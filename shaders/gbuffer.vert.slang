#include "native.slang"
// highlight: the mask of the editor's highlight, drawn without the jitter of the view.
//! constant highlight MIRAI_EDITOR_HIGHLIGHT
// batches: the G-buffer, which draws the visible clusters the cull listed,
// those of the instances of batches too; clip: the same for a view with a
// clip plane, which nothing is drawn behind; visibility: the raster of the
// visibility buffer (vis_raster.frag), which also gives each triangle its
// entry of the visible list.
//! variant batches MIRAI_BATCHES=1
//! variant clip MIRAI_CLIP_PLANE=1 MIRAI_BATCHES=1
//! variant visibility MIRAI_BATCHES=1 MIRAI_VISIBILITY=1
// A cluster is an instance of a draw of CLUSTER_DRAW_VERTICES vertices: the
// corners of as many triangles as it may have, those past its own collapsed.
// Drawn from the visible list (batches), the instance names an entry of it;
// drawn for one instance (glass, overlays, the highlight), the instance is
// that one and the vertex the cluster among those of its mesh times
// CLUSTER_DRAW_VERTICES: the highlight draws those of level 0 (of a streamed
// mesh, the finest the pools hold), the others all of them, and those out of
// the cut of the view are collapsed, as the cull leaves them out.
#include "gbuffer_vertex.slang"
#include "cut.slang"
#ifdef MIRAI_BATCHES
// The visible clusters of both phases (cull_clusters.comp), or those of a
// Surface program (cull_programs.comp): the instance, and the cluster as a
// word of the index pool.
[[vk::binding(SLOT_PASS0, 0)]] StructuredBuffer<uint2> visible : register(MIRAI_REGISTER(t, SLOT_PASS0), space0);
#include <extension_vertex.slang>
#else
// The Surface program whose clusters a draw of an instance draws
// (render.instance_clusters_draw): 0 those without one, INVALID all of them.
struct Draw_Block { uint program; uint pad0; uint pad1; uint pad2; };
[[vk::binding(SLOT_DRAW, 0)]] ConstantBuffer<Draw_Block> draw : register(MIRAI_REGISTER(b, SLOT_DRAW), space0);
#endif
#include "gbuffer_build.slang"
#ifdef MIRAI_VISIBILITY
#include "visibility.slang"
#endif
[shader("vertex")]
Gbuffer_Vertex main(uint vertex_id : SV_VulkanVertexID, uint instance_id : SV_VulkanInstanceID) {
#ifdef MIRAI_BATCHES
    uint2 entry = visible[instance_id];
    uint index = entry.x;
    Instance inst = scene_instance(index);
    Mesh mesh = meshes[instance_mesh(inst)];
    Cluster c = cluster_at(entry.y);
    uint corner = vertex_id;
#else
    uint index = instance_id;
    Instance inst = scene_instance(index);
    Mesh mesh = meshes[instance_mesh(inst)];
    Cluster c = mesh_cluster(mesh, vertex_id / CLUSTER_DRAW_VERTICES);
    uint corner = vertex_id % CLUSTER_DRAW_VERTICES;
#endif
    bool drawn = corner < cluster_triangle_count(c) * 3u;
#ifndef MIRAI_BATCHES
    if (MIRAI_EDITOR_HIGHLIGHT) drawn = drawn && cluster_finest_resident(mesh, c);
    else drawn = drawn && cluster_in_cut(view_detail(), inst, instance_scale(inst), mesh, c, frame.cut.x);
    drawn = drawn && (draw.program == INVALID || materials[material_of(inst, cluster_material(mesh, c))].shared.program_id == draw.program);
#endif
    if (!drawn) {
        // Outside the volume of the view: the triangle has no area to raster.
        Gbuffer_Vertex output = (Gbuffer_Vertex)0;
        output.position = float4(2.0, 2.0, 2.0, 1.0);
        return output;
    }
    Gbuffer_Vertex output = gbuffer_vertex_build(index, inst, mesh, c, corner);
#ifdef MIRAI_VISIBILITY
    output.out_entry = visibility_entry(instance_id, corner / 3u);
#endif
    return output;
}
