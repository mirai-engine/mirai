#include "native.slang"
// Startup self-test of the hardware ray tracing path: traces a fixed set of
// rays against a known two-instance scene. The renderer compares the results
// with the expected hits and falls back to the software BVH on any mismatch.
#define MIRAI_HW_RT 1
#define MIRAI_GROUP_X 8
#define MIRAI_GROUP_Y 1
#define MIRAI_GROUP_Z 1
[[vk::binding(29, 0)]] RaytracingAccelerationStructure scene_tlas : register(t29, space0);
[[vk::binding(19, 0)]] StructuredBuffer<float4> rays : register(t19, space0);   // origin.xyz + tmax, direction.xyz
[[vk::binding(20, 0)]] RWStructuredBuffer<float4> hits : register(u20, space0); // t, instance, primitive, valid

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 dispatch_id : SV_DispatchThreadID) {
    uint i = dispatch_id.x;
    if (i >= 8u) return;
    float4 a = rays[i * 2u];
    float4 b = rays[i * 2u + 1u];
    RayQuery<RAY_FLAG_NONE> query;
    RayDesc ray_desc; ray_desc.Origin = a.xyz; ray_desc.TMin = 0.0; ray_desc.Direction = b.xyz; ray_desc.TMax = a.w; query.TraceRayInline(scene_tlas, RAY_FLAG_FORCE_OPAQUE, 0xFFu, ray_desc);
    while (query.Proceed()) {}
    float4 result = float4(-1.0, -1.0, -1.0, 1.0);
    if (query.CommittedStatus() == COMMITTED_TRIANGLE_HIT) {
        result.x = query.CommittedRayT();
        result.y = float(query.CommittedInstanceID());
        result.z = float(query.CommittedPrimitiveIndex());
    }
    hits[i] = result;
}
