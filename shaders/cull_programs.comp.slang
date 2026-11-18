#include "native.slang"
// The visible clusters of materials with a Surface program (PROGRAMS_* of
// cull_programs.slang), by mode: 0 starts the cull of a view, with no cluster
// in either phase and the draws of every program empty; then, after the cull
// of a phase, 1 counts its clusters by program, 2 gives each program its
// range of the list of the phase and its draw, an instance a cluster, and 3
// lists each cluster in the range of its program (bins.slang). The G-buffer
// draws the clusters of each program with the stage of that program.
#include "scene.slang"
#include "bins.slang"
#include "cull_programs.slang"
#define MIRAI_GROUP_X PROGRAMS_GROUP
#define MIRAI_GROUP_Y 1
#define MIRAI_GROUP_Z 1

// programs: bins, the largest program id plus one. capacity: of the list, both phases together.
struct Params_Block { uint mode; uint phase; uint programs; uint capacity; };
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);
[[vk::binding(SLOT_PASS0, 0)]] RWStructuredBuffer<uint> program_bins : register(MIRAI_REGISTER(u, SLOT_PASS0), space0);
// The clusters of each program, in its range: the instance and the cluster as a word of the index pool.
[[vk::binding(SLOT_PASS1, 0)]] RWStructuredBuffer<uint2> program_visible : register(MIRAI_REGISTER(u, SLOT_PASS1), space0);

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 dispatch_id : SV_DispatchThreadID, uint local : SV_GroupIndex) {
    uint i = dispatch_id.x;
    uint programs = min(params.programs, BINS_MAX);
    uint phase = params.phase;
    if (params.mode == 0u) {
        if (i < programs) {
            for (uint p = 0u; p < 2u; p++) {
                program_bins[programs_count(p, programs) + i] = 0u;
                program_bins[programs_cursor(p, programs) + i] = 0u;
                uint draw = programs_draw(p, i, programs);
                program_bins[draw] = CLUSTER_DRAW_VERTICES;
                program_bins[draw + 1u] = 0u;
                program_bins[draw + 2u] = 0u;
                program_bins[draw + 3u] = 0u;
            }
        }
        if (i == 0u) {
            for (uint p = 0u; p < 2u; p++) {
                program_bins[PROGRAMS_COUNT + p] = 0u;
                program_bins[PROGRAMS_DISPATCH + 3u * p] = 0u;
                program_bins[PROGRAMS_DISPATCH + 3u * p + 1u] = 1u;
                program_bins[PROGRAMS_DISPATCH + 3u * p + 2u] = 1u;
            }
        }
        return;
    }
    uint capacity = params.capacity;
    uint base = phase == 0u ? 0u : min(program_bins[PROGRAMS_COUNT], capacity);
    uint count = min(program_bins[PROGRAMS_COUNT + phase], capacity - base);
    if (params.mode == 2u) {
        // Few bins: one thread runs the prefix.
        if (i != 0u) return;
        uint running = base;
        for (uint p = 0u; p < programs; p++) {
            uint clusters = program_bins[programs_count(phase, programs) + p];
            program_bins[programs_offset(phase, programs) + p] = running;
            uint draw = programs_draw(phase, p, programs);
            program_bins[draw + 1u] = clusters;
            program_bins[draw + 3u] = running;
            running += clusters;
        }
        return;
    }
    // Modes 1 and 3: a thread per cluster of the phase.
    bool valid = i < count;
    uint at = programs_entry(base + min(i, max(count, 1u) - 1u), programs);
    uint program = valid ? min(program_bins[at + 2u], programs - 1u) : 0u;
    uint rank = bins_rank(program, valid, programs, local, PROGRAMS_GROUP);
    if (params.mode == 1u) {
        bins_count(program_bins, programs_count(phase, programs), programs, local, PROGRAMS_GROUP);
        return;
    }
    uint place = bins_place(program_bins, programs_cursor(phase, programs), program, rank, programs, local, PROGRAMS_GROUP);
    if (!valid) return;
    program_visible[program_bins[programs_offset(phase, programs) + program] + place] = uint2(program_bins[at], program_bins[at + 1u]);
}
