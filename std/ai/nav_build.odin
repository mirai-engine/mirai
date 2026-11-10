package ai

// Builds one tile of a navigation mesh from triangles. A modified rewrite in
// Odin of Recast and of the tile finishing of Detour (recastnavigation,
// zlib license, Copyright (c) 2009 Mikko Mononen memon@inside.org).
//
// The triangles are voxelized into columns of solid spans over the tile and a
// border around it. Filters keep the spans an agent stands on, the walkable
// area is eroded by the agent radius and marked by the volumes, a watershed
// over the distance to the walls splits it into regions, and their outlines
// are simplified, triangulated and merged into convex polygons with a detail
// mesh for the height of the surface. The border is voxelized like the tile
// and left out of the result: two tiles see the same voxels along the edge
// they share and agree on its vertices.

import "base:runtime"
import cmath "core:math"
import "core:mem"
import "core:slice"
import math "mirai:std/math"

// Cells across the heightfield of a build: the tile and its border on both sides.
NAV_BUILD_MAX_CELLS :: 4096

// The memory of one builder, reused from build to build: a build may grow it
// and the builds that follow at the same size do not allocate. One per thread.
Nav_Build_Scratch :: struct {
    columns:[dynamic]u32, // first span of each column of the heightfield, plus one; 0 when empty
    spans:[dynamic]Nav_Span,
    span_free:u32,
    cells:[dynamic]u32,   // first compact span of each column, and one past the last
    compact:[dynamic]Nav_Compact_Span,
    area:[dynamic]u8,
    dist,work:[dynamic]u16,
    region,region_dist:[dynamic]u16,
    levels:[NAV_LEVEL_STACKS][dynamic]Nav_Level_Entry,
    stack:[dynamic]Nav_Level_Entry,
    dirty:[dynamic]Nav_Dirty_Entry,
    regions:[dynamic]Nav_Region,
    ints,trace:[dynamic]i32,
    flags:[dynamic]u8,
    raw,simple:[dynamic][4]i32,
    contours:[dynamic]Nav_Contour,
    contour_verts:[dynamic][4]i32,
    outlines:[dynamic]i32,
    holes:[dynamic]Nav_Hole,
    diagonals:[dynamic][2]i32,
    mesh_verts:[dynamic][3]u16,
    vertex_flags:[dynamic]u8,
    vertex_next:[dynamic]i32,
    buckets:[dynamic]i32,
    polys:[dynamic]Nav_Mesh_Poly,
    indices:[dynamic]u32,
    tris:[dynamic]i32,
    merge:[dynamic]Nav_Mesh_Poly,
    hole:[dynamic][3]i32,
    edges:[dynamic][4]i32,
    tverts:[dynamic][4]i32,
    mesh_edges:[dynamic]Nav_Mesh_Edge,
    first_edge,next_edge:[dynamic]i32,
    patch:[dynamic]u16,
    detail_tris,detail_edges,samples:[dynamic][4]i32,
    details:[dynamic]Nav_Detail,
    detail_verts:[dynamic]math.Vec3,
    detail_out:[dynamic]Nav_Detail_Triangle,
    bv_items:[dynamic]Nav_Bv_Item,
    allocator:runtime.Allocator,
}

nav_build_scratch_init :: proc(scratch:^Nav_Build_Scratch,allocator:=context.allocator) {
    if scratch==nil {return}
    nav_build_scratch_destroy(scratch)
    scratch.allocator=allocator
}

nav_build_scratch_destroy :: proc(scratch:^Nav_Build_Scratch) {
    if scratch==nil {return}
    s:=scratch
    for &r in s.regions {delete(r.connections);delete(r.floors)}
    for &level in s.levels {delete(level)}
    delete(s.columns);delete(s.spans);delete(s.cells);delete(s.compact);delete(s.area)
    delete(s.dist);delete(s.work);delete(s.region);delete(s.region_dist)
    delete(s.stack);delete(s.dirty);delete(s.regions);delete(s.ints);delete(s.trace)
    delete(s.flags);delete(s.raw);delete(s.simple);delete(s.contours);delete(s.contour_verts)
    delete(s.outlines);delete(s.holes);delete(s.diagonals)
    delete(s.mesh_verts);delete(s.vertex_flags);delete(s.vertex_next);delete(s.buckets)
    delete(s.polys);delete(s.indices);delete(s.tris);delete(s.merge);delete(s.hole)
    delete(s.edges);delete(s.tverts);delete(s.mesh_edges);delete(s.first_edge);delete(s.next_edge)
    delete(s.patch);delete(s.detail_tris);delete(s.detail_edges);delete(s.samples)
    delete(s.details);delete(s.detail_verts);delete(s.detail_out);delete(s.bv_items)
    s^={}
}

