#include "native.slang"
// The box of each decal: the pixels it covers are those its fragments look at.
#include "decal.slang"

struct Stage_Output {
    float4 position : SV_Position;
    [[vk::location(0)]] nointerpolation uint out_decal : TEXCOORD0;
    [[vk::location(1)]] float3 out_local : TEXCOORD1;
};
[shader("vertex")]
Stage_Output main(uint vertex_id : SV_VulkanVertexID, uint instance_id : SV_VulkanInstanceID) {
    // The corners of the twelve triangles of a cube: a bit for x, y and z each.
    static const uint CORNERS[36] = {
        0u, 2u, 1u, 1u, 2u, 3u, 4u, 5u, 6u, 5u, 7u, 6u,
        0u, 1u, 4u, 1u, 5u, 4u, 2u, 6u, 3u, 3u, 6u, 7u,
        0u, 4u, 2u, 2u, 4u, 6u, 1u, 3u, 5u, 3u, 7u, 5u,
    };
    uint corner = CORNERS[vertex_id];
    float3 local = float3(float(corner & 1u), float((corner >> 1u) & 1u), float((corner >> 2u) & 1u)) - 0.5;
    Stage_Output output;
    output.out_decal = instance_id;
    output.out_local = local;
    output.position = view_clip(transform_point(decals[instance_id].to_world, local));
    return output;
}
