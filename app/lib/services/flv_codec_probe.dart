import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

/// FLV 首个视频 tag 的编码探测结果。
///
/// 用途：预览页在决定“WebView(flv.js，仅 H.264)”还是“原生 MediaCodec”之前，
/// 先读 512KB 文件头 / 本地服务的当前分段头，避免 HEVC 流在 flv.js 里先报错再回退。
class FlvCodecInfo {
  const FlvCodecInfo({
    this.videoCodecId = 0,
    this.audioCodecId = 0,
    this.hasVideo = false,
    this.hasAudio = false,
    this.hasSequenceHeader = false,
    this.width = 0,
    this.height = 0,
    this.durationMs = 0,
    this.error,
  });

  /// 7 = AVC/H.264，12 = HEVC/H.265，0 = 未识别。
  final int videoCodecId;

  /// FLV soundFormat：10 = AAC。
  final int audioCodecId;

  final bool hasVideo;
  final bool hasAudio;

  /// 是否读到 AVC 的 AVCDecoderConfigurationRecord / HEVC 的 HEVCDecoderConfigurationRecord。
  final bool hasSequenceHeader;

  final int width;
  final int height;
  final int durationMs;
  final String? error;

  bool get isHevc => videoCodecId == 12;

  bool get isAvc => videoCodecId == 7;

  bool get isKnownVideo => isAvc || isHevc;

  String get videoCodecName {
    switch (videoCodecId) {
      case 7:
        return 'H.264 (AVC)';
      case 12:
        return 'H.265 (HEVC)';
      default:
        return '未知';
    }
  }

  static FlvCodecInfo unknown([String? error]) =>
      FlvCodecInfo(error: error);

  Map<String, dynamic> toJson() => <String, dynamic>{
        'videoCodecId': videoCodecId,
        'audioCodecId': audioCodecId,
        'hasVideo': hasVideo,
        'hasAudio': hasAudio,
        'hasSequenceHeader': hasSequenceHeader,
        'width': width,
        'height': height,
        'durationMs': durationMs,
        'error': error,
      };

  factory FlvCodecInfo.fromJson(Map<String, dynamic> json) {
    int asInt(Object? value) {
      if (value is int) return value;
      if (value is num) return value.toInt();
      return 0;
    }

    return FlvCodecInfo(
      videoCodecId: asInt(json['videoCodecId']),
      audioCodecId: asInt(json['audioCodecId']),
      hasVideo: json['hasVideo'] == true,
      hasAudio: json['hasAudio'] == true,
      hasSequenceHeader: json['hasSequenceHeader'] == true,
      width: asInt(json['width']),
      height: asInt(json['height']),
      durationMs: asInt(json['durationMs']),
      error: json['error']?.toString(),
    );
  }
}

/// FLV 编码探测（纯 Dart，可在单元测试 / 命令行里直接跑）。
class FlvCodecProbe {
  /// 只读文件头 [maxBytes]（默认 512KB），不会把 1GB 录像整个读进来。
  static Future<FlvCodecInfo> probeFile(
    String path, {
    int maxBytes = 512 * 1024,
  }) async {
    final File file = File(path);
    if (!await file.exists()) {
      throw FileSystemException('录像文件不存在', path);
    }
    final RandomAccessFile raf = await file.open();
    try {
      final int length = await raf.length();
      final int readLength = math.min(length, maxBytes);
      if (readLength <= 0) return FlvCodecInfo.unknown('空文件');
      final Uint8List data = await raf.read(readLength);
      return parse(data);
    } finally {
      await raf.close();
    }
  }

  /// 通过本地服务探测正在录制的任务（读当前分段文件头）。
  static Future<FlvCodecInfo> probeTask(
    String baseUrl,
    String taskId, {
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final HttpClient client = HttpClient()..connectionTimeout = timeout;
    try {
      final Uri uri = Uri.parse(
        '$baseUrl/probe?taskId=${Uri.encodeQueryComponent(taskId)}',
      );
      final HttpClientRequest request = await client.getUrl(uri);
      final HttpClientResponse response =
          await request.close().timeout(timeout);
      if (response.statusCode != HttpStatus.ok) {
        return FlvCodecInfo.unknown('探测接口 HTTP ${response.statusCode}');
      }
      final String body = await response.transform(utf8.decoder).join();
      final Object? decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) {
        return FlvCodecInfo.fromJson(decoded);
      }
      if (decoded is Map) {
        return FlvCodecInfo.fromJson(
          decoded.map((Object? key, Object? value) =>
              MapEntry<String, dynamic>(key.toString(), value)),
        );
      }
      return FlvCodecInfo.unknown('探测接口返回非 JSON 对象');
    } catch (e) {
      return FlvCodecInfo.unknown('探测失败：$e');
    } finally {
      client.close(force: true);
    }
  }

