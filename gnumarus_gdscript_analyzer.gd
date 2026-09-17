class_name gnumarus_gdscript_analyzer
extends RefCounted

## Analyzer of type-annotation comments.
##
## Reads the AST produced by the semantic parser and interprets the
## comments carrying type annotations (the TYPE_INFO tokens the post
## tokenizer builds from COMMENT and DOC_COMMENT tokens). Annotations
## follow the general shape "@name param1 param2 ... lastparam",
## usually on one line; multi-line struct/tuple definitions with
## dictionaries and arrays are future work, not handled here.
##
## Rules are implemented one at a time with growing complexity. The
## first rule is "@deprecated":
## - It may sit at the script root (deprecates the whole script) or
##   right before any member declaration, static or instance:
##   functions, variables, nested classes, enums, constants, signals.
## - Before a function it deprecates the whole function. Function
##   parameters are NOT supported yet (explicitly deferred).
## - Using anything marked deprecated generates a WARNING in the AST
##   about deprecated usage. Misplaced tags generate ERRORS.
##
## The second rule is "@private":
## - It may precede any static or instance member (functions,
##   variables, nested classes, enums, constants, signals), but never
##   the file root, function parameters or function-local variables.
## - A private member may be used inside its whole nested family: the
##   declaring class, its ancestors and its descendants (transitively,
##   including the script root). Sibling classes and inheriting classes
##   are NOT family: uses from there are violations.
## - Violations generate ERRORS (kind "private_use"); misplaced tags
##   generate "private_misplaced" errors. Name-based, single-file
##   analysis: receivers of unknown type are skipped.
##
## The third rule is "@return":
## - It may precede a function declaration or a lambda (a statement
##   whose value is a lambda, e.g. `var f = func(): ...`) and declares
##   the function return type: "void", one type name ("# @return Node")
##   or a union ("# @return Object|String|int").
## - Every named member must be a known type (script classes/enums or
##   types_info files); "void" only works alone. When the function also
##   has a "->" annotation, every @return member must equal it or
##   inherit from it (Control is fine for "-> Node", Node is not fine
##   for "-> Control"). Value/bare returns are checked against voidness.
## - Violations generate ERRORS ("return_misplaced", "return_malformed",
##   "return_unknown_type", "return_mismatch", "return_value").
##   Return VALUE compatibility is not inferred (flat token scan).
##
## The fourth rule is "@var":
## - It takes a variable name and a type ("# @var myvar int|float"):
##   before a variable/constant declaration the name must equal the
##   declared one; anywhere inside a function body it redefines the
##   type of a visible variable (locals, params and members). Never
##   before function parameters.
## - Every type member must be known and must equal the declared type
##   or inherit from it. Untyped `=` variables hold Variant (anything
##   goes); `:=` variables infer the type from simple initializers
##   (literals, arrays, dictionaries, constructors, lambdas).
## - Violations generate ERRORS ("var_misplaced", "var_malformed",
##   "var_unknown", "var_unknown_type", "var_mismatch"). Declarations
##   gain a `var_ann` stamp; free uses only check.
##
## The fifth rule is "@param":
## - It takes a parameter name and a type ("# @param myparam int"):
##   directly before a parameter (multiline parameter lists) or before
##   the function/lambda declaration using the parameters (alongside
##   @return and friends, on other lines). Several pairs may share one
##   merged comment token; each must match a parameter by name.
## - Same checks as @var: known members narrowing the declared vartype
##   (untyped parameters accept anything). Violations generate ERRORS
##   ("param_misplaced", "param_malformed", "param_unknown",
##   "param_unknown_type", "param_mismatch"). Parameters gain a
##   `param_ann` stamp.
##
## The walk is scope-aware (locals and parameters shadow members) and
## threads an explicit owner ("", "Outer", "Outer.Inner") so later
## rules can grow flow analysis and type narrowing on top of it.
##
## analyze() returns {"ast": modified_ast, "errors": [...],
## "warnings": [...]}. Error/warning entries look like
## {"kind","message","line","column","owner"}. The AST itself gains
## "analyzer_errors" and "analyzer_warnings" on the root, plus a
## "deprecated"/"private" mark on marked declaration nodes. Just before
## returning, the user type JSON files are updated with member flags
## and the analysis errors/warnings.
## analyze() first ensures the native database (builtin/, classes/,
## index.json), dumping it on demand; when the dump itself fails it
## records a "native_types" error, prints it and returns early.
##
## Usage:
##   var sem := gnumarus_gdscript_semantic_parser.new()
##   var ana := gnumarus_gdscript_analyzer.new()
##   var ast: Dictionary = sem.analyze(syn.parse("res://s.gd"), "res://s.gd")
##   var result: Dictionary = ana.analyze(ast, "res://s.gd")
##   print(result["warnings"])

const WARN_DEPRECATED_USE := "deprecated_use"
const ERR_DEPRECATED_MISPLACED := "deprecated_misplaced"
const ERR_DEPRECATED_UNSUPPORTED := "deprecated_unsupported"
const ERR_PRIVATE_MISPLACED := "private_misplaced"
const ERR_PRIVATE_USE := "private_use"
const ERR_NATIVE_TYPES := "native_types"
const ERR_RETURN_MISPLACED := "return_misplaced"
const ERR_RETURN_MALFORMED := "return_malformed"
const ERR_RETURN_UNKNOWN := "return_unknown_type"
const ERR_RETURN_MISMATCH := "return_mismatch"
const ERR_RETURN_VALUE := "return_value"
const ERR_VAR_MISPLACED := "var_misplaced"
const ERR_VAR_MALFORMED := "var_malformed"
const ERR_VAR_UNKNOWN := "var_unknown"
const ERR_VAR_UNKNOWN_TYPE := "var_unknown_type"
const ERR_VAR_MISMATCH := "var_mismatch"
const ERR_PARAM_MISPLACED := "param_misplaced"
const ERR_PARAM_MALFORMED := "param_malformed"
const ERR_PARAM_UNKNOWN := "param_unknown"
const ERR_PARAM_UNKNOWN_TYPE := "param_unknown_type"
const ERR_PARAM_MISMATCH := "param_mismatch"
const ERR_TUPLE_MISPLACED := "tuple_misplaced"
const ERR_TUPLE_MALFORMED := "tuple_malformed"
const ERR_TUPLE_UNKNOWN_TYPE := "tuple_unknown_type"
const ERR_TUPLE_CONFLICT := "tuple_conflict"
const ERR_TUPLE_MISMATCH := "tuple_mismatch"
const ERR_TUPLE_BOUNDS := "tuple_bounds"
const ERR_MISSING_METHOD := "missing_method"
const ERR_MISSING_MEMBER := "missing_member"

## Signal methods accepted on signal-typed bases (mirrors the semantic
## parser's SIGNAL_METHODS).
const SIGNAL_METHODS := ["connect", "disconnect", "is_connected", "emit", "get_connections"]

## Variant.Type enum value -> narrowed type name ("" = not a real type).
const VARIANT_TYPE_MAP := {
	"TYPE_NIL": "Nil",
	"TYPE_BOOL": "bool",
	"TYPE_INT": "int",
	"TYPE_FLOAT": "float",
	"TYPE_STRING": "String",
	"TYPE_VECTOR2": "Vector2",
	"TYPE_VECTOR2I": "Vector2i",
	"TYPE_RECT2": "Rect2",
	"TYPE_RECT2I": "Rect2i",
	"TYPE_VECTOR3": "Vector3",
	"TYPE_VECTOR3I": "Vector3i",
	"TYPE_TRANSFORM2D": "Transform2D",
	"TYPE_VECTOR4": "Vector4",
	"TYPE_VECTOR4I": "Vector4i",
	"TYPE_PLANE": "Plane",
	"TYPE_QUATERNION": "Quaternion",
	"TYPE_AABB": "AABB",
	"TYPE_BASIS": "Basis",
	"TYPE_TRANSFORM3D": "Transform3D",
	"TYPE_PROJECTION": "Projection",
	"TYPE_COLOR": "Color",
	"TYPE_STRING_NAME": "StringName",
	"TYPE_NODE_PATH": "NodePath",
	"TYPE_RID": "RID",
	"TYPE_OBJECT": "Object",
	"TYPE_CALLABLE": "Callable",
	"TYPE_SIGNAL": "Signal",
	"TYPE_DICTIONARY": "Dictionary",
	"TYPE_ARRAY": "Array",
	"TYPE_PACKED_BYTE_ARRAY": "PackedByteArray",
	"TYPE_PACKED_INT32_ARRAY": "PackedInt32Array",
	"TYPE_PACKED_INT64_ARRAY": "PackedInt64Array",
	"TYPE_PACKED_FLOAT32_ARRAY": "PackedFloat32Array",
	"TYPE_PACKED_FLOAT64_ARRAY": "PackedFloat64Array",
	"TYPE_PACKED_STRING_ARRAY": "PackedStringArray",
	"TYPE_PACKED_VECTOR2_ARRAY": "PackedVector2Array",
	"TYPE_PACKED_VECTOR3_ARRAY": "PackedVector3Array",
	"TYPE_PACKED_COLOR_ARRAY": "PackedColorArray",
	"TYPE_PACKED_VECTOR4_ARRAY": "PackedVector4Array",
	"TYPE_MAX": "",
}

## Preloaded (not via class_name) so this script compiles standalone,
## even before the editor/cache registers global classes.
const SemParser = preload("res://gnumarus_gdscript_semantic_parser.gd")
## Preloaded like SemParser so the native database can be ensured
## without relying on the global class cache.
const NativeDumper = preload("res://gnumaru_godot_native_types_info_dumper.gd")

## Member kinds tracked per owner. Owner "" is the script root,
## otherwise a dotted inner path like "Outer" or "Outer.Inner".
const DECL_TYPES := ["VAR_DECL", "CONST_DECL", "FUNC_DECL", "CLASS_DECL", "ENUM_DECL", "SIGNAL_DECL"]

var _errors: Array = []
var _warnings: Array = []
var _members: Dictionary = {}
var _private: Dictionary = {}
var _class_extends: Dictionary = {}
var _script_deprecated: Dictionary = {}
var _script_class = ""
var _script_extends = ""
var _script_resource_path = ""
var _project_root = ""
var _write_base = "types_info"
var _written: Array = []
## Type file lookups (builtin/classes/user JSON info or miss marker),
## cached per analyze() call for @return name resolution.
var _type_cache: Dictionary = {}
## @tuple definitions: name -> {"resolved": bool, "raws": [...],
## "spec": {...}}. Pre-scan collects raws (order-free known-checks),
## _resolve_tuples validates into specs before the walk.
var _tuples: Dictionary = {}


## Analyzes a semantic-parser AST in place. Returns a Dictionary with
## the modified "ast" plus flat "errors" and "warnings" arrays.
## script_path should be the res:// path of the analyzed script (used
## for user file naming when there is no class_name).
func analyze(ast: Dictionary, script_path: String = "") -> Dictionary:
	_errors = []
	_warnings = []
	_members = {}
	_private = {}
	_class_extends = {}
	_script_deprecated = {}
	_written = []
	_type_cache = {}
	_tuples = {}
	_script_class = ""
	_script_extends = ""
	for child in ast.get("children", []):
		if child is Dictionary and str((child as Dictionary).get("type", "")) == "CLASS_NAME":
			_script_class = str((child as Dictionary).get("name", ""))
		elif child is Dictionary and str((child as Dictionary).get("type", "")) == "EXTENDS":
			_script_extends = _dotted_path((child as Dictionary).get("path", []))
	var anchor = _analyzer_anchor_dir()
	_project_root = SemParser.find_project_root(anchor)
	if _project_root == "":
		_project_root = SemParser.fallback_root(anchor + "/gnumaru_godot_native_types_info_dumper.gd")
	_script_resource_path = SemParser.resource_path_for(script_path, _project_root)
	_write_base = _compute_write_base(_project_root)
	if not _ensure_native_types():
		ast["analyzer_errors"] = _errors
		ast["analyzer_warnings"] = _warnings
		ast["analyzer_written"] = _written
		return {"ast": ast, "errors": _errors, "warnings": _warnings}
	_scan_header(ast)
	_prescan_tuples(ast)
	_scan_children(ast.get("children", []), "")
	_resolve_tuples()
	var scope = _new_scope(null)
	_walk_members(ast.get("children", []), scope, "")
	_flow_members(ast.get("children", []), _new_scope(null), "")
	ast["analyzer_errors"] = _errors
	ast["analyzer_warnings"] = _warnings
	_update_user_files(ast)
	ast["analyzer_written"] = _written
	return {"ast": ast, "errors": _errors, "warnings": _warnings}


## Ensures the native type database (types_info/builtin, classes,
## index.json) exists, dumping it on demand into _write_base. On failure
## records a "native_types" error, prints it and returns false, so
## analyze() returns early with just that error.
func _ensure_native_types() -> bool:
	var d = NativeDumper.new()
	d.output_base = _write_base
	if d.ensure_present():
		return true
	var msg: String = "Native type info missing and dump failed: " + str(d.last_error)
	push_error(msg)
	_error(ERR_NATIVE_TYPES, msg, 0, 0, "")
	return false


## Directory holding this script (res:// form preferred), used as the
## anchor to discover the project root.
func _analyzer_anchor_dir() -> String:
	var self_path = get_script().resource_path
	var self_dir = self_path.get_base_dir()
	if self_dir == "":
		self_dir = "res://"
	if FileAccess.file_exists(self_dir + "/gnumaru_godot_native_types_info_dumper.gd"):
		return self_dir
	if self_path.begins_with("res://") and FileAccess.file_exists("res://gnumaru_godot_native_types_info_dumper.gd"):
		return "res://"
	return self_dir


func _compute_write_base(root: String) -> String:
	if root != "":
		var r = root
		if r.ends_with("/") and r.length() > 1:
			r = r.substr(0, r.length() - 1)
		return r + "/types_info"
	return "types_info"


## Handles the file header comment: a @deprecated tag here marks
## the whole script deprecated (root-level annotation).
func _scan_header(ast: Dictionary) -> void:
	var header: Variant = ast.get("header_comment", null)
	if header is Dictionary and str((header as Dictionary).get("type", "")) == "TYPE_INFO":
		var tag = _find_deprecated(str((header as Dictionary).get("value", "")))
		if not tag.is_empty():
			_script_deprecated = {"message": str(tag.get("message", "")), "line": int((header as Dictionary).get("line", 0))}
		if not _find_private(str((header as Dictionary).get("value", ""))).is_empty():
			_error(ERR_PRIVATE_MISPLACED, "@private cannot be used at the file root, only on members inside a class body", int((header as Dictionary).get("line", 0)), int((header as Dictionary).get("column", 0)), "")
		if not _find_return(str((header as Dictionary).get("value", ""))).is_empty():
			_error(ERR_RETURN_MISPLACED, "@return can only precede a function or lambda declaration", int((header as Dictionary).get("line", 0)), int((header as Dictionary).get("column", 0)), "")
		if not _find_var(str((header as Dictionary).get("value", ""))).is_empty():
			_error(ERR_VAR_MISPLACED, "@var can only precede a variable or constant declaration, or redefine a variable inside a function body", int((header as Dictionary).get("line", 0)), int((header as Dictionary).get("column", 0)), "")
		if not _find_param(str((header as Dictionary).get("value", ""))).is_empty():
			_error(ERR_PARAM_MISPLACED, "@param can only precede function/lambda parameters or the function/lambda declaration using them", int((header as Dictionary).get("line", 0)), int((header as Dictionary).get("column", 0)), "")
		if not _find_tuple(str((header as Dictionary).get("value", ""))).is_empty():
			_error(ERR_TUPLE_MISPLACED, "@tuple definitions belong at the top level of the script", int((header as Dictionary).get("line", 0)), int((header as Dictionary).get("column", 0)), "")


# ------------------------------------------------------------- tag scan

## Extracts a "@name" tag from a comment value. Returns {} when
## absent, else {"message": rest-of-line, "line": offset}. Only the
## first occurrence counts; only same-line text is read for now.
## The `@` must start the value or follow `#`, space or tab, and the
## name must match exactly (so "@private" never matches "@privates").
func _find_tag(value: String, name: String) -> Dictionary:
	var i = 0
	while i < value.length():
		if value.unicode_at(i) != 64:
			i += 1
			continue
		if i > 0:
			var left = value.unicode_at(i - 1)
			if left != 35 and left != 32 and left != 9:
				i += 1
				continue
		var j = i + 1
		var word = ""
		while j < value.length() and _is_tag_char(value.unicode_at(j)):
			word += value.substr(j, 1)
			j += 1
		if word != name:
			i += 1
			continue
		if j < value.length() and _is_tag_char(value.unicode_at(j)):
			i += 1
			continue
		var msg = ""
		var k = j
		while k < value.length() and value.unicode_at(k) != 10:
			msg += value.substr(k, 1)
			k += 1
		msg = msg.strip_edges()
		if msg.begins_with(":"):
			msg = msg.substr(1).strip_edges()
		return {"message": msg, "line": 0}
	return {}


func _find_deprecated(value: String) -> Dictionary:
	return _find_tag(value, "deprecated")


func _find_private(value: String) -> Dictionary:
	return _find_tag(value, "private")


func _is_tag_char(c: int) -> bool:
	if c >= 65 and c <= 90:
		return true
	if c >= 97 and c <= 122:
		return true
	if c >= 48 and c <= 57:
		return true
	return c == 95


func _has_deprecated_tag(tok: Dictionary) -> Dictionary:
	if str(tok.get("type", "")) != "TYPE_INFO":
		return {}
	return _find_deprecated(str(tok.get("value", "")))


func _has_private_tag(tok: Dictionary) -> Dictionary:
	if str(tok.get("type", "")) != "TYPE_INFO":
		return {}
	return _find_private(str(tok.get("value", "")))


func _find_return(value: String) -> Dictionary:
	return _find_tag(value, "return")


func _has_return_tag(tok: Dictionary) -> Dictionary:
	if str(tok.get("type", "")) != "TYPE_INFO":
		return {}
	return _find_return(str(tok.get("value", "")))


## Looks for @return in a node's leading_comments (first hit wins).
func _leading_return(node: Dictionary) -> Dictionary:
	for c in node.get("leading_comments", []):
		if c is Dictionary:
			var tag = _has_return_tag(c)
			if not tag.is_empty():
				tag["line"] = int((c as Dictionary).get("line", 0))
				return tag
	return {}


func _has_any_return_tag(node: Dictionary) -> bool:
	for c in node.get("leading_comments", []):
		if c is Dictionary and not _has_return_tag(c).is_empty():
			return true
	return false


func _find_var(value: String) -> Dictionary:
	return _find_tag(value, "var")


func _has_var_tag(tok: Dictionary) -> Dictionary:
	if str(tok.get("type", "")) != "TYPE_INFO":
		return {}
	return _find_var(str(tok.get("value", "")))


func _has_any_var_tag(node: Dictionary) -> bool:
	for c in node.get("leading_comments", []):
		if c is Dictionary and not _has_var_tag(c).is_empty():
			return true
	return false


# ------------------------------------------------------- @param helpers

func _find_param(value: String) -> Dictionary:
	return _find_tag(value, "param")


func _has_param_tag(tok: Dictionary) -> Dictionary:
	if str(tok.get("type", "")) != "TYPE_INFO":
		return {}
	return _find_param(str(tok.get("value", "")))


func _has_any_param_tag(node: Dictionary) -> bool:
	for c in node.get("leading_comments", []):
		if c is Dictionary and not _has_param_tag(c).is_empty():
			return true
	return false


# ------------------------------------------------------- @tuple helpers

func _find_tuple(value: String) -> Dictionary:
	return _find_tag(value, "tuple")


func _has_tuple_tag(tok: Dictionary) -> Dictionary:
	if str(tok.get("type", "")) != "TYPE_INFO":
		return {}
	return _find_tuple(str(tok.get("value", "")))


func _has_any_tuple_tag(node: Dictionary) -> bool:
	for c in node.get("leading_comments", []):
		if c is Dictionary and not _has_tuple_tag(c).is_empty():
			return true
	return false


## Parses an @tuple message ("Name COUNT item...") into {"ok","name",
## "size","items","raw"} or {"ok": false, "error"}. COUNT is mandatory
## and must equal the item count (checked by the caller against the
## parsed words). Items stay raw here (unions, `*`, `variant`).
static func _parse_tuple_spec(raw_msg: String) -> Dictionary:
	var words := _split_words(raw_msg.strip_edges())
	if words.size() < 2:
		return {"ok": false, "error": "@tuple needs a name and an explicit size: '# @tuple TupleName 5 int|string float|bool object variant *'"}
	var tname := str(words[0])
	if not _is_type_name(tname):
		return {"ok": false, "error": "@tuple has an invalid name '" + tname + "'"}
	var count_word := str(words[1])
	if count_word == "":
		return {"ok": false, "error": "@tuple needs an explicit size after the name"}
	for i in range(count_word.length()):
		var ch := count_word.unicode_at(i)
		if ch < 48 or ch > 57:
			return {"ok": false, "error": "@tuple size must be a non-negative integer, got '" + count_word + "'"}
	var items: Array = []
	for w in words.slice(2):
		items.append(str(w))
	return {"ok": true, "name": tname, "size": int(count_word), "items": items, "raw": raw_msg.strip_edges()}


