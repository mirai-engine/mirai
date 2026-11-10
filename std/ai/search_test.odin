package ai

import "core:testing"

near :: proc(a,b:f32,eps:f32=1e-4) -> bool {return abs(a-b)<=eps}
near_vec :: proc(a,b:$V/[$N]f32,eps:f32=1e-4) -> bool {
    for i in 0..<N {if abs(a[i]-b[i])>eps {return false}}
    return true
}

@(test)
open_set_pops_in_key_order_and_moves_improved_nodes :: proc(t:^testing.T) {
    open:Open_Set
    testing.expect(t,open_init(&open,8,8))
    defer open_destroy(&open)
    for key,node in ([]f32{5,3,8,1,9,2}) {testing.expect(t,open_push(&open,u32(node),key))}
    testing.expect(t,open_push(&open,2,0.5)) // lower: moves up
    testing.expect(t,open_push(&open,4,100)) // higher: ignored
    testing.expect(t,open_contains(&open,4) && !open_contains(&open,7))
    order:[8]u32
    count:=0
    for {
        node,_,ok:=open_pop(&open)
        if !ok {break}
        order[count]=node;count+=1
    }
    testing.expect_value(t,count,6)
    testing.expect(t,order[0]==2 && order[1]==3 && order[2]==5 && order[3]==1 && order[4]==0 && order[5]==4)
    testing.expect(t,!open_contains(&open,2))
}

@(test)
open_set_refuses_new_nodes_when_full_and_after_clear_starts_empty :: proc(t:^testing.T) {
    open:Open_Set
    testing.expect(t,open_init(&open,6,2))
    defer open_destroy(&open)
    testing.expect(t,open_push(&open,0,1) && open_push(&open,1,2))
    testing.expect(t,!open_push(&open,2,0))
    testing.expect(t,open_push(&open,1,0.5)) // an open node can still improve
    testing.expect(t,!open_push(&open,99,1))
    testing.expect_value(t,open.failed,u64(1))
    testing.expect_value(t,open.peak,2)
    open_clear(&open)
    testing.expect(t,open.count==0 && !open_contains(&open,0) && !open_contains(&open,1))
    testing.expect(t,open_push(&open,2,3))
    _,_,empty:=open_pop(&open)
    _,_,none:=open_pop(&open)
    testing.expect(t,empty && !none)
    bad:Open_Set
    testing.expect(t,!open_init(&bad,0,4) && !open_init(&bad,4,0))
    testing.expect(t,!open_push(&bad,0,1))
    _,_,nothing:=open_pop(&bad)
    testing.expect(t,!nothing)
}

// A space given by procedures of the test: `neighbors` writes the edges of a
// node, `heuristic` estimates the cost from a node to the goal (nil: none).
Graph :: struct {
    user:rawptr,
    neighbors:proc(user:rawptr,node:u64,edges:^Edge_List),
    heuristic:proc(user:rawptr,node,goal:u64) -> f32,
}
graph_neighbors :: proc(graph:Graph,node:u64,edges:^Edge_List) {graph.neighbors(graph.user,node,edges)}
graph_heuristic :: proc(graph:Graph,node,goal:u64) -> f32 {
    if graph.heuristic==nil {return 0}
    return graph.heuristic(graph.user,node,goal)
}
// The cheapest path from start to goal, with its nodes written to `out`.
graph_find_path :: proc(s:^Search,graph:Graph,start,goal:u64,out:[]u64) -> (count:int,status:Search_Status) {
    if graph.neighbors==nil {return 0,.Invalid}
    status=search_run(s,start,goal,graph,graph_neighbors,graph_heuristic)
    if status!=.Found {return 0,status}
    return search_path(s,out)
}

// A graph of explicit edges: node i connects to list[i].
Edges_Of :: struct {edges:[][]Edge}

edges_of :: proc(user:rawptr,node:u64,list:^Edge_List) {
    graph:=cast(^Edges_Of)user
    for edge in graph.edges[node] {edge_add(list,edge.to,edge.cost)}
}

