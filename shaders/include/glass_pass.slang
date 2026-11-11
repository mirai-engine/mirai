// What the passes of glass share (glass_light.comp, glass.comp and
// glass_inside.comp): the layer they light and, but in glass_light.comp
// (GLASS_LIGHT), the scene behind it and the way the view takes through a
// solid and out of it to what it shows.
#ifndef MIRAI_GLASS_PASS_SLANG
#define MIRAI_GLASS_PASS_SLANG
#include "glass.slang"
#include "gbuffer.slang"
#include <extension_hooks.slang>
#include "depth.slang"

// light_budget: lights of a point of the layer (glass_light.comp); traced: its
// reflection was traced; max_distance: the farthest the view goes; snapshot:
// the dispatch copies the scene (glass.comp); medium: the instance plus one of
// the solid the camera may be in, 0 none; near_top: m over and under its top
// within which each pixel decides whether it starts in it (glass_inside.comp).
struct Params_Block { uint light_budget; uint traced; float max_distance; uint snapshot; uint medium; float near_top; uint pad0; uint pad1; };
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);
[[vk::binding(SLOT_PASS0, 0)]] Texture2D<float4> layer_albedo : register(MIRAI_REGISTER(t, SLOT_PASS0), space0);   // rgb base color, a metallic
[[vk::binding(SLOT_PASS1, 0)]] Texture2D<float4> layer_normal : register(MIRAI_REGISTER(t, SLOT_PASS1), space0);   // encoded as the normal target of the G-buffer
[[vk::binding(SLOT_PASS2, 0)]] Texture2D<float4> layer_emission : register(MIRAI_REGISTER(t, SLOT_PASS2), space0); // rgb emission, a alpha
[[vk::binding(SLOT_PASS3, 0)]] Texture2D<uint2> layer_ids : register(MIRAI_REGISTER(t, SLOT_PASS3), space0);     // material row, instance
[[vk::binding(SLOT_PASS4, 0)]] Texture2D<float4> layer_depth : register(MIRAI_REGISTER(t, SLOT_PASS4), space0);
[[vk::binding(SLOT_PASS6, 0)]] Texture2D<float4> reflection : register(MIRAI_REGISTER(t, SLOT_PASS6), space0);     // filtered radiance of the layer's reflection rays
[[vk::binding(SLOT_PASS7, 0)]] [[vk::image_format("rgba16f")]] RWTexture2D<float4> out_color : register(MIRAI_REGISTER(u, SLOT_PASS7), space0);
[[vk::binding(SLOT_PASS9, 0)]] Texture2D<float4> layer_specular : register(MIRAI_REGISTER(t, SLOT_PASS9), space0); // rgb F0, a F90

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
    float4 specular = specular_unpack(layer_specular.Load(int3(p, 0)));
    g.f0 = specular.rgb;
    g.f90 = specular.a;
    // The layers target of the layer is bound in place of the G-buffer's.
    g.layers = gbuffer_layers(p, gbuffer_bits_unpack(normal));
    return g;
}

#ifndef GLASS_LIGHT
[[vk::binding(SLOT_PASS5, 0)]] Texture2D<float4> scene : register(MIRAI_REGISTER(t, SLOT_PASS5), space0);          // everything behind the layer, lit
[[vk::binding(SLOT_PASS8, 0)]] Texture2D<float4> g_depth : register(MIRAI_REGISTER(t, SLOT_PASS8), space0);        // the opaque scene

#define SCATTER_TAPS 8
// Width of the lobe a rough surface scatters transmitted light into, per unit
// of its GGX alpha.
static const float SCATTER_SPREAD = 0.6;

float opaque_depth(float2 uv) {
    float depth = g_depth.SampleLevel(point_sampler, uv, 0.0).r;
    return depth_empty(depth) ? frame.camera_forward.w : depth_distance(depth);
}

// The plane of the opaque surface at uv on screen: where it is, and its normal
// towards the eye, from the depth of the pixels beside it, on each axis the
// side nearer it, so that an edge does not bend it.
float3 opaque_plane(float2 uv, out float3 normal) {
    float3 center = position_from_depth(uv, opaque_depth(uv));
    float2 step = frame.inv_resolution;
    float3 right = position_from_depth(uv + float2(step.x, 0.0), opaque_depth(uv + float2(step.x, 0.0))) - center;
    float3 left = center - position_from_depth(uv - float2(step.x, 0.0), opaque_depth(uv - float2(step.x, 0.0)));
    float3 down = position_from_depth(uv + float2(0.0, step.y), opaque_depth(uv + float2(0.0, step.y))) - center;
    float3 up = center - position_from_depth(uv - float2(0.0, step.y), opaque_depth(uv - float2(0.0, step.y)));
    float3 across = dot(right, right) < dot(left, left) ? right : left;
    float3 along = dot(down, down) < dot(up, up) ? down : up;
    normal = normalize(cross(across, along));
    if (dot(normal, frame.camera_position.xyz - center) < 0.0) normal = -normal;
    return center;
}

