#include "native.slang"
#define PARTICLES_WRITABLE
#include "particles.slang"
#include "particle_work.slang"
#define MIRAI_GROUP_X 64
#define MIRAI_GROUP_Y 1
#define MIRAI_GROUP_Z 1

struct Params_Block {
    uint mode; uint emitters; uint count; uint parity; uint step; uint last;
    uint stage; uint iteration; uint program; uint first; uint emitter_first; uint fields;
};
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);

// Work_Kind in gpu.odin.
uint work_count(uint slot) {
    uint4 range = particle_emitters[slot].range;
    switch (params.count) {
    case 0u: return (range.w & PARTICLE_FLAG_RESET) != 0u ? range.y : 0u;
    case 1u: return (range.w & (PARTICLE_FLAG_BIRTHS | PARTICLE_FLAG_PREPARE)) != 0u &&
        (range.w & PARTICLE_FLAG_PAUSED) == 0u ? 1u : 0u;
    case 2u: {
        uint count;
        float unused;
        uint ribbon;
        particle_spawn(slot, params.step, INVALID, count, unused, ribbon);
        return count;
    }
    case 3u: return particle_channel_span(slot, params.step).y;
    case 4u: return particle_states[slot].live_count[params.parity];
    default: break;
    }
    Particle_Stage stage = particle_stage_of(slot, params.stage);
    if (stage.kind == PARTICLE_STAGE_NONE || params.iteration >= max(stage.iterations, 1u)) return 0u;
    if (params.count == 5u) {
        return stage.kind == PARTICLE_STAGE_PARTICLES ? particle_states[slot].live_count[params.parity] : 0u;
    }
    if (params.count == 6u) {
        if (stage.kind != PARTICLE_STAGE_CELLS) return 0u;
        Particle_Grid_Row grid;
        return particle_grid_of(slot, stage.row - 1u, grid) ? grid.cells.x * grid.cells.y * grid.cells.z : 0u;
    }
    if (params.count == 7u) {
        uint cells = 0u;
        for (uint resource = 0u; resource < PARTICLE_RESOURCES - 1u; resource++) {
            Particle_Grid_Row grid;
            if ((stage.writes & (1u << resource)) != 0u && particle_grid_of(slot, resource, grid)) {
                cells = max(cells, grid.cells.x * grid.cells.y * grid.cells.z);
            }
        }
        return cells;
    }
    if (params.count == 8u) return stage.kind == PARTICLE_STAGE_CELLS ? 1u : 0u;
    return stage.kind == PARTICLE_STAGE_PARTICLES && stage.writes != 0u ? 1u : 0u;
}

void work_dispatch(uint count) {
    particle_queue[WORK_AT / 4u] = min(count, PARTICLE_WORK_ROW);
    particle_queue[WORK_AT / 4u + 1u] = max((count + PARTICLE_WORK_ROW - 1u) / PARTICLE_WORK_ROW, 1u);
    particle_queue[WORK_AT / 4u + 2u] = 1u;
    particle_queue[WORK_AT / 4u + 3u] = count;
}

groupshared uint prefix[MIRAI_GROUP_X];
groupshared uint preceding;

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 id : SV_DispatchThreadID, uint3 group : SV_GroupID, uint3 local : SV_GroupThreadID) {
    if (params.mode == 3u) {
        uint lane = local.x;
        if (params.emitter_first == 1u) {
            if (lane == 0u) {
                uint slot = particle_frame_slot(params.first);
                uint count = (work_count(slot) + MIRAI_GROUP_X - 1u) / MIRAI_GROUP_X;
                particle_queue[WORK_AT / 4u + 4u] = count;
                particle_queue[WORK_AT / 4u + 5u] = slot;
                work_dispatch(count);
            }
            return;
        }
        if (lane == 0u) preceding = 0u;
        GroupMemoryBarrierWithGroupSync();
        for (uint tile = 0u; tile < params.emitter_first; tile += MIRAI_GROUP_X) {
            uint entry = tile + lane;
            uint slot = entry < params.emitter_first ? particle_frame_slot(params.first + entry) : 0u;
            uint count = entry < params.emitter_first ? work_count(slot) : 0u;
            prefix[lane] = (count + MIRAI_GROUP_X - 1u) / MIRAI_GROUP_X;
            GroupMemoryBarrierWithGroupSync();
            for (uint stride = 1u; stride < MIRAI_GROUP_X; stride <<= 1u) {
                uint add = lane >= stride ? prefix[lane - stride] : 0u;
                GroupMemoryBarrierWithGroupSync();
                prefix[lane] += add;
                GroupMemoryBarrierWithGroupSync();
            }
            uint first = preceding;
            GroupMemoryBarrierWithGroupSync();
            if (entry < params.emitter_first) {
                particle_queue[WORK_AT / 4u + 4u + entry * 2u] = first + prefix[lane];
                particle_queue[WORK_AT / 4u + 5u + entry * 2u] = slot;
            }
            if (lane == 0u) preceding = first + prefix[MIRAI_GROUP_X - 1u];
            GroupMemoryBarrierWithGroupSync();
        }
        if (lane == 0u) {
            work_dispatch(preceding);
        }
        return;
    }
    if (params.mode == 0u) {
        Particle_Work work = particle_work(group, local.x, params.emitter_first);
        if (work.slot == INVALID) return;
        uint4 range = particle_emitters[work.slot].range;
        if (work.item >= range.y) return;
        particles[range.x + work.item].lifetime = 0.0;
        particle_lists[range.x + work.item] = work.item;
        particle_lists[2u * particle_emitters[work.slot].program.y + range.x + work.item] = 0xFFFFFFFFu;
        return;
    }
    if (id.x == 0u) {
        uint read = params.mode == 2u ? params.parity : 1u - params.parity;
        uint events = min(particle_queue[read], PARTICLE_EVENT_CAPACITY);
        uint base = 4u + 4u * read;
        particle_queue[base] = (events + 63u) / 64u;
        particle_queue[base + 1u] = 1u;
        particle_queue[base + 2u] = 1u;
        if (params.mode == 1u) {
            particle_queue[params.parity] = 0u;
        } else {
            particle_queue[SORT_AT / 4u] = 0u;
            particle_queue[SORT_AT / 4u + 1u] = 1u;
            particle_queue[SORT_AT / 4u + 2u] = 1u;
            // The header of the lights of the frame: none, and a box that holds nothing.
            particle_queue[PARTICLE_LIGHTS_WORD] = 0u;
            for (uint i = 1u; i <= 3u; i++) {
                particle_queue[PARTICLE_LIGHTS_WORD + i] = 0xFFFFFFFFu;
                particle_queue[PARTICLE_LIGHTS_WORD + 3u + i] = 0u;
            }
        }
    }
    if (params.mode == 2u || id.x >= params.count) return;
    uint slot = particle_frame_slot(id.x);
    uint4 range = particle_emitters[slot].range;
    if (params.step == 0u) {
        particle_states[slot].births = 0u;
        particle_states[slot].lights = 0u;
        if ((range.w & PARTICLE_FLAG_RESET) != 0u) {
            particle_states[slot].dead = range.y;
            particle_states[slot].born = 0u;
            particle_states[slot].live_count[params.parity] = 0u;
        }
    }
    particle_states[slot].live_count[params.parity ^ 1u] = 0u;
}
