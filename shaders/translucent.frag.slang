#include "native.slang"
//! per surface program blend
//! variant hw MIRAI_HW_RT=1
//! variant cost MIRAI_COST=1
//! variant hw_cost MIRAI_HW_RT=1 MIRAI_COST=1
// The light of the blended surfaces behind the per-pixel glass layers, added
// back to front over the scene that glass_filter.frag has filtered: sun and
// local lights with shadow rays where they matter, and the probe volume for
// diffuse and specular indirect light.
#define MIRAI_LIGHT_MAPS
#define SUN_SHADOW_SLOT SLOT_PASS5
#define SHADOW_DATA_SLOT SLOT_PASS8
#define MIRAI_TEXTURE_FEEDBACK
#include "raster.slang"
#include "glass.slang"
#include <extension_hooks.slang>
#ifdef MIRAI_COST
#define COST_SLOT SLOT_PASS7
#include "cost.slang"
#endif

struct Params_Block { uint light_budget; uint near_layer; uint far_layer; uint overflow; };
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);
[[vk::binding(SLOT_PASS0, 0)]] Texture2D<float4> near_layer_depth : register(MIRAI_REGISTER(t, SLOT_PASS0), space0);
[[vk::binding(SLOT_PASS1, 0)]] Texture2D<float4> g_depth : register(MIRAI_REGISTER(t, SLOT_PASS1), space0);
[[vk::binding(SLOT_PASS2, 0)]] Texture2D<float4> far_layer_depth : register(MIRAI_REGISTER(t, SLOT_PASS2), space0);

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
    Glass g = fragment_glass(f, input.in_world);
    float3 color = glass_light(g, glass_shading(f.material, g), float3(0.0), 0.0, overflow ? 0.08 : 0.0, params.light_budget);
    output.out_color = float4(finite_or_zero(color), overflow ? 0.0 : saturate(g.alpha));
    return output;
}
