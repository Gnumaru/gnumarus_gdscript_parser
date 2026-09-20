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
const SemParser = preload("res://addons/0GnumarusGodotProjectAnalyzerSuite/GnumarusGodotProjectAnalyzerSuiteGdscriptSemanticParser.gd")

const DEBOUNCE_SEC := 1.0
## Files per warm pump tick (deferred chain, cancellable).
const WARM_CHUNK := 5
## Milliseconds per warm tick (whichever hits first with the chunk).
const WARM_BUDGET_MS := 120

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
var _last_refs: Array = []
var _last_run_unix := 0.0
var _warm_pending: Array = []
var _warm_idx := 0


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
	_ensure_strict_setting()
	_ensure_debounce()
	_hook_signals(true)
	ensure_bar()
	_rewatch_code_edit()
	analyze_current(false)
	_start_warm()


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


## Registers the strict-untyped ProjectSetting once (keeps the user
## value on later enables): under distrust, member use on
## declared-but-untyped slots warns. The file `# @strict_untyped`
## tag overrides per file; changing the setting applies on the next
## analysis pass.
static func _ensure_strict_setting() -> void:
	var key := "gnumarus_analyzer/strict_untyped"
	if not ProjectSettings.has_setting(key):
		ProjectSettings.set_setting(key, false)
	ProjectSettings.set_initial_value(key, false)
	ProjectSettings.add_property_info({"name": key, "type": TYPE_BOOL})


## Fresh analyzer carrying the current ProjectSetting policy as its
## explicit base (file tags still override per file inside analyze).
## Kept in one place so every analysis entry point stays consistent.
static func _fresh_analyzer() -> RefCounted:
	var ana = Analyzer.new()
	ana.null_policy = str(ProjectSettings.get_setting("gnumarus_analyzer/nullable_policy", "trust"))
	ana.strict_untyped = bool(ProjectSettings.get_setting("gnumarus_analyzer/strict_untyped", false))
	return ana


## Project OS root (globalized res://). Static, headless-safe.
static func project_root() -> String:
	var r := ProjectSettings.globalize_path("res://")
	if r.ends_with("/") and r.length() > 1:
		r = r.substr(0, r.length() - 1)
	return r


## res:// data dir holding user JSONs (mirrors the analyzer base).
## Static, headless-safe.
static func user_dir() -> String:
	return "res://.godot/0GnumarusGodotProjectAnalyzerSuiteData/user"


## Sorted res:// paths of every project .gd (skips `.godot/`).
## Static, pure IO, headless-safe.
static func collect_project_scripts(root: String) -> Array:
	var out: Array = []
	if root == "" or not DirAccess.dir_exists_absolute(root):
		return out
	var dirs: Array = [root]
	while not dirs.is_empty():
		var dir: String = str(dirs.pop_back())
		if dir == "" or not DirAccess.dir_exists_absolute(dir):
			continue
		for sub in DirAccess.get_directories_at(dir):
			if str(sub) != ".godot":
				dirs.append(dir + "/" + str(sub))
		for f in DirAccess.get_files_at(dir):
			if str(f).ends_with(".gd"):
				out.append(_res_path(root, dir + "/" + str(f)))
	out.sort()
	return out


## Dependency order for a warm batch (Kahn, leaves first): a file
## whose extends resolves to another batch file sorts after it, so
## parents are analyzed (JSONs written) before children cascade into
## on-demand re-analysis. Unknown/engine/uncached heads add no edge;
## cycles and the rest keep sorted order. Static, no IO beyond the
## roster (callers refresh first).
static func order_for_warm(paths: Array) -> Array:
	var in_batch := {}
	for p in paths:
		in_batch[str(p)] = true
	var file_deps: Dictionary = {}
	for p in paths:
		file_deps[str(p)] = []
	for k in Analyzer._roster_names.keys():
		var p := str(Analyzer._roster_names[k])
		if not file_deps.has(p):
			continue
		var dp := _warm_dep_path(str(Analyzer._roster_extends.get(k, "")))
		if dp != "" and dp != p and in_batch.has(dp):
			if not (file_deps[p] as Array).has(dp):
				(file_deps[p] as Array).append(dp)
	var ordered: Array = []
	var remaining: Array = paths.duplicate()
	remaining.sort()
	var emitted := {}
	var progress := true
	while progress and not remaining.is_empty():
		progress = false
		var rest: Array = []
		for p in remaining:
			var waiting := false
			for d in (file_deps[str(p)] as Array):
				if not emitted.has(d):
					waiting = true
					break
			if waiting:
				rest.append(p)
			else:
				ordered.append(p)
				emitted[str(p)] = true
				progress = true
		remaining = rest
	for p in remaining:
		ordered.append(p)
	return ordered


