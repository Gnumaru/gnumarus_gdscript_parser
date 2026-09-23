extends VBoxContainer

## Bottom-panel dock listing every Gnumarus analyzer issue known for
## the project: live per-file results from analyze_current overlaid on
## the last full-scan report (ScanResults.json, loaded on build).
##
## Two tabs share one toolbar: "Issues" (the filtered error/warning
## list) and "Files" (the project file census in two simultaneous
## views behind hidden inner tabs: the 9-column table and the
## single-column concatenated rows without the res:// prefix, each
## with a button switching to the other). Clicking a column header
## compacts that column to fit its content (never truncated);
## clicking again stretches it back. Every issue row
## carries a hide button on its right (Tree cell button, so rows keep
## text height); hiding drops that single issue until "Unhide" (in
## the toolbar) brings every hidden issue back. Two toggle groups filter the issue list (same idea as the Output
## panel filter buttons): severities (Errors / Warnings / Notes —
## nothing emits notes yet, the toggle is ready for them) and
## resource types (gd / tscn / tres / godot / other, derived from the
## issue path, so script issues and resource-integrity issues toggle
## independently). Picking a row calls the injected `_goto` Callable
## with the issue dict (the plugin wires it to editor navigation);
## Rescan calls the injected `_rescan` Callable (the full scan). All
## filter/census logic is static and headless-testable; only live
## editor navigation needs the editor.

const EdTree = preload("res://addons/0GnumarusGodotProjectAnalyzerSuite/GnumarusGodotProjectAnalyzerSuiteEditorTree.gd")
const FullScan = preload("res://addons/0GnumarusGodotProjectAnalyzerSuite/GnumarusGodotProjectAnalyzerSuiteFullScanImpl.gd")

const DOCK_HINT := "GNMR Analyzer: no issues. Run Project > Tools > Gnumaru's Full Scan for a project-wide report."
## EditorSettings key holding the filter state. It wins over the
## ScanResults.json copy on load; both are written on every change.
const FILTERS_SETTING := "gnumarus_analyzer/dock_filters"
const SEVERITIES := ["error", "warning", "note"]
const SEV_LABELS := {"error": "Errors", "warning": "Warnings", "note": "Notes"}
const TYPES := ["gd", "tscn", "tres", "godot", "other"]
const TAB_ISSUES := "Issues"
const TAB_FILES := "Files"
const CENSUS_HINT := "No file census yet. Run Project > Tools > Gnumaru's Full Scan."
const SORT_KEYS := ["path", "size", "created", "modified"]
const SORT_LABELS := {"path": "Path", "size": "Size", "created": "Created", "modified": "Modified"}
const TREE_COLUMNS := 9
## Files-tab inner views (hidden tabs of the view TabContainer):
## the 9-column table or the single-column concatenated rows.
const VIEW_COLUMNS := 0
const VIEW_FLAT := 1
## Tree button id of the per-issue hide button (Issues tab).
const HIDE_BUTTON_ID := 0
## Narrow button column width: icon-sized, so issue rows keep text
## height (well under twice the old ItemList row height).
const HIDE_COLUMN_WIDTH := 24
## Fallback hide glyph size (procedural X, used headless or when the
## editor theme has no Close icon): smaller than a text row.
const HIDE_ICON_SIZE := 12

static var _hide_icon_cache: Texture2D = null

var _by_path: Dictionary = {}
var _shown: Array = []
var _hidden := {}
var _show := {"error": true, "warning": true, "note": true}
var _types := {"gd": true, "tscn": true, "tres": true, "godot": true, "other": true}
var _census := {}
var _include_addons := true
var _goto: Callable = Callable()
var _rescan: Callable = Callable()
var _collapsed_cols := {}

var _issues: Tree = null
var _unhide_btn: Button = null
var _status: Label = null
var _files: Label = null
var _addons_btn: Button = null
var _tabs: TabContainer = null
var _tree: Tree = null
var _flat_tree: Tree = null
var _view_tabs: TabContainer = null
var _sort_opt: OptionButton = null
var _sort_desc_btn: CheckButton = null
var _sort_key := "path"
var _sort_desc := false
var _sev_btns := {}
var _type_btns := {}
var _built := false


## Resource bucket of an issue path (lowercased extension; anything
## unrecognized — including extensionless/empty paths — is "other").
## Pure, unit-tested headless.
static func resource_type(path: String) -> String:
	var p := path.strip_edges()
	var dot := p.rfind(".")
	var ext := p.substr(dot + 1).to_lower() if dot >= 0 else ""
	if ext == "gd" or ext == "tscn" or ext == "tres" or ext == "godot":
		return ext
	return "other"


## Display severity of an issue: "error"/"warning" as-is, anything
## else ("note", "info", future kinds) groups under "note". Pure.
static func normalize_severity(issue: Dictionary) -> String:
	var s := str(issue.get("severity", "error"))
	if s == "error" or s == "warning":
		return s
	return "note"


## Severity mark for a row (E/W/N). Pure.
static func severity_mark(sev: String) -> String:
	if sev == "warning":
		return "W"
	if sev == "note":
		return "N"
	return "E"


## One-line row text: "[E] res://addons/0GnumarusGodotProjectAnalyzerSuite/tests/ValidScript0.gd:10: [kind] message". Pure.
static func format_row(issue: Dictionary) -> String:
	var sev := normalize_severity(issue)
	var line := maxi(int(issue.get("line", 1)), 1)
	var scene_line := maxi(int(issue.get("scene_line", 0)), 0)
	if scene_line > 0:
		return "[%s] %s:%d:%d: [%s] %s" % [severity_mark(sev), str(issue.get("path", "?")), scene_line, line, str(issue.get("kind", "?")), str(issue.get("message", ""))]
	return "[%s] %s:%d: [%s] %s" % [severity_mark(sev), str(issue.get("path", "?")), line, str(issue.get("kind", "?")), str(issue.get("message", ""))]


## Filtered copy of issues: a row survives only when its severity
## toggle and its resource-type toggle are both on. Pure.
static func filter_issues(issues: Array, show: Dictionary, types: Dictionary) -> Array:
	var out: Array = []
	for e in issues:
		if not (e is Dictionary):
			continue
		if not bool(show.get(normalize_severity(e), false)):
			continue
		if not bool(types.get(resource_type(str((e as Dictionary).get("path", ""))), false)):
			continue
		out.append(e)
	return out


## Stable identity of one issue for the per-row hide button:
## issues sharing every field hide as one (they are indistinguishable
## on screen anyway). The node and scene line ride along so the same
## embedded error on two nodes (same path/script line) hides per node.
## Pure, unit-tested headless.
static func hide_key(issue: Dictionary) -> String:
	return "%s|%s|%s|%s|%d|%d|%s|%s|%d" % [
		str(issue.get("stage", "")),
		str(issue.get("severity", "")),
		str(issue.get("kind", "")),
		str(issue.get("path", "")),
		maxi(int(issue.get("line", 1)), 1),
		maxi(int(issue.get("column", 0)), 0),
		str(issue.get("message", "")),
		str(issue.get("node", "")),
		maxi(int(issue.get("scene_line", 0)), 0),
	]


