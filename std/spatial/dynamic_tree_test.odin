package spatial

import "core:mem"
import "core:slice"
import "core:testing"
import math "mirai:std/math"

@(private="file") MODEL_CAPACITY :: 384

// A tree next to the plain list of what it should hold; the user value of a proxy is its slot.
@(private="file") Model :: struct {tree:Dynamic_Tree, random:Random, boxes:[MODEL_CAPACITY]Aabb, proxies:[MODEL_CAPACITY]i32, live:[MODEL_CAPACITY]bool, count:int}

@(private="file") model_init :: proc(m:^Model, seed:u64, margin:f32=0) -> bool {
    m.random=random_make(seed)
    return dynamic_tree_init(&m.tree,{proxy_capacity=MODEL_CAPACITY,margin=margin})
}
@(private="file") model_box :: proc(m:^Model) -> Aabb {
    // One in eight boxes has no volume.
    return random_box(&m.random,20,random_int(&m.random,8)==0?0:3)
}
// One random insertion, removal or move.
@(private="file") model_step :: proc(m:^Model) {
    slot:=random_int(&m.random,MODEL_CAPACITY)
    if !m.live[slot] {
        m.boxes[slot]=model_box(m)
        m.proxies[slot],m.live[slot]=dynamic_tree_insert(&m.tree,m.boxes[slot],u64(slot))
        m.count+=1
    } else if random_int(&m.random,3)==0 {
        dynamic_tree_remove(&m.tree,m.proxies[slot])
        m.live[slot]=false
        m.count-=1
    } else {
        m.boxes[slot]=model_box(m)
        dynamic_tree_move(&m.tree,m.proxies[slot],m.boxes[slot])
    }
}
@(private="file") Expectation :: enum {Query,Ray,Sweep}
// Runs one random query of the kind through the tree and through the list: true when both agree.
@(private="file") model_agrees :: proc(m:^Model, kind:Expectation) -> bool {
    box:=random_box(&m.random,22,6)
    origin,translation:=random_vector(&m.random,-25,25),random_translation(&m.random,40)
    max_fraction:=random_f32(&m.random,0.1,1)
    seen:[MODEL_CAPACITY]bool
    found:=0
    record :: proc(m:^Model, seen:^[MODEL_CAPACITY]bool, proxy:i32, user:u64) -> bool {
        if user>=MODEL_CAPACITY||!m.live[user]||m.proxies[user]!=proxy||seen[user] {return false}
        seen[user]=true
        return true
    }
    switch kind {
    case .Query:
        q:=dynamic_tree_query(&m.tree,box)
        for proxy,user in tree_query_next(&q) {
            if !record(m,&seen,proxy,user) {return false}
            found+=1
        }
    case .Ray:
        r:=dynamic_tree_ray(&m.tree,origin,translation,max_fraction)
        for proxy,user in tree_ray_next(&r) {
            if !record(m,&seen,proxy,user) {return false}
            found+=1
        }
    case .Sweep:
        s:=dynamic_tree_sweep(&m.tree,box,translation,max_fraction)
        for proxy,user in tree_sweep_next(&s) {
            if !record(m,&seen,proxy,user) {return false}
            found+=1
        }
    }
    for slot in 0..<MODEL_CAPACITY {
        if !m.live[slot] {continue}
        expected:bool
        switch kind {
        case .Query: expected=math.aabb_overlaps(m.boxes[slot],box)
        case .Ray: _,expected=aabb_ray(m.boxes[slot],origin,translation,max_fraction)
        case .Sweep: _,expected=aabb_sweep(m.boxes[slot],box,translation,max_fraction)
        }
        if expected!=seen[slot] {return false}
        if expected {found-=1}
    }
    return found==0
}
@(private="file") tree_bytes :: proc(tree:^Dynamic_Tree) -> []byte {return slice.to_bytes(tree.nodes[:tree.node_high])}
@(private="file") trees_equal :: proc(a,b:^Dynamic_Tree) -> bool {
    return a.root==b.root&&a.free_list==b.free_list&&a.node_high==b.node_high&&a.proxy_count==b.proxy_count&&a.placed==b.placed&&
        mem.compare(tree_bytes(a),tree_bytes(b))==0
}

