#include "native.slang"
// The table of the pages of the maps of the shadows of a view, each frame
// after the marks of its points (shadow_mark.comp, render.shadow_maps_pass),
// in steps (Params_Block.step, render.Shadow_Pages_Step), each after the
// first dispatched by the arguments it writes:
// - Gate, one thread: the steps run where the view, a light or a caster
//   changed (Params_Block.full), else only where a point asked for a page not
//   drawn since they last ran (SHADOW_STEP_NEW); a still view keeps the
//   requests and the table of the frame before, and its rounds draw nothing;
// - Clear, where they run without a change: what each run writes again, the
//   masks of the points and of the passes after the maps kept;
// - Invalidate, a thread for each box of what changed and each slot: the
//   entries its pages cover, at each mip, where what stays or what moves
//   changed (render.Shadow_Plan boxes);
// - Entries, a thread for each entry of each slot: lets go of the page of
//   the pool of what the plan says (render.Shadow_Slot_Plan), forgets what
//   stays or what moves where they changed, and of a page a point reads, the
//   frame before read late, or the safety net keeps: asks for a page of the
//   pool where it has none, else lists it for the cache to draw where what
//   stays is not drawn there and for the atlas to compose where that is not;
//   a slot that lets go of every page (a light that turned or moved) draws
//   them whole into the atlas alone that frame, and the cache the next;
// - Rank and Sums: the rank of each page asked for, in one order every frame
//   (SHADOW_RANK_WORDS: the safety net first, the coarsest first);
// - Pool, one group while a page was asked for: the pages of the pool that can be given, free first,
//   then those no point read this frame, the longest unread first;
// - Allocate, a thread for each word of the ranks: each page asked for takes
//   the page of the pool of its rank, which its entry lets go of; past them it
//   is left out;
// - Propagate, a thread for each entry: where its page is not drawn, how many
//   levels of the sun or mips coarser the nearest one drawn lies;
// - Finish: the arguments of the culls and the draws of the rounds.
// The pages listed take their bits in the masks of each round, by their
// entry, and each slot with one is listed once.
#include "scene.slang"
#define SHADOW_TABLE_WRITTEN
#define MIRAI_GROUP_X 256
#define MIRAI_GROUP_Y 1
#define MIRAI_GROUP_Z 1
// The table of the pages (render.Shadow_Raster.table).
[[vk::binding(SLOT_PASS3, 0)]] [[vk::image_format("r32ui")]] RWTexture2D<uint> table : register(MIRAI_REGISTER(u, SLOT_PASS3), space0);
uint shadow_table_entry(uint slot, uint entry) { return table[int2(int(entry), int(slot))]; }
void table_set(uint slot, uint entry, uint e) { table[int2(int(entry), int(slot))] = e; }
#include "shadow_maps.slang"

// step; frame: counts the frames; rows: of the words of the lights in the
// buffer of the maps; plan, boxes: the words of it the plans of the slots and
// the boxes of what changed start at, boxes and levels of the sun of them;
// pool: the pages of the pool it may give; groups of the cull of each round;
// fresh: the table holds nothing yet; full: the view, a light or a caster
// changed, and the masks were cleared before the marks.
struct Params_Block { uint step; uint frame; uint rows; uint plan; uint boxes; uint box_count; uint sun; uint pool; uint groups_stays; uint groups_moves; uint groups_glass; uint fresh; uint full; uint pad0; uint pad1; uint pad2; };
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);
[[vk::binding(SLOT_PASS0, 0)]] StructuredBuffer<uint4> shadow_data : register(MIRAI_REGISTER(t, SLOT_PASS0), space0);
[[vk::binding(SLOT_PASS2, 0)]] RWStructuredBuffer<uint> pages : register(MIRAI_REGISTER(u, SLOT_PASS2), space0);
// The farthest depth the cache held over the blocks of each page of the pool
// before this frame drew it (shadow_hiz.comp), its mips.
[[vk::binding(SLOT_PASS4, 0)]] Texture2D<float4> hiz : register(MIRAI_REGISTER(t, SLOT_PASS4), space0);
#include "shadow_hidden.slang"

