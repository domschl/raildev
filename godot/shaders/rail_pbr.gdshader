shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

// asset_mode: 0 = track/rolling stock/signals/portals, 2 = architectural station (with facade atlas, roof tiles & cobble)
uniform int asset_mode = 0;

uniform sampler2D tex_ballast      : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D tex_ballast_n    : hint_normal,  filter_linear_mipmap, repeat_enable;
uniform sampler2D tex_wood_ties    : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D tex_wood_ties_n  : hint_normal,  filter_linear_mipmap, repeat_enable;
uniform sampler2D tex_metal        : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D tex_metal_n      : hint_normal,  filter_linear_mipmap, repeat_enable;
uniform sampler2D tex_wall         : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D tex_wall_n       : hint_normal,  filter_linear_mipmap, repeat_enable;
uniform sampler2D tex_roof         : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D tex_roof_n       : hint_normal,  filter_linear_mipmap, repeat_enable;
uniform sampler2D tex_cobble       : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D tex_cobble_n     : hint_normal,  filter_linear_mipmap, repeat_enable;
uniform sampler2D tex_facade_atlas   : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D tex_facade_atlas_n : hint_normal,  filter_linear_mipmap, repeat_enable;

varying vec3 v_world_pos;
varying vec3 v_local_pos;
varying vec3 v_world_n;
varying vec2 v_uv;

