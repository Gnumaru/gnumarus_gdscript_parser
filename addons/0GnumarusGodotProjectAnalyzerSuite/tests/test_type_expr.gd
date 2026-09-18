extends RefCounted

## Nested type-expression suite: the _parse_type_expr mini-parser
## (names, unions, generics, `*`, whitespace tolerance, errors) plus
## its analyzer plug (complex @var/@param/@return specs and generic
## @tuple items resolve leaves and validate tuple applications).

const H = preload("res://addons/0GnumarusGodotProjectAnalyzerSuite/tests/helpers.gd")
const Ana = preload("res://addons/0GnumarusGodotProjectAnalyzerSuite/GnumarusGodotProjectAnalyzerSuiteGdscriptAnalyzer.gd")


func run() -> Dictionary:
	var h = H.new()
	h.suite = "type_expr"
	_t_parser(h)
	_t_var(h)
	_t_param_return(h)
	_t_items(h)
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


func _parse(text: String) -> Dictionary:
	return Ana._parse_type_expr(text, "@var")


func _t_parser(h) -> void:
	var simple := _parse("int")
	h.check(bool(simple.get("ok", false)) and str((simple.get("node", {}) as Dictionary).get("kind", "")) == "name", "plain name parses")
	var union := _parse("int | float")
	h.check(bool(union.get("ok", false)) and ((union.get("node", {}) as Dictionary).get("arms", []) as Array).size() == 2, "spaced union parses")
	var nested := _parse("int|tuple[int]|Dictionary[String|int,tuple[*,Variant,float]]")
	h.check(bool(nested.get("ok", false)), "user example parses")
	var root: Dictionary = nested.get("node", {})
	h.check(str(root.get("kind", "")) == "union" and ((root.get("arms", []) as Array).size() == 3), "three top arms")
	var last: Dictionary = (root.get("arms", []) as Array)[2]
	h.check(str(last.get("kind", "")) == "generic" and str(last.get("name", "")) == "Dictionary" and ((last.get("args", []) as Array).size() == 2), "dictionary generic shape")
	var inner: Dictionary = (last.get("args", []) as Array)[1]
	h.check(str(inner.get("kind", "")) == "generic" and ((inner.get("args", []) as Array).size() == 3) and str(((inner.get("args", []) as Array)[0] as Dictionary).get("kind", "")) == "any", "nested tuple with star")
	h.check(bool(_parse("tuple[ int , String ]").get("ok", false)), "spaces inside brackets")
	h.check(bool(_parse("Array[Dictionary[String,Array[int]]]").get("ok", false)), "deep nesting parses")
	h.check(not bool(_parse("int|").get("ok", false)), "trailing pipe fails")
	h.check(not bool(_parse("|int").get("ok", false)), "leading pipe fails")
	h.check(not bool(_parse("A[]").get("ok", false)), "empty args fail")
	h.check(not bool(_parse("A[int").get("ok", false)), "missing bracket fails")
	h.check(not bool(_parse("A[int]]").get("ok", false)), "trailing bracket fails")
	h.check(not bool(_parse("A[,int]").get("ok", false)), "leading comma fails")
	h.check(not bool(_parse("A[int,]").get("ok", false)), "trailing comma fails")
	h.check(not bool(_parse("(int)").get("ok", false)), "parens fail")


