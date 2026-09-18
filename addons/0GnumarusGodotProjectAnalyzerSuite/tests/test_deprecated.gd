extends RefCounted

## @deprecated rule suite (migrated from the scratch runner).

const Syn = preload("res://addons/0GnumarusGodotProjectAnalyzerSuite/GnumarusGodotProjectAnalyzerSuiteGdscriptSyntaticParser.gd")
const Ana = preload("res://addons/0GnumarusGodotProjectAnalyzerSuite/GnumarusGodotProjectAnalyzerSuiteGdscriptAnalyzer.gd")
const H = preload("res://addons/0GnumarusGodotProjectAnalyzerSuite/tests/helpers.gd")


func run() -> Dictionary:
	var h = H.new()
	h.suite = "deprecated"
	_t01(h)
	_t02(h)
	_t03(h)
	_t04(h)
	_t05(h)
	_t06(h)
	_t07(h)
	_t08(h)
	_t09(h)
	_t10(h)
	_t11(h)
	_t12(h)
	_t13(h)
	_t14_cross(h)
	return h.result()


func _t01(h) -> void:
	var src := "extends Node\n# @deprecated Use new_api() instead.\nfunc old_api() -> void:\n\tpass\nfunc user() -> void:\n\told_api()\n"
	var res: Dictionary = h.analyze_text(src, "res://tests/tmp_t01.gd")
	h.check((res.get("warnings", []) as Array).size() == 1, "t01 one warning")
	h.check(h.has_warn(res, "use of deprecated function 'old_api'"), "t01 names function")
	h.check(h.has_warn(res, "Use new_api() instead."), "t01 keeps message")


func _t02(h) -> void:
	var src := "extends Node\n# @deprecated\nfunc old_api() -> void:\n\tpass\nfunc user() -> void:\n\tpass\n"
	var res: Dictionary = h.analyze_text(src, "res://tests/tmp_t02.gd")
	h.check((res.get("warnings", []) as Array).is_empty(), "t02 no warnings when unused")
	h.check((res.get("errors", []) as Array).is_empty(), "t02 no errors")


func _t03(h) -> void:
	var src := "extends Node\n# @deprecated\nvar health := 10\nfunc f() -> void:\n\tprint(health)\n\thealth = 5\n"
	var res: Dictionary = h.analyze_text(src, "res://tests/tmp_t03.gd")
	h.check((res.get("warnings", []) as Array).size() == 2, "t03 read+write warn")
	h.check(h.has_warn(res, "use of deprecated variable 'health'"), "t03 names variable")


func _t04(h) -> void:
	var src := "extends Node\n# @deprecated\nsignal changed\nfunc f() -> void:\n\tchanged.connect(_h)\n\tchanged.emit()\nfunc _h() -> void:\n\tpass\n"
	var res: Dictionary = h.analyze_text(src, "res://tests/tmp_t04.gd")
	h.check((res.get("warnings", []) as Array).size() == 2, "t04 connect+emit warn")
	h.check(h.has_warn(res, "use of deprecated signal 'changed'"), "t04 names signal")


func _t05(h) -> void:
	var src := "extends Node\n# @deprecated\nconst MAX := 10\n# @deprecated\nenum State { IDLE }\nfunc f() -> int:\n\tprint(MAX)\n\treturn State.IDLE\n"
	var res: Dictionary = h.analyze_text(src, "res://tests/tmp_t05.gd")
	h.check((res.get("warnings", []) as Array).size() == 2, "t05 const+enum warn")
	h.check(h.has_warn(res, "'MAX'"), "t05 names const")
	h.check(h.has_warn(res, "'State'"), "t05 names enum")


func _t06(h) -> void:
	var src := "extends Node\n# @deprecated\nclass Item:\n\tvar id := 0\nfunc f() -> void:\n\tvar it := Item.new()\n\tprint(it)\n"
	var res: Dictionary = h.analyze_text(src, "res://tests/tmp_t06.gd")
	h.check(h.has_warn(res, "'Item'"), "t06 inner class instantiation warns")
	var src2 := "extends Node\nclass Item:\n\t# @deprecated\n\tstatic func make() -> void:\n\t\tpass\nfunc f() -> void:\n\tItem.make()\n"
	var res2: Dictionary = h.analyze_text(src2, "res://tests/tmp_t06b.gd")
	h.check(h.has_warn(res2, "'Item.make'"), "t06 inner static method warns")
	var src3 := "extends Node\nclass Item:\n\tpass\nfunc f(param: Item) -> void:\n\tpass\n"
	var res3: Dictionary = h.analyze_text(src3, "res://tests/tmp_t06c.gd")
	h.check((res3.get("warnings", []) as Array).is_empty(), "t06 non-deprecated inner clean")


func _t07(h) -> void:
	var src := "class_name MyLib\nextends Node\n# @deprecated\nstatic func old_static() -> void:\n\tpass\n# @deprecated\nvar thing := 1\nfunc f() -> void:\n\tMyLib.old_static()\n\tself.thing = 2\n"
	var res: Dictionary = h.analyze_text(src, "res://tests/tmp_t07.gd")
	h.check(h.has_warn(res, "MyLib.old_static"), "t07 static call warns")
	h.check(h.has_warn(res, "thing"), "t07 self write warns")


