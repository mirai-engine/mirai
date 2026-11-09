package asset

import "core:mem"
import "mirai:std/base"
import "mirai:std/geom"
import mm "mirai:std/math"
import "mirai:std/compressor/lz"
import "mirai:std/serial"

// .mesh: geometry as the renderer draws and traces it, in clusters, with what
// the editor, physics and animation need next to it.
//
//   mesh               Mesh_Info, one row
//   clusters   bulk    Cluster: up to CLUSTER_TRIANGLES triangles of one slot and their vertices
//   levels             Mesh_Level: the clusters of each level, finest first
//   pages      bulk    Mesh_Page: runs of clusters of one level and their vertices and triangles
//   page_data  bulk    the block of each page (mesh_page_layout), coded, then LZ
//   vertices   bulk    skin (Skin_Vertex) of each vertex, on a skinned mesh
//   slots              Material_Slot: the materials the model names
//   joints             mapping to the skeleton and this mesh's inverse binds
//   morphs             Morph_Target, with morph_deltas as bulk (morph.odin)
//   colliders          Collider, with collision_points and collision_indices as bulk
//
// The levels of a static mesh are a DAG: a cluster of a level is replaced by
// clusters of the next one wherever its error is small enough, and a view
// draws the clusters whose own error is within its threshold and whose
// parent's is not. The levels of a skinned mesh, or of foliage pruned by
// islands, are whole meshes (Levels) whose clusters share one sphere, so the
// same test picks one of them. Every bulk column is LZ but page_data, whose
// pages are coded and LZ one by one.
//
// A page holds whole groups of one level (the clusters that share a parent)
// while its block fits in MESH_PAGE_WORDS; a group of a DAG never spans two.
// Its clusters, vertices and words of triangles are contiguous runs of those
// of the mesh, so the pages cover them in order, finest first. A cluster
// names its page and the page of the group it was simplified from, which
// holds its children. Pages [root_page, page count) are the root: whole
// levels from the coarsest while they fit in MESH_ROOT_WORDS, and every
// cluster nothing replaces, so the coarsest cut is always there. Skinned,
// deformed (morphs) and whole-level (Levels) meshes are root whole.
//
// Positions and texture coordinates are integers of grids of the whole mesh
// (position_step, uv_step, uv1_step), stored in each cluster from its lowest
// corner in 16 bits: a vertex two clusters share decodes the same in both,
// and neighbours meet without cracks.
//
// Skin vertices are immutable bind-space geometry. The palette transforms them
// by inverse(mesh_node_world) * joint_world * inverse_bind.

MESH_VERSION :: 11
MESH_MAX_SLOTS :: 32
MESH_MAX_LEVELS :: 32
MESH_RAY_LEVELS :: 4 // the level 0 rays trace near, and up to three coarser cuts of the DAG for far away
MESH_BULK_ALIGNMENT :: 16
MESH_PAGE_WORDS :: 65536 // the most words of a block of a page: a group of 21 clusters of 256 vertices fits
MESH_ROOT_WORDS :: 16384 // the words of the root levels past the coarsest
MESH_PAGE_NONE :: max(u32)

CLUSTER_TRIANGLES :: 128
CLUSTER_VERTICES :: 256
CLUSTER_ROOT :: max(f32) // the parent error of a cluster nothing replaces
CLUSTER_GRID :: 65535    // the most steps of a grid a cluster spans along an axis

// Cluster.counts: vertices - 1 in bits 0-7, triangles in 8-15, the slot in 16-20,
// CLUSTER_CONE in 21, and in 24-31 the cutoff of the cone (snorm8).
CLUSTER_CONE :: u32(1) << 21

// 96 bytes, the layout of the clusters of the geometry pool of the renderer.
Cluster :: struct {
    position:[3]i32,    // its lowest corner, in steps of the position grid
    vertex_first:u32,   // its first vertex, of those of the mesh
    uv:[2]i32,          // the lowest uv of its vertices, in steps of the uv grid
    uv1:[2]i32,         // and their lowest uv1
    triangle_first:u32, // its first word of triangles
    counts:u32,
    size_xy:u32,        // the size of its box in steps of the grid: x in bits 0-15, y in 16-31
    size_z_cone:u32,    // z in bits 0-15; the axis of the cone of its normals, octahedral snorm8, x in 16-23 and y in 24-31
    lod:[4]f32,         // the sphere its error is seen from (xyz, radius), in the space of the mesh
    error:f32 `mirai:"unit=m"`, // bound of its geometric error against level 0
    parent:[4]f32,      // the sphere of the clusters that replace it
    parent_error:f32 `mirai:"unit=m"`, // their error; CLUSTER_ROOT for none
    page:u32,           // the page that holds it
    child_page:u32,     // the page of the group it was simplified from; MESH_PAGE_NONE at level 0 and on a mesh of Levels
}
#assert(size_of(Cluster)==96)

// A vertex of a cluster: 16 bytes, the layout of the geometry pool.
Cluster_Vertex :: struct {
    xy:u32,        // position x and y, steps of the grid from the corner of the cluster
    z_u:u32,       // position z, and u in bits 16-31 from the lowest uv of the cluster
    v_tangent:u32, // v, and the tangent in bits 16-31 (math.tangent_angle_pack)
    normal:u32,    // octahedral, two snorm16 (math.normal_pack)
}
#assert(size_of(Cluster_Vertex)==16)

