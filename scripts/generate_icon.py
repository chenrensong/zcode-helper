#!/usr/bin/env python3
"""
生成 ZCode Helper macOS / Windows App Icon。

设计对齐 zcode.z.ai 与 z.ai 官方 favicon：
    白色外圈 + 深色 #2D2D2D 圆角底板 + 白色几何 Z 字，
    外加 sky-500（zcode.z.ai --brand）循环双箭头，表达「账号切换」的工具身份。
    Z 造型与站内 ZcodeMark 组件（lib/ui/theme.dart）同源。

用法：
    python3 scripts/generate_icon.py

产物：
    macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_16.png ~ app_icon_1024.png
    windows/runner/resources/app_icon.ico
"""
import math
import os
import sys

from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ICON_DIR = os.path.join(ROOT, 'macos', 'Runner', 'Assets.xcassets', 'AppIcon.appiconset')
ICO_PATH = os.path.join(ROOT, 'windows', 'runner', 'resources', 'app_icon.ico')
SIZES = (16, 32, 64, 128, 256, 512, 1024)

S = 3072
K = S / 1024.0


def px(v):
    return v * K


def hexc(h):
    h = h.lstrip('#')
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


def gradient(c0, c1):
    n = 256
    g = Image.new('RGB', (n, n))
    d = ImageDraw.Draw(g)
    a, b = hexc(c0), hexc(c1)
    for i in range(n * 2 - 1):
        t = i / (n * 2 - 2)
        d.line([(i, 0), (0, i)],
               fill=tuple(round(a[j] + (b[j] - a[j]) * t) for j in range(3)))
    return g.resize((S, S), Image.LANCZOS)


def squircle_mask(radius, inset=0):
    m = Image.new('L', (S, S), 0)
    ImageDraw.Draw(m).rounded_rectangle(
        [inset, inset, S - 1 - inset, S - 1 - inset], radius=radius, fill=255)
    return m


def paint(canvas, mask, fill):
    layer = fill if isinstance(fill, Image.Image) else Image.new('RGB', (S, S), hexc(fill))
    canvas.paste(layer, (0, 0), mask)


def z_mask(cx, cy, w, h, bar, stub):
    x0, y0, x1, y1 = cx - w / 2, cy - h / 2, cx + w / 2, cy + h / 2
    pts = [(x0, y0), (x1, y0),
           (x0 + stub, y1 - bar), (x1, y1 - bar),
           (x1, y1), (x0, y1),
           (x1 - stub, y0 + bar), (x0, y0 + bar)]
    m = Image.new('L', (S, S), 0)
    ImageDraw.Draw(m).polygon([(px(a), px(b)) for a, b in pts], fill=255)
    return m


def cycle_ring(cx, cy, r, stroke, arcs, head_len, head_hw):
    m = Image.new('L', (S, S), 0)
    d = ImageDraw.Draw(m)
    box = [px(cx - r), px(cy - r), px(cx + r), px(cy + r)]
    for a0, a1 in arcs:
        d.arc(box, a0, a1, fill=255, width=int(px(stroke)))
        th = math.radians(a1)
        ux, uy = math.cos(th), math.sin(th)
        tx, ty = -uy, ux
        tip = (cx + r * ux + tx * head_len, cy + r * uy + ty * head_len)
        b1 = (cx + (r - head_hw) * ux, cy + (r - head_hw) * uy)
        b2 = (cx + (r + head_hw) * ux, cy + (r + head_hw) * uy)
        d.polygon([(px(p[0]), px(p[1])) for p in (tip, b1, b2)], fill=255)
    return m


def drop_shadow(mask, blur, offset, alpha):
    sh = mask.filter(ImageFilter.GaussianBlur(px(blur))).point(lambda v: int(v * alpha))
    out = Image.new('L', (S, S), 0)
    out.paste(sh, (0, int(px(offset))))
    return out


def render():
    z = z_mask(512, 512, 336, 372, 92, 116)
    ring = cycle_ring(512, 512, 350, 54, [(196, 336), (16, 156)], 96, 52)

    radius = int(px(228))
    canvas = Image.new('RGBA', (S, S), (0, 0, 0, 0))

    # 白色底板 = favicon 的白色外圈
    paint(canvas, squircle_mask(radius), gradient('#fdfdfe', '#e9eaec'))

    # 深色内嵌板 = favicon 的 #2D2D2D 方块（约 5% 白边）
    inset = int(px(52))
    dark = squircle_mask(radius - inset, inset)
    canvas.paste(Image.new('RGB', (S, S), (0, 0, 0)), (0, 0),
                 drop_shadow(dark, 18, 8, 0.18))
    paint(canvas, dark, gradient('#333338', '#222225'))

    # 白色 Z + sky-500 循环箭头
    canvas.paste(Image.new('RGB', (S, S), (0, 0, 0)), (0, 0), drop_shadow(z, 22, 10, 0.45))
    paint(canvas, z, gradient('#ffffff', '#e4e5e8'))
    paint(canvas, ring, gradient('#38bdf8', '#0284c7'))
    return canvas.resize((1024, 1024), Image.LANCZOS)


def main():
    os.makedirs(ICON_DIR, exist_ok=True)
    master = render()

    frames = []
    for size in SIZES:
        img = master.resize((size, size), Image.LANCZOS)
        out = os.path.join(ICON_DIR, f'app_icon_{size}.png')
        img.save(out)
        print(f'wrote {out}')
        frames.append(img)

    os.makedirs(os.path.dirname(ICO_PATH), exist_ok=True)
    frames[0].save(ICO_PATH,
                   format='ICO',
                   sizes=[(s, s) for s in (16, 32, 48, 64, 128, 256)])
    print(f'wrote {ICO_PATH}')

    print(f'\nAll {len(SIZES)} icons generated in {ICON_DIR}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
