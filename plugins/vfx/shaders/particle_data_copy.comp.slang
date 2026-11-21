#include "native.slang"
#include <shared_constants.slang>
#define MIRAI_GROUP_X 64
#define MIRAI_GROUP_Y 1
#define MIRAI_GROUP_Z 1

struct Copy_Params { uint count; uint stride; };
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Copy_Params> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);
[[vk::binding(SLOT_PASS0, 0)]] ByteAddressBuffer source : register(MIRAI_REGISTER(t, SLOT_PASS0), space0);
[[vk::binding(SLOT_PASS1, 0)]] RWByteAddressBuffer destination : register(MIRAI_REGISTER(u, SLOT_PASS1), space0);

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 id : SV_DispatchThreadID) {
    for (uint i = id.x; i < params.count; i += params.stride) destination.Store4(i * 16u, source.Load4(i * 16u));
}
