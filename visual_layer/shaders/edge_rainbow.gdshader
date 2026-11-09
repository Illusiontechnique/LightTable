shader_type canvas_item;
render_mode unshaded;

uniform sampler2D motion_texture : filter_linear, repeat_disable;
uniform sampler2D height_texture : filter_linear, repeat_disable;
uniform float motion_visible = 0.0;
uniform float audio_level : hint_range(0.0, 1.0) = 0.0;

vec3 rainbow(float phase) {
	return 0.5 + 0.5 * cos(6.2831853 * (phase + vec3(0.0, 0.67, 0.33)));
}

void fragment() {
	vec2 pixel = vec2(1.0 / 160.0, 1.0 / 120.0);
	vec2 gradient = vec2(
		texture(motion_texture, UV + vec2(pixel.x, 0.0)).r - texture(motion_texture, UV - vec2(pixel.x, 0.0)).r,
		texture(motion_texture, UV + vec2(0.0, pixel.y)).r - texture(motion_texture, UV - vec2(0.0, pixel.y)).r
	);
	float edge = smoothstep(0.06, 0.35, length(gradient)) * motion_visible;
	float wave = texture(height_texture, UV).r;
	float halo = smoothstep(0.002, 0.09, abs(wave));
	float pulse = 0.65 + 0.35 * sin(wave * 32.0 - TIME * 1.8);
	float brightness = min(1.0, edge * 0.65 + halo * pulse * (0.32 + audio_level * 0.65));
	vec3 color = rainbow(TIME * 0.035 + wave * 2.0 + UV.x * 0.20 + UV.y * 0.12 + audio_level * 0.12);
	vec3 background = vec3(0.006, 0.008, 0.025);
	COLOR = vec4(background + color * brightness, 1.0);
}
