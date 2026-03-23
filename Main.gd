extends Node2D

@export var enemy_scene: PackedScene
@export var compound_enemy_scene: PackedScene
# boss_scene 用 preload 保证一定加载，不依赖编辑器赋值
var boss_scene: PackedScene = preload("res://EnemyBoss.tscn")
const PLAYER_SCENE := preload("res://Turret.tscn")
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
const PERFORMANCE_TEST_HP := 1000
const PERFORMANCE_TEST_REGULAR_BOSSES := 10
const PERFORMANCE_TEST_PLAYER_LEVEL := 6
const PLAYER_COLOR_ORDER := ["blue", "red", "white", "green"]
const NETWORK_PORT := 7000
const NETWORK_DISCOVERY_PORT := 7001
const NETWORK_MAX_PLAYERS := 4
const NETWORK_INPUT_SEND_INTERVAL := 1.0 / 60.0
const NETWORK_STATE_BROADCAST_INTERVAL := 1.0 / 30.0
const NETWORK_ENEMY_STATE_BROADCAST_INTERVAL := 1.0 / 20.0
const NETWORK_DISCOVERY_INTERVAL := 0.6
const NETWORK_DISCOVERY_ROOM_TTL := 2.4
const BASIC_ENEMY_DISABLE_LEVEL := 3
const BOSS_SWARM_LEVEL := 5
const MIN_BOSSES_AFTER_LEVEL_SIX := 4
const MAX_REGULAR_BOSSES_ON_SCREEN := 6
const EMPTY_SWARM_RECOVERY_BOSSES := 2
const REGULAR_BOSS_RESPAWN_INTERVAL := 3.0
const FINAL_BOSS_LEVEL := 9
const FINAL_BOSS_SPAWN_MARGIN := 320.0
const PLAYER_BULLET_POOL_PREWARM := 96
const ENEMY_BULLET_POOL_PREWARM := 160
const PLAYER_BULLET_HIT_RADIUS := 5.0

var max_hp: int         = 50    # 每升一级 +50
var score: int          = 0
var hp: int             = 50
var is_game_over        := false
var _performance_test_mode := false
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
var _players: Array = []
var _network_mode := "offline"
var _network_player_nodes: Dictionary = {}
var _network_player_colors: Dictionary = {}
var _network_player_names: Dictionary = {}
var _network_player_inputs: Dictionary = {}
var _network_player_states: Dictionary = {}
var _network_input_send_timer := 0.0
var _network_state_broadcast_timer := 0.0
var _network_enemy_state_broadcast_timer := 0.0
var _network_next_enemy_id := 1
var _network_enemy_nodes: Dictionary = {}
var _network_room_name := "Bubble Tanks Room"
var _network_match_started := true
var _lan_discovery_listener: PacketPeerUDP = null
var _lan_discovery_broadcaster: PacketPeerUDP = null
var _lan_discovery_broadcast_timer := 0.0
var _lan_discovered_rooms: Dictionary = {}
var _bgm_retry_timer := 0.0
var _pending_regular_boss_spawns := 0
var _regular_boss_spawn_cooldown := 0.0
@onready var _bgm_player: AudioStreamPlayer = $BGM
var _enemy_death_sfx_player: AudioStreamPlayer = null
var _player_bullet_pool: Array = []
var _enemy_bullet_pool: Array = []
var _active_player_bullets: Array = []
var _active_enemy_bullets: Array = []
var _bgm_bus_index := -1
var _bgm_lowpass_effect: AudioEffectLowPassFilter = null
var _bgm_mix_tween: Tween = null
var _network_menu_button: Button = null
var _network_panel: PanelContainer = null
var _network_status_label: Label = null
var _network_player_count_label: Label = null
var _other_players_status_panel: MarginContainer = null
var _other_players_status_list: HBoxContainer = null
var _player_name_input: LineEdit = null
var _direct_address_input: LineEdit = null
var _room_name_input: LineEdit = null
var _room_list: ItemList = null
var _host_room_button: Button = null
var _start_match_button: Button = null
var _refresh_rooms_button: Button = null
var _join_room_button: Button = null
var _leave_room_button: Button = null
var _local_player_name := "玩家1"
var _manual_discovery_targets := ""

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	$Turret.process_mode = Node.PROCESS_MODE_PAUSABLE
	$Bullets.process_mode = Node.PROCESS_MODE_PAUSABLE
	$Enemies.process_mode = Node.PROCESS_MODE_PAUSABLE
	$SpawnTimer.process_mode = Node.PROCESS_MODE_PAUSABLE
	_player_node = $Turret
	if is_instance_valid(_player_node) and _player_node.has_method("configure_player"):
		_player_node.configure_player("blue", true, true)
	if is_instance_valid(_player_node) and _player_node.has_method("set_network_peer_id"):
		_player_node.set_network_peer_id(1)
	register_player(_player_node)
	_network_player_nodes[1] = _player_node
	_network_player_colors[1] = "blue"
	_network_player_names[1] = _local_player_name
	_ensure_network_player_state(1)
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
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
	_setup_other_player_status_ui()
	_setup_network_ui()
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
	_process_lan_discovery(_delta)
	if not get_tree().paused:
		_process_network(_delta)
		_advance_active_projectiles(_delta)
		if _network_mode != "client":
			_tick_regular_boss_spawns(_delta)
	if _network_mode != "client":
		BossEvolution.poll_async()
	_bgm_retry_timer -= _delta
	if _bgm_retry_timer <= 0.0 and (_bgm_player == null or not _bgm_player.playing):
		_bgm_retry_timer = 0.75
		_ensure_bgm_playing()

func _process_network(delta: float) -> void:
	match _network_mode:
		"host":
			_simulate_remote_players(delta)
			_network_state_broadcast_timer -= delta
			if _network_state_broadcast_timer <= 0.0:
				_network_state_broadcast_timer = NETWORK_STATE_BROADCAST_INTERVAL
				_broadcast_player_states()
			_network_enemy_state_broadcast_timer -= delta
			if _network_enemy_state_broadcast_timer <= 0.0:
				_network_enemy_state_broadcast_timer = NETWORK_ENEMY_STATE_BROADCAST_INTERVAL
				_broadcast_enemy_states()
		"client":
			_network_input_send_timer -= delta
			if _network_input_send_timer <= 0.0:
				_network_input_send_timer = NETWORK_INPUT_SEND_INTERVAL
				_submit_local_input_to_host()
			for peer_id in _network_player_nodes.keys():
				var player = _network_player_nodes[peer_id]
				if player != null and is_instance_valid(player) and player.has_method("tick_network_interpolation"):
					player.tick_network_interpolation(delta)
			for enemy_id in _network_enemy_nodes.keys():
				var enemy = _network_enemy_nodes[enemy_id]
				if enemy != null and is_instance_valid(enemy) and enemy.has_method("tick_network_interpolation"):
					enemy.tick_network_interpolation(delta)

func _simulate_remote_players(delta: float) -> void:
	for peer_id in _network_player_inputs.keys():
		if int(peer_id) == multiplayer.get_unique_id():
			continue
		if not is_player_alive(int(peer_id)):
			continue
		var player = _network_player_nodes.get(peer_id, null)
		if player == null or not is_instance_valid(player):
			continue
		if player.has_method("apply_input_state"):
			player.apply_input_state(_network_player_inputs[peer_id], delta)

func _submit_local_input_to_host() -> void:
	if multiplayer.multiplayer_peer == null:
		return
	var player := get_player_node()
	if not is_instance_valid(player) or not player.has_method("build_input_state"):
		return
	rpc_id(1, "_rpc_submit_input", player.build_input_state())

func _broadcast_player_states() -> void:
	if multiplayer.multiplayer_peer == null:
		return
	var states: Array = []
	for peer_id in _network_player_nodes.keys():
		var player = _network_player_nodes[peer_id]
		if player == null or not is_instance_valid(player):
			continue
		var state := _get_network_player_state(int(peer_id))
		states.append({
			"peer_id": int(peer_id),
			"pos": player.global_position,
			"rot": player.rotation,
			"hp": int(state.get("hp", hp)),
			"max_hp": int(state.get("max_hp", max_hp)),
			"alive": bool(state.get("alive", true)),
		})
	for peer_id in multiplayer.get_peers():
		rpc_id(peer_id, "_rpc_receive_player_states", states)

func _broadcast_enemy_states() -> void:
	if multiplayer.multiplayer_peer == null:
		return
	var states: Array = []
	for enemy_id in _network_enemy_nodes.keys():
		var enemy = _network_enemy_nodes[enemy_id]
		if enemy == null or not is_instance_valid(enemy):
			continue
		if enemy.has_method("get_network_entity_state"):
			states.append({
				"enemy_id": int(enemy_id),
				"state": enemy.get_network_entity_state(),
			})
	if states.is_empty():
		return
	for peer_id in multiplayer.get_peers():
		rpc_id(peer_id, "_rpc_receive_enemy_states", states)

func _tick_regular_boss_spawns(delta: float) -> void:
	_trigger_empty_swarm_recovery()
	if _regular_boss_spawn_cooldown > 0.0:
		_regular_boss_spawn_cooldown = maxf(_regular_boss_spawn_cooldown - delta, 0.0)
	if _pending_regular_boss_spawns <= 0:
		return
	if _regular_boss_spawn_cooldown > 0.0:
		return
	_spawn_regular_boss_deferred()

