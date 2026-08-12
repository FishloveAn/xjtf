import json
import struct
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CHARACTER_DIR = ROOT / "assets" / "models" / "characters"
PROP_DIR = ROOT / "assets" / "models" / "props"

EXPECTED_CHARACTERS = {
    "char_goblin_common_lean.glb": (1.55, 2.05),
    "char_goblin_common_strong.glb": (1.65, 2.20),
    "char_goblin_charger.glb": (1.85, 2.35),
    "char_goblin_spitter.glb": (1.75, 2.20),
    "char_goblin_hunter.glb": (1.45, 1.95),
    "char_goblin_boomer.glb": (1.65, 2.10),
}
EXPECTED_PROPS = {
    "prop_ammo_01.glb": 300,
    "prop_medkit_01.glb": 400,
}
REQUIRED_ANIMATIONS = {"idle", "walk", "attack", "hurt", "death", "spawn"}


def read_glb(path: Path) -> dict:
    raw = path.read_bytes()
    magic, version, _ = struct.unpack_from("<4sII", raw, 0)
    assert magic == b"glTF" and version == 2, f"GLB 头无效：{path.name}"
    json_length, json_type = struct.unpack_from("<II", raw, 12)
    assert json_type == 0x4E4F534A, f"GLB JSON 块无效：{path.name}"
    return json.loads(raw[20:20 + json_length].rstrip(b" \x00"))


def validate_character(path: Path, height_range: tuple[float, float]) -> list[str]:
    errors = []
    if not path.exists():
        return [f"缺少 {path.relative_to(ROOT)}"]
    doc = read_glb(path)
    animations = {item.get("name") for item in doc.get("animations", [])}
    missing = REQUIRED_ANIMATIONS - animations
    if missing:
        errors.append(f"{path.name} 缺动画：{sorted(missing)}")
    if not doc.get("skins"):
        errors.append(f"{path.name} 缺骨骼绑定")
    if not 1 <= len(doc.get("materials", [])) <= 2:
        errors.append(f"{path.name} 材质数应为 1-2")
    extras = doc.get("asset", {}).get("extras", {}).get("xjtf", {})
    height = float(extras.get("height_m", 0.0))
    if not height_range[0] <= height <= height_range[1]:
        errors.append(f"{path.name} 高度元数据异常：{height:.2f}m")
    if extras.get("forward") != "-Z":
        errors.append(f"{path.name} 朝向元数据不是 -Z")
    if extras.get("concept_refs", 0) < 1:
        errors.append(f"{path.name} 未记录概念图映射")
    return errors


def validate_prop(path: Path, tri_limit: int) -> list[str]:
    if not path.exists():
        return [f"缺少 {path.relative_to(ROOT)}"]
    doc = read_glb(path)
    extras = doc.get("asset", {}).get("extras", {}).get("xjtf", {})
    tris = int(extras.get("triangles", 0))
    errors = []
    if tris <= 0 or tris > tri_limit:
        errors.append(f"{path.name} 三角面 {tris} 超出 1-{tri_limit}")
    if len(doc.get("materials", [])) > 2:
        errors.append(f"{path.name} 材质数超过 2")
    return errors


def main() -> int:
    errors = []
    for filename, height_range in EXPECTED_CHARACTERS.items():
        errors.extend(validate_character(CHARACTER_DIR / filename, height_range))
    strong = CHARACTER_DIR / "char_zombie_common_02.glb"
    if not strong.exists():
        errors.append("缺少普通丧尸壮型 char_zombie_common_02.glb")
    for filename, tri_limit in EXPECTED_PROPS.items():
        errors.extend(validate_prop(PROP_DIR / filename, tri_limit))
    if errors:
        print("ART_ASSET_TEST_FAIL")
        for error in errors:
            print(" -", error)
        return 1
    print("ART_ASSET_TEST_OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
