#include "native.slang"
// The vertices of the forward blends (translucent.frag): the blended clusters
// of a draw of an instance, without computing previous-frame transforms or
// motion vectors.
#define MIRAI_RASTER_STILL
#include "gbuffer_draw.slang"
[shader("vertex")]
Gbuffer_Vertex main(uint vertex_id : SV_VulkanVertexID, uint instance_id : SV_VulkanInstanceID) {
    return gbuffer_draw_vertex(vertex_id, instance_id, false, true);
}