## Issues minus the user-hidden ones (non-dicts dropped). Pure,
## unit-tested headless.
static func apply_hidden(issues: Array, hidden: Dictionary) -> Array:
	var out: Array = []
	for e in issues:
		if not (e is Dictionary):
			continue
		if bool((hidden as Dictionary).get(hide_key(e), false)):
			continue
		out.append(e)
	return out


## Status text: "E errors, W warnings[, N notes][ (+H hidden)]".
## Pure, unit-tested headless.
static func status_text(n_errors: int, n_warnings: int, n_notes: int, n_hidden: int) -> String:
	var parts: Array = []
	if n_errors > 0:
		parts.append("%d error%s" % [n_errors, "" if n_errors == 1 else "s"])
	if n_warnings > 0:
		parts.append("%d warning%s" % [n_warnings, "" if n_warnings == 1 else "s"])
	if n_notes > 0:
		parts.append("%d note%s" % [n_notes, "" if n_notes == 1 else "s"])
	if parts.is_empty():
		parts.append("no issues")
	if n_hidden > 0:
		parts.append("(+%d hidden)" % n_hidden)
	return "  ".join(parts)


## Project file census text: "12 files (8 gd, 3 tscn, 1 tres)" —
## extensions by count (ties alphabetical), "" when uncensused. With
## include_addons off only the plain project tree counts (old reports
## without the split fall back to the merged view). Pure.
static func census_text(census: Variant, include_addons := true) -> String:
	var view := census_view(census, include_addons)
	var total := maxi(int(view.get("total", 0)), 0)
	if total <= 0:
		return ""
	var exts: Dictionary = view.get("extensions", {})
	var keys: Array = exts.keys()
	keys.sort_custom(func(a: Variant, b: Variant) -> bool:
		var ca := int(exts.get(a, 0))
		var cb := int(exts.get(b, 0))
		if ca != cb:
			return ca > cb
		return str(a) < str(b))
	var parts: Array = []
	for k in keys:
		parts.append("%d %s" % [int(exts.get(k, 0)), str(k)])
	return "%d file%s (%s)" % [total, "" if total == 1 else "s", ", ".join(parts)]


## Census view for display: the plain project tree when addons are
## toggled off and the split exists, else the merged view (also the
## fallback for old reports and non-dicts). Pure.
static func census_view(census: Variant, include_addons: bool) -> Dictionary:
	if not (census is Dictionary):
		return {"extensions": {}, "total": 0}
	if not include_addons and (census as Dictionary).get("project") is Dictionary:
		return (census as Dictionary).get("project")
	return {"extensions": (census as Dictionary).get("extensions", {}), "total": (census as Dictionary).get("total", 0)}


## Unix mtime as UTC "YYYY-MM-DD hh:mm:ss", "" when unknown.
## Pure (Time only), unit-tested headless.
static func census_datetime(mtime: int) -> String:
	if mtime <= 0:
		return ""
	return Time.get_datetime_string_from_unix_time(mtime, true).replace("T", " ")


## One Files-tab summary row per shown group ("All files: 147 files,
## 45.2 MB (2024-03-01 → 2026-09-22)"): merged plus partitions with
## the split, project-only with the toggle off, merged-only without
## it. Size/dates render only when known (legacy reports show counts
## alone). Pure, unit-tested headless.
static func census_summary_rows(census: Variant, include_addons: bool) -> Array:
	if not (census is Dictionary):
		return []
	var groups: Array = []
	var split := (census as Dictionary).get("project") is Dictionary and (census as Dictionary).get("addons") is Dictionary
	if split and include_addons:
		groups = [["All files", (census as Dictionary)], ["project", (census as Dictionary).get("project")], ["addons", (census as Dictionary).get("addons")]]
	elif split:
		groups = [["project", (census as Dictionary).get("project")]]
	else:
		groups = [["All files", (census as Dictionary)]]
	var rows: Array = []
	for g in groups:
		var r := _census_group_row(str((g as Array)[0]), (g as Array)[1])
		if r != "":
			rows.append(r)
	return rows


## Single group summary row ("" when the group counts nothing).
## Prefers the stored human size, computing it from bytes as
## fallback. Pure.
static func _census_group_row(label: String, group: Variant) -> String:
	if not (group is Dictionary):
		return ""
	var total := maxi(int((group as Dictionary).get("total", 0)), 0)
	if total <= 0:
		return ""
	var head := "%s: %d file%s" % [label, total, "" if total == 1 else "s"]
	var detail := ""
	var bytes := maxi(int((group as Dictionary).get("bytes", 0)), 0)
	if bytes > 0:
		var size := str((group as Dictionary).get("size", ""))
		detail = size if size != "" else FullScan.human_size(bytes)
	var newest := maxi(int((group as Dictionary).get("newest", 0)), 0)
	if newest > 0:
		var oldest := maxi(int((group as Dictionary).get("oldest", 0)), 0)
		var span := "(%s → %s)" % [census_datetime(oldest) if oldest > 0 else "?", census_datetime(newest)]
		detail = (detail + " " + span).strip_edges()
	if detail == "":
		return head
	return head + ", " + detail


## One Files-tab row per extension ("gd: 120 (90 project + 30
## addons)" with the project/addons split, "gd: 120" without it),
## ordered by count (ties alphabetical), [] when uncensused. Pure,
## unit-tested headless.
static func census_rows(census: Variant, include_addons: bool) -> Array:
	var view := census_view(census, include_addons)
	var total := maxi(int(view.get("total", 0)), 0)
	if total <= 0:
		return []
	var exts: Dictionary = view.get("extensions", {})
	var keys: Array = exts.keys()
	keys.sort_custom(func(a: Variant, b: Variant) -> bool:
		var ca := int(exts.get(a, 0))
		var cb := int(exts.get(b, 0))
		if ca != cb:
			return ca > cb
		return str(a) < str(b))
	var split := include_addons and (census is Dictionary) and ((census as Dictionary).get("project") is Dictionary) and ((census as Dictionary).get("addons") is Dictionary)
	var proj: Dictionary = ((census as Dictionary).get("project", {}) as Dictionary).get("extensions", {}) if split else {}
	var adns: Dictionary = ((census as Dictionary).get("addons", {}) as Dictionary).get("extensions", {}) if split else {}
	var rows: Array = []
	for k in keys:
		if split:
			rows.append("%s: %d (%d project + %d addons)" % [str(k), int(exts.get(k, 0)), int(proj.get(k, 0)), int(adns.get(k, 0))])
		else:
			rows.append("%s: %d" % [str(k), int(exts.get(k, 0))])
	return rows


