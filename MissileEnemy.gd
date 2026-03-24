extends Area2D

@export var speed: float = 260.0
@export var turn_speed: float = 8.5
@export var max_hp: int = 1

const BODY_LENGTH := 36.0
const BODY_RADIUS := 7.5
const CONTACT_DAMAGE := 12
const CONTACT_RADIUS := 22.0
const SCORE_VALUE := 2

var hp: int = max_hp
var network_entity_id := 0
var authority_simulation := true
var _network_target_position := Vector2.ZERO
var _network_target_rotation := 0.0
var _has_network_target := false
var _last_hit_by_peer_id := 0

func _ready() -> void:
	hp = max_hp
	add_to_group("missile_enemy")
	queue_redraw()

func _draw() -> void:
	draw_rect(Rect2(-BODY_LENGTH * 0.5, -BODY_RADIUS, BODY_LENGTH - 7.0, BODY_RADIUS * 2.0), Color(1.0, 0.48, 0.16, 0.96), true)
	draw_rect(Rect2(-BODY_LENGTH * 0.5, -BODY_RADIUS, BODY_LENGTH - 7.0, BODY_RADIUS * 2.0), Color(0.68, 0.1, 0.06, 1.0), false, 1.4)
	draw_colored_polygon(PackedVector2Array([
		Vector2(BODY_LENGTH * 0.5 - 7.0, -BODY_RADIUS - 1.0),
		Vector2(BODY_LENGTH * 0.5 + 6.0, 0.0),
		Vector2(BODY_LENGTH * 0.5 - 7.0, BODY_RADIUS + 1.0),
	]), Color(0.94, 0.84, 0.28, 0.98))
	draw_colored_polygon(PackedVector2Array([
		Vector2(-BODY_LENGTH * 0.5, -BODY_RADIUS),
		Vector2(-BODY_LENGTH * 0.5 - 8.0, -BODY_RADIUS - 5.5),
		Vector2(-BODY_LENGTH * 0.5 + 2.0, -1.0),
	]), Color(0.96, 0.26, 0.12, 0.88))
	draw_colored_polygon(PackedVector2Array([
		Vector2(-BODY_LENGTH * 0.5, BODY_RADIUS),
		Vector2(-BODY_LENGTH * 0.5 - 8.0, BODY_RADIUS + 5.5),
		Vector2(-BODY_LENGTH * 0.5 + 2.0, 1.0),
	]), Color(0.96, 0.26, 0.12, 0.88))
	draw_circle(Vector2(BODY_LENGTH * 0.12, -2.3), 2.1, Color(1.0, 1.0, 1.0, 0.28), true, -1.0, true)

func _process(delta: float) -> void:
	if not authority_simulation:
		return
	var scene := get_tree().current_scene
	var target_node: Node2D = scene.get_nearest_player_node(global_position) if scene and scene.has_method("get_nearest_player_node") else null
	if is_instance_valid(target_node):
		var to_target := target_node.global_position - global_position
		if to_target.length_squared() > 0.001:
			rotation = lerp_angle(rotation, to_target.angle(), min(1.0, delta * turn_speed))
		if to_target.length_squared() <= CONTACT_RADIUS * CONTACT_RADIUS:
			if target_node.has_method("register_body_hit"):
				target_node.register_body_hit(global_position)
			var target_peer_id: int = scene.get_player_peer_id(target_node) if scene and scene.has_method("get_player_peer_id") else 1
			scene.take_damage(CONTACT_DAMAGE, target_peer_id)
			queue_free()
			return
	global_position += Vector2.RIGHT.rotated(rotation) * speed * delta
	_cleanup_if_outside_bounds()

func hit_by_player_projectile(projectile: Area2D, bullet_radius: float) -> bool:
	_last_hit_by_peer_id = int(projectile.get_owner_peer_id()) if projectile != null and projectile.has_method("get_owner_peer_id") else 0
	var radius := float(projectile.get_hit_radius()) if projectile != null and projectile.has_method("get_hit_radius") else bullet_radius
	return hit_by_player_bullet(projectile.global_position, radius)

func hit_by_player_bullet(bullet_pos: Vector2, bullet_radius: float) -> bool:
	var local_bullet := to_local(bullet_pos)
	var segment_start := Vector2(-BODY_LENGTH * 0.5, 0.0)
	var segment_end := Vector2(BODY_LENGTH * 0.5, 0.0)
	var closest := Geometry2D.get_closest_point_to_segment(local_bullet, segment_start, segment_end)
	var reach := BODY_RADIUS + bullet_radius
	if closest.distance_squared_to(local_bullet) > reach * reach:
		return false
	return _apply_projectile_damage()

func _apply_projectile_damage() -> bool:
	hp -= 1
	var scene := get_tree().current_scene
	if scene and scene.has_method("play_enemy_hit_sfx"):
		scene.play_enemy_hit_sfx(0.92)
	if hp <= 0:
		if scene:
			scene.add_score(SCORE_VALUE)
			if scene.has_method("award_experience_for_enemy_kind"):
				scene.award_experience_for_enemy_kind("missile", _last_hit_by_peer_id)
			if _last_hit_by_peer_id > 0 and scene.has_method("notify_enemy_killed"):
				scene.notify_enemy_killed(_last_hit_by_peer_id, "missile")
			if scene.has_method("play_enemy_death_sfx"):
				scene.play_enemy_death_sfx()
		queue_free()
	else:
		queue_redraw()
	return true

func configure_network_entity(entity_id: int, authority: bool) -> void:
	network_entity_id = entity_id
	authority_simulation = authority
	set_process(authority)

func get_network_entity_state() -> Dictionary:
	return {
		"pos": global_position,
		"rot": rotation,
		"hp": hp,
	}

func apply_network_entity_state(state: Dictionary) -> void:
	_network_target_position = state.get("pos", global_position)
	_network_target_rotation = float(state.get("rot", rotation))
	if not _has_network_target:
		global_position = _network_target_position
		rotation = _network_target_rotation
	_has_network_target = true
	var next_hp := int(state.get("hp", hp))
	if next_hp != hp:
		hp = next_hp
		queue_redraw()

func tick_network_interpolation(delta: float) -> void:
	if authority_simulation or not _has_network_target:
		return
	var dist_sq := global_position.distance_squared_to(_network_target_position)
	if dist_sq > 260.0 * 260.0:
		global_position = _network_target_position
	else:
		global_position = global_position.lerp(_network_target_position, min(1.0, delta * 11.0))
	rotation = lerp_angle(rotation, _network_target_rotation, min(1.0, delta * 14.0))

func get_missile_target_local_point(_from_global_position: Vector2 = Vector2.ZERO) -> Vector2:
	return Vector2.ZERO

func _cleanup_if_outside_bounds() -> void:
	var scene := get_tree().current_scene
	if scene and scene.has_method("is_outside_cleanup_bounds") and scene.is_outside_cleanup_bounds(global_position, BODY_LENGTH + 220.0):
		queue_free()

func _on_screen_exited() -> void:
	_cleanup_if_outside_bounds()
