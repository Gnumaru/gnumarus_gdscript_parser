# @integrity_ignore_file (test harness uses virtual paths)
extends RefCounted

## Generic call suite: instantiation of \@template functions at call
## sites (bare and self calls) — unification, arity, bounds and
## substituted returns flowing into chains.

const H = preload("res://addons/0GnumarusGodotProjectAnalyzerSuite/tests/helpers.gd")


func run() -> Dictionary:
	var h = H.new()
	h.suite = "generic_call"
	_g_identity(h)
	_g_arity(h)
	_g_mismatch(h)
	_g_bounds(h)
	_g_returns(h)
	_g_explicit(h)
	_g_boundaries(h)
	_g_flow(h)
	return h.result()


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


func _clean(res: Dictionary) -> bool:
	return (res.get("errors", []) as Array).is_empty()


func _g_identity(h) -> void:
	h.check(_clean(h.analyze_text("extends Node\n# @template GcT\n# @param x GcT\n# @return GcT\nfunc gcid(x):\n\treturn x\nfunc f():\n\tgcid(1)\n\tgcid(\"a\")\n", "res://tests/tmp_gcl_i01.gd")), "bare identity binds per call")
	h.check(_clean(h.analyze_text("extends Node\n# @template GcT2\n# @param x GcT2\n# @return GcT2\nfunc gcid2(x):\n\treturn x\nfunc f():\n\tself.gcid2(1)\n\tself.gcid2(\"a\")\n", "res://tests/tmp_gcl_i02.gd")), "self identity binds per call")
	h.check(_clean(h.analyze_text("extends Node\n# @template GcT3\n# @param x GcT3\n# @return GcT3\nfunc gcid3(x):\n\treturn x\nfunc f():\n\tvar y := 1\n\tgcid3(y)\n", "res://tests/tmp_gcl_i03.gd")), "inferred local binds")


func _g_arity(h) -> void:
	h.check(_has_err(h.analyze_text("extends Node\n# @template GcT4\n# @param a GcT4\n# @param b GcT4\nfunc gcf2(a, b):\n\tpass\nfunc f():\n\tself.gcf2(1)\n", "res://tests/tmp_gcl_a01.gd"), "template_mismatch", "expects 2 argument(s), got 1"), "missing arg errors")
	h.check(_has_err(h.analyze_text("extends Node\n# @template GcT5\n# @param a GcT5\nfunc gcf1(a):\n\tpass\nfunc f():\n\tself.gcf1(1, 2)\n", "res://tests/tmp_gcl_a02.gd"), "template_mismatch", "expects 1 argument(s), got 2"), "extra arg errors")
	h.check(_clean(h.analyze_text("extends Node\n# @template GcT6\n# @param a GcT6\n# @param b GcT6\nfunc gcdef(a, b = 1):\n\tpass\nfunc f():\n\tgcdef(1)\n\tgcdef(1, 2)\n", "res://tests/tmp_gcl_a03.gd")), "defaults satisfy arity")


func _g_mismatch(h) -> void:
	h.check(_has_err(h.analyze_text("extends Node\n# @template GcT7\n# @param a GcT7\n# @param b GcT7\nfunc gcpair(a, b):\n\tpass\nfunc f():\n\tself.gcpair(1, \"a\")\n", "res://tests/tmp_gcl_m01.gd"), "template_mismatch", "conflicting types for 'GcT7'"), "inconsistent binding errors")
	h.check(_has_err(h.analyze_text("extends Node\n# @template GcT8\n# @param x Array[GcT8]\nfunc gctake(x):\n\tpass\nfunc f():\n\tself.gctake(1)\n", "res://tests/tmp_gcl_m02.gd"), "template_mismatch", "expects 'Array[GcT8]', got 'int'"), "nested formal mismatch errors")
	h.check(_clean(h.analyze_text("extends Node\n# @template GcT9\n# @param x Array[GcT9]\n# @return GcT9\nfunc gcfirst(x):\n\treturn x[0]\nfunc f():\n\tgcfirst([1, 2])\n", "res://tests/tmp_gcl_m03.gd")), "array literal binds element")


