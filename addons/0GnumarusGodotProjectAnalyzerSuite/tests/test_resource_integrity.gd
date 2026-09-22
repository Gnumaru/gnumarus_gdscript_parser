# @integrity_ignore_file (test harness uses virtual paths)
extends RefCounted

## Resource integrity suite (phase 1, report-only): ext_resource
## path/uid validation against stub existence + synthetic uid maps,
## dangling/duplicate/unused ids, bare string refs, header uids,
## project-style globals, reuse, collect and unreadable files.

const RI = preload("res://addons/0GnumarusGodotProjectAnalyzerSuite/GnumarusGodotProjectAnalyzerSuiteResourceIntegrity.gd")
const H = preload("res://addons/0GnumarusGodotProjectAnalyzerSuite/tests/helpers.gd")

const DIR := "res://addons/0GnumarusGodotProjectAnalyzerSuite/tests/"
const GOOD_PATH := "res://addons/0GnumarusGodotProjectAnalyzerSuite/tests/AnnotationsShowcase1.gd"
const OTHER_PATH := "res://addons/0GnumarusGodotProjectAnalyzerSuite/tests/ValidScript0.gd"
const GOOD_UID := "uid://b527whaq1bjrx"
const OTHER_UID := "uid://cpxjs8g0lkytr"

var _existing := {}
var _sidecars := {}


func _exists(p: String) -> bool:
	return bool(_existing.get(p, false))


func _read(p: String) -> String:
	return str(_sidecars.get(p, ""))


func run() -> Dictionary:
	var h = H.new()
	h.suite = "resource_integrity"
	_r_clean(h)
	_r_missing_file(h)
	_r_uid(h)
	_r_ids(h)
	_r_bare_strings(h)
	_r_project_globals(h)
	_r_header(h)
	_r_sidecar(h)
	_r_gd(h)
	_r_gd_strings(h)
	_r_gd_refs(h)
	_r_reuse(h)
	_r_collect(h)
	_r_unreadable(h)
	return h.result()


func _checker() -> RefCounted:
	_existing = {GOOD_PATH: true, OTHER_PATH: true}
	_sidecars = {}
	return RI.new()


func _maps(uid: String = GOOD_UID, path: String = GOOD_PATH) -> Array:
	return [{uid: path}, {path: uid}]


func _errs(res: Dictionary, kind: String) -> Array:
	var out: Array = []
	for e in res.get("errors", []):
		if str((e as Dictionary).get("kind", "")) == kind:
			out.append(e)
	return out


func _warns(res: Dictionary, kind: String) -> Array:
	var out: Array = []
	for w in res.get("warnings", []):
		if str((w as Dictionary).get("kind", "")) == kind:
			out.append(w)
	return out


func _clean_text() -> String:
	return "[gd_scene format=3]\n\n[ext_resource type=\"Script\" path=\"" + GOOD_PATH + "\" uid=\"" + GOOD_UID + "\" id=\"1\"]\n\n[sub_resource type=\"Environment\" id=\"env\"]\n\n[node name=\"N\" type=\"Node\"]\nscript = ExtResource(\"1\")\nenv_prop = SubResource(\"env\")\n"


func _r_clean(h) -> void:
	var c := _checker()
	var maps := _maps()
	var res: Dictionary = c.analyze_text(_clean_text(), "res://x.tscn", maps[0], maps[1], Callable(self, "_exists"), Callable(self, "_read"))
	h.check((res.get("errors", []) as Array).is_empty(), "clean zero errors")
	h.check((res.get("warnings", []) as Array).is_empty(), "clean zero warnings")
	h.check(str(res.get("path", "")) == "res://x.tscn", "path echoed")


