#include "native.slang"
// What one layer of glass lets through of the scene behind it, over the light
// of the layer that glass_light.comp left, once per pixel whatever the number
// of surfaces drawn there, using a screen-space scene read. A sheet shows the scene where it is,
// moved aside by its ripples (sheet_through); a solid bends the view where it
// enters, takes it across a slab of itself and shows the scene where the view
// that leaves it meets it on screen (glass_pass.slang). It reads the scene from a copy
// made by a first dispatch of this pass (params.snapshot) and writes over the
// pixels of the layer alone.
// The back faces of the solid the camera is in are left to glass_inside.comp.
// The air between the eye and the layer (aerial.slang) keeps a share of the
// light of the layer and sends its own where the layer hides what is behind:
// the scene behind already holds the air in front of the layer.
#include "glass_pass.slang"
#include "aerial.slang"
#define MIRAI_GROUP_X 8
#define MIRAI_GROUP_Y 8
#define MIRAI_GROUP_Z 1

// The thickness of a solid that is a pane seen through one of its large
// faces, and the direction across it that leaves that face: its mesh lies on
// the two faces of its box across the axis that is thinner than a fifth of
// the others. 0 for any other solid.
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

// The way of the view across a closed solid: a slab as thick as its pane, or
// else as its material says, under the face it entered, no farther than the
// box of the instance. It leaves by the parallel face, in its original
// direction; a face that would reflect it inside keeps the entry bend.
float solid_exit(Material m, Glass g, uint instance, inout float3 direction, out float3 exit) {
    float3 across;
    float pane = pane_thickness(instance, g.normal, across);
    if (!(pane > 0.0)) { pane = m.thickness; across = g.normal; }
    Instance inst = instances[instance];
    float3 inverse = 1.0 / select(abs(direction) > float3(1e-12), direction, float3(1e-12));
    float3 far = max((inst.bounds_min.xyz - g.position) * inverse, (inst.bounds_max.xyz - g.position) * inverse);
    float path = clamp(pane / max(dot(direction, -across), 1e-3), 0.0, max(min(far.x, min(far.y, far.z)), 0.0));
    exit = g.position + direction * path;
    float3 outside = refract(direction, across, m.ior);
    if (dot(outside, outside) > 0.0) direction = outside;
    return path;
}

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 dispatch_id : SV_DispatchThreadID) {
    int2 p = int2(dispatch_id.xy);
    if (any(p >= int2(frame.resolution))) return;
    // The scene, and in alpha whether the layer stands in front of it (glass_levels.comp).
    if (params.snapshot != 0u) { out_color[p] = float4(scene.Load(int3(p, 0)).rgb, layer_depth.Load(int3(p, 0)).r > 0.0 ? 1.0 : 0.0); return; }
    float depth = layer_depth.Load(int3(p, 0)).r;
    if (depth <= 0.0) return;
    float4 normal = layer_normal.Load(int3(p, 0));
    if ((gbuffer_bits_unpack(normal) & GBUFFER_GLASS_EXIT) != 0u) return;
    float2 uv = (float2(p) + 0.5) * frame.inv_resolution;
    uint2 ids = layer_ids.Load(int3(p, 0));
    Material m = material_row(ids.x, material_values_of(ids.y));
    Glass g = glass_of(p, uv, depth, layer_albedo.Load(int3(p, 0)), normal, layer_emission.Load(int3(p, 0)));
    Air_Between air = air_between(uv, length(g.position - frame.camera_position.xyz));
    // Where the layer does not cover, the scene behind shows as it is.
    float covered = saturate(g.alpha);
    float3 own = out_color[p].rgb;
    float3 behind = (1.0 - covered) * scene.Load(int3(p, 0)).rgb;
    if (!(covered > 0.0)) { out_color[p] = float4(finite_or_zero(own * air.kept + behind), 1.0); return; }
    float3 through = covered * glass_through(m, g, glass_shading(m, g));
    if (!material_solid(m)) {
        float3 passed = (1.0 - covered) + through;
        float3 color = own * air.kept + behind + scene_through(uv, depth, m.transmission > 0.0 ? g.roughness : 0.0) * through + saturate(1.0 - passed) * air.sent;
        out_color[p] = float4(finite_or_zero(color), 1.0);
        return;
    }
    // What the solid absorbed of the scene on the way and scattered towards the eye on it.
    float3 direction = refract(-g.view, g.normal, 1.0 / m.ior);
    Instance inst = instances[ids.y];
    float3 radiance;
    float path;
    if ((meshes[instance_mesh(inst)].flags & MESH_FLAG_CLOSED) == 0u) {
        Sheet_Seen seen = sheet_through(m, g, uv);
        radiance = seen.radiance;
        path = seen.travelled;
        direction = seen.direction;
    } else {
        float3 exit;
        float3 outside = direction;
        path = solid_exit(m, g, ids.y, outside, exit);
        radiance = scene_refracted(exit, outside, depth, g.roughness, uv);
    }
    float3 absorbed = material_absorption(m, path);
    // Through a top that faces up the view entered at the height of the top.
    float3 scattered = solid_scatter(m, ids.y, g.position, direction, path, g.normal.y > 0.7 ? g.position.y : SOLID_TOP_UNKNOWN);
    float3 passed = (1.0 - covered) + absorbed * through;
    float3 color = (own + scattered * through) * air.kept + behind + radiance * absorbed * through + saturate(1.0 - passed) * air.sent;
    out_color[p] = float4(finite_or_zero(color), 1.0);
}
