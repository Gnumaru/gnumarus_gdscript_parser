# @integrity_ignore_file (test harness uses virtual paths)
extends RefCounted

## @generic suite: class declarations (placement, shapes), generic
## vartypes (arity, bounds, leniency) and substitution in member
## lookup (fields and methods with pre-bound class arguments).

const H = preload("res://addons/0GnumarusGodotProjectAnalyzerSuite/tests/helpers.gd")


func run() -> Dictionary:
	var h = H.new()
	h.suite = "generic"
	_g_decl(h)
	_g_vartype(h)
	_g_subst(h)
	_g_extends(h)
	_g_new(h)
	_g_json(h)
	return h.result()


func _has_err(res: Dictionary, kind: String, part: String) -> bool:
	for e in res.get("errors", []):
		if str((e as Dictionary).get("kind", "")) == kind and part in str((e as Dictionary).get("message", "")):
			return true
	return false


func _clean(res: Dictionary) -> bool:
	return (res.get("errors", []) as Array).is_empty()


func _kinds(res: Dictionary) -> Array:
	var out: Array = []
	for e in res.get("errors", []):
		out.append(str((e as Dictionary).get("kind", "")))
	return out


func _g_decl(h) -> void:
	h.check(_clean(h.analyze_text("extends Node\n# @template GxT\n# @generic GxT\nclass GxBox:\n\tpass\n", "res://tests/tmp_ggx_d01.gd")), "declaration clean")
	h.check(_clean(h.analyze_text("extends Node\n# @template GxT1\n# @template GxT2\n# @generic GxT1 GxT2\nclass GxPair:\n\tpass\n", "res://tests/tmp_ggx_d02.gd")), "two params clean")
	h.check(_kinds(h.analyze_text("extends Node\n# @generic GxT\nfunc f():\n\tpass\n", "res://tests/tmp_ggx_d03.gd")).has("generic_misplaced"), "before func misplaced")
	h.check(_kinds(h.analyze_text("extends Node\nfunc f():\n\t# @generic GxT\n\tpass\n", "res://tests/tmp_ggx_d04.gd")).has("generic_misplaced"), "inside func misplaced")
	h.check(_has_err(h.analyze_text("extends Node\n# @template GxT5\n# @generic\nclass GxBox5:\n\tpass\n", "res://tests/tmp_ggx_d05.gd"), "generic_malformed", "at least one"), "empty malformed")
	h.check(_has_err(h.analyze_text("extends Node\n# @template GxT6\n# @generic GxT6 GxT6\nclass GxBox6:\n\tpass\n", "res://tests/tmp_ggx_d06.gd"), "generic_malformed", "more than once"), "duplicate malformed")
	h.check(_has_err(h.analyze_text("extends Node\n# @generic int\nclass GxBox7:\n\tpass\n", "res://tests/tmp_ggx_d07.gd"), "generic_malformed", "must be a template type"), "concrete name malformed")
	h.check(_has_err(h.analyze_text("extends Node\n# @generic NopeGx\nclass GxBox8:\n\tpass\n", "res://tests/tmp_ggx_d08.gd"), "generic_malformed", "must be a template type"), "unknown name malformed")


func _g_vartype(h) -> void:
	h.check(_clean(h.analyze_text("extends Node\n# @template GxT10\n# @generic GxT10\nclass GxBox10:\n\tpass\nvar b: GxBox10[int]\n", "res://tests/tmp_ggx_v01.gd")), "applied vartype clean")
	h.check(_has_err(h.analyze_text("extends Node\n# @template GxT11\n# @generic GxT11\nclass GxBox11:\n\tpass\nvar b: GxBox11[int, String]\n", "res://tests/tmp_ggx_v02.gd"), "generic_mismatch", "takes 1 type argument(s), got 2"), "arity mismatch errors")
	h.check(_clean(h.analyze_text("extends Node\n# @template GxT12\n# @generic GxT12\nclass GxBox12:\n\tpass\nvar b: GxBox12\n", "res://tests/tmp_ggx_v03.gd")), "bare use lenient")
	h.check(_clean(h.analyze_text("extends Node\nvar a: Array[int]\n", "res://tests/tmp_ggx_v04.gd")), "engine generic skipped")
	h.check(_clean(h.analyze_text("extends Node\nvar n: NopeGx[int]\n", "res://tests/tmp_ggx_v05.gd")), "unknown head skipped")
	h.check(_has_err(h.analyze_text("extends Node\n# @template GxT16 of int\n# @generic GxT16\nclass GxBox16:\n\tpass\nvar b: GxBox16[String]\n", "res://tests/tmp_ggx_v06.gd"), "generic_mismatch", "violates bound"), "bound violation errors")
	h.check(_clean(h.analyze_text("extends Node\n# @template GxT17 of int\n# @generic GxT17\nclass GxBox17:\n\tpass\nvar b: GxBox17[int]\n", "res://tests/tmp_ggx_v07.gd")), "bound satisfied clean")


