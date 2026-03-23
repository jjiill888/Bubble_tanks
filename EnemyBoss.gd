class_name EnemyBoss
extends Node2D

signal network_spawn_payload_ready

# ═══════════════════════════════════════════════════════
#  常量
# ═══════════════════════════════════════════════════════
const CORE_HP_BASE  := 10     # 核心基础血量（提升生存性）
const FIRE_INTERVAL := 2.2
const SCORE_VALUE   := 15
const DUAL_CORE_START_LEVEL := 2
const DUAL_CORE_BASE_CHANCE := 0.18
const DUAL_CORE_MAX_CHANCE  := 0.32
const DUAL_CORE_GAP_MARGIN  := 36.0
const PLAYER_COLLISION_RADIUS := 20.0
const SINGLE_CORE_CONTACT_DAMAGE := 50
const DUAL_CORE_CONTACT_DAMAGE := 100
const ENEMY_BULLET_BASE_SPEED := 320.0
const FINAL_BOSS_CONTACT_DAMAGE := 160
const FINAL_BOSS_SPEED := 42.0
const REGULAR_BOSS_SPEED := 52.0
const FINAL_BOSS_CORE_COUNT := 5
const FINAL_BOSS_MIN_TOTAL_BUBBLES := 100
const FINAL_BOSS_MIN_SATELLITES_PER_CORE := 11
const FINAL_BOSS_MAX_SATELLITES_PER_CORE := 14
const FINAL_BOSS_CLEANUP_MARGIN := 760.0
const CONTACT_DAMAGE_INTERVAL := 1.0
const SHIELD_PROTECT_RADIUS := 118.0
const ARMOR_DAMAGE_FACTOR := 0.58
const LURE_MAX_PRESSURE := 0.45
const LURE_SPEED_BONUS := 0.22
const VISUAL_REFRESH_INTERVAL := 0.05

@export var speed: float = 38.0

# ═══════════════════════════════════════════════════════
#  动态参数（由 Main 在玩家升级时调用 apply_player_level）
# ═══════════════════════════════════════════════════════
static var _s_player_level:  int  = 0
static var _s_turret_count:  int  = 2    # 基础炮台数，随等级 +1
static var _s_spread_turret: bool = false # 第 2 级起首个炮塔为散射型
static var _s_fire_interval: float = FIRE_INTERVAL
static var _s_enemy_bullet_speed_multiplier: float = 1.0

static func apply_player_level(level: int) -> void:
	_s_player_level  = level
	_s_turret_count  = 2 + level
	_s_spread_turret = level >= 2
	_s_fire_interval = FIRE_INTERVAL * pow(0.95, level)
	_s_enemy_bullet_speed_multiplier = pow(1.05, level)
	print("[EnemyBoss] apply_player_level(%d) \u5b8c\u6210\uff0c_s_player_level = %d" % [level, _s_player_level])

# ═══════════════════════════════════════════════════════
#  预生成基因组池（等级 0 使用 boss_genomes.json）
# ═══════════════════════════════════════════════════════
const GENOME_FILE := "res://boss_genomes.json"
static var _json_pool:   Array = []
static var _json_loaded: bool  = false

class RegularSpawnBuildJob extends RefCounted:
	var raw_genomes: Array = []
	var player_level: int = 0
	var seed: int = 0

	func _init(job_raw_genomes: Array, job_player_level: int, job_seed: int) -> void:
		raw_genomes = job_raw_genomes
		player_level = job_player_level
		seed = job_seed

	func run() -> Dictionary:
		return EnemyBoss._build_regular_spawn_payload(raw_genomes, player_level, seed)

class FinalSpawnBuildJob extends RefCounted:
	var player_level: int = 0
	var seed: int = 0

	func _init(job_player_level: int, job_seed: int) -> void:
		player_level = job_player_level
		seed = job_seed

	func run() -> Dictionary:
		return EnemyBoss._build_final_spawn_payload(player_level, seed)

static func _load_json_pool() -> void:
	if _json_loaded:
		return
	_json_loaded = true
	if not FileAccess.file_exists(GENOME_FILE):
		return
	var f := FileAccess.open(GENOME_FILE, FileAccess.READ)
	if f == null:
		return
	var parsed = JSON.parse_string(f.get_as_text())
	f.close()
	if parsed is Array:
		_json_pool = parsed
		print("[EnemyBoss] 已加载 %d 个预生成基因组" % _json_pool.size())

static func _rngf(rng: RandomNumberGenerator = null) -> float:
	if rng != null:
		return rng.randf()
	return randf()

static func _rng_rangef(rng: RandomNumberGenerator, min_value: float, max_value: float) -> float:
	if rng != null:
		return rng.randf_range(min_value, max_value)
	return randf_range(min_value, max_value)

static func _rng_rangei(rng: RandomNumberGenerator, min_value: int, max_value: int) -> int:
	if rng != null:
		return rng.randi_range(min_value, max_value)
	return randi_range(min_value, max_value)

# ═══════════════════════════════════════════════════════
#  泡泡状态（内部类）
# ═══════════════════════════════════════════════════════
class BubbleState:
	var pos:     Vector2
	var radius:  float
	var hp:      int
	var max_hp:  int
	var damage_bank: float = 0.0
	var is_core: bool
	var module_kind: String = "normal"
	var cluster_id: int
	var allow_turret: bool = true
	var alive:   bool = true
	var area:    Area2D

var bubbles: Array = []
var is_final_boss := false
var force_sync_generation := false
var network_entity_id := 0
var authority_simulation := true
var is_network_replica := false
var network_spawn_payload: Dictionary = {}
var _network_spawn_payload_cache: Dictionary = {}
var _network_target_position := Vector2.ZERO
var _network_target_rotation := 0.0
var _network_target_turret_angles: Array = []
var _has_network_target := false
var _payload_turret_count_override := -1
var _payload_spread_turret_override := false
var _has_payload_spread_override := false

# ═══════════════════════════════════════════════════════
#  炮塔系统
# ═══════════════════════════════════════════════════════
var turret_indices: Array = []   # 宿主泡泡索引
var turret_angles:  Array = []   # 当前瞄准角
var turret_spread:  Array = []   # bool：是否为散射炮塔
var fire_timer: float = 0.0
var _turn_rate: float = 2.0
var _preferred_range: float = 180.0
var _orbit_weight: float = 0.5
var _orbit_dir: int = 1
var _aim_lead: float = 0.1
var _aggression_bias: float = 0.5
var _caution_bias: float = 0.5
var _ambush_bias: float = 0.5
var _finisher_bias: float = 0.5
var _preferred_tactic: String = "strafe"
var _current_tactic: String = "strafe"
var _utility_rethink_timer: float = 0.0
var _tactic_range_scale: float = 1.0
var _tactic_orbit_scale: float = 1.0
var _tactic_speed_scale: float = 1.0
var _tactic_fire_interval_scale: float = 1.0
var _tactic_aim_scale: float = 1.0
var _last_target_pos: Vector2 = Vector2.ZERO
var _target_velocity: Vector2 = Vector2.ZERO
var _has_target_sample: bool = false
var _visual_refresh_timer: float = 0.0

# ═══════════════════════════════════════════════════════
#  进化追踪
# ═══════════════════════════════════════════════════════
var _bids: Array = []   # BossEvolution 分配的 id（双核心时有两个）

var _boss_bubble_script = preload("res://BossBubble.gd")
var _bullet_scene       = preload("res://EnemyBullet.tscn")
var _contact_damage: int = SINGLE_CORE_CONTACT_DAMAGE
var _contact_overlap_time: float = 0.0
var _max_turrets_per_cluster: int = -1
var _max_bubble_extent: float = 0.0
var _generation_thread: Thread = null
var _generation_runner: RefCounted = null
var _generation_pending := false
var _generation_kind: String = ""
var _pending_raw_genomes: Array = []

# ═══════════════════════════════════════════════════════
#  生命周期
# ═══════════════════════════════════════════════════════
func _ready() -> void:
	add_to_group("boss")
	if is_final_boss:
		add_to_group("final_boss")
	if is_network_replica:
		_generation_pending = false
		visible = not network_spawn_payload.is_empty()
		if not network_spawn_payload.is_empty():
			_apply_spawn_payload(network_spawn_payload)
			_network_target_position = global_position
			_network_target_rotation = rotation
			_network_target_turret_angles = turret_angles.duplicate()
			_has_network_target = true
		set_process(false)
		return
	if is_final_boss:
		_begin_async_final_generation()
		return
	var genomes: Array = []
	if _s_player_level == 0:
		# 等级 0：使用预生成的 boss_genomes.json
		print("[EnemyBoss] 使用 JSON 基因组池，玩家等级: 0")
		_load_json_pool()
		if not _json_pool.is_empty():
			var entry = _json_pool[randi() % _json_pool.size()]
			# JSON 格式可能是 {"genome": {...}} 或直接是基因组
			genomes.append(entry.get("genome", entry))
		else:
			genomes.append(BossEvolution._fallback_genome())
	else:
		# 等级 1+：使用遗传算法进化的基因组
		print("[EnemyBoss] 使用遗传算法基因组，玩家等级: %d" % _s_player_level)
		genomes.append(_acquire_runtime_genome())
		if _should_spawn_dual_core():
			genomes.append(_acquire_runtime_genome())
			print("[EnemyBoss] 生成双核心 Boss，核心数: %d" % genomes.size())
	if force_sync_generation:
		_generate_from_genomes(genomes)
		return
	_begin_async_regular_generation(genomes)

