// The maps of the shadows of the lights that light much of the view
// (render.shadow_maps_pass), drawn again every frame: a light rasterized has a
// map for each face of the cube around it through which it lights what the
// view sees, fitted to that, and the sun one for each cascade of the view;
// each is a square of the atlas. The samples of the direct light read them
// first (direct_samples.comp): where the taps around a point agree it is lit
// or hidden; where they disagree, at a penumbra, it takes the hard shadow of
// the map, which direct_spread.comp averages over the width of the penumbra.
// The lights without maps trace rays.
#ifndef MIRAI_SHADOW_MAPS_SLANG
#define MIRAI_SHADOW_MAPS_SLANG
#include "scene.slang"

#define SHADOW_ATLAS 4096u
// The buffer of the maps (uint4 rows): a word for each light, four to a row,
// 0 for a light without maps, else its first map + 1 and, from bit
// SHADOW_LIGHT_FACES, which faces of its cube have one; then SHADOW_MAP_ROWS
// for each map.
#define SHADOW_MAP_ROWS 6u
#define SHADOW_LIGHT_FACES 16u
#define SHADOW_MAP_ORTHOGRAPHIC 1u
// The most clusters the maps draw in a frame.
#define SHADOW_ENTRIES (1u << 18u)

struct Shadow_Map {
    float3 origin;
    float near;
    float3 right;
    float far;
    float3 up;
    uint kind;     // SHADOW_MAP_ORTHOGRAPHIC, or 0 for a perspective from origin
    float3 forward;
    float skip;    // nearer than this along it lies the body of the light, metres
    float4 span;   // perspective: x / z and y / z, low then high; orthographic: x and y, metres
    uint4 rect;    // its square of the atlas: x, y and side, texels; and its light (INVALID: the sun)
};

// A map from its SHADOW_MAP_ROWS rows.
Shadow_Map shadow_map_from(uint4 a, uint4 b, uint4 c, uint4 d, uint4 e, uint4 f) {
    Shadow_Map m;
    m.origin = asfloat(a.xyz);
    m.near = asfloat(a.w);
    m.right = asfloat(b.xyz);
    m.far = asfloat(b.w);
    m.up = asfloat(c.xyz);
    m.kind = c.w;
    m.forward = asfloat(d.xyz);
    m.skip = asfloat(d.w);
    m.span = asfloat(e);
    m.rect = f;
    return m;
}

Shadow_Map shadow_map_at(StructuredBuffer<uint4> data, uint rows, uint map) {
    uint at = rows + map * SHADOW_MAP_ROWS;
    return shadow_map_from(data[at], data[at + 1u], data[at + 2u], data[at + 3u], data[at + 4u], data[at + 5u]);
}

uint shadow_light_word(StructuredBuffer<uint4> data, uint light) {
    return data[light >> 2u][light & 3u];
}

bool shadow_map_orthographic(Shadow_Map m) { return m.kind == SHADOW_MAP_ORTHOGRAPHIC; }

// A point of the world on the axes of a map: x right, y up, z along it.
float3 shadow_map_local(Shadow_Map m, float3 world) {
    float3 v = world - m.origin;
    return float3(dot(v, m.right), dot(v, m.up), dot(v, m.forward));
}

// Where a point on the axes of a map falls on its span, from -1 to 1.
float2 shadow_map_unit(Shadow_Map m, float3 local) {
    float2 at = shadow_map_orthographic(m) ? local.xy : local.xy / max(local.z, 1e-6);
    return (2.0 * at - (m.span.xy + m.span.zw)) / (m.span.zw - m.span.xy);
}

// The clip coordinates of a point on the axes of a map: reversed depth, 1 at
// near and 0 at far.
float4 shadow_map_clip(Shadow_Map m, float3 local) {
    if (shadow_map_orthographic(m)) {
        float2 xy = (2.0 * local.xy - (m.span.xy + m.span.zw)) / (m.span.zw - m.span.xy);
        return float4(xy, (m.far - local.z) / (m.far - m.near), 1.0);
    }
    float x = (2.0 * local.x - (m.span.x + m.span.z) * local.z) / (m.span.z - m.span.x);
    float y = (2.0 * local.y - (m.span.y + m.span.w) * local.z) / (m.span.w - m.span.y);
    return float4(x, y, (m.far - local.z) * m.near / (m.far - m.near), local.z);
}

// How far along a map the depth it holds is.
float shadow_map_distance(Shadow_Map m, float depth) {
    if (shadow_map_orthographic(m)) return m.far - depth * (m.far - m.near);
    return m.near * m.far / (depth * (m.far - m.near) + m.near);
}

// How wide a texel of a map is `z` along it, metres.
float shadow_map_texel(Shadow_Map m, float z) {
    float across = (m.span.z - m.span.x) / float(max(m.rect.z, 1u));
    return shadow_map_orthographic(m) ? across : across * z;
}

// Whether a box of the world reaches into the frustum of a map.
bool shadow_box_side(float3 low, float3 high, float3 n, float offset) {
    return dot(n, select(n >= 0.0, high, low)) + offset >= 0.0;
}
bool shadow_map_reaches(Shadow_Map m, float3 low, float3 high) {
    // The box on the axes of the map, about its center.
    float3 center = 0.5 * (low + high) - m.origin;
    float3 half = 0.5 * (high - low);
    float3 c = float3(dot(center, m.right), dot(center, m.up), dot(center, m.forward));
    float3 e = float3(dot(half, abs(m.right)), dot(half, abs(m.up)), dot(half, abs(m.forward)));
    float3 lo = c - e, hi = c + e;
    if (hi.z < m.near || lo.z > m.far) return false;
    if (shadow_map_orthographic(m)) return hi.x >= m.span.x && lo.x <= m.span.z && hi.y >= m.span.y && lo.y <= m.span.w;
    // The four sides of the pyramid, on the axes of the map.
    return shadow_box_side(lo, hi, float3(1.0, 0.0, -m.span.x), 0.0) && shadow_box_side(lo, hi, float3(-1.0, 0.0, m.span.z), 0.0)
        && shadow_box_side(lo, hi, float3(0.0, 1.0, -m.span.y), 0.0) && shadow_box_side(lo, hi, float3(0.0, -1.0, m.span.w), 0.0);
}

// The face of the cube around a light a direction from it falls on.
uint shadow_face_of(float3 v) {
    float3 a = abs(v);
    if (a.x >= a.y && a.x >= a.z) return v.x >= 0.0 ? 0u : 1u;
    if (a.y >= a.z) return v.y >= 0.0 ? 2u : 3u;
    return v.z >= 0.0 ? 4u : 5u;
}
#endif