// The square of the tile on XZ, with y open from -max(f32) to max(f32). Zero
// for a config that nav_build_tile rejects.
nav_tile_rect :: proc "contextless" (config:Nav_Build_Config,coord:[2]i32) -> math.Aabb {
    g,ok:=nav_build_grid(config,coord)
    if !ok {return {}}
    low:=[2]i64{i64(coord.x)*i64(g.tile),i64(coord.y)*i64(g.tile)}
    return {
        {nav_world(g.origin.x,low.x,g.cs),-max(f32),nav_world(g.origin.y,low.y,g.cs)},
        {nav_world(g.origin.x,low.x+i64(g.tile),g.cs),max(f32),nav_world(g.origin.y,low.y+i64(g.tile),g.cs)},
    }
}

// Metres around the tile whose triangles the build needs: the agent radius and
// three cells. Zero for a config that nav_build_tile rejects.
nav_build_margin :: proc "contextless" (config:Nav_Build_Config) -> f32 {
    g,ok:=nav_build_grid(config,{})
    if !ok {return 0}
    return f32(g.border)*g.cs
}

// Builds the tile at coord of the grid of config from the triangles, volumes
// and areas of input into out, whose slices live in one block allocated with
// allocator. out is overwritten: what it held is not freed. The scratch keeps
// the memory of the steps between builds and must come from
// nav_build_scratch_init. Same input, same bytes. With `field`, the walkable
// spans the triangles gave are kept in it, in a block of allocator, for
// nav_build_tile_again; it is overwritten like out, and left empty unless
// the tile has walkable spans.
nav_build_tile :: proc(config:Nav_Build_Config,coord:[2]i32,input:Nav_Build_Input,scratch:^Nav_Build_Scratch,out:^Nav_Tile_Data,allocator:=context.allocator,field:^Nav_Tile_Field=nil) -> Nav_Build_Status {
    if field!=nil {field^={}}
    if out==nil {return .Invalid}
    out^={}
    if scratch==nil || scratch.allocator.procedure==nil {return .Invalid}
    g,ok:=nav_build_grid(config,coord)
    if !ok || !nav_build_input_valid(input) {return .Invalid}
    if len(input.indices)==0 {return .Empty}
    context.allocator=scratch.allocator
    s:=scratch
    if status:=nav_rasterize(s,&g,input);status!=.Built {return status}
    nav_filter_spans(s,&g)
    if status:=nav_build_compact(s,&g);status!=.Built {return status}
    if field!=nil && !nav_tile_field_keep(s,&g,field,allocator) {return .Out_Of_Memory}
    return nav_build_surface(s,&g,coord,input.volumes,out,allocator)
}

// The walkable spans of the heightfield of a tile and its border, as its
// triangles give them before the volumes mark them and the radius erodes
// them: what the tile is built again from when only its volumes changed
// (an obstacle that settles, an area), without voxelizing its triangles.
Nav_Tile_Field :: struct {
    side:i32,      // columns across
    base:f64,      // global height cell of the height 0 of its spans
    cells:[]u32,   // first span of each column, and one past the last
    spans:[]Nav_Compact_Span,
    areas:[]u8,
    block:[]byte,
    allocator:runtime.Allocator,
}

nav_tile_field_free :: proc(field:^Nav_Tile_Field) {
    if field==nil {return}
    if field.block!=nil {delete(field.block,field.allocator)}
    field^={}
}

// A field with room for that many columns and spans, in one block.
@(private)
nav_tile_field_alloc :: proc(cells,spans:int,allocator:runtime.Allocator) -> (field:Nav_Tile_Field,ok:bool) {
    span_offset:=(cells*size_of(u32)+align_of(Nav_Compact_Span)-1)&~int(align_of(Nav_Compact_Span)-1)
    area_offset:=span_offset+spans*size_of(Nav_Compact_Span)
    block,error:=mem.alloc_bytes(area_offset+spans,align_of(Nav_Compact_Span),allocator)
    if error!=nil || block==nil {return}
    field.cells=([^]u32)(raw_data(block))[:cells]
    field.spans=([^]Nav_Compact_Span)(raw_data(block[span_offset:]))[:spans]
    field.areas=block[area_offset:][:spans]
    field.block,field.allocator=block,allocator
    return field,true
}

