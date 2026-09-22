# Gnumaru's Godot Project Analyser Suite

> Short on time? Start with the [project overview](../../README.md):
> what the analyzer and the editor addon do for you in two minutes.

A suite of tools written in gdscript for making static analysis of godot 4 projects.
Can be run from the CLI without oppening the editor, but need a godot executable anyways
for headlessly running the gdscripts. Generate artifact files with analysis information
and found errors. Also implements and editor addon to show errors in real time.

All classes are `RefCounted` and expose `class_name`, so they are usable
from any script in the project without preloads. Declared class names are verbose so almost
guaranteed to not clash with your own class names.

## Pipeline

```
source text (.gd)
  └─> GnumarusGodotProjectAnalyzerSuiteGdscriptTokenizer        flat token list (comments kept)
        └─> GnumarusGodotProjectAnalyzerSuiteGdscriptPostTokenizer   @-comments become TYPE_INFO
              └─> GnumarusGodotProjectAnalyzerSuiteGdscriptSyntaticParser   AST (syntax only)
                    └─> GnumarusGodotProjectAnalyzerSuiteGdscriptSemanticParser  semantic errors + data-dir user/*.json
                          └─> GnumarusGodotProjectAnalyzerSuiteGdscriptAnalyzer   annotation + nullability rules + cross-script JSON update
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
  updated with member flags, per-method nullability signatures and
  per-file `analysis_errors` / `analysis_warnings` (see "Analyzer
  data layout").

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
  known returns never error from type uncertainty — only proven-null
  uses error (`null_access`), in every policy. `new` is always
  allowed; signals accept their five methods.
- `if typeof(x) == TYPE_Y` narrows the `then` branch, `!=` narrows
  the `else` (a leading `not`/`!` flips); every `elif` narrows from
  the accumulated previous-failed state, never from entry (conditions
  verify in the state where they run). `@var`/`@param` facts apply in
  order inside the flow.
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

- Not yet: `and`/`or` compounds, loop-carried narrowing (beyond
  `while`/`if` guards), unreachable detection, subscript result
  types, operator checking (the semantic pass owns operators).
  Assignment state is fully tracked instead: `= null` sets exact
  heads, provably-non-null writes mark (distrust) or revert, unknown
  writes reset; call results taint and flow through generics.
- Block scope: names declared in `if`/`for`/`while`/`match` blocks
  (and `for` targets) die with their block in the usage walk, and
  declaration lookups resolve to what is visible at the use line
  (source-order replay with real block frames) — member-call bases,
  free-`@var` targets, guard targets (`== null`, bare truthiness,
  `is`, `typeof`, `is_instance_of`), `Variant.Type` constant holders
  and `x = ...` reassignment targets all see the same visible
  declaration, so a block-nested shadower never hides a later
  function-level redeclaration while inner uses still see the
  shadower.

## 7. GnumarusGodotProjectAnalyzerSuiteTextResourceParser

Parses Godot scene, resource and config files (`.tscn`, `.tres`,
`project.godot`, or any raw text in the same INI-like format).
Unlike the GDScript pipeline it builds no abstract syntax tree: it
converts the file straight into nested Arrays and Dictionaries that
are easy to manipulate from code.

```gdscript
var scene := GnumarusGodotProjectAnalyzerSuiteTextResourceParser.new()
var data: Dictionary = scene.parse("res://scene.tscn")
print(data["kind"], (data["nodes"] as Array).size())
var same: Dictionary = scene.parse_text("[resource]\na = 1\n")
```

- `parse(source)` accepts a file path (`res://`, `user://` or OS
  path, when the file exists) or a raw source string;
  `parse_text(text)` always treats the argument as source. The same
  instance may be reused: every call resets `last_error`, the error
  counters and the value-tokenizer cursors, so results never leak.
- Result shape:
  `{"kind", "header", "globals", "sections", "ext_resources",
  "sub_resources", "nodes", "resources", "errors", "error_list",
  "path"}`. `kind` is `"scene"` (`[gd_scene]`), `"resource"`
  (`[gd_resource]`) or `"config"` (anything else, e.g.
  `project.godot`). `header` holds the leading `[gd_scene]` /
  `[gd_resource]` block (`{"section", "attrs", "line"}`); files
  without one get an empty header. Assignments before the first
  section (e.g. `config_version=5`) go to `globals`.
- Every section is
  `{"section", "attrs", "props", "line"}` in file order; the
  `ext_resources` / `sub_resources` / `nodes` / `resources` arrays
  reference the same Dictionaries (no copies). `attrs` holds
  unwrapped scalars (`[node name="X" type="Node3D"]` gives
  `{"name": "X", "type": "Node3D"}`); `props` maps each property
  name (including slashed ones like `script/source`) to a value node.
- Value nodes always carry `type`, `line` and `raw`: `null`,
  `bool`, `int`, `float`, `string` (escape-decoded), `string_name`
  (`&"..."`), `node_path` (`^"..."`), `identifier` (dotted names
  joined), `array` (`items`), `dict` (`entries` as
  `[{"key", "value"}]` pairs, `:` or `=` separators), `call`
  (`name` + `args`: `Color(...)`, `Vector2(...)`,
  `Transform3D(...)`, `ExtResource(...)`, `SubResource(...)`,
  `PackedStringArray(...)`, ...) and `invalid` (kept, plus an error
  entry). Nesting past 64 levels errors instead of recursing forever.
- Comments start with `;` outside strings at bracket depth 0 and run
  to the physical line end. Values may span physical lines inside
  brackets or inside a quoted string (the multiline `script/source`
  string and multi-row arrays/dicts); the starting physical line is
  kept on every section and value node. Fault tolerant like the
  stages above: each bad header/value becomes an entry in
  `error_list` (`{"message", "line"}`) and parsing continues.

## 8. GnumarusGodotProjectAnalyzerSuiteUidCache

Reads Godot's UID cache (`.godot/uid_cache.bin`), resolving every
resource UID to its path and back. The binary layout is tiny (see
`ResourceUID::save/load` in `core/io/resource_uid.cpp`): uint32 LE
entry count, then per entry int64 LE id, int32 LE UTF-8 byte length,
and the raw path bytes. IDs convert to `"uid://..."` text as
base-34 (alphabet `a-y`, `0-8`) masked to 63 bits.

