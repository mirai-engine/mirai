#ifndef BC_ENCODE_6H
float selector_savings(uint2 stream, uint width) {
    uint4 rows = uint4(stream.x, stream.x >> 16, stream.y, stream.y >> 16) & 65535;
    if (all(rows == rows.x)) {
        if (rows.x == ((rows.x & 15) * 0x1111u)) return 14 * width;
        return 10 * width;
    }
    uint4 paired = (rows ^ (rows >> 4)) & 0x0f0f;
    uint4 equal = uint4((paired & 255) == 0) + uint4((paired >> 8) == 0);
    return 0.5 * width * float(equal.x + equal.y + equal.z + equal.w);
}

float literal_savings(Fit fit) {
#ifdef BC_ENCODE_7
    if (fit.mode == 5) {
        uint rgb = (fit.endpoints.x | fit.endpoints.y) & 0xffffff;
        uint snapped = rgb != 0 ? min(firstbitlow(rgb), 4u) : 4;
        bool flat = ((fit.endpoints.x ^ fit.endpoints.y) & 0xffffff) == 0;
        return 10 + 24 * float(flat) + 6 * float(snapped) + selector_savings(fit.indices.xy, 2) +
               selector_savings(fit.indices.zw, 2);
    }
    return selector_savings(fit.indices.xy, index_width(fit));
#elif defined(BC_ENCODE_5)
    uint ep = fit.endpoints.x | fit.endpoints.y;
    uint snapped = ep != 0 ? min(firstbitlow(ep), 3u) : 3;
    return 4 * float(snapped) + selector_savings(fit.indices.xy, 3) +
           selector_savings(fit.indices.zw, 3);
#else
    return selector_savings(fit.indices.xy, 2);
#endif
}

#ifdef BC_ENCODE_7
void group_selectors(inout Fit fit, uint shape) {
    uint2 shape_size = shape == 0 ? uint2(2, 2) : (shape == 1 ? uint2(4, 1) : uint2(1, 4));
    for (uint y = 0; y < 4; y += shape_size.y) {
        for (uint x = 0; x < 4; x += shape_size.x) {
            uint sum = 0;
            for (uint j = 0; j < shape_size.y; ++j) {
                for (uint i = 0; i < shape_size.x; ++i) {
                    sum += index_at(fit, (y + j) * 4 + x + i);
                }
            }
            uint selector = (sum + 2) / 4;
            if (x == 0 && y == 0) selector = min(selector, 1);
            for (uint j = 0; j < shape_size.y; ++j) {
                for (uint i = 0; i < shape_size.x; ++i) {
                    set_index(fit, (y + j) * 4 + x + i, selector);
                }
            }
        }
    }
}
#endif
#else
float literal_savings(Fit fit) { return 0; }
#endif

float rate_price(Fit fit) {
#ifdef BC_ENCODE_6H
    return params.lambda * lerp(0.000060, 0.000015, fit.activity);
#elif defined(BC_ENCODE_5)
    return params.lambda * lerp(0.065, 0.34, fit.activity);
#elif defined(BC_ENCODE_7)
    if (params.cutoff > 0) return params.lambda * lerp(0.42, 1.30, fit.activity);
    return params.lambda * lerp(0.18, 0.36, fit.activity);
#else
    return params.lambda * lerp(0.132, 0.365, fit.activity);
#endif
}

float objective(Fit fit, float price, float reference_savings) {
    return fit.distortion - price * max(literal_savings(fit), reference_savings);
}

void consider(inout Fit best, inout float cost, Fit candidate, float price,
              float reused = 0) {
    float goal = objective(candidate, price, reused);
    if (goal < cost) { cost = goal; best = candidate; }
}

