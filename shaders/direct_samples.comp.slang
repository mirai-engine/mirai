#include "native.slang"
//! variant hw MIRAI_HW_RT=1
//! variant unlayered MIRAI_GBUFFER_NO_LAYERS=1
//! variant hw_unlayered MIRAI_HW_RT=1 MIRAI_GBUFFER_NO_LAYERS=1
// color: the glass a light crosses colors it (direct_glass), with colored shadows.
//! variant color MIRAI_DIRECT_GLASS=1
//! variant color_hw MIRAI_DIRECT_GLASS=1 MIRAI_HW_RT=1
//! variant unlayered_color MIRAI_DIRECT_GLASS=1 MIRAI_GBUFFER_NO_LAYERS=1
//! variant hw_unlayered_color MIRAI_DIRECT_GLASS=1 MIRAI_HW_RT=1 MIRAI_GBUFFER_NO_LAYERS=1
// The pass of the direct light of a view (direct_samples.slang) that takes
// the samples of each point of the lights no map of the view holds there: of
// those a map holds, direct_maps.comp gave the light before, and this adds to
// it at the points it marked; without maps, all of it. Each
// light that takes some gives its exact light
// with nothing in the way, with the material, once (light_radiance), by the
// share of samples it took against those due to it, and by the part of them
// that got there; a sample of the table of a cell with many lights
// (direct_grid.slang) gives the light it draws over the chance of drawing it.
// Without ray queries the samples meet
// only what stopped the rays of the group and of the groups around
// (direct_rays.comp), and those of a light only what of that stands within the
// cone from the point to it, none where nothing does; with them, each is a ray
// through the whole scene. What it leaves of the local lights: their light
// with nothing in the way over the reflectance, and the part of it that got
// there, plus 2 where a sample met what changed (occluder_changed). Of the sun
// no map holds it leaves only how much of it its samples find, and what the
// glass on the way leaves of it: its light is taken at the pixels
// (direct_filter.comp), whose normals and materials shape it.
#define GBUFFER_ALBEDO SLOT_PASS3
#define GBUFFER_NORMAL SLOT_PASS0
#define SUN_SHADOW_SLOT SLOT_PASS8
#define SHADOW_DATA_SLOT SLOT_PASS9
// The filters of glass with a program wait for it (points.slang): the light
// takes their means, and the resume (params.resume) adds what the exact ones
// change of it.
#ifdef MIRAI_DIRECT_GLASS
#define MIRAI_RAY_FILTERS
#define MIRAI_DEFER_FILTERS
#define POINTS_SLOT SLOT_POINTS
#endif
#include "lighting.slang"
#include "gbuffer.slang"
#include "pixel.slang"
#include "direct_samples.slang"
#define MIRAI_GROUP_X 8
#define MIRAI_GROUP_Y 8
#define MIRAI_GROUP_Z 1

// samples: those of a pixel; sun_radius: angular radius of the sun, radians;
// hard: the shadow rays of a point that traces its own (direct_lighting);
// glass: not 0 where glass colors the light;
// the grid of the lights (render.Light_Grid) and its cells.
struct Params_Block { uint pad0; uint samples; float sun_radius; uint scale; uint hard; uint resume; uint glass; uint pad4; float3 grid_origin; float grid_cell; uint3 grid_size; uint cells;
    // The maps of the shadows of this frame (render.Shadow_Maps).
    uint shadow_on; uint shadow_rows; uint shadow_maps; uint shadow_sun; };
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);
[[vk::binding(SLOT_PASS1, 0)]] Texture2D<float4> g_depth : register(MIRAI_REGISTER(t, SLOT_PASS1), space0);
[[vk::binding(SLOT_PASS2, 0)]] [[vk::image_format("rgba16f")]] RWTexture2D<float4> out_samples : register(MIRAI_REGISTER(u, SLOT_PASS2), space0);
[[vk::binding(SLOT_PASS4, 0)]] Texture2D<uint> blockers : register(MIRAI_REGISTER(t, SLOT_PASS4), space0);
// The linear depth (0 for none) of each point, and the radii of its penumbrae,
// in points, that of the sun (y) and that of the local lights (w): half the
// width of the penumbra of what hid its samples, by the light each brought
// (direct_penumbra); for direct_spread.comp.
[[vk::binding(SLOT_PASS5, 0)]] [[vk::image_format("rgba16f")]] RWTexture2D<float4> out_depth : register(MIRAI_REGISTER(u, SLOT_PASS5), space0);
[[vk::binding(SLOT_PASS6, 0)]] StructuredBuffer<uint4> light_grid : register(MIRAI_REGISTER(t, SLOT_PASS6), space0);
// What the glass on the way leaves of the light of the sun at each point
// (rgb), and how much of the sun gets there (a), below 0 where it gives none.
[[vk::binding(SLOT_PASS7, 0)]] [[vk::image_format("rgba16f")]] RWTexture2D<float4> out_sun : register(MIRAI_REGISTER(u, SLOT_PASS7), space0);
#include "shadow_maps.slang"
#include "direct_grid.slang"