func _exit_tree() -> void:
	_wait_for_generation_thread(false)

func _begin_async_regular_generation(raw_genomes: Array) -> void:
	_pending_raw_genomes = raw_genomes.duplicate(true)
	_generation_kind = "regular"
	visible = false
	_generation_pending = true
	var seed := int(Time.get_ticks_usec())
	_generation_runner = RegularSpawnBuildJob.new(_pending_raw_genomes.duplicate(true), _s_player_level, seed)
	_generation_thread = Thread.new()
	var err := _generation_thread.start(_generation_runner.run)
	if err != OK:
		_generation_thread = null
		_generation_runner = null
		_generation_pending = false
		_generation_kind = ""
		visible = true
		_generate_from_genomes(_pending_raw_genomes)

func _begin_async_final_generation() -> void:
	_generation_kind = "final"
	visible = false
	_generation_pending = true
	var seed := int(Time.get_ticks_usec())
	_generation_runner = FinalSpawnBuildJob.new(_s_player_level, seed)
	_generation_thread = Thread.new()
	var err := _generation_thread.start(_generation_runner.run)
	if err != OK:
		_generation_thread = null
		_generation_runner = null
		_generation_pending = false
		_generation_kind = ""
		visible = true
		_generate_final_boss_sync()

func _poll_async_generation() -> void:
	if _generation_thread == null:
		return
	if _generation_thread.is_alive():
		return
	var result = _generation_thread.wait_to_finish()
	_generation_thread = null
	_generation_runner = null
	if result is Dictionary and bool(result.get("ok", false)):
		_apply_spawn_payload(result)
		return
	_generation_pending = false
	var failed_kind := _generation_kind
	_generation_kind = ""
	visible = true
	if failed_kind == "final":
		_generate_final_boss_sync()
	else:
		_generate_from_genomes(_pending_raw_genomes)

func _wait_for_generation_thread(apply_payload: bool = true) -> void:
	if _generation_thread == null:
		return
	var result = _generation_thread.wait_to_finish()
	_generation_thread = null
	_generation_runner = null
	if apply_payload and _generation_pending and result is Dictionary and bool(result.get("ok", false)):
		_apply_spawn_payload(result)

func _apply_spawn_payload(payload: Dictionary) -> void:
	_generation_pending = false
	_generation_kind = ""
	_pending_raw_genomes.clear()
	_network_spawn_payload_cache = payload.duplicate(true)
	if payload.has("is_final_boss"):
		is_final_boss = bool(payload.get("is_final_boss", is_final_boss))
	if payload.has("turret_count"):
		_payload_turret_count_override = int(payload.get("turret_count", _payload_turret_count_override))
	if payload.has("spread_turret"):
		_payload_spread_turret_override = bool(payload.get("spread_turret", _payload_spread_turret_override))
		_has_payload_spread_override = true
	if payload.has("speed"):
		speed = float(payload.get("speed", speed))
	if payload.has("max_turrets_per_cluster"):
		_max_turrets_per_cluster = int(payload.get("max_turrets_per_cluster", _max_turrets_per_cluster))
	_apply_behavior_genes(payload.get("behavior_genome", {}))
	_contact_damage = int(payload.get("contact_damage", SINGLE_CORE_CONTACT_DAMAGE))
	_finale_from_payload(payload)
	visible = true
	if authority_simulation and not is_network_replica:
		network_spawn_payload_ready.emit()

func _finale_from_payload(payload: Dictionary) -> void:
	var data: Array = payload.get("data", [])
	var cluster_count: int = int(payload.get("cluster_count", 1))
	fire_timer = 0.0
	_contact_overlap_time = 0.0
	_finalize_from_data(data, cluster_count)

func _on_screen_exited() -> void:
	_cleanup_if_outside_bounds()

func _report_death() -> void:
	for bid in _bids:
		if int(bid) >= 0:
			BossEvolution.on_boss_died(int(bid))
	_bids.clear()
	var scene = get_tree().current_scene
	if is_final_boss and scene and scene.has_method("on_final_boss_killed"):
		scene.on_final_boss_killed()
	elif scene and scene.has_method("on_boss_killed"):
		scene.on_boss_killed()

func _generate_final_boss() -> void:
	_begin_async_final_generation()

func _generate_final_boss_sync() -> void:
	var payload := EnemyBoss._build_final_spawn_payload(_s_player_level, 0)
	_apply_spawn_payload(payload)

static func _build_final_spawn_payload(player_level: int, seed: int) -> Dictionary:
	var rng: RandomNumberGenerator = null
	if seed != 0:
		rng = RandomNumberGenerator.new()
		rng.seed = seed
	var behavior_genome := {
		"initial_heading": _rngf(rng) * TAU,
		"turn_rate": 0.85,
		"preferred_range": 260.0,
		"orbit_weight": 0.35,
		"orbit_dir": -1 if _rngf(rng) < 0.5 else 1,
		"aim_lead": 0.28,
	}
	var layout := EnemyBoss._build_final_core_layout(player_level, rng)
	var cores: Array = layout["cores"]
	var links: Array = layout["links"]
	var final_data: Array = []
	var cluster_members: Dictionary = {}
	for core in cores:
		var core_entry := {
			"pos": core["pos"],
			"local_pos": core["pos"],
			"radius": core["radius"],
			"hp": core["hp"],
			"is_core": true,
			"cluster_id": core["cluster_id"],
		}
		final_data.append(core_entry)
		cluster_members[int(core["cluster_id"])] = [core_entry]
	final_data.append_array(EnemyBoss._build_final_core_bridges(cores, links))
	for core in cores:
		var cluster_id := int(core["cluster_id"])
		EnemyBoss._grow_final_cluster_satellites(core, cluster_members[cluster_id], final_data, int(core["target_satellites"]), rng)
	if final_data.size() < FINAL_BOSS_MIN_TOTAL_BUBBLES:
		EnemyBoss._append_final_boss_padding(final_data, cores[0], FINAL_BOSS_MIN_TOTAL_BUBBLES - final_data.size())
	return {
		"ok": true,
		"is_final_boss": true,
		"turret_count": 2 + player_level,
		"spread_turret": player_level >= 2,
		"behavior_genome": behavior_genome,
		"contact_damage": FINAL_BOSS_CONTACT_DAMAGE,
		"speed": FINAL_BOSS_SPEED,
		"max_turrets_per_cluster": 4,
		"data": final_data,
		"cluster_count": FINAL_BOSS_CORE_COUNT,
	}

static func _build_final_core_layout(player_level: int, rng: RandomNumberGenerator = null) -> Dictionary:
	var cores: Array = []
	var links: Array = []
	for cluster_id in range(FINAL_BOSS_CORE_COUNT):
		var core_r := _rng_rangef(rng, 40.0, 50.0) if cluster_id == 0 else _rng_rangef(rng, 34.0, 44.0)
		var core_hp := CORE_HP_BASE + 20 + player_level * 3
		var target_satellites := _rng_rangei(rng, FINAL_BOSS_MIN_SATELLITES_PER_CORE, FINAL_BOSS_MAX_SATELLITES_PER_CORE)
		var envelope := core_r + 82.0 + target_satellites * 1.15
		if cluster_id == 0:
			cores.append({
				"cluster_id": cluster_id,
				"pos": Vector2.ZERO,
				"radius": core_r,
				"hp": core_hp,
				"target_satellites": target_satellites,
				"envelope": envelope,
			})
			continue

		var placed := false
		for attempt in range(96):
			var parent_idx := EnemyBoss._pick_final_core_parent(cores, rng)
			var parent = cores[parent_idx]
			var preferred_angle := -PI * 0.5 + TAU * float(cluster_id - 1) / float(maxi(FINAL_BOSS_CORE_COUNT - 1, 1))
			var angle := preferred_angle + _rng_rangef(rng, -1.0, 1.0) if attempt < 48 else _rngf(rng) * TAU
			var distance := maxf(float(parent["radius"]) + core_r + 64.0, float(parent["envelope"]) * 0.46 + envelope * 0.44 + _rng_rangef(rng, 12.0, 36.0))
			var candidate := (parent["pos"] as Vector2) + Vector2.RIGHT.rotated(angle) * distance
			if EnemyBoss._is_valid_final_core_position(candidate, envelope, cores):
				cores.append({
					"cluster_id": cluster_id,
					"pos": candidate,
					"radius": core_r,
					"hp": core_hp,
					"target_satellites": target_satellites,
					"envelope": envelope,
				})
				links.append([parent_idx, cluster_id])
				placed = true
				break
		if not placed:
			var fallback_parent_idx := maxi(0, cores.size() - 1)
			var fallback_parent = cores[fallback_parent_idx]
			var fallback_angle := _rngf(rng) * TAU
			var fallback_distance := maxf(float(fallback_parent["radius"]) + core_r + 72.0, float(fallback_parent["envelope"]) * 0.48 + envelope * 0.45 + 28.0)
			var fallback_pos := (fallback_parent["pos"] as Vector2) + Vector2.RIGHT.rotated(fallback_angle) * fallback_distance
			cores.append({
				"cluster_id": cluster_id,
				"pos": fallback_pos,
				"radius": core_r,
				"hp": core_hp,
				"target_satellites": target_satellites,
				"envelope": envelope,
			})
			links.append([fallback_parent_idx, cluster_id])
	return {"cores": cores, "links": links}

