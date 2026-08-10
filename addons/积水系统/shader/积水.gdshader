shader_type canvas_item;

// 所有 uniform 都由“积水画布.gd”的中文检查器参数统一维护。
group_uniforms Script_Driven;
// 以下参数由积水画布/积水管理器自动填写，一般不需要手动修改。
// 当前 Sprite2D 的原始纹理，同时作为倒影纹理来源。
uniform sampler2D puddle_mask : repeat_disable, filter_linear;
// 动态积水遮罩左上角的世界坐标。
uniform vec2 mask_world_origin;
// 动态积水遮罩覆盖的世界尺寸。
uniform vec2 mask_world_size;
// CPU 遮罩是否已编码为以 0.5 分隔水/干两侧的平滑距离值。
uniform bool mask_threshold_smoothing = true;
// 主视口的像素尺寸，用于把屏幕 UV 换算为像素坐标。
uniform vec2 viewport_size = vec2(1152.0, 648.0);
// 屏幕左上角对应的世界坐标。
uniform vec2 world_origin = vec2(0.0);
// 屏幕水平方向一个像素对应的世界坐标增量。
uniform vec2 world_step_x = vec2(1.0, 0.0);
// 屏幕垂直方向一个像素对应的世界坐标增量。
uniform vec2 world_step_y = vec2(0.0, 1.0);

// 积水底色；RGB 为颜色，Alpha 为底色混合透明度。
uniform vec4 water_color : source_color = vec4(0.10, 0.28, 0.42, 0.24);
// 倒影混入强度，0 为不显示倒影，1 为完全按倒影权重混合。
uniform float reflection_opacity : hint_range(0.0, 1.0, 0.01) = 0.65;
// 是否在积水遮罩内侧绘制边缘高光。
uniform bool water_edge_enabled = true;
// 是否让边框周期性向积水外侧扩张并收回。
uniform bool water_edge_animation_enabled = false;
// 动效最大外扩距离，单位为世界坐标。
uniform float water_edge_animation_strength : hint_range(0.0, 32.0, 0.5) = 4.0;
// 沿边框局部闪烁的高光强度。
uniform float water_edge_shimmer_strength : hint_range(0.0, 1.0, 0.01) = 0.35;
// 积水边缘颜色；Alpha 控制边缘强度。
uniform vec4 water_edge_color : source_color = vec4(1.0, 1.0, 1.0, 0.65);
// 积水边缘向水内延伸的宽度，单位为世界坐标。
uniform float water_edge_width : hint_range(0.0, 32.0, 0.5) = 4.0;
// 边框靠水面内缘的颜色混合宽度，单位为世界坐标。
uniform float water_edge_blend_width : hint_range(0.0, 32.0, 0.5) = 4.0;

// 是否启用风扰动。关闭后会保留脚步和雨滴波纹。
uniform bool wind_disturbance_enabled = true;
// 风纹传播方向，Shader 内部会自动归一化。
uniform vec2 wind_direction = vec2(1.0, 0.25);
// 风纹的世界坐标波长，数值越小波纹越密。
uniform float wind_ripple_size : hint_range(8.0, 160.0, 1.0) = 42.0;
// 风纹移动速度，0 表示静止。
uniform float wind_speed : hint_range(0.0, 8.0, 0.05) = 1.4;
// 水面高度差转为坡度的放大倍数，同时影响高光和倒影扭曲。
uniform float surface_roughness : hint_range(0.0, 20.0, 0.1) = 8.0;
// 倒影对水面坡度的响应强度，越大倒影越容易被波纹拉开。
uniform float reflection_response : hint_range(0.0, 12.0, 0.1) = 3.0;
// 水面波峰额外高光强度；设为 0 不会关闭倒影。
uniform float ripple_highlight : hint_range(0.0, 0.5, 0.01) = 0.12;

