#include "native.slang"
// The camera looks along its rays: they show a relative emission (hit_emission).
#define MIRAI_HITS_SHOW_RELATIVE_EMISSION 1
//! variant hw MIRAI_HW_RT=1
//! variant color MIRAI_GLASS_MEANS=1
//! variant color_hw MIRAI_GLASS_MEANS=1 MIRAI_HW_RT=1
// The camera inside a solid of glass (params.medium, the blended instance
// under the top of whose box it is), after glass.comp lit the nearest layer:
// at a back face of the solid, the view leaves it, bending out within the
// window of Snell and reflected back inside beyond the critical angle; and the
// solid absorbs what the view meets in it and scatters light towards it, from
// the camera to the first layer or, without one, to the opaque scene. It reads the scene from the copy that
// glass.comp made of it before that layer and writes over the image. It runs
// only while some instance is over the camera.
#define GLASS_WALK_IN_SCENE 1
#include "glass_pass.slang"
#define MIRAI_GROUP_X 8
#define MIRAI_GROUP_Y 8
#define MIRAI_GROUP_Z 1

// The two ways of the light that comes to the eye from inside a solid
// through a back face of it: what bends out of it within the window of Snell
// (LEG_OUT), and what the face reflects back in (LEG_IN), all of it beyond
// the critical angle. The face reflects as its F0 says at the angle outside,
// where the light is in the thinner medium. Each adds to the image once it is
// known, under what the solid absorbs between the camera and the face.
#define LEG_OUT 0u
#define LEG_IN 1u
float3 leaving_reflectance(Material m, Glass g, out bool out_way) {
    float ior = m.ior;
    float cos_inside = saturate(dot(g.view, g.normal));
    float sin2_outside = ior * ior * (1.0 - cos_inside * cos_inside);
    out_way = sin2_outside < 1.0;
    return out_way ? g.f0 + (1.0 - g.f0) * pow(1.0 - sqrt(1.0 - sin2_outside), 5.0) : float3(1.0);
}

// Whether the camera is in the solid, the same for every pixel: a ray going up
// from a little under the camera meets a back face of it first. Up, so that
// under a sheet open below, as the surface of water, is inside it. Instances in
// the way that are not the solid are passed by. Within params.near_top of the
// top found, over or under it, each pixel decides by where its ray starts, on
// the near plane: the line of the surface crosses the lens.
#define MEDIUM_PASSES 8
groupshared uint medium_inside;
groupshared uint medium_near;
groupshared uint medium_row;
groupshared float medium_top;

