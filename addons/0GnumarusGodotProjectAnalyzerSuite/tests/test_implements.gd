# @integrity_ignore_file (test harness uses virtual paths)
extends RefCounted

## \@implements suite: placement (script root vs nested class),
## target resolution (script/engine/struct/interface/tuple) and
## conformance (methods/fields/signals/enums/consts).

const Syn = preload("res://addons/0GnumarusGodotProjectAnalyzerSuite/GnumarusGodotProjectAnalyzerSuiteGdscriptSyntaticParser.gd")
const H = preload("res://addons/0GnumarusGodotProjectAnalyzerSuite/tests/helpers.gd")


func run() -> Dictionary:
	var h = H.new()
	h.suite = "implements"
	_i_placement(h)
	_i_targets(h)
	_i_methods(h)
	_i_members(h)
	_i_engine(h)
	return h.result()


func _kinds(res: Dictionary) -> Array:
	var out: Array = []
	for e in res.get("errors", []):
		if str((e as Dictionary).get("kind", "")).begins_with("implements"):
			out.append(str((e as Dictionary).get("kind", "")))
	return out


func _has(res: Dictionary, kind: String, part: String) -> bool:
	for e in res.get("errors", []):
		if str((e as Dictionary).get("kind", "")) == kind and part in str((e as Dictionary).get("message", "")):
			return true
	return false


func _clean(res: Dictionary) -> bool:
	for e in res.get("errors", []):
		if str((e as Dictionary).get("kind", "")).begins_with("implements"):
			return false
	return true


func _i_placement(h) -> void:
	h.check(_clean(h.analyze_text("# @implements Node2D\nextends Node2D\nfunc f():\n\tpass\n", "res://tests/tmp_impl_p1.gd")), "header root clean")
	h.check(_clean(h.analyze_text("class_name ImplRoot\n# @implements Node2D\nextends Node2D\n", "res://tests/tmp_impl_p2.gd")), "before extends clean")
	h.check(_clean(h.analyze_text("extends Node\n# @interface ImplFaceP\n# func:tick:void\n# @endinterface\n# @implements ImplFaceP\nfunc tick() -> void:\n\tpass\n", "res://tests/tmp_impl_p3.gd")), "before root func records root")
	h.check(_has(h.analyze_text("extends Node\n# @interface ImplFaceP2\n# func:tick:void\n# @endinterface\n# @implements ImplFaceP2\nfunc other():\n\tpass\n", "res://tests/tmp_impl_p4.gd"), "implements_mismatch", "ImplFaceP2.tick"), "before root func checks root target")
	h.check(_kinds(h.analyze_text("extends Node\nfunc f():\n\t# @implements Node2D\n\tpass\n", "res://tests/tmp_impl_p5.gd")).has("implements_misplaced"), "inside func body misplaced")
	h.check(_kinds(h.analyze_text("extends Node\nclass ImplInner:\n\t# @implements Node2D\n\tfunc f():\n\t\tpass\n", "res://tests/tmp_impl_p6.gd")).has("implements_misplaced"), "before nested func misplaced")
	h.check(_clean(h.analyze_text("extends Node\n# @implements Node2D\nclass ImplE extends Node2D:\n\tpass\n", "res://tests/tmp_impl_p7.gd")), "before nested class clean")


func _i_targets(h) -> void:
	h.check(_kinds(h.analyze_text("extends Node\n# @implements ImplNope\nfunc f():\n\tpass\n", "res://tests/tmp_impl_t1.gd")).has("implements_unknown_type"), "unknown type errors")
	h.check(_kinds(h.analyze_text("extends Node\n# @implements\nfunc f():\n\tpass\n", "res://tests/tmp_impl_t2.gd")).has("implements_malformed"), "bare tag malformed")
	h.check(_kinds(h.analyze_text("extends Node\n# @implements 123\nfunc f():\n\tpass\n", "res://tests/tmp_impl_t3.gd")).has("implements_malformed"), "bad word malformed")
	h.check(_has(h.analyze_text("extends Node\n# @tuple ImplPair 2 a b\n# @implements ImplPair\nvar x := 1\n", "res://tests/tmp_impl_t4.gd"), "implements_mismatch", "cannot use tuple"), "tuple rejected")
	h.check(_clean(h.analyze_text("extends Node\nclass ImplLib:\n\tvar v := 1\n# @implements ImplLib\nclass ImplUse extends ImplLib:\n\tpass\n", "res://tests/tmp_impl_t5.gd")), "nested dotted target clean")
	h.check(_has(h.analyze_text("extends Node\nclass ImplLib2:\n\tvar v := 1\n# @implements ImplLib2\nclass ImplUse2:\n\tpass\n", "res://tests/tmp_impl_t6.gd"), "implements_mismatch", "ImplLib2.v"), "script class missing member")


