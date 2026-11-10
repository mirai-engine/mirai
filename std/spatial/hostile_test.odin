package spatial

import math "mirai:std/math"
import "mirai:std/base"
import "core:testing"

// Every public procedure is handed boxes that are NaN, infinite, huge, tiny,
// empty or inverted, handles that are stale, forged or out of range,
// capacities and cell sizes out of range, structures that are zero, and trees
// whose bytes were corrupted. What it takes leaves the structure valid, a
// query gives no more than there is, and a handle that is not live reads as
// zero and changes nothing.

@(private="file") HOSTILE_ROUNDS :: #config(SPATIAL_HOSTILE_ROUNDS,400)
@(private="file") ITERATION_LIMIT :: 100000


@(private="file")
hostile_vec3 :: proc(h:^base.Hostile,wild:bool) -> [3]f32 {
    if !wild {return {f32(base.hostile_int(h,201)-100)/50,f32(base.hostile_int(h,201)-100)/50,f32(base.hostile_int(h,201)-100)/50}}
    return {base.hostile_f32(h),base.hostile_f32(h),base.hostile_f32(h)}
}

@(private="file")
hostile_box :: proc(h:^base.Hostile) -> Aabb {
    switch base.hostile_int(h,9) {
    case 0: return {hostile_vec3(h,true),hostile_vec3(h,true)}
    case 1:
        p:=hostile_vec3(h,false)
        return {p,p}
    case 2: return {{-1e30,-1e30,-1e30},{1e30,1e30,1e30}}
    case 3: return {{-max(f32),-max(f32),-max(f32)},{max(f32),max(f32),max(f32)}}
    case 4:
        p:=hostile_vec3(h,false)
        return {p+{1,1,1},p}
    case 5:
        p:=hostile_vec3(h,false)
        return {p,p+{1e-30,1e-30,1e-30}}
    }
    c:=hostile_vec3(h,false)
    e:=hostile_vec3(h,false)
    e={abs(e.x)/4,abs(e.y)/4,abs(e.z)/4}
    return {c-e,c+e}
}

@(private="file")
hostile_valid_box :: proc(h:^base.Hostile) -> Aabb {
    c:=hostile_vec3(h,false)
    e:=hostile_vec3(h,false)
    e={abs(e.x)/4,abs(e.y)/4,abs(e.z)/4}
    return {c-e,c+e}
}

@(private="file")
hostile_handle :: proc(h:^base.Hostile,live:[]i32,high:i32) -> i32 {
    if len(live)>0 && base.hostile_int(h,3)!=0 {return live[base.hostile_int(h,len(live))]}
    switch base.hostile_int(h,10) {
    case 0: return -1
    case 1: return 0
    case 2: return 1
    case 3: return high
    case 4: return high+1
    case 5: return max(i32)
    case 6: return min(i32)
    case 7: return i32(base.hostile_int(h,max(int(high),1)))
    case 8: return -2
    }
    return 1<<30
}

@(private="file")
hostile_capacity :: proc(h:^base.Hostile) -> int {
    switch base.hostile_int(h,12) {
    case 0: return -1
    case 1: return 0
    case 2: return 1<<40
    case 3: return max(int)
    case 4: return 1
    case 5: return 2
    }
    return 4+base.hostile_int(h,60)
}

@(private="file")
hostile_cell_size :: proc(h:^base.Hostile) -> f32 {
    if base.hostile_int(h,10)<4 {return base.hostile_f32(h)}
    return f32(1+base.hostile_int(h,40))/10
}

@(private="file")
hostile_bounds :: proc(h:^base.Hostile) -> Aabb {
    switch base.hostile_int(h,6) {
    case 0: return {hostile_vec3(h,true),hostile_vec3(h,true)}
    case 1: return {}
    case 2:
        p:=hostile_vec3(h,false)
        return {p+{1,1,1},p}
    }
    e:=f32(1+base.hostile_int(h,20))
    return {{-e,-e,-e},{e,e,e}}
}

