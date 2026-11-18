#include "native.slang"
//! variant hw MIRAI_HW_RT=1
// The rays of the probes chosen this frame (ddgi_select.comp): each probe
// traces the spherical Fibonacci set turned by the rotation of its cell, the
// same every update. Hits take their direct light, each light by the share
// of it the probes gather, and read the bounces of the volume itself, as
// DDGI: nothing they read goes away while the scene stays still; a backface
// marks the probe as seeing the inside of geometry with a negative distance.
// The radiance of a ray is stored encoded (probe_light_encode).
//
// A probe that holds a slot keeps what each ray found (probe_hits.slang): a ray
// is traced only where its probe keeps nothing of it or what it may meet changed, and its hit
// takes its light only then or where its lights changed. The others read the
// bounces around what is kept, which is what an update that traces gives too:
// it reads back what it keeps.
// A hit on a material with a program waits for it (points.slang) and is
// completed by the resume (params.resume) from what the program gave there.
#define MIRAI_DIFFUSE_HITS
// Small instances are not in the light this pass gathers (render.INSTANCE_FLAG_SMALL).
#define MIRAI_TRACE_NO_SMALL
// It reports the levels it samples of each texture (texture_feedback in scene.slang).
#define MIRAI_TEXTURE_FEEDBACK
#define POINTS_SLOT SLOT_POINTS
#define CHOSEN_WRITABLE
#define PROBE_HITS_SLOT SLOT_PASS1
#define PROBE_CHANGES_SLOT SLOT_PASS3
#include "lighting.slang"
#include "probe_hits.slang"
#include <extension_hooks.slang>
#define MIRAI_GROUP_X 32
#define MIRAI_GROUP_Y 1
#define MIRAI_GROUP_Z 1

[[vk::binding(SLOT_PASS0, 0)]] [[vk::image_format("rgba16f")]] RWTexture2D<float4> ray_data : register(MIRAI_REGISTER(u, SLOT_PASS0), space0);

#ifdef MIRAI_HOOK_LIGHTS
// Whether a light of an extension reaches a hit: nothing says when one changes.
bool extension_lights_reach(float3 position, float3 normal, float t) {
    float3 from = offset_origin(position, normal, hit_bias(t));
    for (uint i = 0u; i < mirai_extension_light_count(); i++) {
        Extension_Light reaching;
        if (mirai_extension_light(i, from, normal, float2(-1.0, 0.0), reaching)) return true;
    }
    return false;
}
#endif

// Whether a ray along `arrived` met the inside of something: the back of a
// surface. A two-sided sheet that lets light through (a leaf) has no inside:
// from behind it is a surface like any other, as its light comes through it.
bool hit_inside(Material m, float3 geometric_normal, float3 arrived) {
    bool sheet = m.two_sided != 0u && (m.layers & MATERIAL_LAYER_DIFFUSE_TRANSMISSION) != 0u;
    return !sheet && dot(geometric_normal, arrived) > 0.0;
}

