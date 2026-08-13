class_name FireZone
extends Node3D

@export var owner_peer_id := 1
@export var radius := 5.0
@export var duration := 8.0
@export var damage_per_second := 30.0

var _remaining := 8.0
var _tick := 0.0
var _active := false


func _ready() -> void:
	add_to_group("fire_zones")
	visible = false
	set_physics_process(false)


func activate(position: Vector3, owner_id: int, zone_radius: float, zone_duration: float, dps: float) -> void:
	global_position = position
	owner_peer_id = owner_id
	radius = zone_radius
	duration = zone_duration
	damage_per_second = dps
	_remaining = duration
	_tick = 0.0
	_active = true
	visible = true
	$Visual.scale = Vector3(radius, 0.05, radius)
	var flames := get_node_or_null("Flames") as GPUParticles3D
	if flames != null:
		flames.scale = Vector3(radius, 1.0, radius)
		flames.emitting = true
	set_physics_process(true)


func _physics_process(delta: float) -> void:
	if not _active or not NetworkManager.is_server():
		return
	_remaining -= delta
	_tick += delta
	if _tick >= 0.25:
		var step := _tick
		_tick = 0.0
		for zombie in get_tree().get_nodes_in_group("zombies"):
			var body := zombie as Node3D
			if body == null or global_position.distance_to(body.global_position) > radius:
				continue
			var health := body.get_node_or_null("Health") as ZombieHealth
			if health != null:
				health.take_damage(damage_per_second * step, _owner_player())
	if _remaining <= 0.0:
		_active = false
		visible = false
		var flames := get_node_or_null("Flames") as GPUParticles3D
		if flames != null:
			flames.emitting = false
		set_physics_process(false)


func _owner_player() -> Node:
	for player in get_tree().get_nodes_in_group("players"):
		if player.get_multiplayer_authority() == owner_peer_id:
			return player
	return null
