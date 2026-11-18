// What the rasterizer would have handed a fragment of a pixel of a triangle
// (Raster_Input), rebuilt from the instance and the primitive the visibility
// of the view kept: each attribute gbuffer.vert gives the corners interpolated
// where the ray of the pixel crosses the triangle, and its change to the next
// pixels taken from the triangle too (the gradients of MATERIAL_GRADIENTS,
// which the includer defines before it includes raster.slang).
#ifndef MIRAI_VISIBLE_INPUT_SLANG
#define MIRAI_VISIBLE_INPUT_SLANG
#include "raster.slang"
#include <extension_vertex.slang>

// The weights of the corners of a triangle (in the world) where the ray of
// the view through a point of the image (in pixels) crosses its plane: the
// barycentrics the rasterizer interpolates with at that point.
float3 pixel_weights(float3 a, float3 b, float3 c, float2 pixel) {
    float2 uv = pixel * frame.inv_resolution;
    float3 origin = view_origin(uv);
    float3 direction = view_ray(uv);
    float3 e1 = b - a;
    float3 e2 = c - a;
    float3 p = cross(direction, e2);
    float det = dot(e1, p);
    float inv = abs(det) > 1e-30 ? 1.0 / det : 0.0;
    float3 s = origin - a;
    float u = dot(s, p) * inv;
    float v = dot(direction, cross(s, e1)) * inv;
    return float3(1.0 - u - v, u, v);
}

// What the rasterizer would have handed gbuffer.frag at a pixel of a
// triangle of an instance, and the changes along the pixels it would have
// given its derivatives.
Raster_Input visible_input(uint index, uint primitive, float2 pixel) {
    Instance inst = scene_instance(index);
    Mesh mesh = meshes[instance_mesh(inst)];
    Cluster c = mesh_cluster(mesh, primitive_cluster(primitive));
    uint3 corners = cluster_triangle(mesh, c, primitive_triangle(primitive));
    // The poses gbuffer.vert reads.
    uint posed = mesh.posed_word, previous = mesh.previous_word;
    if (mesh.part_word != INVALID && !view_draws_layers(mesh.part_layers, inst.meta.w)) {
        posed = mesh.part_word;
        previous = mesh.part_word + mesh.vertex_count * POSED_WORDS;
    }
    uint material = material_of(inst, cluster_material(mesh, c));
    Material row = material_row(material);
    bool batched = instance_batched(index);
    float4 hook = batched ? batch_vertex(batch_row(batch_of(index))) : float4(0.0);
    float3 pivot = float3(inst.world[0].w, inst.world[1].w, inst.world[2].w);
    Mesh_Point v[3];
    float3 world[3], before[3], normal[3], color[3];
    float4 tangent[3];
    for (uint k = 0u; k < 3u; k++) {
        uint local = corners[k];
        v[k] = cluster_point_at(mesh, c, local, posed);
        v[k].color = instance_vertex_color(inst, c.vertex_first + local, v[k].color);
        world[k] = transform_point(inst.world, v[k].position);
        before[k] = transform_point(inst.prev_world, cluster_position_previous(mesh, c, local, previous));
#ifdef MIRAI_HOOK_VERTEX
        if (batched) {
            world[k] = mirai_batch_vertex(world[k], pivot, v[k].color, hook, frame.time.x);
            before[k] = mirai_batch_vertex(before[k], pivot, v[k].color, hook, frame.time.y);
        }
#endif
        normal[k] = transform_normal(inst.world_inv, v[k].normal);
        tangent[k] = instance_tangent(inst, v[k].tangent);
        color[k] = instance_color(inst, row, v[k].color.rgb);
    }
    float3 w = pixel_weights(world[0], world[1], world[2], pixel);
    float3 dx = pixel_weights(world[0], world[1], world[2], pixel + float2(1.0, 0.0)) - w;
    float3 dy = pixel_weights(world[0], world[1], world[2], pixel + float2(0.0, 1.0)) - w;
    Raster_Input input;
    input.in_world = world[0] * w.x + world[1] * w.y + world[2] * w.z;
    input.in_normal = normal[0] * w.x + normal[1] * w.y + normal[2] * w.z;
    input.in_tangent = tangent[0] * w.x + tangent[1] * w.y + tangent[2] * w.z;
    input.in_uv = v[0].uv * w.x + v[1].uv * w.y + v[2].uv * w.z;
    input.in_uv1 = v[0].uv1 * w.x + v[1].uv1 * w.y + v[2].uv1 * w.z;
    input.in_color = color[0] * w.x + color[1] * w.y + color[2] * w.z;
    input.in_vertex_color = v[0].color * w.x + v[1].color * w.y + v[2].color * w.z;
    // What is not interpolated is of the first corner, as the rasterizer takes it.
    input.in_emission = inst.emission.rgb + ((v[0].surface.x & MESH_SURFACE_SET) != 0u ? surface_emission(v[0].surface.y) : float3(0.0));
    input.in_surface = v[0].surface.x;
    input.in_flags = ((inst.meta.w >> INSTANCE_HIGHLIGHT_SHIFT) & RASTER_HIGHLIGHT_MASK) | (instance_mirrored(inst) ? RASTER_FLAG_MIRRORED : 0u);
    input.in_material = material;
    input.in_instance = index;
    input.in_clip = view_clip_unjittered(input.in_world);
    input.in_prev_clip = view_clip_previous(before[0] * w.x + before[1] * w.y + before[2] * w.z);
    material_gradients_uv0 = float4(v[0].uv * dx.x + v[1].uv * dx.y + v[2].uv * dx.z, v[0].uv * dy.x + v[1].uv * dy.y + v[2].uv * dy.z);
    material_gradients_uv1 = float4(v[0].uv1 * dx.x + v[1].uv1 * dx.y + v[2].uv1 * dx.z, v[0].uv1 * dy.x + v[1].uv1 * dy.y + v[2].uv1 * dy.z);
    material_gradients_position_dx = world[0] * dx.x + world[1] * dx.y + world[2] * dx.z;
    material_gradients_position_dy = world[0] * dy.x + world[1] * dy.y + world[2] * dy.z;
    float3 n = normalize(input.in_normal);
    material_gradients_normal_dx = normalize(input.in_normal + normal[0] * dx.x + normal[1] * dx.y + normal[2] * dx.z) - n;
    material_gradients_normal_dy = normalize(input.in_normal + normal[0] * dy.x + normal[1] * dy.y + normal[2] * dy.z) - n;
    return input;
}
#endif
