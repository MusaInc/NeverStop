# Build, test, export

Requirements on the VPS: Godot 4.5.1 (`~/opt/godot`, export templates in
`~/.local/share/godot/export_templates/4.5.1.stable`), Blender 4.5 (only to
rebuild vehicles), Python 3 + numpy (sound set), ffmpeg (contact sheets),
xvfb-run (rendered captures), Playwright (web test; uses FireDev's copy).

## Day to day
- `tools/test.sh` – unit + physics + road-graph suite (`tests/test_*.gd`, run
  as a SceneTree script), then the whole-game suite (`tests/game_tests.gd`,
  run inside the real main scene with `--gametest`). Filter: `tools/test.sh test_vehicle`.
- `tools/build.sh` – import, tests, Linux export + packaged `--selftest`,
  web export, iOS Xcode project. `assets` regenerates vehicles + sounds first;
  `shots` renders a review contact sheet.
- Benchmarks: `godot --headless --fixed-fps 60 res://scenes/main.tscn -- --play --bot --scenario=swarm --bench --quit-after=60 --save=user://scratch_save.json`
  (see docs/PERFORMANCE.md).
- Captures always take `--save=user://scratch_save.json` so they never touch a real profile.

## Web test build
`tools/export_web.sh` → `build/web/` (Compatibility renderer, no threads,
~57 MB). Serve locally (`python3 -m http.server -d build/web 8161`) and run
`node tools/web/web_test.mjs http://127.0.0.1:8161/index.html screenshots/web chromium`
(emulated iPhone 13 landscape, real touch events; `?debug=1` publishes
`window.__ns`). Nothing is uploaded anywhere – publishing needs approval.

## iOS
`IOS_TEAM_ID=XXXXXXXXXX tools/export_ios.sh` writes an Xcode project to
`build/ios/NeverStop.xcodeproj` (+ zip). Bundle id `com.musastudios.neverstop`,
iPhone only, landscape, iOS 15+, no capabilities, no tracking. The VPS cannot
compile, sign or run it: on a Mac, open the project, set the team/signing,
build to a device, then use Settings → Show performance during a chase to read
real FPS. Nothing has been run on an iPhone yet.