@(test)
dynamic_tree_init_reserves_every_node_once :: proc(t:^testing.T) {
    tree:Dynamic_Tree
    testing.expect(t,dynamic_tree_init(&tree,{proxy_capacity=10,margin=0.25}))
    defer dynamic_tree_destroy(&tree)
    testing.expect_value(t,len(tree.nodes),19)
    testing.expect_value(t,tree.root,NULL_NODE)
    testing.expect_value(t,tree.free_list,NULL_NODE)
    testing.expect_value(t,tree.margin,f32(0.25))
    testing.expect_value(t,dynamic_tree_height(&tree),0)
    testing.expect_value(t,dynamic_tree_area_ratio(&tree),f32(0))
    testing.expect(t,dynamic_tree_validate(&tree))
}

@(test)
dynamic_tree_init_fails_without_capacity_or_memory :: proc(t:^testing.T) {
    tree:Dynamic_Tree
    testing.expect(t,!dynamic_tree_init(&tree,{proxy_capacity=0}))
    testing.expect(t,!dynamic_tree_init(&tree,{proxy_capacity=-4}))
    buffer:[256]byte
    arena:mem.Arena
    mem.arena_init(&arena,buffer[:])
    testing.expect(t,!dynamic_tree_init(&tree,{proxy_capacity=1000,allocator=mem.arena_allocator(&arena)}))
    testing.expect_value(t,len(tree.nodes),0)
    // A tree that was never initialized holds nothing and refuses proxies.
    _,ok:=dynamic_tree_insert(&tree,{},0)
    testing.expect(t,!ok)
    q:=dynamic_tree_query(&tree,{{-1,-1,-1},{1,1,1}})
    _,_,found:=tree_query_next(&q)
    testing.expect(t,!found)
    dynamic_tree_destroy(&tree)
}

@(test)
dynamic_tree_stores_the_box_and_user_of_a_proxy_exactly :: proc(t:^testing.T) {
    tree:Dynamic_Tree
    testing.expect(t,dynamic_tree_init(&tree,{proxy_capacity=8,margin=0.5}))
    defer dynamic_tree_destroy(&tree)
    a,b:=Aabb{{0,0,0},{1,2,3}},Aabb{{5,5,5},{5,5,5}}
    first,first_ok:=dynamic_tree_insert(&tree,a,41)
    second,second_ok:=dynamic_tree_insert(&tree,b,max(u64))
    testing.expect(t,first_ok&&second_ok&&first!=second)
    testing.expect_value(t,dynamic_tree_aabb(&tree,first),a)
    testing.expect_value(t,dynamic_tree_aabb(&tree,second),b)
    testing.expect_value(t,dynamic_tree_user(&tree,first),u64(41))
    testing.expect_value(t,dynamic_tree_user(&tree,second),max(u64))
    dynamic_tree_set_user(&tree,first,7)
    testing.expect_value(t,dynamic_tree_user(&tree,first),u64(7))
    testing.expect_value(t,tree.proxy_count,i32(2))
    testing.expect_value(t,dynamic_tree_height(&tree),1)
    testing.expect_value(t,tree.nodes[tree.root].aabb,math.aabb_merge(a,b))
    testing.expect(t,dynamic_tree_validate(&tree))
}

@(test)
dynamic_tree_insert_fails_and_counts_when_the_capacity_is_exhausted :: proc(t:^testing.T) {
    tree:Dynamic_Tree
    testing.expect(t,dynamic_tree_init(&tree,{proxy_capacity=5}))
    defer dynamic_tree_destroy(&tree)
    random:=random_make(3)
    proxies:[5]i32
    for &proxy in proxies {
        ok:bool
        proxy,ok=dynamic_tree_insert(&tree,random_box(&random,10,1),0)
        testing.expect(t,ok)
    }
    testing.expect_value(t,tree.node_high,i32(9))
    testing.expect_value(t,tree.stats.insert_failures,u64(0))
    for _ in 0..<3 {
        proxy,ok:=dynamic_tree_insert(&tree,random_box(&random,10,1),0)
        testing.expect(t,!ok)
        testing.expect_value(t,proxy,NULL_NODE)
    }
    testing.expect_value(t,tree.stats.insert_failures,u64(3))
    testing.expect_value(t,tree.proxy_count,i32(5))
    testing.expect(t,dynamic_tree_validate(&tree))
    dynamic_tree_remove(&tree,proxies[2])
    _,ok:=dynamic_tree_insert(&tree,random_box(&random,10,1),0)
    testing.expect(t,ok)
    testing.expect(t,dynamic_tree_validate(&tree))
}

