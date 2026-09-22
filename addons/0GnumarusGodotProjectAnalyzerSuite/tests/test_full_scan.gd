extends RefCounted

## Full-scan suite: the aggregated ScanResults.json report (merge,
## sort, summary, corrupt-file fallback), the gdscript/integrity
## stages on hermetic targets, the dumb-proxy shape of the
## EditorScript, and the Project > Tools wiring in the plugin impl.
## The real ScanResults.json is backed up and restored, and any user
## JSONs the stage runs create are removed, so the suite is hermetic.

const Impl = preload("res://addons/0GnumarusGodotProjectAnalyzerSuite/GnumarusGodotProjectAnalyzerSuiteFullScanImpl.gd")
const PluginImpl = preload("res://addons/0GnumarusGodotProjectAnalyzerSuite/GnumarusGodotProjectAnalyzerSuitePluginImpl.gd")
const H = preload("res://addons/0GnumarusGodotProjectAnalyzerSuite/tests/helpers.gd")

const PROXY_PATH := "res://addons/0GnumarusGodotProjectAnalyzerSuite/GnumarusGodotProjectAnalyzerSuiteFullScan.gd"
const IMPL_PATH := "res://addons/0GnumarusGodotProjectAnalyzerSuite/GnumarusGodotProjectAnalyzerSuiteFullScanImpl.gd"
const TMP_GD := "res://addons/0GnumarusGodotProjectAnalyzerSuite/tests/TmpFullScanTarget.gd"

var _backup := ""
var _had_backup := false


func _exists(_p: String) -> bool:
	return true


func run() -> Dictionary:
	var h = H.new()
	h.suite = "full_scan"
	_backup_results()
	_r_paths(h)
	_r_empty(h)
	_r_store_merge(h)
	_r_sort(h)
	_r_corrupt(h)
	_r_gdscript_stage(h)
	_r_integrity_stage(h)
	_r_proxy(h)
	_r_menu(h)
	_restore_results()
	return h.result()


func _backup_results() -> void:
	_had_backup = FileAccess.file_exists(Impl.results_path())
	_backup = FileAccess.get_file_as_string(Impl.results_path()) if _had_backup else ""


func _restore_results() -> void:
	if _had_backup:
		var f := FileAccess.open(Impl.results_path(), FileAccess.WRITE)
		if f != null:
			(f as FileAccess).store_string(_backup)
			(f as FileAccess).close()
	elif FileAccess.file_exists(Impl.results_path()):
		DirAccess.remove_absolute(Impl.results_path())


func _user_files() -> Array:
	var dir := ProjectSettings.globalize_path(Impl.data_dir() + "/user")
	if not DirAccess.dir_exists_absolute(dir):
		return []
	return DirAccess.get_files_at(dir)


func _clean_user_jsons(before: Array) -> void:
	var base := ProjectSettings.globalize_path(Impl.data_dir() + "/user") + "/"
	for f in _user_files():
		if not before.has(f):
			DirAccess.remove_absolute(base + str(f))


func _r_paths(h) -> void:
	h.check(Impl.results_path() == Impl.data_dir() + "/ScanResults.json", "results path under data dir")
	h.check(Impl.results_path().ends_with("ScanResults.json"), "results file name")
	h.check(Impl.data_dir() == "res://.godot/0GnumarusGodotProjectAnalyzerSuiteData", "data dir matches dumper layout")


func _r_empty(h) -> void:
	var doc := Impl.empty_doc()
	h.check(int(doc.get("version", 0)) == 1, "empty version")
	h.check((doc.get("errors", []) as Array).is_empty(), "empty errors")
	h.check((doc.get("warnings", []) as Array).is_empty(), "empty warnings")
	h.check(int((doc.get("summary", {}) as Dictionary).get("files", -1)) == 0, "empty summary files")


func _mk_issue(path: String, line: int, column: int, kind: String, sev := "error") -> Dictionary:
	return {"stage": "zz", "severity": sev, "kind": kind, "message": "m", "path": path, "line": line, "column": column}


func _r_store_merge(h) -> void:
	DirAccess.remove_absolute(Impl.results_path())
	var a_errors := [_mk_issue("res://b.gd", 2, 1, "k2"), _mk_issue("res://a.gd", 9, 1, "k1")]
	var doc_a: Dictionary = Impl.store_stage("zz_a", a_errors, [], 2)
	h.check(int(((doc_a.get("stages", {}) as Dictionary).get("zz_a", {}) as Dictionary).get("files", 0)) == 2, "stage files recorded")
	h.check((doc_a.get("errors", []) as Array).size() == 2, "stage errors aggregated")
	var doc_b: Dictionary = Impl.store_stage("zz_b", [], [_mk_issue("res://c.gd", 1, 0, "w", "warning")], 1)
	h.check(((doc_b.get("stages", {}) as Dictionary) as Dictionary).has("zz_a"), "second store keeps first stage")
	h.check(((doc_b.get("stages", {}) as Dictionary) as Dictionary).has("zz_b"), "second store adds stage")
	h.check((doc_b.get("errors", []) as Array).size() == 2, "aggregates keep errors")
	h.check((doc_b.get("warnings", []) as Array).size() == 1, "aggregates keep warnings")
	var summary: Dictionary = doc_b.get("summary", {})
	h.check(int(summary.get("files", 0)) == 3, "summary sums files")
	h.check(int(summary.get("errors", 0)) == 2 and int(summary.get("warnings", 0)) == 1, "summary counts issues")
	h.check(summary.get("stages", []) == ["zz_a", "zz_b"], "summary lists stages sorted")
	h.check(FileAccess.file_exists(Impl.results_path()), "report written to disk")
	var disk: Variant = JSON.parse_string(FileAccess.get_file_as_string(Impl.results_path()))
	h.check((disk is Dictionary) and int((disk as Dictionary).get("version", 0)) == 1, "disk report parses")
	DirAccess.remove_absolute(Impl.results_path())


