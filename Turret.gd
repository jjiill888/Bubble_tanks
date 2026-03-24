extends Node2D

@export var bullet_scene: PackedScene
@export var fire_cooldown: float = 0.20
@export var move_speed: float = 200.0
@export var is_local_player := true
@export var player_color_key := "blue"
@export var network_peer_id := 1
@export var preview_mode := false

const DASH_DISTANCE    := 160.0   # 约两个小敌人宽度
const DASH_COOLDOWN    := 3.0     # 秒
const FIRE_SFX := preload("res://universfield-bubble-pop-06-351337.mp3")
const PlayerPaletteRef := preload("res://PlayerPalette.gd")
const BASE_BODY_RADIUS := 20.0
const BODY_GROWTH_PER_LEVEL := 0.65
const CAMERA_ZOOM_REDUCTION_PER_LEVEL := 0.045
const MAX_CAMERA_ZOOM_OUT := 0.62
const FIRST_RING_MIN_BUBBLES := 5
const FIRST_RING_MAX_BUBBLES := 9
const LATER_RING_MIN_BUBBLES := 4
const LATER_RING_MAX_BUBBLES := 7
const FIRST_RING_RADIUS_SCALE_MIN := 0.24
const FIRST_RING_RADIUS_SCALE_MAX := 0.34
const LATER_RING_RADIUS_SCALE_MIN := 0.18
const LATER_RING_RADIUS_SCALE_MAX := 0.28
const SHELL_COLLISION_RADIUS_SCALE := 0.74
const CORE_COLLISION_RADIUS_SCALE := 0.86
const BODY_HIT_SCORE_DISTANCE := 240.0
const BODY_TURN_SPEED := 5.6
const TURRET_TURN_SPEED := 11.5
const TURRET_MAX_AIM_OFFSET := 1.18
const SHELL_HP_STEP := 10.0
const ANTIBODY_BASE_COOLDOWN := 1.4
const ANTIBODY_FAST_COOLDOWN := 1.02
const ANTIBODY_BURST_COUNT := 1
const ANTIBODY_BURST_SPREAD := 0.26
const ANTIBODY_BURST_LATERAL_SPACING := 5.5

# ── 运行状态 ────────────────────────────────────────────────────────────────
var can_fire := true
var _dash_cd: float = 0.0
var _dash_label: Label = null
var _fire_cd_remaining: float = 0.0
var _missile_cd_remaining: float = 0.0
var _fire_sfx_player: AudioStreamPlayer = null
var _base_fire_cooldown: float = 0.20

# ── 技能 ────────────────────────────────────────────────────────────────────
var acquired_skills: Array = []   # Array[String] 已拥有的技能 id
var surfactant_level: int = 0     # 表面活性剂层数，决定可连续击破的泡泡数
var extra_bullets: int = 0        # 尿尿分叉+1：额外散射子弹数
var vampirism_level: int = 0
var vitality_level: int = 0
var antibody_level: int = 0
const SPREAD_ANGLE := 18.0        # 每发子弹之间的扇形间距（度）

var _palette: Dictionary = {}
var _direct_input_enabled := true
var _network_target_position := Vector2.ZERO
var _network_target_rotation := 0.0
var _has_network_target := false
var _network_position_error := Vector2.ZERO
var _network_rotation_error := 0.0
var _is_eliminated := false
var _progression_level := 0
var _target_growth_scale := 1.0
var _display_growth_scale := 1.0
var _target_camera_zoom := Vector2.ONE
var _body_bubbles: Array[Dictionary] = []
var _arena_size := Vector2(1920.0, 1080.0)
var _visual_hp: int = 100
var _visual_max_hp: int = 100
var _broken_shell_count: int = 0
var _pending_hit_local := Vector2.ZERO
var _has_pending_hit := false
var _pending_hit_shell_index: int = -1
var _pending_hit_is_shell := false
var _aim_world_rotation := 0.0
var _turret_angles: Array[float] = []

@onready var _camera: Camera2D = $Camera2D

func _use_ascii_ui() -> bool:
	return OS.has_feature("web")

func _ready() -> void:
	_base_fire_cooldown = fire_cooldown
	_palette = PlayerPaletteRef.get_palette(player_color_key)
	_rebuild_growth_layout()
	set_health_visual_state(_visual_hp, _visual_max_hp)
	if preview_mode:
		queue_redraw()
		return
	add_to_group("player")
	_setup_fire_sfx_player()
	if is_local_player:
		_setup_dash_label()
	if _camera != null:
		_camera.enabled = is_local_player
		_camera.position_smoothing_enabled = true
		_camera.position_smoothing_speed = 6.0
		_update_camera_limits()
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
	_visual_hp = 100
	_visual_max_hp = 100
	_broken_shell_count = 0
	_has_pending_hit = false
	_pending_hit_shell_index = -1
	_pending_hit_is_shell = false
	_aim_world_rotation = rotation
	_turret_angles.clear()
	_rebuild_growth_layout()
	set_health_visual_state(_visual_hp, _visual_max_hp)
	modulate = Color(1.0, 1.0, 1.0, 1.0)
	queue_redraw()
	if preview_mode:
		return
	if _dash_label != null:
		_dash_label.visible = is_local_player
	if _camera != null:
		_camera.enabled = is_local_player
		_update_camera_limits()

func build_visual_snapshot() -> Dictionary:
	return {
		"color_key": player_color_key,
		"level": _progression_level,
		"skills": acquired_skills.duplicate(true),
	}

