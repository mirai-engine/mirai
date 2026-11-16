//! mirai vfx Gather
//! resource hits channel
// A particle grows with the values of the birth that started it and drifts
// to the first birth of the channel hits in each step: what the tests of the
// plugin compile of channels.
namespace Gather {
struct Parameters { float pull; };
struct Attributes { float grown; };

void initialize(Mirai_Vfx_Context ctx, Parameters p, inout Mirai_Vfx_Particle particle, inout Attributes a) {
    a.grown = 1.0 + ctx.values.x;
    particle.size *= a.grown;
}

void update(Mirai_Vfx_Context ctx, Parameters p, inout Mirai_Vfx_Particle particle, inout Attributes a) {
    if (mirai_vfx_channel_count(ctx, hits) == 0u) return;
    Mirai_Vfx_Birth first = mirai_vfx_channel_birth(ctx, hits, 0u);
    particle.velocity += (first.position - particle.position) * p.pull * ctx.delta_time;
}

void render(Mirai_Vfx_Context ctx, Parameters p, Mirai_Vfx_Particle particle, Attributes a, inout Mirai_Vfx_Visual visual) {}
}
