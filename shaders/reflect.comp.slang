#include "native.slang"
// The camera looks along its rays: they show a relative emission (hit_emission).
#define MIRAI_HITS_SHOW_RELATIVE_EMISSION 1
//! variant hw MIRAI_HW_RT=1
//! variant color MIRAI_GLASS_MEANS=1
//! variant color_hw MIRAI_GLASS_MEANS=1 MIRAI_HW_RT=1
// unlayered: while no instance of the scene has layers (gbuffer.slang, scene.slang).
//! variant unlayered MIRAI_GBUFFER_NO_LAYERS=1 MIRAI_MATERIAL_NO_LAYERS=1
//! variant unlayered_hw MIRAI_GBUFFER_NO_LAYERS=1 MIRAI_MATERIAL_NO_LAYERS=1 MIRAI_HW_RT=1
//! variant unlayered_color MIRAI_GBUFFER_NO_LAYERS=1 MIRAI_MATERIAL_NO_LAYERS=1 MIRAI_GLASS_MEANS=1
//! variant unlayered_color_hw MIRAI_GBUFFER_NO_LAYERS=1 MIRAI_MATERIAL_NO_LAYERS=1 MIRAI_GLASS_MEANS=1 MIRAI_HW_RT=1
// Traced specular reflections. A pixel smoother than the roughness limit
// picks a direction of its GGX lobe (the visible normals of Heitz 2018, with
// the tail of the lobe cut short to keep the noise down), traces
// it through the scene and shades what it hits like any other ray hit:
// emission, sun and local lights with shadows, probe volume. A near mirror
// traces its one direction and needs no spatial filtering. The resolve pass
// also accumulates sampled lighting when the exact light budget is exceeded.
//
// The pass runs once per size of block: with a block of 1 every pixel of its
// roughness range traces; with a block of 2 one pixel of each 2x2 traces for
// the four, a different one every frame.
//
// A reflection sharp enough for it to show (params.detail_below) also has the
// glass its ray crosses, as the color filter it is, and the gloss of what it
// finds; the others, the mean filter of that glass.
//
// A hit on a material with a program waits for it (points.slang): the cell
// keeps what the glass on the way leaves and how far the hit is, and the
// resume (params.resume) shades the hit from what the program gave there.
// The exact filters of glass with a program are added then too.
#define MIRAI_RAY_FILTERS
#define POINTS_SLOT SLOT_POINTS
#define MIRAI_DEFER_FILTERS
#include "lighting.slang"
#include <extension_hooks.slang>
#define MIRAI_GROUP_X 8
#define MIRAI_GROUP_Y 8
#define MIRAI_GROUP_Z 1

// cached_below: a pixel that reflects less than this share of what its ray
// finds takes the light of the hit from the probe volume (glass, which
// reflects a few percent away from grazing angles). material_roughness: the
// roughness by which a pixel decides how to trace is the one of its material
// (g_motion.b) rather than the one specular antialiasing widened (a layer of
// glass has only the latter). faint_below: a reflection this faint (glass
// seen face on) traces one turn of its block in four. resume: a thread for
// each head of the round of the batch, instead of each cell.
struct Params_Block { uint light_budget; float max_distance; float firefly_clamp; float pixel_spread; uint block; float roughness_from; float roughness_to; float cached_below; float detail_below; uint stored_reflectance; uint material_roughness; float faint_below; uint resume; uint pad0; uint pad1; uint pad2; };
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);
#define GBUFFER_NORMAL SLOT_PASS0
#define GBUFFER_ALBEDO SLOT_PASS3
#include "gbuffer.slang"
#include "pixel.slang"
[[vk::binding(SLOT_PASS1, 0)]] Texture2D<float4> g_depth : register(MIRAI_REGISTER(t, SLOT_PASS1), space0);
[[vk::binding(SLOT_PASS2, 0)]] [[vk::image_format("rgba16f")]] RWTexture2D<float4> out_radiance : register(MIRAI_REGISTER(u, SLOT_PASS2), space0); // rgb radiance, a hit distance (negative: not traced)
[[vk::binding(SLOT_PASS4, 0)]] Texture2D<float4> g_motion : register(MIRAI_REGISTER(t, SLOT_PASS4), space0); // b roughness of the material

// How the hit of a cell is shaded (Point_Head.aux of a waiting one).
#define SHADE_DETAILED 1u
#define SHADE_CACHED 2u

