#include "native.slang"
// Advances the step's living particles and keeps survivors for the next step.
// After late births, mode 1 writes the frame’s draw records.
//! variant hw MIRAI_HW_RT=1
//! per vfx program
#define PARTICLES_WRITABLE
#define PARTICLE_SCENE_READ
#include "lighting.slang"
#include "particle_programs.slang"
#include "particle_work.slang"
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

void event_push(uint slot, uint trigger, float3 position, float3 velocity, uint color, uint seed, uint leader = 0u) {
    uint2 target = particle_emitters[slot].random.yz;
    if (target.x == 0u || particle_emitters[slot].kinds.w != trigger || target.y == 0u) return;
    uint at;
    InterlockedAdd(particle_queue[params.parity], 1u, at);
    if (at >= PARTICLE_EVENT_CAPACITY) return;
    Particle_Event ev;
    ev.position = position;
    ev.velocity = velocity;
    ev.target = (target.x - 1u) | (target.y << 16u) | leader;
    ev.color = color;
    ev.ribbon = particle_own_ribbon(seed);
    particle_event_store(params.parity, at, ev);
}

// Tells the game of a particle whose emitter's reports name what happened to
// it: an entry of the reports channel (vfx.REPORTS_CHANNEL), in the copy the
// frame writes.
void particle_report(uint slot, uint kind, float3 position, float3 velocity, float3 normal) {
    uint2 reports = uint2(particle_emitters[slot].program.z, particle_frame_reports());
    if (reports.x != kind || reports.y == INVALID) return;
    uint entry;
    particle_world_bytes.InterlockedAdd(reports.y, 1u, entry);
    if (entry >= PARTICLE_DATA_ENTRIES) return;
    uint at = reports.y + 16u + entry * REPORT_WORDS * 4u;
    particle_world_bytes.Store2(at, uint2(slot, kind));
    particle_world_bytes.Store3(at + 8u, asuint(position));
    particle_world_bytes.Store3(at + 20u, asuint(velocity));
    particle_world_bytes.Store3(at + 32u, asuint(normal));
    particle_world_bytes.Store2(at + 44u, particle_emitters[slot].emitter_uid);
}

void release(uint index, uint slot, uint2 range) {
    particles[index].lifetime = 0.0;
    uint at;
    InterlockedAdd(particle_states[slot].dead, 1u, at);
    if (at < range.y) particle_lists[range.x + at] = index - range.x;
}

// Speed into a surface (m/s) below which a particle stays on it instead of bouncing.
#define PARTICLE_REST_SPEED 0.5

