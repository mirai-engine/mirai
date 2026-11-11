// Ray tracing provider. Both implementations return the same Hit:
//  - software: two-level BVH (instance TLAS + per-mesh BLAS) walked in compute,
//    works on every GPU (and on CPU rasterizers like lavapipe);
//  - MIRAI_HW_RT: inline ray queries against native acceleration structures.
// A future SDF or surface-cache tracer plugs in behind the same interface.
#ifndef MIRAI_TRACE_SLANG
#define MIRAI_TRACE_SLANG
#include "scene.slang"
#include "points.slang"
// The alpha of the Surface programs that change it (cook/shaders): a ray
// decides at a masked surface whether it goes on, inside its traversal.
#include <surface_coverage.slang>

// Colored shadows filter their rays through glass; a pass can ask for the
// same filters for rays of its own. MIRAI_COLORED_SHADOWS and
// MIRAI_GLASS_MEANS are constants of the stages that declare them
// (`//! constant`): declared, the stage has what they need; true in a
// pipeline, its rays do it.
#if defined(MIRAI_COLORED_SHADOWS) && !defined(MIRAI_RAY_FILTERS)
#define MIRAI_RAY_FILTERS
#endif

#if defined(MIRAI_RAY_FILTERS) || defined(MIRAI_GLASS_MEANS)
// Product of the filters a ray went through, and where it goes. A product
// does not depend on its order, so one traversal collects the filters as it
// finds them.
static float3 ray_filter;
static float3 ray_filter_direction;
static float ray_filter_distance; // where along the ray its first filter was
static float ray_filter_far;      // and its farthest one
// Metres across the ray stands for, as a beam of that width meets the glass
// face on: the glass is read at the level of what the beam covers of it.
static float ray_filter_footprint = 0.0;
#endif

// A pass whose owners resume over the points of a batch (points.slang) defers
// the filters of glass with a program: a crossing takes the mean of its
// instance and is appended as a filter point of the run of its ray; the run
// is weighed once the ray's share of what the owner gathers is known
// (filters_weigh), and filters_correction adds what the exact filters change.
// Elsewhere, glass with a program filters by its mean.
#if defined(MIRAI_RAY_FILTERS) && defined(MIRAI_DEFER_FILTERS)
#define MIRAI_FILTER_POINTS
static uint filter_chain = INVALID;     // the filter points of the owner, newest first
static uint filter_run = INVALID;       // the first of those of the ray being traced
static float3 ray_filter_fixed = float3(1.0); // what of the filters of that ray waits for no point

// The run of a ray starts empty.
void filters_begin() {
    filter_run = INVALID;
    ray_filter_fixed = float3(1.0);
}
// The ray carries `weight` times what it lets through to the owner: its run
// changes that by weight times what its exact filters change.
void filters_weigh(float3 weight) {
    if (filter_run != INVALID) point_weigh(filter_run, weight * ray_filter_fixed);
    filter_run = INVALID;
}
// A ray stopped by something solid lets nothing through: its run changes nothing.
void filters_blocked() { filter_run = INVALID; }
// A pass with colored shadows defers those of its shadow rays: each one is a
// run, weighed by the light it carries (direct_lighting, reference_lighting).
#ifdef MIRAI_COLORED_SHADOWS
#define MIRAI_SHADOW_FILTER_POINTS
#endif
// A crossing of glass with a program as a filter point, chained to the
// owner's; false when the batch is full.
bool filter_defer(uint instance_index, uint primitive, float2 bary, float t, Material m, bool exit) {
    Material_Point point;
    point.instance = instance_index;
    point.primitive = primitive;
    point.bary = bary;
    point.footprint = max(t * 0.001, 1e-4);
    point.program = m.program_id;
    point.flags = POINT_FILTER | (filter_run == INVALID ? POINT_RUN : 0u) | (exit ? POINT_EXIT : 0u);
    point.next = filter_chain;
    uint index = point_append(point);
    if (index == INVALID) return false;
    if (filter_run == INVALID) filter_run = index;
    filter_chain = index;
    return true;
}
// The exact filter of a filter point, from what its program gave there, and
// the mean its ray took in its place.
float3 filter_of_point(uint index, Material_Point point, out float3 mean) {
    mean = scene_instance(point.instance).glass.rgb;
    return point_filter(index, point);
}
// What the exact filters of a chain change of what their means gave the
// owner: for each run, its weight times the product of its exact filters less
// that of their means.
float3 filters_correction(uint chain) {
    float3 sum = float3(0.0);
    float3 exact = float3(1.0);
    float3 mean = float3(1.0);
    uint index = chain;
    for (uint step = 0u; step < points_capacity() && index != INVALID; step++) {
        Material_Point point = point_load(index);
        float3 taken;
        exact *= filter_of_point(index, point, taken);
        mean *= taken;
        if ((point.flags & POINT_RUN) != 0u) {
            sum += point_weight(index) * (exact - mean);
            exact = float3(1.0);
            mean = float3(1.0);
        }
        index = point.next;
    }
    return sum;
}
#endif

