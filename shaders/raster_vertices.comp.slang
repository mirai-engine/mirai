#include "native.slang"
// shadow: of a round of the maps of the shadows, whose list holds the
// clusters their cull hands each page (shadow_clusters.comp).
//! variant shadow MIRAI_RASTER_SHADOW=1
// cost: counts by mesh and material too (cost.slang), in the frame of a
// request alone, of the view and of the maps.
//! variant cost MIRAI_COST=1
//! variant shadow_cost MIRAI_RASTER_SHADOW=1 MIRAI_COST=1
// The vertices a round of the raster of the visibility target draws
// (raster_lists.slang), a group a cluster of those the round takes that no
// round listed yet: each of its vertices is placed once, where
// gbuffer_build.slang puts it, with what its pose, its islands and the
// vertex hook of a batch move it by; each of its triangles is kept unless
// the raster would give it no pixel (raster_triangle_shows); the vertices
// those triangles use take the next places of the list, in the order the
// cluster has them, and the entry keeps where they start, which triangles
// show and which vertices they use for raster_triangles.comp. A cluster
// whose vertices or triangles find no room in their lists is left to the
// next round, which starts them again; the last round of a view has none
// after it, and counts what it leaves out. What the view would hold in one
// round, what its clusters write and what the last leaves out, is what the
// lists grow to (Stats_Block.raster_need). Of the maps, a cluster is placed
// as the maps draw it (at rest or as its pose has it, with its islands as
// the cut of its map sees them) for one page of a map, and a triangle kept
// where it covers a texel center of the part of the page the round draws,
// both faces; the round is the last of its cull, and a cluster it leaves out
// leaves its page to wait for the next frame (SHADOW_COST_OVER), and what
// the round would hold is what the lists grow to (Stats_Block.shadow_need).
#define MIRAI_BATCHES
#include "gbuffer_vertex.slang"
#include "visibility.slang"
#include "raster_lists.slang"
#include "cull_stats.slang"
#ifdef MIRAI_COST
#include "cost.slang"
#endif
#ifdef MIRAI_RASTER_SHADOW
#define SHADOW_PAGES_SLOT SLOT_PASS6
#define SHADOW_PAGES_WRITTEN
#include "shadow_cull.slang"
[[vk::binding(SLOT_PASS7, 0)]] StructuredBuffer<uint4> shadow_data : register(MIRAI_REGISTER(t, SLOT_PASS7), space0);
#endif
#define MIRAI_GROUP_X 64
#define MIRAI_GROUP_Y 1
#define MIRAI_GROUP_Z 1

// last: no round follows this one; margin: how far a device may move a
// corner as it places it on its grid, in pixels (raster_triangle_shows). Of
// the maps, those of shadow_cull.slang.
#ifndef MIRAI_RASTER_SHADOW
struct Params_Block {
    uint round; uint last; uint vertex_capacity; uint triangle_capacity;
    float margin; uint pad0; uint pad1; uint pad2;
};
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);
#endif
[[vk::binding(SLOT_PASS0, 0)]] RWStructuredBuffer<uint> cull_state : register(MIRAI_REGISTER(u, SLOT_PASS0), space0);
[[vk::binding(SLOT_PASS1, 0)]] RWStructuredBuffer<Stats_Block> stats : register(MIRAI_REGISTER(u, SLOT_PASS1), space0);
[[vk::binding(SLOT_PASS2, 0)]] StructuredBuffer<Visible_Cluster> visible : register(MIRAI_REGISTER(t, SLOT_PASS2), space0);
[[vk::binding(SLOT_PASS3, 0)]] RWStructuredBuffer<Raster_Vertex> raster_vertices : register(MIRAI_REGISTER(u, SLOT_PASS3), space0);
// Of each tested bin, the triangles of each depth bucket (raster_depth_word).
[[vk::binding(SLOT_PASS4, 0)]] RWStructuredBuffer<uint> depth_buckets : register(MIRAI_REGISTER(u, SLOT_PASS4), space0);
[[vk::binding(SLOT_PASS5, 0)]] RWStructuredBuffer<uint> raster_entries : register(MIRAI_REGISTER(u, SLOT_PASS5), space0);
#if defined(MIRAI_HOOK_VERTEX) && !defined(MIRAI_RASTER_SHADOW)
// Of the view, what the vertex hook moves the instance of each visible cluster by (cull_bins.comp).
[[vk::binding(SLOT_PASS6, 0)]] StructuredBuffer<float4> visible_moved : register(MIRAI_REGISTER(t, SLOT_PASS6), space0);
#endif
#include <extension_vertex.slang>
#include "gbuffer_build.slang"

