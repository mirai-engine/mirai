#include "native.slang"
// tested: the clusters of the instances with masked or blended materials,
// which shadow_map.frag draws only where their material is there.
//! variant tested MIRAI_SHADOW_TESTED=1
// square: the square of each map of a list from word params.list, a word
// each: the map, and how many texels its cache moves along x and y plus 2048
// (render.shadow_square), for shadow_map.frag to clear or move.
//! variant square MIRAI_SHADOW_SQUARE=1
// The depth of the scene from a light into the square of one of its maps in
// the atlas (shadow_maps.slang): an instance for each cluster a job of a map
// takes (shadow_maps.comp). The clip distances keep its triangles in the
// window of the job, which the atlas maps to its part of the square.
#include "gbuffer_vertex.slang"
#include "shadow_maps.slang"
// The clusters to draw: the instance, the cluster and the job.
[[vk::binding(SLOT_PASS0, 0)]] StructuredBuffer<uint4> entries : register(MIRAI_REGISTER(t, SLOT_PASS0), space0);
[[vk::binding(SLOT_PASS1, 0)]] StructuredBuffer<uint4> shadow_data : register(MIRAI_REGISTER(t, SLOT_PASS1), space0);
// The tested variant draws the clusters of masked materials, and those of
// glass for the tint and the nearest glass (params.glass).
#include "shadow_cull.slang"

struct Shadow_Vertex {
    float4 position : SV_Position;
    float clip[4] : SV_ClipDistance0;
#ifdef MIRAI_SHADOW_SQUARE
    // The corner of the square, and how far its texels move.
    [[vk::location(0)]] nointerpolation int4 square : SQUARE;
    [[vk::location(1)]] nointerpolation uint side : SIDE;
#endif
#ifdef MIRAI_SHADOW_TESTED
    // The instance and the primitive of the triangle, where on it the point
    // is, and how far a ray that reads its material as coarsely as a texel of
    // the map would have come (hit_covers).
    [[vk::location(0)]] nointerpolation uint2 place : PLACE;
    [[vk::location(1)]] float2 bary : BARY;
    [[vk::location(2)]] nointerpolation float reach : REACH;
    // From the point towards the light, as a shadow ray goes.
    [[vk::location(3)]] float3 toward : TOWARD;
#endif
};

[shader("vertex")]
Shadow_Vertex main(uint vertex_id : SV_VulkanVertexID, uint instance_id : SV_VulkanInstanceID) {
    Shadow_Vertex output;
    for (uint i = 0u; i < 4u; i++) output.clip[i] = -1.0;
    output.position = float4(2.0, 2.0, 2.0, 1.0);
#ifdef MIRAI_SHADOW_SQUARE
    output.square = int4(0);
    output.side = 0u;
    if (instance_id >= params.maps || vertex_id >= 6u) return output;
    uint word = shadow_word(shadow_data, params.list + instance_id);
    Shadow_Map square = shadow_map_at(shadow_data, params.rows, word & 0xFFu);
    float2 at = float2(vertex_id == 1u || vertex_id >= 4u ? 1.0 : -1.0, vertex_id == 2u || vertex_id == 3u || vertex_id == 5u ? 1.0 : -1.0);
    float extent = float(square.rect.z) / float(frame.sun_maps.z);
    float2 low = float2(square.rect.xy) / float(frame.sun_maps.z);
    for (uint i = 0u; i < 4u; i++) output.clip[i] = 1.0;
    output.position = float4(2.0 * low.x + extent - 1.0 + extent * at.x, 1.0 - 2.0 * low.y - extent + extent * at.y, 0.0, 1.0);
    output.square = int4(square.rect.xy, int((word >> 8u) & 0xFFFu) - 2048, int(word >> 20u) - 2048);
    output.side = square.rect.z;
    return output;
#else
#ifdef MIRAI_SHADOW_TESTED
    output.place = uint2(0u);
    output.bary = float2(0.0);
    output.reach = 0.0;
    output.toward = float3(0.0, 0.0, 1.0);
    uint draw = params.glass != 0u ? SHADOW_DRAW_GLASS : SHADOW_DRAW_TESTED;
#else
    uint draw = SHADOW_DRAW_OPAQUE;
#endif
    if (instance_id >= shadow_room(draw)) return output;
    uint4 entry = entries[shadow_entry(draw, instance_id)];
    Instance inst = scene_instance(entry.x);
    Mesh mesh = meshes[instance_mesh(inst)];
    Cluster c = mesh_cluster(mesh, entry.y);
    if (vertex_id >= cluster_triangle_count(c) * 3u) return output;
    Mesh_Point v = cluster_point_at(mesh, c, cluster_corner(mesh, c, vertex_id), mesh.posed_word);
    Shadow_Job job = shadow_job(shadow_data, entry.z);
    Shadow_Map m = shadow_map_at(shadow_data, params.rows, job.map);
    float3 world = transform_point(inst.world, v.position);
    float3 local = shadow_map_local(m, world);
    float4 clip = shadow_map_clip(m, local);
    // The window of the job over the map, from -1 to 1, y up.
    float4 window = float4(job.window) / float(max(m.rect.z, 1u));
    float4 edges = float4(2.0 * window.x - 1.0, 1.0 - 2.0 * window.w, 2.0 * window.z - 1.0, 1.0 - 2.0 * window.y);
    output.clip[0] = clip.x - edges.x * clip.w;
    output.clip[1] = edges.z * clip.w - clip.x;
    output.clip[2] = clip.y - edges.y * clip.w;
    output.clip[3] = edges.w * clip.w - clip.y;
    // From -1 to 1 over the map to its square of the atlas, row 0 on top.
    float side = float(m.rect.z) / float(frame.sun_maps.z);
    float2 corner = float2(m.rect.xy) / float(frame.sun_maps.z);
    output.position = float4((2.0 * corner.x + side) * clip.w - clip.w + side * clip.x,
        clip.w - (2.0 * corner.y + side) * clip.w + side * clip.y, clip.z, clip.w);
#ifdef MIRAI_SHADOW_TESTED
    uint at = vertex_id % 3u;
    output.place = uint2(entry.x, (entry.y << 7u) | (vertex_id / 3u));
    output.bary = float2(at == 1u ? 1.0 : 0.0, at == 2u ? 1.0 : 0.0);
    output.reach = shadow_map_texel(m, local.z) / SHADOW_TESTED_FOOTPRINT;
    output.toward = shadow_map_orthographic(m) ? -m.forward : m.origin - world;
#endif
    return output;
#endif
}
