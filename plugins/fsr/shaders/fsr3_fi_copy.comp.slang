// The final image of the frame, kept for the next one to interpolate from: the
// copy of ffxFrameInterpolationDispatch into its previous interpolation source.
#include "native.slang"
#include "custom_slots.slang"

[[vk::binding(CUSTOM_SLOT_2, 0)]] Texture2D<float4> source : register(MIRAI_REGISTER(t, CUSTOM_SLOT_2), space0);
[[vk::binding(CUSTOM_SLOT_3, 0)]] RWTexture2D<float4> target : register(MIRAI_REGISTER(u, CUSTOM_SLOT_3), space0);

[shader("compute")]
[numthreads(8, 8, 1)]
void main(uint2 id : SV_DispatchThreadID) {
    uint width, height;
    target.GetDimensions(width, height);
    if (id.x >= width || id.y >= height) return;
    target[id] = source[id];
}