static func _pick_final_core_parent(cores: Array, rng: RandomNumberGenerator = null) -> int:
	if cores.size() <= 1:
		return 0
	var roll := _rngf(rng)
	if roll < 0.42:
		return 0
	if roll < 0.75:
		return maxi(0, cores.size() - 1 - _rng_rangei(rng, 0, mini(3, cores.size()) - 1))
	return _rng_rangei(rng, 0, cores.size() - 1)

static func _is_valid_final_core_position(candidate: Vector2, envelope: float, cores: Array) -> bool:
	for core in cores:
		if candidate.distance_to(core["pos"] as Vector2) < envelope * 0.52 + float(core["envelope"]) * 0.5 + 12.0:
			return false
	return true

static func _build_final_core_bridges(cores: Array, links: Array) -> Array:
	var existing: Array = []
	for core in cores:
		existing.append({"pos": core["pos"], "radius": core["radius"]})
	var bridges: Array = []
	for link in links:
		var from_core: Dictionary = cores[int(link[0])]
		var to_core: Dictionary = cores[int(link[1])]
		var bridge := EnemyBoss._build_final_core_bridge(from_core, to_core, existing)
		bridges.append_array(bridge)
		for bubble in bridge:
			existing.append({"pos": bubble["pos"], "radius": bubble["radius"]})
	return bridges

static func _build_final_core_bridge(from_core: Dictionary, to_core: Dictionary, existing: Array) -> Array:
	var start_center := from_core["pos"] as Vector2
	var end_center := to_core["pos"] as Vector2
	var direction := end_center - start_center
	if direction.length() <= 0.001:
		return []
	var dir := direction.normalized()
	var tangent := dir.orthogonal()
	var start := start_center + dir * float(from_core["radius"])
	var finish := end_center - dir * float(to_core["radius"])
	var gap := start.distance_to(finish)
	if gap <= 10.0:
		return []
	var base_radius := clampf(gap / 7.0, 12.0, 17.0)
	var bubble_count := maxi(4, int(ceil(gap / (base_radius * 1.55))))
	var sway_strength := minf(18.0, gap * 0.08)
	var bridge: Array = []
	for i in range(bubble_count):
		var t := float(i + 1) / float(bubble_count + 1)
		var radius := clampf(base_radius * (0.92 + 0.12 * sin(t * PI)), 11.0, 18.0)
		var sway := tangent * sin(t * PI) * sway_strength
		var pos := start.lerp(finish, t) + sway
		if EnemyBoss._bridge_pos_overlaps(existing, pos, radius):
			pos = start.lerp(finish, t)
		if EnemyBoss._bridge_pos_overlaps(existing, pos, radius):
			continue
		bridge.append({
			"pos": pos,
			"local_pos": pos,
			"radius": radius,
			"hp": maxi(2, int(round(radius / 7.0))),
			"is_core": false,
			"cluster_id": int(from_core["cluster_id"] if t < 0.5 else to_core["cluster_id"]),
			"allow_turret": false,
		})
		existing.append({"pos": pos, "radius": radius})
	return bridge

static func _grow_final_cluster_satellites(core: Dictionary, cluster_members: Array, all_data: Array, target_satellites: int, rng: RandomNumberGenerator = null) -> void:
	var core_pos := core["pos"] as Vector2
	var preferred_angle := core_pos.angle() if core_pos.length() > 0.01 else _rngf(rng) * TAU
	var stalls := 0
	while cluster_members.size() - 1 < target_satellites and stalls < 420:
		var parent_idx := EnemyBoss._pick_growth_parent_index(cluster_members, rng)
		var parent: Dictionary = cluster_members[parent_idx]
		var radius := _rng_rangef(rng, 11.0, 20.0)
		var hp := _rng_rangei(rng, 2, 4)
		var angle := EnemyBoss._pick_satellite_growth_angle(parent, core_pos, preferred_angle, rng)
		var distance := float(parent["radius"]) + radius + _rng_rangef(rng, -1.0, 4.0)
		var pos := (parent["pos"] as Vector2) + Vector2.RIGHT.rotated(angle) * distance
		if EnemyBoss._bridge_pos_overlaps(all_data, pos, radius):
			stalls += 1
			continue
		var bubble := {
			"pos": pos,
			"local_pos": pos,
			"radius": radius,
			"hp": hp,
			"is_core": false,
			"cluster_id": core["cluster_id"],
		}
		cluster_members.append(bubble)
		all_data.append(bubble)
		stalls = 0

	while cluster_members.size() - 1 < target_satellites:
		var fallback_parent_idx := EnemyBoss._find_farthest_growth_parent(cluster_members)
		var fallback_parent: Dictionary = cluster_members[fallback_parent_idx]
		var outward := ((fallback_parent["pos"] as Vector2) - core_pos).angle() if fallback_parent_idx != 0 else preferred_angle
		var fallback_radius := _rng_rangef(rng, 11.0, 17.0)
		var fallback_pos := (fallback_parent["pos"] as Vector2) + Vector2.RIGHT.rotated(outward) * (float(fallback_parent["radius"]) + fallback_radius + 3.0)
		if EnemyBoss._bridge_pos_overlaps(all_data, fallback_pos, fallback_radius):
			fallback_pos = (fallback_parent["pos"] as Vector2) + Vector2.RIGHT.rotated(_rngf(rng) * TAU) * (float(fallback_parent["radius"]) + fallback_radius + 3.0)
		var fallback_bubble := {
			"pos": fallback_pos,
			"local_pos": fallback_pos,
			"radius": fallback_radius,
			"hp": 3,
			"is_core": false,
			"cluster_id": core["cluster_id"],
		}
		cluster_members.append(fallback_bubble)
		all_data.append(fallback_bubble)

static func _pick_growth_parent_index(data: Array, rng: RandomNumberGenerator = null) -> int:
	if data.size() <= 1:
		return 0
	var roll := _rngf(rng)
	if roll < 0.18:
		return 0
	if roll < 0.55:
		return maxi(1, data.size() - 1 - _rng_rangei(rng, 0, mini(4, data.size() - 1) - 1))
	return _rng_rangei(rng, 0, data.size() - 1)

static func _pick_satellite_growth_angle(parent: Dictionary, core_pos: Vector2, preferred_angle: float, rng: RandomNumberGenerator = null) -> float:
	var parent_pos := parent["pos"] as Vector2
	if parent_pos.distance_to(core_pos) <= 0.01:
		if _rngf(rng) < 0.7:
			return preferred_angle + _rng_rangef(rng, -1.2, 1.2)
		return _rngf(rng) * TAU
	var base_angle := (parent_pos - core_pos).angle()
	if _rngf(rng) < 0.65:
		return base_angle + _rng_rangef(rng, -1.15, 1.15)
	if _rngf(rng) < 0.75:
		return preferred_angle + _rng_rangef(rng, -1.5, 1.5)
	return _rngf(rng) * TAU

static func _find_farthest_growth_parent(data: Array) -> int:
	var best_idx := 0
	var best_dist := -1.0
	var origin := data[0]["pos"] as Vector2
	for i in range(data.size()):
		var dist := (data[i]["pos"] as Vector2).distance_to(origin)
		if dist > best_dist:
			best_dist = dist
			best_idx = i
	return best_idx

static func _append_final_boss_padding(all_data: Array, center_core: Dictionary, needed: int) -> void:
	var center_pos := center_core["pos"] as Vector2
	var center_radius := float(center_core["radius"])
	for i in range(needed):
		var angle := TAU * float(i) / float(maxi(needed, 1))
		var radius := 12.0
		var pos := center_pos + Vector2.RIGHT.rotated(angle) * (center_radius + 40.0 + float(i / 6) * 18.0)
		if EnemyBoss._bridge_pos_overlaps(all_data, pos, radius):
			continue
		all_data.append({
			"pos": pos,
			"local_pos": pos,
			"radius": radius,
			"hp": 2,
			"is_core": false,
			"cluster_id": int(center_core["cluster_id"]),
			"allow_turret": false,
		})

func _acquire_runtime_genome() -> Dictionary:
	var g := BossEvolution.next_genome()
	var bid := int(g.get("_bid", -1))
	if bid >= 0:
		_bids.append(bid)
	return g

func _should_spawn_dual_core() -> bool:
	if _s_player_level < DUAL_CORE_START_LEVEL:
		return false
	var chance := minf(DUAL_CORE_BASE_CHANCE + 0.03 * float(_s_player_level - DUAL_CORE_START_LEVEL), DUAL_CORE_MAX_CHANCE)
	return randf() < chance

# ═══════════════════════════════════════════════════════
#  基因组解码
# ═══════════════════════════════════════════════════════
func _generate_from_genomes(raw_genomes: Array) -> void:
	var payload := EnemyBoss._build_regular_spawn_payload(raw_genomes, _s_player_level, 0)
	_apply_behavior_genes(payload.get("behavior_genome", {}))
	_contact_damage = int(payload.get("contact_damage", SINGLE_CORE_CONTACT_DAMAGE))
	_finale_from_payload(payload)

