extends RefCounted

## Editor-bar suite: pure status-bar logic (formatting, counts,
## navigation, hotkey predicate, debounce countdown) plus null-safety
## of the editor-tree resolvers and the plugin-impl lifecycle. The impl
## is RefCounted so instances run headless; only live editor nodes
## (ScriptEditor, CodeEdit, the deferred repaint after Godot's
## background reset) stay manual-tested.

const Bar = preload("res://addons/0GnumarusGodotProjectAnalyzerSuite/GnumarusGodotProjectAnalyzerSuiteStatusBar.gd")
const EdTree = preload("res://addons/0GnumarusGodotProjectAnalyzerSuite/GnumarusGodotProjectAnalyzerSuiteEditorTree.gd")
const Impl = preload("res://addons/0GnumarusGodotProjectAnalyzerSuite/GnumarusGodotProjectAnalyzerSuitePluginImpl.gd")

var _goto_seen: Array = []


func run() -> Dictionary:
	var h = {"passed": 0, "failed": 0, "suite": "editor_bar"}
	_check(h, Bar.format_issue({"severity": "error", "kind": "k", "message": "m", "line": 10, "column": 2}) == "Error at (10, 2): [k] m", "format error")
	_check(h, Bar.format_issue({"severity": "warning", "kind": "k", "message": "m", "line": 3, "column": 1}) == "Warning at (3, 1): [k] m", "format warning")
	_check(h, Bar.format_issue({"severity": "error", "kind": "k", "message": "m", "line": 0, "column": 0}) == "Error: [k] m", "format lineless")
	_check(h, Bar.count_text(0, 0, 0, 0) == "0", "count empty")
	_check(h, Bar.count_text(1, 3, 3, 0) == "1/3  3", "count position first")
	_check(h, Bar.count_text(2, 3, 2, 1) == "2/3  2  1", "count position middle")
	_check(h, Bar.pos_text(0, 0) == "", "pos empty")
	_check(h, Bar.pos_text(1, 2) == "1/2", "pos shows")
	_check(h, Bar.err_text(0) == "0", "err count zero")
	_check(h, Bar.err_text(3) == "3", "err count shows")
	_check(h, Bar.warn_text(0) == "", "warn count empty")
	_check(h, Bar.warn_text(2) == "2", "warn count shows")
	_check(h, Bar.next_index(0, 3) == 1 and Bar.next_index(2, 3) == 0 and Bar.prev_index(0, 3) == 2, "wrap navigation")
	_check(h, Bar.next_index(0, 0) == 0 and Bar.prev_index(5, 0) == 0, "empty navigation")
	_check(h, Bar.count_errors([{"severity": "error"}, {"severity": "warning"}, {"severity": "error"}]) == 2, "count errors")
	_check(h, Bar.count_warnings([{"severity": "error"}, {"severity": "warning"}]) == 1, "count warnings")
	_hotkey(h)
	_debounce_countdown(h)
	_plugin_impl(h)
	_warm(h)
	_warm_order(h)
	_warm_fs(h)
	_deps(h)
	_bar_origin(h)
	_bar_model(h)
	_tree_nulls(h)
	return h


func _check(h: Dictionary, cond: bool, name: String) -> void:
	if cond:
		h["passed"] = int(h["passed"]) + 1
	else:
		h["failed"] = int(h["failed"]) + 1
		printerr("FAIL [editor_bar]: ", name)


func _hotkey(h) -> void:
	var good := InputEventKey.new()
	good.pressed = true
	good.echo = false
	good.keycode = KEY_F5
	good.ctrl_pressed = true
	good.shift_pressed = true
	good.alt_pressed = true
	_check(h, Impl.is_analyze_hotkey(good), "hotkey matches")
	var plain := InputEventKey.new()
	plain.pressed = true
	plain.keycode = KEY_F5
	_check(h, not Impl.is_analyze_hotkey(plain), "plain F5 ignored")
	var echo := InputEventKey.new()
	echo.pressed = true
	echo.echo = true
	echo.keycode = KEY_F5
	echo.ctrl_pressed = true
	echo.shift_pressed = true
	echo.alt_pressed = true
	_check(h, not Impl.is_analyze_hotkey(echo), "echo ignored")
	var other := InputEventKey.new()
	other.pressed = true
	other.keycode = KEY_F6
	other.ctrl_pressed = true
	other.shift_pressed = true
	other.alt_pressed = true
	_check(h, not Impl.is_analyze_hotkey(other), "other key ignored")
	_check(h, not Impl.is_analyze_hotkey(InputEventMouseButton.new()), "non-key ignored")
	_check(h, Impl.debounce_interval(0.0) == 1.0, "debounce floor")
	_check(h, Impl.debounce_interval(null) == 1.0, "debounce null")
	_check(h, Impl.debounce_interval("x") == 1.0, "debounce non-numeric")
	_check(h, Impl.debounce_interval(0.4) == 1.0, "debounce below floor")
	_check(h, is_equal_approx(Impl.debounce_interval(2.0), 2.3), "debounce above idle delay")


