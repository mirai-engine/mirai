//! mirai vfx Beacon
// A blue light that each particle gives once it is a quarter of a second
// old, whatever its color: what the tests give a Light layer whose program
// gives its lights (Mirai_Vfx_Visual.light_*).
namespace Beacon {
struct Parameters { float unused; };
struct Attributes { float unused; };

void initialize(Mirai_Vfx_Context ctx, Parameters p, inout Mirai_Vfx_Particle particle, inout Attributes a) {}

void update(Mirai_Vfx_Context ctx, Parameters p, inout Mirai_Vfx_Particle particle, inout Attributes a) {}

void render(Mirai_Vfx_Context ctx, Parameters p, Mirai_Vfx_Particle particle, Attributes a, inout Mirai_Vfx_Visual visual) {
    visual.light_color = float3(0.1, 0.3, 1.0);
    visual.light_intensity = particle.age > 0.25 ? 4.0 : 0.0;
    visual.light_range = 2.0;
    visual.light_radius = 0.05;
}
}
