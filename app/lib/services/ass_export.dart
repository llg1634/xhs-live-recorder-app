import 'dart:convert';
import 'dart:io';

/// 把 `comments.jsonl` 转成弹幕字幕（ASS + SRT）。
///
/// 移植自原脚本 `xhs-live-webui-recorder.js` 的 `generateAss` / `generateSrt`：
/// - 画布 1080×1920，字号 42，单条滚动 8 秒，`\move` 右→左；
/// - 按 56px 泳道做简单避让，避免同一时刻弹幕完全重叠；
/// - `relative_ms` = 评论时间戳 − 录制开始时间。
///
/// 生成的文件放在录像目录里，PotPlayer / VLC 可直接挂载。
class AssExporter {
  static const int playResX = 1080;
  static const int playResY = 1920;
  static const int fontSize = 42;
  static const int durationMs = 8000;
  static const int top = 140;
  static const int laneHeight = 56;

  /// 读取 [commentsJsonl] 并生成 `comments.ass` / `comments.srt`。
  /// 返回生成的评论条数；没有评论时返回 0 且不写文件。
  static Future<int> export({
    required String outputDir,
    required int startEpochMs,
  }) async {
    final file = File('$outputDir/comments.jsonl');
    if (!await file.exists()) return 0;

    final comments = <Map<String, dynamic>>[];
    for (final line in await file.readAsLines()) {
      final text = line.trim();
      if (text.isEmpty) continue;
      try {
        final obj = jsonDecode(text) as Map<String, dynamic>;
        final ts = (obj['ts'] as num?)?.toInt() ?? startEpochMs;
        obj['relative_ms'] = ts - startEpochMs;
        obj['text'] = (obj['text'] ?? '').toString();
        comments.add(obj);
      } catch (_) {
        continue;
      }
    }
    if (comments.isEmpty) return 0;

    comments.sort((a, b) => ((a['relative_ms'] as int) - (b['relative_ms'] as int)));

    await File('$outputDir/comments.ass').writeAsString(buildAss(comments));
    await File('$outputDir/comments.srt').writeAsString(buildSrt(comments));
    return comments.length;
  }

  static String buildAss(List<Map<String, dynamic>> comments) {
    final laneCount = ((playResY - top - 240) / laneHeight).floor().clamp(1, 64);
    final lanes = List<int>.filled(laneCount, 0);

    final lines = <String>[
      '[Script Info]',
      'ScriptType: v4.00+',
      'Collisions: Normal',
      'PlayResX: $playResX',
      'PlayResY: $playResY',
      'WrapStyle: 2',
      'ScaledBorderAndShadow: yes',
      '',
      '[V4+ Styles]',
      'Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, '
          'OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, '
          'ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, '
          'Alignment, MarginL, MarginR, MarginV, Encoding',
      'Style: Danmaku,Microsoft YaHei,$fontSize,&H00FFFFFF,&H00FFFFFF,'
          '&H00324146,&H66000000,0,0,0,0,100,100,0,0,1,2.4,0,7,0,0,0,1',
      '',
      '[Events]',
      'Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, '
          'Effect, Text',
    ];

    for (final comment in comments) {
      final startMs = (comment['relative_ms'] as int? ?? 0).clamp(0, 1 << 40);
      final endMs = startMs + durationMs;
      var laneIndex = lanes.indexWhere((availableAt) => availableAt <= startMs);
      if (laneIndex < 0) {
        var minIndex = 0;
        for (var i = 1; i < lanes.length; i++) {
          if (lanes[i] < lanes[minIndex]) minIndex = i;
        }
        laneIndex = minIndex;
      }
      lanes[laneIndex] = startMs + (durationMs ~/ 3 < 900 ? 900 : durationMs ~/ 3);

      final y = top + laneIndex * laneHeight;
      final text = _escape(comment['text']?.toString() ?? '');
      if (text.trim().isEmpty) continue;
      final width = (text.runes.length * fontSize).clamp(600, 8000);
      lines.add('Dialogue: 0,${_assTime(startMs)},${_assTime(endMs)},Danmaku,,'
          '0,0,0,,{\\move($playResX,$y,-$width,$y)}$text');
    }
    return '${lines.join('\n')}\n';
  }

  static String buildSrt(List<Map<String, dynamic>> comments) {
    final blocks = <String>[];
    var index = 1;
    for (final comment in comments) {
      final text = (comment['text']?.toString() ?? '')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      if (text.isEmpty) continue;
      final startMs = (comment['relative_ms'] as int? ?? 0).clamp(0, 1 << 40);
      final endMs = startMs + 3000;
      blocks.add('${index++}');
      blocks.add('${_srtTime(startMs)} --> ${_srtTime(endMs)}');
      blocks.add(text);
      blocks.add('');
    }
    return blocks.join('\n');
  }

  /// ASS 时间：`H:MM:SS.cc`（百分秒）。
  static String _assTime(int ms) {
    final totalCs = (ms < 0 ? 0 : ms) ~/ 10;
    final cs = totalCs % 100;
    final totalSeconds = totalCs ~/ 100;
    final seconds = totalSeconds % 60;
    final minutes = (totalSeconds ~/ 60) % 60;
    final hours = totalSeconds ~/ 3600;
    return '$hours:${_pad2(minutes)}:${_pad2(seconds)}.${_pad2(cs)}';
  }

  static String _srtTime(int ms) {
    final totalMs = ms < 0 ? 0 : ms;
    final millis = totalMs % 1000;
    final totalSeconds = totalMs ~/ 1000;
    final seconds = totalSeconds % 60;
    final minutes = (totalSeconds ~/ 60) % 60;
    final hours = totalSeconds ~/ 3600;
    return '${_pad2(hours)}:${_pad2(minutes)}:${_pad2(seconds)},'
        '${_pad3(millis)}';
  }

  static String _escape(String text) => text
      .replaceAll('\\', r'\\')
      .replaceAll('{', r'\{')
      .replaceAll('}', r'\}')
      .replaceAll('\r', '')
      .replaceAll('\n', ' ');

  static String _pad2(int v) => v.toString().padLeft(2, '0');
  static String _pad3(int v) => v.toString().padLeft(3, '0');
}
