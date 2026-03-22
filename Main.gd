extends Node2D

@export var enemy_scene: PackedScene
@export var compound_enemy_scene: PackedScene
# boss_scene 用 preload 保证一定加载，不依赖编辑器赋值
var boss_scene: PackedScene = preload("res://EnemyBoss.tscn")
const PLAYER_BULLET_SCENE := preload("res://Bullet.tscn")
const ENEMY_BULLET_SCENE := preload("res://EnemyBullet.tscn")
const GLOBAL_BGM := preload("res://Microscopic_Pursuit.ogg")
const ENEMY_DEATH_SFX := preload("res://universfield-bubble-pop-07-487896.mp3")
const BGM_BUS_NAME := &"BGM"
const BGM_NORMAL_VOLUME_DB := -2.0
const BGM_MANUAL_PAUSE_VOLUME_DB := -10.0
const BGM_MIX_TWEEN_DURATION := 0.22
const BGM_NORMAL_CUTOFF_HZ := 18000.0
const BGM_MANUAL_PAUSE_CUTOFF_HZ := 1200.0

const BUBBLES_PER_LEVEL := 8    # 攒满后触发升级
const BASE_VIEWPORT_SIZE := Vector2(1920.0, 1080.0)
const ARENA_SCALE := 1.25
const DESIGN_VIEWPORT_SIZE := BASE_VIEWPORT_SIZE * ARENA_SCALE
const MAX_COMPOUND_ENEMIES := 7
const BASIC_ENEMY_DISABLE_LEVEL := 3
const BOSS_SWARM_LEVEL := 5
const MIN_BOSSES_AFTER_LEVEL_SIX := 4
const FINAL_BOSS_LEVEL := 9
const FINAL_BOSS_SPAWN_MARGIN := 320.0
const PLAYER_BULLET_POOL_PREWARM := 96
const ENEMY_BULLET_POOL_PREWARM := 160

var max_hp: int         = 50    # 每升一级 +50
var score: int          = 0
var hp: int             = 50
var is_game_over        := false
var next_boss_score: int = 10   # 第一个 Boss 在 10 分时出现
var _final_boss_spawned := false
var _final_boss_defeated := false

# ── 升级系统 ────────────────────────────────────────────────────────────────
var _boss_bubbles: int   = 0    # 当前积累的 Boss 泡泡数
var _player_level: int   = 0    # 玩家当前等级
var _shown_skills: Array = []   # 本局已展示过的技能 id（无论是否选中）

const BASE_BOSS_MIN_SATELLITES := 8
const BASE_BOSS_MAX_SATELLITES := 20

# ── 暂停系统 ────────────────────────────────────────────────────────────────
var _is_manually_paused := false
var _pause_label: Label = null
var _player_node: Node2D = null
var _bgm_retry_timer := 0.0
var _pending_regular_boss_spawns := 0
@onready var _bgm_player: AudioStreamPlayer = $BGM
var _enemy_death_sfx_player: AudioStreamPlayer = null
var _player_bullet_pool: Array = []
var _enemy_bullet_pool: Array = []
var _bgm_bus_index := -1
var _bgm_lowpass_effect: AudioEffectLowPassFilter = null
var _bgm_mix_tween: Tween = null

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	$Turret.process_mode = Node.PROCESS_MODE_PAUSABLE
	$Bullets.process_mode = Node.PROCESS_MODE_PAUSABLE
	$Enemies.process_mode = Node.PROCESS_MODE_PAUSABLE
	$SpawnTimer.process_mode = Node.PROCESS_MODE_PAUSABLE
	_player_node = $Turret
	update_score_label()
	update_hp_label()
	update_level_label()
	EnemyBoss.apply_player_level(_player_level)
	BossEvolution.set_satellite_bounds(
		BASE_BOSS_MIN_SATELLITES + _player_level * 6,
		BASE_BOSS_MAX_SATELLITES + _player_level * 10
	)
	BossEvolution.reset_population()
	BossEvolution.startup()
	_prewarm_projectile_pools()
	_setup_bgm_bus()
	_setup_enemy_death_sfx_player()
	_setup_pause_label()
	call_deferred("_ensure_bgm_playing")
	# 延迟一帧确保 viewport 尺寸已就绪
	call_deferred("_center_player")

