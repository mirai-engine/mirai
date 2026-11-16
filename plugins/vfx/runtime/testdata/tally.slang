//! mirai vfx Tally
//! resource counts grid
//! stage tally over counts iterations 5
// Each iteration adds one to every cell of the grid counts, over what the
// one before left: what the tests of the plugin check of stages over cells.
namespace Tally {
struct Parameters { float step; };
struct Attributes { float unused; };

void initialize(Mirai_Vfx_Context ctx, Parameters p, inout Mirai_Vfx_Particle particle, inout Attributes a) {}

void tally(Mirai_Vfx_Cell cell, Parameters p) {
    mirai_vfx_grid_store(cell, 0u, mirai_vfx_grid_load(cell.ctx, counts, cell.index, 0u) + float4(1.0, 0.0, 0.0, 0.0));
}

void update(Mirai_Vfx_Context ctx, Parameters p, inout Mirai_Vfx_Particle particle, inout Attributes a) {}

void render(Mirai_Vfx_Context ctx, Parameters p, Mirai_Vfx_Particle particle, Attributes a, inout Mirai_Vfx_Visual visual) {}
}
