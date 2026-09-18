class_name GnumarusGodotProjectAnalyzerSuiteGdscriptTokenizer
extends RefCounted

## Tokenizer for GDScript source code.
##
## Turns GDScript source into a flat list of token Dictionaries for the
## future parser. Every token has the same shape:
## {"type": String, "value": String, "line": int, "column": int}
## Line numbers are 1-based, columns are 0-based character offsets.
## Token values keep the exact source text (lossless for literals).
## Comments are preserved as COMMENT / DOC_COMMENT tokens on purpose:
## the future parser will use them, so they are never discarded.
## Consecutive full-line comments of the same kind (only `#` or only
## `##`), back to back with a single newline between them, are merged
## into ONE token whose value joins the lines with "\n". A blank line,
## a code line or a kind switch (`#` vs `##`) starts a new token.
## Trailing comments after code (`var x := 1 # note`) never merge.
## INDENT value holds the indent whitespace, NEWLINE value is "\n",
## DEDENT and EOF values are "".
##
## Usage with a file path:
##   var tokens := GnumarusGodotProjectAnalyzerSuiteGdscriptTokenizer.new().tokenize("res://script.gd")
## Usage with a source string:
##   var tokens := GnumarusGodotProjectAnalyzerSuiteGdscriptTokenizer.new().tokenize("var x := 1\n")
## Direct iteration (tokenize_text() itself is just a collector over it):
##   var tok := GnumarusGodotProjectAnalyzerSuiteGdscriptTokenizer.new()
##   tok.pending_text = "var x := 1\n"
##   for token in tok:
##       print(token)

const TOKEN_ANNOTATION := "ANNOTATION"
const TOKEN_BOOL := "BOOL"
const TOKEN_BUILTIN_TYPE := "BUILTIN_TYPE"
const TOKEN_COLON := "COLON"
const TOKEN_COMMA := "COMMA"
const TOKEN_COMMENT := "COMMENT"
const TOKEN_DEDENT := "DEDENT"
const TOKEN_DOC_COMMENT := "DOC_COMMENT"
const TOKEN_DOT := "DOT"
const TOKEN_EOF := "EOF"
const TOKEN_ERROR := "ERROR"
const TOKEN_FLOAT := "FLOAT"
const TOKEN_GET_NODE := "GET_NODE"
const TOKEN_IDENTIFIER := "IDENTIFIER"
const TOKEN_INDENT := "INDENT"
const TOKEN_INT := "INT"
const TOKEN_KEYWORD := "KEYWORD"
const TOKEN_LBRACE := "LBRACE"
const TOKEN_LBRACKET := "LBRACKET"
const TOKEN_LPAREN := "LPAREN"
const TOKEN_NEWLINE := "NEWLINE"
const TOKEN_NODE_PATH := "NODE_PATH"
const TOKEN_NULL := "NULL"
const TOKEN_OPERATOR := "OPERATOR"
const TOKEN_RBRACE := "RBRACE"
const TOKEN_RBRACKET := "RBRACKET"
const TOKEN_RPAREN := "RPAREN"
const TOKEN_SEMICOLON := "SEMICOLON"
const TOKEN_STRING := "STRING"
const TOKEN_STRING_NAME := "STRING_NAME"
const TOKEN_UNIQUE_NAME := "UNIQUE_NAME"
const TOKEN_UNKNOWN := "UNKNOWN"

## Reserved words. true/false/null get their own token types.
const KEYWORDS: Array = [
	"if", "elif", "else", "for", "while", "match", "when",
	"break", "continue", "pass", "return", "class", "class_name",
	"extends", "is", "in", "as", "self", "super", "signal", "func",
	"static", "const", "enum", "var", "breakpoint", "preload",
	"await", "assert", "void", "PI", "TAU", "INF", "NAN",
	"and", "or", "not",
]

## Built-in Variant type names (from the 4.7 engine API) plus the
## script-level types a tokenizer can know without project context.
const BUILTIN_TYPES: Array = [
	"bool", "int", "float", "String", "Vector2", "Vector2i",
	"Rect2", "Rect2i", "Vector3", "Vector3i", "Transform2D",
	"Vector4", "Vector4i", "Plane", "Quaternion", "AABB", "Basis",
	"Transform3D", "Projection", "Color", "StringName", "NodePath",
	"RID", "Callable", "Signal", "Dictionary", "Array",
	"PackedByteArray", "PackedInt32Array", "PackedInt64Array",
	"PackedFloat32Array", "PackedFloat64Array", "PackedStringArray",
	"PackedVector2Array", "PackedVector3Array", "PackedColorArray",
	"PackedVector4Array", "Object", "Variant",
]

