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

// Where a ray that leaves the layer meets the opaque scene on screen: it meets
// the plane of the surface the screen holds where it starts, and, where the
// screen holds another surface at that point, the plane of that one, up to
// CROSSING_TURNS times. What lies nearer the eye than `nearest` (in front of
// the layer) hides the point. Off the screen it ends at its edge. False where
// the screen does not hold where it ends: it goes past params.max_distance,
// turns away from the planes or meets what is in front of the layer.
#define CROSSING_TURNS 3
bool screen_crossing(float3 origin, float3 direction, float nearest, out float2 uv) {
    uv = project_uv(origin);
    for (int turn = 0; turn < CROSSING_TURNS; turn++) {
        if (opaque_depth(uv) < nearest) return false;
        float3 normal;
        float3 surface = opaque_plane(uv, normal);
        float facing = dot(direction, normal);
        if (!(facing < -1e-4)) return false;
        float travelled = dot(surface - origin, normal) / facing;
        if (!(travelled > 0.0) || travelled > params.max_distance) return false;
        float3 met = origin + direction * travelled;
        float2 next = project_uv(met);
        float2 inside = clamp(next, 0.5 * frame.inv_resolution, 1.0 - 0.5 * frame.inv_resolution);
        uv = inside;
        if (any(((inside) != (next)))) return true;
        float z = view_depth(met);
        if (abs(opaque_depth(uv) - z) <= 0.01 * z + 0.02) return true;
    }
    return true;
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


// A sheet the view does not leave (the surface of water): it shows what the
// pixel holds behind it, moved aside by the part of its refraction the relief
// of the surface gives, against that of its plane alone, by the way through
// the medium. A rippling surface bends what lies under it smoothly, the more
// the deeper it lies; the bend of the plane, alike at every pixel, is left
// out, since it would look for what lies under the sheet where the screen
// holds what stands over it. Where the pixel it lands on holds nothing behind
// the sheet, the pixel shows its own. What it shows is softened over a disc
// that grows with that way, as the scattering of the medium blurs what lies
// deep. travelled: the way through the medium to what the pixel holds.
#define SHEET_SHIFT_MOST 0.04 // of the height of the view
#define SHEET_BLUR 0.03       // metres of blur on what lies behind for each metre of the way to it
#define SHEET_TAPS 6
struct Sheet_Seen {
    float3 radiance;
    float travelled;
    float3 direction; // the way through the medium
};

// Whether the pixel at uv holds the layer, and so what lies under it: the
// layer is drawn only in front of the opaque scene (glass_layer.frag).
bool sheet_behind(float2 uv) {
    return layer_depth.Load(int3(min(int2(uv * frame.resolution), int2(frame.resolution) - 1), 0)).r > 0.0;
}

Sheet_Seen sheet_through(Material m, Glass g, float2 uv, int2 p) {
    Sheet_Seen seen;
    float behind = opaque_depth(uv);
    float3 held = position_from_depth(uv, behind);
    seen.travelled = length(held - g.position);
    float ior = material_ior(m);
    float3 flat = abs(g.normal.y) > 0.3 ? float3(0.0, g.normal.y >= 0.0 ? 1.0 : -1.0, 0.0) : g.normal;
    float3 bent = refract(-g.view, g.normal, 1.0 / ior);
    float3 even = refract(-g.view, flat, 1.0 / ior);
    bool turned = dot(bent, bent) > 0.0 && dot(even, even) > 0.0;
    seen.direction = turned ? bent : -g.view;
    float2 at = uv;
    if (turned) {
        float2 shift = project_uv(held + (bent - even) * seen.travelled) - uv;
        float most = SHEET_SHIFT_MOST * frame.resolution.y;
        float pixels = length(shift * frame.resolution);
        if (pixels > most) shift *= most / pixels;
        float2 moved = clamp(uv + shift, 0.5 * frame.inv_resolution, 1.0 - 0.5 * frame.inv_resolution);
        if (sheet_behind(moved)) at = moved;
    }
    float3 sum = scene.SampleLevel(linear_sampler, at, 0.0).rgb;
    float count = 1.0;
    float radius = min(SHEET_BLUR * seen.travelled / max(frame.footprint.x + frame.footprint.y * max(behind, 1e-3), 1e-9), 0.08 * frame.resolution.y);
    if (radius >= 0.75 && seen.travelled < material_clear_reach(m)) {
        // Turned by a hash of the pixel, the same every frame.
        float rotation = float(hash_u32(uint(p.x) * 73856093u ^ uint(p.y) * 19349663u)) * (2.0 * PI / 4294967296.0);
        for (int i = 0; i < SHEET_TAPS; i++) {
            float angle = rotation + float(i) * 2.399963;
            float2 tap = at + float2(cos(angle), sin(angle)) * (radius * sqrt((float(i) + 0.5) / float(SHEET_TAPS))) * frame.inv_resolution;
            if (any(tap < float2(0.0)) || any(tap > float2(1.0)) || !sheet_behind(tap)) continue;
            sum += scene.SampleLevel(linear_sampler, tap, 0.0).rgb;
            count += 1.0;
        }
    }
    seen.radiance = sum / count;
    return seen;
}

// The way of the view through a solid and out of it, without rays: it goes on
// bent as it went in, and shows the scene where it meets it on screen
// (screen_crossing). Behind what stands in front of the layer, or off the
// screen, it shows what the pixel shows straight through.
#define WALK_OPEN 1u // a sheet, which the view does not leave (sheet_through)

struct Glass_Walk {
    uint flags;      // WALK_OPEN
    float3 origin;
    float3 direction;
    float path;      // how far it went inside before origin
    float3 radiance; // what it shows
};

Glass_Walk walk_start(float3 origin, float3 direction, uint flags) {
    Glass_Walk w;
    w.flags = flags;
    w.origin = origin;
    w.direction = direction;
    w.path = 0.0;
    w.radiance = float3(0.0);
    return w;
}

// What a walk shows, behind the layer. depth: of the layer, which rough glass
// blurs the scene behind by; uv: of the pixel.
void walk_show(inout Glass_Walk w, float depth, float roughness, float2 uv, inout uint seed) {
    float2 at;
    if (!screen_crossing(w.origin, w.direction, depth, at)) at = uv;
    w.radiance = scene_through(at, depth, roughness, seed);
}
#endif

#endif
