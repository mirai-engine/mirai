#include "native.slang"
//! variant hw MIRAI_HW_RT=1
//! variant color MIRAI_COLORED_SHADOWS=1
//! variant color_hw MIRAI_COLORED_SHADOWS=1 MIRAI_HW_RT=1
// Shadows, first pass: one pixel of each block, a different one every frame,
// traces a shadow ray to the sun, to each node of its cut of the local lights
// (lighting.slang): each light that reaches it while they fit in the budget,
// and groups that stand for the far ones when they do not; and to each light
// of extensions, to the point of it the hook gives. The
// ray of a light goes to one of sixteen points of its disc, that of a group
// (along a capsule, across a rectangle: light_point of lighting.slang),
// to one of sixteen picks among its lights and that of the sun to one of
// sixteen directions across its disc: each block of a 4x4 takes one of them,
// the same in every frame (block_turn of lighting.slang), so that the blocks
// of a 4x4 together hold the share of the light its casters leave, and the
// shape of a penumbra, once the filter (shadow_penumbra.comp) smooths them,
// is that of the light seen past them: a low sun draws the end of a long
// shadow out along it. The block keeps the share of the light that reaches
// the pixel, out of what would reach it with nothing in the way, how far its
// penumbras ask to be blurred and the light that reaches it; and whether a
// ray met what casts shadows and changed since the frame before, or a light
// that moved (SHADOW_RAY_MOVED of scene.slang): its history starts again.
//
// The filters of glass with a program wait for it (points.slang): the share
// takes their means, and the resume (params.resume) adds what the exact ones
// change of it.
#define POINTS_SLOT SLOT_POINTS
#define MIRAI_DEFER_FILTERS
#include "lighting.slang"
#include <extension_hooks.slang>
#define MIRAI_GROUP_X 8
#define MIRAI_GROUP_Y 8
#define MIRAI_GROUP_Z 1

// sun_radius: angular radius of the sun, radians. block: pixels along each
// side of a block.
struct Params_Block { uint light_budget; float sun_radius; uint block; uint resume; };
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);
#define GBUFFER_NORMAL SLOT_PASS0
#include "gbuffer.slang"
#include "pixel.slang"
[[vk::binding(SLOT_PASS1, 0)]] Texture2D<float4> g_depth : register(MIRAI_REGISTER(t, SLOT_PASS1), space0);
[[vk::binding(SLOT_PASS2, 0)]] [[vk::image_format("rgba16f")]] RWTexture2D<float4> out_shadow : register(MIRAI_REGISTER(u, SLOT_PASS2), space0);   // rgb share; a: 0 no light faces the pixel, 1 none of its rays met a caster, 2 + the standard deviation of the blur its penumbras ask for, metres; SHADOW_RAY_MOVED more when a ray met what changed
[[vk::binding(SLOT_PASS3, 0)]] [[vk::image_format("rgba16f")]] RWTexture2D<float4> out_geometry : register(MIRAI_REGISTER(u, SLOT_PASS3), space0); // normal and depth the block stands for
[[vk::binding(SLOT_PASS4, 0)]] [[vk::image_format("r16f")]] RWTexture2D<float> out_light : register(MIRAI_REGISTER(u, SLOT_PASS4), space0);         // the luminance of the light that reaches the pixel with nothing in the way, roughly