static func _build_regular_spawn_payload(raw_genomes: Array, player_level: int, seed: int) -> Dictionary:
	var rng: RandomNumberGenerator = null
	if seed != 0:
		rng = RandomNumberGenerator.new()
		rng.seed = seed
	var genomes: Array = []
	for raw in raw_genomes:
		genomes.append(raw.get("genome", raw))
	if genomes.is_empty():
		genomes.append(BossEvolution._fallback_genome())
	var cluster_data: Array = []
	var extents: Array = []
	for i in range(genomes.size()):
		var local_data: Array = EnemyBoss._build_cluster_local_data(genomes[i], i, player_level, rng)
		cluster_data.append(local_data)
		extents.append(EnemyBoss._cluster_extent(local_data))
	var offsets: Array = EnemyBoss._build_cluster_offsets(extents)
	var shifted_clusters: Array = []
	for i in range(cluster_data.size()):
		shifted_clusters.append(EnemyBoss._offset_cluster_data(cluster_data[i], offsets[i]))
	var merged: Array = []
	for shifted in shifted_clusters:
		merged.append_array(shifted)
	if shifted_clusters.size() == 2:
		merged.append_array(EnemyBoss._build_dual_core_bridge(shifted_clusters[0], shifted_clusters[1], rng))
	return {
		"ok": true,
		"is_final_boss": false,
		"turret_count": 2 + player_level,
		"spread_turret": player_level >= 2,
		"behavior_genome": genomes[0],
		"contact_damage": DUAL_CORE_CONTACT_DAMAGE if genomes.size() >= 2 else SINGLE_CORE_CONTACT_DAMAGE,
		"speed": REGULAR_BOSS_SPEED,
		"data": merged,
		"cluster_count": cluster_data.size(),
	}

static func _build_cluster_local_data(genome: Dictionary, cluster_id: int, player_level: int, rng: RandomNumberGenerator = null) -> Array:
	if genome.has("body") and genome.has("modules"):
		return EnemyBoss._build_modular_cluster_local_data(genome, cluster_id, player_level, rng)
	var core_r: float = float(genome.get("core_radius", 40.0))
	var core_hp: int  = CORE_HP_BASE + player_level * 2
	var data: Array = [{
		"pos": Vector2.ZERO,
		"local_pos": Vector2.ZERO,
		"radius": core_r,
		"hp": core_hp,
		"is_core": true,
		"module_kind": "core",
		"cluster_id": cluster_id,
	}]

	for gene in genome.get("satellites", []):
		var pidx: int = mini(int(gene.get("parent_idx", 0)), data.size() - 1)
		var angle: float = float(gene.get("angle", 0.0))
		var r: float = clampf(float(gene.get("radius", 15.0)), 10.0, 22.0)
		var hp: int = int(gene.get("hp", 2))
		var parent = data[pidx]
		var new_pos: Vector2 = parent["local_pos"] + Vector2(cos(angle), sin(angle)) * (parent["radius"] + r)

		var ok := true
		for ex in data:
			if new_pos.distance_to(ex["local_pos"]) < r + ex["radius"] - 1.5:
				ok = false
				break
		if ok:
			data.append({
				"pos": new_pos,
				"local_pos": new_pos,
				"radius": r,
				"hp": hp,
				"is_core": false,
				"module_kind": "normal",
				"cluster_id": cluster_id,
			})

	return data

static func _build_modular_cluster_local_data(genome: Dictionary, cluster_id: int, player_level: int, rng: RandomNumberGenerator = null) -> Array:
	var body: Dictionary = genome.get("body", {})
	var modules: Dictionary = genome.get("modules", {})
	var core_r := float(body.get("core_radius", 40.0))
	var core_hp := CORE_HP_BASE + player_level * 2
	var target_satellites := maxi(0, int(body.get("node_budget", 9)) - 1)
	var connection_style := String(body.get("connection_style", "tree"))
	var symmetry := String(body.get("symmetry", "none"))
	var branchiness := float(body.get("branchiness", 0.5))
	var outer_shell_bias := float(body.get("outer_shell_bias", 0.5))
	var weak_point_exposure := float(body.get("weak_point_exposure", 0.3))
	var max_extent := EnemyBoss._modular_max_extent(core_r, target_satellites, branchiness, outer_shell_bias, connection_style)
	var data: Array = [{
		"pos": Vector2.ZERO,
		"local_pos": Vector2.ZERO,
		"radius": core_r,
		"hp": core_hp,
		"is_core": true,
		"module_kind": "core",
		"cluster_id": cluster_id,
		"depth": 0,
	}]
	var stalls := 0

	while data.size() - 1 < target_satellites and stalls < 220:
		var parent_idx := EnemyBoss._pick_modular_parent_index(data, connection_style, branchiness, outer_shell_bias, rng)
		var parent: Dictionary = data[parent_idx]
		var depth := int(parent.get("depth", 0)) + 1
		var module_kind := EnemyBoss._pick_module_kind(modules, depth, target_satellites, outer_shell_bias, weak_point_exposure, rng)
		var radius := EnemyBoss._module_radius(module_kind, modules, rng)
		var hp := EnemyBoss._module_hp(module_kind, modules, rng)
		var angle := EnemyBoss._pick_modular_angle(data, parent, connection_style, symmetry, cluster_id, outer_shell_bias, max_extent, rng)
		var pos := (parent["local_pos"] as Vector2) + Vector2.RIGHT.rotated(angle) * (float(parent["radius"]) + radius)
		if pos.length() > max_extent or EnemyBoss._modular_pos_overlaps(data, pos, radius):
			stalls += 1
			continue
		data.append({
			"pos": pos,
			"local_pos": pos,
			"radius": radius,
			"hp": hp,
			"is_core": false,
			"module_kind": module_kind,
			"allow_turret": module_kind != "bridge" and module_kind != "shield",
			"cluster_id": cluster_id,
			"depth": depth,
		})
		stalls = 0

	return data

static func _modular_max_extent(core_radius: float, target_satellites: int, branchiness: float, outer_shell_bias: float, connection_style: String) -> float:
	var base_extent := core_radius + 52.0 + float(target_satellites) * (4.4 - branchiness * 1.3)
	base_extent += outer_shell_bias * 18.0
	match connection_style:
		"spine":
			base_extent *= 0.84
		"web":
			base_extent *= 0.94
		"shell":
			base_extent *= 0.9
	return clampf(base_extent, 88.0, 172.0)

static func _pick_modular_parent_index(data: Array, connection_style: String, branchiness: float, outer_shell_bias: float, rng: RandomNumberGenerator = null) -> int:
	if data.size() <= 1:
		return 0
	match connection_style:
		"spine":
			if _rngf(rng) < 0.72:
				return maxi(0, data.size() - 1 - _rng_rangei(rng, 0, mini(3, data.size()) - 1))
		"shell":
			if _rngf(rng) < 0.55 + outer_shell_bias * 0.25:
				return 0
		"ring":
			if _rngf(rng) < 0.45:
				return maxi(0, data.size() - 1 - _rng_rangei(rng, 0, mini(4, data.size()) - 1))
		"web":
			if _rngf(rng) < 0.35 + branchiness * 0.35:
				return _rng_rangei(rng, 0, data.size() - 1)
	if _rngf(rng) < 0.28 + branchiness * 0.32:
		return maxi(0, data.size() - 1 - _rng_rangei(rng, 0, mini(4, data.size()) - 1))
	if _rngf(rng) < 0.18:
		return 0
	return _rng_rangei(rng, 0, data.size() - 1)

static func _pick_modular_angle(data: Array, parent: Dictionary, connection_style: String, symmetry: String, cluster_id: int, outer_shell_bias: float, max_extent: float, rng: RandomNumberGenerator = null) -> float:
	var parent_pos := parent["local_pos"] as Vector2
	var outward := parent_pos.angle() if parent_pos.length() > 0.01 else (-PI * 0.5 + TAU * float(cluster_id + 1) / 7.0)
	var inward := outward + PI
	var extent_ratio := clampf(parent_pos.length() / maxf(max_extent, 1.0), 0.0, 1.0)
	var angle := _rngf(rng) * TAU
	match connection_style:
		"spine":
			angle = lerp_angle(outward + _rng_rangef(rng, -0.45, 0.45), inward + _rng_rangef(rng, -0.85, 0.85), extent_ratio * 0.62)
		"shell":
			angle = lerp_angle(outward + _rng_rangef(rng, -0.95, 0.95), inward + _rng_rangef(rng, -1.0, 1.0), extent_ratio * 0.38)
		"ring":
			angle = lerp_angle(outward + _rng_rangef(rng, -0.35, 0.35), inward + _rng_rangef(rng, -0.9, 0.9), extent_ratio * 0.54)
		"web":
			angle = lerp_angle(outward + _rng_rangef(rng, -1.45, 1.45), inward + _rng_rangef(rng, -1.1, 1.1), extent_ratio * 0.42)
		_:
			angle = lerp_angle(outward + _rng_rangef(rng, -1.1, 1.1), inward + _rng_rangef(rng, -0.95, 0.95), extent_ratio * 0.34)
	if _rngf(rng) < outer_shell_bias * 0.25:
		angle = outward + _rng_rangef(rng, -0.25, 0.25)
	if symmetry == "mirror_x":
		angle = absf(wrapf(angle, -PI, PI)) * signf(cos(angle) if cos(angle) != 0.0 else 1.0)
	elif symmetry == "radial" and parent_pos.length() <= 0.01:
		angle = (-PI * 0.5 + TAU * float((data.size() - 1) % 6) / 6.0) + _rng_rangef(rng, -0.18, 0.18)
	return angle

