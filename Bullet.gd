extends Area2D

@export var speed: float = 750.0
var pierce_hits_remaining: int = 0   # 剩余可继续穿透的命中次数
var _pool_active := true

@onready var _collision_shape: CollisionShape2D = $CollisionShape2D

func _draw() -> void:
	# 子弹：浅蓝色水滴
	draw_circle(Vector2.ZERO, 5.0, Color(0.55, 0.88, 1.0, 0.95), true, -1.0, true)
	draw_circle(Vector2.ZERO, 5.0, Color(0.25, 0.65, 0.92, 1.0), false, 1.0, true)
	# 高光
	draw_circle(Vector2(-1.5, -2.0), 2.2, Color(1.0, 1.0, 1.0, 0.45), true, -1.0, true)

func _process(delta: float) -> void:
	if not _pool_active:
		return
	position += Vector2.RIGHT.rotated(rotation) * speed * delta
	_cleanup_if_outside_bounds()

func activate_from_pool(spawn_position: Vector2, spawn_rotation: float, pierce_hits: int) -> void:
	_pool_active = true
	pierce_hits_remaining = pierce_hits
	global_position = spawn_position
	rotation = spawn_rotation
	visible = true
	set_process(true)
	monitoring = true
	monitorable = true
	_collision_shape.disabled = false

func return_to_pool() -> void:
	if not _pool_active:
		return
	_pool_active = false
	visible = false
	set_process(false)
	global_position = Vector2(-10000.0, -10000.0)
	var scene = get_tree().current_scene
	if scene and scene.has_method("release_player_bullet"):
		scene.release_player_bullet(self)
	else:
		queue_free()

func deactivate_to_pool() -> void:
	_pool_active = false
	pierce_hits_remaining = 0
	visible = false
	set_process(false)
	monitoring = false
	monitorable = false
	_collision_shape.disabled = true
	global_position = Vector2(-10000.0, -10000.0)

func _cleanup_if_outside_bounds() -> void:
	var scene = get_tree().current_scene
	if scene and scene.has_method("is_outside_cleanup_bounds") and scene.is_outside_cleanup_bounds(global_position, 120.0):
		return_to_pool()

func _on_area_entered(area: Area2D) -> void:
	if not _pool_active:
		return
	if area.is_in_group("enemy"):
		if area.has_method("die"):
			area.die()
		if pierce_hits_remaining > 0:
			pierce_hits_remaining -= 1
		else:
			return_to_pool()

func _on_screen_exited() -> void:
	if not _pool_active:
		return
	_cleanup_if_outside_bounds()
