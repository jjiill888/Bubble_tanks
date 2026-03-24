extends RefCounted

const CELL_SIZE := 96.0

var _next_entry_id := 1
var _entries: Dictionary = {}
var _cells: Dictionary = {}

func register_entry(enemy_id: int, part: String, radius: float) -> int:
	var entry_id := _next_entry_id
	_next_entry_id += 1
	_entries[entry_id] = {
		"enemy_id": enemy_id,
		"part": part,
		"radius": radius,
		"pos": Vector2.ZERO,
		"active": false,
		"cell": Vector2i.ZERO,
	}
	return entry_id

func update_entry(entry_id: int, world_pos: Vector2, active: bool) -> void:
	var entry: Dictionary = _entries.get(entry_id, {})
	if entry.is_empty():
		return
	var was_active := bool(entry.get("active", false))
	var previous_cell: Vector2i = entry.get("cell", Vector2i.ZERO)
	if was_active and not active:
		_remove_from_cell(entry_id, previous_cell)
		entry["active"] = false
		entry["pos"] = world_pos
		_entries[entry_id] = entry
		return
	var next_cell := _cell_for_position(world_pos)
	if was_active and previous_cell != next_cell:
		_remove_from_cell(entry_id, previous_cell)
	if active and (not was_active or previous_cell != next_cell):
		_add_to_cell(entry_id, next_cell)
	entry["active"] = active
	entry["pos"] = world_pos
	entry["cell"] = next_cell
	_entries[entry_id] = entry

func remove_entry(entry_id: int) -> void:
	var entry: Dictionary = _entries.get(entry_id, {})
	if entry.is_empty():
		return
	if bool(entry.get("active", false)):
		_remove_from_cell(entry_id, entry.get("cell", Vector2i.ZERO))
	_entries.erase(entry_id)

func query_hit(world_pos: Vector2, bullet_radius: float) -> Dictionary:
	var base_cell := _cell_for_position(world_pos)
	var best_hit: Dictionary = {}
	var best_distance_sq := INF
	for offset_y in range(-1, 2):
		for offset_x in range(-1, 2):
			var cell := base_cell + Vector2i(offset_x, offset_y)
			var bucket: Array = _cells.get(cell, [])
			for entry_id in bucket:
				var entry: Dictionary = _entries.get(entry_id, {})
				if entry.is_empty() or not bool(entry.get("active", false)):
					continue
				var reach := float(entry.get("radius", 0.0)) + bullet_radius
				var distance_sq := world_pos.distance_squared_to(entry.get("pos", Vector2.ZERO))
				if distance_sq > reach * reach:
					continue
				if best_hit.is_empty() or distance_sq < best_distance_sq:
					best_distance_sq = distance_sq
					best_hit = {
						"enemy_id": int(entry.get("enemy_id", 0)),
						"part": String(entry.get("part", "")),
						"entry_id": int(entry_id),
					}
	return best_hit

func clear() -> void:
	_entries.clear()
	_cells.clear()
	_next_entry_id = 1

func _cell_for_position(world_pos: Vector2) -> Vector2i:
	return Vector2i(
		int(floor(world_pos.x / CELL_SIZE)),
		int(floor(world_pos.y / CELL_SIZE))
	)

func _add_to_cell(entry_id: int, cell: Vector2i) -> void:
	var bucket: Array = _cells.get(cell, [])
	if not bucket.has(entry_id):
		bucket.append(entry_id)
	_cells[cell] = bucket

func _remove_from_cell(entry_id: int, cell: Vector2i) -> void:
	if not _cells.has(cell):
		return
	var bucket: Array = _cells[cell]
	bucket.erase(entry_id)
	if bucket.is_empty():
		_cells.erase(cell)
	else:
		_cells[cell] = bucket