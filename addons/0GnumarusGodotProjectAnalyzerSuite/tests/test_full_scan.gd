# @integrity_ignore_file (test harness uses virtual paths)
extends RefCounted

## Full-scan suite: the aggregated ScanResults.json report (merge,
## sort, summary, corrupt-file fallback), the gdscript/integrity
## stages on hermetic targets, the dumb-proxy shape of the
## EditorScript, and the Project > Tools wiring in the plugin impl.
## The real ScanResults.json is backed up and restored, and any user
## JSONs the stage runs create are removed, so the suite is hermetic.

const Impl = preload("res://addons/0GnumarusGodotProjectAnalyzerSuite/GnumarusGodotProjectAnalyzerSuiteFullScanImpl.gd")
const SemParser = preload("res://addons/0GnumarusGodotProjectAnalyzerSuite/GnumarusGodotProjectAnalyzerSuiteGdscriptSemanticParser.gd")
const SynParser = preload("res://addons/0GnumarusGodotProjectAnalyzerSuite/GnumarusGodotProjectAnalyzerSuiteGdscriptSyntaticParser.gd")
const PluginImpl = preload("res://addons/0GnumarusGodotProjectAnalyzerSuite/GnumarusGodotProjectAnalyzerSuitePluginImpl.gd")
const H = preload("res://addons/0GnumarusGodotProjectAnalyzerSuite/tests/helpers.gd")

const PROXY_PATH := "res://addons/0GnumarusGodotProjectAnalyzerSuite/GnumarusGodotProjectAnalyzerSuiteFullScan.gd"
const IMPL_PATH := "res://addons/0GnumarusGodotProjectAnalyzerSuite/GnumarusGodotProjectAnalyzerSuiteFullScanImpl.gd"
const TMP_GD := "res://addons/0GnumarusGodotProjectAnalyzerSuite/tests/TmpFullScanTarget.gd"

var _backup := ""
var _had_backup := false


func _exists(_p: String) -> bool:
	return true


func _stat_stub(p: String) -> Dictionary:
	return {"size": p.length() * 100, "created": 0, "modified": 1700000000 + p.length()}


var _runner_calls: Array = []


## Fake process runner: answers "created|modified" from the path
## length for trailing path args (stat: after flag+format,
## powershell: after the four option/script args).
func _fake_shell_ok(exe: String, args: Array) -> Dictionary:
	_runner_calls.append([exe, args])
	var paths: Array = []
	var take := false
	var skip := 0
	for a in args:
		if take and skip > 0:
			skip -= 1
			continue
		if take:
			paths.append(str(a))
		elif str(a) == "-Command":
			take = true
			skip = 1
		elif str(a) == "-c" or str(a) == "-f":
			take = true
			skip = 1
	var out: Array = []
	for p in paths:
		out.append("%d|%d" % [5000 + p.length(), 6000 + p.length()])
	return {"code": 0, "out": out}


func _fake_shell_fail(exe: String, args: Array) -> Dictionary:
	_runner_calls.append([exe, args])
	return {"code": 1, "out": []}


func _fake_shell_failover(exe: String, args: Array) -> Dictionary:
	if str(exe) == "powershell":
		_runner_calls.append([exe, args])
		return {"code": 1, "out": []}
	return _fake_shell_ok(exe, args)


## Mimics the real OS.execute shape: stdout arrives as ONE blob with
## embedded newlines, not one array element per file.
func _fake_shell_blob(exe: String, args: Array) -> Dictionary:
	_runner_calls.append([exe, args])
	var paths: Array = []
	var take := false
	var skip := 0
	for a in args:
		if take and skip > 0:
			skip -= 1
			continue
		if take:
			paths.append(str(a))
		elif str(a) == "-Command":
			take = true
			skip = 1
		elif str(a) == "-c" or str(a) == "-f":
			take = true
			skip = 1
	var blob := ""
	for p in paths:
		blob += "%d|%d\n" % [5000 + p.length(), 6000 + p.length()]
	return {"code": 0, "out": [blob]}


func _fake_lookup(os_paths: Array) -> Dictionary:
	var out := {}
	for p in os_paths:
		out[str(p)] = {"created": 7000 + str(p).length(), "modified": 8000 + str(p).length()}
	return out


func run() -> Dictionary:
	var h = H.new()
	h.suite = "full_scan"
	_backup_results()
	_r_paths(h)
	_r_empty(h)
	_r_store_merge(h)
	_r_sort(h)
	_r_filters(h)
	_r_census(h)
	_r_inventory(h)
	_r_creation(h)
	_r_embedded(h)
	_r_corrupt(h)
	_r_gdscript_stage(h)
	_r_integrity_stage(h)
	_r_proxy(h)
	_r_menu(h)
	_restore_results()
	return h.result()


func _backup_results() -> void:
	_had_backup = FileAccess.file_exists(Impl.results_path())
	_backup = FileAccess.get_file_as_string(Impl.results_path()) if _had_backup else ""


func _restore_results() -> void:
	if _had_backup:
		var f := FileAccess.open(Impl.results_path(), FileAccess.WRITE)
		if f != null:
			(f as FileAccess).store_string(_backup)
			(f as FileAccess).close()
	elif FileAccess.file_exists(Impl.results_path()):
		DirAccess.remove_absolute(Impl.results_path())


