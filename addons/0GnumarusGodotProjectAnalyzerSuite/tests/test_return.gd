extends RefCounted

## @return rule suite: placement, union shape, known names, "->"
## compatibility (equal or narrower), and value/bare return presence.

const H = preload("res://addons/0GnumarusGodotProjectAnalyzerSuite/tests/helpers.gd")


func run() -> Dictionary:
	var h = H.new()
	h.suite = "return"
	_r_void_forms(h)
	_r_bare_value(h)
	_r_arrow_compat(h)
	_r_unions(h)
	_r_names(h)
	_r_malformed(h)
	_r_misplaced(h)
	_r_lambdas(h)
	_r_script_types(h)
	_r_marks_and_skips(h)
	return h.result()


func _err_texts(res: Dictionary) -> Array:
	var out: Array = []
	for e in res.get("errors", []):
		out.append(str((e as Dictionary).get("message", "")))
	return out


func _has_err(res: Dictionary, kind: String, part: String) -> bool:
	for e in res.get("errors", []):
		if str((e as Dictionary).get("kind", "")) == kind and part in str((e as Dictionary).get("message", "")):
			return true
	return false


func _kinds(res: Dictionary) -> Array:
	var out: Array = []
	for e in res.get("errors", []):
		out.append(str((e as Dictionary).get("kind", "")))
	return out


func _r_void_forms(h) -> void:
	var src := "extends Node\n# @return void\nfunc f() -> void:\n\tpass\n"
	var res: Dictionary = h.analyze_text(src, "res://tests/tmp_ret_void.gd")
	h.check((res.get("errors", []) as Array).is_empty(), "void + -> void clean")
	var src2 := "extends Node\n# @return void\nfunc g():\n\treturn\n"
	var res2: Dictionary = h.analyze_text(src2, "res://tests/tmp_ret_void2.gd")
	h.check((res2.get("errors", []) as Array).is_empty(), "void bare return clean")


func _r_bare_value(h) -> void:
	var src := "extends Node\n# @return void\nfunc f() -> void:\n\treturn 1\n"
	var res: Dictionary = h.analyze_text(src, "res://tests/tmp_ret_val.gd")
	h.check(_has_err(res, "return_value", "cannot return a value from void function 'f'"), "value in void errors")
	var src2 := "extends Node\n# @return int\nfunc f():\n\treturn\n"
	var res2: Dictionary = h.analyze_text(src2, "res://tests/tmp_ret_bare.gd")
	h.check(_has_err(res2, "return_value", "bare return in non-void function 'f'"), "bare in non-void errors")
	var src3 := "extends Node\n# @return int\nfunc f():\n\treturn 1\n"
	var res3: Dictionary = h.analyze_text(src3, "res://tests/tmp_ret_ok.gd")
	h.check((res3.get("errors", []) as Array).is_empty(), "value in non-void clean")


func _r_arrow_compat(h) -> void:
	var ok := "extends Node\n# @return Control\nfunc f() -> Node:\n\tpass\n"
	h.check((h.analyze_text(ok, "res://tests/tmp_ret_sub.gd").get("errors", []) as Array).is_empty(), "narrower @return (Control for -> Node) clean")
	var same := "extends Node\n# @return int\nfunc f() -> int:\n\treturn 1\n"
	h.check((h.analyze_text(same, "res://tests/tmp_ret_same.gd").get("errors", []) as Array).is_empty(), "equal @return clean")
	var wide := "extends Node\n# @return Node\nfunc f() -> Control:\n\tpass\n"
	var res: Dictionary = h.analyze_text(wide, "res://tests/tmp_ret_wide.gd")
	h.check(_has_err(res, "return_mismatch", "'Node' is neither 'Control' nor a subclass"), "wider @return mismatches")
	var tov := "extends Node\n# @return int\nfunc f() -> void:\n\tpass\n"
	h.check(_kinds(h.analyze_text(tov, "res://tests/tmp_ret_tov.gd")).has("return_mismatch"), "non-void @return on -> void mismatches")
	var vot := "extends Node\n# @return void\nfunc f() -> int:\n\treturn 1\n"
	h.check(_kinds(h.analyze_text(vot, "res://tests/tmp_ret_vot.gd")).has("return_mismatch"), "void @return on -> int mismatches")


func _r_unions(h) -> void:
	var src := "extends Node\n# @return Object|String|int\nfunc f():\n\tpass\n"
	h.check((h.analyze_text(src, "res://tests/tmp_ret_union.gd").get("errors", []) as Array).is_empty(), "union of known types clean")
	var src2 := "extends Node\n# @return Control|Node\nfunc f() -> Object:\n\tpass\n"
	h.check((h.analyze_text(src2, "res://tests/tmp_ret_union2.gd").get("errors", []) as Array).is_empty(), "union members narrower than -> clean")
	var src3 := "extends Node\n# @return Control|Object\nfunc f() -> Node:\n\tpass\n"
	var res3: Dictionary = h.analyze_text(src3, "res://tests/tmp_ret_union3.gd")
	var bad := 0
	for e in res3.get("errors", []):
		if str((e as Dictionary).get("kind", "")) == "return_mismatch":
			bad += 1
	h.check(bad == 1, "only the wider union member mismatches")


