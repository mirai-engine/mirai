#include "native.slang"
// The camera looks along its rays: they show a relative emission (hit_emission).
#define MIRAI_HITS_SHOW_RELATIVE_EMISSION 1
//! variant hw MIRAI_HW_RT=1
//! variant color MIRAI_GLASS_MEANS=1
//! variant color_hw MIRAI_GLASS_MEANS=1 MIRAI_HW_RT=1
// One layer of glass over the scene behind it, once per pixel whatever the
// number of surfaces drawn there: the light of the layer, with its traced
// reflection, plus what it lets through of the scene. A sheet shows the scene
// where it is; a solid bends the view ray where it enters, follows it to
// where it leaves and looks for the scene from there, on screen first and
// through the world when it is not there. A pane, a solid much thinner than
// it is wide, needs no ray to find where the view leaves it. It reads the scene from a copy made
// by a first dispatch of this pass (params.snapshot) and writes over the
// pixels of the layer alone.
// The back faces of the solid the camera is in are left to glass_inside.comp.
#include "glass_pass.slang"
#define MIRAI_GROUP_X 8
#define MIRAI_GROUP_Y 8
#define MIRAI_GROUP_Z 1

// The thickness of a solid that is a pane seen through one of its large
// faces, and the direction across it that leaves that face: its mesh lies on
// the two faces of its box across the axis that is thinner than a fifth of
// the others. 0 for any other solid, out of which a ray inside has to find
// its way.
float pane_thickness(uint instance, float3 normal, out float3 across) {
    Instance inst = instances[instance];
    Mesh mesh = meshes[instance_mesh(inst)];
    float3 half_size = 0.5 * (mesh.bounds_max.xyz - mesh.bounds_min.xyz);
    float3 extent;
    float3 axes[3];
    for (int i = 0; i < 3; i++) {
        float3 axis = float3(inst.world[0][i], inst.world[1][i], inst.world[2][i]);
        float scale = length(axis);
        extent[i] = 2.0 * half_size[i] * scale;
        axes[i] = scale > 0.0 ? axis / scale : float3(0.0);
    }
    int thin = extent.x <= extent.y ? (extent.x <= extent.z ? 0 : 2) : (extent.y <= extent.z ? 1 : 2);
    float sides = min(extent[(thin + 1) % 3], extent[(thin + 2) % 3]);
    across = dot(axes[thin], normal) < 0.0 ? -axes[thin] : axes[thin];
    bool slab = ((mesh.slab_axes >> uint(thin)) & 1u) != 0u;
    return slab && extent[thin] <= 0.2 * sides && dot(across, normal) >= 0.98 ? extent[thin] : 0.0;
}

// Where the view goes into a solid at the layer: a pane, a solid much thinner
// than it is wide seen through one of its large faces, needs no ray to find
// where it leaves it; the others follow it inside.
Glass_Walk glass_entry(Material m, Glass g, uint instance, float3 direction, float bias) {
    float3 across;
    float pane = pane_thickness(instance, g.normal, across);
    float3 outside = refract(direction, across, m.ior);
    if (pane > 0.0 && dot(outside, outside) > 0.0) {
        // Between parallel faces the view leaves through the far face, moved aside by its way through.
        float path = pane / max(dot(direction, -across), 1e-3);
        Glass_Walk w = walk_start(0u, WALK_SEEN, g.position + direction * path + outside * bias, outside, 0u);
        w.path = path;
        return w;
    }
    return walk_start(0u, WALK_INSIDE, g.position + direction * bias, direction, 0u);
}

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 dispatch_id : SV_DispatchThreadID, uint3 group : SV_GroupID, uint local : SV_GroupIndex) {
    int2 p;
    Point_Head head;
    if (params.resume != 0u) {
        if (!head_of_round(group.x * (MIRAI_GROUP_X * MIRAI_GROUP_Y) + local, head)) return;
        p = int2(head.owner & 0xffffu, head.owner >> 16u);
    } else {
        p = int2(dispatch_id.xy);
        if (any(((p) >= (int2(frame.resolution))))) return;
        if (params.snapshot != 0u) { out_color[p] = scene.Load(int3(p, 0)); return; }
    }
    float depth = layer_depth.Load(int3(p, 0)).r;
    if (depth <= 0.0) return;
    float4 normal = layer_normal.Load(int3(p, 0));
    if ((gbuffer_bits_unpack(normal) & GBUFFER_GLASS_EXIT) != 0u) return;
    float2 uv = (float2(p) + 0.5) * frame.inv_resolution;
    float4 albedo = layer_albedo.Load(int3(p, 0));
    float4 emission = layer_emission.Load(int3(p, 0));
    uint2 ids = layer_ids.Load(int3(p, 0));
    Material m = material_row(ids.x);
    Glass g = glass_of(p, uv, depth, albedo, normal, emission);
    uint seed = seed_for(uint2(p), frame.frame_index, 23u);
    Shading s = glass_shading(m, g);
    float3 through = glass_through(m, g, s);
    // The light of the layer, then what comes through it of the scene behind:
    // what a solid absorbed of it on the way and scattered towards the eye on it.
    float bias = 1e-3 + 2e-4 * depth;
    float3 direction = refract(-g.view, g.normal, 1.0 / m.ior);
    Glass_Walk w;
    bool shade = false;
    Surface shown;
    float t = 0.0;
    if (params.resume != 0u) {
        w = walk_resumed(head, m, ids.y, bias, shade, shown, t);
    } else {
        float traced = params.traced != 0u ? reflection_weight(g.roughness) : 0.0;
        float3 reflected = traced > 0.0 ? reflection.Load(int3(p, 0)).rgb : float3(0.0);
        float3 color = glass_light(m, g, s, reflected, traced, 0.0, params.light_budget);
        if (!material_solid(m)) {
            color += scene_through(uv, depth, m.transmission > 0.0 ? g.roughness : 0.0, seed) * through;
            out_color[p] = float4(finite_or_zero(color), 1.0);
            return;
        }
        out_color[p] = float4(finite_or_zero(color), 1.0);
        w = glass_entry(m, g, ids.y, direction, bias);
    }
    for (;;) {
        if (shade) {
            walk_shaded(w, shown, t);
            shade = false;
        }
        if (w.stage == WALK_DONE) break;
        bool inside = w.stage == WALK_INSIDE;
        if (!walk_advance(w, m, ids.y, depth, g.roughness, bias, p, seed, shade, shown, t)) return;
        if (inside && w.stage == WALK_SEEN && (w.flags & WALK_OPEN) != 0u) {
            // No way out found: an open mesh, as the surface of water. The solid goes on, bent,
            // to what the view finds.
            w.origin = g.position + direction * bias;
            w.direction = direction;
            w.path = 0.0;
        }
    }
    float path = (w.flags & WALK_OPEN) != 0u ? w.path + w.travelled : w.path;
    float3 absorbed = material_absorption(m, path);
    // Through a top that faces up the view entered at the height of the top.
    float3 scattered = solid_scatter(m, ids.y, g.position, direction, path, g.normal.y > 0.7 ? g.position.y : SOLID_TOP_UNKNOWN);
    out_color[p] = float4(out_color[p].rgb + finite_or_zero((w.radiance * absorbed + scattered) * through), 1.0);
}