func _user_files() -> Array:
	var dir := ProjectSettings.globalize_path(Impl.data_dir() + "/user")
	if not DirAccess.dir_exists_absolute(dir):
		return []
	return DirAccess.get_files_at(dir)


func _clean_user_jsons(before: Array) -> void:
	var base := ProjectSettings.globalize_path(Impl.data_dir() + "/user") + "/"
	for f in _user_files():
		if not before.has(f):
			DirAccess.remove_absolute(base + str(f))


## One user/*.json file as a Dictionary ({} when missing/unreadable).
func _read_user_json(file_name: String) -> Dictionary:
	var p := Impl.data_dir() + "/user/" + file_name
	if not FileAccess.file_exists(p):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(p))
	return parsed as Dictionary if parsed is Dictionary else {}


func _r_paths(h) -> void:
	h.check(Impl.results_path() == Impl.data_dir() + "/ScanResults.json", "results path under data dir")
	h.check(Impl.results_path().ends_with("ScanResults.json"), "results file name")
	h.check(Impl.data_dir() == "res://.godot/0GnumarusGodotProjectAnalyzerSuiteData", "data dir matches dumper layout")


func _r_empty(h) -> void:
	var doc := Impl.empty_doc()
	h.check(int(doc.get("version", 0)) == 1, "empty version")
	h.check((doc.get("errors", []) as Array).is_empty(), "empty errors")
	h.check((doc.get("warnings", []) as Array).is_empty(), "empty warnings")
	h.check(int((doc.get("summary", {}) as Dictionary).get("files", -1)) == 0, "empty summary files")


func _mk_issue(path: String, line: int, column: int, kind: String, sev := "error") -> Dictionary:
	return {"stage": "zz", "severity": sev, "kind": kind, "message": "m", "path": path, "line": line, "column": column}


func _r_store_merge(h) -> void:
	DirAccess.remove_absolute(Impl.results_path())
	var a_errors := [_mk_issue("res://b.gd", 2, 1, "k2"), _mk_issue("res://a.gd", 9, 1, "k1")]
	var doc_a: Dictionary = Impl.store_stage("zz_a", a_errors, [], 2)
	h.check(int(((doc_a.get("stages", {}) as Dictionary).get("zz_a", {}) as Dictionary).get("files", 0)) == 2, "stage files recorded")
	h.check((doc_a.get("errors", []) as Array).size() == 2, "stage errors aggregated")
	var doc_b: Dictionary = Impl.store_stage("zz_b", [], [_mk_issue("res://c.gd", 1, 0, "w", "warning")], 1)
	h.check(((doc_b.get("stages", {}) as Dictionary) as Dictionary).has("zz_a"), "second store keeps first stage")
	h.check(((doc_b.get("stages", {}) as Dictionary) as Dictionary).has("zz_b"), "second store adds stage")
	h.check((doc_b.get("errors", []) as Array).size() == 2, "aggregates keep errors")
	h.check((doc_b.get("warnings", []) as Array).size() == 1, "aggregates keep warnings")
	var summary: Dictionary = doc_b.get("summary", {})
	h.check(int(summary.get("files", 0)) == 3, "summary sums files")
	h.check(int(summary.get("errors", 0)) == 2 and int(summary.get("warnings", 0)) == 1, "summary counts issues")
	h.check(summary.get("stages", []) == ["zz_a", "zz_b"], "summary lists stages sorted")
	h.check(FileAccess.file_exists(Impl.results_path()), "report written to disk")
	var disk: Variant = JSON.parse_string(FileAccess.get_file_as_string(Impl.results_path()))
	h.check((disk is Dictionary) and int((disk as Dictionary).get("version", 0)) == 1, "disk report parses")
	DirAccess.remove_absolute(Impl.results_path())


func _r_sort(h) -> void:
	DirAccess.remove_absolute(Impl.results_path())
	var errs := [_mk_issue("res://b.gd", 1, 0, "k"), _mk_issue("res://a.gd", 5, 3, "k"), _mk_issue("res://a.gd", 5, 1, "k")]
	var doc: Dictionary = Impl.store_stage("zz_sort", errs, [], 1)
	var got: Array = doc.get("errors", [])
	h.check(str((got[0] as Dictionary).get("path", "")) == "res://a.gd" and int((got[0] as Dictionary).get("column", 0)) == 1, "sort path then column")
	h.check(str((got[1] as Dictionary).get("path", "")) == "res://a.gd" and int((got[1] as Dictionary).get("column", 0)) == 3, "sort column within line")
	h.check(str((got[2] as Dictionary).get("path", "")) == "res://b.gd", "sort path last")
	DirAccess.remove_absolute(Impl.results_path())