@(private)
nav_tile_field_keep :: proc(s:^Nav_Build_Scratch,g:^Nav_Grid,field:^Nav_Tile_Field,allocator:runtime.Allocator) -> bool {
    kept,ok:=nav_tile_field_alloc(len(s.cells),len(s.compact),allocator)
    if !ok {return false}
    kept.side,kept.base=g.side,g.base
    copy(kept.cells,s.cells[:])
    copy(kept.spans,s.compact[:])
    copy(kept.areas,s.area[:])
    field^=kept
    return true
}

// A copy of a field in a block of its own.
nav_tile_field_clone :: proc(field:^Nav_Tile_Field,allocator:=context.allocator) -> (copy_of:Nav_Tile_Field,ok:bool) {
    if field==nil || field.block==nil {return}
    copy_of,ok=nav_tile_field_alloc(len(field.cells),len(field.spans),allocator)
    if !ok {return}
    copy_of.side,copy_of.base=field.side,field.base
    copy(copy_of.block,field.block)
    return
}

// Whether a field is one a build of this grid kept: its columns are those of
// the tile and its border, in order, and the spans of each one stand over
// the other, as solids leave them.
@(private)
nav_tile_field_valid :: proc "contextless" (g:^Nav_Grid,field:^Nav_Tile_Field) -> bool {
    columns:=int(g.side)*int(g.side)
    if field.side!=g.side || len(field.cells)!=columns+1 || len(field.spans)==0 || len(field.areas)!=len(field.spans) {return false}
    if !(abs(field.base)<=1<<62) || field.cells[0]!=0 || int(field.cells[columns])!=len(field.spans) {return false}
    for c in 0..<columns {
        first,end:=field.cells[c],field.cells[c+1]
        if end<first || int(end)>len(field.spans) {return false}
        for i in int(first)..<int(end) {
            if field.areas[i]>NAV_AREA_MAX {return false}
            if i>int(first) && int(field.spans[i].y)<int(field.spans[i-1].y)+int(field.spans[i-1].h) {return false}
        }
    }
    return true
}

// Builds the tile again from the field a build of the same config and
// coordinate kept, with other volumes: the same tile, byte for byte, as
// nav_build_tile gives from the triangles of that build and these volumes.
// Invalid for a field that is not of this grid.
nav_build_tile_again :: proc(config:Nav_Build_Config,coord:[2]i32,field:^Nav_Tile_Field,volumes:[]Nav_Area_Volume,scratch:^Nav_Build_Scratch,out:^Nav_Tile_Data,allocator:=context.allocator) -> Nav_Build_Status {
    if out==nil {return .Invalid}
    out^={}
    if scratch==nil || scratch.allocator.procedure==nil || field==nil {return .Invalid}
    g,ok:=nav_build_grid(config,coord)
    if !ok || !nav_build_input_valid({volumes=volumes}) || !nav_tile_field_valid(&g,field) {return .Invalid}
    context.allocator=scratch.allocator
    s:=scratch
    if !nav_resize(&s.cells,len(field.cells)) || !nav_resize(&s.compact,len(field.spans)) || !nav_resize(&s.area,len(field.areas)) {return .Out_Of_Memory}
    copy(s.cells[:],field.cells)
    copy(s.compact[:],field.spans)
    copy(s.area[:],field.areas)
    g.base=field.base
    nav_link_compact(s,&g)
    return nav_build_surface(s,&g,coord,volumes,out,allocator)
}

// From the walkable spans to the tile: the volumes, the erosion, the
// regions, their outlines and the polygons.
@(private)
nav_build_surface :: proc(s:^Nav_Build_Scratch,g:^Nav_Grid,coord:[2]i32,volumes:[]Nav_Area_Volume,out:^Nav_Tile_Data,allocator:runtime.Allocator) -> Nav_Build_Status {
    nav_mark_volumes(s,g,volumes)
    if status:=nav_erode(s,g);status!=.Built {return status}
    if status:=nav_build_regions(s,g);status!=.Built {return status}
    if status:=nav_build_contours(s,g);status!=.Built {return status}
    if status:=nav_build_polymesh(s,g);status!=.Built {return status}
    if status:=nav_build_detail(s,g);status!=.Built {return status}
    return nav_build_finish(s,g,coord,out,allocator)
}

