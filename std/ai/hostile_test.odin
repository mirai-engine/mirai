package ai

import "core:math/linalg"
import "mirai:std/base"
import "base:runtime"
import "core:testing"
import math "mirai:std/math"

// Every public procedure is handed cells, nodes, triangles and states out of
// range, sizes that overflow, graphs with edges to nowhere, NaN, infinities
// and huge coordinates and buffers of any length. What it finds joins its
// ends and fits its output, what it counts is what it wrote, a size it cannot
// hold is refused and an empty structure answers nothing.
// The minds have theirs in mind_test.odin.

@(private="file") HOSTILE_ROUNDS :: #config(AI_HOSTILE_ROUNDS,400)

@(private="file")
hostile_vec2 :: proc "contextless" (h:^base.Hostile,wild:bool) -> math.Vec2 {
    if !wild {return {f32(base.hostile_int(h,201)-100)/20,f32(base.hostile_int(h,201)-100)/20}}
    return {base.hostile_f32(h),base.hostile_f32(h)}
}

@(private="file")
hostile_vec3 :: proc "contextless" (h:^base.Hostile,wild:bool) -> math.Vec3 {
    if !wild {return {f32(base.hostile_int(h,201)-100)/20,f32(base.hostile_int(h,201)-100)/20,f32(base.hostile_int(h,201)-100)/20}}
    return {base.hostile_f32(h),base.hostile_f32(h),base.hostile_f32(h)}
}

@(private="file")
hostile_cell :: proc "contextless" (h:^base.Hostile,size:int) -> Cell {
    switch base.hostile_int(h,10) {
    case 0: return {-1,-1}
    case 1: return {max(i32),max(i32)}
    case 2: return {min(i32),min(i32)}
    case 3: return {i32(size),i32(size)}
    case 4: return {0,i32(size)}
    }
    return {i32(base.hostile_int(h,max(size,1))),i32(base.hostile_int(h,max(size,1)))}
}

@(private="file")
hostile_count :: proc "contextless" (h:^base.Hostile) -> int {
    switch base.hostile_int(h,10) {
    case 0: return -1
    case 1: return 0
    case 2: return 1<<16
    case 3: return 1
    }
    return 1+base.hostile_int(h,40)
}

@(private="file")
hostile_extent :: proc "contextless" (h:^base.Hostile) -> int {
    switch base.hostile_int(h,10) {
    case 0: return -1
    case 1: return 0
    case 2: return 1<<10
    case 3: return 1
    }
    return 1+base.hostile_int(h,40)
}

@(private="file")
hostile_grid :: proc(h:^base.Hostile,g:^Grid) -> bool {
    w,height:=1+base.hostile_int(h,12),1+base.hostile_int(h,12)
    if !grid_init(g,w,height,u8(base.hostile_int(h,3)==0?base.hostile_int(h,256):1)) {return false}
    for _ in 0..<base.hostile_int(h,10) {
        low:=hostile_cell(h,w)
        grid_fill(g,low,low+Cell{i32(base.hostile_int(h,5)),i32(base.hostile_int(h,5))},u8(base.hostile_int(h,3)==0?base.hostile_int(h,256):0))
        _=grid_set(g,hostile_cell(h,w),u8(base.hostile_int(h,256)))
    }
    return true
}

@(test)
hostile_cells_through_the_grid_search :: proc(t:^testing.T) {
    h:=base.Hostile{1}
    path:[dynamic]Cell
    defer delete(path)
    for _ in 0..<HOSTILE_ROUNDS {
        g:Grid
        if !hostile_grid(&h,&g) {continue}
        s:Search
        nodes:=len(g.cost)+base.hostile_int(&h,3)-1
        if !search_init(&s,{nodes=nodes,open=base.hostile_int(&h,3)==0?base.hostile_int(&h,6):0,max_edges=base.hostile_int(&h,3)==0?base.hostile_int(&h,10)-2:0}) {
            grid_destroy(&g)
            continue
        }
        for _ in 0..<8 {
            resize(&path,base.hostile_int(&h,4)==0?base.hostile_int(&h,5):len(g.cost))
            start,goal:=hostile_cell(&h,g.width),hostile_cell(&h,g.height)
            if base.hostile_int(&h,6)==0 {goal=start}
            hood:=Neighborhood(base.hostile_int(&h,2))
            count,status:=grid_find_path(&s,&g,start,goal,hood,path[:])
            if status==.Found {
                testing.expect(t,count>=1&&count<=len(path),"path does not fit")
                if count>=1&&count<=len(path) {
                    testing.expect(t,path[0]==start&&path[count-1]==goal,"path does not join the ends")
                }
            }
            steps:[8]Cell
            lengths:[8]f32
            _=grid_steps(&g,hostile_cell(&h,g.width),hood,&steps,&lengths)
            _=grid_cost(&g,hostile_cell(&h,g.width))
            _=grid_passable(&g,hostile_cell(&h,g.width))
            _=grid_in_bounds(&g,hostile_cell(&h,g.width))
            _=grid_index(&g,hostile_cell(&h,g.width))
            _=grid_cell(&g,base.hostile_int(&h,len(g.cost)))
            _=search_cost(&s)
            _=search_nodes(&s)
            out:[8]u64
            _,_=search_path(&s,out[:base.hostile_int(&h,9)])
        }
        search_destroy(&s)
        grid_destroy(&g)
    }
}

@(test)
hostile_calls_through_empty_grids :: proc(t:^testing.T) {
    h:=base.Hostile{2}
    for _ in 0..<HOSTILE_ROUNDS/8 {
        g:Grid
        s:Search
        f:Flow_Field
        out:[4]Cell
        steps:[8]Cell
        lengths:[8]f32
        _,found:=grid_find_path(&s,&g,hostile_cell(&h,3),hostile_cell(&h,3),.Eight,out[:])
        grid_fill(&g,hostile_cell(&h,3),hostile_cell(&h,3),1)
        empty:=found!=.Found && grid_cost(&g,hostile_cell(&h,3))==0 && !grid_passable(&g,hostile_cell(&h,3)) && !grid_set(&g,hostile_cell(&h,3),1)
        empty&&=grid_steps(&g,hostile_cell(&h,3),.Eight,&steps,&lengths)==0 && grid_cell(&g,base.hostile_int(&h,9)-4)=={}
        testing.expect(t,empty,"A zeroed grid has cells")
        empty=flow_field_build(&f,&g,out[:],.Eight)!=.Found && flow_field_direction(&f,hostile_cell(&h,3))=={} && flow_field_sample(&f,hostile_vec2(&h,true))=={}
        _=flow_field_cost(&f,hostile_cell(&h,3))
        testing.expect(t,empty,"A zeroed flow field points somewhere")
        ran:=search_run(&s,0,0,&g,proc(g:^Grid,n:u64,e:^Edge_List){},proc(g:^Grid,n,goal:u64) -> f32 {return 0})
        count,status:=search_path(&s,nil)
        _,_,popped:=open_pop(&s.open)
        empty=ran!=.Found && count==0 && status!=.Found && !open_contains(&s.open,0) && !open_push(&s.open,0,1) && !popped
        testing.expect(t,empty,"A zeroed search finds a path")
        open_clear(&s.open)
        grid_destroy(&g);search_destroy(&s);flow_field_destroy(&f)
    }
}

@(test)
hostile_sizes_through_the_grid_init :: proc(t:^testing.T) {
    h:=base.Hostile{3}
    for _ in 0..<HOSTILE_ROUNDS {
        g:Grid
        w,height:=hostile_extent(&h),hostile_extent(&h)
        made:=grid_init(&g,w,height)
        if !testing.expect(t,made==(w>0 && height>0) && len(g.cost)==(w*height if made else 0),"A grid has a cell for every place of its two positive sides, or none") {return}
        if made {
            at:=Cell{i32(base.hostile_int(&h,100)),i32(base.hostile_int(&h,100))}
            inside:=int(at.x)<w && int(at.y)<height
            testing.expect(t,grid_set(&g,at,3)==inside && grid_cost(&g,at)==(3 if inside else 0),"Only a cell of the grid takes a cost")
            grid_fill(&g,{0,0},{1<<20,1<<20},2)
            testing.expect(t,grid_cost(&g,{0,0})==2 && grid_cost(&g,{i32(w-1),i32(height-1)})==2 && grid_cost(&g,{i32(w),0})==0,"A fill past the grid sets the cells of the grid")
        }
        grid_destroy(&g)
    }
}

// Whether an init took a size, in the place this family gives it, that overflows what the structure counts with.
@(private="file")
Hostile_Overflow :: struct {name:string,sizes:[]int,took:proc(size:int) -> bool}

