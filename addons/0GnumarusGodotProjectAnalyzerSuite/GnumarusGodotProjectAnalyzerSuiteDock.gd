extends VBoxContainer

## Bottom-panel dock listing every Gnumarus analyzer issue known for
## the project: live per-file results from analyze_current overlaid on
## the last full-scan report (ScanResults.json, loaded on build).
##
## Two tabs share one toolbar: "Issues" (the filtered error/warning
## list) and "Files" (the project file census in two visible inner
## tabs, "Table" and "Text", each split into a files section and a
## directories section). The table tab holds two separate 9-column
## Trees — one listing only files (grouped by project/addons
## partition), one listing only directories — each with its own
## Include Addons toggle, sort dropdown and descending switch; the
## text tab mirrors both sections as single-column concatenated rows
## without the res:// prefix, following the same per-panel state.
## Clicking a column header compacts that column to fit its content
## (never truncated); clicking again stretches it back. Every issue row
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
## Files-only table width: Path, Size, Created, Modified (the
## file/subdir count columns only make sense for directories).
const FILES_COLUMNS := 4
const FILE_COL_SIZE := 1
const FILE_COL_CREATED := 2
const FILE_COL_MODIFIED := 3
## Files-tab inner views (visible tabs of the view TabContainer):
## the 9-column tables or the single-column concatenated rows.
const TAB_TABLE := "Table"
const TAB_TEXT := "Text"
## Files-tab panels (one state triple each: addons toggle, sort key,
## descending switch). "files" lists files, "dirs" lists directories.
const PANEL_FILES := "files"
const PANEL_DIRS := "dirs"
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
## Per-panel Files-tab state: {"files": {...}, "dirs": {...}}, each
## {"include_addons": bool, "sort": key, "descending": bool}. The
## table and text views of a panel share its triple.
var _panel := {
	PANEL_FILES: {"include_addons": true, "sort": "path", "descending": false},
	PANEL_DIRS: {"include_addons": true, "sort": "path", "descending": false},
}
var _goto: Callable = Callable()
var _rescan: Callable = Callable()
## Column-collapse state per table tree ({"files": {col: bool},
## "dirs": {col: bool}}): the two tables have different layouts, so a
## collapsed Size here never touches the dirs table.
var _collapsed_cols := {"files": {}, "dirs": {}}

var _issues: Tree = null
var _unhide_btn: Button = null
var _status: Label = null
var _files: Label = null
var _tabs: TabContainer = null
## Files-tab column Trees (files-only and directories-only).
var _files_tree: Tree = null
var _dirs_tree: Tree = null
## Files-tab text mirrors (single column, same per-panel state).
var _files_flat: Tree = null
var _dirs_flat: Tree = null
var _view_tabs: TabContainer = null
## Per-panel widgets: {panel: {"addons": Button, "sort": OptionButton,
## "desc": CheckButton}}.
var _panel_widgets := {}
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


## Inventory files grouped by extension (same buckets as
## FullScan.census_ext, dotted for display): [[ext, [files...]], ...]
## with extensions alphabetical and files in input order. Pure,
## unit-tested headless.
static func group_files_by_ext(files: Array) -> Array:
	var buckets := {}
	var order: Array = []
	for f in files:
		if not (f is Dictionary):
			continue
		var ext := FullScan.census_ext(str((f as Dictionary).get("path", "")))
		if not buckets.has(ext):
			buckets[ext] = []
			order.append(ext)
		(buckets[ext] as Array).append(f)
	order.sort()
	var out: Array = []
	for ext in order:
		out.append([ext, buckets[ext]])
	return out


## Display label of an extension bucket (".gd", "(no ext)" as-is).
## Pure.
static func ext_label(ext: String) -> String:
	if str(ext) == "" or str(ext) == "(no ext)":
		return "(no ext)"
	return "." + str(ext)


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


