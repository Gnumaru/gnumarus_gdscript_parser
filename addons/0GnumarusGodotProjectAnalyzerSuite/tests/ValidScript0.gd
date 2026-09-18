## ValidScript0123456789654987321.gd - syntactically valid GDScript file for Godot 4.7.2.
## Showcases as many syntax features of the language as possible.
## Test class for the gnumarus_gdscript_parser.
# Plain single-line comment.
# TODO: task marker.
# FIXME: fix marker.
@tool
@static_unload
@icon("res://icon.svg")
class_name ValidScript0123456789654987321
extends Node


## Plain signal without arguments.
signal simple_signal
## Signal with untyped arguments.
signal untyped_signal(a, b)
## Signal with typed arguments.
signal typed_signal(points: int, label: String)
signal moved(position: Vector2, speed: float)
signal health_depleted
signal state_changed(old_state: int, new_state: int)


## Anonymous enum with automatic values.
enum { ANON_A, ANON_B, ANON_C, }
## Anonymous enum with explicit values.
enum { WITH_A = 10, WITH_B = 20, WITH_AUTO, }
## Simple named enum.
enum State { IDLE, RUN, JUMP = 10, FALL, }
## Named enum of directions.
enum Direction { UP = 1, DOWN = 2, LEFT = 4, RIGHT = 8, }
enum Kind { SWORD, BOW = 5, STAFF, }


const SIMPLE_INT = 42
const SIMPLE_FLOAT := 3.14
const SIMPLE_STR := "hello"
const TYPED_INT: int = 10
const TYPED_STR: String = "typed"
const EXPR := 1 + 2 * 3 - 4
const CONCAT := "foo" + "bar"
const BOOL_EXPR := true and not false
const TERNARY_CONST := 1 if true else 2
const ARR_CONST := [1, 2, 3]
const DICT_CONST := {"a": 1, "b": 2}
const VEC_CONST := Vector2(1.0, 2.0)
const COLOR_CONST: Color = Color(1.0, 0.0, 0.0, 1.0)
const SN_CONST := &"my_string_name"
const NP_CONST := ^"Some/Path"
const ENUM_CONST := State.IDLE
const NEG_CONST := -7
const FLOAT_EXP := 1.5e-3
## Self preload (valid path inside the project).
const SELF_SCRIPT := preload("res://addons/0GnumarusGodotProjectAnalyzerSuite/tests/ValidScript0.gd")



class Item:
	var id: int = 0
	var label: String = ""
	func _init(p_id: int = 0, p_label: String = "") -> void:
		id = p_id
		label = p_label
	func _to_string() -> String:
		return "Item(id=%d, label=%s)" % [id, label]


class Base:
	func greet() -> String:
		return "base"


class Child extends Base:
	func greet() -> String:
		return super.greet() + "!"


class Counter:
	extends RefCounted
	var value: int = 0
	func _init(v: int = 0) -> void:
		value = v
	func increment(step: int = 1) -> int:
		value += step
		return value


@abstract
class AbstractBase extends RefCounted:
	@abstract
	func do_work(value: int) -> void


class WithSignal:
	signal changed(old_value: int, new_value: int)
	enum Mode { OFF, ON }
	const DEFAULT_MODE := Mode.OFF
	var mode: Mode = Mode.OFF
	func set_mode(v: Mode) -> void:
		var old: Mode = mode
		mode = v
		changed.emit(old, mode)


class Outer:
	class Nested:
		var x := 1
		func get_x() -> int:
			return x


@warning_ignore_start("unused_variable")
static var global_counter := 0
static var named_count: int = 0
static var shared_list: Array[int] = []
@warning_ignore_restore("unused_variable")


@export_category("ValidScript0123456789654987321 Main")
@export_group("Numbers and Text")
@export var exp_int: int = 42
@export var exp_float: float = 3.14
@export var exp_string: String = "exported"
@export var exp_bool: bool = true
@export_range(0, 100, 1, "or_greater", "hide_slider", "suffix:ms") var exp_ranged: float = 50.0
@export_enum("Idle", "Run", "Jump") var exp_mode_str: String = "Idle"
@export_enum("A", "B", "C") var exp_choice: int = 0
@export_group("Files and Text Areas")
@export_file("*.txt", "*.cfg") var exp_file: String = ""
@export_dir var exp_dir: String = ""
@export_multiline var exp_lore: String = "once upon a time..."
@export_placeholder("nickname") var exp_nick: String = ""
@export_custom(PROPERTY_HINT_RANGE, "0,100,1") var exp_custom: float = 1.0
@export_node_path("Node", "Node2D") var exp_node_path_custom: NodePath = ^"A/B"
@export_subgroup("References and Collections")
@export var exp_node: Node = null
@export var exp_vec: Vector2 = Vector2.ZERO
@export var exp_color: Color = Color.RED
@export var exp_arr: Array[int] = [1, 2, 3, ]
@export var exp_str_arr: Array[String] = ["a", "b", ]
@export var exp_dict: Dictionary = {"k": 1, }
@export var exp_sn: StringName = &"example"
@export var exp_np: NodePath = ^"Some/Path"
@export_tool_button("Press me", "Callable") var tool_btn: Callable = func(): print("tool pressed")
@export_storage var stored_value: int = 7
@export_color_no_alpha var dye_color: Color = Color.BLUE
@export_color_no_alpha var dye_palette: Array[Color] = [Color.RED, ]
@export_exp_easing var transition_speed: float = 1.0
@export_exp_easing("attenuation") var fading_attenuation: float = 0.5
@export_file_path("*.txt") var raw_file_path: String = ""
@export_flags("Fire", "Water", "Earth", "Wind") var spell_elements: int = 0
@export_flags("Self:4", "Allies:8", "Foes:16") var spell_targets: int = 4
@export_flags_2d_navigation var nav_layers_2d: int = 1
@export_flags_2d_physics var physics_layers_2d: int = 1
@export_flags_2d_render var render_layers_2d: int = 1
@export_flags_3d_navigation var nav_layers_3d: int = 1
@export_flags_3d_physics var physics_layers_3d: int = 1
@export_flags_3d_render var render_layers_3d: int = 1
@export_flags_avoidance var avoidance_layers: int = 1
@export_global_dir var abs_dir: String = ""
@export_global_file("*.txt") var abs_file: String = ""
@export var dir_array: Array[Direction] = [Direction.UP, ]


