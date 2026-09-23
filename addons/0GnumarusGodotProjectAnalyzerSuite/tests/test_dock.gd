# @integrity_ignore_file (test harness uses virtual paths)
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
	_r_tabs(h)
	_r_file_tree(h)
	_r_column_collapse(h)
	_r_hide(h)
	_r_flat_view(h)
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
	var emb := _issue("error", "res://a/b/c.tscn", 18, "tuple_mismatch")
	emb["node"] = "SceneRoot/e"
	emb["scene_line"] = 4
	h.check(Dock.format_row(emb) == "[E] res://a/b/c.tscn:4:18: [tuple_mismatch] m", "embedded row shows scene and script lines")
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
	var itree: Tree = (d as Object).get("_issues")
	h.check(itree.get_root().get_child_count() == 3, "rows built")
	h.check(itree.columns == 2, "issue tree has text plus button columns")
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
	itree.get_root().get_child(1).select(0)
	h.check(_goto_seen.size() == 1 and int((_goto_seen[0] as Dictionary).get("line", 0)) == 2, "row pick navigates")
	itree.deselect_all()
	d.call("_on_item_selected")
	h.check(_goto_seen.size() == 1, "deselected pick ignored")
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


func _r_tabs(h) -> void:
	h.check(Dock.census_rows({}, true).is_empty(), "rows empty blank")
	h.check(Dock.census_rows({"extensions": {}, "total": 0}, true).is_empty(), "rows zero blank")
	h.check(Dock.census_datetime(0) == "", "datetime unknown blank")
	h.check(Dock.census_datetime(1700000000) == "2023-11-14 22:13:20", "datetime renders UTC stamp")
	h.check(Dock.census_summary_rows({}, true).is_empty(), "summary empty blank")
	h.check(Dock.census_summary_rows("junk", true).is_empty(), "summary non-dict blank")
	h.check(Dock.census_summary_rows({"extensions": {"gd": 9}, "total": 9}, true) == ["All files: 9 files"], "summary legacy counts alone")
	var mixed := {"extensions": {"tscn": 2, "gd": 5, "tres": 2}, "total": 9}
	h.check(Dock.census_rows(mixed, true) == ["gd: 5", "tres: 2", "tscn: 2"], "rows unsplit ordered")
	var split := {"extensions": {"gd": 6, "tscn": 3}, "total": 9, "project": {"extensions": {"gd": 2, "tscn": 3}, "total": 5}, "addons": {"extensions": {"gd": 4}, "total": 4}}
	h.check(Dock.census_rows(split, true) == ["gd: 6 (2 project + 4 addons)", "tscn: 3 (3 project + 0 addons)"], "rows split breakdown")
	h.check(Dock.census_rows(split, false) == ["tscn: 3", "gd: 2"], "rows toggle hides addons")
	h.check(Dock.census_rows(mixed, false) == ["gd: 5", "tres: 2", "tscn: 2"], "rows unsplit falls back merged")
	var rich := {
		"extensions": {"gd": 6}, "total": 6, "bytes": 2048, "size": "2.0 KB", "newest": 1700000000, "oldest": 1699000000,
		"project": {"extensions": {"gd": 2}, "total": 2, "bytes": 2048, "size": "2.0 KB", "newest": 1700000000, "oldest": 1699000000},
		"addons": {"extensions": {"gd": 4}, "total": 4, "bytes": 0, "size": "", "newest": 0, "oldest": 0},
	}
	h.check(Dock.census_summary_rows(rich, true) == ["All files: 6 files, 2.0 KB (2023-11-03 08:26:40 → 2023-11-14 22:13:20)", "project: 2 files, 2.0 KB (2023-11-03 08:26:40 → 2023-11-14 22:13:20)", "addons: 4 files"], "summary groups with extras")
	h.check(Dock.census_summary_rows(rich, false) == ["project: 2 files, 2.0 KB (2023-11-03 08:26:40 → 2023-11-14 22:13:20)"], "summary toggle narrows groups")
	var d := _new_dock()
	d.call("set_file_results", "res://a.gd", [])
	var tabs: TabContainer = (d as Object).get("_tabs")
	h.check(tabs.get_tab_count() == 2, "two tabs")
	h.check(tabs.get_tab_title(0) == "Issues", "issues tab first")
	h.check(tabs.get_tab_title(1) == "Files", "files tab second")
	var tree: Tree = (d as Object).get("_tree")
	h.check(tree.columns == 9, "tree columns")
	h.check(tree.get_root().get_child_count() == 1, "hint row when uncensused")
	h.check(tree.get_root().get_child(0).get_text(0) == Dock.CENSUS_HINT, "hint text")
	d.call("set_census", mixed)
	h.check(tree.get_root().get_child_count() == 1, "legacy single group")
	h.check(tree.get_root().get_child(0).get_text(0) == "project: 9 files", "legacy project group")
	h.check(tree.get_root().get_child(0).get_child_count() == 3, "legacy extension rows")
	d.call("set_census", split)
	h.check(tree.get_root().get_child_count() == 2, "partition groups built")
	h.check(tree.get_root().get_child(0).get_text(0) == "project: 5 files", "partition summary leads")
	h.check(tree.get_root().get_child(0).get_child_count() == 2, "partition extension rows")
	((d as Object).get("_addons_btn") as Button).button_pressed = false
	((d as Object).get("_addons_btn") as Button).pressed.emit()
	h.check(tree.get_root().get_child_count() == 1, "toggle drops addons group")
	h.check(tree.get_root().get_child(0).get_text(0) == "project: 5 files", "toggle keeps project group")
	d.free()


