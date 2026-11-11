// The geometry of the scene, read here alone: the clusters of the meshes,
// their triangles and vertices, and where a skinned or deformed mesh is now
// (render/gpu_types.odin, asset/mesh.odin). The vertices and triangles of a
// cluster are read through the entry of its page, never from the mesh as a
// whole. The includer declares the pools before it: vertex_words
// (SLOT_VERTICES), indices (SLOT_INDICES, the u32 pool) and meshes
// (SLOT_MESHES).
#ifndef MIRAI_GEOMETRY_SLANG
#define MIRAI_GEOMETRY_SLANG
#include "posed.slang"

// CLUSTER_DRAW_VERTICES: the vertices a draw gives a cluster, the corners of
// as many triangles as one has. A primitive a ray meets is the cluster among
// those of its mesh, then the triangle of the cluster in the low
// PRIMITIVE_TRIANGLE_BITS bits.

Cluster cluster_at(uint word) {
    Cluster c;
    c.position = int3(asint(indices[word]), asint(indices[word + 1u]), asint(indices[word + 2u]));
    c.vertex_first = indices[word + 3u];
    c.uv = int2(asint(indices[word + 4u]), asint(indices[word + 5u]));
    c.uv1 = int2(asint(indices[word + 6u]), asint(indices[word + 7u]));
    c.triangle_first = indices[word + 8u];
    c.counts = indices[word + 9u];
    c.size_xy = indices[word + 10u];
    c.size_z_cone = indices[word + 11u];
    c.lod = asfloat(uint4(indices[word + 12u], indices[word + 13u], indices[word + 14u], indices[word + 15u]));
    c.error = asfloat(indices[word + 16u]);
    c.parent = asfloat(uint4(indices[word + 17u], indices[word + 18u], indices[word + 19u], indices[word + 20u]));
    c.parent_error = asfloat(indices[word + 21u]);
    c.page = indices[word + 22u];
    c.child_page = indices[word + 23u];
    return c;
}
// A cluster of a mesh by its place among those of the mesh.
uint mesh_cluster_word(Mesh mesh, uint ordinal) { return mesh.cluster_word + ordinal * CLUSTER_WORDS; }
Cluster mesh_cluster(Mesh mesh, uint ordinal) { return cluster_at(mesh_cluster_word(mesh, ordinal)); }
uint cluster_vertex_count(Cluster c) { return (c.counts & 0xffu) + 1u; }
uint cluster_triangle_count(Cluster c) { return (c.counts >> 8u) & 0xffu; }
uint cluster_slot(Cluster c) { return (c.counts >> 16u) & 0x1fu; }

// A level of a mesh (asset.Mesh_Level): its first cluster, how many, then past
// their triangles the least error of its clusters and the greatest of what replaces them.
uint2 mesh_level_clusters(Mesh mesh, uint level) { return uint2(indices[mesh.level_word + level * LEVEL_WORDS], indices[mesh.level_word + level * LEVEL_WORDS + 1u]); }
float2 mesh_level_errors(Mesh mesh, uint level) { return asfloat(uint2(indices[mesh.level_word + level * LEVEL_WORDS + 3u], indices[mesh.level_word + level * LEVEL_WORDS + 4u])); }