// Where a ray that leaves the layer meets the opaque scene on screen, and how
// far along it: it meets the plane of the surface the screen holds where it
// starts, and, where the screen holds another surface at that point, the plane
// of that one, up to CROSSING_TURNS times. What lies nearer the eye than
// `nearest` (in front of the layer) hides the point; under a sheet (open),
// what the screen holds at a point is under it only where the layer covers
// that point and it lies behind the layer there. Off the screen it ends at its
// edge. CROSSING_FAR where it goes past reach; CROSSING_LOST where it turns
// away from the planes or meets what is in front of the layer, and the screen
// does not hold where it ends. first: how far it goes to the plane of the
// surface where it starts, below 0 where it turns away from it.
#define CROSSING_TURNS 3
#define CROSSING_MET 0u
#define CROSSING_FAR 1u
#define CROSSING_LOST 2u
uint screen_crossing(float3 origin, float3 direction, float reach, float nearest, bool open, out float2 uv, out float travelled, out float first) {
    uv = project_uv(origin);
    travelled = 0.0;
    first = -1.0;
    for (int turn = 0; turn < CROSSING_TURNS; turn++) {
        if (opaque_depth(uv) < nearest) return CROSSING_LOST;
        if (open) {
            float layer = layer_depth.Load(int3(min(int2(uv * frame.resolution), int2(frame.resolution) - 1), 0)).r;
            if (!(layer > 0.0) || opaque_depth(uv) < layer) return CROSSING_LOST;
        }
        float3 normal;
        float3 surface = opaque_plane(uv, normal);
        float facing = dot(direction, normal);
        if (!(facing < -1e-4)) return CROSSING_LOST;
        travelled = dot(surface - origin, normal) / facing;
        if (turn == 0) first = travelled;
        if (!(travelled > 0.0)) return CROSSING_LOST;
        if (travelled > reach) return CROSSING_FAR;
        float3 met = origin + direction * travelled;
        float2 next = project_uv(met);
        float2 inside = clamp(next, 0.5 * frame.inv_resolution, 1.0 - 0.5 * frame.inv_resolution);
        uv = inside;
        if (any(((inside) != (next)))) return CROSSING_MET;
        float z = view_depth(met);
        if (abs(opaque_depth(uv) - z) <= 0.01 * z + 0.02) return CROSSING_MET;
    }
    return CROSSING_MET;
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


// The way of the view through a solid and out of it, without rays: it goes on
// bent as it went in, and shows the scene where it meets it on screen
// (screen_crossing). Behind what stands in front of the layer, or off the
// screen, it shows what the pixel shows straight through; going on in a solid
// that absorbs (WALK_OPEN, as under water), nothing that far in shows through.
#define WALK_OPEN 1u // it goes on in the solid to what it shows: the solid has no way out (a sheet)

struct Glass_Walk {
    uint flags;      // WALK_OPEN
    float3 origin;
    float3 direction;
    float path;      // how far it went inside before origin
    float travelled; // how far it went from origin to what it shows
    float3 radiance; // what it shows
};

Glass_Walk walk_start(float3 origin, float3 direction, uint flags) {
    Glass_Walk w;
    w.flags = flags;
    w.origin = origin;
    w.direction = direction;
    w.path = 0.0;
    w.travelled = 0.0;
    w.radiance = float3(0.0);
    return w;
}

// What a walk shows, behind the layer. depth: of the layer, which rough glass
// blurs the scene behind by; uv: of the pixel.
void walk_show(inout Glass_Walk w, Material m, float depth, float roughness, float2 uv, inout uint seed) {
    float2 at;
    // In a solid without a way out it goes no farther than what would still show through.
    bool open = (w.flags & WALK_OPEN) != 0u && material_clear_reach(m) < params.max_distance;
    float reach = open ? min(material_clear_reach(m), params.max_distance) : params.max_distance;
    float travelled;
    float first;
    uint crossing = screen_crossing(w.origin, w.direction, reach, depth, (w.flags & WALK_OPEN) != 0u, at, travelled, first);
    if (crossing != CROSSING_MET) {
        // Past reach, or where the screen does not hold where the way ends,
        // what the pixel shows straight through, as far in as the way goes to
        // the surface it starts over: what the solid absorbs on that way fades
        // it as it fades what the screen holds, with no edge between them.
        at = uv;
        travelled = first > 0.0 ? first : length(position_from_depth(at, opaque_depth(at)) - w.origin);
    }
    w.travelled = travelled;
    w.radiance = scene_through(at, depth, roughness, seed);
}
#endif

#endif
