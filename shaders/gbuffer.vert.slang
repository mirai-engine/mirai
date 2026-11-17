#include "native.slang"
// highlight: the mask of the editor's highlight, drawn without the jitter of the view.
//! constant highlight MIRAI_EDITOR_HIGHLIGHT
// A cluster is an instance of a draw of CLUSTER_DRAW_VERTICES vertices: the
// corners of as many triangles as it may have, those past its own collapsed.
// The instance of the draw is that of the scene (glass, overlays, the
// highlight) and the vertex the cluster among those of its mesh times
// CLUSTER_DRAW_VERTICES: the highlight draws those of level 0 (of a streamed
// mesh, the finest the pools hold), the others all of them, and those out of
// the cut of the view are collapsed, as the cull leaves them out.
#include "gbuffer_vertex.slang"
// The Surface program whose clusters a draw of an instance draws
// (render.instance_clusters_draw): 0 those without one, INVALID all of them.
struct Draw_Block { uint program; uint pad0; uint pad1; uint pad2; };
[[vk::binding(SLOT_DRAW, 0)]] ConstantBuffer<Draw_Block> draw : register(MIRAI_REGISTER(b, SLOT_DRAW), space0);
#include "gbuffer_build.slang"
[shader("vertex")]
Gbuffer_Vertex main(uint vertex_id : SV_VulkanVertexID, uint instance_id : SV_VulkanInstanceID) {
    Gbuffer_Vertex output = (Gbuffer_Vertex)0;
    uint index = instance_id;
    Instance inst = scene_instance(index);
    Mesh mesh = meshes[instance_mesh(inst)];
    Cluster c = mesh_cluster(mesh, vertex_id / CLUSTER_DRAW_VERTICES);
    uint corner = vertex_id % CLUSTER_DRAW_VERTICES;
    bool drawn = corner < cluster_triangle_count(c) * 3u;
    if (MIRAI_EDITOR_HIGHLIGHT) drawn = drawn && cluster_finest_resident(mesh, c);
    else drawn = drawn && cluster_in_cut(view_detail(), inst, instance_scale(inst), mesh, c, frame.cut.x);
    drawn = drawn && (draw.program == INVALID || materials[material_of(inst, cluster_material(mesh, c))].shared.program_id == draw.program);
    if (!drawn) {
        // Outside the volume of the view: the triangle has no area to raster.
        output.position = float4(2.0, 2.0, 2.0, 1.0);
        return output;
    }
    // The highlight draws level 0 as it is.
    return gbuffer_vertex_build(index, inst, mesh, c, corner, !MIRAI_EDITOR_HIGHLIGHT);
}