func _r_missing_file(h) -> void:
	var c := _checker()
	var maps := _maps()
	var bad := "[gd_scene format=3]\n\n[ext_resource type=\"Script\" path=\"res://addons/0GnumarusGodotProjectAnalyzerSuite/tests/NopeXyz.gd\" id=\"1\"]\n\n[node name=\"N\" type=\"Node\"]\nscript = ExtResource(\"1\")\nicon = \"res://nope/icon.png\"\n"
	var res: Dictionary = c.analyze_text(bad, "res://x.tscn", maps[0], maps[1], Callable(self, "_exists"), Callable(self, "_read"))
	h.check(_errs(res, "missing_file").size() == 2, "ext path plus bare string missing")
	h.check(int((_errs(res, "missing_file")[0] as Dictionary).get("line", 0)) == 3, "ext missing on entry line")


func _r_uid(h) -> void:
	var c := _checker()
	var maps := _maps()
	var mal := "[gd_scene format=3]\n\n[ext_resource type=\"Script\" path=\"" + GOOD_PATH + "\" uid=\"uid://AB9\" id=\"1\"]\n\n[node name=\"N\" type=\"Node\"]\nscript = ExtResource(\"1\")\n"
	h.check(_errs(c.analyze_text(mal, "res://x.tscn", maps[0], maps[1], Callable(self, "_exists"), Callable(self, "_read")), "malformed_uid").size() == 1, "malformed ext uid")
	var miss := "[gd_scene format=3]\n\n[ext_resource type=\"Script\" path=\"" + GOOD_PATH + "\" uid=\"" + OTHER_UID + "\" id=\"1\"]\n\n[node name=\"N\" type=\"Node\"]\nscript = ExtResource(\"1\")\n"
	h.check(_errs(c.analyze_text(miss, "res://x.tscn", maps[0], maps[1], Callable(self, "_exists"), Callable(self, "_read")), "missing_uid").size() == 1, "unknown uid missing")
	h.check(_errs(c.analyze_text(miss, "res://x.tscn", {}, {}, Callable(self, "_exists"), Callable(self, "_read")), "missing_uid").is_empty(), "empty maps skip uid presence")
	var stale_maps := [{GOOD_UID: "res://gone/missing.gd"}, {GOOD_PATH: GOOD_UID}]
	h.check(_errs(c.analyze_text(_clean_text(), "res://x.tscn", stale_maps[0], stale_maps[1], Callable(self, "_exists"), Callable(self, "_read")), "uid_path_mismatch").size() == 1, "stale uid target")
	var redir_maps := [{GOOD_UID: OTHER_PATH}, {GOOD_PATH: GOOD_UID}]
	h.check(_errs(c.analyze_text(_clean_text(), "res://x.tscn", redir_maps[0], redir_maps[1], Callable(self, "_exists"), Callable(self, "_read")), "uid_path_mismatch").size() == 1, "uid target differs from declared path")
	var pathdiv_maps := [{GOOD_UID: GOOD_PATH}, {GOOD_PATH: OTHER_UID}]
	h.check(_errs(c.analyze_text(_clean_text(), "res://x.tscn", pathdiv_maps[0], pathdiv_maps[1], Callable(self, "_exists"), Callable(self, "_read")), "path_uid_mismatch").size() == 1, "cache path uid differs from declared")


