shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

uniform sampler2D height_tex : filter_linear, repeat_disable;
uniform sampler2D inset_height_tex : filter_linear, repeat_disable;
uniform sampler2D inset2_height_tex : filter_linear, repeat_disable;
uniform sampler2D europe_albedo_tex : source_color, filter_linear_mipmap, repeat_disable;
uniform sampler2D inset_albedo_tex : source_color, filter_linear_mipmap, repeat_disable;
uniform sampler2D inset2_albedo_tex : source_color, filter_linear_mipmap, repeat_disable;
uniform sampler2D inset_water_tex : filter_linear_mipmap, repeat_disable;
uniform sampler2D inset2_water_tex : filter_linear_mipmap, repeat_disable;
uniform sampler2D inset_landuse_tex : filter_linear_mipmap, repeat_disable;
uniform sampler2D inset2_landuse_tex : filter_linear_mipmap, repeat_disable;
uniform sampler2D splat_tex  : filter_linear, repeat_disable;
uniform sampler2D urban_tex  : filter_linear_mipmap, repeat_disable;

uniform sampler2D tex_grass_north : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D tex_grass_med   : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D tex_rock        : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D tex_forest      : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D tex_urban       : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D tex_grass_n     : hint_normal,  filter_linear_mipmap, repeat_enable;
uniform sampler2D tex_forest_n    : hint_normal,  filter_linear_mipmap, repeat_enable;
uniform sampler2D tex_rock_n      : hint_normal,  filter_linear_mipmap, repeat_enable;
uniform sampler2D tex_cobble      : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D tex_cobble_n    : hint_normal,  filter_linear_mipmap, repeat_enable;

uniform vec2 world_size = vec2(204.8, 153.6);
uniform vec2 height_texel = vec2(0.00024414, 0.00032552);
uniform vec4 inset_uv_rect = vec4(0.0, 0.0, 0.0, 0.0);
uniform vec2 inset_texel = vec2(0.00024414, 0.00032552);
uniform vec4 inset2_uv_rect = vec4(0.0, 0.0, 0.0, 0.0);
uniform vec2 inset2_texel = vec2(0.00024414, 0.00048828);
uniform float has_europe_albedo = 0.0;
uniform float has_inset_albedo = 0.0;
uniform float has_inset2_albedo = 0.0;
uniform float has_inset_water = 0.0;
uniform float has_inset2_water = 0.0;
uniform float has_inset_landuse = 0.0;
uniform float has_inset2_landuse = 0.0;
uniform float land_height_scale = 0.00018;
uniform float sea_depth_scale = 0.00022;
uniform vec4 detail_hole_uv = vec4(0.0, 0.0, 0.0, 0.0);
instance uniform vec4 chunk_uv_rect = vec4(0.0, 0.0, 1.0, 1.0);
instance uniform float is_detail_patch = 0.0;

varying vec2 v_uv;
varying vec3 v_world_pos;

