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
//   changed (render.Shadow_Plan boxes), and of each page the cache holds
//   where what stays changed, the texels the box covers, which are all the
//   cache draws of it again (SHADOW_WORDS_PART);
// - Ancestors, a thread for each entry of each slot in use: of a page a point
//   or a pass after the maps reads, the page of each level of the sun or mip
//   coarser that holds it and the eight around that one are asked for too,
//   so that they rank sooner and a page the pool leaves out or that waits has
//   a coarser one drawn, with the pages around it, to stand for it;
// - Entries, a thread for each entry of each slot in use: lets go of the page of
//   the pool of what the plan says (render.Shadow_Slot_Plan), forgets what
//   stays or what moves where they changed, and of a page a point reads, the
//   frame before read late, or the safety net keeps: asks for a page of the
//   pool where it has none, else lists it for the cache to draw where what
//   stays is not drawn there and for the atlas to compose where that is not,
//   or where it holds a batch that sways there (SHADOW_JOB_REFRESH);
//   a slot that lets go of every page (a light that turned or moved) draws
//   them whole into the atlas alone that frame, and the cache the next;
// - Rank and Sums: the rank of each page asked for, in one order every frame
//   (SHADOW_RANK_WORDS: the safety net first, the coarsest first);
// - Pool, one group while a page was asked for: the pages of the pool that can be given, free first,
//   then those no point read for a cycle of the jitter of the view, the
//   longest unread first, then those read within the cycle, the last in the
//   order of the ranks first, which a page takes only where it ranks sooner:
//   a page the points of one frame of the cycle miss and those of the next
//   read keeps its place where the pool is full; while one of them stands in
//   the way, the steps run again the next frame;
// - Allocate, a thread for each word of the ranks: each page asked for takes
//   the page of the pool of its rank, which its entry lets go of; past them it
//   is left out;
// - Finish, one group: the arguments of the culls and the draws of the
//   rounds: each cull by instance goes over the slots with pages listed, those
//   it left out the most frames in a row first, then the coarsest (the levels
//   of the sun from the coarsest, then the faces of the lights), while the
//   threads of the instances that reach them (render.Shadow_Reach) fit those
//   of a frame (Params_Block.threads), one slot at least; the foresight of the
//   cache over those of them with pages not foreseen yet; the pages of a slot
//   past them wait for the frames after, and no slot waits on the others for
//   long;
// - Grant, one group, for the cache and then for the atlas (Params_Block.round)
//   between the cull by instance and the cull by cluster of the round: of the
//   pages it lists of the slots Finish kept, those its points read drawn the
//   frame before first, then in the order the pages are given, then those of
//   the atlas composed again for what sways in them alone, the latest first
//   and those nearest the eye sooner (refresh_order), those whose units of
//   raster work fit a share of those of a frame (Params_Block.budget) with
//   those before: what a page
//   took the last time the round drew it (SHADOW_WORDS_KNOWN), else what the
//   cull by instance foresees, scaled by what the draws took of that before
//   (SHADOW_WORDS_SCALE); a page of the atlas that came only where its quota
//   leaves room for those kept to take more the frame after. Each may take
//   twice that, so that a page that takes more than it was granted for is
//   the only one left over; the others wait for the frames after
//   (SHADOW_COST_WAITS) and the round draws nothing of them. A page of the
//   cache that takes more than its share is drawn in bands of its rows over
//   frames, halved until one fits (SHADOW_WORDS_BAND);
// - Settle, a thread for each page the round lists, after its cull by
//   cluster: a page not drawn whole this frame (waiting, a band before its
//   last, or one that took more than it may) is not ready, and the steps run
//   again the next frame, but a page of the atlas that waits to be composed
//   again for what sways in it alone shows what the atlas last composed there;
//   a page the atlas composed holds what sways where the cull found it there,
//   and the steps run again the next frame while one does;
// - Propagate, a thread for each entry of each slot in use, after the rounds:
//   where its page is not drawn, how many levels of the sun or mips coarser
//   the nearest one drawn lies, which its taps read; of a page a point reads,
//   the nearest drawn, its own or coarser, whose eight pages around all hold
//   something a tap reads, which holds the point (SHADOW_ENTRY_HELD), or none,
//   where the point traces; and the scale of what is foreseen.
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
void table_set(uint slot, uint entry, uint e) { if (shadow_place_valid(slot, entry)) table[int2(int(entry), int(slot))] = e; }
#include "shadow_maps.slang"

// step; frame: counts the frames; rows: of the words of the lights in the
// buffer of the maps; plan, boxes: the words of it the plans of the slots and
// the boxes of what changed start at, boxes and levels of the sun of them;
// pool: the pages of the pool it may give; reach: the word of the buffer of
// the maps what the culls by instance of each slot go over starts at
// (render.Shadow_Reach); threads: what each cull by instance of a frame runs
// at most, one slot at least; fresh: the table holds nothing yet; full: the view, a light or a caster
// changed, and the masks were cleared before the marks; slots: the word of
// the buffer of the maps the slots in use start at, slot_count of them (those
// with a map or that let go of their pages: the others hold no page),
// every slot while the table holds nothing yet (fresh); keep: the frames of
// a cycle of the jitter of the view, which a page no point read keeps its
// place for from the pages that rank no sooner; budget: the units the draws
// of the cache, and those of the atlas, take in a frame (shadow_units); round: 0 the
// cache, 1 the atlas, for Grant and Settle; chunks: what the list of the
// chunks of the cull holds (render.Cull_List.Shadow_Chunks); moves: the
// round of what moves runs this frame (something moves in a map, or a slot
// lets go of every page); sway: the texel the view takes of a point at the
// reach of what sways in the maps (render.shadow_sway_texel).
struct Params_Block { uint step; uint frame; uint rows; uint plan; uint boxes; uint box_count; uint sun; uint pool; uint reach; uint threads; uint fresh; uint full; uint slots; uint slot_count; uint keep; uint budget; uint round; uint chunks; uint moves; float sway; };
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
#define STEP_ANCESTORS 3u
#define STEP_ENTRIES 4u
#define STEP_RANK 5u
#define STEP_SUMS 6u
#define STEP_POOL 7u
#define STEP_ALLOCATE 8u
#define STEP_PROPAGATE 9u
#define STEP_FINISH 10u
#define STEP_GRANT 11u
#define STEP_SETTLE 12u
// What the steps write again each time they run without a change, the masks of the marks kept.
#define CLEAR_WORDS (SHADOW_WORDS_SLOTS - SHADOW_WORDS_STALE)
#define ROUND_STAYS 0u
#define ROUND_MOVES 1u
// The pages the cache draws whose clusters are not foreseen yet.
#define ROUND_FORESEE 2u
#define ROUND_GROUP 256u
#define POOL_GROUP 1024u
// The key of a page of the pool read within the cycle of the jitter.
#define POOL_KEPT 0x40000000u
// Of the key of a page a round grants: its points did not read it drawn the frame before;
// its slot is past the threads of the culls by instance of the frame, and it waits.
// its points read it drawn the frame before and what sways in it is all it
// is composed again for (SHADOW_JOB_REFRESH);
#define KEY_NEW 0x4000000u
#define KEY_REFRESH 0x8000000u
#define KEY_WAITS 0x10000000u
// The threads of a group of shadow_maps.comp.
#define CULL_GROUP 256u
// The pages a round grants fill 1/GRANT_SHARE of the bound with what they are
// foreseen to take; each may take twice that.
#define GRANT_SHARE 2u
// A page not drawn yet takes at most 1/GRANT_GUESS of that share.
#define GRANT_GUESS 32u
// A page of the atlas its points did not read drawn the frame before is
// granted only where twice what it is granted for, the most it may take,
// fits the share less 1/GRANT_NEW of it: the frame after, what the pages kept
// took still fits the share when what moves in them takes a little more, and
// none of them is left over for a page that came.
#define GRANT_NEW 4u
// The least a page of the atlas that takes units is granted for: what
// moves in it may cover a few more the frame after.
#define GRANT_LEAST 32u

