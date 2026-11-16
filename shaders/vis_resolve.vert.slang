#include "native.slang"
// The triangle over the view the resolve of a Surface program draws
// (vis_resolve.frag), at the depth its pixels were classified at
// (vis_classify.frag): the draw of a program names it as its first instance.
#include "visibility.slang"

[shader("vertex")]
float4 main(uint vertex_id : SV_VulkanVertexID, uint instance_id : SV_VulkanInstanceID) : SV_Position {
    float2 uv = float2((vertex_id << 1) & 2, vertex_id & 2);
    return float4(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, visibility_program_depth(instance_id), 1.0);
}
