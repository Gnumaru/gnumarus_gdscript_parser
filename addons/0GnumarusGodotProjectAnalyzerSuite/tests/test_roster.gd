extends RefCounted

## roster suite: global class roster (engine cache + file scan) and
## on-demand dependency analysis. Roster-known but never-analyzed
## classes resolve as opaque (names accepted, compat lenient,
## member checks silent); member data arrives via bounded on-demand
## analysis with a shared cycle guard. Fixture files
## (TmpRosterTarget/Mid/CycleA/CycleB) are real committed scripts the
## suite never analyzes directly — except through on-demand.

const H = preload("res://addons/0GnumarusGodotProjectAnalyzerSuite/tests/helpers.gd")

const USER_DIR := "res://.godot/0GnumarusGodotProjectAnalyzerSuiteData/user/"
const TARGET_PATH := "res://addons/0GnumarusGodotProjectAnalyzerSuite/tests/TmpRosterTarget.gd"
const MID_PATH := "res://addons/0GnumarusGodotProjectAnalyzerSuite/tests/TmpRosterMid.gd"
const CYCLE_A_PATH := "res://addons/0GnumarusGodotProjectAnalyzerSuite/tests/TmpRosterCycleA.gd"
const CYCLE_B_PATH := "res://addons/0GnumarusGodotProjectAnalyzerSuite/tests/TmpRosterCycleB.gd"


func run() -> Dictionary:
	var h = H.new()
	h.suite = "roster"
	_r_names(h)
	_r_demand(h)
	_r_cycle(h)
	_r_depth(h)
	_r_inherit(h)
	_r_refs(h)
	_r_inner(h)
	_r_quoted(h)
	_r_dotted(h)
	_r_super(h)
	return h.result()


func _drop_json(stem: String) -> void:
	var p := USER_DIR + stem + ".json"
	if FileAccess.file_exists(p):
		DirAccess.remove_absolute(p)


func _has_json(stem: String) -> bool:
	return FileAccess.file_exists(USER_DIR + stem + ".json")


func _analyze_file(path: String, policy := "") -> Dictionary:
	return H.new().analyze_text(FileAccess.get_file_as_string(path), path, policy)


func _sig(res: Dictionary) -> Array:
	var out: Array = []
	for e in res.get("errors", []):
		out.append("E:" + str((e as Dictionary).get("kind", "")) + ":" + str((e as Dictionary).get("message", "")))
	for w in res.get("warnings", []):
		out.append("W:" + str((w as Dictionary).get("kind", "")) + ":" + str((w as Dictionary).get("message", "")))
	out.sort()
	return out


func _has_err(res: Dictionary, kind: String, part: String) -> bool:
	for e in res.get("errors", []):
		if str((e as Dictionary).get("kind", "")) == kind and part in str((e as Dictionary).get("message", "")):
			return true
	return false


func _clean(res: Dictionary) -> bool:
	return (res.get("errors", []) as Array).is_empty()


func _r_names(h) -> void:
	_drop_json("TmpRosterTarget")
	var acc := "extends RefCounted\n# @var x TmpRosterTarget\nvar x: Variant\n"
	h.check(not ("var_unknown_type" in _sig(h.analyze_text(acc, "res://tests/tmp_rs_n1.gd"))), "roster name accepted cold")
	var typo := "extends RefCounted\n# @var x TmpRosterTarge\nvar x: Variant\n"
	h.check(_has_err(h.analyze_text(typo, "res://tests/tmp_rs_n2.gd"), "var_unknown_type", "TmpRosterTarge"), "typo still unknown")
	var watch := "extends RefCounted\n# @var x TmpRosterTarget nullable\nvar x: Variant\n"
	h.check(_clean(h.analyze_text(watch, "res://tests/tmp_rs_n4.gd")), "nullable opaque clean")
	h.check(not _has_json("TmpRosterTarget"), "names need no analysis")
	var narrow := "extends RefCounted\n# @var x TmpRosterTarget\nvar x: RefCounted\n"
	h.check(_clean(h.analyze_text(narrow, "res://tests/tmp_rs_n3.gd")), "proven derives silent")
	var cold := "extends RefCounted\nfunc g() -> void:\n\tTmpRosterTarget.take(Node.new())\n"
	var rc: Dictionary = h.analyze_text(cold, "res://tests/tmp_rs_n5.gd")
	h.check(_clean(rc) and (rc.get("warnings", []) as Array).is_empty(), "cold static clean")
	_drop_json("TmpRosterTarget")
	var first := "extends RefCounted\nfunc g(t: TmpRosterTarget) -> void:\n\tt.plain(Node.new())\n"
	var rf: Dictionary = h.analyze_text(first, "res://tests/tmp_rs_n6.gd", "distrust")
	h.check(_clean(rf) and h.has_warn(rf, "(implicitly nullable 'TmpRosterTarget')"), "first touch warns like later ones")