groupshared uint shared_words[POOL_GROUP];
groupshared uint shared_costs[POOL_GROUP];
groupshared uint shared_sums[ROUND_GROUP];
groupshared uint shared_reach[POOL_GROUP];
groupshared uint shared_reach_sums[ROUND_GROUP];
groupshared uint shared_slots[ROUND_GROUP];

// The arguments of the dispatch of a step over a number of threads.
void step_args(uint step, uint threads) {
    uint at = SHADOW_WORDS_STEPS + 3u * step;
    pages[at] = (threads + ROUND_GROUP - 1u) / ROUND_GROUP;
    pages[at + 1u] = 1u;
    pages[at + 2u] = 1u;
}

uint data_word(uint word) { return shadow_data[word >> 2u][word & 3u]; }
// The threads of the cull by instance of a list of a slot (render.Shadow_Reach):
// of what stays (round 0) or what moves (round 1).
uint reach_threads(uint slot, uint list) { return data_word(params.reach + slot * SHADOW_REACH_WORDS + list * 3u + 2u); }
// The slot of rank k in the culls by instance: the levels of the sun from the
// coarsest, then the faces of the lights (render.shadow_slot_rank).
uint slot_by_rank(uint k) { return k < SHADOW_SUN_MAPS ? SHADOW_SUN_MAPS - 1u - k : k; }
// The word the slots a cull by instance goes over start at: of what stays,
// of what moves, and the foresight of what stays.
uint work_list(uint dispatch) { return SHADOW_WORDS_SLOTS + dispatch * (SHADOW_SLOTS + 1u); }
// The arguments of a cull by instance over some threads, in rows of
// SHADOW_CULL_ROW groups, which the threads of the frame count where it runs
// (the cull of what stays runs over the slots of Grant alone).
void cull_args(uint dispatch, uint threads, bool runs) {
    uint at = SHADOW_WORDS_ARGS + SHADOW_ARGS_DISPATCH + 3u * dispatch, groups = (threads + CULL_GROUP - 1u) / CULL_GROUP;
    pages[at] = min(groups, SHADOW_CULL_ROW);
    pages[at + 1u] = (groups + SHADOW_CULL_ROW - 1u) / SHADOW_CULL_ROW;
    pages[at + 2u] = 1u;
    if (runs) InterlockedAdd(pages[SHADOW_WORDS_COUNTS + SHADOW_COUNT_THREADS], threads);
}
// The slots in use, and the k-th of them: every slot while the table holds nothing yet.
uint slots_in_use() { return params.fresh != 0u ? SHADOW_SLOTS : params.slot_count; }
uint slot_in_use(uint k) { return params.fresh != 0u ? k : data_word(params.slots + k); }
uint4 slot_plan(uint slot) { return shadow_data[(params.plan >> 2u) + slot]; }
bool mask_bit(uint region, uint slot, uint entry) { return shadow_place_valid(slot, entry) && ((pages[region + slot * SHADOW_MASK_WORDS + (entry >> 5u)] >> (entry & 31u)) & 1u) != 0u; }
void mask_set(uint region, uint slot, uint entry) {
    if (!shadow_place_valid(slot, entry)) return;
    uint word = region + slot * SHADOW_MASK_WORDS + (entry >> 5u), bit = 1u << (entry & 31u);
    if ((pages[word] & bit) == 0u) InterlockedOr(pages[word], bit);
}
// The texels of a page of the pool the cache draws this frame: the rows of
// its band (SHADOW_WORDS_BAND), all of them where it is drawn whole.
void part_band(uint pool) {
    if (pool >= SHADOW_POOL_PAGES) return;
    uint band = pages[SHADOW_WORDS_BAND + pool], first = band & 0xFFu, at = SHADOW_WORDS_PART + pool * 4u;
    pages[at] = SHADOW_PAGE;
    pages[at + 1u] = SHADOW_PAGE - first;
    pages[at + 2u] = SHADOW_PAGE;
    pages[at + 3u] = min(first + (SHADOW_PAGE >> ((band >> SHADOW_BAND_SHIFT) & 0xFFu)), SHADOW_PAGE);
}

// Of the round of Grant and Settle: its pages listed, how many, the mask of
// the pages it draws, and the word of what it draws into a page of the pool.
uint round_jobs() { return SHADOW_WORDS_JOBS + params.round * SHADOW_POOL_PAGES; }
uint round_count() { return min(pages[SHADOW_WORDS_COUNTS + (params.round == 0u ? SHADOW_COUNT_DRAWN : SHADOW_COUNT_COMPOSED)], SHADOW_POOL_PAGES); }
uint round_mask() { return params.round == 0u ? SHADOW_WORDS_DRAWN : SHADOW_WORDS_COMPOSE; }
uint round_cost(uint pool) { return SHADOW_WORDS_COST + params.round * SHADOW_POOL_PAGES + pool; }
uint round_taken(uint pool) { return SHADOW_WORDS_TAKEN + params.round * SHADOW_POOL_PAGES + pool; }
uint round_known(uint pool) { return SHADOW_WORDS_KNOWN + params.round * SHADOW_POOL_PAGES + pool; }
// A page of the atlas whose cache waits: the atlas composes nothing of it this frame.
bool round_idle(uint pool) {
    uint slot, entry;
    return params.round == 1u && (!shadow_owner_place(pages[SHADOW_WORDS_OWNER + pool], slot, entry) || !mask_bit(SHADOW_WORDS_COMPOSE, slot, entry));
}

