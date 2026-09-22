# @integrity_ignore_file (test harness uses virtual paths)
extends RefCounted

## Scene/resource/config suite: tscn/tres/project.godot parsing into
## nested Arrays and Dictionaries (sections, unwrapped attrs, value
## nodes), plus file fixtures and instance reuse.

const Scene = preload("res://addons/0GnumarusGodotProjectAnalyzerSuite/GnumarusGodotProjectAnalyzerSuiteTextResourceParser.gd")
const H = preload("res://addons/0GnumarusGodotProjectAnalyzerSuite/tests/helpers.gd")

const DIR := "res://addons/0GnumarusGodotProjectAnalyzerSuite/tests/"


func run() -> Dictionary:
	var h = H.new()
	h.suite = "scene"
	_s_values(h)
	_s_sections(h)
	_s_multiline(h)
	_s_comments(h)
	_s_errors(h)
	_s_reuse(h)
	_s_fixtures(h)
	_s_project(h)
	return h.result()


func _prop(data: Dictionary, section: String, idx: int, prop: String) -> Dictionary:
	var list: Array = data.get(section, []) as Array
	return ((list[idx] as Dictionary).get("props", {}) as Dictionary).get(prop, {}) as Dictionary


func _s_values(h) -> void:
	var p = Scene.new()
	var d := p.parse_text("[resource]\na = 1\nb = 0.5\nc = true\nd = null\ne = \"hi\"\nf = Color(1, 0, 0, 1)\n")
	h.check(int(d.get("errors", -1)) == 0, "scalars parse clean")
	h.check((d.get("resources", []) as Array).size() == 1, "one resource section")
	var props: Dictionary = ((d.get("resources", []) as Array)[0] as Dictionary).get("props", {})
	h.check(str((props.get("a", {}) as Dictionary).get("type", "")) == "int", "int node type")
	h.check(int((props.get("a", {}) as Dictionary).get("value", 0)) == 1, "int node value")
	h.check(str((props.get("b", {}) as Dictionary).get("type", "")) == "float", "float node type")
	h.check(str((props.get("c", {}) as Dictionary).get("type", "")) == "bool", "bool node type")
	h.check(str((props.get("d", {}) as Dictionary).get("type", "")) == "null", "null node type")
	h.check(str((props.get("e", {}) as Dictionary).get("value", "")) == "hi", "string node value")
	var f: Dictionary = props.get("f", {})
	h.check(str(f.get("type", "")) == "call" and str(f.get("name", "")) == "Color", "call node name")
	h.check(((f.get("args", []) as Array).size()) == 4, "call node arity")
	var g := p.parse_text("[resource]\nv = [1, \"a\", [true, null]]\nm = {\"k\": 2, \"j\": [1]}\n")
	h.check(int(g.get("errors", -1)) == 0, "collections parse clean")
	var v: Dictionary = ((g.get("resources", []) as Array)[0] as Dictionary).get("props", {}).get("v", {})
	h.check(str(v.get("type", "")) == "array" and (v.get("items", []) as Array).size() == 3, "nested array items")
	h.check(str(((v.get("items", []) as Array)[2] as Dictionary).get("type", "")) == "array", "array in array")
	var m: Dictionary = ((g.get("resources", []) as Array)[0] as Dictionary).get("props", {}).get("m", {})
	h.check(str(m.get("type", "")) == "dict" and (m.get("entries", []) as Array).size() == 2, "dict entries")