func _r_ids(h) -> void:
	var c := _checker()
	var maps := _maps()
	var dang := "[gd_scene format=3]\n\n[ext_resource type=\"Script\" path=\"" + GOOD_PATH + "\" id=\"1\"]\n\n[node name=\"N\" type=\"Node\"]\nscript = ExtResource(\"nope\")\nthing = SubResource(\"ghost\")\n"
	var res: Dictionary = c.analyze_text(dang, "res://x.tscn", maps[0], maps[1], Callable(self, "_exists"), Callable(self, "_read"))
	h.check(_errs(res, "dangling_ext_id").size() == 1, "dangling ext id")
	h.check(_errs(res, "dangling_subresource").size() == 1, "dangling sub id")
	h.check(_warns(res, "unused_ext_resource").size() == 1, "declared ext unused warns")
	var dup := "[gd_scene format=3]\n\n[ext_resource type=\"Script\" path=\"" + GOOD_PATH + "\" id=\"1\"]\n\n[ext_resource type=\"Script\" path=\"" + OTHER_PATH + "\" id=\"1\"]\n"
	h.check(_errs(c.analyze_text(dup, "res://x.tscn", maps[0], maps[1], Callable(self, "_exists"), Callable(self, "_read")), "duplicate_ext_id").size() == 1, "duplicate ext id")
	var dsub := "[gd_resource type=\"Environment\" format=3]\n\n[sub_resource type=\"Sky\" id=\"s\"]\n\n[sub_resource type=\"Sky\" id=\"s\"]\n"
	h.check(_errs(c.analyze_text(dsub, "res://x.tres", maps[0], maps[1], Callable(self, "_exists"), Callable(self, "_read")), "duplicate_subresource").size() == 1, "duplicate sub id")
	var noid := "[gd_scene format=3]\n\n[ext_resource type=\"Script\" path=\"" + GOOD_PATH + "\"]\n"
	h.check(_errs(c.analyze_text(noid, "res://x.tscn", maps[0], maps[1], Callable(self, "_exists"), Callable(self, "_read")), "malformed_ext_resource").size() == 1, "ext without id")


func _r_bare_strings(h) -> void:
	var c := _checker()
	var maps := _maps()
	var bare := "[resource]\nicon = \"" + GOOD_PATH + "\"\nmissing = \"res://gone/icon.png\"\nref = \"" + OTHER_UID + "\"\nbad = \"uid://AB9\"\n"
	var res: Dictionary = c.analyze_text(bare, "res://x.tres", maps[0], maps[1], Callable(self, "_exists"), Callable(self, "_read"))
	h.check(_errs(res, "missing_file").size() == 1, "bare missing path errors once")
	h.check(_errs(res, "missing_uid").size() == 1, "bare unknown uid errors once")
	h.check(_errs(res, "malformed_uid").size() == 1, "bare malformed uid errors once")
	var code := "[sub_resource type=\"GDScript\" id=\"g\"]\nscript/source = \"extends Node\nvar p = \\\"res://gone/from_code.gd\\\"\n\"\n"
	h.check(_errs(c.analyze_text(code, "res://x.tscn", maps[0], maps[1], Callable(self, "_exists"), Callable(self, "_read")), "missing_file").is_empty(), "multiline code strings skipped")
	var frag := "[resource]\nnote = \"see res://gone/in_sentence for details\"\n"
	h.check(_errs(c.analyze_text(frag, "res://x.tres", maps[0], maps[1], Callable(self, "_exists"), Callable(self, "_read")), "missing_file").is_empty(), "sentence fragments skipped")


func _r_project_globals(h) -> void:
	var c := _checker()
	var maps := _maps()
	var proj := "config_version=5\n\n[application]\nconfig/main_scene=\"res://gone/main.tscn\"\nconfig/icon=\"" + GOOD_PATH + "\"\n"
	var res: Dictionary = c.analyze_text(proj, "res://project.godot", maps[0], maps[1], Callable(self, "_exists"), Callable(self, "_read"))
	h.check(_errs(res, "missing_file").size() == 1, "project globals checked")


func _r_header(h) -> void:
	var c := _checker()
	var maps := _maps()
	var bad := "[gd_scene format=3 uid=\"uid://AB9\"]\n"
	h.check(_errs(c.analyze_text(bad, "res://x.tscn", maps[0], maps[1], Callable(self, "_exists"), Callable(self, "_read")), "malformed_uid").size() == 1, "header malformed uid")
	var ok := "[gd_scene format=3 uid=\"" + GOOD_UID + "\"]\n"
	h.check(_errs(c.analyze_text(ok, "res://x.tscn", {}, {}, Callable(self, "_exists"), Callable(self, "_read")), "malformed_uid").is_empty(), "header well-formed ok")