#ifdef MIRAI_RAY_FILTERS
// The color filter of a blended surface without a program for a ray that
// carries light (blend_filter). Glass also keeps what it reflects, and a
// solid counts its color and what it absorbs once, where the ray enters it.
// Rays are not bent.
float3 hit_transmission(Instance inst, Material m, Mesh_Triangle tri, float2 bary, float t, bool exit) {
    float3 through;
    float footprint = max(t * 0.001, 1e-4);
    if (ray_filter_footprint > 0.0) {
        // A beam that crosses the glass at a slant covers more of it.
        float3 face = normalize(transform_normal(inst.world_inv, cross(tri.b.position - tri.a.position, tri.c.position - tri.a.position)));
        footprint = max(footprint, ray_filter_footprint / max(abs(dot(face, ray_filter_direction)), 0.2));
    }
    float3 tint = blend_filter(inst, m, tri, float3(1.0 - bary.x - bary.y, bary.x, bary.y), footprint, through);
    if (!material_solid(m)) return tint * through;
    return exit ? through : tint * material_absorption(m, m.thickness) * through;
}
#endif

// What a ray does with the blended surfaces it meets.
#define BLEND_PASSES  0u // it goes through them
#define BLEND_STOPS   1u // they are surfaces like any other
#define BLEND_FILTERS 2u // each one multiplies ray_filter and lets the ray on
#define BLEND_MEANS   3u // each one multiplies ray_filter by the mean of its instance (Instance.glass) and lets the ray on

#ifdef MIRAI_GLASS_MEANS
// A blended surface met at t by a ray that takes the mean of its instance.
// The ray goes on whatever is left of its light: a closest hit must not stop
// at the glass.
bool hit_mean(Instance inst, float t) {
    ray_filter *= inst.glass.rgb;
    ray_filter_far = max(ray_filter_far, t);
    return false;
}
#endif

// The alpha a masked material gives a ray at a point: its maps, or the alpha
// of its program (surface_coverage.slang), which is that of the default
// material when the program does not change it.
float hit_alpha(Instance inst, Material m, Mesh_Triangle tri, float3 weights, float2 uv, float2 uv1, float2 lod, float t) {
    if (m.program_id == 0u) return material_base_color(material_instanced(m, inst.material_values), uv, uv1, lod, float3(1), true).a;
    float3 normal = transform_normal(inst.world_inv, tri.a.normal * weights.x + tri.b.normal * weights.y + tri.c.normal * weights.z);
    normal = material_ray_normal(m, inst, normal, weights, tri, uv, uv1, lod);
    float3 position = transform_point(inst.world, tri.a.position * weights.x + tri.b.position * weights.y + tri.c.position * weights.z);
    float4 vertex_color = tri.a.color * weights.x + tri.b.color * weights.y + tri.c.color * weights.z;
    Mirai_Surface_Context ctx = material_context_cone(material_context_instance(material_context(position, normal, uv, uv1, lod, true), inst, vertex_color), t * 0.004);
    ctx.material = m.row;
    float alpha;
    float4 parameters[16];
    material_parameters(m.row, inst.material_values, parameters);
    return mirai_program_alpha(m.program_id, parameters, ctx, alpha) ? alpha : MATERIAL_DEFAULT_OPACITY;
}

// What a ray that finds this triangle at distance t does: stop, or go through
// a hole of a masked material or a blended one. Only instances flagged as
// alpha tested ask.
bool hit_covers(uint instance_index, uint primitive, float2 bary, float t, uint blend) {
    Instance inst = scene_instance(instance_index);
#ifdef MIRAI_GLASS_MEANS
    // All glass: its mean, without reading the triangle.
    if (blend == BLEND_MEANS && (inst.meta.w & INSTANCE_FLAG_BLENDED) != 0u) return hit_mean(inst, t);
#endif
    Mesh mesh = meshes[instance_mesh(inst)];
    Material m = material_row(material_of(inst, mesh_primitive_material(mesh, primitive)));
    if (m.alpha_mode == ALPHA_BLEND) {
#ifdef MIRAI_RAY_FILTERS
        if (blend == BLEND_FILTERS) {
            Mesh_Triangle tri = mesh_triangle(inst, mesh, primitive);
            // The ray leaves a solid where its face looks along it.
            float3 face = transform_normal(inst.world_inv, cross(tri.b.position - tri.a.position, tri.c.position - tri.a.position));
            bool exit = dot(face, ray_filter_direction) >= 0.0;
            float3 filter;
#ifdef MIRAI_FILTER_POINTS
            if (m.program_id != 0u && filter_defer(instance_index, primitive, bary, t, m, exit)) {
                filter = inst.glass.rgb;
            } else
#endif
            {
                filter = m.program_id != 0u ? inst.glass.rgb : hit_transmission(inst, m, tri, bary, t, exit);
#ifdef MIRAI_FILTER_POINTS
                ray_filter_fixed *= filter;
#endif
            }
            ray_filter *= filter;
            ray_filter_distance = min(ray_filter_distance, t);
            return max(ray_filter.r, max(ray_filter.g, ray_filter.b)) < 1e-3;
        }
#endif
#ifdef MIRAI_GLASS_MEANS
        if (blend == BLEND_MEANS) return hit_mean(inst, t);
#endif
        return blend == BLEND_STOPS;
    }
    if (m.alpha_mode == ALPHA_OPAQUE) return true;
    Mesh_Triangle tri = mesh_triangle(inst, mesh, primitive);
    float3 weights = float3(1.0 - bary.x - bary.y, bary.x, bary.y);
    float3 edge1 = transform_vector(inst.world, tri.b.position - tri.a.position);
    float3 edge2 = transform_vector(inst.world, tri.c.position - tri.a.position);
    float2 lod = float2(hit_lod(edge1, edge2, tri.b.uv - tri.a.uv, tri.c.uv - tri.a.uv, t * 0.004), hit_lod(edge1, edge2, tri.b.uv1 - tri.a.uv1, tri.c.uv1 - tri.a.uv1, t * 0.004));
    float2 uv = tri.a.uv * weights.x + tri.b.uv * weights.y + tri.c.uv * weights.z;
    float2 uv1 = tri.a.uv1 * weights.x + tri.b.uv1 * weights.y + tri.c.uv1 * weights.z;
    return material_covers(m, hit_alpha(inst, m, tri, weights, uv, uv1, lod, t));
}