## File path without the res:// prefix (flat view shows paths bare
## to save space): "res://" becomes "/", anything else passes
## through untouched. Pure, unit-tested headless.
static func flat_path(path: String) -> String:
	var p := str(path)
	if p == "res://" or p == "res:/":
		return "/"
	if p.begins_with("res://"):
		return "/" + p.substr(6)
	return p


## One flat-view file row ("/a.png: created: …; modified: …; size:
## …"), stamps blank when unknown. Pure, unit-tested headless.
static func flat_file_row(f: Dictionary) -> String:
	return "%s: created: %s; modified: %s; size: %s" % [
		flat_path(str(f.get("path", ""))),
		census_datetime(maxi(int(f.get("created", 0)), 0)),
		census_datetime(maxi(int(f.get("modified", 0)), 0)),
		FullScan.human_size(maxi(int(f.get("size", 0)), 0)),
	]


## One flat-view directory row (direct/recursive sizes plus direct
## and total file/subdir counts). Pure, unit-tested headless.
static func flat_dir_row(d: Dictionary) -> String:
	return "%s: created: %s; modified: %s; size: %s; rec-size: %s; direct files: %d; all files: %d; direct dirs: %d; all dirs: %d" % [
		flat_path(str(d.get("path", ""))),
		census_datetime(maxi(int(d.get("created", 0)), 0)),
		census_datetime(maxi(int(d.get("modified", 0)), 0)),
		FullScan.human_size(maxi(int(d.get("size", 0)), 0)),
		FullScan.human_size(maxi(int(d.get("size_recursive", 0)), 0)),
		maxi(int(d.get("files", 0)), 0),
		maxi(int(d.get("files_recursive", 0)), 0),
		maxi(int(d.get("subdirs", 0)), 0),
		maxi(int(d.get("subdirs_recursive", 0)), 0),
	]


## File partitions shown in either Files-tab view: "project" plus
## "addons" unless toggled off (each [label, group dict]). Pure.
static func view_groups(census: Dictionary, include_addons: bool, files: Array) -> Array:
	var groups: Array = []
	if (census.get("project") is Dictionary) or not files.is_empty():
		groups.append(["project", (census.get("project", {}) as Dictionary)])
	if include_addons and ((census.get("addons") is Dictionary) or not files.is_empty()):
		groups.append(["addons", (census.get("addons", {}) as Dictionary)])
	return groups


## Inventory files belonging to one partition ("project" skips
## res://addons/ paths, "addons" keeps only those). Pure.
static func own_files(files: Array, label: String) -> Array:
	var own: Array = []
	for f in files:
		if not (f is Dictionary):
			continue
		var p := str((f as Dictionary).get("path", ""))
		if p == "":
			continue
		if label == "addons" and not FullScan.is_addons_path(p):
			continue
		if label == "project" and FullScan.is_addons_path(p):
			continue
		own.append(f)
	return own


## Inventory directories shown in either Files-tab view (addons paths
## hidden with the toggle off), sorted by path. Pure.
static func shown_dirs(dirs: Array, include_addons: bool) -> Array:
	var shown: Array = []
	for d in dirs:
		if not (d is Dictionary):
			continue
		var p := str((d as Dictionary).get("path", ""))
		if p == "":
			continue
		if not include_addons and FullScan.is_addons_path(p):
			continue
		shown.append(d)
	shown.sort_custom(func(a: Variant, b: Variant) -> bool: return str((a as Dictionary).get("path", "")) < str((b as Dictionary).get("path", "")))
	return shown


## Sort key guard ("path" fallback). Pure.
static func sanitize_sort_key(raw: Variant) -> String:
	return str(raw) if str(raw) in SORT_KEYS else "path"


## File entries sorted by key ("path"/"size"/"created"/"modified",
## anything else falls back to path), path-tied always, ascending
## unless descending. Returns a sorted copy; non-dicts dropped. Pure,
## unit-tested headless.
static func sort_file_entries(files: Array, sort_key: String, descending := false) -> Array:
	var rows: Array = []
	for f in files:
		if f is Dictionary:
			rows.append(f)
	var key := sanitize_sort_key(sort_key)
	rows.sort_custom(func(a: Variant, b: Variant) -> bool:
		var cmp := 0
		if key == "path":
			var pa := str((a as Dictionary).get("path", ""))
			var pb := str((b as Dictionary).get("path", ""))
			cmp = -1 if pa < pb else (1 if pa > pb else 0)
		else:
			var va := int((a as Dictionary).get(key, 0))
			var vb := int((b as Dictionary).get(key, 0))
			cmp = -1 if va < vb else (1 if va > vb else 0)
		if cmp == 0:
			var qa := str((a as Dictionary).get("path", ""))
			var qb := str((b as Dictionary).get("path", ""))
			cmp = -1 if qa < qb else (1 if qa > qb else 0)
		return cmp > 0 if descending else cmp < 0)
	return rows


## Toggled collapsed state for one Files-tab column: flips the flag
## for a valid column, ignores anything out of range, keeps every
## other entry. Returns a new dict (the input is never mutated).
## Pure, unit-tested headless.
static func toggle_collapsed_state(collapsed: Dictionary, column: int, total: int) -> Dictionary:
	var next := (collapsed as Dictionary).duplicate()
	if column < 0 or column >= total:
		return next
	next[column] = not bool(next.get(column, false))
	return next


## Loads the persisted filter state: the EditorSettings copy wins
## when present, otherwise the ScanResults.json copy, otherwise the
## defaults. Never fails.
static func load_filters() -> Dictionary:
	var from_editor := _read_editor_filters()
	if not (from_editor as Dictionary).is_empty():
		return sanitize_filters(from_editor)
	return sanitize_filters(FullScan.load_results().get("filters", {}))


## Persists the filter state to both backends (EditorSettings first,
## then the report file). Headless it still writes the file copy so
## the logic stays testable; callers gate on editor hint when they
## only want editor-UX persistence.
static func save_filters(show: Dictionary, types: Dictionary, include_addons := true, sort_key := "path", descending := false) -> void:
	var payload := {"show": show.duplicate(), "types": types.duplicate(), "include_addons": bool(include_addons), "sort": sanitize_sort_key(sort_key), "descending": bool(descending)}
	_write_editor_filters(payload)
	FullScan.store_filters(show, types, include_addons, sanitize_sort_key(sort_key), bool(descending))


## EditorSettings filter payload, or {} when unavailable (headless).
## Never fails.
static func _read_editor_filters() -> Dictionary:
	var settings := _editor_settings()
	if settings == null:
		return {}
	if not (settings as Object).has_method("has_setting") or not (settings as Object).has_method("get_setting"):
		return {}
	if not bool((settings as Object).call("has_setting", FILTERS_SETTING)):
		return {}
	var v: Variant = (settings as Object).call("get_setting", FILTERS_SETTING)
	if v is Dictionary:
		return v
	return {}


