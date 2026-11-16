//! mirai surface Terrain_Slope
//! parameter ground {"default":[0.2,0.38,0.12],"min":0,"max":1,"color":true}
//! parameter rock {"default":[0.36,0.33,0.3],"min":0,"max":1,"color":true}
//! parameter slope {"default":0.7,"min":0,"max":1}
//! parameter sharpness {"default":8,"min":0.1,"max":64}
namespace Terrain_Slope {
struct Parameters {float3 ground;float slope;float3 rock;float sharpness;};
// Ground where the terrain is flat and rock where it is steep. `slope` is
// the height of the world normal at which one turns into the other, and
// `sharpness` how short that turn is.
Mirai_Surface evaluate(Mirai_Surface_Context ctx, Parameters p) {
    Mirai_Surface s=mirai_surface_default(ctx);
    float steep=saturate((p.slope-ctx.normal.y)*p.sharpness+0.5);
    s.base_color=lerp(p.ground,p.rock,steep);
    s.roughness=lerp(0.95,0.8,steep);
    return s;
}
}
