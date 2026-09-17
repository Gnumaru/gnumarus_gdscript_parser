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
		return
	if t == "PARAM":
		var ptag = _leading_tag(d)
		if not ptag.is_empty():
			_error(ERR_DEPRECATED_UNSUPPORTED, "@deprecated on function parameters is not supported yet", int(d.get("line", 0)), int(d.get("column", 0)), owner)
		if _has_any_private_tag(d):
			_error(ERR_PRIVATE_MISPLACED, "@private must precede a member declaration (variable, function, class, enum, constant or signal) inside a class body", int(d.get("line", 0)), int(d.get("column", 0)), owner)
		return
	if t == "LAMBDA" or t == "ACCESSOR":
		if _has_any_deprecated_tag(d):
			_error(ERR_DEPRECATED_MISPLACED, "@deprecated must precede a member declaration (variable, function, class, enum, constant or signal)", int(d.get("line", 0)), int(d.get("column", 0)), owner)
			return
		if _has_any_private_tag(d):
			_error(ERR_PRIVATE_MISPLACED, "@private must precede a member declaration (variable, function, class, enum, constant or signal) inside a class body", int(d.get("line", 0)), int(d.get("column", 0)), owner)
			return
		_scan(d.get("params", []), owner, false)
		_scan(d.get("body", null), owner, false)
		_scan(d.get("detail", null), owner, false)
		return
	if t == "BLOCK":
		_scan_children(d.get("children", []), owner, member_pos)
		return
	if t == "COMMENT" or t == "DOC_COMMENT" or t == "TYPE_INFO" or t == "ANNOTATION_DECL":
		return
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
		if k in ["tokens", "args", "annotations", "leading_comments", "header_comment", "deprecated", "private", "analyzer_errors", "analyzer_warnings"]:
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
				_scan_class_body(child, full)
			elif child is Dictionary and str((child as Dictionary).get("type", "")) in DECL_TYPES:
				_mark_decl(child, full)
				_mark_private(child, full)
				if str((child as Dictionary).get("type", "")) == "FUNC_DECL":
					_scan((child as Dictionary).get("body", null), full)


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
		return
	if t == "COMMENT" or t == "DOC_COMMENT" or t == "TYPE_INFO" or t == "ANNOTATION_DECL" or t == "SYNTAX_ERROR":
		return
	_walk_generic(d, scope, owner)


func _walk_generic(d: Dictionary, scope: Dictionary, owner: String) -> void:
	for k in d.keys():
		if k in ["tokens", "args", "annotations", "leading_comments", "header_comment", "deprecated", "private", "analyzer_errors", "analyzer_warnings", "semantic_errors", "user_types_written"]:
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
		if k in ["tokens", "args", "annotations", "leading_comments", "header_comment", "deprecated", "private"]:
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
