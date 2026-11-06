#!/usr/bin/env bash
# Renders the game under Xvfb (software Vulkan, Mobile renderer) with the
# autopilot and tiles the captures into one contact sheet.
#   tools/filmstrip.sh <name> "<t1,t2,...>" [extra user args...]
# Output: screenshots/<name>_sheet.png  (individual frames alongside)
set -euo pipefail
cd "$(dirname "$0")/.."
name=$1; times=$2; shift 2
mkdir -p screenshots
rm -f screenshots/${name}_*.png
xvfb-run -a -s "-screen 0 1280x720x24" godot --rendering-method mobile --resolution 960x540 \
  --fixed-fps 30 -- --shot="$PWD/screenshots/${name}.png" --shot-at="$times" "$@" 2>&1 \
  | grep -E "SCREENSHOT|RENDER_STATS|SCRIPT ERROR|^ERROR" | grep -v leaked || true
python3 tools/contact_sheet.py screenshots/${name}_sheet.png screenshots/${name}_[0-9]*.png
