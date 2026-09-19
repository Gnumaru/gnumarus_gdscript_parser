extends RefCounted

## notnull suite: trailing `notnull` on @var/@param/@return (parse,
## stamps, contradiction), `= null`/`=null` violations via declaration
## and flow state, guard-set flags and plain redefinition clearing.

const H = preload("res://addons/0GnumarusGodotProjectAnalyzerSuite/tests/helpers.gd")


func run() -> Dictionary:
	var h = H.new()
	h.suite = "notnull"
	_n_parse(h)
	_n_clash(h)
	_n_assign(h)
	_n_guard(h)
	_n_param(h)
	_n_return(h)
	_n_callsite(h)
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


func _n_parse(h) -> void:
	h.check(_clean(h.analyze_text("extends RefCounted\n# @var x Node notnull\nvar x: Node\n", "res://tests/tmp_nn_p01.gd")), "var flag clean")
	h.check(_clean(h.analyze_text("extends RefCounted\n# @param p Node notnull\nfunc f(p: Node):\n\tpass\n", "res://tests/tmp_nn_p02.gd")), "param flag clean")
	h.check(_clean(h.analyze_text("extends RefCounted\n# @return Node notnull\nfunc f() -> Node:\n\tpass\n", "res://tests/tmp_nn_p03.gd")), "return flag clean")
	h.check(_kinds(h.analyze_text("extends RefCounted\n# @var x Node|notnull\nvar x: Variant\n", "res://tests/tmp_nn_p04.gd")).has("var_unknown_type"), "pipe spelling stays unknown")
	h.check(_kinds(h.analyze_text("extends RefCounted\n# @return void notnull\nfunc f() -> void:\n\tpass\n", "res://tests/tmp_nn_p05.gd")).has("return_malformed"), "void notnull malformed")
	h.check(_kinds(h.analyze_text("extends RefCounted\n# @var x notnull\nvar x: Variant\n", "res://tests/tmp_nn_p06.gd")).has("var_malformed"), "bare notnull needs a type")


func _n_clash(h) -> void:
	h.check(_has_err(h.analyze_text("extends RefCounted\n# @var x Node|null notnull\nvar x: Variant\n", "res://tests/tmp_nn_c1.gd"), "var_malformed", "contradicts"), "var clash errors")
	h.check(_has_err(h.analyze_text("extends RefCounted\n# @var x null notnull\nvar x: Variant\n", "res://tests/tmp_nn_c2.gd"), "var_malformed", "contradicts"), "bare null clash errors")
	h.check(_has_err(h.analyze_text("extends RefCounted\n# @param p Node|null notnull\nfunc f(p: Variant):\n\tpass\n", "res://tests/tmp_nn_c3.gd"), "param_malformed", "contradicts"), "param clash errors")
	h.check(_has_err(h.analyze_text("extends RefCounted\n# @return Node|null notnull\nfunc f():\n\tpass\n", "res://tests/tmp_nn_c4.gd"), "return_malformed", "contradicts"), "return clash errors")
	h.check(_has_err(h.analyze_text("extends RefCounted\n# @alias MaybeN Node|null @endalias\n# @var x MaybeN notnull\nvar x: Variant\n", "res://tests/tmp_nn_c5.gd"), "var_malformed", "contradicts"), "alias clash errors")


func _n_assign(h) -> void:
	h.check(_has_err(h.analyze_text("extends RefCounted\n# @var x Node notnull\nvar x: Node = null\n", "res://tests/tmp_nn_a1.gd"), "var_notnull", "'x'"), "decl init null errors")
	h.check(_clean(h.analyze_text("extends RefCounted\n# @var x Node notnull\nvar x: Node\n", "res://tests/tmp_nn_a2.gd")), "decl without init clean")
	h.check(_has_err(h.analyze_text("extends RefCounted\n# @var x Node notnull\nvar x: Node\nfunc f() -> void:\n\tx = null\n", "res://tests/tmp_nn_a3.gd"), "var_notnull", "'x'"), "reassign null errors")
	h.check(_has_err(h.analyze_text("extends RefCounted\n# @var x Node notnull\nvar x: Node\nfunc f() -> void:\n\tx=null\n", "res://tests/tmp_nn_a4.gd"), "var_notnull", "'x'"), "nospace assign errors")
	h.check(_clean(h.analyze_text("extends RefCounted\n# @var x Node\nvar x: Node\nfunc f() -> void:\n\tx = null\n", "res://tests/tmp_nn_a5.gd")), "plain reassign stays silent")
	h.check(_clean(h.analyze_text("extends RefCounted\n# @var x Node notnull\nvar x: Node\nfunc f() -> void:\n\tx = Node.new()\n\tx.queue_free()\n", "res://tests/tmp_nn_a6.gd")), "non-null reassign clean")