func _setup_bgm_bus() -> void:
	_bgm_bus_index = AudioServer.get_bus_index(StringName(BGM_BUS_NAME))
	if _bgm_bus_index == -1:
		AudioServer.add_bus(AudioServer.bus_count)
		_bgm_bus_index = AudioServer.bus_count - 1
		AudioServer.set_bus_name(_bgm_bus_index, StringName(BGM_BUS_NAME))
		AudioServer.set_bus_send(_bgm_bus_index, &"Master")
	var effect_count := AudioServer.get_bus_effect_count(_bgm_bus_index)
	for i in range(effect_count):
		var effect := AudioServer.get_bus_effect(_bgm_bus_index, i)
		if effect is AudioEffectLowPassFilter:
			_bgm_lowpass_effect = effect
			break
	if _bgm_lowpass_effect == null:
		_bgm_lowpass_effect = AudioEffectLowPassFilter.new()
		AudioServer.add_bus_effect(_bgm_bus_index, _bgm_lowpass_effect, 0)
	_apply_bgm_mix(true)

func _prewarm_projectile_pools() -> void:
	_prewarm_projectile_pool(PLAYER_BULLET_SCENE, _player_bullet_pool, PLAYER_BULLET_POOL_PREWARM)
	_prewarm_projectile_pool(ENEMY_BULLET_SCENE, _enemy_bullet_pool, ENEMY_BULLET_POOL_PREWARM)

func _prewarm_projectile_pool(scene: PackedScene, pool: Array, count: int) -> void:
	for _i in range(count):
		var projectile := scene.instantiate()
		$Bullets.add_child(projectile)
		if projectile.has_method("deactivate_to_pool"):
			projectile.deactivate_to_pool()
		pool.append(projectile)

func acquire_player_bullet() -> Area2D:
	return _acquire_projectile(PLAYER_BULLET_SCENE, _player_bullet_pool)

func acquire_enemy_bullet() -> Area2D:
	return _acquire_projectile(ENEMY_BULLET_SCENE, _enemy_bullet_pool)

func _acquire_projectile(scene: PackedScene, pool: Array) -> Area2D:
	if not pool.is_empty():
		return pool.pop_back()
	var projectile: Area2D = scene.instantiate()
	$Bullets.add_child(projectile)
	return projectile

func release_player_bullet(projectile: Area2D) -> void:
	call_deferred("_release_player_bullet_deferred", projectile)

func _release_player_bullet_deferred(projectile: Area2D) -> void:
	_release_projectile(projectile, _player_bullet_pool)

func release_enemy_bullet(projectile: Area2D) -> void:
	call_deferred("_release_enemy_bullet_deferred", projectile)

func _release_enemy_bullet_deferred(projectile: Area2D) -> void:
	_release_projectile(projectile, _enemy_bullet_pool)

func _release_projectile(projectile: Area2D, pool: Array) -> void:
	if not is_instance_valid(projectile):
		return
	if projectile.get_parent() != $Bullets:
		$Bullets.add_child(projectile)
	if projectile.has_method("deactivate_to_pool"):
		projectile.deactivate_to_pool()
	pool.append(projectile)

func _setup_enemy_death_sfx_player() -> void:
	_enemy_death_sfx_player = AudioStreamPlayer.new()
	_enemy_death_sfx_player.name = "EnemyDeathSfx"
	_enemy_death_sfx_player.stream = ENEMY_DEATH_SFX
	_enemy_death_sfx_player.bus = &"Master"
	_enemy_death_sfx_player.volume_db = -7.0
	_enemy_death_sfx_player.max_polyphony = 8
	add_child(_enemy_death_sfx_player)

func play_enemy_death_sfx() -> void:
	if _enemy_death_sfx_player == null:
		return
	_enemy_death_sfx_player.play()

func _process(_delta: float) -> void:
	BossEvolution.poll_async()
	_bgm_retry_timer -= _delta
	if _bgm_retry_timer <= 0.0 and (_bgm_player == null or not _bgm_player.playing):
		_bgm_retry_timer = 0.75
		_ensure_bgm_playing()

func _ensure_bgm_playing() -> void:
	if _bgm_player == null:
		return
	_bgm_player.bus = BGM_BUS_NAME
	_bgm_player.stream = GLOBAL_BGM
	_apply_bgm_mix(true)
	_bgm_player.stream_paused = false
	if not _bgm_player.playing:
		_bgm_player.stop()
		_bgm_player.play()