func apply_visual_snapshot(snapshot: Dictionary) -> void:
	player_color_key = String(snapshot.get("color_key", player_color_key))
	_palette = PlayerPaletteRef.get_palette(player_color_key)
	acquired_skills = Array(snapshot.get("skills", [])).duplicate(true)
	_recalculate_skill_state_from_acquired()
	_progression_level = maxi(int(snapshot.get("level", _progression_level)), 0)
	_rebuild_growth_layout()
	_apply_shell_visibility()
	queue_redraw()

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

func set_progression_state(level: int, arena_size: Vector2) -> void:
	_progression_level = maxi(level, 0)
	_arena_size = arena_size
	_target_growth_scale = 1.0 + float(_progression_level) * 0.085
	var zoom_scalar := maxf(MAX_CAMERA_ZOOM_OUT, 1.0 - float(_progression_level) * CAMERA_ZOOM_REDUCTION_PER_LEVEL)
	_target_camera_zoom = Vector2.ONE * zoom_scalar
	_rebuild_growth_layout()
	_apply_shell_visibility()
	_update_camera_limits()
	queue_redraw()

func set_health_visual_state(current_hp: int, current_max_hp: int) -> void:
	var previous_hp := _visual_hp
	_visual_max_hp = maxi(current_max_hp, 1)
	_visual_hp = clampi(current_hp, 0, _visual_max_hp)
	if _visual_hp < previous_hp and _pending_hit_is_shell:
		_broken_shell_count += _shell_delta_to_bubbles(previous_hp - _visual_hp)
	elif _visual_hp > previous_hp and _broken_shell_count > 0:
		_broken_shell_count = maxi(_broken_shell_count - _shell_delta_to_bubbles(_visual_hp - previous_hp), 0)
	if _visual_hp >= _visual_max_hp:
		_broken_shell_count = 0
	_apply_shell_visibility()

func register_body_hit(global_hit_position: Vector2) -> void:
	_pending_hit_local = to_local(global_hit_position)
	_has_pending_hit = true
	_pending_hit_shell_index = _find_nearest_visible_bubble_index(_pending_hit_local)
	_pending_hit_is_shell = _pending_hit_shell_index >= 0 and bool(_body_bubbles[_pending_hit_shell_index].get("shell", false))

func is_pending_shell_hit() -> bool:
	return _pending_hit_is_shell

func get_body_hit_distance_sq(from_position: Vector2, radius: float) -> float:
	var local_position := to_local(from_position)
	var best_dist_sq := INF
	for bubble in _body_bubbles:
		if not bool(bubble.get("visible", true)):
			continue
		var center: Vector2 = bubble.get("center", Vector2.ZERO) * _display_growth_scale
		var collision_scale := SHELL_COLLISION_RADIUS_SCALE if bool(bubble.get("shell", false)) else CORE_COLLISION_RADIUS_SCALE
		var bubble_radius: float = float(bubble.get("radius", BASE_BODY_RADIUS)) * _display_growth_scale * collision_scale
		var reach := bubble_radius + radius
		var dist_sq := center.distance_squared_to(local_position)
		if dist_sq <= reach * reach and dist_sq < best_dist_sq:
			best_dist_sq = dist_sq
	return best_dist_sq

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
		"firing": Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) or Input.is_key_pressed(KEY_J),
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
		var scene := get_tree().current_scene
		var arena: Vector2 = get_viewport_rect().size
		if scene and scene.has_method("get_active_arena_size"):
			arena = scene.get_active_arena_size()
		var margin := _current_body_extent()
		global_position = global_position.clamp(Vector2(margin, margin), arena - Vector2(margin, margin))

	_aim_world_rotation = float(input_state.get("aim_angle", _aim_world_rotation))
	var body_turn_blend: float = min(1.0, delta * BODY_TURN_SPEED)
	rotation = lerp_angle(rotation, _aim_world_rotation, body_turn_blend)

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
	if _missile_cd_remaining > 0.0:
		_missile_cd_remaining = maxf(_missile_cd_remaining - delta, 0.0)

	if bool(input_state.get("dash_pressed", false)) and _dash_cd <= 0.0:
		var dash_dir = Vector2.RIGHT.rotated(rotation)
		global_position += dash_dir * DASH_DISTANCE
		var dash_scene := get_tree().current_scene
		var dash_arena: Vector2 = get_viewport_rect().size
		if dash_scene and dash_scene.has_method("get_active_arena_size"):
			dash_arena = dash_scene.get_active_arena_size()
		var dash_margin := _current_body_extent()
		global_position = global_position.clamp(Vector2(dash_margin, dash_margin), dash_arena - Vector2(dash_margin, dash_margin))
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
		_aim_world_rotation = aim_rotation
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
	_aim_world_rotation = _network_target_rotation

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

## 获得一个技能，立即应用效果
func acquire_skill(id: String) -> bool:
	if not SkillRegistry.can_acquire(id, acquired_skills):
		return false
	acquired_skills.append(id)
	if id == "vitality":
		var scene := get_tree().current_scene
		if scene and scene.has_method("increase_player_max_hp"):
			scene.increase_player_max_hp(get_network_peer_id(), 20, 20)
	_recalculate_skill_state_from_acquired()
	_rebuild_growth_layout()
	_apply_shell_visibility()
	queue_redraw()
	return true

func get_lifesteal_heal_amount(enemy_kind: String) -> int:
	if vampirism_level <= 0:
		return 0
	match enemy_kind:
		"compound", "tank":
			return vampirism_level * 3
		"missile":
			return vampirism_level * 2
		"basic":
			return vampirism_level
		_:
			return 0

