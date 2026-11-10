package terrain

import "core:math"
import "core:math/rand"
import "core:testing"
import "mirai:core"
import "mirai:std/geom"
import "mirai:std/jobs"

@(test)
the_quadtree_of_a_source_covers_its_chunks_once_from_one_root :: proc(t:^testing.T) {
    s:Source;defer source_destroy(&s)
    testing.expect(t,source_make(&s,.Heightfield,{161,1,129},1,16))
    q:=quad_of(&s)
    // 10 by 8 chunks: 5 by 4, 3 by 2, 2 by 1 and the root.
    testing.expect_value(t,q.depth,4)
    testing.expect_value(t,quad_total(&q),80+20+6+2+1)
    count:=make([]int,80,context.temp_allocator)
    for d in 0..=q.depth {
        for &c in count {c=0}
        for i in q.first[d]..<q.first[d+1] {
            a,b:=quad_chunks(&q,i)
            for z in a.y..<b.y {for x in a.x..<b.x {count[x+10*z]+=1}}
            if d>0 {
                for child in quad_children(&q,i) {if child>=0 {testing.expect_value(t,quad_parent(&q,child),i)}}
            }
        }
        for c in count {testing.expect_value(t,c,1)}
    }
    testing.expect_value(t,quad_parent(&q,quad_total(&q)-1),-1)
    low,high:=quad_region(&s,&q,quad_total(&q)-1)
    testing.expect(t,low=={0,0} && high=={160,128})
    // One chunk has a root too: what shows when it goes.
    one:Source;defer source_destroy(&one)
    testing.expect(t,source_make(&one,.Heightfield,{9,1,9},1,8))
    small:=quad_of(&one)
    testing.expect(t,small.depth==1 && quad_total(&small)==2)
    volume:Source;defer source_destroy(&volume)
    testing.expect(t,source_make(&volume,.Volume,{17,17,17},1,8))
    v:=quad_of(&volume)
    testing.expect(t,v.depth==1 && quad_total(&v)==9)
    testing.expect_value(t,quad_place(&volume,&v,5),chunk_coord(&volume,5))
}

@(test)
the_coarse_grid_holds_the_samples_at_its_points_and_follows_edits :: proc(t:^testing.T) {
    s:Source;defer source_destroy(&s)
    testing.expect(t,source_make(&s,.Heightfield,{101,1,77},1,16))
    for z in 0..<77 {for x in 0..<101 {source_set(&s,{x,0,z},f32((x*7+z*3)%11)*0.5+f32(x)*0.01)}}
    n:=chunk_counts(&s)
    ranges:=make([][2]f32,n.x*n.z,context.temp_allocator)
    testing.expect(t,source_coarse_build(&s,ranges))
    check :: proc(t:^testing.T,s:^Source) {
        for j in 0..<s.coarse.size.y {for i in 0..<s.coarse.size.x {
            x,z:=coarse_position(i,int(s.samples.x)),coarse_position(j,int(s.samples.z))
            testing.expect_value(t,coarse_height(s,x,z),grid_get(&s.heights,x,z))
        }}
    }
    check(t,&s)
    // The last row and column are points of it, whatever the step.
    testing.expect_value(t,coarse_height(&s,100,76),grid_get(&s.heights,100,76))
    for range,i in ranges {
        low,high,_:=chunk_region(&s,chunk_coord(&s,i))
        for z in low.z..=high.z {for x in low.x..=high.x {h:=grid_get(&s.heights,x,z);testing.expect(t,h>=range.x && h<=range.y)}}
    }
    change:=source_edit(&s,{kind=.Raise,center={-10,0,-6},radius=6,amount=40})
    testing.expect(t,change.changed)
    source_coarse_update(&s,change.low,change.high,ranges)
    check(t,&s)
    top:=f32(0)
    for z in change.low.z..=change.high.z {for x in change.low.x..=change.high.x {top=max(top,grid_get(&s.heights,x,z))}}
    covered:=false
    for range in ranges {if range.y>=top {covered=true}}
    testing.expect(t,top>30 && covered,"the ranges reach what the edit raised")
}

