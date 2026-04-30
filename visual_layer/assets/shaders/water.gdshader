shader_type canvas_item;

// ── Screen capture ─────────────────────────────────────────────────────────
uniform sampler2D screen_texture : hint_screen_texture, repeat_disable, filter_linear_mipmap;

// ── Wave parameters ────────────────────────────────────────────────────────
uniform float wave_speed     : hint_range(0.0, 3.0)  = 0.70;
uniform float wave_scale     : hint_range(1.0, 20.0) = 5.50;
uniform float wave_height    : hint_range(0.0, 0.05) = 0.010;  // refraction strength
uniform float foam_threshold : hint_range(0.0, 1.0)  = 0.62;

// ── Colour palette ─────────────────────────────────────────────────────────
uniform vec3  color_deep    = vec3(0.01, 0.04, 0.14);
uniform vec3  color_shallow = vec3(0.03, 0.38, 0.72);
uniform vec3  color_foam    = vec3(0.76, 0.97, 1.00);
uniform vec3  color_caustic = vec3(0.24, 0.90, 1.00);
uniform float opacity       : hint_range(0.0, 1.0) = 0.92;

// ── Lighting ───────────────────────────────────────────────────────────────
uniform float specular_power    : hint_range(8.0, 512.0) = 88.0;
uniform float specular_strength : hint_range(0.0, 2.0)   = 0.70;

// ── Multi-touch ripples (up to 8) ──────────────────────────────────────────
//    xy = UV position   z = age in seconds   w = strength (0–2)
uniform vec4 ripples[8];
uniform int  ripple_count = 0;

// ── Audio reactivity ───────────────────────────────────────────────────────
uniform float audio_level : hint_range(0.0, 1.0) = 0.0;

// ── Aspect ratio (set from GDScript each frame) ────────────────────────────
uniform float aspect_ratio = 1.7778;   // width / height, default 16:9

// ══════════════════════════════════════════════════════════════════════════
//  Utility: gradient noise helpers
// ══════════════════════════════════════════════════════════════════════════

vec2 hash22(vec2 p) {
	p = vec2(dot(p, vec2(127.1, 311.7)), dot(p, vec2(269.5, 183.3)));
	return fract(sin(p) * 43758.5453) * 2.0 - 1.0;
}

// Smooth gradient noise (value variant, returns 0–1)
float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	float a = dot(hash22(i            ), f            );
	float b = dot(hash22(i + vec2(1,0)), f - vec2(1,0));
	float c = dot(hash22(i + vec2(0,1)), f - vec2(0,1));
	float d = dot(hash22(i + vec2(1,1)), f - vec2(1,1));
	return 0.5 + 0.5 * mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

// 4-octave FBM — rotated to avoid directional bias
float fbm4(vec2 p) {
	float v = 0.0, a = 0.5;
	mat2  R = mat2(vec2(0.80, 0.60), vec2(-0.60, 0.80));
	for (int i = 0; i < 4; i++) { v += a * vnoise(p); p = R * p * 2.1; a *= 0.5; }
	return v;
}

// ══════════════════════════════════════════════════════════════════════════
//  Gerstner wave — returns (height, dh/dx, dh/dy) analytically
// ══════════════════════════════════════════════════════════════════════════

vec3 gerstner(vec2 uv, vec2 dir, float freq, float amp, float phase, float spd) {
	vec2  d = normalize(dir);
	float k = dot(d, uv) * freq + TIME * spd + phase;
	float c = cos(k);
	return vec3(amp * sin(k), amp * freq * d.x * c, amp * freq * d.y * c);
}

// Sum of 4 Gerstner waves — main ocean swell
vec3 wave_field(vec2 uv) {
	float aa = 1.0 + audio_level * 0.55;
	vec3  w  = vec3(0.0);
	w += gerstner(uv, vec2( 1.0,  0.7),  4.8, 0.44 * aa, 0.00, wave_speed * 1.10);
	w += gerstner(uv, vec2(-0.6,  1.0),  6.5, 0.27 * aa, 1.57, wave_speed * 0.85);
	w += gerstner(uv, vec2( 0.4, -0.9),  9.8, 0.14 * aa, 3.14, wave_speed * 1.35);
	w += gerstner(uv, vec2(-1.0, -0.3), 14.5, 0.06 * aa, 0.80, wave_speed * 0.65);
	return w;
}

// ══════════════════════════════════════════════════════════════════════════
//  Animated Voronoi caustics
//  Highlights the cell EDGES to simulate light focusing at wave troughs.
// ══════════════════════════════════════════════════════════════════════════

float voronoi_edge(vec2 uv, float t) {
	vec2  ip = floor(uv), fp = fract(uv);
	float d1 = 10.0, d2 = 10.0;
	for (int y = -1; y <= 1; y++) {
		for (int x = -1; x <= 1; x++) {
			vec2 cell  = vec2(float(x), float(y));
			// Each cell point drifts on a Lissajous path
			vec2 point = (hash22(ip + cell) * 0.5 + 0.5)
			           + 0.44 * sin(t * 0.65 + 6.2831 * hash22(ip + cell + vec2(13.7, 5.3)));
			float dist = length(cell + point - fp);
			if (dist < d1) { d2 = d1; d1 = dist; } else if (dist < d2) { d2 = dist; }
		}
	}
	// Highlight cell border (d2-d1 is distance to second-nearest point)
	return smoothstep(0.04, 0.16, d2 - d1) * (1.0 - smoothstep(0.0, 0.38, d1));
}

