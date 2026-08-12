extends SceneTree


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() != 1:
		print("用法：godot --headless --script tools/inspect_character_material.gd -- <模型路径>")
		quit(2)
		return
	var scene := load(args[0]) as PackedScene
	if scene == null:
		print("FAIL 无法加载 ", args[0])
		quit(1)
		return
	var root := scene.instantiate()
	var meshes := root.find_children("*", "MeshInstance3D", true, false)
	for mesh_node in meshes:
		var mesh_instance := mesh_node as MeshInstance3D
		print("MESH ", mesh_instance.name, " material_override=", mesh_instance.material_override)
		for surface in mesh_instance.mesh.get_surface_count():
			var material := mesh_instance.mesh.surface_get_material(surface)
			print("SURFACE ", surface, " material=", material)
			if material is StandardMaterial3D:
				var standard := material as StandardMaterial3D
				print("  albedo=", standard.albedo_color)
				print("  vertex_color_use_as_albedo=", standard.vertex_color_use_as_albedo)
			var arrays := mesh_instance.mesh.surface_get_arrays(surface)
			var colors := arrays[Mesh.ARRAY_COLOR] as PackedColorArray
			if colors.is_empty():
				print("  colors=EMPTY")
			else:
				var minimum := colors[0]
				var maximum := colors[0]
				for color in colors:
					minimum = Color(minf(minimum.r, color.r), minf(minimum.g, color.g), minf(minimum.b, color.b), minf(minimum.a, color.a))
					maximum = Color(maxf(maximum.r, color.r), maxf(maximum.g, color.g), maxf(maximum.b, color.b), maxf(maximum.a, color.a))
				print("  colors=", colors.size(), " min=", minimum, " max=", maximum, " first=", colors[0])
	root.free()
	quit(0)
