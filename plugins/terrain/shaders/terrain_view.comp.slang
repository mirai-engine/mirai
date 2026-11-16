#include "native.slang"
// The modes Contour lines and Slope of the editor (terrain_view.odin), in the
// Inspect stage of the view that shows one, over every surface of its lit
// image: the overlays OVERLAY_CONTOURS and OVERLAY_SLOPE of Terrain3D
// (src/shaders/overlays.glsl). They read the normal of the geometry, found
// from the depth of the pixel and of its neighbours: the shading normal of
// the G-buffer carries the normal maps of the materials, and stands in for it
// only where no neighbour is of the same surface. Terrain3D tints the albedo
// before the light; here the slope tints the lit image, which is the same
// for a diffuse surface, and the lines are drawn in their own color.
#include "scene.slang"
#define GBUFFER_NORMAL SLOT_PASS2
#include "gbuffer.slang"
#include "pixel.slang"
#define MIRAI_GROUP_X 8
#define MIRAI_GROUP_Y 8
#define MIRAI_GROUP_Z 1

// Must match Terrain_View_Mode.
#define TERRAIN_VIEW_CONTOURS 0u
#define TERRAIN_VIEW_CONTOURS_HEIGHT 1u
#define TERRAIN_VIEW_SLOPE 2u
// The image of Lit alone, exposed: what the overlays the editor draws go over.
#define TERRAIN_VIEW_EXPOSED 3u

struct Terrain_View_Params {uint mode; uint3 pad;};
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Terrain_View_Params> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);
[[vk::binding(SLOT_PASS0, 0)]] [[vk::image_format("rgba16f")]] RWTexture2D<float4> image : register(MIRAI_REGISTER(u, SLOT_PASS0), space0);
[[vk::binding(SLOT_PASS1, 0)]] Texture2D<float4> linear_depth : register(MIRAI_REGISTER(t, SLOT_PASS1), space0);

// The defaults of Terrain3D: angles in degrees, distances and heights in
// metres, thicknesses in pixels. Its colors are sRGB (source_color), here
// linear. Its contours are for a world of kilometres: here a tenth of its
// heights and a quarter of its distances, so a hill of a few metres shows its
// lines from where it is framed.
static const float SLOPE_ANGLE_LOW = 15.0;
static const float SLOPE_ANGLE_HIGH = 45.0;
static const float SLOPE_SOFTNESS = 12.0;
static const float4 SLOPE_COLOR_MID = float4(1.0, 0.665, 0.0, 1.0);
static const float4 SLOPE_COLOR_HIGH = float4(1.0, 0.0, 0.0, 1.0);
static const float4 CONTOUR_COLOR = float4(0.0, 0.0, 0.0, 0.8);
static const float2 CONTOUR_THERMAL_HEIGHTS = float2(-20.0, 20.0);
static const float CONTOUR_FAR_OPACITY = 0.08;
static const float CONTOUR_INDEX_INTERVAL = 10.0;
static const float CONTOUR_INDEX_DIST = 2048.0;
static const float CONTOUR_INDEX_THICKNESS = 2.0;
static const float CONTOUR_INTER_DIST = 384.0;
static const float CONTOUR_INTER_THICKNESS = 1.2;
static const float CONTOUR_HALF_DIST = 128.0;
static const float CONTOUR_HALF_THICKNESS = 1.2;
static const float CONTOUR_FULL_DIST = 8.0; // full thickness within it

// What a pixel next to p along an axis adds to its place, towards +axis, from
// the side whose depth is nearest p's; false where neither side holds a
// surface of the view that drew p.
bool neighbour_step(int2 p, float depth, Pixel at, int2 axis, out float3 offset) {
    offset = float3(0.0);
    float nearest = 1e30;
    for (int side = -1; side <= 1; side += 2) {
        int2 q = p + axis * side;
        if (any(q < int2(0)) || any(q >= int2(frame.resolution))) continue;
        float d = linear_depth.Load(int3(q, 0)).r;
        if (depth_empty(d) || !depth_same_side(d, depth) || pixel_view(q) != pixel_view(p)) continue;
        float gap = abs(depth_distance(d) - depth_distance(depth));
        if (gap >= nearest) continue;
        nearest = gap;
        offset = (pixel_at(q, (float2(q) + 0.5) * frame.inv_resolution, d).position - at.position) * float(side);
    }
    return nearest < 1e30;
}

// Single interval anti-aliased contour: ~0 on the line, ~1 off it.
float single_contour(float thickness, float interval, float y, float y_fwidth, float dist, float3 normal) {
    // Near is full thickness, far is reduced opacity, so distant major lines do not look too thick.
    thickness *= lerp(1.0, CONTOUR_FAR_OPACITY, smoothstep(CONTOUR_FULL_DIST, CONTOUR_INDEX_DIST * 0.5, dist));
    // None on perfectly flat surfaces.
    thickness *= step(0.0000001, 1.0 - normal.y);
    float mi = max(0.0, thickness - 1.0);
    float ma = max(1.0, thickness);
    float mx = max(0.0, 1.0 - thickness);
    float inv = 1.0 / interval;
    float f = abs(frac((y + interval * 0.5) * inv) - 0.5);
    float df = y_fwidth * inv;
    return clamp((f - df * mi) / (df * (ma - mi) + 1e-8), mx, 1.0);
}

