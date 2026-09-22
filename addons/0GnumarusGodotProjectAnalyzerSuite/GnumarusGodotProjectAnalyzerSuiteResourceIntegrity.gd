class_name GnumarusGodotProjectAnalyzerSuiteResourceIntegrity
extends RefCounted

## Integrity checker for textual Godot resources (.tscn, .tres,
## project.godot and any other file in the same INI-like format) plus
## every static resource string in GDScript (.gd).
##
## Report-only: walks each file looking for resource paths (res://...)
## and UIDs (uid://...) and validates them: referenced files must
## exist, UIDs must be well-formed and present in uid_cache.bin, and a
## cache entry must point at an existing file (an [ext_resource]
## declaring both path and uid must agree with the cache). Dangling
## ExtResource()/SubResource() ids, duplicate ids and malformed
## entries are reported too; declared-but-never-used ext_resource ids
## are warnings.
##
## Deliberately separate from the GDScript analyzer (which owns
## inference, not file references): this stage owns no inference, no
## JSON output and no Editor dependency, so it stays headless-runnable
## and hermetic. .gd files are scanned at the token level (never
## parsed): trigger literals (preload("..."), bare load("..."),
## ResourceLoader.load("..."), extends "...", \@icon("...")) keep
## their labeled checks, and every other static string — assignments,
## call args, any quoting (single, double, triple-double) — plus
## every comment is scanned for embedded references at in-token
## positions. Only dynamic content stays out: concatenation/format
## operands ("res://" + name, "res://%s" % x), custom obj.load()
## calls, bare prefixes and backslash-escaped meta content (example
## code nested in an outer string).
##
## Result shape (mirrors the gdscript analyzer split):
## {
##   "errors": [{"severity": "error", "kind": String, "message": String,
##               "line": int, "column": int, "path": String}],
##   "warnings": [... same shape, severity "warning" ...],
##   "path": String,
## }
## (.gd issues carry real token columns; text-resource issues use
## column 1, which the scene parser does not track.)
## Error kinds: parse_error, unreadable, missing_file, malformed_uid,
## missing_uid, uid_path_mismatch, path_uid_mismatch, sidecar_mismatch,
## malformed_ext_resource, duplicate_ext_id, duplicate_subresource,
## dangling_ext_id, dangling_subresource.
## Warning kinds: unused_ext_resource, stale_cache.
##
## `.uid` sidecars (the engine-written `<resource>.uid` files) are the
## third source of truth, after the filesystem and uid_cache.bin. They
## only validate path-anchored references (the file's own header uid
## and [ext_resource] entries): a declared uid disagreeing with the
## sidecar of its path is a sidecar_mismatch error even when the cache
## is absent, and a uid missing from the cache whose sidecar agrees is
## only a stale_cache warning (stale cache, correct file) instead of a
## missing_uid error. Bare uid://... strings have no path anchor, so
## sidecars cannot validate them. Malformed or unreadable sidecars are
## skipped (engine-managed files, out of scope).
##
## UID maps come from GnumarusGodotProjectAnalyzerSuiteUidCache
## (by_uid/by_path). Empty maps mean "unverifiable": uid presence and
## agreement checks are skipped (only malformed uids still error), so
## a missing cache degrades to path-only checking instead of hundreds
## of false positives.
##
## Usage:
##   var cache := UidCache.new().parse("res://.godot/uid_cache.bin")
##   var checker := ResourceIntegrity.new()
##   var res := checker.analyze_file(
##       "res://addons/0GnumarusGodotProjectAnalyzerSuite/tests/Node3D.tscn",
##       cache.get("by_uid", {}), cache.get("by_path", {}))

const TextParser = preload("res://addons/0GnumarusGodotProjectAnalyzerSuite/GnumarusGodotProjectAnalyzerSuiteTextResourceParser.gd")
const Uid = preload("res://addons/0GnumarusGodotProjectAnalyzerSuite/GnumarusGodotProjectAnalyzerSuiteUidCache.gd")
const GdTokenizer = preload("res://addons/0GnumarusGodotProjectAnalyzerSuite/GnumarusGodotProjectAnalyzerSuiteGdscriptTokenizer.gd")

## Text resource extensions collected by collect_text_resources.
const TEXT_EXTS := [".tscn", ".tres"]

## Token types ignored when looking at neighbors of a load literal
## (layout tokens that can sit inside a parenthesized call).
const _GD_BLANK := ["NEWLINE", "INDENT", "DEDENT"]

