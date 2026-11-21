//! mirai vfx Rebase_Test
//! rebase
namespace Rebase_Test {
struct Parameters {};
struct Attributes {float3 point;};
void initialize(Mirai_Vfx_Context ctx, Parameters p, inout Mirai_Vfx_Particle particle, inout Attributes a) {
    a.point = particle.position;
}
void update(Mirai_Vfx_Context ctx, Parameters p, inout Mirai_Vfx_Particle particle, inout Attributes a) {}
void render(Mirai_Vfx_Context ctx, Parameters p, Mirai_Vfx_Particle particle, Attributes a, inout Mirai_Vfx_Visual visual) {}
void rebase(float3 origin_shift, inout Attributes a) { a.point += origin_shift; }
}
