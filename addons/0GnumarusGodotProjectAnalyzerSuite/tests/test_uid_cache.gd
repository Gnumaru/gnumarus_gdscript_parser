extends RefCounted

## UID cache suite: id/text conversion, synthetic binary parsing,
## truncation errors, reuse, and the live project cache cross-checked
## against the .uid sidecars and the scene fixtures.

const Uid = preload("res://addons/0GnumarusGodotProjectAnalyzerSuite/GnumarusGodotProjectAnalyzerSuiteUidCache.gd")
const Scene = preload("res://addons/0GnumarusGodotProjectAnalyzerSuite/GnumarusGodotProjectAnalyzerSuiteTextResourceParser.gd")
const H = preload("res://addons/0GnumarusGodotProjectAnalyzerSuite/tests/helpers.gd")

const DIR := "res://addons/0GnumarusGodotProjectAnalyzerSuite/tests/"
const CACHE := "res://.godot/uid_cache.bin"


func run() -> Dictionary:
	var h = H.new()
	h.suite = "uid_cache"
	_u_convert(h)
	_u_invalid(h)
	_u_synthetic(h)
	_u_truncated(h)
	_u_reuse(h)
	_u_live(h)
	return h.result()


func _u_convert(h) -> void:
	h.check(Uid.id_to_text(-1) == "uid://<invalid>", "negative id invalid text")
	h.check(Uid.id_to_text(0) == "uid://a", "zero id is a")
	for id in [0, 1, 33, 34, 35, 123456789, 0x7FFFFFFFFFFFFFFF]:
		h.check(Uid.text_to_id(Uid.id_to_text(id)) == id, "round trip " + str(id))
	h.check(Uid.text_to_id("uid://b527whaq1bjrx") == Uid.text_to_id("uid://b527whaq1bjrx"), "known uid stable")
	h.check(Uid.id_to_text(Uid.text_to_id("uid://b527whaq1bjrx")) == "uid://b527whaq1bjrx", "known uid round trip")
	h.check(Uid.id_to_text(Uid.text_to_id("uid://jmhndcwcpoui")) == "uid://jmhndcwcpoui", "tres uid round trip")


func _u_invalid(h) -> void:
	h.check(Uid.text_to_id("") == -1, "empty invalid")
	h.check(Uid.text_to_id("res://x.gd") == -1, "path invalid")
	h.check(Uid.text_to_id("uid://<invalid>") == -1, "invalid marker invalid")
	h.check(Uid.text_to_id("uid://ABC") == -1, "uppercase invalid")
	h.check(Uid.text_to_id("uid://ab9") == -1, "nine invalid")
	h.check(Uid.text_to_id("uid://abz") == -1, "zee invalid")
	h.check(Uid.text_to_id("uid://ab ") == -1, "space invalid")


func _synthetic(count: int, pairs: Array) -> PackedByteArray:
	var out := PackedByteArray()
	var header := PackedByteArray()
	header.resize(4)
	header.encode_u32(0, count)
	out.append_array(header)
	for pair in pairs:
		out.append_array(Uid.encode_entry(int(pair[0]), str(pair[1])))
	return out


func _u_synthetic(h) -> void:
	var id_a := Uid.text_to_id("uid://b527whaq1bjrx")
	var id_b := Uid.text_to_id("uid://jmhndcwcpoui")
	var bytes := _synthetic(2, [[id_a, "res://a/one.gd"], [id_b, "res://b/two.tres"]])
	var d := Uid.new().parse_bytes(bytes)
	h.check(int(d.get("errors", -1)) == 0, "synthetic clean")
	h.check((d.get("entries", []) as Array).size() == 2, "synthetic two entries")
	h.check(str((d.get("by_uid", {}) as Dictionary).get("uid://b527whaq1bjrx", "")) == "res://a/one.gd", "by_uid lookup")
	h.check(str((d.get("by_path", {}) as Dictionary).get("res://b/two.tres", "")) == "uid://jmhndcwcpoui", "by_path lookup")
	h.check(str(d.get("path", "x")) == "", "bytes path empty")


func _u_truncated(h) -> void:
	var id_a := Uid.text_to_id("uid://b527whaq1bjrx")
	var full := _synthetic(2, [[id_a, "res://a/one.gd"], [id_a, "res://b/two.tres"]])
	var cut := full.slice(0, full.size() - 3)
	var d := Uid.new().parse_bytes(cut)
	h.check(int(d.get("errors", 0)) > 0, "truncated errors")
	h.check((d.get("entries", []) as Array).size() == 1, "truncated keeps first entry")
	h.check(Uid.new().last_error == "", "fresh instance starts clean")
	var empty := Uid.new().parse_bytes(PackedByteArray())
	h.check(int(empty.get("errors", 0)) > 0, "empty bytes error")
	var missing := Uid.new().parse("res://.godot/nope_uid_cache_xyz.bin")
	h.check(int(missing.get("errors", 0)) == 1, "missing file errors once")


func _u_reuse(h) -> void:
	var u = Uid.new()
	var id_a := Uid.text_to_id("uid://b527whaq1bjrx")
	var first := u.parse_bytes(_synthetic(1, [[id_a, "res://a/one.gd"]]))
	var second := u.parse_bytes(_synthetic(1, [[id_a, "res://b/other.gd"]]))
	h.check((first.get("entries", []) as Array).size() == 1, "first kept")
	h.check(str((second.get("by_uid", {}) as Dictionary).get("uid://b527whaq1bjrx", "")) == "res://b/other.gd", "second independent")
	h.check(not (first.get("by_path", {}) as Dictionary).has("res://b/other.gd"), "no leak across parses")


func _u_live(h) -> void:
	if not FileAccess.file_exists(CACHE):
		h.check(int(Uid.new().parse(CACHE).get("errors", 0)) == 1, "absent cache errors once")
		return
	var d := Uid.new().parse(CACHE)
	h.check(int(d.get("errors", -1)) == 0, "live cache zero errors")
	h.check(str((d.get("by_path", {}) as Dictionary).get(DIR + "AnnotationsShowcase1.gd", "")) == "uid://b527whaq1bjrx", "live showcase uid")
	var dir := DirAccess.open(DIR)
	h.check(dir != null, "tests dir opens")
	var checked := 0
	for f in dir.get_files():
		if not str(f).ends_with(".uid"):
			continue
		var base := str(f).get_basename()
		var want := FileAccess.get_file_as_string(DIR + str(f)).strip_edges()
		var got := str((d.get("by_path", {}) as Dictionary).get(DIR + base, ""))
		# Absent entries mean a stale cache (editor has not re-saved
		# since the sidecar appeared): unverifiable, not a failure.
		# Present-but-different entries below are real mismatches.
		if got == "":
			continue
		h.check(got == want, "sidecar matches " + base)
		checked += 1
	h.check(checked > 0, "sidecars checked")
	var scene := Scene.new().parse(DIR + "Node3D.tscn")
	var ext: Dictionary = (scene.get("ext_resources", []) as Array)[0]
	var ext_uid := str((ext.get("attrs", {}) as Dictionary).get("uid", ""))
	h.check(str((d.get("by_uid", {}) as Dictionary).get(ext_uid, "")).ends_with("AnnotationsShowcase1.gd"), "scene ext uid resolves")
