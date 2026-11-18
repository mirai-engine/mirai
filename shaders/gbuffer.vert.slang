#include "native.slang"
// highlight: the mask of the editor's highlight, drawn without the jitter of the view.
//! constant highlight MIRAI_EDITOR_HIGHLIGHT
// A draw of the clusters of an instance of the scene (glass, overlays, the
// highlight), indexed by where the frame listed its mesh (render/mesh_draws.odin):
// the instance of the draw is that of the scene and the vertex its cluster
// << DRAW_VERTEX_BITS | the vertex in it. The highlight draws the clusters of
// level 0 (of a streamed mesh, all of them, and of those the finest the
// pools hold), the others all of them, and those out of the cut of the view
// are collapsed, as the cull leaves them out.
#include "gbuffer_vertex.slang"
// The Surface program whose clusters a draw of an instance draws
// (render.instance_clusters_draw): 0 those without one, INVALID all of them.
// The highlight takes only the program of a blended material: the coverage of
// another is its mask map, which the stage without a program reads.
struct Draw_Block { uint program; uint pad0; uint pad1; uint pad2; };
[[vk::binding(SLOT_DRAW, 0)]] ConstantBuffer<Draw_Block> draw : register(MIRAI_REGISTER(b, SLOT_DRAW), space0);
#include "gbuffer_build.slang"
[shader("vertex")]
Gbuffer_Vertex main(uint vertex_id : SV_VulkanVertexID, uint instance_id : SV_VulkanInstanceID) {
    Gbuffer_Vertex output = (Gbuffer_Vertex)0;
    uint index = instance_id;
    Instance inst = scene_instance(index);
    Mesh mesh = meshes[instance_mesh(inst)];
    Cluster c = mesh_cluster(mesh, vertex_id >> DRAW_VERTEX_BITS);
    bool drawn = MIRAI_EDITOR_HIGHLIGHT ? cluster_finest_resident(mesh, c) : cluster_in_cut(view_detail(), inst, instance_scale(inst), mesh, c, frame.cut.x);
    Material m = materials[material_of(inst, cluster_material(mesh, c))].shared;
    uint program = MIRAI_EDITOR_HIGHLIGHT && m.alpha_mode != ALPHA_BLEND ? 0u : m.program_id;
    drawn = drawn && (draw.program == INVALID || program == draw.program);
    if (!drawn) {
        // Outside the volume of the view: the triangle has no area to raster.
        output.position = float4(2.0, 2.0, 2.0, 1.0);
        return output;
    }
    // The highlight draws level 0 as it is.
    output = gbuffer_vertex_build(index, inst, mesh, c, vertex_id & ((1u << DRAW_VERTEX_BITS) - 1u), !MIRAI_EDITOR_HIGHLIGHT);
    // The list has the triangles of the mesh in its own order, which an instance that mirrors it turns.
    if (instance_mirrored(inst)) output.out_flags |= RASTER_FLAG_TURNED;
    return output;
}
