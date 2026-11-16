#include "native.slang"
// The material points of a batch (points.slang), by mode: 0 starts the batch
// empty; 1 takes the points and heads appended since the last resolve as its
// window, empties the bins and gives the dispatches of a thread per point and
// per head of it; 2 counts the points of each program; 3 gives each program
// its range of the list and its dispatch; 4 lists each point in the range of
// its program (bins.slang).
#define POINTS_SLOT SLOT_POINTS
#include "points.slang"
#include "bins.slang"
#define MIRAI_GROUP_X POINTS_GROUP
#define MIRAI_GROUP_Y 1
#define MIRAI_GROUP_Z 1

// capacity and programs: of the buffer, which mode 0 writes in the header.
// frame_start: the first batch of the frame, which forgets what the batches
// of the frame before asked for.
struct Params_Block { uint mode; uint capacity; uint programs; uint frame_start; };
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);

void args_write(uint at, uint threads, uint group = POINTS_GROUP) {
    material_points[at] = (threads + group - 1u) / group;
    material_points[at + 1u] = 1u;
    material_points[at + 2u] = 1u;
}

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 dispatch_id : SV_DispatchThreadID, uint local : SV_GroupIndex) {
    uint i = dispatch_id.x;
    if (params.mode == 0u) {
        if (i != 0u) return;
        material_points[POINTS_CAPACITY] = params.capacity;
        material_points[POINTS_PROGRAMS] = params.programs;
        if (params.frame_start != 0u) material_points[POINTS_WANTED] = 0u;
        for (uint word = POINTS_COUNT; word < POINTS_HEADER; word++) material_points[word] = 0u;
        material_points[POINTS_LIMIT] = params.capacity;
        material_points[POINTS_HEADS_LIMIT] = params.capacity;
        return;
    }
    uint programs = points_programs();
    if (params.mode == 1u) {
        if (i < programs) {
            material_points[points_bin_count(i)] = 0u;
            material_points[points_bin_cursor(i)] = 0u;
        }
        if (i != 0u) return;
        uint capacity = points_capacity();
        uint count = material_points[POINTS_COUNT];
        uint heads = material_points[POINTS_HEADS];
        // What was live while they were appended: the window before, and them.
        uint live = material_points[POINTS_TO] - material_points[POINTS_FROM] + max(count, heads);
        material_points[POINTS_WANTED] = max(material_points[POINTS_WANTED], live);
        uint from = material_points[POINTS_BASE];
        uint to = min(from + count, material_points[POINTS_LIMIT]);
        uint heads_from = material_points[POINTS_HEADS_BASE];
        uint heads_to = min(heads_from + heads, material_points[POINTS_HEADS_LIMIT]);
        material_points[POINTS_FROM] = from;
        material_points[POINTS_TO] = to;
        material_points[POINTS_HEADS_FROM] = heads_from;
        material_points[POINTS_HEADS_TO] = heads_to;
        // The next round appends in the larger room outside the window.
        bool after = capacity - to >= from;
        material_points[POINTS_BASE] = after ? to : 0u;
        material_points[POINTS_LIMIT] = after ? capacity : from;
        material_points[POINTS_COUNT] = 0u;
        bool heads_after = capacity - heads_to >= heads_from;
        material_points[POINTS_HEADS_BASE] = heads_after ? heads_to : 0u;
        material_points[POINTS_HEADS_LIMIT] = heads_after ? capacity : heads_from;
        material_points[POINTS_HEADS] = 0u;
        args_write(POINTS_ARGS, to - from);
        args_write(POINTS_HEAD_ARGS, heads_to - heads_from, POINTS_HEAD_GROUP);
        return;
    }
    uint from = material_points[POINTS_FROM];
    uint to = material_points[POINTS_TO];
    if (params.mode == 3u) {
        // Few bins: one thread runs the prefix.
        if (i != 0u) return;
        uint running = 0u;
        for (uint p = 0u; p < programs; p++) {
            uint count = material_points[points_bin_count(p)];
            material_points[points_bin_offset(p)] = running;
            args_write(points_bin_args(p), count);
            running += count;
        }
        return;
    }
    // Modes 2 and 4: a thread per point of the window. A filter point with no
    // owner waiting for it (one whose ray was not weighed) is still evaluated.
    uint bins = min(programs, BINS_MAX);
    uint index = from + i;
    bool valid = index < to;
    uint program = valid ? point_load(index).program : 0u;
    uint rank = bins_rank(program, valid, bins, local, POINTS_GROUP);
    if (params.mode == 2u) {
        bins_count(material_points, points_bin_count(0u), bins, local, POINTS_GROUP);
        return;
    }
    uint place = bins_place(material_points, points_bin_cursor(0u), program, rank, bins, local, POINTS_GROUP);
    if (!valid) return;
    material_points[points_list() + material_points[points_bin_offset(program)] + place] = index;
}
