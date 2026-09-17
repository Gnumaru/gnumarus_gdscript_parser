extends SceneTree

## Setup step for the test infrastructure (run by tests/test.sh before
## the suites): guarantees the native type database exists.
##
## Only types_info/user/ is written by the parser/analyzer during the
## tests. types_info/builtin/, types_info/classes/ and index.json are
## produced exclusively by gnumaru_godot_native_types_info_dumper, so a
## deleted types_info/ never grows them back on its own. This script
## closes that gap: if the three markers exist and are non-empty it
## exits immediately; otherwise it runs the dumper with the same Godot
## binary used for the tests (env GODOT_BIN, fallback "godot").
## Env FORCE_NATIVE_DUMP=1 regenerates even when everything is present.
##
## Success prints the "NATIVE TYPES READY" marker and exits 0; test.sh
## requires both, so a silent failure can never look green.

const Dumper = preload("res://gnumaru_godot_native_types_info_dumper.gd")

const BASE := "res://types_info"
const INDEX_FILE := "res://types_info/index.json"


func _init() -> void:
	_run()


## Fire-and-forget async entry (dump_all awaits doc downloads):
## everything, including quit(), happens in here.
func _run() -> void:
	var forced: bool = OS.get_environment("FORCE_NATIVE_DUMP") == "1"
	var d = Dumper.new()
	d.output_base = BASE
	if not forced and d.is_present():
		var counts: Array = _count_types()
		print("NATIVE TYPES READY (cached: ", int(counts[0]), " builtin, ", int(counts[1]), " classes)")
		quit(0)
		return
	var summary: Dictionary = await d.dump_all_async(Dumper.default_executable(), self)
	if not bool(summary.get("ok", false)):
		printerr("FAIL [ensure_native_types]: ", str(summary.get("error", d.last_error)))
		quit(1)
		return
	print("NATIVE TYPES READY (dumped: ", int(summary.get("builtin_count", 0)), " builtin, ", int(summary.get("class_count", 0)), " classes, ", str(summary.get("engine_version", "")), ")")
	quit(0)


## [builtin_count, class_count] from index.json (best effort).
func _count_types() -> Array:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(INDEX_FILE))
	if typeof(parsed) != TYPE_DICTIONARY:
		return [0, 0]
	return [int((parsed as Dictionary).get("builtin_count", 0)), int((parsed as Dictionary).get("class_count", 0))]