## Directory entries sorted like files ("size" reads the direct byte
## sum), path-tied always. Returns a sorted copy; non-dicts and
## pathless entries dropped. Pure, unit-tested headless.
static func sort_dir_entries(dirs: Array, sort_key: String, descending := false) -> Array:
	var rows: Array = []
	for d in dirs:
		if d is Dictionary and str((d as Dictionary).get("path", "")) != "":
			rows.append(d)
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
static func save_filters(show: Dictionary, types: Dictionary, files_state := {}, dirs_state := {}) -> void:
	var payload := {"show": show.duplicate(), "types": types.duplicate(), "files": FullScan.normalize_panel_state(files_state), "dirs": FullScan.normalize_panel_state(dirs_state)}
	_write_editor_filters(payload)
	FullScan.store_filters(show, types, files_state, dirs_state)


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
	return maxi(int(census_view(_census, _panel_addons(PANEL_FILES)).get("total", 0)), 0)


## State triple of one Files-tab panel (never null: unknown panels
## read as the files default). Never fails.
func _panel_state(panel: String) -> Dictionary:
	var st: Variant = _panel.get(panel, {})
	if st is Dictionary and not (st as Dictionary).is_empty():
		return st
	return FullScan.default_panel_state()


## One Files-tab panel flag/key: addons toggle, sort key, order.
func _panel_addons(panel: String) -> bool:
	return bool(_panel_state(panel).get("include_addons", true))


func _panel_sort(panel: String) -> String:
	return sanitize_sort_key(_panel_state(panel).get("sort", "path"))


func _panel_desc(panel: String) -> bool:
	return bool(_panel_state(panel).get("descending", false))


## Paints the census label (hidden when uncensused; counts follow the
## files panel) and rebuilds all four Files-tab trees. Never fails.
func _paint_census() -> void:
	_ensure_built()
	_files.text = census_text(_census, _panel_addons(PANEL_FILES))
	_files.visible = _files.text != ""
	_rebuild_files_tree()
	_rebuild_dirs_tree()
	_rebuild_files_flat()
	_rebuild_dirs_flat()


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


## Rebuilds the files-only column tree: one collapsed group row per
## file partition (project, addons unless toggled off) with sorted
## file children. File rows carry size/creation/modification and
## navigate to the file's first issue (line 1 when clean); group rows
## are inert. Without a file inventory, legacy extension-count rows
## fill the groups; with no census at all, a single hint row. Never
## fails.
func _rebuild_files_tree() -> void:
	_ensure_built()
	_files_tree.clear()
	var root := _files_tree.create_item()
	var min_line := _first_issue_lines(_by_path)
	var census := _census if _census is Dictionary else {}
	var files: Array = (census.get("files", []) as Array).duplicate()
	if files.is_empty():
		_rebuild_files_legacy_rows(root, census)
		_refit_collapsed_columns()
		return
	for g in view_groups(census, _panel_addons(PANEL_FILES), files):
		_add_file_group(_files_tree, root, str((g as Array)[0]), (g as Array)[1], files, min_line)
	if root.get_child_count() == 0:
		_add_tree_hint(_files_tree, root)
	_refit_collapsed_columns()


## Rebuilds the directories-only column tree: every directory with
## direct/recursive counts and sizes, sorted by the dirs panel state
## (addons paths hidden with the toggle off; aggregates always cover
## the full tree). All rows inert; a single hint row when empty.
## Never fails.
func _rebuild_dirs_tree() -> void:
	_ensure_built()
	_dirs_tree.clear()
	var root := _dirs_tree.create_item()
	var census := _census if _census is Dictionary else {}
	var dirs: Array = (census.get("dirs", []) as Array).duplicate()
	var shown := sort_dir_entries(shown_dirs(dirs, _panel_addons(PANEL_DIRS)), _panel_sort(PANEL_DIRS), _panel_desc(PANEL_DIRS))
	for d in shown:
		_add_dir_row(_dirs_tree, root, d)
	if root.get_child_count() == 0:
		_add_tree_hint(_dirs_tree, root)
	_refit_collapsed_columns()


## Single hint row on a column tree. Never fails.
func _add_tree_hint(tree: Tree, root: TreeItem) -> void:
	var hint := tree.create_item(root)
	hint.set_text(0, CENSUS_HINT)
	_set_row_selectable(hint, false)


## One directory row on a column tree (inert). Never fails.
func _add_dir_row(tree: Tree, parent: TreeItem, d: Variant) -> void:
	if not (d is Dictionary):
		return
	var dd := d as Dictionary
	var row := tree.create_item(parent)
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


