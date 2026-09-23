class_name GnumarusGodotProjectAnalyzerSuiteFullScanImpl
extends RefCounted

## Project-wide static-analysis aggregator ("Full Scan").
##
## Runs every implemented analysis pass over the whole project and
## merges each pass result into a single JSON report,
## `.godot/0GnumarusGodotProjectAnalyzerSuiteData/ScanResults.json`.
## Current stages: "gdscript" (full analyzer over every project .gd;
## never embedded scripts, so scripts-only runs stay separable) and
## "resource_integrity" (text resources plus .gd load literals, plus
## embedded GDScripts as a consequence of the resource scan unless
## {"embedded": false} or the analyze_embedded_scripts setting opts
## out).
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
## column, sorted by (path, line, column, severity, kind, node —
## embedded scripts on two nodes share path and script line, so the
## node breaks that tie before the message).
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
const SemParser = preload("res://addons/0GnumarusGodotProjectAnalyzerSuite/GnumarusGodotProjectAnalyzerSuiteGdscriptSemanticParser.gd")
const TextParser = preload("res://addons/0GnumarusGodotProjectAnalyzerSuite/GnumarusGodotProjectAnalyzerSuiteTextResourceParser.gd")
const Integrity = preload("res://addons/0GnumarusGodotProjectAnalyzerSuite/GnumarusGodotProjectAnalyzerSuiteResourceIntegrity.gd")
const Uid = preload("res://addons/0GnumarusGodotProjectAnalyzerSuite/GnumarusGodotProjectAnalyzerSuiteUidCache.gd")
const Dumper = preload("res://addons/0GnumarusGodotProjectAnalyzerSuite/GnumarusGodotProjectAnalyzerSuiteGodotTypesInfoDumper.gd")

## Stage names (new stages add one constant and one runner).
const STAGE_GDSCRIPT := "gdscript"
const STAGE_INTEGRITY := "resource_integrity"

## ProjectSetting toggling GDScript embedded in text resources
## (sub_resource GDScript in .tscn/.tres): true analyzes them as a
## consequence of the integrity stage, false skips them. Default true.
const SETTING_EMBEDDED := "gnumarus_analyzer/analyze_embedded_scripts"

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
## `opts` optionally pins the snapshot instead ({"policy","strict"}):
## worker dispatch passes a main-thread snapshot so scan threads never
## touch singletons mid-scan.
static func _fresh_analyzer(opts := {}) -> RefCounted:
	var ana = Analyzer.new()
	if (opts as Dictionary).has("policy"):
		ana.null_policy = str((opts as Dictionary).get("policy", "trust"))
	else:
		ana.null_policy = str(ProjectSettings.get_setting("gnumarus_analyzer/nullable_policy", "trust"))
	if (opts as Dictionary).has("strict"):
		ana.strict_untyped = bool((opts as Dictionary).get("strict", false))
	else:
		ana.strict_untyped = bool(ProjectSettings.get_setting("gnumarus_analyzer/strict_untyped", false))
	return ana


## Main-thread snapshot of the analyzer policy settings for worker
## dispatch (see _fresh_analyzer). Static, pure reads.
static func policy_snapshot() -> Dictionary:
	return {"policy": str(ProjectSettings.get_setting("gnumarus_analyzer/nullable_policy", "trust")), "strict": bool(ProjectSettings.get_setting("gnumarus_analyzer/strict_untyped", false))}


## Empty report (also the fallback for missing/corrupt files).
static func empty_doc() -> Dictionary:
	return {"version": 1, "generated_unix": 0.0, "stages": {}, "errors": [], "warnings": [], "summary": {"stages": [], "files": 0, "errors": 0, "warnings": 0}, "filters": default_filters(), "census": _norm_census_group({}, true)}


## Default dock filter state (everything visible, addons counted,
## files sorted by path ascending). The dock owns the same shape;
## this copy lets the report carry it without depending on the dock
## script.
static func default_filters() -> Dictionary:
	return {"show": {"error": true, "warning": true, "note": true}, "types": {"gd": true, "tscn": true, "tres": true, "godot": true, "other": true}, "include_addons": true, "sort": "path", "descending": false}


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
## warnings on ties (same embedded script line on two nodes orders by
## node before message, so shared scripts stay grouped). Static, pure.
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
	var an := str(ad.get("node", ""))
	var bn := str(bd.get("node", ""))
	if an != bn:
		return an < bn
	return str(ad.get("message", "")) < str(bd.get("message", ""))


