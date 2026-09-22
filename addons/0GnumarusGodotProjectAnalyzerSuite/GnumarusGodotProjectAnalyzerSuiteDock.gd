extends VBoxContainer

## Bottom-panel dock listing every Gnumarus analyzer issue known for
## the project: live per-file results from analyze_current overlaid on
## the last full-scan report (ScanResults.json, loaded on build).
##
## Two toggle groups filter the list (same idea as the Output panel
## filter buttons): severities (Errors / Warnings / Notes — nothing
## emits notes yet, the toggle is ready for them) and resource types
## (gd / tscn / tres / godot / other, derived from the issue path, so
## script issues and resource-integrity issues toggle independently).
## Picking a row calls the injected `_goto` Callable with the issue
## dict (the plugin wires it to editor navigation); Rescan calls the
## injected `_rescan` Callable (the full scan). All filter logic is
## static and headless-testable; only live editor navigation needs
## the editor.

const EdTree = preload("res://addons/0GnumarusGodotProjectAnalyzerSuite/GnumarusGodotProjectAnalyzerSuiteEditorTree.gd")
const FullScan = preload("res://addons/0GnumarusGodotProjectAnalyzerSuite/GnumarusGodotProjectAnalyzerSuiteFullScanImpl.gd")

const DOCK_HINT := "Gnumarus: no issues. Run Project > Tools > Gnumaru's Full Scan for a project-wide report."
## EditorSettings key holding the filter state. It wins over the
## ScanResults.json copy on load; both are written on every change.
const FILTERS_SETTING := "gnumarus_analyzer/dock_filters"
const SEVERITIES := ["error", "warning", "note"]
const SEV_LABELS := {"error": "Errors", "warning": "Warnings", "note": "Notes"}
const TYPES := ["gd", "tscn", "tres", "godot", "other"]

var _by_path: Dictionary = {}
var _shown: Array = []
var _show := {"error": true, "warning": true, "note": true}
var _types := {"gd": true, "tscn": true, "tres": true, "godot": true, "other": true}
var _census := {}
var _include_addons := true
var _goto: Callable = Callable()
var _rescan: Callable = Callable()

var _list: ItemList = null
var _status: Label = null
var _files: Label = null
var _addons_btn: Button = null
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


## One-line row text: "[E] res://x.gd:10: [kind] message". Pure.
static func format_row(issue: Dictionary) -> String:
	var sev := normalize_severity(issue)
	var line := maxi(int(issue.get("line", 1)), 1)
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


## Merges a stored filter payload over the defaults: unknown keys
## dropped, missing keys kept on, non-dicts ignored. Pure.
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
	return clean


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
static func save_filters(show: Dictionary, types: Dictionary, include_addons := true) -> void:
	var payload := {"show": show.duplicate(), "types": types.duplicate(), "include_addons": bool(include_addons)}
	_write_editor_filters(payload)
	FullScan.store_filters(show, types, include_addons)


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


## Paints the census label (hidden when uncensused). Never fails.
func _paint_census() -> void:
	_ensure_built()
	_files.text = census_text(_census, _include_addons)
	_files.visible = _files.text != ""


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
	_files = Label.new()
	_files.text = ""
	_files.visible = false
	_files.clip_text = true
	_files.tooltip_text = "Project files by extension (last full scan)"
	toolbar.add_child(_files)
	_addons_btn = _make_toggle("addons", "Include res://addons/ files in the census")
	_addons_btn.button_pressed = true
	_addons_btn.pressed.connect(_on_addons_toggled)
	toolbar.add_child(_addons_btn)
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
	_list = ItemList.new()
	_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_list.allow_reselect = true
	_list.item_selected.connect(_on_item_selected)
	add_child(_list)
	if Engine.is_editor_hint():
		_apply_filters(load_filters())
		_census = FullScan.load_results().get("census", {})
		_paint_census()
	refresh()


## Applies a persisted filter payload to the state and buttons
## (sanitized: unknown keys dropped, missing keys on).
func _apply_filters(stored: Dictionary) -> void:
	var clean := sanitize_filters(stored)
	_show = (clean.get("show", {}) as Dictionary).duplicate()
	_types = (clean.get("types", {}) as Dictionary).duplicate()
	_include_addons = bool(clean.get("include_addons", true))
	for k in _show.keys():
		if _sev_btns.has(k):
			(_sev_btns[k] as Button).button_pressed = bool(_show.get(k, true))
	for k in _types.keys():
		if _type_btns.has(k):
			(_type_btns[k] as Button).button_pressed = bool(_types.get(k, true))
	if _addons_btn != null and is_instance_valid(_addons_btn):
		_addons_btn.button_pressed = _include_addons


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
	save_filters(_show, _types, _include_addons)


func _on_rescan() -> void:
	if _rescan.is_valid():
		_rescan.call()


func _on_clear() -> void:
	clear_all()


func _on_item_selected(idx: int) -> void:
	if idx < 0 or idx >= _shown.size():
		return
	if _goto.is_valid():
		_goto.call(_shown[idx])


## Rebuilds the visible rows from _by_path through the toggles.
func refresh() -> void:
	_ensure_built()
	var all: Array = []
	for p in _by_path.keys():
		for e in (_by_path[p] as Array):
			all.append(e)
	_shown = filter_issues(all, _show, _types)
	_list.clear()
	for e in _shown:
		var icon := _severity_icon(e)
		if icon != null:
			_list.add_item(format_row(e), icon, true)
		else:
			_list.add_item(format_row(e), null, false)
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
		_status.text = "Gnumarus: " + status_text(n_err, n_warn, n_note, total_count() - _shown.size())


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
