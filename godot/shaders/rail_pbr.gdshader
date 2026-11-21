shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

uniform sampler2D tex_ballast     : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D tex_ballast_n   : hint_normal,  filter_linear_mipmap, repeat_enable;
uniform sampler2D tex_wood_ties   : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D tex_wood_ties_n : hint_normal,  filter_linear_mipmap, repeat_enable;
uniform sampler2D tex_metal       : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D tex_metal_n     : hint_normal,  filter_linear_mipmap, repeat_enable;
uniform sampler2D tex_wall        : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D tex_wall_n      : hint_normal,  filter_linear_mipmap, repeat_enable;

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

    // Triplanar UV & tangent frame in world space (or local space for moving trains so textures stay locked to the body!)
    vec3 sample_p = (v_uv.y > 0.001) ? v_world_pos : v_local_pos;
    float tri_scale = (v_uv.y > 0.001) ? 140.0 : 2.8;
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

    float lum = dot(base_col, vec3(0.299, 0.587, 0.114));

    // Material classification:
    // 1. Track sleeper strip (curve-aligned UVs set in _build_edge_mesh: v_uv.x in [0..1], v_uv.y > 0.01)
    float is_sleeper = step(0.005, v_uv.y) * smoothstep(0.26, 0.19, lum) * step(0.75, wn.y);
    // 2. Track ballast / stone embankment (v_uv.y > 0.001 and warm grey-brown, not steel rail)
    float is_rail    = step(0.005, v_uv.y) * smoothstep(0.01, 0.04, base_col.b - base_col.r);
    float is_ballast = step(0.005, v_uv.y) * (1.0 - is_sleeper) * (1.0 - is_rail);
    // 3. Trains, stations & signals (v_uv.y <= 0.005)
    float is_brass     = smoothstep(0.18, 0.40, base_col.r - base_col.b) * smoothstep(0.45, 0.72, base_col.g);
    float is_glass     = smoothstep(0.05, 0.16, base_col.b - base_col.r) * smoothstep(0.40, 0.65, base_col.b);
    float is_dark_iron = smoothstep(0.28, 0.14, lum) * (1.0 - is_sleeper) * (1.0 - is_ballast);
    float is_masonry   = (1.0 - step(0.005, v_uv.y)) * smoothstep(0.32, 0.55, lum) * (1.0 - is_brass) * (1.0 - is_glass);

    // Sample PBR albedo + tangent-space normal maps
    vec3 bal_alb = texture(tex_ballast, v_world_pos.xz * 240.0).rgb;
    vec3 bal_nm  = texture(tex_ballast_n, v_world_pos.xz * 240.0).rgb * 2.0 - 1.0;

    vec3 tie_alb = texture(tex_wood_ties, vec2(v_uv.x, v_uv.y)).rgb;
    vec3 tie_nm  = texture(tex_wood_ties_n, vec2(v_uv.x, v_uv.y)).rgb * 2.0 - 1.0;

    vec3 met_alb = texture(tex_metal, uv_tri * tri_scale).rgb;
    vec3 met_nm  = texture(tex_metal_n, uv_tri * tri_scale).rgb * 2.0 - 1.0;

    vec3 wal_alb = texture(tex_wall, uv_tri * (tri_scale * 0.85)).rgb;
    vec3 wal_nm  = texture(tex_wall_n, uv_tri * (tri_scale * 0.85)).rgb * 2.0 - 1.0;

    // Select surface texture multiplier & normal map
    vec3 tex_mul = mix(met_alb * 1.18, wal_alb * 1.24, is_masonry);
    tex_mul = mix(tex_mul, bal_alb * 1.42, is_ballast);
    tex_mul = mix(tex_mul, tie_alb * 1.45, is_sleeper);
    tex_mul = mix(tex_mul, met_alb * 1.28, is_rail);

    vec3 nm = mix(met_nm * 0.45, wal_nm * 0.50, is_masonry);
    nm = mix(nm, bal_nm * 0.88, is_ballast);
    nm = mix(nm, tie_nm * 0.85, is_sleeper);
    nm = mix(nm, met_nm * 0.30, is_rail);
    nm *= (1.0 - is_glass);

    vec3 col = mix(vec3(lum), base_col, 0.85) * tex_mul;
    col = min(col, vec3(0.78));

    vec3 pert_n = normalize(wn + t_u * nm.x + t_v * nm.y);

    float ground_ao = mix(0.76, 1.0, smoothstep(-0.02, 0.14, v_local_pos.y));
    ground_ao = mix(ground_ao, 1.0, step(0.005, v_uv.y));
    float sky_ao = mix(0.84, 1.04, clamp(pert_n.y * 0.5 + 0.5, 0.0, 1.0));

    ALBEDO = col * ground_ao * sky_ao;
    METALLIC = clamp(is_brass * 0.80 + is_dark_iron * 0.42 + is_rail * 0.72, 0.0, 0.88);
    ROUGHNESS = clamp(
        0.86 - is_brass * 0.54 - is_glass * 0.60 - is_dark_iron * 0.34 - is_rail * 0.52 + is_ballast * 0.08,
        0.16, 0.96);
    SPECULAR = mix(0.30, 0.84, max(max(is_brass, is_glass), is_rail));
    NORMAL = normalize((VIEW_MATRIX * vec4(pert_n, 0.0)).xyz);
}
