//! mirai surface Pulse
//! parameter glow {"default":[0,0,0],"min":0,"max":100,"color":true}
//! parameter rate {"default":1,"min":0,"max":100}
//! parameter start {"default":0,"min":0,"max":100000}
//! parameter sway {"default":0,"min":0,"max":1}
// A surface that follows the time: its glow, off before `start` seconds and
// then waving between none and `glow` at `rate` radians a second, and its
// color, darkened by up to `sway` in waves that cross the world at that rate.
// What the probes are checked with when a program that reads the time
// changes their light, or does not.
namespace Pulse {
struct Parameters {float3 glow;float rate;float start;float sway;};
Mirai_Surface evaluate(Mirai_Surface_Context ctx, Parameters p) {
    Mirai_Surface s=mirai_surface_default(ctx);
    float on=ctx.time>=p.start ? 1.0 : 0.0;
    s.emission=p.glow*on*(0.5+0.5*sin(ctx.time*p.rate));
    float wave=0.5+0.5*sin(ctx.time*p.rate+dot(ctx.world_position,float3(1.7,0.0,2.3)));
    s.base_color*=1.0-p.sway*wave;
    return s;
}
}