// The weights of the items at the point of each pixel, for the walk after
// their sum (direct_item_weight), two items to a word; those of the same items
// of the pixels side by side, so that a warp reads them from as many banks.
#define GROUP_SIZE uint(MIRAI_GROUP_X * MIRAI_GROUP_Y)
groupshared uint samples_weights[GROUP_SIZE * DIRECT_FEW / 2u];
// Whether a point of the group takes samples.
groupshared uint group_samples;
float samples_weight(uint i, uint index) { return asfloat((samples_weights[(i >> 1u) * GROUP_SIZE + index] << ((i & 1u) != 0u ? 0u : 16u)) & 0xFFFF0000u); }

#ifndef MIRAI_HW_RT
// What stopped the rays of the group and of the eight around, each instance
// once, DIRECT_LIST_MAX at most, found by a table of DIRECT_TABLE slots: its
// sphere, its box and the transform into its own space.
#define DIRECT_LIST_MAX 64u
#define DIRECT_TABLE 256u
groupshared uint list_table[DIRECT_TABLE];
groupshared uint list_count;
groupshared uint list_ids[DIRECT_LIST_MAX];
groupshared uint list_mesh[DIRECT_LIST_MAX];
groupshared float4 list_spheres[DIRECT_LIST_MAX];
groupshared float4 list_lo[DIRECT_LIST_MAX];
groupshared float4 list_hi[DIRECT_LIST_MAX];
groupshared float4 list_inverse[DIRECT_LIST_MAX * 3u];

void list_add(uint id) {
    if (id == DIRECT_NONE) return;
    uint slot = (id * 2654435761u) >> 24u;
    for (uint probe = 0u; probe < DIRECT_TABLE; probe++) {
        uint at = (slot + probe) & (DIRECT_TABLE - 1u);
        uint was;
        InterlockedCompareExchange(list_table[at], INVALID, id, was);
        if (was == id) return;
        if (was != INVALID) continue;
        uint entry;
        InterlockedAdd(list_count, 1u, entry);
        if (entry >= DIRECT_LIST_MAX) return;
        Instance inst = scene_instance(id);
        float3 lo = inst.bounds_min.xyz, hi = inst.bounds_max.xyz;
        list_ids[entry] = id;
        list_mesh[entry] = inst.meta.x | ((inst.meta.w & INSTANCE_FLAG_ALPHA_TESTED) != 0u ? 0x80000000u : 0u);
        list_lo[entry] = float4(lo, 0.0);
        list_hi[entry] = float4(hi, 0.0);
        list_spheres[entry] = float4(0.5 * (lo + hi), 0.5 * length(hi - lo));
        for (uint row = 0u; row < 3u; row++) list_inverse[entry * 3u + row] = inst.world_inv[row];
        return;
    }
}

