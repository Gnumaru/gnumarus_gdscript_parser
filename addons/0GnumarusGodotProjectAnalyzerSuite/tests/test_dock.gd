extends RefCounted

## Dock suite: pure filter/resource-type/format/status helpers, the
## per-file overlay plus scan-report replacement, toggle wiring,
## row navigation, rescan/clear, the EdTree openers (headless-safe)
## and the plugin-impl dock lifecycle (null headless).

const Dock = preload("res://addons/0GnumarusGodotProjectAnalyzerSuite/GnumarusGodotProjectAnalyzerSuiteDock.gd")
const EdTree = preload("res://addons/0GnumarusGodotProjectAnalyzerSuite/GnumarusGodotProjectAnalyzerSuiteEditorTree.gd")
const Impl = preload("res://addons/0GnumarusGodotProjectAnalyzerSuite/GnumarusGodotProjectAnalyzerSuitePluginImpl.gd")
const FullScan = preload("res://addons/0GnumarusGodotProjectAnalyzerSuite/GnumarusGodotProjectAnalyzerSuiteFullScanImpl.gd")
const H = preload("res://addons/0GnumarusGodotProjectAnalyzerSuite/tests/helpers.gd")

var _goto_seen: Array = []
var _rescan_seen := 0
var _backup := ""
var _had_backup := false


func _on_goto(issue: Dictionary) -> void:
	_goto_seen.append(issue)


func _on_rescan() -> void:
	_rescan_seen += 1


func run() -> Dictionary:
	var h = H.new()
	h.suite = "dock"
	_backup_results()
	_r_pure(h)
	_r_filter(h)
	_r_model(h)
	_r_widgets(h)
	_r_persist(h)
	_r_census(h)
	_r_openers(h)
	_r_impl(h)
	_restore_results()
	return h.result()


func _backup_results() -> void:
	_had_backup = FileAccess.file_exists(FullScan.results_path())
	_backup = FileAccess.get_file_as_string(FullScan.results_path()) if _had_backup else ""


func _restore_results() -> void:
	if _had_backup:
		var f := FileAccess.open(FullScan.results_path(), FileAccess.WRITE)
		if f != null:
			(f as FileAccess).store_string(_backup)
			(f as FileAccess).close()
	elif FileAccess.file_exists(FullScan.results_path()):
		DirAccess.remove_absolute(FullScan.results_path())


func _issue(sev: String, path: String, line := 1, kind := "k") -> Dictionary:
	return {"severity": sev, "kind": kind, "message": "m", "line": line, "column": 1, "path": path}


func _r_pure(h) -> void:
	h.check(Dock.resource_type("res://x.gd") == "gd", "type gd")
	h.check(Dock.resource_type("res://X.TSCN") == "tscn", "type case-insensitive")
	h.check(Dock.resource_type("res://x.tres") == "tres", "type tres")
	h.check(Dock.resource_type("res://project.godot") == "godot", "type project.godot")
	h.check(Dock.resource_type("res://x.cfg") == "other", "type unknown other")
	h.check(Dock.resource_type("") == "other", "type empty other")
	h.check(Dock.normalize_severity({"severity": "error"}) == "error", "sev error")
	h.check(Dock.normalize_severity({"severity": "warning"}) == "warning", "sev warning")
	h.check(Dock.normalize_severity({"severity": "note"}) == "note", "sev note")
	h.check(Dock.normalize_severity({"severity": "info"}) == "note", "sev future groups as note")
	h.check(Dock.normalize_severity({}) == "error", "sev missing error")
	h.check(Dock.severity_mark("error") == "E", "mark error")
	h.check(Dock.severity_mark("warning") == "W", "mark warning")
	h.check(Dock.severity_mark("note") == "N", "mark note")
	h.check(Dock.format_row(_issue("error", "res://x.gd", 10, "null_use")) == "[E] res://x.gd:10: [null_use] m", "row format")
	h.check(Dock.format_row(_issue("warning", "res://x.tscn", 0, "w")) == "[W] res://x.tscn:1: [w] m", "row clamps line")
	h.check(Dock.status_text(0, 0, 0, 0) == "no issues", "status empty")
	h.check(Dock.status_text(2, 1, 0, 0) == "2 errors  1 warning", "status counts")
	h.check(Dock.status_text(1, 0, 0, 0) == "1 error", "status singular")
	h.check(Dock.status_text(0, 0, 3, 2) == "3 notes  (+2 hidden)", "status notes plus hidden")
	h.check(Dock.status_text(1, 1, 1, 0) == "1 error  1 warning  1 note", "status all severities")


