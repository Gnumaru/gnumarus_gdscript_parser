# @integrity_ignore_file (test harness uses virtual paths)
extends RefCounted

## Flow suite: Phase 1 strict member calls on known types plus Phase 2
## typeof guards. Reads, dynamic `=`, unknown, self/super and script
## classes never error (suppression-safe by construction).

const H = preload("res://addons/0GnumarusGodotProjectAnalyzerSuite/tests/helpers.gd")


func run() -> Dictionary:
	var h = H.new()
	h.suite = "flow"
	_f_strict(h)
	_f_skip(h)
	_f_continue(h)
	_f_guards(h)
	_f_is(h)
	_f_instanceof(h)
	_f_facts(h)
	_f_script(h)
	_f_block_scope(h)
	return h.result()


func _missing(res: Dictionary) -> Array:
	var out: Array = []
	for e in res.get("errors", []):
		if str((e as Dictionary).get("kind", "")) in ["missing_method", "missing_member"]:
			out.append(str((e as Dictionary).get("message", "")))
	return out


func _has_missing(res: Dictionary, kind: String, part: String) -> bool:
	for e in res.get("errors", []):
		if str((e as Dictionary).get("kind", "")) == kind and part in str((e as Dictionary).get("message", "")):
			return true
	return false


func _clean(res: Dictionary) -> bool:
	return _missing(res).is_empty()


func _f_strict(h) -> void:
	h.check(_has_missing(h.analyze_text("extends Node\nfunc f():\n\tvar v: Variant\n\tv.free()\n", "res://tests/tmp_flow_s1.gd"), "missing_method", "type 'Variant' has no method 'free()'"), "variant call errors")
	h.check(_clean(h.analyze_text("extends Node\nfunc f():\n\tvar n: Node\n\tn.queue_free()\n", "res://tests/tmp_flow_s2.gd")), "valid call clean")
	h.check(_has_missing(h.analyze_text("extends Node\nfunc f():\n\tvar n: Node\n\tn.nonexistent_xyz()\n", "res://tests/tmp_flow_s3.gd"), "missing_method", "type 'Node' has no method"), "bogus call errors")
	h.check(_clean(h.analyze_text("extends Node\nfunc f():\n\tvar s: String\n\ts.substr(0, 1)\n", "res://tests/tmp_flow_s4.gd")), "builtin call clean")
	h.check(_clean(h.analyze_text("extends Node\nfunc f():\n\tvar c: Control\n\tc.hide()\n", "res://tests/tmp_flow_s5.gd")), "inherited call clean")
	h.check(_clean(h.analyze_text("extends Node\nfunc f():\n\tvar n: Node\n\tprint(n.name)\n", "res://tests/tmp_flow_s6.gd")), "engine member read clean")
	h.check(_has_missing(h.analyze_text("extends Node\nfunc f():\n\tvar n: Node\n\tprint(n.bogus_member)\n", "res://tests/tmp_flow_s7.gd"), "missing_member", "has no member"), "engine member read errors")


func _f_skip(h) -> void:
	h.check(_clean(h.analyze_text("extends Node\nfunc f():\n\tvar x = 1\n\tx.anything_goes()\n", "res://tests/tmp_flow_k1.gd")), "dynamic = skips")
	h.check(_clean(h.analyze_text("extends Node\nfunc f(a):\n\ta.anything_goes()\n", "res://tests/tmp_flow_k2.gd")), "untyped param skips")
	h.check(_clean(h.analyze_text("extends Node\nfunc f():\n\tself.queue_free()\n", "res://tests/tmp_flow_k3.gd")), "self engine member clean")
	h.check(_has_missing(h.analyze_text("extends Node\nfunc f():\n\tself.anything_goes()\n", "res://tests/tmp_flow_k3b.gd"), "missing_method", "anything_goes"), "self bogus errors")
	h.check(_clean(h.analyze_text("class_name FLib\nextends Node\nclass Item:\n\tvar id := 0\nfunc f():\n\tvar it := Item.new()\n\tprint(it.id)\n", "res://tests/tmp_flow_k4.gd")), "script member clean")
	h.check(_has_missing(h.analyze_text("class_name FLib\nextends Node\nclass Item:\n\tvar id := 0\nfunc f():\n\tvar it := Item.new()\n\tit.nope()\n", "res://tests/tmp_flow_k5.gd"), "missing_method", "nope"), "script member bogus errors")