// The first word of the masks of the pages asked for that the pages of the
// level of the sun of a page, or of its word of the faces, rank in past the
// safety net (rank_word): a page asked for in a word before it ranks sooner
// than every page of that level.
uint rank_of(uint slot, uint entry) {
    if (slot < SHADOW_SUN_MAPS) return SHADOW_RANK_FIRST + (SHADOW_SUN_MAPS - 1u - slot) * SHADOW_SUN_WORDS;
    return SHADOW_RANK_FIRST + SHADOW_SUN_MAPS * SHADOW_SUN_WORDS + (entry >> 5u) * SHADOW_LOCAL_SLOTS;
}

// Of a page of the atlas composed again for what sways in it alone, its
// place among the others in Grant, the first the soonest: by how many frames
// ago the atlas last composed it (SHADOW_WORDS_SWAY) less a frame for each
// REFRESH_NEARER levels of the sun or mips it lies coarser, and then nearest
// the eye first. Each frame it waits it comes sooner, so none waits on the
// others longer than they take to be composed once, and those nearest the
// eye, larger on the screen, are composed a little more often.
#define REFRESH_NEARER 4u
uint refresh_order(uint slot, uint entry, uint sway) {
    uint coarser = slot < SHADOW_SUN_MAPS ? slot : shadow_entry_mip(entry);
    uint age = (params.frame - sway) & SHADOW_SWAY_FRAME;
    uint late = min(age + 8u - min(coarser / REFRESH_NEARER, 8u), 0xFFFu);
    return ((0xFFFu - late) << 4u) | min(coarser, 15u);
}

