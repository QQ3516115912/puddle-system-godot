extends Node
#重要函数
# is_point_in_water 判断一个点有没有在积水里面
# 绑定视口跟随 让一个节点跟随视口移动，原点在左上角
#重要变量
#倒影倾斜角度 控制所有倒影的倾斜度
#倒影拉伸比例 控制所有倒影的纵向拉伸

var debug:=false #控制打印输出
## 积水倒影使用的全局倾斜角度，单位为度。
var 倒影倾斜角度:=0.0:
	set(v):
		v=clampf(v,-45.0,45.0)
		if 倒影倾斜角度==v:
			return
		倒影倾斜角度=v
		倒影倾斜角度_change.emit(v)
signal 倒影倾斜角度_change(v)
## 积水倒影的纵向拉伸倍率。
var 倒影拉伸比例:=1.0:
	set(v):
		v=clampf(v,0.5,2.0)
		if 倒影拉伸比例==v:
			return
		倒影拉伸比例=v
		倒影拉伸比例_change.emit(v)
signal 倒影拉伸比例_change(v)



# 主视口默认画布层掩码。
const 全部画布层 := 0xFFFFFFFF
# Shader 中脚步涟漪数组的固定槽位数量。
const 最大脚步涟漪数 := 16
# 倒影视口使用的 CanvasItem 图层编号。
const 倒影层: int = 20
# 遮罩在后台生成时保留更多 CPU 给主线程。4 线程虽然单次计算更快，
# 但移动触发重建时容易造成帧时间尖峰；2 线程通常更平稳。
const 遮罩并行最大分块数 := 4
# 空间哈希单元边长，单位为世界坐标。应略大于常用遮罩范围。
const 积水区域空间网格尺寸 := 1024.0

var _积水画布: Node
var _视口跟随节点: Array = []
var _积水水面: Array = []
var _主视口: Viewport
var _倒影视口: SubViewport
var _倒影纹理: ViewportTexture
var _原主视口裁剪层 := 全部画布层
var _已保存主视口裁剪层 := false
var _当前倒影层掩码 := 1 << (倒影层 - 1)
var _遮罩生成线程: Thread
var _生成中世界范围 := Rect2()
var _生成中遮罩版本 := -1
var _待生成节点: Node
var _待生成可见范围 := Rect2()
var _存在待生成请求 := false
var _脚步涟漪位置 := PackedVector2Array()
var _脚步涟漪开始时间 := PackedFloat32Array()
var _下一个脚步涟漪槽位 := 0
var _存在活动脚步涟漪 := false
var _脚步涟漪已上传清空状态 := true
var _上次Shader视口尺寸 := Vector2(-1.0, -1.0)
var _上次Shader画布变换 := Transform2D()
var _已有Shader画布状态 := false
var _原生遮罩构建器: Object
var _正在退出 := false
var _生成积水区域节点: Dictionary = {}
var _排除积水区域节点: Dictionary = {}
var _生成区域空间网格: Dictionary = {}
var _排除区域空间网格: Dictionary = {}
var _积水区域网格单元: Dictionary = {}
var _空间索引版本 := 0
var _候选缓存网格范围 := Rect2i()
var _候选缓存空间版本 := -1
var _候选缓存生成实例: Dictionary = {}
var _候选缓存排除实例: Dictionary = {}
var _区域遮罩刷新已排队 := false

func _ready() -> void:
	if ClassDB.class_exists(&"PuddleMaskBuilder"):
		_原生遮罩构建器 = ClassDB.instantiate(&"PuddleMaskBuilder")
	else:
		push_warning("没有检测到 C++ 遮罩构建器 PuddleMaskBuilder，将回退到 GDScript；功能可用，但高分辨率或大量区域时性能会明显下降。")
	_脚步涟漪位置.resize(最大脚步涟漪数)
	_脚步涟漪开始时间.resize(最大脚步涟漪数)
	for 索引 in range(最大脚步涟漪数):
		_脚步涟漪开始时间[索引] = -1000.0
	RenderingServer.frame_pre_draw.connect(_帧前同步)

func _exit_tree() -> void:
	_正在退出 = true
	if RenderingServer.frame_pre_draw.is_connected(_帧前同步):
		RenderingServer.frame_pre_draw.disconnect(_帧前同步)
	if _遮罩生成线程 != null:
		_遮罩生成线程.wait_to_finish()
	_销毁倒影视口()

func _帧前同步() -> void:
	if _正在退出:
		return
	同步主视口()
	_apply_completed_mask()

func 注册积水画布(节点: Node) -> void:
	# 注册唯一的积水画布，并创建/绑定倒影视口。
	if not is_instance_valid(节点):
		return
	if _积水画布 == 节点:
		return
	if is_instance_valid(_积水画布):
		push_warning("积水管理器一次只能维护一个积水画布，已拒绝新的积水画布注册。")
		return
	_积水画布 = 节点
	_已有Shader画布状态 = false
	_存在活动脚步涟漪 = false
	_脚步涟漪已上传清空状态 = true
	绑定视口跟随(节点)
	_确保倒影视口(节点)
	节点.call("_管理器设置倒影纹理", _倒影纹理)
	call_deferred("同步主视口")

func 注销积水画布(节点: Node) -> void:
	# 移除当前积水画布并释放管理器创建的倒影视口。
	if _积水画布 != 节点:
		return
	_积水画布 = null
	_已有Shader画布状态 = false
	_存在活动脚步涟漪 = false
	_脚步涟漪已上传清空状态 = true
	_待生成节点 = null
	_待生成可见范围 = Rect2()
	_存在待生成请求 = false
	解除视口跟随(节点)
	_销毁倒影视口()

