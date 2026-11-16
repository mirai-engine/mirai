package ai

import "base:runtime"
import "core:math/linalg"
import math "mirai:std/math"

// Builds a zone of a volume: a voxel is free when its center lies in one of
// the spaces and its box, grown by the half size of the agent on each axis,
// touches no triangle. The octree is laid out from the blocks up and written
// layer by layer from the root down.

Nav_Volume_Config :: struct {
    origin:math.Vec3, // corner of zone (0,0,0)
    voxel:f32,        // m across a voxel
    layers:int,       // above the blocks
    half:math.Vec3,   // m the obstacles grow along each axis: half the size of the agent
}

// Triangles in world space, wound either way, that touch the zone grown by
// the half size; the boxes the volume fills, such as the bounds of the air or
// the water; and the boxes taken out of them, grown by the half size, such
// as the dry boxes in the water.
Nav_Volume_Input :: struct {
    vertices:[]math.Vec3,
    indices:[]u32,
    spaces:[]math.Aabb,
    holes:[]math.Aabb,
}

Nav_Volume_Scratch :: struct {
    solid:[dynamic]u64,             // a bit per voxel, a u64 per block: set when blocked
    cells:[dynamic]Nav_Volume_Cell, // of every layer, dense, layer 0 first
    queue,next:[dynamic][3]i32,     // the cells of the nodes of a layer being written, and of the next
    allocator:runtime.Allocator,
}

nav_volume_scratch_init :: proc(scratch:^Nav_Volume_Scratch,allocator:=context.allocator) {
    nav_volume_scratch_destroy(scratch)
    scratch.allocator=allocator
}
nav_volume_scratch_destroy :: proc(scratch:^Nav_Volume_Scratch) {
    delete(scratch.solid);delete(scratch.cells);delete(scratch.queue);delete(scratch.next)
    scratch^={}
}

nav_volume_config_valid :: proc "contextless" (config:Nav_Volume_Config) -> bool {
    if !(config.voxel>0) || config.voxel>1e6 || config.layers<0 || config.layers>NAV_VOLUME_MAX_LAYERS {return false}
    for axis in 0..<3 {
        if !(abs(config.origin[axis])<=1e9) || !(config.half[axis]>=0) || config.half[axis]>1e6 {return false}
    }
    return true
}

// The box a zone of a config covers.
nav_volume_config_zone_box :: proc "contextless" (config:Nav_Volume_Config,coord:[3]i32) -> math.Aabb {
    size:=config.voxel*f32(i32(NAV_VOLUME_BLOCK)<<uint(config.layers))
    low:=config.origin+math.Vec3{f32(coord.x),f32(coord.y),f32(coord.z)}*size
    return {low,low+size}
}

