#include "native.slang"
#include "scene.slang"

[[vk::binding(SLOT_PASS0, 0)]] StructuredBuffer<Thumbnail_Vertex> thumbnail_vertices : register(MIRAI_REGISTER(t, SLOT_PASS0), space0);


struct Stage_Output {
    float4 position : SV_Position;
    [[vk::location(0)]] float3 normal : TEXCOORD0;
    [[vk::location(1)]] float4 color : TEXCOORD1;
    [[vk::location(2)]] nointerpolation float3 emission : TEXCOORD2;
    [[vk::location(3)]] float3 world : TEXCOORD3;
    [[vk::location(4)]] float2 uv0 : TEXCOORD4;
    [[vk::location(5)]] float2 uv1 : TEXCOORD5;
    [[vk::location(6)]] nointerpolation uint material : TEXCOORD6;
    [[vk::location(7)]] float4 tangent : TEXCOORD7;
};
[shader("vertex")]
// program: the Surface program whose triangles the draw draws, as its first
// instance (render.rows_programs_draw), 0 those of materials without one; the
// others collapse.
Stage_Output main(uint index : SV_VulkanVertexID, uint program : SV_VulkanInstanceID) {
    Thumbnail_Vertex value = thumbnail_vertices[index];
    Stage_Output output;
    output.position = materials[value.vertex.material].shared.program_id == program ? view_clip(value.vertex.position) : float4(2.0, 2.0, 2.0, 1.0);
    output.normal = unpack_normal(value.vertex.normal);
    output.color = unpack_rgba8(value.vertex.color);
    output.emission = value.emission;
    output.world = value.vertex.position;
    output.uv0 = value.vertex.uv;
    output.uv1 = value.vertex.uv1;
    output.material = value.vertex.material;
    output.tangent = unpack_tangent(value.vertex.tangent);
    return output;
}