func _f_continue(h) -> void:
	h.check(_clean(h.analyze_text("extends Node\nfunc f():\n\tvar n = Node.new()\n\tn.queue_free()\n", "res://tests/tmp_flow_c1.gd")), "new infers and verifies")
	h.check(_clean(h.analyze_text("extends Node\nfunc f():\n\tvar n: Node\n\tn.get_child(0).queue_free()\n", "res://tests/tmp_flow_c2.gd")), "call result continues")
	h.check(_has_missing(h.analyze_text("extends Node\nfunc f():\n\tvar n: Node\n\tn.get_child(0).nonexistent_xyz()\n", "res://tests/tmp_flow_c3.gd"), "missing_method", "nonexistent_xyz"), "continued call errors")
	h.check(_clean(h.analyze_text("extends Node\nfunc f():\n\tEngine.get_main_loop()\n", "res://tests/tmp_flow_c4.gd")), "engine static clean")
	h.check(_has_missing(h.analyze_text("extends Node\nfunc f():\n\tNode.nonexistent_xyz()\n", "res://tests/tmp_flow_c5.gd"), "missing_method", "nonexistent_xyz"), "engine static bogus errors")


func _f_guards(h) -> void:
	var ex := "extends Node\nfunc myfunc():\n\tvar myvar: Variant\n\tmyvar.free()\n\tif typeof(myvar) == TYPE_OBJECT:\n\t\tmyvar.get_class()\n\tmyvar.free()\n\tmyvar.queue_free()\n"
	var res: Dictionary = h.analyze_text(ex, "res://tests/tmp_flow_g1.gd")
	h.check(_missing(res).size() == 3, "guarded region suppressed, rest errors")
	h.check(_clean(h.analyze_text("extends Node\nfunc f():\n\tvar v: Variant\n\tif typeof(v) == TYPE_STRING:\n\t\tv.substr(0, 1)\n", "res://tests/tmp_flow_g2.gd")), "string guard suppresses")
	h.check(_clean(h.analyze_text("extends Node\nfunc f():\n\tvar v: Variant\n\tif typeof(v) != TYPE_STRING:\n\t\tpass\n\telse:\n\t\tv.substr(0, 1)\n", "res://tests/tmp_flow_g3.gd")), "!= narrows else")
	h.check(_has_missing(h.analyze_text("extends Node\nfunc f():\n\tvar v: Variant\n\tif typeof(v) == TYPE_FROBNICATE:\n\t\tv.substr(0, 1)\n", "res://tests/tmp_flow_g4.gd"), "missing_method", "substr"), "unknown guard ignored")
	h.check(_clean(h.analyze_text("extends Node\nfunc f():\n\tvar v: Variant\n\tif typeof(v) == Variant.Type.TYPE_STRING:\n\t\tv.substr(0, 1)\n", "res://tests/tmp_flow_g6.gd")), "dotted typeof suppresses")


func _f_is(h) -> void:
	var one := "extends Node\nfunc f():\n\tvar v: Variant\n\tv.queue_free()\n\tif v is Node:\n\t\tv.queue_free()\n"
	h.check(_missing(h.analyze_text(one, "res://tests/tmp_flow_i1.gd")).size() == 1, "is narrows then only")
	h.check(_clean(h.analyze_text("extends Node\nfunc f():\n\tvar v: Variant\n\tif v is not Node:\n\t\tpass\n\telse:\n\t\tv.queue_free()\n", "res://tests/tmp_flow_i2.gd")), "is not narrows else")
	h.check(_has_missing(h.analyze_text("extends Node\nfunc f():\n\tvar v: Variant\n\tif v is Nope:\n\t\tv.queue_free()\n", "res://tests/tmp_flow_i3.gd"), "missing_method", "queue_free"), "is unknown ignored")
	h.check(_clean(h.analyze_text("extends Node\nfunc f(a):\n\tif a is Node:\n\t\ta.queue_free()\n", "res://tests/tmp_flow_i4.gd")), "is on param clean")