// Builds the zone at coord into out, whose slices live in one block allocated
// with allocator; out is overwritten. Empty when nothing in the zone is free.
nav_volume_build :: proc(config:Nav_Volume_Config,coord:[3]i32,input:Nav_Volume_Input,scratch:^Nav_Volume_Scratch,out:^Nav_Volume_Data,allocator:=context.allocator) -> Nav_Build_Status {
    if out==nil {return .Invalid}
    out^={}
    if scratch==nil || scratch.allocator.procedure==nil || !nav_volume_config_valid(config) {return .Invalid}
    for c in coord {if abs(c)>1_000_000 {return .Invalid}}
    if len(input.indices)%3!=0 {return .Invalid}
    for index in input.indices {if int(index)>=len(input.vertices) {return .Invalid}}
    box:=nav_volume_config_zone_box(config,coord)
    if !nav_point_finite(box.min) || !nav_point_finite(box.max) {return .Invalid}
    context.allocator=scratch.allocator
    s:=scratch
    layers:=uint(config.layers)
    n:=i32(NAV_VOLUME_BLOCK<<layers)
    side:=i32(1)<<layers
    if resize(&s.solid,int(side*side*side))!=nil {return .Out_Of_Memory}
    for &word in s.solid {word=max(u64)}
    voxel:=config.voxel

    clear_voxel :: #force_inline proc "contextless" (solid:[]u64,side:i32,v:[3]i32) {
        b:=nav_volume_shr(v,2)
        solid[b.x+b.y*side+b.z*side*side]&=~(u64(1)<<nav_volume_voxel_bit(v))
    }
    fill_voxel :: #force_inline proc "contextless" (solid:[]u64,side:i32,v:[3]i32) {
        b:=nav_volume_shr(v,2)
        solid[b.x+b.y*side+b.z*side*side]|=u64(1)<<nav_volume_voxel_bit(v)
    }
    // The voxels whose centers are in a box: low > high on an axis when none.
    voxels_in :: proc "contextless" (space,box:math.Aabb,voxel:f32,n:i32) -> (low,high:[3]i32,empty:bool) {
        for axis in 0..<3 {
            lo:=(space.min[axis]-box.min[axis])/voxel-0.5
            hi:=(space.max[axis]-box.min[axis])/voxel-0.5
            if !(hi>=0) || !(lo<f32(n)) || !(lo<=hi) {return low,high,true}
            low[axis]=0 if lo<=0 else min(i32(linalg.ceil(lo)),n)
            high[axis]=n-1 if hi>=f32(n-1) else i32(hi)
        }
        return
    }
    for space in input.spaces {
        low,high,empty:=voxels_in(space,box,voxel,n)
        if empty {continue}
        for z in low.z..=high.z {for y in low.y..=high.y {for x in low.x..=high.x {clear_voxel(s.solid[:],side,{x,y,z})}}}
    }
    for hole in input.holes {
        low,high,empty:=voxels_in({hole.min-config.half,hole.max+config.half},box,voxel,n)
        if empty {continue}
        for z in low.z..=high.z {for y in low.y..=high.y {for x in low.x..=high.x {fill_voxel(s.solid[:],side,{x,y,z})}}}
    }

    grown:=config.half+voxel*0.5
    for t:=0;t+2<len(input.indices);t+=3 {
        a,b,c:=input.vertices[input.indices[t]],input.vertices[input.indices[t+1]],input.vertices[input.indices[t+2]]
        if !nav_point_finite(a) || !nav_point_finite(b) || !nav_point_finite(c) {continue}
        tmin:=linalg.min(linalg.min(a,b),c)-config.half
        tmax:=linalg.max(linalg.max(a,b),c)+config.half
        low,high:[3]i32
        empty:=false
        for axis in 0..<3 {
            lo:=(tmin[axis]-box.min[axis])/voxel
            hi:=(tmax[axis]-box.min[axis])/voxel
            if hi<0 || lo>=f32(n) {empty=true;break}
            low[axis]=0 if lo<=0 else i32(lo)
            high[axis]=n-1 if hi>=f32(n-1) else i32(hi)
        }
        if empty {continue}
        for z in low.z..=high.z {
            for y in low.y..=high.y {
                for x in low.x..=high.x {
                    v:=[3]i32{x,y,z}
                    bv:=nav_volume_shr(v,2)
                    word:=&s.solid[bv.x+bv.y*side+bv.z*side*side]
                    bit:=u64(1)<<nav_volume_voxel_bit(v)
                    if word^&bit!=0 {continue}
                    center:=box.min+(math.Vec3{f32(x),f32(y),f32(z)}+0.5)*voxel
                    if nav_triangle_box_overlap(center,grown,a,b,c) {word^|=bit}
                }
            }
        }
    }

    // Every layer, dense, from the blocks up.
    offsets:[NAV_VOLUME_MAX_LAYERS+2]int
    for k in 0..=int(layers) {
        s_k:=int(side>>uint(k))
        offsets[k+1]=offsets[k]+s_k*s_k*s_k
    }
    if resize(&s.cells,offsets[layers+1])!=nil {return .Out_Of_Memory}
    for word,i in s.solid {
        s.cells[i]=.Free if word==0 else .Blocked if word==max(u64) else .Mixed
    }
    mixed:[NAV_VOLUME_MAX_LAYERS+1]int
    for &word in s.solid {if word!=0 && word!=max(u64) {mixed[0]+=1}}
    for k in 1..=int(layers) {
        s_k:=i32(side>>uint(k))
        s_below:=s_k*2
        for z in 0..<s_k {
            for y in 0..<s_k {
                for x in 0..<s_k {
                    first:=Nav_Volume_Cell.Mixed
                    same:=true
                    for o in 0..<8 {
                        cx,cy,cz:=x*2+i32(o&1),y*2+i32((o>>1)&1),z*2+i32((o>>2)&1)
                        child:=s.cells[offsets[k-1]+int(cx+cy*s_below+cz*s_below*s_below)]
                        if o==0 {first=child} else if child!=first {same=false}
                    }
                    cell:=first if same && first!=.Mixed else Nav_Volume_Cell.Mixed
                    s.cells[offsets[k]+int(x+y*s_k+z*s_k*s_k)]=cell
                    if cell==.Mixed {mixed[k]+=1}
                }
            }
        }
    }
    if s.cells[offsets[layers]]==.Blocked {return .Empty}

    // The nodes, root first: a layer holds the eight children of each Mixed node above.
    counts:[NAV_VOLUME_MAX_LAYERS+1]int
    counts[layers]=1
    total:=1
    for k:=int(layers);k>=1;k-=1 {counts[k-1]=mixed[k]*8;total+=counts[k-1]}
    voxel_words:=mixed[0]
    data,made:=nav_volume_data_alloc(total,voxel_words,allocator)
    if !made {return .Out_Of_Memory}
    data.coord,data.layers=coord,u8(layers)
    voxels,nodes:=data.voxels,data.nodes
    clear(&s.queue)
    append(&s.queue,[3]i32{})
    at:=0
    words:=0
    for k:=int(layers);k>=0;k-=1 {
        data.first[k]=u32(at)
        clear(&s.next)
        s_k:=i32(side>>uint(k))
        for cell_at in s.queue {
            cell:=s.cells[offsets[k]+int(cell_at.x+cell_at.y*s_k+cell_at.z*s_k*s_k)]
            node:=Nav_Volume_Node{cell=cell}
            if cell==.Mixed {
                if k==0 {
                    node.children=u32(words)
                    voxels[words]=s.solid[cell_at.x+cell_at.y*side+cell_at.z*side*side]
                    words+=1
                } else {
                    node.children=u32(len(s.next))
                    for o in 0..<8 {append(&s.next,[3]i32{cell_at.x*2+i32(o&1),cell_at.y*2+i32((o>>1)&1),cell_at.z*2+i32((o>>2)&1)})}
                }
            }
            nodes[at]=node
            at+=1
        }
        s.queue,s.next=s.next,s.queue
    }
    out^=data
    return .Built
}

