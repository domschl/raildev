shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

varying vec3 v_world_pos;
varying vec3 v_local_pos;
varying vec3 v_world_n;

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
    v_local_pos = VERTEX;
    v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
    v_world_n = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
    vec3 base_col = COLOR.rgb;

    // Triplanar fine architectural / ballast micro-weathering (breaks up flat untextured low-poly look!)
    vec3 an = abs(v_world_n);
    vec2 uv_tri = (an.y > 0.65) ? v_world_pos.xz : ((an.x > an.z) ? v_world_pos.zy : v_world_pos.xy);
    float g1 = vnoise(uv_tri * 240.0);
    float g2 = vnoise(uv_tri * 680.0);
    float grain = 0.88 + 0.16 * g1 + 0.08 * g2;

    // Tone-match to Sentinel-2 natural daylight palette (eliminate plastic bright whites & harsh saturation)
    float lum = dot(base_col, vec3(0.299, 0.587, 0.114));
    vec3 col = mix(vec3(lum), base_col, 0.84) * grain;
    col = min(col, vec3(0.78));

    // Automatic PBR material classification from vertex color:
    // - Warm yellow/gold -> polished brass fittings (metallic)
    // - Cool blue-grey metallic steel -> rails & glass skylights (glossy)
    // - Dark cast iron -> satin oiled iron
    float is_brass = smoothstep(0.18, 0.40, base_col.r - base_col.b) * smoothstep(0.45, 0.72, base_col.g);
    float is_glass = smoothstep(0.05, 0.16, base_col.b - base_col.r) * smoothstep(0.40, 0.65, base_col.b);
    float is_dark_iron = smoothstep(0.28, 0.14, lum);

    // Subtle crevice / ground-contact AO darkening near the base of buildings & embankments
    float ground_ao = mix(0.78, 1.0, smoothstep(-0.02, 0.14, v_local_pos.y));
    float sky_ao = mix(0.86, 1.04, clamp(v_world_n.y * 0.5 + 0.5, 0.0, 1.0));

    ALBEDO = col * ground_ao * sky_ao;
    METALLIC = clamp(is_brass * 0.78 + is_dark_iron * 0.35, 0.0, 0.85);
    ROUGHNESS = clamp(0.86 - is_brass * 0.52 - is_glass * 0.58 - is_dark_iron * 0.32 + (g1 - 0.5) * 0.10, 0.18, 0.96);
    SPECULAR = mix(0.32, 0.82, max(is_brass, is_glass));
}
