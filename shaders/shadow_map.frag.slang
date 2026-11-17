#include "native.slang"
//! variant tested MIRAI_SHADOW_TESTED=1
//! variant copy MIRAI_SHADOW_COPY=1
// The depth alone of shadow_map.vert. tested: of a masked material, only
// where its mask map covers, as a shadow ray reads it; a blended one none;
// of an instance that fades, the texels whose threshold its fade does not
// reach, fixed so that the maps keep them, and their filter softens them.
// copy: a page of the cache into the atlas (shadow_map.vert square, its
// texture bound as held).
#ifdef MIRAI_SHADOW_TESTED
#define MATERIAL_RASTER
#include "trace.slang"
// The mask map, program or not, sampled with the derivatives of its uv: a
// texel of the map wide, as the footprint of a shadow ray.
[shader("fragment")]
void main(float4 position : SV_Position, [[vk::location(0)]] float2 uv : UV0, [[vk::location(1)]] nointerpolation uint2 material : MATERIAL) {
    Material m = material_row(material.x, material.y);
    if (m.alpha_mode == ALPHA_BLEND || fade_threshold(uint2(position.xy)) < material_values_fade(material.y)) discard;
    if (m.alpha_mode == ALPHA_MASK && !material_covers(m, material_mask(m, uv, uv, float2(0.0), false))) discard;
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