func _g_subst(h) -> void:
	h.check(_clean(h.analyze_text("extends Node\n# @template GxT20\n# @generic GxT20\nclass GxBox20:\n\t# @param x GxT20\n\tfunc setv(x):\n\t\tpass\nfunc f():\n\tvar b: GxBox20[int]\n\tb.setv(1)\n", "res://tests/tmp_ggx_s01.gd")), "method call clean")
	h.check(_has_err(h.analyze_text("extends Node\n# @template GxT21\n# @generic GxT21\nclass GxBox21:\n\t# @param x GxT21\n\tfunc setv(x):\n\t\tpass\nfunc f():\n\tvar b: GxBox21[int]\n\tb.setv(\"a\")\n", "res://tests/tmp_ggx_s02.gd"), "template_mismatch", "expects 'int', got 'String'"), "method call mismatch errors")
	h.check(_has_err(h.analyze_text("extends Node\n# @template GxT22\n# @generic GxT22\nclass GxBox22:\n\t# @var v GxT22\n\tvar v\nfunc f():\n\tvar b: GxBox22[int]\n\tb.v.push_back(\"a\")\n", "res://tests/tmp_ggx_s03.gd"), "missing_method", "has no method 'push_back()'"), "field substitution chains")
	h.check(_clean(h.analyze_text("extends Node\n# @template GxT23\n# @generic GxT23\nclass GxBox23:\n\t# @var v GxT23\n\tvar v\nfunc f():\n\tvar b: GxBox23\n\tb.v.push_back(\"a\")\n", "res://tests/tmp_ggx_s04.gd")), "bare instance opaque")


func _g_json(h) -> void:
	h.analyze_text("extends Node\n# @template GxT30\n# @generic GxT30\nclass GxBox30:\n\tpass\n", "res://tests/tmp_ggx_j01.gd")
	var info: Dictionary = h.load_json("res://.godot/0GnumarusGodotProjectAnalyzerSuiteData/user/tests_tmp_ggx_j01.GxBox30.json")
	h.check(str(info.get("kind", "")) == "script", "json kind script")
	h.check((info.get("generic", []) as Array) == ["GxT30"], "json generic kept")


func _g_extends(h) -> void:
	h.check(_clean(h.analyze_text("extends Node\n# @template GxT40\n# @generic GxT40\nclass GxBox40:\n\t# @var v GxT40\n\tvar v\nclass GxKid40 extends GxBox40[int]:\n\tpass\n", "res://tests/tmp_ggx_e01.gd")), "parameterized extends clean")
	h.check(_has_err(h.analyze_text("extends Node\n# @template GxT41\n# @generic GxT41\nclass GxBox41:\n\tpass\nclass GxKid41 extends GxBox41[int, String]:\n\tpass\n", "res://tests/tmp_ggx_e02.gd"), "generic_mismatch", "takes 1 type argument(s), got 2"), "extends arity errors")
	h.check(_has_err(h.analyze_text("extends Node\n# @template GxT42 of int\n# @generic GxT42\nclass GxBox42:\n\tpass\nclass GxKid42 extends GxBox42[String]:\n\tpass\n", "res://tests/tmp_ggx_e03.gd"), "generic_mismatch", "violates bound"), "extends bound errors")
	h.check(_clean(h.analyze_text("extends Node\nclass GxKid44 extends Node:\n\tpass\n", "res://tests/tmp_ggx_e04.gd")), "plain extends untouched")
	h.check(_has_err(h.analyze_text("extends Node\n# @template GxT45\n# @generic GxT45\nclass GxBox45:\n\t# @var v GxT45\n\tvar v\nclass GxKid45 extends GxBox45[int]:\n\tpass\nfunc f():\n\tvar k := GxKid45.new()\n\tk.v.push_back(1)\n", "res://tests/tmp_ggx_e05.gd"), "missing_method", "has no method 'push_back()'"), "inherited field substitutes")
	h.check(_has_err(h.analyze_text("extends Node\n# @template GxT46\n# @generic GxT46\nclass GxBox46:\n\t# @param x GxT46\n\tfunc setv(x):\n\t\tpass\nclass GxKid46 extends GxBox46[int]:\n\tpass\nfunc f():\n\tvar k := GxKid46.new()\n\tk.setv(1)\n\tk.setv(\"a\")\n", "res://tests/tmp_ggx_e06.gd"), "template_mismatch", "expects 'int', got 'String'"), "inherited method binds class arg")


func _g_new(h) -> void:
	h.check(_clean(h.analyze_text("extends Node\n# @template GxT50\n# @param x Array[GxT50]\n# @return GxT50\nfunc gxfirst(x):\n\treturn x[0]\nfunc f():\n\tgxfirst(Array[int]([1, 2]))\n", "res://tests/tmp_ggx_n01.gd")), "typed constructor binds")
	h.check(_clean(h.analyze_text("extends Node\n# @template GxT51\n# @generic GxT51\nclass GxBox51:\n\tpass\nfunc f():\n\tvar b := GxBox51.new()\n", "res://tests/tmp_ggx_n02.gd")), "bare new opaque")
