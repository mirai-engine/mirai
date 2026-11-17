#include "native.slang"
#define MIRAI_GROUP_X 64
#define MIRAI_GROUP_Y 1
#define MIRAI_GROUP_Z 1

// Work that lasts as long as its rounds ask, for the tests of the GPU watchdog.
struct Params { uint count; uint rounds; uint pad0; uint pad1; };
[[vk::binding(0, 0)]] ConstantBuffer<Params> params : register(b0, space0);
[[vk::binding(1, 0)]] RWStructuredBuffer<uint> output_data : register(u1, space0);

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 dispatch_id : SV_DispatchThreadID) {
    uint i = dispatch_id.x;
    if (i >= params.count) return;
    uint x = i * 2654435761u + 1u;
    for (uint r = 0; r < params.rounds; r++) {
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
    }
    output_data[i] = x;
}
