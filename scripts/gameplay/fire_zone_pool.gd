class_name FireZonePool
extends Node3D

const CAPACITY := 8
const FIRE_ZONE_SCENE := preload("res://scenes/gameplay/fire_zone.tscn")
var _zones: Array[FireZone] = []
var _cursor := 0


func _ready() -> void:
	add_to_group("fire_zone_pool")
	for i in CAPACITY:
		var zone := FIRE_ZONE_SCENE.instantiate() as FireZone
		add_child(zone)
		_zones.append(zone)


func activate_zone(position: Vector3, owner_peer_id: int, radius: float, duration: float, dps: float) -> void:
	var zone := _zones[_cursor]
	zone.activate(position, owner_peer_id, radius, duration, dps)
	_cursor = (_cursor + 1) % CAPACITY
