class_name gnumaru_godot_native_types_info_dumper
extends RefCounted

## Dumps Godot native type information for future semantic analysis.
##
## The class runs a Godot executable with --dump-extension-api, parses the
## resulting (huge) extension_api.json and extracts, for every native type,
## inheritance (with Variant as the root, e.g. int extends Variant and
## Node3D extends Node ... extends Object extends Variant), static and
## instance methods, and operators (as, in, is, +, +=, *, **, ...).
## Because the extension-api dump misses entries (e.g. Object.free()
## in 4.7.2), every Object-inheriting class is then completed with live
## ClassDB data (methods, signals, properties, constants, enums):
## anything ClassDB reports and the dump lacks is added, dump data is
## never overridden. Builtin Variant types are not in ClassDB; their
## missing enums and constants come from doc XML downloads instead
## (see merge_doc_data).
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
## extract_from_data(), merge_classdb(), merge_doc_data_async(), write_infos().

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

## Variant.Type int -> type name (verified against the running engine:
## NIL=0, INT=2, STRING=4, OBJECT=24, ARRAY=28, MAX=39, ...). Used to
## translate ClassDB argument/return/property type codes.
const VARIANT_TYPE_INT := {
	0: "Nil", 1: "bool", 2: "int", 3: "float", 4: "String",
	5: "Vector2", 6: "Vector2i", 7: "Rect2", 8: "Rect2i",
	9: "Vector3", 10: "Vector3i", 11: "Transform2D", 12: "Vector4",
	13: "Vector4i", 14: "Plane", 15: "Quaternion", 16: "AABB",
	17: "Basis", 18: "Transform3D", 19: "Projection", 20: "Color",
	21: "StringName", 22: "NodePath", 23: "RID", 24: "Object",
	25: "Callable", 26: "Signal", 27: "Dictionary", 28: "Array",
	29: "PackedByteArray", 30: "PackedInt32Array", 31: "PackedInt64Array",
	32: "PackedFloat32Array", 33: "PackedFloat64Array",
	34: "PackedStringArray", 35: "PackedVector2Array",
	36: "PackedVector3Array", 37: "PackedColorArray",
	38: "PackedVector4Array",
}

## ClassDB method flag bits (Godot 4): static placement and entry
## booleans. Only used to file merged methods and copy flags;
## verification searches static and instance lists alike.
const METHOD_FLAG_CONST := 4
const METHOD_FLAG_VIRTUAL := 8
const METHOD_FLAG_VARARG := 16
const METHOD_FLAG_STATIC := 32

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
	var merged := merge_classdb(infos)
	var docced := merge_doc_data(infos)
	return _finish_dump(infos, merged, docced, dump_path)


## Full pipeline with the HTTPRequest doc fallback (awaits downloads):
## same steps as dump_all(), but doc fetches try curl/wget first and
## HTTPRequest second. Use from async contexts (the test regen step);
## library/analyzer paths keep the sync dump_all(). Pass a SceneTree
## (or null for the engine loop) for the request nodes.
func dump_all_async(godot_path: String = "", tree: SceneTree = null) -> Dictionary:
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
	var merged := merge_classdb(infos)
	var docced := await merge_doc_data_async(infos, tree)
	return _finish_dump(infos, merged, docced, dump_path)


## Shared dump tail: writes files, builds the summary, cleans the
## intermediate dump unless kept.
func _finish_dump(infos: Dictionary, merged: Dictionary, docced: Dictionary, dump_path: String) -> Dictionary:
	var written := write_infos(infos)
	var summary := {
		"ok": true,
		"engine_version": infos.get("__engine_version__", ""),
		"builtin_types": written.get("builtin_types", []),
		"class_types": written.get("class_types", []),
		"builtin_count": written.get("builtin_count", 0),
		"class_count": written.get("class_count", 0),
		"classdb_added": merged,
		"doc_added": docced,
		"builtin_dir": _join_path(output_base, BUILTIN_DIR_NAME),
		"classes_dir": _join_path(output_base, CLASSES_DIR_NAME),
		"index_path": _join_path(output_base, INDEX_FILE_NAME),
	}
	if not keep_dump_file:
		_remove_file_best_effort(dump_path)
	last_summary = summary
	return summary


