class_name GnumarusGodotProjectAnalyzerSuiteFullScanImpl
extends RefCounted

## Project-wide static-analysis aggregator ("Full Scan").
##
## Runs every implemented analysis pass over the whole project and
## merges each pass result into a single JSON report,
## `.godot/0GnumarusGodotProjectAnalyzerSuiteData/ScanResults.json`.
## Current stages: "gdscript" (full analyzer over every project .gd)
## and "resource_integrity" (text resources plus .gd load literals).
## Future stages only need a new stage name and a store_stage() call:
## aggregation (merge, sort, summary) is generic over the stages map,
## so no existing code changes when a stage is added.
##
## Each stage writes the report when it finishes (run_gdscript and
## run_integrity both persist), so a later stage never loses an
## earlier one: store_stage() loads the on-disk report, replaces only
## its own stage entry and recomputes the aggregates.
##
## Report shape:
## {
##   "version": 1, "generated_unix": float,
##   "stages": {"<stage>": {"errors": [...], "warnings": [...],
##                           "files": int}},
##   "errors": [...all stages, sorted...],
##   "warnings": [...all stages, sorted...],
##   "summary": {"stages": [...sorted names...], "files": int,
##               "errors": int, "warnings": int},
## }
## Every issue carries its stage plus severity/kind/message/path/line/
## column, sorted by (path, line, column, severity, kind).
##
## Deliberately RefCounted with no Editor dependency (same split as
## the analyzer and the integrity checker): the whole flow runs
## headless in unit tests. Editor entry points (the EditorScript proxy
## and the Project > Tools menu item) only forward here.
##
## Usage:
##   var res: Dictionary = GnumarusGodotProjectAnalyzerSuiteFullScanImpl.new().run()

const SynParser = preload("res://addons/0GnumarusGodotProjectAnalyzerSuite/GnumarusGodotProjectAnalyzerSuiteGdscriptSyntaticParser.gd")
const Analyzer = preload("res://addons/0GnumarusGodotProjectAnalyzerSuite/GnumarusGodotProjectAnalyzerSuiteGdscriptAnalyzer.gd")
const Integrity = preload("res://addons/0GnumarusGodotProjectAnalyzerSuite/GnumarusGodotProjectAnalyzerSuiteResourceIntegrity.gd")
const Uid = preload("res://addons/0GnumarusGodotProjectAnalyzerSuite/GnumarusGodotProjectAnalyzerSuiteUidCache.gd")
const Dumper = preload("res://addons/0GnumarusGodotProjectAnalyzerSuite/GnumarusGodotProjectAnalyzerSuiteGodotTypesInfoDumper.gd")

## Stage names (new stages add one constant and one runner).
const STAGE_GDSCRIPT := "gdscript"
const STAGE_INTEGRITY := "resource_integrity"

const RESULTS_FILE := "ScanResults.json"
const UID_CACHE := "res://.godot/uid_cache.bin"


## Data dir (single source of truth: the dumper constant).
static func data_dir() -> String:
	return "res://" + Dumper.DATA_DIR_NAME


## Report path inside the data dir.
static func results_path() -> String:
	return data_dir() + "/" + RESULTS_FILE


## Project OS root (globalized res://). Static, headless-safe.
static func project_root() -> String:
	var r := ProjectSettings.globalize_path("res://")
	if r.ends_with("/") and r.length() > 1:
		r = r.substr(0, r.length() - 1)
	return r


## Fresh analyzer carrying the current ProjectSetting policy as its
## explicit base (file tags still override per file inside analyze).
static func _fresh_analyzer() -> RefCounted:
	var ana = Analyzer.new()
	ana.null_policy = str(ProjectSettings.get_setting("gnumarus_analyzer/nullable_policy", "trust"))
	ana.strict_untyped = bool(ProjectSettings.get_setting("gnumarus_analyzer/strict_untyped", false))
	return ana


## Empty report (also the fallback for missing/corrupt files).
static func empty_doc() -> Dictionary:
	return {"version": 1, "generated_unix": 0.0, "stages": {}, "errors": [], "warnings": [], "summary": {"stages": [], "files": 0, "errors": 0, "warnings": 0}}