@(test)
hostile_sizes_that_overflow_are_refused :: proc(t:^testing.T) {
    cells:=[]int{1<<32,(1<<32)+1,1<<44,1<<62,max(int)}
    counts:=[]int{1<<61,1<<62,max(int)}
    families:=[?]Hostile_Overflow{
        {"grid",cells,proc(size:int) -> bool {
            g:Grid
            defer grid_destroy(&g)
            return grid_init(&g,size,size) || grid_init(&g,size,3) || grid_init(&g,2,size)
        }},
        {"flow field",cells,proc(size:int) -> bool {
            f:Flow_Field
            defer flow_field_destroy(&f)
            return flow_field_init(&f,size,size) || flow_field_init(&f,size,3) || flow_field_init(&f,2,size)
        }},
        {"search nodes",counts,proc(size:int) -> bool {s:Search;defer search_destroy(&s);return search_init(&s,{nodes=size})}},
        {"search edges",counts,proc(size:int) -> bool {s:Search;defer search_destroy(&s);return search_init(&s,{nodes=4,max_edges=size})}},
        {"search open set",counts,proc(size:int) -> bool {s:Search;defer search_destroy(&s);return search_init(&s,{nodes=4,open=size})}},
        {"open set",counts,proc(size:int) -> bool {
            o:Open_Set
            defer open_destroy(&o)
            return open_init(&o,size,4) || open_init(&o,4,size)
        }},
        {"utility",{1<<59,1<<61,1<<62,max(int)},proc(size:int) -> bool {
            u:Utility
            defer utility_destroy(&u)
            return utility_init(&u,{max_actions=size}) || utility_init(&u,{max_actions=1,max_considerations=size})
        }},
    }
    for family in families {
        for size in family.sizes {
            testing.expectf(t,!family.took(size),"%s: took the size %d",family.name,size)
        }
    }
}

@(test)
hostile_sizes_through_the_flow_field_init :: proc(t:^testing.T) {
    h:=base.Hostile{4}
    for _ in 0..<HOSTILE_ROUNDS {
        f:Flow_Field
        w,height:=hostile_extent(&h),hostile_extent(&h)
        made:=flow_field_init(&f,w,height)
        testing.expect(t,made==(w>0 && height>0),"A flow field has two positive sides")
        _=flow_field_cost(&f,{0,0})
        testing.expect(t,flow_field_direction(&f,{0,0})=={} && flow_field_sample(&f,hostile_vec2(&h,true))=={},"A flow field that was not built points somewhere")
        flow_field_destroy(&f)
    }
}

@(test)
hostile_sizes_through_the_search_init :: proc(t:^testing.T) {
    h:=base.Hostile{5}
    for _ in 0..<HOSTILE_ROUNDS {
        s:Search
        nodes:=hostile_count(&h)
        if search_init(&s,{nodes=nodes,open=hostile_count(&h),max_edges=hostile_count(&h)}) {
            testing.expect(t,nodes>0 && search_nodes(&s)==nodes,"A search holds the nodes it was made for")
            graph:=Hostile_Graph{nodes=search_nodes(&s)}
            out:[2]u64
            if search_run(&s,0,0,&graph,hostile_graph_neighbors,hostile_graph_heuristic)==.Found {
                count,status:=search_path(&s,out[:])
                testing.expect(t,status==.Found && count==1 && out[0]==0 && search_cost(&s)==0,"The path from a node to itself is that node, at no cost")
            }
        } else {
            testing.expect(t,search_nodes(&s)==0,"A search that was not made holds nodes")
        }
        search_destroy(&s)
        o:Open_Set
        if open_init(&o,hostile_count(&h),hostile_count(&h)) {
            node,key,ok:=u32(0),f32(0),open_push(&o,0,1) && open_contains(&o,0)
            if ok {node,key,ok=open_pop(&o)}
            testing.expect(t,ok && node==0 && key==1 && !open_contains(&o,0),"An open set that was made gives back the node it took")
        }
        open_destroy(&o)
    }
}

@(private="file")
Hostile_Graph :: struct {h:base.Hostile, nodes:int, mode:int}

@(private="file")
hostile_graph_neighbors :: proc(graph:^Hostile_Graph,node:u64,edges:^Edge_List) {
    local:=base.Hostile{node*7919+u64(graph.mode)}
    for _ in 0..<base.hostile_int(&local,12) {
        to:=u64(base.hostile_int(&local,graph.nodes+(graph.mode%3==0?4:0)))
        switch base.hostile_int(&local,12) {
        case 0: to=node
        case 1: to=max(u64)
        }
        cost:=f32(1+base.hostile_int(&local,5))
        if graph.mode%2==0 {cost=base.hostile_f32(&local)}
        edge_add(edges,to,cost)
    }
}

@(private="file")
hostile_graph_heuristic :: proc(graph:^Hostile_Graph,node,goal:u64) -> f32 {
    if graph.mode%4==0 {return f32(base.hostile_next(&graph.h)>>40)-8e6}
    return 0
}

@(private="file")
hostile_user_neighbors :: proc(user:rawptr,node:u64,edges:^Edge_List) {hostile_graph_neighbors((^Hostile_Graph)(user),node,edges)}

@(private="file")
hostile_user_heuristic :: proc(user:rawptr,node,goal:u64) -> f32 {return hostile_graph_heuristic((^Hostile_Graph)(user),node,goal)}

@(test)
hostile_graphs_through_the_search :: proc(t:^testing.T) {
    h:=base.Hostile{6}
    out:[dynamic]u64
    defer delete(out)
    for round in 0..<HOSTILE_ROUNDS {
        graph:=Hostile_Graph{h={u64(round)},nodes=1+base.hostile_int(&h,30),mode=base.hostile_int(&h,8)}
        s:Search
        nodes:=graph.nodes+base.hostile_int(&h,3)-1
        if !search_init(&s,{nodes=nodes,keyed=base.hostile_int(&h,3)==0,open=base.hostile_int(&h,3)==0?base.hostile_int(&h,8):0,max_edges=base.hostile_int(&h,3)==0?base.hostile_int(&h,6)-1:0}) {continue}
        for _ in 0..<6 {
            resize(&out,base.hostile_int(&h,4)==0?base.hostile_int(&h,4):graph.nodes)
            start,goal:=u64(base.hostile_int(&h,graph.nodes+2)),u64(base.hostile_int(&h,graph.nodes+2))
            if base.hostile_int(&h,8)==0 {goal=start}
            if base.hostile_int(&h,10)==0 {start=max(u64)}
            api:=Graph{user=&graph,neighbors=hostile_user_neighbors,heuristic=base.hostile_int(&h,3)==0?nil:hostile_user_heuristic}
            if base.hostile_int(&h,12)==0 {api.neighbors=nil}
            count,status:=graph_find_path(&s,api,start,goal,out[:])
            if status==.Found {
                testing.expect(t,count>=1&&count<=len(out),"path does not fit")
                if count>=1&&count<=len(out) {testing.expect(t,out[0]==start&&out[count-1]==goal,"path does not join the ends")}
            }
            _=search_cost(&s)
            _,_=search_path(&s,out[:])
            _,_=search_path(&s,out[:base.hostile_int(&h,len(out)+1)])
        }
        search_destroy(&s)
    }
}

@(test)
hostile_keys_through_the_open_set :: proc(t:^testing.T) {
    h:=base.Hostile{7}
    for _ in 0..<HOSTILE_ROUNDS {
        if testing.failed(t) {return}
        o:Open_Set
        nodes,capacity:=1+base.hostile_int(&h,20),1+base.hostile_int(&h,20)
        if !open_init(&o,nodes,capacity) {continue}
        // The model: the key of every open node. A NaN key has no order: until the set empties, only what leaves is checked.
        keys:[24]f32
        open:[24]bool
        count,unordered:=0,false
        for step in 0..<80 {
            op:=base.hostile_int(&h,5) if step<60 else 2
            switch op {
            case 0,1:
                node,key:=u32(base.hostile_int(&h,nodes+3)),base.hostile_f32(&h)
                known:=int(node)<nodes && open[node]
                took:=open_push(&o,node,key)
                testing.expect(t,took==(int(node)<nodes && (known || count<capacity)),"A push is refused only for a node out of range or a new one in a full set")
                if took && !known {open[node]=true;keys[node]=key;count+=1;unordered||=key!=key}
                if took && known && key<keys[node] {keys[node]=key}
            case 2:
                node,key,ok:=open_pop(&o)
                if !testing.expect(t,ok==(count>0) && (!ok || (int(node)<nodes && open[node])),"A pop gives an open node exactly while there is one") || !ok {continue}
                lowest:=true
                for other in 0..<nodes {lowest&&=!open[other] || key<=keys[other]}
                testing.expect(t,unordered || (lowest && key==keys[node]),"The node with the lowest key leaves first, with the key it was lowered to")
                open[node]=false;count-=1
            case 3:
                node:=u32(base.hostile_next(&h)) if base.hostile_int(&h,2)==0 else u32(base.hostile_int(&h,nodes))
                testing.expect(t,open_contains(&o,node)==(int(node)<nodes && open[node]),"Only the nodes that were pushed are open")
            case 4:
                open_clear(&o)
                open={};count=0
            }
            if count==0 {unordered=false}
        }
        testing.expect_value(t,count,0)
        open_destroy(&o)
    }
}

