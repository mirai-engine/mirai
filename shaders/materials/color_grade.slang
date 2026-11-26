//! mirai postprocess ColorGrade
//! parameter tint {"default":[1,1,1],"min":0,"max":16}
//! parameter strength {"default":1,"min":0,"max":1}
//! parameter saturation {"default":[1,1,1],"min":0,"max":8}
//! parameter contrast {"default":[1,1,1],"min":0,"max":8}
//! parameter gamma {"default":[1,1,1],"min":0.01,"max":8}
//! parameter shadows_saturation {"default":[1,1,1],"min":0,"max":8}
//! parameter shadows_contrast {"default":[1,1,1],"min":0,"max":8}
//! parameter shadows_gamma {"default":[1,1,1],"min":0.01,"max":8}
//! parameter shadows_end {"default":0.09,"min":0,"max":1}
//! parameter midtones_saturation {"default":[1,1,1],"min":0,"max":8}
//! parameter midtones_contrast {"default":[1,1,1],"min":0,"max":8}
//! parameter midtones_gamma {"default":[1,1,1],"min":0.01,"max":8}
//! parameter highlights_saturation {"default":[1,1,1],"min":0,"max":8}
//! parameter highlights_contrast {"default":[1,1,1],"min":0,"max":8}
//! parameter highlights_gamma {"default":[1,1,1],"min":0.01,"max":8}
//! parameter highlights_start {"default":0.5,"min":0,"max":16}
//! parameter highlights_end {"default":1,"min":0,"max":16}
// The grade of the exposed image: each channel tinted, then pulled toward
// or away from the luminance by its saturation, raised to its contrast
// around middle gray (0.18), so that gray stays where it is, and then to
// 1/gamma (around 1: below 1 it darkens the midtones). The shadows,
// midtones and highlights multiply those of the whole image: the shadows
// fade out by luminance up to shadows_end and the highlights fade in from
// highlights_start to highlights_end; the midtones are the rest.
namespace ColorGrade {
struct Parameters {
    float3 tint;float strength;
    float3 saturation;float3 contrast;float3 gamma;
    float3 shadows_saturation;float3 shadows_contrast;float3 shadows_gamma;float shadows_end;
    float3 midtones_saturation;float3 midtones_contrast;float3 midtones_gamma;
    float3 highlights_saturation;float3 highlights_contrast;float3 highlights_gamma;float highlights_start;float highlights_end;
};
float3 corrected(float3 color,float luma,float3 saturation,float3 contrast,float3 gamma) {
    float3 c=max(lerp(float3(luma),color,saturation),1e-8);
    return pow(pow(c/0.18,contrast)*0.18,1.0/max(gamma,0.01));
}
float4 evaluate(Mirai_PostProcess_Context ctx, Parameters p) {
    float3 color=ctx.color.rgb*p.tint;
    float luma=dot(color,float3(0.2126,0.7152,0.0722));
    float shadows=1.0-smoothstep(0.0,max(p.shadows_end,1e-6),luma);
    float highlights=smoothstep(p.highlights_start,max(p.highlights_end,p.highlights_start+1e-6),luma);
    float3 graded=corrected(color,luma,p.saturation*p.shadows_saturation,p.contrast*p.shadows_contrast,p.gamma*p.shadows_gamma)*shadows
        +corrected(color,luma,p.saturation*p.midtones_saturation,p.contrast*p.midtones_contrast,p.gamma*p.midtones_gamma)*(1.0-shadows-highlights)
        +corrected(color,luma,p.saturation*p.highlights_saturation,p.contrast*p.highlights_contrast,p.gamma*p.highlights_gamma)*highlights;
    return float4(lerp(ctx.color.rgb,graded,saturate(p.strength)),ctx.color.a);
}
}
