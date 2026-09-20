extends RefCounted

## nullable suite: trailing `nullable` on @var/@param/@return (parse,
## stamps, contradiction with `notnull` and never-nullable types),
## trust-mode opt-in warnings, `@return nullable` call-result taint,
## distrust policy via the analyzer `null_policy` property (default
## trust), guard-clause narrowing, and `nullable_params` JSON data.

const H = preload("res://addons/0GnumarusGodotProjectAnalyzerSuite/tests/helpers.gd")


func run() -> Dictionary:
	var h = H.new()
	h.suite = "nullable"
	_nb_parse(h)
	_nb_clash(h)
	_nb_trust(h)
	_nb_return(h)
	_nb_distrust(h)
	_nb_json(h)
	_nb_policy(h)
	_nb_setting(h)
	_nb_filetag(h)
	_nb_boundary(h)
	_nb_istest(h)
	_nb_frontier(h)
	_nb_taintx(h)
	_nb_elif(h)
	_nb_strict(h)
	_nb_reassign(h)
	_nb_bind(h)
	return h.result()


func _kinds(res: Dictionary) -> Array:
	var out: Array = []
	for e in res.get("errors", []):
		out.append(str((e as Dictionary).get("kind", "")))
	return out


func _warn_kinds(res: Dictionary) -> Array:
	var out: Array = []
	for w in res.get("warnings", []):
		out.append(str((w as Dictionary).get("kind", "")))
	return out


func _has_err(res: Dictionary, kind: String, part: String) -> bool:
	for e in res.get("errors", []):
		if str((e as Dictionary).get("kind", "")) == kind and part in str((e as Dictionary).get("message", "")):
			return true
	return false


func _clean(res: Dictionary) -> bool:
	return (res.get("errors", []) as Array).is_empty()


func _nb_parse(h) -> void:
	h.check(_clean(h.analyze_text("extends RefCounted\n# @var x Node nullable\nvar x: Node\n", "res://tests/tmp_nb_p01.gd")), "var flag clean")
	h.check(_clean(h.analyze_text("extends RefCounted\n# @param p Node nullable\nfunc f(p: Node):\n\tpass\n", "res://tests/tmp_nb_p02.gd")), "param flag clean")
	h.check(_clean(h.analyze_text("extends RefCounted\n# @return Node nullable\nfunc f() -> Node:\n\tpass\n", "res://tests/tmp_nb_p03.gd")), "return flag clean")
	h.check(_kinds(h.analyze_text("extends RefCounted\n# @var x Node|nullable\nvar x: Variant\n", "res://tests/tmp_nb_p04.gd")).has("var_unknown_type"), "pipe spelling stays unknown")
	h.check(_kinds(h.analyze_text("extends RefCounted\n# @return void nullable\nfunc f() -> void:\n\tpass\n", "res://tests/tmp_nb_p05.gd")).has("return_malformed"), "void nullable malformed")
	h.check(_kinds(h.analyze_text("extends RefCounted\n# @var x nullable\nvar x: Variant\n", "res://tests/tmp_nb_p06.gd")).has("var_malformed"), "bare nullable needs a type")
	h.check(_has_err(h.analyze_text("extends RefCounted\n# @var x Node notnull nullable\nvar x: Node\n", "res://tests/tmp_nb_p07.gd"), "var_malformed", "cannot combine"), "var both markers malformed")
	h.check(_has_err(h.analyze_text("extends RefCounted\n# @param p Node nullable notnull\nfunc f(p: Node):\n\tpass\n", "res://tests/tmp_nb_p08.gd"), "param_malformed", "cannot combine"), "param both markers malformed")
	h.check(_has_err(h.analyze_text("extends RefCounted\n# @return Node nullable notnull\nfunc f() -> Node:\n\tpass\n", "res://tests/tmp_nb_p09.gd"), "return_malformed", "cannot combine"), "return both markers malformed")


func _nb_clash(h) -> void:
	h.check(_has_err(h.analyze_text("extends RefCounted\n# @var x int nullable\nvar x: int\n", "res://tests/tmp_nb_c1.gd"), "var_malformed", "non-nullable"), "var nullable int malformed")
	h.check(_has_err(h.analyze_text("extends RefCounted\n# @param p int nullable\nfunc f(p: int):\n\tpass\n", "res://tests/tmp_nb_c2.gd"), "param_malformed", "non-nullable"), "param nullable int malformed")
	h.check(_has_err(h.analyze_text("extends RefCounted\n# @return int nullable\nfunc f() -> int:\n\tpass\n", "res://tests/tmp_nb_c3.gd"), "return_malformed", "non-nullable"), "return nullable int malformed")
	h.check(_clean(h.analyze_text("extends RefCounted\n# @var x Node|null nullable\nvar x: Variant\n", "res://tests/tmp_nb_c4.gd")), "nullable null-arm redundant clean")
	h.check(_clean(h.analyze_text("extends RefCounted\n# @alias MaybeN Node|null @endalias\n# @var x MaybeN nullable\nvar x: Variant\n", "res://tests/tmp_nb_c5.gd")), "nullable alias clean")
	h.check(_clean(h.analyze_text("extends RefCounted\n# @var x Node nullable\nvar x: Node\n", "res://tests/tmp_nb_c6.gd")), "nullable plain Node clean")


