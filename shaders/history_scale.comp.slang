#include "native.slang"
// Multiplies the light a history holds, its rgb, by params.scale: what it
// gathered in the render units of one light scale, in those of the next
// (Renderer.light_rescale), so that a new light scale keeps every history.
// An atlas of the probe volume holds it encoded (probe_light_encode).
#include "common.slang"
#define MIRAI_GROUP_X 8
#define MIRAI_GROUP_Y 8
#define MIRAI_GROUP_Z 1

struct Params_Block { float scale; uint encoded; uint pad1; uint pad2; };
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);
[[vk::binding(SLOT_PASS0, 0)]] [[vk::image_format("rgba16f")]] RWTexture2D<float4> history : register(MIRAI_REGISTER(u, SLOT_PASS0), space0);

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 dispatch_id : SV_DispatchThreadID) {
    int2 p = int2(dispatch_id.xy);
    if (any(p >= texture_size(history))) return;
    float4 held = history[p];
    float3 light = params.encoded != 0u ? probe_light_encode(probe_light_decode(held.rgb) * params.scale) : held.rgb * params.scale;
    history[p] = float4(light, held.a);
}
