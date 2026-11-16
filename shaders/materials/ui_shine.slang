//! mirai ui Ui_Shine
//! parameter speed {"default":0.5,"min":0,"max":20}
//! parameter width {"default":0.2,"min":0,"max":1}
//! parameter strength {"default":0.6,"min":0,"max":1}
namespace Ui_Shine {
struct Parameters {float speed;float width;float strength;};
// A slanted band that lightens the color of the node toward white as it
// crosses it, speed times a second; width is a fraction of the node.
float4 evaluate(Mirai_Ui_Context ctx, Parameters p) {
    if (p.width<=0.0 || p.strength<=0.0) return ctx.color;
    float2 x=ctx.uv*ctx.size;
    float across=(x.x+x.y*0.5)/max(ctx.size.x+ctx.size.y*0.5,1e-4);
    float half_width=p.width*0.5;
    float center=frac(ctx.time*p.speed)*(1.0+p.width)-half_width;
    float band=1.0-smoothstep(0.0,half_width,abs(across-center));
    return float4(lerp(ctx.color.rgb,float3(1.0),band*saturate(p.strength)),ctx.color.a);
}
}
