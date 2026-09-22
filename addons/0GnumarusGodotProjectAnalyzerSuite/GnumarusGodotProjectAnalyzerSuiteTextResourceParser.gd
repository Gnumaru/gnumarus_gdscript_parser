class_name GnumarusGodotProjectAnalyzerSuiteTextResourceParser
extends RefCounted

## Parser for Godot scene, resource and config files (.tscn, .tres,
## project.godot, or any raw text in the same INI-like format).
##
## Unlike the GDScript pipeline this stage builds no abstract syntax
## tree: it converts the file straight into nested Arrays and
## Dictionaries that are easy to manipulate from code.
##
## Result shape (all values are plain Array/Dictionary/String/int):
## {
##   "kind": "scene" | "resource" | "config",
##   "header": {"section": String, "attrs": Dictionary, "line": int},
##   "globals": Dictionary,   # assignments before the first section
##   "sections": Array,       # every section in file order
##   "ext_resources": Array,  # references to [ext_resource] sections
##   "sub_resources": Array,  # references to [sub_resource] sections
##   "nodes": Array,          # references to [node] sections
##   "resources": Array,      # references to [resource] sections
##   "errors": int,
##   "error_list": Array,     # {"message": String, "line": int}
##   "path": String,          # input path when parse() read a file
## }
##
## A section looks like:
## {"section": "node", "attrs": {...}, "props": {...}, "line": int}
## attrs holds unwrapped scalars (String/int/float/bool, never null):
## [node name="X" type="Node3D" parent="."] gives
## {"name": "X", "type": "Node3D", "parent": "."}.
## props maps each property name to a value node (see below).
##
## A value node always carries "type", "line" and "raw":
## {"type": "null", "value": null, ...}
## {"type": "bool", "value": true, ...}
## {"type": "int", "value": 3, ...}
## {"type": "float", "value": 0.5, ...}
## {"type": "string", "value": "text", ...}
## {"type": "string_name", "value": "name", ...}   # &"name"
## {"type": "node_path", "value": "path", ...}     # ^"path"
## {"type": "identifier", "name": "SomeConst", ...}
## {"type": "array", "items": [...], ...}
## {"type": "dict", "entries": [{"key": node, "value": node}], ...}
## {"type": "call", "name": "Color", "args": [...], ...}
##   # ExtResource("1"), SubResource("x"), Vector2(...), ... are calls.
## {"type": "invalid", "raw": "...", ...}  # kept, plus an error entry
##
## Comments start with ";" outside strings at bracket depth 0 and run
## to the end of the physical line. Values may span physical lines
## when inside brackets or inside a quoted string (e.g. the multiline
## script/source string or the myvar array in the test scene).
##
## Usage with a file path:
##   var data := GnumarusGodotProjectAnalyzerSuiteTextResourceParser.new().parse("res://addons/0GnumarusGodotProjectAnalyzerSuite/tests/Node3D.tscn")
## Usage with a source string:
##   var data := GnumarusGodotProjectAnalyzerSuiteTextResourceParser.new().parse_text("[resource]\na = 1\n")

const MAX_VALUE_DEPTH := 64

## Last failure message ("" when the previous parse had zero errors).
var last_error := ""

var _errors: int = 0
var _error_list: Array = []
var _vtokens: Array = []
var _vpos: int = 0
var _vline: int = 1
var _vdepth: int = 0


## Parses either a file path (res://, user:// or OS path, when the file
## exists) or a raw scene source string.
func parse(source: String) -> Dictionary:
	last_error = ""
	var text: String = source
	var path := ""
	if FileAccess.file_exists(source):
		var file := FileAccess.open(source, FileAccess.READ)
		if file == null:
			last_error = "Cannot open file: " + source
			push_error(last_error)
			return _empty_result("config", path)
		text = file.get_as_text()
		path = source
	return parse_text(text, path)


