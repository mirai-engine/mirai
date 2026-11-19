// The impostors a view draws, in two phases as the scene culls
// (cull.comp): those whose mesh is not whole and that are not gone, with
// their sphere in the frustum and not behind what the scene drew.
//  phase 0: the pyramid of the frame before, which held the impostors it
//           drew, hides some: they wait for phase 1; the others are drawn
//           first (the first draw of impostor_draw);
//  phase 1: the pyramid built again with those tests what waited, and the
//           second draw takes those it shows, after the first ones.
// Each draw: vertices, instances, first vertex, first instance; the record
// zeroes their instances, and the count of those that wait.
#include "foliage_impostor.slang"
#include "pyramid.slang"
#define MIRAI_GROUP_X 64
#define MIRAI_GROUP_Y 1
#define MIRAI_GROUP_Z 1

[[vk::binding(SLOT_PASS1, 0)]] RWStructuredBuffer<uint> impostor_visible : register(MIRAI_REGISTER(u, SLOT_PASS1), space0);
[[vk::binding(SLOT_PASS2, 0)]] RWStructuredBuffer<uint> impostor_draw : register(MIRAI_REGISTER(u, SLOT_PASS2), space0);
[[vk::binding(SLOT_PASS5, 0)]] Texture2D<float4> pyramid : register(MIRAI_REGISTER(t, SLOT_PASS5), space0);
[[vk::binding(SLOT_PASS6, 0)]] Texture2D<float4> pyramid_before : register(MIRAI_REGISTER(t, SLOT_PASS6), space0);
// The groups of the dispatch of phase 1 (x, y, z), how many wait, then each.
[[vk::binding(SLOT_PASS7, 0)]] RWStructuredBuffer<uint> impostor_waiting : register(MIRAI_REGISTER(u, SLOT_PASS7), space0);

#define IMPOSTOR_WAITING_FIRST 4u

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 dispatch_id : SV_DispatchThreadID) {
    uint phase = impostor_params.count.y;
    uint levels = impostor_params.count.z;
    uint i = dispatch_id.x;
    if (phase == 1u) {
        // The second draw follows the first.
        if (i == 0u) impostor_draw[7] = impostor_draw[1];
        if (i >= impostor_waiting[3]) return;
        i = impostor_waiting[IMPOSTOR_WAITING_FIRST + i];
    } else if (i >= impostor_params.count.x) {
        return;
    }
    Impostor_Instance inst = impostor_instances[i];
    if (inst.row == IMPOSTOR_NONE) return;
    Impostor_Shape s;
    float2 lean;
    if (!impostor_shape(inst, impostor_rows[impostor_row_index(inst.row)], s, lean)) return;
    float3 low = s.center - s.radius;
    float3 high = s.center + s.radius;
    if (phase == 0u) {
        for (int k = 0; k < 6; k++) {
            float4 plane = frame.frustum[k];
            if (dot(plane.xyz, lerp(low, high, step(float3(0.0), plane.xyz))) + plane.w < 0.0) return;
        }
    }
    if ((impostor_params.count.w & 1u) != 0u && pyramid_hides(pyramid, levels, low, high, frame.view_proj_unjittered, frame.camera_position.xyz, frame.depth_plane)) return;
    uint at;
    if (phase == 0u && (impostor_params.count.w & 2u) != 0u && pyramid_hides(pyramid_before, levels, low, high, frame.prev_view_proj, frame.prev_eye.xyz, frame.prev_depth_plane)) {
        InterlockedAdd(impostor_waiting[3], 1u, at);
        impostor_waiting[IMPOSTOR_WAITING_FIRST + at] = i;
        InterlockedMax(impostor_waiting[0], at / MIRAI_GROUP_X + 1u);
        return;
    }
    if (phase == 1u) {
        InterlockedAdd(impostor_draw[5], 1u, at);
        impostor_visible[impostor_draw[1] + at] = i;
        return;
    }
    InterlockedAdd(impostor_draw[1], 1u, at);
    impostor_visible[at] = i;
}