#ifndef BC_ENCODE_6H
Fit seed_fit(Fit base_fit, float price) {
    Fit best = base_fit;
    float cost = objective(best, price, 0);
#ifdef BC_ENCODE_7
    Fit compact = fit_mode(5, 0, 2);
    consider(best, cost, compact, price);
    for (uint step = 2; step <= (params.cutoff > 0 ? 8u : 16u); step *= 2) {
        Fit snapped = compact;
        snap_endpoints(snapped, step);
        assign_indices(snapped, false);
        consider(best, cost, snapped, price);
    }
    for (uint shape = 0; shape < 4; ++shape) {
        Fit grouped = compact;
        if (shape < 3) {
            group_selectors(grouped, shape);
            refit_indices(grouped);
        } else {
            float3 mean = 0;
            for (uint i = 0; i < 16; ++i) mean += pixels[i].xyz;
            uint3 rgb = uint3(floor(mean * (127.0 / (255 * 16)) + 0.5));
            for (uint e = 0; e < 2; ++e) {
                grouped.endpoints[e] = (grouped.endpoints[e] & 0xff000000u) |
                                       pack_bytes(uint4(rgb, 0));
            }
            grouped.indices.xy = 0;
            grouped.distortion = measure(grouped);
        }
        consider(best, cost, grouped, price);
        for (uint step = 2; step <= (params.cutoff > 0 ? 8u : 16u); step *= 2) {
            Fit snapped = grouped;
            snap_endpoints(snapped, step);
            snapped.distortion = measure(snapped);
            consider(best, cost, snapped, price);
        }
    }
#elif defined(BC_ENCODE_5)
    for (uint step = 2; step <= 8; step *= 2) {
        Fit snapped = base_fit;
        snap_endpoints(snapped, step);
        consider(best, cost, snapped, price);
    }
#endif
#if !defined(BC_ENCODE_7) && !defined(BC_ENCODE_5)
    for (uint pair = 1; pair <= 4; pair *= 4) {
        Fit grouped = base_fit;
        assign_indices(grouped, true, pair);
        refit_indices(grouped);
        consider(best, cost, grouped, price);
    }
#endif
    best.activity = base_fit.activity;
    return best;
}
#endif

#ifdef BC_COOK_RDO
groupshared Fit tile[BC_COOK_GROUP * BC_COOK_GROUP];

// Recent blocks in raster order, including a halo across group boundaries.
static const int2 neighbors[] = {
    int2(-1, 0), int2(0, -1), int2(-2, 0), int2(-1, -1),
    int2(1, -1), int2(0, -2), int2(-3, 0), int2(-2, -1),
    int2(2, -1), int2(-1, -2), int2(1, -2), int2(0, -3),
    int2(-4, 0), int2(-3, -1), int2(3, -1), int2(-2, -2),
    int2(2, -2), int2(-1, -3), int2(1, -3), int2(0, -4),
    int2(-8, 0), int2(0, -8), int2(-8, -1), int2(8, -1),
    int2(-BC_COOK_TILE, 0), int2(0, -BC_COOK_TILE),
    int2(-BC_COOK_TILE, -1), int2(BC_COOK_TILE, -1),
    int2(-32, 0), int2(0, -32), int2(-32, -1), int2(32, -1)
};

bool same_layout(Fit a, Fit b) {
#if !defined(BC_ENCODE_5) && !defined(BC_ENCODE_6H) && !defined(BC_ENCODE_7)
    return (a.endpoints.x > a.endpoints.y) == (b.endpoints.x > b.endpoints.y);
#else
    return a.mode == b.mode && a.partition == b.partition;
#endif
}

float match_bits(Fit fit, Fit reference) {
#ifdef BC_ENCODE_5
    uint2 difference = (fit.endpoints ^ reference.endpoints).xy;
    return 16 * float(all((difference & 255) == 0)) +
           16 * float(all((difference >> 8) == 0)) +
           48 * float(all(fit.indices.xy == reference.indices.xy)) +
           48 * float(all(fit.indices.zw == reference.indices.zw));
#else
    if (!same_layout(fit, reference)) return 0;
    float bits = 0;
    if (all(fit.endpoints == reference.endpoints)) bits += endpoint_bits(fit);
#if !defined(BC_ENCODE_6H) && !defined(BC_ENCODE_7)
    else if (any(fit.endpoints.xy == reference.endpoints.xy)) bits += 12;
#endif
    if (all(fit.indices == reference.indices)) bits += index_bits(fit);
#if defined(BC_ENCODE_7)
    else if (fit.mode == 5) {
        if (all(fit.indices.xy == reference.indices.xy)) bits += 31;
        if (all(fit.indices.zw == reference.indices.zw)) bits += 31;
    }
#elif !defined(BC_ENCODE_6H)
    else {
        if (fit.indices.x == reference.indices.x) bits += 12;
        if (fit.indices.y == reference.indices.y) bits += 12;
    }
#endif
    return bits;
#endif
}

