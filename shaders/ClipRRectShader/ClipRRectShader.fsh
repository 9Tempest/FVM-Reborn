varying vec2 v_vTexcoord;
varying vec4 v_vColour;
varying vec2 v_vPosition;

uniform vec2 in_origin;
uniform vec2 in_size;
uniform float in_radius;

void main()
{
    // Match the room coordinates supplied by ClipRRect on every graphics backend.
    // Framebuffer coordinates have platform-dependent origins and scaling.
    vec2 local_pixel_pos = v_vPosition - in_origin;

    vec2 half_size = in_size * 0.5;

    vec2 pos_from_center = local_pixel_pos - half_size;

    vec2 q = abs(pos_from_center) - (half_size - vec2(in_radius));
    float d = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - in_radius;

    float edge = 1.0; 
    float alpha = 1.0 - smoothstep(-edge, edge, d);

    if (alpha <= 0.0) {
        discard;
    }

    vec4 tex_color = texture2D(gm_BaseTexture, v_vTexcoord);
    gl_FragColor = v_vColour * tex_color * vec4(1.0, 1.0, 1.0, alpha);
}
