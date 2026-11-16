package geom

import "base:runtime"
import "core:math/linalg"
import "core:testing"

@(private)
iso_sphere :: proc(values:[]f32,n:int,scale:f32=1) -> Scalar_Grid {
    origin:=Vec3{-2,-2,-2}*scale
    cell:=f32(4)/f32(n-1)*scale
    for z in 0..<n {for y in 0..<n {for x in 0..<n {
        p:=origin+Vec3{f32(x),f32(y),f32(z)}*cell
        values[x+n*(y+n*z)]=linalg.length(p-Vec3{0.13,0.17,0.19}*scale)-1.31*scale
    }}}
    return {samples={n,n,n},cell={cell,cell,cell},origin=origin,values=values}
}

@(test)
isosurface_edges_weld_exactly_and_bound_an_outward_closed_volume :: proc(t:^testing.T) {
    values:[9*9*9]f32
    raw,welded:Mesh_Buffer
    mesh_buffer_init(&raw);mesh_buffer_init(&welded)
    defer mesh_buffer_destroy(&raw);defer mesh_buffer_destroy(&welded)
    for scale in ([3]f32{1,1e-8,1e8}) {
        grid:=iso_sphere(values[:],9,scale)
        testing.expect_value(t,isosurface(grid,{},{8,8,8},&raw),Iso_Error.None)
        mesh_weld(mesh_buffer_view(&raw),0,&welded)
        testing.expect(t,mesh_topology_is_closed(mesh_topology(welded.positions[:],welded.indices[:],by_position=false)))
        volume:=mesh_volume(welded.positions[:],welded.indices[:])
        testing.expectf(t,volume>0,"outward volume at scale %g was %g",scale,volume)
        for p,i in welded.positions {
            testing.expect(t,linalg.dot(welded.normals[i],p-Vec3{0.13,0.17,0.19}*scale)>0)
        }
    }
}

@(test)
isosurface_chunk_faces_match_positions_normals_and_the_complete_surface :: proc(t:^testing.T) {
    values:[9*9*9]f32
    grid:=iso_sphere(values[:],9)
    whole,part,combined,welded:Mesh_Buffer
    for b in ([]^Mesh_Buffer{&whole,&part,&combined,&welded}) {mesh_buffer_init(b)}
    defer for b in ([]^Mesh_Buffer{&whole,&part,&combined,&welded}) {mesh_buffer_destroy(b)}
    testing.expect_value(t,isosurface(grid,{},{8,8,8},&whole),Iso_Error.None)
    shared:=make(map[Vec3]Vec3);defer delete(shared)
    for x in 0..<2 {
        testing.expect_value(t,isosurface(grid,{x*4,0,0},{(x+1)*4,8,8},&part),Iso_Error.None)
        offset:=u32(len(combined.positions))
        for p,i in part.positions {
            if p.x==0 {
                if old,ok:=shared[p];ok {testing.expect_value(t,part.normals[i],old)} else {shared[p]=part.normals[i]}
            }
        }
        append(&combined.positions,..part.positions[:])
        for index in part.indices {append(&combined.indices,index+offset)}
    }
    testing.expect_value(t,len(combined.indices),len(whole.indices))
    testing.expect(t,len(shared)>0)
    mesh_weld(mesh_buffer_view(&combined),0,&welded)
    testing.expect(t,mesh_topology_is_closed(mesh_topology(welded.positions[:],welded.indices[:],by_position=false)))
    testing.expectf(t,abs(mesh_volume(welded.positions[:],welded.indices[:])-mesh_volume(whole.positions[:],whole.indices[:]))<1e-5,"chunk volumes differ")
}

