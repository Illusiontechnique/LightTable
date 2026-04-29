shader_type canvas_item;

uniform sampler2D screen_texture : hint_screen_texture, filter_linear_mipmap;
uniform float wave_speed = 1.0;
uniform float wave_freq = 10.0;
uniform float wave_width = 1.0;
uniform vec2 blur_amount = vec2(0.002, 0.002);

void fragment() {
	vec2 uv = SCREEN_UV;
	
	// Create some ambient motion (pool-like shifting)
	float time = TIME * wave_speed;
	uv.x += sin(uv.y * wave_freq + time) * 0.002;
	uv.y += cos(uv.x * wave_freq + time) * 0.002;
	
	// Base blue water color with transparency
	vec4 water_color = vec4(0.0, 0.4, 0.8, 0.4);
	
	// Sample world behind the water with slight distortion
	vec4 screen_color = texture(screen_texture, uv);
	
	// Subtle caustic/surface highlight effect
	float caustic = sin(uv.x * 20.0 + time) * cos(uv.y * 20.0 + time * 0.5);
	water_color.rgb += caustic * 0.05;
	
	COLOR = mix(screen_color, water_color, 0.5);
}
