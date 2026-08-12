extends Node
#重要函数
# is_point_in_water 判断一个point有没有在积水里面
# bind_viewport_follower 让一个node跟随视口移动，原point在top_left角
#add_footstep_ripple 在积水中添加一个脚步波纹
#重要变量
#reflection_skew_degrees 控制所有倒影的倾斜度
#reflection_stretch 控制所有倒影的纵向拉伸

var debug := false
## PuddleReflection使用的全局倾斜角度，单位为度。
var reflection_skew_degrees:=0.0:
	set(v):
		v=clampf(v,-45.0,45.0)
		if reflection_skew_degrees==v:
			return
		reflection_skew_degrees=v
		reflection_skew_degrees_change.emit(v)
signal reflection_skew_degrees_change(v)
## PuddleReflection的纵向拉伸倍率。
var reflection_stretch:=1.0:
	set(v):
		v=clampf(v,0.5,2.0)
		if reflection_stretch==v:
			return
		reflection_stretch=v
		reflection_stretch_change.emit(v)
signal reflection_stretch_change(v)



# main_viewport默认画布层掩码。
const ALL_CANVAS_LAYERS := 0xFFFFFFFF
# Shader 中脚步涟漪数组的固定槽位数量。
const MAX_FOOTSTEP_RIPPLES := 16
# 倒影视口使用的 CanvasItem 图层编号。
const REFLECTION_LAYER: int = 20
# 遮罩在后台GENERATE时保留更多 CPU 给主线程。4 线程虽然单次计算更快，
# 但移动触发重建时容易造成帧时间尖峰；2 线程通常更平稳。
const MAX_MASK_WORKERS := 4
# 空间哈希cell边长，单位为world_position。应略大于常用mask_rect。
const PUDDLE_REGION_GRID_SIZE := 1024.0

var _PuddleCanvas: Node
var _viewport_followers: Array = []
var _PuddleSurface: Array = []
var _main_viewport: Viewport
var _reflection_viewport: SubViewport
var _reflection_texture: ViewportTexture
var _original_main_viewport_mask := ALL_CANVAS_LAYERS
var _main_viewport_mask_saved := false
var _reflection_layer_mask := 1 << (REFLECTION_LAYER - 1)
var _mask_generation_thread: Thread
var _generating_world_rect := Rect2()
var _generating_mask_version := -1
var _pending_generation_node: Node
var _pending_visible_rect := Rect2()
var _has_pending_generation := false
var _footstep_ripple_positions := PackedVector2Array()
var _footstep_ripple_start_times := PackedFloat32Array()
var _next_footstep_ripple_slot := 0
var _has_active_footstep_ripples := false
var _footstep_clear_state_uploaded := true
var _last_shader_viewport_size := Vector2(-1.0, -1.0)
var _last_shader_canvas_transform := Transform2D()
var _has_shader_canvas_state := false
var _native_mask_builder: Object
var _is_exiting := false
var _generation_regions: Dictionary = {}
var _exclusion_regions: Dictionary = {}
var _generation_spatial_grid: Dictionary = {}
var _exclusion_spatial_grid: Dictionary = {}
var _region_grid_cells: Dictionary = {}
var _spatial_index_version := 0
var _candidate_cache_grid_rect := Rect2i()
var _candidate_cache_spatial_version := -1
var _cached_generation_candidates: Dictionary = {}
var _cached_exclusion_candidates: Dictionary = {}
var _region_mask_refresh_queued := false

func _ready() -> void:
	if ClassDB.class_exists(&"PuddleMaskBuilder"):
		_native_mask_builder = ClassDB.instantiate(&"PuddleMaskBuilder")
	else:
		push_warning("PuddleMaskBuilder was not detected. Falling back to GDScript; high resolutions or many regions may be slower.")
	_footstep_ripple_positions.resize(MAX_FOOTSTEP_RIPPLES)
	_footstep_ripple_start_times.resize(MAX_FOOTSTEP_RIPPLES)
	for index in range(MAX_FOOTSTEP_RIPPLES):
		_footstep_ripple_start_times[index] = -1000.0
	RenderingServer.frame_pre_draw.connect(_before_frame_sync)

func _exit_tree() -> void:
	_is_exiting = true
	if RenderingServer.frame_pre_draw.is_connected(_before_frame_sync):
		RenderingServer.frame_pre_draw.disconnect(_before_frame_sync)
	if _mask_generation_thread != null:
		_mask_generation_thread.wait_to_finish()
	_destroy_reflection_viewport()

func _before_frame_sync() -> void:
	if _is_exiting:
		return
	sync_main_viewport()
	_apply_completed_mask()

func register_puddle_canvas(node: Node) -> void:
	# 注册唯一的PuddleCanvas，并创建/绑定倒影视口。
	if not is_instance_valid(node):
		return
	if _PuddleCanvas == node:
		return
	if is_instance_valid(_PuddleCanvas):
		push_warning("PuddleManager supports one PuddleCanvas at a time. The additional canvas was rejected.")
		return
	_PuddleCanvas = node
	_has_shader_canvas_state = false
	_has_active_footstep_ripples = false
	_footstep_clear_state_uploaded = true
	bind_viewport_follower(node)
	_ensure_reflection_viewport(node)
	node.call("_manager_set_reflection_texture", _reflection_texture)
	call_deferred("sync_main_viewport")

