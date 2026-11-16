// The pages of the maps of the shadows of a view (render.shadow_maps_pass):
// a map lies in a slot, a square of SHADOW_MAP_PAGES pages a side whose
// pages lie where the table of the pages says in the pool of the view, its
// cache and its atlas, both SHADOW_POOL texels a side. An entry of the table
// is the page of the pool + 1 that holds a page (0: none) with
// SHADOW_PAGE_CACHED and SHADOW_PAGE_COMPOSED while it is drawn; the atlas
// keeps a copy of the table in its last pages.
#ifndef MIRAI_SHADOW_PAGES_SLANG
#define MIRAI_SHADOW_PAGES_SLANG

#define SHADOW_PAGE_READY (SHADOW_PAGE_CACHED | SHADOW_PAGE_COMPOSED)
#define SHADOW_POOL_ROW (SHADOW_POOL / SHADOW_PAGE)

// The entry of the table of its slot a page of a map lies at: a level of the
// sun keeps its pages where they are in the world as it moves (rect.y,
// render.shadow_page_entry).
uint shadow_page_entry(uint4 rect, uint2 page) {
    uint ox = rect.y & 0xFFu, oy = (rect.y >> 8u) & 0xFFu;
    return ((page.y + oy) % SHADOW_MAP_PAGES) * SHADOW_MAP_PAGES + (page.x + ox) % SHADOW_MAP_PAGES;
}

// The page of a map at an entry of its slot.
uint2 shadow_entry_page(uint4 rect, uint entry) {
    uint ox = rect.y & 0xFFu, oy = (rect.y >> 8u) & 0xFFu;
    return uint2((entry % SHADOW_MAP_PAGES + SHADOW_MAP_PAGES - ox) % SHADOW_MAP_PAGES, (entry / SHADOW_MAP_PAGES + SHADOW_MAP_PAGES - oy) % SHADOW_MAP_PAGES);
}

// The first texel of a page of the pool.
uint2 shadow_pool_corner(uint pool) { return uint2(pool % SHADOW_POOL_ROW, pool / SHADOW_POOL_ROW) * SHADOW_PAGE; }

// Where the atlas keeps the entry `index` of the table (slot * SHADOW_SLOT_PAGES + entry).
uint2 shadow_table_texel(uint index) { return uint2(SHADOW_TABLE_X + index % SHADOW_TABLE_WIDTH, SHADOW_TABLE_Y + index / SHADOW_TABLE_WIDTH); }

#endif
