class_name gnumarus_gdscript_syntatic_parser
extends RefCounted

## Syntactic parser for GDScript source code.
##
## Consumes the tokens produced by gnumarus_gdscript_post_tokenizer and
## builds a complete abstract syntax tree (AST). This stage performs
## syntactic analysis ONLY: no type checking, no name resolution, no
## value validation. For example, `var myvar: int = null` is accepted
## here; a later semantic pass will flag the mismatch.
##
## The parser is NOT an iterator. Call one of the parse methods and get
## the whole AST back as a single Dictionary.
##
## The parser is fault tolerant. Any syntax error produces a SYNTAX_ERROR
## node and parsing resumes at the next safe boundary (NEWLINE,
## SEMICOLON, DEDENT or EOF), so one bad statement never hides the rest.
##
## AST shape: every node is a Dictionary with at least `type`, `line`
## and `column`. The root is:
## {"type": "SCRIPT", "children": [...], "errors": int, "header_comment": Variant, "line": 1, "column": 0}
## Comment handling: every COMMENT / DOC_COMMENT / TYPE_INFO token is
## kept. A comment immediately preceding a node (own line directly above
## it, no blank line in between) is attached to that node under the
## `leading_comments` key. The very first comment of the file, when it
## comes before any other token, is attached to the SCRIPT root under
## `header_comment`. Comments that precede other comments instead become
## standalone COMMENT / DOC_COMMENT / TYPE_INFO sibling nodes.
## Statement and declaration nodes carry their details in extra keys
## (`name`, `params`, `value`, `body`, `branches`, `tokens`, ...).
## Raw token sequences (expressions, types, patterns) are kept as EXPR /
## TYPE_REF / PATTERN nodes holding the original token Dictionaries.
##
## Usage with a token array:
##   var tokens: Array = post.process("res://script.gd")
##   var ast: Dictionary = gnumarus_gdscript_syntatic_parser.new().parse_tokens(tokens)
## Usage with source code or a file path:
##   var ast: Dictionary = gnumarus_gdscript_syntatic_parser.new().parse_text("var x := 1\n")
##   var ast: Dictionary = gnumarus_gdscript_syntatic_parser.new().parse("res://script.gd")

const gnumarus_gdscript_tokenizer = preload('gnumarus_gdscript_tokenizer.gd')
const gnumarus_gdscript_post_tokenizer = preload('gnumarus_gdscript_post_tokenizer.gd')

const NODE_SCRIPT := "SCRIPT"
const NODE_ANNOTATION_DECL := "ANNOTATION_DECL"
const NODE_CLASS_NAME := "CLASS_NAME"
const NODE_EXTENDS := "EXTENDS"
const NODE_SIGNAL_DECL := "SIGNAL_DECL"
const NODE_ENUM_DECL := "ENUM_DECL"
const NODE_ENUM_MEMBER := "ENUM_MEMBER"
const NODE_CONST_DECL := "CONST_DECL"
const NODE_VAR_DECL := "VAR_DECL"
const NODE_FUNC_DECL := "FUNC_DECL"
const NODE_PARAM := "PARAM"
const NODE_TYPE_REF := "TYPE_REF"
const NODE_CLASS_DECL := "CLASS_DECL"
const NODE_BLOCK := "BLOCK"
const NODE_IF_STMT := "IF_STMT"
const NODE_FOR_STMT := "FOR_STMT"
const NODE_WHILE_STMT := "WHILE_STMT"
const NODE_MATCH_STMT := "MATCH_STMT"
const NODE_MATCH_BRANCH := "MATCH_BRANCH"
const NODE_PATTERN := "PATTERN"
const NODE_RETURN_STMT := "RETURN_STMT"
const NODE_BREAK_STMT := "BREAK_STMT"
const NODE_CONTINUE_STMT := "CONTINUE_STMT"
const NODE_PASS_STMT := "PASS_STMT"
const NODE_BREAKPOINT_STMT := "BREAKPOINT_STMT"
const NODE_ASSERT_STMT := "ASSERT_STMT"
const NODE_EXPR_STMT := "EXPR_STMT"
const NODE_EXPR := "EXPR"
const NODE_LAMBDA := "LAMBDA"
const NODE_ACCESSOR := "ACCESSOR"
const NODE_COMMENT := "COMMENT"
const NODE_DOC_COMMENT := "DOC_COMMENT"
const NODE_TYPE_INFO := "TYPE_INFO"
const NODE_SYNTAX_ERROR := "SYNTAX_ERROR"

var _tokens: Array = []
var _pos: int = 0
var _error_count: int = 0
## Buffered COMMENT / DOC_COMMENT / TYPE_INFO tokens seen while looking
## for the next meaningful token. They are attached or flushed later.
var _pending_trivia: Array = []
## First comment of the file, attached to the SCRIPT root. Claimed once.
var _header_comment: Variant = null
var _header_done: bool = false


## Parses an array of token Dictionaries. Always returns a SCRIPT node.
func parse_tokens(tokens: Array) -> Dictionary:
	_tokens = tokens
	_pos = 0
	_error_count = 0
	_pending_trivia = []
	_header_comment = null
	_header_done = false
	var children: Array = []
	while not _at_end():
		_skip_trivia()
		if _at_end():
			break
		if _peek_type() == "DEDENT":
			_advance()
			continue
		if _peek_type() == "INDENT":
			children.append(_make_error("Unexpected indent at script level.", _peek()))
			_advance()
			continue
		for node in _parse_top_decl():
			children.append(node)
	for node in _flush_trivia_all():
		children.append(node)
	return {"type": NODE_SCRIPT, "children": children, "errors": _error_count, "header_comment": _header_comment, "line": 1, "column": 0}




## Parses raw GDScript source code passed as a string.
func parse_text(text: String) -> Dictionary:
	var tok := gnumarus_gdscript_tokenizer.new()
	var post := gnumarus_gdscript_post_tokenizer.new()
	return parse_tokens(post.process_tokens(tok.tokenize_text(text)))