// No blur reaches further than this, metres.
static const float BLUR_MAX = 0.6;
// The standard deviation of the blur of a penumbra, as a share of its width:
// the blocks see sixteen points of the light, and the blur smooths what a
// thin caster leaves between them.
static const float WIDTH_BLUR = 0.1;

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 dispatch_id : SV_DispatchThreadID, uint3 group : SV_GroupID, uint local : SV_GroupIndex) {
#ifdef MIRAI_FILTER_POINTS
    if (params.resume != 0u) {
        Point_Head head;
        if (!head_of_round(group.x * (MIRAI_GROUP_X * MIRAI_GROUP_Y) + local, head)) return;
        int2 at = int2(head.owner & 0xffffu, head.owner >> 16u);
        float3 change = filters_correction(head.chain);
        float3 inverse = float3(asfloat(head.aux[0]), asfloat(head.aux[1]), asfloat(head.aux[2]));
        float4 held = out_shadow[at];
        float3 share = held.rgb + select(inverse > float3(0.0), change * inverse, float3(luminance(change) * asfloat(head.aux[3])));
        out_shadow[at] = float4(clamp(share, 0.0, 1.0), held.a);
        return;
    }
#endif
    int2 block = int2(dispatch_id.xy);
    int2 size = texture_size(out_shadow);
    if (any(((block) >= (size)))) return;
    int2 full = int2(frame.resolution);
    int span = int(params.block);
    int2 reference = min(block * span, full - 1);
    out_geometry[block] = float4(gbuffer_normal(reference), g_depth.Load(int3(reference, 0)).r);
    out_light[block] = 0.0;
    int2 p = min(block * span + block_pixel(frame.frame_index, params.block), full - 1);
    float depth = g_depth.Load(int3(p, 0)).r;
    if (depth_empty(depth)) { out_shadow[block] = float4(1.0, 1.0, 1.0, 0.0); return; }
    float3 n = gbuffer_normal(p);
    float2 uv = (float2(p) + 0.5) * frame.inv_resolution;
    Pixel pixel = pixel_at(p, uv, depth);
    float3 position = pixel.position;
    float3 origin = offset_origin(position, n, view_bias(pixel.distance));
    float3 reaching = float3(0.0);
    float3 unshadowed = float3(0.0);
    // How far the penumbra of each light asks the share to be blurred,
    // weighed by the light its caster takes.
    float width_sum = 0.0;
    float lost_sum = 0.0;
    bool moved = false;
    uint cut[LIGHT_CUT_MAX];
    uint nodes = light_cut(position, n, params.light_budget, cut);
    // Which of the sixteen points of each light the ray of the block goes to.
    uint turn = block_turn(block);
    float2 shift_spin = light_point_shift(block);
    float shift = shift_spin.x;
    float spin = shift_spin.y;
    // Item 0 is the sun, the nodes follow and then the lights of extensions,
    // whose ray may be two, one after the other: all of them share one
    // traversal in the source, where a call for each would be a copy for each.
    uint items = nodes + 1u;
#ifdef MIRAI_HOOK_LIGHTS
    items += mirai_extension_light_count();
#endif
    for (uint item = 0u; item < items; item++) {
        float3 dir;
        float reach;
        float3 irradiance;
        float radius;
        float3 beyond_origin = float3(0.0), beyond_dir = float3(0.0);
        float beyond_reach = 0.0;
        uint light_index = INVALID;
        if (item > nodes) {
#ifdef MIRAI_HOOK_LIGHTS
            Extension_Light light;
            if (!mirai_extension_light(item - 1u - nodes, origin, n, float2(float(turn) + shift, spin), light)) continue;
            irradiance = light.irradiance;
            radius = light.radius;
            dir = light.direction;
            reach = light.reach;
            beyond_origin = light.beyond_origin;
            beyond_dir = light.beyond_direction;
            beyond_reach = light.beyond_reach;
#endif
        } else if (item == 0u) {
            if (frame.sun_direction.w < 0.5) continue;
            float cosine = dot(n, frame.sun_direction.xyz);
            if (!(cosine > 0.0)) continue;
            irradiance = sun_light(origin) * cosine;
            radius = params.sun_radius;
            dir = sun_ray(float(turn) + shift, spin, radius);
            reach = sun_reach(origin, dir);
        } else {
            Light_Node node = light_nodes[cut[item - 1u]];
            float distance;
            irradiance = node_contribution(node, position, n, dir, distance);
            if (luminance(irradiance) <= LIGHT_CUTOFF) continue;
            radius = node.spread;
            // The ray of a group goes to one of its lights, each about as
            // likely as the light it gives the pixel, and stands for the
            // group with the light of that one over how likely it was.
            float chance;
            uint leaf = node_light(cut[item - 1u], (float(turn) + 0.5) / 16.0, position, n, chance);
            Light_Node target = light_nodes[leaf];
            if ((node.flags & LIGHT_NODE_LEAF) == 0u) {
                float3 towards;
                float far;
                irradiance = light_contribution(lights[target.child], position, n, towards, far) / max(chance, 1e-4);
            }
            uint point = (node.flags & LIGHT_NODE_LEAF) != 0u ? turn : (turn * 5u + 3u) & 15u;
            light_index = target.child;
            Light light = lights[light_index];
            float3 toward = light_point(light, position, float(point) + shift, spin);
            // A point of a capsule or a rectangle under the horizon gives no
            // light: the opposite one of the grid goes instead, and with both
            // under it the ray counts as unblocked.
            bool below = dot(n, toward) <= 0.0;
            if (below && (light_is_rect(light) || light_is_capsule(light))) {
                toward = light_point(light, position, float(15u - point) + 1.0 - shift, spin);
                below = dot(n, toward) <= 0.0;
            } else {
                below = false;
            }
            float far = length(toward);
            dir = toward / max(far, 1e-6);
            reach = below ? 0.0 : light_reach(light, far);
        }
        if (luminance(irradiance) <= 0.0) continue;
        // A light that moved shades anew whatever it reaches.
        if (item == 0u) moved = moved || (frame.moved.z & MOVED_SUN) != 0u;
        else if (light_index != INVALID) moved = moved || light_moved(light_index);
        // The rays of the engine's lights that would cross a gate count as
        // blocked (trace_transmission); those of extensions go through it.
        float path = reach + max(beyond_reach, 0.0);
        float blocker = FLT_MAX;
        float travelled = 0.0;
        float3 from = origin;
        float3 through = float3(1.0);
#ifdef MIRAI_FILTER_POINTS
        filters_begin();
#endif
        for (uint segment = 0u; segment < 2u; segment++) {
            float hit;
            uint stopper;
            through *= trace_transmission_blocker(from, dir, reach, hit, stopper, item <= nodes);
            moved = moved || occluder_changed(from, dir, reach, stopper, hit);
            if (hit < FLT_MAX && blocker == FLT_MAX) blocker = travelled + hit;
            if (segment != 0u || beyond_reach <= 0.0 || max(through.r, max(through.g, through.b)) <= 0.0) break;
            travelled += reach;
            from = beyond_origin;
            dir = beyond_dir;
            reach = beyond_reach;
        }
#ifdef MIRAI_FILTER_POINTS
        filters_weigh(irradiance);
#endif
        unshadowed += irradiance;
        reaching += irradiance * through;
        if (blocker < FLT_MAX) {
            float lost = luminance(irradiance * (1.0 - through));
            // The sun is a direction: its radius is an angle.
            float width = 2.0 * radius * (item == 0u ? blocker : blocker / max(path - blocker, 0.05));
            float blur = WIDTH_BLUR * width;
            width_sum += lost * blur;
            lost_sum += lost;
        }
    }
    float total = luminance(unshadowed);
    out_light[block] = min(total, 6e4);
    if (total <= 0.0) { out_shadow[block] = float4(1.0, 1.0, 1.0, 0.0); return; }
    // A channel the lights do not have takes the share of the whole.
    float whole = luminance(reaching) / total;
    bool3 lit = unshadowed > float3(1e-4 * total);
    float3 share = select(lit, reaching / max(unshadowed, float3(1e-6)), float3(whole));
#ifdef MIRAI_FILTER_POINTS
    // What the share of each channel changes by per unit of light, for the
    // resume: that of the channel, or that of the whole where the channel has none.
    if (filter_chain != INVALID) {
        Point_Head head = point_head(INVALID, filter_chain, uint(block.x) | (uint(block.y) << 16u));
        float3 inverse = select(lit, 1.0 / max(unshadowed, float3(1e-6)), float3(0.0));
        head.aux[0] = asuint(inverse.r);
        head.aux[1] = asuint(inverse.g);
        head.aux[2] = asuint(inverse.b);
        head.aux[3] = asuint(1.0 / total);
        head_append(head);
    }
#endif
    float state = lost_sum > 0.0 ? 2.0 + min(width_sum / lost_sum, BLUR_MAX) : 1.0;
    out_shadow[block] = float4(clamp(share, 0.0, 1.0), moved ? state + SHADOW_RAY_MOVED : state);
}