## Rebuilds the files-only flat tree from the same census: one row
## per group plus one concatenated single-column row per file (no
## res:// prefix). File rows navigate like the column view; group
## rows are inert. Legacy reports and the empty hint mirror the
## column view. Never fails.
func _rebuild_files_flat() -> void:
	_ensure_built()
	_files_flat.clear()
	var root := _files_flat.create_item()
	var min_line := _first_issue_lines(_by_path)
	var census := _census if _census is Dictionary else {}
	var files: Array = (census.get("files", []) as Array).duplicate()
	if files.is_empty():
		_rebuild_files_flat_legacy_rows(root, census)
		return
	for g in view_groups(census, _panel_addons(PANEL_FILES), files):
		_add_flat_file_group(root, str((g as Array)[0]), (g as Array)[1], files, min_line)
	if root.get_child_count() == 0:
		var hint := _files_flat.create_item(root)
		hint.set_text(0, CENSUS_HINT)
		_set_row_selectable(hint, false, 1)


## Rebuilds the directories-only flat tree: one concatenated row per
## directory, same panel state as the column view. Inert rows; a
## single hint row when empty. Never fails.
func _rebuild_dirs_flat() -> void:
	_ensure_built()
	_dirs_flat.clear()
	var root := _dirs_flat.create_item()
	var census := _census if _census is Dictionary else {}
	var dirs: Array = (census.get("dirs", []) as Array).duplicate()
	var shown := sort_dir_entries(shown_dirs(dirs, _panel_addons(PANEL_DIRS)), _panel_sort(PANEL_DIRS), _panel_desc(PANEL_DIRS))
	for d in shown:
		var row := _dirs_flat.create_item(root)
		row.set_text(0, flat_dir_row(d))
		_set_row_selectable(row, false, 1)
	if root.get_child_count() == 0:
		var hint := _dirs_flat.create_item(root)
		hint.set_text(0, CENSUS_HINT)
		_set_row_selectable(hint, false, 1)


## One collapsed flat file-group row with one collapsed extension
## subgroup per bucket holding the sorted concatenated file rows
## (single column, no res:// prefix).
func _add_flat_file_group(root: TreeItem, label: String, group: Variant, files: Array, min_line: Dictionary) -> void:
	var own := own_files(files, label)
	var summary := _census_group_row(label, group)
	if summary == "" and not own.is_empty():
		summary = "%s: %d file%s" % [label, own.size(), "" if own.size() == 1 else "s"]
	if summary == "":
		return
	var node := _files_flat.create_item(root)
	node.set_text(0, summary)
	node.collapsed = true
	_set_row_selectable(node, false, 1)
	for bucket in group_files_by_ext(own):
		var sub := _files_flat.create_item(node)
		sub.set_text(0, ext_label(str((bucket as Array)[0])))
		sub.collapsed = true
		_set_row_selectable(sub, false, 1)
		for f in sort_file_entries((bucket as Array)[1], _panel_sort(PANEL_FILES), _panel_desc(PANEL_FILES)):
			var fd := f as Dictionary
			var p := str(fd.get("path", ""))
			var row := _files_flat.create_item(sub)
			row.set_text(0, flat_file_row(fd))
			row.set_metadata(0, {"path": p, "line": int(min_line.get(p, 1))})


## One collapsed file-group row with one collapsed extension
## subgroup per bucket (project > .gd > files) holding the sorted
## file children. Falls back to the live file count when the group
## dict carries no summary (hand-made censuses), so files never
## vanish silently. File rows carry size/creation/modification only.
func _add_file_group(tree: Tree, root: TreeItem, label: String, group: Variant, files: Array, min_line: Dictionary) -> void:
	var own := own_files(files, label)
	var summary := _census_group_row(label, group)
	if summary == "" and not own.is_empty():
		summary = "%s: %d file%s" % [label, own.size(), "" if own.size() == 1 else "s"]
	if summary == "":
		return
	var node := tree.create_item(root)
	node.set_text(0, summary)
	node.collapsed = true
	_set_row_selectable(node, false, FILES_COLUMNS)
	for bucket in group_files_by_ext(own):
		var ext := str((bucket as Array)[0])
		var sub := tree.create_item(node)
		sub.set_text(0, ext_label(ext))
		sub.collapsed = true
		_set_row_selectable(sub, false, FILES_COLUMNS)
		for f in sort_file_entries((bucket as Array)[1], _panel_sort(PANEL_FILES), _panel_desc(PANEL_FILES)):
			_add_files_table_row(tree, sub, f, min_line)


