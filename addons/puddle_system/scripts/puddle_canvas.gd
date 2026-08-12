@tool
@icon("res://addons/puddle_system/icon/puddle_canvas.svg")
extends Sprite2D
class_name PuddleCanvas

const PUDDLE_SHADER := preload("res://addons/puddle_system/shader/puddle.gdshader")
const GLOBAL_NOISE_RANGE_PROPERTIES := [
	&"global_noise_left",
	&"global_noise_top",
	&"global_noise_right",
	&"global_noise_bottom",
]

enum GlobalNoiseLimitMode {
	RECTANGLE,
	POLYGON,
}
@export_group("Puddle Settings")
## 控制是否enabled这个node，关闭后将不再显示任何积水，且不进行任何运算
@export var puddles_enabled:=true:
	set(v):
		puddles_enabled=v
		visible=v
## 用于GENERATE世界积水分布的 FastNoiseLite。留空会自动创建默认noise。
@export var puddle_noise: FastNoiseLite
## 干涸程度；0 为完整积水，1 接近完全干涸。
@export_range(0.0, 1.0, 0.01) var dryness := 0.0:
	set(value):
		value = clampf(value, 0.0, 1.0)
		if is_equal_approx(dryness, value):
			return
		dryness = value
		_invalidate_mask()
## noise阈value控制积水密度，数value越大通常积水越多。
@export_range(0.05, 0.95, 0.01) var puddle_amount := 0.38:
	set(value):
		puddle_amount = value
		_invalidate_mask()
## noise采样尺度，数value越大积水斑chunk越大。
@export_range(80.0, 1600.0, 10.0) var puddle_size := 520.0:
	set(value):
		puddle_size = value
		_invalidate_mask()
## 统一控制noise积水、指定GENERATEregion和EXCLUDEregion边缘的渐变width。
@export_range(0.001, 0.25, 0.001) var puddle_edge_softness := 0.045:
	set(value):
		puddle_edge_softness = value
		_invalidate_mask()
## GENERATE遮罩的resolution；越高越精细，但计算量越大。
@export_range(64, 512, 1) var mask_resolution := 256:
	set(value):
		mask_resolution = value
		_invalidate_mask()
## 遮罩边缘覆盖率smoothing_radius；按距离递减采样，Shader 以 0.5 为岸线恢复连续轮廓。0 为关闭。
@export_range(0, 8, 1) var mask_edge_smoothing_radius := 2:
	set(value):
		mask_edge_smoothing_radius = value
		_set_puddle_material_parameter(&"mask_threshold_smoothing", value > 0)
		_invalidate_mask()
## 在visible_rect外额外GENERATE的遮罩边缘比例；每侧还会叠加 256 世界单位fixed_buffer。
@export_range(0.0, 1.0, 0.05) var mask_buffer_ratio := 0.35:
	set(value):
		mask_buffer_ratio = value
		_invalidate_mask()
@export_group("")
@export_group("Generation Range")
@export_subgroup("Global Noise Puddles")
## 是否在全图按noiseGENERATE积水。
@export var enable_global_noise_puddles := true:
	set(value):
		enable_global_noise_puddles = value
		notify_property_list_changed()
		_invalidate_mask()
## Limits global noise puddles to either a rectangle or a Polygon2D.
@export var limit_global_noise_range := false:
	set(value):
		limit_global_noise_range = value
		notify_property_list_changed()
		_invalidate_mask()
## Selects the shape used when global noise limiting is enabled.
@export var global_noise_limit_mode := GlobalNoiseLimitMode.RECTANGLE:
	set(value):
		global_noise_limit_mode = value
		notify_property_list_changed()
		_update_global_noise_polygon_signature()
		_invalidate_mask()
## Polygon2D used as the global noise boundary in POLYGON mode.
@export var global_noise_limit_polygon: Polygon2D:
	set(value):
		global_noise_limit_polygon = value
		_update_global_noise_polygon_signature()
		_invalidate_mask()
