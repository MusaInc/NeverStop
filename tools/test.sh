#!/usr/bin/env bash
# Headless test suite: tools/test.sh [filter]
cd "$(dirname "$0")/.."
mkdir -p build
timeout 900 godot --headless --fixed-fps 60 -s res://tests/run_tests.gd -- "$@" 2>&1 \
  | grep -vE "^\s*$|leaked|^\s+at:|Godot Engine|^WARNING: Jolt|RID allocations|PagedAllocator|resources still|instance_notify_deleted|Orphan StringName|unclaimed string" | tee build/test.log
exit ${PIPESTATUS[0]}
