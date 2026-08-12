extends SceneTree

const REQUIRED := [&"idle", &"walk", &"attack", &"hurt", &"death", &"spawn"]


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() != 1:
		print("用法：godot --headless --script tools/check_character_animation_file.gd -- <模型路径>")
		quit(2)
		return
	var path: String = args[0]
	var scene := load(path) as PackedScene
	if scene == null:
		print("FAIL ", path, " 无法加载")
		quit(1)
		return
	var root := scene.instantiate()
	var player := _find_animation_player(root)
	if player == null:
		print("FAIL ", path, " 缺 AnimationPlayer")
		root.free()
		quit(1)
		return
	var missing: Array[StringName] = []
	for animation_name in REQUIRED:
		if not player.has_animation(animation_name):
			missing.append(animation_name)
	if missing.is_empty():
		print("PASS ", path, " animations=", player.get_animation_list())
	else:
		print("FAIL ", path, " 缺动画 ", missing)
	root.free()
	quit(0 if missing.is_empty() else 1)


func _find_animation_player(node: Node) -> AnimationPlayer:
	if node is AnimationPlayer:
		return node as AnimationPlayer
	for child in node.get_children():
		var found := _find_animation_player(child)
		if found != null:
			return found
	return null