## Pre-scan (before _scan): collects @tuple raw definitions from
## top-level standalone comments and top-level leadings so name
## lookups stay order-free. Full validation happens in _resolve_tuples.
func _prescan_tuples(ast: Dictionary) -> void:
	for child in ast.get("children", []):
		if not (child is Dictionary):
			continue
		if str((child as Dictionary).get("type", "")) == "TYPE_INFO":
			_collect_tuple_node(child as Dictionary)
			continue
		for c in (child as Dictionary).get("leading_comments", []):
			if c is Dictionary:
				_collect_tuple_node(c)


## Records every @tuple tag in one comment value as raw material.
## Malformed tags error immediately and are dropped; valid ones queue
## under their name (duplicates resolved in _resolve_tuples).
func _collect_tuple_node(tok: Dictionary) -> void:
	if str(tok.get("type", "")) != "TYPE_INFO":
		return
	var tok_line := int(tok.get("line", 0))
	var li := 0
	for line in str(tok.get("value", "")).split("\n"):
		var tag := _find_tag(line, "tuple")
		if not tag.is_empty():
			var spec := _parse_tuple_spec(str(tag.get("message", "")))
			if not bool(spec.get("ok", false)):
				_error(ERR_TUPLE_MALFORMED, str(spec.get("error", "")), tok_line + li, 0, "")
			else:
				var tname := str(spec.get("name", ""))
				var raw := {"spec": spec, "line": tok_line + li}
				if not _tuples.has(tname):
					_tuples[tname] = {"resolved": false, "raws": [raw]}
				else:
					((_tuples[tname] as Dictionary).get("raws", []) as Array).append(raw)
		li += 1


## Second pass (after _scan, before _walk): validates definitions
## (counts, duplicates, conflicts, item types incl. forward tuple
## refs) and writes their JSON files.
func _resolve_tuples() -> void:
	_ensure_user_dir()
	for tname in _tuples.keys():
		var entry: Dictionary = _tuples[tname]
		if bool(entry.get("resolved", false)):
			continue
		var raws: Array = entry.get("raws", [])
		if raws.is_empty():
			continue
		var first: Dictionary = raws[0]
		var spec: Dictionary = first.get("spec", {})
		if raws.size() > 1:
			_error(ERR_TUPLE_CONFLICT, "@tuple '" + tname + "' is defined more than once", int(first.get("line", 0)), 0, "")
			continue
		var clash := _tuple_conflict(tname)
		if clash != "":
			_error(ERR_TUPLE_CONFLICT, "@tuple '" + tname + "' conflicts with " + clash, int(first.get("line", 0)), 0, "")
			continue
		var items: Array = []
		var ok := true
		if (spec.get("items", []) as Array).size() != int(spec.get("size", -1)):
			_error(ERR_TUPLE_MALFORMED, "@tuple '" + tname + "' declares size " + str(spec.get("size", 0)) + " but lists " + str((spec.get("items", []) as Array).size()) + " items", int(first.get("line", 0)), 0, "")
			ok = false
		else:
			for w in spec.get("items", []):
				var item := _parse_tuple_item(str(w), int(first.get("line", 0)))
				if item.is_empty():
					ok = false
					break
				items.append(item)
		if not ok:
			continue
		entry["resolved"] = true
		entry["spec"] = {"ok": true, "name": tname, "size": int(spec.get("size", 0)), "items": items, "raw": str(spec.get("raw", "")), "line": int(first.get("line", 0))}
		_write_tuple_file(tname)


## Parses one tuple item word: `*` (any), `variant` (unknown marker,
## normalized to Variant), or a |-union of known names (tuple refs
## allowed: all names were pre-scanned). {} + error on failure.
func _parse_tuple_item(word: String, line: int) -> Dictionary:
	if word == "*":
		return {"types": [], "any": true}
	var raw := word
	if word == "variant":
		raw = "Variant"
	var types: Array = []
	for arm in raw.split("|"):
		var aname := str(arm).strip_edges()
		if aname == "" or aname == "void" or not _is_type_name(aname):
			_error(ERR_TUPLE_MALFORMED, "@tuple has an invalid type '" + str(arm) + "'", line, 0, "")
			return {}
		if not _type_known(aname) and not _tuples.has(aname):
			_error(ERR_TUPLE_UNKNOWN_TYPE, "@tuple has unknown type '" + aname + "'", line, 0, "")
			return {}
		types.append(aname)
	if types.is_empty():
		_error(ERR_TUPLE_MALFORMED, "@tuple has an empty type", line, 0, "")
		return {}
	return {"types": types, "any": false}


## Why a tuple name cannot be defined ("" when free). Existing tuple
## JSONs (same kind) are fine: idempotent rewrites. NOTE: not via
## _type_known (the name itself is already registered there).
func _tuple_conflict(tname: String) -> String:
	for key in _members.keys():
		var table: Dictionary = _members[key]
		if table.has(tname):
			return "script member '" + tname + "' (" + str((table[tname] as Dictionary).get("kind", "")) + ")"
	if _members.has(tname):
		return "script class '" + tname + "'"
	if tname == _script_class and tname != "":
		return "the script class name"
	if _type_file_exists(tname):
		var info := _read_json(_write_base + "/user/" + tname + ".json")
		if not info.is_empty() and str(info.get("kind", "")) == "tuple":
			return ""
		return "an existing type '" + tname + "'"
	return ""


## Resolved tuple definition {size, items} or {} (in-memory first,
## then same-kind JSON files, both cached).
func _tuple_def(tname: String) -> Dictionary:
	if _tuples.has(tname):
		var entry: Dictionary = _tuples[tname]
		if bool(entry.get("resolved", false)):
			var spec: Dictionary = entry.get("spec", {})
			if bool(spec.get("ok", false)) and spec.has("items"):
				return {"size": int(spec.get("size", 0)), "items": spec.get("items", [])}
	var info := _type_info(tname)
	if not info.is_empty() and str(info.get("kind", "")) == "tuple":
		return {"size": int(info.get("size", 0)), "items": info.get("tuple_items", [])}
	return {}


## Splits an array literal value into top-level element token arrays.
## Returns {"literal", "elements"} (elements may be empty for `[]`;
## non-literals report literal=false).
func _tuple_lit_split(value: Variant) -> Dictionary:
	var toks := _as_tokens(value)
	if toks.is_empty():
		return {"literal": false, "elements": []}
	if not (toks[0] is Dictionary) or str((toks[0] as Dictionary).get("type", "")) != "LBRACKET":
		return {"literal": false, "elements": []}
	if toks.size() == 2:
		if (toks[1] is Dictionary) and str((toks[1] as Dictionary).get("type", "")) == "RBRACKET":
			return {"literal": true, "elements": []}
		return {"literal": false, "elements": []}
	if _match_close(toks, 0) != toks.size() - 1:
		return {"literal": false, "elements": []}
	var out: Array = []
	var cur: Array = []
	var depth := 0
	var seen := false
	var i := 1
	while i < toks.size() - 1:
		var t: Variant = toks[i]
		var ty := ""
		if t is Dictionary:
			ty = str((t as Dictionary).get("type", ""))
		if ty == "LPAREN" or ty == "LBRACKET" or ty == "LBRACE":
			depth += 1
			cur.append(t)
		elif ty == "RPAREN" or ty == "RBRACKET" or ty == "RBRACE":
			depth -= 1
			cur.append(t)
		elif ty == "COMMA" and depth == 0:
			out.append(cur)
			cur = []
			seen = true
		else:
			cur.append(t)
		i += 1
	if not cur.is_empty() or not seen:
		out.append(cur)
	return {"literal": true, "elements": out}


## Infers a single literal token ("" when not a plain literal).
static func _infer_lit_token(tok: Variant) -> String:
	if not (tok is Dictionary):
		return ""
	match str((tok as Dictionary).get("type", "")):
		"INT":
			return "int"
		"FLOAT":
			return "float"
		"STRING":
			return "String"
		"BOOL":
			return "bool"
	return ""


## Infers an element token array when it is a single plain literal.
static func _infer_lit_elem(elem: Variant) -> String:
	if elem is Array and (elem as Array).size() == 1:
		return _infer_lit_token((elem as Array)[0])
	return ""


## Literal-ish compatibility for tuple elements (mirrors the semantic
## numeric/string families; NULL and complex elements skip).
func _lit_compatible(et: String, mname: String) -> bool:
	if et == mname:
		return true
	if et in ["int", "float"] and mname in ["int", "float"]:
		return true
	if et in ["String", "StringName", "NodePath"] and mname in ["String", "StringName", "NodePath"]:
		return true
	return _derives_from(et, mname)


## Checks an initializer value against a tuple vartype (length +
## per-index literal elements). Non-literals skip (unprovable).
func _check_tuple_value(tname: String, value: Variant, line: int, owner: String) -> void:
	var def := _tuple_def(tname)
	if def.is_empty():
		return
	var lit := _tuple_lit_split(value)
	if not bool(lit.get("literal", false)):
		return
	_check_tuple_elements(tname, def, lit.get("elements", []), line, owner)


## Element-wise check of a literal element list against a definition.
func _check_tuple_elements(tname: String, def: Dictionary, elems: Array, line: int, owner: String) -> void:
	var items: Array = def.get("items", [])
	if elems.size() != int(def.get("size", -1)):
		_error(ERR_TUPLE_MISMATCH, "tuple '" + tname + "' expects " + str(def.get("size", 0)) + " elements, got " + str(elems.size()), line, 0, owner)
		return
	for idx in range(elems.size()):
		var et := _infer_lit_elem(elems[idx])
		if et == "":
			continue
		var item: Dictionary = items[idx]
		if bool(item.get("any", false)):
			continue
		var ok := false
		for m in item.get("types", []):
			if _lit_compatible(et, str(m)):
				ok = true
				break
		if not ok:
			_error(ERR_TUPLE_MISMATCH, "tuple '" + tname + "' element " + str(idx) + " expects '" + _show_types(item.get("types", [])) + "', got '" + et + "'", line, 0, owner)


## Writes one user/<Name>.json per resolved tuple (minimal, class
## compatible: shared keys plus size/tuple_items).
func _write_tuple_file(tname: String) -> void:
	var entry: Dictionary = _tuples[tname]
	var spec: Dictionary = entry.get("spec", {})
	var info := {
		"name": tname,
		"kind": "tuple",
		"class_name": "",
		"resource_path": _script_resource_path,
		"parent": "",
		"inheritance_chain": [tname],
		"size": int(spec.get("size", 0)),
		"tuple_items": spec.get("items", []),
		"enums": [],
		"constants": [],
		"signals": [],
		"fields": [],
		"static_methods": [],
		"instance_methods": [],
		"inner_classes": [],
	}
	_write_json(_write_base + "/user/" + tname + ".json", info)
	_written.append(_write_base + "/user/" + tname + ".json")


## Extracts every @tagname pair from one TYPE_INFO token into
## [{name,types,raw,line}] (consecutive lines merge into one token, so
## each line is scanned independently). Malformed pairs error out and
## are skipped. Shared by @var and @param.
func _extract_tok_tags(tok: Dictionary, owner: String, tagname: String, what: String, malformed_kind: String) -> Array:
	var out: Array = []
	if str(tok.get("type", "")) != "TYPE_INFO":
		return out
	var tok_line := int(tok.get("line", 0))
	var li := 0
	for line in str(tok.get("value", "")).split("\n"):
		var tag := _find_tag(line, tagname)
		if not tag.is_empty():
			var spec := _parse_var_spec(str(tag.get("message", "")), what)
			if not bool(spec.get("ok", false)):
				_error(malformed_kind, str(spec.get("error", "")), tok_line + li, 0, owner)
			else:
				out.append({"name": str(spec.get("name", "")), "types": spec.get("types", []), "raw": str(spec.get("raw", "")), "line": tok_line + li})
		li += 1
	return out


## Extracts every @var pair from a node's leading_comments.
func _extract_var_tags(node: Dictionary, owner: String) -> Array:
	var out: Array = []
	for c in node.get("leading_comments", []):
		if c is Dictionary:
			for spec in _extract_tok_tags(c, owner, "var", "@var", ERR_VAR_MALFORMED):
				out.append(spec)
	return out


## Extracts every @param pair from a node's leading_comments into
## [{name,types,raw,line}].
func _extract_param_tags(node: Dictionary, owner: String) -> Array:
	var out: Array = []
	for c in node.get("leading_comments", []):
		if c is Dictionary:
			for spec in _extract_tok_tags(c, owner, "param", "@param", ERR_PARAM_MALFORMED):
				out.append(spec)
	return out


## Finds a PARAM node by name. {} when absent.
static func _find_param_node(params: Variant, pname: String) -> Dictionary:
	if params is Array:
		for p in params:
			if p is Dictionary:
				var pd: Dictionary = p
				if str(pd.get("type", "")) == "PARAM" and str(pd.get("name", "")) == pname:
					return pd
	return {}


## Narrows one @param pair against a PARAM node: known members
## narrowing the declared vartype (untyped params accept anything).
## Stamps pnode["param_ann"].
func _check_param_pair(pair: Dictionary, pnode: Dictionary, owner: String) -> void:
	var line := int(pair.get("line", int(pnode.get("line", 0))))
	for m in pair.get("types", []):
		if not _type_known(str(m)):
			_error(ERR_PARAM_UNKNOWN_TYPE, "@param has unknown type '" + str(m) + "'", line, 0, owner)
			return
	var ref := _vartype_name(pnode)
	if ref != "" and ref != "Variant" and ref != "dynamic":
		for m in pair.get("types", []):
			if str(m) != ref and not _derives_from(str(m), ref):
				_error(ERR_PARAM_MISMATCH, "cannot use @param type '" + str(m) + "' for parameter '" + str(pair.get("name", "")) + "' declared as '" + ref + "' ('" + str(m) + "' is neither '" + ref + "' nor a subclass of it)", line, 0, owner)
	pnode["param_ann"] = {"name": str(pair.get("name", "")), "types": pair.get("types", []), "raw": str(pair.get("raw", "")), "line": line}


## Applies @param pairs to a whole parameter list (before-func/lambda
## use). Each pair must name one of the params.
func _apply_param_pairs(pairs: Array, params: Variant, fn_display: String, owner: String) -> void:
	for pair in pairs:
		if not (pair is Dictionary):
			continue
		var pnode := _find_param_node(params, str((pair as Dictionary).get("name", "")))
		if pnode.is_empty():
			_error(ERR_PARAM_UNKNOWN, "@param '" + str((pair as Dictionary).get("name", "")) + "' does not match any parameter of function " + fn_display, int((pair as Dictionary).get("line", 0)), 0, owner)
			continue
		_check_param_pair(pair, pnode, owner)


## Applies @param pairs to a single PARAM node (multiline-list use).
## Each pair must name this parameter.
func _apply_param_single(pairs: Array, pnode: Dictionary, owner: String) -> void:
	for pair in pairs:
		if not (pair is Dictionary):
			continue
		if str((pair as Dictionary).get("name", "")) != str(pnode.get("name", "")):
			_error(ERR_PARAM_UNKNOWN, "@param '" + str((pair as Dictionary).get("name", "")) + "' does not match parameter '" + str(pnode.get("name", "")) + "'", int((pair as Dictionary).get("line", 0)), 0, owner)
			continue
		_check_param_pair(pair, pnode, owner)


## @param on a function/lambda carrier: FUNC_DECL, LAMBDA node, or a
## statement whose value is a lambda (VAR/CONST/EXPR_STMT).
func _mark_param_carrier(stmt_node: Dictionary, fn_node: Dictionary, owner: String) -> void:
	var pairs := _extract_param_tags(stmt_node, owner)
	if pairs.is_empty():
		return
	_apply_param_pairs(pairs, fn_node.get("params", []), _fn_display(fn_node), owner)


# ------------------------------------------------------- @var helpers

## Single type name behind a vartype TYPE_REF, or "" when absent or
## complex (Array[int], dotted, ...): only simple names are compared.
static func _vartype_name(decl: Dictionary) -> String:
	var vt: Variant = decl.get("vartype", null)
	if not (vt is Dictionary):
		return ""
	var text := ""
	for t in (vt as Dictionary).get("tokens", []):
		if t is Dictionary:
			text += str((t as Dictionary).get("value", ""))
	text = text.strip_edges()
	if _is_type_name(text):
		return text
	return ""


## Infers a variable type from a simple initializer value:
## literals, arrays, dictionaries, known-type constructors (Color(...),
## Node.new()), node paths and lambdas (Callable). "" when unknown.
## Mirrors the user's rule, not the engine: plain `=` (and missing
## values) mean Variant and are handled by the caller, never here.
func _infer_var_value(value: Variant) -> String:
	if value is Dictionary and str((value as Dictionary).get("type", "")) == "LAMBDA":
		return "Callable"
	var toks := _as_tokens(value)
	if toks.is_empty():
		return ""
	if toks.size() == 1 and toks[0] is Dictionary:
		var one: Dictionary = toks[0]
		match str(one.get("type", "")):
			"INT":
				return "int"
			"FLOAT":
				return "float"
			"STRING":
				return "String"
			"BOOL":
				return "bool"
			"STRING_NAME":
				return "StringName"
			"NODE_PATH":
				return "NodePath"
			"GET_NODE", "UNIQUE_NAME":
				return "Node"
	if toks.size() >= 1 and toks[0] is Dictionary:
		var first := str((toks[0] as Dictionary).get("type", ""))
		if first == "LBRACKET":
			return "Array"
		if first == "LBRACE":
			return "Dictionary"
	if toks.size() >= 2 and toks[0] is Dictionary and toks[1] is Dictionary:
		var t0: Dictionary = toks[0]
		var t1: Dictionary = toks[1]
		var t0t := str(t0.get("type", ""))
		if (t0t == "IDENTIFIER" or t0t == "BUILTIN_TYPE") and str(t1.get("type", "")) == "LPAREN":
			var cname := str(t0.get("value", ""))
			if _type_known(cname):
				return cname
	if toks.size() >= 3 and toks[0] is Dictionary and toks[1] is Dictionary and toks[2] is Dictionary:
		var n0: Dictionary = toks[0]
		var n1: Dictionary = toks[1]
		var n2: Dictionary = toks[2]
		if str(n0.get("type", "")) == "IDENTIFIER" and str(n1.get("type", "")) == "DOT" and str(n2.get("value", "")) == "new":
			var nname := str(n0.get("value", ""))
			if _type_known(nname):
				return nname
	return ""


## Reference type of a VAR/CONST declaration node for @var narrowing:
## explicit vartype first; then `:=`/const inference from the value;
## plain `=` (or missing value) means "dynamic" (no promises: checks
## that need a type skip it, unlike explicit "Variant" which is strict).
## "" only when inference fails (check skipped).
func _var_reference(node: Dictionary, is_const: bool) -> String:
	var vt := _vartype_name(node)
	if vt != "":
		return vt
	if is_const or str(node.get("op", "")) == ":=":
		return _infer_var_value(node.get("value", null))
	return "dynamic"


## Finds a method entry by name in static or instance lists.
## Returns {"returns"} or {}.
static func _engine_call(info: Dictionary, seg: String) -> Dictionary:
	for m in info.get("instance_methods", []):
		if m is Dictionary and str((m as Dictionary).get("name", "")) == seg:
			return {"returns": str((m as Dictionary).get("returns", ""))}
	for m in info.get("static_methods", []):
		if m is Dictionary and str((m as Dictionary).get("name", "")) == seg:
			return {"returns": str((m as Dictionary).get("returns", ""))}
	return {}


## Finds a readable member by name: fields ("type"), signals
## ("signal"), methods-as-values ("Callable"). With static_ctx also
## constants and enums ("int", plus "enumvals" carrying the closed
## value set for continuation). Returns {"type", ...} or {} when absent.
static func _engine_read(info: Dictionary, seg: String, static_ctx: bool) -> Dictionary:
	for f in info.get("members", []):
		if f is Dictionary and str((f as Dictionary).get("name", "")) == seg:
			return {"type": str((f as Dictionary).get("type", ""))}
	for p in info.get("properties", []):
		if p is Dictionary and str((p as Dictionary).get("name", "")) == seg:
			return {"type": str((p as Dictionary).get("type", ""))}
	for s in info.get("signals", []):
		if s is Dictionary and str((s as Dictionary).get("name", "")) == seg:
			return {"type": "signal"}
	for m in info.get("instance_methods", []):
		if m is Dictionary and str((m as Dictionary).get("name", "")) == seg:
			return {"type": "Callable"}
	for m in info.get("static_methods", []):
		if m is Dictionary and str((m as Dictionary).get("name", "")) == seg:
			return {"type": "Callable"}
	if static_ctx:
		for e in info.get("enums", []):
			if e is Dictionary and str((e as Dictionary).get("name", "")) == seg:
				return {"type": "int", "enumvals": _enum_value_names(e), "enumname": str((e as Dictionary).get("name", ""))}
			for v in (e as Dictionary).get("values", []):
				if v is Dictionary and str((v as Dictionary).get("name", "")) == seg:
					return {"type": "int", "enumvals": _enum_value_names(e), "enumname": str((e as Dictionary).get("name", ""))}
		for c in info.get("constants", []):
			if c is Dictionary and str((c as Dictionary).get("name", "")) == seg:
				return {"type": ""}
	return {}


