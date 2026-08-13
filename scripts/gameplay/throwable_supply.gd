class_name ThrowableSupply
extends Node3D
## 固定投掷物补给；每名玩家可独立领取一次。

const PICKUP_RANGE := 2.5
@export_enum("grenade", "molotov") var throwable_type := "grenade"


func _ready() -> void:
	add_to_group("throwable_supplies")
	$Grenade.visible = throwable_type == "grenade"
	$Molotov.visible = throwable_type == "molotov"


func display_name() -> String:
	return "手雷" if throwable_type == "grenade" else "燃烧瓶"


@rpc("any_peer", "call_local", "reliable")
func request_pickup() -> void:
	if not NetworkManager.is_server():
		return
	var peer_id := multiplayer.get_remote_sender_id()
	if peer_id == 0:
		peer_id = multiplayer.get_unique_id()
	for player in get_tree().get_nodes_in_group("players"):
		if player.get_multiplayer_authority() != peer_id:
			continue
		if global_position.distance_to(player.global_position) <= PICKUP_RANGE:
			player.call("grant_throwable", throwable_type)
		return