var untyped_var = 123
var typed_int: int = -42
var typed_float: float = -0.5
var typed_string: String = "double quoted"
var single_quoted: String = 'single quoted'
var inferred_int := 7
var inferred_string := "inferred"
var inferred_vec := Vector2(1.0, 2.0)
var variant_value: Variant = 123
var any_array: Array = [1, "two", null, true, ]
var typed_int_array: Array[int] = [3, 1, 2, ]
var typed_node_array: Array[Node] = []
var nested_array: Array[Array] = [[1, 2], [3, 4], ]
var generic_dict: Dictionary = {"name": "hero", "level": 5, "tags": ["a", "b"], }
var int_key_dict: Dictionary = {1: "one", 2: "two", }
var empty_array := []
var empty_dict := {}
var nullable_node: Node = null
var string_name_val: StringName = &"hello_sn"
var node_path_val: NodePath = ^"A/B"
var callable_val: Callable = Callable()
var signal_val: Signal = simple_signal
var rid_val: RID = RID()
var obj_val: Object = null
var packed_v4: PackedVector4Array = PackedVector4Array([Vector4.ZERO, ])
var state_array: Array[State] = [State.IDLE, State.RUN, ]
var state_val: State = State.RUN
var dir_val: Direction = Direction.UP
var big_number := 1_000_000
var hex_number := 0xFF
var hex_underscore := 0xFF_FF
var bin_number := 0b1010
var oct_number := 0777
var float_exp := 1e10
var float_exp_neg := 1.5e-3
var float_underscore := 1_000.5
var inf_val: float = INF
var nan_val: float = NAN
var pi_val: float = PI
var tau_val: float = TAU
var triple_double := """first line
second line
third line"""
var triple_single := '''line one
line two'''
var escaped := "tab:\t break:\n slash:\\ quotes:\" unicode:\u0041"
var raw_path := r"C:\Godot\project\new"
var raw_single := r'no_escape_\n_here'
var raw_triple := r"""line1\nline2"""
var raw_triple_single := r'''other\nraw'''
var max_health: int = 100
var health: int = 100:
	set(v):
		health = clampi(v, 0, max_health)
	get:
		return health
var speed: float = 1.0:
	set = set_speed, get = get_speed
var stamina: float = 10.0:
	set(v):
		stamina = clampf(v, 0.0, 20.0)
	get:
		return stamina
var display_name: String = "hero":
	set(v):
		display_name = v.strip_edges()
	get:
		return display_name


func set_speed(v: float) -> void:
	speed = clampf(v, 0.0, 99.0)


func get_speed() -> float:
	return speed


@onready var child_node: Node = $Child
@onready var path_node: Node = $"Parent/Child"
@onready var unique_node: Node = %MyUnique
@onready var fetched_node: Node = get_node_or_null("Some/Path")
@onready var inferred_child = $Child


static func add_static(a: int, b: int = 5) -> int:
	return a + b


static func describe_static(kind: Kind = Kind.SWORD) -> String:
	return "kind=%d" % kind


func _init() -> void:
	pass


func _enter_tree() -> void:
	pass


func _ready() -> void:
	simple_signal.connect(_on_simple_signal)
	typed_signal.connect(_on_typed_signal)
	health_depleted.connect(_on_simple_signal, CONNECT_ONE_SHOT)
	simple_signal.emit()
	typed_signal.emit(10, "ready")
	demo_all()


func _exit_tree() -> void:
	if simple_signal.is_connected(_on_simple_signal):
		simple_signal.disconnect(_on_simple_signal)


func _process(delta: float) -> void:
	var _unused_delta := delta
	pass


func _physics_process(delta: float) -> void:
	if delta < 0.0:
		return


func _notification(what: int) -> void:
	if what == NOTIFICATION_READY:
		pass


func _to_string() -> String:
	return "ValidScript0123456789654987321"


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_accept"):
		pass


@warning_ignore("unused_parameter")
func _on_simple_signal() -> void:
	pass


func _on_typed_signal(points: int, label: String) -> void:
	prints("typed", points, label)


@rpc("any_peer", "call_local", "reliable")
func net_ping(peer_id: int) -> void:
	print("ping from %d" % peer_id)


@rpc("authority", "call_remote", "unreliable")
func net_spawn(pos: Vector2, label: String = "enemy") -> void:
	prints("spawn", pos, label)


func one_liner() -> int: return 42


func add(a: int, b: int = 5) -> int:
	return a + b