## Characters ending a resource reference inside a string or
## comment body: whitespace, quotes, brackets, commas and format
## placeholders (`%`, `{}`). A trailing run of sentence punctuation
## (`.,;:!?`) is stripped separately, so "see
## res://addons/0GnumarusGodotProjectAnalyzerSuite/tests/ValidScript0.gd."
## still resolves to the file.
const _GD_REF_STOP := " \t\r\n\"'()[]{},;%<>"

## Last failure message ("" when the previous call was clean).
var last_error := ""


## Analyzes raw resource text. `exists` optionally overrides file
## existence (tests pass a stub Callable(path) -> bool); otherwise
## FileAccess.file_exists is used. `read_text` optionally overrides
## sidecar reads (stub Callable(path) -> String); otherwise sidecars
## are read from disk. Never fails.
func analyze_text(text: String, path: String = "", by_uid: Dictionary = {}, by_path: Dictionary = {}, exists: Callable = Callable(), read_text: Callable = Callable()) -> Dictionary:
	last_error = ""
	var parser = TextParser.new()
	var parsed := parser.parse_text(text, path)
	var errors: Array = []
	var warnings: Array = []
	for e in parsed.get("error_list", []):
		errors.append(_issue("error", "parse_error", str((e as Dictionary).get("message", "")), int((e as Dictionary).get("line", 1)), path))
	_check(parsed, path, by_uid, by_path, exists, read_text, errors, warnings)
	if not errors.is_empty():
		last_error = str(errors[0].get("message", ""))
	return {"errors": errors, "warnings": warnings, "path": path}


## Analyzes the resource file at a res:// (or OS) path. Unreadable
## files yield a single unreadable error instead of crashing.
func analyze_file(src: String, by_uid: Dictionary = {}, by_path: Dictionary = {}, exists: Callable = Callable(), read_text: Callable = Callable()) -> Dictionary:
	last_error = ""
	if not FileAccess.file_exists(src):
		var miss := [_issue("error", "unreadable", "Cannot open file: " + src, 1, src)]
		last_error = str(miss[0].get("message", ""))
		return {"errors": miss, "warnings": [], "path": src}
	return analyze_text(FileAccess.get_file_as_string(src), src, by_uid, by_path, exists, read_text)


## Sorted res:// paths of every textual resource under root
## (*.tscn/*.tres plus res://project.godot when present; `.godot/`
## skipped). Static, pure IO, headless-safe.
static func collect_text_resources(root: String) -> Array:
	var out: Array = []
	if root == "" or not DirAccess.dir_exists_absolute(root):
		return out
	var proj := root + "/project.godot"
	if FileAccess.file_exists(proj):
		out.append("res://project.godot")
	var dirs: Array = [root]
	while not dirs.is_empty():
		var dir: String = str(dirs.pop_back())
		if dir == "" or not DirAccess.dir_exists_absolute(dir):
			continue
		for sub in DirAccess.get_directories_at(dir):
			if str(sub) != ".godot":
				dirs.append(dir + "/" + str(sub))
		for f in DirAccess.get_files_at(dir):
			var fname := str(f)
			for ext in TEXT_EXTS:
				if fname.ends_with(ext):
					out.append(_res_path(root, dir + "/" + fname))
					break
	out.sort()
	return out


## Sorted res:// paths of every project .gd under root (`.godot/`
## skipped). Static, pure IO, headless-safe.
static func collect_gd_scripts(root: String) -> Array:
	var out: Array = []
	if root == "" or not DirAccess.dir_exists_absolute(root):
		return out
	var dirs: Array = [root]
	while not dirs.is_empty():
		var dir: String = str(dirs.pop_back())
		if dir == "" or not DirAccess.dir_exists_absolute(dir):
			continue
		for sub in DirAccess.get_directories_at(dir):
			if str(sub) != ".godot":
				dirs.append(dir + "/" + str(sub))
		for f in DirAccess.get_files_at(dir):
			if str(f).ends_with(".gd"):
				out.append(_res_path(root, dir + "/" + str(f)))
	out.sort()
	return out


## OS/dir path to res:// form under root (raw path outside root).
static func _res_path(root: String, abspath: String) -> String:
	if root != "" and abspath.begins_with(root):
		return "res://" + abspath.substr(root.length()).trim_prefix("/")
	return abspath