func _paths(rows: Array) -> Array:
	var out: Array = []
	for r in rows:
		out.append(str((r as Dictionary).get("path", "")))
	return out


func _r_file_tree(h) -> void:
	var files := [
		{"path": "res://b.gd", "size": 100, "created": 0, "modified": 2000},
		{"path": "res://a.gd", "size": 300, "created": 0, "modified": 1000},
		{"path": "res://addons/c.gd", "size": 200, "created": 0, "modified": 3000},
	]
	h.check(_paths(Dock.sort_file_entries(files, "path", false)) == ["res://a.gd", "res://addons/c.gd", "res://b.gd"], "sort path")
	h.check(_paths(Dock.sort_file_entries(files, "size", false)) == ["res://b.gd", "res://addons/c.gd", "res://a.gd"], "sort size")
	h.check(_paths(Dock.sort_file_entries(files, "modified", true)) == ["res://addons/c.gd", "res://b.gd", "res://a.gd"], "sort modified desc")
	h.check(_paths(Dock.sort_file_entries(files, "created", false)) == ["res://a.gd", "res://addons/c.gd", "res://b.gd"], "sort zeros fall back to path")
	h.check(_paths(Dock.sort_file_entries(files, "bogus", false)) == ["res://a.gd", "res://addons/c.gd", "res://b.gd"], "sort unknown falls back to path")
	h.check(Dock.sort_file_entries(["junk"], "path", false).is_empty(), "sort drops non-dicts")
	h.check(Dock.sanitize_sort_key("size") == "size", "sort key kept")
	h.check(Dock.sanitize_sort_key("nope") == "path", "sort key guarded")
	var census := {
		"extensions": {"gd": 3}, "total": 3, "bytes": 600, "size": "600 B", "newest": 3000, "oldest": 1000,
		"project": {"extensions": {"gd": 2}, "total": 2, "bytes": 400, "size": "400 B", "newest": 2000, "oldest": 1000},
		"addons": {"extensions": {"gd": 1}, "total": 1, "bytes": 200, "size": "200 B", "newest": 3000, "oldest": 3000},
		"files": files,
		"dirs": [{"path": "res://", "created": 0, "modified": 0, "files": 0, "subdirs": 1, "files_recursive": 3, "subdirs_recursive": 2, "size": 0, "size_recursive": 600}],
	}
	var d := _new_dock()
	d.call("set_file_results", "res://a.gd", [{"severity": "error", "kind": "k", "message": "m", "line": 4, "column": 1, "path": "res://a.gd"}])
	d.call("set_census", census)
	var tree: Tree = (d as Object).get("_tree")
	h.check(tree.get_root().get_child_count() == 3, "file groups plus dirs")
	var proj := tree.get_root().get_child(0)
	h.check(proj.get_text(0) == "project: 2 files, 400 B (1970-01-01 00:16:40 → 1970-01-01 00:33:20)", "group summary with extras")
	h.check(proj.collapsed, "groups start collapsed")
	h.check(proj.get_child_count() == 2, "project file rows")
	h.check(proj.get_child(0).get_text(0) == "res://a.gd", "default sort path")
	h.check(proj.get_child(0).get_text(5) == "300 B", "file size human")
	h.check(proj.get_child(0).get_text(7) == "", "file unknown creation blank")
	h.check(proj.get_child(0).get_text(8) == "1970-01-01 00:16:40", "file modified stamp")
	var md: Dictionary = proj.get_child(0).get_metadata(0)
	h.check(str(md.get("path", "")) == "res://a.gd" and int(md.get("line", 0)) == 4, "file row targets first issue")
	var bmd: Dictionary = proj.get_child(1).get_metadata(0)
	h.check(int(bmd.get("line", 0)) == 1, "clean file targets line one")
	var dirs := tree.get_root().get_child(2)
	h.check(dirs.get_text(0) == "directories: 1", "dirs group last")
	h.check(dirs.get_child(0).get_text(0) == "res://", "dir row path")
	h.check(dirs.get_child(0).get_text(1) == "0", "dir direct files")
	h.check(dirs.get_child(0).get_text(2) == "1", "dir direct subdirs")
	h.check(dirs.get_child(0).get_text(3) == "3", "dir recursive files")
	h.check(dirs.get_child(0).get_text(4) == "2", "dir recursive subdirs")
	h.check(dirs.get_child(0).get_text(5) == "0 B", "dir direct size")
	h.check(dirs.get_child(0).get_text(6) == "600 B", "dir recursive size")
	_goto_seen.clear()
	proj.collapsed = false
	proj.get_child(0).select(0)
	h.check(_goto_seen.size() == 1 and str((_goto_seen[0] as Dictionary).get("path", "")) == "res://a.gd", "file row navigates")
	dirs.get_child(0).select(0)
	h.check(_goto_seen.size() == 1, "dir row inert")
	((d as Object).get("_sort_opt") as OptionButton).select(1)
	((d as Object).get("_sort_opt") as OptionButton).emit_signal("item_selected", 1)
	proj = tree.get_root().get_child(0)
	h.check(proj.get_child(0).get_text(0) == "res://b.gd", "sort dropdown re-sorts")
	((d as Object).get("_sort_desc_btn") as CheckButton).button_pressed = true
	((d as Object).get("_sort_desc_btn") as CheckButton).emit_signal("toggled", true)
	proj = tree.get_root().get_child(0)
	h.check(proj.get_child(0).get_text(0) == "res://a.gd", "desc toggle inverts")
	d.call("_apply_filters", {"show": {"error": true, "warning": true, "note": true}, "types": {"gd": true, "tscn": true, "tres": true, "godot": true, "other": true}, "include_addons": true, "sort": "bogus", "descending": "yes"})
	h.check(str((d as Object).get("_sort_key")) == "path", "apply guards sort key")
	h.check(not bool((d as Object).get("_sort_desc")), "apply guards descending")
	d.free()