  /// 解析内存中的 FLV 前缀（至少包含 9 字节文件头）。
  static FlvCodecInfo parse(Uint8List data) {
    if (data.length < 13) return FlvCodecInfo.unknown('数据不足 13 字节');
    if (data[0] != 0x46 || data[1] != 0x4C || data[2] != 0x56) {
      return FlvCodecInfo.unknown('不是 FLV 文件');
    }
    final int dataOffset = _readU32(data, 5);
    if (dataOffset < 9 || dataOffset + 4 > data.length) {
      return FlvCodecInfo.unknown('FLV dataOffset 异常');
    }
    int pos = dataOffset + 4;

    int videoCodecId = 0;
    int audioCodecId = 0;
    bool hasVideo = false;
    bool hasAudio = false;
    bool hasSequenceHeader = false;
    int width = 0;
    int height = 0;
    int durationMs = 0;

    while (pos + 11 <= data.length) {
      final int type = data[pos];
      final int size = (data[pos + 1] << 16) |
          (data[pos + 2] << 8) |
          data[pos + 3];
      final int bodyStart = pos + 11;
      final int tagEnd = bodyStart + size;
      if (size < 0 || tagEnd + 4 > data.length) break;

      if (type == 9 && size >= 5) {
        hasVideo = true;
        final int b0 = data[bodyStart];
        final int codecId = b0 & 0x0F;
        final int packetType = data[bodyStart + 1];
        if (videoCodecId == 0) videoCodecId = codecId;
        if (codecId == 7 || codecId == 12) {
          if (packetType == 0 && !hasSequenceHeader) {
            hasSequenceHeader = true;
            final Uint8List csd = Uint8List.sublistView(
              data,
              bodyStart + 5,
              bodyStart + size,
            );
            final (int, int)? wh = codecId == 12
                ? _parseHevcSpsSize(csd)
                : _parseAvcSpsSize(csd);
            if (wh != null) {
              width = wh.$1;
              height = wh.$2;
            }
          }
        }
      } else if (type == 8 && size >= 2) {
        hasAudio = true;
        final int soundFormat = (data[bodyStart] & 0xFF) >> 4;
        if (audioCodecId == 0) audioCodecId = soundFormat;
      } else if (type == 18 && size > 0) {
        // onMetaData：只取 duration，宽高优先用 SPS。
        try {
          final Map<String, double> meta = _parseAmfMetaData(
            Uint8List.sublistView(data, bodyStart, tagEnd),
          );
          final double? duration = meta['duration'];
          if (duration != null && duration > 0) {
            durationMs = (duration * 1000).round();
          }
        } catch (_) {}
      }

      pos = tagEnd + 4;
      // 首个视频 tag 已经拿到 codecId 后，再扫一小段找音频/时长即可。
      if (hasVideo && videoCodecId != 0 && pos > dataOffset + 256 * 1024) {
        break;
      }
    }

    return FlvCodecInfo(
      videoCodecId: videoCodecId,
      audioCodecId: audioCodecId,
      hasVideo: hasVideo,
      hasAudio: hasAudio,
      hasSequenceHeader: hasSequenceHeader,
      width: width,
      height: height,
      durationMs: durationMs,
    );
  }

  static int _readU32(Uint8List data, int offset) =>
      (data[offset] << 24) |
      (data[offset + 1] << 16) |
      (data[offset + 2] << 8) |
      data[offset + 3];

  // -------------------------------------------------------------------------
  // AMF0
  // -------------------------------------------------------------------------

  static Map<String, double> _parseAmfMetaData(Uint8List payload) {
    final Map<String, double> out = <String, double>{};
    final _AmfReader reader = _AmfReader(payload);
    try {
      if (reader.readByte() != 0x02) return out;
      reader.readString(reader.readShort());
      final int marker = reader.readByte();
      if (marker == 0x08) {
        reader.readInt();
      } else if (marker != 0x03) {
        return out;
      }
      while (reader.remaining >= 2) {
        final int keyLength = reader.readShort();
        if (keyLength == 0) {
          if (reader.remaining > 0) reader.readByte();
          break;
        }
        final String key = reader.readString(keyLength);
        final Object? value = _readAmfValue(reader);
        if (value is double) out[key] = value;
      }
    } catch (_) {}
    return out;
  }

  static Object? _readAmfValue(_AmfReader reader) {
    final int marker = reader.readByte();
    switch (marker) {
      case 0x00:
        return reader.readDouble();
      case 0x01:
        return reader.readByte() != 0;
      case 0x02:
        return reader.readString(reader.readShort());
      case 0x03:
      case 0x08:
        if (marker == 0x08) reader.readInt();
        while (reader.remaining >= 2) {
          final int keyLength = reader.readShort();
          if (keyLength == 0) {
            if (reader.remaining > 0) reader.readByte();
            break;
          }
          reader.readString(keyLength);
          _readAmfValue(reader);
        }
        return null;
      case 0x05:
      case 0x06:
        return null;
      case 0x0A:
        final int count = reader.readInt();
        for (int i = 0; i < count; i++) {
          _readAmfValue(reader);
        }
        return null;
      case 0x0B:
        reader.readDouble();
        reader.readShort();
        return null;
      default:
        return null;
    }
  }

