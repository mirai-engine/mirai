//! mirai surface Sampled
//! parameter image {"kind":"texture","srgb":true,"normal":false}
// The base color of an image at the uv of the mesh, sampled by the program as
// a map would be: what the feedback of the levels of a program is checked with.
namespace Sampled {
struct Parameters {uint image;};
Mirai_Surface evaluate(Mirai_Surface_Context ctx, Parameters p) {
    Mirai_Surface s=mirai_surface_default(ctx);
    s.base_color=mirai_sample_texture(ctx,p.image,ctx.uv0,ctx.lod).rgb;
    return s;
}
}