@(private="file")
hostile_grid_desc :: proc(h:^base.Hostile) -> Grid_Desc {
    desc:=Grid_Desc{cell_size=hostile_cell_size(h),item_capacity=hostile_capacity(h)}
    switch base.hostile_int(h,6) {
    case 0: desc.link_capacity=-1
    case 1: desc.link_capacity=1<<40
    case 2: desc.link_capacity=1
    case: desc.link_capacity=base.hostile_int(h,200)
    }
    if base.hostile_int(h,2)==0 {
        switch base.hostile_int(h,6) {
        case 0: desc.buckets=-1
        case 1: desc.buckets=1<<40
        case 2: desc.buckets=1
        case: desc.buckets=1+base.hostile_int(h,500)
        }
    } else {
        desc.bounds=hostile_bounds(h)
    }
    return desc
}

@(private="file")
grid_probe :: proc(t:^testing.T,g:^Grid,h:^base.Hostile) {
    n:=0
    q:=grid_query(g,hostile_box(h))
    for {
        _,_,ok:=grid_query_next(&q)
        if !ok {break}
        n+=1
        if n>int(g.item_count)||n>ITERATION_LIMIT {
            testing.expect(t,false,"grid query gives more items than there are")
            break
        }
    }
    n=0
    r:=grid_ray(g,hostile_vec3(h,true),hostile_vec3(h,true),base.hostile_f32(h))
    for {
        _,_,ok:=grid_ray_next(&r)
        if !ok {break}
        n+=1
        if n>int(g.item_count)||n>ITERATION_LIMIT {
            testing.expect(t,false,"grid ray gives more items than there are")
            break
        }
        if base.hostile_int(h,4)==0 {r.max_fraction=base.hostile_f32(h)}
    }
}

@(test)
hostile_calls_through_the_grid :: proc(t:^testing.T) {
    h:=base.Hostile{1}
    live:[dynamic]i32
    defer delete(live)
    for _ in 0..<HOSTILE_ROUNDS {
        g:Grid
        if !grid_init(&g,hostile_grid_desc(&h)) {
            grid_destroy(&g)
            continue
        }
        clear(&live)
        for _ in 0..<40 {
            switch base.hostile_int(&h,10) {
            case 0,1,2:
                item,ok:=grid_insert(&g,hostile_box(&h),base.hostile_next(&h))
                if ok {append(&live,item)}
            case 3: _=grid_move(&g,hostile_handle(&h,live[:],g.item_high),hostile_box(&h))
            case 4: grid_remove(&g,hostile_handle(&h,live[:],g.item_high))
            case 5: grid_probe(t,&g,&h)
            case 6: _=grid_cell(&g,hostile_vec3(&h,true))
            case 7:
                if base.hostile_int(&h,8)==0 {grid_clear(&g);clear(&live)}
            case 8: testing.expect(t,grid_validate(&g),"grid state is not valid")
            case 9: grid_remove(&g,hostile_handle(&h,nil,g.item_high))
            }
        }
        grid_probe(t,&g,&h)
        testing.expect(t,grid_validate(&g),"grid state is not valid")
        grid_destroy(&g)
    }
}

@(private="file")
hostile_octree_desc :: proc(h:^base.Hostile) -> Octree_Desc {
    if base.hostile_int(h,2)==0 {return {bounds={{-10,-10,-10},{10,10,10}},item_capacity=4+base.hostile_int(h,60),max_depth=base.hostile_int(h,17),leaf_items=base.hostile_int(h,6),node_capacity=base.hostile_int(h,2)==0?0:1+base.hostile_int(h,100)}}
    desc:=Octree_Desc{bounds=hostile_bounds(h),item_capacity=hostile_capacity(h)}
    switch base.hostile_int(h,8) {
    case 0: desc.max_depth=-1
    case 1: desc.max_depth=17
    case 2: desc.max_depth=max(int)
    case 3: desc.max_depth=16
    case 4: desc.max_depth=1
    case: desc.max_depth=base.hostile_int(h,10)
    }
    switch base.hostile_int(h,6) {
    case 0: desc.leaf_items=-1
    case 1: desc.leaf_items=1
    case 2: desc.leaf_items=max(int)
    case: desc.leaf_items=base.hostile_int(h,10)
    }
    switch base.hostile_int(h,8) {
    case 0: desc.node_capacity=-1
    case 1: desc.node_capacity=1<<40
    case 2: desc.node_capacity=1
    case 3: desc.node_capacity=max(int)
    case 4: desc.node_capacity=9
    case: desc.node_capacity=base.hostile_int(h,100)
    }
    return desc
}