func _r_filters(h) -> void:
	DirAccess.remove_absolute(Impl.results_path())
	h.check((Impl.empty_doc().get("filters", {}) as Dictionary).get("show", {}) is Dictionary, "empty doc carries filters")
	var doc_a: Dictionary = Impl.store_stage("zz_keep", [_mk_issue("res://a.gd", 1, 0, "k")], [], 1)
	var doc_b: Dictionary = Impl.store_filters({"error": false, "warning": true, "note": true}, {"gd": true, "tscn": true, "tres": true, "godot": true, "other": true})
	h.check(((doc_b.get("stages", {}) as Dictionary) as Dictionary).has("zz_keep"), "store_filters keeps stages")
	h.check((doc_b.get("errors", []) as Array).size() == 1, "store_filters keeps aggregates")
	h.check(not bool((((doc_b.get("filters", {}) as Dictionary).get("show", {}) as Dictionary).get("error", true))), "store_filters stores toggles")
	h.check(str((((doc_b.get("filters", {}) as Dictionary).get("files", {}) as Dictionary).get("sort", ""))) == "path", "store_filters defaults files panel")
	var doc_c: Dictionary = Impl.store_filters({"error": true, "warning": true, "note": true}, {"gd": true, "tscn": true, "tres": true, "godot": true, "other": true}, {"include_addons": false, "sort": "size", "descending": true}, {"include_addons": true, "sort": "bogus", "descending": "yes"})
	h.check(not bool((((doc_c.get("filters", {}) as Dictionary).get("files", {}) as Dictionary).get("include_addons", true))), "store_filters stores files panel")
	h.check(str((((doc_c.get("filters", {}) as Dictionary).get("dirs", {}) as Dictionary).get("sort", ""))) == "path", "store_filters guards dirs sort")
	h.check(int((doc_a.get("summary", {}) as Dictionary).get("errors", 0)) == 1, "pre-filter summary intact")
	DirAccess.remove_absolute(Impl.results_path())


