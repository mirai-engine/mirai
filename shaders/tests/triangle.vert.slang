#include "native.slang"
struct Vertex { float4 position; float4 color; };
[[vk::binding(0, 0)]] StructuredBuffer<Vertex> vertices : register(t0, space0);

struct Stage_Output {
    float4 position : SV_Position;
    [[vk::location(0)]] float4 out_color : TEXCOORD0;
};
[shader("vertex")]
Stage_Output main(uint vertex_id : SV_VulkanVertexID) {
    Stage_Output output;
    Vertex v = vertices[vertex_id];
    output.out_color = v.color;
    output.position = v.position;
    return output;
}
