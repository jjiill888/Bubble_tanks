class_name SkillRegistry
## 技能牌总注册表
## 新增技能：往 _POOL 里追加一个字典即可，其余代码无需修改
##
## 字段说明：
##   id        : String  — 唯一标识
##   name      : String  — 卡牌显示名称
##   desc      : String  — 卡牌描述（支持 \n 换行，不含叠加层数，层数由 pick() 动态注入）
##   color     : Color   — 卡牌主题色
##   stackable : bool    — false=展示过一次永久移出池；true=可多次出现，受 max_stack 限制
##   max_stack : int     — stackable=true 时有效，玩家最多累积的层数

static var _POOL: Array[Dictionary] = [
	{
		"id":        "surfactant",
		"name":      "表面活性剂",
		"desc":      "子弹获得有限穿透\n第1层最多击破2个泡泡，第2层4个，最多叠5层",
		"color":     Color(0.3, 0.85, 1.0),
		"stackable": true,
		"max_stack": 5,
	},
	{
		"id":        "red_bull",
		"name":      "红牛",
		"desc":      "射击速度 +10%",
		"color":     Color(1.0, 0.25, 0.1),
		"stackable": true,
		"max_stack": 5,
	},
	{
		"id":        "spread",
		"name":      "尿尿分叉+1",
		"desc":      "主炮退化为核心泡\n长出两座贴身分炮塔，继续升级可扩展更多副炮",
		"color":     Color(0.75, 1.0, 0.3),
		"stackable": true,
		"max_stack": 5,
	},
	{
		"id":        "vampirism",
		"name":      "血红蛋白",
		"desc":      "击杀敌人时回复生命\n对小怪回复 1 点，对组合体和肉怪回复 3 点",
		"color":     Color(0.92, 0.18, 0.24),
		"stackable": true,
		"max_stack": 4,
	},
	{
		"id":        "vitality",
		"name":      "增生膜",
		"desc":      "最大生命 +20\n并立即回复 20 生命",
		"color":     Color(0.24, 0.95, 0.48),
		"stackable": true,
		"max_stack": 4,
	},
	{
		"id":        "antibody",
		"name":      "特异性抗体",
		"desc":      "小飞棍来咯\n1层解锁导弹，2/4层提射速，3/5层多一座发射器",
		"color":     Color(0.96, 0.82, 0.28),
		"stackable": true,
		"max_stack": 5,
	},
]

static func _use_ascii_ui() -> bool:
	return OS.has_feature("web")

static func _web_skill_copy(skill: Dictionary) -> Dictionary:
	if not _use_ascii_ui():
		return skill
	var localized := skill.duplicate()
	match String(skill.get("id", "")):
		"surfactant":
			localized["name"] = "Surfactant"
			localized["desc"] = "Bullets gain limited pierce\nLv1 pops 2 bubbles, Lv2 pops 4, up to 5 stacks"
		"red_bull":
			localized["name"] = "Red Bull"
			localized["desc"] = "Fire rate +10%"
		"spread":
			localized["name"] = "Spread +1"
			localized["desc"] = "Main cannon collapses to a core shot\nGain two close side turrets, more with more stacks"
		"vampirism":
			localized["name"] = "Hemoglobin"
			localized["desc"] = "Heal on kill\n+1 HP from small enemies, +3 HP from compound and tank enemies"
		"vitality":
			localized["name"] = "Growth Membrane"
			localized["desc"] = "Max HP +20\nImmediately heal 20 HP"
		"antibody":
			localized["name"] = "Specific Antibody"
			localized["desc"] = "Little flying stick incoming\nLv1 unlocks missiles, Lv2/Lv4 faster fire, Lv3/Lv5 +1 launcher"
	return localized

static func _find_skill(skill_id: String) -> Dictionary:
	for skill in _POOL:
		if skill["id"] == skill_id:
			return skill
	return {}

static func can_acquire(skill_id: String, acquired: Array) -> bool:
	var skill := _find_skill(skill_id)
	if skill.is_empty():
		return false
	if not skill.get("stackable", false):
		return not acquired.has(skill_id)
	return acquired.count(skill_id) < int(skill.get("max_stack", 1))

## 挑选 count 张技能牌
##   shown    : 本局已展示过的 id（仅 stackable=false 的牌受此限制）
##   acquired : 玩家已选过的技能 id 列表（含重复，用于计算叠加层数）
## 返回的字典已注入 "_stack_cur" / "_stack_max" 字段供 UI 显示
static func pick(count: int, shown: Array, acquired: Array) -> Array[Dictionary]:
	var pool := _POOL.duplicate()
	pool.shuffle()

	var result: Array[Dictionary] = []

	for s in pool:
		if result.size() >= count:
			break
		var cur_stack: int = acquired.count(s["id"])
		if s["stackable"]:
			if can_acquire(s["id"], acquired):
				result.append(_annotate(s, cur_stack))
		else:
			if not shown.has(s["id"]) and can_acquire(s["id"], acquired):
				result.append(_annotate(s, cur_stack))

	return result

## 为技能字典注入当前/最大叠加信息（返回副本，不修改 _POOL 原数据）
static func _annotate(s: Dictionary, cur_stack: int) -> Dictionary:
	var d := _web_skill_copy(s)
	d["_stack_cur"] = cur_stack
	d["_stack_max"] = s["max_stack"]
	return d