func _nb_trust(h) -> void:
	var use := "extends RefCounted\n# @var x Node nullable\nvar x: Node\nfunc f() -> void:\n\tx.queue_free()\n"
	var r: Dictionary = h.analyze_text(use, "res://tests/tmp_nb_t1.gd")
	h.check(_clean(r) and h.has_warn(r, "(nullable 'Node')"), "trust nullable use warns")
	h.check(_warn_kinds(r) == ["maybe_null"], "trust warn kind maybe_null")
	var guarded := "extends RefCounted\n# @var x Node nullable\nvar x: Node\nfunc f() -> void:\n\tif x != null:\n\t\tx.queue_free()\n"
	h.check(h.warn_texts(h.analyze_text(guarded, "res://tests/tmp_nb_t2.gd")).is_empty(), "trust guarded use clean")
	var plain := "extends RefCounted\nvar x: Node\nfunc f() -> void:\n\tx.queue_free()\n"
	h.check(h.warn_texts(h.analyze_text(plain, "res://tests/tmp_nb_t3.gd")).is_empty(), "trust plain Node silent")
	var variant := "extends RefCounted\nvar v: Variant\nfunc f() -> void:\n\tv.foo()\n"
	h.check(_has_err(h.analyze_text(variant, "res://tests/tmp_nb_t4.gd"), "missing_method", "'foo()'"), "trust Variant member still missing_method")
	var untyped := "extends RefCounted\nfunc f() -> void:\n\tvar u = null\n\tu.foo()\n"
	h.check(_clean(h.analyze_text(untyped, "res://tests/tmp_nb_t5.gd")), "trust untyped silent")
	var param := "extends RefCounted\n# @param p Node nullable\nfunc f(p: Node) -> void:\n\tp.queue_free()\n"
	var rp: Dictionary = h.analyze_text(param, "res://tests/tmp_nb_t6.gd")
	h.check(_clean(rp) and h.has_warn(rp, "(nullable 'Node')"), "trust nullable param warns")
	var member := "extends RefCounted\n# @var x Node nullable\nvar x: Node\nfunc f() -> void:\n\tx.queue_free()\n"
	h.check(h.has_warn(h.analyze_text(member, "res://tests/tmp_nb_t7.gd"), "on 'x'"), "trust nullable member warns at use line")
	var fact := "extends RefCounted\nfunc f(n: Node) -> void:\n\t# @var n Node nullable\n\tn.queue_free()\n"
	h.check(h.has_warn(h.analyze_text(fact, "res://tests/tmp_nb_t8.gd"), "(nullable 'Node')"), "trust mid-function fact warns")
	var initnull := "extends RefCounted\n# @var x Node nullable\nvar x: Node = null\n"
	h.check(_clean(h.analyze_text(initnull, "res://tests/tmp_nb_t9.gd")), "nullable init null allowed")


func _nb_return(h) -> void:
	var head := "extends RefCounted\n# @return Node nullable\nfunc make() -> Node:\n\treturn Node.new()\n"
	var tainted := head + "func g() -> void:\n\tvar r = make()\n\tr.queue_free()\n"
	var rt: Dictionary = h.analyze_text(tainted, "res://tests/tmp_nb_r1.gd")
	h.check(_clean(rt) and h.has_warn(rt, "(nullable 'Node')"), "tainted result warns")
	var guarded := head + "func g() -> void:\n\tvar r = make()\n\tif r != null:\n\t\tr.queue_free()\n"
	h.check(h.warn_texts(h.analyze_text(guarded, "res://tests/tmp_nb_r2.gd")).is_empty(), "tainted guarded clean")
	var plain := "extends RefCounted\nfunc make() -> Node:\n\treturn Node.new()\nfunc g() -> void:\n\tvar r = make()\n\tr.queue_free()\n"
	h.check(h.warn_texts(h.analyze_text(plain, "res://tests/tmp_nb_r3.gd")).is_empty(), "plain return clean")
	var chain := head + "func g() -> void:\n\tmake().queue_free()\n"
	h.check(_clean(h.analyze_text(chain, "res://tests/tmp_nb_r4.gd")), "direct chain stays silent (gap)")
	var reassign := head + "func g() -> void:\n\tvar r = make()\n\tr = Node.new()\n\tr.queue_free()\n"
	h.check(h.warn_texts(h.analyze_text(reassign, "res://tests/tmp_nb_r5.gd")).is_empty(), "reassign clears taint")
	var selfcall := "extends RefCounted\n# @return Node nullable\nfunc make() -> Node:\n\treturn Node.new()\nfunc g() -> void:\n\tvar r = self.make()\n\tr.queue_free()\n"
	h.check(h.has_warn(h.analyze_text(selfcall, "res://tests/tmp_nb_r6.gd"), "(nullable 'Node')"), "self call taints")
	var nullret := "extends RefCounted\n# @return Node|null\nfunc make2():\n\treturn null\nfunc g() -> void:\n\tvar r = make2()\n\tr.queue_free()\n"
	h.check(h.has_warn(h.analyze_text(nullret, "res://tests/tmp_nb_r7.gd"), "(nullable 'Node|null')"), "explicit null return warns")
	var retnull := "extends RefCounted\n# @return Node nullable\nfunc make() -> Node:\n\treturn null\n"
	h.check(_clean(h.analyze_text(retnull, "res://tests/tmp_nb_r8.gd")), "nullable return null allowed")


func _nb_distrust(h) -> void:
	var plain := "extends RefCounted\nfunc f(n: Node) -> void:\n\tn.queue_free()\n"
	var r: Dictionary = h.analyze_text(plain, "res://tests/tmp_nb_d01.gd", "distrust")
	h.check(_clean(r) and h.has_warn(r, "(implicitly nullable 'Node')"), "distrust plain Node warns")
	h.check(_warn_kinds(r) == ["maybe_null"], "distrust warn kind maybe_null")
	var guarded := "extends RefCounted\nfunc f(n: Node) -> void:\n\tif n != null:\n\t\tn.queue_free()\n"
	h.check(h.warn_texts(h.analyze_text(guarded, "res://tests/tmp_nb_d02.gd", "distrust")).is_empty(), "distrust guarded clean")
	var clause := "extends RefCounted\nfunc f(n: Node) -> void:\n\tif n == null:\n\t\treturn\n\tn.queue_free()\n"
	h.check(h.warn_texts(h.analyze_text(clause, "res://tests/tmp_nb_d03.gd", "distrust")).is_empty(), "distrust guard clause clean")
	var clause_else := "extends RefCounted\nfunc f(n: Node) -> void:\n\tif n != null:\n\t\tpass\n\telse:\n\t\treturn\n\tn.queue_free()\n"
	h.check(h.warn_texts(h.analyze_text(clause_else, "res://tests/tmp_nb_d04.gd", "distrust")).is_empty(), "distrust else-return clause clean")
	var bare := "extends RefCounted\nfunc f(n: Node) -> void:\n\tif not n:\n\t\treturn\n\tn.queue_free()\n"
	h.check(h.warn_texts(h.analyze_text(bare, "res://tests/tmp_nb_d05.gd", "distrust")).is_empty(), "distrust bare clause clean")
	var no_return := "extends RefCounted\nfunc f(n: Node) -> void:\n\tif n == null:\n\t\tpass\n\tn.queue_free()\n"
	h.check(h.has_warn(h.analyze_text(no_return, "res://tests/tmp_nb_d06.gd", "distrust"), "implicitly nullable"), "distrust non-return branch still warns")
	var vint := "extends RefCounted\nfunc f(i: int) -> void:\n\ti = 2\n"
	h.check(h.warn_texts(h.analyze_text(vint, "res://tests/tmp_nb_d07.gd", "distrust")).is_empty(), "distrust int clean")
	var untyped := "extends RefCounted\nfunc f() -> void:\n\tvar u = null\n\tu.foo()\n"
	h.check(_clean(h.analyze_text(untyped, "res://tests/tmp_nb_d08.gd", "distrust")), "distrust untyped clean")
	var variant := "extends RefCounted\nvar v: Variant\nfunc f() -> void:\n\tv.foo()\n"
	var rv: Dictionary = h.analyze_text(variant, "res://tests/tmp_nb_d09.gd", "distrust")
	h.check(_has_err(rv, "missing_method", "'foo()'") and h.warn_texts(rv).is_empty(), "distrust Variant unchanged missing_method")
	var marked := "extends RefCounted\n# @var x Node notnull\nvar x: Node\nfunc f() -> void:\n\tx.queue_free()\n"
	h.check(h.warn_texts(h.analyze_text(marked, "res://tests/tmp_nb_d10.gd", "distrust")).is_empty(), "distrust notnull clean")
	var alias := "extends RefCounted\n# @alias N2 Node @endalias\n# @var x N2\nvar x: Variant\nfunc f() -> void:\n\tx.queue_free()\n"
	h.check(h.has_warn(h.analyze_text(alias, "res://tests/tmp_nb_d11.gd", "distrust"), "implicitly nullable"), "distrust alias expands")


