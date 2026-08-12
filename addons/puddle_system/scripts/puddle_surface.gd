@tool
@icon("res://addons/puddle_system/icon/puddle_surface.svg")
extends Node2D
class_name PuddleSurface

const WATER_SURFACE_SHADER := preload("res://addons/puddle_system/shader/water_surface.gdshader")

var water_surface_material: ShaderMaterial
var _reflection_texture: ViewportTexture

@export_group("Water Appearance")
## 水面原始纹理的整体色调；RGB 控制颜色，Alpha 控制透明度。
@export var water_color := Color(0.72, 0.86, 1.0, 1.0):
	set(value):
		water_color = value
		_set_surface_material_parameter(&"water_tint", value)
## 水面底色的亮度倍率；1 保持原亮度。
@export_range(0.0, 2.0, 0.01) var water_brightness := 1.0:
	set(value):
		water_brightness = value
		_set_surface_material_parameter(&"water_brightness", value)

@export_group("Reflection")
## 是否显示PuddleManager提供的倒影；没有有效reflection_texture时会自动关闭。
@export var reflection_enabled := true:
	set(value):
		reflection_enabled = value
		notify_property_list_changed()
		_sync_reflection_enabled()
## 倒影混入水面的透明度；0 不可见，1 为完整混合。
@export_range(0.0, 1.0, 0.01) var reflection_opacity := 0.6:
	set(value):
		reflection_opacity = value
		_set_surface_material_parameter(&"reflection_opacity", value)
## 风纹和雨滴形成的水面坡度对倒影采样position的扰动强度。
@export_range(0.0, 100.0, 0.1) var reflection_distortion := 1.5:
	set(value):
		reflection_distortion = value
		_set_surface_material_parameter(&"reflection_response", value)

@export_group("Wind Waves")
## 是否enabled持续移动的风吹水纹；关闭后仍可单独显示雨滴涟漪。
@export var wind_distortion_enabled := true:
	set(value):
		wind_distortion_enabled = value
		notify_property_list_changed()
		_set_surface_material_parameter(&"wind_disturbance_enabled", value)
## 风纹在world_position中的传播方向，Shader 会自动归一化。
@export var wind_direction := Vector2(1.0, 0.25):
	set(value):
		wind_direction = value
		_set_surface_material_parameter(&"wind_direction", value)
## 风纹的world_position波长；越小越密，越大越舒缓。
@export_range(8.0, 160.0, 1.0) var wind_wave_size := 42.0:
	set(value):
		wind_wave_size = value
		_set_surface_material_parameter(&"wind_ripple_size", value)
## 风纹随时间移动的速度。
@export_range(0.0, 8.0, 0.05) var wind_wave_speed := 1.4:
	set(value):
		wind_wave_speed = value
		_set_surface_material_parameter(&"wind_speed", value)
## 风纹对水面底色明暗的调制强度。
@export_range(0.0, 1.0, 0.01) var wind_wave_strength := 0.16:
	set(value):
		wind_wave_strength = value
		_set_surface_material_parameter(&"wind_strength", value)
## 水面坡度产生的高光强度。
@export_range(0.0, 1.0, 0.01) var wind_highlight_strength := 0.18:
	set(value):
		wind_highlight_strength = value
		_set_surface_material_parameter(&"ripple_highlight", value)

@export_group("Rain Ripples")
## 是否在固定水面topGENERATE程序化雨滴圆环。
@export var rain_ripples_enabled := false:
	set(value):
		rain_ripples_enabled = value
		notify_property_list_changed()
		_set_surface_material_parameter(&"rain_ripples_enabled", value)
## 随机雨滴落point使用的世界网格间距。
@export_range(80.0, 400.0, 5.0) var rain_ripple_spacing := 180.0:
	set(value):
		rain_ripple_spacing = value
		_set_surface_material_parameter(&"rain_ripple_spacing", value)
## 同一网格两次雨滴之间的时间间隔。
@export_range(0.15, 4.0, 0.05) var rain_ripple_interval := 0.8:
	set(value):
		rain_ripple_interval = value
		_set_surface_material_parameter(&"rain_ripple_interval", value)
## 雨滴圆环向外扩散的速度。
@export_range(10.0, 180.0, 1.0) var rain_ripple_speed := 55.0:
	set(value):
		rain_ripple_speed = value
		_set_surface_material_parameter(&"rain_ripple_speed", value)
## 单个雨滴圆环从出现到消失的duration。
@export_range(0.1, 3.0, 0.05) var rain_ripple_duration := 1.1:
	set(value):
		rain_ripple_duration = value
		_set_surface_material_parameter(&"rain_ripple_duration", value)
