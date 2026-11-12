//! mirai ui Ui_Rays
//! parameter count {"default":12,"min":1,"max":64}
//! parameter turn {"default":0,"min":-1,"max":1}
//! parameter speed {"default":0.02,"min":-10,"max":10}
//! parameter fade {"default":1,"min":0,"max":1}
namespace Ui_Rays {
struct Parameters {float count;float turn;float speed;float fade;};
// count rays of the color of the node out of its center, as wide as the gaps
// between them, the first turned turn of a whole turn clockwise from the top
// and all turning speed turns a second; fade: how much they fade toward its
// edges. The burst of rays behind a reward.
float4 evaluate(Mirai_Ui_Context ctx, Parameters p) {
    float2 q=(ctx.uv-0.5)*ctx.size;
    float count=max(round(p.count),1.0);
    float turns=atan2(q.x,-q.y)*0.15915494-p.turn-ctx.time*p.speed;
    // How far inside a ray, in periods: negative in a gap.
    float s=frac(turns*count);
    float inside=s<=0.5?min(s,0.5-s):-min(s-0.5,1.0-s);
    float pixel=max(max(fwidth(q.x),fwidth(q.y)),1e-4);
    float coverage=saturate(inside*6.2831853*length(q)/count/pixel+0.5);
    float edge=saturate(length(ctx.uv*2.0-1.0));
    return float4(ctx.color.rgb,ctx.color.a*coverage*(1.0-saturate(p.fade)*edge));
}
}