## Value names of an enum entry (engine or doc-merged shape).
static func _enum_value_names(entry: Dictionary) -> Array:
	var out: Array = []
	for v in entry.get("values", []):
		if v is Dictionary:
			out.append(str((v as Dictionary).get("name", "")))
		elif v is String:
			out.append(v)
	return out


# ------------------------------------------------------- @return helpers

static func _is_type_start(c: int) -> bool:
	if c >= 65 and c <= 90:
		return true
	if c >= 97 and c <= 122:
		return true
	if c == 95 or c >= 128:
		return true
	return false


static func _is_type_part(c: int) -> bool:
	if _is_type_start(c):
		return true
	return c >= 48 and c <= 57


## True for plain type identifiers ("Node", "int", "_Helper").
## Dotted/complex spellings are NOT @return members.
static func _is_type_name(name: String) -> bool:
	if name == "":
		return false
	if not _is_type_start(name.unicode_at(0)):
		return false
	for i in range(1, name.length()):
		if not _is_type_part(name.unicode_at(i)):
			return false
	return true


## Splits on whitespace runs (space/tab/newline), dropping empties.
static func _split_words(s: String) -> Array:
	var out: Array = []
	var cur := ""
	for i in range(s.length()):
		var c := s.unicode_at(i)
		if c == 32 or c == 9 or c == 10:
			if cur != "":
				out.append(cur)
				cur = ""
		else:
			cur += s.substr(i, 1)
	if cur != "":
		out.append(cur)
	return out


## Parses a type spec into {"ok","types","void","raw"} or
## {"ok": false, "error"}. Shape: "void" alone, or one or more
## |-separated type identifiers. "void" cannot be combined.
## `what` names the annotation for messages ("@return", "@var").
static func _parse_return_spec(raw_msg: String, what := "@return") -> Dictionary:
	var raw := raw_msg.strip_edges()
	if raw == "":
		return {"ok": false, "error": what + " needs a type: 'void' or a type name like 'Node' (unions join with '|', e.g. 'Object|String|int')"}
	var parts := raw.split("|")
	var types: Array = []
	for p in parts:
		var name := str(p).strip_edges()
		if name == "":
			return {"ok": false, "error": what + " has an empty type in '" + raw + "'"}
		if name == "void":
			if parts.size() > 1:
				return {"ok": false, "error": what + " 'void' cannot be combined with other types in '" + raw + "'"}
			return {"ok": true, "types": [], "void": true, "raw": raw}
		if not _is_type_name(name):
			return {"ok": false, "error": what + " has an invalid type name '" + name + "'"}
		types.append(name)
	return {"ok": true, "types": types, "void": false, "raw": raw}


## Parses an @var/@param message ("name Type|Union") into
## {"ok","name","types","raw"} or {"ok": false, "error"}.
## "void" is rejected: neither variables nor parameters can be void.
static func _parse_var_spec(raw_msg: String, what := "@var") -> Dictionary:
	var raw := raw_msg.strip_edges()
	if raw == "":
		return {"ok": false, "error": what + " needs a name and a type: '# " + what + " myvar int|float'"}
	var words := _split_words(raw)
	if words.size() < 2:
		return {"ok": false, "error": what + " needs a name and a type: '# " + what + " myvar int|float'"}
	var vname := str(words[0])
	if not _is_type_name(vname):
		return {"ok": false, "error": what + " has an invalid name '" + vname + "'"}
	var rest := raw.substr(vname.length()).strip_edges()
	var spec := _parse_return_spec(rest, what)
	if not bool(spec.get("ok", false)):
		return spec
	if bool(spec.get("void", false)):
		return {"ok": false, "error": what + " 'void' is not a valid variable type"}
	return {"ok": true, "name": vname, "types": spec.get("types", []), "raw": str(spec.get("raw", ""))}


## Full info Dictionary of a type from its JSON file (builtin, classes
## or user under _write_base), cached per analyze() call. {} when missing.
func _type_info(tname: String) -> Dictionary:
	if _type_cache.has(tname):
		return _type_cache[tname]
	for sub in ["builtin", "classes", "user"]:
		var info := _read_json(_write_base + "/" + sub + "/" + tname + ".json")
		if not info.is_empty():
			_type_cache[tname] = info
			return info
	_type_cache[tname] = {}
	return {}


## True when a types_info file exists for the name (builtin, classes or
## user under _write_base). Results are cached per analyze() call.
func _type_file_exists(tname: String) -> bool:
	return not _type_info(tname).is_empty()


## inheritance_chain of a type from its JSON file ([] when unknown).
func _engine_chain(tname: String) -> Array:
	var chain: Array = _type_info(tname).get("inheritance_chain", [])
	return chain


## A @return member is known when it is the script class, a script class
## or enum member, or a types_info file exists for it.
func _type_known(tname: String) -> bool:
	if tname != "" and tname == _script_class:
		return true
	if _tuples.has(tname):
		return true
	for key in _members.keys():
		var table: Dictionary = _members[key]
		if table.has(tname) and str((table[tname] as Dictionary).get("kind", "")) in ["class", "enum"]:
			return true
	return _type_file_exists(tname)


static func _base_simple(dotted: String) -> String:
	if "." in dotted:
		return dotted.substr(dotted.rfind(".") + 1)
	return dotted


## Joins an EXTENDS path (token dicts with DOT separators) into a
## dotted name, ignoring anything else.
static func _dotted_path(parts: Variant) -> String:
	var out: Array = []
	if parts is Array:
		for p in parts:
			if p is Dictionary and str((p as Dictionary).get("type", "")) != "DOT":
				out.append(str((p as Dictionary).get("value", "")))
	return ".".join(out)


## True when member equals declared or inherits from it: engine chain
## first, then the script extends walk, then the engine chain of the
## terminal script base (e.g. Child extends Base extends Node).
func _derives_from(member: String, declared: String) -> bool:
	if member == declared:
		return true
	if declared in _engine_chain(member):
		return true
	return _script_derives(member, declared)


func _script_derives(child: String, ancestor: String) -> bool:
	var key := _resolve_private_owner(child, "")
	var seen := {}
	var guard := 0
	while key != "" and not seen.has(key) and guard < 32:
		seen[key] = true
		guard += 1
		var base := str(_class_extends.get(key, ""))
		if base == "":
			return false
		if base == ancestor or _base_simple(base) == ancestor:
			return true
		if ancestor in _engine_chain(_base_simple(base)):
			return true
		key = _resolve_private_owner(base, key)
	return false


## Single type name behind a "->" TYPE_REF ("void" included), or "" when
## absent or complex (Array[int], dotted, ...): only simple arrows are
## compared against @return.
static func _arrow_name(ref: Variant) -> String:
	if not (ref is Dictionary):
		return ""
	var text := ""
	for t in (ref as Dictionary).get("tokens", []):
		if t is Dictionary:
			text += str((t as Dictionary).get("value", ""))
	text = text.strip_edges()
	if text == "void":
		return "void"
	if _is_type_name(text):
		return text
	return ""


## Validates one @return tag and stamps fn_node["return_ann"].
## Malformed or unknown specs error out and record nothing.
func _attach_return(fn_node: Dictionary, tag: Dictionary, owner: String) -> void:
	var spec := _parse_return_spec(str(tag.get("message", "")))
	var line := int(tag.get("line", int(fn_node.get("line", 0))))
	var col := int(fn_node.get("column", 0))
	if not bool(spec.get("ok", false)):
		_error(ERR_RETURN_MALFORMED, str(spec.get("error", "")), line, col, owner)
		return
	if not bool(spec.get("void", false)):
		for m in spec.get("types", []):
			if not _type_known(str(m)):
				_error(ERR_RETURN_UNKNOWN, "@return has unknown type '" + str(m) + "'", line, col, owner)
				return
	fn_node["return_ann"] = {"types": spec.get("types", []), "void": bool(spec.get("void", false)), "raw": str(spec.get("raw", "")), "line": line}


## Marks a FUNC_DECL node (@return allowed in any position: a nested
## named function is still a function declaration).
func _mark_return_func(fn_node: Dictionary, owner: String) -> void:
	var tag := _leading_return(fn_node)
	if tag.is_empty():
		return
	_attach_return(fn_node, tag, owner)


## Marks @return on a value statement (VAR_DECL/CONST_DECL): attaches
## to a LAMBDA value, errors otherwise.
func _mark_return_stmt(stmt_node: Dictionary, value: Variant, owner: String) -> void:
	if value is Dictionary and str((value as Dictionary).get("type", "")) == "LAMBDA":
		_attach_return(value, _leading_return(stmt_node), owner)
	else:
		_error(ERR_RETURN_MISPLACED, "@return can only precede a function or lambda declaration", int(stmt_node.get("line", 0)), int(stmt_node.get("column", 0)), owner)


## Validates one @var tag against a VAR/CONST declaration node and
## stamps decl_node["var_ann"]. Name must equal the declared one; every
## type member must be known and narrow the declared/inferred type.
func _attach_var_decl(decl_node: Dictionary, spec: Dictionary, owner: String, is_const: bool) -> void:
	var line := int(spec.get("line", int(decl_node.get("line", 0))))
	var col := int(decl_node.get("column", 0))
	var vname := str(spec.get("name", ""))
	if vname != str(decl_node.get("name", "")):
		_error(ERR_VAR_UNKNOWN, "@var '" + vname + "' does not match declared variable '" + str(decl_node.get("name", "")) + "'", line, col, owner)
		return
	for m in spec.get("types", []):
		if not _type_known(str(m)):
			_error(ERR_VAR_UNKNOWN_TYPE, "@var has unknown type '" + str(m) + "'", line, col, owner)
			return
	var ref := _var_reference(decl_node, is_const)
	if ref != "" and ref != "Variant" and ref != "dynamic":
		for m in spec.get("types", []):
			if str(m) != ref and not _derives_from(str(m), ref):
				_error(ERR_VAR_MISMATCH, "cannot use @var type '" + str(m) + "' for variable '" + vname + "' declared as '" + ref + "' ('" + str(m) + "' is neither '" + ref + "' nor a subclass of it)", line, col, owner)
	decl_node["var_ann"] = {"name": vname, "types": spec.get("types", []), "raw": str(spec.get("raw", "")), "line": line}


## Marks a VAR_DECL/CONST_DECL node (@var allowed in any position).
## Every pair in the leading block is validated (pairs for other
## variables error against this declaration).
func _mark_var_decl(decl_node: Dictionary, owner: String) -> void:
	for spec in _extract_var_tags(decl_node, owner):
		if spec is Dictionary:
			_attach_var_decl(decl_node, spec, owner, str(decl_node.get("type", "")) == "CONST_DECL")


## Kind string of a name in scope (walks parents), "" when absent.
func _scope_kind(scope: Variant, name: String) -> String:
	var cur: Variant = scope
	while cur is Dictionary:
		var names: Dictionary = (cur as Dictionary).get("names", {})
		if names.has(name):
			return str(names[name])
		cur = (cur as Dictionary).get("parent", null)
	return ""


## First VAR/CONST declaration named `name` under body, never crossing
## a nested function/class/accessor boundary. {} when absent.
func _find_body_decl(body: Variant, name: String) -> Dictionary:
	if body is Array:
		for e in body:
			var hit := _find_body_decl(e, name)
			if not hit.is_empty():
				return hit
		return {}
	if not (body is Dictionary):
		return {}
	var d: Dictionary = body
	var t := str(d.get("type", ""))
	if t == "FUNC_DECL" or t == "LAMBDA" or t == "CLASS_DECL" or t == "ACCESSOR":
		return {}
	if (t == "VAR_DECL" or t == "CONST_DECL") and str(d.get("name", "")) == name:
		return d
	for k in d.keys():
		if k in ["tokens", "args", "annotations", "leading_comments", "header_comment", "deprecated", "private", "return_ann", "var_ann", "param_ann", "analyzer_errors", "analyzer_warnings", "semantic_errors", "user_types_written"]:
			continue
		var hit2 := _find_body_decl(d[k], name)
		if not hit2.is_empty():
			return hit2
	return {}


## Member VAR/CONST declaration node under owner_key, {} when absent
## or another kind (functions, classes, ... are not variables).
func _member_var_node(owner_key: String, name: String) -> Dictionary:
	if not _members.has(owner_key):
		return {}
	var table: Dictionary = _members[owner_key]
	if not table.has(name):
		return {}
	var rec: Dictionary = table[name]
	if str(rec.get("kind", "")) not in ["variable", "constant"]:
		return {}
	var n: Variant = rec.get("node", {})
	if n is Dictionary:
		return n
	return {}


## Resolves a free-@var name to {"node","is_const","is_param"} for
## narrowing, {"bad": kind} for existing non-variables, {} when nothing
## matches. Scope-first (locals and params shadow members).
func _free_var_target(vname: String, fn_node: Dictionary, scope: Dictionary, owner: String) -> Dictionary:
	var kind := _scope_kind(scope, vname)
	if kind != "":
		if kind in ["func", "class", "signal"]:
			return {"bad": kind}
		if kind == "param":
			for p in fn_node.get("params", []):
				if p is Dictionary and str((p as Dictionary).get("name", "")) == vname:
					return {"node": p, "is_const": false, "is_param": true}
			return {"node": {}, "is_const": false, "is_param": true}
		var decl := _find_body_decl(fn_node.get("body", null), vname)
		if not decl.is_empty():
			return {"node": decl, "is_const": str(decl.get("type", "")) == "CONST_DECL", "is_param": false}
		return {"node": {}, "is_const": false, "is_param": false}
	var seen := {}
	for o in [owner, ""]:
		var key := str(o)
		if seen.has(key):
			continue
		seen[key] = true
		var n := _member_var_node(key, vname)
		if not n.is_empty():
			return {"node": n, "is_const": str(n.get("type", "")) == "CONST_DECL", "is_param": false}
	for o2 in [owner, ""]:
		var key2 := str(o2)
		if _members.has(key2) and (_members[key2] as Dictionary).has(vname):
			return {"bad": str(((_members[key2] as Dictionary)[vname] as Dictionary).get("kind", ""))}
	return {}


## Runs one free-@var spec against the visible variables.
func _check_free_var(spec: Dictionary, scope: Dictionary, owner: String, fn_node: Dictionary) -> void:
	var line := int(spec.get("line", 0))
	var vname := str(spec.get("name", ""))
	var target := _free_var_target(vname, fn_node, scope, owner)
	if target.is_empty():
		_error(ERR_VAR_UNKNOWN, "no variable '" + vname + "' in function " + _fn_display(fn_node), line, 0, owner)
		return
	if target.has("bad"):
		_error(ERR_VAR_UNKNOWN, "'" + vname + "' is a " + str(target.get("bad", "")) + ", not a variable", line, 0, owner)
		return
	for m in spec.get("types", []):
		if not _type_known(str(m)):
			_error(ERR_VAR_UNKNOWN_TYPE, "@var has unknown type '" + str(m) + "'", line, 0, owner)
			return
	var ref := ""
	var tnode: Dictionary = target.get("node", {})
	if bool(target.get("is_param", false)):
		ref = _vartype_name(tnode)
	elif not tnode.is_empty():
		ref = _var_reference(tnode, bool(target.get("is_const", false)))
	if ref != "" and ref != "Variant" and ref != "dynamic":
		for m in spec.get("types", []):
			if str(m) != ref and not _derives_from(str(m), ref):
				_error(ERR_VAR_MISMATCH, "cannot use @var type '" + str(m) + "' for variable '" + vname + "' declared as '" + ref + "' ('" + str(m) + "' is neither '" + ref + "' nor a subclass of it)", line, 0, owner)


## Collects free-@var specs under a function body: standalone TYPE_INFO
## nodes plus leading specs on non-declaration statements. Never crosses
## a nested function/class/accessor boundary (separate contexts) and
## never takes VAR/CONST leading specs (before-decl use, handled in
## _scan). Leading specs on any other statement (including a bare
## lambda statement) are free uses for the enclosing function.
func _free_vars_into(node: Variant, out: Array, owner: String) -> void:
	if node is Array:
		for e in node:
			_free_vars_into(e, out, owner)
		return
	if not (node is Dictionary):
		return
	var d: Dictionary = node
	var t := str(d.get("type", ""))
	if t == "TYPE_INFO":
		for spec in _extract_tok_tags(d, owner, "var", "@var", ERR_VAR_MALFORMED):
			out.append(spec)
		return
	if t == "FUNC_DECL" or t == "LAMBDA" or t == "CLASS_DECL" or t == "ACCESSOR":
		return
	if t == "VAR_DECL" or t == "CONST_DECL":
		return
	for spec in _extract_var_tags(d, owner):
		out.append(spec)
	for k in d.keys():
		if k in ["tokens", "args", "annotations", "leading_comments", "header_comment", "deprecated", "private", "return_ann", "var_ann", "param_ann", "analyzer_errors", "analyzer_warnings", "semantic_errors", "user_types_written", "value", "expr"]:
			continue
		_free_vars_into(d[k], out, owner)


## Runs the free-@var checks over a function body with its scope.
## fn_node null means "not a function" (accessor bodies): every spec
## found is misplaced.
func _process_free_vars(body: Variant, scope: Dictionary, owner: String, fn_node: Variant) -> void:
	var found: Array = []
	_free_vars_into(body, found, owner)
	for spec in found:
		if not (spec is Dictionary):
			continue
		if fn_node == null:
			_error(ERR_VAR_MISPLACED, "@var redefinition is only allowed inside a function body", int((spec as Dictionary).get("line", 0)), 0, owner)
			continue
		_check_free_var(spec, scope, owner, fn_node)


## Scope + free-@var pass for a lambda value reached through a
## statement (mirrors _walk_lambda scope building without walking the
## body, so no other rule changes behavior there).
func _check_lambda_free_vars(lam: Dictionary, scope: Dictionary, owner: String) -> void:
	var lscope = _new_scope(scope)
	for p in lam.get("params", []):
		if p is Dictionary:
			_scope_add(lscope, str((p as Dictionary).get("name", "")), "param")
	_collect_func_bindings(lam.get("body", null), lscope)
	_process_free_vars(lam.get("body", null), lscope, owner, lam)


## Runs the lambda free-@var pass when a statement value/expression is
## a LAMBDA node. No-op otherwise (takes Variant: values may be null).
func _check_value_lambda(v: Variant, scope: Dictionary, owner: String) -> void:
	if v is Dictionary and str((v as Dictionary).get("type", "")) == "LAMBDA":
		_check_lambda_free_vars(v, scope, owner)


## Collects RETURN_STMT nodes under body, never crossing a nested
## FUNC_DECL/LAMBDA boundary (their returns belong to the inner
## function, which gets its own check).
func _collect_returns(body: Variant) -> Array:
	var out: Array = []
	_collect_returns_into(body, out)
	return out


func _collect_returns_into(node: Variant, out: Array) -> void:
	if node is Array:
		for e in node:
			_collect_returns_into(e, out)
		return
	if not (node is Dictionary):
		return
	var d: Dictionary = node
	var t := str(d.get("type", ""))
	if t == "RETURN_STMT":
		out.append(d)
		return
	if t == "FUNC_DECL" or t == "LAMBDA":
		return
	for k in d.keys():
		if k in ["tokens", "args", "annotations", "leading_comments", "header_comment", "deprecated", "private", "return_ann", "var_ann", "param_ann", "analyzer_errors", "analyzer_warnings", "semantic_errors", "user_types_written"]:
			continue
		_collect_returns_into(d[k], out)


func _fn_display(fn_node: Dictionary) -> String:
	var fname := str(fn_node.get("name", ""))
	if fname == "":
		return "<lambda>"
	return "'" + fname + "'"


