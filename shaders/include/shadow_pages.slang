// The pages of the maps of the shadows of a view (render.shadow_maps_pass):
// a map lies in a slot, its mips each a square of pages half as wide as the
// one before (SHADOW_MAP_PAGES the finest, a level of the sun its finest
// alone), whose pages lie where the table of the pages says in the pool of
// the view, its cache and its atlas, both SHADOW_POOL texels a side. An entry
// of the table is the page of the pool + 1 that holds a page (0: none) with
// SHADOW_PAGE_CACHED and SHADOW_PAGE_COMPOSED while it is drawn, how many
// levels or mips coarser the nearest page drawn this frame lies where it is
// not (SHADOW_ENTRY_COARSER), and the page that holds a point there
// (SHADOW_ENTRY_HELD).
#ifndef MIRAI_SHADOW_PAGES_SLANG
#define MIRAI_SHADOW_PAGES_SLANG

#define SHADOW_PAGE_READY (SHADOW_PAGE_CACHED | SHADOW_PAGE_COMPOSED)
#define SHADOW_POOL_ROW (SHADOW_POOL / SHADOW_PAGE)
#define SHADOW_ENTRY_POOL 0xFFFFu
// Of a page of the pool listed for the atlas to copy, that the cache holds it this frame.
#define SHADOW_JOB_HELD 0x10000u
// Of a page of the pool listed for a round, that its points read it drawn the
// frame before: it is granted before the pages that were not.
#define SHADOW_JOB_KEPT 0x20000u

// The first entry of a mip of a slot, the coarsest first, and its pages a side.
uint shadow_mip_base(uint mip) { return ((1u << (2u * (SHADOW_MIPS - 1u - mip))) - 1u) / 3u; }
uint shadow_mip_pages(uint mip) { return SHADOW_MAP_PAGES >> mip; }

// The mip of a map (render.Gpu_Shadow_Map.rect.y), and the mip of an entry.
uint shadow_rect_mip(uint4 rect) { return (rect.y >> 16u) & 7u; }
uint shadow_entry_mip(uint entry) {
    uint mip = 0u;
    while (mip + 1u < SHADOW_MIPS && entry < shadow_mip_base(mip)) mip++;
    return mip;
}

// The entry of the table of its slot a page of a map at its mip lies at: a
// level of the sun keeps its pages where they are in the world as it moves
// (rect.y, render.shadow_page_entry).
uint shadow_page_entry(uint4 rect, uint2 page) {
    uint mip = shadow_rect_mip(rect), n = shadow_mip_pages(mip);
    uint ox = rect.y & 0xFFu, oy = (rect.y >> 8u) & 0xFFu;
    return shadow_mip_base(mip) + ((page.y + oy) % n) * n + (page.x + ox) % n;
}

// The page of a map at an entry of its slot, at the mip of the entry.
uint2 shadow_entry_page(uint4 rect, uint entry) {
    uint mip = shadow_entry_mip(entry), n = shadow_mip_pages(mip);
    uint ox = rect.y & 0xFFu, oy = (rect.y >> 8u) & 0xFFu;
    uint at = entry - shadow_mip_base(mip);
    return uint2((at % n + n - ox % n) % n, (at / n + n - oy % n) % n);
}

// The first texel of a page of the pool.
uint2 shadow_pool_corner(uint pool) { return uint2(pool % SHADOW_POOL_ROW, pool / SHADOW_POOL_ROW) * SHADOW_PAGE; }

// What the steps and the culls read of the table and of the buffer of the
// pages addresses only its own region: a value past its range names nothing
// and is dropped, not taken as a neighbour.
// The page of the pool an entry of the table holds; false for none or past the pool.
bool shadow_entry_pool(uint e, out uint pool) {
    pool = (e & SHADOW_ENTRY_POOL) - 1u;
    return (e & SHADOW_ENTRY_POOL) != 0u && pool < SHADOW_POOL_PAGES;
}
// An entry of a slot within the table.
bool shadow_place_valid(uint slot, uint entry) { return slot < SHADOW_SLOTS && entry < SHADOW_SLOT_ENTRIES; }
// The slot and the entry the owner of a page of the pool names (SHADOW_WORDS_OWNER); false for none or past the table.
bool shadow_owner_place(uint owner, out uint slot, out uint entry) {
    slot = (owner - 1u) / SHADOW_SLOT_ENTRIES;
    entry = (owner - 1u) % SHADOW_SLOT_ENTRIES;
    return owner != 0u && slot < SHADOW_SLOTS;
}

// Whether an entry holds its page drawn this frame: the atlas holds it with
// what moves, from the cache or, in a frame a slot lets go of every page,
// drawn whole straight into it (SHADOW_PLAN_RESET).
bool shadow_entry_ready(uint e) { return (e & SHADOW_ENTRY_POOL) != 0u && (e & SHADOW_PAGE_COMPOSED) != 0u; }

// Whether a point that reads an entry asks for its page: not drawn, nor left
// out of the pool the last time the pages were given.
bool shadow_entry_asks(uint e) { return !shadow_entry_ready(e) && (e & SHADOW_PAGE_LEFT) == 0u; }

// The table of the pages of the view (render.Shadow_Raster.table): a texel
// for each entry, a row for each slot.
#ifndef SHADOW_TABLE_WRITTEN
[[vk::binding(SLOT_SHADOW_TABLE, 0)]] Texture2D<uint> shadow_table : register(MIRAI_REGISTER(t, SLOT_SHADOW_TABLE), space0);
uint shadow_table_entry(uint slot, uint entry) { return shadow_table.Load(int3(int(entry), int(slot), 0)); }
#endif

#endif
