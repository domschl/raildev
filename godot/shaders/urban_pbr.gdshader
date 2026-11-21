shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

uniform vec3 bubble_center = vec3(0.0, 0.0, 0.0);
uniform float bubble_radius = 0.95;
uniform float zoom_fade = 1.0;

uniform sampler2D tex_roof     : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D tex_roof_n   : hint_normal,  filter_linear_mipmap, repeat_enable;
uniform sampler2D tex_wall     : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D tex_wall_n   : hint_normal,  filter_linear_mipmap, repeat_enable;
uniform sampler2D tex_cobble   : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D tex_cobble_n : hint_normal,  filter_linear_mipmap, repeat_enable;

varying vec3 v_world_pos;
varying vec3 v_local_pos;
varying vec3 v_world_n;

void vertex() {
    v_local_pos = VERTEX;
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

    // Sample PBR albedo + tangent-space normal maps
    vec3 wall_alb = texture(tex_wall, uv_tri * 140.0).rgb;
    vec3 wall_nm  = texture(tex_wall_n, uv_tri * 140.0).rgb * 2.0 - 1.0;

    vec3 roof_alb = texture(tex_roof, v_world_pos.xz * 210.0).rgb;
    vec3 roof_nm  = texture(tex_roof_n, v_world_pos.xz * 210.0).rgb * 2.0 - 1.0;

    vec3 cob_alb  = texture(tex_cobble, v_world_pos.xz * 95.0).rgb;
    vec3 cob_nm   = texture(tex_cobble_n, v_world_pos.xz * 95.0).rgb * 2.0 - 1.0;

    // Combine surface albedo (centered around neutral gray so vertex/palette hues stay faithful)
    vec3 surf_mul = mix(wall_alb * 1.24, roof_alb * 1.22, is_roof);
    vec3 col = mix(vec3(lum), base_col, 0.86) * surf_mul;
    col = mix(col, cob_alb * base_col * 1.48, is_plaza);
    // Subtle warm interior reflection inside dark recessed windows
    col = mix(col, vec3(0.14, 0.17, 0.21), is_win * 0.65);
    col = min(col, vec3(0.72));

    // Perturb world normal using sampled PBR normal map
    vec3 nm = mix(wall_nm * 0.48, roof_nm * 0.85, is_roof);
    nm = mix(nm, cob_nm * 0.78, is_plaza);
    nm *= (1.0 - is_win);
    vec3 pert_n = normalize(wn + t_u * nm.x + t_v * nm.y);

    float ground_ao = mix(0.56, 1.00, smoothstep(-0.02, 0.38, v_local_pos.y));
    ground_ao = mix(ground_ao, 0.94, is_plaza);
    float sky_ao = mix(0.82, 1.04, clamp(pert_n.y * 0.5 + 0.5, 0.0, 1.0));

    ALBEDO = col * ground_ao * sky_ao;
    ROUGHNESS = clamp(mix(mix(0.88, 0.78, is_roof), 0.20, is_win), 0.16, 0.96);
    SPECULAR = mix(mix(0.20, 0.30, is_roof), 0.82, is_win);
    NORMAL = normalize((VIEW_MATRIX * vec4(pert_n, 0.0)).xyz);
}
