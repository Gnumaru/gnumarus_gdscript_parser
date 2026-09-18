extends RefCounted

## Virtual-type suite: tuples, structs, aliases and interfaces are
## annotation-only types — they refine concrete declarations through
## @var/@param/@return but can never appear as declared GDScript types
## (vartypes, `->` arrows, base classes).

const H = preload("res://addons/0GnumarusGodotProjectAnalyzerSuite/tests/helpers.gd")


func run() -> Dictionary:
	var h = H.new()
	h.suite = "virtual"
	_v_vartype(h)
	_v_narrow(h)
	_v_values(h)
	_v_union(h)
	return h.result()


func _has_err(res: Dictionary, kind: String, part: String) -> bool:
	for e in res.get("errors", []):
		if str((e as Dictionary).get("kind", "")) == kind and part in str((e as Dictionary).get("message", "")):
			return true
	return false


func _clean(res: Dictionary) -> bool:
	return (res.get("errors", []) as Array).is_empty()


func _v_vartype(h) -> void:
	h.check(_has_err(h.analyze_text("extends Node\n# @tuple VvPair 2 int String\nvar x: VvPair = [1, \"a\"]\n", "res://tests/tmp_vv_t01.gd"), "virtual_vartype", "'VvPair'"), "tuple vartype errors")
	h.check(_has_err(h.analyze_text("extends Node\n# @struct VvPoint 2 x:int y:int\nvar p: VvPoint = {\"x\": 1, \"y\": 2}\n", "res://tests/tmp_vv_t02.gd"), "virtual_vartype", "'VvPoint'"), "struct vartype errors")
	h.check(_has_err(h.analyze_text("extends Node\n# @alias VvNum int|float @endalias\nvar x: VvNum = 1\n", "res://tests/tmp_vv_t03.gd"), "virtual_vartype", "'VvNum'"), "alias vartype errors")
	h.check(_has_err(h.analyze_text("extends Node\n# @tuple VvP2 1 int\nfunc f(p: VvP2):\n\tpass\n", "res://tests/tmp_vv_t04.gd"), "virtual_vartype", "'VvP2'"), "param vartype errors")
	h.check(_has_err(h.analyze_text("extends Node\n# @tuple VvP3 1 int\nfunc f() -> VvP3:\n\treturn [1]\n", "res://tests/tmp_vv_t05.gd"), "virtual_vartype", "'VvP3'"), "arrow errors")
	h.check(_has_err(h.analyze_text("extends Node\n# @tuple VvP4 1 int\nclass C extends VvP4:\n\tpass\n", "res://tests/tmp_vv_t06.gd"), "virtual_vartype", "'VvP4'"), "extends errors")
	h.check(_has_err(h.analyze_text("extends Node\n# @interface VvFace\n# func:f:void\n# @endinterface\nvar v: VvFace\n", "res://tests/tmp_vv_t07.gd"), "virtual_vartype", "'VvFace'"), "interface vartype errors")


func _v_narrow(h) -> void:
	h.check(_clean(h.analyze_text("extends Node\n# @tuple VvP10 2 int String\n# @var x VvP10\nvar x: Array = [1, \"a\"]\n", "res://tests/tmp_vv_n01.gd")), "tuple narrows Array")
	h.check(_clean(h.analyze_text("extends Node\n# @struct VvP11 2 x:int y:int\n# @var p VvP11\nvar p: Dictionary = {\"x\": 1, \"y\": 2}\n", "res://tests/tmp_vv_n02.gd")), "struct narrows Dictionary")
	h.check(_has_err(h.analyze_text("extends Node\n# @tuple VvP12 2 int String\n# @var x VvP12\nvar x: int = 1\n", "res://tests/tmp_vv_n03.gd"), "var_mismatch", "'VvP12'"), "tuple against int still mismatches")
	h.check(_clean(h.analyze_text("extends Node\n# @tuple VvP13 2 int String\n# @param p VvP13\nfunc f(p: Array):\n\tpass\n", "res://tests/tmp_vv_n04.gd")), "tuple narrows param Array")


