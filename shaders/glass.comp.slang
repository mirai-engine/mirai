#include "native.slang"
//! variant hw MIRAI_HW_RT=1
//! variant color MIRAI_GLASS_MEANS=1
//! variant color_hw MIRAI_GLASS_MEANS=1 MIRAI_HW_RT=1
// What one layer of glass lets through of the scene behind it, over the light
// of the layer that glass_light.comp left, once per pixel whatever the number
// of surfaces drawn there, without rays. A sheet shows the scene where it is;
// a solid bends the view where it enters and shows the scene where the bent
// view meets it on screen (glass_pass.slang). It reads the scene from a copy
// made by a first dispatch of this pass (params.snapshot) and writes over the
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

// The faces at which the view turns back into a closed solid before it is let
// out where it is.
#define GLASS_INSIDE_BOUNCES 3u

// Where the view goes into a solid at the layer, and from where it goes on:
// through a pane, a solid much thinner than it is wide seen through one of its
// large faces, from the far face, moved aside by its way through; through
// another closed solid, from the face where it leaves it, found on its own
// mesh, bent out there (or turned back in where it cannot leave); a sheet (an
// open mesh, as the surface of water) it does not leave (WALK_OPEN).
Glass_Walk glass_entry(Material m, Glass g, uint instance, float3 direction, float bias) {
    float3 across;
    float pane = pane_thickness(instance, g.normal, across);
    float3 outside = refract(direction, across, material_ior(m));
    if (pane > 0.0 && dot(outside, outside) > 0.0) {
        float path = pane / max(dot(direction, -across), 1e-3);
        Glass_Walk w = walk_start(g.position + direction * path + outside * bias, outside, 0u);
        w.path = path;
        return w;
    }
    Instance inst = instances[instance];
    if ((meshes[instance_mesh(inst)].flags & MESH_FLAG_CLOSED) == 0u) return walk_start(g.position + direction * bias, direction, WALK_OPEN);
    float3 origin = g.position + direction * bias;
    float path = 0.0;
    for (uint bounce = 0u; bounce < GLASS_INSIDE_BOUNCES; bounce++) {
        Hit hit = trace_instance(instance, origin, direction);
        if (hit.instance != instance) break;
        bool blended;
        float3 normal = hit_normal(hit.instance, hit.primitive, hit.bary, direction, blended);
        origin += direction * hit.t;
        path += hit.t;
        if (!blended) break;
        float3 out_direction = refract(direction, normal, material_ior(m));
        if (dot(out_direction, out_direction) > 0.0) {
            Glass_Walk w = walk_start(origin + out_direction * bias, out_direction, 0u);
            w.path = path;
            return w;
        }
        direction = reflect(direction, normal);
        origin += direction * bias;
    }
    // Without a face of its own on the way, or past the bounces: from where it leaves the box.
    float3 inverse = 1.0 / select(abs(direction) > float3(1e-12), direction, float3(1e-12));
    float3 far = max((inst.bounds_min.xyz - origin) * inverse, (inst.bounds_max.xyz - origin) * inverse);
    float leave = max(min(far.x, min(far.y, far.z)), 0.0);
    Glass_Walk w = walk_start(origin + direction * (leave + bias), direction, 0u);
    w.path = path + leave;
    return w;
}

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 dispatch_id : SV_DispatchThreadID) {
    int2 p = int2(dispatch_id.xy);
    if (any(p >= int2(frame.resolution))) return;
    if (params.snapshot != 0u) { out_color[p] = scene.Load(int3(p, 0)); return; }
    float depth = layer_depth.Load(int3(p, 0)).r;
    if (depth <= 0.0) return;
    float4 normal = layer_normal.Load(int3(p, 0));
    if ((gbuffer_bits_unpack(normal) & GBUFFER_GLASS_EXIT) != 0u) return;
    float2 uv = (float2(p) + 0.5) * frame.inv_resolution;
    uint2 ids = layer_ids.Load(int3(p, 0));
    Material m = material_row(ids.x);
    Glass g = glass_of(p, uv, depth, layer_albedo.Load(int3(p, 0)), normal, layer_emission.Load(int3(p, 0)));
    uint seed = seed_for(uint2(p), frame.frame_index, 23u);
    float3 through = glass_through(m, g, glass_shading(m, g));
    float3 color = out_color[p].rgb;
    if (!material_solid(m)) {
        out_color[p] = float4(finite_or_zero(color + scene_through(uv, depth, m.transmission > 0.0 ? g.roughness : 0.0, seed) * through), 1.0);
        return;
    }
    // What the solid absorbed of the scene on the way and scattered towards the eye on it.
    float bias = 1e-3 + 2e-4 * depth;
    float3 direction = refract(-g.view, g.normal, 1.0 / material_ior(m));
    Glass_Walk w = glass_entry(m, g, ids.y, direction, bias);
    walk_show(w, m, depth, g.roughness, uv, seed);
    float path = (w.flags & WALK_OPEN) != 0u ? w.path + w.travelled : w.path;
    float3 absorbed = material_absorption(m, path);
    // Through a top that faces up the view entered at the height of the top.
    float3 scattered = solid_scatter(m, ids.y, g.position, direction, path, g.normal.y > 0.7 ? g.position.y : SOLID_TOP_UNKNOWN);
    out_color[p] = float4(finite_or_zero(color + (w.radiance * absorbed + scattered) * through), 1.0);
}
