//! mirai vfx Glitch
// A program that writes NaN into one of its Attributes and a finite value
// into the other: what the tests of the plugin check of the scan of rows.
namespace Glitch {
struct Parameters { float unused; };
struct Attributes { float heat; float calm; };

void initialize(Mirai_Vfx_Context ctx, Parameters p, inout Mirai_Vfx_Particle particle, inout Attributes a) {
    a.heat = asfloat(0x7fc00000u);
    a.calm = 1.0;
}

void update(Mirai_Vfx_Context ctx, Parameters p, inout Mirai_Vfx_Particle particle, inout Attributes a) {}

void render(Mirai_Vfx_Context ctx, Parameters p, Mirai_Vfx_Particle particle, Attributes a, inout Mirai_Vfx_Visual visual) {}
}