@(test)
dynamic_tree_reuses_the_nodes_of_removed_proxies :: proc(t:^testing.T) {
    tree:Dynamic_Tree
    testing.expect(t,dynamic_tree_init(&tree,{proxy_capacity=64}))
    defer dynamic_tree_destroy(&tree)
    random:=random_make(5)
    proxies:[32]i32
    for &proxy in proxies {proxy,_=dynamic_tree_insert(&tree,random_box(&random,10,1),1)}
    high:=tree.node_high
    testing.expect_value(t,high,i32(63))
    // The free list is last in, first out: the leaf freed last is the first one handed out.
    dynamic_tree_remove(&tree,proxies[9])
    testing.expect_value(t,tree.free_list,proxies[9])
    again,_:=dynamic_tree_insert(&tree,random_box(&random,10,1),2)
    testing.expect_value(t,again,proxies[9])
    testing.expect_value(t,tree.free_list,NULL_NODE)
    for round in 0..<20 {
        for proxy,i in proxies {
            if (i+round)%3==0 {dynamic_tree_remove(&tree,proxy)}
        }
        testing.expect(t,dynamic_tree_validate(&tree))
        for &proxy,i in proxies {
            if (i+round)%3==0 {proxy,_=dynamic_tree_insert(&tree,random_box(&random,10,1),3)}
        }
        testing.expect(t,dynamic_tree_validate(&tree))
    }
    testing.expect_value(t,tree.node_high,high)
    testing.expect_value(t,tree.proxy_count,i32(32))
    for proxy in proxies {dynamic_tree_remove(&tree,proxy)}
    testing.expect_value(t,tree.root,NULL_NODE)
    testing.expect_value(t,tree.proxy_count,i32(0))
    testing.expect(t,dynamic_tree_validate(&tree))
}

@(test)
dynamic_tree_clear_forgets_every_proxy_and_node :: proc(t:^testing.T) {
    tree:Dynamic_Tree
    testing.expect(t,dynamic_tree_init(&tree,{proxy_capacity=16}))
    defer dynamic_tree_destroy(&tree)
    random:=random_make(8)
    for i in 0..<16 {dynamic_tree_insert(&tree,random_box(&random,10,1),u64(i))}
    dynamic_tree_clear(&tree)
    testing.expect_value(t,tree.proxy_count,i32(0))
    testing.expect_value(t,tree.node_high,i32(0))
    testing.expect(t,dynamic_tree_validate(&tree))
    q:=dynamic_tree_query(&tree,{{-100,-100,-100},{100,100,100}})
    _,_,found:=tree_query_next(&q)
    testing.expect(t,!found)
    for i in 0..<16 {
        _,ok:=dynamic_tree_insert(&tree,random_box(&random,10,1),u64(i))
        testing.expect(t,ok)
    }
    testing.expect(t,dynamic_tree_validate(&tree))
}

@(test)
dynamic_tree_move_stores_exactly_the_given_box :: proc(t:^testing.T) {
    tree:Dynamic_Tree
    testing.expect(t,dynamic_tree_init(&tree,{proxy_capacity=32,margin=1}))
    defer dynamic_tree_destroy(&tree)
    random:=random_make(13)
    proxies:[32]i32
    for &proxy,i in proxies {proxy,_=dynamic_tree_insert(&tree,random_box(&random,10,1),u64(i))}
    for proxy,i in proxies {
        box:=random_box(&random,30,2)
        dynamic_tree_move(&tree,proxy,box)
        testing.expect_value(t,dynamic_tree_aabb(&tree,proxy),box)
        testing.expect_value(t,dynamic_tree_user(&tree,proxy),u64(i))
    }
    testing.expect_value(t,tree.proxy_count,i32(32))
    testing.expect(t,dynamic_tree_validate(&tree))
    // A lone proxy is the root and moves in place.
    lone:Dynamic_Tree
    testing.expect(t,dynamic_tree_init(&lone,{proxy_capacity=1}))
    defer dynamic_tree_destroy(&lone)
    proxy,_:=dynamic_tree_insert(&lone,{{0,0,0},{1,1,1}},9)
    dynamic_tree_move(&lone,proxy,{{4,4,4},{5,5,5}})
    testing.expect_value(t,lone.root,proxy)
    testing.expect_value(t,dynamic_tree_aabb(&lone,proxy),Aabb{{4,4,4},{5,5,5}})
    testing.expect(t,dynamic_tree_validate(&lone))
}

