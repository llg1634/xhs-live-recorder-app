import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

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

  String playerUrlForFile(String filePath) =>
      '$baseUrl/player.html?src=${Uri.encodeComponent('/file?path=$filePath')}';

  Future<void> start() async {
    if (_server != null) return;
    final handler = const Pipeline().addHandler(_route);
    _server = await shelf_io.serve(handler, InternetAddress.loopbackIPv4, port);
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
      return Response.notFound('not found');
    } catch (e) {
      return Response.internalServerError(body: '$e');
    }
  }

  Response _liveStream(String taskId) {
    final recorder = manager.recorderFor(taskId);
    if (recorder == null) {
      return Response.notFound('task not recording');
    }
    StreamSubscription<Uint8List>? subscription;
    late StreamController<List<int>> controller;
    controller = StreamController<List<int>>(
      onListen: () {
        final prelude = recorder.prelude;
        if (prelude != null) controller.add(prelude);
        subscription = recorder.previewStream.listen(
          controller.add,
          onError: controller.addError,
          onDone: controller.close,
        );
      },
      onCancel: () async {
        await subscription?.cancel();
        subscription = null;
      },
    );

    return Response.ok(
      controller.stream,
      headers: {
        'content-type': 'video/x-flv',
        'cache-control': 'no-store',
        'access-control-allow-origin': '*',
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
