"""生成项目统一风格的低模角色与道具 GLB。仅依赖 Python 标准库。"""

import json
import math
import struct
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CHAR_DIR = ROOT / "assets" / "models" / "characters"
PROP_DIR = ROOT / "assets" / "models" / "props"
WEAPON_DIR = ROOT / "assets" / "models" / "weapons"


def add(a, b):
    return tuple(a[i] + b[i] for i in range(3))


def sub(a, b):
    return tuple(a[i] - b[i] for i in range(3))


def mul(a, value):
    return tuple(v * value for v in a)


def dot(a, b):
    return sum(a[i] * b[i] for i in range(3))


def cross(a, b):
    return (a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0])


def normalize(v):
    length = math.sqrt(max(dot(v, v), 1e-12))
    return tuple(x / length for x in v)


def quaternion(axis, angle):
    axis = normalize(axis)
    s = math.sin(angle * 0.5)
    return (axis[0] * s, axis[1] * s, axis[2] * s, math.cos(angle * 0.5))


class BinaryDocument:
    def __init__(self):
        self.data = bytearray()
        self.views = []
        self.accessors = []

    def accessor(self, values, component_type, kind, minimum=None, maximum=None):
        formats = {5126: "f", 5123: "H"}
        widths = {"SCALAR": 1, "VEC3": 3, "VEC4": 4, "MAT4": 16}
        width = widths[kind]
        flat = [value for row in values for value in (row if isinstance(row, (tuple, list)) else (row,))]
        while len(self.data) % 4:
            self.data.append(0)
        offset = len(self.data)
        self.data.extend(struct.pack("<" + formats[component_type] * len(flat), *flat))
        view_index = len(self.views)
        self.views.append({"buffer": 0, "byteOffset": offset, "byteLength": len(self.data) - offset})
        accessor = {
            "bufferView": view_index,
            "componentType": component_type,
            "count": len(values),
            "type": kind,
        }
        if minimum is not None:
            accessor["min"] = list(minimum)
        if maximum is not None:
            accessor["max"] = list(maximum)
        index = len(self.accessors)
        self.accessors.append(accessor)
        return index


class Geometry:
    def __init__(self):
        self.groups = {0: {"p": [], "n": [], "j": [], "w": []}, 1: {"p": [], "n": [], "j": [], "w": []}}

    def triangle(self, a, b, c, joint=0, material=0):
        normal = normalize(cross(sub(b, a), sub(c, a)))
        group = self.groups[material]
        for point in (a, b, c):
            group["p"].append(point)
            group["n"].append(normal)
            group["j"].append((joint, 0, 0, 0))
            group["w"].append((1.0, 0.0, 0.0, 0.0))

    def box(self, center, size, joint=0, material=0):
        x, y, z = (value * 0.5 for value in size)
        cx, cy, cz = center
        v = [(cx + sx * x, cy + sy * y, cz + sz * z) for sx, sy, sz in (
            (-1, -1, -1), (1, -1, -1), (1, 1, -1), (-1, 1, -1),
            (-1, -1, 1), (1, -1, 1), (1, 1, 1), (-1, 1, 1),
        )]
        for a, b, c in ((0, 2, 1), (0, 3, 2), (4, 5, 6), (4, 6, 7), (0, 1, 5), (0, 5, 4),
                        (3, 7, 6), (3, 6, 2), (0, 4, 7), (0, 7, 3), (1, 2, 6), (1, 6, 5)):
            self.triangle(v[a], v[b], v[c], joint, material)

    def ellipsoid(self, center, radii, joint=0, material=0, segments=8, rings=5):
        points = []
        for ring in range(rings + 1):
            phi = math.pi * ring / rings
            row = []
            for segment in range(segments):
                theta = 2.0 * math.pi * segment / segments
                row.append((center[0] + radii[0] * math.sin(phi) * math.cos(theta),
                            center[1] + radii[1] * math.cos(phi),
                            center[2] + radii[2] * math.sin(phi) * math.sin(theta)))
            points.append(row)
        for ring in range(rings):
            for segment in range(segments):
                nxt = (segment + 1) % segments
                a, b = points[ring][segment], points[ring][nxt]
                c, d = points[ring + 1][nxt], points[ring + 1][segment]
                if ring > 0:
                    self.triangle(a, d, b, joint, material)
                if ring < rings - 1:
                    self.triangle(b, d, c, joint, material)

    def frustum(self, start, end, radius_start, radius_end, joint=0, material=0, segments=7):
        axis = normalize(sub(end, start))
        helper = (0.0, 1.0, 0.0) if abs(axis[1]) < 0.9 else (1.0, 0.0, 0.0)
        side = normalize(cross(axis, helper))
        up = normalize(cross(side, axis))
        ring_a, ring_b = [], []
        for i in range(segments):
            angle = 2.0 * math.pi * i / segments
            direction = add(mul(side, math.cos(angle)), mul(up, math.sin(angle)))
            ring_a.append(add(start, mul(direction, radius_start)))
            ring_b.append(add(end, mul(direction, radius_end)))
        for i in range(segments):
            nxt = (i + 1) % segments
            self.triangle(ring_a[i], ring_b[i], ring_a[nxt], joint, material)
            self.triangle(ring_a[nxt], ring_b[i], ring_b[nxt], joint, material)
            self.triangle(start, ring_a[nxt], ring_a[i], joint, material)
            self.triangle(end, ring_b[i], ring_b[nxt], joint, material)

    def ear(self, base, tip, width, joint, material=0):
        front = (base[0], base[1], base[2] - width * 0.25)
        back = (base[0], base[1], base[2] + width * 0.25)
        upper = (base[0], base[1] + width, base[2])
        lower = (base[0], base[1] - width * 0.45, base[2])
        self.triangle(front, tip, upper, joint, material)
        self.triangle(front, lower, tip, joint, material)
        self.triangle(back, upper, tip, joint, material)
        self.triangle(back, tip, lower, joint, material)
        self.triangle(front, upper, back, joint, material)
        self.triangle(front, back, lower, joint, material)


