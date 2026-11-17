#include "native.slang"
// The lists of the lights that cast no shadows of the screen tiles of a view
// (light_lists.slang, render/light_lists.odin), a thread a tile: the box of
// the points of its pixels and that of their normals, then what the walks of
// the tree would visit for any point in them. Each walk is followed over the
// cell with bounds in place of a point. A group none of whose lights can
// reach the cell is left out with what lies under it; one that opens whole at
// every point is left out and what lies under it listed; one that stands for
// its lights at every point (what it may err at most, against the least light
// the estimate gives the cell) is listed alone; any other is listed with what
// lies under it, and each point weighs them as its walk would. The bounds are
// loose, never tight: a list holds more than a point needs, never less.
//
// A list keeps LIGHT_LIST_ROUGH nodes of the estimate and LIGHT_LIST_FINE of
// the light. A cell that would list more lists none (LIGHT_LIST_WALK): its
// points walk the tree, each by itself (Stats_Block.lists counts it).
#define GBUFFER_NORMAL SLOT_PASS0
#define LIGHT_LISTS_WRITTEN
#include "light_lists.slang"
#include "gbuffer.slang"
#include "pixel.slang"
#include "cull_stats.slang"
#define MIRAI_GROUP_X 8
#define MIRAI_GROUP_Y 8
#define MIRAI_GROUP_Z 1
#if LIGHT_LIST_ROUGH + LIGHT_LIST_FINE >= LIGHT_LIST_WORDS
#error a list holds its count and the nodes of both walks
#endif

// tiles: across and down the view.
struct Params_Block { uint2 tiles; uint pad0; uint pad1; };
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);
[[vk::binding(SLOT_PASS1, 0)]] Texture2D<float4> g_depth : register(MIRAI_REGISTER(t, SLOT_PASS1), space0);
[[vk::binding(SLOT_PASS2, 0)]] [[vk::image_format("r32ui")]] RWTexture2D<uint> out_lists : register(MIRAI_REGISTER(u, SLOT_PASS2), space0);
[[vk::binding(SLOT_PASS3, 0)]] RWStructuredBuffer<Stats_Block> list_stats : register(MIRAI_REGISTER(u, SLOT_PASS3), space0);

// The points the list of the thread serves: the box that holds them, the
// sphere around it, and the box that holds their normals.
struct Cell {
    float3 low;
    float3 high;
    float3 middle;
    float radius;
    float3 normal_low;
    float3 normal_high;
};
static Cell cell;

// What a node is to the points of a cell: how near and how far its center
// lies; the least and the most cosine between their normals and the direction
// to it; the most its center rises over the plane of any of them; and the
// most and the least of its light that reaches them by the directions its
// lights face (node_aims).
struct Span {
    float near;
    float far;
    float cosine_low;
    float cosine_high;
    float rise;
    float most;
    float least;
};

Span cell_span(Light_Node node) {
    Span span;
    float3 center = node.center_radius.xyz;
    span.near = length(clamp(center, cell.low, cell.high) - center);
    span.far = length(max(abs(center - cell.low), abs(center - cell.high)));
    float3 from = center - cell.high, to = center - cell.low;
    float3 a = from * cell.normal_low, b = from * cell.normal_high, c = to * cell.normal_low, d = to * cell.normal_high;
    float3 low = min(min(a, b), min(c, d)), high = max(max(a, b), max(c, d));
    float rise_low = low.x + low.y + low.z;
    span.rise = high.x + high.y + high.z;
    span.cosine_high = min(span.rise / max(span.rise > 0.0 ? span.near : span.far, 1e-6), 1.0);
    span.cosine_low = max(rise_low / max(rise_low > 0.0 ? span.far : span.near, 1e-6), -1.0);
    span.most = 1.0;
    span.least = 1.0;
    float inner = min(node_inner(node), node.cone.w);
    if (node.cone.w < PI - 1e-3 || inner < PI - 1e-2) {
        float3 away = cell.middle - center;
        float distance = length(away);
        float radius = node.center_radius.w;
        span.least = 0.0;
        if (distance - cell.radius > radius) {
            // From the node, the cell spans `around` to each side of its middle,
            // and from the cell the sphere of the node at most `sphere`.
            float theta = acos(clamp(dot(node.cone.xyz, away / distance), -1.0, 1.0));
            float around = asin(min(cell.radius / distance, 1.0));
            float sphere = asin(min(radius / (distance - cell.radius), 1.0));
            float falloff = node_falloff(node);
            if (node.cone.w < PI - 1e-3) span.most = node_aim_past(max(theta - around - node.cone.w - sphere, 0.0), falloff);
            span.least = node_aim_past(max(theta + around + sphere + node.cone.w - 2.0 * inner, 0.0), falloff);
        }
    }
    return span;
}

