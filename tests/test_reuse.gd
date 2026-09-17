extends RefCounted

## Instance-reuse suite: every stage must parse a second input with the
## same object and produce results independent of the first one.

const Tok = preload("res://gnumarus_gdscript_tokenizer.gd")
const Post = preload("res://gnumarus_gdscript_post_tokenizer.gd")
const Syn = preload("res://gnumarus_gdscript_syntatic_parser.gd")
const Sem = preload("res://gnumarus_gdscript_semantic_parser.gd")
const Ana = preload("res://gnumarus_gdscript_analyzer.gd")
const H = preload("res://tests/helpers.gd")


func run() -> Dictionary:
	var h = H.new()
	h.suite = "reuse"
	_r_tokenizer(h)
	_r_post(h)
	_r_syntactic(h)
	_r_semantic(h)
	_r_analyzer(h)
	return h.result()


func _r_tokenizer(h) -> void:
	var t = Tok.new()
	var b: Array = t.tokenize_text("func f():\n\tpass\n")
	var types: Array = []
	for tk in b:
		types.append(str((tk as Dictionary).get("type", "")))
	h.check(types.has("KEYWORD") and types.has("INDENT"), "tokenizer reuse parses second input")
	# An abandoned iteration must not poison the next use.
	t.pending_text = "var q := 9\n"
	for tk in t:
		break
	var c: Array = t.tokenize_text("var z := 2\n")
	var found := false
	for tk in c:
		if str((tk as Dictionary).get("value", "")) == "z":
			found = true
	h.check(found, "tokenizer reuse after abandoned iteration")


func _r_post(h) -> void:
	var p = Post.new()
	var r1: Array = p.process_text("var x := 1 # @param x\n")
	var r2: Array = p.process_text("var y := 2 # plain note\n")
	var n1 := 0
	var n2 := 0
	for tk in r1:
		if str((tk as Dictionary).get("type", "")) == "TYPE_INFO":
			n1 += 1
	for tk in r2:
		if str((tk as Dictionary).get("type", "")) == "TYPE_INFO":
			n2 += 1
	h.check(n1 == 1 and n2 == 0, "post-tokenizer reuse is independent")


func _r_syntactic(h) -> void:
	var s = Syn.new()
	var ast1: Dictionary = s.parse_text("var a := 1\n")
	h.check((ast1.get("children", []) as Array).size() == 1, "syntactic first parse ok")
	var ast2: Dictionary = s.parse_text("func f():\n\tpass\n")
	h.check(str(((ast2.get("children", []) as Array)[0] as Dictionary).get("type", "")) == "FUNC_DECL", "syntactic reuse parses second input")
	h.check(int(ast2.get("errors", -1)) == 0, "syntactic reuse has zero errors")


func _r_semantic(h) -> void:
	var s = Syn.new()
	var sem = Sem.new()
	var s1: Dictionary = sem.analyze(s.parse_text("var v: NopeType_xyz := 1\n"), "res://tests/tmp_reuse1.gd")
	var s2: Dictionary = sem.analyze(s.parse_text("var w := 2\n"), "res://tests/tmp_reuse2.gd")
	h.check((s1.get("semantic_errors", []) as Array).size() > 0, "semantic first errors kept")
	h.check((s2.get("semantic_errors", []) as Array).is_empty(), "semantic reuse starts clean")


func _r_analyzer(h) -> void:
	var s = Syn.new()
	var ana = Ana.new()
	var ax1: Dictionary = ana.analyze(s.parse_text("var dummy := 0\n# @deprecated Use new.\nvar old_x := 1\nfunc u():\n\tprint(old_x)\n"), "res://tests/tmp_reuseA.gd")
	var ax2: Dictionary = ana.analyze(s.parse_text("var fresh := 2\n"), "res://tests/tmp_reuseB.gd")
	h.check((ax1.get("warnings", []) as Array).size() > 0, "analyzer first warnings kept")
	h.check((ax2.get("warnings", []) as Array).is_empty(), "analyzer reuse has no leaked warnings")
	h.check((ax2.get("errors", []) as Array).is_empty(), "analyzer reuse has no leaked errors")
