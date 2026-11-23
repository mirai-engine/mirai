#include "native.slang"
// Starts clock births (0), queued events (1), channel births (2) and late events (4).
// Mode 3 prepares an emitter’s program and asks it for its births.
//! variant hw MIRAI_HW_RT=1
//! per vfx program
#define PARTICLES_WRITABLE
#define PARTICLE_SCENE_READ
#include "trace.slang"
#include "particle_programs.slang"
#include "particle_work.slang"
#define MIRAI_GROUP_X 64
#define MIRAI_GROUP_Y 1
#define MIRAI_GROUP_Z 1

struct Params_Block { uint mode; uint emitters; uint count; uint parity; uint step; uint last; uint pad0; uint pad1; uint program; uint first; uint emitter_first; uint fields; };
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);

float3 random_direction(inout uint seed) {
    float z = random01(seed) * 2.0 - 1.0;
    float a = random01(seed) * 2.0 * PI;
    float s = sqrt(max(1.0 - z * z, 0.0));
    return float3(s * cos(a), z, s * sin(a));
}

// A point of the shape and the direction a particle leaves it in, local to the emitter.
void shape_sample(uint slot, inout uint seed, out float3 position, out float3 direction) {
    float3 size = particle_emitters[slot].shape.xyz;
    float shell = particle_emitters[slot].spin.z;
    float reach = lerp(pow(random01(seed), 1.0 / 3.0), 1.0, shell);
    position = float3(0.0);
    direction = float3(0.0, 1.0, 0.0);
    switch (particle_emitters[slot].kinds.x) {
    case PARTICLE_SHAPE_POINT:
        direction = random_direction(seed);
        break;
    case PARTICLE_SHAPE_SPHERE:
    case PARTICLE_SHAPE_HEMISPHERE:
        direction = random_direction(seed);
        if (particle_emitters[slot].kinds.x == PARTICLE_SHAPE_HEMISPHERE) direction.y = abs(direction.y);
        position = direction * size.x * reach;
        break;
    case PARTICLE_SHAPE_CONE: {
        float a = random01(seed) * 2.0 * PI;
        float across = lerp(sqrt(random01(seed)), 1.0, shell);
        float2 radial = float2(cos(a), sin(a));
        position = float3(radial.x, 0.0, radial.y) * size.x * across;
        float tilt = particle_emitters[slot].shape.w * across;
        direction = float3(radial.x * sin(tilt), cos(tilt), radial.y * sin(tilt));
        break;
    }
    case PARTICLE_SHAPE_BOX: {
        float3 u = float3(random01(seed), random01(seed), random01(seed)) * 2.0 - 1.0;
        if (random01(seed) < shell) {
            uint axis = min(uint(random01(seed) * 3.0), 2u);
            u[axis] = u[axis] < 0.0 ? -1.0 : 1.0;
        }
        position = u * size;
        break;
    }
    case PARTICLE_SHAPE_CIRCLE: {
        float a = random01(seed) * 2.0 * PI;
        float across = lerp(sqrt(random01(seed)), 1.0, shell);
        direction = float3(cos(a), 0.0, sin(a));
        position = direction * size.x * across;
        break;
    }
    case PARTICLE_SHAPE_LINE:
        position = float3((random01(seed) * 2.0 - 1.0) * size.x, 0.0, 0.0);
        break;
    case PARTICLE_SHAPE_SURFACE:
        // An event of a surface starts its particles where it was, every way.
        direction = random_direction(seed);
        break;
    default:
        break;
    }
}

