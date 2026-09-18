# gnumarus_gdscript_parser

A GDScript parser made in GDScript: tokenizer, syntactic parser, semantic
analyzer and comment-annotation analyzer for Godot 4.x GDScript files.

All classes are `RefCounted` and expose `class_name`, so they are usable
from any script in the project without preloads.

## Pipeline

```
source text (.gd)
  └─> GnumarusGodotProjectAnalyzerSuiteGdscriptTokenizer        flat token list (comments kept)
        └─> GnumarusGodotProjectAnalyzerSuiteGdscriptPostTokenizer   @-comments become TYPE_INFO
              └─> GnumarusGodotProjectAnalyzerSuiteGdscriptSyntaticParser   AST (syntax only)
                    └─> GnumarusGodotProjectAnalyzerSuiteGdscriptSemanticParser  semantic errors + data-dir user/*.json
                          └─> GnumarusGodotProjectAnalyzerSuiteGdscriptAnalyzer   annotation rules (@deprecated) + JSON update
```

`.godot/0GnumarusGodotProjectAnalyzerSuiteData/` (native + user data)
is produced once by
`GnumarusGodotProjectAnalyzerSuiteGodotTypesInfoDumper` and is ignored by git
(see `.gitignore`).

Minimal end-to-end example:

```gdscript
var syn := GnumarusGodotProjectAnalyzerSuiteGdscriptSyntaticParser.new()
var sem := GnumarusGodotProjectAnalyzerSuiteGdscriptSemanticParser.new()
var ana := GnumarusGodotProjectAnalyzerSuiteGdscriptAnalyzer.new()

var ast: Dictionary = sem.analyze(syn.parse("res://script.gd"), "res://script.gd")
print(ast["semantic_errors"], ast["user_types_written"])

var result: Dictionary = ana.analyze(ast, "res://script.gd")
print(result["warnings"], result["errors"])
```

Each stage below documents its own input, output and knobs.

## 1. GnumarusGodotProjectAnalyzerSuiteGdscriptTokenizer

Turns source text into a flat list of token Dictionaries:

```gdscript
{"type": "IDENTIFIER", "value": "health", "line": 12, "column": 4}
```

- Line numbers are 1-based, columns are 0-based character offsets.
- `tokenize(source)` accepts a file path (`res://`, `user://` or OS path,
  when the file exists) or a raw source string. `tokenize_text(text)`
  always treats the argument as source.
- The tokenizer is also an **iterator**: `tokenize()` / `tokenize_text()`
  just collect `for tok in self`. For manual iteration, stage the text
  in `pending_text` first (only one active iteration per instance):

```gdscript
var tok := GnumarusGodotProjectAnalyzerSuiteGdscriptTokenizer.new()
tok.pending_text = "var x := 1\n"
for token in tok:
    print(token)
```

- Comments are **never discarded**: `# ...` becomes `COMMENT`,
  `## ...` becomes `DOC_COMMENT`. Consecutive full-line comments of the
  same kind, separated by exactly one newline, merge into ONE token
  whose value joins the lines with `"\n"`. A blank line, a code line or
  a `#` vs `##` switch starts a new token. Trailing comments after code
  (`var x := 1 # note`) never merge:

```gdscript
# line one
# line two   # -> a single COMMENT token "# line one\n# line two"

# block a

# block b     # -> two COMMENT tokens (blank line splits them)
```

- Indentation is reported with `INDENT` / `DEDENT` / `NEWLINE` tokens
  (Python-style). Mixed tabs and spaces in the same file produce
  `ERROR` tokens; single bad tokens never stop the run
  (`ERROR` / `UNKNOWN` tokens instead). Unreadable files set
  `last_error` and return `[]`.
- Token types: `ANNOTATION`, `BOOL`, `BUILTIN_TYPE`, `COLON`, `COMMA`,
  `COMMENT`, `DEDENT`, `DOC_COMMENT`, `DOT`, `EOF`, `ERROR`, `FLOAT`,
  `GET_NODE` (`$Path`), `IDENTIFIER`, `INDENT`, `INT`, `KEYWORD`,
  `LBRACE`, `LBRACKET`, `LPAREN`, `NEWLINE`, `NODE_PATH` (`^"..."`),
  `NULL`, `OPERATOR`, `RBRACE`, `RBRACKET`, `RPAREN`, `SEMICOLON`,
  `STRING`, `STRING_NAME` (`&"..."`), `UNIQUE_NAME` (`%Name`),
  `UNKNOWN`. The stream always ends with `EOF`.

## 2. GnumarusGodotProjectAnalyzerSuiteGdscriptPostTokenizer

Iterates raw tokenizer tokens and converts comments carrying type
annotations into `TYPE_INFO` tokens. A comment counts when it contains
`@` **glued to a `#` on its left or separated from it by whitespace**,
followed by **at least one letter** (`A-Z`, `a-z`, Unicode ≥ 128 —
digits and underscore do not count):

```gdscript
# @deprecated Use new_api() instead.   # -> TYPE_INFO
# TODO fix this                        # -> stays COMMENT (no @letter)
# email@test.com                       # -> stays COMMENT (@ after letter)
```

Same value, line and column are preserved; every other token passes
through untouched.

