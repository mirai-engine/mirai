#include "native.slang"
//! variant hw MIRAI_HW_RT=1
// What the diffuse indirect light of each pixel approximates, which the
// tests compare it with (reference_test.odin): the mean, weighted by the cosine, of the
// light that arrives at it from everything but the sun and the local lights,
// by paths. Every frame each pixel sends params.paths rays distributed by the
// cosine; at each surface they meet, the sun and every local light give their
// light through a ray of their own to a point of each, the surface its
// emission where no light stands for it, and the path goes on in another
// direction distributed by the cosine while Russian roulette keeps it. A ray
// that meets nothing sees the sky.
//
// `accumulated` holds the mean of every frame since the reference last
// started (params.reset), the count of frames in a: it is the Gi of the
// pipeline, which the composite and the debug views show in place of the
// probe volume. A frame first scales the
// mean of the frames before by their share, then each path adds its light by
// its own share as it finds it.
//
// A path that meets a material with a program waits for it (points.slang):
// the pixel goes on in the resume (params.resume) from that surface, with
// what it keeps of its paths, and may wait again in a later round.
#define POINTS_SLOT SLOT_POINTS
#include "lighting.slang"
#include "reference.slang"
#include <extension_hooks.slang>
#define MIRAI_GROUP_X 8
#define MIRAI_GROUP_Y 8
#define MIRAI_GROUP_Z 1

// sun_radius: angular radius of the sun, radians.
struct Params_Block { uint paths; uint bounces; uint reset; float sun_radius; uint resume; uint pad0; uint pad1; uint pad2; };
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);
#define GBUFFER_NORMAL SLOT_PASS0
#include "gbuffer.slang"
#include "pixel.slang"
[[vk::binding(SLOT_PASS1, 0)]] Texture2D<float4> g_depth : register(MIRAI_REGISTER(t, SLOT_PASS1), space0);
[[vk::binding(SLOT_PASS2, 0)]] [[vk::image_format("rgba32f")]] RWTexture2D<float4> accumulated : register(MIRAI_REGISTER(u, SLOT_PASS2), space0);