void vertex() {
    v_local_pos = VERTEX;
    v_uv = UV;
    v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
    v_world_n = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
    vec3 base_col = COLOR.rgb;
    vec3 wn = normalize(v_world_n);
    vec3 an = abs(wn);
    float lum = dot(base_col, vec3(0.299, 0.587, 0.114));

    // Triplanar tangent frame in world space
    vec3 sample_p = (v_uv.y > 0.001 || asset_mode == 2) ? v_world_pos : v_local_pos;
    float tri_scale = (v_uv.y > 0.001 || asset_mode == 2) ? 160.0 : 2.8;
    vec2 uv_tri;
    vec3 t_u;
    vec3 t_v;
    if (an.y > 0.55) {
        uv_tri = sample_p.xz;
        t_u = vec3(1.0, 0.0, 0.0);
        t_v = vec3(0.0, 0.0, 1.0);
    } else if (an.x > an.z) {
        uv_tri = vec2(sample_p.z, sample_p.y);
        t_u = vec3(0.0, 0.0, 1.0);
        t_v = vec3(0.0, 1.0, 0.0);
    } else {
        uv_tri = vec2(sample_p.x, sample_p.y);
        t_u = vec3(1.0, 0.0, 0.0);
        t_v = vec3(0.0, 1.0, 0.0);
    }

    vec3 view_w = normalize((INV_VIEW_MATRIX * vec4(VIEW, 0.0)).xyz);
    vec2 view_ts = vec2(dot(view_w, t_u), dot(view_w, t_v)) / max(abs(dot(view_w, wn)), 0.35);

    if (asset_mode == 2) {
        // ===== ARCHITECTURAL EUROPEAN RAILWAY STATION PBR =====
        // Classify surfaces by semantic vertex color from blender_generate_stations.py
        float is_brick   = smoothstep(0.16, 0.28, base_col.r - base_col.b) * smoothstep(0.55, 0.68, base_col.r) * step(an.y, 0.70);
        float is_roof    = smoothstep(0.16, 0.28, base_col.r - base_col.b) * smoothstep(0.20, 0.45, wn.y) * smoothstep(0.60, 0.72, v_local_pos.y);
        float is_copper  = smoothstep(0.06, 0.14, base_col.g - base_col.r) * smoothstep(0.35, 0.44, base_col.g);
        float is_glass   = smoothstep(0.06, 0.13, base_col.b - base_col.r) * smoothstep(0.22, 0.30, base_col.b) * smoothstep(0.32, 0.22, base_col.r);
        float is_win     = smoothstep(0.15, 0.11, lum) * step(an.y, 0.55) * step(0.14, v_local_pos.y);
        float is_iron    = smoothstep(0.22, 0.16, lum) * (1.0 - is_win);
        float is_ballast = step(0.75, wn.y) * step(v_local_pos.y, 0.065) * smoothstep(0.30, 0.26, lum);
        float is_rail    = step(0.75, wn.y) * step(v_local_pos.y, 0.08) * smoothstep(0.03, 0.06, base_col.b - base_col.r) * (1.0 - is_glass);
        float is_cobble  = step(0.70, wn.y) * step(v_local_pos.y, 0.16) * (1.0 - is_ballast) * (1.0 - is_rail);
        float is_stone   = (1.0 - is_brick) * (1.0 - is_roof) * (1.0 - is_copper) * (1.0 - is_glass)
                         * (1.0 - is_win) * (1.0 - is_iron) * (1.0 - is_ballast) * (1.0 - is_rail) * (1.0 - is_cobble);

        // Brick (atlas Q3: bottom-right) and Sandstone Ashlar (atlas Q2: bottom-left) with 32px periodic gutter
        vec2 uv_br = v_uv * 1.45;
        vec2 ddx_br = dFdx(uv_br) * 0.46875;
        vec2 ddy_br = dFdy(uv_br) * 0.46875;
        vec2 uv_q3 = vec2(0.5, 0.5) + fract(uv_br) * 0.46875 + 0.015625;
        vec3 br_alb = textureGrad(tex_facade_atlas, uv_q3, ddx_br, ddy_br).rgb;
        vec4 br_nh  = textureGrad(tex_facade_atlas_n, uv_q3, ddx_br, ddy_br);

        vec2 uv_st = v_uv * 1.15;
        vec2 ddx_st = dFdx(uv_st) * 0.46875;
        vec2 ddy_st = dFdy(uv_st) * 0.46875;
        vec2 uv_q2 = vec2(0.0, 0.5) + fract(uv_st) * 0.46875 + 0.015625;
        vec3 st_alb = textureGrad(tex_facade_atlas, uv_q2, ddx_st, ddy_st).rgb;
        vec4 st_nh  = textureGrad(tex_facade_atlas_n, uv_q2, ddx_st, ddy_st);

        vec2 uv_rf = v_world_pos.xz * 210.0;
        vec3 rf_alb = texture(tex_roof, uv_rf).rgb;
        vec4 rf_nh  = texture(tex_roof_n, uv_rf);

        vec2 uv_cb = v_world_pos.xz * 120.0;
        vec3 cb_alb = texture(tex_cobble, uv_cb).rgb;
        vec4 cb_nh  = texture(tex_cobble_n, uv_cb);

        vec2 uv_bl = v_world_pos.xz * 520.0;
        vec3 bl_alb = texture(tex_ballast, uv_bl).rgb;
        vec4 bl_nh  = texture(tex_ballast_n, uv_bl);

        vec3 mt_alb = texture(tex_metal, uv_tri * 140.0).rgb;
        vec3 mt_nm  = texture(tex_metal_n, uv_tri * 140.0).rgb * 2.0 - 1.0;

        // Victorian iron-and-glass skylight glazing bars (procedural mullion grid over smoked glass)
        float mullion_u = smoothstep(0.08, 0.03, abs(fract(v_uv.x * 4.0) - 0.5));
        float mullion_v = smoothstep(0.10, 0.04, abs(fract(v_uv.y * 2.0) - 0.5));
        float is_mullion = max(mullion_u, mullion_v) * is_glass;

        vec3 col = base_col * st_alb * 1.18;
        col = mix(col, br_alb * vec3(0.96, 0.86, 0.80) * 1.02, is_brick);
        col = mix(col, base_col * rf_alb * 1.32, is_roof);
        col = mix(col, base_col * cb_alb * 1.38, is_cobble);
        col = mix(col, bl_alb * 0.72, is_ballast);
        col = mix(col, mt_alb * vec3(0.68, 0.70, 0.73), is_rail);
        col = mix(col, base_col * mt_alb * 1.15, max(is_iron, is_copper));
        // Dark smoked blue-green Victorian train shed glass + dark iron glazing bars
        vec3 glass_col = mix(vec3(0.14, 0.21, 0.26), vec3(0.11, 0.12, 0.14), is_mullion);
        col = mix(col, glass_col, is_glass);
        // Subtle warm interior station glow in headhouse windows
        col = mix(col, vec3(0.28, 0.23, 0.16), is_win * 0.75);
        col = min(col, vec3(0.80));

        vec3 nm = (st_nh.rgb * 2.0 - 1.0) * 0.65;
        nm = mix(nm, (br_nh.rgb * 2.0 - 1.0) * 0.78, is_brick);
        nm = mix(nm, (rf_nh.rgb * 2.0 - 1.0) * 0.90, is_roof);
        nm = mix(nm, (cb_nh.rgb * 2.0 - 1.0) * 0.80, is_cobble);
        nm = mix(nm, (bl_nh.rgb * 2.0 - 1.0) * 0.85, is_ballast);
        nm = mix(nm, mt_nm * 0.35, max(max(is_iron, is_copper), is_rail));
        nm *= (1.0 - max(is_win, is_glass * (1.0 - is_mullion)));

        vec3 pert_n = normalize(wn + t_u * nm.x + t_v * nm.y);
        float ground_ao = mix(0.45, 1.00, smoothstep(-0.04, 0.28, v_local_pos.y));
        ground_ao = mix(ground_ao, 0.96, max(is_cobble, is_ballast));
        float sky_ao = mix(0.82, 1.04, clamp(pert_n.y * 0.5 + 0.5, 0.0, 1.0));

        ALBEDO = col * ground_ao * sky_ao;
        METALLIC = clamp(is_iron * 0.65 + is_mullion * 0.65 + is_copper * 0.58 + is_rail * 0.85 + is_glass * 0.16, 0.0, 0.90);
        ROUGHNESS = clamp(
            0.82 - is_iron * 0.38 - is_copper * 0.42 - is_rail * 0.60 - is_win * 0.62 - is_glass * (1.0 - is_mullion) * 0.68,
            0.12, 0.95);
        SPECULAR = mix(0.28, 0.88, max(max(is_glass, is_win), max(is_rail, is_copper)));
        NORMAL = normalize((VIEW_MATRIX * vec4(pert_n, 0.0)).xyz);
    } else {
    // ===== TRACKS, TRAINS, SIGNALS & TUNNEL PORTALS (asset_mode == 0) =====
    // Vertex COLOR in fragment() is LINEARIZED by Godot:
    //   col_ballast (0.28) -> linear lum ~0.06 | col_bridge (0.56) -> linear lum ~0.24
    //   col_sleeper (0.96) -> linear lum ~0.87 | col_rail (b-r) -> linear ~0.15
    float is_rail    = step(0.005, v_uv.y) * smoothstep(0.05, 0.11, base_col.b - base_col.r);
    float is_sleeper = step(0.005, v_uv.y) * smoothstep(0.55, 0.72, lum) * (1.0 - is_rail) * step(0.75, wn.y);
    float is_ballast = step(0.005, v_uv.y) * (1.0 - is_sleeper) * (1.0 - is_rail);
    float is_bridge  = is_ballast * smoothstep(0.14, 0.21, lum);
    // 2. Trains, signals & tunnel portals (v_uv.y <= 0.005)
    float is_brass     = (1.0 - step(0.005, v_uv.y)) * smoothstep(0.18, 0.40, base_col.r - base_col.b) * smoothstep(0.45, 0.72, base_col.g);
    float is_glass     = (1.0 - step(0.005, v_uv.y)) * smoothstep(0.05, 0.16, base_col.b - base_col.r) * smoothstep(0.40, 0.65, base_col.b);
    float is_dark_iron = (1.0 - step(0.005, v_uv.y)) * smoothstep(0.28, 0.14, lum);
    float is_masonry   = (1.0 - step(0.005, v_uv.y)) * smoothstep(0.32, 0.55, lum) * (1.0 - is_brass) * (1.0 - is_glass);

    // Fine-scale crushed granite ballast (triplanar so BOTH ballast crown and sloped embankments stay crisp!)
    vec2 uv_bal = uv_tri * 240.0;
    float h_bal = texture(tex_ballast_n, uv_bal).a;
    vec2 uv_bal_p = uv_bal - view_ts * (h_bal - 0.5) * 0.020;
    vec3 bal_alb = texture(tex_ballast, uv_bal_p).rgb;
    vec4 bal_nh  = texture(tex_ballast_n, uv_bal_p);
    vec3 bal_nm  = bal_nh.rgb * 2.0 - 1.0;

    // Curve-aligned 1024px AI creosote oak sleepers + iron tie-plates + granite ballast
    vec3 tie_alb = texture(tex_wood_ties, vec2(v_uv.x, v_uv.y)).rgb;
    vec4 tie_nh  = texture(tex_wood_ties_n, vec2(v_uv.x, v_uv.y));
    vec3 tie_nm  = tie_nh.rgb * 2.0 - 1.0;

    vec3 met_alb = texture(tex_metal, uv_tri * tri_scale).rgb;
    vec3 met_nm  = texture(tex_metal_n, uv_tri * tri_scale).rgb * 2.0 - 1.0;

    vec3 wal_alb = texture(tex_wall, uv_tri * (tri_scale * 0.85)).rgb;
    vec4 wal_nh  = texture(tex_wall_n, uv_tri * (tri_scale * 0.85));
    vec3 wal_nm  = wal_nh.rgb * 2.0 - 1.0;

    // Compose albedo
    vec3 tex_mul = mix(met_alb * 1.18, wal_alb * 1.24, is_masonry);
    vec3 col = mix(vec3(lum), base_col, 0.85) * tex_mul;

    // Ballast & sloped embankment: crisp crushed granite on crown/shoulder, grassy-earth berm on lower slope!
    float is_berm  = is_ballast * (1.0 - is_bridge) * smoothstep(0.008, 0.022, base_col.g - base_col.r);
    vec3 bal_tint = mix(vec3(0.32, 0.30, 0.27), vec3(0.46, 0.43, 0.39), is_bridge);
    bal_tint = mix(bal_tint, vec3(0.16, 0.22, 0.12), is_berm);
    vec3 bal_col = bal_alb * bal_tint * (0.64 + 0.46 * bal_nh.a);
    col = mix(col, bal_col, is_ballast);
    // Sleepers: crisp 1024px AI creosote-oak ties + iron tie-plates + granite ballast
    vec3 slp_col = tie_alb * vec3(1.15, 1.10, 1.02) * (0.72 + 0.42 * tie_nh.a);
    col = mix(col, slp_col, is_sleeper);
    // Gleaming burnished steel railheads (dark gunmetal base + crisp specular glint, never baby-blue!)
    vec3 rail_col = met_alb * vec3(0.54, 0.56, 0.58);
    col = mix(col, rail_col, is_rail);
    col = min(col, vec3(0.84));

    vec3 nm = mix(met_nm * 0.45, wal_nm * 0.52, is_masonry);
    nm = mix(nm, bal_nm * 0.95, is_ballast);
    nm = mix(nm, tie_nm * 0.92, is_sleeper);
    nm = mix(nm, met_nm * 0.22, is_rail);
    nm *= (1.0 - is_glass);

    vec3 pert_n = normalize(wn + t_u * nm.x + t_v * nm.y);

    float ground_ao = mix(0.76, 1.0, smoothstep(-0.02, 0.14, v_local_pos.y));
    ground_ao = mix(ground_ao, 1.0, step(0.005, v_uv.y));
    float sky_ao = mix(0.84, 1.04, clamp(pert_n.y * 0.5 + 0.5, 0.0, 1.0));

    ALBEDO = col * ground_ao * sky_ao;
    METALLIC = clamp(is_brass * 0.80 + is_dark_iron * 0.42 + is_rail * 0.86, 0.0, 0.90);
    ROUGHNESS = clamp(
        0.88 - is_brass * 0.54 - is_glass * 0.60 - is_dark_iron * 0.34 - is_rail * 0.66 + is_ballast * 0.06,
        0.16, 0.96);
    SPECULAR = mix(0.28, 0.90, max(max(is_brass, is_glass), is_rail));
    NORMAL = normalize((VIEW_MATRIX * vec4(pert_n, 0.0)).xyz);
    }
}