func _trigger_empty_swarm_recovery() -> void:
	if not _should_maintain_boss_swarm():
		return
	if _count_live_regular_bosses() > 0:
		return
	var desired_pending := mini(EMPTY_SWARM_RECOVERY_BOSSES, MAX_REGULAR_BOSSES_ON_SCREEN)
	if _pending_regular_boss_spawns < desired_pending:
		_pending_regular_boss_spawns = desired_pending
	_regular_boss_spawn_cooldown = 0.0
	var spawn_now := mini(EMPTY_SWARM_RECOVERY_BOSSES, _pending_regular_boss_spawns)
	for _i in range(spawn_now):
		if _count_live_regular_bosses() >= MAX_REGULAR_BOSSES_ON_SCREEN:
			break
		_spawn_regular_boss_deferred()

func _advance_active_projectiles(delta: float) -> void:
	_advance_projectile_list(_active_player_bullets, delta)
	_advance_projectile_list(_active_enemy_bullets, delta)

func _advance_projectile_list(projectiles: Array, delta: float) -> void:
	for i in range(projectiles.size() - 1, -1, -1):
		var projectile = projectiles[i]
		if not is_instance_valid(projectile):
			projectiles.remove_at(i)
			continue
		if projectile.has_method("is_pool_active") and not projectile.is_pool_active():
			projectiles.remove_at(i)
			continue
		if projectile.has_method("advance_projectile"):
			projectile.advance_projectile(delta)
		if projectile.has_method("is_pool_active") and not projectile.is_pool_active():
			projectiles.remove_at(i)

func register_player_bullet(projectile: Area2D) -> void:
	if not _active_player_bullets.has(projectile):
		_active_player_bullets.append(projectile)

func register_enemy_bullet(projectile: Area2D) -> void:
	if not _active_enemy_bullets.has(projectile):
		_active_enemy_bullets.append(projectile)

func process_player_bullet_hit(projectile: Area2D) -> bool:
	var bullet_position := projectile.global_position
	for enemy in $Enemies.get_children():
		if not is_instance_valid(enemy):
			continue
		if enemy.has_method("hit_by_player_bullet") and enemy.hit_by_player_bullet(bullet_position, PLAYER_BULLET_HIT_RADIUS):
			return true
	return false

func is_client_network_mode() -> bool:
	return _network_mode == "client"

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
	if is_instance_valid(_player_node):
		_player_node.global_position = get_viewport_rect().size / 2.0

func register_player(player: Node2D) -> void:
	if player == null or _players.has(player):
		return
	_players.append(player)
	if _player_node == null:
		_player_node = player

func unregister_player(player: Node2D) -> void:
	_players.erase(player)
	if _player_node == player:
		_player_node = _find_local_player()

func get_active_players() -> Array:
	for i in range(_players.size() - 1, -1, -1):
		if not is_instance_valid(_players[i]):
			_players.remove_at(i)
	return _players.duplicate()

func get_local_peer_id() -> int:
	if _network_mode == "offline" or multiplayer.multiplayer_peer == null:
		return 1
	return multiplayer.get_unique_id()

func get_player_peer_id(player: Node2D) -> int:
	if player == null or not is_instance_valid(player):
		return 0
	if player.has_method("get_network_peer_id"):
		return int(player.get_network_peer_id())
	return 1 if player == _player_node else 0

func _default_player_name(peer_id: int) -> String:
	return "玩家%d" % max(peer_id, 1)

func _sanitize_player_name(player_name: String, peer_id: int = 1) -> String:
	var cleaned := player_name.strip_edges()
	if cleaned.is_empty():
		return _default_player_name(peer_id)
	return cleaned.left(16)

func get_player_display_name(peer_id: int) -> String:
	return String(_network_player_names.get(peer_id, _default_player_name(peer_id)))

func _set_network_player_name(peer_id: int, player_name: String) -> void:
	_network_player_names[peer_id] = _sanitize_player_name(player_name, peer_id)
	if peer_id == get_local_peer_id():
		_local_player_name = String(_network_player_names[peer_id])
		if _player_name_input != null and _player_name_input.text != _local_player_name:
			_player_name_input.text = _local_player_name
	_update_other_player_status_ui()
	_update_network_ui_state()

func _sync_local_player_name_to_network() -> void:
	var local_peer_id := get_local_peer_id()
	_local_player_name = _sanitize_player_name(_player_name_input.text if _player_name_input != null else _local_player_name, local_peer_id)
	if _player_name_input != null and _player_name_input.text != _local_player_name:
		_player_name_input.text = _local_player_name
	if _network_mode == "offline":
		_set_network_player_name(1, _local_player_name)
		return
	if _network_mode == "host":
		_set_network_player_name(local_peer_id, _local_player_name)
		if multiplayer.multiplayer_peer != null:
			for peer_id in multiplayer.get_peers():
				rpc_id(peer_id, "_rpc_update_player_name", local_peer_id, _local_player_name)
		return
	if _network_mode == "client" and multiplayer.multiplayer_peer != null:
		_set_network_player_name(local_peer_id, _local_player_name)
		rpc_id(1, "_rpc_submit_player_name", _local_player_name)

func _ensure_network_player_state(peer_id: int) -> Dictionary:
	if not _network_player_states.has(peer_id):
		_network_player_states[peer_id] = {
			"hp": hp,
			"max_hp": max_hp,
			"alive": true,
		}
	return _network_player_states[peer_id]

func _get_network_player_state(peer_id: int) -> Dictionary:
	return _ensure_network_player_state(peer_id)

func is_player_alive(peer_id: int) -> bool:
	return bool(_get_network_player_state(peer_id).get("alive", true))

func _sync_local_hp_cache() -> void:
	var local_state := _get_network_player_state(get_local_peer_id())
	hp = int(local_state.get("hp", hp))
	max_hp = int(local_state.get("max_hp", max_hp))

func _apply_player_alive_visual(peer_id: int) -> void:
	var player = _network_player_nodes.get(peer_id, null)
	if player == null or not is_instance_valid(player):
		_update_other_player_status_ui()
		return
	var alive := is_player_alive(peer_id)
	if player.has_method("set_eliminated"):
		player.set_eliminated(not alive)
	elif player.has_method("set_direct_input_enabled"):
		player.set_direct_input_enabled(alive and peer_id == get_local_peer_id())
		player.modulate = Color(1.0, 1.0, 1.0, 1.0) if alive else Color(0.7, 0.7, 0.7, 0.45)
	if peer_id == get_local_peer_id():
		_sync_local_hp_cache()
		update_hp_label()
	_update_other_player_status_ui()

func _all_players_eliminated() -> bool:
	for peer_id in _network_player_states.keys():
		if bool(_network_player_states[peer_id].get("alive", true)):
			return false
	return not _network_player_states.is_empty()

func _heal_player(peer_id: int, amount: int) -> void:
	if amount <= 0:
		return
	var state := _get_network_player_state(peer_id)
	if not bool(state.get("alive", true)):
		return
	var current_max_hp := int(state.get("max_hp", max_hp))
	state["hp"] = mini(int(state.get("hp", current_max_hp)) + amount, current_max_hp)
	if peer_id == get_local_peer_id():
		_sync_local_hp_cache()
		update_hp_label()

func _increase_player_max_hp(peer_id: int, amount: int, heal_amount: int = 0) -> void:
	var state := _get_network_player_state(peer_id)
	state["max_hp"] = int(state.get("max_hp", max_hp)) + amount
	state["hp"] = mini(int(state.get("hp", hp)) + heal_amount, int(state.get("max_hp", max_hp)))
	if peer_id == get_local_peer_id():
		_sync_local_hp_cache()
		update_hp_label()

func _broadcast_player_state_snapshot() -> void:
	if _network_mode != "host" or multiplayer.multiplayer_peer == null:
		return
	_broadcast_player_states()

func damage_player(peer_id: int, amount: int) -> void:
	if amount <= 0:
		return
	var state := _get_network_player_state(peer_id)
	if not bool(state.get("alive", true)):
		return
	state["hp"] = maxi(int(state.get("hp", hp)) - amount, 0)
	if int(state["hp"]) <= 0:
		state["alive"] = false
	_apply_player_alive_visual(peer_id)
	_broadcast_player_state_snapshot()
	if _all_players_eliminated():
		game_over()

func _end_match(did_win: bool) -> void:
	if _network_mode == "host" and multiplayer.multiplayer_peer != null:
		for peer_id in multiplayer.get_peers():
			rpc_id(peer_id, "_rpc_match_end", did_win)
	_show_end_screen(did_win)

func is_match_active() -> bool:
	return _network_mode == "offline" or _network_match_started

func _is_network_lobby_active() -> bool:
	return _network_mode != "offline" and not _network_match_started and not is_game_over

func _apply_pause_state() -> void:
	if is_game_over:
		get_tree().paused = true
		return
	var manual_pause_active := _is_manually_paused and (_network_mode == "offline" or _network_mode == "host")
	get_tree().paused = manual_pause_active or _is_network_lobby_active()

func _connected_player_count() -> int:
	var count := 0
	for peer_id in _network_player_nodes.keys():
		var player = _network_player_nodes[peer_id]
		if player != null and is_instance_valid(player):
			count += 1
	return count

