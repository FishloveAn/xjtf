class_name TracerPool
extends MultiMeshInstance3D
## 固定容量曳光池，避免持续射击反复创建节点。

const CAPACITY := 64
const WIDTH := 0.018

var _expires: PackedInt64Array = PackedInt64Array()
var _cursor := 0


func _ready() -> void:
	add_to_group("tracer_pool")
	var box := BoxMesh.new()
	box.size = Vector3.ONE
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.vertex_color_use_as_albedo = true
	box.material = material
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = box
	mm.instance_count = CAPACITY
	multimesh = mm
	_expires.resize(CAPACITY)
	for i in CAPACITY:
		_hide(i)


func show_tracer(from: Vector3, to: Vector3, color: Color = Color(1.0, 0.82, 0.25), duration_s: float = 0.08) -> void:
	var length := from.distance_to(to)
	if length < 0.01:
		return
	var index := _cursor
	_cursor = (_cursor + 1) % CAPACITY
	var direction := (to - from).normalized()
	var basis := Basis.looking_at(direction, Vector3.UP)
	basis = basis.scaled(Vector3(WIDTH, WIDTH, length))
	multimesh.set_instance_transform(index, Transform3D(basis, (from + to) * 0.5))
	multimesh.set_instance_color(index, color)
	_expires[index] = Time.get_ticks_msec() + int(duration_s * 1000.0)


func _process(_delta: float) -> void:
	var now := Time.get_ticks_msec()
	for i in CAPACITY:
		if _expires[i] > 0 and now >= _expires[i]:
			_hide(i)


func _hide(index: int) -> void:
	multimesh.set_instance_transform(index, Transform3D(Basis.from_scale(Vector3.ZERO), Vector3.ZERO))
	_expires[index] = 0
