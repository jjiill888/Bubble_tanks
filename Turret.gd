extends Node2D

@export var bullet_scene: PackedScene
@export var fire_cooldown: float = 0.15
@export var move_speed: float = 200.0
@export var is_local_player := true
@export var player_color_key := "blue"
@export var network_peer_id := 1
@export var preview_mode := false

const DASH_DISTANCE    := 160.0   # 约两个小敌人宽度
const DASH_COOLDOWN    := 3.0     # 秒
const BUBBLES_PER_LEVEL := 8      # 攒齐后升级
const FIRE_SFX := preload("res://universfield-bubble-pop-06-351337.mp3")
const PlayerPaletteRef := preload("res://PlayerPalette.gd")

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
var _palette: Dictionary = {}
var _direct_input_enabled := true
var _network_target_position := Vector2.ZERO
var _network_target_rotation := 0.0
var _has_network_target := false
var _network_position_error := Vector2.ZERO
var _network_rotation_error := 0.0
var _is_eliminated := false

func _ready() -> void:
	_palette = PlayerPaletteRef.get_palette(player_color_key)
	if preview_mode:
		queue_redraw()
		return
	add_to_group("player")
	_setup_fire_sfx_player()
	if is_local_player:
		_setup_dash_label()
	var scene := get_tree().current_scene
	if scene and scene.has_method("register_player"):
		scene.register_player(self)

func _exit_tree() -> void:
	if preview_mode:
		return
	var scene := get_tree().current_scene
	if scene and scene.has_method("unregister_player"):
		scene.unregister_player(self)

func configure_player(color_key: String, local_control: bool, direct_input_enabled: bool = true) -> void:
	player_color_key = color_key
	is_local_player = local_control
	_direct_input_enabled = direct_input_enabled
	_is_eliminated = false
	_palette = PlayerPaletteRef.get_palette(player_color_key)
	modulate = Color(1.0, 1.0, 1.0, 1.0)
	queue_redraw()
	if preview_mode:
		return
	if _dash_label != null:
		_dash_label.visible = is_local_player

func set_network_peer_id(peer_id: int) -> void:
	network_peer_id = peer_id

func get_network_peer_id() -> int:
	return network_peer_id

func set_direct_input_enabled(enabled: bool) -> void:
	_direct_input_enabled = enabled

func set_eliminated(eliminated: bool) -> void:
	_is_eliminated = eliminated
	if eliminated:
		_direct_input_enabled = false
		can_fire = false
		_fire_cd_remaining = 0.0
		modulate = Color(0.7, 0.7, 0.7, 0.45)
	else:
		modulate = Color(1.0, 1.0, 1.0, 1.0)
	if _dash_label != null:
		_dash_label.visible = is_local_player and not eliminated

func is_eliminated() -> bool:
	return _is_eliminated

func get_player_color_key() -> String:
	return player_color_key

func get_dash_cooldown() -> float:
	return _dash_cd

func is_ready_to_fire() -> bool:
	return can_fire

func build_input_state() -> Dictionary:
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
		dir = dir.normalized()
	var aim_angle := rotation
	var mouse_delta := get_global_mouse_position() - global_position
	if mouse_delta.length_squared() > 0.0001:
		aim_angle = mouse_delta.angle()
	return {
		"move_x": dir.x,
		"move_y": dir.y,
		"aim_angle": aim_angle,
		"firing": Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT),
		"dash_pressed": Input.is_action_just_pressed("ui_accept"),
	}

func apply_input_state(input_state: Dictionary, delta: float) -> void:
	if _is_eliminated:
		return
	var dir := Vector2(
		float(input_state.get("move_x", 0.0)),
		float(input_state.get("move_y", 0.0))
	)
	if dir != Vector2.ZERO:
		global_position += dir.normalized() * move_speed * delta
		var vp := get_viewport_rect()
		global_position = global_position.clamp(Vector2.ZERO, vp.size)

	rotation = float(input_state.get("aim_angle", rotation))

	if _dash_cd > 0.0:
		_dash_cd -= delta
		if _dash_cd < 0.0:
			_dash_cd = 0.0
		if is_local_player:
			_refresh_dash_label()

	if not can_fire:
		_fire_cd_remaining -= delta
		if _fire_cd_remaining <= 0.0:
			_fire_cd_remaining = 0.0
			can_fire = true

	if bool(input_state.get("dash_pressed", false)) and _dash_cd <= 0.0:
		var dash_dir = Vector2.RIGHT.rotated(rotation)
		global_position += dash_dir * DASH_DISTANCE
		var vp := get_viewport_rect()
		global_position = global_position.clamp(Vector2.ZERO, vp.size)
		_dash_cd = DASH_COOLDOWN
		if is_local_player:
			_refresh_dash_label()

	if bool(input_state.get("firing", false)):
		fire()