```gdscript
var cache := GnumarusGodotProjectAnalyzerSuiteUidCache.new().parse("res://.godot/uid_cache.bin")
print(cache["by_path"].get("res://scene.tscn", ""))
```

- `parse(path)` reads the cache file (missing/unreadable files yield
  `errors == 1` instead of crashing); `parse_bytes(data)` parses raw
  bytes for hermetic tests. The same instance may be reused: every
  call resets `last_error` and the result maps. Truncated tails are
  reported as errors while keeping the entries decoded so far.
- Result shape:
  `{"entries": [{"id", "uid", "path"}], "by_uid", "by_path",
  "errors", "error_list", "path"}`. Static helpers `id_to_text()`,
  `text_to_id()` (malformed text gives `-1`) and `encode_entry()`
  (builds synthetic bytes) round-trip exactly against the engine:
  every local cache entry decodes byte-exact and matches every
  `.uid` sidecar.
- Pairs well with the scene parser: an `ExtResource`/`SubResource`
  uid from a `.tscn` resolves through `by_uid` to its `res://` path.

## 9. GnumarusGodotProjectAnalyzerSuiteResourceIntegrity

Report-only integrity checker for textual resources (`.tscn`,
`.tres`, `project.godot`) plus every static resource string in
GDScript (`.gd`), deliberately separate from the GDScript analyzer
(which owns inference, not file references). Walks each file for
resource paths (`res://...`)
and UIDs (`uid://...`): referenced files must exist, UIDs must be
well-formed and present in `uid_cache.bin`, and cache entries must
point at existing files (an `[ext_resource]` declaring both must
agree with the cache). `.uid` sidecars are the third source of truth
for path-anchored references (the file's own header uid and
`[ext_resource]` entries): a declaration disagreeing with its
sidecar is a `sidecar_mismatch` error even with no cache, while a uid
missing from the cache whose sidecar agrees is only a `stale_cache`
warning instead of a `missing_uid` error. Also reports dangling `ExtResource()` /
`SubResource()` ids, duplicate ids and malformed entries; declared
but unused ext ids are warnings. Only whole-value single-line
strings are checked, so multiline embedded code (`script/source`)
and sentence fragments never false-positive. `.gd` files are scanned
at the token level (never parsed): trigger literals keep their
labels — `preload("...")`, bare `load("...")`,
`ResourceLoader.load("...")`, `extends "..."` and `@icon("...")`,
with real token line/column — and every other static string in any
quoting (single, double, triple-double: assignments, call args) plus
every `#`/`##` comment is scanned for embedded references at
in-token positions (trailing sentence punctuation and `:line[:col]`
suffixes stripped, so `path:line` log idioms resolve). Out of scope
by construction: dynamic operands (`"res://" + name, "res://%s" %
x`), custom `obj.load()` calls, existence probes
(`FileAccess.file_exists(X)`, `*.exists(X)` — a question, not a
demand), bare prefixes, backslash-escaped meta content (example code
nested in an outer string) and directories (a trailing-slash
reference resolving to a dir counts as existing). Two opt-outs:
`# @integrity_ignore` (trailing, suppresses its own line) and
`# @integrity_ignore_file` (leading comment block only, exempts the
file — for sources deliberately trafficking in virtual paths, like
the analyzer test harnesses). Empty UID maps mean
"unverifiable" (uid presence/agreement skipped), so a missing cache
degrades to path-only checking.

```gdscript
var cache := GnumarusGodotProjectAnalyzerSuiteUidCache.new().parse("res://.godot/uid_cache.bin")
var res := GnumarusGodotProjectAnalyzerSuiteResourceIntegrity.new().analyze_file(
    "res://scene.tscn", cache.get("by_uid", {}), cache.get("by_path", {}))
```

- Standalone CLI (no writes, exits 0 clean / 1 issues / 2 infra):
  `godot --headless --path . --script
  res://addons/0GnumarusGodotProjectAnalyzerSuite/check_resource_integrity.gd`
  (optional `res://` paths after `--` check only those files).
  Prints `checking [i/n] path` progress plus one
  `path:line: kind message` line per issue.
- Live in the editor: every `analyze_current` run also token-scans
  the current `.gd` buffer (unsaved text included), so broken
  `preload()`/`load()`/`extends`/`@icon()` refs surface on open,
  edit and hotkey runs without waiting for a full scan — merged with
  the analyzer issues (tagged `resource_integrity`, like the report)
  in the status bar and the dock. UID maps come from
  `.godot/uid_cache.bin`, cached by file mtime; any filesystem scan
  (save/create/delete elsewhere) flags the live pass dirty, forcing
  one recheck even on an unchanged buffer.

## 10. GnumarusGodotProjectAnalyzerSuiteFullScan

Project-wide aggregator over every static-analysis pass, runnable
two ways: the `GnumarusGodotProjectAnalyzerSuiteFullScan`
`@tool` `EditorScript` (Script Editor File > Run) and the
`Gnumarus Full Scan` entry under Project > Tools (registered by the
analyzer plugin via `add_tool_menu_item`, removed on exit). Both are
dumb forwards: every behavior lives in
`GnumarusGodotProjectAnalyzerSuiteFullScanImpl` (RefCounted, no
Editor dependency, headless-testable — the same proxy split as the
analyzer plugin itself).

`run()` executes each stage in order — currently `gdscript` (the
full analyzer over every project `.gd`) and `resource_integrity`
(text resources plus `.gd` load literals) — and each stage persists
`ScanResults.json` when it finishes, so the report stays complete
even if a later stage is interrupted. Future stages only add a stage
name plus one `store_stage()` call: the report merges generically
(load on-disk doc, replace only that stage entry, recompute sorted
aggregates and summary), so no existing code changes.

