#!/usr/bin/env python3
"""One real physics server, 100 independent lightweight ENet clients on loopback."""
import pathlib
import subprocess
import time
ROOT = pathlib.Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/lcs-network'
OUT.mkdir(parents=True, exist_ok=True)
with (OUT / 'load-server.log').open('w') as log:
    server = subprocess.Popen(['godot', '--headless', '--path', str(ROOT), 'res://scenes/last_car_standing.tscn', '--',
        '--lcs-server', '--players=100', '--no-bots', '--queue-seconds=120', '--port=27976', '--bench',
        '--quit-after=40', '--report=' + str(OUT / 'load-server.json')], stdout=log, stderr=subprocess.STDOUT)
    try:
        deadline = time.monotonic() + 30
        while 'LCS listening' not in (OUT / 'load-server.log').read_text():
            if server.poll() is not None or time.monotonic() > deadline:
                raise RuntimeError('Load server failed to start')
            time.sleep(.2)
        with (OUT / 'load-clients.log').open('w') as clients_log:
            result = subprocess.run(['godot', '--headless', '--path', str(ROOT), '-s', 'res://tests/lcs_load.gd'],
                stdout=clients_log, stderr=subprocess.STDOUT, timeout=50)
        print((OUT / 'load-clients.log').read_text()[-5000:])
        if result.returncode or 'SCRIPT ERROR' in (OUT / 'load-clients.log').read_text():
            raise RuntimeError('100-client load failed')
        server.wait(timeout=30)
        if server.returncode or 'SCRIPT ERROR' in (OUT / 'load-server.log').read_text():
            raise RuntimeError('Load server failed')
        print((OUT / 'load-server.json').read_text())
    finally:
        if server.poll() is None:
            server.terminate()
            server.wait(timeout=10)