## Left world-space boundary used in RECTANGLE mode.
@export var global_noise_left := -10000000:
	set(value):
		global_noise_left = value
		_invalidate_mask()
## Top world-space boundary used in RECTANGLE mode.
@export var global_noise_top := -10000000:
	set(value):
		global_noise_top = value
		_invalidate_mask()
## Right world-space boundary used in RECTANGLE mode.
@export var global_noise_right := 10000000:
	set(value):
		global_noise_right = value
		_invalidate_mask()
## Bottom world-space boundary used in RECTANGLE mode.
@export var global_noise_bottom := 10000000:
	set(value):
		global_noise_bottom = value
		_invalidate_mask()

@export_subgroup("Exclusion Regions")
## 是否enabled类型为“EXCLUDE”的PuddleRegionnode。EXCLUDE优先级高于GENERATE。
@export var enable_exclusion_regions := true:
	set(value):
		enable_exclusion_regions = value
		notify_property_list_changed()
		_invalidate_mask()
## EXCLUDEregion反向曲线比例。贝塞尔端point始终是原polygon_pointspoints；0 为直线，100 为最大反向弯曲。
@export_range(0.0, 100.0, 1.0, "suffix:%") var exclusion_rounding_percent := 100.0:
	set(value):
		exclusion_rounding_percent = value
		_invalidate_mask()

@export_subgroup("Generation Regions")
## 是否enabled类型为“GENERATE”的PuddleRegionnode。
@export var enable_generation_regions := true:
	set(value):
		enable_generation_regions = value
		notify_property_list_changed()
		_invalidate_mask()
## GENERATEregion边界曲线比例。贝塞尔端point始终是原polygon_pointspoints；0 为直线，100 为最大向内弯曲。
@export_range(0.0, 100.0, 1.0, "suffix:%") var generation_rounding_percent := 100.0:
	set(value):
		generation_rounding_percent = value
		_invalidate_mask()

@export_subgroup("")
@export_group("")
@export_group("Water Appearance")
## 水面底色；RGB 为颜色，Alpha 控制底色透明度。
@export var water_color := Color(0.37630722, 0.4856034, 0.69460505, 0.4862745):
	set(value):
		water_color = value
		_set_puddle_material_parameter(&"water_color", value)
## 倒影混入强度；0 为不显示倒影，1 为完全按倒影权重混合。
@export_range(0.0, 1.0, 0.01) var reflection_opacity := 0.6:
	set(value):
		reflection_opacity = value
		_set_puddle_material_parameter(&"reflection_opacity", value)
## 是否显示积水遮罩内侧的边缘高光。
@export var border_enabled := true:
	set(value):
		border_enabled = value
		notify_property_list_changed()
		_set_puddle_material_parameter(&"water_edge_enabled", value)
## 是否让边框周期性向积水外侧扩张并平滑收回。
@export var border_animation_enabled := false:
	set(value):
		border_animation_enabled = value
		notify_property_list_changed()
		_set_puddle_material_parameter(&"water_edge_animation_enabled", value)
## 边框动效的强度，越大向外扩的越远。
@export_range(0.0, 32.0, 0.1) var border_animation_strength := 4.0:
	set(value):
		border_animation_strength = value
		_set_puddle_material_parameter(&"water_edge_animation_strength", value)
## 边框局部闪烁高光强度；数value越大，沿边缘掠过的亮point越明显。
@export_range(0.0, 1.0, 0.01) var border_shimmer_strength := 0.1:
	set(value):
		border_shimmer_strength = value
		_set_puddle_material_parameter(&"water_edge_shimmer_strength", value)
## border_color；Alpha 控制边框覆盖强度。
@export var border_color := Color(1.0, 1.0, 1.0, 0.157):
	set(value):
		border_color = value
		_set_puddle_material_parameter(&"water_edge_color", value)