const OPERATORS_3: Array = ["**=", "<<=", ">>="]
const OPERATORS_2: Array = [
	"**", "<<", ">>", "<=", ">=", "==", "!=",
	"&&", "||", ":=", "->", "+=", "-=", "*=", "/=",
	"%=", "&=", "|=", "^=",
]

## Set when tokenize() itself fails (unreadable file). Single bad
## tokens never stop the run; they show up as ERROR/UNKNOWN tokens.
var last_error: String = ""

var _text: String = ""
var _length: int = 0
var _pos: int = 0
var _line: int = 1
var _column: int = 0
var _tokens: Array = []
var _indent_stack: Array[String] = []
var _indent_char: String = ""
var _bracket_depth: int = 0
var _line_start: bool = true
var _continued: bool = false
var _line_has_tokens: bool = false
## Source text staged for iteration. Only one iteration may be active
## at a time on the same instance (nested loops need separate instances).
## Set it before using `for token in tokenizer`.
var pending_text: String = ""
var _current: Dictionary = {}
var _queue_head: int = 0
var _stream_done: bool = false


## Tokenizes either a file path (res://, user:// or OS path, when the
## file exists) or a raw GDScript source string. Returns an Array of
## token Dictionaries, always terminated by an EOF token.
func tokenize(source: String) -> Array:
	last_error = ""
	var text: String = source
	if FileAccess.file_exists(source):
		var file := FileAccess.open(source, FileAccess.READ)
		if file == null:
			last_error = "Cannot open file: " + source
			push_error(last_error)
			return []
		text = file.get_as_text()
	return tokenize_text(text)


## Tokenizes a raw GDScript source string.
func tokenize_text(text: String) -> Array:
	pending_text = text.replace("\r\n", "\n").replace("\r", "\n")
	var ret: Array = []
	for tok in self:
		ret.push_back(tok)
	return ret


## Custom iterator protocol (see the "Custom iterators" docs):
## `for tok in tokenizer` yields every token, EOF included.
## The step counter lives in the single-element `iter` array as
## documented; the scan cursors stay in member variables.
func _iter_init(iter) -> bool:
	_reset_state(pending_text)
	iter[0] = 0
	return _iter_next(iter)


func _iter_next(iter) -> bool:
	iter[0] = int(iter[0]) + 1
	_pump()
	if _queue_head >= _tokens.size():
		return false
	_current = _tokens[_queue_head]
	_queue_head += 1
	return true


func _iter_get(_unused) -> Variant:
	return _current


## Runs the scanner until one unread token is available or the stream ends.
func _pump() -> void:
	while _queue_head >= _tokens.size() and not _stream_done:
		if _pos >= _length:
			_finish()
			_stream_done = true
		elif _line_start:
			_begin_line()
		else:
			_scan_inline()


func _reset_state(text: String) -> void:
	_text = text
	last_error = ""
	_length = text.length()
	_pos = 0
	_line = 1
	_column = 0
	_tokens = []
	_indent_stack.clear()
	_indent_stack.append("")
	_indent_char = ""
	_bracket_depth = 0
	_line_start = true
	_continued = false
	_line_has_tokens = false
	_queue_head = 0
	_stream_done = false
	_current = {}


func _finish() -> void:
	if _line_has_tokens:
		_add_token(TOKEN_NEWLINE, "\n", _line, _column)
		_line_has_tokens = false
	while _indent_stack.size() > 1:
		_indent_stack.pop_back()
		_add_token(TOKEN_DEDENT, "", _line, _column)
	_add_token(TOKEN_EOF, "", _line, _column)


func _begin_line() -> void:
	if _continued or _bracket_depth > 0:
		_continued = false
		_skip_horizontal()
		if _at_eol():
			_consume_newline()
			return
		_line_start = false
		return
	var indent := _read_indent()
	if _at_eol():
		_consume_newline()
		return
	if _peek() == 35:
		_scan_comment_run()
		_add_token(TOKEN_NEWLINE, "\n", _line, _column)
		_line_has_tokens = false
		_consume_newline()
		return
	if _process_indent(indent):
		_line_start = false
	else:
		_skip_to_eol()
		_add_token(TOKEN_NEWLINE, "\n", _line, _column)
		_line_has_tokens = false
		_consume_newline()