## Normalizes one analyzer/integrity issue into the report shape.
## Embedded-script extras (scene/node/embedded_base/embedded_sub) ride
## along when present, so dock navigation can open the scene, focus
## the node and jump to the embedded line. Static, pure.
static func _tag(stage: String, issue: Variant, fallback_path: String) -> Dictionary:
	var d: Dictionary = issue as Dictionary if issue is Dictionary else {}
	var sev := str(d.get("severity", "error"))
	if sev != "warning":
		sev = "error"
	var out := {
		"stage": stage,
		"severity": sev,
		"kind": str(d.get("kind", "?")),
		"message": str(d.get("message", "")),
		"path": str(d.get("path", fallback_path)),
		"line": maxi(int(d.get("line", 1)), 1),
		"column": maxi(int(d.get("column", 0)), 0),
	}
	for k in ["scene", "node", "embedded_base", "embedded_sub"]:
		if (d as Dictionary).has(k) and str((d as Dictionary).get(k, "")) != "":
			out[k] = str((d as Dictionary).get(k, ""))
	if (d as Dictionary).has("scene_line") and int((d as Dictionary).get("scene_line", 0)) > 0:
		out["scene_line"] = maxi(int((d as Dictionary).get("scene_line", 0)), 1)
	return out


## True when embedded GDScripts ride along the integrity stage.
## `opts` optionally pins {"embedded": bool} (worker/tests); otherwise
## the ProjectSetting decides (default true). Static, headless-safe.
static func embedded_enabled(opts := {}) -> bool:
	if (opts as Dictionary).has("embedded"):
		return bool((opts as Dictionary).get("embedded", true))
	return bool(ProjectSettings.get_setting(SETTING_EMBEDDED, true))


## Analyzes every GDScript embedded in one text resource: parses the
## resource, joins each sub_resource GDScript with the nodes using it
## (see TextParser.embedded_with_nodes), runs the full analyzer per
## (script, node) pair and returns {"errors", "warnings"} with
## path = the resource, line/column inside the embedded source, plus
## scene/node/embedded_base/embedded_sub/scene_line for navigation and
## JSON naming (scene_line = the script/source line in the scene, so
## rows render scene:script; one user JSON per root base plus one per
## inner class, dotted). `text` avoids a second disk read when the
## caller already has it; `opts` pins policy/embedded (worker
## dispatch). Never fails (unreadable sources yield no issues, not
## crashes).
func analyze_embedded_text(resource_path: String, text: String, opts := {}) -> Dictionary:
	var errors: Array = []
	var warnings: Array = []
	if str(resource_path) == "":
		return {"errors": errors, "warnings": warnings}
	var parsed: Dictionary = TextParser.new().parse_text(text, resource_path)
	var items: Array = TextParser.embedded_with_nodes(parsed)
	for item in items:
		if not (item is Dictionary):
			continue
		var source := str((item as Dictionary).get("source", ""))
		if source == "":
			continue
		var node_path := str((item as Dictionary).get("node_path", ""))
		var sub_id := str((item as Dictionary).get("sub_id", ""))
		var scene_line := maxi(int((item as Dictionary).get("line", 1)), 1)
		var base := SemParser.embedded_base(resource_path, node_path, sub_id)
		var ana = _fresh_analyzer(opts)
		var res: Dictionary = ana.analyze(SynParser.new().parse_text(source), resource_path, base)
		for e in res.get("errors", []):
			var ed := (e as Dictionary).duplicate() if e is Dictionary else {}
			ed["path"] = resource_path
			ed["scene"] = resource_path
			ed["node"] = node_path
			ed["embedded_base"] = base
			ed["embedded_sub"] = sub_id
			ed["scene_line"] = scene_line
			errors.append(ed)
		for w in res.get("warnings", []):
			var wd := (w as Dictionary).duplicate() if w is Dictionary else {}
			wd["path"] = resource_path
			wd["scene"] = resource_path
			wd["node"] = node_path
			wd["embedded_base"] = base
			wd["embedded_sub"] = sub_id
			wd["scene_line"] = scene_line
			warnings.append(wd)
	return {"errors": errors, "warnings": warnings}


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
	return _write_doc(doc)


## Writes the report doc to disk (creating the data dir). Never fails
## (a write failure prints and still returns the doc). Shared by
## store_stage and store_filters.
static func _write_doc(doc: Dictionary) -> Dictionary:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(data_dir()))
	var f := FileAccess.open(results_path(), FileAccess.WRITE)
	if f == null:
		printerr("Gnumarus Full Scan: cannot write " + results_path())
		return doc
	(f as FileAccess).store_string(JSON.stringify(doc, "  "))
	(f as FileAccess).close()
	return doc


## Stores dock filter state ("show"/"types" toggle maps, the
## addons-census flag and the Files-tab sort) in the report without
## touching any stage entry or aggregate. Returns the full doc. The
## dock calls this as its file-level persistence; the EditorSettings
## copy (when available) takes precedence on load.
static func store_filters(show: Dictionary, types: Dictionary, include_addons := true, sort_key := "path", descending := false) -> Dictionary:
	var doc := load_results()
	doc["filters"] = {"show": show.duplicate(), "types": types.duplicate(), "include_addons": bool(include_addons), "sort": str(sort_key), "descending": bool(descending)}
	doc["generated_unix"] = Time.get_unix_time_from_system()
	return _write_doc(doc)