// The vertex importers and generators give, at full precision: what a
// cluster encodes, and what decoding one gives back.
Vertex :: struct {
    position:[3]f32,
    normal:u32,   // octahedral, two snorm16
    uv:[2]f32,    // origin at the top left of the image
    color:u32,    // rgba8, multiplies the base color
    material:u32, // row of slots
    uv1:[2]f32,
    tangent:u32,  // MikkTSpace, with the sign of the bitangent (math.tangent_pack)
}

// What a vertex of a far mesh (mesh_build_far) says of its surface in place
// of the maps of a material, as its color says the base color: the same in
// every vertex of a cluster, the mean of what the cluster covers.
Surface_Vertex :: struct {
    material:u32, // roughness in bits 0-7 and metallic in 8-15, unorm8
    emission:u32, // nits, rgb9e5 (math.rgb9e5_pack)
}

// Eight influences whose weights add up to 255.
Skin_Vertex :: struct {
    joints:[8]u16, // rows of joints
    weights:[8]u8,
}

Mesh_Flag :: enum u8 {
    Skinned,
    Has_Colors, // some vertex color is not white
    Has_Uv1,    // uv1 is a set of its own, not a copy of uv
    Levels,     // its levels are whole meshes, not a DAG
    Closed,     // level 0 is closed: no cluster of it is seen from behind its normals
    Has_Surface, // a far mesh: with its colors, its vertices carry roughness, metallic and emission (Surface_Vertex)
}
Mesh_Flags :: bit_set[Mesh_Flag;u32]

Mesh_Info :: struct {
    vertex_count:u32,
    triangle_count:u32, // of every level
    cluster_count:u32,
    bounds_min:[3]f32,
    bounds_max:[3]f32,
    flags:Mesh_Flags,
    skeleton:base.Asset_Id,
    position_step:f32 `mirai:"unit=m"`, // powers of two
    uv_step,uv1_step:f32,
    ray_errors:[MESH_RAY_LEVELS-1]f32 `mirai:"unit=m"`, // the errors of the cuts rays trace far away, coarser each; 0: no more
    root_page:u32, // pages from it on are the root, always resident
    morph_step:f32 `mirai:"unit=m"`, // of the positions of morph_deltas, a power of two; 0 without targets
}

Mesh_Level :: struct {
    first_cluster,cluster_count:u32,
    triangle_count:u32,
    error:f32 `mirai:"unit=m"`,        // the least error of its clusters
    parent_error:f32 `mirai:"unit=m"`, // the greatest error of what replaces them
}

// A run of clusters of one level and the vertices and words of triangles
// they own, and where its block is in page_data.
Mesh_Page :: struct {
    first_cluster,cluster_count:u32,
    first_vertex,vertex_count:u32,
    first_triangle,triangle_words:u32,
    level:u32,       // row of levels
    words:u32,       // of its block decoded (mesh_page_layout)
    data_offset:u32, // byte of page_data its block starts at
    data_bytes:u32,  // of its block in LZ
    coded_bytes:u32, // of its block coded: what data_bytes decode to; 0 for its words as they are
}

// Where each stream of the block of a page starts, in words: its vertices
// (Cluster_Vertex), then uv1 with Has_Uv1, colors with Has_Colors and
// surfaces (Surface_Vertex) with Has_Surface, one each a vertex, then its
// words of triangles. A stream the mesh has not takes no words.
Mesh_Page_Layout :: struct {vertices,uv1s,colors,surfaces,triangles,words:u32}

Material_Slot :: struct {
    id:u32, // stable inside the mesh: what an entity assigns a material to
    label:[64]u8 `mirai:"text"`,
    material:base.Asset_Id, // the one the model came with
}

Rig_Joint :: struct {
    node:u32, // row of the referenced skeleton's bones
    inverse_bind:matrix[4,4]f32,
}

Collider_Kind :: enum u8 {Box,Sphere,Capsule,Hull,Mesh}

// A collision shape in the space of the mesh. Box: size is its half extents.
// Sphere: size.x is its radius. Capsule: size.x is its radius and size.y half
// the distance between its centers, along its local Y. Hull: a range of
// collision_points. Mesh: ranges of collision_points and collision_indices.
Collider :: struct {
    kind:Collider_Kind,
    center:[3]f32,
    rotation:quaternion128,
    size:[3]f32 `mirai:"unit=m"`,
    first_point:u32,
    point_count:u32,
    first_index:u32,
    index_count:u32,
}

// The clusters of a mesh and what decodes them: the tables of a file, or what
// mesh_build made.
Mesh_Geometry :: struct {
    clusters:[]Cluster,
    levels:[]Mesh_Level,
    vertices:[]Cluster_Vertex,
    uv1s:[]u32,   // one per vertex with Has_Uv1: u and v from the lowest uv1 of its cluster
    colors:[]u32, // one per vertex with Has_Colors
    surfaces:[]Surface_Vertex, // one per vertex with Has_Surface
    skin:[]Skin_Vertex,
    triangles:[]u32,
    pages:[]Mesh_Page,
    page_data:[]u8, // the blocks of the pages: of a file, or packed (mesh_pages_pack); empty for what mesh_build made
    morphs:[]Morph_Target,
    morph_deltas:[]Morph_Cluster_Delta,
    morph_step:f32,
    bounds_min,bounds_max:[3]f32,
    flags:Mesh_Flags,
    position_step,uv_step,uv1_step:f32,
    ray_errors:[MESH_RAY_LEVELS-1]f32,
    root_page:u32,
}