func _scan_inline() -> void:
	_skip_horizontal()
	if _pos >= _length:
		return
	var ch := _peek()
	if ch == 10:
		_add_token(TOKEN_NEWLINE, "\n", _line, _column)
		_line_has_tokens = false
		_consume_newline()
		return
	if ch == 35:
		_scan_comment()
		return
	if ch == 92:
		_scan_backslash()
		return
	_scan_token()


## Compares the indent of a fresh logical line against the stack.
## Returns false only for mixed/illegal indentation (the line is then
## skipped by the caller); dedent mismatches are repaired inline.
func _process_indent(indent: String) -> bool:
	if indent == "":
		while _indent_stack.size() > 1:
			_indent_stack.pop_back()
			_add_token(TOKEN_DEDENT, "", _line, _column)
		return true
	var has_tab := false
	var has_space := false
	for i in range(indent.length()):
		var c := indent.unicode_at(i)
		if c == 9:
			has_tab = true
		elif c == 32:
			has_space = true
	if has_tab and has_space:
		_add_token(TOKEN_ERROR, "Mixed use of tabs and spaces for indentation.", _line, 0)
		return false
	var kind := "\t"
	if has_space:
		kind = " "
	if _indent_char == "":
		_indent_char = kind
	elif _indent_char != kind:
		if kind == " ":
			_add_token(TOKEN_ERROR, "Used space character for indentation instead of tab as used before in the file.", _line, 0)
		else:
			_add_token(TOKEN_ERROR, "Used tab character for indentation instead of space as used before in the file.", _line, 0)
		return false
	var top: String = _indent_stack[_indent_stack.size() - 1]
	if indent == top:
		return true
	if indent.length() > top.length():
		_indent_stack.append(indent)
		_add_token(TOKEN_INDENT, indent, _line, 0)
		return true
	while _indent_stack.size() > 1:
		_indent_stack.pop_back()
		_add_token(TOKEN_DEDENT, "", _line, 0)
		top = _indent_stack[_indent_stack.size() - 1]
		if top.length() <= indent.length():
			break
	if top != indent:
		_add_token(TOKEN_ERROR, "Unindent doesn't match the previous indentation level.", _line, 0)
		_indent_stack.clear()
		_indent_stack.append("")
		if indent != "":
			_indent_stack.append(indent)
			_add_token(TOKEN_INDENT, indent, _line, 0)
	return true


func _scan_token() -> void:
	var ch := _peek()
	if _is_word_start(ch):
		_scan_word()
		return
	if _is_digit(ch):
		_scan_number()
		return
	if ch == 46 and _is_digit(_peek_at(1)):
		_scan_number()
		return
	if ch == 38:
		if _peek_at(1) == 34 or _peek_at(1) == 39:
			_scan_prefixed_string(TOKEN_STRING_NAME)
			return
	if ch == 94:
		if _peek_at(1) == 34 or _peek_at(1) == 39:
			_scan_prefixed_string(TOKEN_NODE_PATH)
			return
	if ch == 36:
		_scan_get_node()
		return
	if ch == 37:
		var nx := _peek_at(1)
		if _is_word_start(nx) or nx == 34 or nx == 39:
			_scan_unique_name()
			return
	if ch == 64:
		if _is_word_start(_peek_at(1)):
			_scan_annotation()
		else:
			_add_token(TOKEN_ERROR, 'Standalone "@" without an annotation name.', _line, _column)
			_advance()
		return
	if ch == 34 or ch == 39:
		_scan_plain_string()
		return
	for i in range(OPERATORS_3.size()):
		var op3: String = OPERATORS_3[i]
		if _starts_with(op3):
			_add_token(TOKEN_OPERATOR, op3, _line, _column)
			_advance_by(op3.length())
			return
	for i in range(OPERATORS_2.size()):
		var op2: String = OPERATORS_2[i]
		if _starts_with(op2):
			_add_token(TOKEN_OPERATOR, op2, _line, _column)
			_advance_by(op2.length())
			return
	_scan_single(ch)


