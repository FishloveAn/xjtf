import argparse
import sys
from pathlib import Path

import bpy


def arguments() -> argparse.Namespace:
    argv = sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else []
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-blend", required=True)
    parser.add_argument("--output-glb", required=True)
    return parser.parse_args(argv)


def find_character_mesh() -> bpy.types.Object:
    meshes = [obj for obj in bpy.context.scene.objects if obj.type == "MESH"]
    if len(meshes) != 1:
        raise RuntimeError(f"预期一个角色网格，实际找到 {len(meshes)} 个")
    return meshes[0]


def build_armature() -> bpy.types.Object:
    data = bpy.data.armatures.new("GoblinChargerRig")
    armature = bpy.data.objects.new("CharacterRig", data)
    bpy.context.collection.objects.link(armature)
    bpy.context.view_layer.objects.active = armature
    armature.select_set(True)
    bpy.ops.object.mode_set(mode="EDIT")
    definitions = {
        "root": ((0.0, 0.0, 0.0), (0.0, 0.0, 0.22), None),
        "pelvis": ((0.0, 0.0, 0.62), (0.0, 0.0, 0.92), "root"),
        "spine": ((0.0, 0.0, 0.92), (0.0, 0.0, 1.48), "pelvis"),
        "head": ((0.0, 0.18, 1.43), (0.0, 0.70, 1.67), "spine"),
        "upper_arm_l": ((0.40, 0.0, 1.48), (0.76, 0.08, 1.16), "spine"),
        "lower_arm_l": ((0.76, 0.08, 1.16), (0.97, 0.25, 0.68), "upper_arm_l"),
        "upper_arm_r": ((-0.40, 0.0, 1.48), (-0.76, 0.08, 1.16), "spine"),
        "lower_arm_r": ((-0.76, 0.08, 1.16), (-0.97, 0.25, 0.68), "upper_arm_r"),
        "thigh_l": ((0.19, 0.0, 0.76), (0.31, 0.02, 0.46), "pelvis"),
        "shin_l": ((0.31, 0.02, 0.46), (0.33, 0.14, 0.10), "thigh_l"),
        "thigh_r": ((-0.19, 0.0, 0.76), (-0.31, 0.02, 0.46), "pelvis"),
        "shin_r": ((-0.31, 0.02, 0.46), (-0.33, 0.14, 0.10), "thigh_r"),
    }
    bones = {}
    for name, (head, tail, parent) in definitions.items():
        bone = data.edit_bones.new(name)
        bone.head = head
        bone.tail = tail
        bone.use_deform = name != "root"
        if parent is not None:
            bone.parent = bones[parent]
        bones[name] = bone
    bpy.ops.object.mode_set(mode="POSE")
    for pose_bone in armature.pose.bones:
        pose_bone.rotation_mode = "XYZ"
    bpy.ops.object.mode_set(mode="OBJECT")
    armature.show_in_front = True
    return armature


def primary_bone(x: float, y: float, z: float) -> str:
    # 面部、尖耳、牙齿等全部随头骨移动。
    if abs(x) < 0.55 and y > 0.62 and z > 1.16:
        return "head"

    # 巨臂采用上下两段刚性权重，保留夸张低模体块。
    if abs(x) > 0.55 and z > 0.42:
        suffix = "l" if x > 0.0 else "r"
        return f"upper_arm_{suffix}" if z > 1.14 else f"lower_arm_{suffix}"

    # 双腿按高度分成大腿和小腿/脚。
    if z < 0.92 and abs(x) < 0.74:
        suffix = "l" if x > 0.0 else "r"
        return f"thigh_{suffix}" if z > 0.48 else f"shin_{suffix}"

    if z < 0.94:
        return "pelvis"
    return "spine"


def bind_mesh(mesh: bpy.types.Object, armature: bpy.types.Object) -> None:
    for group in list(mesh.vertex_groups):
        mesh.vertex_groups.remove(group)
    groups = {
        bone.name: mesh.vertex_groups.new(name=bone.name)
        for bone in armature.data.bones
        if bone.use_deform
    }
    counts = {name: 0 for name in groups}
    for vertex in mesh.data.vertices:
        name = primary_bone(vertex.co.x, vertex.co.y, vertex.co.z)
        groups[name].add([vertex.index], 1.0, "REPLACE")
        counts[name] += 1

    mesh.parent = armature
    modifier = mesh.modifiers.new(name="GoblinArmature", type="ARMATURE")
    modifier.object = armature
    print("WEIGHT_COUNTS", counts)


def reset_pose(armature: bpy.types.Object) -> None:
    for bone in armature.pose.bones:
        bone.rotation_euler = (0.0, 0.0, 0.0)
        bone.location = (0.0, 0.0, 0.0)
        bone.scale = (1.0, 1.0, 1.0)