```gdscript
var post := GnumarusGodotProjectAnalyzerSuiteGdscriptPostTokenizer.new()
var tokens: Array = post.process("res://script.gd")   # file or source, like tokenize()
var same: Array = post.process_text("var x := 1 # @param x\n")
var from_array: Array = post.process_tokens(raw_tokens)
var from_iter: Array = post.process_tokenizer(tok)    # drains a tokenizer instance
```

Like the tokenizer it is an iterator (`post.pending_tokens = raw`
then `for token in post`; every `process_*` method just collects the
loop). The static helper `has_type_annotation(value: String) -> bool`
tests a single comment string against the rule above.

## 3. GnumarusGodotProjectAnalyzerSuiteGdscriptSyntaticParser

Builds a complete AST Dictionary from post-tokenizer tokens. Syntax
ONLY: `var myvar: int = null` parses fine here; the semantic stage
flags the mismatch later. This class is **not** an iterator: each
`parse_*` returns the whole AST.

```gdscript
var post := GnumarusGodotProjectAnalyzerSuiteGdscriptPostTokenizer.new()
var syn := GnumarusGodotProjectAnalyzerSuiteGdscriptSyntaticParser.new()
var ast1: Dictionary = syn.parse_tokens(post.process("res://script.gd"))
var ast2: Dictionary = syn.parse_text("var x := 1\n")
var ast3: Dictionary = syn.parse("res://script.gd")
```

- Root shape:
  `{"type": "SCRIPT", "children": [...], "errors": int, "header_comment": Variant, "line": 1, "column": 0}`.
  Every node carries at least `type`, `line`, `column`; declarations
  add `name`, `params`, `value`, `body`, `branches`, `tokens`, etc.
  `VAR_DECL` / `CONST_DECL` also carry `op` (`"="`, `":="` or `""`
  when there is no initializer). Raw token runs stay inside `EXPR` /
  `TYPE_REF` / `PATTERN` nodes.
- Fault tolerant: each syntax error becomes a `SYNTAX_ERROR` node and
  parsing resumes at the next `NEWLINE` / `SEMICOLON` / `DEDENT` / `EOF`.
- Comments are kept twice: the very first comment of the file goes to
  the root as `header_comment`; a comment on its own line directly
  above a node (no blank line between, measured from the comment's
  **last** line) attaches to it under `leading_comments`; anything
  else becomes a standalone `COMMENT` / `DOC_COMMENT` / `TYPE_INFO`
  sibling. At a `DEDENT`, column-0 comments are held back so an outer
  level can still attach them.
- Node types: `SCRIPT`, `ANNOTATION_DECL`, `CLASS_NAME`, `EXTENDS`,
  `SIGNAL_DECL`, `ENUM_DECL`, `ENUM_MEMBER`, `CONST_DECL`, `VAR_DECL`,
  `FUNC_DECL`, `PARAM`, `TYPE_REF`, `CLASS_DECL`, `BLOCK`, `IF_STMT`,
  `FOR_STMT`, `WHILE_STMT`, `MATCH_STMT`, `MATCH_BRANCH`, `PATTERN`,
  `RETURN_STMT`, `BREAK_STMT`, `CONTINUE_STMT`, `PASS_STMT`,
  `BREAKPOINT_STMT`, `ASSERT_STMT`, `EXPR_STMT`, `EXPR`, `LAMBDA`,
  `ACCESSOR`, `COMMENT`, `DOC_COMMENT`, `TYPE_INFO`, `SYNTAX_ERROR`.

## 4. GnumarusGodotProjectAnalyzerSuiteGodotTypesInfoDumper

Runs a Godot executable with `--dump-extension-api` and converts the
(huge) `extension_api.json` into one small JSON file per native type.
Because the extension dump misses entries (`Object.free()` exists in
4.7.2 but is absent from it), every `Object`-inheriting class is then
completed with live `ClassDB` data — methods, signals, properties,
constants, enums — adding only what the dump lacks (dump data is
  never overridden; classes missing from the dump get a minimal entry).
  Builtin Variant types are not in `ClassDB`, so their missing enums
  and constants (`Color.RED`, `Vector2.Axis`) come from the doc XMLs:
  `merge_doc_data()` takes the engine `major.minor` from the dumped
  version and fetches
  `raw.githubusercontent.com/godotengine/godot/refs/heads/<MM>/doc/classes/<Name>.xml`
  (short branch form as fallback) with curl, then wget. Anything
  unfetchable — offline dumps included — is skipped and the dump
  continues normally; only raw-file URLs are attempted (scraping the
  github/docs HTML pages is fragile).
- Environments with neither curl nor wget use `HTTPRequest` as a last
  resort: `dump_all_async()` (await it — e.g. `await
  d.dump_all_async("/path/to/godot4.x86_64", self)` from a `SceneTree`
  script) tries curl/wget per URL first and the request node second.
  The sync `dump_all()` keeps curl/wget only, so library and analyzer
  paths never need awaiting.

```gdscript
var d := GnumarusGodotProjectAnalyzerSuiteGodotTypesInfoDumper.new()
var summary: Dictionary = d.dump_all("/path/to/godot4.x86_64")
var summary2: Dictionary = d.dump_all()  # falls back to the "godot" command
```

