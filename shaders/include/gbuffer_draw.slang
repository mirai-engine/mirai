// A draw of the clusters of an instance of the scene (gbuffer.vert for glass,
// overlays and the highlight; translucent.vert for the forward blends),
// indexed by where the frame listed its mesh (render/mesh_draws.odin): the
// instance of the draw is that of the scene and the vertex its cluster
// << DRAW_VERTEX_BITS | the vertex in it. The highlight draws the clusters of
// level 0 (of a streamed mesh, all of them, and of those the finest the
// pools hold), the others all of them, and those out of the cut of the view
// are collapsed, as the cull leaves them out.
#ifndef MIRAI_GBUFFER_DRAW_SLANG
#define MIRAI_GBUFFER_DRAW_SLANG
#include "gbuffer_vertex.slang"
// The Surface program whose clusters a draw of an instance draws
// (render.instance_clusters_draw): 0 those without one, INVALID all of them.
// The highlight takes only the program of a blended material: the coverage of
// another is its mask map, which the stage without a program reads.
struct Draw_Block { uint program; uint pad0; uint pad1; uint pad2; };
[[vk::binding(SLOT_DRAW, 0)]] ConstantBuffer<Draw_Block> draw : register(MIRAI_REGISTER(b, SLOT_DRAW), space0);
#include "gbuffer_build.slang"

// highlight: the mask of the editor's highlight; blended: the blended
// triangles alone, the clusters of the other materials of the mesh collapsed.
Gbuffer_Vertex gbuffer_draw_vertex(uint vertex_id, uint index, bool highlight, bool blended) {
    Gbuffer_Vertex output = (Gbuffer_Vertex)0;
    Instance inst = scene_instance(index);
    Mesh mesh = meshes[instance_mesh(inst)];
    Cluster c = mesh_cluster(mesh, vertex_id >> DRAW_VERTEX_BITS);
    bool drawn = highlight ? cluster_finest_resident(mesh, c) : cluster_in_cut(view_detail(), inst, instance_scale(inst), mesh, c, frame.cut.x);
    Material m = materials[material_of(instance_row(index), inst, cluster_material(mesh, c))].shared;
    uint program = highlight && !material_blended(m) ? 0u : m.program_id;
    drawn = drawn && (draw.program == INVALID || program == draw.program) && (!blended || material_blended(m));
    if (!drawn) {
        // Outside the volume of the view: the triangle has no area to raster.
        output.position = float4(2.0, 2.0, 2.0, 1.0);
        return output;
    }
    // The highlight draws level 0 as it is.
    output = gbuffer_vertex_build(index, inst, mesh, c, vertex_id & ((1u << DRAW_VERTEX_BITS) - 1u), !highlight);
    // The list has the triangles of the mesh in its own order, which an instance that mirrors it turns.
    if (instance_mirrored(inst)) output.out_flags |= RASTER_FLAG_TURNED;
    return output;
}
#endif