func _r_reuse(h) -> void:
	var c := _checker()
	var maps := _maps()
	var bad := "[gd_scene format=3]\n\n[ext_resource type=\"Script\" path=\"res://gone/x.gd\" id=\"1\"]\n\n[node name=\"N\" type=\"Node\"]\nscript = ExtResource(\"1\")\n"
	var first: Dictionary = c.analyze_text(bad, "res://x.tscn", maps[0], maps[1], Callable(self, "_exists"), Callable(self, "_read"))
	var second: Dictionary = c.analyze_text(_clean_text(), "res://x.tscn", maps[0], maps[1], Callable(self, "_exists"), Callable(self, "_read"))
	h.check(_errs(first, "missing_file").size() == 1, "first kept")
	h.check((second.get("errors", []) as Array).is_empty(), "reuse independent")
	h.check(c.last_error == "", "clean resets last_error")


func _r_collect(h) -> void:
	var root := ProjectSettings.globalize_path("res://")
	if root.ends_with("/") and root.length() > 1:
		root = root.substr(0, root.length() - 1)
	var got := RI.collect_text_resources(root)
	h.check(got.has("res://project.godot"), "collect includes project.godot")
	h.check(got.has(DIR + "Node3D.tscn"), "collect includes fixture tscn")
	h.check(RI.collect_text_resources("/nope_xyz_missing").is_empty(), "collect missing root empty")


func _r_unreadable(h) -> void:
	var c := _checker()
	var maps := _maps()
	var res: Dictionary = c.analyze_file("res://addons/0GnumarusGodotProjectAnalyzerSuite/tests/NopeXyz123.tscn", maps[0], maps[1], Callable(self, "_exists"), Callable(self, "_read"))
	h.check(_errs(res, "unreadable").size() == 1, "unreadable errors once")
	h.check(c.last_error != "", "last_error set on unreadable")


