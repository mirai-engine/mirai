#include "native.slang"
// The visible clusters of a view by raster bin, by mode: 0 starts the cull of
// the view with the draw of the resolve of each Surface program empty (but
// that of the materials without one), a thread per program; 2, after the
// cull of a phase (cull_clusters.comp), turns the counts of the depth
// buckets of its tested bins into the places their clusters start at, in one
// wave; 1 then places each cluster it listed in the range of its bin of the
// visible list, those of phase 1 after those of phase 0, a tested one in the
// range of its depth bucket so its bin draws nearest first, and gives each
// bin of the phase its draw, an instance a cluster.
#include "scene.slang"
#include "cull_bins.slang"
#define MIRAI_GROUP_X CULL_BINS_GROUP
#define MIRAI_GROUP_Y 1
#define MIRAI_GROUP_Z 1

// programs: the largest program id, plus one. capacity: of the visible list, both phases together.
struct Params_Block { uint mode; uint phase; uint programs; uint capacity; };
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);
[[vk::binding(SLOT_PASS0, 0)]] RWStructuredBuffer<uint> cull_state : register(MIRAI_REGISTER(u, SLOT_PASS0), space0);
// The clusters as the cull listed them: the instance, the cluster as a word
// of the index pool, its bin and depth bucket (cull_listed_bin) and its
// Surface program.
[[vk::binding(SLOT_PASS1, 0)]] StructuredBuffer<uint4> listed : register(MIRAI_REGISTER(t, SLOT_PASS1), space0);
// The same by bin: the instance, the cluster and the program.
[[vk::binding(SLOT_PASS2, 0)]] RWStructuredBuffer<uint4> visible : register(MIRAI_REGISTER(u, SLOT_PASS2), space0);
// The draws of the resolve of each Surface program (render.Gpu_Draw): three
// vertices, and the program as its first instance (vis_resolve.vert).
[[vk::binding(SLOT_PASS3, 0)]] RWStructuredBuffer<uint> program_draws : register(MIRAI_REGISTER(u, SLOT_PASS3), space0);
// Of each phase and tested bin, the clusters of each depth bucket, then where they start (cull_depth_word).
[[vk::binding(SLOT_PASS4, 0)]] RWStructuredBuffer<uint> depth_buckets : register(MIRAI_REGISTER(u, SLOT_PASS4), space0);

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 dispatch_id : SV_DispatchThreadID) {
    uint i = dispatch_id.x;
    if (params.mode == 0u) {
        if (i < params.programs) {
            program_draws[i * 4u] = 3u;
            program_draws[i * 4u + 1u] = i == 0u ? 1u : 0u;
            program_draws[i * 4u + 2u] = 0u;
            program_draws[i * 4u + 3u] = i;
        }
        return;
    }
    uint phase = params.phase;
    uint base = phase == 0u ? 0u : min(cull_state[CULL_LISTED], params.capacity);
    uint count = min(cull_state[CULL_LISTED + phase], params.capacity - base);
    uint offsets[RASTER_BINS];
    uint running = base;
    for (uint bin = 0u; bin < RASTER_BINS; bin++) {
        offsets[bin] = running;
        running += cull_state[CULL_BIN_COUNTS + phase * RASTER_BINS + bin];
    }
    if (params.mode == 2u) {
        // The first wave of the group alone: it runs over the buckets of a
        // bin a wave at a time, each starting where those before end.
        if (i >= WaveGetLaneCount()) return;
        for (uint sided = 0u; sided < 2u; sided++) {
            uint start = offsets[RASTER_BIN_TESTED | sided];
            for (uint first = 0u; first < RASTER_DEPTH_BUCKETS; first += WaveGetLaneCount()) {
                uint bucket = first + i;
                uint word = cull_depth_word(phase, sided, min(bucket, RASTER_DEPTH_BUCKETS - 1u));
                uint clusters = bucket < RASTER_DEPTH_BUCKETS ? depth_buckets[word] : 0u;
                uint place = start + WavePrefixSum(clusters);
                start += WaveActiveSum(clusters);
                if (bucket < RASTER_DEPTH_BUCKETS) depth_buckets[word] = place;
            }
        }
        return;
    }
    if (i == 0u) {
        for (uint bin = 0u; bin < RASTER_BINS; bin++) {
            uint draw = CULL_DRAWS + (phase * RASTER_BINS + bin) * 4u;
            cull_state[draw + 1u] = cull_state[CULL_BIN_COUNTS + phase * RASTER_BINS + bin];
            cull_state[draw + 3u] = offsets[bin];
        }
    }
    bool valid = i < count;
    uint4 entry = valid ? listed[base + i] : uint4(0u);
    uint bin = cull_listed_bin(entry.z);
    uint place = 0u;
    if (valid && (bin & RASTER_BIN_TESTED) != 0u) {
        InterlockedAdd(depth_buckets[cull_depth_word(phase, bin & RASTER_BIN_TWO_SIDED, cull_listed_bucket(entry.z))], 1u, place);
    }
    // The threads of a wave take their places in each untested bin with one atomic.
    for (uint untested = 0u; untested < RASTER_BIN_TESTED; untested++) {
        bool mine = valid && bin == untested;
        uint taken = WaveActiveCountBits(mine);
        if (taken == 0u) continue;
        uint first = 0u;
        if (WaveIsFirstLane()) InterlockedAdd(cull_state[CULL_BIN_CURSORS + phase * RASTER_BINS + untested], taken, first);
        first = WaveReadLaneFirst(first);
        if (mine) place = offsets[untested] + first + WavePrefixCountBits(mine);
    }
    if (valid) visible[place] = uint4(entry.xyw, 0u);
}