func unregister_puddle_canvas(node: Node) -> void:
	# 移除当前PuddleCanvas并释放manager创建的倒影视口。
	if _PuddleCanvas != node:
		return
	_PuddleCanvas = null
	_has_shader_canvas_state = false
	_has_active_footstep_ripples = false
	_footstep_clear_state_uploaded = true
	_pending_generation_node = null
	_pending_visible_rect = Rect2()
	_has_pending_generation = false
	unbind_viewport_follower(node)
	_destroy_reflection_viewport()

func register_puddle_region(region: PuddleRegion) -> void:
	if not is_instance_valid(region):
		return
	var instance_id := region.get_instance_id()
	if region.get_region_type() == PuddleRegion.RegionType.GENERATE:
		_generation_regions[instance_id] = region
	else:
		_exclusion_regions[instance_id] = region
	_update_region_spatial_grid(region, Rect2(), region.get_world_bounds())
	_refresh_mask_for_changed_bounds(Rect2(), region.get_world_bounds())

func unregister_puddle_region(region: PuddleRegion, old_bounds: Rect2) -> void:
	if region != null:
		var instance_id := region.get_instance_id()
		_generation_regions.erase(instance_id)
		_exclusion_regions.erase(instance_id)
		_remove_region_from_spatial_grid(instance_id)
	_refresh_mask_for_changed_bounds(old_bounds, Rect2())

func update_puddle_region_type(region: PuddleRegion, old_type: int, new_type: int) -> void:
	if not is_instance_valid(region) or old_type == new_type:
		return
	var instance_id := region.get_instance_id()
	if old_type == PuddleRegion.RegionType.GENERATE:
		_generation_regions.erase(instance_id)
	else:
		_exclusion_regions.erase(instance_id)
	if new_type == PuddleRegion.RegionType.GENERATE:
		_generation_regions[instance_id] = region
	else:
		_exclusion_regions[instance_id] = region
	var bounds := region.get_world_bounds()
	_update_region_spatial_grid(region, bounds, bounds)
	_refresh_mask_for_changed_bounds(bounds, bounds)

func update_puddle_region(_region: PuddleRegion, old_bounds: Rect2, new_bounds: Rect2) -> void:
	if is_instance_valid(_region):
		_update_region_spatial_grid(_region, old_bounds, new_bounds)
	_refresh_mask_for_changed_bounds(old_bounds, new_bounds)

func _get_region_grid_rect(bounds: Rect2) -> Rect2i:
	if not bounds.has_area():
		return Rect2i()
	var end_position := bounds.position + bounds.size
	var min_cell := Vector2i(
		floori(bounds.position.x / PUDDLE_REGION_GRID_SIZE),
		floori(bounds.position.y / PUDDLE_REGION_GRID_SIZE)
	)
	var max_cell := Vector2i(
		floori((end_position.x - 0.001) / PUDDLE_REGION_GRID_SIZE),
		floori((end_position.y - 0.001) / PUDDLE_REGION_GRID_SIZE)
	)
	return Rect2i(min_cell, max_cell - min_cell + Vector2i.ONE)

func _update_region_spatial_grid(region: PuddleRegion, old_bounds: Rect2, new_bounds: Rect2) -> void:
	var instance_id := region.get_instance_id()
	_remove_region_from_spatial_grid(instance_id)
	var grid_rect := _get_region_grid_rect(new_bounds)
	if grid_rect.size == Vector2i.ZERO:
		return
	var target_grid := _generation_spatial_grid if region.get_region_type() == PuddleRegion.RegionType.GENERATE else _exclusion_spatial_grid
	var cell_list: Array[Vector2i] = []
	for grid_y in range(grid_rect.position.y, grid_rect.end.y):
		for grid_x in range(grid_rect.position.x, grid_rect.end.x):
			var cell := Vector2i(grid_x, grid_y)
			var cell_regions: Dictionary = target_grid.get(cell, {})
			cell_regions[instance_id] = true
			target_grid[cell] = cell_regions
			cell_list.append(cell)
	_region_grid_cells[instance_id] = cell_list
	_spatial_index_version += 1

func _remove_region_from_spatial_grid(instance_id: int) -> void:
	var cell_list: Array = _region_grid_cells.get(instance_id, [])
	if cell_list.is_empty():
		return
	for cell in cell_list:
		_remove_from_spatial_grid_cell(_generation_spatial_grid, cell, instance_id)
		_remove_from_spatial_grid_cell(_exclusion_spatial_grid, cell, instance_id)
	_region_grid_cells.erase(instance_id)
	_spatial_index_version += 1

func _remove_from_spatial_grid_cell(spatial_grid: Dictionary, cell: Vector2i, instance_id: int) -> void:
	if not spatial_grid.has(cell):
		return
	var cell_regions: Dictionary = spatial_grid[cell]
	cell_regions.erase(instance_id)
	if cell_regions.is_empty():
		spatial_grid.erase(cell)
	else:
		spatial_grid[cell] = cell_regions