#define STEP_GATE 0u
#define STEP_CLEAR 1u
#define STEP_INVALIDATE 2u
#define STEP_ENTRIES 3u
#define STEP_RANK 4u
#define STEP_SUMS 5u
#define STEP_POOL 6u
#define STEP_ALLOCATE 7u
#define STEP_PROPAGATE 8u
#define STEP_FINISH 9u
// What the steps write again each time they run without a change, the masks of the marks kept.
#define CLEAR_WORDS (SHADOW_WORDS_SLOTS - SHADOW_WORDS_STALE)
#define ROUND_STAYS 0u
#define ROUND_MOVES 1u
#define ROUND_READY 2u
#define ROUND_GROUP 256u
#define POOL_GROUP 1024u

groupshared uint shared_words[POOL_GROUP];

// The arguments of the dispatch of a step over a number of threads.
void step_args(uint step, uint threads) {
    uint at = SHADOW_WORDS_STEPS + 3u * step;
    pages[at] = (threads + ROUND_GROUP - 1u) / ROUND_GROUP;
    pages[at + 1u] = 1u;
    pages[at + 2u] = 1u;
}

uint data_word(uint word) { return shadow_data[word >> 2u][word & 3u]; }
uint4 slot_plan(uint slot) { return shadow_data[(params.plan >> 2u) + slot]; }
bool mask_bit(uint region, uint slot, uint entry) { return ((pages[region + slot * SHADOW_MASK_WORDS + (entry >> 5u)] >> (entry & 31u)) & 1u) != 0u; }
void mask_set(uint region, uint slot, uint entry) {
    uint word = region + slot * SHADOW_MASK_WORDS + (entry >> 5u), bit = 1u << (entry & 31u);
    if ((pages[word] & bit) == 0u) InterlockedOr(pages[word], bit);
}
// The narrowest texel of a map over a box of the world, metres
// (render.shadow_map_finest).
float shadow_map_finest(Shadow_Map m, float3 low, float3 high) {
    float across = (m.span.z - m.span.x) / float(max(m.rect.z, 1u));
    if (shadow_map_orthographic(m)) return across;
    float3 center = 0.5 * (low + high) - m.origin;
    float3 half = 0.5 * (high - low);
    return across * max(dot(center, m.forward) - dot(half, abs(m.forward)), m.near);
}

// A page of a slot in a round: its bit, its slot listed once, the pages of
// each of its mips it spans, and of the cache and the atlas, its page of the
// pool listed to draw, of the atlas with SHADOW_JOB_HELD where the cache holds
// it this frame.
void listed(uint round, uint slot, uint entry, uint2 page, uint job) {
    uint masks[3] = {SHADOW_WORDS_DRAWN, SHADOW_WORDS_COMPOSE, SHADOW_WORDS_READY};
    InterlockedOr(pages[masks[round] + slot * SHADOW_MASK_WORDS + (entry >> 5u)], 1u << (entry & 31u));
    uint mip = shadow_entry_mip(entry);
    uint span = SHADOW_WORDS_BOUNDS + ((round * SHADOW_SLOTS + slot) * SHADOW_MIPS + mip) * 4u;
    InterlockedMax(pages[span], SHADOW_MAP_PAGES - page.x);
    InterlockedMax(pages[span + 1u], SHADOW_MAP_PAGES - page.y);
    InterlockedMax(pages[span + 2u], page.x + 1u);
    InterlockedMax(pages[span + 3u], page.y + 1u);
    uint before;
    InterlockedExchange(pages[SHADOW_WORDS_HAS + round * SHADOW_SLOTS + slot], 1u, before);
    if (before == 0u) {
        uint at;
        InterlockedAdd(pages[SHADOW_WORDS_COUNTS + SHADOW_COUNT_SLOTS + round], 1u, at);
        pages[SHADOW_WORDS_SLOTS + round * SHADOW_SLOTS + at] = slot;
    }
    if (round == ROUND_READY) return;
    uint at;
    InterlockedAdd(pages[SHADOW_WORDS_COUNTS + (round == ROUND_STAYS ? SHADOW_COUNT_DRAWN : SHADOW_COUNT_COMPOSED)], 1u, at);
    if (at < SHADOW_POOL_PAGES) pages[SHADOW_WORDS_JOBS + round * SHADOW_POOL_PAGES + at] = job;
}