func _r_census(h) -> void:
	var grouped := Impl.census_of(["res://a.GD", "res://b.gd", "res://c.tscn", "res://LICENSE", "res://a.gd"])
	h.check(int((grouped.get("extensions", {}) as Dictionary).get("gd", 0)) == 3, "census groups case-insensitive")
	h.check(int((grouped.get("extensions", {}) as Dictionary).get("(no ext)", 0)) == 1, "census buckets extensionless")
	h.check(int(grouped.get("total", 0)) == 5, "census totals")
	var dotted_dirs := Impl.census_of(["res://my.dir/LICENSE", "res://my.dir/notes", "res://my.dir/readme.txt", "res://archive.tar.gz"])
	h.check(int((dotted_dirs.get("extensions", {}) as Dictionary).get("(no ext)", 0)) == 2, "census ignores dots in directories")
	h.check(int((dotted_dirs.get("extensions", {}) as Dictionary).get("txt", 0)) == 1, "census reads file name extension")
	h.check(int((dotted_dirs.get("extensions", {}) as Dictionary).get("gz", 0)) == 1, "census uses last name dot")
	h.check(Impl.census_of([]) == {"extensions": {}, "total": 0}, "census empty")
	h.check(Impl.census_ext("res://a.GD") == "gd", "census_ext lowercases")
	h.check(Impl.census_ext("res://my.dir/LICENSE") == "(no ext)", "census_ext ignores dir dots")
	h.check(Impl.human_size(0) == "0 B", "human zero bytes")
	h.check(Impl.human_size(512) == "512 B", "human bytes")
	h.check(Impl.human_size(1024) == "1.0 KB", "human kilobytes")
	h.check(Impl.human_size(1536) == "1.5 KB", "human fractional kilobytes")
	h.check(Impl.human_size(5 * 1024 * 1024) == "5.0 MB", "human megabytes")
	var real_stat := Impl.file_stat("res://addons/0GnumarusGodotProjectAnalyzerSuite/tests/ValidScript0.gd")
	h.check(int(real_stat.get("size", 0)) > 0, "file_stat reads size")
	h.check(int(real_stat.get("mtime", 0)) == 0, "file_stat has no mtime key")
	h.check(int(real_stat.get("modified", 0)) > 0, "file_stat reads modified")
	h.check(int(real_stat.get("created", -1)) == 0, "file_stat creation unavailable")
	h.check(Impl.file_stat("res://nope_missing_zz/Nope.gd") == {"size": 0, "created": 0, "modified": 0}, "file_stat missing zeros")
	var grp := Impl.census_group(["res://a.gd", "res://b.GD", "res://c.tscn"], Callable(self, "_stat_stub"))
	h.check(int(grp.get("total", 0)) == 3, "group counts")
	h.check(int((grp.get("extensions", {}) as Dictionary).get("gd", 0)) == 2, "group buckets")
	h.check(int(grp.get("bytes", 0)) == ("res://a.gd".length() + "res://b.GD".length() + "res://c.tscn".length()) * 100, "group sums bytes")
	h.check(str(grp.get("size", "")) == Impl.human_size(int(grp.get("bytes", 0))), "group stores human size")
	h.check(int(grp.get("newest", 0)) >= int(grp.get("oldest", 0)) and int(grp.get("oldest", 0)) > 0, "group orders mtimes")
	h.check(Impl.census_group([], Callable(self, "_stat_stub")) == {"extensions": {}, "total": 0, "bytes": 0, "size": "0 B", "newest": 0, "oldest": 0}, "group empty")
	var root := Impl.project_root()
	var files := Impl.collect_project_files(root)
	h.check(not files.is_empty(), "collect finds project files")
	var clean_walk := true
	for f in files:
		if not str(f).begins_with("res://") or "/.godot/" in str(f) or "/.git/" in str(f):
			clean_walk = false
	h.check(clean_walk, "collect skips generated dirs")
	h.check(Impl.collect_project_files("/nope_xyz_missing").is_empty(), "collect missing root empty")
	var census := Impl.collect_file_census(root)
	h.check(int(census.get("total", 0)) == files.size(), "census matches walk")
	h.check(int((census.get("extensions", {}) as Dictionary).get("gd", 0)) > 0, "census sees scripts")
	h.check(Impl.is_addons_path("res://addons/x.gd"), "addons file detected")
	h.check(Impl.is_addons_path("res://addons"), "addons dir itself detected")
	h.check(not Impl.is_addons_path("res://addons2/x.gd"), "addons prefix not confused")
	h.check(not Impl.is_addons_path("res://x.gd"), "plain file not addons")
	h.check(not Impl.is_addons_path(""), "empty not addons")
	var manual_addons := 0
	for f in files:
		if Impl.is_addons_path(str(f)):
			manual_addons += 1
	h.check(int((census.get("addons", {}) as Dictionary).get("total", -1)) == manual_addons, "addons partition matches walk")
	h.check(manual_addons > 0, "repo has addons files")
	var split_sum := int((census.get("project", {}) as Dictionary).get("total", -1)) + int((census.get("addons", {}) as Dictionary).get("total", -1))
	h.check(split_sum == int(census.get("total", -2)), "partitions sum to merged")
	h.check(int(census.get("bytes", 0)) == int((census.get("project", {}) as Dictionary).get("bytes", -1)) + int((census.get("addons", {}) as Dictionary).get("bytes", -1)), "bytes sum across partitions")
	h.check(int(census.get("bytes", 0)) > 0, "real census weighs bytes")
	h.check(int(census.get("newest", 0)) >= int(census.get("oldest", 0)) and int(census.get("oldest", 0)) > 0, "real census orders mtimes")
	h.check(str(census.get("size", "")) == Impl.human_size(int(census.get("bytes", 0))), "real census human size")
	DirAccess.remove_absolute(Impl.results_path())
	h.check((Impl.empty_doc().get("census", {}) as Dictionary).get("total", -1) == 0, "empty doc censused zero")
	Impl.store_stage("zz_keep", [_mk_issue("res://a.gd", 1, 0, "k")], [], 1)
	Impl.store_filters({"error": true, "warning": true, "note": true}, {"gd": true, "tscn": true, "tres": true, "godot": true, "other": true})
	var doc := Impl.store_census({"extensions": {"gd": 2}, "total": 2})
	h.check(((doc.get("stages", {}) as Dictionary) as Dictionary).has("zz_keep"), "store_census keeps stages")
	h.check(((doc.get("filters", {}) as Dictionary).get("show", {}) as Dictionary).has("error"), "store_census keeps filters")
	h.check(int((doc.get("census", {}) as Dictionary).get("total", 0)) == 2, "store_census stores")
	h.check((doc.get("census", {}) as Dictionary).get("project", {}) is Dictionary, "store_census normalizes partitions")
	var reloaded := Impl.store_census(census)
	h.check(int(((reloaded.get("census", {}) as Dictionary).get("addons", {}) as Dictionary).get("total", -1)) == manual_addons, "store_census persists addons partition")
	var disk: Variant = JSON.parse_string(FileAccess.get_file_as_string(Impl.results_path()))
	var disk_census: Dictionary = (disk as Dictionary).get("census", {})
	h.check(int((disk_census.get("project", {}) as Dictionary).get("total", -1)) == int(census.get("total", 0)) - manual_addons, "roundtrip project partition survives disk")
	h.check(int(disk_census.get("total", -1)) > int((disk_census.get("project", {}) as Dictionary).get("total", -2)), "roundtrip toggle-off view differs")
	h.check(int(disk_census.get("bytes", -1)) == int(census.get("bytes", -2)), "roundtrip bytes survive disk")
	h.check(int((disk_census.get("addons", {}) as Dictionary).get("newest", -1)) == int((census.get("addons", {}) as Dictionary).get("newest", -2)), "roundtrip mtimes survive disk")
	h.check(str(disk_census.get("size", "")) == str(census.get("size", "")), "roundtrip human size survives disk")
	DirAccess.remove_absolute(Impl.results_path())


