class_name EnemyGenomeFactory
extends RefCounted

const CONNECTION_STYLES := ["tree", "ring", "web", "spine", "shell"]
const SYMMETRIES := ["none", "mirror_x", "radial"]
const ARCHETYPES := ["bulwark", "artillery", "webber", "spine", "adaptive"]

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

static func _rng_pick(rng: RandomNumberGenerator, items: Array) -> Variant:
	return items[int(_rng_rangei(rng, 0, items.size() - 1))]

static func _rng_sign(rng: RandomNumberGenerator = null) -> int:
	if _rngf(rng) < 0.5:
		return -1
	return 1

static func random_boss_genome(min_sats: int, max_sats: int, archetype_hint: String = "", rng: RandomNumberGenerator = null) -> Dictionary:
	var body := {
		"core_radius": _rng_rangef(rng, 30.0, 56.0),
		"node_budget": _rng_rangei(rng, min_sats + 1, max_sats + 1),
		"connection_style": _rng_pick(rng, CONNECTION_STYLES),
		"symmetry": _rng_pick(rng, SYMMETRIES),
		"branchiness": _rng_rangef(rng, 0.28, 0.82),
		"bridge_density": _rng_rangef(rng, 0.08, 0.38),
		"outer_shell_bias": _rng_rangef(rng, 0.24, 0.72),
		"weak_point_exposure": _rng_rangef(rng, 0.05, 0.75),
	}
	var modules := {
		"turret_ratio": _rng_rangef(rng, 0.12, 0.42),
		"armor_ratio": _rng_rangef(rng, 0.12, 0.48),
		"bridge_ratio": _rng_rangef(rng, 0.10, 0.42),
		"shield_ratio": _rng_rangef(rng, 0.05, 0.30),
		"lure_ratio": _rng_rangef(rng, 0.02, 0.18),
		"armor_hp_scale": _rng_rangef(rng, 1.2, 2.8),
		"shield_hp_scale": _rng_rangef(rng, 1.1, 2.1),
		"bridge_hp_scale": _rng_rangef(rng, 0.9, 1.8),
		"bridge_radius_bias": _rng_rangef(rng, -1.5, 1.5),
		"turret_depth_bias": _rng_rangef(rng, 0.2, 1.0),
	}
	_apply_archetype_hint(body, modules, archetype_hint, rng)
	var genome := {
		"schema": "enemy_genome_v1",
		"archetype": _derive_archetype(body, modules),
		"body": body,
		"modules": modules,
	}
	genome.merge(_random_behavior(archetype_hint, rng))
	_apply_behavior_hint(genome, archetype_hint, rng)
	return genome

static func seed_initial_population(pop_size: int, min_sats: int, max_sats: int) -> Array:
	var population: Array = []
	for i in range(pop_size):
		var archetype_hint: String = String(ARCHETYPES[i % ARCHETYPES.size()])
		population.append(random_boss_genome(min_sats, max_sats, archetype_hint))
	return population

static func fallback_boss_genome(min_sats: int) -> Dictionary:
	var genome := {
		"schema": "enemy_genome_v1",
		"archetype": "bulwark",
		"body": {
			"core_radius": 40.0,
			"node_budget": maxi(min_sats + 1, 9),
			"connection_style": "shell",
			"symmetry": "radial",
			"branchiness": 0.35,
			"bridge_density": 0.22,
			"outer_shell_bias": 0.82,
			"weak_point_exposure": 0.18,
		},
		"modules": {
			"turret_ratio": 0.24,
			"armor_ratio": 0.34,
			"bridge_ratio": 0.18,
			"shield_ratio": 0.14,
			"lure_ratio": 0.05,
			"armor_hp_scale": 2.0,
			"shield_hp_scale": 1.5,
			"bridge_hp_scale": 1.15,
			"bridge_radius_bias": 0.0,
			"turret_depth_bias": 0.72,
		},
	}
	genome.merge(_random_behavior("bulwark"))
	_apply_behavior_hint(genome, "bulwark")
	return genome