func _selected_room_can_join() -> bool:
	var manual_targets := _get_manual_discovery_targets()
	if not manual_targets.is_empty():
		return true
	if _room_list == null:
		return false
	var selected_items := _room_list.get_selected_items()
	if selected_items.is_empty():
		return false
	var room_key := String(_room_list.get_item_metadata(selected_items[0]))
	if not _lan_discovered_rooms.has(room_key):
		return false
	var room: Dictionary = _lan_discovered_rooms[room_key]
	return not bool(room.get("started", false)) and int(room.get("players", 0)) < int(room.get("max_players", NETWORK_MAX_PLAYERS))

func _start_network_match() -> void:
	if _network_mode != "host" or _network_match_started:
		return
	_network_match_started = true
	_is_manually_paused = false
	_apply_pause_state()
	if _pause_label != null:
		_pause_label.visible = false
	_apply_bgm_mix()
	if not is_game_over and $SpawnTimer.is_stopped():
		$SpawnTimer.start()
	for peer_id in multiplayer.get_peers():
		rpc_id(peer_id, "_rpc_set_match_started", true)
	_broadcast_lan_room_presence()
	_close_network_panel()
	_update_network_ui_state()

func _find_local_player() -> Node2D:
	for player in get_active_players():
		if player != null and bool(player.get("is_local_player")):
			return player
	return _players[0] if not _players.is_empty() else null

func spawn_player_instance(spawn_position: Vector2, color_key: String, local_control: bool = false) -> Node2D:
	var player: Node2D = PLAYER_SCENE.instantiate()
	player.bullet_scene = PLAYER_BULLET_SCENE
	player.global_position = spawn_position
	if player.has_method("configure_player"):
		player.configure_player(color_key, local_control, local_control)
	add_child(player)
	return player

func get_player_node() -> Node2D:
	if not is_instance_valid(_player_node):
		_player_node = _find_local_player()
	return _player_node

func get_player_position() -> Vector2:
	var player := get_player_node()
	if is_instance_valid(player):
		return player.global_position
	return get_active_arena_size() * 0.5

func get_nearest_player_node(from_position: Vector2) -> Node2D:
	var nearest: Node2D = null
	var best_dist_sq := INF
	for player in get_active_players():
		if not is_instance_valid(player):
			continue
		if not is_player_alive(get_player_peer_id(player)):
			continue
		var dist_sq: float = player.global_position.distance_squared_to(from_position)
		if dist_sq < best_dist_sq:
			best_dist_sq = dist_sq
			nearest = player
	return nearest

func get_nearest_player_position(from_position: Vector2) -> Vector2:
	var player := get_nearest_player_node(from_position)
	if is_instance_valid(player):
		return player.global_position
	return get_active_arena_size() * 0.5

func get_player_hit_target(from_position: Vector2, radius: float) -> Node2D:
	var best_player: Node2D = null
	var best_dist_sq := INF
	for player in get_active_players():
		if not is_instance_valid(player):
			continue
		if not is_player_alive(get_player_peer_id(player)):
			continue
		var dist_sq: float = player.global_position.distance_squared_to(from_position)
		if dist_sq <= radius * radius and dist_sq < best_dist_sq:
			best_dist_sq = dist_sq
			best_player = player
	return best_player

func get_player_hp_ratio() -> float:
	var local_state := _get_network_player_state(get_local_peer_id())
	return clampf(float(local_state.get("hp", hp)) / maxf(float(local_state.get("max_hp", max_hp)), 1.0), 0.0, 1.0)

func get_player_dash_cooldown() -> float:
	var player := get_player_node()
	if is_instance_valid(player):
		if player.has_method("get_dash_cooldown"):
			return float(player.get_dash_cooldown())
		return float(player.get("_dash_cd"))
	return 0.0

func is_player_ready_to_fire() -> bool:
	var player := get_player_node()
	if is_instance_valid(player):
		if player.has_method("is_ready_to_fire"):
			return bool(player.is_ready_to_fire())
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

func _setup_other_player_status_ui() -> void:
	_other_players_status_panel = MarginContainer.new()
	_other_players_status_panel.name = "OtherPlayersStatusPanel"
	_other_players_status_panel.visible = false
	_other_players_status_panel.anchor_left = 0.5
	_other_players_status_panel.anchor_right = 0.5
	_other_players_status_panel.anchor_top = 0.0
	_other_players_status_panel.anchor_bottom = 0.0
	_other_players_status_panel.offset_left = -250.0
	_other_players_status_panel.offset_right = 250.0
	_other_players_status_panel.offset_top = 10.0
	_other_players_status_panel.offset_bottom = 140.0
	_other_players_status_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_other_players_status_panel.add_theme_constant_override("margin_left", 8)
	_other_players_status_panel.add_theme_constant_override("margin_right", 8)
	_other_players_status_panel.add_theme_constant_override("margin_top", 4)
	_other_players_status_panel.add_theme_constant_override("margin_bottom", 4)
	$CanvasLayer.add_child(_other_players_status_panel)

	var root := VBoxContainer.new()
	root.alignment = BoxContainer.ALIGNMENT_CENTER
	root.add_theme_constant_override("separation", 2)
	_other_players_status_panel.add_child(root)

	_other_players_status_list = HBoxContainer.new()
	_other_players_status_list.alignment = BoxContainer.ALIGNMENT_CENTER
	_other_players_status_list.add_theme_constant_override("separation", 18)
	root.add_child(_other_players_status_list)
	_update_other_player_status_ui()

func _get_player_status_color(color_key: String) -> Color:
	var palette: Dictionary = PlayerPalette.get_palette(color_key)
	return Color(palette.get("bullet_main", Color(0.85, 0.9, 1.0, 1.0)))

func _get_player_color_name(color_key: String) -> String:
	match color_key:
		"red":
			return "红"
		"white":
			return "白"
		"green":
			return "绿"
		_:
			return "蓝"

func _create_player_status_model(color_key: String) -> Control:
	var viewport_container := SubViewportContainer.new()
	viewport_container.stretch = true
	viewport_container.custom_minimum_size = Vector2(84.0, 48.0)
	viewport_container.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var viewport := SubViewport.new()
	viewport.disable_3d = true
	viewport.transparent_bg = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport.size = Vector2i(84, 48)
	viewport_container.add_child(viewport)

	var preview_root := Node2D.new()
	preview_root.position = Vector2(24.0, 24.0)
	viewport.add_child(preview_root)

	var preview_player: Node2D = PLAYER_SCENE.instantiate()
	preview_player.preview_mode = true
	preview_root.add_child(preview_player)
	preview_player.scale = Vector2(0.78, 0.78)
	preview_player.rotation = -0.12
	if preview_player.has_method("configure_player"):
		preview_player.configure_player(color_key, false, false)
	return viewport_container

func _build_other_player_status_row(peer_id: int, color_key: String, current_hp: int, current_max_hp: int, alive: bool) -> Control:
	var row := VBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 2)
	row.custom_minimum_size = Vector2(132.0, 0.0)

	var model_holder := CenterContainer.new()
	model_holder.custom_minimum_size = Vector2(90.0, 48.0)
	model_holder.add_child(_create_player_status_model(color_key))
	row.add_child(model_holder)

	var info_column := VBoxContainer.new()
	info_column.alignment = BoxContainer.ALIGNMENT_CENTER
	info_column.custom_minimum_size = Vector2(132.0, 0.0)
	info_column.add_theme_constant_override("separation", 2)
	row.add_child(info_column)

	var info_label := Label.new()
	info_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	info_label.add_theme_font_size_override("font_size", 15)
	info_label.add_theme_color_override("font_color", _get_player_status_color(color_key))
	info_label.add_theme_color_override("font_shadow_color", Color(0.0, 0.0, 0.0, 0.85))
	info_label.add_theme_constant_override("shadow_offset_x", 2)
	info_label.add_theme_constant_override("shadow_offset_y", 2)
	info_label.text = "%s%s" % [
		get_player_display_name(peer_id),
		"  已淘汰" if not alive else ""
	]
	info_column.add_child(info_label)

	var hp_bar := ProgressBar.new()
	hp_bar.min_value = 0.0
	hp_bar.max_value = float(maxi(current_max_hp, 1))
	hp_bar.value = float(clampi(current_hp, 0, maxi(current_max_hp, 1)))
	hp_bar.show_percentage = false
	hp_bar.custom_minimum_size = Vector2(115.0, 12.0)
	hp_bar.add_theme_stylebox_override("fill", _make_status_bar_fill_style(alive))
	hp_bar.add_theme_stylebox_override("background", _make_status_bar_background_style())
	info_column.add_child(hp_bar)

	var hp_label := Label.new()
	hp_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hp_label.add_theme_font_size_override("font_size", 12)
	hp_label.add_theme_color_override("font_color", Color(0.9, 1.0, 0.9, 0.95) if alive else Color(0.82, 0.82, 0.82, 0.9))
	hp_label.add_theme_color_override("font_shadow_color", Color(0.0, 0.0, 0.0, 0.85))
	hp_label.add_theme_constant_override("shadow_offset_x", 2)
	hp_label.add_theme_constant_override("shadow_offset_y", 2)
	hp_label.text = "%d / %d" % [maxi(current_hp, 0), maxi(current_max_hp, 0)]
	info_column.add_child(hp_label)

	return row

func _make_status_bar_fill_style(alive: bool) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.16, 0.92, 0.34, 0.95) if alive else Color(0.42, 0.42, 0.42, 0.9)
	style.corner_radius_top_left = 5
	style.corner_radius_top_right = 5
	style.corner_radius_bottom_left = 5
	style.corner_radius_bottom_right = 5
	return style