@(test)
hostile_goals_through_the_flow_field :: proc(t:^testing.T) {
    h:=base.Hostile{8}
    goals:[dynamic]Cell
    defer delete(goals)
    for _ in 0..<HOSTILE_ROUNDS {
        if testing.failed(t) {return}
        g:Grid
        if !hostile_grid(&h,&g) {continue}
        f:Flow_Field
        w,height:=g.width,g.height
        if base.hostile_int(&h,6)==0 {w+=base.hostile_int(&h,3)-1}
        if !flow_field_init(&f,max(w,1),height) {grid_destroy(&g);continue}
        clear(&goals)
        reachable:=false
        for _ in 0..<base.hostile_int(&h,5) {
            append(&goals,hostile_cell(&h,g.width))
            reachable||=grid_passable(&g,goals[len(goals)-1])
        }
        status:=flow_field_build(&f,&g,goals[:],Neighborhood(base.hostile_int(&h,2)))
        testing.expect(t,(status==.Found)==(reachable && max(w,1)==g.width),"A field is built exactly when its size is that of the grid and a goal is a cell to walk")
        for goal in goals {
            if status==.Found && grid_passable(&g,goal) {testing.expect(t,flow_field_cost(&f,goal)==0 && flow_field_direction(&f,goal)=={},"A goal is not where its field ends")}
        }
        for _ in 0..<10 {
            c:=hostile_cell(&h,g.width)
            _=flow_field_cost(&f,c)
            direction:=flow_field_direction(&f,c)
            sample:=flow_field_sample(&f,hostile_vec2(&h,base.hostile_int(&h,2)==0))
            testing.expect(t,linalg.length(direction)<=1.5 && linalg.length(sample)<=1.001,"A direction of the field is longer than a step")
            testing.expect(t,status==.Found || (direction=={} && sample=={}),"A field that was not built points somewhere")
            testing.expect(t,grid_in_bounds(&g,c) || direction=={},"A cell outside the field has a direction")
        }
        flow_field_destroy(&f)
        grid_destroy(&g)
    }
}

@(private="file")
hostile_finite_vec3 :: proc "contextless" (h:^base.Hostile) -> math.Vec3 {
    v:=hostile_vec3(h,true)
    for &x in v {
        if x!=x {x=0} else if x>1e30 {x=1e30} else if x< -1e30 {x=-1e30}
    }
    return v
}

@(private="file")
hostile_navmesh_input :: proc(h:^base.Hostile,vertices:^[dynamic]math.Vec3,indices:^[dynamic]u32,finite:bool) -> (scale:f32) {
    clear(vertices);clear(indices)
    scale=1
    if base.hostile_int(h,3)==0 {
        n:=base.hostile_int(h,16)
        for _ in 0..<n {append(vertices,finite?hostile_finite_vec3(h):hostile_vec3(h,true))}
        count:=base.hostile_int(h,30)
        if base.hostile_int(h,4)!=0 {count-=count%3}
        for _ in 0..<count {append(indices,u32(base.hostile_int(h,max(n,1)+(base.hostile_int(h,6)==0?3:0))))}
        return
    }
    switch base.hostile_int(h,6) {
    case 0: scale=1e-3
    case 1: scale=1e4
    case 2: scale=1e12
    }
    w,height:=1+base.hostile_int(h,6),1+base.hostile_int(h,6)
    for z in 0..=height {
        for x in 0..=w {
            jitter:=base.hostile_int(h,4)==0?f32(0.4):0
            append(vertices,math.Vec3{(f32(x)+jitter*f32(base.hostile_int(h,11)-5)/5)*scale,f32(base.hostile_int(h,3))*scale*0.1,(f32(z)+jitter*f32(base.hostile_int(h,11)-5)/5)*scale})
        }
    }
    stride:=u32(w+1)
    for z in 0..<height {
        for x in 0..<w {
            a:=u32(z)*stride+u32(x)
            b,c,d:=a+1,a+stride,a+stride+1
            if base.hostile_int(h,6)==0 {continue}
            if base.hostile_int(h,2)==0 {
                append(indices,a,c,b,b,c,d)
            } else {
                append(indices,a,c,d,a,d,b)
            }
            if base.hostile_int(h,12)==0 {append(indices,a,c,b)}
            if base.hostile_int(h,12)==0 {append(indices,a,a,b)}
        }
    }
    return
}

@(private="file")
hostile_nav_point :: proc(h:^base.Hostile,scale:f32) -> math.Vec3 {
    if base.hostile_int(h,5)==0 {return hostile_vec3(h,true)}
    p:=hostile_vec3(h,false)
    return {p.x*scale/4,p.y*scale/20,p.z*scale/4}
}

@(private="file")
nav_rounds :: proc(t:^testing.T,seed:u64,finite:bool) {
    h:=base.Hostile{seed}
    vertices:[dynamic]math.Vec3
    indices:[dynamic]u32
    defer {delete(vertices);delete(indices)}
    for _ in 0..<HOSTILE_ROUNDS {
        scale:=hostile_navmesh_input(&h,&vertices,&indices,finite)
        mesh:Nav_Mesh
        width:=scale*f32(1+base.hostile_int(&h,8))/2
        if base.hostile_int(&h,8)==0 {width=base.hostile_f32(&h)}
        climb:=base.hostile_int(&h,4)==0?base.hostile_f32(&h):0.3*scale
        if !nav_mesh_init(&mesh,{tile_width=width,climb=climb,max_tiles=1+base.hostile_int(&h,4),max_links=base.hostile_int(&h,5),max_connections=base.hostile_int(&h,3)==0?base.hostile_int(&h,4):0}) {continue}
        for _ in 0..<1+base.hostile_int(&h,3) {
            coord:=[2]i32{i32(base.hostile_int(&h,3)-1),i32(base.hostile_int(&h,3)-1)}
            rect:=math.Aabb{{f32(coord.x)*width,-1e6,f32(coord.y)*width},{f32(coord.x+1)*width,1e6,f32(coord.y+1)*width}}
            if base.hostile_int(&h,6)==0 {rect={hostile_vec3(&h,true),hostile_vec3(&h,true)}}
            data,ok:=nav_tile_from_triangles(coord,rect,vertices[:],indices[:],u8(1+base.hostile_int(&h,3)))
            if !ok {continue}
            if base.hostile_int(&h,8)==0 {data.polys[0].neighbor[base.hostile_int(&h,6)]=u16(base.hostile_next(&h))}
            if !nav_mesh_add_tile(&mesh,data) {nav_tile_data_free(&data)}
        }
        q:Nav_Query
        _=nav_query_init(&q,1+base.hostile_int(&h,64))
        filter:=Nav_Filter{excluded=base.hostile_int(&h,4)==0?base.hostile_next(&h):0,can=base.hostile_int(&h,2)==0?NAV_CAN_ALL:{}}
        if base.hostile_int(&h,5)==0 {filter.costs[base.hostile_int(&h,64)]=base.hostile_f32(&h)}
        rng:=math.rng_make(base.hostile_next(&h))
        path:[16]Nav_Ref
        corners:[8]Nav_Corner
        coarse:Nav_Coarse
        defer nav_coarse_destroy(&coarse)
        coarse_search:Search
        _=search_init(&coarse_search,{nodes=1+base.hostile_int(&h,80),max_edges=base.hostile_int(&h,40)})
        defer search_destroy(&coarse_search)
        for _ in 0..<12 {
            a,b:=hostile_nav_point(&h,scale),hostile_nav_point(&h,scale)
            extents:=base.hostile_int(&h,4)==0?hostile_vec3(&h,true):math.Vec3{scale,scale,scale}
            from,_,near:=nav_find_nearest(&mesh,a,extents,&filter)
            to,_,far:=nav_find_nearest_any(&mesh,b,extents)
            // What a query counts fits what it was given to write, and a polygon it names is of the mesh.
            if !testing.expect(t,(!near || nav_ref_valid(&mesh,from)) && (!far || nav_ref_valid(&mesh,to)) && (near || from==0) && (far || to==0),"The nearest polygon is not of the mesh") {return}
            if base.hostile_int(&h,6)==0 {from=Nav_Ref(base.hostile_next(&h))}
            switch base.hostile_int(&h,9) {
            case 0,1:
                room:=path[:base.hostile_int(&h,17)]
                count,status,partial:=nav_find_path(&q,&mesh,from,to,a,b,&filter,room)
                if !testing.expect(t,count>=0 && count<=len(room) && (status!=.Found || count>=1),"A path does not fit its output") {return}
                testing.expect(t,status!=.Found || partial || (room[0]==from && room[count-1]==to),"A whole path does not join its ends")
                turns:=corners[:base.hostile_int(&h,9)]
                written,_:=nav_straight_path(&mesh,a,b,room[:count],turns)
                testing.expect(t,written>=0 && written<=len(turns),"A straight path has more corners than fit")
            case 2:
                status:=nav_path_begin(&q,&mesh,from,to,a,b,&filter)
                for i:=0;status==.Running && i<64;i+=1 {status=nav_path_step(&q,base.hostile_int(&h,4))}
                if base.hostile_int(&h,3)==0 {_=nav_mesh_remove_tile(&mesh,{i32(base.hostile_int(&h,3)-1),i32(base.hostile_int(&h,3)-1)})}
                count,_,_:=nav_path_finish(&q,path[:])
                testing.expect(t,count>=0 && count<=len(path),"A path found in steps does not fit its output")
            case 3:
                room:=path[:base.hostile_int(&h,17)]
                _,walked:=nav_move_along_surface(&mesh,from,a,b,&filter,room)
                _,_,crossed:=nav_raycast(&mesh,from,a,b,&filter,room)
                testing.expect(t,walked>=0 && walked<=len(room) && crossed>=0 && crossed<=len(room),"More polygons were visited than fit")
            case 4:
                anywhere,_,any:=nav_random_point(&mesh,&filter,&rng)
                around,_,some:=nav_random_point_around(&q,&mesh,from,a,base.hostile_f32(&h),&filter,&rng)
                testing.expect(t,(!any || nav_ref_valid(&mesh,anywhere)) && (!some || nav_ref_valid(&mesh,around)),"A random point is on a polygon that is not of the mesh")
                _,_,_,_=nav_distance_to_wall(&q,&mesh,from,a,base.hostile_f32(&h),&filter)
                targets:=[2]Nav_Ref{to,Nav_Ref(base.hostile_next(&h))}
                _=nav_costs(&q,&mesh,from,a,&filter,targets[:base.hostile_int(&h,3)])
                if base.hostile_int(&h,3)==0 {_=nav_mesh_remove_tile(&mesh,{i32(base.hostile_int(&h,3)-1),i32(base.hostile_int(&h,3)-1)})}
                _,_=nav_cost_to(&q,&mesh,targets[base.hostile_int(&h,2)],b)
            case 5:
                link:=nav_mesh_add_link(&mesh,{start=a,end=b,radius=base.hostile_f32(&h),two_way=base.hostile_int(&h,2)==0,area=u8(base.hostile_int(&h,70)),cost=base.hostile_f32(&h),need={up=base.hostile_f32(&h)},owner=u64(base.hostile_int(&h,3))})
                if base.hostile_int(&h,3)==0 {_=nav_mesh_remove_link(&mesh,link)}
                if base.hostile_int(&h,4)==0 {_=nav_mesh_remove_links_of(&mesh,u64(base.hostile_int(&h,3)))}
                _=nav_mesh_remove_link(&mesh,Nav_Ref(base.hostile_next(&h)))
            case 6:
                _,_=nav_poly_height(&mesh,from,a)
                _,_=nav_closest_point_on_poly(&mesh,from,a)
                _,_,_=nav_portal_points(&mesh,from,to)
                _=nav_ref_valid(&mesh,Nav_Ref(base.hostile_next(&h)))
                jumps:[8]Nav_Jump_Link
                jump:=Nav_Jump{up=base.hostile_f32(&h),across=base.hostile_f32(&h),down=base.hostile_f32(&h),radius=base.hostile_f32(&h),climb=base.hostile_f32(&h),step=base.hostile_int(&h,3)==0?base.hostile_f32(&h):scale*0.25}
                found:=jumps[:base.hostile_int(&h,9)]
                links,_:=nav_jump_links(&mesh,{i32(base.hostile_int(&h,3)-1),i32(base.hostile_int(&h,3)-1)},jump,found)
                testing.expect(t,links>=0 && links<=len(found),"More jump links were found than fit")
                _=nav_jump_point({start=a,end=b,kind=Nav_Jump_Kind(base.hostile_int(&h,2))},base.hostile_f32(&h))
            case 7:
                _=nav_mesh_remove_tile(&mesh,{i32(base.hostile_int(&h,3)-1),i32(base.hostile_int(&h,3)-1)})
            case 8:
                region_of :: proc(user:rawptr,point:math.Vec3) -> u64 {return u64(point.x>0)+u64(point.z>0)*2}
                box:=math.Aabb{a,b}
                if base.hostile_int(&h,3)==0 {box={math.vec3_min(a,b),math.vec3_max(a,b)}}
                _,_,_=nav_coarse_build_region(&coarse,&mesh,&q,&filter,u64(base.hostile_int(&h,4)),base.hostile_next(&h),box,region_of,nil)
                out:[8]math.Vec3
                way:=out[:base.hostile_int(&h,9)]
                points,_:=nav_coarse_route(&coarse,&coarse_search,a,u64(base.hostile_int(&h,5)),b,u64(base.hostile_int(&h,5)),way)
                testing.expect(t,points>=0 && points<=len(way),"A coarse route has more points than fit")
                if base.hostile_int(&h,4)==0 {_=nav_coarse_remove(&coarse,u64(base.hostile_int(&h,4)))}
                if base.hostile_int(&h,4)==0 && len(coarse.portals)>0 {
                    // A graph scribbled over, as a damaged file gives.
                    coarse.portals[base.hostile_int(&h,len(coarse.portals))].edge_first=u32(base.hostile_next(&h))
                    _,_=nav_coarse_route(&coarse,&coarse_search,a,1,b,2,out[:])
                    copied:Nav_Coarse
                    _=nav_coarse_merge(&copied,&coarse)
                    nav_coarse_destroy(&copied)
                    nav_coarse_destroy(&coarse)
                }
            }
        }
        nav_query_destroy(&q)
        nav_mesh_destroy(&mesh)
    }
}