static func crossover_boss_genomes(a: Dictionary, b: Dictionary, min_sats: int, max_sats: int, rng: RandomNumberGenerator = null) -> Dictionary:
	var body_a: Dictionary = a.get("body", {})
	var body_b: Dictionary = b.get("body", {})
	var mod_a: Dictionary = a.get("modules", {})
	var mod_b: Dictionary = b.get("modules", {})
	var archetype: String = String(a.get("archetype", "adaptive"))
	if _rngf(rng) >= 0.5:
		archetype = String(b.get("archetype", "adaptive"))
	var connection_style: String = String(body_a.get("connection_style", "tree"))
	if _rngf(rng) >= 0.5:
		connection_style = String(body_b.get("connection_style", "tree"))
	var symmetry: String = String(body_a.get("symmetry", "none"))
	if _rngf(rng) >= 0.5:
		symmetry = String(body_b.get("symmetry", "none"))
	var node_budget_lerp: float = lerp(
		float(body_a.get("node_budget", min_sats + 1)),
		float(body_b.get("node_budget", max_sats + 1)),
		_rngf(rng)
	)
	var node_budget: int = clampi(int(round(node_budget_lerp)), min_sats + 1, max_sats + 1)
	var child: Dictionary = {
		"schema": "enemy_genome_v1",
		"archetype": archetype,
		"body": {
			"core_radius": lerp(float(body_a.get("core_radius", 40.0)), float(body_b.get("core_radius", 40.0)), _rngf(rng)),
			"node_budget": node_budget,
			"connection_style": connection_style,
			"symmetry": symmetry,
			"branchiness": lerp(float(body_a.get("branchiness", 0.5)), float(body_b.get("branchiness", 0.5)), _rngf(rng)),
			"bridge_density": lerp(float(body_a.get("bridge_density", 0.25)), float(body_b.get("bridge_density", 0.25)), _rngf(rng)),
			"outer_shell_bias": lerp(float(body_a.get("outer_shell_bias", 0.5)), float(body_b.get("outer_shell_bias", 0.5)), _rngf(rng)),
			"weak_point_exposure": lerp(float(body_a.get("weak_point_exposure", 0.3)), float(body_b.get("weak_point_exposure", 0.3)), _rngf(rng)),
		},
		"modules": {
			"turret_ratio": lerp(float(mod_a.get("turret_ratio", 0.24)), float(mod_b.get("turret_ratio", 0.24)), _rngf(rng)),
			"armor_ratio": lerp(float(mod_a.get("armor_ratio", 0.24)), float(mod_b.get("armor_ratio", 0.24)), _rngf(rng)),
			"bridge_ratio": lerp(float(mod_a.get("bridge_ratio", 0.20)), float(mod_b.get("bridge_ratio", 0.20)), _rngf(rng)),
			"shield_ratio": lerp(float(mod_a.get("shield_ratio", 0.12)), float(mod_b.get("shield_ratio", 0.12)), _rngf(rng)),
			"lure_ratio": lerp(float(mod_a.get("lure_ratio", 0.06)), float(mod_b.get("lure_ratio", 0.06)), _rngf(rng)),
			"armor_hp_scale": lerp(float(mod_a.get("armor_hp_scale", 1.7)), float(mod_b.get("armor_hp_scale", 1.7)), _rngf(rng)),
			"shield_hp_scale": lerp(float(mod_a.get("shield_hp_scale", 1.4)), float(mod_b.get("shield_hp_scale", 1.4)), _rngf(rng)),
			"bridge_hp_scale": lerp(float(mod_a.get("bridge_hp_scale", 1.1)), float(mod_b.get("bridge_hp_scale", 1.1)), _rngf(rng)),
			"bridge_radius_bias": lerp(float(mod_a.get("bridge_radius_bias", 0.0)), float(mod_b.get("bridge_radius_bias", 0.0)), _rngf(rng)),
			"turret_depth_bias": lerp(float(mod_a.get("turret_depth_bias", 0.6)), float(mod_b.get("turret_depth_bias", 0.6)), _rngf(rng)),
		},
	}
	child.merge(_crossover_behavior(a, b, rng))
	child["archetype"] = _derive_archetype(child["body"], child["modules"])
	return child

