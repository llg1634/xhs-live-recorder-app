"""生成 App 图标：沿用扩展项目的「红色渐变 + 白色录制圆点」设计。

比例设定：
- 传统图标（mipmap-*/ic_launcher.png）：白圈直径 = 画布 56%，适配各家启动器裁切
- 自适应图标前景（drawable-*/ic_launcher_foreground.png）：白圈直径 = 画布 60%，
  落在 108dp 画布的中心 66dp 安全区内（66/108 ≈ 61%），不会被裁掉
"""
import os
from PIL import Image, ImageDraw

BASE = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'app', 'android', 'app', 'src', 'main', 'res')
BASE = os.path.abspath(BASE)

C1 = (255, 36, 66)
C2 = (207, 22, 62)


def gradient(size):
    img = Image.new('RGB', (size, size))
    d = ImageDraw.Draw(img)
    for y in range(size):
        t = y / max(1, size - 1)
        c = tuple(int(C1[i] + (C2[i] - C1[i]) * t) for i in range(3))
        d.line([(0, y), (size, y)], fill=c)
    return img


def add_dot(img, size, ratio):
    """在中间画白色圆 + 红色内点。"""
    d = ImageDraw.Draw(img)
    r = size * ratio / 2
    cx = cy = size / 2
    d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=(255, 255, 255, 255))
    ir = r * 0.42
    d.ellipse([cx - ir, cy - ir, cx + ir, cy + ir], fill=(255, 36, 66, 255))
    return img


def rounded_mask(size, radius_ratio=0.22):
    mask = Image.new('L', (size, size), 0)
    d = ImageDraw.Draw(mask)
    r = int(size * radius_ratio)
    d.rounded_rectangle([0, 0, size - 1, size - 1], radius=r, fill=255)
    return mask


def circle_mask(size):
    mask = Image.new('L', (size, size), 0)
    d = ImageDraw.Draw(mask)
    d.ellipse([0, 0, size - 1, size - 1], fill=255)
    return mask


LEGACY = {'mdpi': 48, 'hdpi': 72, 'xhdpi': 96, 'xxhdpi': 144, 'xxxhdpi': 192}
FG = {'mdpi': 108, 'hdpi': 162, 'xhdpi': 216, 'xxhdpi': 324, 'xxxhdpi': 432}


def main():
    for dpi, size in LEGACY.items():
        out_dir = os.path.join(BASE, f'mipmap-{dpi}')
        os.makedirs(out_dir, exist_ok=True)

        icon = add_dot(gradient(size), size, 0.56).convert('RGBA')
        icon.putalpha(rounded_mask(size))
        icon.save(os.path.join(out_dir, 'ic_launcher.png'))

        rnd = add_dot(gradient(size), size, 0.56).convert('RGBA')
        rnd.putalpha(circle_mask(size))
        rnd.save(os.path.join(out_dir, 'ic_launcher_round.png'))

        fg_dir = os.path.join(BASE, f'drawable-{dpi}')
        os.makedirs(fg_dir, exist_ok=True)
        fg = Image.new('RGBA', (size, size), (0, 0, 0, 0))
        add_dot(fg, size, 0.60)
        fg.save(os.path.join(fg_dir, 'ic_launcher_foreground.png'))

    # 自适应图标 XML
    anydpi = os.path.join(BASE, 'mipmap-anydpi-v26')
    os.makedirs(anydpi, exist_ok=True)
    xml = '''<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@drawable/ic_launcher_background" />
    <foreground android:drawable="@drawable/ic_launcher_foreground" />
</adaptive-icon>
'''
    for name in ('ic_launcher.xml', 'ic_launcher_round.xml'):
        with open(os.path.join(anydpi, name), 'w', encoding='utf-8') as f:
            f.write(xml)

    # 背景渐变 drawable
    drawable = os.path.join(BASE, 'drawable')
    os.makedirs(drawable, exist_ok=True)
    bg = '''<?xml version="1.0" encoding="utf-8"?>
<shape xmlns:android="http://schemas.android.com/apk/res/android"
    android:shape="rectangle">
    <gradient
        android:angle="270"
        android:startColor="#FFFF2442"
        android:endColor="#FFCF163E" />
</shape>
'''
    with open(os.path.join(drawable, 'ic_launcher_background.xml'), 'w', encoding='utf-8') as f:
        f.write(bg)

    print('icons generated at', BASE)


if __name__ == '__main__':
    main()