func _all_on() -> Array:
	return [Dock.filter_issues([], {}, {})]


func _r_filter(h) -> void:
	h.check(_all_on()[0].is_empty(), "filter empty in empty out")
	var issues := [
		_issue("error", "res://a.gd", 1),
		_issue("warning", "res://b.gd", 2),
		_issue("note", "res://c.tscn", 3),
		_issue("error", "res://d.tres", 4),
		_issue("warning", "res://project.godot", 5),
		_issue("error", "res://e.cfg", 6),
	]
	var show := {"error": true, "warning": true, "note": true}
	var types := {"gd": true, "tscn": true, "tres": true, "godot": true, "other": true}
	h.check(Dock.filter_issues(issues, show, types).size() == 6, "filter all on")
	show["warning"] = false
	h.check(Dock.filter_issues(issues, show, types).size() == 4, "filter hides warnings")
	show["warning"] = true
	show["error"] = false
	show["note"] = false
	h.check(Dock.filter_issues(issues, show, types).size() == 2, "filter warnings only")
	show["error"] = true
	show["note"] = true
	types["gd"] = false
	var no_gd := Dock.filter_issues(issues, show, types)
	h.check(no_gd.size() == 4, "filter hides gd type")
	for e in no_gd:
		h.check(Dock.resource_type(str((e as Dictionary).get("path", ""))) != "gd", "no gd survives type filter")
	types["gd"] = true
	for t in types.keys():
		types[t] = false
	types["other"] = true
	var other_only := Dock.filter_issues(issues, show, types)
	h.check(other_only.size() == 1 and str((other_only[0] as Dictionary).get("path", "")) == "res://e.cfg", "other bucket selectable")
	var mixed := Dock.filter_issues([{"nope": 1}, "junk"], show, types)
	h.check(mixed.size() == 1 and (mixed[0] as Dictionary).has("nope"), "pathless dict lands in other, strings dropped")


func _new_dock() -> Control:
	var d = Dock.new()
	d.set_navigate_fn(Callable(self, "_on_goto"))
	d.set_rescan_fn(Callable(self, "_on_rescan"))
	return d


func _r_model(h) -> void:
	var d := _new_dock()
	d.call("set_file_results", "res://a.gd", [_issue("error", "res://a.gd", 1), _issue("warning", "res://a.gd", 2)])
	h.check(d.call("total_count") == 2, "overlay counts file issues")
	h.check(d.call("shown_count") == 2, "overlay shown")
	d.call("set_file_results", "res://b.tscn", [_issue("error", "res://b.tscn", 3)])
	h.check(d.call("total_count") == 3, "overlay merges second file")
	d.call("set_file_results", "res://a.gd", [_issue("error", "res://a.gd", 9)])
	h.check(d.call("total_count") == 2, "overlay replaces same file")
	var doc := {"errors": [_issue("error", "res://s.gd", 1)], "warnings": [_issue("warning", "res://t.tres", 2)], "path": ""}
	d.call("set_scan_results", doc)
	h.check(d.call("total_count") == 2, "scan replaces overlay")
	var shown: Array = d.call("shown_issues")
	h.check(shown.size() == 2, "scan shown")
	d.call("set_file_results", "res://live.gd", [_issue("warning", "res://live.gd", 4)])
	h.check(d.call("total_count") == 3, "live overlays scan")
	d.call("clear_all")
	h.check(d.call("total_count") == 0 and d.call("shown_count") == 0, "clear drops everything")
	h.check(str((d as Object).get("_status").text) == Dock.DOCK_HINT, "clear restores hint")
	d.free()


func _flip(d: Control, btns: String, key: String, to: bool) -> void:
	var b: Button = (d as Object).get(btns)[key]
	b.button_pressed = to
	b.pressed.emit()


