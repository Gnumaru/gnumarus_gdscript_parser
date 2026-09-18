extends RefCounted

## ClassDB merge suite: the extension-api dump misses entries (e.g.
## Object.free() in 4.7.2), so the dumper completes classes with live
## ClassDB data. Only additions, never overrides, idempotent.

const D = preload("res://addons/0GnumarusGodotProjectAnalyzerSuite/GnumarusGodotProjectAnalyzerSuiteGodotTypesInfoDumper.gd")
const H = preload("res://addons/0GnumarusGodotProjectAnalyzerSuite/tests/helpers.gd")


func run() -> Dictionary:
	var h = H.new()
	h.suite = "classdb"
	_c_type_ints(h)
	_c_merge_unit(h)
	_c_object_json(h)
	return h.result()


func _c_type_ints(h) -> void:
	h.check(Variant.Type.TYPE_NIL == 0, "TYPE_NIL is 0")
	h.check(Variant.Type.TYPE_INT == 2, "TYPE_INT is 2")
	h.check(Variant.Type.TYPE_OBJECT == 24, "TYPE_OBJECT is 24")
	h.check(Variant.Type.TYPE_ARRAY == 28, "TYPE_ARRAY is 28")
	h.check(Variant.Type.TYPE_MAX == 39, "TYPE_MAX is 39")


func _c_merge_unit(h) -> void:
	var d = D.new()
	var infos := {"Object": {"name": "Object", "kind": "class", "static_methods": [], "instance_methods": [{"name": "get_class", "returns": "StringName", "is_vararg": false, "params": []}], "signals": [], "properties": [], "enums": [], "constants": []}}
	var a1: Dictionary = d.merge_classdb(infos, false)
	h.check(int(a1.get("methods", 0)) > 0, "merge adds missing methods")
	var methods: Array = (infos["Object"] as Dictionary).get("instance_methods", [])
	var free_ok := false
	var kept := false
	for m in methods:
		if str((m as Dictionary).get("name", "")) == "free":
			free_ok = str((m as Dictionary).get("returns", "")) == "void"
		if str((m as Dictionary).get("name", "")) == "get_class":
			kept = str((m as Dictionary).get("returns", "")) == "StringName"
	h.check(free_ok, "free merged with void returns")
	h.check(kept, "dump entries never overridden")
	var a2: Dictionary = d.merge_classdb(infos, false)
	var total := 0
	for k in a2.keys():
		total += int(a2[k])
	h.check(total == 0, "merge is idempotent")


func _c_object_json(h) -> void:
	var info: Dictionary = h.load_json("res://.godot/0GnumarusGodotProjectAnalyzerSuiteData/classes/Object.json")
	var found := false
	for m in info.get("instance_methods", []):
		if str((m as Dictionary).get("name", "")) == "free":
			found = true
	h.check(found, "Object.json carries ClassDB-merged free()")