## Parses either a file path (res://, user:// or OS path, when the file
## exists) or a raw GDScript source string.
func parse(source: String) -> Dictionary:
	var tok := gnumarus_gdscript_tokenizer.new()
	var post := gnumarus_gdscript_post_tokenizer.new()
	return parse_tokens(post.process_tokens(tok.tokenize(source)))


## Collects leading trivia (comments) and annotations for the next node.
## NEWLINE / SEMICOLON separators are discarded; COMMENT / DOC_COMMENT /
## TYPE_INFO tokens are buffered in _pending_trivia. Returns annotations.
func _prepare_node() -> Array:
	var annotations: Array = []
	while not _at_end():
		var t := _peek_type()
		if t == "NEWLINE" or t == "SEMICOLON":
			_advance()
			continue
		if t == "COMMENT" or t == "DOC_COMMENT" or t == "TYPE_INFO":
			_pending_trivia.append(_advance())
			continue
		if t == "ANNOTATION":
			for a in _parse_annotations_raw():
				annotations.append(a)
			continue
		break
	return annotations


## Parses consecutive ANNOTATION tokens (with their parenthesized args).
## Does not skip anything else; the _prepare_node loop handles spacing.
func _parse_annotations_raw() -> Array:
	var out: Array = []
	while _peek_type() == "ANNOTATION":
		var tok := _advance()
		var args: Array = []
		if _peek_type() == "LPAREN":
			args = _parse_balanced("LPAREN", "RPAREN")
		out.append({"type": NODE_ANNOTATION_DECL, "name": tok["value"], "args": args, "line": tok["line"], "column": tok["column"]})
	return out


## First line of the node about to be parsed (annotations count as part
## of the node for adjacency purposes).
func _node_start_line(annotations: Array) -> int:
	if annotations.size() > 0:
		var first: Dictionary = annotations[0]
		return int(first.get("line", 0))
	return _line_at()


## Splits buffered trivia for a node starting at node_line.
## Returns [standalone_nodes, attached_tokens]: only the last buffered
## comment attaches, and only when it sits directly above the node
## (comment end line + 1 == node_line; merged multi-line comments end
## on their last line). Earlier comments precede other comments, so
## they become standalone siblings. Claims the file header on first
## use: the very first buffered comment goes to the SCRIPT root.
func _split_trivia(node_line: int) -> Array:
	_claim_header()
	var standalone: Array = []
	for c in _pending_trivia:
		standalone.append(_trivia_to_node(c))
	var attached: Array = []
	if _pending_trivia.size() > 0:
		var last: Dictionary = _pending_trivia[_pending_trivia.size() - 1]
		if _trivia_end_line(last) + 1 == node_line:
			attached = [last]
			standalone = standalone.slice(0, standalone.size() - 1)
	_pending_trivia.clear()
	return [standalone, attached]


## Last line covered by a trivia token (merged comment blocks span
## several lines joined by "\n"; plain tokens end on their own line).
func _trivia_end_line(tok: Dictionary) -> int:
	var start := int(tok.get("line", 0))
	var value := str(tok.get("value", ""))
	if value == "":
		return start
	return start + value.count("\n")


## Moves the very first buffered comment to the SCRIPT root, once.
func _claim_header() -> void:
	if _header_done:
		return
	_header_done = true
	if _pending_trivia.size() > 0:
		_header_comment = _pending_trivia[0]
		_pending_trivia = _pending_trivia.slice(1)


## Flushes every buffered comment as standalone siblings (no node follows).
func _flush_trivia_all() -> Array:
	_claim_header()
	var out: Array = []
	for c in _pending_trivia:
		out.append(_trivia_to_node(c))
	_pending_trivia.clear()
	return out


func _trivia_to_node(tok: Dictionary) -> Dictionary:
	return {"type": tok.get("type", NODE_COMMENT), "value": tok.get("value", ""), "line": tok.get("line", 0), "column": tok.get("column", 0)}


func _with_comments(node: Dictionary, attached: Array) -> Dictionary:
	node["leading_comments"] = attached
	return node


func _parse_top_decl() -> Array:
	var annotations := _prepare_node()
	if _at_end():
		if annotations.size() > 0:
			var tail_parts := _split_trivia(_node_start_line(annotations))
			return _finish_decl(_annotation_stmt(annotations), annotations, tail_parts)
		return _flush_trivia_all()
	var t := _peek_type()
	if t == "DEDENT" or t == "EOF":
		return _flush_trivia_all()
	if t == "INDENT":
		var parts := _split_trivia(_line_at())
		var out: Array = []
		for s in parts[0]:
			out.append(s)
		var err := _make_error("Unexpected indent at script level.", _peek())
		_advance()
		out.append(_with_comments(err, parts[1]))
		return out
	var v := _peek_value()
	var start_line := _node_start_line(annotations)
	var parts := _split_trivia(start_line)
	if t == "KEYWORD":
		if v == "class_name":
			return _finish_decl(_parse_class_name(annotations), annotations, parts)
		if v == "extends":
			return _finish_decl(_parse_extends(annotations), annotations, parts)
		if v == "signal":
			return _finish_decl(_parse_signal(annotations), annotations, parts)
		if v == "enum":
			return _finish_decl(_parse_enum(annotations), annotations, parts)
		if v == "const":
			return _finish_decl(_parse_const(annotations, false), annotations, parts)
		if v == "static":
			if _peek_type(1) == "KEYWORD" and _peek_value(1) == "func":
				return _finish_decl(_parse_func(annotations, true), annotations, parts)
			if _peek_type(1) == "KEYWORD" and _peek_value(1) == "var":
				return _finish_decl(_parse_var(annotations, true), annotations, parts)
			var node := _make_error("Expected 'func' or 'var' after 'static'.", _peek())
			_synchronize()
			return _finish_decl(node, annotations, parts)
		if v == "var":
			return _finish_decl(_parse_var(annotations, false), annotations, parts)
		if v == "func":
			return _finish_decl(_parse_func(annotations, false), annotations, parts)
		if v == "class":
			return _finish_decl(_parse_class(annotations), annotations, parts)
		return _parse_stmt(annotations)
	return _parse_stmt(annotations)