## Loads the on-disk report, or an empty doc when missing/unreadable.
static func load_results() -> Dictionary:
	var p := results_path()
	if not FileAccess.file_exists(p):
		return empty_doc()
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(p))
	if not (parsed is Dictionary) or not ((parsed as Dictionary).get("stages") is Dictionary):
		return empty_doc()
	return parsed


## Cross-file issue order: path first, then position, errors before
## warnings on ties. Static, pure.
static func _issue_less(a: Variant, b: Variant) -> bool:
	if not (a is Dictionary):
		return false
	if not (b is Dictionary):
		return true
	var ad: Dictionary = a
	var bd: Dictionary = b
	var ap := str(ad.get("path", ""))
	var bp := str(bd.get("path", ""))
	if ap != bp:
		return ap < bp
	var al := int(ad.get("line", 0))
	var bl := int(bd.get("line", 0))
	if al != bl:
		return al < bl
	var ac := int(ad.get("column", 0))
	var bc := int(bd.get("column", 0))
	if ac != bc:
		return ac < bc
	var ae := str(ad.get("severity", "error")) == "error"
	var be := str(bd.get("severity", "error")) == "error"
	if ae != be:
		return ae
	var ak := str(ad.get("kind", ""))
	var bk := str(bd.get("kind", ""))
	if ak != bk:
		return ak < bk
	return str(ad.get("message", "")) < str(bd.get("message", ""))


## Normalizes one analyzer/integrity issue into the report shape.
static func _tag(stage: String, issue: Variant, fallback_path: String) -> Dictionary:
	var d: Dictionary = issue as Dictionary if issue is Dictionary else {}
	var sev := str(d.get("severity", "error"))
	if sev != "warning":
		sev = "error"
	return {
		"stage": stage,
		"severity": sev,
		"kind": str(d.get("kind", "?")),
		"message": str(d.get("message", "")),
		"path": str(d.get("path", fallback_path)),
		"line": maxi(int(d.get("line", 1)), 1),
		"column": maxi(int(d.get("column", 0)), 0),
	}


## Direct issue for scan-infra failures (unreadable files).
static func _issue(stage: String, severity: String, kind: String, message: String, path: String) -> Dictionary:
	return {"stage": stage, "severity": severity, "kind": kind, "message": message, "path": path, "line": 1, "column": 0}


## Merges one stage result into the on-disk report: loads the current
## report, replaces only this stage entry, recomputes the sorted
## aggregates and summary, writes back. Never fails (a write failure
## prints and still returns the merged doc). Returns the full doc.
static func store_stage(stage: String, errors: Array, warnings: Array, files: int) -> Dictionary:
	var doc := load_results()
	(doc.get("stages", {}) as Dictionary)[stage] = {"errors": errors, "warnings": warnings, "files": maxi(files, 0)}
	doc["version"] = 1
	doc["generated_unix"] = Time.get_unix_time_from_system()
	var all_errors: Array = []
	var all_warnings: Array = []
	var total_files := 0
	var names: Array = (doc.get("stages", {}) as Dictionary).keys()
	names.sort()
	for n in names:
		var entry: Dictionary = ((doc.get("stages", {}) as Dictionary).get(n, {}) as Dictionary)
		total_files += int(entry.get("files", 0))
		for e in entry.get("errors", []):
			all_errors.append(e)
		for w in entry.get("warnings", []):
			all_warnings.append(w)
	all_errors.sort_custom(_issue_less)
	all_warnings.sort_custom(_issue_less)
	doc["errors"] = all_errors
	doc["warnings"] = all_warnings
	doc["summary"] = {"stages": names, "files": total_files, "errors": all_errors.size(), "warnings": all_warnings.size()}
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(data_dir()))
	var f := FileAccess.open(results_path(), FileAccess.WRITE)
	if f == null:
		printerr("Gnumarus Full Scan: cannot write " + results_path())
		return doc
	(f as FileAccess).store_string(JSON.stringify(doc, "  "))
	(f as FileAccess).close()
	return doc