## Writes the EditorSettings filter payload; silent no-op when
## unavailable (headless). Never fails.
static func _write_editor_filters(payload: Dictionary) -> void:
	var settings := _editor_settings()
	if settings == null:
		return
	if not (settings as Object).has_method("set_setting"):
		return
	(settings as Object).call("set_setting", FILTERS_SETTING, payload)


## Editor settings object, or null outside the editor. Same guard
## shape as the EdTree editor resolvers.
static func _editor_settings() -> Object:
	if not Engine.is_editor_hint():
		return null
	if not Engine.has_singleton("EditorInterface"):
		return null
	var ei: Object = Engine.get_singleton("EditorInterface")
	if ei == null or not is_instance_valid(ei):
		return null
	if not (ei as Object).has_method("get_editor_settings"):
		return null
	var settings: Variant = (ei as Object).call("get_editor_settings")
	if settings == null or not (settings is Object) or not is_instance_valid(settings):
		return null
	return settings


func set_navigate_fn(fn: Callable) -> void:
	_goto = fn


func set_rescan_fn(fn: Callable) -> void:
	_rescan = fn


## Replaces the issues of one file (live analysis overlay).
func set_file_results(path: String, issues: Array) -> void:
	_ensure_built()
	_by_path[path] = issues.duplicate()
	refresh()


## Replaces everything with a full-scan report doc (its errors plus
## warnings, regrouped per path) and shows its file census.
func set_scan_results(doc: Dictionary) -> void:
	_ensure_built()
	_by_path = {}
	for key in ["errors", "warnings"]:
		for e in doc.get(key, []):
			if not (e is Dictionary):
				continue
			var p := str((e as Dictionary).get("path", ""))
			if not _by_path.has(p):
				_by_path[p] = []
			(_by_path[p] as Array).append(e)
	_census = doc.get("census", {})
	_paint_census()
	refresh()


## Replaces the file census display.
func set_census(census: Dictionary) -> void:
	_ensure_built()
	_census = census
	_paint_census()


func census_count() -> int:
	return maxi(int(census_view(_census, _include_addons).get("total", 0)), 0)


## Paints the census label (hidden when uncensused) and rebuilds
## both Files-tab trees (columns and flat). Never fails.
func _paint_census() -> void:
	_ensure_built()
	_files.text = census_text(_census, _include_addons)
	_files.visible = _files.text != ""
	_rebuild_file_tree()
	_rebuild_flat_tree()


## First issue line per path (min), for file-row navigation targets.
## Pure over the issues map.
static func _first_issue_lines(by_path: Dictionary) -> Dictionary:
	var out := {}
	for p in by_path.keys():
		var best := -1
		for e in (by_path[p] as Array):
			if e is Dictionary:
				var ln := maxi(int((e as Dictionary).get("line", 1)), 1)
				if best < 0 or ln < best:
					best = ln
		if best > 0:
			out[str(p)] = best
	return out


## Rebuilds the Files-tab tree from the census: one collapsed group
## row per file partition (project, addons unless toggled off) with
## sorted file children, plus a trailing directories group. File rows
## carry size/creation/modification and navigate to the file's first
## issue (line 1 when clean); group/dir rows are inert. Without a
## file inventory, legacy extension-count rows fill the groups; with
## no census at all, a single hint row. Never fails.
func _rebuild_file_tree() -> void:
	_ensure_built()
	_tree.clear()
	var root := _tree.create_item()
	var min_line := _first_issue_lines(_by_path)
	var census := _census if _census is Dictionary else {}
	var files: Array = (census.get("files", []) as Array).duplicate()
	var dirs: Array = (census.get("dirs", []) as Array).duplicate()
	if files.is_empty() and dirs.is_empty():
		_rebuild_legacy_rows(root, census)
		_refit_collapsed_columns()
		return
	for g in view_groups(census, _include_addons, files):
		_add_file_group(root, str((g as Array)[0]), (g as Array)[1], files, min_line)
	_add_dirs_group(root, dirs)
	if root.get_child_count() == 0:
		var hint := _tree.create_item(root)
		hint.set_text(0, CENSUS_HINT)
		_set_row_selectable(hint, false)
	_refit_collapsed_columns()


## Rebuilds the flat Files-tab tree from the same census: one row
## per group plus one concatenated single-column row per file and
## directory (no res:// prefix). File rows navigate like the column
## view; group/dir rows are inert. Legacy reports and the empty hint
## mirror the column view. Never fails.
func _rebuild_flat_tree() -> void:
	_ensure_built()
	_flat_tree.clear()
	var root := _flat_tree.create_item()
	var min_line := _first_issue_lines(_by_path)
	var census := _census if _census is Dictionary else {}
	var files: Array = (census.get("files", []) as Array).duplicate()
	var dirs: Array = (census.get("dirs", []) as Array).duplicate()
	if files.is_empty() and dirs.is_empty():
		_rebuild_flat_legacy_rows(root, census)
		return
	for g in view_groups(census, _include_addons, files):
		_add_flat_file_group(root, str((g as Array)[0]), (g as Array)[1], files, min_line)
	_add_flat_dirs_group(root, dirs)
	if root.get_child_count() == 0:
		var hint := _flat_tree.create_item(root)
		hint.set_text(0, CENSUS_HINT)
		_set_row_selectable(hint, false, 1)


## One collapsed flat file-group row with its sorted file children
## (single concatenated row per file).
func _add_flat_file_group(root: TreeItem, label: String, group: Variant, files: Array, min_line: Dictionary) -> void:
	var own := own_files(files, label)
	var summary := _census_group_row(label, group)
	if summary == "" and not own.is_empty():
		summary = "%s: %d file%s" % [label, own.size(), "" if own.size() == 1 else "s"]
	if summary == "":
		return
	var node := _flat_tree.create_item(root)
	node.set_text(0, summary)
	node.collapsed = true
	_set_row_selectable(node, false, 1)
	for f in sort_file_entries(own, _sort_key, _sort_desc):
		var fd := f as Dictionary
		var p := str(fd.get("path", ""))
		var row := _flat_tree.create_item(node)
		row.set_text(0, flat_file_row(fd))
		row.set_metadata(0, {"path": p, "line": int(min_line.get(p, 1))})


## Trailing flat directories group: one concatenated row per
## directory. Inert rows.
func _add_flat_dirs_group(root: TreeItem, dirs: Array) -> void:
	var shown := shown_dirs(dirs, _include_addons)
	if shown.is_empty():
		return
	var node := _flat_tree.create_item(root)
	node.set_text(0, "directories: %d" % shown.size())
	node.collapsed = true
	_set_row_selectable(node, false, 1)
	for d in shown:
		var row := _flat_tree.create_item(node)
		row.set_text(0, flat_dir_row(d))
		_set_row_selectable(row, false, 1)


