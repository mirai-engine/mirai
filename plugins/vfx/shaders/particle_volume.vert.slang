#include "native.slang"
// One triangle over the view at the near plane: the depth test of the Blend
// stage lets every pixel through, and the march stops at the scene behind.

struct Stage_Output {
    float4 position : SV_Position;
};

[shader("vertex")]
Stage_Output main(uint vertex_id : SV_VulkanVertexID) {
    Stage_Output output;
    float2 uv = float2((vertex_id << 1) & 2, vertex_id & 2);
    output.position = float4(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, 1.0, 1.0);
    return output;
}
