//! mirai vfx Lay_Across
// Turns the mesh of its particles a quarter about the y of the world, their z
// along its x, three times as thick along their y: what the tests of the
// plugin check of the turn and the scale a program gives.
namespace Lay_Across {
struct Parameters { float unused; };
struct Attributes { float unused; };

void initialize(Mirai_Vfx_Context ctx, Parameters p, inout Mirai_Vfx_Particle particle, inout Attributes a) {}

void update(Mirai_Vfx_Context ctx, Parameters p, inout Mirai_Vfx_Particle particle, inout Attributes a) {}

void render(Mirai_Vfx_Context ctx, Parameters p, Mirai_Vfx_Particle particle, Attributes a, inout Mirai_Vfx_Visual visual) {
    visual.orientation = float4(0.0, 0.70710678, 0.0, 0.70710678);
    visual.scale = float3(1.0, 3.0, 1.0);
}
}
