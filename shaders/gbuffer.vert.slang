#include "native.slang"
// highlight: the mask of the editor's highlight, drawn without the jitter of the view.
//! constant highlight MIRAI_EDITOR_HIGHLIGHT
// blended: the passes of the blended triangles (glass) draw those alone, and
// collapse the clusters of the other materials of the mesh.
//! constant blended MIRAI_BLENDED_ONLY
#include "gbuffer_draw.slang"
[shader("vertex")]
Gbuffer_Vertex main(uint vertex_id : SV_VulkanVertexID, uint instance_id : SV_VulkanInstanceID) {
    return gbuffer_draw_vertex(vertex_id, instance_id, MIRAI_EDITOR_HIGHLIGHT, MIRAI_BLENDED_ONLY);
}