## One file row on the files-only table (navigable). Never fails.
func _add_files_table_row(tree: Tree, parent: TreeItem, f: Variant, min_line: Dictionary) -> void:
	if not (f is Dictionary):
		return
	var fd := f as Dictionary
	var p := str(fd.get("path", ""))
	var row := tree.create_item(parent)
	row.set_text(0, p)
	row.set_text(FILE_COL_SIZE, FullScan.human_size(maxi(int(fd.get("size", 0)), 0)))
	row.set_text(FILE_COL_CREATED, census_datetime(maxi(int(fd.get("created", 0)), 0)))
	row.set_text(FILE_COL_MODIFIED, census_datetime(maxi(int(fd.get("modified", 0)), 0)))
	row.set_metadata(0, {"path": p, "line": int(min_line.get(p, 1))})


## Legacy rows for the files-only column tree (reports without a
## file inventory): extension-count children under each group, like
## the old flat list. Each group shows its own extensions (the merged
## view stands in for a missing project partition). Inert rows.
func _rebuild_files_legacy_rows(root: TreeItem, census: Dictionary) -> void:
	var proj: Dictionary = (census as Dictionary).get("project", {})
	if not (proj is Dictionary) or (proj as Dictionary).is_empty():
		proj = census
	var groups: Array = [["project", proj]]
	if _panel_addons(PANEL_FILES):
		groups.append(["addons", (census as Dictionary).get("addons", {})])
	var built := 0
	for g in groups:
		var gdict: Dictionary = (g as Array)[1]
		var summary := _census_group_row(str((g as Array)[0]), gdict)
		if summary == "":
			continue
		var node := _files_tree.create_item(root)
		node.set_text(0, summary)
		node.collapsed = true
		_set_row_selectable(node, false)
		built += 1
		for r in _sorted_count_rows(gdict.get("extensions", {})):
			var row := _files_tree.create_item(node)
			row.set_text(0, str(r))
			_set_row_selectable(row, false)
	if built == 0:
		var hint := _files_tree.create_item(root)
		hint.set_text(0, CENSUS_HINT)
		_set_row_selectable(hint, false)


## Flat legacy rows for the files-only text tree (reports without a
## file inventory): extension-count children under each group, one
## column. Inert rows.
func _rebuild_files_flat_legacy_rows(root: TreeItem, census: Dictionary) -> void:
	var proj: Dictionary = (census as Dictionary).get("project", {})
	if not (proj is Dictionary) or (proj as Dictionary).is_empty():
		proj = census
	var groups: Array = [["project", proj]]
	if _panel_addons(PANEL_FILES):
		groups.append(["addons", (census as Dictionary).get("addons", {})])
	var built := 0
	for g in groups:
		var gdict: Dictionary = (g as Array)[1]
		var summary := _census_group_row(str((g as Array)[0]), gdict)
		if summary == "":
			continue
		var node := _files_flat.create_item(root)
		node.set_text(0, summary)
		node.collapsed = true
		_set_row_selectable(node, false, 1)
		built += 1
		for r in _sorted_count_rows(gdict.get("extensions", {})):
			var row := _files_flat.create_item(node)
			row.set_text(0, str(r))
			_set_row_selectable(row, false, 1)
	if built == 0:
		var hint := _files_flat.create_item(root)
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


## Header click on a Files-tab column tree: left-click toggles that
## column between stretched and content-fit (other mouse buttons and
## out-of-range columns are ignored). Each table keeps its own
## collapse state (different layouts). The fit floor is measured, not
## trusted to the engine: header title plus every cell (hidden rows
## included, so expanding a group never truncates), with room for
## indentation, arrows, icons and padding. Never fails.
func _on_column_title_clicked(column: int, mouse_button: int, tree: Tree, key: String) -> void:
	if mouse_button != MOUSE_BUTTON_LEFT:
		return
	if tree == null or not is_instance_valid(tree):
		return
	if column < 0 or column >= tree.columns:
		return
	var collapsed: Dictionary = (_collapsed_cols.get(key, {}) as Dictionary).duplicate()
	collapsed = toggle_collapsed_state(collapsed, column, tree.columns)
	_collapsed_cols[key] = collapsed
	_apply_column_collapse(tree, key, column)


