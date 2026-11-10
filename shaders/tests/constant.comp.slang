#include "native.slang"
// double: the stage writes two instead of one.
//! constant double MIRAI_TEST_DOUBLE
[[vk::binding(0, 0)]] RWStructuredBuffer<float> output_data : register(u0, space0);

[shader("compute")]
[numthreads(64, 1, 1)]
void main(uint3 dispatch_id : SV_DispatchThreadID) {
    if (MIRAI_TEST_DOUBLE) output_data[dispatch_id.x] = 2.0;
    else output_data[dispatch_id.x] = 1.0;
}
