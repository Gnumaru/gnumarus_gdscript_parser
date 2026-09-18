extends RefCounted

## @template suite: file-local generic variables (order-free knownness,
## conflicts, bounds) plus the substitution/unification IR (infra only:
## nothing instantiates yet).

const H = preload("res://addons/0GnumarusGodotProjectAnalyzerSuite/tests/helpers.gd")
const Ana = preload("res://addons/0GnumarusGodotProjectAnalyzerSuite/GnumarusGodotProjectAnalyzerSuiteGdscriptAnalyzer.gd")


func run() -> Dictionary:
	var h = H.new()
	h.suite = "template"
	_t_defs(h)
	_t_placement(h)
	_t_conflicts(h)
	_t_bounds(h)
	_t_use(h)
	_t_ir(h)
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


func _t_defs(h) -> void:
	h.check(_clean(h.analyze_text("extends Node\n# @template TplA\n# @var x TplA\nvar x: Variant\n", "res://tests/tmp_tpl_d01.gd")), "bare def clean")
	h.check(_clean(h.analyze_text("extends Node\n# @var x TplB\nvar x: Variant\n# @template TplB\n", "res://tests/tmp_tpl_d02.gd")), "use before def clean")
	h.check(_clean(h.analyze_text("extends Node\n# @template TplC of int|float\n# @var x TplC\nvar x: Variant\n", "res://tests/tmp_tpl_d03.gd")), "bounded def clean")
	h.check(_has_err(h.analyze_text("extends Node\n# @template\nvar x := 1\n", "res://tests/tmp_tpl_d04.gd"), "template_malformed", "needs a name"), "bare tag malformed")
	h.check(_has_err(h.analyze_text("extends Node\n# @template 123\n", "res://tests/tmp_tpl_d05.gd"), "template_malformed", "invalid name"), "bad name malformed")
	h.check(_has_err(h.analyze_text("extends Node\n# @template TplD6 of\n", "res://tests/tmp_tpl_d06.gd"), "template_malformed", "needs a bound"), "dangling of malformed")
	h.check(_has_err(h.analyze_text("extends Node\n# @template TplD7 int\n", "res://tests/tmp_tpl_d07.gd"), "template_malformed", "needs 'of'"), "missing of malformed")


func _t_placement(h) -> void:
	h.check(_kinds(h.analyze_text("extends Node\nfunc f():\n\t# @template TplT\n\tpass\n", "res://tests/tmp_tpl_p01.gd")).has("template_misplaced"), "inside func misplaced")
	h.check(_kinds(h.analyze_text("extends Node\nclass Inner:\n\t# @template TplT\n\tpass\n", "res://tests/tmp_tpl_p02.gd")).is_empty(), "class body silent like tuples")
	h.check(_clean(h.analyze_text("extends Node\n# @template TplD\nclass Inner:\n\tpass\n", "res://tests/tmp_tpl_p03.gd")), "before nested class clean")


func _t_conflicts(h) -> void:
	h.check(_has_err(h.analyze_text("extends Node\n# @template TplN\n# @template TplN\n", "res://tests/tmp_tpl_c01.gd"), "template_conflict", "more than once"), "duplicate conflicts")
	h.check(_has_err(h.analyze_text("extends Node\n# @tuple TplO 1 int\n# @template TplO\n", "res://tests/tmp_tpl_c02.gd"), "template_conflict", "existing template type"), "tuple clash conflicts")
	h.check(_has_err(h.analyze_text("extends Node\n# @template Node2D\n", "res://tests/tmp_tpl_c03.gd"), "template_conflict", "existing type"), "engine clash conflicts")
	h.check(_has_err(h.analyze_text("extends Node\nclass_name TplFoo\n# @template TplFoo\nvar x := 1\n", "res://tests/tmp_tpl_c04.gd"), "template_conflict", "script class name"), "class-name clash conflicts")