// A particle of the emitter at slot `slot`: where it starts in the world,
// with what velocity, how far into the step (age: the seconds the step does
// not move it, as a negative age) and how much of its life it already lived.
// False when its emitter has no free slot or it would be dead already.
bool particle_start(uint slot, uint seed, uint birth, float3 world_position, float3 world_velocity, float age, float lived, float time, float4 tint = float4(1.0), float scale = 1.0, float4 values = float4(0.0), uint ribbon = 0u, bool leader = false, bool drawn = false) {
    float lifetime = lerp(particle_emitters[slot].lifetime_speed.x, particle_emitters[slot].lifetime_speed.y, random01(seed));
    // A leader lives until the next step.
    if (leader) lifetime = min(lifetime, 1e-6);
    if (lived >= lifetime) return false;
    uint previous;
    InterlockedAdd(particle_states[slot].dead, 0xFFFFFFFFu, previous);
    if (previous == 0u || previous > particle_emitters[slot].range.y) {
        InterlockedAdd(particle_states[slot].dead, 1u);
        return false;
    }
    uint index = particle_emitters[slot].range.x + particle_lists[particle_emitters[slot].range.x + previous - 1u];
    Mirai_Vfx_Particle v;
    v.lifetime = lifetime;
    v.size = lerp(particle_emitters[slot].size_rotation.x, particle_emitters[slot].size_rotation.y, random01(seed)) * scale;
    v.rotation = lerp(particle_emitters[slot].size_rotation.z, particle_emitters[slot].size_rotation.w, random01(seed));
    v.spin = lerp(particle_emitters[slot].spin.x, particle_emitters[slot].spin.y, random01(seed));
    v.color = lerp(particle_emitters[slot].color_a, particle_emitters[slot].color_b, random01(seed)) * tint;
    v.seed = birth != INVALID ? particle_birth_seed(slot, birth) : hash_u32(seed);
    v.velocity = world_velocity;
    v.position = world_position;
    v.age = age + lived;
    v.ribbon = ribbon;
    v.mesh = particle_emitters[slot].kinds.y == PARTICLE_RENDER_MESH ? particle_mesh_pick(slot, random01(seed)) : 0u;
    if (lived > 0.0) {
        float3 acceleration = particle_emitters[slot].acceleration.xyz + particle_fields(slot, params.fields, v.position);
        v.position += v.velocity * lived + 0.5 * acceleration * lived * lived;
        v.velocity += acceleration * lived;
        v.rotation += v.spin * lived;
    }
    particle_program_initialize(slot, index, birth, time, values, v);
    Particle p;
    p.light = 0u;
    p.emitter = slot;
    p.flags = 0u;
    particle_program_store(slot, v, true, p);
    particles[index] = p;
    particle_alive_append(slot, drawn ? params.parity ^ 1u : params.parity, index);
    return true;
}

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 id : SV_DispatchThreadID, uint3 group : SV_GroupID, uint3 local : SV_GroupThreadID) {
    uint ordinal = id.x;
    uint emitter = 0u;
    if (params.mode == 0u || params.mode == 2u || params.mode == 3u) {
        Particle_Work work = particle_work(group, local.x, params.emitter_first);
        if (work.slot == INVALID) return;
        emitter = work.slot;
        ordinal = work.item;
    }
    float4 frame_step = particle_frame_step();
    if (params.mode == 3u) {
        if (ordinal != 0u) return;
        uint slot = emitter;
        if (slot >= params.emitters) return;

        if (particle_emitters[slot].program.x != params.program || (particle_emitters[slot].range.w & (PARTICLE_FLAG_BIRTHS | PARTICLE_FLAG_PREPARE)) == 0u) return;
        if ((particle_emitters[slot].range.w & PARTICLE_FLAG_ACTIVE) == 0u || (particle_emitters[slot].range.w & PARTICLE_FLAG_PAUSED) != 0u) return;
        float4 packed[16];
        particle_parameters(slot, packed);
        // A range that starts gives the births since the clock of its emitter started.
        float dt = (particle_emitters[slot].range.w & PARTICLE_FLAG_RESET) != 0u ? max(asfloat(particle_emitters[slot].data.z), frame_step.x) : frame_step.x;
        Mirai_Vfx_Context ctx = particle_program_context(slot, frame_step.w, dt);
        ctx.born = particle_states[slot].born;
        // What the program keeps of the frame first: its births may read it.
        if ((particle_emitters[slot].range.w & PARTICLE_FLAG_PREPARE) != 0u) mirai_vfx_prepare(particle_emitters[slot].program.x, packed, ctx);
        if ((particle_emitters[slot].range.w & PARTICLE_FLAG_BIRTHS) == 0u) return;
        float2 window = particle_birth_window(slot, frame_step.x);
        if (window.y <= 0.0 && particle_emitters[slot].birth_limit < FLT_MAX) return;
        ctx.delta_time = window.y;
        float ended = max(ctx.emitter_age - particle_emitters[slot].birth_limit, 0.0);
        ctx.emitter_age -= ended;
        ctx.time -= ended;
        uint count = min(mirai_vfx_births(particle_emitters[slot].program.x, packed, ctx), particle_emitters[slot].range.y);
        particle_states[slot].births = count;
        particle_states[slot].born += count;
        return;
    }
    if (params.mode == 0u) {
        uint slot = emitter;

        if (particle_emitters[slot].program.x != params.program) return;
        if ((particle_emitters[slot].range.w & (PARTICLE_FLAG_ACTIVE | FLAG_DRAIN)) != PARTICLE_FLAG_ACTIVE) return;
        uint birth;
        float age;
        if (!particle_spawn(slot, params.step, ordinal, birth, age)) return;
        float frame_dt = frame_step.x, h = frame_step.y;
        float born = frame_dt - age;
        bool local_space = (particle_emitters[slot].range.w & PARTICLE_FLAG_LOCAL) != 0u;
        float since_birth = local_space ? 0.0 : clamp(frame_dt - born, 0.0, frame_dt);
        uint seed = hash_u32(particle_emitters[slot].random.x * 9781u + birth * 26699u);
        float3 position, velocity;
        if (particle_emitters[slot].kinds.x == PARTICLE_SHAPE_SURFACE) {
            Mirai_Vfx_Surface s = particle_surface_sample(particle_resource(slot, 0u), seed, frame_dt);
            if (!s.valid) return;
            // The surface moved with its velocity since the birth.
            position = s.position - s.velocity * since_birth;
            float speed = lerp(particle_emitters[slot].lifetime_speed.z, particle_emitters[slot].lifetime_speed.w, random01(seed));
            float3 local_velocity = lerp(particle_emitters[slot].velocity_a.xyz, particle_emitters[slot].velocity_b.xyz, float3(random01(seed), random01(seed), random01(seed)));
            velocity = s.normal * speed + transform_vector(particle_emitters[slot].world, local_velocity) + s.velocity * particle_emitters[slot].spin.w;
        } else {
            float3 local, direction;
            shape_sample(slot, seed, local, direction);
            float t = frame_dt > 0.0 ? saturate(born / frame_dt) : 1.0;
            position = transform_point(particle_emitters[slot].world, local);
            if (!local_space) {
                position = lerp(transform_point(particle_emitters[slot].previous, local), position, t);
            }
            float speed = lerp(particle_emitters[slot].lifetime_speed.z, particle_emitters[slot].lifetime_speed.w, random01(seed));
            float3 local_velocity = lerp(particle_emitters[slot].velocity_a.xyz, particle_emitters[slot].velocity_b.xyz, float3(random01(seed), random01(seed), random01(seed)));
            velocity = particle_unit(transform_vector(particle_emitters[slot].world, direction), direction) * speed + transform_vector(particle_emitters[slot].world, local_velocity);
            float3 moved = (float3(particle_emitters[slot].world[0].w, particle_emitters[slot].world[1].w, particle_emitters[slot].world[2].w) - float3(particle_emitters[slot].previous[0].w, particle_emitters[slot].previous[1].w, particle_emitters[slot].previous[2].w)) / max(frame_dt, 1e-5);
            velocity += moved * particle_emitters[slot].spin.w;
        }
        // Born at `born` in the frame: the rest of its step moves it. Born before the frame, it lived the time before.
        float start = float(params.step) * h;
        particle_start(slot, seed, birth, position, velocity, born >= 0.0 ? start - born : 0.0, max(-born, 0.0), frame_step.w - age);
        return;
    }
    if (params.mode == 2u) {
        uint slot = emitter;

        if (particle_emitters[slot].program.x != params.program) return;
        uint2 channel = particle_channel_span(slot, params.step);
        if (ordinal >= channel.y) return;
        Particle_Birth b = particle_channel_item(slot, channel.x + ordinal);
        float frame_dt = frame_step.x, h = frame_step.y;
        float born = frame_dt - b.age;
        float start = float(params.step) * h;
        uint seed = hash_u32(particle_emitters[slot].random.x * 7919u + b.number * 104729u);
        for (uint k = 0u; k < b.count; k++) {
            float3 local, direction;
            shape_sample(slot, seed, local, direction);
            float speed = lerp(particle_emitters[slot].lifetime_speed.z, particle_emitters[slot].lifetime_speed.w, random01(seed));
            float3 local_velocity = lerp(particle_emitters[slot].velocity_a.xyz, particle_emitters[slot].velocity_b.xyz, float3(random01(seed), random01(seed), random01(seed)));
            float3 offset = transform_vector(particle_emitters[slot].world, local);
            float3 along = transform_vector(particle_emitters[slot].world, direction);
            float normal_scale = max(abs(b.normal.x), max(abs(b.normal.y), abs(b.normal.z)));
            if (particle_emitters[slot].kinds.x == PARTICLE_SHAPE_CONE && normal_scale > 0.0 && all(isfinite(b.normal))) {
                float3 up = normalize(b.normal / normal_scale);
                float3 side = normalize(cross(up, abs(up.z) < 0.99 ? float3(0, 0, 1) : float3(1, 0, 0)));
                float3 front = cross(side, up);
                along = direction.x * side + direction.y * up + direction.z * front;
                offset = local.x * side + local.y * up + local.z * front;
            }
            float3 velocity = particle_unit(along, direction) * speed + transform_vector(particle_emitters[slot].world, local_velocity) + b.velocity;
            if (!particle_start(slot, seed, INVALID, b.position + offset, velocity, born >= 0.0 ? start - born : 0.0, max(-born, 0.0), frame_step.w - b.age, b.color, b.size, b.values)) break;
        }
        return;
    }
    // Mode 1 takes the events of the step before; mode 4, after the last step, those of it.
    bool late = params.mode == 4u;
    uint half_read = late ? params.parity : 1u - params.parity;
    if (id.x >= min(particle_queue[half_read], PARTICLE_EVENT_CAPACITY)) return;
    Particle_Event ev = particle_event_load(half_read, id.x);
    uint slot = ev.target & 0xFFFFu;
    uint count = (ev.target >> 16u) & 0x7FFFu;
    bool leader = (ev.target & PARTICLE_EVENT_LEADER) != 0u;
    if (slot >= params.emitters) return;

    if (particle_emitters[slot].program.x != params.program) return;
    if ((particle_emitters[slot].range.w & (PARTICLE_FLAG_ACTIVE | FLAG_DRAIN)) != PARTICLE_FLAG_ACTIVE) return;
    // The frame too: the events of one step are numbered from 0 in every frame.
    uint seed = hash_u32(particle_emitters[slot].random.x * 7907u + (params.step + (late ? 1u : 0u)) * 3203u + id.x * 104729u + ev.color + frame.frame_index * 2654435761u);
    for (uint k = 0u; k < count; k++) {
        float3 local, direction;
        shape_sample(slot, seed, local, direction);
        float3 offset = transform_vector(particle_emitters[slot].world, local);
        float speed = lerp(particle_emitters[slot].lifetime_speed.z, particle_emitters[slot].lifetime_speed.w, random01(seed));
        float3 local_velocity = lerp(particle_emitters[slot].velocity_a.xyz, particle_emitters[slot].velocity_b.xyz, float3(random01(seed), random01(seed), random01(seed)));
        float3 velocity = particle_unit(transform_vector(particle_emitters[slot].world, direction), direction) * speed + transform_vector(particle_emitters[slot].world, local_velocity);
        if (!particle_start(slot, seed, INVALID, ev.position + offset, velocity + ev.velocity * particle_emitters[slot].spin.w, 0.0, 0.0, late ? frame_step.w : frame_step.w - frame_step.x + float(params.step) * frame_step.y, float4(1.0), 1.0, float4(0.0), ev.ribbon, leader, late)) break;
    }
}
