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
// its vertices tints its row, the poses its vertices are read from, how far
// its islands are on their way to the next level (cluster_along), its flags
// and, of an instance of a batch, what the vertex hook moves it by.
struct Gbuffer_Cluster {
    uint material;
    bool tinted;
    uint posed, previous; // INVALID: at rest
    float along;
    uint flags;
#if defined(MIRAI_BATCHES) && defined(MIRAI_HOOK_VERTEX)
    bool batched;
    float4 hook;  // batch_vertex of its batch
    float3 pivot; // of the instance, in the world
#endif
};

// Of the cluster of an instance of a mesh, with its material row and how far
// its islands are on their way to the next level.
Gbuffer_Cluster gbuffer_cluster_of(uint index, Instance inst, Mesh mesh, uint material, float along) {
    Gbuffer_Cluster k;
    k.material = material;
    // As instance_color: a program reads the color in its context.
    k.tinted = (inst.meta.w & INSTANCE_FLAG_UNIFORM_COLOR) == 0u && materials[k.material].shared.program_id == 0u;
    k.posed = mesh.posed_word;
    k.previous = mesh.previous_word;
    // The part of a skinned mesh the view does not draw is drawn collapsed.
    if (mesh.part_word != INVALID && !view_draws_layers(mesh.part_layers, inst.meta.w)) {
        k.posed = mesh.part_word;
        k.previous = mesh.part_word + mesh.vertex_count * POSED_WORDS;
    }
    k.along = along;
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

// cut: the draw takes the cut of the view, whose islands are on their way to
// the next level; else level 0 as it is.
Gbuffer_Cluster gbuffer_cluster(uint index, Instance inst, Mesh mesh, Cluster c, bool cut) {
    float along = cut ? cluster_along(view_detail(), inst, instance_scale(inst), mesh, c, frame.cut.x) : 0.0;
    return gbuffer_cluster_of(index, inst, mesh, material_of(inst, cluster_material(mesh, c)), along);
}

// Where the vertex hook puts a point of the world of an instance at a time.
float3 gbuffer_hooked(Gbuffer_Cluster k, float3 world, float4 color, float time) {
#if defined(MIRAI_BATCHES) && defined(MIRAI_HOOK_VERTEX)
    if (k.batched) return mirai_batch_vertex(world, k.pivot, color, k.hook, time);
#endif
    return world;
}

// A corner of a cluster: its vertex in the space of its mesh with the colors
// of the instance, its place in the cluster, how far its island has moved and
// where it is in the world now.
struct Gbuffer_Corner {
    Mesh_Point v;
    uint local;
    float3 offset;
    float3 world;
};

// b: where the streams of the cluster start (cluster_block).
Gbuffer_Corner gbuffer_corner_place(Instance inst, Mesh mesh, Cluster c, Cluster_Block b, Gbuffer_Cluster k, uint corner) {
    Gbuffer_Corner p;
    p.local = block_corner(b, gbuffer_corner(inst, corner));
    p.v = block_point_at(mesh, c, b, p.local, k.posed);
    p.v.color = instance_vertex_color(inst, c.vertex_first + p.local, p.v.color);
    p.offset = k.along != 0.0 ? block_island_offset(mesh, c, b, p.local, k.along) : float3(0.0);
    p.world = gbuffer_hooked(k, transform_point(inst.world, p.v.position + p.offset), p.v.color, frame.time.x);
    return p;
}

// Where the vertex hook puts a corner of an instance in the frame before, in
// the world: motion vectors see what the hook moves since then.
float3 gbuffer_corner_world_previous(Instance inst, Mesh mesh, Cluster c, Cluster_Block b, Gbuffer_Cluster k, Gbuffer_Corner p) {
    float3 before = block_position_previous(mesh, c, b, p.local, k.previous) + p.offset;
    return gbuffer_hooked(k, transform_point(inst.prev_world, before), p.v.color, frame.time.y);
}

Gbuffer_Vertex gbuffer_corner_build(uint index, Instance inst, Mesh mesh, Cluster c, Cluster_Block b, Gbuffer_Cluster k, uint corner) {
    Gbuffer_Vertex output = (Gbuffer_Vertex)0;
    Gbuffer_Corner p = gbuffer_corner_place(inst, mesh, c, b, k, corner);
    Mesh_Point v = p.v;
    float3 world = p.world;
#ifdef MIRAI_VISIBILITY
    // The raster of the visibility target: where the corner is now, and of a
    // tested one what its fade and its alpha read; not where it was, nor its
    // light, which the resolve builds.
    output.out_material = k.material;
    output.out_flags = k.flags;
    output.out_instance = index;
#ifdef MIRAI_VISIBILITY_TESTED
    output.out_normal = transform_normal(inst.world_inv, v.normal);
    output.out_tangent = instance_tangent(inst, v.tangent);
    output.out_color = (k.tinted ? v.color.rgb : float3(1.0)) * inst.tint.rgb;
    output.out_vertex_color = v.color;
    output.out_uv = v.uv;
    output.out_uv1 = v.uv1;
#endif
    gbuffer_vertex_place_now(output, world);
    return output;
#else
    float3 prev_world = gbuffer_corner_world_previous(inst, mesh, c, b, k, p);
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
#endif
}

Gbuffer_Vertex gbuffer_vertex_build(uint index, Instance inst, Mesh mesh, Cluster c, uint corner, bool cut) {
    return gbuffer_corner_build(index, inst, mesh, c, cluster_block(mesh, c), gbuffer_cluster(index, inst, mesh, c, cut), corner);
}
#endif
