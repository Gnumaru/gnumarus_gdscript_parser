extends RefCounted

## @interface suite: multi/single-line blocks, member forms, static
## rules, defaults/vararg, enums/signals, conflicts, JSON shape.

const Syn = preload("res://addons/0GnumarusGodotProjectAnalyzerSuite/GnumarusGodotProjectAnalyzerSuiteGdscriptSyntaticParser.gd")
const Sem = preload("res://addons/0GnumarusGodotProjectAnalyzerSuite/GnumarusGodotProjectAnalyzerSuiteGdscriptSemanticParser.gd")
const H = preload("res://addons/0GnumarusGodotProjectAnalyzerSuite/tests/helpers.gd")


func run() -> Dictionary:
	var h = H.new()
	h.suite = "interface"
	_i_blocks(h)
	_i_members(h)
	_i_funcs(h)
	_i_signals_enums(h)
	_i_conflicts(h)
	_i_misplaced(h)
	_i_sem(h)
	_i_json(h)
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


func _sem_kinds(src: String, path: String) -> Array:
	var out: Array = []
	var sem = Sem.new()
	var ast: Dictionary = sem.analyze(Syn.new().parse_text(src), path)
	for e in ast.get("semantic_errors", []):
		out.append(str((e as Dictionary).get("kind", "")))
	return out


func _i_blocks(h) -> void:
	var multi := "extends Node\n# @interface MyI\n# static var:myprop:int|bool\n# func:myfunc:void:a:int,b:int|bool;c:String,...rest:String\n# const:myconstA\n# const:myc:float\n# enum:MyEnum:m1,m2\n# signal:mysigA\n# signal:mysigB:x:int\n# @endinterface\n# @var v MyI\nvar v: Variant\n"
	h.check(_clean(h.analyze_text(multi, "res://tests/tmp_if_b1.gd")), "multi-line full clean")
	h.check(_clean(h.analyze_text("extends Node\n# @interface SI var:a:int func:f:void @endinterface\n# @var v SI\nvar v: Variant\n", "res://tests/tmp_if_b2.gd")), "single-line clean")
	h.check(_clean(h.analyze_text("extends Node\n# @interface EI\n# @endinterface\n", "res://tests/tmp_if_b3.gd")), "empty interface clean")
	h.check(_has_err(h.analyze_text("extends Node\n# @interface I\n# var:a:int\nvar v := 1\n", "res://tests/tmp_if_b4.gd"), "interface_malformed", "missing @endinterface"), "missing endinterface errors")
	h.check(_has_err(h.analyze_text("extends Node\n# @interface I\n# var:a:int\n# @endinterface\n# @interface J\n# var:b:int\n# @endinterface\n", "res://tests/tmp_if_b5.gd"), "interface_malformed", "missing @endinterface") == false, "two blocks clean")


func _i_members(h) -> void:
	h.check(_kinds(h.analyze_text("extends Node\n# @interface I\n# bogus:a:int\n# @endinterface\n", "res://tests/tmp_if_m1.gd")).has("interface_malformed"), "bad kind malformed")
	h.check(_kinds(h.analyze_text("extends Node\n# @interface I\n# static const:c:int\n# @endinterface\n", "res://tests/tmp_if_m2.gd")).has("interface_malformed"), "static const malformed")
	h.check(_kinds(h.analyze_text("extends Node\n# @interface I\n# static signal:s\n# @endinterface\n", "res://tests/tmp_if_m3.gd")).has("interface_malformed"), "static signal malformed")
	h.check(_kinds(h.analyze_text("extends Node\n# @interface I\n# var:a:int\n# var:a:int\n# @endinterface\n", "res://tests/tmp_if_m4.gd")).has("interface_malformed"), "duplicate member malformed")
	h.check(_has_err(h.analyze_text("extends Node\n# @interface I\n# var:a:Nope\n# @endinterface\n", "res://tests/tmp_if_m5.gd"), "interface_unknown_type", "'Nope'"), "unknown type errors")
	h.check(_clean(h.analyze_text("extends Node\n# @interface I\n# static var:a:int\n# static func:f:void\n# @endinterface\n", "res://tests/tmp_if_m6.gd")), "static var and func clean")
	h.check(_clean(h.analyze_text("extends Node\n# @interface I\n# const:c\n# var:v:Variant\n# @endinterface\n", "res://tests/tmp_if_m7.gd")), "bare const and Variant clean")