## Extension bucket of one path: lowercased extension of the file
## name only (dots in directory names never count; extensionless
## names group under "(no ext)"). Pure, unit-tested headless.
static func census_ext(path: String) -> String:
	var s := str(path)
	var file_name := s.substr(s.rfind("/") + 1)
	var dot := file_name.rfind(".")
	var ext := file_name.substr(dot + 1).to_lower() if dot >= 0 else ""
	return ext if ext != "" else "(no ext)"


## Groups file paths by lowercased extension of the file name only
## (see census_ext). Shape {"extensions", "total"} exactly (no sizes:
## use census_group for the enriched form). Pure, unit-tested
## headless.
static func census_of(paths: Array) -> Dictionary:
	var exts := {}
	for p in paths:
		var ext := census_ext(p)
		exts[ext] = int(exts.get(ext, 0)) + 1
	var total := 0
	for k in exts.keys():
		total += int(exts[k])
	return {"extensions": exts, "total": total}


## Human size in multiples of 1024 ("512 B", "1.5 KB", "12.0 MB").
## Pure, unit-tested headless.
static func human_size(bytes: int) -> String:
	var b := maxi(bytes, 0)
	if b < 1024:
		return "%d B" % b
	var units := ["KB", "MB", "GB", "TB"]
	var v := float(b) / 1024.0
	var u := 0
	while v >= 1024.0 and u < units.size() - 1:
		v /= 1024.0
		u += 1
	return "%.1f %s" % [v, units[u]]


## Creation/modification unixtimes via the OS shell (Godot exposes
## no creation-time API: FileAccess has modified/access only, and
## DirAccess has no stat calls at all): {os_path: {"created": int,
## "modified": int}}. One process per chunk (250 paths), order-matched
## output, per-file retry on shape mismatch; anything unparseable
## degrades to zeros with a single warning. `runner` stubs process
## spawns for hermetic tests (Callable(exe, args) -> {"code", "out"}).
## Blocking: worker thread only in production. Static, never fails.
static func creation_map(os_paths: Array, runner := Callable()) -> Dictionary:
	return creation_map_for(OS.get_name(), os_paths, runner)


## OS-dispatched creation lookup (testable without a real OS or shell:
## "Windows" runs one powershell script over all paths — trying
## powershell, then pwsh — "Linux"/"macOS" run stat in chunks;
## anything else degrades to {}. Unknown filesystems (birth time
## unsupported) report 0 and stay 0 downstream.
static func creation_map_for(os_name: String, os_paths: Array, runner := Callable()) -> Dictionary:
	var paths: Array = []
	for p in os_paths:
		if str(p) != "":
			paths.append(str(p))
	if paths.is_empty():
		return {}
	if str(os_name) == "Windows":
		return _creation_map_windows(paths, runner)
	if str(os_name) == "Linux":
		return _creation_map_stat(paths, runner, true)
	if str(os_name) == "macOS":
		return _creation_map_stat(paths, runner, false)
	return {}


## One synchronous process (worker thread only): {"code", "out"}.
## Stubbed by tests via `runner`. Never fails (spawn errors degrade
## to code -1 with empty output).
static func _run_process(exe: String, args: Array, runner: Callable) -> Dictionary:
	if runner.is_valid():
		var stub: Variant = runner.call(exe, args)
		if stub is Dictionary:
			return {"code": int((stub as Dictionary).get("code", -1)), "out": (stub as Dictionary).get("out", [])}
		return {"code": -1, "out": []}
	var str_args := PackedStringArray()
	for a in args:
		str_args.append(str(a))
	var out: Array = []
	var code := OS.execute(exe, str_args, out, false)
	return {"code": code, "out": out}


## "created|modified" line parser (exactly two ints, else []).
## Strips surrounding whitespace: OS.execute returns one blob with
## embedded newlines, so callers split first and lines may carry
## trailing "\n"/"\r". Pure.
static func _parse_stat_pair(line: String) -> Array:
	var s := str(line).strip_edges()
	var parts := s.split("|")
	if parts.size() != 2:
		return []
	if not parts[0].is_valid_int() or not parts[1].is_valid_int():
		return []
	return [int(parts[0]), int(parts[1])]


## Flattens OS.execute output blobs into lines: Godot returns stdout
## as a single array element with embedded newlines ("a|b\nc|d\n"),
## while stubbed runners return one element per line. Splitting every
## chunk on "\n" handles both shapes; trailing blanks are dropped.
## Pure.
static func _flatten_process_lines(raw: Array) -> Array:
	var lines: Array = []
	for chunk in raw:
		for part in str(chunk).split("\n"):
			lines.append(str(part).replace("\r", ""))
	while not lines.is_empty() and str(lines[lines.size() - 1]).strip_edges() == "":
		lines.pop_back()
	return lines