static func _pick_module_kind(modules: Dictionary, depth: int, target_satellites: int, outer_shell_bias: float, weak_point_exposure: float, rng: RandomNumberGenerator = null) -> String:
	var turret_ratio := float(modules.get("turret_ratio", 0.24))
	var armor_ratio := float(modules.get("armor_ratio", 0.24))
	var bridge_ratio := float(modules.get("bridge_ratio", 0.20))
	var shield_ratio := float(modules.get("shield_ratio", 0.12))
	var lure_ratio := float(modules.get("lure_ratio", 0.06))
	var turret_depth_bias := float(modules.get("turret_depth_bias", 0.6))
	var depth_ratio := float(depth) / maxf(float(target_satellites) * 0.25, 1.0)
	var roll := _rngf(rng)
	if depth <= 2 and roll < bridge_ratio:
		return "bridge"
	if depth <= 2 and roll < bridge_ratio + armor_ratio * (1.0 - weak_point_exposure * 0.5):
		return "armor"
	if depth <= 3 and roll < bridge_ratio + armor_ratio + shield_ratio * (1.0 - weak_point_exposure):
		return "shield"
	if depth_ratio >= turret_depth_bias and roll < bridge_ratio + armor_ratio + shield_ratio + turret_ratio:
		return "turret"
	if roll > 1.0 - lure_ratio * (0.45 + outer_shell_bias * 0.55):
		return "lure"
	return "normal"

static func _module_radius(module_kind: String, modules: Dictionary, rng: RandomNumberGenerator = null) -> float:
	match module_kind:
		"armor":
			return _rng_rangef(rng, 15.0, 22.0)
		"bridge":
			return clampf(_rng_rangef(rng, 10.0, 17.0) + float(modules.get("bridge_radius_bias", 0.0)), 9.0, 20.0)
		"shield":
			return _rng_rangef(rng, 12.0, 18.0)
		"turret":
			return _rng_rangef(rng, 13.0, 19.0)
		"lure":
			return _rng_rangef(rng, 14.0, 20.0)
		_:
			return _rng_rangef(rng, 11.0, 18.0)

static func _module_hp(module_kind: String, modules: Dictionary, rng: RandomNumberGenerator = null) -> int:
	match module_kind:
		"armor":
			return maxi(2, int(round(2.0 * float(modules.get("armor_hp_scale", 1.7)))))
		"bridge":
			return maxi(1, int(round(2.0 * float(modules.get("bridge_hp_scale", 1.1)))))
		"shield":
			return maxi(2, int(round(2.0 * float(modules.get("shield_hp_scale", 1.4)))))
		"turret":
			return _rng_rangei(rng, 2, 4)
		"lure":
			return _rng_rangei(rng, 1, 3)
		_:
			return _rng_rangei(rng, 2, 3)

static func _modular_pos_overlaps(data: Array, pos: Vector2, radius: float) -> bool:
	for ex in data:
		if pos.distance_to(ex["local_pos"] as Vector2) < radius + float(ex["radius"]) - 1.25:
			return true
	return false

static func _cluster_extent(data: Array) -> float:
	var extent := 0.0
	for d in data:
		extent = maxf(extent, (d["local_pos"] as Vector2).length() + float(d["radius"]))
	return extent

static func _build_cluster_offsets(extents: Array) -> Array:
	var offsets: Array = []
	if extents.size() == 1:
		offsets.append(Vector2.ZERO)
		return offsets
	if extents.size() == 2:
		var center_gap := float(extents[0]) + float(extents[1]) + DUAL_CORE_GAP_MARGIN
		offsets.append(Vector2.LEFT * center_gap * 0.5)
		offsets.append(Vector2.RIGHT * center_gap * 0.5)
		return offsets
	if extents.size() == FINAL_BOSS_CORE_COUNT:
		var center_extent := float(extents[0])
		var outer_extent := 0.0
		for i in range(1, extents.size()):
			outer_extent = maxf(outer_extent, float(extents[i]))
		offsets.append(Vector2.ZERO)
		var ring_radius := center_extent + outer_extent + 140.0
		for i in range(extents.size() - 1):
			var angle := -PI * 0.5 + TAU * float(i) / float(extents.size() - 1)
			offsets.append(Vector2.RIGHT.rotated(angle) * ring_radius)
		return offsets
	var max_extent := 0.0
	for extent in extents:
		max_extent = maxf(max_extent, float(extent))
	var ring_radius := max_extent * 2.4 + DUAL_CORE_GAP_MARGIN * 2.0
	for i in range(extents.size()):
		var angle := -PI * 0.5 + TAU * float(i) / float(extents.size())
		offsets.append(Vector2.RIGHT.rotated(angle) * ring_radius)
	return offsets

static func _offset_cluster_data(data: Array, offset: Vector2) -> Array:
	var shifted: Array = []
	for d in data:
		shifted.append({
			"pos": d["local_pos"] + offset,
			"local_pos": d["local_pos"],
			"radius": d["radius"],
			"hp": d["hp"],
			"is_core": d["is_core"],
			"module_kind": d.get("module_kind", "normal"),
			"allow_turret": d.get("allow_turret", true),
			"cluster_id": d["cluster_id"],
		})
	return shifted

func _build_final_boss_bridges(shifted_clusters: Array) -> Array:
	var bridges: Array = []
	if shifted_clusters.is_empty():
		return bridges
	var existing: Array = []
	for cluster in shifted_clusters:
		existing.append_array(cluster)
	for i in range(1, shifted_clusters.size()):
		var bridge := _build_cluster_bridge(shifted_clusters[0], shifted_clusters[i], existing)
		bridges.append_array(bridge)
		existing.append_array(bridge)
	for i in range(1, shifted_clusters.size()):
		var next_i := 1 + (i % (shifted_clusters.size() - 1))
		var ring_bridge := _build_cluster_bridge(shifted_clusters[i], shifted_clusters[next_i], existing)
		bridges.append_array(ring_bridge)
		existing.append_array(ring_bridge)
	return bridges

func _build_final_boss_padding(center_cluster: Array, existing: Array, needed: int) -> Array:
	var padding: Array = []
	if needed <= 0 or center_cluster.is_empty():
		return padding
	var anchor: Dictionary = center_cluster[0]
	var anchor_pos := anchor["pos"] as Vector2
	var anchor_radius := float(anchor["radius"])
	for i in range(needed):
		var angle := TAU * float(i) / float(maxi(needed, 1))
		var radius := 12.0
		var pos := anchor_pos + Vector2.RIGHT.rotated(angle) * (anchor_radius + 34.0 + float(i / 6) * 18.0)
		if not _bridge_pos_overlaps(existing, pos, radius):
			var bubble := {
				"pos": pos,
				"local_pos": pos,
				"radius": radius,
				"hp": 2,
				"is_core": false,
				"cluster_id": int(anchor.get("cluster_id", 0)),
				"allow_turret": false,
			}
			padding.append(bubble)
			existing.append(bubble)
	return padding

func _build_cluster_bridge(from_cluster: Array, to_cluster: Array, existing: Array) -> Array:
	if from_cluster.is_empty() or to_cluster.is_empty():
		return []
	var target_from := to_cluster[0]["pos"] as Vector2
	var target_to := from_cluster[0]["pos"] as Vector2
	var from_anchor := _find_bridge_anchor_toward(from_cluster, target_from)
	var to_anchor := _find_bridge_anchor_toward(to_cluster, target_to)
	if from_anchor.is_empty() or to_anchor.is_empty():
		return []
	var start_center := from_anchor["pos"] as Vector2
	var end_center := to_anchor["pos"] as Vector2
	var direction := (end_center - start_center).normalized()
	if direction.length() <= 0.001:
		return []
	var start := start_center + direction * float(from_anchor["radius"])
	var finish := end_center - direction * float(to_anchor["radius"])
	var gap := start.distance_to(finish)
	if gap <= 10.0:
		return []
	var base_radius := clampf(gap / 6.5, 11.0, 16.0)
	var bubble_count := maxi(3, int(ceil(gap / (base_radius * 1.65))))
	var bridge: Array = []
	for i in range(bubble_count):
		var t := float(i + 1) / float(bubble_count + 1)
		var radius := clampf(base_radius * (0.9 + 0.18 * sin(t * PI)), 10.0, 18.0)
		var pos := start.lerp(finish, t)
		if _bridge_pos_overlaps(existing, pos, radius):
			continue
		var bubble := {
			"pos": pos,
			"local_pos": pos,
			"radius": radius,
			"hp": maxi(2, int(round(radius / 7.0))),
			"is_core": false,
			"cluster_id": int(from_anchor.get("cluster_id", 0)),
			"allow_turret": false,
		}
		bridge.append(bubble)
		existing.append(bubble)
	return bridge

func _find_bridge_anchor_toward(cluster: Array, target_pos: Vector2) -> Dictionary:
	var best: Dictionary = {}
	var best_score := -INF
	for entry in cluster:
		var pos := entry["pos"] as Vector2
		var toward := (target_pos - pos).normalized()
		var score := pos.dot(toward) + float(entry["radius"]) * 0.35
		if best.is_empty() or score > best_score:
			best = entry
			best_score = score
	return best

static func _bridge_pos_overlaps(existing: Array, pos: Vector2, radius: float) -> bool:
	for ex in existing:
		if pos.distance_to(ex["pos"] as Vector2) < radius + float(ex["radius"]) - 1.0:
			return true
	return false