func _r_demand(h) -> void:
	_drop_json("TmpRosterTarget")
	_drop_json("TmpRosterMid")
	var caller := "extends RefCounted\nfunc g() -> void:\n\tTmpRosterTarget.take(null)\n"
	var cold: Dictionary = h.analyze_text(caller, "res://tests/tmp_rs_d1.gd")
	h.check(_has_err(cold, "param_notnull", "'m'"), "on-demand literal errors")
	h.check(_has_json("TmpRosterTarget"), "on-demand writes dep json")
	var info: Dictionary = h.load_json(USER_DIR + "TmpRosterTarget.json")
	var names: Array = []
	for m in info.get("instance_methods", []):
		names.append(str((m as Dictionary).get("name", "")))
	h.check("take" in names and "plain" in names and "hook" in names, "dep json complete")
	var warm: Dictionary = h.analyze_text(caller, "res://tests/tmp_rs_d2.gd")
	h.check(_sig(warm) == _sig(cold), "warm matches cold")
	var mid_caller := "extends RefCounted\nfunc g(m: TmpRosterMid) -> void:\n\tif m is TmpRosterMid:\n\t\tvar r = m.fetch(Node.new())\n\t\tr.queue_free()\n"
	var trans: Dictionary = h.analyze_text(mid_caller, "res://tests/tmp_rs_d3.gd", "distrust")
	h.check(h.has_warn(trans, "(nullable 'Node')"), "transitive taint warns")
	h.check(_has_json("TmpRosterMid") and _has_json("TmpRosterTarget"), "cascade writes both")
	var mid_file: Dictionary = _analyze_file(MID_PATH)
	h.check(_clean(mid_file), "mid analyzes clean")


func _r_cycle(h) -> void:
	_drop_json("TmpRosterCycleA")
	_drop_json("TmpRosterCycleB")
	var a_cold: Dictionary = _analyze_file(CYCLE_A_PATH)
	h.check(_has_err(a_cold, "param_notnull", "'m'"), "cycle A errors via B")
	h.check(_has_json("TmpRosterCycleA") and _has_json("TmpRosterCycleB"), "cycle writes both")
	var b_warm: Dictionary = _analyze_file(CYCLE_B_PATH)
	_drop_json("TmpRosterCycleA")
	_drop_json("TmpRosterCycleB")
	var b_seq: Dictionary = _analyze_file(CYCLE_B_PATH)
	var a_seq: Dictionary = _analyze_file(CYCLE_A_PATH)
	h.check(_sig(b_warm) == _sig(b_seq), "cycle B matches sequential")
	h.check(_sig(a_cold) == _sig(a_seq), "cycle A matches sequential")


func _r_depth(h) -> void:
	_drop_json("TmpRosterTarget")
	var caller := "extends RefCounted\nfunc g() -> void:\n\tTmpRosterTarget.take(null)\n"
	for i in range(H.Analyzer.MAX_DEP_DEPTH):
		H.Analyzer._resolve_stack.append("ZZDepthDummy" + str(i))
	var blocked: Dictionary = h.analyze_text(caller, "res://tests/tmp_rs_p1.gd")
	h.check(_clean(blocked), "full stack blocks demand")
	h.check(not _has_json("TmpRosterTarget"), "blocked demand writes nothing")
	H.Analyzer._resolve_stack.clear()
	var freed: Dictionary = h.analyze_text(caller, "res://tests/tmp_rs_p2.gd")
	h.check(_has_err(freed, "param_notnull", "'m'"), "cleared stack analyzes")


