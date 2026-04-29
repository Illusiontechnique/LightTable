shader_type canvas_item;

uniform sampler2D height_map;
uniform float ripple_strength = 0.05;

void fragment() {
    float h = texture(height_map, SCREEN_UV).r;
    vec2 offset = vec2(h, h) * ripple_strength;
    COLOR = texture(SCREEN_TEXTURE, SCREEN_UV + offset);
}