## Combines standalone trivia siblings with one finished decl node.
func _finish_decl(node: Dictionary, annotations: Array, parts: Array) -> Array:
	var out: Array = []
	for s in parts[0]:
		out.append(s)
	out.append(_with_comments(node, parts[1]))
	return out


func _annotation_stmt(annotations: Array) -> Dictionary:
	return {"type": NODE_ANNOTATION_DECL, "annotations": annotations, "line": _line_of_first(annotations), "column": 0}


func _parse_stmt(pre: Array = []) -> Array:
	var annotations: Array = []
	for a in pre:
		annotations.append(a)
	for a in _prepare_node():
		annotations.append(a)
	if _at_end():
		if annotations.size() > 0:
			var tail_parts := _split_trivia(_node_start_line(annotations))
			return _finish_decl(_annotation_stmt(annotations), annotations, tail_parts)
		return _flush_trivia_all()
	var t := _peek_type()
	if t == "DEDENT" or t == "EOF":
		return _flush_trivia_all()
	var v := _peek_value()
	var start_line := _node_start_line(annotations)
	var parts := _split_trivia(start_line)
	if t != "KEYWORD" and t != "IDENTIFIER" and t != "BUILTIN_TYPE" and t not in ["INT", "FLOAT", "STRING", "BOOL", "NULL", "STRING_NAME", "NODE_PATH", "GET_NODE", "UNIQUE_NAME", "LPAREN", "LBRACKET", "LBRACE", "OPERATOR", "DOT", "ANNOTATION", "INDENT"]:
		var bad := _make_error("Unexpected token '" + v + "'.", _peek())
		_advance()
		_synchronize()
		return _finish_decl(bad, annotations, parts)
	if t == "INDENT":
		var bad2 := _make_error("Unexpected indent.", _peek())
		_advance()
		return _finish_decl(bad2, annotations, parts)
	if t == "KEYWORD":
		if v == "var":
			return _finish_decl(_parse_var(annotations, false), annotations, parts)
		if v == "const":
			return _finish_decl(_parse_const(annotations, false), annotations, parts)
		if v == "static":
			if _peek_type(1) == "KEYWORD" and _peek_value(1) == "var":
				return _finish_decl(_parse_var(annotations, true), annotations, parts)
			if _peek_type(1) == "KEYWORD" and _peek_value(1) == "func":
				return _finish_decl(_parse_func(annotations, true), annotations, parts)
		if v == "func":
			if _peek_type(1) == "IDENTIFIER":
				return _finish_decl(_parse_func(annotations, false), annotations, parts)
			return _finish_decl(_parse_lambda_stmt(annotations), annotations, parts)
		if v == "class":
			return _finish_decl(_parse_class(annotations), annotations, parts)
		if v == "signal":
			return _finish_decl(_parse_signal(annotations), annotations, parts)
		if v == "enum":
			return _finish_decl(_parse_enum(annotations), annotations, parts)
		if v == "if":
			return _finish_decl(_parse_if(annotations), annotations, parts)
		if v == "for":
			return _finish_decl(_parse_for(annotations), annotations, parts)
		if v == "while":
			return _finish_decl(_parse_while(annotations), annotations, parts)
		if v == "match":
			return _finish_decl(_parse_match(annotations), annotations, parts)
		if v == "return":
			return _finish_decl(_parse_return(annotations), annotations, parts)
		if v == "break":
			return _finish_decl(_simple_keyword_node(NODE_BREAK_STMT, annotations), annotations, parts)
		if v == "continue":
			return _finish_decl(_simple_keyword_node(NODE_CONTINUE_STMT, annotations), annotations, parts)
		if v == "pass":
			return _finish_decl(_simple_keyword_node(NODE_PASS_STMT, annotations), annotations, parts)
		if v == "breakpoint":
			return _finish_decl(_simple_keyword_node(NODE_BREAKPOINT_STMT, annotations), annotations, parts)
		if v == "assert":
			return _finish_decl(_parse_assert(annotations), annotations, parts)
		if v == "class_name" or v == "extends":
			if v == "extends":
				return _finish_decl(_parse_extends(annotations), annotations, parts)
			var bad3 := _make_error("'" + v + "' is only valid at script level.", _peek())
			_synchronize()
			return _finish_decl(bad3, annotations, parts)
	return _finish_decl(_parse_expr_stmt(annotations), annotations, parts)


## Legacy helper, superseded by _prepare_node + _parse_annotations_raw.
## Kept for reference; do not use (it drops comments).
func _parse_annotations() -> Array:
	return _parse_annotations_raw()


func _parse_class_name(annotations: Array) -> Dictionary:
	var kw := _advance()
	if _peek_type() != "IDENTIFIER":
		var node := _make_error("Expected class name after 'class_name'.", _peek())
		_synchronize()
		return node
	var name := _advance()
	_end_stmt()
	return {"type": NODE_CLASS_NAME, "name": name["value"], "annotations": annotations, "line": kw["line"], "column": kw["column"]}


func _parse_extends(annotations: Array) -> Dictionary:
	var kw := _advance()
	var parts: Array = []
	if _peek_type() != "IDENTIFIER" and _peek_type() != "BUILTIN_TYPE":
		var node := _make_error("Expected base class after 'extends'.", _peek())
		_synchronize()
		return node
	parts.append(_advance())
	while _peek_type() == "DOT" and (_peek_type(1) == "IDENTIFIER" or _peek_type(1) == "BUILTIN_TYPE"):
		parts.append(_advance())
		parts.append(_advance())
	_end_stmt()
	return {"type": NODE_EXTENDS, "path": parts, "annotations": annotations, "line": kw["line"], "column": kw["column"]}


func _parse_signal(annotations: Array) -> Dictionary:
	var kw := _advance()
	if _peek_type() != "IDENTIFIER":
		var node := _make_error("Expected signal name after 'signal'.", _peek())
		_synchronize()
		return node
	var name := _advance()
	var params: Array = []
	if _peek_type() == "LPAREN":
		_advance()
		params = _parse_decl_params()
		if _peek_type() != "RPAREN":
			var node := _make_error("Expected ')' to close signal parameters.", _peek())
			_synchronize()
			return node
		_advance()
	_end_stmt()
	return {"type": NODE_SIGNAL_DECL, "name": name["value"], "params": params, "annotations": annotations, "line": kw["line"], "column": kw["column"]}