// The entries whose sphere reaches into the cone from o along `axis` (unit),
// `far` metres, `spread` wide over each metre.
uint2 list_cone(float3 o, float3 axis, float far, float spread) {
    uint2 mask = uint2(0u);
    uint known = min(list_count, DIRECT_LIST_MAX);
    for (uint i = 0u; i < known; i++) {
        float4 sphere = list_spheres[i];
        float3 to = sphere.xyz - o;
        float t = clamp(dot(to, axis), 0.0, far);
        float3 off = to - axis * t;
        float room = sphere.w + spread * t;
        if (dot(off, off) <= room * room) mask[i >> 5u] |= 1u << (i & 31u);
    }
    return mask;
}

uint2 list_all() {
    uint known = min(list_count, DIRECT_LIST_MAX);
    return uint2(known >= 32u ? 0xFFFFFFFFu : (1u << known) - 1u, known >= 64u ? 0xFFFFFFFFu : known > 32u ? (1u << (known - 32u)) - 1u : 0u);
}
#endif

// How far from o what stands between o and o + w * reach is, -1 for nothing:
// of the entries of the list `mask` keeps, or with ray queries anything.
float direct_hit(float3 o, float3 w, float reach, uint2 mask) {
#ifdef MIRAI_HW_RT
    Hit found = trace_ray_impl(o, w, 0.0, reach, true, BLEND_PASSES, RAY_SHADOWS);
    return found.instance != INVALID ? found.t : -1.0;
#else
    float3 inv = safe_inverse(w);
    for (uint word = 0u; word < 2u; word++) {
        uint bits = mask[word];
        while (bits != 0u) {
            uint i = word * 32u + firstbitlow(bits);
            bits &= bits - 1u;
            float4 sphere = list_spheres[i];
            float3 to = sphere.xyz - o;
            float3 off = to - w * clamp(dot(to, w), 0.0, reach);
            if (dot(off, off) > sphere.w * sphere.w) continue;
            float3 lo = (list_lo[i].xyz - o) * inv;
            float3 hi = (list_hi[i].xyz - o) * inv;
            if (max(max(min(lo.x, hi.x), min(lo.y, hi.y)), max(min(lo.z, hi.z), 0.0)) > min(min(max(lo.x, hi.x), max(lo.y, hi.y)), min(max(lo.z, hi.z), reach))) continue;
            float4 inverse[3] = {list_inverse[i * 3u], list_inverse[i * 3u + 1u], list_inverse[i * 3u + 2u]};
            Hit hit;
            hit.t = reach;
            hit.instance = INVALID;
            hit.primitive = INVALID;
            hit.bary = float2(0.0);
            uint mesh = list_mesh[i];
            if (trace_blas(mesh & 0x7FFFFFFFu, transform_point(inverse, o), transform_vector(inverse, w), 0.0, hit, list_ids[i], true, (mesh & 0x80000000u) != 0u, BLEND_PASSES)) return hit.t;
        }
    }
    return -1.0;
#endif
}

// The samples of a light at a point traced first; the rest only at its penumbra.
#define DIRECT_PROBES 4u

// What the glass between o and o + w * reach lets through of a light: the
// product of the filters of the faces it crosses, 1 without glass. plain:
// what the light gives the owner without it, which what the programs of the
// glass change of that product is weighed by (filters_weigh).
float3 direct_glass(float3 o, float3 w, float reach, float3 plain) {
#ifdef MIRAI_DIRECT_GLASS
    if (params.glass != 0u) {
        filters_begin();
        float3 through = trace_glass_filter(o, w, reach);
        filters_weigh(plain);
        return through;
    }
#endif
    return float3(1.0);
}

