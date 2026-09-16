class_name gnumarus_gdscript_semantic_parser
extends RefCounted

## Semantic analyzer for GDScript abstract syntax trees.
##
## Walks the AST produced by gnumarus_gdscript_syntatic_parser and checks
## semantic errors: unknown types, static versus instance misuse, missing
## methods (including ancestors), invalid operators, wrong argument
## counts, assignments to constants, unknown identifiers and bad
## assignments/returns. This stage is purely semantic: the syntactic
## parser already accepted everything, e.g. `var myvar: int = null`
## parses fine but is flagged here because int is not nullable.
##
## The analysis is fault tolerant: every error becomes an entry in the
## returned "semantic_errors" list and checking continues wherever
## viable. Nodes the analyzer cannot understand are skipped, never fatal.
##
## Type information comes from JSON files. Unknown type names are looked
## up first in types_info/builtin/<Name>.json, then in
## types_info/user/<Name>.json. Missing files mean
## "unknown type '<Name>'". Loaded files are cached per analyze() call.
##
## After checking, and before returning the modified AST, user type files
## are created or updated under types_info/user/: one per script
## class_name (or resource-path based name for class_name-less scripts)
## plus one per inner class, named by concatenating the class names
## needed to reach it (e.g. minha.classe.interna.json). Each file holds
## enums, constants, signals, fields, static and instance functions and
## every other publicly accessible member found in the script.
##
## Usage:
##   var syn := gnumarus_gdscript_syntatic_parser.new()
##   var sem := gnumarus_gdscript_semantic_parser.new()
##   var ast: Dictionary = sem.analyze(syn.parse("res://script.gd"), "res://script.gd")
##   print(ast["semantic_errors"], ast["user_types_written"])

const KIND_UNKNOWN_TYPE := "unknown_type"
const KIND_STATIC_ACCESS := "static_access"
const KIND_MISSING_METHOD := "missing_method"
const KIND_OPERATOR := "operator"
const KIND_ARITY := "arity"
const KIND_CONST_ASSIGN := "const_assign"
const KIND_UNDECLARED := "undeclared"
const KIND_ASSIGN := "assign"

const SIGNAL_METHODS := ["connect", "disconnect", "is_connected", "emit", "get_connections"]
const NODE_SIGNALS := ["ready", "renamed", "tree_entered", "tree_entering", "tree_exited", "tree_exiting", "replacing_by"]
const NUMERIC_TYPES := ["int", "float"]
const ASSIGN_OPS := ["=", ":="]
const AUGMENTED_OPS := ["+=", "-=", "*=", "/=", "%=", "**=", "<<=", ">>=", "&=", "|=", "^="]
const COMPARE_OPS := ["==", "!=", "<", "<=", ">", ">="]
const LOGIC_OPS := ["and", "or", "&&", "||"]
const BINARY_ARITH_OPS := ["+", "-", "*", "/", "%", "**", "<<", ">>", "&", "|", "^"]

## Engine singletons: `Name.anything` is always accepted without checks.
const SINGLETONS := ["Performance", "Engine", "ProjectSettings", "OS", "Time", "ClassDB", "TextServerManager", "NavigationServer2DManager", "PhysicsServer2DManager", "NavigationServer3DManager", "PhysicsServer3DManager", "NavigationMeshGenerator", "IP", "Geometry2D", "Geometry3D", "ResourceLoader", "ResourceSaver", "Marshalls", "TranslationServer", "Input", "InputMap", "EngineDebugger", "GDExtensionManager", "ResourceUID", "WorkerThreadPool", "ThemeDB", "EditorInterface", "GDScriptLanguageProtocol", "JavaClassWrapper", "JavaScriptBridge", "AccessibilityServer", "AudioServer", "CameraServer", "DisplayServer", "NativeMenu", "RenderingServer", "NavigationServer2D", "NavigationServer3D", "PhysicsServer2D", "PhysicsServer3D", "XRServer"]

## Global utility functions (@GDScript / @GlobalScope): calls are trusted.
const GLOBAL_FUNCS := ["print", "prints", "printt", "printerr", "print_debug", "print_stack", "push_error", "push_warning", "len", "range", "load", "load_threaded_request", "str", "int", "float", "bool", "typeof", "type_exists", "convert", "char", "ord", "Color8", "is_instance_of", "is_instance_valid", "is_same", "is_equal_approx", "is_zero_approx", "is_nan", "is_inf", "move_toward", "rotate_toward", "lerp", "lerpf", "lerp_angle", "clamp", "clampi", "clampf", "min", "mini", "minf", "max", "maxi", "maxf", "abs", "absi", "absf", "floor", "floori", "ceil", "ceili", "round", "roundi", "sign", "signf", "snapped", "snappedf", "sqrt", "pow", "exp", "log", "sin", "cos", "tan", "asin", "acos", "atan", "atan2", "deg_to_rad", "rad_to_deg", "fmod", "fposmod", "posmod", "randf", "randi", "randf_range", "randi_range", "randfn", "seed", "srand", "str_to_var", "var_to_str", "bytes_to_var", "var_to_bytes", "weakref", "get_stack", "dict_to_inst", "inst_to_dict", "ease", "step_decimals", "is_equal_approx", "move_toward", "load_threaded_get", "load_threaded_get_status"]

## Language keywords: never identifiers.
const KEYWORDS := ["if", "elif", "else", "for", "while", "match", "when", "break", "continue", "pass", "return", "class", "class_name", "extends", "is", "in", "as", "self", "super", "signal", "func", "static", "const", "enum", "var", "breakpoint", "preload", "await", "assert", "void", "and", "or", "not", "true", "false", "null"]

## Known global return types for a few conversion helpers.
const GLOBAL_RETURNS := {"str": "String", "int": "int", "float": "float", "bool": "bool", "typeof": "int", "len": "int", "load": "Resource"}

var _errors: Array = []
var _type_cache: Dictionary = {}
var _type_miss: Dictionary = {}
var _bases: Array = []
var _write_base: String = "types_info"
var _project_root: String = ""
var _script_resource_path: String = ""
var _script_class: String = ""
var _script_extends: String = ""
var _script_types: Dictionary = {}
var _script_scope: Dictionary = {}
var _script_infos: Dictionary = {}
var _written: Array = []


## Analyzes an AST in place and returns it with "semantic_errors" and
## "user_types_written" added. script_path should be the res:// path of
## the analyzed script (used for user file naming when there is no
## class_name); an absolute path under the project also works.
func analyze(ast: Dictionary, script_path: String = "") -> Dictionary:
	_errors = []
	_type_cache = {}
	_type_miss = {}
	_written = []
	_script_types = {}
	var anchor = _dumper_anchor_dir()
	_project_root = find_project_root(anchor)
	if _project_root == "":
		_project_root = fallback_root(anchor + "/gnumaru_godot_native_types_info_dumper.gd")
	_script_resource_path = resource_path_for(script_path, _project_root)
	_bases = _compute_bases(_project_root)
	_write_base = _compute_write_base(_project_root)
	_script_scope = _new_scope(null)
	_script_infos = {}
	_collect_script(ast)
	_check_script_bodies(ast)
	_write_user_types(ast)
	ast["semantic_errors"] = _errors
	ast["user_types_written"] = _written
	return ast


## Directory holding the dumper script (res:// form preferred), used as
## the anchor to discover the project root.
func _dumper_anchor_dir() -> String:
	var self_path = get_script().resource_path
	var self_dir = self_path.get_base_dir()
	if self_dir == "":
		self_dir = "res://"
	if FileAccess.file_exists(self_dir + "/gnumaru_godot_native_types_info_dumper.gd"):
		return self_dir
	if self_path.begins_with("res://") and FileAccess.file_exists("res://gnumaru_godot_native_types_info_dumper.gd"):
		return "res://"
	return self_dir


## Walks start_dir upward until project.godot or .godot is found.
## Returns "" when nothing is found (caller applies fallback_root).
static func find_project_root(start_dir: String) -> String:
	var dir = start_dir
	if dir == "":
		return ""
	var guard = 0
	while guard < 64:
		guard += 1
		if FileAccess.file_exists(dir + "/project.godot"):
			return dir
		var probe = DirAccess.open(dir)
		if probe != null and probe.dir_exists(".godot"):
			return dir
		if dir == "res://" or dir == "res:/" or dir == "" or dir == "/" or dir == ".":
			break
		var parent = dir.get_base_dir()
		if parent == dir:
			break
		dir = parent
	return ""


## Last resort project root: grandparent directory (../../) of the
## dumper script file, clamped to res:// when it makes no sense.
static func fallback_root(dumper_file: String) -> String:
	var d = dumper_file.get_base_dir().get_base_dir()
	if d == "" or d == "." or d == "res:/":
		return "res://"
	return d


## Normalizes the analyzed script path to res:// form when possible.
static func resource_path_for(script_path: String, project_root: String) -> String:
	if script_path.begins_with("res://"):
		return script_path
	if script_path == "":
		return ""
	var abs_root = project_root
	if abs_root.begins_with("res://"):
		abs_root = ProjectSettings.globalize_path(abs_root)
	abs_root = _rstrip_slash(abs_root)
	if abs_root != "" and script_path.begins_with(abs_root + "/"):
		return "res://" + script_path.trim_prefix(abs_root + "/")
	return ""


## File base name for user type files: the class_name, or the resource
## path without res:// and .gd with slashes as underscores
## (res://a/b.gd becomes a_b). Falls back to the plain file name.
static func user_file_base(cls_name: String, resource_path: String, script_path: String) -> String:
	if cls_name != "":
		return cls_name
	var rp = resource_path
	if rp == "" and script_path != "":
		if script_path.begins_with("res://"):
			rp = script_path
		else:
			rp = script_path.get_file()
	rp = rp.trim_prefix("res://")
	if rp.ends_with(".gd"):
		rp = rp.substr(0, rp.length() - 3)
	rp = rp.replace("/", "_").replace("\\", "_")
	if rp == "":
		rp = "anonymous"
	return rp


static func _rstrip_slash(p: String) -> String:
	if p.ends_with("/") and p.length() > 1:
		return p.substr(0, p.length() - 1)
	return p


func _compute_bases(root: String) -> Array:
	var bases: Array = []
	if root != "":
		var r = _rstrip_slash(root)
		bases.append(r + "/types_info")
		if r.begins_with("res://"):
			var g = _rstrip_slash(ProjectSettings.globalize_path(r))
			if g != r:
				bases.append(g + "/types_info")
	bases.append("types_info")
	bases.append("res://types_info")
	var seen = {}
	var out: Array = []
	for b in bases:
		if not seen.has(b):
			seen[b] = true
			out.append(b)
	return out


func _compute_write_base(root: String) -> String:
	if root != "":
		return _rstrip_slash(root) + "/types_info"
	return "types_info"


# ---------------------------------------------------------------- scope

