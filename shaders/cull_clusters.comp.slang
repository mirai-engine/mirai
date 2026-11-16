#include "native.slang"
// candidates: phase 1 tests again, against this frame's depth pyramid, the
// clusters phase 0 found hidden by last frame's.
//! constant candidates MIRAI_CULL_CANDIDATES
// The clusters of the chunks the instance pass (cull.comp) handed over, a
// group a chunk: those of the cut of the view (cut.slang) in the frustum, not
// seen only from behind (of a material not two-sided) and not hidden by the
// depth pyramid are listed with their raster bin (RASTER_BIN_*), which
// cull_bins.comp sorts them by into the visible list the draws of the phase
// read, an instance of a draw a cluster. Phase 0 tests against last frame's
// pyramid and lists the clusters it hides as candidates of phase 1; phase 1
// against this frame's. A posed mesh has no boxes of its clusters: the
// instance stands for them. Blended clusters are the glass passes'. A cluster
// of a material with a Surface program turns on the resolve of that program.
#include "cut.slang"
#include "cull_common.slang"
#define MIRAI_GROUP_X 64
#define MIRAI_GROUP_Y 1
#define MIRAI_GROUP_Z 1

// The clusters phase 0 found hidden: the instance and the cluster among those of its mesh.
[[vk::binding(SLOT_PASS3, 0)]] RWStructuredBuffer<uint2> cluster_candidates : register(MIRAI_REGISTER(u, SLOT_PASS3), space0);
// The visible clusters of both phases as the cull lists them: the instance,
// the cluster as a word of the index pool, its raster bin and depth bucket
// (cull_listed_word) and the Surface program its pixels are resolved by (0:
// its row).
[[vk::binding(SLOT_PASS6, 0)]] RWStructuredBuffer<uint4> listed : register(MIRAI_REGISTER(u, SLOT_PASS6), space0);
// The pages of streamed meshes the cut asks for: the first word counts them,
// the second the requests that found no entry, and from PAGE_REQUEST_FIRST a
// table of params.pages.w entries (a power of two), each the mesh, the page,
// its highest priority and its key (render.Page_Request).
[[vk::binding(SLOT_PASS7, 0)]] RWStructuredBuffer<uint> page_requests : register(MIRAI_REGISTER(u, SLOT_PASS7), space0);
// Of each slot of the pages, the stamp of the last frame that drew a cluster of the page in it.
[[vk::binding(SLOT_PASS8, 0)]] RWStructuredBuffer<uint> page_stamps : register(MIRAI_REGISTER(u, SLOT_PASS8), space0);
// The draws of the resolve of each Surface program (render.Gpu_Draw): a
// cluster of a program gives the draw of the program its instance.
[[vk::binding(SLOT_PASS9, 0)]] RWStructuredBuffer<uint> program_draws : register(MIRAI_REGISTER(u, SLOT_PASS9), space0);
// Of each phase and tested bin, the clusters of each depth bucket (cull_depth_word).
[[vk::binding(SLOT_PASS4, 0)]] RWStructuredBuffer<uint> depth_buckets : register(MIRAI_REGISTER(u, SLOT_PASS4), space0);
#define PAGE_REQUEST_WORDS 4u
#define PAGE_REQUEST_PROBES 32u

// Asks for the page of the children of a cluster a view draws in their place:
// its entry, found by its key (where the page is in the page table), lists it
// once with the highest priority, whatever order the threads come in.
void page_request(uint handle, Mesh mesh, uint page, float pixels) {
    uint capacity = params.pages.w;
    if (capacity == 0u) return;
    uint key = mesh.page_word + page * PAGE_ENTRY_WORDS + 1u;
    uint at = hash_u32(key);
    for (uint probe = 0u; probe < PAGE_REQUEST_PROBES; probe++) {
        uint word = PAGE_REQUEST_FIRST + ((at + probe) & (capacity - 1u)) * PAGE_REQUEST_WORDS;
        uint held;
        InterlockedCompareExchange(page_requests[word + 3u], 0u, key, held);
        if (held == 0u) {
            InterlockedAdd(page_requests[0], 1u);
            page_requests[word] = handle;
            page_requests[word + 1u] = page;
        }
        if (held == 0u || held == key) {
            InterlockedMax(page_requests[word + 2u], asuint(max(pixels, 0.0)));
            return;
        }
    }
    InterlockedAdd(page_requests[1], 1u);
}

