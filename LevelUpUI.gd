class_name LevelUpUI
extends CanvasLayer
## 升级技能选择界面
## 用法：
##   var ui = LevelUpUI.create(skills, func(id): ...)
##   add_child(ui)

var _skills: Array[Dictionary] = []
var _on_chosen: Callable
var _chooser_name := ""
var _interactive := true
var _subtitle_label: Label = null
var _card_buttons: Dictionary = {}
var _resolved := false

func _use_ascii_ui() -> bool:
	return OS.has_feature("web")

## 工厂方法：创建并配置 UI 实例
static func create(skills: Array[Dictionary], on_chosen: Callable, chooser_name: String = "", interactive: bool = true) -> LevelUpUI:
	var ui := LevelUpUI.new()
	ui._skills   = skills
	ui._on_chosen = on_chosen
	ui._chooser_name = chooser_name
	ui._interactive = interactive
	ui.layer        = 10                           # 渲染在普通 UI 之上
	ui.process_mode = Node.PROCESS_MODE_ALWAYS     # 游戏暂停时仍可交互
	return ui

func _ready() -> void:
	_build_ui()

# ─── UI 构建 ────────────────────────────────────────────────────────────────

func _build_ui() -> void:
	# 灰色半透明遮罩
	var bg := ColorRect.new()
	bg.color          = Color(0.05, 0.07, 0.12, 0.72)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.process_mode   = Node.PROCESS_MODE_ALWAYS
	bg.mouse_filter   = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	# 升级标题
	var title := _make_label("LEVEL UP" if _use_ascii_ui() else "— 升 级 —", 38, Color(1.0, 1.0, 1.0, 0.95))
	title.anchor_left   = 0.0
	title.anchor_right  = 1.0
	title.offset_top    = 70.0
	title.offset_bottom = 130.0
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(title)

	# 副标题
	_subtitle_label = _make_label(_subtitle_text(), 18, Color(0.75, 0.80, 0.88, 0.85))
	_subtitle_label.anchor_left   = 0.0
	_subtitle_label.anchor_right  = 1.0
	_subtitle_label.offset_top    = 132.0
	_subtitle_label.offset_bottom = 168.0
	_subtitle_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(_subtitle_label)

	# 技能卡容器（水平居中）
	var hbox := HBoxContainer.new()
	hbox.anchor_left   =  0.5
	hbox.anchor_right  =  0.5
	hbox.anchor_top    =  0.5
	hbox.anchor_bottom =  0.5
	hbox.offset_left   = -390.0
	hbox.offset_right  =  390.0
	hbox.offset_top    = -130.0
	hbox.offset_bottom =  130.0
	hbox.add_theme_constant_override("separation", 26)
	hbox.process_mode  = Node.PROCESS_MODE_ALWAYS
	hbox.mouse_filter  = Control.MOUSE_FILTER_PASS
	add_child(hbox)

	for skill in _skills:
		hbox.add_child(_build_card(skill))

