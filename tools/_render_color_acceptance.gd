extends SceneTree

const ITEMS := [
	["res://assets/models/characters/char_player_01.glb", Vector3(-2.8, 0, 0), Vector3.ZERO, 1.0],
	["res://assets/models/weapons/wep_pistol_01.glb", Vector3(-1.45, 1.20, 0), Vector3(0, 90, 0), 1.8],
	["res://assets/models/weapons/wep_shotgun_01.glb", Vector3(-0.55, 1.18, 0), Vector3(0, 90, 0), 1.5],
	["res://assets/models/weapons/wep_rifle_01.glb", Vector3(0.45, 1.18, 0), Vector3(0, 90, 0), 1.5],
	["res://assets/models/weapons/wep_smg_01.glb", Vector3(1.35, 1.18, 0), Vector3(0, 90, 0), 1.5],
	["res://assets/models/props/prop_ammo_01.glb", Vector3(2.25, 0.38, 0), Vector3(0, -20, 0), 1.3],
	["res://assets/models/props/prop_medkit_01.glb", Vector3(2.95, 0.38, 0), Vector3(0, 20, 0), 1.5],
]


func _initialize() -> void:
	var holder := Node3D.new()
	get_root().add_child(holder)
	var viewport := SubViewport.new()
	viewport.size = Vector2i(960, 540)
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	holder.add_child(viewport)
	var environment_node := WorldEnvironment.new()
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color("2a3140")
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color("7a8cb8")
	environment.ambient_light_energy = 0.85
	environment_node.environment = environment
	viewport.add_child(environment_node)
	var floor_mesh := BoxMesh.new()
	floor_mesh.size = Vector3(8, 0.15, 3)
	var floor_material := StandardMaterial3D.new()
	floor_material.albedo_color = Color("3a3f4a")
	floor_mesh.material = floor_material
	var floor_instance := MeshInstance3D.new()
	floor_instance.mesh = floor_mesh
	floor_instance.position.y = -0.08
	viewport.add_child(floor_instance)
	for item in ITEMS:
		var packed := load(item[0]) as PackedScene
		var instance := packed.instantiate() as Node3D
		instance.position = item[1]
		instance.rotation_degrees = item[2]
		instance.scale = Vector3.ONE * item[3]
		viewport.add_child(instance)
	var cold_light := DirectionalLight3D.new()
	cold_light.rotation_degrees = Vector3(-45, -25, 0)
	cold_light.light_color = Color("9aabd4")
	cold_light.light_energy = 1.1
	viewport.add_child(cold_light)
	var warm_light := OmniLight3D.new()
	warm_light.position = Vector3(1.8, 2.2, -1.2)
	warm_light.omni_range = 6.0
	warm_light.light_color = Color("ffb35c")
	warm_light.light_energy = 2.0
	viewport.add_child(warm_light)
	var camera := Camera3D.new()
	viewport.add_child(camera)
	camera.current = true
	camera.look_at_from_position(Vector3(0, 2.15, -7.2), Vector3(0, 0.90, 0), Vector3.UP)
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var error := viewport.get_texture().get_image().save_png("user://accept_color_harmony.png")
	print("saved user://accept_color_harmony.png err=", error)
	quit(error)