def make_action(
    armature: bpy.types.Object,
    name: str,
    poses: list[tuple[int, dict[str, tuple[float, float, float]]]],
) -> bpy.types.Action:
    action = bpy.data.actions.new(name)
    action.use_fake_user = True
    armature.animation_data_create()
    armature.animation_data.action = action
    for frame, rotations in poses:
        reset_pose(armature)
        for bone_name, rotation in rotations.items():
            armature.pose.bones[bone_name].rotation_euler = rotation
        for bone in armature.pose.bones:
            bone.keyframe_insert("rotation_euler", frame=frame, group=bone.name)
            bone.keyframe_insert("location", frame=frame, group=bone.name)
            bone.keyframe_insert("scale", frame=frame, group=bone.name)
    armature.animation_data.action = None
    return action


def build_animations(armature: bpy.types.Object) -> None:
    clips = {
        "idle": [
            (1, {"spine": (0.025, 0.0, 0.0), "head": (-0.02, 0.0, 0.0)}),
            (12, {"spine": (-0.025, 0.0, 0.0), "head": (0.025, 0.0, 0.0)}),
            (24, {"spine": (0.025, 0.0, 0.0), "head": (-0.02, 0.0, 0.0)}),
        ],
        "walk": [
            (1, {"thigh_l": (0.34, 0.0, 0.0), "thigh_r": (-0.34, 0.0, 0.0), "upper_arm_l": (-0.18, 0.0, 0.0), "upper_arm_r": (0.18, 0.0, 0.0)}),
            (12, {"thigh_l": (-0.34, 0.0, 0.0), "thigh_r": (0.34, 0.0, 0.0), "upper_arm_l": (0.18, 0.0, 0.0), "upper_arm_r": (-0.18, 0.0, 0.0)}),
            (24, {"thigh_l": (0.34, 0.0, 0.0), "thigh_r": (-0.34, 0.0, 0.0), "upper_arm_l": (-0.18, 0.0, 0.0), "upper_arm_r": (0.18, 0.0, 0.0)}),
        ],
        "attack": [
            (1, {"spine": (-0.18, 0.0, 0.0), "head": (0.10, 0.0, 0.0)}),
            (8, {"spine": (0.42, 0.0, 0.0), "upper_arm_l": (-0.52, 0.0, 0.0), "upper_arm_r": (-0.52, 0.0, 0.0)}),
            (18, {"spine": (-0.18, 0.0, 0.0), "head": (0.10, 0.0, 0.0)}),
        ],
        "hurt": [
            (1, {}),
            (6, {"spine": (-0.28, 0.12, 0.16), "head": (0.22, 0.0, 0.0)}),
            (14, {}),
        ],
        "death": [
            (1, {}),
            (15, {"root": (0.62, 0.0, 0.18), "spine": (0.42, 0.0, 0.0)}),
            (30, {"root": (1.38, 0.0, 0.24), "spine": (0.70, 0.0, 0.0)}),
        ],
        "spawn": [
            (1, {"spine": (0.62, 0.0, 0.0), "head": (-0.42, 0.0, 0.0)}),
            (10, {"spine": (-0.10, 0.0, 0.0), "head": (0.12, 0.0, 0.0)}),
            (18, {}),
        ],
    }
    for name, poses in clips.items():
        make_action(armature, name, poses)
    reset_pose(armature)


def main() -> None:
    args = arguments()
    output_blend = Path(args.output_blend).resolve()
    output_glb = Path(args.output_glb).resolve()
    output_blend.parent.mkdir(parents=True, exist_ok=True)
    output_glb.parent.mkdir(parents=True, exist_ok=True)

    mesh = find_character_mesh()
    for material in mesh.data.materials:
        if material is not None and not material.name.endswith("-vcol"):
            material.name = material.name + "-vcol"
    armature = build_armature()
    bind_mesh(mesh, armature)
    build_animations(armature)

    bpy.context.scene.frame_start = 1
    bpy.context.scene.frame_end = 30
    bpy.context.scene.render.fps = 24
    bpy.ops.wm.save_as_mainfile(filepath=str(output_blend))
    bpy.ops.export_scene.gltf(
        filepath=str(output_glb),
        export_format="GLB",
        export_yup=True,
        export_apply=True,
        export_materials="EXPORT",
        export_vertex_color="MATERIAL",
        export_animations=True,
        export_animation_mode="ACTIONS",
        export_skins=True,
        export_morph=False,
        export_cameras=False,
        export_lights=False,
        export_extras=True,
    )
    print(
        "RIG_OK",
        "bones=",
        len(armature.data.bones),
        "actions=",
        sorted(action.name for action in bpy.data.actions),
        output_blend,
        output_glb,
    )


if __name__ == "__main__":
    main()