func ensure_skill_stack(id: String, target_stack: int) -> void:
	var clamped_target := maxi(target_stack, 0)
	while acquired_skills.count(id) < clamped_target:
		if not acquire_skill(id):
			break

func _recalculate_skill_state_from_acquired() -> void:
	surfactant_level = acquired_skills.count("surfactant")
	extra_bullets = acquired_skills.count("spread")
	vampirism_level = acquired_skills.count("vampirism")
	vitality_level = acquired_skills.count("vitality")
	antibody_level = acquired_skills.count("antibody")
	fire_cooldown = _base_fire_cooldown * pow(0.9, float(acquired_skills.count("red_bull")))

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
		_dash_label.text = "Dash Ready" if _use_ascii_ui() else "冲刺 就绪"
		_dash_label.add_theme_color_override("font_color", Color(0.4, 1.0, 0.45, 1.0))
	else:
		_dash_label.text = ("Dash %.1f s" if _use_ascii_ui() else "冲刺 %.1f s") % _dash_cd
		_dash_label.add_theme_color_override("font_color", Color(1.0, 0.85, 0.2, 1.0))

func _draw() -> void:
	var body_color: Color = Color(_palette.get("turret_body", Color.WHITE))
	var rim_color: Color = Color(_palette.get("turret_body_rim", Color.WHITE))
	if red_bull_level() > 0:
		body_color = body_color.lerp(Color(1.0, 0.55, 0.32, 1.0), 0.28)
		rim_color = rim_color.lerp(Color(0.96, 0.36, 0.18, 1.0), 0.32)
	if extra_bullets <= 0:
		_draw_primary_turret_barrel(body_color, rim_color)
	else:
		for mount in _get_turret_mounts():
			_draw_turret_mount_barrel(mount)
	for bubble in _sorted_body_bubbles():
		_draw_body_bubble(bubble, body_color, rim_color)
	for mount in _get_missile_launcher_mounts():
		_draw_missile_launcher_mount(mount)
	if extra_bullets <= 0:
		_draw_primary_turret_head(body_color, rim_color)
	_draw_core_cluster()
	for mount in _get_turret_mounts():
		_draw_turret_mount_head(mount)

func _process(delta: float) -> void:
	_tick_growth_animation(delta)
	_tick_turret_aim(delta)
	if not is_local_player or not _direct_input_enabled:
		return
	apply_input_state(build_input_state(), delta)

func _tick_turret_aim(delta: float) -> void:
	_ensure_turret_angle_buffer()
	if _turret_angles.is_empty():
		return
	var aim_target_local := _get_local_aim_target()
	var mounts := _get_turret_mounts()
	var turn_blend: float = min(1.0, delta * TURRET_TURN_SPEED)
	for index in range(_turret_angles.size()):
		var target_local_angle := clampf(wrapf(_aim_world_rotation - rotation, -PI, PI), -TURRET_MAX_AIM_OFFSET, TURRET_MAX_AIM_OFFSET)
		if index < mounts.size():
			var mount_center: Vector2 = mounts[index].get("center", Vector2.ZERO)
			var target_vector := aim_target_local - mount_center
			if target_vector.length_squared() > 0.001:
				target_local_angle = target_vector.angle()
		_turret_angles[index] = lerp_angle(_turret_angles[index], target_local_angle, turn_blend)
	queue_redraw()

func fire() -> void:
	if _is_eliminated or not can_fire or bullet_scene == null:
		return
	can_fire = false
	_fire_cd_remaining = fire_cooldown
	var scene := get_tree().current_scene
	var fire_points := _build_fire_points()
	var visual_only: bool = scene != null and scene.has_method("is_client_network_mode") and scene.is_client_network_mode()
	for fire_point in fire_points:
		var bullet: Area2D = scene.acquire_player_bullet() if scene and scene.has_method("acquire_player_bullet") else bullet_scene.instantiate()
		if bullet.get_parent() == null:
			scene.get_node("Bullets").add_child(bullet)
		if bullet.has_method("activate_from_pool"):
			bullet.activate_from_pool(
				fire_point["pos"],
				fire_point["rot"],
				_surfactant_pierce_hits(),
				player_color_key,
				visual_only,
				get_network_peer_id()
			)
		else:
			bullet.global_position = fire_point["pos"]
			bullet.rotation = fire_point["rot"]
			bullet.pierce_hits_remaining = _surfactant_pierce_hits()
			if bullet.has_method("set_color_key"):
				bullet.set_color_key(player_color_key)
	if scene and scene.has_method("notify_player_fire"):
		if scene.has_method("_notify_player_fire_points"):
			scene._notify_player_fire_points(get_network_peer_id(), fire_points, _surfactant_pierce_hits(), player_color_key)
		else:
			scene.notify_player_fire(get_network_peer_id(), global_position, rotation, fire_points.size(), _surfactant_pierce_hits(), player_color_key)
	_try_fire_antibody_missiles(scene, visual_only)
	_play_fire_sfx()

func _tick_growth_animation(delta: float) -> void:
	var growth_blend := 1.0 - exp(-delta * 4.6)
	var eased_growth := growth_blend * growth_blend * (3.0 - 2.0 * growth_blend)
	var previous_scale := _display_growth_scale
	_display_growth_scale = lerpf(_display_growth_scale, _target_growth_scale, eased_growth)
	if absf(previous_scale - _display_growth_scale) > 0.001:
		queue_redraw()
	if _camera != null and is_local_player:
		var camera_blend := 1.0 - exp(-delta * 2.8)
		var eased_camera := camera_blend * camera_blend * (3.0 - 2.0 * camera_blend)
		_camera.zoom = _camera.zoom.lerp(_target_camera_zoom, eased_camera)