## Natural width of one column in pixels on one column tree: the
## header title plus the widest cell, hidden rows included. Padding/
## indent/icon room errs generous on purpose (overestimates waste a
## few pixels, underestimates truncate). Zero when unreadable. Never
## fails.
func _column_fit_width(tree: Tree, column: int) -> int:
	if tree == null or not is_instance_valid(tree):
		return 0
	if column < 0 or column >= tree.columns:
		return 0
	var font := tree.get_theme_font("font", "Tree")
	var fs := tree.get_theme_font_size("font_size", "Tree")
	if font == null or fs <= 0:
		return 0
	var icon_w := 16
	if tree.has_theme_constant("icon_max_width", "Tree"):
		icon_w = maxi(tree.get_theme_constant("icon_max_width", "Tree"), 1)
	var indent := maxi(int(font.get_height(fs)), 1)
	var best := _fit_text_width(tree.get_column_title(column), font, fs, 0, indent, 0)
	var root := tree.get_root()
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


## Applies the collapsed state of one column to one column tree:
## expand off with the measured fit floor when collapsed (content
## never truncates), stretched otherwise. Clipping stays off both
## ways. Each table keeps its own state (different layouts). Never
## fails.
func _apply_column_collapse(tree: Tree, key: String, column: int) -> void:
	if tree == null or not is_instance_valid(tree):
		return
	if column < 0 or column >= tree.columns:
		return
	var collapsed: Dictionary = _collapsed_cols.get(key, {})
	if bool(collapsed.get(column, false)):
		tree.set_column_expand(column, false)
		tree.set_column_custom_minimum_width(column, _column_fit_width(tree, column))
	else:
		tree.set_column_expand(column, true)
		tree.set_column_custom_minimum_width(column, 0)
	tree.set_column_clip_content(column, false)


## Re-measures the floor of every collapsed column on both column
## trees (content changes on every rebuild: rescan, sort, toggles).
## Never fails.
func _refit_collapsed_columns() -> void:
	for entry in [[_files_tree, PANEL_FILES], [_dirs_tree, PANEL_DIRS]]:
		var tree: Tree = entry[0]
		if tree == null or not is_instance_valid(tree):
			continue
		var collapsed: Dictionary = _collapsed_cols.get(str(entry[1]), {})
		for c in collapsed.keys():
			if bool(collapsed.get(c, false)) and int(c) >= 0 and int(c) < tree.columns:
				_apply_column_collapse(tree, str(entry[1]), int(c))


## File-row activation on the files column tree: navigates to the
## file's first issue (line 1 when clean). Group rows carry no target
## and stay inert.
func _on_files_tree_selected() -> void:
	_navigate_tree_selection(_files_tree)


## Same for the files text tree.
func _on_files_flat_selected() -> void:
	_navigate_tree_selection(_files_flat)


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


## Files-tab panel controls: the addons toggle narrows the panel to
## the plain project tree, the sort dropdown reorders its rows, the
## order switch flips ascending/descending. Every change persists and
## rebuilds all four Files-tab trees. Never fails.
func _on_panel_addons(panel: String) -> void:
	var widgets: Dictionary = _panel_widgets.get(panel, {})
	var btn: Button = widgets.get("addons", null)
	if btn != null and is_instance_valid(btn):
		(_panel[panel] as Dictionary)["include_addons"] = btn.button_pressed
	_persist_filters()
	_paint_census()


func _on_panel_sort(idx: int, panel: String) -> void:
	if idx < 0 or idx >= SORT_KEYS.size():
		return
	(_panel[panel] as Dictionary)["sort"] = str(SORT_KEYS[idx])
	_persist_filters()
	_paint_census()