func _bar_model(h) -> void:
	_bar_model_basic(h)
	_bar_model_sorted(h)


## Plugin-implementation instance coverage (headless): the impl is a
## RefCounted precisely so every lifecycle path runs without editor
## nodes — the EditorPlugin proxy itself can only exist in the editor.
func _plugin_impl(h) -> void:
	var impl = Impl.new(null)
	_check(h, impl.plugin == null, "impl hosts null plugin headless")
	impl._restart_debounce()
	_check(h, impl._debounce != null and is_instance_valid(impl._debounce), "impl builds orphan timer")
	impl._on_text_changed()
	_check(h, impl._debounce != null and is_instance_valid(impl._debounce), "keystroke keeps timer")
	impl._on_context_changed()
	_check(h, not impl._has_last, "context change forces deferred pass")
	_check(h, impl._debounce != null and is_instance_valid(impl._debounce), "context change keeps timer")
	impl.analyze_current(false)
	_check(h, not impl._has_last, "headless analyze stays clean")
	impl._input(InputEventMouseButton.new())
	_check(h, true, "non-key input safe headless")
	impl._input(_hotkey_event(KEY_F5))
	_check(h, true, "hotkey input safe headless")
	impl._input(_hotkey_event(KEY_F6))
	_check(h, true, "other key input safe headless")
	impl.enter_tree()
	_check(h, impl._debounce != null and is_instance_valid(impl._debounce), "enter keeps timer")
	impl.exit_tree()
	_check(h, impl._debounce == null, "exit drops timer")
	_check(h, impl._bar == null, "exit drops bar")
	_check(h, not impl._has_last, "exit resets state")
	impl.enter_tree()
	_check(h, impl._debounce != null and is_instance_valid(impl._debounce), "re-enter rebuilds")
	impl.exit_tree()


func _hotkey_event(code: Key) -> InputEventKey:
	var ev := InputEventKey.new()
	ev.pressed = true
	ev.echo = false
	ev.keycode = code
	ev.ctrl_pressed = true
	ev.shift_pressed = true
	ev.alt_pressed = true
	return ev


## Debounce countdown regression: the deferred pass (which repaints
## after Godot's own background reset wipes our paint on file open)
## restarts a one-shot timer with the live delay. Bare timers live
## outside the scene tree, where ticking is impossible: the helper
## must store the delay and refuse silently instead of erroring.
func _debounce_countdown(h) -> void:
	_check(h, not EdTree.restart_debounce(null, 1.0), "null timer refuses")
	_check(h, not EdTree.restart_debounce(null, 0.0), "null timer refuses zero delay")
	var timer := Timer.new()
	timer.one_shot = true
	_check(h, not EdTree.restart_debounce(timer, 2.5), "refuses outside tree")
	_check(h, is_equal_approx(timer.wait_time, 2.5), "fresh delay stored")
	_check(h, timer.one_shot, "one-shot preserved")
	_check(h, timer.is_stopped(), "stays stopped outside tree")
	_check(h, not EdTree.restart_debounce(timer, 0.0), "zero delay refuses")
	_check(h, timer.is_stopped(), "stopped on zero delay")
	timer.free()