func _scan_single(ch: int) -> void:
	var sline := _line
	var scol := _column
	if ch == 46:
		_add_token(TOKEN_DOT, ".", sline, scol)
		_advance()
	elif ch == 44:
		_add_token(TOKEN_COMMA, ",", sline, scol)
		_advance()
	elif ch == 58:
		_add_token(TOKEN_COLON, ":", sline, scol)
		_advance()
	elif ch == 59:
		_add_token(TOKEN_SEMICOLON, ";", sline, scol)
		_advance()
	elif ch == 40:
		_add_token(TOKEN_LPAREN, "(", sline, scol)
		_advance()
		_bracket_depth += 1
	elif ch == 41:
		_add_token(TOKEN_RPAREN, ")", sline, scol)
		_advance()
		_bracket_depth = maxi(0, _bracket_depth - 1)
	elif ch == 91:
		_add_token(TOKEN_LBRACKET, "[", sline, scol)
		_advance()
		_bracket_depth += 1
	elif ch == 93:
		_add_token(TOKEN_RBRACKET, "]", sline, scol)
		_advance()
		_bracket_depth = maxi(0, _bracket_depth - 1)
	elif ch == 123:
		_add_token(TOKEN_LBRACE, "{", sline, scol)
		_advance()
		_bracket_depth += 1
	elif ch == 125:
		_add_token(TOKEN_RBRACE, "}", sline, scol)
		_advance()
		_bracket_depth = maxi(0, _bracket_depth - 1)
	elif ch == 43 or ch == 45 or ch == 42 or ch == 47 or ch == 37 or ch == 60 or ch == 61 or ch == 62 or ch == 33 or ch == 38 or ch == 124 or ch == 94 or ch == 126:
		_add_token(TOKEN_OPERATOR, _text.substr(_pos, 1), sline, scol)
		_advance()
	else:
		_add_token(TOKEN_UNKNOWN, _text.substr(_pos, 1), sline, scol)
		_advance()


func _scan_word() -> void:
	var sline := _line
	var scol := _column
	var start := _pos
	while _is_word_part(_peek()):
		_advance()
	var word := _text.substr(start, _pos - start)
	if word == "r" and (_peek() == 34 or _peek() == 39):
		if _scan_quoted_string(true):
			_add_token(TOKEN_STRING, _text.substr(start, _pos - start), sline, scol)
		else:
			_add_token(TOKEN_ERROR, "Unterminated string literal.", sline, scol)
		return
	if word == "true" or word == "false":
		_add_token(TOKEN_BOOL, word, sline, scol)
	elif word == "null":
		_add_token(TOKEN_NULL, word, sline, scol)
	elif word in KEYWORDS:
		_add_token(TOKEN_KEYWORD, word, sline, scol)
	elif word in BUILTIN_TYPES:
		_add_token(TOKEN_BUILTIN_TYPE, word, sline, scol)
	else:
		_add_token(TOKEN_IDENTIFIER, word, sline, scol)


func _scan_number() -> void:
	var sline := _line
	var scol := _column
	var start := _pos
	var is_float := false
	var allow_exp := true
	var ch := _peek()
	if ch == 46:
		is_float = true
		_advance()
		while _is_digit(_peek()) or _peek() == 95:
			_advance()
	else:
		if ch == 48 and (_peek_at(1) == 120 or _peek_at(1) == 88):
			allow_exp = false
			_advance()
			_advance()
			while _is_hex(_peek()) or _peek() == 95:
				_advance()
		elif ch == 48 and (_peek_at(1) == 98 or _peek_at(1) == 66):
			allow_exp = false
			_advance()
			_advance()
			while _peek() == 48 or _peek() == 49 or _peek() == 95:
				_advance()
		else:
			while _is_digit(_peek()) or _peek() == 95:
				_advance()
			if _peek() == 46 and _peek_at(1) != 46:
				is_float = true
				_advance()
				while _is_digit(_peek()) or _peek() == 95:
					_advance()
		if allow_exp and (_peek() == 101 or _peek() == 69):
			is_float = true
			_advance()
			if _peek() == 43 or _peek() == 45:
				_advance()
			while _is_digit(_peek()) or _peek() == 95:
				_advance()
	var text := _text.substr(start, _pos - start)
	if is_float:
		_add_token(TOKEN_FLOAT, text, sline, scol)
	else:
		_add_token(TOKEN_INT, text, sline, scol)