func _rebuild_growth_layout() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash([player_color_key, _progression_level, surfactant_level, extra_bullets, vampirism_level, vitality_level, antibody_level])
	_body_bubbles.clear()
	var base_radius: float = BASE_BODY_RADIUS + float(_progression_level) * BODY_GROWTH_PER_LEVEL + float(vitality_level) * 1.8
	_body_bubbles.append({"center": Vector2.ZERO, "radius": base_radius, "ring": -1, "visible": true, "shell": false})
	var shell_ring_count: int = _progression_level
	for ring_index in range(shell_ring_count):
		_append_growth_ring(rng, base_radius, ring_index)
	_ensure_turret_angle_buffer()

func _append_growth_ring(rng: RandomNumberGenerator, base_radius: float, ring_index: int) -> void:
	var bubble_budget: int = rng.randi_range(FIRST_RING_MIN_BUBBLES, FIRST_RING_MAX_BUBBLES) if ring_index == 0 else rng.randi_range(LATER_RING_MIN_BUBBLES, LATER_RING_MAX_BUBBLES)
	var shell_rotation: float = rng.randf_range(0.0, TAU)
	var lobe_count: int = rng.randi_range(2, 4) + ring_index
	var shell_phase: float = rng.randf_range(0.0, TAU)
	for bubble_idx in range(bubble_budget):
		var shell_t: float = float(bubble_idx) / float(maxi(bubble_budget, 1))
		var organic_wave: float = sin(shell_t * TAU * float(lobe_count) + shell_phase) * (0.14 + float(ring_index) * 0.02)
		var angle: float = shell_rotation + TAU * shell_t + organic_wave + rng.randf_range(-0.1, 0.1)
		var direction: Vector2 = Vector2.RIGHT.rotated(angle)
		var radius_scale: float = rng.randf_range(FIRST_RING_RADIUS_SCALE_MIN, FIRST_RING_RADIUS_SCALE_MAX) if ring_index == 0 else rng.randf_range(LATER_RING_RADIUS_SCALE_MIN, LATER_RING_RADIUS_SCALE_MAX)
		var radius: float = base_radius * radius_scale * (1.0 + float(ring_index) * 0.03)
		var radial_wave: float = sin(angle * float(lobe_count) + shell_phase) * (base_radius * 0.12 + float(ring_index) * 1.5)
		var center_distance: float = base_radius + float(ring_index) * (base_radius * 0.34) + radius - minf(radius * 0.28, 4.0) + radial_wave * 0.55 + rng.randf_range(-1.8, 1.8)
		var candidate: Vector2 = direction * center_distance
		var attempt: int = 0
		while _body_bubble_overlaps(candidate, radius) and attempt < 8:
			candidate += direction * (2.4 + float(attempt) * 0.55)
			attempt += 1
		if _body_bubble_overlaps(candidate, radius):
			continue
		_body_bubbles.append({
			"center": candidate,
			"radius": radius,
			"ring": ring_index,
			"visible": true,
			"shell": true,
		})

func _apply_shell_visibility() -> void:
	var shell_indices := _get_shell_indices()
	if shell_indices.is_empty():
		_broken_shell_count = 0
		_pending_hit_shell_index = -1
		_pending_hit_is_shell = false
		_has_pending_hit = false
		queue_redraw()
		return
	_broken_shell_count = clampi(_broken_shell_count, 0, shell_indices.size())
	var current_hidden: int = 0
	for index in shell_indices:
		if not bool(_body_bubbles[index].get("visible", true)):
			current_hidden += 1
	if _broken_shell_count > current_hidden:
		_hide_shell_bubbles(_broken_shell_count - current_hidden, _pending_hit_shell_index)
	elif _broken_shell_count < current_hidden:
		_show_shell_bubbles(current_hidden - _broken_shell_count)
	_pending_hit_shell_index = -1
	_pending_hit_is_shell = false
	_has_pending_hit = false
	queue_redraw()

func _get_shell_indices() -> Array[int]:
	var indices: Array[int] = []
	for index in range(_body_bubbles.size()):
		if bool(_body_bubbles[index].get("shell", false)):
			indices.append(index)
	return indices

func _hide_shell_bubbles(count: int, preferred_index: int = -1) -> void:
	if preferred_index >= 0 and count > 0 and preferred_index < _body_bubbles.size():
		var preferred_bubble: Dictionary = _body_bubbles[preferred_index]
		if bool(preferred_bubble.get("shell", false)) and bool(preferred_bubble.get("visible", true)):
			preferred_bubble["visible"] = false
			_body_bubbles[preferred_index] = preferred_bubble
			count -= 1
	for _i in range(count):
		var best_index := -1
		var best_score := -INF
		for index in _get_shell_indices():
			var bubble: Dictionary = _body_bubbles[index]
			if not bool(bubble.get("visible", true)):
				continue
			var center: Vector2 = bubble.get("center", Vector2.ZERO) * _display_growth_scale
			var ring: int = int(bubble.get("ring", 0))
			var score := float(ring) * 120.0 + center.length()
			if _has_pending_hit:
				score += maxf(0.0, BODY_HIT_SCORE_DISTANCE - center.distance_to(_pending_hit_local)) * 2.2
			if score > best_score:
				best_score = score
				best_index = index
		if best_index < 0:
			return
		var next_bubble: Dictionary = _body_bubbles[best_index]
		next_bubble["visible"] = false
		_body_bubbles[best_index] = next_bubble