@(test)
graph_search_chooses_the_cheapest_path :: proc(t:^testing.T) {
    edges:=[][]Edge{{{to=1,cost=1},{to=2,cost=5}},{{to=3,cost=1}},{{to=3,cost=1}},{{to=4,cost=1}},{}}
    data:=Edges_Of{edges}
    s:Search
    testing.expect(t,search_init(&s,{nodes=5}))
    defer search_destroy(&s)
    path:[8]u64
    count,status:=graph_find_path(&s,{user=&data,neighbors=edges_of},0,4,path[:])
    testing.expect(t,status==.Found && count==4 && path[0]==0 && path[1]==1 && path[2]==3 && path[3]==4)
    testing.expect(t,near(search_cost(&s),3))
    count,status=graph_find_path(&s,{user=&data,neighbors=edges_of},2,2,path[:])
    testing.expect(t,status==.Found && count==1 && path[0]==2)
    count,status=graph_find_path(&s,{user=&data,neighbors=edges_of},4,0,path[:])
    testing.expect(t,status==.No_Path && count==0)
    _,after:=search_path(&s,path[:])
    testing.expect_value(t,after,Search_Status.Invalid)
}

@(test)
graph_search_reports_invalid_nodes_and_short_outputs :: proc(t:^testing.T) {
    edges:=[][]Edge{{{to=1,cost=1}},{{to=2,cost=1}},{}}
    data:=Edges_Of{edges}
    s:Search
    testing.expect(t,search_init(&s,{nodes=3}))
    defer search_destroy(&s)
    path:[2]u64
    _,status:=graph_find_path(&s,{user=&data,neighbors=edges_of},0,7,path[:])
    testing.expect_value(t,status,Search_Status.Invalid)
    _,status=graph_find_path(&s,{user=&data},0,1,path[:])
    testing.expect_value(t,status,Search_Status.Invalid)
    count,status2:=graph_find_path(&s,{user=&data,neighbors=edges_of},0,2,path[:])
    testing.expect(t,status2==.Output_Full && count==0)
    count,status2=graph_find_path(&s,{user=&data,neighbors=edges_of},0,1,path[:])
    testing.expect(t,status2==.Found && count==2)
    other:Search
    testing.expect(t,!search_init(&other,{}))
    _,status=graph_find_path(&other,{user=&data,neighbors=edges_of},0,1,path[:])
    testing.expect_value(t,status,Search_Status.Invalid)
}

wide_edges :: proc(user:rawptr,node:u64,list:^Edge_List) {
    if node==0 {for i in 1..<u64(10) {edge_add(list,i,1)}}
}

@(test)
search_reports_a_full_open_set_and_edge_overflow :: proc(t:^testing.T) {
    s:Search
    testing.expect(t,search_init(&s,{nodes=10,open=3,max_edges=4}))
    defer search_destroy(&s)
    path:[4]u64
    _,status:=graph_find_path(&s,{neighbors=wide_edges},0,9,path[:])
    testing.expect_value(t,status,Search_Status.Open_Full)
    testing.expect_value(t,s.stats.open_full,u64(1))
    testing.expect(t,s.stats.peak_open<=3)
    big:Search
    testing.expect(t,search_init(&big,{nodes=10,max_edges=4}))
    defer search_destroy(&big)
    _,status=graph_find_path(&big,{neighbors=wide_edges},0,9,path[:]) // only 4 edges fit: node 9 is never offered
    testing.expect_value(t,status,Search_Status.No_Path)
    list:=Edge_List{items=big.edges}
    wide_edges(nil,0,&list)
    testing.expect(t,list.count==4 && list.dropped==5)
}

@(test)
search_survives_the_generation_counter_wrapping :: proc(t:^testing.T) {
    edges:=[][]Edge{{{to=1,cost=1}},{{to=2,cost=1}},{}}
    data:=Edges_Of{edges}
    s:Search
    testing.expect(t,search_init(&s,{nodes=3}))
    defer search_destroy(&s)
    s.generation=max(u32)-1
    path:[3]u64
    for _ in 0..<4 {
        count,status:=graph_find_path(&s,{user=&data,neighbors=edges_of},0,2,path[:])
        testing.expect(t,status==.Found && count==3)
    }
    testing.expect(t,s.generation<4)
    testing.expect_value(t,s.stats.searches,u64(4))
}