func _parse_enum(annotations: Array) -> Dictionary:
	var kw := _advance()
	var enum_name := ""
	if _peek_type() == "IDENTIFIER":
		enum_name = (_advance())["value"]
	if _peek_type() != "LBRACE":
		var node := _make_error("Expected '{' to open enum body.", _peek())
		_synchronize()
		return node
	_advance()
	var members: Array = []
	while not _at_end() and _peek_type() != "RBRACE":
		_skip_trivia()
		_gather_inline()
		if _peek_type() == "RBRACE":
			break
		if _peek_type() == "COMMA":
			_advance()
			continue
		if _peek_type() != "IDENTIFIER":
			members.append(_make_error("Expected enum member name.", _peek()))
			_synchronize_inside("RBRACE")
			continue
		var mparts := _split_trivia(_line_at())
		var m := _advance()
		var value: Variant = null
		if _peek_type() == "OPERATOR" and _peek_value() == "=":
			_advance()
			value = _parse_expr(["COMMA", "RBRACE"])
		var member := {"type": NODE_ENUM_MEMBER, "name": m["value"], "value": value, "line": m["line"], "column": m["column"]}
		for s in mparts[0]:
			members.append(s)
		member["leading_comments"] = mparts[1]
		members.append(member)
		_skip_trivia()
	if _peek_type() == "RBRACE":
		_advance()
	else:
		_error_at("Expected '}' to close enum body.", _peek())
	_end_stmt()
	return {"type": NODE_ENUM_DECL, "name": enum_name, "members": members, "annotations": annotations, "line": kw["line"], "column": kw["column"]}


func _parse_const(annotations: Array, is_static: bool) -> Dictionary:
	var kw := _peek()
	if _peek_type() == "KEYWORD" and _peek_value() == "static":
		_advance()
		is_static = true
	kw = _advance()
	if _peek_type() != "IDENTIFIER":
		var node := _make_error("Expected constant name after 'const'.", _peek())
		_synchronize()
		return node
	var name := _advance()
	var vartype: Variant = null
	if _peek_type() == "COLON":
		_advance()
		vartype = _parse_type(["OPERATOR", "NEWLINE", "SEMICOLON", "EOF", "DEDENT"])
	var value: Variant = null
	if _peek_type() == "OPERATOR" and (_peek_value() == "=" or _peek_value() == ":="):
		_advance()
		value = _parse_expr(["NEWLINE", "SEMICOLON", "DEDENT", "EOF"])
	else:
		_error_at("Expected '=' with value in const declaration.", _peek())
	_end_stmt()
	return {"type": NODE_CONST_DECL, "name": name["value"], "vartype": vartype, "value": value, "is_static": is_static, "annotations": annotations, "line": kw["line"], "column": kw["column"]}


func _parse_var(annotations: Array, is_static: bool) -> Dictionary:
	var kw := _peek()
	if _peek_type() == "KEYWORD" and _peek_value() == "static":
		_advance()
		is_static = true
	kw = _advance()
	if _peek_type() != "IDENTIFIER":
		var node := _make_error("Expected variable name after 'var'.", _peek())
		_synchronize()
		return node
	var name := _advance()
	var vartype: Variant = null
	if _peek_type() == "COLON":
		_advance()
		vartype = _parse_type(["OPERATOR", "COLON", "NEWLINE", "SEMICOLON", "EOF", "DEDENT"])
	var value: Variant = null
	if _peek_type() == "OPERATOR" and (_peek_value() == "=" or _peek_value() == ":="):
		_advance()
		if _peek_type() == "KEYWORD" and _peek_value() == "func" and _peek_type(1) == "LPAREN":
			value = _parse_lambda()
		else:
			value = _parse_expr(["COLON", "NEWLINE", "SEMICOLON", "DEDENT", "EOF"])
	var accessors: Variant = null
	if _peek_type() == "COLON":
		_advance()
		accessors = _parse_suite()
	else:
		_end_stmt()
	return {"type": NODE_VAR_DECL, "name": name["value"], "vartype": vartype, "value": value, "accessors": accessors, "is_static": is_static, "annotations": annotations, "line": kw["line"], "column": kw["column"]}


func _parse_func(annotations: Array, is_static: bool) -> Dictionary:
	var kw := _peek()
	if _peek_type() == "KEYWORD" and _peek_value() == "static":
		_advance()
		is_static = true
	kw = _advance()
	if _peek_type() != "IDENTIFIER":
		var node := _make_error("Expected function name after 'func'.", _peek())
		_synchronize()
		return node
	var name := _advance()
	if _peek_type() != "LPAREN":
		var node := _make_error("Expected '(' after function name.", _peek())
		_synchronize()
		return node
	_advance()
	var params := _parse_decl_params()
	if _peek_type() != "RPAREN":
		var node := _make_error("Expected ')' to close parameter list.", _peek())
		_synchronize()
		return node
	_advance()
	var return_type: Variant = null
	if _peek_type() == "OPERATOR" and _peek_value() == "->":
		_advance()
		return_type = _parse_type(["COLON", "NEWLINE", "SEMICOLON", "EOF", "DEDENT"])
	if _peek_type() == "NEWLINE" or _peek_type() == "SEMICOLON" or _peek_type() == "DEDENT" or _peek_type() == "EOF":
		_end_stmt()
		return {"type": NODE_FUNC_DECL, "name": name["value"], "params": params, "return_type": return_type, "body": null, "is_static": is_static, "annotations": annotations, "line": kw["line"], "column": kw["column"]}
	if _peek_type() != "COLON":
		var node := _make_error("Expected ':' before function body.", _peek())
		_synchronize()
		return node
	_advance()
	var body := _parse_suite()
	return {"type": NODE_FUNC_DECL, "name": name["value"], "params": params, "return_type": return_type, "body": body, "is_static": is_static, "annotations": annotations, "line": kw["line"], "column": kw["column"]}