## Analyzes GDScript source for resource references. Token-level scan
## (no parse): trigger literals (preload/load/extends/@icon) plus
## every other static string in any quoting and every comment. Only
## dynamic concatenation/format operands stay out. Never fails.
func analyze_gd_text(text: String, path: String = "", by_uid: Dictionary = {}, by_path: Dictionary = {}, exists: Callable = Callable()) -> Dictionary:
	last_error = ""
	var errors: Array = []
	var warnings: Array = []
	var toks: Array = GdTokenizer.new().tokenize_text(text)
	if toks.is_empty():
		return {"errors": errors, "warnings": warnings, "path": path}
	if _gd_ignore_file(toks):
		return {"errors": errors, "warnings": warnings, "path": path}
	_check_gd_tokens(toks, path, by_uid, exists, errors, warnings)
	var ignored := _gd_ignored_lines(toks)
	if not ignored.is_empty():
		errors = errors.filter(func(e: Variant) -> bool: return not (e is Dictionary and ignored.has(int((e as Dictionary).get("line", 1)))))
		warnings = warnings.filter(func(e: Variant) -> bool: return not (e is Dictionary and ignored.has(int((e as Dictionary).get("line", 1)))))
	if not errors.is_empty():
		last_error = str(errors[0].get("message", ""))
	return {"errors": errors, "warnings": warnings, "path": path}


## Analyzes the .gd file at a res:// (or OS) path. Unreadable files
## yield a single unreadable error instead of crashing.
func analyze_gd_file(src: String, by_uid: Dictionary = {}, by_path: Dictionary = {}, exists: Callable = Callable()) -> Dictionary:
	last_error = ""
	if not FileAccess.file_exists(src):
		var miss := [_issue("error", "unreadable", "Cannot open file: " + src, 1, src)]
		last_error = str(miss[0].get("message", ""))
		return {"errors": miss, "warnings": [], "path": src}
	return analyze_gd_text(FileAccess.get_file_as_string(src), src, by_uid, by_path, exists)


func _gd_sig(toks: Array, i: int) -> int:
	if i < 0 or i >= toks.size():
		return -1
	var d := toks[i] as Dictionary
	if _GD_BLANK.has(str(d.get("type", ""))):
		return _gd_sig(toks, i + 1) if i + 1 < toks.size() else -1
	return i


func _gd_prev_sig(toks: Array, i: int) -> int:
	var j := i - 1
	while j >= 0 and _GD_BLANK.has(str((toks[j] as Dictionary).get("type", ""))):
		j -= 1
	return j


func _check_gd_tokens(toks: Array, path: String, by_uid: Dictionary, exists: Callable, errors: Array, warnings: Array) -> void:
	var verify_uids := not by_uid.is_empty()
	var i := 0
	while i < toks.size():
		var d := toks[i] as Dictionary
		var ttype := str(d.get("type", ""))
		var tval := str(d.get("value", ""))
		if ttype == "KEYWORD" and tval == "extends":
			i = _check_gd_extends(toks, i, path, by_uid, verify_uids, exists, errors, warnings)
			continue
		var label := ""
		if ttype == "KEYWORD" and tval == "preload":
			label = "Preloaded"
		elif ttype == "ANNOTATION" and tval == "@icon":
			label = "Icon"
		elif ttype == "IDENTIFIER" and tval == "load" and _gd_load_host(toks, i):
			label = "Loaded"
		if label != "":
			var st := _gd_paren_string(toks, i)
			if st < 0:
				i += 1
				continue
			_check_gd_literal(str((toks[st] as Dictionary).get("value", "")), int((toks[st] as Dictionary).get("line", 1)), int((toks[st] as Dictionary).get("column", 0)), path, by_uid, verify_uids, exists, errors, warnings, label)
			i = st + 1
			continue
		# Trigger-adjacent literals are consumed above (the jump over
		# `st` skips them), so every STRING/COMMENT reaching here is a
		# plain static string: scan its whole content for references.
		if ttype == "STRING":
			if not _gd_dynamic_neighbor(toks, i) and not _gd_existence_probe(toks, i):
				var raw := str(d.get("value", ""))
				_scan_gd_refs(_unquote(raw), int(d.get("line", 1)), int(d.get("column", 0)) + _gd_body_offset(raw), path, by_uid, verify_uids, exists, errors, warnings, "String")
		elif ttype == "COMMENT":
			_scan_gd_refs(_gd_comment_body(str(d.get("value", ""))), int(d.get("line", 1)), int(d.get("column", 0)) + _gd_comment_offset(str(d.get("value", ""))), path, by_uid, verify_uids, exists, errors, warnings, "Comment")
		elif ttype == "DOC_COMMENT":
			_scan_gd_refs(_gd_comment_body(str(d.get("value", ""))), int(d.get("line", 1)), int(d.get("column", 0)) + _gd_comment_offset(str(d.get("value", ""))), path, by_uid, verify_uids, exists, errors, warnings, "Comment")
		i += 1


