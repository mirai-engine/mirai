//! mirai surface Painted
//! parameter shade {"default":[0.5,0.25,1],"min":0,"max":1,"color":true}
//! parameter softness {"default":0.2,"min":0,"max":1}
// A stylized surface given by a program: diffuse alone across a terminator
// softness wide, and the light around by its shade.
namespace Painted {
struct Parameters {float3 shade;float softness;};
Mirai_Surface evaluate(Mirai_Surface_Context ctx, Parameters p) {
    Mirai_Surface s=mirai_surface_standard(ctx);
    s.stylized=true;
    s.stylized_softness=p.softness;
    s.stylized_shade=p.shade;
    return s;
}
}