## stat-backed lookup (GNU "%W|%Y", BSD "%B|%m"): chunked batches
## with per-file retry of misshapen batches. `chunk` exists for
## tests (production uses 250). Never fails.
static func _creation_map_stat(paths: Array, runner: Callable, gnu: bool, chunk := 250) -> Dictionary:
	var out := {}
	var i := 0
	var step := maxi(chunk, 1)
	while i < paths.size():
		var slice := (paths as Array).slice(i, i + step)
		if not _creation_stat_chunk(slice, runner, gnu, out):
			for single in slice:
				_creation_stat_chunk([single], runner, gnu, out)
		i += step
	if out.is_empty() and not paths.is_empty():
		printerr("Gnumarus Full Scan: creation lookup produced nothing (stat missing or unsupported).")
	return out


## One stat batch: parses "created|modified" lines order-matched
## against paths. Records nothing and returns false on any shape
## mismatch (exit code, line count, unparseable line). Never fails.
static func _creation_stat_chunk(paths: Array, runner: Callable, gnu: bool, out: Dictionary) -> bool:
	var args: Array = ["-c", "%W|%Y"] if gnu else ["-f", "%B|%m"]
	for p in paths:
		args.append(str(p))
	var res := _run_process("stat", args, runner)
	if int(res.get("code", 1)) != 0:
		return false
	var lines := _flatten_process_lines(res.get("out", []))
	if lines.size() != paths.size():
		return false
	var tmp: Array = []
	for ln in lines:
		var pair := _parse_stat_pair(str(ln))
		if pair.is_empty():
			return false
		tmp.append(pair)
	for i in range(paths.size()):
		(out as Dictionary)[str(paths[i])] = {"created": int((tmp[i] as Array)[0]), "modified": int((tmp[i] as Array)[1])}
	return true


## Windows lookup: one powershell process looping over argv
## ($args, so paths never pass through shell quoting — only single
## quotes inside the static script are doubled). Tries powershell,
## then pwsh; validates shape like the stat path. Never fails.
static func _creation_map_windows(paths: Array, runner: Callable) -> Dictionary:
	var script := "$o = @()\nforeach ($p in $args) {\n  try {\n    $i = Get-Item -LiteralPath $p -Force\n    $o += (\"{0}|{1}\" -f [int64]([datetimeoffset]$i.CreationTimeUtc).ToUnixTimeSeconds(), [int64]([datetimeoffset]$i.LastWriteTimeUtc).ToUnixTimeSeconds())\n  } catch {\n    $o += \"0|0\"\n  }\n}\n$o -join \"`n\""
	var argv: Array = ["-NoProfile", "-NonInteractive", "-Command", script]
	for p in paths:
		argv.append(str(p))
	for exe in ["powershell", "pwsh"]:
		var res := _run_process(exe, argv, runner)
		if int(res.get("code", -1)) != 0:
			continue
		var lines := _flatten_process_lines(res.get("out", []))
		if lines.size() != paths.size():
			continue
		var out := {}
		var ok := true
		for i in range(paths.size()):
			var pair := _parse_stat_pair(str(lines[i]))
			if pair.is_empty():
				ok = false
				break
			out[str(paths[i])] = {"created": int((pair as Array)[0]), "modified": int((pair as Array)[1])}
		if ok:
			return out
	printerr("Gnumarus Full Scan: creation lookup failed on Windows.")
	return {}


## Size (bytes) and modification unixtime of one file ("created" is
## always 0 here: creation times arrive in bulk via creation_map at
## collect level). Zeros when missing/unreadable. Static, pure IO,
## headless-safe.
static func file_stat(path: String) -> Dictionary:
	var size := 0
	var modified := 0
	if str(path) != "" and FileAccess.file_exists(path):
		modified = int(FileAccess.get_modified_time(path))
		size = maxi(int(FileAccess.get_size(path)), 0)
	return {"size": size, "created": 0, "modified": modified}


## Enriched census group for paths: counts plus byte sum, human size,
## and oldest/newest modification mtimes. `read_stat` optionally stubs
## per-file stats (Callable(path) -> {"size","created","modified"};
## real FileAccess otherwise, so hermetic tests stay file-free).
## Pure modulo stats.
static func census_group(paths: Array, read_stat := Callable()) -> Dictionary:
	return census_group_entries(stat_file_entries(paths, read_stat))


## One stat entry per path ({"path","size","created","modified"}).
## Pure modulo stats.
static func stat_file_entries(paths: Array, read_stat := Callable()) -> Array:
	var out: Array = []
	for p in paths:
		var st: Dictionary = (read_stat.call(str(p)) as Dictionary) if read_stat.is_valid() else file_stat(str(p))
		out.append({"path": str(p), "size": maxi(int(st.get("size", 0)), 0), "created": maxi(int(st.get("created", 0)), 0), "modified": maxi(int(st.get("modified", 0)), 0)})
	return out


