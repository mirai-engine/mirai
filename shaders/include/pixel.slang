// The pixels of the G-buffer in the world, whichever view drew them. A source
// that reads them includes this, so only its stages change with nested views.
#ifndef MIRAI_PIXEL_SLANG
#define MIRAI_PIXEL_SLANG
#include "scene.slang"
#include "depth.slang"

// The view a pixel of the G-buffer was drawn by: 0 for the view itself.
uint pixel_view(int2 p) {
#ifdef MIRAI_NESTED_VIEWS
    if ((frame.flags & FRAME_FLAG_NESTED) == 0u) return 0u;
    return min(pixel_views.Load(int3(p, 0)), uint(NESTED_VIEW_CAPACITY));
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
// The tag of a pixel of the viewmodel of the view (FRAME_FLAG_VIEWMODEL):
// VIEWS_FOREGROUND with its kept share in VIEWS_KEPT; 0 for another pixel.
uint pixel_foreground(int2 p) {
    if ((frame.flags & FRAME_FLAG_VIEWMODEL) == 0u) return 0u;
    uint tag = pixel_views.Load(int3(p, 0));
    return (tag & VIEWS_FOREGROUND) != 0u ? tag : 0u;
}
// A pixel of the G-buffer in the world. One of the viewmodel is drawn with
// its own field of view: it sees along the ray of the viewmodel, and its
// place is the true one pulled toward the eye by the share its tag keeps,
// which keeps it in front of the world under it.
Pixel pixel_at(int2 p, float2 uv, float depth) {
    float3 origin, ray;
    pixel_ray(p, uv, depth, origin, ray);
    float kept = 1.0;
    uint tag = pixel_foreground(p);
    if (tag != 0u) {
        ray = frame.foreground_ray[0].xyz + frame.foreground_ray[1].xyz * uv.x + frame.foreground_ray[2].xyz * uv.y;
        kept = float(tag & VIEWS_KEPT) / float(VIEWS_KEPT);
    }
    float reach = length(ray);
    Pixel px;
    px.position = origin + ray * (depth_distance(depth) * kept);
    px.true_position = origin + ray * depth_distance(depth);
    px.view = ray / reach;
    px.distance = depth_distance(depth) * kept * reach;
    return px;
}
// The width of a pixel at p of the view where it takes the maps of the
// shadows: at its depth, or of a pixel of the viewmodel no nearer than
// FOREGROUND_MARK_DEPTH, so its light comes from the levels the world near
// the eye reads.
float pixel_across(int2 p, float depth) {
    float d = depth_distance(depth);
    if (pixel_foreground(p) != 0u) d = max(d, FOREGROUND_MARK_DEPTH);
    return frame.footprint.x + frame.footprint.y * d;
}
// The surface a pixel is on as spatial filters keep it apart: 1 that of the
// view, 2 one a nested view drew, 3 the viewmodel's.
float pixel_side(int2 p, float depth) {
    return depth_nested(depth) ? 2.0 : pixel_foreground(p) != 0u ? 3.0 : 1.0;
}
// The classes of rays a pixel leaves out: those of a viewmodel the local
// bodies (RAY_BODIES of trace.slang), as its eye is inside its body.
uint pixel_rays_omitted(int2 p) { return pixel_foreground(p) != 0u ? RAY_BODY | RAY_BODY_SMALL : 0u; }
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
