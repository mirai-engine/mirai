#include "native.slang"
// candidates: phase 1 tests again, against this frame's depth pyramid, the
// clusters phase 0 found hidden by last frame's.
//! variant candidates MIRAI_CULL_CANDIDATES=1
// The clusters of the chunks the instance pass (cull.comp) handed over, a
// group a chunk: those of the cut of the view (cut.slang) in the frustum, not
// seen only from behind (a closed mesh) and not hidden by the depth pyramid
// go to the visible list the draws of the phase read, an instance of a draw a
// cluster. Phase 0 tests against last frame's pyramid and lists the clusters
// it hides as candidates of phase 1; phase 1 against this frame's. A posed
// mesh has no boxes of its clusters: the instance stands for them. Blended
// clusters are the glass passes'. Those of materials with a Surface program
// go to a list of their own, which cull_programs.comp sorts by program.
#include "cut.slang"
#include "cull_common.slang"
#include "cull_programs.slang"
#define MIRAI_GROUP_X 64
#define MIRAI_GROUP_Y 1
#define MIRAI_GROUP_Z 1

// The clusters phase 0 found hidden: the instance and the cluster among those of its mesh.
[[vk::binding(SLOT_PASS3, 0)]] RWStructuredBuffer<uint2> cluster_candidates : register(MIRAI_REGISTER(u, SLOT_PASS3), space0);
// The visible clusters of both phases: the instance, and the cluster as a word of the index pool.
[[vk::binding(SLOT_PASS6, 0)]] RWStructuredBuffer<uint2> visible : register(MIRAI_REGISTER(u, SLOT_PASS6), space0);
// The pages of streamed meshes the cut asks for: the first word counts them,
// past the capacity too, and from PAGE_REQUEST_FIRST each is the mesh, the
// page and its priority (render.Page_Request).
[[vk::binding(SLOT_PASS7, 0)]] RWStructuredBuffer<uint> page_requests : register(MIRAI_REGISTER(u, SLOT_PASS7), space0);
// Of each slot of the pages, the stamp of the last frame that drew a cluster of the page in it.
[[vk::binding(SLOT_PASS8, 0)]] RWStructuredBuffer<uint> page_stamps : register(MIRAI_REGISTER(u, SLOT_PASS8), space0);
// The clusters of Surface programs (PROGRAMS_* of cull_common.slang).
[[vk::binding(SLOT_PASS9, 0)]] RWStructuredBuffer<uint> program_bins : register(MIRAI_REGISTER(u, SLOT_PASS9), space0);
#define PAGE_REQUEST_WORDS 4u

// Asks for the page of the children of a cluster a view draws in their place.
void page_request(uint mesh, uint page, float pixels) {
    if (params.pages.w == 0u) return;
    uint at;
    InterlockedAdd(page_requests[0], 1u, at);
    if (at >= params.pages.w) return;
    uint word = PAGE_REQUEST_FIRST + at * PAGE_REQUEST_WORDS;
    page_requests[word] = mesh;
    page_requests[word + 1u] = page;
    page_requests[word + 2u] = asuint(pixels);
}

// Stamps the slot of the page of a cluster drawn: its page is in use.
void page_stamp(Mesh mesh, Cluster c) {
    if ((mesh.flags & MESH_FLAG_STREAMED) == 0u || params.pages.y == 0u) return;
    uint base = indices[mesh.page_word + c.page * PAGE_ENTRY_WORDS];
    if (base == INVALID || base < params.pages.x) return;
    uint slot = (base - params.pages.x) / PAGE_SLOT_WORDS;
    if (slot < params.pages.y) page_stamps[slot] = params.pages.z;
}

// Lists a visible cluster of a material with a Surface program for
// cull_programs.comp; false past the capacity.
bool cluster_programmed(uint index, Mesh mesh, uint ordinal, uint phase, uint program) {
    uint base = phase == 0u ? 0u : min(program_bins[PROGRAMS_COUNT], params.program_capacity);
    uint slot;
    InterlockedAdd(program_bins[PROGRAMS_COUNT + phase], 1u, slot);
    if (base + slot >= params.program_capacity) {
        InterlockedAdd(cull_state[CULL_DROPPED + 3u], 1u);
        InterlockedAdd(stats[0].dropped[3], 1u);
        return false;
    }
    uint at = programs_entry(base + slot, params.programs);
    program_bins[at] = index;
    program_bins[at + 1u] = mesh_cluster_word(mesh, ordinal);
    program_bins[at + 2u] = program;
    InterlockedMax(program_bins[PROGRAMS_DISPATCH + 3u * phase], slot / PROGRAMS_GROUP + 1u);
    return true;
}

