class_name LcsProps
extends Destructibles
## Authoritative removal/slowdown; debris is cosmetic and omitted on headless servers.
func _throw(kind: String, xf: Transform3D, car: Car, w: CityWorld) -> void:
	if DisplayServer.get_name() != "headless":
		super._throw(kind, xf, car, w)

func apply_remote(at: Vector3, car: Car = null) -> void:
	var cell_key := Vector2i(floori(at.x / CELL), floori(at.z / CELL))
	var cell: Array = _grid.get(cell_key, [])
	var key := CityWorld.item_key(at)
	for i in range(cell.size() - 1, -1, -1):
		var item: Array = cell[i]
		if item[3] != key:
			continue
		var w: CityWorld = item[4]
		w.broken[key] = true
		_dirty[item[2]] = 0.15
		_dirty_world[item[2]] = w
		cell.remove_at(i)
		if car:
			_throw(item[0], item[1], car, w)
		return
