# @integrity_ignore_file (test harness uses virtual paths)
extends RefCounted

## Scan-worker suite: the background pool mechanics (dispatch, done,
## cancel, wait — real WorkerThreadPool, trivial tasks only, so no
## analyzer statics are touched), the FullScan opts/cancel plumbs on
## a hermetic target, and the plugin-impl glue null-safety
## headless (dispatch stays quiet, _process safe, filesystem events
## during a worker only flag). The real ScanResults.json is backed
## up and restored, and user JSONs from stage runs are removed.

const Worker = preload("res://addons/0GnumarusGodotProjectAnalyzerSuite/GnumarusGodotProjectAnalyzerSuiteScanWorker.gd")
const Impl = preload("res://addons/0GnumarusGodotProjectAnalyzerSuite/GnumarusGodotProjectAnalyzerSuitePluginImpl.gd")
const FullScan = preload("res://addons/0GnumarusGodotProjectAnalyzerSuite/GnumarusGodotProjectAnalyzerSuiteFullScanImpl.gd")
const H = preload("res://addons/0GnumarusGodotProjectAnalyzerSuite/tests/helpers.gd")

const TMP_GD := "res://addons/0GnumarusGodotProjectAnalyzerSuite/tests/TmpScanWorkerTarget.gd"

var _backup := ""
var _had_backup := false
var _task_seen := 0


func _task_count() -> void:
	_task_seen += 1


func run() -> Dictionary:
	var h = H.new()
	h.suite = "scan_worker"
	_backup_results()
	_r_mechanics(h)
	_r_fullscan_plumbs(h)
	_r_impl_glue(h)
	_restore_results()
	return h.result()


func _backup_results() -> void:
	_had_backup = FileAccess.file_exists(FullScan.results_path())
	_backup = FileAccess.get_file_as_string(FullScan.results_path()) if _had_backup else ""


func _restore_results() -> void:
	if _had_backup:
		var f := FileAccess.open(FullScan.results_path(), FileAccess.WRITE)
		if f != null:
			(f as FileAccess).store_string(_backup)
			(f as FileAccess).close()
	elif FileAccess.file_exists(FullScan.results_path()):
		DirAccess.remove_absolute(FullScan.results_path())


func _user_files() -> Array:
	var dir := ProjectSettings.globalize_path(FullScan.data_dir() + "/user")
	if not DirAccess.dir_exists_absolute(dir):
		return []
	return DirAccess.get_files_at(dir)


func _clean_user_jsons(before: Array) -> void:
	var base := ProjectSettings.globalize_path(FullScan.data_dir() + "/user") + "/"
	for f in _user_files():
		if not before.has(f):
			DirAccess.remove_absolute(base + str(f))


func _r_mechanics(h) -> void:
	_task_seen = 0
	var w := Worker.new()
	h.check(not w.is_done(), "fresh worker not done")
	h.check(not w.is_cancelled(), "fresh worker not cancelled")
	h.check(w.kind == "", "fresh worker kind empty")
	w.cancel()
	h.check(w.is_cancelled(), "cancel flag sticks")
	var w2 := Worker.new()
	var id := w2.dispatch(Callable(self, "_task_count"), "test")
	h.check(id >= 0, "dispatch returns a task id")
	h.check(w2.kind == "test", "kind recorded")
	w2.wait_done()
	h.check(w2.is_done(), "task completes")
	h.check(_task_seen == 1, "task body ran once")
	var w3 := Worker.new()
	w3.dispatch(Callable(self, "_task_count"), "test")
	w3.cancel()
	w3.wait_done()
	h.check(w3.is_done(), "cancelled task still terminates")
	h.check(_task_seen >= 1, "cancel race stays sane")


func _write_tmp() -> void:
	var f := FileAccess.open(TMP_GD, FileAccess.WRITE)
	(f as FileAccess).store_string("extends Node\nconst ANSWER := 42\nfunc f() -> int:\n\treturn ANSWER\n")
	(f as FileAccess).close()


func _never() -> bool:
	return true


func _r_fullscan_plumbs(h) -> void:
	var snap := FullScan.policy_snapshot()
	h.check((snap as Dictionary).has("policy") and (snap as Dictionary).has("strict"), "snapshot carries policy keys")
	var before := _user_files()
	_write_tmp()
	var doc: Dictionary = FullScan.new().run_gdscript("", [TMP_GD], snap)
	var entry: Dictionary = ((doc.get("stages", {}) as Dictionary).get(FullScan.STAGE_GDSCRIPT, {}))
	h.check(int(entry.get("files", 0)) == 1, "opts stage counts file")
	h.check(((entry.get("errors", []) as Array) as Array).is_empty(), "opts stage clean")
	var cancelled: Dictionary = FullScan.new().run_gdscript("", [TMP_GD], snap, Callable(self, "_never"))
	h.check(bool(cancelled.get("cancelled", false)), "cancel aborts the stage")
	h.check(not (((cancelled as Dictionary).get("stages", {}) as Dictionary) as Dictionary).has(FullScan.STAGE_GDSCRIPT), "cancel stores no stage")
	DirAccess.remove_absolute(TMP_GD)
	_clean_user_jsons(before)


func _r_impl_glue(h) -> void:
	h.check(not Impl._worker_available() or Engine.has_singleton("WorkerThreadPool"), "pool predicate consistent")
	var impl = Impl.new(null)
	h.check(not impl._use_worker(), "headless never uses the worker")
	impl._dispatch_warm()
	h.check(impl._worker == null, "headless warm dispatch stays quiet")
	impl._dispatch_full()
	h.check(impl._worker == null, "headless full dispatch stays quiet")
	impl._process(0.016)
	h.check(true, "process without worker safe")
	impl._worker = Worker.new()
	impl._on_filesystem_changed()
	h.check(not impl._warm_restart, "fs change during worker starts no warm")
	h.check(impl._fs_dirty, "fs change during worker dirties live pass")
	h.check(impl._warm_pending.is_empty(), "fs change during worker starts nothing")
	impl._worker = null
	impl.exit_tree()
	h.check(impl._worker == null, "exit drops worker")
