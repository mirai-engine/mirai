#include "native.slang"
#include "batch_instance.slang"
// The instances a test writes into a batch the GPU fills (batch_fill_gpu_test):
// boxes 2 metres apart along x, each counted and written only while its batch
// has room for it.
#define MIRAI_GROUP_X 64
#define MIRAI_GROUP_Y 1
#define MIRAI_GROUP_Z 1

struct Fill {
    uint4 target;  // its first word, the word of its count, its room, the instances to write
    float4 anchor; // relative to the origin
};

[[vk::binding(SLOT_PASS0, 0)]] RWStructuredBuffer<uint> pool : register(MIRAI_REGISTER(u, SLOT_PASS0), space0);
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Fill> fill : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 dispatch_id : SV_DispatchThreadID) {
    uint i = dispatch_id.x;
    if (i >= fill.target.w) return;
    uint k;
    InterlockedAdd(pool[fill.target.y], 1u, k);
    if (k >= fill.target.z) return;
    batch_instance_write(pool, fill.target.x + k * BATCH_WORDS, float3(float(i) * 2.0, 0.5, 0.0) - fill.anchor.xyz, float4(0.0, 0.0, 0.0, 1.0), float3(1.0, 1.0, 1.0));
}
