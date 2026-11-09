// The exposure of a view (render/exposure.odin): a histogram of the light of
// its image, and the exposure value it adapts to.
#ifndef MIRAI_EXPOSURE_SLANG
#define MIRAI_EXPOSURE_SLANG

// render.MIDDLE_GRAY: the reflectance of the card a meter takes as average.
#define MIDDLE_GRAY 0.18

// Bins of log2 of a luminance in nits, from EXPOSURE_LOG_MIN to
// EXPOSURE_LOG_MAX: a sixth of a stop to a third of one each.
#define EXPOSURE_BINS 128u
#define EXPOSURE_LOG_MIN -14.0
#define EXPOSURE_LOG_MAX 28.0
// After the bins, the count of the pixels of sky.
#define EXPOSURE_SKY EXPOSURE_BINS

// The bin of a luminance in nits.
uint exposure_bin(float nits) {
    float at = (log2(max(nits, 1e-12)) - EXPOSURE_LOG_MIN) / (EXPOSURE_LOG_MAX - EXPOSURE_LOG_MIN);
    return min(uint(saturate(at) * float(EXPOSURE_BINS)), EXPOSURE_BINS - 1u);
}

// render.Gpu_Exposure.
struct Exposure_State {
    float ev100;     // what the view is exposed at
    float exposure;  // the scene-linear value of one render unit
    uint valid;      // 0 before the first image
    uint generation; // of the discontinuities of the view it belongs to
};

// The EV100 of a view with nothing to meter yet (render.exposure_first): a
// middle gray card under the strongest light, which the light scale brings
// near one.
float exposure_first(float light_scale, float2 range) {
    return clamp(log2(MIDDLE_GRAY / light_scale * (100.0 / 12.5)), range.x, range.y);
}

#endif