struct Hit {
    float t;
    uint instance;
    uint primitive;
    float2 bary;
};

#define TRACE_STACK 32

// The classes of instances a ray can meet. Those whose every material is
// blended are a class apart, so a ray that goes through glass never visits
// them (RAY_SOLID, RAY_GLASS and RAY_SMALL, the mask of an instance).
// The solid instances a ray meets: every one, or, in the passes of the probe
// volume (MIRAI_TRACE_NO_SMALL), all but the small ones.
#ifdef MIRAI_TRACE_NO_SMALL
#define RAY_OPAQUE RAY_SOLID
#else
#define RAY_OPAQUE (RAY_SOLID | RAY_SMALL)
#endif
// The instances of a batch that casts shadows and that no other ray sees,
// and those of one rays see and that casts none (render.Batch_Flags):
// RAY_SHADOW_ONLY and RAY_UNSHADOWED.
// What the shadow rays of lights meet, and what the rays that see surfaces meet.
#define RAY_SHADOWS (RAY_OPAQUE | RAY_SHADOW_ONLY)
#define RAY_SEEN (RAY_OPAQUE | RAY_UNSHADOWED)

#ifdef MIRAI_HW_RT
[[vk::binding(SLOT_TLAS, 0)]] RaytracingAccelerationStructure scene_tlas : register(MIRAI_REGISTER(t, SLOT_TLAS), space0);

// The cluster and the triangle of a primitive of the BLAS of the cut an
// instance is traced with: the BLAS lists the triangles of the cut, and its
// table in the index pool names where each comes from.
uint hw_primitive(uint instance_index, uint primitive) {
    uint mesh_word = scene_mesh_word(instance_index);
    return indices[meshes[mesh_word & INSTANCE_MESH_MASK].rays[(mesh_word >> INSTANCE_RAY_SHIFT) & 3u].table_word + primitive];
}

Hit trace_ray_impl(float3 origin, float3 direction, float t_min, float t_max, bool any_hit, uint blend, uint classes) {
    RayQuery<RAY_FLAG_NONE> query;
    uint flags = any_hit ? RAY_FLAG_ACCEPT_FIRST_HIT_AND_END_SEARCH : 0u;
    RayDesc ray_desc; ray_desc.Origin = origin; ray_desc.TMin = t_min; ray_desc.Direction = direction; ray_desc.TMax = t_max; query.TraceRayInline(scene_tlas, flags, classes, ray_desc);
    // Opaque instances commit their hits by themselves; the triangles of an
    // alpha tested one come here as candidates.
    while (query.Proceed()) {
        if (query.CandidateType() != CANDIDATE_NON_OPAQUE_TRIANGLE) continue;
        uint instance = uint(query.CandidateInstanceID());
        if (hit_covers(instance, hw_primitive(instance, uint(query.CandidatePrimitiveIndex())),
                query.CandidateTriangleBarycentrics(), query.CandidateTriangleRayT(), blend)) {
            query.CommitNonOpaqueTriangleHit();
        }
    }
    Hit hit;
    hit.t = -1.0;
    hit.instance = INVALID;
    hit.primitive = INVALID;
    hit.bary = float2(0.0);
    if (query.CommittedStatus() == COMMITTED_TRIANGLE_HIT) {
        hit.t = query.CommittedRayT();
        hit.instance = uint(query.CommittedInstanceID());
        hit.primitive = hw_primitive(hit.instance, uint(query.CommittedPrimitiveIndex()));
        hit.bary = query.CommittedTriangleBarycentrics();
    }
    return hit;
}

#else