@(private="file")
octree_probe :: proc(t:^testing.T,o:^Octree,h:^base.Hostile) {
    n:=0
    q:=octree_query(o,hostile_box(h))
    for {
        _,_,ok:=octree_query_next(&q)
        if !ok {break}
        n+=1
        if n>int(o.item_count)||n>ITERATION_LIMIT {
            testing.expect(t,false,"octree query gives more items than there are")
            break
        }
    }
    n=0
    r:=octree_ray(o,hostile_vec3(h,true),hostile_vec3(h,true),base.hostile_f32(h))
    for {
        _,_,ok:=octree_ray_next(&r)
        if !ok {break}
        n+=1
        if n>int(o.item_count)||n>ITERATION_LIMIT {
            testing.expect(t,false,"octree ray gives more items than there are")
            break
        }
        if base.hostile_int(h,4)==0 {r.max_fraction=base.hostile_f32(h)}
    }
}

@(test)
hostile_calls_through_the_octree :: proc(t:^testing.T) {
    h:=base.Hostile{3}
    live:[dynamic]i32
    defer delete(live)
    for _ in 0..<HOSTILE_ROUNDS {
        o:Octree
        if !octree_init(&o,hostile_octree_desc(&h)) {
            octree_destroy(&o)
            continue
        }
        clear(&live)
        for _ in 0..<60 {
            switch base.hostile_int(&h,10) {
            case 0,1,2:
                item,ok:=octree_insert(&o,hostile_box(&h),base.hostile_next(&h))
                if ok {append(&live,item)}
            case 3: _=octree_move(&o,hostile_handle(&h,live[:],o.item_high),hostile_box(&h))
            case 4: octree_remove(&o,hostile_handle(&h,live[:],o.item_high))
            case 5: octree_probe(t,&o,&h)
            case 6: _=octree_node_count(&o)
            case 7:
                if base.hostile_int(&h,8)==0 {octree_clear(&o);clear(&live)}
            case 8: testing.expect(t,octree_validate(&o),"octree state is not valid")
            case 9: octree_remove(&o,hostile_handle(&h,nil,o.item_high))
            }
        }
        octree_probe(t,&o,&h)
        testing.expect(t,octree_validate(&o),"octree state is not valid")
        octree_destroy(&o)
    }
}

@(private="file")
tree_probe :: proc(t:^testing.T,tree:^Dynamic_Tree,h:^base.Hostile) {
    n:=0
    q:=dynamic_tree_query(tree,hostile_box(h))
    for {
        _,_,ok:=tree_query_next(&q)
        if !ok {break}
        n+=1
        if n>int(tree.proxy_count)||n>ITERATION_LIMIT {
            testing.expect(t,false,"tree query gives more proxies than there are")
            break
        }
    }
    n=0
    r:=dynamic_tree_ray(tree,hostile_vec3(h,true),hostile_vec3(h,true),base.hostile_f32(h))
    for {
        _,_,ok:=tree_ray_next(&r)
        if !ok {break}
        n+=1
        if n>int(tree.proxy_count)||n>ITERATION_LIMIT {
            testing.expect(t,false,"tree ray gives more proxies than there are")
            break
        }
        if base.hostile_int(h,4)==0 {r.max_fraction=base.hostile_f32(h)}
    }
    n=0
    s:=dynamic_tree_sweep(tree,hostile_box(h),hostile_vec3(h,true),base.hostile_f32(h))
    for {
        _,_,ok:=tree_sweep_next(&s)
        if !ok {break}
        n+=1
        if n>int(tree.proxy_count)||n>ITERATION_LIMIT {
            testing.expect(t,false,"tree sweep gives more proxies than there are")
            break
        }
    }
}