// What a build derives from its config: sizes in cells and the heightfield.
@(private)
Nav_Grid :: struct {
    origin:[2]f32,          // x and z of config.origin
    cs,ch,ics:f32,
    tile,border,side:i32,   // cells across the tile, each border and the heightfield
    corner:[2]i32,          // global cell of the first column of the heightfield, x and z
    low,high:[2]f32,        // the heightfield on XZ, from origin
    base:f64,               // global height cell of span height 0, set by the rasterization
    height,climb,radius:i32,
    slope_cos2:f64,         // squared cosine of the steepest walkable slope
    max_error:f32,          // cells
    max_edge:i32,           // cells; 0: no limit
    sample_distance,sample_error:f32,
    min_region,merge_region:i32,
}

@(private)
nav_finite :: #force_inline proc "contextless" (x:f32) -> bool {return abs(x)<=max(f32)}

@(private)
nav_world :: #force_inline proc "contextless" (origin:f32,cell:i64,size:f32) -> f32 {
    return f32(f64(origin)+f64(cell)*f64(size))
}

@(private)
nav_build_grid :: proc "contextless" (c:Nav_Build_Config,coord:[2]i32) -> (g:Nav_Grid,ok:bool) {
    if !nav_finite(c.origin.x) || !nav_finite(c.origin.z) || c.tile_size<=0 {return}
    if !(c.cell_size>0) || !nav_finite(c.cell_size) || !(c.cell_height>0) || !nav_finite(c.cell_height) {return}
    if !(c.agent_height>0) || !nav_finite(c.agent_height) {return}
    if !(c.agent_radius>=0) || !nav_finite(c.agent_radius) || !(c.agent_climb>=0) || !nav_finite(c.agent_climb) {return}
    if !(c.agent_max_slope>=0) || !(c.agent_max_slope<f32(cmath.PI/2)) {return}
    if c.min_region_area<0 || c.merge_region_area<0 {return}
    for x in ([4]f32{c.max_edge_length,c.max_edge_error,c.detail_sample_distance,c.detail_max_error}) {
        if !(x>=0) || !nav_finite(x) {return}
    }
    radius:=f64(c.agent_radius)/f64(c.cell_size)
    height:=f64(c.agent_height)/f64(c.cell_height)
    climb:=f64(c.agent_climb)/f64(c.cell_height)
    if radius>NAV_BUILD_MAX_CELLS || height>NAV_SPAN_MAX || climb>NAV_SPAN_MAX {return}
    g.radius=i32(nav_ceil(radius,0,NAV_BUILD_MAX_CELLS))
    g.height=max(i32(nav_ceil(height,0,NAV_SPAN_MAX)),1)
    g.climb=i32(nav_floor(climb,0,NAV_SPAN_MAX))
    g.border=g.radius+3
    if i64(c.tile_size)+2*i64(g.border)>NAV_BUILD_MAX_CELLS {return}
    g.tile=c.tile_size
    g.side=g.tile+2*g.border
    g.origin={c.origin.x,c.origin.z}
    g.cs,g.ch=c.cell_size,c.cell_height
    g.ics=1/c.cell_size
    if !nav_finite(g.ics) {return}
    for k in 0..<2 {
        corner:=i64(coord[k])*i64(g.tile)-i64(g.border)
        if corner<i64(min(i32)) || corner+i64(g.side)>i64(max(i32)) {return}
        g.corner[k]=i32(corner)
        g.low[k]=f32(g.corner[k])*g.cs
        g.high[k]=f32(g.corner[k]+g.side)*g.cs
        if !nav_finite(g.low[k]) || !nav_finite(g.high[k]) {return}
        if !nav_finite(nav_world(g.origin[k],corner,g.cs)) || !nav_finite(nav_world(g.origin[k],corner+i64(g.side),g.cs)) {return}
    }
    _,cos:=cmath.sincos(f64(c.agent_max_slope))
    g.slope_cos2=cos*cos
    g.max_error=f32(f64(c.max_edge_error)/f64(c.cell_size))
    edge:=f64(c.max_edge_length)/f64(c.cell_size)
    g.max_edge=i32(nav_floor(edge,0,4*NAV_BUILD_MAX_CELLS))
    if c.max_edge_length>0 && g.max_edge==0 {g.max_edge=1}
    // Samples closer than a cell read the same voxels.
    g.sample_distance=c.detail_sample_distance
    if g.sample_distance>0 && g.sample_distance<c.cell_size {g.sample_distance=c.cell_size}
    g.sample_error=c.detail_max_error
    g.min_region=c.min_region_area
    g.merge_region=c.merge_region_area
    return g,true
}

