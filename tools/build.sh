#!/usr/bin/env bash
# NEVER STOP build & test workflow (Linux VPS, headless).
#
#   tools/build.sh            import + tests + Linux export (packaged self-test) + Web + iOS Xcode project
#   tools/build.sh assets     also regenerate vehicles (Blender) and the synthesised sound set first
#   tools/build.sh shots      also render a gameplay contact sheet for visual review
#
# Fails fast; exits non-zero on any failing test or export check.
set -euo pipefail
cd "$(dirname "$0")/.."
ARGS=" $* "
step() { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }
mkdir -p build

if [[ "$ARGS" == *" assets "* ]]; then
  step "Vehicles (Blender -> assets/vehicles/*.glb)"
  blender -b --factory-startup --python tools/blender/build_vehicles.py -- assets/vehicles 2>&1 | grep -E "KIT|Error|Traceback|DONE"
  step "Sound set (-> assets/audio/*.wav)"
  python3 tools/audio/gen_sounds.py assets/audio | grep -E "DONE|Error"
fi

step "Import project"
godot --headless --import 2>&1 | grep -E "SCRIPT ERROR|Parse Error" && { echo "import errors"; exit 1; } || true

step "Tests"
tools/test.sh || { echo "TESTS FAILED"; exit 1; }

step "Linux export + packaged self-test"
mkdir -p build/linux
godot --headless --export-release "Linux" build/linux/NeverStop.x86_64 2>&1 | grep -E "^ERROR" | grep -v "resources still in use" || true
selftest=$(timeout 300 build/linux/NeverStop.x86_64 --headless --fixed-fps 60 -- --selftest 2>&1 | grep SELFTEST || true)
echo "$selftest"
[[ "$selftest" == *": OK" ]] || { echo "PACKAGED SELF-TEST FAILED"; exit 1; }

step "Web export"
tools/export_web.sh

step "iOS Xcode project export"
tools/export_ios.sh

if [[ "$ARGS" == *" shots "* ]]; then
  step "Screenshot contact sheet"
  tools/filmstrip.sh review "6,14,22,30" --play --bot --heat=3 --seed=5 --save=user://scratch_save.json
fi

step "Done"
echo "Tests: build/test.log  Linux: build/linux/  Web: build/web/  iOS: build/ios/ (zip: build/NeverStop-ios-xcode.zip)"