@(test)
hostile_calls_through_the_dynamic_tree :: proc(t:^testing.T) {
    h:=base.Hostile{5}
    live:[dynamic]i32
    defer delete(live)
    other:Dynamic_Tree
    defer dynamic_tree_destroy(&other)
    _=dynamic_tree_init(&other,{proxy_capacity=64})
    for round in 0..<HOSTILE_ROUNDS {
        tree:Dynamic_Tree
        wild:=round%3==0
        if !dynamic_tree_init(&tree,{proxy_capacity=base.hostile_int(&h,3)==0?hostile_capacity(&h):1+base.hostile_int(&h,40),margin=base.hostile_f32(&h)}) {
            dynamic_tree_destroy(&tree)
            continue
        }
        clear(&live)
        for _ in 0..<60 {
            box:=wild?hostile_box(&h):hostile_valid_box(&h)
            switch base.hostile_int(&h,11) {
            case 0,1,2,3:
                proxy,ok:=dynamic_tree_insert(&tree,box,base.hostile_next(&h))
                if ok {append(&live,proxy)}
            case 4:
                if len(live)>0 {dynamic_tree_move(&tree,live[base.hostile_int(&h,len(live))],box)}
            case 5:
                if len(live)>0 {_=dynamic_tree_update(&tree,live[base.hostile_int(&h,len(live))],box,hostile_vec3(&h,wild))}
            case 6:
                if len(live)>0 {
                    at:=base.hostile_int(&h,len(live))
                    dynamic_tree_remove(&tree,live[at])
                    unordered_remove(&live,at)
                }
            case 7: tree_probe(t,&tree,&h)
            case 8:
                valid:=dynamic_tree_validate(&tree)
                if !wild {testing.expect(t,valid,"tree state is not valid")}
            case 9:
                _=dynamic_tree_height(&tree)
                _=dynamic_tree_area_ratio(&tree)
            case 10: _,_=dynamic_tree_copy(&other,&tree,base.hostile_int(&h,2)==0)
            }
        }
        tree_probe(t,&tree,&h)
        if !wild {testing.expect(t,dynamic_tree_validate(&tree),"tree state is not valid")}
        dynamic_tree_clear(&tree)
        dynamic_tree_destroy(&tree)
    }
}

// One of the three structures that hand out handles, for the test that treats them alike.
@(private="file")
Hostile_Structure :: struct {grid:Grid,octree:Octree,tree:Dynamic_Tree}

@(private="file")
Hostile_Index :: struct {
    name:string,
    init:proc(s:^Hostile_Structure) -> bool,
    insert:proc(s:^Hostile_Structure,box:Aabb,user:u64) -> (i32,bool),
    remove:proc(s:^Hostile_Structure,item:i32),
    // Whether the item took the box.
    move:proc(s:^Hostile_Structure,h:^base.Hostile,item:i32,box:Aabb) -> bool,
    aabb:proc(s:^Hostile_Structure,item:i32) -> Aabb,
    user:proc(s:^Hostile_Structure,item:i32) -> u64,
    set_user:proc(s:^Hostile_Structure,item:i32,user:u64),
    valid:proc(s:^Hostile_Structure) -> bool,
    high:proc(s:^Hostile_Structure) -> i32,
    destroy:proc(s:^Hostile_Structure),
    refuses_boxes:bool, // a box that is not valid is refused; the tree takes the box it is given
}

