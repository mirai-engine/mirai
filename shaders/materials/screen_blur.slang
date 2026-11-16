//! mirai postprocess Blur
//! parameter radius {"default":4,"min":0,"max":64}
//! parameter strength {"default":1,"min":0,"max":1}
namespace Blur {
struct Parameters {float radius;float strength;};
// radius in pixels of the image: two rings of eight reads around the pixel,
// the nearer weighing more.
float4 evaluate(Mirai_PostProcess_Context ctx, Parameters p) {
    if (p.radius<=0.0 || p.strength<=0.0) return ctx.color;
    float2 step=p.radius/ctx.resolution;
    float4 sum=ctx.color;
    float total=1.0;
    for (int ring=1;ring<=2;ring++) {
        float weight=ring==1?0.75:0.4;
        for (int k=0;k<8;k++) {
            float angle=(float(k)+0.5*float(ring-1))*0.785398;
            sum+=mirai_scene_color(ctx,ctx.uv+float2(cos(angle),sin(angle))*step*(0.5*float(ring)))*weight;
            total+=weight;
        }
    }
    return lerp(ctx.color,sum/total,saturate(p.strength));
}
}
