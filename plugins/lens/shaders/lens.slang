// What the stages of the lens share (lens.lens_record): its parameters, the
// depth and the motion of a pixel of the image and its circle of confusion.
// The image is at the size the view is shown at; the targets of the view may
// be smaller, and are read at the same place.
#ifndef LENS_SLANG
#define LENS_SLANG
#include "scene.slang"
#define MIRAI_GROUP_X 8
#define MIRAI_GROUP_Y 8
#define MIRAI_GROUP_Z 1
// Pixels of the layer of the depth of field on a side of a tile (lens.DOF_TILE).
#define LENS_DOF_TILE 32

// lens.Gpu_Params.
struct Lens_Params {
    float4 image;   // xy size of the image, zw its inverse
    float4 target;  // xy size of what the dispatch writes, zw its inverse
    float4 dof;     // x radius of the circle of confusion of what is infinitely far, pixels of the image; y focus distance, m; z the largest radius, pixels
    float4 motion;  // x the share of the motion of a frame the shutter sees; y the largest radius and the side of a tile, pixels; zw tiles
    float4 effects; // x bloom, y its levels, z vignette, w distortion
    float4 optics;  // x chromatic aberration, y tan of half the vertical field, z aspect, w the scale that keeps the image filling the view
    uint4 level;    // x the mip written, y 1 when it is read from the image
};
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Lens_Params> lens : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);

// The texel of a target of the view at uv of the image.
int2 lens_texel(Texture2D<float4> target, float2 uv) {
    int2 size = texture_size(target, 0);
    return clamp(int2(uv * float2(size)), int2(0), size - 1);
}

// Distance along the view of what the pixel at uv shows, m: what nothing was
// drawn on is infinitely far. A nested view counts as what it shows.
float lens_distance(Texture2D<float4> linear_depth, float2 uv) {
    float depth = linear_depth.Load(int3(lens_texel(linear_depth, uv), 0)).r;
    return depth == 0.0 ? 1e30 : abs(depth);
}

// The radius of the circle of confusion at a distance, pixels of the image:
// below 0 in front of the focus.
float lens_coc(float distance) {
    return clamp(lens.dof.x * (1.0 - lens.dof.y / max(distance, 1e-4)), -lens.dof.z, lens.dof.z);
}

// How far the pixel at uv blurs to each side: half the way it moved while the
// shutter was open, pixels of the image, at most the side of a tile. What
// nothing was drawn on moves as the camera turns.
float2 lens_velocity(Texture2D<float4> motion, Texture2D<float4> linear_depth, float2 uv) {
    float2 moved = motion.Load(int3(lens_texel(motion, uv), 0)).rg;
    if (linear_depth.Load(int3(lens_texel(linear_depth, uv), 0)).r == 0.0) {
        // As the G-buffer: the unjittered places of its direction in the frame before and in this one.
        float4 direction = float4(view_ray(uv), 0.0);
        float4 current = mul(frame.view_proj_unjittered, direction);
        float4 previous = mul(frame.prev_view_proj, direction);
        moved = current.w > 1e-4 && previous.w > 1e-4 ? (previous.xy / previous.w - current.xy / current.w) * float2(0.5, -0.5) : float2(0.0);
    }
    float2 v = moved * lens.image.xy * (0.5 * lens.motion.x);
    float l = length(v);
    return l > lens.motion.y ? v * (lens.motion.y / l) : v;
}

#endif
