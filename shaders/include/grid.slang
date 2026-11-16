// Display-only reference plane. Shared by composition and TAA reprojection;
// it never enters scene geometry or ray tracing.
#ifndef MIRAI_GRID_SLANG
#define MIRAI_GRID_SLANG

bool ground_grid_point(float2 uv, out float3 point, out float distance) {
    point = float3(0.0);
    distance = 0.0;
    if ((frame.flags & FRAME_FLAG_GRID) == 0u) return false;
    float3 origin = view_origin(uv);
    float3 direction = view_direction(uv);
    if (abs(direction.y) < 1e-4) return false;
    // The plane y = 0 of the world.
    distance = (-float(frame.origin.y) * ORIGIN_STEP - origin.y) / direction.y;
    if (distance <= 0.0) return false;
    point = origin + direction * distance;
    return true;
}

float3 ground_grid_background(float3 color, float2 uv) {
    float3 point, point_x, point_y;
    float distance, distance_x, distance_y;
    if (!ground_grid_point(uv, point, distance)) return color;
    if (!ground_grid_point(uv + float2(frame.inv_resolution.x, 0.0), point_x, distance_x) ||
        !ground_grid_point(uv + float2(0.0, frame.inv_resolution.y), point_y, distance_y)) return color;
    float3 place = float3(frame.origin.xyz) * ORIGIN_STEP; // the origin, for what is near the axes of the world
    float height = frame.camera_position.y + place.y;
    float cell = max(1.0, pow(10.0, floor(log2(max(abs(height), 1.0) / 12.0) / 3.32192809489)));
    // Lines every cell and every ten cells: what the origin adds to the ten.
    float2 coordinate = (point.xz + origin_wrap(frame.origin.xyz, float3(cell * 10.0)).xz) / cell;
    // The projected footprint replaces fragment derivatives in compute and
    // uses the same jittered rays as the surrounding rendered samples.
    float2 footprint = max((abs(point_x.xz - point.xz) + abs(point_y.xz - point.xz)) / cell, float2(1e-4));
    float2 minor_distance = abs(frac(coordinate + 0.5) - 0.5);
    float2 minor = 1.0 - smoothstep(footprint * 0.35, footprint * 1.2, minor_distance);
    float2 major_distance = abs(frac(coordinate / 10.0 + 0.5) - 0.5);
    float2 major = 1.0 - smoothstep(footprint * 0.035, footprint * 0.12, major_distance);
    float2 axis = 1.0 - smoothstep(footprint * 0.5, footprint * 1.5, abs((point.xz + place.xz) / cell));
    float reach = max(40.0, abs(height) * 30.0);
    float vertical = abs(view_direction(uv).y);
    float fade = (1.0 - smoothstep(reach * 0.3, reach, distance)) * smoothstep(0.01, 0.08, vertical);
    float parity = ((point.x + place.x >= 0.0) == (point.z + place.z >= 0.0)) ? 1.0 : -1.0;
    color += float3(0.0025, 0.0030, 0.0035) * parity * fade;
    float minor_coverage = max(minor.x, minor.y) * (1.0 - smoothstep(0.15, 0.5, max(footprint.x, footprint.y)));
    // Fixed linear HDR palette, chosen for a muted gray/axis reference under
    // the scene's ordinary ACES mapping. Transparency attenuates it normally.
    color = lerp(color, float3(0.065, 0.070, 0.081), minor_coverage * fade * 0.32);
    color = lerp(color, float3(0.085, 0.092, 0.105), max(major.x, major.y) * fade * 0.40);
    color = lerp(color, float3(0.130, 0.048, 0.045), axis.y * fade * 0.70);
    color = lerp(color, float3(0.043, 0.068, 0.140), axis.x * fade * 0.70);
    return max(color, float3(0.0));
}

#endif