@(test)
hostile_handles_through_every_structure :: proc(t:^testing.T) {
    memory:base.Hostile_Memory
    context.allocator=base.hostile_memory_begin(&memory)
    defer {
        leaked,bad_frees:=base.hostile_memory_end(&memory)
        testing.expectf(t,leaked==0 && bad_frees==0,"%d allocations were left and %d frees were of nothing",leaked,bad_frees)
    }
    indices:=[?]Hostile_Index{
        {"grid",
            proc(s:^Hostile_Structure) -> bool {return grid_init(&s.grid,Grid_Desc{cell_size=1,bounds={{-5,-5,-5},{5,5,5}},item_capacity=4})},
            proc(s:^Hostile_Structure,box:Aabb,user:u64) -> (i32,bool) {return grid_insert(&s.grid,box,user)},
            proc(s:^Hostile_Structure,item:i32) {grid_remove(&s.grid,item)},
            proc(s:^Hostile_Structure,h:^base.Hostile,item:i32,box:Aabb) -> bool {return grid_move(&s.grid,item,box)},
            proc(s:^Hostile_Structure,item:i32) -> Aabb {return grid_aabb(&s.grid,item)},
            proc(s:^Hostile_Structure,item:i32) -> u64 {return grid_user(&s.grid,item)},
            proc(s:^Hostile_Structure,item:i32,user:u64) {grid_set_user(&s.grid,item,user)},
            proc(s:^Hostile_Structure) -> bool {return grid_validate(&s.grid)},
            proc(s:^Hostile_Structure) -> i32 {return s.grid.item_high},
            proc(s:^Hostile_Structure) {grid_destroy(&s.grid)},
            true},
        {"octree",
            proc(s:^Hostile_Structure) -> bool {return octree_init(&s.octree,Octree_Desc{bounds={{-5,-5,-5},{5,5,5}},item_capacity=4})},
            proc(s:^Hostile_Structure,box:Aabb,user:u64) -> (i32,bool) {return octree_insert(&s.octree,box,user)},
            proc(s:^Hostile_Structure,item:i32) {octree_remove(&s.octree,item)},
            proc(s:^Hostile_Structure,h:^base.Hostile,item:i32,box:Aabb) -> bool {return octree_move(&s.octree,item,box)},
            proc(s:^Hostile_Structure,item:i32) -> Aabb {return octree_aabb(&s.octree,item)},
            proc(s:^Hostile_Structure,item:i32) -> u64 {return octree_user(&s.octree,item)},
            proc(s:^Hostile_Structure,item:i32,user:u64) {octree_set_user(&s.octree,item,user)},
            proc(s:^Hostile_Structure) -> bool {return octree_validate(&s.octree)},
            proc(s:^Hostile_Structure) -> i32 {return s.octree.item_high},
            proc(s:^Hostile_Structure) {octree_destroy(&s.octree)},
            true},
        {"dynamic tree",
            proc(s:^Hostile_Structure) -> bool {return dynamic_tree_init(&s.tree,{proxy_capacity=8,margin=0.1})},
            proc(s:^Hostile_Structure,box:Aabb,user:u64) -> (i32,bool) {return dynamic_tree_insert(&s.tree,box,user)},
            proc(s:^Hostile_Structure,item:i32) {dynamic_tree_remove(&s.tree,item)},
            proc(s:^Hostile_Structure,h:^base.Hostile,item:i32,box:Aabb) -> bool {
                leaf:=proxy_valid(&s.tree,item)
                if base.hostile_int(h,2)==0 {
                    dynamic_tree_move(&s.tree,item,box)
                } else if !dynamic_tree_update(&s.tree,item,box,hostile_vec3(h,false)) {
                    // Nothing moves while the box it has contains the new one.
                    return leaf && math.aabb_contains(dynamic_tree_aabb(&s.tree,item),box)
                }
                return leaf
            },
            proc(s:^Hostile_Structure,item:i32) -> Aabb {return dynamic_tree_aabb(&s.tree,item)},
            proc(s:^Hostile_Structure,item:i32) -> u64 {return dynamic_tree_user(&s.tree,item)},
            proc(s:^Hostile_Structure,item:i32,user:u64) {dynamic_tree_set_user(&s.tree,item,user)},
            proc(s:^Hostile_Structure) -> bool {return dynamic_tree_validate(&s.tree)},
            proc(s:^Hostile_Structure) -> i32 {return s.tree.node_high},
            proc(s:^Hostile_Structure) {dynamic_tree_destroy(&s.tree)},
            false},
    }
    live:[dynamic]i32
    boxes:[dynamic]Aabb
    users:[dynamic]u64
    defer {delete(live);delete(boxes);delete(users)}
    for index,seed in indices {
        h:=base.Hostile{u64(seed)+2}
        for _ in 0..<HOSTILE_ROUNDS {
            if testing.failed(t) {return}
            s:Hostile_Structure
            if !testing.expectf(t,index.init(&s),"%s: a small structure was not made",index.name) {return}
            clear(&live);clear(&boxes);clear(&users)
            for _ in 0..<base.hostile_int(&h,8) {
                box,user:=hostile_valid_box(&h),base.hostile_next(&h)|1
                if item,ok:=index.insert(&s,box,user);ok {append(&live,item);append(&boxes,box);append(&users,user)}
            }
            for _ in 0..<8 {
                item:=hostile_handle(&h,live[:],index.high(&s))
                at:=-1
                for held,i in live {if held==item {at=i}}
                switch base.hostile_int(&h,5) {
                case 0:
                    if at<0 {testing.expectf(t,index.aabb(&s,item)=={} && index.user(&s,item)==0,"%s: an item that is not live does not read as zero",index.name)}
                case 1:
                    user:=base.hostile_next(&h)|1
                    index.set_user(&s,item,user)
                    if at>=0 {users[at]=user}
                case 2:
                    box:=hostile_box(&h) if index.refuses_boxes else hostile_valid_box(&h)
                    before:=index.aabb(&s,item)
                    moved:=index.move(&s,&h,item,box)
                    testing.expectf(t,!moved || (at>=0 && aabb_valid(box)),"%s: an item that is not live, or a box that is not valid, was moved",index.name)
                    testing.expectf(t,moved || index.aabb(&s,item)==before,"%s: a refused move changed the item",index.name)
                    if moved && at>=0 {boxes[at]=box}
                case 3,4:
                    index.remove(&s,item)
                    if at>=0 {unordered_remove(&live,at);unordered_remove(&boxes,at);unordered_remove(&users,at)}
                    testing.expectf(t,index.aabb(&s,item)=={} && index.user(&s,item)==0,"%s: a removed item does not read as zero",index.name)
                }
                if !testing.expectf(t,index.valid(&s),"%s: the structure is not valid after a call with the handle %d",index.name,item) {return}
                for held,i in live {
                    if !testing.expectf(t,math.aabb_contains(index.aabb(&s,held),boxes[i]) && index.user(&s,held)==users[i],"%s: a call with the handle %d changed the item %d",index.name,item,held) {return}
                }
            }
            index.destroy(&s)
        }
    }
}