func _r_sidecar(h) -> void:
	var c := _checker()
	var maps := _maps()
	var scar := GOOD_PATH + ".uid"
	_sidecars = {scar: GOOD_UID}
	var res: Dictionary = c.analyze_text(_clean_text(), "res://x.tscn", maps[0], maps[1], Callable(self, "_exists"), Callable(self, "_read"))
	h.check(_errs(res, "sidecar_mismatch").is_empty(), "agreeing sidecar clean")
	h.check((res.get("errors", []) as Array).is_empty(), "agreeing sidecar zero errors")
	h.check(_errs(c.analyze_text(_clean_text(), "res://x.tscn", {}, {}, Callable(self, "_exists"), Callable(self, "_read")), "sidecar_mismatch").is_empty(), "agreement verifiable without cache")
	_sidecars = {scar: OTHER_UID}
	h.check(_errs(c.analyze_text(_clean_text(), "res://x.tscn", maps[0], maps[1], Callable(self, "_exists"), Callable(self, "_read")), "sidecar_mismatch").size() == 1, "disagreeing sidecar errors with cache")
	h.check(_errs(c.analyze_text(_clean_text(), "res://x.tscn", {}, {}, Callable(self, "_exists"), Callable(self, "_read")), "sidecar_mismatch").size() == 1, "disagreeing sidecar errors without cache")
	_sidecars = {scar: GOOD_UID}
	var thin := [{OTHER_UID: OTHER_PATH}, {OTHER_PATH: OTHER_UID}]
	var stale: Dictionary = c.analyze_text(_clean_text(), "res://x.tscn", thin[0], thin[1], Callable(self, "_exists"), Callable(self, "_read"))
	h.check(_errs(stale, "missing_uid").is_empty(), "agreeing sidecar downgrades missing uid")
	h.check(_errs(stale, "sidecar_mismatch").is_empty(), "agreeing sidecar no mismatch")
	h.check(_warns(stale, "stale_cache").size() == 1, "agreeing sidecar warns stale cache")
	_sidecars = {scar: OTHER_UID}
	var wrong: Dictionary = c.analyze_text(_clean_text(), "res://x.tscn", thin[0], thin[1], Callable(self, "_exists"), Callable(self, "_read"))
	h.check(_errs(wrong, "sidecar_mismatch").size() == 1, "disagreeing sidecar explains cache miss")
	h.check(_errs(wrong, "missing_uid").is_empty(), "disagreeing sidecar replaces missing uid")
	_sidecars = {}
	h.check(_errs(c.analyze_text(_clean_text(), "res://x.tscn", thin[0], thin[1], Callable(self, "_exists"), Callable(self, "_read")), "missing_uid").size() == 1, "no sidecar keeps missing uid")
	var nopath := "[gd_scene format=3]\n\n[ext_resource type=\"Script\" path=\"" + GOOD_PATH + "\" id=\"1\"]\n\n[node name=\"N\" type=\"Node\"]\nscript = ExtResource(\"1\")\n"
	_sidecars = {scar: GOOD_UID}
	h.check(_errs(c.analyze_text(nopath, "res://x.tscn", maps[0], maps[1], Callable(self, "_exists"), Callable(self, "_read")), "sidecar_mismatch").is_empty(), "path-only ref ignores sidecar")
	var self_path := "res://x_self.tscn"
	var self_text := "[gd_scene format=3 uid=\"" + GOOD_UID + "\"]\n"
	_sidecars = {(self_path + ".uid"): GOOD_UID}
	h.check(_errs(c.analyze_text(self_text, self_path, maps[0], maps[1], Callable(self, "_exists"), Callable(self, "_read")), "sidecar_mismatch").is_empty(), "self agreement clean")
	_sidecars = {(self_path + ".uid"): OTHER_UID}
	h.check(_errs(c.analyze_text(self_text, self_path, maps[0], maps[1], Callable(self, "_exists"), Callable(self, "_read")), "sidecar_mismatch").size() == 1, "self disagreement errors")
	_sidecars = {}
	h.check(_errs(c.analyze_text(self_text, self_path, maps[0], maps[1], Callable(self, "_exists"), Callable(self, "_read")), "sidecar_mismatch").is_empty(), "self without sidecar clean")
	_sidecars = {}


