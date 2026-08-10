@tool
@icon("res://addons/积水系统/icon/积水区域.svg")
extends Polygon2D
class_name 积水区域

enum 区域类型 {
	生成,## 在区域内会强制产生积水
	排除,## 区域内不会生成积水，优先级高于生成
}

## 区域用途：生成会强制产生积水，排除会从积水中裁掉该区域。
@export var 积水区域类型: 区域类型 = 区域类型.生成:
	set(value):
		if 积水区域类型 == value:
			return
		var 旧类型 := 积水区域类型
		积水区域类型 = value
		_圆角缓存.clear()
		if is_node_ready():
			var 管理器 := get_node_or_null("/root/积水管理器")
			if 管理器 != null and 管理器.has_method("更新积水区域类型"):
				管理器.更新积水区域类型(self, 旧类型, value)

var _上次局部顶点 := PackedVector2Array()
var _上次全局变换 := Transform2D()
var _世界顶点 := PackedVector2Array()
var _粗略世界包围盒 := Rect2()
var _圆角缓存: Dictionary = {}
var _更新已排队 := false

func _ready() -> void:
	set_notify_transform(true)
	_刷新区域缓存(false)
	if not Engine.is_editor_hint():
		visible = false
	var 管理器 := get_node_or_null("/root/积水管理器")
	if 管理器 != null:
		管理器.注册积水区域(self)

func _exit_tree() -> void:
	var 管理器 := get_node_or_null("/root/积水管理器")
	if 管理器 != null:
		管理器.注销积水区域(self, _粗略世界包围盒)

func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSFORM_CHANGED:
		_请求刷新区域缓存()
	elif what == NOTIFICATION_DRAW and polygon != _上次局部顶点:
		_请求刷新区域缓存()

func _请求刷新区域缓存() -> void:
	if not is_node_ready() or _更新已排队:
		return
	_更新已排队 = true
	call_deferred("_执行区域缓存刷新")

func _执行区域缓存刷新() -> void:
	_更新已排队 = false
	if not is_inside_tree():
		return
	_刷新区域缓存(true)

func _刷新区域缓存(通知管理器: bool) -> void:
	var 当前局部顶点 := polygon
	var 当前全局变换 := global_transform
	if 当前局部顶点 == _上次局部顶点 and 当前全局变换 == _上次全局变换:
		return
	var 旧包围盒 := _粗略世界包围盒
	_上次局部顶点 = 当前局部顶点
	_上次全局变换 = 当前全局变换
	_世界顶点 = PackedVector2Array()
	for 点 in 当前局部顶点:
		_世界顶点.append(当前全局变换 * 点)
	_粗略世界包围盒 = _计算粗略包围盒(_世界顶点)
	_圆角缓存.clear()
	if 通知管理器:
		var 管理器 := get_node_or_null("/root/积水管理器")
		if 管理器 != null:
			管理器.更新积水区域(self, 旧包围盒, _粗略世界包围盒)

func 获取区域类型() -> int:
	return 积水区域类型

func 获取粗略世界包围盒() -> Rect2:
	return _粗略世界包围盒

func 获取世界多边形(圆角比例: float) -> PackedVector2Array:
	if 圆角比例 <= 0.0 or _世界顶点.size() < 3:
		return _世界顶点
	var 缓存键 := snappedf(圆角比例, 0.001)
	if _圆角缓存.has(缓存键):
		return _圆角缓存[缓存键]
	var 曲线多边形 := _曲线化多边形边界(_世界顶点, 圆角比例, 获取区域类型() == 区域类型.生成)
	var 结果 := 曲线多边形 if 曲线多边形.size() >= 3 else _世界顶点
	_圆角缓存[缓存键] = 结果
	return 结果

func _计算粗略包围盒(顶点: PackedVector2Array) -> Rect2:
	if 顶点.is_empty():
		return Rect2()
	var 最小位置 := 顶点[0]
	var 最大位置 := 顶点[0]
	var 最大边长 := 0.0
	for 索引 in range(顶点.size()):
		var 点 := 顶点[索引]
		最小位置 = 最小位置.min(点)
		最大位置 = 最大位置.max(点)
		最大边长 = maxf(最大边长, 点.distance_to(顶点[(索引 + 1) % 顶点.size()]))
	# 圆角控制点最多偏移半条边，扩大包围盒可避免曲线外凸时被错误裁掉。
	return Rect2(最小位置, 最大位置 - 最小位置).grow(最大边长 * 0.5)

func _曲线化多边形边界(顶点: PackedVector2Array, 圆角比例: float, 反向圆弧: bool) -> PackedVector2Array:
	if 顶点.size() < 3 or 圆角比例 <= 0.0:
		return 顶点
	var 有向面积 := 0.0
	for 索引 in range(顶点.size()):
		有向面积 += 顶点[索引].cross(顶点[(索引 + 1) % 顶点.size()])
	var 环绕方向 := 1.0 if 有向面积 >= 0.0 else -1.0
	var 圆角系数 := clampf(圆角比例 / 100.0, 0.0, 1.0)
	var 结果 := PackedVector2Array()
	for 索引 in range(顶点.size()):
		var 起点 := 顶点[索引]
		var 终点 := 顶点[(索引 + 1) % 顶点.size()]
		var 边向量 := 终点 - 起点
		if 边向量.length_squared() <= 0.0001:
			continue
		var 内侧法线 := Vector2(-边向量.y, 边向量.x).normalized() * 环绕方向
		if 反向圆弧:
			内侧法线 = -内侧法线
		var 控制点 := (起点 + 终点) * 0.5 + 内侧法线 * 边向量.length() * 0.5 * 圆角系数
		for 步骤 in range(7):
			if 索引 > 0 and 步骤 == 0:
				continue
			var 曲线进度 := float(步骤) / 6.0
			var 反向进度 := 1.0 - 曲线进度
			结果.append(起点 * 反向进度 * 反向进度 + 控制点 * 2.0 * 反向进度 * 曲线进度 + 终点 * 曲线进度 * 曲线进度)
	if 结果.size() > 1 and 结果[0].is_equal_approx(结果[结果.size() - 1]):
		结果.remove_at(结果.size() - 1)
	return 结果
