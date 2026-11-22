#include "native.slang"
//! per surface program blend
//! variant cost MIRAI_COST=1
// The light of the blended surfaces behind the per-pixel glass layers, added
// back to front over the scene that glass_filter.frag has filtered: sun and
// local lights shadowed by the maps of the view alone, whose pages it marks
// for the next frame (a light no map holds reaches it whole), and the probe
// volume for diffuse and specular indirect light.
#define MIRAI_LIGHT_MAPS
#define MIRAI_NO_SHADOW_RAYS
#define SUN_SHADOW_SLOT SLOT_PASS5
#define SHADOW_DATA_SLOT SLOT_PASS8
#define SHADOW_MARKS_SLOT SLOT_PASS6
#define MIRAI_TEXTURE_FEEDBACK
// The lights of its points, decided once for a cell of its instance
// (translucent_draws.comp): a point in it takes every light with shadows that
// reaches it, with no budget since it traces no rays, and those without
// shadows from a list, with no walk of the trees.
#define MIRAI_LIGHTS_GIVEN
#include "raster.slang"
#include "glass.slang"
#include "light_lists.slang"
#include <extension_hooks.slang>
#ifdef MIRAI_COST
#define COST_SLOT SLOT_PASS7
#include "cost.slang"
#endif

struct Params_Block { uint light_budget; uint near_layer; uint far_layer; uint overflow; float3 grid_origin; float grid_cell; uint3 grid_size; uint cells; };
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);
[[vk::binding(SLOT_PASS0, 0)]] Texture2D<float4> near_layer_depth : register(MIRAI_REGISTER(t, SLOT_PASS0), space0);
[[vk::binding(SLOT_PASS1, 0)]] Texture2D<float4> g_depth : register(MIRAI_REGISTER(t, SLOT_PASS1), space0);
[[vk::binding(SLOT_PASS2, 0)]] Texture2D<float4> far_layer_depth : register(MIRAI_REGISTER(t, SLOT_PASS2), space0);
[[vk::binding(SLOT_PASS3, 0)]] StructuredBuffer<uint4> light_grid : register(MIRAI_REGISTER(t, SLOT_PASS3), space0);
[[vk::binding(SLOT_PASS4, 0)]] StructuredBuffer<uint2> entries : register(MIRAI_REGISTER(t, SLOT_PASS4), space0);
#include "direct_grid.slang"

// The cells of the instance of the fragment and the box they split.
static uint2 given_cells;
static float3 given_low, given_high;
bool given_holds(float3 position, uint share) {
    return share == LIGHT_SHARE_ALL && all(position >= given_low) && all(position <= given_high);
}

// Shadowed local lights from the 1m world light_grid (O(1) cell lookup, capped
// to the brightest `budget` lights reaching the point); falls back to light_cut
// only when a single cell holds more than DIRECT_FEW lights.
uint point_light_cut(float3 position, float3 normal, uint budget, uint share) {
    budget = min(budget, LIGHT_CUT_MAX);
    if (budget == 0u || params.cells == 0u) return 0u;
    uint4 row = direct_cell(position);
    uint total = row.y + row.z;
    if (total == 0u) return 0u;
    if (total > DIRECT_FEW) return light_cut(position, normal, budget, share);
    uint count = 0u;
    float worst = FLT_MAX;
    uint worst_at = 0u;
    [loop]
    for (uint i = 0u; i < total; i++) {
        uint light = light_grid[row.x + i].x;
        float w = light_weight(light_grid[params.cells + LIGHT_WEIGHT_ROWS * light],
            light_grid[params.cells + LIGHT_WEIGHT_ROWS * light + 1u], position, normal);
        if (!(w > 0.0)) continue;
        if (count < budget) {
            light_cut_nodes[count] = LIGHT_CUT_DIRECT | light;
            light_cut_needs[count] = w;
            if (w < worst) { worst = w; worst_at = count; }
            count++;
        } else if (w > worst) {
            light_cut_nodes[worst_at] = LIGHT_CUT_DIRECT | light;
            light_cut_needs[worst_at] = w;
            worst = light_cut_needs[0];
            worst_at = 0u;
            [loop]
            for (uint j = 1u; j < count; j++) {
                if (light_cut_needs[j] < worst) { worst = light_cut_needs[j]; worst_at = j; }
            }
        }
    }
    return count;
}

float3 point_shadowless_lighting(Shading s, float known, uint share) {
    int2 block = given_holds(s.position, share) ? light_list_block(translucent_cell_block(given_cells, s.position, given_low, given_high)) : int2(-1, -1);
    return light_list_lighting(s, known, block, share);
}

struct Stage_Output {
    [[vk::location(0)]] float4 out_color : SV_Target0;
};
[shader("fragment")]
Stage_Output main(Raster_Input input, float4 pixel_position : SV_Position, bool front_facing : SV_IsFrontFace) {
    Stage_Output output;
    input = raster_facing(input, front_facing);
    int2 p = int2(pixel_position.xy);
    float opaque = g_depth.Load(int3(p, 0)).r;
    float depth = fragment_depth(input);
    if (params.near_layer != 0u && !behind_layer(depth, near_layer_depth.Load(int3(p, 0)).r)) discard;
    if (params.far_layer != 0u && behind_layer(depth, far_layer_depth.Load(int3(p, 0)).r)) discard;
    bool overflow = params.overflow != 0u;
    if (!fragment_forward(input, fragment_material(input), opaque, overflow)) discard;
#ifdef MIRAI_COST
    if (!IsHelperLane()) {
        uint mesh = cost_instance_mesh(input.in_instance);
        cost_add(mesh, input.in_material, COST_TRANSLUCENT_FRAGMENTS, 1u);
    }
#endif
    Fragment f = fragment_evaluate(input, opaque);
    Instance inst = scene_instance(input.in_instance);
    given_cells = entries[input.in_instance];
    given_low = inst.bounds_min.xyz;
    given_high = inst.bounds_max.xyz;
    Glass g = fragment_glass(f, input.in_world);
    float3 color = glass_light(g, glass_shading(f.material, g), overflow ? 0.08 : 0.0, params.light_budget);
    output.out_color = float4(finite_or_zero(color), overflow ? 0.0 : saturate(g.alpha));
    return output;
}