## GDScript stage: analyzes every project .gd (or `targets` when
## given) with fresh analyzers and stores stage "gdscript".
## `targets`/`root_os` exist for hermetic tests; real runs pass
## nothing. Returns the full stored doc.
func run_gdscript(root_os := "", targets := []) -> Dictionary:
	var root := root_os if root_os != "" else project_root()
	var files: Array = (targets as Array).duplicate() if not (targets as Array).is_empty() else Integrity.collect_gd_scripts(root)
	files.sort()
	Analyzer._roster_refresh(root)
	Analyzer._roster_absorb(Analyzer._roster_scan_files(root))
	var errors: Array = []
	var warnings: Array = []
	var i := 0
	for src in files:
		i += 1
		var path := str(src)
		print("Gnumarus Full Scan: gdscript [%d/%d] %s" % [i, files.size(), path])
		if path == "" or not FileAccess.file_exists(path):
			errors.append(_issue(STAGE_GDSCRIPT, "error", "unreadable", "Cannot open file: " + path, path))
			continue
		var ana = _fresh_analyzer()
		var res: Dictionary = ana.analyze(SynParser.new().parse_text(FileAccess.get_file_as_string(path)), path)
		for e in res.get("errors", []):
			errors.append(_tag(STAGE_GDSCRIPT, e, path))
		for w in res.get("warnings", []):
			warnings.append(_tag(STAGE_GDSCRIPT, w, path))
	return store_stage(STAGE_GDSCRIPT, errors, warnings, files.size())


## Integrity stage: checks every text resource plus every .gd (or
## `targets` when given) and stores stage "resource_integrity".
## `by_uid`/`by_path` plus `exists`/`read_text` exist for hermetic
## tests (a valid `exists` stub means "use the given maps as-is");
## real runs load .godot/uid_cache.bin when the maps are empty.
## Returns the full stored doc.
func run_integrity(root_os := "", targets := [], by_uid := {}, by_path := {}, exists := Callable(), read_text := Callable()) -> Dictionary:
	var root := root_os if root_os != "" else project_root()
	var files: Array = (targets as Array).duplicate() if not (targets as Array).is_empty() else Integrity.collect_text_resources(root) + Integrity.collect_gd_scripts(root)
	files.sort()
	var uids: Dictionary = (by_uid as Dictionary).duplicate()
	var paths: Dictionary = (by_path as Dictionary).duplicate()
	if not exists.is_valid() and uids.is_empty():
		if FileAccess.file_exists(UID_CACHE):
			var cache: Dictionary = Uid.new().parse(UID_CACHE)
			if int(cache.get("errors", 0)) > 0:
				print("Gnumarus Full Scan: uid cache unreadable; uid checks skipped.")
			else:
				uids = cache.get("by_uid", {})
				paths = cache.get("by_path", {})
		else:
			print("Gnumarus Full Scan: uid cache not found; uid checks skipped.")
	var checker = Integrity.new()
	var errors: Array = []
	var warnings: Array = []
	var i := 0
	for target in files:
		i += 1
		var path := str(target)
		print("Gnumarus Full Scan: integrity [%d/%d] %s" % [i, files.size(), path])
		var res: Dictionary = checker.analyze_gd_file(path, uids, paths, exists) if path.ends_with(".gd") else checker.analyze_file(path, uids, paths, exists, read_text)
		for e in res.get("errors", []):
			errors.append(_tag(STAGE_INTEGRITY, e, path))
		for w in res.get("warnings", []):
			warnings.append(_tag(STAGE_INTEGRITY, w, path))
	return store_stage(STAGE_INTEGRITY, errors, warnings, files.size())


## Full run: every stage in order (each persists, so the report is
## complete even if a later stage is interrupted). Prints one
## completion line. Returns the full stored doc.
func run(root_os := "") -> Dictionary:
	var root := root_os if root_os != "" else project_root()
	run_gdscript(root)
	var doc := run_integrity(root)
	var s: Dictionary = doc.get("summary", {})
	print("Gnumarus Full Scan: %d files, %d errors, %d warnings. Results in %s" % [int(s.get("files", 0)), int(s.get("errors", 0)), int(s.get("warnings", 0)), results_path()])
	return doc