func _g_bounds(h) -> void:
	h.check(_clean(h.analyze_text("extends Node\n# @template GcT10 of int\n# @param x GcT10\n# @return GcT10\nfunc gcbnd(x):\n\treturn x\nfunc f():\n\tgcbnd(1)\n", "res://tests/tmp_gcl_b01.gd")), "bound satisfied clean")
	h.check(_has_err(h.analyze_text("extends Node\n# @template GcT11 of int\n# @param x GcT11\n# @return GcT11\nfunc gcbnd2(x):\n\treturn x\nfunc f():\n\tgcbnd2(\"a\")\n", "res://tests/tmp_gcl_b02.gd"), "template_mismatch", "violates bound 'int'"), "bound violation errors")


func _g_returns(h) -> void:
	h.check(_has_err(h.analyze_text("extends Node\n# @template GcT12 of int\n# @param x GcT12\n# @return GcT12\nfunc gcbnd3(x):\n\treturn x\nfunc f():\n\tself.gcbnd3(1).bogus()\n", "res://tests/tmp_gcl_r01.gd"), "missing_method", "has no method 'bogus()'"), "substituted return chains")
	h.check(_clean(h.analyze_text("extends Node\nfunc gcdyn(x):\n\treturn x\nfunc f():\n\tself.gcdyn(1).bogus()\n", "res://tests/tmp_gcl_r02.gd")), "dynamic return stays silent")