Mesh_Desc :: struct {
    id:base.Asset_Id,
    owner:base.Asset_Id, // the asset it is a part of: the prefab of the import that made it
    geometry:Mesh_Geometry,
    slots:[]Material_Slot,
    joints:[]Rig_Joint,
    skeleton:base.Asset_Id,
    colliders:[]Collider,
    collision_points:[][3]f32,
    collision_indices:[]u32,
    source:^Import_Info,
}

Mesh_View :: struct {
    info:^Mesh_Info,
    using geometry:Mesh_Geometry,
    slots:[]Material_Slot,
    joints:[]Rig_Joint,
    colliders:[]Collider,
    collision_points:[][3]f32,
    collision_indices:[]u32,
    source:^Import_Info,
}

cluster_vertex_count :: #force_inline proc "contextless" (c:Cluster) -> u32 {return (c.counts&0xff)+1}
cluster_triangle_count :: #force_inline proc "contextless" (c:Cluster) -> u32 {return c.counts>>8&0xff}
cluster_slot :: #force_inline proc "contextless" (c:Cluster) -> u32 {return c.counts>>16&0x1f}
// The words of triangles of a cluster: its u8 indices, three a triangle.
cluster_triangle_words :: #force_inline proc "contextless" (c:Cluster) -> u32 {return (cluster_triangle_count(c)*3+3)/4}

// The three indices of the vertices of a triangle of a cluster, from its first.
cluster_triangle :: proc "contextless" (triangles:[]u32,c:Cluster,t:u32) -> (corners:[3]u32) {
    for k in 0..<u32(3) {
        at:=t*3+k
        corners[k]=triangles[c.triangle_first+at/4]>>(at%4*8)&0xff
    }
    return
}

// The place of a vertex of a cluster, in the space of the mesh.
cluster_position :: proc "contextless" (g:Mesh_Geometry,c:Cluster,local:u32) -> [3]f32 {
    v:=g.vertices[c.vertex_first+local]
    return {f32(c.position.x+i32(v.xy&0xffff)),f32(c.position.y+i32(v.xy>>16)),f32(c.position.z+i32(v.z_u&0xffff))}*g.position_step
}

// The box of a cluster, from its grid.
cluster_box :: proc "contextless" (step:f32,c:Cluster) -> (low,high:[3]f32) {
    low={f32(c.position.x),f32(c.position.y),f32(c.position.z)}*step
    high={f32(c.position.x+i32(c.size_xy&0xffff)),f32(c.position.y+i32(c.size_xy>>16)),f32(c.position.z+i32(c.size_z_cone&0xffff))}*step
    return
}

// A vertex of a cluster at full precision; material is the slot of the cluster.
cluster_vertex :: proc "contextless" (g:Mesh_Geometry,c:Cluster,local:u32) -> Vertex {
    at:=c.vertex_first+local
    v:=g.vertices[at]
    out:=Vertex{position=cluster_position(g,c,local),normal=v.normal,color=0xffffffff,material=cluster_slot(c)}
    out.uv={f32(c.uv.x+i32(v.z_u>>16)),f32(c.uv.y+i32(v.v_tangent&0xffff))}*g.uv_step
    out.uv1=out.uv
    if len(g.uv1s)>0 {out.uv1={f32(c.uv1.x+i32(g.uv1s[at]&0xffff)),f32(c.uv1.y+i32(g.uv1s[at]>>16))}*g.uv1_step}
    if len(g.colors)>0 {out.color=g.colors[at]}
    tangent,sign:=mm.tangent_angle_unpack(v.normal,u16(v.v_tangent>>16))
    out.tangent=mm.tangent_pack(tangent,sign)
    return out
}

// The triangles of a level as one indexed mesh: the vertices of each cluster
// after those of the one before, and indices into them. Appends; false
// without memory.
mesh_level_decode :: proc(g:Mesh_Geometry,level:int,vertices:^[dynamic]Vertex,indices:^[dynamic]u32) -> bool {
    if level>=len(g.levels) {return true}
    range:=g.levels[level]
    for c in g.clusters[range.first_cluster:][:range.cluster_count] {
        first:=u32(len(vertices))
        for local in 0..<cluster_vertex_count(c) {
            if _,error:=append(vertices,cluster_vertex(g,c,local));error!=nil {return false}
        }
        for t in 0..<cluster_triangle_count(c) {
            corners:=cluster_triangle(g.triangles,c,t)
            if _,error:=append(indices,first+corners[0],first+corners[1],first+corners[2]);error!=nil {return false}
        }
    }
    return true
}