## Consumes a quoted string starting at the opening quote.
## Returns true when a matching terminator was found.
func _scan_quoted_string(raw: bool) -> bool:
	var quote := _peek()
	_advance()
	var triple := false
	if _peek() == quote and _peek_at(1) == quote:
		_advance()
		_advance()
		triple = true
	while true:
		if _pos >= _length:
			return false
		var ch := _peek()
		if not raw and ch == 92:
			_advance()
			if _pos >= _length:
				return false
			var esc := _peek()
			if esc == 10:
				_advance()
			elif esc == 117:
				_advance()
				for _i in range(4):
					if _pos >= _length:
						return false
					_advance()
			elif esc == 85:
				_advance()
				for _i in range(6):
					if _pos >= _length:
						return false
					_advance()
			else:
				_advance()
			continue
		if raw and ch == 92:
			var nx := _peek_at(1)
			if nx == quote or nx == 92:
				_advance()
				_advance()
			else:
				_advance()
			continue
		if ch == quote:
			if triple:
				if _peek_at(1) == quote and _peek_at(2) == quote:
					_advance()
					_advance()
					_advance()
					return true
				_advance()
				continue
			_advance()
			return true
		if ch == 10:
			if triple:
				_advance()
				continue
			return false
		_advance()
	return false


## Scans a plain "..." or '...' literal (STRING).
func _scan_plain_string() -> void:
	var sline := _line
	var scol := _column
	var start := _pos
	if _scan_quoted_string(false):
		_add_token(TOKEN_STRING, _text.substr(start, _pos - start), sline, scol)
	else:
		_add_token(TOKEN_ERROR, "Unterminated string literal.", sline, scol)


## Scans &"..." (STRING_NAME) or ^"..." (NODE_PATH).
func _scan_prefixed_string(type: String) -> void:
	var sline := _line
	var scol := _column
	var start := _pos
	_advance()
	if _scan_quoted_string(false):
		_add_token(type, _text.substr(start, _pos - start), sline, scol)
	else:
		_add_token(TOKEN_ERROR, "Unterminated string literal.", sline, scol)


## Scans $Child, $A/B, $../Sibling, $%Unique or $"quoted/path".
func _scan_get_node() -> void:
	var sline := _line
	var scol := _column
	var start := _pos
	_advance()
	if _pos >= _length:
		_add_token(TOKEN_ERROR, 'Expected node path as string or identifier after "$".', sline, scol)
		return
	var ch := _peek()
	if ch == 34 or ch == 39:
		if _scan_quoted_string(false):
			_add_token(TOKEN_GET_NODE, _text.substr(start, _pos - start), sline, scol)
		else:
			_add_token(TOKEN_ERROR, "Unterminated string literal.", sline, scol)
		return
	if ch == 46:
		while _peek() == 46:
			_advance()
	elif _is_word_start(ch) or ch == 37:
		while _is_word_part(_peek()) or _peek() == 37:
			_advance()
	else:
		_add_token(TOKEN_ERROR, 'Expected node path as string or identifier after "$".', sline, scol)
		return
	while _peek() == 47:
		_advance()
		if _peek() == 46:
			while _peek() == 46:
				_advance()
		elif _is_word_start(_peek()) or _peek() == 37:
			while _is_word_part(_peek()) or _peek() == 37:
				_advance()
		else:
			break
	_add_token(TOKEN_GET_NODE, _text.substr(start, _pos - start), sline, scol)


## Scans %UniqueName or %"quoted name".
func _scan_unique_name() -> void:
	var sline := _line
	var scol := _column
	var start := _pos
	_advance()
	var ch := _peek()
	if ch == 34 or ch == 39:
		if _scan_quoted_string(false):
			_add_token(TOKEN_UNIQUE_NAME, _text.substr(start, _pos - start), sline, scol)
		else:
			_add_token(TOKEN_ERROR, "Unterminated string literal.", sline, scol)
	elif _is_word_start(ch):
		while _is_word_part(_peek()):
			_advance()
		_add_token(TOKEN_UNIQUE_NAME, _text.substr(start, _pos - start), sline, scol)
	else:
		_add_token(TOKEN_ERROR, 'Expected unique node name after "%".', sline, scol)


func _scan_annotation() -> void:
	var sline := _line
	var scol := _column
	var start := _pos
	_advance()
	while _is_word_part(_peek()):
		_advance()
	_add_token(TOKEN_ANNOTATION, _text.substr(start, _pos - start), sline, scol)


