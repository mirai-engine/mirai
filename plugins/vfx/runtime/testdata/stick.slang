//! mirai vfx Stick
//! resource body surface
// A particle starts on the surface body and stays on its triangle as the
// surface moves: what the tests of the plugin check of surfaces.
namespace Stick {
struct Parameters { float lift; };
struct Attributes { uint triangle; float2 barycentric; };

void initialize(Mirai_Vfx_Context ctx, Parameters p, inout Mirai_Vfx_Particle particle, inout Attributes a) {
    uint seed = particle.seed;
    Mirai_Vfx_Surface s = mirai_vfx_surface_sample(ctx, body, seed);
    if (!s.valid) return;
    particle.position = s.position + s.normal * p.lift;
    particle.velocity = float3(0.0);
    a.triangle = s.triangle;
    a.barycentric = s.barycentric;
}

void update(Mirai_Vfx_Context ctx, Parameters p, inout Mirai_Vfx_Particle particle, inout Attributes a) {
    Mirai_Vfx_Surface s = mirai_vfx_surface_at(ctx, body, a.triangle, a.barycentric);
    if (!s.valid) return;
    particle.position = s.position + s.normal * p.lift;
    particle.velocity = float3(0.0);
}

void render(Mirai_Vfx_Context ctx, Parameters p, Mirai_Vfx_Particle particle, Attributes a, inout Mirai_Vfx_Visual visual) {}
}