## Parses a raw scene source string. The same instance may be reused:
## every call resets the error state, so results never leak.
func parse_text(text: String, path: String = "") -> Dictionary:
	_errors = 0
	_error_list = []
	last_error = ""
	var norm: String = text.replace("\r\n", "\n").replace("\r", "\n")
	var header := {"section": "", "attrs": {}, "line": 1}
	var kind := "config"
	var sections: Array = []
	var ext_resources: Array = []
	var sub_resources: Array = []
	var nodes: Array = []
	var resources: Array = []
	var globals: Dictionary = {}
	var current: Variant = null
	for logical in _logical_lines(norm):
		var ltext := str((logical as Dictionary).get("text", ""))
		var lline := int((logical as Dictionary).get("line", 1))
		var s := ltext.strip_edges()
		if s == "":
			continue
		if s.begins_with("["):
			var sec := _parse_section_header(s, lline)
			if sec.is_empty():
				continue
			var sname := str(sec.get("name", ""))
			var sattrs: Dictionary = sec.get("attrs", {})
			if (sname == "gd_scene" or sname == "gd_resource") and sections.is_empty() and str((header as Dictionary).get("section", "")) == "":
				header = {"section": sname, "attrs": sattrs, "line": lline}
				kind = "scene" if sname == "gd_scene" else "resource"
				current = null
				continue
			var entry := {"section": sname, "attrs": sattrs, "props": {}, "line": lline}
			sections.append(entry)
			if sname == "ext_resource":
				ext_resources.append(entry)
			elif sname == "sub_resource":
				sub_resources.append(entry)
			elif sname == "node":
				nodes.append(entry)
			elif sname == "resource":
				resources.append(entry)
			current = entry
			continue
		var eq := _find_assign(s)
		if eq < 0:
			_fail("Expected key = value, got: " + s, lline)
			continue
		var key := s.substr(0, eq).strip_edges()
		var val_text := s.substr(eq + 1).strip_edges()
		if key == "":
			_fail("Empty property name in: " + s, lline)
			continue
		var node := _parse_value_text(val_text, lline)
		if current == null:
			globals[key] = node
		else:
			(current as Dictionary)["props"][key] = node
	if _errors > 0:
		last_error = str((_error_list[0] as Dictionary).get("message", ""))
	return {
		"kind": kind,
		"header": header,
		"globals": globals,
		"sections": sections,
		"ext_resources": ext_resources,
		"sub_resources": sub_resources,
		"nodes": nodes,
		"resources": resources,
		"errors": _errors,
		"error_list": _error_list,
		"path": path,
	}


func _empty_result(kind: String, path: String) -> Dictionary:
	return {
		"kind": kind,
		"header": {"section": "", "attrs": {}, "line": 1},
		"globals": {},
		"sections": [],
		"ext_resources": [],
		"sub_resources": [],
		"nodes": [],
		"resources": [],
		"errors": 1,
		"error_list": [{"message": last_error, "line": 1}],
		"path": path,
	}


func _fail(message: String, line: int) -> void:
	_errors += 1
	_error_list.append({"message": message, "line": line})


## Splits raw text into logical lines. A physical newline ends the
## logical line only at bracket depth 0 outside quoted strings;
## otherwise it is kept inside the buffer (multiline arrays, dicts
## and quoted strings). ";" comments are dropped at depth 0 outside
## strings. Returns [{"text": String, "line": int}] with 1-based
## starting physical line numbers.
func _logical_lines(text: String) -> Array:
	var out: Array = []
	var buf := ""
	var start_line := 1
	var depth := 0
	var quote := ""
	var escaped := false
	var phys := 1
	var n := text.length()
	var i := 0
	while i <= n:
		var c := "\n" if i == n else text.substr(i, 1)
		if c == "\n":
			if quote != "" or depth > 0:
				if i == n:
					if buf.strip_edges() != "":
						out.append({"text": buf, "line": start_line})
					break
				if buf == "":
					start_line = phys
				buf += "\n"
				phys += 1
				escaped = false
				i += 1
				continue
			if buf.strip_edges() != "":
				out.append({"text": buf, "line": start_line})
			buf = ""
			if i == n:
				break
			phys += 1
			i += 1
			continue
		if quote != "":
			if buf == "":
				start_line = phys
			buf += c
			if escaped:
				escaped = false
			elif c == "\\":
				escaped = true
			elif c == quote:
				quote = ""
			i += 1
			continue
		if c == '"' or c == "'":
			if buf == "":
				start_line = phys
			buf += c
			quote = c
			i += 1
			continue
		if c == ";" and depth == 0:
			if buf.strip_edges() != "":
				out.append({"text": buf, "line": start_line})
				buf = ""
			while i < n and text.substr(i, 1) != "\n":
				i += 1
			continue
		if c == "(" or c == "[" or c == "{":
			depth += 1
		elif c == ")" or c == "]" or c == "}":
			depth = maxi(0, depth - 1)
		if buf == "" and not (c == " " or c == "\t"):
			start_line = phys
		buf += c
		i += 1
	return out


