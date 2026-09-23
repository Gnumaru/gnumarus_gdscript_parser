extends RefCounted

## Defensive resolvers for Godot editor nodes (ScriptEditor tree is
## dense and version-dependent). Every function re-resolves from
## scratch and returns null/{} on any doubt — callers must validate
## and be ready to rebuild at any time (context switches can destroy
## the UI out from under us). Only `script_editor()` touches the
## EditorInterface singleton, and only inside the editor.

const CODE_EDIT_CLASS := "CodeEdit"

## Generation counter for deferred Script-workspace asserts (see
## _assert_script_screen_soon): every navigation bumps it, and a
## deferred assert only fires when nothing newer arrived, so rapid
## clicks never yank the user back to a stale target.
static var _focus_gen := 0


## Records a navigation and returns its generation (see _focus_gen).
## Callers with deferred work pass it along; deferred asserts check it.
static func note_navigation() -> int:
	_focus_gen += 1
	return _focus_gen


## The ScriptEditor singleton, or null outside the editor.
static func script_editor() -> Object:
	if not Engine.is_editor_hint():
		return null
	var se: Variant = EditorInterface.get_script_editor()
	if se == null or not (se is Object) or not is_instance_valid(se):
		return null
	return se


## The currently edited ScriptEditorBase, or null.
static func current_editor(script_editor: Object) -> Object:
	if script_editor == null or not is_instance_valid(script_editor):
		return null
	if not (script_editor as Object).has_method("get_current_editor"):
		return null
	var ed: Variant = (script_editor as Object).call("get_current_editor")
	if ed == null or not (ed is Object) or not is_instance_valid(ed):
		return null
	return ed


## True when the editor looks like a GDScript text editor. We accept
## the native ScriptTextEditor class, or any editor exposing a CodeEdit
## child (future-proofing against renames).
static func is_text_editor(ed: Object) -> bool:
	if ed == null or not is_instance_valid(ed):
		return false
	if str((ed as Object).get_class()) == "ScriptTextEditor":
		return true
	return not (resolve_code_edit(ed) == null)


## Current script resource, or null.
static func current_script(script_editor: Object) -> Object:
	if script_editor == null or not is_instance_valid(script_editor):
		return null
	if not (script_editor as Object).has_method("get_current_script"):
		return null
	var scr: Variant = (script_editor as Object).call("get_current_script")
	if scr == null or not (scr is Object) or not is_instance_valid(scr):
		return null
	return scr


## True when the resource is a GDScript (or unknown — lenient).
static func is_gdscript(scr: Object) -> bool:
	if scr == null or not is_instance_valid(scr):
		return true
	return str((scr as Object).get_class()) == "GDScript"


## res:// path of the current script, "" when unknown.
static func current_path(script_editor: Object) -> String:
	var scr := current_script(script_editor)
	if scr == null:
		return ""
	var p: Variant = (scr as Object).get("resource_path")
	if p == null:
		return ""
	return str(p)


## The CodeEdit showing the current script, or null. Prefers an
## explicit get_code_editor() when the editor exposes one, then falls
## back to tree search (visible CodeEdit first).
static func resolve_code_edit(ed: Object) -> Object:
	if ed == null or not is_instance_valid(ed):
		return null
	if (ed as Object).has_method("get_code_editor"):
		var ce: Variant = (ed as Object).call("get_code_editor")
		if is_code_edit(ce):
			return ce
	if not (ed as Object).has_method("find_children"):
		return null
	var found: Array = (ed as Object).call("find_children", "*", CODE_EDIT_CLASS, true, false)
	for n in found:
		if is_code_edit(n) and (n as Node).is_visible_in_tree():
			return n
	for n2 in found:
		if is_code_edit(n2):
			return n2
	return null


## True for a usable code editing control (duck-typed, no class refs).
static func is_code_edit(n: Variant) -> bool:
	if n == null or not (n is Object) or not is_instance_valid(n):
		return false
	var o: Object = n
	return o.has_method("set_line_background_color") and o.has_method("get_line_count")


## Current buffer text, "" when unavailable.
static func current_text(code_edit: Object, script_editor: Object) -> String:
	if is_code_edit(code_edit):
		var t: Variant = (code_edit as Object).get("text")
		if t != null:
			return str(t)
	var scr := current_script(script_editor)
	if scr != null and ("source_code" in scr):
		var s: Variant = (scr as Object).get("source_code")
		if s != null:
			return str(s)
	return ""