#define VERTEX_TURNS (CLUSTER_VERTICES / MIRAI_GROUP_X)
#define TRIANGLE_TURNS (CLUSTER_TRIANGLES / MIRAI_GROUP_X)
#define USED_WORDS (CLUSTER_VERTICES / 32u)
#define SHOWN_WORDS (CLUSTER_TRIANGLES / 32u)

// Where the raster has each vertex of the cluster, in clip space.
groupshared float4 clips[CLUSTER_VERTICES];
// A bit a vertex a triangle that shows uses, and a bit a triangle that shows.
groupshared uint used[USED_WORDS];
groupshared uint shown[SHOWN_WORDS];
// Where the vertices of the cluster start in the list; INVALID: it is left out.
groupshared uint first_vertex;
// A list was full before the group began: the cluster goes to the next round as it is.
groupshared uint full;
#if defined(MIRAI_HOOK_VERTEX) && defined(MIRAI_RASTER_SHADOW)
// What the vertex hook moves the instance of the cluster by (gbuffer_moved).
groupshared float4 cluster_moved;
#endif

// What a cluster writes of each list, added to what the view, or the round
// of the maps, needs of them.
void raster_need(uint vertices, uint triangles) {
    uint before;
    InterlockedAdd(cull_state[CULL_RASTER_NEED], vertices, before);
#ifdef MIRAI_RASTER_SHADOW
    InterlockedMax(stats[0].shadow_need[0], before + vertices);
#else
    InterlockedMax(stats[0].raster_need[0], before + vertices);
#endif
    InterlockedAdd(cull_state[CULL_RASTER_NEED + 1u], triangles, before);
#ifdef MIRAI_RASTER_SHADOW
    InterlockedMax(stats[0].shadow_need[1], before + triangles);
#else
    InterlockedMax(stats[0].raster_need[1], before + triangles);
#endif
}

// A cluster that found no room in a list: the next round takes it, or, with
// none to follow, it is left out and what it lacked of each list is counted;
// of the maps, its page waits.
void cluster_left(uint e, uint vertices, uint triangles, uint pool) {
#ifdef MIRAI_RASTER_SHADOW
    InterlockedAdd(stats[0].shadow[9], 1u);
    if (pool < SHADOW_POOL_PAGES) InterlockedOr(shadow_pages[shadow_cost_word(pool)], SHADOW_COST_OVER);
#else
    if (params.last == 0u) {
        InterlockedMin(cull_state[CULL_RASTER_PENDING], e);
        InterlockedMax(cull_state[CULL_RASTER_PENDING + 1u], e + 1u);
        InterlockedAdd(stats[0].raster[2], 1u);
        return;
    }
    if (vertices != 0u) {
        InterlockedAdd(cull_state[CULL_DROPPED + CULL_LIST_RASTER_VERTICES], vertices);
        InterlockedAdd(stats[0].dropped[CULL_LIST_RASTER_VERTICES], vertices);
    }
    if (triangles != 0u) {
        InterlockedAdd(cull_state[CULL_DROPPED + CULL_LIST_RASTER_TRIANGLES], triangles);
        InterlockedAdd(stats[0].dropped[CULL_LIST_RASTER_TRIANGLES], triangles);
    }
#endif
}