func _query_region_instances(rect: Rect2) -> Dictionary:
	var grid_rect := _get_region_grid_rect(rect)
	if grid_rect.size == Vector2i.ZERO:
		return {"generation": {}, "exclusion": {}}
	if _candidate_cache_spatial_version == _spatial_index_version and _candidate_cache_grid_rect == grid_rect:
		return {
			"generation": _cached_generation_candidates,
			"exclusion": _cached_exclusion_candidates,
		}
	var generation_result := {}
	var exclusion_result := {}
	for grid_y in range(grid_rect.position.y, grid_rect.end.y):
		for grid_x in range(grid_rect.position.x, grid_rect.end.x):
			var cell := Vector2i(grid_x, grid_y)
			if _generation_spatial_grid.has(cell):
				for instance_id in _generation_spatial_grid[cell]:
					generation_result[instance_id] = true
			if _exclusion_spatial_grid.has(cell):
				for instance_id in _exclusion_spatial_grid[cell]:
					exclusion_result[instance_id] = true
	_candidate_cache_grid_rect = grid_rect
	_candidate_cache_spatial_version = _spatial_index_version
	_cached_generation_candidates = generation_result
	_cached_exclusion_candidates = exclusion_result
	return {"generation": generation_result, "exclusion": exclusion_result}

func _refresh_mask_for_changed_bounds(old_bounds: Rect2, new_bounds: Rect2) -> void:
	if not is_instance_valid(_PuddleCanvas):
		return
	var current_mask_rect: Rect2 = _PuddleCanvas.get("mask_world_rect")
	# 首张遮罩由register_puddle_canvas时的延迟同步统一GENERATE。此时所有同场景region
	# 已完成注册，不需要每个region再额外排队一次失效请求。
	if current_mask_rect.size == Vector2.ZERO:
		return
	if current_mask_rect.intersects(old_bounds) or current_mask_rect.intersects(new_bounds):
		if not _region_mask_refresh_queued:
			_region_mask_refresh_queued = true
			call_deferred("_execute_region_mask_refresh")

func _execute_region_mask_refresh() -> void:
	_region_mask_refresh_queued = false
	if is_instance_valid(_PuddleCanvas):
		_PuddleCanvas.call("_invalidate_mask")

func bind_viewport_follower(node: Node) -> void:
	# 让 Node2D 按main_viewportcanvas_transform跟随摄像机。
	if is_instance_valid(node) and not _viewport_followers.has(node):
		_viewport_followers.append(node)
		var exit_callback := _on_viewport_follower_exited.bind(node)
		if not node.tree_exiting.is_connected(exit_callback):
			node.tree_exiting.connect(exit_callback, CONNECT_ONE_SHOT)
		_sync_registered_node_position(node)

func unbind_viewport_follower(node: Node) -> void:
	# 取消node的main_viewport同步。
	_viewport_followers.erase(node)
	if is_instance_valid(node):
		var exit_callback := _on_viewport_follower_exited.bind(node)
		if node.tree_exiting.is_connected(exit_callback):
			node.tree_exiting.disconnect(exit_callback)

func _on_viewport_follower_exited(node: Node) -> void:
	_viewport_followers.erase(node)

func register_puddle_surface(node: Node) -> void:
	if not is_instance_valid(node) or _PuddleSurface.has(node):
		return
	_PuddleSurface.append(node)
	_set_surface_reflection_texture(node)

func unregister_puddle_surface(node: Node) -> void:
	_PuddleSurface.erase(node)

func get_reflection_texture() -> ViewportTexture:
	# 获取manager当前创建的倒影视口纹理。
	return _reflection_texture
## 根据当前动态遮罩判断world_position是否位于积水内。
func is_point_in_water(world_position: Vector2) -> bool:
	
	if not is_instance_valid(_PuddleCanvas):
		return false
	var image := _PuddleCanvas.get("puddle_mask_image") as Image
	var world_rect: Rect2 = _PuddleCanvas.get("mask_world_rect")
	if image == null or world_rect.size.x <= 0.0 or world_rect.size.y <= 0.0:
		return false
	var mask_uv := (world_position - world_rect.position) / world_rect.size
	if mask_uv.x < 0.0 or mask_uv.x >= 1.0 or mask_uv.y < 0.0 or mask_uv.y >= 1.0:
		return false
	var pixel := Vector2i(
		clampi(int(mask_uv.x * image.get_width()), 0, image.get_width() - 1),
		clampi(int(mask_uv.y * image.get_height()), 0, image.get_height() - 1)
	)
	return image.get_pixelv(pixel).r >= 0.5

func add_footstep_ripple(world_position: Vector2) -> void:
	# 在积水中添加一个脚步波纹，最多同时维护MAX_FOOTSTEP_RIPPLES个。
	if not is_point_in_water(world_position):
		return
	_footstep_ripple_positions[_next_footstep_ripple_slot] = world_position
	_footstep_ripple_start_times[_next_footstep_ripple_slot] = Time.get_ticks_msec() / 1000.0
	_next_footstep_ripple_slot = (_next_footstep_ripple_slot + 1) % MAX_FOOTSTEP_RIPPLES
	_has_active_footstep_ripples = true
	_footstep_clear_state_uploaded = false

