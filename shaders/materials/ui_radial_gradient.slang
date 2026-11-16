//! mirai ui Ui_Radial_Gradient
//! parameter color {"default":[0,0,0],"min":0,"max":1}
//! parameter reach {"default":1,"min":0.01,"max":4}
namespace Ui_Radial_Gradient {
struct Parameters {float3 color;float reach;};
// From the color of the node at its center to color, display values 0 to 1,
// reach times the way from the center to its edges out: the glow of a card.
float4 evaluate(Mirai_Ui_Context ctx, Parameters p) {
    float t=saturate(length(ctx.uv*2.0-1.0)/max(p.reach,1e-3));
    return float4(lerp(ctx.color.rgb,saturate(p.color),t),ctx.color.a);
}
}
