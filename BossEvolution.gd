class_name BossEvolution
## 游戏内遗传算法 —— Boss 形态进化系统
##
## 使用方式：
##   BossEvolution.startup()                  ← 游戏开始时调用一次
##   var g = BossEvolution.next_genome()      ← 生成 Boss 时获取基因组
##   BossEvolution.on_boss_died(bid)          ← Boss 死亡时回报（bid 来自基因组的 "_bid" 字段）
##   BossEvolution.set_satellite_bounds(a, b) ← 玩家升级时更新卫星数量区间

# ── 种群参数 ─────────────────────────────────────────────────────────────────
const POP_SIZE  := 20    # 种群大小
const ELITE     := 5     # 每代直接保留的精英数
const MUT_PROB  := 0.28  # 各基因的变异概率
const RANDOM_IMMIGRANTS := 2

static var _pop:      Array      = []   # 当前种群（Dictionary 列表）
static var _gen:      int        = 0    # 当前代数
static var _next_bid: int        = 0    # 全局自增 Boss id
static var _alive:    Dictionary = {}   # bid -> [pop_idx, spawn_ms]
static var _min_sats: int        = 8    # 卫星下限（随玩家升级增大）
static var _max_sats: int        = 20   # 卫星上限（随玩家升级增大）
static var _evolve_thread: Thread = null
static var _evolve_runner: EvolutionJobRunner = null
static var _queued_evolve_request := false
static var _queued_seed_missing_fitness := false

class EvolutionJobRunner extends RefCounted:
	var payload: Dictionary

	func _init(job_payload: Dictionary) -> void:
		payload = job_payload

	func run() -> Dictionary:
		return BossEvolution._run_evolve_job(payload)

# ─────────────────────────────────────────────────────────────────────────────
#  公共接口
# ─────────────────────────────────────────────────────────────────────────────

static func startup() -> void:
	if not _pop.is_empty():
		return
	_pop = EnemyGenomeFactory.seed_initial_population(POP_SIZE, _min_sats, _max_sats)
	print("[BossEvolution] startup() 完成，种群大小: %d，已按原型重建初始种群" % _pop.size())

static func reset_population() -> void:
	_wait_for_async_evolution()
	_pop.clear()
	_alive.clear()
	_gen = 0
	_next_bid = 0
	_queued_evolve_request = false
	_queued_seed_missing_fitness = false

static func set_satellite_bounds(min_n: int, max_n: int) -> void:
	_min_sats = maxi(6, min_n)
	_max_sats = maxi(_min_sats, max_n)

## 强制进化一次（用于玩家升级时立即生成进化后的 Boss）
static func force_evolve() -> void:
	poll_async()
	if _pop.is_empty():
		print("[BossEvolution] force_evolve() 失败：种群为空")
		return
	print("[BossEvolution] force_evolve() 开始，当前代数: %d" % _gen)
	_seed_missing_fitness()
	_request_async_evolve()

## 获取下一个 Boss 基因组（含 "_bid" 字段，供 on_boss_died 使用）
static func next_genome() -> Dictionary:
	poll_async()
	print("[BossEvolution] next_genome() 调用，当前代数: %d, 种群大小: %d" % [_gen, _pop.size()])
	if _pop.is_empty():
		startup()

	# 种群仍为空时（startup 失败）返回兜底基因组
	if _pop.is_empty():
		var fallback := _fallback_genome()
		fallback["_bid"] = _next_bid
		_next_bid += 1
		return fallback

	# 适应度加权随机选择（生存时间越长 → 被选中概率越高）
	var total := 0.0
	for g in _pop:
		total += maxf(g.get("fitness", 0.5), 0.5)
	var r     := randf() * total
	var cumul := 0.0
	var idx   := 0
	for i in range(_pop.size()):
		cumul += maxf(_pop[i].get("fitness", 0.5), 0.5)
		if cumul >= r:
			idx = i
			break

	# 防止 idx 越界
	idx = clampi(idx, 0, _pop.size() - 1)
	var g: Dictionary = _pop[idx].duplicate(true)
	g["_bid"] = _next_bid
	_alive[_next_bid] = [idx, Time.get_ticks_msec()]
	_next_bid += 1
	return g

