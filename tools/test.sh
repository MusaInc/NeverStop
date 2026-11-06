#!/usr/bin/env bash
# Headless test suite: tools/test.sh [filter]
cd "$(dirname "$0")/.."
mkdir -p build
timeout 300 godot --headless --import 2>&1 | grep -E "SCRIPT ERROR|Parse Error" && { echo "IMPORT/PARSE ERRORS"; exit 1; }
timeout 900 godot --headless --fixed-fps 60 -s res://tests/run_tests.gd -- "$@" 2>&1 \
  | grep -vE "^\s*$|leaked|^\s+at:|Godot Engine|^WARNING: Jolt|RID allocations|PagedAllocator|resources still|instance_notify_deleted|Orphan StringName|unclaimed string" | tee build/test.log
unit=${PIPESTATUS[0]}
if [[ -z "${1:-}" || "${1:-}" == "game" ]]; then
  timeout 1500 godot --headless --fixed-fps 60 res://scenes/main.tscn -- --gametest 2>&1 \
    | grep -E "^\s+(ok|FAIL|✗|·)|passed|SCRIPT ERROR" | tee -a build/test.log
  game=${PIPESTATUS[0]}
else
  game=0
fi
exit $(( unit + game ))