func _r_inherit(h) -> void:
	_drop_json("TmpRosterParent")
	_drop_json("TmpRosterChild")
	var compat := "extends RefCounted\n# @var x TmpRosterChild\nvar x: TmpRosterParent\n"
	h.check(_clean(h.analyze_text(compat, "res://tests/tmp_rs_h1.gd")), "cross-file derives silent")
	var refusal := "extends RefCounted\nfunc g() -> void:\n\tTmpRosterChild.take(null)\n"
	h.check(_has_err(h.analyze_text(refusal, "res://tests/tmp_rs_h2.gd"), "param_notnull", "'m'"), "inherited refusal errors")
	var info: Dictionary = h.load_json(USER_DIR + "TmpRosterChild.json")
	h.check(str(info.get("extends", "")) == "TmpRosterParent", "json records extends")
	var priv := "extends RefCounted\nfunc g(v: Variant) -> void:\n\tif v is TmpRosterChild:\n\t\tv.hid()\n"
	var rp: Dictionary = h.analyze_text(priv, "res://tests/tmp_rs_h3.gd")
	h.check(_has_err(rp, "private_use", "TmpRosterParent"), "inherited private names parent")
	var miss := "extends RefCounted\nfunc g() -> void:\n\tTmpRosterChild.nope()\n"
	var rm: Dictionary = h.analyze_text(miss, "res://tests/tmp_rs_h4.gd")
	h.check(_clean(rm) and (rm.get("warnings", []) as Array).is_empty(), "inherited miss silent")


func _r_refs(h) -> void:
	_drop_json("TmpRosterTarget")
	var syn = H.SynParser.new()
	var ana = H.Analyzer.new()
	ana.analyze(syn.parse_text("extends RefCounted\nfunc g() -> void:\n\tTmpRosterTarget.take(null)\n"), "res://tests/tmp_rs_f1.gd")
	h.check((ana._last_refs as Array).has("TmpRosterTarget"), "refs record cross names")
	var ana2 = H.Analyzer.new()
	ana2.analyze(syn.parse_text("extends RefCounted\nfunc g() -> void:\n\tpass\n"), "res://tests/tmp_rs_f2.gd")
	h.check((ana2._last_refs as Array).is_empty(), "refs reset per call")


func _r_inner(h) -> void:
	_drop_json("TmpRosterOuter")
	_drop_json("TmpRosterOuter.Inner")
	var lit := "extends RefCounted\nfunc g(x: TmpRosterOuter.Inner) -> void:\n\tx.take(null)\n"
	h.check(_has_err(h.analyze_text(lit, "res://tests/tmp_rs_k1.gd"), "param_notnull", "'m'"), "dotted inner refusal errors")
	var ok := "extends RefCounted\nfunc g(x: TmpRosterOuter.Inner) -> void:\n\tx.take(Node.new())\n"
	h.check(_clean(h.analyze_text(ok, "res://tests/tmp_rs_k2.gd")), "dotted inner non-null clean")
	var pref := "extends RefCounted\nfunc g(x: TmpRosterOuter.Kid2) -> void:\n\tx.grp(null)\n"
	h.check(_has_err(h.analyze_text(pref, "res://tests/tmp_rs_k3.gd"), "param_notnull", "'m'"), "prefix fallback refusal errors")
	h.check(H.Analyzer._roster_class_for_path("res://addons/0GnumarusGodotProjectAnalyzerSuite/tests/TmpRosterOuter.gd") == "TmpRosterOuter", "reverse prefers top-level")


func _r_quoted(h) -> void:
	_drop_json("TmpRosterParent")
	_drop_json("TmpRosterQuoted")
	var lit := "extends RefCounted\nfunc g() -> void:\n\tTmpRosterQuoted.take(null)\n"
	h.check(_has_err(h.analyze_text(lit, "res://tests/tmp_rs_e1.gd"), "param_notnull", "'m'"), "quoted walk refusal errors")
	h.check(str(H.Analyzer._roster_extends.get("TmpRosterQuoted", "")).begins_with("\"res://"), "roster keeps quoted head")
	var rel: Array = H.Analyzer._parent_candidates("TmpRosterOuter.Kid2", "\"Foo.gd\"")
	h.check(rel == ["res://addons/0GnumarusGodotProjectAnalyzerSuite/tests/Foo.gd"], "relative joins file dir")