@(test)
dynamic_tree_update_keeps_the_fat_box_until_the_tight_one_leaves_it :: proc(t:^testing.T) {
    tree:Dynamic_Tree
    testing.expect(t,dynamic_tree_init(&tree,{proxy_capacity=4,margin=0.5}))
    defer dynamic_tree_destroy(&tree)
    tight:=Aabb{{0,0,0},{1,1,1}}
    proxy,_:=dynamic_tree_insert(&tree,tight,0)
    dynamic_tree_insert(&tree,{{8,8,8},{9,9,9}},1)
    // Insertion stores the tight box, so the first update that leaves it fattens the proxy.
    testing.expect(t,!dynamic_tree_update(&tree,proxy,tight))
    tight={{0.25,0,0},{1.25,1,1}}
    testing.expect(t,dynamic_tree_update(&tree,proxy,tight))
    fat:=Aabb{{-0.25,-0.5,-0.5},{1.75,1.5,1.5}}
    testing.expect_value(t,dynamic_tree_aabb(&tree,proxy),fat)
    for step in 1..=4 {
        tight={{0.25+f32(step)*0.125,0,0},{1.25+f32(step)*0.125,1,1}}
        testing.expect(t,!dynamic_tree_update(&tree,proxy,tight))
        testing.expect_value(t,dynamic_tree_aabb(&tree,proxy),fat)
    }
    // The displacement stretches the new box only on the side it points to.
    tight={{2,0,0},{3,1,1}}
    testing.expect(t,dynamic_tree_update(&tree,proxy,tight,{3,-1,0}))
    testing.expect_value(t,dynamic_tree_aabb(&tree,proxy),Aabb{{1.5,-1.5,-0.5},{6.5,1.5,1.5}})
    testing.expect(t,dynamic_tree_validate(&tree))
}

@(test)
dynamic_tree_iterators_find_nothing_in_an_empty_tree :: proc(t:^testing.T) {
    tree:Dynamic_Tree
    testing.expect(t,dynamic_tree_init(&tree,{proxy_capacity=4}))
    defer dynamic_tree_destroy(&tree)
    q:=dynamic_tree_query(&tree,{{-1,-1,-1},{1,1,1}})
    r:=dynamic_tree_ray(&tree,{0,0,0},{1,0,0},1)
    s:=dynamic_tree_sweep(&tree,{{-1,-1,-1},{1,1,1}},{1,0,0},1)
    for _ in 0..<2 {
        proxy,_,ok:=tree_query_next(&q)
        testing.expect(t,!ok&&proxy==NULL_NODE)
        proxy,_,ok=tree_ray_next(&r)
        testing.expect(t,!ok&&proxy==NULL_NODE)
        proxy,_,ok=tree_sweep_next(&s)
        testing.expect(t,!ok&&proxy==NULL_NODE)
    }
}

@(test)
dynamic_tree_iterators_report_a_lone_proxy_once :: proc(t:^testing.T) {
    tree:Dynamic_Tree
    testing.expect(t,dynamic_tree_init(&tree,{proxy_capacity=4}))
    defer dynamic_tree_destroy(&tree)
    proxy,_:=dynamic_tree_insert(&tree,{{0,0,0},{1,1,1}},77)
    q:=dynamic_tree_query(&tree,{{0.5,0.5,0.5},{3,3,3}})
    found,user,ok:=tree_query_next(&q)
    testing.expect(t,ok&&found==proxy&&user==77)
    _,_,ok=tree_query_next(&q)
    testing.expect(t,!ok)
    r:=dynamic_tree_ray(&tree,{-1,0.5,0.5},{4,0,0},1)
    found,user,ok=tree_ray_next(&r)
    testing.expect(t,ok&&found==proxy&&user==77)
    _,_,ok=tree_ray_next(&r)
    testing.expect(t,!ok)
    s:=dynamic_tree_sweep(&tree,{{-3,0,0},{-2,1,1}},{4,0,0},1)
    found,user,ok=tree_sweep_next(&s)
    testing.expect(t,ok&&found==proxy&&user==77)
    _,_,ok=tree_sweep_next(&s)
    testing.expect(t,!ok)
    q=dynamic_tree_query(&tree,{{2,2,2},{3,3,3}})
    _,_,ok=tree_query_next(&q)
    testing.expect(t,!ok)
    r=dynamic_tree_ray(&tree,{-1,0.5,0.5},{-4,0,0},1)
    _,_,ok=tree_ray_next(&r)
    testing.expect(t,!ok)
}

@(test)
dynamic_tree_query_matches_brute_force_through_random_edits :: proc(t:^testing.T) {
    m:Model
    testing.expect(t,model_init(&m,101))
    defer dynamic_tree_destroy(&m.tree)
    failures:=0
    for _ in 0..<6000 {
        model_step(&m)
        if !model_agrees(&m,.Query) {failures+=1}
    }
    testing.expect_value(t,failures,0)
    testing.expect_value(t,int(m.tree.proxy_count),m.count)
    testing.expect(t,dynamic_tree_validate(&m.tree))
}

