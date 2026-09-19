class_name TmpRosterCycleB
extends RefCounted

## Cycle fixture (B side): references TmpRosterCycleA and back.


# @param m Node notnull
static func ping(m: Node) -> void:
	pass


func ding() -> void:
	TmpRosterCycleA.pong(null)
