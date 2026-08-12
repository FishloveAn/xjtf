"""在 Blender 中制作可编辑的风格化低模角色候选资产。"""

import argparse
import json
import math
import struct
import sys
from pathlib import Path

import bpy
from mathutils import Vector


ROOT = Path(__file__).resolve().parents[2]
SOURCE_ROOT = ROOT / "art_source" / "characters"
CONCEPT_ROOT = ROOT / "项目文档" / "02-设计" / "怪概念设计"


SPECS = {
    "char_goblin_charger": {
        "role": "冲撞型特殊敌人",
        "concepts": ["goblin_charger.png", "zombie_charger.png"],
        "height": 2.10,
        "base": (0.76, 0.045, 0.006, 1.0),
        "accent": (0.82, 0.58, 0.30, 1.0),
        "required": ["超宽肩", "双侧巨拳", "尖耳", "獠牙", "低重心前倾姿态"],
        "shoulder_ratio": 0.75,
        "head_ratio": 0.13,
        "tris_max": 4000,
    },
}


def cli() -> argparse.Namespace:
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    parser = argparse.ArgumentParser()
    parser.add_argument("--asset", choices=sorted(SPECS), required=True)
    return parser.parse_args(argv)


def reset_scene() -> None:
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete(use_global=False)
    for block in (bpy.data.meshes, bpy.data.curves, bpy.data.armatures, bpy.data.materials, bpy.data.actions):
        for item in list(block):
            block.remove(item)


def material(name: str, rgba, emissive=False):
    value = bpy.data.materials.new(name)
    value.diffuse_color = rgba
    value.use_nodes = True
    bsdf = value.node_tree.nodes.get("Principled BSDF")
    bsdf.inputs["Base Color"].default_value = rgba
    bsdf.inputs["Roughness"].default_value = 0.82
    if emissive:
        bsdf.inputs["Emission Color"].default_value = rgba
        bsdf.inputs["Emission Strength"].default_value = 2.0
    return value


def finish_mesh(obj, mat, bone_name: str, armature):
    obj.data.materials.append(mat)
    for polygon in obj.data.polygons:
        polygon.use_smooth = False
    bpy.context.view_layer.objects.active = obj
    obj.select_set(True)
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    group = obj.vertex_groups.new(name=bone_name)
    group.add(list(range(len(obj.data.vertices))), 1.0, "REPLACE")
    modifier = obj.modifiers.new("Armature", "ARMATURE")
    modifier.object = armature
    obj.parent = armature
    return obj


def ico(name, location, scale, mat, bone, armature, subdivisions=1):
    bpy.ops.mesh.primitive_ico_sphere_add(subdivisions=subdivisions, radius=1.0, location=location)
    obj = bpy.context.object
    obj.name = name
    obj.scale = scale
    return finish_mesh(obj, mat, bone, armature)


def cube(name, location, scale, mat, bone, armature, rotation=(0.0, 0.0, 0.0), bevel=0.0):
    bpy.ops.mesh.primitive_cube_add(location=location, rotation=rotation)
    obj = bpy.context.object
    obj.name = name
    obj.scale = scale
    if bevel > 0.0:
        modifier = obj.modifiers.new("LowPolyBevel", "BEVEL")
        modifier.width = bevel
        modifier.segments = 1
    return finish_mesh(obj, mat, bone, armature)


def cone_between(name, start, end, radius_start, radius_end, mat, bone, armature, vertices=7):
    start, end = Vector(start), Vector(end)
    direction = end - start
    bpy.ops.mesh.primitive_cone_add(
        vertices=vertices,
        radius1=radius_start,
        radius2=radius_end,
        depth=direction.length,
        location=(start + end) * 0.5,
    )
    obj = bpy.context.object
    obj.name = name
    obj.rotation_mode = "QUATERNION"
    obj.rotation_quaternion = Vector((0.0, 0.0, 1.0)).rotation_difference(direction.normalized())
    obj.rotation_mode = "XYZ"
    return finish_mesh(obj, mat, bone, armature)


