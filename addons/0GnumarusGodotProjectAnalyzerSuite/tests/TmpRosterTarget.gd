class_name TmpRosterTarget
extends RefCounted

## Leaf fixture for roster tests: never analyzed directly by the
## suite (no suite touches this file), so cross checks against it
## prove on-demand dependency analysis. Godot-valid on its own.


# @param m Node notnull
func take(m: Node) -> void:
	pass


func plain(m: Node) -> void:
	pass


# @return Node nullable
func hook() -> Node:
	return null
