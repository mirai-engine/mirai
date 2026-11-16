package spatial

import "core:testing"
import math "mirai:std/math"

@(private="file") CAPACITY :: 256

@(private="file") Kind :: enum {Grid,Hash,Octree}

// A structure next to the plain list of what it should hold; the user value of an item is its slot.
@(private="file") Model :: struct {
    kind:Kind, grid:Grid, octree:Octree, random:Random,
    boxes:[CAPACITY]Aabb, items:[CAPACITY]i32, live:[CAPACITY]bool,
    world:f32,
}

@(private="file") model_init :: proc(m:^Model, kind:Kind, seed:u64) -> bool {
    m.kind,m.random,m.world=kind,random_make(seed),20
    bounds:=Aabb{{-24,-24,-24},{24,24,24}}
    switch kind {
    case .Grid: return grid_init(&m.grid,{cell_size=4,bounds=bounds,item_capacity=CAPACITY,link_capacity=CAPACITY*64})
    case .Hash: return grid_init(&m.grid,{cell_size=4,buckets=200,item_capacity=CAPACITY,link_capacity=CAPACITY*64})
    case .Octree: return octree_init(&m.octree,{bounds=bounds,max_depth=6,leaf_items=4,item_capacity=CAPACITY})
    }
    return false
}
@(private="file") model_destroy :: proc(m:^Model) {
    grid_destroy(&m.grid)
    octree_destroy(&m.octree)
}
// One in eight boxes has no volume; all are inside the bounds, where a uniform grid answers rays.
@(private="file") model_box :: proc(m:^Model) -> Aabb {
    return random_box(&m.random,m.world,random_int(&m.random,8)==0?0:3)
}
// One random insertion, removal or move.
@(private="file") model_step :: proc(m:^Model) -> bool {
    slot:=random_int(&m.random,CAPACITY)
    ok:=true
    if !m.live[slot] {
        m.boxes[slot]=model_box(m)
        if m.kind==.Octree {m.items[slot],ok=octree_insert(&m.octree,m.boxes[slot],u64(slot))} else {m.items[slot],ok=grid_insert(&m.grid,m.boxes[slot],u64(slot))}
        m.live[slot]=ok
    } else if random_int(&m.random,3)==0 {
        if m.kind==.Octree {octree_remove(&m.octree,m.items[slot])} else {grid_remove(&m.grid,m.items[slot])}
        m.live[slot]=false
    } else {
        m.boxes[slot]=model_box(m)
        if m.kind==.Octree {ok=octree_move(&m.octree,m.items[slot],m.boxes[slot])} else {ok=grid_move(&m.grid,m.items[slot],m.boxes[slot])}
    }
    return ok
}
// Runs one random query or ray through the structure and through the list: true when both agree
// and no item came twice.
@(private="file") model_agrees :: proc(m:^Model, ray:bool, reach:f32) -> bool {
    box:=random_box(&m.random,m.world+2,reach)
    origin,translation:=random_vector(&m.random,-m.world,m.world),random_translation(&m.random,reach*6)
    max_fraction:=random_f32(&m.random,0.1,1)
    seen:[CAPACITY]bool
    found:=0
    record :: proc(m:^Model, seen:^[CAPACITY]bool, item:i32, user:u64) -> bool {
        if user>=CAPACITY||!m.live[user]||m.items[user]!=item||seen[user] {return false}
        seen[user]=true
        return true
    }
    switch {
    case m.kind==.Octree&&!ray:
        q:=octree_query(&m.octree,box)
        for item,user in octree_query_next(&q) {
            if !record(m,&seen,item,user) {return false}
            found+=1
        }
    case m.kind==.Octree:
        r:=octree_ray(&m.octree,origin,translation,max_fraction)
        for item,user in octree_ray_next(&r) {
            if !record(m,&seen,item,user) {return false}
            found+=1
        }
    case !ray:
        q:=grid_query(&m.grid,box)
        for item,user in grid_query_next(&q) {
            if !record(m,&seen,item,user) {return false}
            found+=1
        }
    case:
        r:=grid_ray(&m.grid,origin,translation,max_fraction)
        for item,user in grid_ray_next(&r) {
            if !record(m,&seen,item,user) {return false}
            found+=1
        }
    }
    expected:=0
    for slot in 0..<CAPACITY {
        if !m.live[slot] {continue}
        hit:bool
        if ray {_,hit=aabb_ray(m.boxes[slot],origin,translation,max_fraction)} else {hit=math.aabb_overlaps(m.boxes[slot],box)}
        if hit!=seen[slot] {return false}
        if hit {expected+=1}
    }
    return expected==found
}

