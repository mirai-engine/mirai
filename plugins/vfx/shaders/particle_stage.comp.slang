#include "native.slang"
// The stages of the Vfx programs (vfx/runtime/stages.odin), a mode a
// dispatch. 0: stage k over the particles, a thread per slot of the pool the
// emitters of the program hold, from params.first. 1: an iteration of stage k
// over the cells of a grid, a thread per cell of each emitter of the program
// (y, from params.emitter_first): the stage reads what the one before left and leaves
// the layers of its cell in the other copy, which takes the rest of them as
// they were. 2: the grids of each emitter that its stage k went over in this
// iteration or wrote take the copy it left; 5: those its stage k over the
// particles wrote. 4: a thread per cell of each
// emitter (y): the grids its stage k writes besides its own start the stage
// as they are, or at zero those declared cleared. 3: the cells that came into the region of
// each grid (y; their rows from params.stage on) since its cells were cleared
// start at zero.
//! variant hw MIRAI_HW_RT=1
//! per vfx program
#define PARTICLES_WRITABLE
#define PARTICLE_STAGE_PASS
#include "trace.slang"
#include "particle_programs.slang"
#define MIRAI_GROUP_X 64
#define MIRAI_GROUP_Y 1
#define MIRAI_GROUP_Z 1

struct Params_Block { uint mode; uint emitters; uint count; uint parity; uint step; uint last; uint stage; uint iteration; uint program; uint first; uint emitter_first; uint pad0; };
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);

// The emitter of a living particle at a slot of the pool in use; false for a free slot or
// one of a range that went.
bool stage_particle(uint index, out Particle p, out uint slot, out Particle_Emitter e) {
    p = particles[index];
    slot = particle_emitter_of(p);
    e = (Particle_Emitter)0;
    if (p.lifetime <= 0.0 || slot >= params.emitters) return false;
    e = particle_emitters[slot];
    return (e.range.w & PARTICLE_FLAG_ACTIVE) != 0u && index >= e.range.x && index < e.range.x + e.range.y;
}

