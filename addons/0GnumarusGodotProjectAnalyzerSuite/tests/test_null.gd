extends RefCounted

## Nullability suite: `null` as a union arm (compat table), reserved
## `null` definition names, ==/!= narrowing, exact-null access errors
## and generic bound violations on null arguments.

const H = preload("res://addons/0GnumarusGodotProjectAnalyzerSuite/tests/helpers.gd")


func run() -> Dictionary:
	var h = H.new()
	h.suite = "null"
	_n_grammar(h)
	_n_reserved(h)
	_n_guards(h)
	_n_exact(h)
	_n_generic(h)
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


func _null_kinds(res: Dictionary) -> Array:
	var out: Array = []
	for e in res.get("errors", []):
		if str((e as Dictionary).get("kind", "")) == "null_access":
			out.append(e)
	return out


func _n_grammar(h) -> void:
	h.check(_clean(h.analyze_text("extends RefCounted\n# @var x Node|null\nvar x: Variant\n", "res://tests/tmp_null_g01.gd")), "union arm on Variant clean")
	h.check(_clean(h.analyze_text("extends RefCounted\n# @var x null|Node\nvar x: Variant\n", "res://tests/tmp_null_g02.gd")), "reversed arm order clean")
	h.check(_clean(h.analyze_text("extends RefCounted\n# @var x null\nvar x: Variant\n", "res://tests/tmp_null_g03.gd")), "bare null arm clean")
	h.check(_has_err(h.analyze_text("extends RefCounted\n# @var x int|null\nvar x := 1\n", "res://tests/tmp_null_g04.gd"), "var_mismatch", "'null'"), "null arm against inferred int mismatches")
	h.check(_has_err(h.analyze_text("extends RefCounted\n# @var x Array|null\nvar x: Array\n", "res://tests/tmp_null_g05.gd"), "var_mismatch", "'null'"), "null arm against Array mismatches")
	h.check(_clean(h.analyze_text("extends RefCounted\n# @param p Node|null\nfunc f(p: Node):\n\tpass\n", "res://tests/tmp_null_g06.gd")), "param null arm on Node clean")
	h.check(_has_err(h.analyze_text("extends RefCounted\n# @param p null\nfunc f(p: int):\n\tpass\n", "res://tests/tmp_null_g07.gd"), "param_mismatch", "'null'"), "param null arm on int mismatches")
	h.check(_clean(h.analyze_text("extends RefCounted\n# @return Node|null\nfunc f():\n\tpass\n", "res://tests/tmp_null_g08.gd")), "return null arm clean")
	h.check(_clean(h.analyze_text("extends RefCounted\n# @return null\nfunc f():\n\treturn null\n", "res://tests/tmp_null_g09.gd")), "return null clean")
	h.check(_has_err(h.analyze_text("extends RefCounted\n# @return null\nfunc f() -> int:\n\treturn 1\n", "res://tests/tmp_null_g10.gd"), "return_mismatch", "'null'"), "return null against int arrow mismatches")
	h.check(_clean(h.analyze_text("extends RefCounted\n# @alias MaybeNode Node|null @endalias\n# @var x MaybeNode\nvar x: Variant\n", "res://tests/tmp_null_g11.gd")), "alias with null arm clean")
	h.check(_has_err(h.analyze_text("extends RefCounted\n# @alias MaybeNode Node|null @endalias\n# @var x MaybeNode\nvar x := 1\n", "res://tests/tmp_null_g12.gd"), "var_mismatch", "'null'"), "alias null arm against int mismatches")


func _n_reserved(h) -> void:
	h.check(_kinds(h.analyze_text("extends RefCounted\n# @tuple null 1 int\n", "res://tests/tmp_null_r1.gd")).has("tuple_conflict"), "tuple named null conflicts")
	h.check(_kinds(h.analyze_text("extends RefCounted\n# @struct null 1 x:int\n", "res://tests/tmp_null_r2.gd")).has("struct_conflict"), "struct named null conflicts")
	h.check(_kinds(h.analyze_text("extends RefCounted\n# @alias null int @endalias\n", "res://tests/tmp_null_r3.gd")).has("alias_conflict"), "alias named null conflicts")
	h.check(_kinds(h.analyze_text("extends RefCounted\n# @interface null\n# func:f:void\n# @endinterface\n", "res://tests/tmp_null_r4.gd")).has("interface_conflict"), "interface named null conflicts")
	h.check(_kinds(h.analyze_text("extends RefCounted\n# @template null\n", "res://tests/tmp_null_r5.gd")).has("template_conflict"), "template named null conflicts")