func _f_instanceof(h) -> void:
	h.check(_clean(h.analyze_text("extends Node\nfunc f():\n\tvar v: Variant\n\tif is_instance_of(v, Object):\n\t\tv.get_class()\n", "res://tests/tmp_flow_n1.gd")), "instanceof type clean")
	h.check(_clean(h.analyze_text("extends Node\nfunc f():\n\tvar v: Variant\n\tif is_instance_of(v, TYPE_OBJECT):\n\t\tv.get_class()\n", "res://tests/tmp_flow_n2.gd")), "instanceof bare enum clean")
	h.check(_clean(h.analyze_text("extends Node\nfunc f():\n\tvar v: Variant\n\tif is_instance_of(v, Variant.Type.TYPE_OBJECT):\n\t\tv.get_class()\n", "res://tests/tmp_flow_n3.gd")), "instanceof dotted clean")
	h.check(_clean(h.analyze_text("extends Node\nfunc f():\n\tvar v: Variant\n\tvar typecode: Variant.Type = Variant.Type.TYPE_OBJECT\n\tif is_instance_of(v, typecode):\n\t\tv.get_class()\n", "res://tests/tmp_flow_n4.gd")), "instanceof typecode clean")
	h.check(_clean(h.analyze_text("extends Node\nfunc f():\n\tvar v: Variant\n\tvar typecode := Variant.Type.TYPE_OBJECT\n\tif is_instance_of(v, typecode):\n\t\tv.get_class()\n", "res://tests/tmp_flow_n5.gd")), "instanceof inferred typecode clean")
	h.check(_has_missing(h.analyze_text("extends Node\nfunc f():\n\tvar v: Variant\n\tvar t := 1\n\tif is_instance_of(v, t):\n\t\tv.get_class()\n", "res://tests/tmp_flow_n6.gd"), "missing_method", "get_class"), "instanceof unknown var ignored")
	h.check(_clean(h.analyze_text("extends Node\nfunc f():\n\tvar v: Variant\n\tif not is_instance_of(v, Object):\n\t\tpass\n\telse:\n\t\tv.get_class()\n", "res://tests/tmp_flow_n7.gd")), "not instanceof narrows else")
	h.check(_clean(h.analyze_text("extends Node\nfunc myfunc():\n\tvar myvar: Variant\n\tvar typecode: Variant.Type = Variant.Type.TYPE_OBJECT\n\tif is_instance_of(myvar, typecode):\n\t\tmyvar.get_class()\n\tif is_instance_of(myvar, Object):\n\t\tmyvar.get_class()\n\tif myvar is Node:\n\t\tmyvar.queue_free()\n", "res://tests/tmp_flow_n8.gd")), "user phase3 example clean")


func _f_facts(h) -> void:
	h.check(_clean(h.analyze_text("extends Node\n# @var x Control\nvar x: Node\nfunc f():\n\tx.hide()\n", "res://tests/tmp_flow_a1.gd")), "flow respects @var facts")
	h.check(_has_missing(h.analyze_text("extends Node\nvar x: Node\nfunc f():\n\tx.hide()\n", "res://tests/tmp_flow_a2.gd"), "missing_method", "hide"), "without fact it errors")
	h.check(_clean(h.analyze_text("extends Node\nfunc f():\n\tvar x: Node\n\t# @var x Control\n\n\tx.hide()\n", "res://tests/tmp_flow_a3.gd")), "flow respects free @var facts")
	h.check(_clean(h.analyze_text("extends Node\nfunc f():\n\tvar v: Variant\n\tif typeof(v) == TYPE_OBJECT:\n\t\tv.free()\n", "res://tests/tmp_flow_a4.gd")), "ClassDB-merged free resolves in Object guard")


