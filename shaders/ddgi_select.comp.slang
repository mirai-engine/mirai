#include "native.slang"
// Chooses the probes traced this frame, at most params.budget of them, the
// most urgent first. A probe whose slot holds no light of the cell it stands
// for and that a pixel reads this frame (any, in a whole update) comes first,
// then one a change keeps awake (params.awake frames after it reached it, the
// nearer to it the sooner, or the next frame while its light moves). Of what
// is left of the budget, the new probes no pixel reads take PROBE_WAITING_SHARE
// at most while the volume moves and all of it once it stops, and as much
// as that share again keeps tracing by turns, the longest untraced against how much
// pixels use it, finer cascades first, while nothing changes, only the probes
// that need it: one whose rays met what changes with nothing that says so
// (PROBE_PASSING), once it has waited 1 << its PROBE_WAITS frames, and one
// whose kept rays a change everywhere left behind. A probe whose light
// moves wakes the ones beside it (ddgi_irradiance.comp), so that a change
// spreads with its bounces; any other gives back the same. The updates that
// gather the light of a world shown anew, one a frame, take the whole budget
// (params.whole), over every probe: each is a bounce more for every probe it reaches.
// A probe that is chosen takes a slot for what it keeps of its rays
// (probe_slots.slang) where it holds none and one of its two is free or left:
// its probe was not chosen for PROBE_SLOT_KEEP updates, for
// PROBE_SLOT_KEEP_USED if pixels used it then, or for twice what it waits by
// turns. What the slot held is not its own.
// In the order of params.mode, over one dispatch each:
//  0. per probe: its bucket (buckets[probe]) and the count of each bucket;
//  1. one thread: how many of each bucket are taken;
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
// change (ddgi_touch.comp), two buckets each; the new ones no pixel reads come
// after them, and then the waiting ones.
#define PROBE_NEAR_LEVELS 4u
#define PROBE_NEW_UNREAD (1u + 2u * PROBE_NEAR_LEVELS)
#define PROBE_WAITING_FIRST (PROBE_NEW_UNREAD + 1u)
#define NO_BUCKET 0xFFFFFFFFu
// The share of the budget the new probes no pixel reads take at most, and
// that the probes waiting by turns take at most.
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
    uint moving;     // 1: a cascade took other cells this frame
};
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);
[[vk::binding(SLOT_PASS0, 0)]] RWStructuredBuffer<uint> buckets : register(MIRAI_REGISTER(u, SLOT_PASS0), space0);
// The count of each bucket, then how many of each are taken, then how many of each were.
[[vk::binding(SLOT_PASS1, 0)]] RWStructuredBuffer<uint> histogram : register(MIRAI_REGISTER(u, SLOT_PASS1), space0);
[[vk::binding(SLOT_PASS2, 0)]] RWStructuredBuffer<uint> chosen : register(MIRAI_REGISTER(u, SLOT_PASS2), space0);
// Groups of the trace (x, y, z), of the passes per probe and of the passes per 32 probes.
[[vk::binding(SLOT_PASS3, 0)]] RWStructuredBuffer<uint> dispatch : register(MIRAI_REGISTER(u, SLOT_PASS3), space0);

uint probe_bucket(uint index) {
    uint cascade;
    int3 cell = probe_slot_cell(index, cascade);
    Probe probe = probes[index];
    bool in_use = params.frame_number - probe.frames.y < PROBE_IN_USE;
    // What the slot was last read for is of the cell it held before.
    bool new_cell = !all(probe.cell.xyz == cell);
    // The updates that gather a world shown anew take them all first.
    bool read = params.whole != 0u || (new_cell ? probe.frames.y == params.frame_number : in_use);
    if (new_cell || probe.frames.x == 0u) return read ? 0u : PROBE_NEW_UNREAD;
    if (probe.frames.z > probe.frames.x) {
        // Awake only because its own light moves: the last of the awake ones.
        uint level = probe.frames.z > params.frame_number ? min(uint(probe.offset.w * float(PROBE_NEAR_LEVELS)), PROBE_NEAR_LEVELS - 1u) : 0u;
        return 1u + 2u * (PROBE_NEAR_LEVELS - 1u - level) + (in_use ? 0u : 1u);
    }
    uint waits = uint(probe.cell.w & PROBE_WAITS) / uint(PROBE_WAIT);
    bool passing = (probe.cell.w & PROBE_PASSING) != 0 && params.frame_number - probe.frames.x >= (1u << waits);
    bool due = passing || probe.hits.x < params.seen_everywhere || probe.hits.y < params.lit_everywhere;
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
        // The urgent ones take what they need; the new no pixel reads take a
        // share while the volume moves and what is left once it stops, and the
        // waiting a share, or all that is left in a whole update.
        uint share = params.whole != 0u ? params.budget : max(params.budget / PROBE_WAITING_SHARE, 1u);
        uint left = params.budget;
        uint waiting = share;
        for (uint b = 0u; b < PROBE_BUCKETS; b++) {
            uint unread = params.moving != 0u ? share : left;
            uint most = b < PROBE_NEW_UNREAD ? left : min(left, b == PROBE_NEW_UNREAD ? unread : waiting);
            uint take = min(histogram[b], most);
            histogram[PROBE_BUCKETS + b] = take;
            left -= take;
            if (b >= PROBE_WAITING_FIRST) waiting -= take;
        }
        chosen[0] = 0u;
        chosen[1u + 2u * params.room] = 0u;
        chosen[2u + 2u * params.room] = 0u;
    } else if (params.mode == 2u) {
        if (index >= params.total) return;
        uint bucket = buckets[index];
        if (bucket == NO_BUCKET) return;
        uint room = histogram[PROBE_BUCKETS + bucket];
        bool take = room >= histogram[bucket];
        if (!take && room != 0u) {
            uint place;
            InterlockedAdd(histogram[2u * PROBE_BUCKETS + bucket], 1u, place);
            take = place < room;
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
        // One that waits by turns keeps it until a while after its next.
        uint waits = (probes[index].cell.w & PROBE_PASSING) != 0 ? uint(probes[index].cell.w & PROBE_WAITS) / uint(PROBE_WAIT) : 0u;
        uint keep = max(used ? PROBE_SLOT_KEEP_USED : PROBE_SLOT_KEEP, 2u << waits);
        if (held != INVALID) probe_slots[held * PROBE_SLOT_WORDS + 1u] = params.frame_number + keep;
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