@(test)
the_coarse_grid_built_in_jobs_is_the_one_built_alone :: proc(t:^testing.T) {
    s:Source;defer source_destroy(&s)
    testing.expect(t,source_make(&s,.Heightfield,{133,1,101},1,16))
    for z in 0..<101 {for x in 0..<133 {source_set(&s,{x,0,z},math.sin(f32(x)*0.31)*4+f32((x*5+z*11)%7)*0.3)}}
    n:=chunk_counts(&s)
    alone_ranges:=make([][2]f32,n.x*n.z,context.temp_allocator)
    alone_errors:=make([]Lod_Errors,n.x*n.z,context.temp_allocator)
    testing.expect(t,source_coarse_build(&s,alone_ranges,alone_errors))
    size:=s.coarse.size
    alone:=make([]f32,size.x*size.y,context.temp_allocator)
    for j in 0..<size.y {for i in 0..<size.x {alone[i+size.x*j]=grid_get(&s.coarse.heights,i,j)}}
    system:jobs.Job_System
    if !testing.expect(t,jobs.system_init(&system,{threads=3})) {return}
    defer jobs.system_destroy(&system)
    ranges:=make([][2]f32,n.x*n.z,context.temp_allocator)
    errors:=make([]Lod_Errors,n.x*n.z,context.temp_allocator)
    testing.expect(t,source_coarse_build(&s,ranges,errors,&system))
    for j in 0..<size.y {for i in 0..<size.x {testing.expect_value(t,grid_get(&s.coarse.heights,i,j),alone[i+size.x*j])}}
    for range,i in ranges {testing.expect_value(t,range,alone_ranges[i])}
    for e,i in errors {testing.expect_value(t,e,alone_errors[i])}
}

// A Heightfield of 8 by 8 chunks shown by chunks of mixed levels, nodes of
// depth 1 and 2, and a chunk next to a node of depth 2: their borders meet.
@(test)
quadtree_nodes_and_chunks_of_mixed_levels_join_without_cracks_or_overlaps :: proc(t:^testing.T) {
    s:Source;defer source_destroy(&s)
    testing.expect(t,source_make(&s,.Heightfield,{129,1,129},0.5,16))
    for z in 0..<129 {for x in 0..<129 {source_set(&s,{x,0,z},math.sin(f32(x)*0.37)*2+math.cos(f32(z)*0.23)*3+f32((x*7+z*13)%5)*0.1)}}
    testing.expect(t,source_coarse_build(&s,nil))
    q:=quad_of(&s)
    testing.expect_value(t,q.depth,3)
    // By chunk: the depth of the piece that covers it.
    depth_at :: proc(x,z:int) -> int {
        switch {
        case x<4 && z<4: return 0
        case x>=4 && z<4: return 1
        case x<4 && z>=4: return 2
        case x<6 && z<6: return 0
        }
        return 1
    }
    pieces:[dynamic]int;defer delete(pieces)
    for d in 0..=q.depth {for i in q.first[d]..<q.first[d+1] {
        a,_:=quad_chunks(&q,i)
        if depth_at(a.x,a.y)==d {append(&pieces,i)}
    }}
    levels:[64]u8
    deep:[64]bool
    mesh:Chunk_Mesh;chunk_mesh_init(&mesh);defer chunk_mesh_destroy(&mesh)
    border:Piece_Border;defer piece_border_destroy(&border)
    all:geom.Mesh_Buffer;geom.mesh_buffer_init(&all);defer geom.mesh_buffer_destroy(&all)
    welded:geom.Mesh_Buffer;geom.mesh_buffer_init(&welded);defer geom.mesh_buffer_destroy(&welded)
    random:=rand.create(11)
    generator:=rand.default_random_generator(&random)
    for round in 0..<8 {
        for i in 0..<64 {
            coord:=chunk_coord(&s,i)
            levels[i]=u8(rand.int_max(int(chunk_lod_max(&s,coord))+1,generator))
            // Only a chunk that shows can be deep: its pages are in memory.
            deep[i]=depth_at(int(coord.x),int(coord.z))==0 && (round==0 || rand.int_max(3,generator)>0)
        }
        b:=Border_Levels{counts=q.counts[0],levels=levels[:],deep=deep[:]}
        geom.mesh_buffer_clear(&all)
        nodes:=0
        for i in pieces {
            if i<q.first[1] {
                coord:=chunk_coord(&s,i)
                testing.expect(t,chunk_build(&s,coord,&mesh,false,chunk_lod_border(&b,levels[i],{int(coord.x),int(coord.z)})))
            } else {
                a,c:=quad_chunks(&q,i)
                piece_border(&b,a,c,&border)
                minimum,maximum:=node_lod_min(&s,&q,i),node_lod_max(&s,&q,i)
                level:=minimum+u8(rand.int_max(int(maximum-minimum)+1,generator))
                testing.expect(t,node_build(&s,&q,i,{level=level},&border,&mesh))
                nodes+=1
            }
            chunk_in_terrain(&mesh)
            lod_append(&all,&mesh.geometry)
        }
        testing.expect_value(t,nodes,4+1+3)
        area:=f32(0)
        for at:=0;at<len(all.indices);at+=3 {
            a,b,c:=all.positions[all.indices[at]],all.positions[all.indices[at+1]],all.positions[all.indices[at+2]]
            up:=(b.z-a.z)*(c.x-a.x)-(b.x-a.x)*(c.z-a.z)
            testing.expect(t,up>0,"every triangle faces up")
            area+=up*0.5
        }
        testing.expectf(t,abs(area-64*64)<1e-1,"round %d: the pieces cover %v of %v",round,area,64*64)
        geom.mesh_weld(geom.mesh_buffer_view(&all),0,&welded)
        edges:=make(map[[2]u32]int,context.temp_allocator)
        for at:=0;at<len(welded.indices);at+=3 {
            for corner in 0..<3 {
                a,b:=welded.indices[at+corner],welded.indices[at+(corner+1)%3]
                edges[{min(a,b),max(a,b)}]+=1
            }
        }
        for edge,uses in edges {
            if uses==2 {continue}
            testing.expect_value(t,uses,1)
            a,b:=welded.positions[edge[0]],welded.positions[edge[1]]
            outer:=(abs(a.x)==32 && a.x==b.x) || (abs(a.z)==32 && a.z==b.z)
            testing.expectf(t,outer,"round %d: an open edge %v-%v inside the terrain",round,a,b)
        }
        // A vertex pieces share has one normal.
        normals:=make(map[[3]f32][3]f32,context.temp_allocator)
        for p,i in all.positions {
            if old,ok:=normals[p];ok {testing.expect_value(t,all.normals[i],old)} else {normals[p]=all.normals[i]}
        }
    }
}