## Parses "[name key=value ...]". Returns {"name":..., "attrs":...}
## or {} on failure (one error entry is recorded).
func _parse_section_header(s: String, line: int) -> Dictionary:
	if not s.ends_with("]"):
		_fail("Unclosed section header: " + s, line)
		return {}
	var inner := s.substr(1, s.length() - 2).strip_edges()
	if inner == "":
		_fail("Empty section header", line)
		return {}
	var sp := _first_blank(inner)
	var name := inner if sp < 0 else inner.substr(0, sp)
	var attrs := {}
	if sp >= 0:
		attrs = _parse_attrs(inner.substr(sp + 1).strip_edges(), line)
	return {"name": name, "attrs": attrs}


func _first_blank(s: String) -> int:
	var quote := ""
	var escaped := false
	for i in range(s.length()):
		var c := s.substr(i, 1)
		if quote != "":
			if escaped:
				escaped = false
			elif c == "\\":
				escaped = true
			elif c == quote:
				quote = ""
			continue
		if c == '"' or c == "'":
			quote = c
			continue
		if c == " " or c == "\t":
			return i
	return -1


## Parses "key=value key2=value2 ..." header attributes. Values are
## unwrapped to natives when scalar, kept as value nodes otherwise.
func _parse_attrs(s: String, line: int) -> Dictionary:
	var out := {}
	if s == "":
		return out
	_vtokens = _tokenize_value(s)
	_vpos = 0
	_vline = line
	_vdepth = 0
	while not _v_at_end():
		var t := _v_peek()
		if str(t.get("type", "")) != "IDENT":
			_fail("Expected attribute name in: " + s, line)
			_v_advance()
			continue
		var key := str(t.get("value", ""))
		_v_advance()
		if _v_at_end() or str(_v_peek().get("type", "")) != "EQUALS":
			_fail("Expected = after attribute " + key, line)
			continue
		_v_advance()
		if _v_at_end():
			_fail("Missing value for attribute " + key, line)
			break
		out[key] = _unwrap(_parse_value_node())
	return out


## Index of the first "=" at depth 0 outside strings, or -1.
func _find_assign(s: String) -> int:
	var depth := 0
	var quote := ""
	var escaped := false
	for i in range(s.length()):
		var c := s.substr(i, 1)
		if quote != "":
			if escaped:
				escaped = false
			elif c == "\\":
				escaped = true
			elif c == quote:
				quote = ""
			continue
		if c == '"' or c == "'":
			quote = c
			continue
		if c == "(" or c == "[" or c == "{":
			depth += 1
		elif c == ")" or c == "]" or c == "}":
			depth = maxi(0, depth - 1)
		elif c == "=" and depth == 0:
			return i
	return -1


