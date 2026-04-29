shader_type canvas_item;

uniform sampler2D screen_texture : hint_screen_texture, repeat_disable, filter_linear_mipmap;
uniform vec2 ripple_center = vec2(0.5, 0.5);
uniform float ripple_strength = 0.25;
uniform float wave_speed = 1.1;
uniform float wave_freq = 18.0;

void fragment() {
	vec2 uv = SCREEN_UV;
	float time = TIME * wave_speed;

	vec2 motion = vec2(
		sin(uv.y * wave_freq + time) * 0.006,
		cos(uv.x * (wave_freq * 0.8) - time * 0.85) * 0.006
	);

	vec2 to_center = uv - ripple_center;
	float dist = length(to_center);
	float radial_wave = sin(dist * 75.0 - time * 10.0) * exp(-dist * 6.5) * ripple_strength;
	vec2 radial_offset = normalize(to_center + vec2(0.0001)) * radial_wave * 0.02;

	vec2 sample_uv = uv + motion + radial_offset;
	vec4 scene_color = texture(screen_texture, sample_uv);

	float caustic_a = sin((uv.x + uv.y) * 22.0 + time * 1.6) * 0.5 + 0.5;
	float caustic_b = cos((uv.x - uv.y) * 28.0 - time * 1.2) * 0.5 + 0.5;
	float caustics = pow(caustic_a * caustic_b, 2.5);

	vec3 water_tint = vec3(0.05, 0.35, 0.75);
	vec3 color = mix(scene_color.rgb, water_tint, 0.18);
	color += caustics * vec3(0.08, 0.18, 0.22);
	color += radial_wave * vec3(0.18, 0.22, 0.25);

	COLOR = vec4(color, 1.0);
}
