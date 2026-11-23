#include "native.slang"
// The camera inside a solid of glass (params.medium, the blended instance
// under the top of whose box it is), after glass.comp lit the nearest layer:
// at a back face of the solid, the view leaves it, bending out within the
// window of Snell and shown on screen as glass.comp shows the scene
// (glass_pass.slang), and is reflected back inside, all of it beyond the
// critical angle, as the probe volume lights the face; and
// the solid absorbs what the view meets in it and scatters light towards it,
// from the camera to the first layer or, without one, to the opaque scene. It
// reads the scene from the copy that glass.comp made of it before that layer
// and writes over the image. It runs only while some instance is over the
// camera.
#include "glass_pass.slang"
#define MIRAI_GROUP_X 8
#define MIRAI_GROUP_Y 8
#define MIRAI_GROUP_Z 1

// The two ways of the light that comes to the eye from inside a solid
// through a back face of it: what bends out of it within the window of Snell,
// and what the face reflects back in, all of it beyond the critical angle.
// The face reflects as its F0 says at the angle outside, where the light is
// in the thinner medium. Each adds to the image under what the solid absorbs
// between the camera and the face.
float3 leaving_reflectance(Material m, Glass g, out bool out_way) {
    float ior = m.ior;
    float cos_inside = saturate(dot(g.view, g.normal));
    float sin2_outside = ior * ior * (1.0 - cos_inside * cos_inside);
    out_way = sin2_outside < 1.0;
    return out_way ? g.f0 + (1.0 - g.f0) * pow(1.0 - sqrt(1.0 - sin2_outside), 5.0) : float3(1.0);
}

// Whether the view of a pixel starts in the solid: the camera is under the top
// of its box, and the nearest layer is not a face of it the view enters, which
// a view from inside meets only from behind (GBUFFER_GLASS_EXIT). Within
// params.near_top of the top, over or under it, the pixel decides by where its
// view starts, on the near plane: the line of the surface crosses the lens.
// Under, not only inside: under a sheet open below, as the surface of water,
// is inside it.
bool medium_holds(float3 lens, float top, bool entered) {
    if (entered) return false;
    return abs(frame.camera_position.y - top) < params.near_top ? lens.y < top : frame.camera_position.y < top;
}

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 dispatch_id : SV_DispatchThreadID) {
    int2 p = int2(dispatch_id.xy);
    if (any(p >= int2(frame.resolution))) return;
    float depth = layer_depth.Load(int3(p, 0)).r;
    float2 uv = (float2(p) + 0.5) * frame.inv_resolution;
    uint instance = params.medium - 1u;
    float top = instances[instance].bounds_max.y;
    // Near the top the ray of the pixel starts where it crosses the near plane, over or under the top.
    float3 lens = view_origin(uv) + view_ray(uv) * frame.camera_position.w;
    float3 eye = view_direction(uv);
    Material medium = material_row(params.medium_row, material_values_of(instance));
    if (depth <= 0.0) {
        if (medium_holds(lens, top, false)) {
            float far = length(position_from_depth(uv, opaque_depth(uv)) - lens);
            // A ray that starts under the top and goes up leaves the solid at it, unseen as a layer edge on.
            if (lens.y < top && eye.y > 1e-4) far = min(far, (top - lens.y) / eye.y);
            float3 seen = scene.Load(int3(p, 0)).rgb * material_absorption(medium, far) + solid_scatter(medium, instance, lens, eye, far, top);
            out_color[p] = float4(finite_or_zero(seen), 1.0);
        }
        return;
    }
    float4 normal = layer_normal.Load(int3(p, 0));
    uint2 ids = layer_ids.Load(int3(p, 0));
    float3 at = position_from_depth(uv, depth);
    float near = length(at - frame.camera_position.xyz);
    if ((gbuffer_bits_unpack(normal) & GBUFFER_GLASS_EXIT) != 0u) {
        // The view leaves the solid it started in.
        Material m = material_row(ids.x, material_values_of(ids.y));
        Glass g = glass_of(p, uv, depth, layer_albedo.Load(int3(p, 0)), normal, layer_emission.Load(int3(p, 0)));
        bool out_way;
        float3 reflectance = leaving_reflectance(m, g, out_way);
        float3 near_absorbed = material_absorption(m, near);
        // Where the face does not cover, the view goes on to what lies behind it as it is.
        float covered = saturate(g.alpha);
        float3 face = (1.0 - covered) * scene.Load(int3(p, 0)).rgb + covered * g.emission;
        if (out_way && covered > 0.0) {
            float3 out_direction = refract(-g.view, g.normal, m.ior);
            face += covered * scene_refracted(g.position, out_direction, depth, g.roughness, uv) * surface_through(m, g.base_color, reflectance);
        }
        // Back in, its reflection from the probe volume and what the solid absorbs and scatters.
        float3 back = reflect(-g.view, g.normal);
        Shading s = glass_shading(m, g);
        float3 around = indirect_lobes(g.position, g.normal, g.view, s, INDIRECT_SPECULAR, g.occlusion).radiance;
        float3 inside = around * material_absorption(m, params.max_distance)
            + solid_scatter(m, ids.y, g.position, back, params.max_distance, top);
        face += covered * inside * reflectance;
        float3 seen = face * near_absorbed + solid_scatter(m, ids.y, frame.camera_position.xyz, eye, near, top);
        out_color[p] = float4(finite_or_zero(seen), 1.0);
        return;
    }
    if (medium_holds(lens, top, ids.y == instance)) {
        float3 seen = out_color[p].rgb * material_absorption(medium, near) + solid_scatter(medium, instance, frame.camera_position.xyz, eye, near, top);
        out_color[p] = float4(finite_or_zero(seen), 1.0);
    }
}
