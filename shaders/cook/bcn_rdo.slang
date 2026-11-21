static const int2 neighbors[8] = {
    int2(-1, 0), int2(-2, 0), int2(-4, 0), int2(0, -1),
    int2(-1, -1), int2(1, -1), int2(0, -2), int2(0, -4)
};

bool same_layout(Fit a, Fit b) {
    return a.mode == b.mode && a.partition == b.partition;
}

bool address_in_tile(int2 at, int2 origin, uint2 blocks) {
    return all(at >= origin) && all(at < min(origin + BC_COOK_TILE, int2(blocks)));
}

struct RateEstimate {
    float reuse_bits;
    float mode_count;
};

float rate(Fit fit, uint2 block, uint2 blocks, int2 origin) {
    RateEstimate estimate = {};
    for (uint k = 0; k < 8; ++k) {
        int2 at = int2(block) + neighbors[k];
        if (!address_in_tile(at, origin, blocks)) continue;
        Fit reference = fits[at.y * blocks.x + at.x];
        if (fit.mode == reference.mode) estimate.mode_count += 1;
        if (!same_layout(fit, reference)) continue;
        float bits = 0;
        if (all(fit.endpoints == reference.endpoints)) bits += endpoint_bits(fit);
        if (all(fit.indices == reference.indices)) bits += index_bits(fit);
        // A short reference replaces the matching span; the other bits are literals.
        float offset = 6 + float(abs(neighbors[k].x) + 2 * abs(neighbors[k].y));
        estimate.reuse_bits = max(estimate.reuse_bits, bits - offset);
    }
    return -estimate.reuse_bits - 5 * log2(1 + estimate.mode_count);
}

void consider(inout Fit best, inout float cost, Fit candidate, float price,
              uint2 block, uint2 blocks, int2 origin) {
    if (candidate.distortion > cost + price * 140) return;
    float goal = candidate.distortion + price * rate(candidate, block, blocks, origin);
    if (goal < cost) { cost = goal; best = candidate; }
}

Fit optimize_tile(uint2 block, uint2 blocks, Fit base_fit) {
    // Variance reduces the price of distortion in textured regions.
#ifdef BC_ENCODE_6H
    // A step in the normalized half-float bit domain can move bright values by more than a byte.
    const float rate_units = 128;
#else
    const float rate_units = 8;
#endif
    float price = params.lambda * lerp(0.22, 1.0, base_fit.activity) / rate_units;
    int2 origin = int2(block / BC_COOK_TILE) * BC_COOK_TILE;
    Fit best = base_fit;
    float cost = best.distortion + price * rate(best, block, blocks, origin);
#ifdef BC_ENCODE_7
    uint3 mode_counts = 0;
    uint partition = 0;
#endif
    for (uint k = 0; k < 8; ++k) {
        int2 at = int2(block) + neighbors[k];
        if (!address_in_tile(at, origin, blocks)) continue;
        Fit reference = fits[at.y * blocks.x + at.x];
#ifdef BC_ENCODE_7
        if (reference.mode == 1) { mode_counts.x += 1; partition = reference.partition; }
        if (reference.mode == 5) mode_counts.y += 1;
        if (reference.mode == 6) mode_counts.z += 1;
#endif
        if (same_layout(base_fit, reference) && all(base_fit.endpoints == reference.endpoints) &&
            all(base_fit.indices == reference.indices)) continue;

        reference.distortion = measure(reference);
        consider(best, cost, reference, price, block, blocks, origin);

        Fit endpoints = reference;
        assign_indices(endpoints, true);
        consider(best, cost, endpoints, price, block, blocks, origin);

        if (!same_layout(base_fit, reference)) continue;
        Fit indices = base_fit;
        indices.indices = reference.indices;
        indices.distortion = measure(indices);
        consider(best, cost, indices, price, block, blocks, origin);
    }
#ifdef BC_ENCODE_7
    uint mode = 6;
    if (mode_counts.x > mode_counts.z && mode_counts.x >= mode_counts.y) mode = 1;
    if (mode_counts.y > max(mode_counts.x, mode_counts.z)) mode = 5;
    if (mode != base_fit.mode && any(mode_counts > 0)) {
        Fit collapsed = fit_mode(mode, mode == 1 ? partition : 0, 2);
        consider(best, cost, collapsed, price, block, blocks, origin);
    }
#endif
    return best;
}
