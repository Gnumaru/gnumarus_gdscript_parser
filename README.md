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
  Raw token runs stay inside `EXPR` / `TYPE_REF` / `PATTERN` nodes.
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
owner (`""`, `"Outer"`, `"Outer.Inner"`) so future rules can grow flow
analysis and type narrowing on top.

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
  `test_deprecated.gd` (`@deprecated` rule), `test_private.gd`
  (`@private` nested-family rule), `test_reuse.gd` (same instance
  parsing twice must give independent results).
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