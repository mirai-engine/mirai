// The vertex of a corner of a cluster of an instance as the G-buffer draws
// it: gbuffer.vert for a draw of one instance, raster_vertices.comp for the
// vertices the raster of the visibility target draws, vis_resolve.frag for
// the three corners of the triangle a pixel of it shows. One function, so
// all place it at the same bits. With MIRAI_BATCHES the vertex hook of the
// project (extension_vertex.slang, included before) moves the instances of
// batches: its part of a whole instance is computed once for the cluster,
// its part of a vertex for each corner.
#ifndef MIRAI_GBUFFER_BUILD_SLANG
#define MIRAI_GBUFFER_BUILD_SLANG
#include "gbuffer_vertex.slang"
#include "cut.slang"

// The corner the resolve takes for corner `corner` of a triangle: an instance
// that mirrors its mesh would turn its winding around, so its triangles go
// the other way round and their front faces stay front.
uint gbuffer_corner(bool mirrored, uint corner) {
    uint k = corner % 3u;
    if (!mirrored || k == 0u) return corner;
    return k == 1u ? corner + 1u : corner - 1u;
}

// What a cluster of an instance gives each of its corners alike, built once
// for the three corners of a triangle: its material, whether the color of
// its vertices tints its row, the poses its vertices are read from, how far
// its islands are on their way to the next level (cluster_along), its flags,
// whether it is where it was in the frame before, whether its instance
// mirrors its mesh (instance_mirrored) and, of an instance of a batch, what
// the vertex hook moves it by.
struct Gbuffer_Cluster {
    uint material;
    bool tinted;
    bool mirrored;
    uint posed, previous; // INVALID: at rest
    float along;
    uint flags;
    bool still;
#if defined(MIRAI_BATCHES) && defined(MIRAI_HOOK_VERTEX)
    float3 pivot;         // of the instance, in the world
    float4 moved, before; // mirai_batch_instance now and in the frame before; zero: at rest
#endif
};

// Of the cluster of an instance of a mesh, with its material row and how far
// its islands are on their way to the next level.
Gbuffer_Cluster gbuffer_cluster_of(uint index, Instance inst, Mesh mesh, uint material, float along) {
    Gbuffer_Cluster k;
    k.material = material;
    // As instance_color: a program reads the color in its context.
    k.tinted = (inst.meta.w & INSTANCE_FLAG_UNIFORM_COLOR) == 0u && materials[k.material].shared.program_id == 0u;
    k.mirrored = instance_mirrored(inst);
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
    k.still = k.posed == INVALID && k.previous == INVALID
        && all(inst.world[0] == inst.prev_world[0]) && all(inst.world[1] == inst.prev_world[1]) && all(inst.world[2] == inst.prev_world[2]);
#if defined(MIRAI_BATCHES) && defined(MIRAI_HOOK_VERTEX)
    k.pivot = float3(inst.world[0].w, inst.world[1].w, inst.world[2].w);
    k.moved = float4(0.0);
    k.before = float4(0.0);
#endif
    return k;
}

#if defined(MIRAI_BATCHES) && defined(MIRAI_HOOK_VERTEX)
// What the vertex hook moves an instance by at a time: nothing of one of the scene.
float4 gbuffer_moved(uint index, Instance inst, float time) {
    if (!instance_batched(index)) return float4(0.0);
    return mirai_batch_instance(float3(inst.world[0].w, inst.world[1].w, inst.world[2].w), batch_vertex(batch_row(batch_of(index))), time);
}

void gbuffer_cluster_moved(inout Gbuffer_Cluster k, float4 moved, float4 before) {
    k.moved = moved;
    k.before = before;
    k.still = k.still && all(moved == before);
}
#endif

