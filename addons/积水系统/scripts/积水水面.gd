@tool
@icon("res://addons/积水系统/icon/积水水面.svg")
extends Node2D
class_name 积水水面

const 固定水面着色器 := preload("res://addons/积水系统/shader/固定水面.gdshader")

var 固定水面材质: ShaderMaterial
var _倒影纹理: ViewportTexture

@export_group("水面外观")
## 水面原始纹理的整体色调；RGB 控制颜色，Alpha 控制透明度。
@export var 水面颜色 := Color(0.72, 0.86, 1.0, 1.0):
	set(value):
		水面颜色 = value
		_设置水面材质参数(&"water_tint", value)
## 水面底色的亮度倍率；1 保持原亮度。
@export_range(0.0, 2.0, 0.01) var 水面亮度 := 1.0:
	set(value):
		水面亮度 = value
		_设置水面材质参数(&"water_brightness", value)

@export_group("倒影")
## 是否显示积水管理器提供的倒影；没有有效倒影纹理时会自动关闭。
@export var 启用倒影 := true:
	set(value):
		启用倒影 = value
		notify_property_list_changed()
		_同步倒影启用状态()
## 倒影混入水面的透明度；0 不可见，1 为完整混合。
@export_range(0.0, 1.0, 0.01) var 倒影透明度 := 0.6:
	set(value):
		倒影透明度 = value
		_设置水面材质参数(&"reflection_opacity", value)
## 风纹和雨滴形成的水面坡度对倒影采样位置的扰动强度。
@export_range(0.0, 100.0, 0.1) var 倒影扰动强度 := 1.5:
	set(value):
		倒影扰动强度 = value
		_设置水面材质参数(&"reflection_response", value)

@export_group("风吹水纹")
## 是否启用持续移动的风吹水纹；关闭后仍可单独显示雨滴涟漪。
@export var 启用风扰动 := true:
	set(value):
		启用风扰动 = value
		notify_property_list_changed()
		_设置水面材质参数(&"wind_disturbance_enabled", value)
## 风纹在世界坐标中的传播方向，Shader 会自动归一化。
@export var 风向 := Vector2(1.0, 0.25):
	set(value):
		风向 = value
		_设置水面材质参数(&"wind_direction", value)
## 风纹的世界坐标波长；越小越密，越大越舒缓。
@export_range(8.0, 160.0, 1.0) var 风纹尺寸 := 42.0:
	set(value):
		风纹尺寸 = value
		_设置水面材质参数(&"wind_ripple_size", value)
## 风纹随时间移动的速度。
@export_range(0.0, 8.0, 0.05) var 风纹速度 := 1.4:
	set(value):
		风纹速度 = value
		_设置水面材质参数(&"wind_speed", value)
## 风纹对水面底色明暗的调制强度。
@export_range(0.0, 1.0, 0.01) var 风纹强度 := 0.16:
	set(value):
		风纹强度 = value
		_设置水面材质参数(&"wind_strength", value)
## 水面坡度产生的高光强度。
@export_range(0.0, 1.0, 0.01) var 风纹高光 := 0.18:
	set(value):
		风纹高光 = value
		_设置水面材质参数(&"ripple_highlight", value)

@export_group("雨滴涟漪")
## 是否在固定水面上生成程序化雨滴圆环。
@export var 启用雨滴涟漪 := false:
	set(value):
		启用雨滴涟漪 = value
		notify_property_list_changed()
		_设置水面材质参数(&"rain_ripples_enabled", value)
## 随机雨滴落点使用的世界网格间距。
@export_range(80.0, 400.0, 5.0) var 雨滴涟漪间距 := 180.0:
	set(value):
		雨滴涟漪间距 = value
		_设置水面材质参数(&"rain_ripple_spacing", value)
## 同一网格两次雨滴之间的时间间隔。
@export_range(0.15, 4.0, 0.05) var 雨滴涟漪间隔 := 0.8:
	set(value):
		雨滴涟漪间隔 = value
		_设置水面材质参数(&"rain_ripple_interval", value)
## 雨滴圆环向外扩散的速度。
@export_range(10.0, 180.0, 1.0) var 雨滴涟漪速度 := 55.0:
	set(value):
		雨滴涟漪速度 = value
		_设置水面材质参数(&"rain_ripple_speed", value)
## 单个雨滴圆环从出现到消失的持续时间。
@export_range(0.1, 3.0, 0.05) var 雨滴涟漪持续时间 := 1.1:
	set(value):
		雨滴涟漪持续时间 = value
		_设置水面材质参数(&"rain_ripple_duration", value)