[[vk::binding(SLOT_BLAS_NODES, 0)]] StructuredBuffer<Bvh_Node> blas_nodes : register(MIRAI_REGISTER(t, SLOT_BLAS_NODES), space0);
[[vk::binding(SLOT_BLAS_TRIANGLES, 0)]] StructuredBuffer<Bvh_Triangle> blas_triangles : register(MIRAI_REGISTER(t, SLOT_BLAS_TRIANGLES), space0);
[[vk::binding(SLOT_TLAS_NODES, 0)]] StructuredBuffer<Bvh_Node> tlas_nodes : register(MIRAI_REGISTER(t, SLOT_TLAS_NODES), space0);
// An instance index; TLAS_REF_GLASS marks the RAY_GLASS class, so a ray that
// goes through glass leaves the instance without reading it.
[[vk::binding(SLOT_TLAS_REFS, 0)]] StructuredBuffer<uint> tlas_refs : register(MIRAI_REGISTER(t, SLOT_TLAS_REFS), space0);

// Slab test returning the entry distance, or FLT_MAX on a miss.
float ray_box(float3 origin, float3 inv_dir, float3 bmin, float3 bmax, float t_min, float t_max) {
    float3 t0 = (bmin - origin) * inv_dir;
    float3 t1 = (bmax - origin) * inv_dir;
    float3 lo = min(t0, t1);
    float3 hi = max(t0, t1);
    float enter = max(max(lo.x, lo.y), max(lo.z, t_min));
    float exit = min(min(hi.x, hi.y), min(hi.z, t_max));
    return enter <= exit ? enter : FLT_MAX;
}

float3 safe_inverse(float3 d) {
    const float eps = 1e-12;
    return float3(1.0 / (abs(d.x) > eps ? d.x : (d.x >= 0.0 ? eps : -eps)),
                1.0 / (abs(d.y) > eps ? d.y : (d.y >= 0.0 ? eps : -eps)),
                1.0 / (abs(d.z) > eps ? d.z : (d.z >= 0.0 ? eps : -eps)));
}

// The axes of v turned so that the largest of dir (axis kz) is the last.
float3 ray_axes(float3 v, uint kz) { return kz == 0u ? v.yzx : (kz == 1u ? v.zxy : v); }

// Watertight and double sided (Woop, Benthin and Wald 2013, as pbrt-v4 has
// it): the corners move into a space where the ray runs along +z, and an edge
// two triangles share gives both the same value with opposite signs, so a ray
// through it or through a corner meets one of them. precise keeps the products
// of the edge values unfused, or the two would round apart. Barycentrics
// follow the ray query convention.
bool ray_triangle(float3 origin, float3 dir, Bvh_Triangle tri, float t_min, float t_max, out float t, out float2 bary) {
    t = 0.0;
    bary = float2(0.0);
    float3 m = abs(dir);
    uint kz = m.x > m.y ? (m.x > m.z ? 0u : 2u) : (m.y > m.z ? 1u : 2u);
    float3 d = ray_axes(dir, kz);
    float3 shear = float3(-d.x, -d.y, 1.0) / d.z;
    float3 a = ray_axes(tri.v0 - origin, kz);
    float3 b = ray_axes(tri.v1.xyz - origin, kz);
    float3 c = ray_axes(tri.v2.xyz - origin, kz);
    a.xy += shear.xy * a.z;
    b.xy += shear.xy * b.z;
    c.xy += shear.xy * c.z;
    precise float e0 = b.x * c.y - b.y * c.x;
    precise float e1 = c.x * a.y - c.y * a.x;
    precise float e2 = a.x * b.y - a.y * b.x;
    if ((e0 < 0.0 || e1 < 0.0 || e2 < 0.0) && (e0 > 0.0 || e1 > 0.0 || e2 > 0.0)) return false;
    float det = e0 + e1 + e2;
    if (det == 0.0) return false;
    t = (e0 * a.z + e1 * b.z + e2 * c.z) * shear.z / det;
    bary = float2(e1, e2) / det;
    return t > t_min && t < t_max;
}

// Walks the BVH of the cut of a mesh an instance is traced with in object
// space: mesh_word is the meta.x of the instance, its mesh and its cut. hit.t
// is groupshared with the caller, so the world-space closest hit shrinks every
// subsequent box test. A primitive is its cluster and its triangle.
bool trace_blas(uint mesh_word, float3 origin, float3 dir, float t_min, inout Hit hit, uint instance_index, bool any_hit, bool alpha_tested, uint blend) {
    Mesh_Ray ray = meshes[mesh_word & INSTANCE_MESH_MASK].rays[(mesh_word >> INSTANCE_RAY_SHIFT) & 3u];
    float3 inv_dir = safe_inverse(dir);
    uint stack[TRACE_STACK];
    uint top = 0u;
    uint node_index = ray.bvh_root;
    bool found = false;
    for (;;) {
        Bvh_Node node = blas_nodes[node_index];
        if (node.count > 0u) {
            for (uint i = 0u; i < node.count; i++) {
                Bvh_Triangle tri = blas_triangles[ray.triangle_offset + node.left_first + i];
                float t;
                float2 bary;
                if (ray_triangle(origin, dir, tri, t_min, hit.t, t, bary)) {
                    if (alpha_tested && !hit_covers(instance_index, tri.primitive, bary, t, blend)) continue;
                    hit.t = t;
                    hit.bary = bary;
                    hit.primitive = tri.primitive;
                    hit.instance = instance_index;
                    found = true;
                    if (any_hit) return true;
                }
            }
            if (top == 0u) break;
            node_index = stack[--top];
            continue;
        }
        uint left = ray.bvh_root + node.left_first;
        uint right = left + 1u;
        Bvh_Node l = blas_nodes[left];
        Bvh_Node r = blas_nodes[right];
        float tl = ray_box(origin, inv_dir, l.bounds_min, l.bounds_max, t_min, hit.t);
        float tr = ray_box(origin, inv_dir, r.bounds_min, r.bounds_max, t_min, hit.t);
        if (tl > tr) {
            float tt = tl; tl = tr; tr = tt;
            uint ti = left; left = right; right = ti;
        }
        if (tl == FLT_MAX) {
            if (top == 0u) break;
            node_index = stack[--top];
            continue;
        }
        node_index = left;
        if (tr != FLT_MAX && top < TRACE_STACK) stack[top++] = right;
    }
    return found;
}

