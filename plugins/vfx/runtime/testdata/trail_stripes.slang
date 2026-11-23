//! mirai surface Trail_Stripes
// The material of the ribbons of a test of the plugin: unlit, white where the
// fraction of its v is below one half, black elsewhere.
namespace Trail_Stripes {
struct Parameters { float unused; };
Mirai_Surface evaluate(Mirai_Surface_Context ctx, Parameters p) {
    Mirai_Surface s = mirai_surface_default(ctx);
    s.unlit = true;
    s.base_color = float3(0.0);
    s.emission = frac(ctx.uv0.y) < 0.5 ? float3(1.0) : float3(0.0);
    return s;
}
}
