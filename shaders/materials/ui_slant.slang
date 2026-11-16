//! mirai ui Ui_Slant
//! parameter lean {"default":0.3,"min":-2,"max":2}
namespace Ui_Slant {
struct Parameters {float lean;};
// The color of the node over a parallelogram: its top edge sits lean times
// the height of the node to the right of its bottom one, inside the node.
float4 evaluate(Mirai_Ui_Context ctx, Parameters p) {
    float2 q=ctx.uv*ctx.size;
    float shift=abs(p.lean)*ctx.size.y;
    float rise=p.lean>=0.0?1.0-ctx.uv.y:ctx.uv.y;
    // How far inside its two slanted sides, across them.
    float inside=min(q.x-shift*rise,ctx.size.x-shift*(1.0-rise)-q.x)/sqrt(1.0+p.lean*p.lean);
    float pixel=max(fwidth(q.x),1e-4);
    return float4(ctx.color.rgb,ctx.color.a*saturate(inside/pixel+0.5));
}
}