func 注册积水区域(区域: 积水区域) -> void:
	if not is_instance_valid(区域):
		return
	var 实例ID := 区域.get_instance_id()
	if 区域.获取区域类型() == 积水区域.区域类型.生成:
		_生成积水区域节点[实例ID] = 区域
	else:
		_排除积水区域节点[实例ID] = 区域
	_更新积水区域空间网格(区域, Rect2(), 区域.获取粗略世界包围盒())
	_按变化范围刷新遮罩(Rect2(), 区域.获取粗略世界包围盒())

func 注销积水区域(区域: 积水区域, 旧包围盒: Rect2) -> void:
	if 区域 != null:
		var 实例ID := 区域.get_instance_id()
		_生成积水区域节点.erase(实例ID)
		_排除积水区域节点.erase(实例ID)
		_移除积水区域空间网格(实例ID)
	_按变化范围刷新遮罩(旧包围盒, Rect2())

func 更新积水区域类型(区域: 积水区域, 旧类型: int, 新类型: int) -> void:
	if not is_instance_valid(区域) or 旧类型 == 新类型:
		return
	var 实例ID := 区域.get_instance_id()
	if 旧类型 == 积水区域.区域类型.生成:
		_生成积水区域节点.erase(实例ID)
	else:
		_排除积水区域节点.erase(实例ID)
	if 新类型 == 积水区域.区域类型.生成:
		_生成积水区域节点[实例ID] = 区域
	else:
		_排除积水区域节点[实例ID] = 区域
	var 包围盒 := 区域.获取粗略世界包围盒()
	_更新积水区域空间网格(区域, 包围盒, 包围盒)
	_按变化范围刷新遮罩(包围盒, 包围盒)

func 更新积水区域(_区域: 积水区域, 旧包围盒: Rect2, 新包围盒: Rect2) -> void:
	if is_instance_valid(_区域):
		_更新积水区域空间网格(_区域, 旧包围盒, 新包围盒)
	_按变化范围刷新遮罩(旧包围盒, 新包围盒)

func _获取积水区域网格范围(包围盒: Rect2) -> Rect2i:
	if not 包围盒.has_area():
		return Rect2i()
	var 结束位置 := 包围盒.position + 包围盒.size
	var 最小单元 := Vector2i(
		floori(包围盒.position.x / 积水区域空间网格尺寸),
		floori(包围盒.position.y / 积水区域空间网格尺寸)
	)
	var 最大单元 := Vector2i(
		floori((结束位置.x - 0.001) / 积水区域空间网格尺寸),
		floori((结束位置.y - 0.001) / 积水区域空间网格尺寸)
	)
	return Rect2i(最小单元, 最大单元 - 最小单元 + Vector2i.ONE)

func _更新积水区域空间网格(区域: 积水区域, 旧包围盒: Rect2, 新包围盒: Rect2) -> void:
	var 实例ID := 区域.get_instance_id()
	_移除积水区域空间网格(实例ID)
	var 网格范围 := _获取积水区域网格范围(新包围盒)
	if 网格范围.size == Vector2i.ZERO:
		return
	var 目标网格 := _生成区域空间网格 if 区域.获取区域类型() == 积水区域.区域类型.生成 else _排除区域空间网格
	var 单元列表: Array[Vector2i] = []
	for 网格Y in range(网格范围.position.y, 网格范围.end.y):
		for 网格X in range(网格范围.position.x, 网格范围.end.x):
			var 单元 := Vector2i(网格X, 网格Y)
			var 单元区域: Dictionary = 目标网格.get(单元, {})
			单元区域[实例ID] = true
			目标网格[单元] = 单元区域
			单元列表.append(单元)
	_积水区域网格单元[实例ID] = 单元列表
	_空间索引版本 += 1

func _移除积水区域空间网格(实例ID: int) -> void:
	var 单元列表: Array = _积水区域网格单元.get(实例ID, [])
	if 单元列表.is_empty():
		return
	for 单元 in 单元列表:
		_从空间网格单元移除(_生成区域空间网格, 单元, 实例ID)
		_从空间网格单元移除(_排除区域空间网格, 单元, 实例ID)
	_积水区域网格单元.erase(实例ID)
	_空间索引版本 += 1

func _从空间网格单元移除(空间网格: Dictionary, 单元: Vector2i, 实例ID: int) -> void:
	if not 空间网格.has(单元):
		return
	var 单元区域: Dictionary = 空间网格[单元]
	单元区域.erase(实例ID)
	if 单元区域.is_empty():
		空间网格.erase(单元)
	else:
		空间网格[单元] = 单元区域

func _查询积水区域实例(范围: Rect2) -> Dictionary:
	var 网格范围 := _获取积水区域网格范围(范围)
	if 网格范围.size == Vector2i.ZERO:
		return {"generation": {}, "exclusion": {}}
	if _候选缓存空间版本 == _空间索引版本 and _候选缓存网格范围 == 网格范围:
		return {
			"generation": _候选缓存生成实例,
			"exclusion": _候选缓存排除实例,
		}
	var 生成结果 := {}
	var 排除结果 := {}
	for 网格Y in range(网格范围.position.y, 网格范围.end.y):
		for 网格X in range(网格范围.position.x, 网格范围.end.x):
			var 单元 := Vector2i(网格X, 网格Y)
			if _生成区域空间网格.has(单元):
				for 实例ID in _生成区域空间网格[单元]:
					生成结果[实例ID] = true
			if _排除区域空间网格.has(单元):
				for 实例ID in _排除区域空间网格[单元]:
					排除结果[实例ID] = true
	_候选缓存网格范围 = 网格范围
	_候选缓存空间版本 = _空间索引版本
	_候选缓存生成实例 = 生成结果
	_候选缓存排除实例 = 排除结果
	return {"generation": 生成结果, "exclusion": 排除结果}

