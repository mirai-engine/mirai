//! mirai surface Grounded
//! parameter fallback {"default":[0.0,0.0,1.0],"min":0,"max":1,"color":true}
// What stands on the ground glows with the color of the ground under it, or
// with fallback where the ground keeps none: what the read of that color is
// checked with.
namespace Grounded {
struct Parameters {float3 fallback;float pad;};
Mirai_Surface evaluate(Mirai_Surface_Context ctx, Parameters p) {
    Mirai_Surface s=mirai_surface_default(ctx);
    s.unlit=true;
    s.emission=mirai_ground_color(ctx,ctx.world_position,float4(p.fallback,0.0)).rgb;
    return s;
}
}
