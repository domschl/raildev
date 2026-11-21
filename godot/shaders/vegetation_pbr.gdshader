shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

uniform vec3 bubble_center = vec3(0.0, 0.0, 0.0);
uniform float bubble_radius = 1.15;
uniform float zoom_fade = 1.0;

uniform sampler2D tex_foliage   : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D tex_foliage_n : hint_normal,  filter_linear_mipmap, repeat_enable;
uniform sampler2D tex_bark      : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D tex_bark_n    : hint_normal,  filter_linear_mipmap, repeat_enable;

varying vec3 v_world_pos;
varying vec3 v_local_pos;
varying vec3 v_world_n;

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
    float lum = dot(col, vec3(0.299, 0.587, 0.114));
    // Harmonize saturation with Sentinel-2 atmospheric woodland palette
    col = mix(vec3(lum), col, 0.78);

    // Detect brown trunk vs green canopy from vertex color + height
    float is_trunk = smoothstep(0.0, 0.06, col.r - col.g) * smoothstep(0.85, 0.45, v_local_pos.y);

    vec3 wn = normalize(v_world_n);
    vec3 an = abs(wn);
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

    // Crisp leaf/needle cluster & furrowed bark textures + normal maps
    vec3 fol_alb = texture(tex_foliage, uv_tri * 135.0).rgb;
    vec3 fol_nm  = texture(tex_foliage_n, uv_tri * 135.0).rgb * 2.0 - 1.0;
    vec3 brk_alb = texture(tex_bark, uv_tri * 180.0).rgb;
    vec3 brk_nm  = texture(tex_bark_n, uv_tri * 180.0).rgb * 2.0 - 1.0;

    vec3 tex_mul = mix(fol_alb * 1.18, brk_alb * 1.30, is_trunk);
    vec3 nm = mix(fol_nm * 0.72, brk_nm * 0.85, is_trunk);
    vec3 pert_n = normalize(wn + t_u * nm.x + t_v * nm.y);

    // Strong root-to-crown AO (darkens base into ground contact shadow so trees feel rooted!)
    float crown_ao = mix(0.44, 1.08, smoothstep(0.0, 1.35, v_local_pos.y));
    float sky_lift = mix(0.80, 1.06, clamp(pert_n.y * 0.5 + 0.5, 0.0, 1.0));

    vec3 final_col = col * tex_mul * crown_ao * sky_lift;
    ALBEDO = final_col;
    // Warm sunlit canopy translucency (subsurface glow through leaves/needles!)
    BACKLIGHT = final_col * 0.24 * (1.0 - is_trunk);
    ROUGHNESS = mix(0.86, 0.94, is_trunk);
    SPECULAR = mix(0.14, 0.06, is_trunk);
    NORMAL = normalize((VIEW_MATRIX * vec4(pert_n, 0.0)).xyz);
}