estimate_to :: proc(user:rawptr,node,goal:u64) -> f32 {return f32(abs(int(goal)-int(node)))}
line_edges :: proc(user:rawptr,node:u64,list:^Edge_List) {
    if node>0 {edge_add(list,node-1,1)}
    if node<19 {edge_add(list,node+1,1)}
}

@(test)
a_good_heuristic_expands_fewer_nodes_than_none :: proc(t:^testing.T) {
    s:Search
    testing.expect(t,search_init(&s,{nodes=20}))
    defer search_destroy(&s)
    path:[20]u64
    count,status:=graph_find_path(&s,{neighbors=line_edges},5,15,path[:])
    blind:=s.stats.expanded
    testing.expect(t,status==.Found && count==11)
    count,status=graph_find_path(&s,{neighbors=line_edges,heuristic=estimate_to},5,15,path[:])
    testing.expect(t,status==.Found && count==11 && near(search_cost(&s),10))
    testing.expect(t,s.stats.expanded<blind && s.stats.expanded==10)
}

// Keys far apart, as the polygons of a tiled navmesh: node i is i<<40.
sparse_edges :: proc(user:rawptr,node:u64,list:^Edge_List) {
    i:=node>>40
    if i>0 {edge_add(list,(i-1)<<40,1)}
    if i<19 {edge_add(list,(i+1)<<40,1)}
}

@(test)
a_keyed_search_finds_paths_over_sparse_keys :: proc(t:^testing.T) {
    s:Search
    testing.expect(t,search_init(&s,{nodes=32,keyed=true}))
    defer search_destroy(&s)
    path:[20]u64
    count,status:=graph_find_path(&s,{neighbors=sparse_edges},u64(3)<<40,u64(12)<<40,path[:])
    testing.expect(t,status==.Found && count==10 && near(search_cost(&s),9))
    for key,i in path[:count] {testing.expect_value(t,key,u64(3+i)<<40)}
    parent,ok:=search_parent(&s,u64(5)<<40)
    testing.expect(t,ok && parent==u64(4)<<40)
    _,ok=search_parent(&s,u64(3)<<40)
    testing.expect(t,!ok)
}

@(test)
a_keyed_search_out_of_slots_is_open_full :: proc(t:^testing.T) {
    s:Search
    testing.expect(t,search_init(&s,{nodes=4,keyed=true}))
    defer search_destroy(&s)
    path:[20]u64
    _,status:=graph_find_path(&s,{neighbors=sparse_edges},0,u64(10)<<40,path[:])
    testing.expect_value(t,status,Search_Status.Open_Full)
    count:int
    count,status=graph_find_path(&s,{neighbors=sparse_edges},0,u64(2)<<40,path[:])
    testing.expect(t,status==.Found && count==3)
}

Step_Count :: struct {accepted:int}
step_count_neighbors :: proc(space:^Step_Count,node:u64,list:^Edge_List) {line_edges(nil,node,list)}
step_count_heuristic :: proc(space:^Step_Count,node,goal:u64) -> f32 {return 0}
step_count_accept :: proc(space:^Step_Count,slot:u32,edge:Edge) {space.accepted+=1}

@(test)
a_search_in_steps_ends_where_a_whole_one_does :: proc(t:^testing.T) {
    s:Search
    testing.expect(t,search_init(&s,{nodes=20}))
    defer search_destroy(&s)
    space:Step_Count
    status:=search_begin(&s,5,15,&space,step_count_heuristic)
    steps:=0
    for status==.Running {
        status=search_step(&s,&space,step_count_neighbors,step_count_heuristic,step_count_accept,3)
        steps+=1
    }
    testing.expect(t,status==.Found && near(search_cost(&s),10) && steps>1)
    testing.expect(t,space.accepted>=10)
    testing.expect_value(t,search_step(&s,&space,step_count_neighbors,step_count_heuristic,step_count_accept,3),Search_Status.Found)
}