// The owner of the filter points of the sun of a point, apart from that of
// its local lights: bit 15 of its place.
#define DIRECT_OWNER_SUN 0x8000u

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 group : SV_GroupID, uint index : SV_GroupIndex) {
#ifdef MIRAI_FILTER_POINTS
    if (params.resume != 0u) {
        Point_Head head;
        if (!head_of_round(group.x * GROUP_SIZE + index, head)) return;
        int2 at = int2(head.owner & 0x7FFFu, head.owner >> 16u);
        float3 change = finite_or_zero(filters_correction(head.chain));
        if ((head.owner & DIRECT_OWNER_SUN) != 0u) out_sun[at] = float4(max(out_sun[at].rgb + change, float3(0.0)), out_sun[at].a);
        else out_samples[at] = float4(max(out_samples[at].rgb + change, float3(0.0)), out_samples[at].a);
        return;
    }
#endif
    int scale = int(max(params.scale, 1u));
    int2 p = direct_group_pixel(group.xy, index);
    int2 source = p * scale;
    int2 size = direct_points(scale);
    bool inside = all(p < size);
    // While the view drew maps, the points direct_maps.comp marked; else all.
    bool maps = frame.sun_maps.z != 0u;
    bool sampled = inside;
    if (sampled && maps) sampled = out_depth[p].z < 0.0;
#ifdef MIRAI_HW_RT
    if (!sampled) return;
#else
    if (index == 0u) {
        list_count = 0u;
        group_samples = 0u;
    }
    for (uint i = index; i < DIRECT_TABLE; i += uint(MIRAI_GROUP_X * MIRAI_GROUP_Y)) list_table[i] = INVALID;
    GroupMemoryBarrierWithGroupSync();
    if (sampled) InterlockedOr(group_samples, 1u);
    GroupMemoryBarrierWithGroupSync();
    if (group_samples == 0u) return;
    // What stopped the ray at the place of the pixel in each of the squares of
    // 8x8 pixels around, so that a thin blocker none of the rays of a group met
    // still hides the light its neighbours found it hiding.
    for (int g = 0; g < 9; g++) {
        int2 q = p + int2(g % 3 - 1, g / 3 - 1) * 8;
        if (all(q >= 0) && all(q < size)) list_add(blockers.Load(int3(q, 0)) & ~DIRECT_CHANGED);
    }
    // What moved since the frame before, which rays of earlier frames did not
    // meet where it is now: the samples whose cone reaches it test it.
    GroupMemoryBarrierWithGroupSync();
    if (index < frame.moved.x) {
        uint moved = asuint(frame.moved_boxes[2u * index].w);
        if (moved < frame.instance_count && (scene_instance(moved).meta.w & (INSTANCE_FLAG_HIDDEN | INSTANCE_FLAG_BLENDED)) == 0u) list_add(moved);
    }
    GroupMemoryBarrierWithGroupSync();
#endif
    if (!sampled) return;
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
    bool changes = frame.moved.x > 0u;
    float spin = direct_spin(p);
    uint stopped = blockers.Load(int3(p, 0));
    bool marked = (stopped & DIRECT_CHANGED) != 0u;
    // The traced sample got there when nothing stopped it.
    bool traced_open = (stopped & ~DIRECT_CHANGED) == DIRECT_NONE;
    uint4 row = direct_cell(pixel.position);
    uint count = direct_items(row);
    // The sun: where a map of the view holds the point, direct_maps.comp gave
    // how much of it gets there; elsewhere it takes samples as a light more,
    // for that alone.
    float sun = direct_sun_weight(pixel.position, normal);
    float3 sun_glass = float3(1.0);
    float sun_part = -1.0, sun_wide = 0.0;
    uint sun_chain = INVALID;
    bool sun_given = false;
    if (sun > 0.0) {
        Shadow_Map held;
        sun_given = sun_map_of(pixel.position, held);
        if (!sun_given) sun_glass = direct_glass(origin, frame.sun_direction.xyz, 1e5, float3(1.0));
#ifdef MIRAI_FILTER_POINTS
        sun_chain = filter_chain;
        filter_chain = INVALID;
#endif
        if (sun_given) sun = 0.0;
    }
    float total = sun;
    for (uint i = 0u; i < count; i++) {
        float w = direct_sampled_weight(row, direct_item(row, i), pixel.position, normal);
        uint bits = asuint(w) >> 16u;
        if ((i & 1u) == 0u) samples_weights[(i >> 1u) * GROUP_SIZE + index] = bits;
        else samples_weights[(i >> 1u) * GROUP_SIZE + index] |= bits << 16u;
        total += w;
    }
    float3 open = float3(0.0), lit = float3(0.0);
    float wide = 0.0, hid = 0.0;
    if (total > 0.0) {
        uint m = max(params.samples, 1u);
        uint place = direct_place(p);
        uint traced = direct_traced(p, m);
        float step = total / float(m);
        float next = direct_start(place) * step;
        float upto = 0.0;
        uint k = 0u, i = 0u;
        // A run of the samples of an item at each step, so that the pixels of a
        // warp, which take samples of different items, take their runs together;
        // the sun after the items of the cell.
        while (k < m) {
            uint item = INVALID, first = k;
            float w = 0.0;
            while (i <= count) {
                item = i < count ? direct_item(row, i) : INVALID;
                w = i < count ? samples_weight(i, index) : sun;
                i++;
                upto += w;
                first = k;
                while (k < m && next < upto) {
                    k++;
                    next += step;
                }
                if (k > first && w > 0.0) break;
            }
            if (k == first || !(w > 0.0)) break;
            // What a sample of the item stands for.
            float factor = total / (float(m) * w);
            if (item != DIRECT_CELL_TABLE) {
                // One light: its exact light once, by the part of its samples that got
                // there. The sun without a map: only how much of it its samples find.
                bool of_sun = item == INVALID;
                float3 radiance = float3(0.0), axis;
                float far, spread;
                if (of_sun) {
                    axis = frame.sun_direction.xyz;
                    far = 1e5;
                    spread = params.sun_radius;
                } else {
                    Light chosen = lights[item];
                    radiance = light_radiance(chosen, s, axis, far);
                    spread = light_extent(chosen) / max(far, 1e-4);
                    if (!(luminance(radiance) > 0.0)) continue;
                    // The glass on the way colors all of it, lit or hidden.
                    radiance *= direct_glass(origin, axis, far, radiance * (float(k - first) * factor) / reflectance);
                }
                float3 share = radiance * (float(k - first) * factor);
                open += share;
                if (changes && !of_sun && light_moved(item)) marked = true;
                // Its samples stay within the cone from the point to the light:
                // what changed reaches them only through it, and the list holds
                // what moved, so that one with nothing of it in the cone is lit.
                if (changes && !marked) marked = occluder_changed_in_cone(origin, axis, far, spread);
                bool traced_here = traced >= first && traced < k;
#ifdef MIRAI_HW_RT
                uint2 mask = uint2(0u);
#else
                uint2 mask = list_cone(origin, axis, far, spread);
                if (all(mask == 0u) && (!traced_here || traced_open)) {
                    if (of_sun) sun_part = 1.0;
                    lit += share;
                    continue;
                }
#endif
                // The first rays go to strata spread over the light, the
                // sample traced by direct_rays.comp among them where it falls;
                // only where they disagree, at a penumbra, do the others go.
                uint run = k - first;
                uint probes = run > 128u ? run : min(DIRECT_PROBES, run);
                uint4 done = uint4(0u);
                float seen = 0.0, met = 0.0, hidden = 0.0, hidden_wide = 0.0;
                for (uint round = 0u; round < 2u; round++) {
                    uint rays = round == 0u ? probes : run;
                    for (uint j = 0u; j < rays; j++) {
                        uint at = round == 0u ? (j * run) / probes : j;
                        if (round == 0u && traced_here && (j + 1u) * run / probes > traced - first && at <= traced - first) at = traced - first;
                        if (round != 0u && at < 128u && (done[at >> 5u] & (1u << (at & 31u))) != 0u) continue;
                        if (at < 128u) done[at >> 5u] |= 1u << (at & 31u);
                        uint q = first + at;
                        float3 direction;
                        float reach;
                        direct_ray(item, pixel.position, origin, direct_point(place, m, q), spin, params.sun_radius, direction, reach);
                        if (!(dot(direction, normal) > 0.0)) continue;
                        met += 1.0;
                        if (q == traced) {
                            if (traced_open) seen += 1.0;
                            continue;
                        }
                        float near = direct_hit(origin, direction, reach, mask);
                        if (near < 0.0) {
                            seen += 1.0;
                        } else {
                            hidden_wide += direct_penumbra(item, reach, near, params.sun_radius);
                            hidden += 1.0;
                        }
                    }
                    if (seen == 0.0 || seen == met) break;
                }
                if (of_sun) {
                    sun_part = met > 0.0 ? seen / met : 1.0;
                    sun_wide = hidden > 0.0 ? hidden_wide / hidden : 0.0;
                    continue;
                }
                float unit = luminance(share) / max(met, 1.0);
                wide += unit * hidden_wide;
                hid += unit * hidden;
                lit += share * (met > 0.0 ? seen / met : 1.0);
            } else {
                // The table of the cell: each sample the light it draws, over the chance of drawing it.
#ifdef MIRAI_HW_RT
                uint2 mask = uint2(0u);
#else
                uint2 mask = list_all();
#endif
                for (uint q = first; q < k; q++) {
                    float chance;
                    uint light = direct_table_draw(row, (float(q - first) + direct_start(place)) / float(k - first), chance);
                    float3 direction, toward;
                    float reach, distance;
                    direct_ray(light, pixel.position, origin, direct_point(place, m, q), spin, params.sun_radius, direction, reach);
                    float3 add = light_radiance(lights[light], s, toward, distance) * (factor / max(chance, 1e-6));
                    if (!(luminance(add) > 0.0)) continue;
                    add *= direct_glass(origin, toward, distance, add / reflectance);
                    open += add;
                    if (changes && !marked) marked = light_moved(light) || (q != traced && occluder_changed(origin, direction, reach, INVALID, reach));
                    float near = q == traced ? -1.0 : direct_hit(origin, direction, reach, mask);
                    if (near >= 0.0) {
                        wide += luminance(add) * direct_penumbra(light, reach, near, params.sun_radius);
                        hid += luminance(add);
                    } else if (q != traced || traced_open) {
                        lit += add;
                    }
                }
            }
        }
    }
#ifdef MIRAI_FILTER_POINTS
    uint place_of = uint(p.x) | (uint(p.y) << 16u);
    if (sun_chain != INVALID) head_append(point_head(INVALID, sun_chain, place_of | DIRECT_OWNER_SUN));
    if (filter_chain != INVALID) head_append(point_head(INVALID, filter_chain, place_of));
#endif
    float seen = luminance(lit);
    float4 given_depth = float4(0.0);
    if (maps) {
        // What direct_maps.comp gave of the lights maps hold here, how much of
        // it is hidden at a penumbra and how wide those are (its out_depth).
        float4 given = out_samples[p];
        given_depth = out_depth[p];
        float3 light = given.rgb * reflectance;
        float given_part = given.a >= 1.5 ? given.a - 2.0 : given.a;
        marked = marked || given.a >= 1.5;
        float hidden = (-given_depth.z - 1.0) * luminance(light);
        wide += hidden * given_depth.w;
        hid += hidden;
        open += light;
        seen += given_part * luminance(light);
    }
    float part = luminance(open) > 0.0 ? saturate(seen / luminance(open)) : 1.0;
    out_samples[p] = float4(finite_or_zero(open / reflectance), (isfinite(part) ? part : 1.0) + (marked ? 2.0 : 0.0));
    // The reach of the spread over each penumbra, in points, and half a point.
    float width = float(scale) * (frame.footprint.x + frame.footprint.y * depth_distance(depth));
    float radius = hid > 0.0 ? min(DIRECT_SPREAD_REACH * wide / (hid * width) + 0.5, float(DIRECT_SPREAD_MAX)) : 0.0;
    float sun_radius = sun_part >= 0.0 && sun_wide > 0.0 ? min(DIRECT_SPREAD_REACH * sun_wide / width + 0.5, float(DIRECT_SPREAD_MAX)) : 0.0;
    // The sun a map holds, as direct_maps.comp left it.
    if (sun_given) {
        sun_radius = given_depth.y;
    } else {
        out_sun[p] = float4(sun_glass, isfinite(sun_part) ? sun_part : 1.0);
    }
    out_depth[p] = float4(depth_distance(depth), isfinite(sun_radius) ? sun_radius : 0.0, 0.0, isfinite(radius) ? radius : 0.0);
}