func _r_gd(h) -> void:
	var c := _checker()
	var maps := _maps()
	var clean := "extends Node\nconst A := preload('" + GOOD_PATH + "')\nfunc f() -> void:\n\tvar s := load(\"" + OTHER_PATH + "\")\n\tvar u := ResourceLoader.load(\"" + GOOD_UID + "\")\n"
	var res: Dictionary = c.analyze_gd_text(clean, "res://x.gd", maps[0], maps[1], Callable(self, "_exists"))
	h.check((res.get("errors", []) as Array).is_empty(), "gd clean zero errors")
	h.check((res.get("warnings", []) as Array).is_empty(), "gd clean zero warnings")
	var missing := "extends Node\nconst A := preload(\"res://gone/nope.gd\")\n"
	var mres: Dictionary = c.analyze_gd_text(missing, "res://x.gd", maps[0], maps[1], Callable(self, "_exists"))
	h.check(_errs(mres, "missing_file").size() == 1, "gd missing preload errors")
	h.check(int((_errs(mres, "missing_file")[0] as Dictionary).get("line", 0)) == 2, "gd missing on literal line")
	h.check(int((_errs(mres, "missing_file")[0] as Dictionary).get("column", 0)) > 0, "gd missing carries column")
	h.check(c.last_error != "", "gd last_error set")
	var comment := "# preload(\"res://gone/fake.gd\")\nextends Node\nvar s := \"res://gone/plain_string.gd\"\n"
	var cres: Dictionary = c.analyze_gd_text(comment, "res://x.gd", maps[0], maps[1], Callable(self, "_exists"))
	var cmsgs := []
	for e in cres.get("errors", []):
		cmsgs.append(str((e as Dictionary).get("message", "")))
	h.check(_errs(cres, "missing_file").size() == 2, "gd comments and plain strings scanned")
	h.check(cmsgs.any(func(m: String) -> bool: return m.begins_with("Comment ")), "gd comment labeled")
	h.check(cmsgs.any(func(m: String) -> bool: return m.begins_with("String ")), "gd plain string labeled")
	var dyn := "extends Node\nfunc f() -> void:\n\tvar a := load(\"res://\" + name)\n\tvar b := load(\"res://gone/\" + \"part.gd\")\n"
	h.check((c.analyze_gd_text(dyn, "res://x.gd", maps[0], maps[1], Callable(self, "_exists")).get("errors", []) as Array).is_empty(), "gd concatenation fragments skipped")
	var custom := "extends Node\nfunc f() -> void:\n\tvar x := loader.load(\"res://gone/custom.gd\")\n\tvar y := ResourceLoader.exists(\"res://gone/other.gd\")\n"
	var customres: Dictionary = c.analyze_gd_text(custom, "res://x.gd", maps[0], maps[1], Callable(self, "_exists"))
	h.check(_errs(customres, "missing_file").size() == 1, "gd custom load scanned, probe skipped")
	h.check(str((_errs(customres, "missing_file")[0] as Dictionary).get("message", "")).begins_with("String "), "gd custom load uses plain label")
	var probe := "extends Node\nfunc f() -> bool:\n\treturn FileAccess.file_exists(\"res://gone/probed.gd\") or DirAccess.dir_exists_absolute(\"res://gone/dir\")\n"
	h.check((c.analyze_gd_text(probe, "res://x.gd", maps[0], maps[1], Callable(self, "_exists")).get("errors", []) as Array).is_empty(), "gd existence probes skipped")
	var uidmiss := "extends Node\nfunc f() -> void:\n\tvar u := load(\"" + OTHER_UID + "\")\n"
	h.check(_errs(c.analyze_gd_text(uidmiss, "res://x.gd", maps[0], maps[1], Callable(self, "_exists")), "missing_uid").size() == 1, "gd unknown uid missing")
	h.check(_errs(c.analyze_gd_text(uidmiss, "res://x.gd", {}, {}, Callable(self, "_exists")), "missing_uid").is_empty(), "gd empty maps skip uid presence")
	var uidbad := "extends Node\nfunc f() -> void:\n\tvar u := load(\"uid://AB9\")\n"
	h.check(_errs(c.analyze_gd_text(uidbad, "res://x.gd", maps[0], maps[1], Callable(self, "_exists")), "malformed_uid").size() == 1, "gd malformed uid")
	var stale := "extends Node\nfunc f() -> void:\n\tvar u := load(\"" + GOOD_UID + "\")\n"
	_existing = {GOOD_PATH: false}
	var sres: Dictionary = c.analyze_gd_text(stale, "res://x.gd", maps[0], maps[1], Callable(self, "_exists"))
	_existing = {GOOD_PATH: true, OTHER_PATH: true}
	h.check(_errs(sres, "uid_path_mismatch").size() == 1, "gd stale uid target")
	var reuse_bad: Dictionary = c.analyze_gd_text(missing, "res://x.gd", maps[0], maps[1], Callable(self, "_exists"))
	var reuse_ok: Dictionary = c.analyze_gd_text(clean, "res://x.gd", maps[0], maps[1], Callable(self, "_exists"))
	h.check(_errs(reuse_bad, "missing_file").size() == 1, "gd first kept")
	h.check((reuse_ok.get("errors", []) as Array).is_empty(), "gd reuse independent")
	var root := ProjectSettings.globalize_path("res://")
	if root.ends_with("/") and root.length() > 1:
		root = root.substr(0, root.length() - 1)
	var got := RI.collect_gd_scripts(root)
	h.check(got.has(DIR + "ValidScript0.gd"), "gd collect includes fixture script")
	h.check(not got.has(DIR + "Node3D.tscn"), "gd collect excludes scenes")
	h.check(RI.collect_gd_scripts("/nope_xyz_missing").is_empty(), "gd collect missing root empty")
	var gunread: Dictionary = c.analyze_gd_file("res://addons/0GnumarusGodotProjectAnalyzerSuite/tests/NopeXyz123.gd", maps[0], maps[1], Callable(self, "_exists"))
	h.check(_errs(gunread, "unreadable").size() == 1, "gd unreadable errors once")


