//! mirai sky Bands
//! parameter above {"default":[1,0,0],"min":0,"max":1,"color":true}
//! parameter below {"default":[0,0,1],"min":0,"max":1,"color":true}
//! parameter sun_glow {"default":0,"min":0,"max":100}
// A sky of two bands, one color above its horizon and another below, with a
// spot of sun_glow white within a few texels of the sun: what the tests of
// the skies Sky programs draw read where the camera, a surface and the sun see.
namespace Bands {
struct Parameters {float3 above;float3 below;float sun_glow;};
float3 evaluate(Mirai_Sky_Context ctx, Parameters p) {
    float3 color=ctx.direction.y>=0.0?p.above:p.below;
    float spot=smoothstep(cos(8.0*ctx.texel),cos(4.0*ctx.texel),dot(ctx.direction,ctx.sun_direction));
    return color+p.sun_glow*ctx.sun*spot;
}
}