func _n_guard(h) -> void:
	var src := "extends RefCounted\nfunc f(n: Node) -> void:\n\tif n != null:\n\t\tn = null\n"
	h.check(_has_err(h.analyze_text(src, "res://tests/tmp_nn_g1.gd"), "var_notnull", "'n'"), "guard then assign errors")
	var clear := "extends RefCounted\n# @var x Node notnull\nvar x: Node\nfunc f() -> void:\n\t# @var x Node\n\tx = null\n"
	h.check(_clean(h.analyze_text(clear, "res://tests/tmp_nn_g2.gd")), "plain redefinition clears flag")
	var elsenull := "extends RefCounted\nfunc f(n: Node) -> void:\n\tif n == null:\n\t\tpass\n\telse:\n\t\tn = null\n"
	h.check(_has_err(h.analyze_text(elsenull, "res://tests/tmp_nn_g3.gd"), "var_notnull", "'n'"), "else of eq errors")


func _n_param(h) -> void:
	h.check(_has_err(h.analyze_text("extends RefCounted\n# @param p Node notnull\nfunc f(p: Node = null):\n\tpass\n", "res://tests/tmp_nn_d1.gd"), "param_notnull", "'p'"), "null default errors")
	h.check(_clean(h.analyze_text("extends RefCounted\n# @param p Node notnull\nfunc f(p: Node):\n\tpass\n", "res://tests/tmp_nn_d2.gd")), "plain param clean")


func _n_return(h) -> void:
	h.check(_clean(h.analyze_text("extends RefCounted\n# @return Node notnull\nfunc f() -> Node:\n\tpass\n", "res://tests/tmp_nn_r1.gd")), "return flag clean")
	h.check(_has_err(h.analyze_text("extends RefCounted\n# @return Node notnull\nfunc f() -> Node:\n\treturn null\n", "res://tests/tmp_nn_r2.gd"), "return_notnull", "'f'"), "return null enforced")
	h.check(_has_err(h.analyze_text("extends RefCounted\n# @return Node notnull\nfunc f() -> Node:\n\treturn null # trailing note\n", "res://tests/tmp_nn_r4.gd"), "return_notnull", "'f'"), "trailing comment keeps enforcement")
	h.check(_has_err(h.analyze_text("extends RefCounted\nfunc g() -> void:\n\t# @return Node notnull\n\tvar f = func() -> Node:\n\t\treturn null\n", "res://tests/tmp_nn_r5.gd"), "return_notnull", "lambda"), "lambda return null enforced")
	h.check(_clean(h.analyze_text("extends RefCounted\n# @return Node notnull\nfunc f() -> Node:\n\treturn Node.new()\n", "res://tests/tmp_nn_r6.gd")), "value return clean")
	h.check(_has_err(h.analyze_text("extends RefCounted\n# @return Node notnull\nfunc f() -> Node:\n\treturn\n", "res://tests/tmp_nn_r3.gd"), "return_value", "bare return"), "bare return still fires")
	h.check(_clean(h.analyze_text("extends RefCounted\n# @return Node notnull\nfunc make() -> Node:\n\treturn Node.new()\n# @param p Node notnull\nfunc take(p: Node):\n\tpass\nfunc f() -> void:\n\ttake(make())\n", "res://tests/tmp_nn_r7.gd")), "call result trusted at call site")
	h.check(_clean(h.analyze_text("extends RefCounted\n# @return Node notnull\nfunc make() -> Node:\n\treturn Node.new()\nfunc f() -> void:\n\tvar v = make()\n\tv.queue_free()\n", "res://tests/tmp_nn_r8.gd")), "call result trusted in flow")


func _nn_kinds(res: Dictionary) -> Array:
	var out: Array = []
	for e in res.get("errors", []):
		if str((e as Dictionary).get("kind", "")) == "param_notnull":
			out.append(int((e as Dictionary).get("line", 0)))
	return out