func _s_sections(h) -> void:
	var d := Scene.new().parse_text("[gd_scene format=3 uid=\"uid://abc\"]\n\n[ext_resource type=\"Script\" path=\"res://x.gd\" id=\"1\"]\n\n[node name=\"Root\" type=\"Node3D\"]\nvisible = false\n")
	h.check(str(d.get("kind", "")) == "scene", "scene kind")
	h.check(int(d.get("errors", -1)) == 0, "sections parse clean")
	h.check(str(((d.get("header", {}) as Dictionary).get("attrs", {}) as Dictionary).get("uid", "")) == "uid://abc", "header attrs")
	h.check(int(((d.get("header", {}) as Dictionary).get("attrs", {}) as Dictionary).get("format", 0)) == 3, "header format int")
	h.check((d.get("ext_resources", []) as Array).size() == 1, "one ext resource")
	h.check((d.get("nodes", []) as Array).size() == 1, "one node")
	var node: Dictionary = (d.get("nodes", []) as Array)[0]
	h.check(str((node.get("attrs", {}) as Dictionary).get("name", "")) == "Root", "node name attr")
	var vis: Dictionary = (node.get("props", {}) as Dictionary).get("visible", {})
	h.check(str(vis.get("type", "")) == "bool" and not bool(vis.get("value", true)), "node bool prop")
	var r := Scene.new().parse_text("[gd_resource type=\"Environment\" format=3]\n\n[resource]\nbackground_mode = 2\n")
	h.check(str(r.get("kind", "")) == "resource", "resource kind")
	h.check((r.get("resources", []) as Array).size() == 1, "one resource body")


func _s_multiline(h) -> void:
	var d := Scene.new().parse_text("[node name=\"N\" type=\"Node\"]\nmyvar = [true, 0.1, 1, \"asdf\", {\n\"asdf\": 1\n}]\n")
	h.check(int(d.get("errors", -1)) == 0, "multiline array clean")
	var v: Dictionary = ((d.get("nodes", []) as Array)[0] as Dictionary).get("props", {}).get("myvar", {})
	h.check(str(v.get("type", "")) == "array" and (v.get("items", []) as Array).size() == 5, "multiline array items")
	h.check(str((((v.get("items", []) as Array)[4] as Dictionary).get("type", ""))) == "dict", "dict inside multiline array")
	var t := Scene.new().parse_text("[sub_resource type=\"GDScript\" id=\"g\"]\nscript/source = \"extends Node\n@export var x := 1\n\"\n")
	h.check(int(t.get("errors", -1)) == 0, "multiline string clean")
	var src: Dictionary = ((t.get("sub_resources", []) as Array)[0] as Dictionary).get("props", {}).get("script/source", {})
	h.check(str(src.get("type", "")) == "string" and "extends Node" in str(src.get("value", "")), "multiline string keeps lines")
	h.check("@" in str(src.get("value", "")), "multiline string keeps annotation text")


func _s_comments(h) -> void:
	var d := Scene.new().parse_text("; full line comment\n[resource] ; trailing note\n; another\na = 1 ; inline\n")
	h.check(int(d.get("errors", -1)) == 0, "comments ignored")
	var props: Dictionary = ((d.get("resources", []) as Array)[0] as Dictionary).get("props", {})
	h.check(int((props.get("a", {}) as Dictionary).get("value", 0)) == 1, "value after comments")


func _s_errors(h) -> void:
	var p = Scene.new()
	var bad := p.parse_text("[node name=\"X\"\na = 1\n")
	h.check(int(bad.get("errors", 0)) > 0, "unclosed header errors")
	h.check(p.last_error != "", "last_error set on failure")
	var bad2 := p.parse_text("[resource]\na = [1, 2\n")
	h.check(int(bad2.get("errors", 0)) > 0, "unclosed array errors")
	var ok := p.parse_text("[resource]\na = 1\n")
	h.check(int(ok.get("errors", -1)) == 0 and p.last_error == "", "reuse resets errors")


func _s_reuse(h) -> void:
	var p = Scene.new()
	var first := p.parse("[resource]\na = 1\n")
	var second := p.parse_text("[resource]\nb = 2\n")
	h.check(not ((first.get("resources", []) as Array)[0] as Dictionary).get("props", {}).has("b"), "first result untouched by reuse")
	h.check(((second.get("resources", []) as Array)[0] as Dictionary).get("props", {}).has("b"), "second parse independent")
	h.check(not ((second.get("resources", []) as Array)[0] as Dictionary).get("props", {}).has("a"), "no prop leak across parses")
	var from_file := p.parse(DIR + "Sky.tres")
	var raw: String = FileAccess.get_file_as_string(DIR + "Sky.tres")
	var from_text := p.parse_text(raw)
	h.check(str(from_file.get("kind", "")) == str(from_text.get("kind", "")), "parse path equals parse_text")
	h.check((from_file.get("sub_resources", []) as Array).size() == (from_text.get("sub_resources", []) as Array).size(), "path/text same sections")


