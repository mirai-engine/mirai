#include "native.slang"
#define MATERIAL_RASTER
#include "scene.slang"
#include "exposure.slang"
#include "gbuffer.slang"
#include "highlight.slang"
#include <postprocess_programs.slang>
#include "depth.slang"
[[vk::binding(SLOT_PASS0,0)]] Texture2D<float4> post_color : register(MIRAI_REGISTER(t,SLOT_PASS0),space0);
[[vk::binding(SLOT_PASS1,0)]] Texture2D<float4> post_depth : register(MIRAI_REGISTER(t,SLOT_PASS1),space0);
[[vk::binding(SLOT_PASS2,0)]] Texture2D<float4> post_normal : register(MIRAI_REGISTER(t,SLOT_PASS2),space0);
[[vk::binding(SLOT_PASS3,0)]] StructuredBuffer<Exposure_State> exposure : register(MIRAI_REGISTER(t,SLOT_PASS3),space0);
[[vk::binding(SLOT_PASS4,0)]] Texture2D<float4> post_outline : register(MIRAI_REGISTER(t,SLOT_PASS4),space0);
[[vk::binding(SLOT_PARAMS,0)]] ConstantBuffer<Post_Parameters> post_params : register(MIRAI_REGISTER(b,SLOT_PARAMS),space0);
struct Post_Input {[[vk::location(0)]] float2 uv:TEXCOORD0;};
float post_scale() {return post_params.exposed!=0u?exposure[0].exposure:1.0;}
float4 mirai_scene_color(Mirai_PostProcess_Context ctx, float2 uv) {
    float4 color=post_color.SampleLevel(linear_sampler,uv,0);
    color.rgb*=post_scale();
    return color;
}
float mirai_scene_depth(Mirai_PostProcess_Context ctx, float2 uv) {return depth_distance(post_depth.SampleLevel(point_sampler,uv,0).x);}
float3 mirai_scene_normal(Mirai_PostProcess_Context ctx, float2 uv) {return gbuffer_normal_unpack(post_normal.SampleLevel(point_sampler,uv,0));}
Mirai_Outline mirai_outline(Mirai_PostProcess_Context ctx, float2 uv) {
    Mirai_Outline outline=(Mirai_Outline)0;
    if (post_params.outlined==0u) return outline;
    float2 size=float2(texture_size(post_outline,0));
    float2 p=uv*size;
    float2 mask=post_outline.Load(int3(clamp(int2(floor(p)),int2(0),int2(size)-1),0)).xy;
    uint level=uint(mask.x+0.5);
    if (level<=HIGHLIGHT_LEVELS || level>HIGHLIGHT_LEVELS+OUTLINE_STYLES) return outline;
    outline.style=level-HIGHLIGHT_LEVELS;
    outline.depth=mask.y;
    outline.behind=highlight_behind(mask.y,highlight_seen_depth(post_depth,p,size));
    return outline;
}
[shader("fragment")]
float4 main(Post_Input input):SV_Target0 {
    Mirai_PostProcess_Context ctx;
    uint width,height;post_color.GetDimensions(width,height);
    ctx.uv=input.uv;ctx.resolution=float2(width,height);
    ctx.color=post_color.SampleLevel(linear_sampler,input.uv,0);
    ctx.depth=depth_distance(post_depth.SampleLevel(point_sampler,input.uv,0).x);
    ctx.normal=gbuffer_normal_unpack(post_normal.SampleLevel(point_sampler,input.uv,0));
    ctx.time=frame.time.x;
    float scale=post_scale();
    ctx.color.rgb*=scale;
    float4 result=mirai_evaluate_postprocess(post_params.program,post_params.values,ctx);
    if (post_params.fade>0.0) result=lerp(result,ctx.color,post_params.fade);
    return float4(result.rgb/scale,result.a);
}