## Runs the @return checks for one function/lambda node: "->"
## compatibility first, then value/bare return presence. No-op without
## a recorded return_ann. Takes Variant: statement values may be null.
func _check_return_ann(fn_node: Variant, owner: String) -> void:
	if not (fn_node is Dictionary) or not (fn_node as Dictionary).has("return_ann"):
		return
	var fn: Dictionary = fn_node
	var ann: Dictionary = fn["return_ann"]
	var disp := _fn_display(fn)
	var arrow := _arrow_name(fn.get("return_type", null))
	var ann_void := bool(ann.get("void", false))
	if arrow != "":
		if ann_void and arrow != "void":
			_error(ERR_RETURN_MISMATCH, "cannot use @return 'void' with '-> " + arrow + "' on function " + disp, int(fn.get("line", 0)), int(fn.get("column", 0)), owner)
			return
		if not ann_void and arrow == "void":
			_error(ERR_RETURN_MISMATCH, "cannot use @return '" + str(ann.get("raw", "")) + "' with '-> void' on function " + disp, int(fn.get("line", 0)), int(fn.get("column", 0)), owner)
			return
		if not ann_void and arrow != "Variant":
			for m in ann.get("types", []):
				if str(m) != arrow and not _derives_from(str(m), arrow):
					_error(ERR_RETURN_MISMATCH, "cannot use @return '" + str(m) + "' with '-> " + arrow + "' on function " + disp + " ('" + str(m) + "' is neither '" + arrow + "' nor a subclass of it)", int(fn.get("line", 0)), int(fn.get("column", 0)), owner)
	var rets := _collect_returns(fn.get("body", null))
	if ann_void:
		for r in rets:
			if (r as Dictionary).get("value", null) != null:
				_error(ERR_RETURN_VALUE, "cannot return a value from void function " + disp, int((r as Dictionary).get("line", 0)), int((r as Dictionary).get("column", 0)), owner)
	else:
		var expect := str(ann.get("raw", ""))
		for r in rets:
			if (r as Dictionary).get("value", null) == null:
				_error(ERR_RETURN_VALUE, "bare return in non-void function " + disp + " (expects '" + expect + "')", int((r as Dictionary).get("line", 0)), int((r as Dictionary).get("column", 0)), owner)


# ------------------------------------------------------- collect passes

## Records a member (deprecated or not) under owner. kind is one of
## var, const, func, signal, enum, enum_member, class.
func _record(owner: String, name: String, kind: String, tag: Dictionary, node: Dictionary) -> void:
	if name == "":
		return
	if not _members.has(owner):
		_members[owner] = {}
	var rec = {"kind": kind, "node": node, "deprecated": {}, "owner": owner}
	if not tag.is_empty():
		rec["deprecated"] = {"message": str(tag.get("message", "")), "line": int(node.get("line", 0))}
		node["deprecated"] = {"message": str(tag.get("message", "")), "line": int(node.get("line", 0))}
	(_members[owner] as Dictionary)[name] = rec


## Looks for @deprecated in a node's leading_comments. Returns the tag
## ({} when absent) for the FIRST TYPE_INFO token carrying it.
func _leading_tag(node: Dictionary) -> Dictionary:
	for c in node.get("leading_comments", []):
		if c is Dictionary:
			var tag = _has_deprecated_tag(c)
			if not tag.is_empty():
				tag["line"] = int((c as Dictionary).get("line", 0))
				return tag
	return {}


## First pass: marks members, flags misplaced tags. owner is "" (root)
## or a dotted inner path. member_pos tells whether declarations here
## are real members (script top level, class bodies) as opposed to
## function locals, parameters or lambda bodies. Every node is
## visited once.
func _scan(node: Variant, owner: String, member_pos: bool = true) -> void:
	if node is Array:
		for e in node:
			_scan(e, owner, member_pos)
		return
	if not (node is Dictionary):
		return
	var d: Dictionary = node
	var t = str(d.get("type", ""))
	if t == "SCRIPT":
		_scan_children(d.get("children", []), owner, true)
		return
	if t in DECL_TYPES:
		_mark_decl(d, owner)
		if member_pos:
			_mark_private(d, owner)
		elif _has_any_private_tag(d):
			_error(ERR_PRIVATE_MISPLACED, "@private must precede a member declaration (variable, function, class, enum, constant or signal) inside a class body", int(d.get("line", 0)), int(d.get("column", 0)), owner)
		if t == "FUNC_DECL":
			_mark_return_func(d, owner)
		elif _has_any_return_tag(d):
			if t == "VAR_DECL" or t == "CONST_DECL":
				_mark_return_stmt(d, d.get("value", null), owner)
			else:
				_error(ERR_RETURN_MISPLACED, "@return can only precede a function or lambda declaration", int(d.get("line", 0)), int(d.get("column", 0)), owner)
		if t == "VAR_DECL" or t == "CONST_DECL":
			_mark_var_decl(d, owner)
		elif _has_any_var_tag(d):
			_error(ERR_VAR_MISPLACED, "@var can only precede a variable or constant declaration, or redefine a variable inside a function body", int(d.get("line", 0)), int(d.get("column", 0)), owner)
		if t == "FUNC_DECL":
			_mark_param_carrier(d, d, owner)
		elif _has_any_param_tag(d):
			var _pv: Variant = null
			if t == "VAR_DECL" or t == "CONST_DECL":
				_pv = d.get("value", null)
			if _pv is Dictionary and str((_pv as Dictionary).get("type", "")) == "LAMBDA":
				_mark_param_carrier(d, _pv, owner)
			else:
				_error(ERR_PARAM_MISPLACED, "@param can only precede function/lambda parameters or the function/lambda declaration using them", int(d.get("line", 0)), int(d.get("column", 0)), owner)
		if _has_any_tuple_tag(d) and not (member_pos and owner == ""):
			_error(ERR_TUPLE_MISPLACED, "@tuple definitions belong at the top level of the script", int(d.get("line", 0)), int(d.get("column", 0)), owner)
		if t == "CLASS_DECL":
			_scan_class_body(d, owner)
		elif t == "FUNC_DECL":
			_scan(d.get("params", []), owner, false)
			_scan(d.get("body", null), owner, false)
		return
	if t == "CLASS_NAME" or t == "EXTENDS":
		var tag = _leading_tag(d)
		if not tag.is_empty():
			_script_deprecated = {"message": str(tag.get("message", "")), "line": int(tag.get("line", 0))}
		if _has_any_private_tag(d):
			_error(ERR_PRIVATE_MISPLACED, "@private cannot be used at the file root, only on members inside a class body", int(d.get("line", 0)), int(d.get("column", 0)), owner)
		if _has_any_return_tag(d):
			_error(ERR_RETURN_MISPLACED, "@return can only precede a function or lambda declaration", int(d.get("line", 0)), int(d.get("column", 0)), owner)
		if _has_any_var_tag(d):
			_error(ERR_VAR_MISPLACED, "@var can only precede a variable or constant declaration, or redefine a variable inside a function body", int(d.get("line", 0)), int(d.get("column", 0)), owner)
		if _has_any_param_tag(d):
			_error(ERR_PARAM_MISPLACED, "@param can only precede function/lambda parameters or the function/lambda declaration using them", int(d.get("line", 0)), int(d.get("column", 0)), owner)
		if _has_any_tuple_tag(d) and not (member_pos and owner == ""):
			_error(ERR_TUPLE_MISPLACED, "@tuple definitions belong at the top level of the script", int(d.get("line", 0)), int(d.get("column", 0)), owner)
		return
	if t == "PARAM":
		var ptag = _leading_tag(d)
		if not ptag.is_empty():
			_error(ERR_DEPRECATED_UNSUPPORTED, "@deprecated on function parameters is not supported yet", int(d.get("line", 0)), int(d.get("column", 0)), owner)
		if _has_any_private_tag(d):
			_error(ERR_PRIVATE_MISPLACED, "@private must precede a member declaration (variable, function, class, enum, constant or signal) inside a class body", int(d.get("line", 0)), int(d.get("column", 0)), owner)
		if _has_any_return_tag(d):
			_error(ERR_RETURN_MISPLACED, "@return can only precede a function or lambda declaration", int(d.get("line", 0)), int(d.get("column", 0)), owner)
		if _has_any_var_tag(d):
			_error(ERR_VAR_MISPLACED, "@var can only precede a variable or constant declaration, or redefine a variable inside a function body", int(d.get("line", 0)), int(d.get("column", 0)), owner)
		if _has_any_param_tag(d):
			_apply_param_single(_extract_param_tags(d, owner), d, owner)
		if _has_any_tuple_tag(d):
			_error(ERR_TUPLE_MISPLACED, "@tuple definitions belong at the top level of the script", int(d.get("line", 0)), int(d.get("column", 0)), owner)
		return
	if t == "LAMBDA" or t == "ACCESSOR":
		if _has_any_deprecated_tag(d):
			_error(ERR_DEPRECATED_MISPLACED, "@deprecated must precede a member declaration (variable, function, class, enum, constant or signal)", int(d.get("line", 0)), int(d.get("column", 0)), owner)
			return
		if _has_any_private_tag(d):
			_error(ERR_PRIVATE_MISPLACED, "@private must precede a member declaration (variable, function, class, enum, constant or signal) inside a class body", int(d.get("line", 0)), int(d.get("column", 0)), owner)
			return
		if _has_any_return_tag(d):
			if t == "LAMBDA":
				_attach_return(d, _leading_return(d), owner)
			else:
				_error(ERR_RETURN_MISPLACED, "@return can only precede a function or lambda declaration", int(d.get("line", 0)), int(d.get("column", 0)), owner)
				return
		if _has_any_var_tag(d):
			_error(ERR_VAR_MISPLACED, "@var can only precede a variable or constant declaration, or redefine a variable inside a function body", int(d.get("line", 0)), int(d.get("column", 0)), owner)
			return
		if _has_any_param_tag(d):
			if t == "LAMBDA":
				_mark_param_carrier(d, d, owner)
			else:
				_error(ERR_PARAM_MISPLACED, "@param can only precede function/lambda parameters or the function/lambda declaration using them", int(d.get("line", 0)), int(d.get("column", 0)), owner)
				return
		if _has_any_tuple_tag(d):
			_error(ERR_TUPLE_MISPLACED, "@tuple definitions belong at the top level of the script", int(d.get("line", 0)), int(d.get("column", 0)), owner)
			return
		_scan(d.get("params", []), owner, false)
		_scan(d.get("body", null), owner, false)
		_scan(d.get("detail", null), owner, false)
		return
	if t == "BLOCK":
		_scan_children(d.get("children", []), owner, member_pos)
		return
	if t == "COMMENT" or t == "DOC_COMMENT" or t == "TYPE_INFO" or t == "ANNOTATION_DECL":
		if t == "TYPE_INFO" and member_pos and not _has_var_tag(d).is_empty():
			_error(ERR_VAR_MISPLACED, "@var redefinition is only allowed inside a function body", int(d.get("line", 0)), int(d.get("column", 0)), owner)
		if t == "TYPE_INFO" and not _has_param_tag(d).is_empty():
			_error(ERR_PARAM_MISPLACED, "@param can only precede function/lambda parameters or the function/lambda declaration using them", int(d.get("line", 0)), int(d.get("column", 0)), owner)
		if t == "TYPE_INFO" and not member_pos and not _has_tuple_tag(d).is_empty():
			_error(ERR_TUPLE_MISPLACED, "@tuple definitions belong at the top level of the script", int(d.get("line", 0)), int(d.get("column", 0)), owner)
		return
	if _has_any_tuple_tag(d):
		if not (member_pos and owner == ""):
			_error(ERR_TUPLE_MISPLACED, "@tuple definitions belong at the top level of the script", int(d.get("line", 0)), int(d.get("column", 0)), owner)
			return
		# Top level: already collected by _prescan_tuples; falls through.
	if _has_any_param_tag(d):
		if t == "EXPR_STMT":
			var _pe: Variant = d.get("expr", null)
			if _pe is Dictionary and str((_pe as Dictionary).get("type", "")) == "LAMBDA":
				_mark_param_carrier(d, _pe, owner)
			else:
				_error(ERR_PARAM_MISPLACED, "@param can only precede function/lambda parameters or the function/lambda declaration using them", int(d.get("line", 0)), int(d.get("column", 0)), owner)
		else:
			_error(ERR_PARAM_MISPLACED, "@param can only precede function/lambda parameters or the function/lambda declaration using them", int(d.get("line", 0)), int(d.get("column", 0)), owner)
		return
	if _has_any_return_tag(d):
		if t == "EXPR_STMT":
			var e: Variant = d.get("expr", null)
			if e is Dictionary and str((e as Dictionary).get("type", "")) == "LAMBDA":
				_attach_return(e, _leading_return(d), owner)
			else:
				_error(ERR_RETURN_MISPLACED, "@return can only precede a function or lambda declaration", int(d.get("line", 0)), int(d.get("column", 0)), owner)
		else:
			_error(ERR_RETURN_MISPLACED, "@return can only precede a function or lambda declaration", int(d.get("line", 0)), int(d.get("column", 0)), owner)
		return
	if _has_any_var_tag(d):
		if member_pos:
			_error(ERR_VAR_MISPLACED, "@var redefinition is only allowed inside a function body", int(d.get("line", 0)), int(d.get("column", 0)), owner)
			return
		# Inside a function body: deferred to the walk post-pass, which
		# owns the scope. Falls through to generic children below.
	if _has_any_deprecated_tag(d):
		_error(ERR_DEPRECATED_MISPLACED, "@deprecated must precede a member declaration (variable, function, class, enum, constant or signal)", int(d.get("line", 0)), int(d.get("column", 0)), owner)
		return
	if _has_any_private_tag(d):
		_error(ERR_PRIVATE_MISPLACED, "@private must precede a member declaration (variable, function, class, enum, constant or signal) inside a class body", int(d.get("line", 0)), int(d.get("column", 0)), owner)
		return
	_scan_generic_children(d, owner, member_pos)


func _scan_children(children: Variant, owner: String, member_pos: bool = true) -> void:
	if children is Array:
		for e in children:
			_scan(e, owner, member_pos)


func _scan_generic_children(d: Dictionary, owner: String, member_pos: bool = true) -> void:
	for k in d.keys():
		if k in ["tokens", "args", "annotations", "leading_comments", "header_comment", "deprecated", "private", "return_ann", "var_ann", "param_ann", "analyzer_errors", "analyzer_warnings"]:
			continue
		_scan(d[k], owner, member_pos)


func _has_any_deprecated_tag(node: Dictionary) -> bool:
	for c in node.get("leading_comments", []):
		if c is Dictionary and not _has_deprecated_tag(c).is_empty():
			return true
	return false


func _has_any_private_tag(node: Dictionary) -> bool:
	for c in node.get("leading_comments", []):
		if c is Dictionary and not _has_private_tag(c).is_empty():
			return true
	return false


## Records a private member under owner. kind mirrors _mark_decl kinds.
## Also stamps node["private"]; callers decide member-vs-misplaced.
func _record_private(owner: String, name: String, kind: String, tag: Dictionary, node: Dictionary) -> void:
	if name == "" or kind == "":
		return
	if not _private.has(owner):
		_private[owner] = {}
	var rec = {"kind": kind, "node": node, "private": {}, "owner": owner}
	rec["private"] = {"message": str(tag.get("message", "")), "line": int(node.get("line", 0))}
	node["private"] = {"message": str(tag.get("message", "")), "line": int(node.get("line", 0))}
	(_private[owner] as Dictionary)[name] = rec


## Looks for @private in a node's leading_comments (first hit wins).
func _leading_priv(node: Dictionary) -> Dictionary:
	for c in node.get("leading_comments", []):
		if c is Dictionary:
			var tag = _has_private_tag(c)
			if not tag.is_empty():
				tag["line"] = int((c as Dictionary).get("line", 0))
				return tag
	return {}


## Marks one declaration node private (no recursion; callers descend).
func _mark_private(node: Dictionary, owner: String) -> void:
	var t = str(node.get("type", ""))
	var tag = _leading_priv(node)
	if tag.is_empty():
		return
	var kind = ""
	if t == "VAR_DECL":
		kind = "variable"
	elif t == "CONST_DECL":
		kind = "constant"
	elif t == "FUNC_DECL":
		kind = "function"
	elif t == "CLASS_DECL":
		kind = "class"
	elif t == "ENUM_DECL":
		kind = "enum"
	elif t == "SIGNAL_DECL":
		kind = "signal"
	_record_private(owner, str(node.get("name", "")), kind, tag, node)
	if t == "ENUM_DECL":
		for m in node.get("members", []):
			if m is Dictionary and str((m as Dictionary).get("type", "")) == "ENUM_MEMBER":
				_record_private(owner, str((m as Dictionary).get("name", "")), "enum member", tag, m)


## Marks one declaration node (no recursion; callers descend).
func _mark_decl(node: Dictionary, owner: String) -> void:
	var t = str(node.get("type", ""))
	var tag = _leading_tag(node)
	var kind = ""
	if t == "VAR_DECL":
		kind = "variable"
	elif t == "CONST_DECL":
		kind = "constant"
	elif t == "FUNC_DECL":
		kind = "function"
	elif t == "CLASS_DECL":
		kind = "class"
	elif t == "ENUM_DECL":
		kind = "enum"
	elif t == "SIGNAL_DECL":
		kind = "signal"
	var mname = str(node.get("name", ""))
	_record(owner, mname, kind, tag, node)
	if t == "ENUM_DECL":
		for m in node.get("members", []):
			if m is Dictionary and str((m as Dictionary).get("type", "")) == "ENUM_MEMBER":
				_record(owner, str((m as Dictionary).get("name", "")), "enum member", tag, m)


func _scan_class_body(node: Dictionary, owner: String) -> void:
	var iname = str(node.get("name", ""))
	if iname == "":
		return
	var full = _full_name(owner, iname)
	if not _members.has(full):
		_members[full] = {}
	var base = _extends_text(node)
	if base != "":
		_class_extends[full] = base
	var body: Variant = node.get("body", null)
	if body is Dictionary:
		for child in (body as Dictionary).get("children", []):
			if child is Dictionary and str((child as Dictionary).get("type", "")) == "CLASS_DECL":
				_mark_decl(child, full)
				_mark_private(child, full)
				if _has_any_return_tag(child):
					_error(ERR_RETURN_MISPLACED, "@return can only precede a function or lambda declaration", int((child as Dictionary).get("line", 0)), int((child as Dictionary).get("column", 0)), full)
				if _has_any_var_tag(child):
					_error(ERR_VAR_MISPLACED, "@var can only precede a variable or constant declaration, or redefine a variable inside a function body", int((child as Dictionary).get("line", 0)), int((child as Dictionary).get("column", 0)), full)
				if _has_any_param_tag(child):
					_error(ERR_PARAM_MISPLACED, "@param can only precede function/lambda parameters or the function/lambda declaration using them", int((child as Dictionary).get("line", 0)), int((child as Dictionary).get("column", 0)), full)
				if _has_any_tuple_tag(child):
					_error(ERR_TUPLE_MISPLACED, "@tuple definitions belong at the top level of the script", int((child as Dictionary).get("line", 0)), int((child as Dictionary).get("column", 0)), full)
				_scan_class_body(child, full)
			elif child is Dictionary and str((child as Dictionary).get("type", "")) in DECL_TYPES:
				_mark_decl(child, full)
				_mark_private(child, full)
				if str((child as Dictionary).get("type", "")) == "FUNC_DECL":
					_mark_return_func(child, full)
					_mark_param_carrier(child, child, full)
					_scan((child as Dictionary).get("body", null), full)
				if str((child as Dictionary).get("type", "")) == "VAR_DECL" or str((child as Dictionary).get("type", "")) == "CONST_DECL":
					_mark_var_decl(child, full)
				elif _has_any_var_tag(child):
					_error(ERR_VAR_MISPLACED, "@var can only precede a variable or constant declaration, or redefine a variable inside a function body", int((child as Dictionary).get("line", 0)), int((child as Dictionary).get("column", 0)), full)
				if str((child as Dictionary).get("type", "")) != "FUNC_DECL" and _has_any_param_tag(child):
					var _cpv: Variant = null
					if str((child as Dictionary).get("type", "")) == "VAR_DECL" or str((child as Dictionary).get("type", "")) == "CONST_DECL":
						_cpv = (child as Dictionary).get("value", null)
					if _cpv is Dictionary and str((_cpv as Dictionary).get("type", "")) == "LAMBDA":
						_mark_param_carrier(child, _cpv, full)
					else:
						_error(ERR_PARAM_MISPLACED, "@param can only precede function/lambda parameters or the function/lambda declaration using them", int((child as Dictionary).get("line", 0)), int((child as Dictionary).get("column", 0)), full)
				if _has_any_tuple_tag(child):
					_error(ERR_TUPLE_MISPLACED, "@tuple definitions belong at the top level of the script", int((child as Dictionary).get("line", 0)), int((child as Dictionary).get("column", 0)), full)
				elif _has_any_return_tag(child):
					if str((child as Dictionary).get("type", "")) == "VAR_DECL" or str((child as Dictionary).get("type", "")) == "CONST_DECL":
						_mark_return_stmt(child, (child as Dictionary).get("value", null), full)
					else:
						_error(ERR_RETURN_MISPLACED, "@return can only precede a function or lambda declaration", int((child as Dictionary).get("line", 0)), int((child as Dictionary).get("column", 0)), full)