// 脚步波纹向外扩散的速度（世界单位/秒）。
uniform float footstep_ripple_speed : hint_range(10.0, 300.0, 1.0) = 90.0;
// 单个脚步波纹的持续时间（秒）。
uniform float footstep_ripple_duration : hint_range(0.1, 4.0, 0.05) = 1.2;
// 脚步波纹圆环的宽度。
uniform float footstep_ripple_width : hint_range(1.0, 30.0, 0.5) = 7.0;
// 脚步波纹对水面坡度的影响强度。
uniform float footstep_ripple_strength : hint_range(0.0, 4.0, 0.05) = 1.8;
// 脚步波纹额外高光强度。
uniform float footstep_ripple_highlight : hint_range(0.0, 1.0, 0.01) = 0.45;

// 是否启用程序化雨滴波纹；不占用脚步波纹数组。
uniform bool rain_ripples_enabled = false;
// 雨滴落点网格间距，越大雨滴越稀疏。
uniform float rain_ripple_spacing : hint_range(80.0, 400.0, 5.0) = 180.0;
// 同一网格生成下一次雨滴的时间间隔。
uniform float rain_ripple_interval : hint_range(0.15, 4.0, 0.05) = 0.8;
// 雨滴波纹扩散速度。
uniform float rain_ripple_speed : hint_range(10.0, 180.0, 1.0) = 55.0;
// 单个雨滴波纹的持续时间。
uniform float rain_ripple_duration : hint_range(0.1, 3.0, 0.05) = 1.1;
// 雨滴圆环宽度。
uniform float rain_ripple_width : hint_range(0.5, 16.0, 0.5) = 2.5;
// 雨滴波纹对水面坡度的影响强度。
uniform float rain_ripple_strength : hint_range(0.0, 4.0, 0.05) = 0.75;
// 雨滴波纹额外高光强度。
uniform float rain_ripple_highlight : hint_range(0.0, 1.0, 0.01) = 0.3;

// 脚步波纹数据：xy 为世界坐标，z 为已播放时间，w 为启用标记。
uniform vec4 footstep_ripples[16];
group_uniforms;

// 叠加三组方向和频率略有差异的行波，构造随风移动的水面高度场。
float water_height(vec2 world_position, float time) {
	if (!wind_disturbance_enabled) {
		return 0.0;
	}
	vec2 wind = normalize(wind_direction + vec2(0.0001, 0.0));
	vec2 cross_wind = vec2(-wind.y, wind.x);
	float frequency = 6.283185 / max(wind_ripple_size, 0.001);
	float height = sin(dot(world_position, wind) * frequency - time * wind_speed);
	height += sin(
		dot(world_position, normalize(wind + cross_wind * 0.32))
			* frequency * 1.73
		- time * wind_speed * 1.31
	) * 0.42;
	height += sin(
		dot(world_position, normalize(wind - cross_wind * 0.21))
			* frequency * 2.47
		- time * wind_speed * 1.82
	) * 0.20;
	return height / 1.62;
}

// 把全部脚步圆环合成为同一个带正负相位的高度场。
// 波峰相遇会增强，波峰与波谷相遇会抵消，从而产生干涉条纹。
float footstep_wave_height(vec2 world_position) {
	float combined_height = 0.0;
	for (int ripple_index = 0; ripple_index < 16; ripple_index++) {
		vec4 ripple_data = footstep_ripples[ripple_index];
		float age = ripple_data.z;
		float active = ripple_data.w
			* step(0.0, age)
			* step(age, footstep_ripple_duration);
		float radius = age * footstep_ripple_speed;
		float wave_offset = distance(world_position, ripple_data.xy) - radius;
		// 单峰脉冲只生成一个圆环，不再用正弦的正负半波生成双环。
		float pulse = 1.0 - smoothstep(
			0.0,
			footstep_ripple_width,
			abs(wave_offset)
		);
		float fade = 1.0 - clamp(
			age / max(footstep_ripple_duration, 0.001),
			0.0,
			1.0
		);
		// 相邻槽位使用相反相位，使交叉处既可能增强也可能抵消。
		float polarity = mix(
			1.0,
			-1.0,
			mod(float(ripple_index), 2.0)
		);
		combined_height += pulse * fade * active * polarity;
	}
	return combined_height;
}

