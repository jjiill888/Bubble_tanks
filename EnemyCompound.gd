extends Area2D

@export var speed: float = 75.0
var network_entity_id := 0
var authority_simulation := true
var _network_target_position := Vector2.ZERO
var _has_network_target := false

# 大泡泡
const MED_POS      := Vector2(0.0, -4.0)
const MED_R        := 26.0
const MED_NUC_OFF  := Vector2(-7.0, -9.0)
const MED_NUC_R    := 9.5
# 小泡泡（两侧）
const SM_R         := 15.0
const SM_LEFT      := Vector2(-23.0, 13.0)
const SM_RIGHT     := Vector2(23.0, 13.0)
const CONTACT_DAMAGE := 8
var left_alive  := true
var right_alive := true
var big_damaged := false  # 大泡泡受到第一击后变色
var _last_hit_by_peer_id := 0
var _hit_world: Object = null
var _left_hit_entry_id := 0
var _right_hit_entry_id := 0
var _big_hit_entry_id := 0

func _ready() -> void:
	add_to_group("compound_enemy")
	_setup_hit_world()

func _exit_tree() -> void:
	_clear_hit_world_entries()

func _draw_small(center: Vector2) -> void:
	draw_circle(center, SM_R, Color(1.0, 0.22, 0.22, 0.68), true, -1.0, true)
	draw_circle(center, SM_R, Color(0.85, 0.06, 0.06, 0.82), false, 1.5, true)
	draw_circle(center + Vector2(4.5, -5.5), 4.0, Color(1.0, 1.0, 1.0, 0.2), true, -1.0, true)

func _draw() -> void:
	# 小泡泡（存活时才画）
	if left_alive:
		_draw_small(SM_LEFT)
	if right_alive:
		_draw_small(SM_RIGHT)
	# 大泡泡主体（受伤后变橙色）
	var bubble_color := Color(1.0, 0.45, 0.1, 0.75) if big_damaged else Color(1.0, 0.22, 0.22, 0.75)
	draw_circle(MED_POS, MED_R, bubble_color, true, -1.0, true)
	# 大泡泡细胞膜
	draw_circle(MED_POS, MED_R, Color(0.85, 0.06, 0.06, 0.9), false, 2.2, true)
	# 细胞核
	var nuc = MED_POS + MED_NUC_OFF
	draw_circle(nuc, MED_NUC_R, Color(0.52, 0.04, 0.04, 0.95), true, -1.0, true)
	draw_circle(nuc, MED_NUC_R, Color(0.32, 0.0, 0.0, 0.85), false, 1.5, true)
	# 大泡泡高光
	draw_circle(MED_POS + Vector2(9.0, -11.0), 6.5, Color(1.0, 1.0, 1.0, 0.24), true, -1.0, true)
	draw_circle(MED_POS + Vector2(10.5, -12.5), 3.5, Color(1.0, 1.0, 1.0, 0.14), true, -1.0, true)

func _process(delta: float) -> void:
	if not authority_simulation:
		return
	var scene: Node = get_tree().current_scene
	var target_node: Node2D = scene.get_nearest_player_node(global_position) if scene and scene.has_method("get_nearest_player_node") else null
	var target: Vector2 = target_node.global_position if is_instance_valid(target_node) else get_viewport_rect().size * 0.5
	var to_target: Vector2 = target - global_position
	if to_target.length_squared() < 30.0 * 30.0:
		var target_peer_id: int = scene.get_player_peer_id(target_node) if scene and scene.has_method("get_player_peer_id") else 1
		scene.take_damage(CONTACT_DAMAGE, target_peer_id)
		queue_free()
		return
	global_position += to_target.normalized() * speed * delta
	_sync_hit_world_entries()
	_cleanup_if_outside_bounds()

func _setup_hit_world() -> void:
	var scene := get_tree().current_scene
	if scene and scene.has_method("get_compound_hit_world"):
		_hit_world = scene.get_compound_hit_world()
	_refresh_hit_world_registration()

func _refresh_hit_world_registration() -> void:
	if _hit_world == null or not authority_simulation:
		_clear_hit_world_entries()
		return
	if _left_hit_entry_id == 0:
		_left_hit_entry_id = _hit_world.register_entry(get_instance_id(), "left", SM_R)
	if _right_hit_entry_id == 0:
		_right_hit_entry_id = _hit_world.register_entry(get_instance_id(), "right", SM_R)
	if _big_hit_entry_id == 0:
		_big_hit_entry_id = _hit_world.register_entry(get_instance_id(), "big", MED_R)
	_sync_hit_world_entries()

func _sync_hit_world_entries() -> void:
	if _hit_world == null or not authority_simulation:
		return
	if _left_hit_entry_id != 0:
		_hit_world.update_entry(_left_hit_entry_id, to_global(SM_LEFT), left_alive)
	if _right_hit_entry_id != 0:
		_hit_world.update_entry(_right_hit_entry_id, to_global(SM_RIGHT), right_alive)
	if _big_hit_entry_id != 0:
		_hit_world.update_entry(_big_hit_entry_id, to_global(MED_POS), true)

func _clear_hit_world_entries() -> void:
	if _hit_world != null:
		if _left_hit_entry_id != 0:
			_hit_world.remove_entry(_left_hit_entry_id)
		if _right_hit_entry_id != 0:
			_hit_world.remove_entry(_right_hit_entry_id)
		if _big_hit_entry_id != 0:
			_hit_world.remove_entry(_big_hit_entry_id)
	_left_hit_entry_id = 0
	_right_hit_entry_id = 0
	_big_hit_entry_id = 0

