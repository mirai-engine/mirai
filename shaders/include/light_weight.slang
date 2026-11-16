// What a pixel weighs a local light of its cell of the grid by
// (direct_grid.slang), from a record of the light the grid keeps
// (light_grid.comp.slang): LIGHT_WEIGHT_ROWS rows of the grid buffer after the
// rows of its cells. The first holds its center and range; the second, what
// it gives far away (the luminance of its color by its intensity); the radius
// of the sphere that holds it, 16 bits of its range rounded up; its direction
// (octahedral, 16 bits a side); and its cone: none, LIGHT_WEIGHT_RECT for a
// rectangle, which lights the side its direction faces, or the cosines of the
// edge of a spot and of where it starts to fade, 16 bits each over [-1, 1].
// It needs lighting.slang.
#ifndef MIRAI_LIGHT_WEIGHT_SLANG
#define MIRAI_LIGHT_WEIGHT_SLANG

#define LIGHT_WEIGHT_NONE 0u
#define LIGHT_WEIGHT_RECT 0xFFFFFFFFu
// The most lights a cell of the grid lists apart from its table: those the
// edge of whose cone, or the plane of a rectangle, crosses it (light_grid.comp).
#define LIGHT_GRID_APART 4u

// A cosine in 16 bits, rounded down or to the nearest, and back.
uint light_weight_unit(float c, bool down) {
    float q = (clamp(c, -1.0, 1.0) * 0.5 + 0.5) * 65535.0;
    return uint(down ? floor(q) : round(q));
}
float light_weight_cosine(uint q) { return float(q) / 65535.0 * 2.0 - 1.0; }

// The rows of the record of a light. The edge of a spot is rounded out past
// what 16 bits of its direction and of its cosine may move it, so that no
// point the light reaches weighs nothing.
void light_weight_rows(Light l, out uint4 center, out uint4 shape) {
    center = asuint(l.position_range);
    uint direction = 0u;
    uint cone = LIGHT_WEIGHT_NONE;
    bool rect = light_is_rect(l);
    if (rect || l.direction_cone.w > 0.5 * LIGHT_POINT) {
        int2 q = int2(round(clamp(oct_encode(l.direction_cone.xyz), -1.0, 1.0) * 32767.0));
        direction = (uint(q.x) & 0xFFFFu) | (uint(q.y) << 16u);
    }
    if (rect) {
        cone = LIGHT_WEIGHT_RECT;
    } else if (l.direction_cone.w > 0.5 * LIGHT_POINT) {
        float outer = l.direction_cone.w;
        float inner = cos(acos(outer) * 0.8);
        cone = min(light_weight_unit(outer - 4e-4, true), 65534u) | (light_weight_unit(inner, false) << 16u);
    }
    float range = max(l.position_range.w, 1e-6);
    uint extent = uint(min(ceil(light_extent(l) / range * 65535.0), 65535.0));
    shape = uint4(asuint(luminance(l.color_intensity.rgb) * l.color_intensity.w), extent, direction, cone);
}

// The light of a record at a point, as light_weight_at weighs it.
float light_weight(uint4 center, uint4 shape, float3 position, float3 normal) {
    float4 c = asfloat(center);
    float3 to = c.xyz - position;
    if (dot(to, to) >= c.w * c.w) return 0.0;
    uint cone = shape.w == LIGHT_WEIGHT_NONE ? LIGHT_CONE_NONE : shape.w == LIGHT_WEIGHT_RECT ? LIGHT_CONE_RECT : LIGHT_CONE_SPOT;
    float3 axis = cone != LIGHT_CONE_NONE ? oct_decode(unpackSnorm2x16(shape.z)) : float3(0.0);
    float2 cosines = float2(light_weight_cosine(shape.w & 0xFFFFu), light_weight_cosine(shape.w >> 16u));
    return light_weight_at(c.xyz, c.w, asfloat(shape.x), float(shape.y & 0xFFFFu) / 65535.0 * c.w, cone, axis, cosines, position, normal);
}
#endif