// Walks the tree of the instances of a batch (render.batch_tree: in the BLAS
// nodes, its leaves naming instances through the order the pool keeps after
// them) and the mesh of each instance it reaches. hit.t shrinks as in
// trace_blas. The tree and the instances are relative to the anchor of the
// batch, and so is the ray that walks them.
bool trace_batch(uint batch, float3 origin, float3 direction, float t_min, inout Hit hit, bool any_hit, uint blend, uint classes) {
    Instance row = batch_row(batch);
    if ((batch_classes(row) & classes) == 0u) return false;
    origin -= batch_anchor(row);
    uint root = batch_tree(row);
    uint words = batch_records(row);
    uint order = batch_order(row);
    uint first = frame.instance_count + batch_first(row);
    bool tested = (row.meta.w & INSTANCE_FLAG_ALPHA_TESTED) != 0u;
    float3 inv_dir = safe_inverse(direction);
    uint stack[TRACE_STACK];
    uint top = 0u;
    uint node_index = root;
    bool found = false;
    Bvh_Node top_node = blas_nodes[root];
    if (ray_box(origin, inv_dir, top_node.bounds_min, top_node.bounds_max, t_min, hit.t) == FLT_MAX) return false;
    for (;;) {
        Bvh_Node node = blas_nodes[node_index];
        if (node.count > 0u) {
            for (uint i = 0u; i < node.count; i++) {
                uint local = indices[order + node.left_first + i];
                float4 world[3], inverse[3];
                batch_placement(words + local * BATCH_WORDS, float3(0.0), world, inverse);
                if (trace_blas(row.meta.x, transform_point(inverse, origin), transform_vector(inverse, direction), t_min, hit, first + local, any_hit, tested, blend)) {
                    found = true;
                    if (any_hit) return true;
                }
            }
            if (top == 0u) break;
            node_index = stack[--top];
            continue;
        }
        uint left = root + node.left_first;
        uint right = left + 1u;
        Bvh_Node l = blas_nodes[left];
        Bvh_Node r = blas_nodes[right];
        float tl = ray_box(origin, inv_dir, l.bounds_min, l.bounds_max, t_min, hit.t);
        float tr = ray_box(origin, inv_dir, r.bounds_min, r.bounds_max, t_min, hit.t);
        if (tl > tr) {
            float tt = tl; tl = tr; tr = tt;
            uint ti = left; left = right; right = ti;
        }
        if (tl == FLT_MAX) {
            if (top == 0u) break;
            node_index = stack[--top];
            continue;
        }
        node_index = left;
        if (tr != FLT_MAX && top < TRACE_STACK) stack[top++] = right;
    }
    return found;
}