@(private="file") model_runs :: proc(t:^testing.T, kind:Kind, seed:u64) {
    m:=new(Model)
    defer free(m)
    if !testing.expect(t,model_init(m,kind,seed)) {return}
    defer model_destroy(m)
    for step in 0..<3000 {
        if !testing.expectf(t,model_step(m),"%v: step %d was refused",kind,step) {return}
        if step%16!=0 {continue}
        valid:=kind==.Octree?octree_validate(&m.octree):grid_validate(&m.grid)
        if !testing.expectf(t,valid,"%v: not valid after step %d",kind,step) {return}
        // Small volumes, and ones over more cells than a spatial hash reads cell by cell.
        for reach in ([]f32{2,6,60}) {
            if !testing.expectf(t,model_agrees(m,false,reach),"%v: a query of reach %v disagrees with the list at step %d",kind,reach,step) {return}
            if !testing.expectf(t,model_agrees(m,true,reach),"%v: a ray of reach %v disagrees with the list at step %d",kind,reach,step) {return}
        }
    }
}

@(test)
a_uniform_grid_answers_queries_and_rays_as_a_list_does :: proc(t:^testing.T) {
    model_runs(t,.Grid,11)
    model_runs(t,.Grid,12)
}

@(test)
a_spatial_hash_answers_queries_and_rays_as_a_list_does :: proc(t:^testing.T) {
    model_runs(t,.Hash,21)
    model_runs(t,.Hash,22)
}

@(test)
an_octree_answers_queries_and_rays_as_a_list_does :: proc(t:^testing.T) {
    model_runs(t,.Octree,31)
    model_runs(t,.Octree,32)
}

@(test)
a_grid_refuses_what_it_has_no_room_for_and_counts_it :: proc(t:^testing.T) {
    g:Grid
    // A structure in zero fails without touching memory.
    _,ok:=grid_insert(&g,{{0,0,0},{1,1,1}},1)
    testing.expect(t,!ok && g.stats.insert_failures==1)
    grid_remove(&g,0)
    q:=grid_query(&g,{{0,0,0},{1,1,1}})
    _,_,found:=grid_query_next(&q)
    r:=grid_ray(&g,{0,0,0},{1,0,0},1)
    _,_,hit:=grid_ray_next(&r)
    testing.expect(t,!found && !hit && grid_validate(&g))

    testing.expect(t,!grid_init(&g,{cell_size=0,buckets=16,item_capacity=4}))
    testing.expect(t,!grid_init(&g,{cell_size=1,buckets=16,item_capacity=0}))
    testing.expect(t,!grid_init(&g,{cell_size=1,bounds={{1,0,0},{0,1,1}},item_capacity=4}),"a box inside out is no bounds")
    testing.expect(t,!grid_init(&g,{cell_size=1e-6,bounds={{0,0,0},{10,10,10}},item_capacity=4}),"more cells than a grid holds")

    if !testing.expect(t,grid_init(&g,{cell_size=1,buckets=10,item_capacity=2,link_capacity=8})) {return}
    defer grid_destroy(&g)
    testing.expect_value(t,len(g.heads),16)
    a,a_ok:=grid_insert(&g,{{0.25,0.25,0.25},{0.75,0.75,0.75}},7)
    b,b_ok:=grid_insert(&g,{{5.25,0.25,0.25},{6.75,0.75,0.75}},8)
    testing.expect(t,a_ok && b_ok && g.link_count==3)
    _,ok=grid_insert(&g,{{0,0,0},{0.5,0.5,0.5}},9)
    testing.expect(t,!ok,"no item slot left")
    grid_remove(&g,b)
    grid_remove(&g,b)
    testing.expect_value(t,g.item_count,i32(1))
    _,ok=grid_insert(&g,{{0.25,0.25,0.25},{3.75,2.75,0.75}},9)
    testing.expect(t,!ok,"twelve cells do not fit in the seven links left")
    nan:=f32(0h7fc00000)
    _,ok=grid_insert(&g,{{nan,0,0},{1,1,1}},9)
    testing.expect(t,!ok)
    _,ok=grid_insert(&g,{{-1e30,-1e30,-1e30},{1e30,1e30,1e30}},9)
    testing.expect(t,!ok,"a box over more cells than can be counted")
    testing.expect_value(t,g.stats.insert_failures,u64(4))
    q=grid_query(&g,{{-1e30,-1e30,-1e30},{1e30,1e30,1e30}})
    everything,_,any:=grid_query_next(&q)
    _,_,more:=grid_query_next(&q)
    testing.expect(t,any && !more && everything==a,"a query over all of space reads the items")
    r=grid_ray(&g,{-1e6,0.5,0.5},{2e6,0,0},1)
    crossed,_,any_hit:=grid_ray_next(&r)
    testing.expect(t,any_hit && crossed==a,"and so does a segment across more cells than the hash has lists")
    testing.expect(t,!grid_move(&g,a,{{0.25,0.25,0.25},{3.75,2.75,1.75}}),"a move over more cells than there are links")
    testing.expect_value(t,grid_aabb(&g,a),Aabb{{0.25,0.25,0.25},{0.75,0.75,0.75}})
    testing.expect(t,grid_move(&g,a,{{2.25,0.25,0.25},{3.75,0.75,0.75}}) && grid_user(&g,a)==7)
    testing.expect(t,!grid_move(&g,b,{{0,0,0},{1,1,1}}),"a removed item does not move")
    grid_set_user(&g,a,70)
    q=grid_query(&g,{{3.5,0,0},{9,1,1}})
    item,user,first:=grid_query_next(&q)
    _,_,second:=grid_query_next(&q)
    testing.expect(t,first && !second && item==a && user==70)
    testing.expect(t,grid_validate(&g))
    grid_clear(&g)
    testing.expect(t,g.item_count==0 && g.link_count==0 && grid_validate(&g))
}

