class_name gnumarus_gdscript_post_tokenizer
extends RefCounted

## Post-processor for the gnumarus_gdscript_tokenizer output.
##
## Iterates the raw tokens and looks inside every COMMENT / DOC_COMMENT
## token for type annotation markers such as @param. A marker counts as
## a type annotation only when:
## - the `@` is glued to a `#` on its left, or separated from it by
##   1 or more whitespace chars (in practice: the char immediately to
##   the left of `@` must be `#`, space or tab), AND
## - the char immediately to the right of `@` is at least one letter
##   (A-Z, a-z or Unicode >= 128; digits and underscore do NOT count).
## Any COMMENT / DOC_COMMENT token containing such a marker is converted
## into a TYPE_INFO token (same value, line and column are preserved).
## Every other token passes through untouched.
##
## Usage with a token array:
##   var raw := gnumarus_gdscript_tokenizer.new().tokenize("var x := 1\n")
##   var post := gnumarus_gdscript_post_tokenizer.new()
##   var tokens: Array = post.process_tokens(raw)
## Usage with a tokenizer instance (it is iterable, so it is drained here):
##   var tokens: Array = post.process_tokenizer(tok)
## Usage with a file path or a source string:
##   var tokens: Array = post.process("res://script.gd")
##   var tokens: Array = post.process_text("var x := 1 # @param x\n")
## Direct iteration (every process_* method is just a collector over it):
##   var post := gnumarus_gdscript_post_tokenizer.new()
##   post.pending_tokens = raw
##   for token in post:
##       print(token)

const gnumarus_gdscript_tokenizer = preload('gnumarus_gdscript_tokenizer.gd')
const TOKEN_TYPE_INFO := "TYPE_INFO"

## Raw tokens staged for iteration. Only one iteration may be active
## at a time on the same instance (nested loops need separate instances).
## Set it before using `for token in post_tokenizer`.
var pending_tokens: Array = []

var _current: Dictionary = {}

## Processes an array of raw tokenizer tokens. Returns a new Array of
## token Dictionaries, with qualifying comments converted to TYPE_INFO.
func process_tokens(tokens: Array) -> Array:
	pending_tokens = tokens
	var ret: Array = []
	for tok in self:
		ret.push_back(tok)
	return ret


## Drains a gnumarus_gdscript_tokenizer instance (any iterable yielding
## token Dictionaries) and processes its tokens.
func process_tokenizer(tokenizer: RefCounted) -> Array:
	var collected: Array = []
	for tok in tokenizer:
		collected.push_back(tok)
	return process_tokens(collected)


## Processes raw GDScript source code passed as a string.
func process_text(text: String) -> Array:
	var tok := gnumarus_gdscript_tokenizer.new()
	return process_tokens(tok.tokenize_text(text))


## Processes either a file path (res://, user:// or OS path, when the
## file exists) or a raw GDScript source string, mirroring
## gnumarus_gdscript_tokenizer.tokenize().
func process(source: String) -> Array:
	var tok := gnumarus_gdscript_tokenizer.new()
	return process_tokens(tok.tokenize(source))


## Custom iterator protocol (see the "Custom iterators" docs):
## `for tok in post_tokenizer` yields every processed token.
## The step counter lives in the single-element `iter` array as
## documented; the staged list stays in pending_tokens.
func _iter_init(iter) -> bool:
	iter[0] = 0
	return _iter_next(iter)


func _iter_next(iter) -> bool:
	var idx := int(iter[0])
	if idx >= pending_tokens.size():
		return false
	iter[0] = idx + 1
	_current = _transform(pending_tokens[idx])
	return true


func _iter_get(_unused) -> Variant:
	return _current


## Returns the processed form of a single token: qualifying COMMENT /
## DOC_COMMENT tokens become TYPE_INFO, everything else passes through.
func _transform(token: Variant) -> Dictionary:
	if token is Dictionary:
		var ttype: String = token.get("type", "")
		if ttype == "COMMENT" or ttype == "DOC_COMMENT":
			var value: String = token.get("value", "")
			if has_type_annotation(value):
				return {
					"type": TOKEN_TYPE_INFO,
					"value": value,
					"line": token.get("line", 0),
					"column": token.get("column", 0),
				}
		return token
	return {"type": "UNKNOWN", "value": str(token), "line": 0, "column": 0}


## Checks whether a comment text contains a type annotation marker.
## See the class docs for the exact left/right rules.
static func has_type_annotation(value: String) -> bool:
	var length := value.length()
	for i in range(length):
		if value.unicode_at(i) != 64:
			continue
		if i == 0:
			continue
		var left := value.unicode_at(i - 1)
		if left != 35 and left != 32 and left != 9:
			continue
		if i + 1 >= length:
			continue
		var right := value.unicode_at(i + 1)
		if (right >= 65 and right <= 90) or (right >= 97 and right <= 122) or right >= 128:
			return true
	return false