func _on_panel_desc(pressed_on: bool, panel: String) -> void:
	(_panel[panel] as Dictionary)["descending"] = bool(pressed_on)
	var widgets: Dictionary = _panel_widgets.get(panel, {})
	var btn: CheckButton = widgets.get("desc", null)
	if btn != null and is_instance_valid(btn):
		btn.button_pressed = bool(pressed_on)
	_persist_filters()
	_paint_census()


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
	_files = Label.new()
	_files.text = ""
	_files.visible = false
	_files.clip_text = true
	_files.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_files.tooltip_text = "Project files by extension (last full scan)"
	files_page.add_child(_files)
	_view_tabs = TabContainer.new()
	_view_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	files_page.add_child(_view_tabs)
	var table_page := VBoxContainer.new()
	table_page.name = TAB_TABLE
	table_page.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_view_tabs.add_child(table_page)
	_files_tree = _make_files_tree()
	_files_tree.column_title_clicked.connect(_on_column_title_clicked.bind(_files_tree, PANEL_FILES))
	_files_tree.item_selected.connect(_on_files_tree_selected)
	_add_panel_section(table_page, PANEL_FILES, "Files", _files_tree)
	_dirs_tree = _make_column_tree()
	_dirs_tree.column_title_clicked.connect(_on_column_title_clicked.bind(_dirs_tree, PANEL_DIRS))
	_add_panel_section(table_page, PANEL_DIRS, "Directories", _dirs_tree)
	var text_page := VBoxContainer.new()
	text_page.name = TAB_TEXT
	text_page.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_view_tabs.add_child(text_page)
	_files_flat = _make_flat_tree()
	_files_flat.item_selected.connect(_on_files_flat_selected)
	_add_text_section(text_page, "Files", _files_flat)
	_dirs_flat = _make_flat_tree()
	_add_text_section(text_page, "Directories", _dirs_flat)
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
	var legacy := {"include_addons": clean.get("include_addons", true), "sort": clean.get("sort", "path"), "descending": clean.get("descending", false)}
	clean["files"] = FullScan.normalize_panel_state((raw as Dictionary).get("files", {}), legacy)
	clean["dirs"] = FullScan.normalize_panel_state((raw as Dictionary).get("dirs", {}), legacy)
	return clean


## Applies a persisted filter payload to the state and buttons
## (sanitized: unknown keys dropped, missing keys on; pre-split flat
## keys migrate into both panels).
func _apply_filters(stored: Dictionary) -> void:
	var clean := sanitize_filters(stored)
	_show = (clean.get("show", {}) as Dictionary).duplicate()
	_types = (clean.get("types", {}) as Dictionary).duplicate()
	_panel = {
		PANEL_FILES: (clean.get("files", {}) as Dictionary).duplicate(),
		PANEL_DIRS: (clean.get("dirs", {}) as Dictionary).duplicate(),
	}
	for k in _show.keys():
		if _sev_btns.has(k):
			(_sev_btns[k] as Button).button_pressed = bool(_show.get(k, true))
	for k in _types.keys():
		if _type_btns.has(k):
			(_type_btns[k] as Button).button_pressed = bool(_types.get(k, true))
	_sync_panel_widgets()


static func _make_toggle(label_text: String, tip: String) -> Button:
	var b := Button.new()
	b.text = label_text
	b.toggle_mode = true
	b.focus_mode = Control.FOCUS_NONE
	b.tooltip_text = tip
	return b


## One 9-column Files-tab table Tree (files-only or
## directories-only). Never fails.
static func _make_column_tree() -> Tree:
	var tree := Tree.new()
	tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	tree.columns = TREE_COLUMNS
	tree.set_column_title(0, "Path")
	tree.set_column_title(1, "Files")
	tree.set_column_title(2, "Subdirs")
	tree.set_column_title(3, "Files (rec)")
	tree.set_column_title(4, "Subdirs (rec)")
	tree.set_column_title(5, "Size")
	tree.set_column_title(6, "Size (rec)")
	tree.set_column_title(7, "Created")
	tree.set_column_title(8, "Modified")
	tree.hide_root = true
	tree.column_titles_visible = true
	return tree