func _nb_json(h) -> void:
	var lib := "class_name TmpNullNbLib\nextends RefCounted\n# @param a Node nullable\nfunc take(a: Node) -> void:\n\tpass\n# @param b Node notnull\nfunc keep(b: Node) -> void:\n\tpass\n"
	h.analyze_text(lib, "res://tests/tmp_null_nblib.gd")
	var info: Dictionary = h.load_json("res://.godot/0GnumarusGodotProjectAnalyzerSuiteData/user/TmpNullNbLib.json")
	var take_entry := {}
	var keep_entry := {}
	for m in info.get("instance_methods", []):
		if str((m as Dictionary).get("name", "")) == "take":
			take_entry = m
		if str((m as Dictionary).get("name", "")) == "keep":
			keep_entry = m
	h.check((take_entry as Dictionary).get("param_names", []) == ["a"], "json nullable param order")
	h.check((take_entry as Dictionary).get("nullable_params", []) == ["a"], "json nullable flags")
	h.check((take_entry as Dictionary).get("notnull_params", []) == [], "json nullable adds no notnull")
	h.check((keep_entry as Dictionary).get("notnull_params", []) == ["b"], "json notnull intact")
	h.check((keep_entry as Dictionary).get("nullable_params", []) == [], "json notnull adds no nullable")


func _nb_policy(h) -> void:
	var ana = H.Analyzer.new()
	ana.null_policy = "bogus-value"
	var syn = H.SynParser.new()
	var res: Dictionary = ana.analyze(syn.parse_text("extends RefCounted\nfunc f(n: Node) -> void:\n\tn.queue_free()\n"), "res://tests/tmp_nb_s1.gd")
	h.check((res.get("warnings", []) as Array).is_empty(), "invalid policy falls back to trust")
	var ana2 = H.Analyzer.new()
	h.check(str(ana2.null_policy) == "trust", "policy default trust")


func _nb_setting(h) -> void:
	ProjectSettings.set_setting("gnumarus_analyzer/nullable_policy", "distrust")
	var plain := "extends RefCounted\nfunc f(n: Node) -> void:\n\tn.queue_free()\n"
	var r: Dictionary = h.analyze_text(plain, "res://tests/tmp_nb_s2.gd")
	h.check(_clean(r) and h.has_warn(r, "implicitly nullable"), "setting distrust warns")
	var ana = H.Analyzer.new()
	ana.null_policy = "trust"
	var syn = H.SynParser.new()
	var rprop: Dictionary = ana.analyze(syn.parse_text(plain), "res://tests/tmp_nb_s3.gd")
	h.check(h.warn_texts(rprop).is_empty(), "explicit property beats setting")
	ProjectSettings.set_setting("gnumarus_analyzer/nullable_policy", "bogus")
	h.check(h.warn_texts(h.analyze_text(plain, "res://tests/tmp_nb_s4.gd")).is_empty(), "bogus setting falls back to trust")
	ProjectSettings.set_setting("gnumarus_analyzer/nullable_policy", "trust")
	h.check(h.warn_texts(h.analyze_text(plain, "res://tests/tmp_nb_s5.gd")).is_empty(), "setting restored to trust")


func _nb_filetag(h) -> void:
	var plain := "extends RefCounted\nfunc f(n: Node) -> void:\n\tn.queue_free()\n"
	var r: Dictionary = h.analyze_text("# @nullable_policy distrust\n" + plain, "res://tests/tmp_nb_f1.gd")
	h.check(_clean(r) and h.has_warn(r, "implicitly nullable"), "header tag distrust warns")
	var r2: Dictionary = h.analyze_text("# @nullable_policy trust\n" + plain, "res://tests/tmp_nb_f2.gd", "distrust")
	h.check(h.warn_texts(r2).is_empty(), "header tag trust beats property")
	ProjectSettings.set_setting("gnumarus_analyzer/nullable_policy", "distrust")
	h.check(h.warn_texts(h.analyze_text("# @nullable_policy trust\n" + plain, "res://tests/tmp_nb_f3.gd")).is_empty(), "header tag beats setting")
	ProjectSettings.set_setting("gnumarus_analyzer/nullable_policy", "trust")
	var doc := "# Showcase doc line\n# @nullable_policy distrust\n" + plain
	h.check(h.has_warn(h.analyze_text(doc, "res://tests/tmp_nb_f4.gd"), "implicitly nullable"), "tag works below doc lines")
	var misplaced := "extends RefCounted\nfunc f(n: Node) -> void:\n\t# @nullable_policy distrust\n\tn.queue_free()\n"
	h.check(_has_err(h.analyze_text(misplaced, "res://tests/tmp_nb_f5.gd"), "policy_misplaced", "first comment block"), "in-body tag misplaced")
	var member_level := "extends RefCounted\n# @nullable_policy distrust\nfunc f(n: Node) -> void:\n\tn.queue_free()\n"
	h.check(_has_err(h.analyze_text(member_level, "res://tests/tmp_nb_f6.gd"), "policy_misplaced", "first comment block"), "member-level tag misplaced")
	h.check(_has_err(h.analyze_text("# @nullable_policy strict\nextends RefCounted\n", "res://tests/tmp_nb_f7.gd"), "policy_malformed", "'trust' or 'distrust'"), "bad tag value malformed")


