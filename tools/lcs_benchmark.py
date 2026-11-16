#!/usr/bin/env python3
"""Progressive real shared-physics bot load. GPU requires a device capture."""
import json
import pathlib
import subprocess
import time

ROOT = pathlib.Path(__file__).resolve().parents[1]
OUT = ROOT / "build/lcs-bench"
OUT.mkdir(parents=True, exist_ok=True)
reports = []
for size in (10, 25, 50, 100):
    path = OUT / f"{size}.json"
    with (OUT / f"{size}.log").open("w") as log:
        cmd = ["godot", "--headless", "--fixed-fps", "60", "--path", str(ROOT),
               "res://scenes/last_car_standing.tscn", "--", "--lcs-server", "--port=27978",
               f"--players={size}", "--queue-seconds=0", "--bench", "--match-seed=2026",
               "--quit-after=90", f"--report={path}"]
        proc = subprocess.Popen(cmd, stdout=log, stderr=subprocess.STDOUT)
        peak_rss = 0
        start = time.monotonic()
        while proc.poll() is None:
            try:
                for line in pathlib.Path(f"/proc/{proc.pid}/status").read_text().splitlines():
                    if line.startswith("VmRSS:"):
                        peak_rss = max(peak_rss, int(line.split()[1]))
            except FileNotFoundError:
                pass
            if time.monotonic() - start > 180:
                proc.terminate()
                raise RuntimeError(f"{size} timed out")
            time.sleep(0.1)
        if proc.returncode or not path.exists():
            raise RuntimeError(f"{size} failed; see {log.name}")
    report = json.loads(path.read_text())
    if report["players"] != size or report["state"] not in ("active", "finished") or report.get("max_distance_from_spawn_m", 0) < 10:
        raise RuntimeError(f"Invalid benchmark: {report}")
    report["rss_peak_mib"] = round(peak_rss / 1024, 2)
    report["wall_s"] = round(time.monotonic() - start, 2)
    report["network"] = "no network clients; see tools/lcs_load_test.py for real 100-connection wire load"
    path.write_text(json.dumps(report, indent=2) + "\n")
    reports.append(report)
    print(json.dumps(report), flush=True)
(OUT / "summary.json").write_text(json.dumps(reports, indent=2) + "\n")
