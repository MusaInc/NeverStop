#!/usr/bin/env bash
# Copies build/web to /srv/neverstop, served publicly by Caddy at
# https://musastudios.co.uk/neverstop/ (route in /etc/caddy/Caddyfile).
# Publishing was approved by the owner on 2026-11-06; re-run only with their say-so.
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f build/web/index.wasm ] || { echo "no web build: run tools/export_web.sh first"; exit 1; }
rm -rf /srv/neverstop/*
cp -a build/web/. /srv/neverstop/
gzip -9 -k -f /srv/neverstop/index.wasm   # served precompressed (~9 MB instead of 38 MB)
echo "Published: https://musastudios.co.uk/neverstop/"