func _parse_class(annotations: Array) -> Dictionary:
	var kw := _advance()
	if _peek_type() != "IDENTIFIER":
		var node := _make_error("Expected class name after 'class'.", _peek())
		_synchronize()
		return node
	var name := _advance()
	var extends_type: Variant = null
	if _peek_type() == "KEYWORD" and _peek_value() == "extends":
		_advance()
		extends_type = _parse_type(["COLON", "NEWLINE", "SEMICOLON", "EOF", "DEDENT"])
	if _peek_type() != "COLON":
		var node := _make_error("Expected ':' before class body.", _peek())
		_synchronize()
		return node
	_advance()
	var body := _parse_suite()
	return {"type": NODE_CLASS_DECL, "name": name["value"], "extends_type": extends_type, "body": body, "annotations": annotations, "line": kw["line"], "column": kw["column"]}


func _parse_decl_params() -> Array:
	var params: Array = []
	while not _at_end():
		_skip_trivia()
		_gather_inline()
		if _peek_type() == "RPAREN" or _peek_type() == "EOF":
			break
		if _peek_type() == "COMMA":
			_advance()
			continue
		if _peek_type() != "IDENTIFIER":
			params.append(_make_error("Expected parameter name.", _peek()))
			_synchronize_inside("RPAREN")
			continue
		var pparts := _split_trivia(_line_at())
		var p := _advance()
		var ptype: Variant = null
		if _peek_type() == "COLON":
			_advance()
			ptype = _parse_type(["OPERATOR", "COMMA", "RPAREN", "EOF"])
		var default: Variant = null
		if _peek_type() == "OPERATOR" and _peek_value() == "=":
			_advance()
			default = _parse_expr(["COMMA", "RPAREN"])
		var param := {"type": NODE_PARAM, "name": p["value"], "vartype": ptype, "default": default, "line": p["line"], "column": p["column"]}
		for s in pparts[0]:
			params.append(s)
		param["leading_comments"] = pparts[1]
		params.append(param)
	return params


func _parse_suite() -> Dictionary:
	_gather_inline()
	if _peek_type() == "NEWLINE":
		_advance()
		while _peek_type() == "NEWLINE" or _peek_type() == "SEMICOLON":
			_advance()
		while _peek_type() == "COMMENT" or _peek_type() == "DOC_COMMENT" or _peek_type() == "TYPE_INFO":
			_pending_trivia.append(_advance())
			while _peek_type() == "NEWLINE" or _peek_type() == "SEMICOLON":
				_advance()
		if _peek_type() != "INDENT":
			return {"type": NODE_BLOCK, "children": [], "line": _line_at(), "column": 0}
		_advance()
		var children: Array = []
		while not _at_end() and _peek_type() != "DEDENT" and _peek_type() != "EOF":
			_skip_trivia()
			if _peek_type() == "DEDENT" or _peek_type() == "EOF":
				break
			for node in _parse_stmt():
				children.append(node)
		if _peek_type() == "DEDENT":
			_advance()
		return {"type": NODE_BLOCK, "children": children, "line": _line_at(), "column": 0}
	var children: Array = []
	while not _at_end() and _peek_type() != "NEWLINE" and _peek_type() != "SEMICOLON" and _peek_type() != "DEDENT" and _peek_type() != "EOF":
		for node in _parse_stmt():
			children.append(node)
		if _peek_type() == "SEMICOLON":
			_advance()
			continue
		break
	_end_stmt()
	return {"type": NODE_BLOCK, "children": children, "line": _line_at(), "column": 0}


func _parse_if(annotations: Array) -> Dictionary:
	var kw := _advance()
	var cond := _parse_expr(["COLON"])
	if _peek_type() != "COLON":
		var node := _make_error("Expected ':' after if condition.", _peek())
		_synchronize()
		return node
	_advance()
	var then_body := _parse_suite()
	var elifs: Array = []
	var else_body: Variant = null
	var last_body: Dictionary = then_body
	while true:
		_skip_trivia()
		while _peek_type() == "COMMENT" or _peek_type() == "DOC_COMMENT" or _peek_type() == "TYPE_INFO":
			_pending_trivia.append(_advance())
			_skip_trivia()
		if _peek_type() == "KEYWORD" and _peek_value() == "elif":
			var ekw := _advance()
			var eparts := _split_trivia(ekw["line"])
			var econd := _parse_expr(["COLON"])
			if _peek_type() != "COLON":
				elifs.append(_make_error("Expected ':' after elif condition.", _peek()))
				_synchronize()
				continue
			_advance()
			var ebody := _parse_suite()
			var edict := {"condition": econd, "body": ebody, "line": ekw["line"], "column": ekw["column"]}
			edict["leading_comments"] = eparts[1]
			for s in eparts[0]:
				_append_body_child(last_body, s)
			elifs.append(edict)
			last_body = ebody
			continue
		if _peek_type() == "KEYWORD" and _peek_value() == "else":
			var elsekw := _advance()
			var elseparts := _split_trivia(elsekw["line"])
			if _peek_type() != "COLON":
				else_body = _make_error("Expected ':' after else.", _peek())
				_synchronize()
				break
			_advance()
			else_body = _parse_suite()
			for s in elseparts[0]:
				_append_body_child(last_body, s)
			if else_body is Dictionary:
				else_body["leading_comments"] = elseparts[1]
		break
	return {"type": NODE_IF_STMT, "condition": cond, "then": then_body, "elifs": elifs, "else_body": else_body, "annotations": annotations, "line": kw["line"], "column": kw["column"]}


## Appends a node to a BLOCK body (used for trivia stranded between
## if/elif/else parts, which cannot leave the IF node).
func _append_body_child(body: Variant, node: Dictionary) -> void:
	if body is Dictionary:
		var b: Dictionary = body
		if b.get("type", "") == NODE_BLOCK and b.has("children"):
			(b["children"] as Array).append(node)