func _shell_delta_to_bubbles(hp_delta: int) -> int:
	if hp_delta <= 0:
		return 0
	return maxi(1, int(ceil(float(hp_delta) / SHELL_HP_STEP)))

func _find_nearest_visible_bubble_index(local_position: Vector2) -> int:
	var best_index := -1
	var best_dist_sq := INF
	for index in range(_body_bubbles.size()):
		var bubble: Dictionary = _body_bubbles[index]
		if not bool(bubble.get("visible", true)):
			continue
		var center: Vector2 = bubble.get("center", Vector2.ZERO) * _display_growth_scale
		var dist_sq := center.distance_squared_to(local_position)
		if dist_sq < best_dist_sq:
			best_dist_sq = dist_sq
			best_index = index
	return best_index

func _show_shell_bubbles(count: int) -> void:
	for _i in range(count):
		var best_index := -1
		var best_score := INF
		for index in _get_shell_indices():
			var bubble: Dictionary = _body_bubbles[index]
			if bool(bubble.get("visible", true)):
				continue
			var center: Vector2 = bubble.get("center", Vector2.ZERO) * _display_growth_scale
			var ring: int = int(bubble.get("ring", 0))
			var score := float(ring) * 120.0 + center.length()
			if score < best_score:
				best_score = score
				best_index = index
		if best_index < 0:
			return
		var next_bubble: Dictionary = _body_bubbles[best_index]
		next_bubble["visible"] = true
		_body_bubbles[best_index] = next_bubble

func _body_bubble_overlaps(center: Vector2, radius: float) -> bool:
	for bubble in _body_bubbles:
		var other_center: Vector2 = bubble.get("center", Vector2.ZERO)
		var other_radius: float = float(bubble.get("radius", BASE_BODY_RADIUS))
		if center.distance_to(other_center) < radius + other_radius - 3.0:
			return true
	return false

func _current_body_extent() -> float:
	var max_extent := BASE_BODY_RADIUS * _display_growth_scale
	for bubble in _body_bubbles:
		var center: Vector2 = bubble.get("center", Vector2.ZERO) * _display_growth_scale
		var radius: float = float(bubble.get("radius", BASE_BODY_RADIUS)) * _display_growth_scale
		max_extent = maxf(max_extent, center.length() + radius)
	return max_extent

func _sorted_body_bubbles() -> Array[Dictionary]:
	var ordered: Array[Dictionary] = []
	for bubble in _body_bubbles:
		if bool(bubble.get("visible", true)):
			ordered.append(bubble)
	ordered.sort_custom(func(a: Dictionary, b: Dictionary):
		return float(a.get("radius", 0.0)) > float(b.get("radius", 0.0))
	)
	return ordered

func _draw_body_bubble(bubble: Dictionary, body_color: Color, rim_color: Color) -> void:
	var center: Vector2 = bubble.get("center", Vector2.ZERO) * _display_growth_scale
	var radius: float = float(bubble.get("radius", BASE_BODY_RADIUS)) * _display_growth_scale
	var membrane_color := body_color.lerp(Color(1.0, 1.0, 1.0, 1.0), 0.08)
	var inner_color := body_color.darkened(0.06)
	var highlight_color: Color = Color(_palette.get("turret_highlight", Color.WHITE))
	draw_circle(center + Vector2(radius * 0.08, radius * 0.12), radius * 0.98, inner_color, true, -1.0, true)
	draw_circle(center, radius, membrane_color, true, -1.0, true)
	draw_circle(center, radius, rim_color, false, 2.2, true)
	draw_circle(center, radius * 0.78, Color(1.0, 1.0, 1.0, 0.05), false, 0.9, true)
	draw_circle(center + Vector2(-radius * 0.3, -radius * 0.34), radius * 0.22, highlight_color, true, -1.0, true)
	draw_circle(center + Vector2(-radius * 0.12, -radius * 0.16), radius * 0.1, Color(1.0, 1.0, 1.0, 0.18), true, -1.0, true)
	if vampirism_level > 0:
		draw_circle(center + Vector2(-radius * 0.18, -radius * 0.12), radius * 0.2, Color(0.62, 0.1, 0.12, 0.18 + 0.04 * vampirism_level), true, -1.0, true)

func _draw_core_cluster() -> void:
	if extra_bullets <= 0:
		return
	var base_core_radius := (4.2 + float(extra_bullets) * 1.2 + float(vitality_level) * 0.45) * _display_growth_scale
	draw_circle(Vector2.ZERO, base_core_radius, _palette["turret_core"], true, -1.0, true)
	draw_circle(Vector2.ZERO, base_core_radius, Color(1.0, 1.0, 1.0, 0.16), false, 1.0, true)
	var nucleus_offset := Vector2(base_core_radius * 0.18, -base_core_radius * 0.12)
	draw_circle(nucleus_offset, base_core_radius * 0.42, Color(1.0, 1.0, 1.0, 0.18), true, -1.0, true)
	draw_circle(Vector2.ZERO, base_core_radius * 0.58, Color(_palette.get("turret_ring", Color.WHITE)), false, 1.0, true)