## Locates Godot's own script status bar: the lowest visible
## HBoxContainer holding a Label, excluding our own bar. Returns
## {"host", "parent", "index"} or {} when nothing convincing exists.
static func find_status_host(script_editor: Object) -> Dictionary:
	if script_editor == null or not is_instance_valid(script_editor):
		return {}
	if not (script_editor as Object).has_method("find_children"):
		return {}
	var boxes: Array = (script_editor as Object).call("find_children", "*", "HBoxContainer", true, false)
	var best: Object = _pick_status_box(boxes, true)
	if best == null:
		best = _pick_status_box(boxes, false)
	if best == null:
		return {}
	var parent: Node = (best as Node).get_parent()
	if parent == null:
		return {}
	return {"host": best, "parent": parent, "index": (best as Node).get_index()}


## Lowest HBoxContainer holding a Label (excluding our bar);
## visible-only first, anything second.
static func _pick_status_box(boxes: Array, only_visible: bool) -> Object:
	var best: Object = null
	var best_y := -1.0
	for b in boxes:
		if not (b is Control):
			continue
		var bc := b as Control
		if only_visible and not bc.is_visible_in_tree():
			continue
		if str(bc.name).begins_with("GnumarusBar"):
			continue
		if not _has_label_child(bc):
			continue
		var y: float = bc.get_global_rect().position.y
		if y >= best_y:
			best_y = y
			best = bc
	return best


static func _has_label_child(c: Control) -> bool:
	if not c.has_method("find_children"):
		return false
	var labels: Array = c.call("find_children", "*", "Label", true, false)
	return not labels.is_empty()


## Moves a bar right above Godot's status host (no-op when already
## there). Reads the host index live (dict index may be stale after
## sibling drift) and adjusts for move_child's post-removal indexing.
## Survives reparenting. Pure Node ops.
static func place_above(host: Dictionary, bar: Control) -> void:
	if not (host.get("parent") is Node):
		return
	var parent: Node = host.get("parent")
	var host_node: Variant = host.get("host")
	if not (host_node is Node) or not is_instance_valid(host_node) or (host_node as Node).get_parent() != parent:
		return
	if (bar as Node).get_parent() != parent:
		var old := (bar as Node).get_parent()
		if old != null:
			(old as Node).remove_child(bar)
		parent.add_child(bar)
	var at: int = (host_node as Node).get_index()
	var bi: int = (bar as Node).get_index()
	if bi + 1 == at:
		return
	var target := at
	if bi >= 0 and bi < at:
		target = at - 1
	parent.move_child(bar, target)


## Godot's configured error-line color
## (text_editor/theme/highlighting/mark_color), transparent when
## unavailable (headless). Lets our red match the editor's on any
## theme even when Godot shows no native error lines.
static func editor_mark_color() -> Color:
	if not Engine.is_editor_hint():
		return Color(0, 0, 0, 0)
	if not Engine.has_singleton("EditorInterface"):
		return Color(0, 0, 0, 0)
	var ei: Object = Engine.get_singleton("EditorInterface")
	if ei == null or not is_instance_valid(ei):
		return Color(0, 0, 0, 0)
	if not (ei as Object).has_method("get_editor_settings"):
		return Color(0, 0, 0, 0)
	var settings: Variant = (ei as Object).call("get_editor_settings")
	if settings == null or not (settings is Object) or not is_instance_valid(settings):
		return Color(0, 0, 0, 0)
	if not (settings as Object).has_method("get_setting"):
		return Color(0, 0, 0, 0)
	var v: Variant = (settings as Object).call("get_setting", "text_editor/theme/highlighting/mark_color")
	if v is Color and (v as Color).a > 0.01:
		return v
	return Color(0, 0, 0, 0)


## Godot's configured warning-line color
## (text_editor/theme/highlighting/warning_color), transparent when
## unavailable (headless).
static func editor_warning_color() -> Color:
	if not Engine.is_editor_hint():
		return Color(0, 0, 0, 0)
	if not Engine.has_singleton("EditorInterface"):
		return Color(0, 0, 0, 0)
	var ei: Object = Engine.get_singleton("EditorInterface")
	if ei == null or not is_instance_valid(ei):
		return Color(0, 0, 0, 0)
	if not (ei as Object).has_method("get_editor_settings"):
		return Color(0, 0, 0, 0)
	var settings: Variant = (ei as Object).call("get_editor_settings")
	if settings == null or not (settings is Object) or not is_instance_valid(settings):
		return Color(0, 0, 0, 0)
	if not (settings as Object).has_method("get_setting"):
		return Color(0, 0, 0, 0)
	var v: Variant = (settings as Object).call("get_setting", "text_editor/theme/highlighting/warning_color")
	if v is Color and (v as Color).a > 0.01:
		return v
	return Color(0, 0, 0, 0)