// The word of the masks of the pages asked for of rank word v
// (SHADOW_RANK_WORDS): its mask, slot and word.
uint3 rank_word(uint v) {
    uint region = SHADOW_WORDS_FIRST;
    if (v >= SHADOW_RANK_FIRST) {
        region = SHADOW_WORDS_ASKED;
        v -= SHADOW_RANK_FIRST;
        uint sun = SHADOW_SUN_MAPS * SHADOW_SUN_WORDS;
        if (v >= sun) {
            v -= sun;
            return uint3(region, SHADOW_SUN_MAPS + v % SHADOW_LOCAL_SLOTS, v / SHADOW_LOCAL_SLOTS);
        }
    } else if (v >= SHADOW_SUN_MAPS * SHADOW_SUN_WORDS) {
        return uint3(region, SHADOW_SUN_MAPS + v - SHADOW_SUN_MAPS * SHADOW_SUN_WORDS, 0u);
    }
    return uint3(region, SHADOW_SUN_MAPS - 1u - v / SHADOW_SUN_WORDS, SHADOW_SUN_WORD + v % SHADOW_SUN_WORDS);
}
uint rank_bits(uint v) {
    if (v >= SHADOW_RANK_WORDS) return 0u;
    uint3 w = rank_word(v);
    return pages[w.x + w.y * SHADOW_MASK_WORDS + w.z];
}

// The inclusive sums of the words of a group, in place.
void group_scan(uint lane, uint count) {
    for (uint offset = 1u; offset < count; offset <<= 1u) {
        uint before = lane >= offset ? shared_words[lane - offset] : 0u;
        GroupMemoryBarrierWithGroupSync();
        shared_words[lane] += before;
        GroupMemoryBarrierWithGroupSync();
    }
}

