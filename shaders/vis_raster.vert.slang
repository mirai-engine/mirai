#include "native.slang"
// The vertices of the raster of the visibility target (vis_raster.frag): a
// draw of a raster bin is indexed by the triangles listed of its clusters
// (raster_lists.slang), and a vertex is one raster_vertices.comp placed, read
// where it wrote it. tested: of the clusters whose pixels the alpha of their
// material or a fade decides, with what their alpha reads of the vertex;
// clip: of a view with a clip plane, which nothing is drawn behind. The
// instance of a draw is its first triangle among those listed.
//! variant clip MIRAI_CLIP_PLANE=1
//! variant tested MIRAI_VISIBILITY_TESTED=1
//! variant tested_clip MIRAI_CLIP_PLANE=1 MIRAI_VISIBILITY_TESTED=1
#define MIRAI_BATCHES
#define MIRAI_VISIBILITY
#include "gbuffer_vertex.slang"
#include "visibility.slang"
#include "raster_lists.slang"
// The visible clusters of both phases, by raster bin (cull_bins.comp).
[[vk::binding(SLOT_PASS0, 0)]] StructuredBuffer<Visible_Cluster> visible : register(MIRAI_REGISTER(t, SLOT_PASS0), space0);
[[vk::binding(SLOT_PASS1, 0)]] StructuredBuffer<Raster_Vertex> raster_vertices : register(MIRAI_REGISTER(t, SLOT_PASS1), space0);
#ifdef MIRAI_VISIBILITY_TESTED
#include <extension_vertex.slang>
#include "gbuffer_build.slang"
typedef Gbuffer_Vertex Stage_Vertex;
#else
typedef Visibility_Vertex Stage_Vertex;
#endif

[shader("vertex")]
Stage_Vertex main(uint vertex_id : SV_VulkanVertexID, uint instance_id : SV_VulkanInstanceID) {
    Stage_Vertex output = (Stage_Vertex)0;
    Raster_Vertex vertex = raster_vertices[vertex_id];
#ifdef MIRAI_VISIBILITY_TESTED
    // What the fade and the alpha of a tested cluster read; not where the
    // vertex was, nor its light, which the resolve builds.
    Visible_Cluster entry = visible[raster_source_entry(vertex.source)];
    uint local = raster_source_local(vertex.source);
    Instance inst = scene_instance(entry.instance);
    Mesh mesh = meshes[instance_mesh(inst)];
    Cluster c = cluster_at(entry.cluster);
    Gbuffer_Cluster k = gbuffer_cluster_of(entry.instance, inst, mesh, entry.material, entry.along);
    Mesh_Point v = block_point_at(mesh, c, visible_block(mesh, c, entry), local, k.posed);
    v.color = instance_vertex_color(inst, c.vertex_first + local, v.color);
    output.out_material = k.material;
    output.out_flags = k.flags;
    output.out_instance = entry.instance;
    output.out_normal = transform_normal(inst.world_inv, v.normal);
    output.out_tangent = instance_tangent(inst, v.tangent);
    output.out_color = (k.tinted ? v.color.rgb : float3(1.0)) * inst.tint.rgb;
    output.out_vertex_color = v.color;
    output.out_uv = v.uv;
    output.out_uv1 = v.uv1;
    gbuffer_vertex_place_now(output, vertex.world);
#else
    output.position = view_clip(vertex.world);
#ifdef MIRAI_CLIP_PLANE
    output.clip = dot(frame.clip_plane.xyz, vertex.world) + frame.clip_plane.w;
#endif
#endif
    output.out_first = instance_id;
    return output;
}
