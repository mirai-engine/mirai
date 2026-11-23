#include "native.slang"
//! per surface program blend
//! variant cost MIRAI_COST=1
// The light of the blended surfaces behind the per-pixel glass layers, added
// back to front over the scene that glass_filter.frag has filtered: sun and
// local lights shadowed by the texel of the maps of the view they fall in,
// whose pages it marks for the next frame (a light no map holds reaches it
// whole), and the probe volume for diffuse and specular indirect light.
// [earlydepthstencil] lets hardware reject fragments hidden behind the opaque
// depth buffer before running lighting or storage-buffer atomics.
//
// unlayered: no blended instance in sight has material layers.
// quiet: off the feedback turn of the program, texture feedback is skipped.
// unlisted: the frame has no shadowless lights, compiling out the shadowless
// list walk and its thread-private arrays.
//! constant unlayered MIRAI_MATERIAL_NO_LAYERS
//! constant quiet MIRAI_TEXTURE_FEEDBACK_QUIET
//! constant unlisted MIRAI_TRANSLUCENT_UNLISTED
#define MIRAI_LIGHT_MAPS
#define MIRAI_NO_SHADOW_RAYS
#define SUN_SHADOW_SLOT SLOT_PASS5
#define SHADOW_DATA_SLOT SLOT_PASS8
#define SHADOW_MARKS_SLOT SLOT_PASS6
#define MIRAI_TEXTURE_FEEDBACK
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

// Shadowed lights of a forward blend point: brightest up to min(budget, TRANSLUCENT_LIGHTS)
// from the world light_grid cell, capped at DIRECT_FEW cell entries so coarse cells never
// trigger an unbounded per-fragment scan.
#define TRANSLUCENT_LIGHTS 8u
static uint given_lights[TRANSLUCENT_LIGHTS];
static uint given_instance;
static float3 given_low, given_high;

uint point_light_cut(float3 position, float3 normal, uint budget, uint share) {
    budget = min(budget, TRANSLUCENT_LIGHTS);
    if (budget == 0u || params.cells == 0u) return 0u;
    uint4 row = direct_cell(position);
    uint total = row.y + row.z;
    if (total == 0u) return 0u;
    uint limit = min(total, DIRECT_FEW);
    float weights[TRANSLUCENT_LIGHTS];
    uint count = 0u;
    float worst = FLT_MAX;
    uint worst_at = 0u;
    [loop]
    for (uint i = 0u; i < limit; i++) {
        uint light = light_grid[row.x + i].x;
        float w = light_weight(light_grid[params.cells + LIGHT_WEIGHT_ROWS * light],
            light_grid[params.cells + LIGHT_WEIGHT_ROWS * light + 1u], position, normal);
        if (!(w > 0.0)) continue;
        if (count < budget) {
            given_lights[count] = light;
            weights[count] = w;
            if (w < worst) { worst = w; worst_at = count; }
            count++;
        } else if (w > worst) {
            given_lights[worst_at] = light;
            weights[worst_at] = w;
            worst = weights[0];
            worst_at = 0u;
            [loop]
            for (uint j = 1u; j < count; j++) {
                if (weights[j] < worst) { worst = weights[j]; worst_at = j; }
            }
        }
    }
    return count;
}

uint point_light_item(uint i) {
    return LIGHT_CUT_DIRECT | given_lights[i];
}

float3 point_shadowless_lighting(Shading s, float known, uint share) {
    if (MIRAI_TRANSLUCENT_UNLISTED) return float3(0.0);
    bool held = share == LIGHT_SHARE_ALL && all(s.position >= given_low) && all(s.position <= given_high);
    int2 block = held ? light_list_block(translucent_cell_block(entries[given_instance], s.position, given_low, given_high)) : int2(-1, -1);
    return light_list_lighting(s, known, block, share);
}

struct Stage_Output {
    [[vk::location(0)]] float4 out_color : SV_Target0;
};
[shader("fragment")]
[earlydepthstencil]
Stage_Output main(Raster_Input input, float4 pixel_position : SV_Position, bool front_facing : SV_IsFrontFace) {
    Stage_Output output;
    input = raster_facing(input, front_facing);
    int2 p = int2(pixel_position.xy);
    float depth = fragment_depth(input);
    if (params.near_layer != 0u && !behind_layer(depth, near_layer_depth.Load(int3(p, 0)).r)) discard;
    if (params.far_layer != 0u && behind_layer(depth, far_layer_depth.Load(int3(p, 0)).r)) discard;
    bool overflow = params.overflow != 0u;
    Instance inst = scene_instance(input.in_instance);
    Material material = material_row(input.in_material, inst.material_values);
    if (!fragment_forward(input, material, overflow)) discard;
#ifdef MIRAI_COST
    if (!IsHelperLane()) {
        uint mesh = cost_instance_mesh(input.in_instance);
        cost_add(mesh, input.in_material, COST_TRANSLUCENT_FRAGMENTS, 1u);
    }
#endif
    // Unlit non-program forward blends need no normal map, PBR, lights, shadows or probes.
    if (!overflow && material.program_id == 0u && (material.layers & MATERIAL_LAYER_UNLIT) != 0u) {
        float2 bias = float2(frame.texturing.x);
        float covered = saturate(material_base_color(material, input.in_uv, input.in_uv1, bias, input.in_color, false).a);
        if (!(covered > 0.0)) discard;
        float3 emissive = material.emission;
        if (material_has(material.textures[MATERIAL_MAP_EMISSION])) {
            emissive *= material_map_texel(material, MATERIAL_MAP_EMISSION, material.textures[MATERIAL_MAP_EMISSION], input.in_uv, input.in_uv1, bias, false).rgb;
        }
        float3 color = emission_render_units(emissive + input.in_emission, material.emission_mode == EMISSION_RELATIVE) * covered;
        output.out_color = float4(finite_or_zero(color), covered);
        return output;
    }
    Fragment f = fragment_evaluate(input, material, inst, g_depth.Load(int3(p, 0)).r);
    Glass g = fragment_glass(f, input.in_world);
    if (!overflow && !(g.alpha > 0.0)) discard;
    if (!MIRAI_TRANSLUCENT_UNLISTED) {
        given_instance = input.in_instance;
        given_low = inst.bounds_min.xyz;
        given_high = inst.bounds_max.xyz;
    }
    float3 color = glass_light(g, glass_shading(f.material, g), overflow ? 0.08 : 0.0, params.light_budget);
    output.out_color = float4(finite_or_zero(color), overflow ? 0.0 : saturate(g.alpha));
    return output;
}