BONES = ["root", "pelvis", "spine", "head", "upper_arm_l", "lower_arm_l", "upper_arm_r", "lower_arm_r",
         "thigh_l", "shin_l", "thigh_r", "shin_r"]
BONE = {name: index for index, name in enumerate(BONES)}
PARENTS = {"pelvis": "root", "spine": "pelvis", "head": "spine", "upper_arm_l": "spine", "lower_arm_l": "upper_arm_l",
           "upper_arm_r": "spine", "lower_arm_r": "upper_arm_r", "thigh_l": "pelvis", "shin_l": "thigh_l",
           "thigh_r": "pelvis", "shin_r": "thigh_r"}


CHARACTERS = {
    "char_goblin_common_lean.glb": {"kind": "lean", "height": 1.72, "width": 0.62, "base": [0.48, 0.39, 0.29, 1], "accent": [0.18, 0.12, 0.09, 1], "refs": 2},
    "char_goblin_common_strong.glb": {"kind": "strong", "height": 1.92, "width": 1.03, "base": [0.45, 0.57, 0.24, 1], "accent": [0.12, 0.10, 0.08, 1], "refs": 2},
    # 注意：char_goblin_charger.glb 已由带纹理版本手工替换（2026-08-13），不再程序化生成，
    # 否则运行本脚本会覆盖正式资产。若需重建，先备份正式 GLB。
    "char_goblin_spitter.glb": {"kind": "spitter", "height": 1.94, "width": 1.20, "base": [0.58, 0.61, 0.15, 1], "accent": [0.22, 1.0, 0.32, 1], "refs": 2, "emissive": True},
    "char_goblin_hunter.glb": {"kind": "hunter", "height": 1.69, "width": 0.82, "base": [0.12, 0.63, 0.48, 1], "accent": [0.12, 1.0, 0.78, 1], "refs": 2, "emissive": True},
    "char_goblin_boomer.glb": {"kind": "boomer", "height": 1.87, "width": 1.34, "base": [0.48, 0.13, 0.08, 1], "accent": [1.0, 0.24, 0.03, 1], "refs": 2, "emissive": True},
}


def skeleton_positions(height, width, kind):
    crouch = 0.93 if kind in {"lean", "hunter", "charger"} else 1.0
    return {
        "root": (0.0, 0.0, 0.0), "pelvis": (0.0, height * 0.47 * crouch, 0.0),
        "spine": (0.0, height * 0.66 * crouch, 0.02), "head": (0.0, height * 0.82 * crouch, -0.03),
        "upper_arm_l": (-width * 0.30, height * 0.68 * crouch, 0.0), "lower_arm_l": (-width * 0.49, height * 0.51 * crouch, -0.03),
        "upper_arm_r": (width * 0.30, height * 0.68 * crouch, 0.0), "lower_arm_r": (width * 0.49, height * 0.51 * crouch, -0.03),
        "thigh_l": (-width * 0.15, height * 0.45 * crouch, 0.0), "shin_l": (-width * 0.16, height * 0.24 * crouch, -0.01),
        "thigh_r": (width * 0.15, height * 0.45 * crouch, 0.0), "shin_r": (width * 0.16, height * 0.24 * crouch, -0.01),
    }