// Whether a node may reach some point of the cell (node_reaches).
bool span_reaches(Light_Node node, Span span) {
    return span.near < node.power_reach.w && span.rise > -node.center_radius.w && span.most > 0.0;
}

// The least irradiance a sphere of unit intensity gives the points of the
// cell: none unless all of it is above the horizon of every one.
float span_irradiance_least(Span span, float radius) {
    float r = max(radius, LIGHT_RADIUS_MIN);
    if (!(span.cosine_low * span.near > r)) return 0.0;
    return span.cosine_low / max(span.far * span.far, r * r);
}

// The least a node adds to the estimate of a point of the cell where it
// stands for its lights (node_contribution): of a light, while it is a
// sphere that projects no texture and the cell lies where it shines whole.
float span_least(Light_Node node, Span span) {
    float power = luminance(node.power_reach.rgb);
    if ((node.flags & LIGHT_NODE_LEAF) != 0u) {
        Light light = lights[node.child];
        if (light_is_rect(light) || light_is_capsule(light) || light_projects(light) || span.least < 1.0) return 0.0;
        return power * span_irradiance_least(span, light.size.x) * light_window(span.far, light.position_range.w);
    }
    float deviation = node.spread * 0.57735027;
    float window = 0.5 * (node_window(node, span.far - deviation) + node_window(node, span.far + deviation));
    return power * span_irradiance_least(span, node.spread) * span.least * window;
}

// The most the window of a group bends at a point of the cell (node_bend).
float span_bend(Light_Node node, Span span) {
    return light_window(span.near - node.center_radius.w, node.range_high) - light_window(span.far + node.center_radius.w, node.range_low);
}

// The most a group may err at a point of the cell (the doubt of group_contribution).
float span_doubt(Light_Node node, Span span) {
    float unaimed = luminance(node.power_reach.rgb) * sphere_irradiance(span.cosine_high, span.near, node.spread);
    float spread = node.spread / max(span.near, 1e-6);
    float cosine = span.cosine_low > 0.0 ? span.cosine_low : span.cosine_high < 0.0 ? -span.cosine_high : 0.0;
    float horizon = saturate(1.0 - cosine / max(spread, 1e-6));
    float deviation = node.spread * 0.57735027;
    float window = 0.5 * (node_window(node, span.near - deviation) + node_window(node, span.near + deviation));
    return unaimed * span.most * ((3.0 * spread * spread + horizon) * window + 0.5 * span_bend(node, span)) + unaimed * (span.most - span.least) * window;
}

// What a group is to every point of a cell: it stands for its lights, it
// opens whole, or neither is sure.
#define GROUP_STANDS 0u
#define GROUP_MAY_OPEN 1u
#define GROUP_OPENS 2u

// For the estimate (estimate_node).
uint rough_group(Light_Node node, Span span) {
    float radius = node.center_radius.w;
    if (radius >= ESTIMATE_OPENED * span.far) return GROUP_OPENS;
    if (radius <= ESTIMATE_GROUPED * span.near && span_bend(node, span) <= ESTIMATE_GROUPED) return GROUP_STANDS;
    return GROUP_MAY_OPEN;
}
// For the light (local_node). `total`: the least light the estimate gives a point of the cell.
uint fine_group(Light_Node node, Span span, float total) {
    float radius = node.center_radius.w;
    if (radius >= GROUP_INSIDE * span.far) return GROUP_OPENS;
    if (radius <= GROUP_NEAR * span.near && span_doubt(node, span) <= LIGHTS_GROUPED * total) return GROUP_STANDS;
    return GROUP_MAY_OPEN;
}

// What the thread keeps of a walk of the tree over its cell: the nodes it
// lists, in the order of the tree, each the node from LIGHT_ENTRY_NODE and its
// field; and of each group it is under, its second child and how many listed
// groups that may open lie over that.
static uint walk_entries[LIGHT_LIST_FINE];
static uint walk_count;
static uint walk_pending[LIGHT_TREE_DEPTH];
static uint walk_under[LIGHT_TREE_DEPTH];

// Lists what the walk of the estimate, or with `fine` that of the light,
// visits for the points of the cell: a group before what lies under it, its
// first child and what lies under that before its second. False when they
// are more than `room`.
bool cell_walk(bool fine, float total, uint room) {
    walk_count = 0u;
    uint depth = 0u;
    uint at = frame.shadowless_lights;
    uint under = 0u;
    [loop]
    while (true) {
        Light_Node node = light_nodes[at];
        Span span = cell_span(node);
        if (span_reaches(node, span)) {
            bool leaf = (node.flags & LIGHT_NODE_LEAF) != 0u;
            uint group = leaf || !light_node_opens(node, at) ? GROUP_STANDS : fine ? fine_group(node, span, total) : rough_group(node, span);
            if (group != GROUP_OPENS) {
                if (walk_count >= room) return false;
                walk_entries[walk_count] = (at << LIGHT_ENTRY_NODE) | LIGHT_ENTRY_IN | (group == GROUP_STANDS ? LIGHT_ENTRY_STANDS : 0u) | under;
                walk_count++;
            }
            if (group != GROUP_STANDS) {
                if (group == GROUP_MAY_OPEN) under++;
                if (under >= LIGHT_LIST_DEPTH || depth >= LIGHT_TREE_DEPTH) return false;
                walk_pending[depth] = node.child;
                walk_under[depth] = under;
                depth++;
                at++;
                continue;
            }
        }
        if (depth == 0u) break;
        depth--;
        at = walk_pending[depth];
        under = walk_under[depth];
    }
    return true;
}