// The streams of the block of a page of vertex_count vertices and
// triangle_words words of triangles. Both at most MESH_PAGE_WORDS.
mesh_page_layout :: proc "contextless" (flags:Mesh_Flags,vertex_count,triangle_words:u32) -> (layout:Mesh_Page_Layout) {
    at:=vertex_count*size_of(Cluster_Vertex)/4
    layout.uv1s=at
    if .Has_Uv1 in flags {at+=vertex_count}
    layout.colors=at
    if .Has_Colors in flags {at+=vertex_count}
    layout.surfaces=at
    if .Has_Surface in flags {at+=vertex_count*size_of(Surface_Vertex)/4}
    layout.triangles=at
    layout.words=at+triangle_words
    return
}

// Writes the block of a page of g into out, of page.words words or more.
mesh_page_gather :: proc(g:Mesh_Geometry,page:Mesh_Page,out:[]u32) -> bool {
    layout:=mesh_page_layout(g.flags,page.vertex_count,page.triangle_words)
    if len(out)<int(layout.words) {return false}
    words :: proc(values:[]$T,first,count:u32) -> []u32 {return mem.slice_data_cast([]u32,values[first:][:count])}
    copy(out[layout.vertices:],words(g.vertices,page.first_vertex,page.vertex_count))
    if .Has_Uv1 in g.flags {copy(out[layout.uv1s:],g.uv1s[page.first_vertex:][:page.vertex_count])}
    if .Has_Colors in g.flags {copy(out[layout.colors:],g.colors[page.first_vertex:][:page.vertex_count])}
    if .Has_Surface in g.flags {copy(out[layout.surfaces:],words(g.surfaces,page.first_vertex,page.vertex_count))}
    copy(out[layout.triangles:],g.triangles[page.first_triangle:][:page.triangle_words])
    return true
}

// Whether the block of a page has the words of its layout, within
// MESH_PAGE_WORDS, inside page_data of size bytes. A page of a geometry that
// has no page_data names no bytes.
@(private)
page_block_valid :: proc "contextless" (flags:Mesh_Flags,page:Mesh_Page,size:int) -> bool {
    if page.vertex_count>MESH_PAGE_WORDS || page.triangle_words>MESH_PAGE_WORDS || page.words>MESH_PAGE_WORDS {return false}
    if mesh_page_layout(flags,page.vertex_count,page.triangle_words).words!=page.words {return false}
    return range_inside(page.data_offset,page.data_bytes,size)
}

// The streams of a decoded block into the arrays of g.
@(private="file")
page_scatter :: proc(g:^Mesh_Geometry,page:Mesh_Page,block:[]u32) {
    layout:=mesh_page_layout(g.flags,page.vertex_count,page.triangle_words)
    words :: proc(values:[]$T,first,count:u32) -> []u32 {return mem.slice_data_cast([]u32,values[first:][:count])}
    copy(words(g.vertices,page.first_vertex,page.vertex_count),block[layout.vertices:layout.uv1s])
    if .Has_Uv1 in g.flags {copy(g.uv1s[page.first_vertex:][:page.vertex_count],block[layout.uv1s:layout.colors])}
    if .Has_Colors in g.flags {copy(g.colors[page.first_vertex:][:page.vertex_count],block[layout.colors:layout.surfaces])}
    if .Has_Surface in g.flags {copy(words(g.surfaces,page.first_vertex,page.vertex_count),block[layout.surfaces:layout.triangles])}
    copy(g.triangles[page.first_triangle:][:page.triangle_words],block[layout.triangles:layout.words])
}

mesh_bounds :: proc(vertices:[]Vertex) -> (low,high:[3]f32) {
    if len(vertices)==0 {return}
    low,high=vertices[0].position,vertices[0].position
    for vertex in vertices[1:] {
        for axis in 0..<3 {
            low[axis]=min(low[axis],vertex.position[axis])
            high[axis]=max(high[axis],vertex.position[axis])
        }
    }
    return
}

// Builds the document of a mesh. Fails with Invalid on a description that
// mesh_check would refuse.
mesh_document :: proc(doc:^Document,types:^Types,desc:Mesh_Desc,allocator:=context.allocator) -> Error {
    g:=desc.geometry
    info:=Mesh_Info{
        vertex_count=u32(len(g.vertices)),cluster_count=u32(len(g.clusters)),bounds_min=g.bounds_min,bounds_max=g.bounds_max,
        flags=g.flags,skeleton=desc.skeleton,position_step=g.position_step,uv_step=g.uv_step,uv1_step=g.uv1_step,ray_errors=g.ray_errors,
        root_page=g.root_page,morph_step=g.morph_step,
    }
    for c in g.clusters {info.triangle_count+=cluster_triangle_count(c)}
    if len(desc.joints)>0 {info.flags+={.Skinned}}
    view:=Mesh_View{info=&info,geometry=g,slots=desc.slots,joints=desc.joints,colliders=desc.colliders,collision_points=desc.collision_points,collision_indices=desc.collision_indices}
    if !mesh_check(view) || !mesh_check_indices(view) {return .Invalid}

    document_init(doc,KIND_MESH,desc.id,allocator)
    doc.owner=desc.owner
    doc.kind_version=MESH_VERSION
    error:=mesh_tables(doc,types,&info,view,desc)
    if error!=.None {document_destroy(doc)}
    return error
}