@(test)
dynamic_tree_ray_matches_brute_force_through_random_edits :: proc(t:^testing.T) {
    m:Model
    testing.expect(t,model_init(&m,202))
    defer dynamic_tree_destroy(&m.tree)
    failures:=0
    for _ in 0..<6000 {
        model_step(&m)
        if !model_agrees(&m,.Ray) {failures+=1}
    }
    testing.expect_value(t,failures,0)
}

@(test)
dynamic_tree_sweep_matches_brute_force_through_random_edits :: proc(t:^testing.T) {
    m:Model
    testing.expect(t,model_init(&m,303))
    defer dynamic_tree_destroy(&m.tree)
    failures:=0
    for _ in 0..<6000 {
        model_step(&m)
        if !model_agrees(&m,.Sweep) {failures+=1}
    }
    testing.expect_value(t,failures,0)
}

@(test)
dynamic_tree_ray_enters_the_nearer_child_first_and_clips_to_a_lowered_fraction :: proc(t:^testing.T) {
    tree:Dynamic_Tree
    testing.expect(t,dynamic_tree_init(&tree,{proxy_capacity=4}))
    defer dynamic_tree_destroy(&tree)
    near,_:=dynamic_tree_insert(&tree,{{0,0,0},{1,1,1}},0)
    far,_:=dynamic_tree_insert(&tree,{{10,0,0},{11,1,1}},1)
    r:=dynamic_tree_ray(&tree,{-5,0.5,0.5},{20,0,0},1)
    proxy,_,ok:=tree_ray_next(&r)
    testing.expect(t,ok&&proxy==near)
    proxy,_,ok=tree_ray_next(&r)
    testing.expect(t,ok&&proxy==far)
    _,_,ok=tree_ray_next(&r)
    testing.expect(t,!ok)
    r=dynamic_tree_ray(&tree,{15,0.5,0.5},{-20,0,0},1)
    proxy,_,ok=tree_ray_next(&r)
    testing.expect(t,ok&&proxy==far)
    proxy,_,ok=tree_ray_next(&r)
    testing.expect(t,ok&&proxy==near)
    // A hit on the first leaf shortens the segment: the pending leaf is never reported.
    r=dynamic_tree_ray(&tree,{-5,0.5,0.5},{20,0,0},1)
    proxy,_,ok=tree_ray_next(&r)
    testing.expect(t,ok&&proxy==near)
    r.max_fraction=0.3
    _,_,ok=tree_ray_next(&r)
    testing.expect(t,!ok)
    s:=dynamic_tree_sweep(&tree,{{14,0,0},{15,1,1}},{-20,0,0},1)
    proxy,_,ok=tree_sweep_next(&s)
    testing.expect(t,ok&&proxy==far)
    s.max_fraction=0.2
    _,_,ok=tree_sweep_next(&s)
    testing.expect(t,!ok)
}

@(test)
dynamic_tree_stays_valid_and_shallow_through_thousands_of_random_edits :: proc(t:^testing.T) {
    m:Model
    testing.expect(t,model_init(&m,404))
    defer dynamic_tree_destroy(&m.tree)
    invalid,highest:=0,0
    for _ in 0..<20000 {
        model_step(&m)
        if !dynamic_tree_validate(&m.tree) {invalid+=1}
        highest=max(highest,dynamic_tree_height(&m.tree))
    }
    testing.expect_value(t,invalid,0)
    testing.expectf(t,highest<=20,"height reached %d with at most %d proxies",highest,MODEL_CAPACITY)
    ratio:=dynamic_tree_area_ratio(&m.tree)
    testing.expectf(t,ratio>1&&ratio<40,"area ratio %f",ratio)
}

@(test)
dynamic_tree_stays_shallow_after_sorted_insertion :: proc(t:^testing.T) {
    COUNT :: 8192
    tree:Dynamic_Tree
    testing.expect(t,dynamic_tree_init(&tree,{proxy_capacity=COUNT}))
    defer dynamic_tree_destroy(&tree)
    // A row of boxes in order turns a tree without rotations into a list.
    for i in 0..<COUNT {
        x:=f32(i)*1.5
        dynamic_tree_insert(&tree,{{x,0,0},{x+1,1,1}},u64(i))
    }
    testing.expect(t,dynamic_tree_validate(&tree))
    testing.expectf(t,dynamic_tree_height(&tree)<=26,"height %d for %d sorted boxes",dynamic_tree_height(&tree),COUNT)
    // The same row on a diagonal, inserted from the far end.
    dynamic_tree_clear(&tree)
    for i:=COUNT-1;i>=0;i-=1 {
        x:=f32(i)*1.5
        dynamic_tree_insert(&tree,{{x,x,x},{x+1,x+1,x+1}},u64(i))
    }
    testing.expect(t,dynamic_tree_validate(&tree))
    testing.expectf(t,dynamic_tree_height(&tree)<=26,"height %d for %d sorted boxes on a diagonal",dynamic_tree_height(&tree),COUNT)
}

