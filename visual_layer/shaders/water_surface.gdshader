shader_type canvas_item;
render_mode unshaded;

uniform sampler2D height_texture : filter_linear, repeat_disable;
uniform sampler2D background_texture : source_color, filter_linear, repeat_enable;
uniform bool use_background = false;
uniform vec2 texel_size = vec2(0.00390625);
uniform vec4 deep_color : source_color = vec4(0.025, 0.22, 0.30, 1.0);
uniform vec4 light_color : source_color = vec4(0.18, 0.58, 0.64, 1.0);
uniform float wave_intensity : hint_range(0.0, 10.0) = 3.5;
uniform float ambient_strength : hint_range(0.0, 0.1) = 0.018;
uniform float refraction_strength : hint_range(0.0, 0.1) = 0.025;

void fragment() {
	float left = texture(height_texture, UV - vec2(texel_size.x, 0.0)).r;
	float right = texture(height_texture, UV + vec2(texel_size.x, 0.0)).r;
	float up = texture(height_texture, UV - vec2(0.0, texel_size.y)).r;
	float down = texture(height_texture, UV + vec2(0.0, texel_size.y)).r;
	vec2 slope = vec2(right - left, down - up) * wave_intensity;
	vec2 ambient = vec2(sin(UV.y * 12.0 + TIME * 0.6), cos(UV.x * 10.0 - TIME * 0.45)) * ambient_strength;
	vec3 normal = normalize(vec3(-slope - ambient, 1.0));
	vec3 light_dir = normalize(vec3(-0.45, -0.5, 1.0));
	float diffuse = clamp(dot(normal, light_dir), 0.0, 1.0);
	float specular = pow(max(dot(reflect(-light_dir, normal), vec3(0.0, 0.0, 1.0)), 0.0), 40.0);
	vec3 color = mix(deep_color.rgb, light_color.rgb, 0.25 + 0.48 * diffuse);
	float glow = sin(UV.x * 8.0 + UV.y * 5.0 + TIME * 0.22)
		* sin(UV.y * 9.0 - UV.x * 3.0 - TIME * 0.18);
	color += light_color.rgb * glow * ambient_strength * 2.2;
	if (use_background) {
		vec3 background = texture(background_texture, UV + (slope + ambient) * refraction_strength).rgb;
		color = mix(background, color, 0.48);
	}
	color += vec3(0.65, 0.84, 0.82) * specular * 0.28;
	COLOR = vec4(color, 1.0);
}
