package spatial

import cmath "core:math"
import "core:mem"
import "core:slice"
import "core:testing"
import math "mirai:std/math"

// A height field of 2*cells*cells triangles.
@(private) grid_mesh :: proc(cells:int, size,height:f32, allocator:=context.allocator) -> (vertices:[][3]f32, indices:[]u32) {
    side:=cells+1
    vertices=make([][3]f32,side*side,allocator)
    indices=make([]u32,cells*cells*6,allocator)
    step:=size/f32(cells)
    for z in 0..<side {
        for x in 0..<side {
            px,pz:=f32(x)*step,f32(z)*step
            vertices[z*side+x]={px,height*(cmath.sin(px*0.37)*cmath.cos(pz*0.23)+0.35*cmath.sin(px*1.7+pz*1.3)),pz}
        }
    }
    for z in 0..<cells {
        for x in 0..<cells {
            a:=u32(z*side+x)
            b,c,d:=a+1,a+u32(side),a+u32(side)+1
            copy(indices[(z*cells+x)*6:],[]u32{a,c,b,b,c,d})
        }
    }
    return
}
@(private="file") triangle_box :: proc(vertices:[][3]f32, indices:[]u32, triangle:int) -> Aabb {
    a,b,c:=vertices[indices[3*triangle]],vertices[indices[3*triangle+1]],vertices[indices[3*triangle+2]]
    return {{min(a.x,b.x,c.x),min(a.y,b.y,c.y),min(a.z,b.z,c.z)},{max(a.x,b.x,c.x),max(a.y,b.y,c.y),max(a.z,b.z,c.z)}}
}
@(private="file") bvh_depth :: proc(bvh:^Bvh, node:u32=0) -> int {
    if len(bvh.nodes)==0||bvh.nodes[node].count>0 {return 0}
    return 1+max(bvh_depth(bvh,bvh.nodes[node].first),bvh_depth(bvh,bvh.nodes[node].first+1))
}
@(private="file") bvh_largest_leaf :: proc(bvh:^Bvh) -> (largest:u32) {
    for node in bvh.nodes {largest=max(largest,node.count)}
    return
}
@(private="file") order_is_a_permutation :: proc(bvh:^Bvh, count:int) -> bool {
    if len(bvh.order)!=count {return false}
    seen:=make([]bool,count,context.temp_allocator)
    for primitive in bvh.order {
        if int(primitive)>=count||seen[primitive] {return false}
        seen[primitive]=true
    }
    return true
}
@(private="file") Expectation :: enum {Query,Ray,Sweep}
// One random query through the Bvh and through the list of boxes. Every primitive the list accepts
// must come back exactly once, inside a leaf whose own box the query touches; with `exact`, leaves
// hold one primitive and nothing else may come back.
@(private="file") bvh_agrees :: proc(bvh:^Bvh, boxes:[]Aabb, random:^Random, world:f32, kind:Expectation, exact:bool) -> bool {
    box:=random_box(random,world,world*0.2)
    origin,translation:=random_vector(random,-world*1.2,world*1.2),random_translation(random,world*2)
    max_fraction:=random_f32(random,0.1,1)
    accepts :: proc(a,box:Aabb, origin,translation:[3]f32, max_fraction:f32, kind:Expectation) -> (hit:bool) {
        switch kind {
        case .Query: hit=math.aabb_overlaps(a,box)
        case .Ray: _,hit=aabb_ray(a,origin,translation,max_fraction)
        case .Sweep: _,hit=aabb_sweep(a,box,translation,max_fraction)
        }
        return
    }
    seen:=make([]bool,len(boxes),context.temp_allocator)
    q:Bvh_Query
    r:Bvh_Ray
    s:Bvh_Sweep
    switch kind {
    case .Query: q=bvh_query(bvh,box)
    case .Ray: r=bvh_ray(bvh,origin,translation,max_fraction)
    case .Sweep: s=bvh_sweep(bvh,box,translation,max_fraction)
    }
    for {
        primitives:[]u32
        ok:bool
        switch kind {
        case .Query: primitives,ok=bvh_query_next(&q)
        case .Ray: primitives,ok=bvh_ray_next(&r)
        case .Sweep: primitives,ok=bvh_sweep_next(&s)
        }
        if !ok {break}
        if len(primitives)==0 {return false}
        leaf:=math.AABB_EMPTY
        for primitive in primitives {
            if int(primitive)>=len(boxes)||seen[primitive] {return false}
            seen[primitive]=true
            leaf=math.aabb_merge(leaf,boxes[primitive])
        }
        if !accepts(leaf,box,origin,translation,max_fraction,kind) {return false}
    }
    for other,i in boxes {
        expected:=accepts(other,box,origin,translation,max_fraction,kind)
        if expected&&!seen[i] {return false}
        if exact&&expected!=seen[i] {return false}
    }
    return true
}
@(private="file") bvh_agrees_on_everything :: proc(t:^testing.T, bvh:^Bvh, boxes:[]Aabb, seed:u64, world:f32, exact:bool, rounds:=300) {
    random:=random_make(seed)
    failures:=0
    for _ in 0..<rounds {
        for kind in Expectation {
            if !bvh_agrees(bvh,boxes,&random,world,kind,exact) {failures+=1}
        }
        free_all(context.temp_allocator)
    }
    testing.expect_value(t,failures,0)
}

