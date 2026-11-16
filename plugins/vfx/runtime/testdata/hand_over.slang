//! mirai vfx Hand_Over
// Gives the material of its sprites blue as its second data, 1 as their
// random value and a metre across.
namespace Hand_Over {
struct Parameters { float unused; };
struct Attributes { float unused; };

void initialize(Mirai_Vfx_Context ctx, Parameters p, inout Mirai_Vfx_Particle particle, inout Attributes a) {}

void update(Mirai_Vfx_Context ctx, Parameters p, inout Mirai_Vfx_Particle particle, inout Attributes a) {}

void render(Mirai_Vfx_Context ctx, Parameters p, Mirai_Vfx_Particle particle, Attributes a, inout Mirai_Vfx_Visual visual) {
    visual.data[1] = float4(0.0, 0.0, 1.0, 1.0);
    visual.given |= 2u;
    visual.random = 1.0;
    visual.size = 1.0;
}
}
