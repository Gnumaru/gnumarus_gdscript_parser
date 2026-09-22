# @integrity_ignore_file (test harness uses virtual paths)
extends RefCounted

## @param rule suite: before-parameter (multiline lists) and
## before-function/lambda uses, with @var-style narrowing.

const H = preload("res://addons/0GnumarusGodotProjectAnalyzerSuite/tests/helpers.gd")


func run() -> Dictionary:
	var h = H.new()
	h.suite = "param"
	_p_user_example(h)
	_p_before_func(h)
	_p_multi_pair(h)
	_p_direct(h)
	_p_carrier(h)
	_p_malformed(h)
	_p_misplaced(h)
	_p_marks(h)
	return h.result()


func _kinds(res: Dictionary) -> Array:
	var out: Array = []
	for e in res.get("errors", []):
		out.append(str((e as Dictionary).get("kind", "")))
	return out


func _has_err(res: Dictionary, kind: String, part: String) -> bool:
	for e in res.get("errors", []):
		if str((e as Dictionary).get("kind", "")) == kind and part in str((e as Dictionary).get("message", "")):
			return true
	return false


func _clean(res: Dictionary) -> bool:
	return (res.get("errors", []) as Array).is_empty()


func _p_user_example(h) -> void:
	var src := "extends Node\n# @param myparam1 int|Object\nfunc myfunc1(myparam1):\n\n\tvar mylambda = func(\n\t\t# @param myparam2 String|Object\n\t\tmyparam2: Variant\n\t):\n\t\treturn\n\n\treturn\n"
	h.check(_clean(h.analyze_text(src, "res://tests/tmp_par_ex.gd")), "user example clean")


func _p_before_func(h) -> void:
	h.check(_clean(h.analyze_text("extends Node\n# @param a Control\nfunc f(a: Node):\n\tpass\n", "res://tests/tmp_par_b1.gd")), "before-func narrow clean")
	h.check(_clean(h.analyze_text("extends Node\n# @param a int\nfunc f(a):\n\tpass\n", "res://tests/tmp_par_b2.gd")), "before-func untyped clean")
	h.check(_has_err(h.analyze_text("extends Node\n# @param a Object\nfunc f(a: Node):\n\tpass\n", "res://tests/tmp_par_b3.gd"), "param_mismatch", "'Object' is neither 'Node'"), "before-func widen mismatches")
	h.check(_has_err(h.analyze_text("extends Node\n# @param z int\nfunc f(a):\n\tpass\n", "res://tests/tmp_par_b4.gd"), "param_unknown", "does not match any parameter of function 'f'"), "before-func unknown param errors")
	h.check(_clean(h.analyze_text("extends Node\n# @return int\n# @param a int\nfunc f(a):\n\treturn 1\n", "res://tests/tmp_par_b5.gd")), "colocated with @return clean")


func _p_multi_pair(h) -> void:
	h.check(_clean(h.analyze_text("extends Node\n# @param a int\n# @param b String\nfunc f(a, b):\n\tpass\n", "res://tests/tmp_par_m1.gd")), "merged pair block clean")
	h.check(_has_err(h.analyze_text("extends Node\n# @param a int\n# @param b Nope\nfunc f(a, b):\n\tpass\n", "res://tests/tmp_par_m2.gd"), "param_unknown_type", "'Nope'"), "merged block bad member errors")
	var res: Dictionary = h.analyze_text("extends Node\n# @param a Control|Object\nfunc f(a: Node):\n\tpass\n", "res://tests/tmp_par_m3.gd")
	var n := 0
	for e in res.get("errors", []):
		if str((e as Dictionary).get("kind", "")) == "param_mismatch":
			n += 1
	h.check(n == 1, "only the wider union member mismatches")