@(test)
hostile_meshes_through_the_navmesh :: proc(t:^testing.T) {nav_rounds(t,9,false)}

@(test)
hostile_finite_meshes_through_the_navmesh :: proc(t:^testing.T) {nav_rounds(t,19,true)}

@(test)
hostile_calls_through_an_empty_navmesh :: proc(t:^testing.T) {
    h:=base.Hostile{11}
    for _ in 0..<HOSTILE_ROUNDS/8 {
        mesh:Nav_Mesh
        q:Nav_Query
        filter:Nav_Filter
        path:[4]Nav_Ref
        corners:[4]Nav_Corner
        rng:=math.rng_make(1)
        a,b:=hostile_vec3(&h,true),hostile_vec3(&h,true)
        r:=Nav_Ref(base.hostile_next(&h))
        count,status,_:=nav_find_path(&q,&mesh,r,r,a,b,&filter,path[:])
        _,_,near:=nav_find_nearest_any(&mesh,a,b)
        _,_=nav_straight_path(&mesh,a,b,path[:],corners[:])
        _,walked:=nav_move_along_surface(&mesh,r,a,b,&filter,path[:])
        _,_,crossed:=nav_raycast(&mesh,r,a,b,&filter,path[:])
        _,_,any:=nav_random_point(&mesh,&filter,&rng)
        testing.expect(t,count==0 && status!=.Found && !near && walked==0 && crossed==0 && !any && !nav_ref_valid(&mesh,r),"An empty navmesh has polygons")
        _,_,_=nav_random_point_around(&q,&mesh,r,a,base.hostile_f32(&h),&filter,&rng)
        _,_,_,_=nav_distance_to_wall(&q,&mesh,r,a,base.hostile_f32(&h),&filter)
        _=nav_costs(&q,&mesh,r,a,&filter,path[:])
        _,_=nav_cost_to(&q,&mesh,r,b)
        _=nav_mesh_add_link(&mesh,{start=a,end=b})
        _=nav_mesh_remove_tile(&mesh,{})
        _=nav_mesh_add_tile(&mesh,{})
        _=nav_mesh_coord(&mesh,a)
        _,_=nav_tile_from_triangles({},{},nil,nil)
        _,_=nav_tile_from_triangles({},{},[]math.Vec3{{0,0,0}},[]u32{0,0,0})
        _,_=nav_tile_from_triangles({},{},[]math.Vec3{{0,0,0},{1,0,0},{0,0,1}},[]u32{0,1,2,0})
        data,made:=nav_tile_data_alloc(base.hostile_int(&h,40)-8,base.hostile_int(&h,40)-8,base.hostile_int(&h,9)-2,base.hostile_int(&h,9)-2,base.hostile_int(&h,9)-2)
        if made {
            clone,cloned:=nav_tile_data_clone(&data)
            if cloned {nav_tile_data_free(&clone)}
            if !nav_mesh_add_tile(&mesh,data) {nav_tile_data_free(&data)}
        }
        copied:Nav_Mesh
        _=nav_mesh_copy(&copied,&mesh)
        nav_mesh_destroy(&copied)
        coarse:Nav_Coarse
        search:Search
        out:[4]math.Vec3
        _,_,_=nav_coarse_build_region(&coarse,&mesh,&q,&filter,1,0,{a,b},nil,nil)
        _,_=nav_coarse_route(&coarse,&search,a,0,b,0,out[:])
        _=nav_coarse_remove(&coarse,0)
        _=nav_coarse_merge(&coarse,&coarse)
        nav_coarse_destroy(&coarse)
        nav_query_destroy(&q)
        nav_mesh_destroy(&mesh)
    }
}

