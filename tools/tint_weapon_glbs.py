import json
import struct
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
TINTS = {
    "wep_pistol_01.glb": [1.0, 0.78, 0.24, 1.0],
    "wep_shotgun_01.glb": [1.0, 0.35, 0.08, 1.0],
    "wep_rifle_01.glb": [0.20, 0.46, 0.82, 1.0],
    "wep_smg_01.glb": [0.15, 0.62, 0.78, 1.0],
}


def tint(path: Path, color: list[float]) -> None:
    raw = path.read_bytes()
    json_length, json_type = struct.unpack_from("<II", raw, 12)
    if json_type != 0x4E4F534A:
        raise ValueError(f"GLB JSON 块无效：{path.name}")
    document = json.loads(raw[20:20 + json_length].rstrip(b" \x00"))
    binary_offset = 20 + json_length
    binary_length, binary_type = struct.unpack_from("<II", raw, binary_offset)
    binary = raw[binary_offset + 8:binary_offset + 8 + binary_length]
    for item in document.get("materials", []):
        pbr = item.setdefault("pbrMetallicRoughness", {})
        pbr["baseColorFactor"] = color
        pbr["metallicFactor"] = 0.15
        pbr["roughnessFactor"] = 0.68
    document.setdefault("asset", {}).setdefault("extras", {})["xjtf_weapon_tint"] = color
    json_bytes = json.dumps(document, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    json_bytes += b" " * ((4 - len(json_bytes) % 4) % 4)
    total = 12 + 8 + len(json_bytes) + 8 + len(binary)
    output = bytearray(struct.pack("<4sII", b"glTF", 2, total))
    output.extend(struct.pack("<II", len(json_bytes), 0x4E4F534A))
    output.extend(json_bytes)
    output.extend(struct.pack("<II", len(binary), binary_type))
    output.extend(binary)
    path.write_bytes(output)
    print(f"着色 {path.relative_to(ROOT)} -> {color}")


if __name__ == "__main__":
    directory = ROOT / "assets" / "models" / "weapons"
    for filename, tint_color in TINTS.items():
        tint(directory / filename, tint_color)
