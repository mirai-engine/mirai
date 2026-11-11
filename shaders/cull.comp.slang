#include "native.slang"
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
// writes: glass behind a wall costs nothing. The instances of the batches
// (scene.slang) follow those of the scene, a thread each, with the same tests
// and their cull distance.
#include "cut.slang"
#include "cull_common.slang"
#define MIRAI_GROUP_X 64
#define MIRAI_GROUP_Y 1
#define MIRAI_GROUP_Z 1

[[vk::binding(SLOT_PASS3, 0)]] RWStructuredBuffer<uint> candidates : register(MIRAI_REGISTER(u, SLOT_PASS3), space0);
// render.Gpu_Glass_Dispatch: zero until glass is seen.
[[vk::binding(SLOT_PASS4, 0)]] RWStructuredBuffer<uint> glass_dispatch : register(MIRAI_REGISTER(u, SLOT_PASS4), space0);

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 dispatch_id : SV_DispatchThreadID) {
    uint i = dispatch_id.x;
    if (i >= frame.instance_count + frame.batches.x) return;
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
    // A blended instance has nothing for the G-buffer: its own passes draw it.
    bool blended = (inst.meta.w & INSTANCE_FLAG_BLENDED) != 0u;
    bool gone = batched && batch_faded(row, inst.bounds_min.xyz, inst.bounds_max.xyz) >= 1.0;
    bool visible = false;
    if (params.phase == 0u) {
        // What the view draws: the instances in its layers, not of the body it leaves out, in its frustum and not all behind its clip plane.
        float3 clipped = lerp(inst.bounds_min.xyz, inst.bounds_max.xyz, step(float3(0.0), frame.clip_plane.xyz));
        bool own = view_body_fade(inst.meta.w) >= 1.0;
        bool in_frustum = (inst.meta.w & INSTANCE_FLAG_HIDDEN) == 0u && !own && !gone && view_draws_layers(inst.meta.w >> INSTANCE_LAYERS_SHIFT, inst.meta.w)
            && dot(frame.clip_plane.xyz, clipped) + frame.clip_plane.w >= 0.0 && frustum_visible(inst.bounds_min.xyz, inst.bounds_max.xyz);
        bool hidden = in_frustum && params.occlusion != 0u && occluded(inst.bounds_min.xyz, inst.bounds_max.xyz, frame.prev_view_proj, frame.prev_eye.xyz, frame.prev_depth_plane);
        visible = in_frustum && !hidden;
        candidates[i] = hidden ? 1u : 0u;
        if (!in_frustum && !blended) InterlockedAdd(stats[0].culled_instances, 1u);
    } else {
        bool candidate = candidates[i] != 0u;
        visible = candidate && !(params.occlusion != 0u && occluded(inst.bounds_min.xyz, inst.bounds_max.xyz, frame.view_proj_unjittered, frame.camera_position.xyz, frame.depth_plane));
        if (candidate && !visible && !blended) InterlockedAdd(stats[0].occluded_instances, 1u);
    }
    if (visible && !batched && (inst.meta.w & INSTANCE_FLAG_TRANSLUCENT) != 0u) {
        InterlockedMax(glass_dispatch[0], params.glass_groups.x);
        InterlockedMax(glass_dispatch[1], params.glass_groups.y);
        InterlockedMax(glass_dispatch[2], 1u);
        InterlockedMax(glass_dispatch[3], params.glass_groups.z);
        InterlockedMax(glass_dispatch[4], params.glass_groups.w);
        InterlockedMax(glass_dispatch[5], 1u);
    }
    if (!visible || blended) return;
    InterlockedAdd(stats[0].visible_instances, 1u);
    InterlockedAdd(stats[0].kinds[cull_kind(batched, mesh) * 3u], 1u);
    if (params.phase != 0u) InterlockedAdd(stats[0].late[0], 1u);
    uint2 clusters = instance_clusters(inst, mesh);
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
