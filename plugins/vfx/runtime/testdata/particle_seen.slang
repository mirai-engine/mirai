//! mirai surface Particle_Seen
// The material of the particles of a test of the plugin: unlit, red by the
// share of its life its particle lived and blue by what is left of it, both
// by the color of its mesh, and the green of the color of its particle where
// its point faces the eye of the view.
namespace Particle_Seen {
struct Parameters { float unused; };
Mirai_Surface evaluate(Mirai_Surface_Context ctx, Parameters p) {
    Mirai_Surface s = mirai_surface_default(ctx);
    s.unlit = true;
    s.base_color = float3(0.0);
    s.emission = float3(ctx.particle_life, 0.0, 1.0 - ctx.particle_life) * ctx.vertex_color.rgb;
    if (dot(ctx.normal, ctx.view_direction) > 0.99) s.emission.g = ctx.particle_color.g;
    return s;
}
}
