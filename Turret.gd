extends Node2D

@export var bullet_scene: PackedScene
@export var fire_cooldown: float = 0.15
@export var move_speed: float = 200.0

const DASH_DISTANCE    := 160.0   # 约两个小敌人宽度
const DASH_COOLDOWN    := 3.0     # 秒
const BUBBLES_PER_LEVEL := 8      # 攒齐后升级
const FIRE_SFX := preload("res://universfield-bubble-pop-06-351337.mp3")

# ── 运行状态 ────────────────────────────────────────────────────────────────
var can_fire := true
var _dash_cd: float = 0.0
var _dash_label: Label = null
var _fire_cd_remaining: float = 0.0
var _fire_sfx_player: AudioStreamPlayer = null

# ── 技能 ────────────────────────────────────────────────────────────────────
var acquired_skills: Array = []   # Array[String] 已拥有的技能 id
var surfactant_level: int = 0     # 表面活性剂层数，决定可连续击破的泡泡数
var extra_bullets: int = 0        # 尿尿分叉+1：额外散射子弹数
const SPREAD_ANGLE := 18.0        # 每发子弹之间的扇形间距（度）

# ── Boss 泡泡积累（视觉） ────────────────────────────────────────────────────
var boss_bubble_count: int = 0    # 由 Main 通过 set_boss_bubbles() 设置

func _ready() -> void:
	add_to_group("player")
	_setup_fire_sfx_player()
	_setup_dash_label()

func _setup_fire_sfx_player() -> void:
	_fire_sfx_player = AudioStreamPlayer.new()
	_fire_sfx_player.name = "FireSfx"
	_fire_sfx_player.stream = FIRE_SFX
	_fire_sfx_player.bus = &"Master"
	_fire_sfx_player.volume_db = -8.0
	_fire_sfx_player.max_polyphony = 6
	add_child(_fire_sfx_player)

func _play_fire_sfx() -> void:
	if _fire_sfx_player == null:
		return
	_fire_sfx_player.play()

## 由 Main 调用，更新环绕泡泡数量并重绘
func set_boss_bubbles(n: int) -> void:
	boss_bubble_count = n
	queue_redraw()

## 获得一个技能，立即应用效果
func acquire_skill(id: String) -> bool:
	if not SkillRegistry.can_acquire(id, acquired_skills):
		return false
	acquired_skills.append(id)
	match id:
		"surfactant":
			surfactant_level += 1
		"red_bull":
			fire_cooldown = fire_cooldown * 0.9   # 每层 +10% 射速，叠 5 层后约为原来的 59%
		"spread":
			extra_bullets += 1
	return true

func _surfactant_pierce_hits() -> int:
	if surfactant_level <= 0:
		return 0
	return surfactant_level * 2 - 1

func _setup_dash_label() -> void:
	var canvas = get_tree().current_scene.get_node("CanvasLayer")
	_dash_label = Label.new()
	_dash_label.name = "DashLabel"
	# 锚定右上角
	_dash_label.anchor_left   = 1.0
	_dash_label.anchor_right  = 1.0
	_dash_label.anchor_top    = 0.0
	_dash_label.anchor_bottom = 0.0
	_dash_label.offset_left   = -180.0
	_dash_label.offset_right  = -10.0
	_dash_label.offset_top    = 20.0
	_dash_label.offset_bottom = 60.0
	_dash_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_dash_label.add_theme_font_size_override("font_size", 22)
	_dash_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.7))
	_dash_label.add_theme_constant_override("shadow_offset_x", 2)
	_dash_label.add_theme_constant_override("shadow_offset_y", 2)
	canvas.add_child(_dash_label)
	_refresh_dash_label()

func _refresh_dash_label() -> void:
	if _dash_label == null:
		return
	if _dash_cd <= 0.0:
		_dash_label.text = "冲刺 就绪"
		_dash_label.add_theme_color_override("font_color", Color(0.4, 1.0, 0.45, 1.0))
	else:
		_dash_label.text = "冲刺 %.1f s" % _dash_cd
		_dash_label.add_theme_color_override("font_color", Color(1.0, 0.85, 0.2, 1.0))