@(private="file")
mesh_tables :: proc(doc:^Document,types:^Types,info:^Mesh_Info,view:Mesh_View,desc:Mesh_Desc) -> Error {
    bulk :: proc(doc:^Document,types:^Types,name:string,values:[]$T) -> Error {
        _,error:=document_put(doc,types,name,values,{.Bulk},.LZ,MESH_BULK_ALIGNMENT)
        return error
    }
    document_put_row(doc,types,"mesh",info) or_return
    bulk(doc,types,"clusters",view.clusters) or_return
    document_put(doc,types,"levels",view.levels) or_return
    document_put(doc,types,"slots",view.slots) or_return
    if len(view.joints)>0 {
        document_put(doc,types,"joints",view.joints) or_return
    }
    if len(view.morphs)>0 {
        document_put(doc,types,"morphs",view.morphs) or_return
        bulk(doc,types,"morph_deltas",view.morph_deltas) or_return
    }
    if len(view.colliders)>0 {
        document_put(doc,types,"colliders",view.colliders) or_return
        bulk(doc,types,"collision_points",view.collision_points) or_return
        bulk(doc,types,"collision_indices",view.collision_indices) or_return
    }
    import_put(doc,types,desc.source) or_return
    if len(view.skin)>0 {
        vertices:=document_table_add(doc,"vertices",{.Bulk}) or_return
        document_resize(doc,vertices,len(view.skin)) or_return
        document_column_put(doc,types,vertices,"skin",view.skin,{},.LZ,MESH_BULK_ALIGNMENT) or_return
    }
    pages,data:=pages_compress(view.geometry,.Edit,doc.allocator) or_return
    defer {delete(pages,doc.allocator);delete(data)}
    bulk(doc,types,"pages",pages) or_return
    _,error:=document_put(doc,types,"page_data",data[:],{.Bulk},.None,MESH_BULK_ALIGNMENT)
    return error
}

// The blocks of the pages of geometry mesh_build made, as a file holds them
// (page_data): with them the renderer streams a mesh made in memory whose
// root is not every page as it does one of a file. In allocator, with
// scratch from the temporary allocator; false without memory.
mesh_pages_pack :: proc(g:^Mesh_Geometry,allocator:=context.allocator) -> bool {
    pages,data,error:=pages_compress(g^,.Edit,allocator)
    if error!=.None {return false}
    delete(g.pages,allocator)
    g.pages,g.page_data=pages,data[:]
    return true
}

// The page_data of a mesh document with the block of each page compressed
// again as p says, and its pages pointing into it.
@(private)
mesh_pages_repack :: proc(doc:^Document,p:Pack) -> Error {
    pages_table,has_pages:=document_table(doc,"pages")
    data_table,has_data:=document_table(doc,"page_data")
    if !has_pages || !has_data {return .None}
    if doc.kind_version!=MESH_VERSION {return .Version}
    info_table,has_info:=document_table(doc,"mesh")
    clusters_table,has_clusters:=document_table(doc,"clusters")
    if !has_info || !has_clusters {return .Corrupt}
    pages_column,data_column:=&doc.tables[pages_table].columns[0],&doc.tables[data_table].columns[0]
    info_column,clusters_column:=&doc.tables[info_table].columns[0],&doc.tables[clusters_table].columns[0]
    if pages_column.size!=size_of(Mesh_Page) || data_column.size!=1 || info_column.size!=size_of(Mesh_Info) || len(info_column.data)!=size_of(Mesh_Info) || clusters_column.size!=size_of(Cluster) {return .Corrupt}
    pages:=mem.slice_data_cast([]Mesh_Page,pages_column.data)
    g:=Mesh_Geometry{flags=mem.slice_data_cast([]Mesh_Info,info_column.data)[0].flags,clusters=mem.slice_data_cast([]Cluster,clusters_column.data)}
    decoder:Decoder
    decoder_init(&decoder,context.temp_allocator) or_return
    defer decoder_destroy(&decoder)
    encoder:lz.Encoder
    lz.encoder_init(&encoder,context.temp_allocator)
    defer lz.encoder_destroy(&encoder)
    coder:=page_coder_make(context.temp_allocator)
    defer page_coder_destroy(&coder)
    coded:=make([]u8,MESH_PAGE_SCRATCH_BYTES,context.temp_allocator)
    block:=make([]u32,MESH_PAGE_WORDS,context.temp_allocator)
    data:=make([dynamic]u8,0,len(data_column.data),context.temp_allocator)
    if coded==nil || block==nil || data==nil {return .Out_Of_Memory}
    old:=data_column.data
    for &page in pages {
        if page.data_bytes==0 {continue}
        if !mesh_page_decode(g.flags,page,old,coded,block,&decoder.lz) || u64(page.first_cluster)+u64(page.cluster_count)>u64(len(g.clusters)) {return .Corrupt}
        page_pack(&coder,&encoder,g,&page,block,coded,p,&data) or_return
    }
    document_resize(doc,data_table,len(data)) or_return
    copy(doc.tables[data_table].columns[0].data,data[:])
    return .None
}

mesh_save :: proc(path:string,types:^Types,desc:Mesh_Desc,allocator:=context.allocator) -> Error {
    doc:Document
    mesh_document(&doc,types,desc,allocator) or_return
    defer document_destroy(&doc)
    return document_save(&doc,path)
}

