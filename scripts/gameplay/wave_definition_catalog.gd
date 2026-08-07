class_name WaveDefinitionCatalog
extends RefCounted

var _arena_waves: Array = []
var _level_waves: Array = []


func load_from_path(path: String) -> bool:
	_arena_waves.clear()
	_level_waves.clear()
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return false
	var parsed = JSON.parse_string(file.get_as_text())
	if not (parsed is Dictionary):
		return false
	var arena = parsed.get("waves", [])
	if not (arena is Array) or arena.is_empty():
		return false
	var levels = parsed.get("level_waves", [])
	if not (levels is Array):
		return false
	_arena_waves = arena.duplicate(true)
	_level_waves = levels.duplicate(true)
	return true


func arena_waves() -> Array:
	return _arena_waves.duplicate(true)


func level_waves() -> Array:
	return _level_waves.duplicate(true)


func find(wave_id: String) -> Dictionary:
	var level_wave := _find_in(_level_waves, wave_id)
	if not level_wave.is_empty():
		return level_wave
	return _find_in(_arena_waves, wave_id)


func find_level(wave_id: String) -> Dictionary:
	return find(wave_id)


func composition_total(config: Dictionary) -> int:
	var total := 0
	var composition: Dictionary = config.get("composition", {})
	for amount in composition.values():
		total += int(amount)
	return total


func _find_in(waves: Array, wave_id: String) -> Dictionary:
	for entry in waves:
		if entry is Dictionary and String(entry.get("id", "")) == wave_id:
			return entry.duplicate(true)
	return {}
