//! mirai ui Ui_Dissolve
//! parameter amount {"default":0,"min":0,"max":1}
//! parameter edge {"default":0.08,"min":0,"max":1}
//! parameter cell {"default":8,"min":0.5,"max":1000}
namespace Ui_Dissolve {
struct Parameters {float amount;float edge;float cell;};
float hash(float2 cell) {
    float3 p=frac(float3(cell.xyx)*0.1031);
    p+=dot(p,p.yzx+33.33);
    return frac((p.x+p.y)*p.z);
}
float noise(float2 x) {
    float2 i=floor(x);
    float2 f=x-i;
    float2 u=f*f*(3.0-2.0*f);
    return lerp(lerp(hash(i),hash(i+float2(1,0)),u.x),lerp(hash(i+float2(0,1)),hash(i+float2(1,1)),u.x),u.y);
}
// The node burns away in noise as amount goes from 0, whole, to 1, gone; the
// edge, a fraction of the range of the noise, glows over the burning border.
// cell: the size of the grains in layout units.
float4 evaluate(Mirai_Ui_Context ctx, Parameters p) {
    if (p.amount<=0.0) return ctx.color;
    if (p.amount>=1.0) return float4(ctx.color.rgb,0.0);
    float2 x=ctx.uv*ctx.size/max(p.cell,0.5);
    float n=noise(x)*0.65+noise(x*2.13+17.0)*0.35;
    float edge=max(p.edge,0.0);
    float threshold=p.amount*(1.0+edge);
    float aa=max(fwidth(n),1e-4);
    float alpha=saturate((n-threshold)/aa+0.5);
    float glow=edge>0.0?1.0-saturate((n-threshold)/edge):0.0;
    float3 color=lerp(ctx.color.rgb,float3(1.0,0.85,0.5),glow);
    return float4(color,ctx.color.a*alpha);
}
}
