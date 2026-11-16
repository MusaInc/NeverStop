#!/usr/bin/env python3
"""Exercise fresh-process city generation, without a network connection or renderer."""
import pathlib
import re
import subprocess
ROOT = pathlib.Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/lcs-verification'
OUT.mkdir(parents=True, exist_ok=True)
for attempt in range(1, 6):
    with (OUT / f'startup-{attempt}.log').open('w') as log:
        result = subprocess.run(['godot', '--headless', '--fixed-fps', '60', '--path', str(ROOT),
            'res://scenes/last_car_standing.tscn', '--', '--quit-after=0.1'], stdout=log, stderr=subprocess.STDOUT, timeout=45)
    output = (OUT / f'startup-{attempt}.log').read_text()
    sites = re.search(r'LCS validated road sites: (\d+)', output)
    if result.returncode or 'SCRIPT ERROR' in output or sites is None or int(sites.group(1)) < 100:
        print(output)
        raise SystemExit(f'Startup {attempt} failed')
    print(f'Startup {attempt}/5 PASS', flush=True)
