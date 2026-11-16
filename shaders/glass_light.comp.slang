#include "native.slang"
//! variant hw MIRAI_HW_RT=1
// color: with colored shadows, the rays cross glass as the mean of its instance (trace.slang).
//! constant color MIRAI_GLASS_MEANS
// The light of each pixel of a layer of glass itself, with its traced
// reflection, before glass.comp adds over it what the layer lets through. Its
// lights take their shadows from the maps of the view where these hold the
// point (MIRAI_LIGHT_MAPS of lighting.slang), and trace them where they do not.
#define GLASS_LIGHT
#define MIRAI_LIGHT_MAPS
#define SUN_SHADOW_SLOT SLOT_PASS5
#define SHADOW_DATA_SLOT SLOT_PASS8
#include "glass_pass.slang"
#define MIRAI_GROUP_X 8
#define MIRAI_GROUP_Y 8
#define MIRAI_GROUP_Z 1

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 dispatch_id : SV_DispatchThreadID) {
    int2 p = int2(dispatch_id.xy);
    if (any(p >= int2(frame.resolution))) return;
    float depth = layer_depth.Load(int3(p, 0)).r;
    if (depth <= 0.0) return;
    float4 normal = layer_normal.Load(int3(p, 0));
    // The back faces of the solid the camera is in are left to glass_inside.comp.
    if ((gbuffer_bits_unpack(normal) & GBUFFER_GLASS_EXIT) != 0u) return;
    float2 uv = (float2(p) + 0.5) * frame.inv_resolution;
    uint2 ids = layer_ids.Load(int3(p, 0));
    Material m = material_row(ids.x, material_values_of(ids.y));
    Glass g = glass_of(p, uv, depth, layer_albedo.Load(int3(p, 0)), normal, layer_emission.Load(int3(p, 0)));
    float traced = params.traced != 0u ? reflection_weight(g.roughness) : 0.0;
    float3 reflected = traced > 0.0 ? reflection.Load(int3(p, 0)).rgb : float3(0.0);
    out_color[p] = float4(finite_or_zero(glass_light(m, g, glass_shading(m, g), reflected, traced, 0.0, params.light_budget)), 1.0);
}