## extends "..." trigger: validates the base-path literal only at
## statement end (extends takes a single literal or identifier, so any
## other follower means already-broken code). Returns the resume index.
func _check_gd_extends(toks: Array, i: int, path: String, by_uid: Dictionary, verify_uids: bool, exists: Callable, errors: Array, warnings: Array) -> int:
	var st := _gd_sig(toks, i + 1)
	if st < 0 or str((toks[st] as Dictionary).get("type", "")) != "STRING":
		return i + 1
	var j := st + 1
	while j < toks.size() and (str((toks[j] as Dictionary).get("type", "")) == "INDENT" or str((toks[j] as Dictionary).get("type", "")) == "DEDENT" or str((toks[j] as Dictionary).get("type", "")) == "COMMENT"):
		j += 1
	if j >= toks.size() or str((toks[j] as Dictionary).get("type", "")) == "NEWLINE" or str((toks[j] as Dictionary).get("type", "")) == "SEMICOLON" or str((toks[j] as Dictionary).get("type", "")) == "EOF":
		_check_gd_literal(str((toks[st] as Dictionary).get("value", "")), int((toks[st] as Dictionary).get("line", 1)), int((toks[st] as Dictionary).get("column", 0)), path, by_uid, verify_uids, exists, errors, warnings, "Extended")
	return st + 1


## STRING index of a call-style literal after a trigger token
## (LPAREN + STRING + RPAREN/COMMA), or -1 for anything else
## (dynamic args, missing parens, non-string first args).
func _gd_paren_string(toks: Array, i: int) -> int:
	var lp := _gd_sig(toks, i + 1)
	if lp < 0 or str((toks[lp] as Dictionary).get("type", "")) != "LPAREN":
		return -1
	var st := _gd_sig(toks, lp + 1)
	if st < 0 or str((toks[st] as Dictionary).get("type", "")) != "STRING":
		return -1
	var after := _gd_sig(toks, st + 1)
	if after < 0 or (str((toks[after] as Dictionary).get("type", "")) != "RPAREN" and str((toks[after] as Dictionary).get("type", "")) != "COMMA"):
		return -1
	return st


## True when a load() call site counts: bare load() (previous
## significant token is not a dot) or ResourceLoader.load().
func _gd_load_host(toks: Array, i: int) -> bool:
	var p := _gd_prev_sig(toks, i)
	if p < 0 or str((toks[p] as Dictionary).get("type", "")) != "DOT":
		return true
	var host := _gd_prev_sig(toks, p)
	return host >= 0 and str((toks[host] as Dictionary).get("value", "")) == "ResourceLoader"


## Quote-layer width of a raw STRING token (triple-double or single):
## the column offset where the string body starts.
static func _gd_body_offset(raw: String) -> int:
	if raw.begins_with("\"\"\""):
		return 3
	return 1


## Comment body with the leading `#`/`##` marker stripped (only the
## first line's marker: continuation markers stay in the body, which
## keeps raw columns right for later lines).
static func _gd_comment_body(raw: String) -> String:
	if raw.begins_with("##"):
		return raw.substr(2)
	if raw.begins_with("#"):
		return raw.substr(1)
	return raw


## Column offset where the comment body starts.
static func _gd_comment_offset(raw: String) -> int:
	if raw.begins_with("##"):
		return 2
	if raw.begins_with("#"):
		return 1
	return 0


## True when a STRING token is an existence-probe argument
## (FileAccess.file_exists(X), DirAccess.dir_exists_absolute(X),
## *.exists(X)): a question, not a demand — absence is handled by
## the caller, so nothing is reported. Never fails.
func _gd_existence_probe(toks: Array, i: int) -> bool:
	var lp := _gd_prev_sig(toks, i)
	if lp < 0 or str((toks[lp] as Dictionary).get("type", "")) != "LPAREN":
		return false
	var host := _gd_prev_sig(toks, lp)
	if host < 0 or str((toks[host] as Dictionary).get("type", "")) != "IDENTIFIER":
		return false
	var v := str((toks[host] as Dictionary).get("value", ""))
	return v == "file_exists" or v == "exists" or v == "dir_exists_absolute"


## Whole-file opt-out: "@integrity_ignore_file" inside the file's
## leading comment block (before the first code token, like a
## modeline) exempts the file from .gd scanning — for sources that
## deliberately traffic in virtual paths, like analyzer test
## harnesses. Leading-block scoping also keeps deep mentions of the
## marker (like this very paragraph) from self-exempting. Pure.
static func _gd_ignore_file(toks: Array) -> bool:
	for t in toks:
		var d := t as Dictionary
		var ttype := str(d.get("type", ""))
		if ttype == "COMMENT" or ttype == "DOC_COMMENT":
			if "@integrity_ignore_file" in str(d.get("value", "")):
				return true
		elif ttype != "NEWLINE" and ttype != "INDENT" and ttype != "DEDENT":
			return false
	return false