func _apply_bgm_mix(immediate: bool = false) -> void:
	if _bgm_player == null:
		return
	var target_volume: float = BGM_MANUAL_PAUSE_VOLUME_DB if _is_manually_paused else BGM_NORMAL_VOLUME_DB
	var target_cutoff: float = BGM_MANUAL_PAUSE_CUTOFF_HZ if _is_manually_paused else BGM_NORMAL_CUTOFF_HZ
	if _bgm_mix_tween != null:
		_bgm_mix_tween.kill()
		_bgm_mix_tween = null
	if immediate:
		_bgm_player.volume_db = target_volume
		if _bgm_lowpass_effect != null:
			_bgm_lowpass_effect.cutoff_hz = target_cutoff
		return
	_bgm_mix_tween = create_tween()
	_bgm_mix_tween.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
	_bgm_mix_tween.tween_property(_bgm_player, "volume_db", target_volume, BGM_MIX_TWEEN_DURATION)
	if _bgm_lowpass_effect != null:
		_bgm_mix_tween.parallel().tween_property(_bgm_lowpass_effect, "cutoff_hz", target_cutoff, BGM_MIX_TWEEN_DURATION)

func _center_player() -> void:
	$Turret.global_position = get_viewport_rect().size / 2.0

func get_player_node() -> Node2D:
	if not is_instance_valid(_player_node):
		_player_node = get_node_or_null("Turret")
	return _player_node

func get_player_position() -> Vector2:
	var player := get_player_node()
	if is_instance_valid(player):
		return player.global_position
	return get_active_arena_size() * 0.5

func get_player_hp_ratio() -> float:
	return clampf(float(hp) / maxf(float(max_hp), 1.0), 0.0, 1.0)

func get_player_dash_cooldown() -> float:
	var player := get_player_node()
	if is_instance_valid(player):
		return float(player.get("_dash_cd"))
	return 0.0

func is_player_ready_to_fire() -> bool:
	var player := get_player_node()
	if is_instance_valid(player):
		return bool(player.get("can_fire"))
	return true

func get_active_arena_size() -> Vector2:
	var viewport_size := get_viewport_rect().size
	return Vector2(
		maxf(viewport_size.x, DESIGN_VIEWPORT_SIZE.x),
		maxf(viewport_size.y, DESIGN_VIEWPORT_SIZE.y)
	)

func is_outside_cleanup_bounds(point: Vector2, margin: float = 0.0) -> bool:
	var arena_size := get_active_arena_size()
	return point.x < -margin \
			or point.y < -margin \
			or point.x > arena_size.x + margin \
			or point.y > arena_size.y + margin

func _setup_pause_label() -> void:
	_pause_label = Label.new()
	_pause_label.text = "游戏暂停"
	_pause_label.visible = false
	_pause_label.process_mode = Node.PROCESS_MODE_ALWAYS
	_pause_label.anchor_left   = 1.0
	_pause_label.anchor_right  = 1.0
	_pause_label.anchor_top    = 0.0
	_pause_label.anchor_bottom = 0.0
	_pause_label.offset_left   = -180.0
	_pause_label.offset_right  = -10.0
	_pause_label.offset_top    = 60.0   # 冲刺标签下方
	_pause_label.offset_bottom = 100.0
	_pause_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_pause_label.add_theme_font_size_override("font_size", 22)
	_pause_label.add_theme_color_override("font_color", Color(1.0, 0.9, 0.4, 1.0))
	_pause_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	_pause_label.add_theme_constant_override("shadow_offset_x", 2)
	_pause_label.add_theme_constant_override("shadow_offset_y", 2)
	$CanvasLayer.add_child(_pause_label)


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.keycode == KEY_ESCAPE \
			and event.pressed and not event.echo and not is_game_over:
		_toggle_pause()
		get_viewport().set_input_as_handled()
	elif event is InputEventKey and event.keycode == KEY_F10 \
			and event.pressed and not event.echo and not is_game_over:
		_debug_refresh_boss()
		get_viewport().set_input_as_handled()


func _toggle_pause() -> void:
	# 升级界面打开时不允许手动暂停
	if get_tree().paused and not _is_manually_paused:
		return
	_is_manually_paused = not _is_manually_paused
	get_tree().paused = _is_manually_paused
	_pause_label.visible = _is_manually_paused
	_apply_bgm_mix()