## Tokenizes one value expression. Tokens carry "type", "value" and
## "raw"; strings are already escape-decoded in "value".
func _tokenize_value(s: String) -> Array:
	var tokens: Array = []
	var i := 0
	var n := s.length()
	while i < n:
		var c := s.substr(i, 1)
		if c == " " or c == "\t" or c == "\n" or c == "\r":
			i += 1
			continue
		if c == ";":
			break
		if (c == "&" or c == "^") and i + 1 < n and s.substr(i + 1, 1) == '"':
			var prefix := c
			var r := _read_quoted(s, i + 1)
			r["type"] = "STRINGNAME" if prefix == "&" else "NODEPATH"
			r["raw"] = prefix + str(r.get("raw", ""))
			tokens.append(r)
			i = int(r.get("end", i + 2))
			continue
		if c == '"' or c == "'":
			var r := _read_quoted(s, i)
			r["type"] = "STRING"
			tokens.append(r)
			i = int(r.get("end", i + 1))
			continue
		if _is_digit(c) or ((c == "-" or c == "+") and _number_follows(s, i)) or (c == "." and i + 1 < n and _is_digit(s.substr(i + 1, 1))):
			var r := _read_number(s, i)
			tokens.append(r)
			i = int(r.get("end", i + 1))
			continue
		if _is_ident_start(c):
			var j := i
			while j < n and _is_ident_part(s.substr(j, 1)):
				j += 1
			var word := s.substr(i, j - i)
			if word == "true" or word == "false":
				tokens.append({"type": "BOOL", "value": word == "true", "raw": word})
			elif word == "null":
				tokens.append({"type": "NULL", "value": null, "raw": word})
			else:
				tokens.append({"type": "IDENT", "value": word, "raw": word})
			i = j
			continue
		if c == "(":
			tokens.append({"type": "LPAREN", "value": c, "raw": c})
		elif c == ")":
			tokens.append({"type": "RPAREN", "value": c, "raw": c})
		elif c == "[":
			tokens.append({"type": "LBRACKET", "value": c, "raw": c})
		elif c == "]":
			tokens.append({"type": "RBRACKET", "value": c, "raw": c})
		elif c == "{":
			tokens.append({"type": "LBRACE", "value": c, "raw": c})
		elif c == "}":
			tokens.append({"type": "RBRACE", "value": c, "raw": c})
		elif c == ",":
			tokens.append({"type": "COMMA", "value": c, "raw": c})
		elif c == ":":
			tokens.append({"type": "COLON", "value": c, "raw": c})
		elif c == "=":
			tokens.append({"type": "EQUALS", "value": c, "raw": c})
		elif c == ".":
			tokens.append({"type": "DOT", "value": c, "raw": c})
		else:
			_fail("Unexpected character in value: " + c, _vline)
			tokens.append({"type": "INVALID", "value": c, "raw": c})
		i += 1
	tokens.append({"type": "EOF", "value": "", "raw": ""})
	return tokens


func _read_quoted(s: String, at: int) -> Dictionary:
	var q := s.substr(at, 1)
	var i := at + 1
	var n := s.length()
	var buf := ""
	while i < n:
		var c := s.substr(i, 1)
		if c == "\\" and i + 1 < n:
			var e := s.substr(i + 1, 1)
			if e == "n":
				buf += "\n"
			elif e == "r":
				buf += "\r"
			elif e == "t":
				buf += "\t"
			elif e == "b":
				buf += "\b"
			elif e == "f":
				buf += "\f"
			elif e == "u" and i + 5 < n:
				buf += String.chr(int("0x" + s.substr(i + 2, 4)))
				i += 6
				continue
			else:
				buf += e
			i += 2
			continue
		if c == q:
			return {"value": buf, "raw": s.substr(at, i - at + 1), "end": i + 1}
		if c == "\n" and q == "'":
			break
		buf += c
		i += 1
	_fail("Unterminated string in value", _vline)
	return {"value": buf, "raw": s.substr(at, i - at), "end": i}