## Lines holding a "@integrity_ignore" comment ({line: true}): issues
## reported on those lines are dropped. (A file-marker match does not
## count as a line marker.) Pure.
static func _gd_ignored_lines(toks: Array) -> Dictionary:
	var out := {}
	for t in toks:
		var d := t as Dictionary
		var ttype := str(d.get("type", ""))
		if ttype == "COMMENT" or ttype == "DOC_COMMENT":
			var v := str(d.get("value", ""))
			if "@integrity_ignore" in v and not ("@integrity_ignore_file" in v):
				out[int(d.get("line", 1))] = true
	return out


## True when a STRING token touches a concatenation/format operator:
## a PLUS or PERCENT significant neighbor on either side means
## dynamic content ("res://" + name, "res://%s" % x), out of scope.
func _gd_dynamic_neighbor(toks: Array, i: int) -> bool:
	var neighbors := [_gd_prev_sig(toks, i), _gd_sig(toks, i + 1)]
	for n in neighbors:
		var ni := int(n)
		if ni < 0:
			continue
		var d := toks[ni] as Dictionary
		if str(d.get("type", "")) == "OPERATOR" and (str(d.get("value", "")) == "+" or str(d.get("value", "")) == "%"):
			return true
	return false


## Reference candidate starting at a resource occurrence: the
## maximal run up to a stop character, minus trailing sentence
## punctuation and trailing :line[:column] suffixes (path:line idioms
## in logs and quick-open strings). Pure, unit-tested headless.
static func _gd_ref_candidate(body: String, start: int) -> String:
	var j := start
	while j < body.length() and not _GD_REF_STOP.contains(body.substr(j, 1)):
		j += 1
	var s := body.substr(start, j - start)
	while s.length() > 0 and ".,;:!?".contains(s.substr(s.length() - 1, 1)):
		s = s.substr(0, s.length() - 1)
	var cut := true
	while cut and s.length() > 0:
		cut = false
		var ci := s.rfind(":")
		if ci >= 7:
			var tail := s.substr(ci + 1)
			if tail != "" and tail.is_valid_int():
				s = s.substr(0, ci)
				cut = true
	return s


## Reports every static resource reference inside a STRING or
## COMMENT token body (any quoting — single, double, triple-double —
## comments included) at its in-token position (multiline bodies
## advance the line). Bare prefixes never report; candidates
## containing a backslash are escaped/meta content (example code
## nested in an outer string) and skipped. Never fails.
func _scan_gd_refs(body: String, line: int, column: int, path: String, by_uid: Dictionary, verify_uids: bool, exists: Callable, errors: Array, warnings: Array, label: String) -> void:
	var i := 0
	while i < body.length():
		var r := body.find("res://", i)
		var u := body.find("uid://", i)
		var start := u
		if r >= 0 and (u < 0 or r < u):
			start = r
		if start < 0:
			return
		var head := body.substr(0, start)
		var nl := head.count("\n")
		var ocol := column + start
		if nl > 0:
			ocol = start - (head.rfind("\n") + 1)
		var cand := _gd_ref_candidate(body, start)
		if cand != "" and not ("\\" in cand):
			_check_gd_candidate(cand, line + nl, ocol, path, by_uid, verify_uids, exists, errors, warnings, label)
		i = start + maxi(cand.length(), 1)


## Validates one complete load literal at its token line/column.
## Non-resource strings pass silently; bare "res://"/"uid://" prefixes
## (concatenation fragments) are skipped, never reported.
func _check_gd_literal(raw: String, line: int, column: int, path: String, by_uid: Dictionary, verify_uids: bool, exists: Callable, errors: Array, warnings: Array, label: String = "Loaded") -> void:
	_check_gd_candidate(_unquote(raw).strip_edges(), line, column, path, by_uid, verify_uids, exists, errors, warnings, label)


## Validates one unquoted path candidate at its position. Same
## silence rules as the literal above, shared by the trigger checks
## and the all-strings scan below. Directories count as existing
## (prefix comparisons like begins_with("res://addons/") are static
## strings too).
func _check_gd_candidate(s: String, line: int, column: int, path: String, by_uid: Dictionary, verify_uids: bool, exists: Callable, errors: Array, warnings: Array, label: String) -> void:
	if s == "res://" or s == "uid://":
		return
	if s.begins_with("res://"):
		if " " in s or "\t" in s or "\n" in s:
			return
		if not _gd_ref_exists(s, exists):
			errors.append(_gd_issue("error", "missing_file", label + " file does not exist: " + s, line, column, path))
	elif s.begins_with("uid://"):
		if Uid.text_to_id(s) < 0:
			errors.append(_gd_issue("error", "malformed_uid", "Malformed uid: " + s, line, column, path))
		elif verify_uids:
			if not by_uid.has(s):
				errors.append(_gd_issue("error", "missing_uid", "UID not in uid cache: " + s, line, column, path))
			elif not _exists(str(by_uid.get(s, "")), exists):
				errors.append(_gd_issue("error", "uid_path_mismatch", "UID " + s + " points to missing file: " + str(by_uid.get(s, "")), line, column, path))