## Aggregates stat entries into a census group (counts, byte sum,
## human size, oldest/newest mtimes). Pure.
static func census_group_entries(entries: Array) -> Dictionary:
	var exts := {}
	var total := 0
	var bytes := 0
	var newest := 0
	var oldest := 0
	var seen := false
	for e in entries:
		if not (e is Dictionary):
			continue
		var ed := e as Dictionary
		var ext := census_ext(str(ed.get("path", "")))
		exts[ext] = int(exts.get(ext, 0)) + 1
		total += 1
		bytes += maxi(int(ed.get("size", 0)), 0)
		var mt := maxi(int(ed.get("modified", 0)), 0)
		if not seen or mt < oldest:
			oldest = mt
		if not seen or mt > newest:
			newest = mt
		seen = true
	return {"extensions": exts, "total": total, "bytes": bytes, "size": human_size(bytes), "newest": newest, "oldest": oldest}


## Merges two census groups (counts/bytes/totals summed, oldest/newest
## across both; empty sides contribute nothing). Pure.
static func _merge_groups(a: Dictionary, b: Dictionary) -> Dictionary:
	var exts: Dictionary = ((a as Dictionary).get("extensions", {}) as Dictionary).duplicate()
	for k in ((b as Dictionary).get("extensions", {}) as Dictionary).keys():
		exts[k] = int(exts.get(k, 0)) + int(((b as Dictionary).get("extensions", {}) as Dictionary).get(k, 0))
	var at := maxi(int((a as Dictionary).get("total", 0)), 0)
	var bt := maxi(int((b as Dictionary).get("total", 0)), 0)
	var bytes := maxi(int((a as Dictionary).get("bytes", 0)), 0) + maxi(int((b as Dictionary).get("bytes", 0)), 0)
	var oldest := 0
	var newest := 0
	if at > 0 and bt > 0:
		oldest = mini(maxi(int((a as Dictionary).get("oldest", 0)), 0), maxi(int((b as Dictionary).get("oldest", 0)), 0))
		newest = maxi(maxi(int((a as Dictionary).get("newest", 0)), 0), maxi(int((b as Dictionary).get("newest", 0)), 0))
	elif at > 0:
		oldest = maxi(int((a as Dictionary).get("oldest", 0)), 0)
		newest = maxi(int((a as Dictionary).get("newest", 0)), 0)
	elif bt > 0:
		oldest = maxi(int((b as Dictionary).get("oldest", 0)), 0)
		newest = maxi(int((b as Dictionary).get("newest", 0)), 0)
	return {"extensions": exts, "total": at + bt, "bytes": bytes, "size": human_size(bytes), "newest": newest, "oldest": oldest}


## Every project file under root as res:// paths, skipping generated
## and version-control dirs (`.godot/`, `.git/`). Static, pure IO,
## headless-safe.
static func collect_project_files(root: String) -> Array:
	var out: Array = []
	if root == "" or not DirAccess.dir_exists_absolute(root):
		return out
	var dirs: Array = [root]
	while not dirs.is_empty():
		var dir: String = str(dirs.pop_back())
		if dir == "" or not DirAccess.dir_exists_absolute(dir):
			continue
		for sub in DirAccess.get_directories_at(dir):
			if str(sub) != ".godot" and str(sub) != ".git":
				dirs.append(dir + "/" + str(sub))
		for f in DirAccess.get_files_at(dir):
			out.append(_res_path(root, dir + "/" + str(f)))
	out.sort()
	return out


## OS/dir path to res:// form under root (raw path outside root).
static func _res_path(root: String, abspath: String) -> String:
	if root != "" and abspath.begins_with(root):
		return "res://" + abspath.substr(root.length()).trim_prefix("/")
	return abspath


## Every project directory under root as res:// paths (root itself
## included as "res://"), skipping generated and version-control
## subtrees (`.godot/`, `.git/`). Static, pure IO, headless-safe.
static func collect_project_dirs(root: String) -> Array:
	var out: Array = []
	if root == "" or not DirAccess.dir_exists_absolute(root):
		return out
	var dirs: Array = [root]
	while not dirs.is_empty():
		var dir: String = str(dirs.pop_back())
		if dir == "" or not DirAccess.dir_exists_absolute(dir):
			continue
		out.append(_res_path(root, dir))
		for sub in DirAccess.get_directories_at(dir):
			if str(sub) != ".godot" and str(sub) != ".git":
				dirs.append(dir + "/" + str(sub))
	out.sort()
	return out


