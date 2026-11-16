#include "native.slang"
// The places the pool keeps move by params.shift when the origin of the frame
// moved since they last did, before any view draws them, so that they stay
// where they are in the world (vfx.particles_shift). y 0, a thread per slot of
// the pool in use: a living particle, unless it is local to its emitter or of
// an effect view. y 1 and 2, a thread per event of each half: those that wait
// for a step, unless their emitter is of an effect view.
#define PARTICLES_WRITABLE
#define PARTICLES_COUNTED
#include "particles.slang"
#define MIRAI_GROUP_X 64
#define MIRAI_GROUP_Y 1
#define MIRAI_GROUP_Z 1

struct Params_Block { float4 shift; uint count; uint emitters; uint pad0; uint pad1; };
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 id : SV_DispatchThreadID) {
    if (id.y == 0u) {
        uint index = id.x;
        if (index >= params.count) return;
        Particle p = particles[index];
        uint slot = particle_emitter_of(p);
        if (p.lifetime <= 0.0 || slot >= params.emitters) return;
        Particle_Emitter e = particle_emitters[slot];
        if ((e.range.w & PARTICLE_FLAG_ACTIVE) == 0u || (e.range.w & (PARTICLE_FLAG_LOCAL | PARTICLE_FLAG_VIEW)) != 0u) return;
        particles[index].position = p.position + params.shift.xyz;
        return;
    }
    uint side = id.y - 1u;
    if (id.x >= min(particle_queue[side], PARTICLE_EVENT_CAPACITY)) return;
    Particle_Event ev = particle_event_load(side, id.x);
    uint slot = ev.target & 0xFFFFu;
    if (slot < params.emitters && (particle_emitters[slot].range.w & PARTICLE_FLAG_VIEW) != 0u) return;
    ev.position += params.shift.xyz;
    particle_event_store(side, id.x, ev);
}
