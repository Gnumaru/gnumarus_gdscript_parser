class_name GnumarusGodotProjectAnalyzerSuiteGdscriptAnalyzer
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
##   data-dir JSON files); "void" only works alone. When the function also
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
## Named type templates share user/ with classes (one global type
## namespace) as kind-tagged JSONs: @tuple (fixed-shape arrays),
## @struct (fixed-key dictionaries) and @interface (member blueprints
## between @interface Name and @endinterface, single or multi-line).
## Definitions live top-level only; duplicates and clashes error.
## Tuples/structs verify literals, index/key access and members;
## interfaces define blueprints and @implements checks conformance
## (methods, fields, signals, enums, consts) at the script root or on
## nested classes.
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
##   var sem := GnumarusGodotProjectAnalyzerSuiteGdscriptSemanticParser.new()
##   var ana := GnumarusGodotProjectAnalyzerSuiteGdscriptAnalyzer.new()
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
const ERR_VIRTUAL_VARTYPE := "virtual_vartype"
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
const ERR_ALIAS_MISPLACED := "alias_misplaced"
const ERR_ALIAS_MALFORMED := "alias_malformed"
const ERR_ALIAS_UNKNOWN_TYPE := "alias_unknown_type"
const ERR_ALIAS_CONFLICT := "alias_conflict"
const ERR_ALIAS_MISMATCH := "alias_mismatch"
const ERR_TEMPLATE_MISPLACED := "template_misplaced"
const ERR_TEMPLATE_MALFORMED := "template_malformed"
const ERR_TEMPLATE_UNKNOWN_TYPE := "template_unknown_type"
const ERR_TEMPLATE_CONFLICT := "template_conflict"
const ERR_TEMPLATE_MISMATCH := "template_mismatch"
const ERR_GENERIC_MISPLACED := "generic_misplaced"
const ERR_GENERIC_MALFORMED := "generic_malformed"
const ERR_GENERIC_MISMATCH := "generic_mismatch"
const ERR_STRUCT_MISPLACED := "struct_misplaced"
const ERR_STRUCT_MALFORMED := "struct_malformed"
const ERR_STRUCT_UNKNOWN_TYPE := "struct_unknown_type"
const ERR_STRUCT_CONFLICT := "struct_conflict"
const ERR_STRUCT_MISMATCH := "struct_mismatch"
const ERR_INTERFACE_MISPLACED := "interface_misplaced"
const ERR_INTERFACE_MALFORMED := "interface_malformed"
const ERR_INTERFACE_UNKNOWN_TYPE := "interface_unknown_type"
const ERR_INTERFACE_CONFLICT := "interface_conflict"
const ERR_INTERFACE_MISMATCH := "interface_mismatch"
const ERR_IMPLEMENTS_MISPLACED := "implements_misplaced"
const ERR_IMPLEMENTS_MALFORMED := "implements_malformed"
const ERR_IMPLEMENTS_UNKNOWN_TYPE := "implements_unknown_type"
const ERR_IMPLEMENTS_MISMATCH := "implements_mismatch"
const ERR_MISSING_METHOD := "missing_method"
const ERR_MISSING_MEMBER := "missing_member"
const ERR_NULL_ACCESS := "null_access"
const ERR_MAYBE_NULL := "maybe_null"
const ERR_VAR_NOTNULL := "var_notnull"
const ERR_PARAM_NOTNULL := "param_notnull"
const ERR_RETURN_NOTNULL := "return_notnull"
const ERR_POLICY_MISPLACED := "policy_misplaced"
const ERR_POLICY_MALFORMED := "policy_malformed"
## ProjectSetting holding the default nullability policy ("trust" or
## "distrust"). Read at each analyze() call when neither the analyzer
## `null_policy` property (explicit) nor a file `# @nullable_policy`
## tag decides.
const SETTING_NULL_POLICY := "gnumarus_analyzer/nullable_policy"
## ProjectSetting for untyped strictness (bool, default false).
const SETTING_STRICT_UNTYPED := "gnumarus_analyzer/strict_untyped"

## Signal methods accepted on signal-typed bases (mirrors the semantic
## parser's SIGNAL_METHODS).
const SIGNAL_METHODS := ["connect", "disconnect", "is_connected", "emit", "get_connections"]

## Variant.Type enum value -> narrowed type name ("" = not a real type).
const VARIANT_TYPE_MAP := {
	"TYPE_NIL": "null",
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
const SemParser = preload("GnumarusGodotProjectAnalyzerSuiteGdscriptSemanticParser.gd")
## Preloaded like SemParser so the native database can be ensured
## without relying on the global class cache.
const NativeDumper = preload("GnumarusGodotProjectAnalyzerSuiteGodotTypesInfoDumper.gd")
## Preloaded like SemParser so on-demand dependency analysis can
## parse referenced scripts without relying on global classes.
const SynParser = preload("GnumarusGodotProjectAnalyzerSuiteGdscriptSyntaticParser.gd")

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
var _write_base = NativeDumper.DATA_DIR_NAME
var _written: Array = []
## Type file lookups (builtin/classes/user JSON info or miss marker),
## cached per analyze() call for @return name resolution.
var _type_cache: Dictionary = {}
## @tuple definitions: name -> {"resolved": bool, "raws": [...],
## "spec": {...}}. Pre-scan collects raws (order-free known-checks),
## _resolve_tuples validates into specs before the walk.
var _tuples: Dictionary = {}
## @struct definitions, same two-pass split as tuples.
var _structs: Dictionary = {}
## @interface raw blocks: name -> [{words, line}]. Validated in
## _resolve_interfaces before the walk.
var _interfaces: Dictionary = {}
## @implements raw uses: owner -> [{names, line}]. Checked in
## _check_implements after the walk (tables complete by then).
var _implements: Dictionary = {}
## @template type variables: name -> {"resolved": bool, "raws": [...],
## "spec": {...}}. File-local only: never written to JSON, never read
## from disk. Prescan collects raws, _resolve_templates validates.
var _templates: Dictionary = {}
## @alias definitions: name -> {"resolved": bool, "raws": [...],
## "spec": {...}}. Prescan collects raws, _resolve_aliases validates.
var _aliases: Dictionary = {}
## Raw parameterized extends per class key: {head, inner, line, owner}.
## Collected at scan (order-free), validated post-resolve into
## _extends_args ({key: parent_key, args}).
var _extends_raw: Dictionary = {}
## Validated extends arguments: child key -> {key: parent key, args}.
var _extends_args: Dictionary = {}
## Complex annotation trees awaiting tuple validation: [{tree, mm_kind,
## what, line, col, owner}]. Attach runs before _resolve_tuples, so
## arity/compatibility waits for _check_pending_trees (post-resolve).
var _pending_tree_checks: Array = []
## Alias members awaiting narrowing: [{member, ref, label, line, col,
## owner, pkind}]. Alias definitions resolve after the scan, so
## alias-vs-declared checks wait for _check_pending_alias_narrows.
var _pending_alias_narrows: Array = []
## Alias members awaiting notnull contradiction: [{member, what,
## mkind, raw, line, col, owner, stamp}]. Alias trees resolve after
## the scan; on contradiction the error fires and the premature
## notnull stamp is erased. Evaluated by _check_pending_notnull.
var _pending_notnull_clash: Array = []
## Vartype arguments awaiting bound checks: [{param, arg, head, line,
## col, owner}]. Template bounds resolve after the scan.
var _pending_vartype_bounds: Array = []
## Nullability policy for implicitly-nullable slots (Object-derived,
## explicit Variant): "trust" stays silent like Godot itself, while
## "distrust" warns on unguarded member use. Explicit `notnull` /
## `nullable` slot markers always win over this default; "trust" is
## the default (current behavior). Configuration, so analyze() never
## resets it. Setting it explicitly (even to "trust") marks the
## instance base, which beats the ProjectSetting but still loses to a
## file `# @nullable_policy` tag.
var null_policy := "trust":
	set(v):
		var s := str(v)
		null_policy = s if s == "distrust" else "trust"
		_policy_explicit = true
## True once `null_policy` was assigned (setter only runs on
## assignment, never on the default above).
var _policy_explicit := false
## Instance policy base for this analyze() call: the explicit
## property when set, else the ProjectSetting (or "trust" when the
## setting is missing/invalid). A file tag overrides per file.
var _policy_base := "trust"
## File `# @nullable_policy` tag value ("" when absent): wins over
## the base for the analyzed file only.
var _file_policy := ""


## Effective distrust state for this analyze() call.
func _null_distrust() -> bool:
	if _file_policy == "distrust":
		return true
	if _file_policy == "trust":
		return false
	return _policy_base == "distrust"


## Effective file policy ("trust"/"distrust"): the file tag when
## present, else the base. Stored per user JSON for cross-script
## boundary checks.
func _effective_file_policy() -> String:
	if _file_policy == "distrust" or _file_policy == "trust":
		return _file_policy
	return _policy_base


## ProjectSetting policy, sanitized ("trust" unless exactly
## "distrust"). Static: singletons read fine without an instance.
static func _read_project_policy() -> String:
	var v := str(ProjectSettings.get_setting(SETTING_NULL_POLICY, "trust"))
	return v if v == "distrust" else "trust"


## Strict-untyped mode: under distrust, member use on declared-but-
## untyped slots (plain-`=` locals, untyped params, typeless members)
## warns instead of staying silent. Inert under trust (the master
## switch), off by default. Configuration, so analyze() never resets
## it. Explicit assignment marks the instance base, which beats the
## ProjectSetting but still loses to a file `# @strict_untyped` tag.
var strict_untyped := false:
	set(v):
		strict_untyped = bool(v)
		_strict_explicit = true
## True once `strict_untyped` was assigned.
var _strict_explicit := false
## Instance strict base for this analyze() call: the explicit
## property when set, else the ProjectSetting. A file tag overrides
## per file.
var _strict_base := false
## File `# @strict_untyped` tag state ("on"/"off"/"" when absent):
## wins over the base for the analyzed file only.
var _file_strict := ""


## Effective strict-untyped state: the file tag when present, else
## the base. Only meaningful under distrust (callers check both).
func _effective_strict() -> bool:
	if _file_strict == "on":
		return true
	if _file_strict == "off":
		return false
	return _strict_base


## ProjectSetting strictness, sanitized. Static like the policy.
static func _read_project_strict() -> bool:
	return bool(ProjectSettings.get_setting(SETTING_STRICT_UNTYPED, false))


## Class roster: global script class_name -> res:// source path for
## the whole project. Tells "a script by this name exists" apart from
## "unknown identifier" without analyzing anything: names resolve
## (annotations accept them, chains treat them as opaque scripts)
## while member data stays lazy (on-demand analysis fills it).
## Process-static (shared across instances and sequential analyze()
## calls); content comes from real files on disk, so it is
## deterministic. First hit wins on collisions (sorted paths).
static var _roster_names: Dictionary = {}
## Project root the roster was built for (a different root resets it:
## headless runs can analyze several projects in one process).
static var _roster_root := ""
## mtime of the cfg the roster was built from (-1 none yet, -2
## regex-scan without cfg).
static var _roster_cfg_mtime := -1
## Max nested on-demand dependency analyses (cycle guard is the
## shared _resolve_stack; depth caps pathological cascades).
const MAX_DEP_DEPTH := 4
## Class names currently being on-demand analyzed up-stack (shared
## across the fresh instances of one cascade): re-entry reads as
## missing (partial first pass, converges on re-analysis).
static var _resolve_stack: Array = []
## One regex rescan per analyze() call at most (lookup misses).
var _roster_swept := false
## Class names attempted through on-demand resolution this analyze()
## call (hits and misses, deduped): the cross-file references of the
## analyzed file. Read by the editor to re-analyze dependents when a
## referenced JSON changes. Reset per call, never persisted.
var _last_refs: Array = []


## True when the roster knows a global script class by exact name.
static func _roster_has(tname: String) -> bool:
	return tname != "" and _roster_names.has(tname)


## res:// source path behind a roster class ("" when absent). Pure.
static func _roster_path(tname: String) -> String:
	return str(_roster_names.get(tname, ""))


## Roster class behind a source path ("" when absent): linear scan,
## roster-sized (hundreds), only used by batch tools like warm pass.
## Static: no instance.
static func _roster_class_for_path(source_path: String) -> String:
	for k in _roster_names.keys():
		if str(_roster_names[k]) == source_path:
			return str(k)
	return ""


## Refreshes the roster when the engine cache is new/changed/absent:
## `global_script_class_cache.cfg` (the engine's own truth) when
## present, else a recursive `class_name` line scan (works on
## unparseable files too; skips `.godot/`). Static: no instance.
static func _roster_refresh(root: String) -> void:
	if root == "":
		return
	if _roster_root != root:
		_roster_root = root
		_roster_names = {}
		_roster_cfg_mtime = -1
	var cfg := root + "/.godot/global_script_class_cache.cfg"
	if FileAccess.file_exists(cfg):
		var mt := FileAccess.get_modified_time(cfg)
		if mt == _roster_cfg_mtime and not _roster_names.is_empty():
			return
		var parsed := _roster_parse_cfg(FileAccess.get_file_as_string(cfg))
		if not parsed.is_empty():
			_roster_names = parsed
		_roster_cfg_mtime = mt
		return
	if _roster_cfg_mtime == -2 and not _roster_names.is_empty():
		return
	_roster_names = _roster_scan_files(root)
	_roster_cfg_mtime = -2


## Parses engine cache text into {class_name: res:// path} (.gd only;
## other languages cannot be analyzed). Chunk-split (never DOTALL):
## each `{...}` entry contributes its first class + first path.
static func _roster_parse_cfg(text: String) -> Dictionary:
	var out := {}
	for chunk in text.split("}, {"):
		var cpos := chunk.find("\"class\": &\"")
		if cpos < 0:
			continue
		var cstart := cpos + 11
		var cend := chunk.find("\"", cstart)
		if cend <= cstart:
			continue
		var cname := chunk.substr(cstart, cend - cstart)
		if not _is_type_name(cname):
			continue
		var ppos := chunk.find("\"path\": \"")
		if ppos < 0:
			continue
		var pstart := ppos + 9
		var pend := chunk.find("\"", pstart)
		if pend <= pstart:
			continue
		var ppath := chunk.substr(pstart, pend - pstart)
		if not ppath.ends_with(".gd"):
			continue
		if not out.has(cname):
			out[cname] = ppath
	return out


## Recursive `{class_name: res:// path}` line scan under root
## (skips `.godot/`): first `class_name <Name>` line per file wins;
## collisions keep the sorted-first path. Static: no instance.
static func _roster_scan_files(root: String) -> Dictionary:
	var found: Dictionary = {}
	var dirs: Array = [root]
	while not dirs.is_empty():
		var dir: String = str(dirs.pop_back())
		if dir == "" or not DirAccess.dir_exists_absolute(dir):
			continue
		for sub in DirAccess.get_directories_at(dir):
			if str(sub) != ".godot":
				dirs.append(dir + "/" + str(sub))
		for f in DirAccess.get_files_at(dir):
			if not str(f).ends_with(".gd"):
				continue
			var fpath := dir + "/" + str(f)
			var cname := _roster_file_class(fpath)
			if cname == "":
				continue
			if found.has(cname):
				(found[cname] as Array).append(fpath)
			else:
				found[cname] = [fpath]
	var out := {}
	for cname in found.keys():
		var paths: Array = (found[cname] as Array).duplicate()
		paths.sort()
		var rel := str(paths[0])
		if rel.begins_with(root):
			rel = rel.substr(root.length())
		if not rel.begins_with("res://"):
			rel = "res://" + rel.trim_prefix("/")
		out[cname] = rel
	return out


## class_name behind one file's first `class_name <Name>` line (""
## when absent or invalid). Reads plain text: broken files still
## contribute their name. Static: no instance.
static func _roster_file_class(fpath: String) -> String:
	if not FileAccess.file_exists(fpath):
		return ""
	for line in FileAccess.get_file_as_string(fpath).split("\n"):
		var s := str(line).strip_edges()
		if not s.begins_with("class_name "):
			continue
		var rest := s.substr(11).strip_edges()
		var end := rest.find(" ")
		var tab := rest.find("\t")
		if tab >= 0 and (end < 0 or tab < end):
			end = tab
		var hash := rest.find("#")
		if hash >= 0 and (end < 0 or hash < end):
			end = hash
		var cname := rest if end < 0 else rest.substr(0, end)
		if _is_type_name(cname):
			return cname
		return ""
	return ""


## True for a roster-known script class with no usable info in this
## run (no engine entry, no JSON on disk, no same-file member): the
## name exists, the members are opaque. Compat and name checks stay
## lenient on opaque (unknown hierarchy); never true for builtins,
## value types or dynamic slots.
func _opaque_script(tname: String) -> bool:
	if tname == "" or tname == "Variant" or tname == "dynamic" or tname == "null":
		return false
	if not _roster_has(tname):
		return false
	if not _engine_info(tname).is_empty():
		return false
	if tname == _script_class and tname != "":
		return false
	if not _iface_spec(tname).is_empty():
		return false
	if not _type_info(tname).is_empty():
		return false
	for key in _members.keys():
		var table: Dictionary = _members[key]
		if table.has(tname) and str((table[tname] as Dictionary).get("kind", "")) in ["class", "enum"]:
			return false
	return true


## Script info with on-demand dependency analysis: roster-known
## classes without a data-dir JSON get analyzed right here (fresh
## instance; the dep JSON lands on disk as a side effect), then the
## local miss cache is dropped and the info re-read. Bounded by the
## shared resolve stack (cycles read as missing — partial first
## pass, converges on re-analysis) and MAX_DEP_DEPTH. Configuration
## (explicit policy/strict) carries over; file tags apply inside the
## sub-analysis naturally. Returns {} when nothing resolves.
func _ensure_script_info(tname: String) -> Dictionary:
	if tname == "" or tname == "_" or tname == "null" or tname == "self" or tname == "super":
		return {}
	if tname == _script_class and tname != "":
		return {}
	if not _last_refs.has(tname):
		_last_refs.append(tname)
	var info := _type_info(tname)
	if not info.is_empty():
		return info
	if not _roster_has(tname):
		return {}
	if tname in _resolve_stack:
		return {}
	if _resolve_stack.size() >= MAX_DEP_DEPTH:
		return {}
	var path := _roster_path(tname)
	if path == "" or not FileAccess.file_exists(path):
		if not _roster_swept and _project_root != "":
			_roster_swept = true
			var swept := _roster_scan_files(_project_root)
			for k in swept.keys():
				if not _roster_names.has(k):
					_roster_names[k] = swept[k]
			return _ensure_script_info(tname)
		return {}
	_resolve_stack.append(tname)
	var sub := GnumarusGodotProjectAnalyzerSuiteGdscriptAnalyzer.new()
	if _policy_explicit:
		sub.null_policy = null_policy
	if _strict_explicit:
		sub.strict_untyped = strict_untyped
	sub.analyze(SynParser.new().parse_text(FileAccess.get_file_as_string(path)), path)
	_resolve_stack.pop_back()
	_type_cache.erase(tname)
	return _type_info(tname)


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
	_structs = {}
	_interfaces = {}
	_implements = {}
	_aliases = {}
	_templates = {}
	_extends_raw = {}
	_extends_args = {}
	_pending_tree_checks = []
	_pending_alias_narrows = []
	_pending_notnull_clash = []
	_pending_vartype_bounds = []
	_file_policy = ""
	_file_strict = ""
	_roster_swept = false
	_last_refs = []
	if _policy_explicit:
		_policy_base = null_policy
	else:
		_policy_base = _read_project_policy()
	if _strict_explicit:
		_strict_base = strict_untyped
	else:
		_strict_base = _read_project_strict()
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
		_project_root = SemParser.fallback_root(anchor + "/GnumarusGodotProjectAnalyzerSuiteGodotTypesInfoDumper.gd")
	_script_resource_path = SemParser.resource_path_for(script_path, _project_root)
	_write_base = _compute_write_base(_project_root)
	_roster_refresh(_project_root)
	if not _ensure_native_types():
		ast["analyzer_errors"] = _errors
		ast["analyzer_warnings"] = _warnings
		ast["analyzer_written"] = _written
		return {"ast": ast, "errors": _errors, "warnings": _warnings}
	_scan_header(ast)
	_scan_policy_misplaced(ast.get("children", []))
	_prescan_tuples(ast)
	_prescan_structs(ast)
	_prescan_interfaces(ast)
	_prescan_aliases(ast)
	_prescan_templates(ast)
	_scan_children(ast.get("children", []), "")
	_resolve_tuples()
	_resolve_structs()
	_resolve_interfaces()
	_resolve_aliases()
	_resolve_templates()
	_check_pending_extends()
	_check_pending_vartype_bounds()
	_check_pending_trees()
	_check_pending_alias_narrows()
	_check_pending_notnull()
	var scope = _new_scope(null)
	_walk_members(ast.get("children", []), scope, "")
	_flow_members(ast.get("children", []), _new_scope(null), "")
	_check_implements()
	_sort_issues(_errors)
	_sort_issues(_warnings)
	ast["analyzer_errors"] = _errors
	ast["analyzer_warnings"] = _warnings
	_update_user_files(ast)
	ast["analyzer_written"] = _written
	return {"ast": ast, "errors": _errors, "warnings": _warnings}


## Sorts issue entries in place by (line, column), then kind and
## message for determinism. Pipeline passes append in phase order,
## which is not file order — consumers (editor navigation first of
## all) need position order, so analyze() guarantees it.
static func _sort_issues(items: Array) -> void:
	items.sort_custom(func(a: Variant, b: Variant) -> bool: return _issue_less(a, b))


## Strict ordering for issue entries (non-dicts sort last).
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
	var ak := str(ad.get("kind", ""))
	var bk := str(bd.get("kind", ""))
	if ak != bk:
		return ak < bk
	return str(ad.get("message", "")) < str(bd.get("message", ""))


## Ensures the native type database (data-dir builtin, classes,
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
	if FileAccess.file_exists(self_dir + "/GnumarusGodotProjectAnalyzerSuiteGodotTypesInfoDumper.gd"):
		return self_dir
	if self_path.begins_with("res://") and FileAccess.file_exists("res://GnumarusGodotProjectAnalyzerSuiteGodotTypesInfoDumper.gd"):
		return "res://"
	return self_dir


func _compute_write_base(root: String) -> String:
	if root != "":
		var r = root
		if r.ends_with("/") and r.length() > 1:
			r = r.substr(0, r.length() - 1)
		return r + "/" + NativeDumper.DATA_DIR_NAME
	return NativeDumper.DATA_DIR_NAME


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
		# NOTE: @tuple/@struct/@interface/@alias/@template definitions
		# may live in the header (first in file); prescans collect them
		# like any other top-level comment.
		if not _find_generic(str((header as Dictionary).get("value", ""))).is_empty():
			_error(ERR_GENERIC_MISPLACED, "@generic belongs immediately before a class declaration", int((header as Dictionary).get("line", 0)), int((header as Dictionary).get("column", 0)), "")
		var htag := _find_implements(str((header as Dictionary).get("value", "")))
		if not htag.is_empty():
			_record_implements_words("", _split_words(str(htag.get("message", ""))), int((header as Dictionary).get("line", 0)))
		var ptag := _find_policy(str((header as Dictionary).get("value", "")))
		if not ptag.is_empty():
			var pval := str(ptag.get("message", "")).strip_edges()
			if pval == "trust" or pval == "distrust":
				_file_policy = pval
			else:
				_error(ERR_POLICY_MALFORMED, "@nullable_policy needs 'trust' or 'distrust', got '" + pval + "'", int((header as Dictionary).get("line", 0)), int((header as Dictionary).get("column", 0)), "")
		var stag := _find_strict(str((header as Dictionary).get("value", "")))
		if not stag.is_empty():
			var sval := str(stag.get("message", "")).strip_edges().to_lower()
			if sval == "" or sval == "on":
				_file_strict = "on"
			elif sval == "off":
				_file_strict = "off"
			else:
				_error(ERR_POLICY_MALFORMED, "@strict_untyped needs 'on' or 'off', got '" + str(stag.get("message", "")).strip_edges() + "'", int((header as Dictionary).get("line", 0)), int((header as Dictionary).get("column", 0)), "")


## Errors `@nullable_policy` / `@strict_untyped` tags anywhere but
## the file header: leading comments of any other node (at any depth)
## and nested header blocks (inner classes) are not the file root.
## Call on the root children: the root header itself is exempt
## (parsed above).
func _scan_policy_misplaced(node: Variant) -> void:
	if node is Array:
		for e in node:
			_scan_policy_misplaced(e)
		return
	if not (node is Dictionary):
		return
	var d: Dictionary = node
	for c in (d as Dictionary).get("leading_comments", []):
		if c is Dictionary and not _find_policy(str((c as Dictionary).get("value", ""))).is_empty():
			_error(ERR_POLICY_MISPLACED, "@nullable_policy must be the file's first comment block, before any declaration", int((c as Dictionary).get("line", 0)), int((c as Dictionary).get("column", 0)), "")
		if c is Dictionary and not _find_strict(str((c as Dictionary).get("value", ""))).is_empty():
			_error(ERR_POLICY_MISPLACED, "@strict_untyped must be the file's first comment block, before any declaration", int((c as Dictionary).get("line", 0)), int((c as Dictionary).get("column", 0)), "")
	var hc: Variant = (d as Dictionary).get("header_comment", null)
	if hc is Dictionary and not _find_policy(str((hc as Dictionary).get("value", ""))).is_empty():
		_error(ERR_POLICY_MISPLACED, "@nullable_policy must be the file's first comment block, before any declaration", int((hc as Dictionary).get("line", 0)), int((hc as Dictionary).get("column", 0)), "")
	if hc is Dictionary and not _find_strict(str((hc as Dictionary).get("value", ""))).is_empty():
		_error(ERR_POLICY_MISPLACED, "@strict_untyped must be the file's first comment block, before any declaration", int((hc as Dictionary).get("line", 0)), int((hc as Dictionary).get("column", 0)), "")
	for k in (d as Dictionary).keys():
		if str(k) == "leading_comments" or str(k) == "header_comment":
			continue
		_scan_policy_misplaced((d as Dictionary)[k])


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


## Extracts a "@nullable_policy" file-root tag from a comment value.
## Returns {} when absent, else {"message": rest-of-line}.
func _find_policy(value: String) -> Dictionary:
	return _find_tag(value, "nullable_policy")


## Extracts a "@strict_untyped" file-root tag from a comment value.
func _find_strict(value: String) -> Dictionary:
	return _find_tag(value, "strict_untyped")


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


func _find_struct(value: String) -> Dictionary:
	return _find_tag(value, "struct")


func _has_struct_tag(tok: Dictionary) -> Dictionary:
	if str(tok.get("type", "")) != "TYPE_INFO":
		return {}
	return _find_struct(str(tok.get("value", "")))


func _has_any_struct_tag(node: Dictionary) -> bool:
	for c in node.get("leading_comments", []):
		if c is Dictionary and not _has_struct_tag(c).is_empty():
			return true
	return false


func _has_any_tuple_tag(node: Dictionary) -> bool:
	for c in node.get("leading_comments", []):
		if c is Dictionary and not _has_tuple_tag(c).is_empty():
			return true
	return false


## Parses an @tuple message ("Name COUNT item...") into {"ok","name",
## "size","items","raw"} or {"ok": false, "error"}. COUNT is mandatory
## and must equal the item count (checked by the caller against the
## parsed words). Items stay raw here (unions, `*`, `variant`, nested
## generics). Words split on whitespace first, then bracketed spans
## rejoin so "Dictionary[ String , int ]" stays one item.
static func _parse_tuple_spec(raw_msg: String) -> Dictionary:
	var words := _rejoin_bracket_words(_split_words(raw_msg.strip_edges()))
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


## Rejoins whitespace-split words while brackets stay open, so spaced
## generics survive word-based definition syntax. Joins with "" (spaces
## inside brackets are insignificant to _parse_type_expr).
static func _rejoin_bracket_words(words: Array) -> Array:
	var out: Array = []
	var cur := ""
	var depth := 0
	for w in words:
		var ws := str(w)
		if depth > 0:
			cur += ws
		else:
			cur = ws
		for i in range(ws.length()):
			var c := ws.unicode_at(i)
			if c == 91:
				depth += 1
			elif c == 93 and depth > 0:
				depth -= 1
		if depth <= 0:
			out.append(cur)
			cur = ""
	if cur != "":
		out.append(cur)
	return out


## Pre-scan (before _scan): collects @tuple raw definitions from
## top-level standalone comments and top-level leadings so name
## lookups stay order-free. Full validation happens in _resolve_tuples.
## The file header comment as a collectable token ({} when absent;
## collectors ignore non-TYPE_INFO tokens, so this is always safe).
static func _header_tok(ast: Dictionary) -> Dictionary:
	var header: Variant = ast.get("header_comment", null)
	if header is Dictionary:
		return header
	return {}


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
	_collect_tuple_node(_header_tok(ast))


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
	for tname in _tuples.keys():
		var done: Dictionary = _tuples[tname]
		if not bool(done.get("resolved", false)):
			continue
		var dspec: Dictionary = done.get("spec", {})
		for item in (dspec.get("items", []) as Array):
			if item is Dictionary and (item as Dictionary).has("tree"):
				var itree: Dictionary = (item as Dictionary).get("tree", {})
				var iexp := _expand_tree_aliases(itree)
				if bool(iexp.get("ok", false)):
					itree = iexp.get("node", {})
				var tv := _check_tree_tuples(itree)
				if not bool(tv.get("ok", false)):
					_error(ERR_TUPLE_MISMATCH, "@tuple " + str(tv.get("mismatch", "")), int(dspec.get("line", 0)), 0, "")


## Canonical type name: exact match first (user definitions win),
## then first-letter-uppercased fallback (`string` -> `String`).
## Typo-correction is silent by design: in type position a lowercase
## name can only mean the type. "" when unresolvable.
func _canon_type(tname: String) -> String:
	if _type_known(tname):
		return tname
	if tname != "":
		var first := tname.unicode_at(0)
		if first >= 97 and first <= 122:
			var up := tname.substr(0, 1).to_upper() + tname.substr(1)
			if _type_known(up):
				return up
	return ""


## Splits a struct field word on the first colon: {"name", "spec"}
## (spec "" when bare). Name validity is checked by callers.
static func _split_struct_field(word: String) -> Dictionary:
	var ci := word.find(":")
	if ci < 0:
		return {"name": word, "spec": ""}
	return {"name": word.substr(0, ci), "spec": word.substr(ci + 1)}


## Parses one tuple item word: `*` (any), `variant` (unknown marker,
## normalized to Variant), a |-union of known names (tuple refs
## allowed: all names were pre-scanned), or a nested type expression
## with brackets ("Dictionary[String,int]", "P[int]"). {} + error on
## failure. Generic arms keep their head (anonymous `tuple[...]` reads
## as `Array`); the parsed tree rides along for future structural work.
func _parse_tuple_item(word: String, line: int) -> Dictionary:
	if word == "*":
		return {"types": [], "any": true}
	if "[" in word or "]" in word or "," in word:
		return _parse_tuple_item_complex(word, line)
	var raw := word
	if word == "variant":
		raw = "Variant"
	var types: Array = []
	for arm in raw.split("|"):
		var aname := str(arm).strip_edges()
		if aname == "" or aname == "void" or not _is_type_name(aname):
			_error(ERR_TUPLE_MALFORMED, "@tuple has an invalid type '" + str(arm) + "'", line, 0, "")
			return {}
		var cm := _canon_type(aname)
		if cm == "":
			_error(ERR_TUPLE_UNKNOWN_TYPE, "@tuple has unknown type '" + aname + "'", line, 0, "")
			return {}
		types.append(cm)
	if types.is_empty():
		_error(ERR_TUPLE_MALFORMED, "@tuple has an empty type", line, 0, "")
		return {}
	return {"types": types, "any": false}


## Bracketed tuple-item route: mini-parses the whole word, resolves
## every name, validates tuple applications, and flattens arms to
## head names (legacy flat shape, so literal checks keep working).
func _parse_tuple_item_complex(word: String, line: int) -> Dictionary:
	var parsed := _parse_type_expr(word, "@tuple")
	if not bool(parsed.get("ok", false)):
		_error(ERR_TUPLE_MALFORMED, str(parsed.get("error", "")), line, 0, "")
		return {}
	var tree: Dictionary = parsed.get("node", {})
	if _count_void_names(tree) > 0:
		_error(ERR_TUPLE_MALFORMED, "@tuple 'void' is not a valid item type", line, 0, "")
		return {}
	var arms: Array = []
	if str(tree.get("kind", "")) == "union":
		arms = (tree.get("arms", []) as Array).duplicate()
	else:
		arms = [tree]
	var types: Array = []
	for arm in arms:
		if not (arm is Dictionary):
			_error(ERR_TUPLE_MALFORMED, "@tuple has an invalid type '" + word + "'", line, 0, "")
			return {}
		var kind := str((arm as Dictionary).get("kind", ""))
		if kind == "any":
			_error(ERR_TUPLE_MALFORMED, "@tuple has an invalid type '*'", line, 0, "")
			return {}
		if kind == "name":
			types.append(str((arm as Dictionary).get("name", "")))
		elif kind == "generic":
			var hname := str((arm as Dictionary).get("name", ""))
			if hname == "tuple" and _tuple_def("tuple").is_empty():
				types.append("Array")
			else:
				types.append(hname)
		else:
			_error(ERR_TUPLE_MALFORMED, "@tuple has an invalid type '" + word + "'", line, 0, "")
			return {}
	var tv := _resolve_tree_names(tree)
	if not bool(tv.get("ok", false)):
		_error(ERR_TUPLE_UNKNOWN_TYPE, "@tuple has unknown type '" + str((tv as Dictionary).get("bad", "")) + "'", line, 0, "")
		return {}
	var out: Array = []
	for t in types:
		var cm := _canon_type(str(t))
		if cm == "":
			_error(ERR_TUPLE_UNKNOWN_TYPE, "@tuple has unknown type '" + str(t) + "'", line, 0, "")
			return {}
		out.append(cm)
	return {"types": out, "any": false, "tree": tree}


## Why a tuple name cannot be defined ("" when free). Existing tuple
## JSONs (same kind) are fine: idempotent rewrites. NOTE: not via
## _type_known (the name itself is already registered there).
func _tuple_conflict(tname: String) -> String:
	if tname == "null":
		return "reserved name 'null'"
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
	var toks := _trim_trivia(_as_tokens(value))
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


## Splits a dictionary literal value into [{key, value}] pairs (key
## "" when not a single STRING/IDENT literal). Returns {"literal",
## "pairs"} (non-literals report literal=false).
func _struct_lit_split(value: Variant) -> Dictionary:
	var toks := _trim_trivia(_as_tokens(value))
	if toks.is_empty():
		return {"literal": false, "pairs": []}
	if not (toks[0] is Dictionary) or str((toks[0] as Dictionary).get("type", "")) != "LBRACE":
		return {"literal": false, "pairs": []}
	if toks.size() == 2:
		if (toks[1] is Dictionary) and str((toks[1] as Dictionary).get("type", "")) == "RBRACE":
			return {"literal": true, "pairs": []}
		return {"literal": false, "pairs": []}
	if _match_close(toks, 0) != toks.size() - 1:
		return {"literal": false, "pairs": []}
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
	var pairs: Array = []
	for p in out:
		var pa: Array = p
		var ki := -1
		var kd := 0
		var k := 0
		while k < pa.size():
			var pt: Variant = pa[k]
			var pty := ""
			if pt is Dictionary:
				pty = str((pt as Dictionary).get("type", ""))
			if pty == "LPAREN" or pty == "LBRACKET" or pty == "LBRACE":
				kd += 1
			elif pty == "RPAREN" or pty == "RBRACKET" or pty == "RBRACE":
				kd -= 1
			elif kd == 0 and ((pty == "COLON") or (pty == "OPERATOR" and str((pt as Dictionary).get("value", "")) == "=")):
				ki = k
				break
			k += 1
		if ki <= 0:
			return {"literal": false, "pairs": []}
		var key := ""
		if pa.size() > 0 and ki == 1 and (pa[0] is Dictionary):
			var kt := str((pa[0] as Dictionary).get("type", ""))
			var kv := str((pa[0] as Dictionary).get("value", ""))
			if kt == "STRING":
				key = kv.substr(1, kv.length() - 2) if kv.length() >= 2 else ""
			elif kt == "IDENTIFIER":
				key = kv
		if key == "":
			return {"literal": false, "pairs": []}
		pairs.append({"key": key, "value": pa.slice(ki + 1)})
	return {"literal": true, "pairs": pairs}


## Checks an initializer value against a struct vartype (exact keys +
## per-key literal values). Non-literals skip (unprovable).
func _check_struct_value(tname: String, value: Variant, line: int, owner: String) -> void:
	var def := _struct_def(tname)
	if def.is_empty():
		return
	var lit := _struct_lit_split(value)
	if not bool(lit.get("literal", false)):
		return
	_check_struct_elements(tname, def, lit.get("pairs", []), line, owner)


## Key-set and value check of a literal pair list against a definition.
func _check_struct_elements(tname: String, def: Dictionary, pairs: Array, line: int, owner: String) -> void:
	var fields: Array = def.get("fields", [])
	if pairs.size() != int(def.get("size", -1)):
		_error(ERR_STRUCT_MISMATCH, "struct '" + tname + "' expects " + str(def.get("size", 0)) + " fields, got " + str(pairs.size()), line, 0, owner)
		return
	var by_name := {}
	for f in fields:
		by_name[str((f as Dictionary).get("name", ""))] = f
	for p in pairs:
		var pd: Dictionary = p
		var key := str(pd.get("key", ""))
		if not by_name.has(key):
			_error(ERR_STRUCT_MISMATCH, "struct '" + tname + "' has no field '" + key + "'", line, 0, owner)
			continue
		var field: Dictionary = by_name[key]
		if bool(field.get("any", false)):
			continue
		var et := _infer_lit_elem(pd.get("value", []))
		if et == "":
			continue
		var ok := false
		for m in field.get("types", []):
			if _lit_compatible(et, str(m)):
				ok = true
				break
		if not ok:
			_error(ERR_STRUCT_MISMATCH, "struct '" + tname + "' field '" + key + "' expects '" + _show_types(field.get("types", [])) + "', got '" + et + "'", line, 0, owner)
	for f in fields:
		var fname := str((f as Dictionary).get("name", ""))
		var present := false
		for p in pairs:
			if str((p as Dictionary).get("key", "")) == fname:
				present = true
				break
		if not present:
			_error(ERR_STRUCT_MISMATCH, "struct '" + tname + "' is missing field '" + fname + "'", line, 0, owner)
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


## Literal-ish compatibility for tuple/struct elements (mirrors the
## semantic string family; NULL and complex elements skip). Numerics
## are DIRECTIONAL, not one family: an `int` literal widens into a
## `float` slot (Godot itself accepts `var f: float = 1`), but a
## `float` literal never fits an `int` slot (Godot silently truncates
## `var i: int = 3.14` to 3 — exactly the data loss this checker
## exists to catch).
func _lit_compatible(et: String, mname: String) -> bool:
	if et == mname:
		return true
	if et == "int" and mname == "float":
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


## Literal value checks against every nominal tuple/struct type in
## play: the declared vartype plus @var members naming tuples or
## structs (deduped). Keeps literal validation working under the
## @var + Array/Dictionary pattern; each checker no-ops on misses.
func _check_nominal_values(d: Dictionary, value: Variant, line: int, owner: String) -> void:
	var seen := {}
	var vt := _vartype_name(d)
	if vt != "":
		seen[vt] = true
		_check_tuple_value(vt, value, line, owner)
		_check_struct_value(vt, value, line, owner)
	var ann: Dictionary = d.get("var_ann", {})
	for m in (ann.get("types", []) as Array):
		var ms := str(m)
		if ms == "" or seen.has(ms):
			continue
		seen[ms] = true
		_check_tuple_value(ms, value, line, owner)
		_check_struct_value(ms, value, line, owner)


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


# ------------------------------------------------------- @alias helpers

func _find_alias(value: String) -> Dictionary:
	return _find_tag(value, "alias")


func _has_alias_tag(tok: Dictionary) -> Dictionary:
	if str(tok.get("type", "")) != "TYPE_INFO":
		return {}
	return _find_alias(str(tok.get("value", "")))


func _has_any_alias_tag(node: Dictionary) -> bool:
	for c in node.get("leading_comments", []):
		if c is Dictionary and not _has_alias_tag(c).is_empty():
			return true
	return false


## Left-boundary rule for @alias/@endalias scanning: start of value,
## or #/space/tab/newline before the @ (multi-line tokens included).
func _at_alias_left(value: String, i: int) -> bool:
	if i <= 0:
		return true
	var left := value.unicode_at(i - 1)
	return left == 35 or left == 32 or left == 9 or left == 10 or left == 13


func _is_alias_ws(c: int) -> bool:
	return c == 32 or c == 9 or c == 10 or c == 13


## 0-based line offset of pos inside value.
func _alias_line_of(value: String, pos: int) -> int:
	var line := 0
	var p := 0
	while p < pos and p < value.length():
		if value.unicode_at(p) == 10:
			line += 1
		p += 1
	return line


## Finds "@endalias" at a tag boundary from pos: returns the @ position
## or -1. Stray text (including nested @alias words) is skipped.
func _find_endalias(value: String, from: int) -> int:
	var n := value.length()
	var i := from
	while i < n:
		if value.unicode_at(i) == 64 and _at_alias_left(value, i):
			var j := i + 1
			var word := ""
			while j < n and _is_tag_char(value.unicode_at(j)):
				word += value.substr(j, 1)
				j += 1
			if word == "endalias":
				return i
		i += 1
	return -1


## Strips GDScript comment markers from a raw alias expression span:
## per line, one leading `#` goes (continuation lines) and anything
## from a later `#` is a trailing comment. Lines rejoin with spaces
## (insignificant to _parse_type_expr).
static func _clean_alias_expr(raw: String) -> String:
	var parts: Array = []
	for line in raw.split("\n"):
		var t := str(line).strip_edges()
		if t.begins_with("#"):
			t = t.substr(1).strip_edges()
		var ci := t.find("#")
		if ci >= 0:
			t = t.substr(0, ci).strip_edges()
		if t != "":
			parts.append(t)
	return " ".join(parts)


## Scans a whole comment value for "@alias NAME expr @endalias"
## blocks. The expression runs to @endalias, so it may span lines and
## hold whitespace. Returns [{name, expr, line}] plus
## [{error, line}] for unterminated blocks. Stray @endalias words and
## text between blocks are ignored.
func _extract_alias_blocks(value: String) -> Array:
	var out: Array = []
	var n := value.length()
	var i := 0
	while i < n:
		if value.unicode_at(i) != 64 or not _at_alias_left(value, i):
			i += 1
			continue
		var j := i + 1
		var word := ""
		while j < n and _is_tag_char(value.unicode_at(j)):
			word += value.substr(j, 1)
			j += 1
		if word == "endalias":
			i = j
			continue
		if word != "alias":
			i += 1
			continue
		var tline := _alias_line_of(value, i)
		var k := j
		while k < n and _is_alias_ws(value.unicode_at(k)):
			k += 1
		if k <= j or k >= n:
			out.append({"error": "@alias needs a name and a type expression: '# @alias Name int|float @endalias'", "line": tline})
			i = j
			continue
		var nword := ""
		while k < n and _is_tag_char(value.unicode_at(k)):
			nword += value.substr(k, 1)
			k += 1
		if nword == "":
			out.append({"error": "@alias has an invalid name ''", "line": tline})
			i = k
			continue
		var k2 := k
		while k2 < n and _is_alias_ws(value.unicode_at(k2)):
			k2 += 1
		if k2 <= k or k2 >= n:
			out.append({"error": "@alias '" + nword + "' needs a type expression before @endalias", "line": tline})
			i = k
			continue
		var epos := _find_endalias(value, k2)
		if epos < 0:
			out.append({"error": "@alias '" + nword + "' is missing @endalias", "line": tline})
			i = n
			continue
		var expr := _clean_alias_expr(value.substr(k2, epos - k2))
		if expr == "":
			out.append({"error": "@alias '" + nword + "' needs a type expression before @endalias", "line": tline})
			i = epos + 9
			continue
		out.append({"name": nword, "expr": expr, "line": tline})
		i = epos + 9
	return out


## Pre-scan (before _scan): collects @alias raw definitions from
## top-level standalone comments and top-level leadings so name
## lookups stay order-free. Full validation happens in _resolve_aliases.
func _prescan_aliases(ast: Dictionary) -> void:
	for child in ast.get("children", []):
		if not (child is Dictionary):
			continue
		if str((child as Dictionary).get("type", "")) == "TYPE_INFO":
			_collect_alias_node(child as Dictionary)
			continue
		for c in (child as Dictionary).get("leading_comments", []):
			if c is Dictionary:
				_collect_alias_node(c)
	_collect_alias_node(_header_tok(ast))


## Records every @alias block in one comment value as raw material.
## Malformed blocks error immediately and are dropped; valid ones queue
## under their name (duplicates resolved in _resolve_aliases).
func _collect_alias_node(tok: Dictionary) -> void:
	if str(tok.get("type", "")) != "TYPE_INFO":
		return
	var tok_line := int(tok.get("line", 0))
	for b in _extract_alias_blocks(str(tok.get("value", ""))):
		if not (b is Dictionary):
			continue
		var bd: Dictionary = b
		if bd.has("error"):
			_error(ERR_ALIAS_MALFORMED, str(bd.get("error", "")), tok_line + int(bd.get("line", 0)), 0, "")
			continue
		var aname := str(bd.get("name", ""))
		if not _is_type_name(aname):
			_error(ERR_ALIAS_MALFORMED, "@alias has an invalid name '" + aname + "'", tok_line + int(bd.get("line", 0)), 0, "")
			continue
		var raw := {"name": aname, "expr": str(bd.get("expr", "")), "line": tok_line + int(bd.get("line", 0))}
		if not _aliases.has(aname):
			_aliases[aname] = {"resolved": false, "raws": [raw]}
		else:
			((_aliases[aname] as Dictionary).get("raws", []) as Array).append(raw)


## Why an alias name cannot be defined ("" when free). Existing alias
## JSONs (same kind) are fine: idempotent rewrites. NOTE: not via
## _type_known (the name itself is already registered there).
func _alias_conflict(aname: String) -> String:
	if aname == "null":
		return "reserved name 'null'"
	for key in _members.keys():
		var table: Dictionary = _members[key]
		if table.has(aname):
			return "script member '" + aname + "' (" + str((table[aname] as Dictionary).get("kind", "")) + ")"
	if _members.has(aname):
		return "script class '" + aname + "'"
	if aname == _script_class and aname != "":
		return "the script class name"
	if _type_file_exists(aname):
		var info := _read_json(_write_base + "/user/" + aname + ".json")
		if not info.is_empty() and str(info.get("kind", "")) == "alias":
			return ""
		return "an existing type '" + aname + "'"
	return ""


## Alias names referenced by a tree (name-kind leaves registered as
## in-memory aliases), deduplicated. Disk-only aliases cannot cycle
## back into a validating set, so they are skipped here.
func _alias_tree_refs(tree: Dictionary) -> Array:
	var out: Array = []
	_collect_alias_refs(tree, out, {})
	return out


func _collect_alias_refs(node: Dictionary, out: Array, seen: Dictionary) -> void:
	var kind := str(node.get("kind", ""))
	if kind == "name":
		var nm := str(node.get("name", ""))
		if _aliases.has(nm) and not seen.has(nm):
			seen[nm] = true
			out.append(nm)
	elif kind == "union":
		for arm in (node.get("arms", []) as Array):
			if arm is Dictionary:
				_collect_alias_refs(arm, out, seen)
	elif kind == "generic":
		for arg in (node.get("args", []) as Array):
			if arg is Dictionary:
				_collect_alias_refs(arg, out, seen)


## True when aname reaches itself through in-memory alias references
## (parsed on demand: definitions validate in one loop, so later
## definitions are still raw here).
func _alias_circular(aname: String) -> bool:
	return _alias_reaches(aname, aname, {aname: true})


func _alias_reaches(target: String, cur: String, path: Dictionary) -> bool:
	var raw := _alias_first_expr(cur)
	if raw == "":
		return false
	var parsed := _parse_type_expr(raw, "@alias")
	if not bool(parsed.get("ok", false)):
		return false
	for ref in _alias_tree_refs(parsed.get("node", {})):
		var r := str(ref)
		if r == target:
			return true
		if not path.has(r):
			path[r] = true
			if _alias_reaches(target, r, path):
				return true
			path.erase(r)
	return false


## Raw expression of the first queued block for an alias, "" when none.
func _alias_first_expr(aname: String) -> String:
	if not _aliases.has(aname):
		return ""
	var raws: Array = (_aliases[aname] as Dictionary).get("raws", [])
	if raws.is_empty() or not (raws[0] is Dictionary):
		return ""
	return str((raws[0] as Dictionary).get("expr", ""))


## Second pass (after _scan, before _walk): validates definitions
## (duplicates, conflicts, syntax, names, cycles) and writes their
## JSON files. Tuple applications inside alias trees wait for the
## _resolve_tuples item loop (all definitions exist by then).
func _resolve_aliases() -> void:
	_ensure_user_dir()
	for aname in _aliases.keys():
		var entry: Dictionary = _aliases[aname]
		if bool(entry.get("resolved", false)):
			continue
		var raws: Array = entry.get("raws", [])
		if raws.is_empty():
			continue
		var first: Dictionary = raws[0]
		if raws.size() > 1:
			_error(ERR_ALIAS_CONFLICT, "@alias '" + aname + "' is defined more than once", int(first.get("line", 0)), 0, "")
			continue
		var clash := _alias_conflict(aname)
		if clash != "":
			_error(ERR_ALIAS_CONFLICT, "@alias '" + aname + "' conflicts with " + clash, int(first.get("line", 0)), 0, "")
			continue
		var parsed := _parse_type_expr(str(first.get("expr", "")), "@alias")
		if not bool(parsed.get("ok", false)):
			_error(ERR_ALIAS_MALFORMED, str(parsed.get("error", "")), int(first.get("line", 0)), 0, "")
			continue
		var tree: Dictionary = parsed.get("node", {})
		if _count_void_names(tree) > 0:
			_error(ERR_ALIAS_MALFORMED, "@alias 'void' is not a valid type", int(first.get("line", 0)), 0, "")
			continue
		var rn := _resolve_tree_names(tree)
		if not bool(rn.get("ok", false)):
			_error(ERR_ALIAS_UNKNOWN_TYPE, "@alias has unknown type '" + str(rn.get("bad", "")) + "'", int(first.get("line", 0)), 0, "")
			continue
		if _alias_circular(aname):
			_error(ERR_ALIAS_CONFLICT, "@alias '" + aname + "' is circular", int(first.get("line", 0)), 0, "")
			continue
		entry["resolved"] = true
		entry["spec"] = {"ok": true, "name": aname, "tree": tree, "raw": str(first.get("expr", "")), "line": int(first.get("line", 0))}
		_write_alias_file(aname)
	for aname in _aliases.keys():
		var done: Dictionary = _aliases[aname]
		if not bool(done.get("resolved", false)):
			continue
		var dspec: Dictionary = done.get("spec", {})
		var dtree: Dictionary = dspec.get("tree", {})
		var dexp := _expand_tree_aliases(dtree)
		if bool(dexp.get("ok", false)):
			dtree = dexp.get("node", {})
		var tv := _check_tree_tuples(dtree)
		if not bool(tv.get("ok", false)):
			_error(ERR_ALIAS_MISMATCH, "@alias " + str(tv.get("mismatch", "")), int(dspec.get("line", 0)), 0, "")


## Writes one user/<Name>.json per resolved alias (class-compatible
## keys plus the alias tree, so every JSON reader keeps working).
func _write_alias_file(aname: String) -> void:
	var entry: Dictionary = _aliases[aname]
	var spec: Dictionary = entry.get("spec", {})
	var info := {
		"name": aname,
		"kind": "alias",
		"class_name": "",
		"resource_path": _script_resource_path,
		"parent": "",
		"inheritance_chain": [aname],
		"alias_tree": spec.get("tree", {}),
		"alias_raw": str(spec.get("raw", "")),
		"enums": [],
		"constants": [],
		"signals": [],
		"fields": [],
		"static_methods": [],
		"instance_methods": [],
		"inner_classes": [],
	}
	_write_json(_write_base + "/user/" + aname + ".json", info)
	_written.append(_write_base + "/user/" + aname + ".json")


## Resolved alias definition {tree, raw} or {} (in-memory first,
## then same-kind JSON files, both cached).
func _alias_def(aname: String) -> Dictionary:
	if _aliases.has(aname):
		var entry: Dictionary = _aliases[aname]
		if bool(entry.get("resolved", false)):
			var spec: Dictionary = entry.get("spec", {})
			if bool(spec.get("ok", false)) and spec.has("tree"):
				return {"tree": spec.get("tree", {}), "raw": str(spec.get("raw", ""))}
	var info := _type_info(aname)
	if not info.is_empty() and str(info.get("kind", "")) == "alias":
		var dtree: Dictionary = info.get("alias_tree", {})
		if not dtree.is_empty():
			return {"tree": dtree, "raw": str(info.get("alias_raw", ""))}
	return {}


## Expands alias name-leaves in a tree (post-resolve). Heads are never
## aliases: applying arguments to an alias fails closed. Cycles fail
## closed too (resolve rejects them; disk edits stay defensive).
## Returns {"ok", "node"} or {"ok": false, "error"}.
func _expand_tree_aliases(tree: Dictionary) -> Dictionary:
	return _expand_tree_node(tree, [])


func _expand_tree_node(node: Dictionary, stack: Array) -> Dictionary:
	var kind := str(node.get("kind", ""))
	if kind == "any":
		return {"ok": true, "node": node}
	if kind == "name":
		var nm := str(node.get("name", ""))
		var def := _alias_def(nm)
		if def.is_empty():
			return {"ok": true, "node": node}
		if nm in stack:
			return {"ok": false, "error": "circular alias '" + nm + "'"}
		var sub := _expand_tree_node((def as Dictionary).get("tree", {}), stack + [nm])
		if not bool(sub.get("ok", false)):
			return sub
		return {"ok": true, "node": sub.get("node", {})}
	if kind == "union":
		var arms: Array = []
		for arm in (node.get("arms", []) as Array):
			if not (arm is Dictionary):
				return {"ok": false, "error": "bad union arm"}
			var ex := _expand_tree_node(arm, stack)
			if not bool(ex.get("ok", false)):
				return ex
			arms.append(ex.get("node", {}))
		return {"ok": true, "node": {"kind": "union", "arms": arms}}
	if kind == "generic":
		var hname := str(node.get("name", ""))
		if not _alias_def(hname).is_empty():
			return {"ok": false, "error": "cannot apply type arguments to alias '" + hname + "'"}
		var args: Array = []
		for arg in (node.get("args", []) as Array):
			if not (arg is Dictionary):
				return {"ok": false, "error": "bad type argument"}
			var ex := _expand_tree_node(arg, stack)
			if not bool(ex.get("ok", false)):
				return ex
			args.append(ex.get("node", {}))
		return {"ok": true, "node": {"kind": "generic", "name": hname, "args": args}}
	return {"ok": false, "error": "bad type node"}


## Top-level head names of a tree (anonymous `tuple[...]` reads as
## `Array`; `*` arms are dynamic and skipped).
func _tree_top_heads(tree: Dictionary) -> Array:
	var arms: Array = []
	if str(tree.get("kind", "")) == "union":
		arms = (tree.get("arms", []) as Array).duplicate()
	else:
		arms = [tree]
	var out: Array = []
	for arm in arms:
		if not (arm is Dictionary):
			continue
		var kind := str((arm as Dictionary).get("kind", ""))
		if kind == "any":
			continue
		if kind == "name":
			out.append(str((arm as Dictionary).get("name", "")))
		elif kind == "generic":
			var hname := str((arm as Dictionary).get("name", ""))
			if hname == "tuple" and _tuple_def("tuple").is_empty():
				out.append("Array")
			else:
				out.append(hname)
	return out


## Post-resolve pass: alias members queued at attach narrow against
## the declared type through their expanded heads.
func _check_pending_alias_narrows() -> void:
	for pen in _pending_alias_narrows:
		if not (pen is Dictionary):
			continue
		var pd: Dictionary = pen
		var member := str(pd.get("member", ""))
		var ref := str(pd.get("ref", ""))
		var def := _alias_def(member)
		if def.is_empty():
			continue
		var exp := _expand_tree_aliases(def.get("tree", {}))
		if not bool(exp.get("ok", false)):
			continue
		for h in _tree_top_heads(exp.get("node", {})):
			var hs := str(h)
			if _nominal_compat(hs, ref):
				continue
			if str(pd.get("pkind", "")) == "param":
				_error(ERR_PARAM_MISMATCH, "cannot use @param type '" + hs + "' (from alias '" + member + "') for parameter '" + str(pd.get("label", "")) + "' declared as '" + ref + "' ('" + hs + "' is neither '" + ref + "' nor a subclass of it)", int(pd.get("line", 0)), 0, str(pd.get("owner", "")))
			else:
				_error(ERR_VAR_MISMATCH, "cannot use @var type '" + hs + "' (from alias '" + member + "') for variable '" + str(pd.get("label", "")) + "' declared as '" + ref + "' ('" + hs + "' is neither '" + ref + "' nor a subclass of it)", int(pd.get("line", 0)), int(pd.get("col", 0)), str(pd.get("owner", "")))


# ----------------------------------------------------- @template helpers
#
# File-local generic type variables ("# @template T",
# "# @template T of Bound"). Names work file-wide regardless of order
# but never leave the file: no JSON is written or read. Uses resolve
# as known names today; instantiation (substitution/unification below)
# lands with generics. Bounds must be concrete (no template vars).

func _find_template(value: String) -> Dictionary:
	return _find_tag(value, "template")


func _has_template_tag(tok: Dictionary) -> Dictionary:
	if str(tok.get("type", "")) != "TYPE_INFO":
		return {}
	return _find_template(str(tok.get("value", "")))


func _has_any_template_tag(node: Dictionary) -> bool:
	for c in node.get("leading_comments", []):
		if c is Dictionary and not _has_template_tag(c).is_empty():
			return true
	return false


## Parses an @template message ("Name" or "Name of Bound") into
## {"ok","name","bound","raw"} or {"ok": false, "error"}. The bound is
## raw text here (single line, like every tag message); it is parsed
## at resolve time.
static func _parse_template_spec(raw_msg: String) -> Dictionary:
	var raw := raw_msg.strip_edges()
	if raw == "":
		return {"ok": false, "error": "@template needs a name: '# @template T' or '# @template T of Bound'"}
	var words := _split_words(raw)
	var tname := str(words[0])
	if not _is_type_name(tname):
		return {"ok": false, "error": "@template has an invalid name '" + tname + "'"}
	var rest := raw.substr(tname.length()).strip_edges()
	if rest == "":
		return {"ok": true, "name": tname, "bound": "", "raw": raw}
	if rest == "of":
		return {"ok": false, "error": "@template needs a bound after 'of': '# @template T of Bound'"}
	if rest.begins_with("of ") or rest.begins_with("of\t") or rest.begins_with("of\n"):
		var bound := rest.substr(2).strip_edges()
		if bound == "":
			return {"ok": false, "error": "@template needs a bound after 'of': '# @template T of Bound'"}
		return {"ok": true, "name": tname, "bound": bound, "raw": raw}
	return {"ok": false, "error": "@template needs 'of' before the bound: '# @template T of Bound'"}


## Pre-scan (before _scan): collects @template raw definitions from
## top-level standalone comments and top-level leadings so name
## lookups stay order-free. Full validation happens in
## _resolve_templates.
func _prescan_templates(ast: Dictionary) -> void:
	for child in ast.get("children", []):
		if not (child is Dictionary):
			continue
		if str((child as Dictionary).get("type", "")) == "TYPE_INFO":
			_collect_template_node(child as Dictionary)
			continue
		for c in (child as Dictionary).get("leading_comments", []):
			if c is Dictionary:
				_collect_template_node(c)
	_collect_template_node(_header_tok(ast))


## Records every @template tag in one comment value as raw material.
## Malformed tags error immediately and are dropped; valid ones queue
## under their name (duplicates resolved in _resolve_templates).
func _collect_template_node(tok: Dictionary) -> void:
	if str(tok.get("type", "")) != "TYPE_INFO":
		return
	var tok_line := int(tok.get("line", 0))
	var li := 0
	for line in str(tok.get("value", "")).split("\n"):
		var tag := _find_tag(line, "template")
		if not tag.is_empty():
			var spec := _parse_template_spec(str(tag.get("message", "")))
			if not bool(spec.get("ok", false)):
				_error(ERR_TEMPLATE_MALFORMED, str(spec.get("error", "")), tok_line + li, 0, "")
			else:
				var tname := str(spec.get("name", ""))
				var raw := {"spec": spec, "line": tok_line + li}
				if not _templates.has(tname):
					_templates[tname] = {"resolved": false, "raws": [raw]}
				else:
					((_templates[tname] as Dictionary).get("raws", []) as Array).append(raw)
		li += 1


## Why a template name cannot be defined ("" when free). Template
## variables share no namespace with concrete types on purpose: any
## clash is an error, never shadowing.
func _template_conflict(tname: String) -> String:
	if tname == "null":
		return "reserved name 'null'"
	for key in _members.keys():
		var table: Dictionary = _members[key]
		if table.has(tname):
			return "script member '" + tname + "' (" + str((table[tname] as Dictionary).get("kind", "")) + ")"
	if _members.has(tname):
		return "script class '" + tname + "'"
	if tname == _script_class and tname != "":
		return "the script class name"
	if _tuples.has(tname) or _structs.has(tname) or _interfaces.has(tname) or _aliases.has(tname):
		return "an existing template type '" + tname + "'"
	if _type_file_exists(tname):
		return "an existing type '" + tname + "'"
	return ""


## Second pass (after _scan, before _walk): validates definitions
## (duplicates, conflicts, bounds) into specs. No JSON is written:
## templates are file-local.
func _resolve_templates() -> void:
	for tname in _templates.keys():
		var entry: Dictionary = _templates[tname]
		if bool(entry.get("resolved", false)):
			continue
		var raws: Array = entry.get("raws", [])
		if raws.is_empty():
			continue
		var first: Dictionary = raws[0]
		var spec: Dictionary = first.get("spec", {})
		if raws.size() > 1:
			_error(ERR_TEMPLATE_CONFLICT, "@template '" + tname + "' is defined more than once", int(first.get("line", 0)), 0, "")
			continue
		var clash := _template_conflict(tname)
		if clash != "":
			_error(ERR_TEMPLATE_CONFLICT, "@template '" + tname + "' conflicts with " + clash, int(first.get("line", 0)), 0, "")
			continue
		var bound_tree := {}
		if str(spec.get("bound", "")) != "":
			var parsed := _parse_type_expr(str(spec.get("bound", "")), "@template")
			if not bool(parsed.get("ok", false)):
				_error(ERR_TEMPLATE_MALFORMED, str(parsed.get("error", "")), int(first.get("line", 0)), 0, "")
				continue
			bound_tree = parsed.get("node", {})
			if _count_void_names(bound_tree) > 0:
				_error(ERR_TEMPLATE_MALFORMED, "@template 'void' is not a valid bound", int(first.get("line", 0)), 0, "")
				continue
			var rn := _resolve_tree_names(bound_tree)
			if not bool(rn.get("ok", false)):
				_error(ERR_TEMPLATE_UNKNOWN_TYPE, "@template has unknown type '" + str(rn.get("bad", "")) + "'", int(first.get("line", 0)), 0, "")
				continue
			if not _template_refs(bound_tree, _templates.keys()).is_empty():
				_error(ERR_TEMPLATE_MALFORMED, "@template bounds must be concrete (no template variables)", int(first.get("line", 0)), 0, "")
				continue
			var tv := _check_tree_tuples(bound_tree)
			if not bool(tv.get("ok", false)):
				_error(ERR_TEMPLATE_MISMATCH, "@template " + str(tv.get("mismatch", "")), int(first.get("line", 0)), 0, "")
				continue
		entry["resolved"] = true
		entry["spec"] = {"ok": true, "name": tname, "bound": bound_tree, "raw": str(spec.get("raw", "")), "line": int(first.get("line", 0))}


## Bound tree of a resolved template ({} when unbounded or unknown).
## File-local only: in-memory, never disk.
func _template_bound_of(tname: String) -> Dictionary:
	if _templates.has(tname):
		var entry: Dictionary = _templates[tname]
		if bool(entry.get("resolved", false)):
			return (entry.get("spec", {}) as Dictionary).get("bound", {})
	return {}


## Deep structural equality of two type trees.
static func _same_tree(a: Dictionary, b: Dictionary) -> bool:
	if str(a.get("kind", "")) != str(b.get("kind", "")):
		return false
	var kind := str(a.get("kind", ""))
	if kind == "any":
		return true
	if kind == "name":
		return str(a.get("name", "")) == str(b.get("name", ""))
	if kind == "union":
		var aa: Array = a.get("arms", [])
		var ba: Array = b.get("arms", [])
		if aa.size() != ba.size():
			return false
		for i in range(aa.size()):
			if not (aa[i] is Dictionary) or not (ba[i] is Dictionary):
				return false
			if not _same_tree(aa[i], ba[i]):
				return false
		return true
	if kind == "generic":
		if str(a.get("name", "")) != str(b.get("name", "")):
			return false
		var ga: Array = a.get("args", [])
		var gb: Array = b.get("args", [])
		if ga.size() != gb.size():
			return false
		for i in range(ga.size()):
			if not (ga[i] is Dictionary) or not (gb[i] is Dictionary):
				return false
			if not _same_tree(ga[i], gb[i]):
				return false
		return true
	return false


## Deep copy of a type tree (substitutions share nothing).
static func _copy_tree(node: Dictionary) -> Dictionary:
	var kind := str(node.get("kind", ""))
	if kind == "any":
		return {"kind": "any"}
	if kind == "name":
		return {"kind": "name", "name": str(node.get("name", ""))}
	if kind == "union":
		var arms: Array = []
		for arm in (node.get("arms", []) as Array):
			if arm is Dictionary:
				arms.append(_copy_tree(arm))
		return {"kind": "union", "arms": arms}
	if kind == "generic":
		var args: Array = []
		for arg in (node.get("args", []) as Array):
			if arg is Dictionary:
				args.append(_copy_tree(arg))
		return {"kind": "generic", "name": str(node.get("name", "")), "args": args}
	return {}


## Template variables referenced by a tree, deduplicated, against an
## explicit tvar list (keeps the core static and testable).
static func _template_refs(tree: Dictionary, tvars: Array) -> Array:
	var out: Array = []
	_collect_template_refs(tree, tvars, out, {})
	return out


static func _collect_template_refs(node: Dictionary, tvars: Array, out: Array, seen: Dictionary) -> void:
	var kind := str(node.get("kind", ""))
	if kind == "name":
		var nm := str(node.get("name", ""))
		if tvars.has(nm) and not seen.has(nm):
			seen[nm] = true
			out.append(nm)
	elif kind == "union":
		for arm in (node.get("arms", []) as Array):
			if arm is Dictionary:
				_collect_template_refs(arm, tvars, out, seen)
	elif kind == "generic":
		for arg in (node.get("args", []) as Array):
			if arg is Dictionary:
				_collect_template_refs(arg, tvars, out, seen)


## Substitutes template variables: name-leaves present in subst are
## replaced by deep copies of the value trees. Pure.
static func _subst_tree(node: Dictionary, subst: Dictionary) -> Dictionary:
	var kind := str(node.get("kind", ""))
	if kind == "name":
		var nm := str(node.get("name", ""))
		if subst.has(nm) and (subst[nm] is Dictionary):
			return _copy_tree(subst[nm])
		return {"kind": "name", "name": nm}
	if kind == "any":
		return {"kind": "any"}
	if kind == "union":
		var arms: Array = []
		for arm in (node.get("arms", []) as Array):
			if arm is Dictionary:
				arms.append(_subst_tree(arm, subst))
		return {"kind": "union", "arms": arms}
	if kind == "generic":
		var args: Array = []
		for arg in (node.get("args", []) as Array):
			if arg is Dictionary:
				args.append(_subst_tree(arg, subst))
		return {"kind": "generic", "name": str(node.get("name", "")), "args": args}
	return {}


## Structural unification of a formal tree against an actual tree.
## `tvars` are the bindable names. `any` matches anything without
## binding; concrete names must match; generics need equal heads and
## arity (a bare actual name matches its own head leniently, like the
## flat pipeline); unions match when some arm matches (first success
## wins). Returns {"ok", "subst"} or {"ok": false, "error"}.
static func _unify_trees(formal: Dictionary, actual: Dictionary, subst: Dictionary, tvars: Array) -> Dictionary:
	var fk := str(formal.get("kind", ""))
	if fk == "any":
		return {"ok": true, "subst": subst}
	if fk == "name":
		var fn := str(formal.get("name", ""))
		if tvars.has(fn):
			if subst.has(fn) and (subst[fn] is Dictionary):
				if _same_tree(subst[fn], actual):
					return {"ok": true, "subst": subst}
				return {"ok": false, "error": "conflicting types for '" + fn + "'"}
			var bound := subst.duplicate()
			bound[fn] = _copy_tree(actual)
			return {"ok": true, "subst": bound}
		var ak2 := str(actual.get("kind", ""))
		if ak2 == "any":
			return {"ok": true, "subst": subst}
		var aname := ""
		if ak2 == "name":
			aname = str(actual.get("name", ""))
		elif ak2 == "generic":
			aname = str(actual.get("name", ""))
		if tvars.has(aname):
			return {"ok": true, "subst": subst}
		if aname == fn:
			return {"ok": true, "subst": subst}
		return {"ok": false, "error": "'" + _show_tree(actual) + "' is not '" + fn + "'"}
	if fk == "union":
		for arm in (formal.get("arms", []) as Array):
			if arm is Dictionary:
				var trial := _unify_trees(arm, actual, subst.duplicate(), tvars)
				if bool(trial.get("ok", false)):
					return trial
		return {"ok": false, "error": "no union arm of '" + _show_tree(formal) + "' matches '" + _show_tree(actual) + "'"}
	if fk == "generic":
		var fh := str(formal.get("name", ""))
		var ak := str(actual.get("kind", ""))
		if ak == "any":
			return {"ok": true, "subst": subst}
		if ak == "name":
			if str(actual.get("name", "")) == fh:
				return {"ok": true, "subst": subst}
			return {"ok": false, "error": "'" + _show_tree(actual) + "' is not '" + _show_tree(formal) + "'"}
		if ak == "union":
			var cur: Dictionary = subst
			for arm in (actual.get("arms", []) as Array):
				if not (arm is Dictionary):
					return {"ok": false, "error": "'" + _show_tree(actual) + "' is not '" + _show_tree(formal) + "'"}
				var step := _unify_trees(formal, arm, cur, tvars)
				if not bool(step.get("ok", false)):
					return step
				cur = step.get("subst", cur)
			return {"ok": true, "subst": cur}
		if ak == "generic":
			if str(actual.get("name", "")) != fh:
				return {"ok": false, "error": "'" + _show_tree(actual) + "' is not '" + _show_tree(formal) + "'"}
			var fa: Array = formal.get("args", [])
			var aa: Array = actual.get("args", [])
			if fa.size() != aa.size():
				return {"ok": false, "error": "'" + _show_tree(formal) + "' takes " + str(fa.size()) + " arguments, got " + str(aa.size())}
			var cur: Dictionary = subst
			for i in range(fa.size()):
				if not ((fa[i] is Dictionary) and (aa[i] is Dictionary)):
					return {"ok": false, "error": "bad type argument"}
				var step := _unify_trees(fa[i], aa[i], cur, tvars)
				if not bool(step.get("ok", false)):
					return step
				cur = step.get("subst", cur)
			return {"ok": true, "subst": cur}
		return {"ok": false, "error": "'" + _show_tree(actual) + "' is not '" + _show_tree(formal) + "'"}
	return {"ok": false, "error": "bad type node"}


## Bound check: an actual tree fits an (already validated, concrete)
## bound tree. `any` bounds pass everything. Pure.
static func _check_bound(bound: Dictionary, actual: Dictionary) -> bool:
	if bound.is_empty() or str(bound.get("kind", "")) == "any":
		return true
	var r := _unify_trees(bound, actual, {}, [])
	return bool(r.get("ok", false))


# ------------------------------------------------------- @generic helpers
#
# Class-level generic parameters ("# @generic T1 T2" immediately
# before a class declaration). Every name must be a file @template
# (never a concrete type): the count is the class arity, tied to the
# instance. Stored on the class rec ("generic") and the class JSON.

func _find_generic(value: String) -> Dictionary:
	return _find_tag(value, "generic")


func _has_generic_tag(tok: Dictionary) -> Dictionary:
	if str(tok.get("type", "")) != "TYPE_INFO":
		return {}
	return _find_generic(str(tok.get("value", "")))


func _has_any_generic_tag(node: Dictionary) -> bool:
	for c in node.get("leading_comments", []):
		if c is Dictionary and not _has_generic_tag(c).is_empty():
			return true
	return false


## Marks one CLASS_DECL node generic from its leading @generic tags.
## Merges every tag in every leading token; names must be file
## template types, duplicates and repeats error out.
func _mark_generic_class(node: Dictionary, owner: String) -> void:
	var cname := str(node.get("name", ""))
	if cname == "" or not _members.has(owner):
		return
	var rec: Dictionary = (_members[owner] as Dictionary).get(cname, {})
	if rec.is_empty():
		return
	var names: Array = []
	var found := false
	for c in node.get("leading_comments", []):
		if not (c is Dictionary):
			continue
		var tag := _has_generic_tag(c)
		if tag.is_empty():
			continue
		found = true
		for w in _split_words(str(tag.get("message", ""))):
			var word := str(w)
			if not _is_type_name(word):
				_error(ERR_GENERIC_MALFORMED, "@generic has an invalid template name '" + word + "'", int(c.get("line", 0)), 0, owner)
				return
			if not _templates.has(word):
				_error(ERR_GENERIC_MALFORMED, "@generic '" + word + "' must be a template type of this file", int(c.get("line", 0)), 0, owner)
				return
			if word in names:
				_error(ERR_GENERIC_MALFORMED, "@generic lists '" + word + "' more than once", int(c.get("line", 0)), 0, owner)
				return
			names.append(word)
	if not found:
		return
	if names.is_empty():
		_error(ERR_GENERIC_MALFORMED, "@generic needs at least one template name: '# @generic T1 T2'", int(node.get("line", 0)), int(node.get("column", 0)), owner)
		return
	rec["generic"] = names


## Generic parameter names of a class key ("Outer.Inner"), [] when
## absent, root, or non-generic. In-memory only (cross-file classes
## stay lenient until their JSON is consulted by later work).
func _class_generic(key: String) -> Array:
	if key == "":
		return []
	var parts := str(key).split(".")
	var pname := str(parts[parts.size() - 1])
	var pkey := ".".join(parts.slice(0, parts.size() - 1))
	if not _members.has(pkey):
		return []
	var rec: Dictionary = (_members[pkey] as Dictionary).get(pname, {})
	if rec.is_empty():
		return []
	var out: Array = (rec.get("generic", []) as Array).duplicate()
	return out


## Records raw parameterized extends for a class (called once per
## CLASS_DECL from _scan_class_body): head text plus inner-argument
## text when brackets are present, else nothing. Validation waits
## for _check_pending_extends (post-resolve, order-free).
func _record_extends_args(full: String, node: Dictionary, owner: String) -> void:
	var toks := _extends_tokens_of(node)
	var open := -1
	for i in range(toks.size()):
		if toks[i] is Dictionary and str((toks[i] as Dictionary).get("type", "")) == "LBRACKET":
			open = i
			break
	if open < 0:
		return
	var head := ""
	for i in range(open):
		if toks[i] is Dictionary and (str((toks[i] as Dictionary).get("type", "")) == "IDENTIFIER" or str((toks[i] as Dictionary).get("type", "")) == "BUILTIN_TYPE"):
			head += str((toks[i] as Dictionary).get("value", ""))
		elif toks[i] is Dictionary and str((toks[i] as Dictionary).get("type", "")) == "DOT":
			head += "."
	head = head.strip_edges().trim_prefix(".").trim_suffix(".")
	if head == "":
		return
	var close := _match_bracket(toks, open)
	if close < 0:
		return
	var inner := ""
	for i in range(open + 1, close):
		if toks[i] is Dictionary:
			inner += str((toks[i] as Dictionary).get("value", ""))
	_extends_raw[full] = {"head": head, "inner": inner.strip_edges(), "line": int(node.get("line", 0)), "col": int(node.get("column", 0)), "owner": owner}


## Extends token list of a class node (inline extends_type first,
## then block-form EXTENDS children), [] when absent.
func _extends_tokens_of(node: Dictionary) -> Array:
	var ext: Variant = node.get("extends_type", null)
	if ext is Dictionary and ((ext as Dictionary).get("tokens", []) as Array).size() > 0:
		return (ext as Dictionary).get("tokens", [])
	var body: Variant = node.get("body", null)
	if body is Dictionary:
		for child in (body as Dictionary).get("children", []):
			if child is Dictionary and str((child as Dictionary).get("type", "")) == "EXTENDS":
				return (child as Dictionary).get("path", [])
	return []


## Index of the bracket matching toks[open_idx] (any of ()/[]/{}),
## or -1. Like _match_close but over an arbitrary token array.
static func _match_bracket(toks: Array, open_idx: int) -> int:
	if open_idx < 0 or open_idx >= toks.size() or not (toks[open_idx] is Dictionary):
		return -1
	var o := str((toks[open_idx] as Dictionary).get("type", ""))
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
	while i < toks.size():
		if toks[i] is Dictionary:
			var ty := str((toks[i] as Dictionary).get("type", ""))
			if ty == o:
				depth += 1
			elif ty == want:
				depth -= 1
				if depth == 0:
					return i
		i += 1
	return -1


## Splits text at top-level commas (bracket-aware). Pure.
static func _split_top_commas(text: String) -> Array:
	var out: Array = []
	var cur := ""
	var depth := 0
	for i in range(text.length()):
		var ch := text.substr(i, 1)
		if ch == "[" or ch == "(" or ch == "{":
			depth += 1
			cur += ch
		elif ch == "]" or ch == ")" or ch == "}":
			depth -= 1
			cur += ch
		elif ch == "," and depth == 0:
			out.append(cur)
			cur = ""
		else:
			cur += ch
	out.append(cur)
	return out


## Post-resolve pass: validates parameterized extends (arity against
## @generic classes, template bounds on arguments). Anything else
## (plain bases, engine heads, unknown heads, unbalanced brackets)
## stays silent exactly like today.
func _check_pending_extends() -> void:
	for full in _extends_raw.keys():
		var raw: Dictionary = _extends_raw[full]
		var head := str(raw.get("head", ""))
		var owner := str(raw.get("owner", ""))
		var line := int(raw.get("line", 0))
		var col := int(raw.get("col", 0))
		var key := _script_key_of(head, owner)
		if key == "":
			continue
		var params := _class_generic(key)
		if params.is_empty():
			continue
		var args: Array = []
		var broken := false
		for part in _split_top_commas(str(raw.get("inner", ""))):
			var text := str(part).strip_edges()
			if text == "":
				continue
			var parsed := _parse_type_expr(text, "extends")
			if not bool(parsed.get("ok", false)):
				broken = true
				break
			args.append(parsed.get("node", {}))
		if broken:
			continue
		if args.size() != params.size():
			_error(ERR_GENERIC_MISMATCH, "extends '" + head + "' takes " + str(params.size()) + " type argument(s), got " + str(args.size()), line, col, owner)
			continue
		var bad := false
		for i in range(args.size()):
			if not (args[i] is Dictionary):
				continue
			var bound := _template_bound_of(str(params[i]))
			if bound.is_empty():
				continue
			if not _template_refs(args[i], _templates.keys()).is_empty():
				continue
			if not _check_bound(bound, args[i]):
				_error(ERR_GENERIC_MISMATCH, "type '" + _show_tree(args[i]) + "' for '" + str(params[i]) + "' violates bound '" + _show_tree(bound) + "' in extends '" + head + "'", line, col, owner)
				bad = true
				break
		if bad:
			continue
		var tapp := false
		for arg in args:
			if not (arg is Dictionary):
				continue
			var earg: Dictionary = arg
			var eexp := _expand_tree_aliases(arg)
			if bool(eexp.get("ok", false)):
				earg = eexp.get("node", {})
			var tv := _check_tree_tuples(earg)
			if not bool(tv.get("ok", false)):
				_error(ERR_GENERIC_MISMATCH, "@generic " + str(tv.get("mismatch", "")), line, col, owner)
				tapp = true
				break
		if tapp:
			continue
		_extends_args[full] = {"key": key, "args": args}


# ------------------------------------------------------- @struct helpers

## Parses an @struct message ("Name COUNT field...") into {"ok",
## "name", "size", "fields", "raw"} or {"ok": false, "error"}. COUNT
## is mandatory and must equal the field count (checked by the
## caller). Fields stay raw words here.
static func _parse_struct_spec(raw_msg: String) -> Dictionary:
	var words := _split_words(raw_msg.strip_edges())
	if words.size() < 2:
		return {"ok": false, "error": "@struct needs a name and an explicit size: '# @struct Point 2 x:int y:int'"}
	var tname := str(words[0])
	if not _is_type_name(tname):
		return {"ok": false, "error": "@struct has an invalid name '" + tname + "'"}
	var count_word := str(words[1])
	for i in range(count_word.length()):
		var ch := count_word.unicode_at(i)
		if ch < 48 or ch > 57:
			return {"ok": false, "error": "@struct size must be a non-negative integer, got '" + count_word + "'"}
	var fields: Array = []
	for w in words.slice(2):
		fields.append(str(w))
	return {"ok": true, "name": tname, "size": int(count_word), "fields": fields, "raw": raw_msg.strip_edges()}


## Parses one struct field word: bare `name` (dynamic/any),
## `name:Type|Union`, `name:void` rejected. {} + error on failure.
func _parse_struct_field(word: String, line: int) -> Dictionary:
	var parts := _split_struct_field(word)
	var fname := str(parts.get("name", ""))
	if not _is_type_name(fname):
		_error(ERR_STRUCT_MALFORMED, "@struct has an invalid field name '" + fname + "'", line, 0, "")
		return {}
	var fspec := str(parts.get("spec", ""))
	if fspec == "" and word.find(":") >= 0:
		_error(ERR_STRUCT_MALFORMED, "@struct field '" + fname + "' needs a type after ':' (or nothing for dynamic)", line, 0, "")
		return {}
	if fspec == "":
		return {"name": fname, "types": [], "any": true}
	var spec := _parse_return_spec(fspec, "@struct")
	if not bool(spec.get("ok", false)):
		_error(ERR_STRUCT_MALFORMED, str(spec.get("error", "")), line, 0, "")
		return {}
	if bool(spec.get("void", false)):
		_error(ERR_STRUCT_MALFORMED, "@struct 'void' is not a valid field type", line, 0, "")
		return {}
	var types: Array = []
	for m in spec.get("types", []):
		var cm := _canon_type(str(m))
		if cm == "":
			_error(ERR_STRUCT_UNKNOWN_TYPE, "@struct has unknown type '" + str(m) + "'", line, 0, "")
			return {}
		types.append(cm)
	return {"name": fname, "types": types, "any": false}


## Pre-scan (before _scan): collects @struct raw definitions from
## top-level standalone comments and top-level leadings.
func _prescan_structs(ast: Dictionary) -> void:
	for child in ast.get("children", []):
		if not (child is Dictionary):
			continue
		if str((child as Dictionary).get("type", "")) == "TYPE_INFO":
			_collect_struct_node(child as Dictionary)
			continue
		for c in (child as Dictionary).get("leading_comments", []):
			if c is Dictionary:
				_collect_struct_node(c)
	_collect_struct_node(_header_tok(ast))


## Records every @struct tag in one comment value as raw material.
## Malformed tags error immediately and are dropped.
func _collect_struct_node(tok: Dictionary) -> void:
	if str(tok.get("type", "")) != "TYPE_INFO":
		return
	var tok_line := int(tok.get("line", 0))
	var li := 0
	for line in str(tok.get("value", "")).split("\n"):
		var tag := _find_tag(line, "struct")
		if not tag.is_empty():
			var spec := _parse_struct_spec(str(tag.get("message", "")))
			if not bool(spec.get("ok", false)):
				_error(ERR_STRUCT_MALFORMED, str(spec.get("error", "")), tok_line + li, 0, "")
			else:
				var tname := str(spec.get("name", ""))
				var raw := {"spec": spec, "line": tok_line + li}
				if not _structs.has(tname):
					_structs[tname] = {"resolved": false, "raws": [raw]}
				else:
					((_structs[tname] as Dictionary).get("raws", []) as Array).append(raw)
		li += 1


## Second pass (after _scan, before _walk): validates definitions
## (counts, duplicates, conflicts, field types incl. forward refs).
func _resolve_structs() -> void:
	_ensure_user_dir()
	for tname in _structs.keys():
		var entry: Dictionary = _structs[tname]
		if bool(entry.get("resolved", false)):
			continue
		var raws: Array = entry.get("raws", [])
		if raws.is_empty():
			continue
		var first: Dictionary = raws[0]
		var spec: Dictionary = first.get("spec", {})
		if raws.size() > 1:
			_error(ERR_STRUCT_CONFLICT, "@struct '" + tname + "' is defined more than once", int(first.get("line", 0)), 0, "")
			continue
		var clash := _struct_conflict(tname)
		if clash != "":
			_error(ERR_STRUCT_CONFLICT, "@struct '" + tname + "' conflicts with " + clash, int(first.get("line", 0)), 0, "")
			continue
		var fields: Array = []
		var ok := true
		var seen := {}
		if (spec.get("fields", []) as Array).size() != int(spec.get("size", -1)):
			_error(ERR_STRUCT_MALFORMED, "@struct '" + tname + "' declares size " + str(spec.get("size", 0)) + " but lists " + str((spec.get("fields", []) as Array).size()) + " fields", int(first.get("line", 0)), 0, "")
			ok = false
		else:
			for w in spec.get("fields", []):
				var field := _parse_struct_field(str(w), int(first.get("line", 0)))
				if field.is_empty():
					ok = false
					break
				if seen.has(str(field.get("name", ""))):
					_error(ERR_STRUCT_MALFORMED, "@struct '" + tname + "' repeats field '" + str(field.get("name", "")) + "'", int(first.get("line", 0)), 0, "")
					ok = false
					break
				seen[str(field.get("name", ""))] = true
				fields.append(field)
		if not ok:
			continue
		entry["resolved"] = true
		entry["spec"] = {"ok": true, "name": tname, "size": int(spec.get("size", 0)), "fields": fields, "raw": str(spec.get("raw", "")), "line": int(first.get("line", 0))}
		_write_struct_file(tname)


## Why a struct name cannot be defined ("" when free). Same rules as
## tuples: script members/classes, engine/builtin types, existing
## non-struct files all conflict; same-kind JSON rewrites are fine.
func _struct_conflict(tname: String) -> String:
	if tname == "null":
		return "reserved name 'null'"
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
		if not info.is_empty() and str(info.get("kind", "")) == "struct":
			return ""
		return "an existing type '" + tname + "'"
	return ""


## Resolved struct definition {size, fields} or {} (in-memory first,
## then same-kind JSON files, both cached).
func _struct_def(tname: String) -> Dictionary:
	if _structs.has(tname):
		var entry: Dictionary = _structs[tname]
		if bool(entry.get("resolved", false)):
			var spec: Dictionary = entry.get("spec", {})
			if bool(spec.get("ok", false)) and spec.has("fields"):
				return {"size": int(spec.get("size", 0)), "fields": spec.get("fields", [])}
	var info := _type_info(tname)
	if not info.is_empty() and str(info.get("kind", "")) == "struct":
		return {"size": int(info.get("size", 0)), "fields": info.get("fields", [])}
	return {}


## Writes one user/<Name>.json per resolved struct. Fields reuse the
## class `fields` shape ({name, type, types, any}) so every reader
## keeps working; kind "struct" distinguishes the closed key set.
func _write_struct_file(tname: String) -> void:
	var entry: Dictionary = _structs[tname]
	var spec: Dictionary = entry.get("spec", {})
	var fields: Array = []
	for f in spec.get("fields", []):
		var fd: Dictionary = f
		var ftypes: Array = (fd.get("types", []) as Array).duplicate()
		var ftype := ""
		if not bool(fd.get("any", false)):
			ftype = "|".join(ftypes)
		fields.append({"name": str(fd.get("name", "")), "type": ftype, "types": ftypes, "any": bool(fd.get("any", false))})
	var info := {
		"name": tname,
		"kind": "struct",
		"class_name": "",
		"resource_path": _script_resource_path,
		"parent": "",
		"inheritance_chain": [tname],
		"size": int(spec.get("size", 0)),
		"enums": [],
		"constants": [],
		"signals": [],
		"fields": fields,
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
				var entry := {"name": str(spec.get("name", "")), "types": spec.get("types", []), "raw": str(spec.get("raw", "")), "line": tok_line + li}
				if (spec as Dictionary).has("tree"):
					entry["tree"] = (spec as Dictionary).get("tree", {})
				if bool((spec as Dictionary).get("notnull", false)):
					entry["notnull"] = true
				if bool((spec as Dictionary).get("nullable", false)):
					entry["nullable"] = true
				out.append(entry)
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


## Canonicalizes a spec member list (case-correcting typos):
## {"ok", "types", "bad"}. On unknown, callers error with their own
## kind using "bad" (the as-written name).
func _canon_members(spec: Dictionary) -> Dictionary:
	var out: Array = []
	for m in spec.get("types", []):
		var cm := _canon_type(str(m))
		if cm == "":
			return {"ok": false, "types": [], "bad": str(m)}
		out.append(cm)
	return {"ok": true, "types": out, "bad": ""}


## True when a notnull spec can still be null: a bare `null` member
## or a `null` arm in the top-level tree. Alias members resolve
## post-mark, so they queue separately (see _queue_notnull_aliases).
## Nested `Array[null]` does not count: the array itself is never null.
func _spec_has_top_null(spec: Dictionary, members: Array) -> bool:
	for m in members:
		if str(m) == "null":
			return true
	if (spec as Dictionary).has("tree"):
		return _tree_has_top_null((spec as Dictionary).get("tree", {}))
	return false


static func _tree_has_top_null(node: Variant) -> bool:
	if not (node is Dictionary):
		return false
	var kind := str((node as Dictionary).get("kind", ""))
	if kind == "name":
		return str((node as Dictionary).get("name", "")) == "null"
	if kind == "union":
		for arm in ((node as Dictionary).get("arms", []) as Array):
			if _tree_has_top_null(arm):
				return true
	return false


## notnull-vs-nullable contradiction: errors with the annotation's
## malformed kind. Returns true when contradictory (callers skip
## stamping but keep every other check running).
func _check_notnull_clash(what: String, malformed_kind: String, spec: Dictionary, members: Array, line: int, col: int, owner: String) -> bool:
	if not bool(spec.get("notnull", false)):
		return false
	if not _spec_has_top_null(spec, members):
		return false
	_error(malformed_kind, what + " notnull contradicts nullable type '" + str(spec.get("raw", "")) + "'", line, col, owner)
	return true


## nullable-policy contradiction: `notnull`+`nullable` together, or
## `nullable` on a type that can never hold null. Returns true on
## contradiction (callers skip stamping but keep other checks).
## Deliberately asymmetric with notnull: aliases never contradict
## (their content is invisible, and `nullable` is advisory — watching
## a never-null slot only risks warnings, never unsoundness — while
## `notnull` is a guarantee, so it stays strict via the pending queue).
func _check_nullpolicy_clash(what: String, malformed_kind: String, spec: Dictionary, members: Array, line: int, col: int, owner: String) -> bool:
	if bool(spec.get("notnull", false)) and bool(spec.get("nullable", false)):
		_error(malformed_kind, what + " cannot combine 'notnull' and 'nullable'", line, col, owner)
		return true
	if not bool(spec.get("nullable", false)):
		return false
	if (members as Array).is_empty():
		return false
	for m in members:
		var ms := str(m)
		if ms == "null" or _null_fits(ms):
			return false
		if _aliases.has(ms) or not _alias_def(ms).is_empty():
			return false
		if _opaque_script(ms):
			return false
	_error(malformed_kind, what + " nullable contradicts non-nullable type '" + str(spec.get("raw", "")) + "'", line, col, owner)
	return true


## Queues alias members of a notnull spec for post-resolve
## contradiction (alias trees only exist after _resolve_aliases).
## Skipped when the direct check already fired, and stamp (the live
## var_ann/param_ann/return_ann dict) is erased on contradiction.
func _queue_notnull_aliases(spec: Dictionary, members: Array, what: String, malformed_kind: String, line: int, col: int, owner: String, stamp: Dictionary, direct_clash: bool) -> void:
	if not bool(spec.get("notnull", false)) or direct_clash:
		return
	for m in members:
		if str(m) == "null":
			continue
		if _aliases.has(str(m)) or not _alias_def(str(m)).is_empty():
			_pending_notnull_clash.append({"member": str(m), "what": what, "mkind": malformed_kind, "raw": str(spec.get("raw", "")), "line": line, "col": col, "owner": owner, "stamp": stamp})


## Evaluates queued alias contradictions once alias trees resolve.
func _check_pending_notnull() -> void:
	for pen in _pending_notnull_clash:
		if not (pen is Dictionary):
			continue
		var member := str((pen as Dictionary).get("member", ""))
		var def := _alias_def(member)
		if def.is_empty():
			continue
		var exp := _expand_tree_aliases(def.get("tree", {}))
		if not bool(exp.get("ok", false)):
			continue
		if not _tree_has_top_null(exp.get("node", {})):
			continue
		var stamp: Variant = (pen as Dictionary).get("stamp", {})
		if stamp is Dictionary:
			(stamp as Dictionary).erase("notnull")
		_error(str((pen as Dictionary).get("mkind", "")), str((pen as Dictionary).get("what", "")) + " notnull contradicts nullable type '" + str((pen as Dictionary).get("raw", "")) + "'", int((pen as Dictionary).get("line", 0)), int((pen as Dictionary).get("col", 0)), str((pen as Dictionary).get("owner", "")))


## Narrows one @param pair against a PARAM node: known members
## narrowing the declared vartype (untyped params accept anything).
## Stamps pnode["param_ann"].
func _check_param_pair(pair: Dictionary, pnode: Dictionary, owner: String) -> void:
	var line := int(pair.get("line", int(pnode.get("line", 0))))
	var cm := _canon_members(pair)
	if not bool(cm.get("ok", false)):
		_error(ERR_PARAM_UNKNOWN_TYPE, "@param has unknown type '" + str(cm.get("bad", "")) + "'", line, 0, owner)
		return
	if not _report_tree_errors(pair, ERR_PARAM_UNKNOWN_TYPE, ERR_PARAM_MISMATCH, "@param", line, 0, owner):
		return
	var members: Array = cm.get("types", [])
	var ref := _vartype_name(pnode)
	if ref != "" and ref != "Variant" and ref != "dynamic":
		for m in members:
			if _aliases.has(str(m)) or not _alias_def(str(m)).is_empty():
				_pending_alias_narrows.append({"member": str(m), "ref": ref, "label": str(pair.get("name", "")), "line": line, "col": 0, "owner": owner, "pkind": "param"})
				continue
			if not _nominal_compat(str(m), ref):
				_error(ERR_PARAM_MISMATCH, "cannot use @param type '" + str(m) + "' for parameter '" + str(pair.get("name", "")) + "' declared as '" + ref + "' ('" + str(m) + "' is neither '" + ref + "' nor a subclass of it)", line, 0, owner)
	var notnull_clash := _check_notnull_clash("@param", ERR_PARAM_MALFORMED, pair, members, line, 0, owner)
	var policy_clash := _check_nullpolicy_clash("@param", ERR_PARAM_MALFORMED, pair, members, line, 0, owner)
	var clash := notnull_clash or policy_clash
	if bool(pair.get("notnull", false)) and not clash and _value_is_bare_null((pnode as Dictionary).get("default", null)):
		_error(ERR_PARAM_NOTNULL, "cannot assign null to notnull parameter '" + str(pair.get("name", "")) + "'", line, 0, owner)
	pnode["param_ann"] = {"name": str(pair.get("name", "")), "types": members, "raw": str(pair.get("raw", "")), "line": line}
	if (pair as Dictionary).has("tree"):
		(pnode["param_ann"] as Dictionary)["tree"] = (pair as Dictionary).get("tree", {})
	if bool(pair.get("notnull", false)) and not clash:
		(pnode["param_ann"] as Dictionary)["notnull"] = true
	if bool(pair.get("nullable", false)) and not clash:
		(pnode["param_ann"] as Dictionary)["nullable"] = true
	_queue_notnull_aliases(pair, members, "@param", ERR_PARAM_MALFORMED, line, 0, owner, pnode.get("param_ann", {}), clash)


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


# ------------------------------------------------------- @interface helpers

func _find_interface(value: String) -> Dictionary:
	return _find_tag(value, "interface")


func _has_interface_tag(tok: Dictionary) -> Dictionary:
	if str(tok.get("type", "")) != "TYPE_INFO":
		return {}
	return _find_interface(str(tok.get("value", "")))


func _has_any_interface_tag(node: Dictionary) -> bool:
	for c in node.get("leading_comments", []):
		if c is Dictionary and not _has_interface_tag(c).is_empty():
			return true
	return false


## Splits a comment token value into words (1+ whitespaces of any
## kind), dropping pure-`#` words left by merged comment lines.
static func _iface_words(value: String) -> Array:
	var out: Array = []
	for w in _split_words(value):
		var word := str(w)
		var hashes := true
		for i in range(word.length()):
			if word.unicode_at(i) != 35:
				hashes = false
				break
		if word != "" and not hashes:
			out.append(word)
	return out


## Pre-scan (before _scan): collects @interface raw blocks from
## top-level standalone comments and top-level leadings. Each block is
## {name, words, line}; missing @endinterface errors here.
func _prescan_interfaces(ast: Dictionary) -> void:
	for child in ast.get("children", []):
		if not (child is Dictionary):
			continue
		if str((child as Dictionary).get("type", "")) == "TYPE_INFO":
			_collect_interface_tok(child as Dictionary)
			continue
		for c in (child as Dictionary).get("leading_comments", []):
			if c is Dictionary:
				_collect_interface_tok(c)
	_collect_interface_tok(_header_tok(ast))


## Collects @interface blocks from one comment token. Several blocks
## may share a token; stray @endinterface words are ignored.
func _collect_interface_tok(tok: Dictionary) -> void:
	if str(tok.get("type", "")) != "TYPE_INFO":
		return
	var words := _iface_words(str(tok.get("value", "")))
	var i := 0
	while i < words.size():
		if str(words[i]) != "@interface":
			i += 1
			continue
		if i + 1 >= words.size():
			_error(ERR_INTERFACE_MALFORMED, "@interface needs a name", int(tok.get("line", 0)), 0, "")
			return
		var iname := str(words[i + 1])
		if not _is_type_name(iname):
			_error(ERR_INTERFACE_MALFORMED, "@interface has an invalid name '" + iname + "'", int(tok.get("line", 0)), 0, "")
			return
		var j := i + 2
		while j < words.size() and str(words[j]) != "@endinterface":
			j += 1
		if j >= words.size():
			_error(ERR_INTERFACE_MALFORMED, "@interface '" + iname + "' is missing @endinterface", int(tok.get("line", 0)), 0, "")
			return
		var block := {"name": iname, "words": words.slice(i + 2, j), "line": int(tok.get("line", 0))}
		if not _interfaces.has(iname):
			_interfaces[iname] = {"resolved": false, "raws": [block]}
		else:
			((_interfaces[iname] as Dictionary).get("raws", []) as Array).append(block)
		i = j + 1


## Second pass (after _scan, before _walk): validates interface blocks
## and writes their JSON files.
func _resolve_interfaces() -> void:
	_ensure_user_dir()
	for iname in _interfaces.keys():
		var entry: Dictionary = _interfaces[iname]
		if bool(entry.get("resolved", false)):
			continue
		var raws: Array = entry.get("raws", [])
		if raws.is_empty():
			continue
		var first: Dictionary = raws[0]
		if raws.size() > 1:
			_error(ERR_INTERFACE_CONFLICT, "@interface '" + iname + "' is defined more than once", int(first.get("line", 0)), 0, "")
			continue
		var clash := _iface_conflict(iname)
		if clash != "":
			_error(ERR_INTERFACE_CONFLICT, "@interface '" + iname + "' conflicts with " + clash, int(first.get("line", 0)), 0, "")
			continue
		var members := _parse_iface_members(first.get("words", []), int(first.get("line", 0)))
		if members.is_empty() and not (first.get("words", []) as Array).is_empty():
			continue
		entry["resolved"] = true
		entry["spec"] = {"ok": true, "name": iname, "members": members, "line": int(first.get("line", 0))}
		_write_interface_file(iname)


## Parses member words into [{kind, static, name, ...}]. Returns [] on
## any error (each error reported inline). Empty word lists (empty
## interfaces) yield [] cleanly. A lone `static` word prefixes the next
## member (colon form `static:...` also accepted).
func _parse_iface_members(words: Variant, line: int) -> Array:
	var out: Array = []
	if not (words is Array):
		return out
	var seen := {}
	var pending_static := false
	for w in words:
		var word := str(w)
		if word == "static":
			pending_static = true
			continue
		var m := _parse_iface_member(word, line, pending_static)
		pending_static = false
		if m.is_empty():
			return []
		var key := str(m.get("kind", "")) + ":" + str(m.get("name", ""))
		if seen.has(key):
			_error(ERR_INTERFACE_MALFORMED, "@interface repeats member '" + str(m.get("name", "")) + "'", line, 0, "")
			return []
		seen[key] = true
		out.append(m)
	if pending_static:
		_error(ERR_INTERFACE_MALFORMED, "@interface 'static' needs a member after it", line, 0, "")
		return []
	return out


## Parses one member word: [static] kind:name[:rest] (`static` also
## arrives as a separate word via pending_static). A trailing `:` with
## nothing after it is always malformed (write nothing instead).
## Returns {} + error on failure.
func _parse_iface_member(word: String, line: int, pending_static: bool = false) -> Dictionary:
	if word.ends_with(":"):
		_error(ERR_INTERFACE_MALFORMED, "@interface member '" + word + "' has a trailing ':' with nothing after it", line, 0, "")
		return {}
	var body := word
	var is_static := pending_static
	if body == "static" or body.begins_with("static:"):
		if body == "static":
			_error(ERR_INTERFACE_MALFORMED, "@interface 'static' needs kind, name and body", line, 0, "")
			return {}
		is_static = true
		body = body.substr(7)
	var ci := body.find(":")
	var kind := body
	var rest := ""
	if ci >= 0:
		kind = body.substr(0, ci)
		rest = body.substr(ci + 1)
	if kind != "var" and kind != "func" and kind != "const" and kind != "enum" and kind != "signal":
		_error(ERR_INTERFACE_MALFORMED, "@interface has an unknown member kind '" + kind + "'", line, 0, "")
		return {}
	if is_static and kind != "var" and kind != "func":
		_error(ERR_INTERFACE_MALFORMED, "@interface only var and func can be static", line, 0, "")
		return {}
	if kind == "var" or kind == "const":
		return _parse_iface_varconst(kind, is_static, rest, line)
	if kind == "enum":
		return _parse_iface_enum(rest, line)
	if kind == "signal":
		return _parse_iface_signal(rest, line)
	return _parse_iface_func(rest, is_static, line)


## var:name[:types] / const:name[:types]. Bare means any.
func _parse_iface_varconst(kind: String, is_static: bool, rest: String, line: int) -> Dictionary:
	if rest == "":
		_error(ERR_INTERFACE_MALFORMED, "@interface " + kind + " needs a name", line, 0, "")
		return {}
	var np: Array = rest.split(":", true, 1)
	var vname := str(np[0])
	if not _is_type_name(vname):
		_error(ERR_INTERFACE_MALFORMED, "@interface has an invalid name '" + vname + "'", line, 0, "")
		return {}
	if np.size() < 2:
		return {"kind": kind, "static": is_static, "name": vname, "types": [], "any": true}
	var spec := _parse_return_spec(str(np[1]), "@interface")
	if not bool(spec.get("ok", false)):
		_error(ERR_INTERFACE_MALFORMED, str(spec.get("error", "")), line, 0, "")
		return {}
	if bool(spec.get("void", false)):
		_error(ERR_INTERFACE_MALFORMED, "@interface 'void' is not a valid member type", line, 0, "")
		return {}
	var types: Array = []
	for m in spec.get("types", []):
		var cm := _canon_type(str(m))
		if cm == "":
			_error(ERR_INTERFACE_UNKNOWN_TYPE, "@interface has unknown type '" + str(m) + "'", line, 0, "")
			return {}
		types.append(cm)
	return {"kind": kind, "static": is_static, "name": vname, "types": types, "any": false}


## enum:Name:m1,m2 (names only, at least one).
func _parse_iface_enum(rest: String, line: int) -> Dictionary:
	if rest == "":
		_error(ERR_INTERFACE_MALFORMED, "@interface enum needs a name and members", line, 0, "")
		return {}
	var np: Array = rest.split(":", true, 1)
	var ename := str(np[0])
	if not _is_type_name(ename):
		_error(ERR_INTERFACE_MALFORMED, "@interface has an invalid enum name '" + ename + "'", line, 0, "")
		return {}
	if np.size() < 2 or str(np[1]).strip_edges() == "":
		_error(ERR_INTERFACE_MALFORMED, "@interface enum '" + ename + "' needs at least one member", line, 0, "")
		return {}
	var vals: Array = []
	for v in str(np[1]).split(","):
		var member := str(v).strip_edges()
		if member == "" or not _is_type_name(member):
			_error(ERR_INTERFACE_MALFORMED, "@interface enum '" + ename + "' has an invalid member '" + str(v) + "'", line, 0, "")
			return {}
		vals.append({"name": member, "value": null})
	return {"kind": "enum", "static": false, "name": ename, "members": vals}


## signal:name[:params] (no defaults, no varargs).
func _parse_iface_signal(rest: String, line: int) -> Dictionary:
	if rest == "":
		_error(ERR_INTERFACE_MALFORMED, "@interface signal needs a name", line, 0, "")
		return {}
	var np: Array = rest.split(":", true, 1)
	var sname := str(np[0])
	if not _is_type_name(sname):
		_error(ERR_INTERFACE_MALFORMED, "@interface has an invalid signal name '" + sname + "'", line, 0, "")
		return {}
	var params: Array = []
	if np.size() > 1:
		if ";" in str(np[1]) or "..." in str(np[1]):
			_error(ERR_INTERFACE_MALFORMED, "@interface signals cannot have default or vararg parameters", line, 0, "")
			return {}
		params = _parse_iface_params(str(np[1]), line)
		if params.is_empty():
			return {}
	return {"kind": "signal", "static": false, "name": sname, "params": params}


## func[:name][:return[:params]]: bare name means any-return without
## params; empty return or param sections are invalid (write void).
func _parse_iface_func(rest: String, is_static: bool, line: int) -> Dictionary:
	if rest == "":
		_error(ERR_INTERFACE_MALFORMED, "@interface func needs a name", line, 0, "")
		return {}
	var np: Array = rest.split(":", true, 1)
	var fname := str(np[0])
	if not _is_type_name(fname):
		_error(ERR_INTERFACE_MALFORMED, "@interface has an invalid function name '" + fname + "'", line, 0, "")
		return {}
	if np.size() < 2:
		return {"kind": "func", "static": is_static, "name": fname, "returns": "any", "params": [], "vararg": false}
	var tail := str(np[1])
	if tail == "":
		_error(ERR_INTERFACE_MALFORMED, "@interface func '" + fname + "' with ':' needs a return type (write void)", line, 0, "")
		return {}
	var rp: Array = tail.split(":", true, 1)
	var returns := "any"
	var ptext := ""
	if rp.size() > 1:
		if str(rp[1]).strip_edges() == "":
			_error(ERR_INTERFACE_MALFORMED, "@interface func '" + fname + "' with ':' needs parameters (or drop the colon)", line, 0, "")
			return {}
		ptext = str(rp[1])
	var rspec := _parse_return_spec(str(rp[0]), "@interface")
	if not bool(rspec.get("ok", false)):
		_error(ERR_INTERFACE_MALFORMED, str(rspec.get("error", "")), line, 0, "")
		return {}
	if not bool(rspec.get("void", false)):
		var rtypes: Array = []
		for m in rspec.get("types", []):
			var cm := _canon_type(str(m))
			if cm == "":
				_error(ERR_INTERFACE_UNKNOWN_TYPE, "@interface has unknown type '" + str(m) + "'", line, 0, "")
				return {}
			rtypes.append(cm)
		returns = "|".join(rtypes)
	else:
		returns = "void"
	var params: Array = []
	if ptext != "":
		params = _parse_iface_params(ptext, line)
		if params.is_empty():
			return {}
	var vararg := false
	if not params.is_empty() and bool((params[params.size() - 1] as Dictionary).get("is_vararg", false)):
		vararg = true
	return {"kind": "func", "static": is_static, "name": fname, "returns": returns, "params": params, "vararg": vararg}


## Parses a param list "name:type,..." with an optional ";defaults"
## section (one semicolon max). `...`-prefixed params must be last.
## Empty entries are malformed. Returns [] on error (reported inline);
## callers only invoke it with non-empty text, so [] means failure.
func _parse_iface_params(text: String, line: int) -> Array:
	var out: Array = []
	var parts: Array = text.split(";", true)
	if parts.size() > 2:
		_error(ERR_INTERFACE_MALFORMED, "@interface params take at most one ';' defaults section", line, 0, "")
		return []
	var sections := [false, true]
	for si in range(parts.size()):
		var chunk := str(parts[si]).strip_edges()
		if chunk == "":
			continue
		for entry in chunk.split(","):
			var raw := str(entry).strip_edges()
			if raw == "":
				_error(ERR_INTERFACE_MALFORMED, "@interface has an empty parameter", line, 0, "")
				return []
			var is_var := false
			if raw.begins_with("..."):
				is_var = true
				raw = raw.substr(3).strip_edges()
			var pp: Array = raw.split(":", true, 1)
			var pname := str(pp[0])
			if not _is_type_name(pname):
				_error(ERR_INTERFACE_MALFORMED, "@interface has an invalid parameter name '" + pname + "'", line, 0, "")
				return []
			var ptypes: Array = []
			var pany := false
			if pp.size() < 2 or str(pp[1]).strip_edges() == "":
				if pp.size() > 1:
					_error(ERR_INTERFACE_MALFORMED, "@interface param '" + pname + "' needs a type after ':' (or nothing for dynamic)", line, 0, "")
					return []
				pany = true
			else:
				var pspec := _parse_return_spec(str(pp[1]), "@interface")
				if not bool(pspec.get("ok", false)):
					_error(ERR_INTERFACE_MALFORMED, str(pspec.get("error", "")), line, 0, "")
					return []
				if bool(pspec.get("void", false)):
					_error(ERR_INTERFACE_MALFORMED, "@interface 'void' is not a valid parameter type", line, 0, "")
					return []
				for m in pspec.get("types", []):
					var cm := _canon_type(str(m))
					if cm == "":
						_error(ERR_INTERFACE_UNKNOWN_TYPE, "@interface has unknown type '" + str(m) + "'", line, 0, "")
						return []
					ptypes.append(cm)
			out.append({"name": pname, "type": "|".join(ptypes), "types": ptypes, "any": pany, "has_default": bool(sections[si]), "default": null, "is_vararg": is_var})
	for i in range(out.size()):
		if bool((out[i] as Dictionary).get("is_vararg", false)) and i < out.size() - 1:
			_error(ERR_INTERFACE_MALFORMED, "@interface vararg must be the last parameter", line, 0, "")
			return []
	return out


## Why an interface name cannot be defined ("" when free). Same rules
## as tuples/structs: script members/classes, engine/builtin types and
## existing non-interface files all conflict.
func _iface_conflict(tname: String) -> String:
	if tname == "null":
		return "reserved name 'null'"
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
		if not info.is_empty() and str(info.get("kind", "")) == "interface":
			return ""
		return "an existing type '" + tname + "'"
	return ""


## Writes one user/<Name>.json per resolved interface, reusing the
## class entry shapes (methods split static/instance, fields with
## flags, signals, enums with null values, constants with nulls).
func _write_interface_file(tname: String) -> void:
	var entry: Dictionary = _interfaces[tname]
	var spec: Dictionary = entry.get("spec", {})
	var fields: Array = []
	var static_methods: Array = []
	var instance_methods: Array = []
	var signals: Array = []
	var enums: Array = []
	var constants: Array = []
	for m in spec.get("members", []):
		var md: Dictionary = m
		var kind := str(md.get("kind", ""))
		if kind == "var":
			var ftypes: Array = (md.get("types", []) as Array).duplicate()
			var ftype := ""
			if not bool(md.get("any", false)):
				ftype = "|".join(ftypes)
			fields.append({"name": str(md.get("name", "")), "type": ftype, "types": ftypes, "any": bool(md.get("any", "")), "is_static": bool(md.get("static", false)), "is_exported": false, "is_onready": false, "default": null})
		elif kind == "func":
			var params: Array = []
			for p in (md.get("params", []) as Array):
				var pd: Dictionary = p
				params.append({"name": str(pd.get("name", "")), "type": str(pd.get("type", "")), "types": (pd.get("types", []) as Array).duplicate(), "any": bool(pd.get("any", false)), "has_default": bool(pd.get("has_default", false)), "default": null, "is_vararg": bool(pd.get("is_vararg", false))})
			var ment := {"name": str(md.get("name", "")), "returns": str(md.get("returns", "")), "is_vararg": bool(md.get("vararg", false)), "is_const": false, "is_virtual": false, "params": params, "static": bool(md.get("static", false))}
			if bool(md.get("static", false)):
				static_methods.append(ment)
			else:
				instance_methods.append(ment)
		elif kind == "signal":
			var sparams: Array = []
			for p in (md.get("params", []) as Array):
				var pd: Dictionary = p
				sparams.append({"name": str(pd.get("name", "")), "type": str(pd.get("type", "")), "types": (pd.get("types", []) as Array).duplicate(), "any": bool(pd.get("any", false)), "has_default": false, "default": null, "is_vararg": false})
			signals.append({"name": str(md.get("name", "")), "params": sparams})
		elif kind == "enum":
			var vals: Array = []
			for v in (md.get("members", []) as Array):
				vals.append({"name": str((v as Dictionary).get("name", "")), "value": null})
			enums.append({"name": str(md.get("name", "")), "is_bitfield": false, "values": vals})
		elif kind == "const":
			var ctypes: Array = (md.get("types", []) as Array).duplicate()
			var ctype := ""
			if not bool(md.get("any", false)):
				ctype = "|".join(ctypes)
			constants.append({"name": str(md.get("name", "")), "value": null, "type": ctype, "types": ctypes, "any": bool(md.get("any", false))})
	var info := {
		"name": tname,
		"kind": "interface",
		"class_name": "",
		"resource_path": _script_resource_path,
		"parent": "",
		"inheritance_chain": [tname],
		"size": (spec.get("members", []) as Array).size(),
		"enums": enums,
		"constants": constants,
		"signals": signals,
		"fields": fields,
		"static_methods": static_methods,
		"instance_methods": instance_methods,
		"inner_classes": [],
	}
	_write_json(_write_base + "/user/" + tname + ".json", info)
	_written.append(_write_base + "/user/" + tname + ".json")


# ------------------------------------------------------- @implements

func _find_implements(value: String) -> Dictionary:
	return _find_tag(value, "implements")


func _has_implements_tag(tok: Dictionary) -> Dictionary:
	if str(tok.get("type", "")) != "TYPE_INFO":
		return {}
	return _find_implements(str(tok.get("value", "")))


func _has_any_implements_tag(node: Dictionary) -> bool:
	for c in node.get("leading_comments", []):
		if c is Dictionary and not _has_implements_tag(c).is_empty():
			return true
	return false


## Dotted type names: every dot-separated part must be an identifier.
static func _is_dotted_name(text: String) -> bool:
	if text == "":
		return false
	for part in text.split("."):
		if not _is_type_name(str(part)):
			return false
	return true


## Canonical dotted name: first-letter-uppercased every lowercase
## leading segment (mirrors _canon_type for paths). Names are validated
## by callers; resolution happens in _implement_target.
static func _canon_dotted(text: String) -> String:
	var parts: Array = text.split(".")
	var fixed: Array = []
	for p in parts:
		var ps := str(p)
		if ps != "" and ps.unicode_at(0) >= 97 and ps.unicode_at(0) <= 122:
			fixed.append(ps.substr(0, 1).to_upper() + ps.substr(1))
		else:
			fixed.append(ps)
	return ".".join(fixed)


## Records one raw @implements use (words validated for shape only;
## resolution needs complete tables, so it happens in _check_implements).
func _record_implements(owner: String, node: Dictionary, line: int) -> void:
	for c in node.get("leading_comments", []):
		if not (c is Dictionary):
			continue
		var tag := _has_implements_tag(c)
		if tag.is_empty():
			continue
		_record_implements_words(owner, _split_words(str(tag.get("message", ""))), line)


## Records validated @implements words under an owner.
func _record_implements_words(owner: String, words: Array, line: int) -> void:
	var names: Array = []
	for w in words:
		var word := str(w)
		if not _is_dotted_name(word):
			_error(ERR_IMPLEMENTS_MALFORMED, "@implements needs valid type names, got '" + word + "'", line, 0, owner)
			return
		names.append(_canon_dotted(word))
	if names.is_empty():
		_error(ERR_IMPLEMENTS_MALFORMED, "@implements needs at least one type name", line, 0, owner)
		return
	if not _implements.has(owner):
		_implements[owner] = []
	(_implements[owner] as Array).append({"names": names, "line": line})


## Records one standalone @implements comment token (top level only).
func _record_implements_tok(owner: String, tok: Dictionary) -> void:
	var tag := _has_implements_tag(tok)
	if tag.is_empty():
		return
	_record_implements_words(owner, _split_words(str(tag.get("message", ""))), int(tok.get("line", 0)))


## Resolved interface spec {members} from the registry ({} when the
## interface failed validation: its own errors already reported).
func _iface_spec(iname: String) -> Dictionary:
	if _interfaces.has(iname):
		var entry: Dictionary = _interfaces[iname]
		if bool(entry.get("resolved", false)):
			return entry.get("spec", {})
	var info := _type_info(iname)
	if not info.is_empty() and str(info.get("kind", "")) == "interface":
		return {"members": _iface_members_from_json(info)}
	return {}


## Interface members from a JSON file into _sort_iface_member shape.
func _iface_members_from_json(info: Dictionary) -> Array:
	var out: Array = []
	for f in info.get("fields", []):
		if f is Dictionary:
			out.append({"kind": "var", "static": bool((f as Dictionary).get("is_static", false)), "name": str((f as Dictionary).get("name", "")), "types": (f as Dictionary).get("types", []), "any": bool((f as Dictionary).get("any", false))})
	for m in info.get("static_methods", []):
		if m is Dictionary:
			out.append(_iface_method_from_json(m, true))
	for m in info.get("instance_methods", []):
		if m is Dictionary:
			out.append(_iface_method_from_json(m, false))
	for s in info.get("signals", []):
		if s is Dictionary:
			out.append({"kind": "signal", "static": false, "name": str((s as Dictionary).get("name", "")), "params": (s as Dictionary).get("params", [])})
	for e in info.get("enums", []):
		if e is Dictionary:
			out.append({"kind": "enum", "static": false, "name": str((e as Dictionary).get("name", "")), "members": (e as Dictionary).get("values", [])})
	for c in info.get("constants", []):
		if c is Dictionary:
			out.append({"kind": "const", "static": false, "name": str((c as Dictionary).get("name", "")), "types": (c as Dictionary).get("types", []), "any": bool((c as Dictionary).get("any", false))})
	return out


## One interface method entry from JSON params shape.
func _iface_method_from_json(md: Dictionary, is_static: bool) -> Dictionary:
	var params: Array = []
	for p in (md as Dictionary).get("params", []):
		if p is Dictionary:
			params.append({"name": str((p as Dictionary).get("name", "")), "types": (p as Dictionary).get("types", []), "any": bool((p as Dictionary).get("any", false)), "req": not bool((p as Dictionary).get("has_default", false)) and not bool((p as Dictionary).get("is_vararg", false))})
	return {"kind": "func", "static": is_static, "name": str(md.get("name", "")), "returns": str(md.get("returns", "any")), "params": params}


## Interface func member by name (any staticness: instance calls
## stay lenient), {} when absent.
func _iface_method(ispec: Dictionary, mname: String) -> Dictionary:
	for m in (ispec.get("members", []) as Array):
		if m is Dictionary and str((m as Dictionary).get("kind", "")) == "func" and str((m as Dictionary).get("name", "")) == mname:
			return m
	return {}


## Interface var member by name ({types, any}), {} when absent.
func _iface_field(ispec: Dictionary, mname: String) -> Dictionary:
	for m in (ispec.get("members", []) as Array):
		if m is Dictionary and str((m as Dictionary).get("kind", "")) == "var" and str((m as Dictionary).get("name", "")) == mname:
			return {"types": ((m as Dictionary).get("types", []) as Array).duplicate(), "any": bool((m as Dictionary).get("any", false))}
	return {}


## Required parameters of an interface method (defaults and varargs
## excluded), total count, and vararg flag. Handles both spec shapes
## (parsed members carry has_default/is_vararg; JSON members carry req).
static func _iface_arity(fentry: Dictionary) -> Array:
	var req := 0
	var pars: Array = fentry.get("params", [])
	for p in pars:
		if not (p is Dictionary):
			continue
		var pd: Dictionary = p
		if pd.has("req"):
			if bool(pd.get("req", true)):
				req += 1
		elif not bool(pd.get("has_default", false)) and not bool(pd.get("is_vararg", false)):
			req += 1
	return [req, pars.size(), bool(fentry.get("vararg", false))]


## Checks one interface method call (arity with defaults/vararg,
## then per-argument types like real methods). True when clean;
## reports interface_mismatch and returns false otherwise. Callers
## keep existence handling (found links stay empty on failure, so the
## chain rest skips instead of cascading).
func _check_iface_call(iname: String, seg: String, fentry: Dictionary, tokens: Array, j: int, scope: Dictionary, fn: Variant, env: Dictionary, overlay: Dictionary, owner: String) -> bool:
	var line := int((tokens[j] as Dictionary).get("line", 0))
	var col := int((tokens[j] as Dictionary).get("column", 0))
	if _match_close(tokens, j + 1) < 0:
		return true
	var slices := _split_arg_slices(tokens, j + 1)
	var shape := _iface_arity(fentry)
	var req: int = shape[0]
	var total: int = shape[1]
	var vararg := bool(shape[2])
	if slices.size() < req or (not vararg and slices.size() > total):
		var want := str(req)
		if not vararg and req != total:
			want = str(req) + ".." + str(total)
		elif vararg:
			want = str(req) + "+"
		_error(ERR_INTERFACE_MISMATCH, "interface '" + iname + "' method '" + seg + "' takes " + want + " argument(s), got " + str(slices.size()), line, col, owner)
		return false
	var fpars: Array = fentry.get("params", [])
	for idx in range(mini(slices.size(), fpars.size())):
		if not (fpars[idx] is Dictionary):
			continue
		var fp: Dictionary = fpars[idx]
		var actual := _infer_arg_tree(slices[idx], scope, fn, env, overlay, owner, 0)
		var item := {"types": (fp.get("types", []) as Array).duplicate(), "any": bool(fp.get("any", false)) or ((fp.get("types", []) as Array).is_empty())}
		if _tree_arg_fits(actual, item):
			continue
		var want := "|".join(item.get("types", []))
		if str(want) == "":
			want = "dynamic"
		_error(ERR_INTERFACE_MISMATCH, "interface '" + iname + "' method '" + seg + "' argument '" + str(fp.get("name", "")) + "' expects '" + want + "', got '" + _show_tree(actual) + "'", line, col, owner)
		return false
	return true


## Interface func returns as a list ([] = void/dynamic: the chain
## rest skips, like engine void).
static func _iface_returns(fentry: Dictionary) -> Array:
	var r := str(fentry.get("returns", "any"))
	if r == "" or r == "any" or r == "void":
		return []
	var out: Array = []
	for part in r.split("|"):
		var t := str(part).strip_edges()
		if t != "":
			out.append(t)
	return out


## Finds an implemented member by name walking the class, its script
## parents and the terminal engine chain. Returns {"found", "sig",
## "static", "line"} or {"found": false}. `want` selects the table
## ("methods", "fields", "signals", "enums", "consts").
func _impl_find(owner: String, mname: String, want: String) -> Dictionary:
	var key := owner
	var seen := {}
	var guard := 0
	while guard < 64:
		guard += 1
		if seen.has(key):
			return {"found": false}
		seen[key] = true
		if _members.has(key):
			var table: Dictionary = _members[key]
			if table.has(mname):
				var rec: Dictionary = table[mname]
				var sig := _impl_sig(rec, mname, want)
				if not sig.is_empty():
					sig["line"] = int((rec.get("node", {}) as Dictionary).get("line", 0)) if (rec.get("node", {}) is Dictionary) else 0
					return sig
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
		var er := _impl_engine_find(base, mname, want)
		if bool(er.get("found", false)):
			var esig: Dictionary = er.get("sig", {})
			esig["line"] = 0
			esig["found"] = true
			return esig
		return {"found": false}
	return {"found": false}


## Main @implements pass: for every owner with recorded uses, resolve
## each name (deduped) and check all directly-declared members of the
## target against the class (own or inherited). Tuples resolve but are
## rejected (only classes, structs and interfaces can be implemented).
func _check_implements() -> void:
	for owner in _implements.keys():
		var disp := _owner_display(str(owner))
		for use in (_implements[owner] as Array):
			if not (use is Dictionary):
				continue
			var seen := {}
			for raw in ((use as Dictionary).get("names", []) as Array):
				var iname := str(raw)
				if seen.has(iname):
					continue
				seen[iname] = true
				var tgt := _implement_target(iname, str(owner))
				if tgt.is_empty():
					_error(ERR_IMPLEMENTS_UNKNOWN_TYPE, "@implements has unknown type '" + iname + "'", int((use as Dictionary).get("line", 0)), 0, str(owner))
					continue
				if str(tgt.get("kind", "")) == "tuple":
					_error(ERR_IMPLEMENTS_MISMATCH, "@implements cannot use tuple '" + iname + "' (only classes, structs and interfaces)", int((use as Dictionary).get("line", 0)), 0, str(owner))
					continue
				_check_implements_target(str(owner), disp, iname, tgt, int((use as Dictionary).get("line", 0)))


## Checks one resolved target against one class.
func _check_implements_target(owner: String, disp: String, iname: String, tgt: Dictionary, line: int) -> void:
	var req := _implement_required(tgt)
	for m in (req.get("methods", []) as Array):
		_check_implements_method(owner, disp, iname, m, line)
	for f in (req.get("fields", []) as Array):
		_check_implements_field(owner, disp, iname, f, line)
	for s in (req.get("signals", []) as Array):
		_check_implements_signal(owner, disp, iname, s, line)
	for e in (req.get("enums", []) as Array):
		_check_implements_enum(owner, disp, iname, e, line)
	for c in (req.get("consts", []) as Array):
		_check_implements_const(owner, disp, iname, c, line)


func _check_implements_method(owner: String, disp: String, iname: String, req: Dictionary, line: int) -> void:
	var mname := str(req.get("name", ""))
	var hit := _impl_find(owner, mname, "methods")
	if not bool(hit.get("found", false)):
		_error(ERR_IMPLEMENTS_MISMATCH, "class '" + disp + "' does not implement '" + iname + "." + mname + "'", line, 0, owner)
		return
	var msg := _compare_method(req, hit)
	if msg != "":
		var ln := int(hit.get("line", 0))
		if ln == 0:
			ln = line
		_error(ERR_IMPLEMENTS_MISMATCH, "class '" + disp + "' does not implement '" + iname + "." + mname + "': " + msg, ln, 0, owner)


func _check_implements_field(owner: String, disp: String, iname: String, req: Dictionary, line: int) -> void:
	var mname := str(req.get("name", ""))
	var hit := _impl_find(owner, mname, "fields")
	if not bool(hit.get("found", false)):
		_error(ERR_IMPLEMENTS_MISMATCH, "class '" + disp + "' does not implement '" + iname + "." + mname + "'", line, 0, owner)
		return
	if bool(req.get("static", false)) != bool((hit as Dictionary).get("static", false)):
		_error(ERR_IMPLEMENTS_MISMATCH, "class '" + disp + "' does not implement '" + iname + "." + mname + "': must be " + ("static" if bool(req.get("static", false)) else "an instance member"), int((hit as Dictionary).get("line", line)), 0, owner)
		return
	var rtypes: Array = req.get("types", [])
	var itypes: Array = (hit as Dictionary).get("types", [])
	if not _types_narrower(itypes, rtypes):
		_error(ERR_IMPLEMENTS_MISMATCH, "class '" + disp + "' does not implement '" + iname + "." + mname + "' (incompatible type)", int((hit as Dictionary).get("line", line)), 0, owner)


func _check_implements_signal(owner: String, disp: String, iname: String, req: Dictionary, line: int) -> void:
	var mname := str(req.get("name", ""))
	var hit := _impl_find(owner, mname, "signals")
	if not bool(hit.get("found", false)):
		_error(ERR_IMPLEMENTS_MISMATCH, "class '" + disp + "' does not implement '" + iname + "." + mname + "'", line, 0, owner)
		return
	var rpars: Array = req.get("params", [])
	var ipars: Array = (hit as Dictionary).get("params", [])
	if rpars.size() != ipars.size():
		_error(ERR_IMPLEMENTS_MISMATCH, "class '" + disp + "' does not implement '" + iname + "." + mname + "': different arity", int((hit as Dictionary).get("line", line)), 0, owner)
		return
	for i in range(rpars.size()):
		var rp: Dictionary = rpars[i]
		var ip: Dictionary = ipars[i]
		if not _types_wider((ip as Dictionary).get("types", []), (rp as Dictionary).get("types", [])):
			_error(ERR_IMPLEMENTS_MISMATCH, "class '" + disp + "' does not implement '" + iname + "." + mname + "': parameter '" + str((rp as Dictionary).get("name", "")) + "' is incompatible", int((hit as Dictionary).get("line", line)), 0, owner)
			return


func _check_implements_enum(owner: String, disp: String, iname: String, req: Dictionary, line: int) -> void:
	var mname := str(req.get("name", ""))
	var hit := _impl_find(owner, mname, "enums")
	if not bool(hit.get("found", false)):
		_error(ERR_IMPLEMENTS_MISMATCH, "class '" + disp + "' does not implement '" + iname + "." + mname + "'", line, 0, owner)
		return
	for v in (req as Dictionary).get("members", []):
		if not (str(v) in ((hit as Dictionary).get("members", []) as Array).map(func(x): return str(x))):
			_error(ERR_IMPLEMENTS_MISMATCH, "class '" + disp + "' does not implement '" + iname + "." + mname + "." + str(v) + "'", int((hit as Dictionary).get("line", line)), 0, owner)
			return


func _check_implements_const(owner: String, disp: String, iname: String, req: Dictionary, line: int) -> void:
	var mname := str(req.get("name", ""))
	var hit := _impl_find(owner, mname, "consts")
	if not bool(hit.get("found", false)):
		_error(ERR_IMPLEMENTS_MISMATCH, "class '" + disp + "' does not implement '" + iname + "." + mname + "'", line, 0, owner)
		return
	var rtypes: Array = req.get("types", [])
	var itypes: Array = (hit as Dictionary).get("types", [])
	if not _types_narrower(itypes, rtypes):
		_error(ERR_IMPLEMENTS_MISMATCH, "class '" + disp + "' does not implement '" + iname + "." + mname + "' (incompatible type)", int((hit as Dictionary).get("line", line)), 0, owner)


## Builds an impl-side signature from a member rec ({} when the kind
## does not fit the wanted table).
func _impl_sig(rec: Dictionary, mname: String, want: String) -> Dictionary:
	var kind := str(rec.get("kind", ""))
	var node: Variant = rec.get("node", {})
	if want == "methods" and kind == "function" and node is Dictionary:
		var sig := _impl_method_sig(node)
		sig["found"] = true
		return sig
	if want == "fields" and (kind == "variable" or kind == "constant") and node is Dictionary:
		var ann: Dictionary = (node as Dictionary).get("var_ann", {})
		var types: Array = []
		var any := false
		if not ann.is_empty():
			types = (ann.get("types", []) as Array).duplicate()
		else:
			var vt := _vartype_name(node)
			if vt != "":
				types = [vt]
			else:
				any = true
		return {"found": true, "types": types, "any": any, "static": bool((node as Dictionary).get("is_static", false))}
	if want == "signals" and kind == "signal" and node is Dictionary:
		var params: Array = []
		for p in (node as Dictionary).get("params", []):
			if p is Dictionary:
				var pt := _vartype_name(p)
				if pt != "":
					params.append({"name": str((p as Dictionary).get("name", "")), "types": [pt]})
				else:
					params.append({"name": str((p as Dictionary).get("name", "")), "types": []})
		return {"found": true, "params": params}
	if want == "enums" and kind == "enum" and node is Dictionary:
		var vals: Array = []
		for m in (node as Dictionary).get("members", []):
			if m is Dictionary and str((m as Dictionary).get("type", "")) == "ENUM_MEMBER":
				vals.append(str((m as Dictionary).get("name", "")))
		return {"found": true, "members": vals}
	if want == "consts" and kind == "constant" and node is Dictionary:
		var vt2 := _vartype_name(node)
		if vt2 != "":
			return {"found": true, "types": [vt2], "any": false}
		return {"found": true, "types": [], "any": true}
	return {}


## Engine-side impl lookup for one member name. Terminal base text
## only (script parents were walked by the caller).
func _impl_engine_find(base: String, mname: String, want: String) -> Dictionary:
	var ename := base
	if _engine_info(base).is_empty():
		if _engine_info(_base_simple(base)).is_empty():
			return {"found": false}
		ename = _base_simple(base)
	var chain := _engine_chain(ename)
	if chain.is_empty():
		return {"found": false}
	for link in chain:
		var info := _engine_info(str(link))
		if info.is_empty():
			continue
		if want == "methods":
			for m in info.get("instance_methods", []):
				if m is Dictionary and str((m as Dictionary).get("name", "")) == mname:
					return {"found": true, "sig": _norm_engine_method(m, false), "line": 0}
			for m in info.get("static_methods", []):
				if m is Dictionary and str((m as Dictionary).get("name", "")) == mname:
					return {"found": true, "sig": _norm_engine_method(m, true), "line": 0}
		elif want == "fields":
			for f in info.get("members", []):
				if f is Dictionary and str((f as Dictionary).get("name", "")) == mname:
					return {"found": true, "sig": {"types": [str((f as Dictionary).get("type", ""))], "any": false, "static": false}, "line": 0}
			for p in info.get("properties", []):
				if p is Dictionary and str((p as Dictionary).get("name", "")) == mname:
					return {"found": true, "sig": {"types": [str((p as Dictionary).get("type", ""))], "any": false, "static": false}, "line": 0}
		elif want == "signals":
			for s in info.get("signals", []):
				if s is Dictionary and str((s as Dictionary).get("name", "")) == mname:
					return {"found": true, "sig": _norm_engine_signal(s), "line": 0}
		elif want == "enums":
			for e in info.get("enums", []):
				if e is Dictionary and str((e as Dictionary).get("name", "")) == mname:
					var vals: Array = []
					for v in (e as Dictionary).get("values", []):
						if v is Dictionary:
							vals.append(str((v as Dictionary).get("name", "")))
					return {"found": true, "sig": {"members": vals}, "line": 0}
		elif want == "consts":
			for c in info.get("constants", []):
				if c is Dictionary and str((c as Dictionary).get("name", "")) == mname:
					return {"found": true, "sig": {"types": [], "any": true}, "line": 0}
	return {"found": false}


## Covariant check (implementations narrow): every impl type derives
## from some required type. Either side dynamic/empty passes.
func _types_narrower(impl_types: Array, req_types: Array) -> bool:
	if impl_types.is_empty() or req_types.is_empty():
		return true
	for it in impl_types:
		var ok := false
		for rt in req_types:
			if str(it) == str(rt) or _derives_from(str(it), str(rt)):
				ok = true
				break
		if not ok:
			return false
	return true


## Contravariant check (parameters widen): every required type derives
## from some implementation type. Either side dynamic/empty passes.
func _types_wider(impl_types: Array, req_types: Array) -> bool:
	if impl_types.is_empty() or req_types.is_empty():
		return true
	for rt in req_types:
		var ok := false
		for it in impl_types:
			if str(it) == str(rt) or _derives_from(str(rt), str(it)):
				ok = true
				break
		if not ok:
			return false
	return true


## Counts required and total params. Normalized entries carry "req";
## raw entries fall back to has_default/is_vararg flags.
static func _arity_of(params: Array) -> Array:
	var req := 0
	for p in params:
		if p is Dictionary:
			var d := p as Dictionary
			if d.has("req"):
				if bool(d.get("req", true)):
					req += 1
			elif not bool(d.get("has_default", false)) and not bool(d.get("is_vararg", false)):
				req += 1
	return [req, params.size()]


## Compares one required method against an implementation. Returns an
## error message or "".
func _compare_method(req: Dictionary, imp: Dictionary) -> String:
	var rname := str(req.get("name", ""))
	if bool(req.get("static", false)) != bool(imp.get("static", false)):
		return "method '" + rname + "' must be " + ("static" if bool(req.get("static", false)) else "an instance method")
	var rpars: Array = req.get("params", [])
	var ipars: Array = imp.get("params", [])
	var ra := _arity_of(rpars)
	var ia := _arity_of(ipars)
	if int(ia[0]) > int(ra[0]) or int(ia[1]) < int(ra[1]):
		return "method '" + rname + "' takes " + str(ra[0]) + ".." + str(ra[1]) + " arguments, implementation takes " + str(ia[0]) + ".." + str(ia[1])
	for i in range(rpars.size()):
		var rp: Dictionary = rpars[i]
		var ip: Dictionary = ipars[i]
		if not _types_wider((ip as Dictionary).get("types", []), (rp as Dictionary).get("types", [])):
			return "method '" + rname + "' parameter '" + str((rp as Dictionary).get("name", "")) + "' is incompatible"
	var rret := _returns_list(req.get("returns", "any"))
	var iret := _returns_list(imp.get("returns", []))
	if not _types_narrower(iret, rret):
		var want := "any"
		if not rret.is_empty():
			want = "|".join(rret)
		return "method '" + rname + "' must return '" + want + "'"
	return ""


## Required/implementation returns as a list ([] = any/dynamic).
## Accepts a "a|b" string or a [a, b] array (both shapes circulate).
static func _returns_list(v: Variant) -> Array:
	if v is Array:
		return (v as Array).duplicate()
	var r := str(v)
	if r == "" or r == "any":
		return []
	var out: Array = []
	for part in r.split("|"):
		var t := str(part).strip_edges()
		if t != "":
			out.append(t)
	return out


## Required-side returns as a list ([] = any/dynamic).
static func _ret_list(req: Dictionary) -> Array:
	return _returns_list(req.get("returns", "any"))


## Resolves an @implements name to a target (no errors here; the
## caller reports). Kinds: script (owner key), engine (type name),
## struct, interface. Tuples resolve but are rejected by callers.
func _implement_target(name: String, owner: String) -> Dictionary:
	if name == "":
		return {}
	var sk := _script_key_of(name, owner)
	if sk == "":
		sk = _script_key_of(name, "")
	if sk != "":
		return {"kind": "script", "key": sk}
	if _interfaces.has(name):
		return {"kind": "interface", "name": name}
	if _structs.has(name):
		return {"kind": "struct", "name": name}
	if _tuples.has(name):
		return {"kind": "tuple", "name": name}
	var info := _type_info(name)
	if info.is_empty():
		return {}
	var kind := str(info.get("kind", ""))
	if kind == "tuple":
		return {"kind": "tuple", "name": name}
	if kind == "struct":
		return {"kind": "struct", "name": name}
	if kind == "interface":
		return {"kind": "interface", "name": name}
	if kind == "builtin" or kind == "class" or kind == "root":
		return {"kind": "engine", "name": name}
	return {}


## Required members of a target (directly declared only, never
## inherited): {methods, fields, signals, enums, consts} with
## normalized shapes (see _impl_sig for method normalization).
func _implement_required(tgt: Dictionary) -> Dictionary:
	var out := {"methods": [], "fields": [], "signals": [], "enums": [], "consts": []}
	var kind := str(tgt.get("kind", ""))
	if kind == "script":
		var key := str(tgt.get("key", ""))
		if _members.has(key):
			for mname in (_members[key] as Dictionary).keys():
				var rec: Dictionary = (_members[key] as Dictionary)[mname]
				_sort_script_rec(rec, mname, out)
		return out
	if kind == "interface":
		var iname := str(tgt.get("name", ""))
		var spec := _iface_spec(iname)
		if spec.is_empty():
			return out
		for m in spec.get("members", []):
			_sort_iface_member(m, out)
		return out
	if kind == "struct":
		var sname := str(tgt.get("name", ""))
		var sdef := _struct_def(sname)
		if sdef.is_empty():
			return out
		for f in (sdef.get("fields", []) as Array):
			var fd: Dictionary = f
			(out["fields"] as Array).append({"name": str(fd.get("name", "")), "types": (fd.get("types", []) as Array).duplicate(), "any": bool(fd.get("any", false)), "static": false})
		return out
	if kind == "engine":
		var info := _engine_info(str(tgt.get("name", "")))
		if info.is_empty():
			return out
		for m in info.get("instance_methods", []):
			if m is Dictionary:
				(out["methods"] as Array).append(_norm_engine_method(m, false))
		for m in info.get("static_methods", []):
			if m is Dictionary:
				(out["methods"] as Array).append(_norm_engine_method(m, true))
		for s in info.get("signals", []):
			if s is Dictionary:
				(out["signals"] as Array).append(_norm_engine_signal(s))
		for e in info.get("enums", []):
			if e is Dictionary:
				var vals: Array = []
				for v in (e as Dictionary).get("values", []):
					if v is Dictionary:
						vals.append(str((v as Dictionary).get("name", "")))
				(out["enums"] as Array).append({"name": str((e as Dictionary).get("name", "")), "members": vals})
		for c in info.get("constants", []):
			if c is Dictionary:
				(out["consts"] as Array).append({"name": str((c as Dictionary).get("name", ""))})
		for p in info.get("properties", []):
			if p is Dictionary:
				(out["fields"] as Array).append({"name": str((p as Dictionary).get("name", "")), "types": [str((p as Dictionary).get("type", ""))], "any": false, "static": false})
		for mb in info.get("members", []):
			if mb is Dictionary:
				(out["fields"] as Array).append({"name": str((mb as Dictionary).get("name", "")), "types": [str((mb as Dictionary).get("type", ""))], "any": false, "static": false})
		return out
	return out


## Sorts one script member rec into the required buckets (inner
## classes are skipped: conformance over nested types is deferred).
func _sort_script_rec(rec: Dictionary, mname: String, out: Dictionary) -> void:
	var kind := str(rec.get("kind", ""))
	if kind == "function":
		var node: Variant = rec.get("node", {})
		if node is Dictionary:
			(out["methods"] as Array).append(_impl_method_sig(node))
	elif kind == "variable" or kind == "constant":
		var n: Variant = rec.get("node", {})
		var types: Array = []
		var any := false
		if n is Dictionary:
			var ann: Dictionary = (n as Dictionary).get("var_ann", {})
			if not ann.is_empty():
				types = (ann.get("types", []) as Array).duplicate()
			else:
				var vt := _vartype_name(n)
				if vt != "":
					types = [vt]
				else:
					any = true
		else:
			any = true
		(out["fields"] as Array).append({"name": mname, "types": types, "any": any, "static": bool((rec.get("node", {}) as Dictionary).get("is_static", false)) if (rec.get("node", {}) is Dictionary) else false})
	elif kind == "signal":
		var params: Array = []
		var snode: Variant = rec.get("node", {})
		if snode is Dictionary:
			for p in (snode as Dictionary).get("params", []):
				if p is Dictionary:
					var pt := _vartype_name(p)
					if pt != "":
						params.append({"name": str((p as Dictionary).get("name", "")), "types": [pt]})
					else:
						params.append({"name": str((p as Dictionary).get("name", "")), "types": []})
		(out["signals"] as Array).append({"name": mname, "params": params})
	elif kind == "enum":
		var vals: Array = []
		var enode: Variant = rec.get("node", {})
		if enode is Dictionary:
			for m in (enode as Dictionary).get("members", []):
				if m is Dictionary and str((m as Dictionary).get("type", "")) == "ENUM_MEMBER":
					vals.append(str((m as Dictionary).get("name", "")))
		(out["enums"] as Array).append({"name": mname, "members": vals})
	elif kind == "constant":
		(out["consts"] as Array).append({"name": mname})


## Sorts one interface member dict into the required buckets.
func _sort_iface_member(md: Dictionary, out: Dictionary) -> void:
	var kind := str(md.get("kind", ""))
	if kind == "func":
		var params: Array = []
		for p in (md.get("params", []) as Array):
			var pd: Dictionary = p
			params.append({"name": str(pd.get("name", "")), "types": (pd.get("types", []) as Array).duplicate(), "any": bool(pd.get("any", false)), "req": not bool(pd.get("has_default", false)) and not bool(pd.get("is_vararg", false))})
		(out["methods"] as Array).append({"name": str(md.get("name", "")), "static": bool(md.get("static", false)), "params": params, "returns": str(md.get("returns", "any"))})
	elif kind == "var":
		(out["fields"] as Array).append({"name": str(md.get("name", "")), "types": (md.get("types", []) as Array).duplicate(), "any": bool(md.get("any", false)), "static": bool(md.get("static", false))})
	elif kind == "signal":
		var sparams: Array = []
		for p in (md.get("params", []) as Array):
			var pd: Dictionary = p
			sparams.append({"name": str(pd.get("name", "")), "types": (pd.get("types", []) as Array).duplicate(), "any": bool(pd.get("any", false))})
		(out["signals"] as Array).append({"name": str(md.get("name", "")), "params": sparams})
	elif kind == "enum":
		var vals: Array = []
		for v in (md.get("members", []) as Array):
			vals.append(str((v as Dictionary).get("name", "")))
		(out["enums"] as Array).append({"name": str(md.get("name", "")), "members": vals})
	elif kind == "const":
		(out["consts"] as Array).append({"name": str(md.get("name", "")), "types": (md.get("types", []) as Array).duplicate(), "any": bool(md.get("any", false))})


## Normalized engine method entry: params with types ([] = dynamic)
## and required flags, returns string as-is.
func _norm_engine_method(md: Dictionary, is_static: bool) -> Dictionary:
	var params: Array = []
	for p in (md as Dictionary).get("params", []):
		if p is Dictionary:
			var pt := str((p as Dictionary).get("type", ""))
			var req := not bool((p as Dictionary).get("has_default", false))
			if pt != "":
				params.append({"name": str((p as Dictionary).get("name", "")), "types": [pt], "req": req})
			else:
				params.append({"name": str((p as Dictionary).get("name", "")), "types": [], "req": req})
	return {"name": str(md.get("name", "")), "static": is_static, "params": params, "returns": str(md.get("returns", ""))}


## Normalized engine signal entry.
func _norm_engine_signal(sd: Dictionary) -> Dictionary:
	var params: Array = []
	for p in (sd as Dictionary).get("params", []):
		if p is Dictionary:
			var pt := str((p as Dictionary).get("type", ""))
			if pt == "":
				params.append({"name": str((p as Dictionary).get("name", "")), "types": []})
			else:
				params.append({"name": str((p as Dictionary).get("name", "")), "types": [pt]})
	return {"name": str(sd.get("name", "")), "params": params}


## Normalized impl-side method signature from a FUNC_DECL node:
## params [{name, types, req}], returns list ([] = dynamic).
func _impl_method_sig(node: Dictionary) -> Dictionary:
	var params: Array = []
	for p in node.get("params", []):
		if p is Dictionary:
			var ann: Dictionary = (p as Dictionary).get("param_ann", {})
			var req := (p as Dictionary).get("default", null) == null
			if not ann.is_empty():
				params.append({"name": str((p as Dictionary).get("name", "")), "types": (ann.get("types", []) as Array).duplicate(), "req": req})
				continue
			var vt := _vartype_name(p)
			if vt != "":
				params.append({"name": str((p as Dictionary).get("name", "")), "types": [vt], "req": req})
			else:
				params.append({"name": str((p as Dictionary).get("name", "")), "types": [], "req": req})
	var returns: Array = []
	var arrow := _arrow_name(node.get("return_type", null))
	if arrow != "" and arrow != "void":
		returns = [arrow]
	elif arrow == "void":
		returns = ["void"]
	elif (node as Dictionary).has("return_ann"):
		returns = (((node as Dictionary).get("return_ann", {}) as Dictionary).get("types", []) as Array).duplicate()
	return {"name": str(node.get("name", "")), "static": bool(node.get("is_static", false)), "params": params, "returns": returns}


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


## Raw vartype token text (unvalidated, brackets kept) or "".
static func _vartype_text(decl: Dictionary, key := "vartype") -> String:
	var vt: Variant = decl.get(key, null)
	if not (vt is Dictionary):
		return ""
	var text := ""
	for t in (vt as Dictionary).get("tokens", []):
		if t is Dictionary:
			text += str((t as Dictionary).get("value", ""))
	return text.strip_edges()


## Validates one generic arm of a vartype tree against a @generic
## class (arity + template bounds on arguments). Unknown names are
## left to the semantic pass on purpose (no double reports).
## Returns the class key or "" (skip: non-generic, unknown, engine).
func _check_vartype_arm(head: String, args: Array, owner: String, line: int, col: int) -> String:
	var key := _script_key_of(head, owner)
	if key == "":
		if head == _script_class and head != "":
			return ""
		return ""
	var params := _class_generic(key)
	if params.is_empty():
		return ""
	if args.size() != params.size():
		_error(ERR_GENERIC_MISMATCH, "vartype '" + head + "' takes " + str(params.size()) + " type argument(s), got " + str(args.size()), line, col, owner)
		return ""
	for i in range(args.size()):
		if not (args[i] is Dictionary):
			continue
		_pending_vartype_bounds.append({"param": str(params[i]), "arg": args[i], "head": head, "line": line, "col": col, "owner": owner})
	return key


## Post-resolve pass: template bounds on vartype arguments (bounds
## resolve after the scan, so this waits like the other post passes).
func _check_pending_vartype_bounds() -> void:
	for pen in _pending_vartype_bounds:
		if not (pen is Dictionary):
			continue
		var pd: Dictionary = pen
		var bound := _template_bound_of(str(pd.get("param", "")))
		if bound.is_empty():
			continue
		var arg: Dictionary = pd.get("arg", {})
		if arg.is_empty():
			continue
		if not _template_refs(arg, _templates.keys()).is_empty():
			continue
		if not _check_bound(bound, arg):
			_error(ERR_GENERIC_MISMATCH, "type '" + _show_tree(arg) + "' for '" + str(pd.get("param", "")) + "' violates bound '" + _show_tree(bound) + "' in vartype '" + str(pd.get("head", "")) + "'", int(pd.get("line", 0)), int(pd.get("col", 0)), str(pd.get("owner", "")))


## Validates a vartype (or `->` return type) holding brackets and
## stamps node["vartype_ann"] = {head, key, args, raw, line} for the
## first generic arm over a @generic class. Anything else (simple
## names, engine generics like Array[int], unknown heads) is skipped
## silently, exactly like today.
func _mark_vartype_on(vt: Variant, node: Dictionary, owner: String) -> void:
	if not (vt is Dictionary):
		return
	var text := ""
	for t in (vt as Dictionary).get("tokens", []):
		if t is Dictionary:
			text += str((t as Dictionary).get("value", ""))
	text = text.strip_edges()
	if text == "" or (not ("[" in text) and not ("]" in text) and not ("," in text)):
		return
	var parsed := _parse_type_expr(text, "vartype")
	if not bool(parsed.get("ok", false)):
		return
	var tree: Dictionary = parsed.get("node", {})
	var arms: Array = []
	if str(tree.get("kind", "")) == "union":
		arms = (tree.get("arms", []) as Array).duplicate()
	else:
		arms = [tree]
	for arm in arms:
		if not (arm is Dictionary):
			continue
		if str((arm as Dictionary).get("kind", "")) != "generic":
			continue
		var head := str((arm as Dictionary).get("name", ""))
		var key := _check_vartype_arm(head, (arm as Dictionary).get("args", []), owner, int(node.get("line", 0)), int(node.get("column", 0)))
		if key != "":
			node["vartype_ann"] = {"head": head, "key": key, "args": ((arm as Dictionary).get("args", []) as Array).duplicate(), "raw": text, "line": int(node.get("line", 0))}
			return


## Validates a declaration vartype (VAR/CONST/PARAM nodes).
func _mark_vartype(node: Dictionary, owner: String) -> void:
	_mark_vartype_on(node.get("vartype", null), node, owner)


## Infers a variable type from a simple initializer value:
## literals, arrays, dictionaries, known-type constructors (Color(...),
## Node.new()), node paths and lambdas (Callable). "" when unknown.
## Mirrors the user's rule, not the engine: plain `=` (and missing
## values) mean Variant and are handled by the caller, never here.
func _infer_var_value(value: Variant) -> String:
	if value is Dictionary and str((value as Dictionary).get("type", "")) == "LAMBDA":
		return "Callable"
	var toks := _trim_trivia(_as_tokens(value))
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
	var nn := _split_notnull(raw_msg)
	var raw := str(nn.get("text", ""))
	if raw == "":
		return {"ok": false, "error": what + " needs a type: 'void' or a type name like 'Node' (unions join with '|', e.g. 'Object|String|int')"}
	if "[" in raw or "]" in raw or "," in raw:
		return _parse_complex_spec(raw, what, bool(nn.get("notnull", false)), bool(nn.get("nullable", false)))
	var parts := raw.split("|")
	var types: Array = []
	for p in parts:
		var name := str(p).strip_edges()
		if name == "":
			return {"ok": false, "error": what + " has an empty type in '" + raw + "'"}
		if name == "void":
			if parts.size() > 1:
				return {"ok": false, "error": what + " 'void' cannot be combined with other types in '" + raw + "'"}
			if bool(nn.get("notnull", false)):
				return {"ok": false, "error": what + " 'notnull' cannot combine with 'void'"}
			if bool(nn.get("nullable", false)):
				return {"ok": false, "error": what + " 'nullable' cannot combine with 'void'"}
			return {"ok": true, "types": [], "void": true, "raw": raw}
		if not _is_type_name(name):
			return {"ok": false, "error": what + " has an invalid type name '" + name + "'"}
		types.append(name)
	return {"ok": true, "types": types, "void": false, "raw": raw, "notnull": bool(nn.get("notnull", false)), "nullable": bool(nn.get("nullable", false))}


## Splits a trailing `notnull`/`nullable` marker off a type expression
## (whitespace-boundary match, case-sensitive): {"text", "notnull",
## "nullable"}. `# @var x Node notnull` flags the declaration;
## `Node|notnull` does NOT (that parses as an unknown union arm,
## guiding to the spelling). Both markers may co-occur in the text;
## the contradiction errors at the attach sites, not here.
static func _split_notnull(raw_msg: String) -> Dictionary:
	var s := raw_msg.strip_edges()
	if s == "notnull":
		return {"text": "", "notnull": true, "nullable": false}
	if s == "nullable":
		return {"text": "", "notnull": false, "nullable": true}
	var notnull := false
	var nullable := false
	var changed := true
	while changed:
		changed = false
		for marker in ["notnull", "nullable"]:
			if s.ends_with(marker):
				var pre := s.substr(0, s.length() - marker.length())
				if pre.ends_with(" ") or pre.ends_with("\t"):
					s = pre.strip_edges()
					changed = true
					if marker == "notnull":
						notnull = true
					else:
						nullable = true
	return {"text": s, "notnull": notnull, "nullable": nullable}


## Complex-spec route (nested type expressions with brackets): parses
## the whole text with the mini-parser, then flattens top-level union
## arms to head names for the legacy flat pipeline. Anonymous
## `tuple[...]` (no user tuple named `tuple`) desugars to `Array`;
## named generics keep their head. `void` alone stays void; `void`
## combined or a top-level `*` keep the legacy rejections.
static func _parse_complex_spec(raw: String, what: String, notnull := false, nullable := false) -> Dictionary:
	var parsed := _parse_type_expr(raw, what)
	if not bool(parsed.get("ok", false)):
		return {"ok": false, "error": str(parsed.get("error", ""))}
	var tree: Dictionary = parsed.get("node", {})
	var voids := _count_void_names(tree)
	if voids > 0:
		if voids == 1 and str(tree.get("kind", "")) == "name" and str(tree.get("name", "")) == "void":
			if notnull:
				return {"ok": false, "error": what + " 'notnull' cannot combine with 'void'"}
			if nullable:
				return {"ok": false, "error": what + " 'nullable' cannot combine with 'void'"}
			return {"ok": true, "types": [], "void": true, "raw": raw}
		return {"ok": false, "error": what + " 'void' cannot be combined with other types in '" + raw + "'"}
	var arms: Array = []
	if str(tree.get("kind", "")) == "union":
		arms = (tree.get("arms", []) as Array).duplicate()
	else:
		arms = [tree]
	var types: Array = []
	for arm in arms:
		if not (arm is Dictionary):
			return {"ok": false, "error": what + " has an invalid type in '" + raw + "'"}
		var kind := str((arm as Dictionary).get("kind", ""))
		if kind == "any":
			return {"ok": false, "error": what + " has an invalid type name '*'"}
		if kind == "name":
			types.append(str((arm as Dictionary).get("name", "")))
		elif kind == "generic":
			var hname := str((arm as Dictionary).get("name", ""))
			if hname == "tuple":
				types.append("Array")
			else:
				types.append(hname)
		else:
			return {"ok": false, "error": what + " has an invalid type in '" + raw + "'"}
	return {"ok": true, "types": types, "void": false, "raw": raw, "tree": tree, "notnull": notnull, "nullable": nullable}


## Counts `void` name leaves in a type tree (heads included).
static func _count_void_names(node: Dictionary) -> int:
	var kind := str(node.get("kind", ""))
	if kind == "name":
		return 1 if str(node.get("name", "")) == "void" else 0
	var total := 0
	if kind == "generic":
		if str(node.get("name", "")) == "void":
			total += 1
		for arg in (node.get("args", []) as Array):
			if arg is Dictionary:
				total += _count_void_names(arg)
	elif kind == "union":
		for arm in (node.get("arms", []) as Array):
			if arm is Dictionary:
				total += _count_void_names(arm)
	return total


## Short display of a type node for messages ("int", "*", "P[int,String]").
static func _show_tree(node: Dictionary) -> String:
	var kind := str(node.get("kind", ""))
	if kind == "any":
		return "*"
	if kind == "name":
		return str(node.get("name", ""))
	if kind == "union":
		var parts: Array = []
		for arm in (node.get("arms", []) as Array):
			if arm is Dictionary:
				parts.append(_show_tree(arm))
		return "|".join(parts)
	if kind == "generic":
		var parts: Array = []
		for arg in (node.get("args", []) as Array):
			if arg is Dictionary:
				parts.append(_show_tree(arg))
		return str(node.get("name", "")) + "[" + ",".join(parts) + "]"
	return "?"


## True for the anonymous-tuple head: exactly `tuple` with no user
## tuple definition under that name (user definitions win).
func _is_anon_tuple_head(hname: String) -> bool:
	return hname == "tuple" and _tuple_def("tuple").is_empty()


## Phase 1: every name in the tree resolves. {"ok": true} or
## {"ok": false, "bad": name} with the as-written name. A bare `tuple`
## name still needs a definition (legacy); only generic heads get the
## anonymous-`tuple` pass.
func _resolve_tree_names(node: Dictionary) -> Dictionary:
	return _resolve_tree_node(node)


func _resolve_tree_node(node: Dictionary) -> Dictionary:
	var kind := str(node.get("kind", ""))
	if kind == "any":
		return {"ok": true}
	if kind == "name":
		if _canon_type(str(node.get("name", ""))) == "":
			return {"ok": false, "bad": str(node.get("name", ""))}
		return {"ok": true}
	if kind == "union":
		for arm in (node.get("arms", []) as Array):
			if arm is Dictionary:
				var r := _resolve_tree_node(arm)
				if not bool(r.get("ok", false)):
					return r
		return {"ok": true}
	if kind == "generic":
		var hname := str(node.get("name", ""))
		if not _is_anon_tuple_head(hname):
			if _canon_type(hname) == "":
				return {"ok": false, "bad": hname}
		for arg in (node.get("args", []) as Array):
			if arg is Dictionary:
				var r := _resolve_tree_node(arg)
				if not bool(r.get("ok", false)):
					return r
		return {"ok": true}
	return {"ok": false, "bad": "?"}


## Head name of one applied argument for compatibility ("Array" for
## anonymous `tuple[...]`, "" for unions which callers expand).
func _tree_arg_head(node: Dictionary) -> String:
	var kind := str(node.get("kind", ""))
	if kind == "name":
		return _canon_type(str(node.get("name", "")))
	if kind == "generic":
		var hname := str(node.get("name", ""))
		if _is_anon_tuple_head(hname):
			return "Array"
		return _canon_type(hname)
	return ""


## True when one applied argument fits a tuple definition item
## ({types, any}): `*` and any-items fit all; unions need every arm;
## otherwise the head must equal or derive from an item member.
func _tree_arg_fits(arg: Dictionary, item: Dictionary) -> bool:
	if bool(item.get("any", false)):
		return true
	if str(arg.get("kind", "")) == "any":
		return true
	if str(arg.get("kind", "")) == "union":
		for arm in (arg.get("arms", []) as Array):
			if not (arm is Dictionary) or not _tree_arg_fits(arm, item):
				return false
		return true
	var head := _tree_arg_head(arg)
	if head == "":
		return false
	for m in (item.get("types", []) as Array):
		if head == str(m) or _derives_from(head, str(m)):
			return true
	return false


## Phase 2: generic applications of known @tuple types match the
## definition (arity + per-argument compatibility, recursing into
## nested applications). {"ok": true} or {"ok": false, "mismatch": msg}.
func _check_tree_tuples(node: Dictionary) -> Dictionary:
	var kind := str(node.get("kind", ""))
	if kind == "union":
		for arm in (node.get("arms", []) as Array):
			if arm is Dictionary:
				var r := _check_tree_tuples(arm)
				if not bool(r.get("ok", false)):
					return r
		return {"ok": true}
	if kind != "generic":
		return {"ok": true}
	var hname := str(node.get("name", ""))
	var args: Array = node.get("args", [])
	var def := _tuple_def(hname)
	if not def.is_empty() and not _is_anon_tuple_head(hname):
		var items: Array = def.get("items", [])
		if args.size() != int(def.get("size", -1)):
			return {"ok": false, "mismatch": "tuple '" + hname + "' expects " + str(def.get("size", 0)) + " type arguments, got " + str(args.size())}
		for i in range(args.size()):
			var arg: Dictionary = args[i]
			var item: Dictionary = items[i]
			if not _tree_arg_fits(arg, item):
				return {"ok": false, "mismatch": "tuple '" + hname + "' argument " + str(i) + " expects '" + _show_types(item.get("types", [])) + "', got '" + _show_tree(arg) + "'"}
	for arg in args:
		if arg is Dictionary:
			var r := _check_tree_tuples(arg)
			if not bool(r.get("ok", false)):
				return r
	return {"ok": true}


## Full tree validation: names resolve, then tuple applications fit.
## {"ok": true} or {"ok": false, "bad": name} (unknown) or
## {"ok": false, "mismatch": msg} (tuple arity/compatibility).
## NOTE: only the post-resolve passes may call this whole (definitions
## must be resolved first); attach-time callers use _resolve_tree_names
## plus _pending_tree_checks instead.
func _validate_type_tree(tree: Dictionary) -> Dictionary:
	var rn := _resolve_tree_names(tree)
	if not bool(rn.get("ok", false)):
		return rn
	return _check_tree_tuples(tree)


## Reports tree errors for one complex spec (specs without "tree" pass
## through). Name resolution runs now (unknown names error with
## unk_kind immediately); tuple arity/compatibility needs resolved
## definitions, so it is queued for _check_pending_trees (post-resolve)
## and reported with mm_kind there. Returns false when an error was
## reported now.
func _report_tree_errors(spec: Dictionary, unk_kind: String, mm_kind: String, what: String, line: int, col: int, owner: String) -> bool:
	if not spec.has("tree"):
		return true
	var tree: Dictionary = spec.get("tree", {})
	var rn := _resolve_tree_names(tree)
	if not bool(rn.get("ok", false)):
		_error(unk_kind, what + " has unknown type '" + str(rn.get("bad", "")) + "'", line, col, owner)
		return false
	_pending_tree_checks.append({"tree": tree, "mm_kind": mm_kind, "what": what, "line": line, "col": col, "owner": owner})
	return true


## Post-resolve pass: tuple applications queued by _report_tree_errors
## (attach runs before _resolve_tuples, when definitions are still
## raw, so arity/compatibility waits until here). Alias leaves expand
## first, so applications through aliases validate transparently.
func _check_pending_trees() -> void:
	for pen in _pending_tree_checks:
		if not (pen is Dictionary):
			continue
		var tree: Dictionary = (pen as Dictionary).get("tree", {})
		var exp := _expand_tree_aliases(tree)
		if bool(exp.get("ok", false)):
			tree = exp.get("node", {})
		var tv := _check_tree_tuples(tree)
		if not bool(tv.get("ok", false)):
			_error(str((pen as Dictionary).get("mm_kind", "")), str((pen as Dictionary).get("what", "")) + " " + str(tv.get("mismatch", "")), int((pen as Dictionary).get("line", 0)), int((pen as Dictionary).get("col", 0)), str((pen as Dictionary).get("owner", "")))


## Cap on nested type-expression depth (tuple[A,[B,...]]): purely
## against pathological inputs; real annotations never get close.
const MAX_TYPE_DEPTH := 32


## Parses one nested type expression ("int|tuple[int]|Dictionary[K,V]")
## into {"ok","node"} or {"ok": false, "error"}. Nodes: {"kind":"any"}
## (`*`), {"kind":"name","name"}, {"kind":"union","arms":[...]},
## {"kind":"generic","name","args":[...]}. Whitespace is tolerated
## between tokens; `|` splits at the current bracket level, `,` splits
## generic args. `void` parses as a plain name: callers apply their own
## void rules on top. Pure (no errors reported, no state touched).
static func _parse_type_expr(text: String, what := "@var") -> Dictionary:
	var res := _parse_type_union(text, 0, 0, what)
	if not bool(res.get("ok", false)):
		return res
	var pos := int(res.get("pos", 0))
	pos = _skip_type_ws(text, pos)
	if pos != text.length():
		return {"ok": false, "error": what + " has an unexpected '" + text.substr(pos, 1) + "' in '" + text.strip_edges() + "'"}
	return {"ok": true, "node": res.get("node", {})}


## Skips spaces/tabs/newlines, returning the new position.
static func _skip_type_ws(s: String, pos: int) -> int:
	var p := pos
	while p < s.length():
		var c := s.unicode_at(p)
		if c != 32 and c != 9 and c != 10 and c != 13:
			break
		p += 1
	return p


## Parses one union arm level: primary ("|" primary)*. Returns
## {"ok","node","pos"}; a single arm is returned unwrapped.
static func _parse_type_union(s: String, pos: int, depth: int, what: String) -> Dictionary:
	if depth > MAX_TYPE_DEPTH:
		return {"ok": false, "error": what + " type is nested too deep in '" + s.strip_edges() + "'"}
	var p := _skip_type_ws(s, pos)
	var first := _parse_type_primary(s, p, depth, what)
	if not bool(first.get("ok", false)):
		return first
	var arms: Array = [first.get("node", {})]
	p = int(first.get("pos", p))
	while true:
		p = _skip_type_ws(s, p)
		if p >= s.length() or s.unicode_at(p) != 124:
			break
		p = _skip_type_ws(s, p + 1)
		if p >= s.length():
			return {"ok": false, "error": what + " has an empty type after '|' in '" + s.strip_edges() + "'"}
		if s.unicode_at(p) == 124 or s.unicode_at(p) == 44 or s.unicode_at(p) == 93:
			return {"ok": false, "error": what + " has an empty type after '|' in '" + s.strip_edges() + "'"}
		var arm := _parse_type_primary(s, p, depth, what)
		if not bool(arm.get("ok", false)):
			return arm
		arms.append(arm.get("node", {}))
		p = int(arm.get("pos", p))
	if arms.size() == 1:
		return {"ok": true, "node": arms[0], "pos": p}
	return {"ok": true, "node": {"kind": "union", "arms": arms}, "pos": p}


## Parses one primary: `*` (any), an identifier, or an identifier
## followed by "[args]". Returns {"ok","node","pos"}.
static func _parse_type_primary(s: String, pos: int, depth: int, what: String) -> Dictionary:
	var raw := s.strip_edges()
	var p := _skip_type_ws(s, pos)
	if p >= s.length():
		return {"ok": false, "error": what + " has an empty type in '" + raw + "'"}
	var c := s.unicode_at(p)
	if c == 42:
		return {"ok": true, "node": {"kind": "any"}, "pos": p + 1}
	if c == 124 or c == 44 or c == 93:
		return {"ok": false, "error": what + " has an empty type in '" + raw + "'"}
	if not _is_type_start(c):
		return {"ok": false, "error": what + " has an invalid character '" + s.substr(p, 1) + "' in '" + raw + "'"}
	var name := ""
	while p < s.length() and _is_type_part(s.unicode_at(p)):
		name += s.substr(p, 1)
		p += 1
	p = _skip_type_ws(s, p)
	if p >= s.length() or s.unicode_at(p) != 91:
		return {"ok": true, "node": {"kind": "name", "name": name}, "pos": p}
	p = _skip_type_ws(s, p + 1)
	if p < s.length() and s.unicode_at(p) == 93:
		return {"ok": false, "error": what + " has no type arguments in '" + name + "[]'"}
	var args: Array = []
	while true:
		var arg := _parse_type_union(s, p, depth + 1, what)
		if not bool(arg.get("ok", false)):
			return arg
		args.append(arg.get("node", {}))
		p = _skip_type_ws(s, int(arg.get("pos", p)))
		if p < s.length() and s.unicode_at(p) == 44:
			p = _skip_type_ws(s, p + 1)
			if p >= s.length() or s.unicode_at(p) == 93:
				return {"ok": false, "error": what + " has an empty type after ',' in '" + raw + "'"}
			continue
		break
	if p >= s.length() or s.unicode_at(p) != 93:
		return {"ok": false, "error": what + " is missing ']' in '" + raw + "'"}
	return {"ok": true, "node": {"kind": "generic", "name": name, "args": args}, "pos": p + 1}


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
	var out := {"ok": true, "name": vname, "types": spec.get("types", []), "raw": str(spec.get("raw", "")), "notnull": bool(spec.get("notnull", false)), "nullable": bool(spec.get("nullable", false))}
	if (spec as Dictionary).has("tree"):
		out["tree"] = (spec as Dictionary).get("tree", {})
	return out


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


## True when a data-dir JSON file exists for the name (builtin, classes or
## user under _write_base). Results are cached per analyze() call.
func _type_file_exists(tname: String) -> bool:
	return not _type_info(tname).is_empty()


## inheritance_chain of a type from its JSON file ([] when unknown).
func _engine_chain(tname: String) -> Array:
	var chain: Array = _type_info(tname).get("inheritance_chain", [])
	return chain


## A @return member is known when it is the script class, a script class
## or enum member, a roster-known global script class, or a data-dir
## JSON file exists for it.
func _type_known(tname: String) -> bool:
	if tname == "null":
		return true
	if tname != "" and tname == _script_class:
		return true
	if _tuples.has(tname):
		return true
	if _templates.has(tname):
		return true
	if _aliases.has(tname):
		return true
	if _structs.has(tname):
		return true
	if _interfaces.has(tname):
		return true
	for key in _members.keys():
		var table: Dictionary = _members[key]
		if table.has(tname) and str((table[tname] as Dictionary).get("kind", "")) in ["class", "enum"]:
			return true
	if _roster_has(tname):
		return true
	if not _roster_swept and _project_root != "":
		_roster_swept = true
		var swept := _roster_scan_files(_project_root)
		for k in swept.keys():
			if not _roster_names.has(k):
				_roster_names[k] = swept[k]
		if _roster_has(tname):
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


## True for a @tuple name (declared or on disk). Presence-based, so it
## works before _resolve_tuples (attach-time narrowing needs it).
func _is_tuple_name(nm: String) -> bool:
	if nm != "" and _tuples.has(nm):
		return true
	var info := _type_info(nm)
	return not info.is_empty() and str(info.get("kind", "")) == "tuple"


## True for a @struct name (declared or on disk). Same order-free deal.
func _is_struct_name(nm: String) -> bool:
	if nm != "" and _structs.has(nm):
		return true
	var info := _type_info(nm)
	return not info.is_empty() and str(info.get("kind", "")) == "struct"


## True for an @alias name (declared or on disk). Aliases never work
## as vartypes either (semantic resolves their JSON, so without this
## the misuse would pass silently).
func _is_alias_name(nm: String) -> bool:
	if nm != "" and _aliases.has(nm):
		return true
	var info := _type_info(nm)
	return not info.is_empty() and str(info.get("kind", "")) == "alias"


## True for an @interface name (resolved in-memory or same-kind
## JSON on disk). Order-free like the tuple/struct twins.
func _is_interface_name(nm: String) -> bool:
	if nm == "":
		return false
	if _interfaces.has(nm):
		return true
	var info := _type_info(nm)
	return not info.is_empty() and str(info.get("kind", "")) == "interface"


## True when a name is virtual (tuple/struct/alias/interface):
## annotation-only types that can never appear as a declared GDScript
## type (vartypes, `->` arrows, base classes).
func _is_virtual_name(nm: String) -> bool:
	return _is_tuple_name(nm) or _is_struct_name(nm) or _is_alias_name(nm) or _is_interface_name(nm)


## Head type name of a vartype (before any brackets), "" when absent
## or not a plain identifier (dotted paths stay lenient, like today).
static func _vartype_head(node: Dictionary, key := "vartype") -> String:
	var vt: Variant = node.get(key, null)
	if not (vt is Dictionary):
		return ""
	var text := ""
	for t in (vt as Dictionary).get("tokens", []):
		if t is Dictionary:
			text += str((t as Dictionary).get("value", ""))
	text = text.strip_edges()
	var bi := text.find("[")
	if bi >= 0:
		text = text.substr(0, bi).strip_edges()
	if text == "" or not _is_type_name(text):
		return ""
	return text


## Flags virtual types used as declared types (vartypes and `->`
## arrows): tuples, structs and aliases only refine Array/Dictionary/
## Variant through @var/@param/@return. Interfaces stay lenient
## (documented asymmetry: their README section blesses vartype use).
func _mark_virtual_vartype(node: Dictionary, owner: String) -> void:
	var head := _vartype_head(node)
	if head != "" and _is_virtual_name(head):
		_error(ERR_VIRTUAL_VARTYPE, "virtual type '" + head + "' cannot be used as a declared type (refine Array/Dictionary/Variant with @var/@param/@return instead)", int(node.get("line", 0)), int(node.get("column", 0)), owner)
	var rhead := _vartype_head(node, "return_type")
	if rhead != "" and _is_virtual_name(rhead):
		_error(ERR_VIRTUAL_VARTYPE, "virtual type '" + rhead + "' cannot be used as a declared type (refine Array/Dictionary/Variant with @var/@param/@return instead)", int(node.get("line", 0)), int(node.get("column", 0)), owner)


## True when an annotation member fits a declared reference: equal,
## derived, a nominal tuple/struct against its Array/Dictionary root
## (tuples ARE fixed-shape arrays, structs ARE fixed-key
## dictionaries), or a known interface (contracts refine capabilities,
## never the nominal type, so they always pass narrowing).
func _nominal_compat(member: String, ref: String) -> bool:
	if member == "null":
		return _null_fits(ref)
	if member == ref or _derives_from(member, ref):
		return true
	if _opaque_script(member) or _opaque_script(ref):
		return true
	if ref == "Array" and _is_tuple_name(member):
		return true
	if ref == "Dictionary" and _is_struct_name(member):
		return true
	if _is_interface_name(member):
		return true
	return false


## Nil assignability: null flows into Object-derived types, Variant
## and dynamic slots only (mirrors Godot, which rejects null for
## value types, arrays and dictionaries at parse time).
func _null_fits(ref: String) -> bool:
	if ref == "" or ref == "Variant" or ref == "dynamic" or ref == "null":
		return true
	return _is_object_like(ref)


## True for definitely-Object types (engine classes, script classes,
## interfaces): only then does truthiness imply non-null (`not []` is
## emptiness, `not false` is boolean logic, so those stay out).
func _is_object_like(h: String) -> bool:
	if h == "" or h == "Variant" or h == "dynamic" or h == "null":
		return false
	var einfo := _engine_info(h)
	if not einfo.is_empty():
		return str(einfo.get("kind", "")) == "class"
	if h == _script_class and h != "":
		return true
	if not _iface_spec(h).is_empty():
		return true
	return str(_type_info(h).get("kind", "")) == "script"


func _script_derives(child: String, ancestor: String) -> bool:
	var key := _resolve_private_owner(child, "")
	var seen := {}
	var guard := 0
	while key != "" and not seen.has(key) and guard < 32:
		seen[key] = true
		guard += 1
		var base := str(_class_extends.get(key, ""))
		if base == "":
			break
		if base == ancestor or _base_simple(base) == ancestor:
			return true
		if ancestor in _engine_chain(_base_simple(base)):
			return true
		key = _resolve_private_owner(base, key)
	return _script_derives_json(child, ancestor, {})


## Cross-file derivation through user JSON extends chains (recorded
## per file by the writers). Engine pairs keep the old behavior
## exactly (only script infos walk here). Seen-guarded; on-demand
## analysis fills missing files within the shared depth cap.
func _script_derives_json(child: String, ancestor: String, seen: Dictionary) -> bool:
	if child == "" or ancestor == "" or seen.has(child):
		return false
	seen[child] = true
	var info := _ensure_script_info(child)
	if info.is_empty() or str(info.get("kind", "")) != "script":
		return false
	var base := str(info.get("extends", ""))
	if base == "":
		return false
	var simple := _base_simple(base)
	if simple == ancestor or base == ancestor:
		return true
	if ancestor in _engine_chain(simple):
		return true
	return _script_derives_json(simple, ancestor, seen)


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
		var cm := _canon_members(spec)
		if not bool(cm.get("ok", false)):
			_error(ERR_RETURN_UNKNOWN, "@return has unknown type '" + str(cm.get("bad", "")) + "'", line, col, owner)
			return
		var rebuilt := {"ok": true, "types": cm.get("types", []), "void": false, "raw": str(spec.get("raw", "")), "line": line, "notnull": bool(spec.get("notnull", false)), "nullable": bool(spec.get("nullable", false))}
		if (spec as Dictionary).has("tree"):
			rebuilt["tree"] = (spec as Dictionary).get("tree", {})
		spec = rebuilt
	if not _report_tree_errors(spec, ERR_RETURN_UNKNOWN, ERR_RETURN_MISMATCH, "@return", line, col, owner):
		return
	var notnull_clash := _check_notnull_clash("@return", ERR_RETURN_MALFORMED, spec, spec.get("types", []), line, col, owner)
	var policy_clash := _check_nullpolicy_clash("@return", ERR_RETURN_MALFORMED, spec, spec.get("types", []), line, col, owner)
	var ret_clash := notnull_clash or policy_clash
	fn_node["return_ann"] = {"types": spec.get("types", []), "void": bool(spec.get("void", false)), "raw": str(spec.get("raw", "")), "line": line}
	if (spec as Dictionary).has("tree"):
		(fn_node["return_ann"] as Dictionary)["tree"] = (spec as Dictionary).get("tree", {})
	if bool(spec.get("notnull", false)) and not ret_clash:
		(fn_node["return_ann"] as Dictionary)["notnull"] = true
	if bool(spec.get("nullable", false)) and not ret_clash:
		(fn_node["return_ann"] as Dictionary)["nullable"] = true


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
	var cm := _canon_members(spec)
	if not bool(cm.get("ok", false)):
		_error(ERR_VAR_UNKNOWN_TYPE, "@var has unknown type '" + str(cm.get("bad", "")) + "'", line, col, owner)
		return
	if not _report_tree_errors(spec, ERR_VAR_UNKNOWN_TYPE, ERR_VAR_MISMATCH, "@var", line, col, owner):
		return
	var members: Array = cm.get("types", [])
	var ref := _var_reference(decl_node, is_const)
	if ref != "" and ref != "Variant" and ref != "dynamic":
		for m in members:
			if _aliases.has(str(m)) or not _alias_def(str(m)).is_empty():
				_pending_alias_narrows.append({"member": str(m), "ref": ref, "label": vname, "line": line, "col": col, "owner": owner, "pkind": "var"})
				continue
			if not _nominal_compat(str(m), ref):
				_error(ERR_VAR_MISMATCH, "cannot use @var type '" + str(m) + "' for variable '" + vname + "' declared as '" + ref + "' ('" + str(m) + "' is neither '" + ref + "' nor a subclass of it)", line, col, owner)
	var notnull_clash := _check_notnull_clash("@var", ERR_VAR_MALFORMED, spec, members, line, col, owner)
	var policy_clash := _check_nullpolicy_clash("@var", ERR_VAR_MALFORMED, spec, members, line, col, owner)
	var vclash := notnull_clash or policy_clash
	if bool(spec.get("notnull", false)) and not vclash and _value_is_bare_null(decl_node.get("value", null)):
		_error(ERR_VAR_NOTNULL, "cannot assign null to notnull variable '" + vname + "'", line, col, owner)
	decl_node["var_ann"] = {"name": vname, "types": members, "raw": str(spec.get("raw", "")), "line": line}
	if (spec as Dictionary).has("tree"):
		(decl_node["var_ann"] as Dictionary)["tree"] = (spec as Dictionary).get("tree", {})
	if bool(spec.get("notnull", false)) and not vclash:
		(decl_node["var_ann"] as Dictionary)["notnull"] = true
	if bool(spec.get("nullable", false)) and not vclash:
		(decl_node["var_ann"] as Dictionary)["nullable"] = true
	_queue_notnull_aliases(spec, members, "@var", ERR_VAR_MALFORMED, line, col, owner, decl_node.get("var_ann", {}), vclash)


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
	var cm := _canon_members(spec)
	if not bool(cm.get("ok", false)):
		_error(ERR_VAR_UNKNOWN_TYPE, "@var has unknown type '" + str(cm.get("bad", "")) + "'", line, 0, owner)
		return
	var members: Array = cm.get("types", [])
	var ref := ""
	var tnode: Dictionary = target.get("node", {})
	if bool(target.get("is_param", false)):
		ref = _vartype_name(tnode)
	elif not tnode.is_empty():
		ref = _var_reference(tnode, bool(target.get("is_const", false)))
	if ref != "" and ref != "Variant" and ref != "dynamic":
		for m in members:
			if not _nominal_compat(str(m), ref):
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
## compatibility first, then value/bare/null return presence. No-op
## without a recorded return_ann. Takes Variant: statement values may
## be null.
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
			var atypes: Array = []
			for m in ann.get("types", []):
				if _aliases.has(str(m)) or not _alias_def(str(m)).is_empty():
					var adef := _alias_def(str(m))
					if not adef.is_empty():
						var aexp := _expand_tree_aliases(adef.get("tree", {}))
						if bool(aexp.get("ok", false)):
							for ah in _tree_top_heads(aexp.get("node", {})):
								atypes.append(str(ah))
							continue
				atypes.append(str(m))
			for m in atypes:
				if not _nominal_compat(str(m), arrow):
					_error(ERR_RETURN_MISMATCH, "cannot use @return '" + str(m) + "' with '-> " + arrow + "' on function " + disp + " ('" + str(m) + "' is neither '" + arrow + "' nor a subclass of it)", int(fn.get("line", 0)), int(fn.get("column", 0)), owner)
	var rets := _collect_returns(fn.get("body", null))
	if ann_void:
		for r in rets:
			if (r as Dictionary).get("value", null) != null:
				_error(ERR_RETURN_VALUE, "cannot return a value from void function " + disp, int((r as Dictionary).get("line", 0)), int((r as Dictionary).get("column", 0)), owner)
	else:
		var expect := str(ann.get("raw", ""))
		var notnull_ret := bool(ann.get("notnull", false))
		for r in rets:
			if (r as Dictionary).get("value", null) == null:
				_error(ERR_RETURN_VALUE, "bare return in non-void function " + disp + " (expects '" + expect + "')", int((r as Dictionary).get("line", 0)), int((r as Dictionary).get("column", 0)), owner)
			elif notnull_ret and _value_is_bare_null((r as Dictionary).get("value", null)):
				_error(ERR_RETURN_NOTNULL, "cannot return null from notnull function " + disp, int((r as Dictionary).get("line", 0)), int((r as Dictionary).get("column", 0)), owner)


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
		# Function-local vars/consts are not members: scopes own them
		# (bindings are pre-collected, so member fallback never fires
		# for them). Recording them here leaked locals into member
		# tables, user JSONs and cross-script lookups, and a shadowing
		# local even clobbered its member record. Other decl kinds
		# (local classes included) keep today's behavior.
		if member_pos or (t != "VAR_DECL" and t != "CONST_DECL"):
			_mark_decl(d, owner)
		if member_pos:
			_mark_private(d, owner)
		elif _has_any_private_tag(d):
			_error(ERR_PRIVATE_MISPLACED, "@private must precede a member declaration (variable, function, class, enum, constant or signal) inside a class body", int(d.get("line", 0)), int(d.get("column", 0)), owner)
		if t == "FUNC_DECL":
			_mark_return_func(d, owner)
			_mark_vartype_on(d.get("return_type", null), d, owner)
			_mark_virtual_vartype(d, owner)
		elif _has_any_return_tag(d):
			if t == "VAR_DECL" or t == "CONST_DECL":
				_mark_return_stmt(d, d.get("value", null), owner)
			else:
				_error(ERR_RETURN_MISPLACED, "@return can only precede a function or lambda declaration", int(d.get("line", 0)), int(d.get("column", 0)), owner)
		if t == "VAR_DECL" or t == "CONST_DECL":
			_mark_var_decl(d, owner)
			_mark_vartype(d, owner)
			_mark_virtual_vartype(d, owner)
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
		if _has_any_alias_tag(d) and not (member_pos and owner == ""):
			_error(ERR_ALIAS_MISPLACED, "@alias definitions belong at the top level of the script", int(d.get("line", 0)), int(d.get("column", 0)), owner)
		if _has_any_template_tag(d) and not (member_pos and owner == ""):
			_error(ERR_TEMPLATE_MISPLACED, "@template definitions belong at the top level of the script", int(d.get("line", 0)), int(d.get("column", 0)), owner)
		if _has_any_struct_tag(d) and not (member_pos and owner == ""):
			_error(ERR_STRUCT_MISPLACED, "@struct definitions belong at the top level of the script", int(d.get("line", 0)), int(d.get("column", 0)), owner)
		if _has_any_interface_tag(d) and not (member_pos and owner == ""):
			_error(ERR_INTERFACE_MISPLACED, "@interface definitions belong at the top level of the script", int(d.get("line", 0)), int(d.get("column", 0)), owner)
		if _has_any_implements_tag(d):
			if t == "CLASS_DECL":
				_record_implements(_full_name(owner, str(d.get("name", ""))), d, int(d.get("line", 0)))
			elif member_pos and owner == "":
				_record_implements("", d, int(d.get("line", 0)))
			else:
				_error(ERR_IMPLEMENTS_MISPLACED, "@implements can only precede a class declaration or sit at the script root", int(d.get("line", 0)), int(d.get("column", 0)), owner)
		if _has_any_generic_tag(d):
			if t == "CLASS_DECL" and member_pos:
				_mark_generic_class(d, owner)
			else:
				_error(ERR_GENERIC_MISPLACED, "@generic belongs immediately before a class declaration", int(d.get("line", 0)), int(d.get("column", 0)), owner)
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
		if _has_any_alias_tag(d) and not (member_pos and owner == ""):
			_error(ERR_ALIAS_MISPLACED, "@alias definitions belong at the top level of the script", int(d.get("line", 0)), int(d.get("column", 0)), owner)
		if _has_any_template_tag(d) and not (member_pos and owner == ""):
			_error(ERR_TEMPLATE_MISPLACED, "@template definitions belong at the top level of the script", int(d.get("line", 0)), int(d.get("column", 0)), owner)
		if _has_any_struct_tag(d) and not (member_pos and owner == ""):
			_error(ERR_STRUCT_MISPLACED, "@struct definitions belong at the top level of the script", int(d.get("line", 0)), int(d.get("column", 0)), owner)
		if _has_any_interface_tag(d) and not (member_pos and owner == ""):
			_error(ERR_INTERFACE_MISPLACED, "@interface definitions belong at the top level of the script", int(d.get("line", 0)), int(d.get("column", 0)), owner)
		if _has_any_generic_tag(d):
			_error(ERR_GENERIC_MISPLACED, "@generic belongs immediately before a class declaration", int(d.get("line", 0)), int(d.get("column", 0)), owner)
		if _has_any_implements_tag(d):
			_record_implements("", d, int(d.get("line", 0)))
		return
	if t == "PARAM":
		var ptag = _leading_tag(d)
		if not ptag.is_empty():
			_error(ERR_DEPRECATED_UNSUPPORTED, "@deprecated on function parameters is not supported yet", int(d.get("line", 0)), int(d.get("column", 0)), owner)
		_mark_vartype(d, owner)
		_mark_virtual_vartype(d, owner)
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
		if _has_any_alias_tag(d):
			_error(ERR_ALIAS_MISPLACED, "@alias definitions belong at the top level of the script", int(d.get("line", 0)), int(d.get("column", 0)), owner)
		if _has_any_template_tag(d):
			_error(ERR_TEMPLATE_MISPLACED, "@template definitions belong at the top level of the script", int(d.get("line", 0)), int(d.get("column", 0)), owner)
		if _has_any_generic_tag(d):
			_error(ERR_GENERIC_MISPLACED, "@generic belongs immediately before a class declaration", int(d.get("line", 0)), int(d.get("column", 0)), owner)
		if _has_any_struct_tag(d):
			_error(ERR_STRUCT_MISPLACED, "@struct definitions belong at the top level of the script", int(d.get("line", 0)), int(d.get("column", 0)), owner)
		if _has_any_interface_tag(d):
			_error(ERR_INTERFACE_MISPLACED, "@interface definitions belong at the top level of the script", int(d.get("line", 0)), int(d.get("column", 0)), owner)
		if _has_any_implements_tag(d):
			_error(ERR_IMPLEMENTS_MISPLACED, "@implements can only precede a class declaration or sit at the script root", int(d.get("line", 0)), int(d.get("column", 0)), owner)
		return
	if t == "LAMBDA" or t == "ACCESSOR":
		if t == "LAMBDA":
			_mark_virtual_vartype(d, owner)
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
		if _has_any_alias_tag(d):
			_error(ERR_ALIAS_MISPLACED, "@alias definitions belong at the top level of the script", int(d.get("line", 0)), int(d.get("column", 0)), owner)
		if _has_any_template_tag(d):
			_error(ERR_TEMPLATE_MISPLACED, "@template definitions belong at the top level of the script", int(d.get("line", 0)), int(d.get("column", 0)), owner)
			return
		if _has_any_generic_tag(d):
			_error(ERR_GENERIC_MISPLACED, "@generic belongs immediately before a class declaration", int(d.get("line", 0)), int(d.get("column", 0)), owner)
			return
		if _has_any_struct_tag(d):
			_error(ERR_STRUCT_MISPLACED, "@struct definitions belong at the top level of the script", int(d.get("line", 0)), int(d.get("column", 0)), owner)
			return
		if _has_any_interface_tag(d):
			_error(ERR_INTERFACE_MISPLACED, "@interface definitions belong at the top level of the script", int(d.get("line", 0)), int(d.get("column", 0)), owner)
			return
		if _has_any_implements_tag(d):
			_error(ERR_IMPLEMENTS_MISPLACED, "@implements can only precede a class declaration or sit at the script root", int(d.get("line", 0)), int(d.get("column", 0)), owner)
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
		if t == "TYPE_INFO" and not member_pos and not _has_alias_tag(d).is_empty():
			_error(ERR_ALIAS_MISPLACED, "@alias definitions belong at the top level of the script", int(d.get("line", 0)), int(d.get("column", 0)), owner)
		if t == "TYPE_INFO" and not member_pos and not _has_template_tag(d).is_empty():
			_error(ERR_TEMPLATE_MISPLACED, "@template definitions belong at the top level of the script", int(d.get("line", 0)), int(d.get("column", 0)), owner)
		if t == "TYPE_INFO" and not _has_generic_tag(d).is_empty():
			_error(ERR_GENERIC_MISPLACED, "@generic belongs immediately before a class declaration", int(d.get("line", 0)), int(d.get("column", 0)), owner)
		if t == "TYPE_INFO" and not member_pos and not _has_struct_tag(d).is_empty():
			_error(ERR_STRUCT_MISPLACED, "@struct definitions belong at the top level of the script", int(d.get("line", 0)), int(d.get("column", 0)), owner)
		if t == "TYPE_INFO" and not member_pos and not _has_interface_tag(d).is_empty():
			_error(ERR_INTERFACE_MISPLACED, "@interface definitions belong at the top level of the script", int(d.get("line", 0)), int(d.get("column", 0)), owner)
		if t == "TYPE_INFO" and not _has_implements_tag(d).is_empty():
			if member_pos and owner == "":
				_record_implements_tok("", d)
			else:
				_error(ERR_IMPLEMENTS_MISPLACED, "@implements can only precede a class declaration or sit at the script root", int(d.get("line", 0)), int(d.get("column", 0)), owner)
		return
	if _has_any_tuple_tag(d):
		if not (member_pos and owner == ""):
			_error(ERR_TUPLE_MISPLACED, "@tuple definitions belong at the top level of the script", int(d.get("line", 0)), int(d.get("column", 0)), owner)
			return
		# Top level: already collected by _prescan_tuples; falls through.
	if _has_any_alias_tag(d):
		if not (member_pos and owner == ""):
			_error(ERR_ALIAS_MISPLACED, "@alias definitions belong at the top level of the script", int(d.get("line", 0)), int(d.get("column", 0)), owner)
			return
		# Top level: already collected by _prescan_aliases; falls through.
	if _has_any_template_tag(d):
		if not (member_pos and owner == ""):
			_error(ERR_TEMPLATE_MISPLACED, "@template definitions belong at the top level of the script", int(d.get("line", 0)), int(d.get("column", 0)), owner)
			return
		# Top level: already collected by _prescan_templates; falls through.
	if _has_any_generic_tag(d):
		_error(ERR_GENERIC_MISPLACED, "@generic belongs immediately before a class declaration", int(d.get("line", 0)), int(d.get("column", 0)), owner)
		return
	if _has_any_struct_tag(d):
		if not (member_pos and owner == ""):
			_error(ERR_STRUCT_MISPLACED, "@struct definitions belong at the top level of the script", int(d.get("line", 0)), int(d.get("column", 0)), owner)
			return
		# Top level: already collected by _prescan_structs; falls through.
	if _has_any_interface_tag(d):
		if not (member_pos and owner == ""):
			_error(ERR_INTERFACE_MISPLACED, "@interface definitions belong at the top level of the script", int(d.get("line", 0)), int(d.get("column", 0)), owner)
			return
		# Top level: already collected by _prescan_interfaces; falls through.
	if _has_any_implements_tag(d):
		_error(ERR_IMPLEMENTS_MISPLACED, "@implements can only precede a class declaration or sit at the script root", int(d.get("line", 0)), int(d.get("column", 0)), owner)
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
		if _is_type_name(base) and _is_virtual_name(base):
			_error(ERR_VIRTUAL_VARTYPE, "virtual type '" + base + "' cannot be used as a base class (tuples, structs and aliases only refine values through @var/@param/@return)", int(node.get("line", 0)), int(node.get("column", 0)), owner)
	_record_extends_args(full, node, owner)
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
				if _has_any_alias_tag(child):
					_error(ERR_ALIAS_MISPLACED, "@alias definitions belong at the top level of the script", int((child as Dictionary).get("line", 0)), int((child as Dictionary).get("column", 0)), full)
				if _has_any_template_tag(child):
					_error(ERR_TEMPLATE_MISPLACED, "@template definitions belong at the top level of the script", int((child as Dictionary).get("line", 0)), int((child as Dictionary).get("column", 0)), full)
				if _has_any_generic_tag(child):
					_mark_generic_class(child, full)
				if _has_any_struct_tag(child):
					_error(ERR_STRUCT_MISPLACED, "@struct definitions belong at the top level of the script", int((child as Dictionary).get("line", 0)), int((child as Dictionary).get("column", 0)), full)
				if _has_any_interface_tag(child):
					_error(ERR_INTERFACE_MISPLACED, "@interface definitions belong at the top level of the script", int((child as Dictionary).get("line", 0)), int((child as Dictionary).get("column", 0)), full)
				if _has_any_implements_tag(child):
					_record_implements(_full_name(full, str((child as Dictionary).get("name", ""))), child as Dictionary, int((child as Dictionary).get("line", 0)))
				_scan_class_body(child, full)
			elif child is Dictionary and str((child as Dictionary).get("type", "")) in DECL_TYPES:
				_mark_decl(child, full)
				_mark_private(child, full)
				if str((child as Dictionary).get("type", "")) == "FUNC_DECL":
					_mark_return_func(child, full)
					_mark_vartype_on((child as Dictionary).get("return_type", null), child, full)
					_mark_virtual_vartype(child, full)
					_mark_param_carrier(child, child, full)
					_scan((child as Dictionary).get("body", null), full, false)
				if str((child as Dictionary).get("type", "")) == "VAR_DECL" or str((child as Dictionary).get("type", "")) == "CONST_DECL":
					_mark_var_decl(child, full)
					_mark_vartype(child, full)
					_mark_virtual_vartype(child, full)
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
				if _has_any_alias_tag(child):
					_error(ERR_ALIAS_MISPLACED, "@alias definitions belong at the top level of the script", int((child as Dictionary).get("line", 0)), int((child as Dictionary).get("column", 0)), full)
				if _has_any_template_tag(child):
					_error(ERR_TEMPLATE_MISPLACED, "@template definitions belong at the top level of the script", int((child as Dictionary).get("line", 0)), int((child as Dictionary).get("column", 0)), full)
				if _has_any_generic_tag(child):
					_error(ERR_GENERIC_MISPLACED, "@generic belongs immediately before a class declaration", int((child as Dictionary).get("line", 0)), int((child as Dictionary).get("column", 0)), full)
				if _has_any_struct_tag(child):
					_error(ERR_STRUCT_MISPLACED, "@struct definitions belong at the top level of the script", int((child as Dictionary).get("line", 0)), int((child as Dictionary).get("column", 0)), full)
				if _has_any_interface_tag(child):
					_error(ERR_INTERFACE_MISPLACED, "@interface definitions belong at the top level of the script", int((child as Dictionary).get("line", 0)), int((child as Dictionary).get("column", 0)), full)
				if _has_any_implements_tag(child):
					_error(ERR_IMPLEMENTS_MISPLACED, "@implements can only precede a class declaration or sit at the script root", int((child as Dictionary).get("line", 0)), int((child as Dictionary).get("column", 0)), full)
				elif str((child as Dictionary).get("type", "")) != "FUNC_DECL" and _has_any_return_tag(child):
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
			if not (t is Dictionary):
				continue
			var ty := str((t as Dictionary).get("type", ""))
			if ty == "IDENTIFIER" or ty == "BUILTIN_TYPE":
				parts.append(str((t as Dictionary).get("value", "")))
			elif ty == "DOT":
				continue
			else:
				break
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
					if not (t is Dictionary):
						continue
					var ty2 := str((t as Dictionary).get("type", ""))
					if ty2 == "IDENTIFIER" or ty2 == "BUILTIN_TYPE":
						p2.append(str((t as Dictionary).get("value", "")))
					elif ty2 == "DOT":
						continue
					else:
						break
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
		_check_nominal_values(d, d.get("value", null), int(d.get("line", 0)), owner)
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
			_check_nominal_values(child as Dictionary, (child as Dictionary).get("value", null), int((child as Dictionary).get("line", 0)), owner)
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


## Leading/trailing trivia of a token array (comments, separators and
## indent markers). Value-shape readers (literal splitters, inference)
## must ignore a trailing `# note` on the declaration line, or a
## single trailing comment silently disables the whole check.
static func _trim_trivia(toks: Array) -> Array:
	var start := 0
	var end := toks.size()
	while start < end and _is_trivia(toks[start]):
		start += 1
	while end > start and _is_trivia(toks[end - 1]):
		end -= 1
	return toks.slice(start, end)


static func _is_trivia(t: Variant) -> bool:
	if not (t is Dictionary):
		return false
	return str((t as Dictionary).get("type", "")) in ["COMMENT", "DOC_COMMENT", "TYPE_INFO", "NEWLINE", "SEMICOLON", "INDENT", "DEDENT", "EOF"]


## True for a bare `null` literal value, unwrapping redundant
## parentheses (`return (null)` counts). A trailing `# note` ignored.
func _value_is_bare_null(value: Variant) -> bool:
	var toks := _trim_trivia(_as_tokens(value))
	while toks.size() >= 2 and (toks[0] is Dictionary) and str((toks[0] as Dictionary).get("type", "")) == "LPAREN" and _match_close(toks, 0) == toks.size() - 1:
		toks = _trim_trivia(toks.slice(1, toks.size() - 1))
	return toks.size() == 1 and (toks[0] is Dictionary) and str((toks[0] as Dictionary).get("type", "")) == "NULL"


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


## Cross-script member flags: looks seg up in another script class'
## user JSON (builtin/engine kinds never qualify). Returns {"kind",
## "decl_owner", "private", "dep"} (empty Dictionaries for absent
## flags) or {} when unknown. Only directly-declared members (script
## JSONs list no inherited members); the analyzed script itself is
## skipped (in-memory tables own same-file checks, so this can never
## double-report).
func _user_member_entry(tname: String, seg: String) -> Dictionary:
	if tname == "" or seg == "" or seg == "_" or seg == "new":
		return {}
	if _script_class != "" and tname == _script_class:
		return {}
	var info := _ensure_script_info(tname)
	if info.is_empty() or str(info.get("kind", "")) != "script":
		return {}
	if _script_class != "" and str(info.get("class_name", "")) == _script_class:
		return {}
	var lists := [
		["instance_methods", "function"],
		["static_methods", "function"],
		["fields", "variable"],
		["constants", "constant"],
		["signals", "signal"],
		["enums", "enum"],
	]
	var cur := info
	var cur_name := tname
	var seen := {str(info.get("name", "")): true}
	while true:
		for pair in lists:
			for m in cur.get(pair[0], []):
				if m is Dictionary and str((m as Dictionary).get("name", "")) == seg:
					return {"kind": pair[1], "decl_owner": cur_name, "private": (m as Dictionary).get("private", {}), "dep": (m as Dictionary).get("deprecated", {})}
		var base := str(cur.get("extends", ""))
		if base == "":
			return {}
		var simple := _base_simple(base)
		if seen.has(simple):
			return {}
		seen[simple] = true
		cur = _ensure_script_info(simple)
		if cur.is_empty() or str(cur.get("kind", "")) != "script":
			return {}
		cur_name = simple
	return {}


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
## FUNC_DECL node for a script function (same walk as _script_seg),
## or {} when absent, not a function, or engine-backed.
func _script_func_node(owner_key: String, seg: String) -> Dictionary:
	var key := owner_key
	var seen := {}
	var guard := 0
	while guard < 64:
		guard += 1
		if seen.has(key):
			return {}
		seen[key] = true
		if _members.has(key):
			var table: Dictionary = _members[key]
			if table.has(seg):
				var rec: Dictionary = table[seg]
				if str(rec.get("kind", "")) == "function":
					var n: Variant = rec.get("node", {})
					if n is Dictionary and str((n as Dictionary).get("type", "")) == "FUNC_DECL":
						return n
				return {}
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
		return {}
	return {}


## Rebuilds an annotation tree from a stamped *_ann ({types} flat
## fallback when no tree was stamped): single name, union of names,
## or {kind: any} for dynamic. Pure.
static func _ann_tree(ann: Dictionary) -> Dictionary:
	if ann.has("tree") and (ann["tree"] is Dictionary) and not (ann.get("tree", {}) as Dictionary).is_empty():
		return ann.get("tree", {})
	var types: Array = ann.get("types", [])
	if types.is_empty():
		return {"kind": "any"}
	if types.size() == 1:
		return {"kind": "name", "name": str(types[0])}
	var arms: Array = []
	for t in types:
		arms.append({"kind": "name", "name": str(t)})
	return {"kind": "union", "arms": arms}


## Canonizes every name in a tree (typo-correction like the flat
## pipeline). Anonymous `tuple[...]` heads are kept verbatim.
func _canon_tree_names(node: Dictionary) -> Dictionary:
	var kind := str(node.get("kind", ""))
	if kind == "any":
		return {"kind": "any"}
	if kind == "name":
		var nm := str(node.get("name", ""))
		var cm := _canon_type(nm)
		if cm != "":
			return {"kind": "name", "name": cm}
		return {"kind": "name", "name": nm}
	if kind == "union":
		var arms: Array = []
		for arm in (node.get("arms", []) as Array):
			if arm is Dictionary:
				arms.append(_canon_tree_names(arm))
		return {"kind": "union", "arms": arms}
	if kind == "generic":
		var hname := str(node.get("name", ""))
		if not _is_anon_tuple_head(hname):
			var cm := _canon_type(hname)
			if cm != "":
				hname = cm
		var args: Array = []
		for arg in (node.get("args", []) as Array):
			if arg is Dictionary:
				args.append(_canon_tree_names(arg))
		return {"kind": "generic", "name": hname, "args": args}
	return {"kind": "any"}


## Generic signature of a FUNC_DECL node: formals [{name, tree, req}],
## return tree, and free template vars. {"ok": false} when the
## signature references no template variable (plain call: existing
## behavior untouched) or an alias fails to expand.
func _func_template_sig(fn_node: Dictionary) -> Dictionary:
	var formals: Array = []
	var seen := {}
	for p in fn_node.get("params", []):
		if not (p is Dictionary):
			continue
		var pd: Dictionary = p
		if str(pd.get("type", "")) != "PARAM":
			continue
		var tree := _ann_tree(pd.get("param_ann", {}))
		tree = _canon_tree_names(tree)
		var exp := _expand_tree_aliases(tree)
		if not bool(exp.get("ok", false)):
			return {"ok": false}
		tree = exp.get("node", {})
		formals.append({"name": str(pd.get("name", "")), "tree": tree, "req": (pd as Dictionary).get("default", null) == null})
		for v in _template_refs(tree, _templates.keys()):
			seen[str(v)] = true
	var ret := {"kind": "any"}
	if (fn_node as Dictionary).has("return_ann"):
		ret = _ann_tree((fn_node as Dictionary).get("return_ann", {}))
	else:
		var arrow := _arrow_name(fn_node.get("return_type", null))
		if arrow == "void":
			ret = {"kind": "name", "name": "void"}
		elif arrow != "":
			ret = {"kind": "name", "name": arrow}
	ret = _canon_tree_names(ret)
	var rexp := _expand_tree_aliases(ret)
	if not bool(rexp.get("ok", false)):
		return {"ok": false}
	ret = rexp.get("node", {})
	for v in _template_refs(ret, _templates.keys()):
		seen[str(v)] = true
	if seen.is_empty():
		return {"ok": false}
	return {"ok": true, "formals": formals, "return": ret, "tvars": seen.keys()}


## Splits call arguments (tokens between an LPAREN open_idx and its
## match) at top-level commas. Returns an Array of token Arrays
## (empty for `f()`; a trailing comma leaves no phantom argument).
static func _split_arg_slices(tokens: Array, open_idx: int) -> Array:
	var close := _match_close(tokens, open_idx)
	if close < 0:
		return []
	var out: Array = []
	var cur: Array = []
	var depth := 0
	var i := open_idx + 1
	while i < close:
		var t: Variant = tokens[i]
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
		else:
			cur.append(t)
		i += 1
	if not cur.is_empty():
		out.append(cur)
	return out


## Infers one call-argument tree from a token slice: literals,
## array/dictionary literals (elements recurse, depth-capped),
## identifiers via flow env/scope/members, anything else dynamic.
## Pure: reads tables, reports nothing.
func _infer_arg_tree(slice: Array, scope: Dictionary, fn: Variant, env: Dictionary, overlay: Dictionary, owner: String, depth: int) -> Dictionary:
	if slice.is_empty() or depth > 6:
		return {"kind": "any"}
	if slice.size() == 1 and slice[0] is Dictionary:
		var t: Dictionary = slice[0]
		var ty := str(t.get("type", ""))
		var val := str(t.get("value", ""))
		if ty == "INT":
			return {"kind": "name", "name": "int"}
		if ty == "FLOAT":
			return {"kind": "name", "name": "float"}
		if ty == "STRING":
			return {"kind": "name", "name": "String"}
		if ty == "BOOL":
			return {"kind": "name", "name": "bool"}
		if ty == "NULL":
			return {"kind": "name", "name": "null"}
		if ty == "KEYWORD":
			if val == "true" or val == "false":
				return {"kind": "name", "name": "bool"}
			return {"kind": "any"}
		if ty == "IDENTIFIER" or ty == "BUILTIN_TYPE":
			return _canon_tree_names(_infer_arg_name(val, scope, fn, env, overlay, owner))
		return {"kind": "any"}
	if (slice[0] is Dictionary) and str((slice[0] as Dictionary).get("type", "")) == "LBRACKET" and str((slice[slice.size() - 1] as Dictionary).get("type", "")) == "RBRACKET":
		var inner: Array = []
		var cur: Array = []
		var depth2 := 0
		var i := 1
		while i < slice.size() - 1:
			var e: Variant = slice[i]
			var et := ""
			if e is Dictionary:
				et = str((e as Dictionary).get("type", ""))
			if et == "LPAREN" or et == "LBRACKET" or et == "LBRACE":
				depth2 += 1
				cur.append(e)
			elif et == "RPAREN" or et == "RBRACKET" or et == "RBRACE":
				depth2 -= 1
				cur.append(e)
			elif et == "COMMA" and depth2 == 0:
				inner.append(cur)
				cur = []
			else:
				cur.append(e)
			i += 1
		if not cur.is_empty():
			inner.append(cur)
		if inner.is_empty():
			return {"kind": "name", "name": "Array"}
		var arms: Array = []
		for el in inner:
			arms.append(_infer_arg_tree(el, scope, fn, env, overlay, owner, depth + 1))
		if arms.size() == 1:
			return {"kind": "generic", "name": "Array", "args": arms}
		return {"kind": "generic", "name": "Array", "args": [{"kind": "union", "arms": arms}]}
	if (slice[0] is Dictionary) and str((slice[0] as Dictionary).get("type", "")) == "LBRACE":
		return {"kind": "name", "name": "Dictionary"}
	if (slice[0] is Dictionary) and str((slice[0] as Dictionary).get("type", "")) == "LPAREN" and _match_close(slice, 0) == slice.size() - 1:
		return _infer_arg_tree(slice.slice(1, slice.size() - 1), scope, fn, env, overlay, owner, depth + 1)
	var ctor := _infer_ctor_tree(slice, owner, depth)
	if not ctor.is_empty():
		return ctor
	return {"kind": "any"}


## Generic tree for an `Head[args](...)` constructor call slice, {}
## when the shape misses. Engine heads only (script constructors take
## no type arguments): leaves resolve leniently, anything unknown
## collapses the whole inference to dynamic. Pure.
func _infer_ctor_tree(slice: Array, owner: String, depth: int) -> Dictionary:
	if depth > 6 or slice.size() < 6:
		return {}
	if not (slice[0] is Dictionary):
		return {}
	var t0 := str((slice[0] as Dictionary).get("type", ""))
	if t0 != "IDENTIFIER" and t0 != "BUILTIN_TYPE":
		return {}
	if not (slice[1] is Dictionary) or str((slice[1] as Dictionary).get("type", "")) != "LBRACKET":
		return {}
	var rbr := _match_bracket(slice, 1)
	if rbr < 0 or rbr + 1 >= slice.size():
		return {}
	if not (slice[rbr + 1] is Dictionary) or str((slice[rbr + 1] as Dictionary).get("type", "")) != "LPAREN":
		return {}
	if _match_close(slice, rbr + 1) != slice.size() - 1:
		return {}
	var head := str((slice[0] as Dictionary).get("value", ""))
	if _engine_info(head).is_empty():
		return {}
	var inner := ""
	for i in range(2, rbr):
		if slice[i] is Dictionary:
			inner += str((slice[i] as Dictionary).get("value", ""))
	var args: Array = []
	for part in _split_top_commas(inner):
		var text := str(part).strip_edges()
		if text == "":
			return {}
		var parsed := _parse_type_expr(text, "vartype")
		if not bool(parsed.get("ok", false)):
			return {}
		args.append(_canon_tree_names(parsed.get("node", {})))
	return {"kind": "generic", "name": head, "args": args}


## Name tree for one identifier argument via flow env/scope/members
## (flat union, or dynamic when unknown). Pure.
func _infer_arg_name(vname: String, scope: Dictionary, fn: Variant, env: Dictionary, overlay: Dictionary, owner: String) -> Dictionary:
	if vname == "" or vname == "_" or vname == "self" or vname == "super" or (overlay as Dictionary).has(vname):
		return {"kind": "any"}
	if (env as Dictionary).has(vname):
		var tt := _env_tree(env, vname)
		if not tt.is_empty():
			return tt
		var et: Array = (env as Dictionary)[vname]
		if et.is_empty():
			return {"kind": "any"}
		if et.size() == 1:
			return {"kind": "name", "name": str(et[0])}
		var arms: Array = []
		for t in et:
			arms.append({"kind": "name", "name": str(t)})
		return {"kind": "union", "arms": arms}
	var fnd: Dictionary = fn if fn is Dictionary else {}
	var kind := _scope_kind(scope, vname)
	if kind == "param":
		var pnode := _find_param_node(fnd.get("params", []), vname)
		if pnode.is_empty():
			return {"kind": "any"}
		if pnode.has("param_ann"):
			return _ann_tree(pnode.get("param_ann", {}))
		var ptree := _vartype_ann_tree(pnode, owner)
		if not ptree.is_empty():
			return ptree
		return _flat_to_tree(_flow_decl_types(pnode, false, true))
	if kind == "local" or kind == "const":
		var decl := _find_body_decl(fnd.get("body", null), vname)
		if decl.is_empty():
			return {"kind": "any"}
		if decl.has("var_ann"):
			return _ann_tree(decl.get("var_ann", {}))
		var dtree := _vartype_ann_tree(decl, owner)
		if not dtree.is_empty():
			return dtree
		return _flat_to_tree(_flow_decl_types(decl, str(decl.get("type", "")) == "CONST_DECL", false))
	for o in [owner, ""]:
		var n := _member_var_node(str(o), vname)
		if not n.is_empty():
			if n.has("var_ann"):
				return _ann_tree(n.get("var_ann", {}))
			var ntree := _vartype_ann_tree(n, owner)
			if not ntree.is_empty():
				return ntree
			return _flat_to_tree(_flow_decl_types(n, str(n.get("type", "")) == "CONST_DECL", false))
	return {"kind": "any"}


## Generic tree for a declaration with a validated parameterized
## vartype, {} otherwise. Head canonized, args as stamped. Pure.
func _vartype_ann_tree(node: Dictionary, owner: String) -> Dictionary:
	if not node.has("vartype_ann"):
		return {}
	var vta: Dictionary = node["vartype_ann"]
	if str(vta.get("key", "")) == "":
		return {}
	var args: Array = (vta.get("args", []) as Array).duplicate()
	var head := _canon_type(str(vta.get("head", "")))
	if head == "":
		return {}
	return {"kind": "generic", "name": head, "args": args}


## Flat type-name list to a tree (single name, union, or dynamic).
static func _flat_to_tree(types: Array) -> Dictionary:
	if types.is_empty():
		return {"kind": "any"}
	if types.size() == 1:
		return {"kind": "name", "name": str(types[0])}
	var arms: Array = []
	for t in types:
		arms.append({"kind": "name", "name": str(t)})
	return {"kind": "union", "arms": arms}


## Instantiates one generic call: unifies formal parameter trees with
## inferred actual trees, checks bounds of bound variables, and
## returns the substituted return tree and heads. Pure: reports
## nothing (messages come fully formatted in "error"), callers decide.
## {"ok", "generic", "subst", "ret", "heads"} plus "error" when !ok.
## No-ops ({ok, n/a}) without template variables. `pre` seeds
## class-level bindings (generic methods on instantiated classes).
func _instantiate_generic_call(fn_node: Dictionary, disp: String, slices: Array, scope: Dictionary, fn: Variant, env: Dictionary, overlay: Dictionary, owner: String, pre := {}) -> Dictionary:
	var sig := _func_template_sig(fn_node)
	if not bool(sig.get("ok", false)):
		return {"ok": true, "generic": false}
	var tvars: Array = sig.get("tvars", [])
	var formals: Array = sig.get("formals", [])
	var ret: Dictionary = sig.get("return", {})
	var free: Array = []
	if pre.is_empty():
		free = tvars.duplicate()
	else:
		for f in formals:
			if f is Dictionary:
				(f as Dictionary)["tree"] = _subst_tree((f as Dictionary).get("tree", {}), pre)
		ret = _subst_tree(ret, pre)
		for v in tvars:
			if not pre.has(str(v)):
				free.append(str(v))
	if free.is_empty() and pre.is_empty():
		return {"ok": true, "generic": false}
	var req := 0
	for f in formals:
		if f is Dictionary and bool((f as Dictionary).get("req", true)):
			req += 1
	if slices.size() < req or slices.size() > formals.size():
		var want := str(req)
		if req != formals.size():
			want = str(req) + ".." + str(formals.size())
		return {"ok": false, "generic": true, "error": "generic function " + disp + " expects " + want + " argument(s), got " + str(slices.size())}
	var subst := pre.duplicate()
	for idx in range(slices.size()):
		var formal: Dictionary = formals[idx]
		var actual := _infer_arg_tree(slices[idx], scope, fn, env, overlay, owner, 0)
		var u := _unify_trees(formal.get("tree", {}), actual, subst, free)
		if not bool(u.get("ok", false)):
			return {"ok": false, "generic": true, "error": "argument " + str(idx + 1) + " of generic function " + disp + " expects '" + _show_tree(formal.get("tree", {})) + "', got '" + _show_tree(actual) + "' (" + str(u.get("error", "")) + ")"}
		subst = u.get("subst", subst)
	for v in free:
		var vs := str(v)
		if subst.has(vs) and (subst[vs] is Dictionary) and _template_refs(subst[vs], free).is_empty() and not _template_bound_of(vs).is_empty():
			if not _check_bound(_template_bound_of(vs), subst[vs]):
				return {"ok": false, "generic": true, "error": "type '" + _show_tree(subst[vs]) + "' for '" + vs + "' violates bound '" + _show_tree(_template_bound_of(vs)) + "' in generic function " + disp}
	var ret2 := _subst_tree(ret, subst)
	return {"ok": true, "generic": true, "subst": subst, "ret": ret2, "heads": _tree_top_heads(ret2)}


## Reporting wrapper over _instantiate_generic_call: template_mismatch
## on failure, {ok, generic, heads} either way (heads feed chaining).
func _check_generic_call(fn_node: Dictionary, disp: String, slices: Array, scope: Dictionary, fn: Variant, env: Dictionary, overlay: Dictionary, owner: String, line: int, col: int, pre := {}) -> Dictionary:
	var r := _instantiate_generic_call(fn_node, disp, slices, scope, fn, env, overlay, owner, pre)
	if not bool(r.get("generic", false)):
		return {"ok": true, "generic": false}
	if not bool(r.get("ok", false)):
		_error(ERR_TEMPLATE_MISMATCH, str(r.get("error", "")), line, col, owner)
		return {"ok": false, "generic": true}
	return {"ok": true, "generic": true, "heads": r.get("heads", [])}


## Substitutes class-parameter heads in a script hit with instance
## type arguments: direct hits use the link args; inherited hits use
## the child's validated extends arguments (single level: deeper
## chains and extends-without-args stay opaque). Arity guarded.
func _subst_hit_types(hut: Dictionary, rec: Dictionary, key: String, start_key: String, link_args: Array) -> Dictionary:
	if str(rec.get("kind", "")) not in ["variable", "constant"]:
		return hut
	if str(rec.get("owner", "")) != key:
		return hut
	var params := _class_generic(key)
	var args := link_args
	if key != start_key:
		if link_args.is_empty():
			var e := _extends_args.get(start_key, {})
			if e is Dictionary and str((e as Dictionary).get("key", "")) == key:
				args = (e as Dictionary).get("args", [])
			else:
				return hut
		else:
			return hut
	if params.is_empty() or params.size() != args.size():
		return hut
	var cont: Dictionary = hut.get("cont", {})
	var out: Array = []
	var changed := false
	for t in (cont.get("types", []) as Array):
		var idx := params.find(str(t))
		if idx < 0 or not (args[idx] is Dictionary):
			out.append(t)
			continue
		var hs := _tree_top_heads(args[idx])
		if hs.is_empty():
			out.append(t)
		else:
			for h in hs:
				out.append(str(h))
			changed = true
	if changed:
		cont["types"] = out
	return hut


## Owner key holding a script function (same walk as _script_func_node),
## "" when absent. Used to bind the right class parameters for
## inherited generic methods.
func _script_func_owner(owner_key: String, seg: String) -> String:
	var key := owner_key
	var seen := {}
	var guard := 0
	while guard < 64:
		guard += 1
		if seen.has(key):
			return ""
		seen[key] = true
		if _members.has(key):
			var table: Dictionary = _members[key]
			if table.has(seg):
				var rec: Dictionary = table[seg]
				if str(rec.get("kind", "")) == "function":
					var n: Variant = rec.get("node", {})
					if n is Dictionary and str((n as Dictionary).get("type", "")) == "FUNC_DECL":
						return key
				return ""
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
		return ""
	return ""


func _script_seg(owner_key: String, seg: String, is_call: bool, link_args := []) -> Dictionary:
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
				var hut := _script_hit(table[seg], seg, is_call)
				return _subst_hit_types(hut, table[seg], key, owner_key, link_args)
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
	if node.has("vartype_ann"):
		var vta: Dictionary = node["vartype_ann"]
		if str(vta.get("head", "")) != "":
			return [str(vta.get("head", ""))]
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


## Declaration node behind a chain base name (param/local/const
## scopes, then member vars), {} when shadowed by env/overlay values
## or unresolvable. Mirrors _flow_base precedence (nodes only).
func _base_decl_node(base: String, fn: Variant, scope: Dictionary, owner: String, env: Dictionary) -> Dictionary:
	if base == "" or base == "_" or base == "self" or base == "super":
		return {}
	if (env as Dictionary).has(base):
		return {}
	var fnd: Dictionary = fn if fn is Dictionary else {}
	var kind := _scope_kind(scope, base)
	if kind == "param":
		return _find_param_node(fnd.get("params", []), base)
	if kind == "local" or kind == "const":
		return _find_body_decl(fnd.get("body", null), base)
	if kind != "":
		return {}
	for o in [owner, ""]:
		var n := _member_var_node(str(o), base)
		if not n.is_empty():
			return n
	return {}


## Generic arguments behind a chain base for one resolved link key:
## the declaration vartype first, then @var/@param stamped trees whose
## head resolves to the key. [] when absent or mismatched. Pure.
func _link_vartype_args(base: String, fn: Variant, scope: Dictionary, owner: String, env: Dictionary, key: String) -> Array:
	if key == "":
		return []
	var node := _base_decl_node(base, fn, scope, owner, env)
	if node.is_empty():
		return []
	if node.has("vartype_ann"):
		var vta: Dictionary = node["vartype_ann"]
		if str(vta.get("key", "")) == key:
			return (vta.get("args", []) as Array).duplicate()
	for ak in ["var_ann", "param_ann"]:
		if node.has(ak):
			var tree := _ann_tree(node[ak])
			if str(tree.get("kind", "")) == "generic":
				var hn := str(tree.get("name", ""))
				var kk := _script_key_of(hn, owner)
				if kk == key:
					return (tree.get("args", []) as Array).duplicate()
	return []
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
	if not _struct_def(tname).is_empty():
		return {"kind": "struct", "name": tname}
	if not _iface_spec(tname).is_empty():
		return {"kind": "interface", "name": tname}
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


## Generic instantiation for a method call on a script link: resolves
## the callee FUNC_DECL and checks argument trees when its signature
## references template variables. Returns {"applies": false} for
## plain calls (caller keeps existing behavior) or {"applies": true,
## "types": [...]} with substituted return heads (possibly dynamic).
func _generic_link_types(key: String, seg: String, tokens: Array, j: int, scope: Dictionary, fn: Variant, env: Dictionary, overlay: Dictionary, owner: String, link_args := []) -> Dictionary:
	var node := _script_func_node(key, seg)
	if node.is_empty():
		return {"applies": false}
	if j + 1 >= tokens.size() or not (tokens[j + 1] is Dictionary) or str((tokens[j + 1] as Dictionary).get("type", "")) != "LPAREN":
		return {"applies": false}
	var close := _match_close(tokens, j + 1)
	if close < 0:
		return {"applies": false}
	var slices := _split_arg_slices(tokens, j + 1)
	var disp := "'" + seg + "'"
	var pre := {}
	var mowner := _script_func_owner(key, seg)
	if mowner != "":
		if mowner == key:
			pre = _class_prebindings(key, link_args)
		else:
			var e := _extends_args.get(key, {})
			if e is Dictionary and str((e as Dictionary).get("key", "")) == mowner:
				pre = _class_prebindings(mowner, (e as Dictionary).get("args", []))
	var r := _check_generic_call(node, disp, slices, scope, fn, env, overlay, owner, int((tokens[j] as Dictionary).get("line", 0)), int((tokens[j] as Dictionary).get("column", 0)), pre)
	if not bool(r.get("generic", false)):
		return {"applies": false}
	return {"applies": true, "types": r.get("heads", [])}


## Class-level prebindings for a method call on an instantiated link:
## {class_param: arg_tree} when the link carries args matching the
## class arity (checked at declaration; guarded). {} otherwise.
func _class_prebindings(key: String, link_args: Array) -> Dictionary:
	var out := {}
	var params := _class_generic(key)
	if params.is_empty() or params.size() != link_args.size():
		return out
	for i in range(params.size()):
		if link_args[i] is Dictionary:
			out[str(params[i])] = link_args[i]
		else:
			return {}
	return out


## True when a FUNC_DECL has any notnull parameter.
static func _func_has_notnull(node: Dictionary) -> bool:
	for p in (node as Dictionary).get("params", []):
		if p is Dictionary:
			var ann: Variant = (p as Dictionary).get("param_ann", {})
			if ann is Dictionary and bool((ann as Dictionary).get("notnull", false)):
				return true
	return false


## True when a FUNC_DECL/LAMBDA declares a nullable return: call
## results taint the assignee so unguarded use warns downstream.
static func _func_returns_nullable(node: Dictionary) -> bool:
	var ann: Variant = (node as Dictionary).get("return_ann", {})
	return ann is Dictionary and bool((ann as Dictionary).get("nullable", false))


## Declared return heads of a FUNC_DECL/LAMBDA ([] when none).
static func _return_ann_types(node: Dictionary) -> Array:
	var ann: Variant = (node as Dictionary).get("return_ann", {})
	if ann is Dictionary:
		return ((ann as Dictionary).get("types", []) as Array).duplicate()
	return []


## True when a FUNC_DECL/LAMBDA return can be null (bare `null` arm
## or null in the top tree): assigned results resolve with the
## declared heads so member use warns through the null arm.
static func _return_ann_has_null(node: Dictionary) -> bool:
	var ann: Variant = (node as Dictionary).get("return_ann", {})
	if not (ann is Dictionary):
		return false
	for t in ((ann as Dictionary).get("types", []) as Array):
		if str(t) == "null":
			return true
	if (ann as Dictionary).has("tree"):
		return _tree_has_top_null((ann as Dictionary).get("tree", {}))
	return false


## First null-literal violation of a call against one callee: {} when
## every provided notnull parameter gets a non-null argument (missing
## args rely on defaults, already def-checked; extra args skipped).
## Maybe-null arguments stay silent (lenient); template machinery
## owns nothing here (it never reads notnull flags, so no doubles).
func _notnull_call_violation(node: Dictionary, slices: Array) -> Dictionary:
	var params: Array = (node as Dictionary).get("params", [])
	var n := mini(params.size(), slices.size())
	for i in range(n):
		var p: Variant = params[i]
		if not (p is Dictionary):
			continue
		var ann: Variant = (p as Dictionary).get("param_ann", {})
		if not (ann is Dictionary) or not bool((ann as Dictionary).get("notnull", false)):
			continue
		if i >= slices.size() or not (slices[i] is Array):
			continue
		var tt := _trim_trivia(slices[i])
		if tt.size() == 1 and (tt[0] is Dictionary) and str((tt[0] as Dictionary).get("type", "")) == "NULL":
			return {"param": str((p as Dictionary).get("name", "")), "line": int((tt[0] as Dictionary).get("line", 0)), "col": int((tt[0] as Dictionary).get("column", 0))}
	return {}


## Errors one callee's first null-literal violation, if any.
func _error_notnull_call(node: Dictionary, seg: String, slices: Array, owner: String) -> void:
	var v := _notnull_call_violation(node, slices)
	if v.is_empty():
		return
	_error(ERR_PARAM_NOTNULL, "cannot pass null to notnull parameter '" + str(v.get("param", "")) + "' of '" + seg + "()'", int(v.get("line", 0)), int(v.get("col", 0)), owner)


## Warns declared-maybe (non-literal) arguments to notnull parameters
## of one callee, one warning per offending argument at its own line.
## Distrust only: trust keeps the historical silence (literals still
## error in both). Null literals stay out (the error above owns
## them); the callee's own policy is irrelevant here (a refusal
## broken at the boundary is invisible to the callee either way).
func _warn_notnull_maybe_call(node: Dictionary, seg: String, slices: Array, scope: Dictionary, fn: Variant, env: Dictionary, overlay: Dictionary, owner: String) -> void:
	if not _null_distrust():
		return
	var params: Array = (node as Dictionary).get("params", [])
	var n := mini(params.size(), slices.size())
	for i in range(n):
		var p: Variant = params[i]
		if not (p is Dictionary):
			continue
		var ann: Variant = (p as Dictionary).get("param_ann", {})
		if not (ann is Dictionary) or not bool((ann as Dictionary).get("notnull", false)):
			continue
		if i >= slices.size() or not (slices[i] is Array):
			continue
		var hit := _slice_maybe_arg(slices[i], scope, fn, env, overlay, owner)
		if hit.is_empty() or str(hit.get("name", "")) == "null":
			continue
		var cause := _hit_cause(hit, _effective_strict())
		if cause == "":
			continue
		var tok: Dictionary = hit.get("tok", {})
		var suffix := " (untyped)" if cause == "untyped" else ""
		_warnings.append({"kind": ERR_MAYBE_NULL, "message": "possible null argument '" + str(hit.get("name", "")) + "' for notnull parameter '" + str((p as Dictionary).get("name", "")) + "' of '" + seg + "()'" + suffix, "line": int(tok.get("line", 0)), "column": int(tok.get("column", 0)), "owner": owner})


## Bare-call site check (mirrors _verify_bare_generic resolution:
## member functions outward; shadowed names bail like there, except
## lambda values, whose own params are checked).
func _check_notnull_bare(tokens: Array, i: int, open_idx: int, scope: Dictionary, fn: Variant, env: Dictionary, overlay: Dictionary, owner: String) -> void:
	var base := str((tokens[i] as Dictionary).get("value", ""))
	if base == "" or base == "_":
		return
	if (overlay as Dictionary).has(base):
		return
	var lnode := _lambda_value_node(base, fn, scope, owner, env, overlay)
	if not lnode.is_empty():
		if _func_has_notnull(lnode):
			var lslices := _split_arg_slices(tokens, open_idx)
			_error_notnull_call(lnode, base, lslices, owner)
			_warn_notnull_maybe_call(lnode, base, lslices, scope, fn, env, overlay, owner)
		return
	if str(_scope_kind(scope, base)) != "":
		return
	if (env as Dictionary).has(base):
		return
	var node := _script_func_node(owner, base)
	if node.is_empty() and owner != "":
		node = _script_func_node("", base)
	if node.is_empty() or not _func_has_notnull(node):
		return
	var slices := _split_arg_slices(tokens, open_idx)
	_error_notnull_call(node, base, slices, owner)
	_warn_notnull_maybe_call(node, base, slices, scope, fn, env, overlay, owner)


## Lambda-valued declaration behind a bare-call base (locals, member
## vars; env-bound and overlay names stay opaque). {} when the name
## cannot hold a lambda value.
func _lambda_value_node(base: String, fn: Variant, scope: Dictionary, owner: String, env: Dictionary, overlay: Dictionary) -> Dictionary:
	if base == "" or base == "_":
		return {}
	if (overlay as Dictionary).has(base):
		return {}
	if (env as Dictionary).has(base):
		return {}
	var fnd: Dictionary = fn if fn is Dictionary else {}
	var kind := str(_scope_kind(scope, base))
	var node := {}
	if kind == "param":
		node = _find_param_node(fnd.get("params", []), base)
	elif kind == "local" or kind == "const":
		node = _find_body_decl(fnd.get("body", null), base)
	else:
		for o in [owner, ""]:
			node = _member_var_node(str(o), base)
			if not node.is_empty():
				break
	if node.is_empty():
		return {}
	var v: Variant = (node as Dictionary).get("value", null)
	if v is Dictionary and str((v as Dictionary).get("type", "")) == "LAMBDA":
		return v
	return {}


## `super.m(...)` site check: resolves the parent script key in this
## file's tables only (engine/cross-file parents stay silent, like the
## chain itself, which never verifies super calls).
func _check_notnull_super(base: String, tokens: Array, j: int, scope: Dictionary, fn: Variant, env: Dictionary, overlay: Dictionary, owner: String) -> void:
	if base != "super":
		return
	var b: String = _script_extends if owner == "" else str(_class_extends.get(owner, ""))
	if b == "":
		return
	var key := _resolve_private_owner(b, owner)
	if key == "" or not _members.has(key):
		return
	if j >= tokens.size() or not (tokens[j] is Dictionary):
		return
	if str((tokens[j] as Dictionary).get("type", "")) != "DOT":
		return
	if j + 1 >= tokens.size() or not (tokens[j + 1] is Dictionary):
		return
	if str((tokens[j + 1] as Dictionary).get("type", "")) not in ["IDENTIFIER", "BUILTIN_TYPE", "KEYWORD"]:
		return
	var seg := str((tokens[j + 1] as Dictionary).get("value", ""))
	if j + 2 >= tokens.size() or not (tokens[j + 2] is Dictionary):
		return
	if str((tokens[j + 2] as Dictionary).get("type", "")) != "LPAREN":
		return
	_check_notnull_links([{"kind": "script", "key": key}], seg, tokens, j + 1, scope, fn, env, overlay, owner)


## Chain call-site check across one segment's script links (self and
## same-file instances). Union dispatch is lenient: errors only when
## every resolving callee flags the position. Engine, dynamic and
## cross-script links (no signature data) stay silent, as do signals
## (handled before this point).
func _check_notnull_links(links: Array, seg: String, tokens: Array, j: int, scope: Dictionary, fn: Variant, env: Dictionary, overlay: Dictionary, owner: String) -> void:
	var slices := _split_arg_slices(tokens, j + 1)
	if slices.is_empty():
		return
	var saw := false
	var clean := false
	var first := {}
	var wnode := {}
	for L in links:
		if not (L is Dictionary) or str(L.get("kind", "")) != "script":
			continue
		var node := _script_func_node(str(L.get("key", "")), seg)
		if node.is_empty() or not _func_has_notnull(node):
			continue
		if wnode.is_empty():
			wnode = node
		saw = true
		var v := _notnull_call_violation(node, slices)
		if v.is_empty():
			clean = true
			break
		if first.is_empty():
			first = v
	if saw and not clean and not first.is_empty():
		_error(ERR_PARAM_NOTNULL, "cannot pass null to notnull parameter '" + str(first.get("param", "")) + "' of '" + seg + "()'", int(first.get("line", 0)), int(first.get("col", 0)), owner)
	if not wnode.is_empty():
		_warn_notnull_maybe_call(wnode, seg, slices, scope, fn, env, overlay, owner)
## Generic instantiation for a bare call `f(...)`: only when the name
## cannot be a value (no overlay/scope/env/member binding), resolving
## member functions outward (owner, then root). Returns the index past
## the call (DOT rest skipped, like _skip_chain_verify) or -1 when the
## existing skip path owns the chain.
func _verify_bare_generic(tokens: Array, i: int, j: int, scope: Dictionary, fn: Variant, env: Dictionary, overlay: Dictionary, owner: String) -> int:
	var base := str((tokens[i] as Dictionary).get("value", ""))
	if base == "" or base == "_":
		return -1
	if (overlay as Dictionary).has(base):
		return -1
	if str(_scope_kind(scope, base)) != "":
		return -1
	if (env as Dictionary).has(base):
		return -1
	for o in [owner, ""]:
		if not _member_var_node(str(o), base).is_empty():
			return -1
	if j >= tokens.size() or not (tokens[j] is Dictionary) or str((tokens[j] as Dictionary).get("type", "")) != "LPAREN":
		return -1
	var node := _script_func_node(owner, base)
	if node.is_empty() and owner != "":
		node = _script_func_node("", base)
	if node.is_empty():
		return -1
	var close := _match_close(tokens, j)
	if close < 0:
		return -1
	var slices := _split_arg_slices(tokens, j)
	var r := _check_generic_call(node, "'" + base + "'", slices, scope, fn, env, overlay, owner, int((tokens[i] as Dictionary).get("line", 0)), int((tokens[i] as Dictionary).get("column", 0)))
	if not bool(r.get("generic", false)):
		return -1
	_verify_span(tokens, j, scope, owner, fn, env, overlay)
	return _skip_chain_verify(tokens, close + 1, scope, owner, fn, env, overlay)


## True for a definitely-null union: non-empty and every head null.
static func _types_all_null(types: Array) -> bool:
	if types.is_empty():
		return false
	for t in types:
		if str(t) != "null":
			return false
	return true


## Exact-null member use: the receiver is provably null, so any call
## or read errors null_access (bare uses like print(x) stay legal and
## never reach here: no DOT segment peeks out).
func _error_null_seg(tokens: Array, j: int, owner: String) -> void:
	if j >= tokens.size() or not (tokens[j] is Dictionary):
		return
	if str((tokens[j] as Dictionary).get("type", "")) != "DOT":
		return
	if j + 1 >= tokens.size() or not (tokens[j + 1] is Dictionary):
		return
	var nt := str((tokens[j + 1] as Dictionary).get("type", ""))
	if nt != "IDENTIFIER" and nt != "BUILTIN_TYPE" and nt != "KEYWORD":
		return
	var seg := str((tokens[j + 1] as Dictionary).get("value", ""))
	var is_call := j + 2 < tokens.size() and (tokens[j + 2] is Dictionary) and str((tokens[j + 2] as Dictionary).get("type", "")) == "LPAREN"
	if is_call:
		_error(ERR_NULL_ACCESS, "cannot call method '" + seg + "()' on null", int((tokens[j + 1] as Dictionary).get("line", 0)), int((tokens[j + 1] as Dictionary).get("column", 0)), owner)
	else:
		_error(ERR_NULL_ACCESS, "cannot read member '" + seg + "' of null", int((tokens[j + 1] as Dictionary).get("line", 0)), int((tokens[j + 1] as Dictionary).get("column", 0)), owner)


## Explicit-nullable unguarded use: the union resolved through some
## arm, but a `null` arm (direct or via alias) is in play and nothing
## proves non-null (no notnull mark, no guard). Warning only, never an
## error: maybe is not definitely. `cause` selects the display:
## "declared" (explicit mark or taint) reads `(nullable 'T')`,
## "policy" (distrust default) reads `(implicitly nullable 'T')`.
func _warn_maybe_null(base: String, seg: String, warn_types: Array, is_call: bool, tok: Dictionary, owner: String, cause := "") -> void:
	var disp := _show_types(warn_types)
	var tag := "nullable"
	if cause == "policy":
		tag = "implicitly nullable"
	elif cause == "untyped":
		tag = "untyped"
		disp = base
	if is_call:
		_warnings.append({"kind": ERR_MAYBE_NULL, "message": "possible null call '" + seg + "()' on '" + base + "' (" + tag + " '" + disp + "')", "line": int(tok.get("line", 0)), "column": int(tok.get("column", 0)), "owner": owner})
	else:
		_warnings.append({"kind": ERR_MAYBE_NULL, "message": "possible null read '" + seg + "' on '" + base + "' (" + tag + " '" + disp + "')", "line": int(tok.get("line", 0)), "column": int(tok.get("column", 0)), "owner": owner})


## Strict-untyped receiver check for an otherwise-silent chain:
## under distrust + effective strict, member use on a declared-but-
## untyped slot warns once on the first segment (bare uses stay
## legal). notnull state (mark, stamp, guard) always wins; totally
## unknown names, super/self and shadowed values stay out.
func _check_strict_untyped(base: String, tokens: Array, j: int, scope: Dictionary, fn: Variant, env: Dictionary, owner: String) -> void:
	if not _null_distrust() or not _effective_strict():
		return
	if base == "" or base == "_" or base == "super" or base == "self":
		return
	if j >= tokens.size() or not (tokens[j] is Dictionary):
		return
	if str((tokens[j] as Dictionary).get("type", "")) != "DOT":
		return
	if j + 1 >= tokens.size() or not (tokens[j + 1] is Dictionary):
		return
	var nt := str((tokens[j + 1] as Dictionary).get("type", ""))
	if nt != "IDENTIFIER" and nt != "BUILTIN_TYPE" and nt != "KEYWORD":
		return
	var seg := str((tokens[j + 1] as Dictionary).get("value", ""))
	if seg == "" or seg == "_" or seg == "new":
		return
	if not _untyped_slot(base, fn, scope, owner, env):
		return
	if _flow_notnull(base, fn, scope, owner, env):
		return
	var is_call := j + 2 < tokens.size() and (tokens[j + 2] is Dictionary) and str((tokens[j + 2] as Dictionary).get("type", "")) == "LPAREN"
	_warn_maybe_null(base, seg, [], is_call, tokens[j + 1], owner, "untyped")


## Head-miss watch: the base is watched (explicit mark/taint or
## distrust) but its heads resolve to no link (explicit Variant,
## transparent aliases), so the chain skips verification entirely.
## Warns once on the first segment, then the skip stands: watching
## what verification cannot see still deserves the warning.
func _warn_unresolved_watch(base: String, tokens: Array, j: int, warn_types: Array, warn_cause: String, owner: String) -> void:
	if warn_cause == "" or warn_types.is_empty():
		return
	if j >= tokens.size() or not (tokens[j] is Dictionary):
		return
	if str((tokens[j] as Dictionary).get("type", "")) != "DOT":
		return
	if j + 1 >= tokens.size() or not (tokens[j + 1] is Dictionary):
		return
	var nt := str((tokens[j + 1] as Dictionary).get("type", ""))
	if nt != "IDENTIFIER" and nt != "BUILTIN_TYPE" and nt != "KEYWORD":
		return
	var seg := str((tokens[j + 1] as Dictionary).get("value", ""))
	if seg == "" or seg == "_":
		return
	var is_call := j + 2 < tokens.size() and (tokens[j + 2] is Dictionary) and str((tokens[j + 2] as Dictionary).get("type", "")) == "LPAREN"
	_warn_maybe_null(base, seg, warn_types, is_call, tokens[j + 1], owner, warn_cause)


## Cross-script call-site check: null literal arguments against
## notnull parameters read from the target script's user JSON
## (param_names/notnull_params our analyzer maintains there).
## Unknown classes, engine types, stale files without the keys and
## public members stay silent. Inherited members are not followed
## (JSONs list direct members only), like every other cross check.
func _check_cross_notnull(tname: String, tokens: Array, j: int, owner: String) -> void:
	if tname == "" or tname == "_" or tname == "null":
		return
	if j >= tokens.size() or not (tokens[j] is Dictionary):
		return
	if str((tokens[j] as Dictionary).get("type", "")) != "DOT":
		return
	if j + 1 >= tokens.size() or not (tokens[j + 1] is Dictionary):
		return
	var nt := str((tokens[j + 1] as Dictionary).get("type", ""))
	if nt != "IDENTIFIER" and nt != "BUILTIN_TYPE" and nt != "KEYWORD":
		return
	var seg := str((tokens[j + 1] as Dictionary).get("value", ""))
	if seg == "" or seg == "_" or seg == "new":
		return
	if j + 2 >= tokens.size() or not (tokens[j + 2] is Dictionary):
		return
	if str((tokens[j + 2] as Dictionary).get("type", "")) != "LPAREN":
		return
	if _script_class != "" and tname == _script_class:
		return
	var info := _ensure_script_info(tname)
	if info.is_empty() or str(info.get("kind", "")) != "script":
		return
	if _script_class != "" and str(info.get("class_name", "")) == _script_class:
		return
	var entry := _user_method_entry_chain(tname, info, seg)
	if entry.is_empty():
		return
	var names: Variant = entry.get("param_names", [])
	var flagged: Variant = entry.get("notnull_params", [])
	if not (names is Array) or not (flagged is Array):
		return
	if (names as Array).is_empty() or (flagged as Array).is_empty():
		return
	var slices := _split_arg_slices(tokens, j + 2)
	var n := mini((names as Array).size(), slices.size())
	for i in range(n):
		if not (flagged as Array).has(str((names as Array)[i])):
			continue
		if not (slices[i] is Array):
			continue
		var tt := _trim_trivia(slices[i])
		if tt.size() == 1 and (tt[0] is Dictionary) and str((tt[0] as Dictionary).get("type", "")) == "NULL":
			_error(ERR_PARAM_NOTNULL, "cannot pass null to notnull parameter '" + str((names as Array)[i]) + "' of '" + seg + "()'", int((tt[0] as Dictionary).get("line", 0)), int((tt[0] as Dictionary).get("column", 0)), owner)


## Cross-script boundary consent: a distrust caller passing a
## declared-maybe argument (null literal, nullable stamp/taint, or an
## explicit null arm) to an IMPLICIT parameter of a trust callee warns
## maybe_null at the argument: the callee will not check, so the
## caller must. Silent when the caller is lenient, when the callee
## watches itself (distrust), when the parameter consents (`nullable`)
## or refuses (`notnull`, whose literal rule owns that direction),
## and for stale JSONs without the keys (same precedent as
## _check_cross_notnull). Same-file calls never warn (one file, one
## policy: use sites cover them); super/engine/dynamic stay out.
func _check_cross_maybe(tname: String, tokens: Array, j: int, scope: Dictionary, fn: Variant, env: Dictionary, overlay: Dictionary, owner: String) -> void:
	if not _null_distrust():
		return
	if tname == "" or tname == "_" or tname == "null":
		return
	if j >= tokens.size() or not (tokens[j] is Dictionary):
		return
	if str((tokens[j] as Dictionary).get("type", "")) != "DOT":
		return
	if j + 1 >= tokens.size() or not (tokens[j + 1] is Dictionary):
		return
	var nt := str((tokens[j + 1] as Dictionary).get("type", ""))
	if nt != "IDENTIFIER" and nt != "BUILTIN_TYPE" and nt != "KEYWORD":
		return
	var seg := str((tokens[j + 1] as Dictionary).get("value", ""))
	if seg == "" or seg == "_" or seg == "new":
		return
	if j + 2 >= tokens.size() or not (tokens[j + 2] is Dictionary):
		return
	if str((tokens[j + 2] as Dictionary).get("type", "")) != "LPAREN":
		return
	if _script_class != "" and tname == _script_class:
		return
	var info := _ensure_script_info(tname)
	if info.is_empty() or str(info.get("kind", "")) != "script":
		return
	if _script_class != "" and str(info.get("class_name", "")) == _script_class:
		return
	if str(info.get("null_policy", "")) != "trust":
		return
	var entry := _user_method_entry_chain(tname, info, seg)
	if entry.is_empty():
		return
	var names: Variant = entry.get("param_names", [])
	var refused: Variant = entry.get("notnull_params", [])
	var consented: Variant = entry.get("nullable_params", [])
	if not (names is Array) or not (refused is Array) or not (consented is Array):
		return
	if (names as Array).is_empty():
		return
	var slices := _split_arg_slices(tokens, j + 2)
	var n := mini((names as Array).size(), slices.size())
	for i in range(n):
		var pname := str((names as Array)[i])
		if (refused as Array).has(pname) or (consented as Array).has(pname):
			continue
		if not (slices[i] is Array):
			continue
		var hit := _slice_maybe_arg(slices[i], scope, fn, env, overlay, owner)
		if hit.is_empty():
			continue
		var cause := _hit_cause(hit, _effective_strict())
		if cause == "":
			continue
		var tok: Dictionary = hit.get("tok", {})
		var tag := "untyped" if cause == "untyped" else "implicitly nullable"
		_warnings.append({"kind": ERR_MAYBE_NULL, "message": "possible null argument '" + str(hit.get("name", "")) + "' for parameter '" + pname + "' of '" + seg + "()' (" + tag + ")", "line": int(tok.get("line", 0)), "column": int(tok.get("column", 0)), "owner": owner})


## Shared cause gate for boundary argument hits: "declared" hits
## always count under distrust; "untyped" hits (no cause key means
## declared) only count under effective strict. Returns the cause, or
## "" when the hit must stay silent. Pure.
static func _hit_cause(hit: Dictionary, strict: bool) -> String:
	var cause := str(hit.get("cause", "declared"))
	if cause == "untyped" and not strict:
		return ""
	return cause


## Cross-script refusal direction: a distrust caller passing a
## declared-maybe (non-literal) argument to a `notnull` parameter
## warns at the argument. Null literals stay out (the literal error
## owns them); the callee's policy is irrelevant (a refusal broken at
## the boundary is invisible to the callee either way). Same-file and
## super calls route through _warn_notnull_maybe_call instead.
func _check_cross_notnull_maybe(tname: String, tokens: Array, j: int, scope: Dictionary, fn: Variant, env: Dictionary, overlay: Dictionary, owner: String) -> void:
	if not _null_distrust():
		return
	if tname == "" or tname == "_" or tname == "null":
		return
	if j >= tokens.size() or not (tokens[j] is Dictionary):
		return
	if str((tokens[j] as Dictionary).get("type", "")) != "DOT":
		return
	if j + 1 >= tokens.size() or not (tokens[j + 1] is Dictionary):
		return
	var nt := str((tokens[j + 1] as Dictionary).get("type", ""))
	if nt != "IDENTIFIER" and nt != "BUILTIN_TYPE" and nt != "KEYWORD":
		return
	var seg := str((tokens[j + 1] as Dictionary).get("value", ""))
	if seg == "" or seg == "_" or seg == "new":
		return
	if j + 2 >= tokens.size() or not (tokens[j + 2] is Dictionary):
		return
	if str((tokens[j + 2] as Dictionary).get("type", "")) != "LPAREN":
		return
	if _script_class != "" and tname == _script_class:
		return
	var info := _ensure_script_info(tname)
	if info.is_empty() or str(info.get("kind", "")) != "script":
		return
	if _script_class != "" and str(info.get("class_name", "")) == _script_class:
		return
	var entry := _user_method_entry_chain(tname, info, seg)
	if entry.is_empty():
		return
	var names: Variant = entry.get("param_names", [])
	var refused: Variant = entry.get("notnull_params", [])
	if not (names is Array) or not (refused is Array):
		return
	if (names as Array).is_empty() or (refused as Array).is_empty():
		return
	var slices := _split_arg_slices(tokens, j + 2)
	var n := mini((names as Array).size(), slices.size())
	for i in range(n):
		if not (refused as Array).has(str((names as Array)[i])):
			continue
		if not (slices[i] is Array):
			continue
		var hit := _slice_maybe_arg(slices[i], scope, fn, env, overlay, owner)
		if hit.is_empty() or str(hit.get("name", "")) == "null":
			continue
		var cause := _hit_cause(hit, _effective_strict())
		if cause == "":
			continue
		var tok: Dictionary = hit.get("tok", {})
		var suffix := " (untyped)" if cause == "untyped" else ""
		_warnings.append({"kind": ERR_MAYBE_NULL, "message": "possible null argument '" + str(hit.get("name", "")) + "' for notnull parameter '" + str((names as Array)[i]) + "' of '" + seg + "()'" + suffix, "line": int(tok.get("line", 0)), "column": int(tok.get("column", 0)), "owner": owner})


## Declared-maybe argument behind one call slice: {"name", "tok",
## "cause"} for a bare null literal, a single identifier resolving to
## a watched slot (nullable stamp/taint or an explicit null arm,
## cause "declared") or to a declared-but-untyped slot (cause
## "untyped", only under distrust + effective strict and never under
## a notnull mark), or a call to a nullable (or
## explicit-null-returning) function — bare, self, lambda-held,
## same-file member or cross-file static shapes, {} otherwise.
## Policy-watched (implicit, distrust-default) arguments stay out:
## unproven is not maybe. Pure (never warns itself).
func _slice_maybe_arg(slice: Array, scope: Dictionary, fn: Variant, env: Dictionary, overlay: Dictionary, owner: String) -> Dictionary:
	var tt := _trim_trivia(slice)
	if tt.is_empty() or not (tt[0] is Dictionary):
		return {}
	var t: Dictionary = tt[0]
	if str(t.get("type", "")) == "NULL" and tt.size() == 1:
		return {"name": "null", "tok": t}
	if str(t.get("type", "")) == "IDENTIFIER" and tt.size() == 1:
		var aname := str(t.get("value", ""))
		if aname == "" or aname == "_":
			return {}
		var fb := _flow_base(aname, fn, scope, owner, env, overlay)
		if str(fb.get("kind", "")) != "instance":
			return {}
		if _flow_watch_cause(aname, fn, scope, owner, env, (fb as Dictionary).get("types", [])) == "declared":
			return {"name": aname, "tok": t, "cause": "declared"}
		if _null_distrust() and _effective_strict() and _untyped_slot(aname, fn, scope, owner, env) and not _flow_notnull(aname, fn, scope, owner, env):
			return {"name": aname, "tok": t, "cause": "untyped"}
		return {}
	var node := _taint_rhs_node(tt, scope, fn, env, owner)
	if not node.is_empty():
		if not _func_returns_nullable(node) and not _return_ann_has_null(node):
			return {}
		return {"name": _slice_call_display(tt), "tok": t, "cause": "declared"}
	var jsig := _taint_json_sig(tt, scope, fn, env, owner)
	if jsig.is_empty() or not bool(jsig.get("nullable", false)):
		return {}
	return {"name": _slice_call_display(tt), "tok": t, "cause": "declared"}


## Short display for a call slice ("make()", "self.make()",
## "super.make()", "lib.make()", "cb.call()").
static func _slice_call_display(tt: Array) -> String:
	if tt.is_empty() or not (tt[0] is Dictionary):
		return "call()"
	if str((tt[0] as Dictionary).get("type", "")) == "KEYWORD" and tt.size() > 2 and (tt[2] is Dictionary):
		return str((tt[0] as Dictionary).get("value", "")) + "." + str((tt[2] as Dictionary).get("value", "")) + "()"
	if tt.size() > 2 and (tt[1] is Dictionary) and str((tt[1] as Dictionary).get("type", "")) == "DOT" and (tt[2] is Dictionary):
		return str((tt[0] as Dictionary).get("value", "")) + "." + str((tt[2] as Dictionary).get("value", "")) + "()"
	return str((tt[0] as Dictionary).get("value", "")) + "()"


## Method entry by name in a script user JSON (instance first, then
## static). {} when absent.
func _user_method_entry(info: Dictionary, seg: String) -> Dictionary:
	for list_key in ["instance_methods", "static_methods"]:
		var items: Variant = info.get(list_key, [])
		if items is Array:
			for m in items:
				if m is Dictionary and str((m as Dictionary).get("name", "")) == seg:
					return m
	return {}


## Method entry by name following the JSON extends chain (direct
## members first, then parents via on-demand analysis). Top-level
## classes only. {} when absent everywhere.
func _user_method_entry_chain(tname: String, info: Dictionary, seg: String) -> Dictionary:
	var hit := _user_method_entry(info, seg)
	if not hit.is_empty():
		return hit
	var seen := {str(info.get("name", "")): true}
	var cur := info
	while true:
		var base := str(cur.get("extends", ""))
		if base == "":
			return {}
		var simple := _base_simple(base)
		if seen.has(simple):
			return {}
		seen[simple] = true
		cur = _ensure_script_info(simple)
		if cur.is_empty() or str(cur.get("kind", "")) != "script":
			return {}
		hit = _user_method_entry(cur, seg)
		if not hit.is_empty():
			return hit
	return {}


## Cross-script member probe on an otherwise-silent chain: peeks the
## next DOT segment and consults the target script's user JSON. A
## private flag errors private_use; a deprecated flag warns
## deprecated_use (same messages as same-file uses). Anything else
## stays silent (unknown receivers, public members, line-18 Variant
## rule).
func _check_cross_private(tname: String, tokens: Array, j: int, owner: String) -> void:
	if j >= tokens.size() or not (tokens[j] is Dictionary):
		return
	if str((tokens[j] as Dictionary).get("type", "")) != "DOT":
		return
	if j + 1 >= tokens.size() or not (tokens[j + 1] is Dictionary):
		return
	var nt := str((tokens[j + 1] as Dictionary).get("type", ""))
	if nt != "IDENTIFIER" and nt != "BUILTIN_TYPE" and nt != "KEYWORD":
		return
	var seg := str((tokens[j + 1] as Dictionary).get("value", ""))
	var entry := _user_member_entry(tname, seg)
	if entry.is_empty():
		return
	var tok: Dictionary = tokens[j + 1]
	if not ((entry.get("private", {}) as Dictionary).is_empty()):
		_error_private_use(tname + "." + seg, {"kind": str(entry.get("kind", "")), "decl_owner": str(entry.get("decl_owner", "")), "message": "", "line": 0}, tok, owner)
	if not ((entry.get("dep", {}) as Dictionary).is_empty()):
		_warn_use(str(entry.get("kind", "")), tname + "." + seg, {"dep": entry.get("dep", {})}, tok, owner)


## Static cross-script probe for `ClassName.member` chains whose base
## resolves to nothing local (shadowed names bail out exactly like
## _verify_bare_generic: locals/params, overlays, narrowed env values
## and member vars keep today's silence).
func _check_cross_static(base: String, tokens: Array, j: int, scope: Dictionary, fn: Variant, env: Dictionary, overlay: Dictionary, owner: String) -> void:
	if base == "" or base == "_" or base == "super" or base == "self":
		return
	if (overlay as Dictionary).has(base):
		return
	if (env as Dictionary).has(base):
		return
	if str(_scope_kind(scope, base)) != "":
		return
	for o in [owner, ""]:
		if not _member_var_node(str(o), base).is_empty():
			return
	if base == _script_class and base != "":
		return
	if _script_key_of(base, owner) != "":
		return
	_check_cross_private(base, tokens, j, owner)
	_check_cross_notnull(base, tokens, j, owner)
	_check_cross_maybe(base, tokens, j, scope, fn, env, overlay, owner)
	_check_cross_notnull_maybe(base, tokens, j, scope, fn, env, overlay, owner)


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
		_check_cross_static(base, tokens, j, scope, fn, env, overlay, owner)
		_check_notnull_super(base, tokens, j, scope, fn, env, overlay, owner)
		_check_strict_untyped(base, tokens, j, scope, fn, env, owner)
		var bj := _verify_bare_generic(tokens, i, j, scope, fn, env, overlay, owner)
		if bj >= 0:
			return bj
		return _skip_chain_verify(tokens, j, scope, owner, fn, env, overlay)
	var signal_mode := kind == "signal"
	var static_ctx := kind == "class" or kind == "script"
	var links: Array = []
	var saw_null := false
	var warn_types: Array = []
	var warn_cause := ""
	var ctx := owner
	if kind == "instance":
		var itypes: Array = (fb.get("types", []) as Array).duplicate()
		if _types_all_null(itypes):
			_error_null_seg(tokens, j, owner)
			return _skip_chain_verify(tokens, j, scope, owner, fn, env, overlay)
		if itypes.is_empty():
			_check_strict_untyped(base, tokens, j, scope, fn, env, owner)
			return _skip_chain_verify(tokens, j, scope, owner, fn, env, overlay)
		var eff: Array = []
		for t in itypes:
			var ts := str(t)
			if ts == "null":
				saw_null = true
				continue
			if _aliases.has(ts) or not _alias_def(ts).is_empty():
				var exp := _expand_tree_aliases((_alias_def(ts) as Dictionary).get("tree", {}))
				if bool(exp.get("ok", false)):
					var any_null := false
					for h in _tree_top_heads(exp.get("node", {})):
						if str(h) == "null":
							any_null = true
						else:
							eff.append(str(h))
					if any_null:
						saw_null = true
						continue
			eff.append(ts)
		if saw_null:
			warn_types = itypes.duplicate()
		else:
			warn_cause = _flow_watch_cause(base, fn, scope, owner, env, itypes)
			if warn_cause != "":
				warn_types = itypes.duplicate()
		for t in eff:
			var l := _link_kind_of(str(t), owner)
			if l.is_empty():
				_check_cross_private(str(t), tokens, j, owner)
				_check_cross_notnull(str(t), tokens, j, owner)
				_check_cross_maybe(str(t), tokens, j, scope, fn, env, overlay, owner)
				_check_cross_notnull_maybe(str(t), tokens, j, scope, fn, env, overlay, owner)
				_warn_unresolved_watch(base, tokens, j, warn_types, warn_cause, owner)
				return _skip_chain_verify(tokens, j, scope, owner, fn, env, overlay)
			links.append(l)
		if links.size() == 1 and str(links[0].get("kind", "")) == "script":
			var largs := _link_vartype_args(base, fn, scope, owner, env, str(links[0].get("key", "")))
			if not largs.is_empty():
				(links[0] as Dictionary)["args"] = largs
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
			if str(L.get("kind", "")) == "struct":
				var sname := str(L.get("name", ""))
				var sdef := _struct_def(sname)
				if sdef.is_empty():
					silent = true
					dnames.append(sname)
					continue
				var matched := false
				var fany := false
				var ftypes: Array = []
				for f in (sdef.get("fields", []) as Array):
					if str((f as Dictionary).get("name", "")) == seg:
						matched = true
						fany = bool((f as Dictionary).get("any", false))
						ftypes = ((f as Dictionary).get("types", []) as Array).duplicate()
						break
				if matched:
					found = true
					if fany or ftypes.is_empty():
						silent = true
					else:
						for cn in ftypes:
							var cl := _link_kind_of(str(cn), next_ctx)
							if cl.is_empty():
								silent = true
							else:
								next_links.append(cl)
				else:
					var dv := _verify_seg(["Dictionary"], seg, is_call, false, tokens[j], owner, true)
					var dvt := str(dv.get("vtype", ""))
					if dvt != "":
						found = true
						var dl := _link_kind_of(dvt, next_ctx)
						if dl.is_empty():
							silent = true
						else:
							next_links.append(dl)
					else:
						sure_miss = true
				dnames.append(sname)
				continue
			if str(L.get("kind", "")) == "interface":
				var iname := str(L.get("name", ""))
				var ispec := _iface_spec(iname)
				if ispec.is_empty():
					silent = true
					dnames.append(iname)
					continue
				if is_call:
					var fentry := _iface_method(ispec, seg)
					if fentry.is_empty():
						dnames.append(iname)
						continue
					found = true
					if not _check_iface_call(iname, seg, fentry, tokens, j, scope, fn, env, overlay, owner):
						continue
					var rtypes := _iface_returns(fentry)
					if rtypes.is_empty():
						silent = true
					else:
						for cn in rtypes:
							var cl := _link_kind_of(str(cn), next_ctx)
							if cl.is_empty():
								silent = true
							else:
								next_links.append(cl)
				else:
					var fld := _iface_field(ispec, seg)
					if fld.is_empty():
						dnames.append(iname)
						continue
					found = true
					if bool(fld.get("any", false)) or ((fld.get("types", []) as Array).is_empty()):
						silent = true
					else:
						for cn in (fld.get("types", []) as Array):
							var cl := _link_kind_of(str(cn), next_ctx)
							if cl.is_empty():
								silent = true
							else:
								next_links.append(cl)
				dnames.append(iname)
				continue
			if str(L.get("kind", "")) == "script":
				var r := _script_seg(str(L.get("key", "")), seg, is_call, (L.get("args", []) as Array).duplicate())
				var status := str(r.get("status", ""))
				if status == "found":
					found = true
					var cont: Dictionary = r.get("cont", {})
					var cont_types: Array = (cont.get("types", []) as Array).duplicate()
					if is_call:
						var go := _generic_link_types(str(L.get("key", "")), seg, tokens, j, scope, fn, env, overlay, owner, (L.get("args", []) as Array).duplicate())
						if bool(go.get("applies", false)):
							cont_types = go.get("types", [])
					if not (cont.get("enumvals", []) as Array).is_empty():
						next_links.append({"kind": "enumvals", "vals": (cont.get("enumvals", []) as Array).duplicate(), "dname": str(cont.get("enumname", seg))})
					elif cont.has("signal"):
						signal_mode = true
					elif cont.has("script"):
						next_links.append({"kind": "script", "key": str(cont.get("script", ""))})
						next_ctx = str(cont.get("script", ""))
					else:
						for cn in cont_types:
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
			if not warn_types.is_empty() and not _flow_notnull(base, fn, scope, owner, env):
				_warn_maybe_null(base, seg, warn_types, is_call, tokens[j], owner, warn_cause)
			if is_call:
				_check_notnull_links(links, seg, tokens, j, scope, fn, env, overlay, owner)
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
				if not warn_types.is_empty() and not _flow_notnull(base, fn, scope, owner, env):
					_warn_maybe_null(base, seg, warn_types, true, tokens[j], owner, warn_cause)
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
			if not warn_types.is_empty() and not _flow_notnull(base, fn, scope, owner, env):
				_warn_maybe_null(base, seg, warn_types, false, tokens[j], owner, warn_cause)
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
				_check_notnull_bare(tokens, i, i + 1, scope, fn, env, overlay, owner)
				var bj := _verify_bare_generic(tokens, i, i + 1, scope, fn, env, overlay, owner)
				if bj >= 0:
					i = bj
					continue
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
		var sdef := _struct_base_def(base, fn, scope, owner, env, overlay)
		if sdef.is_empty():
			return close + 1
		return _verify_struct_key(tokens, i, close, sdef, owner)
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


## Struct definition {name} for a subscript base, or {}.
func _struct_base_def(base: String, fn: Variant, scope: Dictionary, owner: String, env: Dictionary, overlay: Dictionary) -> Dictionary:
	var fb := _flow_base(base, fn, scope, owner, env, overlay)
	if str(fb.get("kind", "")) != "instance":
		return {}
	for t in (fb.get("types", []) as Array):
		if not _struct_def(str(t)).is_empty():
			return {"name": str(t)}
	return {}


## Struct key access for an already-resolved definition: single
## string-literal keys resolve (unknown keys error); anything else
## skips silently.
func _verify_struct_key(tokens: Array, i: int, close: int, def: Dictionary, owner: String) -> int:
	var inner: Array = []
	if close > i + 2:
		inner = tokens.slice(i + 2, close)
	if inner.size() != 1 or not (inner[0] is Dictionary):
		return close + 1
	var tok: Dictionary = inner[0]
	if str(tok.get("type", "")) != "STRING":
		return close + 1
	var raw := str(tok.get("value", ""))
	var key := raw
	if raw.length() >= 2:
		key = raw.substr(1, raw.length() - 2)
	var sdef := _struct_def(str(def.get("name", "")))
	if sdef.is_empty():
		return close + 1
	for f in (sdef.get("fields", []) as Array):
		if str((f as Dictionary).get("name", "")) == key:
			return close + 1
	_error(ERR_MISSING_MEMBER, "type '" + str(def.get("name", "")) + "' has no member '" + key + "'", int(tok.get("line", 0)), int(tok.get("column", 0)), owner)
	return close + 1


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
	if yname == "" or yname == "null" or not _type_known(yname):
		return {}
	var eq := positive
	if neg:
		eq = not eq
	return {"name": _vt_val(tokens, s), "types": [yname], "eq": eq}


## Recognizes `x == null` / `x != null` (either order, leading not/!
## flips). Yields exact-nil heads: member access on them errors with
## null_access, anything else stays as before. `x is null` is NOT
## accepted (Godot rejects it at parse time).
func _guard_null(tokens: Array) -> Dictionary:
	var be := _guard_bounds(tokens)
	var s := int(be[0])
	var e := int(be[1])
	var neg := false
	if s < e and ((_vt_type(tokens, s) == "KEYWORD" and _vt_val(tokens, s) == "not") or (_vt_type(tokens, s) == "OPERATOR" and _vt_val(tokens, s) == "!")):
		neg = true
		s += 1
	if e - s != 3:
		return {}
	if _vt_type(tokens, s + 1) != "OPERATOR":
		return {}
	var op := _vt_val(tokens, s + 1)
	if op != "==" and op != "!=":
		return {}
	var vname := ""
	if _vt_type(tokens, s) == "IDENTIFIER" and _vt_type(tokens, s + 2) == "NULL":
		vname = _vt_val(tokens, s)
	elif _vt_type(tokens, s) == "NULL" and _vt_type(tokens, s + 2) == "IDENTIFIER":
		vname = _vt_val(tokens, s + 2)
	else:
		return {}
	if vname == "" or vname == "_":
		return {}
	var eq := op == "=="
	if neg:
		eq = not eq
	return {"name": vname, "types": ["null"], "eq": eq}


## Recognizes bare `x` / `not x` / `!x` truthiness checks. Shapes only:
## object validation happens at application (env visible there), where
## non-objects are ignored. Returns {name, bare_null, eq} with
## null-guard polarity (`not x` behaves like `x == null`, `x` like
## `x != null` for the flag; `==`-style heads for the null side).
static func _guard_bare_null(tokens: Array) -> Dictionary:
	var be := _guard_bounds(tokens)
	var s := int(be[0])
	var e := int(be[1])
	var neg := false
	if s < e and ((_vt_type(tokens, s) == "KEYWORD" and _vt_val(tokens, s) == "not") or (_vt_type(tokens, s) == "OPERATOR" and _vt_val(tokens, s) == "!")):
		neg = true
		s += 1
	if e - s != 1:
		return {}
	if _vt_type(tokens, s) != "IDENTIFIER":
		return {}
	var vname := _vt_val(tokens, s)
	if vname == "" or vname == "_":
		return {}
	return {"name": vname, "bare_null": true, "eq": neg}


## Applies one guard's holds/fails narrowing to a then/else env pair
## in place (target validity plus bare object-ness checked inside;
## no-op when invalid). Covers null guards, bare truthiness and
## type-test guards. Shared by `if` and every `elif` branch: callers
## own the chaining (each `elif` narrows from the accumulated
## previous-failed state, never from entry). `env` is the state where
## the condition runs (entry for `if`, accumulated rest for `elif`),
## used only for the bare object-ness check.
func _narrow_guard_envs(g: Dictionary, fn: Variant, scope: Dictionary, owner: String, env: Dictionary, then_env: Dictionary, else_env: Dictionary) -> void:
	if g.is_empty():
		return
	var fnd: Dictionary = fn if fn is Dictionary else {}
	var target := _free_var_target(str(g.get("name", "")), fnd, scope, owner)
	if target.is_empty() or target.has("bad"):
		return
	if bool(g.get("bare_null", false)):
		var bn := str(g.get("name", ""))
		if bn != "" and _guard_notnull_object(bn, fn, scope, owner, env):
			if bool(g.get("eq", true)):
				_env_set(then_env, bn, ["null"], {})
				(else_env as Dictionary)[ENV_NOTNULL_PREFIX + bn] = true
			else:
				(then_env as Dictionary)[ENV_NOTNULL_PREFIX + bn] = true
				_env_set(else_env, bn, ["null"], {})
	elif bool(g.get("eq", true)):
		_env_set(then_env, str(g.get("name", "")), g.get("types", []), {})
	else:
		_env_set(else_env, str(g.get("name", "")), g.get("types", []), {})
	if _is_null_guard(g):
		var nn := str(g.get("name", ""))
		if nn != "":
			if bool(g.get("eq", true)):
				(else_env as Dictionary)[ENV_NOTNULL_PREFIX + nn] = true
			else:
				(then_env as Dictionary)[ENV_NOTNULL_PREFIX + nn] = true
	if _is_typetest_guard(g):
		var tn := str(g.get("name", ""))
		if tn != "":
			if bool(g.get("eq", true)):
				(then_env as Dictionary)[ENV_NOTNULL_PREFIX + tn] = true
			else:
				(else_env as Dictionary)[ENV_NOTNULL_PREFIX + tn] = true


## True when the primary-false state of a guard may still be null:
## `!=`/failing null checks, failing type tests, `x` (bare truthy
## failing means null-ish). Used by guard-clause soundness with elifs
## (branches running in a possibly-null state must all return).
static func _guard_false_may_be_null(g: Dictionary) -> bool:
	if bool(g.get("bare_null", false)):
		return not bool(g.get("eq", true))
	if _is_typetest_guard(g):
		return bool(g.get("eq", true))
	return not bool(g.get("eq", true))


## Applies a null-family guard ({types ["null"]} or bare-truthiness
## shape) to an env in place: the null side gets exact heads, the
## non-null side gets the flag. A type-test guard (`is` and friends
## against a non-null type) sets the flag outright: `while` bodies run
## on the holding side. Used by `while` bodies, which otherwise narrow
## nothing. Validates the target and, for bare shapes, object-ness,
## exactly like `if`.
func _apply_null_family_guard(cond: Array, fn: Variant, scope: Dictionary, owner: String, env: Dictionary) -> void:
	var g := _guard_null(cond)
	if g.is_empty():
		g = _guard_bare_null(cond)
	if not g.is_empty():
		var fnd: Dictionary = fn if fn is Dictionary else {}
		var target := _free_var_target(str(g.get("name", "")), fnd, scope, owner)
		if target.is_empty() or target.has("bad"):
			return
		if bool(g.get("bare_null", false)) and not _guard_notnull_object(str(g.get("name", "")), fn, scope, owner, env):
			return
		if bool(g.get("eq", true)):
			_env_set(env, str(g.get("name", "")), ["null"], {})
		else:
			(env as Dictionary)[ENV_NOTNULL_PREFIX + str(g.get("name", ""))] = true
		return
	var t := _flow_guard(cond, fn, scope, owner)
	if not _is_typetest_guard(t):
		return
	var tfnd: Dictionary = fn if fn is Dictionary else {}
	var tname := str(t.get("name", ""))
	if tname == "":
		return
	var ttarget := _free_var_target(tname, tfnd, scope, owner)
	if ttarget.is_empty() or ttarget.has("bad"):
		return
	(env as Dictionary)[ENV_NOTNULL_PREFIX + tname] = true


## Branch env for one `match` branch: a sole `null` pattern on a bare
## identifier subject narrows to exact null, anything else duplicates.
func _match_null_env(node: Dictionary, branch: Dictionary, fn: Variant, scope: Dictionary, owner: String, env: Dictionary) -> Dictionary:
	var benv := env.duplicate()
	var stoks := _trim_trivia(_as_tokens(node.get("subject", null)))
	if stoks.size() != 1 or not (stoks[0] is Dictionary) or str((stoks[0] as Dictionary).get("type", "")) != "IDENTIFIER":
		return benv
	var vname := str((stoks[0] as Dictionary).get("value", ""))
	if vname == "" or vname == "_":
		return benv
	var ptoks := _trim_trivia(_as_tokens((branch as Dictionary).get("pattern", null)))
	if ptoks.size() != 1 or not (ptoks[0] is Dictionary) or str((ptoks[0] as Dictionary).get("type", "")) != "NULL":
		return benv
	var fnd: Dictionary = fn if fn is Dictionary else {}
	var target := _free_var_target(vname, fnd, scope, owner)
	if target.is_empty() or target.has("bad"):
		return benv
	_env_set(benv, vname, ["null"], {})
	return benv


## True when vname is provably an Object in flow (env heads or
## declaration types, every head object-like): unknown, dynamic and
## value-typed names stay out, so truthiness never misreads them.
func _guard_notnull_object(vname: String, fn: Variant, scope: Dictionary, owner: String, env: Dictionary) -> bool:
	if vname == "" or vname == "_":
		return false
	if (env as Dictionary).has(vname):
		var heads: Variant = (env as Dictionary)[vname]
		if not (heads is Array) or (heads as Array).is_empty():
			return false
		for h in heads:
			if not _is_object_like(str(h)):
				return false
		return true
	var node := _base_decl_node(vname, fn, scope, owner, env)
	if node.is_empty():
		return false
	var ntype := str(node.get("type", ""))
	var heads: Array = []
	if str(_scope_kind(scope, vname)) == "param" or ntype == "PARAM":
		heads = _flow_decl_types(node, false, true)
	else:
		heads = _flow_decl_types(node, str(ntype) == "CONST_DECL", false)
	if heads.is_empty():
		return false
	for h in heads:
		if not _is_object_like(str(h)):
			return false
	return true


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


## Any recognized guard: typeof first, then `is`, then `== null`,
## then bare truthiness, then is_instance_of. Shapes are mutually
## exclusive; first hit wins.
func _flow_guard(tokens: Array, fn: Variant, scope: Dictionary, owner: String) -> Dictionary:
	var g := _guard_typeof(tokens)
	if not g.is_empty():
		return g
	g = _guard_is(tokens)
	if not g.is_empty():
		return g
	g = _guard_null(tokens)
	if not g.is_empty():
		return g
	g = _guard_bare_null(tokens)
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


## Flow env trees ride under "@tree:"<name> keys (plain identifiers
## can never collide): flat heads stay the source of truth for links,
## trees add generics for argument inference. Trees are never mutated
## in place, so env.duplicate() sharing is safe.
const ENV_TREE_PREFIX := "@tree:"


## Flow notnull marks ride under "@notnull:"<name> keys: set by
## notnull @var facts and by the non-null side of `==`/`!=` null
## guards, read by the `= null` assignment check.
const ENV_NOTNULL_PREFIX := "@notnull:"
## Flow watch marks ride under "@watch:"<name> keys: set when a name
## is assigned a call to a `@return nullable` function, so the tainted
## result warns on unguarded use. Cleared by any other assignment.
const ENV_WATCH_PREFIX := "@watch:"


## Tree recorded for a name in env, {} when absent. Pure.
static func _env_tree(env: Dictionary, vname: String) -> Dictionary:
	var t: Variant = env.get(ENV_TREE_PREFIX + vname, {})
	if t is Dictionary:
		return t
	return {}


## Records flat heads plus an optional tree for a name. Pure storage.
static func _env_set(env: Dictionary, vname: String, heads: Array, tree: Dictionary) -> void:
	(env as Dictionary)[vname] = heads.duplicate()
	if tree.is_empty():
		(env as Dictionary).erase(ENV_TREE_PREFIX + vname)
	else:
		(env as Dictionary)[ENV_TREE_PREFIX + vname] = tree


## True when a declaration node already owns a usable type (explicit
## annotation, vartype or value inference): call-result tracking only
## fills genuinely unknown targets, never shadows declarations.
func _decl_has_type(node: Dictionary) -> bool:
	if node.is_empty():
		return false
	if node.has("var_ann") or node.has("param_ann") or node.has("vartype_ann"):
		return true
	if _vartype_name(node) != "":
		return true
	if str(node.get("type", "")) == "CONST_DECL" or str(node.get("op", "")) == ":=":
		if _infer_var_value(node.get("value", null)) != "":
			return true
	return false


## True when a chain base is a declared-but-untyped slot (param,
## local, const or member without any type: no @var/@param stamp, no
## vartype, no `:=`/const inference). env/overlay-shadowed names read
## as opaque (never untyped here); totally unknown names are not
## slots. Used by strict-untyped (receivers and boundary args).
func _untyped_slot(base: String, fn: Variant, scope: Dictionary, owner: String, env: Dictionary) -> bool:
	if base == "" or base == "_" or base == "self" or base == "super":
		return false
	var node := _base_decl_node(base, fn, scope, owner, env)
	if node.is_empty():
		return false
	return not _decl_has_type(node)


## Resolves a bare-call callee for assignment tracking (same guards as
## _verify_bare_generic): {} when the name can be a value.
func _assign_callee(name: String, scope: Dictionary, fn: Variant, env: Dictionary, owner: String) -> Dictionary:
	if name == "" or name == "_":
		return {}
	if str(_scope_kind(scope, name)) != "":
		return {}
	if (env as Dictionary).has(name):
		return {}
	for o in [owner, ""]:
		if not _member_var_node(str(o), name).is_empty():
			return {}
	var node := _script_func_node(owner, name)
	if node.is_empty() and owner != "":
		node = _script_func_node("", name)
	return node


## Applies `@return nullable` (and explicit-null) call-result taint
## on assignment: the flag makes unguarded member use warn, and
## undeclared targets resolve with the callee's declared return heads
## so the chain has types to warn through. Bare, self, lambda-held
## and same-file member calls resolve to nodes (zero-arg included);
## cross-file static calls resolve through the callee's user JSON
## signature (`return_types`/`nullable_return` our analyzer maintains
## there). Anything else stays silent.
func _apply_return_taint(vname: String, vtoks: Array, scope: Dictionary, fn: Variant, env: Dictionary, owner: String) -> void:
	var node := _taint_rhs_node(vtoks, scope, fn, env, owner)
	if not node.is_empty():
		if _func_returns_nullable(node):
			(env as Dictionary)[ENV_WATCH_PREFIX + vname] = true
		if (_func_returns_nullable(node) or _return_ann_has_null(node)) and not _decl_has_type(_assign_target(vname, fn, scope, owner, env)):
			var rtypes := _return_ann_types(node)
			if not rtypes.is_empty():
				_env_set(env, vname, rtypes, {})
		return
	var jsig := _taint_json_sig(vtoks, scope, fn, env, owner)
	if jsig.is_empty():
		return
	if bool(jsig.get("nullable", false)):
		(env as Dictionary)[ENV_WATCH_PREFIX + vname] = true
	var jtypes: Array = jsig.get("types", [])
	if not jtypes.is_empty() and not _decl_has_type(_assign_target(vname, fn, scope, owner, env)):
		_env_set(env, vname, jtypes, {})


## Cross-file static return signature behind an assignment RHS shaped
## `Lib.seg(...)` ({} otherwise): delegates shape + shadow checks to
## _json_return_sig (which may analyze the target on demand).
func _taint_json_sig(vtoks: Array, scope: Dictionary, fn: Variant, env: Dictionary, owner: String) -> Dictionary:
	var tt := _trim_trivia(vtoks)
	if tt.size() < 5 or not (tt[0] is Dictionary):
		return {}
	if str((tt[0] as Dictionary).get("type", "")) != "IDENTIFIER":
		return {}
	if tt.size() < 2 or not (tt[1] is Dictionary) or str((tt[1] as Dictionary).get("type", "")) != "DOT":
		return {}
	if tt.size() < 3 or not (tt[2] is Dictionary) or str((tt[2] as Dictionary).get("type", "")) not in ["IDENTIFIER", "BUILTIN_TYPE", "KEYWORD"]:
		return {}
	if tt.size() < 4 or not (tt[3] is Dictionary) or str((tt[3] as Dictionary).get("type", "")) != "LPAREN":
		return {}
	if _match_close(tt, 3) != tt.size() - 1:
		return {}
	return _json_return_sig(str((tt[0] as Dictionary).get("value", "")), str((tt[2] as Dictionary).get("value", "")), scope, fn, env, owner)


## Return signature behind a cross-file call (`Lib.seg()` static, or
## `base.seg()` on a shadowed base whose env-aware type resolves to a
## script): {"nullable", "types"} from the target script's user JSON
## (stale files without the keys read as non-nullable; missing files
## are analyzed on demand). {} when no script resolves or the method
## is missing. Union bases merge MAYBE: any nullable arm flags, heads
## come from the first resolving arm.
func _json_return_sig(base: String, seg: String, scope: Dictionary, fn: Variant, env: Dictionary, owner: String) -> Dictionary:
	if base == "" or base == "_" or base == "self" or base == "super" or seg == "" or seg == "_" or seg == "new":
		return {}
	if _script_class != "" and base == _script_class:
		return {}
	if str(_scope_kind(scope, base)) == "" and not (env as Dictionary).has(base):
		var shadowed := false
		for o in [owner, ""]:
			if not _member_var_node(str(o), base).is_empty():
				shadowed = true
				break
		if not shadowed:
			return _json_static_return_sig(base, seg)
	var fb := _flow_base(base, fn, scope, owner, env, {})
	if str(fb.get("kind", "")) != "instance":
		return {}
	var out := {}
	for t in ((fb as Dictionary).get("types", []) as Array):
		var ts := str(t)
		if ts == "" or ts == "dynamic" or ts == "null" or ts == "Variant":
			continue
		var info := _ensure_script_info(ts)
		if info.is_empty() or str(info.get("kind", "")) != "script":
			continue
		if _script_class != "" and str(info.get("class_name", "")) == _script_class:
			continue
		var entry := _user_method_entry_chain(ts, info, seg)
		if entry.is_empty():
			continue
		var rtypes: Array = ((entry as Dictionary).get("return_types", []) as Array).duplicate()
		var flagged := bool((entry as Dictionary).get("nullable_return", false))
		if not flagged:
			for h in rtypes:
				if str(h) == "null":
					flagged = true
					break
		if out.is_empty():
			out = {"nullable": flagged, "types": rtypes}
		elif flagged:
			out["nullable"] = true
	return out


## Return signature behind a cross-file static call (`Lib.seg()`):
## {"nullable", "types"} from the target script's user JSON (missing
## files are analyzed on demand). {} when the class is unknown, not a
## script, or the method is missing.
func _json_static_return_sig(tname: String, seg: String) -> Dictionary:
	var info := _ensure_script_info(tname)
	if info.is_empty() or str(info.get("kind", "")) != "script":
		return {}
	if _script_class != "" and str(info.get("class_name", "")) == _script_class:
		return {}
	var entry := _user_method_entry_chain(tname, info, seg)
	if entry.is_empty():
		return {}
	var rtypes: Array = ((entry as Dictionary).get("return_types", []) as Array).duplicate()
	var flagged := bool((entry as Dictionary).get("nullable_return", false))
	if not flagged:
		for t in rtypes:
			if str(t) == "null":
				flagged = true
				break
	return {"nullable": flagged, "types": rtypes}


## Callee FUNC_DECL/LAMBDA behind a `recv.seg(...)` assignment RHS
## ({} otherwise). Resolves same-file receivers only: self, super
## (parent key in this file's tables), static class refs, and
## instance bases whose env-aware script type resolves (params,
## locals, members, `is`-narrowed values). Maybe-direction is ANY:
## one nullable-returning arm taints. Engine, dynamic, unknown and
## cross-file receivers stay out (the JSON path covers static ones).
func _taint_member_node(recv: String, seg: String, fn: Variant, scope: Dictionary, owner: String, env: Dictionary) -> Dictionary:
	if recv == "" or recv == "_" or seg == "" or seg == "_" or seg == "new":
		return {}
	if recv == "self":
		return _script_func_node(owner, seg)
	if recv == "super":
		var b: String = _script_extends if owner == "" else str(_class_extends.get(owner, ""))
		if b == "":
			return {}
		var key := _resolve_private_owner(b, owner)
		if key == "" or not _members.has(key):
			return {}
		return _script_func_node(key, seg)
	var skey := _script_key_of(recv, owner)
	if skey != "":
		return _script_func_node(skey, seg)
	if recv == _script_class and recv != "":
		return _script_func_node(owner, seg)
	var lamb := _lambda_value_node(recv, fn, scope, owner, env, {})
	if seg == "call" and not lamb.is_empty():
		return lamb
	var fb := _flow_base(recv, fn, scope, owner, env, {})
	if str(fb.get("kind", "")) != "instance":
		return {}
	for t in ((fb as Dictionary).get("types", []) as Array):
		var ts := str(t)
		if ts == "" or ts == "dynamic" or ts == "null" or ts == "Variant":
			continue
		var lk := _link_kind_of(ts, owner)
		if (lk as Dictionary).is_empty() or str((lk as Dictionary).get("kind", "")) != "script":
			continue
		var node := _script_func_node(str((lk as Dictionary).get("key", "")), seg)
		if node.is_empty():
			continue
		if _func_returns_nullable(node) or _return_ann_has_null(node):
			return node
	return {}


## Callee FUNC_DECL behind an assignment RHS shaped as a bare or
## self call ({} otherwise). Mirrors the _flow_assign_call shapes
## with a >=3 token gate so `var r = make()` counts.
func _taint_rhs_node(vtoks: Array, scope: Dictionary, fn: Variant, env: Dictionary, owner: String) -> Dictionary:
	if vtoks.size() < 3:
		return {}
	if not (vtoks[0] is Dictionary):
		return {}
	var t0 := str((vtoks[0] as Dictionary).get("type", ""))
	if t0 == "IDENTIFIER" and vtoks.size() > 1 and (vtoks[1] is Dictionary) and str((vtoks[1] as Dictionary).get("type", "")) == "LPAREN" and _match_close(vtoks, 1) == vtoks.size() - 1:
		var cname := str((vtoks[0] as Dictionary).get("value", ""))
		var lamb := _lambda_value_node(cname, fn, scope, owner, env, {})
		if not lamb.is_empty():
			return lamb
		return _assign_callee(cname, scope, fn, env, owner)
	if t0 == "KEYWORD" and str((vtoks[0] as Dictionary).get("value", "")) == "self" and vtoks.size() > 3 and (vtoks[1] is Dictionary) and str((vtoks[1] as Dictionary).get("type", "")) == "DOT" and (vtoks[2] is Dictionary) and (vtoks[3] is Dictionary) and str((vtoks[3] as Dictionary).get("type", "")) == "LPAREN" and _match_close(vtoks, 3) == vtoks.size() - 1:
		return _script_func_node(owner, str((vtoks[2] as Dictionary).get("value", "")))
	if t0 == "IDENTIFIER" and vtoks.size() > 4 and (vtoks[1] is Dictionary) and str((vtoks[1] as Dictionary).get("type", "")) == "DOT" and (vtoks[2] is Dictionary) and str((vtoks[2] as Dictionary).get("type", "")) in ["IDENTIFIER", "BUILTIN_TYPE", "KEYWORD"] and (vtoks[3] is Dictionary) and str((vtoks[3] as Dictionary).get("type", "")) == "LPAREN" and _match_close(vtoks, 3) == vtoks.size() - 1:
		return _taint_member_node(str((vtoks[0] as Dictionary).get("value", "")), str((vtoks[2] as Dictionary).get("value", "")), fn, scope, owner, env)
	if (t0 == "KEYWORD" and str((vtoks[0] as Dictionary).get("value", "")) == "super") and vtoks.size() > 4 and (vtoks[1] is Dictionary) and str((vtoks[1] as Dictionary).get("type", "")) == "DOT" and (vtoks[2] is Dictionary) and str((vtoks[2] as Dictionary).get("type", "")) in ["IDENTIFIER", "BUILTIN_TYPE", "KEYWORD"] and (vtoks[3] is Dictionary) and str((vtoks[3] as Dictionary).get("type", "")) == "LPAREN" and _match_close(vtoks, 3) == vtoks.size() - 1:
		return _taint_member_node("super", str((vtoks[2] as Dictionary).get("value", "")), fn, scope, owner, env)
	return {}


## Assignment-state invalidation for `vname = RHS` EXPR_STMT
## reassignments and (nonnull-only) declaration initializers (vtoks
## are the RHS tokens; a null or unknown init stays lenient — a null
## init is the cross-function placeholder idiom, which
## intra-procedural flow cannot see through): runtime truth replaces
## flow memory. Bare `null` sets exact heads (later member use errors
## null_access, even for nullable slots); provably-non-null RHS
## (value literals, array/dict literals, `self`, `X.new()`, calls to
## notnull-returning functions incl. cross-file ones with clean
## signatures) reverts heads to the declaration and, in distrust
## only, marks non-null (trust keeps incidental state silent — only
## explicit user checks, i.e. guard marks, establish intent there);
## anything else fully resets (heads, tree, watch and flow marks go —
## a stale guard mark must not survive an unknown write).
## Declaration stamps (`notnull` @var/@param) are permanent and never
## reset: only flow marks clear. `notnull` targets still error on
## `= null` first (via _check_null_assign); the env update follows
## regardless, so follow-on uses report runtime truth too. Member
## targets (`self.x`) never reach here — env cannot represent them.
func _apply_assign_invalidation(vname: String, vtoks: Array, scope: Dictionary, fn: Variant, env: Dictionary, owner: String, is_init := false) -> void:
	if vname == "" or vname == "_":
		return
	var tt := _trim_trivia(vtoks)
	if tt.is_empty():
		return
	if tt.size() == 1 and (tt[0] is Dictionary) and str((tt[0] as Dictionary).get("type", "")) == "NULL":
		if is_init:
			return
		_env_set(env, vname, ["null"], {})
		(env as Dictionary).erase(ENV_NOTNULL_PREFIX + vname)
		(env as Dictionary).erase(ENV_WATCH_PREFIX + vname)
		return
	if _rhs_is_nonnull(tt, scope, fn, env, owner):
		(env as Dictionary).erase(vname)
		(env as Dictionary).erase(ENV_TREE_PREFIX + vname)
		(env as Dictionary).erase(ENV_WATCH_PREFIX + vname)
		if _null_distrust():
			(env as Dictionary)[ENV_NOTNULL_PREFIX + vname] = true
		return
	if is_init:
		return
	(env as Dictionary).erase(vname)
	(env as Dictionary).erase(ENV_TREE_PREFIX + vname)
	(env as Dictionary).erase(ENV_WATCH_PREFIX + vname)
	(env as Dictionary).erase(ENV_NOTNULL_PREFIX + vname)


## True when RHS tokens are provably non-null at runtime: value
## literals, whole array/dict literals, bare `self`, any `X.new()`
## construction, or a call resolving (same-file or cross-file JSON)
## to a notnull-returning function with no null arm. Pure.
func _rhs_is_nonnull(tt: Array, scope: Dictionary, fn: Variant, env: Dictionary, owner: String) -> bool:
	if tt.is_empty() or not (tt[0] is Dictionary):
		return false
	if tt.size() == 1:
		var ty := str((tt[0] as Dictionary).get("type", ""))
		if ty == "INT" or ty == "FLOAT" or ty == "STRING" or ty == "BOOL":
			return true
		if ty == "KEYWORD" and str((tt[0] as Dictionary).get("value", "")) == "self":
			return true
		return false
	var first := str((tt[0] as Dictionary).get("type", ""))
	var last := str((tt[tt.size() - 1] as Dictionary).get("type", ""))
	if first == "LBRACKET" and last == "RBRACKET" and _match_close(tt, 0) == tt.size() - 1:
		return true
	if first == "LBRACE" and last == "RBRACE" and _match_close(tt, 0) == tt.size() - 1:
		return true
	if tt.size() > 4 and first == "IDENTIFIER" and (tt[1] is Dictionary) and str((tt[1] as Dictionary).get("type", "")) == "DOT" and (tt[2] is Dictionary) and str((tt[2] as Dictionary).get("value", "")) == "new" and (tt[3] is Dictionary) and str((tt[3] as Dictionary).get("type", "")) == "LPAREN" and _match_close(tt, 3) == tt.size() - 1:
		return true
	var node := _taint_rhs_node(tt, scope, fn, env, owner)
	if not node.is_empty():
		var ann: Variant = (node as Dictionary).get("return_ann", {})
		if ann is Dictionary and bool((ann as Dictionary).get("notnull", false)):
			return true
		return false
	var jsig := _taint_json_sig(tt, scope, fn, env, owner)
	if jsig.is_empty():
		return false
	if not bool(jsig.get("nullable", false)):
		var has_null := false
		for h in (jsig.get("types", []) as Array):
			if str(h) == "null":
				has_null = true
				break
		if not has_null and not (jsig.get("types", []) as Array).is_empty():
			return true
	return false


## Tracks `name = f(...)` / `var name[ :=] f(...)` call results in env
## (flat heads plus tree) when the target has no declared type and the
## substituted return is non-dynamic. Bare and self calls only; pure
## (the statement's own verification reports call errors).
func _flow_assign_call(vname: String, vtoks: Array, target: Dictionary, scope: Dictionary, fn: Variant, env: Dictionary, owner: String) -> void:
	if vname == "":
		return
	(env as Dictionary).erase(ENV_WATCH_PREFIX + vname)
	_apply_return_taint(vname, vtoks, scope, fn, env, owner)
	if vtoks.size() < 4:
		return
	if not (vtoks[0] is Dictionary):
		return
	var node := {}
	var slices: Array = []
	var disp := ""
	var t0 := str((vtoks[0] as Dictionary).get("type", ""))
	if t0 == "IDENTIFIER" and vtoks.size() > 1 and (vtoks[1] is Dictionary) and str((vtoks[1] as Dictionary).get("type", "")) == "LPAREN" and _match_close(vtoks, 1) == vtoks.size() - 1:
		node = _assign_callee(str((vtoks[0] as Dictionary).get("value", "")), scope, fn, env, owner)
		if node.is_empty():
			return
		slices = _split_arg_slices(vtoks, 1)
		disp = "'" + str((vtoks[0] as Dictionary).get("value", "")) + "'"
	elif t0 == "KEYWORD" and str((vtoks[0] as Dictionary).get("value", "")) == "self" and vtoks.size() > 3 and (vtoks[1] is Dictionary) and str((vtoks[1] as Dictionary).get("type", "")) == "DOT" and (vtoks[2] is Dictionary) and (vtoks[3] is Dictionary) and str((vtoks[3] as Dictionary).get("type", "")) == "LPAREN" and _match_close(vtoks, 3) == vtoks.size() - 1:
		node = _script_func_node(owner, str((vtoks[2] as Dictionary).get("value", "")))
		if node.is_empty():
			return
		slices = _split_arg_slices(vtoks, 3)
		disp = "'" + str((vtoks[2] as Dictionary).get("value", "")) + "'"
	else:
		return
	var r := _instantiate_generic_call(node, disp, slices, scope, fn, env, {}, owner)
	if not bool(r.get("ok", false)) or not bool(r.get("generic", false)):
		return
	var ret: Dictionary = r.get("ret", {})
	if ret.is_empty() or str(ret.get("kind", "")) == "any":
		return
	if _decl_has_type(target):
		return
	_env_set(env, vname, _tree_top_heads(ret), ret)


## True for a null guard ({types ["null"]}, from `==`/`!=` or
## `typeof`/`is_instance_of` NIL forms): the non-null side carries a
## notnull mark instead of trimmed heads (plain `Node` stays lenient).
static func _is_null_guard(g: Dictionary) -> bool:
	var types: Array = g.get("types", [])
	return types.size() == 1 and str(types[0]) == "null"


## True for a type-test guard (`is`, `is_instance_of`, `typeof`
## against a non-null type): the side where the test HOLDS ran on a
## non-null value (proven against the engine: `null is Node` is
## false). Excludes NIL forms (owned by _is_null_guard) and `Variant`
## tests (`null is Variant` is true, so those prove nothing), plus
## bare truthiness (shapes, not type tests).
static func _is_typetest_guard(g: Dictionary) -> bool:
	if g.is_empty() or bool(g.get("bare_null", false)):
		return false
	var types: Array = g.get("types", [])
	if types.is_empty():
		return false
	for t in types:
		var ts := str(t)
		if ts == "null" or ts == "Variant" or ts == "dynamic":
			return false
	return true


## notnull state of a variable in flow: an explicit env mark (notnull
## @var facts, non-null guard sides) or a notnull @var/@param stamp on
## its declaration (locals, params, consts, members). Anything else
## (including lambda-param shadowing, which this path cannot see)
## reads as nullable.
func _flow_notnull(vname: String, fn: Variant, scope: Dictionary, owner: String, env: Dictionary) -> bool:
	if vname == "" or vname == "_":
		return false
	if (env as Dictionary).has(ENV_NOTNULL_PREFIX + vname):
		return true
	var node := _base_decl_node(vname, fn, scope, owner, env)
	if node.is_empty():
		return false
	for ak in ["var_ann", "param_ann", "return_ann"]:
		var ann: Variant = node.get(ak, {})
		if ann is Dictionary and bool((ann as Dictionary).get("notnull", false)):
			return true
	return false


## Watch cause for unguarded member use of a chain base: "declared"
## for explicit `nullable` marks (stamps, mid-function @var facts via
## the env taint flag, call-result taint), "policy" for
## implicitly-nullable heads under distrust, "" when silent. notnull
## state (mark, stamp, guard) always wins; exact-null belongs to the
## null_access error path, not here.
func _flow_watch_cause(base: String, fn: Variant, scope: Dictionary, owner: String, env: Dictionary, itypes: Array) -> String:
	if base == "" or base == "_":
		return ""
	if _flow_notnull(base, fn, scope, owner, env):
		return ""
	if _types_all_null(itypes):
		return ""
	if (env as Dictionary).has(ENV_WATCH_PREFIX + base):
		return "declared"
	var node := _base_decl_node(base, fn, scope, owner, env)
	if not node.is_empty():
		for ak in ["var_ann", "param_ann"]:
			var ann: Variant = node.get(ak, {})
			if ann is Dictionary and bool((ann as Dictionary).get("nullable", false)):
				return "declared"
	if _heads_have_null(itypes):
		return "declared"
	if _null_distrust() and _watchable_heads(itypes):
		return "policy"
	return ""


## True when heads carry a top-level `null` arm (direct or via an
## alias expansion): the declared-maybe behind boundary argument
## checks. Mirrors the chain saw_null expansion; failed expansions
## read as absent on both sides.
func _heads_have_null(itypes: Array) -> bool:
	for t in itypes:
		var ts := str(t)
		if ts == "null":
			return true
		if _aliases.has(ts) or not _alias_def(ts).is_empty():
			var exp := _expand_tree_aliases((_alias_def(ts) as Dictionary).get("tree", {}))
			if bool(exp.get("ok", false)):
				for h in _tree_top_heads(exp.get("node", {})):
					if str(h) == "null":
						return true
	return false


## True when any head can implicitly hold null under distrust
## (Object-derived, expanding aliases): value types, arrays,
## dictionaries, dynamic and empty slots stay out. Explicit `Variant`
## needs no branch: member use through it already errors
## `missing_method` (it links as an engine type with no members), so
## both modes stay equally strict there by pre-existing design.
## Roster-known heads are analyzed on demand first, so the first
## touch warns exactly like later ones (no order dependence).
func _watchable_heads(itypes: Array) -> bool:
	for t in itypes:
		var ts := str(t)
		if _is_object_like(ts):
			return true
		if ts == "" or ts == "dynamic" or ts == "null" or ts == "Variant":
			continue
		if _roster_has(ts):
			_ensure_script_info(ts)
			if _is_object_like(ts):
				return true
		if _aliases.has(ts) or not _alias_def(ts).is_empty():
			var exp := _expand_tree_aliases((_alias_def(ts) as Dictionary).get("tree", {}))
			if bool(exp.get("ok", false)):
				for h in _tree_top_heads(exp.get("node", {})):
					var hs := str(h)
					if _is_object_like(hs):
						return true
					if _roster_has(hs):
						_ensure_script_info(hs)
						if _is_object_like(hs):
							return true
	return false


## Tracks `name = ...` reassignments: generic call results (see
## _flow_assign_call) plus the `= null` check against notnull state.
func _flow_assign_stmt(node: Dictionary, scope: Dictionary, fn: Variant, env: Dictionary, owner: String) -> void:
	var toks := _as_tokens(node.get("expr", null))
	_check_null_assign(toks, node, scope, fn, env, owner)
	var tt := _trim_trivia(toks)
	if tt.size() >= 3 and (tt[0] is Dictionary) and str((tt[0] as Dictionary).get("type", "")) == "IDENTIFIER" and (tt[1] is Dictionary) and str((tt[1] as Dictionary).get("type", "")) == "OPERATOR" and str((tt[1] as Dictionary).get("value", "")) == "=":
		_apply_assign_invalidation(str((tt[0] as Dictionary).get("value", "")), tt.slice(2), scope, fn, env, owner)
	if toks.size() < 4:
		return
	if not (toks[0] is Dictionary) or str((toks[0] as Dictionary).get("type", "")) != "IDENTIFIER":
		return
	if not (toks[1] is Dictionary) or str((toks[1] as Dictionary).get("type", "")) != "OPERATOR" or str((toks[1] as Dictionary).get("value", "")) != "=":
		return
	var vname := str((toks[0] as Dictionary).get("value", ""))
	_flow_assign_call(vname, toks.slice(2), _assign_target(vname, fn, scope, owner, env), scope, fn, env, owner)


## Errors `vname = null` (bare null literal, trailing notes ignored)
## when the target is notnull by declaration or flow state. Anything
## else (compound values, unmarked targets) stays silent.
func _check_null_assign(toks: Array, node: Dictionary, scope: Dictionary, fn: Variant, env: Dictionary, owner: String) -> void:
	var tt := _trim_trivia(toks)
	if tt.size() == 5 and (tt[0] is Dictionary) and str((tt[0] as Dictionary).get("type", "")) == "KEYWORD" and str((tt[0] as Dictionary).get("value", "")) == "self" and (tt[1] is Dictionary) and str((tt[1] as Dictionary).get("type", "")) == "DOT" and (tt[2] is Dictionary) and str((tt[2] as Dictionary).get("type", "")) == "IDENTIFIER" and (tt[3] is Dictionary) and str((tt[3] as Dictionary).get("type", "")) == "OPERATOR" and str((tt[3] as Dictionary).get("value", "")) == "=" and (tt[4] is Dictionary) and str((tt[4] as Dictionary).get("type", "")) == "NULL":
		var mname := str((tt[2] as Dictionary).get("value", ""))
		for o in [owner, ""]:
			var mnode := _member_var_node(str(o), mname)
			if mnode.is_empty():
				continue
			var mann: Variant = mnode.get("var_ann", {})
			if mann is Dictionary and bool((mann as Dictionary).get("notnull", false)):
				_error(ERR_VAR_NOTNULL, "cannot assign null to notnull variable '" + mname + "'", int((tt[4] as Dictionary).get("line", int(node.get("line", 0)))), int((tt[4] as Dictionary).get("column", 0)), owner)
			return
	if tt.size() != 3:
		return
	if not (tt[0] is Dictionary) or str((tt[0] as Dictionary).get("type", "")) != "IDENTIFIER":
		return
	if not (tt[1] is Dictionary) or str((tt[1] as Dictionary).get("type", "")) != "OPERATOR" or str((tt[1] as Dictionary).get("value", "")) != "=":
		return
	if not (tt[2] is Dictionary) or str((tt[2] as Dictionary).get("type", "")) != "NULL":
		return
	var vname := str((tt[0] as Dictionary).get("value", ""))
	if not _flow_notnull(vname, fn, scope, owner, env):
		return
	_error(ERR_VAR_NOTNULL, "cannot assign null to notnull variable '" + vname + "'", int((tt[2] as Dictionary).get("line", int(node.get("line", 0)))), int((tt[2] as Dictionary).get("column", 0)), owner)


## Resolves an `x = ...` reassignment target to its declaration node
## ({} when dynamic/unknown: the call result is fresh information).
func _assign_target(vname: String, fn: Variant, scope: Dictionary, owner: String, env: Dictionary) -> Dictionary:
	if vname == "" or (env as Dictionary).has(vname):
		return {}
	var fnd: Dictionary = fn if fn is Dictionary else {}
	var kind := _scope_kind(scope, vname)
	if kind == "param":
		return _find_param_node(fnd.get("params", []), vname)
	if kind == "local" or kind == "const":
		return _find_body_decl(fnd.get("body", null), vname)
	if kind != "":
		return {}
	for o in [owner, ""]:
		var n := _member_var_node(str(o), vname)
		if not n.is_empty():
			return n
	return {}
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
		_env_set(env, vname, (spec as Dictionary).get("types", []), (spec as Dictionary).get("tree", {}))
		if bool((spec as Dictionary).get("nullable", false)):
			(env as Dictionary)[ENV_WATCH_PREFIX + vname] = true
		else:
			(env as Dictionary).erase(ENV_WATCH_PREFIX + vname)
		if bool((spec as Dictionary).get("notnull", false)):
			(env as Dictionary)[ENV_NOTNULL_PREFIX + vname] = true
		else:
			(env as Dictionary).erase(ENV_NOTNULL_PREFIX + vname)


## Guard-clause narrowing: when an `if` check's failing side ends in
## `return`, code after the `if` only runs proven state, so the outer
## env gains the notnull mark. Null checks (`x == null` returns from
## the null side), bare truthiness (`not x` returns) and type tests
## (`x is not Y` returns from the `is` side) all unify: the proven
## side keeps running, the other side must return. Covers `x ==/!=
## null` (either order), `typeof`/`is_instance_of` NIL forms, bare `x`/
## `not x` on Objects and `is`/`is_instance_of`/`typeof` against
## non-null types. With `elif` branches present, every branch running
## in a possibly-null primary-false state (each `elif` body plus a
## present `else`) must also return — otherwise the fall-through
## could still be null. `elif` chains, `break`/`continue` exits and
## nested returns stay out (conservative: last statement must be
## RETURN).
func _apply_guard_clause(node: Dictionary, g: Dictionary, scope: Dictionary, owner: String, fn: Variant, env: Dictionary) -> void:
	if g.is_empty():
		return
	var bare := bool(g.get("bare_null", false))
	var typetest := _is_typetest_guard(g)
	if not _is_null_guard(g) and not bare and not typetest:
		return
	var nname := str(g.get("name", ""))
	if nname == "":
		return
	var fnd: Dictionary = fn if fn is Dictionary else {}
	var target := _free_var_target(nname, fnd, scope, owner)
	if target.is_empty() or target.has("bad"):
		return
	if bare and not _guard_notnull_object(nname, fn, scope, owner, env):
		return
	var eq := bool(g.get("eq", true))
	var holding: Variant = null
	var other: Variant = null
	if typetest:
		holding = node.get("then", null) if eq else node.get("else_body", null)
		other = node.get("else_body", null) if eq else node.get("then", null)
	else:
		other = node.get("then", null) if eq else node.get("else_body", null)
		holding = node.get("else_body", null) if eq else node.get("then", null)
	if not _block_ends_return(other) or _block_ends_return(holding):
		return
	var elifs: Array = node.get("elifs", [])
	if not elifs.is_empty() and _guard_false_may_be_null(g):
		for e in elifs:
			if not (e is Dictionary) or not _block_ends_return((e as Dictionary).get("body", null)):
				return
		var eb: Variant = node.get("else_body", null)
		if not (eb is Dictionary) or not _block_ends_return(eb):
			return
	(env as Dictionary)[ENV_NOTNULL_PREFIX + nname] = true


## True when a branch body (BLOCK, statement Array or single node)
## ends in a RETURN_STMT (last statement node wins; trailing tags
## ignored by scanning back to the last Dictionary child).
static func _block_ends_return(b: Variant) -> bool:
	var kids: Array = []
	if b is Array:
		kids = b
	elif b is Dictionary and str((b as Dictionary).get("type", "")) == "BLOCK":
		kids = ((b as Dictionary).get("children", []) as Array).duplicate()
	elif b is Dictionary:
		kids = [b]
	else:
		return false
	for i in range(kids.size() - 1, -1, -1):
		if kids[i] is Dictionary:
			return str((kids[i] as Dictionary).get("type", "")) == "RETURN_STMT"
	return false


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
		_apply_assign_invalidation(str(node.get("name", "")), _as_tokens(node.get("value", null)), scope, fn, env, owner, true)
		_flow_assign_call(str(node.get("name", "")), _as_tokens(node.get("value", null)), node, scope, fn, env, owner)
		_flow_lambda_value(node.get("value", null), scope, owner)
		var acc: Variant = node.get("accessors", null)
		if acc is Dictionary:
			_flow_accessor(acc, scope, owner)
		return
	if t == "EXPR_STMT":
		_flow_facts(node, scope, owner, fn, env)
		_verify_tokens(_as_tokens(node.get("expr", null)), scope, owner, fn, env, {})
		_flow_assign_stmt(node, scope, fn, env, owner)
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
		var rest_env := env.duplicate()
		_narrow_guard_envs(g, fn, scope, owner, env, then_env, rest_env)
		_flow_block(node.get("then", null), scope, owner, fn, then_env)
		for e in node.get("elifs", []):
			if e is Dictionary:
				var econd := _as_tokens((e as Dictionary).get("condition", null))
				_verify_tokens(econd, scope, owner, fn, rest_env, {})
				var eg := _flow_guard(econd, fn, scope, owner)
				var ethen := rest_env.duplicate()
				var erest := rest_env.duplicate()
				_narrow_guard_envs(eg, fn, scope, owner, rest_env, ethen, erest)
				_flow_block((e as Dictionary).get("body", null), scope, owner, fn, ethen)
				rest_env = erest
		if node.get("else_body", null) is Dictionary:
			_flow_block(node.get("else_body", null), scope, owner, fn, rest_env)
		_apply_guard_clause(node, g, scope, owner, fn, env)
		return
	if t == "FOR_STMT":
		_verify_tokens(_as_tokens(node.get("iter", null)), scope, owner, fn, env, {})
		_flow_block(node.get("body", null), scope, owner, fn, env.duplicate())
		return
	if t == "WHILE_STMT":
		var wcond := _as_tokens(node.get("condition", null))
		_verify_tokens(wcond, scope, owner, fn, env, {})
		var wenv := env.duplicate()
		_apply_null_family_guard(wcond, fn, scope, owner, wenv)
		_flow_block(node.get("body", null), scope, owner, fn, wenv)
		return
	if t == "MATCH_STMT":
		_verify_tokens(_as_tokens(node.get("subject", null)), scope, owner, fn, env, {})
		for b in node.get("branches", []):
			if b is Dictionary and str((b as Dictionary).get("type", "")) == "MATCH_BRANCH":
				_verify_tokens(_as_tokens((b as Dictionary).get("pattern", null)), scope, owner, fn, env, {})
				_flow_block((b as Dictionary).get("body", null), scope, owner, fn, _match_null_env(node, b, fn, scope, owner, env))
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

## Updates data-dir user/ files: main script file plus one per inner
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


## Generic parameter names for the class described by a member-table
## owner key ("" = root script class, never generic in v1). Updates on
## every analyze (classes may gain or lose @generic).
func _generic_for_file(owner: String) -> Array:
	if owner == "":
		return []
	var parts := owner.split(".")
	var pname := str(parts[parts.size() - 1])
	var pkey := ".".join(parts.slice(0, parts.size() - 1))
	if not _members.has(pkey):
		return []
	var rec: Dictionary = (_members[pkey] as Dictionary).get(pname, {})
	if rec.is_empty():
		return []
	return (rec.get("generic", []) as Array).duplicate()


func _write_class_file(file_base: String, owner: String, ast: Dictionary, root_prefix: String) -> void:
	var path = _write_base + "/user/" + file_base + ".json"
	var info: Dictionary = _read_json(path)
	if info.is_empty():
		info = _minimal_info(file_base, owner, root_prefix)
	else:
		_merge_members(info, owner)
	info["generic"] = _generic_for_file(owner)
	_flag_deprecated(info, owner)
	_flag_private(info, owner)
	info["analysis_errors"] = _issues_for(owner, _errors)
	info["analysis_warnings"] = _issues_for(owner, _warnings)
	_write_json(path, info)
	_written.append(path)


## Adds current-table members missing from a loaded user file. New
## declarations must appear for cross-script checks (private and
## deprecated consult these rosters); existing entries keep their
## richer semantic data untouched. Never removes: a partially parsed
## re-analysis must not wipe the roster.
## Ordered parameter names + notnull/nullable subsets from a
## member-table function rec (empty lists when unavailable). Feeds
## user JSON signatures for cross-script call-site checks; our own
## keys, never clobbering richer semantic entries. `nullable_params`
## is consent data for future boundary checks (recorded now, read
## later); only `notnull_params` refuses today.
static func _signature_param_info(rec: Dictionary) -> Dictionary:
	var names: Array = []
	var flagged: Array = []
	var watch: Array = []
	var ret_types: Array = []
	var ret_nullable := false
	var node: Variant = rec.get("node", {})
	if node is Dictionary and str((node as Dictionary).get("type", "")) == "FUNC_DECL":
		for p in (node as Dictionary).get("params", []):
			if p is Dictionary:
				var pname := str((p as Dictionary).get("name", ""))
				names.append(pname)
				var ann: Variant = (p as Dictionary).get("param_ann", {})
				if ann is Dictionary and bool((ann as Dictionary).get("notnull", false)):
					flagged.append(pname)
				if ann is Dictionary and bool((ann as Dictionary).get("nullable", false)):
					watch.append(pname)
		var rann: Variant = (node as Dictionary).get("return_ann", {})
		if rann is Dictionary and not bool((rann as Dictionary).get("void", false)):
			ret_types = ((rann as Dictionary).get("types", []) as Array).duplicate()
			ret_nullable = bool((rann as Dictionary).get("nullable", false))
	return {"names": names, "notnull": flagged, "nullable": watch, "return_types": ret_types, "nullable_return": ret_nullable}


func _merge_members(info: Dictionary, owner: String) -> void:
	(info as Dictionary)["null_policy"] = _effective_file_policy()
	(info as Dictionary)["extends"] = _script_extends if owner == "" else str(_class_extends.get(owner, ""))
	var table: Dictionary = _members.get(owner, {})
	for mname in table.keys():
		if not (table[mname] is Dictionary):
			continue
		var kind := str((table[mname] as Dictionary).get("kind", ""))
		var list_key := _member_list_key(kind)
		if list_key == "":
			continue
		if not (info.get(list_key, null) is Array):
			info[list_key] = []
		var items: Array = info[list_key]
		var entry := {}
		for e in items:
			if e is Dictionary and str((e as Dictionary).get("name", "")) == mname:
				entry = e
				break
		if entry.is_empty():
			if kind == "class":
				entry = {"name": mname, "full_name": mname, "file": mname + ".json"}
			else:
				entry = {"name": mname}
			items.append(entry)
		if kind == "function":
			var sig := _signature_param_info(table[mname] as Dictionary)
			(entry as Dictionary)["param_names"] = (sig as Dictionary).get("names", [])
			(entry as Dictionary)["notnull_params"] = (sig as Dictionary).get("notnull", [])
			(entry as Dictionary)["nullable_params"] = (sig as Dictionary).get("nullable", [])
			(entry as Dictionary)["return_types"] = (sig as Dictionary).get("return_types", [])
			(entry as Dictionary)["nullable_return"] = (sig as Dictionary).get("nullable_return", false)


## User-file member list for a member-table kind ("" when none).
static func _member_list_key(kind: String) -> String:
	if kind == "enum":
		return "enums"
	if kind == "constant":
		return "constants"
	if kind == "signal":
		return "signals"
	if kind == "variable":
		return "fields"
	if kind == "function":
		return "instance_methods"
	if kind == "class":
		return "inner_classes"
	return ""


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
	# Drop any cached miss for this file: same-run conflict checks
	# (_tuple_conflict and friends cache negative lookups) must see
	# freshly written type files.
	_type_cache.erase(path.get_file().get_basename())


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
		"null_policy": _effective_file_policy(),
		"extends": _script_extends if owner == "" else str(_class_extends.get(owner, "")),
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
			var sig := _signature_param_info(rec)
			entry["param_names"] = (sig as Dictionary).get("names", [])
			entry["notnull_params"] = (sig as Dictionary).get("notnull", [])
			entry["nullable_params"] = (sig as Dictionary).get("nullable", [])
			entry["return_types"] = (sig as Dictionary).get("return_types", [])
			entry["nullable_return"] = (sig as Dictionary).get("nullable_return", false)
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