## One collapsed file-group row with its sorted file children.
## Falls back to the live file count when the group dict carries no
## summary (hand-made censuses), so files never vanish silently.
func _add_file_group(root: TreeItem, label: String, group: Variant, files: Array, min_line: Dictionary) -> void:
	var own := own_files(files, label)
	var summary := _census_group_row(label, group)
	if summary == "" and not own.is_empty():
		summary = "%s: %d file%s" % [label, own.size(), "" if own.size() == 1 else "s"]
	if summary == "":
		return
	var node := _tree.create_item(root)
	node.set_text(0, summary)
	node.collapsed = true
	_set_row_selectable(node, false)
	for f in sort_file_entries(own, _sort_key, _sort_desc):
		var fd := f as Dictionary
		var p := str(fd.get("path", ""))
		var row := _tree.create_item(node)
		row.set_text(0, p)
		row.set_text(5, FullScan.human_size(maxi(int(fd.get("size", 0)), 0)))
		row.set_text(7, census_datetime(maxi(int(fd.get("created", 0)), 0)))
		row.set_text(8, census_datetime(maxi(int(fd.get("modified", 0)), 0)))
		row.set_metadata(0, {"path": p, "line": int(min_line.get(p, 1))})


## Trailing directories group: every directory with direct/recursive
## counts and sizes (addons paths hidden with the toggle off;
## aggregates always cover the full tree). Inert rows.
func _add_dirs_group(root: TreeItem, dirs: Array) -> void:
	var shown := shown_dirs(dirs, _include_addons)
	if shown.is_empty():
		return
	var node := _tree.create_item(root)
	node.set_text(0, "directories: %d" % shown.size())
	node.collapsed = true
	_set_row_selectable(node, false)
	for d in shown:
		var dd := d as Dictionary
		var row := _tree.create_item(node)
		row.set_text(0, str(dd.get("path", "")))
		row.set_text(1, str(maxi(int(dd.get("files", 0)), 0)))
		row.set_text(2, str(maxi(int(dd.get("subdirs", 0)), 0)))
		row.set_text(3, str(maxi(int(dd.get("files_recursive", 0)), 0)))
		row.set_text(4, str(maxi(int(dd.get("subdirs_recursive", 0)), 0)))
		row.set_text(5, FullScan.human_size(maxi(int(dd.get("size", 0)), 0)))
		row.set_text(6, FullScan.human_size(maxi(int(dd.get("size_recursive", 0)), 0)))
		row.set_text(7, census_datetime(maxi(int(dd.get("created", 0)), 0)))
		row.set_text(8, census_datetime(maxi(int(dd.get("modified", 0)), 0)))
		_set_row_selectable(row, false)


## Legacy rows for reports without a file inventory: extension-count
## children under each group, like the old flat list. Each group
## shows its own extensions (the merged view stands in for a missing
## project partition). Inert rows.
func _rebuild_legacy_rows(root: TreeItem, census: Dictionary) -> void:
	var proj: Dictionary = (census as Dictionary).get("project", {})
	if not (proj is Dictionary) or (proj as Dictionary).is_empty():
		proj = census
	var groups: Array = [["project", proj]]
	if _include_addons:
		groups.append(["addons", (census as Dictionary).get("addons", {})])
	var built := 0
	for g in groups:
		var gdict: Dictionary = (g as Array)[1]
		var summary := _census_group_row(str((g as Array)[0]), gdict)
		if summary == "":
			continue
		var node := _tree.create_item(root)
		node.set_text(0, summary)
		node.collapsed = true
		_set_row_selectable(node, false)
		built += 1
		for r in _sorted_count_rows(gdict.get("extensions", {})):
			var row := _tree.create_item(node)
			row.set_text(0, str(r))
			_set_row_selectable(row, false)
	if built == 0:
		var hint := _tree.create_item(root)
		hint.set_text(0, CENSUS_HINT)
		_set_row_selectable(hint, false)


## Flat legacy rows for reports without a file inventory:
## extension-count children under each group, one column. Inert rows.
func _rebuild_flat_legacy_rows(root: TreeItem, census: Dictionary) -> void:
	var proj: Dictionary = (census as Dictionary).get("project", {})
	if not (proj is Dictionary) or (proj as Dictionary).is_empty():
		proj = census
	var groups: Array = [["project", proj]]
	if _include_addons:
		groups.append(["addons", (census as Dictionary).get("addons", {})])
	var built := 0
	for g in groups:
		var gdict: Dictionary = (g as Array)[1]
		var summary := _census_group_row(str((g as Array)[0]), gdict)
		if summary == "":
			continue
		var node := _flat_tree.create_item(root)
		node.set_text(0, summary)
		node.collapsed = true
		_set_row_selectable(node, false, 1)
		built += 1
		for r in _sorted_count_rows(gdict.get("extensions", {})):
			var row := _flat_tree.create_item(node)
			row.set_text(0, str(r))
			_set_row_selectable(row, false, 1)
	if built == 0:
		var hint := _flat_tree.create_item(root)
		hint.set_text(0, CENSUS_HINT)
		_set_row_selectable(hint, false, 1)


## "ext: N" strings from an extensions map, count order with
## alphabetical ties. Pure.
static func _sorted_count_rows(exts: Variant) -> Array:
	var map: Dictionary = (exts as Dictionary) if exts is Dictionary else {}
	var keys: Array = map.keys()
	keys.sort_custom(func(a: Variant, b: Variant) -> bool:
		var ca := int(map.get(a, 0))
		var cb := int(map.get(b, 0))
		if ca != cb:
			return ca > cb
		return str(a) < str(b))
	var rows: Array = []
	for k in keys:
		rows.append("%s: %d" % [str(k), int(map.get(k, 0))])
	return rows


## Marks the columns of a row (un)selectable (single-column trees
## pass their width). Never fails.
func _set_row_selectable(row: TreeItem, selectable: bool, total := TREE_COLUMNS) -> void:
	if row == null or not is_instance_valid(row):
		return
	for c in range(maxi(total, 1)):
		row.set_selectable(c, selectable)


## Header click on a Files-tab column: left-click toggles that
## column between stretched and content-fit (other mouse buttons and
## out-of-range columns are ignored). The fit floor is measured, not
## trusted to the engine: header title plus every cell (hidden rows
## included, so expanding a group never truncates), with room for
## indentation, arrows, icons and padding. Never fails.
func _on_column_title_clicked(column: int, mouse_button: int) -> void:
	if mouse_button != MOUSE_BUTTON_LEFT:
		return
	if column < 0 or column >= TREE_COLUMNS:
		return
	_collapsed_cols = toggle_collapsed_state(_collapsed_cols, column, TREE_COLUMNS)
	_apply_column_collapse(column)


