"""FLV 头部/编码探测：判断视频编码 ID、是否有序列头、音频编码。

用法: python tools/flv_probe.py <file.flv> [max_bytes]
"""
import sys

VIDEO_CODECS = {
    2: 'Sorenson H.263',
    3: 'Screen video',
    4: 'VP6',
    5: 'VP6 alpha',
    6: 'Screen video v2',
    7: 'AVC/H.264',
    12: 'HEVC/H.265',
    13: 'AV1',
}


def probe(path, limit=None):
    data = open(path, 'rb').read() if limit is None else open(path, 'rb').read(limit)
    if len(data) < 13 or data[:3] != b'FLV':
        return {'file': path, 'error': 'not flv / too short'}
    pos = int.from_bytes(data[5:9], 'big') + 4
    info = {
        'file': path,
        'size_read': len(data),
        'has_audio': bool(data[4] & 0x04),
        'has_video': bool(data[4] & 0x01),
        'video_codec_ids': [],
        'first_video_tag': None,
        'video_seq_headers': 0,
        'video_frames': 0,
        'keyframes': 0,
        'audio_codec': None,
        'tags': 0,
        'meta': False,
        'last_ts': 0,
    }
    sizes = {}
    while pos + 11 <= len(data):
        tag_type = data[pos] & 0x1F
        size = int.from_bytes(data[pos + 1:pos + 4], 'big')
        ts = int.from_bytes(data[pos + 4:pos + 7], 'big') | (data[pos + 7] << 24)
        body = data[pos + 11:pos + 11 + size]
        if len(body) < size:
            info['truncated'] = True
            break
        info['tags'] += 1
        info['last_ts'] = ts
        sizes[tag_type] = sizes.get(tag_type, 0) + 1
        if tag_type == 18:
            info['meta'] = True
        elif tag_type == 9 and size >= 1:
            b0 = body[0]
            codec = b0 & 0x0F
            info['video_codec_ids'].append(codec)
            if info['first_video_tag'] is None:
                info['first_video_tag'] = {
                    'codec': codec,
                    'codec_name': VIDEO_CODECS.get(codec, f'unknown({codec})'),
                    'frame_type': b0 >> 4,
                    'packet_type': body[1] if size > 1 else None,
                    'ts': ts,
                }
            if size >= 2 and body[1] == 0:
                info['video_seq_headers'] += 1
            else:
                info['video_frames'] += 1
            if b0 >> 4 == 1:
                info['keyframes'] += 1
        elif tag_type == 8 and size >= 1:
            info['audio_codec'] = body[0] >> 4
        pos += 11 + size + 4
    info['tag_counts'] = sizes
    info['video_codec_ids'] = sorted(set(info['video_codec_ids']))
    return info


if __name__ == '__main__':
    limit = int(sys.argv[2]) if len(sys.argv) > 2 else None
    for k, v in probe(sys.argv[1], limit).items():
        print(f'{k}: {v}')
