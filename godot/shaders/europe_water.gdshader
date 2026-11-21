shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

uniform sampler2D height_tex : filter_linear, repeat_disable;
uniform sampler2D splat_tex  : filter_linear, repeat_disable;
uniform sampler2D water_tex  : source_color, filter_linear_mipmap, repeat_enable;

varying vec2 v_uv;

void vertex() {
    v_uv = UV;
}

void fragment() {
    float elev = texture(height_tex, v_uv).r;
    if (elev > 4.0) {
        discard;
    }

    float depth = max(0.0, -elev);

    // Dual-scrolling gentle ocean currents & fine ripples
    vec2 uv_a = v_uv * vec2(48.0, 36.0) + vec2(TIME * 0.0018, TIME * 0.0011);
    vec2 uv_b = v_uv * vec2(84.0, 63.0) - vec2(TIME * 0.0013, -TIME * 0.0016);
    vec3 w_a = texture(water_tex, uv_a).rgb;
    vec3 w_b = texture(water_tex, uv_b).rgb;
    float ripple = ((w_a.b + w_b.b) * 0.5 - 0.5);

    // Bathymetric ocean colors: shallow turquoise shelf -> cerulean -> deep navy abyss
    vec3 shallow_col = vec3(0.24, 0.56, 0.66);
    vec3 shelf_col   = vec3(0.14, 0.39, 0.55);
    vec3 deep_col    = vec3(0.07, 0.20, 0.36);

    float t1 = smoothstep(0.0, 160.0, depth);
    float t2 = smoothstep(140.0, 1200.0, depth);
    vec3 water_col = mix(mix(shallow_col, shelf_col, t1), deep_col, t2);
    water_col += vec3(0.025, 0.035, 0.045) * ripple;

    // Subtle animated shoreline foam right along the coast
    float foam_band = smoothstep(14.0, 1.5, depth) * step(0.01, depth);
    float foam_wave = 0.5 + 0.5 * sin(depth * 0.8 - TIME * 0.55 + ripple * 4.0);
    float foam = foam_band * (0.25 + 0.35 * foam_wave);
    water_col = mix(water_col, vec3(0.86, 0.91, 0.94), foam * 0.28);

    // Subtle nautical shipping lanes over open water
    float sea_lane = texture(splat_tex, v_uv).b * step(8.0, depth);
    water_col = mix(water_col, vec3(0.82, 0.88, 0.92), smoothstep(0.15, 0.45, sea_lane) * 0.28);

    // Subtle wave normal perturbation for sunlight sparkle
    vec3 wave_n = normalize(vec3(
        (w_a.r - w_b.r) * 0.055,
        1.0,
        (w_a.g - w_b.g) * 0.055
    ));

    // Smooth transparency right at the shoreline, opaque in deeper sea
    float alpha = smoothstep(-0.5, 18.0, depth);
    alpha = clamp(0.68 + 0.30 * alpha + foam * 0.2, 0.0, 0.98);

    ALBEDO = water_col;
    ALPHA = alpha;
    ROUGHNESS = mix(0.14, 0.45, foam);
    SPECULAR = 0.72;
    NORMAL = normalize((VIEW_MATRIX * vec4(wave_n, 0.0)).xyz);
}
