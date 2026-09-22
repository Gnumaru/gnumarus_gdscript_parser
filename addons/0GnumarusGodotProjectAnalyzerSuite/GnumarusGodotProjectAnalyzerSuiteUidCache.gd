class_name GnumarusGodotProjectAnalyzerSuiteUidCache
extends RefCounted

## Reader for Godot's UID cache (.godot/uid_cache.bin).
##
## The engine caches the UID of every resource in a binary file with a
## tiny layout (see ResourceUID::save/load in core/io/resource_uid.cpp):
## uint32 LE entry count, then per entry int64 LE id, int32 LE UTF-8
## byte length, and the raw path bytes (no terminator). IDs convert to
## the familiar "uid://" text as base-34 (alphabet a-y, 0-8; 'z' and
## '9' are never used) masked to 63 bits.
##
## Result shape (plain Array/Dictionary, easy to manipulate):
## {
##   "entries": [{"id": int, "uid": String, "path": String}],
##   "by_uid": {"uid://...": "res://..."},
##   "by_path": {"res://...": "uid://..."},
##   "errors": int,
##   "error_list": [{"message": String}],
##   "path": String,  # input file, "" for parse_bytes()
## }
##
## Usage with the project cache:
##   var cache := GnumarusGodotProjectAnalyzerSuiteUidCache.new().parse("res://.godot/uid_cache.bin")
##   print(cache["by_path"].get("res://addons/0GnumarusGodotProjectAnalyzerSuite/tests/Node3D.tscn", ""))
## Usage with raw bytes (hermetic tests):
##   var cache := GnumarusGodotProjectAnalyzerSuiteUidCache.new().parse_bytes(bytes)

## UID text alphabet (base 34): a-y then 0-8.
const UID_ALPHABET := "abcdefghijklmnopqrstuvwxy012345678"
const UID_BASE := 34
const UID_MASK := 0x7FFFFFFFFFFFFFFF
const INVALID_ID := -1

## Last failure message ("" when the previous parse had zero errors).
var last_error := ""


## Converts a numeric UID id to "uid://..." text. Negative ids give
## "uid://<invalid>", mirroring the engine.
static func id_to_text(id: int) -> String:
	if id < 0:
		return "uid://<invalid>"
	var digits := ""
	var rest := id
	while true:
		digits = UID_ALPHABET.substr(rest % UID_BASE, 1) + digits
		rest = rest / UID_BASE
		if rest == 0:
			break
	return "uid://" + digits


## Converts "uid://..." text to a numeric id, or -1 when malformed.
static func text_to_id(uid_text: String) -> int:
	if not uid_text.begins_with("uid://") or uid_text == "uid://<invalid>":
		return INVALID_ID
	var uid := 0
	for i in range(6, uid_text.length()):
		var c := uid_text.substr(i, 1)
		var digit := UID_ALPHABET.find(c)
		if digit < 0:
			return INVALID_ID
		uid = uid * UID_BASE + digit
	return uid & UID_MASK


## Parses the cache file at path. Missing/unreadable files yield
## errors == 1 instead of crashing.
func parse(path: String) -> Dictionary:
	last_error = ""
	if not FileAccess.file_exists(path):
		last_error = "UID cache not found: " + path
		push_error(last_error)
		return _empty_result(path)
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		last_error = "Cannot open UID cache: " + path
		push_error(last_error)
		return _empty_result(path)
	var data := file.get_buffer(file.get_length())
	return parse_bytes(data, path)


## Parses raw cache bytes. The same instance may be reused: every call
## resets the error state, so results never leak. Truncated tails are
## reported as errors while keeping the entries decoded so far.
func parse_bytes(data: PackedByteArray, path: String = "") -> Dictionary:
	last_error = ""
	var errors := 0
	var error_list: Array = []
	var entries: Array = []
	var by_uid := {}
	var by_path := {}
	if data.size() < 4:
		errors += 1
		error_list.append({"message": "UID cache too short for entry count"})
		last_error = str(error_list[0].get("message", ""))
		return _result(entries, by_uid, by_path, errors, error_list, path)
	var count := _u32(data, 0)
	var off := 4
	for i in range(count):
		if off + 12 > data.size():
			errors += 1
			error_list.append({"message": "UID cache truncated at entry " + str(i)})
			break
		var id := _i64(data, off)
		var length := _i32(data, off + 8)
		off += 12
		if length < 0 or off + length > data.size():
			errors += 1
			error_list.append({"message": "UID cache bad path length at entry " + str(i)})
			break
		var raw := data.slice(off, off + length)
		off += length
		var res_path := raw.get_string_from_utf8()
		var uid := id_to_text(id)
		entries.append({"id": id, "uid": uid, "path": res_path})
		by_uid[uid] = res_path
		by_path[res_path] = uid
	if errors > 0:
		last_error = str(error_list[0].get("message", ""))
	return _result(entries, by_uid, by_path, errors, error_list, path)


## Encodes one cache entry the way the engine writes it. Test helper
## for building synthetic cache bytes (count header included).
static func encode_entry(id: int, res_path: String) -> PackedByteArray:
	var out := PackedByteArray()
	out.append_array(_put_u64(id))
	var raw := res_path.to_utf8_buffer()
	out.append_array(_put_u32(raw.size()))
	out.append_array(raw)
	return out


static func _put_u32(v: int) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(4)
	out.encode_u32(0, v)
	return out


static func _put_u64(v: int) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(8)
	out.encode_u64(0, v)
	return out


func _u32(data: PackedByteArray, at: int) -> int:
	return data.decode_u32(at)


func _i32(data: PackedByteArray, at: int) -> int:
	return data.decode_s32(at)


func _i64(data: PackedByteArray, at: int) -> int:
	return data.decode_s64(at)


func _empty_result(path: String) -> Dictionary:
	return _result([], {}, {}, 1, [{"message": last_error}], path)


func _result(entries: Array, by_uid: Dictionary, by_path: Dictionary, errors: int, error_list: Array, path: String) -> Dictionary:
	return {
		"entries": entries,
		"by_uid": by_uid,
		"by_path": by_path,
		"errors": errors,
		"error_list": error_list,
		"path": path,
	}
