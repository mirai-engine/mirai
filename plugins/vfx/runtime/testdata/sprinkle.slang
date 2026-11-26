//! mirai vfx Sprinkle
//! births
// Starts rate particles for each second its emitter emits in a frame: what
// the tests of the plugin check of the births a program gives.
namespace Sprinkle {
struct Parameters { float rate; };
struct Attributes { float unused; };

uint births(Mirai_Vfx_Context ctx, Parameters p) { return uint(ceil(p.rate * ctx.delta_time)); }

void initialize(Mirai_Vfx_Context ctx, Parameters p, inout Mirai_Vfx_Particle particle, inout Attributes a) {}

void update(Mirai_Vfx_Context ctx, Parameters p, inout Mirai_Vfx_Particle particle, inout Attributes a) {}

void render(Mirai_Vfx_Context ctx, Parameters p, Mirai_Vfx_Particle particle, Attributes a, inout Mirai_Vfx_Visual visual) {}
}
