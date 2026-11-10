// The media of a view (render.MEDIA_TEXTURE): a volume along its frustum
// whose cells hold, from the eye to their far side, the light the media turn
// towards the eye (rgb) and what they let through (a). Slices of about
// scale / slices metres near the eye grow with the distance to `distance`;
// past it each slice is further than the one before by the same ratio up to
// `reach`, and the last goes on without end. Needs scene.slang.
#ifndef MEDIA_GRID_SLANG
#define MEDIA_GRID_SLANG

// render.Media_Grid.
struct Media_Grid {
    uint4 cells;    // columns, rows, slices to distance, slices past it
    float distance; // metres along the view the slices reach
    float scale;    // metres: about where slices start growing with the distance
    float reach;    // metres along the view where the last slice past them begins
    uint valid;     // 1: the view has media
};

// The depth along the view where slice coordinate s lies, and back.
float media_slice_depth(Media_Grid g, float s) {
    return g.scale * (pow(1.0 + g.distance / g.scale, s / float(g.cells.z)) - 1.0);
}
float media_depth_slice(Media_Grid g, float depth) {
    return float(g.cells.z) * log2(1.0 + max(depth, 0.0) / g.scale) / log2(1.0 + g.distance / g.scale);
}

// Past the slices to distance, the depth of the far side of slice j of those beyond.
float media_far_depth(Media_Grid g, uint j) {
    return g.distance * pow(g.reach / g.distance, float(j + 1u) / float(g.cells.w - 1u));
}

// The slice coordinate of a depth among all of them; empty: past the last.
float media_seen_slice(Media_Grid g, float depth, bool empty) {
    if (empty) return float(g.cells.z + g.cells.w);
    if (depth <= g.distance) return media_depth_slice(g, depth);
    return min(float(g.cells.z) + float(g.cells.w - 1u) * log2(depth / g.distance) / log2(g.reach / g.distance), float(g.cells.z + g.cells.w - 1u));
}

// The light the media turn towards the eye from it to a depth along the ray
// of uv, and what they let through: a cell holds them up to its far side.
float4 media_seen(Texture3D<float4> media, Media_Grid g, float2 uv, float depth, bool empty) {
    float s = media_seen_slice(g, depth, empty);
    float4 f = media.SampleLevel(linear_sampler, float3(uv, max(s - 0.5, 0.5) / float(g.cells.z + g.cells.w)), 0.0);
    return s < 1.0 ? lerp(float4(0.0, 0.0, 0.0, 1.0), f, s) : f;
}

// Those of a place of the frame (relative to its origin) seen from the eye;
// none in a view without media or for a place off the view.
float4 media_over(Texture3D<float4> media, Media_Grid g, float3 position) {
    if (g.valid == 0u) return float4(0.0, 0.0, 0.0, 1.0);
    float4 clip = view_clip_unjittered(position);
    if (!(clip.w > 0.0)) return float4(0.0, 0.0, 0.0, 1.0);
    float2 uv = saturate(clip.xy / clip.w * float2(0.5, -0.5) + 0.5);
    return media_seen(media, g, uv, view_depth(position), false);
}
#endif