func _update_footstep_ripples() -> void:
	if not _has_active_footstep_ripples and _footstep_clear_state_uploaded:
		return
	if not is_instance_valid(_PuddleCanvas):
		return
	var material := _PuddleCanvas.get("puddle_material") as ShaderMaterial
	if material == null:
		return
	var current_time := Time.get_ticks_msec() / 1000.0
	var duration := float(_PuddleCanvas.get("footstep_ripple_duration"))
	var data := PackedVector4Array()
	data.resize(MAX_FOOTSTEP_RIPPLES)
	var active_count := 0
	for index in range(MAX_FOOTSTEP_RIPPLES):
		var elapsed_time := current_time - _footstep_ripple_start_times[index]
		var enabled := 1.0 if elapsed_time <= duration else 0.0
		if enabled > 0.0:
			active_count += 1
		var position := _footstep_ripple_positions[index]
		data[index] = Vector4(position.x, position.y, elapsed_time, enabled)
	material.set_shader_parameter("footstep_ripples", data)
	_has_active_footstep_ripples = active_count > 0
	_footstep_clear_state_uploaded = active_count == 0

func sync_main_viewport() -> void:
	if not is_instance_valid(_PuddleCanvas):
		_PuddleCanvas = null
		return
	var reference_node := _PuddleCanvas
	_main_viewport = reference_node.get_viewport()
	if _main_viewport == null:
		return
	_ensure_reflection_viewport(reference_node)
	_reflection_layer_mask = 1 << (REFLECTION_LAYER - 1)
	if not Engine.is_editor_hint():
		if not _main_viewport_mask_saved:
			_original_main_viewport_mask = _main_viewport.canvas_cull_mask
			_main_viewport_mask_saved = true
		_main_viewport.canvas_cull_mask = _original_main_viewport_mask & ~_reflection_layer_mask
	_reflection_viewport.canvas_cull_mask = _reflection_layer_mask
	var visible_size := Vector2i(_main_viewport.get_visible_rect().size)
	if visible_size.x <= 0 or visible_size.y <= 0:
		return
	_reflection_viewport.size = visible_size
	_reflection_viewport.canvas_transform = _main_viewport.get_canvas_transform()
	for node in _viewport_followers:
		_sync_registered_node_position(node)
	sync_puddle_canvas(_PuddleCanvas)
	_update_footstep_ripples()

func _sync_registered_node_position(node: Node) -> void:
	if not is_instance_valid(node) or not node is Node2D:
		return
	var node_viewport := node.get_viewport()
	if node_viewport != null:
		(node as Node2D).global_transform = node_viewport.get_canvas_transform().affine_inverse()

func sync_puddle_canvas(node: Node) -> void:
	if not is_instance_valid(node) or not node.is_visible_in_tree():
		return
	var material := node.get("puddle_material") as ShaderMaterial
	if material == null:
		return
	var main_viewport := node.get_viewport()
	var viewport_size := main_viewport.get_visible_rect().size
	var canvas_transform := main_viewport.get_canvas_transform()
	var screen_to_world := canvas_transform.affine_inverse()
	var world_origin := screen_to_world * Vector2.ZERO
	if not _has_shader_canvas_state or viewport_size != _last_shader_viewport_size or canvas_transform != _last_shader_canvas_transform:
		material.set_shader_parameter("viewport_size", viewport_size)
		material.set_shader_parameter("world_origin", world_origin)
		material.set_shader_parameter("world_step_x", screen_to_world * Vector2.RIGHT - world_origin)
		material.set_shader_parameter("world_step_y", screen_to_world * Vector2.DOWN - world_origin)
		_last_shader_viewport_size = viewport_size
		_last_shader_canvas_transform = canvas_transform
		_has_shader_canvas_state = true
	var visible_world_rect := _get_visible_world_rect(screen_to_world, viewport_size)
	if not _mask_contains_rect(node, visible_world_rect):
		request_mask_generation(node, visible_world_rect)

func _get_visible_world_rect(screen_to_world: Transform2D, viewport_size: Vector2) -> Rect2:
	var top_left := screen_to_world * Vector2.ZERO
	var top_right := screen_to_world * Vector2(viewport_size.x, 0.0)
	var bottom_left := screen_to_world * Vector2(0.0, viewport_size.y)
	var bottom_right := screen_to_world * viewport_size
	var minimum_position := Vector2(
		min(top_left.x, top_right.x, bottom_left.x, bottom_right.x),
		min(top_left.y, top_right.y, bottom_left.y, bottom_right.y)
	)
	var maximum_position := Vector2(
		max(top_left.x, top_right.x, bottom_left.x, bottom_right.x),
		max(top_left.y, top_right.y, bottom_left.y, bottom_right.y)
	)
	return Rect2(minimum_position, maximum_position - minimum_position)

func _mask_contains_rect(node: Node, visible_rect: Rect2) -> bool:
	if int(node.get("_uploaded_mask_version")) != int(node.get("_mask_parameter_version")):
		return false
	var mask_texture := node.get("puddle_mask_texture")
	var mask_rect: Rect2 = node.get("mask_world_rect")
	if mask_texture == null:
		return false
	# 不等visible_rect越过遮罩边缘才刷新。提前在剩余一半buffer时GENERATE新遮罩，
	# 异步GENERATE期间继续使用仍覆盖整个屏幕的旧遮罩，避免边缘空白闪烁。
	var early_refresh_buffer := _get_mask_buffer(node, visible_rect.size) * 0.5
	var refresh_rect := Rect2(
		visible_rect.position - early_refresh_buffer,
		visible_rect.size + early_refresh_buffer * 2.0
	)
	return mask_rect.encloses(refresh_rect)

