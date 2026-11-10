// What the passes of glass share (glass.comp and glass_inside.comp): the
// layer they light, the scene behind it, and the ways a ray takes through a
// solid and out of it to what it shows.
#ifndef MIRAI_GLASS_PASS_SLANG
#define MIRAI_GLASS_PASS_SLANG
#define POINTS_SLOT SLOT_POINTS
#include "glass.slang"
#include "gbuffer.slang"
#include <extension_hooks.slang>
#include "depth.slang"

// medium: the instance plus one of the solid the camera may be in, 0 none; near_top: m over and under its top
// within which each pixel decides whether it starts in it (glass_inside.comp).
// resume: a thread for each head of the round of the batch, instead of each pixel.
struct Params_Block { uint light_budget; uint traced; float max_distance; float firefly_clamp; float pixel_spread; uint snapshot; uint medium; float near_top; uint resume; uint pad0; uint pad1; uint pad2; };
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);
[[vk::binding(SLOT_PASS0, 0)]] Texture2D<float4> layer_albedo : register(MIRAI_REGISTER(t, SLOT_PASS0), space0);   // rgb base color, a metallic
[[vk::binding(SLOT_PASS1, 0)]] Texture2D<float4> layer_normal : register(MIRAI_REGISTER(t, SLOT_PASS1), space0);   // encoded as the normal target of the G-buffer
[[vk::binding(SLOT_PASS2, 0)]] Texture2D<float4> layer_emission : register(MIRAI_REGISTER(t, SLOT_PASS2), space0); // rgb emission, a alpha
[[vk::binding(SLOT_PASS3, 0)]] Texture2D<uint2> layer_ids : register(MIRAI_REGISTER(t, SLOT_PASS3), space0);     // material row, instance
[[vk::binding(SLOT_PASS4, 0)]] Texture2D<float4> layer_depth : register(MIRAI_REGISTER(t, SLOT_PASS4), space0);
[[vk::binding(SLOT_PASS5, 0)]] Texture2D<float4> scene : register(MIRAI_REGISTER(t, SLOT_PASS5), space0);          // everything behind the layer, lit
[[vk::binding(SLOT_PASS6, 0)]] Texture2D<float4> reflection : register(MIRAI_REGISTER(t, SLOT_PASS6), space0);     // filtered radiance of the layer's reflection rays
[[vk::binding(SLOT_PASS7, 0)]] [[vk::image_format("rgba16f")]] RWTexture2D<float4> out_color : register(MIRAI_REGISTER(u, SLOT_PASS7), space0);
[[vk::binding(SLOT_PASS8, 0)]] Texture2D<float4> g_depth : register(MIRAI_REGISTER(t, SLOT_PASS8), space0);        // the opaque scene

[[vk::binding(SLOT_PASS9, 0)]] Texture2D<float4> layer_specular : register(MIRAI_REGISTER(t, SLOT_PASS9), space0); // rgb F0, a F90

#define SCATTER_TAPS 8
// Bounces inside a solid before the ray is let out where it is.
#define INSIDE_BOUNCES 3
// Width of the lobe a rough surface scatters transmitted light into, per unit
// of its GGX alpha.
static const float SCATTER_SPREAD = 0.6;

float opaque_depth(float2 uv) {
    float depth = g_depth.SampleLevel(point_sampler, uv, 0.0).r;
    return depth_empty(depth) ? frame.camera_forward.w : depth_distance(depth);
}

// Where a ray that leaves the layer meets the opaque scene on screen. The
// depth buffer is a height field seen from the camera, so going to the depth
// found where the ray is now closes in on the crossing in a few steps. False
// when the ray leaves the screen or turns towards the camera.
bool screen_crossing(float3 origin, float3 direction, out float2 uv) {
    uv = float2(0.0);
    float along = dot(direction, frame.camera_forward.xyz);
    if (along < 0.05) return false;
    float start = dot(origin - frame.camera_position.xyz, frame.camera_forward.xyz);
    uv = project_uv(origin);
    for (int i = 0; i < 4; i++) {
        if (any(((uv) < (float2(0.0)))) || any(((uv) > (float2(1.0))))) return false;
        float2 next = project_uv(origin + direction * max((opaque_depth(uv) - start) / along, 0.0));
        bool settled = all(((abs(next - uv) * frame.resolution) < (float2(0.5))));
        uv = next;
        if (settled) break;
    }
    return all(((uv) >= (float2(0.0)))) && all(((uv) <= (float2(1.0))));
}

