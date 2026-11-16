// The vertex of a corner of a cluster of an instance as the G-buffer draws
// it: gbuffer.vert for the raster, vis_resolve.frag for the three corners of
// the triangle a pixel of the visibility target shows. One function, so both
// place it at the same bits. With MIRAI_BATCHES the vertex hook of the
// project (extension_vertex.slang, included before) moves the instances of
// batches.
#ifndef MIRAI_GBUFFER_BUILD_SLANG
#define MIRAI_GBUFFER_BUILD_SLANG
#include "gbuffer_vertex.slang"
#include "cut.slang"

// The corner a draw of a cluster takes for its vertex `corner`: an instance
// that mirrors its mesh would turn its winding around, so its triangles go
// the other way round and their front faces stay front.
uint gbuffer_corner(Instance inst, uint corner) {
    uint k = corner % 3u;
    if (!instance_mirrored(inst) || k == 0u) return corner;
    return k == 1u ? corner + 1u : corner - 1u;
}

// What a cluster of an instance gives each of its corners alike, built once
// for the three corners of a triangle: its material, whether the color of
// its vertices tints its row, the poses its vertices are read from, its flags
// and, of an instance of a batch, what the vertex hook moves it by.
struct Gbuffer_Cluster {
    uint material;
    bool tinted;
    uint posed, previous; // INVALID: at rest
    uint flags;
#if defined(MIRAI_BATCHES) && defined(MIRAI_HOOK_VERTEX)
    bool batched;
    float4 hook;  // batch_vertex of its batch
    float3 pivot; // of the instance, in the world
#endif
};

Gbuffer_Cluster gbuffer_cluster(uint index, Instance inst, Mesh mesh, Cluster c) {
    Gbuffer_Cluster k;
    k.material = material_of(inst, cluster_material(mesh, c));
    // As instance_color: a program reads the color in its context.
    k.tinted = (inst.meta.w & INSTANCE_FLAG_UNIFORM_COLOR) == 0u && materials[k.material].shared.program_id == 0u;
    k.posed = mesh.posed_word;
    k.previous = mesh.previous_word;
    // The part of a skinned mesh the view does not draw is drawn collapsed.
    if (mesh.part_word != INVALID && !view_draws_layers(mesh.part_layers, inst.meta.w)) {
        k.posed = mesh.part_word;
        k.previous = mesh.part_word + mesh.vertex_count * POSED_WORDS;
    }
    float fade = instance_fade(index, inst);
    k.flags = ((inst.meta.w >> INSTANCE_HIGHLIGHT_SHIFT) & RASTER_HIGHLIGHT_MASK)
        | (fade > 0.0 ? RASTER_FLAG_FADING | (uint(saturate(fade) * 65535.0 + 0.5) << RASTER_FADE_SHIFT) : 0u);
#if defined(MIRAI_BATCHES) && defined(MIRAI_HOOK_VERTEX)
    k.batched = instance_batched(index);
    k.hook = k.batched ? batch_vertex(batch_row(batch_of(index))) : float4(0.0);
    k.pivot = float3(inst.world[0].w, inst.world[1].w, inst.world[2].w);
#endif
    return k;
}

// Where the vertex hook puts a point of the world of an instance at a time.
float3 gbuffer_hooked(Gbuffer_Cluster k, float3 world, float4 color, float time) {
#if defined(MIRAI_BATCHES) && defined(MIRAI_HOOK_VERTEX)
    if (k.batched) return mirai_batch_vertex(world, k.pivot, color, k.hook, time);
#endif
    return world;
}

Gbuffer_Vertex gbuffer_corner_build(uint index, Instance inst, Mesh mesh, Cluster c, Gbuffer_Cluster k, uint corner) {
    Gbuffer_Vertex output = (Gbuffer_Vertex)0;
    uint local = cluster_corner(mesh, c, gbuffer_corner(inst, corner));
    Mesh_Point v = cluster_point_at(mesh, c, local, k.posed);
    v.color = instance_vertex_color(inst, c.vertex_first + local, v.color);
    // Motion vectors see what the hook moves since the previous frame.
    float3 world = gbuffer_hooked(k, transform_point(inst.world, v.position), v.color, frame.time.x);
    float3 prev_world = gbuffer_hooked(k, transform_point(inst.prev_world, cluster_position_previous(mesh, c, local, k.previous)), v.color, frame.time.y);
    output.out_normal = transform_normal(inst.world_inv, v.normal);
    output.out_tangent = instance_tangent(inst, v.tangent);
    output.out_material = k.material;
    output.out_color = (k.tinted ? v.color.rgb : float3(1.0)) * inst.tint.rgb;
    output.out_vertex_color = v.color;
    // A far mesh: its emission joins that of the instance, and its roughness
    // and metallic replace those of its material.
    output.out_emission = inst.emission.rgb + ((v.surface.x & MESH_SURFACE_SET) != 0u ? surface_emission(v.surface.y) : float3(0.0));
    output.out_surface = v.surface.x;
    output.out_flags = k.flags;
    output.out_instance = index;
    output.out_uv = v.uv;
    output.out_uv1 = v.uv1;
    gbuffer_vertex_place(output, world, prev_world);
    return output;
}

Gbuffer_Vertex gbuffer_vertex_build(uint index, Instance inst, Mesh mesh, Cluster c, uint corner) {
    return gbuffer_corner_build(index, inst, mesh, c, gbuffer_cluster(index, inst, mesh, c), corner);
}
#endif