static func _build_dual_core_bridge(left_cluster: Array, right_cluster: Array, rng: RandomNumberGenerator = null) -> Array:
	var left_anchor := EnemyBoss._find_bridge_anchor(left_cluster, true)
	var right_anchor := EnemyBoss._find_bridge_anchor(right_cluster, false)
	if left_anchor.is_empty() or right_anchor.is_empty():
		return []

	var start := (left_anchor["pos"] as Vector2) + Vector2.RIGHT * float(left_anchor["radius"])
	var finish := (right_anchor["pos"] as Vector2) + Vector2.LEFT * float(right_anchor["radius"])
	var gap := start.distance_to(finish)
	if gap <= 6.0:
		return []

	var base_radius := clampf(gap / 5.0, 11.0, 16.0)
	var bubble_count := maxi(2, int(ceil(gap / (base_radius * 1.7))))
	var bridge: Array = []
	var existing: Array = []
	existing.append_array(left_cluster)
	existing.append_array(right_cluster)

	for i in range(bubble_count):
		var t := float(i + 1) / float(bubble_count + 1)
		var radius := clampf(base_radius * (0.92 + 0.16 * sin(t * PI)), 10.0, 18.0)
		var pos := start.lerp(finish, t)
		var ok := true
		for ex in existing:
			if pos.distance_to(ex["pos"] as Vector2) < radius + float(ex["radius"]) - 1.0:
				ok = false
				break
		if not ok:
			continue
		var cluster_id := 0 if t < 0.5 else 1
		var bridge_bubble := {
			"pos": pos,
			"local_pos": pos,
			"radius": radius,
			"hp": maxi(2, int(round(radius / 7.0))),
			"is_core": false,
			"cluster_id": cluster_id,
			"allow_turret": false,
		}
		bridge.append(bridge_bubble)
		existing.append(bridge_bubble)

	return bridge

static func _find_bridge_anchor(cluster: Array, prefer_right: bool) -> Dictionary:
	var best: Dictionary = {}
	var best_score := -INF if prefer_right else INF
	for entry in cluster:
		var pos := entry["pos"] as Vector2
		var score := pos.x + float(entry["radius"]) if prefer_right else pos.x - float(entry["radius"])
		if best.is_empty() or (prefer_right and score > best_score) or (not prefer_right and score < best_score):
			best = entry
			best_score = score
	return best

# ── 共用：从 data 数组创建炮塔 + BubbleState + 碰撞节点 ──────────────────────
func _finalize_from_data(data: Array, cluster_count: int) -> void:
	bubbles.clear()
	turret_indices.clear()
	turret_angles.clear()
	turret_spread.clear()
	_max_bubble_extent = 0.0

	var source_turret_count := _payload_turret_count_override if _payload_turret_count_override >= 0 else _s_turret_count
	var source_spread_turret := _payload_spread_turret_override if _has_payload_spread_override else _s_spread_turret
	var turrets_per_cluster := source_turret_count if _max_turrets_per_cluster < 0 else mini(source_turret_count, _max_turrets_per_cluster)
	for cluster_id in range(cluster_count):
		var candidates: Array = []
		for idx in range(data.size()):
			if int(data[idx].get("cluster_id", 0)) == cluster_id \
					and not bool(data[idx].get("is_core", false)) \
					and bool(data[idx].get("allow_turret", true)):
				candidates.append(idx)
		candidates.sort_custom(func(a, b): return _compare_data_turret_candidates(data[a], data[b]))
		for i in range(mini(turrets_per_cluster, candidates.size())):
			turret_indices.append(candidates[i])
			turret_angles.append(0.0)
			turret_spread.append(source_spread_turret and i == 0)

	for i in range(data.size()):
		var d  = data[i]
		var bs = BubbleState.new()
		bs.pos     = d["pos"]
		bs.radius  = d["radius"]
		bs.hp      = d["hp"]
		bs.max_hp  = d["hp"]
		bs.is_core = d["is_core"]
		bs.module_kind = String(d.get("module_kind", "normal"))
		bs.cluster_id = int(d.get("cluster_id", 0))
		bs.allow_turret = bool(d.get("allow_turret", true))
		_max_bubble_extent = maxf(_max_bubble_extent, bs.pos.length() + bs.radius)

		var area = Area2D.new()
		area.position = bs.pos
		area.modulate = _module_color(bs.module_kind, bs.is_core)
		area.set_script(_boss_bubble_script)
		area.boss       = self
		area.bubble_idx = i

		var col    = CollisionShape2D.new()
		var circle = CircleShape2D.new()
		circle.radius = bs.radius
		col.shape = circle
		area.add_child(col)
		add_child(area)

		bs.area = area
		bubbles.append(bs)

func hit_by_player_bullet(bullet_pos: Vector2, bullet_radius: float) -> bool:
	if _generation_pending or bubbles.is_empty():
		return false
	var local_bullet_pos := to_local(bullet_pos)
	var max_reach := _max_bubble_extent + bullet_radius
	if local_bullet_pos.length_squared() > max_reach * max_reach:
		return false
	var hit_idx := -1
	var best_dist_sq := INF
	for i in range(bubbles.size()):
		var bubble: BubbleState = bubbles[i]
		if not bubble.alive:
			continue
		var reach := bubble.radius + bullet_radius
		var dist_sq := bubble.pos.distance_squared_to(local_bullet_pos)
		if dist_sq <= reach * reach and dist_sq < best_dist_sq:
			best_dist_sq = dist_sq
			hit_idx = i
	if hit_idx < 0:
		return false
	on_bubble_hit(hit_idx)
	return true

func _compare_data_turret_candidates(a: Dictionary, b: Dictionary) -> bool:
	var a_score := _data_turret_candidate_score(a)
	var b_score := _data_turret_candidate_score(b)
	if absf(a_score - b_score) > 0.001:
		return a_score > b_score
	return (a["local_pos"] as Vector2).length() > (b["local_pos"] as Vector2).length()

func _data_turret_candidate_score(entry: Dictionary) -> float:
	var score := (entry["local_pos"] as Vector2).length()
	match String(entry.get("module_kind", "normal")):
		"turret":
			score += 240.0
		"lure":
			score += 70.0
		"armor":
			score -= 90.0
		"bridge":
			score -= 160.0
		"shield":
			score -= 200.0
	return score

func _module_color(module_kind: String, is_core: bool) -> Color:
	if is_core:
		return Color(1.0, 0.47, 0.47)
	match module_kind:
		"turret":
			return Color(1.0, 0.77, 0.32)
		"armor":
			return Color(0.58, 0.86, 1.0)
		"bridge":
			return Color(0.77, 0.77, 0.84)
		"shield":
			return Color(0.56, 0.98, 0.86)
		"lure":
			return Color(1.0, 0.60, 0.82)
		_:
			return Color(1.0, 1.0, 1.0)

func _apply_behavior_genes(genome: Dictionary) -> void:
	rotation = float(genome.get("initial_heading", randf() * TAU))
	_turn_rate = clampf(float(genome.get("turn_rate", 2.0)), 0.6, 4.5)
	_preferred_range = clampf(float(genome.get("preferred_range", 180.0)), 90.0, 320.0)
	_orbit_weight = clampf(float(genome.get("orbit_weight", 0.5)), 0.05, 1.2)
	_orbit_dir = -1 if int(genome.get("orbit_dir", 1)) < 0 else 1
	_aim_lead = clampf(float(genome.get("aim_lead", 0.1)), 0.0, 0.7)
	_aggression_bias = clampf(float(genome.get("aggression_bias", 0.5)), 0.05, 1.2)
	_caution_bias = clampf(float(genome.get("caution_bias", 0.5)), 0.05, 1.2)
	_ambush_bias = clampf(float(genome.get("ambush_bias", 0.5)), 0.05, 1.2)
	_finisher_bias = clampf(float(genome.get("finisher_bias", 0.5)), 0.05, 1.2)
	_preferred_tactic = String(genome.get("preferred_tactic", "strafe"))
	_has_target_sample = false
	_target_velocity = Vector2.ZERO
	_apply_tactic(_preferred_tactic)

func _sample_target(target: Vector2, delta: float) -> void:
	if _has_target_sample and delta > 0.0:
		_target_velocity = (target - _last_target_pos) / delta
	else:
		_target_velocity = Vector2.ZERO
	_last_target_pos = target
	_has_target_sample = true

func _desired_move_direction(to_target: Vector2) -> Vector2:
	var distance := to_target.length()
	var lure_pressure := _get_lure_pressure()
	var preferred_range := lerpf(_preferred_range * _tactic_range_scale, _preferred_range * _tactic_range_scale * 0.58, lure_pressure)
	var orbit_weight := lerpf(_orbit_weight * _tactic_orbit_scale, _orbit_weight * _tactic_orbit_scale * 0.32, lure_pressure)
	if distance <= 0.001:
		return Vector2.RIGHT.rotated(rotation)
	var radial := to_target / distance
	if distance < 56.0:
		return -radial
	var tangent := radial.orthogonal() * float(_orbit_dir)
	var range_error := clampf((distance - preferred_range) / maxf(preferred_range, 1.0), -1.0, 1.0)
	var desired := tangent * orbit_weight + radial * range_error * (0.35 + absf(range_error) * (0.95 + lure_pressure * 0.8))
	if desired.length() <= 0.05:
		desired = tangent
	return desired.normalized()

func _get_lure_pressure() -> float:
	var alive_count := 0
	var lure_count := 0
	for bubble in bubbles:
		if not bubble.alive or bubble.is_core:
			continue
		alive_count += 1
		if bubble.module_kind == "lure":
			lure_count += 1
	if alive_count <= 0 or lure_count <= 0:
		return 0.0
	return clampf(float(lure_count) / float(alive_count), 0.0, LURE_MAX_PRESSURE)

