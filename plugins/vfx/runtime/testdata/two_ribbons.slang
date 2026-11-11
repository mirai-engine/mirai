//! mirai vfx Two_Ribbons
// Its particles join two ribbons, by the order of their births, whose ids
// differ only in the highest bit a ribbon keeps.
namespace Two_Ribbons {
struct Parameters { float unused; };
struct Attributes { float unused; };

void initialize(Mirai_Vfx_Context ctx, Parameters p, inout Mirai_Vfx_Particle particle, inout Attributes a) {
    particle.ribbon = (ctx.birth & 1u) != 0u ? (1u << 20u) | 1u : 1u;
}

void update(Mirai_Vfx_Context ctx, Parameters p, inout Mirai_Vfx_Particle particle, inout Attributes a) {}

void render(Mirai_Vfx_Context ctx, Parameters p, Mirai_Vfx_Particle particle, Attributes a, inout Mirai_Vfx_Visual visual) {}
}
