extends HBoxContainer

const EdTree = preload("res://addons/0GnumarusGodotProjectAnalyzerSuite/GnumarusGodotProjectAnalyzerSuiteEditorTree.gd")

## Status bar showing Gnumarus analyzer issues for the current script:
## [<] [message ....] [>] ... [white pos] [console error icon + red
## count] [console warning icon + amber count]. Navigation calls the
## injected `_goto` Callable with the issue dict (the plugin wires it
## to editor navigation). All highlighting goes through the stored
## code edit, re-validated on every use: annotation lines carry a
## discreet tint (the theme comment color at low alpha), issue lines
## paint over it. A dedicated "Gnumarus"
## gutter shows one error/warning icon per issue line (errors win
## ties); clicking an icon reselects that line's first message (the
## dropdown is the tooltip) and focuses it in the editor.

const HINT_TEXT := "Gnumarus: live analysis on, Ctrl+Shift+Alt+F5 logs to console"
const ERR_COLOR := Color(0.85, 0.15, 0.15, 1.0)
const POS_COLOR := Color(1, 1, 1, 1)
const WARN_COUNT_COLOR := Color(1.0, 0.75, 0.25, 1.0)
const MSG_ERR_COLOR := Color.RED
const MSG_WARN_COLOR := Color(1.0, 0.75, 0.25, 1.0)
const ERR_LINE_COLOR := Color(0.85, 0.12, 0.12, 0.28)
const WARN_LINE_COLOR := Color(0.85, 0.65, 0.1, 0.22)
## Fallback annotation tint (headless or theme without comment_color):
## desaturated teal, hue-clear of error red, warning amber, selection
## blue and the neutral current line.
const ANN_LINE_COLOR := Color(0.3, 0.65, 0.6, 0.1)
const STATUS_ICON_SIZE := Vector2(16, 16)
## Name of our dedicated CodeEdit gutter (error/warning icons per
## issue line). Found by name on every use: editor gutter indices
## shift across context switches, so nothing is cached.
const GUTTER_NAME := "Gnumarus"
## TextEdit.GutterType.GUTTER_TYPE_ICON (the draw switch ignores
## icons on STRING gutters): add_gutter() births STRING gutters, so
## _ensure_gutter sets this on ours every time.
const GUTTER_TYPE_ICON := 1

var _issues: Array = []
var _index: int = 0
var _path: String = ""
var _code_edit: Object = null
var _painted: Array = []
## 1-based annotation lines tinted under the issue highlights (from
## the analyzer, via set_results; issue lines keep issue colors).
var _ann_lines: Array = []
## 0-based lines carrying our gutter icons (for clearing).
var _gutter_lines: Array = []
## Pre-paint background colors ({line: Color}) for the currently
## painted lines: clearing restores these instead of blanking, so
## foreign highlights underneath ours (Godot's own error paint)
## survive our teardown. First paint wins across repaints; dropped
## together with _painted on every clear.
var _prev_colors: Dictionary = {}
var _goto: Callable = Callable()
## Analysis origin marker ("deps" when a dependency refresh
## triggered the run, "" otherwise): shown beside the position while
## these results stand, cleared by the next set/clear.
var _origin := ""

var _btn_prev: Button = null
var _btn_next: Button = null
var _opt: OptionButton = null
var _pos: Label = null
var _err_icon: TextureRect = null
var _count: Label = null
var _warn_icon: TextureRect = null
var _count_warn: Label = null
var _built := false


## Pure display helpers (unit-tested headless).


static func format_issue(issue: Dictionary) -> String:
	var mark := "Error"
	if str(issue.get("severity", "error")) != "error":
		mark = "Warning"
	var where := ""
	var line := int(issue.get("line", 0))
	if line >= 1:
		where = " at (" + str(line) + ", " + str(maxi(1, int(issue.get("column", 1)))) + ")"
	return mark + where + ": [" + str(issue.get("kind", "?")) + "] " + str(issue.get("message", ""))