func _r_widgets(h) -> void:
	_goto_seen.clear()
	_rescan_seen = 0
	var d := _new_dock()
	d.call("set_file_results", "res://a.gd", [_issue("error", "res://a.gd", 1), _issue("warning", "res://a.gd", 2), _issue("error", "res://b.tscn", 3)])
	h.check((d as Object).get("_list").item_count == 3, "rows built")
	_flip(d, "_sev_btns", "warning", false)
	h.check(d.call("shown_count") == 2, "warning toggle hides")
	h.check("hidden" in str((d as Object).get("_status").text), "status marks hidden")
	_flip(d, "_sev_btns", "warning", true)
	_flip(d, "_type_btns", "gd", false)
	h.check(d.call("shown_count") == 1, "gd toggle hides scripts")
	_flip(d, "_type_btns", "gd", true)
	h.check(d.call("shown_count") == 3, "toggles restore")
	d.call("_on_rescan")
	h.check(_rescan_seen == 1, "rescan wired")
	(d as Object).get("_list").emit_signal("item_selected", 1)
	h.check(_goto_seen.size() == 1 and int((_goto_seen[0] as Dictionary).get("line", 0)) == 2, "row pick navigates")
	(d as Object).get("_list").emit_signal("item_selected", 99)
	h.check(_goto_seen.size() == 1, "out-of-range pick ignored")
	d.call("_on_clear")
	h.check(d.call("total_count") == 0, "clear button clears")
	d.free()


func _r_census(h) -> void:
	h.check(Dock.census_text({}) == "", "census empty blank")
	h.check(Dock.census_text("junk") == "", "census non-dict blank")
	h.check(Dock.census_text({"extensions": {}, "total": 0}) == "", "census zero blank")
	h.check(Dock.census_text({"extensions": {"gd": 1}, "total": 1}) == "1 file (1 gd)", "census singular")
	var mixed := {"extensions": {"tscn": 2, "gd": 5, "tres": 2}, "total": 9}
	h.check(Dock.census_text(mixed) == "9 files (5 gd, 2 tres, 2 tscn)", "census count order ties alpha")
	var split := {"extensions": {"gd": 6}, "total": 6, "project": {"extensions": {"gd": 2}, "total": 2}, "addons": {"extensions": {"gd": 4}, "total": 4}}
	h.check(Dock.census_text(split, false) == "2 files (2 gd)", "census toggle hides addons")
	h.check(Dock.census_text(split, true) == "6 files (6 gd)", "census toggle shows all")
	h.check(Dock.census_text(mixed, false) == "9 files (5 gd, 2 tres, 2 tscn)", "census unsplit falls back merged")
	var d := _new_dock()
	d.call("set_file_results", "res://a.gd", [])
	h.check(d.call("census_count") == 0, "headless uncensused")
	h.check(not ((d as Object).get("_files") as Label).visible, "census label hidden headless")
	d.call("set_census", mixed)
	h.check(d.call("census_count") == 9, "set_census counts")
	h.check(((d as Object).get("_files") as Label).text == "9 files (5 gd, 2 tres, 2 tscn)", "set_census paints")
	d.call("set_scan_results", {"errors": [], "warnings": [], "census": {"extensions": {"gd": 3}, "total": 3}})
	h.check(d.call("census_count") == 3, "scan report updates census")
	d.call("clear_all")
	h.check(d.call("census_count") == 3, "clear keeps census")
	var split2 := {"extensions": {"gd": 6}, "total": 6, "project": {"extensions": {"gd": 2}, "total": 2}, "addons": {"extensions": {"gd": 4}, "total": 4}}
	d.call("set_scan_results", {"errors": [], "warnings": [], "census": split2})
	((d as Object).get("_addons_btn") as Button).button_pressed = false
	((d as Object).get("_addons_btn") as Button).pressed.emit()
	h.check(d.call("census_count") == 2, "addons toggle narrows count")
	h.check(str(((d as Object).get("_files") as Label).text) == "2 files (2 gd)", "addons toggle repaints")
	((d as Object).get("_addons_btn") as Button).button_pressed = true
	((d as Object).get("_addons_btn") as Button).pressed.emit()
	h.check(d.call("census_count") == 6, "addons toggle restores")
	d.call("_apply_filters", {"show": {"error": true, "warning": true, "note": true}, "types": {"gd": true, "tscn": true, "tres": true, "godot": true, "other": true}, "include_addons": false})
	h.check(not (d as Object).get("_include_addons"), "apply syncs addons state")
	h.check(not (((d as Object).get("_addons_btn") as Button).button_pressed), "apply syncs addons button")
	h.check(d.call("census_count") == 2, "apply narrows census")
	d.free()


