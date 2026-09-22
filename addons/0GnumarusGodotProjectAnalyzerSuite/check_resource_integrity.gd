extends SceneTree

## Standalone CLI for resource integrity (report-only).
##
## Checks every .tscn/.tres plus res://project.godot plus every .gd
## (or the res:// paths given as user args): referenced files must
## exist, UIDs must be well-formed and present in
## .godot/uid_cache.bin, and cache entries must point at existing
## files. .gd files contribute only their preload()/load() literals.
## Prints per-file progress (`checking [i/n] path`) plus one
## `path:line:column: kind message` line per issue, then a summary.
## Never writes anything.
##
## Usage (from the project root):
##   godot --headless --path . --script res://addons/0GnumarusGodotProjectAnalyzerSuite/check_resource_integrity.gd
##   godot --headless --path . --script res://addons/0GnumarusGodotProjectAnalyzerSuite/check_resource_integrity.gd -- res://addons/0GnumarusGodotProjectAnalyzerSuite/tests/Node3D.tscn
##
## Exits 0 when clean, 1 when issues found, 2 on infra failure.

const Checker = preload("res://addons/0GnumarusGodotProjectAnalyzerSuite/GnumarusGodotProjectAnalyzerSuiteResourceIntegrity.gd")
const Uid = preload("res://addons/0GnumarusGodotProjectAnalyzerSuite/GnumarusGodotProjectAnalyzerSuiteUidCache.gd")

const CACHE := "res://.godot/uid_cache.bin"


func _init() -> void:
	_run()


func _run() -> void:
	var root := ProjectSettings.globalize_path("res://")
	if root.ends_with("/") and root.length() > 1:
		root = root.substr(0, root.length() - 1)
	var targets: Array = []
	for a in OS.get_cmdline_user_args():
		if str(a).begins_with("res://"):
			targets.append(str(a))
	if targets.is_empty():
		targets = Checker.collect_text_resources(root) + Checker.collect_gd_scripts(root)
		targets.sort()
	if targets.is_empty():
		print("No resources found.")
		quit(0)
		return
	var by_uid := {}
	var by_path := {}
	if FileAccess.file_exists(CACHE):
		var cache := Uid.new().parse(CACHE)
		by_uid = cache.get("by_uid", {})
		by_path = cache.get("by_path", {})
		if int(cache.get("errors", 0)) > 0:
			printerr("WARNING: uid cache unreadable (" + str(cache.get("error_list", [])[0].get("message", "")) + "); uid checks skipped.")
			by_uid = {}
			by_path = {}
	else:
		print("WARNING: uid cache not found (" + CACHE + "); uid checks skipped.")
	var checker = Checker.new()
	var err_total := 0
	var warn_total := 0
	var i := 0
	for t in targets:
		i += 1
		print("checking [" + str(i) + "/" + str(targets.size()) + "] " + str(t))
		var res: Dictionary = checker.analyze_gd_file(str(t), by_uid, by_path) if str(t).ends_with(".gd") else checker.analyze_file(str(t), by_uid, by_path)
		for e in res.get("errors", []):
			err_total += 1
			print(_fmt(e, t))
		for w in res.get("warnings", []):
			warn_total += 1
			print(_fmt(w, t))
	print("INTEGRITY: " + str(targets.size()) + " files, " + str(err_total) + " errors, " + str(warn_total) + " warnings")
	quit(1 if err_total > 0 else 0)


func _fmt(issue: Variant, fallback_path: String) -> String:
	var d := issue as Dictionary
	return str(d.get("path", fallback_path)) + ":" + str(d.get("line", 1)) + ":" + str(d.get("column", 1)) + ": " + str(d.get("kind", "")) + " " + str(d.get("message", ""))