static func count_text(pos: int, total: int, n_errors: int, n_warnings: int) -> String:
	var parts: Array = []
	var p := pos_text(pos, total)
	if p != "":
		parts.append(p)
	parts.append(err_text(n_errors))
	var w := warn_text(n_warnings)
	if w != "":
		parts.append(w)
	return "  ".join(parts)


## Position half of the counter (white label, hidden when empty).
static func pos_text(pos: int, total: int) -> String:
	if total <= 0:
		return ""
	return str(pos) + "/" + str(total)


## Origin marker beside the position (" (deps)" for dependency
## refreshes, "" otherwise): tells a dep-triggered repaint apart
## from a normal analysis. Pure, unit-tested headless.
static func origin_text(origin: String) -> String:
	if origin == "deps":
		return " (deps)"
	return ""


## Error count number (red label, next to the console error icon).
static func err_text(n_errors: int) -> String:
	return str(n_errors)


## Warning count number (amber label, hidden when zero).
static func warn_text(n_warnings: int) -> String:
	if n_warnings <= 0:
		return ""
	return str(n_warnings)


static func next_index(i: int, n: int) -> int:
	if n <= 0:
		return 0
	return (i + 1) % n


static func prev_index(i: int, n: int) -> int:
	if n <= 0:
		return 0
	return (i - 1 + n) % n


static func count_errors(issues: Array) -> int:
	var n := 0
	for e in issues:
		if e is Dictionary and str((e as Dictionary).get("severity", "error")) == "error":
			n += 1
	return n


static func count_warnings(issues: Array) -> int:
	var n := 0
	for e in issues:
		if e is Dictionary and str((e as Dictionary).get("severity", "error")) != "error":
			n += 1
	return n


func _ensure_built() -> void:
	if _built:
		return
	_built = true
	name = "GnumarusBar"
	_btn_prev = Button.new()
	_btn_prev.text = "<"
	_btn_prev.focus_mode = Control.FOCUS_NONE
	_btn_prev.tooltip_text = "Previous analyzer message"
	_btn_prev.pressed.connect(_on_prev)
	add_child(_btn_prev)
	_btn_next = Button.new()
	_btn_next.text = ">"
	_btn_next.focus_mode = Control.FOCUS_NONE
	_btn_next.tooltip_text = "Next analyzer message"
	_btn_next.pressed.connect(_on_next)
	add_child(_btn_next)
	_opt = OptionButton.new()
	_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_opt.clip_text = true
	_opt.fit_to_longest_item = false
	_opt.text = HINT_TEXT
	_opt.disabled = true
	_opt.tooltip_text = "Analyzer messages for the current script"
	_opt.item_selected.connect(_on_option_picked)
	add_child(_opt)
	_pos = Label.new()
	_pos.text = ""
	_pos.visible = false
	_pos.add_theme_color_override("font_color", POS_COLOR)
	add_child(_pos)
	_err_icon = _make_status_icon("Errors")
	add_child(_err_icon)
	_count = Label.new()
	_count.text = err_text(0)
	_count.add_theme_color_override("font_color", ERR_COLOR)
	add_child(_count)
	_warn_icon = _make_status_icon("Warnings")
	_warn_icon.visible = false
	add_child(_warn_icon)
	_count_warn = Label.new()
	_count_warn.text = ""
	_count_warn.visible = false
	_count_warn.add_theme_color_override("font_color", WARN_COUNT_COLOR)
	add_child(_count_warn)
	refresh()


## Console-style status icon slot (16px, empty texture headless).
## Textures resolve live in refresh(), so theme switches apply.
static func _make_status_icon(tip: String) -> TextureRect:
	var icon := TextureRect.new()
	icon.custom_minimum_size = STATUS_ICON_SIZE
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	icon.tooltip_text = tip
	return icon