// The column and the row of the first page of a level of the sun on the grid
// of the world, rows up from its bottom.
int2 sun_first_page(Shadow_Map m) {
    float page = (m.span.z - m.span.x) / float(SHADOW_MAP_PAGES);
    return int2(round(m.span.xy / page));
}

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 id : SV_DispatchThreadID, uint3 lane3 : SV_GroupThreadID, uint3 group : SV_GroupID) {
    uint i = id.x, lane = lane3.x;
    if (params.step == STEP_GATE) {
        if (i != 0u) return;
        bool run = params.full != 0u || pages[SHADOW_STEP_NEW] != 0u;
        pages[SHADOW_STEP_NEW] = 0u;
        if (run) pages[SHADOW_STEP_RUNS] += 1u;
        uint all = run ? SHADOW_SLOTS * SHADOW_SLOT_ENTRIES : 0u;
        step_args(STEP_CLEAR, run && params.full == 0u ? CLEAR_WORDS : 0u);
        step_args(STEP_INVALIDATE, run ? params.box_count * SHADOW_SLOTS : 0u);
        step_args(STEP_ENTRIES, all);
        step_args(STEP_RANK, run ? SHADOW_RANK_WORDS : 0u);
        step_args(STEP_SUMS, run ? 1u : 0u);
        step_args(STEP_POOL, 0u);
        step_args(STEP_ALLOCATE, 0u);
        step_args(STEP_PROPAGATE, all);
        step_args(STEP_FINISH, run ? 1u : 0u);
        if (run) return;
        // A still view: the rounds of what stays and of what moves draw nothing;
        // that of the glass keeps the pages ready of the last run.
        uint counts[4] = {SHADOW_COUNT_DRAWN, SHADOW_COUNT_COMPOSED, SHADOW_COUNT_REQUESTS, SHADOW_COUNT_LEFT};
        for (uint k = 0u; k < 4u; k++) pages[SHADOW_WORDS_COUNTS + counts[k]] = 0u;
        for (uint round = 0u; round < 2u; round++) {
            pages[SHADOW_WORDS_ARGS + SHADOW_ARGS_DISPATCH + 3u * round] = 0u;
            pages[SHADOW_WORDS_ARGS + SHADOW_ARGS_DRAW + 4u * round + 1u] = 0u;
        }
        pages[SHADOW_WORDS_ARGS + SHADOW_ARGS_HIZ] = 0u;
    } else if (params.step == STEP_CLEAR) {
        if (i < CLEAR_WORDS) pages[SHADOW_WORDS_STALE + i] = 0u;
    } else if (params.step == STEP_INVALIDATE) {
        uint box = i / SHADOW_SLOTS, slot = i % SHADOW_SLOTS;
        if (box >= params.box_count) return;
        Shadow_Map whole = shadow_map_at(shadow_data, params.rows, slot);
        if (whole.rect.z == 0u) return;
        uint4 a = shadow_data[(params.boxes >> 2u) + box * SHADOW_BOX_ROWS], b = shadow_data[(params.boxes >> 2u) + box * SHADOW_BOX_ROWS + 1u];
        float3 low = asfloat(a.xyz), high = asfloat(b.xyz);
        float fine = asfloat(a.w);
        uint region = b.w != 0u ? SHADOW_WORDS_MOVED : SHADOW_WORDS_STALE;
        if (!shadow_map_reaches(whole, low, high)) return;
        for (uint mip = 0u; mip < (slot < SHADOW_SUN_MAPS ? 1u : SHADOW_MIPS); mip++) {
            Shadow_Map m = shadow_map_mip(whole, mip);
            // A box of what sways changes only the maps whose texel is narrower than its sway.
            uint4 rect;
            if (fine > 0.0 && !(shadow_map_finest(m, low, high) < fine)) continue;
            if (!shadow_page_rect(m, low, high, rect)) continue;
            for (uint y = rect.y; y <= rect.w; y++) {
                for (uint x = rect.x; x <= rect.z; x++) {
                    // Where the cache holds the page and hides the box, the change shows nowhere in it.
                    uint entry = shadow_page_entry(m.rect, uint2(x, y)), e = shadow_table_entry(slot, entry);
                    if ((e & SHADOW_PAGE_CACHED) != 0u && shadow_box_hidden(hiz, m, uint2(x, y), (e & SHADOW_ENTRY_POOL) - 1u, low, high)) continue;
                    mask_set(region, slot, entry);
                }
            }
        }
    } else if (params.step == STEP_ENTRIES) {
        if (i >= SHADOW_SLOTS * SHADOW_SLOT_ENTRIES) return;
        uint slot = i / SHADOW_SLOT_ENTRIES, entry = i % SHADOW_SLOT_ENTRIES;
        Shadow_Map m = shadow_map_at(shadow_data, params.rows, slot);
        uint4 plan = slot_plan(slot);
        // What the table held of the frame before, without where it pointed coarser.
        uint e = params.fresh != 0u ? 0u : shadow_table_entry(slot, entry) & ~((0xFu << SHADOW_ENTRY_COARSER) | SHADOW_PAGE_LEFT);
        uint mip = shadow_entry_mip(entry), n = shadow_mip_pages(mip);
        bool inside = m.rect.z != 0u && mip < (slot < SHADOW_SUN_MAPS ? 1u : SHADOW_MIPS);
        uint2 page = shadow_entry_page(m.rect, entry);
        bool reset = (plan.x & SHADOW_PLAN_RESET) != 0u;
        if (inside && slot < SHADOW_SUN_MAPS && !reset) {
            // A level that moved by whole pages: the columns and the rows that came in held pages that left.
            int2 shift = int2(asint(plan.y), asint(plan.z));
            bool in_x = shift.x > 0 ? int(page.x) >= int(n) - shift.x : int(page.x) < -shift.x;
            bool in_y = shift.y > 0 ? int(page.y) < shift.y : int(page.y) >= int(n) + shift.y;
            reset = in_x || in_y;
        }
        if (reset && (e & SHADOW_ENTRY_POOL) != 0u) {
            pages[SHADOW_WORDS_OWNER + (e & SHADOW_ENTRY_POOL) - 1u] = 0u;
            e = 0u;
        }
        if ((plan.x & SHADOW_PLAN_STALE) != 0u || mask_bit(SHADOW_WORDS_STALE, slot, entry)) e &= ~SHADOW_PAGE_READY;
        if (mask_bit(SHADOW_WORDS_MOVED, slot, entry)) e &= ~SHADOW_PAGE_COMPOSED;
        // The safety net: of a level of the sun the 2x2 pages nearest the eye, of a face its coarsest mip.
        bool net = inside && (plan.x & SHADOW_PLAN_NET) != 0u;
        if (net && slot < SHADOW_SUN_MAPS) {
            uint4 square = uint4(plan.w & 0xFFu, (plan.w >> 8u) & 0xFFu, (plan.w >> 16u) & 0xFFu, plan.w >> 24u);
            net = all(page >= square.xy) && all(page <= square.zw);
        } else if (net) {
            net = mip == SHADOW_MIPS - 1u;
        }
        bool needed = inside && (net || mask_bit(SHADOW_WORDS_NEEDED, slot, entry) || mask_bit(SHADOW_WORDS_LATE, slot, entry));
        if (needed && e == 0u) {
            mask_set(net ? SHADOW_WORDS_FIRST : SHADOW_WORDS_ASKED, slot, entry);
        } else if (needed) {
            uint pool = (e & SHADOW_ENTRY_POOL) - 1u;
            pages[SHADOW_WORDS_AGE + pool] = params.frame;
            bool draw = (e & SHADOW_PAGE_CACHED) == 0u;
            if (draw) listed(ROUND_STAYS, slot, entry, page, pool);
            if (draw || (e & SHADOW_PAGE_COMPOSED) == 0u) listed(ROUND_MOVES, slot, entry, page, pool | SHADOW_JOB_HELD);
            e |= SHADOW_PAGE_READY;
        }
        if (inside && shadow_entry_ready(e)) listed(ROUND_READY, slot, entry, page, 0u);
        table_set(slot, entry, e);
    } else if (params.step == STEP_RANK) {
        // Within each group, the requests of the rank words before each.
        uint bits = countbits(rank_bits(i));
        shared_words[lane] = bits;
        GroupMemoryBarrierWithGroupSync();
        group_scan(lane, ROUND_GROUP);
        if (i < SHADOW_RANK_WORDS) pages[SHADOW_WORDS_RANK + i] = shared_words[lane] - bits;
        if (lane == ROUND_GROUP - 1u && group.x < SHADOW_RANK_GROUPS) pages[SHADOW_WORDS_GROUPS + group.x] = shared_words[lane];
    } else if (params.step == STEP_SUMS) {
        // One group: the requests of the groups before each, and of all.
        uint total = lane < SHADOW_RANK_GROUPS ? pages[SHADOW_WORDS_GROUPS + lane] : 0u;
        shared_words[lane] = total;
        GroupMemoryBarrierWithGroupSync();
        group_scan(lane, ROUND_GROUP);
        if (lane < SHADOW_RANK_GROUPS) pages[SHADOW_WORDS_GROUPS + lane] = shared_words[lane] - total;
        if (lane == ROUND_GROUP - 1u) {
            uint requests = shared_words[lane];
            pages[SHADOW_WORDS_COUNTS + SHADOW_COUNT_REQUESTS] = requests;
            // The pool is sorted and given only while a page was asked for.
            step_args(STEP_POOL, requests > 0u ? 1u : 0u);
            step_args(STEP_ALLOCATE, requests > 0u ? SHADOW_RANK_WORDS : 0u);
        }
    } else if (params.step == STEP_POOL) {
        // One group: each page of the pool by when it may be given, free
        // first, then by how many frames ago a point last read it in powers of
        // two, the longest first, then by its place; those read this frame not
        // at all. Sorted in the group, the same every frame.
        for (uint k = lane; k < POOL_GROUP; k += ROUND_GROUP) {
            uint key = 0xFFFFFFFFu;
            if (k < min(params.pool, SHADOW_POOL_PAGES)) {
                if (pages[SHADOW_WORDS_OWNER + k] == 0u) {
                    key = k;
                } else if (pages[SHADOW_WORDS_AGE + k] != params.frame) {
                    uint unread = min(firstbithigh(params.frame - pages[SHADOW_WORDS_AGE + k]), 15u);
                    key = ((16u - unread) << 16u) | k;
                }
            }
            shared_words[k] = key;
        }
        GroupMemoryBarrierWithGroupSync();
        for (uint size = 2u; size <= POOL_GROUP; size <<= 1u) {
            for (uint stride = size >> 1u; stride > 0u; stride >>= 1u) {
                for (uint pair = lane; pair < POOL_GROUP / 2u; pair += ROUND_GROUP) {
                    uint low = 2u * stride * (pair / stride) + pair % stride, high = low + stride;
                    uint a = shared_words[low], b = shared_words[high];
                    if ((a > b) == ((low & size) == 0u) && a != b) {
                        shared_words[low] = b;
                        shared_words[high] = a;
                    }
                }
                GroupMemoryBarrierWithGroupSync();
            }
        }
        for (uint k = lane; k < POOL_GROUP; k += ROUND_GROUP) {
            uint sorted = shared_words[k], next = k + 1u < POOL_GROUP ? shared_words[k + 1u] : 0xFFFFFFFFu;
            pages[SHADOW_WORDS_VICTIMS + k] = sorted & 0xFFFFu;
            if (k == 0u && sorted == 0xFFFFFFFFu) pages[SHADOW_WORDS_COUNTS + SHADOW_COUNT_GIVEN] = 0u;
            if (k == 0u && sorted >= 0x10000u) pages[SHADOW_WORDS_COUNTS + SHADOW_COUNT_FREE] = 0u;
            if (sorted != 0xFFFFFFFFu && next == 0xFFFFFFFFu) pages[SHADOW_WORDS_COUNTS + SHADOW_COUNT_GIVEN] = k + 1u;
            if (sorted < 0x10000u && next >= 0x10000u) pages[SHADOW_WORDS_COUNTS + SHADOW_COUNT_FREE] = k + 1u;
        }
    } else if (params.step == STEP_ALLOCATE) {
        uint bits = rank_bits(i);
        if (bits == 0u) return;
        uint3 w = rank_word(i);
        uint rank = pages[SHADOW_WORDS_GROUPS + i / ROUND_GROUP] + pages[SHADOW_WORDS_RANK + i];
        uint given = pages[SHADOW_WORDS_COUNTS + SHADOW_COUNT_GIVEN];
        Shadow_Map m = shadow_map_at(shadow_data, params.rows, w.y);
        for (; bits != 0u; bits &= bits - 1u, rank++) {
            uint entry = w.z * 32u + firstbitlow(bits);
            if (rank >= given) {
                InterlockedAdd(pages[SHADOW_WORDS_COUNTS + SHADOW_COUNT_LEFT], 1u);
                table_set(w.y, entry, SHADOW_PAGE_LEFT);
                continue;
            }
            uint pool = pages[SHADOW_WORDS_VICTIMS + rank];
            uint owner = pages[SHADOW_WORDS_OWNER + pool];
            if (owner != 0u) table_set((owner - 1u) / SHADOW_SLOT_ENTRIES, (owner - 1u) % SHADOW_SLOT_ENTRIES, 0u);
            pages[SHADOW_WORDS_OWNER + pool] = w.y * SHADOW_SLOT_ENTRIES + entry + 1u;
            pages[SHADOW_WORDS_AGE + pool] = params.frame;
            uint2 page = shadow_entry_page(m.rect, entry);
            // A slot that let go of every page draws it whole into the atlas alone.
            bool whole = (slot_plan(w.y).x & SHADOW_PLAN_RESET) != 0u;
            table_set(w.y, entry, (pool + 1u) | (whole ? SHADOW_PAGE_COMPOSED : SHADOW_PAGE_READY));
            if (!whole) listed(ROUND_STAYS, w.y, entry, page, pool);
            listed(ROUND_MOVES, w.y, entry, page, pool | (whole ? 0u : SHADOW_JOB_HELD));
            listed(ROUND_READY, w.y, entry, page, 0u);
        }
    } else if (params.step == STEP_PROPAGATE) {
        if (i >= SHADOW_SLOTS * SHADOW_SLOT_ENTRIES) return;
        uint slot = i / SHADOW_SLOT_ENTRIES, entry = i % SHADOW_SLOT_ENTRIES;
        uint e = shadow_table_entry(slot, entry);
        if (shadow_entry_ready(e)) return;
        Shadow_Map m = shadow_map_at(shadow_data, params.rows, slot);
        uint mip = shadow_entry_mip(entry);
        if (m.rect.z == 0u || mip >= (slot < SHADOW_SUN_MAPS ? 1u : SHADOW_MIPS)) return;
        uint2 page = shadow_entry_page(m.rect, entry);
        uint coarser = 0u;
        if (slot < SHADOW_SUN_MAPS) {
            // The page of each coarser level that holds this one, by the grid of the world.
            int2 first = sun_first_page(m);
            int2 world = int2(first.x + int(page.x), first.y + int(SHADOW_MAP_PAGES) - 1 - int(page.y));
            for (uint j = 1u; slot + j < params.sun && coarser == 0u; j++) {
                Shadow_Map c = shadow_map_at(shadow_data, params.rows, slot + j);
                int2 held = sun_first_page(c), at = world >> int(j);
                int2 p = int2(at.x - held.x, held.y + int(SHADOW_MAP_PAGES) - 1 - at.y);
                if (any(p < 0) || any(p >= int(SHADOW_MAP_PAGES))) continue;
                if (shadow_entry_ready(shadow_table_entry(slot + j, shadow_page_entry(c.rect, uint2(p))))) coarser = j;
            }
        } else {
            for (uint j = 1u; mip + j < SHADOW_MIPS && coarser == 0u; j++) {
                if (shadow_entry_ready(shadow_table_entry(slot, shadow_page_entry(shadow_map_mip(m, mip + j).rect, page >> j)))) coarser = j;
            }
        }
        if (coarser != 0u) table_set(slot, entry, e | (coarser << SHADOW_ENTRY_COARSER));
    } else if (i == 0u) {
        uint groups[3] = {params.groups_stays, params.groups_moves, params.groups_glass};
        for (uint round = 0u; round < 3u; round++) {
            uint at = SHADOW_WORDS_ARGS + SHADOW_ARGS_DISPATCH + 3u * round;
            uint slots = pages[SHADOW_WORDS_COUNTS + SHADOW_COUNT_SLOTS + round];
            pages[at] = slots > 0u ? groups[round] : 0u;
            pages[at + 1u] = slots;
            pages[at + 2u] = 1u;
        }
        uint hiz = SHADOW_WORDS_ARGS + SHADOW_ARGS_HIZ;
        pages[hiz] = min(pages[SHADOW_WORDS_COUNTS + SHADOW_COUNT_DRAWN], SHADOW_POOL_PAGES);
        pages[hiz + 1u] = 1u;
        pages[hiz + 2u] = 1u;
        for (uint round = 0u; round < 2u; round++) {
            uint at = SHADOW_WORDS_ARGS + SHADOW_ARGS_DRAW + 4u * round;
            pages[at] = 6u;
            pages[at + 1u] = min(pages[SHADOW_WORDS_COUNTS + (round == 0u ? SHADOW_COUNT_DRAWN : SHADOW_COUNT_COMPOSED)], SHADOW_POOL_PAGES);
            pages[at + 2u] = 0u;
            pages[at + 3u] = 0u;
        }
    }
}
