#include "native.slang"
//! per surface program only
// The material points of one Surface program (points.slang) in the window of
// the resolve: what the program gives at each, or the filter of a filter
// point, in its record. A thread per point of its bin, or, when the scene has
// no other program (whole), a thread per point of the window, unbinned.
// It reports the levels it samples of each texture (texture_feedback in scene.slang).
#define MIRAI_TEXTURE_FEEDBACK
#define POINTS_SLOT SLOT_POINTS
#include "scene.slang"
#include "points.slang"
#define MIRAI_GROUP_X POINTS_GROUP
#define MIRAI_GROUP_Y 1
#define MIRAI_GROUP_Z 1

struct Params_Block { uint program; uint whole; uint pad0; uint pad1; };
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 dispatch_id : SV_DispatchThreadID) {
    uint i = dispatch_id.x;
    uint program = params.program;
    uint index;
    if (params.whole != 0u) {
        index = material_points[POINTS_FROM] + i;
        if (index >= material_points[POINTS_TO]) return;
    } else {
        if (i >= material_points[points_bin_count(program)]) return;
        index = material_points[points_list() + material_points[points_bin_offset(program)] + i];
    }
    Material_Point point = point_load(index);
    // Room reserved past the end of a batch keeps no program.
    if (point.program != program) return;
    Hit_Point h = hit_point(point.instance, point.primitive, point.bary, point.footprint);
    // A filter needs only what tints and lets light through: the rest of the program goes unused.
    if ((point.flags & POINT_FILTER) != 0u) point_filter_store(index, point_filter_at(point, h, true, hit_program(h)));
    else point_record_store(index, hit_program(h));
}
