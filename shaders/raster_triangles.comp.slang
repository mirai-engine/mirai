#include "native.slang"
// The triangles a round of the raster of the visibility target draws
// (raster_lists.slang), a group a cluster: those of a cluster the round
// listed that show (raster_vertices.comp) take the next places of the range
// of its raster bin, or of its depth bucket in a tested one
// (raster_starts.comp), in the order the cluster has them. Each is the three
// places its corners have among the vertices written, and the word the
// visibility target names it by.
#include "visibility.slang"
#include "raster_lists.slang"
#define MIRAI_GROUP_X 64
#define MIRAI_GROUP_Y 1
#define MIRAI_GROUP_Z 1

struct Params_Block { uint round; uint pad0; uint pad1; uint pad2; };
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);
[[vk::binding(SLOT_PASS0, 0)]] RWStructuredBuffer<uint> cull_state : register(MIRAI_REGISTER(u, SLOT_PASS0), space0);
[[vk::binding(SLOT_PASS2, 0)]] StructuredBuffer<Visible_Cluster> visible : register(MIRAI_REGISTER(t, SLOT_PASS2), space0);
// Three indices a triangle, of the vertices written.
[[vk::binding(SLOT_PASS3, 0)]] RWStructuredBuffer<uint> raster_indices : register(MIRAI_REGISTER(u, SLOT_PASS3), space0);
[[vk::binding(SLOT_PASS4, 0)]] RWStructuredBuffer<uint> depth_buckets : register(MIRAI_REGISTER(u, SLOT_PASS4), space0);
[[vk::binding(SLOT_PASS5, 0)]] StructuredBuffer<uint> raster_entries : register(MIRAI_REGISTER(t, SLOT_PASS5), space0);
// The word of each triangle (visibility_id).
[[vk::binding(SLOT_PASS6, 0)]] RWStructuredBuffer<uint> raster_ids : register(MIRAI_REGISTER(u, SLOT_PASS6), space0);

#define TRIANGLE_TURNS (CLUSTER_TRIANGLES / MIRAI_GROUP_X)
#define USED_WORDS (CLUSTER_VERTICES / 32u)
#define SHOWN_WORDS (CLUSTER_TRIANGLES / 32u)

// Where the triangles of the cluster start among those listed.
groupshared uint first_triangle;

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 group : SV_GroupID, uint3 lane : SV_GroupThreadID) {
    uint g = raster_group(group);
    if (g >= cull_state[CULL_RASTER_COUNT]) return;
    uint e = cull_state[CULL_RASTER_FIRST] + g;
    uint record = e * RASTER_ENTRY_WORDS;
    uint listed_in = raster_entries[record + RASTER_ENTRY_ROUND];
    uint triangles = raster_entries[record + RASTER_ENTRY_TRIANGLES];
    if (!raster_round_is(listed_in, params.round) || triangles == 0u) return;
    if (lane.x == 0u) {
        uint listed = raster_entries[record + RASTER_ENTRY_BIN];
        uint bin = cull_listed_bin(listed);
        uint first;
        if ((bin & RASTER_BIN_TESTED) != 0u) {
            InterlockedAdd(depth_buckets[RASTER_DEPTH_STARTS + raster_depth_word(bin & RASTER_BIN_TWO_SIDED, cull_listed_bucket(listed))], triangles, first);
        } else {
            InterlockedAdd(cull_state[CULL_RASTER_CURSORS + bin], triangles, first);
        }
        first_triangle = first;
    }
    GroupMemoryBarrierWithGroupSync();

    uint first_vertex = raster_entries[record + RASTER_ENTRY_VERTICES];
    bool mirrored = raster_round_mirrored(listed_in);
    uint shown[SHOWN_WORDS], used[USED_WORDS];
    for (uint word = 0u; word < SHOWN_WORDS; word++) shown[word] = raster_entries[record + RASTER_ENTRY_SHOWN + word];
    for (uint word = 0u; word < USED_WORDS; word++) used[word] = raster_entries[record + RASTER_ENTRY_USED + word];
    Cluster_Block b = (Cluster_Block)0;
    b.triangles = visible[e].triangles;
    for (uint turn = 0u; turn < TRIANGLE_TURNS; turn++) {
        uint t = lane.x + turn * MIRAI_GROUP_X;
        if ((shown[t >> 5u] & (1u << (t & 31u))) == 0u) continue;
        uint place = first_triangle;
        for (uint word = 0u; word < SHOWN_WORDS; word++) place += countbits(raster_bits_before(shown[word], word, t));
        uint3 corners = block_triangle(b, t);
        if (mirrored) corners = corners.xzy;
        uint3 at = uint3(first_vertex);
        for (uint word = 0u; word < USED_WORDS; word++) {
            at += uint3(countbits(raster_bits_before(used[word], word, corners.x)), countbits(raster_bits_before(used[word], word, corners.y)), countbits(raster_bits_before(used[word], word, corners.z)));
        }
        raster_indices[place * 3u] = at.x;
        raster_indices[place * 3u + 1u] = at.y;
        raster_indices[place * 3u + 2u] = at.z;
        raster_ids[place] = visibility_id(e, t);
    }
}
