extends RefCounted

## @struct suite: definitions (mandatory size, fields, markers),
## semantic compatibility, literal shapes, key/member access.

const Syn = preload("res://addons/0GnumarusGodotProjectAnalyzerSuite/GnumarusGodotProjectAnalyzerSuiteGdscriptSyntaticParser.gd")
const Sem = preload("res://addons/0GnumarusGodotProjectAnalyzerSuite/GnumarusGodotProjectAnalyzerSuiteGdscriptSemanticParser.gd")
const H = preload("res://addons/0GnumarusGodotProjectAnalyzerSuite/tests/helpers.gd")


func run() -> Dictionary:
	var h = H.new()
	h.suite = "struct"
	_s_def(h)
	_s_def_errors(h)
	_s_sem(h)
	_s_use(h)
	_s_keys_members(h)
	_s_canon(h)
	_s_json(h)
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


func _has_err_sem(src: String, path: String, kind: String, part: String) -> bool:
	var sem = Sem.new()
	var ast: Dictionary = sem.analyze(Syn.new().parse_text(src), path)
	for e in ast.get("semantic_errors", []):
		if str((e as Dictionary).get("kind", "")) == kind and part in str((e as Dictionary).get("message", "")):
			return true
	return false


func _s_def(h) -> void:
	h.check(_clean(h.analyze_text("extends Node\n# @tuple MyTuple 1 int\n# @struct MyStructB 4 field1:MyTuple field2:int|bool field3 field4:Variant\n# @var x MyStructB\nvar x: Dictionary\n", "res://tests/tmp_st_d1.gd")), "full example clean")
	h.check(_clean(h.analyze_text("extends Node\n# @struct Outer 2 a:Inner b:int\n# @struct Inner 1 x:int\n# @var v Outer\nvar v: Dictionary\n", "res://tests/tmp_st_d2.gd")), "forward struct ref clean")
	h.check(_clean(h.analyze_text("extends Node\n# @struct ES 0\n# @var x ES\nvar x: Dictionary = {}\n", "res://tests/tmp_st_d3.gd")), "empty struct clean")
	h.check(_has_err(h.analyze_text("extends Node\n# @tuple E 0\n# @struct E 0\nvar x: E\n", "res://tests/tmp_st_d4.gd"), "struct_conflict", "existing type"), "tuple vs struct collides")


func _s_def_errors(h) -> void:
	h.check(_has_err(h.analyze_text("extends Node\n# @struct S 3 a:int b:int\nvar x: S\n", "res://tests/tmp_st_e1.gd"), "struct_malformed", "declares size 3 but lists 2"), "count mismatch malformed")
	h.check(_kinds(h.analyze_text("extends Node\n# @struct S a:int\nvar x: S\n", "res://tests/tmp_st_e2.gd")).has("struct_malformed"), "missing count malformed")
	h.check(_kinds(h.analyze_text("extends Node\n# @struct\nvar x := 1\n", "res://tests/tmp_st_e3.gd")).has("struct_malformed"), "empty malformed")
	h.check(_has_err(h.analyze_text("extends Node\n# @struct S 2 a:int a:String\n", "res://tests/tmp_st_e4.gd"), "struct_malformed", "repeats field"), "duplicate field malformed")
	h.check(_has_err(h.analyze_text("extends Node\n# @struct S 1 a:void\nvar x: S\n", "res://tests/tmp_st_e5.gd"), "struct_malformed", "not a valid field type"), "void malformed")
	h.check(_has_err(h.analyze_text("extends Node\n# @struct S 1 a:Nope\nvar x: S\n", "res://tests/tmp_st_e6.gd"), "struct_unknown_type", "'Nope'"), "unknown field type errors")
	h.check(_has_err(h.analyze_text("extends Node\n# @struct S 1 a:int\n# @struct S 1 a:int\nvar x: S\n", "res://tests/tmp_st_e7.gd"), "struct_conflict", "more than once"), "duplicate conflicts")
	h.check(_has_err(h.analyze_text("extends Node\n# @struct Item 1 a:int\nclass Item:\n\tpass\n", "res://tests/tmp_st_e8.gd"), "struct_conflict", "script member"), "class conflict")
	h.check(_has_err(h.analyze_text("extends Node\n# @struct Node 1 a:int\n", "res://tests/tmp_st_e9.gd"), "struct_conflict", "existing type"), "builtin conflict")
	h.check(_kinds(h.analyze_text("extends Node\nfunc f(\n\t\t# @struct S 1 a:int\n\t\ta: int\n\t) -> void:\n\tpass\n", "res://tests/tmp_st_e10.gd")).has("struct_misplaced"), "param misplaced")
	h.check(_kinds(h.analyze_text("extends Node\nfunc f():\n\t# @struct S 1 a:int\n\n\tpass\n", "res://tests/tmp_st_e11.gd")).has("struct_misplaced"), "body misplaced")
	h.check(_kinds(h.analyze_text("# @struct S 1 a:int\nclass_name Foo\n", "res://tests/tmp_st_e12.gd")).has("struct_misplaced"), "header misplaced")


func _s_sem(h) -> void:
	h.check(_sem_kinds("extends Node\n# @struct S 2 a:int b:String\nvar x: S\n", "res://tests/tmp_st_s1.gd").is_empty(), "semantic accepts struct vartype")
	h.check(_sem_kinds("extends Node\n# @struct S 2 a:int b:String\nvar s: S\nvar d: Dictionary = s\n", "res://tests/tmp_st_s2.gd").is_empty(), "semantic struct to dict clean")
	h.check(_has_err_sem("extends Node\n# @struct S 2 a:int b:String\nvar d := {}\nvar x: S = d\n", "res://tests/tmp_st_s3.gd", "assign", "shape not provable"), "semantic dict to struct rejects")
	h.check(_sem_kinds("extends Node\n# @struct S 2 a:int b:String\nvar x: S = {\"a\": 1}\n", "res://tests/tmp_st_s4.gd").is_empty(), "semantic defers literals")
	h.check(_has_err_sem("extends Node\n# @struct S 2 a:int b:String\n# @struct T 1 q:int\nvar a: S\nvar b: T = a\n", "res://tests/tmp_st_s5.gd", "assign", "different struct types"), "semantic nominal mismatch")