func _draw_primary_turret_barrel(body_color: Color, rim_color: Color) -> void:
	var turret_ring: Color = Color(_palette.get("turret_ring", Color.WHITE))
	var turret_core: Color = Color(_palette.get("turret_core", rim_color))
	var barrel_main: Color = Color(_palette.get("barrel_main", body_color))
	var barrel_rim: Color = Color(_palette.get("barrel_rim", rim_color))
	var muzzle_main: Color = Color(_palette.get("muzzle_main", barrel_main))
	var muzzle_rim: Color = Color(_palette.get("muzzle_rim", barrel_rim))
	draw_rect(Rect2(0.0, -5.0 * _display_growth_scale, 40.0 * _display_growth_scale, 10.0 * _display_growth_scale), barrel_main, true)
	draw_rect(Rect2(0.0, -5.0 * _display_growth_scale, 40.0 * _display_growth_scale, 10.0 * _display_growth_scale), barrel_rim, false, 1.5)
	var muzzle_pos := Vector2(40.0 * _display_growth_scale, 0.0)
	var muzzle_radius := 5.5 * _display_growth_scale
	draw_circle(muzzle_pos, muzzle_radius, muzzle_main, true, -1.0, true)
	draw_circle(muzzle_pos, muzzle_radius, muzzle_rim, false, 1.2, true)

func _draw_primary_turret_head(body_color: Color, rim_color: Color) -> void:
	var turret_ring: Color = Color(_palette.get("turret_ring", Color.WHITE))
	var turret_core: Color = Color(_palette.get("turret_core", rim_color))
	draw_circle(Vector2.ZERO, 12.0 * _display_growth_scale, turret_ring, false, 1.2, true)
	draw_circle(Vector2.ZERO, 4.5 * _display_growth_scale, turret_core, true, -1.0, true)

func _get_turret_mounts() -> Array[Dictionary]:
	var mounts: Array[Dictionary] = []
	var total_turrets: int = _total_turret_count()
	if extra_bullets <= 0:
		return mounts
	var body_extent := _current_body_extent()
	var core_radius := maxf(10.0 * _display_growth_scale, body_extent * 0.24)
	var socket_angles := _get_turret_socket_angles(total_turrets)
	var shared_aim_angle := clampf(wrapf(_aim_world_rotation - rotation, -PI, PI), -TURRET_MAX_AIM_OFFSET, TURRET_MAX_AIM_OFFSET)
	for i in range(total_turrets):
		var ring_index: int = i / 3
		var slot_index: int = i % 3
		var turret_angle: float = _turret_angles[i] if i < _turret_angles.size() else 0.0
		var socket_angle: float = socket_angles[i] if i < socket_angles.size() else 0.0
		var orbit_angle: float = socket_angle + shared_aim_angle * 0.22
		var orbit_radius: float = body_extent * (0.64 + float(ring_index) * 0.18)
		var center := Vector2.RIGHT.rotated(orbit_angle) * orbit_radius
		center += Vector2.RIGHT.rotated(orbit_angle).rotated(PI * 0.5) * float(slot_index - 1) * 2.0 * _display_growth_scale
		var body_radius: float = (9.4 + minf(float(ring_index), 2.0) * 0.9) * _display_growth_scale
		var barrel_length: float = (13.5 + minf(float(ring_index), 2.0) * 1.8) * _display_growth_scale
		var barrel_width: float = 6.0 * _display_growth_scale
		mounts.append({
			"index": i,
			"center": center,
			"angle": turret_angle,
			"orbit_angle": orbit_angle,
			"body_radius": body_radius,
			"length": barrel_length,
			"width": barrel_width,
			"socket_radius": core_radius,
		})
	return mounts

func _antibody_launcher_count() -> int:
	if antibody_level >= 5:
		return 3
	if antibody_level >= 3:
		return 2
	if antibody_level >= 1:
		return 1
	return 0

func _antibody_fire_cooldown() -> float:
	if antibody_level >= 4:
		return ANTIBODY_FAST_COOLDOWN
	if antibody_level >= 2:
		return (ANTIBODY_BASE_COOLDOWN + ANTIBODY_FAST_COOLDOWN) * 0.5
	return ANTIBODY_BASE_COOLDOWN

func _get_missile_launcher_mounts() -> Array[Dictionary]:
	var mounts: Array[Dictionary] = []
	var launcher_count := _antibody_launcher_count()
	if launcher_count <= 0:
		return mounts
	var candidates: Array[Dictionary] = []
	for bubble in _body_bubbles:
		if not bool(bubble.get("visible", true)):
			continue
		var center: Vector2 = bubble.get("center", Vector2.ZERO) * _display_growth_scale
		var radius: float = float(bubble.get("radius", BASE_BODY_RADIUS)) * _display_growth_scale
		candidates.append({
			"center": center,
			"radius": radius,
			"score": center.length() + radius,
		})
	if candidates.is_empty():
		return mounts
	candidates.sort_custom(func(a: Dictionary, b: Dictionary):
		return float(a.get("score", 0.0)) > float(b.get("score", 0.0))
	)
	for index in range(mini(launcher_count, candidates.size())):
		var candidate: Dictionary = candidates[index]
		var center: Vector2 = candidate.get("center", Vector2.ZERO)
		var normal := center.normalized() if center != Vector2.ZERO else Vector2.RIGHT.rotated(-0.6 + float(index) * 0.6)
		var tangent := normal.rotated(PI * 0.5)
		var radius: float = float(candidate.get("radius", 10.0))
		var length := (18.0 + float(index) * 1.5) * _display_growth_scale
		var width := 7.2 * _display_growth_scale
		var anchor := center + normal * (radius * 0.32)
		mounts.append({
			"center": anchor,
			"normal": normal,
			"tangent": tangent,
			"length": length,
			"width": width,
		})
	return mounts