float hash21(vec2 p) {
    p = fract(p * vec2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

float vnoise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    vec2 u = f * f * (3.0 - 2.0 * f);
    float a = hash21(i);
    float b = hash21(i + vec2(1.0, 0.0));
    float c = hash21(i + vec2(0.0, 1.0));
    float d = hash21(i + vec2(1.0, 1.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

// Multi-octave ridged fBm for sharp alpine granite cracks & rock faces
float ridge_fbm(vec2 p) {
    float sum = 0.0;
    float amp = 0.52;
    mat2 rot = mat2(vec2(0.80, -0.60), vec2(0.60, 0.80));
    for (int i = 0; i < 4; i++) {
        float n = 1.0 - abs(2.0 * vnoise(p) - 1.0);
        sum += amp * n * n;
        p = rot * p * 2.15 + vec2(13.7, 7.3);
        amp *= 0.48;
    }
    return sum;
}

// Procedural mountain micro-relief combining sharp ridges, fine Alpine couloirs, geological strata & scree
float rock_detail_height(vec3 wp) {
    float crags_macro = ridge_fbm(wp.xz * 1.65);
    float crags_micro = ridge_fbm(wp.xz * 5.8 + vec2(3.1, 8.7));
    float strata = 0.5 + 0.5 * sin(wp.y * 28.0 + crags_macro * 5.2 + vnoise(wp.xz * 0.75) * 3.5);
    float scree = vnoise(wp.xz * 16.0) * 0.65 + vnoise(wp.xz * 38.0) * 0.35;
    return crags_macro * 0.48 + crags_micro * 0.28 + strata * 0.14 + scree * 0.10;
}

// Dual-scale rotated sampling eliminates visible tiling repetition at all zoom levels
vec3 sample_non_repeating(sampler2D tex, vec2 uv, float scale) {
    vec2 uv1 = uv * scale;
    mat2 rot = mat2(vec2(0.7986, -0.6018), vec2(0.6018, 0.7986));
    vec2 uv2 = (rot * uv) * (scale * 0.73) + vec2(0.37, 0.61);
    float blend = smoothstep(0.25, 0.75, vnoise(uv * 11.0 + vec2(4.2, 9.1)));
    return mix(texture(tex, uv1).rgb, texture(tex, uv2).rgb, blend * 0.55);
}

// Organic noise-blended 3-octave prime-ratio rotated sampler (crisp blades, ZERO square borders, ZERO repetition!)
vec3 sample_organic_pbr(sampler2D tex, vec2 uv) {
    mat2 r2 = mat2(vec2(0.7986, -0.6018), vec2(0.6018, 0.7986));   // 37 deg
    mat2 r3 = mat2(vec2(-0.3907, -0.9205), vec2(0.9205, -0.3907)); // 113 deg
    vec2 uv2 = r2 * (uv * 0.73) + vec2(0.37, 0.61);
    vec2 uv3 = r3 * (uv * 0.53) + vec2(0.71, 0.23);
    float m1 = smoothstep(0.30, 0.70, vnoise(uv * 0.14 + vec2(4.2, 9.1)) * 0.65 + vnoise(uv * 0.37 + vec2(11.3, 2.7)) * 0.35);
    float m2 = smoothstep(0.34, 0.74, vnoise(uv * 0.09 + vec2(21.7, 5.4)) * 0.60 + vnoise(uv * 0.29 + vec2(2.1, 17.8)) * 0.40);
    vec3 c12 = mix(texture(tex, uv).rgb, texture(tex, uv2).rgb, m1);
    return mix(c12, texture(tex, uv3).rgb, m2 * 0.52);
}

// Matching 3-octave rotated normal sampler (properly rotates each layer's tangent-space XY normal!)
vec3 sample_organic_normal(sampler2D tex_n, vec2 uv) {
    mat2 r2 = mat2(vec2(0.7986, -0.6018), vec2(0.6018, 0.7986));
    mat2 r2_inv = mat2(vec2(0.7986, 0.6018), vec2(-0.6018, 0.7986));
    mat2 r3 = mat2(vec2(-0.3907, -0.9205), vec2(0.9205, -0.3907));
    mat2 r3_inv = mat2(vec2(-0.3907, 0.9205), vec2(-0.9205, -0.3907));
    vec2 uv2 = r2 * (uv * 0.73) + vec2(0.37, 0.61);
    vec2 uv3 = r3 * (uv * 0.53) + vec2(0.71, 0.23);
    float m1 = smoothstep(0.30, 0.70, vnoise(uv * 0.14 + vec2(4.2, 9.1)) * 0.65 + vnoise(uv * 0.37 + vec2(11.3, 2.7)) * 0.35);
    float m2 = smoothstep(0.34, 0.74, vnoise(uv * 0.09 + vec2(21.7, 5.4)) * 0.60 + vnoise(uv * 0.29 + vec2(2.1, 17.8)) * 0.40);
    vec3 n1 = texture(tex_n, uv).rgb * 2.0 - 1.0;
    vec3 n2 = texture(tex_n, uv2).rgb * 2.0 - 1.0;
    vec3 n3 = texture(tex_n, uv3).rgb * 2.0 - 1.0;
    n2.xy = r2_inv * n2.xy;
    n3.xy = r3_inv * n3.xy;
    return normalize(mix(mix(n1, n2, m1), n3, m2 * 0.52));
}

// Photorealistic procedural Alpine granite + limestone strata (zero inked outline artifacts up close!)
vec3 sample_triplanar_rock(vec3 wp, vec3 n) {
    float grain1 = vnoise(wp.xz * 6.5 + vec2(wp.y * 4.2, 1.3));
    float grain2 = vnoise(wp.xz * 22.0 + vec2(wp.y * 14.0, 5.7));
    float grain3 = vnoise(wp.xz * 58.0 + vec2(wp.y * 32.0, 9.1));
    float strata = 0.5 + 0.5 * sin(wp.y * 26.0 + ridge_fbm(wp.xz * 1.6) * 4.5 + grain1 * 2.4);
    float tone = 0.62 + 0.24 * grain1 + 0.14 * grain2 + 0.08 * grain3;
    vec3 limestone = vec3(0.74, 0.71, 0.66);
    vec3 granite   = vec3(0.56, 0.59, 0.64);
    vec3 slate     = vec3(0.42, 0.45, 0.50);
    vec3 col = mix(limestone, granite, smoothstep(0.25, 0.78, strata * 0.6 + grain1 * 0.4));
    col = mix(col, slate, smoothstep(0.60, 0.92, 1.0 - abs(n.y)) * (0.45 + 0.35 * grain2));
    return col * tone;
}

// Exact 4-tap GPU Cubic B-Spline height sampler (strictly positive weights + floor(tc) -> zero grid lines!)
float sample_height_bicubic_tex(sampler2D tex, vec2 uv, vec2 texel) {
    vec2 tex_size = 1.0 / texel;
    vec2 tc = uv * tex_size - 0.5;
    vec2 tc0 = floor(tc);
    vec2 f = tc - tc0;
    vec2 f2 = f * f;
    vec2 f3 = f2 * f;
    vec2 inv_f = 1.0 - f;

    vec2 w0 = (inv_f * inv_f * inv_f) / 6.0;
    vec2 w1 = (3.0 * f3 - 6.0 * f2 + 4.0) / 6.0;
    vec2 w2 = (-3.0 * f3 + 3.0 * f2 + 3.0 * f + 1.0) / 6.0;
    vec2 w3 = f3 / 6.0;

    vec2 s0 = w0 + w1;
    vec2 s1 = w2 + w3;
    vec2 f0 = w1 / s0;
    vec2 f1 = w3 / s1;

    vec2 t0 = (tc0 - 0.5 + f0) * texel;
    vec2 t1 = (tc0 + 1.5 + f1) * texel;

    float h00 = texture(tex, vec2(t0.x, t0.y)).r;
    float h10 = texture(tex, vec2(t1.x, t0.y)).r;
    float h01 = texture(tex, vec2(t0.x, t1.y)).r;
    float h11 = texture(tex, vec2(t1.x, t1.y)).r;

    return (h00 * s0.x + h10 * s1.x) * s0.y + (h01 * s0.x + h11 * s1.x) * s1.y;
}

// Step B: Seamless Europe 4K DEM + up to 2 simultaneous Regional High-Res Inset Packs!
// Returns vec3(elev_m, inset1_w, inset2_w)
vec3 sample_height_combined(vec2 uv) {
    float h = sample_height_bicubic_tex(height_tex, uv, height_texel);
    float w1 = 0.0;
    float w2 = 0.0;
    if (inset_uv_rect.z > 0.0001) {
        vec2 iuv = (uv - inset_uv_rect.xy) / inset_uv_rect.zw;
        if (iuv.x > 0.0 && iuv.x < 1.0 && iuv.y > 0.0 && iuv.y < 1.0) {
            w1 = smoothstep(0.0, 0.045, iuv.x) * smoothstep(1.0, 0.955, iuv.x)
               * smoothstep(0.0, 0.045, iuv.y) * smoothstep(1.0, 0.955, iuv.y);
            if (w1 > 0.001) {
                h = mix(h, sample_height_bicubic_tex(inset_height_tex, iuv, inset_texel), w1);
            }
        }
    }
    if (inset2_uv_rect.z > 0.0001) {
        vec2 iuv2 = (uv - inset2_uv_rect.xy) / inset2_uv_rect.zw;
        if (iuv2.x > 0.0 && iuv2.x < 1.0 && iuv2.y > 0.0 && iuv2.y < 1.0) {
            w2 = smoothstep(0.0, 0.045, iuv2.x) * smoothstep(1.0, 0.955, iuv2.x)
               * smoothstep(0.0, 0.045, iuv2.y) * smoothstep(1.0, 0.955, iuv2.y);
            if (w2 > 0.001) {
                h = mix(h, sample_height_bicubic_tex(inset2_height_tex, iuv2, inset2_texel), w2);
            }
        }
    }
    return vec3(h, w1, w2);
}

// Step A: Generative Geological Mountain Synthesis — domain-warped dendritic arêtes,
//         branching hydraulic couloirs & rugged mid-mountain hillside ribs (in meters).
//         Strictly ZERO below 780m or near water so valley cities (Munich, Innsbruck, Garmisch)
//         and railways match CPU elevation 100% with zero floating buildings!
vec2 mountain_erosion(vec2 wp_xz, float base_elev, float water_mask, float inset_w) {
    float foothill_w = smoothstep(780.0, 1220.0, base_elev) * (1.0 - smoothstep(0.08, 0.34, water_mask));
    float alpine_w   = smoothstep(980.0, 1620.0, base_elev) * (1.0 - smoothstep(0.10, 0.38, water_mask));
    if (foothill_w <= 0.001) {
        return vec2(0.0, 0.0);
    }
    // Dual-scale domain warp breaks up any straight grid-aligned DEM ridges into natural curved arêtes
    vec2 warp1 = vec2(
        vnoise(wp_xz * 0.85 + vec2(1.7, 9.2)) - 0.5,
        vnoise(wp_xz * 0.85 + vec2(8.3, 2.8)) - 0.5
    ) * 0.62;
    vec2 warp2 = vec2(
        vnoise(wp_xz * 2.9 + warp1 * 1.4 + vec2(4.1, 6.3)) - 0.5,
        vnoise(wp_xz * 2.9 + warp1 * 1.4 + vec2(9.7, 1.9)) - 0.5
    ) * 0.20;
    vec2 p = wp_xz * 1.25 + warp1 + warp2;

    // Sharp knife-edge arêtes + secondary spur ridges + fine rock ribs
    float arete = ridge_fbm(p);
    float spur  = ridge_fbm(p * 2.45 + vec2(5.1, 3.7));
    float crag  = ridge_fbm(p * 5.60 + vec2(11.3, 2.4));

    // Carve branching V-shaped hydraulic gullies/couloirs into high slopes
    float gully_raw = clamp(1.0 - (arete * 0.60 + spur * 0.28 + crag * 0.12), 0.0, 1.0);
    float gully_cut = pow(gully_raw, 1.75) * 0.42;

    float sculpted = (arete * 0.54 + spur * 0.28 + crag * 0.18) - 0.50 - gully_cut * 0.45;
    // Lower-mountain hillside roughness breaks up "polished spline" foothills (520m - 1400m)
    float hill_ribs = (spur * 0.55 + crag * 0.45 - 0.48) * 34.0 * foothill_w * (1.0 - alpine_w * 0.55);
    float amp_m = mix(95.0, 235.0, smoothstep(1050.0, 2950.0, base_elev)) * mix(1.0, 0.44, inset_w);
    return vec2(sculpted * amp_m * alpine_w + hill_ribs * mix(1.0, 0.62, inset_w), gully_raw * max(alpine_w, foothill_w * 0.55));
}

float sample_world_y_at(vec2 uv, vec2 wp_xz) {
    vec3 hc = sample_height_combined(uv);
    float e = hc.x;
    if (e >= 0.0) {
        float water_m = texture(splat_tex, uv).g;
        e += mountain_erosion(wp_xz, e, water_m, max(hc.y, hc.z)).x;
        return max(0.0, e) * land_height_scale;
    }
    return max(-3.2, e * sea_depth_scale);
}

void vertex() {
    v_uv = chunk_uv_rect.xy + UV * chunk_uv_rect.zw;
    vec3 world_base = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
    vec3 hc = sample_height_combined(v_uv);
    float e = hc.x;
    if (e >= 0.0) {
        float water_m = texture(splat_tex, v_uv).g;
        e += mountain_erosion(world_base.xz, e, water_m, max(hc.y, hc.z)).x;
        VERTEX.y = max(0.0, e) * land_height_scale;
    } else {
        VERTEX.y = max(-3.2, e * sea_depth_scale);
    }
    // Vertical skirt vertices drop below neighboring chunk seams -> 100% crack-free LOD transitions!
    if (COLOR.r > 0.5) {
        VERTEX.y -= 0.18;
    }
    v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
    // Discard coarse base-chunk pixels covered by the camera-centered ultra-high-res detail patch
    if (is_detail_patch < 0.5 && detail_hole_uv.z > 0.0001) {
        if (v_uv.x > detail_hole_uv.x && v_uv.x < detail_hole_uv.x + detail_hole_uv.z &&
            v_uv.y > detail_hole_uv.y && v_uv.y < detail_hole_uv.y + detail_hole_uv.w) {
            discard;
        }
    }

    vec4 splat = texture(splat_tex, v_uv);
    vec3 hc = sample_height_combined(v_uv);
    float base_elev = hc.x;
    float inset1_w = hc.y;
    float inset2_w = hc.z;
    float inset_w = max(inset1_w, inset2_w);
    vec2 ero = mountain_erosion(v_world_pos.xz, base_elev, splat.g, inset_w);
    float elev = (base_elev >= 0.0) ? max(0.0, base_elev + ero.x) : base_elev;
    float gully_w = ero.y;

    // Analytic per-pixel normal using full high-res inset texel step inside active regional packs!
    vec2 eff_texel = height_texel;
    if (inset1_w > 0.01) {
        eff_texel = mix(eff_texel, inset_uv_rect.zw * inset_texel, inset1_w);
    }
    if (inset2_w > 0.01) {
        eff_texel = mix(eff_texel, inset2_uv_rect.zw * inset2_texel, inset2_w);
    }
    vec2 d_xz = world_size * eff_texel;
    float hL = sample_world_y_at(v_uv - vec2(eff_texel.x, 0.0), v_world_pos.xz - vec2(d_xz.x, 0.0));
    float hR = sample_world_y_at(v_uv + vec2(eff_texel.x, 0.0), v_world_pos.xz + vec2(d_xz.x, 0.0));
    float hU = sample_world_y_at(v_uv - vec2(0.0, eff_texel.y), v_world_pos.xz - vec2(0.0, d_xz.y));
    float hD = sample_world_y_at(v_uv + vec2(0.0, eff_texel.y), v_world_pos.xz + vec2(0.0, d_xz.y));
    float stepX = 2.0 * d_xz.x;
    float stepZ = 2.0 * d_xz.y;
    vec3 macro_n = normalize(vec3((hL - hR) / stepX, 1.0, (hU - hD) / stepZ));
    float slope = 1.0 - macro_n.y;

    // Fine spatial noise for organic biome transitions & micro-detail
    float edge_n = vnoise(v_uv * 95.0) * 0.65 + vnoise(v_uv * 210.0) * 0.35 - 0.5;
    float macro_tone = 0.92 + 0.16 * vnoise(v_uv * 16.0 + vec2(2.3, 7.1));
    float micro_grain = 0.94 + 0.12 * vnoise(v_world_pos.xz * 7.5);

    // Sample regional lowland textures without repetition (dual-scale for crisp close-up fields!)
    vec3 col_north = sample_non_repeating(tex_grass_north, v_uv, 18.0);
    vec3 col_med   = sample_non_repeating(tex_grass_med,   v_uv, 18.0);
    vec3 col_micro_g = texture(tex_grass_north, v_world_pos.xz * 0.95).rgb;

    // Determine satellite coverage FIRST so ALL coarse generative overlays (forests, rivers, lakes,
    // roads, urban decals) are completely suppressed wherever real Sentinel-2 imagery is active!
    float sat_w = 0.0;
    vec3 sat_col = vec3(0.0);
    if (has_europe_albedo > 0.5 || (has_inset_albedo > 0.5 && inset1_w > 0.001) || (has_inset2_albedo > 0.5 && inset2_w > 0.001)) {
        if (has_europe_albedo > 0.5) {
            sat_col = texture(europe_albedo_tex, v_uv).rgb;
            sat_w = 1.0;
        }
        if (has_inset_albedo > 0.5 && inset1_w > 0.001) {
            vec2 iuv = (v_uv - inset_uv_rect.xy) / inset_uv_rect.zw;
            vec3 inset_col = texture(inset_albedo_tex, iuv).rgb;
            sat_col = (sat_w > 0.5) ? mix(sat_col, inset_col, inset1_w) : inset_col;
            sat_w = max(sat_w, inset1_w);
        }
        if (has_inset2_albedo > 0.5 && inset2_w > 0.001) {
            vec2 iuv2 = (v_uv - inset2_uv_rect.xy) / inset2_uv_rect.zw;
            vec3 inset2_col = texture(inset2_albedo_tex, iuv2).rgb;
            sat_col = (sat_w > 0.5) ? mix(sat_col, inset2_col, inset2_w) : inset2_col;
            sat_w = max(sat_w, inset2_w);
        }
        // Natural photographic color balance (desaturate vivid greens ~22% into realistic Alpine pine/olive)
        float sat_lum = dot(sat_col, vec3(0.299, 0.587, 0.114));
        float green_excess = clamp((sat_col.g - max(sat_col.r, sat_col.b)) * 3.0, 0.0, 1.0);
        sat_col = mix(sat_col, vec3(sat_lum), 0.24 + 0.30 * green_excess);
        sat_col = sat_col * vec3(0.99, 0.98, 0.97) * micro_grain;
    }

    // 1. Base regional lowland grassland (only used where no satellite albedo is active)
    float med_w = smoothstep(0.15, 0.85, splat.a + edge_n * 0.18) * smoothstep(1050.0, 420.0, elev);
    vec3 albedo = mix(col_north, col_med, med_w) * mix(0.86, 1.14, col_micro_g.g) * micro_grain;

    // Tactile close-up countryside normal relief (subtle micro-grain, never blocky!)
    vec3 world_n = macro_n;
    if (elev > 1.0) {
        float g_eps = 0.03;
        float g0 = vnoise(v_world_pos.xz * 12.0) * 0.6 + vnoise(v_world_pos.xz * 32.0) * 0.4;
        float gx = vnoise((v_world_pos.xz + vec2(g_eps, 0.0)) * 12.0) * 0.6 + vnoise((v_world_pos.xz + vec2(g_eps, 0.0)) * 32.0) * 0.4;
        float gz = vnoise((v_world_pos.xz + vec2(0.0, g_eps)) * 12.0) * 0.6 + vnoise((v_world_pos.xz + vec2(0.0, g_eps)) * 32.0) * 0.4;
        world_n = normalize(world_n + vec3((g0 - gx) / g_eps * 0.014, 0.0, (g0 - gz) / g_eps * 0.014));
    }

    // 2. Tier 1 — Generative CORINE Forest Overlays (DISABLED where satellite imagery is active -> zero green squares!)
    float corine_f = smoothstep(0.26, 0.56, splat.r + edge_n * 0.08);
    float subalpine_f = smoothstep(620.0, 980.0, elev + edge_n * 160.0)
                      * smoothstep(1920.0, 1540.0, elev + edge_n * 180.0)
                      * smoothstep(0.14, 0.045, slope)
                      * clamp(splat.r * 1.2 + 0.35 + edge_n * 0.35, 0.0, 1.0);
    float forest_w = clamp(max(corine_f, subalpine_f * 0.88), 0.0, 1.0)
                   * smoothstep(1940.0, 1580.0, elev + edge_n * 160.0)
                   * smoothstep(0.15, 0.06, slope)
                   * step(4.0, elev)
                   * (1.0 - sat_w);

    // Alpine meadow / tundra pastures between timberline (~1500m) and nival rock (~2280m)
    float alpine_meadow_w = smoothstep(1250.0, 1720.0, elev + edge_n * 180.0)
                          * smoothstep(2320.0, 1920.0, elev + edge_n * 180.0)
                          * smoothstep(0.12, 0.035, slope)
                          * (1.0 - forest_w * 0.75);
    vec3 meadow_col = mix(vec3(0.40, 0.48, 0.25), vec3(0.50, 0.47, 0.27), vnoise(v_world_pos.xz * 4.5) * 0.65 + 0.2);
    albedo = mix(albedo, meadow_col * micro_grain, alpine_meadow_w * 0.82);

    if (forest_w > 0.01) {
        vec3 col_canopy_macro = sample_non_repeating(tex_forest, v_uv, 58.0);
        vec3 col_canopy_close = texture(tex_forest, v_world_pos.xz * 2.2).rgb;
        vec3 col_canopy = mix(col_canopy_macro, col_canopy_close, 0.48);
        float conifer_w = clamp(smoothstep(480.0, 1120.0, elev) + smoothstep(0.86, 0.95, splat.r) * 0.55, 0.0, 1.0);
        vec3 canopy_tint = mix(
            mix(vec3(0.76, 0.90, 0.66), vec3(0.84, 0.86, 0.66), med_w),  // Broadleaf / Mediterranean woodland
            vec3(0.46, 0.64, 0.48),                                      // Deep Alpine / Black Forest spruce
            conifer_w
        );
        // Strong 3D volumetric tree-crown domes & dark understory crevice AO
        float c_eps = 0.018;
        float c0 = vnoise(v_world_pos.xz * 18.0) * 0.52 + vnoise(v_world_pos.xz * 44.0) * 0.33 + col_canopy_close.g * 0.15;
        float cx = vnoise((v_world_pos.xz + vec2(c_eps, 0.0)) * 18.0) * 0.52 + vnoise((v_world_pos.xz + vec2(c_eps, 0.0)) * 44.0) * 0.33
                 + texture(tex_forest, (v_world_pos.xz + vec2(c_eps, 0.0)) * 2.2).g * 0.15;
        float cz = vnoise((v_world_pos.xz + vec2(0.0, c_eps)) * 18.0) * 0.52 + vnoise((v_world_pos.xz + vec2(0.0, c_eps)) * 44.0) * 0.33
                 + texture(tex_forest, (v_world_pos.xz + vec2(0.0, c_eps)) * 2.2).g * 0.15;
        vec3 canopy_n = normalize(vec3((c0 - cx) / c_eps * 0.14, 1.0, (c0 - cz) / c_eps * 0.14));
        world_n = normalize(mix(world_n, normalize(macro_n + vec3(canopy_n.x, 0.0, canopy_n.z) * 1.15), forest_w * 0.92));
        float canopy_ao = 0.56 + 0.68 * smoothstep(0.18, 0.84, c0);
        albedo = mix(albedo, col_canopy * canopy_tint * canopy_ao, forest_w * 0.92);
    }

    // 3. Exposed High-Alpine Rock & Sheer Cliff Faces (green Alpine meadows reach ~1,850m - 2,050m!)
    float rock_elev = smoothstep(1920.0, 2450.0, elev + edge_n * 220.0);
    float rock_slope = smoothstep(0.11, 0.24, slope + edge_n * 0.02) * smoothstep(1250.0, 1820.0, elev);
    float rock_w = clamp(max(rock_elev, rock_slope), 0.0, 1.0);

    float rock_ao = 1.0;
    if (rock_w > 0.02 && elev > 15.0) {
        float eps = 0.024;
        float r0 = rock_detail_height(v_world_pos);
        float rx = rock_detail_height(v_world_pos + vec3(eps, 0.0, 0.0));
        float rz = rock_detail_height(v_world_pos + vec3(0.0, 0.0, eps));
        float bump_strength = (0.34 + 0.62 * rock_w) * smoothstep(15.0, 350.0, elev);
        vec3 detail_n = normalize(vec3((r0 - rx) / eps * bump_strength * 0.22, 1.0, (r0 - rz) / eps * bump_strength * 0.22));
        // Blend macro terrain normal with high-frequency crag & strata normal
        world_n = normalize(mix(world_n, normalize(vec3(
            macro_n.x + detail_n.x * 1.05,
            macro_n.y,
            macro_n.z + detail_n.z * 1.05
        )), rock_w));
        // Crevice ambient occlusion darkens rock fissures & couloirs cleanly without ink-black artifacts
        rock_ao = mix(1.0, 0.70 + 0.40 * r0, rock_w);
    }

    // Photorealistic procedural limestone/granite rock + scree-to-granite altitude tint
    vec3 col_rock = sample_triplanar_rock(v_world_pos, world_n);
    vec3 scree_tint = vec3(0.78, 0.74, 0.66);
    vec3 granite_tint = vec3(0.66, 0.70, 0.76);
    vec3 rock_tint = mix(scree_tint, granite_tint, smoothstep(1550.0, 2450.0, elev));
    albedo = mix(albedo, col_rock * rock_tint * rock_ao, rock_w);

    // 4. Sunlit Alpine Snow & Glacial Zone (aspect-aware + wind-drifted snow couloirs in eroded gullies!)
    float detail_slope = 1.0 - world_n.y;
    float aspect_snow = -macro_n.z * 150.0;
    float couloir_boost = smoothstep(0.42, 0.78, gully_w) * 260.0;
    float base_snow = smoothstep(1760.0, 2340.0, elev + edge_n * 210.0 + aspect_snow + couloir_boost) * smoothstep(0.56, 0.14, detail_slope);
    float summit_ice = smoothstep(2480.0, 2980.0, elev + edge_n * 180.0) * smoothstep(0.72, 0.28, detail_slope);
    float snow_w = clamp(max(base_snow, summit_ice), 0.0, 1.0);
    // Subtle cool glacial blue in shaded snow crevices & gullies
    vec3 snow_col = mix(vec3(0.82, 0.89, 0.96), vec3(0.97, 0.98, 1.00), rock_ao * (1.0 - gully_w * 0.15));
    albedo = mix(albedo, snow_col, snow_w);

    // 4b. Apply Continental + Regional Sentinel-2 Cloudless Satellite Albedo cleanly over land!
    if (sat_w > 0.001) {
        albedo = mix(albedo, sat_col, sat_w * step(-1.0, elev));
    }

    // 4c. Close-Up Satellite-Driven PBR Ground Synthesis:
    //     At strategic/regional zoom (cam_dist > 5.2), authentic Sentinel-2 imagery shines 100%.
    //     As you zoom into close-up diorama mode, smoothly replace the blurry 40m/px satellite pixels
    //     with 100% crisp, house-scale, normal-mapped PBR ground textures (meadow grass, mossy forest floor,
    //     dry pasture/farmland, Alpine rock, snow & European cobblestones) classified by the satellite
    //     colors + regional landuse mask + slope, with organic height-weighted transitions!
    float cam_dist = length(CAMERA_POSITION_WORLD - v_world_pos);
    float close_w = smoothstep(5.2, 1.45, cam_dist) * step(0.5, elev);
    float micro_rough_mod = 0.0;
    if (close_w > 0.01) {
        vec2 wp = v_world_pos.xz;
        float alb_lum = dot(albedo, vec3(0.299, 0.587, 0.114));

        // Sample pixel-accurate regional pack landuse (R=forest, G=urban, B=roads) when available
        vec3 hi_lu = vec3(0.0);
        if (has_inset_landuse > 0.5 && inset_uv_rect.z > 0.0001) {
            vec2 iuv = (v_uv - inset_uv_rect.xy) / inset_uv_rect.zw;
            if (iuv.x >= 0.0 && iuv.x <= 1.0 && iuv.y >= 0.0 && iuv.y <= 1.0) {
                hi_lu = max(hi_lu, texture(inset_landuse_tex, iuv).rgb);
            }
        }
        if (has_inset2_landuse > 0.5 && inset2_uv_rect.z > 0.0001) {
            vec2 iuv2 = (v_uv - inset2_uv_rect.xy) / inset2_uv_rect.zw;
            if (iuv2.x >= 0.0 && iuv2.x <= 1.0 && iuv2.y >= 0.0 && iuv2.y <= 1.0) {
                hi_lu = max(hi_lu, texture(inset2_landuse_tex, iuv2).rgb);
            }
        }

        // Organic dual-rotation PBR sampling at realistic diorama scale (ZERO square cell borders!)
        vec2 g_uv = wp * 95.0;
        vec2 f_uv = wp * 90.0;
        vec2 r_uv = wp * 38.0;
        vec2 c_uv = wp * 135.0;

        vec3 pbr_grass  = sample_organic_pbr(tex_grass_north, g_uv);
        vec3 pbr_dry    = sample_organic_pbr(tex_grass_med,   g_uv * 0.92);
        vec3 pbr_forest = sample_organic_pbr(tex_forest,      f_uv);
        vec3 pbr_rock   = sample_organic_pbr(tex_rock,        r_uv);
        // Keep cobblestones aligned in continuous street courses (no random rotated square patches!)
        vec3 pbr_cob    = texture(tex_cobble, c_uv).rgb;

        vec3 n_grass  = sample_organic_normal(tex_grass_n,  g_uv);
        vec3 n_forest = sample_organic_normal(tex_forest_n, f_uv);
        vec3 n_rock   = sample_organic_normal(tex_rock_n,   r_uv);
        vec3 n_cob    = texture(tex_cobble_n, c_uv).rgb * 2.0 - 1.0;

        // Multi-scale organic fBm color variation (breaks up any uniform flat tint across meadows, woods & peaks!)
        float var_macro = vnoise(wp * 2.6 + vec2(4.1, 8.3));
        float var_med   = vnoise(wp * 9.5 + vec2(17.2, 3.9));
        float var_fine  = vnoise(wp * 28.0 + vec2(9.7, 21.4));
        float var_mix   = var_macro * 0.50 + var_med * 0.32 + var_fine * 0.18;
        float org_edge  = (var_med - 0.5) * 0.36 + (var_fine - 0.5) * 0.22;

        // Smooth, non-binary material weights driven by Sentinel-2 colors + regional landuse + slope
        float sat_forest = smoothstep(0.004, 0.055, albedo.g - albedo.r) * smoothstep(0.36, 0.12, alb_lum);
        float w_forest = smoothstep(0.06, 0.88, max(sat_forest, hi_lu.r) + org_edge * 0.55);

        float sat_dry = smoothstep(-0.006, 0.055, albedo.r - albedo.g) * smoothstep(0.16, 0.42, alb_lum);
        float w_dry = smoothstep(0.12, 0.82, max(sat_dry, max(med_w * 0.65, var_macro * 0.38)) + org_edge * 0.45) * (1.0 - w_forest * 0.75);

        float city_mask = smoothstep(0.08, 0.42, texture(urban_tex, v_uv).r);
        float sat_built = smoothstep(0.042, 0.008, albedo.g - max(albedo.r, albedo.b)) * smoothstep(0.22, 0.42, alb_lum);
        float raw_paved = max(hi_lu.g, max(hi_lu.b * 0.95, city_mask * sat_built));
        // Crisper curb-like transition between cobblestone streets/plazas and adjacent lawns
        float w_paved = smoothstep(0.22, 0.52, raw_paved + org_edge * 0.50)
                      * (1.0 - w_forest * 0.80) * smoothstep(1400.0, 950.0, elev);
        float curb_band = smoothstep(0.18, 0.34, raw_paved + org_edge * 0.50) * (1.0 - w_paved)
                        * (1.0 - w_forest * 0.80) * smoothstep(1400.0, 950.0, elev);

        // Keep green Alpine grass/pasture climbing up to ~1,850m (bare rock only on steep cliffs or high peaks!)
        float w_rock = clamp(max(rock_w, smoothstep(0.18, 0.34, slope) * smoothstep(1680.0, 2150.0, elev)), 0.0, 1.0);
        float w_snow = snow_w;

        // Satellite-locked PBR ground synthesis: preserve the EXACT Sentinel-2 satellite hue & brightness
        // across all zoom levels (zero green->brown morph when zooming in!), while injecting 100% crisp
        // 1024px micro-detail (grass blades, clover, fallen needles, rock grit) & normal-map relief!
        float l_grass  = dot(pbr_grass,  vec3(0.299, 0.587, 0.114));
        float l_dry    = dot(pbr_dry,    vec3(0.299, 0.587, 0.114));
        float l_forest = dot(pbr_forest, vec3(0.299, 0.587, 0.114));

        // Zero-mean contrast-boosted detail multipliers (preserve exact Sentinel-2 average hue/brightness
        // while restoring crisp individual grass blades, clover, soil flecks & woodland needles!)
        float c_grass  = clamp(1.0 + (l_grass  - 0.28) * 3.1, 0.42, 1.75);
        float c_dry    = clamp(1.0 + (l_dry    - 0.36) * 2.6, 0.46, 1.65);
        float c_forest = clamp(1.0 + (l_forest - 0.26) * 3.0, 0.38, 1.72);
        vec3 det_grass  = mix(vec3(1.0), pbr_grass  / max(l_grass,  0.08), 0.52) * c_grass;
        vec3 det_dry    = mix(vec3(1.0), pbr_dry    / max(l_dry,    0.08), 0.48) * c_dry;
        vec3 det_forest = mix(vec3(1.0), pbr_forest / max(l_forest, 0.08), 0.55) * c_forest;

        vec3 det_veg = mix(det_grass, det_dry, w_dry);
        det_veg = mix(det_veg, det_forest, w_forest);

        // Fallback standalone palette when no satellite albedo is present
        vec3 fallback_veg = mix(
            mix(pbr_grass * vec3(0.86, 0.98, 0.72), pbr_dry * vec3(0.84, 0.78, 0.60), w_dry),
            pbr_forest * vec3(0.84, 0.90, 0.72),
            w_forest
        );
        // Lock ground color directly to Sentinel-2 satellite tone (zero color shift on zoom!)
        vec3 synth_veg = mix(fallback_veg, albedo * det_veg, sat_w);

        // Geological Alpine rock: blend stochastic rock texture with procedural limestone/granite/slate strata + warm scree!
        vec3 rock_strata = sample_triplanar_rock(v_world_pos, macro_n) * 0.58;
        vec3 rock_tex_c  = mix(vec3(dot(pbr_rock, vec3(0.299, 0.587, 0.114))), pbr_rock, 0.68);
        vec3 rock_warm   = rock_strata * vec3(1.12, 1.02, 0.90);
        vec3 rock_cool   = rock_strata * vec3(0.80, 0.86, 0.94);
        vec3 col_rock    = mix(rock_cool, rock_warm, smoothstep(0.18, 0.82, var_macro * 0.60 + var_med * 0.40))
                         * mix(0.62, 1.36, dot(rock_tex_c, vec3(0.3, 0.59, 0.11)))
                         * mix(1.0, 0.64, gully_w * 0.78);
        // Subtle satellite tinting on rock too so Alpine peaks never shift hue when zooming in
        col_rock = mix(col_rock, mix(col_rock, albedo * clamp(dot(rock_tex_c, vec3(0.3, 0.59, 0.11)) / 0.45, 0.65, 1.40), 0.45), sat_w);

        // Crisp 1024px granite cobblestones with subtle mortar crevice darkening & stone curb border
        float cob_h     = texture(tex_cobble_n, c_uv).a;
        vec3 col_cob    = pbr_cob * vec3(0.76, 0.74, 0.71) * (0.80 + 0.30 * cob_h) * (0.92 + 0.16 * var_med);
        vec3 col_curb   = vec3(0.50, 0.49, 0.46) * (0.88 + 0.22 * var_fine);
        vec3 col_snow   = vec3(0.84, 0.86, 0.90) * (0.92 + 0.14 * dot(pbr_rock, vec3(0.3, 0.59, 0.11)));

        // Synthesize 100% crisp, non-repeating PBR close-up ground albedo + matching normal map
        vec3 synth_alb = synth_veg;
        synth_alb = mix(synth_alb, col_rock, w_rock);
        synth_alb = mix(synth_alb, col_curb, curb_band * 0.72);
        synth_alb = mix(synth_alb, col_cob, w_paved);
        synth_alb = mix(synth_alb, col_snow, w_snow);

        vec3 synth_nm = mix(n_grass, mix(n_grass, n_forest, 0.65), w_forest);
        synth_nm = mix(synth_nm, n_rock, w_rock);
        synth_nm = mix(synth_nm, n_cob, w_paved);
        synth_nm = mix(synth_nm, n_rock * 0.35, w_snow);

        // Smoothly crossfade from blurry satellite image into 100% crisp PBR ground as camera zooms in!
        albedo = mix(albedo, synth_alb, close_w);
        float relief_amp = mix(0.88, 1.05, max(max(w_forest * 0.7, w_rock), w_paved)) * (1.0 - w_snow * 0.65);
        world_n = normalize(mix(world_n, normalize(world_n + vec3(synth_nm.x, 0.0, synth_nm.y) * relief_amp), close_w));

        float synth_lum = dot(synth_alb, vec3(0.299, 0.587, 0.114));
        micro_rough_mod = mix((0.45 - synth_lum) * 0.24, -0.08, w_paved) * close_w;
    }

    // 5. Crisp coastal sandy/pebble beach (only in non-satellite mode)
    float beach_w = smoothstep(16.0, 1.0, elev) * step(-2.0, elev) * (1.0 - sat_w);
    vec3 beach_col = mix(vec3(0.78, 0.74, 0.60), vec3(0.84, 0.76, 0.58), med_w);
    albedo = mix(albedo, beach_col, beach_w * 0.65);

    // 6. Submerged seabed tint (seen through translucent 3D ocean water)
    if (elev < 0.0) {
        float depth_t = clamp(-elev / 350.0, 0.0, 1.0);
        albedo = mix(vec3(0.48, 0.56, 0.52), vec3(0.06, 0.14, 0.22), depth_t);
    }

    // 7. Painterly overland trade roads (only in non-satellite mode)
    float road_w = (elev >= 0.0) ? smoothstep(0.22, 0.78, splat.b) * (1.0 - sat_w) : 0.0;
    vec3 road_col = mix(vec3(0.64, 0.56, 0.43), vec3(0.76, 0.66, 0.50), med_w);
    albedo = mix(albedo, road_col, road_w * 0.44);

    // 7b. Tier 2 — To-Scale Urban Rooftop & Street Fabric (only in non-satellite mode;
    //     in satellite mode, real Sentinel-2 city footprints show through cleanly!)
    float urban_raw = texture(urban_tex, v_uv).r;
    float urban_w = smoothstep(0.14, 0.56, urban_raw + edge_n * 0.18) * step(1.0, elev) * (1.0 - sat_w);
    if (urban_w > 0.01) {
        vec2 u_coord = v_world_pos.xz * 2.2;
        vec3 col_urb = texture(tex_urban, u_coord).rgb;
        float u_eps = 0.014;
        float lum0 = dot(col_urb, vec3(0.3, 0.55, 0.15));
        float lumx = dot(texture(tex_urban, (v_world_pos.xz + vec2(u_eps, 0.0)) * 2.2).rgb, vec3(0.3, 0.55, 0.15));
        float lumz = dot(texture(tex_urban, (v_world_pos.xz + vec2(0.0, u_eps)) * 2.2).rgb, vec3(0.3, 0.55, 0.15));
        vec3 urb_n = normalize(vec3((lum0 - lumx) / u_eps * 0.14, 1.0, (lum0 - lumz) / u_eps * 0.14));
        world_n = normalize(mix(world_n, normalize(macro_n + vec3(urb_n.x, 0.0, urb_n.z) * 1.2), urban_w * 0.90));
        float urb_ao = 0.68 + 0.48 * smoothstep(0.18, 0.78, lum0);
        vec3 urb_tint = mix(vec3(0.84, 0.82, 0.80), vec3(1.04, 0.96, 0.86), med_w);
        albedo = mix(albedo, col_urb * urb_tint * urb_ao, urban_w * 0.85);
    }

    // 8. Water rendering:
    //    - Outside regional high-res packs: coarse splat rivers/lakes disabled in satellite mode
    //    - Inside regional packs with pixel-accurate OSM water masks: enhance green-tinted satellite
    //      lakes & rivers into crisp reflective Alpine turquoise/blue water with sun glint!
    float river_val = splat.g;
    float paint_mask = 1.0 - sat_w;
    float river_bank = smoothstep(0.08, 0.50, river_val) * step(0.0, elev) * paint_mask;
    albedo = mix(albedo, albedo * vec3(0.84, 0.97, 0.82), river_bank * 0.30);

    float river_core = smoothstep(0.62, 0.84, river_val) * step(-4.0, elev) * paint_mask;
    float lake_core = smoothstep(0.90, 0.99, river_val) * step(-4.0, elev) * paint_mask;
    vec3 river_col = vec3(0.07, 0.21, 0.36);
    vec3 lake_col  = mix(vec3(0.05, 0.20, 0.34), vec3(0.03, 0.14, 0.26), vnoise(v_world_pos.xz * 2.2) * 0.45 + 0.35);
    vec3 water_col = mix(river_col, lake_col, lake_core);
    albedo = mix(albedo, water_col, river_core * 0.94);

    // High-res OSM water enhancement inside regional realism packs (40-80m/px!)
    float hi_water = 0.0;
    if (has_inset_water > 0.5 && inset_uv_rect.z > 0.0001) {
        vec2 iuv = (v_uv - inset_uv_rect.xy) / inset_uv_rect.zw;
        if (iuv.x >= 0.0 && iuv.x <= 1.0 && iuv.y >= 0.0 && iuv.y <= 1.0) {
            float bw = smoothstep(0.0, 0.03, iuv.x) * smoothstep(0.0, 0.03, 1.0 - iuv.x)
                     * smoothstep(0.0, 0.03, iuv.y) * smoothstep(0.0, 0.03, 1.0 - iuv.y);
            hi_water = max(hi_water, texture(inset_water_tex, iuv).r * bw);
        }
    }
    if (has_inset2_water > 0.5 && inset2_uv_rect.z > 0.0001) {
        vec2 iuv2 = (v_uv - inset2_uv_rect.xy) / inset2_uv_rect.zw;
        if (iuv2.x >= 0.0 && iuv2.x <= 1.0 && iuv2.y >= 0.0 && iuv2.y <= 1.0) {
            float bw2 = smoothstep(0.0, 0.03, iuv2.x) * smoothstep(0.0, 0.03, 1.0 - iuv2.x)
                      * smoothstep(0.0, 0.03, iuv2.y) * smoothstep(0.0, 0.03, 1.0 - iuv2.y);
            hi_water = max(hi_water, texture(inset2_water_tex, iuv2).r * bw2);
        }
    }

    // Organic Alpine river & lake shoreline (damp mossy/reed banks + sporadic wet gravel bars, NO white outline!)
    float shore_macro = vnoise(v_world_pos.xz * 5.2 + vec2(3.1, 7.4));
    float shore_noise = (vnoise(v_world_pos.xz * 32.0) - 0.5) * 0.22 + (vnoise(v_world_pos.xz * 96.0) - 0.5) * 0.10;
    float hw_org = clamp(hi_water + shore_noise * smoothstep(0.02, 0.35, hi_water) * (1.0 - smoothstep(0.55, 0.88, hi_water)), 0.0, 1.0);
    float hi_w_mask = smoothstep(0.26, 0.68, hw_org) * step(-2.0, elev);
    float hi_lake_w = smoothstep(0.76, 0.94, hi_water);

    // Zone 1: Damp dark alluvial earth & lush riparian reeds/grass along the water margin
    float damp_bank = smoothstep(0.03, 0.26, hw_org) * (1.0 - smoothstep(0.28, 0.56, hw_org)) * step(-2.0, elev);
    float wet_shore_rough = 0.0;
    if (damp_bank > 0.01) {
        vec3 reed_col = mix(albedo * vec3(0.72, 0.80, 0.64), vec3(0.18, 0.23, 0.15), 0.42);
        albedo = mix(albedo, reed_col, damp_bank * 0.62);
        wet_shore_rough = damp_bank * 0.45;
    }

    // Zone 2: Sporadic, irregular muted wet gravel bars (gated by shore_macro so it NEVER forms a uniform ring!)
    float gravel_patch = smoothstep(0.56, 0.78, shore_macro);
    float pebble_shore = smoothstep(0.16, 0.34, hw_org) * (1.0 - smoothstep(0.36, 0.54, hw_org)) * gravel_patch * step(-2.0, elev);
    if (pebble_shore > 0.01) {
        float peb_g = vnoise(v_world_pos.xz * 220.0) * 0.55 + vnoise(v_world_pos.xz * 480.0) * 0.45;
        vec3 peb_col = mix(vec3(0.24, 0.24, 0.22), vec3(0.40, 0.39, 0.35), peb_g);
        albedo = mix(albedo, peb_col, pebble_shore * 0.72);
        wet_shore_rough = max(wet_shore_rough, pebble_shore * 0.85);
    }

    if (hi_w_mask > 0.01) {
        // Zone 3: Natural shallow-to-deep Alpine river & lake water blending smoothly from dark wet banks
        float sat_l = clamp(dot(albedo, vec3(0.299, 0.587, 0.114)) * 2.4, 0.40, 1.20);
        float shallow_w = smoothstep(0.68, 0.30, hw_org);
        vec3 shallow_col      = vec3(0.12, 0.28, 0.30) * mix(0.84, 1.08, sat_l * 0.55);
        vec3 alpine_river_col = vec3(0.09, 0.24, 0.32) * mix(0.84, 1.12, sat_l * 0.65);
        vec3 alpine_lake_col  = mix(vec3(0.06, 0.21, 0.31), vec3(0.03, 0.14, 0.24),
                                    vnoise(v_world_pos.xz * 2.8) * 0.35 + 0.35) * mix(0.82, 1.15, sat_l * 0.55);
        vec3 hi_col = mix(alpine_river_col, alpine_lake_col, hi_lake_w);
        hi_col = mix(hi_col, shallow_col, shallow_w * 0.45);
        albedo = mix(albedo, hi_col, hi_w_mask * mix(0.54, 0.70, hi_lake_w));

        // Ultra-subtle fine micro-ripple shimmer on high-res lakes & rivers
        float t_w1 = TIME * 0.11;
        float t_w2 = TIME * 0.07;
        vec2 wp_a = v_world_pos.xz * 165.0 + vec2(t_w1, t_w1 * 0.65);
        vec2 wp_b = v_world_pos.xz * 320.0 - vec2(t_w2 * 0.75, t_w2);
        float w0 = vnoise(wp_a) * 0.65 + vnoise(wp_b) * 0.35;
        float wx = vnoise(wp_a + vec2(0.18, 0.0)) * 0.65 + vnoise(wp_b + vec2(0.36, 0.0)) * 0.35;
        float wz = vnoise(wp_a + vec2(0.0, 0.18)) * 0.65 + vnoise(wp_b + vec2(0.0, 0.36)) * 0.35;
        vec3 water_n = normalize(vec3((w0 - wx) * 0.10, 1.0, (w0 - wz) * 0.10));
        world_n = normalize(mix(world_n, water_n, hi_w_mask * 0.90));
    }

    world_n = normalize(mix(world_n, vec3(0.0, 1.0, 0.0), river_core * 0.92));

    float total_water = max(river_core, hi_w_mask);
    float total_lake = max(lake_core, hi_lake_w * hi_w_mask);
    ALBEDO = albedo * macro_tone;
    float base_rough = mix(mix(mix(0.92, 0.90, rock_w), 0.86, snow_w), 0.38, wet_shore_rough * 0.75);
    ROUGHNESS = clamp(mix(base_rough, mix(0.18, 0.11, total_lake), total_water) + micro_rough_mod * (1.0 - total_water), 0.08, 0.98);
    SPECULAR = mix(mix(0.10, 0.34, wet_shore_rough * 0.7), mix(0.62, 0.78, total_lake), total_water);

    // Transform final perturbed world-space normal into view space for Godot's PBR lighting
    NORMAL = normalize((VIEW_MATRIX * vec4(world_n, 0.0)).xyz);
}