def build_character_geometry(spec):
    kind, height, width = spec["kind"], spec["height"], spec["width"]
    p = skeleton_positions(height, width, kind)
    g = Geometry()
    bulky = kind in {"strong", "charger"}
    round_body = kind in {"spitter", "boomer"}
    torso_rx = width * (0.43 if bulky else 0.31)
    torso_ry = height * (0.20 if bulky else 0.17)
    torso_rz = width * (0.26 if bulky else 0.22)
    if round_body:
        torso_rx, torso_ry, torso_rz = width * 0.45, height * 0.27, width * 0.34
        torso_center = (0.0, height * 0.48, 0.01)
    else:
        torso_center = (0.0, height * 0.62, 0.01)
    g.ellipsoid(torso_center, (torso_rx, torso_ry, torso_rz), BONE["spine"], 0, 10, 6)
    if kind == "charger":
        g.ellipsoid((0.0, height * 0.72, 0.04), (width * 0.48, height * 0.17, width * 0.27), BONE["spine"], 0, 10, 5)
    head_y = p["head"][1]
    head_size = height * (0.105 if kind not in {"spitter", "boomer"} else 0.12)
    g.ellipsoid((0.0, head_y, -0.04), (head_size * 0.82, head_size, head_size * 0.82), BONE["head"], 0, 8, 5)
    ear_span = width * (0.55 if kind == "hunter" else 0.42)
    ear_up = height * (0.11 if kind in {"hunter", "spitter"} else 0.08)
    if spec.get("species", "goblin") == "goblin":
        for side in (-1, 1):
            base = (side * head_size * 0.65, head_y + head_size * 0.12, -0.03)
            tip = (side * ear_span, head_y + ear_up, -0.02)
            g.ear(base, tip, head_size * 0.55, BONE["head"], 0)
        nose_len = height * (0.18 if kind in {"lean", "hunter"} else 0.10)
        g.frustum((0.0, head_y, -head_size * 0.68), (0.0, head_y - head_size * 0.18, -head_size * 0.68 - nose_len),
                  head_size * 0.28, head_size * 0.08, BONE["head"], 0, 6)
        tusk_mat = 1 if kind == "charger" else 0
        for side in (-1, 1):
            g.frustum((side * head_size * 0.38, head_y - head_size * 0.52, -head_size * 0.68),
                      (side * head_size * 0.48, head_y - head_size * 0.05, -head_size * 0.88),
                      head_size * 0.12, 0.01, BONE["head"], tusk_mat, 5)
    else:
        g.box((0.0, head_y - head_size * 0.58, -head_size * 0.28),
              (head_size * 0.95, head_size * 0.36, head_size * 0.65), BONE["head"], 0)
    arm_radius = width * (0.15 if bulky else 0.075)
    if kind == "charger":
        arm_radius *= 1.38
    for side, upper_name, lower_name in ((-1, "upper_arm_l", "lower_arm_l"), (1, "upper_arm_r", "lower_arm_r")):
        shoulder = (side * width * 0.29, height * 0.68, 0.0)
        elbow = p[lower_name]
        hand_y = height * (0.28 if kind == "charger" else (0.29 if kind == "hunter" else 0.33))
        hand = (side * width * (0.57 if kind != "hunter" else 0.53), hand_y, -0.05)
        g.frustum(shoulder, elbow, arm_radius, arm_radius * 0.82, BONE[upper_name], 0, 7)
        g.frustum(elbow, hand, arm_radius * 0.84, arm_radius * (1.15 if kind == "charger" else 0.72), BONE[lower_name], 0, 7)
        g.ellipsoid(hand, (arm_radius * (1.65 if kind == "charger" else 0.85), arm_radius * (1.35 if kind == "charger" else 0.9), arm_radius * 0.8), BONE[lower_name], 0, 7, 4)
    leg_radius = width * (0.13 if bulky else 0.085)
    for side, thigh_name, shin_name in ((-1, "thigh_l", "shin_l"), (1, "thigh_r", "shin_r")):
        hip = (side * width * 0.15, height * 0.48, 0.0)
        knee = p[shin_name]
        ankle = (side * width * 0.16, height * 0.08, 0.0)
        g.frustum(hip, knee, leg_radius, leg_radius * 0.84, BONE[thigh_name], 0, 7)
        g.frustum(knee, ankle, leg_radius * 0.82, leg_radius * 0.62, BONE[shin_name], 0, 7)
        g.box((ankle[0], height * 0.045, -width * 0.07), (leg_radius * 1.65, height * 0.09, width * 0.28), BONE[shin_name], 0)
    g.box((0.0, height * 0.47, 0.0), (width * 0.58, height * 0.10, width * 0.30), BONE["pelvis"], 1)
    g.box((0.0, height * 0.40, 0.01), (width * 0.48, height * 0.10, width * 0.24), BONE["pelvis"], 1)
    eye_y = head_y + head_size * 0.15
    for side in (-1, 1):
        g.ellipsoid((side * head_size * 0.30, eye_y, -head_size * 0.73), (head_size * 0.10,) * 3, BONE["head"], 1, 6, 3)
    if kind == "spitter":
        for x, y, scale in ((-0.25, 0.62, 0.11), (0.26, 0.54, 0.09), (0.08, 0.37, 0.12), (-0.31, 0.43, 0.07)):
            g.ellipsoid((x * width, y * height, -torso_rz * 0.88), (scale * width,) * 3, BONE["spine"], 1, 7, 4)
    if kind == "boomer":
        for x, y, sx, sy in ((-0.18, 0.54, 0.035, 0.13), (0.13, 0.44, 0.03, 0.16), (0.02, 0.62, 0.025, 0.10)):
            g.box((x * width, y * height, -torso_rz * 0.98), (sx * width, sy * height, width * 0.025), BONE["spine"], 1)
    return g, p


