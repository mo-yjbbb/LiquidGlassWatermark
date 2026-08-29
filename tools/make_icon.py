# -*- coding: utf-8 -*-
"""生成液态玻璃水印的图标 PNG（不依赖 Pillow / cairosvg / Java）。

输出 432x432（=108dp @ xxxhdpi）的 RGBA PNG，放在 res/drawable-nodpi/ 下，
作为自适应图标的图层。用 PNG 而不是 vector，是因为 MIUI 的图标渲染路径上
vector + <aapt:attr> 渐变会 inflate 失败，导致系统回退到默认机器人图标。
"""
import math, os, struct, zlib

S = 432                 # 输出边长（像素）
K = S / 108.0           # 108 单位画布 -> 像素
SS = 4                  # 抗锯齿超采样

# ---------------- 基础工具 ----------------

def new_buf():
    return [0.0] * (S * S * 4)

def blend(buf, x, y, rgb, a):
    if a <= 0.0:
        return
    a = min(1.0, max(0.0, a))
    i = (y * S + x) * 4
    dst_a = buf[i + 3] / 255.0
    out_a = a + dst_a * (1.0 - a)
    if out_a <= 0.0:
        return
    for c in range(3):
        src = rgb[c]
        dst = buf[i + c]
        buf[i + c] = (src * a + dst * dst_a * (1.0 - a)) / out_a
    buf[i + 3] = out_a * 255.0

def bezier(p0, p1, p2, p3, n=48):
    out = []
    for i in range(n + 1):
        t = i / float(n)
        u = 1.0 - t
        x = u*u*u*p0[0] + 3*u*u*t*p1[0] + 3*u*t*t*p2[0] + t*t*t*p3[0]
        y = u*u*u*p0[1] + 3*u*u*t*p1[1] + 3*u*t*t*p2[1] + t*t*t*p3[1]
        out.append((x, y))
    return out