func _r_names(h) -> void:
	var src := "extends Node\n# @return NopeType\nfunc f():\n\tpass\n"
	h.check(_has_err(h.analyze_text(src, "res://tests/tmp_ret_unk.gd"), "return_unknown_type", "'NopeType'"), "unknown member errors")
	var src2 := "extends Node\n# @return Variant\nfunc f():\n\tpass\n"
	h.check((h.analyze_text(src2, "res://tests/tmp_ret_var.gd").get("errors", []) as Array).is_empty(), "Variant known")


func _r_malformed(h) -> void:
	h.check(_kinds(h.analyze_text("extends Node\n# @return\nfunc f():\n\tpass\n", "res://tests/tmp_ret_m1.gd")).has("return_malformed"), "empty spec malformed")
	h.check(_kinds(h.analyze_text("extends Node\n# @return 123\nfunc f():\n\tpass\n", "res://tests/tmp_ret_m2.gd")).has("return_malformed"), "non-identifier malformed")
	h.check(_kinds(h.analyze_text("extends Node\n# @return int|\nfunc f():\n\tpass\n", "res://tests/tmp_ret_m3.gd")).has("return_malformed"), "empty union arm malformed")
	h.check(_kinds(h.analyze_text("extends Node\n# @return void|int\nfunc f():\n\tpass\n", "res://tests/tmp_ret_m4.gd")).has("return_malformed"), "void combined malformed")


func _r_misplaced(h) -> void:
	h.check(_kinds(h.analyze_text("extends Node\n# @return int\nvar x := 1\n", "res://tests/tmp_ret_p1.gd")).has("return_misplaced"), "@return on var misplaced")
	h.check(_kinds(h.analyze_text("extends Node\n# @return int\nsignal s\n", "res://tests/tmp_ret_p2.gd")).has("return_misplaced"), "@return on signal misplaced")
	h.check(_kinds(h.analyze_text("extends Node\nfunc f(\n\t\t# @return int\n\t\ta: int\n\t) -> void:\n\tpass\n", "res://tests/tmp_ret_p3.gd")).has("return_misplaced"), "@return on param misplaced")
	h.check(_kinds(h.analyze_text("# @return int\nclass_name Foo\n", "res://tests/tmp_ret_p4.gd")).has("return_misplaced"), "@return at root misplaced")


func _r_lambdas(h) -> void:
	var src := "extends Node\n# @return int\nvar f = func():\n\treturn 1\n"
	h.check((h.analyze_text(src, "res://tests/tmp_ret_l1.gd").get("errors", []) as Array).is_empty(), "lambda with value clean")
	var src2 := "extends Node\n# @return void\nvar f = func():\n\treturn 1\n"
	h.check(_has_err(h.analyze_text(src2, "res://tests/tmp_ret_l2.gd"), "return_value", "void function <lambda>"), "lambda value in void errors")
	var src3 := "extends Node\n# @return int\nvar f = func():\n\treturn\n"
	h.check(_has_err(h.analyze_text(src3, "res://tests/tmp_ret_l3.gd"), "return_value", "non-void function <lambda>"), "lambda bare return errors")
	var src4 := "extends Node\n# @return int\nvar f = func() -> int:\n\treturn 1\n"
	h.check((h.analyze_text(src4, "res://tests/tmp_ret_l4.gd").get("errors", []) as Array).is_empty(), "lambda arrow compatible clean")


func _r_script_types(h) -> void:
	var src := "extends Node\nclass Base:\n\tpass\nclass Child extends Base:\n\tpass\n# @return Child\nfunc f() -> Base:\n\tpass\n"
	h.check((h.analyze_text(src, "res://tests/tmp_ret_s1.gd").get("errors", []) as Array).is_empty(), "script subclass narrower clean")
	var src2 := "extends Node\nclass Base:\n\tpass\nclass Child extends Base:\n\tpass\n# @return Base\nfunc f() -> Child:\n\tpass\n"
	h.check(_kinds(h.analyze_text(src2, "res://tests/tmp_ret_s2.gd")).has("return_mismatch"), "script wider mismatches")


func _r_marks_and_skips(h) -> void:
	var src := "extends Node\n# @return int\nfunc f():\n\treturn 1\n"
	var res: Dictionary = h.analyze_text(src, "res://tests/tmp_ret_mark.gd")
	var marked := false
	for c in ((res.get("ast", {}) as Dictionary).get("children", []) as Array):
		if (c as Dictionary).get("type", "") == "FUNC_DECL" and (c as Dictionary).has("return_ann"):
			marked = true
	h.check(marked, "func node stamped with return_ann")
	var src2 := "extends Node\n# @return int\nfunc f() -> Array[int]:\n\treturn []\n"
	h.check((h.analyze_text(src2, "res://tests/tmp_ret_cx.gd").get("errors", []) as Array).is_empty(), "complex -> skips mismatch check")
	var src3 := "extends Node\n# @return Node\nfunc f() -> Variant:\n\tpass\n"
	h.check((h.analyze_text(src3, "res://tests/tmp_ret_top.gd").get("errors", []) as Array).is_empty(), "anything narrows Variant")
