# @integrity_ignore_file (test harness uses virtual paths)
extends RefCounted

## @alias suite: block syntax (single/multi-line, @endalias delimiter),
## placement, conflicts, cycles, JSON storage, global availability and
## narrowing through expansion.

const H = preload("res://addons/0GnumarusGodotProjectAnalyzerSuite/tests/helpers.gd")


func run() -> Dictionary:
	var h = H.new()
	h.suite = "alias"
	_a_blocks(h)
	_a_placement(h)
	_a_conflicts(h)
	_a_use(h)
	_a_narrow(h)
	_a_json(h)
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


func _a_blocks(h) -> void:
	h.check(_clean(h.analyze_text("extends Node\n#@alias number int|float @endalias\n# @var x number\nvar x: Variant\n", "res://tests/tmp_ali_b01.gd")), "glued tag clean")
	h.check(_clean(h.analyze_text("extends Node\n# @alias pairs\n# tuple[int, String]\n# @endalias\n# @var p pairs\nvar p: Array\n", "res://tests/tmp_ali_b02.gd")), "multi-line clean")
	h.check(_clean(h.analyze_text("extends Node\n# @alias a int @endalias\n# @alias b a|float @endalias\n# @var x b\nvar x: Variant\n", "res://tests/tmp_ali_b03.gd")), "chained aliases clean")
	h.check(_has_err(h.analyze_text("extends Node\n# @alias number int|float\nvar x := 1\n", "res://tests/tmp_ali_b04.gd"), "alias_malformed", "missing @endalias"), "missing endalias malformed")
	h.check(_has_err(h.analyze_text("extends Node\n# @alias\nvar x := 1\n", "res://tests/tmp_ali_b05.gd"), "alias_malformed", "needs a name"), "bare tag malformed")
	h.check(_has_err(h.analyze_text("extends Node\n# @alias 123abc int @endalias\n", "res://tests/tmp_ali_b06.gd"), "alias_malformed", "invalid name"), "bad name malformed")
	h.check(_has_err(h.analyze_text("extends Node\n# @alias number @endalias\n", "res://tests/tmp_ali_b07.gd"), "alias_malformed", "needs a type expression"), "missing expr malformed")
	h.check(_has_err(h.analyze_text("extends Node\n# @alias number int|tuple[int\n# @endalias\n", "res://tests/tmp_ali_b08.gd"), "alias_malformed", "missing ']'"), "unbalanced expr malformed")
	h.check(_has_err(h.analyze_text("extends Node\n# @alias number void @endalias\n", "res://tests/tmp_ali_b09.gd"), "alias_malformed", "void"), "void def malformed")
	h.check(_has_err(h.analyze_text("extends Node\n# @alias number Nope|int @endalias\n", "res://tests/tmp_ali_b10.gd"), "alias_unknown_type", "Nope"), "unknown leaf errors")


func _a_placement(h) -> void:
	h.check(_kinds(h.analyze_text("extends Node\nfunc f():\n\t# @alias number int @endalias\n\tpass\n", "res://tests/tmp_ali_p01.gd")).has("alias_misplaced"), "inside func misplaced")
	h.check(_kinds(h.analyze_text("extends Node\nclass Inner:\n\t# @alias number int @endalias\n\tpass\n", "res://tests/tmp_ali_p02.gd")).is_empty(), "class body silent like tuples")
	h.check(_clean(h.analyze_text("extends Node\n# @alias number int @endalias\nclass Inner:\n\tpass\n", "res://tests/tmp_ali_p03.gd")), "before nested class clean")


func _a_conflicts(h) -> void:
	h.check(_has_err(h.analyze_text("extends Node\n# @alias number int @endalias\n# @alias number float @endalias\n", "res://tests/tmp_ali_c01.gd"), "alias_conflict", "more than once"), "duplicate conflicts")
	h.check(_has_err(h.analyze_text("extends Node\n# @tuple AliClash 1 int\n# @alias AliClash int @endalias\n", "res://tests/tmp_ali_c02.gd"), "alias_conflict", "existing type"), "tuple clash conflicts")
	h.check(_has_err(h.analyze_text("extends Node\n# @alias Node2D int @endalias\n", "res://tests/tmp_ali_c03.gd"), "alias_conflict", "existing type"), "engine clash conflicts")
	h.check(_has_err(h.analyze_text("extends Node\n# @alias A B @endalias\n# @alias B A @endalias\n", "res://tests/tmp_ali_c04.gd"), "alias_conflict", "circular"), "cycle conflicts")
	h.check(_has_err(h.analyze_text("extends Node\n# @alias A A @endalias\n", "res://tests/tmp_ali_c05.gd"), "alias_conflict", "circular"), "self cycle conflicts")


