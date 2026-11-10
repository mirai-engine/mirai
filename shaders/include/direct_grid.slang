// The lights of a pixel from the grid of the lights (render/light_grid.odin),
// what direct_rays.comp and direct_samples.comp share; it needs their params
// (grid_origin, grid_cell, grid_size, cells) and the grid buffer light_grid.
//
// The items the samples of a pixel spread over: each light of its cell when
// it lists DIRECT_FEW at most, weighed at the point of the pixel
// (light_weight); else the lights it lists apart, weighed so, and its table as
// one item, by what it could give the cell, whose samples draw their light from
// it (alias method), each its own; and then the sun.
#ifndef MIRAI_DIRECT_GRID_SLANG
#define MIRAI_DIRECT_GRID_SLANG
#include "light_weight.slang"

#define DIRECT_FEW 64u
// The item that stands for the table of a cell with more than DIRECT_FEW lights.
#define DIRECT_CELL_TABLE 0xFFFFFFFDu

// The cell of a point, INVALID outside the grid.
uint direct_cell_index(float3 position) {
    if (params.cells == 0u) return INVALID;
    int3 c = int3(floor((position - params.grid_origin) / params.grid_cell));
    if (any(c < 0) || any(c >= int3(params.grid_size))) return INVALID;
    return uint(c.x) + params.grid_size.x * (uint(c.y) + params.grid_size.y * uint(c.z));
}

// The row of a cell: its first entry, the entries of its table, those apart
// after them, and what its table could give the cell; none outside the grid.
uint4 direct_row(uint cell) { return cell != INVALID ? light_grid[cell] : uint4(0u); }
uint4 direct_cell(float3 position) { return direct_row(direct_cell_index(position)); }

// How many items of lights a cell gives a pixel, the sun aside.
uint direct_items(uint4 row) { return row.y + row.z <= DIRECT_FEW ? row.y + row.z : row.z + 1u; }

// Item i of the lights of a cell: a light, or DIRECT_CELL_TABLE.
uint direct_item(uint4 row, uint i) {
    if (row.y + row.z <= DIRECT_FEW) return light_grid[row.x + i].x;
    return i < row.z ? light_grid[row.x + row.y + i].x : DIRECT_CELL_TABLE;
}

// The weight of an item at a point, in the 16 high bits of its float, which
// direct_samples.comp keeps: the walk spreads samples by them and weighs each
// by them, so that they need no more.
float direct_item_weight(uint4 row, uint item, float3 position, float3 normal) {
    float w = item == DIRECT_CELL_TABLE ? asfloat(row.w) : light_weight(light_grid[params.cells + LIGHT_WEIGHT_ROWS * item], light_grid[params.cells + LIGHT_WEIGHT_ROWS * item + 1u], position, normal);
    return asfloat(asuint(w) & 0xFFFF0000u);
}

// The light a draw at u, from 0 to 1, of the table of a cell lands on, and the
// chance of drawing it.
uint direct_table_draw(uint4 row, float u, out float chance) {
    float v = saturate(u) * float(row.y);
    uint at = min(uint(v), row.y - 1u);
    uint4 entry = light_grid[row.x + at];
    if (v - float(at) >= asfloat(entry.z)) entry = light_grid[row.x + entry.y];
    chance = asfloat(entry.w);
    return entry.x;
}

// The ray of a sample towards a point of a light, or of the sun for INVALID.
void direct_ray(uint light, float3 position, float3 origin, float point, float spin, float sun_radius, out float3 direction, out float reach) {
    if (light == INVALID) {
        direction = sun_ray(point, spin, sun_radius);
        reach = scene_reach(origin, direction);
        return;
    }
    float3 toward = light_point(lights[light], position, point, spin);
    float distance = length(toward);
    direction = toward / max(distance, 1e-6);
    reach = light_reach(lights[light], distance);
}

// The weight of an item at a point for the samples: none for a light a map of
// the view holds there, whose light direct_maps.comp gives.
float direct_sampled_weight(uint4 row, uint item, float3 position, float3 normal) {
#ifdef SHADOW_DATA_SLOT
    Shadow_Map m;
    if (item != DIRECT_CELL_TABLE && light_map_of(item, position, m)) return 0.0;
#endif
    return direct_item_weight(row, item, position, normal);
}

#endif
