extends RefCounted

## Pipeline smoke test on the ValidScript0.gd fixture:
## tokenize -> parse -> analyze must come out clean.

const Tok = preload("res://addons/0GnumarusGodotProjectAnalyzerSuite/GnumarusGodotProjectAnalyzerSuiteGdscriptTokenizer.gd")
const Syn = preload("res://addons/0GnumarusGodotProjectAnalyzerSuite/GnumarusGodotProjectAnalyzerSuiteGdscriptSyntaticParser.gd")
const Ana = preload("res://addons/0GnumarusGodotProjectAnalyzerSuite/GnumarusGodotProjectAnalyzerSuiteGdscriptAnalyzer.gd")
const H = preload("res://addons/0GnumarusGodotProjectAnalyzerSuite/tests/helpers.gd")


func run() -> Dictionary:
	var h = H.new()
	h.suite = "fixture"
	var tok = Tok.new()
	var tokens: Array = tok.tokenize("res://addons/0GnumarusGodotProjectAnalyzerSuite/tests/ValidScript0.gd")
	h.check(not tokens.is_empty(), "fixture tokens non-empty")
	h.check(str((tokens[tokens.size() - 1] as Dictionary).get("type", "")) == "EOF", "fixture tokens end with EOF")
	var syn = Syn.new()
	var ast: Dictionary = syn.parse_tokens(tokens)
	h.check(str(ast.get("type", "")) == "SCRIPT", "fixture ast root is SCRIPT")
	h.check(int(ast.get("errors", -1)) == 0, "fixture ast has zero syntax errors")
	var ana = Ana.new()
	var res: Dictionary = ana.analyze(ast, "res://addons/0GnumarusGodotProjectAnalyzerSuite/tests/ValidScript0.gd")
	h.check((res.get("errors", []) as Array).is_empty(), "fixture no analyzer errors")
	h.check((res.get("warnings", []) as Array).is_empty(), "fixture no analyzer warnings")
	return h.result()
