#include "native.slang"
// cost: counts by mesh too (cost.slang), in the frame of a request alone.
//! variant cost MIRAI_COST=1
// GPU-driven culling, by instance and then by cluster, in two phases a frame:
//  phase 0: an instance in the frustum and not hidden by last frame's depth
//           pyramid (projected with last frame's camera) hands the clusters
//           its cut can take to the cluster pass (cull_clusters.comp) in
//           chunks; one the pyramid hides is a candidate of phase 1;
//  phase 1: the candidates are tested against this frame's pyramid (built
//           from what phase 0 drew), and those it shows hand theirs over.
// The cut by instance: of the levels of its mesh, those whose clusters the
// cut can take somewhere in its box. A far object whose root already does
// hands its root alone. An instance with blended triangles that passes these
// tests turns on the glass passes, which run with dispatch sizes this pass
// writes: glass behind a wall costs nothing. Before phase 0 a pass tests
// each batch (scene.slang) once by its box, with the same tests and its cull
// distance; the groups of slots of those that pass follow the instances of
// the scene in the dispatch of both phases, a thread a slot.
#include "cut.slang"
#include "cull_common.slang"
#ifdef MIRAI_COST
#include "cost.slang"
#endif
#define MIRAI_GROUP_X 64
#define MIRAI_GROUP_Y 1
#define MIRAI_GROUP_Z 1

[[vk::binding(SLOT_PASS3, 0)]] RWStructuredBuffer<uint> candidates : register(MIRAI_REGISTER(u, SLOT_PASS3), space0);
// render.Gpu_Glass_Dispatch: zero until glass is seen.
[[vk::binding(SLOT_PASS4, 0)]] RWStructuredBuffer<uint> glass_dispatch : register(MIRAI_REGISTER(u, SLOT_PASS4), space0);
// What phase 0 starts the cull of a view with, before the cluster pass reads
// it: the draws of the resolve of the Surface programs
// (render.Gpu_Program_Draw), that of the materials without one drawn over the
// view and those of the programs empty, over no pixel, until a cluster of
// theirs turns them on and widens them to its box, and the counts and cursors
// of the depth buckets of the tested bins of both phases (cull_bins.comp),
// zero.
[[vk::binding(SLOT_PASS6, 0)]] RWStructuredBuffer<uint> depth_buckets : register(MIRAI_REGISTER(u, SLOT_PASS6), space0);
[[vk::binding(SLOT_PASS9, 0)]] RWStructuredBuffer<uint> program_draws : register(MIRAI_REGISTER(u, SLOT_PASS9), space0);

void cull_start(uint i) {
    uint threads = (max(frame.batches.z, 1u) + MIRAI_GROUP_X - 1u) / MIRAI_GROUP_X * MIRAI_GROUP_X;
    for (uint program = i; program < max(params.programs, 1u); program += threads) {
        uint at = program * PROGRAM_DRAW_WORDS;
        program_draws[at] = program == 0u ? 3u : 6u;
        program_draws[at + 1u] = program == 0u ? 1u : 0u;
        program_draws[at + 2u] = 0u;
        program_draws[at + 3u] = program;
        program_draws[at + 4u] = 0xffffffffu;
        program_draws[at + 5u] = 0xffffffffu;
        program_draws[at + 6u] = 0u;
        program_draws[at + 7u] = 0u;
    }
    for (uint word = i; word < CULL_DEPTH_WORDS; word += threads) depth_buckets[word] = 0u;
}

// What the view draws of what has that box: in its layers, not of the body it
// leaves out nor faded out whole by its values or, of a batch, by its
// distance and size (batch_faded of its row), in its frustum and not all
// behind its clip plane. The box of a batch holds those of its instances:
// where it fails, every instance fails.
bool view_draws_box(Instance inst, bool batched, Instance row, float3 low, float3 high) {
    float3 clipped = lerp(low, high, step(float3(0.0), frame.clip_plane.xyz));
    bool own = max(view_body_fade(inst), material_values_fade(inst.material_values)) >= 1.0;
    bool gone = batched && batch_faded(row, low, high) >= 1.0;
    return (inst.meta.w & INSTANCE_FLAG_HIDDEN) == 0u && !own && !gone && view_draws_layers(inst.meta.w >> INSTANCE_LAYERS_SHIFT, inst.meta.w) && view_draws_viewmodel(inst)
        && dot(frame.clip_plane.xyz, clipped) + frame.clip_plane.w >= 0.0 && frustum_visible(low, high);
}

// The groups of slots of the batches listed, after the candidates of the
// instances and the slots: a word each, the group among those of the batches.
uint batch_listed(uint k) { return frame.instance_count + frame.batches.x + k; }

