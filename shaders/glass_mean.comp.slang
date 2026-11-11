#include "native.slang"
// The mean filter of the blended surfaces of each instance that has them
// (Instance.glass), for the rays that take it (BLEND_MEANS in trace.slang):
// those of the indirect light, and the shadow rays of what they and the
// reflections find. It is the filter of each face (blend_face_filter) over
// their area, from points spread by area over the triangles of the instance,
// each read with the footprint of its share of the surface so that the level
// of its textures averages what it stands for. A group per instance of
// glass_list; the pass runs after every upload of the instances, which brings
// the value the CPU holds.
//
// The points of faces with a program wait for it (points.slang): the group
// takes room for them one after another and a head for the instance, keeps
// the sum of the other faces and the area of all, and the resume
// (params.resume) adds what the program gives at its points and divides. A
// group of the resume takes its heads one after another, all its threads
// over the points of each. Without room, the faces take their rows.
#define INSTANCES_WRITABLE
#define POINTS_SLOT SLOT_POINTS
#include "trace.slang"
#define MIRAI_GROUP_X 64
#define MIRAI_GROUP_Y 1
#define MIRAI_GROUP_Z 1
// Triangles an instance samples at most: a mesh with more, one of each share of them.
#define GLASS_MEAN_TRIANGLES 1024u

// batch: the pass has a batch of points (render.points_begin).
struct Params_Block { uint resume; uint batch; uint pad0; uint pad1; };
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);
[[vk::binding(SLOT_PASS0, 0)]] StructuredBuffer<uint> glass_list : register(MIRAI_REGISTER(t, SLOT_PASS0), space0);

groupshared float4 sums[MIRAI_GROUP_X];
groupshared uint waiting; // points of faces with a program
groupshared uint head;    // the head of the instance; INVALID: none
groupshared uint first;   // the first of its points; INVALID: they do not fit

// The sum of a value of every thread of the group.
float4 group_sum(float4 value, uint local) {
    sums[local] = value;
    GroupMemoryBarrierWithGroupSync();
    for (uint stride = MIRAI_GROUP_X / 2u; stride > 0u; stride >>= 1u) {
        if (local < stride) sums[local] += sums[local + stride];
        GroupMemoryBarrierWithGroupSync();
    }
    return sums[0];
}

// A blended triangle an instance samples: the k-th of those it takes of its
// triangles, each of which stands for `share` of them.
struct Glass_Face {
    Mesh_Triangle t;
    Material m;
    uint primitive;
    float area;
};
bool glass_face(Instance inst, Mesh mesh, uint k, uint triangles, float share, out Glass_Face face) {
    face = (Glass_Face)0;
    uint at = min(uint(float(k) * share), triangles - 1u);
    Cluster c = mesh_cluster(mesh, at / CLUSTER_TRIANGLES);
    if (at % CLUSTER_TRIANGLES >= cluster_triangle_count(c) || !cluster_resident(mesh, c)) return false;
    face.m = material_row(material_of(inst, cluster_material(mesh, c)), inst.material_values);
    if (face.m.alpha_mode != ALPHA_BLEND) return false;
    face.primitive = ((at / CLUSTER_TRIANGLES) << PRIMITIVE_TRIANGLE_BITS) | (at % CLUSTER_TRIANGLES);
    face.t = mesh_triangle(inst, mesh, face.primitive);
    face.area = 0.5 * length(cross(transform_vector(inst.world, face.t.b.position - face.t.a.position), transform_vector(inst.world, face.t.c.position - face.t.a.position)));
    return face.area > 0.0;
}

// The barycentric weights of the center of cell i of a side x side square,
// taken to the triangle with even density.
float3 glass_cell(uint i, uint side) {
    float2 u = (float2(float(i % side), float(i / side)) + 0.5) / float(side);
    float s = sqrt(u.x);
    return float3(1.0 - s, s * (1.0 - u.y), s * u.y);
}

// The mean filter of a face over its points, as its row gives it.
float3 face_mean(Instance inst, Glass_Face face, uint side) {
    float points = float(side * side);
    float footprint = sqrt(face.area / points);
    float3 filtered = float3(0.0);
    for (uint i = 0u; i < side * side; i++) {
        float3 through;
        float3 tint = blend_filter(inst, face.m, face.t, glass_cell(i, side), footprint, through);
        filtered += blend_face_filter(face.m, tint, through);
    }
    return filtered / points;
}