func _按变化范围刷新遮罩(旧包围盒: Rect2, 新包围盒: Rect2) -> void:
	if not is_instance_valid(_积水画布):
		return
	var 当前遮罩范围: Rect2 = _积水画布.get("mask_world_rect")
	# 首张遮罩由注册积水画布时的延迟同步统一生成。此时所有同场景区域
	# 已完成注册，不需要每个区域再额外排队一次失效请求。
	if 当前遮罩范围.size == Vector2.ZERO:
		return
	if 当前遮罩范围.intersects(旧包围盒) or 当前遮罩范围.intersects(新包围盒):
		if not _区域遮罩刷新已排队:
			_区域遮罩刷新已排队 = true
			call_deferred("_执行区域遮罩刷新")

func _执行区域遮罩刷新() -> void:
	_区域遮罩刷新已排队 = false
	if is_instance_valid(_积水画布):
		_积水画布.call("_invalidate_mask")

func 绑定视口跟随(节点: Node) -> void:
	# 让 Node2D 按主视口画布变换跟随摄像机。
	if is_instance_valid(节点) and not _视口跟随节点.has(节点):
		_视口跟随节点.append(节点)
		var 退出回调 := _视口跟随节点退出.bind(节点)
		if not 节点.tree_exiting.is_connected(退出回调):
			节点.tree_exiting.connect(退出回调, CONNECT_ONE_SHOT)
		_同步注册节点位置(节点)

func 解除视口跟随(节点: Node) -> void:
	# 取消节点的主视口同步。
	_视口跟随节点.erase(节点)
	if is_instance_valid(节点):
		var 退出回调 := _视口跟随节点退出.bind(节点)
		if 节点.tree_exiting.is_connected(退出回调):
			节点.tree_exiting.disconnect(退出回调)

func _视口跟随节点退出(节点: Node) -> void:
	_视口跟随节点.erase(节点)

func 注册积水水面(节点: Node) -> void:
	if not is_instance_valid(节点) or _积水水面.has(节点):
		return
	_积水水面.append(节点)
	_设置固定水面纹理(节点)

func 注销积水水面(节点: Node) -> void:
	_积水水面.erase(节点)

func 获取倒影纹理() -> ViewportTexture:
	# 获取管理器当前创建的倒影视口纹理。
	return _倒影纹理
## 根据当前动态遮罩判断世界坐标是否位于积水内。
func is_point_in_water(世界坐标: Vector2) -> bool:
	
	if not is_instance_valid(_积水画布):
		return false
	var 图像 := _积水画布.get("puddle_mask_image") as Image
	var 世界范围: Rect2 = _积水画布.get("mask_world_rect")
	if 图像 == null or 世界范围.size.x <= 0.0 or 世界范围.size.y <= 0.0:
		return false
	var 遮罩坐标 := (世界坐标 - 世界范围.position) / 世界范围.size
	if 遮罩坐标.x < 0.0 or 遮罩坐标.x >= 1.0 or 遮罩坐标.y < 0.0 or 遮罩坐标.y >= 1.0:
		return false
	var 像素 := Vector2i(
		clampi(int(遮罩坐标.x * 图像.get_width()), 0, 图像.get_width() - 1),
		clampi(int(遮罩坐标.y * 图像.get_height()), 0, 图像.get_height() - 1)
	)
	return 图像.get_pixelv(像素).r >= 0.5

func 添加脚步涟漪(世界坐标: Vector2) -> void:
	# 在积水中添加一个脚步波纹，最多同时维护最大脚步涟漪数个。
	if not is_point_in_water(世界坐标):
		return
	_脚步涟漪位置[_下一个脚步涟漪槽位] = 世界坐标
	_脚步涟漪开始时间[_下一个脚步涟漪槽位] = Time.get_ticks_msec() / 1000.0
	_下一个脚步涟漪槽位 = (_下一个脚步涟漪槽位 + 1) % 最大脚步涟漪数
	_存在活动脚步涟漪 = true
	_脚步涟漪已上传清空状态 = false

func _更新脚步涟漪() -> void:
	if not _存在活动脚步涟漪 and _脚步涟漪已上传清空状态:
		return
	if not is_instance_valid(_积水画布):
		return
	var 材质 := _积水画布.get("积水材质") as ShaderMaterial
	if 材质 == null:
		return
	var 当前时间 := Time.get_ticks_msec() / 1000.0
	var 持续时间 := float(_积水画布.get("脚步涟漪持续时间"))
	var 数据 := PackedVector4Array()
	数据.resize(最大脚步涟漪数)
	var 活动数量 := 0
	for 索引 in range(最大脚步涟漪数):
		var 已播放时间 := 当前时间 - _脚步涟漪开始时间[索引]
		var 启用 := 1.0 if 已播放时间 <= 持续时间 else 0.0
		if 启用 > 0.0:
			活动数量 += 1
		var 位置 := _脚步涟漪位置[索引]
		数据[索引] = Vector4(位置.x, 位置.y, 已播放时间, 启用)
	材质.set_shader_parameter("footstep_ripples", 数据)
	_存在活动脚步涟漪 = 活动数量 > 0
	_脚步涟漪已上传清空状态 = 活动数量 == 0