func make_item(
		p_id: int,
		p_label: String = "default",
		p_tags: Array = [],
		p_meta: Dictionary = {"k": 1}
	) -> Item:
		var item := Item.new(p_id, p_label)
		return item


func demo_coroutine() -> void:
	await get_tree().process_frame
	print("coroutine resumed")


func demo_all() -> void:
	# Partial demo calls.
	demo_operators()
	demo_literals()
	demo_collections()
	demo_flow()
	demo_strings()
	demo_builtin_types()
	demo_callables()
	demo_nodes()
	demo_misc()
	demo_engine_classes()
	demo_indentation()
	# Multiple statements on one line with semicolons.
	var a := 1; var b := 2; print(a + b)
	# Line continuation with a backslash.
	var total := 1 + \
		2 + \
		3
	print(total)
	# Continuation with parentheses.
	var total2 := (
		10
		+ 20
		+ 30
	)
	print(total2)
	# Inline single-line suite.
	if total > 0: print("positive")
	# Self, variant and casts.
	variant_value = "now I am a string"
	variant_value = 999
	var as_node := self as Node
	print(self.get_name())
	print(as_node)
	# Awaiting a coroutine, a signal and a timer.
	await demo_coroutine()
	await simple_signal
	await get_tree().create_timer(0.01).timeout
	await ready
	# Dynamic load (does not fail at compile time).
	var loaded := load("res://icon.svg")
	print(loaded)
	# Compile-time preload (points to itself).
	print(SELF_SCRIPT)
	# Multiline lambda.
	var mult = func(x: int, y: int) -> int:
		var s := x + y
		return s * 2
	print(mult.call(3, 4))
	# Assert with one- and two-argument forms and a conditional breakpoint.
	assert(health >= 0)
	assert(max_health > 0, "max_health must be positive")
	if OS.is_debug_build():
		print("debug build")
	if false:
		breakpoint
	# Singleton and global constant access.
	print(Engine.get_process_frames())
	print(Time.get_ticks_msec())
	print(OK)
	print(FAILED)


func demo_operators() -> void:
	var x := 10
	var y := 3.0
	var arith := 1 + 2 - 3 * 4 / 2
	@warning_ignore("integer_division")
	var int_div := 7 / 2
	var mod := 7 % 3
	var power := 2 ** 8
	var neg := -x
	var pos := +x
	var bit_and := 6 & 3
	var bit_or := 6 | 3
	var bit_xor := 6 ^ 3
	var shift_l := 1 << 4
	var shift_r := 256 >> 4
	var bit_not := ~6
	x += 5; x -= 2; x *= 2; x /= 2; x %= 4; x **= 2
	x <<= 1; x >>= 1; x &= 7; x |= 8; x ^= 3
	var cmp := (x == 10) and (x != 5) and (x > 1) and (x < 100) and (x >= 1) and (x <= 200)
	var logic := (true and false) or (not false)
	var logic_alias := (true && true) || (!false)
	var probe: Variant = self
	var is_not_node := probe is not Button
	var not_in_arr := 9 not in [1, 2, 3]
	var not_in_dict := "z" not in {"k": 1}
	var not_in_str := "xyz" not in "hello"
	var s := "ab"
	var in_arr := 1 in [1, 2, 3]
	var in_dict := "k" in {"k": 1}
	var in_str := "ell" in "hello"
	var is_node := self is Node
	var is_int := x is int
	var casted := self as Node
	var fmt1 := "hello %s" % "world"
	var fmt2 := "a=%s b=%d" % ["x", 7]
	var concat := "foo" + "bar"
	concat += "!"
	var tern := "yes" if cmp else "no"
	var nested_tern := "a" if x == 1 else "b" if x == 2 else "c"
	print(y, arith, int_div, mod, power, neg, pos)
	print(bit_and, bit_or, bit_xor, shift_l, shift_r, bit_not)
	print(logic, logic_alias, s, in_arr, in_dict, in_str, is_node, is_int, casted)
	print(is_not_node, not_in_arr, not_in_dict, not_in_str)
	print(fmt1, fmt2, concat, tern, nested_tern)


func demo_literals() -> void:
	var i1 := 42
	var i2 := -7
	var i3 := 1_000_000
	var i4 := 0xDEAD
	var i5 := 0b1101
	var i6 := 0755
	var f1 := 3.14
	var f2 := -0.25
	var f3 := 2e6
	var f4 := 1.5e-3
	var b1 := true
	var b2 := false
	var n = null
	var d1 := "double"
	var d2 := 'single'
	var d3 := """multi
line"""
	var d4 := '''other
multi'''
	var esc := "a\nb\tc\\d\"e\u0041"
	var sn := &"some_name"
	var np := ^"Path/To/Node"
	var dollar := $Child
	var dollar_str := $"A/B"
	var pct := %MyUnique
	var self_ref := self
	print(i1, i2, i3, i4, i5, i6, f1, f2, f3, f4, b1, b2, n)
	print(d1, d2, d3, d4, esc, sn, np, dollar, dollar_str, pct, self_ref)
	print(raw_path, raw_single, raw_triple, raw_triple_single)
	print(PI, TAU, INF, NAN)