## Ensures the native database under output_base exists: index.json plus
## non-empty builtin/ and classes/ directories. Dumps on demand with
## dump_all() when anything is missing. Returns true when the database
## is present (or was just dumped); false sets last_error. Never crashes.
## The semantic parser and the analyzer call this on every analyze().
func ensure_present(godot_path: String = "") -> bool:
	last_error = ""
	if is_present():
		return true
	var exe: String = godot_path
	if exe == "":
		exe = default_executable()
	var summary: Dictionary = dump_all(exe)
	if not bool(summary.get("ok", false)):
		return false
	return is_present()


## True when output_base holds index.json plus non-empty builtin/ and
## classes/ directories. No dumping, no writes: safe to call often.
func is_present() -> bool:
	if not FileAccess.file_exists(_join_path(output_base, INDEX_FILE_NAME)):
		return false
	return _dir_has_files(_join_path(output_base, BUILTIN_DIR_NAME)) and _dir_has_files(_join_path(output_base, CLASSES_DIR_NAME))


## Picks the Godot executable for dumping: explicit GODOT_BIN first,
## then the currently running engine binary, then the "godot" command.
static func default_executable() -> String:
	var env: String = OS.get_environment("GODOT_BIN")
	if env != "":
		return env
	var exe: String = OS.get_executable_path()
	if exe != "":
		return exe
	return "godot"


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


## Merges live ClassDB data into the extracted infos. The## --dump-extension-api output misses entries (e.g. Object.free() in
## 4.7.2), so for every Object-inheriting native class the methods,
## signals, properties, constants and enums reported by ClassDB and
## missing from the dump are added (never overriding dump data, which
## stays richer). Classes present in ClassDB but absent from the dump
## get a minimal skeleton entry so coverage is complete (pass
## include_new=false to only fill classes already present, useful for
## fast unit tests). Builtin Variant types are not in ClassDB and stay
## dump-only. Returns counts of added entries.
func merge_classdb(infos: Dictionary, include_new: bool = true) -> Dictionary:
	var added := {"classes": 0, "methods": 0, "signals": 0, "properties": 0, "constants": 0, "enums": 0}
	for c in ClassDB.get_class_list():
		var tname := str(c)
		var info: Dictionary = infos.get(tname, {})
		if info.is_empty():
			if not include_new:
				continue
			info = _classdb_skeleton(tname)
			if info.is_empty():
				continue
			infos[tname] = info
			added["classes"] = int(added["classes"]) + 1
		if str(info.get("kind", "")) != "class":
			continue
		for m in ClassDB.class_get_method_list(tname, true):
			if not (m is Dictionary):
				continue
			var md: Dictionary = m
			var mname := str(md.get("name", ""))
			if mname == "":
				continue
			if _has_named(info.get("static_methods", []), mname) or _has_named(info.get("instance_methods", []), mname):
				continue
			var key := "instance_methods"
			if (int(md.get("flags", 1)) & METHOD_FLAG_STATIC) != 0:
				key = "static_methods"
			var mlst: Array = info.get(key, [])
			mlst.append(_classdb_method(md))
			info[key] = mlst
			added["methods"] = int(added["methods"]) + 1
		for s in ClassDB.class_get_signal_list(tname, true):
			if not (s is Dictionary):
				continue
			var sd: Dictionary = s
			var sname := str(sd.get("name", ""))
			if sname == "" or _has_named(info.get("signals", []), sname):
				continue
			var slst: Array = info.get("signals", [])
			slst.append({"name": sname, "params": _classdb_params(sd.get("arguments", sd.get("args", [])), sd.get("default_args", []))})
			info["signals"] = slst
			added["signals"] = int(added["signals"]) + 1
		for p in ClassDB.class_get_property_list(tname, true):
			if not (p is Dictionary):
				continue
			var pd: Dictionary = p
			var pname := str(pd.get("name", ""))
			if pname == "" or _has_named(info.get("properties", []), pname):
				continue
			var plst: Array = info.get("properties", [])
			plst.append({"name": pname, "type": _classdb_type(pd, false), "setter": "", "getter": ""})
			info["properties"] = plst
			added["properties"] = int(added["properties"]) + 1
		for cv in ClassDB.class_get_integer_constant_list(tname, true):
			var cname := str(cv)
			if cname == "" or _has_named(info.get("constants", []), cname):
				continue
			var clst: Array = info.get("constants", [])
			clst.append({"name": cname, "value": ClassDB.class_get_integer_constant(tname, cname)})
			info["constants"] = clst
			added["constants"] = int(added["constants"]) + 1
		for ev in ClassDB.class_get_enum_list(tname, true):
			var ename := str(ev)
			if ename == "" or _has_named(info.get("enums", []), ename):
				continue
			var vals: Array = []
			for cc in ClassDB.class_get_enum_constants(tname, ename, true):
				var cn2 := str(cc)
				vals.append({"name": cn2, "value": ClassDB.class_get_integer_constant(tname, cn2)})
			var elst: Array = info.get("enums", [])
			elst.append({"name": ename, "is_bitfield": false, "values": vals})
			info["enums"] = elst
			added["enums"] = int(added["enums"]) + 1
	return added


