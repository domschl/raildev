shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

uniform vec3 bubble_center = vec3(0.0, 0.0, 0.0);
uniform float bubble_radius = 1.15;
uniform float zoom_fade = 1.0;

varying vec3 v_world_pos;
varying vec3 v_local_pos;
varying vec3 v_world_n;

float hash21(vec2 p) {
    p = fract(p * vec2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

void vertex() {
    v_local_pos = VERTEX;
    vec3 inst_origin = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
    float d = length(inst_origin.xz - bubble_center.xz);
    // Smooth radial scale fade at the outer rim of the detail bubble + zoom-distance fade (ZERO popping!)
    float radial_fade = 1.0 - smoothstep(bubble_radius * 0.68, bubble_radius, d);
    float s = clamp(radial_fade * zoom_fade, 0.0, 1.0);

    // Subtle Alpine breeze sway near tree crowns
    float phase = inst_origin.x * 17.3 + inst_origin.z * 23.1;
    float sway_w = max(0.0, VERTEX.y - 0.15) * s;
    vec3 v = VERTEX * s;
    v.x += sin(TIME * 1.15 + phase) * 0.022 * sway_w;
    v.z += cos(TIME * 0.95 + phase * 1.3) * 0.018 * sway_w;

    VERTEX = v;
    v_world_pos = (MODEL_MATRIX * vec4(v, 1.0)).xyz;
    v_world_n = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
    // Combine baked vertex color (trunk vs foliage) with per-instance Sentinel-2 forest tint
    vec3 col = COLOR.rgb;

    // Soft vertical crown AO (darker shaded understory, sunlit upper needles/leaves)
    float crown_ao = mix(0.68, 1.08, smoothstep(0.0, 1.35, v_local_pos.y));
    float sky_lift = mix(0.84, 1.06, clamp(v_world_n.y * 0.5 + 0.5, 0.0, 1.0));
    float micro = 0.92 + 0.16 * hash21(floor(v_world_pos.xz * 480.0));

    ALBEDO = col * crown_ao * sky_lift * micro;
    ROUGHNESS = 0.88;
    SPECULAR = 0.12;
}
