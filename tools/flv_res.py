"""从 FLV 里解析 H.264 SPS，得到分辨率。（没有 ffprobe 时的替代）"""
import sys, struct


def read_flv(path):
    data = open(path, 'rb').read()
    if data[:3] != b'FLV':
        raise SystemExit('not flv')
    pos = struct.unpack('>I', data[5:9])[0] + 4  # 跳过 PreviousTagSize0
    tags = []
    while pos + 11 <= len(data):
        tag_type = data[pos] & 0x1f
        size = int.from_bytes(data[pos + 1:pos + 4], 'big')
        body = data[pos + 11:pos + 11 + size]
        tags.append((tag_type, body))
        pos += 11 + size + 4
    return tags


def sps_from_avc(body):
    # video tag: [frametype/codec][AVCPacketType][composition time 3B][payload]
    if len(body) < 5:
        return None
    if body[1] != 0:  # 0 = AVC sequence header
        return None
    rec = body[5:]
    num_sps = rec[5] & 0x1f
    p = 6
    for _ in range(num_sps):
        ln = int.from_bytes(rec[p:p + 2], 'big')
        sps = rec[p + 2:p + 2 + ln]
        p += 2 + ln
        return sps
    return None


class BitReader:
    def __init__(self, data):
        self.data = data
        self.pos = 0

    def bit(self):
        byte = self.data[self.pos >> 3]
        v = (byte >> (7 - (self.pos & 7))) & 1
        self.pos += 1
        return v

    def bits(self, n):
        v = 0
        for _ in range(n):
            v = (v << 1) | self.bit()
        return v

    def ue(self):
        zeros = 0
        while self.bit() == 0:
            zeros += 1
        return (1 << zeros) - 1 + self.bits(zeros)


def parse_sps(sps):
    # 去掉 emulation prevention 0x000003
    out = bytearray()
    i = 0
    while i < len(sps):
        if i + 2 < len(sps) and sps[i] == 0 and sps[i + 1] == 0 and sps[i + 2] == 3:
            out += sps[i:i + 2]
            i += 3
        else:
            out.append(sps[i])
            i += 1
    r = BitReader(bytes(out))
    r.bits(8)  # nal header
    profile = r.bits(8)
    r.bits(16)  # constraint + level
    r.ue()  # seq_parameter_set_id
    if profile in (100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135):
        chroma = r.ue()
        if chroma == 3:
            r.bit()
        r.ue()
        r.ue()
        r.bit()
        if r.bit():
            for i in range(8 if chroma != 3 else 12):
                if r.bit():
                    # scaling list: 跳过
                    last = 8
                    nxt = 8
                    for _j in range(16 if i < 6 else 64):
                        if nxt != 0:
                            nxt = (last + r.ue() + 256) % 256
                        last = nxt if nxt != 0 else last
    r.ue()  # log2_max_frame_num_minus4
    poc_type = r.ue()
    if poc_type == 0:
        r.ue()
    elif poc_type == 1:
        r.bit()
        r.ue()
        r.ue()
        for _ in range(r.ue()):
            r.ue()
    r.ue()  # max_num_ref_frames
    r.bit()
    w_mbs = r.ue()
    h_map = r.ue()
    frame_mbs_only = r.bit()
    if not frame_mbs_only:
        r.bit()
    r.bit()  # direct_8x8
    if r.bit():  # cropping
        l = r.ue(); rr = r.ue(); t = r.ue(); b = r.ue()
    else:
        l = rr = t = b = 0
    width = (w_mbs + 1) * 16 - (l + rr) * 2
    height = (2 - frame_mbs_only) * (h_map + 1) * 16 - (t + b) * 2
    return width, height


for path in sys.argv[1:]:
    tags = read_flv(path)
    got = None
    for t, body in tags:
        if t == 9:
            sps = sps_from_avc(body)
            if sps:
                got = parse_sps(sps)
                break
    print(path, got)