func _bar_model_basic(h) -> void:
	var bar = Bar.new()
	bar.set_navigate_fn(Callable(self, "_on_goto"))
	var issues := [
		{"severity": "error", "kind": "a", "message": "first", "line": 2, "column": 1, "path": "res://x.gd"},
		{"severity": "warning", "kind": "b", "message": "second", "line": 5, "column": 1, "path": "res://x.gd"},
	]
	bar.set_results(issues, "res://x.gd", null)
	_check(h, bar.issue_count() == 2, "model count")
	_check(h, str((bar.current_issue() as Dictionary).get("message", "")) == "first", "model first")
	_check(h, str(bar._pos.text) == "1/2", "pos shows")
	_check(h, bar._pos.visible, "pos visible with issues")
	_check(h, bar._pos.get_theme_color("font_color") == Bar.POS_COLOR, "pos white")
	_check(h, bar._pos.get_theme_color("font_color") == Color(1, 1, 1, 1), "pos exactly white")
	_check(h, str(bar._count.text) == "1", "err count number")
	_check(h, bar._count.get_theme_color("font_color") == Bar.ERR_COLOR, "err count red")
	_check(h, bar._err_icon != null and bar._err_icon is TextureRect, "err icon slot")
	_check(h, str(bar._count_warn.text) == "1", "warn count number")
	_check(h, bar._count_warn.visible, "warn count visible with warnings")
	_check(h, bar._warn_icon.visible, "warn icon visible with warnings")
	_check(h, bar._count_warn.get_theme_color("font_color") == Bar.WARN_COUNT_COLOR, "warn count amber")
	_check(h, bar._opt.get_theme_color("font_color") == Color.RED, "message red for errors")
	_check(h, bar._opt.item_count == 2, "dropdown lists issues")
	_check(h, bar._opt.selected == 0, "dropdown selects first")
	bar.show_index(1)
	_check(h, bar._opt.selected == 1, "buttons move dropdown selection")
	_check(h, str(bar._pos.text) == "2/2", "pos follows buttons")
	_goto_seen.clear()
	bar._on_option_picked(0)
	_check(h, str((bar.current_issue() as Dictionary).get("message", "")) == "first", "dropdown pick selects issue")
	_check(h, str(bar._pos.text) == "1/2", "pos follows dropdown pick")
	_check(h, _goto_seen.size() == 1 and str((_goto_seen[0] as Dictionary).get("message", "")) == "first", "dropdown pick focuses editor")
	bar.show_index(5)
	_check(h, str((bar.current_issue() as Dictionary).get("message", "")) == "second", "model clamp")
	bar.show_index(0)
	_goto_seen.clear()
	bar.show_index(Bar.next_index(0, 2))
	_check(h, _goto_seen.size() == 1 and str((_goto_seen[0] as Dictionary).get("message", "")) == "second", "goto wired")
	bar.clear_results()
	_check(h, bar.issue_count() == 0, "model cleared")
	_check(h, bar._opt.item_count == 0, "dropdown cleared")
	_check(h, bar._opt.disabled, "dropdown disabled when cleared")
	_check(h, not bar._pos.visible, "pos hidden when cleared")
	_check(h, str(bar._count.text) == "0", "err zero when cleared")
	_check(h, not bar._count_warn.visible, "warn count hidden when cleared")
	_check(h, not bar._warn_icon.visible, "warn icon hidden when cleared")
	bar.set_results([{"severity": "error", "kind": "e", "message": "only", "line": 1, "column": 1, "path": "res://x.gd"}], "res://x.gd", null)
	_check(h, str(bar._pos.text) == "1/1", "err-only pos")
	_check(h, str(bar._count.text) == "1", "err-only count")
	_check(h, not bar._count_warn.visible, "warn count hidden without warnings")
	_check(h, not bar._warn_icon.visible, "warn icon hidden without warnings")
	bar.clear_results()
	bar.queue_free()


func _bar_model_sorted(h) -> void:
	var items := [
		{"severity": "warning", "kind": "b", "message": "late-warn", "line": 9, "column": 1},
		{"severity": "error", "kind": "a", "message": "late-err", "line": 9, "column": 1},
		{"severity": "error", "kind": "c", "message": "early", "line": 2, "column": 5},
	]
	items.sort_custom(func(a: Variant, b: Variant) -> bool: return Impl._issue_less(a, b))
	_check(h, str((items[0] as Dictionary).get("message", "")) == "early", "combined sort by line")
	_check(h, str((items[1] as Dictionary).get("message", "")) == "late-err", "errors before warnings on ties")
	_check(h, str((items[2] as Dictionary).get("message", "")) == "late-warn", "warnings last on ties")
func _on_goto(issue: Dictionary) -> void:
	_goto_seen.append(issue)


func _tree_nulls(h) -> void:
	_tree_nulls_basic(h)
	_tree_ui(h)


func _tree_nulls_basic(h) -> void:
	_check(h, not EdTree.is_code_edit(null), "null not code edit")
	_check(h, EdTree.script_editor() == null, "no script editor headless")
	_check(h, EdTree.resolve_code_edit(null) == null, "null resolve")
	_check(h, EdTree.apply_highlights(null, [1], Color.RED, Color.YELLOW, []) == [], "null highlights")
	EdTree.clear_highlights(null, [1])
	_check(h, not EdTree.goto_line(null, null, 3), "null goto false")
	_check(h, EdTree.find_status_host(null) == {}, "null host")
	_check(h, EdTree.resolve_code_edit(MockEditor.new(null)) == null, "mock without editor resolves null")
	_check(h, EdTree.editor_mark_color() == Color(0, 0, 0, 0), "mark color transparent headless")
	_check(h, EdTree.editor_warning_color() == Color(0, 0, 0, 0), "warning color transparent headless")
	_check(h, EdTree.godot_error_color(null) == Color(0, 0, 0, 0), "error color null transparent")
	_check(h, EdTree.godot_warning_color(null) == Color(0, 0, 0, 0), "warning color null transparent")
	_check(h, EdTree.editor_status_icon("StatusError") == null, "status icon null headless")
	_check(h, EdTree.editor_error_icon() == null, "error icon null headless")
	_check(h, EdTree.editor_warning_icon() == null, "warning icon null headless")


