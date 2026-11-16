//! mirai surface Surface_Probe
//! parameter strength {"default":1,"min":0,"max":100}
// A surface of a test of the plugin that glows with what its context says:
// red, the color of its vertices as data; green, the scale of its object
// along y over 4; blue, 1 on the +x side of its object and 0 on the other.
namespace Surface_Probe {
struct Parameters { float strength; };
Mirai_Surface evaluate(Mirai_Surface_Context ctx, Parameters p) {
    Mirai_Surface s = mirai_surface_default(ctx);
    s.base_color = float3(0.0);
    float side = mirai_object_point(ctx, ctx.world_position).x > 0.0 ? 1.0 : 0.0;
    s.emission = float3(ctx.vertex_color.r, mirai_object_scale(ctx).y * 0.25, side) * p.strength;
    return s;
}
}