@(test)
hostile_corridors_forged_and_followed :: proc(t:^testing.T) {
    h:=base.Hostile{24}
    mesh:Nav_Mesh
    _=nav_mesh_init(&mesh,{tile_width=2,climb=0.3,max_tiles=4,max_links=2})
    defer nav_mesh_destroy(&mesh)
    vertices:=[]math.Vec3{{0,0,0},{2,0,0},{2,0,2},{0,0,2}}
    for x in 0..<2 {
        moved:[4]math.Vec3
        for v,i in vertices {moved[i]=v+{f32(x)*2,0,0}}
        data,ok:=nav_tile_from_triangles({i32(x),0},{moved[0]+{0,-1,0},moved[2]+{0,1,0}},moved[:],[]u32{0,1,2,0,2,3})
        if ok && !nav_mesh_add_tile(&mesh,data) {nav_tile_data_free(&data)}
    }
    _=nav_mesh_add_link(&mesh,{start={1,0,1},end={3,0,1},radius=0.5})
    refs:[8]Nav_Ref
    n:=0
    for &tile in mesh.tiles {
        if !tile.used {continue}
        for i in 0..<len(tile.data.polys) {if n<len(refs) {refs[n]=nav_tile_ref(&mesh,&tile,i);n+=1}}
    }
    if n<len(refs) {refs[n]=nav_ref_link(mesh.links[0].salt,0,base.hostile_int(&h,2)==0);n+=1}
    filter:=Nav_Filter{can=base.hostile_int(&h,2)==0?NAV_CAN_ALL:{}}
    for _ in 0..<HOSTILE_ROUNDS {
        c:Nav_Corridor
        c.count=i32(base.hostile_int(&h,NAV_CORRIDOR_CAPACITY+4))-2
        if base.hostile_int(&h,8)==0 {c.count=i32(base.hostile_next(&h))}
        for &r in c.path[:base.hostile_int(&h,NAV_CORRIDOR_CAPACITY)] {r=refs[base.hostile_int(&h,max(n,1))] if base.hostile_int(&h,6)!=0 else Nav_Ref(base.hostile_next(&h))}
        c.position,c.target=hostile_nav_point(&h,2),hostile_nav_point(&h,2)
        corners:[4]Nav_Corner
        for _ in 0..<6 {
            switch base.hostile_int(&h,7) {
            case 0:
                room:=corners[:base.hostile_int(&h,5)]
                written:=nav_corridor_corners(&c,&mesh,room,base.hostile_f32(&h))
                testing.expect(t,written>=0 && written<=len(room),"A corridor writes more corners than fit")
            case 1: _=nav_corridor_move(&c,&mesh,&filter,hostile_nav_point(&h,2))
            case 2: c.count=i32(nav_path_straighten(&mesh,&filter,hostile_nav_point(&h,2),hostile_nav_point(&h,2),c.path[:],int(c.count)))
            case 3: _,_,_,_=nav_corridor_cross(&c,&mesh)
            case 4: _=nav_corridor_valid(&c,&mesh,&filter,base.hostile_int(&h,80)-4)
            case 5:
                if nav_corridor_set(&c,&mesh,&filter,hostile_nav_point(&h,2),refs[:base.hostile_int(&h,n+1)]) {
                    testing.expect(t,c.count>=1 && c.count<=NAV_CORRIDOR_CAPACITY,"A corridor that took a path does not hold it")
                }
            case 6:
                ref:=refs[base.hostile_int(&h,max(n,1))]
                nav_corridor_reset(&c,ref,hostile_nav_point(&h,2))
                testing.expect(t,c.count==1 && nav_corridor_first(&c)==ref && nav_corridor_last(&c)==ref,"A corridor that was reset is not its one polygon")
            }
            held:=c.count>0 && c.count<=NAV_CORRIDOR_CAPACITY
            testing.expect(t,len(nav_corridor_slice(&c))==(int(c.count) if held else 0 if c.count<=0 else NAV_CORRIDOR_CAPACITY),"The polygons of a corridor are those it can hold")
            testing.expect(t,(c.count>0 || nav_corridor_first(&c)==0) && (held || nav_corridor_last(&c)==0),"A corridor without a count it can hold has ends")
        }
    }
}

@(private="file")
hostile_steer_vec2 :: proc(t:^testing.T,h:^base.Hostile) {
    V :: math.Vec2
    // A force of numbers is no longer than the largest it was allowed.
    limited :: proc(force:V,max_force:f32,inputs:..V) -> bool {
        if !(max_force>=0 && max_force<=1e30) {return true}
        for input in inputs {if input-input!={} {return true}}
        return force-force=={} && linalg.length(force)<=max_force*1.001+1e-6
    }
    wild:=base.hostile_int(h,2)==0
    p,v,o:=hostile_vec2(h,wild),hostile_vec2(h,wild),hostile_vec2(h,wild)
    other:=hostile_vec2(h,wild)
    ms,mf:=base.hostile_f32(h),base.hostile_f32(h)
    numbers:=ms-ms==0
    testing.expect(t,!numbers || limited(seek(p,v,o,ms,mf),mf,p,v,o),"seek is stronger than its largest force")
    testing.expect(t,!numbers || limited(flee(p,v,o,ms,mf),mf,p,v,o),"flee is stronger than its largest force")
    slow:=base.hostile_f32(h)
    testing.expect(t,!numbers || slow-slow!=0 || limited(arrive(p,v,o,ms,mf,slow),mf,p,v,o),"arrive is stronger than its largest force")
    testing.expect(t,!numbers || slow-slow!=0 || limited(pursue(p,v,o,other,ms,mf,slow),mf,p,v,o,other),"pursue is stronger than its largest force")
    testing.expect(t,!numbers || slow-slow!=0 || limited(evade(p,v,o,other,ms,mf,slow),mf,p,v,o,other),"evade is stronger than its largest force")
    displacement:=hostile_vec2(h,wild)
    rng:=math.rng_make(base.hostile_next(h))
    a,b,c:=base.hostile_f32(h),base.hostile_f32(h),base.hostile_f32(h)
    testing.expect(t,a-a!=0 || b-b!=0 || c-c!=0 || limited(wander(&displacement,v,a,b,c,mf,&rng),mf,v,displacement),"wander is stronger than its largest force")
    kept:=displacement
    testing.expect(t,wander(&displacement,v,a,b,c,mf,nil)=={} && (displacement==kept || kept-kept!={}),"wander without a generator pushes, or moves its point")
    boids:[6]Boid(V)
    for &boid in boids {boid={hostile_vec2(h,wild),hostile_vec2(h,wild)}}
    n:=boids[:base.hostile_int(h,7)]
    radius:=base.hostile_f32(h)
    flock:=radius-radius==0
    for boid in n {flock&&=boid.position-boid.position=={} && boid.velocity-boid.velocity=={}}
    testing.expect(t,!flock || limited(separation(p,n,radius,mf),mf,p),"separation is stronger than its largest force")
    testing.expect(t,!flock || !numbers || limited(alignment(p,v,n,radius,ms,mf),mf,p,v),"alignment is stronger than its largest force")
    testing.expect(t,!flock || !numbers || limited(cohesion(p,v,n,radius,ms,mf),mf,p,v),"cohesion is stronger than its largest force")
    obstacles:[4]Obstacle(V)
    for &ob in obstacles {ob={hostile_vec2(h,wild),base.hostile_f32(h)}}
    blocked:=obstacles[:base.hostile_int(h,5)]
    ahead,size:=base.hostile_f32(h),base.hostile_f32(h)
    clear_numbers:=ahead-ahead==0 && size-size==0
    for ob in blocked {clear_numbers&&=ob.center-ob.center=={} && ob.radius-ob.radius==0}
    testing.expect(t,!clear_numbers || limited(avoid_obstacles(p,v,blocked,ahead,size,mf),mf,p,v),"avoid_obstacles is stronger than its largest force")
    _,_=steering_integrate(p,v,o,ms,base.hostile_f32(h))
    testing.expect(t,!numbers || ms<0 || p-p!={} || linalg.length(limit_length(p,ms))<=ms*1.001+1e-6,"limit_length is longer than its limit")
}

@(private="file")
hostile_steer_vec3 :: proc(t:^testing.T,h:^base.Hostile) {
    V :: math.Vec3
    // A force of numbers is no longer than the largest it was allowed.
    limited :: proc(force:V,max_force:f32,inputs:..V) -> bool {
        if !(max_force>=0 && max_force<=1e30) {return true}
        for input in inputs {if input-input!={} {return true}}
        return force-force=={} && linalg.length(force)<=max_force*1.001+1e-6
    }
    wild:=base.hostile_int(h,2)==0
    p,v,o:=hostile_vec3(h,wild),hostile_vec3(h,wild),hostile_vec3(h,wild)
    other:=hostile_vec3(h,wild)
    ms,mf:=base.hostile_f32(h),base.hostile_f32(h)
    numbers:=ms-ms==0
    testing.expect(t,!numbers || limited(seek(p,v,o,ms,mf),mf,p,v,o),"seek is stronger than its largest force")
    testing.expect(t,!numbers || limited(flee(p,v,o,ms,mf),mf,p,v,o),"flee is stronger than its largest force")
    slow:=base.hostile_f32(h)
    testing.expect(t,!numbers || slow-slow!=0 || limited(arrive(p,v,o,ms,mf,slow),mf,p,v,o),"arrive is stronger than its largest force")
    testing.expect(t,!numbers || slow-slow!=0 || limited(pursue(p,v,o,other,ms,mf,slow),mf,p,v,o,other),"pursue is stronger than its largest force")
    testing.expect(t,!numbers || slow-slow!=0 || limited(evade(p,v,o,other,ms,mf,slow),mf,p,v,o,other),"evade is stronger than its largest force")
    displacement:=hostile_vec3(h,wild)
    rng:=math.rng_make(base.hostile_next(h))
    a,b,c:=base.hostile_f32(h),base.hostile_f32(h),base.hostile_f32(h)
    testing.expect(t,a-a!=0 || b-b!=0 || c-c!=0 || limited(wander(&displacement,v,a,b,c,mf,&rng),mf,v,displacement),"wander is stronger than its largest force")
    kept:=displacement
    testing.expect(t,wander(&displacement,v,a,b,c,mf,nil)=={} && (displacement==kept || kept-kept!={}),"wander without a generator pushes, or moves its point")
    boids:[6]Boid(V)
    for &boid in boids {boid={hostile_vec3(h,wild),hostile_vec3(h,wild)}}
    n:=boids[:base.hostile_int(h,7)]
    radius:=base.hostile_f32(h)
    flock:=radius-radius==0
    for boid in n {flock&&=boid.position-boid.position=={} && boid.velocity-boid.velocity=={}}
    testing.expect(t,!flock || limited(separation(p,n,radius,mf),mf,p),"separation is stronger than its largest force")
    testing.expect(t,!flock || !numbers || limited(alignment(p,v,n,radius,ms,mf),mf,p,v),"alignment is stronger than its largest force")
    testing.expect(t,!flock || !numbers || limited(cohesion(p,v,n,radius,ms,mf),mf,p,v),"cohesion is stronger than its largest force")
    obstacles:[4]Obstacle(V)
    for &ob in obstacles {ob={hostile_vec3(h,wild),base.hostile_f32(h)}}
    blocked:=obstacles[:base.hostile_int(h,5)]
    ahead,size:=base.hostile_f32(h),base.hostile_f32(h)
    clear_numbers:=ahead-ahead==0 && size-size==0
    for ob in blocked {clear_numbers&&=ob.center-ob.center=={} && ob.radius-ob.radius==0}
    testing.expect(t,!clear_numbers || limited(avoid_obstacles(p,v,blocked,ahead,size,mf),mf,p,v),"avoid_obstacles is stronger than its largest force")
    _,_=steering_integrate(p,v,o,ms,base.hostile_f32(h))
    testing.expect(t,!numbers || ms<0 || p-p!={} || linalg.length(limit_length(p,ms))<=ms*1.001+1e-6,"limit_length is longer than its limit")
}

