//! mirai postprocess ColorGrade
//! parameter tint {"default":[1,1,1],"min":0,"max":16}
//! parameter strength {"default":1,"min":0,"max":1}
//! parameter contrast {"default":1,"min":0,"max":8}
namespace ColorGrade {
struct Parameters {float3 tint;float strength;float contrast;};
float4 evaluate(Mirai_PostProcess_Context ctx, Parameters p) {
    float3 graded=(ctx.color.rgb*p.tint-0.5)*p.contrast+0.5;
    return float4(lerp(ctx.color.rgb,graded,saturate(p.strength)),ctx.color.a);
}
}