// The pass before phase 0, a thread a batch drawn: one the view draws lists
// its groups of slots after the groups of the instances of the scene in the
// dispatch of both phases (CULL_INSTANCE_DISPATCH).
void cull_batch(uint b) {
    if (b >= frame.batches.z) return;
    Instance row = batch_row(b);
    float reach = batch_reach(row);
    if (!view_draws_box(row, true, row, row.bounds_min.xyz - reach, row.bounds_max.xyz + reach)) {
        if ((row.meta.w & INSTANCE_FLAG_BLENDED) == 0u) InterlockedAdd(stats[0].culled_instances, batch_count(row));
        return;
    }
    uint count = (batch_count(row) + BATCH_GROUP - 1u) / BATCH_GROUP, at;
    InterlockedAdd(cull_state[CULL_INSTANCE_DISPATCH], count, at);
    at -= (frame.instance_count + MIRAI_GROUP_X - 1u) / MIRAI_GROUP_X;
    for (uint g = 0u; g < count; g++) candidates[batch_listed(at + g)] = batch_first(row) / BATCH_GROUP + g;
}

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 dispatch_id : SV_DispatchThreadID, uint3 group_id : SV_GroupID, uint3 lane : SV_GroupThreadID) {
    if (params.phase == CULL_PHASE_BATCHES) {
        cull_start(dispatch_id.x);
        cull_batch(dispatch_id.x);
        return;
    }
    uint i = dispatch_id.x, scene_groups = (frame.instance_count + MIRAI_GROUP_X - 1u) / MIRAI_GROUP_X;
    if (group_id.x >= scene_groups) i = frame.instance_count + candidates[batch_listed(group_id.x - scene_groups)] * BATCH_GROUP + lane.x;
    else if (i >= frame.instance_count) return;
    bool batched = instance_batched(i);
    Instance row = (Instance)0;
    if (batched) {
        row = batch_row(batch_of(i));
        // The slots after the last instance of a batch fill its last group.
        if (i - frame.instance_count - batch_first(row) >= batch_count(row)) return;
    }
    Instance inst = scene_instance(i);
    Mesh mesh = meshes[instance_mesh(inst)];
    // What the vertex hook moves of an instance of a batch stays in its box grown by its reach.
    if (batched) {
        inst.bounds_min.xyz -= batch_reach(row);
        inst.bounds_max.xyz += batch_reach(row);
    }
    // The viewmodel of the view where it draws it, in front of all that could hide it.
    bool viewmodel = view_viewmodel(inst);
    float3 low = inst.bounds_min.xyz, high = inst.bounds_max.xyz;
    view_drawn_box(inst, low, high);
    // A blended instance has nothing for the G-buffer: its own passes draw it.
    bool blended = (inst.meta.w & INSTANCE_FLAG_BLENDED) != 0u;
    bool visible = false;
    bool probed = !batched && params.probe == i + 1u;
    if (params.phase == 0u) {
        bool in_frustum = view_draws_box(inst, batched, row, low, high);
        if (probed) {
            uint seen = CULL_PROBE_TESTED | (in_frustum ? CULL_PROBE_DRAWS : 0u) | (frustum_visible(low, high) ? CULL_PROBE_FRUSTUM : 0u);
            InterlockedOr(stats[0].probe[0], seen);
        }
        float3 before_low, before_high;
        box_before(inst, inst.bounds_min.xyz, inst.bounds_max.xyz, before_low, before_high);
        bool hidden = in_frustum && params.occlusion != 0u && !viewmodel && occluded(before_low, before_high, frame.prev_view_proj, frame.prev_eye.xyz, frame.prev_depth_plane);
        visible = in_frustum && !hidden;
        candidates[i] = hidden ? 1u : 0u;
        if (!in_frustum && !blended) InterlockedAdd(stats[0].culled_instances, 1u);
    } else {
        bool candidate = candidates[i] != 0u;
        visible = candidate && !(params.occlusion != 0u && occluded(low, high, frame.view_proj_unjittered, frame.camera_position.xyz, frame.depth_plane));
        if (candidate && !visible && !blended) InterlockedAdd(stats[0].occluded_instances, 1u);
    }
    if (probed && visible) {
        InterlockedOr(stats[0].probe[0], CULL_PROBE_VISIBLE);
        stats[0].probe[1] = instance_levels(view_detail(), inst, mesh).x + 1u;
    }
    if (visible && !batched && params.glass_groups.x != 0u && (inst.meta.x & INSTANCE_FLAG_GLASS) != 0u) {
        InterlockedMax(glass_dispatch[0], params.glass_groups.x);
        InterlockedMax(glass_dispatch[1], params.glass_groups.y);
        InterlockedMax(glass_dispatch[2], 1u);
    }
    if (!visible || blended) return;
    InterlockedAdd(stats[0].visible_instances, 1u);
#ifdef MIRAI_COST
    cost_add(instance_mesh(inst), INVALID, COST_INSTANCES, 1u);
#endif
    InterlockedAdd(stats[0].kinds[cull_kind(batched, mesh) * 3u], 1u);
    if (params.phase != 0u) InterlockedAdd(stats[0].late[0], 1u);
    uint2 clusters = instance_clusters(view_detail(), inst, mesh);
    uint count = (clusters.y + CULL_CHUNK - 1u) / CULL_CHUNK;
    uint base;
    InterlockedAdd(cull_state[CULL_CHUNK_COUNT], count, base);
    uint kept = base >= params.chunk_capacity ? 0u : min(count, params.chunk_capacity - base);
    if (kept < count) {
        InterlockedAdd(cull_state[CULL_DROPPED], count - kept);
        InterlockedAdd(stats[0].dropped[0], count - kept);
    }
    for (uint k = 0u; k < kept; k++) {
        uint first = k * CULL_CHUNK;
        chunks[base + k] = uint2(i, ((clusters.x + first) << 6u) | (min(CULL_CHUNK, clusters.y - first) - 1u));
    }
    if (kept > 0u) {
        uint total = base + kept;
        InterlockedMax(cull_state[CULL_CHUNK_DISPATCH], min(total, CULL_DISPATCH_X));
        InterlockedMax(cull_state[CULL_CHUNK_DISPATCH + 1u], (total + CULL_DISPATCH_X - 1u) / CULL_DISPATCH_X);
    }
}