## 雨滴圆环的边缘width，单位为world_position。
@export_range(0.5, 16.0, 0.5) var rain_ripple_width := 2.5:
	set(value):
		rain_ripple_width = value
		_set_surface_material_parameter(&"rain_ripple_width", value)
## 雨滴形成的水面坡度强度，同时影响倒影扰动。
@export_range(0.0, 4.0, 0.05) var rain_ripple_strength := 0.75:
	set(value):
		rain_ripple_strength = value
		_set_surface_material_parameter(&"rain_ripple_strength", value)
## 雨滴圆环额外叠加的高光强度。
@export_range(0.0, 1.0, 0.01) var rain_ripple_highlight := 0.3:
	set(value):
		rain_ripple_highlight = value
		_set_surface_material_parameter(&"rain_ripple_highlight", value)
@export_group("")

func _validate_property(property: Dictionary) -> void:
	if property.name in [&"reflection_opacity", &"reflection_distortion"] and not reflection_enabled:
		property.usage = PROPERTY_USAGE_STORAGE
	elif property.name in [&"wind_direction", &"wind_wave_size", &"wind_wave_speed", &"wind_wave_strength", &"wind_highlight_strength"] and not wind_distortion_enabled:
		property.usage = PROPERTY_USAGE_STORAGE
	elif property.name in [&"rain_ripple_spacing", &"rain_ripple_interval", &"rain_ripple_speed", &"rain_ripple_duration", &"rain_ripple_width", &"rain_ripple_strength", &"rain_ripple_highlight"] and not rain_ripples_enabled:
		property.usage = PROPERTY_USAGE_STORAGE

func _ready() -> void:
	_ensure_water_surface_material()
	_sync_all_water_parameters()
	_add_surface_descendants(self)
	var manager := get_node_or_null("/root/PuddleManager")
	if manager != null and manager.has_method("register_puddle_surface"):
		manager.register_puddle_surface(self)

func _exit_tree() -> void:
	var manager := get_node_or_null("/root/PuddleManager")
	if manager != null and manager.has_method("unregister_puddle_surface"):
		manager.unregister_puddle_surface(self)

func _ensure_water_surface_material() -> void:
	water_surface_material = material as ShaderMaterial
	if water_surface_material == null or water_surface_material.shader != WATER_SURFACE_SHADER:
		water_surface_material = ShaderMaterial.new()
		water_surface_material.shader = WATER_SURFACE_SHADER
		material = water_surface_material

func _add_surface_descendants(node: Node) -> void:
	if not node.child_entered_tree.is_connected(_add_surface_descendants):
		node.child_entered_tree.connect(_add_surface_descendants)
	if node != self and node is CanvasItem:
		(node as CanvasItem).use_parent_material = true
	for 子node in node.get_children():
		_add_surface_descendants(子node)

func _sync_all_water_parameters() -> void:
	var surface_parameters := {
		&"water_tint": water_color,
		&"water_brightness": water_brightness,
		&"reflection_opacity": reflection_opacity,
		&"reflection_response": reflection_distortion,
		&"wind_disturbance_enabled": wind_distortion_enabled,
		&"wind_direction": wind_direction,
		&"wind_ripple_size": wind_wave_size,
		&"wind_speed": wind_wave_speed,
		&"wind_strength": wind_wave_strength,
		&"ripple_highlight": wind_highlight_strength,
		&"rain_ripples_enabled": rain_ripples_enabled,
		&"rain_ripple_spacing": rain_ripple_spacing,
		&"rain_ripple_interval": rain_ripple_interval,
		&"rain_ripple_speed": rain_ripple_speed,
		&"rain_ripple_duration": rain_ripple_duration,
		&"rain_ripple_width": rain_ripple_width,
		&"rain_ripple_strength": rain_ripple_strength,
		&"rain_ripple_highlight": rain_ripple_highlight,
	}
	for parameter_name in surface_parameters:
		water_surface_material.set_shader_parameter(parameter_name, surface_parameters[parameter_name])
	_sync_reflection_enabled()

func _set_surface_material_parameter(parameter_name: StringName, value: Variant) -> void:
	if is_node_ready() and water_surface_material != null:
		water_surface_material.set_shader_parameter(parameter_name, value)

func _sync_reflection_enabled() -> void:
	_set_surface_material_parameter(&"reflection_enabled", reflection_enabled and _reflection_texture != null)

func _manager_set_reflection_texture(reflection_texture: ViewportTexture) -> void:
	_ensure_water_surface_material()
	_reflection_texture = reflection_texture
	water_surface_material.set_shader_parameter(&"reflection_texture", reflection_texture)
	water_surface_material.set_shader_parameter(&"reflection_enabled", reflection_enabled and reflection_texture != null)