float random_from_position(vec2 value) {
	vec2 random_value = fract(value * vec2(0.1031, 0.1030));
	random_value += dot(random_value, random_value.yx + 33.33);
	return fract((random_value.x + random_value.y) * random_value.x);
}

// 在世界网格中为每个区域生成独立、循环变化的随机雨滴落点。
float rain_wave_height(vec2 world_position, float time) {
	if (!rain_ripples_enabled) {
		return 0.0;
	}

	float cycle_duration = max(rain_ripple_interval, rain_ripple_duration);
	float maximum_radius = rain_ripple_speed * rain_ripple_duration
		+ rain_ripple_width * 2.0;
	float cell_size = max(rain_ripple_spacing, maximum_radius);
	vec2 center_cell = floor(world_position / cell_size);
	float combined_height = 0.0;

	// 单个圆环不会超过一个网格，因此只需要检查周围九格。
	for (int cell_y = -1; cell_y <= 1; cell_y++) {
		for (int cell_x = -1; cell_x <= 1; cell_x++) {
			vec2 cell = center_cell + vec2(float(cell_x), float(cell_y));
			float time_offset = random_from_position(cell + vec2(17.2, 4.8))
				* cycle_duration;
			float local_time = time + time_offset;
			float cycle_index = floor(local_time / cycle_duration);
			float age = mod(local_time, cycle_duration);
			float active = step(age, rain_ripple_duration);
			vec2 cycle_seed = cell + vec2(cycle_index * 13.7, cycle_index * 7.1);
			vec2 hit_offset = vec2(
				random_from_position(cycle_seed + vec2(2.3, 9.1)),
				random_from_position(cycle_seed + vec2(8.7, 1.4))
			);
			vec2 hit_position = (cell + hit_offset) * cell_size;
			float radius = age * rain_ripple_speed;
			float ring_distance = abs(distance(world_position, hit_position) - radius);
			float pulse = 1.0 - smoothstep(
				0.0,
				rain_ripple_width,
				ring_distance
			);
			float fade = 1.0 - clamp(
				age / max(rain_ripple_duration, 0.001),
				0.0,
				1.0
			);
			combined_height += pulse * fade * active;
		}
	}
	return combined_height;
}

// 在指定半径上采样八个方向，用于提取积水边框。
float sample_mask_ring(vec2 mask_uv, vec2 uv_offset) {
	vec2 diagonal = uv_offset * 0.70710678;
	float result = 0.0;
	result += texture(puddle_mask, clamp(mask_uv + vec2(uv_offset.x, 0.0), vec2(0.0), vec2(1.0))).r;
	result += texture(puddle_mask, clamp(mask_uv - vec2(uv_offset.x, 0.0), vec2(0.0), vec2(1.0))).r;
	result += texture(puddle_mask, clamp(mask_uv + vec2(0.0, uv_offset.y), vec2(0.0), vec2(1.0))).r;
	result += texture(puddle_mask, clamp(mask_uv - vec2(0.0, uv_offset.y), vec2(0.0), vec2(1.0))).r;
	result += texture(puddle_mask, clamp(mask_uv + diagonal, vec2(0.0), vec2(1.0))).r;
	result += texture(puddle_mask, clamp(mask_uv - diagonal, vec2(0.0), vec2(1.0))).r;
	result += texture(puddle_mask, clamp(mask_uv + vec2(diagonal.x, -diagonal.y), vec2(0.0), vec2(1.0))).r;
	result += texture(puddle_mask, clamp(mask_uv + vec2(-diagonal.x, diagonal.y), vec2(0.0), vec2(1.0))).r;
	return result * 0.125;
}