func _scan_comment() -> void:
	var sline := _line
	var scol := _column
	var doc := _peek_at(1) == 35
	var text := _read_comment_text()
	if doc:
		_add_token(TOKEN_DOC_COMMENT, text, sline, scol)
	else:
		_add_token(TOKEN_COMMENT, text, sline, scol)


## Reads one comment line starting at `#`, stopping before the newline.
## Leaves the position at the end of the line (on `\n` or at EOF).
func _read_comment_text() -> String:
	var start := _pos
	_skip_to_eol()
	return _text.substr(start, _pos - start)


## Scans a run of consecutive full-line comments of the same kind as ONE
## token. Lines join with "\n"; the token starts at the first `#`. Only
## lines separated by exactly one newline merge: a blank line, a code
## line or a `#` vs `##` switch ends the run. The newline and indent of
## continuation lines are consumed, never stored.
func _scan_comment_run() -> void:
	var sline := _line
	var scol := _column
	var doc := _peek_at(1) == 35
	var first := _read_comment_text()
	var text := first
	while _peek() == 10:
		var j := _pos + 1
		while j < _length and (_text.unicode_at(j) == 32 or _text.unicode_at(j) == 9):
			j += 1
		if j >= _length:
			break
		if _text.unicode_at(j) != 35:
			break
		var next_doc := j + 1 < _length and _text.unicode_at(j + 1) == 35
		if next_doc != doc:
			break
		while _pos < j:
			_advance()
		text += "\n" + _read_comment_text()
	if doc:
		_add_token(TOKEN_DOC_COMMENT, text, sline, scol)
	else:
		_add_token(TOKEN_COMMENT, text, sline, scol)


func _scan_backslash() -> void:
	var sline := _line
	var scol := _column
	var j := _pos + 1
	while j < _length and (_text.unicode_at(j) == 32 or _text.unicode_at(j) == 9):
		j += 1
	if j >= _length or _text.unicode_at(j) == 10:
		while _pos < j:
			_advance()
		if _pos < _length:
			_advance()
		_continued = true
		_line_start = true
		return
	_add_token(TOKEN_UNKNOWN, "\\", sline, scol)
	_advance()


func _peek() -> int:
	if _pos >= _length:
		return -1
	return _text.unicode_at(_pos)


func _peek_at(offset: int) -> int:
	if _pos + offset >= _length:
		return -1
	return _text.unicode_at(_pos + offset)


func _starts_with(word: String) -> bool:
	if _pos + word.length() > _length:
		return false
	return _text.substr(_pos, word.length()) == word


func _advance() -> void:
	if _pos >= _length:
		return
	if _text.unicode_at(_pos) == 10:
		_pos += 1
		_line += 1
		_column = 0
	else:
		_pos += 1
		_column += 1


func _advance_by(count: int) -> void:
	for _i in range(count):
		_advance()


func _at_eol() -> bool:
	var ch := _peek()
	return ch == 10 or ch == -1


func _consume_newline() -> void:
	if _peek() == 10:
		_advance()
	_line_start = true


func _skip_horizontal() -> void:
	while _peek() == 32 or _peek() == 9:
		_advance()


func _skip_to_eol() -> void:
	while not _at_eol():
		_advance()


func _read_indent() -> String:
	var start := _pos
	while _peek() == 32 or _peek() == 9:
		_advance()
	return _text.substr(start, _pos - start)


func _add_token(type: String, value: String, tok_line: int, tok_column: int) -> void:
	_tokens.append({"type": type, "value": value, "line": tok_line, "column": tok_column})
	if type != TOKEN_NEWLINE and type != TOKEN_INDENT and type != TOKEN_DEDENT and type != TOKEN_EOF:
		_line_has_tokens = true


func _is_word_start(ch: int) -> bool:
	return ch == 95 or ch >= 128 or (ch >= 65 and ch <= 90) or (ch >= 97 and ch <= 122)


func _is_word_part(ch: int) -> bool:
	return _is_word_start(ch) or (ch >= 48 and ch <= 57)


func _is_digit(ch: int) -> bool:
	return ch >= 48 and ch <= 57


func _is_hex(ch: int) -> bool:
	if ch >= 48 and ch <= 57:
		return true
	if ch >= 65 and ch <= 70:
		return true
	if ch >= 97 and ch <= 102:
		return true
	return false
