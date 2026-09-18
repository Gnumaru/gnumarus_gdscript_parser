extends SceneTree

const H = preload("res://addons/0GnumarusGodotProjectAnalyzerSuite/tests/helpers.gd")

func _show(tag: String, src: String, path: String) -> void:
	var h = H.new()
	var res: Dictionary = h.analyze_text(src, path)
	print("=== ", tag, " n=", (res.get("errors", []) as Array).size())
	for e in res.get("errors", []):
		print("  [", (e as Dictionary).get("kind", ""), "] :: ", (e as Dictionary).get("message", ""))

func _init() -> void:
	_show("flagship", "extends Node\n#@alias number int|float @endalias\n# @var x number\nvar x := 1\n", "res://tests/tmp_ali_s1.gd")
	_show("multiline", "extends Node\n# @alias pairs\n# tuple[int, String]\n# @endalias\n# @var p pairs\nvar p: Array\n", "res://tests/tmp_ali_s2.gd")
	_show("narrow-bad", "extends Node\n# @alias number int|float @endalias\n# @var x number\nvar x := \"a\"\n", "res://tests/tmp_ali_s3.gd")
	_show("unknown-use", "extends Node\n# @var x NoSuchAlias\nvar x: Variant\n", "res://tests/tmp_ali_s4.gd")
	_show("missing-end", "extends Node\n# @alias number int|float\nvar x := 1\n", "res://tests/tmp_ali_s5.gd")
	_show("dup", "extends Node\n# @alias number int @endalias\n# @alias number float @endalias\n", "res://tests/tmp_ali_s6.gd")
	_show("cycle", "extends Node\n# @alias A B @endalias\n# @alias B A @endalias\n", "res://tests/tmp_ali_s7.gd")
	_show("in-func", "extends Node\nfunc f():\n\t# @alias number int @endalias\n\tpass\n", "res://tests/tmp_ali_s8.gd")
	_show("tuple-arity", "extends Node\n# @tuple TxP 2 int String\n# @alias bad TxP[int] @endalias\n", "res://tests/tmp_ali_s9.gd")
	_show("applied-ok", "extends Node\n# @tuple TxP2 2 int String\n# @alias good TxP2[int,String] @endalias\n# @var p good\nvar p: Array\n", "res://tests/tmp_ali_s10.gd")
	quit(0)