func _p_direct(h) -> void:
	h.check(_clean(h.analyze_text("extends Node\nfunc f(\n\t# @param a int\n\ta: Variant\n):\n\tpass\n", "res://tests/tmp_par_d1.gd")), "direct narrow clean")
	h.check(_has_err(h.analyze_text("extends Node\nfunc f(\n\t# @param a String\n\ta: int\n):\n\tpass\n", "res://tests/tmp_par_d2.gd"), "param_mismatch", "declared as 'int'"), "direct widen mismatches")
	h.check(_has_err(h.analyze_text("extends Node\nfunc f(\n\t# @param b int\n\ta: int\n):\n\tpass\n", "res://tests/tmp_par_d3.gd"), "param_unknown", "does not match parameter 'a'"), "direct name mismatch errors")


func _p_carrier(h) -> void:
	h.check(_clean(h.analyze_text("extends Node\n# @param x int\nvar f = func(x):\n\tpass\n", "res://tests/tmp_par_c1.gd")), "lambda carrier clean")
	h.check(_has_err(h.analyze_text("extends Node\n# @param y int\nvar f = func(x):\n\tpass\n", "res://tests/tmp_par_c2.gd"), "param_unknown", "function <lambda>"), "lambda carrier unknown errors")
	h.check(_clean(h.analyze_text("class_name PLib\nextends Node\nclass Inner:\n\t# @param a Control\n\tfunc f(a: Node):\n\t\tpass\n", "res://tests/tmp_par_c3.gd")), "before-func inside class clean")


func _p_malformed(h) -> void:
	h.check(_kinds(h.analyze_text("extends Node\n# @param\nfunc f(a):\n\tpass\n", "res://tests/tmp_par_x1.gd")).has("param_malformed"), "empty malformed")
	h.check(_kinds(h.analyze_text("extends Node\n# @param a\nfunc f(a):\n\tpass\n", "res://tests/tmp_par_x2.gd")).has("param_malformed"), "missing type malformed")
	h.check(_kinds(h.analyze_text("extends Node\n# @param a void\nfunc f(a):\n\tpass\n", "res://tests/tmp_par_x3.gd")).has("param_malformed"), "void malformed")
	h.check(_kinds(h.analyze_text("extends Node\n# @param 1a int\nfunc f(a):\n\tpass\n", "res://tests/tmp_par_x4.gd")).has("param_malformed"), "bad name malformed")
	h.check(_has_err(h.analyze_text("extends Node\n# @param a Nope\nfunc f(a):\n\tpass\n", "res://tests/tmp_par_x5.gd"), "param_unknown_type", "'Nope'"), "unknown type errors")


func _p_misplaced(h) -> void:
	h.check(_kinds(h.analyze_text("extends Node\n# @param x int\nvar x := 1\n", "res://tests/tmp_par_p1.gd")).has("param_misplaced"), "@param on var misplaced")
	h.check(_kinds(h.analyze_text("extends Node\n# @param s int\nsignal s\n", "res://tests/tmp_par_p2.gd")).has("param_misplaced"), "@param on signal misplaced")
	h.check(_kinds(h.analyze_text("# @param a int\nclass_name Foo\n", "res://tests/tmp_par_p3.gd")).has("param_misplaced"), "@param at root misplaced")
	h.check(_kinds(h.analyze_text("extends Node\nfunc f(a):\n\t# @param a int\n\n\tprint(a)\n", "res://tests/tmp_par_p4.gd")).has("param_misplaced"), "mid-body standalone misplaced")
	h.check(_kinds(h.analyze_text("extends Node\nfunc f(a):\n\t# @param a int\n\tprint(a)\n", "res://tests/tmp_par_p5.gd")).has("param_misplaced"), "mid-body attached misplaced")


func _p_marks(h) -> void:
	var res: Dictionary = h.analyze_text("extends Node\nfunc f(\n\t# @param a int\n\ta\n):\n\tpass\n", "res://tests/tmp_par_k1.gd")
	h.check(_clean(res), "direct use clean")
	var marked := false
	for c in ((res.get("ast", {}) as Dictionary).get("children", []) as Array):
		if (c as Dictionary).get("type", "") == "FUNC_DECL":
			for p in (c as Dictionary).get("params", []):
				if (p as Dictionary).has("param_ann"):
					marked = true
	h.check(marked, "param node stamped with param_ann")