## 兜底基因组：固定形状，保证 Boss 一定能正常生成
static func _fallback_genome() -> Dictionary:
	return EnemyGenomeFactory.fallback_boss_genome(_min_sats)

## Boss 死亡（被击杀或离屏）时调用
static func on_boss_died(bid: int) -> void:
	poll_async()
	if not _alive.has(bid):
		return
	var info:     Array = _alive[bid]
	var pop_idx:  int   = info[0]
	var spawn_ms: int   = info[1]
	var survival: float = (Time.get_ticks_msec() - spawn_ms) / 1000.0
	_alive.erase(bid)

	if pop_idx < _pop.size():
		_pop[pop_idx]["fitness"] = maxf(_pop[pop_idx].get("fitness", 0.0), survival)

	# 积累足够评估数据后进化
	var rated := 0
	for g in _pop:
		if g.get("fitness", 0.0) > 0.0:
			rated += 1
	if rated >= POP_SIZE / 2:
		_request_async_evolve()

static func poll_async() -> void:
	if _evolve_thread == null:
		return
	if _evolve_thread.is_alive():
		return
	var result = _evolve_thread.wait_to_finish()
	_evolve_thread = null
	_evolve_runner = null
	if result is Dictionary and bool(result.get("ok", false)):
		_pop = result.get("pop", [])
		_gen = int(result.get("gen", _gen))
		_alive.clear()
		print("[BossEvolution] 异步进化完成，新代数: %d，种群大小: %d" % [_gen, _pop.size()])
	if _queued_evolve_request:
		var needs_seed := _queued_seed_missing_fitness
		_queued_evolve_request = false
		_queued_seed_missing_fitness = false
		if needs_seed:
			_seed_missing_fitness()
		_start_async_evolve()

# ─────────────────────────────────────────────────────────────────────────────
#  进化操作
# ─────────────────────────────────────────────────────────────────────────────

static func _evolve() -> void:
	_pop.sort_custom(func(a, b):
		return a.get("fitness", 0.0) > b.get("fitness", 0.0)
	)
	var elite_sat_count: int = EnemyGenomeFactory.estimate_satellite_count(_pop[0], _min_sats)
	print("[BossEvolution] Gen %d → 精英适应度 %.1f s, 节点数: %d" % [_gen, _pop[0].get("fitness", 0.0), elite_sat_count + 1])

	var new_pop: Array = []

	# 保留精英（清除 fitness 供下一代重新评估）
	for i in range(mini(ELITE, _pop.size())):
		var e: Dictionary = _pop[i].duplicate(true)
		e.erase("fitness")
		e.erase("_bid")
		new_pop.append(e)

	# 交叉 + 变异补足种群
	while new_pop.size() < POP_SIZE - RANDOM_IMMIGRANTS:
		var p1 := _tournament()
		var p2 := _tournament()
		var child: Dictionary = _crossover(p1, p2)
		_mutate(child)
		new_pop.append(child)

	while new_pop.size() < POP_SIZE:
		new_pop.append(_random_genome())

	_pop = new_pop
	_gen += 1
	_alive.clear()   # 旧追踪记录清空（下一代 Boss 将重新注册）
	print("[BossEvolution] Gen %d 完成，新种群大小: %d" % [_gen, _pop.size()])

static func _tournament() -> Dictionary:
	var best: Dictionary = _pop[randi() % _pop.size()]
	for _i in range(2):
		var c: Dictionary = _pop[randi() % _pop.size()]
		if c.get("fitness", 0.0) > best.get("fitness", 0.0):
			best = c
	return best

static func _crossover(a: Dictionary, b: Dictionary) -> Dictionary:
	return EnemyGenomeFactory.crossover_boss_genomes(a, b, _min_sats, _max_sats)

static func _mutate(g: Dictionary) -> void:
	EnemyGenomeFactory.mutate_boss_genome(g, MUT_PROB, _min_sats, _max_sats)