## Minimal class entry for a ClassDB class missing from the dump, with
## the parent chain resolved live. Members merge on top of it.
static func _classdb_skeleton(tname: String) -> Dictionary:
	if tname == "":
		return {}
	var chain: Array = [tname]
	var seen := {tname: true}
	var p := str(ClassDB.get_parent_class(tname))
	while p != "" and not seen.has(p):
		chain.append(p)
		seen[p] = true
		if ClassDB.class_exists(p):
			p = str(ClassDB.get_parent_class(p))
		else:
			break
	chain.append(VARIANT_ROOT)
	var parent := ""
	if chain.size() > 1:
		parent = str(chain[1])
	return {
		"name": tname, "kind": "class", "parent": parent, "inheritance_chain": chain,
		"is_instantiable": ClassDB.can_instantiate(tname),
		"is_refcounted": ClassDB.is_parent_class(tname, "RefCounted"),
		"operators": [], "properties": [], "signals": [], "enums": [],
		"constants": [], "static_methods": [], "instance_methods": [],
	}


static func _has_named(items: Variant, mname: String) -> bool:
	if not (items is Array):
		return false
	for e in items:
		if e is Dictionary and str((e as Dictionary).get("name", "")) == mname:
			return true
	return false


## Transcribes one ClassDB method entry ({args, default_args, flags,
## id, name, return}) into our method shape.
static func _classdb_method(md: Dictionary) -> Dictionary:
	var flags := int(md.get("flags", 1))
	return {
		"name": str(md.get("name", "")),
		"returns": _classdb_type(md.get("return", {}), true),
		"is_vararg": (flags & METHOD_FLAG_VARARG) != 0,
		"is_const": (flags & METHOD_FLAG_CONST) != 0,
		"is_virtual": (flags & METHOD_FLAG_VIRTUAL) != 0,
		"params": _classdb_params(md.get("args", []), md.get("default_args", [])),
	}


