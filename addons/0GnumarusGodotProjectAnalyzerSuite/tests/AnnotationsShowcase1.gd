# @interface DoThing func:thing:void @endinterface

class_name GnumarusGodotProjectAnalyzerSuiteAnnotationsShowcase1

extends Node

func _ready() -> void:
	# deprecated func, gives warning
	my_old_func()

	# non-deprecated, does not give warning
	my_new_func()

	# yeilds error. "UnexistingType" is unknow
	# @var v1 UnexistingType
	var v1

	# @var v2 int|String
	var v2 = false

	var showcase2: Variant = GnumarusGodotProjectAnalyzerSuiteAnnotationsShowcase2.new()
	# typing as 'Variant' is equivalent to typescripts "unknown" type: every usage is an error unless type guarded
	showcase2._my_private_func()

	if showcase2 is GnumarusGodotProjectAnalyzerSuiteAnnotationsShowcase2:
		# still an error because _my_private_func is anotated as private
		showcase2._my_private_func()

	# @var myint Variant
	var myint: Variant = 1
	myint = 'çlkj'
	var v: Variant

	# analiser error, all unchecked uses of Variant besides assignment are errors
	v.thing()

	# not longer analiser error, "v" type was redefined throuh a new anotation, and DoThing has the method "thing"
	# @var v DoThing
	v.thing()

	# @var v Variant
	v.thing() # "v" becomes unknown yet again due to type redefinition. yields error
	Color.RED

func my_new_func():
	return

# @deprecated
func my_old_func():
	return


func cross_file_demo() -> void:
	var other: Variant = GnumarusGodotProjectAnalyzerSuiteAnnotationsShowcase2.new()
	if other is GnumarusGodotProjectAnalyzerSuiteAnnotationsShowcase2:
		other.old_api() # WARNING: deprecated member from another file
		print(other._secret) # ERROR: private field from another file
		other.new_api() # OK: public member from another file


func interface_demo() -> void:
	var mynode: Variant = GnumarusGodotProjectAnalyzerSuiteAnnotationsShowcase2.new()
	# @var mynode ShowDrawable
	mynode.ping() # OK: ShowDrawable provides ping
	mynode.bogus() # ERROR: nobody provides bogus


func null_demo() -> void:
	var other: Variant = GnumarusGodotProjectAnalyzerSuiteAnnotationsShowcase2.new()
	if other == null:
		other.queue_free() # ERROR: provably null
	# the ShowMaybeNode alias was defined in other class, in GnumarusGodotProjectAnalyzerSuiteAnnotationsShowcase2
	# @var okay ShowMaybeNode
	var okay: Node # OK: both arms fit Node
	# @var bad ShowMaybeNode
	var bad := 1 # ERROR on the tag above: neither arm fits int