`ScanResults.json` shape: `version`, `generated_unix`, per-stage
`stages` (`errors` / `warnings` / `files` each), flat sorted
`errors` / `warnings` (every issue tagged with its `stage`, ordered
by path, line, column, severity), a `summary` (sorted stage
names, total files/errors/warnings) and the dock `filters` toggle
state (`show` / `types`, written by `store_filters()` without
touching any stage). `census` holds the project file count by file
name extension: the merged view plus the `project`
(res://addons/ excluded) and `addons` partitions, so the dock
addons toggle switches views without rescanning; each group carries
`extensions` / `total` plus `bytes` (byte sum), `size` (human
1024-based string), `newest` / `oldest` (unix mtimes); dots in
directory names never count, so extensionless names group under
`(no ext)`; the walk skips `.godot/` and `.git/`).

```gdscript
var res: Dictionary = GnumarusGodotProjectAnalyzerSuiteFullScanImpl.new().run()
```

## 11. GnumarusGodotProjectAnalyzerSuiteDock

Bottom-panel dock (next to Output, Debugger, …) with two tabs
sharing one toolbar. The Issues tab lists every known issue: live
per-file results from each analysis overlaid on the last
full-scan report (`ScanResults.json` is loaded when the dock builds,
so it starts populated). Two toggle groups filter the rows, like the
Output panel buttons: severities (Errors / Warnings / Notes —
nothing emits notes yet, the toggle is ready) and resource types
(`gd` / `tscn` / `tres` / `godot` / `other`, derived from the issue
path, so script issues and resource-integrity issues toggle
independently). A status label counts visible issues and how many
the filters hide; picking a row navigates to it (same-file `.gd`
reuses the status-bar path, other scripts open in the script editor,
scenes open on the main screen — script jumps also reveal the Script
workspace, since opening alone leaves 2D/3D/Game/AssetLib on
screen). Rescan re-runs the full scan and
reveals the dock; Clear drops the list. Toggle state persists in
both `EditorSettings` (`gnumarus_analyzer/dock_filters`, which wins
on load) and the `ScanResults.json` `filters` copy, so it survives
editor restarts with or without editor settings. The Files tab shows
the project file census from the report's `census` key grouped by
extension (`gd: 120 (90 project + 30 addons)`, count order), led by
per-group summary rows (`All files: 147 files, 45.2 MB
(2024-03-01 → 2026-09-22)`), with an
`addons` toggle that includes or drops `res://addons/` (and nested
dirs) from the count — persisted like the other toggles, no rescan
needed.

```gdscript
dock.set_file_results("res://x.gd", issues) # live overlay, one file
dock.set_scan_results(FullScan.load_results()) # whole-project report
```

## Annotations

Available annotations at a glance (details in each subsection below):

- `@generic` — declares a class generic over file templates.
- `@template` — declares a file-local generic type variable.
- `@interface` … `@endinterface` — declares an interface blueprint.
- `@implements` — claims conformance to interfaces or classes.
- `@struct` — defines a fixed-shape struct type refining `Dictionary`.
- `@tuple` — defines a fixed-shape tuple type refining `Array`.
- `@private` — restricts a member to its nested family; outside uses error.
- `@deprecated` — marks a script or member as deprecated; uses warn.
- `@alias` … `@endalias` — names a reusable type expression.
- `@return` — declares a function or lambda return type.
- `@param` — declares a parameter type.
- `@var` — declares or redefines a variable type, narrowing included.

Nullability configuration tags (`# @nullable_policy`,
`# @strict_untyped`) are documented under Nullability, not here.

Type annotations live in comments and follow the general shape:

```gdscript
# @annotationname param1 param2 ... lastparam
```

Only same-line text is read for now; multi-line struct/tuple
definitions with dictionaries and arrays are future work. A comment
counts as an annotation only under the post-tokenizer rule
(`@` glued to `#` or after whitespace, followed by a letter). To
mention an annotation without using it (docs, section headers),
escape it with a backslash: `\@param` is a mention and never
analyzes — the same backslash-means-meta convention as the integrity
scanner. An escaped mention beside a real tag still lets the real
one through.
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
- Cross-script uses warn through the target script's `user/*.json`
  flags: once a value is provably of another script class (an
  `is`-narrowed or explicitly typed variable, or a static
  `ClassName.member` access), using its deprecated members warns.
  Unknown receivers stay silent, as do public or undeclared members.
  Only directly-declared members are followed (script JSONs list no
  inherited members); `X.new()._m()` chains restart silent after
  `new`.
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
- Cross-script uses are checked through the target script's
  `user/*.json` flags: once a value is provably of another script
  class (an `is`-narrowed or explicitly typed variable, or a static
  `ClassName.member` access), calling/reading its private members
  errors — different files are never the same family. Unknown
  receivers stay silent (`var x: Variant` + `x._m()` only answers to
  the flow pass), as do public or undeclared members, so cross-file
  member checking otherwise behaves exactly as before. Only
  directly-declared members are followed (script JSONs list no
  inherited members); `X.new()._m()` chains restart silent after
  `new`.
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
  classes/enums, roster-known global classes, or a data-dir JSON
  file); unknown names error
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
  per-method `return_types` / `nullable_return` are written to the
  user JSON files for cross-script taint.

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
Every name must resolve (`null` is a valid arm: see Nullability);
applications of known `@tuple` types check
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
  must equal the declared type, inherit from it, or be a nominal
  tuple/struct refining its root (`@var x Pair` narrows `Array`,
  `@var p Point` narrows `Dictionary`) — anything else is
  `var_mismatch` (`Variant` accepts anything). Without an explicit
  vartype, `:=` infers from simple initializers (literals, arrays,
  dictionaries, known constructors, lambdas); plain `=` means
  Variant. Anything more complex skips the check.
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
# @var x Pair
var x: Array = [1, "a"]   # OK: length and elements conform
# @var y Pair
var y: Array = [1, 2, 3]  # ERROR: expects 2 elements, got 3
# @var z Pair
var z: Array = ["a", "b"] # ERROR: element 0 expects 'int', got 'String'
# @var w Pair
var w: Array = [3.14, "a"] # ERROR: element 0 expects 'int', got 'float'
# @tuple PairF 2 float float
# @var v PairF
var v: Array = [1, 2]     # OK: int widens into float
```

Literal elements check directionally: an `int` literal fits an
`int` or `float` slot (Godot itself accepts `var f: float = 1`),
but a `float` literal never fits an `int` slot (Godot silently
truncates `var i: int = 3.14` to `3` — exactly the data loss this
check exists to catch).

func f():
    print(x[0])             # OK: int
    print(x[5])             # ERROR: index out of bounds
    print(x[i])             # OK: dynamic index yields Variant
    print(x.size())         # OK: tuples verify methods through Array
    x.bogus()               # ERROR: Array has no such method
```

