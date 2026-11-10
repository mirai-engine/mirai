#include "native.slang"
//! per surface program
//! variant hw MIRAI_HW_RT=1
// color: with colored shadows, the rays cross glass as the mean of its instance (trace.slang).
//! constant color MIRAI_GLASS_MEANS
// The light of the blended surfaces behind the per-pixel glass layers, added
// back to front over the scene that glass_filter.frag has filtered: sun and
// local lights with shadow rays where they matter, and the probe volume for
// diffuse and specular indirect light.
#include "raster.slang"
#include "glass.slang"
#include <extension_hooks.slang>

struct Params_Block { uint light_budget; uint pad0; uint pad1; uint pad2; };
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);
[[vk::binding(SLOT_PASS0, 0)]] Texture2D<float4> last_layer_depth : register(MIRAI_REGISTER(t, SLOT_PASS0), space0);
[[vk::binding(SLOT_PASS1, 0)]] Texture2D<float4> g_depth : register(MIRAI_REGISTER(t, SLOT_PASS1), space0);

struct Stage_Output {
    [[vk::location(0)]] float4 out_color : SV_Target0;
};
[shader("fragment")]
Stage_Output main(Raster_Input input, float4 pixel_position : SV_Position, bool front_facing : SV_IsFrontFace) {
    Stage_Output output;
    int2 p = int2(pixel_position.xy);
    float opaque = g_depth.Load(int3(p, 0)).r;
    if (!fragment_forward(input, front_facing, last_layer_depth.Load(int3(p, 0)).r, opaque)) discard;
    Fragment f = fragment_evaluate(input, opaque);
    // Behind a layer of glass, the few percent a pane reflects of the probes do not show.
    Glass g = fragment_glass(f, input.in_world);
    float3 color = glass_light(f.material, g, glass_shading(f.material, g), float3(0.0), 0.0, 0.08, params.light_budget);
    output.out_color = float4(finite_or_zero(color), 0.0);
    return output;
}