def material(base_color, emissive=False, name="材质"):
    item = {"name": name, "doubleSided": True, "pbrMetallicRoughness": {"baseColorFactor": base_color, "metallicFactor": 0.0, "roughnessFactor": 0.82}}
    if emissive:
        item["emissiveFactor"] = [base_color[0] * 0.8, base_color[1] * 0.8, base_color[2] * 0.8]
        item.setdefault("extensions", {})["KHR_materials_emissive_strength"] = {"emissiveStrength": 1.8}
    return item


def animation_definitions():
    return {
        "idle": {"spine": [(0, (0, 1, 0), -0.035), (0.5, (0, 1, 0), 0.035), (1, (0, 1, 0), -0.035)]},
        "walk": {"upper_arm_l": [(0, (1, 0, 0), 0.55), (0.5, (1, 0, 0), -0.55), (1, (1, 0, 0), 0.55)],
                 "upper_arm_r": [(0, (1, 0, 0), -0.55), (0.5, (1, 0, 0), 0.55), (1, (1, 0, 0), -0.55)],
                 "thigh_l": [(0, (1, 0, 0), -0.45), (0.5, (1, 0, 0), 0.45), (1, (1, 0, 0), -0.45)],
                 "thigh_r": [(0, (1, 0, 0), 0.45), (0.5, (1, 0, 0), -0.45), (1, (1, 0, 0), 0.45)]},
        "attack": {"upper_arm_l": [(0, (1, 0, 0), 0), (0.45, (1, 0, 0), -1.15), (1, (1, 0, 0), 0)],
                   "upper_arm_r": [(0, (1, 0, 0), 0), (0.45, (1, 0, 0), -1.15), (1, (1, 0, 0), 0)],
                   "spine": [(0, (1, 0, 0), 0), (0.45, (1, 0, 0), -0.32), (1, (1, 0, 0), 0)]},
        "hurt": {"spine": [(0, (0, 0, 1), 0), (0.25, (0, 0, 1), 0.28), (1, (0, 0, 1), 0)]},
        "death": {"spine": [(0, (0, 0, 1), 0), (1, (0, 0, 1), 1.35)], "head": [(0, (1, 0, 0), 0), (1, (1, 0, 0), -0.55)]},
        "spawn": {"spine": [(0, (1, 0, 0), 0.65), (0.65, (1, 0, 0), -0.12), (1, (1, 0, 0), 0)]},
    }


