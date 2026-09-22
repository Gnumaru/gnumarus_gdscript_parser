# @integrity_ignore_file (test harness uses virtual paths)
extends RefCounted

## Native-database guard suite: the dumper's is_present()/ensure_present()
## contract that the semantic parser and the analyzer rely on.
## (Their early-return branch itself needs a missing data dir and is
## covered by a manual probe, not here: wiping the data dir mid-run would
## break the other suites' JSON assertions.)

const Dumper = preload("res://addons/0GnumarusGodotProjectAnalyzerSuite/GnumarusGodotProjectAnalyzerSuiteGodotTypesInfoDumper.gd")
const H = preload("res://addons/0GnumarusGodotProjectAnalyzerSuite/tests/helpers.gd")


func run() -> Dictionary:
	var h = H.new()
	h.suite = "native_guard"
	var d = Dumper.new()
	d.output_base = "res://.godot/0GnumarusGodotProjectAnalyzerSuiteData"
	h.check(d.is_present(), "native database present")
	h.check(d.ensure_present(), "ensure_present passes when cached")
	h.check(str(Dumper.default_executable()) != "", "default executable non-empty")
	var bad = Dumper.new()
	bad.output_base = "res://types_info_test_missing_zz"
	h.check(not bad.is_present(), "missing database detected")
	var ok: bool = bad.ensure_present("/definitely/not/a/godot_binary")
	h.check(not ok, "ensure_present fails with bad executable")
	h.check(str(bad.last_error) != "", "failure sets last_error")
	return h.result()