// The tables of an open mesh as typed slices, decompressed into memory of
// the asset. Everything a range refers to is inside what the file holds;
// mesh_check_indices looks at the indices and the weights themselves.
mesh_view :: proc(a:^Asset,types:^Types) -> (view:Mesh_View,error:Error) {
    kind_check(a,KIND_MESH,MESH_VERSION) or_return
    view.info=asset_row(a,types,"mesh",Mesh_Info) or_return
    view.clusters=table_rows(a,types,"clusters",Cluster) or_return
    view.levels=table_rows(a,types,"levels",Mesh_Level) or_return
    view.pages=table_rows(a,types,"pages",Mesh_Page) or_return
    view.page_data=table_rows(a,types,"page_data",u8) or_return
    if _,found:=asset_table(a,"vertices");found {view.skin=asset_rows(a,types,"vertices","skin",Skin_Vertex) or_return}
    view.slots=table_rows(a,types,"slots",Material_Slot) or_return
    view.joints=table_rows(a,types,"joints",Rig_Joint) or_return
    view.morphs=table_rows(a,types,"morphs",Morph_Target) or_return
    view.morph_deltas=table_rows(a,types,"morph_deltas",Morph_Cluster_Delta) or_return
    view.colliders=table_rows(a,types,"colliders",Collider) or_return
    view.collision_points=table_rows(a,types,"collision_points",[3]f32) or_return
    view.collision_indices=table_rows(a,types,"collision_indices",u32) or_return
    view.source=import_info(a,types) or_return
    info:=view.info
    view.bounds_min,view.bounds_max,view.flags=info.bounds_min,info.bounds_max,info.flags
    view.position_step,view.uv_step,view.uv1_step,view.ray_errors=info.position_step,info.uv_step,info.uv1_step,info.ray_errors
    view.root_page,view.morph_step=info.root_page,info.morph_step
    pages_decode(a,&view) or_return
    if !mesh_check(view) {return {},.Corrupt}
    return view,.None
}

// The vertices, their streams and the triangles of every page, decoded into
// memory of the asset. The pages cover the vertices and the triangles in
// order; how much a page decodes to is bound by its bytes.
@(private="file")
pages_decode :: proc(a:^Asset,view:^Mesh_View) -> Error {
    vertices,words:u64
    largest:u32
    for page in view.pages {
        if !page_block_valid(view.flags,page,len(view.page_data)) || page.data_bytes==0 {return .Corrupt}
        if u64(page.first_vertex)!=vertices || u64(page.first_triangle)!=words {return .Corrupt}
        vertices+=u64(page.vertex_count)
        words+=u64(page.triangle_words)
        largest=max(largest,page.words)
    }
    if vertices!=u64(view.info.vertex_count) {return .Corrupt}
    rows :: proc(a:^Asset,$T:typeid,count:u64,present:bool) -> (rows:[]T,error:Error) {
        if !present {return nil,.None}
        block:=asset_alloc(a,int(count)*size_of(T),align_of(T)) or_return
        return mem.slice_data_cast([]T,block),.None
    }
    view.vertices=rows(a,Cluster_Vertex,vertices,true) or_return
    view.uv1s=rows(a,u32,vertices,.Has_Uv1 in view.flags) or_return
    view.colors=rows(a,u32,vertices,.Has_Colors in view.flags) or_return
    view.surfaces=rows(a,Surface_Vertex,vertices,.Has_Surface in view.flags) or_return
    view.triangles=rows(a,u32,words,true) or_return
    block,allocation:=make([]u32,largest,a.allocator)
    if allocation!=nil {return .Out_Of_Memory}
    defer delete(block,a.allocator)
    scratch:[]u8
    if scratch,allocation=make([]u8,MESH_PAGE_SCRATCH_BYTES,a.allocator);allocation!=nil {return .Out_Of_Memory}
    defer delete(scratch,a.allocator)
    decoder:=asset_decoder(a) or_return
    for page in view.pages {
        if !mesh_page_decode(view.flags,page,view.page_data,scratch,block,&decoder.lz) {return .Corrupt}
        page_scatter(&view.geometry,page,block)
    }
    return .None
}

@(private="file")
range_inside :: proc "contextless" (first,count:u32,size:int) -> bool {
    return u64(first)+u64(count)<=u64(size)
}

// Whether a step of a grid is a positive power of two.
@(private)
step_valid :: proc "contextless" (step:f32) -> bool {
    bits:=transmute(u32)step
    return step>0 && bits&0x7fffff==0 && bits>>23&0xff!=0xff
}