- Tuples are virtual types (like aliases): they refine `Array`,
  `Variant` or untyped declarations through `@var`/`@param`/
  `@return`, but `var x: Pair` is `virtual_vartype` (use the pattern
  above). A tuple narrows `Array` (and `Variant`/dynamic accept
  anything); an `Array` flows in only as a conforming literal
  (checked at `var`/`const` declarations, via the annotation too);
  different tuple names never mix (nominal typing).
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
# @alias whole int @endalias
# @alias pairs
# tuple[int, String]
# @endalias

# @var x whole
var x := 1                 # OK: exact match

# @var y number
var y := "a"               # ERROR: neither int nor float is String
```

- Aliases are global: one `kind: "alias"` JSON per name under
  `user/`, usable from any file once written (use before that errors
  `*_unknown_type` — unlike script classes, which the roster resolves
  without analysis). Definitions live
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
- The flow `env` also carries trees (`@tree:<name>` keys beside the
  flat heads, same last-write-wins discipline): `var y := id(1)`
  records the substituted return, so later uses of `y` check as
  `int`; reassignments (`y = id2(..)`) update it. Declarations own
  their type (vartype/`@var`/inference beat call results), guards
  erase trees when narrowing, dynamic results never widen.
- Gaps (documented): `@generic` classes come next; generic
  substitution results feed assignments through bare/`self` calls
  only (member-call results carry nullability taint instead — see
  Nullability — but not generic substitution).

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
  out). Single-level inheritance substitutes too: `class Kid
  extends GBox[int]` validates arity/bounds at declaration
  (`generic_mismatch`) and members inherited from `GBox` read with
  `TplT = int`; deeper chains, unparameterized children and
  cross-file generic classes stay lenient.
- Typed constructors infer generically: `gxfirst(Array[int]([1, 2]))`
  binds through `Array[TplT]` (engine heads only; script-class
  `Box[int](...)` and unknown heads read dynamic). `Box.new()`
  stays bare (opaque, as before).
- Definitions accept classes at root or nested (`generic_misplaced`
  elsewhere); bad shapes error (`generic_malformed`: empty,
  duplicates, non-template names).
- Gaps (documented): the script root itself cannot be generic (no
  `CLASS_DECL` to attach to); bare template names in vartypes/arrows
  (`var x: TplT`) error in the semantic pass (untouched) — use
  applications or annotations; `@return` marks methods normally, but
  template variables in it do not substitute — generic method returns
  flow only via `->` arrows.

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

# @interface IDamageable
# func:apply_damage:void:dmg:int|float
# @endinterface
# @var mynode Node|IDamageable
var mynode: Node = get_node('some_path')
mynode.apply_damage(1)   # OK: Node lacks it, IDamageable has it
mynode.bogus()           # ERROR: nobody has 'bogus()'
```

- Interfaces are virtual types (like tuples): `var v: Drawable` is
  `virtual_vartype` — declare a general `Object` class (`Object`,
  `Node`, ...) or `Variant`/untyped, and refine with `@var`. From
  the analyzer's view the value is a union of the interface and the
  real class used.
- Member chains check every union arm: interface methods (any
  staticness, lenient) and fields resolve, with call checking like
  real methods — arity with defaults/vararg plus per-argument types
  (`interface_mismatch`); returns continue the chain (`void`/
  dynamic skip the rest, like engine calls); absence everywhere
  errors `missing_method`/`missing_member`. Interface arms skip
  narrowing (contracts refine capabilities, never the nominal type).
- Definitions live top-level only; duplicates and clashes error
  (`interface_conflict`); bad shapes error (`interface_malformed`,
  `interface_unknown_type`). Written as `kind: "interface"` JSONs
  reusing class entry shapes (methods split static/instance, enum
  values and const values null). A `void` func return stays `"void"`
  (not `any`), so `@implements` can require it.
- Gaps (documented): signals/consts/enums don't resolve through
  unions yet; disk interfaces assume fixed arity (vararg lives only
  in same-file definitions).

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
# @var p Point
var p: Dictionary = {"x": 1, "y": 2}   # OK: exact keys, conforming values
# @var q Point
var q: Dictionary = {"x": 1}           # ERROR: missing field 'y'
# @var r Point
var r: Dictionary = {"x": 1, "y": 2, "z": 3}  # ERROR: expects 2 fields, got 3
# @var s Point
var s: Dictionary = {"x": 1, "y": 3.14} # ERROR: field 'y' expects 'int', got 'float'
```

Literal values check directionally like tuple elements: `int`
widens into `float` slots, `float` never fits `int`.

func f():
    print(p.x)                    # OK: int
    print(p.nope)                 # ERROR: has no member 'nope'
    print(p["x"])                 # OK: literal keys resolve
    print(p.keys())               # OK: Dictionary methods work
```

- Structs are virtual types (like aliases): they refine `Dictionary`,
  `Variant` or untyped declarations through `@var`/`@param`/
  `@return`, but `var p: Point` is `virtual_vartype` (use the pattern
  above). A struct narrows `Dictionary`; a `Dictionary` flows in
  only as a conforming literal (checked at `var`/`const`
  declarations, via the annotation too); different struct names
  never mix.
  Definitions live top-level only; duplicates and clashes error
  (`struct_conflict`); bad shapes error (`struct_malformed`,
  `struct_unknown_type`, `struct_mismatch`). Same documented gaps as
  tuples (call args, defaults, returns, `is`/`as`, no continuation).

### Nullability