func _parse_for(annotations: Array) -> Dictionary:
	var kw := _advance()
	_skip_trivia()
	var target: Variant = null
	if _peek_type() == "IDENTIFIER":
		target = _advance()
	else:
		var node := _make_error("Expected loop variable after 'for'.", _peek())
		_synchronize()
		return node
	if _peek_type() != "KEYWORD" or _peek_value() != "in":
		var node := _make_error("Expected 'in' after for loop variable.", _peek())
		_synchronize()
		return node
	_advance()
	var iter := _parse_expr(["COLON"])
	if _peek_type() != "COLON":
		var node := _make_error("Expected ':' after for iterable.", _peek())
		_synchronize()
		return node
	_advance()
	var body := _parse_suite()
	return {"type": NODE_FOR_STMT, "target": target, "iter": iter, "body": body, "annotations": annotations, "line": kw["line"], "column": kw["column"]}


func _parse_while(annotations: Array) -> Dictionary:
	var kw := _advance()
	var cond := _parse_expr(["COLON"])
	if _peek_type() != "COLON":
		var node := _make_error("Expected ':' after while condition.", _peek())
		_synchronize()
		return node
	_advance()
	var body := _parse_suite()
	return {"type": NODE_WHILE_STMT, "condition": cond, "body": body, "annotations": annotations, "line": kw["line"], "column": kw["column"]}


func _parse_match(annotations: Array) -> Dictionary:
	var kw := _advance()
	var subject := _parse_expr(["COLON"])
	if _peek_type() != "COLON":
		var node := _make_error("Expected ':' after match subject.", _peek())
		_synchronize()
		return node
	_advance()
	_gather_inline()
	if _peek_type() != "NEWLINE":
		var node := _make_error("Expected new indented block after match ':'.", _peek())
		_synchronize()
		return node
	_advance()
	while _peek_type() == "NEWLINE" or _peek_type() == "SEMICOLON":
		_advance()
	while _peek_type() == "COMMENT" or _peek_type() == "DOC_COMMENT" or _peek_type() == "TYPE_INFO":
		_pending_trivia.append(_advance())
		while _peek_type() == "NEWLINE" or _peek_type() == "SEMICOLON":
			_advance()
	if _peek_type() != "INDENT":
		return {"type": NODE_MATCH_STMT, "subject": subject, "branches": [], "annotations": annotations, "line": kw["line"], "column": kw["column"]}
	_advance()
	var branches: Array = []
	while not _at_end() and _peek_type() != "DEDENT" and _peek_type() != "EOF":
		_skip_trivia()
		if _peek_type() == "DEDENT" or _peek_type() == "EOF":
			break
		for node in _parse_match_branch():
			branches.append(node)
	if _peek_type() == "DEDENT":
		_advance()
	return {"type": NODE_MATCH_STMT, "subject": subject, "branches": branches, "annotations": annotations, "line": kw["line"], "column": kw["column"]}


func _parse_match_branch() -> Array:
	var annotations := _prepare_node()
	var start := _peek()
	var start_line := int(start.get("line", 0))
	if annotations.size() > 0:
		start_line = _node_start_line(annotations)
	var parts := _split_trivia(start_line)
	var pattern := _parse_pattern()
	if _peek_type() != "COLON":
		var node := _make_error("Expected ':' after match pattern.", _peek())
		_synchronize_branch()
		return _finish_decl(node, annotations, parts)
	_advance()
	var body := _parse_suite()
	var branch := {"type": NODE_MATCH_BRANCH, "pattern": pattern, "body": body, "line": start["line"], "column": start["column"]}
	return _finish_decl(branch, annotations, parts)


func _parse_pattern() -> Dictionary:
	var start := _peek()
	var tokens: Array = []
	var depth := 0
	while not _at_end():
		var t := _peek_type()
		if t == "EOF" or t == "DEDENT" or t == "NEWLINE" or t == "SEMICOLON":
			break
		if t == "LPAREN" or t == "LBRACKET" or t == "LBRACE":
			depth += 1
			tokens.append(_advance())
			continue
		if t == "RPAREN" or t == "RBRACKET" or t == "RBRACE":
			if depth > 0:
				depth -= 1
				tokens.append(_advance())
				continue
			break
		if depth > 0:
			tokens.append(_advance())
			continue
		if t == "COLON":
			break
		tokens.append(_advance())
	return {"type": NODE_PATTERN, "tokens": tokens, "line": start["line"], "column": start["column"]}


func _parse_return(annotations: Array) -> Dictionary:
	var kw := _advance()
	_skip_trivia_inline()
	if _peek_type() == "NEWLINE" or _peek_type() == "SEMICOLON" or _peek_type() == "DEDENT" or _peek_type() == "EOF":
		_end_stmt()
		return {"type": NODE_RETURN_STMT, "value": null, "annotations": annotations, "line": kw["line"], "column": kw["column"]}
	var value := _parse_expr(["NEWLINE", "SEMICOLON", "DEDENT", "EOF"])
	_end_stmt()
	return {"type": NODE_RETURN_STMT, "value": value, "annotations": annotations, "line": kw["line"], "column": kw["column"]}


func _parse_assert(annotations: Array) -> Dictionary:
	var kw := _advance()
	var call_args: Array = []
	if _peek_type() == "LPAREN":
		call_args = _parse_balanced("LPAREN", "RPAREN")
	else:
		var value := _parse_expr(["NEWLINE", "SEMICOLON", "DEDENT", "EOF"])
		call_args = [value]
	_end_stmt()
	return {"type": NODE_ASSERT_STMT, "args": call_args, "annotations": annotations, "line": kw["line"], "column": kw["column"]}


func _simple_keyword_node(ntype: String, annotations: Array) -> Dictionary:
	var kw := _advance()
	_end_stmt()
	return {"type": ntype, "annotations": annotations, "line": kw["line"], "column": kw["column"]}


func _parse_lambda_stmt(annotations: Array) -> Dictionary:
	var start := _peek()
	var lambda := _parse_lambda()
	_skip_trivia_inline()
	if _peek_type() == "NEWLINE" or _peek_type() == "SEMICOLON" or _peek_type() == "EOF" or _peek_type() == "DEDENT":
		_end_stmt()
		return {"type": NODE_EXPR_STMT, "expr": lambda, "annotations": annotations, "line": start["line"], "column": start["column"]}
	var rest := _parse_expr_continuation()
	rest["annotations"] = annotations
	_end_stmt()
	return rest


