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
var _script_resource_path = ""
var _project_root = ""
var _write_base = "types_info"
var _written: Array = []
## Type file lookups (builtin/classes/user JSON info or miss marker),
## cached per analyze() call for @return name resolution.
var _type_cache: Dictionary = {}


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
	_script_class = ""
	for child in ast.get("children", []):
		if child is Dictionary and str((child as Dictionary).get("type", "")) == "CLASS_NAME":
			_script_class = str((child as Dictionary).get("name", ""))
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
	_scan_children(ast.get("children", []), "")
	var scope = _new_scope(null)
	_walk_members(ast.get("children", []), scope, "")
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


## Looks for @var in a node's leading_comments (first hit wins).
func _leading_var(node: Dictionary) -> Dictionary:
	for c in node.get("leading_comments", []):
		if c is Dictionary:
			var tag = _has_var_tag(c)
			if not tag.is_empty():
				tag["line"] = int((c as Dictionary).get("line", 0))
				return tag
	return {}


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


## Extracts every @param pair from a node's leading_comments into
## [{name,types,raw,line}]. Consecutive @param lines merge into one
## token, so each line is scanned independently. Malformed pairs error
## out (param_malformed) and are skipped.
func _extract_param_tags(node: Dictionary, owner: String) -> Array:
	var out: Array = []
	for c in node.get("leading_comments", []):
		if not (c is Dictionary):
			continue
		if str((c as Dictionary).get("type", "")) != "TYPE_INFO":
			continue
		var tok_line := int((c as Dictionary).get("line", 0))
		var li := 0
		for line in str((c as Dictionary).get("value", "")).split("\n"):
			var tag := _find_tag(line, "param")
			if not tag.is_empty():
				var spec := _parse_var_spec(str(tag.get("message", "")), "@param")
				if not bool(spec.get("ok", false)):
					_error(ERR_PARAM_MALFORMED, str(spec.get("error", "")), tok_line + li, 0, owner)
				else:
					out.append({"name": str(spec.get("name", "")), "types": spec.get("types", []), "raw": str(spec.get("raw", "")), "line": tok_line + li})
			li += 1
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
	if ref != "" and ref != "Variant":
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
## plain `=` (or missing value) means Variant. "" only when inference
## fails (check skipped).
func _var_reference(node: Dictionary, is_const: bool) -> String:
	var vt := _vartype_name(node)
	if vt != "":
		return vt
	if is_const or str(node.get("op", "")) == ":=":
		return _infer_var_value(node.get("value", null))
	return "Variant"


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


## True when a types_info file exists for the name (builtin, classes or
## user under _write_base). Results are cached per analyze() call.
func _type_file_exists(tname: String) -> bool:
	if _type_cache.has(tname):
		return not (_type_cache[tname] as Dictionary).is_empty()
	for sub in ["builtin", "classes", "user"]:
		var info := _read_json(_write_base + "/" + sub + "/" + tname + ".json")
		if not info.is_empty():
			_type_cache[tname] = info
			return true
	_type_cache[tname] = {}
	return false


## inheritance_chain of a type from its JSON file ([] when unknown).
func _engine_chain(tname: String) -> Array:
	if _type_cache.has(tname):
		var hit: Dictionary = _type_cache[tname]
		var chain: Array = hit.get("inheritance_chain", [])
		return chain
	for sub in ["builtin", "classes", "user"]:
		var info := _read_json(_write_base + "/" + sub + "/" + tname + ".json")
		if not info.is_empty():
			_type_cache[tname] = info
			var chain2: Array = info.get("inheritance_chain", [])
			return chain2
	_type_cache[tname] = {}
	return []


