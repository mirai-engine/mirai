#include "native.slang"
// unlayered: while no instance with layers is in sight (gbuffer.slang).
//! constant unlayered MIRAI_GBUFFER_NO_LAYERS
// The first pass of the direct light of a view (direct_samples.slang), while
// the view drew maps (Frame.sun_maps.z): the light of each point from the sun
// and the local lights a map of the view holds there, each once and exact,
// without samples or rays: its light with nothing in the way, through the
// glass the tint of its map keeps (shadow_tint), by the part its map says gets
// there. A point some light no map holds lights is marked for
// direct_samples.comp (out_depth.z below 0), which adds the light of its
// samples to this; the others it leaves as they are.
#define GBUFFER_ALBEDO SLOT_PASS3
#define GBUFFER_NORMAL SLOT_PASS0
#define SUN_SHADOW_SLOT SLOT_PASS8
#define SHADOW_DATA_SLOT SLOT_PASS9
#define SHADOW_TINT_SLOT SLOT_PASS4
#include "lighting.slang"
#include "gbuffer.slang"
#include "pixel.slang"
#include "direct_samples.slang"
#define MIRAI_GROUP_X 8
#define MIRAI_GROUP_Y 8
#define MIRAI_GROUP_Z 1

// Those of direct_samples.comp.
struct Params_Block { uint pad0; uint samples; float sun_radius; uint scale; uint hard; uint resume; uint glass; uint pad4; float3 grid_origin; float grid_cell; uint3 grid_size; uint cells;
    uint shadow_on; uint shadow_rows; uint shadow_maps; uint shadow_sun; };
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);
[[vk::binding(SLOT_PASS1, 0)]] Texture2D<float4> g_depth : register(MIRAI_REGISTER(t, SLOT_PASS1), space0);
// As direct_samples.comp leaves them; at a point it adds to, out_depth.z holds
// -1 less the part of the light of this pass that is hidden at a penumbra, and
// w the mean width of those penumbrae, metres.
[[vk::binding(SLOT_PASS2, 0)]] [[vk::image_format("rgba16f")]] RWTexture2D<float4> out_samples : register(MIRAI_REGISTER(u, SLOT_PASS2), space0);
[[vk::binding(SLOT_PASS5, 0)]] [[vk::image_format("rgba16f")]] RWTexture2D<float4> out_depth : register(MIRAI_REGISTER(u, SLOT_PASS5), space0);
[[vk::binding(SLOT_PASS6, 0)]] StructuredBuffer<uint4> light_grid : register(MIRAI_REGISTER(t, SLOT_PASS6), space0);
[[vk::binding(SLOT_PASS7, 0)]] [[vk::image_format("rgba16f")]] RWTexture2D<float4> out_sun : register(MIRAI_REGISTER(u, SLOT_PASS7), space0);
#include "shadow_maps.slang"
#include "direct_grid.slang"

// Tap i of count over an ellipse of radii texels around a point, its first
// radius along axis: the point itself, then a spiral turned by spin.
float2 shadow_tap(uint i, uint count, float spin, float2 radii, float2 axis) {
    if (i == 0u) return float2(0.0);
    float a = float(i) * 2.39996323 + spin;
    float2 disc = float2(cos(a), sin(a)) * sqrt((float(i) - 0.5) / float(count)) * radii;
    return axis * disc.x + float2(-axis.y, axis.x) * disc.y;
}