func _v_values(h) -> void:
	h.check(_has_err(h.analyze_text("extends Node\n# @tuple VvP20 2 int String\n# @var x VvP20\nvar x: Array = [1, 2, 3]\n", "res://tests/tmp_vv_v01.gd"), "tuple_mismatch", "expects 2 elements"), "literal checked through annotation")
	h.check(_clean(h.analyze_text("extends Node\n# @struct VvP21 2 x:int y:int\n# @var p VvP21\nvar p: Dictionary = {\"x\": 1, \"y\": 2}\n", "res://tests/tmp_vv_v02.gd")), "struct literal through annotation clean")


func _v_union(h) -> void:
	h.check(_clean(h.analyze_text("extends Node\n# @interface VvDmg\n# func:apply_damage:void:dmg:int|float\n# @endinterface\n# @var mynode Node|VvDmg\nvar mynode: Node = get_node('some_path')\nmynode.apply_damage(1)\n", "res://tests/tmp_vv_u01.gd")), "union call through interface clean")
	h.check(_has_err(h.analyze_text("extends Node\n# @interface VvDmg2\n# func:apply_damage:void:dmg:int|float\n# @endinterface\n# @var mynode Node|VvDmg2\nvar mynode: Node = get_node('some_path')\nmynode.bogus()\n", "res://tests/tmp_vv_u02.gd"), "missing_method", "has no method 'bogus()'"), "union missing everywhere errors")
	h.check(_clean(h.analyze_text("extends Node\n# @interface VvHp\n# var:hp:int\n# @endinterface\n# @var mynode Node|VvHp\nvar mynode: Node\nprint(mynode.hp)\n", "res://tests/tmp_vv_u03.gd")), "union field read clean")
	h.check(_clean(h.analyze_text("extends Node\n# @interface VvPing\n# func:ping:void\n# @endinterface\n# @var x VvPing\nvar x: Variant\nx.ping()\n", "res://tests/tmp_vv_u04.gd")), "interface alone suffices")
	h.check(_clean(h.analyze_text("extends Node\n# @interface VvDmg5\n# func:apply_damage:void:dmg:int|float\n# @endinterface\n# @var mynode Node|VvDmg5\nvar mynode: Node\n", "res://tests/tmp_vv_u05.gd")), "union narrowing skipped")
	h.check(_has_err(h.analyze_text("extends Node\n# @interface VvHit\n# func:hit:void:tgt:Node\n# @endinterface\n# @var x VvHit\nvar x: Variant\nx.hit()\n", "res://tests/tmp_vv_u06.gd"), "interface_mismatch", "takes 1 argument(s), got 0"), "arity few errors")
	h.check(_has_err(h.analyze_text("extends Node\n# @interface VvHit2\n# func:hit:void:tgt:Node\n# @endinterface\n# @var x VvHit2\nvar x: Variant\nx.hit(a, b)\n", "res://tests/tmp_vv_u07.gd"), "interface_mismatch", "takes 1 argument(s), got 2"), "arity many errors")
	h.check(_has_err(h.analyze_text("extends Node\n# @interface VvHit3\n# func:hit:void:tgt:int\n# @endinterface\n# @var x VvHit3\nvar x: Variant\nx.hit(\"a\")\n", "res://tests/tmp_vv_u08.gd"), "interface_mismatch", "expects 'int', got 'String'"), "arg type errors")
	h.check(_clean(h.analyze_text("extends Node\n# @interface VvHit4\n# func:hit:void:tgt:int|float\n# @endinterface\n# @var x VvHit4\nvar x: Variant\nx.hit(1.5)\n", "res://tests/tmp_vv_u09.gd")), "union arg clean")
	h.check(_clean(h.analyze_text("extends Node\n# @interface VvHit5\n# func:hit:void:tgt:int;extra:String\n# @endinterface\n# @var x VvHit5\nvar x: Variant\nx.hit(1)\n", "res://tests/tmp_vv_u10.gd")), "defaults arity clean")
