class_name gnumaru_godot_native_types_info_dumper
extends RefCounted

## Dumps Godot native type information for future semantic analysis.
##
## The class runs a Godot executable with --dump-extension-api, parses the
## resulting (huge) extension_api.json and extracts, for every native type,
## inheritance (with Variant as the root, e.g. int extends Variant and
## Node3D extends Node ... extends Object extends Variant), static and
## instance methods, and operators (as, in, is, +, +=, *, **, ...).
##
## Output layout (created when missing; "types_info" is ignored by the
## repo .gitignore):
##   <output_base>/builtin/<Name>.json   (String, Array, int, ...)
##   <output_base>/builtin/Variant.json  (synthesized root)
##   <output_base>/classes/<Name>.json   (Node3D, Object, ...)
##   <output_base>/index.json                      (type lists and counts)
## Every per-type file holds at minimum the type name, the allowed
## operators with the expected type of each parameter, and the static and
## instance methods with parameter list, expected types, default values
## and vararg presence. Extra capability data (constructors, members,
## properties, signals, enums, constants) is included when available.
##
## Usage with an explicit executable:
##   var d := gnumaru_godot_native_types_info_dumper.new()
##   var summary: Dictionary = d.dump_all("/path/to/godot4.x86_64")
## Usage relying on PATH (falls back to the "godot" command):
##   var summary: Dictionary = d.dump_all()
## Lower level steps are exposed too: run_dump(), extract_from_file(),
## extract_from_data(), write_infos().

## Default executable used when dump_all()/run_dump() get an empty path.
var godot_executable: String = "godot"
## Base directory for types_info/builtin and types_info/classes.
## Accepts res://, user://, absolute or CWD-relative paths.
var output_base: String = "types_info"
## Keeps the intermediate extension_api.json next to the output.
var keep_dump_file: bool = false
## Human readable description of the last failure ("" when fine).
var last_error: String = ""
## Absolute-or-given path of the last generated dump file.
var last_dump_path: String = ""
## Summary Dictionary returned by the last dump_all() call.
var last_summary: Dictionary = {}

const DUMP_FILE_NAME := "extension_api.json"
const BUILTIN_DIR_NAME := "builtin"
const CLASSES_DIR_NAME := "classes"
const INDEX_FILE_NAME := "index.json"
const VARIANT_ROOT := "Variant"

## Binary operators from which an augmented assignment form is derived
## (e.g. "+" allows "+="). Derived entries are marked origin "derived"
## with "derived_from" set, so consumers know they came from the rule.
const AUGMENTED_FROM: Array = ["+", "-", "*", "/", "%", "**", "<<", ">>", "&", "|", "^"]


## Full pipeline: dump, extract and write. Returns a summary Dictionary
## with "ok" true on success (counts, dirs, engine version) or "ok"
## false with an "error" message. Never crashes; failures are reported.
func dump_all(godot_path: String = "") -> Dictionary:
	last_error = ""
	last_summary = {}
	var dump_path := run_dump(godot_path)
	if dump_path == "":
		last_summary = {"ok": false, "error": last_error}
		return last_summary
	var infos := extract_from_file(dump_path)
	if infos.is_empty() and last_error != "":
		last_summary = {"ok": false, "error": last_error}
		return last_summary
	var written := write_infos(infos)
	var summary := {
		"ok": true,
		"engine_version": infos.get("__engine_version__", ""),
		"builtin_types": written.get("builtin_types", []),
		"class_types": written.get("class_types", []),
		"builtin_count": written.get("builtin_count", 0),
		"class_count": written.get("class_count", 0),
		"builtin_dir": _join_path(output_base, BUILTIN_DIR_NAME),
		"classes_dir": _join_path(output_base, CLASSES_DIR_NAME),
		"index_path": _join_path(output_base, INDEX_FILE_NAME),
	}
	if not keep_dump_file:
		_remove_file_best_effort(dump_path)
	last_summary = summary
	return summary


## Runs the Godot executable with --dump-extension-api and returns the
## path of the generated JSON file, or "" on failure (last_error set).
func run_dump(godot_path: String = "") -> String:
	last_error = ""
	last_dump_path = ""
	var exe := godot_path
	if exe == "":
		exe = godot_executable
	var output: Array = []
	var code := OS.execute(exe, PackedStringArray(["--headless", "--dump-extension-api"]), output, true)
	if code != 0:
		last_error = "Godot dump failed (exit " + str(code) + ") for '" + exe + "': " + "".join(output).strip_edges()
		return ""
	for candidate in [DUMP_FILE_NAME, "res://" + DUMP_FILE_NAME]:
		if FileAccess.file_exists(candidate):
			last_dump_path = candidate
			return candidate
	last_error = "Dump ran but '" + DUMP_FILE_NAME + "' was not found next to the working directory. Output: " + "".join(output).strip_edges()
	return ""


