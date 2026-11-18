#include "native.slang"
//! variant hw MIRAI_HW_RT=1
// color: with colored shadows, the rays cross glass as the mean of its instance (trace.slang).
//! constant color MIRAI_GLASS_MEANS
// The rays of the probes chosen this frame (ddgi_select.comp): each probe
// traces the spherical Fibonacci set turned by the rotation of its cell, the
// same every update. Hits trace their direct light and read the bounces of
// the volume itself, as DDGI: nothing they read goes away while the scene
// stays still; a backface marks the probe as seeing the inside of geometry with a
// negative distance. The radiance of a ray is stored encoded (probe_light_encode).
// A hit on a material with a program waits for it (points.slang) and is
// shaded by the resume (params.resume) from what the program gave there.
#define MIRAI_DIFFUSE_HITS
// Small instances are not in the light this pass gathers (render.INSTANCE_FLAG_SMALL).
#define MIRAI_TRACE_NO_SMALL
// It reports the levels it samples of each texture (texture_feedback in scene.slang).
#define MIRAI_TEXTURE_FEEDBACK
#define POINTS_SLOT SLOT_POINTS
#include "lighting.slang"
#include "probe_update.slang"
#include <extension_hooks.slang>
#define MIRAI_GROUP_X 32
#define MIRAI_GROUP_Y 1
#define MIRAI_GROUP_Z 1

[[vk::binding(SLOT_PASS0, 0)]] [[vk::image_format("rgba16f")]] RWTexture2D<float4> ray_data : register(MIRAI_REGISTER(u, SLOT_PASS0), space0);

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 dispatch_id : SV_DispatchThreadID, uint3 group : SV_GroupID, uint local : SV_GroupIndex) {
    uint ray, slot;
    Surface s;
    float3 direction, glass;
    float t, gate;
    uint instance;
    if (params.resume != 0u) {
        Point_Head head;
        if (!head_of_round(group.x * MIRAI_GROUP_X + local, head)) return;
        ray = head.owner % params.rays_per_probe;
        slot = head.owner / params.rays_per_probe;
        Material_Point point = point_load(head.point);
        s = surface_from_hit(hit_point(point.instance, point.primitive, point.bary, point.footprint), point_record_given(head.point), point_record_load(head.point));
        instance = point.instance;
        direction = unpack_normal(head.aux[0]);
        t = asfloat(head.aux[1]);
        glass = float3(record_unhalf2(head.aux[2]), half_value(head.aux[3] & 0xffffu));
        gate = asfloat(head.aux[4]);
    } else {
        ray = dispatch_id.x;
        slot = dispatch_id.y;
        if (ray >= params.rays_per_probe || slot >= chosen[0]) return;
        uint probe = chosen[1u + slot];
        float3 origin = probe_world_position(probe);
        float3 dir = probe_ray_direction(probe, ray, params.rays_per_probe);
        Ray_Path path;
        Hit hit = trace_ray(origin, dir, 0.0, params.max_distance, false, path);
        // What a ray finds beyond a gate of an extension lights the probe, and for
        // its visibility is as far as the gate: what is behind it is another place.
        // A ray that meets the sky stores the whole distance, which no hit reaches.
        gate = path.gate;
        if (hit.instance == INVALID) {
            ray_data[int2(ray, slot)] = float4(probe_light_encode(sky_radiance(path.direction) * path.glass), gate >= 0.0 ? gate : params.max_distance);
            return;
        }
        // Each ray stands for an equal share of the sphere around the probe.
        float spread = 2.0 * sqrt(4.0 / float(params.rays_per_probe));
        Hit_Point found = hit_point(hit.instance, hit.primitive, hit.bary, hit.t * spread);
        direction = path.direction;
        t = hit.t;
        glass = path.glass;
        instance = hit.instance;
        if (found.m.program_id != 0u && dot(found.geometric_normal, direction) <= 0.0) {
            Material_Point point = {hit.instance, hit.primitive, hit.bary, hit.t * spread, found.m.program_id, 0u, INVALID};
            uint index = point_append(point);
            if (index != INVALID) {
                Point_Head head = point_head(index, INVALID, slot * params.rays_per_probe + ray);
                head.aux[0] = record_oct(direction);
                head.aux[1] = asuint(t);
                head.aux[2] = record_half2(glass.r, glass.g);
                head.aux[3] = half_bits(glass.b);
                head.aux[4] = asuint(gate);
                if (head_append(head)) return;
            }
        }
        s = surface_from_hit(found, false, (Mirai_Surface)0);
    }
    bool gated = gate >= 0.0;
    if (dot(s.geometric_normal, direction) > 0.0) {
        ray_data[int2(ray, slot)] = float4(0.0, 0.0, 0.0, gated ? gate : -t * 0.2);
        return;
    }
    // Its own direct light, so that a light that moves or turns off reaches the probes in the
    // frame it does, and the bounces of the volume itself where it hits: each trace adds one.
    float3 radiance = hit_on_light(s, instance) ? float3(0.0) : shade_hit(s, direction, t, params.light_budget);
    ray_data[int2(ray, slot)] = float4(probe_light_encode(radiance * glass), gated ? gate : t);
}
