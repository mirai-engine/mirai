//! mirai vfx Dissolve
//! parameter hues {"default":1,"min":0,"max":1}
// Gives the material of its sprites how far each particle has burned away,
// none at its birth and all at the end of its life, and a hue of its own
// among hues: what Sprite_Dissolve reads of its particle.
namespace Dissolve {
struct Parameters { float hues; };
struct Attributes { float unused; };

void initialize(Mirai_Vfx_Context ctx, Parameters p, inout Mirai_Vfx_Particle particle, inout Attributes a) {}

void update(Mirai_Vfx_Context ctx, Parameters p, inout Mirai_Vfx_Particle particle, inout Attributes a) {}

void render(Mirai_Vfx_Context ctx, Parameters p, Mirai_Vfx_Particle particle, Attributes a, inout Mirai_Vfx_Visual visual) {
    float life = saturate(particle.age / max(particle.lifetime, 1e-5));
    visual.data[0] = float4(life, float(particle.seed & 1023u) / 1023.0 * p.hues, 0.0, 0.0);
    visual.given |= 1u;
}
}