- Knobs: `godot_executable` (default `"godot"`), `output_base`
  (default `"res://.godot/0GnumarusGodotProjectAnalyzerSuiteData"`;
  accepts `res://`, `user://`, absolute or
  CWD-relative paths), `keep_dump_file` (default `false` — the
  intermediate `extension_api.json` is deleted after extraction),
  plus read-only `last_error`, `last_dump_path`, `last_summary`.
  Lower-level steps are exposed: `run_dump()`, `extract_from_file()`,
  `extract_from_data()`, `merge_classdb()`, `merge_doc_data()`,
  `write_infos()`. Failures never crash;
  `dump_all()` returns `{"ok": false, "error": ...}` instead.
- Layout (created when missing):
  `<base>/builtin/<Name>.json` (`String`, `Array`, `int`, …),
  `<base>/builtin/Variant.json` (synthesized root),
  `<base>/classes/<Name>.json` (`Node3D`, `Object`, …),
  `<base>/index.json` (type lists and counts).
- Every per-type file holds at minimum the type name, the inheritance
  chain with `Variant` as root (`int` → `Variant`;
  `Node3D` → `Node` → … → `Object` → `Variant`), the allowed operators
  with the expected type of each parameter
  (`{"op": "+", "left": "String", "right": "String",
  "right_kind": "value", "returns": "String", "origin": "api"}`),
  and static/instance methods with parameter list, expected types,
  default values and vararg presence
  (`{"name": "substr", "returns": "String", "is_vararg": false,
  "params": [{"name": "from", "type": "int", "has_default": false,
  "default": null}, ...]}`).
  Extra capability data (constructors, members, properties, signals,
  enums, constants, `indexing_return_type`) is included when available.
  Language operators (`is`, `as`) carry `"origin": "language"`;
  augmented assignments (`+=`, …) carry `"origin": "derived"` with
  `"derived_from"` set. Missing `return_type` means `"void"`;
  `typedarray::T` normalizes to `Array[T]`, `enum::X` to `int`.

## 5. GnumarusGodotProjectAnalyzerSuiteGdscriptSemanticParser

Walks a syntactic AST and checks semantic errors — unknown types,
static vs instance misuse (`FileAccess.close()` must be `file.close()`),
missing methods (walking ancestors, e.g. `RefCounted < Object <
Variant`), invalid operators (`myvar += null` with `myvar: int`),
wrong argument counts (defaults and varargs respected), assignments
to constants, unknown identifiers, bad assignments/returns, and
subscript rules (`node["name"]` needs a real property/method/constant;
`arr["x"]` is rejected; `arr[0]`, `dict[anything]`, `vec["x"]` are
fine). Fault tolerant like the stages above.

```gdscript
var ast: Dictionary = sem.analyze(syn.parse("res://script.gd"), "res://script.gd")
print(ast["semantic_errors"], ast["user_types_written"])
```

- Unknown type names resolve from the data-dir `builtin/<Name>.json`,
  then `classes/<Name>.json`, then
  `user/<Name>.json` (cached per call); a total miss is
  `"unknown type '<Name>'"`.
- Before returning, user type files are created/updated under
  `user/`: one per script `class_name` (or resource-path
  name for `class_name`-less scripts — `res://a/b.gd` becomes
  `a_b.json`, `anonymous` as last resort), plus one per inner class
  named by concatenating the path to it (`minha.classe.interna.json`).
  Each file lists enums, constants, signals, fields, static/instance
  functions and every other publicly accessible member.
- Error entries look like
  `{"kind": "missing_method", "message": "type 'FileAccess' has no
  method 'superlegal' (chain: FileAccess < RefCounted < Object <
  Variant)", "line": 12, "column": 4}`. Kinds: `unknown_type`,
  `static_access`, `missing_method`, `operator`, `arity`,
  `const_assign`, `undeclared`, `assign`, `subscript`.
- Pragmatic trust rules (no false positives by design): engine
  singletons (`Engine`, `OS`, `Input`, …), global utilities (`print`,
  `len`, `clampi`, …), `ALL_CAPS` global constants, and anything
  involving unknown, `Variant` or enum types are accepted without
  checks.

## 6. GnumarusGodotProjectAnalyzerSuiteGdscriptAnalyzer (annotation rules)

Interprets the `TYPE_INFO` comments of a semantic-parser AST and
checks the annotation rules, one rule at a time. The walk is
scope-aware (locals/parameters shadow members) and threads an explicit
owner (`""`, `"Outer"`, `"Outer.Inner"`). A separate flow pass then
walks function bodies in order carrying a type environment for
member verification and `typeof` guards (see below).

```gdscript
var result: Dictionary = ana.analyze(ast, "res://script.gd")
print(result["warnings"], result["errors"])  # result["ast"] is the modified AST
```

- Returns `{"ast": modified_ast, "errors": [...], "warnings": [...]}`;
  entries look like `{"kind", "message", "line", "column", "owner"}`.
  The AST root gains `analyzer_errors` / `analyzer_warnings`, and
  marked declaration nodes gain `"deprecated"` / `"private"` marks.
- Just before returning, the data-dir `user/*.json` files are
  updated with member flags plus per-file `analysis_errors` /
  `analysis_warnings`.

