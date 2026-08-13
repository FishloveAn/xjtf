class_name BloodDecalPool
extends Node3D
## 血渍贴花池（美术方向 §3.6：地面/墙面血迹，Decal 投影）。
## 固定容量池：死亡/命中时 spawn_decal 复用最旧贴花，避免反复创建节点；血渍贴图程序生成（随机斑点），
## 无外部素材依赖；贴花持久保留（尸体消失后血迹仍在地面，符合 L4D 氛围）。

const CAPACITY := 24
const TEXTURE_VARIANTS := 3

var _decals: Array[Decal] = []
var _textures: Array[ImageTexture] = []
var _cursor := 0


func _ready() -> void:
	add_to_group("blood_decal_pool")
	for i in TEXTURE_VARIANTS:
		_textures.append(_make_blood_texture(1000 + i))
	for i in CAPACITY:
		var decal := Decal.new()
		decal.visible = false
		add_child(decal)
		_decals.append(decal)


## 在 pos 处投影一块血迹（朝下贴地，随机滚转/缩放/贴图变体）。
func spawn_decal(pos: Vector3) -> void:
	var decal := _decals[_cursor]
	_cursor = (_cursor + 1) % CAPACITY
	decal.texture_albedo = _textures[randi() % _textures.size()]
	decal.global_position = pos + Vector3(0.0, 0.08, 0.0)
	decal.rotation = Vector3(-PI / 2.0, randf_range(0.0, TAU), 0.0)
	var s := randf_range(0.5, 1.0)
	decal.size = Vector3(0.7 * s, 0.7 * s, 0.5 * s)
	decal.visible = true


## 程序生成血渍贴图：透明底 + 随机红色斑点（叠加以模拟泼溅），128x128 RGBA。
func _make_blood_texture(seed_val: int) -> ImageTexture:
	var size := 128
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.0, 0.0, 0.0, 0.0))
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_val
	for i in 40:
		var cx := int(rng.randf_range(0.15, 0.85) * size)
		var cy := int(rng.randf_range(0.15, 0.85) * size)
		var r := int(rng.randf_range(4.0, 22.0))
		var alpha := rng.randf_range(0.25, 0.7)
		_paint_blob(img, cx, cy, r, Color(0.42, 0.03, 0.03, alpha))
	return ImageTexture.create_from_image(img)


## 在 img 上画一个径向衰减的血渍斑点（边缘羽化，中心实）。
func _paint_blob(img: Image, cx: int, cy: int, r: int, col: Color) -> void:
	for y in range(-r, r + 1):
		for x in range(-r, r + 1):
			var d := Vector2(x, y).length()
			if d > r:
				continue
			var px := cx + x
			var py := cy + y
			if px < 0 or py < 0 or px >= img.get_width() or py >= img.get_height():
				continue
			var a := col.a * (1.0 - d / r)
			var existing := img.get_pixel(px, py)
			img.set_pixel(px, py, Color(col.r, col.g, col.b, clampf(existing.a + a, 0.0, 1.0)))