func _make_status_bar_background_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.08, 0.12, 0.08, 0.72)
	style.corner_radius_top_left = 5
	style.corner_radius_top_right = 5
	style.corner_radius_bottom_left = 5
	style.corner_radius_bottom_right = 5
	return style

func _update_other_player_status_ui() -> void:
	if _other_players_status_panel == null or _other_players_status_list == null:
		return
	for child in _other_players_status_list.get_children():
		child.queue_free()
	if is_game_over or _network_mode == "offline":
		_other_players_status_panel.visible = false
		return
	var local_peer_id := get_local_peer_id()
	var peer_ids := _network_player_nodes.keys()
	peer_ids.sort()
	var has_other_players := false
	for peer_id_variant in peer_ids:
		var peer_id := int(peer_id_variant)
		if peer_id == local_peer_id:
			continue
		var player = _network_player_nodes.get(peer_id, null)
		if player == null or not is_instance_valid(player):
			continue
		var state := _get_network_player_state(peer_id)
		var alive := bool(state.get("alive", true))
		var current_hp := int(state.get("hp", max_hp))
		var current_max_hp := int(state.get("max_hp", max_hp))
		var color_key := String(_network_player_colors.get(peer_id, "blue"))
		_other_players_status_list.add_child(_build_other_player_status_row(peer_id, color_key, current_hp, current_max_hp, alive))
		has_other_players = true
	_other_players_status_panel.visible = has_other_players

func _setup_network_ui() -> void:
	_network_menu_button = Button.new()
	_network_menu_button.name = "NetworkMenuButton"
	_network_menu_button.text = "联机"
	_network_menu_button.visible = false
	_network_menu_button.process_mode = Node.PROCESS_MODE_ALWAYS
	_network_menu_button.anchor_left = 1.0
	_network_menu_button.anchor_right = 1.0
	_network_menu_button.anchor_top = 1.0
	_network_menu_button.anchor_bottom = 1.0
	_network_menu_button.offset_left = -150.0
	_network_menu_button.offset_right = -20.0
	_network_menu_button.offset_top = -70.0
	_network_menu_button.offset_bottom = -20.0
	_network_menu_button.pressed.connect(_toggle_network_panel)
	$CanvasLayer.add_child(_network_menu_button)

	_network_panel = PanelContainer.new()
	_network_panel.name = "NetworkPanel"
	_network_panel.visible = false
	_network_panel.process_mode = Node.PROCESS_MODE_ALWAYS
	_network_panel.anchor_left = 0.5
	_network_panel.anchor_right = 0.5
	_network_panel.anchor_top = 0.5
	_network_panel.anchor_bottom = 0.5
	_network_panel.offset_left = -280.0
	_network_panel.offset_right = 280.0
	_network_panel.offset_top = -220.0
	_network_panel.offset_bottom = 220.0
	$CanvasLayer.add_child(_network_panel)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 10)
	_network_panel.add_child(root)

	var title := Label.new()
	title.text = "局域网联机"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 28)
	root.add_child(title)

	_network_status_label = Label.new()
	_network_status_label.text = "未联机"
	_network_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root.add_child(_network_status_label)

	_network_player_count_label = Label.new()
	_network_player_count_label.text = "当前人数: 1/4"
	_network_player_count_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root.add_child(_network_player_count_label)

	var player_name_row := HBoxContainer.new()
	root.add_child(player_name_row)
	var player_name_label := Label.new()
	player_name_label.text = "玩家名"
	player_name_row.add_child(player_name_label)
	_player_name_input = LineEdit.new()
	_player_name_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_player_name_input.placeholder_text = "输入自己的名字"
	_player_name_input.text = _local_player_name
	_player_name_input.text_submitted.connect(_on_player_name_submitted)
	_player_name_input.focus_exited.connect(_on_player_name_focus_exited)
	player_name_row.add_child(_player_name_input)

	var direct_address_row := HBoxContainer.new()
	root.add_child(direct_address_row)
	var direct_address_label := Label.new()
	direct_address_label.text = "直连IP"
	direct_address_row.add_child(direct_address_label)
	_direct_address_input = LineEdit.new()
	_direct_address_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_direct_address_input.placeholder_text = "输入 ZeroTier/VPN IP，支持逗号分隔多个地址"
	_direct_address_input.text = _manual_discovery_targets
	_direct_address_input.text_changed.connect(_on_direct_address_text_changed)
	_direct_address_input.text_submitted.connect(_on_direct_address_submitted)
	direct_address_row.add_child(_direct_address_input)

	var room_name_row := HBoxContainer.new()
	root.add_child(room_name_row)
	var room_name_label := Label.new()
	room_name_label.text = "房间名"
	room_name_row.add_child(room_name_label)
	_room_name_input = LineEdit.new()
	_room_name_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_room_name_input.placeholder_text = "输入房间名称"
	_room_name_input.text = _network_room_name
	room_name_row.add_child(_room_name_input)

	var action_row := HBoxContainer.new()
	action_row.add_theme_constant_override("separation", 8)
	root.add_child(action_row)
	_host_room_button = Button.new()
	_host_room_button.text = "创建房间"
	_host_room_button.pressed.connect(_on_host_room_pressed)
	action_row.add_child(_host_room_button)
	_start_match_button = Button.new()
	_start_match_button.text = "开始游戏"
	_start_match_button.pressed.connect(_on_start_match_pressed)
	action_row.add_child(_start_match_button)
	_refresh_rooms_button = Button.new()
	_refresh_rooms_button.text = "刷新房间"
	_refresh_rooms_button.pressed.connect(_on_refresh_rooms_pressed)
	action_row.add_child(_refresh_rooms_button)
	_join_room_button = Button.new()
	_join_room_button.text = "加入选中房间"
	_join_room_button.pressed.connect(_on_join_room_pressed)
	action_row.add_child(_join_room_button)
	_leave_room_button = Button.new()
	_leave_room_button.text = "离开房间"
	_leave_room_button.pressed.connect(_on_leave_room_pressed)
	action_row.add_child(_leave_room_button)

	_room_list = ItemList.new()
	_room_list.custom_minimum_size = Vector2(0.0, 220.0)
	_room_list.item_selected.connect(_on_room_selected)
	_room_list.item_activated.connect(_on_room_activated)
	root.add_child(_room_list)

	var help_label := Label.new()
	help_label.text = "局域网会自动广播；ZeroTier/VPN 这类虚拟网络请在上方填写对方 IP，再点刷新或直接加入。"
	help_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(help_label)

	_update_network_pause_ui_visibility()
	_update_network_ui_state()

func _update_network_pause_ui_visibility() -> void:
	var should_show := _is_manually_paused and not is_game_over and (_network_mode == "offline" or _network_mode == "host")
	if _network_menu_button != null:
		_network_menu_button.visible = should_show
	if not should_show and _network_panel != null:
		_network_panel.visible = false

func _toggle_network_panel() -> void:
	if _network_panel == null:
		return
	_network_panel.visible = not _network_panel.visible
	if _network_panel.visible:
		if _room_name_input != null:
			_room_name_input.text = _network_room_name
		if _network_mode != "host":
			_start_lan_discovery_listener()
		_prune_discovered_rooms()
		_refresh_room_list_ui()
	else:
		if _network_mode == "offline":
			_stop_lan_discovery_listener()
	_update_network_ui_state()

func _close_network_panel() -> void:
	if _network_panel == null:
		return
	_network_panel.visible = false
	if _network_mode == "offline":
		_stop_lan_discovery_listener()
	_update_network_ui_state()

func _sanitize_room_name(room_name: String) -> String:
	var cleaned := room_name.strip_edges()
	if cleaned.is_empty():
		return "Bubble Tanks Room"
	return cleaned.left(32)

func _sanitize_manual_targets(text: String) -> String:
	var cleaned := text.strip_edges()
	if cleaned.is_empty():
		return ""
	return cleaned.replace("\n", ",").replace(";", ",")

func _get_manual_discovery_targets() -> Array[String]:
	_manual_discovery_targets = _sanitize_manual_targets(_direct_address_input.text if _direct_address_input != null else _manual_discovery_targets)
	if _direct_address_input != null and _direct_address_input.text != _manual_discovery_targets:
		_direct_address_input.text = _manual_discovery_targets
	var targets: Array[String] = []
	for raw_part in _manual_discovery_targets.split(",", false):
		var address := raw_part.strip_edges()
		if address.is_empty() or targets.has(address):
			continue
		targets.append(address)
	return targets

func _set_network_status(text: String, color: Color = Color(0.92, 0.95, 1.0, 1.0)) -> void:
	if _network_status_label == null:
		return
	_network_status_label.text = text
	_network_status_label.add_theme_color_override("font_color", color)