@(private="file")
bvh_probe :: proc(t:^testing.T,bvh:^Bvh,h:^base.Hostile) {
    n:=0
    q:=bvh_query(bvh,hostile_box(h))
    for {
        primitives,ok:=bvh_query_next(&q)
        if !ok {break}
        n+=len(primitives)
        if n>len(bvh.order)||n>ITERATION_LIMIT {
            testing.expect(t,false,"bvh query gives more primitives than there are")
            break
        }
    }
    n=0
    r:=bvh_ray(bvh,hostile_vec3(h,true),hostile_vec3(h,true),base.hostile_f32(h))
    for {
        primitives,ok:=bvh_ray_next(&r)
        if !ok {break}
        n+=len(primitives)
        if n>len(bvh.order)||n>ITERATION_LIMIT {
            testing.expect(t,false,"bvh ray gives more primitives than there are")
            break
        }
        if base.hostile_int(h,4)==0 {r.max_fraction=base.hostile_f32(h)}
    }
    n=0
    s:=bvh_sweep(bvh,hostile_box(h),hostile_vec3(h,true),base.hostile_f32(h))
    for {
        primitives,ok:=bvh_sweep_next(&s)
        if !ok {break}
        n+=len(primitives)
        if n>len(bvh.order)||n>ITERATION_LIMIT {
            testing.expect(t,false,"bvh sweep gives more primitives than there are")
            break
        }
    }
}

@(private="file")
hostile_leaf_size :: proc(h:^base.Hostile) -> int {
    switch base.hostile_int(h,6) {
    case 0: return -1
    case 1: return 1
    case 2: return max(int)
    }
    return base.hostile_int(h,9)
}

@(test)
hostile_boxes_through_the_bvh_build :: proc(t:^testing.T) {
    h:=base.Hostile{11}
    boxes:[dynamic]Aabb
    defer delete(boxes)
    for round in 0..<HOSTILE_ROUNDS {
        clear(&boxes)
        wild:=round%4==0
        same:=base.hostile_int(&h,6)==0
        first:=hostile_valid_box(&h)
        for _ in 0..<base.hostile_int(&h,40) {append(&boxes,same?first:(wild?hostile_box(&h):hostile_valid_box(&h)))}
        bvh:Bvh
        ok:=bvh_build(&bvh,boxes[:],{max_leaf_size=hostile_leaf_size(&h)})
        if ok {testing.expect(t,bvh_validate(&bvh),"bvh is not valid")}
        _=bvh_bounds(&bvh)
        bvh_probe(t,&bvh,&h)
        bvh_destroy(&bvh)
        free_all(context.temp_allocator)
    }
}

