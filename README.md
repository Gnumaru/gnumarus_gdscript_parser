# gnumarus_gdscript_parser

A GDScript parser made in GDScript: tokenizer, syntactic parser, semantic
analyzer and comment-annotation analyzer for Godot 4.x GDScript files.

All classes are `RefCounted` and expose `class_name`, so they are usable
from any script in the project without preloads.

## Pipeline

```
source text (.gd)
  └─> gnumarus_gdscript_tokenizer        flat token list (comments kept)
        └─> gnumarus_gdscript_post_tokenizer   @-comments become TYPE_INFO
              └─> gnumarus_gdscript_syntatic_parser   AST (syntax only)
                    └─> gnumarus_gdscript_semantic_parser  semantic errors + types_info/user/*.json
                          └─> gnumarus_gdscript_analyzer   annotation rules (@deprecated) + JSON update
```

`types_info/` (native data) is produced once by
`gnumaru_godot_native_types_info_dumper` and is ignored by git
(see `.gitignore`).

Minimal end-to-end example:

```gdscript
var syn := gnumarus_gdscript_syntatic_parser.new()
var sem := gnumarus_gdscript_semantic_parser.new()
var ana := gnumarus_gdscript_analyzer.new()

var ast: Dictionary = sem.analyze(syn.parse("res://script.gd"), "res://script.gd")
print(ast["semantic_errors"], ast["user_types_written"])

var result: Dictionary = ana.analyze(ast, "res://script.gd")
print(result["warnings"], result["errors"])
```

Each stage below documents its own input, output and knobs.

## 1. gnumarus_gdscript_tokenizer

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
var tok := gnumarus_gdscript_tokenizer.new()
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

## 2. gnumarus_gdscript_post_tokenizer

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
var post := gnumarus_gdscript_post_tokenizer.new()
var tokens: Array = post.process("res://script.gd")   # file or source, like tokenize()
var same: Array = post.process_text("var x := 1 # @param x\n")
var from_array: Array = post.process_tokens(raw_tokens)
var from_iter: Array = post.process_tokenizer(tok)    # drains a tokenizer instance
```

Like the tokenizer it is an iterator (`post.pending_tokens = raw`
then `for token in post`; every `process_*` method just collects the
loop). The static helper `has_type_annotation(value: String) -> bool`
tests a single comment string against the rule above.

## 3. gnumarus_gdscript_syntatic_parser

Builds a complete AST Dictionary from post-tokenizer tokens. Syntax
ONLY: `var myvar: int = null` parses fine here; the semantic stage
flags the mismatch later. This class is **not** an iterator: each
`parse_*` returns the whole AST.

```gdscript
var post := gnumarus_gdscript_post_tokenizer.new()
var syn := gnumarus_gdscript_syntatic_parser.new()
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

## 4. gnumaru_godot_native_types_info_dumper

Runs a Godot executable with `--dump-extension-api` and converts the
(huge) `extension_api.json` into one small JSON file per native type:

```gdscript
var d := gnumaru_godot_native_types_info_dumper.new()
var summary: Dictionary = d.dump_all("/path/to/godot4.x86_64")
var summary2: Dictionary = d.dump_all()  # falls back to the "godot" command
```

- Knobs: `godot_executable` (default `"godot"`), `output_base`
  (default `"types_info"`; accepts `res://`, `user://`, absolute or
  CWD-relative paths), `keep_dump_file` (default `false` — the
  intermediate `extension_api.json` is deleted after extraction),
  plus read-only `last_error`, `last_dump_path`, `last_summary`.
  Lower-level steps are exposed: `run_dump()`, `extract_from_file()`,
  `extract_from_data()`, `write_infos()`. Failures never crash;
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

## 5. gnumarus_gdscript_semantic_parser

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

- Unknown type names resolve from `types_info/builtin/<Name>.json`,
  then `types_info/classes/<Name>.json`, then
  `types_info/user/<Name>.json` (cached per call); a total miss is
  `"unknown type '<Name>'"`.
- Before returning, user type files are created/updated under
  `types_info/user/`: one per script `class_name` (or resource-path
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

## 6. gnumarus_gdscript_analyzer (annotation rules)

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
- Just before returning, the `types_info/user/*.json` files are
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
- Suppression-safe by construction: dynamic plain-`=` variables,
  untyped parameters, unknown types, `self`/`super`, script classes
  and member READS never error (reads only guide continuation, like
  the semantic pass). `new` is always allowed; signals accept their
  five methods.
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
  classes/enums, or a `types_info` file); unknown names error
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

## types_info layout

- `types_info/builtin/<Name>.json` and `types_info/classes/<Name>.json`
  come from the dumper (plus `index.json`); the whole directory is
  gitignored and regenerated on demand (see "tests" below).
- `types_info/user/<Name>.json` is written by the semantic parser and
  updated by the analyzer: one file per script `class_name` (or
  resource-path name like `a_b.json` for `class_name`-less scripts),
  plus one dotted file per inner class (`Outer.json`,
  `Outer.Inner.json`, …). The analyzer adds `"private"` /
  `"deprecated"` flags on members plus per-file `analysis_errors` /
  `analysis_warnings`.

## tests

`./tests/test.sh` (from the project root) runs every
`tests/test_*.gd` suite headlessly inside this project's own directory
— no scratch copies needed. It exits 0 only when Godot exits 0 AND
the `ALL TESTS PASSED` marker is printed, so crashes can never look
green. `GODOT_BIN` overrides the engine path.

- `tests/run_all.gd` loads each suite (they expose `run()`), prints a
  per-suite `PASS`/`FAIL` line plus the grand total. A suite that
  fails to load counts as a failure.
- `tests/helpers.gd` holds the shared assertions: one instance per
  suite, `check()` per expectation, failed names via printerr.
- Suites: `test_fixture.gd` (tokenize → parse → analyze on the
  `tests/ValidScript0.gd` fixture, must come out clean),
  `test_native_guard.gd` (native database contract),
  `test_deprecated.gd` (`@deprecated` rule), `test_private.gd`
  (`@private` nested-family rule), `test_return.gd` (`@return` rule),
  `test_var.gd` (`@var` rule), `test_param.gd` (`@param` rule),
  `test_flow.gd` (flow member checks + `typeof` guards),
  `test_reuse.gd` (same instance parsing twice must give independent
  results).
- `tests/ensure_native_types.gd` runs first: if `types_info/builtin/`,
  `types_info/classes/` and `index.json` exist with content it exits
  immediately; otherwise it runs the dumper with the same engine
  binary, so a deleted `types_info/` fully grows back
  (`FORCE_NATIVE_DUMP=1` regenerates even when present).
- The semantic parser and the analyzer enforce the same precondition
  on every `analyze()`: when the native database is missing they dump
  it on demand, and when the dump itself fails (e.g. no `godot`
  binary) they print an error and return early with a single
  `native_types` error entry instead of flooding unknown-type noise.
- Workflow: after any change to the pipeline scripts, run
  `./tests/test.sh`. If checks that should pass fail (or vice
  versa), fix the code or the test — never both silently — and
  re-run until green.
- Test artifacts (`types_info/`, `.godot/`, `*.uid`) are gitignored.

## Documentation maintenance

This README is part of the deliverable: implementing a new annotation
or changing an existing rule must update the corresponding section
here (placement, semantics, messages, error kinds, examples) in the
same change.