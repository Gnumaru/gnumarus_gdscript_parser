extends RefCounted

## Shared assertions and helpers for the tests/ suites.
##
## Each suite creates one instance, sets `suite`, calls `check()` for
## every expectation and returns `result()`. Failed checks print
## immediately via printerr AND count toward the suite totals, so a
## single run shows both the failing names and the final tally.

const SynParser = preload("res://addons/0GnumarusGodotProjectAnalyzerSuite/GnumarusGodotProjectAnalyzerSuiteGdscriptSyntaticParser.gd")
const Analyzer = preload("res://addons/0GnumarusGodotProjectAnalyzerSuite/GnumarusGodotProjectAnalyzerSuiteGdscriptAnalyzer.gd")

var suite: String = ""
var passed: int = 0
var failed: int = 0


func check(cond: bool, name: String) -> void:
	if cond:
		passed += 1
	else:
		failed += 1
		printerr("FAIL [", suite, "]: ", name)


func result() -> Dictionary:
	return {"suite": suite, "passed": passed, "failed": failed}


## Parses + analyzes a source string with fresh instances. `policy`
## optionally sets the analyzer nullability policy ("trust"/"distrust";
## "" keeps the default) for the fresh instance.
func analyze_text(src: String, path: String, policy := "") -> Dictionary:
	var syn = SynParser.new()
	var ana = Analyzer.new()
	if policy != "":
		ana.null_policy = policy
	return ana.analyze(syn.parse_text(src), path)


func warn_texts(res: Dictionary) -> Array:
	var out: Array = []
	for w in res.get("warnings", []):
		out.append(str((w as Dictionary).get("message", "")))
	return out


func err_kinds(res: Dictionary) -> Array:
	var out: Array = []
	for e in res.get("errors", []):
		out.append(str((e as Dictionary).get("kind", "")))
	return out


func has_warn(res: Dictionary, part: String) -> bool:
	for t in warn_texts(res):
		if part in t:
			return true
	return false


func priv_errors(res: Dictionary) -> Array:
	var out: Array = []
	for e in res.get("errors", []):
		if str((e as Dictionary).get("kind", "")) == "private_use":
			out.append(e)
	return out


func has_priv(res: Dictionary, part: String) -> bool:
	for e in priv_errors(res):
		if part in str((e as Dictionary).get("message", "")):
			return true
	return false


func field_flagged(info: Dictionary, fname: String) -> bool:
	for f in info.get("fields", []):
		if str((f as Dictionary).get("name", "")) == fname and (f as Dictionary).has("private"):
			return true
	return false


func load_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(parsed) != TYPE_DICTIONARY:
		return {}
	return parsed
