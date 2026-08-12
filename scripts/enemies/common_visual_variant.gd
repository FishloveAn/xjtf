extends Node3D

@onready var _lean: Node3D = $Lean
@onready var _strong: Node3D = $Strong


func _ready() -> void:
	var use_strong: bool = abs(get_parent().name.hash()) % 2 == 1
	_lean.visible = not use_strong
	_strong.visible = use_strong