Hit trace_ray_impl(float3 origin, float3 direction, float t_min, float t_max, bool any_hit, uint blend, uint classes) {
    Hit hit;
    hit.t = t_max;
    hit.instance = INVALID;
    hit.primitive = INVALID;
    hit.bary = float2(0.0);
    if (frame.instance_count == 0u && frame.batches.w == 0u) { hit.t = -1.0; return hit; }
    float3 inv_dir = safe_inverse(direction);
    uint stack[TRACE_STACK];
    uint top = 0u;
    uint node_index = 0u;
    Bvh_Node root = tlas_nodes[0];
    if (ray_box(origin, inv_dir, root.bounds_min, root.bounds_max, t_min, t_max) == FLT_MAX) { hit.t = -1.0; return hit; }
    // What rules a reference out: the glass bit for a ray that does not meet
    // glass, its absence for one that meets nothing else.
    uint unseen = (classes & RAY_GLASS) != 0u ? 0u : TLAS_REF_GLASS;
    uint wanted = (classes & RAY_SOLID) != 0u ? 0u : TLAS_REF_GLASS;
    for (;;) {
        Bvh_Node node = tlas_nodes[node_index];
        if (node.count > 0u) {
            for (uint i = 0u; i < node.count; i++) {
                uint ref = tlas_refs[node.left_first + i];
                if ((ref & unseen) != 0u || (~ref & wanted) != 0u) continue;
                uint instance_index = ref & ~TLAS_REF_GLASS;
                // A reference past the instances is a batch, which has a tree of its own.
                if (instance_batched(instance_index)) {
                    if (trace_batch(instance_index - frame.instance_count, origin, direction, t_min, hit, any_hit, blend, classes) && any_hit) return hit;
                    continue;
                }
                Instance inst = instances[instance_index];
                if ((inst.meta.w & INSTANCE_FLAG_HIDDEN) != 0u) continue;
                if ((inst.meta.w & INSTANCE_FLAG_SMALL) != 0u && (classes & RAY_SMALL) == 0u) continue;
                // The object-space direction is not renormalized, so t stays in
                // world units across instances.
                float3 o = transform_point(inst.world_inv, origin);
                float3 d = transform_vector(inst.world_inv, direction);
                if (trace_blas(inst.meta.x, o, d, t_min, hit, instance_index, any_hit, (inst.meta.w & INSTANCE_FLAG_ALPHA_TESTED) != 0u, blend) && any_hit) return hit;
            }
            if (top == 0u) break;
            node_index = stack[--top];
            continue;
        }
        uint left = node.left_first;
        uint right = left + 1u;
        Bvh_Node l = tlas_nodes[left];
        Bvh_Node r = tlas_nodes[right];
        float tl = ray_box(origin, inv_dir, l.bounds_min, l.bounds_max, t_min, hit.t);
        float tr = ray_box(origin, inv_dir, r.bounds_min, r.bounds_max, t_min, hit.t);
        if (tl > tr) {
            float tt = tl; tl = tr; tr = tt;
            uint ti = left; left = right; right = ti;
        }
        if (tl == FLT_MAX) {
            if (top == 0u) break;
            node_index = stack[--top];
            continue;
        }
        node_index = left;
        if (tr != FLT_MAX && top < TRACE_STACK) stack[top++] = right;
    }
    if (hit.instance == INVALID) hit.t = -1.0;
    return hit;
}
#endif

// The nearest surface along a ray that travels inside an instance, whatever
// its material: where the ray leaves a solid, or what stands in its way. The
// ray visits nothing beyond the box of the instance's mesh.
Hit trace_instance(uint instance_index, float3 origin, float3 direction) {
    Instance inst = scene_instance(instance_index);
    float3 o = transform_point(inst.world_inv, origin);
    float3 d = transform_vector(inst.world_inv, direction);
#ifdef MIRAI_HW_RT
    Mesh mesh = meshes[instance_mesh(inst)];
    float3 inv = 1.0 / select(abs(d) < float3(1e-12), float3(1e-12), d);
    float3 far = max((mesh.bounds_min.xyz - o) * inv, (mesh.bounds_max.xyz - o) * inv);
    return trace_ray_impl(origin, direction, 0.0, max(min(far.x, min(far.y, far.z)), 0.0) + 1e-3, false, BLEND_STOPS, RAY_SEEN | RAY_GLASS);
#else
    Hit hit;
    hit.t = FLT_MAX;
    hit.instance = INVALID;
    hit.primitive = INVALID;
    hit.bary = float2(0.0);
    trace_blas(inst.meta.x, o, d, 0.0, hit, instance_index, false, false, BLEND_STOPS);
    if (hit.instance == INVALID) hit.t = -1.0;
    return hit;
#endif
}

#ifdef MIRAI_HOOK_RAY
// The ray hook of the generation (extension_hooks.slang): whether a ray leaves
// through a gate of an extension before t_max, how far along it, and the ray
// it goes on as beyond the gate. It traces nothing.
bool mirai_ray_gate(float3 origin, float3 direction, float t_max, out float t, out float3 next_origin, out float3 next_direction);
// Light does not come back along a ray that leaves through a gate: what is
// beyond it is another place.
bool ray_gated(float3 origin, float3 direction, float t_max, out float t) {
    float3 next_origin, next_direction;
    return mirai_ray_gate(origin, direction, t_max, t, next_origin, next_direction);
}
#endif

// How a ray reached what trace_ray found.
struct Ray_Path {
    float3 origin;    // of the stretch it arrived along: beyond the gate it went through, if any
    float3 direction; // it arrived with
    float gate;       // how far along it the gate of an extension it went through was; negative: none
    float3 glass;     // what the glass it crossed leaves of the light that comes back along it
};

// The rays of the indirect light, and the shadow rays of what they find, cross
// glass as the mean filter of its instance (MIRAI_GLASS_MEANS): its detail
// averages away after a diffuse bounce. Without it they go through glass.
#ifdef MIRAI_GLASS_MEANS
#define RAY_CROSSES (MIRAI_GLASS_MEANS ? (RAY_SEEN | RAY_GLASS) : RAY_SEEN)
#define RAY_CROSSING (MIRAI_GLASS_MEANS ? BLEND_MEANS : BLEND_PASSES)
#else
#define RAY_CROSSES RAY_SEEN
#define RAY_CROSSING BLEND_PASSES
#endif

