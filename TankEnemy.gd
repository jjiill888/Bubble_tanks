extends Area2D

const TankGenomeFactory := preload("res://TankEnemyGenomeFactory.gd")

@export var speed: float = 72.0
@export var max_hp: int = 5

const CONTACT_DAMAGE := 18
const SCORE_VALUE := 3

var hp: int = max_hp
var network_entity_id := 0
var authority_simulation := true
var _network_target_position := Vector2.ZERO
var _has_network_target := false
var _last_hit_by_peer_id := 0
var _genome_entry_id := 0
var _core_radius := 30.0
var _rim_thickness := 2.4
var _core_color := Color(0.98, 0.46, 0.18, 0.78)
var _rim_color := Color(0.65, 0.12, 0.08, 0.95)
var _nucleus_offset := Vector2(-8.0, -7.0)
var _nucleus_radius := 9.0
var _highlight_offset := Vector2(10.0, 8.0)
var _highlight_radius := 7.0
var _lobes: Array[Dictionary] = []
var _hit_world: Object = null
var _core_hit_entry_id := 0
var _lobe_hit_entry_ids: Array[int] = []

func _ready() -> void:
	hp = max_hp
	if _lobes.is_empty():
		_apply_genome_entry(TankGenomeFactory.pick_random_entry())
	add_to_group("tank_enemy")
	_setup_hit_world()

func _exit_tree() -> void:
	_clear_hit_world_entries()

func _draw() -> void:
	var hp_ratio := float(hp) / maxf(float(max_hp), 1.0)
	var body_color := _core_color.lerp(Color(0.72, 0.18, 0.12, 0.88), 1.0 - hp_ratio)
	for lobe in _lobes:
		var angle := float(lobe.get("angle", 0.0))
		var distance := float(lobe.get("distance", 0.0))
		var radius := float(lobe.get("radius", 10.0))
		var center := Vector2.RIGHT.rotated(angle) * distance
		draw_circle(center, radius, body_color, true, -1.0, true)
		draw_circle(center, radius, _rim_color, false, _rim_thickness * 0.88, true)
	draw_circle(Vector2.ZERO, _core_radius, body_color, true, -1.0, true)
	draw_circle(Vector2.ZERO, _core_radius, _rim_color, false, _rim_thickness, true)
	draw_circle(_nucleus_offset, _nucleus_radius, Color(0.52, 0.08, 0.04, 0.95), true, -1.0, true)
	draw_circle(_highlight_offset, _highlight_radius, Color(1.0, 0.86, 0.75, 0.18), true, -1.0, true)

func _process(delta: float) -> void:
	if not authority_simulation:
		return
	var scene: Node = get_tree().current_scene
	var target_node: Node2D = scene.get_nearest_player_node(global_position) if scene and scene.has_method("get_nearest_player_node") else null
	var target: Vector2 = target_node.global_position if is_instance_valid(target_node) else get_viewport_rect().size * 0.5
	var to_target: Vector2 = target - global_position
	var contact_radius := _max_visual_radius() + 6.0
	if to_target.length_squared() < contact_radius * contact_radius:
		var target_peer_id: int = scene.get_player_peer_id(target_node) if scene and scene.has_method("get_player_peer_id") else 1
		scene.take_damage(CONTACT_DAMAGE, target_peer_id)
		queue_free()
		return
	global_position += to_target.normalized() * speed * delta
	_sync_hit_world_entries()
	_cleanup_if_outside_bounds()

func _setup_hit_world() -> void:
	var scene: Node = get_tree().current_scene
	if scene and scene.has_method("get_compound_hit_world"):
		_hit_world = scene.get_compound_hit_world()
	_refresh_hit_world_registration()