// cut: the draw takes the cut of the view, whose islands are on their way to
// the next level; else level 0 as it is.
Gbuffer_Cluster gbuffer_cluster(uint index, Instance inst, Mesh mesh, Cluster c, bool cut) {
    float along = cut ? cluster_along(view_detail(), inst, instance_scale(inst), mesh, c, frame.cut.x) : 0.0;
    return gbuffer_cluster_of(index, inst, mesh, material_of(instance_row(index), inst, cluster_material(mesh, c)), along);
}

// Where the vertex hook puts a point of the world of an instance now, or in the frame before.
float3 gbuffer_hooked(Gbuffer_Cluster k, float3 world, float4 color, bool now) {
#if defined(MIRAI_BATCHES) && defined(MIRAI_HOOK_VERTEX)
    float4 moved = now ? k.moved : k.before;
    if (any(moved != 0.0)) return mirai_batch_vertex(world, k.pivot, color, moved);
#endif
    return world;
}

// A corner of a cluster: its vertex in the space of its mesh with the colors
// of the instance, its place in the cluster, how far its island has moved,
// where it is in the world now and where it rests there, before the vertex
// hook moves it.
struct Gbuffer_Corner {
    Mesh_Point v;
    uint local;
    float3 offset;
    float3 world;
    float3 rest;
};

// The same of the vertex `local` of the cluster. b: where the streams of the
// cluster start (cluster_block).
Gbuffer_Corner gbuffer_local_place(Instance inst, Mesh mesh, Cluster c, Cluster_Block b, Gbuffer_Cluster k, uint local) {
    Gbuffer_Corner p;
    p.local = local;
    p.v = block_point_at(mesh, c, b, p.local, k.posed);
    p.v.color = instance_vertex_color(inst, c.vertex_first + p.local, p.v.color);
    p.offset = k.along != 0.0 ? block_island_offset(mesh, c, b, p.local, k.along) : float3(0.0);
    p.rest = transform_point(inst.world, p.v.position + p.offset);
    p.world = gbuffer_hooked(k, p.rest, p.v.color, true);
    return p;
}
Gbuffer_Corner gbuffer_corner_place(Instance inst, Mesh mesh, Cluster c, Cluster_Block b, Gbuffer_Cluster k, uint corner) {
    return gbuffer_local_place(inst, mesh, c, b, k, block_corner(b, gbuffer_corner(k.mirrored, corner)));
}

// Where the vertex hook puts a corner of an instance in the frame before, in
// the world: motion vectors see what the hook moves since then.
float3 gbuffer_corner_world_previous(Instance inst, Mesh mesh, Cluster c, Cluster_Block b, Gbuffer_Cluster k, Gbuffer_Corner p) {
    if (k.still) return p.world;
    float3 before = block_position_previous(mesh, c, b, p.local, k.previous) + p.offset;
    return gbuffer_hooked(k, transform_point(inst.prev_world, before), p.v.color, false);
}

Gbuffer_Vertex gbuffer_local_build(uint index, Instance inst, Mesh mesh, Cluster c, Cluster_Block b, Gbuffer_Cluster k, uint local) {
    Gbuffer_Vertex output = (Gbuffer_Vertex)0;
    Gbuffer_Corner p = gbuffer_local_place(inst, mesh, c, b, k, local);
    Mesh_Point v = p.v;
    output.out_normal = transform_normal(inst.world_inv, v.normal);
    output.out_tangent = instance_tangent(inst, k.mirrored, v.tangent);
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
#ifdef MIRAI_RASTER_STILL
    gbuffer_vertex_place_now(output, p.world);
#else
    gbuffer_vertex_place(output, p.world, gbuffer_corner_world_previous(inst, mesh, c, b, k, p));
#endif
    return output;
}

// The vertex `local` of a cluster of an instance, as a draw of the instance takes it.
Gbuffer_Vertex gbuffer_vertex_build(uint index, Instance inst, Mesh mesh, Cluster c, uint local, bool cut) {
    return gbuffer_local_build(index, inst, mesh, c, cluster_block(mesh, c), gbuffer_cluster(index, inst, mesh, c, cut), local);
}
#endif