func _get_alive_hp_ratio() -> float:
	var total_hp := 0.0
	var total_max_hp := 0.0
	for bubble in bubbles:
		if not bubble.alive:
			continue
		total_hp += float(maxi(bubble.hp, 0))
		total_max_hp += float(maxi(bubble.max_hp, 1))
	if total_max_hp <= 0.0:
		return 0.0
	return clampf(total_hp / total_max_hp, 0.0, 1.0)

func _evaluate_tactical_mode(player: Node2D, scene: Node, distance: float) -> String:
	var self_hp_ratio: float = _get_alive_hp_ratio()
	var player_hp_ratio: float = scene.get_player_hp_ratio() if scene != null and scene.has_method("get_player_hp_ratio") else 1.0
	var player_dash_cd: float = player.get_dash_cooldown() if player != null and player.has_method("get_dash_cooldown") else 0.0
	var player_dash_ready: bool = player_dash_cd <= 0.15
	var player_can_fire: bool = player.is_ready_to_fire() if player != null and player.has_method("is_ready_to_fire") else true
	var preferred_range: float = maxf(_preferred_range, 1.0)
	var dist_ratio: float = distance / preferred_range
	var lure_pressure: float = _get_lure_pressure()

	var pressure_score: float = 0.18 + _aggression_bias * 0.85 + lure_pressure * 0.8 + clampf(dist_ratio - 0.9, 0.0, 1.2) * 0.35 + (1.0 - player_hp_ratio) * 0.25 - _caution_bias * (1.0 - self_hp_ratio) * 0.55
	var strafe_score: float = 0.35 + (0.22 if _preferred_tactic == "strafe" else 0.0) + clampf(1.0 - absf(dist_ratio - 1.0), 0.0, 1.0) * 0.55 + _ambush_bias * 0.12
	var retreat_score: float = 0.14 + _caution_bias * 0.95 + (1.0 - self_hp_ratio) * 1.15 + (0.24 if player_dash_ready else 0.0) + clampf(1.0 - dist_ratio, 0.0, 1.0) * 0.45
	var ambush_score: float = 0.12 + _ambush_bias * 0.95 + (0.36 if not player_dash_ready else 0.0) + (0.24 if not player_can_fire else 0.0) + clampf(1.25 - absf(dist_ratio - 1.1), 0.0, 1.0) * 0.42
	var finish_score: float = 0.08 + _finisher_bias * 0.95 + (1.0 - player_hp_ratio) * 1.2 + self_hp_ratio * 0.18 + clampf(1.15 - dist_ratio, 0.0, 1.0) * 0.55

	var best_mode: String = _preferred_tactic
	var best_score: float = -INF
	for pair in [
		{"mode": "pressure", "score": pressure_score},
		{"mode": "strafe", "score": strafe_score},
		{"mode": "retreat", "score": retreat_score},
		{"mode": "ambush", "score": ambush_score},
		{"mode": "finish", "score": finish_score},
	]:
		if float(pair["score"]) > best_score:
			best_score = float(pair["score"])
			best_mode = String(pair["mode"])
	return best_mode

func _apply_tactic(mode: String) -> void:
	_current_tactic = mode
	match mode:
		"pressure":
			_tactic_range_scale = 0.82
			_tactic_orbit_scale = 0.55
			_tactic_speed_scale = 1.18
			_tactic_fire_interval_scale = 0.90
			_tactic_aim_scale = 1.08
		"retreat":
			_tactic_range_scale = 1.30
			_tactic_orbit_scale = 1.12
			_tactic_speed_scale = 1.10
			_tactic_fire_interval_scale = 1.14
			_tactic_aim_scale = 0.96
		"ambush":
			_tactic_range_scale = 0.96
			_tactic_orbit_scale = 0.72
			_tactic_speed_scale = 1.08
			_tactic_fire_interval_scale = 0.84
			_tactic_aim_scale = 1.24
		"finish":
			_tactic_range_scale = 0.66
			_tactic_orbit_scale = 0.22
			_tactic_speed_scale = 1.24
			_tactic_fire_interval_scale = 0.76
			_tactic_aim_scale = 1.30
		_:
			_tactic_range_scale = 1.0
			_tactic_orbit_scale = 1.24
			_tactic_speed_scale = 1.0
			_tactic_fire_interval_scale = 1.0
			_tactic_aim_scale = 1.0

func _update_utility_ai(player: Node2D, scene: Node, distance: float, delta: float) -> void:
	_utility_rethink_timer -= delta
	if _utility_rethink_timer > 0.0:
		return
	_utility_rethink_timer = 0.35
	var mode := _evaluate_tactical_mode(player, scene, distance)
	if mode != _current_tactic:
		_apply_tactic(mode)

# ═══════════════════════════════════════════════════════
#  每帧逻辑
# ═══════════════════════════════════════════════════════
func _process(delta: float) -> void:
	if not authority_simulation:
		return
	if _generation_pending:
		_poll_async_generation()
		return
	var scene: Node = get_tree().current_scene
	var player: Node2D = scene.get_nearest_player_node(global_position) if scene and scene.has_method("get_nearest_player_node") else get_tree().get_first_node_in_group("player")
	var target: Vector2 = player.global_position if is_instance_valid(player) else get_viewport_rect().size * 0.5
	_sample_target(target, delta)
	var to_target: Vector2 = target - global_position
	_update_utility_ai(player, scene, to_target.length(), delta)

	var desired_dir := _desired_move_direction(to_target)
	rotation = rotate_toward(rotation, desired_dir.angle(), _turn_rate * delta)
	var movement_speed := speed * _tactic_speed_scale * lerpf(1.0, 1.0 + LURE_SPEED_BONUS, _get_lure_pressure())
	global_position += Vector2.RIGHT.rotated(rotation) * movement_speed * delta

	# 炮塔瞄准
	var any_alive := false
	var predicted_target: Vector2 = target + _target_velocity * (_aim_lead * _tactic_aim_scale)
	for i in range(turret_indices.size()):
		var ti = turret_indices[i]
		if ti < bubbles.size() and bubbles[ti].alive:
			any_alive = true
			var host_global := to_global(bubbles[ti].pos)
			turret_angles[i] = (predicted_target - host_global).angle() - rotation

	if any_alive:
		fire_timer += delta
		if fire_timer >= _s_fire_interval * _tactic_fire_interval_scale:
			fire_timer = 0.0
			_fire()

	if player and _is_touching_player(target):
		_contact_overlap_time += delta
		while _contact_overlap_time >= CONTACT_DAMAGE_INTERVAL:
			_contact_overlap_time -= CONTACT_DAMAGE_INTERVAL
			var target_peer_id: int = scene.get_player_peer_id(player) if scene and scene.has_method("get_player_peer_id") else 1
			scene.take_damage(_contact_damage, target_peer_id)
	else:
		_contact_overlap_time = 0.0

	_cleanup_if_outside_bounds()
	_visual_refresh_timer -= delta
	if _visual_refresh_timer <= 0.0:
		_visual_refresh_timer = VISUAL_REFRESH_INTERVAL
		queue_redraw()

func _cleanup_if_outside_bounds() -> void:
	var scene = get_tree().current_scene
	var margin := FINAL_BOSS_CLEANUP_MARGIN if is_final_boss else 420.0
	if scene and scene.has_method("is_outside_cleanup_bounds") and scene.is_outside_cleanup_bounds(global_position, margin):
		queue_free()

func _is_touching_player(player_pos: Vector2) -> bool:
	for bubble in bubbles:
		if not bubble.alive:
			continue
		var bubble_pos := to_global(bubble.pos)
		var reach: float = bubble.radius + PLAYER_COLLISION_RADIUS
		if bubble_pos.distance_squared_to(player_pos) <= reach * reach:
			return true
	return false

# ═══════════════════════════════════════════════════════
#  战斗逻辑
# ═══════════════════════════════════════════════════════
func _fire() -> void:
	var scene := get_tree().current_scene
	var bullets_node = scene.get_node("Bullets")
	for i in range(turret_indices.size()):
		var ti = turret_indices[i]
		if ti >= bubbles.size() or not bubbles[ti].alive:
			continue
		var host    = bubbles[ti]
		var angle   = turret_angles[i]
		var is_spr  = i < turret_spread.size() and turret_spread[i]
		var offsets: Array = [deg_to_rad(-18.0), 0.0, deg_to_rad(18.0)] if is_spr else [0.0]
		var host_global: Vector2 = to_global(host.pos)

		for a_off in offsets:
			var fire_angle: float = rotation + angle + a_off
			var bullet: Area2D = scene.acquire_enemy_bullet() if scene and scene.has_method("acquire_enemy_bullet") else _bullet_scene.instantiate()
			if bullet.get_parent() == null:
				bullets_node.add_child(bullet)
			var spawn_position: Vector2 = host_global + Vector2.RIGHT.rotated(fire_angle) * (host.radius + 20.0)
			var spawn_direction: Vector2 = Vector2.RIGHT.rotated(fire_angle)
			var spawn_speed: float = ENEMY_BULLET_BASE_SPEED * _s_enemy_bullet_speed_multiplier
			if scene and scene.has_method("notify_enemy_fire"):
				scene.notify_enemy_fire(spawn_position, spawn_direction, spawn_speed)
			if bullet.has_method("activate_from_pool"):
				bullet.activate_from_pool(spawn_position, spawn_direction, spawn_speed)
			else:
				bullet.global_position = spawn_position
				bullet.direction = spawn_direction
				bullet.speed = spawn_speed

func configure_network_entity(entity_id: int, authority: bool) -> void:
	network_entity_id = entity_id
	authority_simulation = authority
	if is_inside_tree():
		set_process(authority)

