// The test of a box against a depth pyramid of the view (hiz.comp): the
// culls of the scene (cull_common.slang) and the passes of extensions in the
// Gbuffer stage (render.pass_depth_pyramid) take it.
#ifndef MIRAI_PYRAMID_SLANG
#define MIRAI_PYRAMID_SLANG
#include "scene.slang"

// The finest level of the pyramid at which `texels` (of level 0, inclusive)
// span at most `footprint` texels along each axis: two texels of level k
// cover 2^(k+1) of level 0, and where the footprint straddles the edges of
// the texels of that level one level coarser always holds it.
int pyramid_level_for(int4 texels, int footprint) {
    int2 span = texels.zw - texels.xy;
    int level = max(max(int(firstbithigh(uint(span.x))), int(firstbithigh(uint(span.y)))) - (int(firstbithigh(uint(footprint))) - 1), 0);
    if (any((texels.zw >> level) - (texels.xy >> level) > footprint - 1)) level++;
    return level;
}

// What the farthest depth a texel of the pyramid holds is taken as at most:
// relatively a step farther, well above the rounding of the depth the raster
// writes and of the projection of a corner, well below any distance between
// two surfaces that matters; and at least an absolute step farther, past the
// rounding of a depth near the far plane, where the projection subtracts two
// near equal terms. Either keeps a surface from being hidden by itself.
#define PYRAMID_DEPTH_SLACK 1e-4
#define PYRAMID_DEPTH_FLOOR 1e-7

// True when the box is entirely behind the farthest depth stored in the
// pyramid over its screen footprint: the nearest of its corners, by the
// reverse Z of view_proj (the camera the pyramid was drawn with, which takes
// a point from eye), is farther than every pixel there. Conservative:
// anything touching the near plane or the screen border counts as visible.
// levels: of the pyramid.
bool pyramid_hides(Texture2D<float4> pyramid, uint levels, float3 bmin, float3 bmax, float4x4 view_proj, float3 eye) {
    float2 lo = float2(1.0), hi = float2(0.0);
    float nearest = -FLT_MAX;
    // The corners from the lowest one along the edges of the box.
    float3 size = bmax - bmin;
    float4 low = mul(view_proj, float4(bmin - eye, 1.0));
    float4 dx = mul(view_proj, float4(size.x, 0.0, 0.0, 0.0));
    float4 dy = mul(view_proj, float4(0.0, size.y, 0.0, 0.0));
    float4 dz = mul(view_proj, float4(0.0, 0.0, size.z, 0.0));
    for (int i = 0; i < 8; i++) {
        float4 clip = low + ((i & 1) != 0 ? dx : 0.0) + ((i & 2) != 0 ? dy : 0.0) + ((i & 4) != 0 ? dz : 0.0);
        // Behind the eye, or on the near plane (depth 1) or nearer.
        if (clip.w <= 0.0 || clip.z >= clip.w) return false;
        float2 ndc = clip.xy / clip.w;
        float2 uv = float2(ndc.x * 0.5 + 0.5, 0.5 - ndc.y * 0.5);
        lo = min(lo, uv);
        hi = max(hi, uv);
        nearest = max(nearest, clip.z / clip.w);
    }
    lo = clamp(lo, float2(0.0), float2(1.0));
    hi = clamp(hi, float2(0.0), float2(1.0));
    if (any(((lo) >= (hi)))) return false;
    // Footprint in render pixels, widened by one pixel because the pyramid
    // was rasterized with TAA jitter while this test projects without it.
    float2 px_lo = max(lo * frame.resolution - 1.0, float2(0.0));
    float2 px_hi = min(hi * frame.resolution + 1.0, frame.resolution - 1.0);
    // At the level where it spans at most 4x4 texels: texel j of level L
    // covers pixels j * 2^(L+1) to (j + 1) * 2^(L+1), the last one those of
    // the view that are left (hiz.comp).
    int4 texels = int4(int2(px_lo), int2(px_hi)) >> 1;
    int level = min(pyramid_level_for(texels, 4), int(levels) - 1);
    int2 level_size = (int2(frame.resolution) + ((2 << level) - 1)) >> (level + 1);
    int2 a = min(texels.xy >> level, level_size - 1);
    int2 b = min(texels.zw >> level, level_size - 1);
    float farthest = 1.0;
    for (int y = a.y; y <= b.y; y++) {
        for (int x = a.x; x <= b.x; x++) {
            farthest = min(farthest, pyramid.Load(int3(int2(x, y), level)).r);
        }
    }
    return nearest < farthest * (1.0 - PYRAMID_DEPTH_SLACK) - PYRAMID_DEPTH_FLOOR;
}
#endif
