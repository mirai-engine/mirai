#include "native.slang"
//! variant hw MIRAI_HW_RT=1
// color: colored shadows, whose rays take the filters of the glass they cross (trace.slang).
//! constant color MIRAI_COLORED_SHADOWS
// The direct light of the pixels that trace rays of their own. A pixel of
// thin geometry or an edge, whose surface no block of shadows holds, traces
// one to the sun, to each node of its cut and to each light of extensions,
// and one that lets light through traces those of its other side; those
// pixels come from the list of lighting.comp and add to what it wrote.
// Without blocks (a view without soft shadows) every pixel traces its own light.
//
// The filters of glass with a program wait for it (points.slang): the light
// takes their means, and the resume (params.resume) adds what the exact ones
// change of it.
#define POINTS_SLOT SLOT_POINTS
#define MIRAI_DEFER_FILTERS
#define GBUFFER_ALBEDO SLOT_PASS3
#define GBUFFER_NORMAL SLOT_PASS0
#include "lighting.slang"
#include "gbuffer.slang"
#include <extension_hooks.slang>
#include "pixel.slang"
#define MIRAI_GROUP_X 64
#define MIRAI_GROUP_Y 1
#define MIRAI_GROUP_Z 1

// listed: the pixels of the list of lighting.comp; else every pixel.
struct Params_Block { uint light_budget; uint listed; uint pad0; uint pad1; uint resume; uint pad2; uint pad3; uint pad4; };
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);
[[vk::binding(SLOT_PASS1, 0)]] Texture2D<float4> g_depth : register(MIRAI_REGISTER(t, SLOT_PASS1), space0);
[[vk::binding(SLOT_PASS2, 0)]] [[vk::image_format("rgba16f")]] RWTexture2D<float4> out_direct : register(MIRAI_REGISTER(u, SLOT_PASS2), space0);
// The list of lighting.comp (DIRECT_TRACED_* in lighting.slang).
[[vk::binding(SLOT_PASS4, 0)]] StructuredBuffer<uint> traced : register(MIRAI_REGISTER(t, SLOT_PASS4), space0);

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 dispatch_id : SV_DispatchThreadID, uint3 group : SV_GroupID, uint local : SV_GroupIndex) {
    if (MIRAI_COLORED_SHADOWS && params.resume != 0u) {
        Point_Head head;
        if (!head_of_round(group.x * (MIRAI_GROUP_X * MIRAI_GROUP_Y) + local, head)) return;
        int2 at = int2(head.owner & 0xffffu, head.owner >> 16u);
        out_direct[at] = float4(finite_or_zero(out_direct[at].rgb + filters_correction(head.chain)), 1.0);
        return;
    }
    uint index = dispatch_id.x;
    int2 p;
    bool front = true, back = true;
    if (params.listed != 0u) {
        if (index >= traced[0]) return;
        uint entry = traced[DIRECT_TRACED_FIRST + index];
        p = int2(entry & DIRECT_TRACED_X_MASK, (entry >> DIRECT_TRACED_Y_SHIFT) & DIRECT_TRACED_X_MASK);
        front = (entry & DIRECT_TRACED_FRONT) != 0u;
        back = (entry & DIRECT_TRACED_BACK) != 0u;
    } else {
        uint width = uint(frame.resolution.x);
        p = int2(index % width, index / width);
        if (p.y >= int(frame.resolution.y)) return;
    }
    float depth = g_depth.Load(int3(p, 0)).r;
    if (depth_empty(depth)) { out_direct[p] = float4(0.0); return; }
    float2 uv = (float2(p) + 0.5) * frame.inv_resolution;
    Pixel pixel = pixel_at(p, uv, depth);
    Shading s = gbuffer_shading(gbuffer_read(p), pixel);
    float bias = view_bias(pixel.distance);
    float3 direct = params.listed != 0u ? out_direct[p].rgb : float3(0.0);
    back = back && shading_transmits(s);
    Shading behind = shading_back(s);
    // One call traces both sides: the traversal of its rays is a copy in the source for each call.
    for (uint side = front ? 0u : 1u; side < (back ? 2u : 1u); side++) {
        direct += direct_lighting(side == 0u ? s : behind, bias, params.light_budget, LIGHTS_ALL, float2(-1.0, 0.0));
    }
    out_direct[p] = float4(direct, 1.0);
    if (MIRAI_COLORED_SHADOWS && filter_chain != INVALID) head_append(point_head(INVALID, filter_chain, uint(p.x) | (uint(p.y) << 16u)));
}
