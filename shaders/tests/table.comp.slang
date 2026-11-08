#include "native.slang"
// Samples the texture table with an index that differs per invocation.
#define MIRAI_GROUP_X 8
#define MIRAI_GROUP_Y 1
#define MIRAI_GROUP_Z 1
[[vk::binding(2, 0)]] SamplerState table_sampler : register(s2, space0);
[[vk::binding(3, 0)]] StructuredBuffer<float4> queries : register(t3, space0); // uv, table index, lod
[[vk::binding(4, 0)]] RWStructuredBuffer<float4> results : register(u4, space0);
[[vk::binding(34, 1)]] Texture2D<float4> table[] : register(t34, space1);

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 dispatch_id : SV_DispatchThreadID) {
    uint i = dispatch_id.x;
    if (i >= 8u) return;
    float4 q = queries[i];
    results[i] = table[mirai_nonuniform(uint(q.z))].SampleLevel(table_sampler, q.xy, q.w);
}