// A level of 10k boxes inserted in the order it was authored, row by row: the rebuild keeps every proxy
// with its box and user, bounds less area, and gives the same tree for the same leaves.
@(test)
dynamic_tree_rebuild_lowers_the_area_of_a_level_and_keeps_every_proxy :: proc(t:^testing.T) {
    SIDE :: 100
    trees:[2]Dynamic_Tree
    for &tree in trees {testing.expect(t,dynamic_tree_init(&tree,{proxy_capacity=SIDE*SIDE}))}
    defer for &tree in trees {dynamic_tree_destroy(&tree)}
    random:=random_make(13)
    boxes:=make([]Aabb,SIDE*SIDE)
    defer delete(boxes)
    for &box,i in boxes {
        corner:=[3]f32{f32(i%SIDE)*4,random_f32(&random,0,2),f32(i/SIDE)*4}
        box={corner,corner+random_vector(&random,0.5,3.5)}
        for &tree in trees {dynamic_tree_insert(&tree,box,u64(i))}
    }
    before:=dynamic_tree_area_ratio(&trees[0])
    testing.expect_value(t,trees[0].placed,SIDE*SIDE)
    testing.expect(t,dynamic_tree_rebuild(&trees[0]))
    testing.expect_value(t,trees[0].placed,0)
    testing.expect(t,dynamic_tree_validate(&trees[0]))
    after:=dynamic_tree_area_ratio(&trees[0])
    testing.expectf(t,after<0.9*before,"area ratio %f after the rebuild, %f before",after,before)
    kept:=0
    for &node,proxy in trees[0].nodes[:trees[0].node_high] {
        if node.height==0 && node.child1==NULL_NODE && node.user<SIDE*SIDE && node.aabb==boxes[node.user] && dynamic_tree_user(&trees[0],i32(proxy))==node.user {kept+=1}
    }
    testing.expect_value(t,kept,SIDE*SIDE)
    testing.expect(t,dynamic_tree_rebuild(&trees[1]))
    testing.expect(t,trees_equal(&trees[0],&trees[1]))
}

// A box that is not finite or a temporary allocator without room leave the tree as it was; after a
// rebuild what it finds is what it holds, and edits go on.
@(test)
dynamic_tree_rebuild_refuses_hostile_boxes_and_lack_of_memory :: proc(t:^testing.T) {
    m:Model
    testing.expect(t,model_init(&m,909))
    defer dynamic_tree_destroy(&m.tree)
    for _ in 0..<3000 {model_step(&m)}
    nan:=transmute(f32)u32(0x7fc00000)
    copied:=make([]byte,len(tree_bytes(&m.tree)))
    defer delete(copied)
    hostile,_:=dynamic_tree_insert(&m.tree,{{nan,0,0},{1,1,1}},MODEL_CAPACITY)
    copy(copied,tree_bytes(&m.tree))
    testing.expect(t,!dynamic_tree_rebuild(&m.tree))
    testing.expect(t,mem.compare(copied,tree_bytes(&m.tree))==0)
    dynamic_tree_remove(&m.tree,hostile)
    copy(copied,tree_bytes(&m.tree))
    buffer:[64]byte
    arena:mem.Arena
    mem.arena_init(&arena,buffer[:])
    temp:=context.temp_allocator
    context.temp_allocator=mem.arena_allocator(&arena)
    testing.expect(t,!dynamic_tree_rebuild(&m.tree))
    context.temp_allocator=temp
    testing.expect(t,mem.compare(copied,tree_bytes(&m.tree))==0)
    testing.expect(t,dynamic_tree_rebuild(&m.tree))
    testing.expect(t,dynamic_tree_validate(&m.tree))
    disagreed:=0
    for round in 0..<300 {
        if round%3==0 {model_step(&m)}
        for kind in Expectation {disagreed+=int(!model_agrees(&m,kind))}
    }
    testing.expect_value(t,disagreed,0)
    testing.expect(t,dynamic_tree_validate(&m.tree))
}

