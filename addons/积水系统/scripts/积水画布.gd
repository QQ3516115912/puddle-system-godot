@tool
@icon("res://addons/积水系统/icon/积水画布.svg")
extends Sprite2D
class_name 积水画布

const 积水着色器 := preload("res://addons/积水系统/shader/积水.gdshader")
const 全图噪声范围参数 := [
	&"全图噪声积水左边界",
	&"全图噪声积水上边界",
	&"全图噪声积水右边界",
	&"全图噪声积水下边界",
]
@export_group("积水设置")
## 控制是否启用这个节点，关闭后将不再显示任何积水，且不进行任何运算
@export var 启用积水:=true:
	set(v):
		启用积水=v
		visible=v
## 用于生成世界积水分布的 FastNoiseLite。留空会自动创建默认噪声。
@export var 积水所用噪声: FastNoiseLite
## 干涸程度；0 为完整积水，1 接近完全干涸。
@export_range(0.0, 1.0, 0.01) var 干涸度 := 0.0:
	set(value):
		value = clampf(value, 0.0, 1.0)
		if is_equal_approx(干涸度, value):
			return
		干涸度 = value
		_invalidate_mask()
## 噪声阈值控制积水密度，数值越大通常积水越多。
@export_range(0.05, 0.95, 0.01) var 积水多少 := 0.38:
	set(value):
		积水多少 = value
		_invalidate_mask()
## 噪声采样尺度，数值越大积水斑块越大。
@export_range(80.0, 1600.0, 10.0) var 积水大小 := 520.0:
	set(value):
		积水大小 = value
		_invalidate_mask()
## 统一控制噪声积水、指定生成区域和排除区域边缘的渐变宽度。
@export_range(0.001, 0.25, 0.001) var 积水边缘柔和度 := 0.045:
	set(value):
		积水边缘柔和度 = value
		_invalidate_mask()
## 生成遮罩的分辨率；越高越精细，但计算量越大。
@export_range(64, 512, 1) var 遮罩精度 := 256:
	set(value):
		遮罩精度 = value
		_invalidate_mask()
## 遮罩边缘覆盖率平滑半径；按距离递减采样，Shader 以 0.5 为岸线恢复连续轮廓。0 为关闭。
@export_range(0, 8, 1) var 遮罩边缘平滑采样 := 2:
	set(value):
		遮罩边缘平滑采样 = value
		_设置积水材质参数(&"mask_threshold_smoothing", value > 0)
		_invalidate_mask()
## 在可见范围外额外生成的遮罩边缘比例；每侧还会叠加 256 世界单位固定缓冲。
@export_range(0.0, 1.0, 0.05) var 遮罩缓冲比例 := 0.35:
	set(value):
		遮罩缓冲比例 = value
		_invalidate_mask()
@export_group("")
@export_group("生成范围")
@export_subgroup("全图噪声积水")
## 是否在全图按噪声生成积水。
@export var 启用全图噪声积水 := true:
	set(value):
		启用全图噪声积水 = value
		notify_property_list_changed()
		_invalidate_mask()
## 是否限制全图噪声只在四个边界组成的矩形内生成。
@export var 限制全图噪声积水生成范围 := false:
	set(value):
		限制全图噪声积水生成范围 = value
		notify_property_list_changed()
		_invalidate_mask()
## 全图噪声生成范围的左边界，单位为世界坐标。
@export var 全图噪声积水左边界 := -10000000:
	set(value):
		全图噪声积水左边界 = value
		_invalidate_mask()
## 全图噪声生成范围的上边界，单位为世界坐标。
@export var 全图噪声积水上边界 := -10000000:
	set(value):
		全图噪声积水上边界 = value
		_invalidate_mask()
## 全图噪声生成范围的右边界，单位为世界坐标。
@export var 全图噪声积水右边界 := 10000000:
	set(value):
		全图噪声积水右边界 = value
		_invalidate_mask()
## 全图噪声生成范围的下边界，单位为世界坐标。
@export var 全图噪声积水下边界 := 10000000:
	set(value):
		全图噪声积水下边界 = value
		_invalidate_mask()

@export_subgroup("积水排除区域")
## 是否启用类型为“排除”的积水区域节点。排除优先级高于生成。
@export var 使用积水排除区域 := true:
	set(value):
		使用积水排除区域 = value
		notify_property_list_changed()
		_invalidate_mask()