func apply_authoritative_state(position: Vector2, aim_rotation: float) -> void:
	if is_local_player:
		_network_position_error = position - global_position
		_network_rotation_error = wrapf(aim_rotation - rotation, -PI, PI)
	_network_target_position = position
	_network_target_rotation = aim_rotation
	if not _has_network_target:
		global_position = position
		rotation = aim_rotation
	_has_network_target = true

func tick_network_interpolation(delta: float) -> void:
	if is_local_player:
		if _network_position_error.length_squared() > 0.0001:
			var error_blend: float = min(1.0, delta * 12.0)
			global_position += _network_position_error * error_blend
			_network_position_error = _network_position_error.lerp(Vector2.ZERO, error_blend)
		if absf(_network_rotation_error) > 0.0001:
			var rotation_error_blend: float = min(1.0, delta * 14.0)
			rotation += _network_rotation_error * rotation_error_blend
			_network_rotation_error = lerpf(_network_rotation_error, 0.0, rotation_error_blend)
		return
	if not _has_network_target:
		return
	var position_blend: float = min(1.0, delta * (8.0 if is_local_player else 14.0))
	var rotation_blend: float = min(1.0, delta * (10.0 if is_local_player else 16.0))
	var dist_sq: float = global_position.distance_squared_to(_network_target_position)
	if dist_sq > 220.0 * 220.0:
		global_position = _network_target_position
	else:
		global_position = global_position.lerp(_network_target_position, position_blend)
	rotation = lerp_angle(rotation, _network_target_rotation, rotation_blend)

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

func ensure_skill_stack(id: String, target_stack: int) -> void:
	var clamped_target := maxi(target_stack, 0)
	while acquired_skills.count(id) < clamped_target:
		if not acquire_skill(id):
			break

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
	draw_rect(Rect2(0, -5, 40, 10), _palette["barrel_main"], true)
	draw_rect(Rect2(0, -5, 40, 10), _palette["barrel_rim"], false, 1.5)
	# 炮口
	draw_circle(Vector2(40, 0), 5.5, _palette["muzzle_main"], true, -1.0, true)
	draw_circle(Vector2(40, 0), 5.5, _palette["muzzle_rim"], false, 1.2, true)
	# 底座 - 浅蓝色
	draw_circle(Vector2.ZERO, 20.0, _palette["turret_body"], true, -1.0, true)
	draw_circle(Vector2.ZERO, 20.0, _palette["turret_body_rim"], false, 2.5, true)
	# 内环装饰
	draw_circle(Vector2.ZERO, 12.0, _palette["turret_ring"], false, 1.2, true)
	# 中心点
	draw_circle(Vector2.ZERO, 4.5, _palette["turret_core"], true, -1.0, true)
	# 高光
	draw_circle(Vector2(-6.0, -8.0), 5.0, _palette["turret_highlight"], true, -1.0, true)

func _process(delta: float) -> void:
	if not is_local_player or not _direct_input_enabled:
		return
	apply_input_state(build_input_state(), delta)

func fire() -> void:
	if _is_eliminated or not can_fire or bullet_scene == null:
		return
	can_fire = false
	_fire_cd_remaining = fire_cooldown
	var scene := get_tree().current_scene
	var total := 1 + extra_bullets
	var spread := deg_to_rad(SPREAD_ANGLE)
	var visual_only: bool = scene != null and scene.has_method("is_client_network_mode") and scene.is_client_network_mode()
	for i in range(total):
		# 以瞄准方向为中轴，均匀分布扇形角度
		var offset := (i - (total - 1) / 2.0) * spread
		var bullet: Area2D = scene.acquire_player_bullet() if scene and scene.has_method("acquire_player_bullet") else bullet_scene.instantiate()
		if bullet.get_parent() == null:
			scene.get_node("Bullets").add_child(bullet)
		if bullet.has_method("activate_from_pool"):
			bullet.activate_from_pool($Muzzle.global_position, rotation + offset, _surfactant_pierce_hits(), player_color_key, visual_only)
		else:
			bullet.global_position = $Muzzle.global_position
			bullet.rotation = rotation + offset
			bullet.pierce_hits_remaining = _surfactant_pierce_hits()
			if bullet.has_method("set_color_key"):
				bullet.set_color_key(player_color_key)
	if scene and scene.has_method("notify_player_fire"):
		scene.notify_player_fire(
			get_network_peer_id(),
			$Muzzle.global_position,
			rotation,
			total,
			_surfactant_pierce_hits(),
			player_color_key
		)
	_play_fire_sfx()