// A page of a mesh (render.Gpu_Mesh_Page): where its block is in the vertex
// pool, and the first vertex, the vertices and the first word of triangles
// of the mesh it holds.
struct Mesh_Page {
    uint base;
    uint first_vertex;
    uint vertex_count;
    uint first_triangle;
};
Mesh_Page page_at(Mesh mesh, uint page) {
    uint word = mesh.page_word + page * PAGE_ENTRY_WORDS;
    Mesh_Page p;
    p.base = indices[word];
    p.first_vertex = indices[word + 1u];
    p.vertex_count = indices[word + 2u];
    p.first_triangle = indices[word + 3u];
    return p;
}
// Whether the block of a page is in the vertex pool. The root of a mesh
// always is; a page of a streamed mesh (MESH_FLAG_STREAMED) out of it only
// while it has a slot.
bool page_resident(Mesh mesh, uint page) { return indices[mesh.page_word + page * PAGE_ENTRY_WORDS] != INVALID; }
// Whether a cluster can be read: what reads a mesh without the cut
// (cull_clusters, cut.slang) leaves out those whose page is not there.
bool cluster_resident(Mesh mesh, Cluster c) { return page_resident(mesh, c.page); }
// Where each stream of the block of a page starts in the vertex pool, as
// asset.mesh_page_layout lays it out: its vertices (VERTEX_WORDS each) at its
// base, then uv1, colors and surfaces (two words) of the streams the mesh
// has, a vertex each, then the words of its triangles.
struct Page_Layout {
    uint uv1s;
    uint colors;
    uint surfaces;
    uint triangles;
};
Page_Layout page_layout(Mesh mesh, Mesh_Page p) {
    Page_Layout l;
    l.uv1s = p.base + p.vertex_count * VERTEX_WORDS;
    l.colors = l.uv1s + ((mesh.flags & MESH_FLAG_UV1) != 0u ? p.vertex_count : 0u);
    l.surfaces = l.colors + ((mesh.flags & MESH_FLAG_COLORS) != 0u ? p.vertex_count : 0u);
    l.triangles = l.surfaces + ((mesh.flags & MESH_FLAG_SURFACE) != 0u ? p.vertex_count * 2u : 0u);
    return l;
}

// The page of a mesh that holds a vertex of it, by the index of the vertex
// in the mesh: the last whose first vertex is not past it.
uint mesh_vertex_page(Mesh mesh, uint vertex) {
    uint low = 0u, high = mesh.page_count;
    while (high - low > 1u) {
        uint middle = (low + high) / 2u;
        if (indices[mesh.page_word + middle * PAGE_ENTRY_WORDS + 1u] <= vertex) low = middle;
        else high = middle;
    }
    return low;
}
// The color of a vertex of a mesh by its index in the mesh, for what walks
// the vertices without their clusters: white for a mesh without colors.
float4 mesh_vertex_color(Mesh mesh, uint vertex) {
    if ((mesh.flags & MESH_FLAG_COLORS) == 0u) return float4(1.0);
    Mesh_Page p = page_at(mesh, mesh_vertex_page(mesh, vertex));
    return unpack_rgba8(vertex_words[page_layout(mesh, p).colors + vertex - p.first_vertex]);
}

// Where the streams of a cluster start in the vertex pool: its first vertex
// in each, and its first word of triangles.
struct Cluster_Block {
    uint vertices;
    uint uv1s;
    uint colors;
    uint surfaces;
    uint triangles;
};
Cluster_Block cluster_block(Mesh mesh, Cluster c) {
    Mesh_Page p = page_at(mesh, c.page);
    Page_Layout l = page_layout(mesh, p);
    uint local = c.vertex_first - p.first_vertex;
    Cluster_Block b;
    b.vertices = p.base + local * VERTEX_WORDS;
    b.uv1s = l.uv1s + local;
    b.colors = l.colors + local;
    b.surfaces = l.surfaces + local * 2u;
    b.triangles = l.triangles + c.triangle_first - p.first_triangle;
    return b;
}

// The vertex of its cluster a corner of a cluster names: corner 3t + k is
// corner k of triangle t.
uint block_corner(Cluster_Block b, uint corner) {
    return (vertex_words[b.triangles + corner / 4u] >> ((corner & 3u) * 8u)) & 0xffu;
}
uint3 block_triangle(Cluster_Block b, uint t) {
    return uint3(block_corner(b, t * 3u), block_corner(b, t * 3u + 1u), block_corner(b, t * 3u + 2u));
}
uint cluster_corner(Mesh mesh, Cluster c, uint corner) { return block_corner(cluster_block(mesh, c), corner); }
uint3 cluster_triangle(Mesh mesh, Cluster c, uint t) { return block_triangle(cluster_block(mesh, c), t); }