func _new_scope(parent: Variant) -> Dictionary:
	return {"names": {}, "parent": parent}


func _scope_add(scope: Dictionary, name: String, kind: String, type_name: String = "", node: Dictionary = {}) -> void:
	var entry = {"kind": kind, "type": type_name}
	if not node.is_empty():
		entry["node"] = node
	(scope["names"] as Dictionary)[name] = entry


func _scope_get(scope: Variant, name: String) -> Dictionary:
	var cur: Variant = scope
	while cur is Dictionary:
		var names: Dictionary = (cur as Dictionary).get("names", {})
		if names.has(name):
			return names[name]
		cur = (cur as Dictionary).get("parent", null)
	return {}


func _is_all_caps(name: String) -> bool:
	if name.length() == 0:
		return false
	var first = name.unicode_at(0)
	if first < 65 or first > 90:
		return false
	for i in range(1, name.length()):
		var c = name.unicode_at(i)
		if not ((c >= 65 and c <= 90) or (c >= 48 and c <= 57) or c == 95):
			return false
	return true


# ------------------------------------------------------- script collect

func _collect_script(ast: Dictionary) -> void:
	_script_class = ""
	_script_extends = ""
	for child in ast.get("children", []):
		if not (child is Dictionary):
			continue
		var t = str((child as Dictionary).get("type", ""))
		if t == "CLASS_NAME":
			_script_class = str((child as Dictionary).get("name", ""))
		elif t == "EXTENDS":
			_script_extends = _dotted_name((child as Dictionary).get("path", []))
	for child in ast.get("children", []):
		_register_top(child)
	if _script_class != "":
		_script_types[_script_class] = {"kind": "class", "full": _script_class}
	_build_script_infos(ast)


## Builds method tables for the script itself and every inner class so
## method checks work on user types (with parent walking).
func _build_script_infos(ast: Dictionary) -> void:
	_script_infos = {}
	var root_parent = _script_extends
	if root_parent == "":
		root_parent = "RefCounted"
	_script_infos[""] = {"methods": {}, "parent": root_parent, "full": _script_class}
	if _script_class != "":
		_script_infos[_script_class] = _script_infos[""]
	for child in ast.get("children", []):
		if child is Dictionary:
			_collect_methods(child, _script_infos[""], "")
			if str((child as Dictionary).get("type", "")) == "CLASS_DECL":
				_build_inner_info(child, "")


func _collect_methods(node: Dictionary, info: Dictionary, _prefix: String) -> void:
	var t = str(node.get("type", ""))
	if t == "FUNC_DECL":
		(info["methods"] as Dictionary)[str(node.get("name", ""))] = _script_method_entry(node)
	elif t == "VAR_DECL" or t == "CONST_DECL" or t == "SIGNAL_DECL" or t == "ENUM_DECL" or t == "CLASS_DECL":
		return
	elif t == "BLOCK":
		for child in node.get("children", []):
			if child is Dictionary:
				_collect_methods(child, info, _prefix)


func _script_method_entry(node: Dictionary) -> Dictionary:
	var params: Array = []
	for p in node.get("params", []):
		if p is Dictionary:
			params.append({"name": str((p as Dictionary).get("name", "")), "type": _param_type_of(p), "has_default": (p as Dictionary).get("default", null) != null, "default": null})
	var rt = _type_text(node.get("return_type", null))
	if rt == "":
		rt = "void"
	return {"name": str(node.get("name", "")), "returns": rt, "is_vararg": false, "params": params, "static": bool(node.get("is_static", false))}


func _build_inner_info(node: Dictionary, prefix: String) -> void:
	var iname = str(node.get("name", ""))
	if iname == "":
		return
	var full = iname
	if prefix != "":
		full = prefix + "." + iname
	elif _script_class != "":
		full = _script_class + "." + iname
	var parent = _type_text(node.get("extends_type", null))
	if parent == "":
		var body: Variant = node.get("body", null)
		if body is Dictionary:
			for child in (body as Dictionary).get("children", []):
				if child is Dictionary and str((child as Dictionary).get("type", "")) == "EXTENDS":
					parent = _dotted_name((child as Dictionary).get("path", []))
					break
	if parent == "":
		parent = "RefCounted"
	var info = {"methods": {}, "parent": parent, "full": full}
	_script_infos[iname] = info
	_script_infos[full] = info
	var body2: Variant = node.get("body", null)
	if body2 is Dictionary:
		for child in (body2 as Dictionary).get("children", []):
			if child is Dictionary:
				_collect_methods(child, info, full)
				if str((child as Dictionary).get("type", "")) == "CLASS_DECL":
					_build_inner_info(child, full)


func _script_info_for(type_name: String) -> Dictionary:
	if _script_infos.has(type_name):
		return _script_infos[type_name]
	if "." in type_name:
		var short = type_name.substr(type_name.rfind(".") + 1)
		if _script_infos.has(short):
			return _script_infos[short]
	return {}


func _register_top(node: Dictionary) -> void:
	var t = str(node.get("type", ""))
	if t == "VAR_DECL":
		_scope_add(_script_scope, str(node.get("name", "")), "member", _effective_type_of(node, _script_scope, _self_type()))
	elif t == "CONST_DECL":
		_scope_add(_script_scope, str(node.get("name", "")), "const", _effective_type_of(node, _script_scope, _self_type()))
	elif t == "FUNC_DECL":
		_scope_add(_script_scope, str(node.get("name", "")), "func", "", node)
	elif t == "SIGNAL_DECL":
		_scope_add(_script_scope, str(node.get("name", "")), "signal", "")
	elif t == "ENUM_DECL":
		var ename = str(node.get("name", ""))
		if ename != "":
			_script_types[ename] = {"kind": "enum"}
			_scope_add(_script_scope, ename, "enum", ename)
		for m in node.get("members", []):
			if m is Dictionary and str((m as Dictionary).get("type", "")) == "ENUM_MEMBER":
				_scope_add(_script_scope, str((m as Dictionary).get("name", "")), "const", ename)
	elif t == "CLASS_DECL":
		_register_inner(node, "")
	elif t == "SYNTAX_ERROR":
		return


func _register_inner(node: Dictionary, prefix: String) -> void:
	var iname = str(node.get("name", ""))
	if iname == "":
		return
	var root_name = _script_class
	if root_name == "":
		root_name = user_file_base("", _script_resource_path, "")
	var full = iname
	if prefix != "":
		full = prefix + "." + iname
	elif root_name != "":
		full = root_name + "." + iname
	_script_types[iname] = {"kind": "class", "full": full}
	_script_types[full] = {"kind": "class", "full": full}
	_scope_add(_script_scope, iname, "class", full)
	_scope_add(_script_scope, full, "class", full)
	var body: Variant = node.get("body", null)
	if body is Dictionary:
		for child in (body as Dictionary).get("children", []):
			if not (child is Dictionary):
				continue
			var c: Dictionary = child
			var ct = str(c.get("type", ""))
			if ct == "ENUM_DECL":
				var ename = str(c.get("name", ""))
				if ename != "":
					var efull = full + "." + ename
					_script_types[ename] = {"kind": "enum"}
					_script_types[efull] = {"kind": "enum"}
			elif ct == "CLASS_DECL":
				_register_inner(c, full)


func _collect_bindings(node: Variant, scope: Dictionary) -> void:
	if node is Array:
		for e in node:
			_collect_bindings(e, scope)
		return
	if not (node is Dictionary):
		return
	var d: Dictionary = node
	var t = str(d.get("type", ""))
	if t == "VAR_DECL" or t == "CONST_DECL":
		var kind = "var"
		if t == "CONST_DECL":
			kind = "const"
		_scope_add(scope, str(d.get("name", "")), kind, _declared_type_of(d))
	elif t == "PARAM":
		_scope_add(scope, str(d.get("name", "")), "param", _param_type_of(d))
	elif t == "FOR_STMT":
		var target: Variant = d.get("target", null)
		if target is Dictionary:
			_scope_add(scope, str((target as Dictionary).get("value", "")), "loop", _infer_for_target(d))
	elif t == "PATTERN":
		_collect_pattern_bindings(d, scope)
	elif t == "LAMBDA":
		for p in d.get("params", []):
			if p is Dictionary:
				_scope_add(scope, str((p as Dictionary).get("name", "")), "param", _param_type_of(p))
		return
	elif t == "CLASS_DECL":
		return
	for k in d.keys():
		if k in ["tokens", "args", "annotations", "leading_comments"]:
			continue
		_collect_bindings(d[k], scope)


func _collect_pattern_bindings(pattern: Dictionary, scope: Dictionary) -> void:
	var toks: Array = pattern.get("tokens", [])
	var i = 0
	while i < toks.size():
		var tk: Dictionary = toks[i]
		if str(tk.get("type", "")) == "KEYWORD" and str(tk.get("value", "")) == "var" and i + 1 < toks.size() and str((toks[i + 1] as Dictionary).get("type", "")) == "IDENTIFIER":
			_scope_add(scope, str((toks[i + 1] as Dictionary).get("value", "")), "bind", "")
			i += 2
			continue
		i += 1


func _infer_for_target(for_node: Dictionary) -> String:
	var iter: Variant = for_node.get("iter", null)
	if iter is Dictionary and str((iter as Dictionary).get("type", "")) == "EXPR":
		var toks: Array = (iter as Dictionary).get("tokens", [])
		if toks.size() == 1 and str((toks[0] as Dictionary).get("type", "")) == "INT":
			return "int"
	return ""


# ------------------------------------------------------------- checking

func _check_script_bodies(ast: Dictionary) -> void:
	for child in ast.get("children", []):
		if child is Dictionary:
			_check_top_node(child, _script_scope, _self_type())


func _self_type() -> String:
	if _script_class != "":
		return _script_class
	if _script_extends != "":
		return _script_extends
	return ""


func _check_top_node(node: Dictionary, scope: Dictionary, self_type: String) -> void:
	var t = str(node.get("type", ""))
	if t == "VAR_DECL" or t == "CONST_DECL":
		_check_decl(node, scope, self_type)
	elif t == "FUNC_DECL":
		_check_func(node, scope, self_type)
	elif t == "CLASS_DECL":
		_check_inner_class(node, scope)
	elif t == "SIGNAL_DECL":
		_check_signal(node)
	elif t == "ENUM_DECL":
		for m in node.get("members", []):
			if m is Dictionary and (m as Dictionary).get("value", null) != null:
				_check_expr_tokens(_expr_like_tokens((m as Dictionary).get("value", null)), scope, self_type)
	elif t == "BLOCK":
		_walk_block(node, scope, self_type)
	elif t == "EXPR_STMT":
		_check_expr_stmt(node, scope, self_type)
	elif t == "IF_STMT" or t == "FOR_STMT" or t == "WHILE_STMT" or t == "MATCH_STMT":
		_walk_block({"type": "BLOCK", "children": [node], "line": node.get("line", 0), "column": 0}, scope, self_type)