static func mutate_boss_genome(g: Dictionary, prob: float, min_sats: int, max_sats: int, rng: RandomNumberGenerator = null) -> void:
	var body: Dictionary = g.get("body", {})
	var modules: Dictionary = g.get("modules", {})
	if _rngf(rng) < prob:
		body["core_radius"] = clampf(float(body.get("core_radius", 40.0)) + _rng_rangef(rng, -7.0, 7.0), 28.0, 56.0)
	if _rngf(rng) < prob:
		body["node_budget"] = clampi(int(body.get("node_budget", min_sats + 1)) + _rng_rangei(rng, -2, 2), min_sats + 1, max_sats + 1)
	if _rngf(rng) < prob * 0.7:
		body["connection_style"] = _rng_pick(rng, CONNECTION_STYLES)
	if _rngf(rng) < prob * 0.5:
		body["symmetry"] = _rng_pick(rng, SYMMETRIES)
	if _rngf(rng) < prob:
		body["branchiness"] = clampf(float(body.get("branchiness", 0.5)) + _rng_rangef(rng, -0.18, 0.18), 0.05, 0.98)
	if _rngf(rng) < prob:
		body["bridge_density"] = clampf(float(body.get("bridge_density", 0.25)) + _rng_rangef(rng, -0.16, 0.16), 0.02, 0.75)
	if _rngf(rng) < prob:
		body["outer_shell_bias"] = clampf(float(body.get("outer_shell_bias", 0.5)) + _rng_rangef(rng, -0.18, 0.18), 0.02, 0.98)
	if _rngf(rng) < prob:
		body["weak_point_exposure"] = clampf(float(body.get("weak_point_exposure", 0.3)) + _rng_rangef(rng, -0.18, 0.18), 0.0, 0.95)

	for key in ["turret_ratio", "armor_ratio", "bridge_ratio", "shield_ratio", "lure_ratio"]:
		if _rngf(rng) < prob:
			modules[key] = clampf(float(modules.get(key, 0.2)) + _rng_rangef(rng, -0.12, 0.12), 0.0, 0.65)
	if _rngf(rng) < prob:
		modules["armor_hp_scale"] = clampf(float(modules.get("armor_hp_scale", 1.7)) + _rng_rangef(rng, -0.25, 0.25), 1.0, 3.2)
	if _rngf(rng) < prob:
		modules["shield_hp_scale"] = clampf(float(modules.get("shield_hp_scale", 1.4)) + _rng_rangef(rng, -0.20, 0.20), 0.8, 2.5)
	if _rngf(rng) < prob:
		modules["bridge_hp_scale"] = clampf(float(modules.get("bridge_hp_scale", 1.1)) + _rng_rangef(rng, -0.20, 0.20), 0.6, 2.2)
	if _rngf(rng) < prob:
		modules["bridge_radius_bias"] = clampf(float(modules.get("bridge_radius_bias", 0.0)) + _rng_rangef(rng, -0.8, 0.8), -3.0, 3.0)
	if _rngf(rng) < prob:
		modules["turret_depth_bias"] = clampf(float(modules.get("turret_depth_bias", 0.6)) + _rng_rangef(rng, -0.16, 0.16), 0.0, 1.0)

	_mutate_behavior(g, prob, rng)
	g["body"] = body
	g["modules"] = modules
	g["archetype"] = _derive_archetype(body, modules)

static func estimate_satellite_count(genome: Dictionary, fallback: int = 0) -> int:
	if genome.has("body"):
		return maxi(0, int(genome.get("body", {}).get("node_budget", fallback + 1)) - 1)
	if genome.has("satellites"):
		return (genome.get("satellites", []) as Array).size()
	return fallback

static func _derive_archetype(body: Dictionary, modules: Dictionary) -> String:
	if float(modules.get("armor_ratio", 0.0)) > 0.34 and float(body.get("outer_shell_bias", 0.0)) > 0.65:
		return "bulwark"
	if float(modules.get("turret_ratio", 0.0)) > 0.30 and float(modules.get("turret_depth_bias", 0.0)) > 0.60:
		return "artillery"
	if float(body.get("branchiness", 0.0)) > 0.72:
		return "webber"
	if float(body.get("bridge_density", 0.0)) > 0.42:
		return "spine"
	return "adaptive"

