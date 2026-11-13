#include "native.slang"
#include "common.slang"
#include "batch_instance.slang"
// The instances of the native TLAS of the batches rays meet, written on the
// GPU from where their instances are in the pool, as rhi.Tlas_Instance: a
// job is a batch (render.Gpu_Tlas_Batch), whose instances follow from its
// first. The RHI makes them native (tlas_instances.comp).
#define MIRAI_GROUP_X 64
#define MIRAI_GROUP_Y 1
#define MIRAI_GROUP_Z 1

struct Tlas_Batch {
    uint words;      // the first word of its instances in the pool
    uint first;      // the first instance of the TLAS it writes
    uint custom;     // the custom index of its first instance
    uint blas;       // rhi.accel_id of the BLAS of its mesh
    uint mask_flags; // as rhi.Tlas_Instance
    uint pad0;
    uint pad1;
    uint pad2;
    float4 anchor;   // xyz: what its instances are relative to, relative to the origin
};
// jobs: the batches; first: the first instance of the TLAS a batch writes; total: the instances after it.
struct Params_Block { uint jobs; uint first; uint total; uint pad; };
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);
[[vk::binding(SLOT_INDICES, 0)]] StructuredBuffer<uint> indices : register(MIRAI_REGISTER(t, SLOT_INDICES), space0);
[[vk::binding(SLOT_PASS0, 0)]] StructuredBuffer<Tlas_Batch> batches : register(MIRAI_REGISTER(t, SLOT_PASS0), space0);
[[vk::binding(SLOT_PASS1, 0)]] RWStructuredBuffer<uint> instances : register(MIRAI_REGISTER(u, SLOT_PASS1), space0);

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 id : SV_DispatchThreadID) {
    uint thread = id.x + id.y * TLAS_DISPATCH_X * MIRAI_GROUP_X;
    if (thread >= params.total) return;
    uint i = params.first + thread;
    // The batch of the instance: the last one that starts at it or before.
    uint low = 0u, high = params.jobs - 1u;
    while (low < high) {
        uint middle = (low + high + 1u) >> 1u;
        if (batches[middle].first <= i) low = middle; else high = middle - 1u;
    }
    Tlas_Batch b = batches[low];
    uint k = i - b.first;
    uint words = b.words + k * BATCH_WORDS;
    float3 p = asfloat(uint3(indices[words], indices[words + 1u], indices[words + 2u])) + b.anchor.xyz;
    float4 world[3];
    float4 inverse[3];
    batch_instance_placement(p, indices[words + 3u], uint2(indices[words + 4u], indices[words + 5u]), world, inverse);
    uint to = i * 16u;
    for (uint row = 0u; row < 3u; row++) {
        instances[to + row * 4u] = asuint(world[row].x);
        instances[to + row * 4u + 1u] = asuint(world[row].y);
        instances[to + row * 4u + 2u] = asuint(world[row].z);
        instances[to + row * 4u + 3u] = asuint(world[row].w);
    }
    instances[to + 12u] = b.custom + k;
    instances[to + 13u] = b.blas;
    instances[to + 14u] = b.mask_flags;
    instances[to + 15u] = 0u;
}