func _update_network_ui_state() -> void:
	if _network_player_count_label != null:
		_network_player_count_label.text = "当前人数: %d/%d" % [_connected_player_count(), NETWORK_MAX_PLAYERS]
	_update_other_player_status_ui()
	if _player_name_input != null and not _player_name_input.has_focus() and _player_name_input.text != _local_player_name:
		_player_name_input.text = _local_player_name
	if _direct_address_input != null and not _direct_address_input.has_focus() and _direct_address_input.text != _manual_discovery_targets:
		_direct_address_input.text = _manual_discovery_targets
	if _room_name_input != null:
		_room_name_input.editable = _network_mode == "offline"
	if _host_room_button != null:
		_host_room_button.disabled = _network_mode != "offline"
	if _start_match_button != null:
		_start_match_button.visible = _network_mode == "host"
		_start_match_button.disabled = _network_mode != "host" or _network_match_started
	if _refresh_rooms_button != null:
		_refresh_rooms_button.disabled = _network_mode == "host"
	if _join_room_button != null:
		_join_room_button.disabled = _network_mode != "offline" or not _selected_room_can_join()
	if _leave_room_button != null:
		_leave_room_button.disabled = _network_mode == "offline"
	match _network_mode:
		"host":
			var host_status := "等待房主开始" if not _network_match_started else "游戏进行中"
			_set_network_status("房主房间: %s | %s" % [_network_room_name, host_status], Color(0.45, 1.0, 0.5, 1.0))
		"client":
			var client_status := "等待房主开始" if not _network_match_started else "已加入房间"
			_set_network_status(client_status, Color(0.5, 0.85, 1.0, 1.0))
		_:
			_set_network_status("未联机", Color(0.92, 0.95, 1.0, 1.0))

func _on_player_name_submitted(_text: String) -> void:
	_sync_local_player_name_to_network()

func _on_player_name_focus_exited() -> void:
	_sync_local_player_name_to_network()

func _on_direct_address_text_changed(new_text: String) -> void:
	_manual_discovery_targets = _sanitize_manual_targets(new_text)
	_update_network_ui_state()

func _on_direct_address_submitted(_text: String) -> void:
	_manual_discovery_targets = _sanitize_manual_targets(_direct_address_input.text if _direct_address_input != null else _manual_discovery_targets)
	if _selected_room_can_join():
		_on_join_room_pressed()

func _start_lan_discovery_listener() -> void:
	if _lan_discovery_listener != null:
		return
	_lan_discovery_listener = PacketPeerUDP.new()
	var err := _lan_discovery_listener.bind(NETWORK_DISCOVERY_PORT, "0.0.0.0")
	if err != OK:
		_lan_discovery_listener = null
		_set_network_status("房间发现监听失败", Color(1.0, 0.45, 0.35, 1.0))
		return

func _stop_lan_discovery_listener() -> void:
	if _lan_discovery_listener == null:
		return
	_lan_discovery_listener.close()
	_lan_discovery_listener = null

func _start_lan_discovery_broadcast() -> void:
	_stop_lan_discovery_broadcast()
	_lan_discovery_broadcaster = PacketPeerUDP.new()
	_lan_discovery_broadcaster.set_broadcast_enabled(true)
	var err := _lan_discovery_broadcaster.bind(0, "0.0.0.0")
	if err != OK:
		_lan_discovery_broadcaster = null
		_set_network_status("房间广播启动失败", Color(1.0, 0.45, 0.35, 1.0))
		return
	_lan_discovery_broadcast_timer = 0.0

func _stop_lan_discovery_broadcast() -> void:
	if _lan_discovery_broadcaster == null:
		return
	_lan_discovery_broadcaster.close()
	_lan_discovery_broadcaster = null

func _process_lan_discovery(delta: float) -> void:
	if _lan_discovery_broadcaster != null and _network_mode == "host":
		_lan_discovery_broadcast_timer -= delta
		if _lan_discovery_broadcast_timer <= 0.0:
			_lan_discovery_broadcast_timer = NETWORK_DISCOVERY_INTERVAL
			_broadcast_lan_room_presence()
	if _lan_discovery_listener != null:
		while _lan_discovery_listener.get_available_packet_count() > 0:
			var packet := _lan_discovery_listener.get_packet()
			var packet_ip := _lan_discovery_listener.get_packet_ip()
			var parsed = JSON.parse_string(packet.get_string_from_utf8())
			if parsed is Dictionary:
				_handle_discovery_packet(parsed, packet_ip)
		_prune_discovered_rooms()

func _handle_discovery_packet(payload: Dictionary, source_ip: String) -> void:
	if String(payload.get("game", "")) != "bubble-tanks":
		return
	var packet_type := String(payload.get("type", "presence"))
	if packet_type == "discover_request":
		if _network_mode == "host":
			_send_lan_room_presence_to(source_ip)
		return
	_register_discovered_room(payload, source_ip)

func _broadcast_lan_room_presence() -> void:
	if _lan_discovery_broadcaster == null:
		return
	_send_lan_room_presence_to("255.255.255.255")

func _send_lan_room_presence_to(target_ip: String) -> void:
	if _lan_discovery_broadcaster == null:
		return
	var payload := {
		"game": "bubble-tanks",
		"type": "presence",
		"room_name": _network_room_name,
		"port": NETWORK_PORT,
		"players": _network_player_nodes.size(),
		"max_players": NETWORK_MAX_PLAYERS,
		"started": _network_match_started,
	}
	_lan_discovery_broadcaster.set_dest_address(target_ip, NETWORK_DISCOVERY_PORT)
	_lan_discovery_broadcaster.put_packet(JSON.stringify(payload).to_utf8_buffer())

func _send_unicast_discovery_requests() -> void:
	if _lan_discovery_broadcaster == null:
		_start_lan_discovery_broadcast()
	if _lan_discovery_broadcaster == null:
		return
	var payload := {
		"game": "bubble-tanks",
		"type": "discover_request",
	}
	var request_data := JSON.stringify(payload).to_utf8_buffer()
	for target_ip in _get_manual_discovery_targets():
		_lan_discovery_broadcaster.set_dest_address(target_ip, NETWORK_DISCOVERY_PORT)
		_lan_discovery_broadcaster.put_packet(request_data)

func _register_discovered_room(payload: Dictionary, source_ip: String) -> void:
	if String(payload.get("game", "")) != "bubble-tanks":
		return
	var room_key := "%s:%d" % [source_ip, int(payload.get("port", NETWORK_PORT))]
	_lan_discovered_rooms[room_key] = {
		"ip": source_ip,
		"port": int(payload.get("port", NETWORK_PORT)),
		"room_name": String(payload.get("room_name", "Bubble Tanks Room")),
		"players": int(payload.get("players", 1)),
		"max_players": int(payload.get("max_players", NETWORK_MAX_PLAYERS)),
		"started": bool(payload.get("started", false)),
		"last_seen": Time.get_ticks_msec() / 1000.0,
	}
	_refresh_room_list_ui()

func _prune_discovered_rooms() -> void:
	var now := Time.get_ticks_msec() / 1000.0
	for room_key in _lan_discovered_rooms.keys():
		var room: Dictionary = _lan_discovered_rooms[room_key]
		if now - float(room.get("last_seen", now)) > NETWORK_DISCOVERY_ROOM_TTL:
			_lan_discovered_rooms.erase(room_key)
	_refresh_room_list_ui()

func _refresh_room_list_ui() -> void:
	if _room_list == null:
		return
	var selected_room_key := ""
	var selected_items := _room_list.get_selected_items()
	if not selected_items.is_empty():
		selected_room_key = String(_room_list.get_item_metadata(selected_items[0]))
	_room_list.clear()
	var room_keys := _lan_discovered_rooms.keys()
	room_keys.sort()
	for room_key in room_keys:
		var room: Dictionary = _lan_discovered_rooms[room_key]
		var state_text := "游戏中" if bool(room.get("started", false)) else "等待中"
		var line := "%s  |  %s  |  %d/%d  |  %s" % [
			String(room.get("room_name", "Bubble Tanks Room")),
			String(room.get("ip", "0.0.0.0")),
			int(room.get("players", 1)),
			int(room.get("max_players", NETWORK_MAX_PLAYERS)),
			state_text,
		]
		var item_index := _room_list.add_item(line)
		_room_list.set_item_metadata(item_index, room_key)
		if room_key == selected_room_key:
			_room_list.select(item_index)
	_update_network_ui_state()

func _selected_room_address() -> String:
	if _room_list == null:
		var targets := _get_manual_discovery_targets()
		return targets[0] if not targets.is_empty() else ""
	var selected_items := _room_list.get_selected_items()
	if selected_items.is_empty():
		var targets := _get_manual_discovery_targets()
		return targets[0] if not targets.is_empty() else ""
	var room_key := String(_room_list.get_item_metadata(selected_items[0]))
	if not _lan_discovered_rooms.has(room_key):
		var targets := _get_manual_discovery_targets()
		return targets[0] if not targets.is_empty() else ""
	return String((_lan_discovered_rooms[room_key] as Dictionary).get("ip", ""))

func _on_host_room_pressed() -> void:
	if _network_mode != "offline":
		return
	_sync_local_player_name_to_network()
	_manual_discovery_targets = _sanitize_manual_targets(_direct_address_input.text if _direct_address_input != null else _manual_discovery_targets)
	_network_room_name = _sanitize_room_name(_room_name_input.text if _room_name_input != null else _network_room_name)
	_stop_lan_discovery_listener()
	_debug_host_session(_network_room_name)
	if _network_panel != null:
		_network_panel.visible = true
	_update_network_ui_state()

func _on_refresh_rooms_pressed() -> void:
	if _network_mode == "host":
		return
	_manual_discovery_targets = _sanitize_manual_targets(_direct_address_input.text if _direct_address_input != null else _manual_discovery_targets)
	_lan_discovered_rooms.clear()
	_start_lan_discovery_listener()
	_send_unicast_discovery_requests()
	_refresh_room_list_ui()
	_set_network_status("正在搜索房间...", Color(0.9, 0.9, 0.45, 1.0))

