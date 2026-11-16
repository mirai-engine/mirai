//! mirai vfx Spread
//! resource heat grid
//! stage give over particles
//! stage keep over heat
// Each particle splats give into the grid heat every step, which keeps what
// they splat; a particle takes the heat where it is: what the tests of the
// plugin check of splats and samples.
namespace Spread {
struct Parameters { float give; };
struct Attributes { float heat; };

void initialize(Mirai_Vfx_Context ctx, Parameters p, inout Mirai_Vfx_Particle particle, inout Attributes a) {}

void give(Mirai_Vfx_Context ctx, Parameters p, inout Mirai_Vfx_Particle particle, inout Attributes a) {
    mirai_vfx_grid_splat(ctx, heat, particle.position, 0u, float4(p.give, 0.0, 0.0, 0.0));
}

void keep(Mirai_Vfx_Cell cell, Parameters p) {
    float4 held = mirai_vfx_grid_load(cell.ctx, heat, cell.index, 0u);
    mirai_vfx_grid_store(cell, 0u, held + mirai_vfx_grid_splatted(cell.ctx, heat, cell.index, 0u));
}

void update(Mirai_Vfx_Context ctx, Parameters p, inout Mirai_Vfx_Particle particle, inout Attributes a) {
    a.heat = mirai_vfx_grid_sample(ctx, heat, particle.position, 0u).x;
}

void render(Mirai_Vfx_Context ctx, Parameters p, Mirai_Vfx_Particle particle, Attributes a, inout Mirai_Vfx_Visual visual) {}
}
