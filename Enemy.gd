extends Area2D

@export var speed: float = 120.0
var network_entity_id := 0
var authority_simulation := true
var _network_target_position := Vector2.ZERO
var _has_network_target := false

const RADIUS       := 20.0
const NUC_OFFSET   := Vector2(-5.0, -4.0)
const NUC_RADIUS   := 7.0
const HL_OFFSET    := Vector2(7.0, -8.0)
const HL_RADIUS    := 5.5
const CONTACT_DAMAGE := 5

var _last_hit_by_peer_id := 0
var _hit_world: Object = null
var _hit_entry_id := 0

func _ready() -> void:
	add_to_group("enemy")
	_setup_hit_world()

func _exit_tree() -> void:
	_clear_hit_world_entry()

func _draw() -> void:
	# 泡泡主体（半透明红）
	draw_circle(Vector2.ZERO, RADIUS, Color(1.0, 0.22, 0.22, 0.72), true, -1.0, true)
	# 细胞膜轮廓
	draw_circle(Vector2.ZERO, RADIUS, Color(0.85, 0.06, 0.06, 0.88), false, 2.0, true)
	# 细胞核主体
	draw_circle(NUC_OFFSET, NUC_RADIUS, Color(0.52, 0.04, 0.04, 0.95), true, -1.0, true)
	# 核膜
	draw_circle(NUC_OFFSET, NUC_RADIUS, Color(0.32, 0.0, 0.0, 0.82), false, 1.2, true)
	# 高光（泡泡质感）
	draw_circle(HL_OFFSET, HL_RADIUS, Color(1.0, 1.0, 1.0, 0.24), true, -1.0, true)
	draw_circle(HL_OFFSET + Vector2(1.5, 1.0), HL_RADIUS * 0.5, Color(1.0, 1.0, 1.0, 0.14), true, -1.0, true)

func _process(delta: float) -> void:
	if not authority_simulation:
		return
	var scene: Node = get_tree().current_scene
	var target_node: Node2D = scene.get_nearest_player_node(global_position) if scene and scene.has_method("get_nearest_player_node") else null
	var target: Vector2 = target_node.global_position if is_instance_valid(target_node) else get_viewport_rect().size * 0.5
	var to_target: Vector2 = target - global_position
	if to_target.length_squared() < 22.0 * 22.0:
		var target_peer_id: int = scene.get_player_peer_id(target_node) if scene and scene.has_method("get_player_peer_id") else 1
		scene.take_damage(CONTACT_DAMAGE, target_peer_id)
		queue_free()
		return
	global_position += to_target.normalized() * speed * delta
	_sync_hit_world_entry()
	_cleanup_if_outside_bounds()

func _setup_hit_world() -> void:
	var scene := get_tree().current_scene
	if scene and scene.has_method("get_compound_hit_world"):
		_hit_world = scene.get_compound_hit_world()
	_refresh_hit_world_registration()

func _refresh_hit_world_registration() -> void:
	if _hit_world == null or not authority_simulation:
		_clear_hit_world_entry()
		return
	if _hit_entry_id == 0:
		_hit_entry_id = _hit_world.register_entry(get_instance_id(), "body", RADIUS)
	_sync_hit_world_entry()

func _sync_hit_world_entry() -> void:
	if _hit_world == null or not authority_simulation or _hit_entry_id == 0:
		return
	_hit_world.update_entry(_hit_entry_id, global_position, true)

func _clear_hit_world_entry() -> void:
	if _hit_world != null and _hit_entry_id != 0:
		_hit_world.remove_entry(_hit_entry_id)
	_hit_entry_id = 0

func _cleanup_if_outside_bounds() -> void:
	var scene = get_tree().current_scene
	if scene and scene.has_method("is_outside_cleanup_bounds") and scene.is_outside_cleanup_bounds(global_position, 180.0):
		queue_free()

func die() -> void:
	var scene := get_tree().current_scene
	get_tree().current_scene.add_score(1)
	if scene and scene.has_method("award_experience_for_enemy_kind"):
		scene.award_experience_for_enemy_kind("basic", _last_hit_by_peer_id)
	if _last_hit_by_peer_id > 0 and scene and scene.has_method("notify_enemy_killed"):
		scene.notify_enemy_killed(_last_hit_by_peer_id, "basic")
	if scene and scene.has_method("play_enemy_death_sfx"):
		scene.play_enemy_death_sfx()
	queue_free()

func hit_by_player_projectile(projectile: Area2D, bullet_radius: float) -> bool:
	_last_hit_by_peer_id = int(projectile.get_owner_peer_id()) if projectile != null and projectile.has_method("get_owner_peer_id") else 0
	return hit_by_player_bullet(projectile.global_position, bullet_radius)

func hit_hit_world_part(_part_name: String, projectile: Area2D, bullet_radius: float) -> bool:
	_last_hit_by_peer_id = int(projectile.get_owner_peer_id()) if projectile != null and projectile.has_method("get_owner_peer_id") else 0
	return hit_by_player_bullet(projectile.global_position, bullet_radius)

func configure_network_entity(entity_id: int, authority: bool) -> void:
	network_entity_id = entity_id
	authority_simulation = authority
	set_process(authority)
	_refresh_hit_world_registration()

func get_network_entity_state() -> Dictionary:
	return {
		"pos": global_position,
	}

func apply_network_entity_state(state: Dictionary) -> void:
	_network_target_position = state.get("pos", global_position)
	if not _has_network_target:
		global_position = _network_target_position
	_has_network_target = true

func tick_network_interpolation(delta: float) -> void:
	if authority_simulation or not _has_network_target:
		return
	var dist_sq := global_position.distance_squared_to(_network_target_position)
	if dist_sq > 180.0 * 180.0:
		global_position = _network_target_position
		return
	var blend: float = min(1.0, delta * 12.0)
	global_position = global_position.lerp(_network_target_position, blend)

func hit_by_player_bullet(bullet_pos: Vector2, bullet_radius: float) -> bool:
	var reach := RADIUS + bullet_radius
	if global_position.distance_squared_to(bullet_pos) > reach * reach:
		return false
	var scene := get_tree().current_scene
	if scene and scene.has_method("play_enemy_hit_sfx"):
		scene.play_enemy_hit_sfx(1.0)
	die()
	return true

func get_missile_target_local_point(_from_global_position: Vector2 = Vector2.ZERO) -> Vector2:
	return Vector2.ZERO

func _on_screen_exited() -> void:
	_cleanup_if_outside_bounds()
