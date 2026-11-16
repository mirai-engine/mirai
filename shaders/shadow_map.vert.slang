#include "native.slang"
// tested: the clusters of the instances with masked or blended materials,
// which shadow_map.frag draws only where their material is there.
//! variant tested MIRAI_SHADOW_TESTED=1
// square: of each word of a list of the buffer of the pages from
// params.list, its page of the pool (shadow_page_word), for shadow_map.frag
// to clear or copy.
//! variant square MIRAI_SHADOW_SQUARE=1
// The depth of the scene from a light into the pages of one of its maps in
// the pool (shadow_maps.slang): an instance for each page of a map a cluster
// covers (shadow_clusters.comp). The clip distances keep its triangles in the
// page, which the table maps to its page of the pool.
#include "gbuffer_vertex.slang"
#include "shadow_maps.slang"
// The clusters to draw: the instance, the cluster, the page (shadow_page_word), and 1 for one at rest.
[[vk::binding(SLOT_PASS0, 0)]] StructuredBuffer<uint4> entries : register(MIRAI_REGISTER(t, SLOT_PASS0), space0);
[[vk::binding(SLOT_PASS1, 0)]] StructuredBuffer<uint4> shadow_data : register(MIRAI_REGISTER(t, SLOT_PASS1), space0);
// The tested variant draws the clusters of masked materials, and those of
// glass for the tint and the nearest glass (params.glass).
#define SHADOW_PAGES_SLOT SLOT_PASS3
#include "shadow_cull.slang"

struct Shadow_Vertex {
    float4 position : SV_Position;
    float clip[4] : SV_ClipDistance0;
#ifdef MIRAI_SHADOW_SQUARE
    // 1 where the page of the atlas takes that of the cache, 0 where the cache
    // holds nothing of it this frame and it is cleared.
    [[vk::location(0)]] nointerpolation float held : HELD;
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
    // What a masked material without a program reads where it is: its uvs,
    // and its row and the values of the instance (shadow_map.frag).
    [[vk::location(4)]] float2 uv : UV0;
    [[vk::location(5)]] float2 uv1 : UV1;
    [[vk::location(6)]] nointerpolation uint2 material : MATERIAL;
#endif
};

[shader("vertex")]
Shadow_Vertex main(uint vertex_id : SV_VulkanVertexID, uint instance_id : SV_VulkanInstanceID) {
    Shadow_Vertex output;
    for (uint i = 0u; i < 4u; i++) output.clip[i] = -1.0;
    output.position = float4(2.0, 2.0, 2.0, 1.0);
#ifdef MIRAI_SHADOW_SQUARE
    output.held = 0.0;
    if (vertex_id >= 6u) return output;
    float2 at = float2(vertex_id == 1u || vertex_id >= 4u ? 1.0 : 0.0, vertex_id == 2u || vertex_id == 3u || vertex_id == 5u ? 0.0 : 1.0);
    uint word = shadow_pages[params.list + instance_id];
    Shadow_Map square = shadow_map_mip(shadow_map_at(shadow_data, params.rows, shadow_page_map(word)), shadow_page_mip(word));
    uint2 corner;
    if (!shadow_page_pool(square, shadow_page_of(word), corner)) return output;
    output.held = (shadow_table_entry(square.rect.x, shadow_page_entry(square.rect, shadow_page_of(word))) & SHADOW_PAGE_CACHED) != 0u ? 1.0 : 0.0;
    float4 rect = float4(float2(corner), float2(corner + SHADOW_PAGE));
    float2 texel = lerp(rect.xy, rect.zw, at);
    for (uint i = 0u; i < 4u; i++) output.clip[i] = 1.0;
    output.position = float4(2.0 * texel.x / float(SHADOW_POOL) - 1.0, 1.0 - 2.0 * texel.y / float(SHADOW_POOL), 0.0, 1.0);
    return output;
#else
#ifdef MIRAI_SHADOW_TESTED
    output.place = uint2(0u);
    output.bary = float2(0.0);
    output.reach = 0.0;
    output.toward = float3(0.0, 0.0, 1.0);
    output.uv = float2(0.0);
    output.uv1 = float2(0.0);
    output.material = uint2(0u);
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
    // At rest (entry.w, shadow_clusters.comp), the vertices of its clusters.
    Mesh_Point v = cluster_point_at(mesh, c, cluster_corner(mesh, c, vertex_id), entry.w != 0u ? INVALID : mesh.posed_word);
    Shadow_Map m = shadow_map_mip(shadow_map_at(shadow_data, params.rows, shadow_page_map(entry.z)), shadow_page_mip(entry.z));
    uint4 page = shadow_page_window(m, shadow_page_of(entry.z));
    float3 world = transform_point(inst.world, v.position);
    float3 local = shadow_map_local(m, world);
    float4 clip = shadow_map_clip(m, local);
    // The page over the map, from -1 to 1, y up.
    float4 window = float4(page) / float(max(m.rect.z, 1u));
    float4 edges = float4(2.0 * window.x - 1.0, 1.0 - 2.0 * window.w, 2.0 * window.z - 1.0, 1.0 - 2.0 * window.y);
    output.clip[0] = clip.x - edges.x * clip.w;
    output.clip[1] = edges.z * clip.w - clip.x;
    output.clip[2] = clip.y - edges.y * clip.w;
    output.clip[3] = edges.w * clip.w - clip.y;
    // From -1 to 1 over the map to its page of the pool, row 0 on top: where
    // the corner of its square would lie were the page where it is.
    uint2 pool;
    if (!shadow_page_pool(m, shadow_page_of(entry.z), pool)) {
        for (uint i = 0u; i < 4u; i++) output.clip[i] = -1.0;
        return output;
    }
    float side = float(m.rect.z) / float(SHADOW_POOL);
    float2 corner = (float2(pool) - float2(page.xy)) / float(SHADOW_POOL);
    output.position = float4((2.0 * corner.x + side) * clip.w - clip.w + side * clip.x,
        clip.w - (2.0 * corner.y + side) * clip.w + side * clip.y, clip.z, clip.w);
#ifdef MIRAI_SHADOW_TESTED
    uint at = vertex_id % 3u;
    output.place = uint2(entry.x, (entry.y << 7u) | (vertex_id / 3u));
    output.bary = float2(at == 1u ? 1.0 : 0.0, at == 2u ? 1.0 : 0.0);
    output.reach = shadow_map_texel(m, local.z) / SHADOW_TESTED_FOOTPRINT;
    output.toward = shadow_map_orthographic(m) ? -m.forward : m.origin - world;
    output.uv = v.uv;
    output.uv1 = v.uv1;
    output.material = uint2(material_of(inst, mesh_primitive_material(mesh, output.place.y)), inst.material_values);
#endif
    return output;
#endif
}