func _check_inner_class(node: Dictionary, outer_scope: Dictionary) -> void:
	var scope = _new_scope(outer_scope)
	var body: Variant = node.get("body", null)
	if not (body is Dictionary):
		return
	for child in (body as Dictionary).get("children", []):
		if child is Dictionary:
			_register_member(child, scope)
	_walk_block(body, scope, str(node.get("name", "")))


func _register_member(node: Dictionary, scope: Dictionary) -> void:
	var t = str(node.get("type", ""))
	if t == "VAR_DECL":
		_scope_add(scope, str(node.get("name", "")), "member", _effective_type_of(node, scope, ""))
	elif t == "CONST_DECL":
		_scope_add(scope, str(node.get("name", "")), "const", _effective_type_of(node, scope, ""))
	elif t == "FUNC_DECL":
		_scope_add(scope, str(node.get("name", "")), "func", "", node)
	elif t == "SIGNAL_DECL":
		_scope_add(scope, str(node.get("name", "")), "signal", "")
	elif t == "ENUM_DECL":
		var ename = str(node.get("name", ""))
		if ename != "":
			_scope_add(scope, ename, "enum", ename)
		for m in node.get("members", []):
			if m is Dictionary and str((m as Dictionary).get("type", "")) == "ENUM_MEMBER":
				_scope_add(scope, str((m as Dictionary).get("name", "")), "const", ename)


func _check_decl(node: Dictionary, scope: Dictionary, self_type: String) -> void:
	var is_const := str(node.get("type", "")) == "CONST_DECL"
	var vt: Variant = node.get("vartype", null)
	if vt is Dictionary:
		_check_type_ref(vt)
	var value: Variant = node.get("value", null)
	var vkind = ""
	if value is Dictionary:
		vkind = str((value as Dictionary).get("type", ""))
	if vkind == "LAMBDA":
		_check_lambda(value, scope, self_type)
	elif value != null:
		_check_expr_tokens(_expr_like_tokens(value), scope, self_type)
	var declared = _declared_type_of(node)
	if declared != "" and value != null and vkind != "LAMBDA":
		var inferred = _infer_tokens(_expr_like_tokens(value), scope, self_type)
		_check_assignable(declared, inferred, int(node.get("line", 0)), int(node.get("column", 0)))
	var accessors: Variant = node.get("accessors", null)
	if accessors is Dictionary:
		_walk_block(accessors, scope, self_type)


func _check_func(node: Dictionary, scope: Dictionary, self_type: String) -> void:
	for p in node.get("params", []):
		if p is Dictionary:
			var pt: Variant = (p as Dictionary).get("vartype", null)
			if pt is Dictionary:
				_check_type_ref(pt)
			var def: Variant = (p as Dictionary).get("default", null)
			if def != null:
				_check_expr_tokens(_expr_like_tokens(def), scope, self_type)
	var rt: Variant = node.get("return_type", null)
	if rt is Dictionary:
		_check_type_ref(rt)
	var body: Variant = node.get("body", null)
	if not (body is Dictionary):
		return
	var fscope = _new_scope(scope)
	for p in node.get("params", []):
		if p is Dictionary:
			_scope_add(fscope, str((p as Dictionary).get("name", "")), "param", _param_type_of(p))
	_collect_bindings(body, fscope)
	_walk_block(body, fscope, self_type)


func _check_signal(node: Dictionary) -> void:
	for p in node.get("params", []):
		if p is Dictionary:
			var pt: Variant = (p as Dictionary).get("vartype", null)
			if pt is Dictionary:
				_check_type_ref(pt)


func _check_lambda(node: Dictionary, scope: Dictionary, self_type: String) -> void:
	var lscope = _new_scope(scope)
	for p in node.get("params", []):
		if p is Dictionary:
			_scope_add(lscope, str((p as Dictionary).get("name", "")), "param", _param_type_of(p))
			var pt: Variant = (p as Dictionary).get("vartype", null)
			if pt is Dictionary:
				_check_type_ref(pt)
	var rt: Variant = node.get("return_type", null)
	if rt is Dictionary:
		_check_type_ref(rt)
	var body: Variant = node.get("body", null)
	var declared = ""
	if rt is Dictionary:
		declared = _type_text(rt)
	if body is Dictionary:
		_collect_bindings(body, lscope)
		_walk_block(body, lscope, self_type)
		if declared != "" and declared != "void":
			for ret in _collect_nodes(body, "RETURN_STMT"):
				var rv: Variant = (ret as Dictionary).get("value", null)
				if rv != null:
					_check_assignable(declared, _infer_tokens(_expr_like_tokens(rv), lscope, self_type), int((ret as Dictionary).get("line", 0)), int((ret as Dictionary).get("column", 0)))


func _walk_block(block: Variant, scope: Dictionary, self_type: String) -> void:
	if not (block is Dictionary):
		return
	for child in (block as Dictionary).get("children", []):
		if not (child is Dictionary):
			continue
		_walk_stmt(child, scope, self_type)


func _walk_stmt(node: Dictionary, scope: Dictionary, self_type: String) -> void:
	var t = str(node.get("type", ""))
	if t == "VAR_DECL" or t == "CONST_DECL":
		var kind = "var"
		if t == "CONST_DECL":
			kind = "const"
		_scope_add(scope, str(node.get("name", "")), kind, _effective_type_of(node, scope, self_type))
		_check_decl(node, scope, self_type)
	elif t == "FUNC_DECL":
		_scope_add(scope, str(node.get("name", "")), "func", "", node)
		_check_func(node, scope, self_type)
	elif t == "CLASS_DECL":
		_scope_add(scope, str(node.get("name", "")), "class", "")
		_check_inner_class(node, scope)
	elif t == "SIGNAL_DECL":
		_scope_add(scope, str(node.get("name", "")), "signal", "")
		_check_signal(node)
	elif t == "ENUM_DECL":
		_register_member(node, scope)
	elif t == "IF_STMT":
		_check_expr_tokens(_expr_like_tokens(node.get("condition", null)), scope, self_type)
		_walk_block(node.get("then", null), scope, self_type)
		for e in node.get("elifs", []):
			if e is Dictionary:
				_check_expr_tokens(_expr_like_tokens((e as Dictionary).get("condition", null)), scope, self_type)
				_walk_block((e as Dictionary).get("body", null), scope, self_type)
		if node.get("else_body", null) is Dictionary:
			_walk_block(node.get("else_body", null), scope, self_type)
	elif t == "FOR_STMT":
		_check_expr_tokens(_expr_like_tokens(node.get("iter", null)), scope, self_type)
		var target: Variant = node.get("target", null)
		if target is Dictionary:
			_scope_add(scope, str((target as Dictionary).get("value", "")), "loop", _infer_for_target(node))
		_walk_block(node.get("body", null), scope, self_type)
	elif t == "WHILE_STMT":
		_check_expr_tokens(_expr_like_tokens(node.get("condition", null)), scope, self_type)
		_walk_block(node.get("body", null), scope, self_type)
	elif t == "MATCH_STMT":
		_check_expr_tokens(_expr_like_tokens(node.get("subject", null)), scope, self_type)
		for b in node.get("branches", []):
			if b is Dictionary and str((b as Dictionary).get("type", "")) == "MATCH_BRANCH":
				_check_expr_tokens(_pattern_tokens((b as Dictionary).get("pattern", null)), scope, self_type)
				_walk_block((b as Dictionary).get("body", null), scope, self_type)
	elif t == "RETURN_STMT":
		var rv: Variant = node.get("value", null)
		if rv == null:
			return
		_check_expr_tokens(_expr_like_tokens(rv), scope, self_type)
	elif t == "ASSERT_STMT":
		_check_expr_tokens(_raw_tokens(node.get("args", [])), scope, self_type)
	elif t == "EXPR_STMT":
		_check_expr_stmt(node, scope, self_type)
	elif t == "ACCESSOR":
		var ascope = _new_scope(scope)
		for p in node.get("params", []):
			if p is Dictionary:
				_scope_add(ascope, str((p as Dictionary).get("name", "")), "param", _param_type_of(p))
		var detail: Variant = node.get("detail", null)
		if detail is Dictionary:
			if detail.has("tokens"):
				_check_expr_tokens(_expr_like_tokens(detail), ascope, self_type)
			if detail.has("alias_pair"):
				for pair in detail.get("alias_pair", []):
					if pair is Dictionary and (pair as Dictionary).has("expr"):
						_check_expr_tokens(_expr_like_tokens((pair as Dictionary).get("expr", null)), ascope, self_type)
		_walk_block(node.get("body", null), ascope, self_type)
	elif t == "BLOCK":
		_walk_block(node, scope, self_type)


func _check_expr_stmt(node: Dictionary, scope: Dictionary, self_type: String) -> void:
	var expr: Variant = node.get("expr", null)
	if expr is Dictionary and str((expr as Dictionary).get("type", "")) == "LAMBDA":
		_check_lambda(expr, scope, self_type)
		return
	_check_expr_tokens(_expr_like_tokens(expr), scope, self_type)


func _expr_like_tokens(v: Variant) -> Array:
	if v is Dictionary and (v as Dictionary).has("tokens"):
		var toks: Variant = (v as Dictionary).get("tokens", [])
		if toks is Array:
			return toks
	return []


func _raw_tokens(v: Variant) -> Array:
	var out: Array = []
	_flatten_tokens(v, out)
	return out


func _flatten_tokens(v: Variant, out: Array) -> void:
	if v is Array:
		for e in v:
			_flatten_tokens(e, out)
	elif v is Dictionary:
		if (v as Dictionary).has("type") and (v as Dictionary).has("value") and (v as Dictionary).has("line"):
			out.append(v)


func _pattern_tokens(v: Variant) -> Array:
	return _expr_like_tokens(v)


# ------------------------------------------------------- type references

func _type_text(v: Variant) -> String:
	if not (v is Dictionary):
		return ""
	var out = ""
	for t in (v as Dictionary).get("tokens", []):
		if t is Dictionary:
			out += str((t as Dictionary).get("value", ""))
	return out


func _base_type(text: String) -> String:
	var t = text.strip_edges()
	var cut = t.length()
	for i in range(t.length()):
		var c = t.unicode_at(i)
		if c == 91 or c == 46:
			cut = i
			break
	return t.substr(0, cut).strip_edges()


func _declared_type_of(decl: Dictionary) -> String:
	var vt: Variant = decl.get("vartype", null)
	if vt is Dictionary:
		var text = _type_text(vt)
		if text == "":
			return ""
		return text
	var value: Variant = decl.get("value", null)
	if value is Dictionary and str((value as Dictionary).get("type", "")) == "LAMBDA":
		return "Callable"
	return ""


