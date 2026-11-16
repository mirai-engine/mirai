#include "native.slang"
// The table of the pages of the maps of the shadows of a view, each frame
// after the marks of its points (shadow_mark.comp, render.shadow_maps_pass),
// in steps (Params_Block.step, render.Shadow_Pages_Step):
// - Entries, a thread for each entry of each slot: lets go of the page of
//   the pool of what the plan says (render.Shadow_Slot_Masks), forgets what
//   stays or what moves where they changed, and of a page a point reads, or
//   the plan keeps: asks for a page of the pool where it has none, else lists
//   it for the cache to draw where what stays is not drawn there and for the
//   atlas to compose where that is not;
// - Pool, a thread for each page of the pool: lists those free and those no
//   point read this frame;
// - Allocate, a thread for each page asked for: takes a free one, else one no
//   point read, which its entry lets go of; past them it is left out, and the
//   points of it trace rays;
// - Finish: the arguments of the culls and the draws of the rounds.
// The pages listed take their bits in the masks of each round, by their
// place in their map, and each slot with one is listed once.
#include "shadow_maps.slang"
#define MIRAI_GROUP_X 64
#define MIRAI_GROUP_Y 1
#define MIRAI_GROUP_Z 1

// step; frame: counts the frames; rows: of the words of the lights in the
// buffer of the maps; masks: the word of it the masks of the slots start at;
// groups of the cull of each round, along x.
struct Params_Block { uint step; uint frame; uint rows; uint masks; uint groups_stays; uint groups_moves; uint groups_glass; uint pad; };
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);
[[vk::binding(SLOT_PASS0, 0)]] StructuredBuffer<uint4> shadow_data : register(MIRAI_REGISTER(t, SLOT_PASS0), space0);
[[vk::binding(SLOT_PASS2, 0)]] RWStructuredBuffer<uint> pages : register(MIRAI_REGISTER(u, SLOT_PASS2), space0);

#define ROUND_STAYS 0u
#define ROUND_MOVES 1u
#define ROUND_READY 2u

uint data_word(uint word) { return shadow_data[word >> 2u][word & 3u]; }

// Mask k of a slot from the plan (render.Shadow_Slot_Masks): reset, stale, moved, kept.
bool plan_bit(uint slot, uint k, uint entry) {
    return ((data_word(params.masks + (slot * 4u + k) * SHADOW_MASK_WORDS + (entry >> 5u)) >> (entry & 31u)) & 1u) != 0u;
}