func _n_callsite(h) -> void:
	var decl := "extends RefCounted\n# @param p Node notnull\nfunc take(p: Node):\n\tpass\n"
	h.check(_nn_kinds(h.analyze_text(decl + "func f() -> void:\n\ttake(null)\n", "res://tests/tmp_nn_s01.gd")) == [6], "bare null arg errors on its line")
	var res: Dictionary = h.analyze_text(decl + "func f() -> void:\n\ttake(\n\t\tnull\n\t)\n", "res://tests/tmp_nn_s02.gd")
	h.check(_nn_kinds(res) == [7], "multiline null arg pins arg line")
	h.check(_has_err(res, "param_notnull", "of 'take()'"), "message names callee")
	h.check(_clean(h.analyze_text("extends RefCounted\n# @var x Node notnull\nvar x: Node\n# @param p Node notnull\nfunc take(p: Node):\n\tpass\nfunc f() -> void:\n\ttake(x)\n", "res://tests/tmp_nn_s03.gd")), "notnull var arg clean")
	h.check(_clean(h.analyze_text(decl + "func f(v: Variant) -> void:\n\ttake(v)\n", "res://tests/tmp_nn_s04.gd")), "maybe-null arg stays silent")
	h.check(_clean(h.analyze_text(decl + "func f() -> void:\n\ttake(Node.new())\n", "res://tests/tmp_nn_s05.gd")), "fresh instance arg clean")
	h.check(_clean(h.analyze_text("extends RefCounted\n# @param p Node\nfunc take(p: Node):\n\tpass\nfunc f() -> void:\n\ttake(null)\n", "res://tests/tmp_nn_s06.gd")), "plain param accepts null")
	h.check(_nn_kinds(h.analyze_text("extends RefCounted\n# @param p Node notnull\nfunc take(p: Node):\n\tpass\nfunc f() -> void:\n\tself.take(null)\n", "res://tests/tmp_nn_s07.gd")) == [6], "self null arg errors")
	h.check(_clean(h.analyze_text("extends RefCounted\n# @param p Node notnull\nfunc take(p: Node):\n\tpass\nfunc f() -> void:\n\tself.take(Node.new())\n", "res://tests/tmp_nn_s08.gd")), "self non-null arg clean")
	h.check(_nn_kinds(h.analyze_text("extends RefCounted\nclass Box:\n\t# @param x Node notnull\n\tfunc store(x: Node) -> void:\n\t\tpass\nfunc f() -> void:\n\tvar b := Box.new()\n\tb.store(null)\n", "res://tests/tmp_nn_s09.gd")) == [8], "instance null arg errors")
	h.check(_clean(h.analyze_text("extends RefCounted\nclass Box:\n\t# @param x Node notnull\n\tfunc store(x: Node) -> void:\n\t\tpass\nfunc f() -> void:\n\tvar b := Box.new()\n\tb.store(Node.new())\n", "res://tests/tmp_nn_s10.gd")), "instance non-null arg clean")
	h.check(_nn_kinds(h.analyze_text("extends RefCounted\n# @param a int\n# @param p Node notnull\nfunc take2(a: int, p: Node):\n\tpass\nfunc f() -> void:\n\ttake2(1, null)\n", "res://tests/tmp_nn_s11.gd")) == [7], "positional mapping errors")
	h.check(_nn_kinds(h.analyze_text("extends RefCounted\nfunc f(take: int) -> void:\n\ttake(null)\n", "res://tests/tmp_nn_s12.gd")).is_empty(), "shadowing param suppresses")
	h.check(_nn_kinds(h.analyze_text("extends RefCounted\nclass Box2:\n\t# @param x Node notnull\n\tstatic func put(x: Node) -> void:\n\t\tpass\nfunc f() -> void:\n\tBox2.put(null)\n", "res://tests/tmp_nn_s13.gd")) == [7], "static null arg errors")
	var gen := "extends RefCounted\n# @template TG\n# @param x TG\n# @param y Node notnull\nfunc g(x, y):\n\tpass\nfunc f() -> void:\n\tg(1, null)\n"
	h.check(_nn_kinds(h.analyze_text(gen, "res://tests/tmp_nn_s14.gd")) == [8], "generic complement fires once")
	var lib := "class_name TmpNullCallLib\nextends RefCounted\n# @param m Node notnull\nfunc take2(m: Node):\n\tpass\n"
	h.analyze_text(lib, "res://tests/tmp_null_call_lib.gd")
	h.check(_nn_kinds(h.analyze_text("extends RefCounted\nfunc f(v: Variant) -> void:\n\tif v is TmpNullCallLib:\n\t\tv.take2(null)\n", "res://tests/tmp_null_call_consumer.gd")).is_empty(), "cross-script call stays silent")