func _s_use(h) -> void:
	h.check(_clean(h.analyze_text("extends Node\n# @struct S 2 a:int b:String\n# @var x S\nvar x: Dictionary = {\"a\": 1, \"b\": \"s\"}\n", "res://tests/tmp_st_u1.gd")), "conforming literal clean")
	h.check(_has_err(h.analyze_text("extends Node\n# @struct S 2 a:int b:String\n# @var x S\nvar x: Dictionary = {\"a\": 1}\n", "res://tests/tmp_st_u2.gd"), "struct_mismatch", "expects 2 fields, got 1"), "missing key mismatches")
	h.check(_has_err(h.analyze_text("extends Node\n# @struct S 2 a:int b:String\n# @var x S\nvar x: Dictionary = {\"a\": 1, \"b\": \"s\", \"c\": 2}\n", "res://tests/tmp_st_u3.gd"), "struct_mismatch", "expects 2 fields, got 3"), "extra key mismatches")
	h.check(_has_err(h.analyze_text("extends Node\n# @struct S 2 a:int b:String\n# @var x S\nvar x: Dictionary = {\"a\": \"s\", \"b\": \"s\"}\n", "res://tests/tmp_st_u4.gd"), "struct_mismatch", "field 'a' expects 'int'"), "wrong value mismatches")
	h.check(_clean(h.analyze_text("extends Node\n# @struct S 2 a:int b:String\nvar d := {}\n# @var x S\nvar x: Dictionary = d\n", "res://tests/tmp_st_u5.gd")), "analyzer silent on non-literal")
	h.check(_clean(h.analyze_text("extends Node\n# @struct S 1 m:Variant\n# @var x S\nvar x: Dictionary = {\"m\": 1}\n", "res://tests/tmp_st_u6.gd")), "unknown field accepts literal")


func _s_keys_members(h) -> void:
	h.check(_clean(h.analyze_text("extends Node\n# @struct S 2 a:int b:String\n# @var x S\nvar x: Dictionary = {\"a\": 1, \"b\": \"s\"}\nfunc f():\n\tprint(x.a)\n", "res://tests/tmp_st_k1.gd")), "member read clean")
	h.check(_has_err(h.analyze_text("extends Node\n# @struct S 2 a:int b:String\n# @var x S\nvar x: Dictionary = {\"a\": 1, \"b\": \"s\"}\nfunc f():\n\tprint(x.nope)\n", "res://tests/tmp_st_k2.gd"), "missing_member", "has no member 'nope'"), "member bogus errors")
	h.check(_clean(h.analyze_text("extends Node\n# @struct S 1 a:int\n# @var x S\nvar x: Dictionary = {\"a\": 1}\nfunc f():\n\tprint(x.keys())\n", "res://tests/tmp_st_k3.gd")), "dict method clean")
	h.check(_clean(h.analyze_text("extends Node\n# @struct S 2 a:int b:String\n# @var x S\nvar x: Dictionary = {\"a\": 1, \"b\": \"s\"}\nfunc f():\n\tprint(x[\"a\"])\n", "res://tests/tmp_st_k4.gd")), "key read clean")
	h.check(_has_err(h.analyze_text("extends Node\n# @struct S 2 a:int b:String\n# @var x S\nvar x: Dictionary = {\"a\": 1, \"b\": \"s\"}\nfunc f():\n\tprint(x[\"z\"])\n", "res://tests/tmp_st_k5.gd"), "missing_member", "has no member 'z'"), "key unknown errors")
	h.check(_clean(h.analyze_text("extends Node\n# @struct S 2 a:int b:String\n# @var x S\nvar x: Dictionary = {\"a\": 1, \"b\": \"s\"}\nfunc f(k):\n\tprint(x[k])\n", "res://tests/tmp_st_k6.gd")), "dynamic key skips")


func _s_canon(h) -> void:
	h.check(_clean(h.analyze_text("extends Node\n# @struct S 1 a:string\n# @var x S\nvar x: Dictionary\n", "res://tests/tmp_st_c1.gd")), "lowercase field type corrected")
	h.check(_clean(h.analyze_text("extends Node\n# @tuple T 1 object\n# @var x T\nvar x: Array\n", "res://tests/tmp_st_c2.gd")), "lowercase tuple item corrected")
	h.check(_clean(h.analyze_text("extends Node\n# @return object\nfunc f():\n\tpass\n", "res://tests/tmp_st_c3.gd")), "lowercase return corrected")


func _s_json(h) -> void:
	h.analyze_text("extends Node\n# @struct JStruct 2 a:int b:String|int\nvar x: JStruct\n", "res://tests/tmp_st_j1.gd")
	var info: Dictionary = h.load_json("res://.godot/0GnumarusGodotProjectAnalyzerSuiteData/user/JStruct.json")
	h.check(str(info.get("kind", "")) == "struct", "json kind struct")
	h.check(int(info.get("size", -1)) == 2, "json size kept")
	var fields: Array = info.get("fields", [])
	h.check(fields.size() == 2 and str((fields[0] as Dictionary).get("type", "")) == "int", "json fields kept")
	h.check(str((fields[1] as Dictionary).get("type", "")) == "String|int", "json union spelled")