@(test)
hostile_meshes_through_the_bvh_build :: proc(t:^testing.T) {
    h:=base.Hostile{12}
    vertices:[dynamic][3]f32
    indices:[dynamic]u32
    defer {delete(vertices);delete(indices)}
    for round in 0..<HOSTILE_ROUNDS {
        clear(&vertices);clear(&indices)
        wild:=round%4==0
        n:=base.hostile_int(&h,20)
        for _ in 0..<n {append(&vertices,hostile_vec3(&h,wild))}
        count:=base.hostile_int(&h,40)
        if base.hostile_int(&h,3)!=0 {count-=count%3}
        for _ in 0..<count {append(&indices,u32(base.hostile_int(&h,max(n,1)+(base.hostile_int(&h,5)==0?3:0))))}
        bvh:Bvh
        ok:=bvh_build_triangles(&bvh,vertices[:],indices[:],{max_leaf_size=hostile_leaf_size(&h)})
        if ok {testing.expect(t,bvh_validate(&bvh),"bvh is not valid")}
        bvh_probe(t,&bvh,&h)
        bvh_destroy(&bvh)
        free_all(context.temp_allocator)
    }
}

@(test)
hostile_nodes_through_the_bvh_validate :: proc(t:^testing.T) {
    h:=base.Hostile{13}
    boxes:[dynamic]Aabb
    defer delete(boxes)
    for _ in 0..<HOSTILE_ROUNDS {
        clear(&boxes)
        for _ in 0..<1+base.hostile_int(&h,30) {append(&boxes,hostile_valid_box(&h))}
        bvh:Bvh
        if !bvh_build(&bvh,boxes[:],{max_leaf_size=1+base.hostile_int(&h,4)}) {continue}
        for _ in 0..<1+base.hostile_int(&h,3) {
            word:u32
            switch base.hostile_int(&h,6) {
            case 0: word=0xffffffff
            case 1: word=0
            case 2: word=1
            case 3: word=u32(len(bvh.nodes))
            case: word=u32(base.hostile_int(&h,len(bvh.nodes)+2))
            }
            if base.hostile_int(&h,4)==0 {
                bvh.order[base.hostile_int(&h,len(bvh.order))]=word
            } else {
                node:=&bvh.nodes[base.hostile_int(&h,len(bvh.nodes))]
                if base.hostile_int(&h,2)==0 {node.first=word} else {node.count=word}
            }
        }
        if bvh_validate(&bvh) {bvh_probe(t,&bvh,&h)}
        bvh_destroy(&bvh)
        free_all(context.temp_allocator)
    }
}

@(test)
hostile_boxes_through_the_segment_tests :: proc(t:^testing.T) {
    h:=base.Hostile{14}
    for _ in 0..<HOSTILE_ROUNDS {
        a,b:=hostile_box(&h),hostile_box(&h)
        reach:=base.hostile_f32(&h)
        fraction,hit:=aabb_ray(a,hostile_vec3(&h,true),hostile_vec3(&h,true),reach)
        testing.expect(t,!hit || (fraction>=0 && fraction<=reach),"A segment enters a box within its reach")
        fraction,hit=aabb_sweep(a,b,hostile_vec3(&h,true),reach)
        testing.expect(t,!hit || (fraction>=0 && fraction<=reach),"A moving box touches a box within its reach")
        _=aabb_center(a);_=aabb_extents(a);_=aabb_translate_extend(a,hostile_vec3(&h,true))
        finite:=true
        for i in 0..<3 {finite&&=a.min[i]<=a.max[i] && a.min[i]-a.min[i]==0 && a.max[i]-a.max[i]==0}
        testing.expect(t,aabb_valid(a)==finite,"A box is valid exactly when it is finite and not inverted")
        if !finite {continue}
        swept:=aabb_translate_extend(a,hostile_vec3(&h,false))
        testing.expect(t,aabb_area(a)>=0 && math.aabb_contains(swept,a),"A valid box has an area and is inside what it sweeps")
        fraction,hit=aabb_ray(a,aabb_center(a),hostile_vec3(&h,false),1)
        testing.expect(t,hit && fraction==0,"A segment that starts inside a box enters it at 0")
    }
}