func _refresh_hit_world_registration() -> void:
	if _hit_world == null or not authority_simulation:
		_clear_hit_world_entries()
		return
	if _core_hit_entry_id == 0:
		_core_hit_entry_id = _hit_world.register_entry(get_instance_id(), "core", _core_radius)
	while _lobe_hit_entry_ids.size() < _lobes.size():
		var lobe_index: int = _lobe_hit_entry_ids.size()
		var lobe: Dictionary = _lobes[lobe_index]
		_lobe_hit_entry_ids.append(_hit_world.register_entry(get_instance_id(), "lobe:%d" % lobe_index, float(lobe.get("radius", 10.0))))
	while _lobe_hit_entry_ids.size() > _lobes.size():
		var removed_id: int = _lobe_hit_entry_ids.pop_back()
		if removed_id != 0:
			_hit_world.remove_entry(removed_id)
	_sync_hit_world_entries()

func _sync_hit_world_entries() -> void:
	if _hit_world == null or not authority_simulation:
		return
	if _core_hit_entry_id != 0:
		_hit_world.update_entry(_core_hit_entry_id, global_position, true)
	for i in range(_lobe_hit_entry_ids.size()):
		var entry_id: int = _lobe_hit_entry_ids[i]
		if entry_id == 0 or i >= _lobes.size():
			continue
		var lobe: Dictionary = _lobes[i]
		var center: Vector2 = Vector2.RIGHT.rotated(float(lobe.get("angle", 0.0))) * float(lobe.get("distance", 0.0))
		_hit_world.update_entry(entry_id, to_global(center), true)

func _clear_hit_world_entries() -> void:
	if _hit_world != null:
		if _core_hit_entry_id != 0:
			_hit_world.remove_entry(_core_hit_entry_id)
		for entry_id in _lobe_hit_entry_ids:
			if entry_id != 0:
				_hit_world.remove_entry(entry_id)
	_core_hit_entry_id = 0
	_lobe_hit_entry_ids.clear()

func hit_by_player_projectile(projectile: Area2D, bullet_radius: float) -> bool:
	_last_hit_by_peer_id = int(projectile.get_owner_peer_id()) if projectile != null and projectile.has_method("get_owner_peer_id") else 0
	return hit_by_player_bullet(projectile.global_position, bullet_radius)

func hit_hit_world_part(part_name: String, projectile: Area2D, bullet_radius: float) -> bool:
	_last_hit_by_peer_id = int(projectile.get_owner_peer_id()) if projectile != null and projectile.has_method("get_owner_peer_id") else 0
	if part_name == "core":
		return _apply_projectile_damage()
	if part_name.begins_with("lobe:"):
		var lobe_index := int(part_name.trim_prefix("lobe:"))
		if lobe_index >= 0 and lobe_index < _lobes.size():
			return _apply_projectile_damage()
	return hit_by_player_bullet(projectile.global_position, bullet_radius)

func _apply_projectile_damage() -> bool:
	hp -= 1
	var scene := get_tree().current_scene
	if scene and scene.has_method("play_enemy_hit_sfx"):
		scene.play_enemy_hit_sfx(0.82)
	if hp <= 0:
		if scene:
			scene.add_score(SCORE_VALUE)
			if scene.has_method("award_experience_for_enemy_kind"):
				scene.award_experience_for_enemy_kind("tank", _last_hit_by_peer_id)
			if _last_hit_by_peer_id > 0 and scene.has_method("notify_enemy_killed"):
				scene.notify_enemy_killed(_last_hit_by_peer_id, "tank")
			if scene.has_method("play_enemy_death_sfx"):
				scene.play_enemy_death_sfx()
		queue_free()
	else:
		queue_redraw()
	return true

func hit_by_player_bullet(bullet_pos: Vector2, bullet_radius: float) -> bool:
	var reach := _core_radius + bullet_radius
	for lobe in _lobes:
		var lobe_center := Vector2.RIGHT.rotated(float(lobe.get("angle", 0.0))) * float(lobe.get("distance", 0.0))
		var lobe_reach := float(lobe.get("radius", 10.0)) + bullet_radius
		if to_global(lobe_center).distance_squared_to(bullet_pos) <= lobe_reach * lobe_reach:
			return _apply_projectile_damage()
	if global_position.distance_squared_to(bullet_pos) > reach * reach:
		return false
	return _apply_projectile_damage()

