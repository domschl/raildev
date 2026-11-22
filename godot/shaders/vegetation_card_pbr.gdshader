shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_disabled, diffuse_burley, specular_schlick_ggx;

uniform vec3 bubble_center = vec3(0.0, 0.0, 0.0);
uniform float bubble_radius = 1.35;
uniform float zoom_fade = 1.0;

uniform sampler2D tex_card   : source_color, filter_linear_mipmap, repeat_disable;
uniform sampler2D tex_card_n : hint_normal,  filter_linear_mipmap, repeat_disable;

varying vec3 v_local_pos;
varying vec2 v_uv;

void vertex() {
    v_local_pos = VERTEX;
    v_uv = UV;

    vec3 inst_origin = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
    float d = length(inst_origin.xz - bubble_center.xz);
    float radial_fade = 1.0 - smoothstep(bubble_radius * 0.68, bubble_radius, d);
    float s = clamp(radial_fade * zoom_fade, 0.0, 1.0);

    // Gentle Alpine breeze sway (stiff lower trunk, quadratic flex only near upper crown)
    float phase = inst_origin.x * 17.3 + inst_origin.z * 23.1;
    float h_flex = max(0.0, VERTEX.y - 0.35);
    float sway_w = h_flex * h_flex * s;
    vec3 v = VERTEX * s;
    v.x += sin(TIME * 0.78 + phase) * 0.0065 * sway_w;
    v.z += cos(TIME * 0.64 + phase * 1.3) * 0.0052 * sway_w;

    // Subtle high-frequency rustle at outer bough tips
    float tip_w = UV.y * UV.y * s;
    float flutter = sin(TIME * 2.4 + phase * 2.3 + VERTEX.x * 9.0 + VERTEX.z * 7.0) * 0.0045 * tip_w;
    v.y += flutter;
    v.x += flutter * 0.5;

    VERTEX = v;
}

void fragment() {
    vec4 card = texture(tex_card, v_uv);
    ALPHA = card.a;
    // Lower threshold + zero-halo dilated RGB keeps fine pine needles lush even at mip distance
    ALPHA_SCISSOR_THRESHOLD = 0.28;

    vec4 nh = texture(tex_card_n, v_uv);
    NORMAL_MAP = nh.rgb;
    NORMAL_MAP_DEPTH = 0.80;

    // Harmonize botanical bough albedo with LOD1 Sentinel-2 forest palette + baked inner-crown AO (COLOR)
    vec3 inst_tint = COLOR.rgb;
    float card_lum = dot(card.rgb, vec3(0.299, 0.587, 0.114));
    // Deep, natural European woodland tone that seamlessly matches LOD1 trees behind it
    vec3 tinted = card.rgb * mix(vec3(0.74, 0.78, 0.72), inst_tint * 1.15, 0.70);
    // Preserve warm woody twig color where card is brownish
    float is_twig = smoothstep(0.02, 0.10, card.r - card.g);
    vec3 col = mix(tinted, card.rgb * (0.58 + 0.30 * inst_tint.r), is_twig);

    // Root-to-crown AO (matches vegetation_pbr.gdshader) + height-packed micro-AO
    float crown_ao = mix(0.46, 1.04, smoothstep(0.0, 1.40, v_local_pos.y));
    float micro_ao = 0.80 + 0.24 * nh.a;
    vec3 final_col = clamp(col * crown_ao * micro_ao, vec3(0.015), vec3(0.75));

    ALBEDO = final_col;
    // Subtle sunlit needle/leaf translucency without washing out dark forest depth
    BACKLIGHT = final_col * 0.20 * (1.0 - is_twig) * (0.55 + 0.45 * card_lum);
    ROUGHNESS = mix(0.84, 0.94, is_twig);
    SPECULAR = mix(0.14, 0.06, is_twig);
}
