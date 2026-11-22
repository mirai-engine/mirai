// The lists of the lights that cast no shadows (render/light_lists.odin,
// light_lists.comp): what the walks of their tree (lighting.slang) visit for
// the points of a cell, decided once for the cell, so that each point sums a
// short list with no walk. A list holds the nodes either walk, the estimate
// or the light, takes anything from at some point of the cell, in the order
// of the tree: a light, a group that stands for its lights at every point of
// the cell, or a group that may open at some of them, with what lies under
// it after it. A point weighs each as its own walk would, so what it sums is
// what the walk gives it, the same on both sides of the border of a cell.
//
// A list is a block of the texture of the lists, LIGHT_LIST_TILE texels
// across and LIGHT_LIST_WORDS in all: how many entries, then the entries. An
// entry: the node from bit LIGHT_ENTRY_NODE, then a field for the estimate
// (from LIGHT_ENTRY_ROUGH) and one for the light (from 0): LIGHT_ENTRY_IN,
// the sum takes the node; LIGHT_ENTRY_STANDS, a light, or a group that stands
// for its lights whatever a point makes of it; and in LIGHT_ENTRY_UNDER how
// many groups listed before it that may open lie over it, the last of which
// hands it the share it opens by.
//
// A list keeps as many nodes of each walk as the walk visits at most
// (LIGHT_WALK_MAX): where the bounds of a cell are those of a point, what a
// walk gives the point fits its list. A cell with more to list has none: its
// count is LIGHT_LIST_WALK, and each of its points walks the tree.
#ifndef MIRAI_LIGHT_LISTS_SLANG
#define MIRAI_LIGHT_LISTS_SLANG
#include "lighting.slang"

#define LIGHT_ENTRY_NODE 14u
#define LIGHT_ENTRY_ROUGH 7u
#define LIGHT_ENTRY_IN 64u
#define LIGHT_ENTRY_STANDS 32u
#define LIGHT_ENTRY_UNDER 31u
#define LIGHT_LIST_DEPTH 32
#define LIGHT_LIST_ROUGH 63
#define LIGHT_LIST_FINE 64
#define LIGHT_LIST_WALK 0xFFFFFFFFu

// The texels of a block, and the texel of a word of the list whose block starts at `block`.
static const int2 LIGHT_LIST_BLOCK = int2(int(LIGHT_LIST_TILE), int(LIGHT_LIST_WORDS / LIGHT_LIST_TILE));
int2 light_list_texel(int2 block, uint word) { return block + int2(int(word % LIGHT_LIST_TILE), int(word / LIGHT_LIST_TILE)); }
// The blocks of the lists of the blended instances of a view
// (translucent_draws.comp): where the n-th starts; the word of how many cells
// split an instance along each side, and back; and the block of the cell of
// an instance, whose first block and that word are `cells`, that holds a
// point of its box.
int2 light_list_block(uint n) { return int2(int(n % TRANSLUCENT_LIST_COLUMNS), int(n / TRANSLUCENT_LIST_COLUMNS)) * LIGHT_LIST_BLOCK; }
uint translucent_cells_word(uint3 sides) { return sides.x | (sides.y << 8u) | (sides.z << 16u); }
uint3 translucent_cells_sides(uint word) { return max(uint3(word & 255u, (word >> 8u) & 255u, (word >> 16u) & 255u), uint3(1u)); }
uint translucent_cell_block(uint2 cells, float3 position, float3 low, float3 high) {
    uint3 sides = translucent_cells_sides(cells.y);
    uint3 at = uint3(clamp(floor((position - low) / max(high - low, 1e-6) * float3(sides)), 0.0, float3(sides - 1u)));
    return cells.x + at.x + sides.x * (at.y + sides.y * at.z);
}

#ifndef LIGHT_LISTS_WRITTEN
[[vk::binding(SLOT_LIGHT_LISTS, 0)]] Texture2D<uint> light_lists : register(MIRAI_REGISTER(t, SLOT_LIGHT_LISTS), space0);

// The block of the list of the screen tile of pixel p.
int2 light_list_of_pixel(int2 p) { return (p / int(LIGHT_LIST_TILE)) * LIGHT_LIST_BLOCK; }