## 边框向积水内部延伸的width，单位为world_position。
@export_range(0.0, 32.0, 0.5) var border_width := 8.0:
	set(value):
		border_width = value
		_set_puddle_material_parameter(&"water_edge_width", value)
## 边框靠水面内缘的渐变width；类似 StyleBoxFlat 的 blend，0 仅保留pixel抗锯齿。
@export_range(0.0, 32.0, 0.5) var border_blend_width := 4.0:
	set(value):
		border_blend_width = value
		_set_puddle_material_parameter(&"water_edge_blend_width", value)
@export_group("")

@export_group("Wind Waves")
## 是否wind_distortion_enabled高度场。
@export var wind_distortion_enabled := true:
	set(value):
		wind_distortion_enabled = value
		_set_puddle_material_parameter(&"wind_disturbance_enabled", value)
## 风纹传播方向，Shader 内部会自动归一化。
@export var wind_direction := Vector2(1.0, 1.0):
	set(value):
		wind_direction = value
		_set_puddle_material_parameter(&"wind_direction", value)
## 风纹世界尺寸；越大纹理越疏。
@export_range(8.0, 300.0, 1.0) var wind_wave_size := 122.0:
	set(value):
		wind_wave_size = value
		_set_puddle_material_parameter(&"wind_ripple_size", value)
## 风纹移动速度。
@export_range(0.0, 8.0, 0.05) var wind_wave_speed := 2.0:
	set(value):
		wind_wave_speed = value
		_set_puddle_material_parameter(&"wind_speed", value)
## 水面高度差转换为法线坡度的倍率。
@export_range(0.0, 20.0, 0.1) var surface_roughness := 8.0:
	set(value):
		surface_roughness = value
		_set_puddle_material_parameter(&"surface_roughness", value)
## 倒影对水面坡度的响应倍率。
@export_range(0.0, 12.0, 0.1) var reflection_distortion := 3.0:
	set(value):
		reflection_distortion = value
		_set_puddle_material_parameter(&"reflection_response", value)
## wind_highlight_strength。
@export_range(0.0, 0.5, 0.01) var wind_highlight_strength := 0.2:
	set(value):
		wind_highlight_strength = value
		_set_puddle_material_parameter(&"ripple_highlight", value)
@export_group("")

@export_group("Rain Ripples")
## 是否enabled程序化雨滴涟漪。
@export var rain_ripples_enabled := false:
	set(value):
		rain_ripples_enabled = value
		_set_puddle_material_parameter(&"rain_ripples_enabled", value)
## 雨滴落point网格间距，越大雨滴越稀疏。
@export_range(80.0, 400.0, 5.0) var rain_ripple_spacing := 180.0:
	set(value):
		rain_ripple_spacing = value
		_set_puddle_material_parameter(&"rain_ripple_spacing", value)
## 同一落pointGENERATEbottom一次雨滴的时间间隔。
@export_range(0.15, 4.0, 0.05) var rain_ripple_interval := 0.8:
	set(value):
		rain_ripple_interval = value
		_set_puddle_material_parameter(&"rain_ripple_interval", value)
## 雨滴圆环扩散速度。
@export_range(10.0, 180.0, 1.0) var rain_ripple_speed := 55.0:
	set(value):
		rain_ripple_speed = value
		_set_puddle_material_parameter(&"rain_ripple_speed", value)
## 单个雨滴圆环duration。
@export_range(0.1, 3.0, 0.05) var rain_ripple_duration := 1.1:
	set(value):
		rain_ripple_duration = value
		_set_puddle_material_parameter(&"rain_ripple_duration", value)
## 雨滴圆环width。
@export_range(0.5, 16.0, 0.5) var rain_ripple_width := 2.5:
	set(value):
		rain_ripple_width = value
		_set_puddle_material_parameter(&"rain_ripple_width", value)