## Normalizes one ClassDB parameter list. Defaults are trailing
## (default_args aligns to the end of args); only JSON-safe scalar
## defaults are kept.
static func _classdb_params(api_arguments: Variant, api_defaults: Variant) -> Array:
	var out: Array = []
	if not (api_arguments is Array):
		return out
	var defs: Array = []
	if api_defaults is Array:
		defs = api_defaults
	var first_default := (api_arguments as Array).size() - defs.size()
	for i in range((api_arguments as Array).size()):
		var a: Variant = (api_arguments as Array)[i]
		if not (a is Dictionary):
			continue
		var ad: Dictionary = a
		var has_default := i >= first_default and defs.size() > 0
		var def: Variant = null
		if has_default:
			def = _classdb_json_value(defs[i - first_default])
		out.append({
			"name": str(ad.get("name", "")),
			"type": _classdb_type(ad, false),
			"has_default": has_default,
			"default": def,
		})
	return out


## Translates a ClassDB type Dictionary ({type int, class_name}) to a
## type name. OBJECT with a plain class_name uses it (dotted names are
## enum references: plain int, like the dump normalizer); return
## position maps absent results to void.
static func _classdb_type(d: Variant, is_return: bool) -> String:
	if not (d is Dictionary):
		return "void" if is_return else "Variant"
	var t := int((d as Dictionary).get("type", 0))
	if t == 24:
		var cn := str((d as Dictionary).get("class_name", ""))
		if cn != "" and not ("." in cn):
			return cn
		return "Object"
	if t == 0:
		return "void" if is_return else "Nil"
	return str(VARIANT_TYPE_INT.get(t, "Variant"))


## Keeps only JSON-safe scalar defaults (anything else becomes null so
## one exotic default can never corrupt a whole type file).
static func _classdb_json_value(v: Variant) -> Variant:
	match typeof(v):
		TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_FLOAT, TYPE_STRING:
			return v
	return null


## First "major.minor" in an engine version string ("Godot Engine
## v4.7.2.stable.official" -> "4.7"). "" when none is found, in which
## case doc downloads are skipped entirely.
static func _major_minor(version_full: String) -> String:
	var n := version_full.length()
	var i := 0
	while i < n and not _is_digit(version_full.unicode_at(i)):
		i += 1
	var major := ""
	while i < n and _is_digit(version_full.unicode_at(i)):
		major += version_full.substr(i, 1)
		i += 1
	if i >= n or version_full.unicode_at(i) != 46:
		return ""
	i += 1
	var minor := ""
	while i < n and _is_digit(version_full.unicode_at(i)):
		minor += version_full.substr(i, 1)
		i += 1
	if major == "" or minor == "":
		return ""
	return major + "." + minor


static func _is_digit(c: int) -> bool:
	return c >= 48 and c <= 57


## Doc XML download URLs for a builtin type, most direct first. Only
## raw file URLs are attempted: the github blob and docs pages are HTML
## (scraping them is fragile), so anything not fetchable raw is skipped.
static func _doc_urls(tname: String, major_minor: String) -> Array:
	var path := "/doc/classes/" + tname + ".xml"
	return [
		"https://raw.githubusercontent.com/godotengine/godot/refs/heads/" + major_minor + path,
		"https://raw.githubusercontent.com/godotengine/godot/" + major_minor + path,
	]


## Downloads a URL to stdout with curl, falling back to wget. "" on any
## failure (missing tools, DNS, HTTP errors, timeouts): callers treat
## that as "skip this class". For environments without either tool see
## download_text_async (last resort, needs awaiting).
func _download_text(url: String) -> String:
	var out: Array = []
	if OS.execute("curl", PackedStringArray(["-fsSL", "--max-time", "15", url]), out, false, false) == 0 and not out.is_empty() and str(out[0]) != "":
		return str(out[0])
	out = []
	if OS.execute("wget", PackedStringArray(["-qO-", "--timeout=15", "--tries=1", url]), out, false, false) == 0 and not out.is_empty() and str(out[0]) != "":
		return str(out[0])
	return ""


