#include "native.slang"
// Starts particles, over the emitters of the program of the pass from
// params.emitter_first. Mode 0: a thread per birth of each emitter in the frame
// (y), which starts it if it falls in this step: where the emitter was then,
// as old as the step has left it, or on its surface where the surface was
// then. A birth before the frame starts as far in its life as it got (a
// prewarm). Mode 1: a thread per event of the step before, which starts the
// particles it asks for in its target emitter, in the ribbon it names. A particle takes a free slot
// of its emitter; one that finds none is not started. The program of the
// emitter starts it after its effect. Mode 2: a thread per birth a game gave
// the channel of each emitter (y), which starts its particles if it falls in
// this step, where the birth is, with its velocity, color, size and values
// over those of the effect. Mode 3, in the first step: a thread per emitter
// whose program prepares what it keeps of the frame or gives its births:
// prepare, then how many it starts this frame; mode 0 then starts them
// spread over the frame.
//! variant hw MIRAI_HW_RT=1
//! per vfx program
#define PARTICLES_WRITABLE
#define PARTICLE_SCENE_READ
#include "trace.slang"
#include "particle_programs.slang"
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
void shape_sample(Particle_Emitter e, inout uint seed, out float3 position, out float3 direction) {
    float3 size = e.shape.xyz;
    float shell = e.spin.z;
    float reach = lerp(pow(random01(seed), 1.0 / 3.0), 1.0, shell);
    position = float3(0.0);
    direction = float3(0.0, 1.0, 0.0);
    switch (e.kinds.x) {
    case PARTICLE_SHAPE_POINT:
        direction = random_direction(seed);
        break;
    case PARTICLE_SHAPE_SPHERE:
    case PARTICLE_SHAPE_HEMISPHERE:
        direction = random_direction(seed);
        if (e.kinds.x == PARTICLE_SHAPE_HEMISPHERE) direction.y = abs(direction.y);
        position = direction * size.x * reach;
        break;
    case PARTICLE_SHAPE_CONE: {
        float a = random01(seed) * 2.0 * PI;
        float across = lerp(sqrt(random01(seed)), 1.0, shell);
        float2 radial = float2(cos(a), sin(a));
        position = float3(radial.x, 0.0, radial.y) * size.x * across;
        float tilt = e.shape.w * across;
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
    case PARTICLE_SHAPE_BONES:
        // An event of a surface or of bones starts its particles where it was, every way.
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
bool particle_start(uint slot, Particle_Emitter e, uint seed, uint birth, float3 world_position, float3 world_velocity, float age, float lived, float time, float4 tint = float4(1.0), float scale = 1.0, float4 values = float4(0.0), uint ribbon = 0u) {
    float lifetime = lerp(e.lifetime_speed.x, e.lifetime_speed.y, random01(seed));
    if (lived >= lifetime) return false;
    uint previous;
    InterlockedAdd(particle_states[slot].dead, 0xFFFFFFFFu, previous);
    if (previous == 0u || previous > e.range.y) {
        InterlockedAdd(particle_states[slot].dead, 1u);
        return false;
    }
    uint index = e.range.x + particle_lists[e.range.x + previous - 1u];
    Mirai_Vfx_Particle v;
    v.lifetime = lifetime;
    v.size = lerp(e.size_rotation.x, e.size_rotation.y, random01(seed)) * scale;
    v.rotation = lerp(e.size_rotation.z, e.size_rotation.w, random01(seed));
    v.spin = lerp(e.spin.x, e.spin.y, random01(seed));
    v.color = lerp(e.color_a, e.color_b, random01(seed)) * tint;
    v.seed = birth != INVALID ? particle_birth_seed(slot, birth) : hash_u32(seed);
    v.velocity = world_velocity;
    v.position = world_position;
    v.age = age + lived;
    v.ribbon = ribbon;
    if (lived > 0.0) {
        float3 acceleration = e.acceleration.xyz + particle_fields(slot, params.fields, v.position);
        v.position += v.velocity * lived + 0.5 * acceleration * lived * lived;
        v.velocity += acceleration * lived;
        v.rotation += v.spin * lived;
    }
    if (birth != INVALID) particle_lists[particle_birth_entry(slot, birth)] = index - e.range.x;
    particle_program_initialize(slot, index, birth, time, values, v);
    Particle p;
    p.light = 0u;
    p.emitter = slot;
    p.flags = 0u;
    particle_program_store(slot, v, true, p);
    particles[index] = p;
    return true;
}

// The birth of an emitter that thread `ordinal` starts: its seed and how old
// it is at the end of the frame.
void particle_birth(Particle_Emitter e, uint ordinal, out uint birth, out float age) {
    uint within = ordinal;
    birth = 0u;
    age = 0.0;
    for (uint g = 0u; g < e.random.w; g++) {
        uint4 group = e.spawns[g];
        if (within >= group.x) { within -= group.x; continue; }
        birth = group.z + within;
        age = asfloat(group.w) - float(within / max(group.y, 1u)) * e.spacing[g / 4u][g % 4u];
        return;
    }
}

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 id : SV_DispatchThreadID) {
    if (params.mode == 3u) {
        uint slot = params.emitter_first + id.x;
        if (slot >= params.emitters) return;
        Particle_Emitter e = particle_emitters[slot];
        if (e.program.x != params.program || (e.range.w & (PARTICLE_FLAG_BIRTHS | PARTICLE_FLAG_PREPARE)) == 0u) return;
        if ((e.range.w & PARTICLE_FLAG_ACTIVE) == 0u || (e.range.w & PARTICLE_FLAG_PAUSED) != 0u) return;
        float4 packed[16];
        particle_parameters(slot, packed);
        // A range that starts gives the births since the clock of its emitter started.
        float dt = (e.range.w & PARTICLE_FLAG_RESET) != 0u ? max(asfloat(e.data.z), e.step.x) : e.step.x;
        Mirai_Vfx_Context ctx = particle_program_context(slot, e.step.w, dt);
        ctx.born = particle_states[slot].born;
        // What the program keeps of the frame first: its births may read it.
        if ((e.range.w & PARTICLE_FLAG_PREPARE) != 0u) mirai_vfx_prepare(e.program.x, packed, ctx);
        if ((e.range.w & PARTICLE_FLAG_BIRTHS) == 0u) return;
        uint count = min(mirai_vfx_births(e.program.x, packed, ctx), e.range.y);
        particle_states[slot].births = count;
        particle_states[slot].born += count;
        return;
    }
    if (params.mode == 0u) {
        uint slot = params.emitter_first + id.y;
        Particle_Emitter e = particle_emitters[slot];
        if (e.program.x != params.program) return;
        if ((e.range.w & PARTICLE_FLAG_ACTIVE) == 0u) return;
        uint birth;
        float age;
        if ((e.range.w & PARTICLE_FLAG_BIRTHS) != 0u) {
            // Those its program gave, spread over the frame.
            uint count = particle_states[slot].births;
            if (id.x >= count) return;
            birth = particle_states[slot].born - count + id.x;
            age = e.step.x * (1.0 - (float(id.x) + 0.5) / float(count));
        } else {
            if (id.x >= e.range.z) return;
            particle_birth(e, id.x, birth, age);
        }
        // When in the frame it is born, and the step that starts it.
        float frame_dt = e.step.x, h = e.step.y;
        float born = frame_dt - age;
        uint step = born <= 0.0 ? 0u : min(uint(born / max(h, 1e-6)), uint(e.step.z) - 1u);
        if (step != params.step) return;
        uint seed = hash_u32(e.random.x * 9781u + birth * 26699u);
        float3 position, velocity;
        if (e.kinds.x == PARTICLE_SHAPE_SURFACE) {
            Mirai_Vfx_Surface s = particle_surface_sample(particle_resource(slot, 0u), seed, frame_dt);
            if (!s.valid) return;
            // The surface moved with its velocity since the birth.
            position = s.position - s.velocity * clamp(frame_dt - born, 0.0, frame_dt);
            float speed = lerp(e.lifetime_speed.z, e.lifetime_speed.w, random01(seed));
            float3 local_velocity = lerp(e.velocity_a.xyz, e.velocity_b.xyz, float3(random01(seed), random01(seed), random01(seed)));
            velocity = s.normal * speed + transform_vector(e.world, local_velocity) + s.velocity * e.spin.w;
        } else if (e.kinds.x == PARTICLE_SHAPE_BONES) {
            Particle_Bone b = particle_bone_sample(particle_resource(slot, 0u), seed, frame_dt);
            if (!b.valid) return;
            // Away from the bone, across it, by up to the radius of the shape.
            float3 side = cross(b.axis, abs(b.axis.y) < 0.99 ? float3(0.0, 1.0, 0.0) : float3(1.0, 0.0, 0.0));
            side = normalize(side);
            float3 other = cross(b.axis, side);
            float a = random01(seed) * 2.0 * PI;
            float3 away = side * cos(a) + other * sin(a);
            float reach = lerp(sqrt(random01(seed)), 1.0, e.spin.z);
            position = b.position + away * e.shape.x * reach - b.velocity * clamp(frame_dt - born, 0.0, frame_dt);
            float speed = lerp(e.lifetime_speed.z, e.lifetime_speed.w, random01(seed));
            float3 local_velocity = lerp(e.velocity_a.xyz, e.velocity_b.xyz, float3(random01(seed), random01(seed), random01(seed)));
            velocity = away * speed + transform_vector(e.world, local_velocity) + b.velocity * e.spin.w;
        } else {
            float3 local, direction;
            shape_sample(e, seed, local, direction);
            float t = frame_dt > 0.0 ? saturate(born / frame_dt) : 1.0;
            position = lerp(transform_point(e.previous, local), transform_point(e.world, local), t);
            float speed = lerp(e.lifetime_speed.z, e.lifetime_speed.w, random01(seed));
            float3 local_velocity = lerp(e.velocity_a.xyz, e.velocity_b.xyz, float3(random01(seed), random01(seed), random01(seed)));
            velocity = normalize(transform_vector(e.world, direction)) * speed + transform_vector(e.world, local_velocity);
            float3 moved = (float3(e.world[0].w, e.world[1].w, e.world[2].w) - float3(e.previous[0].w, e.previous[1].w, e.previous[2].w)) / max(frame_dt, 1e-5);
            velocity += moved * e.spin.w;
        }
        // Born at `born` in the frame: the rest of its step moves it. Born before the frame, it lived the time before.
        float start = float(step) * h;
        particle_start(slot, e, seed, birth, position, velocity, born >= 0.0 ? start - born : 0.0, max(-born, 0.0), e.step.w - age);
        return;
    }
    if (params.mode == 2u) {
        uint slot = params.emitter_first + id.y;
        Particle_Emitter e = particle_emitters[slot];
        if (e.program.x != params.program) return;
        if ((e.range.w & PARTICLE_FLAG_ACTIVE) == 0u || id.x >= e.frame.z) return;
        Particle_Birth b = particle_birth_at(e.frame.y + id.x * PARTICLE_BIRTH_BYTES);
        float frame_dt = e.step.x, h = e.step.y;
        float born = frame_dt - b.age;
        uint step = born <= 0.0 ? 0u : min(uint(born / max(h, 1e-6)), uint(e.step.z) - 1u);
        if (step != params.step) return;
        float start = float(step) * h;
        uint seed = hash_u32(e.random.x * 7919u + b.number * 104729u);
        for (uint k = 0u; k < b.count; k++) {
            float3 local, direction;
            shape_sample(e, seed, local, direction);
            float speed = lerp(e.lifetime_speed.z, e.lifetime_speed.w, random01(seed));
            float3 local_velocity = lerp(e.velocity_a.xyz, e.velocity_b.xyz, float3(random01(seed), random01(seed), random01(seed)));
            float3 velocity = normalize(transform_vector(e.world, direction)) * speed + transform_vector(e.world, local_velocity) + b.velocity;
            if (!particle_start(slot, e, seed, INVALID, b.position + transform_vector(e.world, local), velocity, born >= 0.0 ? start - born : 0.0, max(-born, 0.0), e.step.w - b.age, b.color, b.size, b.values)) break;
        }
        return;
    }
    uint half_read = 1u - params.parity;
    if (id.x >= min(particle_queue[half_read], PARTICLE_EVENT_CAPACITY)) return;
    Particle_Event ev = particle_event_load(half_read, id.x);
    uint slot = ev.target & 0xFFFFu;
    uint count = ev.target >> 16u;
    if (slot >= params.emitters) return;
    Particle_Emitter e = particle_emitters[slot];
    if (e.program.x != params.program) return;
    if ((e.range.w & PARTICLE_FLAG_ACTIVE) == 0u) return;
    uint seed = hash_u32(e.random.x * 7907u + params.step * 3203u + id.x * 104729u + ev.color);
    for (uint k = 0u; k < count; k++) {
        float3 local, direction;
        shape_sample(e, seed, local, direction);
        float3 offset = transform_vector(e.world, local);
        float speed = lerp(e.lifetime_speed.z, e.lifetime_speed.w, random01(seed));
        float3 local_velocity = lerp(e.velocity_a.xyz, e.velocity_b.xyz, float3(random01(seed), random01(seed), random01(seed)));
        float3 velocity = normalize(transform_vector(e.world, direction)) * speed + transform_vector(e.world, local_velocity);
        if (!particle_start(slot, e, seed, INVALID, ev.position + offset, velocity + ev.velocity * e.spin.w, 0.0, 0.0, e.step.w - e.step.x + float(params.step) * e.step.y, float4(1.0), 1.0, float4(0.0), ev.ribbon)) break;
    }
}