// A level is the coarsest whose error covers about a pixel, never finer than
// samples two pixels apart, and stays put near the bounds.
@(test)
levels_follow_the_projected_error_and_the_spacing_of_the_samples :: proc(t:^testing.T) {
    q:Quad
    q.first[1]=1
    errors:=[]Lod_Errors{{levels={0,0.01,0.02,0.04,0.5,1,2,4,8,8,8,8,8,8,8,8,8,8,8,8,8}}}
    // 100 pixels a metre: the error of level 2 covers 2 pixels, that of level 1 one.
    testing.expect_value(t,lod_level_error(errors,&q,0,0,5,100,1000,0.01,99),u8(1))
    // Smoother: everything up to level 3 fits; level 4 does not.
    testing.expect_value(t,lod_level_error(errors,&q,0,0,5,10,1000,0.01,99),u8(3))
    // Noise finer than a pixel: the samples 0.1 m apart cover 0.1 pixels, level 5 is the finest worth it.
    testing.expect_value(t,lod_spacing_level(1,0.1),u8(5))
    testing.expect_value(t,lod_level_error(errors,&q,0,0,6,100,1,0.1,99),u8(5))
    // Near a bound the level held stays.
    // At 55 pixels a metre level 1 fits and level 2 just misses: a level 2 held stays, a level 0 does not.
    testing.expect_value(t,lod_level_error(errors,&q,0,0,5,55,1000,0.01,2),u8(2))
    testing.expect_value(t,lod_level_error(errors,&q,0,0,5,55,1000,0.01,0),u8(1))
    testing.expect_value(t,lod_level_error(errors,&q,0,0,5,55,1000,0.01,99),u8(1))
    // The view: 900 pixels high at 60 degrees, or its own.
    testing.expect(t,abs(view_pixels({})-LOD_VIEW_PIXELS)<1e-3)
    view:=core.VIEW_DEFAULT
    view.size={1440,1800}
    testing.expect(t,abs(view_pixels(view)-2*LOD_VIEW_PIXELS)<1e-2)
}

// Appends a piece to a mesh of all of them, as they stand in their terrain.
@(private)
lod_append :: proc(all:^geom.Mesh_Buffer,m:^geom.Mesh_Buffer) {
    first:=u32(len(all.positions))
    append(&all.positions,..m.positions[:])
    append(&all.normals,..m.normals[:])
    for index in m.indices {append(&all.indices,index+first)}
    append(&all.materials,..m.materials[:])
}