// 手动双线性读取遮罩，避免项目级纹理过滤或视口设置把动态 ImageTexture
// 退化成最近邻采样，导致一个遮罩像素显示成一整块方形台阶。
float sample_puddle_mask_bilinear(vec2 mask_uv) {
	ivec2 texture_size = textureSize(puddle_mask, 0);
	vec2 pixel_position = clamp(mask_uv, vec2(0.0), vec2(1.0)) * vec2(texture_size) - vec2(0.5);
	ivec2 base_pixel = ivec2(floor(pixel_position));
	vec2 blend_weight = fract(pixel_position);
	ivec2 max_pixel = texture_size - ivec2(1);
	ivec2 p00 = clamp(base_pixel, ivec2(0), max_pixel);
	ivec2 p10 = clamp(base_pixel + ivec2(1, 0), ivec2(0), max_pixel);
	ivec2 p01 = clamp(base_pixel + ivec2(0, 1), ivec2(0), max_pixel);
	ivec2 p11 = clamp(base_pixel + ivec2(1, 1), ivec2(0), max_pixel);
	float top = mix(texelFetch(puddle_mask, p00, 0).r, texelFetch(puddle_mask, p10, 0).r, blend_weight.x);
	float bottom = mix(texelFetch(puddle_mask, p01, 0).r, texelFetch(puddle_mask, p11, 0).r, blend_weight.x);
	return mix(top, bottom, blend_weight.y);
}

float sample_water_coverage(vec2 mask_uv) {
	float sampled_mask = sample_puddle_mask_bilinear(mask_uv);
	float antialias_width = max(fwidth(sampled_mask), 1.0 / 255.0);
	return smoothstep(0.5 - antialias_width, 0.5 + antialias_width, sampled_mask);
}

float sample_water_ring(vec2 mask_uv, vec2 uv_offset) {
	vec2 diagonal = uv_offset * 0.70710678;
	float result = 0.0;
	result += sample_water_coverage(mask_uv + vec2(uv_offset.x, 0.0));
	result += sample_water_coverage(mask_uv - vec2(uv_offset.x, 0.0));
	result += sample_water_coverage(mask_uv + vec2(0.0, uv_offset.y));
	result += sample_water_coverage(mask_uv - vec2(0.0, uv_offset.y));
	result += sample_water_coverage(mask_uv + diagonal);
	result += sample_water_coverage(mask_uv - diagonal);
	result += sample_water_coverage(mask_uv + vec2(diagonal.x, -diagonal.y));
	result += sample_water_coverage(mask_uv + vec2(-diagonal.x, diagonal.y));
	return result * 0.125;
}

float sample_water_ring_min(vec2 mask_uv, vec2 uv_offset) {
	vec2 diagonal = uv_offset * 0.70710678;
	float result = 1.0;
	result = min(result, sample_water_coverage(mask_uv + vec2(uv_offset.x, 0.0)));
	result = min(result, sample_water_coverage(mask_uv - vec2(uv_offset.x, 0.0)));
	result = min(result, sample_water_coverage(mask_uv + vec2(0.0, uv_offset.y)));
	result = min(result, sample_water_coverage(mask_uv - vec2(0.0, uv_offset.y)));
	result = min(result, sample_water_coverage(mask_uv + diagonal));
	result = min(result, sample_water_coverage(mask_uv - diagonal));
	result = min(result, sample_water_coverage(mask_uv + vec2(diagonal.x, -diagonal.y)));
	result = min(result, sample_water_coverage(mask_uv + vec2(-diagonal.x, diagonal.y)));
	return result;
}