func 同步主视口() -> void:
	if not is_instance_valid(_积水画布):
		_积水画布 = null
		return
	var 参考节点 := _积水画布
	_主视口 = 参考节点.get_viewport()
	if _主视口 == null:
		return
	_确保倒影视口(参考节点)
	_当前倒影层掩码 = 1 << (倒影层 - 1)
	if not Engine.is_editor_hint():
		if not _已保存主视口裁剪层:
			_原主视口裁剪层 = _主视口.canvas_cull_mask
			_已保存主视口裁剪层 = true
		_主视口.canvas_cull_mask = _原主视口裁剪层 & ~_当前倒影层掩码
	_倒影视口.canvas_cull_mask = _当前倒影层掩码
	var 可见尺寸 := Vector2i(_主视口.get_visible_rect().size)
	if 可见尺寸.x <= 0 or 可见尺寸.y <= 0:
		return
	_倒影视口.size = 可见尺寸
	_倒影视口.canvas_transform = _主视口.get_canvas_transform()
	for 节点 in _视口跟随节点:
		_同步注册节点位置(节点)
	同步积水画布(_积水画布)
	_更新脚步涟漪()

func _同步注册节点位置(节点: Node) -> void:
	if not is_instance_valid(节点) or not 节点 is Node2D:
		return
	var 节点视口 := 节点.get_viewport()
	if 节点视口 != null:
		(节点 as Node2D).global_transform = 节点视口.get_canvas_transform().affine_inverse()

func 同步积水画布(节点: Node) -> void:
	if not is_instance_valid(节点) or not 节点.is_visible_in_tree():
		return
	var 材质 := 节点.get("积水材质") as ShaderMaterial
	if 材质 == null:
		return
	var 主视口 := 节点.get_viewport()
	var 视口尺寸 := 主视口.get_visible_rect().size
	var 画布变换 := 主视口.get_canvas_transform()
	var 屏幕转世界 := 画布变换.affine_inverse()
	var 世界原点 := 屏幕转世界 * Vector2.ZERO
	if not _已有Shader画布状态 or 视口尺寸 != _上次Shader视口尺寸 or 画布变换 != _上次Shader画布变换:
		材质.set_shader_parameter("viewport_size", 视口尺寸)
		材质.set_shader_parameter("world_origin", 世界原点)
		材质.set_shader_parameter("world_step_x", 屏幕转世界 * Vector2.RIGHT - 世界原点)
		材质.set_shader_parameter("world_step_y", 屏幕转世界 * Vector2.DOWN - 世界原点)
		_上次Shader视口尺寸 = 视口尺寸
		_上次Shader画布变换 = 画布变换
		_已有Shader画布状态 = true
	var 可见世界范围 := _获取可见世界范围(屏幕转世界, 视口尺寸)
	if not _遮罩包含范围(节点, 可见世界范围):
		请求生成遮罩(节点, 可见世界范围)

func _获取可见世界范围(屏幕转世界: Transform2D, 视口尺寸: Vector2) -> Rect2:
	var 左上 := 屏幕转世界 * Vector2.ZERO
	var 右上 := 屏幕转世界 * Vector2(视口尺寸.x, 0.0)
	var 左下 := 屏幕转世界 * Vector2(0.0, 视口尺寸.y)
	var 右下 := 屏幕转世界 * 视口尺寸
	var 最小位置 := Vector2(
		min(左上.x, 右上.x, 左下.x, 右下.x),
		min(左上.y, 右上.y, 左下.y, 右下.y)
	)
	var 最大位置 := Vector2(
		max(左上.x, 右上.x, 左下.x, 右下.x),
		max(左上.y, 右上.y, 左下.y, 右下.y)
	)
	return Rect2(最小位置, 最大位置 - 最小位置)

func _遮罩包含范围(节点: Node, 可见范围: Rect2) -> bool:
	if int(节点.get("_已上传遮罩版本")) != int(节点.get("_遮罩参数版本")):
		return false
	var 遮罩纹理 := 节点.get("puddle_mask_texture")
	var 遮罩范围: Rect2 = 节点.get("mask_world_rect")
	if 遮罩纹理 == null:
		return false
	# 不等可见范围越过遮罩边缘才刷新。提前在剩余一半缓冲时生成新遮罩，
	# 异步生成期间继续使用仍覆盖整个屏幕的旧遮罩，避免边缘空白闪烁。
	var 提前刷新缓冲 := _获取遮罩缓冲(节点, 可见范围.size) * 0.5
	var 刷新范围 := Rect2(
		可见范围.position - 提前刷新缓冲,
		可见范围.size + 提前刷新缓冲 * 2.0
	)
	return 遮罩范围.encloses(刷新范围)

func _获取遮罩缓冲(节点: Node, 可见尺寸: Vector2) -> Vector2:
	var 缓冲比例 := maxf(float(节点.get("遮罩缓冲比例")), 0.0)
	var 固定缓冲 := Vector2(256.0, 256.0)
	return Vector2(
		可见尺寸.x * 缓冲比例 + 固定缓冲.x,
		可见尺寸.y * 缓冲比例 + 固定缓冲.y
	)