// Stamps the slot of the page of a cluster drawn: its page is in use.
void page_stamp(Mesh mesh, Cluster c) {
    if ((mesh.flags & MESH_FLAG_STREAMED) == 0u || params.pages.y == 0u) return;
    uint base = indices[mesh.page_word + c.page * PAGE_ENTRY_WORDS];
    if (base == INVALID || base < params.pages.x) return;
    uint slot = (base - params.pages.x) / PAGE_SLOT_WORDS;
    if (slot < params.pages.y) page_stamps[slot] = params.pages.z;
}

// The depth bucket of a box: even in the logarithm of the depth of its
// center from the near plane of the view to its far one.
uint depth_bucket(float3 low, float3 high) {
    float depth = dot(frame.depth_plane.xyz, (low + high) * 0.5) + frame.depth_plane.w;
    float near = max(frame.camera_position.w, 1e-4), far = max(frame.camera_forward.w, near * 2.0);
    float t = log2(clamp(depth, near, far) / near) / log2(far / near);
    return uint(clamp(int(floor(t * float(RASTER_DEPTH_BUCKETS))), 0, int(RASTER_DEPTH_BUCKETS) - 1));
}

// Lists a visible cluster of the phase with its raster bin, while the list
// has room, and counts it in its bin; one of a tested bin, in the depth
// bucket of its box too. The lanes of a wave take their slots and add to the
// counts they share with an atomic each.
void cluster_visible(uint index, Mesh mesh, uint ordinal, Cluster c, float3 low, float3 high) {
    uint phase = min(params.phase, 1u);
    Instance inst = scene_instance(index);
    Material m = material_row(material_of(inst, cluster_material(mesh, c)), inst.material_values);
    uint base = phase == 0u ? 0u : min(cull_state[CULL_LISTED], params.visible_capacity);
    uint first = 0u;
    uint listing = WaveActiveCountBits(true);
    if (WaveIsFirstLane()) InterlockedAdd(cull_state[CULL_LISTED + phase], listing, first);
    uint slot = WaveReadLaneFirst(first) + WavePrefixCountBits(true);
    if (base + slot >= params.visible_capacity) {
        InterlockedAdd(cull_state[CULL_DROPPED + CULL_LIST_VISIBLE], 1u);
        InterlockedAdd(stats[0].dropped[CULL_LIST_VISIBLE], 1u);
        return;
    }
    uint bin = (m.two_sided != 0u ? RASTER_BIN_TWO_SIDED : 0u) | (m.alpha_mode == ALPHA_MASK || instance_fade(index, inst) > 0.0 ? RASTER_BIN_TESTED : 0u);
    // A program past those the renderer has resolves as its row.
    uint program = m.program_id < params.programs ? m.program_id : 0u;
    uint bucket = 0u;
    if ((bin & RASTER_BIN_TESTED) != 0u) {
        bucket = depth_bucket(low, high);
        InterlockedAdd(depth_buckets[cull_depth_word(phase, bin & RASTER_BIN_TWO_SIDED, bucket)], 1u);
    }
    listed[base + slot] = uint4(index, mesh_cluster_word(mesh, ordinal), cull_listed_word(bin, bucket), program);
    for (uint b = 0u; b < RASTER_BINS; b++) {
        uint binned = WaveActiveCountBits(bin == b);
        if (WaveIsFirstLane() && binned != 0u) InterlockedAdd(cull_state[CULL_BIN_COUNTS + phase * RASTER_BINS + b], binned);
    }
    uint last = WaveActiveMax(slot);
    if (WaveIsFirstLane()) InterlockedMax(cull_state[CULL_BINS_DISPATCH + 3u * phase], last / CULL_BINS_GROUP + 1u);
    if (program != 0u) program_draws[program * 4u + 1u] = 1u;
    page_stamp(mesh, c);
    uint triangles = cluster_triangle_count(c);
    uint clusters = WaveActiveCountBits(true), drawn = WaveActiveSum(triangles);
    uint kind = cull_kind(instance_batched(index), mesh);
    uint3 kinds_clusters, kinds_triangles;
    for (uint k = 0u; k < 3u; k++) {
        kinds_clusters[k] = WaveActiveCountBits(kind == k);
        kinds_triangles[k] = WaveActiveSum(kind == k ? triangles : 0u);
    }
    if (WaveIsFirstLane()) {
        InterlockedAdd(stats[0].visible_clusters, clusters);
        InterlockedAdd(stats[0].visible_triangles, drawn);
        for (uint k = 0u; k < 3u; k++) {
            if (kinds_clusters[k] == 0u) continue;
            InterlockedAdd(stats[0].kinds[k * 3u + 1u], kinds_clusters[k]);
            InterlockedAdd(stats[0].kinds[k * 3u + 2u], kinds_triangles[k]);
        }
        if (phase != 0u) {
            InterlockedAdd(stats[0].late[1], clusters);
            InterlockedAdd(stats[0].late[2], drawn);
        }
    }
}

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 group : SV_GroupID, uint3 lane : SV_GroupThreadID, uint3 dispatch_id : SV_DispatchThreadID) {
    uint index, ordinal;
    if (MIRAI_CULL_CANDIDATES) {
        if (dispatch_id.x >= min(cull_state[CULL_CANDIDATE_COUNT], params.candidate_capacity)) return;
        uint2 entry = cluster_candidates[dispatch_id.x];
        index = entry.x;
        ordinal = entry.y;
    } else {
        uint chunk = group.y * CULL_DISPATCH_X + group.x;
        if (chunk >= min(cull_state[CULL_CHUNK_COUNT], params.chunk_capacity)) return;
        uint2 work = chunks[chunk];
        if (lane.x > (work.y & (CULL_CHUNK - 1u))) return;
        index = work.x;
        ordinal = (work.y >> 6u) + lane.x;
    }
    Instance inst = scene_instance(index);
    Mesh mesh = meshes[instance_mesh(inst)];
    Cluster c = mesh_cluster(mesh, ordinal);
    bool posed = mesh.posed_word != INVALID;
    float3 low = inst.bounds_min.xyz, high = inst.bounds_max.xyz;
    // A cluster of a pose has a box where the skin wrote one this frame.
    Posed_Bounds pose;
    bool boxed = !posed || posed_bounds(mesh, ordinal, pose);
    if (!posed) cluster_world_box(inst, mesh, c, low, high);
    else if (boxed) instance_world_box(inst, pose.low, pose.high, low, high);
    // What the vertex hook moves of an instance of a batch stays in its box grown by its reach.
    if (!posed && instance_batched(index)) {
        float reach = batch_reach(batch_row(batch_of(index)));
        low -= reach;
        high += reach;
    }
    if (MIRAI_CULL_CANDIDATES) {
        if (boxed && occluded(low, high, frame.view_proj_unjittered, frame.camera_position.xyz, frame.depth_plane)) return;
    } else {
        float scale = instance_scale(inst);
        Cluster_Cut cut = cluster_cut(view_detail(), inst, scale, mesh, c, frame.cut.x);
        if (!cut.drawn) return;
        Material m = material_row(material_of(inst, cluster_material(mesh, c)), inst.material_values);
        if (m.alpha_mode == ALPHA_BLEND) return;
        if (boxed) {
            bool away = m.two_sided == 0u && (posed ? pose.cone && cone_backfacing(inst, scale, pose.axis, pose.cutoff, low, high) : cluster_backfacing(inst, scale, c, low, high));
            if (!frustum_visible(low, high) || away) return;
            // What the depth pyramid hides asks too: it shows once what hides it moves.
            if (!posed && cut.request) page_request(instance_mesh(inst), mesh, c.child_page, cut.pixels);
            if (params.occlusion != 0u) {
                if (params.phase == 0u) {
                    float3 before_low, before_high;
                    box_before(inst, low, high, before_low, before_high);
                    if (occluded(before_low, before_high, frame.prev_view_proj, frame.prev_eye.xyz, frame.prev_depth_plane)) {
                        uint slot;
                        InterlockedAdd(cull_state[CULL_CANDIDATE_COUNT], 1u, slot);
                        if (slot < params.candidate_capacity) {
                            cluster_candidates[slot] = uint2(index, ordinal);
                            InterlockedMax(cull_state[CULL_CANDIDATE_DISPATCH], slot / MIRAI_GROUP_X + 1u);
                        } else {
                            InterlockedAdd(cull_state[CULL_DROPPED + 2u], 1u);
                            InterlockedAdd(stats[0].dropped[2], 1u);
                        }
                        return;
                    }
                } else if (occluded(low, high, frame.view_proj_unjittered, frame.camera_position.xyz, frame.depth_plane)) {
                    return;
                }
            }
        }
    }
    cluster_visible(index, mesh, ordinal, c, low, high);
}
