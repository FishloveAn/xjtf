extends SceneTree

# 正面渲染正式角色到 PNG，供轮廓、材质、朝向与比例验收。
const FILES := [
	["player", "res://assets/models/characters/char_player_01.glb", Vector3(0, 0, 0), 1.0],
	["zombie", "res://assets/models/characters/char_zombie_common_01.glb", Vector3(0, 0, 0), 1.0],
	["zombie02", "res://assets/models/characters/char_zombie_common_02.glb", Vector3(0, 0, 0), 1.0],
	["spitter", "res://assets/models/characters/char_zombie_spitter_01.glb", Vector3(0, 0, 0), 1.0],
	["goblin_lean", "res://assets/models/characters/char_goblin_common_lean.glb", Vector3(0, 0, 0), 1.0],
	["goblin_strong", "res://assets/models/characters/char_goblin_common_strong.glb", Vector3(0, 0, 0), 1.0],
	["goblin_charger", "res://assets/models/characters/char_goblin_charger.glb", Vector3(0, 0, 0), 1.0],
	["goblin_spitter", "res://assets/models/characters/char_goblin_spitter.glb", Vector3(0, 0, 0), 1.0],
	["goblin_hunter", "res://assets/models/characters/char_goblin_hunter.glb", Vector3(0, 0, 0), 1.0],
	["goblin_boomer", "res://assets/models/characters/char_goblin_boomer.glb", Vector3(0, 0, 0), 1.0],
]


func _initialize() -> void:
	var root_node := Node3D.new()
	get_root().add_child(root_node)
	var vp := SubViewport.new()
	vp.size = Vector2i(512, 512)
	vp.transparent_bg = false
	vp.own_world_3d = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root_node.add_child(vp)
	var environment := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.12, 0.12, 0.14)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color.WHITE
	env.ambient_light_energy = 1.2
	environment.environment = env
	vp.add_child(environment)
	var cam := Camera3D.new()
	vp.add_child(cam)
	cam.current = true
	# 模型统一面朝 -Z，因此相机位于 -Z 才是正面视图。
	cam.look_at_from_position(Vector3(0, 1.35, -3.0), Vector3(0, 0.95, 0), Vector3.UP)
	var light := DirectionalLight3D.new()
	light.rotation = Vector3(-deg_to_rad(45), deg_to_rad(30), 0)
	light.light_energy = 1.2
	vp.add_child(light)
	for entry in FILES:
		var tag: String = entry[0]
		var path: String = entry[1]
		var pos: Vector3 = entry[2]
		var sc: float = entry[3]
		var ps: PackedScene = load(path)
		if ps == null:
			printerr("FAIL " + path)
			continue
		var inst: Node3D = ps.instantiate()
		inst.position = pos
		inst.scale = Vector3(sc, sc, sc)
		vp.add_child(inst)
		await RenderingServer.frame_post_draw
		await RenderingServer.frame_post_draw
		var img := vp.get_texture().get_image()
		var err := img.save_png("user://preview_" + tag + ".png")
		print("saved user://preview_" + tag + ".png err=", err)
		vp.remove_child(inst)
		inst.queue_free()
	print("done")
	quit(0)