`null` works as a union arm in any type expression
(`# @var x Node|null`,
`# @alias MaybeNode Node|null @endalias`): it means the Nil type.
Arm compatibility mirrors Godot assignability, verified against the
language itself: `null` fits Object-derived types, `Variant` and
untyped/dynamic slots, and nothing else (value types, arrays and
dictionaries reject null at parse time, so `@var x int|null` on an
inferred `int` mismatches on the `null` arm). `null` alone is valid
too (`# @var x null` on a `Variant` means exactly null). `null` is
lowercase-only and reserved: no tuple/struct/alias/interface/template
may be named `null` (`*_conflict`).

Flow narrowing understands null: `if x == null` (either order, with
optional leading `not`/`!`) narrows the branch to exactly null, and
`!=` narrows the other side the same way; `typeof(x) == TYPE_NIL`
(and `is_instance_of(x, TYPE_NIL)`) does the same. (`x is null` is
rejected: Godot rejects it at parse time.) Bare truthiness narrows
objects too (`if not x:` nulls that branch, `if x:` flags the other),
but only for provably-Object slots — bools, ints, `Variant`s and
unknowns never misread. `while` conditions narrow their bodies the
same way, and a sole `null` `match` pattern narrows its branch.
Guard clauses narrow what follows: when an `if` null-check's null
side ends in `return` (`if x == null: return`, `if x != null: ...
else: return`, `if not x: return` on Objects), the rest of the block
runs non-null. Every `elif` branch runs narrowed from the
accumulated previous-failed state (`elif x != null:` holds non-null
even when the `if` tested something else).
Anything provably null
errors `null_access` on member calls and reads (`cannot call method
'm()' on null`); bare uses like `print(x)` stay legal. Plain
nullable types stay lenient by design: `var x: Node = null` followed
by `x.foo()` is silent, as is any unguarded `Variant` use. Generic
null arguments compose naturally (`id(null)` against `of int`
mismatches).

Explicitly nullable values warn instead of staying silent: when a
union with a `null` arm (direct, or via an alias expanding to one)
resolves a member through another arm, `maybe_null` warns (`possible
null call 'm()' on 'x' (nullable 'Node|null')`) — still a warning,
never an error, and skipped under `notnull` marks and guards. Under
the default trust policy, plain
`Node` (implicitly nullable) stays silent: only written `|null`
opt-ins warn.

A trailing `notnull` marker on `@var`/`@param`/`@return`
(`# @var x Node notnull`) declares the slot never-null: it is stored
on the stamp, rejects nullable types (`Node|null`, bare `null` or an
alias expanding to one) as malformed, errors `= null` initializers
(including `self.x`), `null` defaults and `= null` reassignments
(`var_notnull`, `param_notnull`), and is set by the non-null side of
`==`/`!=` guards
(a plain redefinition without the marker clears it). Stamp and mark
differ on writes: a stamp is a contract and errors `= null` in every
policy, while a flow mark is context and errors only in distrust —
so `if impl != null: impl.close(); impl = null` (use-then-clear
teardown) stays silent in trust. A flow refinement in scope
(narrowed heads) suspends the stamp the same way a plain
redefinition does. Call sites are
checked too: passing a `null` literal to a notnull parameter errors
(`param_notnull`) for bare, `self.`, same-file instance/static,
`super` and lambda-held calls, one error per offending argument at
its own line; maybe-null
arguments stay silent in trust but warn in distrust (refusal
direction below), template-typed parameters belong to generic
machinery (no doubles), and cross-script calls resolve through the
callee's `user/*.json` signature (`param_names`/`notnull_params`/
`nullable_params`/`return_types`/`nullable_return` maintained per
method). `@return notnull` errors
`return null`
(`return_notnull`, lambdas and redundant parentheses included); call
results are trusted
downstream — passing them to notnull parameters or using them needs
no guard.

A trailing `nullable` marker on `@var`/`@param`/`@return`
(`# @var x Node nullable`) declares the slot maybe-null and watches
it: unguarded member use warns `maybe_null` in both policies
(`possible null call 'm()' on 'x' (nullable 'Node')`). The marker is
always optional and never combines with `notnull` (malformed), nor
with `void`, nor with a type that can never hold null (`int
nullable` is malformed); a `|null` arm or a nullable alias alongside
it is simply redundant, never an error (alias content is invisible).
`nullable` slots accept `= null` initializers, `null` defaults and
`return null` without complaint — that is what they declare.

The analyzer `null_policy` property (`"trust"` default, `"distrust"`
opt-in) decides the default for implicitly-nullable slots
(Object-derived types; aliases expand): trust stays silent (current
behavior, bit-for-bit), distrust warns on unguarded member use
(`... (implicitly nullable 'Node')`), still a warning, never an
error. Explicit markers always win over the policy; guards (in-block
and guard-clause) silence both. Untyped/dynamic slots stay out of
plain distrust — unless the analyzer `strict_untyped` flag (own
property, default off, inert under trust) opts in: then member use
on declared-but-untyped slots (plain-`=` locals, untyped params,
typeless members, `for` targets and `var` match bindings) warns
`maybe_null` too (`possible null call
'foo()' on 'p' (untyped 'p')`), as do subscripts on those slots
(`possible null read '[]' on 'p' (untyped 'p')`). Totally unknown
names stay silent
(they are not slots), bare uses stay legal, and guards/`notnull`
marks still win; explicit `: Variant` member use keeps erroring
`missing_method` by pre-existing design. Precedence mirrors the
policy, first hit wins: file `# @strict_untyped` tag (`on`, bare,
or `off`; misplaced and bad values error like the policy tag) >
explicit property > `gnumarus_analyzer/strict_untyped`
ProjectSetting (registered by the plugin, default false) > off.
The property is per-instance configuration: an
explicit assignment (even back to `"trust"`) beats the
`gnumarus_analyzer/nullable_policy` ProjectSetting (registered by
the editor plugin on enable, `"trust"` default, invalid values read
as trust); the setting applies on the next analysis pass.