func demo_collections() -> void:
	var empty_a := []
	var empty_d := {}
	var mixed := [1, "two", 2.5, true, null, &"sn", ^"np", Vector2.ZERO, ]
	var nested := [[1, 2], ["a", "b"], [{"k": 1}], ]
	var multiline := [
		1,
		2,
		3,
	]
	var typed: Array[int] = [3, 1, 2, ]
	var str_typed: Array[String] = ["b", "a", ]
	var node_typed: Array[Node] = []
	var dict := {
		"name": "hero",
		"hp": 100,
		"pos": Vector2(1, 2),
		"tags": ["fast", "strong"],
		"nested": {"x": 1},
	}
	var with_int_keys := {1: "one", 2: "two", }
	print(empty_a, empty_d, mixed, nested, multiline)
	print(typed, str_typed, node_typed, dict, with_int_keys)
	# Subscripts, negative index and methods.
	print(mixed[0])
	print(mixed[-1])
	print(dict["name"])
	print(dict.get("missing", "default"))
	mixed.push_back(99)
	mixed.append(100)
	print(mixed.pop_back())
	print(mixed.size())
	print(mixed.is_empty())
	print(mixed.has(1))
	mixed = [3, 1, 2]
	mixed.sort()
	print(mixed)
	mixed.reverse()
	print(mixed)
	print(mixed.slice(0, 2))
	print(dict.keys())
	print(dict.values())
	print(dict.has("hp"))
	print(dict.size())
	print(dict.is_empty())
	typed.sort_custom(func(a: int, b: int) -> bool: return a < b)
	print(typed)
	# Iteration over array, dictionary and string.
	for e in mixed:
		print(e)
	for k in dict:
		prints(k, dict[k])
	for k in dict.keys():
		print(k)
	for v in dict.values():
		print(v)
	for ch in "abc":
		print(ch)
	for i in range(3):
		print(i)
	for i in range(10, 0, -1):
		print(i)
	for i in 5:
		print(i)
	for c in get_children():
		print(c.name)


func demo_flow(x: int = 7, tag: String = "demo") -> String:
	# Chained if / elif / else.
	var result := ""
	if x == 0:
		result = "zero"
	elif x < 0 and tag != "":
		result = "negative"
	elif x > 0 or not tag.is_empty():
		result = "positive"
	else:
		result = "other"
	# Inline if.
	if x > 100: result = "huge"
	elif x < -100: result = "tiny"
	else: result = result
	# While with break and continue.
	var i := 0
	while i < 10:
		i += 1
		if i == 2:
			continue
		if i == 6:
			break
		print(i)
	# While true with break.
	while true:
		i -= 1
		if i <= 0:
			break
	# For with break, continue and a discarded variable.
	for n in [1, 2, 3, 4]:
		if n == 2:
			continue
		if n == 4:
			break
		print(n)
	for _idx in range(2):
		pass
	# Nested for and nested if with in / is.
	for a in [1, 2]:
		for b in [3, 4]:
			print(a + b)
	if x in [1, 2, 3, 7]:
		print("x is in the list")
		if tag in ["demo", "other"]:
			if x is int:
				print("x is int")
	var maybe_item: Variant = Item.new(1, "tmp")
	if maybe_item is Item:
		print("is Item")
	# Full match: int, multiple patterns, string, bool, null, float, enum, array, dict, bind, guard and wildcard.
	match x:
		0:
			result = "zero!"
		1, 2, 3:
			result = "low"
		10:
			result = "ten"
		_ when x < 0:
			result = "guarded negative"
		_:
			result = "fallback"
	match tag:
		"demo":
			print("tag demo")
		"other", "alt":
			print("tag other")
		_:
			pass
	match true:
		true, false:
			pass
	match null:
		null:
			pass
		_:
			pass
	match 3.14:
		3.14:
			pass
		_:
			pass
	match state_val:
		State.IDLE:
			print("idle")
		State.RUN:
			print("run")
		State.JUMP, State.FALL:
			print("air")
		_:
			pass
	match [1, 2]:
		[1, 2]:
			print("pair 1,2")
		[var a, var b] when a == b:
			prints("equal", a, b)
		_:
			pass
	match {"k": 1}:
		{"k": var v}:
			print(v)
		_:
			pass
	match x:
		var bound when bound > 100:
			print(bound)
		var other_bound:
			print(other_bound)
	# Early return and pass.
	if x == 999:
		return "early"
		pass
	return result if result != "" else "empty"


func demo_strings() -> void:
	var name := "Ada"
	var score := 99
	var s1 := "hello " + name
	var s2 := "score=%d name=%s" % [score, name]
	var s3 := "single: %s" % name
	var upper := s1.to_upper()
	var lower := s1.to_lower()
	var trimmed := "  pad  ".strip_edges()
	var sub := s1.substr(0, 5)
	var has := s1.contains("ell")
	var begins := s1.begins_with("hello")
	var ends := s1.ends_with(name)
	var replaced := s1.replace("hello", "hi")
	var parts := "a,b,c".split(",")
	var joined := ", ".join(PackedStringArray(["a", "b", "c"]))
	print(s1, s2, s3, upper, lower, trimmed, sub)
	print(has, begins, ends, replaced, parts, joined)
	print("len=%d" % s1.length())
	prints("prints", "splits", "with", "space")
	printt("printt", "with", "tabs")