## Strict Objects: no dynamic script dispatch, only declared and
## inherited members. Script members through a base type error;
## suppressing needs a type guard.
func _f_script(h) -> void:
	h.check(_has_missing(h.analyze_text("extends Node\nvar health := 10\nfunc f():\n\tvar n: Node\n\tprint(n.health)\n", "res://tests/tmp_flow_d1.gd"), "missing_member", "has no member 'health'"), "script member via engine base errors")
	h.check(_clean(h.analyze_text("extends Node\nclass Item:\n\tvar id := 0\nfunc f():\n\tvar n: Node\n\tif n is Item:\n\t\tprint(n.id)\n", "res://tests/tmp_flow_d2.gd")), "is guard suppresses script member")
	h.check(_clean(h.analyze_text("extends Node\nclass Base:\n\tfunc b():\n\t\tpass\nclass Child extends Base\nfunc f():\n\tvar c := Child.new()\n\tc.b()\n", "res://tests/tmp_flow_d3.gd")), "inherited script member clean")
	h.check(_clean(h.analyze_text("extends Node\nvar health := 10\nfunc f():\n\tprint(self.health)\n", "res://tests/tmp_flow_d4.gd")), "self member clean")
	h.check(_clean(h.analyze_text("extends Node\nfunc f():\n\tself.queue_free()\n", "res://tests/tmp_flow_d5.gd")), "self inherited engine clean")
	h.check(_has_missing(h.analyze_text("extends Node\nfunc f():\n\tself.bogus_xyz()\n", "res://tests/tmp_flow_d6.gd"), "missing_method", "bogus_xyz"), "self bogus errors")
	h.check(_has_missing(h.analyze_text("class_name DLib\nextends Node\nclass Item:\n\tvar id := 0\nfunc f():\n\tvar it := Item.new()\n\tit.nope()\n", "res://tests/tmp_flow_d7.gd"), "missing_method", "nope"), "script method bogus errors")
	h.check(_has_missing(h.analyze_text("extends Node\nvar health := 10\nfunc f():\n\tvar n: Node\n\tprint(n.health)\n", "res://tests/tmp_flow_a5.gd"), "missing_member", "has no member 'health'"), "script member via engine base errors")
	h.check(_clean(h.analyze_text("extends Node\nclass Item:\n\tvar id := 0\nfunc f():\n\tvar n: Node\n\tif n is Item:\n\t\tprint(n.id)\n", "res://tests/tmp_flow_a6.gd")), "is guard suppresses script member")
	h.check(_clean(h.analyze_text("extends Node\nclass Base:\n\tfunc b():\n\t\tpass\nclass Child extends Base\nfunc f():\n\tvar c := Child.new()\n\tc.b()\n", "res://tests/tmp_flow_a7.gd")), "inherited script member clean")