def write_character(path, spec):
    geometry, positions = build_character_geometry(spec)
    binary = BinaryDocument()
    primitives = []
    triangles = 0
    for material_index in (0, 1):
        group = geometry.groups[material_index]
        if not group["p"]:
            continue
        triangles += len(group["p"]) // 3
        mins = tuple(min(point[i] for point in group["p"]) for i in range(3))
        maxs = tuple(max(point[i] for point in group["p"]) for i in range(3))
        primitives.append({"attributes": {
            "POSITION": binary.accessor(group["p"], 5126, "VEC3", mins, maxs),
            "NORMAL": binary.accessor(group["n"], 5126, "VEC3"),
            "JOINTS_0": binary.accessor(group["j"], 5123, "VEC4"),
            "WEIGHTS_0": binary.accessor(group["w"], 5126, "VEC4"),
        }, "material": material_index, "mode": 4})
    nodes = []
    children = {name: [] for name in BONES}
    for child, parent in PARENTS.items():
        children[parent].append(BONE[child])
    for name in BONES:
        world = positions[name]
        parent = PARENTS.get(name)
        translation = sub(world, positions[parent]) if parent else world
        node = {"name": name, "translation": list(translation)}
        if children[name]:
            node["children"] = children[name]
        nodes.append(node)
    inverse_bind = []
    for name in BONES:
        x, y, z = positions[name]
        inverse_bind.append((1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, -x, -y, -z, 1))
    ibm_accessor = binary.accessor(inverse_bind, 5126, "MAT4")
    mesh_node = len(nodes)
    nodes.append({"name": "BodyMesh", "mesh": 0, "skin": 0})
    animations = []
    for clip_name, channels_by_bone in animation_definitions().items():
        samplers, channels = [], []
        for bone_name, keys in channels_by_bone.items():
            times = [(key[0],) for key in keys]
            rotations = [quaternion(key[1], key[2]) for key in keys]
            sampler_index = len(samplers)
            samplers.append({"input": binary.accessor(times, 5126, "SCALAR", (times[0][0],), (times[-1][0],)),
                             "output": binary.accessor(rotations, 5126, "VEC4"), "interpolation": "LINEAR"})
            channels.append({"sampler": sampler_index, "target": {"node": BONE[bone_name], "path": "rotation"}})
        animations.append({"name": clip_name, "samplers": samplers, "channels": channels})
    materials = [material(spec["base"], False, "皮肤与服饰"), material(spec["accent"], spec.get("emissive", False), "识别强调")]
    doc = {
        "asset": {"version": "2.0", "generator": "xjtf procedural low-poly pipeline", "extras": {"xjtf": {
            "height_m": spec["height"], "forward": "-Z", "triangles": triangles, "concept_refs": spec["refs"],
            "style": "stylized_low_poly", "animation_set": sorted(animation_definitions()),
        }}},
        "extensionsUsed": ["KHR_materials_emissive_strength"] if spec.get("emissive") else [],
        "scene": 0, "scenes": [{"name": path.stem, "nodes": [BONE["root"], mesh_node]}], "nodes": nodes,
        "meshes": [{"name": path.stem + "_mesh", "primitives": primitives}], "materials": materials,
        "skins": [{"name": "goblin_rig", "inverseBindMatrices": ibm_accessor, "joints": list(range(len(BONES))), "skeleton": BONE["root"]}],
        "animations": animations, "buffers": [{"byteLength": len(binary.data)}], "bufferViews": binary.views, "accessors": binary.accessors,
    }
    write_glb(path, doc, binary.data)
    print(f"生成 {path.relative_to(ROOT)}：{triangles} tris / 12 bones / 6 animations")


