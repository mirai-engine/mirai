//! mirai surface Tiled
//! parameter image {"kind":"texture","srgb":true,"normal":false}
//! parameter repeat {"default":3,"min":0.01,"max":1000}
// The base color of an image repeated over the uv of the mesh, a uv the
// program computes and samples with its derivatives (mirai_uv0): what the
// resolve of a program that takes no derivative across a quad is checked with.
namespace Tiled {
struct Parameters {uint image;float repeat;};
Mirai_Surface evaluate(Mirai_Surface_Context ctx, Parameters p) {
    Mirai_Surface s=mirai_surface_default(ctx);
    s.base_color=mirai_sample_texture(ctx,p.image,mirai_uv0(ctx)*p.repeat).rgb;
    return s;
}
}
