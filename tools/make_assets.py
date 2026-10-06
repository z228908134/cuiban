# -*- coding: utf-8 -*-
"""
生成 App 资源：
  1. App 图标 PNG（纯标准库，无第三方依赖）
  2. 催促提示音 nag.wav（29 秒，循环急促双音）
  3. 常驻静音 silence.wav（后台保活用）
"""
import math
import os
import struct
import wave
import zlib

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
ICON_DIR = os.path.join(ROOT, 'Cuiban', 'Assets.xcassets', 'AppIcon.appiconset')
RES_DIR = os.path.join(ROOT, 'Cuiban', 'Resources')
os.makedirs(ICON_DIR, exist_ok=True)
os.makedirs(RES_DIR, exist_ok=True)

# --------------------------------------------------------------------------
# PNG 写出器
# --------------------------------------------------------------------------

def write_png(path, w, h, pixel_fn):
    raw = bytearray()
    for y in range(h):
        raw.append(0)
        for x in range(w):
            r, g, b, a = pixel_fn(x, y)
            raw += bytes((r, g, b, a))

    def chunk(tag, data):
        return (struct.pack('>I', len(data)) + tag + data +
                struct.pack('>I', zlib.crc32(tag + data) & 0xffffffff))

    out = b'\x89PNG\r\n\x1a\n'
    out += chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 6, 0, 0, 0))
    out += chunk(b'IDAT', zlib.compress(bytes(raw), 9))
    out += chunk(b'IEND', b'')
    with open(path, 'wb') as f:
        f.write(out)


# --------------------------------------------------------------------------
# 形状
# --------------------------------------------------------------------------

def in_round_rect(u, v, r):
    """u,v 归一化到 [0,1]，r 为圆角半径（同坐标尺度）"""
    cx = min(max(u, r), 1.0 - r)
    cy = min(max(v, r), 1.0 - r)
    if u < 0 or v < 0 or u > 1 or v > 1:
        return False
    return (u - cx) ** 2 + (v - cy) ** 2 <= r * r


def in_bell(u, v):
    """铃铛图形。u,v 归一化到 [0,1]"""
    x = (u - 0.5) / 0.86
    y = (v - 0.5) / 0.86 + 0.5 + 0.024
    ax = abs(x)

    # 顶部圆钮
    if x * x + (y - 0.185) ** 2 <= 0.052 ** 2:
        return True
    # 圆顶
    if x * x + (y - 0.405) ** 2 <= 0.238 ** 2:
        return True
    # 外扩钟身
    if 0.405 <= y <= 0.720:
        t = (y - 0.405) / 0.315
        if ax <= 0.238 + t * 0.128:
            return True
    # 底沿（带圆角）
    if 0.720 < y <= 0.790:
        if ax <= 0.300:
            return True
        if ax <= 0.366 and (ax - 0.300) ** 2 + (y - 0.724) ** 2 <= 0.066 ** 2:
            return True
    # 钟锤
    if x * x + (y - 0.768) ** 2 <= 0.098 ** 2:
        return True
    return False


def gradient(u, v):
    """橙红渐变 + 左上高光"""
    t = (u * 0.35 + v * 0.85)
    t = min(1.0, max(0.0, t))
    r = 255 + (238 - 255) * t
    g = 124 + (38 - 124) * t
    b = 66 + (26 - 66) * t
    d = math.hypot(u - 0.26, v - 0.16)
    hl = max(0.0, 1.0 - d / 0.72) ** 2 * 0.30
    r = r + (255 - r) * hl
    g = g + (255 - g) * hl
    b = b + (255 - b) * hl
    return r, g, b


def make_icon(path, size, ss):
    radius = 0.2237
    inv = 1.0 / (size * ss)
    step = 1.0 / ss
    acc = [[0, 0, 0, 0, 0, 0] for _ in range(size * size)]  # bg, glyph, r, g, b 累计

    for py in range(size * ss):
        row = (py // ss) * size
        vy = (py + 0.5) * inv
        for px in range(size * ss):
            ux = (px + 0.5) * inv
            cell = acc[row + (px // ss)]
            if in_round_rect(ux, vy, radius):
                cell[0] += 1
                if in_bell(ux, vy):
                    cell[1] += 1
                else:
                    rr, gg, bb = gradient(ux, vy)
                    cell[2] += rr
                    cell[3] += gg
                    cell[4] += bb
            cell[5] += 1

    total = ss * ss

    def pixel(x, y):
        bg, glyph, r, g, b, _ = acc[y * size + x]
        if bg == 0:
            return (0, 0, 0, 0)
        n = bg - glyph
        if n > 0:
            br, bgc, bb = r / n, g / n, b / n
        else:
            br, bgc, bb = 240, 60, 40
        k = glyph / bg
        fr = br + (255 - br) * k
        fg = bgc + (255 - bgc) * k
        fb = bb + (255 - bb) * k
        alpha = round(255 * bg / total)
        return (int(round(fr)), int(round(fg)), int(round(fb)), alpha)

    write_png(path, size, size, pixel)
    print('icon ->', os.path.basename(path), size)


# --------------------------------------------------------------------------
# 音效
# --------------------------------------------------------------------------

SR = 22050


def tone(freq, dur, amp, sr=SR, shape='mix'):
    out = []
    n = int(dur * sr)
    for i in range(n):
        t = i / sr
        env_pos = i / max(1, n - 1)
        # 快速起音 + 尾部衰减
        env = min(1.0, env_pos / 0.02) * (1.0 - env_pos) ** 0.9
        s = math.sin(2 * math.pi * freq * t)
        if shape == 'mix':
            s = 0.70 * s + 0.30 * (1.0 if s >= 0 else -1.0) * 0.6
        out.append(s * env * amp)
    return out


def silence(dur, sr=SR):
    return [0.0] * int(dur * sr)


def make_alarm(path, seconds=29.0):
    """急促双音循环：叮-咚-叮 然后短暂停顿"""
    buf = []
    burst = [950, 1250, 950]
    while len(buf) < int(seconds * SR):
        progress = len(buf) / float(seconds * SR)
        amp = 0.45 + 0.55 * progress           # 越到后面越响
        for f in burst:
            buf += tone(f, 0.155, amp)
            buf += silence(0.085)
        buf += silence(0.30)
    buf = buf[:int(seconds * SR)]
    # 首尾各 30ms 淡入淡出，避免爆音
    fade = int(0.03 * SR)
    for i in range(fade):
        k = i / fade
        buf[i] *= k
        buf[-1 - i] *= k

    with wave.open(path, 'wb') as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        frames = bytearray()
        for s in buf:
            v = int(max(-1.0, min(1.0, s)) * 32000)
            frames += struct.pack('<h', v)
        w.writeframes(bytes(frames))
    print('audio ->', os.path.basename(path), round(os.path.getsize(path) / 1024.0), 'KB')


def make_silence(path, seconds=2.0):
    with wave.open(path, 'wb') as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(b'\x00\x00' * int(seconds * SR))
    print('audio ->', os.path.basename(path), round(os.path.getsize(path) / 1024.0), 'KB')


if __name__ == '__main__':
    make_icon(os.path.join(ICON_DIR, 'icon-1024.png'), 1024, 2)
    make_icon(os.path.join(ROOT, 'preview-icon-512.png'), 512, 3)
    make_icon(os.path.join(ROOT, 'preview-icon-256.png'), 256, 3)
    make_alarm(os.path.join(RES_DIR, 'nag.wav'), 29.0)
    make_silence(os.path.join(RES_DIR, 'silence.wav'), 2.0)
    print('DONE')
