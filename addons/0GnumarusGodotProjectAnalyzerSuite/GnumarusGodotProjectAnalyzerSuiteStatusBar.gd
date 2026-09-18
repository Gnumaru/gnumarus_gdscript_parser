extends HBoxContainer

const EdTree = preload("res://addons/0GnumarusGodotProjectAnalyzerSuite/GnumarusGodotProjectAnalyzerSuiteEditorTree.gd")

## Status bar showing Gnumarus analyzer issues for the current script:
## [<] [message ....] [>] ... [white pos] [console error icon + red
## count] [console warning icon + amber count]. Navigation calls the
## injected `_goto` Callable with the issue dict (the plugin wires it
## to editor navigation). All highlighting goes through the stored
## code edit, re-validated on every use.

const HINT_TEXT := "Gnumarus: live analysis on, Ctrl+Shift+Alt+F5 logs to console"
const ERR_COLOR := Color(0.85, 0.15, 0.15, 1.0)
const POS_COLOR := Color(1, 1, 1, 1)
const WARN_COUNT_COLOR := Color(1.0, 0.75, 0.25, 1.0)
const MSG_ERR_COLOR := Color.RED
const MSG_WARN_COLOR := Color(1.0, 0.75, 0.25, 1.0)
const ERR_LINE_COLOR := Color(0.85, 0.12, 0.12, 0.28)
const WARN_LINE_COLOR := Color(0.85, 0.65, 0.1, 0.22)
const STATUS_ICON_SIZE := Vector2(16, 16)

var _issues: Array = []
var _index: int = 0
var _path: String = ""
var _code_edit: Object = null
var _painted: Array = []
var _goto: Callable = Callable()

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
func set_results(issues: Array, path: String, code_edit: Object) -> void:
	_ensure_built()
	clear_highlights()
	_issues = issues.duplicate()
	_path = path
	_code_edit = code_edit
	_index = 0
	apply()


## Clears display and highlights, back to the hint state.
func clear_results() -> void:
	_ensure_built()
	clear_highlights()
	_issues = []
	_path = ""
	_index = 0
	refresh()


func clear_highlights() -> void:
	if _code_edit != null and is_instance_valid(_code_edit):
		EdTree.clear_highlights(_code_edit, _painted)
	_painted = []
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
	_pos.text = pos_text(_index + 1, _issues.size())
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


## Paints current issue lines and updates the widgets.
func apply() -> void:
	_ensure_built()
	if _issues.is_empty() or _code_edit == null or not is_instance_valid(_code_edit):
		refresh()
		return
	var lines: Array = []
	var warns: Array = []
	for e in _issues:
		if e is Dictionary and int((e as Dictionary).get("line", 0)) >= 1:
			lines.append(int((e as Dictionary).get("line", 0)))
			if str((e as Dictionary).get("severity", "error")) != "error":
				warns.append(int((e as Dictionary).get("line", 0)))
	var err_col: Color = ERR_LINE_COLOR
	var live: Color = EdTree.godot_error_color(_code_edit)
	if live.a > 0.01:
		err_col = live
	var warn_col: Color = WARN_LINE_COLOR
	var live_warn: Color = EdTree.godot_warning_color(_code_edit)
	if live_warn.a > 0.01:
		warn_col = live_warn
	_painted = EdTree.apply_highlights(_code_edit, lines, err_col, warn_col, warns)
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