@(test)
hostile_values_through_the_steering :: proc(t:^testing.T) {
    h:=base.Hostile{12}
    for _ in 0..<HOSTILE_ROUNDS {
        hostile_steer_vec2(t,&h)
        hostile_steer_vec3(t,&h)
    }
}

@(test)
hostile_neighbors_through_the_avoidance :: proc(t:^testing.T) {
    h:=base.Hostile{13}
    neighbors:[dynamic]Avoid_Agent(2)
    flying:[dynamic]Avoid_Agent(3)
    defer {delete(neighbors);delete(flying)}
    for round in 0..<HOSTILE_ROUNDS {
        clear(&neighbors)
        wild:=round%3==0
        for _ in 0..<base.hostile_int(&h,40) {append(&neighbors,Avoid_Agent(2){hostile_vec2(&h,wild),hostile_vec2(&h,wild),wild?base.hostile_f32(&h):f32(base.hostile_int(&h,20))/10})}
        if base.hostile_int(&h,4)==0 && len(neighbors)>0 {
            for &n in neighbors {n.position=neighbors[0].position}
        }
        self:=Avoid_Agent(2){hostile_vec2(&h,wild),hostile_vec2(&h,wild),wild?base.hostile_f32(&h):f32(base.hostile_int(&h,20))/10}
        _=avoid_velocity(self,hostile_vec2(&h,wild),base.hostile_f32(&h),neighbors[:],base.hostile_f32(&h),base.hostile_f32(&h))
        speed:=f32(1+base.hostile_int(&h,5))
        walked:=avoid_velocity(self,hostile_vec2(&h,false),speed,neighbors[:],f32(1+base.hostile_int(&h,5)),0.1)
        // Among neighbors of numbers, the velocity is one, and no faster than the agent goes.
        testing.expectf(t,wild || (walked-walked=={} && linalg.length(walked)<=speed*1.001+1e-4),"An agent among %d neighbors walks at %v, faster than %v",len(neighbors),walked,speed)
        clear(&flying)
        for _ in 0..<base.hostile_int(&h,40) {append(&flying,Avoid_Agent(3){hostile_vec3(&h,wild),hostile_vec3(&h,wild),wild?base.hostile_f32(&h):f32(base.hostile_int(&h,20))/10})}
        if base.hostile_int(&h,4)==0 && len(flying)>0 {
            for &n in flying {n.position=flying[0].position}
        }
        bird:=Avoid_Agent(3){hostile_vec3(&h,wild),hostile_vec3(&h,wild),wild?base.hostile_f32(&h):f32(base.hostile_int(&h,20))/10}
        _=avoid_velocity(bird,hostile_vec3(&h,wild),base.hostile_f32(&h),flying[:],base.hostile_f32(&h),base.hostile_f32(&h))
        speed=f32(1+base.hostile_int(&h,5))
        flown:=avoid_velocity(bird,hostile_vec3(&h,false),speed,flying[:],f32(1+base.hostile_int(&h,5)),0.1)
        testing.expectf(t,wild || (flown-flown=={} && linalg.length(flown)<=speed*1.001+1e-4),"An agent among %d neighbors flies at %v, faster than %v",len(flying),flown,speed)
    }
}

@(private="file")
hostile_response :: proc(h:^base.Hostile) -> Response {
    return {kind=Response_Kind(base.hostile_int(h,base.hostile_int(h,10)==0?256:4)),degree=u8(base.hostile_int(h,base.hostile_int(h,10)==0?256:5)),slope=base.hostile_f32(h),shift_x=base.hostile_f32(h),shift_y=base.hostile_f32(h),invert=base.hostile_int(h,2)==0}
}

@(test)
hostile_considerations_through_the_utility :: proc(t:^testing.T) {
    h:=base.Hostile{22}
    considerations:[dynamic]Consideration
    inputs,scores:[dynamic]f32
    defer {delete(considerations);delete(inputs);delete(scores)}
    for _ in 0..<HOSTILE_ROUNDS {
        if testing.failed(t) {return}
        u:Utility
        max_actions:=base.hostile_int(&h,3)==0?hostile_count(&h):1+base.hostile_int(&h,8)
        if !utility_init(&u,{max_actions=max_actions,max_considerations=base.hostile_int(&h,3)==0?hostile_count(&h):base.hostile_int(&h,20)}) {
            utility_destroy(&u)
            continue
        }
        rng:=math.rng_make(base.hostile_next(&h))
        added:=0
        for _ in 0..<20 {
            clear(&considerations)
            for _ in 0..<base.hostile_int(&h,5) {append(&considerations,Consideration{input=u16(base.hostile_int(&h,base.hostile_int(&h,8)==0?70000:6)),min=base.hostile_f32(&h),max=base.hostile_f32(&h),response=hostile_response(&h)})}
            index:=utility_add_action(&u,u32(added),base.hostile_f32(&h),considerations[:])
            testing.expect(t,index==added || (index==-1 && (added>=max_actions || len(considerations)>0)),"An action gets the next index, or none when there is no room")
            if index==added {added+=1}
            resize(&inputs,base.hostile_int(&h,6))
            for &x in inputs {x=base.hostile_f32(&h)}
            resize(&scores,added+base.hostile_int(&h,3))
            outside:=added+base.hostile_int(&h,3) if base.hostile_int(&h,2)==0 else -1-base.hostile_int(&h,3)
            testing.expect(t,utility_score(&u,outside,inputs[:])==0,"An action that does not exist has a score")
            written:=utility_scores(&u,inputs[:],scores[:base.hostile_int(&h,len(scores)+1)])
            testing.expect(t,written>=0 && written<=added,"More scores were written than there are actions")
            testing.expect_value(t,utility_scores(&u,inputs[:],scores[:]),added)
            best,ordered:=f32(0),true
            for score in scores[:added] {
                ordered&&=score==score
                if score>best {best=score}
            }
            id,score,selected:=utility_select(&u,inputs[:])
            testing.expect(t,!ordered || (selected==(best>0) && (!selected || (score==best && int(id)<added))),"The action selected is not the one with the highest score above 0")
            picked,any:=utility_pick(&u,inputs[:],scores[:],&rng)
            testing.expect(t,!any || (int(picked)<added && (!ordered || best>0)),"An action was picked that has no score above 0")
            _,any=utility_pick(&u,inputs[:],scores[:],nil)
            testing.expect(t,!any,"An action was picked without a generator")
            curve,x:=hostile_response(&h),base.hostile_f32(&h)
            if y:=response_evaluate(curve,x);x==x && numbers_all(curve.slope,curve.shift_x,curve.shift_y) {
                testing.expectf(t,y>=0 && y<=1,"The response %v at %v left 0..1: %v",curve,x,y)
            }
        }
        utility_destroy(&u)
    }
}

@(private="file")
numbers_all :: proc(values:..f32) -> bool {
    for value in values {if value!=value {return false}}
    return true
}

@(test)
hostile_calls_through_an_empty_utility :: proc(t:^testing.T) {
    h:=base.Hostile{23}
    for _ in 0..<HOSTILE_ROUNDS/8 {
        u:Utility
        rng:=math.rng_make(1)
        scores:[4]f32
        inputs:[3]f32
        _,_,selected:=utility_select(&u,inputs[:])
        _,picked:=utility_pick(&u,inputs[:],scores[:],&rng)
        empty:=utility_add_action(&u,1,1,nil)==-1 && utility_add_action(&u,1,1,[]Consideration{{}})==-1 && utility_score(&u,base.hostile_int(&h,5)-2,inputs[:])==0
        testing.expect(t,empty && utility_scores(&u,inputs[:],scores[:])==0 && !selected && !picked,"A zeroed utility has actions")
        utility_destroy(&u)
        testing.expect(t,!utility_init(&u,{max_actions=0}) && !utility_init(&u,{max_actions=1,max_considerations=-1}),"A utility without room for an action, or with less than no considerations, was made")
        utility_destroy(&u)
    }
}