@(test)
bvh_of_no_primitives_has_no_nodes :: proc(t:^testing.T) {
    bvh:Bvh
    testing.expect(t,bvh_build(&bvh,nil,{}))
    defer bvh_destroy(&bvh)
    testing.expect_value(t,len(bvh.nodes),0)
    testing.expect_value(t,len(bvh.order),0)
    testing.expect_value(t,bvh_bounds(&bvh),Aabb{})
    testing.expect(t,bvh_validate(&bvh))
    q:=bvh_query(&bvh,{{-1,-1,-1},{1,1,1}})
    r:=bvh_ray(&bvh,{0,0,0},{1,0,0},1)
    s:=bvh_sweep(&bvh,{{-1,-1,-1},{1,1,1}},{1,0,0},1)
    for _ in 0..<2 {
        _,ok:=bvh_query_next(&q)
        testing.expect(t,!ok)
        _,ok=bvh_ray_next(&r)
        testing.expect(t,!ok)
        _,ok=bvh_sweep_next(&s)
        testing.expect(t,!ok)
    }
    testing.expect(t,bvh_build_triangles(&bvh,nil,nil,{}))
    testing.expect_value(t,len(bvh.nodes),0)
}

@(test)
bvh_of_one_primitive_is_a_single_leaf :: proc(t:^testing.T) {
    bvh:Bvh
    box:=Aabb{{1,2,3},{4,5,6}}
    testing.expect(t,bvh_build(&bvh,{box},{}))
    defer bvh_destroy(&bvh)
    defer free_all(context.temp_allocator)
    testing.expect_value(t,len(bvh.nodes),1)
    testing.expect_value(t,bvh.nodes[0],Bvh_Node{min=box.min,max=box.max,first=0,count=1})
    testing.expect_value(t,bvh_bounds(&bvh),box)
    testing.expect(t,bvh_validate(&bvh))
    q:=bvh_query(&bvh,{{0,0,0},{2,3,4}})
    primitives,ok:=bvh_query_next(&q)
    testing.expect(t,ok&&len(primitives)==1&&primitives[0]==0)
    _,ok=bvh_query_next(&q)
    testing.expect(t,!ok)
    r:=bvh_ray(&bvh,{0,3,4},{2,0,0},1)
    primitives,ok=bvh_ray_next(&r)
    testing.expect(t,ok&&len(primitives)==1)
    _,ok=bvh_ray_next(&r)
    testing.expect(t,!ok)
    r=bvh_ray(&bvh,{0,3,4},{0.5,0,0},1)
    _,ok=bvh_ray_next(&r)
    testing.expect(t,!ok)
    s:=bvh_sweep(&bvh,{{-2,2,3},{-1,3,4}},{2,0,0},1)
    primitives,ok=bvh_sweep_next(&s)
    testing.expect(t,ok&&len(primitives)==1)
    q=bvh_query(&bvh,{{7,7,7},{8,8,8}})
    _,ok=bvh_query_next(&q)
    testing.expect(t,!ok)
}