// The time of the step for the context of a stage.
float stage_time(Particle_Emitter e) { return e.step.w - e.step.x + float(params.step + 1u) * e.step.y; }

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 id : SV_DispatchThreadID) {
    particle_step_last = params.last != 0u;
    switch (params.mode) {
    case 0u: {
        uint index = params.first + id.x;
        Particle p;
        uint slot;
        Particle_Emitter e;
        if (index >= params.count || !stage_particle(index, p, slot, e) || e.program.x == 0u || e.program.x != params.program) return;
        Particle_Stage stage = particle_stage_of(slot, params.stage);
        if (stage.kind != PARTICLE_STAGE_PARTICLES || params.iteration >= max(stage.iterations, 1u)) return;
        bool paused = (e.range.w & PARTICLE_FLAG_PAUSED) != 0u;
        float4 packed[16];
        particle_parameters(slot, packed);
        Mirai_Vfx_Context ctx = particle_program_context(slot, stage_time(e), paused ? 0.0 : e.step.y);
        ctx.particle = index;
        ctx.iteration = params.iteration;
        Mirai_Vfx_Particle v = particle_program_value(slot, p);
        if (!mirai_vfx_particle_stage(e.program.x, params.stage, packed, particle_attributes(slot, index), ctx, v)) return;
        particle_program_store(slot, v, true, p);
        particles[index] = p;
        return;
    }
    case 1u: {
        uint slot = params.emitter_first + id.y;
        if (slot >= params.emitters) return;
        Particle_Emitter e = particle_emitters[slot];
        if ((e.range.w & PARTICLE_FLAG_ACTIVE) == 0u || e.program.x == 0u || e.program.x != params.program) return;
        Particle_Stage stage = particle_stage_of(slot, params.stage);
        if (stage.kind != PARTICLE_STAGE_CELLS || params.iteration >= stage.iterations) return;
        Particle_Grid_Row g;
        if (!particle_grid_of(slot, stage.row - 1u, g) || id.x >= g.cells.x * g.cells.y * g.cells.z) return;
        uint3 along = uint3(id.x % g.cells.x, (id.x / g.cells.x) % g.cells.y, id.x / (g.cells.x * g.cells.y));
        int3 index = g.first + int3(along);
        uint at;
        if (!particle_grid_cell(g, index, at)) return;
        // What the stage does not leave stays as it was.
        uint copy = particle_grid_copy(g);
        for (uint layer = 0u; layer < g.layers; layer++) {
            particle_world_bytes.Store4(particle_grid_address(g, copy ^ 1u, at, layer), particle_world_bytes.Load4(particle_grid_address(g, copy, at, layer)));
        }
        float4 packed[16];
        particle_parameters(slot, packed);
        bool paused = (e.range.w & PARTICLE_FLAG_PAUSED) != 0u;
        Mirai_Vfx_Cell cell;
        cell.ctx = particle_program_context(slot, stage_time(e), paused ? 0.0 : e.step.y);
        cell.ctx.iteration = params.iteration;
        cell.grid = stage.row - 1u;
        cell.index = index;
        cell.position = particle_grid_middle(g, index);
        mirai_vfx_cell_stage(e.program.x, params.stage, packed, cell);
        return;
    }
    case 2u:
    case 5u: {
        uint slot = id.x;
        if (slot >= params.emitters) return;
        Particle_Emitter e = particle_emitters[slot];
        if ((e.range.w & PARTICLE_FLAG_ACTIVE) == 0u || e.program.x == 0u) return;
        Particle_Stage stage = particle_stage_of(slot, params.stage);
        uint kind = params.mode == 2u ? PARTICLE_STAGE_CELLS : PARTICLE_STAGE_PARTICLES;
        if (stage.kind != kind || params.iteration >= max(stage.iterations, 1u)) return;
        uint written = stage.writes;
        if (stage.kind == PARTICLE_STAGE_CELLS) written |= 1u << (stage.row - 1u);
        for (uint resource = 0u; resource < PARTICLE_RESOURCES - 1u; resource++) {
            Particle_Grid_Row g;
            if ((written & (1u << resource)) == 0u || !particle_grid_of(slot, resource, g)) continue;
            particle_world_bytes.Store(g.parity, particle_grid_copy(g) ^ 1u);
        }
        return;
    }
    case 4u: {
        uint slot = id.y;
        if (slot >= params.emitters) return;
        Particle_Emitter e = particle_emitters[slot];
        if ((e.range.w & PARTICLE_FLAG_ACTIVE) == 0u || e.program.x == 0u) return;
        Particle_Stage stage = particle_stage_of(slot, params.stage);
        if (stage.kind == PARTICLE_STAGE_NONE || params.iteration >= max(stage.iterations, 1u)) return;
        for (uint resource = 0u; resource < PARTICLE_RESOURCES - 1u; resource++) {
            Particle_Grid_Row g;
            if ((stage.writes & (1u << resource)) == 0u || !particle_grid_of(slot, resource, g) || id.x >= g.cells.x * g.cells.y * g.cells.z) continue;
            uint copy = particle_grid_copy(g);
            bool zero = (stage.clears & (1u << resource)) != 0u;
            for (uint layer = 0u; layer < g.layers; layer++) {
                uint at = id.x;
                particle_world_bytes.Store4(particle_grid_address(g, copy ^ 1u, at, layer), zero ? uint4(0u) : particle_world_bytes.Load4(particle_grid_address(g, copy, at, layer)));
            }
        }
        return;
    }
    case 3u: {
        Particle_Grid_Row g = particle_grid_row_at(params.stage + id.y * PARTICLE_GRID_ROW_BYTES);
        if (g.moved == 0u || id.x >= g.cells.x * g.cells.y * g.cells.z) return;
        uint3 along = uint3(id.x % g.cells.x, (id.x / g.cells.x) % g.cells.y, id.x / (g.cells.x * g.cells.y));
        int3 index = g.first + int3(along);
        // In the region where its cells were cleared last: it keeps them.
        bool kept = true;
        for (uint axis = 0u; axis < 3u; axis++) {
            if (g.cells[axis] <= 1u) continue;
            int from = index[axis] - g.previous[axis];
            kept = kept && from >= 0 && from < int(g.cells[axis]);
        }
        uint at;
        if (kept || !particle_grid_cell(g, index, at)) return;
        for (uint layer = 0u; layer < g.layers; layer++) {
            particle_world_bytes.Store4(particle_grid_address(g, 0u, at, layer), uint4(0u));
            particle_world_bytes.Store4(particle_grid_address(g, 1u, at, layer), uint4(0u));
        }
        return;
    }
    default:
        return;
    }
}
