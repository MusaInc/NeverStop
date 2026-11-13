#!/usr/bin/env bash
# Bakes assets/ui/splash.png from src/ui/splash_art.gd (needs a renderer: Xvfb).
set -euo pipefail
cd "$(dirname "$0")/.."
timeout 120 xvfb-run -a -s "-screen 0 1920x1080x24" godot --rendering-method mobile -s res://tools/make_splash.gd 2>&1 \
  | grep -E "SPLASH|SCRIPT ERROR|^ERROR" || true
timeout 300 godot --headless --import >/dev/null 2>&1 || true
