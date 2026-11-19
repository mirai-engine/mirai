// Shared raster material sampling and specular antialiasing, also used by UI previews.
#ifndef MIRAI_MATERIAL_RASTER_SLANG
#define MIRAI_MATERIAL_RASTER_SLANG
#define MATERIAL_RASTER
#include "scene.slang"

// The lobe widened by the spread of the normal across the pixel
// (roughness_widened). Resolved from the visibility target
// (MATERIAL_GRADIENTS), along an axis where the quad does not continue the
// surface the spread is that of the interpolated normal of the triangle,
// without its map.
float specular_antialiasing(float3 n, float roughness) {
    float3 dx = ddx(n);
    float3 dy = ddy(n);
#ifdef MATERIAL_GRADIENTS
    if (!material_steady.x) dx = material_normal_gradients[0];
    if (!material_steady.y) dy = material_normal_gradients[1];
#endif
    return roughness_widened(roughness, 0.25 * (dot(dx, dx) + dot(dy, dy)));
}

#endif
