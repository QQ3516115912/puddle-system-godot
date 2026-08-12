# Puddle System

A dynamic 2D puddle and water reflection plugin for Godot 4.4 and newer.

## Features

- Infinite world-space puddles generated from `FastNoiseLite`.
- Generation and exclusion regions with curved polygon boundaries.
- Optional world bounds for global noise puddles.
- Dryness, edge softness, mask smoothing, and buffered mask updates.
- Dynamic reflections rendered through an automatically managed `SubViewport`.
- Wind waves, animated borders, footstep ripples, and rain ripples.
- Static river and lake surfaces through the `PuddleSurface` container.
- Native Windows x86_64 mask generation with a GDScript fallback.

## Installation

1. Copy `addons/puddle_system` into your project's `addons` directory.
2. Open **Project > Project Settings > Plugins**.
3. Enable **Puddle System**.
4. The plugin automatically creates this Autoload:

   ```text
   PuddleManager -> res://addons/puddle_system/scripts/puddle_manager.gd
   ```

If it is missing, add the script manually as an Autoload named `PuddleManager`.

## Platform Support

The release includes native Debug and Release libraries for Windows x86_64. On unsupported platforms, the plugin automatically uses its GDScript fallback. The fallback preserves functionality but can be slower with high mask resolutions or many regions.

## Quick Start

### Dynamic Puddles

1. Add a `PuddleCanvas` node to the scene.
2. Keep it under an unscaled canvas parent when possible.
3. Configure puddle generation, appearance, wind, rain, and footstep properties in the Inspector.

Only one `PuddleCanvas` can be active at a time. It registers itself with `PuddleManager` and receives the generated mask and reflection texture automatically.

### Custom Regions

Add a `PuddleRegion` node, draw its polygon, and choose its `region_type`:

- `GENERATE`: forces puddles inside the region.
- `EXCLUDE`: removes puddles from the region and takes priority over generation.

Regions automatically update cached world geometry after movement, rotation, scaling, polygon edits, or type changes.

### Reflections

Add `PuddleReflection` to an object that should appear in water, then place reflected visual nodes below it. The container recursively configures descendant `CanvasItem` nodes for the reflection layer.

The default reflection layer is layer `20`, defined by `PuddleManager.REFLECTION_LAYER`.

### Static Water Surfaces

Add a `PuddleSurface` container for rivers, lakes, or other permanent water. Place `Sprite2D`, `Polygon2D`, `TileMapLayer`, or other `CanvasItem` descendants below it. The container applies the shared water material and receives the reflection texture automatically.

## Public API

```gdscript
if PuddleManager.is_point_in_water(global_position):
	PuddleManager.add_footstep_ripple(global_position)

PuddleManager.bind_viewport_follower(node)
PuddleManager.unbind_viewport_follower(node)

var reflection_texture: ViewportTexture = PuddleManager.get_reflection_texture()
```

## Main PuddleCanvas Properties

| Property | Purpose |
| --- | --- |
| `puddles_enabled` | Enables or hides the puddle system. |
| `puddle_noise` | Noise resource used for world-space puddle generation. |
| `puddle_amount` | Controls global noise coverage. |
| `puddle_size` | Controls the world-space size of puddle shapes. |
| `dryness` | Shrinks global and region-generated puddles. |
| `puddle_edge_softness` | Controls transition width around puddle boundaries. |
| `mask_resolution` | Sets the square mask resolution. |
| `mask_edge_smoothing_radius` | Smooths mask coverage before upload. |
| `mask_buffer_ratio` | Adds off-screen mask coverage to reduce refresh artifacts. |
| `enable_global_noise_puddles` | Enables noise-generated puddles across the world. |
| `enable_generation_regions` | Enables `GENERATE` regions. |
| `enable_exclusion_regions` | Enables `EXCLUDE` regions. |

## Troubleshooting

### No puddles are visible

- Confirm the plugin is enabled and `/root/PuddleManager` exists.
- Confirm exactly one `PuddleCanvas` is active.
- Check `puddles_enabled`, `enable_global_noise_puddles`, `enable_generation_regions`, and `dryness`.
- For region-only water, add a `PuddleRegion`, select `GENERATE`, and draw a polygon.

### Reflections are missing

- Add reflected visuals below a `PuddleReflection` node.
- Confirm reflection layer `20` is available.
- Do not assign a static reflection texture; `PuddleManager` injects the runtime texture.

### Performance is low

- Lower `mask_resolution` or `mask_edge_smoothing_radius`.
- Disable unused rain ripples.
- Reduce the number of overlapping regions.
- Confirm the Windows native library loaded when running on Windows x86_64.

## Directory Structure

```text
addons/puddle_system/
├─ bin/
├─ icon/
│  ├─ puddle_canvas.svg
│  ├─ puddle_reflection.svg
│  ├─ puddle_region.svg
│  └─ puddle_surface.svg
├─ scripts/
│  ├─ puddle_canvas.gd
│  ├─ puddle_manager.gd
│  ├─ puddle_reflection.gd
│  ├─ puddle_region.gd
│  └─ puddle_surface.gd
├─ shader/
│  ├─ puddle.gdshader
│  └─ water_surface.gdshader
├─ LICENSE
├─ plugin.cfg
├─ plugin.gd
└─ puddle_mask.gdextension
```

## License

MIT License. See `LICENSE`.