static func _random_behavior(archetype_hint: String = "", rng: RandomNumberGenerator = null) -> Dictionary:
	return {
		"initial_heading": _rngf(rng) * TAU,
		"turn_rate": _rng_rangef(rng, 0.9, 4.0),
		"preferred_range": _rng_rangef(rng, 100.0, 290.0),
		"orbit_weight": _rng_rangef(rng, 0.15, 1.0),
		"orbit_dir": _rng_sign(rng),
		"aim_lead": _rng_rangef(rng, 0.0, 0.55),
		"aggression_bias": _rng_rangef(rng, 0.1, 1.0),
		"caution_bias": _rng_rangef(rng, 0.1, 1.0),
		"ambush_bias": _rng_rangef(rng, 0.1, 1.0),
		"finisher_bias": _rng_rangef(rng, 0.1, 1.0),
		"preferred_tactic": archetype_hint if archetype_hint != "" else "strafe",
	}

static func _crossover_behavior(a: Dictionary, b: Dictionary, rng: RandomNumberGenerator = null) -> Dictionary:
	var initial_heading: float = float(a.get("initial_heading", 0.0))
	if _rngf(rng) >= 0.5:
		initial_heading = float(b.get("initial_heading", 0.0))
	var orbit_dir: int = int(a.get("orbit_dir", 1))
	if _rngf(rng) >= 0.5:
		orbit_dir = int(b.get("orbit_dir", 1))
	var preferred_tactic: String = String(a.get("preferred_tactic", "strafe"))
	if _rngf(rng) >= 0.5:
		preferred_tactic = String(b.get("preferred_tactic", "strafe"))
	return {
		"initial_heading": initial_heading,
		"turn_rate": lerp(float(a.get("turn_rate", 2.1)), float(b.get("turn_rate", 2.1)), _rngf(rng)),
		"preferred_range": lerp(float(a.get("preferred_range", 180.0)), float(b.get("preferred_range", 180.0)), _rngf(rng)),
		"orbit_weight": lerp(float(a.get("orbit_weight", 0.55)), float(b.get("orbit_weight", 0.55)), _rngf(rng)),
		"orbit_dir": orbit_dir,
		"aim_lead": lerp(float(a.get("aim_lead", 0.15)), float(b.get("aim_lead", 0.15)), _rngf(rng)),
		"aggression_bias": lerp(float(a.get("aggression_bias", 0.5)), float(b.get("aggression_bias", 0.5)), _rngf(rng)),
		"caution_bias": lerp(float(a.get("caution_bias", 0.5)), float(b.get("caution_bias", 0.5)), _rngf(rng)),
		"ambush_bias": lerp(float(a.get("ambush_bias", 0.5)), float(b.get("ambush_bias", 0.5)), _rngf(rng)),
		"finisher_bias": lerp(float(a.get("finisher_bias", 0.5)), float(b.get("finisher_bias", 0.5)), _rngf(rng)),
		"preferred_tactic": preferred_tactic,
	}

static func _mutate_behavior(g: Dictionary, prob: float, rng: RandomNumberGenerator = null) -> void:
	if _rngf(rng) < prob:
		g["initial_heading"] = fmod(float(g.get("initial_heading", 0.0)) + _rng_rangef(rng, -1.2, 1.2), TAU)
	if _rngf(rng) < prob:
		g["turn_rate"] = clampf(float(g.get("turn_rate", 2.1)) + _rng_rangef(rng, -0.45, 0.45), 0.6, 4.5)
	if _rngf(rng) < prob:
		g["preferred_range"] = clampf(float(g.get("preferred_range", 180.0)) + _rng_rangef(rng, -38.0, 38.0), 90.0, 320.0)
	if _rngf(rng) < prob:
		g["orbit_weight"] = clampf(float(g.get("orbit_weight", 0.55)) + _rng_rangef(rng, -0.18, 0.18), 0.05, 1.2)
	if _rngf(rng) < prob * 0.4:
		g["orbit_dir"] = -int(g.get("orbit_dir", 1))
	if _rngf(rng) < prob:
		g["aim_lead"] = clampf(float(g.get("aim_lead", 0.15)) + _rng_rangef(rng, -0.1, 0.1), 0.0, 0.7)
	for key in ["aggression_bias", "caution_bias", "ambush_bias", "finisher_bias"]:
		if _rngf(rng) < prob:
			g[key] = clampf(float(g.get(key, 0.5)) + _rng_rangef(rng, -0.16, 0.16), 0.05, 1.2)
	if _rngf(rng) < prob * 0.35:
		g["preferred_tactic"] = _rng_pick(rng, ["pressure", "strafe", "retreat", "ambush", "finish"])

