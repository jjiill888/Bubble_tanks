extends Area2D

var speed: float = 320.0
var direction: Vector2 = Vector2.RIGHT
var _pool_active := true

const PLAYER_RADIUS := 22.0
const DAMAGE        := 5

@onready var _collision_shape: CollisionShape2D = $CollisionShape2D

func _draw() -> void:
	# 橙红色敌方子弹
	draw_circle(Vector2.ZERO, 5.5, Color(1.0, 0.48, 0.08, 0.95), true, -1.0, true)
	draw_circle(Vector2.ZERO, 5.5, Color(0.75, 0.25, 0.0, 1.0), false, 1.2, true)
	draw_circle(Vector2(-1.5, -1.8), 2.2, Color(1.0, 0.9, 0.5, 0.45), true, -1.0, true)

func _process(delta: float) -> void:
	if not _pool_active:
		return
	position += direction * speed * delta
	var scene: Node = get_tree().current_scene
	var target: Vector2 = scene.get_player_position() if scene and scene.has_method("get_player_position") else get_viewport_rect().size * 0.5
	if global_position.distance_squared_to(target) < PLAYER_RADIUS * PLAYER_RADIUS:
		scene.take_damage(DAMAGE)
		return_to_pool()
		return
	_cleanup_if_outside_bounds()

func activate_from_pool(spawn_position: Vector2, spawn_direction: Vector2, spawn_speed: float) -> void:
	_pool_active = true
	global_position = spawn_position
	direction = spawn_direction
	speed = spawn_speed
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
	if scene and scene.has_method("release_enemy_bullet"):
		scene.release_enemy_bullet(self)
	else:
		queue_free()

func deactivate_to_pool() -> void:
	_pool_active = false
	direction = Vector2.RIGHT
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

func _on_screen_exited() -> void:
	if not _pool_active:
		return
	_cleanup_if_outside_bounds()