func _g_explicit(h) -> void:
	var decl := "extends Node\n# @template GeT1\n# @template GeT2\n# @generic_func GeT1 GeT2\n# @param a GeT2\n# @return GeT1\nfunc gemyfunc(a: Variant) -> Variant:\n\treturn a\n"
	h.check(_has_err(h.analyze_text(decl + "func other():\n\t# @generic_call gemyfunc[int, Object]\n\tvar a: String = gemyfunc(1)\n", "res://tests/tmp_gcl_e01.gd"), "assign_mismatch", "cannot assign 'int'"), "explicit slot mismatch errors")
	h.check(_has_err(h.analyze_text(decl + "func other():\n\t# @generic_call gemyfunc[int, Object]\n\tvar a: String = gemyfunc(1)\n", "res://tests/tmp_gcl_e01.gd"), "template_mismatch", "expects 'Object', got 'int'"), "explicit actual mismatch errors")
	h.check(_clean(h.analyze_text(decl + "func other():\n\t# @generic_call gemyfunc[int, int]\n\tvar a: int = gemyfunc(1)\n", "res://tests/tmp_gcl_e02.gd")), "conforming explicit clean")
	h.check(_has_err(h.analyze_text(decl + "func other():\n\t# @generic_call gemyfunc[int]\n\tvar a: int = gemyfunc(1)\n", "res://tests/tmp_gcl_e03.gd"), "generic_call_mismatch", "takes 2 type argument(s), got 1"), "explicit arity errors")
	h.check(_has_err(h.analyze_text(decl + "func other():\n\t# @generic_call gemyfunc[Nope, int]\n\tvar a: int = gemyfunc(1)\n", "res://tests/tmp_gcl_e04.gd"), "generic_call_mismatch", "unknown type 'Nope'"), "explicit unknown errors")
	h.check(_has_err(h.analyze_text(decl + "func other():\n\t# @generic_call gemyfunc[void, int]\n\tvar a: int = gemyfunc(1)\n", "res://tests/tmp_gcl_e05.gd"), "generic_call_malformed", "not a valid type argument"), "explicit void malformed")
	h.check(_has_err(h.analyze_text("extends Node\n# @template GeT6 of int\n# @generic_func GeT6\n# @return GeT6\nfunc geint() -> Variant:\n\treturn 1\nfunc other():\n\t# @generic_call geint[String]\n\tvar a: int = geint()\n", "res://tests/tmp_gcl_e06.gd"), "template_mismatch", "violates bound 'int'"), "explicit bound errors")
	h.check(_has_err(h.analyze_text(decl + "func other():\n\t# @generic_call gemyfunc[int, int]\n\tpass\n", "res://tests/tmp_gcl_e07.gd"), "generic_call_misplaced", "must precede a statement"), "dangling errors")
	h.check(_has_err(h.analyze_text(decl + "func other():\n\t# @generic_call gemyfunc[int, int]\n\tx = gemyfunc(1) + gemyfunc(2)\n", "res://tests/tmp_gcl_e08.gd"), "generic_call_misplaced", "more than one"), "multi match errors")
	h.check(_has_err(h.analyze_text(decl + "func other():\n\tpass\n\t# @generic_call gemyfunc[int, int]\n", "res://tests/tmp_gcl_e09.gd"), "generic_call_misplaced", "must precede"), "orphan errors")
	h.check(_has_err(h.analyze_text("extends Node\nfunc genplain() -> int:\n\treturn 1\nfunc other():\n\t# @generic_call genplain[int]\n\tvar a: String = genplain()\n", "res://tests/tmp_gcl_e10.gd"), "generic_call_mismatch", "has no @generic_func"), "plain func claim errors")
	h.check(_has_err(h.analyze_text(decl + "func other():\n\tvar v: Variant\n\t# @generic_call v.gemyfunc[int, int]\n\tvar a: int = v.gemyfunc(1)\n", "res://tests/tmp_gcl_e11.gd"), "generic_call_mismatch", "Variant-typed receiver"), "variant receiver errors")
	h.check(_clean(h.analyze_text(decl + "func other():\n\tvar v\n\t# @generic_call v.gemyfunc[int, int]\n\tvar a: int = v.gemyfunc(1)\n", "res://tests/tmp_gcl_e12.gd")), "untyped receiver silent")
	var meth := "extends Node\n# @template GeT13\n# @template GeT14\nclass GeBox:\n\t# @generic_func GeT13 GeT14\n\t# @param a GeT14\n\t# @return GeT13\n\tfunc geconv(a: Variant) -> Variant:\n\t\treturn a\n"
	h.check(_has_err(h.analyze_text(meth + "func other():\n\tvar b: GeBox = GeBox.new()\n\t# @generic_call b.geconv[int, Object]\n\tvar s: String = b.geconv(1)\n", "res://tests/tmp_gcl_e13.gd"), "assign_mismatch", "cannot assign 'int'"), "explicit method slot errors")
	h.check(_has_err(h.analyze_text(meth + "func other():\n\tvar b: GeBox = GeBox.new()\n\t# @generic_call b.geconv[int, Object]\n\tvar s: String = b.geconv(1)\n", "res://tests/tmp_gcl_e13.gd"), "template_mismatch", "expects 'Object', got 'int'"), "explicit method actual errors")
	h.check(_clean(h.analyze_text(meth + "func other():\n\tvar b: GeBox = GeBox.new()\n\t# @generic_call b.geconv[int, int]\n\tvar s: int = b.geconv(1)\n", "res://tests/tmp_gcl_e14.gd")), "explicit method conforming clean")
	h.check(_has_err(h.analyze_text("extends Node\n# @template GeT15\n# @generic_func GeT15\n# @return GeT15\nfunc geone() -> Variant:\n\treturn 1\nfunc other():\n\t# @generic_call self.geone[int]\n\tvar s: String = self.geone()\n", "res://tests/tmp_gcl_e15.gd"), "assign_mismatch", "cannot assign 'int'"), "explicit self slot errors")
	h.check(_has_err(h.analyze_text("extends Node\n# @template GeT16\nclass GeBox16:\n\t# @generic_func GeT16\n\t# @return GeT16\n\tstatic func gemake() -> Variant:\n\t\treturn 1\nfunc other():\n\t# @generic_call GeBox16.gemake[int]\n\tvar s: String = GeBox16.gemake()\n", "res://tests/tmp_gcl_e16.gd"), "assign_mismatch", "cannot assign 'int'"), "explicit static slot errors")
	h.check(_has_err(h.analyze_text(decl + "func other():\n\tvar s: String\n\t# @generic_call gemyfunc[int, int]\n\ts = gemyfunc(1)\n", "res://tests/tmp_gcl_e17.gd"), "assign_mismatch", "cannot assign 'int'"), "explicit reassign errors")
	var bareurteil: Dictionary = h.analyze_text(decl + "func other():\n\t# @generic_call gemyfunc[int, Object]\n\tgemyfunc(1)\n", "res://tests/tmp_gcl_e18.gd")
	h.check(_has_err(bareurteil, "template_mismatch", "expects 'Object', got 'int'"), "bare statement args checked")
	h.check(not _kinds(bareurteil).has("assign_mismatch"), "bare statement has no slot")
	h.check(_clean(h.analyze_text(decl + "func other():\n\t# @generic_call gemyfunc[int, int]\n\tif gemyfunc(1):\n\t\tpass\n", "res://tests/tmp_gcl_e19.gd")), "if condition conforming clean")


