#include "native.slang"
#include <shared_constants.slang>
// What micro_gpu_test reads of the batch of a look in a view: the count its
// Instances stage wrote, then the words of its first instances.
#define MIRAI_GROUP_X 64
#define MIRAI_GROUP_Y 1
#define MIRAI_GROUP_Z 1

struct Read {
    uint4 target; // the first word of the batch, the word of its count, words to copy
};

[[vk::binding(SLOT_PASS0, 0)]] RWStructuredBuffer<uint> copied : register(MIRAI_REGISTER(u, SLOT_PASS0), space0);
[[vk::binding(SLOT_PASS3, 0)]] StructuredBuffer<uint> pool : register(MIRAI_REGISTER(t, SLOT_PASS3), space0);
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Read> read : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 dispatch_id : SV_DispatchThreadID) {
    uint i = dispatch_id.x;
    if (i >= read.target.z) return;
    copied[i] = i == 0u ? pool[read.target.y] : pool[read.target.x + i - 1u];
}