## Parent res:// directory of a file or dir path ("" for the root
## itself). The res:// double slash is preserved ("res://x.gd" lives
## in "res://", not "res:/"). Pure.
static func _parent_dir(path: String) -> String:
	var s := str(path)
	while s.ends_with("/") and s.length() > 7:
		s = s.substr(0, s.length() - 1)
	if s == "" or s == "res://" or s == "res:/":
		return ""
	var slash := s.rfind("/")
	if slash < 0:
		return ""
	var parent := s.substr(0, slash)
	if parent == "res:/":
		return "res://"
	return parent


## Per-directory rollups for `dirs` from pre-statted `file_entries`
## ({"path","size",...}): direct file/subdir counts, recursive file/
## subdir totals, direct and recursive byte sums. Directory dates start
## at 0 here and are filled later by _enrich_creation via the shell
## (DirAccess exposes no stat API). Children roll into parents
## deepest-first. Pure.
static func census_dir_entries(dirs: Array, file_entries: Array) -> Array:
	var by_parent_files := {}
	for f in file_entries:
		if not (f is Dictionary):
			continue
		var parent := _parent_dir(str((f as Dictionary).get("path", "")))
		if not by_parent_files.has(parent):
			by_parent_files[parent] = []
		(by_parent_files[parent] as Array).append(f)
	var by_parent_dirs := {}
	for d in dirs:
		var ds := str(d)
		if ds == "":
			continue
		var parent := _parent_dir(ds)
		if parent != "":
			if not by_parent_dirs.has(parent):
				by_parent_dirs[parent] = []
			(by_parent_dirs[parent] as Array).append(ds)
	var ordered: Array = (dirs as Array).duplicate()
	ordered.sort_custom(func(a: Variant, b: Variant) -> bool: return str(a).length() > str(b).length())
	var acc := {}
	var out: Array = []
	for ds in ordered:
		var dsp := str(ds)
		if dsp == "":
			continue
		var dfiles: Array = (by_parent_files.get(dsp, []) as Array).duplicate()
		var ddirs: Array = (by_parent_dirs.get(dsp, []) as Array).duplicate()
		var direct_bytes := 0
		for f in dfiles:
			direct_bytes += maxi(int((f as Dictionary).get("size", 0)), 0)
		var rec_files := dfiles.size()
		var rec_subdirs := ddirs.size()
		var rec_bytes := direct_bytes
		for child in ddirs:
			var cr: Dictionary = acc.get(str(child), {})
			rec_files += int(cr.get("files_recursive", 0))
			rec_subdirs += int(cr.get("subdirs_recursive", 0))
			rec_bytes += int(cr.get("size_recursive", 0))
		var entry := {
			"path": dsp, "created": 0, "modified": 0,
			"files": dfiles.size(), "subdirs": ddirs.size(),
			"files_recursive": rec_files, "subdirs_recursive": rec_subdirs,
			"size": direct_bytes, "size_recursive": rec_bytes,
		}
		acc[dsp] = entry
		out.append(entry)
	out.sort_custom(func(a: Variant, b: Variant) -> bool: return str((a as Dictionary).get("path", "")) < str((b as Dictionary).get("path", "")))
	return out


## True for paths inside res://addons/ (the dir itself counts too).
## Pure, unit-tested headless.
static func is_addons_path(path: String) -> bool:
	var p := path.strip_edges()
	return p == "res://addons" or p.begins_with("res://addons/")


## Counts every project file by extension, split into the plain
## project tree ("project", res://addons/ excluded) and the addons
## subtree ("addons"), plus the merged view (same group shape).
## Every group carries counts, byte sum, human size and oldest/newest
## mtimes; the report additionally lists every file
## ({"path","size","created","modified"}) and every directory (see
## census_dir_entries). `read_stat` stubs per-file stats (see
## census_group); with a valid stub the shell lookup is skipped, so
## hermetic tests never spawn processes. Static, pure IO.
static func collect_file_census(root: String, read_stat := Callable()) -> Dictionary:
	var res_paths := collect_project_files(root)
	var entries := stat_file_entries(res_paths, read_stat)
	var dir_res := collect_project_dirs(root)
	var dir_entries := census_dir_entries(dir_res, entries)
	if not read_stat.is_valid():
		_enrich_creation(root, res_paths, entries, dir_res, dir_entries)
	var pentries: Array = []
	var aentries: Array = []
	for e in entries:
		if is_addons_path(str((e as Dictionary).get("path", ""))):
			aentries.append(e)
		else:
			pentries.append(e)
	var pg := census_group_entries(pentries)
	var ag := census_group_entries(aentries)
	var merged := _merge_groups(pg, ag)
	return {"extensions": merged.get("extensions", {}), "total": int(merged.get("total", 0)), "bytes": int(merged.get("bytes", 0)), "size": str(merged.get("size", "")), "newest": int(merged.get("newest", 0)), "oldest": int(merged.get("oldest", 0)), "project": pg, "addons": ag, "files": entries, "dirs": dir_entries}