func _g_boundaries(h) -> void:
	h.check(_clean(h.analyze_text("extends Node\nfunc gcplain(a: int):\n\tpass\nfunc f():\n\tself.gcplain(\"a\")\n", "res://tests/tmp_gcl_x01.gd")), "plain calls unchecked")
	h.check(_clean(h.analyze_text("extends Node\n# @template GcT13\n# @param x GcT13\nfunc gcdyn2(x):\n\tpass\nfunc f():\n\tvar u\n\tgcdyn2(u)\n", "res://tests/tmp_gcl_x02.gd")), "dynamic actual lenient")
	h.check(_clean(h.analyze_text("extends Node\n# @template GcT14\nclass GcInner:\n\t# @param x GcT14\n\tfunc gcown(x):\n\t\tpass\nfunc f():\n\tvar o := GcInner.new()\n\to.gcown(1)\n", "res://tests/tmp_gcl_x03.gd")), "method on instance checks")


func _g_flow(h) -> void:
	h.check(_has_err(h.analyze_text("extends Node\n# @template GcT20\n# @param x GcT20\n# @return GcT20\nfunc gcid(x):\n\treturn x\nfunc f():\n\tvar y := gcid(1)\n\ty.bogus()\n", "res://tests/tmp_gcl_f01.gd"), "missing_method", "has no method 'bogus()'"), "call result flows to use")
	h.check(_clean(h.analyze_text("extends Node\n# @template GcT21\n# @param x GcT21\n# @return GcT21\nfunc gcid2(x):\n\treturn x\nfunc f():\n\tvar y := gcid2(1)\n\tprint(y)\n", "res://tests/tmp_gcl_f02.gd")), "flow clean stays clean")
	h.check(_has_err(h.analyze_text("extends Node\n# @template GcT22\n# @param x GcT22\n# @return GcT22\nfunc gcid3(x):\n\treturn x\nfunc f():\n\tvar y\n\ty = gcid3(\"a\")\n\ty.bogus()\n", "res://tests/tmp_gcl_f03.gd"), "missing_method", "has no method 'bogus()'"), "reassignment flows")
	h.check(_has_err(h.analyze_text("extends Node\n# @template GcT23\n# @param x GcT23\n# @return GcT23\nfunc gcid4(x):\n\treturn x\nfunc f():\n\tvar y: Array = gcid4(1)\n\ty.bogus()\n", "res://tests/tmp_gcl_f04.gd"), "missing_method", "type 'Array' has no method"), "declaration wins over call")
	h.check(_clean(h.analyze_text("extends Node\n# @template GcT24\n# @param x GcT24\n# @return GcT24\nfunc gcid5(x):\n\treturn x\nfunc takes_int(a: int):\n\tpass\nfunc f():\n\tvar y := gcid5(1)\n\tself.takes_int(y)\n", "res://tests/tmp_gcl_f05.gd")), "flowed value feeds calls")
