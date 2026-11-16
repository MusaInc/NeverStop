#!/usr/bin/env python3
"""Real ENet integration check. Logs retained under build/lcs-network/."""
import pathlib
import subprocess
import time

ROOT = pathlib.Path(__file__).resolve().parents[1]
OUT = ROOT / "build/lcs-network"
OUT.mkdir(parents=True, exist_ok=True)
BASE = ["godot", "--headless", "--path", str(ROOT), "-s", "res://tests/lcs_network_peer.gd", "--"]
processes = []
files = []
try:
    def start(name, options):
        log = (OUT / f"{name}.log").open("w")
        files.append(log)
        proc = subprocess.Popen(BASE + options, stdout=log, stderr=subprocess.STDOUT)
        processes.append((name, proc))
        return proc
    server = start("server", ["--role=server", "--lcs-server", "--port=27979", "--players=2", "--no-bots", "--queue-seconds=120"])
    deadline = time.monotonic() + 35
    while "NET_SERVER_READY" not in (OUT / "server.log").read_text():
        if server.poll() is not None or time.monotonic() > deadline:
            raise RuntimeError("Server failed to start")
        time.sleep(0.2)
    for name in ["Reconnect", "Opponent"]:
        start(name, ["--role=client", "--join=127.0.0.1", "--port=27979", f"--name={name}"])
        # Establish deterministic competitor IDs.
        time.sleep(5)
    for name, proc in processes:
        code = proc.wait(timeout=65)
        print((OUT / f"{name}.log").read_text())
        if code != 0 or 'SCRIPT ERROR' in (OUT / f"{name}.log").read_text() or f"NET_RESULT {'server' if name == 'server' else 'client'} PASS" not in (OUT / f"{name}.log").read_text():
            raise RuntimeError(f"{name} failed ({code})")
    print("ENet integration: PASS")
finally:
    for _, proc in processes:
        if proc.poll() is None:
            proc.terminate()
            proc.wait(timeout=10)
    for log in files:
        log.close()