## Parses a dumped extension_api.json file into {type_name: info}.
## Returns {} on failure (last_error set).
func extract_from_file(dump_path: String) -> Dictionary:
	last_error = ""
	if not FileAccess.file_exists(dump_path):
		last_error = "Dump file not found: " + dump_path
		return {}
	var file := FileAccess.open(dump_path, FileAccess.READ)
	if file == null:
		last_error = "Cannot open dump file: " + dump_path
		return {}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		last_error = "Dump file is not a JSON object: " + dump_path
		return {}
	return extract_from_data(parsed)


## Builds {type_name: info} plus "__engine_version__" from parsed JSON.
func extract_from_data(api: Dictionary) -> Dictionary:
	var infos: Dictionary = {}
	var classes_by_name: Dictionary = {}
	for c in api.get("classes", []):
		if c is Dictionary and (c as Dictionary).has("name"):
			classes_by_name[str((c as Dictionary)["name"])] = c
	for b in api.get("builtin_classes", []):
		if b is Dictionary and (b as Dictionary).has("name"):
			var info := _builtin_info(b, classes_by_name)
			infos[str((b as Dictionary)["name"])] = info
	infos[VARIANT_ROOT] = _variant_root_info()
	for cname in classes_by_name.keys():
		infos[str(cname)] = _class_info(classes_by_name[cname], classes_by_name)
	var header: Dictionary = api.get("header", {})
	infos["__engine_version__"] = str(header.get("version_full_name", ""))
	return infos


## Writes one <Name>.json per type plus index.json.
## Returns counts and type lists. Skips the __engine_version__ entry.
func write_infos(infos: Dictionary) -> Dictionary:
	last_error = ""
	var builtin_dir := _join_path(output_base, BUILTIN_DIR_NAME)
	var classes_dir := _join_path(output_base, CLASSES_DIR_NAME)
	if _ensure_dir(builtin_dir) != OK:
		last_error = "Cannot create directory: " + builtin_dir
		return {}
	if _ensure_dir(classes_dir) != OK:
		last_error = "Cannot create directory: " + classes_dir
		return {}
	var builtin_types: Array = []
	var class_types: Array = []
	for tname in infos.keys():
		var tkey := str(tname)
		if tkey == "__engine_version__":
			continue
		var info: Dictionary = infos[tkey]
		var target := classes_dir
		if str(info.get("kind", "")) != "class":
			target = builtin_dir
		var path := _join_path(target, tkey + ".json")
		var file := FileAccess.open(path, FileAccess.WRITE)
		if file == null:
			last_error = "Cannot write file: " + path
			return {}
		file.store_string(JSON.stringify(info, "\t"))
		file.close()
		if str(info.get("kind", "")) == "class":
			class_types.append(tkey)
		else:
			builtin_types.append(tkey)
	builtin_types.sort()
	class_types.sort()
	var index := {
		"engine_version": str(infos.get("__engine_version__", "")),
		"generator": "gnumaru_godot_native_types_info_dumper",
		"generated_at": Time.get_datetime_string_from_system(),
		"builtin_count": builtin_types.size(),
		"class_count": class_types.size(),
		"builtin_types": builtin_types,
		"class_types": class_types,
	}
	var index_file := FileAccess.open(_join_path(output_base, INDEX_FILE_NAME), FileAccess.WRITE)
	if index_file == null:
		last_error = "Cannot write file: " + _join_path(output_base, INDEX_FILE_NAME)
		return {}
	index_file.store_string(JSON.stringify(index, "\t"))
	index_file.close()
	return {"builtin_count": builtin_types.size(), "class_count": class_types.size(), "builtin_types": builtin_types, "class_types": class_types}