@(test)
bvh_matches_brute_force_over_random_boxes :: proc(t:^testing.T) {
    COUNT :: 3000
    random:=random_make(21)
    boxes:=make([]Aabb,COUNT)
    defer delete(boxes)
    // One in eight boxes has no volume.
    for &box,i in boxes {box=random_box(&random,30,i%8==0?0:2)}
    bounds:=math.AABB_EMPTY
    for box in boxes {bounds=math.aabb_merge(bounds,box)}
    defer free_all(context.temp_allocator)

    single:Bvh
    testing.expect(t,bvh_build(&single,boxes,{max_leaf_size=1}))
    defer bvh_destroy(&single)
    testing.expect(t,bvh_validate(&single))
    testing.expect(t,order_is_a_permutation(&single,COUNT))
    testing.expect_value(t,bvh_bounds(&single),bounds)
    testing.expect_value(t,bvh_largest_leaf(&single),u32(1))
    testing.expect_value(t,len(single.nodes),2*COUNT)
    testing.expect(t,uintptr(raw_data(single.nodes))%64==0)
    bvh_agrees_on_everything(t,&single,boxes,22,30,true)

    // The default leaf holds up to four primitives.
    grouped:Bvh
    testing.expect(t,bvh_build(&grouped,boxes,{}))
    defer bvh_destroy(&grouped)
    testing.expect(t,bvh_validate(&grouped))
    testing.expect(t,order_is_a_permutation(&grouped,COUNT))
    testing.expect_value(t,bvh_bounds(&grouped),bounds)
    testing.expect(t,bvh_largest_leaf(&grouped)<=4)
    testing.expect(t,len(grouped.nodes)<len(single.nodes))
    testing.expectf(t,bvh_depth(&grouped)<=24,"depth %d for %d boxes",bvh_depth(&grouped),COUNT)
    bvh_agrees_on_everything(t,&grouped,boxes,23,30,false)

    wide:Bvh
    testing.expect(t,bvh_build(&wide,boxes,{max_leaf_size=16}))
    defer bvh_destroy(&wide)
    testing.expect(t,bvh_validate(&wide))
    testing.expect(t,bvh_largest_leaf(&wide)<=16)
    bvh_agrees_on_everything(t,&wide,boxes,24,30,false,100)
}

@(test)
bvh_over_triangles_bounds_each_triangle :: proc(t:^testing.T) {
    vertices,indices:=grid_mesh(40,50,3)
    defer delete(vertices)
    defer delete(indices)
    defer free_all(context.temp_allocator)
    count:=len(indices)/3
    testing.expect_value(t,count,3200)
    boxes:=make([]Aabb,count)
    defer delete(boxes)
    bounds:=math.AABB_EMPTY
    for &box,i in boxes {
        box=triangle_box(vertices,indices,i)
        bounds=math.aabb_merge(bounds,box)
    }
    bvh:Bvh
    testing.expect(t,bvh_build_triangles(&bvh,vertices,indices,{max_leaf_size=1}))
    defer bvh_destroy(&bvh)
    testing.expect(t,bvh_validate(&bvh))
    testing.expect(t,order_is_a_permutation(&bvh,count))
    testing.expect_value(t,bvh_bounds(&bvh),bounds)
    // Leaves of one primitive: every node box is exactly the box of its triangle.
    for node in bvh.nodes {
        if node.count==1 {
            testing.expect_value(t,Aabb{node.min,node.max},boxes[bvh.order[node.first]])
        }
    }
    // The queries run in a frame centered on the origin.
    for &box in boxes {box={box.min-{25,0,25},box.max-{25,0,25}}}
    for &vertex in vertices {vertex-={25,0,25}}
    centered:Bvh
    testing.expect(t,bvh_build_triangles(&centered,vertices,indices,{max_leaf_size=1}))
    defer bvh_destroy(&centered)
    bvh_agrees_on_everything(t,&centered,boxes,31,25,true)
    grouped:Bvh
    testing.expect(t,bvh_build_triangles(&grouped,vertices,indices,{}))
    defer bvh_destroy(&grouped)
    testing.expect(t,bvh_validate(&grouped))
    testing.expect(t,bvh_largest_leaf(&grouped)<=4)
    bvh_agrees_on_everything(t,&grouped,boxes,32,25,false)
}

