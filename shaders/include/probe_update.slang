// What the passes that update the probe volume share: the probes chosen this
// frame (ddgi_select.comp: their count, then their slots, then for each
// whether it traced a ray this update, then the rays the update traced and
// the hits it lit) and the directions each traces.
#ifndef MIRAI_PROBE_UPDATE_SLANG
#define MIRAI_PROBE_UPDATE_SLANG
#include "scene.slang"

#ifdef CHOSEN_WRITABLE
[[vk::binding(SLOT_PASS2, 0)]] RWStructuredBuffer<uint> chosen : register(MIRAI_REGISTER(u, SLOT_PASS2), space0);
#else
[[vk::binding(SLOT_PASS2, 0)]] StructuredBuffer<uint> chosen : register(MIRAI_REGISTER(t, SLOT_PASS2), space0);
#endif

struct Params_Block {
    uint rays_per_probe;
    uint light_budget;
    float max_distance;
    uint frame_number; // render.Renderer.light_frame, as Probe.frames counts
    uint resume;       // ddgi_trace.comp: a thread for each head of the round of its batch (points.slang)
    uint room;         // probes the list of the chosen has room for
    // Of what the probes keep of their rays (probe_hits.slang): the changes
    // the scene lists, and the update, plus one, of the newest that left the
    // list; then the update, plus one, in which what rays meet last changed
    // everywhere, and the one in which the lights did.
    uint changes;
    uint changes_lost;
    uint seen_everywhere;
    uint lit_everywhere;
    uint pad0;
    uint pad1;
};
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);

// Where the list says whether a probe of the chosen, by its place in it,
// traced a ray this update (CHOSEN_TRACED) and whether what one of its rays
// may meet changed (CHOSEN_CROSSED), and where it counts the rays traced and
// the hits lit.
#define CHOSEN_TRACED 1u
#define CHOSEN_CROSSED 2u
uint chosen_traced(uint slot) { return 1u + params.room + slot; }
uint chosen_rays() { return 1u + 2u * params.room; }
uint chosen_lit() { return 2u + 2u * params.room; }

// What a probe keeps of its rays as an update finds it: whether it is what
// they found from where it is, with what they may meet as it was but for the
// changes listed since it last checked them (`checked`, an update plus one);
// and whether its hits were lit before the lights last changed everywhere.
struct Probe_Kept {
    bool stands;
    bool unlit;
    uint checked;
};
Probe_Kept probe_kept(uint index) {
    Probe probe = probes[index];
    uint cascade;
    int3 cell = probe_slot_cell(index, cascade);
    Probe_Kept kept;
    kept.checked = probe.hits.z;
    kept.stands = all(probe.cell.xyz == cell) && (probe.cell.w & PROBE_KEPT) != 0 && probe.hits.x >= params.seen_everywhere && probe.hits.z >= params.changes_lost;
    kept.unlit = probe.hits.y < params.lit_everywhere;
    return kept;
}

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
