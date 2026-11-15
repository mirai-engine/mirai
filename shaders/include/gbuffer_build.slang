// The vertex of a corner of a cluster of an instance as the G-buffer draws
// it: gbuffer.vert for the raster, vis_resolve.frag for the three corners of
// the triangle a pixel of the visibility buffer shows. One function, so both
// place it at the same bits. With MIRAI_BATCHES the vertex hook of the
// project (extension_vertex.slang) moves the instances of batches.
#ifndef MIRAI_GBUFFER_BUILD_SLANG
#define MIRAI_GBUFFER_BUILD_SLANG
#include "gbuffer_vertex.slang"

Gbuffer_Vertex gbuffer_vertex_build(uint index, Instance inst, Mesh mesh, Cluster c, uint corner) {
    Gbuffer_Vertex output = (Gbuffer_Vertex)0;
    uint material = material_of(inst, cluster_material(mesh, c));
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
    output.out_color = instance_color(inst, material_row(output.out_material), v.color.rgb);
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
#endif