## Natural width of one column in pixels: the header title plus the
## widest cell, hidden rows included. Padding/indent/icon room errs
## generous on purpose (overestimates waste a few pixels,
## underestimates truncate). Zero when unreadable. Never fails.
func _column_fit_width(column: int) -> int:
	if _tree == null or not is_instance_valid(_tree):
		return 0
	if column < 0 or column >= TREE_COLUMNS:
		return 0
	var font := _tree.get_theme_font("font", "Tree")
	var fs := _tree.get_theme_font_size("font_size", "Tree")
	if font == null or fs <= 0:
		return 0
	var icon_w := 16
	if _tree.has_theme_constant("icon_max_width", "Tree"):
		icon_w = maxi(_tree.get_theme_constant("icon_max_width", "Tree"), 1)
	var indent := maxi(int(font.get_height(fs)), 1)
	var best := _fit_text_width(_tree.get_column_title(column), font, fs, 0, indent, 0)
	var root := _tree.get_root()
	if root != null and is_instance_valid(root):
		best = maxi(best, _subtree_fit_width(root, column, font, fs, indent, icon_w))
	return best


## Widest fitted cell under an item (its whole subtree, collapsed or
## not), `depth` levels below the top rows. Never fails.
func _subtree_fit_width(item: TreeItem, column: int, font: Font, fs: int, indent: int, icon_w: int) -> int:
	var best := 0
	var stack: Array = []
	for i in range(item.get_child_count()):
		stack.append([item.get_child(i), 0])
	while not stack.is_empty():
		var frame: Array = stack.pop_back()
		var node := frame[0] as TreeItem
		if node == null or not is_instance_valid(node):
			continue
		var depth := int(frame[1])
		var extra := 0
		if node.get_child_count() > 0 and column == 0:
			extra += icon_w
		if node.get_icon(column) != null:
			extra += icon_w
		best = maxi(best, _fit_text_width(node.get_text(column), font, fs, depth, indent, extra))
		for i in range(node.get_child_count()):
			stack.append([node.get_child(i), depth + 1])
	return best