@(test)
bvh_build_rejects_malformed_input :: proc(t:^testing.T) {
    defer free_all(context.temp_allocator)
    zero:=f32(0)
    bvh:Bvh
    vertices:=[][3]f32{{0,0,0},{1,0,0},{0,1,0},{1,1,0}}
    testing.expect(t,bvh_build_triangles(&bvh,vertices,{0,1,2,1,3,2},{}))
    testing.expect_value(t,len(bvh.order),2)
    bvh_destroy(&bvh)
    testing.expect(t,!bvh_build_triangles(&bvh,vertices,{0,1,2,1,3},{}))
    testing.expect(t,!bvh_build_triangles(&bvh,vertices,{0,1,2,1,4,2},{}))
    for corner in 0..<3 {
        broken:=[3][3]f32{{0,0,0},{1,0,0},{0,1,0}}
        broken[corner].y=zero/zero
        testing.expect(t,!bvh_build_triangles(&bvh,broken[:],{0,1,2},{}))
        broken[corner].y=-1/zero
        testing.expect(t,!bvh_build_triangles(&bvh,broken[:],{0,1,2},{}))
    }
    // A vertex no triangle uses does not matter.
    testing.expect(t,bvh_build_triangles(&bvh,{{0,0,0},{1,0,0},{0,1,0},{zero/zero,0,0}},{0,1,2},{}))
    bvh_destroy(&bvh)
    testing.expect(t,!bvh_build(&bvh,{{{0,0,0},{1,1,1}},{{2,2,2},{1,3,3}}},{}))
    testing.expect(t,!bvh_build(&bvh,{{{0,0,0},{1,1/zero,1}}},{}))
    testing.expect(t,!bvh_build(&bvh,{{{0,0,0},{1,1,1}},{{zero/zero,0,0},{1,1,1}}},{}))
    // A depth deeper than the stack of an iterator, or below zero.
    testing.expect(t,!bvh_build(&bvh,{{{0,0,0},{1,1,1}}},{max_depth=BVH_STACK_CAPACITY+1}))
    testing.expect(t,!bvh_build(&bvh,{{{0,0,0},{1,1,1}}},{max_depth=-1}))
    testing.expect_value(t,len(bvh.nodes),0)
    testing.expect_value(t,len(bvh.order),0)
    bvh_destroy(&bvh)
}

@(test)
bvh_build_fails_without_memory_and_leaves_nothing_behind :: proc(t:^testing.T) {
    defer free_all(context.temp_allocator)
    random:=random_make(41)
    boxes:[64]Aabb
    for &box in boxes {box=random_box(&random,10,1)}
    // Too small for the order, then large enough for it but not for the nodes.
    for size in ([2]int{64,320}) {
        buffer:[320]byte
        arena:mem.Arena
        mem.arena_init(&arena,buffer[:size])
        bvh:Bvh
        testing.expect(t,!bvh_build(&bvh,boxes[:],{allocator=mem.arena_allocator(&arena)}))
        testing.expect_value(t,len(bvh.nodes),0)
        testing.expect_value(t,len(bvh.order),0)
    }
}