def write_prop(path, kind):
    g = Geometry()
    if kind == "ammo":
        g.box((0, 0.16, 0), (0.48, 0.30, 0.34), 0, 0)
        g.box((0, 0.32, 0), (0.45, 0.045, 0.31), 0, 1)
        for x in (-0.13, 0, 0.13):
            g.frustum((x, 0.34, -0.05), (x, 0.48, -0.05), 0.035, 0.025, 0, 1, 6)
    else:
        g.box((0, 0.16, 0), (0.42, 0.30, 0.16), 0, 0)
        g.box((0, 0.17, -0.085), (0.10, 0.23, 0.025), 0, 1)
        g.box((0, 0.17, -0.088), (0.24, 0.09, 0.025), 0, 1)
        g.frustum((-0.11, 0.32, 0), (0.11, 0.32, 0), 0.025, 0.025, 0, 0, 6)
    binary = BinaryDocument()
    primitives, triangles = [], 0
    for material_index in (0, 1):
        group = g.groups[material_index]
        if not group["p"]:
            continue
        triangles += len(group["p"]) // 3
        mins = tuple(min(point[i] for point in group["p"]) for i in range(3))
        maxs = tuple(max(point[i] for point in group["p"]) for i in range(3))
        primitives.append({"attributes": {"POSITION": binary.accessor(group["p"], 5126, "VEC3", mins, maxs),
                                             "NORMAL": binary.accessor(group["n"], 5126, "VEC3")}, "material": material_index, "mode": 4})
    colors = ([0.95, 0.55, 0.06, 1], [1.0, 0.79, 0.24, 1]) if kind == "ammo" else ([0.88, 0.88, 0.78, 1], [0.24, 0.86, 0.52, 1])
    doc = {"asset": {"version": "2.0", "generator": "xjtf procedural low-poly pipeline", "extras": {"xjtf": {
        "triangles": triangles, "forward": "-Z", "style": "stylized_low_poly"}}}, "scene": 0,
        "scenes": [{"name": path.stem, "nodes": [0]}], "nodes": [{"name": path.stem, "mesh": 0}],
        "meshes": [{"name": path.stem + "_mesh", "primitives": primitives}],
        "materials": [material(colors[0], False, "主体"), material(colors[1], True, "交互强调")],
        "extensionsUsed": ["KHR_materials_emissive_strength"], "buffers": [{"byteLength": len(binary.data)}],
        "bufferViews": binary.views, "accessors": binary.accessors}
    write_glb(path, doc, binary.data)
    print(f"生成 {path.relative_to(ROOT)}：{triangles} tris")


def write_throwable(path, kind):
    """投掷物模型：手榴弹（球形主体+引信+菠萝纹）/ 燃烧瓶（瓶身+瓶颈+火焰布条）。
    材质 0=主体、材质 1=强调（燃烧瓶布条 emissive）。"""
    g = Geometry()
    if kind == "grenade":
        g.ellipsoid((0, 0.10, 0), (0.09, 0.11, 0.09), 0, 0, 8, 5)
        g.frustum((0, 0.20, 0), (0, 0.26, 0), 0.025, 0.02, 0, 1, 6)
        g.ellipsoid((0.05, 0.27, 0), (0.03, 0.015, 0.015), 0, 1, 6, 3)
        for i in range(8):
            a = 2.0 * math.pi * i / 8.0
            g.box((math.cos(a) * 0.08, 0.10, math.sin(a) * 0.08), (0.03, 0.03, 0.03), 0, 0)
        base = [0.23, 0.29, 0.22, 1]
        accent = [0.62, 0.64, 0.60, 1]
        emissive = False
    else:
        g.frustum((0, 0.02, 0), (0, 0.20, 0), 0.075, 0.055, 0, 0, 7)
        g.frustum((0, 0.20, 0), (0, 0.30, 0), 0.055, 0.024, 0, 0, 6)
        g.box((0, 0.315, 0), (0.05, 0.03, 0.05), 0, 1)
        base = [0.38, 0.32, 0.24, 1]
        accent = [1.0, 0.45, 0.05, 1]
        emissive = True
    binary = BinaryDocument()
    primitives, triangles = [], 0
    for material_index in (0, 1):
        group = g.groups[material_index]
        triangles += len(group["p"]) // 3
        mins = tuple(min(point[i] for point in group["p"]) for i in range(3))
        maxs = tuple(max(point[i] for point in group["p"]) for i in range(3))
        primitives.append({"attributes": {"POSITION": binary.accessor(group["p"], 5126, "VEC3", mins, maxs),
                                             "NORMAL": binary.accessor(group["n"], 5126, "VEC3")}, "material": material_index, "mode": 4})
    doc = {"asset": {"version": "2.0", "generator": "xjtf procedural low-poly pipeline", "extras": {"xjtf": {
        "triangles": triangles, "forward": "-Z", "style": "stylized_low_poly"}}}, "scene": 0,
        "scenes": [{"name": path.stem, "nodes": [0]}], "nodes": [{"name": path.stem, "mesh": 0}],
        "meshes": [{"name": path.stem + "_mesh", "primitives": primitives}],
        "materials": [material(base, False, "主体"), material(accent, emissive, "强调")],
        "extensionsUsed": ["KHR_materials_emissive_strength"] if emissive else [],
        "buffers": [{"byteLength": len(binary.data)}], "bufferViews": binary.views, "accessors": binary.accessors}
    write_glb(path, doc, binary.data)
    print(f"生成 {path.relative_to(ROOT)}：{triangles} tris")


