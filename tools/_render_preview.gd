extends SceneTree

# 渲染玩家与丧尸到 PNG，对比朝向
const FILES := [
	["player", "res://assets/models/characters/char_player_01.glb", Vector3(0, 0.9, 0), 0.578],
	["zombie", "res://assets/models/characters/char_zombie_common_01.glb", Vector3(0, 0.85, 0), 1.45],
]


func _initialize() -> void:
	var root_node := Node3D.new()
	get_root().add_child(root_node)
	var vp := SubViewport.new()
	vp.size = Vector2i(512, 512)
	vp.transparent_bg = false
	root_node.add_child(vp)
	var cam := Camera3D.new()
	vp.add_child(cam)
	cam.look_at_from_position(Vector3(0, 1.6, 2.4), Vector3(0, 1.0, 0), Vector3.UP)
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