func 请求生成遮罩(节点: Node, 可见范围: Rect2) -> void:
	if _遮罩生成线程 != null:
		var 当前版本 := int(节点.get("_遮罩参数版本"))
		if _待生成节点 == 节点 and _生成中遮罩版本 == 当前版本 and _生成中世界范围.encloses(可见范围):
			return
		_待生成节点 = 节点
		_待生成可见范围 = 可见范围
		_存在待生成请求 = true
		return
	# 固定缓冲和比例缓冲同时生效；每一侧都额外增加固定世界单位，
	# 再叠加当前可见范围对应的比例缓冲。
	var 缓冲 := _获取遮罩缓冲(节点, 可见范围.size)
	var 世界范围 := Rect2(可见范围.position - 缓冲, 可见范围.size + 缓冲 * 2.0)
	# 将遮罩原点固定到世界像素网格。相机移动触发重建时，新旧遮罩的
	# 重叠部分仍采样完全相同的世界坐标，避免轮廓因亚像素相位变化而闪动。
	var 遮罩分辨率 := maxi(1, int(节点.get("遮罩精度")))
	var 遮罩像素世界尺寸 := 世界范围.size / float(遮罩分辨率)
	世界范围.position = Vector2(
		floorf(世界范围.position.x / 遮罩像素世界尺寸.x) * 遮罩像素世界尺寸.x,
		floorf(世界范围.position.y / 遮罩像素世界尺寸.y) * 遮罩像素世界尺寸.y
	)
	_生成中世界范围 = 世界范围
	_生成中遮罩版本 = int(节点.get("_遮罩参数版本"))
	_待生成节点 = 节点
	var GDS预处理起点 := Time.get_ticks_usec()
	var 启用全图噪声 := bool(节点.get("启用全图噪声积水"))
	var 限制全图噪声 := bool(节点.get("限制全图噪声积水生成范围"))
	var 全图噪声范围 := _获取全图噪声积水范围(节点)
	var 当前范围有全图噪声 := 启用全图噪声 and (not 限制全图噪声 or 世界范围.intersects(全图噪声范围))
	var 启用生成区域 := bool(节点.get("启用指定区域积水")) and float(节点.get("干涸度")) < 0.999
	var 启用排除区域 := bool(节点.get("使用积水排除区域"))
	var 区域结果 := _收集注册区域(
		启用生成区域,
		启用排除区域,
		float(节点.get("生成区域圆角比例")),
		float(节点.get("排除区域圆角比例")),
		当前范围有全图噪声
	) if 启用生成区域 or (启用排除区域 and 当前范围有全图噪声) else {
		"generation": [],
		"exclusion": [],
	}
	var 生成多边形: Array = 区域结果.generation
	var 当前范围有生成区域 := not 生成多边形.is_empty()
	var 当前范围有水源 := 当前范围有全图噪声 or 当前范围有生成区域
	var 排除多边形: Array = 区域结果.exclusion if 当前范围有水源 else []
	var 噪声: FastNoiseLite = null
	if 当前范围有全图噪声:
		噪声 = 节点.get("积水所用噪声") as FastNoiseLite
		if 噪声 == null:
			噪声 = FastNoiseLite.new()
		噪声 = 噪声.duplicate(true)
	var 数据 := {
		"world_rect": 世界范围,
		"resolution": 遮罩分辨率,
		"edge_smoothing_radius": int(节点.get("遮罩边缘平滑采样")),
		"puddle_size": float(节点.get("积水大小")),
		"threshold": _获取积水阈值(节点),
		"dryness": float(节点.get("干涸度")),
		"edge_softness": float(节点.get("积水边缘柔和度")),
		"noise": 噪声,
		"excluded_water_polygons": 排除多边形,
		"generation_polygons": 生成多边形,
		"force_generation_polygons": 当前范围有生成区域,
		"enable_global_noise": 当前范围有全图噪声,
		"limit_global_noise": 限制全图噪声,
		"global_noise_rect": 全图噪声范围,
		"has_water_sources": 当前范围有水源,
		"generation_edge_softness": float(节点.get("积水边缘柔和度")) * float(节点.get("积水大小")),
		"version": int(节点.get("_遮罩参数版本")),
		"node_id": 节点.get_instance_id(),
	}
	数据["gds_prepare_ms"] = float(Time.get_ticks_usec() - GDS预处理起点) / 1000.0
	# 首张遮罩和后续刷新统一在后台生成。积水画布在结果完成前持续使用
	# 1x1 黑色安全遮罩，既不会阻塞首帧，也不会出现低精度替换闪烁。
	_遮罩生成线程 = Thread.new()
	var 启动错误 := _遮罩生成线程.start(_构建积水遮罩.bind(数据))
	if 启动错误 != OK:
		push_error("积水遮罩后台线程启动失败，错误码：%d" % 启动错误)
		_遮罩生成线程 = null
		_生成中世界范围 = Rect2()
		_生成中遮罩版本 = -1

func _获取积水阈值(节点: Node) -> float:
	return lerpf(0.55, -0.45, float(节点.get("积水多少")))

func _获取全图噪声积水范围(节点: Node) -> Rect2:
	var 左 := float(节点.get("全图噪声积水左边界"))
	var 上 := float(节点.get("全图噪声积水上边界"))
	var 右 := maxf(float(节点.get("全图噪声积水右边界")), 左)
	var 下 := maxf(float(节点.get("全图噪声积水下边界")), 上)
	return Rect2(Vector2(左, 上), Vector2(右 - 左, 下 - 上))