@(test)
isosurface_of_a_window_matches_the_whole_grid_and_rejects_regions_that_reach_past_it :: proc(t:^testing.T) {
    values:[17*17*17]f32
    grid:=iso_sphere(values[:],17)
    whole,part:Mesh_Buffer
    mesh_buffer_init(&whole);mesh_buffer_init(&part)
    defer mesh_buffer_destroy(&whole);defer mesh_buffer_destroy(&part)
    low,high:=[3]int{6,0,6},[3]int{12,8,12}
    for level in u8(0)..=2 {
        lod:=Iso_Lod{level=level,faces={0,1,2,0,1,2},edges={0,1,2,0,1,2,0,1,2,0,1,2}}
        reach:=1<<uint(level)
        first,last:[3]int
        for axis in 0..<3 {first[axis]=max(low[axis]-reach,0);last[axis]=min(high[axis]+reach,16)}
        extent:=last-first+1
        window:=make([]f32,extent.x*extent.y*extent.z);defer delete(window)
        for z in 0..<extent.z {for y in 0..<extent.y {for x in 0..<extent.x {
            p:=first+{x,y,z}
            window[x+extent.x*(y+extent.y*z)]=values[p.x+17*(p.y+17*p.z)]
        }}}
        windowed:=grid
        windowed.values,windowed.first,windowed.extent=window,first,extent
        testing.expect_value(t,isosurface(grid,low,high,&whole,0,lod),Iso_Error.None)
        testing.expect_value(t,isosurface(windowed,low,high,&part,0,lod),Iso_Error.None)
        testing.expect(t,len(whole.positions)>0 && len(part.positions)==len(whole.positions))
        for p,i in whole.positions {
            if i>=len(part.positions) {break}
            testing.expect_value(t,part.positions[i],p)
            testing.expect_value(t,part.normals[i],whole.normals[i])
        }
        testing.expect_value(t,isosurface(windowed,low-{1,0,1},high,&part,0,lod),Iso_Error.Invalid_Region)
        short:=windowed
        short.values=window[:len(window)-1]
        testing.expect_value(t,isosurface(short,low,high,&part,0,lod),Iso_Error.Invalid_Grid)
    }
}

@(test)
isosurface_validates_grids_regions_nonfinite_values_and_exhausted_memory :: proc(t:^testing.T) {
    values:=[8]f32{-1,1,-1,1,-1,1,-1,1}
    grid:=Scalar_Grid{samples={2,2,2},cell={1,1,1},values=values[:]}
    out:Mesh_Buffer
    mesh_buffer_init(&out)
    defer mesh_buffer_destroy(&out)
    testing.expect_value(t,isosurface({}, {},{},&out),Iso_Error.Invalid_Grid)
    testing.expect_value(t,isosurface(grid,{-1,0,0},{1,1,1},&out),Iso_Error.Invalid_Region)
    testing.expect_value(t,isosurface(grid,{}, {2,1,1},&out),Iso_Error.Invalid_Region)
    testing.expect_value(t,isosurface(grid,{}, {1,1,1},&out),Iso_Error.None)
    for p in out.positions {testing.expect_value(t,p.x,f32(0.5))}
    values[0]=f32(0h7fc00000)
    testing.expect_value(t,isosurface(grid,{}, {1,1,1},&out),Iso_Error.Invalid_Grid)
    testing.expect_value(t,len(out.indices),0)
    values[0]=-1
    grid.samples={max(int),2,2}
    testing.expect_value(t,isosurface(grid,{}, {},&out),Iso_Error.Invalid_Grid)
    grid.samples={2,2,2}
    empty:Mesh_Buffer
    mesh_buffer_init(&empty,runtime.nil_allocator())
    defer mesh_buffer_destroy(&empty)
    testing.expect_value(t,isosurface(grid,{}, {1,1,1},&empty),Iso_Error.Out_Of_Memory)
}

@(test)
isosurface_reuses_output_capacity_and_preserves_identical_results :: proc(t:^testing.T) {
    values:[9*9*9]f32
    grid:=iso_sphere(values[:],9)
    a,b:Mesh_Buffer
    mesh_buffer_init(&a);mesh_buffer_init(&b)
    defer mesh_buffer_destroy(&a);defer mesh_buffer_destroy(&b)
    testing.expect_value(t,isosurface(grid,{},{8,8,8},&a),Iso_Error.None)
    held:=raw_data(a.positions)
    a.positions.allocator=runtime.nil_allocator()
    a.normals.allocator=runtime.nil_allocator()
    a.indices.allocator=runtime.nil_allocator()
    for _ in 0..<4 {testing.expect_value(t,isosurface(grid,{},{8,8,8},&a),Iso_Error.None)}
    a.positions.allocator=context.allocator;a.normals.allocator=context.allocator;a.indices.allocator=context.allocator
    testing.expect_value(t,raw_data(a.positions),held)
    testing.expect_value(t,isosurface(grid,{},{8,8,8},&b),Iso_Error.None)
    testing.expect_value(t,len(a.positions),len(b.positions))
    testing.expect_value(t,len(a.indices),len(b.indices))
    for p,i in a.positions {testing.expect_value(t,p,b.positions[i]);testing.expect_value(t,a.normals[i],b.normals[i])}
    for index,i in a.indices {testing.expect_value(t,index,b.indices[i])}
}