## Last-resort download via HTTPRequest (for environments with neither
## curl nor wget). Needs a SceneTree (pass one, e.g. self from a
## SceneTree script; falls back to the engine main loop): attaches the
## request node to the tree root and awaits request_completed (15 s
## timeout). "" when there is no tree, the request fails, or the
## status is not 200.
func download_text_async(url: String, tree: SceneTree = null) -> String:
	var t: SceneTree = tree
	if t == null:
		t = Engine.get_main_loop() as SceneTree
	if t == null or t.root == null:
		return ""
	var req := HTTPRequest.new()
	req.timeout = 15
	t.root.add_child(req)
	await t.process_frame
	if not req.is_inside_tree():
		req.queue_free()
		return ""
	var body := ""
	if req.request(url) == OK:
		var done: Array = await req.request_completed
		if done.size() == 4 and int(done[1]) == 200:
			body = (done[3] as PackedByteArray).get_string_from_utf8()
	req.queue_free()
	return body


## Parses a doc/classes/<Name>.xml text into constants and enums:
## {"constants": [{name, value}], "enums": [{name, is_bitfield,
## values: [{name, value}]}]}. Constants carrying an `enum` attribute
## are grouped (bitfield-ness is not in the XML: always false).
## Values are raw expression strings ("Color(1, 0, 0, 1)"): only names
## matter for verification. Garbage in yields empty lists, never a crash.
static func _parse_doc_data(xml_text: String) -> Dictionary:
	var out := {"constants": [], "enums": []}
	var parser := XMLParser.new()
	if parser.open_buffer(xml_text.to_utf8_buffer()) != OK:
		return out
	var in_constants := false
	var enums := {}
	var order: Array = []
	while parser.read() == OK:
		var nt := parser.get_node_type()
		if nt == XMLParser.NODE_ELEMENT:
			var nm := parser.get_node_name()
			if nm == "constants":
				in_constants = true
			elif nm == "constant" and in_constants:
				var cname := ""
				var cvalue := ""
				var cenum := ""
				for i in range(parser.get_attribute_count()):
					var an := parser.get_attribute_name(i)
					if an == "name":
						cname = parser.get_attribute_value(i)
					elif an == "value":
						cvalue = parser.get_attribute_value(i)
					elif an == "enum":
						cenum = parser.get_attribute_value(i)
				if cname != "":
					(out["constants"] as Array).append({"name": cname, "value": cvalue})
					if cenum != "":
						if not enums.has(cenum):
							enums[cenum] = []
							order.append(cenum)
						(enums[cenum] as Array).append({"name": cname, "value": cvalue})
		elif nt == XMLParser.NODE_ELEMENT_END:
			if parser.get_node_name() == "constants":
				in_constants = false
	for ename in order:
		(out["enums"] as Array).append({"name": str(ename), "is_bitfield": false, "values": enums[ename]})
	return out


## Merges one downloaded doc XML into a builtin info entry. Returns
## true when anything was added. Shared by both merge flavors.
func _merge_doc_entry(infos: Dictionary, tname: String, body: String, added: Dictionary) -> bool:
	var parsed := _parse_doc_data(body)
	var info: Dictionary = infos[tname]
	var touched := false
	for c in (parsed as Dictionary).get("constants", []):
		if _has_named(info.get("constants", []), str((c as Dictionary).get("name", ""))):
			continue
		var clst: Array = info.get("constants", [])
		clst.append(c)
		info["constants"] = clst
		added["constants"] = int(added["constants"]) + 1
		touched = true
	for e in (parsed as Dictionary).get("enums", []):
		if _has_named(info.get("enums", []), str((e as Dictionary).get("name", ""))):
			continue
		var elst: Array = info.get("enums", [])
		elst.append(e)
		info["enums"] = elst
		added["enums"] = int(added["enums"]) + 1
		touched = true
	return touched


## Builtin type names in infos (never classes), sorted, for doc fetching.
func _doc_names(infos: Dictionary) -> Array:
	var names: Array = []
	for tname in infos.keys():
		var key := str(tname)
		if key == "" or key.begins_with("__"):
			continue
		if str((infos[key] as Dictionary).get("kind", "")) == "class":
			continue
		names.append(key)
	names.sort()
	return names