func _r_gd_strings(h) -> void:
	var c := _checker()
	var maps := _maps()
	var triple := "extends Node\nvar c := \"\"\"see res://gone/triple.tscn.\"\"\"\n"
	var tres: Dictionary = c.analyze_gd_text(triple, "res://x.gd", maps[0], maps[1], Callable(self, "_exists"))
	h.check(_errs(tres, "missing_file").size() == 1, "gd triple-quoted scanned")
	h.check("res://gone/triple.tscn" in str((_errs(tres, "missing_file")[0] as Dictionary).get("message", "")), "gd sentence period stripped")
	h.check(int((_errs(tres, "missing_file")[0] as Dictionary).get("line", 0)) == 2, "gd embedded line")
	h.check(int((_errs(tres, "missing_file")[0] as Dictionary).get("column", 0)) > 0, "gd embedded column")
	var single := "extends Node\nvar a := 'res://gone/single.tscn'\n"
	h.check(_errs(c.analyze_gd_text(single, "res://x.gd", maps[0], maps[1], Callable(self, "_exists")), "missing_file").size() == 1, "gd single-quoted scanned")
	var second := "extends Node\nfunc f() -> void:\n\tfoo(\"ok\", \"res://gone/second.tscn\")\n"
	h.check(_errs(c.analyze_gd_text(second, "res://x.gd", maps[0], maps[1], Callable(self, "_exists")), "missing_file").size() == 1, "gd non-first arg scanned")
	var fmt := "extends Node\nfunc f() -> void:\n\tvar s := \"res://gone/%s.tscn\" % name\n"
	h.check((c.analyze_gd_text(fmt, "res://x.gd", maps[0], maps[1], Callable(self, "_exists")).get("errors", []) as Array).is_empty(), "gd format operand skipped")
	var meta := "extends Node\nvar s := \"example: \\\"res://gone/meta.tscn\\\" end\"\n"
	h.check((c.analyze_gd_text(meta, "res://x.gd", maps[0], maps[1], Callable(self, "_exists")).get("errors", []) as Array).is_empty(), "gd escaped meta skipped")
	var uidstr := "extends Node\nvar u := \"ref " + OTHER_UID + " here\"\n"
	h.check(_errs(c.analyze_gd_text(uidstr, "res://x.gd", maps[0], maps[1], Callable(self, "_exists")), "missing_uid").size() == 1, "gd embedded uid scanned")
	var linesuf := "extends Node\n# broke at res://gone/logged.tscn:10:4 yesterday\n"
	var lres: Dictionary = c.analyze_gd_text(linesuf, "res://x.gd", maps[0], maps[1], Callable(self, "_exists"))
	h.check(_errs(lres, "missing_file").size() == 1, "gd path:line suffix scanned")
	h.check("res://gone/logged.tscn" in str((_errs(lres, "missing_file")[0] as Dictionary).get("message", "")) and ":10" not in str((_errs(lres, "missing_file")[0] as Dictionary).get("message", "")), "gd path:line suffix stripped")
	var doc := "## Example: checker.analyze_file(\"res://gone/doc.tscn\")\nextends Node\n"
	var dres: Dictionary = c.analyze_gd_text(doc, "res://x.gd", maps[0], maps[1], Callable(self, "_exists"))
	h.check(_errs(dres, "missing_file").size() == 1, "gd doc comments scanned")
	h.check(str((_errs(dres, "missing_file")[0] as Dictionary).get("message", "")).begins_with("Comment "), "gd doc comment labeled")
	var ignline := "extends Node\nvar s := \"res://gone/ignored.tscn\" # @integrity_ignore\nvar t := \"res://gone/kept.tscn\"\n"
	var ignres: Dictionary = c.analyze_gd_text(ignline, "res://x.gd", maps[0], maps[1], Callable(self, "_exists"))
	h.check(_errs(ignres, "missing_file").size() == 1, "gd line ignore drops its line only")
	h.check("res://gone/kept.tscn" in str((_errs(ignres, "missing_file")[0] as Dictionary).get("message", "")), "gd line ignore keeps other lines")
	var ignfile := "# @integrity_ignore_file\nextends Node\nvar s := \"res://gone/anything.tscn\"\n"
	h.check((c.analyze_gd_text(ignfile, "res://x.gd", maps[0], maps[1], Callable(self, "_exists")).get("errors", []) as Array).is_empty(), "gd file ignore exempts")
	var latemarker := "extends Node\n# @integrity_ignore_file\nvar s := \"res://gone/late.tscn\"\n"
	h.check(_errs(c.analyze_gd_text(latemarker, "res://x.gd", maps[0], maps[1], Callable(self, "_exists")), "missing_file").size() == 1, "gd late file marker ignored")