@(test)
hostile_unallocatable_sizes_through_the_inits :: proc(t:^testing.T) {
    size:=1<<44
    s:Search
    testing.expect(t,!search_init(&s,{nodes=size}))
    testing.expect(t,!search_init(&s,{nodes=4,open=size}))
    testing.expect(t,!search_init(&s,{nodes=4,max_edges=size}))
    o:Open_Set
    testing.expect(t,!open_init(&o,size,4))
    testing.expect(t,!open_init(&o,4,size))
    g:Grid
    testing.expect(t,!grid_init(&g,size,1))
    f:Flow_Field
    testing.expect(t,!flow_field_init(&f,size,1))
    u:Utility
    testing.expect(t,!utility_init(&u,{max_actions=size}))
    testing.expect(t,!utility_init(&u,{max_actions=1,max_considerations=size}))
    m:Nav_Mesh
    testing.expect(t,!nav_mesh_init(&m,{tile_width=1,max_tiles=size}))
    q:Nav_Query
    testing.expect(t,!nav_query_init(&q,size))
}

// Mostly small valid configs, now and then a wild value.
@(private="file")
hostile_nav_config :: proc "contextless" (h:^base.Hostile) -> Nav_Build_Config {
    pick :: proc "contextless" (h:^base.Hostile,tame:f32) -> f32 {return base.hostile_f32(h) if base.hostile_int(h,64)==0 else tame}
    count :: proc "contextless" (h:^base.Hostile,tame:int) -> i32 {return i32(base.hostile_int(h,1<<20)-(1<<19)) if base.hostile_int(h,64)==0 else i32(tame)}
    sizes:=[6]i32{-1,0,NAV_BUILD_MAX_CELLS,max(i32),min(i32),150}
    return {
        origin={pick(h,f32(base.hostile_int(h,9)-4)),pick(h,0),pick(h,f32(base.hostile_int(h,9)-4))},
        tile_size=sizes[base.hostile_int(h,6)] if base.hostile_int(h,32)==0 else i32(1+base.hostile_int(h,40)),
        cell_size=pick(h,0.1+f32(base.hostile_int(h,10))*0.05),
        cell_height=pick(h,0.05+f32(base.hostile_int(h,6))*0.05),
        agent_radius=pick(h,f32(base.hostile_int(h,8))*0.1),
        agent_height=pick(h,0.25+f32(base.hostile_int(h,8))*0.25),
        agent_climb=pick(h,f32(base.hostile_int(h,6))*0.1),
        agent_max_slope=pick(h,f32(base.hostile_int(h,16))*0.1),
        min_region_area=count(h,base.hostile_int(h,20)),
        merge_region_area=count(h,base.hostile_int(h,40)),
        max_edge_length=pick(h,f32(base.hostile_int(h,8))*0.5),
        max_edge_error=pick(h,f32(base.hostile_int(h,8))*0.1),
        detail_sample_distance=pick(h,f32(base.hostile_int(h,8))*0.25),
        detail_max_error=pick(h,f32(base.hostile_int(h,6))*0.05),
    }
}

@(private="file")
hostile_nav_quad :: proc(vertices:^[dynamic]math.Vec3,indices:^[dynamic]u32,a,b,c,d:math.Vec3) {
    first:=u32(len(vertices))
    append(vertices,a,b,c,d)
    append(indices,first,first+1,first+2,first,first+2,first+3)
}

// Boxes, floors, ramps and loose triangles over the tile, with coordinates
// that are sometimes wild, indices that are sometimes broken, areas of any
// length and volumes of any shape.
@(private="file")
hostile_nav_input :: proc(h:^base.Hostile,vertices:^[dynamic]math.Vec3,indices:^[dynamic]u32,areas:^[dynamic]u8,volumes:^[dynamic]Nav_Area_Volume) -> Nav_Build_Input {
    clear(vertices);clear(indices);clear(areas);clear(volumes)
    wild:=base.hostile_int(h,6)==0
    point :: proc "contextless" (h:^base.Hostile,wild:bool) -> math.Vec3 {
        if wild && base.hostile_int(h,4)==0 {return hostile_vec3(h,true)}
        p:=hostile_vec3(h,false)
        return {p.x+3,p.y*0.3,p.z+3}
    }
    count:=base.hostile_int(h,200) if base.hostile_int(h,8)==0 else base.hostile_int(h,16)
    for _ in 0..<count {
        p,q:=point(h,wild),point(h,wild)
        low,high:=math.vec3_min(p,q),math.vec3_max(p,q)
        switch base.hostile_int(h,4) {
        case 0:
            first:=u32(len(vertices))
            append(vertices,p,q,point(h,wild))
            append(indices,first,first+1,first+2)
        case 1:
            hostile_nav_quad(vertices,indices,{low.x,high.y,low.z},{low.x,high.y,high.z},{high.x,high.y,high.z},{high.x,high.y,low.z})
            hostile_nav_quad(vertices,indices,{low.x,low.y,low.z},{low.x,high.y,low.z},{high.x,high.y,low.z},{high.x,low.y,low.z})
            hostile_nav_quad(vertices,indices,{low.x,low.y,high.z},{high.x,low.y,high.z},{high.x,high.y,high.z},{low.x,high.y,high.z})
            hostile_nav_quad(vertices,indices,{low.x,low.y,low.z},{low.x,low.y,high.z},{low.x,high.y,high.z},{low.x,high.y,low.z})
            hostile_nav_quad(vertices,indices,{high.x,low.y,low.z},{high.x,high.y,low.z},{high.x,high.y,high.z},{high.x,low.y,high.z})
        case 2:
            hostile_nav_quad(vertices,indices,{p.x-4,p.y,p.z-4},{p.x-4,p.y,p.z+4},{p.x+4,p.y,p.z+4},{p.x+4,p.y,p.z-4})
        case 3:
            hostile_nav_quad(vertices,indices,{p.x,p.y,p.z},{p.x,p.y,q.z},{q.x,q.y,q.z},{q.x,q.y,p.z})
        }
    }
    if base.hostile_int(h,4)==0 {
        for _ in 0..<len(indices)/3 {append(areas,u8(base.hostile_int(h,4)))}
    }
    ring_x:=[8]f32{1,0.7,0,-0.7,-1,-0.7,0,0.7}
    ring_z:=[8]f32{0,0.7,1,0.7,0,-0.7,-1,-0.7}
    for _ in 0..<base.hostile_int(h,4) {
        v:Nav_Area_Volume
        v.count=u8(base.hostile_int(h,9))
        center:=hostile_vec2(h,false)+{3,3}
        for k in 0..<8 {
            radius:=f32(base.hostile_int(h,5)+1)
            v.points[k]=hostile_vec2(h,true) if wild && base.hostile_int(h,6)==0 else center+{ring_x[k],ring_z[k]}*radius
        }
        v.area=u8(base.hostile_int(h,4))
        v.min_y=base.hostile_f32(h) if wild else f32(base.hostile_int(h,5))-2
        v.max_y=base.hostile_f32(h) if wild else v.min_y+f32(base.hostile_int(h,4))
        append(volumes,v)
    }
    // One broken value now and then.
    switch base.hostile_int(h,48) {
    case 0: if len(indices)>0 {pop(indices)}
    case 1: append(indices,u32(len(vertices)+base.hostile_int(h,3)))
    case 2: if len(areas)>0 {pop(areas)} else {append(areas,1)}
    case 3: if len(areas)>0 {areas[base.hostile_int(h,len(areas))]=NAV_AREA_MAX+1}
    case 4: if len(volumes)>0 {volumes[0].count=9+u8(base.hostile_int(h,200))}
    case 5: if len(volumes)>0 {volumes[0].area=NAV_AREA_MAX+1+u8(base.hostile_int(h,100))}
    }
    return {vertices=vertices[:],indices=indices[:],triangle_areas=areas[:],volumes=volumes[:]}
}

@(private="file")
hostile_nav_tile_holds :: proc(t:^testing.T,data:^Nav_Tile_Data) {
    for p,i in data.polys {
        if !testing.expect(t,p.count>=3 && int(p.count)<=NAV_VERTS_PER_POLY,"polygon size") {return}
        for k in 0..<int(p.count) {
            testing.expect(t,int(p.vertices[k])<len(data.vertices),"vertex out of range")
            n:=p.neighbor[k]
            testing.expect(t,n==NAV_EDGE_WALL || n&NAV_EDGE_PORTAL!=0 && n&~NAV_EDGE_PORTAL<4 || int(n)-1<len(data.polys),"neighbor out of range")
        }
        d:=data.details[i]
        if !testing.expect(t,int(d.triangle_first)+int(d.triangle_count)<=len(data.detail_triangles) && int(d.vertex_first)+int(d.vertex_count)<=len(data.detail_vertices),"detail out of range") {return}
        for tri in data.detail_triangles[d.triangle_first:][:d.triangle_count] {
            testing.expect(t,int(max(tri[0],tri[1],tri[2]))<int(p.count)+int(d.vertex_count),"detail triangle out of range")
        }
    }
    testing.expect(t,len(data.bv)==2*len(data.polys)-1,"tree size")
}