func demo_builtin_types() -> void:
	var v2 := Vector2(1.0, 2.0)
	var v2i := Vector2i(1, 2)
	var v3 := Vector3(1.0, 2.0, 3.0)
	var v3i := Vector3i(1, 2, 3)
	var v4 := Vector4(1.0, 2.0, 3.0, 4.0)
	var v4i := Vector4i(1, 2, 3, 4)
	var col1 := Color(1.0, 0.0, 0.0, 1.0)
	var col2 := Color("red")
	var col3 := Color.html("#00ff00")
	var col4 := Color.GREEN
	var r2 := Rect2(0.0, 0.0, 10.0, 10.0)
	var r2i := Rect2i(0, 0, 10, 10)
	var box := AABB(Vector3.ZERO, Vector3.ONE)
	var plane := Plane(Vector3.UP, 1.0)
	var quat := Quaternion.IDENTITY
	var basis := Basis.IDENTITY
	var t2 := Transform2D.IDENTITY
	var t3 := Transform3D.IDENTITY
	var proj := Projection.IDENTITY
	var s := str(123)
	var si := StringName("my_name")
	var npath := NodePath("A/B")
	var pba := PackedByteArray([1, 2, 3])
	var pi32 := PackedInt32Array([1, 2])
	var pi64 := PackedInt64Array([1, 2])
	var pf32 := PackedFloat32Array([1.0, 2.0])
	var pf64 := PackedFloat64Array([1.0, 2.0])
	var ps := PackedStringArray(["x", "y"])
	var pv2 := PackedVector2Array([Vector2.ZERO, Vector2.ONE])
	var pv3 := PackedVector3Array([Vector3.ZERO])
	var pc := PackedColorArray([Color.RED, Color.BLUE])
	print(v2, v2i, v3, v3i, v4, v4i)
	print(col1, col2, col3, col4, r2, r2i)
	print(box, plane, quat, basis, t2, t3, proj)
	print(s, si, npath)
	print(pba, pi32, pi64, pf32, pf64, ps, pv2, pv3, pc)
	print(Vector2.ZERO, Vector2.ONE, Vector2.UP, Vector2.RIGHT)
	print(clampi(150, 0, 100), clampf(1.5, 0.0, 1.0), lerpf(0.0, 10.0, 0.5))
	print(min(1, 2), max(1, 2), abs(-5), floor(1.7), ceil(1.2), round(1.5))
	print(sqrt(4.0), pow(2.0, 3.0), sin(0.0), cos(0.0))
	print(int(1.9), float(2), bool(1), str(v2))
	# Vector operations and PackedArray methods.
	var v_sum := v2 + Vector2.ONE
	var v_scaled := v2 * 2.0
	print(v_sum, v_scaled, v2.length(), v2.normalized(), v2.dot(Vector2.UP))
	print(t3 * v3)
	print(pba.size(), ps.has("x"), pv2.is_empty())
	print("123".to_int(), "3.5".to_float())


func demo_callables() -> void:
	var single := func(n: int) -> int: return n * 2
	print(single.call(21))
	var adder = func(a: int, b: int) -> int:
		return a + b
	print(adder.call(2, 3))
	# Lambda capturing an outer variable.
	var base := 10
	var capturer = func(x: int) -> int: return x + base
	print(capturer.call(5))
	# Immediately invoked lambda.
	print((func() -> int: return 99).call())
	var c := Callable(self, "add")
	print(c.call(1, 2))
	print(c.callv([3, 4]))
	var bound := Callable(self, "add").bind(100)
	print(bound.call(1))
	print(c.is_valid())
	var arr := [5, 2, 8, 1]
	arr.sort_custom(func(a: int, b: int) -> bool: return a < b)
	print(arr)
	var filtered := [1, 2, 3, 4].filter(func(x: int) -> bool: return x > 2)
	print(filtered)
	var mapped := [1, 2, 3]
	print(mapped)
	var item := Item.new(1, "one")
	print(item)
	var counter := Counter.new(10)
	print(counter.increment(5))
	var kid := Child.new()
	print(kid.greet())
	var nested := Outer.Nested.new()
	print(nested.get_x())
	var with_sig := WithSignal.new()
	with_sig.changed.connect(_on_with_signal_changed)
	with_sig.set_mode(WithSignal.Mode.ON)
	print(with_sig.mode)


func _on_with_signal_changed(old_value: int, new_value: int) -> void:
	prints("with_signal", old_value, new_value)


func demo_nodes() -> void:
	var node_name := get_name()
	print(node_name)
	var parent := get_parent()
	print(parent)
	print(get_child_count())
	print(has_node("Some/Path"))
	print(get_node_or_null("Some/Path"))
	var direct := $Child if has_node("Child") else null
	print(direct)
	var uniq := %MyUnique if has_node("%MyUnique") else null
	print(uniq)
	var via_dollar := $"Parent/Child" if has_node("Parent/Child") else null
	print(via_dollar)
	print(is_instance_valid(self))
	print(is_instance_of(self, Node))
	var err := OK
	if err == OK:
		pass
	err = FAILED
	print(err)
	push_warning("sample warning")
	printerr("sample error")
	push_error("another error")
	# Node handling, Input and settings.
	var temp := Node.new()
	temp.name = "TempNode"
	add_child(temp)
	print(get_child(get_child_count() - 1).name)
	print(find_child("TempNode", false, false))
	print(temp.has_method("get_name"))
	temp.set_meta("k", 42)
	print(temp.get_meta("k"))
	print(Input.is_action_pressed("ui_accept"))
	print(ProjectSettings.get_setting("application/config/name"))
	temp.queue_free()


