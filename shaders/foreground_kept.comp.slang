#include "native.slang"
// The share of the way from the eye to its true place that the light of the
// viewmodel of a view is taken at, one for all its pixels (render/foreground.odin):
// the least any of them keeps to stay FOREGROUND_CLEARANCE in front of the
// world the view drew under it, in VIEWS_KEPT steps. One share keeps the
// weapon lit as one piece where only some of its pixels are over a wall.
#include "common.slang"
#define MIRAI_GROUP_X 8
#define MIRAI_GROUP_Y 8
#define MIRAI_GROUP_Z 1

// along, by: the linear depth of the point p = (ndc x, ndc y, d, 1) of the
// depth of a pixel of the viewmodel is dot(along, p) / dot(by, p); size: of
// the targets, pixels.
struct Params_Block { float4 along; float4 by; float2 size; float2 pad; };
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);
[[vk::binding(SLOT_PASS0, 0)]] Texture2D<float4> depth : register(MIRAI_REGISTER(t, SLOT_PASS0), space0);        // the depth target
[[vk::binding(SLOT_PASS1, 0)]] Texture2D<float4> world_depth : register(MIRAI_REGISTER(t, SLOT_PASS1), space0);  // the linear depth of the world
[[vk::binding(SLOT_PASS2, 0)]] RWStructuredBuffer<uint> kept : register(MIRAI_REGISTER(u, SLOT_PASS2), space0);   // the least, from above VIEWS_KEPT

groupshared uint group_kept;

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 id : SV_DispatchThreadID, uint index : SV_GroupIndex) {
    if (index == 0u) group_kept = VIEWS_KEPT;
    GroupMemoryBarrierWithGroupSync();
    int2 p = int2(id.xy);
    float d = all(float2(p) < params.size) ? depth.Load(int3(p, 0)).r : 0.0;
    if (d > FOREGROUND_DEPTH) {
        float2 ndc = (float2(p) + 0.5) / params.size * float2(2.0, -2.0) + float2(-1.0, 1.0);
        float4 point = float4(ndc, d, 1.0);
        float own = dot(params.along, point) / dot(params.by, point);
        float world = world_depth.Load(int3(p, 0)).r;
        float share = world > 0.0 && own > 0.0 ? saturate((world - FOREGROUND_CLEARANCE) / own) : 1.0;
        InterlockedMin(group_kept, uint(floor(share * float(VIEWS_KEPT))));
    }
    GroupMemoryBarrierWithGroupSync();
    if (index == 0u && group_kept < VIEWS_KEPT) InterlockedMin(kept[0], group_kept);
}
