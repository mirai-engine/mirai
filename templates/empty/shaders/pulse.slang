//! mirai surface Pulse
//! parameter color {"default":[0.9,0.35,0.1],"min":0,"max":1,"color":true}
//! parameter glow {"default":2,"min":0,"max":50}
//! parameter speed {"default":1,"min":0,"max":20}
namespace Pulse {
struct Parameters {float3 color;float glow;float speed;};
// A surface of one color whose emission breathes `speed` times per second,
// from none up to `glow` times its color.
Mirai_Surface evaluate(Mirai_Surface_Context ctx, Parameters p) {
    Mirai_Surface s=mirai_surface_default(ctx);
    s.base_color=p.color;
    s.roughness=0.5;
    s.emission=p.color*p.glow*(0.5+0.5*sin(ctx.time*p.speed*6.2831853));
    return s;
}
}