// The scene around uv as a rough layer at layer_distance shows it: spread over
// a disc that grows with what is between the layer and the scene behind it.
// Pixels of what stands in front of the layer are not part of it.
float3 scene_through(float2 uv, float layer_distance, float roughness, inout uint seed) {
    float3 center = scene.SampleLevel(linear_sampler, uv, 0.0).rgb;
    if (roughness <= MIRROR_ROUGHNESS) return center;
    float alpha = roughness * roughness;
    float behind = opaque_depth(uv);
    // Pixels a world radius covers at the depth of the scene.
    float radius = max(behind - layer_distance, 0.0) * alpha * SCATTER_SPREAD / max(frame.footprint.x + frame.footprint.y * max(behind, 1e-3), 1e-9);
    if (radius < 0.75) return center;
    radius = min(radius, 0.08 * frame.resolution.y);
    float3 sum = center;
    float count = 1.0;
    float rotation = random01(seed) * 2.0 * PI;
    for (int i = 0; i < SCATTER_TAPS; i++) {
        float angle = rotation + float(i) * 2.399963;
        float2 at = uv + float2(cos(angle), sin(angle)) * (radius * sqrt((float(i) + 0.5) / float(SCATTER_TAPS))) * frame.inv_resolution;
        if (any(((at) < (float2(0.0)))) || any(((at) > (float2(1.0)))) || opaque_depth(at) < layer_distance) continue;
        sum += scene.SampleLevel(linear_sampler, at, 0.0).rgb;
        count += 1.0;
    }
    return sum / count;
}

// What a solid with a scatter color sends towards the eye from `path` of it
// along direction from origin, on top of what it lets through of what lies
// behind: the light around that reaches it inside, dimmed by the way through
// the solid down from its top, times the share it scatters of what it stops
// on that path. The light is taken at one point, half way along the path or
// along the distance its attenuation is given for, whichever is nearer. The
// sun in it, with the shadows of what stands in its way, is the shafts of fog.
// top: the height of the top over the point when the caller knows it, as a
// flat top it entered through or found over the camera; below SOLID_TOP_UNKNOWN,
// a ray up in the solid finds it.
#define SOLID_TOP_UNKNOWN -1e29
float3 solid_scatter(Material m, uint instance, float3 origin, float3 direction, float path, float top) {
    float3 scatter = materials[m.row].volume.scatter;
    if (!any(scatter > 0.0) || !(path > 0.0)) return float3(0.0);
    float3 at = origin + direction * (0.5 * min(path, max(m.attenuation_distance, 1.0)));
    float under;
    if (top > SOLID_TOP_UNKNOWN) {
        under = max(top - at.y, 0.0);
    } else {
        Hit found = trace_instance(instance, at, float3(0.0, 1.0, 0.0));
        under = found.instance == INVALID ? 0.0 : found.t;
    }
    float3 light = 0.5 * sky_irradiance(float3(0.0, 1.0, 0.0)) * material_absorption(m, under);
    return scatter * light * (1.0 - material_absorption(m, path));
}

// The ways of a ray of the view through a solid and out of it, in rounds
// (points.slang): one waits for the normal of a face with a program it meets
// inside (WALK_INSIDE), or for the surface with a program it finds beyond
// (WALK_SEEN); the resume (params.resume) goes on from there, and the pixel
// adds what each way brings to the image as it ends.
// Inside, a way also meets the rest of the scene where the stage says so (the
// camera in the solid, glass_inside.comp): a constant, so the others carry
// no ray for it.
#ifndef GLASS_WALK_IN_SCENE
#define GLASS_WALK_IN_SCENE 0
#endif
#define WALK_INSIDE 1u   // following the solid inside: a face to turn at
#define WALK_SEEN 2u     // out of it: what it shows
#define WALK_DONE 3u
#define WALK_STOPPED 4u  // it met something solid of the mesh inside
#define WALK_OPEN 8u     // it found no way out: it goes on as it was
#define WALK_FOUND 16u   // it met something of the scene inside
#define WALK_BOUNCE_SHIFT 8u
#define WALK_LEG_SHIFT 12u

struct Glass_Walk {
    uint stage;     // WALK_INSIDE, WALK_SEEN or WALK_DONE
    uint flags;     // WALK_STOPPED, WALK_OPEN, WALK_FOUND
    uint bounce;    // inside, before the ray is let out where it is
    uint leg;       // which way of the pass it is
    float3 origin;
    float3 direction;
    float path;     // how far it went inside
    float3 glass;   // what the glass it crossed on the way leaves of light
    float travelled; // how far the ray went to what it shows
    float3 radiance; // what it shows, at WALK_DONE
};

Glass_Walk walk_start(uint leg, uint stage, float3 origin, float3 direction, uint flags) {
    Glass_Walk w;
    w.stage = stage;
    w.flags = flags;
    w.bounce = 0u;
    w.leg = leg;
    w.origin = origin;
    w.direction = direction;
    w.path = 0.0;
    w.glass = float3(1.0);
    w.travelled = 0.0;
    w.radiance = float3(0.0);
    return w;
}

