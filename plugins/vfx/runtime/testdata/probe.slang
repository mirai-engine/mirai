//! mirai vfx Probe
//! resource seen grid
//! stage look over seen
// Each cell of the grid seen traces the scene along +x and keeps what its
// ray met: what the tests of the plugin check of rays from stages.
namespace Probe {
struct Parameters { float reach; };
struct Attributes { float unused; };

void initialize(Mirai_Vfx_Context ctx, Parameters p, inout Mirai_Vfx_Particle particle, inout Attributes a) {}

void look(Mirai_Vfx_Cell cell, Parameters p) {
    Mirai_Vfx_Hit h = mirai_vfx_trace(cell.ctx, cell.position, float3(1.0, 0.0, 0.0), p.reach);
    mirai_vfx_grid_store(cell, 0u, float4(h.hit ? h.distance : -1.0, h.inside ? 1.0 : 0.0, h.normal.x, 0.0));
}

void update(Mirai_Vfx_Context ctx, Parameters p, inout Mirai_Vfx_Particle particle, inout Attributes a) {}

void render(Mirai_Vfx_Context ctx, Parameters p, Mirai_Vfx_Particle particle, Attributes a, inout Mirai_Vfx_Visual visual) {}
}
