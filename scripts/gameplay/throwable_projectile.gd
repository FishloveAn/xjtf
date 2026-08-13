class_name ThrowableProjectile
extends CharacterBody3D
## 服务器权威投掷物；客户端只接收位置并播放表现。

@export_enum("grenade", "molotov") var throwable_type := "grenade"
@export var owner_peer_id := 1
@export var initial_velocity := Vector3.ZERO

const GRENADE_FUSE := 2.5
const GRENADE_RADIUS := 6.0
const MOLOTOV_RADIUS := 5.0
const FIRE_DURATION := 8.0
const FIRE_DPS := 30.0

var _age := 0.0


func _enter_tree() -> void:
	set_multiplayer_authority(NetworkManager.SERVER_ID)


func _ready() -> void:
	velocity = initial_velocity
	_configure_sync()


func _configure_sync() -> void:
	var sync := get_node_or_null("ProjectileSync") as MultiplayerSynchronizer
	if sync == null:
		return
	var config := SceneReplicationConfig.new()
	config.add_property(NodePath(".:position"))
	config.property_set_replication_mode(NodePath(".:position"), SceneReplicationConfig.REPLICATION_MODE_ALWAYS)
	config.add_property(NodePath(".:rotation"))
	config.property_set_replication_mode(NodePath(".:rotation"), SceneReplicationConfig.REPLICATION_MODE_ALWAYS)
	sync.replication_config = config
	sync.replication_interval = 0.05


func _physics_process(delta: float) -> void:
	if not NetworkManager.is_server():
		return
	_age += delta
	velocity += get_gravity() * delta
	var collision := move_and_collide(velocity * delta)
	if collision != null:
		if throwable_type == "molotov":
			_explode()
			return
		velocity = velocity.bounce(collision.get_normal()) * 0.45
	if throwable_type == "grenade" and _age >= GRENADE_FUSE:
		_explode()
	elif _age >= 5.0:
		_explode()


func _explode() -> void:
	if throwable_type == "grenade":
		_apply_radial_damage(GRENADE_RADIUS)
	else:
		_spawn_fire_zone()
	var main := get_tree().current_scene
	if main != null and main.has_method("broadcast_aoe_visual"):
		main.call("broadcast_aoe_visual", global_position, throwable_type)
	queue_free()


func _apply_radial_damage(radius: float) -> void:
	for zombie in get_tree().get_nodes_in_group("zombies"):
		var body := zombie as Node3D
		if body == null:
			continue
		var distance := global_position.distance_to(body.global_position)
		if distance > radius or _is_blocked(body.global_position + Vector3.UP):
			continue
		var damage := lerpf(250.0, 50.0, distance / radius)
		var health := body.get_node_or_null("Health") as ZombieHealth
		if health != null:
			health.take_damage(damage, _owner_player())


func _spawn_fire_zone() -> void:
	var pools := get_tree().get_nodes_in_group("fire_zone_pool")
	if not pools.is_empty():
		(pools[0] as FireZonePool).activate_zone(global_position, owner_peer_id, MOLOTOV_RADIUS, FIRE_DURATION, FIRE_DPS)


func _is_blocked(target: Vector3) -> bool:
	var query := PhysicsRayQueryParameters3D.create(global_position + Vector3.UP * 0.15, target, 1, [get_rid()])
	return not get_world_3d().direct_space_state.intersect_ray(query).is_empty()


func _owner_player() -> Node:
	for player in get_tree().get_nodes_in_group("players"):
		if player.get_multiplayer_authority() == owner_peer_id:
			return player
	return null