@(test)
bvh_handles_primitives_that_share_one_center :: proc(t:^testing.T) {
    defer free_all(context.temp_allocator)
    // Nothing separates them, so the build halves the range until the leaves fit.
    same:[100]Aabb
    for &box in same {box={{1,1,1},{2,2,2}}}
    bvh:Bvh
    testing.expect(t,bvh_build(&bvh,same[:],{}))
    defer bvh_destroy(&bvh)
    testing.expect(t,bvh_validate(&bvh))
    testing.expect(t,order_is_a_permutation(&bvh,100))
    testing.expect(t,bvh_largest_leaf(&bvh)<=4)
    testing.expect_value(t,bvh_depth(&bvh),5)
    bvh_agrees_on_everything(t,&bvh,same[:],51,4,false,60)

    // Concentric boxes of different sizes, and points on one spot.
    nested:[33]Aabb
    for &box,i in nested {box={{-f32(i),-f32(i),-f32(i)},{f32(i),f32(i),f32(i)}}}
    concentric:Bvh
    testing.expect(t,bvh_build(&concentric,nested[:],{max_leaf_size=1}))
    defer bvh_destroy(&concentric)
    testing.expect(t,bvh_validate(&concentric))
    testing.expect_value(t,bvh_largest_leaf(&concentric),u32(1))
    bvh_agrees_on_everything(t,&concentric,nested[:],52,40,true,60)

    points:[7]Aabb
    for &box in points {box={{3,3,3},{3,3,3}}}
    spot:Bvh
    testing.expect(t,bvh_build(&spot,points[:],{max_leaf_size=2}))
    defer bvh_destroy(&spot)
    testing.expect(t,bvh_validate(&spot))
    testing.expect(t,bvh_largest_leaf(&spot)<=2)
    q:=bvh_query(&spot,{{3,3,3},{3,3,3}})
    found:=0
    for primitives in bvh_query_next(&q) {found+=len(primitives)}
    testing.expect_value(t,found,7)
}

@(test)
bvh_handles_boxes_without_volume :: proc(t:^testing.T) {
    defer free_all(context.temp_allocator)
    random:=random_make(61)
    points:[500]Aabb
    for &box in points {
        p:=random_vector(&random,-10,10)
        box={p,p}
    }
    bvh:Bvh
    testing.expect(t,bvh_build(&bvh,points[:],{max_leaf_size=1}))
    defer bvh_destroy(&bvh)
    testing.expect(t,bvh_validate(&bvh))
    bvh_agrees_on_everything(t,&bvh,points[:],62,10,true)
    // Points on a line have boxes of no area at every level of the tree.
    for &box,i in points {box={{f32(i),2,2},{f32(i),2,2}}}
    line:Bvh
    testing.expect(t,bvh_build(&line,points[:],{max_leaf_size=1}))
    defer bvh_destroy(&line)
    testing.expect(t,bvh_validate(&line))
    r:=bvh_ray(&line,{-1,2,2},{1000,0,0},1)
    last,found:=-1,0
    for primitives in bvh_ray_next(&r) {
        testing.expect(t,int(primitives[0])>last)
        last=int(primitives[0])
        found+=1
    }
    testing.expect_value(t,found,500)
}