A file opts out (or in) with a `# @nullable_policy trust|distrust`
tag that must be the file's first comment block, before any
declaration — anywhere else (member level, function bodies, inner
classes) errors `policy_misplaced`, and any other value errors
`policy_malformed`. Precedence, first hit wins: slot marker > file
tag > explicit property > ProjectSetting > `trust`. This is the
migration path: enable distrust globally, tag legacy files `trust`
until they are converted. Each `user/*.json` records its file's
effective policy (`"null_policy"`) for cross-script checks.

`@return T nullable` taints call results: assigning one watches the
target downstream, and undeclared targets resolve with the declared
return heads. Every callee shape resolves: bare and `self.` calls
(zero-arg included), lambda-held callees (both `cb()` and the
Godot-valid `cb.call()`, via the lambda's own `@return`), same-file
member calls (instance receivers — params, locals, members,
`is`-narrowed values with ANY-arm-maybeness — static class refs and
`super`), and cross-file static AND instance calls through the
callee's `user/*.json` signature (`return_types`/`nullable_return`
maintained per method, stale files without the keys read as
non-nullable). Explicit-null returns (`Node|null`) resolve the same
way through their null arm. `"nullable_params"` in `user/*.json` is
consent data for boundary checks: a distrust caller passing a
declared-maybe argument (null literal, `nullable` stamp/taint, an
explicit null arm, or a call to a nullable-returning function in any
of the shapes above — never a merely policy-watched one) to an
IMPLICIT parameter of a trust callee warns at the argument
(`possible null argument 'x' for parameter 'a' of 'plain()'
(implicitly nullable)`). Silent when the caller is lenient, when the
callee file is distrust (it warns at its own use sites — no
doubles), when the parameter consents (`nullable`) or refuses
(`notnull`, whose literal rule owns that direction), for stale JSONs
without the keys (missing files are analyzed on demand first — see
below), and for same-file calls (one file, one policy).
The refusal direction is covered everywhere the literal rule is:
same-file, `self.`, `super` and lambda-held `notnull` parameters
warn on declared-maybe arguments in distrust
(`possible null argument 'x' for notnull parameter 'c' of 'need()'`),
literals included in the message but owned by the error; cross-script
`notnull` warns the same way through the callee's JSON signature.
Under strict-untyped, declared-but-untyped arguments join both
directions (`... (untyped)`), still never under a `notnull` mark or
guard. Trust keeps the historical silence in all these positions
(literals still error in both).

Reassignments invalidate flow memory (all policies — this is runtime
truth, not suspicion): `x = null` sets exact-null heads, so a later
`x.foo()` errors `null_access` even for nullable slots (a `notnull`
target errors at the write first, then the use reports the resulting
null too); provably-non-null writes (value/array/dict literals,
`self`, `X.new()`, calls to `notnull`-returning functions) revert to
the declaration and, in distrust only, mark non-null (trust keeps
incidental state silent — only explicit user checks, i.e. guard
marks, establish intent there); any other write fully resets
heads, taint and guard marks (stale marks must not survive).
Declaration initializers stay lenient: `= null` and unknown inits
never invalidate (the null-init placeholder idiom is invisible to
intra-procedural flow), only provably-non-null inits mark (in
distrust).
`self.x` writes are out — env cannot represent members. `for`
targets bind like assignments on a body-local copy (iterable taint
and invalidation apply, e.g. `for x in make_nullable()` watches
`x`); `var` match bindings read as untyped slots (strict warns,
other modes stay silent).

Type tests prove non-null: `if v is Node:` runs the holding branch
on a non-null value (proven against the engine: `null is Node` is
false), so the branch gains the notnull mark — `while v is Node:`
and `if v is not Node: return` guard clauses work the same way.
`is_instance_of` and non-nil `typeof` tests count; `x is Variant`
proves nothing (`null is Variant` is true) and NIL forms belong to
the null rules above.

Cross-script references resolve without opening files. A process-wide
class roster maps every global `class_name` to its source: the
engine's `global_script_class_cache.cfg` when present (mtime-checked
per analysis), else a recursive line scan (works on
unparseable files too; skips `.godot/`; collisions keep the
sorted-first path; at most one rescan per analysis, on lookup miss).
The scan also records dotted inner classes (`Outer.Inner`, inners
of `class_name`-less files are unreachable globally) with their
`extends` heads, which warm ordering consumes. Roster-known but
never-analyzed classes are opaque: annotations
accept the name, narrowing stays lenient (unknown hierarchy proves
neither compat nor contradiction), and member positions stay silent
— while names absent from the roster still error (typo detection is
now sound: unknown means typo, not unseen). Member data arrives via
bounded on-demand analysis: the first cross check against a class
without JSON analyzes its file in a fresh instance under its own
effective policy (file tag, else ProjectSetting — never the
caller's override, so a distrust caller cannot stamp a trust file's
JSON as distrust; its JSON lands on
disk as a side effect), guarded by a shared resolve stack (cycles
read as missing — partial first pass, converges on re-analysis) and
a depth cap of 4. No user action needed: open one file and its
transitive references sharpen automatically.

Gaps (documented): guard clauses need a trailing `return`
(`break`/`continue`
and nested returns stay out, and the proven side returning keeps the
warning); with `elif` branches, every branch running in a
possibly-null primary-false state must also return; subscripts on
exact null skip (strict still warns on untyped slots, never on
proven null);
`const X = null` and
`var x := null`
are Godot parse errors, so inference never sees them; cross-file
inheritance limits: dotted names work in vartypes, annotations
(`@var`/`@param`/`@return`, including bracket generics and
tuple/struct arms) and in `is` / `is_instance_of` guards; quoted
`extends "res://..."` heads resolve in member walks too (absolute
directly, relative joined to the current file dir; the roster scan
sees quoted bases the parser drops); implicit-argument
boundary checks cover
static class calls, narrowed receivers and cross-file `super`
(same-file super resolves through member nodes instead);
explicit `: Variant` member use errors
`missing_method` by pre-existing engine-link design (both policies
alike); direct call chains (`make().foo()`), member taint targets
(`self.x = make()`) and engine/dynamic receivers stay silent for
return-taint purposes; unsaved buffers are invisible to the roster (save
triggers rescan); scripts without `class_name` resolve by path
only, never by name.

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
  `analysis_warnings`, maintains per-method `"param_names"` /
  `"notnull_params"` / `"nullable_params"` / `"return_types"` /
  `"nullable_return"` signatures, the file-level `"null_policy"` and
  the `"extends"` head for cross-script call-site checks,
  and merges newly declared members into the
  roster (existing entries keep their data; nothing is ever removed,
  so a partially parsed re-analysis cannot wipe it).
