//! mirai ui Ui_Radial_Wipe
//! parameter fill {"default":1,"min":0,"max":1}
//! parameter start {"default":0,"min":-1,"max":1}
namespace Ui_Radial_Wipe {
struct Parameters {float fill;float start;};
// The color of the node over the sector that turns clockwise from start, in
// turns from the top, through fill of a whole turn: the shade of a cooldown.
float4 evaluate(Mirai_Ui_Context ctx, Parameters p) {
    float2 q=(ctx.uv-0.5)*ctx.size;
    float turns=frac(atan2(q.x,-q.y)*0.15915494-p.start);
    float fill=saturate(p.fill);
    // How far into the sector, in turns: negative outside it.
    float inside=turns<=fill?min(turns,fill-turns):-min(turns-fill,1.0-turns);
    float pixel=max(max(fwidth(q.x),fwidth(q.y)),1e-4);
    float coverage=fill>=1.0?1.0:fill<=0.0?0.0:saturate(inside*6.2831853*length(q)/pixel+0.5);
    return float4(ctx.color.rgb,ctx.color.a*coverage);
}
}