// A ray inside the solid turns at a face of the given normal: it bends out
// where it can and is reflected back in where it cannot; something solid of
// the mesh stops it.
void walk_turn(inout Glass_Walk w, Material m, float3 normal, bool blended, float t, float bias) {
    w.origin += w.direction * t;
    w.path += t;
    if (!blended) { w.flags |= WALK_STOPPED; w.stage = WALK_SEEN; return; }
    float3 outside = refract(w.direction, normal, m.ior);
    if (dot(outside, outside) > 0.0) {
        w.direction = outside;
        w.origin += outside * bias;
        w.stage = WALK_SEEN;
        return;
    }
    // Total internal reflection.
    w.direction = reflect(w.direction, normal);
    w.origin += w.direction * bias;
    w.bounce++;
    if (w.bounce >= INSIDE_BOUNCES) w.stage = WALK_SEEN;
}

// The head of a walk that waits for a point, with what the resume needs of it.
bool walk_wait(Glass_Walk w, uint point, float t, int2 p) {
    point_keep(point, float2(asfloat(record_oct(w.direction)), t));
    Point_Head head = point_head(point, INVALID, uint(p.x) | (uint(p.y) << 16u));
    if (w.stage == WALK_INSIDE) {
        head.aux[0] = asuint(w.origin.x);
        head.aux[1] = asuint(w.origin.y);
        head.aux[2] = asuint(w.origin.z);
    } else {
        head.aux[0] = record_half2(w.glass.r, w.glass.g);
        head.aux[1] = half_bits(w.glass.b);
    }
    head.aux[3] = asuint(w.path);
    head.aux[4] = w.stage | w.flags | (w.bounce << WALK_BOUNCE_SHIFT) | (w.leg << WALK_LEG_SHIFT);
    return head_append(head);
}

// The walk a head waits with, and the surface it waited for: a face whose
// normal it turns at, or what it shows.
Glass_Walk walk_resumed(Point_Head head, Material m, uint instance, float bias, out bool shade, out Surface s, out float t) {
    Glass_Walk w;
    uint packed = head.aux[4];
    w.stage = packed & 3u;
    w.flags = packed & (WALK_STOPPED | WALK_OPEN | WALK_FOUND);
    w.bounce = (packed >> WALK_BOUNCE_SHIFT) & 15u;
    w.leg = packed >> WALK_LEG_SHIFT;
    w.path = asfloat(head.aux[3]);
    w.travelled = 0.0;
    w.radiance = float3(0.0);
    float2 kept = point_kept(head.point);
    w.direction = unpack_normal(asuint(kept.x));
    t = kept.y;
    Material_Point point = point_load(head.point);
    s = surface_from_hit(hit_point(point.instance, point.primitive, point.bary, point.footprint), point_record_given(head.point), point_record_load(head.point));
    shade = w.stage == WALK_SEEN;
    if (shade) {
        w.glass = float3(record_unhalf2(head.aux[0]), half_value(head.aux[1] & 0xffffu));
        w.origin = float3(0.0);
        return w;
    }
    w.glass = float3(1.0);
    w.origin = float3(asfloat(head.aux[0]), asfloat(head.aux[1]), asfloat(head.aux[2]));
    uint row;
    float3 face = triangle_face(point.instance, point.primitive, row);
    walk_turn(w, m, hit_normal_turned(face, s.normal, w.direction), material_row(row).alpha_mode == ALPHA_BLEND, t, bias);
    return w;
}

// What the radiance of a surface a walk shows is, as the view sees it: lit,
// through the glass on the way, without fireflies.
float3 walk_shown(Surface s, Glass_Walk w, float t) {
    float3 radiance = shade_hit(s, w.direction, t, params.light_budget) * w.glass;
    float l = luminance(radiance);
    return l > params.firefly_clamp ? radiance * (params.firefly_clamp / l) : radiance;
}