// Lists a visible cluster in the draw of the phase, which counts as many as
// fit, or in the list of the clusters of Surface programs.
void cluster_visible(uint index, Mesh mesh, uint ordinal, Cluster c) {
    uint phase = min(params.phase, 1u);
    uint program = materials[material_of(scene_instance(index), cluster_material(mesh, c))].shared.program_id;
    if (program != 0u && program < params.programs) {
        if (!cluster_programmed(index, mesh, ordinal, phase, program)) return;
    } else {
        uint base = phase == 0u ? 0u : cull_state[CULL_DRAW0 + 1u];
        uint room = params.visible_capacity - min(base, params.visible_capacity);
        uint slot;
        InterlockedAdd(cull_state[CULL_VISIBLE_COUNT + phase], 1u, slot);
        if (slot >= room) {
            InterlockedAdd(cull_state[CULL_DROPPED + 1u], 1u);
            InterlockedAdd(stats[0].dropped[1], 1u);
            return;
        }
        visible[base + slot] = uint2(index, mesh_cluster_word(mesh, ordinal));
        InterlockedMax(cull_state[(phase == 0u ? CULL_DRAW0 : CULL_DRAW1) + 1u], slot + 1u);
    }
    page_stamp(mesh, c);
    InterlockedAdd(stats[0].visible_clusters, 1u);
    InterlockedAdd(stats[0].visible_triangles, cluster_triangle_count(c));
    uint kind = cull_kind(instance_batched(index), mesh) * 3u;
    InterlockedAdd(stats[0].kinds[kind + 1u], 1u);
    InterlockedAdd(stats[0].kinds[kind + 2u], cluster_triangle_count(c));
    if (phase != 0u) {
        InterlockedAdd(stats[0].late[1], 1u);
        InterlockedAdd(stats[0].late[2], cluster_triangle_count(c));
    }
}

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 group : SV_GroupID, uint3 lane : SV_GroupThreadID, uint3 dispatch_id : SV_DispatchThreadID) {
#ifdef MIRAI_CULL_CANDIDATES
    if (dispatch_id.x >= min(cull_state[CULL_CANDIDATE_COUNT], params.candidate_capacity)) return;
    uint2 entry = cluster_candidates[dispatch_id.x];
    uint index = entry.x, ordinal = entry.y;
#else
    uint chunk = group.y * CULL_DISPATCH_X + group.x;
    if (chunk >= min(cull_state[CULL_CHUNK_COUNT], params.chunk_capacity)) return;
    uint2 work = chunks[chunk];
    if (lane.x > (work.y & (CULL_CHUNK - 1u))) return;
    uint index = work.x, ordinal = (work.y >> 6u) + lane.x;
#endif
    Instance inst = scene_instance(index);
    Mesh mesh = meshes[instance_mesh(inst)];
    Cluster c = mesh_cluster(mesh, ordinal);
    bool posed = mesh.posed_word != INVALID;
    float3 low = inst.bounds_min.xyz, high = inst.bounds_max.xyz;
    if (!posed) cluster_world_box(inst, mesh, c, low, high);
    // What the vertex hook moves of an instance of a batch stays in its box grown by its reach.
    if (!posed && instance_batched(index)) {
        float reach = batch_reach(batch_row(batch_of(index)));
        low -= reach;
        high += reach;
    }
#ifdef MIRAI_CULL_CANDIDATES
    if (!posed && occluded(low, high, frame.view_proj_unjittered, frame.camera_position.xyz, frame.depth_plane)) return;
#else
    float scale = instance_scale(inst);
    Cluster_Cut cut = cluster_cut(inst, scale, mesh, c, frame.cut.x);
    if (!cut.drawn) return;
    if (materials[material_of(inst, cluster_material(mesh, c))].shared.alpha_mode == ALPHA_BLEND) return;
    if (!posed) {
        if (!frustum_visible(low, high) || cluster_backfacing(inst, scale, mesh, c, low, high)) return;
        // What the depth pyramid hides asks too: it shows once what hides it moves.
        if (cut.request) page_request(instance_mesh(inst), c.child_page, cut.pixels);
        if (params.occlusion != 0u) {
            if (params.phase == 0u) {
                if (occluded(low, high, frame.prev_view_proj, frame.prev_eye.xyz, frame.prev_depth_plane)) {
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
#endif
    cluster_visible(index, mesh, ordinal, c);
}