func _get_mask_buffer(node: Node, visible_size: Vector2) -> Vector2:
	var buffer_ratio := maxf(float(node.get("mask_buffer_ratio")), 0.0)
	var fixed_buffer := Vector2(256.0, 256.0)
	return Vector2(
		visible_size.x * buffer_ratio + fixed_buffer.x,
		visible_size.y * buffer_ratio + fixed_buffer.y
	)

func request_mask_generation(node: Node, visible_rect: Rect2) -> void:
	if _mask_generation_thread != null:
		var current_version := int(node.get("_mask_parameter_version"))
		if _pending_generation_node == node and _generating_mask_version == current_version and _generating_world_rect.encloses(visible_rect):
			return
		_pending_generation_node = node
		_pending_visible_rect = visible_rect
		_has_pending_generation = true
		return
	# fixed_buffer和比例buffer同时生效；每一侧都额外增加固定世界单位，
	# 再叠加当前visible_rect对应的比例buffer。
	var buffer := _get_mask_buffer(node, visible_rect.size)
	var world_rect := Rect2(visible_rect.position - buffer, visible_rect.size + buffer * 2.0)
	# 将遮罩原point固定到世界pixel网格。相机移动触发重建时，新旧遮罩的
	# 重叠部分仍采样完全相同的world_position，避免轮廓因亚pixel相位变化而闪动。
	var resolution := maxi(1, int(node.get("mask_resolution")))
	var mask_pixel_world_size := world_rect.size / float(resolution)
	world_rect.position = Vector2(
		floorf(world_rect.position.x / mask_pixel_world_size.x) * mask_pixel_world_size.x,
		floorf(world_rect.position.y / mask_pixel_world_size.y) * mask_pixel_world_size.y
	)
	_generating_world_rect = world_rect
	_generating_mask_version = int(node.get("_mask_parameter_version"))
	_pending_generation_node = node
	var gds_prepare_start := Time.get_ticks_usec()
	var enable_global_noise := bool(node.get("enable_global_noise_puddles"))
	var limit_global_noise := bool(node.get("limit_global_noise_range"))
	var global_noise_rect := _get_global_noise_rect(node)
	var has_global_noise_in_rect := enable_global_noise and (not limit_global_noise or world_rect.intersects(global_noise_rect))
	var enabledGENERATEregion := bool(node.get("enable_generation_regions")) and float(node.get("dryness")) < 0.999
	var enabledEXCLUDEregion := bool(node.get("enable_exclusion_regions"))
	var region_result := _collect_registered_regions(
		enabledGENERATEregion,
		enabledEXCLUDEregion,
		float(node.get("generation_rounding_percent")),
		float(node.get("exclusion_rounding_percent")),
		has_global_noise_in_rect
	) if enabledGENERATEregion or (enabledEXCLUDEregion and has_global_noise_in_rect) else {
		"generation": [],
		"exclusion": [],
	}
	var generation_polygons: Array = region_result.generation
	var has_generation_regions := not generation_polygons.is_empty()
	var has_water_sources := has_global_noise_in_rect or has_generation_regions
	var exclusion_polygons: Array = region_result.exclusion if has_water_sources else []
	var noise: FastNoiseLite = null
	if has_global_noise_in_rect:
		noise = node.get("puddle_noise") as FastNoiseLite
		if noise == null:
			noise = FastNoiseLite.new()
		noise = noise.duplicate(true)
	var data := {
		"world_rect": world_rect,
		"resolution": resolution,
		"edge_smoothing_radius": int(node.get("mask_edge_smoothing_radius")),
		"puddle_size": float(node.get("puddle_size")),
		"threshold": _get_puddle_threshold(node),
		"dryness": float(node.get("dryness")),
		"edge_softness": float(node.get("puddle_edge_softness")),
		"noise": noise,
		"excluded_water_polygons": exclusion_polygons,
		"generation_polygons": generation_polygons,
		"force_generation_polygons": has_generation_regions,
		"enable_global_noise": has_global_noise_in_rect,
		"limit_global_noise": limit_global_noise,
		"global_noise_rect": global_noise_rect,
		"has_water_sources": has_water_sources,
		"generation_edge_softness": float(node.get("puddle_edge_softness")) * float(node.get("puddle_size")),
		"version": int(node.get("_mask_parameter_version")),
		"node_id": node.get_instance_id(),
	}
	data["gds_prepare_ms"] = float(Time.get_ticks_usec() - gds_prepare_start) / 1000.0
	# 首张遮罩和后续刷新统一在后台GENERATE。PuddleCanvas在result完成前持续使用
	# 1x1 黑色安全遮罩，既不会阻塞首帧，也不会出现低精度替换闪烁。
	_mask_generation_thread = Thread.new()
	var start_error := _mask_generation_thread.start(_build_puddle_mask.bind(data))
	if start_error != OK:
		push_error("积水遮罩后台线程启动失败，错误码：%d" % start_error)
		_mask_generation_thread = null
		_generating_world_rect = Rect2()
		_generating_mask_version = -1

func _get_puddle_threshold(node: Node) -> float:
	return lerpf(0.55, -0.45, float(node.get("puddle_amount")))

