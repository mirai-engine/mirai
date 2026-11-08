#include "native.slang"
// A thread per slot of the pool the emitters of the program of the pass hold
// (from params.first), each step. A living particle ages,
// its program updates it and the forces of its effect move it (a program
// that moves its particles ages and moves them alone): acceleration, the
// gravity and the wind of where it is, curl noise, an attractor and drag,
// then collision against the depth of the frame or the traced scene. It
// dies into the free list of its emitter, with an event for the emitter that
// follows it. In the last step of the frame it goes on the list that is
// drawn, and a lit one keeps the light it receives: the sun with its shadow
// ray, the local lights and the probe volume, renewed for half of the
// particles each frame. A paused emitter keeps its particles as they are.
//! variant hw MIRAI_HW_RT=1
//! per vfx program
#define PARTICLES_WRITABLE
#define PARTICLE_SCENE_READ
#include "lighting.slang"
#include "particle_programs.slang"
#include <extension_hooks.slang>
#define MIRAI_GROUP_X 64
#define MIRAI_GROUP_Y 1
#define MIRAI_GROUP_Z 1

struct Params_Block { uint mode; uint emitters; uint count; uint parity; uint step; uint last; uint pad0; uint pad1; uint program; uint first; uint emitter_first; uint fields; };
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);

float lattice(int3 i) {
    uint h = hash_u32(uint(i.x) * 73856093u ^ uint(i.y) * 19349663u ^ uint(i.z) * 83492791u);
    return float(h >> 8) * (2.0 / 16777216.0) - 1.0;
}

// Value noise and its gradient (Quilez) at base + x, base a lattice point: x value, yzw
// derivatives.
float4 noise_gradient(int3 base, float3 x) {
    int3 i = base + int3(floor(x));
    float3 w = frac(x);
    float3 u = w * w * w * (w * (w * 6.0 - 15.0) + 10.0);
    float3 du = 30.0 * w * w * (w * (w - 2.0) + 1.0);
    float a = lattice(i), b = lattice(i + int3(1, 0, 0)), c = lattice(i + int3(0, 1, 0)), d = lattice(i + int3(1, 1, 0));
    float e = lattice(i + int3(0, 0, 1)), f = lattice(i + int3(1, 0, 1)), g = lattice(i + int3(0, 1, 1)), h = lattice(i + int3(1, 1, 1));
    float k1 = b - a, k2 = c - a, k3 = e - a, k4 = a - b - c + d, k5 = a - c - e + g, k6 = a - b - e + f, k7 = -a + b + c - d + e - f - g + h;
    float value = a + k1 * u.x + k2 * u.y + k3 * u.z + k4 * u.x * u.y + k5 * u.y * u.z + k6 * u.z * u.x + k7 * u.x * u.y * u.z;
    float3 gradient = du * float3(k1 + k4 * u.y + k6 * u.z + k7 * u.y * u.z, k2 + k5 * u.z + k4 * u.x + k7 * u.z * u.x, k3 + k6 * u.x + k5 * u.y + k7 * u.x * u.y);
    return float4(value, gradient);
}

// A flow without sources or sinks: the curl of three noise fields, at base + p.
float3 curl_noise(int3 base, float3 p) {
    float3 x = noise_gradient(base, p).yzw;
    float3 y = noise_gradient(base, p + float3(31.416, -47.853, 12.679)).yzw;
    float3 z = noise_gradient(base, p + float3(-233.145, 113.29, 71.27)).yzw;
    return float3(z.y - y.z, x.z - z.x, y.x - x.y);
}

void event_push(uint slot, uint trigger, float3 position, float3 velocity, uint color) {
    uint2 target = particle_emitters[slot].random.yz;
    if (target.x == 0u || particle_emitters[slot].kinds.w != trigger || target.y == 0u) return;
    uint at;
    InterlockedAdd(particle_queue[params.parity], 1u, at);
    if (at >= PARTICLE_EVENT_CAPACITY) return;
    Particle_Event ev;
    ev.position = position;
    ev.velocity = velocity;
    ev.target = (target.x - 1u) | (target.y << 16u);
    ev.color = color;
    particle_event_store(params.parity, at, ev);
}

void release(uint index, uint slot, uint2 range) {
    particles[index].lifetime = 0.0;
    uint at;
    InterlockedAdd(particle_states[slot].dead, 1u, at);
    if (at < range.y) particle_lists[range.x + at] = index - range.x;
}