@(test)
a_uniform_grid_keeps_what_leaves_its_box_at_the_border :: proc(t:^testing.T) {
    g:Grid
    if !testing.expect(t,grid_init(&g,{cell_size=2,bounds={{0,0,0},{8,4,2}},item_capacity=8})) {return}
    defer grid_destroy(&g)
    testing.expect_value(t,g.dims,[3]i32{4,2,1})
    testing.expect_value(t,grid_cell(&g,{-50,3.5,100}),[3]i32{0,1,0})
    outside,ok:=grid_insert(&g,{{20,20,20},{21,21,21}},1)
    testing.expect(t,ok && g.link_count==1)
    q:=grid_query(&g,{{19,19,19},{30,30,30}})
    item,_,found:=grid_query_next(&q)
    testing.expect(t,found && item==outside,"a query that leaves the box the same way finds it")
    q=grid_query(&g,{{7,3,1},{8,4,2}})
    _,_,found=grid_query_next(&q)
    testing.expect(t,!found,"the border cell is read and the boxes do not overlap")
    r:=grid_ray(&g,{-5,10,1},{20,0,0},1)
    _,_,found=grid_ray_next(&r)
    testing.expect(t,!found,"a segment that misses the box of the grid finds nothing")
}

@(test)
a_grid_gives_the_items_of_a_ray_in_the_order_it_crosses_their_cells :: proc(t:^testing.T) {
    for hashed in ([]bool{false,true}) {
        g:Grid
        desc:=Grid_Desc{cell_size=1,item_capacity=16}
        if hashed {desc.buckets=64} else {desc.bounds={{0,0,0},{16,4,4}}}
        if !testing.expect(t,grid_init(&g,desc)) {return}
        defer grid_destroy(&g)
        for column in ([]int{9,2,13,5}) {
            x:=f32(column)
            // Each spans two cells of the path: it must still come once.
            _,ok:=grid_insert(&g,{{x+0.5,1.25,1.25},{x+1.5,1.75,1.75}},u64(column))
            testing.expect(t,ok)
        }
        r:=grid_ray(&g,{0.5,1.5,1.5},{15,0,0},1)
        order:[8]u64
        count:=0
        for _,user in grid_ray_next(&r) {
            if count<len(order) {order[count]=user}
            count+=1
        }
        testing.expect_value(t,count,4)
        testing.expect_value(t,order,[8]u64{2,5,9,13,0,0,0,0})
        // A lowered max_fraction clips what is left.
        r=grid_ray(&g,{0.5,1.5,1.5},{15,0,0},1)
        _,first,_:=grid_ray_next(&r)
        r.max_fraction=0.4
        _,second,_:=grid_ray_next(&r)
        _,_,third:=grid_ray_next(&r)
        testing.expect(t,first==2 && second==5 && !third)
    }
}