func _r_column_collapse(h) -> void:
	h.check(Dock.toggle_collapsed_state({}, 2, 9) == {2: true}, "toggle collapses")
	h.check(Dock.toggle_collapsed_state({2: true}, 2, 9) == {2: false}, "toggle restores")
	h.check(Dock.toggle_collapsed_state({}, -1, 9).is_empty(), "toggle ignores negative")
	h.check(Dock.toggle_collapsed_state({}, 9, 9).is_empty(), "toggle ignores overflow")
	h.check(Dock.toggle_collapsed_state({1: true}, 2, 9) == {1: true, 2: true}, "toggle keeps other columns")
	var src := {3: true}
	Dock.toggle_collapsed_state(src, 0, 9)
	h.check(not src.has(0), "toggle never mutates input")
	var d := _new_dock()
	d.call("set_file_results", "res://a.gd", [])
	var tree: Tree = (d as Object).get("_tree")
	h.check(tree.is_column_expanding(1) and not tree.is_column_clipping_content(1), "columns start normal")
	d.call("_on_column_title_clicked", 1, MOUSE_BUTTON_LEFT)
	h.check(bool((d as Object).get("_collapsed_cols").get(1, false)), "click records collapse")
	h.check(not tree.is_column_expanding(1), "click compacts tree column")
	h.check(not tree.is_column_clipping_content(1), "compacted column never clips")
	h.check(tree.is_column_expanding(0) and tree.is_column_expanding(2), "click spares other columns")
	d.call("_on_column_title_clicked", 1, MOUSE_BUTTON_LEFT)
	h.check(not bool((d as Object).get("_collapsed_cols").get(1, true)), "second click records restore")
	h.check(tree.is_column_expanding(1) and not tree.is_column_clipping_content(1), "second click restores tree column")
	d.call("_on_column_title_clicked", 0, MOUSE_BUTTON_RIGHT)
	h.check(not bool((d as Object).get("_collapsed_cols").get(0, false)), "right click ignored")
	h.check(tree.is_column_expanding(0), "right click spares tree column")
	d.call("_on_column_title_clicked", 99, MOUSE_BUTTON_LEFT)
	h.check((d as Object).get("_collapsed_cols").size() == 1, "out-of-range click ignored")
	d.free()
	var d2 := _new_dock()
	d2.call("set_file_results", "res://a.gd", [])
	d2.call("set_census", {
		"extensions": {"gd": 2}, "total": 2,
		"project": {"extensions": {"gd": 1}, "total": 1},
		"addons": {"extensions": {"gd": 1}, "total": 1},
		"files": [
			{"path": "res://a.gd", "size": 440729, "created": 0, "modified": 1000},
			{"path": "res://addons/very_long_directory_name/c.gd", "size": 100, "created": 0, "modified": 2000},
		],
		"dirs": [],
	})
	var tree2: Tree = (d2 as Object).get("_tree")
	var font := tree2.get_theme_font("font", "Tree")
	var fs := tree2.get_theme_font_size("font_size", "Tree")
	var path_w := int(font.get_string_size("res://addons/very_long_directory_name/c.gd", HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x)
	h.check(d2.call("_column_fit_width", 0) >= path_w, "fit covers hidden child paths")
	var size_w := int(font.get_string_size("430.4 KB", HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x)
	var size_title_w := int(font.get_string_size("Size", HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x)
	h.check(d2.call("_column_fit_width", 5) >= maxi(size_w, size_title_w), "fit covers cells and title")
	h.check(d2.call("_column_fit_width", -1) == 0, "fit rejects negative")
	h.check(d2.call("_column_fit_width", 9) == 0, "fit rejects overflow")
	h.check(Dock._fit_text_width("", font, fs, 0, 16, 0) >= 12, "fit keeps padding on empty")
	h.check(Dock._fit_text_width("x", font, fs, 2, 16, 0) > Dock._fit_text_width("x", font, fs, 0, 16, 0), "fit grows with depth")
	d2.call("_on_column_title_clicked", 5, MOUSE_BUTTON_LEFT)
	d2.call("set_census", {
		"extensions": {"gd": 1}, "total": 1,
		"project": {"extensions": {"gd": 1}, "total": 1},
		"addons": {"extensions": {}, "total": 0},
		"files": [{"path": "res://z.gd", "size": 10, "created": 0, "modified": 1000}],
		"dirs": [],
	})
	h.check(not tree2.is_column_expanding(5), "rebuild keeps collapse")
	d2.free()


func _r_hide(h) -> void:
	var a := _issue("error", "res://a.gd", 1, "k1")
	var b := _issue("warning", "res://b.gd", 2, "k2")
	h.check(Dock.hide_key(a) == Dock.hide_key(a.duplicate()), "hide key stable")
	h.check(Dock.hide_key(a) != Dock.hide_key(b), "hide key distinguishes issues")
	var e1 := _issue("error", "res://x.tscn", 3, "k")
	e1["node"] = "R/A"
	e1["scene_line"] = 4
	var e2 := e1.duplicate()
	e2["node"] = "R/B"
	h.check(Dock.hide_key(e1) != Dock.hide_key(e2), "hide key distinguishes embedded nodes")
	h.check(Dock.apply_hidden([a, b], {}).size() == 2, "no hidden keeps all")
	h.check(Dock.apply_hidden([a, b], {Dock.hide_key(a): true}) == [b], "hidden drops one")
	h.check(Dock.apply_hidden(["junk", a], {Dock.hide_key(a): true}).is_empty(), "hidden drops non-dicts")
	h.check(Dock.hide_icon() is Texture2D, "hide glyph available headless")
	var d := _new_dock()
	d.call("set_file_results", "res://a.gd", [a])
	d.call("set_file_results", "res://b.gd", [b])
	var tree: Tree = (d as Object).get("_issues")
	var unhide: Button = (d as Object).get("_unhide_btn")
	h.check(tree.get_root().get_child_count() == 2, "hide rows built")
	h.check(tree.get_root().get_child(0).get_button_count(1) == 1, "hide button on row")
	h.check(unhide.disabled, "unhide starts disabled")
	d.call("_on_issue_button_clicked", tree.get_root().get_child(0), 1, Dock.HIDE_BUTTON_ID, MOUSE_BUTTON_LEFT)
	h.check(d.call("shown_count") == 1, "button hides one issue")
	h.check(tree.get_root().get_child_count() == 1, "hidden row gone")
	h.check(not unhide.disabled and "1" in unhide.text, "unhide counts hidden")
	h.check("hidden" in str((d as Object).get("_status").text), "status marks user-hidden")
	d.call("_on_issue_button_clicked", tree.get_root().get_child(0), 1, 99, MOUSE_BUTTON_LEFT)
	h.check(d.call("shown_count") == 1, "foreign button id ignored")
	d.call("_on_issue_button_clicked", tree.get_root().get_child(0), 1, Dock.HIDE_BUTTON_ID, MOUSE_BUTTON_RIGHT)
	h.check(d.call("shown_count") == 1, "right click ignored")
	d.call("_on_unhide_all")
	h.check(d.call("shown_count") == 2, "unhide restores all")
	h.check(tree.get_root().get_child_count() == 2, "unhidden rows back")
	h.check(unhide.disabled, "unhide disables when empty")
	d.call("_on_issue_button_clicked", tree.get_root().get_child(0), 1, Dock.HIDE_BUTTON_ID, MOUSE_BUTTON_LEFT)
	d.call("set_scan_results", {"errors": [_issue("error", "res://c.gd", 9, "k9")], "warnings": []})
	h.check((d as Object).get("_hidden").is_empty(), "stale hidden keys pruned")
	h.check(d.call("shown_count") == 1, "prune keeps live rows")
	d.free()


func _r_flat_view(h) -> void:
	h.check(Dock.flat_path("res://") == "/", "flat root path")
	h.check(Dock.flat_path("res://a.png") == "/a.png", "flat strips prefix")
	h.check(Dock.flat_path("res://a/b/c") == "/a/b/c", "flat keeps nesting")
	h.check(Dock.flat_path("other/x") == "other/x", "flat passes foreign paths")
	var f := {"path": "res://a.png", "size": 1536, "created": 1700000000, "modified": 1699000000}
	h.check(Dock.flat_file_row(f) == "/a.png: created: 2023-11-14 22:13:20; modified: 2023-11-03 08:26:40; size: 1.5 KB", "flat file row format")
	h.check(Dock.flat_file_row({"path": "res://x.gd", "size": 0, "created": 0, "modified": 0}) == "/x.gd: created: ; modified: ; size: 0 B", "flat file row blanks unknown")
	var dd := {"path": "res://a", "created": 1700000000, "modified": 1699000000, "files": 1, "subdirs": 2, "files_recursive": 3, "subdirs_recursive": 4, "size": 1536, "size_recursive": 2048}
	h.check(Dock.flat_dir_row(dd) == "/a: created: 2023-11-14 22:13:20; modified: 2023-11-03 08:26:40; size: 1.5 KB; rec-size: 2.0 KB; direct files: 1; all files: 3; direct dirs: 2; all dirs: 4", "flat dir row format")
	var split := {"extensions": {"gd": 6}, "total": 6, "project": {"extensions": {"gd": 2}, "total": 2}, "addons": {"extensions": {"gd": 4}, "total": 4}}
	h.check(Dock.view_groups(split, true, []).size() == 2, "view groups split")
	h.check(Dock.view_groups(split, false, []).size() == 1, "view groups toggle drops addons")
	h.check(Dock.view_groups({}, true, []).is_empty(), "view groups empty censused")
	h.check(Dock.view_groups({}, true, [{"path": "res://x.gd"}]).size() == 2, "view groups fall back with files")
	h.check(Dock.own_files([{"path": "res://a.gd"}, {"path": "res://addons/c.gd"}, {"nope": 1}, {"path": ""}], "project") == [{"path": "res://a.gd"}], "own files filter project")
	h.check(Dock.own_files([{"path": "res://a.gd"}, {"path": "res://addons/c.gd"}], "addons") == [{"path": "res://addons/c.gd"}], "own files filter addons")
	var dirs := [{"path": "res://b"}, {"path": "res://a"}, {"path": "res://addons/z"}, {"path": ""}, "junk"]
	h.check(Dock.shown_dirs(dirs, true).map(func(e: Variant) -> String: return str((e as Dictionary).get("path", ""))) == ["res://a", "res://addons/z", "res://b"], "shown dirs sorted")
	h.check(Dock.shown_dirs(dirs, false).size() == 2, "shown dirs toggle drops addons")
	var files := [
		{"path": "res://b.gd", "size": 100, "created": 0, "modified": 2000},
		{"path": "res://a.gd", "size": 300, "created": 0, "modified": 1000},
		{"path": "res://addons/c.gd", "size": 200, "created": 0, "modified": 3000},
	]
	var census := {
		"extensions": {"gd": 3}, "total": 3, "bytes": 600, "size": "600 B", "newest": 3000, "oldest": 1000,
		"project": {"extensions": {"gd": 2}, "total": 2, "bytes": 400, "size": "400 B", "newest": 2000, "oldest": 1000},
		"addons": {"extensions": {"gd": 1}, "total": 1, "bytes": 200, "size": "200 B", "newest": 3000, "oldest": 3000},
		"files": files,
		"dirs": [{"path": "res://", "created": 0, "modified": 0, "files": 0, "subdirs": 1, "files_recursive": 3, "subdirs_recursive": 2, "size": 0, "size_recursive": 600}],
	}
	var d := _new_dock()
	d.call("set_file_results", "res://a.gd", [{"severity": "error", "kind": "k", "message": "m", "line": 4, "column": 1, "path": "res://a.gd"}])
	d.call("set_census", census)
	var flat: Tree = (d as Object).get("_flat_tree")
	var cols: Tree = (d as Object).get("_tree")
	h.check(flat.columns == 1, "flat single column")
	h.check(flat.get_root().get_child_count() == cols.get_root().get_child_count(), "flat mirrors column groups")
	var fproj := flat.get_root().get_child(0)
	h.check(fproj.get_child_count() == 2, "flat project file rows")
	h.check(fproj.get_child(0).get_text(0) == Dock.flat_file_row(files[1]), "flat file row concatenated")
	h.check(not ("res://" in fproj.get_child(0).get_text(0)), "flat file row hides prefix")
	var fdirs := flat.get_root().get_child(2)
	h.check(fdirs.get_child(0).get_text(0) == Dock.flat_dir_row((census.get("dirs", []) as Array)[0]), "flat dir row concatenated")
	_goto_seen.clear()
	fproj.collapsed = false
	fproj.get_child(0).select(0)
	h.check(_goto_seen.size() == 1 and str((_goto_seen[0] as Dictionary).get("path", "")) == "res://a.gd", "flat file row navigates")
	fdirs.get_child(0).select(0)
	h.check(_goto_seen.size() == 1, "flat dir row inert")
	var vtabs: TabContainer = (d as Object).get("_view_tabs")
	h.check(not vtabs.tabs_visible, "view tabs hidden")
	h.check(vtabs.get_tab_count() == 2, "two file views")
	h.check(vtabs.get_tab_control(0).visible and not vtabs.get_tab_control(1).visible, "columns view first")
	d.call("_switch_file_view", Dock.VIEW_FLAT)
	h.check(vtabs.get_tab_control(1).visible and not vtabs.get_tab_control(0).visible, "switch reaches flat view")
	d.call("_switch_file_view", 99)
	h.check(vtabs.get_tab_control(1).visible and not vtabs.get_tab_control(0).visible, "switch clamps overflow")
	d.call("_switch_file_view", -5)
	h.check(vtabs.get_tab_control(0).visible and not vtabs.get_tab_control(1).visible, "switch clamps underflow")
	((d as Object).get("_sort_opt") as OptionButton).select(1)
	((d as Object).get("_sort_opt") as OptionButton).emit_signal("item_selected", 1)
	h.check(flat.get_root().get_child(0).get_child(0).get_text(0) == Dock.flat_file_row(files[0]), "flat view follows sort")
	((d as Object).get("_addons_btn") as Button).button_pressed = false
	((d as Object).get("_addons_btn") as Button).pressed.emit()
	h.check(flat.get_root().get_child_count() == cols.get_root().get_child_count(), "flat mirrors addons toggle")
	d.call("set_census", {"extensions": {"gd": 9}, "total": 9})
	h.check(flat.get_root().get_child(0).get_child_count() == 1, "flat legacy extension rows")
	d.call("set_census", {})
	h.check(flat.get_root().get_child(0).get_text(0) == Dock.CENSUS_HINT, "flat hint when uncensused")
	d.free()


func _r_openers(h) -> void:
	h.check(EdTree.editor_interface() == null, "no editor interface headless")
	h.check(not EdTree.open_script_at("", 1), "open empty path false")
	h.check(not EdTree.open_script_at("res://addons/0GnumarusGodotProjectAnalyzerSuite/tests/ValidScript0.gd", 1), "open script false headless")
	h.check(not EdTree.open_scene("res://addons/0GnumarusGodotProjectAnalyzerSuite/tests/Node3D.tscn"), "open scene false headless")
	h.check(not EdTree.open_scene(""), "open empty scene false")
	h.check(not EdTree.show_main_screen("Script"), "screen switch false headless")
	h.check(not EdTree.show_main_screen(""), "screen switch empty false")
	h.check(not EdTree.show_main_screen("   "), "screen switch blank false")


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