// A particle that goes into a surface of normal n faster than the rest speed, or
// than twice what the acceleration a gives it in the step h, bounces (collide.x
// of its normal speed) and it is a hit: true. Slower, it stays on the surface
// without a hit. Both lose tangent speed by friction (collide.y) times the normal
// speed stopped (Coulomb): one at rest slows by friction times its weight each
// second, whatever the step.
bool respond(inout float3 velocity, float3 n, float3 a, float h, float2 collide) {
    float into = -dot(velocity, n);
    if (into <= 0.0) return false;
    bool hit = into > max(PARTICLE_REST_SPEED, 2.0 * max(-dot(a, n), 0.0) * h);
    float kept = hit ? into * collide.x : 0.0;
    float3 tangent = velocity + n * into;
    velocity = tangent * max(1.0 - collide.y * (into + kept) / max(length(tangent), 1e-6), 0.0) + n * kept;
    return hit;
}

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 group : SV_GroupID, uint3 local : SV_GroupThreadID) {
    particle_step_last = params.last != 0u;
    Particle_Work work = particle_work(group, local.x, params.emitter_first);
    if (work.slot == INVALID) return;
    uint slot = work.slot;
    if (work.item >= particle_states[slot].live_count[params.parity]) return;
    uint index = particle_lists[particle_alive_at(slot, params.parity) + work.item];
    Particle p = particles[index];
    uint4 range = particle_emitters[slot].range;
    uint2 program = particle_emitters[slot].program.xy;
    if (params.mode == 1u) {
        particle_draw_look_store(slot, index, particle_program_look(slot, index, p));
        particle_lists[program.y + range.x + work.item] = index;
        return;
    }
    if (!(p.lifetime > 0.0)) { release(index, slot, range.xy); return; }
    float4 clock = particle_frame_step();
    bool paused = (range.w & PARTICLE_FLAG_PAUSED) != 0u;
    float step = paused ? 0.0 : clock.y;
    // The seconds of the step it lived: one born in it, less.
    float h = max(step + min(p.age, 0.0), 0.0);
    float time = clock.w - clock.x + float(params.step + 1u) * clock.y;
    float drain_age = p.age + step;
    bool moved = (range.w & PARTICLE_FLAG_MOVED) != 0u;
    if (!moved) p.age += step;
    Mirai_Vfx_Particle v = particle_program_value(slot, p);
    if (h > 0.0) particle_program_update(slot, index, time, h, v);
    if ((range.w & FLAG_DRAIN) != 0u) v.age = max(v.age, drain_age);
    if (v.age >= v.lifetime) {
        event_push(slot, PARTICLE_EVENT_DEATH, v.position, v.velocity, p.color, v.seed);
        particle_report(slot, PARTICLE_EVENT_DEATH, v.position, v.velocity, float3(0.0));
        release(index, slot, range.xy);
        return;
    }
    // Its age before a hit takes life from it: what its trail counts.
    float lived = v.age;
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
        if (collision == PARTICLE_COLLISION_WORLD) {
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
        float4 collide = particle_emitters[slot].collide;
        if (hit && respond(velocity, normal, acceleration, h, collide.xy)) {
            v.age += collide.z * v.lifetime;
            event_push(slot, PARTICLE_EVENT_COLLISION, next, velocity, p.color, v.seed);
            particle_report(slot, PARTICLE_EVENT_COLLISION, next, velocity, normal);
        }
        v.rotation += v.spin * h;
        v.position = next;
        v.velocity = velocity;
    }
    particle_program_store(slot, v, program.x != 0u, p);
    if (particle_emitters[slot].kinds.y == PARTICLE_RENDER_MESH && particle_emitters[slot].mesh.y == PARTICLE_FACING_VELOCITY && length(v.velocity) > PARTICLE_MESH_FACING_SPEED) {
        p.flags = (p.flags & ((1u << RIBBON_SHIFT) - 1u)) | particle_heading_pack(normalize(v.velocity));
    }
    // A trail: an event each time its age passes a period, where it is now, and
    // at the end of the frame one whose point leads it to where its head is.
    if (h > 0.0 && floor(lived * float(TRAILS_PER_SECOND)) != floor((lived - h) * float(TRAILS_PER_SECOND))) event_push(slot, PARTICLE_EVENT_TRAIL, v.position, v.velocity, p.color, v.seed);
    else if (params.last != 0u) event_push(slot, PARTICLE_EVENT_TRAIL, v.position, v.velocity, p.color, v.seed, PARTICLE_EVENT_LEADER);
    if (params.last != 0u && (range.w & PARTICLE_FLAG_LIT) != 0u && ((p.flags & 1u) == 0u || ((index + frame.frame_index) & 1u) == 0u)) {
        float3 ambient_axis = float3(0.0, 1.0, 0.0);
        float4 clip = view_clip(v.position);
        bool near_view = clip.w > 0.0 && all(abs(clip.xy) <= 1.2 * clip.w)
            && view_depth(v.position) < min(frame.camera_forward.w, 100.0);
        float radius = v.size * 0.5;
        float3 light = float3(0.0);
        if (frame.sun_direction.w > 0.5) {
            float3 from = v.position + frame.sun_direction.xyz * (radius + 0.02);
            light += sun_light(v.position) * 0.8 * float(!near_view || trace_visible(from, frame.sun_direction.xyz, sun_reach(from, frame.sun_direction.xyz), false));
        }
        Shading around = shading_diffuse(v.position, float3(0.0), float3(1.0));
        light += local_lighting(around, 0.0) + shadowless_lighting(around, 0.0);
        light += indirect_irradiance(v.position, ambient_axis, ambient_axis, false);
        light = finite_or_zero(light);
        p.light = pack_rgbe(light);
        p.flags |= 1u;
    }
    particles[index] = p;
    particle_alive_append(slot, params.parity ^ 1u, index);
}
