extends RefCounted

## @private nested-family rule suite (migrated from the scratch runner).

const H = preload("res://addons/0GnumarusGodotProjectAnalyzerSuite/tests/helpers.gd")
const Syn = preload("res://addons/0GnumarusGodotProjectAnalyzerSuite/GnumarusGodotProjectAnalyzerSuiteGdscriptSyntaticParser.gd")
const Ana = preload("res://addons/0GnumarusGodotProjectAnalyzerSuite/GnumarusGodotProjectAnalyzerSuiteGdscriptAnalyzer.gd")


func run() -> Dictionary:
	var h = H.new()
	h.suite = "private"
	_f_root_uses_at_root(h)
	_f_inner_uses_root(h)
	_f_root_uses_inner(h)
	_f_deep_family(h)
	_f_static_family(h)
	_f_self_forms(h)
	_f_sibling_bare_and_qualified(h)
	_f_sibling_class_use(h)
	_f_inheritance(h)
	_f_inner_inherits(h)
	_f_shadow_still_ok(h)
	_f_misplaced_still_errors(h)
	_f_json_flags(h)
	_f_fixture_clean(h)
	return h.result()


func _f_root_uses_at_root(h) -> void:
	var src := "extends Node\n# @private\nvar _cache := 1\nfunc f() -> void:\n\tprint(_cache)\n\t_cache = 2\n\tself._cache = 3\n"
	var res: Dictionary = h.analyze_text(src, "res://tests/tmp_fam_root.gd")
	h.check(h.priv_errors(res).is_empty(), "root private used at root is allowed")


func _f_inner_uses_root(h) -> void:
	var src := "extends Node\n# @private\nvar _cache := 1\nclass Inner:\n\tfunc f() -> void:\n\t\tprint(_cache)\n\t\tprint(self._cache)\n"
	var res: Dictionary = h.analyze_text(src, "res://tests/tmp_fam_in.gd")
	h.check(h.priv_errors(res).is_empty(), "inner code may use outer privates")
	# NOTE: `self._cache` inside Inner is invalid scoping (Godot itself
	# rejects outer members in inner classes); the family rule governs
	# @private visibility only, so missing_member is expected while
	# private_use stays empty.
	var non_missing := 0
	var scoped := false
	for e in res.get("errors", []):
		if str((e as Dictionary).get("kind", "")) == "missing_member" and "_cache" in str((e as Dictionary).get("message", "")):
			scoped = true
		else:
			non_missing += 1
	h.check(non_missing == 0 and scoped, "only the scoping error besides family use")
	var info: Dictionary = h.load_json("res://.godot/0GnumarusGodotProjectAnalyzerSuiteData/user/tests_tmp_fam_in.json")
	h.check(h.field_flagged(info, "_cache"), "root private flag recorded in json")


func _f_root_uses_inner(h) -> void:
	var src := "extends Node\nclass Inner:\n\t# @private\n\tvar _x := 1\n\t# @private\n\tstatic func make() -> void:\n\t\tpass\nfunc f() -> void:\n\tprint(Inner._x)\n\tInner.make()\n\tvar it := Inner.new()\n"
	var res: Dictionary = h.analyze_text(src, "res://tests/tmp_fam_out.gd")
	h.check(h.priv_errors(res).is_empty(), "outer code may use inner privates")


func _f_deep_family(h) -> void:
	var src := "extends Node\n# @private\nvar _top := 1\nclass Outer:\n\tclass Deep:\n\t\t# @private\n\t\tvar _d := 2\n\t\tfunc f() -> void:\n\t\t\tprint(_top)\n\t\t\tprint(_d)\n\tfunc g() -> void:\n\t\tprint(Deep._d)\n"
	var res: Dictionary = h.analyze_text(src, "res://tests/tmp_fam_deep.gd")
	h.check(h.priv_errors(res).is_empty(), "transitive ancestor/descendant access allowed")
	h.check((res.get("errors", []) as Array).is_empty(), "no errors at all in deep family")
	var deep: Dictionary = h.load_json("res://.godot/0GnumarusGodotProjectAnalyzerSuiteData/user/tests_tmp_fam_deep.Outer.Deep.json")
	h.check(h.field_flagged(deep, "_d"), "deep private flag recorded in json")


func _f_static_family(h) -> void:
	var src := "class_name MyLib\nextends RefCounted\n# @private\nstatic var _s := 1\nclass Inner:\n\tfunc f() -> void:\n\t\tprint(MyLib._s)\n\t\tprint(_s)\n"
	var res: Dictionary = h.analyze_text(src, "res://tests/tmp_fam_static.gd")
	h.check(h.priv_errors(res).is_empty(), "inner may use root static private qualified or bare")


func _f_self_forms(h) -> void:
	var src := "extends Node\nclass Inner:\n\t# @private\n\tvar _x := 1\n\tfunc f() -> void:\n\t\tprint(self._x)\n\t\tprint(_x)\n\t\t_x = 2\n"
	var res: Dictionary = h.analyze_text(src, "res://tests/tmp_fam_self.gd")
	h.check(h.priv_errors(res).is_empty(), "self and bare uses inside owner allowed")