func _r_inventory(h) -> void:
	h.check(Impl._parent_dir("res://a/b/c.gd") == "res://a/b", "parent strips file")
	h.check(Impl._parent_dir("res://x.gd") == "res://", "parent of root file is root")
	h.check(Impl._parent_dir("res://addons") == "res://", "parent of top dir is root")
	h.check(Impl._parent_dir("res://") == "", "root has no parent")
	h.check(Impl._parent_dir("") == "", "empty has no parent")
	var fentries := [
		{"path": "res://a/f1.gd", "size": 100, "created": 0, "modified": 1000},
		{"path": "res://a/f2.gd", "size": 300, "created": 0, "modified": 3000},
		{"path": "res://a/b/f3.gd", "size": 600, "created": 0, "modified": 2000},
	]
	var dentries := Impl.census_dir_entries(["res://", "res://a", "res://a/b", "res://empty"], fentries)
	h.check(dentries.size() == 4, "dir entries cover all dirs")
	h.check(str(dentries[0].get("path", "")) == "res://", "dir entries sorted by path")
	var by_path := {}
	for d in dentries:
		by_path[str((d as Dictionary).get("path", ""))] = d
	var ra: Dictionary = by_path.get("res://a", {})
	h.check(int(ra.get("files", -1)) == 2, "direct file count")
	h.check(int(ra.get("subdirs", -1)) == 1, "direct subdir count")
	h.check(int(ra.get("files_recursive", -1)) == 3, "recursive file count")
	h.check(int(ra.get("subdirs_recursive", -1)) == 1, "recursive subdir count")
	h.check(int(ra.get("size", -1)) == 400, "direct size sums direct files")
	h.check(int(ra.get("size_recursive", -1)) == 1000, "recursive size sums subtree")
	h.check(int((by_path.get("res://a/b", {}) as Dictionary).get("files_recursive", -1)) == 1, "leaf recursive equals direct")
	h.check(int((by_path.get("res://empty", {}) as Dictionary).get("size_recursive", -1)) == 0, "empty dir zeros")
	h.check(int((by_path.get("res://", {}) as Dictionary).get("files_recursive", -1)) == 3, "root rolls up everything")
	var root := Impl.project_root()
	var dirs := Impl.collect_project_dirs(root)
	h.check(dirs.has("res://"), "collect includes root")
	h.check(dirs.has("res://addons/0GnumarusGodotProjectAnalyzerSuite/tests"), "collect includes nested dir")
	h.check(not dirs.has("res://.godot"), "collect skips data dir")
	h.check(Impl.collect_project_dirs("/nope_xyz_missing").is_empty(), "collect dirs missing root empty")
	var inv := Impl.collect_file_census(root)
	h.check((inv.get("files", []) as Array).size() == int(inv.get("total", -1)), "inventory files match total")
	h.check(not (inv.get("dirs", []) as Array).is_empty(), "inventory lists dirs")
	var bad_shape := false
	for f in inv.get("files", []):
		if not ((f as Dictionary).has("path") and (f as Dictionary).has("size") and (f as Dictionary).has("created") and (f as Dictionary).has("modified")):
			bad_shape = true
	h.check(not bad_shape, "inventory file shape")
	var saw_created := false
	for f in inv.get("files", []):
		if (f as Dictionary).has("created"):
			saw_created = true
	h.check(saw_created, "inventory files carry created")
	var saw_dir_dates := false
	for dd in inv.get("dirs", []):
		if (dd as Dictionary).has("created") and (dd as Dictionary).has("modified"):
			saw_dir_dates = true
	h.check(saw_dir_dates, "inventory dirs carry dates")
	var rdoc := Impl.store_census(inv)
	h.check(((rdoc.get("census", {}) as Dictionary).get("files", []) as Array).size() == (inv.get("files", []) as Array).size(), "roundtrip keeps files")
	h.check(((rdoc.get("census", {}) as Dictionary).get("dirs", []) as Array).size() == (inv.get("dirs", []) as Array).size(), "roundtrip keeps dirs")