func _收集注册区域(收集生成: bool, 收集排除: bool, 生成圆角比例: float, 排除圆角比例: float, 已有全图水源: bool) -> Dictionary:
	var 生成结果: Array = []
	var 排除候选节点: Array[积水区域] = []
	var 当前场景 := get_tree().current_scene
	var 无效生成区域: Array[int] = []
	var 无效排除区域: Array[int] = []
	var 候选结果 := _查询积水区域实例(_生成中世界范围)
	var 生成候选: Dictionary = 候选结果.generation
	var 排除候选: Dictionary = 候选结果.exclusion
	if 收集生成:
		for 实例ID in 生成候选:
			var 区域 := _生成积水区域节点.get(实例ID) as 积水区域
			if 区域 == null:
				continue
			if not is_instance_valid(区域):
				无效生成区域.append(实例ID)
				continue
			if 当前场景 != null and not 当前场景.is_ancestor_of(区域):
				continue
			if _生成中世界范围.intersects(区域.获取粗略世界包围盒()):
				生成结果.append(区域.获取世界多边形(生成圆角比例))
	if 收集排除:
		for 实例ID in 排除候选:
			var 区域 := _排除积水区域节点.get(实例ID) as 积水区域
			if 区域 == null:
				continue
			if not is_instance_valid(区域):
				无效排除区域.append(实例ID)
				continue
			if 当前场景 != null and not 当前场景.is_ancestor_of(区域):
				continue
			if _生成中世界范围.intersects(区域.获取粗略世界包围盒()):
				排除候选节点.append(区域)
	for 实例ID in 无效生成区域:
		_生成积水区域节点.erase(实例ID)
		_移除积水区域空间网格(实例ID)
	for 实例ID in 无效排除区域:
		_排除积水区域节点.erase(实例ID)
		_移除积水区域空间网格(实例ID)
	var 排除结果: Array = []
	if 已有全图水源 or not 生成结果.is_empty():
		for 区域 in 排除候选节点:
			排除结果.append(区域.获取世界多边形(排除圆角比例))
	return {"generation": 生成结果, "exclusion": 排除结果}

func _构建积水遮罩(数据: Dictionary) -> Dictionary:
	var 计时起点 := Time.get_ticks_usec()
	if not bool(数据.get("has_water_sources", true)):
		var 空图像 := Image.create(1, 1, false, Image.FORMAT_R8)
		空图像.fill(Color.BLACK)
		if debug:
			var 空载耗时 := float(Time.get_ticks_usec() - 计时起点) / 1000.0
			print_debug("积水遮罩：当前范围无水源，直接返回 1x1 空遮罩，总计 %.3f ms" % 空载耗时)
		return {"image": 空图像, "world_rect": 数据.world_rect, "version": 数据.version, "node_id": 数据.node_id}
	var 分辨率 := int(数据.resolution)
	var 边缘平滑采样 := maxi(0, int(数据.get("edge_smoothing_radius", 0)))
	if is_instance_valid(_原生遮罩构建器):
		var 原生结果: Variant = _原生遮罩构建器.call(
			&"build_mask",
			数据,
			maxi(1, 遮罩并行最大分块数)
		)
		if 原生结果 is Dictionary and not 原生结果.is_empty():
			var 耗时 := float(Time.get_ticks_usec() - 计时起点) / 1000.0
			var 实际线程数 := int(原生结果.get("worker_count", 1))
			if debug:
				print_debug("积水遮罩：GDS预处理 %.3f ms；C++ %dx%d，生成区 %d / 排除区 %d，请求 %d / 实际 %d 线程，准备 %.2f，基础 %.2f，平滑(%d px) %.2f，建图 %.2f，调用总计 %.2f ms" % [
					float(数据.get("gds_prepare_ms", 0.0)), 分辨率, 分辨率, int(原生结果.get("generation_polygon_count", 0)), int(原生结果.get("exclusion_polygon_count", 0)), maxi(1, 遮罩并行最大分块数), 实际线程数,
					float(原生结果.get("setup_ms", 0.0)), float(原生结果.get("mask_ms", 0.0)),
					边缘平滑采样, float(原生结果.get("smoothing_ms", 0.0)),
					float(原生结果.get("image_ms", 0.0)), 耗时
				])
			return 原生结果
	var 回退结果 := _构建积水遮罩_gdscript(数据)
	var 回退耗时 := float(Time.get_ticks_usec() - 计时起点) / 1000.0
	if debug:print_debug("积水遮罩 GDScript：%dx%d，%d 线程，总计 %.2f ms" % [分辨率, 分辨率, maxi(1, 遮罩并行最大分块数), 回退耗时])
	return 回退结果

