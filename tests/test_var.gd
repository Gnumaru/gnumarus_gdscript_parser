extends RefCounted

## @var rule suite: before-declaration narrowing with :=/= inference,
## free redefinition over visible variables, and placement/shape errors.

const H = preload("res://tests/helpers.gd")


func run() -> Dictionary:
	var h = H.new()
	h.suite = "var"
	_v_before_decl(h)
	_v_inference(h)
	_v_free(h)
	_v_targets(h)
	_v_malformed(h)
	_v_misplaced(h)
	_v_marks_and_bounds(h)
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


func _v_before_decl(h) -> void:
	h.check(_clean(h.analyze_text("extends Node\n# @var x Control\nvar x: Node\n", "res://tests/tmp_var_d1.gd")), "member narrow clean")
	h.check(_has_err(h.analyze_text("extends Node\n# @var x Object\nvar x: Node\n", "res://tests/tmp_var_d2.gd"), "var_mismatch", "'Object' is neither 'Node'"), "member widen mismatches")
	h.check(_has_err(h.analyze_text("extends Node\n# @var y int\nvar x := 1\n", "res://tests/tmp_var_d3.gd"), "var_unknown", "does not match declared variable 'x'"), "name mismatch errors")
	h.check(_clean(h.analyze_text("extends Node\n# @var v int|String\nvar v: Variant\n", "res://tests/tmp_var_d4.gd")), "union before-decl clean")
	h.check(_clean(h.analyze_text("extends Node\n# @var MAX int\nconst MAX = 10\n", "res://tests/tmp_var_d5.gd")), "const inferred clean")
	h.check(_has_err(h.analyze_text("extends Node\n# @var MAX String\nconst MAX = 10\n", "res://tests/tmp_var_d6.gd"), "var_mismatch", "declared as 'int'"), "const inferred mismatch errors")


func _v_inference(h) -> void:
	h.check(_clean(h.analyze_text("extends Node\n# @var y int\nvar y := 1\n", "res://tests/tmp_var_i1.gd")), ":= infers int")
	h.check(_has_err(h.analyze_text("extends Node\n# @var y String\nvar y := 1\n", "res://tests/tmp_var_i2.gd"), "var_mismatch", "declared as 'int'"), ":= mismatch errors")
	h.check(_clean(h.analyze_text("extends Node\n# @var x String\nvar x = 1\n", "res://tests/tmp_var_i3.gd")), "plain = is Variant")
	h.check(_clean(h.analyze_text("extends Node\n# @var c Color\nvar c := Color(1, 1, 1)\n", "res://tests/tmp_var_i4.gd")), "constructor infers")
	h.check(_clean(h.analyze_text("extends Node\n# @var a Array\nvar a := [1, 2]\n", "res://tests/tmp_var_i5.gd")), "array infers")


func _v_free(h) -> void:
	var ok := "extends Node\nfunc f():\n\tvar x: Node\n\t# @var x Control\n\n\tprint(x)\n"
	h.check(_clean(h.analyze_text(ok, "res://tests/tmp_var_f1.gd")), "free standalone narrow clean")
	var bad := "extends Node\nfunc f():\n\tvar x: Node\n\t# @var x Object\n\n\tprint(x)\n"
	h.check(_has_err(h.analyze_text(bad, "res://tests/tmp_var_f2.gd"), "var_mismatch", "declared as 'Node'"), "free widen mismatches")
	var attached := "extends Node\nfunc f():\n\tvar x: Node\n\t# @var x Control\n\tx = null\n"
	h.check(_clean(h.analyze_text(attached, "res://tests/tmp_var_f3.gd")), "free attached clean")
	var lam := "extends Node\nvar f = func():\n\tvar x: Node\n\t# @var x Control\n\n\tprint(x)\n"
	h.check(_clean(h.analyze_text(lam, "res://tests/tmp_var_f4.gd")), "free inside lambda clean")