## Issues: [{severity ("error"/"warning"), kind, message, line,
## column}]. Replaces previous results (old highlights cleared).
## `origin` ("deps" or "") marks dependency-triggered runs.
## `ann_lines` (1-based) tints annotation lines under issue colors.
func set_results(issues: Array, path: String, code_edit: Object, origin := "", ann_lines := []) -> void:
	_ensure_built()
	clear_highlights()
	_issues = issues.duplicate()
	_path = path
	_code_edit = code_edit
	_origin = str(origin)
	_ann_lines = (ann_lines as Array).duplicate()
	_index = 0
	apply()


## Clears display and highlights, back to the hint state.
func clear_results() -> void:
	_ensure_built()
	clear_highlights()
	_issues = []
	_path = ""
	_origin = ""
	_ann_lines = []
	_index = 0
	refresh()


func clear_highlights() -> void:
	_clear_gutter()
	if _code_edit != null and is_instance_valid(_code_edit):
		EdTree.restore_highlights(_code_edit, _prev_colors)
	_painted = []
	_prev_colors = {}
	_code_edit = null


func issue_count() -> int:
	return _issues.size()


func current_issue() -> Dictionary:
	if _issues.is_empty():
		return {}
	return _issues[clampi(_index, 0, _issues.size() - 1)]


func set_navigate_fn(fn: Callable) -> void:
	_goto = fn


func show_index(i: int) -> void:
	_ensure_built()
	if _issues.is_empty():
		_index = 0
		refresh()
		return
	_index = clampi(i, 0, _issues.size() - 1)
	_opt.select(_index)
	refresh()
	_goto_current()


func refresh() -> void:
	_ensure_built()
	_paint_status_icons()
	if _issues.is_empty():
		_opt.clear()
		_opt.text = HINT_TEXT
		_opt.disabled = true
		_opt.remove_theme_color_override("font_color")
		_pos.text = ""
		_pos.visible = false
		_count.text = err_text(0)
		_warn_icon.visible = false
		_count_warn.text = ""
		_count_warn.visible = false
		_btn_prev.disabled = true
		_btn_next.disabled = true
		return
	_rebuild_items()
	_opt.disabled = false
	_opt.select(_index)
	var cur := current_issue()
	if str(cur.get("severity", "error")) == "error":
		_opt.add_theme_color_override("font_color", MSG_ERR_COLOR)
	else:
		_opt.add_theme_color_override("font_color", MSG_WARN_COLOR)
	var n_errors := count_errors(_issues)
	var n_warnings := count_warnings(_issues)
	_pos.text = pos_text(_index + 1, _issues.size()) + origin_text(_origin)
	_pos.visible = true
	_count.text = err_text(n_errors)
	_warn_icon.visible = n_warnings > 0
	_count_warn.text = warn_text(n_warnings)
	_count_warn.visible = n_warnings > 0
	_btn_prev.disabled = _issues.size() < 2
	_btn_next.disabled = _issues.size() < 2


## Resolves the console icons live (theme switches included). A null
## texture keeps the previous one, so a missing theme never blanks
## an icon that is already showing.
func _paint_status_icons() -> void:
	var err_icon := EdTree.editor_error_icon()
	if err_icon != null:
		_err_icon.texture = err_icon
	var warn_icon := EdTree.editor_warning_icon()
	if warn_icon != null:
		_warn_icon.texture = warn_icon


