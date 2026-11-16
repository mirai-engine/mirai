//! mirai vfx Smoke_Plume
//! resource plume grid
//! stage feed over particles
//! stage rise over plume
//! parameter density {"default":4,"min":0,"max":64}
//! parameter heat {"default":6,"min":0,"max":64}
//! parameter lift {"default":1.2,"min":0,"max":8}
//! parameter spread {"default":0.3,"min":0,"max":1}
//! parameter fade {"default":0.35,"min":0,"max":8}
//! parameter cooling {"default":1.5,"min":0,"max":16}
// A column of smoke in the grid plume, which a Particle_Volume draws: each
// particle feeds density, and glow while it is young, where it is; the cells
// carry it upward at lift, spread it sideways and lose it by fade (glow by
// cooling). The particles themselves are not meant to be seen.
namespace Smoke_Plume {
struct Parameters {
    float density; // a cell a second, of a particle
    float heat;    // glow a particle feeds at its birth, a second
    float lift;    // metres a second the smoke rises
    float spread;  // share of the neighbors a cell takes a second
    float fade;    // of the density, a second
    float cooling; // of the glow, a second
};
struct Attributes { float unused; };

void initialize(Mirai_Vfx_Context ctx, Parameters p, inout Mirai_Vfx_Particle particle, inout Attributes a) {}

void feed(Mirai_Vfx_Context ctx, Parameters p, inout Mirai_Vfx_Particle particle, inout Attributes a) {
    float young = 1.0 - saturate(particle.age / max(particle.lifetime, 1e-3));
    mirai_vfx_grid_splat(ctx, plume, particle.position, 0u, float4(p.density, p.heat * young * young, 0.0, 0.0) * ctx.delta_time);
}

void rise(Mirai_Vfx_Cell cell, Parameters p) {
    float dt = cell.ctx.delta_time;
    float size = mirai_vfx_grid(cell.ctx, plume).cell_size;
    float4 here = mirai_vfx_grid_load(cell.ctx, plume, cell.index, 0u);
    float4 below = mirai_vfx_grid_load(cell.ctx, plume, cell.index - int3(0, 1, 0), 0u);
    float4 sides = (mirai_vfx_grid_load(cell.ctx, plume, cell.index + int3(1, 0, 0), 0u)
        + mirai_vfx_grid_load(cell.ctx, plume, cell.index - int3(1, 0, 0), 0u)
        + mirai_vfx_grid_load(cell.ctx, plume, cell.index + int3(0, 0, 1), 0u)
        + mirai_vfx_grid_load(cell.ctx, plume, cell.index - int3(0, 0, 1), 0u)) * 0.25;
    // Less than a cell a step: what rises comes from the cell below.
    float4 moved = lerp(here, below, saturate(p.lift * dt / size));
    moved = lerp(moved, sides, saturate(p.spread * dt));
    moved *= float4(exp(-p.fade * dt), exp(-p.cooling * dt), 0.0, 0.0);
    mirai_vfx_grid_store(cell, 0u, moved + mirai_vfx_grid_splatted(cell.ctx, plume, cell.index, 0u));
}

void update(Mirai_Vfx_Context ctx, Parameters p, inout Mirai_Vfx_Particle particle, inout Attributes a) {}

void render(Mirai_Vfx_Context ctx, Parameters p, Mirai_Vfx_Particle particle, Attributes a, inout Mirai_Vfx_Visual visual) {
    visual.color.a = 0.0;
}
}