@(test)
bvh_ray_enters_the_nearer_child_first_and_clips_to_a_lowered_fraction :: proc(t:^testing.T) {
    defer free_all(context.temp_allocator)
    boxes:[]Aabb={{{0,0,0},{1,1,1}},{{10,0,0},{11,1,1}},{{20,0,0},{21,1,1}}}
    bvh:Bvh
    testing.expect(t,bvh_build(&bvh,boxes,{max_leaf_size=1}))
    defer bvh_destroy(&bvh)
    visited:[3]u32
    count:=0
    r:=bvh_ray(&bvh,{-5,0.5,0.5},{40,0,0},1)
    for primitives in bvh_ray_next(&r) {visited[count]=primitives[0];count+=1}
    testing.expect_value(t,count,3)
    testing.expect_value(t,visited,[3]u32{0,1,2})
    count=0
    r=bvh_ray(&bvh,{25,0.5,0.5},{-40,0,0},1)
    for primitives in bvh_ray_next(&r) {visited[count]=primitives[0];count+=1}
    testing.expect_value(t,visited,[3]u32{2,1,0})
    // A hit on the first leaf shortens the segment: nothing behind it is reported.
    r=bvh_ray(&bvh,{-5,0.5,0.5},{40,0,0},1)
    primitives,ok:=bvh_ray_next(&r)
    testing.expect(t,ok&&primitives[0]==0)
    r.max_fraction=0.2
    _,ok=bvh_ray_next(&r)
    testing.expect(t,!ok)
    s:=bvh_sweep(&bvh,{{24,0,0},{25,1,1}},{-40,0,0},1)
    primitives,ok=bvh_sweep_next(&s)
    testing.expect(t,ok&&primitives[0]==2)
    s.max_fraction=0.4
    primitives,ok=bvh_sweep_next(&s)
    testing.expect(t,ok&&primitives[0]==1)
    _,ok=bvh_sweep_next(&s)
    testing.expect(t,!ok)
}

@(test)
bvh_build_is_deterministic :: proc(t:^testing.T) {
    defer free_all(context.temp_allocator)
    random:=random_make(71)
    boxes:=make([]Aabb,2000)
    defer delete(boxes)
    for &box in boxes {box=random_box(&random,30,2)}
    a,b:Bvh
    testing.expect(t,bvh_build(&a,boxes,{})&&bvh_build(&b,boxes,{}))
    defer bvh_destroy(&a)
    defer bvh_destroy(&b)
    testing.expect(t,len(a.nodes)>0&&raw_data(a.nodes)!=raw_data(b.nodes))
    testing.expect(t,mem.compare(slice.to_bytes(a.nodes),slice.to_bytes(b.nodes))==0)
    testing.expect(t,slice.equal(a.order,b.order))
}

@(test)
bvh_depth_never_exceeds_the_iterator_stack :: proc(t:^testing.T) {
    defer free_all(context.temp_allocator)
    // Sizes and positions in geometric progression make every split peel off a few primitives.
    COUNT :: 400
    boxes:[COUNT]Aabb
    position:=f32(1e-6)
    for &box in boxes {
        box={{position,position*0.5,-position},{position*1.01,position,position}}
        position*=1.09
    }
    scratch:=boxes
    free_form:Bvh
    testing.expect(t,bvh_build_boxes(&free_form,scratch[:],{max_leaf_size=1}))
    defer bvh_destroy(&free_form)
    testing.expect(t,bvh_validate(&free_form))
    testing.expect(t,bvh_depth(&free_form)>24&&bvh_depth(&free_form)<=BVH_STACK_CAPACITY)
    // The same input under a tighter limit: past it the build halves the ranges.
    scratch=boxes
    limited:Bvh
    testing.expect(t,bvh_build_boxes(&limited,scratch[:],{max_leaf_size=1,max_depth=16}))
    defer bvh_destroy(&limited)
    testing.expect(t,bvh_validate(&limited))
    testing.expect(t,order_is_a_permutation(&limited,COUNT))
    testing.expect_value(t,bvh_largest_leaf(&limited),u32(1))
    testing.expectf(t,bvh_depth(&limited)<=16,"depth %d under a limit of 16",bvh_depth(&limited))
    // A limit below what halving needs: the leaves at it hold the rest.
    shallow:Bvh
    testing.expect(t,bvh_build(&shallow,boxes[:],{max_leaf_size=1,max_depth=3}))
    defer bvh_destroy(&shallow)
    testing.expect(t,bvh_validate(&shallow)&&order_is_a_permutation(&shallow,COUNT))
    testing.expect(t,bvh_depth(&shallow)==3&&bvh_largest_leaf(&shallow)>1)
    random:=random_make(81)
    failures:=0
    for _ in 0..<200 {
        // Queries concentrated where the primitives are.
        reach:=position*random_f32(&random,0.001,1)
        for kind in Expectation {
            if !bvh_agrees(&limited,boxes[:],&random,reach,kind,true) {failures+=1}
            if !bvh_agrees(&free_form,boxes[:],&random,reach,kind,true) {failures+=1}
        }
        free_all(context.temp_allocator)
    }
    testing.expect_value(t,failures,0)
}

