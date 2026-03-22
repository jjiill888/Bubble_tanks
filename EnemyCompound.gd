extends Area2D

@export var speed: float = 75.0

# 大泡泡
const MED_POS      := Vector2(0.0, -4.0)
const MED_R        := 26.0
const MED_NUC_OFF  := Vector2(-7.0, -9.0)
const MED_NUC_R    := 9.5
# 小泡泡（两侧）
const SM_R         := 15.0
const SM_LEFT      := Vector2(-23.0, 13.0)
const SM_RIGHT     := Vector2(23.0, 13.0)

var left_alive  := true
var right_alive := true
var big_damaged := false  # 大泡泡受到第一击后变色

func _ready() -> void:
	add_to_group("compound_enemy")

func _draw_small(center: Vector2) -> void:
	draw_circle(center, SM_R, Color(1.0, 0.22, 0.22, 0.68), true, -1.0, true)
	draw_circle(center, SM_R, Color(0.85, 0.06, 0.06, 0.82), false, 1.5, true)
	draw_circle(center + Vector2(4.5, -5.5), 4.0, Color(1.0, 1.0, 1.0, 0.2), true, -1.0, true)

func _draw() -> void:
	# 小泡泡（存活时才画）
	if left_alive:
		_draw_small(SM_LEFT)
	if right_alive:
		_draw_small(SM_RIGHT)
	# 大泡泡主体（受伤后变橙色）
	var bubble_color := Color(1.0, 0.45, 0.1, 0.75) if big_damaged else Color(1.0, 0.22, 0.22, 0.75)
	draw_circle(MED_POS, MED_R, bubble_color, true, -1.0, true)
	# 大泡泡细胞膜
	draw_circle(MED_POS, MED_R, Color(0.85, 0.06, 0.06, 0.9), false, 2.2, true)
	# 细胞核
	var nuc = MED_POS + MED_NUC_OFF
	draw_circle(nuc, MED_NUC_R, Color(0.52, 0.04, 0.04, 0.95), true, -1.0, true)
	draw_circle(nuc, MED_NUC_R, Color(0.32, 0.0, 0.0, 0.85), false, 1.5, true)
	# 大泡泡高光
	draw_circle(MED_POS + Vector2(9.0, -11.0), 6.5, Color(1.0, 1.0, 1.0, 0.24), true, -1.0, true)
	draw_circle(MED_POS + Vector2(10.5, -12.5), 3.5, Color(1.0, 1.0, 1.0, 0.14), true, -1.0, true)

func _process(delta: float) -> void:
	var scene: Node = get_tree().current_scene
	var target: Vector2 = scene.get_player_position() if scene and scene.has_method("get_player_position") else get_viewport_rect().size * 0.5
	var to_target: Vector2 = target - global_position
	if to_target.length_squared() < 30.0 * 30.0:
		scene.take_damage(8)
		queue_free()
		return
	global_position += to_target.normalized() * speed * delta
	_cleanup_if_outside_bounds()

func _cleanup_if_outside_bounds() -> void:
	var scene = get_tree().current_scene
	if scene and scene.has_method("is_outside_cleanup_bounds") and scene.is_outside_cleanup_bounds(global_position, 220.0):
		queue_free()

# 大泡泡被打中但未消灭（第一击）
func on_bubble_damaged(bubble: Area2D) -> void:
	if bubble.name == "BigBubble":
		big_damaged = true
		queue_redraw()

# 某个泡泡被消灭（HP归零）
func on_bubble_destroyed(bubble: Area2D) -> void:
	match bubble.name:
		"SmallBubbleLeft":
			left_alive = false
			queue_redraw()
		"SmallBubbleRight":
			right_alive = false
			queue_redraw()
		"BigBubble":
			var scene := get_tree().current_scene
			scene.add_score(2)
			if scene and scene.has_method("play_enemy_death_sfx"):
				scene.play_enemy_death_sfx()
			queue_free()

func _on_screen_exited() -> void:
	_cleanup_if_outside_bounds()