@(test)
an_octree_divides_its_leaves_and_joins_them_again :: proc(t:^testing.T) {
    o:Octree
    // A structure in zero fails without touching memory.
    _,ok:=octree_insert(&o,{{0,0,0},{1,1,1}},1)
    testing.expect(t,!ok && o.stats.insert_failures==1)
    octree_remove(&o,0)
    q:=octree_query(&o,{{0,0,0},{1,1,1}})
    _,_,found:=octree_query_next(&q)
    r:=octree_ray(&o,{0,0,0},{1,0,0},1)
    _,_,hit:=octree_ray_next(&r)
    testing.expect(t,!found && !hit && octree_validate(&o))
    testing.expect(t,!octree_init(&o,{bounds={{0,0,0},{8,8,8}},item_capacity=0}))
    testing.expect(t,!octree_init(&o,{bounds={{0,0,0},{8,8,8}},item_capacity=4,max_depth=OCTREE_MAX_DEPTH+1}))

    if !testing.expect(t,octree_init(&o,{bounds={{0,0,0},{8,4,2}},max_depth=3,leaf_items=2,item_capacity=8,node_capacity=17})) {return}
    defer octree_destroy(&o)
    testing.expect_value(t,o.half,f32(4))
    testing.expect_value(t,o.center,[3]f32{4,2,1})
    octree_destroy(&o)
    if !testing.expect(t,octree_init(&o,{bounds={{0,0,0},{8,8,8}},max_depth=3,leaf_items=2,item_capacity=8,node_capacity=17})) {return}
    items:[8]i32
    // Two small boxes at the two ends of the first octant, one in the last octant, and one of the
    // size of a cell of the second level across the center of the cube.
    boxes:=[4]Aabb{{{0.5,0.5,0.5},{1,1,1}},{{2.5,2.5,2.5},{3,3,3}},{{6,6,6},{7,7,7}},{{3,3,3},{5,5,5}}}
    for box,i in boxes {
        items[i],ok=octree_insert(&o,box,u64(i))
        testing.expect(t,ok)
    }
    // The third divided the root and the fourth its first octant: a box lies as deep as its size
    // lets it, whatever planes it is across.
    testing.expect(t,octree_validate(&o))
    testing.expect_value(t,octree_node_count(&o),17)
    testing.expect_value(t,o.items[items[0]].node,i32(9))
    testing.expect_value(t,o.items[items[1]].node,i32(16))
    testing.expect_value(t,o.items[items[2]].node,i32(8))
    testing.expect_value(t,o.items[items[3]].node,i32(16))
    testing.expect_value(t,o.nodes[1].total,i32(3))
    testing.expect_value(t,o.nodes[1].count,i32(0))
    // No nodes are left for a third level: the leaf keeps what it is given.
    for i in 4..<8 {
        items[i],ok=octree_insert(&o,{{0.3,0.3,0.3},{0.4,0.4,0.4}},u64(i))
        testing.expect(t,ok && o.items[items[i]].node==9)
    }
    testing.expect(t,o.stats.split_failures>0 && octree_validate(&o))
    _,ok=octree_insert(&o,{{0,0,0},{1,1,1}},9)
    testing.expect(t,!ok,"no item slot left")
    nan:=f32(0h7fc00000)
    testing.expect(t,!octree_move(&o,items[0],{{nan,0,0},{1,1,1}}))
    // A box with its middle outside the cube lives in the root, and is found from there.
    testing.expect(t,octree_move(&o,items[2],{{40,40,40},{41,41,41}}))
    testing.expect_value(t,o.items[items[2]].node,i32(0))
    q=octree_query(&o,{{39,39,39},{40.5,40.5,40.5}})
    item,user,first:=octree_query_next(&q)
    testing.expect(t,first && item==items[2] && user==2)
    // With one item left under it a divided node is a leaf again and its nodes are free.
    for i in 4..<8 {octree_remove(&o,items[i])}
    octree_remove(&o,items[0])
    octree_remove(&o,items[0])
    testing.expect(t,octree_validate(&o) && octree_node_count(&o)==17,"two items still hold the first octant divided")
    octree_remove(&o,items[3])
    testing.expect(t,octree_validate(&o))
    testing.expect_value(t,octree_node_count(&o),9)
    testing.expect_value(t,o.items[items[1]].node,i32(1))
    testing.expect_value(t,o.item_count,i32(2))
    octree_set_user(&o,items[1],10)
    testing.expect(t,octree_user(&o,items[1])==10 && octree_aabb(&o,items[1])==boxes[1])
    octree_remove(&o,items[2])
    testing.expect(t,octree_validate(&o) && octree_node_count(&o)==1 && o.items[items[1]].node==0,"the last item is in a root without octants")
    octree_clear(&o)
    testing.expect(t,o.item_count==0 && octree_validate(&o))
}

@(test)
grids_and_octrees_repeat_the_same_answers_for_the_same_history :: proc(t:^testing.T) {
    for kind in Kind {
        order:[2][64]i32
        counts:[2]int
        for run in 0..<2 {
            m:=new(Model)
            defer free(m)
            if !testing.expect(t,model_init(m,kind,77)) {return}
            defer model_destroy(m)
            for _ in 0..<600 {model_step(m)}
            if kind==.Octree {
                q:=octree_query(&m.octree,{{-10,-10,-10},{10,10,10}})
                for item in octree_query_next(&q) {
                    if counts[run]<64 {order[run][counts[run]]=item}
                    counts[run]+=1
                }
            } else {
                q:=grid_query(&m.grid,{{-10,-10,-10},{10,10,10}})
                for item in grid_query_next(&q) {
                    if counts[run]<64 {order[run][counts[run]]=item}
                    counts[run]+=1
                }
            }
        }
        testing.expect(t,counts[0]>0 && counts[0]==counts[1] && order[0]==order[1],"the same history gives the same items in the same order")
    }
}
