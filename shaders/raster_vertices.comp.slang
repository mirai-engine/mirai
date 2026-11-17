#include "native.slang"
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
// after it, and counts what it leaves out.
#define MIRAI_BATCHES
#include "gbuffer_vertex.slang"
#include "visibility.slang"
#include "raster_lists.slang"
#include "cull_stats.slang"
#define MIRAI_GROUP_X 64
#define MIRAI_GROUP_Y 1
#define MIRAI_GROUP_Z 1

// last: no round follows this one; margin: how far a device may move a
// corner as it places it on its grid, in pixels (raster_triangle_shows).
struct Params_Block {
    uint round; uint last; uint vertex_capacity; uint triangle_capacity;
    float margin; uint pad0; uint pad1; uint pad2;
};
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);
[[vk::binding(SLOT_PASS0, 0)]] RWStructuredBuffer<uint> cull_state : register(MIRAI_REGISTER(u, SLOT_PASS0), space0);
[[vk::binding(SLOT_PASS1, 0)]] RWStructuredBuffer<Stats_Block> stats : register(MIRAI_REGISTER(u, SLOT_PASS1), space0);
[[vk::binding(SLOT_PASS2, 0)]] StructuredBuffer<Visible_Cluster> visible : register(MIRAI_REGISTER(t, SLOT_PASS2), space0);
[[vk::binding(SLOT_PASS3, 0)]] RWStructuredBuffer<Raster_Vertex> raster_vertices : register(MIRAI_REGISTER(u, SLOT_PASS3), space0);
// Of each tested bin, the triangles of each depth bucket (raster_depth_word).
[[vk::binding(SLOT_PASS4, 0)]] RWStructuredBuffer<uint> depth_buckets : register(MIRAI_REGISTER(u, SLOT_PASS4), space0);
[[vk::binding(SLOT_PASS5, 0)]] RWStructuredBuffer<uint> raster_entries : register(MIRAI_REGISTER(u, SLOT_PASS5), space0);
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

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 group : SV_GroupID, uint3 lane : SV_GroupThreadID) {
    uint g = raster_group(group);
    if (g >= cull_state[CULL_RASTER_COUNT]) return;
    uint e = cull_state[CULL_RASTER_FIRST] + g;
    uint record = e * RASTER_ENTRY_WORDS;
    if (!raster_round_pending(raster_entries[record + RASTER_ENTRY_ROUND])) return;
    Visible_Cluster entry = visible[e];
    Instance inst = scene_instance(entry.instance);
    Mesh mesh = meshes[instance_mesh(inst)];
    Cluster c = cluster_at(entry.cluster);
    Cluster_Block b = visible_block(mesh, c, entry);
    Gbuffer_Cluster k = gbuffer_cluster_of(entry.instance, inst, mesh, entry.material, entry.along);
    uint vertex_count = cluster_vertex_count(c), triangle_count = cluster_triangle_count(c);
    uint bin = cull_listed_bin(raster_entries[record + RASTER_ENTRY_BIN]);
    bool mirrored = instance_mirrored(inst);

    float3 worlds[VERTEX_TURNS];
    for (uint turn = 0u; turn < VERTEX_TURNS; turn++) {
        uint local = lane.x + turn * MIRAI_GROUP_X;
        worlds[turn] = float3(0.0);
        if (local >= vertex_count) continue;
        worlds[turn] = gbuffer_local_place(inst, mesh, c, b, k, local).world;
        clips[local] = view_clip(worlds[turn]);
    }
    if (lane.x < USED_WORDS) used[lane.x] = 0u;
    if (lane.x < SHOWN_WORDS) shown[lane.x] = 0u;
    GroupMemoryBarrierWithGroupSync();

    for (uint turn = 0u; turn < TRIANGLE_TURNS; turn++) {
        uint t = lane.x + turn * MIRAI_GROUP_X;
        if (t >= triangle_count) continue;
        uint3 corners = block_triangle(b, t);
        // An instance that mirrors its mesh draws its triangles the other way round (gbuffer_corner).
        if (mirrored) corners = corners.xzy;
        if (corners.x == corners.y || corners.y == corners.z || corners.x == corners.z) continue;
        if (!raster_triangle_shows(clips[corners.x], clips[corners.y], clips[corners.z], (bin & RASTER_BIN_TWO_SIDED) != 0u, frame.resolution, params.margin)) continue;
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
            if (listed) {
                InterlockedAdd(stats[0].raster[0], vertices);
                InterlockedAdd(stats[0].raster[1], triangles);
                InterlockedAdd(cull_state[CULL_RASTER_COUNTS + bin], triangles);
                if ((bin & RASTER_BIN_TESTED) != 0u) {
                    uint bucket = cull_listed_bucket(raster_entries[record + RASTER_ENTRY_BIN]);
                    InterlockedAdd(depth_buckets[raster_depth_word(bin & RASTER_BIN_TWO_SIDED, bucket)], triangles);
                }
            } else if (params.last == 0u) {
                InterlockedMin(cull_state[CULL_RASTER_PENDING], e);
                InterlockedMax(cull_state[CULL_RASTER_PENDING + 1u], e + 1u);
                InterlockedAdd(stats[0].raster[2], 1u);
            } else {
                if (!room) {
                    InterlockedAdd(cull_state[CULL_DROPPED + CULL_LIST_RASTER_VERTICES], vertices);
                    InterlockedAdd(stats[0].dropped[CULL_LIST_RASTER_VERTICES], vertices);
                }
                if (!room_triangles) {
                    InterlockedAdd(cull_state[CULL_DROPPED + CULL_LIST_RASTER_TRIANGLES], triangles);
                    InterlockedAdd(stats[0].dropped[CULL_LIST_RASTER_TRIANGLES], triangles);
                }
            }
        }
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