func _on_join_room_pressed() -> void:
	if _network_mode != "offline":
		return
	_sync_local_player_name_to_network()
	_manual_discovery_targets = _sanitize_manual_targets(_direct_address_input.text if _direct_address_input != null else _manual_discovery_targets)
	var address := _selected_room_address()
	if address.is_empty():
		_set_network_status("请先选择房间或填写直连IP", Color(1.0, 0.65, 0.35, 1.0))
		return
	_stop_lan_discovery_listener()
	_debug_join_session(address)

func _on_start_match_pressed() -> void:
	_start_network_match()

func _on_leave_room_pressed() -> void:
	if _network_mode == "offline":
		return
	_shutdown_network_session()
	_set_network_status("已离开房间", Color(0.92, 0.95, 1.0, 1.0))

func _on_room_selected(_index: int) -> void:
	_update_network_ui_state()

func _on_room_activated(_index: int) -> void:
	_on_join_room_pressed()


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.keycode == KEY_ESCAPE \
			and event.pressed and not event.echo and not is_game_over:
		if _network_mode == "client":
			_toggle_network_panel()
		else:
			_toggle_pause()
		get_viewport().set_input_as_handled()
	elif event is InputEventKey and event.keycode == KEY_F5 \
			and event.pressed and not event.echo:
		_toggle_network_panel()
		get_viewport().set_input_as_handled()
	elif event is InputEventKey and event.keycode == KEY_F6 \
			and event.pressed and not event.echo and not is_game_over:
		_debug_host_session(_network_room_name)
		get_viewport().set_input_as_handled()
	elif event is InputEventKey and event.keycode == KEY_F7 \
			and event.pressed and not event.echo and not is_game_over:
		_debug_join_session("127.0.0.1")
		get_viewport().set_input_as_handled()
	elif event is InputEventKey and event.keycode == KEY_F9 \
			and event.pressed and not event.echo and not is_game_over:
		_activate_performance_test_mode()
		get_viewport().set_input_as_handled()
	elif event is InputEventKey and event.keycode == KEY_F10 \
			and event.pressed and not event.echo and not is_game_over:
		_debug_refresh_boss()
		get_viewport().set_input_as_handled()

func _activate_performance_test_mode() -> void:
	_resume_game_for_performance_test()
	_performance_test_mode = true
	if max_hp < PERFORMANCE_TEST_HP:
		max_hp = PERFORMANCE_TEST_HP
	hp = PERFORMANCE_TEST_HP
	update_hp_label()
	var player := get_player_node()
	if is_instance_valid(player) and player.has_method("ensure_skill_stack"):
		player.ensure_skill_stack("spread", 5)
	_spawn_regular_bosses_for_test(PERFORMANCE_TEST_REGULAR_BOSSES, PERFORMANCE_TEST_PLAYER_LEVEL)

func _resume_game_for_performance_test() -> void:
	_is_manually_paused = false
	get_tree().paused = false
	if _pause_label != null:
		_pause_label.visible = false
	for child in get_children():
		if child is LevelUpUI:
			child.queue_free()
	_apply_bgm_mix(true)
	_ensure_bgm_playing()

func _debug_host_session(room_name: String = "Bubble Tanks Room") -> void:
	if _network_mode != "offline":
		return
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(NETWORK_PORT, NETWORK_MAX_PLAYERS)
	if err != OK:
		push_error("[Net] create_server failed: %s" % err)
		return
	multiplayer.multiplayer_peer = peer
	_network_mode = "host"
	_network_room_name = _sanitize_room_name(room_name)
	_network_match_started = false
	_network_player_nodes.clear()
	_network_player_colors.clear()
	_network_player_names.clear()
	_network_player_inputs.clear()
	_network_player_states.clear()
	_network_input_send_timer = NETWORK_INPUT_SEND_INTERVAL
	_network_state_broadcast_timer = NETWORK_STATE_BROADCAST_INTERVAL
	_network_enemy_state_broadcast_timer = NETWORK_ENEMY_STATE_BROADCAST_INTERVAL
	_network_enemy_nodes.clear()
	_network_next_enemy_id = 1
	_register_or_update_network_player(multiplayer.get_unique_id(), "blue", get_active_arena_size() * 0.5)
	_set_network_player_name(multiplayer.get_unique_id(), _local_player_name)
	$SpawnTimer.stop()
	_start_lan_discovery_listener()
	_start_lan_discovery_broadcast()
	_broadcast_player_state_snapshot()
	_apply_pause_state()
	_update_network_ui_state()
	print("[Net] Hosting LAN session on port %d" % NETWORK_PORT)

func _debug_join_session(address: String) -> void:
	if _network_mode != "offline":
		return
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(address, NETWORK_PORT)
	if err != OK:
		push_error("[Net] create_client failed: %s" % err)
		return
	multiplayer.multiplayer_peer = peer
	_network_mode = "client"
	_network_match_started = false
	_network_player_nodes.clear()
	_network_player_colors.clear()
	_network_player_names.clear()
	_network_player_inputs.clear()
	_network_player_states.clear()
	_network_input_send_timer = 0.0
	_network_state_broadcast_timer = NETWORK_STATE_BROADCAST_INTERVAL
	_network_enemy_state_broadcast_timer = NETWORK_ENEMY_STATE_BROADCAST_INTERVAL
	_network_enemy_nodes.clear()
	_stop_lan_discovery_broadcast()
	_apply_pause_state()
	if is_instance_valid(_player_node) and _player_node.has_method("configure_player"):
		_player_node.configure_player("blue", true, true)
	$SpawnTimer.stop()
	print("[Net] Joining LAN session %s:%d" % [address, NETWORK_PORT])

func _choose_next_player_color() -> String:
	for color_key in PLAYER_COLOR_ORDER:
		if not _network_player_colors.values().has(color_key):
			return color_key
	return PLAYER_COLOR_ORDER[_network_player_colors.size() % PLAYER_COLOR_ORDER.size()]

func _scene_kind_from_packed_scene(scene: PackedScene) -> String:
	if scene == enemy_scene:
		return "basic"
	if scene == compound_enemy_scene:
		return "compound"
	if scene == boss_scene:
		return "boss"
	return ""

func _enemy_kind_from_node(enemy: Node) -> String:
	if enemy is EnemyBoss:
		return "boss"
	if enemy.is_in_group("compound_enemy"):
		return "compound"
	if enemy.is_in_group("enemy"):
		return "basic"
	return ""

func _network_spawn_position(peer_id: int) -> Vector2:
	var arena := get_active_arena_size()
	var slots := [
		arena * Vector2(0.35, 0.35),
		arena * Vector2(0.65, 0.35),
		arena * Vector2(0.35, 0.65),
		arena * Vector2(0.65, 0.65),
	]
	return slots[(peer_id - 1) % slots.size()]

func _register_or_update_network_player(peer_id: int, color_key: String, spawn_position: Vector2) -> void:
	var is_local_peer := peer_id == multiplayer.get_unique_id()
	var player = _network_player_nodes.get(peer_id, null)
	if player == null or not is_instance_valid(player):
		if is_local_peer:
			player = get_player_node()
			if not is_instance_valid(player):
				player = spawn_player_instance(spawn_position, color_key, true)
		else:
			player = spawn_player_instance(spawn_position, color_key, false)
		_network_player_nodes[peer_id] = player
	_ensure_network_player_state(peer_id)
	var direct_input := is_local_peer
	if player.has_method("configure_player"):
		player.configure_player(color_key, is_local_peer, direct_input)
	if player.has_method("set_network_peer_id"):
		player.set_network_peer_id(peer_id)
	player.global_position = spawn_position
	_network_player_colors[peer_id] = color_key
	if not _network_player_names.has(peer_id):
		_network_player_names[peer_id] = _default_player_name(peer_id)
	if is_local_peer:
		_player_node = player
	_apply_player_alive_visual(peer_id)
	_update_other_player_status_ui()

func _remove_network_player(peer_id: int) -> void:
	var player = _network_player_nodes.get(peer_id, null)
	_network_player_nodes.erase(peer_id)
	_network_player_colors.erase(peer_id)
	_network_player_names.erase(peer_id)
	_network_player_inputs.erase(peer_id)
	_network_player_states.erase(peer_id)
	if player == null or not is_instance_valid(player):
		_update_other_player_status_ui()
		return
	if player == _player_node:
		_update_other_player_status_ui()
		return
	player.queue_free()
	_update_other_player_status_ui()

func notify_player_fire(peer_id: int, spawn_position: Vector2, spawn_rotation: float, total: int, pierce_hits: int, color_key: String) -> void:
	if _network_mode == "client" and multiplayer.multiplayer_peer != null and peer_id == get_local_peer_id():
		rpc_id(1, "_rpc_submit_player_fire", spawn_position, spawn_rotation, total, pierce_hits, color_key)
		return
	if _network_mode != "host" or multiplayer.multiplayer_peer == null:
		return
	for remote_peer_id in multiplayer.get_peers():
		if remote_peer_id == peer_id:
			continue
		rpc_id(remote_peer_id, "_rpc_replicate_player_fire", peer_id, spawn_position, spawn_rotation, total, pierce_hits, color_key)