## Sync doc merge (curl/wget only): see merge_doc_data_async for the
## full version. Used by the sync dump_all() so library and analyzer
## paths never need awaiting.
func merge_doc_data(infos: Dictionary) -> Dictionary:
	var added := {"classes": 0, "constants": 0, "enums": 0}
	var mm := _major_minor(str(infos.get("__engine_version__", "")))
	if mm == "":
		return added
	var names := _doc_names(infos)
	var offline := false
	for tname in names:
		var body := ""
		if not offline:
			for url in _doc_urls(str(tname), mm):
				body = _download_text(str(url))
				if body != "":
					break
			if body == "":
				if names[0] == tname:
					offline = true
				continue
		if body == "":
			continue
		if _merge_doc_entry(infos, str(tname), body, added):
			added["classes"] = int(added["classes"]) + 1
	return added


## Async doc merge: same as merge_doc_data, but each URL tries
## curl/wget first and HTTPRequest second (last resort for tool-less
## environments). Used by dump_all_async(); library and analyzer paths
## keep the sync flavor so nothing else needs awaiting.
func merge_doc_data_async(infos: Dictionary, tree: SceneTree = null) -> Dictionary:
	var added := {"classes": 0, "constants": 0, "enums": 0}
	var mm := _major_minor(str(infos.get("__engine_version__", "")))
	if mm == "":
		return added
	var names := _doc_names(infos)
	var offline := false
	for tname in names:
		var body := ""
		if not offline:
			for url in _doc_urls(str(tname), mm):
				body = _download_text(str(url))
				if body == "":
					body = await download_text_async(str(url), tree)
				if body != "":
					break
			if body == "":
				if names[0] == tname:
					offline = true
				continue
		if body == "":
			continue
		if _merge_doc_entry(infos, str(tname), body, added):
			added["classes"] = int(added["classes"]) + 1
	return added


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
	var indexing: Variant = b.get("indexing_return_type", null)
	return {
		"name": tname,
		"kind": "builtin",
		"parent": VARIANT_ROOT,
		"inheritance_chain": [tname, VARIANT_ROOT],
		"is_instantiable": tname != "Nil",
		"is_keyed": bool(b.get("is_keyed", false)),
		"indexing_return_type": str(indexing) if indexing != null else null,
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
## Engine classes report results as return_value {type}, builtins as a
## return_type string; missing results mean void.
static func _method_info(m: Dictionary) -> Dictionary:
	return {
		"name": str(m.get("name", "")),
		"returns": _return_type_of(m),
		"is_vararg": bool(m.get("is_vararg", false)),
		"is_const": bool(m.get("is_const", false)),
		"is_virtual": bool(m.get("is_virtual", false)),
		"params": _params_info(m.get("arguments", [])),
	}


## Reads the result type of a method entry in either API shape.
static func _return_type_of(m: Dictionary) -> String:
	if m.has("return_type"):
		return _normalize_type_name(str(m["return_type"]))
	var rv: Variant = m.get("return_value", null)
	if rv is Dictionary:
		return _normalize_type_name(str((rv as Dictionary).get("type", "void")))
	return "void"


## Normalizes exotic type spellings from the extension API.
## typedarray::Node becomes Array[Node]; enum::X becomes int because
## enum values behave as ints for semantic purposes.
static func _normalize_type_name(t: String) -> String:
	if t.begins_with("typedarray::"):
		return "Array[" + t.trim_prefix("typedarray::") + "]"
	if t.begins_with("enum::"):
		return "int"
	return t


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


## True when path is a directory holding at least one visible file.
func _dir_has_files(path: String) -> bool:
	var d: DirAccess = DirAccess.open(path)
	if d == null:
		return false
	d.list_dir_begin()
	var found := false
	var f: String = d.get_next()
	while f != "":
		if not f.begins_with("."):
			found = true
			break
		f = d.get_next()
	d.list_dir_end()
	return found


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