## Fitted width of one cell text: string measure plus base padding,
## one indent step per depth level and icon/arrow room. Pure.
static func _fit_text_width(text: String, font: Font, fs: int, depth: int, indent: int, extra: int) -> int:
	if font == null or fs <= 0:
		return 0
	var w := int(font.get_string_size(str(text), HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x)
	return w + 12 + maxi(depth, 0) * maxi(indent, 0) + maxi(extra, 0)


## Applies the collapsed state of one column to the tree: expand off
## with the measured fit floor when collapsed (content never
## truncates), stretched otherwise. Clipping stays off both ways.
## Never fails.
func _apply_column_collapse(column: int) -> void:
	if _tree == null or not is_instance_valid(_tree):
		return
	if column < 0 or column >= TREE_COLUMNS:
		return
	if bool(_collapsed_cols.get(column, false)):
		_tree.set_column_expand(column, false)
		_tree.set_column_custom_minimum_width(column, _column_fit_width(column))
	else:
		_tree.set_column_expand(column, true)
		_tree.set_column_custom_minimum_width(column, 0)
	_tree.set_column_clip_content(column, false)


## Re-measures the floor of every collapsed column (content changes
## on every rebuild: rescan, sort, toggles). Never fails.
func _refit_collapsed_columns() -> void:
	if _tree == null or not is_instance_valid(_tree):
		return
	for c in _collapsed_cols.keys():
		if bool(_collapsed_cols.get(c, false)) and int(c) >= 0 and int(c) < TREE_COLUMNS:
			_apply_column_collapse(int(c))


## File-row activation in either Files-tab view: navigates to the
## file's first issue (line 1 when clean). Group/dir rows carry no
## target and stay inert.
func _on_tree_item_selected() -> void:
	_navigate_tree_selection(_tree)


## Same for the flat Files-tab view.
func _on_flat_item_selected() -> void:
	_navigate_tree_selection(_flat_tree)


## Shared row activation for both Files-tab trees. Never fails.
func _navigate_tree_selection(tree: Tree) -> void:
	if tree == null or not is_instance_valid(tree):
		return
	var sel := tree.get_selected()
	if sel == null or not is_instance_valid(sel):
		return
	var md: Variant = sel.get_metadata(0)
	if not (md is Dictionary) or str((md as Dictionary).get("path", "")) == "":
		return
	if _goto.is_valid():
		_goto.call(md)


## Files-tab view switch (hidden inner tabs): columns or flat.
## current_tab is set for the editor, and page visibility is synced
## immediately (TabContainer applies tab switches on a later layout
## pass, which headless runs without frames never reach). Out-of-range
## indices clamp. Never fails.
func _switch_file_view(idx: int) -> void:
	_ensure_built()
	if _view_tabs == null or not is_instance_valid(_view_tabs):
		return
	var clamped := clampi(idx, VIEW_COLUMNS, VIEW_FLAT)
	_view_tabs.current_tab = clamped
	for i in range(_view_tabs.get_tab_count()):
		var c := _view_tabs.get_tab_control(i)
		if c is Control and is_instance_valid(c):
			(c as Control).visible = (i == clamped)


## Sort dropdown: re-sorts the file groups, persisting the choice.
func _on_sort_changed(idx: int) -> void:
	if idx < 0 or idx >= SORT_KEYS.size():
		return
	_sort_key = str(SORT_KEYS[idx])
	_persist_filters()
	_rebuild_file_tree()
	_rebuild_flat_tree()


## Order toggle: flips ascending/descending, persisting the choice.
func _on_desc_toggled(pressed_on: bool) -> void:
	_sort_desc = bool(pressed_on)
	if _sort_desc_btn != null and is_instance_valid(_sort_desc_btn):
		_sort_desc_btn.button_pressed = _sort_desc
	_persist_filters()
	_rebuild_file_tree()
	_rebuild_flat_tree()


## Drops every known issue.
func clear_all() -> void:
	_ensure_built()
	_by_path = {}
	refresh()


func total_count() -> int:
	var n := 0
	for p in _by_path.keys():
		n += (_by_path[p] as Array).size()
	return n


func shown_count() -> int:
	return _shown.size()


func shown_issues() -> Array:
	return _shown.duplicate()


func _ensure_built() -> void:
	if _built:
		return
	_built = true
	name = "GnumarusDock"
	var toolbar := HBoxContainer.new()
	toolbar.name = "Toolbar"
	add_child(toolbar)
	for sev in SEVERITIES:
		var b := _make_toggle(str(SEV_LABELS.get(sev, sev)), "Show " + str(SEV_LABELS.get(sev, sev)).to_lower())
		b.button_pressed = true
		b.pressed.connect(_on_sev_toggled.bind(sev))
		toolbar.add_child(b)
		_sev_btns[sev] = b
	toolbar.add_child(VSeparator.new())
	for t in TYPES:
		var tb := _make_toggle(t, "Show " + t + " files")
		tb.button_pressed = true
		tb.pressed.connect(_on_type_toggled.bind(t))
		toolbar.add_child(tb)
		_type_btns[t] = tb
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	toolbar.add_child(spacer)
	_status = Label.new()
	_status.text = DOCK_HINT
	_status.clip_text = true
	_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	toolbar.add_child(_status)
	var rescan := Button.new()
	rescan.text = "Rescan"
	rescan.focus_mode = Control.FOCUS_NONE
	rescan.tooltip_text = "Run the Gnumarus full scan now"
	rescan.pressed.connect(_on_rescan)
	toolbar.add_child(rescan)
	var clear := Button.new()
	clear.text = "Clear"
	clear.focus_mode = Control.FOCUS_NONE
	clear.tooltip_text = "Clear the issue list"
	clear.pressed.connect(_on_clear)
	toolbar.add_child(clear)
	_unhide_btn = Button.new()
	_unhide_btn.text = "Unhide (0)"
	_unhide_btn.focus_mode = Control.FOCUS_NONE
	_unhide_btn.tooltip_text = "Show every hidden issue again"
	_unhide_btn.disabled = true
	_unhide_btn.pressed.connect(_on_unhide_all)
	toolbar.add_child(_unhide_btn)
	_tabs = TabContainer.new()
	_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(_tabs)
	_issues = Tree.new()
	_issues.name = TAB_ISSUES
	_issues.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_issues.columns = 2
	_issues.hide_root = true
	_issues.column_titles_visible = false
	_issues.allow_reselect = true
	_issues.set_column_expand(1, false)
	_issues.set_column_custom_minimum_width(1, HIDE_COLUMN_WIDTH)
	_issues.set_column_clip_content(1, true)
	_issues.item_selected.connect(_on_item_selected)
	if _issues.has_signal("button_clicked"):
		_issues.button_clicked.connect(_on_issue_button_clicked)
	_tabs.add_child(_issues)
	var files_page := VBoxContainer.new()
	files_page.name = TAB_FILES
	files_page.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tabs.add_child(files_page)
	var files_bar := HBoxContainer.new()
	files_bar.name = "FilesBar"
	files_page.add_child(files_bar)
	_files = Label.new()
	_files.text = ""
	_files.visible = false
	_files.clip_text = true
	_files.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_files.tooltip_text = "Project files by extension (last full scan)"
	files_bar.add_child(_files)
	_addons_btn = _make_toggle("Include Addons", "Include res://addons/ files in the census")
	_addons_btn.button_pressed = true
	_addons_btn.pressed.connect(_on_addons_toggled)
	files_bar.add_child(_addons_btn)
	_sort_opt = OptionButton.new()
	_sort_opt.focus_mode = Control.FOCUS_NONE
	_sort_opt.tooltip_text = "Sort files by"
	_sort_opt.fit_to_longest_item = false
	_sort_opt.clip_text = true
	for k in SORT_KEYS:
		_sort_opt.add_item(str(SORT_LABELS.get(k, k)))
	_sort_opt.selected = 0
	_sort_opt.item_selected.connect(_on_sort_changed)
	files_bar.add_child(_sort_opt)
	_sort_desc_btn = CheckButton.new()
	_sort_desc_btn.text = "Descending"
	_sort_desc_btn.focus_mode = Control.FOCUS_NONE
	_sort_desc_btn.tooltip_text = "Reverse the file order"
	_sort_desc_btn.toggled.connect(_on_desc_toggled)
	files_bar.add_child(_sort_desc_btn)
	_tree = Tree.new()
	_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tree.columns = TREE_COLUMNS
	_tree.set_column_title(0, "Path")
	_tree.set_column_title(1, "Files")
	_tree.set_column_title(2, "Subdirs")
	_tree.set_column_title(3, "Files (rec)")
	_tree.set_column_title(4, "Subdirs (rec)")
	_tree.set_column_title(5, "Size")
	_tree.set_column_title(6, "Size (rec)")
	_tree.set_column_title(7, "Created")
	_tree.set_column_title(8, "Modified")
	_tree.hide_root = true
	_tree.column_titles_visible = true
	_tree.column_title_clicked.connect(_on_column_title_clicked)
	_tree.item_selected.connect(_on_tree_item_selected)
	_view_tabs = TabContainer.new()
	_view_tabs.tabs_visible = false
	_view_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_view_tabs.current_tab = VIEW_COLUMNS
	files_page.add_child(_view_tabs)
	var columns_page := VBoxContainer.new()
	columns_page.name = "Columns"
	columns_page.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_view_tabs.add_child(columns_page)
	var columns_bar := HBoxContainer.new()
	columns_bar.name = "ColumnsBar"
	columns_page.add_child(columns_bar)
	var to_flat := Button.new()
	to_flat.text = "Single column"
	to_flat.focus_mode = Control.FOCUS_NONE
	to_flat.tooltip_text = "Show the census as single-column rows"
	to_flat.pressed.connect(_switch_file_view.bind(VIEW_FLAT))
	columns_bar.add_child(to_flat)
	columns_page.add_child(_tree)
	var flat_page := VBoxContainer.new()
	flat_page.name = "Flat"
	flat_page.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_view_tabs.add_child(flat_page)
	var flat_bar := HBoxContainer.new()
	flat_bar.name = "FlatBar"
	flat_page.add_child(flat_bar)
	var to_columns := Button.new()
	to_columns.text = "Columns"
	to_columns.focus_mode = Control.FOCUS_NONE
	to_columns.tooltip_text = "Show the census as a column table"
	to_columns.pressed.connect(_switch_file_view.bind(VIEW_COLUMNS))
	flat_bar.add_child(to_columns)
	_flat_tree = Tree.new()
	_flat_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_flat_tree.columns = 1
	_flat_tree.hide_root = true
	_flat_tree.column_titles_visible = false
	_flat_tree.item_selected.connect(_on_flat_item_selected)
	flat_page.add_child(_flat_tree)
	_switch_file_view(VIEW_COLUMNS)
	if Engine.is_editor_hint():
		_apply_filters(load_filters())
		_census = FullScan.load_results().get("census", {})
	_paint_census()
	refresh()


## Merges a stored filter payload over the defaults: unknown keys
## dropped, missing keys kept on, non-dicts ignored, sort key
## validated, descending strictly boolean. Pure.
static func sanitize_filters(raw: Variant) -> Dictionary:
	var clean := FullScan.default_filters()
	if not (raw is Dictionary):
		return clean
	var stored_show: Variant = (raw as Dictionary).get("show", {})
	var stored_types: Variant = (raw as Dictionary).get("types", {})
	if stored_show is Dictionary:
		for k in (clean.get("show", {}) as Dictionary).keys():
			if (stored_show as Dictionary).has(k):
				(clean.get("show", {}) as Dictionary)[k] = bool((stored_show as Dictionary).get(k, true))
	if stored_types is Dictionary:
		for k in (clean.get("types", {}) as Dictionary).keys():
			if (stored_types as Dictionary).has(k):
				(clean.get("types", {}) as Dictionary)[k] = bool((stored_types as Dictionary).get(k, true))
	var stored_addons: Variant = (raw as Dictionary).get("include_addons", true)
	clean["include_addons"] = stored_addons if stored_addons is bool else true
	clean["sort"] = sanitize_sort_key((raw as Dictionary).get("sort", "path"))
	var stored_desc: Variant = (raw as Dictionary).get("descending", false)
	clean["descending"] = stored_desc if stored_desc is bool else false
	return clean


## Applies a persisted filter payload to the state and buttons
## (sanitized: unknown keys dropped, missing keys on).
func _apply_filters(stored: Dictionary) -> void:
	var clean := sanitize_filters(stored)
	_show = (clean.get("show", {}) as Dictionary).duplicate()
	_types = (clean.get("types", {}) as Dictionary).duplicate()
	_include_addons = bool(clean.get("include_addons", true))
	_sort_key = sanitize_sort_key(clean.get("sort", "path"))
	_sort_desc = bool(clean.get("descending", false))
	for k in _show.keys():
		if _sev_btns.has(k):
			(_sev_btns[k] as Button).button_pressed = bool(_show.get(k, true))
	for k in _types.keys():
		if _type_btns.has(k):
			(_type_btns[k] as Button).button_pressed = bool(_types.get(k, true))
	if _addons_btn != null and is_instance_valid(_addons_btn):
		_addons_btn.button_pressed = _include_addons
	if _sort_opt != null and is_instance_valid(_sort_opt):
		_sort_opt.select(maxi(SORT_KEYS.find(_sort_key), 0))
	if _sort_desc_btn != null and is_instance_valid(_sort_desc_btn):
		_sort_desc_btn.button_pressed = _sort_desc


static func _make_toggle(label_text: String, tip: String) -> Button:
	var b := Button.new()
	b.text = label_text
	b.toggle_mode = true
	b.focus_mode = Control.FOCUS_NONE
	b.tooltip_text = tip
	return b


func _on_sev_toggled(sev: String) -> void:
	_show[sev] = bool((_sev_btns[sev] as Button).button_pressed)
	_persist_filters()
	refresh()


func _on_type_toggled(t: String) -> void:
	_types[t] = bool((_type_btns[t] as Button).button_pressed)
	_persist_filters()
	refresh()


func _on_addons_toggled() -> void:
	if _addons_btn != null and is_instance_valid(_addons_btn):
		_include_addons = _addons_btn.button_pressed
	_persist_filters()
	_paint_census()


## Writes the current toggle state to both backends, editor-only: in
## tests (headless) flips stay in-memory so suites never touch the
## real report file implicitly (save_filters itself stays directly
## testable).
func _persist_filters() -> void:
	if not Engine.is_editor_hint():
		return
	save_filters(_show, _types, _include_addons, _sort_key, _sort_desc)


func _on_rescan() -> void:
	if _rescan.is_valid():
		_rescan.call()


func _on_clear() -> void:
	clear_all()


func _on_item_selected() -> void:
	if _issues == null or not is_instance_valid(_issues):
		return
	var sel := _issues.get_selected()
	if sel == null or not is_instance_valid(sel):
		return
	var md: Variant = sel.get_metadata(0)
	if not (md is Dictionary):
		return
	if _goto.is_valid():
		_goto.call(md)


## Hide-button click on an issue row: left-click hides that single
## issue (other buttons, columns and out-of-range ids ignored).
## Never fails.
func _on_issue_button_clicked(item: TreeItem, column: int, id: int, mouse_button: int) -> void:
	if mouse_button != MOUSE_BUTTON_LEFT or id != HIDE_BUTTON_ID:
		return
	if item == null or not is_instance_valid(item):
		return
	var md: Variant = item.get_metadata(0)
	if not (md is Dictionary):
		return
	_hidden[hide_key(md)] = true
	refresh()


## Re-shows every hidden issue. Never fails.
func _on_unhide_all() -> void:
	_hidden.clear()
	refresh()


## Rebuilds the visible rows from _by_path through the toggles and
## the hidden set (stale hidden keys with no live issue are pruned,
## so the set never grows stale).
func refresh() -> void:
	_ensure_built()
	var all: Array = []
	for p in _by_path.keys():
		for e in (_by_path[p] as Array):
			all.append(e)
	_shown = apply_hidden(filter_issues(all, _show, _types), _hidden)
	var live := {}
	for e in all:
		if e is Dictionary:
			live[hide_key(e)] = true
	for k in _hidden.keys():
		if not live.has(k):
			_hidden.erase(k)
	_issues.clear()
	var root := _issues.create_item()
	var glyph := hide_icon()
	for e in _shown:
		var row := _issues.create_item(root)
		row.set_text(0, format_row(e))
		var icon := _severity_icon(e)
		if icon != null:
			row.set_icon(0, icon)
		row.add_button(1, glyph, HIDE_BUTTON_ID, false, "Hide this issue")
		row.set_metadata(0, e)
	_update_unhide_btn()
	var n_err := 0
	var n_warn := 0
	var n_note := 0
	for e in _shown:
		match normalize_severity(e):
			"error":
				n_err += 1
			"warning":
				n_warn += 1
			_:
				n_note += 1
	if _shown.is_empty() and total_count() == 0:
		_status.text = DOCK_HINT
	else:
		_status.text = "GNMR Analyzer: " + status_text(n_err, n_warn, n_note, total_count() - _shown.size())


## Updates the toolbar Unhide button (count label, disabled when
## nothing is hidden). Never fails.
func _update_unhide_btn() -> void:
	if _unhide_btn == null or not is_instance_valid(_unhide_btn):
		return
	_unhide_btn.text = "Unhide (%d)" % _hidden.size()
	_unhide_btn.disabled = _hidden.is_empty()


## Hide-button glyph: the editor Close icon when available, else a
## small procedural X (12px, visible on dark and light themes) so
## headless runs and bare themes still get a button. Never fails.
static func hide_icon() -> Texture2D:
	var ed := EdTree.editor_status_icon("Close")
	if ed != null:
		return ed
	if _hide_icon_cache != null and is_instance_valid(_hide_icon_cache):
		return _hide_icon_cache
	var s := HIDE_ICON_SIZE
	var img := Image.create(s, s, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var ink := Color(0.55, 0.55, 0.55, 1.0)
	for i in range(2, s - 2):
		for t in range(-1, 2):
			var j1 := i + t
			var j2 := s - 1 - i + t
			if j1 >= 0 and j1 < s:
				img.set_pixel(i, j1, ink)
			if j2 >= 0 and j2 < s:
				img.set_pixel(i, j2, ink)
	_hide_icon_cache = ImageTexture.create_from_image(img)
	return _hide_icon_cache


## Console glyph for a row severity (null headless/unknown: the row
## then renders text-only). Never fails.
static func _severity_icon(issue: Variant) -> Texture2D:
	if not (issue is Dictionary):
		return null
	match normalize_severity(issue):
		"error":
			return EdTree.editor_error_icon()
		"warning":
			return EdTree.editor_warning_icon()
		_:
			return EdTree.editor_status_icon("Info")
	return null
