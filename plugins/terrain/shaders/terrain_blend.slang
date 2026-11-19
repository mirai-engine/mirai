//! mirai constant HEIGHT_BLEND_WINDOW float ../runtime/layers.odin
#ifndef TERRAIN_BLEND_SLANG
#define TERRAIN_BLEND_SLANG
#include <constants/plugins/terrain.slang>
// What of the weights of the layers at a point shows (Terrain_Layers, the
// relief of terrain_displace.comp). Each weight shows less that of the third
// heaviest, so the two heaviest show and a layer comes in and goes where it
// weighs as much as the third, at nothing: no pair hands over with a step.
// Where the three weigh within TERRAIN_THIRD_BAND of each other, two would
// have to jump from pair to pair at the point where the three weigh alike:
// there each shows less the first less the band instead, so the third comes
// in by how close it is and the three show alike where they weigh alike.
// Each also shows less TERRAIN_WEIGHT_MIN at least, so what barely weighs is
// not read. A fourth never shows; only where four weigh exactly alike does
// the first show alone. The weights need not be sorted; those returned add
// up to 1.
static const float TERRAIN_THIRD_BAND = 0.2;
static const float TERRAIN_WEIGHT_MIN = 0.02;
float4 terrain_heaviest(float4 w) {
    float high0 = max(w.x, w.y), low0 = min(w.x, w.y), high1 = max(w.z, w.w), low1 = min(w.z, w.w);
    float first = max(high0, high1), upper = min(high0, high1), lower = max(low0, low1);
    float third = min(upper, lower), fourth = min(low0, low1);
    float under = max(max(fourth, TERRAIN_WEIGHT_MIN), min(third, first - TERRAIN_THIRD_BAND));
    float4 shown = max(w - under, float4(0.0));
    float sum = shown.x + shown.y + shown.z + shown.w;
    return sum > 0.0 ? shown / sum : float4(1.0, 0.0, 0.0, 0.0);
}
// Where layers meet, the higher texels show: each layer's height (0 to 1)
// scaled by what shows of it, and each layer shown by that share within a
// window under the highest of those heights, HEIGHT_BLEND_WINDOW wide at a
// height_blend of 1 and without end at 0, its share alone. A layer shows
// about what it weighs, and of layers that weigh alike the higher texel.
float4 terrain_height_blend(float4 shown, float4 height, float4 height_blend) {
    float4 h = height * shown;
    float top = max(max(h.x, h.y), max(h.z, h.w));
    float4 b = shown * saturate(1.0 - height_blend * (top - h) / HEIGHT_BLEND_WINDOW);
    float sum = b.x + b.y + b.z + b.w;
    return sum > 0.0 ? b / sum : float4(1.0, 0.0, 0.0, 0.0);
}
#endif
