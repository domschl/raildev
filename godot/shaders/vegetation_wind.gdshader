shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

uniform float wind_strength = 0.045;
uniform float wind_speed = 1.6;

void vertex() {
    // Gentle breeze sway pinned at the base of the trunk (VERTEX.y == 0)
    vec3 inst_pos = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
    float phase = inst_pos.x * 0.45 + inst_pos.z * 0.37;
    float height_w = clamp(VERTEX.y, 0.0, 2.0);
    float sway = sin(TIME * wind_speed + phase) * wind_strength * height_w * height_w;
    VERTEX.x += sway;
    VERTEX.z += sway * 0.6;
}

void fragment() {
    // COLOR automatically multiplies mesh vertex color with MultiMesh instance color
    ALBEDO = COLOR.rgb;
    ROUGHNESS = 0.88;
    SPECULAR = 0.18;
}
