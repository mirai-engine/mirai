#include "native.slang"
//! variant scan MIRAI_LIGHT_GRID_SCAN=1
//! variant fill MIRAI_LIGHT_GRID_FILL=1
//! variant weights MIRAI_LIGHT_GRID_WEIGHTS=1
// The grid of the local lights (render/light_grid.odin), in three passes over
// its cells: this one counts the lights whose range reaches each cell, down
// the tree of the lights; with MIRAI_LIGHT_GRID_SCAN one group adds the counts
// up into the row of the first entry of each cell; with MIRAI_LIGHT_GRID_FILL
// each cell puts its lights there, each as likely as what it could give the
// cell, in an alias table (Vose) built in place. With
// MIRAI_LIGHT_GRID_WEIGHTS, a pass over the lights writes the record each is
// weighed by (light_weight.slang) after the rows of the cells.
#include "scene.slang"
#include "lighting.slang"
#include "light_weight.slang"
#ifdef MIRAI_LIGHT_GRID_SCAN
#define MIRAI_GROUP_X 1024
#else
#define MIRAI_GROUP_X 64
#endif
#define MIRAI_GROUP_Y 1
#define MIRAI_GROUP_Z 1

// origin: the corner of the first cell; cell: metres a side; size: cells
// along each axis, x first; cells: all of them; lights: all of them, whose
// records come before the entries; grow: 1 for a cell to take the lights
// that reach it grown by half a cell to each side; rows: of the buffer.
struct Params_Block { float3 origin; float cell; uint3 size; uint cells; uint lights; uint grow; uint rows; uint pad0; };
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);
// A row for each cell, the row of its first entry, how many there are in its
// table, how many after them it lists apart and what those of its table could
// give it together; the records of the lights;
// then the entries: a light, the entry of its cell, from the first, a draw
// goes to when this one does not keep it, the chance that it keeps it and the
// chance of drawing its light in the cell. Up to LIGHT_GRID_APART lights the
// edge of whose cone or plane crosses the cell go apart, after the table, with
// what they could give the cell in .w: the table is that of the cell without
// them, and a point their light does not reach draws from it as if they were
// not there (direct_grid.slang).
[[vk::binding(SLOT_PASS0, 0)]] RWStructuredBuffer<uint4> light_grid : register(MIRAI_REGISTER(u, SLOT_PASS0), space0);

#if defined(MIRAI_LIGHT_GRID_WEIGHTS)
[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 dispatch_id : SV_DispatchThreadID) {
    uint light = dispatch_id.x;
    if (light >= params.lights) return;
    uint4 center, shape;
    light_weight_rows(lights[light], center, shape);
    light_grid[params.cells + LIGHT_WEIGHT_ROWS * light] = center;
    light_grid[params.cells + LIGHT_WEIGHT_ROWS * light + 1u] = shape;
}
#elif defined(MIRAI_LIGHT_GRID_SCAN)
groupshared uint scan_sums[MIRAI_GROUP_X];

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint index : SV_GroupIndex) {
    uint carry = 0u;
    for (uint base = 0u; base < params.cells; base += MIRAI_GROUP_X) {
        uint cell = base + index;
        uint count = cell < params.cells ? light_grid[cell].y : 0u;
        scan_sums[index] = count;
        GroupMemoryBarrierWithGroupSync();
        for (uint step = 1u; step < MIRAI_GROUP_X; step <<= 1u) {
            uint add = index >= step ? scan_sums[index - step] : 0u;
            GroupMemoryBarrierWithGroupSync();
            scan_sums[index] += add;
            GroupMemoryBarrierWithGroupSync();
        }
        if (cell < params.cells) light_grid[cell].x = params.cells + LIGHT_WEIGHT_ROWS * params.lights + carry + scan_sums[index] - count;
        carry += scan_sums[MIRAI_GROUP_X - 1u];
        GroupMemoryBarrierWithGroupSync();
    }
}
#else
// With params.grow, a cell takes the lights that reach it grown by half a
// cell to each side, so that a point near the border of its cell finds there
// the lights that reach it from beyond.

// What a light could give the cell whose lowest corner is low: its power by
// the window of its range at the nearest point of the grown cell, over the
// square of the distance to its center; none when no point of the grown cell
// is in its range, in the cone of a spot or on the side a rectangle lights.
float light_grid_weight(Light l, float3 low, out bool edged) {
    edged = false;
    float3 center = l.position_range.xyz;
    float range = l.position_range.w;
    float grown = params.grow != 0u ? 0.5 * params.cell : 0.0;
    float near = length(clamp(center, low - grown, low + params.cell + grown) - center);
    if (near >= range) return 0.0;
    float half_side = 0.5 * params.cell + grown;
    float3 to = low + 0.5 * params.cell - center;
    float distance = length(to);
    bool rect = l.direction_cone.w < 0.5 * (LIGHT_POINT + LIGHT_RECT);
    float extent = rect ? length(l.size.yz) : l.size.x + l.size.y;
    float corner = half_side * 1.7320508;
    if (rect) {
        float3 facing = l.direction_cone.xyz;
        float ahead = dot(to, facing);
        float spread = half_side * (abs(facing.x) + abs(facing.y) + abs(facing.z));
        if (ahead + spread <= 0.0) return 0.0;
        edged = ahead - spread <= 0.0;
    } else if (l.direction_cone.w > 0.5 * LIGHT_POINT) {
        // Within the cone a spot lights the cell as a point; the edge fades from 0.8 of its angle out (light_contribution).
        edged = true;
        if (distance > corner + extent) {
            float off = acos(clamp(dot(to / distance, l.direction_cone.xyz), -1.0, 1.0));
            float across = asin(min((corner + extent) / distance, 1.0));
            float edge = acos(clamp(l.direction_cone.w, -1.0, 1.0));
            if (off - across >= edge) return 0.0;
            edged = off + across > 0.8 * edge;
        }
    }
    return max(luminance(l.color_intensity.rgb) * l.color_intensity.w * light_window(near, range) / max(distance * distance, corner * corner + extent * extent), 1e-30);
}

