extends Area2D

# 动态附加到 EnemyBoss 生成的每个泡泡 Area2D 上
var boss: Node = null
var bubble_idx: int = 0

func _ready() -> void:
	add_to_group("enemy")

func die() -> void:
	if is_instance_valid(boss):
		boss.on_bubble_hit(bubble_idx)