func _f_sibling_bare_and_qualified(h) -> void:
	# Siblings are NOT family: qualified access must fail.
	var src := "extends Node\nclass SibA:\n\tfunc f() -> void:\n\t\tprint(SibB._x)\nclass SibB:\n\t# @private\n\tvar _x := 1\n"
	var res: Dictionary = h.analyze_text(src, "res://tests/tmp_fam_sib.gd")
	h.check(h.priv_errors(res).size() == 1, "sibling qualified use is one violation")
	h.check(h.has_priv(res, "SibB._x"), "sibling message names SibB._x")
	# Cousins through a shared outer are still siblings of each other.
	var src2 := "extends Node\nclass Outer:\n\tclass A:\n\t\tfunc f() -> void:\n\t\t\tprint(B._x)\n\tclass B:\n\t\t# @private\n\t\tvar _x := 1\n"
	var res2: Dictionary = h.analyze_text(src2, "res://tests/tmp_fam_cousin.gd")
	h.check(h.priv_errors(res2).size() == 1, "cousin qualified use is one violation")


func _f_sibling_class_use(h) -> void:
	var src := "extends Node\nclass SibA:\n\tfunc f() -> void:\n\t\tvar o := SibB.new()\n# @private\nclass SibB:\n\tpass\n"
	var res: Dictionary = h.analyze_text(src, "res://tests/tmp_fam_sibclass.gd")
	h.check(h.priv_errors(res).size() == 1, "sibling private class use is one violation")
	h.check(h.has_priv(res, "SibB"), "sibling class message names SibB")


func _f_inheritance(h) -> void:
	var src := "extends Node\nclass Base:\n\t# @private\n\tvar _v := 1\nclass Child extends Base:\n\tfunc f() -> void:\n\t\tprint(self._v)\n\t\tprint(_v)\n"
	var res: Dictionary = h.analyze_text(src, "res://tests/tmp_fam_inherit.gd")
	h.check(h.priv_errors(res).size() == 2, "inheriting class use is two violations")
	h.check(h.has_priv(res, "Base"), "inherit message names declaring class")
	# ...but the child using its OWN private is fine.
	var src2 := "extends Node\nclass Base:\n\t# @private\n\tvar _v := 1\nclass Child extends Base:\n\t# @private\n\tvar _w := 2\n\tfunc f() -> void:\n\t\tprint(self._w)\n\t\tprint(_w)\n"
	var res2: Dictionary = h.analyze_text(src2, "res://tests/tmp_fam_inherit_ok.gd")
	h.check(h.priv_errors(res2).is_empty(), "own privates in inheriting class allowed")


func _f_inner_inherits(h) -> void:
	# Inner extends a sibling: still inheritance, still forbidden.
	var src := "extends Node\nclass Base:\n\t# @private\n\tvar _v := 1\nclass Outer:\n\tclass Child extends Base:\n\t\tfunc f() -> void:\n\t\t\tprint(self._v)\n"
	var res: Dictionary = h.analyze_text(src, "res://tests/tmp_fam_inner_inherit.gd")
	h.check(h.priv_errors(res).size() == 1, "inner inheriting use is one violation")


func _f_shadow_still_ok(h) -> void:
	var src := "extends Node\n# @private\nvar _x := 1\nclass Inner:\n\tfunc f(_x: int) -> void:\n\t\tprint(_x)\n"
	var res: Dictionary = h.analyze_text(src, "res://tests/tmp_fam_shadow.gd")
	h.check(h.priv_errors(res).is_empty(), "param shadowing suppresses")


func _f_misplaced_still_errors(h) -> void:
	var src := "# @private\nclass_name Foo\n"
	var res: Dictionary = h.analyze_text(src, "res://tests/tmp_fam_misplaced.gd")
	var kinds: Array = h.err_kinds(res)
	h.check(kinds.has("private_misplaced"), "root @private still misplaced")


func _f_json_flags(h) -> void:
	var src := "class_name JLib\nextends Node\n# @private\nvar _a := 1\nclass In:\n\t# @private\n\tvar _b := 2\n"
	var res: Dictionary = h.analyze_text(src, "res://tests/tmp_fam_json.gd")
	var info: Dictionary = h.load_json("res://.godot/0GnumarusGodotProjectAnalyzerSuiteData/user/JLib.json")
	var flagged := false
	for f in info.get("fields", []):
		if str((f as Dictionary).get("name", "")) == "_a" and (f as Dictionary).has("private"):
			flagged = true
	h.check(flagged, "main json flags private field")
	var inner: Dictionary = h.load_json("res://.godot/0GnumarusGodotProjectAnalyzerSuiteData/user/JLib.In.json")
	var flagged2 := false
	for f in inner.get("fields", []):
		if str((f as Dictionary).get("name", "")) == "_b" and (f as Dictionary).has("private"):
			flagged2 = true
	h.check(flagged2, "inner json flags private field")
	h.check(((res.get("errors", []) as Array).is_empty()), "no errors in flag fixture")


func _f_fixture_clean(h) -> void:
	var syn = Syn.new()
	var ana = Ana.new()
	var ast: Dictionary = syn.parse("res://addons/0GnumarusGodotProjectAnalyzerSuite/tests/ValidScript0.gd")
	var res: Dictionary = ana.analyze(ast, "res://addons/0GnumarusGodotProjectAnalyzerSuite/tests/ValidScript0.gd")
	h.check((res.get("errors", []) as Array).is_empty(), "fixture no analyzer errors")
	h.check((res.get("warnings", []) as Array).is_empty(), "fixture no analyzer warnings")
