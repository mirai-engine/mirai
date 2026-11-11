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

// SHADOW_MAP_ROWS, SHADOW_LIGHT_FACES, SHADOW_ENTRIES: the buffer of the maps
// and the clusters they draw (render/abi); those of the instances with masked
// or blended materials are listed from the end. The side of the atlas, texels,
// is Frame.sun_maps.z.
// The width of what a ray reads of a material over how far it came
// (hit_covers): a fragment of a map reads its material as coarsely as a texel.
#define SHADOW_TESTED_FOOTPRINT 0.004

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

// 1 where the depth a texel of a map holds is no blocker of a point `limit`
// along it: nearer than `skip` lies the body of the light.
float shadow_past(Shadow_Map m, float depth, float skip, float limit) {
    float b = shadow_map_distance(m, depth);
    return b > skip && b < limit ? 0.0 : 1.0;
}

// Whether the center of the light sees a point `d` along a map past what the
// 2x2 texels around `texel` hold, blended between them.
float shadow_hard_seen(Texture2D<float4> atlas, Shadow_Map m, float2 texel, float d, float bias, float skip) {
    float2 corner = texel - 0.5;
    float2 first = floor(corner), f = corner - first;
    float4 depth = atlas.GatherRed(point_sampler, (float2(m.rect.xy) + first + 1.0) / float(frame.sun_maps.z));
    float limit = d - bias;
    float4 past = float4(shadow_past(m, depth.x, skip, limit), shadow_past(m, depth.y, skip, limit),
                         shadow_past(m, depth.z, skip, limit), shadow_past(m, depth.w, skip, limit));
    // Gather order: (0, 1), (1, 1), (1, 0), (0, 0).
    return lerp(lerp(past.w, past.z, f.x), lerp(past.x, past.y, f.x), f.y);
}

// The map of the sun of the view that holds a point with room for the taps
// around it, the nearest cascade first (Frame.sun_maps); false where none
// does, or the view drew none.
bool sun_map_of(float3 position, out Shadow_Map m) {
    uint count = min(frame.sun_maps.x, uint(SUN_MAP_ROWS) / SHADOW_MAP_ROWS);
    for (uint k = 0u; k < count; k++) {
        uint row = k * SHADOW_MAP_ROWS;
        m = shadow_map_from(frame.sun_map_rows[row], frame.sun_map_rows[row + 1u], frame.sun_map_rows[row + 2u],
                            frame.sun_map_rows[row + 3u], frame.sun_map_rows[row + 4u], frame.sun_map_rows[row + 5u]);
        float3 local = shadow_map_local(m, position);
        if (all(abs(shadow_map_unit(m, local)) < 0.9) && local.z < m.far) return true;
    }
    m = (Shadow_Map)0;
    return false;
}

#ifdef SUN_SHADOW_SLOT
// The atlas of the maps of the view (render.Surface_Source.Shadow_Atlas), for
// a pass that takes the shadows of the lights from it and not from rays.
[[vk::binding(SUN_SHADOW_SLOT, 0)]] Texture2D<float4> view_shadow_atlas : register(MIRAI_REGISTER(t, SUN_SHADOW_SLOT), space0);

// How much of the sun reaches a point past what the maps of the view hold;
// -1 where no cascade holds the point, or the view drew none: a ray tells.
// n: the normal of its surface, zero for a point of a medium. blended:
// between the texels around the point, the border of a shadow as fine as the
// map; else by the texel it falls in alone, as the samples of the direct light
// tell a point lit (shadow_map_seen of direct_samples.comp).
float sun_shadow_seen(float3 position, float3 n, bool blended = true) {
    Shadow_Map m;
    if (!sun_map_of(position, m)) return -1.0;
    float c = dot(n, frame.sun_direction.xyz);
    float lean = c > 0.0 ? min(sqrt(max(1.0 - c * c, 0.0)) / max(c, 1e-3), 8.0) : 0.0;
    float step = shadow_map_texel(m, 0.0);
    // A texel and a half off the surface, so that it does not hide itself.
    float3 local = shadow_map_local(m, position + n * (1.5 * step));
    float2 unit = shadow_map_unit(m, local);
    float2 texel = float2(unit.x * 0.5 + 0.5, 0.5 - unit.y * 0.5) * float(m.rect.z);
    float bias = step * (1.0 + lean) + 0.001 * local.z;
    if (blended) return shadow_hard_seen(view_shadow_atlas, m, texel, local.z, bias, m.near);
    return shadow_past(m, view_shadow_atlas.Load(int3(int2(m.rect.xy) + int2(floor(texel)), 0)).r, m.near, local.z - bias);
}
#endif

// The face of the cube around a light a direction from it falls on.
uint shadow_face_of(float3 v) {
    float3 a = abs(v);
    if (a.x >= a.y && a.x >= a.z) return v.x >= 0.0 ? 0u : 1u;
    if (a.y >= a.z) return v.y >= 0.0 ? 2u : 3u;
    return v.z >= 0.0 ? 4u : 5u;
}

#ifdef SHADOW_DATA_SLOT
// The buffer of the maps of the view (render.pass_shadow_data): the words of
// the lights, then the rows of the maps from Frame.sun_maps.y. With
// SUN_SHADOW_SLOT.
[[vk::binding(SHADOW_DATA_SLOT, 0)]] StructuredBuffer<uint4> view_shadow_data : register(MIRAI_REGISTER(t, SHADOW_DATA_SLOT), space0);