func _t08(h) -> void:
	var src := "extends Node\n# @deprecated\nvar health := 10\nfunc f(health: int) -> void:\n\tprint(health)\n"
	var res: Dictionary = h.analyze_text(src, "res://tests/tmp_t08.gd")
	h.check((res.get("warnings", []) as Array).is_empty(), "t08 param shadows member")
	var src2 := "extends Node\n# @deprecated\nfunc helper() -> void:\n\tpass\nfunc f() -> void:\n\tvar helper := 1\n\tprint(helper)\n"
	var res2: Dictionary = h.analyze_text(src2, "res://tests/tmp_t08b.gd")
	h.check((res2.get("warnings", []) as Array).is_empty(), "t08 local shadows func")


func _t09(h) -> void:
	var src := "extends Node\nfunc f() -> void:\n\t# @deprecated\n\tpass\n"
	var res: Dictionary = h.analyze_text(src, "res://tests/tmp_t09.gd")
	h.check(h.err_kinds(res).has("deprecated_misplaced"), "t09 misplaced error")


func _t10(h) -> void:
	var src := "extends Node\nfunc f(\n\t\t# @deprecated\n\t\ta: int\n\t) -> void:\n\tpass\n"
	var res: Dictionary = h.analyze_text(src, "res://tests/tmp_t10.gd")
	h.check(h.err_kinds(res).has("deprecated_unsupported"), "t10 params unsupported error")


func _t11(h) -> void:
	var src := "# @deprecated Whole script is old.\nclass_name OldLib\nextends Node\nvar x := 1\nfunc f() -> void:\n\tprint(x)\n"
	var res: Dictionary = h.analyze_text(src, "res://tests/tmp_t11.gd")
	h.check((res.get("warnings", []) as Array).is_empty(), "t11 no internal warnings")
	h.check((res.get("errors", []) as Array).is_empty(), "t11 no errors")
	var info: Dictionary = h.load_json("res://.godot/0GnumarusGodotProjectAnalyzerSuiteData/user/OldLib.json")
	h.check(str(info.get("deprecated", {}).get("message", "")) == "Whole script is old.", "t11 json marks script")


func _t12(h) -> void:
	var src := "class_name MyLib2\nextends Node\n# @deprecated\nfunc old_fn() -> void:\n\tpass\nfunc f() -> void:\n\told_fn()\n"
	var res: Dictionary = h.analyze_text(src, "res://tests/tmp_t12.gd")
	h.check(res.has("ast") and res.has("errors") and res.has("warnings"), "t12 return shape")
	h.check(((res.get("ast", {}) as Dictionary).has("analyzer_errors")), "t12 ast has analyzer_errors")
	h.check(((res.get("ast", {}) as Dictionary).has("analyzer_warnings")), "t12 ast has analyzer_warnings")
	var info: Dictionary = h.load_json("res://.godot/0GnumarusGodotProjectAnalyzerSuiteData/user/MyLib2.json")
	var flagged := false
	for m in info.get("instance_methods", []):
		if str((m as Dictionary).get("name", "")) == "old_fn" and (m as Dictionary).has("deprecated"):
			flagged = true
	h.check(flagged, "t12 json flags member")
	h.check(((info.get("analysis_warnings", []) as Array).size()) == 1, "t12 json has warning")
	h.check(((info.get("analysis_errors", []) as Array).is_empty()), "t12 json no errors")
	var marked := false
	for c in ((res.get("ast", {}) as Dictionary).get("children", []) as Array):
		if (c as Dictionary).get("type", "") == "FUNC_DECL" and str((c as Dictionary).get("name", "")) == "old_fn" and (c as Dictionary).has("deprecated"):
			marked = true
	h.check(marked, "t12 ast node marked")


func _t13(h) -> void:
	var syn = Syn.new()
	var ana = Ana.new()
	var ast: Dictionary = syn.parse("res://addons/0GnumarusGodotProjectAnalyzerSuite/tests/ValidScript0.gd")
	var res: Dictionary = ana.analyze(ast, "res://addons/0GnumarusGodotProjectAnalyzerSuite/tests/ValidScript0.gd")
	h.check((res.get("errors", []) as Array).is_empty(), "t13 fixture no errors")
	h.check((res.get("warnings", []) as Array).is_empty(), "t13 fixture no warnings")


func _t14_cross(h) -> void:
	# Library first: analyzing it writes user/TmpDepCrossLib.json
	# carrying the deprecated flag the consumer warns consult.
	var lib := "class_name TmpDepCrossLib\nextends RefCounted\n# @deprecated Use fresh() instead.\nfunc old_fn() -> void:\n\tpass\nfunc fresh() -> void:\n\tpass\n"
	h.analyze_text(lib, "res://tests/tmp_dep_cross_lib.gd")
	var src := "extends RefCounted\nfunc f(v: Variant) -> void:\n\tv.old_fn()\n\tif v is TmpDepCrossLib:\n\t\tv.old_fn()\n\t\tv.fresh()\n"
	var res: Dictionary = h.analyze_text(src, "res://tests/tmp_dep_cross_consumer.gd")
	var lines: Array = []
	for w in res.get("warnings", []):
		if str((w as Dictionary).get("kind", "")) == "deprecated_use":
			lines.append(int((w as Dictionary).get("line", 0)))
	h.check(lines == [5], "narrowed cross-script call warns once")
	h.check(h.has_warn(res, "TmpDepCrossLib.old_fn"), "cross message names member")
	h.check(h.has_warn(res, "Use fresh() instead."), "cross warning keeps message")