## Godot's own error-line color: the configured mark_color first
## (stable with or without native errors), then the first painted
## line as legacy fallback (transparent when Godot shows none).
## Callers fall back to their constant when this is transparent.
static func godot_error_color(code_edit: Object) -> Color:
	var themed: Color = editor_mark_color()
	if themed.a > 0.01:
		return themed
	if not is_code_edit(code_edit):
		return Color(0, 0, 0, 0)
	var ce: Object = code_edit
	var count: int = int(ce.call("get_line_count"))
	for i in range(count):
		var c: Color = ce.call("get_line_background_color", i)
		if c.a > 0.01:
			return c
	return Color(0, 0, 0, 0)


## Godot's own warning-line color: the configured warning_color.
## No line scan here (a scan cannot tell errors from warnings);
## callers fall back to their constant when this is transparent.
static func godot_warning_color(_code_edit: Object) -> Color:
	return editor_warning_color()


## (Re)starts a one-shot debounce countdown with the given delay
## (stop + start so keystrokes reset it). Zero/negative delays only
## stop. A timer outside the scene tree cannot tick: the fresh delay
## is still stored and stop() applied, but start() is skipped and
## false returns (never an engine error). Returns the running state.
## Pure node ops: the plugin delegates its timer here so the countdown
## stays unit-testable.
static func restart_debounce(timer: Timer, delay_sec: float) -> bool:
	if timer == null or not is_instance_valid(timer):
		return false
	if delay_sec > 0.0:
		timer.wait_time = delay_sec
	timer.stop()
	if delay_sec <= 0.0 or not timer.is_inside_tree():
		return false
	timer.start()
	return not timer.is_stopped()


## Console status icons (the same red-circle / yellow-circle glyphs
## the Output panel filter buttons use). Null when unavailable
## (headless); callers keep their text/number layout as fallback.
static func editor_status_icon(icon_name: String) -> Texture2D:
	if not Engine.is_editor_hint():
		return null
	if not Engine.has_singleton("EditorInterface"):
		return null
	var ei: Object = Engine.get_singleton("EditorInterface")
	if ei == null or not is_instance_valid(ei):
		return null
	if not (ei as Object).has_method("get_editor_theme"):
		return null
	var theme: Variant = (ei as Object).call("get_editor_theme")
	if theme == null or not (theme is Object) or not is_instance_valid(theme):
		return null
	if not (theme as Object).has_method("has_icon") or not (theme as Object).has_method("get_icon"):
		return null
	if not bool((theme as Object).call("has_icon", icon_name, "EditorIcons")):
		return null
	var icon: Variant = (theme as Object).call("get_icon", icon_name, "EditorIcons")
	if icon is Texture2D:
		return icon
	return null


## Console error icon (red circle), null when unavailable.
static func editor_error_icon() -> Texture2D:
	return editor_status_icon("StatusError")


## Console warning icon (yellow circle), null when unavailable.
static func editor_warning_icon() -> Texture2D:
	return editor_status_icon("StatusWarning")


## Paints 1-based lines red (warnings amber), skipping out-of-range.
## Returns the lines actually painted (for later clearing).
static func apply_highlights(code_edit: Object, lines: Array, err_color: Color, warn_color: Color, warn_lines: Array) -> Array:
	var painted: Array = []
	if not is_code_edit(code_edit):
		return painted
	var ce: Object = code_edit
	var count: int = int(ce.call("get_line_count"))
	for ln in lines:
		var line := int(ln)
		if line < 1 or line > count:
			continue
		var col := err_color
		if int(ln) in warn_lines:
			col = warn_color
		ce.call("set_line_background_color", line - 1, col)
		painted.append(line)
	return painted


## Current background color of a 1-based line (transparent when
## unreadable or out of range). Never fails.
static func line_color(code_edit: Object, line: int) -> Color:
	if not is_code_edit(code_edit):
		return Color(0, 0, 0, 0)
	var ce: Object = code_edit
	var count: int = int(ce.call("get_line_count"))
	if line < 1 or line > count:
		return Color(0, 0, 0, 0)
	var c: Variant = ce.call("get_line_background_color", line - 1)
	if c is Color:
		return c
	return Color(0, 0, 0, 0)


## Snapshots current background colors of 1-based lines ({line:
## Color}, duplicates collapsed, out-of-range skipped). Call before
## painting; hand the map to restore_highlights on clear, so foreign
## paint (e.g. Godot's own error highlights underneath ours) survives
## our teardown. Never fails.
static func snapshot_highlights(code_edit: Object, lines: Array) -> Dictionary:
	var out := {}
	if not is_code_edit(code_edit):
		return out
	for ln in lines:
		var line := int(ln)
		if line < 1 or out.has(line):
			continue
		var count: int = int((code_edit as Object).call("get_line_count"))
		if line > count:
			continue
		out[line] = line_color(code_edit, line)
	return out


