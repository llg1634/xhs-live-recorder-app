import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

import '../models/live_room.dart';
import 'recording_manager.dart';

/// 本地 HTTP 服务：
/// - `/live/<taskId>.flv` 把正在录制的实时 FLV 转发给 WebView 里的 flv.js；
/// - `/file?path=...` 回放已录好的分段（支持 Range 供播放器拖动）；
/// - `/player.html?src=...` 播放页（与上面同源，避免 CORS）。
class LocalStreamServer {
  LocalStreamServer({required this.manager, this.port = 0});

  final RecordingManager manager;
  final int port;

  HttpServer? _server;
  final Map<String, Uint8List> _assetCache = {};

  int get actualPort => _server?.port ?? 0;

  String get baseUrl => 'http://127.0.0.1:$actualPort';

  String liveUrl(String taskId) => '$baseUrl/live/$taskId.flv';

  String playerUrlForLive(String taskId) =>
      '$baseUrl/player.html?src=${Uri.encodeComponent('/live/$taskId.flv')}&title=${Uri.encodeComponent('直播预览')}';

  String playerUrlForFile(String filePath) {
    final name = p.basename(filePath);
    return '$baseUrl/player.html?src=${Uri.encodeComponent('/file?path=$filePath')}'
        '&title=${Uri.encodeComponent(name)}';
  }

