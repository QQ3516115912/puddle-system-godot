@tool
@icon("res://addons/puddle_system/icon/puddle_region.svg")
extends Polygon2D
class_name PuddleRegion

enum RegionType {
	GENERATE,## 在region内会强制产生积水
	EXCLUDE,## region内不会GENERATE积水，优先级高于GENERATE
}

## Region Purpose：GENERATE会强制产生积水，EXCLUDE会从积水中裁掉该region。
@export var region_type: RegionType = RegionType.GENERATE:
	set(value):
		if region_type == value:
			return
		var old_type := region_type
		region_type = value
		_rounded_polygon_cache.clear()
		if is_node_ready():
			var manager := get_node_or_null("/root/PuddleManager")
			if manager != null and manager.has_method("update_puddle_region_type"):
				manager.update_puddle_region_type(self, old_type, value)

var _last_local_points := PackedVector2Array()
var _last_global_transform := Transform2D()
var _world_points := PackedVector2Array()
var _world_bounds := Rect2()
var _rounded_polygon_cache: Dictionary = {}
var _update_queued := false

func _ready() -> void:
	set_notify_transform(true)
	_refresh_region_cache(false)
	if not Engine.is_editor_hint():
		visible = false
	var manager := get_node_or_null("/root/PuddleManager")
	if manager != null:
		manager.register_puddle_region(self)

func _exit_tree() -> void:
	var manager := get_node_or_null("/root/PuddleManager")
	if manager != null:
		manager.unregister_puddle_region(self, _world_bounds)

func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSFORM_CHANGED:
		_request_region_cache_refresh()
	elif what == NOTIFICATION_DRAW and polygon != _last_local_points:
		_request_region_cache_refresh()

func _request_region_cache_refresh() -> void:
	if not is_node_ready() or _update_queued:
		return
	_update_queued = true
	call_deferred("_execute_region_cache_refresh")

func _execute_region_cache_refresh() -> void:
	_update_queued = false
	if not is_inside_tree():
		return
	_refresh_region_cache(true)

func _refresh_region_cache(notify_manager: bool) -> void:
	var current_local_points := polygon
	var current_global_transform := global_transform
	if current_local_points == _last_local_points and current_global_transform == _last_global_transform:
		return
	var old_bounds := _world_bounds
	_last_local_points = current_local_points
	_last_global_transform = current_global_transform
	_world_points = PackedVector2Array()
	for point in current_local_points:
		_world_points.append(current_global_transform * point)
	_world_bounds = _calculate_bounds(_world_points)
	_rounded_polygon_cache.clear()
	if notify_manager:
		var manager := get_node_or_null("/root/PuddleManager")
		if manager != null:
			manager.update_puddle_region(self, old_bounds, _world_bounds)

func get_region_type() -> int:
	return region_type

func get_world_bounds() -> Rect2:
	return _world_bounds

func get_world_polygon(rounding_percent: float) -> PackedVector2Array:
	if rounding_percent <= 0.0 or _world_points.size() < 3:
		return _world_points
	var cache_key := snappedf(rounding_percent, 0.001)
	if _rounded_polygon_cache.has(cache_key):
		return _rounded_polygon_cache[cache_key]
	var curved_polygon := _curve_polygon_boundary(_world_points, rounding_percent, get_region_type() == RegionType.GENERATE)
	var result := curved_polygon if curved_polygon.size() >= 3 else _world_points
	_rounded_polygon_cache[cache_key] = result
	return result

func _calculate_bounds(points: PackedVector2Array) -> Rect2:
	if points.is_empty():
		return Rect2()
	var minimum_position := points[0]
	var maximum_position := points[0]
	var max_edge_length := 0.0
	for index in range(points.size()):
		var point := points[index]
		minimum_position = minimum_position.min(point)
		maximum_position = maximum_position.max(point)
		max_edge_length = maxf(max_edge_length, point.distance_to(points[(index + 1) % points.size()]))
	# 圆角control_point最多offset半条边，扩大bounds可避免曲线外凸时被错误裁掉。
	return Rect2(minimum_position, maximum_position - minimum_position).grow(max_edge_length * 0.5)

func _curve_polygon_boundary(points: PackedVector2Array, rounding_percent: float, reverse_arc: bool) -> PackedVector2Array:
	if points.size() < 3 or rounding_percent <= 0.0:
		return points
	var signed_area := 0.0
	for index in range(points.size()):
		signed_area += points[index].cross(points[(index + 1) % points.size()])
	var winding := 1.0 if signed_area >= 0.0 else -1.0
	var rounding_factor := clampf(rounding_percent / 100.0, 0.0, 1.0)
	var result := PackedVector2Array()
	for index in range(points.size()):
		var start_point := points[index]
		var end_point := points[(index + 1) % points.size()]
		var edge_vector := end_point - start_point
		if edge_vector.length_squared() <= 0.0001:
			continue
		var inward_normal := Vector2(-edge_vector.y, edge_vector.x).normalized() * winding
		if reverse_arc:
			inward_normal = -inward_normal
		var control_point := (start_point + end_point) * 0.5 + inward_normal * edge_vector.length() * 0.5 * rounding_factor
		for step_index in range(7):
			if index > 0 and step_index == 0:
				continue
			var curve_t := float(step_index) / 6.0
			var inverse_t := 1.0 - curve_t
			result.append(start_point * inverse_t * inverse_t + control_point * 2.0 * inverse_t * curve_t + end_point * curve_t * curve_t)
	if result.size() > 1 and result[0].is_equal_approx(result[result.size() - 1]):
		result.remove_at(result.size() - 1)
	return result
