"""Tile PNG frames into a 2-column contact sheet using ffmpeg's xstack."""
import subprocess, sys

out = sys.argv[1]
frames = sorted(sys.argv[2:], key=lambda f: int(f.rsplit("_", 1)[1].split(".")[0]))
if not frames:
    sys.exit("no frames")
cols = 2 if len(frames) > 1 else 1
cells = []
for i in range(len(frames)):
    x = "0" if i % cols == 0 else "w0"
    r = i // cols
    y = "0" if r == 0 else "+".join(["h0"] * r)
    cells.append(f"{x}_{y}")
fc = "".join(f"[{i}:v]scale=640:-1[s{i}];" for i in range(len(frames)))
fc += "".join(f"[s{i}]" for i in range(len(frames)))
fc += f"xstack=inputs={len(frames)}:layout={'|'.join(cells)}:fill=black" if len(frames) > 1 else "null"
inputs = sum((["-i", f] for f in frames), [])
subprocess.run(["ffmpeg", "-loglevel", "error", "-y", *inputs, "-filter_complex", fc, out], check=True)
print("SHEET", out)