// A page of a slot in a round: its bit, its slot listed once, the pages of
// each of its mips it spans, and its page of the pool listed to draw, of the
// atlas with SHADOW_JOB_HELD where the cache holds it this frame.
void listed(uint round, uint slot, uint entry, uint2 page, uint job) {
    if (!shadow_place_valid(slot, entry) || (job & SHADOW_ENTRY_POOL) >= SHADOW_POOL_PAGES) return;
    // What the cull by instance foresees it hands over for the page starts anew.
    if (round != ROUND_STAYS) pages[SHADOW_WORDS_REACH + (round == ROUND_MOVES ? SHADOW_POOL_PAGES : 0u) + (job & SHADOW_ENTRY_POOL)] = 0u;
    // Whether what sways shows in it is found anew by the cull of the atlas.
    if (round == ROUND_MOVES) pages[SHADOW_WORDS_SWAY + (job & SHADOW_ENTRY_POOL)] &= ~SHADOW_SWAY_NOW;
    uint masks[3] = {SHADOW_WORDS_DRAWN, SHADOW_WORDS_COMPOSE, SHADOW_WORDS_FORESEE};
    InterlockedOr(pages[masks[round] + slot * SHADOW_MASK_WORDS + (entry >> 5u)], 1u << (entry & 31u));
    uint mip = shadow_entry_mip(entry);
    uint span = SHADOW_WORDS_BOUNDS + ((round * SHADOW_SLOTS + slot) * SHADOW_MIPS + mip) * 4u;
    InterlockedMax(pages[span], SHADOW_MAP_PAGES - page.x);
    InterlockedMax(pages[span + 1u], SHADOW_MAP_PAGES - page.y);
    InterlockedMax(pages[span + 2u], page.x + 1u);
    InterlockedMax(pages[span + 3u], page.y + 1u);
    uint has = SHADOW_WORDS_HAS + round * SHADOW_SLOTS + slot;
    if (pages[has] == 0u) pages[has] = 1u;
    if (round == ROUND_FORESEE) return;
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

// The mips of a slot: a level of the sun has its finest alone.
uint slot_mips(uint slot) { return slot < SHADOW_SUN_MAPS ? 1u : SHADOW_MIPS; }

// Whether a point or a pass after the maps reads an entry.
bool entry_read(uint slot, uint entry) { return mask_bit(SHADOW_WORDS_NEEDED, slot, entry) || mask_bit(SHADOW_WORDS_LATE, slot, entry); }

// How many levels or mips coarser a page stands for another at most: the
// four bits of SHADOW_ENTRY_COARSER and SHADOW_ENTRY_HELD.
#define SHADOW_COARSER_MOST 15u
// How many levels or mips coarser than its own a page holds a point at most,
// and the coarser pages a page read asks for: one with texels wider than
// that tells too little of what hides the point, which then traces.
#define SHADOW_HELD_COARSER 2u

// The page of the level of the sun or the mip j coarser than a page of a slot
// at a mip that holds it, the levels by the grid of the world: its slot, its
// map at that mip and its page; false past the levels or the mips, or past
// its square.
bool page_coarser(uint slot, uint mip, uint2 page, uint j, out uint at_slot, out Shadow_Map c, out int2 p) {
    at_slot = slot;
    p = int2(page >> j);
    if (slot < SHADOW_SUN_MAPS) {
        at_slot = min(slot + j, SHADOW_SUN_MAPS - 1u);
        c = shadow_map_at(shadow_data, params.rows, at_slot);
        if (slot + j >= params.sun) return false;
        int2 first = sun_first_page(shadow_map_at(shadow_data, params.rows, slot)), held = sun_first_page(c);
        int2 world = int2(first.x + int(page.x), first.y + int(SHADOW_MAP_PAGES) - 1 - int(page.y)) >> int(j);
        p = int2(world.x - held.x, held.y + int(SHADOW_MAP_PAGES) - 1 - world.y);
    } else {
        c = shadow_map_mip(shadow_map_at(shadow_data, params.rows, slot), min(mip + j, SHADOW_MIPS - 1u));
        if (mip + j >= SHADOW_MIPS) return false;
    }
    return c.rect.z != 0u && all(p >= 0) && all(p < int(shadow_mip_pages(shadow_rect_mip(c.rect))));
}

// How many levels of the sun or mips coarser the nearest page drawn that
// holds a page lies; 0: none.
uint coarser_drawn(uint slot, uint mip, uint2 page) {
    uint at_slot;
    Shadow_Map c;
    int2 p;
    for (uint j = 1u; j < SHADOW_COARSER_MOST && page_coarser(slot, mip, page, j, at_slot, c, p); j++) {
        if (shadow_entry_ready(shadow_table_entry(at_slot, shadow_page_entry(c.rect, uint2(p))))) return j;
    }
    return 0u;
}

// Whether each page of map m around a page of it, at its mip, is drawn or
// held by a coarser one drawn, so that every tap of a point the page holds
// reads a blocker; past the square of the map a tap reads the face beside,
// or nothing.
bool around_read(uint slot, Shadow_Map m, int2 page) {
    uint mip = shadow_rect_mip(m.rect);
    int n = int(shadow_mip_pages(mip));
    for (int y = max(page.y - 1, 0); y <= min(page.y + 1, n - 1); y++) {
        for (int x = max(page.x - 1, 0); x <= min(page.x + 1, n - 1); x++) {
            if (all(int2(x, y) == page) || shadow_entry_ready(shadow_table_entry(slot, shadow_page_entry(m.rect, uint2(x, y))))) continue;
            if (coarser_drawn(slot, mip, uint2(x, y)) == 0u) return false;
        }
    }
    return true;
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
        uint all = run ? slots_in_use() * SHADOW_SLOT_ENTRIES : 0u;
        step_args(STEP_CLEAR, run && params.full == 0u ? CLEAR_WORDS : 0u);
        step_args(STEP_INVALIDATE, run ? params.box_count * SHADOW_SLOTS : 0u);
        step_args(STEP_ANCESTORS, all);
        step_args(STEP_ENTRIES, all);
        step_args(STEP_RANK, run ? SHADOW_RANK_WORDS : 0u);
        step_args(STEP_SUMS, run ? 1u : 0u);
        step_args(STEP_POOL, 0u);
        step_args(STEP_ALLOCATE, 0u);
        step_args(STEP_PROPAGATE, all);
        step_args(STEP_FINISH, run ? 1u : 0u);
        step_args(STEP_GRANT, run ? 1u : 0u);
        step_args(STEP_SETTLE, run ? SHADOW_POOL_PAGES : 0u);
        if (run) return;
        // A still view: the rounds of what stays and of what moves draw nothing.
        uint counts[8] = {SHADOW_COUNT_DRAWN, SHADOW_COUNT_COMPOSED, SHADOW_COUNT_REQUESTS, SHADOW_COUNT_LEFT, SHADOW_COUNT_WAITING, SHADOW_COUNT_SHORT, SHADOW_COUNT_THREADS, SHADOW_COUNT_REFRESHED};
        for (uint k = 0u; k < 8u; k++) pages[SHADOW_WORDS_COUNTS + counts[k]] = 0u;
        for (uint round = 0u; round < 3u; round++) pages[SHADOW_WORDS_ARGS + SHADOW_ARGS_DISPATCH + 3u * round] = 0u;
        for (uint round = 0u; round < 2u; round++) {
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
            // A box of what sways changes only the maps that draw it as it sways.
            float4 texels;
            if (fine > 0.0 && !shadow_map_sways(m, low, high, fine, params.sway)) continue;
            if (!shadow_box_texels(m, low, high, texels)) continue;
            uint4 rect = shadow_texel_pages(m, texels);
            for (uint y = rect.y; y <= rect.w; y++) {
                for (uint x = rect.x; x <= rect.z; x++) {
                    // Where the cache holds the page and hides the box, the change shows
                    // nowhere in it. A table that holds nothing yet holds no page: what
                    // its texels hold before the entries are written is not an entry.
                    uint entry = shadow_page_entry(m.rect, uint2(x, y)), e = params.fresh != 0u ? 0u : shadow_table_entry(slot, entry), pool;
                    bool cached = (e & SHADOW_PAGE_CACHED) != 0u && shadow_entry_pool(e, pool);
                    if (cached && shadow_box_hidden(hiz, m, uint2(x, y), pool, low, high)) continue;
                    mask_set(region, slot, entry);
                    if (region != SHADOW_WORDS_STALE || !cached) continue;
                    // The texels of the page the box covers, and one around them.
                    float4 at = texels - float4(uint2(x, y) * SHADOW_PAGE, uint2(x, y) * SHADOW_PAGE);
                    uint2 first = uint2(clamp(floor(at.xy) - 1.0, 0.0, float(SHADOW_PAGE - 1u))), last = uint2(clamp(floor(at.zw) + 1.0, 0.0, float(SHADOW_PAGE - 1u)));
                    uint part = SHADOW_WORDS_PART + pool * 4u;
                    InterlockedMax(pages[part], SHADOW_PAGE - first.x);
                    InterlockedMax(pages[part + 1u], SHADOW_PAGE - first.y);
                    InterlockedMax(pages[part + 2u], last.x + 1u);
                    InterlockedMax(pages[part + 3u], last.y + 1u);
                }
            }
        }
    } else if (params.step == STEP_ANCESTORS) {
        if (i >= slots_in_use() * SHADOW_SLOT_ENTRIES) return;
        uint slot = slot_in_use(i / SHADOW_SLOT_ENTRIES), entry = i % SHADOW_SLOT_ENTRIES;
        if (slot >= SHADOW_SLOTS || !entry_read(slot, entry)) return;
        Shadow_Map m = shadow_map_at(shadow_data, params.rows, slot);
        uint mip = shadow_entry_mip(entry);
        if (m.rect.z == 0u || mip >= slot_mips(slot)) return;
        uint2 page = shadow_entry_page(m.rect, entry);
        uint at_slot;
        Shadow_Map c;
        int2 p;
        for (uint j = 1u; j <= SHADOW_HELD_COARSER && page_coarser(slot, mip, page, j, at_slot, c, p); j++) {
            int n = int(shadow_mip_pages(shadow_rect_mip(c.rect)));
            for (int y = max(p.y - 1, 0); y <= min(p.y + 1, n - 1); y++) {
                for (int x = max(p.x - 1, 0); x <= min(p.x + 1, n - 1); x++) mask_set(SHADOW_WORDS_ANCESTORS, at_slot, shadow_page_entry(c.rect, uint2(x, y)));
            }
        }
    } else if (params.step == STEP_ENTRIES) {
        if (i >= slots_in_use() * SHADOW_SLOT_ENTRIES) return;
        uint slot = slot_in_use(i / SHADOW_SLOT_ENTRIES), entry = i % SHADOW_SLOT_ENTRIES;
        if (slot >= SHADOW_SLOTS) return;
        Shadow_Map m = shadow_map_at(shadow_data, params.rows, slot);
        uint4 plan = slot_plan(slot);
        // What the table held of the frame before, without where it pointed
        // coarser; an entry that names no page of the pool holds none.
        uint e = params.fresh != 0u ? 0u : shadow_table_entry(slot, entry) & ~((0xFu << SHADOW_ENTRY_COARSER) | (0xFu << SHADOW_ENTRY_HELD) | SHADOW_PAGE_LEFT), held;
        if (!shadow_entry_pool(e, held)) e = 0u;
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
        if (reset && e != 0u) {
            pages[SHADOW_WORDS_OWNER + held] = 0u;
            e = 0u;
        }
        // Its points read it drawn the frame before: the rounds grant it first.
        uint kept = (e & SHADOW_PAGE_COMPOSED) != 0u ? SHADOW_JOB_KEPT : 0u;
        // Where the cache holds the page and what stays changed in boxes, it draws their part of it alone.
        bool part = (e & SHADOW_PAGE_CACHED) != 0u && (plan.x & SHADOW_PLAN_STALE) == 0u;
        bool stale = (plan.x & SHADOW_PLAN_STALE) != 0u || mask_bit(SHADOW_WORDS_STALE, slot, entry);
        if (stale) e &= ~SHADOW_PAGE_READY;
        if (mask_bit(SHADOW_WORDS_MOVED, slot, entry)) e &= ~SHADOW_PAGE_COMPOSED;
        // The safety net: of a level of the sun the 2x2 pages nearest the eye, of a face its coarsest mip.
        bool net = inside && (plan.x & SHADOW_PLAN_NET) != 0u;
        if (net && slot < SHADOW_SUN_MAPS) {
            uint4 square = uint4(plan.w & 0xFFu, (plan.w >> 8u) & 0xFFu, (plan.w >> 16u) & 0xFFu, plan.w >> 24u);
            net = all(page >= square.xy) && all(page <= square.zw);
        } else if (net) {
            net = mip == SHADOW_MIPS - 1u;
        }
        bool needed = inside && (net || entry_read(slot, entry) || mask_bit(SHADOW_WORDS_ANCESTORS, slot, entry));
        if (needed && e == 0u) {
            mask_set(net ? SHADOW_WORDS_FIRST : SHADOW_WORDS_ASKED, slot, entry);
        } else if (needed) {
            uint pool = held;
            pages[SHADOW_WORDS_AGE + pool] = params.frame;
            bool draw = (e & SHADOW_PAGE_CACHED) == 0u;
            // A page drawn in bands under what changed starts again from its
            // first row; one drawn in part is drawn in one frame.
            uint band = pages[SHADOW_WORDS_BAND + pool];
            pages[SHADOW_WORDS_BAND + pool] = part ? 0u : stale ? band & ~(0xFFu | SHADOW_BAND_STUCK) : band;
            if (part) pages[SHADOW_WORDS_KNOWN + pool] = 0u;
            if (draw && !part) part_band(pool);
            if (draw) listed(ROUND_STAYS, slot, entry, page, pool | kept);
            if (draw && pages[SHADOW_WORDS_KNOWN + pool] == 0u) listed(ROUND_FORESEE, slot, entry, page, pool);
            if (draw || (e & SHADOW_PAGE_COMPOSED) == 0u) listed(ROUND_MOVES, slot, entry, page, pool | SHADOW_JOB_HELD | kept);
            else if ((pages[SHADOW_WORDS_SWAY + pool] & SHADOW_SWAY_SWAYS) != 0u && params.moves != 0u) listed(ROUND_MOVES, slot, entry, page, pool | SHADOW_JOB_HELD | SHADOW_JOB_REFRESH);
            // Where nothing moves, nothing sways in it.
            if (params.moves == 0u) pages[SHADOW_WORDS_SWAY + pool] &= ~SHADOW_SWAY_SWAYS;
            e |= SHADOW_PAGE_READY;
        }
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
        // two, the longest first, then by its place; then those read within a
        // cycle of the jitter, the last in the order of the ranks first; those
        // read this frame not at all. Sorted in the group, the same every frame.
        for (uint k = lane; k < POOL_GROUP; k += ROUND_GROUP) {
            uint key = 0xFFFFFFFFu;
            if (k < min(params.pool, SHADOW_POOL_PAGES)) {
                uint unread = params.frame - pages[SHADOW_WORDS_AGE + k], slot, entry;
                // An owner past the table names no page: its page of the pool is free.
                if (!shadow_owner_place(pages[SHADOW_WORDS_OWNER + k], slot, entry)) {
                    key = k;
                } else if (unread >= params.keep) {
                    key = ((16u - min(firstbithigh(unread), 15u)) << 16u) | k;
                } else if (unread != 0u) {
                    key = POOL_KEPT | ((0xFFFFu - rank_of(slot, entry)) << 12u) | k;
                    // Once the cycle is over any page may take it: those left out ask again then.
                    pages[SHADOW_STEP_NEW] = 1u;
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
            // Its page, and from bit 16 of one read within the cycle the word its level ranks from + 1.
            bool kept = sorted >= POOL_KEPT && sorted != 0xFFFFFFFFu;
            pages[SHADOW_WORDS_VICTIMS + k] = kept ? (sorted & 0xFFFu) | ((0x10000u - ((sorted >> 12u) & 0xFFFFu)) << 16u) : sorted & 0xFFFFu;
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
            // Past the pool, or where the page of its rank was read within the
            // cycle of the jitter and is of a level that ranks no later, it is left out.
            uint victim = rank < given ? pages[SHADOW_WORDS_VICTIMS + rank] : 0u;
            if (rank >= given || ((victim >> 16u) != 0u && i + 1u >= (victim >> 16u))) {
                InterlockedAdd(pages[SHADOW_WORDS_COUNTS + SHADOW_COUNT_LEFT], 1u);
                table_set(w.y, entry, SHADOW_PAGE_LEFT);
                continue;
            }
            uint pool = victim & 0xFFFFu, slot, held;
            if (pool >= SHADOW_POOL_PAGES) continue;
            uint owner = pages[SHADOW_WORDS_OWNER + pool];
            if (shadow_owner_place(owner, slot, held)) table_set(slot, held, 0u);
            pages[SHADOW_WORDS_OWNER + pool] = w.y * SHADOW_SLOT_ENTRIES + entry + 1u;
            pages[SHADOW_WORDS_AGE + pool] = params.frame;
            uint2 page = shadow_entry_page(m.rect, entry);
            // A slot that let go of every page draws it whole into the atlas alone.
            bool whole = (slot_plan(w.y).x & SHADOW_PLAN_RESET) != 0u;
            table_set(w.y, entry, (pool + 1u) | (whole ? SHADOW_PAGE_COMPOSED : SHADOW_PAGE_READY));
            pages[SHADOW_WORDS_BAND + pool] = 0u;
            pages[SHADOW_WORDS_KNOWN + pool] = 0u;
            pages[SHADOW_WORDS_KNOWN + SHADOW_POOL_PAGES + pool] = 0u;
            pages[SHADOW_WORDS_SWAY + pool] = params.frame & SHADOW_SWAY_FRAME;
            if (!whole) part_band(pool);
            if (!whole) listed(ROUND_STAYS, w.y, entry, page, pool);
            if (!whole) listed(ROUND_FORESEE, w.y, entry, page, pool);
            listed(ROUND_MOVES, w.y, entry, page, pool | (whole ? 0u : SHADOW_JOB_HELD));
        }
    } else if (params.step == STEP_GRANT) {
        // One group: the pages the round lists, those read drawn the frame
        // before first, then by the order the pages are given, then by their
        // page of the pool, the same every frame.
        uint count = round_count();
        for (uint k = lane; k < POOL_GROUP; k += ROUND_GROUP) {
            uint key = 0xFFFFFFFFu;
            uint job = k < count ? pages[round_jobs() + k] : SHADOW_POOL_PAGES, pool = job & SHADOW_ENTRY_POOL;
            if (pool < SHADOW_POOL_PAGES) {
                uint slot, entry;
                bool placed = shadow_owner_place(pages[SHADOW_WORDS_OWNER + pool], slot, entry);
                // A page whose one row a draw had no room for goes last, not to hold the others back.
                bool stuck = (pages[SHADOW_WORDS_BAND + pool] & SHADOW_BAND_STUCK) != 0u;
                uint rank = !placed || stuck ? 0xFFFFu : rank_of(slot, entry);
                // A page of a slot past the threads of the culls by instance waits, after the others.
                bool waits = placed && pages[SHADOW_WORDS_HAS + params.round * SHADOW_SLOTS + slot] != 2u;
                bool refresh = placed && !stuck && (job & SHADOW_JOB_REFRESH) != 0u;
                if (refresh) rank = refresh_order(slot, entry, pages[SHADOW_WORDS_SWAY + pool]);
                key = (waits ? KEY_WAITS : 0u) | (refresh ? KEY_REFRESH : (job & SHADOW_JOB_KEPT) != 0u ? 0u : KEY_NEW) | (rank << 10u) | pool;
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
        // What each takes of the frame: of a page of the cache drawn before, what
        // its draws took of its band then, of a page of the atlas what composing
        // it took the last time (SHADOW_WORDS_KNOWN), which follows what moves in
        // it frame by frame; else what the cull by instance foresees, scaled by
        // what the draws took of that before (SHADOW_WORDS_SCALE). A page of the
        // cache known to take more than its share of the bound is drawn in bands
        // of its rows, halved until one takes no more, a row at least.
        uint scale = pages[SHADOW_WORDS_SCALE + params.round], share = max(params.budget / GRANT_SHARE, 1u);
        if (scale == 0u) scale = SHADOW_SCALE_ONE;
        for (uint k = lane; k < POOL_GROUP; k += ROUND_GROUP) {
            uint key = shared_words[k], cost = 0u, reach = 0u;
            if (key != 0xFFFFFFFFu && (key & KEY_WAITS) != 0u && !round_idle(key & 0x3FFu)) {
                cost = 1u;
            } else if (key != 0xFFFFFFFFu && !round_idle(key & 0x3FFu)) {
                uint pool = key & 0x3FFu, foreseen = pages[round_cost(pool)] & SHADOW_COST_UNITS;
                uint known = pages[round_known(pool)];
                // What the cache foresaw of a page it did not draw yet holds until
                // the page is drawn or changes; the cull foresees it once.
                if ((known & SHADOW_KNOWN_FORESEEN) != 0u) {
                    foreseen = known & SHADOW_COST_UNITS;
                    known = 0u;
                } else if (params.round == 0u && known == 0u) {
                    pages[SHADOW_WORDS_KNOWN + pool] = foreseen | SHADOW_KNOWN_FORESEEN;
                }
                // What is foreseen strays most for the pages that hold the most; one
                // not known yet takes at most a part of the share, and once drawn
                // the frames after know what it takes.
                cost = known != 0u ? known : uint(min(ceil(float(foreseen) * float(scale) / float(SHADOW_SCALE_ONE)), float(max(share / GRANT_GUESS, 1u))));
                // The chunks the cull by instance foresaw it hands over for it.
                reach = max(pages[SHADOW_WORDS_REACH + params.round * SHADOW_POOL_PAGES + pool], 1u);
                if (params.round == 1u && cost != 0u) cost = max(cost, GRANT_LEAST);
                uint band = pages[SHADOW_WORDS_BAND + pool], shift = (band >> SHADOW_BAND_SHIFT) & 0xFFu;
                if (params.round == 0u && known != 0u && (cost > share || (shift > 0u && 8u * cost <= share))) {
                    uint was = shift;
                    for (; cost > share && (SHADOW_PAGE >> shift) > 1u; shift++) cost = (cost + 1u) / 2u;
                    // Where the bound grew since, its bands grow back while two fit a quarter of the share.
                    for (; shift > 0u && 8u * cost <= share; shift--) cost *= 2u;
                    if (shift != was) {
                        pages[SHADOW_WORDS_BAND + pool] = (band & (0xFFu | SHADOW_BAND_STUCK)) | (shift << SHADOW_BAND_SHIFT);
                        pages[SHADOW_WORDS_KNOWN + pool] = cost;
                        part_band(pool);
                    }
                }
                cost = clamp(cost, 1u, params.budget);
                // Foreseen, for the scale (Propagate).
                if (known == 0u) pages[round_cost(pool)] = foreseen | SHADOW_COST_GUESS;
            }
            shared_costs[k] = cost;
            shared_reach[k] = cost != 0u ? reach : 0u;
        }
        GroupMemoryBarrierWithGroupSync();
        // The sums of what those before each take, each lane over four in turn.
        uint four = 0u, four_reach = 0u;
        for (uint j = 0u; j < 4u; j++) {
            four += shared_costs[lane * 4u + j];
            four_reach = min(four_reach + shared_reach[lane * 4u + j], SHADOW_COST_UNITS);
        }
        shared_sums[lane] = four;
        shared_reach_sums[lane] = four_reach;
        GroupMemoryBarrierWithGroupSync();
        for (uint offset = 1u; offset < ROUND_GROUP; offset <<= 1u) {
            uint before = lane >= offset ? shared_sums[lane - offset] : 0u;
            uint reach_before = lane >= offset ? shared_reach_sums[lane - offset] : 0u;
            GroupMemoryBarrierWithGroupSync();
            shared_sums[lane] += before;
            shared_reach_sums[lane] = min(shared_reach_sums[lane] + reach_before, SHADOW_COST_UNITS);
            GroupMemoryBarrierWithGroupSync();
        }
        // A page is granted where nothing is before it, or where it fits with
        // those before in a share of the bound and the chunks it may hand over
        // fit the list, and may take twice what it was granted for, at most the
        // bound (its quota): the quotas of a frame fit the bound, a page that
        // takes more than its own is the one left over, and only a page alone
        // may find the list full.
        // The slots and the spans of the round become those of the pages it
        // grants: the culls after this go over them alone.
        uint bounds = SHADOW_WORDS_BOUNDS + params.round * SHADOW_SLOTS * SHADOW_MIPS * 4u;
        for (uint w = lane; w < SHADOW_SLOTS * SHADOW_MIPS * 4u; w += ROUND_GROUP) pages[bounds + w] = 0u;
        shared_slots[lane] = 0u;
        AllMemoryBarrierWithGroupSync();
        uint spent = shared_sums[lane] - four, reached = shared_reach_sums[lane] - four_reach;
        for (uint j = 0u; j < 4u; j++) {
            uint k = lane * 4u + j, key = shared_words[k], cost = shared_costs[k], reach = shared_reach[k];
            // A page composed again for what sways in it comes after those kept and
            // those that came, and fills the share as they do: the frame after,
            // those go first again.
            bool kept = key < KEY_NEW || (key & KEY_REFRESH) != 0u || params.round == 0u;
            bool granted = (key & KEY_WAITS) == 0u && (spent == 0u || ((kept ? spent + cost <= share : spent + 2u * cost <= share - share / GRANT_NEW) && reached + reach <= params.chunks));
            spent += cost;
            reached = min(reached + reach, SHADOW_COST_UNITS);
            if (key == 0xFFFFFFFFu || cost == 0u) continue;
            uint pool = key & 0x3FFu, word = pages[round_cost(pool)];
            if (granted) {
                if ((word & SHADOW_COST_GUESS) != 0u) InterlockedAdd(pages[SHADOW_WORDS_COUNTS + SHADOW_COUNT_FORESEEN + params.round], word & SHADOW_COST_UNITS);
                pages[round_cost(pool)] = (word & SHADOW_COST_GUESS) | min(2u * cost, params.budget);
                uint slot, entry;
                if (!shadow_owner_place(pages[SHADOW_WORDS_OWNER + pool], slot, entry)) continue;
                shared_slots[slot] = 1u;
                Shadow_Map m = shadow_map_at(shadow_data, params.rows, slot);
                uint2 page = shadow_entry_page(m.rect, entry);
                uint span = bounds + (slot * SHADOW_MIPS + shadow_entry_mip(entry)) * 4u;
                InterlockedMax(pages[span], SHADOW_MAP_PAGES - page.x);
                InterlockedMax(pages[span + 1u], SHADOW_MAP_PAGES - page.y);
                InterlockedMax(pages[span + 2u], page.x + 1u);
                InterlockedMax(pages[span + 3u], page.y + 1u);
                continue;
            }
            // Past the units of the frame it waits, and the round draws nothing of it.
            pages[round_cost(pool)] = SHADOW_COST_WAITS;
            uint slot, entry;
            if (!shadow_owner_place(pages[SHADOW_WORDS_OWNER + pool], slot, entry)) continue;
            InterlockedAnd(pages[round_mask() + slot * SHADOW_MASK_WORDS + (entry >> 5u)], ~(1u << (entry & 31u)));
            if (params.round == 0u) for (uint w = 0u; w < 4u; w++) pages[SHADOW_WORDS_PART + pool * 4u + w] = 0u;
        }
        GroupMemoryBarrierWithGroupSync();
        // The cull by instance after the grant goes over the slots of the pages
        // granted alone, within those Finish kept.
        if (lane == 0u) {
            uint list = work_list(params.round), count = 0u, total = 0u;
            for (uint k = 0u; k < SHADOW_SLOTS; k++) {
                uint slot = slot_by_rank(k), threads = reach_threads(slot, params.round);
                if (shared_slots[slot] == 0u || threads == 0u) continue;
                pages[list + 1u + count++] = slot | total << SHADOW_WORK_SHIFT;
                total += threads;
            }
            pages[list] = count;
            cull_args(params.round, total, true);
        }
    } else if (params.step == STEP_SETTLE) {
        if (i >= round_count()) return;
        uint job = pages[round_jobs() + i], pool = job & SHADOW_ENTRY_POOL, slot, entry;
        if (pool >= SHADOW_POOL_PAGES || !shadow_owner_place(pages[SHADOW_WORDS_OWNER + pool], slot, entry)) return;
        uint cost = pages[round_cost(pool)], taken = pages[round_taken(pool)], e = shadow_table_entry(slot, entry);
        // What the cache left for the frames after is not ready already.
        if (params.round == 1u && (e & SHADOW_PAGE_COMPOSED) == 0u) return;
        // Where the list of the chunks of the round had no room, no page of it is drawn whole.
        bool dropped = pages[SHADOW_WORDS_COUNTS + SHADOW_COUNT_DROPPED + params.round] != 0u;
        bool granted = (cost & SHADOW_COST_WAITS) == 0u, done = granted && (cost & SHADOW_COST_OVER) == 0u && !dropped;
        // What the draws took of what was foreseen, for the scale (Propagate).
        if (granted && (cost & SHADOW_COST_GUESS) != 0u) InterlockedAdd(pages[SHADOW_WORDS_COUNTS + SHADOW_COUNT_MEASURED + params.round], taken);
        // What composing it took, which the next frame grants it for.
        if (params.round == 1u && granted) pages[round_known(pool)] = taken;
        // Whether what the atlas composed holds what sways, and when; the steps
        // run again the next frame while it does.
        bool refresh = (job & SHADOW_JOB_REFRESH) != 0u;
        if (params.round == 1u) {
            uint sway = pages[SHADOW_WORDS_SWAY + pool], sways = (sway & (SHADOW_SWAY_NOW | SHADOW_SWAY_SWAYS)) != 0u ? SHADOW_SWAY_SWAYS : 0u;
            if (done) sways = (sway & SHADOW_SWAY_NOW) != 0u ? SHADOW_SWAY_SWAYS : 0u;
            pages[SHADOW_WORDS_SWAY + pool] = sways | (done ? params.frame : sway) & SHADOW_SWAY_FRAME;
            if (sways != 0u) pages[SHADOW_STEP_NEW] = 1u;
            if (done && refresh) InterlockedAdd(pages[SHADOW_WORDS_COUNTS + SHADOW_COUNT_REFRESHED], 1u);
        }
        if (params.round == 0u) {
            uint band = pages[SHADOW_WORDS_BAND + pool], shift = (band >> SHADOW_BAND_SHIFT) & 0xFFu, rows = band & 0xFFu;
            uint stuck = band & SHADOW_BAND_STUCK;
            if (done) rows += SHADOW_PAGE >> shift;
            else if (granted && !dropped && (SHADOW_PAGE >> shift) == 1u) stuck = SHADOW_BAND_STUCK;
            done = rows >= SHADOW_PAGE;
            pages[SHADOW_WORDS_BAND + pool] = done ? 0u : rows | (shift << SHADOW_BAND_SHIFT) | stuck;
            // What its band took, which the next band of it takes too.
            if (granted || done) pages[SHADOW_WORDS_KNOWN + pool] = done ? 0u : taken;
            if (!done) {
                table_set(slot, entry, e & ~SHADOW_PAGE_READY);
                InterlockedAnd(pages[SHADOW_WORDS_COMPOSE + slot * SHADOW_MASK_WORDS + (entry >> 5u)], ~(1u << (entry & 31u)));
            }
        } else if (!done && (granted || !refresh)) {
            table_set(slot, entry, e & ~SHADOW_PAGE_COMPOSED);
        }
        if (done) return;
        InterlockedAdd(pages[SHADOW_WORDS_COUNTS + SHADOW_COUNT_WAITING], 1u);
        pages[SHADOW_STEP_NEW] = 1u;
    } else if (params.step == STEP_PROPAGATE) {
        // Of each round, what its draws took of what was foreseen for the pages
        // granted as foreseen, for the next Grant, half of it from this frame so
        // that one frame of pages unlike the others does not swing it.
        if (i < 2u) {
            uint foreseen = pages[SHADOW_WORDS_COUNTS + SHADOW_COUNT_FORESEEN + i], measured = pages[SHADOW_WORDS_COUNTS + SHADOW_COUNT_MEASURED + i];
            uint before = pages[SHADOW_WORDS_SCALE + i];
            uint now = uint(float(measured) * float(SHADOW_SCALE_ONE) / max(float(foreseen), 1.0));
            if (foreseen > 0u) pages[SHADOW_WORDS_SCALE + i] = clamp(((before == 0u ? SHADOW_SCALE_ONE : before) + now) / 2u, SHADOW_SCALE_ONE / 16u, SHADOW_SCALE_ONE * 4u);
        }
        // In a still view the pages that wait make the bound grow too: no view
        // that moves waits on them.
        if (i == 0u && params.full == 0u) InterlockedAdd(pages[SHADOW_WORDS_COUNTS + SHADOW_COUNT_SHORT], pages[SHADOW_WORDS_COUNTS + SHADOW_COUNT_WAITING]);
        if (i >= slots_in_use() * SHADOW_SLOT_ENTRIES) return;
        uint slot = slot_in_use(i / SHADOW_SLOT_ENTRIES), entry = i % SHADOW_SLOT_ENTRIES;
        if (slot >= SHADOW_SLOTS) return;
        Shadow_Map m = shadow_map_at(shadow_data, params.rows, slot);
        uint mip = shadow_entry_mip(entry);
        if (m.rect.z == 0u || mip >= slot_mips(slot)) return;
        uint e = shadow_table_entry(slot, entry);
        uint2 page = shadow_entry_page(m.rect, entry);
        uint coarser = shadow_entry_ready(e) ? 0u : coarser_drawn(slot, mip, page);
        uint held = 0u;
        if (entry_read(slot, entry)) {
            if (shadow_entry_ready(e) && around_read(slot, shadow_map_mip(m, mip), int2(page))) held = 1u;
            uint at_slot;
            Shadow_Map c;
            int2 p;
            for (uint j = 1u; j <= SHADOW_HELD_COARSER && held == 0u && page_coarser(slot, mip, page, j, at_slot, c, p); j++) {
                if (shadow_entry_ready(shadow_table_entry(at_slot, shadow_page_entry(c.rect, uint2(p)))) && around_read(at_slot, c, p)) held = j + 1u;
            }
            if (held == 0u) InterlockedAdd(pages[SHADOW_WORDS_COUNTS + SHADOW_COUNT_SHORT], 1u);
        }
        if (coarser != 0u || held != 0u) table_set(slot, entry, e | (coarser << SHADOW_ENTRY_COARSER) | (held << SHADOW_ENTRY_HELD));
    } else if (params.step == STEP_FINISH) {
        // The slots each cull by instance goes over, those it left out the most
        // frames in a row first, then the coarsest, while their threads fit
        // those of a frame, one at least; a slot it keeps (2) has its pages
        // granted, the others wait.
        for (uint round = 0u; round < 2u; round++) {
            uint slot = lane < SHADOW_SLOTS ? slot_by_rank(lane) : SHADOW_SLOTS, key = 0xFFFFu;
            uint skipped = SHADOW_WORDS_SKIPPED + round * SHADOW_SLOTS;
            if (slot < SHADOW_SLOTS && pages[SHADOW_WORDS_HAS + round * SHADOW_SLOTS + slot] != 0u) key = ((0xFFu - min(pages[skipped + slot], 0xFFu)) << 8u) | lane;
            shared_words[lane] = key;
            GroupMemoryBarrierWithGroupSync();
            for (uint size = 2u; size <= ROUND_GROUP; size <<= 1u) {
                for (uint stride = size >> 1u; stride > 0u; stride >>= 1u) {
                    if (lane < ROUND_GROUP / 2u) {
                        uint low = 2u * stride * (lane / stride) + lane % stride, high = low + stride;
                        uint a = shared_words[low], b = shared_words[high];
                        if ((a > b) == ((low & size) == 0u) && a != b) {
                            shared_words[low] = b;
                            shared_words[high] = a;
                        }
                    }
                    GroupMemoryBarrierWithGroupSync();
                }
            }
            if (lane == 0u) {
                uint list = work_list(round), count = 0u, total = 0u;
                for (uint k = 0u; k < SHADOW_SLOTS && shared_words[k] != 0xFFFFu; k++) {
                    uint at = slot_by_rank(shared_words[k] & 0xFFu), has = SHADOW_WORDS_HAS + round * SHADOW_SLOTS + at, threads = reach_threads(at, round);
                    if (count > 0u && total + threads > params.threads) {
                        pages[skipped + at] += 1u;
                        continue;
                    }
                    pages[has] = 2u;
                    pages[skipped + at] = 0u;
                    if (threads == 0u) continue;
                    pages[list + 1u + count++] = at | total << SHADOW_WORK_SHIFT;
                    total += threads;
                }
                pages[list] = count;
                cull_args(round, total, round != ROUND_STAYS);
            }
            AllMemoryBarrierWithGroupSync();
        }
        if (lane != 0u) return;
        // The foresight of the cache: of the slots it keeps, those with pages not foreseen yet.
        uint list = work_list(ROUND_FORESEE), count = 0u, total = 0u;
        for (uint k = 0u; k < SHADOW_SLOTS; k++) {
            uint slot = slot_by_rank(k), threads = reach_threads(slot, ROUND_STAYS);
            if (pages[SHADOW_WORDS_HAS + ROUND_FORESEE * SHADOW_SLOTS + slot] == 0u || pages[SHADOW_WORDS_HAS + slot] != 2u || threads == 0u) continue;
            pages[list + 1u + count++] = slot | total << SHADOW_WORK_SHIFT;
            total += threads;
        }
        pages[list] = count;
        cull_args(ROUND_FORESEE, total, true);
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