func _t_var(h) -> void:
	h.check(_clean(h.analyze_text("extends Node\n# @var myvar int|tuple[int]|Dictionary[String|int,tuple[*,Variant,float]]\nvar myvar: Variant\n", "res://tests/tmp_tx_v01.gd")), "user example clean on Variant")
	h.check(_clean(h.analyze_text("extends Node\n# @var myvar int | tuple[ int ] | Dictionary[ String | int , tuple[ *, Variant , float ] ]\nvar myvar: Variant\n", "res://tests/tmp_tx_v02.gd")), "spaced example clean")
	h.check(_has_err(h.analyze_text("extends Node\n# @var myvar int|tuple[int]\nvar myvar: Array\n", "res://tests/tmp_tx_v11.gd"), "var_mismatch", "'int' is neither 'Array'"), "plain arms still narrow")
	h.check(_has_err(h.analyze_text("extends Node\n# @var x Dictionary[String|Nope]\nvar x: Dictionary\n", "res://tests/tmp_tx_v03.gd"), "var_unknown_type", "Nope"), "unknown leaf errors")
	h.check(_has_err(h.analyze_text("extends Node\n# @var x Nope[int]\nvar x: Array\n", "res://tests/tmp_tx_v04.gd"), "var_unknown_type", "Nope"), "unknown head errors")
	h.check(_has_err(h.analyze_text("extends Node\n# @var x int|tuple[int\nvar x: Array\n", "res://tests/tmp_tx_v05.gd"), "var_malformed", "missing ']'"), "unbalanced brackets malformed")
	h.check(_has_err(h.analyze_text("extends Node\n# @var x void|int\nvar x: Variant\n", "res://tests/tmp_tx_v06.gd"), "var_malformed", "cannot be combined"), "void union still rejected")
	h.check(_clean(h.analyze_text("extends Node\n# @tuple TxPair 2 int String\n# @var p TxPair[int,String]\nvar p: TxPair\n", "res://tests/tmp_tx_v07.gd")), "applied tuple clean")
	h.check(_has_err(h.analyze_text("extends Node\n# @tuple TxPair2 2 int String\n# @var p TxPair2[int]\nvar p: TxPair2\n", "res://tests/tmp_tx_v08.gd"), "var_mismatch", "expects 2 type arguments, got 1"), "tuple arity mismatches")
	h.check(_has_err(h.analyze_text("extends Node\n# @tuple TxPair3 2 int String\n# @var p TxPair3[int,int]\nvar p: TxPair3\n", "res://tests/tmp_tx_v09.gd"), "var_mismatch", "argument 1 expects 'String'"), "tuple arg compat mismatches")
	h.check(_has_err(h.analyze_text("extends Node\n# @var x tuple[Nope]\nvar x: Array\n", "res://tests/tmp_tx_v10.gd"), "var_unknown_type", "Nope"), "anon tuple leaf validated")


func _t_param_return(h) -> void:
	h.check(_clean(h.analyze_text("extends Node\n# @param p tuple[int,String]\nfunc f(p):\n\tpass\n", "res://tests/tmp_tx_p01.gd")), "param complex clean")
	h.check(_has_err(h.analyze_text("extends Node\n# @param p Dictionary[String|Nope]\nfunc f(p):\n\tpass\n", "res://tests/tmp_tx_p02.gd"), "param_unknown_type", "Nope"), "param unknown leaf errors")
	h.check(_clean(h.analyze_text("extends Node\n# @return tuple[int,String]\nfunc f():\n\treturn [1, \"a\"]\n", "res://tests/tmp_tx_r01.gd")), "return complex clean")
	h.check(_has_err(h.analyze_text("extends Node\n# @return tuple[Nope]\nfunc f():\n\treturn []\n", "res://tests/tmp_tx_r02.gd"), "return_unknown_type", "Nope"), "return unknown leaf errors")
	h.check(_has_err(h.analyze_text("extends Node\n# @return int|tuple[int\nfunc f():\n\treturn 1\n", "res://tests/tmp_tx_r03.gd"), "return_malformed", "missing ']'"), "return unbalanced malformed")


func _t_items(h) -> void:
	h.check(_clean(h.analyze_text("extends Node\n# @tuple TxQ 2 int|Dictionary[String,int] *\n", "res://tests/tmp_tx_i01.gd")), "generic item clean")
	h.check(_clean(h.analyze_text("extends Node\n# @tuple TxQ2 2 Dictionary[ String , int ] *\n", "res://tests/tmp_tx_i02.gd")), "spaced generic item clean")
	h.check(_has_err(h.analyze_text("extends Node\n# @tuple TxQ3 2 int|Nope *\n", "res://tests/tmp_tx_i03.gd"), "tuple_unknown_type", "Nope"), "item unknown leaf errors")
	h.check(_has_err(h.analyze_text("extends Node\n# @tuple TxP4 2 int String\n# @tuple TxQ4 2 TxP4[int] *\n", "res://tests/tmp_tx_i04.gd"), "tuple_mismatch", "expects 2 type arguments"), "item tuple arity mismatches")
	h.check(_has_err(h.analyze_text("extends Node\n# @tuple TxQ5 2 void[int] *\n", "res://tests/tmp_tx_i05.gd"), "tuple_malformed", "void"), "item void malformed")
