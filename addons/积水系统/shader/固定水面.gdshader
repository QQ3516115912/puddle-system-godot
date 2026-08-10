shader_type canvas_item;

// 固定河面专用 Shader：不读取积水遮罩，只对本层已有的河面瓦片做风扰动。
group_uniforms Water_Appearance;
// 河面原始纹理与该颜色相乘后的整体色调；Alpha 控制河面透明度。
uniform vec4 water_tint : source_color = vec4(0.72, 0.86, 1.0, 1.0);
// 河面亮度倍率。
uniform float water_brightness : hint_range(0.0, 2.0, 0.01) = 1.0;

group_uniforms Reflection;
// 是否采样倒影视口纹理；关闭时只显示河面本身,编辑器里就算关闭了，管理器里遍历时也会自动开启。
uniform bool reflection_enabled = false;
// 管理器提供的倒影视口纹理。
uniform sampler2D reflection_texture
	: source_color, repeat_disable, filter_nearest;
// 倒影混入透明度。
uniform float reflection_opacity : hint_range(0.0, 1.0, 0.01) = 0.6;
// 倒影受水面坡度影响的 UV 偏移倍率，即倒影受扰动的幅度。
uniform float reflection_response : hint_range(0.0, 100.0, 0.1) = 1.5;
group_uniforms Wind_Ripples;
// 是否启用风扰动；关闭后仍可保留雨滴波纹。
uniform bool wind_disturbance_enabled = true;
// 风纹传播方向。
uniform vec2 wind_direction = vec2(1.0, 0.25);
// 风纹的世界坐标波长，越小越密。
uniform float wind_ripple_size : hint_range(8.0, 160.0, 1.0) = 42.0;
// 风纹移动速度。
uniform float wind_speed : hint_range(0.0, 8.0, 0.05) = 1.4;
// 风纹对河面底色明暗的调制强度。
uniform float wind_strength : hint_range(0.0, 1.0, 0.01) = 0.16;
// 波纹高光强度。
uniform float ripple_highlight : hint_range(0.0, 1.0, 0.01) = 0.18;

group_uniforms Rain_Ripples;
// 是否启用程序化雨滴波纹。
uniform bool rain_ripples_enabled = false;
// 雨滴落点网格间距。
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

// 从顶点阶段传入世界坐标，避免使用会随摄像机移动的屏幕坐标。
varying vec2 world_position;

void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy;
}

float water_height(vec2 position, float time) {
	if (!wind_disturbance_enabled) {
		return 0.0;
	}
	vec2 wind = normalize(wind_direction + vec2(0.0001, 0.0));
	vec2 cross_wind = vec2(-wind.y, wind.x);
	float frequency = 6.283185 / max(wind_ripple_size, 0.001);
	float height = sin(dot(position, wind) * frequency - time * wind_speed);
	height += sin(
		dot(position, normalize(wind + cross_wind * 0.32))
			* frequency * 1.73 - time * wind_speed * 1.31
	) * 0.42;
	height += sin(
		dot(position, normalize(wind - cross_wind * 0.21))
			* frequency * 2.47 - time * wind_speed * 1.82
	) * 0.20;
	return height / 1.62;
}

float random_from_position(vec2 value) {
	vec2 random_value = fract(value * vec2(0.1031, 0.1030));
	random_value += dot(random_value, random_value.yx + 33.33);
	return fract((random_value.x + random_value.y) * random_value.x);
}

// 以世界网格生成稳定的随机落点，摄像机移动不会带动雨滴圆环。
float rain_wave_height(vec2 position, float time) {
	if (!rain_ripples_enabled) {
		return 0.0;
	}

	float cycle_duration = max(rain_ripple_interval, rain_ripple_duration);
	float maximum_radius = rain_ripple_speed * rain_ripple_duration
		+ rain_ripple_width * 2.0;
	float cell_size = max(rain_ripple_spacing, maximum_radius);
	vec2 center_cell = floor(position / cell_size);
	float combined_height = 0.0;

	for (int cell_y = -1; cell_y <= 1; cell_y++) {
		for (int cell_x = -1; cell_x <= 1; cell_x++) {
			vec2 cell = center_cell + vec2(float(cell_x), float(cell_y));
			float time_offset = random_from_position(cell + vec2(17.2, 4.8))
				* cycle_duration;
			float local_time = time + time_offset;
			float cycle_index = floor(local_time / cycle_duration);
			float age = mod(local_time, cycle_duration);
			float active = step(age, rain_ripple_duration);
			vec2 cycle_seed = cell
				+ vec2(cycle_index * 13.7, cycle_index * 7.1);
			vec2 hit_offset = vec2(
				random_from_position(cycle_seed + vec2(2.3, 9.1)),
				random_from_position(cycle_seed + vec2(8.7, 1.4))
			);
			vec2 hit_position = (cell + hit_offset) * cell_size;
			float radius = age * rain_ripple_speed;
			float ring_distance = abs(distance(position, hit_position) - radius);
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

void fragment() {
	vec4 base = texture(TEXTURE, UV) * COLOR;
	if (base.a <= 0.001) {
		COLOR = base;
	} else {
		// 使用世界坐标让风纹固定在河面上，不随玩家和摄像机移动。
		vec2 position = world_position;
		float center = water_height(position, TIME);
		float right = water_height(position + vec2(1.0, 0.0), TIME);
		float down = water_height(position + vec2(0.0, 1.0), TIME);
		vec2 slope = vec2(right - center, down - center);

		float rain_center = rain_wave_height(position, TIME);
		float rain_right = rain_wave_height(position + vec2(1.0, 0.0), TIME);
		float rain_down = rain_wave_height(position + vec2(0.0, 1.0), TIME);
		slope += vec2(
			rain_right - rain_center,
			rain_down - rain_center
		) * rain_ripple_strength;
		float highlight = max(dot(normalize(vec3(-slope, 1.0)), vec3(-0.35, -0.45, 1.0)), 0.0);
		highlight = pow(highlight, 12.0) * ripple_highlight;
		highlight += (1.0 - exp(-abs(rain_center)))
			* rain_ripple_highlight;
		float modulation = 1.0 + center * wind_strength;

		vec3 water_color = base.rgb
			* water_tint.rgb
			* water_brightness
			* modulation;
		// 倒影使用屏幕 UV 与倒影视口对齐，扭曲坡度来自世界坐标水纹。
		vec2 reflection_uv = SCREEN_UV
			+ slope * reflection_response * 0.08;
		vec3 color = water_color;
		if (reflection_enabled) {
			vec4 reflection = texture(
				reflection_texture,
				clamp(reflection_uv, vec2(0.0), vec2(1.0))
			);
			float reflection_alpha = reflection.a * reflection_opacity;
			color = mix(water_color, reflection.rgb, reflection_alpha);
		}
		color += vec3(1.0) * highlight;
		COLOR = vec4(color, base.a * water_tint.a);
	}
}
