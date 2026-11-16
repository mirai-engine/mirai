#include "native.slang"
// A layer of a grid flat along y as halves after the grids, a thread a cell,
// for the renderer to copy into its texture of the world: the cell of the
// world c at the texel c modulo the cells, where the grid keeps it, so that a
// material reads it repeating over the world (vfx_world_texture.slang)
// without the region moving it.
#define PARTICLES_WRITABLE
#include "particle_programs.slang"
#define MIRAI_GROUP_X 8
#define MIRAI_GROUP_Y 8
#define MIRAI_GROUP_Z 1

// grid: bytes of its row in particle_frame; packed: bytes in particle_world_bytes
// where its texels go, from the first multiple of 16.
struct Params_Block { uint grid; uint layer; uint packed; uint pad; };
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 id : SV_DispatchThreadID) {
    Particle_Grid_Row g = particle_grid_row_at(params.grid);
    if (id.x >= g.cells.x || id.y >= g.cells.z) return;
    uint at = id.x + g.cells.x * id.y;
    float4 v = asfloat(particle_world_bytes.Load4(particle_grid_address(g, particle_grid_copy(g), at, params.layer)));
    uint first = (params.packed + 15u) & ~15u;
    particle_world_bytes.Store2(first + at * 8u, half_bits(v));
}
