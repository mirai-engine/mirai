// The impostors a view draws: those whose mesh is not whole and that are not
// gone, with their sphere in the frustum, appended to the visible list and
// counted in the instances of its draw (vertices, instances, first vertex,
// first instance), which the record zeroes before.
#include "foliage_impostor.slang"
#define MIRAI_GROUP_X 64
#define MIRAI_GROUP_Y 1
#define MIRAI_GROUP_Z 1

[[vk::binding(SLOT_PASS1, 0)]] RWStructuredBuffer<uint> impostor_visible : register(MIRAI_REGISTER(u, SLOT_PASS1), space0);
[[vk::binding(SLOT_PASS2, 0)]] RWStructuredBuffer<uint> impostor_draw : register(MIRAI_REGISTER(u, SLOT_PASS2), space0);

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 dispatch_id : SV_DispatchThreadID) {
    uint i = dispatch_id.x;
    if (i >= impostor_params.count.x) return;
    Impostor_Instance inst = impostor_instances[i];
    if (inst.row == IMPOSTOR_NONE) return;
    Impostor_Shape s;
    if (!impostor_shape(inst, impostor_rows[impostor_row_index(inst.row)], s)) return;
    float3 low = s.center - s.radius;
    float3 high = s.center + s.radius;
    for (int k = 0; k < 6; k++) {
        float4 plane = frame.frustum[k];
        if (dot(plane.xyz, lerp(low, high, step(float3(0.0), plane.xyz))) + plane.w < 0.0) return;
    }
    uint at;
    InterlockedAdd(impostor_draw[1], 1u, at);
    impostor_visible[at] = i;
}
