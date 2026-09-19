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
	h.check(_clean(rr) and (rr.get("warnings", []) as Array).is_empty(), "boundary notnull-maybe silent (gap)")
	var samefile := "extends RefCounted\nfunc take(a: Node) -> void:\n\ta.queue_free()\n# @var x Node nullable\nvar x: Node\nfunc g() -> void:\n\ttake(x)\n"
	var rs: Dictionary = h.analyze_text(samefile, "res://tests/tmp_nb_b7.gd", "distrust")
	h.check((rs.get("warnings", []) as Array).size() == 1 and not h.has_warn(rs, "argument"), "same-file boundary silent, use warns")
	var narrow := "extends RefCounted\n# @var x Node nullable\nvar x: Node\nfunc g(v: Variant) -> void:\n\tif v is TmpNullP3Lib:\n\t\tv.plain(x)\n"
	var rn: Dictionary = h.analyze_text(narrow, "res://tests/tmp_nb_b8.gd", "distrust")
	h.check((rn.get("warnings", []) as Array).size() == 2 and h.has_warn(rn, "argument"), "narrowed boundary warns once")
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
