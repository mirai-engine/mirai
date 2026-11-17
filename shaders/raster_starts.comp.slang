#include "native.slang"
// Where the triangles the raster of the visibility target draws of a phase
// go (raster_lists.slang), once raster_vertices.comp counted them: those of
// each raster bin in a row after those of the bin before, those of phase 1
// after those of phase 0, and in a tested bin those of each depth bucket
// after those of the bucket before, so that it draws nearest first. Each bin
// gets its draw, and each range the place its next triangle takes
// (raster_triangles.comp). One group.
#include "scene.slang"
#include "raster_lists.slang"
#define MIRAI_GROUP_X CULL_BINS_GROUP
#define MIRAI_GROUP_Y 1
#define MIRAI_GROUP_Z 1

struct Params_Block { uint phase; uint pad0; uint pad1; uint pad2; };
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);
[[vk::binding(SLOT_PASS0, 0)]] RWStructuredBuffer<uint> cull_state : register(MIRAI_REGISTER(u, SLOT_PASS0), space0);
[[vk::binding(SLOT_PASS4, 0)]] RWStructuredBuffer<uint> depth_buckets : register(MIRAI_REGISTER(u, SLOT_PASS4), space0);

#define BUCKETS_PER_THREAD (2u * RASTER_DEPTH_BUCKETS / CULL_BINS_GROUP)
groupshared uint thread_sums[CULL_BINS_GROUP];

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 lane : SV_GroupThreadID) {
    uint phase = params.phase;
    uint running = 0u;
    if (phase != 0u) {
        for (uint bin = 0u; bin < RASTER_BINS; bin++) running += cull_state[CULL_RASTER_COUNTS + bin];
    }
    uint starts[RASTER_BINS];
    for (uint bin = 0u; bin < RASTER_BINS; bin++) {
        starts[bin] = running;
        running += cull_state[CULL_RASTER_COUNTS + phase * RASTER_BINS + bin];
    }
    // The buckets of both tested bins in a row, those of a bin starting where
    // it does: each thread sums a run of them, then takes the sums of the
    // threads of its bin before it.
    uint t = lane.x, first = t * BUCKETS_PER_THREAD;
    uint sided = first / RASTER_DEPTH_BUCKETS;
    uint counts[BUCKETS_PER_THREAD];
    uint sum = 0u;
    for (uint k = 0u; k < BUCKETS_PER_THREAD; k++) {
        counts[k] = depth_buckets[raster_depth_word(phase, sided, first % RASTER_DEPTH_BUCKETS + k)];
        sum += counts[k];
    }
    thread_sums[t] = sum;
    GroupMemoryBarrierWithGroupSync();
    uint start = starts[RASTER_BIN_TESTED | sided];
    for (uint before = sided * (CULL_BINS_GROUP / 2u); before < t; before++) start += thread_sums[before];
    for (uint k = 0u; k < BUCKETS_PER_THREAD; k++) {
        depth_buckets[RASTER_DEPTH_STARTS + raster_depth_word(phase, sided, first % RASTER_DEPTH_BUCKETS + k)] = start;
        start += counts[k];
    }
    if (t != 0u) return;
    for (uint bin = 0u; bin < RASTER_BINS; bin++) {
        uint triangles = cull_state[CULL_RASTER_COUNTS + phase * RASTER_BINS + bin];
        cull_state[CULL_RASTER_CURSORS + phase * RASTER_BINS + bin] = starts[bin];
        uint draw = CULL_DRAWS + (phase * RASTER_BINS + bin) * CULL_DRAW_WORDS;
        cull_state[draw] = triangles * 3u;
        cull_state[draw + 1u] = 1u;
        cull_state[draw + 2u] = starts[bin] * 3u;
        cull_state[draw + 3u] = 0u;
        cull_state[draw + 4u] = starts[bin];
    }
}