def wedge(name, vertices, faces, mat, bone, armature):
    mesh = bpy.data.meshes.new(name + "Mesh")
    mesh.from_pydata(vertices, [], faces)
    mesh.update()
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.collection.objects.link(obj)
    return finish_mesh(obj, mat, bone, armature)


def build_armature():
    data = bpy.data.armatures.new("CharacterRig")
    armature = bpy.data.objects.new("CharacterRig", data)
    bpy.context.collection.objects.link(armature)
    bpy.context.view_layer.objects.active = armature
    armature.select_set(True)
    bpy.ops.object.mode_set(mode="EDIT")
    definitions = {
        "root": ((0, 0, 0), (0, 0, 0.20), None),
        "pelvis": ((0, 0, 0.68), (0, 0, 0.96), "root"),
        "spine": ((0, 0, 0.96), (0, 0, 1.46), "pelvis"),
        "head": ((0, 0, 1.46), (0, 0, 1.82), "spine"),
        "upper_arm_l": ((0.42, 0, 1.40), (0.72, 0.03, 1.13), "spine"),
        "lower_arm_l": ((0.72, 0.03, 1.13), (0.79, 0.08, 0.73), "upper_arm_l"),
        "upper_arm_r": ((-0.42, 0, 1.40), (-0.72, 0.03, 1.13), "spine"),
        "lower_arm_r": ((-0.72, 0.03, 1.13), (-0.79, 0.08, 0.73), "upper_arm_r"),
        "thigh_l": ((0.20, 0, 0.78), (0.24, 0, 0.43), "pelvis"),
        "shin_l": ((0.24, 0, 0.43), (0.24, 0.05, 0.10), "thigh_l"),
        "thigh_r": ((-0.20, 0, 0.78), (-0.24, 0, 0.43), "pelvis"),
        "shin_r": ((-0.24, 0, 0.43), (-0.24, 0.05, 0.10), "thigh_r"),
    }
    bones = {}
    for name, (head, tail, parent) in definitions.items():
        bone = data.edit_bones.new(name)
        bone.head, bone.tail = head, tail
        if parent:
            bone.parent = bones[parent]
        bones[name] = bone
    bpy.ops.object.mode_set(mode="POSE")
    for pose_bone in armature.pose.bones:
        pose_bone.rotation_mode = "XYZ"
    bpy.ops.object.mode_set(mode="OBJECT")
    return armature


def build_face(armature, base, accent):
    ico("Head", (0, 0.07, 1.58), (0.21, 0.18, 0.20), base, "head", armature, 2)
    ico("Snout", (0, 0.23, 1.55), (0.13, 0.13, 0.075), base, "head", armature, 1)
    ico("Chin", (0, 0.21, 1.40), (0.17, 0.11, 0.065), base, "head", armature, 1)
    ico("Nose", (0, 0.31, 1.59), (0.085, 0.12, 0.075), base, "head", armature, 1)
    for side in (-1, 1):
        x = side * 0.19
        ear_vertices = [
            (x, 0.02, 1.63), (side * 0.50, 0.02, 1.77), (side * 0.24, 0.08, 1.47),
            (x, 0.12, 1.63), (side * 0.50, 0.08, 1.77), (side * 0.24, 0.16, 1.47),
        ]
        wedge(f"Ear_{side}", ear_vertices, [(0, 1, 2), (3, 5, 4), (0, 3, 4), (0, 4, 1), (2, 1, 4), (2, 4, 5), (0, 2, 5), (0, 5, 3)], base, "head", armature)
        ico(f"Eye_{side}", (side * 0.082, 0.235, 1.63), (0.04, 0.03, 0.028), accent, "head", armature, 1)
        cone_between(f"Tusk_{side}", (side * 0.115, 0.33, 1.43), (side * 0.15, 0.38, 1.60), 0.052, 0.01, accent, "head", armature, 6)
        cube(f"Brow_{side}", (side * 0.09, 0.24, 1.69), (0.105, 0.035, 0.028), base, "head", armature, rotation=(side * -0.18, 0, side * -0.12))


