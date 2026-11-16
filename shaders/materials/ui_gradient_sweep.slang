//! mirai ui Ui_Gradient_Sweep
//! parameter color {"default":[1,1,1],"min":0,"max":1}
//! parameter speed {"default":0.25,"min":-20,"max":20}
namespace Ui_Gradient_Sweep {
struct Parameters {float3 color;float speed;};
// A gradient from the color of the node to color, display values 0 to 1, and
// back across the node, which scrolls speed times its width a second toward
// the right; still, color is at the middle and the node color at the sides.
float4 evaluate(Mirai_Ui_Context ctx, Parameters p) {
    float t=frac(ctx.uv.x-ctx.time*p.speed);
    float w=smoothstep(0.0,1.0,1.0-abs(t*2.0-1.0));
    return float4(lerp(ctx.color.rgb,saturate(p.color),w),ctx.color.a);
}
}