func _get_global_noise_rect(node: Node) -> Rect2:
	var left := float(node.get("global_noise_left"))
	var top := float(node.get("global_noise_top"))
	var right := maxf(float(node.get("global_noise_right")), left)
	var bottom := maxf(float(node.get("global_noise_bottom")), top)
	return Rect2(Vector2(left, top), Vector2(right - left, bottom - top))

func _collect_registered_regions(collect_generation: bool, collect_exclusion: bool, GENERATErounding_percent: float, EXCLUDErounding_percent: float, has_global_water_source: bool) -> Dictionary:
	var generation_result: Array = []
	var exclusion_candidate_nodes: Array[PuddleRegion] = []
	var current_scene := get_tree().current_scene
	var invalid_generation_regions: Array[int] = []
	var invalid_exclusion_regions: Array[int] = []
	var candidate_result := _query_region_instances(_generating_world_rect)
	var generation_candidates: Dictionary = candidate_result.generation
	var exclusion_candidates: Dictionary = candidate_result.exclusion
	if collect_generation:
		for instance_id in generation_candidates:
			var region := _generation_regions.get(instance_id) as PuddleRegion
			if region == null:
				continue
			if not is_instance_valid(region):
				invalid_generation_regions.append(instance_id)
				continue
			if current_scene != null and not current_scene.is_ancestor_of(region):
				continue
			if _generating_world_rect.intersects(region.get_world_bounds()):
				generation_result.append(region.get_world_polygon(GENERATErounding_percent))
	if collect_exclusion:
		for instance_id in exclusion_candidates:
			var region := _exclusion_regions.get(instance_id) as PuddleRegion
			if region == null:
				continue
			if not is_instance_valid(region):
				invalid_exclusion_regions.append(instance_id)
				continue
			if current_scene != null and not current_scene.is_ancestor_of(region):
				continue
			if _generating_world_rect.intersects(region.get_world_bounds()):
				exclusion_candidate_nodes.append(region)
	for instance_id in invalid_generation_regions:
		_generation_regions.erase(instance_id)
		_remove_region_from_spatial_grid(instance_id)
	for instance_id in invalid_exclusion_regions:
		_exclusion_regions.erase(instance_id)
		_remove_region_from_spatial_grid(instance_id)
	var exclusion_result: Array = []
	if has_global_water_source or not generation_result.is_empty():
		for region in exclusion_candidate_nodes:
			exclusion_result.append(region.get_world_polygon(EXCLUDErounding_percent))
	return {"generation": generation_result, "exclusion": exclusion_result}

func _build_puddle_mask(data: Dictionary) -> Dictionary:
	var timer_start := Time.get_ticks_usec()
	if not bool(data.get("has_water_sources", true)):
		var empty_image := Image.create(1, 1, false, Image.FORMAT_R8)
		empty_image.fill(Color.BLACK)
		if debug:
			var empty_elapsed_ms := float(Time.get_ticks_usec() - timer_start) / 1000.0
			print_debug("积水遮罩：当前rect无水源，直接返回 1x1 空遮罩，总计 %.3f ms" % empty_elapsed_ms)
		return {"image": empty_image, "world_rect": data.world_rect, "version": data.version, "node_id": data.node_id}
	var resolution := int(data.resolution)
	var edge_smoothing_radius := maxi(0, int(data.get("edge_smoothing_radius", 0)))
	if is_instance_valid(_native_mask_builder):
		var native_result: Variant = _native_mask_builder.call(
			&"build_mask",
			data,
			maxi(1, MAX_MASK_WORKERS)
		)
		if native_result is Dictionary and not native_result.is_empty():
			var elapsed_ms := float(Time.get_ticks_usec() - timer_start) / 1000.0
			var actual_worker_count := int(native_result.get("worker_count", 1))
			if debug:
				print_debug("积水遮罩：GDS预处理 %.3f ms；C++ %dx%d，GENERATE区 %d / EXCLUDE区 %d，请求 %d / 实际 %d 线程，准备 %.2f，基础 %.2f，平滑(%d px) %.2f，建图 %.2f，调用总计 %.2f ms" % [
					float(data.get("gds_prepare_ms", 0.0)), resolution, resolution, int(native_result.get("generation_polygon_count", 0)), int(native_result.get("exclusion_polygon_count", 0)), maxi(1, MAX_MASK_WORKERS), actual_worker_count,
					float(native_result.get("setup_ms", 0.0)), float(native_result.get("mask_ms", 0.0)),
					edge_smoothing_radius, float(native_result.get("smoothing_ms", 0.0)),
					float(native_result.get("image_ms", 0.0)), elapsed_ms
				])
			return native_result
	var fallback_result := _build_puddle_mask_gdscript(data)
	var fallback_elapsed_ms := float(Time.get_ticks_usec() - timer_start) / 1000.0
	if debug:print_debug("积水遮罩 GDScript：%dx%d，%d 线程，总计 %.2f ms" % [resolution, resolution, maxi(1, MAX_MASK_WORKERS), fallback_elapsed_ms])
	return fallback_result

