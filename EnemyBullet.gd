extends Area2D

var speed: float = 320.0
var direction: Vector2 = Vector2.RIGHT
var _pool_active := true
var _use_external_update := false
var _visual_only := false
var _off_camera_timer: float = 0.0
var _off_camera_check_accum: float = 0.0

const OFF_CAMERA_DESTROY_TIME := 1.0
const OFF_CAMERA_CHECK_INTERVAL := 0.2

const PLAYER_RADIUS := 22.0
const DAMAGE        := 5

@onready var _collision_shape: CollisionShape2D = $CollisionShape2D

func _draw() -> void:
	# 橙红色敌方子弹
	draw_circle(Vector2.ZERO, 5.5, Color(1.0, 0.48, 0.08, 0.95), true, -1.0, true)
	draw_circle(Vector2.ZERO, 5.5, Color(0.75, 0.25, 0.0, 1.0), false, 1.2, true)
	draw_circle(Vector2(-1.5, -1.8), 2.2, Color(1.0, 0.9, 0.5, 0.45), true, -1.0, true)

func _process(delta: float) -> void:
	if _use_external_update:
		return
	advance_projectile(delta)

func advance_projectile(delta: float) -> void:
	if not _pool_active:
		return
	position += direction * speed * delta
	if _visual_only:
		_cleanup_if_outside_bounds()
		return
	var scene: Node = get_tree().current_scene
	var target: Node2D = scene.get_player_hit_target(global_position, PLAYER_RADIUS) if scene and scene.has_method("get_player_hit_target") else null
	if target != null:
		if target.has_method("register_body_hit"):
			target.register_body_hit(global_position)
		var target_peer_id: int = scene.get_player_peer_id(target) if scene and scene.has_method("get_player_peer_id") else 1
		scene.take_damage(DAMAGE, target_peer_id)
		return_to_pool()
		return
	_cleanup_if_outside_bounds()
	if _pool_active:
		_update_off_camera_timer(delta)

func is_pool_active() -> bool:
	return _pool_active

func _update_off_camera_timer(delta: float) -> void:
	_off_camera_check_accum += delta
	if _off_camera_check_accum < OFF_CAMERA_CHECK_INTERVAL:
		return
	_off_camera_check_accum = 0.0
	var viewport := get_viewport()
	if viewport == null:
		return
	var screen_pos := viewport.get_canvas_transform() * global_position
	var vp_size := viewport.get_visible_rect().size
	var margin := 60.0
	var on_camera := screen_pos.x >= -margin and screen_pos.y >= -margin \
		and screen_pos.x <= vp_size.x + margin and screen_pos.y <= vp_size.y + margin
	if on_camera:
		_off_camera_timer = 0.0
	else:
		_off_camera_timer += OFF_CAMERA_CHECK_INTERVAL
		if _off_camera_timer >= OFF_CAMERA_DESTROY_TIME:
			return_to_pool()

func activate_from_pool(spawn_position: Vector2, spawn_direction: Vector2, spawn_speed: float, visual_only: bool = false) -> void:
	_pool_active = true
	_off_camera_timer = 0.0
	_off_camera_check_accum = 0.0
	global_position = spawn_position
	direction = spawn_direction
	speed = spawn_speed
	_visual_only = visual_only
	visible = true
	var scene = get_tree().current_scene
	_use_external_update = scene != null and scene.has_method("register_enemy_bullet")
	set_process(not _use_external_update)
	if _use_external_update:
		scene.register_enemy_bullet(self)
	monitoring = false
	monitorable = false
	# 敌方子弹命中玩家走手写距离判定，不参与 2D 碰撞广相。
	_collision_shape.disabled = true

func return_to_pool() -> void:
	if not _pool_active:
		return
	_pool_active = false
	visible = false
	set_process(false)
	_use_external_update = false
	_visual_only = false
	global_position = Vector2(-10000.0, -10000.0)
	var scene = get_tree().current_scene
	if scene and scene.has_method("release_enemy_bullet"):
		scene.release_enemy_bullet(self)
	else:
		queue_free()

func deactivate_to_pool() -> void:
	_pool_active = false
	_off_camera_timer = 0.0
	_off_camera_check_accum = 0.0
	direction = Vector2.RIGHT
	visible = false
	set_process(false)
	_use_external_update = false
	_visual_only = false
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