// Bounces off a surface of normal n the particle went into.
void bounce(inout float3 velocity, float3 n, float2 collide) {
    float into = dot(velocity, n);
    if (into >= 0.0) return;
    float3 normal = n * into;
    velocity = (velocity - normal) * (1.0 - collide.y) - normal * collide.x;
}

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 id : SV_DispatchThreadID) {
    particle_step_last = params.last != 0u;
    uint index = params.first + id.x;
    if (index >= params.count) return;
    Particle p = particles[index];
    if (p.lifetime <= 0.0) return;
    uint slot = particle_emitter_of(p);
    if (slot >= params.emitters) { particles[index].lifetime = 0.0; return; }
    // Only the fields of its emitter it reads, from the row: a copy of the whole row costs each thread.
    uint2 program = particle_emitters[slot].program.xy;
    // The emitters of another program run on its pipeline.
    if (program.x != params.program) return;
    uint4 range = particle_emitters[slot].range;
    // A slot of a range that went, or that another emitter took since.
    if ((range.w & PARTICLE_FLAG_ACTIVE) == 0u || index < range.x || index >= range.x + range.y) { particles[index].lifetime = 0.0; return; }
    float4 clock = particle_emitters[slot].step;
    bool paused = (range.w & PARTICLE_FLAG_PAUSED) != 0u;
    float step = paused ? 0.0 : clock.y;
    // The seconds of the step it lived: one born in it, less.
    float h = max(step + min(p.age, 0.0), 0.0);
    float time = clock.w - clock.x + float(params.step + 1u) * clock.y;
    bool moved = (range.w & PARTICLE_FLAG_MOVED) != 0u;
    if (!moved) p.age += step;
    Mirai_Vfx_Particle v = particle_program_value(slot, p);
    if (h > 0.0) particle_program_update(slot, index, time, h, v);
    if (v.age >= v.lifetime) {
        event_push(slot, PARTICLE_EVENT_DEATH, v.position, v.velocity, p.color);
        particle_report(slot, PARTICLE_EVENT_DEATH, v.position, v.velocity, float3(0.0));
        release(index, slot, range.xy);
        return;
    }
    if (h > 0.0 && !moved) {
        float4 drag = particle_emitters[slot].acceleration;
        float3 acceleration = drag.xyz + particle_fields(slot, params.fields, v.position);
        float4 noise = particle_emitters[slot].noise;
        if (noise.x != 0.0) {
            // On the lattice of the world: where the origin is on it.
            int3 whole;
            float3 part;
            origin_lattice(particle_origin(slot), float3(noise.y), whole, part);
            acceleration += curl_noise(whole, part + v.position * noise.y + float3(0.0, time * noise.z, 0.0)) * noise.x;
        }
        float4 attractor = particle_emitters[slot].attractor;
        if (attractor.w != 0.0) {
            float3 toward = transform_point(particle_emitters[slot].world, attractor.xyz) - v.position;
            float distance = length(toward);
            if (distance > 1e-4) acceleration += toward / distance * attractor.w * min(distance, 1.0);
        }
        float3 velocity = (v.velocity + acceleration * h) / (1.0 + drag.w * h);
        float3 next = v.position + velocity * h;
        float radius = v.size * 0.5;
        bool hit = false;
        float3 normal = float3(0.0, 1.0, 0.0);
        uint collision = particle_emitters[slot].kinds.z;
        if (collision == PARTICLE_COLLISION_SCREEN) {
            float4 clip = view_clip_unjittered(next);
            if (clip.w > 0.0 && view_depth(next) > frame.camera_position.w) {
                float2 uv = clip.xy / clip.w * float2(0.5, -0.5) + 0.5;
                if (all(uv > float2(0.0)) && all(uv < float2(1.0))) {
                    int2 pixel = int2(uv * frame.resolution);
                    float surface = g_depth.Load(int3(pixel, 0)).r;
                    float depth = dot(next - frame.camera_position.xyz, frame.camera_forward.xyz);
                    float thickness = max(0.25, length(velocity) * h * 2.0) + radius;
                    // The pixels of a nested view show another place: nothing there to collide with.
                    if (surface > 0.0 && depth + radius > surface && depth - radius < surface + thickness) {
                        normal = normalize(gbuffer_normal(pixel));
                        if (dot(velocity, normal) < 0.0) {
                            hit = true;
                            next = position_from_depth(uv, surface) + normal * radius;
                        }
                    }
                }
            }
        } else if (collision == PARTICLE_COLLISION_WORLD) {
            float3 travel = next - v.position;
            float distance = length(travel);
            if (distance > 1e-5) {
                float3 direction = travel / distance;
                Hit found = trace_ray_impl(v.position, direction, 0.0, distance + radius, false, BLEND_PASSES, RAY_OPAQUE);
                if (found.instance != INVALID) {
                    bool blended;
                    normal = hit_normal(found.instance, found.primitive, found.bary, direction, blended);
                    hit = true;
                    // Out of the plane of the triangle along its normal: what it travels along the surface stays.
                    float3 at = v.position + direction * found.t;
                    next += normal * max(radius + 1e-3 - dot(next - at, normal), 0.0);
                }
            }
        }
        if (hit) {
            float4 collide = particle_emitters[slot].collide;
            bounce(velocity, normal, collide.xy);
            v.age += collide.z * v.lifetime;
            event_push(slot, PARTICLE_EVENT_COLLISION, next, velocity, p.color);
            particle_report(slot, PARTICLE_EVENT_COLLISION, next, velocity, normal);
        }
        v.rotation += v.spin * h;
        v.position = next;
        v.velocity = velocity;
    }
    particle_program_store(slot, v, program.x != 0u, p);
    if (params.last != 0u && (range.w & PARTICLE_FLAG_LIT) != 0u && ((p.flags & 1u) == 0u || ((index + frame.frame_index) & 1u) == 0u)) {
        float3 view = to_eye(v.position);
        float radius = v.size * 0.5;
        float3 light = float3(0.0);
        if (frame.sun_direction.w > 0.5) {
            float wrap = 0.5 + 0.5 * dot(view, frame.sun_direction.xyz);
            float3 from = v.position + frame.sun_direction.xyz * (radius + 0.02);
            light += sun_light(v.position) * lerp(0.6, 1.0, wrap) * trace_transmission(from, frame.sun_direction.xyz, sun_reach(from, frame.sun_direction.xyz), false);
        }
        Shading around = shading_diffuse(v.position, float3(0.0), float3(1.0));
        light += local_lighting(around, 0.0) + shadowless_lighting(around, 0.0);
        light += indirect_irradiance(v.position, view, view, false);
        light = finite_or_zero(light);
        p.light = pack_rgbe(light);
        p.flags |= 1u;
    }
    particles[index] = p;
    if (params.last == 0u) return;
    uint at;
    InterlockedAdd(particle_states[slot].alive, 1u, at);
    if (at < range.y) particle_lists[program.y + range.x + at] = index;
}