## Paints annotation tint plus current issue lines and updates the
## widgets. Tint lands first so issue colors win shared lines; the
## tint paints even when no issues remain.
func apply() -> void:
	_ensure_built()
	if _code_edit == null or not is_instance_valid(_code_edit):
		refresh()
		return
	var lines: Array = []
	var warns: Array = []
	for e in _issues:
		if e is Dictionary and int((e as Dictionary).get("line", 0)) >= 1:
			lines.append(int((e as Dictionary).get("line", 0)))
			if str((e as Dictionary).get("severity", "error")) != "error":
				warns.append(int((e as Dictionary).get("line", 0)))
	var tinted: Array = []
	for ln in _ann_lines:
		var line := int(ln)
		if line >= 1 and not (line in lines):
			tinted.append(line)
	var snap := EdTree.snapshot_highlights(_code_edit, lines + tinted)
	for k in snap.keys():
		if not _prev_colors.has(k):
			_prev_colors[k] = snap[k]
	var tint_col: Color = ANN_LINE_COLOR
	var live_ann: Color = EdTree.editor_annotation_color()
	if live_ann.a > 0.01:
		tint_col = live_ann
	var done := EdTree.apply_tint(_code_edit, tinted, tint_col)
	var err_col: Color = ERR_LINE_COLOR
	var live: Color = EdTree.godot_error_color(_code_edit)
	if live.a > 0.01:
		err_col = live
	var warn_col: Color = WARN_LINE_COLOR
	var live_warn: Color = EdTree.godot_warning_color(_code_edit)
	if live_warn.a > 0.01:
		warn_col = live_warn
	_painted = done + EdTree.apply_highlights(_code_edit, lines, err_col, warn_col, warns)
	_paint_gutter(_code_edit, _issues)
	refresh()


func _on_prev() -> void:
	show_index(prev_index(_index, _issues.size()))


func _on_next() -> void:
	show_index(next_index(_index, _issues.size()))


## Dropdown pick: show the chosen issue, focus it in the editor and
## update the position label (same path as the </> buttons).
## select() never emits this, so programmatic moves cannot loop here.
func _on_option_picked(idx: int) -> void:
	show_index(idx)


## Rebuilds the dropdown items from _issues (selection preserved by
## the caller). Skipped when already in sync: refresh() runs on every
## navigation move, but items only change with new results.
func _rebuild_items() -> void:
	if _opt.item_count == _issues.size():
		var synced := true
		for i in range(_issues.size()):
			if _opt.get_item_text(i) != format_issue(_issues[i]):
				synced = false
				break
		if synced:
			return
	_opt.clear()
	for e in _issues:
		if e is Dictionary:
			_opt.add_item(format_issue(e))


func _goto_current() -> void:
	var issue := current_issue()
	if issue.is_empty():
		return
	if _goto.is_valid():
		_goto.call(issue)


## 0-based gutter row for a 1-based issue line (CodeEdit gutter rows
## follow the caret convention, like set_caret_line). Pure.
static func gutter_line(issue_line: int) -> int:
	return maxi(int(issue_line) - 1, 0)


## Gutter paint plan: {0-based line: "error"/"warning"} — one entry
## per issue line (errors win ties), clamped to [0, line_count).
## Pure, unit-tested headless.
static func gutter_plan(issues: Array, line_count: int) -> Dictionary:
	var plan := {}
	var total := maxi(int(line_count), 0)
	for e in issues:
		if not (e is Dictionary):
			continue
		var ln := int((e as Dictionary).get("line", 0))
		if ln < 1 or ln > total:
			continue
		var sev := "warning" if str((e as Dictionary).get("severity", "error")) != "error" else "error"
		if not plan.has(ln - 1) or sev == "error":
			plan[ln - 1] = sev
	return plan


## Bar index behind a gutter click (0-based line): the first issue on
## that 1-based line, -1 when none. Pure, unit-tested headless.
static func gutter_issue_index(issues: Array, line0: int) -> int:
	var want := int(line0) + 1
	for i in range(issues.size()):
		var e: Variant = issues[i]
		if e is Dictionary and int((e as Dictionary).get("line", 0)) == want:
			return i
	return -1


## Index of our gutter on a CodeEdit (-1 when absent/unreadable).
## Found by name every time (never cached). Never fails.
static func find_gutter(code_edit: Object) -> int:
	if not EdTree.is_code_edit(code_edit):
		return -1
	var ce: Object = code_edit
	if not (ce as Object).has_method("get_gutter_count") or not (ce as Object).has_method("get_gutter_name"):
		return -1
	var n := int((ce as Object).call("get_gutter_count"))
	for g in range(n):
		if str((ce as Object).call("get_gutter_name", g)) == GUTTER_NAME:
			return g
	return -1


