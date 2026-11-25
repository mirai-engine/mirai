#include "native.slang"
//! variant tested MIRAI_SHADOW_TESTED=1
//! variant copy MIRAI_SHADOW_COPY=1
// The depth alone of the maps of the shadows: of the clusters of a page
// (vis_raster.vert shadow), and of the squares that clear its part of the
// pool (shadow_map.vert). tested: of a masked material, only
// where its mask map covers, as a shadow ray reads it; a blended one none;
// of an instance that fades, the texels whose threshold its fade does not
// reach, fixed so that the maps keep them, and their filter softens them.
// copy: a page of the atlas, the nearer of the cache (shadow_map.vert, its
// texture bound as held) and the tile of the page in the layer of what sways.
#ifdef MIRAI_SHADOW_TESTED
#define MATERIAL_RASTER
#include "trace.slang"
// The mask map, program or not, sampled with the derivatives of its uv: a
// texel of the map wide, as the footprint of a shadow ray.
[shader("fragment")]
void main(float4 position : SV_Position, [[vk::location(0)]] float2 uv : UV0, [[vk::location(1)]] nointerpolation uint2 material : MATERIAL) {
    Material m = material_row(material.x, material.y);
    if (material_apart(m) || fade_threshold(uint2(position.xy)) < material_values_fade(material.y)) discard;
    if (m.alpha_mode == ALPHA_MASK && !material_covers(m, material_mask(m, uv, uv, float2(0.0), false))) discard;
}
#elif defined(MIRAI_SHADOW_COPY)
#include "common.slang"
[[vk::binding(SLOT_PASS2, 0)]] Texture2D<float4> held : register(MIRAI_REGISTER(t, SLOT_PASS2), space0);
// The pool scaled down by the levels it lies coarser, a tile of each page;
// 0 where nothing that sways lies (reversed depth).
[[vk::binding(SLOT_PASS4, 0)]] Texture2D<float4> layer : register(MIRAI_REGISTER(t, SLOT_PASS4), space0);
[shader("fragment")]
float main(float4 position : SV_Position, [[vk::location(0)]] nointerpolation float cached : HELD) : SV_Depth {
    int2 at = int2(floor(position.xy));
    float depth = cached > 0.5 ? held.Load(int3(at, 0)).r : 0.0;
    uint2 size;
    layer.GetDimensions(size.x, size.y);
    int scale = int(SHADOW_POOL / max(size.x, 1u)), side = int(SHADOW_PAGE) / scale;
    int2 tile = at / int(SHADOW_PAGE) * side;
    // The four texels of the tile around the middle of this one, and how much of it each covers.
    float2 q = (float2(at % int(SHADOW_PAGE)) + 0.5) / float(scale) - 0.5;
    int2 low = int2(floor(q));
    float2 f = q - float2(low);
    int2 a = clamp(low, int2(0, 0), int2(side - 1, side - 1)), b = clamp(low + 1, int2(0, 0), int2(side - 1, side - 1));
    float4 d = float4(layer.Load(int3(tile + a, 0)).r, layer.Load(int3(tile + int2(b.x, a.y), 0)).r,
                      layer.Load(int3(tile + int2(a.x, b.y), 0)).r, layer.Load(int3(tile + b, 0)).r);
    float4 w = float4((1.0 - f.x) * (1.0 - f.y), f.x * (1.0 - f.y), (1.0 - f.x) * f.y, f.x * f.y);
    bool4 covered = d > 0.0;
    // Mostly outside what sways, the cache alone, exact.
    if (dot(w, select(covered, 1.0, 0.0)) < 0.5) return depth;
    // Inside, the plane the four sampled; on its outline, the farthest of
    // those it covers, so that the outline does not shade the caster itself.
    float farthest = min(min(covered.x ? d.x : 1.0, covered.y ? d.y : 1.0), min(covered.z ? d.z : 1.0, covered.w ? d.w : 1.0));
    return max(depth, all(covered) ? dot(w, d) : farthest);
}
#else
[shader("fragment")]
void main() {}
#endif