// shadowless_lighting from the list at `block` of a cell that holds the
// point and its normal: the same light, with no walk. The estimate takes
// every node in one pass, which also takes the light of each node whose
// share does not wait for the estimate: one that stands with no group that
// may open over it. A second pass takes the others, where there are any.
float3 light_list_lighting(Shading s, float known, int2 block, uint share = LIGHT_SHARE_ALL) {
    if (frame.shadowless_lights == 0u) return float3(0.0);
    uint count = light_lists.Load(int3(block, 0));
    if (count == LIGHT_LIST_WALK) return shadowless_lighting(s, known, share);
    count = min(count, LIGHT_LIST_WORDS - 1u);
    // What each group that may open, of those over the entry at hand, leaves to what lies under it.
    float shares[LIGHT_LIST_DEPTH];
    float total = max(known, 0.0);
    float3 result = float3(0.0);
    uint waiting = 0u;
    const uint SETTLED = LIGHT_ENTRY_IN | LIGHT_ENTRY_STANDS;
    for (uint i = 0u; i < count; i++) {
        uint entry = light_lists.Load(int3(light_list_texel(block, 1u + i), 0));
        uint rough = entry >> LIGHT_ENTRY_ROUGH;
        bool settled = (entry & (SETTLED | LIGHT_ENTRY_UNDER)) == SETTLED;
        if ((entry & LIGHT_ENTRY_IN) != 0u && !settled) waiting++;
        bool estimated = (rough & LIGHT_ENTRY_IN) != 0u;
        uint under = rough & LIGHT_ENTRY_UNDER;
        float weight = !estimated ? 0.0 : under > 0u ? shares[under - 1u] : 1.0;
        float opened = 0.0;
        uint at = entry >> LIGHT_ENTRY_NODE;
        if ((weight > 0.0 || settled) && at < frame.light_nodes) {
            Light_Node node = light_nodes[at];
            float distance_squared;
            if (node_reaches(node, s.position, s.normal, distance_squared, share)) {
                float shared = node_share(node, share);
                float3 direction;
                float distance;
                if ((node.flags & LIGHT_NODE_LEAF) != 0u) {
                    Light light = lights[node.child];
                    float3 irradiance = light_contribution(light, s.position, s.normal, direction, distance, shading_footprint(s));
                    // The estimate of the walks takes the image of a light at its finest level.
                    float3 estimated = light_projects(light) ? light_contribution(light, s.position, s.normal, direction, distance) : irradiance;
                    total += luminance(estimated) * (weight * shared);
                    if (settled) {
                        float3 diffuse, specular;
                        light_lobes_of(light, s, irradiance, direction, distance, diffuse, specular);
                        result += (diffuse + specular) * shared;
                    }
                } else {
                    if ((rough & LIGHT_ENTRY_STANDS) == 0u) opened = estimate_opened(node, distance_squared);
                    if (opened < 1.0 || settled) {
                        float doubt;
                        float3 irradiance = group_contribution(node, s.position, s.normal, direction, distance, doubt);
                        total += luminance(irradiance) * (weight * (1.0 - opened) * shared);
                        if (settled) result += group_radiance_of(node, s, irradiance, direction, distance) * shared;
                    }
                }
            }
        }
        if (estimated) shares[under] = weight * opened;
    }
    if (waiting == 0u) return result;
    total = max(total, 1e-8);
    for (uint i = 0u; i < count; i++) {
        uint entry = light_lists.Load(int3(light_list_texel(block, 1u + i), 0));
        if ((entry & LIGHT_ENTRY_IN) == 0u || (entry & (SETTLED | LIGHT_ENTRY_UNDER)) == SETTLED) continue;
        uint under = entry & LIGHT_ENTRY_UNDER;
        float weight = under > 0u ? shares[under - 1u] : 1.0;
        float opened = 0.0;
        uint at = entry >> LIGHT_ENTRY_NODE;
        if (weight > 0.0 && at < frame.light_nodes) {
            float distance_squared;
            result += weight * local_node(light_nodes[at], s, total, share, (entry & LIGHT_ENTRY_STANDS) != 0u, opened, distance_squared);
        }
        shares[under] = weight * opened;
    }
    return result;
}
#endif
#endif