// The least the estimate gives a point of the cell, from what its walk
// listed: each node that stands, the least it adds; a group that may open,
// the lesser of that and what lies under it.
float rough_least() {
    float sums[LIGHT_LIST_DEPTH + 1];
    for (uint i = 0u; i <= LIGHT_LIST_DEPTH; i++) sums[i] = 0.0;
    for (uint i = walk_count; i > 0u; i--) {
        uint entry = walk_entries[i - 1u];
        uint under = entry & LIGHT_ENTRY_UNDER;
        Light_Node node = light_nodes[entry >> LIGHT_ENTRY_NODE];
        float least = span_least(node, cell_span(node));
        if ((entry & LIGHT_ENTRY_STANDS) == 0u) least = min(least, sums[under + 1u]);
        sums[under + 1u] = 0.0;
        sums[under] += least;
    }
    return sums[0];
}

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 id : SV_DispatchThreadID) {
    if (any(id.xy >= params.tiles)) return;
    int2 block = int2(id.xy) * LIGHT_LIST_BLOCK;
    int2 corner = int2(id.xy) * int(LIGHT_LIST_TILE);
    int2 size = int2(frame.resolution);
    cell.low = float3(FLT_MAX);
    cell.high = float3(-FLT_MAX);
    cell.normal_low = float3(1.0);
    cell.normal_high = float3(-1.0);
    for (uint k = 0u; k < LIGHT_LIST_TILE * LIGHT_LIST_TILE; k++) {
        int2 p = corner + int2(int(k % LIGHT_LIST_TILE), int(k / LIGHT_LIST_TILE));
        if (any(p >= size)) continue;
        float depth = g_depth.Load(int3(p, 0)).r;
        if (depth_empty(depth)) continue;
        float3 position = pixel_at(p, (float2(p) + 0.5) * frame.inv_resolution, depth).position;
        float3 normal = gbuffer_normal(p);
        cell.low = min(cell.low, position);
        cell.high = max(cell.high, position);
        cell.normal_low = min(cell.normal_low, normal);
        cell.normal_high = max(cell.normal_high, normal);
    }
    if (cell.low.x > cell.high.x) {
        out_lists[block] = 0u;
        return;
    }
    cell.middle = 0.5 * (cell.low + cell.high);
    cell.radius = 0.5 * length(cell.high - cell.low);

    uint rough[LIGHT_LIST_ROUGH];
    bool fits = cell_walk(false, 0.0, LIGHT_LIST_ROUGH);
    uint rough_count = walk_count;
    if (fits) {
        float least = rough_least();
        for (uint i = 0u; i < rough_count; i++) rough[i] = walk_entries[i];
        fits = cell_walk(true, max(least, 1e-8), LIGHT_LIST_FINE);
    }
    InterlockedAdd(list_stats[0].lists[0], 1u);
    if (!fits) {
        out_lists[block] = LIGHT_LIST_WALK;
        InterlockedAdd(list_stats[0].lists[2], 1u);
        return;
    }

    // Both in one list, in the order of the tree, a node once.
    uint i = 0u, j = 0u, count = 0u;
    [loop]
    while (i < rough_count || j < walk_count) {
        uint a = i < rough_count ? rough[i] >> LIGHT_ENTRY_NODE : INVALID;
        uint b = j < walk_count ? walk_entries[j] >> LIGHT_ENTRY_NODE : INVALID;
        uint entry = min(a, b) << LIGHT_ENTRY_NODE;
        if (a <= b) {
            entry |= (rough[i] & ((1u << LIGHT_ENTRY_ROUGH) - 1u)) << LIGHT_ENTRY_ROUGH;
            i++;
        }
        if (b <= a) {
            entry |= walk_entries[j] & ((1u << LIGHT_ENTRY_ROUGH) - 1u);
            j++;
        }
        count++;
        out_lists[light_list_texel(block, count)] = entry;
    }
    out_lists[block] = count;
    InterlockedAdd(list_stats[0].lists[1], count);
    InterlockedMax(list_stats[0].lists[3], count);
}