func demo_misc() -> void:
	# Conversions and type checks.
	var as_int := int(2.7)
	var as_float := float(3)
	var as_str := str(3.14)
	var as_bool := bool(1)
	print(as_int, as_float, as_str, as_bool)
	# Logical operations with parentheses and not.
	var flag := (true or false) and not false
	print(flag)
	# Chained and multiline call.
	var chained := "  HeLLo  ".strip_edges().to_lower().substr(0, 5)
	print(chained)
	print(
		"multiline",
		"call",
		123,
	)
	# Enum, const and static.
	print(State.IDLE, Direction.LEFT, Kind.BOW)
	print(SIMPLE_INT, TYPED_STR, ENUM_CONST)
	print(add_static(1, 2))
	print(describe_static(Kind.BOW))
	global_counter += 1
	print(global_counter)
	# Dictionary and array as default arguments already covered in make_item; exercised here.
	print(make_item(9))
	print(add(1))
	print(add(1, 2))
	print(is_ready_custom())
	print(sum_typed([1, 2, 3]))
	print(take_variant("text"))
	print(with_many_defaults())
	print(one_liner())
	# Combined is / as.
	var maybe: Variant = self
	if maybe is Node:
		var as_n := maybe as Node
		print(as_n.name)
	# JSON, FileAccess and extra filters.
	print(JSON.parse_string("{\"a\": 1}"))
	print("42".to_int(), "3.5".to_float())
	print(randf(), randi(), randf_range(0.0, 1.0))
	print(typeof(42), typeof("s"))
	print(is_equal_approx(1.0, 1.001))
	print(move_toward(0.0, 10.0, 2.5))
	print(var_to_str({"a": 1}))
	print(str_to_var("{\"a\": 1}"))
	print(len([1, 2, 3]), len("hello"), len({"a": 1}))
	print(Color8(255, 128, 0), char(65), ord("A"))
	print(convert(42, TYPE_FLOAT), type_exists("Node"), type_exists("ValidScript0123456789654987321"))
	print(ClassDB.class_exists("Node2D"))
	print(ResourceLoader.exists("res://icon.svg"))
	print(InputMap.has_action("ui_accept"))
	print(AudioServer.get_bus_count())
	print(Performance.get_monitor(Performance.TIME_FPS))
	print(FileAccess.file_exists("user://save.dat"))
	print(DirAccess.dir_exists_absolute("user://"))
	var nums := [3, 1, 2]
	print(nums)
	var d2 := {"x": 1, "y": 2}
	d2.erase("x")
	print(d2)


