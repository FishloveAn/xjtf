class_name WeaponStand
extends Node3D
## 地图武器架：每名玩家可独立领取一次，不会被队友抢空。

const PICKUP_RANGE := 2.5

@export_enum("shotgun", "rifle", "smg") var weapon_id := "shotgun"
var _claimed_peers: Dictionary = {}


func _ready() -> void:
	add_to_group("weapon_stands")
	for child in $Models.get_children():
		child.visible = String(child.name).to_lower() == weapon_id
		if child.visible:
			_apply_outline(child)


func _apply_outline(root: Node) -> void:
	var shader := Shader.new()
	shader.code = "shader_type spatial; render_mode unshaded, cull_front; void vertex(){ VERTEX *= 1.035; } void fragment(){ ALBEDO=vec3(0.1,0.8,1.0); EMISSION=ALBEDO*1.8; }"
	var outline := ShaderMaterial.new()
	outline.shader = shader
	for child in root.get_children():
		if child is GeometryInstance3D:
			(child as GeometryInstance3D).material_overlay = outline
		_apply_outline(child)


func display_name() -> String:
	match weapon_id:
		"shotgun": return "霰弹枪"
		"rifle": return "步枪"
		"smg": return "冲锋枪"
	return weapon_id


@rpc("any_peer", "call_local", "reliable")
func request_pickup() -> void:
	if not NetworkManager.is_server():
		return
	var peer_id := multiplayer.get_remote_sender_id()
	if peer_id == 0:
		peer_id = multiplayer.get_unique_id()
	if _claimed_peers.has(peer_id):
		return
	var player := _find_player(peer_id)
	if player == null or global_position.distance_to(player.global_position) > PICKUP_RANGE:
		return
	if bool(player.call("has_claimed_weapon_stand", weapon_id)):
		return
	if not bool(player.call("equip_primary", weapon_id)):
		return
	player.call("mark_weapon_stand_claimed", weapon_id)
	_claimed_peers[peer_id] = true


func _find_player(peer_id: int) -> Node3D:
	for player in get_tree().get_nodes_in_group("players"):
		if player.get_multiplayer_authority() == peer_id:
			return player as Node3D
	return null