func _r_creation(h) -> void:
	h.check(Impl._os_path("/proj", "res://") == "/proj", "os path maps root")
	h.check(Impl._os_path("/proj", "res://a/b.gd") == "/proj/a/b.gd", "os path joins")
	h.check(Impl._os_path("/proj/", "res://a.gd") == "/proj/a.gd", "os path tolerates slash")
	h.check(Impl._parse_stat_pair("111|222") == [111, 222], "stat pair parses")
	h.check(Impl._parse_stat_pair("oops").is_empty(), "stat pair rejects garbage")
	h.check(Impl._parse_stat_pair("1|2|3").is_empty(), "stat pair rejects triples")
	h.check(Impl.creation_map([], Callable(self, "_fake_shell_ok")).is_empty(), "creation empty paths")
	_runner_calls.clear()
	var linux := Impl.creation_map_for("Linux", ["/a", "/bb"], Callable(self, "_fake_shell_ok"))
	h.check(str(_runner_calls[0][0]) == "stat" and "-c" in _runner_calls[0][1], "linux uses gnu stat")
	h.check(int((linux.get("/a", {}) as Dictionary).get("created", -1)) == 5002, "linux parses created")
	h.check(int((linux.get("/bb", {}) as Dictionary).get("modified", -1)) == 6003, "linux parses modified")
	_runner_calls.clear()
	var mac := Impl.creation_map_for("macOS", ["/a"], Callable(self, "_fake_shell_ok"))
	h.check(str(_runner_calls[0][0]) == "stat" and "-f" in _runner_calls[0][1], "macos uses bsd stat")
	h.check(int((mac.get("/a", {}) as Dictionary).get("created", -1)) == 5002, "macos parses created")
	_runner_calls.clear()
	var win := Impl.creation_map_for("Windows", [String("C:/a").replace("/", "\\")], Callable(self, "_fake_shell_ok"))
	h.check(str(_runner_calls[0][0]) == "powershell", "windows tries powershell first")
	h.check(not (win as Dictionary).is_empty(), "windows parses values")
	_runner_calls.clear()
	var fover := Impl.creation_map_for("Windows", ["/a"], Callable(self, "_fake_shell_failover"))
	h.check(not (fover as Dictionary).is_empty(), "windows falls back to pwsh")
	var exes := []
	for c in _runner_calls:
		exes.append(str((c as Array)[0]))
	h.check(exes == ["powershell", "pwsh"], "failover tries both shells")
	_runner_calls.clear()
	h.check(Impl.creation_map_for("Plan9", ["/a"], Callable(self, "_fake_shell_ok")).is_empty(), "unknown os degrades")
	h.check(_runner_calls.is_empty(), "unknown os spawns nothing")
	_runner_calls.clear()
	var retry := Impl._creation_map_stat(["/a", "/b", "/c"], Callable(self, "_fake_shell_fail"), true)
	h.check(retry.is_empty(), "failed batches stay empty")
	h.check(_runner_calls.size() == 4, "misshapen batch retries per file")
	_runner_calls.clear()
	Impl._creation_map_stat(["/a", "/b", "/c", "/d", "/e"], Callable(self, "_fake_shell_ok"), true, 2)
	h.check(_runner_calls.size() == 3, "chunking batches calls")
	h.check(Impl._parse_stat_pair("111|222\n") == [111, 222], "stat pair strips newline")
	h.check(Impl._parse_stat_pair("111|222\r\n") == [111, 222], "stat pair strips crlf")
	h.check(Impl._flatten_process_lines(["111|222\n333|444\n"]) == ["111|222", "333|444"], "flatten splits single blob")
	h.check(Impl._flatten_process_lines(["111|222", "333|444"]) == ["111|222", "333|444"], "flatten keeps per-line shape")
	h.check(Impl._flatten_process_lines(["111|222\r\n333|444\r\n"]) == ["111|222", "333|444"], "flatten strips carriage returns")
	_runner_calls.clear()
	var blob := Impl._creation_map_stat(["/a", "/bb"], Callable(self, "_fake_shell_blob"), true)
	h.check(int((blob.get("/a", {}) as Dictionary).get("created", -1)) == 5002, "single blob batch parses created")
	h.check(int((blob.get("/bb", {}) as Dictionary).get("modified", -1)) == 6003, "single blob batch parses modified")
	h.check(_runner_calls.size() == 1, "single blob needs no retry")
	_runner_calls.clear()
	var win_blob := Impl.creation_map_for("Windows", ["/a", "/bb"], Callable(self, "_fake_shell_blob"))
	h.check(int((win_blob.get("/a", {}) as Dictionary).get("created", -1)) == 5002, "windows single blob parses")
	var fentries := [{"path": "res://a.gd", "size": 10, "created": 0, "modified": 100}]
	var dentries: Array = Impl.census_dir_entries(["res://b", "res://a"], fentries)
	Impl._enrich_creation("/proj", ["res://a.gd"], fentries, ["res://b", "res://a"], dentries, Callable(self, "_fake_lookup"))
	var by_dir := {}
	for d in dentries:
		by_dir[str((d as Dictionary).get("path", ""))] = d
	h.check(int((by_dir.get("res://a", {}) as Dictionary).get("created", 0)) == 7000 + "/proj/a".length(), "enrich maps dirs by path")
	h.check(int((by_dir.get("res://b", {}) as Dictionary).get("modified", 0)) == 8000 + "/proj/b".length(), "enrich maps sorted dirs")
	h.check(int((fentries[0] as Dictionary).get("created", 0)) == 7000 + "/proj/a.gd".length(), "enrich fills file created")