func _draw_missile_launcher_mount(mount: Dictionary) -> void:
	var center: Vector2 = mount.get("center", Vector2.ZERO)
	var normal: Vector2 = mount.get("normal", Vector2.RIGHT)
	var tangent: Vector2 = mount.get("tangent", Vector2.DOWN)
	var length: float = float(mount.get("length", 18.0))
	var width: float = float(mount.get("width", 7.0))
	var half_length := length * 0.5
	var half_width := width * 0.5
	var body_color := Color(_palette.get("barrel_main", Color.WHITE)).lerp(Color(0.92, 0.92, 0.98, 1.0), 0.18)
	var rim_color := Color(_palette.get("barrel_rim", Color.WHITE))
	var nose_color := Color(_palette.get("muzzle_main", body_color))
	draw_colored_polygon(PackedVector2Array([
		center - normal * half_length + tangent * half_width,
		center - normal * half_length - tangent * half_width,
		center + normal * (half_length - 4.0 * _display_growth_scale) - tangent * half_width,
		center + normal * (half_length - 4.0 * _display_growth_scale) + tangent * half_width,
	]), body_color)
	draw_polyline(PackedVector2Array([
		center - normal * half_length + tangent * half_width,
		center - normal * half_length - tangent * half_width,
		center + normal * (half_length - 4.0 * _display_growth_scale) - tangent * half_width,
		center + normal * (half_length - 4.0 * _display_growth_scale) + tangent * half_width,
		center - normal * half_length + tangent * half_width,
	]), rim_color, 1.2, true)
	draw_colored_polygon(PackedVector2Array([
		center + normal * (half_length - 4.0 * _display_growth_scale) + tangent * (half_width + 1.2 * _display_growth_scale),
		center + normal * (half_length + 4.2 * _display_growth_scale),
		center + normal * (half_length - 4.0 * _display_growth_scale) - tangent * (half_width + 1.2 * _display_growth_scale),
	]), nose_color)
	draw_circle(center - normal * (half_length * 0.32), 1.6 * _display_growth_scale, Color(1.0, 1.0, 1.0, 0.22), true, -1.0, true)

func _total_turret_count() -> int:
	if extra_bullets <= 0:
		return 1
	return extra_bullets * 2

func _get_turret_socket_angles(total_turrets: int) -> Array[float]:
	var socket_angles: Array[float] = []
	if total_turrets <= 0:
		return socket_angles
	if total_turrets == 1:
		socket_angles.append(0.0)
		return socket_angles
	var arc_span := minf(2.25, 1.2 + float(total_turrets - 2) * 0.22)
	for index in range(total_turrets):
		var t := float(index) / float(maxi(total_turrets - 1, 1))
		socket_angles.append(lerpf(-arc_span * 0.5, arc_span * 0.5, t))
	return socket_angles

func _ensure_turret_angle_buffer() -> void:
	var target_count: int = _total_turret_count()
	while _turret_angles.size() < target_count:
		_turret_angles.append(0.0)
	while _turret_angles.size() > target_count:
		_turret_angles.remove_at(_turret_angles.size() - 1)

func _draw_turret_mount_barrel(mount: Dictionary) -> void:
	var center: Vector2 = mount.get("center", Vector2.ZERO)
	var angle: float = float(mount.get("angle", 0.0))
	var body_radius: float = float(mount.get("body_radius", 10.0))
	var length: float = float(mount.get("length", 32.0))
	var width: float = float(mount.get("width", 10.0))
	var forward: Vector2 = Vector2.RIGHT.rotated(angle)
	var perpendicular: Vector2 = forward.rotated(PI * 0.5)
	var turret_main: Color = Color(_palette.get("barrel_main", Color.WHITE))
	var turret_rim: Color = Color(_palette.get("barrel_rim", Color.WHITE))
	var turret_ring: Color = Color(_palette.get("turret_ring", Color.WHITE))
	if red_bull_level() > 0:
		turret_main = turret_main.lerp(Color(1.0, 0.55, 0.32, 1.0), 0.22)
		turret_rim = turret_rim.lerp(Color(0.96, 0.36, 0.18, 1.0), 0.22)
	draw_colored_polygon(PackedVector2Array([
		center + perpendicular * (width * 0.5),
		center - perpendicular * (width * 0.5),
		center + forward * length - perpendicular * (width * 0.5),
		center + forward * length + perpendicular * (width * 0.5),
	]), turret_main)
	var muzzle_pos := center + forward * length
	var muzzle_radius := maxf(5.5 * _display_growth_scale, body_radius * 0.52)
	draw_circle(muzzle_pos, muzzle_radius, Color(_palette.get("muzzle_main", turret_rim)), true, -1.0, true)
	draw_circle(muzzle_pos, muzzle_radius, Color(_palette.get("muzzle_rim", turret_rim)), false, 1.1, true)