def static_humanoid_geometry(kind):
    g = Geometry()
    if kind == "player":
        skin, accent, height = [0.30, 0.42, 0.58, 1], [0.92, 0.48, 0.16, 1], 1.80
        g.ellipsoid((0, 1.61, 0), (0.14, 0.17, 0.13), 0, 0, 8, 5)
        g.ellipsoid((0, 1.19, 0), (0.30, 0.34, 0.18), 0, 0, 9, 5)
        g.box((0, 1.02, -0.18), (0.34, 0.16, 0.05), 0, 1)
        for side in (-1, 1):
            g.frustum((side * 0.24, 1.38, 0), (side * 0.32, 0.91, -0.02), 0.09, 0.07, 0, 0, 7)
            g.ellipsoid((side * 0.33, 0.82, -0.03), (0.08, 0.11, 0.07), 0, 1, 7, 4)
            g.frustum((side * 0.14, 0.91, 0), (side * 0.16, 0.42, 0), 0.115, 0.09, 0, 0, 7)
            g.frustum((side * 0.16, 0.42, 0), (side * 0.16, 0.10, -0.02), 0.09, 0.065, 0, 0, 7)
            g.box((side * 0.16, 0.05, -0.06), (0.17, 0.10, 0.28), 0, 1)
    else:
        skin, accent, height = [0.58, 0.68, 0.34, 1], [0.18, 0.16, 0.13, 1], 1.82
        g.ellipsoid((0, 1.61, -0.02), (0.16, 0.18, 0.15), 0, 0, 8, 5)
        g.box((0, 1.50, -0.13), (0.18, 0.09, 0.08), 0, 1)
        g.ellipsoid((0, 1.18, 0), (0.42, 0.38, 0.24), 0, 0, 10, 6)
        g.ellipsoid((0, 0.91, 0), (0.35, 0.25, 0.22), 0, 0, 9, 5)
        g.box((0, 0.84, 0), (0.58, 0.15, 0.35), 0, 1)
        for side in (-1, 1):
            g.frustum((side * 0.36, 1.36, 0), (side * 0.48, 0.86, -0.03), 0.13, 0.10, 0, 0, 7)
            g.ellipsoid((side * 0.49, 0.76, -0.04), (0.11, 0.13, 0.09), 0, 0, 7, 4)
            g.frustum((side * 0.20, 0.82, 0), (side * 0.21, 0.42, 0), 0.14, 0.11, 0, 1, 7)
            g.frustum((side * 0.21, 0.42, 0), (side * 0.21, 0.10, 0), 0.11, 0.08, 0, 0, 7)
            g.box((side * 0.21, 0.05, -0.07), (0.22, 0.10, 0.31), 0, 0)
    return g, skin, accent, height


def write_static_humanoid(path, kind):
    g, base, accent, height = static_humanoid_geometry(kind)
    binary = BinaryDocument()
    primitives, triangles = [], 0
    for material_index in (0, 1):
        group = g.groups[material_index]
        triangles += len(group["p"]) // 3
        mins = tuple(min(point[i] for point in group["p"]) for i in range(3))
        maxs = tuple(max(point[i] for point in group["p"]) for i in range(3))
        primitives.append({"attributes": {"POSITION": binary.accessor(group["p"], 5126, "VEC3", mins, maxs),
                                             "NORMAL": binary.accessor(group["n"], 5126, "VEC3")}, "material": material_index, "mode": 4})
    refs = 1 if kind == "zombie_strong" else 0
    doc = {"asset": {"version": "2.0", "generator": "xjtf procedural low-poly pipeline", "extras": {"xjtf": {
        "height_m": height, "forward": "-Z", "triangles": triangles, "concept_refs": refs, "style": "stylized_low_poly"}}},
        "scene": 0, "scenes": [{"name": path.stem, "nodes": [0]}], "nodes": [{"name": path.stem, "mesh": 0}],
        "meshes": [{"name": path.stem + "_mesh", "primitives": primitives}],
        "materials": [material(base, False, "主体"), material(accent, False, "服饰强调")],
        "buffers": [{"byteLength": len(binary.data)}], "bufferViews": binary.views, "accessors": binary.accessors}
    write_glb(path, doc, binary.data)
    print(f"重建 {path.relative_to(ROOT)}：{triangles} tris")