// Adds the lanes of the wave that count to a word of the list of the chosen, once a wave.
void count(uint word, bool counts) {
    uint lanes = WaveActiveCountBits(counts);
    if (lanes != 0u && WaveIsFirstLane()) InterlockedAdd(chosen[word], lanes);
}

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 dispatch_id : SV_DispatchThreadID, uint3 group : SV_GroupID, uint local : SV_GroupIndex) {
    bool resume = params.resume != 0u;
    uint ray = dispatch_id.x;
    uint slot = dispatch_id.y;
    Point_Head head = (Point_Head)0;
    bool active = resume ? head_of_round(group.x * MIRAI_GROUP_X + local, head) : ray < params.rays_per_probe && slot < chosen[0];
    if (resume && active) {
        ray = head.owner % params.rays_per_probe;
        slot = head.owner / params.rays_per_probe;
    }
    uint probe = active ? chosen[1u + slot] : 0u;
    float3 origin = float3(0.0), direction = float3(0.0, 1.0, 0.0);
    Probe_Kept kept = (Probe_Kept)0;
    if (active) {
        kept = probe_kept(probe);
        origin = probe_world_position(probe);
        direction = probe_ray_direction(probe, ray, params.rays_per_probe);
    }
    uint at = kept.slot != INVALID ? probe_hit_at(kept.slot, ray) : INVALID;

    // What is kept of the ray, and what the changes since ask of it.
    Probe_Hit hit = (Probe_Hit)0;
    bool trace = active && !resume;
    bool light = false;
    bool reached = false; // by a light of an extension
    uint traced = CHOSEN_TRACED;
    if (trace && kept.stands) {
        hit = probe_hit_load(at);
        uint kind = hit.flags & HIT_KIND;
        uint asked = probe_hit_asked(hit, origin, direction, kept.checked);
        if ((asked & HIT_ASKS_TRACE) != 0u) traced |= CHOSEN_CROSSED;
        light = kind == HIT_SURFACE && (kept.unlit || (asked & HIT_ASKS_LIGHT) != 0u);
        trace = kind == HIT_NONE || (hit.flags & HIT_PASSING) != 0u || (asked & HIT_ASKS_TRACE) != 0u;
#ifdef MIRAI_HOOK_RAY
        // A gate of an extension may have come on its way: nothing says so.
        float gate_at;
        if (!trace) trace = ray_gated(origin, direction, kind == HIT_SKY ? params.max_distance : hit.t, gate_at);
#endif
#ifdef MIRAI_HOOK_LIGHTS
        // Nor when a light of an extension changes: a hit one reaches takes its light every update.
        if (!trace && kind == HIT_SURFACE) {
            reached = extension_lights_reach(origin + direction * hit.t, hit.normal, hit.t);
            light = light || reached;
        }
#endif
        if (light && (hit.flags & HIT_FIXED) != 0u) trace = true;
        if (trace) light = false;
    }
    count(chosen_rays(), trace);
    if (trace) InterlockedOr(chosen[chosen_traced(slot)], traced);

    // The surface a traced ray met, or the one a program gave the resume.
    Surface s = (Surface)0;
    Material material = (Material)0;
    bool surface = false;
    bool passing = false;
    uint instance = INVALID;
    float3 arrived = direction;
    float gate = -1.0;
    float t = 0.0;
    if (resume && active) {
        Material_Point point = point_load(head.point);
        Hit_Point met = hit_point(point.instance, point.primitive, point.bary, point.footprint);
        s = surface_from_hit(met, point_record_given(head.point), point_record_load(head.point));
        material = met.m;
        surface = true;
        instance = point.instance;
        arrived = unpack_normal(head.aux[0]);
        t = asfloat(head.aux[1]);
        gate = asfloat(head.aux[2]);
    } else if (trace) {
        Ray_Path path;
        Hit found = trace_ray(origin, direction, 0.0, params.max_distance, false, path);
        // What a ray finds beyond a gate of an extension lights the probe, and for
        // its visibility is as far as the gate: what is behind it is another place.
        gate = path.gate;
        arrived = path.direction;
        hit = (Probe_Hit)0;
        if (found.instance == INVALID) {
            hit.flags = HIT_SKY;
        } else {
            // Each ray stands for an equal share of the sphere around the probe.
            float spread = 2.0 * sqrt(4.0 / float(params.rays_per_probe));
            Hit_Point met = hit_point(found.instance, found.primitive, found.bary, found.t * spread);
            t = found.t;
            instance = found.instance;
            if (met.m.program_id != 0u && !hit_inside(met.m, met.geometric_normal, arrived)) {
                Material_Point point = {found.instance, found.primitive, found.bary, found.t * spread, met.m.program_id, 0u, INVALID};
                uint index = point_append(point);
                if (index != INVALID) {
                    Point_Head waiting = point_head(index, INVALID, slot * params.rays_per_probe + ray);
                    waiting.aux[0] = record_oct(arrived);
                    waiting.aux[1] = asuint(t);
                    waiting.aux[2] = asuint(gate);
                    if (head_append(waiting)) return;
                }
                // Without room for its program it shows its row, this update.
                passing = true;
            }
            s = surface_from_hit(met, false, (Mirai_Surface)0);
            material = met.m;
            surface = true;
        }
    }
    if (!active) return;

    // What is kept of a surface: the light it takes comes below.
    float3 albedo = hit.albedo, through = hit.through, emission = float3(0.0);
    if (surface) {
        hit = (Probe_Hit)0;
        hit.t = t;
        if (hit_inside(material, s.geometric_normal, arrived)) {
            hit.flags = HIT_BACK;
        } else {
            // To a ray the globe of a light is that light, which what it reaches
            // takes already: it brings back nothing.
            bool globe = hit_on_light(s, instance);
            albedo = globe ? float3(0.0) : s.albedo;
            through = globe ? float3(0.0) : surface_transmit(s);
            emission = globe ? float3(0.0) : s.emission;
            hit.normal = hit_normal(s, arrived);
            hit.albedo = albedo;
            hit.through = through;
            hit.flags = HIT_SURFACE;
            if (any(s.emission > float3(0.0))) hit.flags |= HIT_FIXED;
            light = !globe;
        }
        if (passing || material_changing(material)) hit.flags |= HIT_PASSING;
    }
    bool gated = gate >= 0.0;
    if (gated) hit.flags |= HIT_PASSING;
    bool fresh = surface || trace;
    // What a later update reads of it, which this one gives too.
    Probe_Hit seen = fresh ? probe_hit_unpack(probe_hit_pack(hit)) : hit;
    uint kind = seen.flags & HIT_KIND;
    float3 position = gated ? s.position : origin + direction * seen.t;
#ifdef MIRAI_HOOK_LIGHTS
    if (fresh && kind == HIT_SURFACE) reached = extension_lights_reach(position, seen.normal, seen.t);
#endif
    // What changes with nothing that says so keeps its probe traced by turns.
    if ((seen.flags & HIT_PASSING) != 0u || reached) InterlockedOr(chosen[chosen_traced(slot)], CHOSEN_PASSING);

    // Its own direct light, so that a light that moves or turns off reaches the
    // probes in the frame it does.
    count(chosen_lit(), light);
    if (light) {
        // One that is not fixed reflects what is kept of it, as when it is lit again.
        if ((seen.flags & HIT_FIXED) == 0u) {
            albedo = seen.albedo;
            through = seen.through;
        }
        uint which = LIGHTS_ALL | LIGHTS_BOUNCED;
        float3 direct = emission + direct_lighting(shading_diffuse(position, seen.normal, albedo), hit_bias(seen.t), params.light_budget, which);
        // A thin surface that lets light through: the light of its other side.
        if (max(through.r, max(through.g, through.b)) > 0.0) direct += direct_lighting(shading_diffuse(position, -seen.normal, through), hit_bias(seen.t), params.light_budget, which | LIGHTS_THROUGH);
        hit = seen;
        hit.direct = direct;
        seen = probe_hit_unpack(probe_hit_pack(hit));
    }
    if (at != INVALID && (fresh || light)) probe_hit_store(at, probe_hit_pack(hit));

    if (kind == HIT_SKY) {
        // A ray that meets the sky stores the whole distance, which no hit reaches.
        ray_data[int2(ray, slot)] = float4(probe_light_encode(sky_radiance(arrived)), gated ? gate : params.max_distance);
        return;
    }
    if (kind == HIT_BACK) {
        ray_data[int2(ray, slot)] = float4(0.0, 0.0, 0.0, gated ? gate : -seen.t * 0.2);
        return;
    }
    // The bounces of the volume itself where it hits: each update adds one.
    float3 radiance = seen.direct + seen.albedo * sample_probes(position, seen.normal, -arrived, seen.t);
    if (max(seen.through.r, max(seen.through.g, seen.through.b)) > 0.0) radiance += seen.through * sample_probes(position, -seen.normal, -arrived, seen.t);
    ray_data[int2(ray, slot)] = float4(probe_light_encode(radiance), gated ? gate : seen.t);
}