### Flow analysis (member calls + `typeof` guards)

After the annotation walk, a dedicated pass verifies method calls
against known types and narrows `Variant`s inside `typeof` guards:

```gdscript
extends Node

func myfunc():
    var myvar: Variant
    myvar.free()                    # ERROR: type 'Variant' has no method 'free()'
    if typeof(myvar) == TYPE_OBJECT:
        myvar.get_class()           # OK: narrowed to Object (which has get_class)
    myvar.free()                    # ERROR again: outside the guard, no guarantee
```

- Calls on a provably-known type missing the method error
  (`missing_method`, `type 'X' has no method 'm()'`), walking the
  `inheritance_chain` and following known call results
  (`n.get_child(0).queue_free()` verifies end to end).
- Objects are assumed to hold ONLY declared and inherited members
  (no dynamic script dispatch): a script member reached through a
  base type misses (`var n: Node` + `n.health` errors, even though a
  script could provide it at runtime). Script classes verify through
  their own tables, `extends` walk and engine fallback; `self`
  verifies against the current class (root `extends`, default
  `RefCounted`). Suppressing needs a type guard
  (`if n is Item: n.id` is clean). Member READS on `Object`-derived
  or script types error the same way (`missing_member`); builtin
  reads stay lenient (`Dictionary` keys are unknowable, `Variant`
  tops are dynamic). Enum reads carry their closed value set
  (`WithSignal.Mode.ON` verifies, `.NOPE` errors).
- Suppression-safe by construction: dynamic plain-`=` variables,
  untyped parameters, unknown types, `super` and call results without
  known returns never error. `new` is always allowed; signals accept
  their five methods.
- `if typeof(x) == TYPE_Y` narrows the `then` branch, `!=` narrows
  the `else` (a leading `not`/`!` flips); `elif` restarts from the
  entry types. `@var`/`@param` facts apply in order inside the flow.
- `x is Y` / `x is not Y` narrow the same way (single known type
  names). `is_instance_of(x, T)` accepts a type name, a
  `Variant.Type` constant (`TYPE_OBJECT`,
  `Variant.Type.TYPE_OBJECT`) or a variable holding one — locals,
  consts, members and parameter defaults initialized with such a
  constant are constant-folded (reassignments are not tracked):

```gdscript
extends Node

func myfunc():
    var myvar: Variant
    var typecode: Variant.Type = Variant.Type.TYPE_OBJECT
    if is_instance_of(myvar, typecode):
        myvar.get_class()       # OK: typecode proves Object
    if myvar is Node:
        myvar.queue_free()      # OK: narrowed to Node
```

- Not yet: assignment tracking, `and`/`or` compounds, loop-carried
  narrowing, unreachable detection, subscript result types, operator
  checking (the semantic pass owns operators).

## Annotations

Type annotations live in comments and follow the general shape:

```gdscript
# @annotationname param1 param2 ... lastparam
```

Only same-line text is read for now; multi-line struct/tuple
definitions with dictionaries and arrays are future work. A comment
counts as an annotation only under the post-tokenizer rule
(`@` glued to `#` or after whitespace, followed by a letter).
Type names in annotations are case-corrected silently: a lowercase
`string` resolves as `String` (in type position it can only mean the
type).

### `@deprecated`

Marks a whole script (file header comment) or a single member as
deprecated. Before a function it deprecates the whole function;
function parameters are explicitly NOT supported yet.

```gdscript
class_name OldLib
extends Node

# @deprecated Use new_api() instead.
func old_api() -> void:
    pass

# @deprecated
var legacy_flag := true

# @deprecated
signal changed

# @deprecated
enum Kind { SWORD }

# @deprecated
const MAX := 10

# @deprecated
class LegacyItem:
    pass

func user() -> void:
    old_api()            # WARNING: use of deprecated function 'old_api': Use new_api() instead.
    print(legacy_flag)   # WARNING: use of deprecated variable 'legacy_flag'
    LegacyItem.new()     # WARNING: use of deprecated class 'LegacyItem'
```

(A `@deprecated` tag as the very first comment of the file lands in
the AST `header_comment` and therefore marks the whole script — see
"Script root" below — instead of the following member.)

- Any use of a deprecated member warns: bare calls, `self.x`,
  `ClassName.x`, `Inner.x`, `Outer.Inner.x`, reads/writes, `await
  sig`, `sig.connect(...)` / `sig.emit(...)`, `Enum.Member`, bare
  members, and type references (`var x: OldClass`, `as`/`is`).
  A local or parameter with the same name shadows the member (no
  warning); a deprecated function calling itself still warns.
  A script marked deprecated at the root produces no internal
  warnings — the mark is recorded for cross-script use.
- Misuse is an error, not a warning:
  - `@deprecated` attached to a non-declaration (e.g. before `pass`)
    → `deprecated_misplaced`;
  - `@deprecated` before a function parameter →
    `deprecated_unsupported` (parameters are explicitly deferred).

### `@private`

Marks a member as usable only inside its nested family: the declaring
class itself, its ancestors and its descendants (transitively,
including the script root). Sibling classes and inheriting classes are
NOT family — uses from there are violations. It may precede any
static or instance member (functions, variables, nested classes,
enums, constants, signals), but never the file root, function
parameters or function-local variables.

