#ifndef MIRAI_OVERLAY_SLANG
#define MIRAI_OVERLAY_SLANG
#include "pixel.slang"
// What is drawn over the finished image at the resolution of the output and
// without the sub-pixel jitter of the scene: UI placed in the world and debug
// lines. It has no history, so TAA cannot blur it or leave a trail of it.

// Whether a point of an overlay is behind the opaque scene. uv is its place
// in the output and depth its distance along the view. The depth of the
// scene is jittered and may have another resolution: the farthest of the 2x2
// texels around the point decides, so a background texel beside a silhouette
// does not make what is in front of the silhouette blink as the jitter moves.
bool overlay_occluded(Texture2D<float4> scene_depth, float2 uv, float depth) {
    int2 size = texture_size(scene_depth, 0);
    float2 scene_p = uv * float2(size) + frame.jitter.xy;
    int2 base = int2(floor(scene_p - 0.5));
    float visible = 0.0;
    for (int k = 0; k < 4; ++k) {
        int2 q = clamp(base + int2(k & 1, k >> 1), int2(0), size - 1);
        float scene = scene_depth.Load(int3(q, 0)).x;
        // No surface was drawn there: nothing is in front of the overlay.
        float reach = depth_empty(scene) ? 1e30 : depth_distance(scene);
#ifdef MIRAI_NESTED_VIEWS
        // What a nested view drew is behind its opening: the overlay is of
        // this side, and only in front of the opening is it in front of that.
        uint view = pixel_view(q);
        if (view != 0u) {
            float4 opening = frame.nested[view - 1u].opening;
            float approach = dot(opening.xyz, view_ray(uv));
            if (abs(approach) > 1e-8) reach = max(-(dot(opening.xyz, view_origin(uv)) + opening.w) / approach, 0.0);
        }
#endif
        visible = max(visible, reach);
    }
    return depth > visible * 1.01 + 0.02;
}
#endif
