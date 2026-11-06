"""Renders build/roads.json (tools/road_dump.gd) to a PNG road audit map
(numpy raster + ffmpeg for the PNG; no PIL on the VPS).
Lanes coloured by height (blue low -> orange high), connectors yellow, red
rings = lane ends with no way on (dead ends)."""
import json, subprocess, sys
import numpy as np
src = sys.argv[1] if len(sys.argv) > 1 else "build/roads.json"
out = sys.argv[2] if len(sys.argv) > 2 else "build/roads.png"
d = json.load(open(src))
xs, zs = [], []
for land in d["lands"]:
    for v in land["coast"]:
        xs.append(v[0]); zs.append(v[1])
x0, x1, z0, z1 = min(xs) - 50, max(xs) + 50, min(zs) - 50, max(zs) + 50
W = 2400
S = W / (x1 - x0)
H = int((z1 - z0) * S)
im = np.zeros((H, W, 3), np.uint8)
im[:] = (18, 32, 48)

def fill(poly, col):
    p = np.array([((x - x0) * S, (z - z0) * S) for x, z in poly])
    ymin, ymax = int(max(0, p[:, 1].min())), int(min(H - 1, p[:, 1].max()))
    n = len(p)
    for y in range(ymin, ymax + 1):
        yy = y + 0.5
        xs_ = []
        for i in range(n):
            a, b = p[i], p[(i + 1) % n]
            if (a[1] <= yy < b[1]) or (b[1] <= yy < a[1]):
                xs_.append(a[0] + (yy - a[1]) * (b[0] - a[0]) / (b[1] - a[1]))
        xs_.sort()
        for k in range(0, len(xs_) - 1, 2):
            im[y, max(0, int(xs_[k])):min(W, int(xs_[k + 1]) + 1)] = col

def line(a, b, col, w=1):
    ax, ay = (a[0] - x0) * S, (a[1] - z0) * S
    bx, by = (b[0] - x0) * S, (b[1] - z0) * S
    n = int(max(abs(bx - ax), abs(by - ay)) * 2) + 1
    t = np.linspace(0, 1, n)
    px = (ax + (bx - ax) * t).astype(int)
    py = (ay + (by - ay) * t).astype(int)
    for dx in range(-(w // 2), w // 2 + 1):
        for dy in range(-(w // 2), w // 2 + 1):
            ok = (px + dx >= 0) & (px + dx < W) & (py + dy >= 0) & (py + dy < H)
            im[py[ok] + dy, px[ok] + dx] = col

def ring(c, r, col):
    cx, cy = (c[0] - x0) * S, (c[1] - z0) * S
    for a in np.linspace(0, 6.283, 40):
        x, y = int(cx + r * np.cos(a)), int(cy + r * np.sin(a))
        if 0 <= x < W and 0 <= y < H:
            im[max(0, y - 1):y + 2, max(0, x - 1):x + 2] = col

for land in d["lands"]:
    fill(land["coast"], (44, 46, 44))
    for b in land["blocks"]:
        col = {"block": (70, 70, 74), "park": (40, 80, 45), "green": (40, 80, 45), "plaza": (90, 85, 75)}.get(b["kind"], (58, 58, 60))
        if len(b["poly"]) > 2:
            fill(b["poly"], col)
dead = []
for land in d["lands"]:
    for ln in land["lanes"]:
        pts = ln["pts"]
        for a, b in zip(pts, pts[1:]):
            h = max(0.0, min(1.0, a[1] / 40.0))
            col = (255, 210, 60) if ln["conn"] else (int(90 + 165 * h), int(170 - 40 * h), int(255 - 215 * h))
            line((a[0], a[2]), (b[0], b[2]), col)
        if not ln["loop"] and ln["ends"] == 0 and not ln["conn"]:
            dead.append(pts[-1])
for e in dead:
    ring((e[0], e[2]), 6, (255, 40, 40))
subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{W}x{H}",
                "-i", "-", out], input=im.tobytes(), check=True)
print("map", out, W, H, "dead ends:", len(dead), "scale m/px %.2f" % (1 / S))