class MockEditor extends RefCounted:
	var _ce: Object = null

	func _init(ce: Object) -> void:
		_ce = ce

	func get_code_editor() -> Object:
		return _ce


func _tree_ui(h) -> void:
	_tree_placement(h)
	_tree_highlight(h)


func _tree_placement(h) -> void:
	var root := VBoxContainer.new()
	root.name = "Root"
	var filler := Label.new()
	filler.text = "tabs"
	root.add_child(filler)
	var status := HBoxContainer.new()
	status.name = "StatusBar"
	var lab := Label.new()
	lab.text = "Error at (1, 1): nope"
	status.add_child(lab)
	root.add_child(status)
	var host := EdTree.find_status_host(root)
	_check(h, not host.is_empty(), "host found in mock tree")
	var bar = Bar.new()
	EdTree.place_above(host, bar)
	_check(h, (bar as Node).get_index() == (status as Node).get_index() - 1, "bar sits above status")
	EdTree.place_above(host, bar)
	_check(h, (bar as Node).get_index() == (status as Node).get_index() - 1, "placement idempotent")
	var stray := HBoxContainer.new()
	root.add_child(stray)
	EdTree.place_above({"host": status, "parent": root, "index": (status as Node).get_index()}, stray)
	_check(h, (stray as Node).get_index() == (status as Node).get_index() - 1, "repair after drift")
	EdTree.place_above({"host": status, "parent": root, "index": (status as Node).get_index()}, bar)
	EdTree.place_above({}, bar)
	_check(h, (bar as Node).get_index() == (status as Node).get_index() - 1, "empty host no-op")
	bar.queue_free()
	stray.queue_free()
	root.queue_free()


func _tree_highlight(h) -> void:
	var ce := TextEdit.new()
	ce.text = "line one\nline two\nline three\n"
	_check(h, EdTree.godot_error_color(ce) == Color(0, 0, 0, 0), "error color transparent when unpainted")
	ce.set_line_background_color(0, Color(0.5, 0.1, 0.1, 0.3))
	_check(h, EdTree.godot_error_color(ce) == Color(0.5, 0.1, 0.1, 0.3), "error color legacy line fallback")
	ce.set_line_background_color(0, Color(0, 0, 0, 0))
	var mock := MockEditor.new(ce)
	_check(h, EdTree.resolve_code_edit(mock) == ce, "mock editor resolves")
	_check(h, EdTree.is_text_editor(mock), "mock counts as text editor")
	var bar = Bar.new()
	bar.set_results([{"severity": "error", "kind": "e", "message": "bad", "line": 2, "column": 1, "path": "res://x.gd"}], "res://x.gd", ce)
	_check(h, ce.get_line_background_color(1) != Color(0, 0, 0, 0), "error line painted")
	bar.clear_results()
	_check(h, ce.get_line_background_color(1) == Color(0, 0, 0, 0), "paint cleared")
	bar.set_results([{"severity": "error", "kind": "e", "message": "bad", "line": 3, "column": 1, "path": "res://x.gd"}], "res://x.gd", ce)
	_check(h, EdTree.goto_line(ce, null, 3), "goto works")
	_check(h, ce.get_caret_line() == 2, "caret moved")
	bar.queue_free()
	ce.queue_free()