func _read_number(s: String, at: int) -> Dictionary:
	var n := s.length()
	var j := at
	if j < n and (s.substr(j, 1) == "-" or s.substr(j, 1) == "+"):
		j += 1
	var dot := false
	var exp := false
	while j < n:
		var c := s.substr(j, 1)
		if _is_digit(c):
			j += 1
		elif c == "." and not dot and not exp:
			dot = true
			j += 1
		elif (c == "e" or c == "E") and not exp:
			exp = true
			j += 1
			if j < n and (s.substr(j, 1) == "-" or s.substr(j, 1) == "+"):
				j += 1
		else:
			break
	var word := s.substr(at, j - at)
	if dot or exp:
		if word.is_valid_float():
			return {"type": "FLOAT", "value": word.to_float(), "raw": word, "end": j}
		return {"type": "INVALID", "value": word, "raw": word, "end": j}
	if word.is_valid_int():
		return {"type": "INT", "value": word.to_int(), "raw": word, "end": j}
	return {"type": "INVALID", "value": word, "raw": word, "end": j}


func _is_digit(c: String) -> bool:
	return c >= "0" and c <= "9"


func _is_ident_start(c: String) -> bool:
	return (c >= "a" and c <= "z") or (c >= "A" and c <= "Z") or c == "_"


func _is_ident_part(c: String) -> bool:
	return _is_ident_start(c) or _is_digit(c)


func _number_follows(s: String, at: int) -> bool:
	var n := s.length()
	var j := at + 1
	if j >= n:
		return false
	var c := s.substr(j, 1)
	if _is_digit(c):
		return true
	if c == "." and j + 1 < n and _is_digit(s.substr(j + 1, 1)):
		return true
	return false


func _parse_value_text(val_text: String, line: int) -> Dictionary:
	_vtokens = _tokenize_value(val_text)
	_vpos = 0
	_vline = line
	_vdepth = 0
	if _v_at_end():
		_fail("Empty value", line)
		return {"type": "invalid", "raw": val_text, "line": line}
	var node := _parse_value_node()
	if not _v_at_end():
		_fail("Trailing tokens in value: " + val_text, line)
	return node


func _v_at_end() -> bool:
	return _vpos >= _vtokens.size() or str((_vtokens[_vpos] as Dictionary).get("type", "")) == "EOF"


func _v_peek() -> Dictionary:
	return _vtokens[_vpos] as Dictionary


func _v_advance() -> Dictionary:
	var t := _vtokens[_vpos] as Dictionary
	_vpos += 1
	return t


func _parse_value_node() -> Dictionary:
	if _vdepth > MAX_VALUE_DEPTH:
		_fail("Value nesting too deep", _vline)
		return {"type": "invalid", "raw": "", "line": _vline}
	if _v_at_end():
		_fail("Unexpected end of value", _vline)
		return {"type": "invalid", "raw": "", "line": _vline}
	var t := _v_peek()
	var kind := str(t.get("type", ""))
	if kind == "LBRACKET":
		return _parse_array_node()
	if kind == "LBRACE":
		return _parse_dict_node()
	if kind == "IDENT":
		return _parse_ident_or_call_node()
	if kind == "STRING":
		_v_advance()
		return {"type": "string", "value": str(t.get("value", "")), "line": _vline, "raw": str(t.get("raw", ""))}
	if kind == "STRINGNAME":
		_v_advance()
		return {"type": "string_name", "value": str(t.get("value", "")), "line": _vline, "raw": str(t.get("raw", ""))}
	if kind == "NODEPATH":
		_v_advance()
		return {"type": "node_path", "value": str(t.get("value", "")), "line": _vline, "raw": str(t.get("raw", ""))}
	if kind == "INT":
		_v_advance()
		return {"type": "int", "value": int(t.get("value", 0)), "line": _vline, "raw": str(t.get("raw", ""))}
	if kind == "FLOAT":
		_v_advance()
		return {"type": "float", "value": float(t.get("value", 0.0)), "line": _vline, "raw": str(t.get("raw", ""))}
	if kind == "BOOL":
		_v_advance()
		return {"type": "bool", "value": bool(t.get("value", false)), "line": _vline, "raw": str(t.get("raw", ""))}
	if kind == "NULL":
		_v_advance()
		return {"type": "null", "value": null, "line": _vline, "raw": str(t.get("raw", ""))}
	_fail("Unexpected token in value: " + str(t.get("raw", "")), _vline)
	_v_advance()
	return {"type": "invalid", "raw": str(t.get("raw", "")), "line": _vline}


