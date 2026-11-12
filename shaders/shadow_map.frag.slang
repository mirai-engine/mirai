#include "native.slang"
//! variant tested MIRAI_SHADOW_TESTED=1
//! variant tint MIRAI_SHADOW_TESTED=1 MIRAI_SHADOW_TINT=1
//! variant glass MIRAI_SHADOW_TESTED=1 MIRAI_SHADOW_GLASS=1
//! variant moved MIRAI_SHADOW_MOVED=1
// The depth alone of shadow_map.vert. tested: of a masked or blended
// material, only where it is there, as a shadow ray asks it (hit_covers).
// tint: what each face of a blended material in front of the depth of the
// atlas lets through of the light, multiplied into the tint of the maps, with
// the alpha of a face whose program gives its color 0 (shadow_tint_programmed);
// glass: the depth of the nearest of those faces (shadow_tint of
// shadow_maps.slang). moved: what a square of the cache held, from a copy of
// it, its texels moved as far as the map did (shadow_map.vert square); far
// where it held nothing.
#ifdef MIRAI_SHADOW_TESTED
#ifdef MIRAI_SHADOW_TINT
#define MIRAI_RAY_FILTERS
#endif
#include "trace.slang"
bool shadow_blended(uint2 place, out bool programmed) {
    Instance inst = scene_instance(place.x);
    Mesh mesh = meshes[instance_mesh(inst)];
    Material m = material_row(material_of(inst, mesh_primitive_material(mesh, place.y)), inst.material_values);
    programmed = m.program_id != 0u;
    return m.alpha_mode == ALPHA_BLEND;
}
#ifdef MIRAI_SHADOW_TINT
[shader("fragment")]
float4 main([[vk::location(0)]] nointerpolation uint2 place : PLACE, [[vk::location(1)]] float2 bary : BARY, [[vk::location(2)]] nointerpolation float reach : REACH, [[vk::location(3)]] float3 toward : TOWARD) : SV_Target0 {
    bool programmed;
    if (!shadow_blended(place, programmed)) discard;
    ray_filter = float3(1.0);
    ray_filter_direction = normalize(toward);
    hit_covers(place.x, place.y, bary, reach, BLEND_FILTERS);
    return float4(ray_filter, programmed ? 0.0 : 1.0);
}
#elif defined(MIRAI_SHADOW_GLASS)
[shader("fragment")]
void main([[vk::location(0)]] nointerpolation uint2 place : PLACE, [[vk::location(1)]] float2 bary : BARY, [[vk::location(2)]] nointerpolation float reach : REACH, [[vk::location(3)]] float3 toward : TOWARD) {
    bool programmed;
    if (!shadow_blended(place, programmed)) discard;
}
#else
[shader("fragment")]
void main([[vk::location(0)]] nointerpolation uint2 place : PLACE, [[vk::location(1)]] float2 bary : BARY, [[vk::location(2)]] nointerpolation float reach : REACH, [[vk::location(3)]] float3 toward : TOWARD) {
    if (!hit_covers(place.x, place.y, bary, reach, BLEND_PASSES)) discard;
}
#endif
#elif defined(MIRAI_SHADOW_MOVED)
#include "common.slang"
[[vk::binding(SLOT_PASS2, 0)]] Texture2D<float4> held : register(MIRAI_REGISTER(t, SLOT_PASS2), space0);
[shader("fragment")]
float main(float4 position : SV_Position, [[vk::location(0)]] nointerpolation int4 square : SQUARE, [[vk::location(1)]] nointerpolation uint side : SIDE) : SV_Depth {
    int2 texel = int2(floor(position.xy)) - square.xy;
    int2 from = texel + int2(square.z, -square.w);
    if (any(from < 0) || any(from >= int(side))) return 0.0;
    return held.Load(int3(square.xy + from, 0)).r;
}
#else
[shader("fragment")]
void main() {}
#endif
