class_name GnumarusGodotProjectAnalyzerSuiteAnnotationsShowcase2
extends Node
# @private
func _my_private_func() -> void:
	pass

# @deprecated Use new_api() instead.
func old_api() -> void:
	pass


func new_api() -> void:
	pass


func use_own() -> void:
	_my_private_func() # OK: own privates usable inside the owner
	old_api() # WARNING: own deprecated use still warns


# @private
var _secret := 42


# @tuple ShowPair 2 int String
# @var pair_ok ShowPair
var pair_ok: Array = [1, "a"] # OK: length and elements conform


# @var pair_bad ShowPair
var pair_bad: Array = [1, 2, 3] # ERROR: expects 2 elements, got 3


func tuple_demo() -> void:
	print(pair_ok[0]) # OK: int
	print(pair_ok[5]) # ERROR: index out of bounds


# @struct ShowPoint 2 x:int y:int
# @var point_ok ShowPoint
var point_ok: Dictionary = {"x": 1, "y": 2} # OK: exact keys


# @var point_bad ShowPoint
var point_bad: Dictionary = {"x": 1} # ERROR: expects 2 fields, got 1


# @alias show_number int|float @endalias
# @alias show_flag bool @endalias
# @var flag_ok show_flag
var flag_ok := true # OK: bool matches the alias


# @var num_bad show_number
var num_bad := "a" # ERROR on the tag above: neither int nor float is String


# @template ShowTNum of int|float
# @param x ShowTNum
# @return ShowTNum
func double_it(x):
	return x


func template_demo() -> void:
	double_it(2) # OK: int satisfies the bound
	double_it("nope") # ERROR: String violates int|float


# @template ShowTBox
# @generic ShowTBox
class ShowBox:
	# @param x ShowTBox
	func store(x) -> void:
		pass


# @generic Nope
class ShowBadBox:
	pass # ERROR on the tag above: non-template name


func generic_demo() -> void:
	var b: ShowBox
	b.store("anything") # OK: bare instances stay opaque


# @return int
func give_number():
	return 1 # OK


# @return int
func give_nothing():
	return # ERROR: bare return in non-void function


# @return Node
func give_control() -> Control: # ERROR: Node is wider than Control
	return Control.new()


# @param amount Nope
func take_something(amount):
	pass # ERROR on the tag above: unknown type 'Nope'


# @param size int
func take_node(size: Node):
	pass # ERROR: int is neither Node nor a subclass


func var_demo() -> void:
	var t: Node
	# @var t Control
	print(t) # OK: narrows the local
	# @var nope int
	var t2 := 1 # ERROR on the tag above: no variable 'nope'


func misplaced_demo() -> void:
	# @deprecated
	pass # ERROR on the tag above: misplaced tag


class ShowSibA:
	func f() -> void:
		print(ShowSibB.hidden) # ERROR: cannot use private variable 'ShowSibB.hidden'


class ShowSibB:
	# @private
	static var hidden := 1


# @interface ShowDrawable
# func:ping:void
# @endinterface


# @implements ShowDrawable
class ShowGoodImpl:
	func ping() -> void:
		pass # OK: satisfies ShowDrawable


# @implements ShowDrawable
class ShowBadImpl:
	func nope() -> void:
		pass # ERROR: missing 'ping'


# @interface ShowBadIface
# func:broken:Nope:x:int
# @endinterface


# @struct ShowBadPoint 1 x:Nope


# @template ShowTBad of Nope


# @alias show_broken int|float
var filler := 0 # ERROR on the tag above: missing @endalias


# @alias ShowMaybeNode Node|null @endalias
# @var nn_node Node notnull
var nn_node: Node


func nn_demo() -> void:
	nn_node = null # ERROR: cannot assign null to notnull


# @param p Node notnull
func need_node(p: Node = null): # ERROR on the tag above: null default
	pass


func call_demo() -> void:
	need_node(null) # ERROR: null argument
	need_node(Node.new()) # OK


# @return Node notnull
func make_node() -> Node:
	return null # ERROR: cannot return null


func guard_demo(n: Node) -> void:
	if n == null:
		n.queue_free() # ERROR: provably null
	if n != null:
		n.queue_free() # OK: proven non-null