func _v_targets(h) -> void:
	var p := "extends Node\nfunc f(a: Node):\n\t# @var a Control\n\n\tprint(a)\n"
	h.check(_clean(h.analyze_text(p, "res://tests/tmp_var_t1.gd")), "free on param clean")
	var pb := "extends Node\nfunc f(a: int):\n\t# @var a String\n\n\tprint(a)\n"
	h.check(_has_err(h.analyze_text(pb, "res://tests/tmp_var_t2.gd"), "var_mismatch", "declared as 'int'"), "free on param mismatch errors")
	var m := "extends Node\n# @var _c int\nvar _c := 1\nfunc f():\n\t# @var _c int\n\n\tprint(_c)\n"
	h.check(_clean(h.analyze_text(m, "res://tests/tmp_var_t3.gd")), "free on member clean")
	var gone := "extends Node\nfunc f():\n\tvar x := 1\n\t# @var nope int\n\n\tprint(x)\n"
	h.check(_has_err(h.analyze_text(gone, "res://tests/tmp_var_t4.gd"), "var_unknown", "no variable 'nope' in function 'f'"), "free on missing errors")
	var fn := "extends Node\nfunc g():\n\tpass\nfunc f():\n\t# @var g int\n\n\tprint(g)\n"
	h.check(_has_err(h.analyze_text(fn, "res://tests/tmp_var_t5.gd"), "var_unknown", "not a variable"), "free on function errors")
	var loop := "extends Node\nfunc f():\n\tfor i in [1, 2]:\n\t\t# @var i int\n\n\t\tprint(i)\n"
	h.check(_clean(h.analyze_text(loop, "res://tests/tmp_var_t6.gd")), "free on loop var accepted")


func _v_malformed(h) -> void:
	h.check(_kinds(h.analyze_text("extends Node\n# @var\nvar x := 1\n", "res://tests/tmp_var_m1.gd")).has("var_malformed"), "empty malformed")
	h.check(_kinds(h.analyze_text("extends Node\n# @var x\nvar x := 1\n", "res://tests/tmp_var_m2.gd")).has("var_malformed"), "missing type malformed")
	h.check(_kinds(h.analyze_text("extends Node\n# @var 123 int\nvar x := 1\n", "res://tests/tmp_var_m3.gd")).has("var_malformed"), "bad name malformed")
	h.check(_kinds(h.analyze_text("extends Node\n# @var x void\nvar x := 1\n", "res://tests/tmp_var_m4.gd")).has("var_malformed"), "void malformed")
	h.check(_kinds(h.analyze_text("extends Node\n# @var x int|\nvar x := 1\n", "res://tests/tmp_var_m5.gd")).has("var_malformed"), "empty arm malformed")
	h.check(_has_err(h.analyze_text("extends Node\n# @var x Nope\nvar x := 1\n", "res://tests/tmp_var_m6.gd"), "var_unknown_type", "'Nope'"), "unknown type errors")


func _v_misplaced(h) -> void:
	h.check(_kinds(h.analyze_text("extends Node\nfunc f(\n\t\t# @var a int\n\t\ta: int\n\t) -> void:\n\tpass\n", "res://tests/tmp_var_p1.gd")).has("var_misplaced"), "@var on param misplaced")
	h.check(_kinds(h.analyze_text("extends Node\n# @var f int\nfunc f():\n\tpass\n", "res://tests/tmp_var_p2.gd")).has("var_misplaced"), "@var on func misplaced")
	h.check(_kinds(h.analyze_text("extends Node\n# @var s int\nsignal s\n", "res://tests/tmp_var_p3.gd")).has("var_misplaced"), "@var on signal misplaced")
	h.check(_kinds(h.analyze_text("# @var x int\nclass_name Foo\n", "res://tests/tmp_var_p4.gd")).has("var_misplaced"), "@var at root misplaced")
	h.check(_kinds(h.analyze_text("# @var x int\n\nvar x := 1\n", "res://tests/tmp_var_p5.gd")).has("var_misplaced"), "standalone @var at top misplaced")
	h.check(_kinds(h.analyze_text("extends Node\nvar x: int:\n\tget:\n\t\t# @var y int\n\n\t\treturn 1\n", "res://tests/tmp_var_p6.gd")).has("var_misplaced"), "@var in accessor misplaced")


func _v_marks_and_bounds(h) -> void:
	var res: Dictionary = h.analyze_text("extends Node\n# @var y int\nvar y := 1\n", "res://tests/tmp_var_k1.gd")
	var marked := false
	for c in ((res.get("ast", {}) as Dictionary).get("children", []) as Array):
		if (c as Dictionary).get("type", "") == "VAR_DECL" and (c as Dictionary).has("var_ann"):
			marked = true
	h.check(marked, "var node stamped with var_ann")
	var nested := "extends Node\nfunc f():\n\tvar x: Node\n\tvar g = func():\n\t\tvar y: int\n\t\t# @var y String\n\n\t\tprint(y)\n"
	var res2: Dictionary = h.analyze_text(nested, "res://tests/tmp_var_k2.gd")
	h.check((res2.get("errors", []) as Array).size() == 1, "nested lambda violation reported once")
