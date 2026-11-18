// Shared raster material sampling and specular antialiasing, also used by UI previews.
#ifndef MIRAI_MATERIAL_RASTER_SLANG
#define MIRAI_MATERIAL_RASTER_SLANG
#define MATERIAL_RASTER
#include "scene.slang"

// A lobe narrower than the spread of the normal across the pixel flickers:
// that spread widens it (Tokuyoshi and Kaplanyan 2019). A fragment drawn
// from the triangle of its pixel (MATERIAL_GRADIENTS) has the spread of the
// normal of the surface, without that of its normal map.
float specular_antialiasing(float3 n, float roughness) {
#ifdef MATERIAL_GRADIENTS
    float3 dx = material_gradients_normal_dx;
    float3 dy = material_gradients_normal_dy;
#else
    float3 dx = ddx(n);
    float3 dy = ddy(n);
#endif
    float variance = 0.25 * (dot(dx, dx) + dot(dy, dy));
    float alpha = roughness * roughness;
    return sqrt(sqrt(clamp(alpha * alpha + min(2.0 * variance, 0.18), 0.0, 1.0)));
}

#endif
