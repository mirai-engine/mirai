#include "native.slang"
#define PARTICLES_WRITABLE
#include "particles.slang"
#define MIRAI_GROUP_X 64
#define MIRAI_GROUP_Y 1
#define MIRAI_GROUP_Z 1

struct Params_Block { uint mode; uint emitters; uint count; uint parity; };
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);
[[vk::binding(SLOT_PASS9, 0)]] RWStructuredBuffer<uint> counted : register(MIRAI_REGISTER(u, SLOT_PASS9), space0);

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 id : SV_DispatchThreadID) {
    if (id.x == 0u) particle_queue[params.parity ^ 1u] = 0u;
    if (id.x >= params.count) return;
    uint slot = particle_frame_slot(id.x);
    uint alive = particle_states[slot].live_count[params.parity];
    uint4 range = particle_emitters[slot].range;
    uint kind = particle_emitters[slot].kinds.y;
    uint count = particle_emitters[slot].mesh.x;
    bool ribbon = kind == PARTICLE_RENDER_RIBBON;
    particle_states[slot].alive = alive;
    particle_states[slot].drained = (range.w & FLAG_DRAIN) != 0u && alive == 0u
        ? particle_emitters[slot].emitter_uid : uint2(0u);
    if (kind == PARTICLE_RENDER_MESH) {
        uint only_choice = 0u;
        if (alive == 1u && count > 1u) {
            only_choice = particle_mesh_choice(slot, particles[particle_drawn(slot, 0u)]);
        }
        for (uint c = 0u; c < count; c++) {
            uint words = PARTICLE_MESH_DRAWS_AT + (slot * PARTICLE_MESHES + c) * PARTICLE_MESH_DRAW_WORDS;
            particle_queue[words + 1u] = c == only_choice ? alive : 0u;
            particle_queue[words + 3u] = 0u;
        }
    } else {
        particle_states[slot].index_count = 6u;
        particle_states[slot].instance_count = ribbon ? 0u : alive;
        particle_states[slot].first_index = 0u;
        particle_states[slot].vertex_offset = 0;
        particle_states[slot].first_instance = 0u;
    }
    if (alive == 0u) return;
    InterlockedAdd(counted[0], alive);
    InterlockedAdd(counted[1], 1u);
    if (alive >= 2u && ((range.w & PARTICLE_FLAG_SORT) != 0u || ribbon || count > 1u)) {
        uint at;
        InterlockedAdd(particle_queue[SORT_AT / 4u], 1u, at);
        particle_queue[SORT_AT / 4u + 4u + at] = slot;
    }
}
