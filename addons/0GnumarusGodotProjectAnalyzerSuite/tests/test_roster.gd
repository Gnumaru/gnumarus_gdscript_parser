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