func _build_card(skill: Dictionary) -> Control:
	var btn := Button.new()
	btn.custom_minimum_size = Vector2(225, 260)
	btn.focus_mode = Control.FOCUS_NONE
	btn.process_mode = Node.PROCESS_MODE_ALWAYS
	btn.mouse_filter = Control.MOUSE_FILTER_STOP
	btn.disabled = not _interactive

	# 普通状态样式
	var normal := StyleBoxFlat.new()
	normal.bg_color     = Color(0.08, 0.11, 0.18, 0.93)
	normal.border_color = skill["color"]
	normal.set_border_width_all(3)
	normal.set_corner_radius_all(14)
	btn.add_theme_stylebox_override("normal", normal)

	# 悬停样式
	var hover := normal.duplicate() as StyleBoxFlat
	hover.bg_color = Color(0.15, 0.20, 0.32, 0.97)
	hover.set_border_width_all(5)
	btn.add_theme_stylebox_override("hover", hover)

	# 按下样式
	var pressed := hover.duplicate() as StyleBoxFlat
	pressed.bg_color = Color(0.22, 0.28, 0.44, 1.0)
	btn.add_theme_stylebox_override("pressed", pressed)

	# 卡内容 VBox
	var vbox := VBoxContainer.new()
	vbox.anchor_left   =  0.0
	vbox.anchor_right  =  1.0
	vbox.anchor_top    =  0.0
	vbox.anchor_bottom =  1.0
	vbox.offset_left   =  18.0
	vbox.offset_right  = -18.0
	vbox.offset_top    =  22.0
	vbox.offset_bottom = -22.0
	vbox.add_theme_constant_override("separation", 14)
	btn.add_child(vbox)

	# 技能名
	var name_lbl := _make_label(skill["name"], 26, skill["color"])
	name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(name_lbl)

	# 叠加层数（仅 stackable 技能显示）
	if skill.get("stackable", false):
		var cur: int = skill.get("_stack_cur", 0)
		var mx: int  = skill.get("_stack_max", 5)
		var stack_lbl := _make_label(("Stack %d / %d" if _use_ascii_ui() else "当前 %d / %d 层") % [cur, mx], 14,
				Color(skill["color"].r, skill["color"].g, skill["color"].b, 0.75))
		stack_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		vbox.add_child(stack_lbl)

	# 分隔线
	var sep := ColorRect.new()
	sep.color = Color(skill["color"].r, skill["color"].g, skill["color"].b, 0.45)
	sep.custom_minimum_size = Vector2(0, 2)
	vbox.add_child(sep)

	# 描述
	var desc_lbl := _make_label(skill["desc"], 15, Color(0.85, 0.88, 0.92, 0.90))
	desc_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	desc_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(desc_lbl)

	var skill_id: String = skill["id"]
	_card_buttons[skill_id] = btn
	btn.pressed.connect(func(): _on_card_pressed(skill_id))
	return btn

func _on_card_pressed(skill_id: String) -> void:
	if not _interactive or _resolved:
		return
	_resolved = true
	_on_chosen.call(skill_id)

func reveal_choice(skill_id: String, chooser_name: String = "") -> void:
	_resolved = true
	if not chooser_name.is_empty():
		_chooser_name = chooser_name
	if _subtitle_label != null:
		var chosen_skill_name := _skill_name_by_id(skill_id)
		_subtitle_label.text = ("%s chose %s" if _use_ascii_ui() else "%s 选择了 %s") % [
			_chooser_name if not _chooser_name.is_empty() else ("Player" if _use_ascii_ui() else "玩家"),
			chosen_skill_name
		]
	for card_id in _card_buttons.keys():
		var button: Button = _card_buttons[card_id]
		if button == null or not is_instance_valid(button):
			continue
		button.disabled = true
		button.modulate = Color(1.0, 1.0, 1.0, 1.0) if String(card_id) == skill_id else Color(0.58, 0.58, 0.62, 0.78)

func _subtitle_text() -> String:
	if _chooser_name.is_empty():
		return "Choose a skill" if _use_ascii_ui() else "选择一张技能牌"
	if _interactive:
		return ("%s is choosing" if _use_ascii_ui() else "%s 正在选技能") % _chooser_name
	return ("Watching %s choose" if _use_ascii_ui() else "观看 %s 选技能") % _chooser_name

func _skill_name_by_id(skill_id: String) -> String:
	for skill in _skills:
		if String(skill.get("id", "")) == skill_id:
			return String(skill.get("name", skill_id))
	return skill_id

# ─── 辅助 ───────────────────────────────────────────────────────────────────

func _make_label(text: String, font_size: int, color: Color) -> Label:
	var lbl := Label.new()
	lbl.text         = text
	lbl.process_mode = Node.PROCESS_MODE_ALWAYS
	lbl.add_theme_font_size_override("font_size", font_size)
	lbl.add_theme_color_override("font_color", color)
	lbl.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.7))
	lbl.add_theme_constant_override("shadow_offset_x", 2)
	lbl.add_theme_constant_override("shadow_offset_y", 2)
	return lbl
