#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成 1024x1024 的 iOS 应用图标：深色底 + 青绿双向箭头（表示「转换」）。
性能要点：渐变先在小图上逐像素算，再放大；模糊也先在小图上做。"""
from PIL import Image, ImageDraw, ImageFilter
import os

OUT = "/var/minis/workspace/universal-converter/Verto/Assets.xcassets/AppIcon.appiconset/icon_ios_1024.png"
S = 2                      # 超采样倍数（1024 -> 2048 绘制，再缩回）
N = 1024 * S
SMALL = 48                 # 渐变计算用的低分辨率

ACCENT = (77, 222, 143)
ACCENT_DIM = (46, 168, 108)

# --- 背景：对角渐变（小图算完再放大）---
small = Image.new("RGB", (SMALL, SMALL))
pixels = small.load()
for y in range(SMALL):
    for x in range(SMALL):
        t = (x / SMALL) * 0.45 + (y / SMALL) * 0.55
        pixels[x, y] = (int(7 + 14 * t), int(12 + 34 * t), int(16 + 24 * t))
bg = small.resize((N, N), Image.BICUBIC)

# --- 中心柔光（同样先小后大）---
tiny = SMALL * 2
glow = Image.new("L", (tiny, tiny), 0)
ImageDraw.Draw(glow).ellipse([tiny * 0.18, tiny * 0.18, tiny * 0.82, tiny * 0.82], fill=110)
glow = glow.resize((N, N), Image.BICUBIC).filter(ImageFilter.GaussianBlur(N * 0.10))
glow = glow.point(lambda v: int(v * 0.36))
bg = Image.composite(Image.new("RGB", (N, N), ACCENT_DIM), bg, glow)

draw = ImageDraw.Draw(bg, "RGBA")

def arrow(y_center, x_from, x_to, thickness, color):
    half = thickness / 2
    head_len = thickness * 1.5
    head_half = thickness * 1.08
    direction = 1 if x_to > x_from else -1
    shaft_end = x_to - head_len * direction

    draw.rounded_rectangle(
        [min(x_from, shaft_end) - half, y_center - half,
         max(x_from, shaft_end) + half, y_center + half],
        radius=half, fill=color)
    draw.polygon(
        [(x_to, y_center),
         (shaft_end, y_center - head_half),
         (shaft_end, y_center + head_half)],
        fill=color)

arrow(int(N * 0.412), int(N * 0.200), int(N * 0.800), int(N * 0.075), ACCENT)
arrow(int(N * 0.588), int(N * 0.800), int(N * 0.200), int(N * 0.075), ACCENT)

# --- 缩回 1024 并去掉透明通道 ---
final = bg.resize((1024, 1024), Image.LANCZOS).convert("RGB")

os.makedirs(os.path.dirname(OUT), exist_ok=True)
final.save(OUT, "PNG", optimize=True)
final.resize((256, 256), Image.LANCZOS).save("/var/minis/attachments/icon_preview_256.png")
print("已生成", final.size, final.mode, os.path.getsize(OUT), "字节")
