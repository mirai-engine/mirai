#include "native.slang"
#define MIRAI_GROUP_X 64
#define MIRAI_GROUP_Y 1
#define MIRAI_GROUP_Z 1

struct Params { uint count; float scale; float offset; uint pad; };
[[vk::binding(0, 0)]] ConstantBuffer<Params> params : register(b0, space0);
[[vk::binding(1, 0)]] StructuredBuffer<float> input_data : register(t1, space0);
[[vk::binding(2, 0)]] RWStructuredBuffer<float> output_data : register(u2, space0);

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 dispatch_id : SV_DispatchThreadID) {
    uint i = dispatch_id.x;
    if (i >= params.count) return;
    output_data[i] = input_data[i] * params.scale + params.offset;
}