def write_arms_view(path):
    """第一人称手臂 view 模型（右手持枪，相机局部 -Z 朝前，Y 向上）。
    材质 0=手臂皮肤、材质 1=袖子/手套，运行时由皮肤系统按 surface index 换色。"""
    g = Geometry()
    # 袖子（材质 1 accent）：肘 → 前臂中点
    g.frustum((0.30, -0.34, -0.04), (0.22, -0.20, -0.22), 0.062, 0.052, 0, 1, 7)
    # 前臂（材质 0 skin）：前臂中点 → 手腕
    g.frustum((0.22, -0.20, -0.22), (0.16, -0.12, -0.42), 0.052, 0.040, 0, 0, 7)
    # 手（材质 0 skin）：握枪姿势，沿 -Z 拉长
    g.ellipsoid((0.14, -0.09, -0.49), (0.042, 0.048, 0.085), 0, 0, 7, 4)
    binary = BinaryDocument()
    primitives, triangles = [], 0
    for material_index in (0, 1):
        group = g.groups[material_index]
        triangles += len(group["p"]) // 3
        mins = tuple(min(point[i] for point in group["p"]) for i in range(3))
        maxs = tuple(max(point[i] for point in group["p"]) for i in range(3))
        primitives.append({"attributes": {"POSITION": binary.accessor(group["p"], 5126, "VEC3", mins, maxs),
                                             "NORMAL": binary.accessor(group["n"], 5126, "VEC3")}, "material": material_index, "mode": 4})
    base = [0.86, 0.70, 0.58, 1]
    accent = [0.25, 0.26, 0.28, 1]
    doc = {"asset": {"version": "2.0", "generator": "xjtf procedural low-poly pipeline", "extras": {"xjtf": {
        "triangles": triangles, "forward": "-Z", "style": "stylized_low_poly"}}}, "scene": 0,
        "scenes": [{"name": path.stem, "nodes": [0]}], "nodes": [{"name": path.stem, "mesh": 0}],
        "meshes": [{"name": path.stem + "_mesh", "primitives": primitives}],
        "materials": [material(base, False, "手臂皮肤"), material(accent, False, "袖子/手套")],
        "buffers": [{"byteLength": len(binary.data)}], "bufferViews": binary.views, "accessors": binary.accessors}
    write_glb(path, doc, binary.data)
    print(f"生成 {path.relative_to(ROOT)}：{triangles} tris")


def write_glb(path, document, blob):
    path.parent.mkdir(parents=True, exist_ok=True)
    while len(blob) % 4:
        blob.append(0)
    document["buffers"][0]["byteLength"] = len(blob)
    json_bytes = json.dumps(document, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    json_bytes += b" " * ((4 - len(json_bytes) % 4) % 4)
    total = 12 + 8 + len(json_bytes) + 8 + len(blob)
    output = bytearray(struct.pack("<4sII", b"glTF", 2, total))
    output.extend(struct.pack("<II", len(json_bytes), 0x4E4F534A))
    output.extend(json_bytes)
    output.extend(struct.pack("<II", len(blob), 0x004E4942))
    output.extend(blob)
    path.write_bytes(output)


def main():
    for filename, spec in CHARACTERS.items():
        write_character(CHAR_DIR / filename, spec)
    write_prop(PROP_DIR / "prop_ammo_01.glb", "ammo")
    write_prop(PROP_DIR / "prop_medkit_01.glb", "medkit")
    write_throwable(PROP_DIR / "prop_grenade_01.glb", "grenade")
    write_throwable(PROP_DIR / "prop_molotov_01.glb", "molotov")
    write_static_humanoid(CHAR_DIR / "char_player_01.glb", "player")
    write_static_humanoid(CHAR_DIR / "char_zombie_common_02.glb", "zombie_strong")
    write_arms_view(WEAPON_DIR / "wep_arms_view.glb")
    zombie_spitter = {"kind": "spitter", "species": "zombie", "height": 1.95, "width": 1.10,
                      "base": [0.60, 0.64, 0.18, 1], "accent": [0.22, 1.0, 0.32, 1],
                      "refs": 1, "emissive": True}
    write_character(CHAR_DIR / "char_zombie_spitter_01.glb", zombie_spitter)


if __name__ == "__main__":
    main()