## 排除区域反向曲线比例。贝塞尔端点始终是原多边形顶点；0 为直线，100 为最大反向弯曲。
@export_range(0.0, 100.0, 1.0, "suffix:%") var 排除区域圆角比例 := 100.0:
	set(value):
		排除区域圆角比例 = value
		_invalidate_mask()

@export_subgroup("指定生成区域")
## 是否启用类型为“生成”的积水区域节点。
@export var 启用指定区域积水 := true:
	set(value):
		启用指定区域积水 = value
		notify_property_list_changed()
		_invalidate_mask()
## 生成区域边界曲线比例。贝塞尔端点始终是原多边形顶点；0 为直线，100 为最大向内弯曲。
@export_range(0.0, 100.0, 1.0, "suffix:%") var 生成区域圆角比例 := 100.0:
	set(value):
		生成区域圆角比例 = value
		_invalidate_mask()

@export_subgroup("")
@export_group("")
@export_group("水面外观")
## 水面底色；RGB 为颜色，Alpha 控制底色透明度。
@export var 水面颜色 := Color(0.37630722, 0.4856034, 0.69460505, 0.4862745):
	set(value):
		水面颜色 = value
		_设置积水材质参数(&"water_color", value)
## 倒影混入强度；0 为不显示倒影，1 为完全按倒影权重混合。
@export_range(0.0, 1.0, 0.01) var 倒影透明度 := 0.6:
	set(value):
		倒影透明度 = value
		_设置积水材质参数(&"reflection_opacity", value)
## 是否显示积水遮罩内侧的边缘高光。
@export var 启用积水边框 := true:
	set(value):
		启用积水边框 = value
		notify_property_list_changed()
		_设置积水材质参数(&"water_edge_enabled", value)
## 是否让边框周期性向积水外侧扩张并平滑收回。
@export var 启用积水边框动效 := false:
	set(value):
		启用积水边框动效 = value
		notify_property_list_changed()
		_设置积水材质参数(&"water_edge_animation_enabled", value)
## 边框动效的强度，越大向外扩的越远。
@export_range(0.0, 32.0, 0.1) var 积水边框动效强度 := 4.0:
	set(value):
		积水边框动效强度 = value
		_设置积水材质参数(&"water_edge_animation_strength", value)
## 边框局部闪烁高光强度；数值越大，沿边缘掠过的亮点越明显。
@export_range(0.0, 1.0, 0.01) var 积水边框闪光强度 := 0.1:
	set(value):
		积水边框闪光强度 = value
		_设置积水材质参数(&"water_edge_shimmer_strength", value)
## 积水边框颜色；Alpha 控制边框覆盖强度。
@export var 积水边框颜色 := Color(1.0, 1.0, 1.0, 0.157):
	set(value):
		积水边框颜色 = value
		_设置积水材质参数(&"water_edge_color", value)
## 边框向积水内部延伸的宽度，单位为世界坐标。
@export_range(0.0, 32.0, 0.5) var 积水边框宽度 := 8.0:
	set(value):
		积水边框宽度 = value
		_设置积水材质参数(&"water_edge_width", value)
## 边框靠水面内缘的渐变宽度；类似 StyleBoxFlat 的 blend，0 仅保留像素抗锯齿。
@export_range(0.0, 32.0, 0.5) var 积水边框混合宽度 := 4.0:
	set(value):
		积水边框混合宽度 = value
		_设置积水材质参数(&"water_edge_blend_width", value)
@export_group("")

@export_group("风吹水纹")
## 是否启用风扰动高度场。
@export var 风扰动启用 := true:
	set(value):
		风扰动启用 = value
		_设置积水材质参数(&"wind_disturbance_enabled", value)
## 风纹传播方向，Shader 内部会自动归一化。
@export var 风向 := Vector2(1.0, 1.0):
	set(value):
		风向 = value
		_设置积水材质参数(&"wind_direction", value)
## 风纹世界尺寸；越大纹理越疏。
@export_range(8.0, 300.0, 1.0) var 风纹尺寸 := 122.0:
	set(value):
		风纹尺寸 = value
		_设置积水材质参数(&"wind_ripple_size", value)
## 风纹移动速度。
@export_range(0.0, 8.0, 0.05) var 风纹速度 := 2.0:
	set(value):
		风纹速度 = value
		_设置积水材质参数(&"wind_speed", value)
