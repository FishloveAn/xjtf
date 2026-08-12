import argparse
import math
import sys
from pathlib import Path

import bpy
from mathutils import Vector


def arguments() -> argparse.Namespace:
    argv = sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else []
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-blend", required=True)
    parser.add_argument("--output-glb", required=True)
    return parser.parse_args(argv)


def clamp(value: float, low: float = 0.0, high: float = 1.0) -> float:
    return max(low, min(high, value))


def mesh_objects() -> list[bpy.types.Object]:
    return [obj for obj in bpy.context.scene.objects if obj.type == "MESH"]


def normalize_and_deform(obj: bpy.types.Object) -> None:
    points = [obj.matrix_world @ vertex.co for vertex in obj.data.vertices]
    low = Vector((min(p.x for p in points), min(p.y for p in points), min(p.z for p in points)))
    high = Vector((max(p.x for p in points), max(p.y for p in points), max(p.z for p in points)))
    center_x = (low.x + high.x) * 0.5
    scale = 2.1 / (high.z - low.z)

    for vertex in obj.data.vertices:
        world = obj.matrix_world @ vertex.co
        x = (world.x - center_x) * scale
        y = world.y * scale
        z = (world.z - low.z) * scale

        # 上半身外扩、腰部内收，强化冲锋怪的倒三角轮廓。
        if z > 1.38:
            x *= 1.0 + 0.07 * clamp((z - 1.38) / 0.72)
        elif 0.72 < z < 1.25 and abs(x) < 0.72:
            x *= 0.91

        # 巨拳再向外、向前推，避免与前臂融成圆柱。
        if abs(x) > 0.72 and z < 1.12:
            sign = 1.0 if x >= 0.0 else -1.0
            x = sign * (0.72 + (abs(x) - 0.72) * 1.08)
            y += 0.055 * clamp((1.12 - z) / 0.65)

        # 面部区域前推并压低，让额头、口鼻形成更凶的前倾角。
        if abs(x) < 0.34 and y > 0.35 and 1.25 < z < 1.86:
            y = 0.35 + (y - 0.35) * 0.60
            x *= 1.08
            if z > 1.63:
                z -= 0.035 * clamp((z - 1.63) / 0.23)

        # 双脚压平并略微外扩，保证脚底接触地面。
        if z < 0.23 and abs(x) < 0.72:
            z = max(0.0, z * 0.68)
            x *= 1.08

        vertex.co = obj.matrix_world.inverted() @ Vector((x, y, z))

    obj.data.update()
    bpy.context.view_layer.objects.active = obj
    obj.select_set(True)
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)


def decimate(obj: bpy.types.Object, target_faces: int = 3350) -> None:
    ratio = min(1.0, target_faces / max(1, len(obj.data.polygons)))
    modifier = obj.modifiers.new(name="GameMeshDecimate", type="DECIMATE")
    modifier.decimate_type = "COLLAPSE"
    modifier.ratio = ratio
    modifier.use_collapse_triangulate = True
    bpy.context.view_layer.objects.active = obj
    bpy.ops.object.modifier_apply(modifier=modifier.name)
    for polygon in obj.data.polygons:
        polygon.use_smooth = False


def vertex_color_material() -> bpy.types.Material:
    material = bpy.data.materials.get("MAT_GoblinVertexColor-vcol") or bpy.data.materials.new(
        "MAT_GoblinVertexColor-vcol"
    )
    material.use_nodes = True
    nodes = material.node_tree.nodes
    links = material.node_tree.links
    nodes.clear()
    output = nodes.new("ShaderNodeOutputMaterial")
    shader = nodes.new("ShaderNodeBsdfPrincipled")
    color = nodes.new("ShaderNodeVertexColor")
    color.layer_name = "Color"
    shader.inputs["Roughness"].default_value = 0.82
    shader.inputs["Metallic"].default_value = 0.0
    specular = shader.inputs.get("Specular IOR Level")
    if specular is not None:
        specular.default_value = 0.0
    links.new(color.outputs["Color"], shader.inputs["Base Color"])
    links.new(color.outputs["Alpha"], shader.inputs["Alpha"])
    links.new(shader.outputs["BSDF"], output.inputs["Surface"])
    return material


def assign_face_colors(
    obj: bpy.types.Object,
    material: bpy.types.Material,
    base: tuple[float, float, float, float],
    faceted: bool = False,
) -> None:
    obj.data.materials.clear()
    obj.data.materials.append(material)
    colors = obj.data.color_attributes.get("Color")
    if colors is None:
        colors = obj.data.color_attributes.new(
            name="Color", type="BYTE_COLOR", domain="CORNER"
        )
    for polygon in obj.data.polygons:
        if faceted:
            light = 0.52 + 0.18 * max(0.0, polygon.normal.y) + 0.08 * max(
                0.0, polygon.normal.z
            )
            light += ((polygon.index * 37) % 11 - 5) * 0.012
        else:
            light = 1.0
        rgba = (
            clamp(base[0] * light),
            clamp(base[1] * light),
            clamp(base[2] * light),
            base[3],
        )
        for loop_index in polygon.loop_indices:
            colors.data[loop_index].color = rgba


def add_ico(
    name: str,
    location: tuple[float, float, float],
    scale: tuple[float, float, float],
    color: tuple[float, float, float, float],
    material: bpy.types.Material,
    subdivisions: int = 1,
) -> bpy.types.Object:
    bpy.ops.mesh.primitive_ico_sphere_add(subdivisions=subdivisions, radius=1.0, location=location)
    obj = bpy.context.object
    obj.name = name
    obj.scale = scale
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    assign_face_colors(obj, material, color, faceted=False)
    return obj


