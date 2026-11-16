#include "native.slang"
#define MIRAI_GROUP_X 8
#define MIRAI_GROUP_Y 8
#define MIRAI_GROUP_Z 1

// A pass that generates a frame in the tests of host: the final image without
// what is drawn over it (SLOT_PASS0), inverted into the generated one (SLOT_PASS1).
[[vk::binding(19, 0)]] Texture2D<float4> source : register(t19, space0);
[[vk::binding(20, 0)]] [[vk::image_format("rgba8")]] RWTexture2D<float4> target : register(u20, space0);

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 dispatch_id : SV_DispatchThreadID) {
    int2 p = int2(dispatch_id.xy);
    int2 size = texture_size(target);
    if (p.x >= size.x || p.y >= size.y) return;
    float4 c = source.Load(int3(p, 0));
    target[p] = float4(1 - c.rgb, 1);
}
