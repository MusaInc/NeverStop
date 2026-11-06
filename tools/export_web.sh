#!/usr/bin/env bash
# Exports the playable web test build (Compatibility renderer, no threads).
# Output: build/web/index.html (+ .pck/.wasm). Serve it locally, e.g.
#   python3 -m http.server -d build/web 8160
# Never uploaded anywhere by this script.
set -euo pipefail
cd "$(dirname "$0")/.."
rm -rf build/web && mkdir -p build/web
godot --headless --export-release "Web" build/web/index.html 2>&1 | grep -E "^ERROR" | grep -v "resources still in use" || true
test -f build/web/index.pck || { echo "Web export FAILED"; exit 1; }
du -sh build/web
