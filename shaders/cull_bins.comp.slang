#include "native.slang"
// The visible clusters of a view by raster bin, by mode: 0 starts the cull of
// the view with the draw of the resolve of each Surface program empty (but
// that of the materials without one), a thread per program; 1, after the cull
// of a phase (cull_clusters.comp), places each cluster it listed in the range
// of its bin of the visible list, those of phase 1 after those of phase 0,
// and gives each bin of the phase its draw, an instance a cluster.
#include "scene.slang"
#include "cull_bins.slang"
#define MIRAI_GROUP_X CULL_BINS_GROUP
#define MIRAI_GROUP_Y 1
#define MIRAI_GROUP_Z 1

// programs: the largest program id, plus one. capacity: of the visible list, both phases together.
struct Params_Block { uint mode; uint phase; uint programs; uint capacity; };
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);
[[vk::binding(SLOT_PASS0, 0)]] RWStructuredBuffer<uint> cull_state : register(MIRAI_REGISTER(u, SLOT_PASS0), space0);
// The clusters as the cull listed them: the instance, the cluster as a word of the index pool and its bin.
[[vk::binding(SLOT_PASS1, 0)]] StructuredBuffer<uint4> listed : register(MIRAI_REGISTER(t, SLOT_PASS1), space0);
// The same by bin: the instance and the cluster.
[[vk::binding(SLOT_PASS2, 0)]] RWStructuredBuffer<uint2> visible : register(MIRAI_REGISTER(u, SLOT_PASS2), space0);
// The draws of the resolve of each Surface program (render.Gpu_Draw): three
// vertices, and the program as its first instance (vis_resolve.vert).
[[vk::binding(SLOT_PASS3, 0)]] RWStructuredBuffer<uint> program_draws : register(MIRAI_REGISTER(u, SLOT_PASS3), space0);

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
    if (i == 0u) {
        for (uint bin = 0u; bin < RASTER_BINS; bin++) {
            uint draw = CULL_DRAWS + (phase * RASTER_BINS + bin) * 4u;
            cull_state[draw + 1u] = cull_state[CULL_BIN_COUNTS + phase * RASTER_BINS + bin];
            cull_state[draw + 3u] = offsets[bin];
        }
    }
    bool valid = i < count;
    uint4 entry = valid ? listed[base + i] : uint4(0u);
    // The threads of a wave take their places in each bin with one atomic.
    uint place = 0u;
    for (uint bin = 0u; bin < RASTER_BINS; bin++) {
        bool mine = valid && entry.z == bin;
        uint taken = WaveActiveCountBits(mine);
        if (taken == 0u) continue;
        uint first = 0u;
        if (WaveIsFirstLane()) InterlockedAdd(cull_state[CULL_BIN_CURSORS + phase * RASTER_BINS + bin], taken, first);
        first = WaveReadLaneFirst(first);
        if (mine) place = offsets[bin] + first + WavePrefixCountBits(mine);
    }
    if (valid) visible[place] = entry.xy;
}
