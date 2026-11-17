#include "native.slang"
//! variant tested MIRAI_SHADOW_TESTED=1
//! variant copy MIRAI_SHADOW_COPY=1
// The depth alone of shadow_map.vert. tested: of a masked or blended
// material, only where it is there, as a shadow ray asks it (hit_covers).
// copy: a page of the cache into the atlas (shadow_map.vert square, its
// texture bound as held).
#ifdef MIRAI_SHADOW_TESTED
#define MATERIAL_RASTER
#include "trace.slang"
// A masked material without a program samples its alpha with the derivatives
// of its uvs, a texel of the map wide as the footprint hit_covers takes; the
// others ask hit_covers, which reads the triangle.
[shader("fragment")]
void main([[vk::location(0)]] nointerpolation uint2 place : PLACE, [[vk::location(1)]] float2 bary : BARY, [[vk::location(2)]] nointerpolation float reach : REACH, [[vk::location(3)]] float2 uv : UV0, [[vk::location(4)]] float2 uv1 : UV1, [[vk::location(5)]] nointerpolation uint2 material : MATERIAL) {
    Material m = material_row(material.x, material.y);
    if (m.program_id == 0u && m.alpha_mode == ALPHA_MASK) {
        if (!material_covers(m, material_base_color(m, uv, uv1, float2(0.0), float3(1.0), false).a)) discard;
        return;
    }
    if (!hit_covers(place.x, place.y, bary, reach, BLEND_PASSES)) discard;
}
#elif defined(MIRAI_SHADOW_COPY)
#include "common.slang"
[[vk::binding(SLOT_PASS2, 0)]] Texture2D<float4> held : register(MIRAI_REGISTER(t, SLOT_PASS2), space0);
[shader("fragment")]
float main(float4 position : SV_Position, [[vk::location(0)]] nointerpolation float cached : HELD) : SV_Depth { return cached > 0.5 ? held.Load(int3(int2(floor(position.xy)), 0)).r : 0.0; }
#else
[shader("fragment")]
void main() {}
#endif