func _gd_issue(severity: String, kind: String, message: String, line: int, column: int, path: String) -> Dictionary:
	return {"severity": severity, "kind": kind, "message": message, "line": maxi(line, 1), "column": maxi(column, 0), "path": path}


## Strips one or more surrounding quote layers ('...', "...",
## triple-quoted). Inner quotes never match the outer pair, so plain
## apostrophes inside double quotes survive untouched.
func _unquote(raw: String) -> String:
	var s := raw
	while s.length() >= 2 and (s.begins_with("\"") or s.begins_with("'")) and s.ends_with(s.substr(0, 1)):
		s = s.substr(1, s.length() - 2)
	return s


func _issue(severity: String, kind: String, message: String, line: int, path: String) -> Dictionary:
	return {"severity": severity, "kind": kind, "message": message, "line": maxi(line, 1), "column": 1, "path": path}


func _exists(p: String, exists: Callable) -> bool:
	if exists.is_valid():
		return bool(exists.call(p))
	return FileAccess.file_exists(p)


## A res:// reference resolves to a file or a directory (the
## `exists` stub, when given, answers for both, keeping hermetic
## tests in control of the whole universe).
func _gd_ref_exists(p: String, exists: Callable) -> bool:
	if exists.is_valid():
		return bool(exists.call(p))
	return FileAccess.file_exists(p) or DirAccess.dir_exists_absolute(p)


func _check(parsed: Dictionary, path: String, by_uid: Dictionary, by_path: Dictionary, exists: Callable, read_text: Callable, errors: Array, warnings: Array) -> void:
	var verify_uids := not by_uid.is_empty()
	_check_header_uid(parsed, path, errors)
	_check_self_sidecar(parsed, path, read_text, errors)
	var ext_ids := _check_ext_resources(parsed, path, by_uid, by_path, verify_uids, exists, read_text, errors, warnings)
	var sub_ids := _check_sub_resources(parsed, path, errors)
	_walk_values(parsed, path, by_uid, verify_uids, exists, ext_ids, sub_ids, errors)
	_check_unused_ext(ext_ids, path, warnings)


func _check_header_uid(parsed: Dictionary, path: String, errors: Array) -> void:
	var header: Dictionary = parsed.get("header", {})
	var uid := str((header.get("attrs", {}) as Dictionary).get("uid", ""))
	if uid == "":
		return
	if Uid.text_to_id(uid) < 0:
		errors.append(_issue("error", "malformed_uid", "Malformed header uid: " + uid, int(header.get("line", 1)), path))


## Reads the engine-written sidecar (<res_path>.uid), stripped, or
## "" when absent/unreadable/blank. Never fails.
func _read_sidecar(res_path: String, read_text: Callable) -> String:
	if res_path == "":
		return ""
	var sidecar := res_path + ".uid"
	if read_text.is_valid():
		var out: Variant = read_text.call(sidecar)
		if out is String:
			return (out as String).strip_edges()
		return ""
	if not FileAccess.file_exists(sidecar):
		return ""
	return FileAccess.get_file_as_string(sidecar).strip_edges()


## Sidecar for a path-anchored reference, or "" when the reference
## has no res:// path anchor or no sidecar exists.
func _anchored_sidecar(rpath: String, read_text: Callable) -> String:
	if not rpath.begins_with("res://"):
		return ""
	return _read_sidecar(rpath, read_text)


## Compares a declared ext_resource uid against the sidecar of its
## path. Silent when there is no path anchor, no sidecar, or
## agreement; otherwise a sidecar_mismatch error.
func _check_declared_vs_sidecar(uid: String, rpath: String, line: int, path: String, read_text: Callable, errors: Array) -> void:
	var sc := _anchored_sidecar(rpath, read_text)
	if sc == "" or sc == uid:
		return
	errors.append(_issue("error", "sidecar_mismatch", "Declared uid " + uid + " disagrees with sidecar " + sc + " for " + rpath, line, path))