// Whether a triangle touches a box, by the separating axes of Akenine-Möller:
// the plane of the triangle, the axes of the box and their crosses with its edges.
@(private)
nav_triangle_box_overlap :: proc "contextless" (center,half:math.Vec3,a,b,c:math.Vec3) -> bool {
    v0,v1,v2:=a-center,b-center,c-center
    e0,e1,e2:=v1-v0,v2-v1,v0-v2
    normal:=linalg.cross(e0,e1)
    if abs(linalg.dot(normal,v0))>half.x*abs(normal.x)+half.y*abs(normal.y)+half.z*abs(normal.z) {return false}
    for axis in 0..<3 {
        if min(v0[axis],v1[axis],v2[axis])>half[axis] || max(v0[axis],v1[axis],v2[axis])< -half[axis] {return false}
    }
    edges:=[3]math.Vec3{e0,e1,e2}
    units:=[3]math.Vec3{{1,0,0},{0,1,0},{0,0,1}}
    for e in edges {
        for u in units {
            axis:=linalg.cross(e,u)
            p0,p1,p2:=linalg.dot(axis,v0),linalg.dot(axis,v1),linalg.dot(axis,v2)
            r:=half.x*abs(axis.x)+half.y*abs(axis.y)+half.z*abs(axis.z)
            if min(p0,p1,p2)>r || max(p0,p1,p2)< -r {return false}
        }
    }
    return true
}
