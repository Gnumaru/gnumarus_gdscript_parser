class_name TmpRosterQuoted
extends "res://addons/0GnumarusGodotProjectAnalyzerSuite/tests/TmpRosterParent.gd"

## Quoted-extends fixture: the parser drops quoted bases, so the
## roster scan is the only source of this edge. Godot-valid.


func ownq() -> void:
	pass


# @var qx Node nullable
var qx: Node


func via_super() -> void:
	super.take(null)
	super.plain(qx)