func _node_by_name(data: Dictionary, name: String) -> Dictionary:
	for n in data.get("nodes", []):
		if str((n as Dictionary).get("attrs", {}).get("name", "")) == name:
			return n
	return {}


func _s_fixtures(h) -> void:
	var tscn := Scene.new().parse(DIR + "Node3D.tscn")
	h.check(int(tscn.get("errors", -1)) == 0, "Node3D.tscn zero errors")
	h.check(str(tscn.get("kind", "")) == "scene", "Node3D.tscn kind scene")
	h.check((tscn.get("ext_resources", []) as Array).size() == 1, "Node3D.tscn one ext")
	h.check((tscn.get("sub_resources", []) as Array).size() == 4, "Node3D.tscn four subs")
	h.check((tscn.get("nodes", []) as Array).size() == 4, "Node3D.tscn four nodes")
	var light := _node_by_name(tscn, "DirectionalLight3D")
	h.check(not light.is_empty(), "directional light found")
	var tr: Dictionary = (light.get("props", {}) as Dictionary).get("transform", {})
	h.check(str(tr.get("type", "")) == "call" and str(tr.get("name", "")) == "Transform3D", "transform call node")
	h.check((tr.get("args", []) as Array).size() == 12, "transform twelve args")
	var extra := _node_by_name(tscn, "Node")
	var myvar: Dictionary = (extra.get("props", {}) as Dictionary).get("myvar", {})
	h.check(str(myvar.get("type", "")) == "array" and (myvar.get("items", []) as Array).size() == 5, "fixture multiline myvar")
	var env := Scene.new().parse(DIR + "Environment.tres")
	h.check(int(env.get("errors", -1)) == 0, "Environment.tres zero errors")
	h.check(str(env.get("kind", "")) == "resource", "Environment.tres kind resource")
	h.check((env.get("sub_resources", []) as Array).size() == 2, "Environment.tres two subs")
	h.check((env.get("resources", []) as Array).size() == 1, "Environment.tres one body")
	var sky_mat := Scene.new().parse(DIR + "ProceduralSkyMaterial.tres")
	h.check(int(sky_mat.get("errors", -1)) == 0, "ProceduralSkyMaterial.tres zero errors")
	h.check((sky_mat.get("resources", []) as Array).size() == 1, "sky material one body")
	var sky := Scene.new().parse(DIR + "Sky.tres")
	h.check(int(sky.get("errors", -1)) == 0, "Sky.tres zero errors")
	h.check((sky.get("sub_resources", []) as Array).size() == 1, "Sky.tres one sub")


func _s_project(h) -> void:
	var d := Scene.new().parse("res://project.godot")
	h.check(int(d.get("errors", -1)) == 0, "project.godot zero errors")
	h.check(str(d.get("kind", "")) == "config", "project.godot kind config")
	var cfg: Dictionary = d.get("globals", {}).get("config_version", {})
	h.check(str(cfg.get("type", "")) == "int" and int(cfg.get("value", 0)) == 5, "project config_version")
	var app := {}
	for s in d.get("sections", []):
		if str((s as Dictionary).get("section", "")) == "application":
			app = s
	h.check(not (app as Dictionary).is_empty(), "project application section")
	var nm: Dictionary = (app as Dictionary).get("props", {}).get("config/name", {})
	h.check(str(nm.get("value", "")) == "gnumarus_gdscript_parser", "project name prop")
	var feats: Dictionary = (app as Dictionary).get("props", {}).get("config/features", {})
	h.check(str(feats.get("type", "")) == "call" and str(feats.get("name", "")) == "PackedStringArray", "project features call")
