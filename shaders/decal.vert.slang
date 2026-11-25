#include "native.slang"
// The vertices of the decals (decal.frag): of a draw of an entry of the
// decals of the scene (decal_draws.comp), the clusters of its slot in the cut
// of the view, the others collapsed. The surfaces under a decal were drawn at
// their own detail and their own triangles: its clip depth comes nearer the
// eye by DECAL_SLACK pixels of footprint, more as it turns away from the eye,
// and the place its fragment evaluates stays where it is.
#define MIRAI_RASTER_STILL
#include "gbuffer_vertex.slang"
#include "gbuffer_build.slang"

// Of each entry, its instance and the slot of its mesh (render.Scene_State.decals).
[[vk::binding(SLOT_PASS0, 0)]] StructuredBuffer<uint2> entries : register(MIRAI_REGISTER(t, SLOT_PASS0), space0);

#define DECAL_SLACK 2.0
// The facing below which the slack grows no more.
#define DECAL_GRAZING 0.125

[shader("vertex")]
Gbuffer_Vertex main(uint vertex_id : SV_VulkanVertexID, uint instance_id : SV_VulkanInstanceID) {
    Gbuffer_Vertex output = (Gbuffer_Vertex)0;
    uint2 entry = entries[instance_id];
    Instance inst = scene_instance(entry.x);
    Mesh mesh = meshes[instance_mesh(inst)];
    Cluster c = mesh_cluster(mesh, vertex_id >> DRAW_VERTEX_BITS);
    if (cluster_slot(c) != entry.y || !cluster_in_cut(view_detail(), inst, instance_scale(inst), mesh, c, frame.cut.x)) {
        // Outside the volume of the view: the triangle has no area to raster.
        output.position = float4(2.0, 2.0, 2.0, 1.0);
        return output;
    }
    output = gbuffer_vertex_build(entry.x, inst, mesh, c, vertex_id & ((1u << DRAW_VERTEX_BITS) - 1u), true);
    if (instance_mirrored(inst)) output.out_flags |= RASTER_FLAG_TURNED;
    float3 eye = frame.camera_position.xyz;
    float3 offset = output.out_world - eye;
    float distance = length(offset);
    float depth = dot(offset, frame.camera_forward.xyz);
    float facing = abs(dot(normalize(output.out_normal), offset / max(distance, 1e-20)));
    float slack = DECAL_SLACK * (frame.footprint.x + frame.footprint.y * max(depth, 0.0)) / max(facing, DECAL_GRAZING);
    output.position = view_clip(eye + offset * max(1.0 - slack / max(distance, 1e-20), 0.5));
    return output;
}