static func _random_behavior() -> Dictionary:
	return {
		"initial_heading": randf() * TAU,
		"turn_rate": randf_range(0.9, 4.0),
		"preferred_range": randf_range(100.0, 290.0),
		"orbit_weight": randf_range(0.15, 1.0),
		"orbit_dir": -1 if randf() < 0.5 else 1,
		"aim_lead": randf_range(0.0, 0.55),
	}

# ─────────────────────────────────────────────────────────────────────────────
#  随机基因组（初始种群）
# ─────────────────────────────────────────────────────────────────────────────

static func _random_genome() -> Dictionary:
	return EnemyGenomeFactory.random_boss_genome(_min_sats, _max_sats)

static func _request_async_evolve() -> void:
	if _pop.is_empty():
		return
	if _evolve_thread != null:
		_queued_evolve_request = true
		return
	_start_async_evolve()

static func _start_async_evolve() -> void:
	var payload := {
		"pop": _pop.duplicate(true),
		"gen": _gen,
		"min_sats": _min_sats,
		"max_sats": _max_sats,
		"seed": Time.get_ticks_usec(),
	}
	_evolve_runner = EvolutionJobRunner.new(payload)
	_evolve_thread = Thread.new()
	var err := _evolve_thread.start(_evolve_runner.run)
	if err != OK:
		_evolve_thread = null
		_evolve_runner = null
		print("[BossEvolution] 异步进化启动失败，回退到同步进化")
		_evolve()
		return
	print("[BossEvolution] 已启动异步进化任务，当前代数: %d" % _gen)

static func _wait_for_async_evolution() -> void:
	if _evolve_thread == null:
		return
	var result = _evolve_thread.wait_to_finish()
	_evolve_thread = null
	_evolve_runner = null
	if result is Dictionary and bool(result.get("ok", false)):
		_pop = result.get("pop", [])
		_gen = int(result.get("gen", _gen))
		_alive.clear()

static func _seed_missing_fitness() -> void:
	for g in _pop:
		if not g.has("fitness") or g.get("fitness", 0.0) <= 0.0:
			g["fitness"] = randf_range(0.5, 2.0)

static func _run_evolve_job(payload: Dictionary) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = int(payload.get("seed", 1))
	var pop_snapshot: Array = payload.get("pop", [])
	var min_sats := int(payload.get("min_sats", 8))
	var max_sats := int(payload.get("max_sats", 20))
	var gen := int(payload.get("gen", 0))
	var result_pop := _evolve_population_snapshot(pop_snapshot, min_sats, max_sats, rng)
	return {
		"ok": true,
		"pop": result_pop,
		"gen": gen + 1,
	}

static func _evolve_population_snapshot(population: Array, min_sats: int, max_sats: int, rng: RandomNumberGenerator) -> Array:
	population.sort_custom(func(a, b):
		return a.get("fitness", 0.0) > b.get("fitness", 0.0)
	)
	var new_pop: Array = []

	for i in range(mini(ELITE, population.size())):
		var elite: Dictionary = population[i].duplicate(true)
		elite.erase("fitness")
		elite.erase("_bid")
		new_pop.append(elite)

	while new_pop.size() < POP_SIZE - RANDOM_IMMIGRANTS:
		var p1 := _tournament_from(population, rng)
		var p2 := _tournament_from(population, rng)
		var child: Dictionary = EnemyGenomeFactory.crossover_boss_genomes(p1, p2, min_sats, max_sats, rng)
		EnemyGenomeFactory.mutate_boss_genome(child, MUT_PROB, min_sats, max_sats, rng)
		new_pop.append(child)

	while new_pop.size() < POP_SIZE:
		new_pop.append(EnemyGenomeFactory.random_boss_genome(min_sats, max_sats, "", rng))

	return new_pop

static func _tournament_from(population: Array, rng: RandomNumberGenerator) -> Dictionary:
	var best: Dictionary = population[rng.randi_range(0, population.size() - 1)]
	for _i in range(2):
		var candidate: Dictionary = population[rng.randi_range(0, population.size() - 1)]
		if candidate.get("fitness", 0.0) > best.get("fitness", 0.0):
			best = candidate
	return best
