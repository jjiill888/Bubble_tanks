extends Area2D

const PlayerPaletteRef := preload("res://PlayerPalette.gd")
const HIT_RADIUS := 9.0
const DEFAULT_PIERCE_HITS := 3
const MAX_LIFETIME := 4.5

@export var speed: float = 460.0
@export var turn_speed: float = 7.4

var _pool_active := true
var _use_external_update := false
var _visual_only := false
var _color_key := "blue"
var _palette: Dictionary = PlayerPaletteRef.get_palette("blue")
var owner_peer_id := 1
var _target_node: Node2D = null
var _target_local_point := Vector2.ZERO
var _lifetime_remaining := MAX_LIFETIME
var pierce_hits_remaining: int = DEFAULT_PIERCE_HITS

@onready var _collision_shape: CollisionShape2D = $CollisionShape2D

func _draw() -> void:
	draw_rect(Rect2(-11.0, -3.8, 18.0, 7.6), _palette["barrel_main"], true)
	draw_rect(Rect2(-11.0, -3.8, 18.0, 7.6), _palette["barrel_rim"], false, 1.0)
	draw_colored_polygon(PackedVector2Array([
		Vector2(7.0, -4.8),
		Vector2(14.0, 0.0),
		Vector2(7.0, 4.8),
	]), _palette["muzzle_main"])
	draw_colored_polygon(PackedVector2Array([
		Vector2(-11.0, -3.8),
		Vector2(-16.5, -7.0),
		Vector2(-7.0, -1.2),
	]), _palette["turret_ring"])
	draw_colored_polygon(PackedVector2Array([
		Vector2(-11.0, 3.8),
		Vector2(-16.5, 7.0),
		Vector2(-7.0, 1.2),
	]), _palette["turret_ring"])
	draw_circle(Vector2(-2.0, -1.6), 1.7, Color(1.0, 1.0, 1.0, 0.32), true, -1.0, true)

func set_color_key(color_key: String) -> void:
	if _color_key == color_key:
		return
	_color_key = color_key
	_palette = PlayerPaletteRef.get_palette(_color_key)
	queue_redraw()

func _process(delta: float) -> void:
	if _use_external_update:
		return
	advance_projectile(delta)

func advance_projectile(delta: float) -> void:
	if not _pool_active:
		return
	_lifetime_remaining -= delta
	if _lifetime_remaining <= 0.0:
		return_to_pool()
		return
	var scene := get_tree().current_scene
	if not _has_valid_target_anchor():
		_acquire_target_anchor(scene)
	if _has_valid_target_anchor():
		var to_target := _get_target_world_point() - global_position
		if to_target.length_squared() > 0.001:
			rotation = lerp_angle(rotation, to_target.angle(), min(1.0, delta * turn_speed))
	position += Vector2.RIGHT.rotated(rotation) * speed * delta
	if not _visual_only and scene and scene.has_method("process_player_bullet_hit") and scene.process_player_bullet_hit(self):
		_consume_hit()
		return
	_cleanup_if_outside_bounds()

func is_pool_active() -> bool:
	return _pool_active

func activate_from_pool(spawn_position: Vector2, spawn_rotation: float, color_key: String = "blue", visual_only: bool = false, shooter_peer_id: int = 1, pierce_hits: int = DEFAULT_PIERCE_HITS) -> void:
	_pool_active = true
	_visual_only = visual_only
	owner_peer_id = shooter_peer_id
	pierce_hits_remaining = maxi(pierce_hits, 0)
	_target_node = null
	_target_local_point = Vector2.ZERO
	_lifetime_remaining = MAX_LIFETIME
	global_position = spawn_position
	rotation = spawn_rotation
	set_color_key(color_key)
	visible = true
	var scene := get_tree().current_scene
	_use_external_update = scene != null and scene.has_method("register_player_missile") and scene.has_method("process_player_bullet_hit")
	set_process(not _use_external_update)
	if _use_external_update:
		scene.register_player_missile(self)
	monitoring = not _use_external_update
	monitorable = not _use_external_update
	_collision_shape.disabled = _use_external_update

func return_to_pool() -> void:
	if not _pool_active:
		return
	_pool_active = false
	visible = false
	set_process(false)
	_use_external_update = false
	_target_node = null
	_target_local_point = Vector2.ZERO
	global_position = Vector2(-10000.0, -10000.0)
	var scene := get_tree().current_scene
	if scene and scene.has_method("release_player_missile"):
		scene.release_player_missile(self)
	else:
		queue_free()

func deactivate_to_pool() -> void:
	_pool_active = false
	_visual_only = false
	owner_peer_id = 1
	pierce_hits_remaining = DEFAULT_PIERCE_HITS
	_target_node = null
	_target_local_point = Vector2.ZERO
	_lifetime_remaining = MAX_LIFETIME
	visible = false
	set_process(false)
	_use_external_update = false
	monitoring = false
	monitorable = false
	_collision_shape.disabled = true
	global_position = Vector2(-10000.0, -10000.0)

func get_owner_peer_id() -> int:
	return owner_peer_id

func get_hit_radius() -> float:
	return HIT_RADIUS

func _consume_hit() -> void:
	if pierce_hits_remaining > 0:
		pierce_hits_remaining -= 1
		_target_node = null
		_target_local_point = Vector2.ZERO
		return
	return_to_pool()

func _has_valid_target_anchor() -> bool:
	return _target_node != null and is_instance_valid(_target_node)

func _get_target_world_point() -> Vector2:
	if not _has_valid_target_anchor():
		return global_position + Vector2.RIGHT.rotated(rotation) * 180.0
		
	return _target_node.to_global(_target_local_point)

func _acquire_target_anchor(scene: Node) -> void:
	_target_node = null
	_target_local_point = Vector2.ZERO
	if scene == null or not scene.has_method("get_nearest_enemy_target_anchor"):
		return
	var anchor: Dictionary = scene.get_nearest_enemy_target_anchor(global_position)
	if anchor.is_empty():
		return
	var target_node := anchor.get("node", null) as Node2D
	if target_node == null or not is_instance_valid(target_node):
		return
	_target_node = target_node
	_target_local_point = anchor.get("local_point", Vector2.ZERO) as Vector2

func _cleanup_if_outside_bounds() -> void:
	var scene := get_tree().current_scene
	if scene and scene.has_method("is_outside_cleanup_bounds") and scene.is_outside_cleanup_bounds(global_position, 150.0):
		return_to_pool()

func _on_screen_exited() -> void:
	if not _pool_active:
		return
	_cleanup_if_outside_bounds()