// The map of local light `light` a point falls in; false where it has none on
// that side, or the point lies off the part of the face it was fitted to or
// past its depths, where its texels hold what lies elsewhere: rays tell
// there. A spot with one map along its cone (SHADOW_SPOT_FACE) has it for
// every point in its cone.
bool light_map_of(uint light, float3 position, out Shadow_Map m) {
    m = (Shadow_Map)0;
    if (frame.sun_maps.z == 0u) return false;
    uint word = shadow_light_word(view_shadow_data, light);
    if (word == 0u) return false;
    uint faces = word >> SHADOW_LIGHT_FACES;
    uint at = (word & 0xFFFFu) - 1u;
    if ((faces & (1u << SHADOW_SPOT_FACE)) == 0u) {
        uint face = shadow_face_of(position - lights[light].position_range.xyz);
        if ((faces & (1u << face)) == 0u) return false;
        at += countbits(faces & ((1u << face) - 1u));
    }
    m = shadow_map_at(view_shadow_data, frame.sun_maps.y, at);
    float3 local = shadow_map_local(m, position);
    return local.z > m.near && local.z < m.far && all(abs(shadow_map_unit(m, local)) < 1.0);
}

#ifdef SUN_SHADOW_SLOT
// How much of local light `light` reaches a point past what its map holds, as
// sun_shadow_seen; -1 where no map of it holds the point. radius: of the
// light, metres: about that near it lies its body, not what it shines past.
float light_shadow_seen(uint light, float3 position, float3 n, float radius) {
    Shadow_Map m;
    if (!light_map_of(light, position, m)) return -1.0;
    float c = dot(n, normalize(lights[light].position_range.xyz - position));
    float lean = c > 0.0 ? min(sqrt(max(1.0 - c * c, 0.0)) / max(c, 1e-3), 8.0) : 0.0;
    float step = shadow_map_texel(m, shadow_map_local(m, position).z);
    float3 local = shadow_map_local(m, position + n * (1.5 * step));
    float2 unit = shadow_map_unit(m, local);
    // Past its far plane a map holds nothing: an empty texel would read as a blocker there.
    if (any(abs(unit) >= 1.0) || local.z <= m.near || local.z >= m.far) return -1.0;
    float2 texel = float2(unit.x * 0.5 + 0.5, 0.5 - unit.y * 0.5) * float(m.rect.z);
    float bias = step * (1.0 + lean) + 0.001 * local.z;
    return shadow_hard_seen(view_shadow_atlas, m, texel, local.z, bias, max(m.near, min(3.0 * radius, radius + 0.3)));
}
#endif
#endif

#ifdef SHADOW_TINT_SLOT
// What the glass in front of the depth of each texel of the maps lets through
// of their light (render.Surface_Source.Shadow_Tint, shadow_map.frag): all of
// it lies between the light and a surface the maps light.
[[vk::binding(SHADOW_TINT_SLOT, 0)]] Texture2D<float4> view_shadow_tint : register(MIRAI_REGISTER(t, SHADOW_TINT_SLOT), space0);
#ifdef SHADOW_GLASS_SLOT
// The depth of the nearest of that glass (Surface_Source.Shadow_Glass), for a
// point that may lie in front of it: one of a medium.
[[vk::binding(SHADOW_GLASS_SLOT, 0)]] Texture2D<float4> view_shadow_glass : register(MIRAI_REGISTER(t, SHADOW_GLASS_SLOT), space0);
#endif

// What the glass between the light of map m and a point lets through; 1 while
// the maps keep no tint (Frame.sun_maps.w).
float3 shadow_tint(Shadow_Map m, float3 position) {
    if (frame.sun_maps.w == 0u) return float3(1.0);
    float3 local = shadow_map_local(m, position);
    float2 unit = shadow_map_unit(m, local);
    float side = float(m.rect.z);
    float2 texel = clamp(float2(unit.x * 0.5 + 0.5, 0.5 - unit.y * 0.5) * side, float2(0.5), float2(side - 0.5));
#ifdef SHADOW_GLASS_SLOT
    if (!(shadow_map_distance(m, view_shadow_glass.Load(int3(int2(m.rect.xy) + int2(floor(texel)), 0)).r) < local.z)) return float3(1.0);
#endif
    return view_shadow_tint.SampleLevel(linear_sampler, (float2(m.rect.xy) + texel) / float(frame.sun_maps.z), 0.0).rgb;
}

// Whether a glass whose program gives its color stands in the way of the
// light of map m to position: its tint keeps only the mean of the program,
// and the rays of the samples of the direct light run the program instead.
bool shadow_tint_programmed(Shadow_Map m, float3 position) {
    if (frame.sun_maps.w == 0u) return false;
    float3 local = shadow_map_local(m, position);
    float2 unit = shadow_map_unit(m, local);
    float side = float(m.rect.z);
    int2 texel = int2(m.rect.xy) + int2(clamp(float2(unit.x * 0.5 + 0.5, 0.5 - unit.y * 0.5) * side, float2(0.5), float2(side - 0.5)));
#ifdef SHADOW_GLASS_SLOT
    if (!(shadow_map_distance(m, view_shadow_glass.Load(int3(texel, 0)).r) < local.z)) return false;
#endif
    return view_shadow_tint.Load(int3(texel, 0)).a < 0.5;
}
#endif
#endif
