// What the passes that update the probe volume share: the probes chosen this
// frame (ddgi_select.comp: their count, then their slots) and the directions
// each traces.
#ifndef MIRAI_PROBE_UPDATE_SLANG
#define MIRAI_PROBE_UPDATE_SLANG
#include "scene.slang"

[[vk::binding(SLOT_PASS2, 0)]] StructuredBuffer<uint> chosen : register(MIRAI_REGISTER(t, SLOT_PASS2), space0);

struct Params_Block {
    uint rays_per_probe;
    uint light_budget;
    float max_distance;
    uint frame_number; // render.Renderer.frame, as Probe.frames counts
    uint resume;       // ddgi_trace.comp: a thread for each head of the round of its batch (points.slang)
    uint pad0;
    uint pad1;
    uint pad2;
};
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);

// A rotation of the set of rays for each cell of the world and cascade, the
// same every update: what a probe gives changes only when what it sees does,
// and neighbours do not share the gaps of one set of directions.
float3x3 probe_ray_rotation(int3 cell, uint cascade) {
    uint seed = hash_u32(uint(cell.x) ^ hash_u32(uint(cell.y) ^ hash_u32(uint(cell.z) ^ hash_u32(cascade + 0x9E3779B9u))));
    float u1 = random01(seed);
    float u2 = random01(seed) * 2.0 * PI;
    float u3 = random01(seed) * 2.0 * PI;
    float a = sqrt(1.0 - u1), b = sqrt(u1);
    float x = a * cos(u2), y = b * sin(u3), z = b * cos(u3), w = a * sin(u2);
    return float3x3(
        float3(1.0 - 2.0 * (y * y + z * z), 2.0 * (x * y - z * w), 2.0 * (x * z + y * w)),
        float3(2.0 * (x * y + z * w), 1.0 - 2.0 * (x * x + z * z), 2.0 * (y * z - x * w)),
        float3(2.0 * (x * z - y * w), 2.0 * (y * z + x * w), 1.0 - 2.0 * (x * x + y * y)));
}
float3 probe_ray_direction(uint probe, uint ray, uint rays) {
    uint cascade;
    int3 cell = probe_slot_cell(probe, cascade);
    return normalize(mul(probe_ray_rotation(cell, cascade), spherical_fibonacci(float(ray), float(rays))));
}

#endif