float3 firefly_clamped(float3 radiance) {
    float l = luminance(radiance);
    return finite_or_zero(l > params.firefly_clamp ? radiance * (params.firefly_clamp / l) : radiance);
}

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 dispatch_id : SV_DispatchThreadID, uint3 group : SV_GroupID, uint local : SV_GroupIndex) {
    int2 cell;
    Surface s;
    float3 direction;
    float distance;
    uint how;
    // What multiplies the light of the hit: the glass on the way.
    float3 through;
    if (params.resume != 0u) {
        Point_Head head;
        if (!head_of_round(group.x * (MIRAI_GROUP_X * MIRAI_GROUP_Y) + local, head)) return;
        cell = int2(head.owner & 0xffffu, head.owner >> 16u);
        float4 held = out_radiance[cell];
        distance = held.a;
        if (head.point == INVALID) {
            // The hit was shaded: what the exact filters change of it.
            out_radiance[cell] = float4(firefly_clamped(held.rgb + filters_correction(head.chain)), distance);
            return;
        }
        through = held.rgb + filters_correction(head.chain);
        Material_Point point = point_load(head.point);
        s = surface_from_hit(hit_point(point.instance, point.primitive, point.bary, point.footprint), point_record_given(head.point), point_record_load(head.point));
        direction = unpack_normal(head.aux[0]);
        how = head.aux[1];
    } else {
        cell = int2(dispatch_id.xy);
        int2 size = int2(frame.resolution);
        int2 p = cell * int(params.block);
        if (any(((p) >= (size)))) return;
        if (params.block > 1u) p = min(p + block_pixel(frame.frame_index, 2u), size - 1);
        float depth = g_depth.Load(int3(p, 0)).r;
        // A layer of glass always keeps its reflectance; the opaque G-buffer, when the scene needs it.
        Gbuffer_Pixel g = gbuffer_read(p, params.stored_reflectance != 0u);
        float roughness = (params.material_roughness != 0u ? g_motion.Load(int3(p, 0)).b : g.roughness) + ROUGHNESS_ROUNDING;
        // The view leaves a solid at an exit face of glass: what it reflects there is inside, which the glass pass traces.
        if (depth_empty(depth) || reflection_weight(roughness) <= 0.0 || roughness < params.roughness_from || roughness >= params.roughness_to || (g.bits & GBUFFER_GLASS_EXIT) != 0u) {
            out_radiance[cell] = float4(0.0, 0.0, 0.0, -1.0);
            return;
        }
        float2 uv = (float2(p) + 0.5) * frame.inv_resolution;
        Pixel pixel = pixel_at(p, uv, depth);
        float3 position = pixel.position;
        float3 view = pixel.view;
        // The lobe the G-buffer chose to trace: the coat's, or the base's, which may be anisotropic.
        bool coat = (g.bits & GBUFFER_TRACE_COAT) != 0u;
        float3 n = coat ? g.layers.coat_normal : g.normal;
        float widened = coat ? g.layers.coat_roughness : g.roughness;
        uint seed = seed_for(uint2(p), frame.frame_index, 17u);
        float3 dir = reflect(view, n);
        if (roughness > MIRROR_ROUGHNESS) {
            float3 t, b;
            float2 alpha = float2(roughness * roughness);
            if (!coat && (g.bits & MATERIAL_LAYER_ANISOTROPY) != 0u && g.layers.anisotropy > 0.0) {
                // OpenPBR: the mean square of the two alphas is that of the lobe.
                float a = saturate(g.layers.anisotropy);
                t = normalize(g.layers.tangent - n * dot(n, g.layers.tangent));
                b = cross(n, t);
                alpha.x *= sqrt(2.0 / (1.0 + (1.0 - a) * (1.0 - a)));
                alpha.y = max((1.0 - a) * alpha.x, 1e-4);
            } else {
                make_basis(n, t, b);
            }
            float2 u = float2(random01(seed) * (1.0 - LOBE_TAIL_CUT), random01(seed));
            float3 h = sample_visible_normal(float3(dot(-view, t), dot(-view, b), dot(-view, n)), alpha, u);
            float3 sampled = reflect(view, normalize(t * h.x + b * h.y + n * h.z));
            if (dot(sampled, n) > 0.0) dir = sampled;
        }
        float3 origin = offset_origin(position, n, view_bias(pixel.distance));
        bool detailed = roughness < params.detail_below;
        float3 fresnel;
        if (coat) {
            float ratio = (g.layers.coat_ior - 1.0) / (g.layers.coat_ior + 1.0);
            fresnel = float3(g.layers.coat * fresnel_schlick(float3(ratio * ratio), 1.0, saturate(dot(n, -view))).r);
        } else {
            fresnel = fresnel_schlick(g.f0, g.f90, saturate(dot(n, -view)));
        }
        float reflectance = max(fresnel.r, max(fresnel.g, fresnel.b));
        // A reflection this faint shows little and changes little: its block
        // traces four frames in sixteen, one pixel of it each, and the filter
        // keeps what they found in between. The turn is the same for a whole
        // group of threads, which skip it together.
        if (reflectance < params.faint_below && ((frame.frame_index >> 2u) + hash_u32(group.x * 7919u + group.y)) % 4u != 0u) {
            out_radiance[cell] = float4(0.0, 0.0, 0.0, -1.0);
            return;
        }
        Ray_Path path;
        Hit hit = trace_ray(origin, dir, 0.0, params.max_distance, false, path);
        distance = hit.instance == INVALID ? params.max_distance : hit.t;
        // The glass the ray crosses on its way: with its detail in a sharp
        // reflection, up to the gate of an extension it leaves through, and as its
        // mean in the others.
        bool filtered = detailed && (frame.flags & FRAME_FLAG_GLASS) != 0u;
        if (filtered) {
            filters_begin();
            through = trace_glass_filter(origin, dir, path.gate >= 0.0 ? path.gate : distance);
        } else {
            through = path.glass;
        }
        uint owner = uint(cell.x) | (uint(cell.y) << 16u);
        if (hit.instance == INVALID) {
            float3 sky = sky_radiance(path.direction, roughness);
            if (filtered) filters_weigh(sky);
            if (filter_chain != INVALID && head_append(point_head(INVALID, filter_chain, owner))) {
                out_radiance[cell] = float4(finite_or_zero(sky * through), distance);
                return;
            }
            out_radiance[cell] = float4(firefly_clamped(sky * through), distance);
            return;
        }
        bool cached = reflectance < params.cached_below && (frame.flags & FRAME_FLAG_GI) != 0u && frame.volume_atlas.w != 0u;
        how = (detailed ? SHADE_DETAILED : 0u) | (cached ? SHADE_CACHED : 0u);
        direction = path.direction;
        // The footprint of the pixel carried along the ray, wider on rougher
        // surfaces and where the surface curves within the pixel.
        float footprint = (depth_distance(depth) + hit.t) * max(params.pixel_spread, widened * widened);
        Hit_Point found = hit_point(hit.instance, hit.primitive, hit.bary, footprint);
        if (found.m.program_id != 0u) {
            Material_Point point = {hit.instance, hit.primitive, hit.bary, footprint, found.m.program_id, 0u, INVALID};
            uint index = point_append(point);
            if (index != INVALID) {
                if (filtered) filters_weigh(float3(1.0));
                Point_Head head = point_head(index, filter_chain, owner);
                head.aux[0] = record_oct(direction);
                head.aux[1] = how;
                if (head_append(head)) {
                    out_radiance[cell] = float4(through, distance);
                    return;
                }
            }
        }
        s = surface_from_hit(found, false, (Mirai_Surface)0);
    }
    float3 radiance;
    if ((how & SHADE_DETAILED) != 0u) radiance = shade_hit_glossy(s, direction, distance, params.light_budget, (how & SHADE_CACHED) == 0u);
    else if ((how & SHADE_CACHED) != 0u) radiance = shade_hit_cached(s, direction, distance);
    else radiance = shade_hit(s, direction, distance, params.light_budget);
    // A hit shaded here past glass with a program: the exact filters are added once they are known.
    if (params.resume == 0u && filter_chain != INVALID) {
        filters_weigh(radiance);
        uint owner = uint(cell.x) | (uint(cell.y) << 16u);
        if (head_append(point_head(INVALID, filter_chain, owner))) {
            out_radiance[cell] = float4(finite_or_zero(radiance * through), distance);
            return;
        }
    }
    out_radiance[cell] = float4(firefly_clamped(radiance * through), distance);
}