// The lights whose range reaches the grown cell whose lowest corner is low, down the
// tree of the lights, and what those of its table could give it together; with
// room, those of the table written from row `first`, each with its weight, and
// the `apart` of them it lists apart from the last row of the room back.
uint light_grid_walk(float3 low, uint first, uint room, out float total, out uint apart) {
    total = 0.0;
    apart = 0u;
    uint count = 0u;
    if (frame.light_nodes == 0u) return 0u;
    float grown = params.grow != 0u ? 0.5 * params.cell : 0.0;
    float3 grown_low = low - grown, grown_high = low + params.cell + grown;
    uint pending[LIGHT_TREE_DEPTH];
    uint depth = 0u;
    uint at = 0u;
    [loop]
    while (true) {
        Light_Node node = light_nodes[at];
        float3 away = clamp(node.center_radius.xyz, grown_low, grown_high) - node.center_radius.xyz;
        if (dot(away, away) < node.power_reach.w * node.power_reach.w) {
            if ((node.flags & LIGHT_NODE_LEAF) != 0u) {
                bool edged;
                float weight = light_grid_weight(lights[node.child], low, edged);
                if (weight > 0.0 && edged && apart < LIGHT_GRID_APART) {
                    if (room > 0u) light_grid[first + room - 1u - apart] = uint4(node.child, 0u, 0u, asuint(weight));
                    apart++;
                } else if (weight > 0.0) {
                    if (count < room) light_grid[first + count] = uint4(node.child, count, 0u, asuint(weight));
                    total += weight;
                    count++;
                }
            } else if (depth < LIGHT_TREE_DEPTH) {
                pending[depth] = node.child;
                depth++;
                at++;
                continue;
            }
        }
        if (depth == 0u) break;
        depth--;
        at = pending[depth];
    }
    return count + apart;
}

#ifdef MIRAI_LIGHT_GRID_FILL
// The first entry from `from` on whose draws exceed one, of the n from `first`; n for none.
uint light_grid_large(uint first, uint n, uint from) {
    for (uint i = from; i < n; i++) {
        if (asfloat(light_grid[first + i].z) >= 1.0) return i;
    }
    return n;
}
#endif

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 dispatch_id : SV_DispatchThreadID) {
    uint cell = dispatch_id.x;
    if (cell >= params.cells) return;
    uint3 place = uint3(cell % params.size.x, (cell / params.size.x) % params.size.y, cell / (params.size.x * params.size.y));
    float3 low = params.origin + float3(place) * params.cell;
    float total;
#ifdef MIRAI_LIGHT_GRID_FILL
    uint4 row = light_grid[cell];
    if (row.y == 0u) return;
    uint first = row.x;
    // The lights a pass writes on the GPU are not in the rows the CPU counted:
    // a cell whose entries would go past the buffer lists none.
    if (first > params.rows || row.y > params.rows - first) {
        light_grid[cell] = uint4(first, 0u, 0u, 0u);
        return;
    }
    uint apart;
    uint n = min(light_grid_walk(low, first, row.y, total, apart), row.y) - apart;
    light_grid[cell] = uint4(first, n, apart, asuint(total));
    // In .z the draws of each entry out of n, to be shared by the alias
    // table; in .w the chance of drawing its light.
    for (uint i = 0u; i < n; i++) {
        uint4 entry = light_grid[first + i];
        float weight = asfloat(entry.w);
        light_grid[first + i] = uint4(entry.x, i, asuint(weight * float(n) / total), asuint(weight / total));
    }
    // An entry with less than one draw keeps that much and hands the rest to
    // one with more, which may then have less than one: it is the next to
    // hand out. An entry is done when it names another.
    uint scan = 0u;
    uint large = light_grid_large(first, n, 0u);
    uint handed = INVALID;
    [loop]
    while (true) {
        uint small = n;
        if (handed != INVALID) {
            small = handed;
            handed = INVALID;
        } else {
            for (; scan < n; scan++) {
                uint4 entry = light_grid[first + scan];
                if (asfloat(entry.z) < 1.0 && entry.y == scan) {
                    small = scan;
                    scan++;
                    break;
                }
            }
        }
        if (small >= n || large >= n) break;
        float keep = asfloat(light_grid[first + small].z);
        light_grid[first + small].y = large;
        float left = asfloat(light_grid[first + large].z) + keep - 1.0;
        light_grid[first + large].z = asuint(left);
        if (left < 1.0) {
            handed = large;
            large = light_grid_large(first, n, large + 1u);
        }
    }
    // What none was handed to keeps all of its draws.
    for (uint i = 0u; i < n; i++) {
        if (light_grid[first + i].y == i) light_grid[first + i].z = asuint(1.0);
    }
#else
    uint apart;
    light_grid[cell] = uint4(0u, light_grid_walk(low, 0u, 0u, total, apart), 0u, 0u);
#endif
}
#endif
