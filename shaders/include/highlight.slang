#ifndef MIRAI_HIGHLIGHT_SLANG
#define MIRAI_HIGHLIGHT_SLANG
#include "depth.slang"
// The outline mask holds, unjittered and at window points, the level and the
// distance along the view of the outlined surfaces, drawn without the
// surfaces around them (highlight.frag).

// The farthest of the surfaces seen around p, a point of the mask of size
// mask_size, as a distance along the view. Scene depth is jittered and may
// use another resolution, so it is read in its own coordinates; a
// conservative 2x2 footprint keeps a background texel beside a silhouette
// from making an unoccluded contour blink as the jitter moves.
float highlight_seen_depth(Texture2D<float4> scene_depth, float2 p, float2 mask_size) {
    int2 size = texture_size(scene_depth, 0);
    float2 scene_p = p / mask_size * float2(size) + frame.jitter.xy;
    int2 base = int2(floor(scene_p - 0.5));
    float seen = 0.0;
    for (int k=0; k<4; ++k) {
        int2 q = clamp(base + int2(k & 1, k >> 1), int2(0), size - 1);
        seen = max(seen, depth_distance(scene_depth.Load(int3(q, 0)).x));
    }
    return seen;
}

// Whether an outlined surface at depth lies behind the surfaces seen there.
bool highlight_behind(float depth, float seen) {return depth > seen * 1.01 + 0.02;}
#endif