#ifdef MIRAI_COST
// What the count of a request adds of a cluster as its round decides it: of
// the view, the cluster and its triangles once it is drawn or left out for
// good, and the triangles that show of one drawn; of the maps, the triangles
// of one drawn into its page, or one left out.
void raster_cost(Visible_Cluster entry, uint mesh, bool listed, uint shown, uint triangles) {
#ifdef MIRAI_RASTER_SHADOW
    if (listed) cost_add(mesh, entry.material, COST_SHADOW_TRIANGLES, shown);
    else cost_add(mesh, entry.material, COST_SHADOW_OVER, 1u);
#else
    if (!listed && params.last == 0u) return;
    cost_add(mesh, entry.material, COST_CLUSTERS, 1u);
    cost_add(mesh, entry.material, COST_TRIANGLES, triangles);
    if (listed) cost_add(mesh, entry.material, COST_RASTER_TRIANGLES, shown);
#endif
}
#endif

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 group : SV_GroupID, uint3 lane : SV_GroupThreadID) {
    uint g = raster_group(group);
    if (g >= cull_state[CULL_RASTER_COUNT]) return;
    uint e = cull_state[CULL_RASTER_FIRST] + g;
    uint record = e * RASTER_ENTRY_WORDS;
    if (!raster_round_pending(raster_entries[record + RASTER_ENTRY_ROUND])) return;
    Visible_Cluster entry = visible[e];
    Cluster c = cluster_at(entry.cluster);
    Instance inst = scene_instance(entry.instance);
#ifdef MIRAI_RASTER_SHADOW
    bool rest = (entry.program & SHADOW_ENTRY_REST) != 0u;
#endif
    // A list is full for good once it is passed: no vertex is placed for a
    // cluster it has no room for, which a round after takes. The last finds
    // what the cluster would write, which it counts.
    if (lane.x == 0u) {
        full = params.last == 0u && (cull_state[CULL_RASTER_VERTICES] >= params.vertex_capacity || cull_state[CULL_RASTER_TRIANGLES] >= params.triangle_capacity) ? 1u : 0u;
        if (full != 0u) cluster_left(e, 0u, 0u, INVALID);
#if defined(MIRAI_HOOK_VERTEX) && defined(MIRAI_RASTER_SHADOW)
        // The maps leave the vertex hook of a batch out, but where they draw
        // one that sways as it sways.
        bool hooked = full == 0u && !rest && instance_batched(entry.instance) && batch_sway(batch_row(batch_of(entry.instance))) > 0.0;
        cluster_moved = hooked ? gbuffer_moved(entry.instance, inst, frame.time.x) : float4(0.0);
#endif
    }
    GroupMemoryBarrierWithGroupSync();
    if (full != 0u) return;
    Mesh mesh = meshes[instance_mesh(inst)];
    Cluster_Block b = visible_block(mesh, c, entry);
    uint vertex_count = cluster_vertex_count(c), triangle_count = cluster_triangle_count(c);
    uint bin = cull_listed_bin(raster_entries[record + RASTER_ENTRY_BIN]);
    // What mirrors its mesh, or a view that mirrors the world, turns its winding around.
    bool mirrored = instance_mirrored(inst) != view_mirrored();
#ifdef MIRAI_RASTER_SHADOW
    // Where the page lies in the pool and the part of it the round draws;
    // a page with no place in the pool draws nothing.
    Shadow_Page_Draw page;
    if (!shadow_page_draw(shadow_data, entry.program & ~SHADOW_ENTRY_REST, page)) triangle_count = 0u;
    // The tile of the page in the layer of what sways, its texels as many times fewer.
    float scale = (entry.program & SHADOW_ENTRY_LAYER) != 0u ? float(1u << params.coarser) : 1.0;
    float4 window = page.window / scale;
    float2 resolution = float2(SHADOW_POOL, frame.sun_maps.z) / scale;
    uint pool = page.pool;
    // The maps draw both faces of every triangle.
    bool two_sided = true;
    Gbuffer_Cluster k = (Gbuffer_Cluster)0;
    k.posed = rest ? INVALID : mesh.posed_word;
    k.along = entry.along;
#ifdef MIRAI_HOOK_VERTEX
    k.pivot = float3(inst.world[0].w, inst.world[1].w, inst.world[2].w);
    k.moved = cluster_moved;
#endif
#else
    float4 window = float4(0.0, 0.0, frame.resolution);
    float2 resolution = frame.resolution;
    uint pool = INVALID;
    bool two_sided = (bin & RASTER_BIN_TWO_SIDED) != 0u;
    Gbuffer_Cluster k = gbuffer_cluster_of(entry.instance, inst, mesh, entry.material, entry.along);
#ifdef MIRAI_HOOK_VERTEX
    if (instance_batched(entry.instance)) k.moved = visible_moved[e * 2u];
#endif
#endif

    float3 worlds[VERTEX_TURNS];
    for (uint turn = 0u; turn < VERTEX_TURNS; turn++) {
        uint local = lane.x + turn * MIRAI_GROUP_X;
        worlds[turn] = float3(0.0);
        if (local >= vertex_count) continue;
        worlds[turn] = gbuffer_local_place(inst, mesh, c, b, k, local).world;
#ifdef MIRAI_RASTER_SHADOW
        float4 inside;
        clips[local] = shadow_page_clip(page, worlds[turn], inside);
#else
        clips[local] = view_clip(worlds[turn]);
#endif
    }
    if (lane.x < USED_WORDS) used[lane.x] = 0u;
    if (lane.x < SHOWN_WORDS) shown[lane.x] = 0u;
    GroupMemoryBarrierWithGroupSync();

    for (uint turn = 0u; turn < TRIANGLE_TURNS; turn++) {
        uint t = lane.x + turn * MIRAI_GROUP_X;
        if (t >= triangle_count) continue;
        uint3 corners = block_triangle(b, t);
        // Those draw their triangles the other way round, so that their front faces stay front.
        if (mirrored) corners = corners.xzy;
        if (corners.x == corners.y || corners.y == corners.z || corners.x == corners.z) continue;
        if (!raster_triangle_shows(clips[corners.x], clips[corners.y], clips[corners.z], two_sided, window, resolution, params.margin)) continue;
        InterlockedOr(shown[t >> 5u], 1u << (t & 31u));
        InterlockedOr(used[corners.x >> 5u], 1u << (corners.x & 31u));
        InterlockedOr(used[corners.y >> 5u], 1u << (corners.y & 31u));
        InterlockedOr(used[corners.z >> 5u], 1u << (corners.z & 31u));
    }
    GroupMemoryBarrierWithGroupSync();

    if (lane.x == 0u) {
        uint vertices = 0u, triangles = 0u;
        for (uint word = 0u; word < USED_WORDS; word++) vertices += countbits(used[word]);
        for (uint word = 0u; word < SHOWN_WORDS; word++) triangles += countbits(shown[word]);
        uint first = 0u, before = 0u;
        bool listed = true;
        if (triangles != 0u) {
            InterlockedAdd(cull_state[CULL_RASTER_VERTICES], vertices, first);
            InterlockedAdd(cull_state[CULL_RASTER_TRIANGLES], triangles, before);
            bool room = first + vertices <= params.vertex_capacity, room_triangles = before + triangles <= params.triangle_capacity;
            listed = room && room_triangles;
            if (listed || params.last != 0u) raster_need(vertices, triangles);
            if (listed) {
#ifdef MIRAI_RASTER_SHADOW
                InterlockedAdd(stats[0].shadow[13], vertices);
                InterlockedAdd(stats[0].shadow[14], triangles);
#else
                InterlockedAdd(stats[0].raster[0], vertices);
                InterlockedAdd(stats[0].raster[1], triangles);
#endif
                InterlockedAdd(cull_state[CULL_RASTER_COUNTS + bin], triangles);
                if ((bin & RASTER_BIN_TESTED) != 0u) {
                    uint bucket = cull_listed_bucket(raster_entries[record + RASTER_ENTRY_BIN]);
                    InterlockedAdd(depth_buckets[raster_depth_word(bin & RASTER_BIN_TWO_SIDED, bucket)], triangles);
                }
            } else {
                cluster_left(e, room ? 0u : vertices, room_triangles ? 0u : triangles, pool);
            }
        }
#ifdef MIRAI_COST
        raster_cost(entry, instance_mesh(inst), listed, triangles, triangle_count);
#endif
        first_vertex = listed && triangles != 0u ? first : INVALID;
        if (listed) {
            raster_entries[record + RASTER_ENTRY_VERTICES] = first;
            raster_entries[record + RASTER_ENTRY_TRIANGLES] = triangles;
            raster_entries[record + RASTER_ENTRY_ROUND] = raster_round_word(params.round, mirrored);
            for (uint word = 0u; word < SHOWN_WORDS; word++) raster_entries[record + RASTER_ENTRY_SHOWN + word] = shown[word];
            for (uint word = 0u; word < USED_WORDS; word++) raster_entries[record + RASTER_ENTRY_USED + word] = used[word];
        }
    }
    GroupMemoryBarrierWithGroupSync();

    if (first_vertex == INVALID) return;
    for (uint turn = 0u; turn < VERTEX_TURNS; turn++) {
        uint local = lane.x + turn * MIRAI_GROUP_X;
        if (local >= vertex_count || (used[local >> 5u] & (1u << (local & 31u))) == 0u) continue;
        uint place = first_vertex;
        for (uint word = 0u; word < USED_WORDS; word++) place += countbits(raster_bits_before(used[word], word, local));
        Raster_Vertex v;
        v.world = worlds[turn];
        v.source = raster_source(e, local);
        raster_vertices[place] = v;
    }
}
