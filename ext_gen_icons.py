"""Generate red rounded-square PNG icons (16/32/48/128) without PIL."""
import zlib, struct, math, os

def make_png(size, px, path):
    """px: list of rows, each row = list of RGBA tuples"""
    raw = b""
    for row in px:
        raw += b"\x00" + b"".join(bytes(p) for p in row)
    def chunk(typ, data):
        c = struct.pack(">I", len(data)) + typ + data
        c += struct.pack(">I", zlib.crc32(typ + data) & 0xFFFFFFFF)
        return c
    ihdr = struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0)
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(png)

def rounded_rect(px, size, x0, y0, x1, y1, r, color):
    """fill rounded rect with color (rgba tuple)"""
    for y in range(y0, y1 + 1):
        for x in range(x0, x1 + 1):
            # nearest corner distance
            cx = min(max(x, x0 + r), x1 - r)
            cy = min(max(y, y0 + r), y1 - r)
            d = math.hypot(x - cx, y - cy)
            if d <= r:
                px[y][x] = color

def circle(px, size, cx, cy, r, color):
    for y in range(max(0, int(cy - r)), min(size - 1, int(cy + r)) + 1):
        for x in range(max(0, int(cx - r)), min(size - 1, int(cx + r)) + 1):
            if math.hypot(x - cx, y - cy) <= r:
                px[y][x] = color

def build(size):
    # background: vertical gradient red (like #ff2442 -> #d7193f)
    px = [[(0,0,0,0) for _ in range(size)] for _ in range(size)]
    C1 = (255, 36, 66, 255)   # #ff2442
    C2 = (207, 22, 62, 255)   # #cf163e
    m = size - 1
    for y in range(size):
        t = y / m
        base = (int(C1[0] + (C2[0]-C1[0])*t), int(C1[1] + (C2[1]-C1[1])*t), int(C1[2] + (C2[2]-C1[2])*t), 255)
        for x in range(size):
            px[y][x] = base
    # rounded corner mask: make transparent outside rounded rect
    # (do it by re-applying transparent outside)
    rad = max(2, size // 5)
    for y in range(size):
        for x in range(size):
            # inside-check with rounded corners
            xr = min(x, size - 1 - x)
            yr = min(y, size - 1 - y)
            if xr < rad and yr < rad:
                if math.hypot((rad - xr), (rad - yr)) > rad:
                    px[y][x] = (0,0,0,0)
    # white play-ish dot (like record button center dot): white circle with red center? 
    # Use XHS vibe: white circle at center
    cr = max(1, size * 0.28)
    circle(px, size, size * 0.5, size * 0.5, cr, (255,255,255,255))
    # inner red dot
    circle(px, size, size * 0.5, size * 0.5, cr * 0.42, (255, 36, 66, 255))
    return px

out = os.path.dirname(os.path.abspath(__file__))
for size in (16, 32, 48, 128):
    px = build(size)
    make_png(size, px, os.path.join(out, f"icon{size}.png"))
    print("generated", f"icon{size}.png")