func _a_use(h) -> void:
	h.check(_clean(h.analyze_text("extends Node\n# @alias number int|float @endalias\n# @var x number\nvar x: Variant\n", "res://tests/tmp_ali_u01.gd")), "var use clean")
	h.check(_has_err(h.analyze_text("extends Node\n# @var x NoSuchAlias_xyz\nvar x: Variant\n", "res://tests/tmp_ali_u02.gd"), "var_unknown_type", "NoSuchAlias_xyz"), "use before JSON errors")
	h.check(_clean(h.analyze_text("extends Node\n# @alias answer int @endalias\n# @param p answer\nfunc f(p):\n\tpass\n", "res://tests/tmp_ali_u03.gd")), "param use clean")
	h.check(_clean(h.analyze_text("extends Node\n# @alias answer int @endalias\n# @return answer\nfunc f():\n\treturn 1\n", "res://tests/tmp_ali_u04.gd")), "return use clean")
	h.check(_has_err(h.analyze_text("extends Node\n# @tuple TxAP 2 int String\n# @alias bad TxAP[int] @endalias\n", "res://tests/tmp_ali_u05.gd"), "alias_mismatch", "expects 2 type arguments"), "tuple arity in def mismatches")
	h.check(_clean(h.analyze_text("extends Node\n# @tuple TxAQ 2 int String\n# @alias good TxAQ[int,String] @endalias\n# @var p good\nvar p: Array\n", "res://tests/tmp_ali_u06.gd")), "applied alias clean")


func _a_narrow(h) -> void:
	h.check(_clean(h.analyze_text("extends Node\n# @alias answer int @endalias\n# @var x answer\nvar x := 1\n", "res://tests/tmp_ali_n01.gd")), "narrow int clean")
	h.check(_has_err(h.analyze_text("extends Node\n# @alias number int|float @endalias\n# @var x number\nvar x := \"a\"\n", "res://tests/tmp_ali_n02.gd"), "var_mismatch", "from alias 'number'"), "narrow string mismatches")
	h.check(_clean(h.analyze_text("extends Node\n# @alias words String @endalias\n# @param p words\nfunc f(p: String):\n\tpass\n", "res://tests/tmp_ali_n03.gd")), "param narrow clean")
	h.check(_has_err(h.analyze_text("extends Node\n# @alias words String @endalias\n# @param p words\nfunc f(p: int):\n\tpass\n", "res://tests/tmp_ali_n04.gd"), "param_mismatch", "from alias 'words'"), "param narrow mismatches")
	h.check(_clean(h.analyze_text("extends Node\n# @alias answer int @endalias\n# @return answer\nfunc f() -> int:\n\treturn 1\n", "res://tests/tmp_ali_n05.gd")), "return arrow compat clean")
	h.check(_has_err(h.analyze_text("extends Node\n# @alias answer int @endalias\n# @return answer\nfunc f() -> String:\n\treturn \"a\"\n", "res://tests/tmp_ali_n06.gd"), "return_mismatch", "'int' with '-> String'"), "return arrow mismatch errors")
	h.check(_has_err(h.analyze_text("extends Node\n# @alias number int|float @endalias\n# @var x number\nvar x := \"a\" # trailing note\n", "res://tests/tmp_ali_n07.gd"), "var_mismatch", "from alias 'number'"), "trailing comment keeps mismatch")


func _a_json(h) -> void:
	h.analyze_text("extends Node\n# @alias JAliasNum int|float @endalias\n", "res://tests/tmp_ali_j01.gd")
	var info: Dictionary = h.load_json("res://.godot/0GnumarusGodotProjectAnalyzerSuiteData/user/JAliasNum.json")
	h.check(str(info.get("kind", "")) == "alias", "json kind alias")
	h.check(str((info.get("alias_tree", {}) as Dictionary).get("kind", "")) == "union", "json tree kept")