  Future<void> start() async {
    if (_server != null) return;
    final handler = const Pipeline().addHandler(_route);
    try {
      _server = await shelf_io.serve(handler, InternetAddress.loopbackIPv4, port);
    } catch (_) {
      // 固定端口被占用时退回随机端口，保证预览功能可用。
      _server = await shelf_io.serve(handler, InternetAddress.loopbackIPv4, 0);
    }
    _server!.autoCompress = false;
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  Future<Response> _route(Request request) async {
    final path = '/${request.url.path}';
    try {
      if (path == '/' || path == '/player.html' || path == '/player') {
        return await _playerPage(request);
      }
      if (path == '/flv.min.js') {
        return await _asset('assets/web/flv.min.js', 'application/javascript');
      }
      if (path.startsWith('/live/') && path.endsWith('.flv')) {
        final taskId = path.substring('/live/'.length, path.length - 4);
        return _liveStream(taskId);
      }
      if (path == '/file') {
        return await _file(request);
      }
      if (path == '/debug') {
        return _debug();
      }
      return Response.notFound('not found');
    } catch (e) {
      return Response.internalServerError(body: '$e');
    }
  }

  Response _debug() {
    final tasks = manager.tasks.map((t) => {
          'id': t.id,
          'state': t.state.name,
          'room': t.room?.roomId,
          'platform': t.room?.platform.key,
          'bytes': t.totalBytes,
          'segments': t.segmentCount,
          'recorder': manager.recorderFor(t.id) != null,
          'prelude': manager.recorderFor(t.id)?.prelude?.length,
          'outputDir': t.outputDir,
          'error': t.errorMessage,
        }).toList();
    return Response.ok(
      const JsonEncoder.withIndent('  ').convert({'port': actualPort, 'tasks': tasks}),
      headers: {'content-type': 'application/json; charset=utf-8'},
    );
  }

  /// 实时预览：直接 tail 正在写入的分段文件。
  ///
  /// 不用 `recorder.previewStream` 的原因：预录头 + 实时 socket 字节在拼接处
  /// 不是 FLV tag 对齐的，flv.js 解析会卡住；而 part 文件本身是一个完整 FLV，
  /// 从头顺序读就是合法的渐进式视频流（延迟约等于写盘 flush 间隔）。
  Response _liveStream(String taskId) {
    final task = manager.taskById(taskId);
    if (task == null) return Response.notFound('task not found');

    late StreamController<List<int>> controller;
    var cancelled = false;

    Future<void> pump() async {
      var offset = 0;
      var idleTicks = 0;
      File? current;

      while (!cancelled) {
        final segmentPath = task.currentSegment?.path ??
            (task.segments.isNotEmpty ? task.segments.last.path : null);
        if (segmentPath == null) {
          if (!task.isActive) break;
          await Future<void>.delayed(const Duration(milliseconds: 200));
          continue;
        }

        final file = File(segmentPath);
        if (current?.path != file.path) {
          current = file;
          offset = 0;
          idleTicks = 0;
        }

        try {
          if (!await file.exists()) {
            await Future<void>.delayed(const Duration(milliseconds: 200));
            continue;
          }
          final length = await file.length();
          if (length > offset) {
            final raf = await file.open();
            try {
              await raf.setPosition(offset);
              final bytes = await raf.read(length - offset);
              if (bytes.isNotEmpty && !cancelled && !controller.isClosed) {
                offset += bytes.length;
                idleTicks = 0;
                try {
                  controller.add(bytes);
                } catch (_) {
                  // 客户端可能在读取过程中断开，忽略即可。
                  break;
                }
              }
            } finally {
              await raf.close();
            }
            continue;
          }
        } catch (_) {
          // 文件正在写入时偶尔读不到，忽略后重试。
        }

        // 文件暂时没有新数据：等下一轮；若任务已结束且连续多次没数据则收尾。
        idleTicks++;
        if (!task.isActive && idleTicks > 10) break;
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }

      if (!cancelled && !controller.isClosed) {
        try {
          await controller.close();
        } catch (_) {}
      }
    }

    controller = StreamController<List<int>>(
      onListen: () {
        debugPrint('[live] client connected: task=$taskId');
        unawaited(pump());
      },
      onCancel: () {
        cancelled = true;
        debugPrint('[live] client disconnected: task=$taskId');
      },
    );

    return Response.ok(
      controller.stream,
      headers: {
        'content-type': 'video/x-flv',
        'cache-control': 'no-store',
        'access-control-allow-origin': '*',
        'accept-ranges': 'none',
      },
    );
  }

  Future<Response> _file(Request request) async {
    final path = request.url.queryParameters['path'] ?? '';
    if (path.isEmpty) return Response.badRequest(body: 'missing path');
    final file = File(path);
    if (!await file.exists()) return Response.notFound('file not found');

    final length = await file.length();
    final range = request.headers['range'];
    final contentType = 'video/x-flv';

    if (range != null) {
      final match = RegExp(r'bytes=(\d*)-(\d*)').firstMatch(range);
      if (match != null) {
        final start = int.tryParse(match.group(1) ?? '') ?? 0;
        final end = int.tryParse(match.group(2) ?? '') ?? length - 1;
        final safeEnd = end >= length ? length - 1 : end;
        if (start > safeEnd) return Response(416);
        final sink = file.openRead(start, safeEnd + 1);
        return Response(206, body: sink, headers: {
          'content-type': contentType,
          'content-length': '${safeEnd - start + 1}',
          'content-range': 'bytes $start-$safeEnd/$length',
          'accept-ranges': 'bytes',
          'access-control-allow-origin': '*',
        });
      }
    }

    return Response.ok(file.openRead(), headers: {
      'content-type': contentType,
      'content-length': '$length',
      'accept-ranges': 'bytes',
      'access-control-allow-origin': '*',
    });
  }

  Future<Response> _playerPage(Request request) async {
    final src = request.url.queryParameters['src'] ?? '';
    final title = request.url.queryParameters['title'] ?? '直播预览';
    var html = await _textAsset('assets/web/player.html');
    html = html
        .replaceAll('{{SRC}}', htmlEscape.convert(src))
        .replaceAll('{{TITLE}}', htmlEscape.convert(title));
    return Response.ok(html, headers: {
      'content-type': 'text/html; charset=utf-8',
      'cache-control': 'no-store',
    });
  }

  Future<Response> _asset(String key, String contentType) async {
    final bytes = _assetCache[key] ??= await _loadBytes(key);
    return Response.ok(bytes, headers: {'content-type': contentType});
  }

  Future<String> _textAsset(String key) async {
    final bytes = _assetCache[key] ??= await _loadBytes(key);
    return utf8.decode(bytes);
  }

  Future<Uint8List> _loadBytes(String key) async {
    final data = await rootBundle.load(key);
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  }

  /// 录像目录名 → 便于展示的标题。
  static String prettyName(String dirPath) =>
      p.basename(dirPath).replaceAll('_', ' ');
}