## res:// path to OS path under root ("res://" itself maps to root).
## Pure.
static func _os_path(root: String, res_path: String) -> String:
	var rel := str(res_path)
	if rel == "res://":
		return root
	if rel.begins_with("res://"):
		rel = rel.substr(6)
	if root.ends_with("/"):
		return root + rel
	return root + "/" + rel


## Fills "created" on file entries and "created"/"modified" on dir
## entries from one batched shell lookup (real runs only). Dir entries
## are matched by path (census_dir_entries returns them sorted, not in
## walk order), so index-based matching would misattribute dates.
## `lookup` stubs the shell map for tests (Callable(os_paths) ->
## {os_path: {"created","modified"}}); real runs call creation_map.
## Unknown paths keep their zeros. Never fails.
static func _enrich_creation(root: String, res_paths: Array, entries: Array, dir_res: Array, dir_entries: Array, lookup := Callable()) -> void:
	var os_paths: Array = []
	var owners: Array = []
	for i in range(res_paths.size()):
		os_paths.append(_os_path(root, str(res_paths[i])))
		owners.append([0, i])
	for j in range(dir_res.size()):
		os_paths.append(_os_path(root, str(dir_res[j])))
		owners.append([1, str(dir_res[j])])
	var dir_by_path := {}
	for d in dir_entries:
		if d is Dictionary:
			dir_by_path[str((d as Dictionary).get("path", ""))] = d
	var got: Dictionary = (lookup.call(os_paths) as Dictionary) if lookup.is_valid() else creation_map(os_paths)
	for k in range(owners.size()):
		var hit: Dictionary = got.get(str(os_paths[k]), {})
		if hit.is_empty():
			continue
		var o: Array = owners[k]
		if int(o[0]) == 0 and int(o[1]) < entries.size():
			(entries[int(o[1])] as Dictionary)["created"] = maxi(int(hit.get("created", 0)), 0)
		elif int(o[0]) == 1:
			var target: Variant = dir_by_path.get(str(o[1]), null)
			if target is Dictionary:
				(target as Dictionary)["created"] = maxi(int(hit.get("created", 0)), 0)
				(target as Dictionary)["modified"] = maxi(int(hit.get("modified", 0)), 0)


## Stores the file census in the report without touching any stage
## entry or aggregate. Persists the merged view plus the project and
## addons partitions (each with counts, byte sum, human size and
## oldest/newest mtimes), the per-file inventory ({"path","size",
## "created","modified"}) and the per-directory rollups (see
## census_dir_entries). Missing keys normalize to zero/empty.
## Returns the full doc.
static func store_census(census: Dictionary) -> Dictionary:
	var doc := load_results()
	doc["census"] = _norm_census_group(census, true)
	(doc["census"] as Dictionary)["files"] = _norm_file_entries(census.get("files", []))
	(doc["census"] as Dictionary)["dirs"] = _norm_dir_entries(census.get("dirs", []))
	doc["generated_unix"] = Time.get_unix_time_from_system()
	return _write_doc(doc)


## Normalized per-file entries (unknown shapes dropped). Pure.
static func _norm_file_entries(files: Variant) -> Array:
	var out: Array = []
	if not (files is Array):
		return out
	for f in (files as Array):
		if not (f is Dictionary):
			continue
		var d := f as Dictionary
		out.append({"path": str(d.get("path", "")), "size": maxi(int(d.get("size", 0)), 0), "created": maxi(int(d.get("created", 0)), 0), "modified": maxi(int(d.get("modified", 0)), 0)})
	return out


## Normalized per-directory entries (unknown shapes dropped). Pure.
static func _norm_dir_entries(dirs: Variant) -> Array:
	var out: Array = []
	if not (dirs is Array):
		return out
	for d in (dirs as Array):
		if not (d is Dictionary):
			continue
		var e := d as Dictionary
		out.append({"path": str(e.get("path", "")), "created": maxi(int(e.get("created", 0)), 0), "modified": maxi(int(e.get("modified", 0)), 0), "files": maxi(int(e.get("files", 0)), 0), "subdirs": maxi(int(e.get("subdirs", 0)), 0), "files_recursive": maxi(int(e.get("files_recursive", 0)), 0), "subdirs_recursive": maxi(int(e.get("subdirs_recursive", 0)), 0), "size": maxi(int(e.get("size", 0)), 0), "size_recursive": maxi(int(e.get("size_recursive", 0)), 0)})
	return out