func demo_engine_classes() -> void:
	## Representative sample of the 1054 engine classes (names verified against API 4.7.2).
	## Full coverage is unfeasible in a single file; complete variant types are in demo_builtin_types().
	var node_ref: Node = null
	var node_2d_ref: Node2D = null
	var node_3d_ref: Node3D = null
	var control_ref: Control = null
	var window_ref: Window = null
	var canvas_layer_ref: CanvasLayer = null
	var canvas_item_ref: CanvasItem = null
	var button_ref: Button = null
	var label_ref: Label = null
	var label_3d_ref: Label3D = null
	var line_edit_ref: LineEdit = null
	var text_edit_ref: TextEdit = null
	var code_edit_ref: CodeEdit = null
	var rich_text_label_ref: RichTextLabel = null
	var panel_ref: Panel = null
	var panel_container_ref: PanelContainer = null
	var v_box_container_ref: VBoxContainer = null
	var h_box_container_ref: HBoxContainer = null
	var grid_container_ref: GridContainer = null
	var scroll_container_ref: ScrollContainer = null
	var tab_container_ref: TabContainer = null
	var tree_ref: Tree = null
	var item_list_ref: ItemList = null
	var option_button_ref: OptionButton = null
	var check_box_ref: CheckBox = null
	var check_button_ref: CheckButton = null
	var h_slider_ref: HSlider = null
	var v_slider_ref: VSlider = null
	var progress_bar_ref: ProgressBar = null
	var spin_box_ref: SpinBox = null
	var texture_rect_ref: TextureRect = null
	var texture_button_ref: TextureButton = null
	var color_picker_ref: ColorPicker = null
	var color_rect_ref: ColorRect = null
	var menu_button_ref: MenuButton = null
	var popup_menu_ref: PopupMenu = null
	var tab_bar_ref: TabBar = null
	var link_button_ref: LinkButton = null
	var separator_ref: Separator = null
	var h_separator_ref: HSeparator = null
	var v_separator_ref: VSeparator = null
	var scroll_bar_ref: ScrollBar = null
	var h_scroll_bar_ref: HScrollBar = null
	var v_scroll_bar_ref: VScrollBar = null
	var split_container_ref: SplitContainer = null
	var h_split_container_ref: HSplitContainer = null
	var v_split_container_ref: VSplitContainer = null
	var margin_container_ref: MarginContainer = null
	var center_container_ref: CenterContainer = null
	var aspect_ratio_container_ref: AspectRatioContainer = null
	var reference_rect_ref: ReferenceRect = null
	var nine_patch_rect_ref: NinePatchRect = null
	var sub_viewport_container_ref: SubViewportContainer = null
	var foldable_container_ref: FoldableContainer = null
	var sprite_2d_ref: Sprite2D = null
	var sprite_3d_ref: Sprite3D = null
	var animated_sprite_2d_ref: AnimatedSprite2D = null
	var animated_sprite_3d_ref: AnimatedSprite3D = null
	var camera_2d_ref: Camera2D = null
	var camera_3d_ref: Camera3D = null
	var tile_map_ref: TileMap = null
	var tile_map_layer_ref: TileMapLayer = null
	var line_2d_ref: Line2D = null
	var polygon_2d_ref: Polygon2D = null
	var marker_2d_ref: Marker2D = null
	var marker_3d_ref: Marker3D = null
	var path_2d_ref: Path2D = null
	var path_3d_ref: Path3D = null
	var path_follow_2d_ref: PathFollow2D = null
	var path_follow_3d_ref: PathFollow3D = null
	var ray_cast_2d_ref: RayCast2D = null
	var ray_cast_3d_ref: RayCast3D = null
	var collision_shape_2d_ref: CollisionShape2D = null
	var collision_shape_3d_ref: CollisionShape3D = null
	var collision_polygon_2d_ref: CollisionPolygon2D = null
	var static_body_2d_ref: StaticBody2D = null
	var static_body_3d_ref: StaticBody3D = null
	var rigid_body_2d_ref: RigidBody2D = null
	var rigid_body_3d_ref: RigidBody3D = null
	var character_body_2d_ref: CharacterBody2D = null
	var character_body_3d_ref: CharacterBody3D = null
	var area_2d_ref: Area2D = null
	var area_3d_ref: Area3D = null
	var animatable_body_2d_ref: AnimatableBody2D = null
	var animatable_body_3d_ref: AnimatableBody3D = null
	var physical_bone_2d_ref: PhysicalBone2D = null
	var physical_bone_3d_ref: PhysicalBone3D = null
	var vehicle_body_3d_ref: VehicleBody3D = null
	var cpu_particles_2d_ref: CPUParticles2D = null
	var cpu_particles_3d_ref: CPUParticles3D = null
	var gpu_particles_2d_ref: GPUParticles2D = null
	var gpu_particles_3d_ref: GPUParticles3D = null
	var mesh_instance_2d_ref: MeshInstance2D = null
	var mesh_instance_3d_ref: MeshInstance3D = null
	var multi_mesh_instance_3d_ref: MultiMeshInstance3D = null
	var directional_light_3d_ref: DirectionalLight3D = null
	var omni_light_3d_ref: OmniLight3D = null
	var spot_light_3d_ref: SpotLight3D = null
	var world_environment_ref: WorldEnvironment = null
	var spring_arm_3d_ref: SpringArm3D = null
	var grid_map_ref: GridMap = null
	var reflection_probe_ref: ReflectionProbe = null
	var decal_ref: Decal = null
	var fog_volume_ref: FogVolume = null
	var voxel_gi_ref: VoxelGI = null
	var lightmap_gi_ref: LightmapGI = null
	var visible_on_screen_notifier_2d_ref: VisibleOnScreenNotifier2D = null
	var visible_on_screen_notifier_3d_ref: VisibleOnScreenNotifier3D = null
	var remote_transform_2d_ref: RemoteTransform2D = null
	var remote_transform_3d_ref: RemoteTransform3D = null
	var animation_player_ref: AnimationPlayer = null
	var animation_tree_ref: AnimationTree = null
	var animation_mixer_ref: AnimationMixer = null
	var tween_ref: Tween = null
	var audio_stream_player_ref: AudioStreamPlayer = null
	var audio_stream_player_2d_ref: AudioStreamPlayer2D = null
	var audio_stream_player_3d_ref: AudioStreamPlayer3D = null
	var audio_effect_reverb_ref: AudioEffectReverb = null
	var audio_bus_layout_ref: AudioBusLayout = null
	var timer_ref: Timer = null
	var http_request_ref: HTTPRequest = null
	var resource_preloader_ref: ResourcePreloader = null
	var multiplayer_spawner_ref: MultiplayerSpawner = null
	var multiplayer_synchronizer_ref: MultiplayerSynchronizer = null
	var navigation_agent_2d_ref: NavigationAgent2D = null
	var navigation_agent_3d_ref: NavigationAgent3D = null
	var navigation_region_2d_ref: NavigationRegion2D = null
	var navigation_region_3d_ref: NavigationRegion3D = null
	var navigation_obstacle_2d_ref: NavigationObstacle2D = null
	var navigation_obstacle_3d_ref: NavigationObstacle3D = null
	var pin_joint_2d_ref: PinJoint2D = null
	var pin_joint_3d_ref: PinJoint3D = null
	var hinge_joint_3d_ref: HingeJoint3D = null
	var damped_spring_joint_2d_ref: DampedSpringJoint2D = null
	var groove_joint_2d_ref: GrooveJoint2D = null
	var input_event_key_ref: InputEventKey = null
	var input_event_mouse_button_ref: InputEventMouseButton = null
	var input_event_action_ref: InputEventAction = null
	var input_event_joypad_button_ref: InputEventJoypadButton = null
	var shortcut_ref: Shortcut = null
	var font_ref: Font = null
	var font_file_ref: FontFile = null
	var font_variation_ref: FontVariation = null
	var label_settings_ref: LabelSettings = null
	var theme_ref: Theme = null
	var style_box_flat_ref: StyleBoxFlat = null
	var style_box_ref: StyleBox = null
	var translation_ref: Translation = null
	var shader_ref: Shader = null
	var shader_material_ref: ShaderMaterial = null
	var standard_material_3d_ref: StandardMaterial3D = null
	var base_material_3d_ref: BaseMaterial3D = null
	var array_mesh_ref: ArrayMesh = null
	var box_mesh_ref: BoxMesh = null
	var capsule_mesh_ref: CapsuleMesh = null
	var cylinder_mesh_ref: CylinderMesh = null
	var plane_mesh_ref: PlaneMesh = null
	var quad_mesh_ref: QuadMesh = null
	var prism_mesh_ref: PrismMesh = null
	var sphere_mesh_ref: SphereMesh = null
	var immediate_mesh_ref: ImmediateMesh = null
	var image_ref: Image = null
	var image_texture_ref: ImageTexture = null
	var gradient_ref: Gradient = null
	var gradient_texture1d_ref: GradientTexture1D = null
	var gradient_texture_2d_ref: GradientTexture2D = null
	var curve_ref: Curve = null
	var curve_2d_ref: Curve2D = null
	var curve_3d_ref: Curve3D = null
	var noise_texture_2d_ref: NoiseTexture2D = null
	var fast_noise_lite_ref: FastNoiseLite = null
	var circle_shape_2d_ref: CircleShape2D = null
	var rectangle_shape_2d_ref: RectangleShape2D = null
	var capsule_shape_2d_ref: CapsuleShape2D = null
	var capsule_shape_3d_ref: CapsuleShape3D = null
	var box_shape_3d_ref: BoxShape3D = null
	var sphere_shape_3d_ref: SphereShape3D = null
	var convex_polygon_shape_3d_ref: ConvexPolygonShape3D = null
	var concave_polygon_shape_3d_ref: ConcavePolygonShape3D = null
	var height_map_shape_3d_ref: HeightMapShape3D = null
	var world_boundary_shape_2d_ref: WorldBoundaryShape2D = null
	var world_boundary_shape_3d_ref: WorldBoundaryShape3D = null
	var physics_material_ref: PhysicsMaterial = null
	var environment_ref: Environment = null
	var camera_attributes_ref: CameraAttributes = null
	var sky_ref: Sky = null
	var procedural_sky_material_ref: ProceduralSkyMaterial = null
	var physical_sky_material_ref: PhysicalSkyMaterial = null
	var panorama_sky_material_ref: PanoramaSkyMaterial = null
	var packed_scene_ref: PackedScene = null
	var scene_tree_ref: SceneTree = null
	var main_loop_ref: MainLoop = null
	var resource_ref: Resource = null
	var ref_counted_ref: RefCounted = null
	var config_file_ref: ConfigFile = null
	var reg_ex_ref: RegEx = null
	var json_ref: JSON = null
	var xml_parser_ref: XMLParser = null
	var crypto_ref: Crypto = null
	var aes_context_ref: AESContext = null
	var file_access_ref: FileAccess = null
	var dir_access_ref: DirAccess = null
	var tcp_server_ref: TCPServer = null
	var stream_peer_tcp_ref: StreamPeerTCP = null
	var packet_peer_udp_ref: PacketPeerUDP = null
	var web_socket_peer_ref: WebSocketPeer = null
	var skeleton_2d_ref: Skeleton2D = null
	var skeleton_3d_ref: Skeleton3D = null
	var bone_2d_ref: Bone2D = null
	var canvas_modulate_ref: CanvasModulate = null
	var sub_viewport_ref: SubViewport = null
	var viewport_ref: Viewport = null
	var light_2d_ref: Light2D = null
	var point_light_2d_ref: PointLight2D = null
	var directional_light_2d_ref: DirectionalLight2D = null
	var light_occluder_2d_ref: LightOccluder2D = null
	var parallax_background_ref: ParallaxBackground = null
	var parallax_layer_ref: ParallaxLayer = null
	var shape_cast_2d_ref: ShapeCast2D = null
	var shape_cast_3d_ref: ShapeCast3D = null
	var soft_body_3d_ref: SoftBody3D = null
	var spring_bone_simulator_3d_ref: SpringBoneSimulator3D = null
	var missing_node_ref: MissingNode = null
	var instance_placeholder_ref: InstancePlaceholder = null
	var canvas_texture_ref: CanvasTexture = null
	var camera_texture_ref: CameraTexture = null
	print(node_ref, button_ref, timer_ref)
	print(array_mesh_ref, audio_stream_player_ref, animation_player_ref)