func _nb_boundary(h) -> void:
	var lib := "class_name TmpNullP3Lib\nextends RefCounted\nfunc plain(a: Node) -> void:\n\tpass\n# @param b Node nullable\nfunc take(b: Node) -> void:\n\tpass\n# @param c Node notnull\nfunc need(c: Node) -> void:\n\tpass\n"
	h.analyze_text(lib, "res://tests/tmp_null_p3lib.gd")
	var info: Dictionary = h.load_json("res://.godot/0GnumarusGodotProjectAnalyzerSuiteData/user/TmpNullP3Lib.json")
	h.check(str(info.get("null_policy", "")) == "trust", "json carries file policy")
	var watched := "extends RefCounted\n# @var x Node nullable\nvar x: Node\nfunc g() -> void:\n\tTmpNullP3Lib.plain(x)\n"
	var r: Dictionary = h.analyze_text(watched, "res://tests/tmp_nb_b1.gd", "distrust")
	h.check(_clean(r) and h.has_warn(r, "possible null argument 'x'"), "boundary implicit warns")
	h.check(_warn_kinds(r) == ["maybe_null"], "boundary warn kind maybe_null")
	var consent := "extends RefCounted\n# @var x Node nullable\nvar x: Node\nfunc g() -> void:\n\tTmpNullP3Lib.take(x)\n"
	h.check(h.warn_texts(h.analyze_text(consent, "res://tests/tmp_nb_b2.gd", "distrust")).is_empty(), "boundary consent silent")
	var literal := "extends RefCounted\nfunc g() -> void:\n\tTmpNullP3Lib.plain(null)\n"
	h.check(h.has_warn(h.analyze_text(literal, "res://tests/tmp_nb_b3.gd", "distrust"), "possible null argument 'null'"), "boundary literal warns")
	var policy_arg := "extends RefCounted\nfunc g(n: Node) -> void:\n\tTmpNullP3Lib.plain(n)\n"
	h.check(h.warn_texts(h.analyze_text(policy_arg, "res://tests/tmp_nb_b4.gd", "distrust")).is_empty(), "boundary policy-arg silent")
	var guarded := "extends RefCounted\n# @var x Node nullable\nvar x: Node\nfunc g() -> void:\n\tif x != null:\n\t\tTmpNullP3Lib.plain(x)\n"
	h.check(h.warn_texts(h.analyze_text(guarded, "res://tests/tmp_nb_b5.gd", "distrust")).is_empty(), "boundary guarded silent")
	var refused := "extends RefCounted\n# @var x Node nullable\nvar x: Node\nfunc g() -> void:\n\tTmpNullP3Lib.need(x)\n"
	var rr: Dictionary = h.analyze_text(refused, "res://tests/tmp_nb_b6.gd", "distrust")
	h.check(_clean(rr) and h.has_warn(rr, "possible null argument 'x' for notnull parameter 'c'"), "boundary notnull-maybe warns")
	var samefile := "extends RefCounted\nfunc take(a: Node) -> void:\n\ta.queue_free()\n# @var x Node nullable\nvar x: Node\nfunc g() -> void:\n\ttake(x)\n"
	var rs: Dictionary = h.analyze_text(samefile, "res://tests/tmp_nb_b7.gd", "distrust")
	h.check((rs.get("warnings", []) as Array).size() == 1 and not h.has_warn(rs, "argument"), "same-file boundary silent, use warns")
	var narrow := "extends RefCounted\n# @var x Node nullable\nvar x: Node\nfunc g(v: Variant) -> void:\n\tif v is TmpNullP3Lib:\n\t\tv.plain(x)\n"
	var rn: Dictionary = h.analyze_text(narrow, "res://tests/tmp_nb_b8.gd", "distrust")
	h.check((rn.get("warnings", []) as Array).size() == 1 and h.has_warn(rn, "argument"), "narrowed boundary warns once (receiver proven by is)")
	var dlib := "# @nullable_policy distrust\nclass_name TmpNullP3LibD\nextends RefCounted\nfunc plain(a: Node) -> void:\n\ta.queue_free()\n"
	var rlib: Dictionary = h.analyze_text(dlib, "res://tests/tmp_null_p3libd.gd")
	h.check((rlib.get("warnings", []) as Array).size() == 1, "distrust callee warns at use")
	var dcon := "extends RefCounted\n# @var x Node nullable\nvar x: Node\nfunc g() -> void:\n\tTmpNullP3LibD.plain(x)\n"
	h.check(h.warn_texts(h.analyze_text(dcon, "res://tests/tmp_nb_b9.gd", "distrust")).is_empty(), "distrust callee boundary silent")
	var stale := "{\"name\": \"TmpNullP3Stale\", \"kind\": \"script\", \"class_name\": \"TmpNullP3Stale\", \"instance_methods\": [{\"name\": \"old\", \"param_names\": [\"p\"], \"notnull_params\": [], \"nullable_params\": []}]}"
	var f := FileAccess.open("res://.godot/0GnumarusGodotProjectAnalyzerSuiteData/user/TmpNullP3Stale.json", FileAccess.WRITE)
	(f as FileAccess).store_string(stale)
	(f as FileAccess).close()
	var sold := "extends RefCounted\n# @var x Node nullable\nvar x: Node\nfunc g() -> void:\n\tTmpNullP3Stale.old(x)\n"
	h.check(h.warn_texts(h.analyze_text(sold, "res://tests/tmp_nb_b10.gd", "distrust")).is_empty(), "stale json silent")