func _parse_lambda() -> Dictionary:
	var kw := _advance()
	if _peek_type() != "LPAREN":
		return {"type": NODE_SYNTAX_ERROR, "message": "Expected '(' after 'func' in lambda.", "line": kw["line"], "column": kw["column"]}
	_advance()
	var params := _parse_decl_params()
	if _peek_type() != "RPAREN":
		return {"type": NODE_SYNTAX_ERROR, "message": "Expected ')' to close lambda parameters.", "line": _line_at(), "column": 0}
	_advance()
	var return_type: Variant = null
	if _peek_type() == "OPERATOR" and _peek_value() == "->":
		_advance()
		return_type = _parse_type(["COLON", "NEWLINE", "SEMICOLON", "EOF", "DEDENT"])
	if _peek_type() != "COLON":
		return {"type": NODE_SYNTAX_ERROR, "message": "Expected ':' before lambda body.", "line": _line_at(), "column": 0}
	_advance()
	var body := _parse_suite()
	return {"type": NODE_LAMBDA, "params": params, "return_type": return_type, "body": body, "line": kw["line"], "column": kw["column"]}


func _parse_expr_stmt(annotations: Array) -> Dictionary:
	var start := _peek()
	if _peek_type() == "KEYWORD" and _peek_value() == "func" and _peek_type(1) == "LPAREN":
		var lambda := _parse_lambda()
		var tail := _parse_expr_tail(["NEWLINE", "SEMICOLON", "DEDENT", "EOF"])
		var tokens: Array = [{"type": "LAMBDA_MARKER", "value": lambda, "line": start["line"], "column": start["column"]}]
		for tk in tail["tokens"]:
			tokens.append(tk)
		_end_stmt()
		return {"type": NODE_EXPR_STMT, "expr": {"type": NODE_EXPR, "tokens": tokens, "line": start["line"], "column": start["column"]}, "annotations": annotations, "line": start["line"], "column": start["column"]}
	if _is_accessor_start():
		return _parse_accessor(annotations)
	var expr := _parse_expr(["NEWLINE", "SEMICOLON", "DEDENT", "EOF"])
	_end_stmt()
	return {"type": NODE_EXPR_STMT, "expr": expr, "annotations": annotations, "line": start["line"], "column": start["column"]}


func _parse_expr_continuation() -> Dictionary:
	var start := _peek()
	var tail := _parse_expr_tail(["NEWLINE", "SEMICOLON", "DEDENT", "EOF"])
	return {"type": NODE_EXPR_STMT, "expr": tail, "line": start["line"], "column": start["column"]}


func _is_accessor_start() -> bool:
	if _peek_type() != "IDENTIFIER":
		return false
	var word: String = _peek_value()
	if word != "set" and word != "get":
		return false
	var nt := _peek_type(1)
	var nv := _peek_value(1)
	if nt == "OPERATOR" and nv == "=":
		return true
	if nt == "LPAREN":
		return true
	if nt == "COLON":
		return true
	return false


func _parse_accessor(annotations: Array) -> Dictionary:
	var kw := _advance()
	var detail: Variant = null
	if _peek_type() == "OPERATOR" and _peek_value() == "=":
		_advance()
		detail = _parse_expr(["COMMA", "NEWLINE", "SEMICOLON", "DEDENT", "EOF"])
		while _peek_type() == "COMMA":
			_advance()
			_skip_trivia()
			if _peek_type() == "IDENTIFIER" and (_peek_value() == "set" or _peek_value() == "get"):
				var extra := _advance()
				if _peek_type() == "OPERATOR" and _peek_value() == "=":
					_advance()
					var extra_expr := _parse_expr(["COMMA", "NEWLINE", "SEMICOLON", "DEDENT", "EOF"])
					detail = {"alias_pair": [detail, {"name": extra["value"], "expr": extra_expr}]}
				break
			break
		_end_stmt()
		return {"type": NODE_ACCESSOR, "kind": kw["value"], "detail": detail, "annotations": annotations, "line": kw["line"], "column": kw["column"]}
	var params: Array = []
	if _peek_type() == "LPAREN":
		_advance()
		params = _parse_decl_params()
		if _peek_type() == "RPAREN":
			_advance()
	if _peek_type() != "COLON":
		var node := _make_error("Expected ':' after accessor header.", _peek())
		_synchronize()
		return node
	_advance()
	var body := _parse_suite()
	return {"type": NODE_ACCESSOR, "kind": kw["value"], "params": params, "body": body, "annotations": annotations, "line": kw["line"], "column": kw["column"]}


func _parse_type(stop: Array) -> Dictionary:
	var start := _peek()
	var tokens: Array = []
	var depth := 0
	while not _at_end():
		var t := _peek_type()
		if t == "LPAREN" or t == "LBRACKET" or t == "LBRACE":
			depth += 1
			tokens.append(_advance())
			continue
		if t == "RPAREN" or t == "RBRACKET" or t == "RBRACE":
			if depth > 0:
				depth -= 1
				tokens.append(_advance())
				continue
			break
		if depth > 0:
			if t == "NEWLINE" or t == "SEMICOLON" or t == "INDENT" or t == "DEDENT":
				_advance()
				continue
			if t == "COMMENT" or t == "DOC_COMMENT" or t == "TYPE_INFO":
				_pending_trivia.append(_advance())
				continue
			tokens.append(_advance())
			continue
		if t in stop or t == "EOF":
			break
		if t == "OPERATOR" and _peek_value() == "->":
			break
		if t == "COMMA":
			break
		tokens.append(_advance())
	return {"type": NODE_TYPE_REF, "tokens": tokens, "line": start["line"], "column": start["column"]}


func _parse_expr(stop: Array) -> Dictionary:
	var start := _peek()
	var tail := _parse_expr_tail(stop)
	return {"type": NODE_EXPR, "tokens": tail["tokens"], "line": start["line"], "column": start["column"]}


