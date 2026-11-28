//! mirai surface Flip_Probe
// The material of the particles of a test of the plugin: unlit and opaque,
// red where uv0 lies across its tile of a flipbook of two columns, green the
// share between this frame and the next, blue 1.
namespace Flip_Probe {
struct Parameters { float unused; };
Mirai_Surface evaluate(Mirai_Surface_Context ctx, Parameters p) {
    Mirai_Surface s = mirai_surface_default(ctx);
    s.unlit = true;
    s.base_color = float3(0.0);
    s.alpha = 1.0;
    s.emission = float3(frac(ctx.uv0.x * 2.0), ctx.particle_frame, 1.0);
    return s;
}
}