## Declared type, falling back to value inference (literals,
## constructors, lambdas). Used for scope types and user files so that
## `var mixed := [...]` is known as Array. The strict declared-only
## form above stays in use for assignment compatibility.
func _effective_type_of(decl: Dictionary, scope: Dictionary, self_type: String) -> String:
	var vt: Variant = decl.get("vartype", null)
	if vt is Dictionary:
		var text = _type_text(vt)
		if text != "":
			return text
	var value: Variant = decl.get("value", null)
	if value is Dictionary and str((value as Dictionary).get("type", "")) == "LAMBDA":
		return "Callable"
	if value is Dictionary:
		return _infer_tokens(_expr_like_tokens(value), scope, self_type)
	return ""


func _param_type_of(p: Dictionary) -> String:
	var vt: Variant = p.get("vartype", null)
	if vt is Dictionary:
		return _type_text(vt)
	return ""


func _dotted_name(parts: Array) -> String:
	var out = ""
	for p in parts:
		if p is Dictionary and str((p as Dictionary).get("type", "")) != "DOT":
			out += str((p as Dictionary).get("value", ""))
	return out


## Checks every named type inside a TYPE_REF (base plus parameters).
func _check_type_ref(tref: Dictionary) -> void:
	for t in tref.get("tokens", []):
		if not (t is Dictionary):
			continue
		var ty = str((t as Dictionary).get("type", ""))
		if ty == "IDENTIFIER" or ty == "BUILTIN_TYPE":
			_resolve_type(str((t as Dictionary).get("value", "")), int((t as Dictionary).get("line", 0)), int((t as Dictionary).get("column", 0)))


## Resolves a type name: script types, then builtin files, then engine
## class files, then user files. Emits "unknown type '<Name>'" when
## everything misses. void is always accepted. Returns info or {}.
## NOTE: the request mentioned only builtin/ and user/, but engine
## classes (Node, FileAccess, ...) live in classes/ by dumper layout,
## so classes/ is searched between builtin/ and user/.
func _resolve_type(name: String, line: int, column: int) -> Dictionary:
	if name == "" or name == "void":
		return {"name": name}
	if _script_types.has(name):
		return {"name": name, "kind": "script"}
	if _type_cache.has(name):
		return _type_cache[name]
	if _type_miss.has(name):
		_error(KIND_UNKNOWN_TYPE, "unknown type '" + name + "'", line, column)
		return {}
	for base in _bases:
		var path = base + "/builtin/" + name + ".json"
		var info = _read_type_file(path)
		if not info.is_empty():
			_type_cache[name] = info
			return info
	for base in _bases:
		var cpath = base + "/classes/" + name + ".json"
		var cinfo = _read_type_file(cpath)
		if not cinfo.is_empty():
			_type_cache[name] = cinfo
			return cinfo
	for base in _bases:
		var path2 = base + "/user/" + name + ".json"
		var info2 = _read_type_file(path2)
		if not info2.is_empty():
			_type_cache[name] = info2
			return info2
	_type_miss[name] = true
	_error(KIND_UNKNOWN_TYPE, "unknown type '" + name + "'", line, column)
	return {}