  // -------------------------------------------------------------------------
  // HEVC hvcC / SPS
  // -------------------------------------------------------------------------

  static (int, int)? _parseHevcSpsSize(Uint8List hvcCsd) {
    final Uint8List? sps = _extractHevcSps(hvcCsd);
    if (sps == null) return null;
    try {
      final _BitReader br = _BitReader(_removeEmulationPrevention(sps));
      br.readBits(4); // sps_video_parameter_set_id
      final int maxSubLayersMinus1 = br.readBits(3);
      br.readBits(1); // sps_temporal_id_nesting_flag
      // profile_tier_level(1, maxSubLayersMinus1)
      br.readBits(2);
      br.readBits(1);
      br.readBits(5);
      br.readBits(32);
      br.readBits(48);
      br.readBits(8);
      for (int i = 0; i < maxSubLayersMinus1; i++) {
        final int profilePresent = br.readBits(1);
        final int levelPresent = br.readBits(1);
        if (profilePresent == 1) br.readBits(88);
        if (levelPresent == 1) br.readBits(8);
      }
      if (maxSubLayersMinus1 > 0) {
        for (int i = 0; i < maxSubLayersMinus1; i++) {
          br.readBits(2);
        }
      }
      br.readUe(); // sps_seq_parameter_set_id
      final int chromaFormatIdc = br.readUe();
      if (chromaFormatIdc == 3) br.readBits(1);
      int width = br.readUe();
      int height = br.readUe();
      if (br.readBits(1) == 1) {
        final int left = br.readUe();
        final int right = br.readUe();
        final int top = br.readUe();
        final int bottom = br.readUe();
        final int subWidthC =
            (chromaFormatIdc == 1 || chromaFormatIdc == 2) ? 2 : 1;
        final int subHeightC = chromaFormatIdc == 1 ? 2 : 1;
        width -= (left + right) * subWidthC;
        height -= (top + bottom) * subHeightC;
      }
      if (width <= 0 || height <= 0 || width > 8192 || height > 8192) {
        return null;
      }
      return (width, height);
    } catch (_) {
      return null;
    }
  }

  static Uint8List? _extractHevcSps(Uint8List hvcCsd) {
    if (hvcCsd.length < 23) return null;
    int pos = 22;
    final int numArrays = hvcCsd[pos];
    pos += 1;
    for (int i = 0; i < numArrays; i++) {
      if (pos + 3 > hvcCsd.length) return null;
      final int nalType = hvcCsd[pos] & 0x3F;
      final int count = (hvcCsd[pos + 1] << 8) | hvcCsd[pos + 2];
      pos += 3;
      for (int j = 0; j < count; j++) {
        if (pos + 2 > hvcCsd.length) return null;
        final int length = (hvcCsd[pos] << 8) | hvcCsd[pos + 1];
        pos += 2;
        if (length <= 0 || pos + length > hvcCsd.length) return null;
        if (nalType == 33) {
          return Uint8List.sublistView(hvcCsd, pos, pos + length);
        }
        pos += length;
      }
    }
    return null;
  }

  static Uint8List _removeEmulationPrevention(Uint8List data) {
    final List<int> out = <int>[];
    int zeros = 0;
    for (final int value in data) {
      if (zeros >= 2 && value == 0x03) {
        zeros = 0;
        continue;
      }
      out.add(value);
      zeros = value == 0x00 ? zeros + 1 : 0;
    }
    return Uint8List.fromList(out);
  }

  // -------------------------------------------------------------------------
  // AVC avcC / SPS
  // -------------------------------------------------------------------------

