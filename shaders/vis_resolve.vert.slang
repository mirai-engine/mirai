#include "native.slang"
// What the resolve of a Surface program draws (vis_resolve.frag), at the
// depth its pixels were classified at (vis_classify.frag): the draw of a
// program names it as its first instance. The materials without a program
// cover the view with a triangle; a program, the rectangle of the pixels its
// clusters cover (cull_clusters.comp), with two.
#include "visibility.slang"
#include "cull_bins.slang"

// The resolve draws of the programs (render.Gpu_Program_Draw).
[[vk::binding(SLOT_PASS3, 0)]] StructuredBuffer<uint> program_draws : register(MIRAI_REGISTER(t, SLOT_PASS3), space0);

[shader("vertex")]
float4 main(uint vertex_id : SV_VulkanVertexID, uint instance_id : SV_VulkanInstanceID) : SV_Position {
    float depth = visibility_program_depth(instance_id);
    if (instance_id == 0u) {
        float2 uv = float2((vertex_id << 1) & 2, vertex_id & 2);
        return float4(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, depth, 1.0);
    }
    uint at = instance_id * PROGRAM_DRAW_WORDS + 4u;
    float4 rect = float4(program_draws[at], program_draws[at + 1u], program_draws[at + 2u], program_draws[at + 3u]);
    // Two triangles: corners 0 1 2 and 2 1 3 of the rectangle, two bits each.
    uint corner = (0xda4u >> (vertex_id * 2u)) & 3u;
    float2 pixel = float2((corner & 1u) != 0u ? rect.z : rect.x, (corner & 2u) != 0u ? rect.w : rect.y);
    float2 ndc = pixel * frame.inv_resolution * 2.0 - 1.0;
    return float4(ndc.x, -ndc.y, depth, 1.0);
}
