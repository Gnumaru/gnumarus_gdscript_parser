extends RefCounted

## Doc-fetch suite: builtin enums/constants come from doc XML downloads
## (ClassDB and the extension dump never carry them). Everything here
## is offline-safe: unit cases plus graceful-failure paths. Live merges
## are validated by regenerating the data dir, not by this suite.

const D = preload("res://addons/0GnumarusGodotProjectAnalyzerSuite/GnumarusGodotProjectAnalyzerSuiteGodotTypesInfoDumper.gd")
const H = preload("res://addons/0GnumarusGodotProjectAnalyzerSuite/tests/helpers.gd")


func run() -> Dictionary:
	var h = H.new()
	h.suite = "docfetch"
	_d_version(h)
	_d_urls(h)
	_d_parse(h)
	_d_graceful(h)
	_d_color_json(h)
	return h.result()


func _d_version(h) -> void:
	h.check(D._major_minor("Godot Engine v4.7.2.stable.official") == "4.7", "full version parses")
	h.check(D._major_minor("4.7.2.stable.official.ed1daf0bf") == "4.7", "bare version parses")
	h.check(D._major_minor("4.7") == "4.7", "short version parses")
	h.check(D._major_minor("garbage") == "", "garbage yields empty")
	h.check(D._major_minor("v4") == "", "major-only yields empty")


func _d_urls(h) -> void:
	var urls: Array = D._doc_urls("Color", "4.7")
	h.check(urls.size() == 2, "two url forms")
	h.check(str(urls[0]) == "https://raw.githubusercontent.com/godotengine/godot/refs/heads/4.7/doc/classes/Color.xml", "refs/heads form first")
	h.check(str(urls[1]) == "https://raw.githubusercontent.com/godotengine/godot/4.7/doc/classes/Color.xml", "short form fallback")


func _d_parse(h) -> void:
	var xml := "<class name=\"Vector2\"> <constants> <constant name=\"ZERO\" value=\"Vector2(0, 0)\">Desc.</constant> <constant name=\"AXIS_X\" value=\"0\" enum=\"Axis\">Desc.</constant> <constant name=\"AXIS_Y\" value=\"1\" enum=\"Axis\" /> </constants> </class>"
	var parsed: Dictionary = D._parse_doc_data(xml)
	var consts: Array = parsed.get("constants", [])
	h.check(consts.size() == 3, "all constants parsed")
	h.check(str((consts[0] as Dictionary).get("name", "")) == "ZERO", "first name kept")
	var enums: Array = parsed.get("enums", [])
	h.check(enums.size() == 1 and str((enums[0] as Dictionary).get("name", "")) == "Axis", "enum grouped")
	h.check(((enums[0] as Dictionary).get("values", []) as Array).size() == 2, "enum values grouped")
	h.check((D._parse_doc_data("not xml <oops") as Dictionary).get("constants", []).is_empty(), "garbage parses empty")


func _d_graceful(h) -> void:
	var d = D.new()
	h.check(d._download_text("http://127.0.0.1:9/nope.xml") == "", "unreachable download yields empty")
	h.check(D._major_minor("") == "", "empty version yields empty")


func _d_color_json(h) -> void:
	var info: Dictionary = h.load_json("res://.godot/0GnumarusGodotProjectAnalyzerSuiteData/builtin/Color.json")
	var names: Array = []
	for c in info.get("constants", []):
		names.append(str((c as Dictionary).get("name", "")))
	if names.is_empty():
		h.check(true, "Color.json constants skipped (offline regen)")
	else:
		h.check(names.has("RED"), "Color.json carries doc-merged RED")