func _draw_turret_mount_head(mount: Dictionary) -> void:
	var center: Vector2 = mount.get("center", Vector2.ZERO)
	var angle: float = float(mount.get("angle", 0.0))
	var body_radius: float = float(mount.get("body_radius", 10.0))
	var socket_radius: float = float(mount.get("socket_radius", body_radius * 0.7))
	var turret_main: Color = Color(_palette.get("barrel_main", Color.WHITE))
	var turret_rim: Color = Color(_palette.get("barrel_rim", Color.WHITE))
	var turret_ring: Color = Color(_palette.get("turret_ring", Color.WHITE))
	if red_bull_level() > 0:
		turret_main = turret_main.lerp(Color(1.0, 0.55, 0.32, 1.0), 0.22)
		turret_rim = turret_rim.lerp(Color(0.96, 0.36, 0.18, 1.0), 0.22)
	var bridge_dir := center.normalized()
	if bridge_dir == Vector2.ZERO:
		bridge_dir = Vector2.RIGHT
	var bridge_perpendicular := bridge_dir.rotated(PI * 0.5)
	var bridge_start := bridge_dir * socket_radius
	var bridge_end := center - bridge_dir * (body_radius * 0.72)
	draw_colored_polygon(PackedVector2Array([
		bridge_start + bridge_perpendicular * (body_radius * 0.34),
		bridge_start - bridge_perpendicular * (body_radius * 0.34),
		bridge_end - bridge_perpendicular * (body_radius * 0.42),
		bridge_end + bridge_perpendicular * (body_radius * 0.42),
	]), Color(_palette.get("turret_body", turret_main)).darkened(0.04))
	draw_circle(center, body_radius, turret_main, true, -1.0, true)
	draw_circle(center, body_radius, turret_rim, false, 2.0, true)
	draw_circle(center, body_radius * 0.55, turret_ring, false, 1.2, true)
	var facing := Vector2.RIGHT.rotated(angle)
	var facing_core := center + facing * (body_radius * 0.18)
	draw_circle(facing_core, body_radius * 0.24, Color(_palette.get("turret_core", turret_ring)), true, -1.0, true)
	draw_circle(center - facing * (body_radius * 0.2), body_radius * 0.16, Color(1.0, 1.0, 1.0, 0.14), true, -1.0, true)

func _build_fire_points() -> Array:
	var fire_points: Array = []
	var aim_target_local := _get_local_aim_target()
	if extra_bullets <= 0:
		var primary_muzzle := Vector2(44.0 * _display_growth_scale, 0.0)
		fire_points.append({
			"pos": to_global(primary_muzzle),
			"rot": rotation,
		})
		return fire_points
	for mount in _get_turret_mounts():
		var center: Vector2 = mount.get("center", Vector2.ZERO)
		var angle: float = float(mount.get("angle", 0.0))
		var body_radius: float = float(mount.get("body_radius", 10.0))
		var length: float = float(mount.get("length", 32.0))
		var forward := Vector2.RIGHT.rotated(angle)
		var local_muzzle := center + forward * (body_radius * 0.12 + length + 4.0 * _display_growth_scale)
		var muzzle_angle := angle
		var target_vector := aim_target_local - local_muzzle
		if target_vector.length_squared() > 0.001:
			muzzle_angle = target_vector.angle()
		fire_points.append({
			"pos": to_global(local_muzzle),
			"rot": rotation + muzzle_angle,
		})
	return fire_points

func _build_missile_fire_points() -> Array:
	var fire_points: Array = []
	var scene := get_tree().current_scene
	for mount in _get_missile_launcher_mounts():
		var center: Vector2 = mount.get("center", Vector2.ZERO)
		var normal: Vector2 = mount.get("normal", Vector2.RIGHT)
		var length: float = float(mount.get("length", 18.0))
		var local_muzzle := center + normal * (length * 0.5 + 4.0 * _display_growth_scale)
		var global_muzzle := to_global(local_muzzle)
		var missile_rotation := rotation + normal.angle()
		if scene and scene.has_method("get_nearest_enemy_position"):
			var enemy_position: Vector2 = scene.get_nearest_enemy_position(global_muzzle)
			var to_enemy := enemy_position - global_muzzle
			if to_enemy.length_squared() > 0.001:
				missile_rotation = to_enemy.angle()
		var tangent := normal.rotated(PI * 0.5)
		for burst_index in range(ANTIBODY_BURST_COUNT):
			var burst_t := float(burst_index) / float(maxi(ANTIBODY_BURST_COUNT - 1, 1))
			var spread_offset := lerpf(-ANTIBODY_BURST_SPREAD * 0.5, ANTIBODY_BURST_SPREAD * 0.5, burst_t)
			var lateral_offset := lerpf(-ANTIBODY_BURST_LATERAL_SPACING * 0.5, ANTIBODY_BURST_LATERAL_SPACING * 0.5, burst_t) * _display_growth_scale
			fire_points.append({
				"pos": global_muzzle + tangent * lateral_offset,
				"rot": missile_rotation + spread_offset,
			})
	return fire_points

func _try_fire_antibody_missiles(scene: Node, visual_only: bool) -> void:
	if antibody_level <= 0 or _missile_cd_remaining > 0.0:
		return
	if scene == null or not scene.has_method("acquire_player_missile"):
		return
	var fire_points := _build_missile_fire_points()
	if fire_points.is_empty():
		return
	_missile_cd_remaining = _antibody_fire_cooldown()
	for fire_point_variant in fire_points:
		var fire_point: Dictionary = fire_point_variant
		var missile: Area2D = scene.acquire_player_missile()
		if missile.has_method("activate_from_pool"):
			missile.activate_from_pool(
				fire_point.get("pos", global_position),
				float(fire_point.get("rot", rotation)),
				player_color_key,
				visual_only,
				get_network_peer_id()
			)
	if scene.has_method("notify_player_missile_launch_points"):
		scene.notify_player_missile_launch_points(get_network_peer_id(), fire_points, player_color_key)

func _get_local_aim_target() -> Vector2:
	if is_local_player and _direct_input_enabled:
		return to_local(get_global_mouse_position())
	var aim_local_angle := wrapf(_aim_world_rotation - rotation, -PI, PI)
	return Vector2.RIGHT.rotated(aim_local_angle) * (_current_body_extent() + 1200.0)

func _update_camera_limits() -> void:
	if _camera == null:
		return
	_camera.limit_left = 0
	_camera.limit_top = 0
	_camera.limit_right = int(_arena_size.x)
	_camera.limit_bottom = int(_arena_size.y)

func red_bull_level() -> int:
	return acquired_skills.count("red_bull")