## Restores previously snapshotted background colors (out-of-range
## and non-Color entries skipped). Counterpart to
## snapshot_highlights. Never fails.
static func restore_highlights(code_edit: Object, prev: Dictionary) -> void:
	if not is_code_edit(code_edit):
		return
	var ce: Object = code_edit
	var count: int = int(ce.call("get_line_count"))
	for ln in prev.keys():
		var line := int(ln)
		if line < 1 or line > count:
			continue
		var c: Variant = prev[ln]
		if c is Color:
			ce.call("set_line_background_color", line - 1, c)


## Clears background paint of 1-based lines. Never fails.
static func clear_highlights(code_edit: Object, lines: Array) -> void:
	if not is_code_edit(code_edit):
		return
	var ce: Object = code_edit
	var count: int = int(ce.call("get_line_count"))
	for ln in lines:
		var line := int(ln)
		if line < 1 or line > count:
			continue
		ce.call("set_line_background_color", line - 1, Color(0, 0, 0, 0))


## Moves the caret to a 1-based line and focuses the editor. Falls
## back to ScriptEditor.goto_line(). Returns true when something
## plausible happened.
static func goto_line(code_edit: Object, script_editor: Object, line: int) -> bool:
	if line < 1:
		return false
	if is_code_edit(code_edit):
		var ce: Object = code_edit
		if ce.has_method("set_caret_line"):
			ce.call("set_caret_line", line - 1)
			if ce.has_method("center_viewport_to_caret"):
				ce.call("center_viewport_to_caret")
			if ce is Control and (ce as Control).is_inside_tree():
				(ce as Control).grab_focus()
			return true
	if script_editor != null and is_instance_valid(script_editor) and (script_editor as Object).has_method("goto_line"):
		(script_editor as Object).call("goto_line", line)
		return true
	return false


## The EditorInterface singleton, or null outside the editor.
## Every opener below goes through here (never a bare singleton
## reference), so all of them are null-safe and headless-testable.
static func editor_interface() -> Object:
	if not Engine.is_editor_hint():
		return null
	if not Engine.has_singleton("EditorInterface"):
		return null
	var ei: Object = Engine.get_singleton("EditorInterface")
	if ei == null or not is_instance_valid(ei):
		return null
	return ei


## Switches the editor main screen ("2D", "3D", "Script", "Game",
## "AssetLib"). False headless or without editor support; harmless
## when already there.
static func show_main_screen(screen_name: String) -> bool:
	if screen_name.strip_edges() == "":
		return false
	var ei := editor_interface()
	if ei == null or not (ei as Object).has_method("set_main_screen_editor"):
		return false
	(ei as Object).call("set_main_screen_editor", screen_name)
	return true


## Opens a .gd path in the script editor and moves to a 1-based line
## (line jump via the ScriptEditor fallback, since edit_script takes
## the script only here), revealing the Script workspace: edit_script
## alone leaves 2D/3D/Game/AssetLib on screen. False headless or when
## anything is missing.
static func open_script_at(path: String, line: int) -> bool:
	var ei := editor_interface()
	if ei == null or not (ei as Object).has_method("edit_script"):
		return false
	if path.strip_edges() == "" or not FileAccess.file_exists(path):
		return false
	var res: Variant = load(path)
	if not (res is Script):
		return false
	(ei as Object).call("edit_script", res)
	show_main_screen("Script")
	var se := script_editor()
	if se != null and line >= 1:
		goto_line(null, se, line)
	return true


## Opens a scene path in the editor (2D/3D main screen). False
## headless or without editor support.
static func open_scene(path: String) -> bool:
	var ei := editor_interface()
	if ei == null or not (ei as Object).has_method("open_scene_from_path"):
		return false
	if path.strip_edges() == "":
		return false
	(ei as Object).call("open_scene_from_path", path)
	return true


## Relative node path inside the edited scene for an absolute
## scene-root-prefixed path ("SceneRoot/d/e" -> "d/e", root itself ->
## "."). Pure.
static func relative_node_path(node_path: String, root_name: String) -> String:
	var np := str(node_path)
	var rn := str(root_name)
	if np == "" or rn == "":
		return np
	if np == rn:
		return "."
	if np.begins_with(rn + "/"):
		return np.substr(rn.length() + 1)
	return np