func _r_embedded(h) -> void:
	h.check(SemParser.embedded_base("res://a/b/c.tscn", "SceneRoot/d/e", "GDScript_06whq") == "a_b_c.tscn_SceneRoot_d_e", "embedded base matches spec example")
	h.check(SemParser.embedded_base("res://a/b/c.tscn", "", "GDScript_zz") == "a_b_c.tscn_GDScript_zz", "embedded orphan falls back to sub id")
	h.check(SemParser.embedded_base("res://a\\b\\c.tscn", "R\\d", "") == "a_b_c.tscn_R_d", "embedded base handles backslashes")
	h.check(SemParser.embedded_base("", "", "") == "embedded", "embedded base never empty")
	h.check(Impl.embedded_enabled({"embedded": true}), "embedded opts pin on")
	h.check(not Impl.embedded_enabled({"embedded": false}), "embedded opts pin off")
	var key := Impl.SETTING_EMBEDDED
	var had := ProjectSettings.has_setting(key)
	var prev: Variant = ProjectSettings.get_setting(key, true)
	ProjectSettings.set_setting(key, true)
	h.check(Impl.embedded_enabled({}), "embedded default analyzes")
	ProjectSettings.set_setting(key, false)
	h.check(not Impl.embedded_enabled({}), "embedded setting opts out")
	if had:
		ProjectSettings.set_setting(key, prev)
	else:
		ProjectSettings.set_setting(key, true)
	var tagged: Dictionary = Impl._tag(Impl.STAGE_INTEGRITY, {"severity": "error", "kind": "return_mismatch", "message": "m", "line": 3, "column": 1, "path": "res://a/b/c.tscn", "scene": "res://a/b/c.tscn", "node": "SceneRoot/e", "embedded_base": "a_b_c.tscn_SceneRoot_e", "embedded_sub": "GDScript_06whq", "scene_line": 4}, "res://a/b/c.tscn")
	h.check(str(tagged.get("node", "")) == "SceneRoot/e" and str(tagged.get("embedded_base", "")) == "a_b_c.tscn_SceneRoot_e", "tag preserves embedded extras")
	h.check(int(tagged.get("scene_line", 0)) == 4, "tag preserves scene line")
	var plain: Dictionary = Impl._tag(Impl.STAGE_INTEGRITY, {"severity": "error", "kind": "k", "message": "m", "line": 1, "column": 0}, "res://x.tscn")
	h.check(not (plain as Dictionary).has("node"), "tag adds no extras unasked")
	var sa := _mk_issue("res://x.tscn", 3, 1, "k")
	sa["node"] = "R/B"
	var sb := _mk_issue("res://x.tscn", 3, 1, "k")
	sb["node"] = "R/A"
	var sorted: Array = [sa, sb]
	sorted.sort_custom(Impl._issue_less)
	h.check(str((sorted[0] as Dictionary).get("node", "")) == "R/A", "sort breaks embedded ties by node")
	var before := _user_files()
	var bad_text := "[gd_scene format=3 uid=\"uid://bo2qscigvkjxo\"]\n\n[sub_resource type=\"GDScript\" id=\"GDScript_06whq\"]\nscript/source = \"extends Node\\n# @return int\\nfunc f() -> String:\\n\\treturn 1\\nclass Inner:\\n\\tvar y := 1\\n\"\n\n[node name=\"SceneRoot\" type=\"Node\"]\n\n[node name=\"e\" type=\"Node\" parent=\".\"]\nscript = SubResource(\"GDScript_06whq\")\n"
	var emb: Dictionary = Impl.new().analyze_embedded_text("res://a/b/c.tscn", bad_text, {"embedded": true})
	var errs: Array = emb.get("errors", [])
	h.check(errs.size() == 1 and str((errs[0] as Dictionary).get("kind", "")) == "return_mismatch", "embedded analysis reports script error")
	h.check(str((errs[0] as Dictionary).get("path", "")) == "res://a/b/c.tscn", "embedded issue path is the scene")
	h.check(str((errs[0] as Dictionary).get("node", "")) == "SceneRoot/e", "embedded issue carries node")
	h.check(str((errs[0] as Dictionary).get("embedded_base", "")) == "a_b_c.tscn_SceneRoot_e", "embedded issue carries base")
	h.check(int((errs[0] as Dictionary).get("scene_line", 0)) == 4, "embedded issue carries scene line")
	var fresh: Array = []
	for f in _user_files():
		if not before.has(f):
			fresh.append(str(f))
	h.check("a_b_c.tscn_SceneRoot_e.json" in fresh, "embedded root json named per spec")
	h.check("a_b_c.tscn_SceneRoot_e.Inner.json" in fresh, "embedded inner json dotted")
	var root_json := _read_user_json("a_b_c.tscn_SceneRoot_e.json")
	h.check(str(root_json.get("resource_path", "")) == "res://a/b/c.tscn", "embedded root json stores scene path")
	h.check(str(root_json.get("node_path", "")) == "SceneRoot/e", "embedded root json stores node path")
	var inner_json := _read_user_json("a_b_c.tscn_SceneRoot_e.Inner.json")
	h.check(str(inner_json.get("resource_path", "")) == "res://a/b/c.tscn", "embedded inner json stores scene path")
	h.check(str(inner_json.get("node_path", "")) == "SceneRoot/e", "embedded inner json stores node path")
	_clean_user_jsons(before)
	var clean: Dictionary = Impl.new().analyze_embedded_text("res://a/b/c.tscn", "[gd_scene format=3]\n\n[node name=\"R\" type=\"Node\"]\n", {"embedded": true})
	h.check((clean.get("errors", []) as Array).is_empty() and (clean.get("warnings", []) as Array).is_empty(), "embedded scriptless clean")
	h.check((Impl.new().analyze_embedded_text("", bad_text, {}) as Dictionary).get("errors", []).is_empty(), "embedded empty path safe")
	_clean_user_jsons(before)
	var tup_text := "[gd_scene format=3]\n\n[sub_resource type=\"GDScript\" id=\"g\"]\nscript/source = \"extends Node\\n# @tuple EmbNodeTup 1 int\\n# @var x EmbNodeTup\\nvar x: Array = [1]\\n\"\n\n[node name=\"R\" type=\"Node\"]\n\n[node name=\"e\" type=\"Node\" parent=\".\"]\nscript = SubResource(\"g\")\n"
	Impl.new().analyze_embedded_text("res://a/b/c.tscn", tup_text, {"embedded": true})
	var tup_json := _read_user_json("EmbNodeTup.json")
	h.check(str(tup_json.get("resource_path", "")) == "res://a/b/c.tscn", "embedded tuple json stores scene path")
	h.check(str(tup_json.get("node_path", "")) == "R/e", "embedded tuple json stores node path")
	_clean_user_jsons(before)
	var sem_before := _user_files()
	SemParser.new().analyze(SynParser.new().parse_text("extends Node\nclass Inner:\n\tvar y := 1\n"), "res://a/b/c.tscn", "a_b_c.tscn_SceneRoot_e", "SceneRoot/e")
	var sem_root := _read_user_json("a_b_c.tscn_SceneRoot_e.json")
	h.check(str(sem_root.get("resource_path", "")) == "res://a/b/c.tscn", "semantic json stores scene path")
	h.check(str(sem_root.get("node_path", "")) == "SceneRoot/e", "semantic json stores node path")
	var sem_inner := _read_user_json("a_b_c.tscn_SceneRoot_e.Inner.json")
	h.check(str(sem_inner.get("node_path", "")) == "SceneRoot/e", "semantic inner json stores node path")
	_clean_user_jsons(sem_before)