func _i_methods(h) -> void:
	var base := "extends Node\n# @interface %s\n# func:draw:void:canvas:CanvasItem\n# @endinterface\n# @implements %s\n"
	h.check(_clean(h.analyze_text(base % ["ImplM1", "ImplM1"] + "func draw(canvas: CanvasItem) -> void:\n\tpass\n", "res://tests/tmp_impl_m1.gd")), "exact method clean")
	h.check(_has(h.analyze_text(base % ["ImplM2", "ImplM2"] + "func other():\n\tpass\n", "res://tests/tmp_impl_m2.gd"), "implements_mismatch", "ImplM2.draw"), "missing method mismatch")
	h.check(_has(h.analyze_text(base % ["ImplM3", "ImplM3"] + "func draw(canvas: CanvasItem) -> int:\n\treturn 1\n", "res://tests/tmp_impl_m3.gd"), "implements_mismatch", "must return 'void'"), "wider return mismatch")
	h.check(_has(h.analyze_text(base % ["ImplM4", "ImplM4"] + "func draw(canvas: Node2D) -> void:\n\tpass\n", "res://tests/tmp_impl_m4.gd"), "implements_mismatch", "incompatible"), "narrower param mismatch")
	h.check(_clean(h.analyze_text(base % ["ImplM5", "ImplM5"] + "func draw(canvas: CanvasItem, extra: int = 0) -> void:\n\tpass\n", "res://tests/tmp_impl_m5.gd")), "extra default param clean")
	h.check(_clean(h.analyze_text("extends Node\n# @interface ImplM6\n# func:draw:void:canvas:CanvasItem\n# @endinterface\n# @implements ImplM6\nfunc draw(canvas) -> void:\n\tpass\n", "res://tests/tmp_impl_m6.gd")), "dynamic impl param clean")
	var st := "extends Node\n# @interface %s\n# static func:make:void\n# @endinterface\n# @implements %s\nfunc make() -> void:\n\tpass\n"
	h.check(_has(h.analyze_text(st % ["ImplM7", "ImplM7"], "res://tests/tmp_impl_m7.gd"), "implements_mismatch", "must be static"), "static mismatch")


func _i_members(h) -> void:
	h.check(_clean(h.analyze_text("extends Node\n# @interface ImplF1\n# var:visible:bool\n# @endinterface\n# @implements ImplF1\nvar visible := true\n", "res://tests/tmp_impl_f1.gd")), "field via @var clean")
	h.check(_has(h.analyze_text("extends Node\n# @interface ImplF2\n# var:visible:bool\n# @endinterface\n# @implements ImplF2\nvar x := 1\n", "res://tests/tmp_impl_f2.gd"), "implements_mismatch", "ImplF2.visible"), "missing field mismatch")
	h.check(_has(h.analyze_text("extends Node\n# @interface ImplF3\n# var:visible:bool\n# @endinterface\n# @implements ImplF3\nvar visible: String\n", "res://tests/tmp_impl_f3.gd"), "implements_mismatch", "incompatible type"), "field wrong type mismatch")
	h.check(_clean(h.analyze_text("extends Node\n# @struct ImplS1 2 x:int y:String\n# @implements ImplS1\nvar x: int\nvar y: String\n", "res://tests/tmp_impl_s1.gd")), "struct clean")
	h.check(_has(h.analyze_text("extends Node\n# @struct ImplS2 2 x:int y:String\n# @implements ImplS2\nvar x: int\n", "res://tests/tmp_impl_s2.gd"), "implements_mismatch", "ImplS2.y"), "struct missing field")
	h.check(_has(h.analyze_text("extends Node\n# @struct ImplS3 2 x:int y:String\n# @implements ImplS3\nvar x: String\nvar y: String\n", "res://tests/tmp_impl_s3.gd"), "implements_mismatch", "incompatible type"), "struct wrong type")
	h.check(_clean(h.analyze_text("extends Node\n# @interface ImplG1\n# signal:hit:x:int\n# @endinterface\n# @implements ImplG1\nsignal hit(x: int)\n", "res://tests/tmp_impl_g1.gd")), "signal clean")
	h.check(_has(h.analyze_text("extends Node\n# @interface ImplG2\n# signal:hit:x:int\n# @endinterface\n# @implements ImplG2\n", "res://tests/tmp_impl_g2.gd"), "implements_mismatch", "ImplG2.hit"), "missing signal")
	h.check(_clean(h.analyze_text("extends Node\n# @interface ImplE1\n# enum:Hue:R,G,B\n# @endinterface\n# @implements ImplE1\nenum Hue { R, G, B }\n", "res://tests/tmp_impl_e1.gd")), "enum clean")
	h.check(_has(h.analyze_text("extends Node\n# @interface ImplE2\n# enum:Hue:R,G,B\n# @endinterface\n# @implements ImplE2\nenum Hue { R, G }\n", "res://tests/tmp_impl_e2.gd"), "implements_mismatch", "ImplE2.Hue.B"), "enum missing member")
	h.check(_clean(h.analyze_text("extends Node\n# @interface ImplC1\n# const:max:int\n# @endinterface\n# @implements ImplC1\nconst max := 10\n", "res://tests/tmp_impl_c1.gd")), "const clean")
	h.check(_has(h.analyze_text("extends Node\n# @interface ImplC2\n# const:max:int\n# @endinterface\n# @implements ImplC2\n", "res://tests/tmp_impl_c2.gd"), "implements_mismatch", "ImplC2.max"), "missing const")


func _i_engine(h) -> void:
	h.check(_clean(h.analyze_text("extends Node2D\n# @implements Node2D\nfunc f():\n\tpass\n", "res://tests/tmp_impl_n1.gd")), "root inherits engine clean")
	h.check(_clean(h.analyze_text("extends Node\n# @implements Node2D\nclass ImplEN extends Node2D:\n\tpass\n", "res://tests/tmp_impl_n2.gd")), "nested inherits engine clean")
	h.check(_clean(h.analyze_text("extends Node2D\n# @interface ImplN3\n# func:tick:void\n# @endinterface\n# @implements Node2D ImplN3\nfunc tick() -> void:\n\tpass\n", "res://tests/tmp_impl_n3.gd")), "multi target clean")
	h.check(_has(h.analyze_text("extends Node\n# @implements Vector2\nclass ImplNV:\n\tpass\n", "res://tests/tmp_impl_n4.gd"), "implements_mismatch", "Vector2.x"), "non-object engine members required")