func _nb_istest(h) -> void:
	var branch := "extends RefCounted\nfunc f(v: Variant) -> void:\n\tif v is Node:\n\t\tv.queue_free()\n"
	h.check(h.warn_texts(h.analyze_text(branch, "res://tests/tmp_nb_i1.gd", "distrust")).is_empty(), "is branch holds non-null")
	var els := "extends RefCounted\nfunc f(v: Variant) -> void:\n\tif v is Node:\n\t\tpass\n\telse:\n\t\tv = Node.new()\n"
	h.check(_clean(h.analyze_text(els, "res://tests/tmp_nb_i2.gd", "distrust")), "is else clean")
	var variant := "extends RefCounted\nfunc f(v: Variant) -> void:\n\tif v is Variant:\n\t\tv.foo()\n"
	var rv: Dictionary = h.analyze_text(variant, "res://tests/tmp_nb_i3.gd", "distrust")
	h.check(_has_err(rv, "missing_method", "'foo()'"), "is Variant proves nothing")
	var isnot := "extends RefCounted\nfunc f(n: Node) -> void:\n\tif n is not Node:\n\t\treturn\n\tn.queue_free()\n"
	h.check(h.warn_texts(h.analyze_text(isnot, "res://tests/tmp_nb_i4.gd", "distrust")).is_empty(), "is-not clause narrows")
	var wrong_side := "extends RefCounted\nfunc f(n: Node) -> void:\n\tif n is Node:\n\t\treturn\n\tn.queue_free()\n"
	h.check(h.has_warn(h.analyze_text(wrong_side, "res://tests/tmp_nb_i5.gd", "distrust"), "implicitly nullable"), "holding side returning still warns")
	var inst := "extends RefCounted\nfunc f(v: Variant) -> void:\n\tif is_instance_of(v, Node):\n\t\tv.queue_free()\n"
	h.check(h.warn_texts(h.analyze_text(inst, "res://tests/tmp_nb_i6.gd", "distrust")).is_empty(), "is_instance_of branch holds non-null")
	var typ := "extends RefCounted\nfunc f(v: Variant) -> void:\n\tif typeof(v) == TYPE_NODE:\n\t\tv.queue_free()\n"
	h.check(h.warn_texts(h.analyze_text(typ, "res://tests/tmp_nb_i7.gd", "distrust")).is_empty(), "typeof branch holds non-null")
	var trust_is := "extends RefCounted\nfunc f(v: Variant) -> void:\n\tif v is Node:\n\t\tv.queue_free()\n"
	h.check(_clean(h.analyze_text(trust_is, "res://tests/tmp_nb_i8.gd")), "is branch clean in trust too")


func _nb_frontier(h) -> void:
	var sup := "extends RefCounted\nclass BaseP:\n\t# @param x Node notnull\n\tfunc m(x: Node) -> void:\n\t\tpass\nclass KidP extends BaseP:\n\t# @var w Node nullable\n\tvar w: Node\n\tfunc f() -> void:\n\t\tsuper.m(w)\n"
	var rs: Dictionary = h.analyze_text(sup, "res://tests/tmp_nb_g1.gd", "distrust")
	h.check(_clean(rs) and h.has_warn(rs, "possible null argument 'w' for notnull parameter 'x'"), "super notnull-maybe warns")
	h.check(_warn_kinds(rs) == ["maybe_null"], "super warn kind maybe_null")
	var sup_trust := "extends RefCounted\nclass BaseQ:\n\t# @param x Node notnull\n\tfunc m(x: Node) -> void:\n\t\tpass\nclass KidQ extends BaseQ:\n\t# @var w Node nullable\n\tvar w: Node\n\tfunc f() -> void:\n\t\tsuper.m(w)\n"
	h.check(h.warn_texts(h.analyze_text(sup_trust, "res://tests/tmp_nb_g2.gd")).is_empty(), "super silent in trust")
	var sup_lit := "extends RefCounted\nclass BaseR:\n\t# @param x Node notnull\n\tfunc m(x: Node) -> void:\n\t\tpass\nclass KidR extends BaseR:\n\tfunc f() -> void:\n\t\tsuper.m(null)\n"
	h.check(_has_err(h.analyze_text(sup_lit, "res://tests/tmp_nb_g3.gd", "distrust"), "param_notnull", "'x'"), "super literal still errors")
	var callres := "extends RefCounted\n# @return Node nullable\nfunc make() -> Node:\n\treturn Node.new()\n# @param x Node notnull\nfunc need(x: Node) -> void:\n\tpass\nfunc g() -> void:\n\tneed(make())\n"
	var rc: Dictionary = h.analyze_text(callres, "res://tests/tmp_nb_g4.gd", "distrust")
	h.check(_clean(rc) and h.has_warn(rc, "possible null argument 'make()' for notnull parameter 'x'"), "call-result to notnull warns")
	var callres_trust := "extends RefCounted\n# @return Node nullable\nfunc make() -> Node:\n\treturn Node.new()\n# @param x Node notnull\nfunc need(x: Node) -> void:\n\tpass\nfunc g() -> void:\n\tneed(make())\n"
	h.check(h.warn_texts(h.analyze_text(callres_trust, "res://tests/tmp_nb_g5.gd")).is_empty(), "call-result silent in trust")
	var selfres := "extends RefCounted\n# @return Node nullable\nfunc make() -> Node:\n\treturn Node.new()\n# @param x Node notnull\nfunc need(x: Node) -> void:\n\tpass\nfunc g() -> void:\n\tneed(self.make())\n"
	h.check(h.has_warn(h.analyze_text(selfres, "res://tests/tmp_nb_g6.gd", "distrust"), "'self.make()'"), "self call-result warns")
	var plainres := "extends RefCounted\nfunc make() -> Node:\n\treturn Node.new()\n# @param x Node notnull\nfunc need(x: Node) -> void:\n\tpass\nfunc g() -> void:\n\tneed(make())\n"
	h.check(h.warn_texts(h.analyze_text(plainres, "res://tests/tmp_nb_g7.gd", "distrust")).is_empty(), "plain call-result silent")
	var xcallres := "extends RefCounted\n# @return Node nullable\nfunc make() -> Node:\n\treturn Node.new()\nfunc g() -> void:\n\tTmpNullP3Lib.plain(make())\n"
	h.check(h.has_warn(h.analyze_text(xcallres, "res://tests/tmp_nb_g8.gd", "distrust"), "possible null argument 'make()'"), "cross call-result warns")


