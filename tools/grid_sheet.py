"""Tile PNGs (in the given order) into a 3-column sheet with ffmpeg xstack, 480 px cells."""
import subprocess, sys
out = sys.argv[1]
frames = sys.argv[2:]
cols = 3 if len(frames) >= 3 else len(frames)
cells = []
for i in range(len(frames)):
    c, r = i % cols, i // cols
    x = "0" if c == 0 else "+".join(["w0"] * c)
    y = "0" if r == 0 else "+".join(["h0"] * r)
    cells.append(f"{x}_{y}")
fc = "".join(f"[{i}:v]scale=480:-1[s{i}];" for i in range(len(frames)))
fc += "".join(f"[s{i}]" for i in range(len(frames)))
fc += f"xstack=inputs={len(frames)}:layout={'|'.join(cells)}:fill=black"
inputs = sum((["-i", f] for f in frames), [])
subprocess.run(["ffmpeg", "-loglevel", "error", "-y", *inputs, "-filter_complex", fc, out], check=True)
print("SHEET", out)
