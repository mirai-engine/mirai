// The exposure of the view as FSR 3.1 reads it, a 1x1 texture, and, when the
// history starts, its frame info as ffx_fsr3upscaler.cpp resets it.
#include "native.slang"
#include "common.slang"
#include "exposure.slang"
#include "custom_slots.slang"

struct Params {uint reset; uint3 pad;};
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);
[[vk::binding(CUSTOM_SLOT_2, 0)]] StructuredBuffer<Exposure_State> exposure : register(MIRAI_REGISTER(t, CUSTOM_SLOT_2), space0);
[[vk::binding(CUSTOM_SLOT_3, 0)]] [[vk::image_format("rg32f")]] RWTexture2D<float2> fsr_exposure : register(MIRAI_REGISTER(u, CUSTOM_SLOT_3), space0);
[[vk::binding(CUSTOM_SLOT_4, 0)]] [[vk::image_format("rgba32f")]] RWTexture2D<float4> frame_info : register(MIRAI_REGISTER(u, CUSTOM_SLOT_4), space0);

[shader("compute")]
[numthreads(1, 1, 1)]
void main() {
    Exposure_State state = exposure[0];
    fsr_exposure[uint2(0, 0)] = float2(state.valid != 0u ? state.exposure : 0.0, 0.0);
    if (params.reset != 0u) frame_info[uint2(0, 0)] = float4(-1.0, 1e8, 0.0, 0.0);
}
