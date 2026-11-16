#include "native.slang"
#include "scene.slang"
// Debug lines in world space: 16 byte vertices, two per line, as the world
// has them: the shader takes them relative to the origin.
struct Debug_Vertex { float x, y, z; uint color; };
[[vk::binding(SLOT_PASS0, 0)]] StructuredBuffer<Debug_Vertex> debug_vertices : register(MIRAI_REGISTER(t, SLOT_PASS0), space0);

struct Stage_Output {
    float4 position : SV_Position;
    [[vk::location(0)]] float4 out_color : TEXCOORD0;
    [[vk::location(1)]] float out_depth : TEXCOORD1;
};
[shader("vertex")]
Stage_Output main(uint vertex_id : SV_VulkanVertexID) {
    Stage_Output output;
    Debug_Vertex v = debug_vertices[vertex_id];
    float3 world = float3(v.x, v.y, v.z) - float3(frame.origin.xyz) * ORIGIN_STEP;
    output.out_color = unpack_rgba8(v.color);
    output.position = view_clip_unjittered(world);
    output.out_depth = dot(world - frame.camera_position.xyz, frame.camera_forward.xyz);
    return output;
}