@(private)
nav_build_input_valid :: proc "contextless" (input:Nav_Build_Input) -> bool {
    if len(input.indices)%3!=0 {return false}
    for index in input.indices {if int(index)>=len(input.vertices) {return false}}
    if len(input.triangle_areas)!=0 && len(input.triangle_areas)!=len(input.indices)/3 {return false}
    for area in input.triangle_areas {if area>NAV_AREA_MAX {return false}}
    for volume in input.volumes {if volume.count>8 || volume.area>NAV_AREA_MAX {return false}}
    return true
}

// Grows the array to count zeroed items.
@(private)
nav_resize :: proc(array:^[dynamic]$T,count:int) -> bool {
    clear(array)
    return resize(array,count)==nil
}

@(private)
Nav_Bv_Item :: struct {
    min,max:[3]u16,
    index:i32,
}

// Converts the mesh to world space and packs it into one block.
@(private)
nav_build_finish :: proc(s:^Nav_Build_Scratch,g:^Nav_Grid,coord:[2]i32,out:^Nav_Tile_Data,allocator:runtime.Allocator) -> Nav_Build_Status {
    vertex_count,poly_count:=len(s.mesh_verts),len(s.polys)
    detail_vertex_count,detail_triangle_count:=len(s.detail_verts),len(s.detail_out)
    bv_count:=2*poly_count-1
    offsets:[7]int
    size:=0
    place :: proc "contextless" (size:^int,offset:^int,count,item,align:int) {
        size^=(size^+align-1)&~(align-1)
        offset^=size^
        size^+=count*item
    }
    place(&size,&offsets[0],vertex_count,size_of(math.Vec3),align_of(math.Vec3))
    place(&size,&offsets[1],poly_count,size_of(Nav_Poly),align_of(Nav_Poly))
    place(&size,&offsets[2],poly_count,size_of(Nav_Detail),align_of(Nav_Detail))
    place(&size,&offsets[3],detail_vertex_count,size_of(math.Vec3),align_of(math.Vec3))
    place(&size,&offsets[4],detail_triangle_count,size_of(Nav_Detail_Triangle),align_of(Nav_Detail_Triangle))
    place(&size,&offsets[5],bv_count,size_of(Nav_Bv),align_of(Nav_Bv))
    place(&size,&offsets[6],poly_count,size_of(u32),align_of(u32))
    block,error:=mem.alloc_bytes(size,16,allocator)
    if error!=nil || block==nil {return .Out_Of_Memory}
    mem.zero_slice(block)
    at :: proc "contextless" (block:[]byte,offset,count:int,$T:typeid) -> []T {
        if count==0 {return nil}
        return ([^]T)(rawptr(uintptr(raw_data(block))+uintptr(offset)))[:count]
    }
    out^={
        coord=coord,
        cell_size=g.cs,
        cell_height=g.ch,
        vertices=at(block,offsets[0],vertex_count,math.Vec3),
        polys=at(block,offsets[1],poly_count,Nav_Poly),
        details=at(block,offsets[2],poly_count,Nav_Detail),
        detail_vertices=at(block,offsets[3],detail_vertex_count,math.Vec3),
        detail_triangles=at(block,offsets[4],detail_triangle_count,Nav_Detail_Triangle),
        bv=at(block,offsets[5],bv_count,Nav_Bv),
        poly_links=at(block,offsets[6],poly_count,u32),
        block=block,
        allocator=allocator,
    }
    tile:=[2]i64{i64(coord.x)*i64(g.tile),i64(coord.y)*i64(g.tile)}
    bounds:=math.Aabb{{max(f32),max(f32),max(f32)},{-max(f32),-max(f32),-max(f32)}}
    for v,i in s.mesh_verts {
        p:=math.Vec3{nav_world(g.origin.x,tile.x+i64(v.x),g.cs),f32((g.base+f64(v.y))*f64(g.ch)),nav_world(g.origin.y,tile.y+i64(v.z),g.cs)}
        out.vertices[i]=p
        bounds=math.aabb_add_point(bounds,p)
    }
    copy(out.detail_vertices,s.detail_verts[:])
    copy(out.detail_triangles,s.detail_out[:])
    copy(out.details,s.details[:])
    for v in s.detail_verts {bounds=math.aabb_add_point(bounds,v)}
    out.bounds=bounds
    for p,i in s.polys {
        dst:=&out.polys[i]
        dst.count=p.count
        dst.area=p.area
        for k in 0..<int(p.count) {
            dst.vertices[k]=p.vertices[k]
            n:=p.neighbor[k]
            dst.neighbor[k]=n==NAV_NULL_INDEX ? NAV_EDGE_WALL : n&NAV_EDGE_PORTAL!=0 ? n : n+1
        }
    }
    if !nav_build_bv(s,g,out) {nav_tile_data_free(out);return .Out_Of_Memory}
    return .Built
}

