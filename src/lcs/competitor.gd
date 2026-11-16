class_name LcsCompetitor
extends Car
## Shared vehicle physics; only the authority processes physical damage.
var authoritative := true
var competitor_id := 0

func _handle_impacts() -> void:
	if authoritative:
		super._handle_impacts()
	else:
		_impacts.clear()

func repair_full() -> void:
	pass # Combat ledger is the only source of healing in this mode.
