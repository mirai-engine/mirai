#include "native.slang"
// tested: the clusters of the instances with masked or blended materials,
// which shadow_map.frag draws only where their material is there.
//! variant tested MIRAI_SHADOW_TESTED=1
// The depth of the scene from a light into the square of one of its maps in
// the atlas (shadow_maps.slang): an instance for each cluster a map takes
// (shadow_maps.comp). The clip distances keep its triangles in the frustum of
// the map, which the atlas maps to its square.
#include "gbuffer_vertex.slang"
#include "shadow_maps.slang"
// The clusters to draw: the instance, the cluster and the map.
[[vk::binding(SLOT_PASS0, 0)]] StructuredBuffer<uint4> entries : register(MIRAI_REGISTER(t, SLOT_PASS0), space0);
[[vk::binding(SLOT_PASS1, 0)]] StructuredBuffer<uint4> shadow_data : register(MIRAI_REGISTER(t, SLOT_PASS1), space0);
// rows: of the words of the lights in shadow_data.
struct Params_Block { uint instances; uint maps; uint rows; uint pad0; };
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);

struct Shadow_Vertex {
    float4 position : SV_Position;
    float clip[4] : SV_ClipDistance0;
#ifdef MIRAI_SHADOW_TESTED
    // The instance and the primitive of the triangle, where on it the point
    // is, and how far a ray that reads its material as coarsely as a texel of
    // the map would have come (hit_covers).
    [[vk::location(0)]] nointerpolation uint2 place : PLACE;
    [[vk::location(1)]] float2 bary : BARY;
    [[vk::location(2)]] nointerpolation float reach : REACH;
#endif
};

[shader("vertex")]
Shadow_Vertex main(uint vertex_id : SV_VulkanVertexID, uint instance_id : SV_VulkanInstanceID) {
    Shadow_Vertex output;
    for (uint i = 0u; i < 4u; i++) output.clip[i] = -1.0;
    output.position = float4(2.0, 2.0, 2.0, 1.0);
#ifdef MIRAI_SHADOW_TESTED
    output.place = uint2(0u);
    output.bary = float2(0.0);
    output.reach = 0.0;
    if (instance_id >= SHADOW_TESTED_ENTRIES) return output;
    uint4 entry = entries[SHADOW_ENTRIES - 1u - instance_id];
#else
    if (instance_id >= SHADOW_ENTRIES - SHADOW_TESTED_ENTRIES) return output;
    uint4 entry = entries[instance_id];
#endif
    Instance inst = scene_instance(entry.x);
    Mesh mesh = meshes[instance_mesh(inst)];
    Cluster c = mesh_cluster(mesh, entry.y);
    if (vertex_id >= cluster_triangle_count(c) * 3u) return output;
    Mesh_Point v = cluster_point_at(mesh, c, cluster_corner(mesh, c, vertex_id), mesh.posed_word);
    Shadow_Map m = shadow_map_at(shadow_data, params.rows, entry.z);
    float3 local = shadow_map_local(m, transform_point(inst.world, v.position));
    float4 clip = shadow_map_clip(m, local);
    output.clip[0] = clip.w + clip.x;
    output.clip[1] = clip.w - clip.x;
    output.clip[2] = clip.w + clip.y;
    output.clip[3] = clip.w - clip.y;
    // From -1 to 1 over the map to its square of the atlas, row 0 on top.
    float side = float(m.rect.z) / float(SHADOW_ATLAS);
    float2 corner = float2(m.rect.xy) / float(SHADOW_ATLAS);
    output.position = float4((2.0 * corner.x + side) * clip.w - clip.w + side * clip.x,
        clip.w - (2.0 * corner.y + side) * clip.w + side * clip.y, clip.z, clip.w);
#ifdef MIRAI_SHADOW_TESTED
    uint at = vertex_id % 3u;
    output.place = uint2(entry.x, (entry.y << 7u) | (vertex_id / 3u));
    output.bary = float2(at == 1u ? 1.0 : 0.0, at == 2u ? 1.0 : 0.0);
    output.reach = shadow_map_texel(m, local.z) / SHADOW_TESTED_FOOTPRINT;
#endif
    return output;
}
