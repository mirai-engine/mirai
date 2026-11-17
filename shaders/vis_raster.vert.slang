#include "native.slang"
// The vertices of the raster of the visibility target (vis_raster.frag): a
// draw of a raster bin is indexed by the triangles listed of its clusters
// (raster_lists.slang), and a vertex is one raster_vertices.comp placed, read
// where it wrote it. tested: of the clusters whose pixels the mask map of
// their material or a fade decides, with the uv that map reads; clip: of a
// view with a clip plane, which nothing is drawn behind. The instance of a
// draw is its first triangle among those listed.
//! variant clip MIRAI_CLIP_PLANE=1
//! variant tested MIRAI_VISIBILITY_TESTED=1
//! variant tested_clip MIRAI_CLIP_PLANE=1 MIRAI_VISIBILITY_TESTED=1
#define MIRAI_BATCHES
#define MIRAI_VISIBILITY
#include "visibility.slang"
#include "raster_lists.slang"
// The visible clusters of both phases, by raster bin (cull_bins.comp).
[[vk::binding(SLOT_PASS0, 0)]] StructuredBuffer<Visible_Cluster> visible : register(MIRAI_REGISTER(t, SLOT_PASS0), space0);
[[vk::binding(SLOT_PASS1, 0)]] StructuredBuffer<Raster_Vertex> raster_vertices : register(MIRAI_REGISTER(t, SLOT_PASS1), space0);
#ifdef MIRAI_VISIBILITY_TESTED
typedef Coverage_Vertex Stage_Vertex;
#else
typedef Visibility_Vertex Stage_Vertex;
#endif

[shader("vertex")]
Stage_Vertex main(uint vertex_id : SV_VulkanVertexID, uint instance_id : SV_VulkanInstanceID) {
    Stage_Vertex output = (Stage_Vertex)0;
    Raster_Vertex vertex = raster_vertices[vertex_id];
#ifdef MIRAI_VISIBILITY_TESTED
    Visible_Cluster entry = visible[raster_source_entry(vertex.source)];
    Instance inst = scene_instance(entry.instance);
    Mesh mesh = meshes[instance_mesh(inst)];
    Cluster c = cluster_at(entry.cluster);
    output.out_material = uint2(entry.material, inst.material_values);
    output.out_fade = uint(saturate(instance_fade(entry.instance, inst)) * 65535.0 + 0.5);
    output.out_uv = block_uv_at(mesh, c, visible_block(mesh, c, entry), raster_source_local(vertex.source), mask_uv_set(entry.material));
#endif
    output.position = view_clip(vertex.world);
#ifdef MIRAI_CLIP_PLANE
    output.clip = dot(frame.clip_plane.xyz, vertex.world) + frame.clip_plane.w;
#endif
    output.out_first = instance_id;
    return output;
}
