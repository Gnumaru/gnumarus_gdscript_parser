class_name GnumarusGodotProjectAnalyzerSuitePluginImpl
extends RefCounted

## Gnumarus Analyzer implementation: analyzes the current GDScript
## with the project analyzer suite and shows its errors/warnings in
## a status bar above the script status bar, with red line highlights
## and prev/next navigation. Analysis is realtime with debounce:
## immediate on file open/switch plus 1s after the last edit.
## Ctrl+Shift+Alt+F5 forces an immediate run that also logs to console.
##
## This class owns every behavior; GnumarusGodotProjectAnalyzerSuitePlugin
## is a dumb EditorPlugin proxy that only forwards _enter_tree,
## _exit_tree and _input here. RefCounted (not a Node) on purpose, so
## the whole logic instantiates headless in unit tests: pass null as
## the plugin there (every plugin use is null-guarded). Inside the
## editor the proxy passes itself and the timer is parented to it.

const Bar = preload("res://addons/0GnumarusGodotProjectAnalyzerSuite/GnumarusGodotProjectAnalyzerSuiteStatusBar.gd")
const EdTree = preload("res://addons/0GnumarusGodotProjectAnalyzerSuite/GnumarusGodotProjectAnalyzerSuiteEditorTree.gd")
const SynParser = preload("res://addons/0GnumarusGodotProjectAnalyzerSuite/GnumarusGodotProjectAnalyzerSuiteGdscriptSyntaticParser.gd")
const Analyzer = preload("res://addons/0GnumarusGodotProjectAnalyzerSuite/GnumarusGodotProjectAnalyzerSuiteGdscriptAnalyzer.gd")

const DEBOUNCE_SEC := 1.0

## EditorPlugin host (null headless). Only Node services are used
## (add_child, get_viewport): everything else goes through singletons.
var plugin: EditorPlugin = null

var _bar: Control = null
var _warned_fallback := false
var _debounce: Timer = null
var _watched_ce: Object = null
var _last_path := ""
var _last_hash := 0
var _has_last := false


func _init(p_plugin: EditorPlugin = null) -> void:
	plugin = p_plugin


static func is_analyze_hotkey(event: InputEvent) -> bool:
	if not (event is InputEventKey):
		return false
	var k: InputEventKey = event
	if not k.pressed or k.echo:
		return false
	if k.keycode != KEY_F5 and k.physical_keycode != KEY_F5:
		return false
	return k.ctrl_pressed and k.shift_pressed and k.alt_pressed


## Debounce delay in seconds: at least DEBOUNCE_SEC, and past Godot's
## own idle parser delay when configured (so our paint lands after the
## native background reset). Pure, unit-tested headless.
static func debounce_interval(raw: Variant) -> float:
	if raw is float or raw is int:
		var v := float(raw)
		if v > 0.0:
			return maxf(DEBOUNCE_SEC, v + 0.3)
	return DEBOUNCE_SEC


## Live debounce delay, reading idle_parse_delay when available.
static func _live_debounce() -> float:
	if not Engine.is_editor_hint():
		return DEBOUNCE_SEC
	if not Engine.has_singleton("EditorInterface"):
		return DEBOUNCE_SEC
	var ei: Object = Engine.get_singleton("EditorInterface")
	if ei == null or not is_instance_valid(ei):
		return DEBOUNCE_SEC
	if not (ei as Object).has_method("get_editor_settings"):
		return DEBOUNCE_SEC
	var settings: Variant = (ei as Object).call("get_editor_settings")
	if settings == null or not (settings is Object) or not is_instance_valid(settings):
		return DEBOUNCE_SEC
	if not (settings as Object).has_method("get_setting"):
		return DEBOUNCE_SEC
	return debounce_interval((settings as Object).call("get_setting", "text_editor/completion/idle_parse_delay"))


## Editor entry point (forwarded by the proxy).
func enter_tree() -> void:
	_ensure_policy_setting()
	_ensure_debounce()
	_hook_signals(true)
	ensure_bar()
	_rewatch_code_edit()
	analyze_current(false)


## Registers the nullable-policy ProjectSetting once (keeps the user
## value on later enables): "trust" keeps Godot's own leniency,
## "distrust" warns on unguarded implicitly-nullable use. The file
## `# @nullable_policy` tag overrides per file; changing the setting
## applies on the next analysis pass.
static func _ensure_policy_setting() -> void:
	var key := "gnumarus_analyzer/nullable_policy"
	if not ProjectSettings.has_setting(key):
		ProjectSettings.set_setting(key, "trust")
	ProjectSettings.set_initial_value(key, "trust")
	ProjectSettings.add_property_info({"name": key, "type": TYPE_STRING, "hint": PROPERTY_HINT_ENUM, "hint_string": "trust,distrust"})