def build_charger(spec):
    armature = build_armature()
    base = material("主体", spec["base"])
    accent = material("识别强调", spec["accent"])
    ico("Pelvis", (0, -0.02, 0.82), (0.35, 0.25, 0.28), base, "pelvis", armature, 1)
    ico("LowerTorso", (0, -0.02, 1.06), (0.50, 0.28, 0.30), base, "spine", armature, 1)
    ico("Chest", (0, -0.03, 1.31), (0.76, 0.34, 0.37), base, "spine", armature, 2)
    ico("BackMass", (0, -0.20, 1.39), (0.72, 0.26, 0.30), base, "spine", armature, 1)
    cube("Belt", (0, 0.03, 0.88), (0.37, 0.27, 0.075), base, "pelvis", armature, bevel=0.04)
    build_face(armature, base, accent)

    for side, suffix in ((1, "l"), (-1, "r")):
        upper_bone, lower_bone = f"upper_arm_{suffix}", f"lower_arm_{suffix}"
        ico(f"Shoulder_{suffix}", (side * 0.64, -0.02, 1.34), (0.37, 0.34, 0.36), base, upper_bone, armature, 2)
        cone_between(f"UpperArm_{suffix}", (side * 0.62, 0.01, 1.28), (side * 0.79, 0.11, 1.01), 0.25, 0.20, base, upper_bone, armature)
        cone_between(f"Forearm_{suffix}", (side * 0.79, 0.11, 1.01), (side * 0.82, 0.22, 0.70), 0.23, 0.29, base, lower_bone, armature)
        ico(f"Fist_{suffix}", (side * 0.83, 0.28, 0.56), (0.33, 0.31, 0.29), base, lower_bone, armature, 2)
        for finger in range(3):
            cube(f"Knuckle_{suffix}_{finger}", (side * (0.69 + finger * 0.09), 0.52, 0.58), (0.055, 0.07, 0.055), base, lower_bone, armature, bevel=0.02)
        thigh_bone, shin_bone = f"thigh_{suffix}", f"shin_{suffix}"
        cone_between(f"Thigh_{suffix}", (side * 0.20, 0, 0.76), (side * 0.24, 0.01, 0.43), 0.23, 0.18, base, thigh_bone, armature)
        cone_between(f"Shin_{suffix}", (side * 0.24, 0.01, 0.43), (side * 0.24, 0.08, 0.13), 0.18, 0.14, base, shin_bone, armature)
        cube(f"Foot_{suffix}", (side * 0.24, 0.18, 0.07), (0.21, 0.34, 0.08), base, shin_bone, armature, bevel=0.04)
    return armature


def make_action(armature, name, poses):
    action = bpy.data.actions.new(name)
    armature.animation_data_create()
    armature.animation_data.action = action
    for frame, rotations in poses:
        for bone in armature.pose.bones:
            bone.rotation_euler = (0.0, 0.0, 0.0)
            bone.location = (0.0, 0.0, 0.0)
        for bone_name, rotation in rotations.items():
            armature.pose.bones[bone_name].rotation_euler = rotation
        for bone in armature.pose.bones:
            bone.keyframe_insert("rotation_euler", frame=frame, group=bone.name)
            bone.keyframe_insert("location", frame=frame, group=bone.name)
    armature.animation_data.action = None
    return action


def build_animations(armature):
    clips = {
        "idle": [(1, {"spine": (0.03, 0, 0)}), (12, {"spine": (-0.03, 0, 0)}), (24, {"spine": (0.03, 0, 0)})],
        "walk": [(1, {"thigh_l": (0.45, 0, 0), "thigh_r": (-0.45, 0, 0), "upper_arm_l": (-0.25, 0, 0), "upper_arm_r": (0.25, 0, 0)}), (12, {"thigh_l": (-0.45, 0, 0), "thigh_r": (0.45, 0, 0), "upper_arm_l": (0.25, 0, 0), "upper_arm_r": (-0.25, 0, 0)}), (24, {"thigh_l": (0.45, 0, 0), "thigh_r": (-0.45, 0, 0), "upper_arm_l": (-0.25, 0, 0), "upper_arm_r": (0.25, 0, 0)})],
        "attack": [(1, {"spine": (-0.2, 0, 0)}), (8, {"spine": (0.5, 0, 0), "upper_arm_l": (-0.65, 0, 0), "upper_arm_r": (-0.65, 0, 0)}), (18, {"spine": (-0.2, 0, 0)})],
        "hurt": [(1, {}), (6, {"spine": (-0.35, 0.15, 0.18), "head": (0.2, 0, 0)}), (14, {})],
        "death": [(1, {}), (15, {"root": (0.7, 0.0, 0.2), "spine": (0.5, 0, 0)}), (30, {"root": (1.45, 0.0, 0.25), "spine": (0.8, 0, 0)})],
        "spawn": [(1, {"spine": (0.75, 0, 0), "head": (-0.5, 0, 0)}), (18, {"spine": (0.0, 0, 0), "head": (0.0, 0, 0)})],
    }
    for name, poses in clips.items():
        make_action(armature, name, poses)


