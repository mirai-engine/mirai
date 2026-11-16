#include "native.slang"
// The visible clusters of a view by raster bin: after the cull of a phase
// (cull_clusters.comp), each cluster it listed goes to the range of its bin of
// the visible list, those of phase 1 after those of phase 0, and each bin of
// the phase gets its draw, an instance a cluster. A tested bin draws nearest
// first: its clusters go to the range of their depth bucket, which each group
// finds from the counts of the buckets alone.
#include "scene.slang"
#include "cull_bins.slang"
#define MIRAI_GROUP_X CULL_BINS_GROUP
#define MIRAI_GROUP_Y 1
#define MIRAI_GROUP_Z 1

// capacity: of the visible list, both phases together.
struct Params_Block { uint phase; uint capacity; uint pad0; uint pad1; };
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);
[[vk::binding(SLOT_PASS0, 0)]] RWStructuredBuffer<uint> cull_state : register(MIRAI_REGISTER(u, SLOT_PASS0), space0);
// The clusters as the cull listed them: the instance, the cluster as a word
// of the index pool, its bin and depth bucket (cull_listed_bin) and its
// Surface program.
[[vk::binding(SLOT_PASS1, 0)]] StructuredBuffer<uint4> listed : register(MIRAI_REGISTER(t, SLOT_PASS1), space0);
// The same by bin: the instance, the cluster and the program.
[[vk::binding(SLOT_PASS2, 0)]] RWStructuredBuffer<uint4> visible : register(MIRAI_REGISTER(u, SLOT_PASS2), space0);
// Of each phase and tested bin, the clusters of each depth bucket, then the cursors of the buckets (cull_depth_word).
[[vk::binding(SLOT_PASS4, 0)]] RWStructuredBuffer<uint> depth_buckets : register(MIRAI_REGISTER(u, SLOT_PASS4), space0);

#define BUCKETS_PER_THREAD (2u * RASTER_DEPTH_BUCKETS / CULL_BINS_GROUP)
// Where the clusters of each depth bucket of both tested bins of the phase start.
groupshared uint bucket_starts[2u * RASTER_DEPTH_BUCKETS];
groupshared uint thread_sums[CULL_BINS_GROUP];

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 dispatch_id : SV_DispatchThreadID, uint3 lane : SV_GroupThreadID) {
    uint i = dispatch_id.x;
    uint phase = params.phase;
    uint base = phase == 0u ? 0u : min(cull_state[CULL_LISTED], params.capacity);
    uint count = min(cull_state[CULL_LISTED + phase], params.capacity - base);
    uint offsets[RASTER_BINS];
    uint running = base;
    for (uint bin = 0u; bin < RASTER_BINS; bin++) {
        offsets[bin] = running;
        running += cull_state[CULL_BIN_COUNTS + phase * RASTER_BINS + bin];
    }
    // The buckets of both tested bins in a row, those of a bin starting where
    // it does: each thread sums a run of them, then takes the sums of the
    // threads of its bin before it.
    uint t = lane.x, first = t * BUCKETS_PER_THREAD;
    uint sided = first / RASTER_DEPTH_BUCKETS;
    uint counts[BUCKETS_PER_THREAD];
    uint sum = 0u;
    for (uint k = 0u; k < BUCKETS_PER_THREAD; k++) {
        counts[k] = depth_buckets[cull_depth_word(phase, sided, first % RASTER_DEPTH_BUCKETS + k)];
        sum += counts[k];
    }
    thread_sums[t] = sum;
    GroupMemoryBarrierWithGroupSync();
    uint start = offsets[RASTER_BIN_TESTED | sided];
    for (uint before = sided * (CULL_BINS_GROUP / 2u); before < t; before++) start += thread_sums[before];
    for (uint k = 0u; k < BUCKETS_PER_THREAD; k++) {
        bucket_starts[first + k] = start;
        start += counts[k];
    }
    GroupMemoryBarrierWithGroupSync();

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
        uint two_sided = bin & RASTER_BIN_TWO_SIDED, bucket = cull_listed_bucket(entry.z);
        uint taken;
        InterlockedAdd(depth_buckets[CULL_DEPTH_COUNTS + cull_depth_word(phase, two_sided, bucket)], 1u, taken);
        place = bucket_starts[two_sided * RASTER_DEPTH_BUCKETS + bucket] + taken;
    }
    // The threads of a wave take their places in each untested bin with one atomic.
    for (uint untested = 0u; untested < RASTER_BIN_TESTED; untested++) {
        bool mine = valid && bin == untested;
        uint taken = WaveActiveCountBits(mine);
        if (taken == 0u) continue;
        uint at = 0u;
        if (WaveIsFirstLane()) InterlockedAdd(cull_state[CULL_BIN_CURSORS + phase * RASTER_BINS + untested], taken, at);
        at = WaveReadLaneFirst(at);
        if (mine) place = offsets[untested] + at + WavePrefixCountBits(mine);
    }
    if (valid) visible[place] = uint4(entry.xyw, 0u);
}
