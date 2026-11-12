// The cut of the levels of a mesh a view draws, and what hides a cluster
// from it: the cull passes and the vertices of the draws that do not go
// through them (glass, overlays) decide the same way. render/cluster.odin
// has the same test on the CPU.
#ifndef MIRAI_CUT_SLANG
#define MIRAI_CUT_SLANG
#include "scene.slang"

// The longest axis an instance scales the space of its mesh by.
float instance_scale(Instance inst) {
    float3 c0 = float3(inst.world[0].x, inst.world[1].x, inst.world[2].x);
    float3 c1 = float3(inst.world[0].y, inst.world[1].y, inst.world[2].y);
    float3 c2 = float3(inst.world[0].z, inst.world[1].z, inst.world[2].z);
    return max(length(c0), max(length(c1), length(c2)));
}

// Where the detail of a cut is chosen from: the eye and the nearest it looks
// (w), how wide a pixel is there and per metre farther, and the axis distance
// runs along (zero: from the eye whichever way). A view chooses from its eye
// (view_detail); a map of the shadows from its light (shadow_map_detail).
struct Detail {
    float4 eye;
    float2 footprint;
    float3 axis;
};

Detail view_detail() {
    Detail d;
    d.eye = frame.detail_eye;
    d.footprint = frame.detail_footprint.xy;
    d.axis = float3(0.0);
    return d;
}

// The nearest and the farthest a box lies from the eye of a detail.
float2 detail_span(Detail d, float3 low, float3 high) {
    float3 eye = d.eye.xyz;
    if (any(d.axis != 0.0)) {
        float along = dot(0.5 * (low + high) - eye, d.axis);
        float extent = dot(0.5 * (high - low), abs(d.axis));
        return float2(along - extent, along + extent);
    }
    return float2(length(eye - clamp(eye, low, high)), length(select(eye * 2.0 < low + high, high, low) - eye));
}

// How wide a pixel of a detail is at a distance from its eye.
float detail_width(Detail d, float distance) {
    return max(d.footprint.x + d.footprint.y * max(distance, d.eye.w), 1e-9);
}

// The pixels an error of the world spans at the point of a sphere nearest the
// eye the detail is chosen from.
float lod_pixels(Detail d, float3 center, float radius, float error) {
    float3 v = center - d.eye.xyz;
    float distance = (any(d.axis != 0.0) ? dot(v, d.axis) : length(v)) - radius;
    return error / detail_width(d, distance);
}

// What the cut of a view does with a cluster: whether it draws it, and
// whether it asks for the page of its children, by how many pixels its own
// error spans.
struct Cluster_Cut {
    bool drawn;
    bool request;
    float pixels;
};

// A view draws a cluster when its own error is within threshold pixels and
// that of what replaces it is not. Of a streamed mesh it draws what is in
// the pools: a cluster whose page is there, whose parent's error is not
// within the threshold, and whose own is or whose children's page is not
// there; then it asks for that page. Every page a cluster of the pools names
// as its parent's is there too (pages.odin), so the clusters drawn cover the
// mesh once. A level-0 pose stays at level 0.
Cluster_Cut cluster_cut(Detail d, Instance inst, float scale, Mesh mesh, Cluster c, float threshold) {
    Cluster_Cut cut;
    cut.request = false;
    cut.pixels = 0.0;
    if ((mesh.flags & MESH_FLAG_LEVEL0) != 0u) {
        cut.drawn = c.error == 0.0;
        return cut;
    }
    cut.pixels = lod_pixels(d, transform_point(inst.world, c.lod.xyz), c.lod.w * scale, c.error * scale);
    bool within = cut.pixels <= threshold;
    bool parent = lod_pixels(d, transform_point(inst.world, c.parent.xyz), c.parent.w * scale, c.parent_error * scale) <= threshold;
    if ((mesh.flags & MESH_FLAG_STREAMED) == 0u) {
        cut.drawn = within && !parent;
        return cut;
    }
    bool children = c.child_page != INVALID && page_resident(mesh, c.child_page);
    cut.drawn = !parent && (within || !children) && cluster_resident(mesh, c);
    cut.request = cut.drawn && !within && c.child_page != INVALID;
    return cut;
}
bool cluster_in_cut(Detail d, Instance inst, float scale, Mesh mesh, Cluster c, float threshold) {
    return cluster_cut(d, inst, scale, mesh, c, threshold).drawn;
}
// The instance passes of a cull (cull.comp, shadow_maps.comp) hand the
// clusters of an instance to their cluster passes in chunks of up to
// CULL_CHUNK, a group each, in rows of CULL_DISPATCH_X groups.
#define CULL_CHUNK 64u
#define CULL_DISPATCH_X 32768u
// The clusters of the levels of a mesh the cut can take under an instance:
// those whose least error a pixel of the threshold spans at the far side of
// its box, and whose greatest parent error none spans at the near side. Of a
// streamed mesh, up to its coarsest level: a coarser cluster stands for
// children whose page is not in the pools.
uint2 instance_clusters(Detail d, Instance inst, Mesh mesh) {
    if ((mesh.flags & MESH_FLAG_LEVEL0) != 0u) return mesh_level_clusters(mesh, 0u);
    float scale = instance_scale(inst);
    float2 span = detail_span(d, inst.bounds_min.xyz, inst.bounds_max.xyz);
    float threshold = frame.cut.x;
    float least = threshold * detail_width(d, span.x - mesh.lod_reach * scale) / scale * 0.999;
    float most = threshold * detail_width(d, span.y) / scale * 1.001;
    uint first = mesh.level_count, last = 0u;
    for (uint level = 0u; level < mesh.level_count; level++) {
        float2 errors = mesh_level_errors(mesh, level);
        if (errors.x <= most && errors.y > least) {
            first = min(first, level);
            last = level;
        }
    }
    if ((mesh.flags & MESH_FLAG_STREAMED) != 0u) {
        last = mesh.level_count - 1u;
        first = min(first, last);
    }
    if (first > last) return mesh_level_clusters(mesh, 0u);
    uint2 begin = mesh_level_clusters(mesh, first), end = mesh_level_clusters(mesh, last);
    return uint2(begin.x, end.x + end.y - begin.x);
}

