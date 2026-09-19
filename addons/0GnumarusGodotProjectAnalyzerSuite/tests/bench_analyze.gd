extends SceneTree

## Manual performance bench for the analyzer pipeline (NOT a run_all
## suite: timings are machine-dependent, never asserted).
##
## Usage (from the project root):
##   GODOT_BIN=/sync/opt/godot/godot4.x86_64 \
##     /sync/opt/godot/godot4.x86_64 --headless --path . \
##     --quit-after 600 \
##     --script res://addons/0GnumarusGodotProjectAnalyzerSuite/tests/bench_analyze.gd
##
## Measures parse + analyze on the biggest project file (the analyzer
## itself, ~10k lines) and a small file, each in trust and in
## distrust+strict, warm data dir (run test.sh first).

const SynParser = preload("res://addons/0GnumarusGodotProjectAnalyzerSuite/GnumarusGodotProjectAnalyzerSuiteGdscriptSyntaticParser.gd")
const Analyzer = preload("res://addons/0GnumarusGodotProjectAnalyzerSuite/GnumarusGodotProjectAnalyzerSuiteGdscriptAnalyzer.gd")

const BIG := "res://addons/0GnumarusGodotProjectAnalyzerSuite/GnumarusGodotProjectAnalyzerSuiteGdscriptAnalyzer.gd"
const SMALL := "res://addons/0GnumarusGodotProjectAnalyzerSuite/tests/TmpRosterTarget.gd"


func _measure(path: String, policy := "", strict := false) -> Dictionary:
	var src: String = FileAccess.get_file_as_string(path)
	var t0 := Time.get_ticks_msec()
	var syn = SynParser.new()
	var ast: Dictionary = syn.parse_text(src)
	var t1 := Time.get_ticks_msec()
	var ana = Analyzer.new()
	if policy != "":
		ana.null_policy = policy
	if strict:
		ana.strict_untyped = true
	var res: Dictionary = ana.analyze(ast, path)
	var t2 := Time.get_ticks_msec()
	return {
		"path": path, "policy": policy, "strict": strict,
		"parse_ms": t1 - t0, "analyze_ms": t2 - t1,
		"errors": (res.get("errors", []) as Array).size(),
		"warnings": (res.get("warnings", []) as Array).size(),
	}


func _init() -> void:
	var rows: Array = []
	rows.append(_measure(SMALL))
	rows.append(_measure(SMALL, "distrust", true))
	rows.append(_measure(BIG))
	rows.append(_measure(BIG, "distrust", true))
	for r in rows:
		print("BENCH file=", str((r as Dictionary).get("path", "")).get_file(), " policy=", (r as Dictionary).get("policy", ""), " strict=", (r as Dictionary).get("strict", false), " parse_ms=", (r as Dictionary).get("parse_ms", 0), " analyze_ms=", (r as Dictionary).get("analyze_ms", 0), " E=", (r as Dictionary).get("errors", 0), " W=", (r as Dictionary).get("warnings", 0))
	quit()