func _r_dotted(h) -> void:
	_drop_json("TmpRosterOuter")
	_drop_json("TmpRosterOuter.Inner")
	var ann := "extends RefCounted\n# @var x TmpRosterOuter.Inner\nvar x: Variant\n"
	h.check(_clean(h.analyze_text(ann, "res://tests/tmp_rs_w1.gd")), "dotted var accepted cold")
	var ret := "extends RefCounted\n# @return TmpRosterOuter.Inner\nfunc f():\n\tpass\n"
	h.check(_clean(h.analyze_text(ret, "res://tests/tmp_rs_w2.gd")), "dotted return accepted cold")
	var narrow := "extends RefCounted\nfunc g(v: Variant) -> void:\n\tif v is TmpRosterOuter.Inner:\n\t\tv.take(Node.new())\n"
	h.check(_clean(h.analyze_text(narrow, "res://tests/tmp_rs_w3.gd")), "dotted is narrows clean")
	var lit := "extends RefCounted\nfunc g(v: Variant) -> void:\n\tif v is TmpRosterOuter.Inner:\n\t\tv.take(null)\n"
	h.check(_has_err(h.analyze_text(lit, "res://tests/tmp_rs_w4.gd"), "param_notnull", "'m'"), "dotted is refusal errors")
	var grab := "extends RefCounted\nfunc g(v: Variant) -> void:\n\tif v is Nope VCC:\n\t\tpass\n"
	var rg: Dictionary = h.analyze_text(grab, "res://tests/tmp_rs_w5.gd")
	h.check(_clean(rg) and (rg.get("warnings", []) as Array).is_empty(), "garbage is silent")
	var cplx := "extends RefCounted\n# @var x Array[TmpRosterOuter.Inner]\nvar x: Variant\n"
	h.check(_clean(h.analyze_text(cplx, "res://tests/tmp_rs_w6.gd")), "dotted inside brackets accepted")


func _r_super(h) -> void:
	_drop_json("TmpRosterParent")
	_drop_json("TmpRosterQuoted")
	var lit := "extends TmpRosterParent\nfunc f() -> void:\n\tsuper.take(null)\n"
	h.check(_has_err(h.analyze_text(lit, "res://tests/tmp_rs_u1.gd"), "param_notnull", "'m'"), "super literal errors")
	var imp := "extends TmpRosterParent\n# @var x Node nullable\nvar x: Node\nfunc f() -> void:\n\tsuper.plain(x)\n"
	var ri: Dictionary = h.analyze_text(imp, "res://tests/tmp_rs_u2.gd", "distrust")
	h.check(_clean(ri) and h.has_warn(ri, "possible null argument 'x'"), "super implicit warns")
	h.check(h.warn_texts(h.analyze_text(imp, "res://tests/tmp_rs_u3.gd")).is_empty(), "super implicit trust silent")
	var may := "extends TmpRosterParent\n# @var x Node nullable\nvar x: Node\nfunc f() -> void:\n\tsuper.take(x)\n"
	h.check(h.has_warn(h.analyze_text(may, "res://tests/tmp_rs_u4.gd", "distrust"), "for notnull parameter 'm'"), "super maybe warns")
	var qtrust: Dictionary = _analyze_file("res://addons/0GnumarusGodotProjectAnalyzerSuite/tests/TmpRosterQuoted.gd")
	h.check(_has_err(qtrust, "param_notnull", "'m'"), "quoted super literal errors")
	h.check((qtrust.get("warnings", []) as Array).is_empty(), "quoted super trust silent")
	var qdis: Dictionary = _analyze_file("res://addons/0GnumarusGodotProjectAnalyzerSuite/tests/TmpRosterQuoted.gd", "distrust")
	h.check(h.has_warn(qdis, "possible null argument 'qx'"), "quoted super implicit warns")
