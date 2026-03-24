extends Area2D

@export var speed: float = 92.0
@export var heal_amount: int = 10

const RADIUS := 18.0
const INNER_CORE_RADIUS := 7.5

var network_entity_id := 0
var authority_simulation := true
var _network_target_position := Vector2.ZERO
var _has_network_target := false

func _ready() -> void:
	add_to_group("neutral_heal")

func _draw() -> void:
	draw_circle(Vector2.ZERO, RADIUS, Color(0.35, 1.0, 0.56, 0.74), true, -1.0, true)
	draw_circle(Vector2.ZERO, RADIUS, Color(0.08, 0.72, 0.24, 0.96), false, 2.0, true)
	draw_circle(Vector2.ZERO, INNER_CORE_RADIUS, Color(0.88, 1.0, 0.9, 0.95), true, -1.0, true)
	draw_circle(Vector2(-4.0, -6.0), 4.8, Color(1.0, 1.0, 1.0, 0.24), true, -1.0, true)

func _process(delta: float) -> void:
	if not authority_simulation:
		return
	var scene := get_tree().current_scene
	var target_node: Node2D = scene.get_nearest_player_node(global_position) if scene and scene.has_method("get_nearest_player_node") else null
	if not is_instance_valid(target_node):
		return
	var to_target := target_node.global_position - global_position
	if to_target.length_squared() > 0.0001:
		global_position += to_target.normalized() * speed * delta
	_cleanup_if_outside_bounds()

func hit_by_player_projectile(projectile: Area2D, bullet_radius: float) -> bool:
	var reach := RADIUS + bullet_radius
	if global_position.distance_squared_to(projectile.global_position) > reach * reach:
		return false
	var scene := get_tree().current_scene
	var shooter_peer_id := int(projectile.get_owner_peer_id()) if projectile != null and projectile.has_method("get_owner_peer_id") else 1
	if scene and scene.has_method("heal_player"):
		scene.heal_player(shooter_peer_id, heal_amount)
	if scene and scene.has_method("play_enemy_death_sfx"):
		scene.play_enemy_death_sfx()
	queue_free()
	return true

func _cleanup_if_outside_bounds() -> void:
	var scene := get_tree().current_scene
	if scene and scene.has_method("is_outside_cleanup_bounds") and scene.is_outside_cleanup_bounds(global_position, 120.0):
		queue_free()

func configure_network_entity(entity_id: int, authority: bool) -> void:
	network_entity_id = entity_id
	authority_simulation = authority
	set_process(authority)

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
	if dist_sq > 200.0 * 200.0:
		global_position = _network_target_position
		return
	var blend: float = min(1.0, delta * 10.0)
	global_position = global_position.lerp(_network_target_position, blend)

func _on_screen_exited() -> void:
	_cleanup_if_outside_bounds()