func _r_corrupt(h) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(Impl.data_dir()))
	var f := FileAccess.open(Impl.results_path(), FileAccess.WRITE)
	(f as FileAccess).store_string("not json {{{")
	(f as FileAccess).close()
	var doc := Impl.load_results()
	h.check((doc.get("errors", []) as Array).is_empty() and ((doc.get("stages", {}) as Dictionary) as Dictionary).is_empty(), "corrupt report falls back empty")
	var doc2: Dictionary = Impl.store_stage("zz_after_corrupt", [], [], 0)
	h.check(((doc2.get("stages", {}) as Dictionary) as Dictionary).has("zz_after_corrupt"), "store recovers from corrupt")
	DirAccess.remove_absolute(Impl.results_path())


func _write_tmp() -> void:
	var f := FileAccess.open(TMP_GD, FileAccess.WRITE)
	(f as FileAccess).store_string("extends Node\nconst ANSWER := 42\nfunc f() -> int:\n\treturn ANSWER\n")
	(f as FileAccess).close()


func _r_gdscript_stage(h) -> void:
	var before := _user_files()
	_write_tmp()
	var doc: Dictionary = Impl.new().run_gdscript("", [TMP_GD])
	var entry: Dictionary = ((doc.get("stages", {}) as Dictionary).get(Impl.STAGE_GDSCRIPT, {}))
	h.check(int(entry.get("files", 0)) == 1, "gdscript stage counts file")
	h.check(((entry.get("errors", []) as Array) as Array).is_empty(), "tmp script analyzer-clean")
	h.check(((entry.get("warnings", []) as Array) as Array).is_empty(), "tmp script warning-clean")
	for e in doc.get("errors", []):
		h.check(str((e as Dictionary).get("stage", "")) == Impl.STAGE_GDSCRIPT, "gdscript issues tagged")
	var tmp_json := _read_user_json("addons_0GnumarusGodotProjectAnalyzerSuite_tests_TmpFullScanTarget.json")
	h.check(str(tmp_json.get("resource_path", "")) == TMP_GD, "file json stores source path")
	h.check(str(tmp_json.get("node_path", "")) == "", "file json stores empty node path")
	DirAccess.remove_absolute(TMP_GD)
	_clean_user_jsons(before)


func _r_integrity_stage(h) -> void:
	_write_tmp()
	var doc: Dictionary = Impl.new().run_integrity("", [TMP_GD], {}, {}, Callable(self, "_exists"))
	var entry: Dictionary = ((doc.get("stages", {}) as Dictionary).get(Impl.STAGE_INTEGRITY, {}))
	h.check(int(entry.get("files", 0)) == 1, "integrity stage counts file")
	h.check(((entry.get("errors", []) as Array) as Array).is_empty(), "tmp script integrity-clean")
	DirAccess.remove_absolute(TMP_GD)


func _r_proxy(h) -> void:
	var proxy_text := FileAccess.get_file_as_string(PROXY_PATH)
	h.check("@tool" in proxy_text, "proxy is tool")
	h.check("extends EditorScript" in proxy_text, "proxy extends EditorScript")
	h.check("func _run" in proxy_text, "proxy implements _run")
	h.check("FullScanImpl" in proxy_text, "proxy forwards to impl")
	var scr: Variant = load(PROXY_PATH)
	h.check(scr is Script, "proxy loads as script")
	h.check((scr as Script).is_tool(), "proxy script is tool")
	h.check((scr as Script).get_instance_base_type() == "EditorScript", "proxy base is EditorScript")
	var found_run := false
	for m in (scr as Script).get_script_method_list():
		if str((m as Dictionary).get("name", "")) == "_run":
			found_run = true
	h.check(found_run, "proxy declares _run")
	var impl_text := FileAccess.get_file_as_string(IMPL_PATH)
	h.check("extends RefCounted" in impl_text, "impl is RefCounted")
	h.check(not ("@tool" in impl_text), "impl not tool")
	h.check(not ("extends EditorScript" in impl_text), "impl free of EditorScript")
	h.check(not ("extends EditorPlugin" in impl_text), "impl free of EditorPlugin")


func _r_menu(h) -> void:
	h.check(PluginImpl.FULL_SCAN_MENU == "Gnumaru's Full Scan", "menu name")
	var impl = PluginImpl.new(null)
	h.check(impl.has_method("_on_full_scan_menu"), "menu callback exists")
	impl.enter_tree()
	h.check(not impl._tool_menu_added, "headless adds no menu")
	impl._remove_tool_menu()
	h.check(not impl._tool_menu_added, "remove without add stays calm")
	impl.exit_tree()
	h.check(not impl._tool_menu_added, "exit without menu stays calm")