def write_manifest(asset_name, spec, directory):
    manifest = {
        "asset_name": asset_name,
        "concept_images": [str((CONCEPT_ROOT / name).relative_to(ROOT)).replace("\\", "/") for name in spec["concepts"]],
        "role": spec["role"],
        "silhouette": {
            "height_m": spec["height"],
            "shoulder_to_height": spec["shoulder_ratio"],
            "head_to_height": spec["head_ratio"],
            "stance": "前倾、低重心",
        },
        "required_features": spec["required"],
        "simplifiable_features": ["细碎皮肤裂纹", "牙齿数量", "肌肉表面小褶皱"],
        "palette": {"base": "#EB2B06", "accent": "#FF9414", "emissive": []},
        "budgets": {"triangles_max": spec["tris_max"], "materials_max": 2},
        "visual_review": {"front": "pending", "side": "pending", "back": "pending", "game_view": "pending", "notes": []},
    }
    (directory / "visual_manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")


def add_asset_metadata(path: Path, spec):
    raw = path.read_bytes()
    _, _, _ = struct.unpack_from("<4sII", raw, 0)
    json_length, json_type = struct.unpack_from("<II", raw, 12)
    document = json.loads(raw[20:20 + json_length].rstrip(b" \x00"))
    offset = 20 + json_length
    remaining = raw[offset:]
    document.setdefault("asset", {}).setdefault("extras", {})["xjtf"] = {
        "height_m": spec["height"], "forward": "-Z", "concept_refs": len(spec["concepts"]),
        "style": "stylized_low_poly_blender", "source_blend": True,
    }
    encoded = json.dumps(document, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    encoded += b" " * ((4 - len(encoded) % 4) % 4)
    total = 12 + 8 + len(encoded) + len(remaining)
    output = bytearray(struct.pack("<4sII", b"glTF", 2, total))
    output.extend(struct.pack("<II", len(encoded), json_type))
    output.extend(encoded)
    output.extend(remaining)
    path.write_bytes(output)


def export_candidate(asset_name, spec, armature):
    directory = SOURCE_ROOT / asset_name
    export_dir = directory / "export"
    preview_dir = directory / "previews"
    export_dir.mkdir(parents=True, exist_ok=True)
    preview_dir.mkdir(parents=True, exist_ok=True)
    write_manifest(asset_name, spec, directory)
    blend_path = directory / "source.blend"
    bpy.ops.wm.save_as_mainfile(filepath=str(blend_path))
    glb_path = export_dir / f"{asset_name}.glb"
    bpy.ops.export_scene.gltf(
        filepath=str(glb_path), export_format="GLB", export_yup=True,
        export_animations=True, export_animation_mode="ACTIONS",
        export_skins=True, export_morph=False, export_cameras=False,
        export_lights=False, export_extras=True,
    )
    add_asset_metadata(glb_path, spec)
    print(f"CANDIDATE_OK {asset_name} {blend_path} {glb_path}")


def main():
    args = cli()
    spec = SPECS[args.asset]
    reset_scene()
    if args.asset == "char_goblin_charger":
        armature = build_charger(spec)
    else:
        raise ValueError(args.asset)
    build_animations(armature)
    export_candidate(args.asset, spec, armature)


if __name__ == "__main__":
    main()