func _构建积水遮罩_gdscript(数据: Dictionary) -> Dictionary:
	var 世界范围: Rect2 = 数据.world_rect
	var 分辨率: int = 数据.resolution
	var 任务数 := mini(
		maxi(1, 遮罩并行最大分块数),
		maxi(1, OS.get_processor_count() - 1)
	)
	var 行数 := ceili(float(分辨率) / float(任务数))
	var 分块 := []
	for 任务索引 in range(任务数):
		var 起始行 := 任务索引 * 行数
		var 结束行 := mini(起始行 + 行数, 分辨率)
		if 起始行 >= 结束行:
			continue
		分块.append({"start": 起始行, "end": 结束行, "bytes": PackedByteArray()})
	var 组任务 := WorkerThreadPool.add_group_task(_计算遮罩分块.bind(数据, 分块, 世界范围, 分辨率), 分块.size())
	WorkerThreadPool.wait_for_group_task_completion(组任务)
	var 像素数据 := PackedByteArray()
	像素数据.resize(分辨率 * 分辨率)
	var 偏移 := 0
	for 块 in 分块:
		var 数据块: PackedByteArray = 块.bytes
		for 值 in 数据块:
			像素数据[偏移] = 值
			偏移 += 1
	var 平滑半径 := clampi(int(数据.get("edge_smoothing_radius", 0)), 0, 8)
	if 平滑半径 > 0:
		像素数据 = _平滑遮罩覆盖率(像素数据, 分辨率, 平滑半径)
	var 图像 := Image.create_from_data(分辨率, 分辨率, false, Image.FORMAT_R8, 像素数据)
	return {"image": 图像, "world_rect": 世界范围, "version": 数据.version, "node_id": 数据.node_id}

func _平滑遮罩覆盖率(源像素: PackedByteArray, 分辨率: int, 半径: int) -> PackedByteArray:
	var 权重总和 := float((半径 + 1) * (半径 + 1))
	var 水平 := PackedFloat32Array()
	水平.resize(源像素.size())
	for y in range(分辨率):
		for x in range(分辨率):
			var 总值 := 0.0
			for 偏移 in range(-半径, 半径 + 1):
				var 采样X := clampi(x + 偏移, 0, 分辨率 - 1)
				总值 += float(源像素[y * 分辨率 + 采样X]) / 255.0 * float(半径 + 1 - absi(偏移))
			水平[y * 分辨率 + x] = 总值 / 权重总和
	var 结果 := PackedByteArray()
	结果.resize(源像素.size())
	for y in range(分辨率):
		for x in range(分辨率):
			var 总值 := 0.0
			for 偏移 in range(-半径, 半径 + 1):
				var 采样Y := clampi(y + 偏移, 0, 分辨率 - 1)
				总值 += 水平[采样Y * 分辨率 + x] * float(半径 + 1 - absi(偏移))
			结果[y * 分辨率 + x] = roundi(clampf(总值 / 权重总和, 0.0, 1.0) * 255.0)
	return 结果

func _计算遮罩分块(索引: int, 数据: Dictionary, 分块: Array, 世界范围: Rect2, 分辨率: int) -> void:
	var 块: Dictionary = 分块[索引]
	var 起始行: int = 块.start
	var 结束行: int = 块.end
	var 宽度 := 分辨率
	var 输出 := PackedByteArray()
	输出.resize((结束行 - 起始行) * 宽度)
	var 噪声: FastNoiseLite = null
	if bool(数据.enable_global_noise):
		var 源噪声 := 数据.noise as FastNoiseLite
		噪声 = 源噪声.duplicate(true) if 源噪声 != null else FastNoiseLite.new()
	var 积水大小: float = 数据.puddle_size
	var 柔和度: float = 数据.edge_softness
	var 干涸度: float = 数据.dryness
	var 排除柔和度 := 柔和度 * 积水大小
	var 遮罩像素世界尺寸 := maxf(世界范围.size.x, 世界范围.size.y) / float(分辨率)
	排除柔和度 = maxf(排除柔和度, 遮罩像素世界尺寸 * 1.5)
	var 全局阈值 := lerpf(数据.threshold, 1.0 + 柔和度, 干涸度)
	var 腐蚀距离 := 干涸度 * 积水大小
	var 噪声最小X := 0
	var 噪声最大X := 分辨率
	var 噪声最小Y := 0
	var 噪声最大Y := 分辨率
	var 噪声范围与遮罩相交: bool = bool(数据.enable_global_noise) and 噪声 != null
	if 数据.enable_global_noise and 数据.limit_global_noise:
		var 相交范围 := 世界范围.intersection(数据.global_noise_rect)
		噪声范围与遮罩相交 = 相交范围.has_area()
		if 噪声范围与遮罩相交:
			var 像素尺寸 := 世界范围.size / float(分辨率)
			噪声最小X = clampi(ceili((相交范围.position.x - 世界范围.position.x) / 像素尺寸.x - 0.5), 0, 分辨率)
			噪声最大X = clampi(ceili((相交范围.end.x - 世界范围.position.x) / 像素尺寸.x - 0.5), 0, 分辨率)
			噪声最小Y = clampi(ceili((相交范围.position.y - 世界范围.position.y) / 像素尺寸.y - 0.5), 0, 分辨率)
			噪声最大Y = clampi(ceili((相交范围.end.y - 世界范围.position.y) / 像素尺寸.y - 0.5), 0, 分辨率)
	for y in range(起始行, 结束行):
		var 当前行计算噪声 := 噪声范围与遮罩相交 and y >= 噪声最小Y and y < 噪声最大Y
		for x in range(宽度):
			var 位置 := 世界范围.position + Vector2((float(x) + 0.5) / 分辨率, (float(y) + 0.5) / 分辨率) * 世界范围.size
			var 遮罩值 := 0.0
			if 当前行计算噪声 and x >= 噪声最小X and x < 噪声最大X:
				var 噪声值 := 噪声.get_noise_2d(位置.x / 积水大小, 位置.y / 积水大小)
				遮罩值 = smoothstep(全局阈值 - 柔和度, 全局阈值 + 柔和度, 噪声值)
			if 数据.force_generation_polygons and 干涸度 < 0.999:
				for 多边形: PackedVector2Array in 数据.generation_polygons:
					遮罩值 = maxf(遮罩值, _多边形内侧遮罩(位置, 多边形, 数据.generation_edge_softness, 腐蚀距离))
			for 多边形: PackedVector2Array in 数据.excluded_water_polygons:
				遮罩值 *= _多边形排除遮罩(位置, 多边形, 排除柔和度)
			输出[(y - 起始行) * 宽度 + x] = roundi(clampf(遮罩值, 0.0, 1.0) * 255.0)
	块.bytes = 输出

