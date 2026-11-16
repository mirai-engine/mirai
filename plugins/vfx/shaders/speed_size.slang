//! mirai vfx Speed_Size
//! parameter speed {"default":10,"min":0,"max":1000}
//! parameter least {"default":1,"min":0,"max":100}
//! parameter most {"default":2,"min":0,"max":100}
namespace Speed_Size {
// Each particle is drawn least times its size at rest and most times at
// speed metres per second or faster, in between as it goes.
struct Parameters {float speed;float least;float most;};
struct Attributes {float unused;};

void initialize(Mirai_Vfx_Context ctx, Parameters p, inout Mirai_Vfx_Particle particle, inout Attributes a) {}

void update(Mirai_Vfx_Context ctx, Parameters p, inout Mirai_Vfx_Particle particle, inout Attributes a) {}

void render(Mirai_Vfx_Context ctx, Parameters p, Mirai_Vfx_Particle particle, Attributes a, inout Mirai_Vfx_Visual visual) {
    visual.size *= lerp(p.least, p.most, saturate(length(particle.velocity) / max(p.speed, 1e-4)));
}
}