bool face_waits(Material m) {
    return params.batch != 0u && m.program_id != 0u && m.program_id < points_programs();
}

// The heads of the round, one after another: the filters of their points,
// weighed by the area each stands for, added to the sum of their instance.
void resume(uint group, uint local) {
    for (uint j = 0u; j < POINTS_HEAD_GROUP; j++) {
        Point_Head h;
        if (!head_of_round(group * POINTS_HEAD_GROUP + j, h)) return;
        float3 sum = float3(0.0);
        for (uint k = local; k < h.aux[0]; k += MIRAI_GROUP_X) {
            uint index = h.point + k;
            sum += point_filter(index, point_load(index)) * point_kept(index).x;
        }
        float4 total = group_sum(float4(sum, 0.0), local);
        if (local == 0u) {
            total += instances[h.owner].glass;
            instances[h.owner].glass = float4(total.a > 0.0 ? total.rgb / total.a : float3(1.0), total.a);
        }
        GroupMemoryBarrierWithGroupSync();
    }
}

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 group : SV_GroupID, uint3 thread : SV_GroupThreadID) {
    uint local = thread.x;
    if (params.resume != 0u) {
        resume(group.x, local);
        return;
    }
    uint index = glass_list[group.x];
    Instance inst = instances[index];
    Mesh mesh = meshes[instance_mesh(inst)];
    // The triangles of level 0, a cluster after another: CLUSTER_TRIANGLES a cluster stands for each.
    uint clusters = mesh_level_clusters(mesh, 0u).y;
    uint triangles = clusters * CLUSTER_TRIANGLES;
    uint sampled = min(triangles, GLASS_MEAN_TRIANGLES);
    float share = float(triangles) / float(max(sampled, 1u));
    // A side x side grid of points on each triangle: more where there are few.
    uint side = sampled <= MIRAI_GROUP_X ? 4u : (sampled <= 4u * MIRAI_GROUP_X ? 2u : 1u);
    uint points = side * side;
    if (local == 0u) waiting = 0u;
    GroupMemoryBarrierWithGroupSync();
    float4 sum = float4(0.0);
    uint mine = 0u;
    for (uint k = local; k < sampled; k += MIRAI_GROUP_X) {
        Glass_Face face;
        if (!glass_face(inst, mesh, k, triangles, share, face)) continue;
        if (face_waits(face.m)) mine += points;
        else sum += float4(face_mean(inst, face, side), 1.0) * (face.area * share);
    }
    uint offset = 0u;
    if (mine != 0u) InterlockedAdd(waiting, mine, offset);
    GroupMemoryBarrierWithGroupSync();
    if (local == 0u) {
        head = waiting != 0u ? head_reserve() : INVALID;
        first = head != INVALID ? points_reserve(waiting) : INVALID;
    }
    GroupMemoryBarrierWithGroupSync();
    if (mine != 0u) {
        for (uint k = local; k < sampled; k += MIRAI_GROUP_X) {
            Glass_Face face;
            if (!glass_face(inst, mesh, k, triangles, share, face) || !face_waits(face.m)) continue;
            if (first == INVALID) {
                sum += float4(face_mean(inst, face, side), 1.0) * (face.area * share);
                continue;
            }
            float footprint = sqrt(face.area / float(points));
            for (uint i = 0u; i < points; i++) {
                float3 w = glass_cell(i, side);
                Material_Point point = {index, face.primitive, w.yz, footprint, face.m.program_id, POINT_FILTER | POINT_FACE, INVALID};
                point_store(first + offset, point);
                // The area the point stands for.
                point_keep(first + offset, float2(face.area * share / float(points), 0.0));
                offset++;
            }
            sum.a += face.area * share;
        }
    }
    float4 total = group_sum(sum, local);
    if (local != 0u) return;
    if (head != INVALID) {
        // The resume adds the points and divides.
        instances[index].glass = total;
        Point_Head h = point_head(first, INVALID, index);
        h.aux[0] = first != INVALID ? waiting : 0u;
        head_store(head, h);
        return;
    }
    instances[index].glass = float4(total.a > 0.0 ? total.rgb / total.a : float3(1.0), total.a);
}