## Builds the info Dictionary for one builtin Variant type.
func _builtin_info(b: Dictionary, _classes_by_name: Dictionary) -> Dictionary:
	var tname := str(b.get("name", ""))
	var operators: Array = _operators_from_api(tname, b.get("operators", []))
	operators = _with_language_operators(tname, operators, tname != "Nil")
	operators = _with_augmented_operators(tname, operators)
	var static_methods: Array = []
	var instance_methods: Array = []
	for m in b.get("methods", []):
		if m is Dictionary:
			var entry := _method_info(m)
			if bool((m as Dictionary).get("is_static", false)):
				static_methods.append(entry)
			else:
				instance_methods.append(entry)
	var constructors: Array = []
	for c in b.get("constructors", []):
		if c is Dictionary:
			constructors.append({"params": _params_info((c as Dictionary).get("arguments", []))})
	var members: Array = []
	for mb in b.get("members", []):
		if mb is Dictionary:
			members.append({"name": str((mb as Dictionary).get("name", "")), "type": str((mb as Dictionary).get("type", VARIANT_ROOT))})
	return {
		"name": tname,
		"kind": "builtin",
		"parent": VARIANT_ROOT,
		"inheritance_chain": [tname, VARIANT_ROOT],
		"is_instantiable": tname != "Nil",
		"is_keyed": bool(b.get("is_keyed", false)),
		"operators": operators,
		"constructors": constructors,
		"members": members,
		"static_methods": static_methods,
		"instance_methods": instance_methods,
	}


## Builds the info Dictionary for one engine class.
func _class_info(c: Dictionary, classes_by_name: Dictionary) -> Dictionary:
	var tname := str(c.get("name", ""))
	var chain: Array = [tname]
	var seen := {tname: true}
	var parent := str(c.get("inherits", ""))
	while parent != "" and not seen.has(parent):
		chain.append(parent)
		seen[parent] = true
		if classes_by_name.has(parent):
			parent = str((classes_by_name[parent] as Dictionary).get("inherits", ""))
		else:
			parent = ""
	chain.append(VARIANT_ROOT)
	var direct_parent := ""
	if chain.size() > 1:
		direct_parent = str(chain[1])
	var operators: Array = [
		{"op": "==", "left": tname, "right": VARIANT_ROOT, "right_kind": "value", "returns": "bool", "origin": "language"},
		{"op": "!=", "left": tname, "right": VARIANT_ROOT, "right_kind": "value", "returns": "bool", "origin": "language"},
	]
	operators = _with_language_operators(tname, operators, true)
	var static_methods: Array = []
	var instance_methods: Array = []
	for m in c.get("methods", []):
		if m is Dictionary:
			var entry := _method_info(m)
			if bool((m as Dictionary).get("is_static", false)):
				static_methods.append(entry)
			else:
				instance_methods.append(entry)
	var properties: Array = []
	for p in c.get("properties", []):
		if p is Dictionary:
			properties.append({
				"name": str((p as Dictionary).get("name", "")),
				"type": str((p as Dictionary).get("type", VARIANT_ROOT)),
				"setter": str((p as Dictionary).get("setter", "")),
				"getter": str((p as Dictionary).get("getter", "")),
			})
	var signals: Array = []
	for s in c.get("signals", []):
		if s is Dictionary:
			signals.append({"name": str((s as Dictionary).get("name", "")), "params": _params_info((s as Dictionary).get("arguments", []))})
	var enums: Array = []
	for e in c.get("enums", []):
		if e is Dictionary:
			var values: Array = []
			for v in (e as Dictionary).get("values", []):
				if v is Dictionary:
					values.append({"name": str((v as Dictionary).get("name", "")), "value": (v as Dictionary).get("value", 0)})
			enums.append({"name": str((e as Dictionary).get("name", "")), "is_bitfield": bool((e as Dictionary).get("is_bitfield", false)), "values": values})
	var constants: Array = []
	for k in c.get("constants", []):
		if k is Dictionary:
			constants.append({"name": str((k as Dictionary).get("name", "")), "value": (k as Dictionary).get("value", 0)})
	return {
		"name": tname,
		"kind": "class",
		"parent": direct_parent,
		"inheritance_chain": chain,
		"is_instantiable": bool(c.get("is_instantiable", true)),
		"is_refcounted": bool(c.get("is_refcounted", false)),
		"operators": operators,
		"properties": properties,
		"signals": signals,
		"enums": enums,
		"constants": constants,
		"static_methods": static_methods,
		"instance_methods": instance_methods,
	}


