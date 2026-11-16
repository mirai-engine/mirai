//! mirai surface Imprint_Surface
//! parameter mesh_spacing {"default":0.25,"min":0.01,"max":4}
//! parameter detail_step {"default":0.04,"min":0.005,"max":1}
//! parameter detail {"default":1,"min":0,"max":4}
//! parameter pressed_tint {"default":[0.82,0.86,0.92],"min":0,"max":1,"color":true}
//! parameter pressed_roughness {"default":0.35,"min":0,"max":1}
//! parameter wet_darken {"default":0.5,"min":0,"max":1}
//! parameter wet_roughness {"default":0.2,"min":0,"max":1}
#include "vfx_world_texture.slang"
namespace Imprint_Surface {
struct Parameters {float mesh_spacing;float detail_step;float detail;float pressed_roughness;float3 pressed_tint;float wet_darken;float wet_roughness;};
// The ground of an Imprint_Ground under the imprints of the grid imprint:
// its vertices already rise and sink with them, so the normal adds only the
// slope finer than mesh_spacing (the metres between those vertices), found
// detail_step apart; where it was pressed it takes pressed_tint and
// pressed_roughness (packed snow, wet sand), and where a fluid wet it,
// darker by wet_darken and as rough as wet_roughness.
float height_at(float3 p) { return vfx_world_texture("imprint", p).x; }

float2 slope_at(float3 p, float step) {
    float2 d = float2(height_at(p + float3(step, 0.0, 0.0)) - height_at(p - float3(step, 0.0, 0.0)),
                      height_at(p + float3(0.0, 0.0, step)) - height_at(p - float3(0.0, 0.0, step)));
    return d / (2.0 * step);
}

Mirai_Surface evaluate(Mirai_Surface_Context ctx, Parameters p) {
    Mirai_Surface s = mirai_surface_default(ctx);
    float4 here = vfx_world_texture("imprint", ctx.world_position);
    float2 fine = slope_at(ctx.world_position, p.detail_step) - slope_at(ctx.world_position, max(p.mesh_spacing, p.detail_step));
    s.normal = normalize(s.normal - float3(fine.x, 0.0, fine.y) * p.detail);
    float pressed = saturate(here.y), wet = saturate(here.z);
    s.base_color *= lerp(float3(1.0), p.pressed_tint, pressed) * (1.0 - p.wet_darken * wet);
    s.roughness = lerp(lerp(s.roughness, p.pressed_roughness, pressed), p.wet_roughness, wet);
    return s;
}
}