// A page of a slot in a round: its bit, its slot listed once, and of the
// cache and the atlas, the page listed to draw.
void listed(uint round, uint slot, uint2 page) {
    uint masks[3] = {SHADOW_WORDS_DRAWN, SHADOW_WORDS_COMPOSE, SHADOW_WORDS_READY};
    uint bit = page.y * SHADOW_MAP_PAGES + page.x;
    InterlockedOr(pages[masks[round] + slot * SHADOW_MASK_WORDS + (bit >> 5u)], 1u << (bit & 31u));
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
    if (at < SHADOW_POOL_PAGES) pages[SHADOW_WORDS_JOBS + round * SHADOW_POOL_PAGES + at] = slot | page.x << 8u | page.y << 16u;
}

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 id : SV_DispatchThreadID) {
    uint i = id.x;
    if (params.step == 0u) {
        if (i >= SHADOW_SLOTS * SHADOW_SLOT_PAGES) return;
        uint slot = i / SHADOW_SLOT_PAGES, entry = i % SHADOW_SLOT_PAGES;
        Shadow_Map m = shadow_map_at(shadow_data, params.rows, slot);
        uint e = pages[i];
        if (plan_bit(slot, 0u, entry) && e != 0u) {
            pages[SHADOW_WORDS_OWNER + (e & 0xFFFFu) - 1u] = 0u;
            e = 0u;
        }
        if (plan_bit(slot, 1u, entry)) e &= ~SHADOW_PAGE_READY;
        if (plan_bit(slot, 2u, entry)) e &= ~SHADOW_PAGE_COMPOSED;
        uint2 page = shadow_entry_page(m.rect, entry);
        bool inside = m.rect.z != 0u && all(page < m.rect.zz / SHADOW_PAGE);
        bool needed = inside && (((pages[SHADOW_WORDS_NEEDED + slot * SHADOW_MASK_WORDS + (entry >> 5u)] >> (entry & 31u)) & 1u) != 0u || plan_bit(slot, 3u, entry));
        if (needed && e == 0u) {
            uint at;
            InterlockedAdd(pages[SHADOW_WORDS_COUNTS + SHADOW_COUNT_REQUESTS], 1u, at);
            if (at < SHADOW_REQUESTS) pages[SHADOW_WORDS_REQUESTS + at] = i;
        } else if (needed) {
            pages[SHADOW_WORDS_AGE + (e & 0xFFFFu) - 1u] = params.frame;
            bool draw = (e & SHADOW_PAGE_CACHED) == 0u;
            if (draw) listed(ROUND_STAYS, slot, page);
            if (draw || (e & SHADOW_PAGE_COMPOSED) == 0u) listed(ROUND_MOVES, slot, page);
            e |= SHADOW_PAGE_READY;
        }
        if (inside && e != 0u && (e & SHADOW_PAGE_READY) == SHADOW_PAGE_READY) listed(ROUND_READY, slot, page);
        pages[i] = e;
    } else if (params.step == 1u) {
        if (i >= SHADOW_POOL_PAGES) return;
        uint at;
        if (pages[SHADOW_WORDS_OWNER + i] == 0u) {
            InterlockedAdd(pages[SHADOW_WORDS_COUNTS + SHADOW_COUNT_FREE], 1u, at);
            pages[SHADOW_WORDS_FREE + at] = i;
        } else if (pages[SHADOW_WORDS_AGE + i] != params.frame) {
            InterlockedAdd(pages[SHADOW_WORDS_COUNTS + SHADOW_COUNT_SPARE], 1u, at);
            pages[SHADOW_WORDS_SPARE + at] = i;
        }
    } else if (params.step == 2u) {
        if (i >= min(pages[SHADOW_WORDS_COUNTS + SHADOW_COUNT_REQUESTS], SHADOW_REQUESTS)) return;
        uint index = pages[SHADOW_WORDS_REQUESTS + i];
        uint free = pages[SHADOW_WORDS_COUNTS + SHADOW_COUNT_FREE], spare = pages[SHADOW_WORDS_COUNTS + SHADOW_COUNT_SPARE];
        uint pool;
        if (i < free) {
            pool = pages[SHADOW_WORDS_FREE + i];
        } else if (i - free < spare) {
            pool = pages[SHADOW_WORDS_SPARE + i - free];
            pages[pages[SHADOW_WORDS_OWNER + pool] - 1u] = 0u;
        } else {
            InterlockedAdd(pages[SHADOW_WORDS_COUNTS + SHADOW_COUNT_LEFT], 1u);
            return;
        }
        pages[index] = (pool + 1u) | SHADOW_PAGE_READY;
        pages[SHADOW_WORDS_OWNER + pool] = index + 1u;
        pages[SHADOW_WORDS_AGE + pool] = params.frame;
        uint slot = index / SHADOW_SLOT_PAGES;
        uint2 page = shadow_entry_page(shadow_map_at(shadow_data, params.rows, slot).rect, index % SHADOW_SLOT_PAGES);
        listed(ROUND_STAYS, slot, page);
        listed(ROUND_MOVES, slot, page);
        listed(ROUND_READY, slot, page);
    } else if (i == 0u) {
        uint requests = pages[SHADOW_WORDS_COUNTS + SHADOW_COUNT_REQUESTS];
        if (requests > SHADOW_REQUESTS) InterlockedAdd(pages[SHADOW_WORDS_COUNTS + SHADOW_COUNT_LEFT], requests - SHADOW_REQUESTS);
        uint groups[3] = {params.groups_stays, params.groups_moves, params.groups_glass};
        for (uint round = 0u; round < 3u; round++) {
            uint at = SHADOW_WORDS_ARGS + SHADOW_ARGS_DISPATCH + 3u * round;
            uint slots = pages[SHADOW_WORDS_COUNTS + SHADOW_COUNT_SLOTS + round];
            pages[at] = slots > 0u ? groups[round] : 0u;
            pages[at + 1u] = slots;
            pages[at + 2u] = 1u;
        }
        for (uint round = 0u; round < 2u; round++) {
            uint at = SHADOW_WORDS_ARGS + SHADOW_ARGS_DRAW + 4u * round;
            pages[at] = 6u;
            pages[at + 1u] = min(pages[SHADOW_WORDS_COUNTS + (round == 0u ? SHADOW_COUNT_DRAWN : SHADOW_COUNT_COMPOSED)], SHADOW_POOL_PAGES);
            pages[at + 2u] = 0u;
            pages[at + 3u] = 0u;
        }
    }
}