// Bounces after which Russian roulette may end a path, and the most it keeps one.
static const uint ROULETTE_AFTER = 2u;
static const float ROULETTE_KEEP_MAX = 0.95;

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 dispatch_id : SV_DispatchThreadID, uint3 group : SV_GroupID, uint local : SV_GroupIndex) {
    int2 p;
    uint path = 0u, bounce = 0u, seed;
    float3 weight = float3(1.0);
    // A surface the path met, waiting to be shaded: the one of the resume.
    bool waiting = false;
    Surface s;
    float3 direction;
    float t;
    uint instance;
    if (params.resume != 0u) {
        Point_Head head;
        if (!head_of_round(group.x * (MIRAI_GROUP_X * MIRAI_GROUP_Y) + local, head)) return;
        p = int2(head.owner & 0xffffu, head.owner >> 16u);
        weight = float3(asfloat(head.aux[0]), asfloat(head.aux[1]), asfloat(head.aux[2]));
        seed = head.aux[3];
        path = head.aux[4] & 0xffffu;
        bounce = head.aux[4] >> 16u;
        Material_Point point = point_load(head.point);
        s = surface_from_hit(hit_point(point.instance, point.primitive, point.bary, point.footprint), point_record_given(head.point), point_record_load(head.point));
        float2 kept = point_kept(head.point);
        direction = unpack_normal(asuint(kept.x));
        t = kept.y;
        instance = point.instance;
        waiting = true;
    } else {
        p = int2(dispatch_id.xy);
        if (any(p >= int2(frame.resolution))) return;
        float4 held = params.reset != 0u ? float4(0.0) : accumulated[p];
        float frames = held.a + 1.0;
        // The mean of the frames before, by their share of the mean with this one.
        accumulated[p] = float4(held.rgb * (1.0 - 1.0 / frames), frames);
        if (depth_empty(g_depth.Load(int3(p, 0)).r)) return;
        // Nested hashes: a sum of the coordinates would repeat the numbers of
        // other pixels in other frames.
        seed = hash_u32(hash_u32(hash_u32(uint(p.x) + 0x9E3779B9u) ^ uint(p.y)) + frame.frame_index * 0x85EBCA6Bu);
    }
    float depth = g_depth.Load(int3(p, 0)).r;
    float3 n0 = gbuffer_normal(p);
    float2 uv = (float2(p) + 0.5) * frame.inv_resolution;
    Pixel pixel = pixel_at(p, uv, depth);
    float3 start = offset_origin(pixel.position, n0, view_bias(pixel.distance));
    // What a light found adds to the mean: its share of the paths of this frame and of the frames.
    float share = 1.0 / (float(max(params.paths, 1u)) * accumulated[p].a);
    float3 found_light = float3(0.0);
    float3 origin = start;
    float3 dir = float3(0.0);
    while (path < params.paths) {
        if (!waiting) {
            if (bounce == 0u) {
                origin = start;
                dir = sample_cosine(n0, float2(random01(seed), random01(seed)));
                weight = float3(1.0);
            }
            Ray_Path ray;
            Hit hit = trace_ray(origin, dir, 0.0, scene_reach(origin, dir), false, ray);
            if (hit.instance == INVALID) {
                found_light += finite_or_zero(weight * sky_radiance(ray.direction));
                path++;
                bounce = 0u;
                continue;
            }
            Hit_Point met = hit_point(hit.instance, hit.primitive, hit.bary, 0.0);
            direction = ray.direction;
            t = hit.t;
            instance = hit.instance;
            if (met.m.program_id != 0u) {
                Material_Point point = {hit.instance, hit.primitive, hit.bary, 0.0, met.m.program_id, 0u, INVALID};
                uint index = point_append(point);
                if (index != INVALID) {
                    point_keep(index, float2(asfloat(record_oct(direction)), t));
                    Point_Head head = point_head(index, INVALID, uint(p.x) | (uint(p.y) << 16u));
                    head.aux[0] = asuint(weight.r);
                    head.aux[1] = asuint(weight.g);
                    head.aux[2] = asuint(weight.b);
                    head.aux[3] = seed;
                    head.aux[4] = path | (bounce << 16u);
                    if (head_append(head)) break;
                }
            }
            s = surface_from_hit(met, false, (Mirai_Surface)0);
        }
        waiting = false;
        // The ray arrived at the side of its triangle: an interpolated normal can
        // face along a ray that grazes a curved surface, and turning it would
        // light the surface from behind.
        float3 side = dot(s.geometric_normal, s.normal) < 0.0 ? -s.geometric_normal : s.geometric_normal;
        float3 n = dot(side, direction) > 0.0 ? -s.normal : s.normal;
        bool ends = hit_on_light(s, instance);
        if (!ends) {
            found_light += finite_or_zero(weight * s.emission);
            float bias = hit_bias(t);
            Shading white = shading_diffuse(s.position, n, float3(1.0));
            float3 direct = reference_lighting(white, bias, params.sun_radius, 1u, seed);
#ifdef MIRAI_HOOK_LIGHTS
            direct += direct_lighting(white, bias, 0u, LIGHTS_EXTENSION, float2(random01(seed) * 16.0, random01(seed) * 2.0 * PI));
#endif
            found_light += finite_or_zero(weight * s.albedo * direct);
            weight *= s.albedo;
            if (bounce >= ROULETTE_AFTER) {
                float keep = min(max(weight.r, max(weight.g, weight.b)), ROULETTE_KEEP_MAX);
                if (random01(seed) >= keep) ends = true;
                else weight /= keep;
            }
            origin = offset_origin(s.position, n, bias);
            dir = sample_cosine(n, float2(random01(seed), random01(seed)));
        }
        bounce++;
        if (ends || bounce >= params.bounces) {
            path++;
            bounce = 0u;
        }
    }
    float4 mean = accumulated[p];
    accumulated[p] = float4(mean.rgb + found_light * share, mean.a);
}