def svg_arc(p0, rx, ry, phi_deg, large, sweep, p1, n=64):
    """SVG 椭圆弧 endpoint -> center 参数化（W3C 实现说明 F.6.5）。"""
    phi = math.radians(phi_deg)
    cosp, sinp = math.cos(phi), math.sin(phi)
    dx2, dy2 = (p0[0] - p1[0]) / 2.0, (p0[1] - p1[1]) / 2.0
    x1p = cosp * dx2 + sinp * dy2
    y1p = -sinp * dx2 + cosp * dy2
    rx, ry = abs(rx), abs(ry)
    lam = (x1p*x1p) / (rx*rx) + (y1p*y1p) / (ry*ry)
    if lam > 1.0:
        s = math.sqrt(lam)
        rx, ry = rx * s, ry * s
    num = rx*rx*ry*ry - rx*rx*y1p*y1p - ry*ry*x1p*x1p
    den = rx*rx*y1p*y1p + ry*ry*x1p*x1p
    if den == 0:
        return [p0, p1]
    co = math.sqrt(max(0.0, num / den))
    if large == sweep:
        co = -co
    cxp, cyp = co * rx * y1p / ry, -co * ry * x1p / rx
    cx = cosp*cxp - sinp*cyp + (p0[0] + p1[0]) / 2.0
    cy = sinp*cxp + cosp*cyp + (p0[1] + p1[1]) / 2.0
    def ang(ux, uy, vx, vy):
        d = math.hypot(ux, uy) * math.hypot(vx, vy)
        if d == 0:
            return 0.0
        c = max(-1.0, min(1.0, (ux*vx + uy*vy) / d))
        a = math.acos(c)
        return -a if (ux*vy - uy*vx) < 0 else a
    th1 = ang(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
    dth = ang((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
    if not sweep and dth > 0:
        dth -= 2 * math.pi
    elif sweep and dth < 0:
        dth += 2 * math.pi
    out = []
    for i in range(n + 1):
        th = th1 + dth * i / float(n)
        ct, st = math.cos(th), math.sin(th)
        x = cosp*rx*ct - sinp*ry*st + cx
        y = sinp*rx*ct + cosp*ry*st + cy
        out.append((x, y))
    return out

def fill_polygon(buf, poly, color_fn):
    """扫描线填充；水平方向解析覆盖率，垂直方向 SS 倍超采样。"""
    pts = [(p[0] * K, p[1] * K) for p in poly]
    n = len(pts)
    if n < 3:
        return
    ymin = max(0, int(math.floor(min(p[1] for p in pts))))
    ymax = min(S - 1, int(math.ceil(max(p[1] for p in pts))))
    edges = [(pts[i], pts[(i + 1) % n]) for i in range(n)]
    for y in range(ymin, ymax + 1):
        for s in range(SS):
            yy = y + (s + 0.5) / SS
            xs = []
            for (x1, y1), (x2, y2) in edges:
                if (y1 <= yy < y2) or (y2 <= yy < y1):
                    xs.append(x1 + (yy - y1) * (x2 - x1) / (y2 - y1))
            if len(xs) < 2:
                continue
            xs.sort()
            for k in range(0, len(xs) - 1, 2):
                xa, xb = xs[k], xs[k + 1]
                for x in range(max(0, int(math.floor(xa))), min(S - 1, int(math.floor(xb))) + 1):
                    cov = min(x + 1.0, xb) - max(float(x), xa)
                    if cov <= 0.0:
                        continue
                    r, g, b, a = color_fn((x + 0.5) / K, (y + 0.5) / K)
                    blend(buf, x, y, (r, g, b), a * cov / SS)

def stroke_path(buf, path, width, rgb, alpha, cap='round'):
    """沿路径盖圆形笔刷；round cap 由端点圆自然形成。"""
    r = width / 2.0
    step = max(0.35, r * 0.5)
    acc = [0.0]
    pts = []
    for i in range(len(path) - 1):
        x1, y1 = path[i]
        x2, y2 = path[i + 1]
        seg = math.hypot(x2 - x1, y2 - y1)
        m = max(1, int(seg / step))
        for j in range(m):
            t = j / float(m)
            pts.append((x1 + (x2 - x1) * t, y1 + (y2 - y1) * t))
    pts.append(path[-1])
    stamp_circles(buf, pts, r, rgb, alpha)

def stamp_circles(buf, pts, r, rgb, alpha, ss=4):
    pr = r * K
    for (cx, cy) in pts:
        pcx, pcy = cx * K, cy * K
        x0 = max(0, int(pcx - pr - 1)); x1 = min(S - 1, int(pcx + pr + 1))
        y0 = max(0, int(pcy - pr - 1)); y1 = min(S - 1, int(pcy + pr + 1))
        for y in range(y0, y1 + 1):
            for x in range(x0, x1 + 1):
                hit = 0
                for sy in range(ss):
                    py = y + (sy + 0.5) / ss
                    for sx in range(ss):
                        px = x + (sx + 0.5) / ss
                        dx, dy = px - pcx, py - pcy
                        if dx * dx + dy * dy <= pr * pr:
                            hit += 1
                if hit:
                    blend(buf, x, y, rgb, alpha * hit / float(ss * ss))

def fill_circle(buf, cx, cy, r, rgb, alpha):
    stamp_circles(buf, [(cx, cy)], r, rgb, alpha, ss=5)

def offset_polygon(poly, dist):
    """沿外法线外扩多边形（用于描边）。"""
    n = len(poly)
    out = []
    for i in range(n):
        p0, p1, p2 = poly[(i - 1) % n], poly[i], poly[(i + 1) % n]
        e1 = (p1[0] - p0[0], p1[1] - p0[1])
        L1 = math.hypot(*e1) or 1.0
        n1 = (-e1[1] / L1, e1[0] / L1)
        e2 = (p2[0] - p1[0], p2[1] - p1[1])
        L2 = math.hypot(*e2) or 1.0
        n2 = (-e2[1] / L2, e2[0] / L2)
        nx, ny = n1[0] + n2[0], n1[1] + n2[1]
        L = math.hypot(nx, ny)
        if L < 1e-6:
            out.append((p1[0] + n1[0] * dist, p1[1] + n1[1] * dist))
        else:
            s = dist / max(math.hypot(n1[0] + n2[0], n1[1] + n2[1]) / 2.0, 0.35)
            out.append((p1[0] + nx / L * s, p1[1] + ny / L * s))
    return out

def poly_area(poly):
    a = 0.0
    for i in range(len(poly)):
        x1, y1 = poly[i]
        x2, y2 = poly[(i + 1) % len(poly)]
        a += x1 * y2 - x2 * y1
    return a / 2.0

# ---------------- 形状定义（108 单位画布） ----------------

DROP_PATH = (
    bezier((54, 26), (64, 41), (78, 47), (78, 62), 44)
    + svg_arc((78, 62), 24, 24, 0, 1, 1, (30, 62), 72)[1:]
    + bezier((30, 62), (30, 47), (44, 41), (54, 26), 44)[1:]
)
STAR_PATH = (
    bezier((34, 33.5), (35.1, 39.7), (36.8, 41.4), (43, 42.5), 24)
    + bezier((43, 42.5), (36.8, 43.6), (35.1, 45.3), (34, 51.5), 24)[1:]
    + bezier((34, 51.5), (32.9, 45.3), (31.2, 43.6), (25, 42.5), 24)[1:]
    + bezier((25, 42.5), (31.2, 41.4), (32.9, 39.7), (34, 33.5), 24)[1:]
)
HIGHLIGHT_ARC = svg_arc((38, 58), 17, 17, 0, 0, 1, (51, 42), 40)
SHEEN_ARC = svg_arc((40, 68), 15, 9, 0, 0, 0, (68, 68), 48)

# ---------------- 背景 ----------------

BG_STOPS = [(0.0, (0x2A, 0x16, 0x68)), (0.5, (0x1B, 0x0E, 0x3F)), (1.0, (0x0D, 0x0B, 0x22))]
GLOWS = [((32, 92), 52, (0xFF, 0x4F, 0xA3), 0.95),
         ((84, 16), 40, (0x57, 0xC8, 0xFF), 0.85),
         ((24, 28), 23, (0xA7, 0x8B, 0xFF), 0.40)]

def gradient_at(f):
    for i in range(len(BG_STOPS) - 1):
        f0, c0 = BG_STOPS[i]
        f1, c1 = BG_STOPS[i + 1]
        if f0 <= f <= f1:
            t = 0.0 if f1 == f0 else (f - f0) / (f1 - f0)
            return tuple(c0[j] + (c1[j] - c0[j]) * t for j in range(3))
    return BG_STOPS[-1][1]

def make_background():
    buf = new_buf()
    for y in range(S):
        v = (y + 0.5) / K
        for x in range(S):
            u = (x + 0.5) / K
            f = min(1.0, max(0.0, (u / 108.0 + v / 108.0) * 0.5))
            rgb = gradient_at(f)
            # 径向光晕叠加
            rr, gg, bb = rgb
            for (gx, gy), gr, gcol, ga in GLOWS:
                d = math.hypot(u - gx, v - gy)
                if d < gr:
                    t = 1.0 - d / gr
                    a = ga * t * t
                    rr = rr * (1 - a) + gcol[0] * a
                    gg = gg * (1 - a) + gcol[1] * a
                    bb = bb * (1 - a) + gcol[2] * a
            blend(buf, x, y, (rr, gg, bb), 1.0)
    return buf

# ---------------- 前景 ----------------

def drop_color(u, v):
    """水滴本体：自上而下的白色渐变（Android angle=270 → 顶部亮）。"""
    t = min(1.0, max(0.0, (v - 26.0) / 60.0))
    if t < 0.5:
        a = 0.96 + (0.77 - 0.96) * (t / 0.5)
    else:
        a = 0.77 + (0.25 - 0.77) * ((t - 0.5) / 0.5)
    return (255.0, 255.0, 255.0, a)

def make_foreground():
    buf = new_buf()
    outer = offset_polygon(DROP_PATH, 1.3)
    if poly_area(outer) < poly_area(DROP_PATH):      # 法线方向兜底
        outer = offset_polygon(DROP_PATH, -1.3)
    fill_polygon(buf, outer, lambda u, v: (255.0, 255.0, 255.0, 1.0))   # 描边
    fill_polygon(buf, DROP_PATH, drop_color)                            # 本体
    stroke_path(buf, HIGHLIGHT_ARC, 4.2, (255.0, 255.0, 255.0), 1.0)    # 高光弧
    stroke_path(buf, SHEEN_ARC, 2.4, (255.0, 255.0, 255.0), 0.45)       # 反光线
    fill_circle(buf, 64, 74, 4.0, (255.0, 255.0, 255.0), 0.35)          # 内部气泡
    fill_polygon(buf, STAR_PATH, lambda u, v: (255.0, 255.0, 255.0, 1.0))
    return buf

def make_monochrome():
    buf = new_buf()
    fill_polygon(buf, DROP_PATH, lambda u, v: (255.0, 255.0, 255.0, 1.0))
    fill_polygon(buf, STAR_PATH, lambda u, v: (255.0, 255.0, 255.0, 1.0))
    return buf

# ---------------- PNG 输出 ----------------

def write_png(path, buf, opaque=False):
    rows = []
    for y in range(S):
        row = bytearray()
        base = y * S * 4
        for x in range(S):
            i = base + x * 4
            row += bytes((int(min(255.0, max(0.0, buf[i]))),
                          int(min(255.0, max(0.0, buf[i + 1]))),
                          int(min(255.0, max(0.0, buf[i + 2]))),
                          255 if opaque else int(min(255.0, max(0.0, buf[i + 3])))))
        rows.append(row)
    raw = b''.join(b'\x00' + bytes(r) for r in rows)

    def chunk(tag, data):
        return (struct.pack('>I', len(data)) + tag + data
                + struct.pack('>I', zlib.crc32(tag + data) & 0xffffffff))

    png = b'\x89PNG\r\n\x1a\n'
    png += chunk(b'IHDR', struct.pack('>IIBBBBB', S, S, 8, 6, 0, 0, 0))
    png += chunk(b'IDAT', zlib.compress(raw, 9))
    png += chunk(b'IEND', b'')
    with open(path, 'wb') as f:
        f.write(png)

if __name__ == '__main__':
    out_dir = os.path.join('LiquidGlassWatermark', 'Android', 'app', 'src', 'main',
                           'res', 'drawable-nodpi')
    os.makedirs(out_dir, exist_ok=True)
    print('drop area', round(poly_area(DROP_PATH), 1), 'expected ~2400')
    print('star area', round(poly_area(STAR_PATH), 1))

    bg = make_background()
    write_png(os.path.join(out_dir, 'ic_launcher_background.png'), bg, opaque=True)
    print('background done')

    fg = make_foreground()
    write_png(os.path.join(out_dir, 'ic_launcher_foreground.png'), fg)
    print('foreground done')

    write_png(os.path.join(out_dir, 'ic_launcher_monochrome.png'), make_monochrome())
    print('monochrome done')

    # legacy：背景 + 前景合成的不透明图标，供 App 内 UI 与非自适应兜底使用
    legacy = list(bg)
    for y in range(S):
        for x in range(S):
            i = (y * S + x) * 4
            a = fg[i + 3] / 255.0
            if a > 0:
                for c in range(3):
                    legacy[i + c] = legacy[i + c] * (1 - a) + fg[i + c] * a
                legacy[i + 3] = 255.0
    write_png(os.path.join(out_dir, 'ic_launcher_legacy.png'), legacy, opaque=True)
    print('legacy done')
