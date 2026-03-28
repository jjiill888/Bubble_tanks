extends Node2D

# 十字形绿藻装饰，覆盖整个最大竞技场
# 网格分布 + 随机偏移，固定种子保证每局相同布局

const GRID_SIZE   := 312.0   # 网格间距（像素）
const JITTER      := 65.0    # 随机位移量
const BASE_ARM_LEN := 13.0   # 十字臂半长（base 尺寸）
const BASE_ARM_W  := 5.0     # 十字臂半宽
const SIZE_VAR    := 0.55    # 尺寸变化范围 (0…1)

# 覆盖最大竞技场 (~6720×3780 at lv15) + 余量
const COLS := 35
const ROWS := 22

var _algae: Array[Dictionary] = []

func _ready() -> void:
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	for row in range(ROWS):
		for col in range(COLS):
			var cx := col * GRID_SIZE + rng.randf_range(-JITTER, JITTER)
			var cy := row * GRID_SIZE + rng.randf_range(-JITTER, JITTER)
			var sc  := 0.6 + rng.randf() * SIZE_VAR
			var rot := rng.randf_range(-0.22, 0.22)
			# 绿色调微变
			var g   := rng.randf_range(0.55, 0.80)
			var r   := rng.randf_range(0.07, 0.17)
			var alpha := rng.randf_range(0.58, 0.78)
			_algae.append({
				"pos"    : Vector2(cx, cy),
				"arm_len": BASE_ARM_LEN * sc,
				"arm_w"  : BASE_ARM_W * sc,
				"rot"    : rot,
				"c_fill" : Color(r, g, 0.18, alpha),
				"c_rim"  : Color(r * 0.5, g * 0.52, 0.10, 0.92),
			})

func _draw() -> void:
	for a in _algae:
		_draw_cross(a)

func _draw_cross(a: Dictionary) -> void:
	var arm_len : float  = a["arm_len"]
	var arm_w   : float  = a["arm_w"]
	var c_fill  : Color  = a["c_fill"]
	var c_rim   : Color  = a["c_rim"]

	draw_set_transform(a["pos"], a["rot"], Vector2.ONE)

	# 两段矩形构成十字主体
	var h_rect := Rect2(-arm_len, -arm_w, arm_len * 2.0, arm_w * 2.0)
	var v_rect := Rect2(-arm_w, -arm_len, arm_w * 2.0, arm_len * 2.0)
	draw_rect(h_rect, c_fill, true)
	draw_rect(v_rect, c_fill, true)

	# 四端圆头，让十字看起来更有机感
	draw_circle(Vector2( arm_len, 0.0),   arm_w, c_fill, true)
	draw_circle(Vector2(-arm_len, 0.0),   arm_w, c_fill, true)
	draw_circle(Vector2(0.0,  arm_len),   arm_w, c_fill, true)
	draw_circle(Vector2(0.0, -arm_len),   arm_w, c_fill, true)

	# 描边轮廓
	draw_rect(h_rect, c_rim, false, 1.2)
	draw_rect(v_rect, c_rim, false, 1.2)

	# 中心高光（细胞感）
	draw_circle(Vector2.ZERO, arm_w * 0.46, Color(0.5, 1.0, 0.6, 0.22), true)

	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