// The nearest surface along a ray from `from` to `reach`, and in path.glass
// what the glass before it leaves of light. A closest hit meets the glass
// before it but also, until it finds the surface, glass beyond it: then the
// ray goes again only as far as the surface, which leaves that glass out.
// Both share one traversal in the source.
Hit trace_segment(float3 from, float3 direction, float t_min, float reach, bool any_hit, inout Ray_Path path) {
    Hit hit;
    for (uint attempt = 0u; attempt < 2u; attempt++) {
#ifdef MIRAI_GLASS_MEANS
        ray_filter = float3(1.0);
        ray_filter_far = 0.0;
#endif
        Hit found = trace_ray_impl(from, direction, t_min, reach, any_hit, RAY_CROSSING, RAY_CROSSES);
        if (attempt == 0u) hit = found;
#ifdef MIRAI_GLASS_MEANS
        if (MIRAI_GLASS_MEANS) {
            if (attempt == 0u && hit.instance != INVALID && ray_filter_far > hit.t) {
                reach = hit.t;
                continue;
            }
            path.glass *= ray_filter;
        }
#endif
        break;
    }
    return hit;
}

// The nearest surface along a ray, which goes on beyond a gate of an extension
// it meets first: hit.t is the whole way. The segments share one traversal in
// the source, since a second call would be a second copy of it in every stage.
Hit trace_ray(float3 origin, float3 direction, float t_min, float t_max, bool any_hit, out Ray_Path path) {
    path.origin = origin;
    path.direction = direction;
    path.gate = -1.0;
    path.glass = float3(1.0);
#ifdef MIRAI_HOOK_RAY
    Hit hit;
    float3 from = origin;
    float travelled = 0.0;
    for (uint segment = 0u; segment < 2u; segment++) {
        hit = trace_segment(from, path.direction, t_min, t_max - travelled, any_hit, path);
        if (segment != 0u) break;
        float t;
        float3 next_origin, next_direction;
        if (!mirai_ray_gate(from, path.direction, hit.instance != INVALID ? hit.t : t_max, t, next_origin, next_direction)) break;
        from = next_origin;
        path.origin = next_origin;
        path.direction = next_direction;
        path.gate = t;
        travelled = t;
        t_min = 0.0;
    }
    if (hit.instance != INVALID) hit.t += travelled;
    return hit;
#else
    return trace_segment(origin, direction, t_min, t_max, any_hit, path);
#endif
}
Hit trace_ray(float3 origin, float3 direction, float t_min, float t_max, bool any_hit) {
    Ray_Path path;
    return trace_ray(origin, direction, t_min, t_max, any_hit, path);
}

bool trace_visible(float3 origin, float3 direction, float t_max) {
    if (t_max <= 0.0) return true;
#ifdef MIRAI_HOOK_RAY
    float gate;
    if (ray_gated(origin, direction, t_max, gate)) return false;
#endif
    return trace_ray_impl(origin, direction, 0.0, t_max, true, BLEND_PASSES, RAY_SHADOWS).instance == INVALID;
}

#ifdef MIRAI_RAY_FILTERS
// What the glass a ray crosses before t_max leaves of the light that comes
// back along it. The ray meets the instances that are all glass and nothing
// else: what stops it is already known. The software tree does not say where
// the glass is, so while there are few of those instances the ray tests their
// boxes one by one.
#define GLASS_LIST_MAX 16u
float3 trace_glass_filter(float3 origin, float3 direction, float t_max) {
    ray_filter = float3(1.0);
    ray_filter_direction = direction;
#ifndef MIRAI_HW_RT
    uint count = uint(frame.texturing.w);
    if (count <= GLASS_LIST_MAX) {
        uint first = uint(frame.texturing.z);
        float3 inv_dir = safe_inverse(direction);
        Hit hit;
        hit.t = t_max;
        hit.instance = INVALID;
        for (uint i = 0u; i < count; i++) {
            Bvh_Node box = tlas_nodes[first + i];
            if (ray_box(origin, inv_dir, box.bounds_min, box.bounds_max, 0.0, t_max) == FLT_MAX) continue;
            Instance inst = instances[box.left_first];
            if (trace_blas(inst.meta.x, transform_point(inst.world_inv, origin), transform_vector(inst.world_inv, direction), 0.0, hit, box.left_first, true, true, BLEND_FILTERS)) break;
        }
        return ray_filter;
    }
#endif
    trace_ray_impl(origin, direction, 0.0, t_max, true, BLEND_FILTERS, RAY_GLASS);
    return ray_filter;
}
#endif