func _build_puddle_mask_gdscript(data: Dictionary) -> Dictionary:
	var world_rect: Rect2 = data.world_rect
	var resolution: int = data.resolution
	var task_count := mini(
		maxi(1, MAX_MASK_WORKERS),
		maxi(1, OS.get_processor_count() - 1)
	)
	var rows_per_task := ceili(float(resolution) / float(task_count))
	var chunks := []
	for task_index in range(task_count):
		var start_row := task_index * rows_per_task
		var end_row := mini(start_row + rows_per_task, resolution)
		if start_row >= end_row:
			continue
		chunks.append({"start": start_row, "end": end_row, "bytes": PackedByteArray()})
	var group_task := WorkerThreadPool.add_group_task(_calculate_mask_chunk.bind(data, chunks, world_rect, resolution), chunks.size())
	WorkerThreadPool.wait_for_group_task_completion(group_task)
	var pixeldata := PackedByteArray()
	pixeldata.resize(resolution * resolution)
	var offset := 0
	for chunk in chunks:
		var datachunk: PackedByteArray = chunk.bytes
		for value in datachunk:
			pixeldata[offset] = value
			offset += 1
	var smoothing_radius := clampi(int(data.get("edge_smoothing_radius", 0)), 0, 8)
	if smoothing_radius > 0:
		pixeldata = _smooth_mask_coverage(pixeldata, resolution, smoothing_radius)
	var image := Image.create_from_data(resolution, resolution, false, Image.FORMAT_R8, pixeldata)
	return {"image": image, "world_rect": world_rect, "version": data.version, "node_id": data.node_id}

func _smooth_mask_coverage(source_pixels: PackedByteArray, resolution: int, radius: int) -> PackedByteArray:
	var weight_sum := float((radius + 1) * (radius + 1))
	var horizontal := PackedFloat32Array()
	horizontal.resize(source_pixels.size())
	for y in range(resolution):
		for x in range(resolution):
			var total := 0.0
			for offset in range(-radius, radius + 1):
				var sample_x := clampi(x + offset, 0, resolution - 1)
				total += float(source_pixels[y * resolution + sample_x]) / 255.0 * float(radius + 1 - absi(offset))
			horizontal[y * resolution + x] = total / weight_sum
	var result := PackedByteArray()
	result.resize(source_pixels.size())
	for y in range(resolution):
		for x in range(resolution):
			var total := 0.0
			for offset in range(-radius, radius + 1):
				var sample_y := clampi(y + offset, 0, resolution - 1)
				total += horizontal[sample_y * resolution + x] * float(radius + 1 - absi(offset))
			result[y * resolution + x] = roundi(clampf(total / weight_sum, 0.0, 1.0) * 255.0)
	return result

func _calculate_mask_chunk(index: int, data: Dictionary, chunks: Array, world_rect: Rect2, resolution: int) -> void:
	var chunk: Dictionary = chunks[index]
	var start_row: int = chunk.start
	var end_row: int = chunk.end
	var width := resolution
	var output := PackedByteArray()
	output.resize((end_row - start_row) * width)
	var noise: FastNoiseLite = null
	if bool(data.enable_global_noise):
		var source_noise := data.noise as FastNoiseLite
		noise = source_noise.duplicate(true) if source_noise != null else FastNoiseLite.new()
	var puddle_size: float = data.puddle_size
	var softness: float = data.edge_softness
	var dryness: float = data.dryness
	var EXCLUDEsoftness := softness * puddle_size
	var mask_pixel_world_size := maxf(world_rect.size.x, world_rect.size.y) / float(resolution)
	EXCLUDEsoftness = maxf(EXCLUDEsoftness, mask_pixel_world_size * 1.5)
	var global_threshold := lerpf(data.threshold, 1.0 + softness, dryness)
	var erosion_distance := dryness * puddle_size
	var noise_min_x := 0
	var noise_max_x := resolution
	var noise_min_y := 0
	var noise_max_y := resolution
	var noise_overlaps_mask: bool = bool(data.enable_global_noise) and noise != null
	if data.enable_global_noise and data.limit_global_noise:
		var overlap_rect := world_rect.intersection(data.global_noise_rect)
		noise_overlaps_mask = overlap_rect.has_area()
		if noise_overlaps_mask:
			var pixel_size := world_rect.size / float(resolution)
			noise_min_x = clampi(ceili((overlap_rect.position.x - world_rect.position.x) / pixel_size.x - 0.5), 0, resolution)
			noise_max_x = clampi(ceili((overlap_rect.end.x - world_rect.position.x) / pixel_size.x - 0.5), 0, resolution)
			noise_min_y = clampi(ceili((overlap_rect.position.y - world_rect.position.y) / pixel_size.y - 0.5), 0, resolution)
			noise_max_y = clampi(ceili((overlap_rect.end.y - world_rect.position.y) / pixel_size.y - 0.5), 0, resolution)
	for y in range(start_row, end_row):
		var sample_noise_for_row := noise_overlaps_mask and y >= noise_min_y and y < noise_max_y
		for x in range(width):
			var position := world_rect.position + Vector2((float(x) + 0.5) / resolution, (float(y) + 0.5) / resolution) * world_rect.size
			var mask_value := 0.0
			if sample_noise_for_row and x >= noise_min_x and x < noise_max_x:
				var noisevalue := noise.get_noise_2d(position.x / puddle_size, position.y / puddle_size)
				mask_value = smoothstep(global_threshold - softness, global_threshold + softness, noisevalue)
			if data.force_generation_polygons and dryness < 0.999:
				for polygon_points: PackedVector2Array in data.generation_polygons:
					mask_value = maxf(mask_value, _polygon_inside_mask(position, polygon_points, data.generation_edge_softness, erosion_distance))
			for polygon_points: PackedVector2Array in data.excluded_water_polygons:
				mask_value *= _polygon_exclusion_mask(position, polygon_points, EXCLUDEsoftness)
			output[(y - start_row) * width + x] = roundi(clampf(mask_value, 0.0, 1.0) * 255.0)
	chunk.bytes = output

