#include "native.slang"
//! per surface program
// What a blended surface behind the per-pixel glass layers leaves of the
// scene behind it, multiplied into the color target; translucent.frag then
// adds the light of the surface.
#include "raster.slang"
#include "glass.slang"

[[vk::binding(SLOT_PASS0, 0)]] Texture2D<float4> last_layer_depth : register(MIRAI_REGISTER(t, SLOT_PASS0), space0);
[[vk::binding(SLOT_PASS1, 0)]] Texture2D<float4> g_depth : register(MIRAI_REGISTER(t, SLOT_PASS1), space0);

struct Stage_Output {
    [[vk::location(0)]] float4 out_filter : SV_Target0;
};
[shader("fragment")]
Stage_Output main(Raster_Input input, float4 pixel_position : SV_Position, bool front_facing : SV_IsFrontFace) {
    Stage_Output output;
    int2 p = int2(pixel_position.xy);
    float opaque = g_depth.Load(int3(p, 0)).r;
    if (!fragment_forward(input, front_facing, last_layer_depth.Load(int3(p, 0)).r, opaque)) discard;
    Fragment f = fragment_evaluate(input, opaque);
    output.out_filter = float4(glass_filter(f.material, fragment_glass(f, input.in_world)), 1.0);
    return output;
}
