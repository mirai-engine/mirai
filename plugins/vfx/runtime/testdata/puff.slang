//! mirai vfx Puff
//! resource smoke grid
//! stage fill over smoke
// The grid smoke holds density, and glow, in a ball around the emitter:
// what the tests of the plugin draw as a volume.
namespace Puff {
struct Parameters { float radius; float glow; };
struct Attributes { float unused; };

void initialize(Mirai_Vfx_Context ctx, Parameters p, inout Mirai_Vfx_Particle particle, inout Attributes a) {}

void fill(Mirai_Vfx_Cell cell, Parameters p) {
    float inside = length(cell.position - cell.ctx.origin) < p.radius ? 1.0 : 0.0;
    mirai_vfx_grid_store(cell, 0u, float4(inside, inside * p.glow, 0.0, 0.0));
}

void update(Mirai_Vfx_Context ctx, Parameters p, inout Mirai_Vfx_Particle particle, inout Attributes a) {}

void render(Mirai_Vfx_Context ctx, Parameters p, Mirai_Vfx_Particle particle, Attributes a, inout Mirai_Vfx_Visual visual) {}
}