void fragment() {
	// 当前屏幕像素对应的世界坐标，保证相机移动时水纹留在世界中。
	vec2 screen_pixel = SCREEN_UV * viewport_size;
	vec2 world_position = world_origin
		+ world_step_x * screen_pixel.x
		+ world_step_y * screen_pixel.y;

	// 把世界坐标映射到动态积水遮罩；遮罩范围外强制视为无水。
	vec2 mask_uv = (world_position - mask_world_origin) / mask_world_size;
	float inside_mask = step(0.0, mask_uv.x)
		* step(0.0, mask_uv.y)
		* step(mask_uv.x, 1.0)
		* step(mask_uv.y, 1.0);
	float sampled_water_mask = sample_puddle_mask_bilinear(mask_uv);
	// CPU 将最近岸线的有符号距离编码到 0～1，0.5 为真实岸线。
	// 屏幕导数将连续距离场还原成约一个屏幕像素的覆盖率抗锯齿。
	float sdf_antialias = max(fwidth(sampled_water_mask), 1.0 / 255.0);
	float threshold_water_mask = smoothstep(
		0.5 - sdf_antialias,
		0.5 + sdf_antialias,
		sampled_water_mask
	);
	float water_mask = (mask_threshold_smoothing ? threshold_water_mask : sampled_water_mask)
		* inside_mask;
	float edge_center_mask = water_mask;

	// 沿同一世界半径环形采样八个方向。平均值比四方向取最小值更圆滑，
	// 不会在斜边和拐角形成明显的十字形像素锯齿。
	// 偏移按世界范围换算，因此宽度不受遮罩分辨率影响。
	// 整圈使用统一的余弦呼吸节奏：平滑外扩到最大值，再平滑收回。
	float edge_animation_phase = 0.5 - 0.5 * cos(TIME * 2.4);
	float edge_expansion = water_edge_animation_enabled
		? max(water_edge_animation_strength, 0.0) * edge_animation_phase
		: 0.0;
	// 用遮罩梯度把 0.5 岸线附近的覆盖率换算为屏幕像素距离。
	// 正值在水内，负值在水外；整个边框和动效只使用这一条连续距离场，
	// 与 StyleBoxFlat 的 blend 类似，不再叠加多份偏移轮廓。
	vec2 mask_gradient = vec2(dFdx(sampled_water_mask), dFdy(sampled_water_mask));
	float signed_edge_distance_px = (sampled_water_mask - 0.5)
		/ max(length(mask_gradient), 0.0001);
	float world_units_per_pixel = max(
		(length(world_step_x) + length(world_step_y)) * 0.5,
		0.0001
	);
	float border_width_px = max(water_edge_width / world_units_per_pixel, 0.0001);
	float border_blend_px = clamp(water_edge_blend_width / world_units_per_pixel, 0.0, border_width_px);
	float expansion_width_px = max(edge_expansion / world_units_per_pixel, 0.0001);
	// 有符号距离以屏幕像素为单位；用导数给边框两侧各保留约一个像素
	// 的覆盖率过渡，避免岸线端和内缘端重新形成锯齿硬边。
	float border_antialias_px = max(fwidth(signed_edge_distance_px) * 0.75, 0.75);
	float shore_coverage = smoothstep(
		-border_antialias_px,
		border_antialias_px,
		signed_edge_distance_px
	);
	float inner_blend_start = max(border_width_px - border_blend_px, 0.0);
	float inner_edge_coverage = 1.0 - smoothstep(
		max(inner_blend_start - border_antialias_px, 0.0),
		border_width_px + border_antialias_px,
		signed_edge_distance_px
	);
	float base_edge_falloff = shore_coverage * inner_edge_coverage;
	float outer_edge_signal = water_edge_animation_enabled
		? (1.0 - shore_coverage)
			* (1.0 - smoothstep(
				max(expansion_width_px - border_antialias_px, 0.0),
				expansion_width_px + border_antialias_px,
				-signed_edge_distance_px
			))
			* edge_animation_phase
		: 0.0;
	float base_water_edge = (water_edge_enabled ? 1.0 : 0.0)
		* step(0.001, water_edge_width)
		* base_edge_falloff;
	float animated_outer_edge = (water_edge_enabled && water_edge_animation_enabled ? 1.0 : 0.0)
		* step(0.001, water_edge_animation_strength)
		* clamp(outer_edge_signal, 0.0, 1.0);
	float water_edge = clamp(base_water_edge + animated_outer_edge, 0.0, 1.0);
	// 风纹始终只作用于水面内部。边框区域仍保留水面底色，边框只减弱内部风纹，避免水面与边框
	// 像两层贴图一样硬切。
	float inner_water_mask = water_mask * (1.0 - water_edge * 0.45);
	float ripple_effect_mask = inner_water_mask;
	// 边框本身不显示倒影，倒影只保留在边框以内的积水区域。
	float reflection_mask = water_mask * (1.0 - water_edge);

	// 对相邻位置采样高度，通过有限差分求出水面坡度和法线。
	float height_center = water_height(world_position, TIME);
	float height_right = water_height(world_position + vec2(1.0, 0.0), TIME);
	float height_down = water_height(world_position + vec2(0.0, 1.0), TIME);
	vec2 surface_slope = vec2(
		height_right - height_center,
		height_down - height_center
	) * surface_roughness * inner_water_mask;

	// 先叠加所有脚步波高，再从总高度场求坡度，让圆环产生真实的相长/相消干涉。
	float footstep_height_center = footstep_wave_height(world_position);
	float footstep_height_right = footstep_wave_height(
		world_position + vec2(1.0, 0.0)
	);
	float footstep_height_down = footstep_wave_height(
		world_position + vec2(0.0, 1.0)
	);
	surface_slope += vec2(
		footstep_height_right - footstep_height_center,
		footstep_height_down - footstep_height_center
	) * footstep_ripple_strength * ripple_effect_mask;

	// 雨滴拥有独立高度场和参数，但与其他水波共同影响最终水面法线。
	float rain_height_center = rain_wave_height(world_position, TIME);
	float rain_height_right = rain_wave_height(
		world_position + vec2(1.0, 0.0),
		TIME
	);
	float rain_height_down = rain_wave_height(
		world_position + vec2(0.0, 1.0),
		TIME
	);
	surface_slope += vec2(
		rain_height_right - rain_height_center,
		rain_height_down - rain_height_center
	) * rain_ripple_strength * ripple_effect_mask;
	vec3 surface_normal = normalize(vec3(-surface_slope, 1.0));

	// 倒影使用同一水面坡度产生折散，不使用独立的贴图扭曲动画。
	// 只把有限范围内的坡度用于倒影折散，避免风纹尺寸或粗糙度过大
	// 时把整片倒影采样扩散成模糊色块。
	vec2 reflection_slope = clamp(surface_slope, vec2(-1.0), vec2(1.0));
	vec2 reflection_uv = UV
		+ reflection_slope * reflection_response * ripple_effect_mask
			* TEXTURE_PIXEL_SIZE;
	vec4 reflection = texture(
		TEXTURE,
		clamp(reflection_uv, vec2(0.0), vec2(1.0))
	);

	// 只保留相对平静水面新增的高光，避免整片积水统一变亮。
	vec3 light_direction = normalize(vec3(-0.35, -0.45, 1.0));
	float flat_specular = pow(light_direction.z, 12.0);
	float disturbed_specular = pow(
		max(dot(surface_normal, light_direction), 0.0),
		12.0
	);
	float ripple_specular = max(
		disturbed_specular - flat_specular,
		0.0
	) * ripple_highlight * inner_water_mask;
	// 指数映射保留叠加强弱，避免单个圆环就把高光截到上限。
	float footstep_interference = 1.0 - exp(-abs(footstep_height_center));
	ripple_specular += footstep_interference
		* footstep_ripple_highlight
		* ripple_effect_mask;
	float rain_highlight = 1.0 - exp(-abs(rain_height_center));
	ripple_specular += rain_highlight
		* rain_ripple_highlight
		* ripple_effect_mask;

	// 直接按倒影权重混合颜色，避免半透明水色和倒影平均化后变灰。
	float water_alpha = water_mask * water_color.a;
	float reflection_alpha = reflection.a * reflection_mask * reflection_opacity;
	float surface_alpha = water_alpha
		+ reflection_alpha * (1.0 - water_alpha)
		+ ripple_specular * (1.0 - water_alpha);
	float border_coverage = clamp(water_edge, 0.0, 1.0);
	float reflection_weight = clamp(reflection_alpha, 0.0, 1.0);
	vec3 water_surface_color = mix(water_color.rgb, reflection.rgb, reflection_weight);
	// 使用 StyleBoxFlat 类似的覆盖率混合：边框替换水面颜色，不额外叠加一层水色/倒影。
	float border_color_mix = border_coverage * water_edge_color.a;
	vec3 combined_color = mix(water_surface_color, water_edge_color.rgb, border_color_mix);
	float combined_alpha = mix(surface_alpha, water_edge_color.a, border_coverage);
	combined_color += vec3(1.0) * ripple_specular;
	// 在固定世界网格中产生稀疏片状波光。每片具有随机方向、尺寸和慢速时相，
	// 并且只乘基础边框遮罩，不会出现在呼吸外扩区域。
	float shimmer_cell_size = 54.0;
	// 使用连续移动的世界坐标采样，而不是按时间切换网格种子；
	// 光片会缓慢漂移，跨格时仍保持连续，不会瞬移到固定几个位置。
	vec2 shimmer_drift = TIME * vec2(0.11, -0.065);
	vec2 shimmer_sample_position = world_position / shimmer_cell_size - shimmer_drift;
	vec2 shimmer_cell = floor(shimmer_sample_position);
	vec2 shimmer_local = fract(shimmer_sample_position);
	float shimmer_seed = random_from_position(shimmer_cell + vec2(31.7, 9.2));
	vec2 shimmer_center = vec2(
		random_from_position(shimmer_cell + vec2(4.3, 17.1)),
		random_from_position(shimmer_cell + vec2(12.8, 2.6))
	);
	float shimmer_angle = shimmer_seed * 6.283185;
	vec2 shimmer_axis = vec2(cos(shimmer_angle), sin(shimmer_angle));
	vec2 shimmer_cross_axis = vec2(-shimmer_axis.y, shimmer_axis.x);
	vec2 shimmer_offset = shimmer_local - shimmer_center;
	vec2 shimmer_shape = vec2(
		dot(shimmer_offset, shimmer_axis) / mix(0.24, 0.42, shimmer_seed),
		dot(shimmer_offset, shimmer_cross_axis) / mix(0.08, 0.16, shimmer_seed)
	);
	float shimmer_patch = 1.0 - smoothstep(0.55, 1.0, length(shimmer_shape));
	float shimmer_breakup = 0.72 + 0.28 * sin(
		dot(world_position, vec2(0.11, -0.07)) + shimmer_seed * 12.0
	);
	float shimmer_twinkle = pow(
		max(sin(TIME * mix(0.55, 1.15, shimmer_seed) + shimmer_seed * 18.84956), 0.0),
		3.0
	);
	float shimmer_sparse = step(0.48, shimmer_seed);
	float edge_shimmer = water_edge_animation_enabled
		? base_water_edge * shimmer_patch * shimmer_breakup * shimmer_twinkle * shimmer_sparse
			* water_edge_shimmer_strength
		: 0.0;
	combined_color += vec3(1.0) * edge_shimmer;
	combined_alpha = clamp(combined_alpha, 0.0, 1.0);
	combined_alpha += edge_shimmer * (1.0 - combined_alpha);

	COLOR = vec4(combined_color, combined_alpha);
}