func _nb_taintx(h) -> void:
	var inst := "extends RefCounted\nclass TBox:\n\t# @return Node nullable\n\tfunc make() -> Node:\n\t\treturn null\nfunc g(b: TBox) -> void:\n\tvar r = b.make()\n\tr.queue_free()\n"
	var ri: Dictionary = h.analyze_text(inst, "res://tests/tmp_nb_x01.gd", "distrust")
	h.check(_clean(ri) and h.has_warn(ri, "(nullable 'Node')"), "member instance taint warns")
	var stat := "extends RefCounted\nclass SBox:\n\t# @return Node nullable\n\tstatic func make() -> Node:\n\t\treturn null\nfunc g() -> void:\n\tvar r = SBox.make()\n\tr.queue_free()\n"
	h.check(h.has_warn(h.analyze_text(stat, "res://tests/tmp_nb_x02.gd", "distrust"), "(nullable 'Node')"), "static taint warns")
	var plain := "extends RefCounted\nclass PBox:\n\tfunc make() -> Node:\n\t\treturn Node.new()\nfunc g(b: PBox) -> void:\n\tif b is PBox:\n\t\tvar r = b.make()\n\t\tr.queue_free()\n"
	h.check(h.warn_texts(h.analyze_text(plain, "res://tests/tmp_nb_x03.gd", "distrust")).is_empty(), "plain member clean")
	var sup := "extends RefCounted\nclass Base:\n\t# @return Node nullable\n\tfunc make() -> Node:\n\t\treturn null\nclass Kid extends Base:\n\tfunc f() -> void:\n\t\tvar r = super.make()\n\t\tr.queue_free()\n"
	h.check(h.has_warn(h.analyze_text(sup, "res://tests/tmp_nb_x04.gd", "distrust"), "(nullable 'Node')"), "super taint warns")
	var lamb := "extends RefCounted\nfunc g() -> void:\n\t# @return Node nullable\n\tvar cb = func() -> Node:\n\t\treturn null\n\tvar r = cb.call()\n\tr.queue_free()\n"
	h.check(h.has_warn(h.analyze_text(lamb, "res://tests/tmp_nb_x05.gd", "distrust"), "(nullable 'Node')"), "lambda call taint warns")
	var lamb_plain := "extends RefCounted\nfunc g() -> void:\n\tvar cb = func() -> Node:\n\t\treturn Node.new()\n\tvar r = cb.call()\n\tif r is Node:\n\t\tr.queue_free()\n"
	h.check(h.warn_texts(h.analyze_text(lamb_plain, "res://tests/tmp_nb_x06.gd", "distrust")).is_empty(), "plain lambda clean")
	var lib := "class_name TmpNullXRet\nextends RefCounted\n# @return Node nullable\nstatic func smake() -> Node:\n\treturn null\n# @return Node nullable\nfunc imake() -> Node:\n\treturn null\nfunc plain() -> Node:\n\treturn Node.new()\n"
	h.analyze_text(lib, "res://tests/tmp_null_xret.gd")
	var info: Dictionary = h.load_json("res://.godot/0GnumarusGodotProjectAnalyzerSuiteData/user/TmpNullXRet.json")
	var smake_entry := {}
	for list_key in ["instance_methods", "static_methods"]:
		for m in info.get(list_key, []):
			if str((m as Dictionary).get("name", "")) == "smake":
				smake_entry = m
	h.check((smake_entry as Dictionary).get("return_types", []) == ["Node"], "json return heads")
	h.check(bool((smake_entry as Dictionary).get("nullable_return", false)), "json nullable return flag")
	var xs := "extends RefCounted\nfunc g() -> void:\n\tvar r = TmpNullXRet.smake()\n\tr.queue_free()\n"
	h.check(h.has_warn(h.analyze_text(xs, "res://tests/tmp_nb_x07.gd", "distrust"), "(nullable 'Node')"), "cross static taint warns")
	var xi := "extends RefCounted\nfunc g(b: TmpNullXRet) -> void:\n\tif b is TmpNullXRet:\n\t\tvar r = b.imake()\n\t\tr.queue_free()\n"
	h.check(h.has_warn(h.analyze_text(xi, "res://tests/tmp_nb_x08.gd", "distrust"), "(nullable 'Node')"), "cross instance taint warns")
	var xp := "extends RefCounted\nfunc g(b: TmpNullXRet) -> void:\n\tif b is TmpNullXRet:\n\t\tvar r = b.plain()\n\t\tr.queue_free()\n"
	h.check(h.warn_texts(h.analyze_text(xp, "res://tests/tmp_nb_x09.gd", "distrust")).is_empty(), "cross plain clean")
	var xsl := "extends RefCounted\n# @param x Node notnull\nfunc need(x: Node) -> void:\n\tpass\nfunc g() -> void:\n\tneed(TmpNullXRet.smake())\n"
	h.check(h.has_warn(h.analyze_text(xsl, "res://tests/tmp_nb_x10.gd", "distrust"), "possible null argument 'TmpNullXRet.smake()'"), "cross static slice warns")
	var trust := "extends RefCounted\nclass TBox2:\n\t# @return Node nullable\n\tfunc make() -> Node:\n\t\treturn null\nfunc g(b: TBox2) -> void:\n\tif b is TBox2:\n\t\tvar r = b.make()\n\t\tr.queue_free()\n"
	h.check(h.has_warn(h.analyze_text(trust, "res://tests/tmp_nb_x11.gd"), "(nullable 'Node')"), "member taint warns in trust too")


func _nb_elif(h) -> void:
	var holds := "extends RefCounted\nfunc f(n: Node) -> void:\n\tif n == null:\n\t\tpass\n\telif n != null:\n\t\tn.queue_free()\n"
	h.check(h.warn_texts(h.analyze_text(holds, "res://tests/tmp_nb_e01.gd", "distrust")).is_empty(), "elif holds narrows")
	var chain := "extends RefCounted\nfunc f(n: Node) -> void:\n\tif n == null:\n\t\tpass\n\telif n == null:\n\t\tpass\n\telse:\n\t\tn.queue_free()\n"
	h.check(h.warn_texts(h.analyze_text(chain, "res://tests/tmp_nb_e02.gd", "distrust")).is_empty(), "elif chain else narrows")
	var miss := "extends RefCounted\nfunc f(n: Node, c: bool, d: bool) -> void:\n\tif c:\n\t\tpass\n\telif d:\n\t\tn.queue_free()\n"
	h.check(h.has_warn(h.analyze_text(miss, "res://tests/tmp_nb_e03.gd", "distrust"), "implicitly nullable"), "unrelated elif still warns")
	var err := "extends RefCounted\nfunc f(n: Node, c: bool) -> void:\n\tif c:\n\t\tpass\n\telif n == null:\n\t\tn.queue_free()\n"
	h.check(_has_err(h.analyze_text(err, "res://tests/tmp_nb_e04.gd", "distrust"), "null_access", "on null"), "elif null branch errors")
	var ischain := "extends RefCounted\nfunc f(v: Variant) -> void:\n\tif v is Node:\n\t\tpass\n\telif v is Control:\n\t\tv.queue_free()\n"
	var rc: Dictionary = h.analyze_text(ischain, "res://tests/tmp_nb_e05.gd", "distrust")
	h.check(_clean(rc) and (rc.get("warnings", []) as Array).is_empty(), "elif is holds non-null")
	var allret := "extends RefCounted\nfunc f(n: Node, c: bool) -> void:\n\tif n != null:\n\t\tpass\n\telif c:\n\t\treturn\n\telse:\n\t\treturn\n\tn.queue_free()\n"
	h.check(h.warn_texts(h.analyze_text(allret, "res://tests/tmp_nb_e06.gd", "distrust")).is_empty(), "all-return elif chain marks")
	var fall := "extends RefCounted\nfunc f(n: Node, c: bool) -> void:\n\tif n != null:\n\t\tpass\n\telif c:\n\t\tpass\n\telse:\n\t\treturn\n\tn.queue_free()\n"
	h.check(h.has_warn(h.analyze_text(fall, "res://tests/tmp_nb_e07.gd", "distrust"), "implicitly nullable"), "falling elif keeps warning")
	var ectrue := "extends RefCounted\nfunc f(n: Node, c: bool) -> void:\n\tif n == null:\n\t\treturn\n\telif c:\n\t\tpass\n\tn.queue_free()\n"
	h.check(h.warn_texts(h.analyze_text(ectrue, "res://tests/tmp_nb_e08.gd", "distrust")).is_empty(), "eq-true chain marks despite elif")


