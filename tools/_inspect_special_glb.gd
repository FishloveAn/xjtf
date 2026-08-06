extends SceneTree
## tools/_inspect_special_glb.gd — M3-ART-P1 验证脚本（headless）
## 用法：godot --headless --path . --script tools/_inspect_special_glb.gd
## 验证：导入 glb → 实例化 → 列节点树 → 列动画槽名 → COUNT tris
## 期望：AnimationPlayer 存在 + 6 槽名 idle/walk/attack/hurt/death/spawn
##       骨架节点 + MeshInstance3D + 单纹理（baseColor 染色生效）

const REQUIRED_ANIMS := ["idle", "walk", "attack", "hurt", "death", "spawn"]
const MODELS := [
    "res://assets/models/characters/char_zombie_charger_01.glb",
    "res://assets/models/characters/char_zombie_spitter_01.glb",
]

var _fail := 0


func _check(cond: bool, label: String) -> void:
    if cond:
        print("  [PASS] ", label)
    else:
        _fail += 1
        print("  [FAIL] ", label)


func _inspect(scene_path: String) -> void:
    print("\n=== ", scene_path, " ===")
    var scene: PackedScene = load(scene_path)
    if scene == null:
        print("  [FAIL] load failed")
        _fail += 1
        return
    var root: Node = scene.instantiate()
    _walk(root, 0)
    # 动画
    var anim: AnimationPlayer = root.find_child("AnimationPlayer", true, false)
    if anim == null:
        # 退路：递归找 AnimationPlayer
        anim = _find_anim(root)
    _check(anim != null, "AnimationPlayer 存在")
    if anim != null:
        var names: PackedStringArray = anim.get_animation_list()
        print("  动画列表 (", names.size(), "): ", names)
        for slot in REQUIRED_ANIMS:
            _check(anim.has_animation(slot), "动画槽存在 '" + slot + "'")
        _check(names.size() == REQUIRED_ANIMS.size(),
            "动画数量 = " + str(REQUIRED_ANIMS.size()) + " (实际 " + str(names.size()) + ")")
    # 骨架
    var skel: Skeleton3D = root.find_child("Skeleton3D", true, false)
    _check(skel != null, "Skeleton3D 存在")
    if skel != null:
        print("  骨骼节点数（joints）=", skel.get_bone_count())
    # 纹理
    var mi_meshes: Array = []
    _collect_mesh_instances(root, mi_meshes)
    _check(mi_meshes.size() > 0, "MeshInstance3D 存在（找到 " + str(mi_meshes.size()) + " 个）")
    var total_tris := 0
    for mi in mi_meshes:
        var mesh: Mesh = mi.mesh
        if mesh == null:
            continue
        for s in mesh.get_surface_count():
            var arrays: Array = mesh.surface_get_arrays(s)
            if arrays != null and arrays[Mesh.ARRAY_INDEX] != null:
                total_tris += (arrays[Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 3
    if mi_meshes.size() > 0:
        print("  MeshInstance3D 数量=", mi_meshes.size(), " total_tris=", total_tris)
        _check(total_tris > 0 and total_tris <= 4000, "tris 在 (0, 4000] 区间（实际 " + str(total_tris) + "）")
    # baseColor 染色验证
    for mi in mi_meshes:
        if mi.mesh == null:
            continue
        for s in mi.mesh.get_surface_count():
            var mat: Material = mi.mesh.surface_get_material(s)
            if mat is StandardMaterial3D:
                var sm: StandardMaterial3D = mat
                var albedo: Color = sm.albedo_color
                print("  StandardMaterial3D albedo=", albedo, " has_texture=", sm.albedo_texture != null)
                _check(sm.albedo_texture != null, "  albedo_texture 已设置（纹理染色生效）")
                break
        break
    # 高度 AABB（可视化参考）
    var aabb: AABB = _compute_aabb(root)
    if aabb.size != Vector3.ZERO:
        print("  AABB size=", aabb.size, " ext.y=", aabb.size.y, " (用户可视高度≈size.y)")
    root.queue_free()


func _walk(n: Node, depth: int) -> void:
    var prefix: String = "  " + "  ".repeat(depth) + "├─ "
    var info: String = n.name + " (" + n.get_class() + ")"
    if n is MeshInstance3D:
        info += " mesh_surface=" + str((n as MeshInstance3D).mesh.get_surface_count() if (n as MeshInstance3D).mesh != null else 0)
    if n is Skeleton3D:
        info += " bones=" + str((n as Skeleton3D).get_bone_count())
    if n is AnimationPlayer:
        var names: PackedStringArray = (n as AnimationPlayer).get_animation_list()
        info += " anims=" + str(names).replace("\"", "'")
    print(prefix, info)
    for c in n.get_children():
        _walk(c, depth + 1)


func _collect_mesh_instances(n: Node, out: Array) -> void:
    if n is MeshInstance3D:
        out.append(n)
    for c in n.get_children():
        _collect_mesh_instances(c, out)


func _find_anim(n: Node) -> AnimationPlayer:
    if n is AnimationPlayer:
        return n
    for c in n.get_children():
        var found: AnimationPlayer = _find_anim(c)
        if found != null:
            return found
    return null


func _compute_aabb(n: Node) -> AABB:
    # 收集所有 MeshInstance3D 的 AABB
    var result: AABB = AABB()
    var has_any := false
    for c in n.find_children("*", "MeshInstance3D", true, false):
        var mi: MeshInstance3D = c as MeshInstance3D
        if mi.mesh != null:
            var a := mi.get_aabb()
            if not has_any:
                result = a
                has_any = true
            else:
                result = result.merge(a)
    return result


func _initialize() -> void:
    for m in MODELS:
        _inspect(m)
    print("\n=== INSPECT ", "PASS" if _fail == 0 else "FAIL", " (fail=", _fail, ") ===")
    quit(_fail)