## Reads the base class text of a CLASS_DECL: inline extends_type
## (TYPE_REF tokens) or a block-form EXTENDS child. IDENTIFIER parts
## join with "."; anything else means unknown (engine parent, path).
func _extends_text(node: Dictionary) -> String:
	var ext: Variant = node.get("extends_type", null)
	if ext is Dictionary:
		var parts: Array = []
		for t in (ext as Dictionary).get("tokens", []):
			if t is Dictionary and (str((t as Dictionary).get("type", "")) == "IDENTIFIER" or str((t as Dictionary).get("type", "")) == "BUILTIN_TYPE"):
				parts.append(str((t as Dictionary).get("value", "")))
		if not parts.is_empty():
			var out = str(parts[0])
			for i in range(1, parts.size()):
				out += "." + str(parts[i])
			return out
	var body: Variant = node.get("body", null)
	if body is Dictionary:
		for child in (body as Dictionary).get("children", []):
			if child is Dictionary and str((child as Dictionary).get("type", "")) == "EXTENDS":
				var p2: Array = []
				for t in (child as Dictionary).get("path", []):
					if t is Dictionary and (str((t as Dictionary).get("type", "")) == "IDENTIFIER" or str((t as Dictionary).get("type", "")) == "BUILTIN_TYPE"):
						p2.append(str((t as Dictionary).get("value", "")))
				if not p2.is_empty():
					var out2 = str(p2[0])
					for i in range(1, p2.size()):
						out2 += "." + str(p2[i])
					return out2
	return ""


# ------------------------------------------------------- usage walk

func _new_scope(parent) -> Dictionary:
	return {"names": {}, "parent": parent}


func _scope_add(scope: Dictionary, name: String, kind: String) -> void:
	if name != "":
		(scope["names"] as Dictionary)[name] = kind


func _scope_has(scope, name: String) -> bool:
	var cur = scope
	while cur is Dictionary:
		if ((cur as Dictionary).get("names", {}) as Dictionary).has(name):
			return true
		cur = (cur as Dictionary).get("parent", null)
	return false


## Looks a bare name up: locals/params first (shadow), then members of
## the current owner, then script-root type-ish names (classes, enums).
## Returns {} when unknown, else {"kind","owner","dep"}.
func _resolve_bare(name: String, scope: Dictionary, owner: String) -> Dictionary:
	if _scope_has(scope, name):
		return {"shadowed": true}
	var hit = _member_lookup(owner, name)
	if not hit.is_empty():
		return hit
	if owner != "":
		hit = _member_lookup("", name)
		if not hit.is_empty() and str(hit.get("kind", "")) in ["class", "enum", "enum member", "constant"]:
			return hit
	return {}


## Member lookup inside one owner table (no shadowing here).
func _member_lookup(owner: String, name: String) -> Dictionary:
	if not _members.has(owner):
		return {}
	var table: Dictionary = _members[owner]
	if not table.has(name):
		return {}
	var rec: Dictionary = table[name]
	return {"kind": str(rec.get("kind", "")), "owner": owner, "dep": rec.get("deprecated", {})}


## Second pass: walks executable code with scopes. owner tracks the
## enclosing class for self-resolution and issue attribution.
func _walk(node: Variant, scope: Dictionary, owner: String) -> void:
	if node is Array:
		for e in node:
			_walk(e, scope, owner)
		return
	if not (node is Dictionary):
		return
	var d: Dictionary = node
	var t = str(d.get("type", ""))
	if t == "SCRIPT":
		_walk(d.get("children", []), scope, owner)
		return
	if t == "FUNC_DECL":
		_walk_func(d, scope, owner)
		return
	if t == "CLASS_DECL":
		_walk_class(d, scope, owner)
		return
	if t == "VAR_DECL" or t == "CONST_DECL":
		_check_expr_tokens(_as_tokens(d.get("value", null)), scope, owner)
		_check_type_ref(d.get("vartype", null), scope, owner)
		_scope_add(scope, str(d.get("name", "")), "local")
		_check_return_ann(d.get("value", null), owner)
		_check_value_lambda(d.get("value", null), scope, owner)
		_check_tuple_value(_vartype_name(d), d.get("value", null), int(d.get("line", 0)), owner)
		var acc: Variant = d.get("accessors", null)
		if acc is Dictionary:
			_walk(acc, scope, owner)
		return
	if t == "SIGNAL_DECL" or t == "CLASS_NAME":
		return
	if t == "ENUM_DECL":
		_walk_enum_values(d, scope, owner)
		return
	if t == "EXTENDS":
		_check_expr_tokens(_flat_tokens(d.get("path", [])), scope, owner)
		return
	if t == "LAMBDA":
		_walk_lambda(d, scope, owner)
		return
	if t == "BLOCK":
		_walk(d.get("children", []), scope, owner)
		return
	if t == "IF_STMT":
		_check_expr_tokens(_as_tokens(d.get("condition", null)), scope, owner)
		_walk(d.get("then", null), scope, owner)
		for e in d.get("elifs", []):
			if e is Dictionary:
				_check_expr_tokens(_as_tokens((e as Dictionary).get("condition", null)), scope, owner)
				_walk((e as Dictionary).get("body", null), scope, owner)
		if d.get("else_body", null) is Dictionary:
			_walk(d.get("else_body", null), scope, owner)
		return
	if t == "FOR_STMT":
		_check_expr_tokens(_as_tokens(d.get("iter", null)), scope, owner)
		var target: Variant = d.get("target", null)
		if target is Dictionary and str((target as Dictionary).get("type", "")) == "IDENTIFIER":
			_scope_add(scope, str((target as Dictionary).get("value", "")), "loop")
		_walk(d.get("body", null), scope, owner)
		return
	if t == "WHILE_STMT":
		_check_expr_tokens(_as_tokens(d.get("condition", null)), scope, owner)
		_walk(d.get("body", null), scope, owner)
		return
	if t == "MATCH_STMT":
		_check_expr_tokens(_as_tokens(d.get("subject", null)), scope, owner)
		for b in d.get("branches", []):
			if b is Dictionary and str((b as Dictionary).get("type", "")) == "MATCH_BRANCH":
				_walk_pattern((b as Dictionary).get("pattern", null), scope, owner)
				_walk((b as Dictionary).get("body", null), scope, owner)
		return
	if t == "RETURN_STMT":
		_check_expr_tokens(_as_tokens(d.get("value", null)), scope, owner)
		return
	if t == "ASSERT_STMT":
		_check_expr_tokens(_flat_tokens(d.get("args", [])), scope, owner)
		return
	if t == "EXPR_STMT":
		_check_expr_tokens(_as_tokens(d.get("expr", null)), scope, owner)
		_check_return_ann(d.get("expr", null), owner)
		_check_value_lambda(d.get("expr", null), scope, owner)
		return
	if t == "ACCESSOR":
		var detail: Variant = d.get("detail", null)
		if detail is Dictionary:
			if detail.has("tokens"):
				_check_expr_tokens(_as_tokens(detail), scope, owner)
			if detail.has("alias_pair"):
				for pair in detail.get("alias_pair", []):
					if pair is Dictionary and (pair as Dictionary).has("expr"):
						_check_expr_tokens(_as_tokens((pair as Dictionary).get("expr", null)), scope, owner)
		for p in d.get("params", []):
			if p is Dictionary:
				_scope_add(scope, str((p as Dictionary).get("name", "")), "param")
		_walk(d.get("body", null), scope, owner)
		_process_free_vars(d.get("body", null), scope, owner, null)
		return
	if t == "COMMENT" or t == "DOC_COMMENT" or t == "TYPE_INFO" or t == "ANNOTATION_DECL" or t == "SYNTAX_ERROR":
		return
	_walk_generic(d, scope, owner)


func _walk_generic(d: Dictionary, scope: Dictionary, owner: String) -> void:
	for k in d.keys():
		if k in ["tokens", "args", "annotations", "leading_comments", "header_comment", "deprecated", "private", "return_ann", "var_ann", "param_ann", "analyzer_errors", "analyzer_warnings", "semantic_errors", "user_types_written"]:
			continue
		_walk(d[k], scope, owner)


## Walks member-level children (script top or class body): member
## declarations are checked WITHOUT adding them as shadowing locals
## (they already live in the member tables).
func _walk_members(children: Variant, scope: Dictionary, owner: String) -> void:
	if not (children is Array):
		return
	for child in children:
		if not (child is Dictionary):
			continue
		var t = str((child as Dictionary).get("type", ""))
		if t == "VAR_DECL" or t == "CONST_DECL":
			_check_expr_tokens(_as_tokens((child as Dictionary).get("value", null)), scope, owner)
			_check_type_ref((child as Dictionary).get("vartype", null), scope, owner)
			_check_return_ann((child as Dictionary).get("value", null), owner)
			_check_value_lambda((child as Dictionary).get("value", null), scope, owner)
			_check_tuple_value(_vartype_name(child as Dictionary), (child as Dictionary).get("value", null), int((child as Dictionary).get("line", 0)), owner)
			var acc: Variant = (child as Dictionary).get("accessors", null)
			if acc is Dictionary:
				_walk(acc, scope, owner)
		elif t == "FUNC_DECL":
			_walk_func(child, scope, owner)
		elif t == "CLASS_DECL":
			_walk_class(child, scope, owner)
		elif t == "ENUM_DECL":
			_walk_enum_values(child, scope, owner)
		else:
			_walk(child, scope, owner)


## Walks enum member values (no scope changes).
func _walk_enum_values(node: Dictionary, scope: Dictionary, owner: String) -> void:
	for m in node.get("members", []):
		if m is Dictionary and str((m as Dictionary).get("type", "")) == "ENUM_MEMBER":
			_check_expr_tokens(_as_tokens((m as Dictionary).get("value", null)), scope, owner)


func _walk_func(node: Dictionary, scope: Dictionary, owner: String) -> void:
	var fscope = _new_scope(scope)
	_collect_func_bindings(node.get("body", null), fscope)
	for p in node.get("params", []):
		if p is Dictionary:
			_scope_add(fscope, str((p as Dictionary).get("name", "")), "param")
			var def: Variant = (p as Dictionary).get("default", null)
			if def != null:
				_check_expr_tokens(_as_tokens(def), fscope, owner)
	var rt: Variant = node.get("return_type", null)
	if rt is Dictionary:
		_check_type_ref(rt, fscope, owner)
	_walk(node.get("body", null), fscope, owner)
	_check_return_ann(node, owner)
	_process_free_vars(node.get("body", null), fscope, owner, node)


func _walk_class(node: Dictionary, scope: Dictionary, owner: String) -> void:
	var full = _full_name(owner, str(node.get("name", "")))
	var cscope = _new_scope(scope)
	var body: Variant = node.get("body", null)
	var ext: Variant = node.get("extends_type", null)
	if ext is Dictionary:
		_check_expr_tokens(_as_tokens(ext), cscope, full)
	if body is Dictionary:
		_walk_members((body as Dictionary).get("children", []), cscope, full)


func _walk_lambda(node: Dictionary, scope: Dictionary, owner: String) -> void:
	var lscope = _new_scope(scope)
	for p in node.get("params", []):
		if p is Dictionary:
			_scope_add(lscope, str((p as Dictionary).get("name", "")), "param")
	_collect_func_bindings(node.get("body", null), lscope)
	_walk(node.get("body", null), lscope, owner)
	_check_return_ann(node, owner)
	_process_free_vars(node.get("body", null), lscope, owner, node)


## Pre-walk collecting VAR/CONST names, FOR targets and `var x`
## pattern bindings into scope (order-insensitive, like shadowing).
func _collect_func_bindings(node: Variant, scope: Dictionary) -> void:
	if node is Array:
		for e in node:
			_collect_func_bindings(e, scope)
		return
	if not (node is Dictionary):
		return
	var d: Dictionary = node
	var t = str(d.get("type", ""))
	if t == "VAR_DECL":
		_scope_add(scope, str(d.get("name", "")), "local")
		return
	if t == "CONST_DECL":
		_scope_add(scope, str(d.get("name", "")), "const")
		return
	if t == "FOR_STMT":
		var target: Variant = d.get("target", null)
		if target is Dictionary and str((target as Dictionary).get("type", "")) == "IDENTIFIER":
			_scope_add(scope, str((target as Dictionary).get("value", "")), "loop")
	elif t == "PATTERN":
		_collect_pattern_bindings(d, scope)
	elif t == "CLASS_DECL":
		return
	for k in d.keys():
		if k in ["tokens", "args", "annotations", "leading_comments", "header_comment", "deprecated", "private", "return_ann", "var_ann", "param_ann"]:
			continue
		_collect_func_bindings(d[k], scope)


func _collect_pattern_bindings(pattern: Dictionary, scope: Dictionary) -> void:
	var toks: Array = pattern.get("tokens", [])
	var i = 0
	while i < toks.size():
		if toks[i] is Dictionary and str((toks[i] as Dictionary).get("type", "")) == "KEYWORD" and str((toks[i] as Dictionary).get("value", "")) == "var" and i + 1 < toks.size() and (toks[i + 1] is Dictionary) and str((toks[i + 1] as Dictionary).get("type", "")) == "IDENTIFIER":
			_scope_add(scope, str((toks[i + 1] as Dictionary).get("value", "")), "bind")
			i += 2
			continue
		i += 1


func _walk_pattern(pattern: Variant, scope: Dictionary, owner: String) -> void:
	if not (pattern is Dictionary):
		return
	var toks: Array = (pattern as Dictionary).get("tokens", [])
	var i = 0
	while i < toks.size():
		if toks[i] is Dictionary and str((toks[i] as Dictionary).get("type", "")) == "KEYWORD" and str((toks[i] as Dictionary).get("value", "")) == "var":
			i += 2
			continue
		i += 1
	_check_expr_tokens(toks, scope, owner)


func _as_tokens(v: Variant) -> Array:
	if v is Dictionary and (v as Dictionary).has("tokens"):
		var toks: Variant = (v as Dictionary).get("tokens", [])
		if toks is Array:
			return toks
	return []


func _flat_tokens(v: Variant) -> Array:
	var out: Array = []
	_flat_into(v, out)
	return out


func _flat_into(v: Variant, out: Array) -> void:
	if v is Array:
		for e in v:
			_flat_into(e, out)
	elif v is Dictionary:
		if (v as Dictionary).has("type") and (v as Dictionary).has("value") and (v as Dictionary).has("line"):
			out.append(v)


## Checks TYPE_REF contents (deprecated classes as annotations).
func _check_type_ref(v: Variant, scope: Dictionary, owner: String) -> void:
	if v is Dictionary:
		_check_expr_tokens(_as_tokens(v), scope, owner)


# ------------------------------------------------------- expression scan

## Flat token scan detecting deprecated uses. LAMBDA nodes are walked
## with their params in scope; raw `func` soups absorb params too.
func _check_expr_tokens(tokens: Array, scope: Dictionary, owner: String) -> void:
	var i = 0
	while i < tokens.size():
		if not (tokens[i] is Dictionary):
			i += 1
			continue
		var t: Dictionary = tokens[i]
		var ty = str(t.get("type", ""))
		var v = str(t.get("value", ""))
		if ty == "LAMBDA":
			_walk_lambda(t, scope, owner)
			i += 1
			continue
		if ty == "KEYWORD" and v == "func":
			i = _absorb_lambda_params(tokens, i, scope)
			continue
		if ty == "IDENTIFIER":
			var nxt_ty = ""
			var nxt_v = ""
			if i + 1 < tokens.size() and tokens[i + 1] is Dictionary:
				nxt_ty = str((tokens[i + 1] as Dictionary).get("type", ""))
				nxt_v = str((tokens[i + 1] as Dictionary).get("value", ""))
			if nxt_ty == "DOT":
				i = _check_chain(tokens, i, scope, owner)
				continue
			if nxt_ty == "LPAREN" and nxt_v == "(":
				_check_bare_call(t, scope, owner)
				i += 1
				continue
			_check_bare_name(t, scope, owner)
			i += 1
			continue
		i += 1


## Absorbs raw lambda parameters (`func (a, b ...)`) into scope.
## Returns the index of the closing RPAREN (or nearby on garbage).
func _absorb_lambda_params(tokens: Array, at: int, scope: Dictionary) -> int:
	var i = at + 1
	if i >= tokens.size() or not (tokens[i] is Dictionary) or str((tokens[i] as Dictionary).get("type", "")) != "LPAREN":
		return at + 1
	var depth = 0
	i += 1
	while i < tokens.size():
		if not (tokens[i] is Dictionary):
			i += 1
			continue
		var ty = str((tokens[i] as Dictionary).get("type", ""))
		if ty == "LPAREN":
			depth += 1
		elif ty == "RPAREN":
			if depth == 0:
				return i
			depth -= 1
		elif ty == "IDENTIFIER" and depth == 0:
			_scope_add(scope, str((tokens[i] as Dictionary).get("value", "")), "param")
		i += 1
	return i


## Bare `name` reference (read, write, callable value, `await sig`...).
func _check_bare_name(t: Dictionary, scope: Dictionary, owner: String) -> void:
	var v = str(t.get("value", ""))
	if v == "" or v == "_":
		return
	if not _scope_has(scope, v):
		var pv = _private_lookup(v, owner, owner)
		if not pv.is_empty():
			_error_private_use(v, pv, t, owner)
	var hit = _resolve_bare(v, scope, owner)
	if hit.is_empty() or hit.has("shadowed"):
		return
	_warn_use(str(hit.get("kind", "")), v, hit, t, owner)


## Bare `name(...)` call.
func _check_bare_call(t: Dictionary, scope: Dictionary, owner: String) -> void:
	var v = str(t.get("value", ""))
	if v == "" or v == "_":
		return
	if not _scope_has(scope, v):
		var pv = _private_lookup(v, owner, owner)
		if not pv.is_empty():
			_error_private_use(v, pv, t, owner)
	var hit = _resolve_bare(v, scope, owner)
	if hit.is_empty() or hit.has("shadowed"):
		return
	if str(hit.get("kind", "")) == "class":
		_warn_use("class", v, hit, t, owner)
		return
	_warn_use(str(hit.get("kind", "")), v, hit, t, owner)


## Dotted chains: self.x, ClassName.x, Inner.x, Outer.Inner.x,
## unknown_base.x (skipped). Returns index past the chain.
func _check_chain(tokens: Array, i: int, scope: Dictionary, owner: String) -> int:
	var base = str((tokens[i] as Dictionary).get("value", ""))
	var j = i + 1
	var info = _chain_base(base, scope, owner, tokens[i])
	var cur_owner = str(info.get("owner", ""))
	var cur_kind = str(info.get("kind", ""))
	var cur_known = bool(info.get("known", false))
	if cur_kind == "class":
		var dep = _class_dep(base, cur_owner)
		if not dep.is_empty():
			_warn_use("class", base, {"dep": dep}, tokens[i], owner)
	var cur_dep: Dictionary = info.get("dep", {})
	var chain_warned = false
	if not _scope_has(scope, base):
		var pb = _private_lookup(base, owner, owner)
		if not pb.is_empty():
			_error_private_use(base, pb, tokens[i], owner)
	while j < tokens.size() and (tokens[j] is Dictionary) and str((tokens[j] as Dictionary).get("type", "")) == "DOT":
		j += 1
		if j >= tokens.size() or not (tokens[j] is Dictionary):
			break
		var nt = str((tokens[j] as Dictionary).get("type", ""))
		if nt != "IDENTIFIER" and nt != "BUILTIN_TYPE" and nt != "KEYWORD":
			break
		var seg = str((tokens[j] as Dictionary).get("value", ""))
		if seg == "new":
			j += 1
			continue
		if not cur_known:
			j += 1
			continue
		if cur_kind == "signal":
			if not chain_warned:
				_warn_use("signal", base, {"dep": cur_dep}, tokens[j - 2], owner)
				chain_warned = true
			j += 1
			continue
		var ps = _private_lookup(seg, cur_owner, owner)
		if not ps.is_empty():
			_error_private_use(_qualify(cur_owner, seg), ps, tokens[j], owner)
		var sub = _member_lookup(cur_owner, seg)
		if sub.is_empty():
			var inner_full = _inner_full(cur_owner, seg)
			if inner_full != "":
				cur_owner = inner_full
				cur_known = true
				cur_kind = "class"
				j += 1
				continue
			cur_known = false
			j += 1
			continue
		if seg == cur_owner or seg == base:
			j += 1
			continue
		_warn_use(str(sub.get("kind", "")), _qualify(cur_owner, seg), sub, tokens[j], owner)
		var next_owner = _inner_full(cur_owner, seg)
		if next_owner != "" and str(sub.get("kind", "")) == "class":
			cur_owner = next_owner
			cur_known = true
		else:
			cur_known = false
		j += 1
	return j