## One 4-column files-only table Tree (Path, Size, Created,
## Modified). Never fails.
static func _make_files_tree() -> Tree:
	var tree := Tree.new()
	tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	tree.columns = FILES_COLUMNS
	tree.set_column_title(0, "Path")
	tree.set_column_title(FILE_COL_SIZE, "Size")
	tree.set_column_title(FILE_COL_CREATED, "Created")
	tree.set_column_title(FILE_COL_MODIFIED, "Modified")
	tree.hide_root = true
	tree.column_titles_visible = true
	return tree


## One single-column Files-tab text Tree. Never fails.
static func _make_flat_tree() -> Tree:
	var tree := Tree.new()
	tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	tree.columns = 1
	tree.hide_root = true
	tree.column_titles_visible = false
	return tree


## One table-tab panel section: header label, toolbar (addons
## toggle, sort dropdown, order switch, all bound to the panel
## triple) and its column tree. Never fails.
func _add_panel_section(page: VBoxContainer, panel: String, title: String, tree: Tree) -> void:
	var head := Label.new()
	head.text = title
	head.clip_text = true
	page.add_child(head)
	var bar := HBoxContainer.new()
	bar.name = title + "Bar"
	page.add_child(bar)
	var addons_btn := _make_toggle("Include Addons", "Include res://addons/ files in the " + title.to_lower())
	addons_btn.button_pressed = true
	addons_btn.pressed.connect(_on_panel_addons.bind(panel))
	bar.add_child(addons_btn)
	var sort_opt := OptionButton.new()
	sort_opt.focus_mode = Control.FOCUS_NONE
	sort_opt.tooltip_text = "Sort " + title.to_lower() + " by"
	sort_opt.fit_to_longest_item = false
	sort_opt.clip_text = true
	for k in SORT_KEYS:
		sort_opt.add_item(str(SORT_LABELS.get(k, k)))
	sort_opt.selected = 0
	sort_opt.item_selected.connect(_on_panel_sort.bind(panel))
	bar.add_child(sort_opt)
	var desc_btn := CheckButton.new()
	desc_btn.text = "Descending"
	desc_btn.focus_mode = Control.FOCUS_NONE
	desc_btn.tooltip_text = "Reverse the " + title.to_lower() + " order"
	desc_btn.toggled.connect(_on_panel_desc.bind(panel))
	bar.add_child(desc_btn)
	_panel_widgets[panel] = {"addons": addons_btn, "sort": sort_opt, "desc": desc_btn}
	page.add_child(tree)


## One text-tab mirror section: header label plus its single-column
## tree (follows the panel triple, no toolbar of its own). Never
## fails.
func _add_text_section(page: VBoxContainer, title: String, tree: Tree) -> void:
	var head := Label.new()
	head.text = title
	head.clip_text = true
	page.add_child(head)
	page.add_child(tree)


func _on_sev_toggled(sev: String) -> void:
	_show[sev] = bool((_sev_btns[sev] as Button).button_pressed)
	_persist_filters()
	refresh()


func _on_type_toggled(t: String) -> void:
	_types[t] = bool((_type_btns[t] as Button).button_pressed)
	_persist_filters()
	refresh()


## Pushes every panel triple onto its toolbar widgets (addons
## toggle, sort dropdown, order switch). Never fails.
func _sync_panel_widgets() -> void:
	for panel in [PANEL_FILES, PANEL_DIRS]:
		var widgets: Dictionary = _panel_widgets.get(panel, {})
		var addons_btn: Button = widgets.get("addons", null)
		if addons_btn != null and is_instance_valid(addons_btn):
			addons_btn.button_pressed = _panel_addons(panel)
		var sort_opt: OptionButton = widgets.get("sort", null)
		if sort_opt != null and is_instance_valid(sort_opt):
			sort_opt.select(maxi(SORT_KEYS.find(_panel_sort(panel)), 0))
		var desc_btn: CheckButton = widgets.get("desc", null)
		if desc_btn != null and is_instance_valid(desc_btn):
			desc_btn.button_pressed = _panel_desc(panel)


## Writes the current toggle state to both backends, editor-only: in
## tests (headless) flips stay in-memory so suites never touch the
## real report file implicitly (save_filters itself stays directly
## testable).
func _persist_filters() -> void:
	if not Engine.is_editor_hint():
		return
	save_filters(_show, _types, _panel.get(PANEL_FILES, {}), _panel.get(PANEL_DIRS, {}))


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
