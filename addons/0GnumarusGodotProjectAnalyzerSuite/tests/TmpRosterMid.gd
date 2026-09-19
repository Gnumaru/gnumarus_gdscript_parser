class_name TmpRosterMid
extends RefCounted

## Mid-chain fixture for roster tests: references TmpRosterTarget,
## so a caller referencing only Mid proves transitive on-demand
## (Mid analyzed, then Target). Godot-valid on its own.


func via(t: TmpRosterTarget) -> void:
	t.plain(Node.new())


# @return Node nullable
func fetch(t: TmpRosterTarget):
	return t.hook()