@(test)
hostile_triangles_through_the_tile_build :: proc(t:^testing.T) {
    h:=base.Hostile{24}
    vertices:[dynamic]math.Vec3
    indices:[dynamic]u32
    areas:[dynamic]u8
    volumes:[dynamic]Nav_Area_Volume
    defer {delete(vertices);delete(indices);delete(areas);delete(volumes)}
    scratch:Nav_Build_Scratch
    nav_build_scratch_init(&scratch)
    defer nav_build_scratch_destroy(&scratch)
    coords:=[5][2]i32{{0,0},{1,0},{-1,-1},{max(i32),min(i32)},{min(i32),3}}
    for _ in 0..<HOSTILE_ROUNDS {
        config:=hostile_nav_config(&h)
        input:=hostile_nav_input(&h,&vertices,&indices,&areas,&volumes)
        coord:=coords[base.hostile_int(&h,5)] if base.hostile_int(&h,8)==0 else [2]i32{}
        data:Nav_Tile_Data
        if nav_build_tile(config,coord,input,&scratch,&data)==.Built {hostile_nav_tile_holds(t,&data)}
        nav_tile_data_free(&data)
        _=nav_tile_rect(config,coord)
        _=nav_build_margin(config)
    }
}

// More floors in a column than a link names, heights beyond the span range
// and the largest heightfield.
@(test)
hostile_extreme_tiles_through_the_tile_build :: proc(t:^testing.T) {
    vertices:[dynamic]math.Vec3
    indices:[dynamic]u32
    defer {delete(vertices);delete(indices)}
    scratch:Nav_Build_Scratch
    nav_build_scratch_init(&scratch)
    defer nav_build_scratch_destroy(&scratch)
    config:=Nav_Build_Config{tile_size=24,cell_size=0.25,cell_height=0.05,agent_radius=0.25,agent_height=0.2,agent_climb=0.1,agent_max_slope=0.7,min_region_area=4,merge_region_area=10,max_edge_length=2,max_edge_error=0.3,detail_sample_distance=1,detail_max_error=0.05}
    for k in 0..<100 {hostile_nav_quad(&vertices,&indices,{-2,f32(k)*0.3,-2},{-2,f32(k)*0.3,8},{8,f32(k)*0.3,8},{8,f32(k)*0.3,-2})}
    hostile_nav_quad(&vertices,&indices,{-2,1e4,-2},{-2,1e4,8},{8,1e4,8},{8,1e4,-2})
    hostile_nav_quad(&vertices,&indices,{-2,-3e4,-2},{-2,-3e4,8},{8,-3e4,8},{8,-3e4,-2})
    data:Nav_Tile_Data
    if nav_build_tile(config,{},{vertices=vertices[:],indices=indices[:]},&scratch,&data)==.Built {hostile_nav_tile_holds(t,&data)}
    nav_tile_data_free(&data)
    clear(&vertices);clear(&indices)
    hostile_nav_quad(&vertices,&indices,{1,0,1},{1,0,9},{9,0,9},{9,0,1})
    config.cell_size=1
    config.tile_size=NAV_BUILD_MAX_CELLS-2*(1+3)
    if testing.expect_value(t,nav_build_tile(config,{},{vertices=vertices[:],indices=indices[:]},&scratch,&data),Nav_Build_Status.Built) {
        hostile_nav_tile_holds(t,&data)
    }
    nav_tile_data_free(&data)
    config.tile_size+=1
    testing.expect_value(t,nav_build_tile(config,{},{vertices=vertices[:],indices=indices[:]},&scratch,&data),Nav_Build_Status.Invalid)
}

@(test)
hostile_scratch_and_tiles_through_the_tile_build :: proc(t:^testing.T) {
    h:=base.Hostile{25}
    vertices:[dynamic]math.Vec3
    indices:[dynamic]u32
    areas:[dynamic]u8
    volumes:[dynamic]Nav_Area_Volume
    defer {delete(vertices);delete(indices);delete(areas);delete(volumes)}
    for _ in 0..<HOSTILE_ROUNDS/8 {
        input:=hostile_nav_input(&h,&vertices,&indices,&areas,&volumes)
        scratch:Nav_Build_Scratch
        data:Nav_Tile_Data
        testing.expect(t,nav_build_tile(hostile_nav_config(&h),{},input,&scratch,&data)!=.Built && len(data.polys)==0,"A tile was built with a scratch that was never made")
        testing.expect(t,nav_build_tile(hostile_nav_config(&h),{},input,nil,&data)!=.Built && len(data.polys)==0,"A tile was built without a scratch")
        testing.expect(t,nav_build_tile(hostile_nav_config(&h),{},input,&scratch,nil)!=.Built,"A tile was built into nothing")
        starved:=base.hostile_int(&h,2)==0
        nav_build_scratch_init(&scratch,runtime.nil_allocator() if starved else context.allocator)
        failing:=runtime.nil_allocator() if base.hostile_int(&h,3)==0 else context.allocator
        starved||=failing.procedure==runtime.nil_allocator().procedure
        status:=nav_build_tile(hostile_nav_config(&h),{},input,&scratch,&data,failing)
        if status==.Built {
            testing.expect(t,!starved,"A tile was built without memory")
            hostile_nav_tile_holds(t,&data)
        } else {
            testing.expect(t,len(data.polys)==0 && len(data.vertices)==0,"A tile that was not built has polygons")
        }
        nav_tile_data_free(&data)
        nav_build_scratch_destroy(&scratch)
        nav_build_scratch_destroy(&scratch)
        nav_tile_data_free(&data)
    }
}

@(test)
hostile_memories_and_places :: proc(t:^testing.T) {
    h:=base.Hostile{31}
    for _ in 0..<HOSTILE_ROUNDS {
        if testing.failed(t) {return}
        m:Perception_Memory
        // A count that was forged only has to be survived; an honest memory is held to its contract.
        forged:=base.hostile_int(&h,6)==0
        if forged {m.count=i32(base.hostile_next(&h))}
        gone:[4]u64
        for _ in 0..<24 {
            subject:=u64(base.hostile_int(&h,20))
            before:=m.count
            switch base.hostile_int(&h,4) {
            case 0,1:
                change:=memory_perceive(&m,subject,hostile_vec3(&h,true),Sense(base.hostile_int(&h,3)),base.hostile_f32(&h),f64(base.hostile_f32(&h)))
                known:=memory_find(&m,subject)
                testing.expect(t,forged || ((change==.None || known!=nil) && (change!=.New || m.count==before+1 || before==PERCEPTION_CAPACITY)),"A subject that was perceived is not remembered")
            case 2:
                room:=gone[:base.hostile_int(&h,5)]
                count:=memory_forget(&m,f64(base.hostile_f32(&h)),base.hostile_f32(&h),room)
                testing.expect(t,forged || (count>=0 && int(m.count)==int(before)-count),"What a memory forgot is not what it lost")
                for lost in room[:clamp(count,0,len(room))] {testing.expect(t,forged || memory_find(&m,lost)==nil,"A forgotten subject is remembered")}
            case 3:
                found:=memory_find(&m,subject)
                _,any:=memory_best(&m,hostile_vec3(&h,true))
                testing.expect(t,forged || ((found==nil || found.subject==subject) && any==(m.count>0)),"A memory finds another subject, or has a best one exactly while it remembers")
            }
            if !testing.expect(t,forged || (m.count>=0 && m.count<=PERCEPTION_CAPACITY),"A memory remembers more than it holds") {break}
        }
        eye,point:=hostile_vec3(&h,false),hostile_vec3(&h,false)
        range:=f32(base.hostile_int(&h,20))
        testing.expect(t,sight_in_cone(eye,hostile_vec3(&h,true),point,range,4)==(linalg.length(point-eye)<=range) || abs(linalg.length(point-eye)-range)<1e-3,"All around, a point is seen exactly when it is in range")
        _=sight_in_cone(hostile_vec3(&h,true),hostile_vec3(&h,true),hostile_vec3(&h,true),base.hostile_f32(&h),base.hostile_f32(&h))
        points:[32]math.Vec3
        room:=points[:base.hostile_int(&h,33)]
        written:=places_rings(hostile_vec3(&h,true),base.hostile_f32(&h),base.hostile_f32(&h),base.hostile_int(&h,6)-1,base.hostile_int(&h,40)-1,room)
        testing.expect(t,written>=0 && written<=len(room),"More ring points were written than fit")
        room=points[:base.hostile_int(&h,33)]
        written=places_grid(hostile_vec3(&h,true),base.hostile_f32(&h),base.hostile_f32(&h),room)
        testing.expect(t,written>=0 && written<=len(room),"More grid points were written than fit")
        inputs:[12]f32
        for &x in inputs {x=base.hostile_f32(&h)}
        considerations:=[2]Consideration{{input=u16(base.hostile_int(&h,20)),min=base.hostile_f32(&h),max=base.hostile_f32(&h),response={kind=Response_Kind(base.hostile_int(&h,4)),slope=base.hostile_f32(&h)}},{}}
        best:[4]Place_Score
        given,stride:=inputs[:base.hostile_int(&h,13)],base.hostile_int(&h,5)-1
        kept:=places_best(considerations[:base.hostile_int(&h,3)],given,stride,best[:base.hostile_int(&h,5)])
        if !testing.expect(t,kept>=0 && kept<=len(best) && (kept==0 || stride>0),"More places were kept than fit, or without inputs for each") {continue}
        for place,i in best[:kept] {
            testing.expect(t,place.score>0 && place.index>=0 && int(place.index)<len(given)/stride && (i==0 || place.score<=best[i-1].score),"The places kept are not candidates with a score, best first")
        }
    }
}
