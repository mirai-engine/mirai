//! mirai surface Count_Ground
//! parameter scale {"default":0.01,"min":0,"max":1}
#include "vfx_world_texture.slang"
// The floor of a test of the plugin: black, glowing by what the texture of
// the world counts holds where it is, times scale.
namespace Count_Ground {
struct Parameters { float scale; };
Mirai_Surface evaluate(Mirai_Surface_Context ctx, Parameters p) {
    Mirai_Surface s = mirai_surface_default(ctx);
    s.base_color = float3(0.0);
    s.emission = float3(vfx_world_texture("counts", ctx.world_position).x * p.scale);
    return s;
}
}