## Synthesized root entry: every native type derives from Variant.
func _variant_root_info() -> Dictionary:
	return {
		"name": VARIANT_ROOT,
		"kind": "root",
		"parent": "",
		"inheritance_chain": [VARIANT_ROOT],
		"is_instantiable": false,
		"operators": [
			{"op": "==", "left": VARIANT_ROOT, "right": VARIANT_ROOT, "right_kind": "value", "returns": "bool", "origin": "language"},
			{"op": "!=", "left": VARIANT_ROOT, "right": VARIANT_ROOT, "right_kind": "value", "returns": "bool", "origin": "language"},
			{"op": "is", "right": VARIANT_ROOT, "right_kind": "type", "returns": "bool", "origin": "language"},
			{"op": "as", "right": VARIANT_ROOT, "right_kind": "type", "returns": VARIANT_ROOT, "origin": "language"},
		],
		"constructors": [],
		"members": [],
		"static_methods": [],
		"instance_methods": [],
	}


## Transcribes builtin operator entries from the extension API.
func _operators_from_api(tname: String, api_operators: Array) -> Array:
	var out: Array = []
	for o in api_operators:
		if not (o is Dictionary):
			continue
		var entry := {"op": str((o as Dictionary).get("name", "")), "left": tname, "right_kind": "value", "origin": "api"}
		if (o as Dictionary).has("right_type"):
			entry["right"] = str((o as Dictionary)["right_type"])
		else:
			entry["right"] = null
			entry["right_kind"] = "none"
		entry["returns"] = str((o as Dictionary).get("return_type", VARIANT_ROOT))
		out.append(entry)
	return out


## Adds the language-level "is" and "as" operators naming this type.
static func _with_language_operators(tname: String, operators: Array, enabled: bool) -> Array:
	if not enabled:
		return operators
	var out: Array = []
	for o in operators:
		out.append(o)
	out.append({"op": "is", "right": tname, "right_kind": "type", "returns": "bool", "origin": "language"})
	out.append({"op": "as", "right": tname, "right_kind": "type", "returns": tname, "origin": "language"})
	return out


## Derives augmented assignments (+=, -=, ...) from plain binary operators.
static func _with_augmented_operators(tname: String, operators: Array) -> Array:
	var out: Array = []
	for o in operators:
		out.append(o)
	for o in operators:
		var od: Dictionary = o
		var base := str(od.get("op", ""))
		if not (base in AUGMENTED_FROM):
			continue
		if str(od.get("origin", "")) != "api":
			continue
		if str(od.get("right_kind", "")) != "value" or od.get("right", null) == null:
			continue
		out.append({
			"op": base + "=",
			"left": tname,
			"right": str(od["right"]),
			"right_kind": "value",
			"returns": str(od.get("returns", tname)),
			"origin": "derived",
			"derived_from": base,
		})
	return out


## Normalizes one method (or signal-like) entry from the extension API.
static func _method_info(m: Dictionary) -> Dictionary:
	return {
		"name": str(m.get("name", "")),
		"returns": str(m.get("return_type", "void")),
		"is_vararg": bool(m.get("is_vararg", false)),
		"is_const": bool(m.get("is_const", false)),
		"is_virtual": bool(m.get("is_virtual", false)),
		"params": _params_info(m.get("arguments", [])),
	}


## Normalizes one parameter list with expected types and defaults.
static func _params_info(api_arguments: Array) -> Array:
	var out: Array = []
	for a in api_arguments:
		if not (a is Dictionary):
			continue
		var ad: Dictionary = a
		var has_default := ad.has("default_value")
		out.append({
			"name": str(ad.get("name", "")),
			"type": str(ad.get("type", VARIANT_ROOT)),
			"has_default": has_default,
			"default": ad.get("default_value", null),
		})
	return out


## Creates a directory (and parents) for res://, user://, absolute or
## CWD-relative paths. Returns OK (0) on success.
func _ensure_dir(path: String) -> int:
	if path.begins_with("res://") or path.begins_with("user://"):
		return _ensure_dir(ProjectSettings.globalize_path(path))
	if path.begins_with("/"):
		return DirAccess.make_dir_recursive_absolute(path)
	var d := DirAccess.open(".")
	if d == null:
		return FAILED
	return d.make_dir_recursive(path)


## Best-effort removal of the intermediate dump file.
func _remove_file_best_effort(path: String) -> void:
	if path.begins_with("res://") or path.begins_with("user://"):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	elif path.begins_with("/"):
		DirAccess.remove_absolute(path)
	else:
		var d := DirAccess.open(".")
		if d != null:
			d.remove(path)


func _join_path(base: String, child: String) -> String:
	if base == "":
		return child
	if base.ends_with("/"):
		return base + child
	return base + "/" + child