## The analyzed file's own identity: header uid vs its sidecar.
## Missing header, missing sidecar or agreement all pass silently;
## only a present-but-different pair errors.
func _check_self_sidecar(parsed: Dictionary, path: String, read_text: Callable, errors: Array) -> void:
	if path == "" or not path.begins_with("res://"):
		return
	var header: Dictionary = parsed.get("header", {})
	var uid := str((header.get("attrs", {}) as Dictionary).get("uid", ""))
	if uid == "" or Uid.text_to_id(uid) < 0:
		return
	var sc := _read_sidecar(path, read_text)
	if sc == "" or sc == uid:
		return
	errors.append(_issue("error", "sidecar_mismatch", "Header uid " + uid + " disagrees with sidecar " + sc + " for " + path, int(header.get("line", 1)), path))
	return


func _check_ext_resources(parsed: Dictionary, path: String, by_uid: Dictionary, by_path: Dictionary, verify_uids: bool, exists: Callable, read_text: Callable, errors: Array, warnings: Array) -> Dictionary:
	var ids := {}
	for entry in parsed.get("ext_resources", []):
		var e := entry as Dictionary
		var line := int(e.get("line", 1))
		var attrs: Dictionary = e.get("attrs", {})
		var rid := str(attrs.get("id", ""))
		if rid == "":
			errors.append(_issue("error", "malformed_ext_resource", "ext_resource without id", line, path))
			continue
		if ids.has(rid):
			errors.append(_issue("error", "duplicate_ext_id", "Duplicate ext_resource id: " + rid, line, path))
			continue
		ids[rid] = {"line": line, "used": false}
		var rpath := str(attrs.get("path", ""))
		var uid := str(attrs.get("uid", ""))
		if rpath != "" and rpath.begins_with("res://") and not _exists(rpath, exists):
			errors.append(_issue("error", "missing_file", "Referenced file does not exist: " + rpath, line, path))
		if uid != "":
			if Uid.text_to_id(uid) < 0:
				errors.append(_issue("error", "malformed_uid", "Malformed uid: " + uid, line, path))
			elif verify_uids and by_uid.has(uid):
				var target := str(by_uid.get(uid, ""))
				if not _exists(target, exists):
					errors.append(_issue("error", "uid_path_mismatch", "UID " + uid + " points to missing file: " + target, line, path))
				elif rpath != "" and target != rpath:
					errors.append(_issue("error", "uid_path_mismatch", "UID " + uid + " points to " + target + " but ext_resource declares " + rpath, line, path))
				_check_declared_vs_sidecar(uid, rpath, line, path, read_text, errors)
			elif verify_uids:
				# Cache is non-empty but lacks the uid: the sidecar (when
				# present) decides between a stale cache, a wrong
				# declaration, and a genuinely missing uid.
				var sc := _anchored_sidecar(rpath, read_text)
				if sc != "" and sc == uid:
					warnings.append(_issue("warning", "stale_cache", "UID " + uid + " not in uid cache but sidecar of " + rpath + " agrees; cache is stale", line, path))
				elif sc != "":
					errors.append(_issue("error", "sidecar_mismatch", "Declared uid " + uid + " disagrees with sidecar " + sc + " for " + rpath, line, path))
				else:
					errors.append(_issue("error", "missing_uid", "UID not in uid cache: " + uid, line, path))
			else:
				# Cache absent: the sidecar is the only uid truth.
				_check_declared_vs_sidecar(uid, rpath, line, path, read_text, errors)
		if rpath != "" and uid != "" and not by_path.is_empty() and by_path.has(rpath) and str(by_path.get(rpath, "")) != uid:
			errors.append(_issue("error", "path_uid_mismatch", "Path " + rpath + " has UID " + str(by_path.get(rpath, "")) + " in cache but ext_resource declares " + uid, line, path))
	return ids


func _check_sub_resources(parsed: Dictionary, path: String, errors: Array) -> Dictionary:
	var ids := {}
	for entry in parsed.get("sub_resources", []):
		var e := entry as Dictionary
		var rid := str((e.get("attrs", {}) as Dictionary).get("id", ""))
		if rid == "":
			continue
		if ids.has(rid):
			errors.append(_issue("error", "duplicate_subresource", "Duplicate sub_resource id: " + rid, int(e.get("line", 1)), path))
			continue
		ids[rid] = true
	return ids


func _walk_values(parsed: Dictionary, path: String, by_uid: Dictionary, verify_uids: bool, exists: Callable, ext_ids: Dictionary, sub_ids: Dictionary, errors: Array) -> void:
	for key in parsed.get("globals", {}):
		_walk_node(parsed.get("globals", {})[key], path, by_uid, verify_uids, exists, ext_ids, sub_ids, errors)
	for section in parsed.get("sections", []):
		for key in (section as Dictionary).get("props", {}):
			_walk_node(((section as Dictionary).get("props", {}) as Dictionary).get(key), path, by_uid, verify_uids, exists, ext_ids, sub_ids, errors)