def add_box(
    name: str,
    location: tuple[float, float, float],
    scale: tuple[float, float, float],
    rotation: tuple[float, float, float],
    color: tuple[float, float, float, float],
    material: bpy.types.Material,
) -> bpy.types.Object:
    bpy.ops.mesh.primitive_cube_add(size=1.0, location=location, rotation=rotation)
    obj = bpy.context.object
    obj.name = name
    obj.scale = scale
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    assign_face_colors(obj, material, color, faceted=False)
    return obj


def add_cone(
    name: str,
    location: tuple[float, float, float],
    radius: float,
    depth: float,
    upside_down: bool,
    color: tuple[float, float, float, float],
    material: bpy.types.Material,
) -> bpy.types.Object:
    rotation = (math.pi, 0.0, 0.0) if upside_down else (0.0, 0.0, 0.0)
    bpy.ops.mesh.primitive_cone_add(
        vertices=6,
        radius1=radius,
        radius2=radius * 0.12,
        depth=depth,
        location=location,
        rotation=rotation,
    )
    obj = bpy.context.object
    obj.name = name
    assign_face_colors(obj, material, color, faceted=False)
    return obj


def add_ear(
    name: str,
    sign: float,
    material: bpy.types.Material,
    color: tuple[float, float, float, float],
) -> bpy.types.Object:
    inner_low = sign * 0.13
    inner_high = sign * 0.18
    tip = sign * 0.48
    vertices = [
        (inner_low, 0.91, 1.48),
        (inner_high, 0.89, 1.69),
        (tip, 0.80, 1.75),
        (inner_low, 0.80, 1.48),
        (inner_high, 0.78, 1.69),
        (tip, 0.70, 1.75),
    ]
    faces = [(0, 1, 2), (5, 4, 3), (0, 3, 4, 1), (1, 4, 5, 2), (2, 5, 3, 0)]
    mesh = bpy.data.meshes.new(f"{name}_Mesh")
    mesh.from_pydata(vertices, [], faces)
    mesh.update()
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.collection.objects.link(obj)
    assign_face_colors(obj, material, color, faceted=True)
    return obj


def add_face_and_limb_details(material: bpy.types.Material) -> None:
    dark = (0.018, 0.001, 0.0002, 1.0)
    deep_orange = (0.34, 0.008, 0.0005, 1.0)
    orange = (0.78, 0.028, 0.001, 1.0)
    ivory = (0.72, 0.34, 0.09, 1.0)
    eye = (0.82, 0.48, 0.015, 1.0)

    add_ear("Ear_L", -1.0, material, orange)
    add_ear("Ear_R", 1.0, material, orange)
    add_ico("FaceMass", (0.0, 0.89, 1.52), (0.275, 0.105, 0.28), orange, material)
    add_ico("MouthCavity", (0.0, 0.99, 1.37), (0.23, 0.035, 0.12), dark, material)
    add_ico("Nose", (0.0, 1.015, 1.54), (0.095, 0.025, 0.064), deep_orange, material)
    add_box(
        "Chin",
        (0.0, 0.94, 1.22),
        (0.20, 0.055, 0.055),
        (0.0, 0.0, 0.0),
        deep_orange,
        material,
    )

    for sign in (-1.0, 1.0):
        add_box(
            f"Brow_{sign:+.0f}",
            (sign * 0.10, 1.005, 1.64),
            (0.105, 0.026, 0.030),
            (0.0, sign * 0.08, sign * -0.24),
            deep_orange,
            material,
        )
        add_ico(
            f"Eye_{sign:+.0f}",
            (sign * 0.10, 1.025, 1.60),
            (0.043, 0.012, 0.022),
            eye,
            material,
        )
        add_cone(
            f"LowerTusk_{sign:+.0f}",
            (sign * 0.165, 1.015, 1.37),
            0.038,
            0.20,
            False,
            ivory,
            material,
        )


def join_meshes() -> bpy.types.Object:
    bpy.ops.object.select_all(action="DESELECT")
    objects = mesh_objects()
    for obj in objects:
        obj.select_set(True)
    bpy.context.view_layer.objects.active = objects[0]
    bpy.ops.object.join()
    result = bpy.context.object
    result.name = "char_goblin_charger_sculpt"
    for polygon in result.data.polygons:
        polygon.use_smooth = False
    return result


def main() -> None:
    args = arguments()
    output_blend = Path(args.output_blend).resolve()
    output_glb = Path(args.output_glb).resolve()
    output_blend.parent.mkdir(parents=True, exist_ok=True)
    output_glb.parent.mkdir(parents=True, exist_ok=True)

    meshes = mesh_objects()
    if len(meshes) != 1:
        raise RuntimeError(f"预期一个基础网格，实际找到 {len(meshes)} 个")
    body = meshes[0]
    body.name = "Body_SF3D"
    normalize_and_deform(body)
    decimate(body)

    material = vertex_color_material()
    assign_face_colors(body, material, (0.88, 0.032, 0.0012, 1.0), faceted=True)
    add_face_and_limb_details(material)
    result = join_meshes()

    # 统一脚底、原点和朝向：Blender +Y 对应 Godot -Z。
    min_z = min((result.matrix_world @ vertex.co).z for vertex in result.data.vertices)
    result.location.z -= min_z
    bpy.context.view_layer.objects.active = result
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)

    bpy.ops.wm.save_as_mainfile(filepath=str(output_blend))
    bpy.ops.export_scene.gltf(
        filepath=str(output_glb),
        export_format="GLB",
        export_yup=True,
        export_apply=True,
        export_materials="EXPORT",
        export_vertex_color="MATERIAL",
    )
    print(
        "SCULPT_OK",
        result.name,
        "verts=",
        len(result.data.vertices),
        "faces=",
        len(result.data.polygons),
        output_blend,
        output_glb,
    )


if __name__ == "__main__":
    main()
