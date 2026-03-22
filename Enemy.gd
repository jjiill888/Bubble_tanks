extends Area2D

@export var speed: float = 120.0

const RADIUS       := 20.0
const NUC_OFFSET   := Vector2(-5.0, -4.0)
const NUC_RADIUS   := 7.0
const HL_OFFSET    := Vector2(7.0, -8.0)
const HL_RADIUS    := 5.5

func _ready() -> void:
	add_to_group("enemy")

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
	var scene: Node = get_tree().current_scene
	var target: Vector2 = scene.get_player_position() if scene and scene.has_method("get_player_position") else get_viewport_rect().size * 0.5
	var to_target: Vector2 = target - global_position
	if to_target.length_squared() < 22.0 * 22.0:
		scene.take_damage(5)
		queue_free()
		return
	global_position += to_target.normalized() * speed * delta
	_cleanup_if_outside_bounds()

func _cleanup_if_outside_bounds() -> void:
	var scene = get_tree().current_scene
	if scene and scene.has_method("is_outside_cleanup_bounds") and scene.is_outside_cleanup_bounds(global_position, 180.0):
		queue_free()

func die() -> void:
	var scene := get_tree().current_scene
	get_tree().current_scene.add_score(1)
	if scene and scene.has_method("play_enemy_death_sfx"):
		scene.play_enemy_death_sfx()
	queue_free()

func _on_screen_exited() -> void:
	_cleanup_if_outside_bounds()