func _walk_node(node: Variant, path: String, by_uid: Dictionary, verify_uids: bool, exists: Callable, ext_ids: Dictionary, sub_ids: Dictionary, errors: Array) -> void:
	if not (node is Dictionary):
		return
	var n := node as Dictionary
	var ntype := str(n.get("type", ""))
	var line := int(n.get("line", 1))
	if ntype == "call":
		var cname := str(n.get("name", ""))
		var args: Array = n.get("args", [])
		if (cname == "ExtResource" or cname == "SubResource") and not args.is_empty():
			_check_resource_ref(cname, args[0], line, path, ext_ids, sub_ids, errors)
		elif cname == "Resource" and not args.is_empty():
			_check_bare_uid(args[0], line, path, by_uid, verify_uids, exists, errors)
		for a in args:
			_walk_node(a, path, by_uid, verify_uids, exists, ext_ids, sub_ids, errors)
		return
	if ntype == "array":
		for item in n.get("items", []):
			_walk_node(item, path, by_uid, verify_uids, exists, ext_ids, sub_ids, errors)
		return
	if ntype == "dict":
		for entry in n.get("entries", []):
			_walk_node((entry as Dictionary).get("key"), path, by_uid, verify_uids, exists, ext_ids, sub_ids, errors)
			_walk_node((entry as Dictionary).get("value"), path, by_uid, verify_uids, exists, ext_ids, sub_ids, errors)
		return
	if ntype == "string":
		_check_bare_string(str(n.get("value", "")), line, path, by_uid, verify_uids, exists, errors)


func _check_resource_ref(cname: String, arg: Variant, line: int, path: String, ext_ids: Dictionary, sub_ids: Dictionary, errors: Array) -> void:
	var rid := ""
	if arg is Dictionary:
		var a := arg as Dictionary
		if str(a.get("type", "")) == "string":
			rid = str(a.get("value", ""))
		elif str(a.get("type", "")) == "int":
			rid = str(a.get("value", 0))
	if rid == "":
		return
	if cname == "ExtResource":
		if ext_ids.has(rid):
			(ext_ids[rid] as Dictionary)["used"] = true
		else:
			errors.append(_issue("error", "dangling_ext_id", "ExtResource id not declared: " + rid, line, path))
	elif not sub_ids.has(rid):
		errors.append(_issue("error", "dangling_subresource", "SubResource id not declared: " + rid, line, path))


## Bare uid://... values (a Resource() arg or a whole-value string):
## well-formed, cached, and pointing at an existing file.
func _check_bare_uid(arg: Variant, line: int, path: String, by_uid: Dictionary, verify_uids: bool, exists: Callable, errors: Array) -> void:
	if not (arg is Dictionary) or str((arg as Dictionary).get("type", "")) != "string":
		return
	_check_bare_string(str((arg as Dictionary).get("value", "")), line, path, by_uid, verify_uids, exists, errors)


## Whole-value strings only (stripped value starts with res:// or
## uid://, single line): property fragments and multiline embedded
## code (script/source) are skipped to avoid false positives.
func _check_bare_string(value: String, line: int, path: String, by_uid: Dictionary, verify_uids: bool, exists: Callable, errors: Array) -> void:
	if "\n" in value:
		return
	var s := value.strip_edges()
	if s.begins_with("res://"):
		if " " in s or "\t" in s:
			return
		if not _exists(s, exists):
			errors.append(_issue("error", "missing_file", "Referenced file does not exist: " + s, line, path))
	elif s.begins_with("uid://"):
		if Uid.text_to_id(s) < 0:
			errors.append(_issue("error", "malformed_uid", "Malformed uid: " + s, line, path))
		elif verify_uids:
			if not by_uid.has(s):
				errors.append(_issue("error", "missing_uid", "UID not in uid cache: " + s, line, path))
			elif not _exists(str(by_uid.get(s, "")), exists):
				errors.append(_issue("error", "uid_path_mismatch", "UID " + s + " points to missing file: " + str(by_uid.get(s, "")), line, path))


func _check_unused_ext(ext_ids: Dictionary, path: String, warnings: Array) -> void:
	var ids: Array = ext_ids.keys()
	ids.sort()
	for rid in ids:
		if not bool((ext_ids[rid] as Dictionary).get("used", false)):
			warnings.append(_issue("warning", "unused_ext_resource", "ext_resource id never used: " + str(rid), int((ext_ids[rid] as Dictionary).get("line", 1)), path))
