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
	h.check(_clean(h.analyze_text("extends RefCounted\n# @return Node notnull\nfunc f() -> Node:\n\treturn null\n", "res://tests/tmp_nn_r2.gd")), "return null not yet enforced")
	h.check(_has_err(h.analyze_text("extends RefCounted\n# @return Node notnull\nfunc f() -> Node:\n\treturn\n", "res://tests/tmp_nn_r3.gd"), "return_value", "bare return"), "bare return still fires")
