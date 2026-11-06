#!/usr/bin/env bash
# City Swing build & test workflow (Linux VPS, headless).
#
#   tools/build.sh            import + tests + exports (Linux smoke test, iOS Xcode project)
#   tools/build.sh assets     also regenerate Blender models and synthesised audio first
#   tools/build.sh courses    also re-record Time Trial courses (after physics/layout changes)
#   tools/build.sh shots      also render a screenshot contact sheet for visual review
#
# Steps fail fast; the script exits non-zero on any failing test or export check.
set -euo pipefail
cd "$(dirname "$0")/.."
ARGS=" $* "
step() { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }

if [[ "$ARGS" == *" assets "* ]]; then
  step "Blender kit (procedural models -> assets/models/*.glb)"
  blender -b --factory-startup --python tools/blender/build_kit.py -- assets/models 2>&1 | grep -E "KIT|Error|Traceback"
  blender -b --factory-startup --python tools/blender/build_street.py -- assets/models 2>&1 | grep -E "KIT|Error|Traceback"
  blender -b --factory-startup --python tools/blender/build_residences.py -- assets/models
  # build_kit contains a legacy hero; always replace it with the skinned asset.
  blender -b --factory-startup --python tools/blender/build_character.py -- assets/models
  step "Synthesised audio (-> assets/audio/*.wav)"
  python3 tools/audio/gen_audio.py assets/audio | grep -E "DONE|Error"
fi

step "Import project"
godot --headless --import 2>&1 | grep -E "SCRIPT ERROR|Parse Error" && { echo "import errors"; exit 1; } || true

if [[ "$ARGS" == *" courses "* ]]; then
  step "Record Time Trial courses from autopilot flights"
  godot --headless --fixed-fps 60 -s res://tools/make_courses.gd 2>&1 | grep -E "OK|DNF|wrote"
fi

step "Tests (physics unit, scene, city, modes)"
set +e
godot --headless --fixed-fps 60 -s res://tests/run_tests.gd 2>&1 | grep -vE "^\s*$|leaked|^\s+at:|Godot Engine|^WARNING: Jolt" | tee build/test.log
status=${PIPESTATUS[0]}
set -e
[[ $status -eq 0 ]] || { echo "TESTS FAILED ($status)"; exit 1; }

step "Linux export + packaged self-test"
mkdir -p build/linux
godot --headless --export-release "Linux" build/linux/CitySwing.x86_64 2>&1 | grep -E "^ERROR" | grep -v "resources still in use" || true
selftest=$(build/linux/CitySwing.x86_64 --headless -- --selftest 2>&1 | grep SELFTEST || true)
echo "$selftest"
[[ "$selftest" == *" OK" ]] || { echo "PACKAGED SELF-TEST FAILED"; exit 1; }

step "iOS Xcode project export"
tools/export_ios.sh

if [[ "$ARGS" == *" shots "* ]]; then
  step "Screenshot contact sheet"
  tools/filmstrip.sh review "3,7,11,15" --mode=free --bot=expert --touch --perf
fi

step "Done"
echo "Tests: build/test.log   Linux build: build/linux/   iOS project: build/ios/ (zip: build/CitySwing-ios-xcode.zip)"
