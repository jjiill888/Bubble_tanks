extends Area2D

@export var max_hp: int = 1
var hp: int

func _ready() -> void:
	hp = max_hp
	add_to_group("enemy")

func die() -> void:
	hp -= 1
	if hp > 0:
		get_parent().on_bubble_damaged(self)
		return
	get_parent().on_bubble_destroyed(self)
	queue_free()