// The tree over the polygons: each level splits its items in halves along the
// longest axis of their bounds, as Detour does.
@(private)
nav_build_bv :: proc(s:^Nav_Build_Scratch,g:^Nav_Grid,out:^Nav_Tile_Data) -> bool {
    if !nav_resize(&s.bv_items,len(out.polys)) {return false}
    quantize :: proc "contextless" (x,low,size:f32,up:bool) -> u16 {
        q:=f64(x-low)/f64(size)
        return u16(up ? nav_ceil(q,0,0xffff) : nav_floor(q,0,0xffff))
    }
    for p,i in out.polys {
        box:=math.Aabb{out.vertices[p.vertices[0]],out.vertices[p.vertices[0]]}
        for k in 1..<int(p.count) {box=math.aabb_add_point(box,out.vertices[p.vertices[k]])}
        d:=out.details[i]
        for k in 0..<int(d.vertex_count) {box=math.aabb_add_point(box,out.detail_vertices[int(d.vertex_first)+k])}
        item:=&s.bv_items[i]
        item.index=i32(i)
        sizes:=[3]f32{g.cs,g.ch,g.cs}
        for a in 0..<3 {
            item.min[a]=quantize(box.min[a],out.bounds.min[a],sizes[a],false)
            item.max[a]=quantize(box.max[a],out.bounds.min[a],sizes[a],true)
        }
    }
    node:=0
    nav_bv_split(s.bv_items[:],out.bv,&node)
    return true
}

@(private="file")
nav_bv_split :: proc(items:[]Nav_Bv_Item,nodes:[]Nav_Bv,next:^int) {
    current:=next^
    next^+=1
    node:=&nodes[current]
    if len(items)==1 {
        node^={items[0].min,items[0].max,items[0].index}
        return
    }
    node.min,node.max=items[0].min,items[0].max
    for item in items[1:] {
        for a in 0..<3 {node.min[a]=min(node.min[a],item.min[a]);node.max[a]=max(node.max[a],item.max[a])}
    }
    extent:=[3]u16{node.max[0]-node.min[0],node.max[1]-node.min[1],node.max[2]-node.min[2]}
    axis:=0
    if extent[1]>extent[axis] {axis=1}
    if extent[2]>extent[axis] {axis=2}
    switch axis {
    case 0: slice.sort_by(items,proc(a,b:Nav_Bv_Item) -> bool {return a.min[0]<b.min[0] || a.min[0]==b.min[0] && a.index<b.index})
    case 1: slice.sort_by(items,proc(a,b:Nav_Bv_Item) -> bool {return a.min[1]<b.min[1] || a.min[1]==b.min[1] && a.index<b.index})
    case: slice.sort_by(items,proc(a,b:Nav_Bv_Item) -> bool {return a.min[2]<b.min[2] || a.min[2]==b.min[2] && a.index<b.index})
    }
    half:=len(items)/2
    nav_bv_split(items[:half],nodes,next)
    nav_bv_split(items[half:],nodes,next)
    node.index=-i32(next^-current)
}