@(test)
bvh_validate_detects_a_broken_structure :: proc(t:^testing.T) {
    defer free_all(context.temp_allocator)
    random:=random_make(91)
    boxes:[40]Aabb
    for &box in boxes {box=random_box(&random,10,1)}
    broken :: proc(boxes:[]Aabb, edit:proc(bvh:^Bvh)) -> bool {
        bvh:Bvh
        if !bvh_build(&bvh,boxes,{max_leaf_size=2})||!bvh_validate(&bvh) {return false}
        defer bvh_destroy(&bvh)
        nodes,order:=bvh.nodes,bvh.order
        edit(&bvh)
        invalid:=!bvh_validate(&bvh)
        bvh.nodes=nodes;bvh.order=order
        return invalid
    }
    leaf :: proc(bvh:^Bvh) -> ^Bvh_Node {
        for &node in bvh.nodes {
            if node.count>0 {return &node}
        }
        return nil
    }
    testing.expect(t,broken(boxes[:],proc(bvh:^Bvh) {bvh.nodes[0].first=0}))
    testing.expect(t,broken(boxes[:],proc(bvh:^Bvh) {bvh.nodes[0].first=1}))
    testing.expect(t,broken(boxes[:],proc(bvh:^Bvh) {bvh.nodes[0].first=u32(len(bvh.nodes))-1}))
    testing.expect(t,broken(boxes[:],proc(bvh:^Bvh) {bvh.nodes[2].max.x=bvh.nodes[0].max.x+1}))
    testing.expect(t,broken(boxes[:],proc(bvh:^Bvh) {leaf(bvh).count+=1}))
    testing.expect(t,broken(boxes[:],proc(bvh:^Bvh) {leaf(bvh).first+=1}))
    testing.expect(t,broken(boxes[:],proc(bvh:^Bvh) {bvh.order[5]=40}))
    testing.expect(t,broken(boxes[:],proc(bvh:^Bvh) {bvh.order=bvh.order[:39]}))
    testing.expect(t,broken(boxes[:],proc(bvh:^Bvh) {bvh.nodes=nil}))
    // A chain as deep as the stack of an iterator: each interior node has the next one and a leaf.
    // Every iterator still reaches all of it; one level more is rejected.
    DEPTH :: BVH_STACK_CAPACITY
    chain:[2*DEPTH+2]Bvh_Node
    order:[DEPTH+1]u32
    for depth in 0..<DEPTH {
        chain[2*depth]={first=u32(2*depth+2)}
        chain[2*depth+3]={first=u32(DEPTH-depth),count=1}
    }
    chain[2*DEPTH]={first=0,count=1}
    for &primitive,i in order {primitive=u32(i)}
    deep:=Bvh{nodes=chain[:],order=order[:]}
    testing.expect(t,bvh_validate(&deep))
    found:[3]int
    q:=bvh_query(&deep,{})
    for primitives in bvh_query_next(&q) {found[0]+=len(primitives)}
    r:=bvh_ray(&deep,{},{0,1,0},1)
    for primitives in bvh_ray_next(&r) {found[1]+=len(primitives)}
    s:=bvh_sweep(&deep,{},{0,1,0},1)
    for primitives in bvh_sweep_next(&s) {found[2]+=len(primitives)}
    testing.expect_value(t,found,[3]int{DEPTH+1,DEPTH+1,DEPTH+1})
    chain[2*DEPTH]={first=u32(2*DEPTH+2)}
    testing.expect(t,!bvh_validate(&deep))
}
