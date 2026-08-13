class_name WaveSpawnLedger
extends RefCounted

const SPECIAL_TYPES := [&"charger", &"spitter", &"hunter", &"boomer"]

var _composition: Dictionary = {}
var _spawned_by_type: Dictionary = {}
var _spawned := 0
var _killed := 0
var _concurrent := 0
var _active_specials := 0


func reset(composition: Dictionary) -> void:
	_composition = composition.duplicate(true)
	_spawned_by_type.clear()
	_spawned = 0
	_killed = 0
	_concurrent = 0
	_active_specials = 0


func record_spawned(enemy_type: StringName) -> void:
	_spawned_by_type[enemy_type] = spawned_type(enemy_type) + 1
	_spawned += 1
	_concurrent += 1
	if enemy_type in SPECIAL_TYPES:
		_active_specials += 1


func record_killed(enemy_type: StringName) -> bool:
	if _killed < _spawned:
		_killed += 1
		_concurrent = maxi(_concurrent - 1, 0)
		if enemy_type in SPECIAL_TYPES:
			_active_specials = maxi(_active_specials - 1, 0)
	return is_cleared()


func next_spawn_type(special_allowed: bool, special_cap: int) -> StringName:
	if special_allowed and _active_specials < special_cap:
		if _has_remaining(&"charger"):
			return &"charger"
		if _has_remaining(&"spitter"):
			return &"spitter"
		if _has_remaining(&"hunter"):
			return &"hunter"
		if _has_remaining(&"boomer"):
			return &"boomer"
	if _has_remaining(&"common"):
		return &"common"
	return &""


func total_count() -> int:
	var total := 0
	for amount in _composition.values():
		total += int(amount)
	return total


func spawned_count() -> int:
	return _spawned


func killed_count() -> int:
	return _killed


func concurrent_count() -> int:
	return _concurrent


func active_special_count() -> int:
	return _active_specials


func spawned_type(enemy_type: StringName) -> int:
	return int(_spawned_by_type.get(enemy_type, 0))


func all_spawned() -> bool:
	return _spawned >= total_count()


func is_cleared() -> bool:
	var total := total_count()
	return _spawned >= total and _killed >= total


func _has_remaining(enemy_type: StringName) -> bool:
	return int(_composition.get(enemy_type, 0)) > spawned_type(enemy_type)