// The box and the cone of the normals of cluster k of a pose as posed now;
// false where the pose has none for it.
struct Posed_Bounds { float3 low; float3 high; bool cone; float3 axis; float cutoff; };
bool posed_bounds(Mesh mesh, uint k, out Posed_Bounds b) {
    b.low = float3(0.0);
    b.high = float3(0.0);
    b.cone = false;
    b.axis = float3(0.0, 0.0, 1.0);
    b.cutoff = 1.0;
    if (mesh.bounds_word == INVALID) return false;
    uint at = mesh.bounds_word + k * POSED_BOUNDS_WORDS;
    uint flags = vertex_words[at + 3u];
    if ((flags & POSED_BOUNDS_BOX) == 0u) return false;
    b.low = asfloat(uint3(vertex_words[at], vertex_words[at + 1u], vertex_words[at + 2u]));
    b.high = asfloat(uint3(vertex_words[at + 4u], vertex_words[at + 5u], vertex_words[at + 6u]));
    b.cone = (flags & POSED_BOUNDS_CONE) != 0u;
    b.cutoff = float(int(flags << 16u) >> 24) / 127.0;
    uint axis = vertex_words[at + 7u];
    b.axis = oct_decode(max(float2(float(int(axis << 24u) >> 24), float(int(axis << 16u) >> 24)) / 127.0, float2(-1.0)));
    return true;
}
// The material word of the slot of a cluster: the row of the table, and its source slot << 24.
uint cluster_material(Mesh mesh, Cluster c) { return indices[mesh.slot_word + cluster_slot(c)]; }

// The box of a cluster in the space of its mesh, from its grid.
void cluster_box(Mesh mesh, Cluster c, out float3 low, out float3 high) {
    low = float3(c.position) * mesh.position_step;
    high = float3(c.position + int3(int(c.size_xy & 0xffffu), int(c.size_xy >> 16u), int(c.size_z_cone & 0xffffu))) * mesh.position_step;
}

// A vertex of a mesh as shading reads it, in the space of the mesh.
struct Mesh_Point {
    float3 position;
    float3 normal;  // unit
    float4 tangent; // xyz along u, w the sign of its bitangent, sign * cross(normal, tangent)
    float2 uv;
    float2 uv1;
    float4 color;
    // A far mesh says its surface at each vertex (asset.Surface_Vertex):
    // roughness and metallic in x, MESH_SURFACE_SET with them, and the
    // emission in y; 0 for the others, whose material says it.
    uint2 surface;
};
#define MESH_SURFACE_SET (1u << 31u)

// The place of a vertex of a cluster at rest, on the grid of its mesh.
float3 block_rest_position(Mesh mesh, Cluster c, Cluster_Block b, uint local) {
    uint at = b.vertices + local * VERTEX_WORDS;
    uint xy = vertex_words[at], zu = vertex_words[at + 1u];
    return float3(c.position + int3(int(xy & 0xffffu), int(xy >> 16u), int(zu & 0xffffu))) * mesh.position_step;
}
float3 cluster_rest_position(Mesh mesh, Cluster c, uint local) { return block_rest_position(mesh, c, cluster_block(mesh, c), local); }