func add_score(value: int) -> void:
	score += value
	update_score_label()
	# 回血量 = 击杀分值 × max(1, 当前分数/20)，分数越高每次回复越多
	var heal_amount = value * maxi(1, score / 20)
	heal(heal_amount)
	# Boss 里程碑：每 20 分出现一个
	if score >= next_boss_score:
		next_boss_score += 20
		if _should_spawn_regular_boss():
			_queue_regular_boss_spawn()

func _should_spawn_regular_boss() -> bool:
	return not _final_boss_spawned and not _final_boss_defeated and _player_level < FINAL_BOSS_LEVEL

## 由 EnemyBoss 在核心被摧毁时调用
func on_boss_killed() -> void:
	if is_game_over:
		return
	_boss_bubbles += 1
	$Turret.set_boss_bubbles(_boss_bubbles)
	if _boss_bubbles >= BUBBLES_PER_LEVEL:
		_boss_bubbles = 0
		_player_level += 1
		# 升级奖励：血量上限 +50，当前血量也 +50
		max_hp += 50
		heal(50)
		# 同步 Boss 难度参数
		EnemyBoss.apply_player_level(_player_level)
		BossEvolution.set_satellite_bounds(
			BASE_BOSS_MIN_SATELLITES + _player_level * 6,
			BASE_BOSS_MAX_SATELLITES + _player_level * 10
		)
		update_level_label()
		_fill_regular_bosses_to_minimum()
		if _player_level >= FINAL_BOSS_LEVEL and not _final_boss_spawned and not _final_boss_defeated:
			_spawn_final_boss()
		BossEvolution.force_evolve()
		_do_level_up()

func on_final_boss_killed() -> void:
	if is_game_over or _final_boss_defeated:
		return
	_final_boss_defeated = true
	_show_end_screen(true)

func _spawn_final_boss() -> void:
	call_deferred("_spawn_final_boss_deferred")

func _spawn_final_boss_deferred() -> void:
	if _final_boss_spawned or _final_boss_defeated:
		return
	_final_boss_spawned = true
	_pending_regular_boss_spawns = 0
	for boss in get_tree().get_nodes_in_group("boss"):
		boss.queue_free()
	var final_boss = boss_scene.instantiate()
	final_boss.is_final_boss = true
	_place_spawned_enemy(final_boss, FINAL_BOSS_SPAWN_MARGIN)
	$Enemies.add_child(final_boss)

## 暂停游戏并弹出技能选择界面
func _do_level_up() -> void:
	get_tree().paused = true
	var acquired: Array = $Turret.acquired_skills
	var skills := SkillRegistry.pick(2, _shown_skills, acquired)
	if skills.is_empty():
		$Turret.set_boss_bubbles(_boss_bubbles)
		get_tree().paused = false
		return
	# 只把 stackable=false 的牌加入 shown（stackable 的牌可继续出现直到叠满）
	for s in skills:
		if not s["stackable"] and not _shown_skills.has(s["id"]):
			_shown_skills.append(s["id"])
	var ui := LevelUpUI.create(skills, func(skill_id: String) -> void:
		$Turret.acquire_skill(skill_id)
		$Turret.set_boss_bubbles(_boss_bubbles)
		get_tree().paused = false
	)
	add_child(ui)

func heal(amount: int) -> void:
	hp = mini(hp + amount, max_hp)
	update_hp_label()

func take_damage(amount: int) -> void:
	if is_game_over:
		return
	hp = maxi(hp - amount, 0)
	update_hp_label()
	if hp <= 0:
		game_over()

func game_over() -> void:
	_show_end_screen(false)

func _show_end_screen(did_win: bool) -> void:
	is_game_over = true
	_is_manually_paused = false
	_apply_bgm_mix()
	if _pause_label != null:
		_pause_label.visible = false
	$SpawnTimer.stop()
	update_score_label()
	var knockout_score := _get_knockout_score()
	score = knockout_score
	var title_label: Label = $CanvasLayer/GameOverBox/GameOverTitle
	var final_score_label: Label = $CanvasLayer/GameOverBox/FinalScoreLabel
	var restart_button: Button = $CanvasLayer/GameOverBox/RestartButton
	title_label.text = "通关成功" if did_win else "游戏结束"
	final_score_label.text = "击落分：%d" % knockout_score
	title_label.add_theme_color_override(
		"font_color",
		Color(0.92, 0.95, 1.0, 1.0) if did_win else Color(1.0, 0.35, 0.25, 1.0)
	)
	$CanvasLayer/GameOverBG.color = Color(0.42, 0.42, 0.42, 0.84) if did_win else Color(0.0, 0.0, 0.0, 0.75)
	restart_button.text = "再来一局" if did_win else "重新开始"
	$CanvasLayer/GameOverBG.visible = true
	$CanvasLayer/GameOverBox.visible = true
	get_tree().paused = true

