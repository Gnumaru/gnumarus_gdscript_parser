#!/bin/bash
# Test infrastructure entry point: runs every tests/test_*.gd suite
# headlessly inside this project's own directory.
#
# Succeeds (exit 0) only when Godot exits 0 AND the "ALL TESTS PASSED"
# marker is in the output, so crashes or hangs can never look green.
#
# Usage:
#   ./tests/test.sh            # from the project root
#   GODOT_BIN=/path/to/godot ./tests/test.sh
set -u
__DIR__="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd)"
ROOT="$(dirname "$__DIR__")"
GODOT="${GODOT_BIN:-/sync/opt/godot/godot4.x86_64}"
export GODOT_BIN="$GODOT"
cd "$ROOT" || exit 1
echo "== ensuring native types =="
OUT_DUMP="$("$GODOT" --headless --path "$ROOT" --quit-after 600 --script res://tests/ensure_native_types.gd 2>&1)"
CODE_DUMP=$?
echo "$OUT_DUMP" | grep -v "^Godot Engine"
if [ $CODE_DUMP -ne 0 ] || ! echo "$OUT_DUMP" | grep -q "NATIVE TYPES READY"; then
  echo "native types setup failed" >&2
  exit 1
fi
echo "== running suites =="
OUT="$("$GODOT" --headless --path "$ROOT" --quit-after 120 --script res://tests/run_all.gd 2>&1)"
CODE=$?
echo "$OUT" | grep -v "^Godot Engine"
if [ $CODE -eq 0 ] && echo "$OUT" | grep -q "ALL TESTS PASSED"; then
  exit 0
else
  exit 1
fi
