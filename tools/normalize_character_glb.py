import json
import struct
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
TARGETS = {
    "char_player_01.glb": {"scale": 0.578, "merge_player_materials": True},
    "char_zombie_common_01.glb": {"scale": 1.45},
    "char_zombie_spitter_01.glb": {"scale": 1.81},
}


def read_glb(path: Path) -> tuple[dict, list[tuple[int, bytes]]]:
    data = path.read_bytes()
    magic, version, _ = struct.unpack_from("<4sII", data, 0)
    if magic != b"glTF" or version != 2:
        raise ValueError(f"不支持的 GLB：{path}")

    chunks = []
    offset = 12
    while offset < len(data):
        length, chunk_type = struct.unpack_from("<II", data, offset)
        offset += 8
        chunks.append((chunk_type, data[offset:offset + length]))
        offset += length

    document = json.loads(chunks[0][1].rstrip(b" \x00").decode("utf-8"))
    return document, chunks[1:]


def write_glb(path: Path, document: dict, chunks: list[tuple[int, bytes]]) -> None:
    json_data = json.dumps(document, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    json_data += b" " * ((4 - len(json_data) % 4) % 4)
    output_chunks = [(0x4E4F534A, json_data), *chunks]
    total = 12 + sum(8 + len(data) for _, data in output_chunks)

    output = bytearray(struct.pack("<4sII", b"glTF", 2, total))
    for chunk_type, data in output_chunks:
        output.extend(struct.pack("<II", len(data), chunk_type))
        output.extend(data)
    path.write_bytes(output)


def normalize(path: Path, scale: float, merge_player_materials: bool = False) -> None:
    document, chunks = read_glb(path)
    extras = document.setdefault("asset", {}).setdefault("extras", {})
    marker = extras.setdefault("xjtf_normalized", {})

    if not marker.get("root_scale"):
        scene = document["scenes"][document.get("scene", 0)]
        for node_index in scene["nodes"]:
            node = document["nodes"][node_index]
            previous = node.get("scale", [1.0, 1.0, 1.0])
            node["scale"] = [value * scale for value in previous]
        marker["root_scale"] = scale

    if merge_player_materials and not marker.get("two_materials"):
        old_materials = document["materials"]
        document["materials"] = [old_materials[1], old_materials[4]]
        for mesh in document.get("meshes", []):
            for primitive in mesh.get("primitives", []):
                primitive["material"] = 1 if primitive.get("material") == 4 else 0
        marker["two_materials"] = True

    write_glb(path, document, chunks)
    print(f"已规范化：{path.relative_to(ROOT)}")


if __name__ == "__main__":
    character_dir = ROOT / "assets" / "models" / "characters"
    for filename, options in TARGETS.items():
        normalize(character_dir / filename, **options)