## Ensures our clickable gutter exists (appended last when missing)
## and connects its click signal once. Returns the index, -1 on any
## doubt. Never fails.
func _ensure_gutter(code_edit: Object) -> int:
	if not EdTree.is_code_edit(code_edit):
		return -1
	var ce: Object = code_edit
	var g := find_gutter(ce)
	if g < 0:
		if not (ce as Object).has_method("add_gutter") or not (ce as Object).has_method("get_gutter_count"):
			return -1
		var before := int((ce as Object).call("get_gutter_count"))
		(ce as Object).call("add_gutter", -1)
		g = int((ce as Object).call("get_gutter_count")) - 1
		if g < before or g < 0:
			return -1
		if (ce as Object).has_method("set_gutter_name"):
			(ce as Object).call("set_gutter_name", g, GUTTER_NAME)
	if (ce as Object).has_method("set_gutter_type"):
		(ce as Object).call("set_gutter_type", g, GUTTER_TYPE_ICON)
	if (ce as Object).has_method("set_gutter_clickable"):
		(ce as Object).call("set_gutter_clickable", g, true)
	if (ce as Object).has_signal("gutter_clicked") and not (ce as Object).is_connected("gutter_clicked", Callable(self, "_on_gutter_clicked")):
		(ce as Object).connect("gutter_clicked", Callable(self, "_on_gutter_clicked"))
	return g


## Paints one gutter icon per issue line (errors win ties). Icons
## resolve live from the editor theme; without icons (headless) no
## gutter is even created. Never fails.
func _paint_gutter(code_edit: Object, issues: Array) -> void:
	_gutter_lines = []
	var err_icon := EdTree.editor_error_icon()
	var warn_icon := EdTree.editor_warning_icon()
	if err_icon == null and warn_icon == null:
		return
	var g := _ensure_gutter(code_edit)
	if g < 0:
		return
	var ce: Object = code_edit
	if not (ce as Object).has_method("get_line_count"):
		return
	var plan := gutter_plan(issues, int((ce as Object).call("get_line_count")))
	if plan.is_empty():
		return
	if not (ce as Object).has_method("set_line_gutter_icon") or not (ce as Object).has_method("set_line_gutter_clickable"):
		return
	if (ce as Object).has_method("set_gutter_draw"):
		(ce as Object).call("set_gutter_draw", g, true)
	for l0 in plan.keys():
		var icon: Texture2D = err_icon if str(plan[l0]) == "error" else warn_icon
		if icon == null:
			icon = err_icon if err_icon != null else warn_icon
		if icon == null:
			continue
		(ce as Object).call("set_line_gutter_icon", int(l0), g, icon)
		(ce as Object).call("set_line_gutter_clickable", int(l0), g, true)
		_gutter_lines.append(int(l0))


## Drops our gutter icons and hides the gutter (never removed: that
## would shift the editor's own gutter indices). Never fails.
func _clear_gutter() -> void:
	if _code_edit != null and is_instance_valid(_code_edit):
		var g := find_gutter(_code_edit)
		if g >= 0:
			for l0 in _gutter_lines:
				if (_code_edit as Object).has_method("set_line_gutter_icon"):
					(_code_edit as Object).call("set_line_gutter_icon", int(l0), g, null)
			if (_code_edit as Object).has_method("set_gutter_draw"):
				(_code_edit as Object).call("set_gutter_draw", g, false)
	_gutter_lines = []


## Gutter click: our gutter reselects the first issue on that line
## (show_index moves the dropdown and focuses the editor — the
## dropdown is the tooltip); foreign gutters (breakpoints, native
## errors) pass through untouched. Never fails.
func _on_gutter_clicked(line: int, gutter: int) -> void:
	_ensure_built()
	if _issues.is_empty():
		return
	if _code_edit == null or not is_instance_valid(_code_edit):
		return
	if gutter != find_gutter(_code_edit):
		return
	var idx := gutter_issue_index(_issues, int(line))
	if idx >= 0:
		show_index(idx)