## 水面高度差转换为法线坡度的倍率。
@export_range(0.0, 20.0, 0.1) var 水面粗糙度 := 8.0:
	set(value):
		水面粗糙度 = value
		_设置积水材质参数(&"surface_roughness", value)
## 倒影对水面坡度的响应倍率。
@export_range(0.0, 12.0, 0.1) var 倒影扰动强度 := 3.0:
	set(value):
		倒影扰动强度 = value
		_设置积水材质参数(&"reflection_response", value)
## 风纹高光强度。
@export_range(0.0, 0.5, 0.01) var 风纹高光强度 := 0.2:
	set(value):
		风纹高光强度 = value
		_设置积水材质参数(&"ripple_highlight", value)
@export_group("")

@export_group("雨滴涟漪")
## 是否启用程序化雨滴涟漪。
@export var 启用雨滴涟漪 := false:
	set(value):
		启用雨滴涟漪 = value
		_设置积水材质参数(&"rain_ripples_enabled", value)
## 雨滴落点网格间距，越大雨滴越稀疏。
@export_range(80.0, 400.0, 5.0) var 雨滴涟漪间距 := 180.0:
	set(value):
		雨滴涟漪间距 = value
		_设置积水材质参数(&"rain_ripple_spacing", value)
## 同一落点生成下一次雨滴的时间间隔。
@export_range(0.15, 4.0, 0.05) var 雨滴涟漪间隔 := 0.8:
	set(value):
		雨滴涟漪间隔 = value
		_设置积水材质参数(&"rain_ripple_interval", value)
## 雨滴圆环扩散速度。
@export_range(10.0, 180.0, 1.0) var 雨滴涟漪速度 := 55.0:
	set(value):
		雨滴涟漪速度 = value
		_设置积水材质参数(&"rain_ripple_speed", value)
## 单个雨滴圆环持续时间。
@export_range(0.1, 3.0, 0.05) var 雨滴涟漪持续时间 := 1.1:
	set(value):
		雨滴涟漪持续时间 = value
		_设置积水材质参数(&"rain_ripple_duration", value)
## 雨滴圆环宽度。
@export_range(0.5, 16.0, 0.5) var 雨滴涟漪宽度 := 2.5:
	set(value):
		雨滴涟漪宽度 = value
		_设置积水材质参数(&"rain_ripple_width", value)
## 雨滴对水面法线的影响强度。
@export_range(0.0, 4.0, 0.05) var 雨滴涟漪强度 := 0.75:
	set(value):
		雨滴涟漪强度 = value
		_设置积水材质参数(&"rain_ripple_strength", value)
## 雨滴高光强度。
@export_range(0.0, 1.0, 0.01) var 雨滴涟漪高光 := 0.3:
	set(value):
		雨滴涟漪高光 = value
		_设置积水材质参数(&"rain_ripple_highlight", value)
@export_group("")

@export_group("脚步涟漪")
## 脚步圆环扩散速度。
@export_range(10.0, 300.0, 1.0) var 脚步涟漪速度 := 90.0:
	set(value):
		脚步涟漪速度 = value
		_设置积水材质参数(&"footstep_ripple_speed", value)
## 脚步圆环持续时间。
@export_range(0.1, 4.0, 0.05) var 脚步涟漪持续时间 := 1.2:
	set(value):
		脚步涟漪持续时间 = value
		_设置积水材质参数(&"footstep_ripple_duration", value)
## 脚步圆环宽度。
@export_range(1.0, 30.0, 0.5) var 脚步涟漪宽度 := 4.0:
	set(value):
		脚步涟漪宽度 = value
		_设置积水材质参数(&"footstep_ripple_width", value)
## 脚步对水面法线的影响强度。
@export_range(0.0, 4.0, 0.05) var 脚步涟漪强度 := 1.8:
	set(value):
		脚步涟漪强度 = value
		_设置积水材质参数(&"footstep_ripple_strength", value)
## 脚步圆环高光强度。
@export_range(0.0, 1.0, 0.01) var 脚步涟漪高光 := 0.45:
	set(value):
		脚步涟漪高光 = value
		_设置积水材质参数(&"footstep_ripple_highlight", value)
@export_group("")