## Classifies a chain base. known=true means member tables apply.
## Deprecated value bases (var/const/func/enum) warn here; classes and
## enums resolve to their full tables; signals get their own branch.
func _chain_base(base: String, scope: Dictionary, owner: String, tok: Dictionary) -> Dictionary:
	if base == "self":
		return {"owner": owner, "kind": "self", "known": true}
	if base == _script_class and _script_class != "":
		return {"owner": "", "kind": "class", "known": true}
	if _members.has(base):
		return {"owner": base, "kind": "class", "known": true}
	for key in _members.keys():
		var ks = str(key)
		if ks == base or ks.ends_with("." + base):
			return {"owner": ks, "kind": "class", "known": true}
	var hit = _resolve_bare(base, scope, owner)
	if hit.is_empty() or hit.has("shadowed"):
		return {"owner": "", "kind": "unknown", "known": false}
	var kind = str(hit.get("kind", ""))
	if kind == "signal":
		return {"owner": str(hit.get("owner", "")), "kind": "signal", "known": true, "dep": hit.get("dep", {})}
	if kind == "class":
		return {"owner": _full_name(str(hit.get("owner", "")), base), "kind": "class", "known": true}
	if kind == "enum":
		_warn_use("enum", base, hit, tok, owner)
		return {"owner": "", "kind": "unknown", "known": false}
	_warn_use(kind, base, hit, tok, owner)
	return {"owner": "", "kind": "unknown", "known": false}


## Full dotted name of a class recorded under owner table ("" = root).
func _full_name(owner: String, name: String) -> String:
	if owner != "":
		return owner + "." + name
	if _script_class != "":
		return _script_class + "." + name
	return name


## Deprecation record of a class referred by its simple written name:
## looks in the root table, then in any owner table (first hit wins).
func _class_dep(simple: String, _owner_hint: String) -> Dictionary:
	if _members.has("") and (_members[""] as Dictionary).has(simple):
		var rec: Dictionary = (_members[""] as Dictionary)[simple]
		if str(rec.get("kind", "")) == "class":
			return rec.get("deprecated", {})
	for key in _members.keys():
		var ks = str(key)
		if ks == "":
			continue
		var table: Dictionary = _members[ks]
		if table.has(simple):
			var rec2: Dictionary = table[simple]
			if str(rec2.get("kind", "")) == "class":
				return rec2.get("deprecated", {})
	return {}


## Display name for an owner in messages: "" becomes the script
## class_name, or "script root" when there is none.
func _owner_display(o: String) -> String:
	if o != "":
		return o
	if _script_class != "":
		return _script_class
	return "script root"


## In-file parent owner key of a class owner ("" when the parent is the
## engine or cannot be resolved to a script class).
func _private_parent(owner_key: String) -> String:
	if not _class_extends.has(owner_key):
		return ""
	return _resolve_private_owner(str(_class_extends[owner_key]), owner_key)


## Resolves an extends base text to an owner-table key: exact match,
## relative to from_owner, then script-prefixed. "" = engine/absent.
func _resolve_private_owner(base_text: String, from_owner: String) -> String:
	if base_text == "":
		return ""
	if _members.has(base_text) or _private.has(base_text):
		return base_text
	if from_owner != "":
		var rel = from_owner + "." + base_text
		if _members.has(rel) or _private.has(rel):
			return rel
	if _script_class != "" and not ("." in base_text):
		var sc = _script_class + "." + base_text
		if _members.has(sc) or _private.has(sc):
			return sc
	if _members.has("") and (_members[""] as Dictionary).has(base_text):
		var r: Dictionary = (_members[""] as Dictionary)[base_text]
		if str(r.get("kind", "")) == "class":
			return _full_name("", base_text)
	return ""


## Nested-family relation for @private: the same class, an ancestor,
## or a descendant (transitively). The script root ("") is family with
## everything in the file, so inner classes freely use outer privates
## and vice versa. Siblings and inheritance lines are NOT family.
func _same_family(use_owner: String, decl_owner: String) -> bool:
	if use_owner == decl_owner:
		return true
	if use_owner == "" or decl_owner == "":
		return true
	if decl_owner.begins_with(use_owner + "."):
		return true
	if use_owner.begins_with(decl_owner + "."):
		return true
	return false


## Unified private lookup: nearest _members hit along [start_owner +
## extends...] decides; a private hit outside the same nested family
## is a violation, anything else is allowed or unknown.
## Returns {} when allowed/unknown, else {decl_owner,kind,...}.
## - start_owner "" scans the root table (bare uses at root, qualified
##   roots like `MyLib._x`).
## - use_owner is only used for the family test, never for lookup.
## - Callers must have ruled out scope shadowing for bare names.
func _private_lookup(name: String, start_owner: String, use_owner: String) -> Dictionary:
	if name == "" or name == "_":
		return {}
	var seen = {}
	var cur = start_owner
	while true:
		if _members.has(cur) and (_members[cur] as Dictionary).has(name):
			if _private.has(cur) and (_private[cur] as Dictionary).has(name):
				var decl = cur
				var rec: Dictionary = (_private[cur] as Dictionary)[name]
				if str(rec.get("kind", "")) == "class":
					decl = _decl_subtree(cur, name)
				if not _same_family(use_owner, decl):
					var priv: Dictionary = rec.get("private", {})
					return {"decl_owner": decl, "kind": str(rec.get("kind", "")), "message": str(priv.get("message", "")), "line": int(priv.get("line", 0))}
			return {}
		if cur == "" or seen.has(cur):
			return {}
		seen[cur] = true
		cur = _private_parent(cur)
	return {}


## Subtree path a member declaration belongs to: classes live in their
## own subtree, everything else in its recording table.
func _decl_subtree(table_owner: String, name: String) -> String:
	if table_owner == "":
		return _full_name("", name)
	return table_owner + "." + name


func _error_private_use(qname: String, hit: Dictionary, tok: Dictionary, use_owner: String) -> void:
	var msg = "cannot use private " + str(hit.get("kind", "")) + " '" + qname + "' outside class '" + _owner_display(str(hit.get("decl_owner", ""))) + "'"
	_error(ERR_PRIVATE_USE, msg, int(tok.get("line", 0)), int(tok.get("column", 0)), use_owner)


## Full dotted name of an inner class owned by cur_owner, or "".
func _inner_full(cur_owner: String, seg: String) -> String:
	var cand = seg
	if cur_owner != "":
		cand = cur_owner + "." + seg
	elif _script_class != "":
		cand = _script_class + "." + seg
	if _members.has(cand):
		return cand
	if _members.has(seg):
		return seg
	return ""


func _qualify(owner: String, seg: String) -> String:
	if owner == "":
		if _script_class != "":
			return _script_class + "." + seg
		return seg
	return owner + "." + seg


func _warn_use(kind: String, qname: String, hit: Dictionary, tok: Dictionary, owner: String) -> void:
	if not _script_deprecated.is_empty():
		return
	var dep: Dictionary = hit.get("dep", {})
	if dep.is_empty():
		return
	var msg = "use of deprecated " + kind + " '" + qname + "'"
	var dm = str(dep.get("message", ""))
	if dm != "":
		msg += ": " + dm
	_warnings.append({"kind": WARN_DEPRECATED_USE, "message": msg, "line": int(tok.get("line", 0)), "column": int(tok.get("column", 0)), "owner": owner})


func _error(kind: String, message: String, line: int, column: int, owner: String) -> void:
	_errors.append({"kind": kind, "message": message, "line": line, "column": column, "owner": owner})


# ------------------------------------------------- flow analysis
#
# Flow-sensitive member verification (Phase 1) with typeof type guards
# (Phase 2). A dedicated pass walks function bodies in order carrying
# env {name: [types]}: declared types outside guards, narrowed types
# inside `if typeof(x) == T` branches, @var/@param facts in order.
# Anything else (dynamic plain-`=` variables, uninferrable values,
# super, call results without known returns) skips verification.
# Objects are assumed to hold ONLY declared and inherited members (no
# dynamic script dispatch): a script member reached through a base type
# misses, and suppressing that needs a type guard. Calls AND reads on
# Object-derived or script types error on exhaustion (missing_method /
# missing_member); builtin reads stay lenient (Color.RED has no JSON
# backing problem anymore, but Dictionary keys and Variant tops do).
# Enum reads carry their closed value set forward (WithSignal.Mode.ON
# verifies; .NOPE errors). The scope-aware _walk pass is untouched
# (no signature or behavior changes there).


## Owner-table key of a script class name ("", "Outer", "Outer.Inner",
## "MyLib.Item", ...), resolved from an owner context. "" when the
## name is not a script class (engine types resolve to "").
func _script_key_of(name: String, owner: String) -> String:
	if name == "":
		return ""
	var key := _resolve_private_owner(name, owner)
	if key != "" and _members.has(key):
		return key
	return ""


## One script-table hit. cont carries continuation: {"types": [...]}
## (possibly empty = opaque but found), {"script": key} for inner
## classes (constructed or read as values), {"signal": true}.
## Returns {"status": "found", "cont"} or {"status": "miss-sure"}
## (existing member used wrongly: called enum/signal/constant).
func _script_hit(rec: Dictionary, seg: String, is_call: bool) -> Dictionary:
	var kind := str(rec.get("kind", ""))
	if kind == "function":
		if is_call:
			var arrow := _arrow_name((rec.get("node", {}) as Dictionary).get("return_type", null))
			if arrow == "":
				return {"status": "found", "cont": {"types": []}}
			return {"status": "found", "cont": {"types": [arrow]}}
		return {"status": "found", "cont": {"types": ["Callable"]}}
	if kind == "variable" or kind == "constant":
		if not is_call:
			var n: Variant = rec.get("node", {})
			if n is Dictionary:
				return {"status": "found", "cont": {"types": _flow_decl_types(n, kind == "constant", false)}}
			return {"status": "found", "cont": {"types": []}}
		return {"status": "found", "cont": {"types": []}}
	if kind == "signal":
		if is_call:
			return {"status": "miss-sure"}
		return {"status": "found", "cont": {"signal": true}}
	if kind == "class":
		var parent := str(rec.get("owner", ""))
		var full := seg
		if parent != "":
			full = parent + "." + seg
		elif _script_class != "":
			full = _script_class + "." + seg
		return {"status": "found", "cont": {"script": full}}
	if kind == "enum" or kind == "enum member":
		if is_call:
			return {"status": "miss-sure"}
		var vals: Array = []
		var enode: Variant = rec.get("node", {})
		if enode is Dictionary:
			for m in (enode as Dictionary).get("members", []):
				if m is Dictionary and str((m as Dictionary).get("type", "")) == "ENUM_MEMBER":
					vals.append(str((m as Dictionary).get("name", "")))
		var eparent := str(rec.get("owner", ""))
		var efull := seg
		if eparent != "":
			efull = eparent + "." + seg
		elif _script_class != "":
			efull = _script_class + "." + seg
		return {"status": "found", "cont": {"types": ["int"], "enumvals": vals, "enumname": efull}}
	return {"status": "miss-sure"}


## Script-side member lookup: own table, then script parents, then the
## terminal engine base. Objects are assumed to hold ONLY declared and
## inherited members (no dynamic script dispatch): script members found
## out of the inheritance line still miss. Returns:
## - {"status": "found", "cont"} (see _script_hit);
## - {"status": "miss-skip"} (unresolvable parent: cannot prove absence);
## - {"status": "miss-engine", "base"} (terminal engine base: caller
##   runs the engine check, which errors on absence);
## - {"status": "miss-sure"} (existing member misused: caller errors).
func _script_seg(owner_key: String, seg: String, is_call: bool) -> Dictionary:
	var key := owner_key
	var seen := {}
	var guard := 0
	while guard < 64:
		guard += 1
		if seen.has(key):
			return {"status": "miss-skip"}
		seen[key] = true
		if _members.has(key):
			var table: Dictionary = _members[key]
			if table.has(seg):
				return _script_hit(table[seg], seg, is_call)
		var base := ""
		if key == "":
			base = _script_extends
		else:
			base = str(_class_extends.get(key, ""))
		if base == "":
			base = "RefCounted"
		var resolved := _resolve_private_owner(base, key)
		if resolved != "" and _members.has(resolved):
			key = resolved
			continue
		if _engine_info(base).is_empty() and _engine_info(_base_simple(base)).is_empty():
			return {"status": "miss-skip"}
		var ename := base
		if _engine_info(base).is_empty():
			ename = _base_simple(base)
		return {"status": "miss-engine", "base": ename}
	return {"status": "miss-skip"}


## Declared types of a VAR/CONST/PARAM node as a list ([] = dynamic).
## Before-decl @var / @param facts win, then explicit vartype, then
## `:=`/const inference. Plain `=` stays dynamic on purpose.
func _flow_decl_types(node: Dictionary, is_const: bool, is_param: bool) -> Array:
	if node.has("var_ann"):
		var va: Dictionary = node["var_ann"]
		return (va.get("types", []) as Array).duplicate()
	if node.has("param_ann"):
		var pa: Dictionary = node["param_ann"]
		return (pa.get("types", []) as Array).duplicate()
	var vt := _vartype_name(node)
	if vt != "":
		return [vt]
	if is_param:
		return []
	if is_const or str(node.get("op", "")) == ":=":
		var inf := _infer_var_value(node.get("value", null))
		if inf != "":
			return [inf]
	return []


## True for engine-backed type info (builtin/class/root kinds).
## Script user files ("script") never verify: their methods are
## collected without inheritance, so misses would false-positive.
static func _is_engine_info(info: Dictionary) -> bool:
	return str(info.get("kind", "")) in ["builtin", "class", "root"]


## Lenient reads: dynamic tops (Variant/root kind) and keyed
## containers (Dictionary keys are unknowable). Everything else with
## JSON backing verifies strictly: builtins are sealed (no script can
## add members to String), classes walk their chain.
static func _read_lenient(info: Dictionary, tname: String) -> bool:
	var kind := str(info.get("kind", ""))
	if kind != "class" and kind != "builtin":
		return true
	if tname == "Variant" or tname == "Dictionary":
		return true
	if bool(info.get("is_keyed", false)):
		return true
	return false


## Engine-backed info or {} (never script user files).
func _engine_info(tname: String) -> Dictionary:
	var info := _type_info(tname)
	if _is_engine_info(info):
		return info
	return {}


## Resolves a chain base name to {"kind", ...}:
## - {"kind": "skip"}: super/unknown/dynamic.
## - {"kind": "signal"}: signal-typed base (SIGNAL_METHODS apply).
## - {"kind": "class", "tname"}: engine class (static context).
## - {"kind": "script", "key"}: script class or self (owner key).
## - {"kind": "instance", "types": [...]}: known value types (engine
##   or script names; resolved per segment).
func _flow_base(vname: String, fn: Variant, scope: Dictionary, owner: String, env: Dictionary, overlay: Dictionary) -> Dictionary:
	if vname == "" or vname == "_":
		return {"kind": "skip"}
	if (overlay as Dictionary).has(vname):
		return {"kind": "skip"}
	if (env as Dictionary).has(vname):
		var et: Array = (env as Dictionary)[vname]
		if et.is_empty():
			return {"kind": "skip"}
		return {"kind": "instance", "types": et.duplicate()}
	if vname == "super":
		return {"kind": "skip"}
	if vname == "self":
		return {"kind": "script", "key": owner}
	var fnd: Dictionary = fn if fn is Dictionary else {}
	var kind := _scope_kind(scope, vname)
	if kind != "":
		if kind == "param":
			var pnode := _find_param_node(fnd.get("params", []), vname)
			if pnode.is_empty():
				return {"kind": "skip"}
			return {"kind": "instance", "types": _flow_decl_types(pnode, false, true)}
		if kind == "local" or kind == "const":
			var decl := _find_body_decl(fnd.get("body", null), vname)
			if decl.is_empty():
				return {"kind": "skip"}
			return {"kind": "instance", "types": _flow_decl_types(decl, str(decl.get("type", "")) == "CONST_DECL", false)}
		if kind == "signal":
			return {"kind": "signal"}
		return {"kind": "skip"}
	for o in [owner, ""]:
		var n := _member_var_node(str(o), vname)
		if not n.is_empty():
			return {"kind": "instance", "types": _flow_decl_types(n, str(n.get("type", "")) == "CONST_DECL", false)}
	for o2 in [owner, ""]:
		var key2 := str(o2)
		if _members.has(key2) and (_members[key2] as Dictionary).has(vname):
			var rec: Dictionary = (_members[key2] as Dictionary)[vname]
			if str(rec.get("kind", "")) == "signal":
				return {"kind": "signal"}
	var skey := _script_key_of(vname, owner)
	if skey != "" or (vname == _script_class and vname != ""):
		if skey == "":
			return {"kind": "script", "key": ""}
		return {"kind": "script", "key": skey}
	if not _tuple_def(vname).is_empty():
		return {"kind": "tuple", "name": vname}
	if _engine_info(vname).is_empty():
		return {"kind": "skip"}
	return {"kind": "class", "tname": vname}


## Resolves one link name to {"kind": "script", "key"} (script classes
## win over engine names), {"kind": "engine", "name"}, or {} when
## neither (dynamic/unknown: caller skips silently).
func _link_kind_of(tname: String, ctx: String) -> Dictionary:
	if tname == "":
		return {}
	if tname == _script_class and tname != "":
		return {"kind": "script", "key": ""}
	var sk := _script_key_of(tname, ctx)
	if sk != "":
		return {"kind": "script", "key": sk}
	if not _tuple_def(tname).is_empty():
		return {"kind": "tuple", "name": tname}
	if _engine_info(tname).is_empty():
		return {}
	return {"kind": "engine", "name": tname}


static func _show_types(types: Array) -> String:
	if types.size() == 1:
		return str(types[0])
	return "|".join(types)


## Verifies one chain segment against a union type list, walking each
## type's inheritance_chain (methods live on ancestors: hide/show are
## CanvasItem's, not Control's). Ok iff ANY listed engine type has it
## (a non-engine or partially-dumped member means "might have it":
## skip silently). CALLS missing everywhere error (missing_method)
## unless quiet; READS never error here (the chain loop decides reads
## separately). Returns {"vtype"} for continuation ("" = unknown:
## rest of the chain skips).
func _verify_seg(types: Array, seg: String, is_call: bool, static_ctx: bool, tok: Dictionary, owner: String, quiet := false) -> Dictionary:
	var fully_walked := true
	for t in types:
		var chain := _engine_chain(str(t))
		if chain.is_empty():
			if _engine_info(str(t)).is_empty():
				fully_walked = false
			continue
		for link in chain:
			var info := _engine_info(str(link))
			if info.is_empty():
				fully_walked = false
				continue
			if is_call:
				var hit := _engine_call(info, seg)
				if not hit.is_empty():
					return {"vtype": str(hit.get("returns", ""))}
			else:
				var hit2 := _engine_read(info, seg, static_ctx)
				if not hit2.is_empty():
					return {"vtype": str(hit2.get("type", "")), "enumvals": hit2.get("enumvals", []), "enumname": str(hit2.get("enumname", ""))}
	if not fully_walked:
		return {"vtype": ""}
	if is_call and not quiet:
		_error(ERR_MISSING_METHOD, "type '" + _show_types(types) + "' has no method '" + seg + "()'", int(tok.get("line", 0)), int(tok.get("column", 0)), owner)
	return {"vtype": ""}


## Index of the bracket matching tokens[open_idx], or -1.
static func _match_close(tokens: Array, open_idx: int) -> int:
	if open_idx < 0 or open_idx >= tokens.size() or not (tokens[open_idx] is Dictionary):
		return -1
	var o := str((tokens[open_idx] as Dictionary).get("type", ""))
	var want := ""
	if o == "LPAREN":
		want = "RPAREN"
	elif o == "LBRACKET":
		want = "RBRACKET"
	elif o == "LBRACE":
		want = "RBRACE"
	else:
		return -1
	var depth := 0
	var i := open_idx
	while i < tokens.size():
		if tokens[i] is Dictionary:
			var ty := str((tokens[i] as Dictionary).get("type", ""))
			if ty == o:
				depth += 1
			elif ty == want:
				depth -= 1
				if depth == 0:
					return i
		i += 1
	return -1


## Verifies an argument/group span (tokens between open_idx and its
## match) and returns the match index (tokens.size() when unbalanced).
func _verify_span(tokens: Array, open_idx: int, scope: Dictionary, owner: String, fn: Variant, env: Dictionary, overlay: Dictionary) -> int:
	var close := _match_close(tokens, open_idx)
	if close < 0:
		return tokens.size()
	if close > open_idx + 1:
		_verify_tokens(tokens.slice(open_idx + 1, close), scope, owner, fn, env, overlay)
	return close