func _warm(h) -> void:
	var root := Impl.project_root()
	_check(h, root != "" and DirAccess.dir_exists_absolute(root), "project root resolves")
	var paths: Array = Impl.collect_project_scripts(root)
	_check(h, not paths.is_empty(), "collect finds scripts")
	var sorted := paths.duplicate()
	sorted.sort()
	_check(h, paths == sorted, "collect sorted")
	var nodot := true
	for p in paths:
		if ".godot/" in str(p):
			nodot = false
	_check(h, nodot, "collect skips data dir")
	_check(h, "res://addons/0GnumarusGodotProjectAnalyzerSuite/tests/TmpRosterTarget.gd" in paths, "collect has fixture")
	_check(h, Impl.json_for_source("res://addons/0GnumarusGodotProjectAnalyzerSuite/tests/TmpRosterTarget.gd") == Impl.user_dir() + "/TmpRosterTarget.json", "json stem via roster")
	_check(h, Impl.json_for_source("res://addons/0GnumarusGodotProjectAnalyzerSuite/tests/helpers.gd").ends_with("helpers.json"), "json stem via path")
	var pair := [
		"res://addons/0GnumarusGodotProjectAnalyzerSuite/tests/ValidScript0.gd",
		"res://addons/0GnumarusGodotProjectAnalyzerSuite/tests/TmpRosterTarget.gd",
	]
	var impl = Impl.new(null)
	var done := impl.warm_step(pair, 0, 60000)
	_check(h, done == pair.size(), "warm step completes")
	_check(h, FileAccess.file_exists(Impl.json_for_source(pair[0])), "warm writes json")
	done = impl.warm_step(pair, 0, 60000)
	_check(h, done == pair.size(), "warm second pass completes")
	_check(h, impl.warm_step(pair, pair.size(), 60000) == pair.size(), "warm past end stable")
	_check(h, impl.warm_step([], 0, 60000) == 0, "warm empty stable")
	DirAccess.remove_absolute(Impl.json_for_source(pair[0]))
	DirAccess.remove_absolute(Impl.json_for_source(pair[1]))


func _deps(h) -> void:
	_check(h, Impl.deps_changed(["ZZMissingDep_xyz"], 0.0, Impl.user_dir()), "missing dep triggers")
	_check(h, not Impl.deps_changed([], 0.0, Impl.user_dir()), "no refs calm")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(Impl.user_dir()))
	var dummy := Impl.user_dir() + "/ZZDepsDummy.json"
	var f := FileAccess.open(dummy, FileAccess.WRITE)
	(f as FileAccess).store_string("{}")
	(f as FileAccess).close()
	_check(h, Impl.deps_changed(["ZZDepsDummy"], 0.0, Impl.user_dir()), "stale stamp triggers")
	_check(h, not Impl.deps_changed(["ZZDepsDummy"], 99999999999.0, Impl.user_dir()), "future stamp calm")
	DirAccess.remove_absolute(dummy)
	var impl = Impl.new(null)
	_check(h, (impl._last_refs as Array).is_empty(), "refs start empty")


func _warm_order(h) -> void:
	Impl.Analyzer._roster_refresh(Impl.project_root())
	Impl.Analyzer._roster_absorb(Impl.Analyzer._roster_scan_files(Impl.project_root()))
	var child := "res://addons/0GnumarusGodotProjectAnalyzerSuite/tests/TmpRosterChild.gd"
	var parent := "res://addons/0GnumarusGodotProjectAnalyzerSuite/tests/TmpRosterParent.gd"
	var ordered: Array = Impl.order_for_warm([child, parent])
	_check(h, ordered == [parent, child], "leaves before dependents")
	_check(h, Impl.order_for_warm([parent, child]) == [parent, child], "ordered input stable")
	var lone := "res://addons/0GnumarusGodotProjectAnalyzerSuite/tests/TmpRosterTarget.gd"
	_check(h, Impl.order_for_warm([child, lone, parent]) == [parent, lone, child], "unknown keeps sorted slot")


func _bar_origin(h) -> void:
	_check(h, Bar.origin_text("") == "", "origin empty silent")
	_check(h, Bar.origin_text("deps") == " (deps)", "origin deps marked")
	_check(h, Bar.origin_text("other") == "", "origin unknown silent")
	var bar = Bar.new()
	bar.set_results([{"severity": "error", "kind": "e", "message": "m", "line": 2, "column": 1}], "res://x.gd", null, "deps")
	_check(h, str(bar._pos.text) == "1/1 (deps)", "origin paints beside position")
	bar.set_results([{"severity": "error", "kind": "e", "message": "m", "line": 2, "column": 1}], "res://x.gd", null)
	_check(h, str(bar._pos.text) == "1/1", "plain run clears origin")
	bar.free()


func _warm_fs(h) -> void:
	var impl = Impl.new(null)
	impl._on_filesystem_changed()
	_check(h, impl._warm_pending.is_empty() and not impl._warm_restart, "idle fs change stays quiet headless")
	impl._warm_pending = ["res://x.gd"]
	impl._warm_idx = 1
	impl._on_filesystem_changed()
	_check(h, impl._warm_restart, "active fs change flags restart")
	_check(h, impl._warm_pending == ["res://x.gd"] and impl._warm_idx == 1, "flagged pass untouched")
	impl.exit_tree()
	_check(h, impl._warm_pending.is_empty() and not impl._warm_restart, "exit clears warm state")