var 积水材质: ShaderMaterial
var puddle_mask_texture: ImageTexture
var _备用遮罩纹理: ImageTexture
var puddle_mask_image: Image
var mask_world_rect := Rect2()
var _已上传遮罩版本 := -1
var _遮罩参数版本 := 0
# 仅用于读取旧版插件保存到场景中的“白边”字段，新项目检查器只显示“边框”。
var _旧白边参数: Dictionary = {}

func _set(property: StringName, value: Variant) -> bool:
	if property in [&"启用积水白边", &"积水白边显示倒影", &"启用积水白边动效", &"积水白边动效强度", &"积水白边闪光强度", &"积水白边颜色", &"积水白边宽度"]:
		_旧白边参数[property] = value
		return true
	return false

func _validate_property(property: Dictionary) -> void:
	if property.name == &"限制全图噪声积水生成范围" and not 启用全图噪声积水:
		property.usage = PROPERTY_USAGE_STORAGE
	elif property.name in 全图噪声范围参数 and (not 启用全图噪声积水 or not 限制全图噪声积水生成范围):
		property.usage = PROPERTY_USAGE_STORAGE
	elif property.name == &"排除区域圆角比例" and not 使用积水排除区域:
		property.usage = PROPERTY_USAGE_STORAGE
	elif property.name == &"生成区域圆角比例" and not 启用指定区域积水:
		property.usage = PROPERTY_USAGE_STORAGE
	elif property.name in [&"启用积水边框动效", &"积水边框动效强度", &"积水边框闪光强度", &"积水边框颜色", &"积水边框宽度", &"积水边框混合宽度"] and not 启用积水边框:
		property.usage = PROPERTY_USAGE_STORAGE
	elif property.name in [&"积水边框动效强度", &"积水边框闪光强度"] and not 启用积水边框动效:
		property.usage = PROPERTY_USAGE_STORAGE

func _ready() -> void:
	_迁移旧白边参数()
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	if centered:
		centered=false
	积水材质 = material as ShaderMaterial
	if 积水材质 == null:
		积水材质 = ShaderMaterial.new()
		积水材质.shader = 积水着色器
		material = 积水材质
	if 积水所用噪声 == null:
		积水所用噪声 = FastNoiseLite.new()
	积水所用噪声.frequency = 1.0
	积水所用噪声.fractal_octaves = 2
	_设置空遮罩()
	_同步全部水面参数()
	var 管理器 := get_node_or_null("/root/积水管理器")
	if 管理器 != null and 管理器.has_method("注册积水画布"):
		管理器.注册积水画布(self)
	elif not Engine.is_editor_hint():
		push_warning("积水画布未找到 /root/积水管理器，请在项目设置中启用积水系统插件或添加同名 Autoload。")

func _迁移旧白边参数() -> void:
	if _旧白边参数.has(&"启用积水白边"):
		启用积水边框 = bool(_旧白边参数[&"启用积水白边"])
	if _旧白边参数.has(&"启用积水白边动效"):
		启用积水边框动效 = bool(_旧白边参数[&"启用积水白边动效"])
	if _旧白边参数.has(&"积水白边动效强度"):
		积水边框动效强度 = float(_旧白边参数[&"积水白边动效强度"])
	if _旧白边参数.has(&"积水白边闪光强度"):
		积水边框闪光强度 = float(_旧白边参数[&"积水白边闪光强度"])
	if _旧白边参数.has(&"积水白边颜色"):
		积水边框颜色 = _旧白边参数[&"积水白边颜色"]
	if _旧白边参数.has(&"积水白边宽度"):
		积水边框宽度 = float(_旧白边参数[&"积水白边宽度"])
	_旧白边参数.clear()

func _exit_tree() -> void:
	var 管理器 := get_node_or_null("/root/积水管理器")
	if 管理器 != null and 管理器.has_method("注销积水画布"):
		管理器.注销积水画布(self)

func _管理器设置倒影纹理(倒影纹理: ViewportTexture) -> void:
	texture = 倒影纹理