// Shadow transport is common to both tracing providers. Without colored
// shadows it is the terminating boolean query, which never visits glass. With
// them the same query also meets the blended surfaces, which multiply the
// filter of the ray and let it on; a solid surface, or a filter that leaves
// no light, ends it. Where only the mean of the glass is seen
// (MIRAI_GLASS_MEANS without colored shadows: the lights of what the rays of
// the indirect light find), each blended surface multiplies it by the mean of
// its instance. gated: a gate of an extension the ray would leave through
// stops it; false for the ray of a light that comes through one.
float3 trace_transmission(float3 origin, float3 direction, float t_max, bool gated = true) {
    if (t_max <= 0.0) return float3(1.0);
#ifdef MIRAI_HOOK_RAY
    float gate;
    if (gated && ray_gated(origin, direction, t_max, gate)) return float3(0.0);
#endif
#if defined(MIRAI_COLORED_SHADOWS) || defined(MIRAI_GLASS_MEANS)
    // One traversal in the source, whatever the constants of the pipeline make of it.
    uint blend = BLEND_PASSES;
    uint classes = RAY_SHADOWS;
#ifdef MIRAI_GLASS_MEANS
    if (MIRAI_GLASS_MEANS) {
        blend = BLEND_MEANS;
        classes = RAY_SHADOWS | RAY_GLASS;
    }
#endif
#ifdef MIRAI_COLORED_SHADOWS
    if (MIRAI_COLORED_SHADOWS) {
        blend = BLEND_FILTERS;
        classes = RAY_SHADOWS | RAY_GLASS;
        ray_filter_direction = direction;
    }
#endif
    ray_filter = float3(1.0);
    bool blocked = trace_ray_impl(origin, direction, 0.0, t_max, true, blend, classes).instance != INVALID;
#if defined(MIRAI_COLORED_SHADOWS) && defined(MIRAI_FILTER_POINTS)
    if (MIRAI_COLORED_SHADOWS && blocked) filters_blocked();
#endif
    return blocked ? float3(0.0) : ray_filter;
#else
    return trace_ray_impl(origin, direction, 0.0, t_max, true, BLEND_PASSES, RAY_SHADOWS).instance == INVALID ? float3(1.0) : float3(0.0);
#endif
}

// The same transport, how far along the ray light was first lost: to the
// surface that stopped it or to its first filter (FLT_MAX: nowhere), and the
// instance that stopped it (INVALID: none, or a gate). The query stops at the
// first surface it finds, not the nearest.
float3 trace_transmission_blocker(float3 origin, float3 direction, float t_max, out float blocker, out uint stopper, bool gated = true) {
    blocker = FLT_MAX;
    stopper = INVALID;
    if (t_max <= 0.0) return float3(1.0);
#ifdef MIRAI_HOOK_RAY
    float gate;
    if (gated && ray_gated(origin, direction, t_max, gate)) { blocker = gate; return float3(0.0); }
#endif
#ifndef MIRAI_COLORED_SHADOWS
    Hit hit = trace_ray_impl(origin, direction, 0.0, t_max, true, BLEND_PASSES, RAY_SHADOWS);
    if (hit.instance == INVALID) return float3(1.0);
    blocker = hit.t;
    stopper = hit.instance;
    return float3(0.0);
#else
    // One traversal in the source: without colored shadows in the pipeline no
    // filter is met, and the filter and its distance stay as they start.
    ray_filter = float3(1.0);
    ray_filter_direction = direction;
    ray_filter_distance = FLT_MAX;
    Hit hit = trace_ray_impl(origin, direction, 0.0, t_max, true, MIRAI_COLORED_SHADOWS ? BLEND_FILTERS : BLEND_PASSES, MIRAI_COLORED_SHADOWS ? (RAY_SHADOWS | RAY_GLASS) : RAY_SHADOWS);
    blocker = ray_filter_distance;
    if (hit.instance == INVALID) return ray_filter;
    blocker = min(blocker, hit.t);
    stopper = hit.instance;
#ifdef MIRAI_FILTER_POINTS
    if (MIRAI_COLORED_SHADOWS) filters_blocked();
#endif
    return float3(0.0);
#endif
}

// Whether a shadow ray from origin, `reach` along direction, met what casts
// shadows and changed since the frame before (render.Occluder_Changes, in
// frame.moved): stopped by an instance that changed, or where one of a box
// that stands for several is; not stopped, through a box where one was or is,
// where its shadow left or came. stopper: the instance that stopped it at
// `stopped` (trace_transmission_blocker); INVALID for one that went through,
// or of which that is not known. Without changes it reads nothing else.
bool occluder_changed(float3 origin, float3 direction, float reach, uint stopper, float stopped) {
    uint count = frame.moved.x;
    if (count == 0u) return false;
    float3 inverse = 1.0 / select(abs(direction) > float3(1e-12), direction, float3(1e-12));
    float3 stop = origin + direction * stopped;
    for (uint i = 0u; i < count; i++) {
        float4 low = frame.moved_boxes[2u * i];
        float3 high = frame.moved_boxes[2u * i + 1u].xyz;
        uint instance = asuint(low.w);
        if (stopper != INVALID) {
            if (instance == stopper || (instance == OCCLUDERS_MANY && all(stop >= low.xyz) && all(stop <= high))) return true;
            continue;
        }
        float3 t0 = (low.xyz - origin) * inverse;
        float3 t1 = (high - origin) * inverse;
        float3 near = min(t0, t1);
        float3 far = max(t0, t1);
        if (max(max(near.x, near.y), max(near.z, 0.0)) <= min(min(far.x, far.y), min(far.z, reach))) return true;
    }
    return false;
}

// Whether light `index` of the lights of the scene moved or changed its shape
// since the frame before.
bool light_moved(uint index) {
    if ((frame.moved.z & MOVED_LIGHTS_ALL) != 0u) return true;
    for (uint i = 0u; i < frame.moved.y; i++) {
        if (frame.moved_lights[i / 4u][i % 4u] == index) return true;
    }
    return false;
}

#endif