func _cleanup_if_outside_bounds() -> void:
	var scene := get_tree().current_scene
	if scene and scene.has_method("is_outside_cleanup_bounds") and scene.is_outside_cleanup_bounds(global_position, _max_visual_radius() + 230.0):
		queue_free()

func _max_visual_radius() -> float:
	var max_radius := _core_radius
	for lobe in _lobes:
		var extent := float(lobe.get("distance", 0.0)) + float(lobe.get("radius", 0.0))
		max_radius = maxf(max_radius, extent)
	return max_radius

func _apply_genome_entry(entry: Dictionary) -> void:
	_genome_entry_id = int(entry.get("id", 0))
	var genome := entry.get("genome", {}) as Dictionary
	_core_radius = float(genome.get("core_radius", 30.0))
	_rim_thickness = float(genome.get("rim_thickness", 2.4))
	_core_color = _array_to_color(genome.get("core_color", [0.98, 0.46, 0.18, 0.78]))
	_rim_color = _array_to_color(genome.get("rim_color", [0.65, 0.12, 0.08, 0.95]))
	_nucleus_offset = _array_to_vector2(genome.get("nucleus_offset", [-8.0, -7.0]))
	_nucleus_radius = float(genome.get("nucleus_radius", 9.0))
	_highlight_offset = _array_to_vector2(genome.get("highlight_offset", [10.0, 8.0]))
	_highlight_radius = float(genome.get("highlight_radius", 7.0))
	_lobes.clear()
	for lobe_variant in genome.get("lobes", []):
		_lobes.append((lobe_variant as Dictionary).duplicate(true))
	_refresh_hit_world_registration()
	queue_redraw()

func _array_to_vector2(value: Variant) -> Vector2:
	if value is Array and value.size() >= 2:
		return Vector2(float(value[0]), float(value[1]))
	return Vector2.ZERO

func _array_to_color(value: Variant) -> Color:
	if value is Array and value.size() >= 4:
		return Color(float(value[0]), float(value[1]), float(value[2]), float(value[3]))
	return Color(1.0, 1.0, 1.0, 1.0)

func get_network_spawn_payload() -> Dictionary:
	return {
		"genome_id": _genome_entry_id,
	}

func apply_network_spawn_payload(payload: Dictionary) -> void:
	var genome_id := int(payload.get("genome_id", 0))
	_apply_genome_entry(TankGenomeFactory.get_entry_by_id(genome_id))

func configure_network_entity(entity_id: int, authority: bool) -> void:
	network_entity_id = entity_id
	authority_simulation = authority
	set_process(authority)
	_refresh_hit_world_registration()

func get_network_entity_state() -> Dictionary:
	return {
		"pos": global_position,
		"hp": hp,
	}

func apply_network_entity_state(state: Dictionary) -> void:
	_network_target_position = state.get("pos", global_position)
	if not _has_network_target:
		global_position = _network_target_position
	_has_network_target = true
	var next_hp := int(state.get("hp", hp))
	if next_hp != hp:
		hp = next_hp
		queue_redraw()

func tick_network_interpolation(delta: float) -> void:
	if authority_simulation or not _has_network_target:
		return
	var dist_sq := global_position.distance_squared_to(_network_target_position)
	if dist_sq > 240.0 * 240.0:
		global_position = _network_target_position
		return
	var blend: float = min(1.0, delta * 9.0)
	global_position = global_position.lerp(_network_target_position, blend)

func get_missile_target_local_point(from_global_position: Vector2 = Vector2.ZERO) -> Vector2:
	var local_from := to_local(from_global_position)
	var best_point := Vector2.ZERO
	var best_dist_sq := local_from.distance_squared_to(Vector2.ZERO)
	for lobe in _lobes:
		var lobe_center := Vector2.RIGHT.rotated(float(lobe.get("angle", 0.0))) * float(lobe.get("distance", 0.0))
		var lobe_dist_sq := local_from.distance_squared_to(lobe_center)
		if lobe_dist_sq < best_dist_sq:
			best_dist_sq = lobe_dist_sq
			best_point = lobe_center
	return best_point

func _on_screen_exited() -> void:
	_cleanup_if_outside_bounds()