func _spawn_authoritative_player_fire(spawn_position: Vector2, spawn_rotation: float, total: int, pierce_hits: int, color_key: String) -> void:
	var spread := deg_to_rad(18.0)
	for i in range(total):
		var offset := (i - (total - 1) / 2.0) * spread
		var bullet: Area2D = acquire_player_bullet()
		if bullet.has_method("activate_from_pool"):
			bullet.activate_from_pool(spawn_position, spawn_rotation + offset, pierce_hits, color_key, false)

func notify_enemy_fire(spawn_position: Vector2, spawn_direction: Vector2, spawn_speed: float) -> void:
	if _network_mode != "host" or multiplayer.multiplayer_peer == null:
		return
	for remote_peer_id in multiplayer.get_peers():
		rpc_id(remote_peer_id, "_rpc_replicate_enemy_fire", spawn_position, spawn_direction, spawn_speed)

func _broadcast_network_enemy_spawn(enemy_id: int, target_peer_id: int = 0) -> void:
	if _network_mode != "host" or multiplayer.multiplayer_peer == null:
		return
	var enemy = _network_enemy_nodes.get(enemy_id, null)
	if enemy == null or not is_instance_valid(enemy):
		return
	var enemy_kind := _enemy_kind_from_node(enemy)
	if enemy_kind.is_empty():
		return
	var spawn_payload: Dictionary = {}
	if enemy_kind == "boss":
		if not enemy.has_method("is_network_spawn_ready") or not enemy.is_network_spawn_ready():
			return
		if enemy.has_method("get_network_spawn_payload"):
			spawn_payload = enemy.get_network_spawn_payload()
	if target_peer_id > 0:
		rpc_id(target_peer_id, "_rpc_spawn_enemy", enemy_id, enemy_kind, enemy.global_position, spawn_payload)
		return
	for peer_id in multiplayer.get_peers():
		rpc_id(peer_id, "_rpc_spawn_enemy", enemy_id, enemy_kind, enemy.global_position, spawn_payload)

func _on_network_enemy_spawn_payload_ready(enemy_id: int) -> void:
	_broadcast_network_enemy_spawn(enemy_id)

func _register_network_enemy_instance(enemy: Node, enemy_kind: String) -> void:
	if enemy_kind.is_empty():
		return
	var enemy_id := _network_next_enemy_id
	_network_next_enemy_id += 1
	_network_enemy_nodes[enemy_id] = enemy
	if enemy.has_method("configure_network_entity"):
		enemy.configure_network_entity(enemy_id, true)
	if enemy_kind == "boss" and enemy.has_signal("network_spawn_payload_ready"):
		enemy.network_spawn_payload_ready.connect(_on_network_enemy_spawn_payload_ready.bind(enemy_id), CONNECT_ONE_SHOT)
	enemy.tree_exited.connect(_on_network_enemy_tree_exited.bind(enemy_id), CONNECT_ONE_SHOT)
	_broadcast_network_enemy_spawn(enemy_id)

func _spawn_network_enemy_instance(enemy_id: int, enemy_kind: String, spawn_position: Vector2, spawn_payload: Dictionary = {}) -> void:
	if _network_enemy_nodes.has(enemy_id):
		return
	var scene: PackedScene = null
	match enemy_kind:
		"basic":
			scene = enemy_scene
		"compound":
			scene = compound_enemy_scene
		"boss":
			scene = boss_scene
		_:
			return
	var enemy = scene.instantiate()
	if enemy_kind == "boss":
		enemy.authority_simulation = false
		enemy.is_network_replica = true
		enemy.is_final_boss = bool(spawn_payload.get("is_final_boss", false))
		enemy.network_spawn_payload = spawn_payload.duplicate(true)
	enemy.global_position = spawn_position
	$Enemies.add_child(enemy)
	if enemy.has_method("configure_network_entity"):
		enemy.configure_network_entity(enemy_id, false)
	_network_enemy_nodes[enemy_id] = enemy

func _on_network_enemy_tree_exited(enemy_id: int) -> void:
	_network_enemy_nodes.erase(enemy_id)
	if _network_mode != "host" or multiplayer.multiplayer_peer == null:
		return
	for peer_id in multiplayer.get_peers():
		rpc_id(peer_id, "_rpc_remove_enemy", enemy_id)

func _on_peer_connected(peer_id: int) -> void:
	if _network_mode != "host":
		return
	var color_key := _choose_next_player_color()
	var spawn_position := _network_spawn_position(peer_id)
	for existing_peer_id in _network_player_nodes.keys():
		var existing_player = _network_player_nodes[existing_peer_id]
		if existing_player == null or not is_instance_valid(existing_player):
			continue
		rpc_id(peer_id, "_rpc_register_player", int(existing_peer_id), String(_network_player_colors.get(existing_peer_id, "blue")), existing_player.global_position)
		rpc_id(peer_id, "_rpc_update_player_name", int(existing_peer_id), get_player_display_name(int(existing_peer_id)))
	_register_or_update_network_player(peer_id, color_key, spawn_position)
	_set_network_player_name(peer_id, _default_player_name(peer_id))
	for remote_peer_id in multiplayer.get_peers():
		rpc_id(remote_peer_id, "_rpc_register_player", peer_id, color_key, spawn_position)
		rpc_id(remote_peer_id, "_rpc_update_player_name", peer_id, get_player_display_name(peer_id))
	rpc_id(peer_id, "_rpc_set_match_started", _network_match_started)
	for enemy_id in _network_enemy_nodes.keys():
		var enemy = _network_enemy_nodes[enemy_id]
		if enemy == null or not is_instance_valid(enemy):
			continue
		_broadcast_network_enemy_spawn(int(enemy_id), peer_id)
	_broadcast_player_state_snapshot()
	_broadcast_lan_room_presence()
	_update_network_ui_state()
	print("[Net] Peer connected: %d" % peer_id)

func _on_peer_disconnected(peer_id: int) -> void:
	if _network_mode == "offline":
		return
	_remove_network_player(peer_id)
	if _network_mode == "host":
		for remote_peer_id in multiplayer.get_peers():
			rpc_id(remote_peer_id, "_rpc_remove_player", peer_id)
		_broadcast_lan_room_presence()
	_update_network_ui_state()
	print("[Net] Peer disconnected: %d" % peer_id)

func _on_connected_to_server() -> void:
	_is_manually_paused = false
	_apply_pause_state()
	_close_network_panel()
	if _pause_label != null:
		_pause_label.visible = false
	_apply_bgm_mix()
	_sync_local_player_name_to_network()
	_update_network_ui_state()
	_set_network_status("已连接到主机", Color(0.5, 0.85, 1.0, 1.0))
	print("[Net] Connected to server")

func _on_connection_failed() -> void:
	_set_network_status("连接房间失败", Color(1.0, 0.45, 0.35, 1.0))
	print("[Net] Connection failed")
	_shutdown_network_session()

func _on_server_disconnected() -> void:
	_set_network_status("已与主机断开", Color(1.0, 0.65, 0.35, 1.0))
	print("[Net] Server disconnected")
	_shutdown_network_session()

func _shutdown_network_session() -> void:
	_stop_lan_discovery_listener()
	_stop_lan_discovery_broadcast()
	_network_mode = "offline"
	_network_match_started = true
	_network_player_inputs.clear()
	_network_player_colors.clear()
	_network_player_names.clear()
	_network_player_states.clear()
	_network_enemy_nodes.clear()
	for peer_id in _network_player_nodes.keys():
		if int(peer_id) != 1:
			_remove_network_player(int(peer_id))
	_network_player_nodes.clear()
	multiplayer.multiplayer_peer = null
	if is_instance_valid(_player_node) and _player_node.has_method("configure_player"):
		_player_node.configure_player("blue", true, true)
		if _player_node.has_method("set_network_peer_id"):
			_player_node.set_network_peer_id(1)
	_network_player_nodes[1] = _player_node
	_network_player_colors[1] = "blue"
	_network_player_names[1] = _local_player_name
	_ensure_network_player_state(1)
	_apply_player_alive_visual(1)
	_network_next_enemy_id = 1
	_apply_pause_state()
	if _network_panel != null and _network_panel.visible:
		_start_lan_discovery_listener()
	_update_network_ui_state()

@rpc("authority", "reliable")
func _rpc_register_player(peer_id: int, color_key: String, spawn_position: Vector2) -> void:
	_register_or_update_network_player(peer_id, color_key, spawn_position)
	_update_network_ui_state()

@rpc("authority", "reliable")
func _rpc_update_player_name(peer_id: int, player_name: String) -> void:
	_set_network_player_name(peer_id, player_name)

@rpc("any_peer", "reliable")
func _rpc_submit_player_name(player_name: String) -> void:
	if _network_mode != "host":
		return
	var sender_id := multiplayer.get_remote_sender_id()
	var resolved_name := _sanitize_player_name(player_name, sender_id)
	_set_network_player_name(sender_id, resolved_name)
	for peer_id in multiplayer.get_peers():
		rpc_id(peer_id, "_rpc_update_player_name", sender_id, resolved_name)

@rpc("authority", "reliable")
func _rpc_set_match_started(started: bool) -> void:
	_network_match_started = started
	if started:
		_is_manually_paused = false
		if not is_game_over and $SpawnTimer.is_stopped():
			$SpawnTimer.start()
		_close_network_panel()
		if _pause_label != null:
			_pause_label.visible = false
	else:
		$SpawnTimer.stop()
	_apply_pause_state()
	_apply_bgm_mix()
	_update_network_ui_state()