func _nb_strict(h) -> void:
	var ana0 = H.Analyzer.new()
	h.check(not bool(ana0.strict_untyped), "strict default off")
	var local := "extends RefCounted\nfunc g() -> void:\n\tvar u\n\tu.foo()\n"
	var rs: Dictionary = h.analyze_text(local, "res://tests/tmp_nb_s01.gd", "distrust", true)
	h.check(_clean(rs) and h.has_warn(rs, "(untyped 'u')"), "strict local warns")
	h.check(_warn_kinds(rs) == ["maybe_null"], "strict warn kind maybe_null")
	h.check(h.warn_texts(h.analyze_text(local, "res://tests/tmp_nb_s02.gd", "distrust")).is_empty(), "strict off silent")
	h.check(h.warn_texts(h.analyze_text(local, "res://tests/tmp_nb_s03.gd")).is_empty(), "strict inert in trust")
	var param := "extends RefCounted\nfunc g(p) -> void:\n\tp.foo()\n"
	h.check(h.has_warn(h.analyze_text(param, "res://tests/tmp_nb_s04.gd", "distrust", true), "(untyped 'p')"), "strict param warns")
	var lit := "extends RefCounted\nfunc g() -> void:\n\tvar u = 1\n\tu.foo()\n"
	h.check(h.warn_texts(h.analyze_text(lit, "res://tests/tmp_nb_s05.gd", "distrust", true)).is_empty(), "proven literal silent")
	var guarded := "extends RefCounted\nfunc g(p) -> void:\n\tif p != null:\n\t\tp.foo()\n"
	h.check(h.warn_texts(h.analyze_text(guarded, "res://tests/tmp_nb_s06.gd", "distrust", true)).is_empty(), "guarded untyped silent")
	var member := "extends RefCounted\nvar x\nfunc g() -> void:\n\tx.foo()\n"
	h.check(h.has_warn(h.analyze_text(member, "res://tests/tmp_nb_s07.gd", "distrust", true), "(untyped 'x')"), "strict member warns")
	var unknown := "extends RefCounted\nfunc g() -> void:\n\tnosuchvar_xyz.foo()\n"
	h.check(h.warn_texts(h.analyze_text(unknown, "res://tests/tmp_nb_s08.gd", "distrust", true)).is_empty(), "unknown name silent")
	var bare := "extends RefCounted\nfunc g(p) -> void:\n\tprint(p)\n"
	h.check(h.warn_texts(h.analyze_text(bare, "res://tests/tmp_nb_s09.gd", "distrust", true)).is_empty(), "bare use legal")
	var read := "extends RefCounted\nfunc g(p) -> void:\n\tprint(p.bar)\n"
	h.check(h.has_warn(h.analyze_text(read, "res://tests/tmp_nb_s10.gd", "distrust", true), "possible null read 'bar'"), "strict read warns")
	var ismark := "extends RefCounted\nfunc g(p) -> void:\n\tif p is Node:\n\t\tp.queue_free()\n"
	h.check(h.warn_texts(h.analyze_text(ismark, "res://tests/tmp_nb_s11.gd", "distrust", true)).is_empty(), "is-narrowed silent")
	var barg := "extends RefCounted\nfunc g(p) -> void:\n\tTmpNullP3Lib.plain(p)\n"
	var rb: Dictionary = h.analyze_text(barg, "res://tests/tmp_nb_s12.gd", "distrust", true)
	h.check(_clean(rb) and h.has_warn(rb, "possible null argument 'p'") and h.has_warn(rb, "(untyped)"), "strict cross implicit warns")
	h.check(h.warn_texts(h.analyze_text(barg, "res://tests/tmp_nb_s13.gd", "distrust")).is_empty(), "nonstrict cross silent")
	var nbarg := "extends RefCounted\n# @param x Node notnull\nfunc need(x: Node) -> void:\n\tpass\nfunc g(p) -> void:\n\tneed(p)\n"
	h.check(h.has_warn(h.analyze_text(nbarg, "res://tests/tmp_nb_s14.gd", "distrust", true), "for notnull parameter 'x' of 'need()' (untyped)"), "strict notnull arg warns")
	var gbarg := "extends RefCounted\n# @param x Node notnull\nfunc need(x: Node) -> void:\n\tpass\nfunc g(p) -> void:\n\tif p != null:\n\t\tneed(p)\n"
	h.check(h.warn_texts(h.analyze_text(gbarg, "res://tests/tmp_nb_s15.gd", "distrust", true)).is_empty(), "guarded arg silent")
	ProjectSettings.set_setting("gnumarus_analyzer/nullable_policy", "distrust")
	ProjectSettings.set_setting("gnumarus_analyzer/strict_untyped", true)
	h.check(h.has_warn(h.analyze_text(local, "res://tests/tmp_nb_s16.gd"), "(untyped 'u')"), "strict setting warns")
	ProjectSettings.set_setting("gnumarus_analyzer/strict_untyped", false)
	h.check(h.warn_texts(h.analyze_text(local, "res://tests/tmp_nb_s17.gd")).is_empty(), "strict setting off silent")
	ProjectSettings.set_setting("gnumarus_analyzer/nullable_policy", "trust")
	var tag := "# @nullable_policy distrust\n# @strict_untyped\nextends RefCounted\nfunc g(p) -> void:\n\tp.foo()\n"
	h.check(h.has_warn(h.analyze_text(tag, "res://tests/tmp_nb_s18.gd"), "(untyped 'p')"), "strict tag warns")
	var tagoff := "# @strict_untyped off\nextends RefCounted\nfunc g(p) -> void:\n\tp.foo()\n"
	h.check(h.warn_texts(h.analyze_text(tagoff, "res://tests/tmp_nb_s19.gd", "distrust", true)).is_empty(), "strict tag off beats property")
	var tagbad := "# @strict_untyped sometimes\nextends RefCounted\n"
	h.check(_has_err(h.analyze_text(tagbad, "res://tests/tmp_nb_s20.gd"), "policy_malformed", "'on' or 'off'"), "bad strict value malformed")
	var tagmis := "extends RefCounted\nfunc g(p) -> void:\n\t# @strict_untyped\n\tp.foo()\n"
	h.check(_has_err(h.analyze_text(tagmis, "res://tests/tmp_nb_s21.gd"), "policy_misplaced", "first comment block"), "strict tag misplaced")