## Advances past DOT-name pairs without checks (unknown base), still
## verifying nested argument spans. Returns the index past the chain.
func _skip_chain_verify(tokens: Array, j: int, scope: Dictionary, owner: String, fn: Variant, env: Dictionary, overlay: Dictionary) -> int:
	while j < tokens.size() and (tokens[j] is Dictionary) and str((tokens[j] as Dictionary).get("type", "")) == "DOT":
		j += 1
		if j >= tokens.size() or not (tokens[j] is Dictionary):
			break
		var nt := str((tokens[j] as Dictionary).get("type", ""))
		if nt != "IDENTIFIER" and nt != "BUILTIN_TYPE" and nt != "KEYWORD":
			break
		j += 1
		if j < tokens.size() and (tokens[j] is Dictionary) and str((tokens[j] as Dictionary).get("type", "")) == "LPAREN":
			j = _verify_span(tokens, j, scope, owner, fn, env, overlay) + 1
	return j


## Verifies one DOT chain starting at tokens[i] (an IDENTIFIER).
## Links unify engine names and script owner keys: each segment is
## checked against script tables (own, extends walk, terminal engine
## base) and engine files, ok iff ANY link has it. Provable absence
## errors (missing_method for calls; missing_member for reads on
## Object-derived or script types only — builtin reads stay lenient:
## Color.RED-style enum reads have no JSON backing). Anything
## unresolvable silences the rest of the chain. Returns the index past
## the chain.
func _verify_chain(tokens: Array, i: int, scope: Dictionary, owner: String, fn: Variant, env: Dictionary, overlay: Dictionary) -> int:
	var base := str((tokens[i] as Dictionary).get("value", ""))
	var fb := _flow_base(base, fn, scope, owner, env, overlay)
	var j := i + 1
	var kind := str(fb.get("kind", ""))
	if kind == "skip":
		return _skip_chain_verify(tokens, j, scope, owner, fn, env, overlay)
	var signal_mode := kind == "signal"
	var static_ctx := kind == "class" or kind == "script"
	var links: Array = []
	var ctx := owner
	if kind == "instance":
		for t in (fb.get("types", []) as Array):
			var l := _link_kind_of(str(t), owner)
			if l.is_empty():
				return _skip_chain_verify(tokens, j, scope, owner, fn, env, overlay)
			links.append(l)
	elif kind == "class":
		var lc := _link_kind_of(str(fb.get("tname", "")), owner)
		if lc.is_empty():
			return _skip_chain_verify(tokens, j, scope, owner, fn, env, overlay)
		links.append(lc)
	elif kind == "script":
		links = [{"kind": "script", "key": str(fb.get("key", ""))}]
		ctx = str(fb.get("key", ""))
	elif kind == "tuple":
		links = [{"kind": "tuple", "name": str(fb.get("name", ""))}]
	if links.is_empty():
		return _skip_chain_verify(tokens, j, scope, owner, fn, env, overlay)
	while j < tokens.size() and (tokens[j] is Dictionary) and str((tokens[j] as Dictionary).get("type", "")) == "DOT":
		j += 1
		if j >= tokens.size() or not (tokens[j] is Dictionary):
			break
		var nt := str((tokens[j] as Dictionary).get("type", ""))
		if nt != "IDENTIFIER" and nt != "BUILTIN_TYPE" and nt != "KEYWORD":
			break
		var seg := str((tokens[j] as Dictionary).get("value", ""))
		if seg == "new":
			if links.size() == 1 and static_ctx and (str(links[0].get("kind", "")) == "script" or str(links[0].get("kind", "")) == "engine"):
				static_ctx = false
				signal_mode = false
			else:
				return _skip_chain_verify(tokens, j - 1, scope, owner, fn, env, overlay)
			j += 1
			continue
		var is_call := j + 1 < tokens.size() and (tokens[j + 1] is Dictionary) and str((tokens[j + 1] as Dictionary).get("type", "")) == "LPAREN"
		if signal_mode:
			if not (seg in SIGNAL_METHODS):
				_error(ERR_MISSING_METHOD, "signal has no method '" + seg + "'", int((tokens[j] as Dictionary).get("line", 0)), int((tokens[j] as Dictionary).get("column", 0)), owner)
			if is_call:
				j = _verify_span(tokens, j + 1, scope, owner, fn, env, overlay)
			j += 1
			continue
		var found := false
		var silent := false
		var sure_miss := false
		var read_strict := true
		var engine_names: Array = []
		var dnames: Array = []
		var next_links: Array = []
		var next_ctx := ctx
		for L in links:
			if not (L is Dictionary):
				silent = true
				continue
			if str(L.get("kind", "")) == "enumvals":
				var dname := str(L.get("dname", seg))
				if seg in (L.get("vals", []) as Array):
					found = true
					next_links.append({"kind": "engine", "name": "int"})
					dnames.append(dname)
				else:
					sure_miss = true
					dnames.append(dname)
				continue
			if str(L.get("kind", "")) == "tuple":
				var tname := str(L.get("name", ""))
				var av := _verify_seg(["Array"], seg, is_call, false, tokens[j], owner, true)
				var avt := str(av.get("vtype", ""))
				if avt != "":
					found = true
					var al := _link_kind_of(avt, next_ctx)
					if al.is_empty():
						silent = true
					else:
						next_links.append(al)
				else:
					sure_miss = true
				dnames.append(tname)
				continue
			if str(L.get("kind", "")) == "script":
				var r := _script_seg(str(L.get("key", "")), seg, is_call)
				var status := str(r.get("status", ""))
				if status == "found":
					found = true
					var cont: Dictionary = r.get("cont", {})
					if not (cont.get("enumvals", []) as Array).is_empty():
						next_links.append({"kind": "enumvals", "vals": (cont.get("enumvals", []) as Array).duplicate(), "dname": str(cont.get("enumname", seg))})
					elif cont.has("signal"):
						signal_mode = true
					elif cont.has("script"):
						next_links.append({"kind": "script", "key": str(cont.get("script", ""))})
						next_ctx = str(cont.get("script", ""))
					else:
						for cn in (cont.get("types", []) as Array):
							var cl := _link_kind_of(str(cn), next_ctx)
							if cl.is_empty():
								silent = true
							else:
								next_links.append(cl)
					dnames.append(_owner_display(str(L.get("key", ""))))
				elif status == "miss-skip":
					silent = true
				elif status == "miss-engine":
					engine_names.append(str(r.get("base", "")))
					dnames.append(str(r.get("base", "")))
				else:
					sure_miss = true
					dnames.append(_owner_display(str(L.get("key", ""))))
			else:
				var ename := str(L.get("name", ""))
				var einfo := _engine_info(ename)
				if einfo.is_empty():
					silent = true
					continue
				if _read_lenient(einfo, ename):
					read_strict = false
				engine_names.append(ename)
				dnames.append(ename)
		if found:
			if not engine_names.is_empty():
				var extra := _verify_seg(engine_names, seg, is_call, static_ctx, tokens[j], owner, true)
				var vt := str(extra.get("vtype", ""))
				if vt != "" and vt != "signal":
					var vl := _link_kind_of(vt, next_ctx)
					if vl.is_empty():
						silent = true
					else:
						next_links.append(vl)
				elif vt == "signal" and next_links.is_empty():
					signal_mode = true
			links = next_links
			ctx = next_ctx
			static_ctx = false
			if links.is_empty() and not signal_mode:
				return _skip_chain_verify(tokens, j - 1, scope, owner, fn, env, overlay)
			if is_call:
				j = _verify_span(tokens, j + 1, scope, owner, fn, env, overlay)
			j += 1
			continue
		if silent:
			return _skip_chain_verify(tokens, j - 1, scope, owner, fn, env, overlay)
		if engine_names.is_empty():
			_error(ERR_MISSING_METHOD if is_call else ERR_MISSING_MEMBER, "type '" + _show_types(dnames) + "' has no " + ("method '" + seg + "()'" if is_call else "member '" + seg + "'"), int((tokens[j] as Dictionary).get("line", 0)), int((tokens[j] as Dictionary).get("column", 0)), owner)
			return _skip_chain_verify(tokens, j - 1, scope, owner, fn, env, overlay)
		if is_call:
			var verdict := _verify_seg(engine_names, seg, is_call, static_ctx, tokens[j], owner)
			var vt2 := str(verdict.get("vtype", ""))
			links = []
			ctx = owner
			if vt2 == "signal":
				signal_mode = true
			elif vt2 != "":
				var vl2 := _link_kind_of(vt2, ctx)
				if vl2.is_empty():
					return _skip_chain_verify(tokens, j, scope, owner, fn, env, overlay)
				links = [vl2]
				static_ctx = false
			j = _verify_span(tokens, j + 1, scope, owner, fn, env, overlay)
			j += 1
			continue
		var qverdict := _verify_seg(engine_names, seg, false, static_ctx, tokens[j], owner, true)
		var qvt := str(qverdict.get("vtype", ""))
		var qvals: Array = qverdict.get("enumvals", [])
		if qvt == "signal":
			signal_mode = true
		elif not qvals.is_empty():
			links = [{"kind": "enumvals", "vals": qvals.duplicate(), "dname": str(qverdict.get("enumname", seg))}]
			static_ctx = false
		elif qvt != "":
			var ql := _link_kind_of(qvt, ctx)
			if ql.is_empty():
				return _skip_chain_verify(tokens, j - 1, scope, owner, fn, env, overlay)
			links = [ql]
			static_ctx = false
		elif not read_strict:
			return _skip_chain_verify(tokens, j - 1, scope, owner, fn, env, overlay)
		else:
			_error(ERR_MISSING_MEMBER, "type '" + _show_types(dnames) + "' has no member '" + seg + "'", int((tokens[j] as Dictionary).get("line", 0)), int((tokens[j] as Dictionary).get("column", 0)), owner)
			return _skip_chain_verify(tokens, j - 1, scope, owner, fn, env, overlay)
		j += 1
		continue
	return j


## Collects raw-soup lambda parameter names into overlay. Returns the
## index of the closing RPAREN (or nearby on garbage).
static func _flow_absorb_params(tokens: Array, at: int, overlay: Dictionary) -> int:
	var i := at + 1
	if i >= tokens.size() or not (tokens[i] is Dictionary) or str((tokens[i] as Dictionary).get("type", "")) != "LPAREN":
		return at + 1
	var depth := 0
	i += 1
	while i < tokens.size():
		if not (tokens[i] is Dictionary):
			i += 1
			continue
		var ty := str((tokens[i] as Dictionary).get("type", ""))
		if ty == "LPAREN":
			depth += 1
		elif ty == "RPAREN":
			if depth == 0:
				return i
			depth -= 1
		elif ty == "IDENTIFIER" and depth == 0:
			(overlay as Dictionary)[str((tokens[i] as Dictionary).get("value", ""))] = true
		i += 1
	return i


## Verifies member accesses in a flat token array with the flow env.
## Bare names/calls are untouched (other rules own them); DOT chains,
## argument spans and grouping spans recurse.
func _verify_tokens(tokens: Array, scope: Dictionary, owner: String, fn: Variant, env: Dictionary, overlay: Dictionary) -> void:
	var i := 0
	while i < tokens.size():
		if not (tokens[i] is Dictionary):
			i += 1
			continue
		var t: Dictionary = tokens[i]
		var ty := str(t.get("type", ""))
		var v := str(t.get("value", ""))
		if ty == "LAMBDA_MARKER" and t.get("value", null) is Dictionary:
			_flow_lambda_node(t.get("value", {}), scope, owner)
			i += 1
			continue
		if ty == "LAMBDA":
			_flow_lambda_node(t, scope, owner)
			i += 1
			continue
		if ty == "KEYWORD" and v == "func":
			i = _flow_absorb_params(tokens, i, overlay)
			continue
		if ty == "IDENTIFIER" or (ty == "KEYWORD" and (v == "self" or v == "super")):
			var nxt_ty := ""
			var nxt_v := ""
			if i + 1 < tokens.size() and tokens[i + 1] is Dictionary:
				nxt_ty = str((tokens[i + 1] as Dictionary).get("type", ""))
				nxt_v = str((tokens[i + 1] as Dictionary).get("value", ""))
			if nxt_ty == "DOT":
				i = _verify_chain(tokens, i, scope, owner, fn, env, overlay)
				continue
			if nxt_ty == "LPAREN" and nxt_v == "(":
				i = _verify_span(tokens, i + 1, scope, owner, fn, env, overlay) + 1
				continue
			if nxt_ty == "LBRACKET":
				i = _verify_subscript(tokens, i, scope, owner, fn, env, overlay)
				continue
			i += 1
			continue
		if ty == "LPAREN" or ty == "LBRACKET" or ty == "LBRACE":
			i = _verify_span(tokens, i, scope, owner, fn, env, overlay) + 1
			continue
		i += 1


static func _vt_type(tokens: Array, i: int) -> String:
	if i < 0 or i >= tokens.size() or not (tokens[i] is Dictionary):
		return ""
	return str((tokens[i] as Dictionary).get("type", ""))


## Verifies tuple index access `base[...]` starting at tokens[i] (an
## IDENTIFIER base). The inner span always verifies for nested chains.
## A single int literal index bounds-checks (leading `-` wraps from
## the end); a single non-int literal errors (tuples are positional);
## anything else skips (dynamic index yields Variant). Returns the
## index past `]`.
func _verify_subscript(tokens: Array, i: int, scope: Dictionary, owner: String, fn: Variant, env: Dictionary, overlay: Dictionary) -> int:
	var base := str((tokens[i] as Dictionary).get("value", ""))
	var close := _match_close(tokens, i + 1)
	if close < 0:
		return i + 1
	if close > i + 2:
		_verify_tokens(tokens.slice(i + 2, close), scope, owner, fn, env, overlay)
	var def := _tuple_base_def(base, fn, scope, owner, env, overlay)
	if def.is_empty():
		return close + 1
	var inner: Array = []
	if close > i + 2:
		inner = tokens.slice(i + 2, close)
	if inner.is_empty():
		return close + 1
	if inner.size() == 1 and (inner[0] is Dictionary):
		var itt := str((inner[0] as Dictionary).get("type", ""))
		if itt == "INT":
			_check_tuple_index(str(def.get("name", "")), int(def.get("size", 0)), int(str((inner[0] as Dictionary).get("value", "0"))), int((inner[0] as Dictionary).get("line", 0)), owner)
			return close + 1
		if itt == "IDENTIFIER":
			return close + 1
		_error(ERR_TUPLE_BOUNDS, "tuple '" + str(def.get("name", "")) + "' is indexed by int, got '" + str((inner[0] as Dictionary).get("value", "")) + "'", int((inner[0] as Dictionary).get("line", 0)), int((inner[0] as Dictionary).get("column", 0)), owner)
		return close + 1
	if inner.size() == 2 and (inner[0] is Dictionary) and str((inner[0] as Dictionary).get("type", "")) == "OPERATOR" and str((inner[0] as Dictionary).get("value", "")) == "-" and (inner[1] is Dictionary) and str((inner[1] as Dictionary).get("type", "")) == "INT":
		_check_tuple_index(str(def.get("name", "")), int(def.get("size", 0)), -int(str((inner[1] as Dictionary).get("value", "0"))), int((inner[1] as Dictionary).get("line", 0)), owner)
		return close + 1
	return close + 1


## Bounds-checks one tuple index (negative wraps from the end).
func _check_tuple_index(tname: String, size: int, idx: int, line: int, owner: String) -> void:
	if idx >= 0 and idx < size:
		return
	if idx < 0 and idx >= -size:
		return
	_error(ERR_TUPLE_BOUNDS, "index " + str(idx) + " out of bounds for tuple '" + tname + "' of size " + str(size), line, 0, owner)


## Tuple definition {name, size} for a chain base, or {} when the base
## is not tuple-typed (then subscripts verify inner chains only).
func _tuple_base_def(base: String, fn: Variant, scope: Dictionary, owner: String, env: Dictionary, overlay: Dictionary) -> Dictionary:
	var fb := _flow_base(base, fn, scope, owner, env, overlay)
	if str(fb.get("kind", "")) != "instance":
		return {}
	for t in (fb.get("types", []) as Array):
		var def := _tuple_def(str(t))
		if not def.is_empty():
			return {"name": str(t), "size": int(def.get("size", 0))}
	return {}


static func _vt_val(tokens: Array, i: int) -> String:
	if i < 0 or i >= tokens.size() or not (tokens[i] is Dictionary):
		return ""
	return str((tokens[i] as Dictionary).get("value", ""))


## [start, end) bounds of a guard condition, stripping outer balanced
## parens. Operates on the token array as given (slices welcome).
static func _guard_bounds(tokens: Array) -> Array:
	var s := 0
	var e := tokens.size()
	while e - s >= 2 and _vt_type(tokens, s) == "LPAREN" and _match_close(tokens, s) == e - 1:
		s += 1
		e -= 1
	return [s, e]


## Recognizes `typeof(x) == TYPE_Y` / `!=` (outer parens and a leading
## not/! flip polarity). Returns {name, types, eq} or {}.
func _guard_typeof(tokens: Array) -> Dictionary:
	var be := _guard_bounds(tokens)
	var s := int(be[0])
	var e := int(be[1])
	var neg := false
	if s < e and ((_vt_type(tokens, s) == "KEYWORD" and _vt_val(tokens, s) == "not") or (_vt_type(tokens, s) == "OPERATOR" and _vt_val(tokens, s) == "!")):
		neg = true
		s += 1
	if e - s < 6:
		return {}
	if not (_vt_type(tokens, s) == "IDENTIFIER" and _vt_val(tokens, s) == "typeof"):
		return {}
	if _vt_type(tokens, s + 1) != "LPAREN":
		return {}
	if _vt_type(tokens, s + 2) != "IDENTIFIER":
		return {}
	if _match_close(tokens, s + 1) != s + 3:
		return {}
	if _vt_type(tokens, s + 4) != "OPERATOR":
		return {}
	var op := _vt_val(tokens, s + 4)
	if op != "==" and op != "!=":
		return {}
	var parts := _dotted_parts(tokens, s + 5, e)
	if parts.is_empty():
		return {}
	var last := str(parts[parts.size() - 1])
	if not VARIANT_TYPE_MAP.has(last):
		return {}
	var tname := str(VARIANT_TYPE_MAP[last])
	if tname == "" or not _type_known(tname):
		return {}
	var eq := op == "=="
	if neg:
		eq = not eq
	return {"name": _vt_val(tokens, s + 2), "types": [tname], "eq": eq}


## Dotted (or bare) value tokens shaped like a type reference: single
## IDENTIFIER/BUILTIN_TYPE or DOT-joined parts. Returns the dotted
## name or "" on any other shape.
static func _dotted_parts(tokens: Array, s: int, e: int) -> Array:
	var parts: Array = []
	var k := s
	while k < e:
		var kt := _vt_type(tokens, k)
		if kt == "DOT":
			k += 1
			continue
		if kt != "IDENTIFIER" and kt != "BUILTIN_TYPE":
			return []
		parts.append(_vt_val(tokens, k))
		k += 1
	return parts


## Recognizes `x is Y` / `x is not Y` (leading not/! flips). Y must be
## a single known type name (dotted paths are skipped: without engine
## backing they could not verify anything anyway). Returns
## {name, types, eq} or {}.
func _guard_is(tokens: Array) -> Dictionary:
	var be := _guard_bounds(tokens)
	var s := int(be[0])
	var e := int(be[1])
	var neg := false
	if s < e and ((_vt_type(tokens, s) == "KEYWORD" and _vt_val(tokens, s) == "not") or (_vt_type(tokens, s) == "OPERATOR" and _vt_val(tokens, s) == "!")):
		neg = true
		s += 1
	if e - s != 3 and e - s != 4:
		return {}
	if _vt_type(tokens, s) != "IDENTIFIER":
		return {}
	if not (_vt_type(tokens, s + 1) == "KEYWORD" and _vt_val(tokens, s + 1) == "is"):
		return {}
	var idx := s + 2
	var positive := true
	if e - s == 4:
		if not (_vt_type(tokens, s + 2) == "KEYWORD" and _vt_val(tokens, s + 2) == "not"):
			return {}
		positive = false
		idx = s + 3
	var ytype := _vt_type(tokens, idx)
	if ytype != "IDENTIFIER" and ytype != "BUILTIN_TYPE":
		return {}
	var yname := _vt_val(tokens, idx)
	if yname == "" or not _type_known(yname):
		return {}
	var eq := positive
	if neg:
		eq = not eq
	return {"name": _vt_val(tokens, s), "types": [yname], "eq": eq}


## Maps value tokens shaped like a Variant.Type constant (bare
## `TYPE_X` or dotted `Variant.Type.TYPE_X`) to the narrowed type
## name, or "" when the shape does not match.
func _const_type_tokens(tokens: Array) -> String:
	var parts := _dotted_parts(tokens, 0, tokens.size())
	if parts.is_empty():
		return ""
	var last := str(parts[parts.size() - 1])
	if not VARIANT_TYPE_MAP.has(last):
		return ""
	var tname := str(VARIANT_TYPE_MAP[last])
	if tname == "" or not _type_known(tname):
		return ""
	return tname


