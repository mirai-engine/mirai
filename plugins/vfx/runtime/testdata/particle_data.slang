//! mirai surface Particle_Data
// The material of the sprites of a test of the plugin: unlit, glowing with
// the second data its particle gives where it is 1 as its random value and
// half a metre as its radius (black elsewhere), green where it gives none.
namespace Particle_Data {
struct Parameters { float unused; };
Mirai_Surface evaluate(Mirai_Surface_Context ctx, Parameters p) {
    Mirai_Surface s = mirai_surface_default(ctx);
    s.unlit = true;
    s.base_color = float3(0.0);
    bool kept = ctx.particle_random > 0.99 && abs(ctx.particle_radius - 0.5) < 0.01;
    s.emission = (ctx.particle_given & 2u) != 0u ? (kept ? ctx.particle_data[1].rgb : float3(0.0)) : float3(0.0, 1.0, 0.0);
    return s;
}
}