```gdscript
extends Node

# @private
var _cache := 1

class Inner:
    func f() -> void:
        print(_cache)      # OK: inner code may use outer privates
        print(self._cache) # OK

class SibA:
    func f() -> void:
        print(SibB._x)     # ERROR: cannot use private variable 'SibB._x'
                           # outside class 'SibB' (siblings are not family)

class SibB:
    # @private
    var _x := 1

class Base:
    # @private
    var _v := 1

class Child extends Base:
    func f() -> void:
        print(self._v)     # ERROR: inheriting does not grant access
        print(_v)          # ERROR: same, bare form
```

- Checked everywhere names resolve: bare reads/writes/calls,
  `self.x`, `ClassName.x`, `Inner.x`, `Outer.Inner.x`, `await sig`,
  `sig.connect(...)` / `sig.emit(...)`, `Enum.Member`, type
  references (`var x: Inner`, `as`/`is`), `Inner.new()`, and
  `class Child extends Base` clauses. A local or parameter with the
  same name shadows the member (no error). Receivers of unknown type
  are skipped (name-based, single-file analysis).
- A use is a violation only outside the member's nested family
  (message: `cannot use private <kind> '<name>' outside class
  '<owner>'`, kind `private_use`, as an ERROR entry, never a
  warning).
- Misplaced tags are errors too (`private_misplaced`): file header /
  root, function parameters, function-local variables, and any
  non-declaration statement.

### `@return`

Declares a function return type. It may precede a function
declaration or a lambda (a statement whose value is a lambda, e.g.
`var f = func(): ...`): `"void"`, one type name (`# @return Node`)
or a union (`# @return Object|String|int`). `"void"` only works
alone.

```gdscript
extends Node

# @return void
func reset() -> void:
    pass

# @return Control
func make_button() -> Node:   # OK: Control inherits Node
    return Button.new()

# @return Node
func make_node() -> Control:  # ERROR: Node does not inherit Control
    pass

# @return Object|String|int
func describe():
    pass

# @return void
func bad() -> void:
    return 1                  # ERROR: cannot return a value from void function 'bad'

# @return int
func bare():
    return                    # ERROR: bare return in non-void function 'bare'

# @return int
var f = func():
    return 1                  # OK: lambdas work too
```

- Every named member must be a known type (the script class, script
  classes/enums, or a data-dir JSON file); unknown names error
  (`return_unknown_type`). Empty specs, non-identifiers, empty union
  arms and `void` combined with names error (`return_malformed`).
- When the function also has a `->` annotation, every `@return`
  member must equal it or inherit from it — narrower is fine,
  wider/unrelated is `return_mismatch`. Only simple `->` names are
  compared (`Array[int]`, dotted, ... skip the check).
- Value/bare presence is checked per function (`return_value`);
  nested lambdas/functions get their own check. Return VALUE
  compatibility is NOT inferred (flat token scan).
- Misplaced tags are errors (`return_misplaced`): file header, class
  name, variables, signals, parameters, and any statement that is not
  a function or a lambda. Marked nodes gain a `return_ann` stamp;
  nothing is written to the user JSON files.

### `@var`

Declares or redefines a variable type. It takes a name and a type
(`# @var myvar int|float`, unions with `|`): before a variable or
constant declaration the name must equal the declared one; anywhere
inside a function body it redefines the type of a visible variable
(locals, parameters and members). Never before function parameters.
Types may nest with brackets
(`# @var myvar int|tuple[int]|Dictionary[String|int,tuple[*,float]]`):
`|` splits at the current bracket level, `,` splits generic
arguments, whitespace is free, `*` is allowed inside brackets.
Every name must resolve; applications of known `@tuple` types check
arity and per-argument compatibility (see `@tuple`). Plain union arms
still narrow the declared type one by one; anonymous `tuple[...]`
reads as `Array` for narrowing. Full structural narrowing is future
work (generics milestone).

```gdscript
extends Node

# @var x Control
var x: Node                # OK: narrows the declared type

# @var y int
var y := 1                 # OK: := infers int from the literal

# @var z String
var z = 1                  # OK: plain = holds Variant, anything goes

func f(a: Node):
    var t: Node
    # @var t Control

    print(t)               # OK: narrows the local
    # @var t Object       # ERROR: Object is neither Node nor a subclass
    # @var nope int       # ERROR: no variable 'nope' in function 'f'
```

- Every type member must be known (`var_unknown_type`); every member
  must equal the declared type or inherit from it (`var_mismatch`,
  `Variant` accepts anything). Without an explicit vartype, `:=`
  infers from simple initializers (literals, arrays, dictionaries,
  known constructors, lambdas); plain `=` means Variant. Anything
  more complex skips the check.
- Shape errors are `var_malformed` (missing name/type, bad
  identifiers, `void`, empty union arms); wrong positions are
  `var_misplaced` (parameters, file root, non-variable statements,
  accessor bodies); missing or non-variable targets are
  `var_unknown`. Declarations gain a `var_ann` stamp.
- Order-insensitive like the rest of the analyzer: a `@var` sees all
  locals/params of its function. Narrowing a captured outer variable
  from a nested lambda checks existence but skips the type check;
  lambdas inside default values or call arguments are not scanned.

