class_name AoeFxPool
extends Node3D
## 固定容量 AOE 表现池，避免高潮阶段反复创建和销毁节点。

const CAPACITY := 16
var _items: Array[MeshInstance3D] = []
var _timers: Array[float] = []
var _cursor := 0


func _ready() -> void:
	for i in CAPACITY:
		var mesh_instance := MeshInstance3D.new()
		var mesh := SphereMesh.new()
		mesh.radius = 1.0
		mesh.height = 2.0
		var material := StandardMaterial3D.new()
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.albedo_color = Color(1.0, 0.35, 0.05, 0.45)
		mesh.material = material
		mesh_instance.mesh = mesh
		mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mesh_instance.visible = false
		add_child(mesh_instance)
		_items.append(mesh_instance)
		_timers.append(0.0)


func show_aoe(position: Vector3, kind: String) -> void:
	var item := _items[_cursor]
	item.global_position = position
	item.scale = Vector3.ONE * (0.25 if kind == "grenade" else 0.4)
	item.visible = true
	_timers[_cursor] = 0.45
	_cursor = (_cursor + 1) % CAPACITY


func _process(delta: float) -> void:
	for i in _items.size():
		if _timers[i] <= 0.0:
			continue
		_timers[i] -= delta
		_items[i].scale += Vector3.ONE * delta * 12.0
		if _timers[i] <= 0.0:
			_items[i].visible = false