func _t_bounds(h) -> void:
	h.check(_has_err(h.analyze_text("extends Node\n# @template TplE of Nope\n", "res://tests/tmp_tpl_b01.gd"), "template_unknown_type", "Nope"), "unknown bound leaf errors")
	h.check(_has_err(h.analyze_text("extends Node\n# @template TplF of void\n", "res://tests/tmp_tpl_b02.gd"), "template_malformed", "void"), "void bound malformed")
	h.check(_has_err(h.analyze_text("extends Node\n# @template TplG of TplH\n# @template TplH\n", "res://tests/tmp_tpl_b03.gd"), "template_malformed", "concrete"), "template bound rejected")
	h.check(_has_err(h.analyze_text("extends Node\n# @tuple TplP 2 int String\n# @template TplI of TplP[int]\n", "res://tests/tmp_tpl_b04.gd"), "template_mismatch", "expects 2 type arguments"), "bound tuple arity mismatches")
	h.check(_clean(h.analyze_text("extends Node\n# @tuple TplQ 2 int String\n# @template TplJ of TplQ[int,String]\n", "res://tests/tmp_tpl_b05.gd")), "bound tuple clean")


func _t_use(h) -> void:
	h.check(_clean(h.analyze_text("extends Node\n# @template TplK\n# @var x TplK\nvar x: Variant\n", "res://tests/tmp_tpl_u01.gd")), "var use clean")
	h.check(_has_err(h.analyze_text("extends Node\n# @var x NopeTpl_xyz\nvar x: Variant\n", "res://tests/tmp_tpl_u02.gd"), "var_unknown_type", "NopeTpl_xyz"), "undeclared stays unknown")
	h.check(_clean(h.analyze_text("extends Node\n# @template TplL\n# @param p TplL\nfunc f(p):\n\tpass\n", "res://tests/tmp_tpl_u03.gd")), "param use clean")
	h.check(_clean(h.analyze_text("extends Node\n# @template TplM\n# @return TplM\nfunc f():\n\treturn 1\n", "res://tests/tmp_tpl_u04.gd")), "return use clean")


func _t_ir(h) -> void:
	var t := {"kind": "name", "name": "T"}
	var i := {"kind": "name", "name": "int"}
	h.check(Ana._same_tree(t, {"kind": "name", "name": "T"}), "same name")
	h.check(not Ana._same_tree(t, i), "different names differ")
	h.check(Ana._same_tree({"kind": "generic", "name": "A", "args": [t]}, {"kind": "generic", "name": "A", "args": [{"kind": "name", "name": "T"}]}), "nested equal")
	h.check(not Ana._same_tree({"kind": "union", "arms": [t]}, {"kind": "union", "arms": [t, i]}), "arity differs")
	var s := Ana._subst_tree({"kind": "generic", "name": "A", "args": [t, i]}, {"T": {"kind": "generic", "name": "B", "args": [i]}})
	h.check(str(s.get("name", "")) == "A" and str(((s.get("args", []) as Array)[0] as Dictionary).get("name", "")) == "B", "subst nested")
	h.check(str((Ana._subst_tree(i, {}) as Dictionary).get("name", "")) == "int", "subst no-op")
	h.check(Ana._template_refs({"kind": "union", "arms": [t, i]}, ["T"]) == ["T"], "refs collect")
	var u1 := Ana._unify_trees(t, i, {}, ["T"])
	h.check(bool(u1.get("ok", false)) and str(((u1.get("subst", {}) as Dictionary).get("T", {}) as Dictionary).get("name", "")) == "int", "binds var")
	var u2 := Ana._unify_trees(t, {"kind": "name", "name": "String"}, {"T": i}, ["T"])
	h.check(not bool(u2.get("ok", false)), "conflicting rebind fails")
	h.check(bool(Ana._unify_trees(i, i, {}, []).get("ok", false)), "concrete match")
	h.check(not bool(Ana._unify_trees(i, {"kind": "name", "name": "String"}, {}, []).get("ok", false)), "concrete mismatch fails")
	h.check(bool(Ana._unify_trees({"kind": "generic", "name": "A", "args": [t]}, {"kind": "generic", "name": "A", "args": [i]}, {}, ["T"]).get("ok", false)), "generic args unify")
	h.check(not bool(Ana._unify_trees({"kind": "generic", "name": "A", "args": [t, t]}, {"kind": "generic", "name": "A", "args": [i]}, {}, ["T"]).get("ok", false)), "generic arity fails")
	h.check(bool(Ana._unify_trees({"kind": "union", "arms": [i, t]}, i, {}, ["T"]).get("ok", false)), "union arm matches")
	h.check(Ana._check_bound({"kind": "name", "name": "int"}, i), "bound fits")
	h.check(not Ana._check_bound({"kind": "name", "name": "String"}, i), "bound rejects")
	h.check(Ana._check_bound({}, i), "empty bound passes")
