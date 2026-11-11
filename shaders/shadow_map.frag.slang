#include "native.slang"
//! variant tested MIRAI_SHADOW_TESTED=1
//! variant tint MIRAI_SHADOW_TESTED=1 MIRAI_SHADOW_TINT=1
//! variant glass MIRAI_SHADOW_TESTED=1 MIRAI_SHADOW_GLASS=1
// The depth alone of shadow_map.vert. tested: of a masked or blended
// material, only where it is there, as a shadow ray asks it (hit_covers).
// tint: what each face of a blended material in front of the depth of the
// atlas lets through of the light, multiplied into the tint of the maps, with
// the alpha of a face whose program gives its color 0 (shadow_tint_programmed);
// glass: the depth of the nearest of those faces (shadow_tint of
// shadow_maps.slang).
#ifdef MIRAI_SHADOW_TESTED
#ifdef MIRAI_SHADOW_TINT
#define MIRAI_RAY_FILTERS
#endif
#include "trace.slang"
bool shadow_blended(uint2 place, out bool programmed) {
    Instance inst = scene_instance(place.x);
    Mesh mesh = meshes[instance_mesh(inst)];
    Material m = material_row(material_of(inst, mesh_primitive_material(mesh, place.y)));
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
#else
[shader("fragment")]
void main() {}
#endif
