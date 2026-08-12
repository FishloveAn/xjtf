extends SceneTree

const REQUIRED := [&"idle", &"walk", &"attack", &"hurt", &"death", &"spawn"]
const FILES := [
	"char_goblin_common_lean.glb",
	"char_goblin_common_strong.glb",
	"char_goblin_charger.glb",
	"char_goblin_spitter.glb",
	"char_goblin_hunter.glb",
	"char_goblin_boomer.glb",
	"char_zombie_spitter_01.glb",
]


func _initialize() -> void:
	var failures := 0
	for filename in FILES:
		var scene := load("res://assets/models/characters/" + filename) as PackedScene
		if scene == null:
			failures += 1
			print("FAIL ", filename, " 无法加载")
			continue
		var root := scene.instantiate()
		var player := _find_animation_player(root)
		if player == null:
			failures += 1
			print("FAIL ", filename, " 缺 AnimationPlayer")
			root.free()
			continue
		var missing: Array[StringName] = []
		for animation_name in REQUIRED:
			if not player.has_animation(animation_name):
				missing.append(animation_name)
		if missing.is_empty():
			print("PASS ", filename, " animations=", player.get_animation_list())
		else:
			failures += 1
			print("FAIL ", filename, " 缺动画 ", missing)
		root.free()
	print("ANIMATION_SUMMARY checked=", FILES.size(), " fail=", failures)
	quit(failures)


func _find_animation_player(node: Node) -> AnimationPlayer:
	if node is AnimationPlayer:
		return node as AnimationPlayer
	for child in node.get_children():
		var found := _find_animation_player(child)
		if found != null:
			return found
	return null