- `ScanResults.json` is written by the full scan (section 10): the
  merged report over every analysis stage (per-stage issues plus
  sorted flat aggregates and summary).

## tests

`./addons/0GnumarusGodotProjectAnalyzerSuite/tests/test.sh` (from the
project root) runs every
`addons/0GnumarusGodotProjectAnalyzerSuite/tests/test_*.gd` suite
headlessly inside this project's own directory
— no scratch copies needed. It exits 0 only when Godot exits 0 AND
the `ALL TESTS PASSED` marker is printed AND no `SCRIPT ERROR`
appears (a mid-suite crash aborts only that function while later
suites still print, so the marker alone could look green).
`GODOT_BIN` overrides the engine path.

- `addons/0GnumarusGodotProjectAnalyzerSuite/tests/run_all.gd` loads
  each suite (they expose `run()`), prints a
  per-suite `PASS`/`FAIL` line plus the grand total. A suite that
  fails to load, lacks `run()`, or returns a malformed result
  (mid-run crash) counts as a failure.
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
  `test_virtual.gd` (virtual types: annotation-only tuples/structs/aliases),
  `test_struct.gd` (`@struct` rule),
  `test_interface.gd` (`@interface` rule),
  `test_implements.gd` (`@implements` rule),
  `test_flow.gd` (flow member checks + guards + block-scope
  shadowing),
  `test_reuse.gd` (same instance parsing twice must give independent
  results),
  `test_editor_bar.gd` (editor status-bar logic: formatting, counts,
  navigation, hotkey, null-safe resolvers, mock-tree placement and
  real highlight/caret on a `TextEdit`; warm collect/order/step,
  incremental re-warm on filesystem scans, deferred begin/pump loop
  and dep-change gating;
  origin marker paint; snapshot/restore of foreign highlights and
  exit-time clearing),
  `test_scene.gd` (scene/resource/config parsing: value nodes,
  sections, multiline values, comments, errors, reuse, plus the
  `Node3D.tscn`, `Environment.tres`, `ProceduralSkyMaterial.tres`,
  `Sky.tres` fixtures and `project.godot`),
  `test_uid_cache.gd` (UID cache reading: id/text conversion,
  synthetic binaries, truncation errors, reuse, plus the live
  `.godot/uid_cache.bin` cross-checked against the `.uid` sidecars
  and the scene fixtures),
  `test_resource_integrity.gd` (integrity checking: ext path/uid
  validation, sidecar agreement/stale-cache fallback, dangling/
  duplicate/unused ids, bare strings, header uids, project globals,
  gd preload/load/extends/icon literals plus every static string in
  any quoting and every comment (labels, in-token positions,
  punctuation/line-suffix stripping, dynamic/probe/meta skips,
  ignore directives), reuse, collect, unreadable files),
  `test_null.gd` (nullability: `null` union arms and compat, reserved
  `null` names, `==`/`!=` narrowing, exact-null access errors and
  generic bound violations on null arguments),
  `test_notnull.gd` (trailing `notnull`: parse, contradiction,
  `= null` violations, guard-set flags, redefinition clearing,
  stamp-vs-mark write split (distrust errors, trust companions),
  call-site checks, fine coverage and cross-script signatures),
  `test_nullable.gd` (trailing `nullable`: parse, `notnull` /
  never-nullable contradiction, trust opt-in warnings, `@return
  nullable` taint, distrust policy, guard clauses,
  `nullable_params` / `return_types` JSON, ProjectSetting,
  `# @nullable_policy` file tags with precedence, cross-script
  boundary consent, `is` type-test narrowing, the same-file/`super`/
  call-result frontier, member/lambda/cross-file taint shapes, `elif`
  narrowing, strict-untyped slots with setting/tag, reassignment
  invalidation, and loop/match bindings with strict subscripts),
  `test_roster.gd` (class roster: cold names accepted, typos still
  unknown, opaque narrowing lenient; on-demand literal errors, dep
  JSON completeness, warm-cold equivalence, transitive taint;
  mutual-cycle termination with sequential equivalence; depth-cap
  blocking and release; cross-file inheritance (`extends` in JSON,
  chain lookups, derived compat); dotted inner classes with prefix
  fallback; quoted `extends` walks; dotted annotations, `is` /
  `is_instance_of` narrowing, bracket generics and tuple/struct arms;
  cross-file `super` (literal, maybe, implicit, quoted); recorded
  cross references per analysis).
  `test_full_scan.gd` (aggregated full scan: `ScanResults.json`
  merge/sort/summary, corrupt-file fallback, hermetic gdscript +
  integrity stages, EditorScript dumb-proxy shape, Project > Tools
  wiring null-safety).
  `test_dock.gd` (bottom-panel dock: severity/type filter logic,
  row format and status text, per-file overlay plus scan-report
  replacement, toggle wiring, row navigation, rescan/clear, editor
  openers headless-safe, dock lifecycle null-safety, Issues/Files
  tabs with grouped census rows).
  `test_scan_worker.gd` (background scans: pool dispatch/done/
  cancel/wait mechanics, FullScan policy-snapshot and cancel plumbs,
  plugin dispatch null-safety headless).
- `tests/AnnotationsStressTest.gd` is a non-suite fixture: a
  single-file stress of every annotation, valid and invalid uses
  with documented verdicts. It parses in Godot, so its diagnostics
  come only from this analyzer.