## 雨滴对水面法线的影响强度。
@export_range(0.0, 4.0, 0.05) var rain_ripple_strength := 0.75:
	set(value):
		rain_ripple_strength = value
		_set_puddle_material_parameter(&"rain_ripple_strength", value)
## 雨滴高光强度。
@export_range(0.0, 1.0, 0.01) var rain_ripple_highlight := 0.3:
	set(value):
		rain_ripple_highlight = value
		_set_puddle_material_parameter(&"rain_ripple_highlight", value)
@export_group("")

@export_group("Footstep Ripples")
## 脚步圆环扩散速度。
@export_range(10.0, 300.0, 1.0) var footstep_ripple_speed := 90.0:
	set(value):
		footstep_ripple_speed = value
		_set_puddle_material_parameter(&"footstep_ripple_speed", value)
## 脚步圆环duration。
@export_range(0.1, 4.0, 0.05) var footstep_ripple_duration := 1.2:
	set(value):
		footstep_ripple_duration = value
		_set_puddle_material_parameter(&"footstep_ripple_duration", value)
## 脚步圆环width。
@export_range(1.0, 30.0, 0.5) var footstep_ripple_width := 4.0:
	set(value):
		footstep_ripple_width = value
		_set_puddle_material_parameter(&"footstep_ripple_width", value)
## 脚步对水面法线的影响强度。
@export_range(0.0, 4.0, 0.05) var footstep_ripple_strength := 1.8:
	set(value):
		footstep_ripple_strength = value
		_set_puddle_material_parameter(&"footstep_ripple_strength", value)
## 脚步圆环高光强度。
@export_range(0.0, 1.0, 0.01) var footstep_ripple_highlight := 0.45:
	set(value):
		footstep_ripple_highlight = value
		_set_puddle_material_parameter(&"footstep_ripple_highlight", value)
@export_group("")

var puddle_material: ShaderMaterial
var puddle_mask_texture: ImageTexture
var _fallback_mask_texture: ImageTexture
var puddle_mask_image: Image
var mask_world_rect := Rect2()
var _uploaded_mask_version := -1
var _mask_parameter_version := 0
# 仅用于读取旧版插件保存到场景中的“白边”字段，新项目检查器只显示“边框”。
var _legacy_border_properties: Dictionary = {}
var _global_noise_polygon_signature := 0

func _set(property: StringName, value: Variant) -> bool:
	if property in [&"puddles_enabled白边", &"积水白边显示倒影", &"puddles_enabled白边动效", &"积水白边动效强度", &"积水白边闪光强度", &"积水白边颜色", &"积水白边width"]:
		_legacy_border_properties[property] = value
		return true
	return false

func _validate_property(property: Dictionary) -> void:
	if property.name == &"limit_global_noise_range" and not enable_global_noise_puddles:
		property.usage = PROPERTY_USAGE_STORAGE
	elif property.name == &"global_noise_limit_mode" and (not enable_global_noise_puddles or not limit_global_noise_range):
		property.usage = PROPERTY_USAGE_STORAGE
	elif property.name == &"global_noise_limit_polygon" and (not enable_global_noise_puddles or not limit_global_noise_range or global_noise_limit_mode != GlobalNoiseLimitMode.POLYGON):
		property.usage = PROPERTY_USAGE_STORAGE
	elif property.name in GLOBAL_NOISE_RANGE_PROPERTIES and (not enable_global_noise_puddles or not limit_global_noise_range or global_noise_limit_mode != GlobalNoiseLimitMode.RECTANGLE):
		property.usage = PROPERTY_USAGE_STORAGE
	elif property.name == &"exclusion_rounding_percent" and not enable_exclusion_regions:
		property.usage = PROPERTY_USAGE_STORAGE
	elif property.name == &"generation_rounding_percent" and not enable_generation_regions:
		property.usage = PROPERTY_USAGE_STORAGE
	elif property.name in [&"border_animation_enabled", &"border_animation_strength", &"border_shimmer_strength", &"border_color", &"border_width", &"border_blend_width"] and not border_enabled:
		property.usage = PROPERTY_USAGE_STORAGE
	elif property.name in [&"border_animation_strength", &"border_shimmer_strength"] and not border_animation_enabled:
		property.usage = PROPERTY_USAGE_STORAGE

