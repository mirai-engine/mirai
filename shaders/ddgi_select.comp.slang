#include "native.slang"
// Chooses the probes traced this frame, at most params.budget of them, the
// most urgent first. A probe whose slot holds no light of the cell it stands
// for comes first, then one a change keeps awake (params.awake frames after it
// reached it, the nearer to it the sooner, or the next frame while its light
// moves), then the longest untraced against how much pixels use it, finer
// cascades first. Of what is left of the budget, PROBE_WAITING_SHARE at most
// keeps tracing by turns, while nothing changes, only the probes that need it:
// one whose rays met what changes with nothing that says so (PROBE_PASSING),
// and one whose kept rays a change everywhere left behind. A probe whose light
// moves wakes the ones beside it (ddgi_irradiance.comp), so that a change
// spreads with its bounces; any other gives back the same. The updates that
// gather the light of a world shown anew take the whole budget (params.whole),
// over every probe: each is a bounce more for every probe it reaches.
// A probe that is chosen takes a slot for what it keeps of its rays
// (probe_slots.slang) where it holds none and one of its two is free or left:
// its probe was not chosen for PROBE_SLOT_KEEP updates, or for
// PROBE_SLOT_KEEP_USED if pixels used it then. What the slot held is not its own.
// In the order of params.mode, over one dispatch each:
//  0. per probe: its bucket (buckets[probe]) and the count of each bucket;
//  1. one thread: the last bucket that fits and how many of it fit;
//  2. per probe: the chosen ones, into chosen (count, then slots);
//  3. one thread: the sizes of the indirect dispatches of the update passes.
#define PROBES_WRITABLE
#define PROBE_SLOTS_WRITABLE
#include "scene.slang"
#include "probe_slots.slang"
#define MIRAI_GROUP_X 64
#define MIRAI_GROUP_Y 1
#define MIRAI_GROUP_Z 1

// The priority of a probe is one of PROBE_BUCKETS buckets. A probe a change
// keeps awake falls in one of PROBE_NEAR_LEVELS levels of how near it is to the
// change (ddgi_touch.comp), two buckets each, and the waiting ones come after them.
#define PROBE_NEAR_LEVELS 4u
#define PROBE_WAITING_FIRST (2u + 2u * PROBE_NEAR_LEVELS)
#define NO_BUCKET 0xFFFFFFFFu
// The share of the budget the probes waiting by turns take at most.
#define PROBE_WAITING_SHARE 8u
// Frames since a pixel used a probe for it to count as in use.
#define PROBE_IN_USE 8u
// Updates a probe that is not chosen keeps its slot from another that is. One a
// change keeps awake is chosen again within a few; one the pixels use, which
// waits by turns, comes back after hundreds, and the others long after.
#define PROBE_SLOT_KEEP 16u
#define PROBE_SLOT_KEEP_USED 1024u

struct Params_Block {
    uint mode;
    uint budget;
    uint frame_number;
    uint rays_per_probe;
    uint total;
    uint awake;      // frames a change keeps the probes it reaches traced
    uint whole;      // 1: the probes waiting by turns take all that is left of the budget (render.gi_warm)
    uint room;       // probes the list of the chosen has room for: after them, what the update passes write of each and count (probe_update.slang)
    uint slots;      // of what the probes keep of their rays
    // The update, plus one, in which what rays meet last changed everywhere,
    // and the one in which the lights did (probe_update.slang).
    uint seen_everywhere;
    uint lit_everywhere;
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
    bool due = (probe.cell.w & PROBE_PASSING) != 0 || probe.hits.x < params.seen_everywhere || probe.hits.y < params.lit_everywhere;
    if (!due && params.whole == 0u) return NO_BUCKET;
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
        uint urgent = 0u;
        for (uint b = 0u; b < PROBE_WAITING_FIRST; b++) urgent += histogram[b];
        uint budget = params.whole != 0u ? params.budget : min(params.budget, urgent + max(params.budget / PROBE_WAITING_SHARE, 1u));
        uint taken = 0u;
        uint last = PROBE_BUCKETS;
        uint room = 0u;
        for (uint b = 0u; b < PROBE_BUCKETS; b++) {
            if (taken + histogram[b] > budget) { last = b; room = budget - taken; break; }
            taken += histogram[b];
        }
        histogram[PROBE_BUCKETS] = last;
        histogram[PROBE_BUCKETS + 1u] = room;
        histogram[PROBE_BUCKETS + 2u] = 0u;
        chosen[0] = 0u;
        chosen[1u + 2u * params.room] = 0u;
        chosen[2u + 2u * params.room] = 0u;
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
        chosen[1u + params.room + at] = 0u;
        uint held = probe_slot_held(index, params.slots);
        uint2 slots = probe_slots_of(index, params.slots);
        for (uint k = 0u; k < 2u && held == INVALID && params.slots != 0u; k++) {
            uint word = slots[k] * PROBE_SLOT_WORDS;
            uint owner = probe_slots[word];
            if (owner != 0u && params.frame_number <= probe_slots[word + 1u]) continue;
            uint was;
            InterlockedCompareExchange(probe_slots[word], owner, index + 1u, was);
            if (was != owner) continue;
            held = slots[k];
            probes[index].cell.w &= ~PROBE_KEPT;
        }
        bool used = params.frame_number - probes[index].frames.y < PROBE_IN_USE;
        if (held != INVALID) probe_slots[held * PROBE_SLOT_WORDS + 1u] = params.frame_number + (used ? PROBE_SLOT_KEEP_USED : PROBE_SLOT_KEEP);
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