### `@param`

Declares a parameter type. It takes a name and a type
(`# @param myparam int|Object`, unions with `|`): directly before a
parameter (multiline parameter lists) or before the function/lambda
declaration using the parameters — possibly on nearby lines together
with `@return` and friends (consecutive lines merge into one token,
each pair is matched by name).

```gdscript
extends Node

# @param myparam1 int|Object
func myfunc1(myparam1):

    var mylambda = func(
        # @param myparam2 String|Object
        myparam2: Variant
    ):
        return

    return
```

- Same checks as `@var`: known members narrowing the declared
  vartype (untyped parameters accept anything). Error kinds:
  `param_misplaced` (anything that is not a parameter or its
  function/lambda — including floating uses mid-body),
  `param_malformed`, `param_unknown` (no parameter with that name),
  `param_unknown_type`, `param_mismatch`. Parameters gain a
  `param_ann` stamp.
- Like all member annotations, the block needs a first line above it:
  the very first comment of the file is the file header, never a
  member annotation.

### `@tuple`

Defines a fixed-shape tuple type: `# @tuple TupleName 5 int|string
float|bool Object Variant *` — name, **mandatory** size, then exactly
that many items. Items are `|`-unions of known names; `*` means
dynamic (`any`), `variant` means unknown (normalized to `Variant`).
Items may nest with brackets (`Dictionary[String,int]`,
`Pair[int]`): spaces inside brackets are rejoined, every nested name
must resolve, and applications of known `@tuple` items check arity
and per-argument compatibility (`tuple_mismatch`). Nested templates
must exist (two-pass: definition order is free).

```gdscript
extends Node

# @tuple Pair 2 int String
var x: Pair = [1, "a"]      # OK: length and elements conform
var y: Pair = [1, 2, 3]     # ERROR: expects 2 elements, got 3
var z: Pair = ["a", "b"]    # ERROR: element 0 expects 'int', got 'String'

func f():
    print(x[0])             # OK: int
    print(x[5])             # ERROR: index out of bounds
    print(x[i])             # OK: dynamic index yields Variant
    print(x.size())         # OK: tuples verify methods through Array
    x.bogus()               # ERROR: Array has no such method
```

- A tuple flows into `Array`/`Variant`/untyped positions; an `Array`
  flows in only as a conforming literal (checked at `var`/`const`
  declarations); different tuple names never mix (nominal typing).
  Definitions live top-level only (`tuple_misplaced` elsewhere);
  duplicates and name clashes with script/engine types error
  (`tuple_conflict`); bad shapes error (`tuple_malformed`,
  `tuple_unknown_type`, `tuple_mismatch`, `tuple_bounds`).
- Templates share `user/` with classes (one global type namespace)
  as `kind: "tuple"` JSONs (compatible keys plus `size` and
  `tuple_items`).
- Gaps (documented): call arguments, parameter defaults and function
  return values with tuple literals are unchecked; `is`/`as` accept
  tuple names without misuse checking; no subscript continuation
  (`t[0].foo()` skips the rest); `Tuple.new()` silently skipped.

### `@alias`

Declares a named type alias: `# @alias Name <type-expr> @endalias`.
The expression runs to `@endalias`, so it may span lines and hold
whitespace (after the first whitespace run comes the name, after the
second comes the expression). Any type expression the mini-parser
accepts works, including other aliases:

```gdscript
extends Node

# @alias number int|float @endalias
# @alias pairs
# tuple[int, String]
# @endalias

# @var x number
var x := 1                 # OK: int is in the alias

# @var y number
var y := "a"               # ERROR: neither int nor float is String
```

- Aliases are global: one `kind: "alias"` JSON per name under
  `user/`, usable from any file once written (use before that
  errors `*_unknown_type`, like any missing type). Definitions live
  top-level only (`alias_misplaced` elsewhere); duplicates, clashes
  with script/engine/template types and circular definitions error
  (`alias_conflict`); bad shapes error (`alias_malformed`,
  `alias_unknown_type`); tuple applications inside the expression
  check arity/compatibility (`alias_mismatch`). `void` is rejected.
- Uses narrow through expansion: `@var`/`@param` members and
  `@return`/`->` compatibility see the expanded heads, and tuple
  applications validate through aliases. Downstream stamps keep the
  alias name (opaque); `@implements` does not resolve aliases yet.
  Gaps (documented): alias heads never take arguments
  (`Num[int]` errors); no vartype (`var x: number`) support — the
  semantic parser is untouched.

### `@template`

Declares a file-local generic type variable: `# @template T` or
`# @template T of Bound`. Names work file-wide regardless of order
but never leave the file (no JSON is written or read). A bound, when
present, must be concrete (no template variables) and is validated
like any type expression:

```gdscript
extends Node

# @template TplT of int|float

# @var x TplT
var x: Variant              # OK: known name, narrowing deferred
```

- Definitions live top-level only (`template_misplaced` elsewhere);
  duplicates and clashes with script/engine/template types error
  (`template_conflict`); bad shapes error (`template_malformed`,
  `template_unknown_type`, `template_mismatch`). Template names in
  `@var`/`@param`/`@return` resolve as known.