func _管理器上传遮罩(图像: Image, 世界范围: Rect2, 版本: int = -1) -> void:
	puddle_mask_image = 图像
	var 尺寸变化: bool = puddle_mask_texture == null or puddle_mask_texture.get_width() != 图像.get_width() or puddle_mask_texture.get_height() != 图像.get_height()
	if 尺寸变化:
		puddle_mask_texture = ImageTexture.create_from_image(图像)
		_备用遮罩纹理 = ImageTexture.create_from_image(图像)
	else:
		# 更新未被当前 Shader 采样的备用纹理，再交换引用，避免对正在渲染的
		# ImageTexture 原地 update 导致 RenderingServer/GPU 同步尖峰。
		if _备用遮罩纹理 == null or _备用遮罩纹理.get_width() != 图像.get_width() or _备用遮罩纹理.get_height() != 图像.get_height():
			_备用遮罩纹理 = ImageTexture.create_from_image(图像)
		else:
			_备用遮罩纹理.update(图像)
		var 旧活动纹理 := puddle_mask_texture
		puddle_mask_texture = _备用遮罩纹理
		_备用遮罩纹理 = 旧活动纹理
	mask_world_rect = 世界范围
	_已上传遮罩版本 = _遮罩参数版本 if 版本 < 0 else 版本
	积水材质.set_shader_parameter("puddle_mask", puddle_mask_texture)
	积水材质.set_shader_parameter("mask_world_origin", 世界范围.position)
	积水材质.set_shader_parameter("mask_world_size", 世界范围.size)

func _设置空遮罩() -> void:
	var 空图像 := Image.create(1, 1, false, Image.FORMAT_R8)
	空图像.fill(Color.BLACK)
	puddle_mask_texture = ImageTexture.create_from_image(空图像)
	_备用遮罩纹理 = ImageTexture.create_from_image(空图像)
	puddle_mask_image = null
	mask_world_rect = Rect2()
	积水材质.set_shader_parameter("puddle_mask", puddle_mask_texture)
	积水材质.set_shader_parameter("mask_world_origin", Vector2.ZERO)
	积水材质.set_shader_parameter("mask_world_size", Vector2.ONE)

func _同步全部水面参数() -> void:
	var water_parameters := {
		&"mask_threshold_smoothing": 遮罩边缘平滑采样 > 0,
		&"water_color": 水面颜色,
		&"reflection_opacity": 倒影透明度,
		&"water_edge_enabled": 启用积水边框,
		&"water_edge_animation_enabled": 启用积水边框动效,
		&"water_edge_animation_strength": 积水边框动效强度,
		&"water_edge_shimmer_strength": 积水边框闪光强度,
		&"water_edge_color": 积水边框颜色,
		&"water_edge_width": 积水边框宽度,
		&"water_edge_blend_width": 积水边框混合宽度,
		&"wind_disturbance_enabled": 风扰动启用,
		&"wind_direction": 风向,
		&"wind_ripple_size": 风纹尺寸,
		&"wind_speed": 风纹速度,
		&"surface_roughness": 水面粗糙度,
		&"reflection_response": 倒影扰动强度,
		&"ripple_highlight": 风纹高光强度,
		&"footstep_ripple_speed": 脚步涟漪速度,
		&"footstep_ripple_duration": 脚步涟漪持续时间,
		&"footstep_ripple_width": 脚步涟漪宽度,
		&"footstep_ripple_strength": 脚步涟漪强度,
		&"footstep_ripple_highlight": 脚步涟漪高光,
		&"rain_ripples_enabled": 启用雨滴涟漪,
		&"rain_ripple_spacing": 雨滴涟漪间距,
		&"rain_ripple_interval": 雨滴涟漪间隔,
		&"rain_ripple_speed": 雨滴涟漪速度,
		&"rain_ripple_duration": 雨滴涟漪持续时间,
		&"rain_ripple_width": 雨滴涟漪宽度,
		&"rain_ripple_strength": 雨滴涟漪强度,
		&"rain_ripple_highlight": 雨滴涟漪高光,
	}
	for parameter_name in water_parameters:
		_设置积水材质参数(parameter_name, water_parameters[parameter_name])

func _设置积水材质参数(parameter_name: StringName, value: Variant) -> void:
	if is_node_ready() and 积水材质 != null:
		积水材质.set_shader_parameter(parameter_name, value)

func _invalidate_mask() -> void:
	_遮罩参数版本 += 1
	_已上传遮罩版本 = -1
	# 保留当前遮罩作为后台重建期间的画面，完成后再原位更新纹理。
	# 首次启动仍由 _ready() 设置空遮罩并同步生成完整精度遮罩。