func demo_indentation() -> void:
		## This body sits one extra level deep: Godot only requires
		## deeper-than-parent, not exactly-one-level indentation.
		var total := 0
		if total == 0:
			total += 1
		else:
			total -= 1
		for i in range(3):
				total += i
		while total > 100:
				total -= 1
		match total:
			4:
				total += 10
			_:
				pass
	 	# Oddly indented comments are ignored by the parser.
		# Blank line below carries trailing spaces, also ignored.
   
		var weird := [
				1,
		2,
	3,
		]
		print(weird)
		print(
			"free",
				"indent",
		)
		var continued := 1 + \
0 + \
				2
		print(total, continued)

func is_ready_custom() -> bool:
	return is_node_ready()


func sum_typed(values: Array[int]) -> int:
	var total := 0
	for v in values:
		total += v
	return total


func take_variant(v: Variant) -> Variant:
	return v


func with_many_defaults(
		p_sn: StringName = &"hi",
		p_np: NodePath = ^"A",
		p_v: Vector2 = Vector2.ZERO,
		p_c: Color = Color.RED,
		p_cb: Callable = Callable(),
		p_arr: Array[int] = [1, 2]
	) -> String:
		return "%s %s %s %s %d" % [p_sn, p_np, p_v, p_c, p_arr.size()]
