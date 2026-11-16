#include "native.slang"

struct Stage_Output {
    float4 position : SV_Position;
    [[vk::location(0)]] float2 out_uv : TEXCOORD0;
};
[shader("vertex")]
Stage_Output main(uint vertex_id : SV_VulkanVertexID) {
    Stage_Output output;
    // One triangle covering the viewport; uv (0,0) is the top-left texel.
    float2 uv = float2((vertex_id << 1) & 2, vertex_id & 2);
    output.out_uv = uv;
    output.position = float4(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, 0.0, 1.0);
    return output;
}