@rpc("authority", "reliable")
func _rpc_remove_player(peer_id: int) -> void:
	_remove_network_player(peer_id)
	_update_network_ui_state()

@rpc("authority", "reliable")
func _rpc_spawn_enemy(enemy_id: int, enemy_kind: String, spawn_position: Vector2, spawn_payload: Dictionary = {}) -> void:
	if _network_mode != "client":
		return
	_spawn_network_enemy_instance(enemy_id, enemy_kind, spawn_position, spawn_payload)

@rpc("any_peer", "unreliable")
func _rpc_submit_input(input_state: Dictionary) -> void:
	if _network_mode != "host":
		return
	var sender_id := multiplayer.get_remote_sender_id()
	if not is_player_alive(sender_id):
		return
	_network_player_inputs[sender_id] = input_state

@rpc("any_peer", "unreliable")
func _rpc_submit_player_fire(spawn_position: Vector2, spawn_rotation: float, total: int, pierce_hits: int, color_key: String) -> void:
	if _network_mode != "host":
		return
	var sender_id := multiplayer.get_remote_sender_id()
	if not is_player_alive(sender_id):
		return
	_spawn_authoritative_player_fire(spawn_position, spawn_rotation, total, pierce_hits, color_key)
	notify_player_fire(sender_id, spawn_position, spawn_rotation, total, pierce_hits, color_key)

@rpc("authority", "unreliable")
func _rpc_receive_player_states(states: Array) -> void:
	if _network_mode != "client":
		return
	for entry in states:
		var peer_id := int(entry.get("peer_id", 0))
		var player = _network_player_nodes.get(peer_id, null)
		if player == null or not is_instance_valid(player):
			continue
		var state := _get_network_player_state(peer_id)
		state["hp"] = int(entry.get("hp", state.get("hp", hp)))
		state["max_hp"] = int(entry.get("max_hp", state.get("max_hp", max_hp)))
		state["alive"] = bool(entry.get("alive", state.get("alive", true)))
		_apply_player_alive_visual(peer_id)
		if player.has_method("apply_authoritative_state"):
			player.apply_authoritative_state(entry.get("pos", player.global_position), float(entry.get("rot", player.rotation)))
	_update_other_player_status_ui()

@rpc("authority", "reliable")
func _rpc_match_end(did_win: bool) -> void:
	_show_end_screen(did_win)

@rpc("authority", "unreliable")
func _rpc_receive_enemy_states(states: Array) -> void:
	if _network_mode != "client":
		return
	for entry in states:
		var enemy_id := int(entry.get("enemy_id", 0))
		var enemy = _network_enemy_nodes.get(enemy_id, null)
		if enemy == null or not is_instance_valid(enemy):
			continue
		if enemy.has_method("apply_network_entity_state"):
			enemy.apply_network_entity_state(entry.get("state", {}))

@rpc("authority", "reliable")
func _rpc_remove_enemy(enemy_id: int) -> void:
	var enemy = _network_enemy_nodes.get(enemy_id, null)
	_network_enemy_nodes.erase(enemy_id)
	if enemy != null and is_instance_valid(enemy):
		enemy.queue_free()

@rpc("authority", "reliable")
func _rpc_replicate_player_fire(peer_id: int, spawn_position: Vector2, spawn_rotation: float, total: int, pierce_hits: int, color_key: String) -> void:
	if _network_mode != "client":
		return
	var spread := deg_to_rad(18.0)
	for i in range(total):
		var offset := (i - (total - 1) / 2.0) * spread
		var bullet: Area2D = acquire_player_bullet()
		if bullet.has_method("activate_from_pool"):
			bullet.activate_from_pool(spawn_position, spawn_rotation + offset, pierce_hits, color_key, true)

@rpc("authority", "unreliable")
func _rpc_replicate_enemy_fire(spawn_position: Vector2, spawn_direction: Vector2, spawn_speed: float) -> void:
	if _network_mode != "client":
		return
	var bullet: Area2D = acquire_enemy_bullet()
	if bullet.has_method("activate_from_pool"):
		bullet.activate_from_pool(spawn_position, spawn_direction, spawn_speed, true)

func _spawn_regular_bosses_for_test(target_count: int, player_level: int) -> void:
	if boss_scene == null:
		return
	EnemyBoss.apply_player_level(player_level)
	BossEvolution.set_satellite_bounds(
		BASE_BOSS_MIN_SATELLITES + player_level * 6,
		BASE_BOSS_MAX_SATELLITES + player_level * 10
	)
	_pending_regular_boss_spawns = 0
	_regular_boss_spawn_cooldown = 0.0
	var live_count := _count_live_regular_bosses()
	for _i in range(maxi(0, target_count - live_count)):
		var boss: Node2D = boss_scene.instantiate()
		boss.force_sync_generation = true
		_place_spawned_enemy(boss)
		$Enemies.add_child(boss)
		if _network_mode == "host":
			_register_network_enemy_instance(boss, "boss")


func _toggle_pause() -> void:
	if _network_mode == "client":
		_toggle_network_panel()
		return
	# 升级界面打开时不允许手动暂停
	if get_tree().paused and not _is_manually_paused:
		return
	_is_manually_paused = not _is_manually_paused
	_apply_pause_state()
	_pause_label.visible = _is_manually_paused
	_update_network_pause_ui_visibility()
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
	_regular_boss_spawn_cooldown = maxf(_regular_boss_spawn_cooldown, REGULAR_BOSS_RESPAWN_INTERVAL)
	_boss_bubbles += 1
	$Turret.set_boss_bubbles(_boss_bubbles)
	if _boss_bubbles >= BUBBLES_PER_LEVEL:
		_boss_bubbles = 0
		_player_level += 1
		# 升级奖励：所有存活玩家血量上限 +50，当前血量也 +50
		for peer_id in _network_player_states.keys():
			_increase_player_max_hp(int(peer_id), 50, 50)
		_broadcast_player_state_snapshot()
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
	_end_match(true)

func _spawn_final_boss() -> void:
	call_deferred("_spawn_final_boss_deferred")

func _spawn_final_boss_deferred() -> void:
	if _final_boss_spawned or _final_boss_defeated:
		return
	_final_boss_spawned = true
	_pending_regular_boss_spawns = 0
	_regular_boss_spawn_cooldown = 0.0
	for boss in get_tree().get_nodes_in_group("boss"):
		boss.queue_free()
	var final_boss = boss_scene.instantiate()
	final_boss.is_final_boss = true
	_place_spawned_enemy(final_boss, FINAL_BOSS_SPAWN_MARGIN)
	$Enemies.add_child(final_boss)
	if _network_mode == "host":
		_register_network_enemy_instance(final_boss, "boss")

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
	for peer_id in _network_player_states.keys():
		_heal_player(int(peer_id), amount)
	_broadcast_player_state_snapshot()

func take_damage(amount: int, peer_id: int = -1) -> void:
	if is_game_over or _network_mode == "client":
		return
	var resolved_peer_id := peer_id if peer_id > 0 else get_local_peer_id()
	damage_player(resolved_peer_id, amount)

func game_over() -> void:
	_end_match(false)

func _show_end_screen(did_win: bool) -> void:
	is_game_over = true
	_update_other_player_status_ui()
	_is_manually_paused = false
	_apply_pause_state()
	_update_network_pause_ui_visibility()
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
	_pending_regular_boss_spawns = 0
	_regular_boss_spawn_cooldown = 0.0
	var final_boss = boss_scene.instantiate()
	final_boss.is_final_boss = true
	_place_spawned_enemy(final_boss, FINAL_BOSS_SPAWN_MARGIN)
	$Enemies.add_child(final_boss)
	if _network_mode == "host":
		_register_network_enemy_instance(final_boss, "boss")

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
	_sync_local_hp_cache()
	var local_state := _get_network_player_state(get_local_peer_id())
	var alive := bool(local_state.get("alive", true))
	label.text = "HP: %d / %d" % [hp, max_hp] if alive else "HP: 0 / %d 观战中" % max_hp
	var ratio := float(hp) / maxf(float(max_hp), 1.0)
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
	return _count_live_regular_bosses() + _pending_regular_boss_spawns

func _count_live_regular_bosses() -> int:
	var count := 0
	for boss in get_tree().get_nodes_in_group("boss"):
		if boss.is_in_group("final_boss"):
			continue
		count += 1
	return count

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
	if _network_mode == "client":
		return
	if scene == boss_scene and not _should_spawn_regular_boss():
		return
	var enemy = scene.instantiate()
	_place_spawned_enemy(enemy)
	$Enemies.add_child(enemy)
	if _network_mode == "host":
		_register_network_enemy_instance(enemy, _scene_kind_from_packed_scene(scene))

func _queue_regular_boss_spawn() -> void:
	if not _should_spawn_regular_boss():
		return
	if _count_regular_bosses() >= MAX_REGULAR_BOSSES_ON_SCREEN:
		return
	_pending_regular_boss_spawns += 1

func _spawn_regular_boss_deferred() -> void:
	if _pending_regular_boss_spawns > 0:
		_pending_regular_boss_spawns -= 1
	if not _should_spawn_regular_boss():
		return
	if _count_regular_bosses() >= MAX_REGULAR_BOSSES_ON_SCREEN:
		return
	_spawn(boss_scene)
	_regular_boss_spawn_cooldown = REGULAR_BOSS_RESPAWN_INTERVAL

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