- Calls to functions whose `@param`/`@return` reference template
  variables instantiate per call site (bare, `self.` and instance
  calls): arity with defaults, positional unification (one
  substitution per call, conflicting bindings error), bound checks,
  all as `template_mismatch`. The substituted return type flows into
  member chains (`self.id(1).bogus()` errors on `int`); unbound
  variables stay opaque (chain rest skipped, like unknown types).
  Argument inference covers literals, array/dictionary literals
  (`Array[T]` binds from `[1, 2]`), annotated/inferred locals and
  params; nested calls, member reads and operators read dynamic.
  Non-generic calls are unchecked exactly as before.
- Gaps (documented): `@generic` classes come next; `env` still
  carries flat heads (no tree flow across statements).

### `@generic`

Declares a class generic: `# @generic T1 T2` immediately before a
class declaration. Every name must be a file `@template` (never a
concrete type); the count is the class arity, tied to the instance.
The parameter list rides on the class rec and the class JSON
(`"generic": [...]`):

```gdscript
extends Node

# @template TplT
# @generic TplT
class GBox:
    # @param x TplT
    func setv(x):
        pass

func f():
    var b: GBox[int]       # OK: arity matches, bound checked
    b.setv(1)              # OK: TplT = int here
    b.setv("a")            # ERROR: expects 'int', got 'String'
```

- Vartypes (and `->` returns, and params) holding brackets validate
  against `@generic` classes: unknown or non-generic heads stay
  silent (engine generics like `Array[int]` keep working); arity and
  template bounds on arguments error `generic_mismatch`. Bare uses
  (`var b: GBox`) stay lenient (dynamic arguments).
- Member lookup substitutes through instance arguments: fields typed
  by class parameters read substituted, and method calls pre-bind
  class arguments before unifying the method's own variables
  (nested generics like `Box[TplU]` inside generic functions fall
  out). Inherited members stay opaque (no extends-with-args in v1),
  as do cross-file generic classes (in-memory only for now).
- Definitions accept classes at root or nested (`generic_misplaced`
  elsewhere); bad shapes error (`generic_malformed`: empty,
  duplicates, non-template names).
- Gaps (documented): the script root itself cannot be generic (no
  `CLASS_DECL` to attach to); `extends Box[int]` is unchecked;
  bare template names in vartypes/arrows (`var x: TplT`) error in
  the semantic pass (untouched) — use applications or annotations;
  methods cannot carry `@return` (pre-existing rule), so generic
  method returns flow only via `->` arrows.

### `@interface`

Declares an interface blueprint between `@interface Name` and a
mandatory `@endinterface`, single or multi-line (members split on any
whitespace; internals use `:`, `,` and `;`). Members: `var:name[:types]`
and `const:name[:types]` (bare means any), `func:name` (returns any, no
params), `func:name:Return[:params]`, `signal:name[:params]`,
`enum:Name:m1,m2` (names only). Only `var`/`func` take a leading
`static`. Params are `name:type` (bare means any) separated by `,`;
`;` starts the default-valued section (it may open the list);
`...`-prefixed params must be last. Signals take no defaults or
varargs. Funcs with `:` but empty return/params are invalid (write
`void`).

```gdscript
extends Node

# @interface Drawable
# var:visible:bool
# func:draw:void:canvas:CanvasItem
# signal:redrawn
# @endinterface
var d: Drawable     # OK: known name; assignments stay lenient
                    # until @implements checks conformance
```

- Definitions live top-level only; duplicates and clashes error
  (`interface_conflict`); bad shapes error (`interface_malformed`,
  `interface_unknown_type`). Written as `kind: "interface"` JSONs
  reusing class entry shapes (methods split static/instance, enum
  values and const values null). A `void` func return stays `"void"`
  (not `any`), so `@implements` can require it. No use checking yet:
  names resolve, assignments pass, member verification skips
  interface types.

### `@implements`

Claims conformance: `# @implements Name1 Name2` at the script root
(file header, before `extends`/`class_name`, or before any root
member) or immediately before a nested `class` (then it applies to
that class). Each name is any valid type except tuples: dotted
nested classes (`My.Inner`), structs, `@interface` names, native
classes (`Node2D`) and non-object types (`Vector2`).

```gdscript
extends Node2D

# @interface Drawable
# func:draw:void:canvas:CanvasItem
# @endinterface
# @implements Node2D Drawable
func draw(canvas: CanvasItem) -> void:
    pass
```

- Every directly-declared member of each target is checked against
  the class, own or inherited: methods (staticness, arity with
  defaults/vararg, contravariant params, covariant returns),
  fields/consts (compatible types), signals (arity + params),
  enums (all members present). Missing members error
  (`implements_mismatch`); unknown names error
  (`implements_unknown_type`); tuples are rejected
  (`implements_mismatch`); empty/misshapen tags error
  (`implements_malformed`); any other position errors
  (`implements_misplaced`). Dynamic (untyped) implementation sides
  pass; `void` interface returns require `void`-compatible
  implementations.

### `@struct`

Defines a fixed-shape struct type: `# @struct Point 2 x:int y:int`
— name, **mandatory** size, then exactly that many fields. A field is
`name` (dynamic, `any`), `name:Type` or `name:A|B`; `void` and
duplicates are rejected. Nested templates must exist (two-pass).
Structs reuse the class `fields` shape (`{name, type, types, any}`)
so every reader keeps working.

