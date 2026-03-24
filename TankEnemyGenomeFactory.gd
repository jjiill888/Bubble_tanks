class_name TankEnemyGenomeFactory
extends RefCounted

const GENOME_FILE := "res://tank_genomes.json"

static var _json_pool: Array = []
static var _json_loaded := false

static func _load_json_pool() -> void:
	if _json_loaded:
		return
	_json_loaded = true
	if not FileAccess.file_exists(GENOME_FILE):
		return
	var file: FileAccess = FileAccess.open(GENOME_FILE, FileAccess.READ)
	if file == null:
		return
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	if parsed is Array:
		_json_pool = parsed

static func fallback_genome() -> Dictionary:
	return {
		"id": 0,
		"genome": {
			"core_radius": 29.0,
			"rim_thickness": 2.4,
			"core_color": [0.96, 0.44, 0.18, 0.82],
			"rim_color": [0.67, 0.16, 0.10, 0.96],
			"nucleus_offset": [-8.0, -6.0],
			"nucleus_radius": 8.5,
			"highlight_offset": [11.0, 8.0],
			"highlight_radius": 6.5,
			"lobes": [
				{"angle": 0.45, "distance": 19.0, "radius": 12.0},
				{"angle": 2.55, "distance": 17.0, "radius": 10.0},
				{"angle": 4.25, "distance": 14.0, "radius": 8.0}
			]
		}
	}

static func pick_random_entry() -> Dictionary:
	_load_json_pool()
	if _json_pool.is_empty():
		return fallback_genome()
	var index: int = randi() % _json_pool.size()
	return (_json_pool[index] as Dictionary).duplicate(true)

static func get_entry_by_id(entry_id: int) -> Dictionary:
	_load_json_pool()
	for entry_variant in _json_pool:
		var entry := entry_variant as Dictionary
		if int(entry.get("id", -1)) == entry_id:
			return entry.duplicate(true)
	return fallback_genome()
