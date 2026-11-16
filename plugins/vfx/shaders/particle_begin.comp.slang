#include "native.slang"
// Mode 0, a thread per slot of each emitter that starts: the slot is free
// and on the free list. Mode 1, a thread per emitter, each step: the counters
// of the step, the dispatch that takes the events of the step before, and
// the half of the events this step writes is empty.
#define PARTICLES_WRITABLE
#include "particles.slang"
#define MIRAI_GROUP_X 64
#define MIRAI_GROUP_Y 1
#define MIRAI_GROUP_Z 1

struct Params_Block { uint mode; uint emitters; uint count; uint parity; uint step; uint last; uint pad0; uint pad1; };
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 id : SV_DispatchThreadID) {
    if (params.mode == 0u) {
        Particle_Emitter e = particle_emitters[id.y];
        if ((e.range.w & PARTICLE_FLAG_RESET) == 0u || id.x >= e.range.y) return;
        particles[e.range.x + id.x].lifetime = 0.0;
        particle_lists[e.range.x + id.x] = id.x;
        particle_lists[2u * e.program.y + e.range.x + id.x] = 0xFFFFFFFFu;
        return;
    }
    if (params.mode == 2u) {
        // After the last step: the dispatch that takes its events now.
        if (id.x != 0u) return;
        uint events = min(particle_queue[params.parity], PARTICLE_EVENT_CAPACITY);
        uint base = 4u + 4u * params.parity;
        particle_queue[base] = (events + 63u) / 64u;
        particle_queue[base + 1u] = 1u;
        particle_queue[base + 2u] = 1u;
        return;
    }
    if (id.x == 0u) {
        uint read = 1u - params.parity;
        uint events = min(particle_queue[read], PARTICLE_EVENT_CAPACITY);
        uint base = 4u + 4u * read;
        particle_queue[base] = (events + 63u) / 64u;
        particle_queue[base + 1u] = 1u;
        particle_queue[base + 2u] = 1u;
        particle_queue[params.parity] = 0u;
    }
    if (id.x >= params.emitters) return;
    Particle_Emitter e = particle_emitters[id.x];
    if ((e.range.w & PARTICLE_FLAG_ACTIVE) == 0u) return;
    if (params.step == 0u && (e.range.w & PARTICLE_FLAG_RESET) != 0u) {
        particle_states[id.x].dead = e.range.y;
        particle_states[id.x].born = 0u;
    }
    if (params.step == 0u) particle_states[id.x].births = 0u;
    particle_states[id.x].alive = 0u;
}