@(test)
hostile_calls_through_empty_structures :: proc(t:^testing.T) {
    h:=base.Hostile{15}
    for _ in 0..<HOSTILE_ROUNDS/8 {
        g:Grid
        item,inserted:=grid_insert(&g,hostile_box(&h),0)
        testing.expect(t,!inserted && !grid_move(&g,hostile_handle(&h,nil,0),hostile_box(&h)) && grid_aabb(&g,item)=={},"A zeroed grid takes nothing")
        grid_remove(&g,hostile_handle(&h,nil,0))
        _=grid_cell(&g,hostile_vec3(&h,true))
        grid_probe(t,&g,&h)
        _=grid_validate(&g)
        grid_clear(&g)
        grid_destroy(&g)
        o:Octree
        item,inserted=octree_insert(&o,hostile_box(&h),0)
        testing.expect(t,!inserted && !octree_move(&o,hostile_handle(&h,nil,0),hostile_box(&h)) && octree_node_count(&o)==0,"A zeroed octree takes nothing and has no nodes")
        octree_remove(&o,hostile_handle(&h,nil,0))
        octree_probe(t,&o,&h)
        _=octree_validate(&o)
        octree_clear(&o)
        octree_destroy(&o)
        tree:Dynamic_Tree
        item,inserted=dynamic_tree_insert(&tree,hostile_box(&h),0)
        tree_probe(t,&tree,&h)
        _=dynamic_tree_validate(&tree)
        _=dynamic_tree_area_ratio(&tree)
        zeroed:Dynamic_Tree
        copied,fits:=dynamic_tree_copy(&zeroed,&tree,true)
        testing.expect(t,!inserted && dynamic_tree_height(&tree)==0 && fits && copied==0,"A zeroed tree takes nothing, and copies as an empty one")
        dynamic_tree_clear(&tree)
        dynamic_tree_destroy(&tree)
        bvh:Bvh
        bvh_probe(t,&bvh,&h)
        _=bvh_validate(&bvh)
        _=bvh_bounds(&bvh)
        bvh_destroy(&bvh)
        _=bvh_build(&bvh,nil,{})
        _=bvh_build_triangles(&bvh,nil,nil,{})
        bvh_destroy(&bvh)
    }
}

@(test)
hostile_nested_boxes_through_every_structure :: proc(t:^testing.T) {
    h:=base.Hostile{16}
    for count in ([?]int{70,150,300}) {
        boxes:=make([]Aabb,count)
        defer delete(boxes)
        for &box,i in boxes {
            e:=f32(i+1)
            box={{-e,-e,-e},{e,e,e}}
        }
        tree:Dynamic_Tree
        _=dynamic_tree_init(&tree,{proxy_capacity=count})
        for box in boxes {_,_=dynamic_tree_insert(&tree,box,1)}
        testing.expect(t,dynamic_tree_validate(&tree),"nested tree is not valid")
        for _ in 0..<HOSTILE_ROUNDS/8 {tree_probe(t,&tree,&h)}
        dynamic_tree_destroy(&tree)
        bvh:Bvh
        if bvh_build(&bvh,boxes,{}) {testing.expect(t,bvh_validate(&bvh),"nested bvh is not valid")}
        for _ in 0..<HOSTILE_ROUNDS/8 {bvh_probe(t,&bvh,&h)}
        bvh_destroy(&bvh)
        o:Octree
        _=octree_init(&o,{bounds={{-400,-400,-400},{400,400,400}},item_capacity=count,max_depth=16})
        for box in boxes {_,_=octree_insert(&o,box,1)}
        testing.expect(t,octree_validate(&o),"nested octree is not valid")
        for _ in 0..<HOSTILE_ROUNDS/8 {octree_probe(t,&o,&h)}
        octree_destroy(&o)
        g:Grid
        _=grid_init(&g,{cell_size=8,bounds={{-400,-400,-400},{400,400,400}},item_capacity=count,link_capacity=count*100})
        for box in boxes {_,_=grid_insert(&g,box,1)}
        testing.expect(t,grid_validate(&g),"nested grid is not valid")
        for _ in 0..<HOSTILE_ROUNDS/8 {grid_probe(t,&g,&h)}
        grid_destroy(&g)
    }
}

