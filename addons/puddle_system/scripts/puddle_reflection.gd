@icon("res://addons/puddle_system/icon/puddle_reflection.svg")
extends Node2D
class_name PuddleReflection

@export var affected_by_reflection_transform:=true:
	set(v):
		if v==affected_by_reflection_transform:
			return
		affected_by_reflection_transform=v
		_affected_by_reflection_transform_change.emit(v)
var parent: Node2D
var initial_position := Vector2.ZERO
var initial_rotation := 0.0
var initial_scale := Vector2.ONE
var initial_skew := 0.0
var current_stretch := 1.0
var current_skew_degrees := 0.0
var manager: Node
var _last_parent_transform := Transform2D()
var _has_parent_transform := false
var _transform_dirty := true

signal _affected_by_reflection_transform_change(bl:bool)
func _ready() -> void:
	manager = get_node_or_null("/root/PuddleManager")
	if manager == null:
		return
	_affected_by_reflection_transform_change.connect(_on_affected_by_reflection_transform_change)
	parent = get_parent() as Node2D
	top_level = true
	_add_reflection_descendants(self)
	var initial_transform := transform
	initial_position = initial_transform.get_origin()
	initial_rotation = initial_transform.get_rotation()
	initial_scale = initial_transform.get_scale()
	initial_skew = initial_transform.get_skew()
	_on_affected_by_reflection_transform_change(affected_by_reflection_transform)
func _add_reflection_descendants(node: Node) -> void:
	_configure_canvas_item(node)
	_configure_descendants(node)
func _configure_canvas_item(node: Node) -> void:
	if not node.child_entered_tree.is_connected(_add_reflection_descendants):
		node.child_entered_tree.connect(_add_reflection_descendants)
	if not node is CanvasItem:
		return
	var canvas_item := node as CanvasItem
	canvas_item.visibility_layer = 1 << (manager.REFLECTION_LAYER - 1)
	canvas_item.light_mask = 1 << (manager.REFLECTION_LAYER - 1)
	if "range_item_cull_mask" in canvas_item:
		canvas_item.range_item_cull_mask = 1 << (manager.REFLECTION_LAYER - 1)

func _configure_descendants(parent_node: Node = self) -> void:
	for 子node in parent_node.get_children():
		_add_reflection_descendants(子node)
func _on_affected_by_reflection_transform_change(bl:bool):
	if manager==null:
		return
	_transform_dirty = true
	if bl:
		current_skew_degrees = manager.reflection_skew_degrees
		current_stretch = manager.reflection_stretch
		if not manager.reflection_skew_degrees_change.is_connected(_on_reflection_skew_changed):
			manager.reflection_skew_degrees_change.connect(_on_reflection_skew_changed)
		if not manager.reflection_stretch_change.is_connected(_on_reflection_stretch_changed):
			manager.reflection_stretch_change.connect(_on_reflection_stretch_changed)
	else:
		current_skew_degrees = 0.0
		current_stretch = 1.0
		if manager.reflection_skew_degrees_change.is_connected(_on_reflection_skew_changed):
			manager.reflection_skew_degrees_change.disconnect(_on_reflection_skew_changed)
		if manager.reflection_stretch_change.is_connected(_on_reflection_stretch_changed):
			manager.reflection_stretch_change.disconnect(_on_reflection_stretch_changed)
		_transform_dirty = true
	sync_parent_transform()

func _process(_delta: float) -> void:
	sync_parent_transform()

func sync_parent_transform() -> void:
	if not is_instance_valid(parent):
		return
	if not parent.is_inside_tree():
		return
	var parent_transform := parent.global_transform
	if not _transform_dirty and _has_parent_transform and parent_transform == _last_parent_transform:
		return
	var determinant := parent_transform.x.cross(parent_transform.y)
	var mirror_compensation := -1.0 if determinant < 0.0 else 1.0
	var local_transform := Transform2D(
		initial_rotation,
		Vector2(initial_scale.x, initial_scale.y * current_stretch),
		initial_skew + deg_to_rad(current_skew_degrees) * mirror_compensation,
		initial_position
	)
	global_transform = parent_transform * local_transform
	_last_parent_transform = parent_transform
	_has_parent_transform = true
	_transform_dirty = false

func _on_reflection_skew_changed(value: float) -> void:
	current_skew_degrees = value
	_transform_dirty = true

func _on_reflection_stretch_changed(value: float) -> void:
	current_stretch = value
	_transform_dirty = true