func _n_guards(h) -> void:
	var eq := "extends RefCounted\nfunc f(n: Node) -> void:\n\tif n == null:\n\t\tn.queue_free()\n\tn.queue_free()\n"
	var eq_res: Dictionary = h.analyze_text(eq, "res://tests/tmp_null_eq.gd")
	h.check(_null_kinds(eq_res).size() == 1, "eq branch errors once")
	h.check(_has_err(eq_res, "null_access", "on null"), "eq branch is null_access")
	var ne := "extends RefCounted\nfunc f(n: Node) -> void:\n\tif n != null:\n\t\tn.queue_free()\n\telse:\n\t\tn.queue_free()\n"
	var ne_res: Dictionary = h.analyze_text(ne, "res://tests/tmp_null_ne.gd")
	h.check(_null_kinds(ne_res).size() == 1, "ne else errors once")
	var rev := "extends RefCounted\nfunc f(n: Node) -> void:\n\tif null == n:\n\t\tn.queue_free()\n"
	h.check(_has_err(h.analyze_text(rev, "res://tests/tmp_null_rev.gd"), "null_access", "on null"), "reversed order narrows")
	var flip := "extends RefCounted\nfunc f(n: Node) -> void:\n\tif not n == null:\n\t\tn.queue_free()\n"
	h.check(_null_kinds(h.analyze_text(flip, "res://tests/tmp_null_flip.gd")).is_empty(), "negated guard stays lenient")
	var noname := "extends RefCounted\nfunc f(a: Node) -> void:\n\tif a.b == null:\n\t\tpass\n"
	h.check(_null_kinds(h.analyze_text(noname, "res://tests/tmp_null_noname.gd")).is_empty(), "non-identifier guard silent")
	var isnull := "extends RefCounted\nfunc f(v: Variant) -> void:\n\tif typeof(v) == TYPE_NIL:\n\t\tv.queue_free()\n"
	h.check(_has_err(h.analyze_text(isnull, "res://tests/tmp_null_typeof.gd"), "null_access", "on null"), "typeof nil narrows to exact null")


func _n_exact(h) -> void:
	var src := "extends RefCounted\n# @var x null\nvar x: Variant\nfunc f() -> void:\n\tx.queue_free()\n"
	h.check(_has_err(h.analyze_text(src, "res://tests/tmp_null_x1.gd"), "null_access", "on null"), "call on exact null errors")
	var read := "extends RefCounted\n# @var x null\nvar x: Variant\nfunc f() -> void:\n\tprint(x.size)\n"
	h.check(_has_err(h.analyze_text(read, "res://tests/tmp_null_x2.gd"), "null_access", "cannot read member"), "read on exact null errors")
	var bare := "extends RefCounted\n# @var x null\nvar x: Variant\nfunc f() -> void:\n\tprint(x)\n"
	h.check(_null_kinds(h.analyze_text(bare, "res://tests/tmp_null_x3.gd")).is_empty(), "bare use of exact null silent")
	var lenient := "extends RefCounted\nfunc f() -> void:\n\tvar x: Node = null\n\tx.queue_free()\n"
	h.check(_null_kinds(h.analyze_text(lenient, "res://tests/tmp_null_x4.gd")).is_empty(), "plain nullable Node stays lenient")
	var dyn := "extends RefCounted\nfunc f(v: Variant) -> void:\n\tv.queue_free()\n"
	h.check(_null_kinds(h.analyze_text(dyn, "res://tests/tmp_null_x5.gd")).is_empty(), "unguarded Variant has no null_access")


func _n_generic(h) -> void:
	var src := "extends RefCounted\n# @template TNull of int|float\n# @param x TNull\nfunc gid(x):\n\treturn x\nfunc f() -> void:\n\tgid(1)\n\tgid(null)\n"
	var res: Dictionary = h.analyze_text(src, "res://tests/tmp_null_c1.gd")
	var lines: Array = []
	for e in res.get("errors", []):
		if str((e as Dictionary).get("kind", "")) == "template_mismatch":
			lines.append(int((e as Dictionary).get("line", 0)))
	h.check(lines == [8], "generic null arg violates bound once")
	h.check(_has_err(res, "template_mismatch", "null"), "generic null message names null")