void medium_find(uint instance) {
    medium_inside = 0u;
    medium_near = 0u;
    medium_row = 0u;
    medium_top = SOLID_TOP_UNKNOWN - 1.0;
    float3 up = float3(0.0, 1.0, 0.0);
    float3 origin = frame.camera_position.xyz - up * params.near_top;
    for (int pass = 0; pass < MEDIUM_PASSES; pass++) {
        Hit hit = trace_instance(instance, origin, up);
        if (hit.instance == INVALID) return;
        if (hit.instance != instance) { origin += up * (hit.t + 1e-3); continue; }
        uint row;
        float3 face = triangle_face(hit.instance, hit.primitive, row);
        Material m = material_row(row);
        if (dot(face, up) > 0.0 && m.alpha_mode == ALPHA_BLEND && material_solid(m)) {
            float top = origin.y + hit.t;
            medium_inside = frame.camera_position.y < top ? 1u : 0u;
            medium_near = abs(frame.camera_position.y - top) < params.near_top ? 1u : 0u;
            medium_row = row;
            medium_top = top;
        }
        return;
    }
}

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 dispatch_id : SV_DispatchThreadID, uint3 group : SV_GroupID, uint local : SV_GroupIndex) {
    if (local == 0u) medium_find(params.medium - 1u);
    GroupMemoryBarrierWithGroupSync();
    int2 p = int2(dispatch_id.xy);
    Point_Head head;
    if (params.resume != 0u) {
        if (!head_of_round(group.x * (MIRAI_GROUP_X * MIRAI_GROUP_Y) + local, head)) return;
        p = int2(head.owner & 0xffffu, head.owner >> 16u);
    }
    if (any(((p) >= (int2(frame.resolution))))) return;
    float depth = layer_depth.Load(int3(p, 0)).r;
    float2 uv = (float2(p) + 0.5) * frame.inv_resolution;
    bool inside = medium_inside != 0u;
    // Near the top the ray of the pixel starts where it crosses the near plane, over or under the top.
    float3 lens = view_origin(uv) + view_ray(uv) * frame.camera_position.w;
    float3 eye = view_direction(uv);
    if (medium_near != 0u) inside = lens.y < medium_top;
    if (depth <= 0.0) {
        if (inside) {
            float far = length(position_from_depth(uv, opaque_depth(uv)) - lens);
            // A ray that starts under the top and goes up leaves the solid at it, unseen as a layer edge on.
            if (medium_near != 0u && eye.y > 1e-4) far = min(far, (medium_top - lens.y) / eye.y);
            Material medium = material_row(medium_row);
            float3 seen = scene.Load(int3(p, 0)).rgb * material_absorption(medium, far) + solid_scatter(medium, params.medium - 1u, lens, eye, far, medium_top);
            out_color[p] = float4(finite_or_zero(seen), 1.0);
        }
        return;
    }
    float4 normal = layer_normal.Load(int3(p, 0));
    float3 at = position_from_depth(uv, depth);
    float near = length(at - frame.camera_position.xyz);
    if ((gbuffer_bits_unpack(normal) & GBUFFER_GLASS_EXIT) != 0u) {
        // The view leaves the solid it started in.
        uint2 ids = layer_ids.Load(int3(p, 0));
        Material m = material_row(ids.x);
        Glass g = glass_of(p, uv, depth, layer_albedo.Load(int3(p, 0)), normal, layer_emission.Load(int3(p, 0)));
        uint seed = seed_for(uint2(p), frame.frame_index, 23u);
        float bias = 1e-3 + 2e-4 * depth;
        bool out_way;
        float3 reflectance = leaving_reflectance(m, g, out_way);
        float3 near_absorbed = material_absorption(m, near);
        float3 back = reflect(-g.view, g.normal);
        Glass_Walk w;
        bool shade = false;
        Surface shown;
        float t = 0.0;
        if (params.resume != 0u) {
            w = walk_resumed(head, m, ids.y, bias, shade, shown, t);
        } else {
            out_color[p] = float4(finite_or_zero(g.emission * near_absorbed + solid_scatter(m, ids.y, frame.camera_position.xyz, view_direction(uv), near, medium_top)), 1.0);
            float3 out_direction = refract(-g.view, g.normal, m.ior);
            w = out_way ? walk_start(LEG_OUT, WALK_SEEN, g.position + out_direction * bias, out_direction, 0u) : walk_start(LEG_IN, WALK_INSIDE, g.position + back * bias, back, 0u);
        }
        for (;;) {
            if (shade) {
                walk_shaded(w, shown, t);
                shade = false;
            }
            if (w.stage == WALK_DONE) {
                float3 added;
                if (w.leg == LEG_OUT) {
                    added = w.radiance * surface_filter(m, g.base_color, g.alpha, reflectance);
                } else {
                    // Under an open sheet the solid goes on to what the ray finds.
                    float path = (w.flags & WALK_OPEN) != 0u ? w.path + w.travelled : w.path;
                    added = (w.radiance * material_absorption(m, path) + solid_scatter(m, ids.y, g.position + back * bias, back, path, medium_top)) * reflectance;
                }
                out_color[p] = float4(out_color[p].rgb + finite_or_zero(added * near_absorbed), 1.0);
                if (w.leg == LEG_IN) return;
                w = walk_start(LEG_IN, WALK_INSIDE, g.position + back * bias, back, 0u);
            }
            if (!walk_advance(w, m, ids.y, depth, g.roughness, bias, p, seed, shade, shown, t)) return;
        }
    }
    if (inside) {
        Material medium = material_row(medium_row);
        float3 seen = out_color[p].rgb * material_absorption(medium, near) + solid_scatter(medium, params.medium - 1u, frame.camera_position.xyz, view_direction(uv), near, medium_top);
        out_color[p] = float4(finite_or_zero(seen), 1.0);
    }
}