func _i_funcs(h) -> void:
	h.check(_clean(h.analyze_text("extends Node\n# @interface I\n# func:f\n# @endinterface\n", "res://tests/tmp_if_f1.gd")), "bare func any clean")
	h.check(_clean(h.analyze_text("extends Node\n# @interface I\n# func:f:void\n# @endinterface\n", "res://tests/tmp_if_f2.gd")), "void func clean")
	h.check(_kinds(h.analyze_text("extends Node\n# @interface I\n# func:f:\n# @endinterface\n", "res://tests/tmp_if_f3.gd")).has("interface_malformed"), "trailing colon invalid")
	h.check(_clean(h.analyze_text("extends Node\n# @interface I\n# func:f:void:;a:int\n# @endinterface\n", "res://tests/tmp_if_f4.gd")), "defaults-first clean")
	h.check(_kinds(h.analyze_text("extends Node\n# @interface I\n# func:f:void:a:void\n# @endinterface\n", "res://tests/tmp_if_f5.gd")).has("interface_malformed"), "void param malformed")
	h.check(_kinds(h.analyze_text("extends Node\n# @interface I\n# func:f:void:...a:int,b:int\n# @endinterface\n", "res://tests/tmp_if_f6.gd")).has("interface_malformed"), "vararg mid malformed")
	h.check(_kinds(h.analyze_text("extends Node\n# @interface I\n# func:f:void:a:int;;b:int\n# @endinterface\n", "res://tests/tmp_if_f7.gd")).has("interface_malformed"), "double semicolon malformed")
	h.check(_kinds(h.analyze_text("extends Node\n# @interface I\n# func:f:void:a:int,\n# @endinterface\n", "res://tests/tmp_if_f8.gd")).has("interface_malformed"), "trailing comma malformed")


func _i_signals_enums(h) -> void:
	h.check(_clean(h.analyze_text("extends Node\n# @interface I\n# signal:s\n# @endinterface\n", "res://tests/tmp_if_g1.gd")), "bare signal clean")
	h.check(_clean(h.analyze_text("extends Node\n# @interface I\n# signal:s:x:int,y:String\n# @endinterface\n", "res://tests/tmp_if_g2.gd")), "signal params clean")
	h.check(_kinds(h.analyze_text("extends Node\n# @interface I\n# signal:s:a:int;b:int\n# @endinterface\n", "res://tests/tmp_if_g3.gd")).has("interface_malformed"), "signal defaults malformed")
	h.check(_kinds(h.analyze_text("extends Node\n# @interface I\n# signal:s:...a:int\n# @endinterface\n", "res://tests/tmp_if_g4.gd")).has("interface_malformed"), "signal vararg malformed")
	h.check(_clean(h.analyze_text("extends Node\n# @interface I\n# enum:E:m1,m2\n# @endinterface\n", "res://tests/tmp_if_g5.gd")), "enum clean")
	h.check(_kinds(h.analyze_text("extends Node\n# @interface I\n# enum:E\n# @endinterface\n", "res://tests/tmp_if_g6.gd")).has("interface_malformed"), "empty enum malformed")