## Focuses a node in the edited scene (selects it so the inspector
## shows its script): opens nothing, so callers open the scene first.
## False headless, without editor support or when the node is missing.
static func focus_scene_node(node_path: String) -> bool:
	var ei := editor_interface()
	if ei == null:
		return false
	if str(node_path).strip_edges() == "":
		return false
	if not (ei as Object).has_method("get_edited_scene_root") or not (ei as Object).has_method("get_selection"):
		return false
	var root: Variant = (ei as Object).call("get_edited_scene_root")
	if not (root is Node) or not is_instance_valid(root):
		return false
	var rn := str((root as Node).name)
	var rel := relative_node_path(node_path, rn)
	var target: Node = null
	if rel == ".":
		target = root
	else:
		target = (root as Node).get_node_or_null(rel)
	if target == null or not is_instance_valid(target):
		return false
	var sel: Variant = (ei as Object).call("get_selection")
	if sel == null or not (sel is Object) or not is_instance_valid(sel):
		return false
	if (sel as Object).has_method("clear"):
		(sel as Object).call("clear")
	if (sel as Object).has_method("add_node"):
		(sel as Object).call("add_node", target)
	return true


## Opens the GDScript attached to a scene node and jumps to a 1-based
## embedded line. The scene must already be open (callers open it and
## focus the node first). Schedules a deferred Script-workspace assert
## (see _assert_script_screen_soon): opening the scene flips to 2D/3D
## after our immediate screen switch, so the workspace is re-asserted
## once the dust settles. False headless, without support or when the
## node carries no script.
static func open_node_script(node_path: String, line: int) -> bool:
	var ei := editor_interface()
	if ei == null:
		return false
	if str(node_path).strip_edges() == "":
		return false
	var root: Variant = null
	if (ei as Object).has_method("get_edited_scene_root"):
		root = (ei as Object).call("get_edited_scene_root")
	if not (root is Node) or not is_instance_valid(root):
		return false
	var rn := str((root as Node).name)
	var rel := relative_node_path(node_path, rn)
	var target: Node = (root as Node) if rel == "." else (root as Node).get_node_or_null(rel)
	if target == null or not is_instance_valid(target):
		return false
	if not (target as Object).has_method("get_script"):
		return false
	var scr: Variant = (target as Object).call("get_script")
	if not (scr is Script):
		return false
	if not (ei as Object).has_method("edit_script"):
		return false
	(ei as Object).call("edit_script", scr)
	show_main_screen("Script")
	var se := script_editor()
	if se != null and line >= 1:
		goto_line(null, se, line)
	_assert_script_screen_soon(note_navigation(), line)
	return true


## Schedules a deferred re-assert of the Script workspace plus the
## caret line: scene opening switches to 2D/3D after (sometimes well
## after) the synchronous call returns, burying an immediate
## show_main_screen("Script"). After three process frames the switch
## has settled, so the deferred pass wins the race. Generation-guarded
## (a newer navigation cancels the stale assert) and fully
## null-safe: headless (no tree) it schedules nothing.
static func _assert_script_screen_soon(gen: int, line: int) -> void:
	var se := script_editor()
	if se == null or not (se is Node):
		return
	var tree: SceneTree = (se as Node).get_tree()
	if tree == null:
		return
	tree.process_frame.connect(func() -> void: _deferred_script_focus(3, gen, line), CONNECT_ONE_SHOT)


## Deferred tail of _assert_script_screen_soon: counts frames down,
## then re-shows the Script workspace and re-moves the caret, unless
## a newer navigation arrived (gen mismatch) or the editor went away.
## Never fails.
static func _deferred_script_focus(frames_left: int, gen: int, line: int) -> void:
	if gen != _focus_gen:
		return
	var se := script_editor()
	if se == null or not (se is Node):
		return
	var tree: SceneTree = (se as Node).get_tree()
	if tree == null:
		return
	if frames_left > 1:
		tree.process_frame.connect(func() -> void: _deferred_script_focus(frames_left - 1, gen, line), CONNECT_ONE_SHOT)
		return
	show_main_screen("Script")
	if line >= 1:
		goto_line(null, se, line)


## Opens an embedded-script issue: the scene, then the node focus,
## then the node script at the embedded line. Best-effort chain where
## every step is null-guarded: a failed node focus still tries the
## script open, and anything failing returns false headless-style.
## `scene`/`node`/`line` come from the issue dict extras.
static func open_embedded_issue(scene: String, node: String, line: int) -> bool:
	if str(scene).strip_edges() == "":
		return false
	if not open_scene(scene):
		return false
	if str(node).strip_edges() != "":
		focus_scene_node(node)
		if open_node_script(node, line):
			return true
	return false
