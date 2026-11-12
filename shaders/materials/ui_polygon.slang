//! mirai ui Ui_Polygon
//! parameter sides {"default":6,"min":3,"max":32}
//! parameter turn {"default":0,"min":-1,"max":1}
namespace Ui_Polygon {
struct Parameters {float sides;float turn;};
// The color of the node over a regular polygon of sides corners stretched to
// touch its four edges, turned turn of a whole turn clockwise: at 0 a corner
// points up, at 1/12 a hexagon lies on a side.
float4 evaluate(Mirai_Ui_Context ctx, Parameters p) {
    float n=clamp(round(p.sides),3.0,32.0);
    float step=6.2831853/n;
    float start=p.turn*6.2831853;
    // The box of its corners on a circle of radius 1, which the node is.
    float2 lo=float2(1.0),hi=float2(-1.0);
    for (int i=0;i<32;i++) {
        if (float(i)>=n) break;
        float a=start+step*float(i);
        float2 corner=float2(sin(a),-cos(a));
        lo=min(lo,corner);hi=max(hi,corner);
    }
    float2 at=lerp(lo,hi,ctx.uv);
    // Past its farthest side: negative inside.
    float outside=-2.0;
    for (int i=0;i<32;i++) {
        if (float(i)>=n) break;
        float a=start+step*(float(i)+0.5);
        outside=max(outside,dot(at,float2(sin(a),-cos(a))));
    }
    outside-=cos(step*0.5);
    float coverage=saturate(0.5-outside/max(fwidth(outside),1e-5));
    return float4(ctx.color.rgb,ctx.color.a*coverage);
}
}