func is_network_spawn_ready() -> bool:
	return not _network_spawn_payload_cache.is_empty()

func get_network_spawn_payload() -> Dictionary:
	return _network_spawn_payload_cache.duplicate(true)

func get_network_entity_state() -> Dictionary:
	if _generation_pending or bubbles.is_empty():
		return {}
	var bubble_hp: Array = []
	var bubble_alive: Array = []
	for bubble in bubbles:
		bubble_hp.append(int(bubble.hp))
		bubble_alive.append(bool(bubble.alive))
	return {
		"pos": global_position,
		"rot": rotation,
		"turret_angles": turret_angles.duplicate(),
		"bubble_hp": bubble_hp,
		"bubble_alive": bubble_alive,
	}

func apply_network_entity_state(state: Dictionary) -> void:
	if state.is_empty():
		return
	_network_target_position = state.get("pos", global_position)
	_network_target_rotation = float(state.get("rot", rotation))
	var next_turret_angles: Array = state.get("turret_angles", [])
	if next_turret_angles.size() == turret_angles.size():
		_network_target_turret_angles = next_turret_angles.duplicate()
	var bubble_hp: Array = state.get("bubble_hp", [])
	var bubble_alive: Array = state.get("bubble_alive", [])
	var state_count := mini(bubbles.size(), mini(bubble_hp.size(), bubble_alive.size()))
	var needs_redraw := false
	for i in range(state_count):
		var bubble: BubbleState = bubbles[i]
		var next_hp := int(bubble_hp[i])
		var next_alive := bool(bubble_alive[i])
		if bubble.hp != next_hp or bubble.alive != next_alive:
			needs_redraw = true
		if bubble.alive and not next_alive and is_instance_valid(bubble.area):
			bubble.area.queue_free()
		bubble.hp = next_hp
		bubble.alive = next_alive
	_has_network_target = true
	if needs_redraw:
		queue_redraw()

func tick_network_interpolation(delta: float) -> void:
	if authority_simulation or not _has_network_target:
		return
	var position_blend: float = min(1.0, delta * 10.0)
	var rotation_blend: float = min(1.0, delta * 12.0)
	var dist_sq: float = global_position.distance_squared_to(_network_target_position)
	if dist_sq > 420.0 * 420.0:
		global_position = _network_target_position
	else:
		global_position = global_position.lerp(_network_target_position, position_blend)
	rotation = lerp_angle(rotation, _network_target_rotation, rotation_blend)
	if _network_target_turret_angles.size() == turret_angles.size():
		for i in range(turret_angles.size()):
			turret_angles[i] = lerp_angle(float(turret_angles[i]), float(_network_target_turret_angles[i]), min(1.0, delta * 16.0))
	queue_redraw()

func on_bubble_hit(idx: int) -> void:
	if idx >= bubbles.size():
		return
	var resolved_idx := _resolve_hit_target(idx)
	var b = bubbles[resolved_idx]
	if not b.alive:
		return

	b.damage_bank += _module_incoming_damage(b)
	var applied_damage := int(floor(b.damage_bank))
	if applied_damage <= 0:
		queue_redraw()
		return
	b.damage_bank -= float(applied_damage)
	b.hp -= applied_damage
	if b.hp > 0:
		queue_redraw()
		return

	b.alive = false
	if is_instance_valid(b.area):
		b.area.queue_free()

	if b.is_core:
		var scene := get_tree().current_scene
		scene.add_score(SCORE_VALUE)
		_collapse_cluster(b.cluster_id)
		if _alive_core_count() <= 0:
			if scene and scene.has_method("play_enemy_death_sfx"):
				scene.play_enemy_death_sfx()
			_report_death()
			queue_free()
		else:
			queue_redraw()
	else:
		queue_redraw()

func _resolve_hit_target(idx: int) -> int:
	if idx >= bubbles.size():
		return idx
	var target: BubbleState = bubbles[idx]
	if not target.alive or target.module_kind == "shield":
		return idx
	var shield_idx := _find_protecting_shield_index(idx)
	return shield_idx if shield_idx >= 0 else idx

func _find_protecting_shield_index(idx: int) -> int:
	var target: BubbleState = bubbles[idx]
	var best_idx := -1
	var best_dist := INF
	for i in range(bubbles.size()):
		if i == idx:
			continue
		var candidate: BubbleState = bubbles[i]
		if not candidate.alive or candidate.cluster_id != target.cluster_id:
			continue
		if candidate.module_kind != "shield":
			continue
		var dist := candidate.pos.distance_to(target.pos)
		if dist <= candidate.radius + target.radius + SHIELD_PROTECT_RADIUS and dist < best_dist:
			best_dist = dist
			best_idx = i
	return best_idx

func _module_incoming_damage(bubble: BubbleState) -> float:
	match bubble.module_kind:
		"armor":
			return ARMOR_DAMAGE_FACTOR
		"shield":
			return 1.0
		_:
			return 1.0

func _collapse_cluster(cluster_id: int) -> void:
	for bubble in bubbles:
		if bubble.cluster_id != cluster_id or not bubble.alive:
			continue
		bubble.alive = false
		if is_instance_valid(bubble.area):
			bubble.area.queue_free()

func _alive_core_count() -> int:
	var alive_cores := 0
	for bubble in bubbles:
		if bubble.is_core and bubble.alive:
			alive_cores += 1
	return alive_cores

# ═══════════════════════════════════════════════════════
#  绘制
# ═══════════════════════════════════════════════════════
func _draw() -> void:
	for i in range(bubbles.size()):
		var b = bubbles[i]
		if b.alive and not b.is_core:
			_draw_bubble(b)
	for i in range(bubbles.size()):
		var b = bubbles[i]
		if b.alive and b.is_core:
			_draw_bubble(b)
	for i in range(turret_indices.size()):
		var ti = turret_indices[i]
		if ti < bubbles.size() and bubbles[ti].alive:
			var is_spr: bool = i < turret_spread.size() and turret_spread[i]
			_draw_turret(bubbles[ti].pos, turret_angles[i], is_spr)

func _draw_bubble(b: BubbleState) -> void:
	var dmg := 1.0 - float(b.hp) / float(b.max_hp)
	var base: Color
	if b.is_core:
		base = Color(1.0, 0.38, 0.0, 0.88).lerp(Color(0.55, 0.04, 0.0, 0.88), dmg)
	else:
		base = Color(1.0, 0.22, 0.22, 0.72).lerp(Color(0.5, 0.04, 0.04, 0.72), dmg)

	var rim_color := Color(base.r * 0.80, base.g * 0.25, 0.03, 0.92)
	var rim_w     := 2.4 if b.is_core else 1.6

	draw_circle(b.pos, b.radius, base, true, -1.0, true)
	draw_circle(b.pos, b.radius, rim_color, false, rim_w, true)

	if b.radius >= 13.0:
		var nuc_off := Vector2(-b.radius * 0.24, -b.radius * 0.27)
		var nuc_r   := b.radius * (0.30 if b.is_core else 0.27)
		draw_circle(b.pos + nuc_off, nuc_r, Color(0.40, 0.02, 0.02, 0.95), true, -1.0, true)
		draw_circle(b.pos + nuc_off, nuc_r, Color(0.24, 0.0, 0.0, 0.85), false, 1.3, true)

	draw_circle(
		b.pos + Vector2(b.radius * 0.28, -b.radius * 0.32),
		b.radius * 0.22,
		Color(1.0, 1.0, 1.0, 0.25 if b.is_core else 0.20),
		true, -1.0, true
	)

func _draw_turret(host_pos: Vector2, angle: float, is_spread: bool) -> void:
	# 散射炮台：绿色，3 根细炮管；普通炮台：金色，1 根粗炮管
	var c_main := Color(0.20, 0.80, 0.28, 1.0) if is_spread else Color(0.85, 0.60, 0.05, 1.0)
	var c_rim  := Color(0.05, 0.48, 0.12, 1.0) if is_spread else Color(0.52, 0.32, 0.00, 1.0)
	var c_ring := Color(0.40, 0.95, 0.45, 0.5) if is_spread else Color(0.95, 0.75, 0.20, 0.5)

	draw_circle(host_pos, 10.0, c_main, true, -1.0, true)
	draw_circle(host_pos, 10.0, c_rim,  false, 2.0, true)
	draw_circle(host_pos, 5.5,  c_ring, false, 1.2, true)

	if is_spread:
		for a_off in [deg_to_rad(-18.0), 0.0, deg_to_rad(18.0)]:
			var d2  := Vector2.RIGHT.rotated(angle + a_off)
			var p2  := d2.rotated(PI * 0.5)
			var bw2 := 4.5
			draw_colored_polygon(PackedVector2Array([
				host_pos + p2 * bw2 * 0.5,
				host_pos - p2 * bw2 * 0.5,
				host_pos + d2 * 18.0 - p2 * bw2 * 0.5,
				host_pos + d2 * 18.0 + p2 * bw2 * 0.5,
			]), c_main)
	else:
		var dir  := Vector2.RIGHT.rotated(angle)
		var perp := dir.rotated(PI * 0.5)
		draw_colored_polygon(PackedVector2Array([
			host_pos + perp * 4.0,
			host_pos - perp * 4.0,
			host_pos + dir * 20.0 - perp * 4.0,
			host_pos + dir * 20.0 + perp * 4.0,
		]), c_main)
		draw_circle(host_pos + dir * 20.0, 5.5, c_rim, true, -1.0, true)
