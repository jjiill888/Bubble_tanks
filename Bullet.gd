extends Area2D

const PlayerPaletteRef := preload("res://PlayerPalette.gd")

@export var speed: float = 750.0
var pierce_hits_remaining: int = 0   # 剩余可继续穿透的命中次数
var _pool_active := true
var _use_external_update := false
var _color_key := "blue"
var _palette: Dictionary = PlayerPaletteRef.get_palette("blue")
var _visual_only := false
var owner_peer_id := 1

@onready var _collision_shape: CollisionShape2D = $CollisionShape2D

func _draw() -> void:
	draw_circle(Vector2.ZERO, 5.0, _palette["bullet_main"], true, -1.0, true)
	draw_circle(Vector2.ZERO, 5.0, _palette["bullet_rim"], false, 1.0, true)
	draw_circle(Vector2(-1.5, -2.0), 2.2, _palette["bullet_highlight"], true, -1.0, true)

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
	position += Vector2.RIGHT.rotated(rotation) * speed * delta
	var scene = get_tree().current_scene
	if not _visual_only and scene and scene.has_method("process_player_bullet_hit") and scene.process_player_bullet_hit(self):
		_consume_hit()
		if not _pool_active:
			return
	_cleanup_if_outside_bounds()

func is_pool_active() -> bool:
	return _pool_active

func activate_from_pool(spawn_position: Vector2, spawn_rotation: float, pierce_hits: int, color_key: String = "blue", visual_only: bool = false, shooter_peer_id: int = 1) -> void:
	_pool_active = true
	pierce_hits_remaining = pierce_hits
	_visual_only = visual_only
	owner_peer_id = shooter_peer_id
	global_position = spawn_position
	rotation = spawn_rotation
	set_color_key(color_key)
	visible = true
	var scene = get_tree().current_scene
	_use_external_update = scene != null and scene.has_method("register_player_bullet") and scene.has_method("process_player_bullet_hit")
	set_process(not _use_external_update)
	if _use_external_update:
		scene.register_player_bullet(self)
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
	global_position = Vector2(-10000.0, -10000.0)
	var scene = get_tree().current_scene
	if scene and scene.has_method("release_player_bullet"):
		scene.release_player_bullet(self)
	else:
		queue_free()

func deactivate_to_pool() -> void:
	_pool_active = false
	pierce_hits_remaining = 0
	_visual_only = false
	owner_peer_id = 1
	visible = false
	set_process(false)
	_use_external_update = false
	monitoring = false
	monitorable = false
	_collision_shape.disabled = true
	global_position = Vector2(-10000.0, -10000.0)

func get_owner_peer_id() -> int:
	return owner_peer_id

func _cleanup_if_outside_bounds() -> void:
	var scene = get_tree().current_scene
	if scene and scene.has_method("is_outside_cleanup_bounds") and scene.is_outside_cleanup_bounds(global_position, 120.0):
		return_to_pool()

func _consume_hit() -> void:
	if pierce_hits_remaining > 0:
		pierce_hits_remaining -= 1
	else:
		return_to_pool()

func _on_area_entered(area: Area2D) -> void:
	if not _pool_active or _visual_only:
		return
	if area.is_in_group("enemy"):
		if area.has_method("die"):
			area.die()
		_consume_hit()

func _on_screen_exited() -> void:
	if not _pool_active:
		return
	_cleanup_if_outside_bounds()