float saved_bits(Fit fit, Fit reference, float overhead) {
    return max(match_bits(fit, reference) - overhead, 0);
}

Fit optimize_tile(uint2 block, uint2 blocks, uint2 origin, Fit seed, float price) {
#ifdef BC_ENCODE_6H
    const uint search = 6;
#elif defined(BC_ENCODE_5)
    const uint search = 16;
#else
    const uint search = 32;
#endif
    Fit best = seed;
    float cost = objective(best, price, 0);
    Fit nearest = seed;
    float nearest_score = INVALID_FIT;
    float nearest_overhead = 0;
    for (uint k = 0; k < search; ++k) {
        int2 at = int2(block) + neighbors[k];
        if (any(at < 0) || any(at >= int2(blocks))) continue;
        int2 local = at - int2(origin);
        Fit reference = all(local >= 0) && all(local < BC_COOK_GROUP) ?
            tile[local.y * BC_COOK_GROUP + local.x] : fits[at.y * blocks.x + at.x];
        float overhead = 6 + log2(float(abs(neighbors[k].y) * blocks.x +
                                        abs(neighbors[k].x) + 1));
        consider(best, cost, best, price, saved_bits(best, reference, overhead));
        if (match_bits(seed, reference) == endpoint_bits(seed) + index_bits(seed)) {
            continue;
        }

#if !defined(BC_ENCODE_5) && !defined(BC_ENCODE_6H) && !defined(BC_ENCODE_7)
        if (k < 12 && !all(seed.endpoints == reference.endpoints)) {
            Fit endpoints = reference;
            assign_indices(endpoints, true);
            consider(best, cost, endpoints, price, saved_bits(endpoints, reference, overhead));
        }
#endif

        Fit reused = reference;
        reused.distortion = measure(reused);
        consider(best, cost, reused, price, saved_bits(reused, reference, overhead));
        if (reused.distortion < nearest_score) {
            nearest = reference;
            nearest_score = reused.distortion;
            nearest_overhead = overhead;
        }

#ifndef BC_ENCODE_6H
#ifdef BC_ENCODE_5
        for (uint c = 0; c < 2; ++c) {
            Fit channel = best;
            uint mask = 255u << (8 * c);
            channel.endpoints.xy = (channel.endpoints.xy & ~mask) |
                                   (reference.endpoints.xy & mask);
            channel.indices[2 * c] = reference.indices[2 * c];
            channel.indices[2 * c + 1] = reference.indices[2 * c + 1];
            channel.distortion = measure(channel);
            consider(best, cost, channel, price, saved_bits(channel, reference, overhead));
        }
#endif
        if (!same_layout(seed, reference)) continue;
        Fit indices = seed;
        indices.indices = reference.indices;
        indices.distortion = measure(indices);
        consider(best, cost, indices, price, saved_bits(indices, reference, overhead));
        refit_indices(indices);
        consider(best, cost, indices, price, saved_bits(indices, reference, overhead));
#endif
    }
    if (nearest_score < INVALID_FIT) {
#if !defined(BC_ENCODE_5) && !defined(BC_ENCODE_6H) && !defined(BC_ENCODE_7)
        for (uint e = 0; e < 2; ++e) {
            Fit merged = seed;
            merged.endpoints[e] = nearest.endpoints[e];
            assign_indices(merged, true);
            consider(best, cost, merged, price, saved_bits(merged, nearest, nearest_overhead));
        }
#endif
        Fit endpoints = nearest;
        assign_indices(endpoints, true);
        consider(best, cost, endpoints, price, saved_bits(endpoints, nearest, nearest_overhead));
    }
    return best;
}
#endif