func _draw() -> void:
	# ── 环绕 Boss 泡泡（不随炮塔旋转）──────────────────────────────────────
	if boss_bubble_count > 0:
		# 反向旋转，使泡泡在世界坐标中保持固定方位
		draw_set_transform(Vector2.ZERO, -rotation)
		for i in range(boss_bubble_count):
			var angle := TAU * i / BUBBLES_PER_LEVEL
			var bpos  := Vector2.RIGHT.rotated(angle) * 36.0
			draw_circle(bpos, 6.5, Color(1.0, 0.55, 0.10, 0.85), true, -1.0, true)
			draw_circle(bpos, 6.5, Color(0.80, 0.28, 0.0, 0.92), false, 1.4, true)
			draw_circle(bpos + Vector2(-1.5, -2.0), 2.2,
					Color(1.0, 1.0, 1.0, 0.32), true, -1.0, true)
		draw_set_transform(Vector2.ZERO, 0.0)   # 恢复旋转

	# 炮管（先画，在底座下面）
	draw_rect(Rect2(0, -5, 40, 10), Color(0.35, 0.72, 0.95, 1.0), true)
	draw_rect(Rect2(0, -5, 40, 10), Color(0.2, 0.55, 0.85, 1.0), false, 1.5)
	# 炮口
	draw_circle(Vector2(40, 0), 5.5, Color(0.25, 0.65, 0.9, 1.0), true, -1.0, true)
	draw_circle(Vector2(40, 0), 5.5, Color(0.15, 0.5, 0.8, 1.0), false, 1.2, true)
	# 底座 - 浅蓝色
	draw_circle(Vector2.ZERO, 20.0, Color(0.55, 0.83, 1.0, 1.0), true, -1.0, true)
	draw_circle(Vector2.ZERO, 20.0, Color(0.2, 0.6, 0.92, 1.0), false, 2.5, true)
	# 内环装饰
	draw_circle(Vector2.ZERO, 12.0, Color(0.35, 0.72, 0.97, 0.55), false, 1.2, true)
	# 中心点
	draw_circle(Vector2.ZERO, 4.5, Color(0.15, 0.55, 0.9, 1.0), true, -1.0, true)
	# 高光
	draw_circle(Vector2(-6.0, -8.0), 5.0, Color(1.0, 1.0, 1.0, 0.28), true, -1.0, true)

func _process(delta: float) -> void:
	# WASD 移动
	var dir := Vector2.ZERO
	if Input.is_key_pressed(KEY_W):
		dir.y -= 1
	if Input.is_key_pressed(KEY_S):
		dir.y += 1
	if Input.is_key_pressed(KEY_A):
		dir.x -= 1
	if Input.is_key_pressed(KEY_D):
		dir.x += 1
	if dir != Vector2.ZERO:
		global_position += dir.normalized() * move_speed * delta
		var vp := get_viewport_rect()
		global_position = global_position.clamp(Vector2.ZERO, vp.size)

	look_at(get_global_mouse_position())

	# 冲刺冷却倒计时
	if _dash_cd > 0.0:
		_dash_cd -= delta
		if _dash_cd < 0.0:
			_dash_cd = 0.0
		_refresh_dash_label()

	if not can_fire:
		_fire_cd_remaining -= delta
		if _fire_cd_remaining <= 0.0:
			_fire_cd_remaining = 0.0
			can_fire = true

	# 冲刺触发（空格）
	if Input.is_action_just_pressed("ui_accept") and _dash_cd <= 0.0:
		var dash_dir = Vector2.RIGHT.rotated(rotation)
		global_position += dash_dir * DASH_DISTANCE
		var vp := get_viewport_rect()
		global_position = global_position.clamp(Vector2.ZERO, vp.size)
		_dash_cd = DASH_COOLDOWN
		_refresh_dash_label()

	if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		fire()

func fire() -> void:
	if not can_fire or bullet_scene == null:
		return
	can_fire = false
	_fire_cd_remaining = fire_cooldown
	var scene := get_tree().current_scene
	var total := 1 + extra_bullets
	var spread := deg_to_rad(SPREAD_ANGLE)
	for i in range(total):
		# 以瞄准方向为中轴，均匀分布扇形角度
		var offset := (i - (total - 1) / 2.0) * spread
		var bullet: Area2D = scene.acquire_player_bullet() if scene and scene.has_method("acquire_player_bullet") else bullet_scene.instantiate()
		if bullet.get_parent() == null:
			scene.get_node("Bullets").add_child(bullet)
		if bullet.has_method("activate_from_pool"):
			bullet.activate_from_pool($Muzzle.global_position, rotation + offset, _surfactant_pierce_hits())
		else:
			bullet.global_position = $Muzzle.global_position
			bullet.rotation = rotation + offset
			bullet.pierce_hits_remaining = _surfactant_pierce_hits()
	_play_fire_sfx()