// The level of each region of a grid of n regions, and of what each shares:
// the finer of the regions that share it.
@(private="file")
iso_lod_of :: proc(levels:[]u8,n:[3]int,at:[3]int) -> (lod:Iso_Lod) {
    level :: proc(levels:[]u8,n,p:[3]int) -> (u8,bool) {
        for axis in 0..<3 {if p[axis]<0 || p[axis]>=n[axis] {return 0,false}}
        return levels[p.x+n.x*(p.y+n.y*p.z)],true
    }
    lod.level,_=level(levels,n,at)
    for axis in 0..<3 {for side in 0..<2 {
        p:=at;p[axis]+=side*2-1
        other,ok:=level(levels,n,p)
        lod.faces[axis*2+side]=ok?min(lod.level,other):lod.level
    }}
    for axis in 0..<3 {
        b,c:=(axis+1)%3,(axis+2)%3
        if b>c {b,c=c,b}
        for i in 0..<4 {
            edge:=lod.level
            for mask in 1..<4 {
                p:=at
                if mask&1!=0 {p[b]+=(i&1)*2-1}
                if mask&2!=0 {p[c]+=((i>>1)&1)*2-1}
                if other,ok:=level(levels,n,p);ok {edge=min(edge,other)}
            }
            lod.edges[axis*4+i]=edge
        }
    }
    return
}

@(test)
isosurface_regions_of_mixed_levels_join_closed_without_cracks :: proc(t:^testing.T) {
    N :: 33
    values:=make([]f32,N*N*N);defer delete(values)
    grid:=iso_sphere(values,N)
    // Bumps a coarse level does not read.
    for &value,i in values {value+=f32((i*7919)%11)*0.01}
    regions:=[3]int{4,4,4}
    size:=(N-1)/regions.x
    levels:=make([]u8,64);defer delete(levels)
    part,all,welded,whole:Mesh_Buffer
    for b in ([]^Mesh_Buffer{&part,&all,&welded,&whole}) {mesh_buffer_init(b)}
    defer for b in ([]^Mesh_Buffer{&part,&all,&welded,&whole}) {mesh_buffer_destroy(b)}
    testing.expect_value(t,isosurface(grid,{},{N-1,N-1,N-1},&whole),Iso_Error.None)
    whole_volume:=mesh_volume(whole.positions[:],whole.indices[:])
    seed:=u32(12345)
    for round in 0..<8 {
        for &level in levels {
            seed=seed*1664525+1013904223
            level=round==0?0:(round==1?2:u8((seed>>16)%3))
        }
        mesh_buffer_clear(&all)
        triangles:=0
        for z in 0..<regions.z {for y in 0..<regions.y {for x in 0..<regions.x {
            lod:=iso_lod_of(levels,regions,{x,y,z})
            low:=[3]int{x,y,z}*size
            testing.expect_value(t,isosurface(grid,low,low+size,&part,0,lod),Iso_Error.None)
            first:=u32(len(all.positions))
            append(&all.positions,..part.positions[:])
            append(&all.normals,..part.normals[:])
            for index in part.indices {append(&all.indices,index+first)}
            triangles+=len(part.indices)/3
        }}}
        if round==1 {testing.expectf(t,triangles*4<len(whole.indices)/3,"level 2 everywhere has %d triangles of %d",triangles,len(whole.indices)/3)}
        mesh_weld(mesh_buffer_view(&all),0,&welded)
        topology:=mesh_topology(welded.positions[:],welded.indices[:],by_position=false)
        testing.expectf(t,mesh_topology_is_closed(topology),"round %d: %v",round,topology)
        volume:=mesh_volume(welded.positions[:],welded.indices[:])
        testing.expectf(t,abs(volume-whole_volume)<0.15*whole_volume,"round %d: volume %g of %g",round,volume,whole_volume)
        // A vertex two regions share has one normal.
        normals:=make(map[Vec3]Vec3,context.temp_allocator)
        for p,i in all.positions {
            if old,ok:=normals[p];ok {testing.expect_value(t,all.normals[i],old)} else {normals[p]=all.normals[i]}
        }
    }
}