// A vertex of a cluster: posed at posed_word, or at rest with INVALID.
Mesh_Point cluster_point_at(Mesh mesh, Cluster c, uint local, uint posed_word) {
    Cluster_Block b = cluster_block(mesh, c);
    uint at = b.vertices + local * VERTEX_WORDS;
    uint xy = vertex_words[at], zu = vertex_words[at + 1u], vt = vertex_words[at + 2u], packed = vertex_words[at + 3u];
    Mesh_Point p;
    p.uv = float2(c.uv + int2(int(zu >> 16u), int(vt & 0xffffu))) * mesh.uv_step;
    p.uv1 = p.uv;
    if ((mesh.flags & MESH_FLAG_UV1) != 0u) {
        uint w = vertex_words[b.uv1s + local];
        p.uv1 = float2(c.uv1 + int2(int(w & 0xffffu), int(w >> 16u))) * mesh.uv1_step;
    }
    p.color = (mesh.flags & MESH_FLAG_COLORS) != 0u ? unpack_rgba8(vertex_words[b.colors + local]) : float4(1.0);
    p.surface = uint2(0u, 0u);
    if ((mesh.flags & MESH_FLAG_SURFACE) != 0u) {
        uint at_surface = b.surfaces + local * 2u;
        p.surface = uint2(vertex_words[at_surface] | MESH_SURFACE_SET, vertex_words[at_surface + 1u]);
    }
    if (posed_word != INVALID) {
        Posed_Vertex posed = posed_load(posed_word, c.vertex_first + local);
        p.position = posed.position;
        p.normal = unpack_normal(posed.normal);
        p.tangent = unpack_tangent(posed.tangent);
    } else {
        p.position = float3(c.position + int3(int(xy & 0xffffu), int(xy >> 16u), int(zu & 0xffffu))) * mesh.position_step;
        p.normal = unpack_normal(packed);
        p.tangent = unpack_tangent_angle(packed, vt >> 16u);
    }
    return p;
}
// Where a vertex of a cluster is now.
Mesh_Point cluster_point(Mesh mesh, Cluster c, uint local) { return cluster_point_at(mesh, c, local, mesh.posed_word); }
float3 cluster_position(Mesh mesh, Cluster c, uint local) {
    return mesh.posed_word != INVALID ? posed_position(mesh.posed_word, c.vertex_first + local) : cluster_rest_position(mesh, c, local);
}
// Where it was in the frame before: a mesh that is not posed does not move.
float3 cluster_position_previous(Mesh mesh, Cluster c, uint local, uint previous_word) {
    return previous_word != INVALID ? posed_position(previous_word, c.vertex_first + local) : cluster_rest_position(mesh, c, local);
}

// The cluster of a mesh and the triangle of it a primitive a ray met names.
uint primitive_cluster(uint primitive) { return primitive >> PRIMITIVE_TRIANGLE_BITS; }
uint primitive_triangle(uint primitive) { return primitive & ((1u << PRIMITIVE_TRIANGLE_BITS) - 1u); }

// A triangle of a mesh where it is now: its corners and the material word of its slot.
struct Mesh_Triangle {
    Mesh_Point a;
    Mesh_Point b;
    Mesh_Point c;
    uint material;
};
Mesh_Triangle mesh_triangle(Mesh mesh, uint primitive) {
    Cluster c = mesh_cluster(mesh, primitive_cluster(primitive));
    uint3 corners = cluster_triangle(mesh, c, primitive_triangle(primitive));
    Mesh_Triangle t;
    t.a = cluster_point(mesh, c, corners.x);
    t.b = cluster_point(mesh, c, corners.y);
    t.c = cluster_point(mesh, c, corners.z);
    t.material = cluster_material(mesh, c);
    return t;
}
// Its corners alone, and the material word.
void mesh_triangle_positions(Mesh mesh, uint primitive, out float3 a, out float3 b, out float3 d, out uint material) {
    Cluster c = mesh_cluster(mesh, primitive_cluster(primitive));
    Cluster_Block block = cluster_block(mesh, c);
    uint3 corners = block_triangle(block, primitive_triangle(primitive));
    if (mesh.posed_word != INVALID) {
        a = posed_position(mesh.posed_word, c.vertex_first + corners.x);
        b = posed_position(mesh.posed_word, c.vertex_first + corners.y);
        d = posed_position(mesh.posed_word, c.vertex_first + corners.z);
    } else {
        a = block_rest_position(mesh, c, block, corners.x);
        b = block_rest_position(mesh, c, block, corners.y);
        d = block_rest_position(mesh, c, block, corners.z);
    }
    material = cluster_material(mesh, c);
}
// The material word of the triangle a primitive names, without its corners.
uint mesh_primitive_material(Mesh mesh, uint primitive) {
    return cluster_material(mesh, mesh_cluster(mesh, primitive_cluster(primitive)));
}
#endif
