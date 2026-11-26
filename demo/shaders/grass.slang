//! mirai surface Grass
//! parameter tip {"default":[0.30,0.52,0.12],"min":0,"max":1,"color":true}
//! parameter roughness {"default":0.75,"min":0,"max":1}
//! parameter root {"default":[0.10,0.20,0.05],"min":0,"max":1,"color":true}
//! parameter ground {"default":0.65,"min":0,"max":1}
// A blade of grass that takes the color of the ground it grows from at its
// root and its own toward its tip: the red of the vertex color is how high
// up the blade a point is (0 at the root, 1 at the tip). ground: how much of
// the color of the ground the root takes; root where there is none.
namespace Grass {
struct Parameters {float3 tip;float roughness;float3 root;float ground;};
Mirai_Surface evaluate(Mirai_Surface_Context ctx, Parameters p) {
    Mirai_Surface s=mirai_surface_default(ctx);
    float up=saturate(ctx.vertex_color.r);
    float3 under=mirai_ground_color(ctx,ctx.world_position,float4(p.root,0.0)).rgb;
    s.base_color=lerp(lerp(p.root,under,p.ground),p.tip,up*up);
    s.roughness=p.roughness;
    return s;
}
}