func _apply_completed_mask() -> void:
	if _遮罩生成线程 == null or _遮罩生成线程.is_alive():
		return
	var 回收起点 := Time.get_ticks_usec()
	var 结果: Dictionary = _遮罩生成线程.wait_to_finish()
	var 回收毫秒 := float(Time.get_ticks_usec() - 回收起点) / 1000.0
	_遮罩生成线程 = null
	_生成中世界范围 = Rect2()
	_生成中遮罩版本 = -1
	var 节点 := instance_from_id(int(结果.node_id))
	if is_instance_valid(节点):
		# 连续调参时不要丢弃旧结果；先显示它，再继续生成最新版本，
		# 否则每次结果完成都会因版本变化被丢弃，画面要等松手才更新。
		var 上传起点 := Time.get_ticks_usec()
		节点.call("_管理器上传遮罩", 结果.image, 结果.world_rect, int(结果.version))
		var 上传毫秒 := float(Time.get_ticks_usec() - 上传起点) / 1000.0
		if debug and (回收毫秒 > 2.0 or 上传毫秒 > 2.0):
			print_debug("积水遮罩主线程：回收 %.2f ms，双缓冲上传 %.2f ms" % [回收毫秒, 上传毫秒])
	if _存在待生成请求:
		var 待处理节点 := _待生成节点
		var 待处理范围 := _待生成可见范围
		_存在待生成请求 = false
		if is_instance_valid(待处理节点) and not _遮罩包含范围(待处理节点, 待处理范围):
			请求生成遮罩(待处理节点, 待处理范围)

func _多边形内侧遮罩(位置: Vector2, 多边形: PackedVector2Array, 柔和度: float, 腐蚀距离: float) -> float:
	if 多边形.size() < 3 or not Geometry2D.is_point_in_polygon(位置, 多边形):
		return 0.0
	var 最小距离 := INF
	for 索引 in range(多边形.size()):
		var 起点 := 多边形[索引]
		var 终点 := 多边形[(索引 + 1) % 多边形.size()]
		var 最近点 := Geometry2D.get_closest_point_to_segment(位置, 起点, 终点)
		最小距离 = minf(最小距离, 位置.distance_to(最近点))
	return smoothstep(腐蚀距离, 腐蚀距离 + 柔和度, 最小距离)

func _多边形排除遮罩(位置: Vector2, 多边形: PackedVector2Array, 柔和度: float) -> float:
	if 多边形.size() < 3:
		return 1.0
	var 在内部 := Geometry2D.is_point_in_polygon(位置, 多边形)
	if 柔和度 <= 0.0:
		return 0.0 if 在内部 else 1.0
	var 最小距离 := INF
	for 索引 in range(多边形.size()):
		var 起点 := 多边形[索引]
		var 终点 := 多边形[(索引 + 1) % 多边形.size()]
		var 最近点 := Geometry2D.get_closest_point_to_segment(位置, 起点, 终点)
		最小距离 = minf(最小距离, 位置.distance_to(最近点))
	if 在内部:
		return 0.0
	return smoothstep(0.0, 柔和度, 最小距离)

func _设置固定水面纹理(节点: Node) -> void:
	if is_instance_valid(节点) and 节点.has_method("_管理器设置倒影纹理"):
		节点.call("_管理器设置倒影纹理", _倒影纹理)

func _确保倒影视口(参考节点: Node) -> void:
	if _倒影视口 != null and is_instance_valid(_倒影视口):
		return
	_倒影视口 = SubViewport.new()
	_倒影视口.name = "积水倒影视口"
	_倒影视口.transparent_bg = true
	_倒影视口.handle_input_locally = false
	_倒影视口.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_倒影视口.canvas_item_default_texture_filter = Viewport.DEFAULT_CANVAS_ITEM_TEXTURE_FILTER_NEAREST
	_主视口 = 参考节点.get_viewport()
	if _主视口 != null:
		_倒影视口.world_2d = _主视口.world_2d
	add_child(_倒影视口)
	_倒影纹理 = _倒影视口.get_texture()
	if is_instance_valid(_积水画布):
		_积水画布.call("_管理器设置倒影纹理", _倒影纹理)
	for 节点 in _积水水面:
		if is_instance_valid(节点):
			_设置固定水面纹理(节点)

func _销毁倒影视口() -> void:
	if _主视口 != null and _已保存主视口裁剪层 and is_instance_valid(_主视口):
		_主视口.canvas_cull_mask = _原主视口裁剪层
	_已保存主视口裁剪层 = false
	if is_instance_valid(_倒影视口):
		_倒影视口.queue_free()
	_倒影视口 = null
	_倒影纹理 = null
	for 节点 in _积水水面:
		if is_instance_valid(节点):
			_设置固定水面纹理(节点)