// What every reader of a mesh relies on: counts that agree, ranges that stay
// inside the tables they index and levels that cover the clusters in order.
mesh_check :: proc(view:Mesh_View) -> bool {
    info:=view.info
    if info==nil || int(info.vertex_count)!=len(view.vertices) || int(info.cluster_count)!=len(view.clusters) {return false}
    if len(view.clusters)==0 || len(view.levels)==0 || len(view.levels)>MESH_MAX_LEVELS || len(view.slots)>MESH_MAX_SLOTS {return false}
    if !finite(info.bounds_min.x,info.bounds_min.y,info.bounds_min.z,info.bounds_max.x,info.bounds_max.y,info.bounds_max.z) {return false}
    if !step_valid(info.position_step) || !step_valid(info.uv_step) || !step_valid(info.uv1_step) {return false}
    if (.Has_Uv1 in info.flags)!=(len(view.uv1s)>0) || (.Has_Colors in info.flags)!=(len(view.colors)>0) {return false}
    if len(view.uv1s)!=0 && len(view.uv1s)!=len(view.vertices) || len(view.colors)!=0 && len(view.colors)!=len(view.vertices) {return false}
    if (.Has_Surface in info.flags)!=(len(view.surfaces)>0) || len(view.surfaces)!=0 && (len(view.surfaces)!=len(view.vertices) || len(view.colors)==0) {return false}
    if len(view.skin)!=0 && len(view.skin)!=len(view.vertices) {return false}
    // Coarser each, and none after the first that is not there.
    previous:f32
    ended:=false
    for e in info.ray_errors {
        if !finite(e) || e<0 {return false}
        if e==0 {ended=true;continue}
        if ended || e<=previous {return false}
        previous=e
    }
    triangles:u32
    for c in view.clusters {
        vertices,count,slot:=cluster_vertex_count(c),cluster_triangle_count(c),cluster_slot(c)
        if vertices==0 || count==0 || count>CLUSTER_TRIANGLES || !range_inside(c.vertex_first,vertices,len(view.vertices)) {return false}
        if !range_inside(c.triangle_first,cluster_triangle_words(c),len(view.triangles)) {return false}
        if slot>=u32(max(len(view.slots),1)) {return false}
        if !finite(c.lod.x,c.lod.y,c.lod.z,c.lod.w,c.error,c.parent.x,c.parent.y,c.parent.z,c.parent.w) || c.error<0 || c.lod.w<0 || c.parent.w<0 {return false}
        if !(c.parent_error>=c.error) {return false}
        triangles+=count
    }
    if triangles!=info.triangle_count {return false}
    next:u32
    for level,at in view.levels {
        if level.first_cluster!=next || level.cluster_count==0 || !range_inside(level.first_cluster,level.cluster_count,len(view.clusters)) {return false}
        if !finite(level.error) || level.error<0 || !(level.parent_error>=level.error) {return false}
        if at>0 && level.error<view.levels[at-1].error {return false}
        held:u32
        for c in view.clusters[level.first_cluster:][:level.cluster_count] {held+=cluster_triangle_count(c)}
        if held!=level.triangle_count {return false}
        next+=level.cluster_count
    }
    if int(next)!=len(view.clusters) || !pages_check(view) {return false}
    for &slot,at in view.slots {
        if !text_valid(slot.label[:]) {return false}
        for other in view.slots[:at] {
            if other.id==slot.id {return false}
        }
    }
    if (len(view.joints)>0)!=(info.skeleton!={}) || len(view.skin)>0 && len(view.joints)==0 {return false}
    if (.Skinned in info.flags)!=(len(view.joints)>0) || !mesh_morph_check(view) {return false}
    if len(view.joints)>0 && (len(view.skin)!=len(view.vertices) || len(view.joints)>1<<16) {return false}
    for joint in view.joints {
        if joint.node>=SKELETON_MAX_BONES {return false}
        for row in 0..<4 {for column in 0..<4 {if !finite(joint.inverse_bind[row,column]) {return false}}}
        if abs(joint.inverse_bind[3,0])+abs(joint.inverse_bind[3,1])+abs(joint.inverse_bind[3,2])+abs(joint.inverse_bind[3,3]-1)>1e-5 {return false}
    }
    for collider in view.colliders {
        if !range_inside(collider.first_point,collider.point_count,len(view.collision_points)) || !range_inside(collider.first_index,collider.index_count,len(view.collision_indices)) {return false}
        if collider.index_count%3!=0 || !finite(collider.size.x,collider.size.y,collider.size.z,collider.center.x,collider.center.y,collider.center.z) {return false}
    }
    return true
}

// The pages of a mesh whose clusters and levels are checked: they cover the
// clusters, vertices and words of triangles in order, each of one level,
// finest first, and hold what their clusters own; each cluster names its
// page, and the page of its children one of the level before. The root
// holds every cluster nothing replaces, and the coarsest cut rays trace
// takes none of the other pages (mesh_ray_errors).
@(private="file")
pages_check :: proc(view:Mesh_View) -> bool {
    info:=view.info
    if len(view.pages)==0 || int(info.root_page)>=len(view.pages) {return false}
    whole:=.Skinned in info.flags || .Levels in info.flags || len(view.morphs)>0
    if whole && info.root_page!=0 {return false}
    clusters,vertices,words:u64
    need:f32 // the greatest parent error out of the root
    for page,at in view.pages {
        if !page_block_valid(info.flags,page,len(view.page_data)) || page.cluster_count==0 {return false}
        if u64(page.first_cluster)!=clusters || u64(page.first_vertex)!=vertices || u64(page.first_triangle)!=words {return false}
        clusters+=u64(page.cluster_count)
        vertices+=u64(page.vertex_count)
        words+=u64(page.triangle_words)
        if clusters>u64(len(view.clusters)) || vertices>u64(len(view.vertices)) || words>u64(len(view.triangles)) {return false}
        if int(page.level)>=len(view.levels) || at>0 && page.level<view.pages[at-1].level {return false}
        level:=view.levels[page.level]
        if page.first_cluster<level.first_cluster || clusters>u64(level.first_cluster)+u64(level.cluster_count) {return false}
        for c in view.clusters[page.first_cluster:][:page.cluster_count] {
            if c.page!=u32(at) || c.vertex_first<page.first_vertex || u64(c.vertex_first)+u64(cluster_vertex_count(c))>vertices {return false}
            if c.triangle_first<page.first_triangle || u64(c.triangle_first)+u64(cluster_triangle_words(c))>words {return false}
            if c.child_page==MESH_PAGE_NONE {
                if page.level>0 && .Levels not_in info.flags {return false}
            } else if .Levels in info.flags || c.child_page>=u32(at) || view.pages[c.child_page].level+1!=page.level {return false}
            if u32(at)<info.root_page {
                if c.parent_error==CLUSTER_ROOT {return false}
                need=max(need,c.parent_error)
            }
        }
    }
    if clusters!=u64(len(view.clusters)) || vertices!=u64(len(view.vertices)) || words!=u64(len(view.triangles)) {return false}
    if info.root_page>0 {
        coarsest:f32
        for e in info.ray_errors {if e>0 {coarsest=e}}
        if !(coarsest>0) || coarsest<need {return false}
    }
    return true
}

