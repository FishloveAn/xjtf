import argparse
import math
import sys
from pathlib import Path

import bpy
from mathutils import Vector


def arguments() -> argparse.Namespace:
    argv = sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else []
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-dir", required=True)
    return parser.parse_args(argv)


def look_at(obj: bpy.types.Object, point: Vector) -> None:
    obj.rotation_euler = (point - obj.location).to_track_quat("-Z", "Y").to_euler()


def setup_scene() -> bpy.types.Object:
    scene = bpy.context.scene
    scene.render.engine = "BLENDER_EEVEE"
    scene.render.resolution_x = 640
    scene.render.resolution_y = 640
    scene.render.resolution_percentage = 100
    scene.render.image_settings.file_format = "PNG"
    scene.render.film_transparent = False
    scene.world.color = (0.025, 0.032, 0.045)

    bpy.ops.object.camera_add(location=(3.8, 5.8, 2.65))
    camera = bpy.context.object
    camera.data.lens = 58
    look_at(camera, Vector((0.0, 0.35, 1.05)))
    scene.camera = camera

    for location, energy, size in [
        ((3.0, 4.0, 5.0), 1000.0, 3.0),
        ((-4.0, 2.0, 3.0), 700.0, 4.0),
        ((0.0, -3.0, 4.5), 900.0, 3.0),
    ]:
        bpy.ops.object.light_add(type="AREA", location=location)
        light = bpy.context.object
        light.data.energy = energy
        light.data.shape = "DISK"
        light.data.size = size
        look_at(light, Vector((0.0, 0.25, 1.0)))

    bpy.ops.mesh.primitive_plane_add(size=20, location=(0.0, 0.0, -0.015))
    plane = bpy.context.object
    material = bpy.data.materials.new("QA_Ground")
    material.diffuse_color = (0.045, 0.055, 0.070, 1.0)
    plane.data.materials.append(material)
    return camera


def render_actions(output_dir: Path) -> None:
    scene = bpy.context.scene
    armatures = [obj for obj in scene.objects if obj.type == "ARMATURE"]
    if len(armatures) != 1:
        raise RuntimeError(f"预期一个骨架，实际找到 {len(armatures)} 个")
    armature = armatures[0]
    armature.animation_data_create()
    samples = {
        "idle": 12,
        "walk": 1,
        "attack": 8,
        "hurt": 6,
        "death": 30,
        "spawn": 1,
    }
    for name, frame in samples.items():
        action = bpy.data.actions.get(name)
        if action is None:
            raise RuntimeError(f"缺少动作：{name}")
        armature.animation_data.action = action
        scene.frame_set(frame)
        bpy.context.view_layer.update()
        scene.render.filepath = str(output_dir / f"{name}.png")
        bpy.ops.render.render(write_still=True)
        print("RENDERED", name, frame, scene.render.filepath)
    armature.animation_data.action = None


def main() -> None:
    args = arguments()
    output_dir = Path(args.output_dir).resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    setup_scene()
    render_actions(output_dir)
    print("ANIMATION_QA_OK", output_dir)


if __name__ == "__main__":
    main()