func _parse_array_node() -> Dictionary:
	var open := _v_advance()
	_vdepth += 1
	var items: Array = []
	while not _v_at_end() and str(_v_peek().get("type", "")) != "RBRACKET":
		items.append(_parse_value_node())
		if _v_at_end():
			break
		var sep := str(_v_peek().get("type", ""))
		if sep == "COMMA":
			_v_advance()
			if not _v_at_end() and str(_v_peek().get("type", "")) == "RBRACKET":
				break
		elif sep != "RBRACKET":
			_fail("Expected , or ] in array", _vline)
			if sep != "EOF":
				_v_advance()
	if _v_at_end():
		_fail("Unclosed array value", _vline)
	else:
		_v_advance()
	_vdepth -= 1
	return {"type": "array", "items": items, "line": _vline, "raw": str(open.get("raw", ""))}


func _parse_dict_node() -> Dictionary:
	_v_advance()
	_vdepth += 1
	var entries: Array = []
	while not _v_at_end() and str(_v_peek().get("type", "")) != "RBRACE":
		var key := _parse_value_node()
		var sep := ""
		if not _v_at_end():
			sep = str(_v_peek().get("type", ""))
		if sep != "COLON" and sep != "EQUALS":
			_fail("Expected : in dict entry", _vline)
			entries.append({"key": key, "value": {"type": "invalid", "raw": "", "line": _vline}})
		else:
			_v_advance()
			entries.append({"key": key, "value": _parse_value_node()})
		if _v_at_end():
			break
		var after := str(_v_peek().get("type", ""))
		if after == "COMMA":
			_v_advance()
			if not _v_at_end() and str(_v_peek().get("type", "")) == "RBRACE":
				break
		elif after != "RBRACE":
			_fail("Expected , or } in dict", _vline)
			if after != "EOF":
				_v_advance()
	if _v_at_end():
		_fail("Unclosed dict value", _vline)
	else:
		_v_advance()
	_vdepth -= 1
	return {"type": "dict", "entries": entries, "line": _vline, "raw": "{}"}


func _parse_ident_or_call_node() -> Dictionary:
	var first := _v_advance()
	var name := str(first.get("value", ""))
	while not _v_at_end() and str(_v_peek().get("type", "")) == "DOT":
		_v_advance()
		if _v_at_end() or str(_v_peek().get("type", "")) != "IDENT":
			_fail("Expected identifier after .", _vline)
			break
		name += "." + str(_v_advance().get("value", ""))
	if _v_at_end() or str(_v_peek().get("type", "")) != "LPAREN":
		return {"type": "identifier", "name": name, "line": _vline, "raw": name}
	_v_advance()
	_vdepth += 1
	var args: Array = []
	while not _v_at_end() and str(_v_peek().get("type", "")) != "RPAREN":
		args.append(_parse_value_node())
		if _v_at_end():
			break
		var sep := str(_v_peek().get("type", ""))
		if sep == "COMMA":
			_v_advance()
			if not _v_at_end() and str(_v_peek().get("type", "")) == "RPAREN":
				break
		elif sep != "RPAREN":
			_fail("Expected , or ) in call", _vline)
			if sep != "EOF":
				_v_advance()
	if _v_at_end():
		_fail("Unclosed call " + name, _vline)
	else:
		_v_advance()
	_vdepth -= 1
	return {"type": "call", "name": name, "args": args, "line": _vline, "raw": name + "(...)"}


## Unwraps scalar value nodes to natives for header attributes.
func _unwrap(node: Variant) -> Variant:
	if not (node is Dictionary):
		return node
	var d := node as Dictionary
	match str(d.get("type", "")):
		"string", "string_name", "node_path":
			return str(d.get("value", ""))
		"int":
			return int(d.get("value", 0))
		"float":
			return float(d.get("value", 0.0))
		"bool":
			return bool(d.get("value", false))
		"null":
			return null
		"identifier":
			return str(d.get("name", ""))
	return node
