@tool
extends EditorPlugin

const 积水画布脚本 := preload("res://addons/积水系统/scripts/积水画布.gd")
const 积水画布图标 := preload("res://addons/积水系统/icon/积水画布.svg")
const 区域脚本 := preload("res://addons/积水系统/scripts/积水区域.gd")
const 区域图标 := preload("res://addons/积水系统/icon/积水区域.svg")
const 积水水面脚本 := preload("res://addons/积水系统/scripts/积水水面.gd")
const 积水水面图标 := preload("res://addons/积水系统/icon/积水水面.svg")
const 积水倒影脚本 := preload("res://addons/积水系统/scripts/积水倒影.gd")
const 积水倒影图标 := preload("res://addons/积水系统/icon/积水倒影.svg")
const 管理器路径 := "res://addons/积水系统/scripts/积水管理器.gd"

func _enter_tree() -> void:
	if not FileAccess.file_exists("res://addons/积水系统/bin/puddle_mask.windows.template_debug.x86_64.dll"):
		push_warning("积水系统原生遮罩构建器未找到，将自动使用 GDScript 回退实现。")
	add_custom_type("积水画布", "Sprite2D", 积水画布脚本, 积水画布图标)
	add_custom_type("积水区域", "Polygon2D", 区域脚本, 区域图标)
	add_custom_type("积水水面", "Node2D", 积水水面脚本, 积水水面图标)
	add_custom_type("积水倒影", "Node2D", 积水倒影脚本, 积水倒影图标)
	var 自动加载路径 := "autoload/积水管理器"
	if not ProjectSettings.has_setting(自动加载路径) or ProjectSettings.get_setting(自动加载路径) != "*%s" % 管理器路径:
		ProjectSettings.set_setting(自动加载路径, "*%s" % 管理器路径)
		ProjectSettings.save()

func _exit_tree() -> void:
	remove_custom_type("积水画布")
	remove_custom_type("积水区域")
	remove_custom_type("积水水面")
	remove_custom_type("积水倒影")
	if ProjectSettings.has_setting("autoload/积水管理器"):
		remove_autoload_singleton("积水管理器")