static func _apply_archetype_hint(body: Dictionary, modules: Dictionary, archetype_hint: String, rng: RandomNumberGenerator = null) -> void:
	match archetype_hint:
		"bulwark":
			body["connection_style"] = "shell"
			body["symmetry"] = "radial"
			body["outer_shell_bias"] = _rng_rangef(rng, 0.72, 0.95)
			body["weak_point_exposure"] = _rng_rangef(rng, 0.05, 0.22)
			modules["armor_ratio"] = _rng_rangef(rng, 0.32, 0.52)
			modules["shield_ratio"] = _rng_rangef(rng, 0.12, 0.28)
			modules["turret_ratio"] = _rng_rangef(rng, 0.14, 0.26)
		"artillery":
			body["connection_style"] = "spine"
			body["outer_shell_bias"] = _rng_rangef(rng, 0.34, 0.56)
			body["branchiness"] = _rng_rangef(rng, 0.32, 0.55)
			modules["turret_ratio"] = _rng_rangef(rng, 0.30, 0.48)
			modules["turret_depth_bias"] = _rng_rangef(rng, 0.58, 0.95)
			modules["bridge_ratio"] = _rng_rangef(rng, 0.10, 0.22)
		"webber":
			body["connection_style"] = "web"
			body["branchiness"] = _rng_rangef(rng, 0.72, 0.95)
			body["bridge_density"] = _rng_rangef(rng, 0.24, 0.48)
			modules["shield_ratio"] = _rng_rangef(rng, 0.10, 0.22)
			modules["lure_ratio"] = _rng_rangef(rng, 0.06, 0.18)
		"spine":
			body["connection_style"] = "spine"
			body["bridge_density"] = _rng_rangef(rng, 0.22, 0.42)
			body["branchiness"] = _rng_rangef(rng, 0.34, 0.58)
			body["outer_shell_bias"] = _rng_rangef(rng, 0.26, 0.5)
			modules["bridge_ratio"] = _rng_rangef(rng, 0.16, 0.28)
			modules["armor_ratio"] = _rng_rangef(rng, 0.16, 0.30)
		"adaptive":
			pass

static func _apply_behavior_hint(genome: Dictionary, archetype_hint: String, rng: RandomNumberGenerator = null) -> void:
	match archetype_hint:
		"bulwark":
			genome["caution_bias"] = _rng_rangef(rng, 0.72, 1.05)
			genome["aggression_bias"] = _rng_rangef(rng, 0.25, 0.58)
			genome["ambush_bias"] = _rng_rangef(rng, 0.18, 0.46)
			genome["finisher_bias"] = _rng_rangef(rng, 0.28, 0.55)
			genome["preferred_tactic"] = "retreat"
		"artillery":
			genome["caution_bias"] = _rng_rangef(rng, 0.42, 0.72)
			genome["aggression_bias"] = _rng_rangef(rng, 0.38, 0.75)
			genome["ambush_bias"] = _rng_rangef(rng, 0.72, 1.05)
			genome["finisher_bias"] = _rng_rangef(rng, 0.32, 0.62)
			genome["preferred_tactic"] = "ambush"
		"webber":
			genome["caution_bias"] = _rng_rangef(rng, 0.38, 0.68)
			genome["aggression_bias"] = _rng_rangef(rng, 0.34, 0.66)
			genome["ambush_bias"] = _rng_rangef(rng, 0.52, 0.86)
			genome["finisher_bias"] = _rng_rangef(rng, 0.42, 0.72)
			genome["preferred_tactic"] = "strafe"
		"spine":
			genome["caution_bias"] = _rng_rangef(rng, 0.24, 0.52)
			genome["aggression_bias"] = _rng_rangef(rng, 0.58, 0.98)
			genome["ambush_bias"] = _rng_rangef(rng, 0.34, 0.72)
			genome["finisher_bias"] = _rng_rangef(rng, 0.46, 0.86)
			genome["preferred_tactic"] = "pressure"
		"adaptive":
			genome["preferred_tactic"] = "strafe"
