#!/bin/bash
# Test infrastructure entry point: runs every addon test suite
# headlessly inside the project directory.
#
# Succeeds (exit 0) only when Godot exits 0 AND the "ALL TESTS PASSED"
# marker is in the output, so crashes or hangs can never look green.
#
# Usage:
#   ./addons/0GnumarusGodotProjectAnalyzerSuite/tests/test.sh   # from the project root
#   GODOT_BIN=/path/to/godot ./addons/0GnumarusGodotProjectAnalyzerSuite/tests/test.sh
#   CLEAN_USER_JSON=1 ./addons/0GnumarusGodotProjectAnalyzerSuite/tests/test.sh   # wipe user/*.json first
ADDON="addons/0GnumarusGodotProjectAnalyzerSuite/tests"
set -u
__DIR__="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd)"
ROOT="$(dirname "$(dirname "$(dirname "$__DIR__")")")"
GODOT="${GODOT_BIN:-/sync/opt/godot/godot4.x86_64}"
export GODOT_BIN="$GODOT"
cd "$ROOT" || exit 1
if [ "${CLEAN_USER_JSON:-0}" = "1" ]; then
  echo "== cleaning user type files (they regenerate on demand) =="
  rm -f .godot/0GnumarusGodotProjectAnalyzerSuiteData/user/*.json
fi
echo "== ensuring native types =="
OUT_DUMP="$("$GODOT" --headless --path "$ROOT" --quit-after 600 --script res://addons/0GnumarusGodotProjectAnalyzerSuite/tests/ensure_native_types.gd 2>&1)"
CODE_DUMP=$?
echo "$OUT_DUMP" | grep -v "^Godot Engine"
if [ $CODE_DUMP -ne 0 ] || ! echo "$OUT_DUMP" | grep -q "NATIVE TYPES READY"; then
  echo "native types setup failed" >&2
  exit 1
fi
echo "== running suites =="
OUT="$("$GODOT" --headless --path "$ROOT" --quit-after 120 --script res://addons/0GnumarusGodotProjectAnalyzerSuite/tests/run_all.gd 2>&1)"
CODE=$?
echo "$OUT" | grep -v "^Godot Engine"
if [ $CODE -eq 0 ] && echo "$OUT" | grep -q "ALL TESTS PASSED"; then
  exit 0
else
  exit 1
fi