func _i_conflicts(h) -> void:
	h.check(_has_err(h.analyze_text("extends Node\n# @interface I\n# var:a:int\n# @endinterface\n# @interface I\n# var:b:int\n# @endinterface\n", "res://tests/tmp_if_c1.gd"), "interface_conflict", "more than once"), "duplicate conflicts")
	h.check(_has_err(h.analyze_text("extends Node\n# @interface Item\n# var:a:int\n# @endinterface\nclass Item:\n\tpass\n", "res://tests/tmp_if_c2.gd"), "interface_conflict", "script member"), "class conflict")
	h.check(_has_err(h.analyze_text("extends Node\n# @interface Node\n# var:a:int\n# @endinterface\n", "res://tests/tmp_if_c3.gd"), "interface_conflict", "existing type"), "builtin conflict")


func _i_misplaced(h) -> void:
	h.check(_kinds(h.analyze_text("extends Node\nfunc f():\n\t# @interface I\n\t# var:a:int\n\t# @endinterface\n\tpass\n", "res://tests/tmp_if_p1.gd")).has("interface_misplaced"), "body misplaced")
	h.check(_kinds(h.analyze_text("# @interface I\n# @endinterface\nclass_name Foo\n", "res://tests/tmp_if_p2.gd")).is_empty(), "header definition clean")
	h.check(_kinds(h.analyze_text("extends Node\nclass Inner:\n\t# @interface I\n\t# var:a:int\n\t# @endinterface\n\tvar x := 1\n", "res://tests/tmp_if_p3.gd")).has("interface_misplaced"), "class member leading misplaced")


func _i_sem(h) -> void:
	h.check(_sem_kinds("extends Node\n# @interface I\n# func:f:void\n# @endinterface\nvar v: I\n", "res://tests/tmp_if_s1.gd").is_empty(), "semantic accepts interface vartype")
	h.check(_sem_kinds("extends Node\n# @interface I\n# func:f:void\n# @endinterface\nvar v: I\nvar n: Node = v\nvar w: I = n\n", "res://tests/tmp_if_s2.gd").is_empty(), "semantic lenient both ways")
	h.check(_sem_kinds("extends Node\nvar x: Nope\n", "res://tests/tmp_if_s3.gd").has("unknown_type"), "semantic still rejects unknown")


func _i_json(h) -> void:
	h.analyze_text("extends Node\n# @interface JFace\n# static var:sp:int\n# func:f:String:a:int,...rest:String\n# signal:s:x:int\n# enum:E:m1,m2\n# const:c:float\n# @endinterface\n", "res://tests/tmp_if_j1.gd")
	var info: Dictionary = h.load_json("res://.godot/0GnumarusGodotProjectAnalyzerSuiteData/user/JFace.json")
	h.check(str(info.get("kind", "")) == "interface", "json kind interface")
	var found_static := false
	for f in info.get("fields", []):
		if str((f as Dictionary).get("name", "")) == "sp" and bool((f as Dictionary).get("is_static", false)):
			found_static = true
	h.check(found_static, "json static field kept")
	var meth_ok := false
	for m in info.get("instance_methods", []):
		if str((m as Dictionary).get("name", "")) == "f" and str((m as Dictionary).get("returns", "")) == "String" and bool((m as Dictionary).get("is_vararg", false)):
			meth_ok = true
	h.check(meth_ok, "json method shape kept")
	var sig_ok := false
	for s in info.get("signals", []):
		if str((s as Dictionary).get("name", "")) == "s" and ((s as Dictionary).get("params", []) as Array).size() == 1:
			sig_ok = true
	h.check(sig_ok, "json signal kept")
	var enum_ok := false
	for e in info.get("enums", []):
		if str((e as Dictionary).get("name", "")) == "E" and ((e as Dictionary).get("values", []) as Array).size() == 2:
			enum_ok = true
	h.check(enum_ok, "json enum kept")
	var const_ok := false
	for c in info.get("constants", []):
		if str((c as Dictionary).get("name", "")) == "c" and str((c as Dictionary).get("type", "")) == "float":
			const_ok = true
	h.check(const_ok, "json const kept")
