shader_type canvas_item;
render_mode unshaded, blend_disabled;

uniform sampler2D state_texture : filter_nearest, repeat_disable;
uniform sampler2D motion_texture : filter_linear, repeat_disable;
uniform vec2 texel_size = vec2(0.00390625);
uniform float propagation : hint_range(0.01, 0.49) = 0.22;
uniform float damping : hint_range(0.9, 0.9999) = 0.992;
uniform float motion_threshold : hint_range(0.0, 0.95) = 0.08;
uniform float motion_sensitivity : hint_range(0.0, 10.0) = 2.0;
uniform float impulse_strength : hint_range(0.0, 0.5) = 0.04;
uniform float max_disturbance : hint_range(0.01, 1.0) = 0.35;
uniform float motion_enabled = 0.0;
uniform bool motion_edges = false;
uniform int test_pattern = 0;
uniform float test_time = 0.0;
uniform float test_impulse = 0.0;

float spot(vec2 uv, vec2 center, float radius) {
	vec2 p = (uv - center) / radius;
	return exp(-dot(p, p) * 3.0);
}

void fragment() {
	vec2 state = texture(state_texture, UV).rg;
	float laplacian = texture(state_texture, UV + vec2(texel_size.x, 0.0)).r
		+ texture(state_texture, UV - vec2(texel_size.x, 0.0)).r
		+ texture(state_texture, UV + vec2(0.0, texel_size.y)).r
		+ texture(state_texture, UV - vec2(0.0, texel_size.y)).r - 4.0 * state.r;
	float intensity = texture(motion_texture, UV).r;
	float motion = max(intensity - motion_threshold, 0.0) * motion_sensitivity;
	if (motion_edges) {
		vec2 pixel = vec2(1.0 / 160.0, 1.0 / 120.0);
		vec2 gradient = vec2(
			texture(motion_texture, UV + vec2(pixel.x, 0.0)).r - texture(motion_texture, UV - vec2(pixel.x, 0.0)).r,
			texture(motion_texture, UV + vec2(0.0, pixel.y)).r - texture(motion_texture, UV - vec2(0.0, pixel.y)).r
		);
		motion = max(length(gradient) - motion_threshold, 0.0) * motion_sensitivity;
	}
	float impulse = min(motion, max_disturbance) * impulse_strength * motion_enabled;
	if (test_pattern == 1) {
		impulse += spot(UV, vec2(0.5), 0.05) * test_impulse;
	} else if (test_pattern == 2) {
		impulse += spot(UV, vec2(0.5 + 0.32 * sin(test_time), 0.5), 0.035) * test_impulse;
	} else if (test_pattern == 3) {
		impulse += (spot(UV, vec2(0.28, 0.36), 0.04) + spot(UV, vec2(0.72, 0.64), 0.04)) * test_impulse;
	} else if (test_pattern == 4) {
		impulse += spot(UV, vec2(fract(test_time * 0.15), 0.5 + 0.18 * sin(test_time * 1.5)), 0.04) * test_impulse;
	}
	float next_height = (2.0 * state.r - state.g + propagation * laplacian) * damping + impulse;
	next_height = clamp(next_height, -1.0, 1.0);
	COLOR = vec4(next_height, state.r, 0.0, 1.0);
}
