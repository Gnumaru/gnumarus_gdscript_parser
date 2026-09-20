class_name TmpRosterOuter
extends RefCounted

## Outer fixture for cross-file inner-class tests: dotted names
## (`TmpRosterOuter.Inner`) resolve through the roster with direct
## members, and `Kid2` resolves its parent through the lexical
## prefix fallback.


class Inner:
	# @param m Node notnull
	func take(m: Node) -> void:
		pass

	func plain(m: Node) -> void:
		pass


class Base2:
	# @param m Node notnull
	func grp(m: Node) -> void:
		pass


class Kid2 extends Base2:
	func own2() -> void:
		pass
