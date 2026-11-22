shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

uniform vec3 bubble_center = vec3(0.0, 0.0, 0.0);
uniform float bubble_radius = 0.95;
uniform float zoom_fade = 1.0;

uniform sampler2D tex_roof          : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D tex_roof_n        : hint_normal,  filter_linear_mipmap, repeat_enable;
uniform sampler2D tex_wall          : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D tex_wall_n        : hint_normal,  filter_linear_mipmap, repeat_enable;
uniform sampler2D tex_cobble        : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D tex_cobble_n      : hint_normal,  filter_linear_mipmap, repeat_enable;
// Optional 2x2 UV facade atlas (slot in AI-generated 4-style European facades with zero code changes!)
uniform bool use_facade_atlas = false;
uniform sampler2D tex_facade_atlas   : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D tex_facade_atlas_n : hint_normal,  filter_linear_mipmap, repeat_enable;

varying vec3 v_world_pos;
varying vec3 v_local_pos;
varying vec3 v_world_n;
varying vec2 v_uv;
varying vec4 v_inst_custom;

void vertex() {
    v_local_pos = VERTEX;
    v_uv = UV;
    v_inst_custom = INSTANCE_CUSTOM;
    vec3 inst_origin = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
    float d = length(inst_origin.xz - bubble_center.xz);
    float radial_fade = 1.0 - smoothstep(bubble_radius * 0.68, bubble_radius, d);
    float s = clamp(radial_fade * zoom_fade, 0.0, 1.0);
    vec3 v = VERTEX * s;
    // Deepen underground foundation plinth vertices (y < -0.05) so buildings NEVER float on hills or slopes!
    if (VERTEX.y < -0.05) {
        v.y -= 1.80 * s;
    }
    VERTEX = v;
    v_world_pos = (MODEL_MATRIX * vec4(v, 1.0)).xyz;
    v_world_n = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
    vec3 base_col = COLOR.rgb;
    vec3 wn = normalize(v_world_n);
    vec3 an = abs(wn);

    // Triplanar UV & tangent frame (u_dir, v_dir) in world space for crisp normal perturbation
    vec2 uv_tri;
    vec3 t_u;
    vec3 t_v;
    if (an.y > 0.55) {
        uv_tri = v_world_pos.xz;
        t_u = vec3(1.0, 0.0, 0.0);
        t_v = vec3(0.0, 0.0, 1.0);
    } else if (an.x > an.z) {
        uv_tri = vec2(v_world_pos.z, v_world_pos.y);
        t_u = vec3(0.0, 0.0, 1.0);
        t_v = vec3(0.0, 1.0, 0.0);
    } else {
        uv_tri = vec2(v_world_pos.x, v_world_pos.y);
        t_u = vec3(1.0, 0.0, 0.0);
        t_v = vec3(0.0, 1.0, 0.0);
    }

    float lum = dot(base_col, vec3(0.299, 0.587, 0.114));
    float is_win = smoothstep(0.18, 0.09, lum) * step(0.10, v_local_pos.y) * step(an.y, 0.45);
    float is_plaza = step(0.85, wn.y) * step(abs(v_local_pos.y), 0.08);
    float is_roof = smoothstep(0.20, 0.48, wn.y) * smoothstep(0.68, 0.84, v_local_pos.y) * (1.0 - is_plaza);

    // View direction in world space for subtle height-map parallax relief
    vec3 view_w = normalize((INV_VIEW_MATRIX * vec4(VIEW, 0.0)).xyz);
    vec2 view_ts = vec2(dot(view_w, t_u), dot(view_w, t_v)) / max(abs(dot(view_w, wn)), 0.35);

    // Sample PBR albedo + tangent-space normal & packed depth/height (alpha channel)
    // Per-instance style variation via INSTANCE_CUSTOM:
    //   x = facade style (0..3: plaster, half-timber, sandstone, brick)
    //   y = roof material (0..2: terracotta, Alpine slate, weathered copper-zinc)
    //   z = weathering / age seed (0..1)
    //   w = warm interior window glow seed (0..1)
    float style_idx = floor(clamp(v_inst_custom.x, 0.0, 3.99));
    float roof_idx  = floor(clamp(v_inst_custom.y, 0.0, 2.99));
    float weather_s = clamp(v_inst_custom.z, 0.0, 1.0);
    float win_seed  = v_inst_custom.w;

    vec2 uv_wall = uv_tri * 140.0;
    vec3 wall_alb;
    vec4 wall_nh;
    if (use_facade_atlas) {
        // Map model UV into the selected 2x2 quadrant of the 2048x2048 AI facade atlas.
        // Each 1024x1024 quadrant has a 960x960 seamless core + 32px periodic wrap gutter:
        //   span = 960/2048 = 0.46875, margin = 32/2048 = 0.015625.
        float uv_tile_scale = (style_idx < 0.5) ? 1.25 :
                              (style_idx < 1.5) ? 1.00 :
                              (style_idx < 2.5) ? 1.35 :
                                                  1.65;
        vec2 uv_f = v_uv * uv_tile_scale;
        vec2 quad_off = vec2(mod(style_idx, 2.0) * 0.5, floor(style_idx * 0.5) * 0.5);
        vec2 ddx = dFdx(uv_f) * 0.46875;
        vec2 ddy = dFdy(uv_f) * 0.46875;
        vec2 uv_atlas0 = quad_off + fract(uv_f) * 0.46875 + 0.015625;
        float h_wall = textureGrad(tex_facade_atlas_n, uv_atlas0, ddx, ddy).a;
        vec2 uv_fp = uv_f - view_ts * (h_wall - 0.5) * 0.014;
        vec2 uv_atlas = quad_off + fract(uv_fp) * 0.46875 + 0.015625;
        wall_alb = textureGrad(tex_facade_atlas, uv_atlas, ddx, ddy).rgb;
        wall_nh  = textureGrad(tex_facade_atlas_n, uv_atlas, ddx, ddy);
    } else {
        float h_wall = texture(tex_wall_n, uv_wall).a;
        vec2 uv_wall_p = uv_wall - view_ts * (h_wall - 0.5) * 0.012;
        wall_alb = texture(tex_wall, uv_wall_p).rgb;
        wall_nh  = texture(tex_wall_n, uv_wall_p);
    }
    vec3 wall_nm = wall_nh.rgb * 2.0 - 1.0;

    vec2 uv_roof = v_world_pos.xz * 210.0;
    float h_roof = texture(tex_roof_n, uv_roof).a;
    vec2 uv_roof_p = uv_roof - view_ts * (h_roof - 0.5) * 0.022;
    vec3 roof_alb = texture(tex_roof, uv_roof_p).rgb;
    vec4 roof_nh  = texture(tex_roof_n, uv_roof_p);
    vec3 roof_nm  = roof_nh.rgb * 2.0 - 1.0;

    vec2 uv_cob = v_world_pos.xz * 95.0;
    float h_cob = texture(tex_cobble_n, uv_cob).a;
    vec2 uv_cob_p = uv_cob - view_ts * (h_cob - 0.5) * 0.028;
    vec3 cob_alb  = texture(tex_cobble, uv_cob_p).rgb;
    vec4 cob_nh   = texture(tex_cobble_n, uv_cob_p);
    vec3 cob_nm   = cob_nh.rgb * 2.0 - 1.0;

    // Apply per-instance roof material variation (terracotta / Alpine slate / weathered zinc-copper)
    vec3 roof_tint = (roof_idx < 0.5) ? vec3(1.06, 0.94, 0.88) :
                     (roof_idx < 1.5) ? vec3(0.56, 0.62, 0.72) :
                                        vec3(0.64, 0.76, 0.72);
    // Apply subtle per-instance facade material tint & weathering variation
    vec3 wall_style_tint = (style_idx < 0.5) ? vec3(1.02, 1.00, 0.96) :
                           (style_idx < 1.5) ? vec3(0.98, 0.95, 0.86) :
                           (style_idx < 2.5) ? vec3(0.92, 0.90, 0.84) :
                                               vec3(0.96, 0.80, 0.72);
    float age_mul = mix(0.88, 1.06, weather_s);

    // Combine surface albedo (centered around neutral gray so vertex/palette hues stay faithful)
    vec3 surf_mul = mix(wall_alb * wall_style_tint * 1.24 * age_mul, roof_alb * roof_tint * 1.22, is_roof);
    float micro_ao = mix(0.86 + 0.20 * wall_nh.a, 0.80 + 0.28 * roof_nh.a, is_roof);
    micro_ao = mix(micro_ao, 0.74 + 0.34 * cob_nh.a, is_plaza);
    vec3 col = mix(vec3(lum), base_col, 0.86) * surf_mul;
    col = mix(col, cob_alb * base_col * 1.48, is_plaza);
    col *= mix(micro_ao, 1.0, is_win);
    // Subtle warm interior reflection inside dark recessed windows (select windows softly lit)
    float win_lit = step(0.72, fract(win_seed * 13.7 + floor(v_local_pos.x * 5.0) * 0.31 + floor(v_local_pos.y * 4.0) * 0.47));
    vec3 win_col = mix(vec3(0.12, 0.16, 0.21), vec3(0.42, 0.33, 0.19), win_lit * 0.65);
    col = mix(col, win_col, is_win * 0.72);
    col = min(col, vec3(0.76));

    // Organic stone foundation plinth & creeping garden moss/ivy binding buildings into the ground!
    float vine_h = fract(sin(dot(floor(v_world_pos.xz * 260.0), vec2(127.1, 311.7))) * 43758.5453);
    float vine_wave = sin(v_world_pos.x * 420.0 + v_world_pos.z * 310.0) * 0.5 + 0.5;
    float base_stone = smoothstep(0.11, -0.02, v_local_pos.y) * (1.0 - is_plaza) * (1.0 - is_win);
    float ivy_limit = 0.06 + 0.14 * (vine_wave * 0.65 + vine_h * 0.35);
    float base_moss = smoothstep(ivy_limit, ivy_limit - 0.09, v_local_pos.y)
                    * smoothstep(0.32, 0.68, vine_wave * 0.7 + vine_h * 0.3)
                    * (1.0 - is_plaza) * (1.0 - is_win) * step(an.y, 0.65);

    vec3 stone_plinth_col = cob_alb * vec3(0.46, 0.45, 0.42);
    vec3 moss_ivy_col = mix(vec3(0.16, 0.25, 0.12), vec3(0.24, 0.33, 0.16), vine_wave);
    col = mix(col, stone_plinth_col, base_stone * 0.72);
    col = mix(col, moss_ivy_col, base_moss * 0.78);

    // Perturb world normal using sampled PBR normal map
    vec3 nm = mix(wall_nm * 0.52, roof_nm * 0.88, is_roof);
    nm = mix(nm, cob_nm * 0.85, max(is_plaza, base_stone * 0.8));
    nm *= (1.0 - is_win);
    vec3 pert_n = normalize(wn + t_u * nm.x + t_v * nm.y);

    float ground_ao = mix(0.38, 1.00, smoothstep(-0.04, 0.36, v_local_pos.y));
    ground_ao = mix(ground_ao, 0.94, is_plaza);
    float sky_ao = mix(0.82, 1.04, clamp(pert_n.y * 0.5 + 0.5, 0.0, 1.0));

    ALBEDO = col * ground_ao * sky_ao;
    float surf_rough = mix(mix(0.88 - 0.10 * wall_nh.a, 0.80 - 0.14 * roof_nh.a, is_roof), 0.78 - 0.18 * cob_nh.a, is_plaza);
    surf_rough = mix(surf_rough, 0.94, base_moss);
    ROUGHNESS = clamp(mix(surf_rough, 0.20, is_win), 0.16, 0.96);
    SPECULAR = mix(mix(0.20, 0.32, is_roof), 0.82, is_win);
    NORMAL = normalize((VIEW_MATRIX * vec4(pert_n, 0.0)).xyz);
}