## 雨滴圆环的边缘宽度，单位为世界坐标。
@export_range(0.5, 16.0, 0.5) var 雨滴涟漪宽度 := 2.5:
	set(value):
		雨滴涟漪宽度 = value
		_设置水面材质参数(&"rain_ripple_width", value)
## 雨滴形成的水面坡度强度，同时影响倒影扰动。
@export_range(0.0, 4.0, 0.05) var 雨滴涟漪强度 := 0.75:
	set(value):
		雨滴涟漪强度 = value
		_设置水面材质参数(&"rain_ripple_strength", value)
## 雨滴圆环额外叠加的高光强度。
@export_range(0.0, 1.0, 0.01) var 雨滴涟漪高光 := 0.3:
	set(value):
		雨滴涟漪高光 = value
		_设置水面材质参数(&"rain_ripple_highlight", value)
@export_group("")

func _validate_property(property: Dictionary) -> void:
	if property.name in [&"倒影透明度", &"倒影扰动强度"] and not 启用倒影:
		property.usage = PROPERTY_USAGE_STORAGE
	elif property.name in [&"风向", &"风纹尺寸", &"风纹速度", &"风纹强度", &"风纹高光"] and not 启用风扰动:
		property.usage = PROPERTY_USAGE_STORAGE
	elif property.name in [&"雨滴涟漪间距", &"雨滴涟漪间隔", &"雨滴涟漪速度", &"雨滴涟漪持续时间", &"雨滴涟漪宽度", &"雨滴涟漪强度", &"雨滴涟漪高光"] and not 启用雨滴涟漪:
		property.usage = PROPERTY_USAGE_STORAGE

func _ready() -> void:
	_确保固定水面材质()
	_同步全部水面参数()
	_添加水面后代(self)
	var 管理器 := get_node_or_null("/root/积水管理器")
	if 管理器 != null and 管理器.has_method("注册积水水面"):
		管理器.注册积水水面(self)

func _exit_tree() -> void:
	var 管理器 := get_node_or_null("/root/积水管理器")
	if 管理器 != null and 管理器.has_method("注销积水水面"):
		管理器.注销积水水面(self)

func _确保固定水面材质() -> void:
	固定水面材质 = material as ShaderMaterial
	if 固定水面材质 == null or 固定水面材质.shader != 固定水面着色器:
		固定水面材质 = ShaderMaterial.new()
		固定水面材质.shader = 固定水面着色器
		material = 固定水面材质

func _添加水面后代(节点: Node) -> void:
	if not 节点.child_entered_tree.is_connected(_添加水面后代):
		节点.child_entered_tree.connect(_添加水面后代)
	if 节点 != self and 节点 is CanvasItem:
		(节点 as CanvasItem).use_parent_material = true
	for 子节点 in 节点.get_children():
		_添加水面后代(子节点)

func _同步全部水面参数() -> void:
	var 水面参数 := {
		&"water_tint": 水面颜色,
		&"water_brightness": 水面亮度,
		&"reflection_opacity": 倒影透明度,
		&"reflection_response": 倒影扰动强度,
		&"wind_disturbance_enabled": 启用风扰动,
		&"wind_direction": 风向,
		&"wind_ripple_size": 风纹尺寸,
		&"wind_speed": 风纹速度,
		&"wind_strength": 风纹强度,
		&"ripple_highlight": 风纹高光,
		&"rain_ripples_enabled": 启用雨滴涟漪,
		&"rain_ripple_spacing": 雨滴涟漪间距,
		&"rain_ripple_interval": 雨滴涟漪间隔,
		&"rain_ripple_speed": 雨滴涟漪速度,
		&"rain_ripple_duration": 雨滴涟漪持续时间,
		&"rain_ripple_width": 雨滴涟漪宽度,
		&"rain_ripple_strength": 雨滴涟漪强度,
		&"rain_ripple_highlight": 雨滴涟漪高光,
	}
	for 参数名 in 水面参数:
		固定水面材质.set_shader_parameter(参数名, 水面参数[参数名])
	_同步倒影启用状态()

func _设置水面材质参数(参数名: StringName, 值: Variant) -> void:
	if is_node_ready() and 固定水面材质 != null:
		固定水面材质.set_shader_parameter(参数名, 值)

func _同步倒影启用状态() -> void:
	_设置水面材质参数(&"reflection_enabled", 启用倒影 and _倒影纹理 != null)

func _管理器设置倒影纹理(倒影纹理: ViewportTexture) -> void:
	_确保固定水面材质()
	_倒影纹理 = 倒影纹理
	固定水面材质.set_shader_parameter(&"reflection_texture", 倒影纹理)
	固定水面材质.set_shader_parameter(&"reflection_enabled", 启用倒影 and 倒影纹理 != null)