## res:// dependency path behind a roster extends head (""): bare and
## dotted class names via the roster, quoted `"res://..."` heads
## directly. Static, pure.
static func _warm_dep_path(head: String) -> String:
	var h := head.strip_edges()
	if h == "":
		return ""
	if h.begins_with("\"") and h.ends_with("\"") and h.length() >= 2:
		return h.substr(1, h.length() - 2)
	if Analyzer._roster_names.has(h):
		return str(Analyzer._roster_names[h])
	return ""


## OS/dir path to res:// form under root (falls back to the raw path
## outside the root). Static, pure.
static func _res_path(root: String, abspath: String) -> String:
	if root != "" and abspath.begins_with(root):
		var rel := abspath.substr(root.length()).trim_prefix("/")
		return "res://" + rel
	return abspath


## Expected user JSON res:// path for a source res:// path:
## class_name via the roster reverse map, else the path-derived base
## (same rule as the writers). Static, no IO.
static func json_for_source(source_res_path: String) -> String:
	var stem := Analyzer._roster_class_for_path(source_res_path)
	if stem == "":
		stem = SemParser.user_file_base("", "", source_res_path)
	return user_dir() + "/" + stem + ".json"


## True when any referenced dep JSON is missing or newer than the
## analysis stamp (unix seconds; 1s granularity). Static, pure IO,
## headless-safe. Callers pass the analyzer `_last_refs`.
static func deps_changed(refs: Array, since_unix: float, dir: String) -> bool:
	for r in refs:
		var jp := dir + "/" + str(r) + ".json"
		if not FileAccess.file_exists(jp):
			return true
		if float(FileAccess.get_modified_time(jp)) > since_unix:
			return true
	return false


## One warm chunk: analyzes stale/missing-JSON sources from
## paths[idx:], stopping at the chunk/budget cap. Returns the next
## index (== size when done). Headless-runnable; editors pump it
## deferred (see _warm_pump). Skips up-to-date files by mtime.
func warm_step(paths: Array, from_idx: int, budget_ms: int) -> int:
	var i := mini(maxi(from_idx, 0), paths.size())
	var t0 := Time.get_ticks_msec()
	var done := 0
	while i < paths.size():
		var src := str(paths[i])
		if src != "" and FileAccess.file_exists(src):
			var js := json_for_source(src)
			var sm := FileAccess.get_modified_time(src)
			if not FileAccess.file_exists(js) or sm > FileAccess.get_modified_time(js):
				var ana = _fresh_analyzer()
				ana.analyze(SynParser.new().parse_text(FileAccess.get_file_as_string(src)), src)
		i += 1
		done += 1
		if done >= WARM_CHUNK or Time.get_ticks_msec() - t0 >= budget_ms:
			break
	return i


## Starts the background warm pass (editor only — headless instances
## never pump, so unit tests stay hermetic). Roster refreshes plus one
## full scan (extends edges for ordering) first, then leaves-first
## order minimizes on-demand cascades mid-pass.
func _start_warm() -> void:
	_warm_pending = []
	_warm_idx = 0
	if not Engine.is_editor_hint():
		return
	Analyzer._roster_refresh(project_root())
	Analyzer._roster_absorb(Analyzer._roster_scan_files(project_root()))
	_warm_pending = order_for_warm(collect_project_scripts(project_root()))
	_warm_idx = 0
	if not _warm_pending.is_empty():
		call_deferred("_warm_pump")


## One deferred warm tick; chains until done or cancelled by
## exit_tree (which empties the pending list first).
func _warm_pump() -> void:
	if _warm_pending.is_empty():
		return
	_warm_idx = warm_step(_warm_pending, _warm_idx, WARM_BUDGET_MS)
	if _warm_idx < _warm_pending.size():
		call_deferred("_warm_pump")
	else:
		_warm_pending = []


## Editor exit point (forwarded by the proxy).
func exit_tree() -> void:
	_hook_signals(false)
	_unwatch_code_edit()
	_warm_pending = []
	_warm_idx = 0
	_drop(_debounce)
	_debounce = null
	_drop(_bar)
	_bar = null
	_has_last = false


## Editor input point (forwarded by the proxy). Returns true when the
## hotkey consumed the event (the proxy marks it handled).
func _input(event: InputEvent) -> void:
	if is_analyze_hotkey(event):
		analyze_current(true)
		plugin.get_viewport().set_input_as_handled()


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
	var same := not announce and _has_last and path == _last_path and h == _last_hash
	var via_deps := same and deps_changed(_last_refs, _last_run_unix, user_dir())
	if same and not via_deps:
		_rewatch_code_edit()
		return
	_last_path = path
	_last_hash = h
	_has_last = true
	var ana = _fresh_analyzer()
	var res: Dictionary = ana.analyze(SynParser.new().parse_text(text), path)
	_last_refs = (ana._last_refs as Array).duplicate() if ana._last_refs is Array else []
	_last_run_unix = Time.get_unix_time_from_system()
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
	(bar as Object).call("set_results", issues, path, code_edit, "deps" if via_deps else "")
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