## Resolves a name holding a Variant.Type constant (a local/const
## initialized with one, a member, or a parameter default) to the
## narrowed type name, or "". Reassignments are not tracked: the
## initializer shape alone decides.
func _guard_const_type(vname: String, fn: Variant, scope: Dictionary, owner: String) -> String:
	var fnd: Dictionary = fn if fn is Dictionary else {}
	if _scope_kind(scope, vname) == "param":
		var pnode := _find_param_node(fnd.get("params", []), vname)
		if not pnode.is_empty():
			return _const_type_tokens(_as_tokens((pnode as Dictionary).get("default", null)))
	var decl := _find_body_decl(fnd.get("body", null), vname)
	if not decl.is_empty():
		return _const_type_tokens(_as_tokens(decl.get("value", null)))
	for o in [owner, ""]:
		var n := _member_var_node(str(o), vname)
		if not n.is_empty():
			return _const_type_tokens(_as_tokens(n.get("value", null)))
	return ""


## Recognizes `is_instance_of(x, T)` (leading not/! flips). T is a
## known type name, a Variant.Type constant (`TYPE_X` or
## `Variant.Type.TYPE_X`), or a variable holding one. `is` demands a
## constant, but is_instance_of resolves at runtime, so variables work
## here. Returns {name, types, eq} or {}.
func _guard_instanceof(tokens: Array, fn: Variant, scope: Dictionary, owner: String) -> Dictionary:
	var be := _guard_bounds(tokens)
	var s := int(be[0])
	var e := int(be[1])
	var neg := false
	if s < e and ((_vt_type(tokens, s) == "KEYWORD" and _vt_val(tokens, s) == "not") or (_vt_type(tokens, s) == "OPERATOR" and _vt_val(tokens, s) == "!")):
		neg = true
		s += 1
	if e - s < 6:
		return {}
	if not (_vt_type(tokens, s) == "IDENTIFIER" and _vt_val(tokens, s) == "is_instance_of"):
		return {}
	if _vt_type(tokens, s + 1) != "LPAREN" or _match_close(tokens, s + 1) != e - 1:
		return {}
	if _vt_type(tokens, s + 2) != "IDENTIFIER":
		return {}
	if _vt_type(tokens, s + 3) != "COMMA":
		return {}
	var tstart := s + 4
	var tend := e - 1
	if tstart >= tend:
		return {}
	var tfirst := _vt_type(tokens, tstart)
	var resolved := ""
	if tfirst == "IDENTIFIER" or tfirst == "BUILTIN_TYPE":
		var tname := _vt_val(tokens, tstart)
		if tstart + 1 >= tend:
			if _type_known(tname):
				resolved = tname
			elif VARIANT_TYPE_MAP.has(tname):
				var mapped := str(VARIANT_TYPE_MAP[tname])
				if mapped != "" and _type_known(mapped):
					resolved = mapped
			else:
				resolved = _guard_const_type(tname, fn, scope, owner)
		else:
			var parts := _dotted_parts(tokens, tstart, tend)
			if not parts.is_empty():
				var last := str(parts[parts.size() - 1])
				if VARIANT_TYPE_MAP.has(last):
					var mapped2 := str(VARIANT_TYPE_MAP[last])
					if mapped2 != "" and _type_known(mapped2):
						resolved = mapped2
	if resolved == "":
		return {}
	var eq := not neg
	return {"name": _vt_val(tokens, s + 2), "types": [resolved], "eq": eq}


## Any recognized guard: typeof first, then `is`, then
## is_instance_of. Shapes are mutually exclusive; first hit wins.
func _flow_guard(tokens: Array, fn: Variant, scope: Dictionary, owner: String) -> Dictionary:
	var g := _guard_typeof(tokens)
	if not g.is_empty():
		return g
	g = _guard_is(tokens)
	if not g.is_empty():
		return g
	return _guard_instanceof(tokens, fn, scope, owner)


## Builds a function scope for the flow pass (params + collected
## bindings, chained to the incoming scope). Mirrors _walk_func.
func _flow_fn_scope(fn: Dictionary, scope: Dictionary) -> Dictionary:
	var fs = _new_scope(scope)
	for p in fn.get("params", []):
		if p is Dictionary:
			_scope_add(fs, str((p as Dictionary).get("name", "")), "param")
	_collect_func_bindings(fn.get("body", null), fs)
	return fs


## Applies free-@var facts from one statement: leading specs on
## non-declaration statements plus the statement itself when it is a
## standalone @var TYPE_INFO. Before-decl VAR/CONST leading is skipped
## (already the initial reference via var_ann). Malformed or
## unresolvable specs are skipped (the walk pass already reported).
func _flow_facts(node: Dictionary, scope: Dictionary, owner: String, fn: Variant, env: Dictionary) -> void:
	if str(node.get("type", "")) == "VAR_DECL" or str(node.get("type", "")) == "CONST_DECL":
		return
	var specs: Array = []
	if str(node.get("type", "")) == "TYPE_INFO":
		for spec in _extract_tok_tags(node, owner, "var", "@var", ERR_VAR_MALFORMED):
			specs.append(spec)
	else:
		for spec in _extract_var_tags(node, owner):
			specs.append(spec)
	var fnd: Dictionary = fn if fn is Dictionary else {}
	for spec in specs:
		if not (spec is Dictionary):
			continue
		var vname := str((spec as Dictionary).get("name", ""))
		var target := _free_var_target(vname, fnd, scope, owner)
		if target.is_empty() or target.has("bad"):
			continue
		(env as Dictionary)[vname] = ((spec as Dictionary).get("types", []) as Array).duplicate()


## Flow pass over one statement with the current env (mutated by
## facts, branched by guards). fn is the enclosing function/lambda.
func _flow_stmt(node: Dictionary, scope: Dictionary, owner: String, fn: Variant, env: Dictionary) -> void:
	var t := str(node.get("type", ""))
	if t == "FUNC_DECL":
		_flow_func(node, scope, owner)
		return
	if t == "CLASS_DECL":
		var full := _full_name(owner, str(node.get("name", "")))
		var cscope = _new_scope(scope)
		var ext: Variant = node.get("extends_type", null)
		if ext is Dictionary:
			_verify_tokens(_as_tokens(ext), cscope, full, null, {}, {})
		var cbody: Variant = node.get("body", null)
		if cbody is Dictionary:
			_flow_members((cbody as Dictionary).get("children", []), cscope, full)
		return
	if t == "VAR_DECL" or t == "CONST_DECL":
		_verify_tokens(_as_tokens(node.get("value", null)), scope, owner, fn, env, {})
		_flow_lambda_value(node.get("value", null), scope, owner)
		var acc: Variant = node.get("accessors", null)
		if acc is Dictionary:
			_flow_accessor(acc, scope, owner)
		return
	if t == "EXPR_STMT":
		_flow_facts(node, scope, owner, fn, env)
		_verify_tokens(_as_tokens(node.get("expr", null)), scope, owner, fn, env, {})
		_flow_lambda_value(node.get("expr", null), scope, owner)
		return
	if t == "TYPE_INFO":
		_flow_facts(node, scope, owner, fn, env)
		return
	if t == "IF_STMT":
		var cond := _as_tokens(node.get("condition", null))
		_verify_tokens(cond, scope, owner, fn, env, {})
		var g := _flow_guard(cond, fn, scope, owner)
		var then_env := env.duplicate()
		var else_env := env.duplicate()
		if not g.is_empty():
			var fnd: Dictionary = fn if fn is Dictionary else {}
			var target := _free_var_target(str(g.get("name", "")), fnd, scope, owner)
			if not target.is_empty() and not target.has("bad"):
				if bool(g.get("eq", true)):
					then_env[str(g.get("name", ""))] = (g.get("types", []) as Array).duplicate()
				else:
					else_env[str(g.get("name", ""))] = (g.get("types", []) as Array).duplicate()
		_flow_block(node.get("then", null), scope, owner, fn, then_env)
		for e in node.get("elifs", []):
			if e is Dictionary:
				_verify_tokens(_as_tokens((e as Dictionary).get("condition", null)), scope, owner, fn, env, {})
				_flow_block((e as Dictionary).get("body", null), scope, owner, fn, env.duplicate())
		if node.get("else_body", null) is Dictionary:
			_flow_block(node.get("else_body", null), scope, owner, fn, else_env)
		return
	if t == "FOR_STMT":
		_verify_tokens(_as_tokens(node.get("iter", null)), scope, owner, fn, env, {})
		_flow_block(node.get("body", null), scope, owner, fn, env.duplicate())
		return
	if t == "WHILE_STMT":
		_verify_tokens(_as_tokens(node.get("condition", null)), scope, owner, fn, env, {})
		_flow_block(node.get("body", null), scope, owner, fn, env.duplicate())
		return
	if t == "MATCH_STMT":
		_verify_tokens(_as_tokens(node.get("subject", null)), scope, owner, fn, env, {})
		for b in node.get("branches", []):
			if b is Dictionary and str((b as Dictionary).get("type", "")) == "MATCH_BRANCH":
				_verify_tokens(_as_tokens((b as Dictionary).get("pattern", null)), scope, owner, fn, env, {})
				_flow_block((b as Dictionary).get("body", null), scope, owner, fn, env.duplicate())
		return
	if t == "RETURN_STMT":
		_verify_tokens(_as_tokens(node.get("value", null)), scope, owner, fn, env, {})
		return
	if t == "ASSERT_STMT":
		_verify_tokens(_flat_tokens(node.get("args", [])), scope, owner, fn, env, {})
		return
	if t == "ACCESSOR":
		_flow_accessor(node, scope, owner)
		return
	if t == "LAMBDA":
		_flow_lambda_node(node, scope, owner)
		return
	if t == "BLOCK":
		_flow_block(node.get("children", []), scope, owner, fn, env)
		return
	if t == "ENUM_DECL":
		for m in node.get("members", []):
			if m is Dictionary and str((m as Dictionary).get("type", "")) == "ENUM_MEMBER":
				_verify_tokens(_as_tokens((m as Dictionary).get("value", null)), scope, owner, fn, env, {})
		return
	if t == "EXTENDS":
		_verify_tokens(_flat_tokens(node.get("path", [])), scope, owner, fn, env, {})
		return
	_flow_facts(node, scope, owner, fn, env)


## Flow pass over a BLOCK node or statement array.
func _flow_block(node: Variant, scope: Dictionary, owner: String, fn: Variant, env: Dictionary) -> void:
	if node is Array:
		for e in node:
			if e is Dictionary:
				_flow_stmt(e, scope, owner, fn, env)
		return
	if not (node is Dictionary):
		return
	var d: Dictionary = node
	if str(d.get("type", "")) == "BLOCK":
		_flow_block(d.get("children", []), scope, owner, fn, env)
		return
	_flow_stmt(d, scope, owner, fn, env)


## Flow pass over member-level children (script top or class body).
func _flow_members(children: Variant, scope: Dictionary, owner: String) -> void:
	if not (children is Array):
		return
	for child in children:
		if not (child is Dictionary):
			continue
		_flow_stmt(child, scope, owner, null, {})


## Fresh-env flow for a named function (its own guards/facts).
func _flow_func(node: Dictionary, scope: Dictionary, owner: String) -> void:
	var fs = _flow_fn_scope(node, scope)
	_flow_block(node.get("body", null), fs, owner, node, {})


## Fresh-env flow for a lambda node with the incoming scope chained.
func _flow_lambda_node(node: Dictionary, scope: Dictionary, owner: String) -> void:
	var fs = _flow_fn_scope(node, scope)
	_flow_block(node.get("body", null), fs, owner, node, {})


## Runs fresh-env flow when a statement value/expression is a LAMBDA
## node. No-op otherwise.
func _flow_lambda_value(v: Variant, scope: Dictionary, owner: String) -> void:
	if v is Dictionary and str((v as Dictionary).get("type", "")) == "LAMBDA":
		_flow_lambda_node(v, scope, owner)


## Accessor bodies are not functions: fresh env, no free-@var facts
## (misplaced tags already errored in the scan pass).
func _flow_accessor(node: Dictionary, scope: Dictionary, owner: String) -> void:
	var ascope = _new_scope(scope)
	for p in node.get("params", []):
		if p is Dictionary:
			_scope_add(ascope, str((p as Dictionary).get("name", "")), "param")
	_collect_func_bindings(node.get("body", null), ascope)
	_flow_block(node.get("body", null), ascope, owner, null, {})


# ------------------------------------------------------- user JSON files

## Updates types_info/user files: main script file plus one per inner
## class (dotted names). Existing files are patched (deprecated flags
## plus analysis lists); missing files get a minimal equivalent.
func _update_user_files(ast: Dictionary) -> void:
	var base_name = SemParser.user_file_base(_script_class, _script_resource_path, "")
	var root_prefix = _script_class
	if root_prefix == "":
		root_prefix = base_name
	_ensure_user_dir()
	_write_class_file(base_name, "", ast, root_prefix)
	for item in _inner_full_names(ast, root_prefix, ""):
		_write_class_file(str((item as Dictionary).get("file", "")), str((item as Dictionary).get("owner", "")), ast, root_prefix)


## Inner classes as {file, owner} pairs: file keeps the resource/class
## prefix for unique filenames, owner is the member-table key used by
## the mark and walk passes (identical when class_name is set).
func _inner_full_names(ast: Dictionary, file_prefix: String, owner_prefix: String) -> Array:
	var out: Array = []
	for child in ast.get("children", []):
		if child is Dictionary and str((child as Dictionary).get("type", "")) == "CLASS_DECL":
			_collect_inner_names(child, file_prefix, owner_prefix, out)
	return out


func _collect_inner_names(node: Dictionary, file_prefix: String, owner_prefix: String, out: Array) -> void:
	var iname = str(node.get("name", ""))
	if iname == "":
		return
	var file_full = iname
	if file_prefix != "":
		file_full = file_prefix + "." + iname
	var owner_full = _full_name(owner_prefix, iname)
	out.append({"file": file_full, "owner": owner_full})
	var body: Variant = node.get("body", null)
	if body is Dictionary:
		for child in (body as Dictionary).get("children", []):
			if child is Dictionary and str((child as Dictionary).get("type", "")) == "CLASS_DECL":
				_collect_inner_names(child, file_full, owner_full, out)


func _write_class_file(file_base: String, owner: String, ast: Dictionary, root_prefix: String) -> void:
	var path = _write_base + "/user/" + file_base + ".json"
	var info: Dictionary = _read_json(path)
	if info.is_empty():
		info = _minimal_info(file_base, owner, root_prefix)
	_flag_deprecated(info, owner)
	_flag_private(info, owner)
	info["analysis_errors"] = _issues_for(owner, _errors)
	info["analysis_warnings"] = _issues_for(owner, _warnings)
	_write_json(path, info)
	_written.append(path)


func _issues_for(owner: String, issues: Array) -> Array:
	var out: Array = []
	for e in issues:
		if e is Dictionary and str((e as Dictionary).get("owner", "")) == owner:
			out.append(e)
	return out


func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(parsed) != TYPE_DICTIONARY:
		return {}
	return parsed


func _write_json(path: String, data: Dictionary) -> void:
	var file = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(JSON.stringify(data, "\t"))
	file.close()


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


## Minimal file used when no user JSON exists yet. Member lists carry
## just names plus deprecated flags; analysis lists are attached.
func _minimal_info(file_base: String, owner: String, root_prefix: String) -> Dictionary:
	var info = {
		"name": file_base,
		"kind": "script",
		"class_name": _script_class,
		"resource_path": _script_resource_path,
		"enums": [],
		"constants": [],
		"signals": [],
		"fields": [],
		"static_methods": [],
		"instance_methods": [],
		"inner_classes": [],
	}
	var table: Dictionary = _members.get(owner, {})
	for mname in table.keys():
		var rec: Dictionary = table[mname]
		var entry = {"name": mname}
		if not (rec.get("deprecated", {}) as Dictionary).is_empty():
			entry["deprecated"] = rec["deprecated"]
		var prec = _private_rec_of(owner, mname)
		if not (prec.get("private", {}) as Dictionary).is_empty():
			entry["private"] = prec["private"]
		var kind = str(rec.get("kind", ""))
		if kind == "enum":
			(info["enums"] as Array).append(entry)
		elif kind == "constant":
			(info["constants"] as Array).append(entry)
		elif kind == "signal":
			(info["signals"] as Array).append(entry)
		elif kind == "variable":
			(info["fields"] as Array).append(entry)
		elif kind == "function":
			(info["instance_methods"] as Array).append(entry)
		elif kind == "class":
			(info["inner_classes"] as Array).append({"name": mname, "full_name": mname, "file": mname + ".json"})
	return info


## Private record of a member in an explicit table ({} when absent).
func _private_rec_of(owner: String, mname: String) -> Dictionary:
	if _private.has(owner) and (_private[owner] as Dictionary).has(mname):
		return (_private[owner] as Dictionary)[mname]
	return {}


## Sets "private" on matching member entries of a loaded user file.
func _flag_private(info: Dictionary, owner: String) -> void:
	var table: Dictionary = _private.get(owner, {})
	for mname in table.keys():
		var priv: Dictionary = (table[mname] as Dictionary).get("private", {})
		if priv.is_empty():
			continue
		var flag = {"message": str(priv.get("message", "")), "line": int(priv.get("line", 0))}
		_flag_in_list(info.get("enums", []), mname, flag, "private")
		_flag_in_list(info.get("constants", []), mname, flag, "private")
		_flag_in_list(info.get("signals", []), mname, flag, "private")
		_flag_in_list(info.get("fields", []), mname, flag, "private")
		_flag_in_list(info.get("static_methods", []), mname, flag, "private")
		_flag_in_list(info.get("instance_methods", []), mname, flag, "private")
		_flag_in_list(info.get("inner_classes", []), mname, flag, "private")
		for e in info.get("enums", []):
			if e is Dictionary:
				_flag_in_list((e as Dictionary).get("members", []), mname, flag, "private")
	if owner != "":
		var rec = _owner_priv_record(owner)
		if not rec.is_empty():
			info["private"] = {"message": str(rec.get("message", "")), "line": int(rec.get("line", 0))}


## Private record of an inner class itself (stored under its parent).
func _owner_priv_record(full: String) -> Dictionary:
	var short = full
	if "." in full:
		short = full.substr(full.rfind(".") + 1)
	var parent = ""
	if "." in full:
		parent = full.substr(0, full.rfind("."))
		if _private.has(parent):
			var table: Dictionary = _private[parent]
			if table.has(short):
				return (table[short] as Dictionary).get("private", {})
	elif _private.has("") and (_private[""] as Dictionary).has(short):
		return ((_private[""] as Dictionary)[short] as Dictionary).get("private", {})
	return {}


func _flag_in_list(items: Variant, mname: String, flag: Dictionary, key: String = "deprecated") -> void:
	if not (items is Array):
		return
	for e in items:
		if e is Dictionary and str((e as Dictionary).get("name", "")) == mname:
			(e as Dictionary)[key] = flag


## Sets "deprecated" on matching member entries of a loaded user file.
func _flag_deprecated(info: Dictionary, owner: String) -> void:
	var table: Dictionary = _members.get(owner, {})
	for mname in table.keys():
		var dep: Dictionary = (table[mname] as Dictionary).get("deprecated", {})
		if dep.is_empty():
			continue
		var flag = {"message": str(dep.get("message", "")), "line": int(dep.get("line", 0))}
		_flag_in_list(info.get("enums", []), mname, flag)
		_flag_in_list(info.get("constants", []), mname, flag)
		_flag_in_list(info.get("signals", []), mname, flag)
		_flag_in_list(info.get("fields", []), mname, flag)
		_flag_in_list(info.get("static_methods", []), mname, flag)
		_flag_in_list(info.get("instance_methods", []), mname, flag)
		_flag_in_list(info.get("inner_classes", []), mname, flag)
		for e in info.get("enums", []):
			if e is Dictionary:
				_flag_in_list((e as Dictionary).get("members", []), mname, flag)
	if owner == "":
		if not _script_deprecated.is_empty():
			info["deprecated"] = {"message": str(_script_deprecated.get("message", "")), "line": int(_script_deprecated.get("line", 0))}
	else:
		var rec = _owner_record(owner)
		if not rec.is_empty():
			info["deprecated"] = {"message": str(rec.get("message", "")), "line": int(rec.get("line", 0))}


## Deprecation record of an inner class itself (stored under its parent).
func _owner_record(full: String) -> Dictionary:
	var short = full
	if "." in full:
		short = full.substr(full.rfind(".") + 1)
	var parent = ""
	if "." in full:
		parent = full.substr(0, full.rfind("."))
		if _members.has(parent):
			var table: Dictionary = _members[parent]
			if table.has(short):
				return (table[short] as Dictionary).get("deprecated", {})
	elif _members.has("") and (_members[""] as Dictionary).has(short):
		return ((_members[""] as Dictionary)[short] as Dictionary).get("deprecated", {})
	return {}