func _ready() -> void:
	_migrate_legacy_border_properties()
	_update_global_noise_polygon_signature()
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	if centered:
		centered=false
	puddle_material = material as ShaderMaterial
	if puddle_material == null:
		puddle_material = ShaderMaterial.new()
		puddle_material.shader = PUDDLE_SHADER
		material = puddle_material
	if puddle_noise == null:
		puddle_noise = FastNoiseLite.new()
	puddle_noise.frequency = 1.0
	puddle_noise.fractal_octaves = 2
	_set_empty_mask()
	_sync_all_water_parameters()
	var manager := get_node_or_null("/root/PuddleManager")
	if manager != null and manager.has_method("register_puddle_canvas"):
		manager.register_puddle_canvas(self)
	elif not Engine.is_editor_hint():
		push_warning("PuddleCanvas could not find /root/PuddleManager. Enable the Puddle System plugin or add the Autoload manually.")

func _process(_delta: float) -> void:
	if not limit_global_noise_range or global_noise_limit_mode != GlobalNoiseLimitMode.POLYGON:
		return
	var previous_signature := _global_noise_polygon_signature
	_update_global_noise_polygon_signature()
	if previous_signature != _global_noise_polygon_signature:
		_invalidate_mask()

func _update_global_noise_polygon_signature() -> void:
	if not is_instance_valid(global_noise_limit_polygon):
		_global_noise_polygon_signature = 0
		return
	_global_noise_polygon_signature = hash([
		global_noise_limit_polygon.get_instance_id(),
		global_noise_limit_polygon.polygon,
		global_noise_limit_polygon.global_transform,
	])

func _migrate_legacy_border_properties() -> void:
	if _legacy_border_properties.has(&"puddles_enabled白边"):
		border_enabled = bool(_legacy_border_properties[&"puddles_enabled白边"])
	if _legacy_border_properties.has(&"puddles_enabled白边动效"):
		border_animation_enabled = bool(_legacy_border_properties[&"puddles_enabled白边动效"])
	if _legacy_border_properties.has(&"积水白边动效强度"):
		border_animation_strength = float(_legacy_border_properties[&"积水白边动效强度"])
	if _legacy_border_properties.has(&"积水白边闪光强度"):
		border_shimmer_strength = float(_legacy_border_properties[&"积水白边闪光强度"])
	if _legacy_border_properties.has(&"积水白边颜色"):
		border_color = _legacy_border_properties[&"积水白边颜色"]
	if _legacy_border_properties.has(&"积水白边width"):
		border_width = float(_legacy_border_properties[&"积水白边width"])
	_legacy_border_properties.clear()

func _exit_tree() -> void:
	var manager := get_node_or_null("/root/PuddleManager")
	if manager != null and manager.has_method("unregister_puddle_canvas"):
		manager.unregister_puddle_canvas(self)

func _manager_set_reflection_texture(reflection_texture: ViewportTexture) -> void:
	texture = reflection_texture