// Whether every index names a vertex of its cluster, every skin weight a
// joint with weights that add up to 255, and every collision index a point
// of its collider. Linear in the size of the mesh.
mesh_check_indices :: proc(view:Mesh_View) -> bool {
    for c in view.clusters {
        vertices:=cluster_vertex_count(c)
        for t in 0..<cluster_triangle_count(c) {
            for corner in cluster_triangle(view.triangles,c,t) {if corner>=vertices {return false}}
        }
    }
    for influence in view.skin {
        sum:u32
        for joint,at in influence.joints {
            if influence.weights[at]!=0 && int(joint)>=len(view.joints) {return false}
            sum+=u32(influence.weights[at])
        }
        if sum!=255 {return false}
    }
    for collider in view.colliders {
        for index in view.collision_indices[collider.first_index:][:collider.index_count] {
            if index>=collider.point_count {return false}
        }
    }
    return mesh_morph_check_deltas(view)
}

mesh_skeleton_check :: proc(mesh:Mesh_View,skeleton:Skeleton_View) -> bool {
    if !mesh_check(mesh) || !skeleton_check(skeleton) || len(mesh.joints)==0 {return false}
    for joint in mesh.joints {if int(joint.node)>=len(skeleton.bones) {return false}}
    return true
}

// Eight weights as the bytes of a Skin_Vertex: each the nearest 255th, the
// rounding left on the largest so they add up to 255. Weights that add up
// to nothing give the first joint all of it.
skin_weights_quantize :: proc "contextless" (weights:[8]f32) -> (bytes:[8]u8) {
    total:f32
    for w in weights {total+=max(w,0)}
    if !(total>0) {bytes[0]=255;return}
    sum:i32
    largest:=0
    for w,i in weights {
        bytes[i]=u8(clamp(max(w,0)/total*255+0.5,0,255))
        sum+=i32(bytes[i])
        if weights[i]>weights[largest] {largest=i}
    }
    bytes[largest]=u8(clamp(i32(bytes[largest])+255-sum,0,255))
    return
}

// Gives the vertices of a mesh, which come without tangents, the MikkTSpace
// tangents of their corners (geom.corner_tangents over uv): a vertex whose
// corners take different tangents is repeated, with its skin when skin has
// one per vertex. indices are rewritten in place. False without memory or
// for indices outside the vertices.
mesh_tangents :: proc(vertices:^[dynamic]Vertex,indices:[]u32,skin:^[dynamic]Skin_Vertex=nil) -> bool {
    scratch:=context.temp_allocator
    count:=len(vertices)
    for index in indices {if int(index)>=count {return false}}
    positions:=make([][3]f32,count,scratch)
    normals:=make([][3]f32,count,scratch)
    uvs:=make([][2]f32,count,scratch)
    corners:=make([][4]f32,len(indices),scratch)
    Key :: struct {vertex:u32,tangent:u32}
    known:=make(map[Key]u32,count,scratch)
    defer {delete(positions,scratch);delete(normals,scratch);delete(uvs,scratch);delete(corners,scratch);delete(known)}
    if count>0 && (positions==nil || normals==nil || uvs==nil) || len(indices)>0 && corners==nil {return false}
    for vertex,i in vertices {positions[i],normals[i],uvs[i]=vertex.position,mm.normal_unpack(vertex.normal),vertex.uv}
    if !geom.corner_tangents(positions,normals,uvs,indices,corners) {return false}
    skinned:=skin!=nil && len(skin)==count
    for &index,at in indices {
        packed:=mm.tangent_pack(corners[at].xyz,corners[at].w)
        key:=Key{index,packed}
        if found,seen:=known[key];seen {
            index=found
            continue
        }
        target:=index
        if vertices[index].tangent!=0 {
            target=u32(len(vertices))
            append(vertices,vertices[index])
            if skinned {append(skin,skin[index])}
        }
        vertices[target].tangent=packed
        known[key]=target
        index=target
    }
    return true
}
