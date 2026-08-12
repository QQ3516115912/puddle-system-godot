@tool
extends EditorPlugin

const PUDDLE_CANVAS_SCRIPT := preload("res://addons/puddle_system/scripts/puddle_canvas.gd")
const PUDDLE_CANVAS_ICON := preload("res://addons/puddle_system/icon/puddle_canvas.svg")
const PUDDLE_REGION_SCRIPT := preload("res://addons/puddle_system/scripts/puddle_region.gd")
const PUDDLE_REGION_ICON := preload("res://addons/puddle_system/icon/puddle_region.svg")
const PUDDLE_SURFACE_SCRIPT := preload("res://addons/puddle_system/scripts/puddle_surface.gd")
const PUDDLE_SURFACE_ICON := preload("res://addons/puddle_system/icon/puddle_surface.svg")
const PUDDLE_REFLECTION_SCRIPT := preload("res://addons/puddle_system/scripts/puddle_reflection.gd")
const PUDDLE_REFLECTION_ICON := preload("res://addons/puddle_system/icon/puddle_reflection.svg")
const MANAGER_PATH := "res://addons/puddle_system/scripts/puddle_manager.gd"

func _enter_tree() -> void:
	if not FileAccess.file_exists("res://addons/puddle_system/bin/puddle_mask.windows.template_debug.x86_64.dll"):
		push_warning("The native puddle mask builder was not found. Falling back to GDScript.")
	add_custom_type("PuddleCanvas", "Sprite2D", PUDDLE_CANVAS_SCRIPT, PUDDLE_CANVAS_ICON)
	add_custom_type("PuddleRegion", "Polygon2D", PUDDLE_REGION_SCRIPT, PUDDLE_REGION_ICON)
	add_custom_type("PuddleSurface", "Node2D", PUDDLE_SURFACE_SCRIPT, PUDDLE_SURFACE_ICON)
	add_custom_type("PuddleReflection", "Node2D", PUDDLE_REFLECTION_SCRIPT, PUDDLE_REFLECTION_ICON)
	var autoload_path := "autoload/PuddleManager"
	if not ProjectSettings.has_setting(autoload_path) or ProjectSettings.get_setting(autoload_path) != "*%s" % MANAGER_PATH:
		ProjectSettings.set_setting(autoload_path, "*%s" % MANAGER_PATH)
		ProjectSettings.save()

func _exit_tree() -> void:
	remove_custom_type("PuddleCanvas")
	remove_custom_type("PuddleRegion")
	remove_custom_type("PuddleSurface")
	remove_custom_type("PuddleReflection")
	if ProjectSettings.has_setting("autoload/PuddleManager"):
		remove_autoload_singleton("PuddleManager")