// From max_op near to min_op far.
float contour_opacity(float dist, float fade_start, float fade_end, float min_op, float max_op) {
    return lerp(min_op, max_op, 1.0 - smoothstep(fade_start, fade_end, dist));
}

// Blue, cyan, green, yellow, orange.
float3 contour_thermal(float t) {
    t = saturate(t);
    return lerp(lerp(float3(0.0, 0.1, 0.8), float3(0.0, 0.9, 0.9), smoothstep(0.0, 0.35, t)),
                lerp(float3(0.1, 0.9, 0.1), float3(1.0, 0.9, 0.0), smoothstep(0.35, 0.7, t)),
                smoothstep(0.35, 0.7, t)) * (1.0 - smoothstep(0.7, 1.0, t))
         + float3(1.0, 0.2, 0.0) * smoothstep(0.7, 1.0, t);
}

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 dispatch_id : SV_DispatchThreadID) {
    int2 p = int2(dispatch_id.xy);
    if (any(p >= int2(frame.resolution))) return;
    // The image comes in render units: exposed and through a filmic curve
    // (Narkowicz), close to how Lit shows it.
    float3 x = image[p].rgb * frame.exposure;
    float3 color = saturate((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14));
    float depth = linear_depth.Load(int3(p, 0)).r;
    if (depth_empty(depth) || params.mode == TERRAIN_VIEW_EXPOSED) {
        image[p] = float4(color, 1.0);
        return;
    }
    Pixel at = pixel_at(p, (float2(p) + 0.5) * frame.inv_resolution, depth);
    float3 dx, dy;
    bool across = neighbour_step(p, depth, at, int2(1, 0), dx);
    bool down = neighbour_step(p, depth, at, int2(0, 1), dy);
    // The slope reads the smooth normal the surface is shaded with, as
    // Terrain3D reads that of its vertices; the contours know a flat surface
    // from its own triangle.
    float3 shaded = gbuffer_normal(p);
    float3 normal = shaded;
    float3 face = cross(dy, dx);
    if (across && down && dot(face, face) > 1e-20) {
        normal = normalize(face);
        if (dot(normal, at.view) > 0.0) normal = -normal;
    }

    if (params.mode == TERRAIN_VIEW_SLOPE) {
        float slope_deg = degrees(acos(clamp(shaded.y, -1.0, 1.0)));
        float intensity = smoothstep(SLOPE_ANGLE_LOW - SLOPE_SOFTNESS * 0.5, SLOPE_ANGLE_LOW + SLOPE_SOFTNESS * 0.5, slope_deg);
        float ramp = smoothstep(SLOPE_ANGLE_HIGH - SLOPE_SOFTNESS * 0.5, SLOPE_ANGLE_HIGH + SLOPE_SOFTNESS * 0.5, slope_deg);
        float3 slope_color = lerp(SLOPE_COLOR_MID.rgb, SLOPE_COLOR_HIGH.rgb, ramp);
        float strength = lerp(SLOPE_COLOR_MID.a, SLOPE_COLOR_HIGH.a, ramp) * intensity;
        color *= lerp(float3(1.0), slope_color, strength);
    } else {
        // The height in the world, and what it changes by from a pixel to the next (fwidth).
        float y = at.position.y + float(frame.origin.y) * ORIGIN_STEP;
        float y_fwidth = abs(dx.y) + abs(dy.y);
        float index_line = single_contour(CONTOUR_INDEX_THICKNESS, CONTOUR_INDEX_INTERVAL, y, y_fwidth, at.distance, normal);
        float inter_line = single_contour(CONTOUR_INTER_THICKNESS, CONTOUR_INDEX_INTERVAL * 0.2, y, y_fwidth, at.distance, normal);
        float half_line = single_contour(CONTOUR_HALF_THICKNESS, CONTOUR_INDEX_INTERVAL * 0.1, y, y_fwidth, at.distance, normal);
        float inter_op = contour_opacity(at.distance, CONTOUR_HALF_DIST, CONTOUR_INTER_DIST, 0.0, 1.0);
        float half_op = contour_opacity(at.distance, 0.0, CONTOUR_HALF_DIST, 0.0, 0.8);
        float contrib = max(max(1.0 - index_line, (1.0 - inter_line) * inter_op), (1.0 - half_line) * half_op);
        float3 line_color = CONTOUR_COLOR.rgb;
        if (params.mode == TERRAIN_VIEW_CONTOURS_HEIGHT) {
            float h = saturate((y - CONTOUR_THERMAL_HEIGHTS.x) / (CONTOUR_THERMAL_HEIGHTS.y - CONTOUR_THERMAL_HEIGHTS.x + 1e-5));
            line_color = contour_thermal(h);
        }
        color = lerp(color, line_color, contrib * CONTOUR_COLOR.a);
    }
    image[p] = float4(color, 1.0);
}
