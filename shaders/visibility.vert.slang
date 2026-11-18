#include "native.slang"
// The visibility of a view (render.visibility_pass): the clusters of a
// visible list, an instance of the draw a cluster, each corner where
// gbuffer.vert places it, with no more than visibility.frag keeps. A corner
// past the triangles of its cluster is collapsed. The entry of the list says
// where the corners are, so the attributes of the surface are not read here
// but once a pixel (gbuffer_visible.frag).
#include "scene.slang"
// The visible clusters of a phase, or those of the Surface programs, each as scene.visible_entry gives it.
[[vk::binding(SLOT_PASS0, 0)]] StructuredBuffer<uint4> visible : register(MIRAI_REGISTER(t, SLOT_PASS0), space0);
#include <extension_vertex.slang>

struct Stage_Output {
    float4 position : SV_Position;
    // The instance, the cluster as a word of the index pool, and the triangle of it.
    [[vk::location(0)]] nointerpolation uint3 out_ids : TEXCOORD0;
    // The weights of the second and third corners (scene.hit_point), and the linear depth.
    [[vk::location(1)]] float3 out_bary_depth : TEXCOORD1;
};

[shader("vertex")]
Stage_Output main(uint vertex_id : SV_VulkanVertexID, uint instance_id : SV_VulkanInstanceID) {
    Stage_Output output = (Stage_Output)0;
    uint4 entry = visible[instance_id];
    uint index = entry.x;
    Instance inst = scene_instance(index);
    Cluster c = cluster_at(entry.y);
    uint corner = vertex_id;
    if (corner >= cluster_triangle_count(c) * 3u) {
        // Outside the volume of the view: the triangle has no area to raster.
        output.position = float4(2.0, 2.0, 2.0, 1.0);
        return output;
    }
    uint local = (vertex_words[entry.z + corner / 4u] >> ((corner & 3u) * 8u)) & 0xffu;
    float3 world;
    if (entry.w != INVALID) world = transform_point(inst.world, posed_position(entry.w, local));
    else world = transform_point(inst.world, cluster_rest_position(meshes[instance_mesh(inst)], c, local));
#ifdef MIRAI_HOOK_VERTEX
    if (instance_batched(index)) {
        // The hook moves it as in gbuffer.vert, by the color of the vertex.
        float4 color = instance_vertex_color(inst, c.vertex_first + local, cluster_point_at(meshes[instance_mesh(inst)], c, local, INVALID).color);
        float3 pivot = float3(inst.world[0].w, inst.world[1].w, inst.world[2].w);
        world = mirai_batch_vertex(world, pivot, color, batch_vertex(batch_row(batch_of(index))), frame.time.x);
    }
#endif
    output.position = view_clip(world);
    output.out_ids = uint3(index, entry.y, corner / 3u);
    uint k = corner % 3u;
    output.out_bary_depth = float3(k == 1u ? 1.0 : 0.0, k == 2u ? 1.0 : 0.0, dot(world - frame.camera_position.xyz, frame.camera_forward.xyz));
    return output;
}