## Block scope: a block-nested declaration stops hiding the outer one
## after its block (if/for/while), so later uses resolve to the
## visible declaration; inner uses still see the shadower.
func _f_block_scope(h) -> void:
	h.check(_clean(h.analyze_text("extends RefCounted\nstatic func g(v: Variant) -> bool:\n\tif v != null:\n\t\tvar heads: Variant = v\n\t\tif not (heads is Array):\n\t\t\treturn false\n\tvar heads: Array = []\n\tif heads.is_empty():\n\t\treturn false\n\treturn true\n", "res://tests/tmp_flow_b1.gd")), "if shadow then outer redecl clean")
	h.check(_clean(h.analyze_text("extends RefCounted\nstatic func g() -> bool:\n\tvar i := 0\n\twhile i < 1:\n\t\tvar heads: Variant = i\n\t\ti += 1\n\tvar heads: Array = []\n\tif heads.is_empty():\n\t\treturn false\n\treturn true\n", "res://tests/tmp_flow_b2.gd")), "while shadow then outer redecl clean")
	h.check(_clean(h.analyze_text("extends RefCounted\nstatic func g() -> bool:\n\tfor i in [1]:\n\t\tvar heads: Variant = i\n\t\tprint(heads)\n\tvar heads: Array = []\n\tif heads.is_empty():\n\t\treturn false\n\treturn true\n", "res://tests/tmp_flow_b3.gd")), "for shadow then outer redecl clean")
	h.check(_clean(h.analyze_text("extends RefCounted\nstatic func g() -> bool:\n\tvar heads: Array = []\n\tif true:\n\t\tvar heads: Variant = 1\n\t\tprint(heads)\n\tif heads.is_empty():\n\t\treturn false\n\treturn true\n", "res://tests/tmp_flow_b4.gd")), "outer first use after block clean")
	h.check(_has_missing(h.analyze_text("extends RefCounted\nstatic func g() -> bool:\n\tif true:\n\t\tvar heads: Variant = 1\n\t\tif heads.is_empty():\n\t\t\treturn false\n\treturn true\n", "res://tests/tmp_flow_b5.gd"), "missing_method", "has no method 'is_empty()'"), "inner shadow use still errors")
	h.check(_clean(h.analyze_text("extends Node\nfunc f(c: bool) -> void:\n\tif c:\n\t\tvar x: int = 1\n\t\tprint(x)\n\tvar x: String = \"a\"\n\t# @var x String\n\tprint(x)\n", "res://tests/tmp_flow_b6.gd")), "free @var binds the visible declaration")
	h.check(_has_missing(h.analyze_text("extends Node\nfunc f(c: bool) -> void:\n\tif c:\n\t\tvar x: int = 1\n\t\tprint(x)\n\tvar x: String = \"a\"\n\t# @var x Node\n\tprint(x)\n", "res://tests/tmp_flow_b7.gd"), "var_mismatch", "declared as 'String'"), "free @var mismatch names the visible declaration")
	h.check(_clean(h.analyze_text("extends Node\nfunc f(c: bool, v: Variant) -> void:\n\tif c:\n\t\tvar tc := TYPE_INT\n\t\tprint(tc)\n\tvar tc: Variant.Type = Variant.Type.TYPE_OBJECT\n\tif is_instance_of(v, tc):\n\t\tv.get_class()\n", "res://tests/tmp_flow_b8.gd")), "is_instance_of folds the visible constant holder")
	h.check(_has_missing(h.analyze_text("extends Node\nfunc f(v: Variant) -> void:\n\tvar tc := TYPE_INT\n\tif is_instance_of(v, tc):\n\t\tv.queue_free()\n", "res://tests/tmp_flow_b9.gd"), "missing_method", "type 'int' has no method"), "inner constant holder still narrows")
	h.check(_has_missing(h.analyze_text("extends Node\n# @template GcT\n# @param x GcT\n# @return GcT\nfunc gcid(x):\n\treturn x\nfunc f(c: bool) -> void:\n\tif c:\n\t\tvar r: int = 1\n\t\tprint(r)\n\tvar r = gcid(\"a\")\n\tr.bogus_xyz()\n", "res://tests/tmp_flow_b10.gd"), "missing_method", "type 'String' has no method 'bogus_xyz()'"), "reassignment result flows into the visible untyped target")
	h.check(_has_missing(h.analyze_text("extends Node\n# @template GcT\n# @param x GcT\n# @return GcT\nfunc gcid(x):\n\treturn x\nfunc f() -> void:\n\tvar r = gcid(\"a\")\n\tr.bogus_xyz()\n", "res://tests/tmp_flow_b11.gd"), "missing_method", "type 'String' has no method 'bogus_xyz()'"), "reassignment result flows without shadowing")
	h.check(_has_missing(h.analyze_text("extends Node\n# @template GcT\n# @param x GcT\n# @return GcT\nfunc gcid(x):\n\treturn x\nfunc f(c: bool) -> void:\n\tif c:\n\t\tvar r: int = 1\n\t\tprint(r)\n\tvar r: String = \"s\"\n\tr = gcid(\"b\")\n\tr.bogus_xyz()\n", "res://tests/tmp_flow_b12.gd"), "missing_method", "type 'String' has no method 'bogus_xyz()'"), "reassignment on visible typed target names it")