  static (int, int)? _parseAvcSpsSize(Uint8List avcCsd) {
    if (avcCsd.length < 8) return null;
    int pos = 5;
    final int numSps = avcCsd[pos] & 0x1F;
    pos += 1;
    if (numSps <= 0) return null;
    if (pos + 2 > avcCsd.length) return null;
    final int length = (avcCsd[pos] << 8) | avcCsd[pos + 1];
    pos += 2;
    if (length <= 0 || pos + length > avcCsd.length) return null;
    final Uint8List sps =
        Uint8List.sublistView(avcCsd, pos, pos + length);
    try {
      final _BitReader br = _BitReader(_removeEmulationPrevention(sps));
      final int profileIdc = br.readBits(8);
      br.readBits(8); // constraint flags
      br.readBits(8); // level
      br.readUe(); // seq_parameter_set_id
      int chromaFormatIdc = 1;
      if (<int>[
        100,
        110,
        122,
        244,
        44,
        83,
        86,
        118,
        128,
        138,
        139,
        134,
        135,
      ].contains(profileIdc)) {
        chromaFormatIdc = br.readUe();
        if (chromaFormatIdc == 3) br.readBits(1);
        br.readUe(); // bit_depth_luma_minus8
        br.readUe(); // bit_depth_chroma_minus8
        br.readBits(1); // qpprime_y_zero_transform_bypass_flag
        if (br.readBits(1) == 1) {
          final int count = chromaFormatIdc != 3 ? 8 : 12;
          for (int i = 0; i < count; i++) {
            if (br.readBits(1) == 1) _skipScalingList(br, i < 6 ? 16 : 64);
          }
        }
      }
      br.readUe(); // log2_max_frame_num_minus4
      final int picOrderCntType = br.readUe();
      if (picOrderCntType == 0) {
        br.readUe();
      } else if (picOrderCntType == 1) {
        br.readBits(1);
        br.readUe();
        br.readUe();
        final int cycle = br.readUe();
        for (int i = 0; i < cycle; i++) {
          br.readUe();
        }
      }
      br.readUe(); // max_num_ref_frames
      br.readBits(1); // gaps_in_frame_num_value_allowed_flag
      final int widthMbs = br.readUe() + 1;
      final int heightMapUnits = br.readUe() + 1;
      final int frameMbsOnly = br.readBits(1);
      if (frameMbsOnly == 0) br.readBits(1);
      br.readBits(1); // direct_8x8_inference_flag
      int cropLeft = 0;
      int cropRight = 0;
      int cropTop = 0;
      int cropBottom = 0;
      if (br.readBits(1) == 1) {
        cropLeft = br.readUe();
        cropRight = br.readUe();
        cropTop = br.readUe();
        cropBottom = br.readUe();
      }
      final int subWidthC =
          (chromaFormatIdc == 1 || chromaFormatIdc == 2) ? 2 : 1;
      final int subHeightC = chromaFormatIdc == 1 ? 2 : 1;
      final int width = widthMbs * 16 - (cropLeft + cropRight) * subWidthC;
      final int height = (2 - frameMbsOnly) * heightMapUnits * 16 -
          (cropTop + cropBottom) * subHeightC * (2 - frameMbsOnly);
      if (width <= 0 || height <= 0) return null;
      return (width, height);
    } catch (_) {
      return null;
    }
  }

  static void _skipScalingList(_BitReader br, int size) {
    int lastScale = 8;
    int nextScale = 8;
    for (int i = 0; i < size; i++) {
      if (nextScale != 0) {
        final int delta = br.readSe();
        nextScale = (lastScale + delta + 256) % 256;
      }
      lastScale = nextScale == 0 ? lastScale : nextScale;
    }
  }
}

class _AmfReader {
  _AmfReader(this.data);

  final Uint8List data;
  int pos = 0;

  int get remaining => data.length - pos;

  int readByte() {
    if (pos >= data.length) throw const FormatException('AMF 越界');
    return data[pos++];
  }

  int readShort() => (readByte() << 8) | readByte();

  int readInt() =>
      (readByte() << 24) | (readByte() << 16) | (readByte() << 8) | readByte();

  double readDouble() {
    int bits = 0;
    for (int i = 0; i < 8; i++) {
      bits = (bits << 8) | readByte();
    }
    final ByteData view = ByteData(8)..setInt64(0, bits);
    return view.getFloat64(0);
  }

  String readString(int length) {
    if (length < 0 || pos + length > data.length) {
      throw const FormatException('AMF 字符串越界');
    }
    final String text = utf8.decode(
      Uint8List.sublistView(data, pos, pos + length),
      allowMalformed: true,
    );
    pos += length;
    return text;
  }
}

class _BitReader {
  _BitReader(this.data);

  final Uint8List data;
  int bitPos = 0;

  int readBit() {
    final int byteIndex = bitPos >> 3;
    if (byteIndex >= data.length) throw const FormatException('位流越界');
    final int bit = (data[byteIndex] >> (7 - (bitPos & 7))) & 1;
    bitPos += 1;
    return bit;
  }

  int readBits(int count) {
    int value = 0;
    for (int i = 0; i < count; i++) {
      value = (value << 1) | readBit();
    }
    return value;
  }

  int readUe() {
    int zeros = 0;
    while (readBit() == 0) {
      zeros += 1;
      if (zeros > 31) throw const FormatException('Exp-Golomb 溢出');
    }
    if (zeros == 0) return 0;
    return (1 << zeros) - 1 + readBits(zeros);
  }

  int readSe() {
    final int value = readUe();
    return (value & 1) == 1 ? (value + 1) ~/ 2 : -(value ~/ 2);
  }
}
