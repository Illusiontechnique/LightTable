shader_type canvas_item;

uniform sampler2D screen_texture : hint_screen_texture, repeat_disable, filter_linear_mipmap;
uniform vec2 ripple_center = vec2(0.5, 0.5);
uniform float ripple_strength = 0.45;
uniform float wave_speed = 1.15;
uniform float wave_freq = 18.0;

void fragment() {
	vec2 uv = SCREEN_UV;
	float time = TIME * wave_speed;

	vec2 motion = vec2(
		sin(uv.y * wave_freq + time * 1.25) * 0.009,
		cos(uv.x * (wave_freq * 0.82) - time * 1.05) * 0.009
	);

	vec2 to_center = uv - ripple_center;
	float dist = length(to_center);
	vec2 center_dir = normalize(to_center + vec2(0.0001));

	float wave_front = sin(dist * 78.0 - time * 11.0);
	wave_front = pow(abs(wave_front), 5.0) * exp(-dist * 6.0) * ripple_strength;
	vec2 radial_offset = center_dir * wave_front * 0.035;

	vec2 sample_uv = uv + motion + radial_offset;
	vec3 scene_color = texture(screen_texture, sample_uv).rgb;

	float caustic_a = sin((uv.x + uv.y) * 24.0 + time * 1.7) * 0.5 + 0.5;
	float caustic_b = cos((uv.x - uv.y) * 31.0 - time * 1.25) * 0.5 + 0.5;
	float caustics = pow(caustic_a * caustic_b, 3.0);

	float sun_glow = pow(max(0.0, 1.0 - distance(uv, vec2(0.45, 0.25)) * 1.55), 3.2);
	float sweep = pow(sin((uv.x * 10.0 + uv.y * 6.0) + time * 0.9) * 0.5 + 0.5, 2.0);

	float ring = 1.0 - smoothstep(0.0, 0.028, abs(dist - 0.17 - sin(time * 0.8 + dist * 16.0) * 0.006));
	float edge_vignette = smoothstep(0.95, 0.35, dist);

	vec3 deep_color = vec3(0.01, 0.06, 0.14);
	vec3 aqua = vec3(0.02, 0.65, 0.92);
	vec3 foam = vec3(0.80, 0.98, 1.0);
	vec3 glow = aqua * (caustics * 0.55 + sun_glow * 0.9 + sweep * 0.18 + ring * 0.85);
	glow += foam * (sun_glow * 0.18 + ring * 0.35);

	vec3 color = mix(deep_color, scene_color, 0.20);
	color += glow;
	color *= mix(vec3(0.55, 0.68, 0.82), vec3(1.0), edge_vignette);
	color = mix(color, vec3(0.0, 0.03, 0.08), smoothstep(0.82, 1.0, dist));
	color = pow(color, vec3(0.92));

	COLOR = vec4(color, 1.0);
}