## Fresh analyzer carrying the current ProjectSetting policy as its
## explicit base (file tags still override per file inside analyze).
## Kept in one place so every analysis entry point stays consistent.
static func _fresh_analyzer() -> RefCounted:
	var ana = Analyzer.new()
	ana.null_policy = str(ProjectSettings.get_setting("gnumarus_analyzer/nullable_policy", "trust"))
	return ana


## Editor exit point (forwarded by the proxy).
func exit_tree() -> void:
	_hook_signals(false)
	_unwatch_code_edit()
	_drop(_debounce)
	_debounce = null
	_drop(_bar)
	_bar = null
	_has_last = false


## Editor input point (forwarded by the proxy). Returns true when the
## hotkey consumed the event (the proxy marks it handled).
func handle_input(event: InputEvent) -> bool:
	if is_analyze_hotkey(event):
		analyze_current(true)
		return true
	return false


## Frees a Node now when it is outside the tree (headless/tests) and
## defers to the frame end inside it. Keeps teardown warning-free in
## both worlds.
static func _drop(node: Variant) -> void:
	if node == null or not (node is Object) or not is_instance_valid(node):
		return
	if (node as Node).is_inside_tree():
		(node as Node).queue_free()
	else:
		(node as Node).free()


func _hook_signals(connect_now: bool) -> void:
	var se := EdTree.script_editor()
	if se == null:
		return
	for sig in ["editor_script_changed", "script_close"]:
		if not (se as Object).has_signal(sig):
			continue
		var already: bool = (se as Object).is_connected(sig, _on_context_changed)
		if connect_now and not already:
			(se as Object).connect(sig, _on_context_changed)
		elif not connect_now and already:
			(se as Object).disconnect(sig, _on_context_changed)


## Returns the live bar, building it on first use and repairing its
## position on every call: the ScriptEditor UI may not exist yet at
## plugin init (fallback docking), and context switches can move or
## orphan it. Whenever Godot's status bar is found, our bar sits
## right above it; otherwise the last known placement is kept.
func ensure_bar() -> Control:
	var se := EdTree.script_editor()
	if se == null:
		return null
	if _bar == null or not is_instance_valid(_bar):
		_bar = Bar.new()
		_bar.set_navigate_fn(Callable(self, "_goto_issue"))
	var host := EdTree.find_status_host(se)
	if host.is_empty():
		if not (_bar as Node).is_inside_tree():
			(se as Node).add_child(_bar)
			(_bar as Control).set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
			if not _warned_fallback:
				_warned_fallback = true
				push_warning("Gnumarus Analyzer: script status bar not found, docked at editor bottom.")
		return _bar
	EdTree.place_above(host, _bar)
	return _bar


func _on_context_changed(_script: Variant = null) -> void:
	# File opened or tab switched: repair the bar, rewatch the new
	# CodeEdit and show issues right away (no debounce here). Then
	# force one deferred pass: Godot's own validator runs after us
	# and resets every line background, wiping our paint; the timer
	# (past Godot's idle delay) repaints once it settles. At most one
	# extra analysis per open/switch.
	ensure_bar()
	_rewatch_code_edit()
	analyze_current(false)
	_has_last = false
	_restart_debounce()


## One-shot debounce timer, parented to the plugin host when present
## (headless it stays orphaned and refuses to tick: see restart).
func _ensure_debounce() -> void:
	if _debounce != null and is_instance_valid(_debounce):
		_debounce.wait_time = _live_debounce()
		return
	_debounce = Timer.new()
	(_debounce as Timer).one_shot = true
	(_debounce as Timer).wait_time = _live_debounce()
	(_debounce as Timer).timeout.connect(_on_debounce_timeout)
	if plugin != null and is_instance_valid(plugin):
		plugin.add_child(_debounce)


## Watches the current CodeEdit text_changed signal. Re-resolved from
## scratch on every use; the old watch is always dropped first, so a
## destroyed CodeEdit never leaks a connection.
func _rewatch_code_edit() -> void:
	_ensure_debounce()
	var se := EdTree.script_editor()
	var ce: Object = null
	if se != null:
		var ed := EdTree.current_editor(se)
		if ed != null:
			ce = EdTree.resolve_code_edit(ed)
	if _watched_ce != null and is_instance_valid(_watched_ce):
		if _watched_ce == ce:
			return
		_unwatch_code_edit()
	_watched_ce = ce
	if _watched_ce != null and is_instance_valid(_watched_ce):
		if (_watched_ce as Object).has_signal("text_changed"):
			if not (_watched_ce as Object).is_connected("text_changed", _on_text_changed):
				(_watched_ce as Object).connect("text_changed", _on_text_changed)