// Goes on with a walk until it ends (WALK_DONE, with what it shows) or it
// waits for a point: then false, and the pixel stops here this round. A
// surface without a program it meets is in s, to shade (shade): one call
// site of the lighting for every way of a pass.
bool walk_advance(inout Glass_Walk w, Material m, uint instance, float depth, float roughness, float bias, int2 p, inout uint seed, out bool shade, out Surface s, out float t) {
    shade = false;
    s = (Surface)0;
    t = 0.0;
    if (w.stage == WALK_INSIDE) {
        while (w.stage == WALK_INSIDE) {
            Hit hit = trace_instance(instance, w.origin, w.direction);
#if GLASS_WALK_IN_SCENE
            {
                Ray_Path crossed;
                // Past the face it found: with ray tracing hardware what that found can be what is met.
                Hit met = trace_ray(w.origin, w.direction, 0.0, hit.instance == INVALID ? params.max_distance : hit.t + bias, false, crossed);
                if (met.instance != INVALID && met.instance != instance) {
                    w.flags |= WALK_FOUND;
                    w.glass = crossed.glass;
                    w.origin += w.direction * met.t;
                    w.path += met.t;
                    w.stage = WALK_SEEN;
                    Hit_Point found = hit_point(met.instance, met.primitive, met.bary, (depth + w.path) * max(params.pixel_spread, roughness * roughness));
                    t = met.t;
                    if (found.m.program_id != 0u) {
                        Material_Point point = {met.instance, met.primitive, met.bary, (depth + w.path) * max(params.pixel_spread, roughness * roughness), found.m.program_id, 0u, INVALID};
                        uint index = point_append(point);
                        if (index != INVALID && walk_wait(w, index, t, p)) return false;
                    }
                    s = surface_from_hit(found, false, (Mirai_Surface)0);
                    shade = true;
                    return true;
                }
            }
#endif
            if (hit.instance == INVALID) {
                // No way out found: an open mesh, or a sheet the camera is under.
                w.flags |= WALK_OPEN;
                w.stage = WALK_SEEN;
                break;
            }
            uint row;
            float3 face = triangle_face(hit.instance, hit.primitive, row);
            Material at = material_row(row);
            if (at.program_id != 0u) {
                Material_Point point = {hit.instance, hit.primitive, hit.bary, 1e-4, at.program_id, 0u, INVALID};
                uint index = point_append(point);
                if (index != INVALID && walk_wait(w, index, hit.t, p)) return false;
            }
            walk_turn(w, m, hit_normal_turned(face, surface_from_triangle(hit.instance, hit.primitive, hit.bary, 1e-4).normal, w.direction), at.alpha_mode == ALPHA_BLEND, hit.t, bias);
        }
        return true;
    }
    if (w.stage != WALK_SEEN) return true;
    // What the ray shows: the scene on screen when it is there, else what it finds in the world.
    float2 at;
    bool on_screen;
    if ((w.flags & WALK_STOPPED) != 0u) {
        at = project_uv(w.origin);
        on_screen = all(((at) >= (float2(0.0)))) && all(((at) <= (float2(1.0))));
    } else {
        on_screen = screen_crossing(w.origin, w.direction, at);
    }
    if (on_screen && opaque_depth(at) >= depth) {
        w.travelled = length(position_from_depth(at, opaque_depth(at)) - w.origin);
        w.radiance = scene_through(at, depth, roughness, seed);
        w.stage = WALK_DONE;
        return true;
    }
    Ray_Path arrival;
    Hit hit = trace_ray(w.origin, w.direction, 0.0, params.max_distance, false, arrival);
    w.direction = arrival.direction;
    w.glass = arrival.glass;
    if (hit.instance == INVALID) {
        w.travelled = params.max_distance;
        w.radiance = (frame.background.w > 0.5 ? frame.background.rgb : sky_seen(arrival.direction)) * arrival.glass;
        w.stage = WALK_DONE;
        return true;
    }
    w.travelled = hit.t;
    t = hit.t;
    float footprint = (depth + w.path + hit.t) * max(params.pixel_spread, roughness * roughness);
    Hit_Point found = hit_point(hit.instance, hit.primitive, hit.bary, footprint);
    if (found.m.program_id != 0u) {
        Material_Point point = {hit.instance, hit.primitive, hit.bary, footprint, found.m.program_id, 0u, INVALID};
        uint index = point_append(point);
        if (index != INVALID && walk_wait(w, index, t, p)) return false;
    }
    s = surface_from_hit(found, false, (Mirai_Surface)0);
    shade = true;
    return true;
}

// A walk that shaded the surface it showed ends with it.
void walk_shaded(inout Glass_Walk w, Surface s, float t) {
    if ((w.flags & WALK_FOUND) == 0u) w.travelled = t;
    w.radiance = walk_shown(s, w, t);
    w.stage = WALK_DONE;
}

// The surface of the layer at a pixel.
Glass glass_of(int2 p, float2 uv, float depth, float4 albedo, float4 normal, float4 emission) {
    Glass g;
    g.position = position_from_depth(uv, depth);
    g.normal = gbuffer_normal_unpack(normal);
    g.view = -view_direction(uv);
    g.base_color = albedo.rgb;
    g.alpha = emission.a;
    g.metallic = albedo.a;
    g.roughness = normal.z;
    g.emission = emission.rgb;
    g.occlusion = 1.0;
    float4 specular = layer_specular.Load(int3(p, 0));
    g.f0 = specular.rgb;
    g.f90 = specular.a;
    // The layers target of the layer is bound in place of the G-buffer's.
    g.layers = gbuffer_layers(p, gbuffer_bits_unpack(normal));
    return g;
}

#endif