func _r_gd_refs(h) -> void:
	var c := _checker()
	var maps := _maps()
	var ok := "@icon(\"" + GOOD_PATH + "\")\nextends \"" + OTHER_PATH + "\"\n"
	h.check((c.analyze_gd_text(ok, "res://x.gd", maps[0], maps[1], Callable(self, "_exists")).get("errors", []) as Array).is_empty(), "gd extends and icon clean")
	var badext := "extends \"res://gone/base.gd\"\n"
	var eres: Dictionary = c.analyze_gd_text(badext, "res://x.gd", maps[0], maps[1], Callable(self, "_exists"))
	h.check(_errs(eres, "missing_file").size() == 1, "gd missing extends errors")
	h.check("Extended" in str((_errs(eres, "missing_file")[0] as Dictionary).get("message", "")), "gd extends message labeled")
	var badicon := "@icon(\"res://gone/icon.svg\")\nextends Node\n"
	var ires: Dictionary = c.analyze_gd_text(badicon, "res://x.gd", maps[0], maps[1], Callable(self, "_exists"))
	h.check(_errs(ires, "missing_file").size() == 1, "gd missing icon errors")
	h.check(int((_errs(ires, "missing_file")[0] as Dictionary).get("line", 0)) == 1, "gd icon on annotation line")
	var ident := "extends Node\n"
	h.check((c.analyze_gd_text(ident, "res://x.gd", maps[0], maps[1], Callable(self, "_exists")).get("errors", []) as Array).is_empty(), "gd identifier extends skipped")
	var other := "@warning_ignore(\"res://gone/not_a_path.gd\")\nextends Node\n"
	var otherres: Dictionary = c.analyze_gd_text(other, "res://x.gd", maps[0], maps[1], Callable(self, "_exists"))
	h.check(_errs(otherres, "missing_file").size() == 1, "gd other annotations scanned as plain strings")
	h.check(str((_errs(otherres, "missing_file")[0] as Dictionary).get("message", "")).begins_with("String "), "gd other annotations use plain label")
	var iconuid := "@icon(\"" + OTHER_UID + "\")\nextends Node\n"
	h.check(_errs(c.analyze_gd_text(iconuid, "res://x.gd", maps[0], maps[1], Callable(self, "_exists")), "missing_uid").size() == 1, "gd icon unknown uid missing")
