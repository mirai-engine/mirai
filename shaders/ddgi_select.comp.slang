#include "native.slang"
// Chooses the probes traced this frame, at most params.budget of them, the
// most urgent first. A probe whose slot holds no light of the cell it stands
// for comes first, then one a change keeps awake (params.awake frames after it
// reached it, the nearer to it the sooner, or the next frame while its light
// moves), then the longest untraced against how much pixels use it, finer
// cascades first. What is left
// of the budget keeps tracing the probes by turns while nothing changes: each
// trace takes one more bounce from the volume, and once the volume holds them
// all its rays, the same every update, give back what it holds.
// In the order of params.mode, over one dispatch each:
//  0. per probe: its bucket (buckets[probe]) and the count of each bucket;
//  1. one thread: the last bucket that fits and how many of it fit;
//  2. per probe: the chosen ones, into chosen (count, then slots);
//  3. one thread: the sizes of the indirect dispatches of the update passes.
#define PROBES_WRITABLE
#include "scene.slang"
#define MIRAI_GROUP_X 64
#define MIRAI_GROUP_Y 1
#define MIRAI_GROUP_Z 1

// The priority of a probe is one of PROBE_BUCKETS buckets. A probe a change
// keeps awake falls in one of PROBE_NEAR_LEVELS levels of how near it is to the
// change (ddgi_touch.comp), two buckets each, and the waiting ones come after them.
#define PROBE_NEAR_LEVELS 4u
#define PROBE_WAITING_FIRST (2u + 2u * PROBE_NEAR_LEVELS)
#define NO_BUCKET 0xFFFFFFFFu
// Frames since a pixel used a probe for it to count as in use.
#define PROBE_IN_USE 8u

struct Params_Block {
    uint mode;
    uint budget;
    uint changed_everywhere; // render.Renderer.frame of the last change everywhere
    uint frame_number;
    uint rays_per_probe;
    uint total;
    uint awake;      // frames a change keeps the probes it reaches traced
    uint pad0;
};
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);
[[vk::binding(SLOT_PASS0, 0)]] RWStructuredBuffer<uint> buckets : register(MIRAI_REGISTER(u, SLOT_PASS0), space0);
// The count of each bucket, then the last bucket chosen, how many of it fit and how many of it were taken.
[[vk::binding(SLOT_PASS1, 0)]] RWStructuredBuffer<uint> histogram : register(MIRAI_REGISTER(u, SLOT_PASS1), space0);
[[vk::binding(SLOT_PASS2, 0)]] RWStructuredBuffer<uint> chosen : register(MIRAI_REGISTER(u, SLOT_PASS2), space0);
// Groups of the trace (x, y, z), of the passes per probe and of the passes per 32 probes.
[[vk::binding(SLOT_PASS3, 0)]] RWStructuredBuffer<uint> dispatch : register(MIRAI_REGISTER(u, SLOT_PASS3), space0);

uint probe_bucket(uint index) {
    uint cascade;
    int3 cell = probe_slot_cell(index, cascade);
    Probe probe = probes[index];
    bool in_use = params.frame_number - probe.frames.y < PROBE_IN_USE;
    if (!all(probe.cell.xyz == cell) || probe.frames.x == 0u) return in_use ? 0u : 1u;
    if (probe.frames.z > probe.frames.x) {
        // Awake only because its own light moves: the last of the awake ones.
        uint level = probe.frames.z > params.frame_number ? min(uint(probe.offset.w * float(PROBE_NEAR_LEVELS)), PROBE_NEAR_LEVELS - 1u) : 0u;
        return 2u + 2u * (PROBE_NEAR_LEVELS - 1u - level) + (in_use ? 0u : 1u);
    }
    float waiting = float(params.frame_number - probe.frames.x) * (in_use ? 4.0 : 1.0) / float(cascade + 1u);
    return PROBE_BUCKETS - 1u - min(uint(log2(max(waiting, 1.0))), PROBE_BUCKETS - 1u - PROBE_WAITING_FIRST);
}

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 dispatch_id : SV_DispatchThreadID) {
    uint index = dispatch_id.x;
    if (params.mode == 0u) {
        if (index >= params.total) return;
        uint bucket = probe_bucket(index);
        buckets[index] = bucket;
        if (bucket != NO_BUCKET) InterlockedAdd(histogram[bucket], 1u);
    } else if (params.mode == 1u) {
        if (index != 0u) return;
        uint taken = 0u;
        uint last = PROBE_BUCKETS;
        uint room = 0u;
        for (uint b = 0u; b < PROBE_BUCKETS; b++) {
            if (taken + histogram[b] > params.budget) { last = b; room = params.budget - taken; break; }
            taken += histogram[b];
        }
        histogram[PROBE_BUCKETS] = last;
        histogram[PROBE_BUCKETS + 1u] = room;
        histogram[PROBE_BUCKETS + 2u] = 0u;
        chosen[0] = 0u;
    } else if (params.mode == 2u) {
        if (index >= params.total) return;
        uint bucket = buckets[index];
        uint last = histogram[PROBE_BUCKETS];
        bool take = bucket < last;
        if (bucket == last) {
            uint place;
            InterlockedAdd(histogram[PROBE_BUCKETS + 2u], 1u, place);
            take = place < histogram[PROBE_BUCKETS + 1u];
        }
        if (!take) return;
        uint at;
        InterlockedAdd(chosen[0], 1u, at);
        if (at >= params.budget) return;
        chosen[1u + at] = index;
        probes[index].cell.w |= PROBE_CHOSEN;
    } else {
        if (index != 0u) return;
        uint count = min(chosen[0], params.budget);
        chosen[0] = count;
        dispatch[0] = (params.rays_per_probe + 31u) / 32u;
        dispatch[1] = count;
        dispatch[2] = 1u;
        dispatch[3] = count;
        dispatch[4] = 1u;
        dispatch[5] = 1u;
        dispatch[6] = (count + 31u) / 32u;
        dispatch[7] = 1u;
        dispatch[8] = 1u;
    }
}
