// The pixels of the G-buffer in the world, whichever view drew them. A source
// that reads them includes this, so only its stages change with nested views.
#ifndef MIRAI_PIXEL_SLANG
#define MIRAI_PIXEL_SLANG
#include "scene.slang"
#include "depth.slang"

// The view a pixel of the G-buffer was drawn by: 0 for the view itself.
uint pixel_view(int2 p) {
#ifdef MIRAI_NESTED_VIEWS
    return uint(clamp(pixel_views.Load(int3(p, 0)).a - 0.5, 0.0, float(NESTED_VIEW_CAPACITY)));
#else
    return 0u;
#endif
}

// The ray of the view of pixel p through uv, as view_origin and view_ray, in
// the world that view shows.
void pixel_ray(int2 p, float2 uv, float depth, out float3 origin, out float3 ray) {
    origin = view_origin(uv);
    ray = view_ray(uv);
#ifdef MIRAI_NESTED_VIEWS
    if (depth_nested(depth)) {
        Nested_View nested = frame.nested[max(pixel_view(p), 1u) - 1u];
        origin = transform_point(nested.to_world, origin);
        ray = transform_vector(nested.to_world, ray);
    }
#endif
}
Pixel pixel_at(int2 p, float2 uv, float depth) {
    float3 origin, ray;
    pixel_ray(p, uv, depth, origin, ray);
    float reach = length(ray);
    Pixel px;
    px.position = origin + ray * depth_distance(depth);
    px.view = ray / reach;
    px.distance = depth_distance(depth) * reach;
    return px;
}
// The direction the view of pixel p looks in: what a unit along it adds to the linear depth.
float3 pixel_forward(int2 p, float depth) {
#ifdef MIRAI_NESTED_VIEWS
    if (depth_nested(depth)) return transform_vector(frame.nested[max(pixel_view(p), 1u) - 1u].to_world, frame.camera_forward.xyz);
#endif
    return frame.camera_forward.xyz;
}
// Where a point of the view of pixel p was for the previous camera: its clip
// position, and its linear depth.
float3 previous_view_point(int2 p, float depth, float3 world) {
#ifdef MIRAI_NESTED_VIEWS
    if (depth_nested(depth)) return transform_point(frame.nested[max(pixel_view(p), 1u) - 1u].from_world_previous, world);
#endif
    return world;
}
float4 previous_clip(int2 p, float depth, float3 world) { return view_clip_previous(previous_view_point(p, depth, world)); }
float previous_depth(int2 p, float depth, float3 world) {
    float3 point = previous_view_point(p, depth, world);
    return dot(frame.prev_depth_plane.xyz, point) + frame.prev_depth_plane.w;
}
#endif