func _unwatch_code_edit() -> void:
	if _watched_ce != null and is_instance_valid(_watched_ce):
		if (_watched_ce as Object).has_signal("text_changed"):
			if (_watched_ce as Object).is_connected("text_changed", _on_text_changed):
				(_watched_ce as Object).disconnect("text_changed", _on_text_changed)
	_watched_ce = null


## Last keystroke restarts the 1s countdown; analysis runs only after
## the buffer stays still. Painting text never emits text_changed,
## so this cannot loop on itself.
func _on_text_changed() -> void:
	_restart_debounce()


## (Re)starts the one-shot debounce countdown with the live delay.
## Safe headless (the countdown itself only ticks in the editor tree).
func _restart_debounce() -> void:
	if _debounce == null or not is_instance_valid(_debounce):
		_ensure_debounce()
		if _debounce == null:
			return
	EdTree.restart_debounce(_debounce, _live_debounce())


func _on_debounce_timeout() -> void:
	analyze_current(false)


func analyze_current(announce := true) -> void:
	var bar := ensure_bar()
	if bar == null:
		return
	var se := EdTree.script_editor()
	if se == null:
		return
	var ed := EdTree.current_editor(se)
	if ed == null or not EdTree.is_text_editor(ed):
		(bar as Object).call("clear_results")
		_has_last = false
		return
	var scr := EdTree.current_script(se)
	if scr != null and not EdTree.is_gdscript(scr):
		(bar as Object).call("clear_results")
		_has_last = false
		return
	var code_edit := EdTree.resolve_code_edit(ed)
	var text := EdTree.current_text(code_edit, se)
	if text.strip_edges() == "":
		(bar as Object).call("clear_results")
		_has_last = false
		return
	var path := EdTree.current_path(se)
	if path.strip_edges() == "":
		path = "res://untitled.gd"
	var h := text.hash()
	if not announce and _has_last and path == _last_path and h == _last_hash:
		_rewatch_code_edit()
		return
	_last_path = path
	_last_hash = h
	_has_last = true
	var res: Dictionary = _fresh_analyzer().analyze(SynParser.new().parse_text(text), path)
	var issues: Array = []
	for e in res.get("errors", []):
		if e is Dictionary:
			issues.append({"severity": "error", "kind": str((e as Dictionary).get("kind", "?")), "message": str((e as Dictionary).get("message", "")), "line": int((e as Dictionary).get("line", 0)), "column": int((e as Dictionary).get("column", 0)), "path": path})
	for w in res.get("warnings", []):
		if w is Dictionary:
			issues.append({"severity": "warning", "kind": str((w as Dictionary).get("kind", "?")), "message": str((w as Dictionary).get("message", "")), "line": int((w as Dictionary).get("line", 0)), "column": int((w as Dictionary).get("column", 0)), "path": path})
	issues.sort_custom(func(a: Variant, b: Variant) -> bool: return _issue_less(a, b))
	if announce:
		for issue in issues:
			if (issue as Dictionary).get("severity", "error") == "error":
				push_error("Gnumarus [%s] %s:%d - %s" % [str((issue as Dictionary).get("kind", "?")), path, int((issue as Dictionary).get("line", 0)), str((issue as Dictionary).get("message", ""))])
			else:
				push_warning("Gnumarus [%s] %s:%d - %s" % [str((issue as Dictionary).get("kind", "?")), path, int((issue as Dictionary).get("line", 0)), str((issue as Dictionary).get("message", ""))])
	(bar as Object).call("set_results", issues, path, code_edit)
	_rewatch_code_edit()


## Navigation order: position first, errors before warnings on ties.
static func _issue_less(a: Variant, b: Variant) -> bool:
	if not (a is Dictionary):
		return false
	if not (b is Dictionary):
		return true
	var ad: Dictionary = a
	var bd: Dictionary = b
	var al := int(ad.get("line", 0))
	var bl := int(bd.get("line", 0))
	if al != bl:
		return al < bl
	var ac := int(ad.get("column", 0))
	var bc := int(bd.get("column", 0))
	if ac != bc:
		return ac < bc
	var ae := str(ad.get("severity", "error")) == "error"
	var be := str(bd.get("severity", "error")) == "error"
	if ae != be:
		return ae
	return str(ad.get("kind", "")) < str(bd.get("kind", ""))


func _goto_issue(issue: Dictionary) -> void:
	var se := EdTree.script_editor()
	if se == null:
		return
	if str(issue.get("path", "")) != "" and str(issue.get("path", "")) != EdTree.current_path(se):
		return
	var ed := EdTree.current_editor(se)
	if ed == null:
		return
	var code_edit := EdTree.resolve_code_edit(ed)
	EdTree.goto_line(code_edit, se, int(issue.get("line", 0)))