func _cleanup_if_outside_bounds() -> void:
	var scene = get_tree().current_scene
	if scene and scene.has_method("is_outside_cleanup_bounds") and scene.is_outside_cleanup_bounds(global_position, 220.0):
		queue_free()

# 大泡泡被打中但未消灭（第一击）
func on_bubble_damaged(bubble: Area2D) -> void:
	if bubble.name == "BigBubble":
		big_damaged = true
		queue_redraw()

# 某个泡泡被消灭（HP归零）
func on_bubble_destroyed(bubble: Area2D) -> void:
	match bubble.name:
		"SmallBubbleLeft":
			left_alive = false
			_sync_hit_world_entries()
			queue_redraw()
		"SmallBubbleRight":
			right_alive = false
			_sync_hit_world_entries()
			queue_redraw()
		"BigBubble":
			var scene := get_tree().current_scene
			scene.add_score(2)
			if scene and scene.has_method("award_experience_for_enemy_kind"):
				scene.award_experience_for_enemy_kind("compound", _last_hit_by_peer_id)
			if _last_hit_by_peer_id > 0 and scene and scene.has_method("notify_enemy_killed"):
				scene.notify_enemy_killed(_last_hit_by_peer_id, "compound")
			if scene and scene.has_method("play_enemy_death_sfx"):
				scene.play_enemy_death_sfx()
			queue_free()

func hit_hit_world_part(part_name: String, projectile: Area2D, _bullet_radius: float) -> bool:
	_last_hit_by_peer_id = int(projectile.get_owner_peer_id()) if projectile != null and projectile.has_method("get_owner_peer_id") else 0
	match part_name:
		"left":
			if not left_alive:
				return false
			var left_bubble := get_node_or_null("SmallBubbleLeft")
			if left_bubble and left_bubble.has_method("die"):
				left_bubble.die()
				return true
		"right":
			if not right_alive:
				return false
			var right_bubble := get_node_or_null("SmallBubbleRight")
			if right_bubble and right_bubble.has_method("die"):
				right_bubble.die()
				return true
		"big":
			var big_bubble := get_node_or_null("BigBubble")
			if big_bubble and big_bubble.has_method("die"):
				big_bubble.die()
				return true
	return false

func hit_by_player_projectile(projectile: Area2D, bullet_radius: float) -> bool:
	_last_hit_by_peer_id = int(projectile.get_owner_peer_id()) if projectile != null and projectile.has_method("get_owner_peer_id") else 0
	return hit_by_player_bullet(projectile.global_position, bullet_radius)

func hit_by_player_bullet(bullet_pos: Vector2, bullet_radius: float) -> bool:
	var local_bullet_pos := to_local(bullet_pos)
	if left_alive:
		var left_reach := SM_R + bullet_radius
		if local_bullet_pos.distance_squared_to(SM_LEFT) <= left_reach * left_reach:
			var left_bubble := get_node_or_null("SmallBubbleLeft")
			if left_bubble and left_bubble.has_method("die"):
				left_bubble.die()
				return true
	if right_alive:
		var right_reach := SM_R + bullet_radius
		if local_bullet_pos.distance_squared_to(SM_RIGHT) <= right_reach * right_reach:
			var right_bubble := get_node_or_null("SmallBubbleRight")
			if right_bubble and right_bubble.has_method("die"):
				right_bubble.die()
				return true
	var big_reach := MED_R + bullet_radius
	if local_bullet_pos.distance_squared_to(MED_POS) > big_reach * big_reach:
		return false
	var big_bubble := get_node_or_null("BigBubble")
	if big_bubble and big_bubble.has_method("die"):
		big_bubble.die()
		return true
	return false

func configure_network_entity(entity_id: int, authority: bool) -> void:
	network_entity_id = entity_id
	authority_simulation = authority
	set_process(authority)
	_refresh_hit_world_registration()

func get_network_entity_state() -> Dictionary:
	return {
		"pos": global_position,
		"left_alive": left_alive,
		"right_alive": right_alive,
		"big_damaged": big_damaged,
	}

func apply_network_entity_state(state: Dictionary) -> void:
	_network_target_position = state.get("pos", global_position)
	if not _has_network_target:
		global_position = _network_target_position
	_has_network_target = true
	var next_left_alive := bool(state.get("left_alive", left_alive))
	var next_right_alive := bool(state.get("right_alive", right_alive))
	var next_big_damaged := bool(state.get("big_damaged", big_damaged))
	var needs_redraw := next_left_alive != left_alive or next_right_alive != right_alive or next_big_damaged != big_damaged
	left_alive = next_left_alive
	right_alive = next_right_alive
	big_damaged = next_big_damaged
	if needs_redraw:
		queue_redraw()

func tick_network_interpolation(delta: float) -> void:
	if authority_simulation or not _has_network_target:
		return
	var dist_sq := global_position.distance_squared_to(_network_target_position)
	if dist_sq > 220.0 * 220.0:
		global_position = _network_target_position
		return
	var blend: float = min(1.0, delta * 10.0)
	global_position = global_position.lerp(_network_target_position, blend)

func get_missile_target_local_point(from_global_position: Vector2 = Vector2.ZERO) -> Vector2:
	var local_from := to_local(from_global_position)
	var best_point := MED_POS
	var best_dist_sq := local_from.distance_squared_to(MED_POS)
	if left_alive:
		var left_dist_sq := local_from.distance_squared_to(SM_LEFT)
		if left_dist_sq < best_dist_sq:
			best_dist_sq = left_dist_sq
			best_point = SM_LEFT
	if right_alive:
		var right_dist_sq := local_from.distance_squared_to(SM_RIGHT)
		if right_dist_sq < best_dist_sq:
			best_point = SM_RIGHT
	return best_point

func _on_screen_exited() -> void:
	_cleanup_if_outside_bounds()