## Normalized census group (counts, bytes, size, mtimes; zeros when
## absent), optionally with normalized project/addons partitions.
## Shared by store_census and empty_doc. Pure.
static func _norm_census_group(census: Dictionary, with_parts: bool) -> Dictionary:
	var out := {
		"extensions": ((census.get("extensions", {}) as Dictionary).duplicate()),
		"total": maxi(int(census.get("total", 0)), 0),
		"bytes": maxi(int(census.get("bytes", 0)), 0),
		"size": str(census.get("size", "")),
		"newest": maxi(int(census.get("newest", 0)), 0),
		"oldest": maxi(int(census.get("oldest", 0)), 0),
	}
	if out.get("size", "") == "" and int(out.get("bytes", 0)) > 0:
		out["size"] = human_size(int(out.get("bytes", 0)))
	if with_parts:
		out["project"] = _norm_census_group((census.get("project", {}) as Dictionary), false)
		out["addons"] = _norm_census_group((census.get("addons", {}) as Dictionary), false)
	return out


## GDScript stage: analyzes every project .gd (or `targets` when
## given) with fresh analyzers and stores stage "gdscript".
## `targets`/`root_os` exist for hermetic tests; real runs pass
## nothing. `opts` pins the policy snapshot (worker dispatch);
## `cancel` (Callable() -> bool, worker-owned) aborts between files.
## Returns the full stored doc.
func run_gdscript(root_os := "", targets := [], opts := {}, cancel := Callable()) -> Dictionary:
	var root := root_os if root_os != "" else project_root()
	var files: Array = (targets as Array).duplicate() if not (targets as Array).is_empty() else Integrity.collect_gd_scripts(root)
	files.sort()
	Analyzer._roster_refresh(root)
	Analyzer._roster_absorb(Analyzer._roster_scan_files(root))
	var errors: Array = []
	var warnings: Array = []
	var i := 0
	for src in files:
		if cancel.is_valid() and bool(cancel.call()):
			print("Gnumarus Full Scan: gdscript cancelled.")
			return {"errors": errors, "warnings": warnings, "path": "", "cancelled": true}
		i += 1
		var path := str(src)
		print("Gnumarus Full Scan: gdscript [%d/%d] %s" % [i, files.size(), path])
		if path == "" or not FileAccess.file_exists(path):
			errors.append(_issue(STAGE_GDSCRIPT, "error", "unreadable", "Cannot open file: " + path, path))
			continue
		var ana = _fresh_analyzer(opts)
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
## `opts` pins policy/embedded (worker dispatch; {"embedded": false}
## skips embedded GDScripts). Embedded scripts ride along here — never
## in run_gdscript, so scripts-only and resources-only runs stay
## separable. `cancel` aborts between files (worker dispatch).
## Returns the full stored doc.
func run_integrity(root_os := "", targets := [], by_uid := {}, by_path := {}, exists := Callable(), read_text := Callable(), cancel := Callable(), opts := {}) -> Dictionary:
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
	var do_embedded := embedded_enabled(opts)
	for target in files:
		if cancel.is_valid() and bool(cancel.call()):
			print("Gnumarus Full Scan: integrity cancelled.")
			return {"errors": errors, "warnings": warnings, "path": "", "cancelled": true}
		i += 1
		var path := str(target)
		print("Gnumarus Full Scan: integrity [%d/%d] %s" % [i, files.size(), path])
		var res: Dictionary = checker.analyze_gd_file(path, uids, paths, exists) if path.ends_with(".gd") else checker.analyze_file(path, uids, paths, exists, read_text)
		for e in res.get("errors", []):
			errors.append(_tag(STAGE_INTEGRITY, e, path))
		for w in res.get("warnings", []):
			warnings.append(_tag(STAGE_INTEGRITY, w, path))
		if do_embedded and not path.ends_with(".gd") and FileAccess.file_exists(path):
			var emb: Dictionary = analyze_embedded_text(path, FileAccess.get_file_as_string(path), opts)
			for e in emb.get("errors", []):
				errors.append(_tag(STAGE_INTEGRITY, e, path))
			for w in emb.get("warnings", []):
				warnings.append(_tag(STAGE_INTEGRITY, w, path))
	return store_stage(STAGE_INTEGRITY, errors, warnings, files.size())


## Full run: every stage in order (each persists, so the report is
## complete even if a later stage is interrupted), then the project
## file census. Prints one completion line. Returns the full doc.
## `opts`/`cancel` are the worker-dispatch plumbs (see run_gdscript).
func run(root_os := "", opts := {}, cancel := Callable()) -> Dictionary:
	var root := root_os if root_os != "" else project_root()
	var gd := run_gdscript(root, [], opts, cancel)
	if bool(gd.get("cancelled", false)):
		return gd
	var ri := run_integrity(root, [], {}, {}, Callable(), Callable(), cancel, opts)
	if bool(ri.get("cancelled", false)):
		return ri
	var doc := store_census(collect_file_census(root))
	var s: Dictionary = doc.get("summary", {})
	print("Gnumarus Full Scan: %d files, %d errors, %d warnings. Results in %s" % [int(s.get("files", 0)), int(s.get("errors", 0)), int(s.get("warnings", 0)), results_path()])
	return doc
