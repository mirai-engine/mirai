#include "native.slang"
// highlight: the mask of the editor's highlight, drawn without the jitter of the view.
//! constant highlight MIRAI_EDITOR_HIGHLIGHT
// batches: the G-buffer, which draws the visible clusters the cull listed,
// those of the instances of batches too; clip: the same for a view with a
// clip plane, which nothing is drawn behind.
//! variant batches MIRAI_BATCHES=1
//! variant clip MIRAI_CLIP_PLANE=1 MIRAI_BATCHES=1
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
[shader("vertex")]
Gbuffer_Vertex main(uint vertex_id : SV_VulkanVertexID, uint instance_id : SV_VulkanInstanceID) {
    Gbuffer_Vertex output = (Gbuffer_Vertex)0;
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
    uint material = material_of(inst, cluster_material(mesh, c));
    bool drawn = corner < cluster_triangle_count(c) * 3u;
#ifndef MIRAI_BATCHES
    if (MIRAI_EDITOR_HIGHLIGHT) drawn = drawn && cluster_finest_resident(mesh, c);
    else drawn = drawn && cluster_in_cut(inst, instance_scale(inst), mesh, c, frame.cut.x);
    drawn = drawn && (draw.program == INVALID || materials[material].shared.program_id == draw.program);
#endif
    if (!drawn) {
        // Outside the volume of the view: the triangle has no area to raster.
        output.position = float4(2.0, 2.0, 2.0, 1.0);
        return output;
    }
    uint local = cluster_corner(mesh, c, corner);
    uint posed = mesh.posed_word, previous = mesh.previous_word;
    // The part of a skinned mesh the view does not draw is drawn collapsed.
    if (mesh.part_word != INVALID && !view_draws_layers(mesh.part_layers, inst.meta.w)) {
        posed = mesh.part_word;
        previous = mesh.part_word + mesh.vertex_count * POSED_WORDS;
    }
    Mesh_Point v = cluster_point_at(mesh, c, local, posed);
    v.color = instance_vertex_color(inst, c.vertex_first + local, v.color);
    float3 world = transform_point(inst.world, v.position);
    float3 prev_world = transform_point(inst.prev_world, cluster_position_previous(mesh, c, local, previous));
    float fade = view_body_fade(inst.meta.w);
#ifdef MIRAI_BATCHES
    if (instance_batched(index)) {
        Instance row = batch_row(batch_of(index));
        fade = max(fade, batch_faded(row, inst.bounds_min.xyz, inst.bounds_max.xyz));
#ifdef MIRAI_HOOK_VERTEX
        // Motion vectors see what the hook moves since the previous frame.
        float3 pivot = float3(inst.world[0].w, inst.world[1].w, inst.world[2].w);
        world = mirai_batch_vertex(world, pivot, v.color, batch_vertex(row), frame.time.x);
        prev_world = mirai_batch_vertex(prev_world, pivot, v.color, batch_vertex(row), frame.time.y);
#endif
    }
#endif
    output.out_normal = transform_normal(inst.world_inv, v.normal);
    output.out_tangent = instance_tangent(inst, v.tangent);
    output.out_material = material;
    output.out_color = instance_color(inst, material_row(output.out_material, inst.material_values), v.color.rgb);
    output.out_vertex_color = v.color;
    // A far mesh: its emission joins that of the instance, and its roughness
    // and metallic replace those of its material.
    output.out_emission = inst.emission.rgb + ((v.surface.x & MESH_SURFACE_SET) != 0u ? surface_emission(v.surface.y) : float3(0.0));
    output.out_surface = v.surface.x;
    output.out_flags = ((inst.meta.w >> INSTANCE_HIGHLIGHT_SHIFT) & RASTER_HIGHLIGHT_MASK) | (instance_mirrored(inst) ? RASTER_FLAG_MIRRORED : 0u)
        | (fade > 0.0 ? RASTER_FLAG_FADING | (uint(saturate(fade) * 65535.0 + 0.5) << RASTER_FADE_SHIFT) : 0u);
    output.out_instance = index;
    output.out_uv = v.uv;
    output.out_uv1 = v.uv1;
    gbuffer_vertex_place(output, world, prev_world);
    return output;
}
