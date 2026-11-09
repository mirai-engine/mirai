#include "native.slang"
//! variant hw MIRAI_HW_RT=1
// The first pass of the direct light of a view (direct_samples.slang), a
// thread for each square of 2x2 pixels: its
// first pixel (direct_traces) traces through the whole scene the one of its
// samples its place in its group says, leaving what stopped it for the samples
// of the group and of the groups around to meet; the other three, nothing.
#define GBUFFER_NORMAL SLOT_PASS0
#include "lighting.slang"
#include "gbuffer.slang"
#include "pixel.slang"
#include "direct_samples.slang"
#include "shadow_maps.slang"
#define MIRAI_GROUP_X 8
#define MIRAI_GROUP_Y 8
#define MIRAI_GROUP_Z 1

// samples: those of a pixel; sun_radius: angular radius of the sun, radians;
// hard: the shadow rays of a point that traces its own (direct_lighting); the
// grid of the lights (render.Light_Grid) and its cells.
struct Params_Block { uint pad0; uint samples; float sun_radius; uint scale; uint hard; uint mode; uint pad3; uint pad4; float3 grid_origin; float grid_cell; uint3 grid_size; uint cells; };
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);
[[vk::binding(SLOT_PASS1, 0)]] Texture2D<float4> g_depth : register(MIRAI_REGISTER(t, SLOT_PASS1), space0);
// What stopped the ray of each pixel (DIRECT_NONE, DIRECT_CHANGED).
[[vk::binding(SLOT_PASS2, 0)]] [[vk::image_format("r32ui")]] RWTexture2D<uint> out_blockers : register(MIRAI_REGISTER(u, SLOT_PASS2), space0);
[[vk::binding(SLOT_PASS6, 0)]] StructuredBuffer<uint4> light_grid : register(MIRAI_REGISTER(t, SLOT_PASS6), space0);
#include "direct_grid.slang"

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 dispatch_id : SV_DispatchThreadID) {
    int scale = int(max(params.scale, 1u));
    int2 p = int2(dispatch_id.xy * 2u);
    int2 source = p * scale;
    int2 size = direct_points(scale);
    if (any(p >= size)) return;
    for (uint other = 1u; other < 4u; other++) {
        int2 q = p + int2(int(other & 1u), int(other >> 1u));
        if (all(q < size)) out_blockers[q] = DIRECT_NONE;
    }
    float depth = g_depth.Load(int3(source, 0)).r;
    if (depth_empty(depth)) {
        out_blockers[p] = DIRECT_NONE;
        return;
    }
    Pixel pixel = pixel_at(source, (float2(source) + 0.5) * frame.inv_resolution, depth);
    float3 normal = gbuffer_normal(source);
    uint4 row = direct_cell(pixel.position);
    uint count = direct_items(row);
    // The weights of the items and of the sun, the sun last; none where a map tells of it.
    float sun = direct_sun_weight(pixel.position, normal);
    Shadow_Map held;
    if (sun > 0.0 && sun_map_of(pixel.position, held)) sun = 0.0;
    float total = sun;
    for (uint i = 0u; i < count; i++) {
        total += direct_item_weight(row, direct_item(row, i), pixel.position, normal);
    }
    uint m = max(params.samples, 1u);
    if (!(total > 0.0)) {
        out_blockers[p] = DIRECT_NONE;
        return;
    }
    uint traced = direct_traced(p, m);
    uint place = direct_place(p);
    // The item of the traced sample, by the walk of direct_samples.comp, step for step.
    float step = total / float(m);
    float next = direct_start(place) * step;
    float upto = 0.0;
    uint k = 0u;
    uint item = INVALID;
    uint first = 0u;
    bool found = false;
    for (uint i = 0u; i <= count && k < m; i++) {
        float w = i < count ? direct_item_weight(row, direct_item(row, i), pixel.position, normal) : sun;
        upto += w;
        first = k;
        while (k < m && next < upto) {
            k++;
            next += step;
        }
        if (traced >= first && traced < k) {
            item = i < count ? direct_item(row, i) : INVALID;
            found = w > 0.0;
            break;
        }
    }
    if (!found) {
        out_blockers[p] = DIRECT_NONE;
        return;
    }
    uint light = item;
    if (item == DIRECT_CELL_TABLE) {
        float chance;
        light = direct_table_draw(row, (float(traced - first) + direct_start(place)) / float(k - first), chance);
    }
    float3 origin = offset_origin(pixel.position, normal, view_bias(pixel.distance));
    float3 direction;
    float reach;
    direct_ray(light, pixel.position, origin, direct_point(place, m, traced), direct_spin(p), params.sun_radius, direction, reach);
    Hit hit = trace_ray_impl(origin, direction, 0.0, reach, true, BLEND_PASSES, RAY_SHADOWS);
    bool changed = occluder_changed(origin, direction, reach, hit.instance, hit.instance == INVALID ? reach : hit.t) || (light != INVALID && light_moved(light));
    out_blockers[p] = (hit.instance == INVALID ? DIRECT_NONE : min(hit.instance, DIRECT_NONE - 1u)) | (changed ? DIRECT_CHANGED : 0u);
}