@(test)
dynamic_tree_iterators_cross_a_chain_deeper_than_their_stack :: proc(t:^testing.T) {
    COUNT :: 300
    tree:Dynamic_Tree
    testing.expect(t,dynamic_tree_init(&tree,{proxy_capacity=COUNT}))
    defer dynamic_tree_destroy(&tree)
    // Each box holds every earlier one, so each new leaf pairs with the whole tree: a chain.
    boxes:[COUNT]Aabb
    for &box,i in boxes {
        half:=1+f32(i)*0.25
        box={{-half,-half,-half},{half,half*0.5,half*2}}
        dynamic_tree_insert(&tree,box,u64(i))
    }
    testing.expect(t,dynamic_tree_validate(&tree))
    testing.expect(t,dynamic_tree_height(&tree)>2*TREE_STACK_CAPACITY)
    random:=random_make(606)
    failures:=0
    for round in 0..<600 {
        box:=random_box(&random,60,round%2==0?0.5:30)
        origin:=round%3==0?random_vector(&random,-1,1):random_vector(&random,-90,90)
        translation:=random_translation(&random,120)
        seen:[3][COUNT]bool
        q:=dynamic_tree_query(&tree,box)
        for _,user in tree_query_next(&q) {
            if seen[0][user] {failures+=1}
            seen[0][user]=true
        }
        r:=dynamic_tree_ray(&tree,origin,translation,1)
        for _,user in tree_ray_next(&r) {
            if seen[1][user] {failures+=1}
            seen[1][user]=true
        }
        s:=dynamic_tree_sweep(&tree,box,translation,1)
        for _,user in tree_sweep_next(&s) {
            if seen[2][user] {failures+=1}
            seen[2][user]=true
        }
        for other,i in boxes {
            _,ray:=aabb_ray(other,origin,translation,1)
            _,sweep:=aabb_sweep(other,box,translation,1)
            if seen[0][i]!=math.aabb_overlaps(other,box)||seen[1][i]!=ray||seen[2][i]!=sweep {failures+=1}
        }
    }
    testing.expect_value(t,failures,0)
    // Clipping still cuts the walk short below the stack.
    r:=dynamic_tree_ray(&tree,{0,0,0},{0,0,1000},1)
    _,_,ok:=tree_ray_next(&r)
    testing.expect(t,ok)
    r.max_fraction=-1
    _,_,ok=tree_ray_next(&r)
    testing.expect(t,!ok)
}

@(test)
dynamic_tree_is_deterministic_for_a_sequence_of_operations :: proc(t:^testing.T) {
    a,b:Model
    testing.expect(t,model_init(&a,707)&&model_init(&b,707))
    defer dynamic_tree_destroy(&a.tree)
    defer dynamic_tree_destroy(&b.tree)
    for _ in 0..<5000 {model_step(&a)}
    for _ in 0..<5000 {model_step(&b)}
    testing.expect(t,a.tree.node_high>0)
    testing.expect(t,trees_equal(&a.tree,&b.tree))
    // The trees do not share memory, so equal bytes mean nothing depends on an address.
    testing.expect(t,raw_data(a.tree.nodes)!=raw_data(b.tree.nodes))
    order:[2][64]i32
    for tree,i in ([2]^Dynamic_Tree{&a.tree,&b.tree}) {
        q:=dynamic_tree_query(tree,{{-8,-8,-8},{8,8,8}})
        count:=0
        for proxy in tree_query_next(&q) {
            if count<64 {order[i][count]=proxy}
            count+=1
        }
        testing.expect(t,count>0)
    }
    testing.expect_value(t,order[0],order[1])
}