```gdscript
extends Node

# @struct Point 2 x:int y:int
var p: Point = {"x": 1, "y": 2}   # OK: exact keys, conforming values
var q: Point = {"x": 1}           # ERROR: missing field 'y'
var r: Point = {"x": 1, "y": 2, "z": 3}  # ERROR: expects 2 fields, got 3

func f():
    print(p.x)                    # OK: int
    print(p.nope)                 # ERROR: has no member 'nope'
    print(p["x"])                 # OK: literal keys resolve
    print(p.keys())               # OK: Dictionary methods work
```

- A struct flows into `Dictionary`/`Variant`/untyped positions; a
  `Dictionary` flows in only as a conforming literal (checked at
  `var`/`const` declarations); different struct names never mix.
  Definitions live top-level only; duplicates and clashes error
  (`struct_conflict`); bad shapes error (`struct_malformed`,
  `struct_unknown_type`, `struct_mismatch`). Same documented gaps as
  tuples (call args, defaults, returns, `is`/`as`, no continuation).

## Analyzer data layout

All pipeline data lives under
`.godot/0GnumarusGodotProjectAnalyzerSuiteData/` (inside `.godot`, so
it never pollutes the project tree):

- `builtin/<Name>.json` and `classes/<Name>.json`
  come from the dumper (plus `index.json`); the whole directory is
  gitignored and regenerated on demand (see "tests" below).
- `user/<Name>.json` is written by the semantic parser and
  updated by the analyzer: one file per script `class_name` (or
  resource-path name like `a_b.json` for `class_name`-less scripts),
  plus one dotted file per inner class (`Outer.json`,
  `Outer.Inner.json`, …). The analyzer adds `"private"` /
  `"deprecated"` flags on members plus per-file `analysis_errors` /
  `analysis_warnings`.

## tests

`./addons/0GnumarusGodotProjectAnalyzerSuite/tests/test.sh` (from the
project root) runs every
`addons/0GnumarusGodotProjectAnalyzerSuite/tests/test_*.gd` suite
headlessly inside this project's own directory
— no scratch copies needed. It exits 0 only when Godot exits 0 AND
the `ALL TESTS PASSED` marker is printed, so crashes can never look
green. `GODOT_BIN` overrides the engine path.

- `addons/0GnumarusGodotProjectAnalyzerSuite/tests/run_all.gd` loads
  each suite (they expose `run()`), prints a
  per-suite `PASS`/`FAIL` line plus the grand total. A suite that
  fails to load counts as a failure.
- `addons/0GnumarusGodotProjectAnalyzerSuite/tests/helpers.gd` holds
  the shared assertions: one instance per
  suite, `check()` per expectation, failed names via printerr.
- Suites: `test_fixture.gd` (tokenize → parse → analyze on the
  `tests/ValidScript0.gd` fixture, must come out clean),
  `test_native_guard.gd` (native database contract),
  `test_classdb_merge.gd` (ClassDB completion),
  `test_doc_fetch.gd` (doc XML enums/constants, offline-safe),
  `test_deprecated.gd` (`@deprecated` rule), `test_private.gd`
  (`@private` nested-family rule), `test_return.gd` (`@return` rule),
  `test_var.gd` (`@var` rule), `test_param.gd` (`@param` rule),
  `test_tuple.gd` (`@tuple` rule),
  `test_type_expr.gd` (nested type-expression mini-parser + tuple
  applications),
  `test_alias.gd` (`@alias` rule),
  `test_template.gd` (`@template` file-local variables + subst/unify IR),
  `test_generic_call.gd` (generic call instantiation),
  `test_generic.gd` (`@generic` classes),
  `test_struct.gd` (`@struct` rule),
  `test_interface.gd` (`@interface` rule),
  `test_implements.gd` (`@implements` rule),
  `test_flow.gd` (flow member checks + guards),
  `test_reuse.gd` (same instance parsing twice must give independent
  results).
- `addons/0GnumarusGodotProjectAnalyzerSuite/tests/ensure_native_types.gd`
  runs first: if the data-dir `builtin/`,
  `classes/` and `index.json` exist with content it exits
  immediately; otherwise it runs the dumper with the same engine
  binary, so a deleted data dir fully grows back
  (`FORCE_NATIVE_DUMP=1` regenerates even when present).
- The semantic parser and the analyzer enforce the same precondition
  on every `analyze()`: when the native database is missing they dump
  it on demand, and when the dump itself fails (e.g. no `godot`
  binary) they print an error and return early with a single
  `native_types` error entry instead of flooding unknown-type noise.
- Workflow: after any change to the pipeline scripts, run
  `./addons/0GnumarusGodotProjectAnalyzerSuite/tests/test.sh`. If checks that should pass fail (or vice
  versa), fix the code or the test — never both silently — and
  re-run until green.
- Test artifacts (`.godot/`, `*.uid`) are gitignored.

## Documentation maintenance

This README is part of the deliverable: implementing a new annotation
or changing an existing rule must update the corresponding section
here (placement, semantics, messages, error kinds, examples) in the
same change.