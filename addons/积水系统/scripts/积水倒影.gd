@icon("res://addons/积水系统/icon/积水倒影.svg")
extends Node2D
class_name 积水倒影

@export var 是否受倒影变换影响:=true:
	set(v):
		if v==是否受倒影变换影响:
			return
		是否受倒影变换影响=v
		_是否受倒影变换影响_change.emit(v)
var parent: Node2D
var 初始位置 := Vector2.ZERO
var 初始旋转 := 0.0
var 初始缩放 := Vector2.ONE
var 初始倾斜 := 0.0
var 当前拉伸比例 := 1.0
var 当前倾斜角度 := 0.0
var 管理器: Node
var _上次父变换 := Transform2D()
var _已有父变换 := false
var _变换需要同步 := true

signal _是否受倒影变换影响_change(bl:bool)
func _ready() -> void:
	管理器 = get_node_or_null("/root/积水管理器")
	if 管理器 == null:
		return
	_是否受倒影变换影响_change.connect(_on_是否受倒影变换影响_change)
	parent = get_parent() as Node2D
	top_level = true
	_添加倒影(self)
	var 初始变换 := transform
	初始位置 = 初始变换.get_origin()
	初始旋转 = 初始变换.get_rotation()
	初始缩放 = 初始变换.get_scale()
	初始倾斜 = 初始变换.get_skew()
	_on_是否受倒影变换影响_change(是否受倒影变换影响)
func _添加倒影(节点: Node) -> void:
	_设置单个节点(节点)
	_设置子节点(节点)
func _设置单个节点(节点: Node) -> void:
	if not 节点.child_entered_tree.is_connected(_添加倒影):
		节点.child_entered_tree.connect(_添加倒影)
	if not 节点 is CanvasItem:
		return
	var 画布节点 := 节点 as CanvasItem
	画布节点.visibility_layer = 1 << (管理器.倒影层 - 1)
	画布节点.light_mask = 1 << (管理器.倒影层 - 1)
	if "range_item_cull_mask" in 画布节点:
		画布节点.range_item_cull_mask = 1 << (管理器.倒影层 - 1)

func _设置子节点(父节点: Node = self) -> void:
	for 子节点 in 父节点.get_children():
		_添加倒影(子节点)
func _on_是否受倒影变换影响_change(bl:bool):
	if 管理器==null:
		return
	_变换需要同步 = true
	if bl:
		当前倾斜角度 = 管理器.倒影倾斜角度
		当前拉伸比例 = 管理器.倒影拉伸比例
		if not 管理器.倒影倾斜角度_change.is_connected(on_倒影倾斜角度_change):
			管理器.倒影倾斜角度_change.connect(on_倒影倾斜角度_change)
		if not 管理器.倒影拉伸比例_change.is_connected(on_倒影拉伸比例_change):
			管理器.倒影拉伸比例_change.connect(on_倒影拉伸比例_change)
	else:
		当前倾斜角度 = 0.0
		当前拉伸比例 = 1.0
		if 管理器.倒影倾斜角度_change.is_connected(on_倒影倾斜角度_change):
			管理器.倒影倾斜角度_change.disconnect(on_倒影倾斜角度_change)
		if 管理器.倒影拉伸比例_change.is_connected(on_倒影拉伸比例_change):
			管理器.倒影拉伸比例_change.disconnect(on_倒影拉伸比例_change)
		_变换需要同步 = true
	同步父节点变换()

func _process(_delta: float) -> void:
	同步父节点变换()

func 同步父节点变换() -> void:
	if not is_instance_valid(parent):
		return
	if not parent.is_inside_tree():
		return
	var 父变换 := parent.global_transform
	if not _变换需要同步 and _已有父变换 and 父变换 == _上次父变换:
		return
	var 行列式 := 父变换.x.cross(父变换.y)
	var 镜像补偿 := -1.0 if 行列式 < 0.0 else 1.0
	var 局部变换 := Transform2D(
		初始旋转,
		Vector2(初始缩放.x, 初始缩放.y * 当前拉伸比例),
		初始倾斜 + deg_to_rad(当前倾斜角度) * 镜像补偿,
		初始位置
	)
	global_transform = 父变换 * 局部变换
	_上次父变换 = 父变换
	_已有父变换 = true
	_变换需要同步 = false

func on_倒影倾斜角度_change(值: float) -> void:
	当前倾斜角度 = 值
	_变换需要同步 = true

func on_倒影拉伸比例_change(值: float) -> void:
	当前拉伸比例 = 值
	_变换需要同步 = true
