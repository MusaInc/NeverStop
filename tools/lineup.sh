#!/usr/bin/env bash
# Showroom renders of cars in the game's real lighting, tiled into a sheet.
#   tools/lineup.sh "kestrel,marlin,..." [name]   -> screenshots/lineup_<name>_sheet.png
set -euo pipefail
cd "$(dirname "$0")/.."
ids=$1; name=${2:-cars}
out="$PWD/screenshots/lineup_$name"
rm -rf "$out"; mkdir -p "$out"
timeout 900 xvfb-run -a -s "-screen 0 1280x720x24" godot --rendering-method mobile --resolution 960x540 \
  -- --lineup="$ids" --lineup-out="$out" --nopolice --nociv --at=-60,-17,270 --time=${LINEUP_TIME:-15} --save=user://scratch_save.json 2>&1 \
  | grep -E "LINEUP|SCRIPT ERROR|^ERROR" | grep -v leaked | tail -3 || true
files=()
for id in ${ids//,/ }; do for v in front rear side; do [ -f "$out/${id}_$v.png" ] && files+=("$out/${id}_$v.png"); done; done
python3 tools/grid_sheet.py screenshots/lineup_${name}_sheet.png "${files[@]}"
