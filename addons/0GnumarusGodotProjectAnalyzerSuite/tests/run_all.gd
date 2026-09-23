extends SceneTree

## Single entry point for the whole test infrastructure.
##
## Loads every tests/test_*.gd suite (each exposes `run() -> Dictionary`
## with `suite`/`passed`/`failed`), prints a per-suite line plus the
## grand total, and exits 0 only when every check passed.
## Loading is defensive: a suite that fails to load still counts as a
## failure, so _init() always reaches quit() with the right code.
##
## Hermeticity: suites share one process and every analyze() writes
## data-dir user/*.json files — including suites using virtual
## res://tests/tmp_* paths that never exist on disk. A leaked tuple/
## struct/class JSON would false-positive later conflict/known-type
## checks in the SAME run (e.g. a phantom T1.json vs @template T1),
## so run_all snapshots user/ up front and deletes everything new at
## the end. Pre-existing files are never touched.

const FullScan = preload("res://addons/0GnumarusGodotProjectAnalyzerSuite/GnumarusGodotProjectAnalyzerSuiteFullScanImpl.gd")

func _user_dir() -> String:
	return ProjectSettings.globalize_path(FullScan.data_dir() + "/user")


func _user_files() -> Array:
	var dir := _user_dir()
	if not DirAccess.dir_exists_absolute(dir):
		return []
	return DirAccess.get_files_at(dir)


func _clean_user_files(before: Array) -> void:
	var base := _user_dir() + "/"
	for f in _user_files():
		if not before.has(f):
			DirAccess.remove_absolute(base + str(f))

func _init() -> void:
	var suite_files: Array = [
		"res://addons/0GnumarusGodotProjectAnalyzerSuite/tests/test_fixture.gd",
		"res://addons/0GnumarusGodotProjectAnalyzerSuite/tests/test_native_guard.gd",
		"res://addons/0GnumarusGodotProjectAnalyzerSuite/tests/test_classdb_merge.gd",
		"res://addons/0GnumarusGodotProjectAnalyzerSuite/tests/test_doc_fetch.gd",
		"res://addons/0GnumarusGodotProjectAnalyzerSuite/tests/test_deprecated.gd",
		"res://addons/0GnumarusGodotProjectAnalyzerSuite/tests/test_private.gd",
		"res://addons/0GnumarusGodotProjectAnalyzerSuite/tests/test_return.gd",
		"res://addons/0GnumarusGodotProjectAnalyzerSuite/tests/test_var.gd",
		"res://addons/0GnumarusGodotProjectAnalyzerSuite/tests/test_param.gd",
		"res://addons/0GnumarusGodotProjectAnalyzerSuite/tests/test_tuple.gd",
		"res://addons/0GnumarusGodotProjectAnalyzerSuite/tests/test_alias.gd",
		"res://addons/0GnumarusGodotProjectAnalyzerSuite/tests/test_template.gd",
		"res://addons/0GnumarusGodotProjectAnalyzerSuite/tests/test_generic_call.gd",
		"res://addons/0GnumarusGodotProjectAnalyzerSuite/tests/test_generic.gd",
		"res://addons/0GnumarusGodotProjectAnalyzerSuite/tests/test_type_expr.gd",
		"res://addons/0GnumarusGodotProjectAnalyzerSuite/tests/test_struct.gd",
		"res://addons/0GnumarusGodotProjectAnalyzerSuite/tests/test_virtual.gd",
		"res://addons/0GnumarusGodotProjectAnalyzerSuite/tests/test_interface.gd",
		"res://addons/0GnumarusGodotProjectAnalyzerSuite/tests/test_implements.gd",
		"res://addons/0GnumarusGodotProjectAnalyzerSuite/tests/test_flow.gd",
		"res://addons/0GnumarusGodotProjectAnalyzerSuite/tests/test_reuse.gd",
		"res://addons/0GnumarusGodotProjectAnalyzerSuite/tests/test_editor_bar.gd",
		"res://addons/0GnumarusGodotProjectAnalyzerSuite/tests/test_scene.gd",
		"res://addons/0GnumarusGodotProjectAnalyzerSuite/tests/test_uid_cache.gd",
		"res://addons/0GnumarusGodotProjectAnalyzerSuite/tests/test_resource_integrity.gd",
		"res://addons/0GnumarusGodotProjectAnalyzerSuite/tests/test_null.gd",
		"res://addons/0GnumarusGodotProjectAnalyzerSuite/tests/test_notnull.gd",
		"res://addons/0GnumarusGodotProjectAnalyzerSuite/tests/test_nullable.gd",
		"res://addons/0GnumarusGodotProjectAnalyzerSuite/tests/test_roster.gd",
		"res://addons/0GnumarusGodotProjectAnalyzerSuite/tests/test_full_scan.gd",
		"res://addons/0GnumarusGodotProjectAnalyzerSuite/tests/test_dock.gd",
		"res://addons/0GnumarusGodotProjectAnalyzerSuite/tests/test_scan_worker.gd",
	]
	var total_p := 0
	var total_f := 0
	var user_before := _user_files()
	for f in suite_files:
		var scr: Variant = load(f)
		if not (scr is Script):
			total_f += 1
			printerr("FAIL [run_all]: cannot load ", f)
			continue
		var inst: Variant = (scr as Script).new()
		if not (inst as Object).has_method("run"):
			total_f += 1
			printerr("FAIL [run_all]: suite has no run(): ", f)
			continue
		var r: Variant = inst.call("run")
		if not (r is Dictionary) or not (r as Dictionary).has("suite") or not (r as Dictionary).has("passed") or not (r as Dictionary).has("failed"):
			total_f += 1
			printerr("FAIL [run_all]: suite returned malformed result (mid-run crash?): ", f)
			continue
		total_p += int((r as Dictionary).get("passed", 0))
		total_f += int((r as Dictionary).get("failed", 0))
		print("SUITE ", str((r as Dictionary).get("suite", "?")), ": PASS ", int((r as Dictionary).get("passed", 0)), " FAIL ", int((r as Dictionary).get("failed", 0)))
	_clean_user_files(user_before)
	print("TOTAL PASS: ", total_p, " FAIL: ", total_f)
	if total_f == 0:
		print("ALL TESTS PASSED")
		quit(0)
	else:
		printerr("TESTS FAILED")
		quit(1)