func _nb_reassign(h) -> void:
	var renull := "extends RefCounted\n# @var x Node|null\nvar x: Node\nfunc g() -> void:\n\tx = null\n\tx.queue_free()\n"
	var rr: Dictionary = h.analyze_text(renull, "res://tests/tmp_nb_w01.gd", "distrust")
	h.check(_has_err(rr, "null_access", "on null"), "reassigned null errors on use")
	var trust := "extends RefCounted\n# @var x Node|null\nvar x: Node\nfunc g() -> void:\n\tx = null\n\tx.queue_free()\n"
	h.check(_has_err(h.analyze_text(trust, "res://tests/tmp_nb_w02.gd"), "null_access", "on null"), "reassign invalidation policy-free")
	var reseat := "extends RefCounted\n# @var x Node|null\nvar x: Node\nfunc g() -> void:\n\tx = null\n\tx = Node.new()\n\tx.queue_free()\n"
	var rs: Dictionary = h.analyze_text(reseat, "res://tests/tmp_nb_w03.gd", "distrust")
	h.check(_clean(rs) and (rs.get("warnings", []) as Array).is_empty(), "reseat clears exact null")
	var initonly := "extends RefCounted\nvar x: Node = null\nfunc g() -> void:\n\tx = null\n\tx.queue_free()\n"
	h.check(_has_err(h.analyze_text(initonly, "res://tests/tmp_nb_w04.gd"), "null_access", "on null"), "reassign triggers past init leniency")
	var stale := "extends RefCounted\nfunc g(n: Node, y: Variant) -> void:\n\tif n != null:\n\t\tn = y\n\t\tn.queue_free()\n"
	h.check(h.has_warn(h.analyze_text(stale, "res://tests/tmp_nb_w05.gd", "distrust"), "implicitly nullable"), "unknown write clears guard")
	var staleclean := "extends RefCounted\nvar x: Node\nfunc g(y: Variant) -> void:\n\tif x != null:\n\t\tx = y\n\t\tx = null\n"
	h.check(_clean(h.analyze_text(staleclean, "res://tests/tmp_nb_w06.gd")), "cleared mark accepts null")
	var litmark := "extends RefCounted\nfunc g() -> void:\n\tvar u = 1\n\tu.foo()\n"
	h.check(_clean(h.analyze_text(litmark, "res://tests/tmp_nb_w07.gd", "distrust", true)), "literal write proves non-null")
	var litnull := "extends RefCounted\nfunc g() -> void:\n\tvar u = 1\n\tu = null\n"
	h.check(_has_err(h.analyze_text(litnull, "res://tests/tmp_nb_w08.gd", "distrust"), "var_notnull", "'u'"), "null after literal errors in distrust")
	h.check(_clean(h.analyze_text(litnull, "res://tests/tmp_nb_w08b.gd")), "null after literal silent in trust")
	var member := "extends RefCounted\nvar x: Node\nfunc g() -> void:\n\tself.x = null\n\tself.x.queue_free()\n"
	h.check(_clean(h.analyze_text(member, "res://tests/tmp_nb_w09.gd", "distrust")), "member reassign silent (gap)")
	var cascade := "extends RefCounted\n# @var x Node notnull\nvar x: Node\nfunc g() -> void:\n\tx = null\n\tx.queue_free()\n"
	var rc: Dictionary = h.analyze_text(cascade, "res://tests/tmp_nb_w10.gd")
	h.check(_has_err(rc, "var_notnull", "'x'") and _has_err(rc, "null_access", "on null"), "notnull cascade reports both")
	var proven := "extends RefCounted\nfunc g(p) -> void:\n\tp = null\n\tp.foo()\n"
	h.check(_has_err(h.analyze_text(proven, "res://tests/tmp_nb_w11.gd", "distrust", true), "null_access", "on null"), "proven null beats strict warn")


func _nb_bind(h) -> void:
	var sub := "extends RefCounted\nfunc g(p) -> void:\n\tprint(p[0])\n"
	var rs: Dictionary = h.analyze_text(sub, "res://tests/tmp_nb_q01.gd", "distrust", true)
	h.check(_clean(rs) and h.has_warn(rs, "possible null read '[]' on 'p' (untyped 'p')"), "strict subscript warns")
	h.check(_warn_kinds(rs) == ["maybe_null"], "subscript warn kind maybe_null")
	h.check(h.warn_texts(h.analyze_text(sub, "res://tests/tmp_nb_q02.gd", "distrust")).is_empty(), "subscript nonstrict silent")
	var guarded := "extends RefCounted\nfunc g(p) -> void:\n\tif p != null:\n\t\tprint(p[0])\n"
	h.check(h.warn_texts(h.analyze_text(guarded, "res://tests/tmp_nb_q03.gd", "distrust", true)).is_empty(), "guarded subscript silent")
	var taint := "extends RefCounted\n# @return Node nullable\nfunc make() -> Node:\n\treturn null\nfunc g() -> void:\n\tfor x in make():\n\t\tx.queue_free()\n"
	h.check(h.has_warn(h.analyze_text(taint, "res://tests/tmp_nb_q04.gd", "distrust"), "(nullable 'Node')"), "for taint warns")
	var dyn := "extends RefCounted\nfunc g(items: Array) -> void:\n\tfor x in items:\n\t\tx.foo()\n"
	h.check(h.has_warn(h.analyze_text(dyn, "res://tests/tmp_nb_q05.gd", "distrust", true), "(untyped 'x')"), "loop dynamic warns")
	h.check(h.warn_texts(h.analyze_text(dyn, "res://tests/tmp_nb_q06.gd", "distrust")).is_empty(), "loop dynamic nonstrict silent")
	var bind := "extends RefCounted\nfunc g(d: Dictionary) -> void:\n\tmatch d:\n\t\t{\"a\": var v}:\n\t\t\tv.foo()\n"
	h.check(h.has_warn(h.analyze_text(bind, "res://tests/tmp_nb_q07.gd", "distrust", true), "(untyped 'v')"), "match bind warns")
	h.check(h.warn_texts(h.analyze_text(bind, "res://tests/tmp_nb_q08.gd", "distrust")).is_empty(), "match bind nonstrict silent")