func _r_openers(h) -> void:
	h.check(EdTree.editor_interface() == null, "no editor interface headless")
	h.check(not EdTree.open_script_at("", 1), "open empty path false")
	h.check(not EdTree.open_script_at("res://addons/0GnumarusGodotProjectAnalyzerSuite/tests/ValidScript0.gd", 1), "open script false headless")
	h.check(not EdTree.open_scene("res://addons/0GnumarusGodotProjectAnalyzerSuite/tests/Node3D.tscn"), "open scene false headless")
	h.check(not EdTree.open_scene(""), "open empty scene false")


func _r_persist(h) -> void:
	DirAccess.remove_absolute(FullScan.results_path())
	var fresh := Dock.load_filters()
	h.check(bool((fresh.get("show", {}) as Dictionary).get("error", false)), "missing file loads error on")
	h.check(bool((fresh.get("types", {}) as Dictionary).get("gd", false)), "missing file loads gd on")
	Dock.save_filters({"error": false, "warning": true, "note": true}, {"gd": false, "tscn": true, "tres": true, "godot": true, "other": true})
	var back := Dock.load_filters()
	h.check(not bool((back.get("show", {}) as Dictionary).get("error", true)), "roundtrip keeps error off")
	h.check(bool((back.get("show", {}) as Dictionary).get("warning", false)), "roundtrip keeps warning on")
	h.check(not bool((back.get("types", {}) as Dictionary).get("gd", true)), "roundtrip keeps gd off")
	h.check(bool(back.get("include_addons", false)), "roundtrip defaults addons on")
	Dock.save_filters({"error": true, "warning": true, "note": true}, {"gd": true, "tscn": true, "tres": true, "godot": true, "other": true}, false)
	h.check(not bool(Dock.load_filters().get("include_addons", true)), "roundtrip keeps addons off")
	var disk: Variant = JSON.parse_string(FileAccess.get_file_as_string(FullScan.results_path()))
	h.check(((disk as Dictionary).get("filters", {}) as Dictionary).get("show", {}) is Dictionary, "file copy stores filters")
	var dirty := Dock.sanitize_filters({"show": {"error": false, "bogus": true}, "types": "nope"})
	h.check(not bool((dirty.get("show", {}) as Dictionary).get("error", true)), "sanitize keeps known off")
	h.check(bool((dirty.get("show", {}) as Dictionary).get("warning", false)), "sanitize defaults missing on")
	h.check(bool((dirty.get("types", {}) as Dictionary).get("gd", false)), "sanitize ignores non-dict")
	h.check(Dock.sanitize_filters("junk").get("show", {}) is Dictionary, "sanitize non-dict defaults")
	var d = Dock.new()
	d.call("set_file_results", "res://a.gd", [])
	d.call("_apply_filters", {"show": {"error": false, "warning": true, "note": true}, "types": {"gd": true, "tscn": false, "tres": true, "godot": true, "other": true}})
	h.check(not ((d as Object).get("_sev_btns") as Dictionary).get("error").button_pressed, "apply syncs sev button")
	h.check(not ((d as Object).get("_type_btns") as Dictionary).get("tscn").button_pressed, "apply syncs type button")
	h.check(not bool((d as Object).get("_show").get("error", true)), "apply syncs state")
	d.free()
	DirAccess.remove_absolute(FullScan.results_path())


func _r_impl(h) -> void:
	var impl = Impl.new(null)
	h.check(impl.ensure_dock() == null, "headless dock stays null")
	h.check(not impl._dock_added, "headless adds no dock")
	impl._goto_dock_issue({"severity": "error", "kind": "k", "message": "m", "line": 3, "column": 1, "path": "res://x.gd"})
	h.check(true, "dock goto safe headless")
	impl._goto_dock_issue({"severity": "error", "kind": "k", "message": "m", "line": 1, "column": 1, "path": "res://x.tscn"})
	h.check(true, "scene goto safe headless")
	impl._reveal_dock()
	h.check(true, "reveal safe headless")
	impl.enter_tree()
	h.check(impl._dock == null and not impl._dock_added, "enter keeps dock null headless")
	impl.exit_tree()
	h.check(impl._dock == null, "exit drops dock")
