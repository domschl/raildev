shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_back, diffuse_burley, specular_schlick_ggx;

uniform vec3 bubble_center = vec3(0.0, 0.0, 0.0);
uniform float bubble_radius = 1.15;
uniform float zoom_fade = 1.0;

uniform sampler2D tex_cobble   : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D tex_cobble_n : hint_normal,  filter_linear_mipmap, repeat_enable;

varying vec2 v_uv;
varying vec3 v_world_pos;
varying vec3 v_world_n;
varying vec4 v_inst_custom;

float hash21(vec2 p) {
    p = fract(p * vec2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

float vnoise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    vec2 u = f * f * (3.0 - 2.0 * f);
    return mix(
        mix(hash21(i), hash21(i + vec2(1.0, 0.0)), u.x),
        mix(hash21(i + vec2(0.0, 1.0)), hash21(i + vec2(1.0, 1.0)), u.x),
        u.y
    );
}

void vertex() {
    v_uv = UV;
    v_inst_custom = INSTANCE_CUSTOM;
    vec3 inst_origin = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
    float d = length(inst_origin.xz - bubble_center.xz);
    float radial_fade = 1.0 - smoothstep(bubble_radius * 0.68, bubble_radius, d);
    float s = clamp(radial_fade * zoom_fade, 0.0, 1.0);
    vec3 v = VERTEX * s;
    VERTEX = v;
    v_world_pos = (MODEL_MATRIX * vec4(v, 1.0)).xyz;
    v_world_n = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
    vec2 p = v_uv * 2.0 - 1.0;
    vec2 wp = v_world_pos.xz;

    // Multi-frequency world-space noise breaks up the yard outline so it NEVER reads as a geometric box
    float n1 = vnoise(wp * 42.0 + vec2(v_inst_custom.z * 17.0, v_inst_custom.w * 23.0));
    float n2 = vnoise(wp * 115.0 + vec2(3.7, 9.1));
    float n_org = n1 * 0.65 + n2 * 0.35;

    // Rounded-rectangle SDF for the house yard/courtyard apron + organic noise warp
    vec2 q = abs(p) - vec2(0.38, 0.30);
    float sdf = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0);
    float d_warped = sdf + (n_org - 0.5) * 0.26;

    // Tight soft ambient-occlusion contact shadow right where house walls meet the ground
    vec2 q_ao = abs(p) - vec2(0.32, 0.24);
    float sdf_ao = length(max(q_ao, 0.0));
    float contact_ao = 1.0 - smoothstep(0.0, 0.34, sdf_ao + (n2 - 0.5) * 0.10);

    // Feathered outer mask guaranteed to reach 0.0 before quad edge
    float edge_guard = 1.0 - smoothstep(0.72, 0.96, max(abs(p.x), abs(p.y)));
    float yard_mask = (1.0 - smoothstep(0.10, 0.44, d_warped)) * edge_guard;
    float alpha = clamp(max(yard_mask * 0.78, contact_ao * 0.88) * zoom_fade, 0.0, 0.92);
    if (alpha < 0.015) {
        discard;
    }

    // World-space cobblestone / gravel / garden earth surface variation per building
    vec2 uv_c = wp * 155.0;
    vec3 cob = texture(tex_cobble, uv_c).rgb;
    vec4 cob_nh = texture(tex_cobble_n, uv_c);
    vec3 cob_nm = cob_nh.rgb * 2.0 - 1.0;

    float style = v_inst_custom.x;
    // Style 0: weathered stone/gravel yard, Style 1: mossy courtyard, Style 2: dark tended garden earth
    vec3 yard_col = (style < 0.5) ? (cob * vec3(0.50, 0.48, 0.43)) :
                    (style < 1.5) ? (cob * vec3(0.36, 0.40, 0.28)) :
                                    (cob * vec3(0.34, 0.30, 0.24));
    // Mossy fringe along the outer edge of the yard pad
    float outer_moss = smoothstep(0.04, 0.30, d_warped) * smoothstep(0.35, 0.72, n_org);
    yard_col = mix(yard_col, vec3(0.18, 0.25, 0.14) * (0.75 + 0.45 * cob_nh.a), outer_moss * 0.65);

    // Deepen ground directly under/around house walls with realistic contact AO
    float ao_mul = mix(0.95, 0.24, contact_ao * 0.92);
    yard_col *= ao_mul * (0.76 + 0.36 * cob_nh.a);

    vec3 wn = normalize(v_world_n);
    vec3 pert_n = normalize(wn + vec3(cob_nm.x, 0.0, cob_nm.y) * 0.55);

    ALBEDO = yard_col;
    ALPHA = alpha;
    ROUGHNESS = clamp(0.88 - 0.12 * cob_nh.a + outer_moss * 0.08, 0.65, 0.98);
    SPECULAR = 0.08;
    NORMAL = normalize((VIEW_MATRIX * vec4(pert_n, 0.0)).xyz);
}