func _apply_completed_mask() -> void:
	if _mask_generation_thread == null or _mask_generation_thread.is_alive():
		return
	var collect_start := Time.get_ticks_usec()
	var result: Dictionary = _mask_generation_thread.wait_to_finish()
	var collect_ms := float(Time.get_ticks_usec() - collect_start) / 1000.0
	_mask_generation_thread = null
	_generating_world_rect = Rect2()
	_generating_mask_version = -1
	var node := instance_from_id(int(result.node_id))
	if is_instance_valid(node):
		# 连续调参时不要丢弃旧result；先显示它，再继续GENERATE最新version，
		# 否则每次result完成都会因version变化被丢弃，画面要等松手才更新。
		var upload_start := Time.get_ticks_usec()
		node.call("_manager_upload_mask", result.image, result.world_rect, int(result.version))
		var upload_ms := float(Time.get_ticks_usec() - upload_start) / 1000.0
		if debug and (collect_ms > 2.0 or upload_ms > 2.0):
			print_debug("积水遮罩主线程：回收 %.2f ms，双buffertop传 %.2f ms" % [collect_ms, upload_ms])
	if _has_pending_generation:
		var pending_node := _pending_generation_node
		var pending_rect := _pending_visible_rect
		_has_pending_generation = false
		if is_instance_valid(pending_node) and not _mask_contains_rect(pending_node, pending_rect):
			request_mask_generation(pending_node, pending_rect)

func _polygon_inside_mask(position: Vector2, polygon_points: PackedVector2Array, softness: float, erosion_distance: float) -> float:
	if polygon_points.size() < 3 or not Geometry2D.is_point_in_polygon(position, polygon_points):
		return 0.0
	var minimum_distance := INF
	for index in range(polygon_points.size()):
		var start_point := polygon_points[index]
		var end_point := polygon_points[(index + 1) % polygon_points.size()]
		var closest_point := Geometry2D.get_closest_point_to_segment(position, start_point, end_point)
		minimum_distance = minf(minimum_distance, position.distance_to(closest_point))
	return smoothstep(erosion_distance, erosion_distance + softness, minimum_distance)

func _polygon_exclusion_mask(position: Vector2, polygon_points: PackedVector2Array, softness: float) -> float:
	if polygon_points.size() < 3:
		return 1.0
	var is_inside := Geometry2D.is_point_in_polygon(position, polygon_points)
	if softness <= 0.0:
		return 0.0 if is_inside else 1.0
	var minimum_distance := INF
	for index in range(polygon_points.size()):
		var start_point := polygon_points[index]
		var end_point := polygon_points[(index + 1) % polygon_points.size()]
		var closest_point := Geometry2D.get_closest_point_to_segment(position, start_point, end_point)
		minimum_distance = minf(minimum_distance, position.distance_to(closest_point))
	if is_inside:
		return 0.0
	return smoothstep(0.0, softness, minimum_distance)

func _set_surface_reflection_texture(node: Node) -> void:
	if is_instance_valid(node) and node.has_method("_manager_set_reflection_texture"):
		node.call("_manager_set_reflection_texture", _reflection_texture)

func _ensure_reflection_viewport(reference_node: Node) -> void:
	if _reflection_viewport != null and is_instance_valid(_reflection_viewport):
		return
	_reflection_viewport = SubViewport.new()
	_reflection_viewport.name = "PuddleReflection视口"
	_reflection_viewport.transparent_bg = true
	_reflection_viewport.handle_input_locally = false
	_reflection_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_reflection_viewport.canvas_item_default_texture_filter = Viewport.DEFAULT_CANVAS_ITEM_TEXTURE_FILTER_NEAREST
	_main_viewport = reference_node.get_viewport()
	if _main_viewport != null:
		_reflection_viewport.world_2d = _main_viewport.world_2d
	add_child(_reflection_viewport)
	_reflection_texture = _reflection_viewport.get_texture()
	if is_instance_valid(_PuddleCanvas):
		_PuddleCanvas.call("_manager_set_reflection_texture", _reflection_texture)
	for node in _PuddleSurface:
		if is_instance_valid(node):
			_set_surface_reflection_texture(node)

func _destroy_reflection_viewport() -> void:
	if _main_viewport != null and _main_viewport_mask_saved and is_instance_valid(_main_viewport):
		_main_viewport.canvas_cull_mask = _original_main_viewport_mask
	_main_viewport_mask_saved = false
	if is_instance_valid(_reflection_viewport):
		_reflection_viewport.queue_free()
	_reflection_viewport = null
	_reflection_texture = null
	for node in _PuddleSurface:
		if is_instance_valid(node):
			_set_surface_reflection_texture(node)