// A tree that only takes copies of another and gives them back: what did not change is not copied, and
// what follows a copy back repeats.
@(test)
dynamic_tree_copy_takes_only_what_changed_and_what_follows_repeats :: proc(t:^testing.T) {
    m:Model
    testing.expect(t,model_init(&m,808))
    defer dynamic_tree_destroy(&m.tree)
    for _ in 0..<3000 {model_step(&m)}
    kept,later:Dynamic_Tree
    testing.expect(t,dynamic_tree_init(&kept,{proxy_capacity=MODEL_CAPACITY})&&dynamic_tree_init(&later,{proxy_capacity=MODEL_CAPACITY}))
    defer dynamic_tree_destroy(&kept)
    defer dynamic_tree_destroy(&later)
    stale,_:=dynamic_tree_insert(&kept,{{0,0,0},{1,1,1}},0)
    dynamic_tree_insert(&kept,{{2,2,2},{3,3,3}},0)
    dynamic_tree_remove(&kept,stale)
    written,ok:=dynamic_tree_copy(&kept,&m.tree,true)
    testing.expect(t,ok&&written>=len(tree_bytes(&m.tree)))
    testing.expect(t,trees_equal(&m.tree,&kept)&&dynamic_tree_validate(&kept))
    written,_=dynamic_tree_copy(&kept,&m.tree,false)
    testing.expect_value(t,written,0)
    saved:=new_clone(m)
    defer free(saved)
    for _ in 0..<2000 {model_step(&m)}
    _,ok=dynamic_tree_copy(&later,&m.tree,true)
    testing.expect(t,ok&&!trees_equal(&m.tree,&kept))
    // Back to the kept tree, copying what changed, the same operations rebuild the same bytes.
    _,ok=dynamic_tree_copy(&m.tree,&kept,false)
    testing.expect(t,ok&&trees_equal(&m.tree,&kept))
    tree:=m.tree
    m=saved^
    m.tree=tree
    for _ in 0..<2000 {model_step(&m)}
    testing.expect(t,trees_equal(&m.tree,&later))
    _,ok=dynamic_tree_copy(&kept,&m.tree,false)
    testing.expect(t,ok&&trees_equal(&m.tree,&kept))
    failures:=0
    for _ in 0..<200 {
        if !model_agrees(&m,.Query) {failures+=1}
    }
    testing.expect_value(t,failures,0)
    // The nodes of a tree do not fit in a smaller one, which stays as it was.
    small:Dynamic_Tree
    testing.expect(t,dynamic_tree_init(&small,{proxy_capacity=4}))
    defer dynamic_tree_destroy(&small)
    dynamic_tree_insert(&small,{{0,0,0},{1,1,1}},7)
    written,ok=dynamic_tree_copy(&small,&m.tree,true)
    testing.expect(t,!ok&&written==0&&small.proxy_count==1&&dynamic_tree_user(&small,small.root)==7)
}

@(test)
dynamic_tree_validate_detects_a_broken_structure :: proc(t:^testing.T) {
    random:=random_make(1010)
    broken :: proc(random:^Random, edit:proc(tree:^Dynamic_Tree)) -> bool {
        tree:Dynamic_Tree
        if !dynamic_tree_init(&tree,{proxy_capacity=16}) {return false}
        defer dynamic_tree_destroy(&tree)
        proxies:[12]i32
        for &proxy,i in proxies {proxy,_=dynamic_tree_insert(&tree,random_box(random,10,1),u64(i))}
        dynamic_tree_remove(&tree,proxies[3])
        dynamic_tree_remove(&tree,proxies[8])
        if !dynamic_tree_validate(&tree) {return false}
        edit(&tree)
        return !dynamic_tree_validate(&tree)
    }
    internal :: proc(tree:^Dynamic_Tree) -> ^Tree_Node {
        for &node in tree.nodes[:tree.node_high] {
            if node.height>0&&node.parent!=NULL_NODE {return &node}
        }
        return nil
    }
    testing.expect(t,broken(&random,proc(tree:^Dynamic_Tree) {internal(tree).parent=NULL_NODE}))
    testing.expect(t,broken(&random,proc(tree:^Dynamic_Tree) {internal(tree).height+=1}))
    testing.expect(t,broken(&random,proc(tree:^Dynamic_Tree) {internal(tree).aabb.max.x+=1}))
    testing.expect(t,broken(&random,proc(tree:^Dynamic_Tree) {internal(tree).child1=internal(tree).child2}))
    testing.expect(t,broken(&random,proc(tree:^Dynamic_Tree) {internal(tree).child2=99}))
    testing.expect(t,broken(&random,proc(tree:^Dynamic_Tree) {tree.nodes[tree.root].parent=0}))
    testing.expect(t,broken(&random,proc(tree:^Dynamic_Tree) {tree.proxy_count+=1}))
    testing.expect(t,broken(&random,proc(tree:^Dynamic_Tree) {tree.root=NULL_NODE}))
    testing.expect(t,broken(&random,proc(tree:^Dynamic_Tree) {tree.free_list=NULL_NODE}))
    testing.expect(t,broken(&random,proc(tree:^Dynamic_Tree) {tree.free_list=tree.root}))
    testing.expect(t,broken(&random,proc(tree:^Dynamic_Tree) {tree.nodes[tree.free_list].parent=tree.free_list}))
    testing.expect(t,broken(&random,proc(tree:^Dynamic_Tree) {tree.nodes[tree.free_list].height=-2}))
    testing.expect(t,broken(&random,proc(tree:^Dynamic_Tree) {tree.node_high=40}))
}