float caustics_val(vec2 uv) {
	float sc = 5.0 + audio_level * 1.8;
	float t  = TIME;
	float c1 = voronoi_edge(uv * sc        + vec2( t * 0.12,  t * 0.07), t      );
	float c2 = voronoi_edge(uv * sc * 1.38 + vec2(-t * 0.09, -t * 0.11), t * 1.3);
	return pow(c1 * c2, 1.45);
}

// ══════════════════════════════════════════════════════════════════════════
//  Multi-touch ripple field
//  Each active ripple: expanding ring wave with temporal + spatial decay.
// ══════════════════════════════════════════════════════════════════════════

vec3 ripple_field(vec2 uv) {
	vec3 out_ = vec3(0.0);   // (height,  dh/dx,  dh/dy)
	for (int i = 0; i < 8; i++) {
		if (i >= ripple_count) break;
		vec4  r   = ripples[i];
		float age = r.z;
		if (age < 0.0 || age > 3.2) continue;

		vec2  delta = uv - r.xy;
		delta.x    *= aspect_ratio;          // correct for widescreen UVs
		float dist  = length(delta);
		if (dist < 0.0001) continue;

		// Ring propagates outward; decays with age and distance
		float env   = exp(-age * 1.8) * exp(-dist * 5.5);
		float front = dist - age * 0.40;     // ring front position
		float wave  = sin(front * 48.0) * env * r.w;
		float dwave = cos(front * 48.0) * 48.0 * env * r.w;

		out_.x   += wave;
		out_.yz  += normalize(delta) * dwave;
	}
	return out_;
}

// ══════════════════════════════════════════════════════════════════════════
//  Fragment
// ══════════════════════════════════════════════════════════════════════════

void fragment() {
	vec2 uv = UV;

	// ── Gerstner wave field ─────────────────────────────────────────────
	vec3  wf = wave_field(uv * wave_scale);
	float wh = wf.x;
	vec2  wg = vec2(wf.y, wf.z);   // surface gradient

	// ── Ripple contributions ────────────────────────────────────────────
	vec3  rf = ripple_field(uv);
	float rh = rf.x;
	vec2  rg = rf.yz;

	// ── Synthesise surface normal from combined gradients ───────────────
	// N = normalise(-dh/dx, -dh/dy, 1) — standard height-field normal
	vec2  raw_g = wg * wave_height * 8.0 + rg * wave_height * 22.0;
	vec3  N     = normalize(vec3(-raw_g.x, -raw_g.y, 1.0));

	// ── Refraction — distort the screen sample using the surface normal ─
	vec2  refr_uv = clamp(SCREEN_UV + raw_g * wave_height, vec2(0.001), vec2(0.999));
	vec3  refr    = texture(screen_texture, refr_uv).rgb;

	// ── Depth vignette (edge = deep, centre = shallow) ──────────────────
	float depth = clamp(length((uv - 0.5) * 1.85), 0.0, 1.0);

	// ── Caustics ────────────────────────────────────────────────────────
	float caust = caustics_val(uv) * (1.0 - depth * 0.55);

	// ── Large-scale surface shimmer (light dancing on a still day) ──────
	float shimmer = fbm4(uv * 3.2 + vec2(TIME * 0.10, TIME * 0.07)) * 0.18;

	// ── Foam ────────────────────────────────────────────────────────────
	// 1. Crest foam — where the summed wave height exceeds the threshold
	float total_h    = wh + rh * 2.0;
	float crest_foam = smoothstep(foam_threshold - 0.07, foam_threshold, total_h * 0.5 + 0.5);
	// 2. Ripple ring foam — along the ring edge
	float rip_foam   = smoothstep(0.03, 0.16, abs(rh));
	// 3. Organic noise mask so foam has a natural torn-edge look
	float foam_tex   = fbm4(uv * 22.0 + TIME * 0.28);
	float foam       = clamp((crest_foam * 0.55 + rip_foam * 0.95) * (foam_tex * 0.5 + 0.5), 0.0, 1.0);

	// ── Blinn-Phong specular ─────────────────────────────────────────────
	// View is top-down; light orbits slowly for an animated sun reflection
	vec3  V    = vec3(0.0, 0.0, 1.0);
	float lt   = TIME * 0.14;
	vec3  L    = normalize(vec3(cos(lt) * 0.75, sin(lt * 0.78) * 0.75, 1.0));
	vec3  H    = normalize(L + V);                             // half-vector
	float spec = pow(max(0.0, dot(N, H)), specular_power)
	           * specular_strength * (0.6 + audio_level * 0.7);

	// ── Colour composite ─────────────────────────────────────────────────
	// Base water: shallow turquoise at centre, deep navy at edges
	vec3 water = mix(color_shallow, color_deep, pow(depth, 0.75));

	// Caustic brightening — stronger at centre
	water += color_caustic * caust * 0.45;

	// Surface shimmer
	water += color_shallow * shimmer * (1.0 - depth * 0.7);

	// Blend in refracted content below (more transparent at centre)
	vec3 color = mix(water, refr, 0.16 + (1.0 - depth) * 0.10);

	// Ripple tint — slight brightening along the ring front
	color = mix(color, color_shallow * 1.55, clamp(abs(rh) * 3.2, 0.0, 0.22));

	// Foam overlay
	color = mix(color, color_foam, foam);

	// Specular glints on top
	color += color_foam * spec;

	// Edge deepening
	color = mix(color, color_deep * 0.25, smoothstep(0.72, 1.0, depth));

	// Gentle gamma (HDR-style tonemapping)
	color = pow(clamp(color, vec3(0.0), vec3(1.8)), vec3(0.88));

	COLOR = vec4(color, opacity);
}