func _parse_expr_tail(stop: Array) -> Dictionary:
	var start := _peek()
	var tokens: Array = []
	var depth := 0
	while not _at_end():
		var t := _peek_type()
		if t == "EOF" or t == "DEDENT":
			break
		if t == "LPAREN" or t == "LBRACKET" or t == "LBRACE":
			depth += 1
			tokens.append(_advance())
			continue
		if t == "RPAREN" or t == "RBRACKET" or t == "RBRACE":
			if depth > 0:
				depth -= 1
				tokens.append(_advance())
				continue
			break
		if depth > 0:
			if t == "NEWLINE" or t == "SEMICOLON" or t == "INDENT" or t == "DEDENT":
				_advance()
				continue
			if t == "COMMENT" or t == "DOC_COMMENT" or t == "TYPE_INFO":
				_pending_trivia.append(_advance())
				continue
			tokens.append(_advance())
			continue
		if t in stop:
			break
		if t == "COLON":
			break
		if t == "NEWLINE" or t == "SEMICOLON":
			break
		if t == "INDENT":
			break
		tokens.append(_advance())
	return {"type": NODE_EXPR, "tokens": tokens, "line": start["line"], "column": start["column"]}


func _parse_balanced(open_t: String, close_t: String) -> Array:
	var collected: Array = []
	_advance()
	var depth := 1
	while not _at_end() and depth > 0:
		var t := _peek_type()
		if t == open_t:
			depth += 1
		if t == close_t:
			depth -= 1
			if depth == 0:
				_advance()
				break
		if t == "EOF":
			break
		if t == "NEWLINE" or t == "SEMICOLON" or t == "INDENT" or t == "DEDENT":
			_advance()
			continue
		if t == "COMMENT" or t == "DOC_COMMENT" or t == "TYPE_INFO":
			_pending_trivia.append(_advance())
			continue
		collected.append(_advance())
	return collected


func _parse_trivia_node() -> Dictionary:
	var tok := _advance()
	var ntype := NODE_COMMENT
	if tok["type"] == "DOC_COMMENT":
		ntype = NODE_DOC_COMMENT
	elif tok["type"] == "TYPE_INFO":
		ntype = NODE_TYPE_INFO
	_end_stmt_soft()
	return {"type": ntype, "value": tok["value"], "line": tok["line"], "column": tok["column"]}


func _eof_node() -> Dictionary:
	return {"type": NODE_EXPR_STMT, "expr": {"type": NODE_EXPR, "tokens": [], "line": _line_at(), "column": 0}, "annotations": [], "line": _line_at(), "column": 0}


func _make_error(message: String, tok: Dictionary) -> Dictionary:
	_error_count += 1
	return {"type": NODE_SYNTAX_ERROR, "message": message, "line": tok.get("line", 0), "column": tok.get("column", 0)}


func _error_at(message: String, tok: Dictionary) -> void:
	_error_count += 1


func _synchronize() -> void:
	while not _at_end():
		var t := _peek_type()
		if t == "NEWLINE" or t == "SEMICOLON":
			_advance()
			return
		if t == "DEDENT" or t == "EOF":
			return
		_advance()


func _synchronize_inside(stop_t: String) -> void:
	var depth := 0
	while not _at_end():
		var t := _peek_type()
		if t == stop_t and depth == 0:
			return
		if t == "NEWLINE" or t == "SEMICOLON" or t == "EOF":
			return
		if t == "LPAREN" or t == "LBRACKET" or t == "LBRACE":
			depth += 1
		if t == "RPAREN" or t == "RBRACKET" or t == "RBRACE":
			if depth > 0:
				depth -= 1
		_advance()


func _synchronize_branch() -> void:
	while not _at_end():
		var t := _peek_type()
		if t == "NEWLINE" or t == "DEDENT" or t == "EOF":
			return
		_advance()


func _end_stmt() -> void:
	_gather_inline()
	if _peek_type() == "NEWLINE" or _peek_type() == "SEMICOLON":
		_advance()


func _end_stmt_soft() -> void:
	if _peek_type() == "NEWLINE" or _peek_type() == "SEMICOLON":
		_advance()


func _skip_trivia() -> void:
	while _peek_type() == "NEWLINE" or _peek_type() == "SEMICOLON":
		_advance()


## Buffers COMMENT / DOC_COMMENT / TYPE_INFO tokens without consuming
## anything else. The buffered trivia is attached to the next node (or
## flushed as siblings) by the dispatchers.
func _gather_inline() -> void:
	while _peek_type() == "COMMENT" or _peek_type() == "DOC_COMMENT" or _peek_type() == "TYPE_INFO":
		_pending_trivia.append(_advance())


## Old comment skipper, superseded by _gather_inline. Kept for reference.
func _skip_trivia_inline() -> void:
	_gather_inline()


func _at_end() -> bool:
	return _pos >= _tokens.size() or _peek_type() == "EOF"


func _peek(offset: int = 0) -> Dictionary:
	var idx := _pos + offset
	if idx < 0 or idx >= _tokens.size():
		return {"type": "EOF", "value": "", "line": _line_at(), "column": 0}
	var tok: Dictionary = _tokens[idx]
	return tok


func _peek_type(offset: int = 0) -> String:
	return _peek(offset).get("type", "EOF")


func _peek_value(offset: int = 0) -> String:
	return str(_peek(offset).get("value", ""))


func _advance() -> Dictionary:
	if _pos < _tokens.size():
		var tok: Dictionary = _tokens[_pos]
		_pos += 1
		return tok
	return {"type": "EOF", "value": "", "line": _line_at(), "column": 0}


func _line_at() -> int:
	if _pos < _tokens.size():
		var tok: Dictionary = _tokens[_pos]
		return int(tok.get("line", 0))
	if _tokens.size() > 0:
		var last: Dictionary = _tokens[_tokens.size() - 1]
		return int(last.get("line", 0))
	return 0


func _line_of_first(items: Array) -> int:
	if items.size() > 0:
		var first: Dictionary = items[0]
		return int(first.get("line", 0))
	return _line_at()