func _manager_upload_mask(image: Image, world_rect: Rect2, version: int = -1) -> void:
	puddle_mask_image = image
	var size_changed: bool = puddle_mask_texture == null or puddle_mask_texture.get_width() != image.get_width() or puddle_mask_texture.get_height() != image.get_height()
	if size_changed:
		puddle_mask_texture = ImageTexture.create_from_image(image)
		_fallback_mask_texture = ImageTexture.create_from_image(image)
	else:
		# 更新未被当前 Shader 采样的备用纹理，再交换引用，避免对正在渲染的
		# ImageTexture 原地 update 导致 RenderingServer/GPU 同步尖峰。
		if _fallback_mask_texture == null or _fallback_mask_texture.get_width() != image.get_width() or _fallback_mask_texture.get_height() != image.get_height():
			_fallback_mask_texture = ImageTexture.create_from_image(image)
		else:
			_fallback_mask_texture.update(image)
		var old_active_texture := puddle_mask_texture
		puddle_mask_texture = _fallback_mask_texture
		_fallback_mask_texture = old_active_texture
	mask_world_rect = world_rect
	_uploaded_mask_version = _mask_parameter_version if version < 0 else version
	puddle_material.set_shader_parameter("puddle_mask", puddle_mask_texture)
	puddle_material.set_shader_parameter("mask_world_origin", world_rect.position)
	puddle_material.set_shader_parameter("mask_world_size", world_rect.size)

func _set_empty_mask() -> void:
	var empty_image := Image.create(1, 1, false, Image.FORMAT_R8)
	empty_image.fill(Color.BLACK)
	puddle_mask_texture = ImageTexture.create_from_image(empty_image)
	_fallback_mask_texture = ImageTexture.create_from_image(empty_image)
	puddle_mask_image = null
	mask_world_rect = Rect2()
	puddle_material.set_shader_parameter("puddle_mask", puddle_mask_texture)
	puddle_material.set_shader_parameter("mask_world_origin", Vector2.ZERO)
	puddle_material.set_shader_parameter("mask_world_size", Vector2.ONE)

func _sync_all_water_parameters() -> void:
	var water_parameters := {
		&"mask_threshold_smoothing": mask_edge_smoothing_radius > 0,
		&"water_color": water_color,
		&"reflection_opacity": reflection_opacity,
		&"water_edge_enabled": border_enabled,
		&"water_edge_animation_enabled": border_animation_enabled,
		&"water_edge_animation_strength": border_animation_strength,
		&"water_edge_shimmer_strength": border_shimmer_strength,
		&"water_edge_color": border_color,
		&"water_edge_width": border_width,
		&"water_edge_blend_width": border_blend_width,
		&"wind_disturbance_enabled": wind_distortion_enabled,
		&"wind_direction": wind_direction,
		&"wind_ripple_size": wind_wave_size,
		&"wind_speed": wind_wave_speed,
		&"surface_roughness": surface_roughness,
		&"reflection_response": reflection_distortion,
		&"ripple_highlight": wind_highlight_strength,
		&"footstep_ripple_speed": footstep_ripple_speed,
		&"footstep_ripple_duration": footstep_ripple_duration,
		&"footstep_ripple_width": footstep_ripple_width,
		&"footstep_ripple_strength": footstep_ripple_strength,
		&"footstep_ripple_highlight": footstep_ripple_highlight,
		&"rain_ripples_enabled": rain_ripples_enabled,
		&"rain_ripple_spacing": rain_ripple_spacing,
		&"rain_ripple_interval": rain_ripple_interval,
		&"rain_ripple_speed": rain_ripple_speed,
		&"rain_ripple_duration": rain_ripple_duration,
		&"rain_ripple_width": rain_ripple_width,
		&"rain_ripple_strength": rain_ripple_strength,
		&"rain_ripple_highlight": rain_ripple_highlight,
	}
	for parameter_name in water_parameters:
		_set_puddle_material_parameter(parameter_name, water_parameters[parameter_name])

func _set_puddle_material_parameter(parameter_name: StringName, value: Variant) -> void:
	if is_node_ready() and puddle_material != null:
		puddle_material.set_shader_parameter(parameter_name, value)

func _invalidate_mask() -> void:
	_mask_parameter_version += 1
	_uploaded_mask_version = -1
	# 保留当前遮罩作为后台重建期间的画面，完成后再原位更新纹理。
	# 首次启动仍由 _ready() 设置空遮罩并同步GENERATE完整精度遮罩。
