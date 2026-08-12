extends SceneTree

## 视觉验收渲染（2026-08-10 美术收口）
## 在真实 rustyard 关卡 + 主场景光照（ProceduralSky + 平行光 -45/-30）下摆拍角色模型，
## 输出 PNG 供剪影辨认 / 亮度对比 / 配色协调验收。
## 用法：godot --path . --script tools/_render_acceptance.gd   （窗口模式，非 headless）

const LEVEL := "res://scenes/environment/rustyard/rustyard.tscn"
const CHAR_DIR := "res://assets/models/characters/"

# [tag, glb 文件名, 队列横向位置]
const LINEUP := [
	["goblin_lean", "char_goblin_common_lean.glb", -6.4],
	["goblin_strong", "char_goblin_common_strong.glb", -4.8],
	["goblin_charger", "char_goblin_charger.glb", -3.2],
	["goblin_spitter", "char_goblin_spitter.glb", -1.6],
	["goblin_hunter", "char_goblin_hunter.glb", 0.0],
	["goblin_boomer", "char_goblin_boomer.glb", 1.6],
	["zombie_lean", "char_zombie_common_01.glb", 3.2],
	["zombie_strong", "char_zombie_common_02.glb", 4.8],
	["zombie_spitter_old", "char_zombie_spitter_01.glb", 6.4],
	["player", "char_player_01.glb", 8.0],
]

const CAM_X := 18.0      # 广场西侧（开阔区，镜头向 +X 看广场）
const SHOT_DISTS := [10.0, 20.0]


func _initialize() -> void:
	var root_node := Node3D.new()
	get_root().add_child(root_node)
	var vp := SubViewport.new()
	vp.size = Vector2i(960, 540)
	vp.transparent_bg = false
	vp.own_world_3d = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root_node.add_child(vp)

	# 主场景同款天空与平行光
	var sky := Sky.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky.sky_material = sky_mat
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	var we := WorldEnvironment.new()
	we.environment = env
	vp.add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-45, -30, 0)
	sun.shadow_enabled = true
	vp.add_child(sun)

	# 关卡
	var level: PackedScene = load(LEVEL)
	var level_inst: Node3D = level.instantiate()
	vp.add_child(level_inst)

	# 角色列队（面朝 -X，即朝向出生点相机）
	var placed: Array[Node3D] = []
	for entry in LINEUP:
		var path: String = CHAR_DIR + entry[1]
		if not ResourceLoader.exists(path):
			print("skip (不存在): ", entry[1])
			continue
		var ps: PackedScene = load(path)
		for d in SHOT_DISTS:
			var inst: Node3D = ps.instantiate()
			inst.position = Vector3(CAM_X + d, 0, entry[2])
			# 模型约定面朝 -Z；绕 Y 轴 +90° 后朝向位于 -X 的相机。
			inst.rotation_degrees = Vector3(0, 90, 0)
			vp.add_child(inst)
			placed.append(inst)

	var cam := Camera3D.new()
	vp.add_child(cam)
	cam.current = true

	for d in SHOT_DISTS:
		# 只留该距离的模型（其余隐藏，防遮挡）
		for inst in placed:
			inst.visible = is_equal_approx(inst.position.x, CAM_X + d)
		cam.look_at_from_position(Vector3(CAM_X, 1.6, 0), Vector3(CAM_X + d, 1.1, 0), Vector3.UP)
		await RenderingServer.frame_post_draw
		await RenderingServer.frame_post_draw
		var img := vp.get_texture().get_image()
		var tag := "near" if d < 15.0 else "far"
		var err := img.save_png("user://accept_" + tag + ".png")
		print("saved user://accept_" + tag + ".png err=", err)
	print("done")
	quit(0)
