class_name TmpRosterCycleA
extends RefCounted

## Cycle fixture (A side): references TmpRosterCycleB and back.
## Proves the resolve-stack guard terminates mutual references.


# @param m Node notnull
static func pong(m: Node) -> void:
	pass


func ring() -> void:
	TmpRosterCycleB.ping(null)