func _debug_refresh_boss() -> void:
	for boss in get_tree().get_nodes_in_group("boss"):
		boss.queue_free()
	_final_boss_spawned = true
	var final_boss = boss_scene.instantiate()
	final_boss.is_final_boss = true
	_place_spawned_enemy(final_boss, FINAL_BOSS_SPAWN_MARGIN)
	$Enemies.add_child(final_boss)

func _on_restart_button_pressed() -> void:
	get_tree().paused = false
	get_tree().reload_current_scene()

func _on_quit_button_pressed() -> void:
	get_tree().quit()

func update_score_label() -> void:
	$CanvasLayer/ScoreLabel.text = "击落: %d" % score

func _get_knockout_score() -> int:
	var label_text: String = $CanvasLayer/ScoreLabel.text
	var prefix: String = "击落: "
	if label_text.begins_with(prefix):
		return maxi(score, label_text.trim_prefix(prefix).to_int())
	return score

func update_level_label() -> void:
	$CanvasLayer/LevelLabel.text = "等级: %d" % (_player_level + 1)

func update_hp_label() -> void:
	var label = $CanvasLayer/HPLabel
	label.text = "HP: %d / %d" % [hp, max_hp]
	var ratio := float(hp) / max_hp
	if ratio > 0.6:
		label.add_theme_color_override("font_color", Color(0.4, 1.0, 0.45, 1.0))
	elif ratio > 0.3:
		label.add_theme_color_override("font_color", Color(1.0, 0.85, 0.2, 1.0))
	else:
		label.add_theme_color_override("font_color", Color(1.0, 0.3, 0.3, 1.0))

func _on_spawn_timer_timeout() -> void:
	if _should_maintain_boss_swarm() and _count_regular_bosses() < MIN_BOSSES_AFTER_LEVEL_SIX:
		_fill_regular_bosses_to_minimum()
		return
	if _player_level >= BASIC_ENEMY_DISABLE_LEVEL:
		return
	if randf() < 0.7 or _count_compound_enemies() >= MAX_COMPOUND_ENEMIES:
		_spawn(enemy_scene)
	else:
		_spawn(compound_enemy_scene)

func _should_maintain_boss_swarm() -> bool:
	return _player_level >= BOSS_SWARM_LEVEL and _should_spawn_regular_boss()

func _count_regular_bosses() -> int:
	var count := 0
	for boss in get_tree().get_nodes_in_group("boss"):
		if boss.is_in_group("final_boss"):
			continue
		count += 1
	return count + _pending_regular_boss_spawns

func _fill_regular_bosses_to_minimum() -> void:
	if not _should_maintain_boss_swarm():
		return
	var missing := maxi(0, MIN_BOSSES_AFTER_LEVEL_SIX - _count_regular_bosses())
	for _i in range(missing):
		_queue_regular_boss_spawn()

func _count_compound_enemies() -> int:
	return get_tree().get_nodes_in_group("compound_enemy").size()

func _spawn(scene: PackedScene) -> void:
	if scene == null:
		return
	if scene == boss_scene and not _should_spawn_regular_boss():
		return
	var enemy = scene.instantiate()
	_place_spawned_enemy(enemy)
	$Enemies.add_child(enemy)

func _queue_regular_boss_spawn() -> void:
	if not _should_spawn_regular_boss():
		return
	_pending_regular_boss_spawns += 1
	call_deferred("_spawn_regular_boss_deferred")

func _spawn_regular_boss_deferred() -> void:
	if _pending_regular_boss_spawns > 0:
		_pending_regular_boss_spawns -= 1
	if not _should_spawn_regular_boss():
		return
	_spawn(boss_scene)

func _place_spawned_enemy(enemy: Node2D, margin: float = 60.0) -> void:
	var vp = get_active_arena_size()
	var side = randi() % 4
	var pos := Vector2.ZERO
	match side:
		0: pos = Vector2(randf() * vp.x, -margin)
		1: pos = Vector2(randf() * vp.x, vp.y + margin)
		2: pos = Vector2(-margin, randf() * vp.y)
		3: pos = Vector2(vp.x + margin, randf() * vp.y)
	enemy.global_position = pos
