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
	uv.x += sin(uv.y * wave_freq + time) * 0.01;
	uv.y += cos(uv.x * wave_freq + time) * 0.01;
	
	// Base blue water color - simplified for testing
	vec4 water_color = vec4(0.1, 0.4, 0.8, 0.8);
	
	// Subtle caustic/surface highlight effect
	float caustic1 = sin(uv.x * 30.0 + time * 0.5) * 0.5 + 0.5;
	float caustic2 = cos(uv.y * 30.0 - time * 0.3) * 0.5 + 0.5;
	float combined_caustic = pow(caustic1 * caustic2, 2.0);
	
	water_color.rgb += combined_caustic * 0.2;
	
	COLOR = water_color;
}