func _read_type_file(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(parsed) != TYPE_DICTIONARY:
		return {}
	return parsed


func _is_enum_type(name: String) -> bool:
	if _script_types.has(name) and str((_script_types[name] as Dictionary).get("kind", "")) == "enum":
		return true
	return false


func _chain_of(info: Dictionary) -> Array:
	var c: Variant = info.get("inheritance_chain", [])
	if c is Array:
		return c
	var chain: Array = [str(info.get("name", ""))]
	var parent = str(info.get("parent", ""))
	if parent != "" and parent != str(info.get("name", "")):
		chain.append(parent)
	return chain


## Finds a method through the type and its ancestors. Script types use
## the collected tables, other types use loaded JSON files. Returns a
## Dictionary with entry/owner/static/chain or {} when missing.
func _find_method(type_name: String, method: String) -> Dictionary:
	var seen = {}
	var cur = type_name
	while cur != "" and not seen.has(cur):
		seen[cur] = true
		var sinfo = _script_info_for(cur)
		if not sinfo.is_empty():
			var methods: Dictionary = sinfo.get("methods", {})
			if methods.has(method):
				var entry: Dictionary = methods[method]
				return {"entry": entry, "owner": cur, "static": bool(entry.get("static", false)), "chain": _script_chain_names(cur)}
			cur = str(sinfo.get("parent", ""))
			if cur == "":
				cur = "RefCounted"
			continue
		var info = _resolve_type_quiet(cur)
		if info.is_empty():
			var base = _base_type(cur)
			if base != "" and base != cur:
				cur = base
				continue
			return {}
		for m in info.get("static_methods", []):
			if m is Dictionary and str((m as Dictionary).get("name", "")) == method:
				return {"entry": m, "owner": cur, "static": true, "chain": _chain_of(info)}
		for m in info.get("instance_methods", []):
			if m is Dictionary and str((m as Dictionary).get("name", "")) == method:
				return {"entry": m, "owner": cur, "static": false, "chain": _chain_of(info)}
		var next = str(info.get("parent", ""))
		if next == "" or next == cur:
			if cur != "Variant" and not seen.has("Variant"):
				cur = "Variant"
				continue
			break
		cur = next
	return {}


func _script_chain_names(type_name: String) -> Array:
	var chain: Array = [type_name]
	var seen = {type_name: true}
	var cur = type_name
	var guard = 0
	while guard < 32:
		guard += 1
		var sinfo = _script_info_for(cur)
		var parent = ""
		if not sinfo.is_empty():
			parent = str(sinfo.get("parent", ""))
		else:
			var info = _resolve_type_quiet(cur)
			if info.is_empty():
				break
			parent = str(info.get("parent", ""))
		if parent == "" or seen.has(parent):
			break
		chain.append(parent)
		seen[parent] = true
		cur = parent
	if not (chain[chain.size() - 1] == "Variant"):
		chain.append("Variant")
	return chain


## Quiet resolution (no error emitted): script types, cache, builtin,
## classes and user files, in that order.
func _resolve_type_quiet(name: String) -> Dictionary:
	if name == "" or name == "void":
		return {"name": name}
	if _script_types.has(name):
		return {"name": name, "kind": "script"}
	if _type_cache.has(name):
		return _type_cache[name]
	if _type_miss.has(name):
		return {}
	for base in _bases:
		var info = _read_type_file(base + "/builtin/" + name + ".json")
		if not info.is_empty():
			_type_cache[name] = info
			return info
	for base in _bases:
		var cinfo = _read_type_file(base + "/classes/" + name + ".json")
		if not cinfo.is_empty():
			_type_cache[name] = cinfo
			return cinfo
	for base in _bases:
		var info2 = _read_type_file(base + "/user/" + name + ".json")
		if not info2.is_empty():
			_type_cache[name] = info2
			return info2
	_type_miss[name] = true
	return {}


# ------------------------------------------------------- error reporting

func _error(kind: String, message: String, line: int, column: int) -> void:
	_errors.append({"kind": kind, "message": message, "line": line, "column": column})


# ------------------------------------------------------- expression walk

## Main expression checker over raw token arrays.
func _check_expr_tokens(tokens: Array, scope: Dictionary, self_type: String) -> void:
	var lambda_extra = {}
	_check_range(tokens, 0, tokens.size(), scope, self_type, lambda_extra, 0)


func _check_range(tokens: Array, start: int, end: int, scope: Dictionary, self_type: String, lambda_extra: Dictionary, depth: int) -> void:
	var i = start
	while i < end and i < tokens.size():
		var t: Dictionary = tokens[i]
		var ty = str(t.get("type", ""))
		var v = str(t.get("value", ""))
		if ty == "LAMBDA_MARKER":
			if (t.get("value", null)) is Dictionary:
				_check_lambda(t.get("value", {}), scope, self_type)
			i += 1
			continue
		if ty == "KEYWORD":
			if v == "func":
				i = _absorb_lambda_params(tokens, i, lambda_extra)
				continue
			if v == "super":
				i = _skip_dotted_call(tokens, i)
				continue
			if v == "is" or v == "as":
				_check_cast_target(tokens, i, v)
				i += 1
				continue
			i += 1
			continue
		if ty == "OPERATOR":
			if (v == "=" or v == ":=") and depth == 0:
				_check_assignment(tokens, i, scope, self_type, lambda_extra)
			elif v in AUGMENTED_OPS and depth == 0:
				_check_augmented(tokens, i, scope, self_type, lambda_extra)
			elif not (v in ASSIGN_OPS):
				_check_binary_op(tokens, i, scope, self_type)
			i += 1
			continue
		if ty == "IDENTIFIER":
			var nxt = ""
			var nxt_ty = ""
			if i + 1 < end and i + 1 < tokens.size():
				nxt_ty = str((tokens[i + 1] as Dictionary).get("type", ""))
				nxt = str((tokens[i + 1] as Dictionary).get("value", ""))
			if nxt_ty == "DOT":
				i = _check_dot_chain(tokens, i, end, scope, self_type, lambda_extra)
				continue
			if nxt == "(" and nxt_ty == "LPAREN":
				_check_bare_call(tokens, i, scope, self_type, lambda_extra)
				i += 1
				continue
			_check_bare_name(t, scope, lambda_extra)
			i += 1
			continue
		if ty == "BUILTIN_TYPE":
			i += 1
			continue
		if ty == "DOT":
			var back = _infer_operand_back(tokens, i - 1, scope, self_type, lambda_extra)
			if str(back.get("type", "")) != "":
				i = _check_chain_from(tokens, i, end, scope, self_type, {"kind": "instance", "type": str(back.get("type", ""))})
			else:
				i = _skip_chain(tokens, i, end)
			continue
		if ty == "LPAREN" or ty == "LBRACKET" or ty == "LBRACE":
			depth += 1
			i += 1
			continue
		if ty == "RPAREN" or ty == "RBRACKET" or ty == "RBRACE":
			depth = maxi(0, depth - 1)
			i += 1
			continue
		i += 1


## Collects lambda parameter names after a raw `func` keyword into the
## overlay scope. Returns the index of the closing RPAREN (or close).
func _absorb_lambda_params(tokens: Array, at: int, lambda_extra: Dictionary) -> int:
	var i = at + 1
	if i >= tokens.size() or str((tokens[i] as Dictionary).get("type", "")) != "LPAREN":
		return at + 1
	var depth = 0
	i += 1
	while i < tokens.size():
		var ty = str((tokens[i] as Dictionary).get("type", ""))
		var v = str((tokens[i] as Dictionary).get("value", ""))
		if ty == "LPAREN":
			depth += 1
		elif ty == "RPAREN":
			if depth == 0:
				return i
			depth -= 1
		elif ty == "IDENTIFIER" and depth == 0:
			var prev_ty = ""
			var prev_v = ""
			if i - 1 >= 0:
				prev_ty = str((tokens[i - 1] as Dictionary).get("type", ""))
				prev_v = str((tokens[i - 1] as Dictionary).get("value", ""))
			var prev_is_name := prev_ty == "LPAREN" or prev_ty == "COMMA"
			if prev_ty == "":
				prev_is_name = true
			if prev_is_name and not (lambda_extra as Dictionary).has(v):
				(lambda_extra as Dictionary)[v] = true
		i += 1
	return i


## Skips `super`, `super.name` and `super.name(...)` entirely.
func _skip_dotted_call(tokens: Array, i: int) -> int:
	var j = i + 1
	while j < tokens.size():
		if str((tokens[j] as Dictionary).get("type", "")) != "DOT":
			break
		j += 1
		if j < tokens.size() and str((tokens[j] as Dictionary).get("type", "")) in ["IDENTIFIER", "BUILTIN_TYPE", "KEYWORD"]:
			j += 1
		if j < tokens.size() and str((tokens[j] as Dictionary).get("type", "")) == "LPAREN":
			j = _match_forward(tokens, j) + 1
	return j


## Validates an `is`/`as` target type name (dotted names allowed).
func _check_cast_target(tokens: Array, i: int, op: String) -> void:
	var j = i + 1
	if j < tokens.size() and str((tokens[j] as Dictionary).get("type", "")) == "KEYWORD" and str((tokens[j] as Dictionary).get("value", "")) == "not" and op == "is":
		j += 1
	var parts: Array = []
	while j < tokens.size():
		var ty = str((tokens[j] as Dictionary).get("type", ""))
		if ty == "IDENTIFIER" or ty == "BUILTIN_TYPE":
			parts.append(str((tokens[j] as Dictionary).get("value", "")))
			j += 1
		elif ty == "DOT":
			j += 1
		else:
			break
	if parts.is_empty():
		return
	_resolve_type(".".join(parts), int((tokens[i] as Dictionary).get("line", 0)), int((tokens[i] as Dictionary).get("column", 0)))


func _match_forward(tokens: Array, open_idx: int) -> int:
	var o = str((tokens[open_idx] as Dictionary).get("type", ""))
	var want = ""
	if o == "LPAREN":
		want = "RPAREN"
	elif o == "LBRACKET":
		want = "RBRACKET"
	elif o == "LBRACE":
		want = "RBRACE"
	else:
		return open_idx
	var depth = 0
	var i = open_idx
	while i < tokens.size():
		var ty = str((tokens[i] as Dictionary).get("type", ""))
		if ty == o:
			depth += 1
		elif ty == want:
			depth -= 1
			if depth == 0:
				return i
		i += 1
	return tokens.size() - 1


## Splits call arguments at top level. Returns an Array of token arrays.
func _split_args(tokens: Array, open_idx: int) -> Array:
	var close = _match_forward(tokens, open_idx)
	var args: Array = []
	var cur: Array = []
	var depth = 0
	var i = open_idx + 1
	while i < close:
		var ty = str((tokens[i] as Dictionary).get("type", ""))
		if ty == "LPAREN" or ty == "LBRACKET" or ty == "LBRACE":
			depth += 1
			cur.append(tokens[i])
		elif ty == "RPAREN" or ty == "RBRACKET" or ty == "RBRACE":
			depth -= 1
			cur.append(tokens[i])
		elif ty == "COMMA" and depth == 0:
			args.append(cur)
			cur = []
		else:
			cur.append(tokens[i])
		i += 1
	if cur.is_empty():
		if args.is_empty():
			return []
		args.append(cur)
		var last: Array = args[args.size() - 1]
		if last.is_empty():
			args.pop_back()
		return args
	args.append(cur)
	return args


func _check_bare_name(t: Dictionary, scope: Dictionary, overlay: Dictionary) -> void:
	var v = str(t.get("value", ""))
	if v == "" or v == "_":
		return
	if _scope_get(scope, v).has("kind"):
		return
	if (overlay as Dictionary).has(v):
		return
	if _script_types.has(v):
		return
	if v in SINGLETONS or v in GLOBAL_FUNCS or v in KEYWORDS or v in NODE_SIGNALS:
		return
	if _is_all_caps(v):
		return
	if _resolve_type_quiet(v).has("name"):
		return
	_error(KIND_UNDECLARED, "unknown identifier '" + v + "'", int(t.get("line", 0)), int(t.get("column", 0)))


## Handles `name(...)` calls without a dot: script funcs, self methods,
## globals and constructors pass; anything else is undeclared.
func _check_bare_call(tokens: Array, i: int, scope: Dictionary, self_type: String, overlay: Dictionary) -> void:
	var t: Dictionary = tokens[i]
	var v = str(t.get("value", ""))
	var entry = _scope_get(scope, v)
	if entry.has("kind"):
		if str(entry.get("kind", "")) == "func":
			var fnode: Variant = entry.get("node", {})
			var fparams: Array = []
			if fnode is Dictionary:
				for p in (fnode as Dictionary).get("params", []):
					if p is Dictionary:
						fparams.append({"has_default": (p as Dictionary).get("default", null) != null})
			_check_arity(v, fparams, tokens, i, int(t.get("line", 0)), int(t.get("column", 0)))
			return
		if str(entry.get("kind", "")) in ["var", "param", "member", "loop", "bind", "const"]:
			return
		return
	if (overlay as Dictionary).has(v):
		return
	if _script_types.has(v):
		return
	if v in SINGLETONS or v in GLOBAL_FUNCS or v in KEYWORDS:
		return
	if _is_all_caps(v):
		return
	var stype = self_type
	if stype != "":
		var found = _find_method(stype, v)
		if not found.is_empty():
			_check_arity(v, (found["entry"] as Dictionary).get("params", []), tokens, i, int(t.get("line", 0)), int(t.get("column", 0)), bool((found["entry"] as Dictionary).get("is_vararg", false)))
			return
	_error(KIND_UNDECLARED, "unknown identifier '" + v + "'", int(t.get("line", 0)), int(t.get("column", 0)))


## Handles `base.name(...)`, `base.name` and longer chains.
## Returns the index just past the consumed chain (args not consumed).
func _check_dot_chain(tokens: Array, i: int, end: int, scope: Dictionary, self_type: String, overlay: Dictionary) -> int:
	var base_info = _dot_base(tokens, i, scope, self_type, overlay)
	return _check_chain_from(tokens, i + 1, end, scope, self_type, base_info)


## Walks dotted segments starting at a DOT token with a known base.
## Args of calls are validated but not consumed (the main loop walks
## them for nested checks).
func _check_chain_from(tokens: Array, dot_idx: int, end: int, scope: Dictionary, self_type: String, base_info: Dictionary) -> int:
	var cur_type = str(base_info.get("type", ""))
	var cur_kind = str(base_info.get("kind", ""))
	var j = dot_idx
	while j < end and j < tokens.size():
		if str((tokens[j] as Dictionary).get("type", "")) != "DOT":
			break
		j += 1
		if j >= end or j >= tokens.size():
			break
		var nt = str((tokens[j] as Dictionary).get("type", ""))
		if nt != "IDENTIFIER" and nt != "BUILTIN_TYPE" and nt != "KEYWORD":
			break
		var mname = str((tokens[j] as Dictionary).get("value", ""))
		var is_call := j + 1 < end and j + 1 < tokens.size() and str((tokens[j + 1] as Dictionary).get("type", "")) == "LPAREN"
		if cur_kind in ["unknown", "singleton", "super", "enum"]:
			j += 1
			cur_kind = "unknown"
			cur_type = ""
			continue
		if cur_kind == "signal":
			if not (mname in SIGNAL_METHODS):
				_error(KIND_MISSING_METHOD, "signal has no method '" + mname + "'", int((tokens[j] as Dictionary).get("line", 0)), int((tokens[j] as Dictionary).get("column", 0)))
			j += 1
			cur_kind = "unknown"
			cur_type = ""
			continue
		if cur_kind == "type":
			if cur_type == "":
				j += 1
				cur_kind = "unknown"
				continue
			if mname == "new":
				cur_kind = "instance"
				j += 1
				continue
			var found = _find_method(cur_type, mname)
			if found.is_empty():
				j += 1
				continue
			if not bool(found.get("static", false)) and is_call:
				_error(KIND_STATIC_ACCESS, "instance method '" + cur_type + "." + mname + "' cannot be accessed statically", int((tokens[j] as Dictionary).get("line", 0)), int((tokens[j] as Dictionary).get("column", 0)))
			elif is_call:
				_check_arity(cur_type + "." + mname, (found["entry"] as Dictionary).get("params", []), tokens, j, int((tokens[j] as Dictionary).get("line", 0)), int((tokens[j] as Dictionary).get("column", 0)), bool((found["entry"] as Dictionary).get("is_vararg", false)))
			cur_type = _method_returns(found)
			cur_kind = "instance"
			j += 1
			continue
		if cur_kind == "instance" or cur_kind == "self":
			if not is_call:
				cur_kind = "unknown"
				cur_type = ""
				j += 1
				continue
			if cur_type == "":
				cur_kind = "unknown"
				j += 1
				continue
			var found2 = _find_method(cur_type, mname)
			if found2.is_empty():
				var chain = _display_chain(cur_type)
				_error(KIND_MISSING_METHOD, "type '" + cur_type + "' has no method '" + mname + "'" + chain, int((tokens[j] as Dictionary).get("line", 0)), int((tokens[j] as Dictionary).get("column", 0)))
				cur_kind = "unknown"
				cur_type = ""
				j += 1
				continue
			_check_arity(cur_type + "." + mname, (found2["entry"] as Dictionary).get("params", []), tokens, j, int((tokens[j] as Dictionary).get("line", 0)), int((tokens[j] as Dictionary).get("column", 0)), bool((found2["entry"] as Dictionary).get("is_vararg", false)))
			cur_type = _method_returns(found2)
			cur_kind = "instance"
			j += 1
			continue
		j += 1
	return j


func _method_returns(found: Dictionary) -> String:
	var entry: Dictionary = found.get("entry", {})
	return str(entry.get("returns", ""))


func _display_chain(type_name: String) -> String:
	var info = _resolve_type_quiet(type_name)
	var chain = _chain_of(info)
	if chain.size() <= 1:
		return ""
	return " (chain: " + " < ".join(chain) + ")"


## Consumes DOT name pairs without checks (call args are left for the
## main loop so nested identifiers are still validated). Used when the
## chain base type is unknown so positions stay aligned.
func _skip_chain(tokens: Array, dot_idx: int, end: int) -> int:
	var j = dot_idx
	while j < end and j < tokens.size():
		if str((tokens[j] as Dictionary).get("type", "")) != "DOT":
			break
		j += 1
		if j >= end or j >= tokens.size():
			break
		var nt = str((tokens[j] as Dictionary).get("type", ""))
		if nt != "IDENTIFIER" and nt != "BUILTIN_TYPE" and nt != "KEYWORD":
			break
		j += 1
	return j


## Classifies the base of a dotted chain: type name, signal, singleton,
## instance with known type, enum, super, self or unknown.
func _dot_base(tokens: Array, i: int, scope: Dictionary, self_type: String, overlay: Dictionary) -> Dictionary:
	var t: Dictionary = tokens[i]
	var ty = str(t.get("type", ""))
	var v = str(t.get("value", ""))
	if ty == "KEYWORD" and v == "self":
		return {"kind": "self", "type": self_type}
	if ty == "KEYWORD" and v == "super":
		return {"kind": "super", "type": ""}
	if ty == "BUILTIN_TYPE":
		if v == "void":
			return {"kind": "unknown", "type": ""}
		return {"kind": "type", "type": v}
	if ty != "IDENTIFIER":
		return {"kind": "unknown", "type": ""}
	if v in SINGLETONS:
		return {"kind": "singleton", "type": ""}
	var entry = _scope_get(scope, v)
	if entry.has("kind"):
		var kind = str(entry.get("kind", ""))
		if kind == "signal":
			return {"kind": "signal", "type": ""}
		if kind in ["var", "param", "member", "loop", "bind", "const"]:
			return {"kind": "instance", "type": str(entry.get("type", ""))}
		if kind == "func":
			return {"kind": "unknown", "type": ""}
		if kind in ["class", "enum"]:
			return {"kind": "type", "type": str(entry.get("type", v))}
		return {"kind": "unknown", "type": ""}
	if (overlay as Dictionary).has(v):
		return {"kind": "instance", "type": ""}
	if _script_types.has(v):
		var st: Dictionary = _script_types[v]
		if str(st.get("kind", "")) == "enum":
			return {"kind": "enum", "type": v}
		return {"kind": "type", "type": str(st.get("full", v))}
	if _is_all_caps(v) or v in KEYWORDS:
		return {"kind": "unknown", "type": ""}
	if _resolve_type_quiet(v).has("name"):
		return {"kind": "type", "type": v}
	_error(KIND_UNDECLARED, "unknown identifier '" + v + "'", int(t.get("line", 0)), int(t.get("column", 0)))
	return {"kind": "unknown", "type": ""}


## Arity check against params with defaults and method-level vararg.
func _check_arity(label: String, params: Array, tokens: Array, name_idx: int, line: int, column: int, method_vararg: bool = false) -> void:
	if name_idx + 1 >= tokens.size() or str((tokens[name_idx + 1] as Dictionary).get("type", "")) != "LPAREN":
		return
	var args = _split_args(tokens, name_idx + 1)
	var nargs = args.size()
	var required = 0
	var total = 0
	var vararg = method_vararg
	for p in params:
		if p is Dictionary and bool((p as Dictionary).get("is_vararg", false)):
			vararg = true
	for p in params:
		if not (p is Dictionary):
			continue
		if str((p as Dictionary).get("kind", "")) == "vararg":
			vararg = true
			continue
		total += 1
		if not bool((p as Dictionary).get("has_default", false)):
			if required == total - 1:
				required += 1
	if nargs < required or (not vararg and nargs > total):
		var expected = str(required) + ".." + str(total)
		if vararg:
			expected = str(required) + "..*"
		_error(KIND_ARITY, "wrong number of arguments calling '" + label + "' (expected " + expected + ", got " + str(nargs) + ")", line, column)


func _params_have_vararg(params: Array) -> bool:
	for p in params:
		if p is Dictionary and bool((p as Dictionary).get("is_vararg", false)):
			return true
	return false


func _check_assignment(tokens: Array, i: int, scope: Dictionary, self_type: String, overlay: Dictionary) -> void:
	if i == 0:
		return
	var target: Dictionary = tokens[i - 1]
	if str(target.get("type", "")) != "IDENTIFIER":
		return
	if i >= 2 and str((tokens[i - 2] as Dictionary).get("type", "")) == "DOT":
		return
	var v = str(target.get("value", ""))
	var entry = _scope_get(scope, v)
	if not entry.has("kind"):
		if (overlay as Dictionary).has(v):
			return
		if _script_types.has(v) or v in SINGLETONS or v in GLOBAL_FUNCS or v in KEYWORDS or _is_all_caps(v) or v == "_":
			return
		if _resolve_type_quiet(v).has("name"):
			return
		_error(KIND_UNDECLARED, "unknown identifier '" + v + "'", int(target.get("line", 0)), int(target.get("column", 0)))
		return
	if str(entry.get("kind", "")) == "const":
		_error(KIND_CONST_ASSIGN, "cannot assign to constant '" + v + "'", int(target.get("line", 0)), int(target.get("column", 0)))
		return
	var declared = str(entry.get("type", ""))
	if declared == "" or declared == "Variant":
		return
	var rhs = _infer_slice(tokens, i + 1, scope, self_type)
	if rhs == "" or rhs == "Variant":
		return
	_check_assignable(declared, rhs, int(target.get("line", 0)), int(target.get("column", 0)))


func _check_augmented(tokens: Array, i: int, scope: Dictionary, self_type: String, overlay: Dictionary) -> void:
	if i == 0:
		return
	var target: Dictionary = tokens[i - 1]
	if str(target.get("type", "")) != "IDENTIFIER":
		return
	if i >= 2 and str((tokens[i - 2] as Dictionary).get("type", "")) == "DOT":
		return
	var v = str(target.get("value", ""))
	var entry = _scope_get(scope, v)
	if not entry.has("kind"):
		if (overlay as Dictionary).has(v):
			return
		return
	if str(entry.get("kind", "")) == "const":
		_error(KIND_CONST_ASSIGN, "cannot assign to constant '" + v + "'", int(target.get("line", 0)), int(target.get("column", 0)))
		return
	var left = str(entry.get("type", ""))
	if left == "" or left == "Variant" or _is_enum_type(left):
		return
	var op = str((tokens[i] as Dictionary).get("value", ""))
	var right = _infer_slice(tokens, i + 1, scope, self_type)
	if right == "" or right == "Variant":
		return
	_check_operator(op, left, right, int((tokens[i] as Dictionary).get("line", 0)), int((tokens[i] as Dictionary).get("column", 0)))


## Generic binary operator check for arithmetic, bitwise, comparisons
## and `in`. Skips anything involving unknown, Variant or enum types.
func _check_binary_op(tokens: Array, i: int, scope: Dictionary, self_type: String) -> void:
	var op = str((tokens[i] as Dictionary).get("value", ""))
	if op in ["=", ":=", "->", ".", ":", ","]:
		return
	if op == "=>":
		return
	if (op == "+" or op == "-") and _is_unary_position(tokens, i):
		return
	var left = _infer_operand_back(tokens, i - 1, scope, self_type, {})
	var right = _infer_operand_fwd(tokens, i + 1, scope, self_type, {})
	var lt = str(left.get("type", ""))
	var rt = str(right.get("type", ""))
	if lt == "" or rt == "" or lt == "Variant" or rt == "Variant":
		return
	if _is_enum_type(lt) or _is_enum_type(rt):
		return
	if op == "in":
		_check_in_operator(rt, int((tokens[i] as Dictionary).get("line", 0)), int((tokens[i] as Dictionary).get("column", 0)))
		return
	if op in LOGIC_OPS or op == "not":
		return
	_check_operator(op, lt, rt, int((tokens[i] as Dictionary).get("line", 0)), int((tokens[i] as Dictionary).get("column", 0)))


## True when + or - sits where only a unary operator fits: at the
## start or right after an opener, comma, colon, semicolon or another
## operator (e.g. the -1 in mixed[-1]).
func _is_unary_position(tokens: Array, i: int) -> bool:
	if i <= 0:
		return true
	var pt = str((tokens[i - 1] as Dictionary).get("type", ""))
	return pt in ["LPAREN", "LBRACKET", "LBRACE", "COMMA", "COLON", "SEMICOLON", "OPERATOR"]


func _check_in_operator(right: String, line: int, column: int) -> void:
	var info = _resolve_type_quiet(_base_type(right))
	if info.is_empty():
		return
	for o in info.get("operators", []):
		if o is Dictionary and str((o as Dictionary).get("op", "")) == "in":
			return
	_error(KIND_OPERATOR, "operator 'in' is not defined for '" + right + "'", line, column)


## Table lookup: exact right match, Variant wildcard, or Object cover.
func _check_operator(op: String, left: String, right: String, line: int, column: int) -> void:
	var base = _base_type(left)
	if base == "":
		return
	var info = _resolve_type_quiet(base)
	if info.is_empty():
		return
	var right_base = _base_type(right)
	var right_disp = right_base
	if right_base == "Nil":
		right_disp = "null"
	for o in info.get("operators", []):
		if not (o is Dictionary):
			continue
		if str((o as Dictionary).get("op", "")) != op:
			continue
		var want = str((o as Dictionary).get("right", ""))
		if str((o as Dictionary).get("right_kind", "value")) == "none" and right == "":
			return
		if want == right_base or want == "Variant":
			return
		if want == "Object" and _derives_object(right_base):
			return
	_error(KIND_OPERATOR, "operator '" + op + "' is not defined for '" + left + "' with '" + right_disp + "'", line, column)


func _derives_object(type_name: String) -> bool:
	var info = _resolve_type_quiet(_base_type(type_name))
	if info.is_empty():
		return false
	return "Object" in _chain_of(info)


## Assignment/return compatibility (tolerant buddy system).
func _check_assignable(declared: String, value: String, line: int, column: int) -> void:
	if declared == "" or value == "" or declared == "Variant" or value == "Variant":
		return
	if declared == value:
		return
	if _is_enum_type(declared) or _is_enum_type(value):
		if _is_enum_type(declared) and _is_enum_type(value) and declared == value:
			return
		if _is_enum_type(value) and declared == "int":
			return
		if _is_enum_type(declared) or _is_enum_type(value):
			return
	if declared in NUMERIC_TYPES and value in NUMERIC_TYPES:
		return
	if value == "null" or value == "Nil":
		if _derives_object(declared) or _base_type(declared) == "Variant":
			return
		_error(KIND_ASSIGN, "cannot assign 'null' to '" + declared + "'", line, column)
		return
	if _base_type(declared) == _base_type(value):
		return
	_error(KIND_ASSIGN, "cannot assign '" + value + "' to '" + declared + "'", line, column)


# ------------------------------------------------------- type inference

## Infers the type of a token slice ("" means unknown).
func _infer_slice(tokens: Array, start: int, scope: Dictionary, self_type: String) -> String:
	var sub: Array = []
	var i = start
	while i < tokens.size():
		sub.append(tokens[i])
		i += 1
	return _infer_tokens(sub, scope, self_type)


func _infer_tokens(tokens: Array, scope: Dictionary, self_type: String) -> String:
	var clean: Array = []
	for t in tokens:
		if t is Dictionary and str((t as Dictionary).get("type", "")) != "LAMBDA_MARKER":
			clean.append(t)
	if clean.is_empty():
		return ""
	if clean.size() == 1:
		return _infer_primary(clean, 0, scope, self_type).get("type", "")
	var first_ty = str((clean[0] as Dictionary).get("type", ""))
	if first_ty == "LBRACKET":
		return "Array"
	if first_ty == "LBRACE":
		return "Dictionary"
	var extra: Dictionary = {}
	for t in clean:
		if t is Dictionary and str((t as Dictionary).get("type", "")) == "KEYWORD" and str((t as Dictionary).get("value", "")) == "func":
			return "Callable"
	if _has_top_op(clean, "as"):
		return _infer_cast(clean, scope, self_type)
	if _has_top_op(clean, "is") or _has_top_kw_in(clean):
		return "bool"
	if _has_top_compare(clean) or _has_top_logic(clean) or _has_top_not(clean):
		return "bool"
	if _has_top_ternary(clean):
		return _infer_ternary(clean, scope, self_type)
	return _infer_binary_fold(clean, scope, self_type)


func _has_top_op(tokens: Array, word: String) -> bool:
	var depth = 0
	for t in tokens:
		var ty = str((t as Dictionary).get("type", ""))
		var v = str((t as Dictionary).get("value", ""))
		if ty == "LPAREN" or ty == "LBRACKET" or ty == "LBRACE":
			depth += 1
		elif ty == "RPAREN" or ty == "RBRACKET" or ty == "RBRACE":
			depth = maxi(0, depth - 1)
		elif depth == 0 and ((ty == "KEYWORD" and v == word) or (ty == "OPERATOR" and v == word)):
			return true
	return false


func _has_top_kw_in(tokens: Array) -> bool:
	var depth = 0
	for t in tokens:
		var ty = str((t as Dictionary).get("type", ""))
		var v = str((t as Dictionary).get("value", ""))
		if ty == "LPAREN" or ty == "LBRACKET" or ty == "LBRACE":
			depth += 1
		elif ty == "RPAREN" or ty == "RBRACKET" or ty == "RBRACE":
			depth = maxi(0, depth - 1)
		elif depth == 0 and ty == "KEYWORD" and v == "in":
			return true
	return false


func _has_top_compare(tokens: Array) -> bool:
	var depth = 0
	for t in tokens:
		var ty = str((t as Dictionary).get("type", ""))
		var v = str((t as Dictionary).get("value", ""))
		if ty == "LPAREN" or ty == "LBRACKET" or ty == "LBRACE":
			depth += 1
		elif ty == "RPAREN" or ty == "RBRACKET" or ty == "RBRACE":
			depth = maxi(0, depth - 1)
		elif depth == 0 and ty == "OPERATOR" and v in COMPARE_OPS:
			return true
	return false


func _has_top_logic(tokens: Array) -> bool:
	var depth = 0
	for t in tokens:
		var ty = str((t as Dictionary).get("type", ""))
		var v = str((t as Dictionary).get("value", ""))
		if ty == "LPAREN" or ty == "LBRACKET" or ty == "LBRACE":
			depth += 1
		elif ty == "RPAREN" or ty == "RBRACKET" or ty == "RBRACE":
			depth = maxi(0, depth - 1)
		elif depth == 0 and ((ty == "KEYWORD" and (v == "and" or v == "or")) or (ty == "OPERATOR" and (v == "&&" or v == "||"))):
			return true
	return false


func _has_top_not(tokens: Array) -> bool:
	if tokens.is_empty():
		return false
	var t: Dictionary = tokens[0]
	return (str(t.get("type", "")) == "KEYWORD" and str(t.get("value", "")) == "not") or (str(t.get("type", "")) == "OPERATOR" and str(t.get("value", "")) == "!")


func _has_top_ternary(tokens: Array) -> bool:
	return _has_top_op(tokens, "if") and _has_top_op(tokens, "else")


func _infer_cast(tokens: Array, scope: Dictionary, self_type: String) -> String:
	var depth = 0
	var i = 0
	while i < tokens.size():
		var ty = str((tokens[i] as Dictionary).get("type", ""))
		var v = str((tokens[i] as Dictionary).get("value", ""))
		if ty == "LPAREN" or ty == "LBRACKET" or ty == "LBRACE":
			depth += 1
		elif ty == "RPAREN" or ty == "RBRACKET" or ty == "RBRACE":
			depth = maxi(0, depth - 1)
		elif depth == 0 and ((ty == "KEYWORD" and v == "as") or (ty == "OPERATOR" and v == "as")):
			var parts: Array = []
			var j = i + 1
			while j < tokens.size():
				var jt = str((tokens[j] as Dictionary).get("type", ""))
				if jt == "IDENTIFIER" or jt == "BUILTIN_TYPE":
					parts.append(str((tokens[j] as Dictionary).get("value", "")))
					j += 1
				elif jt == "DOT":
					j += 1
				else:
					break
			if parts.is_empty():
				return ""
			return ".".join(parts)
		i += 1
	return ""


func _infer_ternary(tokens: Array, scope: Dictionary, self_type: String) -> String:
	var depth = 0
	var if_at = -1
	var else_at = -1
	var i = 0
	while i < tokens.size():
		var ty = str((tokens[i] as Dictionary).get("type", ""))
		var v = str((tokens[i] as Dictionary).get("value", ""))
		if ty == "LPAREN" or ty == "LBRACKET" or ty == "LBRACE":
			depth += 1
		elif ty == "RPAREN" or ty == "RBRACKET" or ty == "RBRACE":
			depth = maxi(0, depth - 1)
		elif depth == 0 and ty == "KEYWORD" and v == "if" and if_at == -1:
			if_at = i
		elif depth == 0 and ty == "KEYWORD" and v == "else" and if_at != -1:
			else_at = i
			break
		i += 1
	if if_at == -1 or else_at == -1:
		return ""
	var left: Array = tokens.slice(0, if_at)
	var right: Array = tokens.slice(else_at + 1)
	var lt = _infer_tokens(left, scope, self_type)
	var rt = _infer_tokens(right, scope, self_type)
	if lt != "" and lt == rt:
		return lt
	return ""


func _infer_binary_fold(tokens: Array, scope: Dictionary, self_type: String) -> String:
	var current = ""
	var i = 0
	while i < tokens.size():
		var ty = str((tokens[i] as Dictionary).get("type", ""))
		var v = str((tokens[i] as Dictionary).get("value", ""))
		if ty == "LPAREN" or ty == "LBRACKET" or ty == "LBRACE":
			if ty == "LPAREN" and i > 0:
				var prev = str((tokens[i - 1] as Dictionary).get("type", ""))
				if prev == "IDENTIFIER" or prev == "BUILTIN_TYPE" or prev == "RPAREN" or prev == "RBRACKET" or prev == "RBRACE":
					var cname = ""
					if prev == "IDENTIFIER" or prev == "BUILTIN_TYPE":
						cname = str((tokens[i - 1] as Dictionary).get("value", ""))
					var close = _match_forward(tokens, i)
					if _known_type_name(cname, scope):
						current = cname
					else:
						current = ""
					i = close + 1
					continue
			var close = _match_forward(tokens, i)
			var inner = _infer_tokens(tokens.slice(i + 1, close), scope, self_type)
			if current == "":
				current = inner
			i = close + 1
			continue
		if (ty == "OPERATOR" and (v in BINARY_ARITH_OPS or v in COMPARE_OPS)) or (ty == "KEYWORD" and (v == "and" or v == "or")) or (ty == "OPERATOR" and (v == "&&" or v == "||")):
			if v in COMPARE_OPS:
				return "bool"
			if v in LOGIC_OPS or v == "&&" or v == "||":
				return "bool"
			var rhs = _infer_operand_fwd(tokens, i + 1, scope, self_type, {})
			var rtype = str(rhs.get("type", ""))
			if current == "" or rtype == "":
				return ""
			current = _apply_operator(current, v, rtype)
			if current == "":
				return ""
			i = int(rhs.get("next", i + 1))
			continue
		if ty == "OPERATOR" and v in ["=", ":=", "->", ".", ":", ",", ";"]:
			i += 1
			continue
		if ty == "KEYWORD" and v in ["if", "else", "not", "in", "is", "as", "await", "when"]:
			if v == "not":
				return "bool"
			i += 1
			continue
		var prim = _infer_primary(tokens, i, scope, self_type)
		var ptype = str(prim.get("type", ""))
		if ptype != "" and current == "":
			current = ptype
		i = maxi(i + 1, int(prim.get("next", i + 1)))
	return current


## True when a name can act as a constructor type (not a variable).
func _known_type_name(cname: String, scope: Dictionary) -> bool:
	if cname == "":
		return false
	if _script_types.has(cname):
		return true
	var entry = _scope_get(scope, cname)
	if entry.has("kind"):
		return str(entry.get("kind", "")) in ["class", "enum"]
	return _resolve_type_quiet(cname).has("name")


func _apply_operator(left: String, op: String, right: String) -> String:
	if left == "" or right == "" or left == "Variant" or right == "Variant":
		return ""
	if _is_enum_type(left) or _is_enum_type(right):
		return ""
	var info = _resolve_type_quiet(_base_type(left))
	if info.is_empty():
		return ""
	var rb = _base_type(right)
	for o in info.get("operators", []):
		if not (o is Dictionary):
			continue
		if str((o as Dictionary).get("op", "")) != op:
			continue
		var want = str((o as Dictionary).get("right", ""))
		if want == rb or want == "Variant":
			return str((o as Dictionary).get("returns", ""))
		if want == "Object" and _derives_object(rb):
			return str((o as Dictionary).get("returns", ""))
	return ""


## Infers the operand ending at index idx (walks dotted chains/calls).
func _infer_operand_back(tokens: Array, idx: int, scope: Dictionary, self_type: String, overlay: Dictionary) -> Dictionary:
	if idx < 0:
		return {"type": "", "next": 0}
	return _infer_primary(tokens, idx, scope, self_type, true)


## Infers the operand starting at index idx.
func _infer_operand_fwd(tokens: Array, idx: int, scope: Dictionary, self_type: String, overlay: Dictionary) -> Dictionary:
	if idx >= tokens.size():
		return {"type": "", "next": idx}
	return _infer_primary(tokens, idx, scope, self_type, false)


## Infers one primary expression. When backward is true, idx points at
## the last token of the operand; otherwise at the first.
func _infer_primary(tokens: Array, idx: int, scope: Dictionary, self_type: String, backward: bool = false) -> Dictionary:
	if idx < 0 or idx >= tokens.size():
		return {"type": "", "next": idx}
	var t: Dictionary = tokens[idx]
	var ty = str(t.get("type", ""))
	var v = str(t.get("value", ""))
	if ty == "INT":
		return {"type": "int", "next": idx}
	if ty == "FLOAT":
		return {"type": "float", "next": idx}
	if ty == "STRING":
		return {"type": "String", "next": idx}
	if ty == "BOOL":
		return {"type": "bool", "next": idx}
	if ty == "NULL":
		return {"type": "Nil", "next": idx}
	if ty == "STRING_NAME":
		return {"type": "StringName", "next": idx}
	if ty == "NODE_PATH":
		return {"type": "NodePath", "next": idx}
	if ty == "GET_NODE" or ty == "UNIQUE_NAME":
		return {"type": "Node", "next": idx}
	if ty == "LBRACKET":
		return {"type": "Array", "next": idx}
	if ty == "LBRACE":
		return {"type": "Dictionary", "next": idx}
	if ty == "LAMBDA_MARKER":
		return {"type": "Callable", "next": idx}
	if ty == "KEYWORD":
		if v == "func":
			return {"type": "Callable", "next": idx}
		if v == "self":
			return {"type": self_type, "next": idx}
		if v == "true" or v == "false":
			return {"type": "bool", "next": idx}
		return {"type": "", "next": idx}
	if ty == "BUILTIN_TYPE":
		return {"type": v, "next": idx}
	if ty != "IDENTIFIER":
		return {"type": "", "next": idx}
	var entry = _scope_get(scope, v)
	if entry.has("kind"):
		var kind = str(entry.get("kind", ""))
		if kind in ["var", "param", "member", "loop", "bind", "const"]:
			return {"type": str(entry.get("type", "")), "next": idx}
		if kind == "signal":
			return {"type": "Signal", "next": idx}
		if kind == "func":
			return {"type": "", "next": idx}
		if kind in ["class", "enum"]:
			return {"type": str(entry.get("type", v)), "next": idx}
		return {"type": "", "next": idx}
	if _script_types.has(v):
		var st: Dictionary = _script_types[v]
		if str(st.get("kind", "")) == "enum":
			return {"type": v, "next": idx}
		return {"type": str(st.get("full", v)), "next": idx}
	return {"type": "", "next": idx}


# ------------------------------------------------------- user type files

func _write_user_types(ast: Dictionary) -> void:
	var base_name = user_file_base(_script_class, _script_resource_path, "")
	var root_prefix = _script_class
	if root_prefix == "":
		root_prefix = base_name
	var main = _script_type_info(ast, base_name, root_prefix)
	_ensure_user_dir()
	_write_json(_user_path(base_name), main)
	_written.append(_user_path(base_name))
	for inner in _collect_inner_infos(ast, root_prefix):
		var iname = str((inner as Dictionary).get("full_name", ""))
		_write_json(_user_path(iname), inner)
		_written.append(_user_path(iname))


func _user_path(dotted_or_base: String) -> String:
	return _write_base + "/user/" + dotted_or_base + ".json"


func _ensure_user_dir() -> void:
	var dir = _write_base + "/user"
	if dir.begins_with("res://") or dir.begins_with("user://"):
		_ensure_dir(ProjectSettings.globalize_path(dir))
	elif dir.begins_with("/"):
		DirAccess.make_dir_recursive_absolute(dir)
	else:
		var d = DirAccess.open(".")
		if d != null:
			d.make_dir_recursive(dir)


func _ensure_dir(path: String) -> void:
	if path.begins_with("res://") or path.begins_with("user://"):
		_ensure_dir(ProjectSettings.globalize_path(path))
	elif path.begins_with("/"):
		DirAccess.make_dir_recursive_absolute(path)
	else:
		var d = DirAccess.open(".")
		if d != null:
			d.make_dir_recursive(path)


func _write_json(path: String, data: Dictionary) -> void:
	var file = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(JSON.stringify(data, "\t"))
	file.close()


func _script_type_info(ast: Dictionary, base_name: String, prefix: String) -> Dictionary:
	var parent = _script_extends
	if parent == "":
		parent = "RefCounted"
	var info = {
		"name": base_name,
		"kind": "script",
		"class_name": _script_class,
		"resource_path": _script_resource_path,
		"parent": parent,
		"inheritance_chain": _script_chain(base_name, parent, [base_name]),
		"enums": [],
		"constants": [],
		"signals": [],
		"fields": [],
		"static_methods": [],
		"instance_methods": [],
		"inner_classes": [],
	}
	for child in ast.get("children", []):
		if child is Dictionary:
			_add_member_info(info, child, prefix)
	return info


func _script_chain(base_name: String, parent: String, seen: Array) -> Array:
	var chain: Array = [base_name]
	if parent == "" or parent in seen:
		return chain
	seen.append(parent)
	var pinfo = _resolve_type_quiet(_base_type(parent))
	if pinfo.is_empty():
		chain.append(parent)
		return chain
	for c in _chain_of(pinfo):
		if not (c in chain):
			chain.append(c)
	return chain


func _add_member_info(info: Dictionary, node: Dictionary, prefix: String) -> void:
	var t = str(node.get("type", ""))
	if t == "ENUM_DECL":
		(info["enums"] as Array).append(_enum_info(node))
	elif t == "CONST_DECL":
		(info["constants"] as Array).append(_const_info(node))
	elif t == "SIGNAL_DECL":
		(info["signals"] as Array).append(_signal_info(node))
	elif t == "VAR_DECL":
		(info["fields"] as Array).append(_field_info(node))
	elif t == "FUNC_DECL":
		var f = _func_info(node)
		if bool(node.get("is_static", false)):
			(info["static_methods"] as Array).append(f)
		else:
			(info["instance_methods"] as Array).append(f)
	elif t == "CLASS_DECL":
		var iname = str(node.get("name", ""))
		if iname == "":
			return
		var full = iname
		if prefix != "":
			full = prefix + "." + iname
		(info["inner_classes"] as Array).append({"name": iname, "full_name": full, "file": full + ".json"})


func _collect_inner_infos(ast: Dictionary, prefix: String) -> Array:
	var out: Array = []
	for child in ast.get("children", []):
		if child is Dictionary and str((child as Dictionary).get("type", "")) == "CLASS_DECL":
			_collect_inner_recursive(child, prefix, out)
	return out


func _collect_inner_recursive(node: Dictionary, prefix: String, out: Array) -> void:
	var iname = str(node.get("name", ""))
	if iname == "":
		return
	var full = iname
	if prefix != "":
		full = prefix + "." + iname
	var parent = _type_text(node.get("extends_type", null))
	if parent == "":
		var body: Variant = node.get("body", null)
		if body is Dictionary:
			for child in (body as Dictionary).get("children", []):
				if child is Dictionary and str((child as Dictionary).get("type", "")) == "EXTENDS":
					parent = _dotted_name((child as Dictionary).get("path", []))
					break
	if parent == "":
		parent = "RefCounted"
	var info = {
		"name": iname,
		"full_name": full,
		"kind": "script",
		"class_name": full,
		"resource_path": _script_resource_path,
		"parent": parent,
		"inheritance_chain": _script_chain(full, parent, [full]),
		"enums": [],
		"constants": [],
		"signals": [],
		"fields": [],
		"static_methods": [],
		"instance_methods": [],
		"inner_classes": [],
	}
	var body2: Variant = node.get("body", null)
	if body2 is Dictionary:
		for child in (body2 as Dictionary).get("children", []):
			if child is Dictionary:
				_add_member_info(info, child, full)
	out.append(info)
	if body2 is Dictionary:
		for child in (body2 as Dictionary).get("children", []):
			if child is Dictionary and str((child as Dictionary).get("type", "")) == "CLASS_DECL":
				_collect_inner_recursive(child, full, out)


func _enum_info(node: Dictionary) -> Dictionary:
	var members: Array = []
	for m in node.get("members", []):
		if m is Dictionary and str((m as Dictionary).get("type", "")) == "ENUM_MEMBER":
			var val: Variant = (m as Dictionary).get("value", null)
			var text: Variant = null
			if val is Dictionary:
				text = _expr_text(val)
			members.append({"name": str((m as Dictionary).get("name", "")), "value": text})
	return {"name": str(node.get("name", "")), "members": members}


func _const_info(node: Dictionary) -> Dictionary:
	var val: Variant = node.get("value", null)
	var text: Variant = null
	if val is Dictionary:
		text = _expr_text(val)
	return {"name": str(node.get("name", "")), "type": _type_text(node.get("vartype", null)), "value": text}


func _signal_info(node: Dictionary) -> Dictionary:
	var params: Array = []
	for p in node.get("params", []):
		if p is Dictionary:
			params.append({"name": str((p as Dictionary).get("name", "")), "type": _param_type_of(p)})
	return {"name": str(node.get("name", "")), "params": params}


func _field_info(node: Dictionary) -> Dictionary:
	var exported = false
	var onready = false
	for a in node.get("annotations", []):
		if a is Dictionary:
			var aname = str((a as Dictionary).get("name", ""))
			if aname.begins_with("@export"):
				exported = true
			if aname == "@onready":
				onready = true
	var val: Variant = node.get("value", null)
	var text: Variant = null
	if val is Dictionary and str((val as Dictionary).get("type", "")) != "LAMBDA":
		text = _expr_text(val)
	return {
		"name": str(node.get("name", "")),
		"type": _declared_type_of(node),
		"is_static": bool(node.get("is_static", false)),
		"is_exported": exported,
		"is_onready": onready,
		"default": text,
	}


func _func_info(node: Dictionary) -> Dictionary:
	var params: Array = []
	for p in node.get("params", []):
		if p is Dictionary:
			var def: Variant = (p as Dictionary).get("default", null)
			var text: Variant = null
			if def is Dictionary:
				text = _expr_text(def)
			params.append({
				"name": str((p as Dictionary).get("name", "")),
				"type": _param_type_of(p),
				"has_default": def != null,
				"default": text,
			})
	var rt = _type_text(node.get("return_type", null))
	if rt == "":
		rt = "void"
	return {"name": str(node.get("name", "")), "returns": rt, "is_vararg": false, "params": params}


func _expr_text(v: Variant) -> String:
	if not (v is Dictionary):
		return ""
	if not ((v as Dictionary).has("tokens")):
		return ""
	var out = ""
	for t in (v as Dictionary).get("tokens", []):
		if t is Dictionary:
			out += str((t as Dictionary).get("value", ""))
	return out


# ------------------------------------------------------- node collection

func _collect_nodes(node: Variant, want: String) -> Array:
	var out: Array = []
	_walk_collect(node, want, out)
	return out


func _walk_collect(node: Variant, want: String, out: Array) -> void:
	if node is Array:
		for e in node:
			_walk_collect(e, want, out)
		return
	if not (node is Dictionary):
		return
	var d: Dictionary = node
	if str(d.get("type", "")) == want:
		out.append(d)
	for k in d.keys():
		if k in ["tokens", "args", "annotations", "leading_comments"]:
			continue
		_walk_collect(d[k], want, out)