func _r_sort(h) -> void:
	DirAccess.remove_absolute(Impl.results_path())
	var errs := [_mk_issue("res://b.gd", 1, 0, "k"), _mk_issue("res://a.gd", 5, 3, "k"), _mk_issue("res://a.gd", 5, 1, "k")]
	var doc: Dictionary = Impl.store_stage("zz_sort", errs, [], 1)
	var got: Array = doc.get("errors", [])
	h.check(str((got[0] as Dictionary).get("path", "")) == "res://a.gd" and int((got[0] as Dictionary).get("column", 0)) == 1, "sort path then column")
	h.check(str((got[1] as Dictionary).get("path", "")) == "res://a.gd" and int((got[1] as Dictionary).get("column", 0)) == 3, "sort column within line")
	h.check(str((got[2] as Dictionary).get("path", "")) == "res://b.gd", "sort path last")
	DirAccess.remove_absolute(Impl.results_path())


func _r_corrupt(h) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(Impl.data_dir()))
	var f := FileAccess.open(Impl.results_path(), FileAccess.WRITE)
	(f as FileAccess).store_string("not json {{{")
	(f as FileAccess).close()
	var doc := Impl.load_results()
	h.check((doc.get("errors", []) as Array).is_empty() and ((doc.get("stages", {}) as Dictionary) as Dictionary).is_empty(), "corrupt report falls back empty")
	var doc2: Dictionary = Impl.store_stage("zz_after_corrupt", [], [], 0)
	h.check(((doc2.get("stages", {}) as Dictionary) as Dictionary).has("zz_after_corrupt"), "store recovers from corrupt")
	DirAccess.remove_absolute(Impl.results_path())


func _write_tmp() -> void:
	var f := FileAccess.open(TMP_GD, FileAccess.WRITE)
	(f as FileAccess).store_string("extends Node\nconst ANSWER := 42\nfunc f() -> int:\n\treturn ANSWER\n")
	(f as FileAccess).close()


func _r_gdscript_stage(h) -> void:
	var before := _user_files()
	_write_tmp()
	var doc: Dictionary = Impl.new().run_gdscript("", [TMP_GD])
	var entry: Dictionary = ((doc.get("stages", {}) as Dictionary).get(Impl.STAGE_GDSCRIPT, {}))
	h.check(int(entry.get("files", 0)) == 1, "gdscript stage counts file")
	h.check(((entry.get("errors", []) as Array) as Array).is_empty(), "tmp script analyzer-clean")
	h.check(((entry.get("warnings", []) as Array) as Array).is_empty(), "tmp script warning-clean")
	for e in doc.get("errors", []):
		h.check(str((e as Dictionary).get("stage", "")) == Impl.STAGE_GDSCRIPT, "gdscript issues tagged")
	DirAccess.remove_absolute(TMP_GD)
	_clean_user_jsons(before)


func _r_integrity_stage(h) -> void:
	_write_tmp()
	var doc: Dictionary = Impl.new().run_integrity("", [TMP_GD], {}, {}, Callable(self, "_exists"))
	var entry: Dictionary = ((doc.get("stages", {}) as Dictionary).get(Impl.STAGE_INTEGRITY, {}))
	h.check(int(entry.get("files", 0)) == 1, "integrity stage counts file")
	h.check(((entry.get("errors", []) as Array) as Array).is_empty(), "tmp script integrity-clean")
	DirAccess.remove_absolute(TMP_GD)


func _r_proxy(h) -> void:
	var proxy_text := FileAccess.get_file_as_string(PROXY_PATH)
	h.check("@tool" in proxy_text, "proxy is tool")
	h.check("extends EditorScript" in proxy_text, "proxy extends EditorScript")
	h.check("func _run" in proxy_text, "proxy implements _run")
	h.check("FullScanImpl" in proxy_text, "proxy forwards to impl")
	var scr: Variant = load(PROXY_PATH)
	h.check(scr is Script, "proxy loads as script")
	h.check((scr as Script).is_tool(), "proxy script is tool")
	h.check((scr as Script).get_instance_base_type() == "EditorScript", "proxy base is EditorScript")
	var found_run := false
	for m in (scr as Script).get_script_method_list():
		if str((m as Dictionary).get("name", "")) == "_run":
			found_run = true
	h.check(found_run, "proxy declares _run")
	var impl_text := FileAccess.get_file_as_string(IMPL_PATH)
	h.check("extends RefCounted" in impl_text, "impl is RefCounted")
	h.check(not ("@tool" in impl_text), "impl not tool")
	h.check(not ("extends EditorScript" in impl_text), "impl free of EditorScript")
	h.check(not ("extends EditorPlugin" in impl_text), "impl free of EditorPlugin")


func _r_menu(h) -> void:
	h.check(PluginImpl.FULL_SCAN_MENU == "Gnumarus Full Scan", "menu name")
	var impl = PluginImpl.new(null)
	h.check(impl.has_method("_on_full_scan_menu"), "menu callback exists")
	impl.enter_tree()
	h.check(not impl._tool_menu_added, "headless adds no menu")
	impl._remove_tool_menu()
	h.check(not impl._tool_menu_added, "remove without add stays calm")
	impl.exit_tree()
	h.check(not impl._tool_menu_added, "exit without menu stays calm")
