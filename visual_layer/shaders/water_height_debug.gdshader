shader_type canvas_item;
render_mode unshaded;

void fragment() {
	float h = texture(TEXTURE, UV).r;
	COLOR = vec4(vec3(clamp(0.5 + h * 2.0, 0.0, 1.0)), 1.0);
}