- `tests/bench_analyze.gd` is a manual benchmark (not a suite):
  parse + analyze timings on the analyzer itself (~10k lines) and a
  small file, trust vs distrust+strict. Reference numbers
  (Godot 4.7.2, Linux, warm data dir): small file 1ms parse /
  ~17ms analyze both modes; big file ~2.4s parse / ~4.5s trust /
  ~5.0s distrust+strict analyze. Parse dominates proportionally;
  distrust+strict adds ~12% on the big file. Typical open files
  (hundreds of lines) analyze in milliseconds — debounce-safe;
  the warm pass absorbs the rest in budgeted ticks.
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
  re-run until green. `CLEAN_USER_JSON=1` wipes `user/*.json` first
  (they regenerate on demand); use it when debugging stale-cache
  behavior, never as default (a clean-every-run CI would stop
  catching staleness).
- Test artifacts (`.godot/`, `*.uid`) are gitignored.

## Editor addon (`addons/0GnumarusGodotProjectAnalyzerSuite/`)

An editor plugin ("Gnumarus Analyzer") that runs this repo's analyzer
on the script being edited and shows its errors/warnings in a status
bar placed immediately above the script status bar: `<` previous
message, `>` next message (both focus the error line), the current
message in a dropdown in red (amber for warnings, both move together:
buttons change the dropdown selection, picking an entry focuses it in
the editor and updates the position), and on the right a white `1/3`
position plus the console-style counters: the `StatusError` red-circle
icon with the error count in red, and the `StatusWarning` yellow-circle
icon with the warning count in amber (hidden when zero). Error lines get a
red background (amber for warnings): the red is Godot's own
`text_editor/theme/highlighting/mark_color` (amber is
`warning_color`), read live from `EditorSettings` on every analysis,
so the tone matches native Godot errors with or without Godot errors
present (headless fallback is the built-in constant, then the legacy
first-painted-line scan).

- Install: open the project in Godot 4.7.2+, enable the plugin in
  Project → Plugins. No tracked source files are touched by the
  plugin (analysis artifacts land gitignored under `.godot/`).
  Nullability defaults live in Project → Project Settings (see
  Nullability): `gnumarus_analyzer/nullable_policy`
  (`trust`/`distrust`) and `gnumarus_analyzer/strict_untyped`.
- Use: open any GDScript and issues show right away; after that
  analysis is realtime with debounce (1s after the last edit, or past
  Godot's `idle_parse_delay` when larger). Opening/switching files
  also schedules one forced deferred pass: Godot's own validator
  runs after our immediate paint and resets every line background,
  so without it highlights would vanish until the next manual run.
  On enable, a background warm pass analyzes stale project files in
  one WorkerThreadPool task (leaves first via the roster extends
  map, so parents land before children cascade, so cross-file data
  is ready before it is needed): no frame slicing, no main-thread
  work at all — the editor stays fully usable, progress still prints
  per file (`warming [i/n] path`), and completion is polled from the
  plugin's `_process` (enabled only while a scan owns the process).
  The pool is exclusive-mode: while a scan runs, realtime analysis
  skips (a manual hotkey prints a note instead of silently idling;
  file switches clear a stale bar), because Analyzer statics
  (roster, resolve stack) and user JSON writes belong to the worker
  alone. Teardown cancels between files and joins the task; a scan
  requested mid-scan queues behind it (warm restarts, manual full
  scans preempt it). Web builds keep the legacy budgeted frame pump
  (pool tasks run inline there). Enabling never blocks the editor.
  Editor filesystem rescans re-warm incrementally (a restart when idle, one flagged
  extra pass otherwise; mtime skips keep both cheap). Repeat triggers
  on an unchanged buffer re-analyze only when a referenced script
  JSON changed (new/missing data converges without edits); those
  runs mark the position readout with ` (deps)`.
  **Ctrl+Shift+Alt+F5**
  forces an immediate run that also logs to the console; automatic
  runs update only the bar and highlights. Issues are shown in file
  order (`analyze()` returns errors and warnings sorted by
  line/column, so `<`/`>` always walk the file top to bottom with
  wraparound). Same-text repeats are skipped via path + text hash.
- Robustness first: every editor node (script editor, text editor,
  CodeEdit, Godot's own status bar) is re-resolved from scratch on
  every use — nothing is cached across context switches, and the bar
  rebuilds itself if the UI went away. The watched `text_changed`
  connection is dropped before every rewatch, so destroyed CodeEdits
  never leak. Placement is verified and
  repaired on every call (early-init fallback docking never sticks),
  so a missing bar fixes itself on the next run. When
  Godot's status bar can't be located, the bar docks at the editor
  bottom with a one-time console warning. All CodeEdit calls are
  `has_method`-guarded.
- Headless coverage: `test_editor_bar.gd` checks message formatting,
  counts, dropdown behavior, wraparound navigation, the hotkey
  predicate, debounce interval/countdown and null-safety
  of every resolver, plus bar placement, real highlight paint/clear
  and caret movement on mock trees and a real `TextEdit`, and the
  plugin-impl lifecycle on headless instances.
- Structure: `GnumarusGodotProjectAnalyzerSuitePlugin.gd` is a dumb
  `EditorPlugin` proxy (forwards `_enter_tree`/`_exit_tree`/`_input`/`_process`
  only); every behavior lives in
  `GnumarusGodotProjectAnalyzerSuitePluginImpl.gd` (`RefCounted`,
  holding the host reference for Node services), precisely so the
  logic instantiates headless in unit tests.
  `GnumarusGodotProjectAnalyzerSuiteScanWorker.gd` owns the pool
  mechanics only (dispatch/done/cancel/wait + one mutex); scan bodies
  stay in the impl/FullScan cores, which tests and the CLI keep using
  synchronously.
- Limitations: GDScript editors only; unsaved (`untitled`) scripts
  analyze under a fallback path; each run writes the usual
  `user/*.json` analysis files like any other analyze() call.
  Disabling the plugin clears only its own line highlights: every
  painted line restores the background it had before our paint, so
  Godot's native error highlights underneath survive the teardown
  (a native repaint landing between our paint and the disable is
  indistinguishable from ours by color and restores blank instead
  — transient until Godot revalidates).

## Documentation maintenance

This README is part of the deliverable: implementing a new annotation
or changing an existing rule must update the corresponding section
here (placement, semantics, messages, error kinds, examples) in the
same change.