// The finest of a mesh the pools hold: level 0 where it is there, else the
// clusters whose children's page is not. A mesh that does not stream draws
// level 0 whole.
bool cluster_finest_resident(Mesh mesh, Cluster c) {
    if ((mesh.flags & MESH_FLAG_STREAMED) == 0u) return true;
    return cluster_resident(mesh, c) && (c.child_page == INVALID || !page_resident(mesh, c.child_page));
}

// A box of the space of a mesh in the world under an instance.
void instance_world_box(Instance inst, float3 a, float3 b, out float3 low, out float3 high) {
    float3 center = transform_point(inst.world, (a + b) * 0.5);
    float3 half_size = (b - a) * 0.5;
    float3 extent = float3(dot(abs(inst.world[0].xyz), half_size), dot(abs(inst.world[1].xyz), half_size), dot(abs(inst.world[2].xyz), half_size));
    low = center - extent;
    high = center + extent;
}

// The box in the world of a cluster under an instance.
void cluster_world_box(Instance inst, Mesh mesh, Cluster c, out float3 low, out float3 high) {
    float3 a, b;
    cluster_box(mesh, c, a, b);
    instance_world_box(inst, a, b, low, high);
}

// As cluster_backfacing (below), for a cone of the normals in the space of the mesh
// (axis) whose normals spread from it by the sine `cutoff`.
bool cone_backfacing(Instance inst, float scale, Mesh mesh, float3 cone_axis, float cutoff, float3 low, float3 high) {
    if ((mesh.flags & MESH_FLAG_CLOSED) == 0u) return false;
    float3 c0 = float3(inst.world[0].x, inst.world[1].x, inst.world[2].x);
    float3 c1 = float3(inst.world[0].y, inst.world[1].y, inst.world[2].y);
    float3 c2 = float3(inst.world[0].z, inst.world[1].z, inst.world[2].z);
    if (min(length(c0), min(length(c1), length(c2))) < scale * 0.99) return false;
    float3 axis = normalize(transform_normal(inst.world_inv, cone_axis));
    float3 center = (low + high) * 0.5;
    float radius = length(high - low) * 0.5;
    if (frame.eye.w < 0.5) return dot(-frame.eye.xyz, axis) >= cutoff + 1e-3;
    float3 to = center - frame.eye.xyz;
    return dot(to, axis) >= cutoff * length(to) + radius;
}

// Whether the eye sees a cluster of a closed mesh only from behind its
// normals: every direction from the eye to its box is within the cutoff of
// the cone around its axis. An instance that stretches its mesh unevenly
// turns normals the cone does not hold: it is never left out.
bool cluster_backfacing(Instance inst, float scale, Mesh mesh, Cluster c, float3 low, float3 high) {
    if ((c.counts & CLUSTER_CONE) == 0u) return false;
    float2 packed = float2(float(int(c.size_z_cone << 8u) >> 24), float(int(c.size_z_cone) >> 24)) / 127.0;
    return cone_backfacing(inst, scale, mesh, oct_decode(max(packed, float2(-1.0))), float(int(c.counts) >> 24) / 127.0, low, high);
}
#endif