## A @return member is known when it is the script class, a script class
## or enum member, or a types_info file exists for it.
func _type_known(tname: String) -> bool:
	if tname != "" and tname == _script_class:
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
func _attach_var_decl(decl_node: Dictionary, tag: Dictionary, owner: String, is_const: bool) -> void:
	var spec := _parse_var_spec(str(tag.get("message", "")))
	var line := int(tag.get("line", int(decl_node.get("line", 0))))
	var col := int(decl_node.get("column", 0))
	if not bool(spec.get("ok", false)):
		_error(ERR_VAR_MALFORMED, str(spec.get("error", "")), line, col, owner)
		return
	var vname := str(spec.get("name", ""))
	if vname != str(decl_node.get("name", "")):
		_error(ERR_VAR_UNKNOWN, "@var '" + vname + "' does not match declared variable '" + str(decl_node.get("name", "")) + "'", line, col, owner)
		return
	for m in spec.get("types", []):
		if not _type_known(str(m)):
			_error(ERR_VAR_UNKNOWN_TYPE, "@var has unknown type '" + str(m) + "'", line, col, owner)
			return
	var ref := _var_reference(decl_node, is_const)
	if ref != "" and ref != "Variant":
		for m in spec.get("types", []):
			if str(m) != ref and not _derives_from(str(m), ref):
				_error(ERR_VAR_MISMATCH, "cannot use @var type '" + str(m) + "' for variable '" + vname + "' declared as '" + ref + "' ('" + str(m) + "' is neither '" + ref + "' nor a subclass of it)", line, col, owner)
	decl_node["var_ann"] = {"name": vname, "types": spec.get("types", []), "raw": str(spec.get("raw", "")), "line": line}


## Marks a VAR_DECL/CONST_DECL node (@var allowed in any position).
func _mark_var_decl(decl_node: Dictionary, owner: String) -> void:
	var tag := _leading_var(decl_node)
	if tag.is_empty():
		return
	_attach_var_decl(decl_node, tag, owner, str(decl_node.get("type", "")) == "CONST_DECL")


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


## Runs one free-@var tag against the visible variables.
func _check_free_var(tag: Dictionary, scope: Dictionary, owner: String, fn_node: Dictionary) -> void:
	var spec := _parse_var_spec(str(tag.get("message", "")))
	var line := int(tag.get("line", 0))
	if not bool(spec.get("ok", false)):
		_error(ERR_VAR_MALFORMED, str(spec.get("error", "")), line, 0, owner)
		return
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
	if ref != "" and ref != "Variant":
		for m in spec.get("types", []):
			if str(m) != ref and not _derives_from(str(m), ref):
				_error(ERR_VAR_MISMATCH, "cannot use @var type '" + str(m) + "' for variable '" + vname + "' declared as '" + ref + "' ('" + str(m) + "' is neither '" + ref + "' nor a subclass of it)", line, 0, owner)


## Collects free-@var tags under a function body: standalone TYPE_INFO
## nodes plus leading tags on non-declaration statements. Never crosses
## a nested function/class/accessor boundary (separate contexts) and
## never takes VAR/CONST leading tags (before-decl use, handled in
## _scan) nor lambda-statement leading tags (they belong to the lambda).
func _free_vars_into(node: Variant, out: Array) -> void:
	if node is Array:
		for e in node:
			_free_vars_into(e, out)
		return
	if not (node is Dictionary):
		return
	var d: Dictionary = node
	var t := str(d.get("type", ""))
	if t == "TYPE_INFO":
		var stag := _has_var_tag(d)
		if not stag.is_empty():
			stag["line"] = int(d.get("line", 0))
			out.append(stag)
		return
	if t == "FUNC_DECL" or t == "LAMBDA" or t == "CLASS_DECL" or t == "ACCESSOR":
		return
	if t == "VAR_DECL" or t == "CONST_DECL":
		return
	if t == "EXPR_STMT":
		var e: Variant = d.get("expr", null)
		if e is Dictionary and str((e as Dictionary).get("type", "")) == "LAMBDA":
			return
	var lt := _leading_var(d)
	if not lt.is_empty():
		out.append(lt)
	for k in d.keys():
		if k in ["tokens", "args", "annotations", "leading_comments", "header_comment", "deprecated", "private", "return_ann", "var_ann", "param_ann", "analyzer_errors", "analyzer_warnings", "semantic_errors", "user_types_written", "value", "expr"]:
			continue
		_free_vars_into(d[k], out)


## Runs the free-@var checks over a function body with its scope.
## fn_node null means "not a function" (accessor bodies): every tag
## found is misplaced.
func _process_free_vars(body: Variant, scope: Dictionary, owner: String, fn_node: Variant) -> void:
	var found: Array = []
	_free_vars_into(body, found)
	for tag in found:
		if not (tag is Dictionary):
			continue
		if fn_node == null:
			_error(ERR_VAR_MISPLACED, "@var redefinition is only allowed inside a function body", int((tag as Dictionary).get("line", 0)), 0, owner)
			continue
		_check_free_var(tag, scope, owner, fn_node)


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
		return
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
