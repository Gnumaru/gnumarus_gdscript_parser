extends SceneTree

## Single entry point for the whole test infrastructure.
##
## Loads every tests/test_*.gd suite (each exposes `run() -> Dictionary`
## with `suite`/`passed`/`failed`), prints a per-suite line plus the
## grand total, and exits 0 only when every check passed.
## Loading is defensive: a suite that fails to load still counts as a
## failure, so _init() always reaches quit() with the right code.

func _init() -> void:
	var suite_files: Array = [
		"res://tests/test_fixture.gd",
		"res://tests/test_native_guard.gd",
		"res://tests/test_deprecated.gd",
		"res://tests/test_private.gd",
		"res://tests/test_return.gd",
		"res://tests/test_var.gd",
		"res://tests/test_param.gd",
		"res://tests/test_flow.gd",
		"res://tests/test_reuse.gd",
	]
	var total_p := 0
	var total_f := 0
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
		var r: Dictionary = inst.call("run")
		total_p += int(r.get("passed", 0))
		total_f += int(r.get("failed", 0))
		print("SUITE ", str(r.get("suite", "?")), ": PASS ", int(r.get("passed", 0)), " FAIL ", int(r.get("failed", 0)))
	print("TOTAL PASS: ", total_p, " FAIL: ", total_f)
	if total_f == 0:
		print("ALL TESTS PASSED")
		quit(0)
	else:
		printerr("TESTS FAILED")
		quit(1)
