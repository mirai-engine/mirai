#include "native.slang"
// The tags of the pixels of the viewmodel of a view, after its visibility and
// before its resolve (render/foreground.odin): VIEWS_FOREGROUND where it
// drew, with the share of the way from the eye to its true place its light
// is taken at, in front of the world the view drew under it by
// FOREGROUND_CLEARANCE: a wall nearer than the weapon keeps its light in
// front of the wall. 0 elsewhere.
#include "common.slang"

// along, by: the linear depth of the point p = (ndc x, ndc y, d, 1) of the
// depth of a pixel of the viewmodel is dot(along, p) / dot(by, p); size: of
// the targets, pixels.
struct Params_Block { float4 along; float4 by; float2 size; float2 pad; };
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);
[[vk::binding(SLOT_PASS0, 0)]] Texture2D<float4> depth : register(MIRAI_REGISTER(t, SLOT_PASS0), space0);        // the depth target
[[vk::binding(SLOT_PASS1, 0)]] Texture2D<float4> world_depth : register(MIRAI_REGISTER(t, SLOT_PASS1), space0);  // the linear depth of the world

[shader("fragment")]
uint main(float4 pixel : SV_Position) : SV_Target0 {
    int2 p = int2(pixel.xy);
    float d = depth.Load(int3(p, 0)).r;
    if (d <= FOREGROUND_DEPTH) return 0u;
    float2 ndc = pixel.xy / params.size * float2(2.0, -2.0) + float2(-1.0, 1.0);
    float4 point = float4(ndc, d, 1.0);
    float own = dot(params.along, point) / dot(params.by, point);
    float world = world_depth.Load(int3(p, 0)).r;
    float kept = world > 0.0 && own > 0.0 ? saturate((world - FOREGROUND_CLEARANCE) / own) : 1.0;
    return VIEWS_FOREGROUND | uint(round(kept * float(VIEWS_KEPT)));
}