// What map m of a light (the sun for sun) says of a point at position with
// normal n, towards the light along `toward`: 1 where the taps around it see
// past all that could hide a part of the light, or where the point turns from
// it; 0 where they all meet something nearer; where they disagree, at a
// penumbra, its hard shadow (shadow_hard_seen), which direct_spread.comp
// averages over the width of the penumbra the blockers the taps met cast
// there, to both sides of its border. radius: of the light, metres, or the
// angle of the sun; spin: how the taps are turned at the point; across: the
// width of the point across the view, metres. On its surface the point
// stretches by as much as the surface turns from the eye, along the way the
// view goes over it: where that is wider than the penumbra (ground seen at a
// grazing angle far away) the share of that ellipse that is lit, which the
// jitter of the view does not move as it moves the hard shadow at the point;
// only the ellipse, never the wider disc the blockers are searched in, which
// would light the inside of a narrow shadow. spread: the width of the
// penumbra of what hides a point that is not lit.
float shadow_map_seen(Shadow_Map m, bool sun, float3 toward, float3 position, float3 n, float radius, float spin, float across, float grow, out float spread) {
    spread = 0.0;
    Shadow_Taps t;
    if (!shadow_map_taps(m, sun, toward, position, n, radius, across, grow, t)) return 1.0;
    // The least half width of a penumbra, metres at the point.
    float least = SHADOW_PENUMBRA_MIN * t.grow * t.step;
    uint taps = 0u, blocked = 0u, hiding = 0u;
    float blockers = 0.0;
    for (uint i = 0u; i <= SHADOW_TAPS; i++) {
        float2 off = shadow_tap(i, SHADOW_TAPS, spin, t.radii, t.axis);
        // A tap no page holds tells nothing, as one past the square.
        float b;
        uint coarser;
        if (!shadow_blocker(m, int2(floor(t.texel + off)), b, coarser)) continue;
        taps++;
        float apart = length(off) * t.step;
        if (!shadow_blocks(t, b, off, coarser)) continue;
        blocked++;
        // A blocker hides a part of the light only within the penumbra it casts on the point.
        float width = sun ? radius * (t.d - b) : radius * (t.d - b) / max(b, 1e-3);
        if (apart > max(max(width, least), t.covered * t.step) + t.step) continue;
        hiding++;
        blockers += b;
    }
    if (taps == 0u || hiding == 0u) return 1.0;
    float b = blockers / float(hiding);
    spread = sun ? 2.0 * radius * (t.d - b) : 2.0 * radius * (t.d - b) / (b + radius);
    if (blocked == taps) return 0.0;
    if (!(t.covered > max(0.5 * spread / t.step, SHADOW_PENUMBRA_MIN * t.grow))) return shadow_hard_seen(m, t);
    // The share of the ellipse of the point that is lit.
    float2 ellipse = float2(t.covered, max(SHADOW_WIDE_COVER * 0.5 * across / t.step, 0.5));
    uint inside = 0u, lit = 0u;
    for (uint i = 0u; i <= SHADOW_WIDE_TAPS; i++) {
        float2 off = shadow_tap(i, SHADOW_WIDE_TAPS, spin, ellipse, t.axis);
        float b;
        uint coarser;
        if (!shadow_blocker(m, int2(floor(t.texel + off)), b, coarser)) continue;
        inside++;
        if (!shadow_blocks(t, b, off, coarser)) lit++;
    }
    return inside > 0u ? float(lit) / float(inside) : 1.0;
}

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 dispatch_id : SV_DispatchThreadID) {
    int scale = int(max(params.scale, 1u));
    int2 p = int2(dispatch_id.xy);
    int2 size = direct_points(scale);
    if (any(p >= size)) return;
    int2 source = p * scale;
    float depth = g_depth.Load(int3(source, 0)).r;
    if (depth_empty(depth)) {
        out_depth[p] = float4(0.0);
        out_samples[p] = float4(0.0, 0.0, 0.0, 1.0);
        out_sun[p] = float4(1.0, 1.0, 1.0, -1.0);
        return;
    }
    float2 uv = (float2(source) + 0.5) * frame.inv_resolution;
    Pixel pixel = pixel_at(source, uv, depth);
    float3 normal = gbuffer_normal(source);
    Shading s = gbuffer_shading(gbuffer_read(source), pixel);
    float3 reflectance = max(s.diffuse + specular_albedo(s), float3(0.02));
    float3 origin = offset_origin(pixel.position, normal, view_bias(pixel.distance));
    uint4 row = direct_cell(pixel.position);
    uint count = direct_items(row);
    // A glass with a program in the way of a light a map holds here: the
    // samples take all of the point, through rays that run the program.
    float across = float(scale) * (frame.footprint.x + frame.footprint.y * depth_distance(depth));
    if (frame.sun_maps.w != 0u) {
        Shadow_Map m;
        bool programmed = direct_sun_weight(pixel.position, normal) > 0.0 && sun_map_of(pixel.position, m) && sun_map_given(pixel.position, across) && shadow_tint_programmed(m, pixel.position);
        for (uint i = 0u; i < count && !programmed; i++) {
            uint item = direct_item(row, i);
            programmed = item != DIRECT_CELL_TABLE && light_map_of(item, pixel.position, m) && shadow_map_held(m, pixel.position) && shadow_tint_programmed(m, pixel.position);
        }
        if (programmed) {
            out_samples[p] = float4(0.0, 0.0, 0.0, 1.0);
            out_sun[p] = float4(1.0, 1.0, 1.0, -1.0);
            out_depth[p] = float4(depth_distance(depth), DIRECT_MAPS_NONE, -1.0, 0.0);
            return;
        }
    }
    bool changes = frame.moved.x > 0u;
    float spin = direct_spin(p);
    bool marked = false;
    // Whether a light no map holds here gives the point some.
    bool rest = false;
    float sun = direct_sun_weight(pixel.position, normal);
    float sun_part = -1.0, sun_wide = 0.0;
    Sun_Pick pick;
    if (sun > 0.0 && sun_pick(pixel.position, across, pick)) {
        // Its level, or the coarser one drawn where its page is not; over the
        // top of the octave of its level, blended into the next.
        Shadow_Map held = sun_level(pick.level);
        if (shadow_map_held(held, pixel.position)) {
            bool own = held.rect.x == pick.level;
            sun_part = shadow_map_seen(held, true, frame.sun_direction.xyz, pixel.position, normal, params.sun_radius, spin, across, own ? pick.grow : 1.0, sun_wide);
            Shadow_Map next = sun_level(pick.level + 1u);
            float wide;
            if (own && pick.blend > 0.0 && shadow_map_held(next, pixel.position)) {
                float part = shadow_map_seen(next, true, frame.sun_direction.xyz, pixel.position, normal, params.sun_radius, spin, across, 1.0, wide);
                sun_part = lerp(sun_part, part, pick.blend);
                sun_wide = lerp(sun_wide, wide, pick.blend);
            }
            if (changes) marked = occluder_changed_in_cone(origin, frame.sun_direction.xyz, 1e5, params.sun_radius);
        } else {
            rest = true;
        }
    } else if (sun > 0.0) {
        rest = true;
    }
    float3 open = float3(0.0), lit = float3(0.0);
    float wide = 0.0, hid = 0.0;
    for (uint i = 0u; i < count; i++) {
        uint item = direct_item(row, i);
        Shadow_Map m;
        if (item == DIRECT_CELL_TABLE || !light_map_of(item, pixel.position, m) || !shadow_map_held(m, pixel.position)) {
            rest = rest || direct_item_weight(row, item, pixel.position, normal) > 0.0;
            continue;
        }
        Light chosen = lights[item];
        float3 axis;
        float far;
        float3 radiance = light_radiance(chosen, s, axis, far);
        if (!(luminance(radiance) > 0.0)) continue;
        radiance *= shadow_tint(m, pixel.position);
        open += radiance;
        float radius = light_extent(chosen);
        if (changes && !marked) marked = light_moved(item) || occluder_changed_in_cone(origin, axis, far, radius / max(far, 1e-4));
        float spread;
        lit += radiance * shadow_map_seen(m, false, axis, pixel.position, normal, radius, spin, across, 1.0, spread);
        // Within the penumbra of what its taps met, on its lit side as on the other.
        if (spread > 0.0) {
            wide += luminance(radiance) * spread;
            hid += luminance(radiance);
        }
    }
    float shown = luminance(open);
    float part = shown > 0.0 ? saturate(luminance(lit) / shown) : 1.0;
    out_samples[p] = float4(finite_or_zero(open / reflectance), (isfinite(part) ? part : 1.0) + (marked ? 2.0 : 0.0));
    out_sun[p] = float4(1.0, 1.0, 1.0, isfinite(sun_part) ? sun_part : 1.0);
    // The reach of the spread over each penumbra, in points, and half a point.
    float width = float(scale) * (frame.footprint.x + frame.footprint.y * depth_distance(depth));
    float sun_radius = sun_part >= 0.0 && sun_wide > 0.0 ? min(DIRECT_SPREAD_REACH * sun_wide / width + 0.5, float(DIRECT_SPREAD_MAX)) : 0.0;
    sun_radius = isfinite(sun_radius) ? sun_radius : 0.0;
    if (rest) {
        float hidden = shown > 0.0 ? saturate(hid / shown) : 0.0;
        float mean = hid > 0.0 ? wide / hid : 0.0;
        out_depth[p] = float4(depth_distance(depth), sun_radius, -1.0 - (isfinite(hidden) ? hidden : 0.0), isfinite(mean) ? mean : 0.0);
        return;
    }
    float radius = hid > 0.0 ? min(DIRECT_SPREAD_REACH * wide / (hid * width) + 0.5, float(DIRECT_SPREAD_MAX)) : 0.0;
    out_depth[p] = float4(depth_distance(depth), sun_radius, 0.0, isfinite(radius) ? radius : 0.0);
}
