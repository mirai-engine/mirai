package ai

import "base:runtime"

// A*. The open set is an indexed binary heap of fixed capacity: a node is in
// it at most once and improving its cost moves it, so the capacity needed is
// the number of nodes that are open at once, never the number of relaxations.
// The same loop searches every space: navigation meshes, volumes, the coarse
// graph of portals.
//
// Nodes are named by u64 keys. A dense search takes the key as the slot of the
// node, below its capacity (the portals of a coarse graph). A keyed search gives the first
// keys a search reaches a slot each through a hash table, so the keys may be
// sparse (polygons of a tiled navmesh, hashed planning states) and the
// capacity bounds the nodes one search reaches.

// Min-heap of slots keyed by an f32. `slot` is the position of each slot in
// the heap, or -1.
Open_Set :: struct {
    node:[]u32,
    key:[]f32,
    slot:[]i32,
    count,peak:int,
    failed:u64, // insertions refused for lack of room
    allocator:runtime.Allocator,
}

// Slots are u32 and heap positions i32: more nodes or capacity than those hold fail.
open_init :: proc(open:^Open_Set,nodes,capacity:int,allocator:=context.allocator) -> bool {
    open^={allocator=allocator}
    if nodes<=0 || capacity<=0 || nodes>int(max(u32)) || capacity>int(max(i32)) {return false}
    e1,e2,e3:runtime.Allocator_Error
    open.node,e1=make([]u32,capacity,allocator)
    open.key,e2=make([]f32,capacity,allocator)
    open.slot,e3=make([]i32,nodes,allocator)
    if e1!=nil || e2!=nil || e3!=nil {open_destroy(open);return false}
    for &slot in open.slot {slot=-1}
    return true
}
open_destroy :: proc(open:^Open_Set) {
    if open.allocator.procedure==nil {open^={};return}
    delete(open.node,open.allocator);delete(open.key,open.allocator);delete(open.slot,open.allocator)
    open^={}
}
open_clear :: proc "contextless" (open:^Open_Set) {
    for i in 0..<open.count {open.slot[open.node[i]]=-1}
    open.count=0
}
open_contains :: #force_inline proc "contextless" (open:^Open_Set,node:u32) -> bool {return int(node)<len(open.slot) && open.slot[node]>=0}

// Inserts the node, or lowers its key when it is already open (a higher key is
// ignored). False when it is new and the heap is full or the id is out of range.
open_push :: proc "contextless" (open:^Open_Set,node:u32,key:f32) -> bool {
    if int(node)>=len(open.slot) {return false}
    index:=int(open.slot[node])
    if index>=0 {
        // Not lower: higher, equal, or a NaN, which has no order.
        if !(key<open.key[index]) {return true}
        open.key[index]=key
        open_up(open,index)
        return true
    }
    if open.count>=len(open.node) {open.failed+=1;return false}
    index=open.count
    open.count+=1
    open.peak=max(open.peak,open.count)
    open.node[index]=node;open.key[index]=key;open.slot[node]=i32(index)
    open_up(open,index)
    return true
}
open_pop :: proc "contextless" (open:^Open_Set) -> (node:u32,key:f32,ok:bool) {
    if open.count==0 {return}
    node,key=open.node[0],open.key[0]
    open.slot[node]=-1
    open.count-=1
    if open.count>0 {
        last:=open.count
        open.node[0]=open.node[last];open.key[0]=open.key[last]
        open.slot[open.node[0]]=0
        open_down(open,0)
    }
    return node,key,true
}
@(private)
open_swap :: #force_inline proc "contextless" (open:^Open_Set,a,b:int) {
    open.node[a],open.node[b]=open.node[b],open.node[a]
    open.key[a],open.key[b]=open.key[b],open.key[a]
    open.slot[open.node[a]]=i32(a);open.slot[open.node[b]]=i32(b)
}
@(private)
open_up :: proc "contextless" (open:^Open_Set,from:int) {
    index:=from
    for index>0 {
        parent:=(index-1)>>1
        if open.key[parent]<=open.key[index] {break}
        open_swap(open,parent,index)
        index=parent
    }
}
@(private)
open_down :: proc "contextless" (open:^Open_Set,from:int) {
    index:=from
    for {
        child:=index*2+1
        if child>=open.count {break}
        if child+1<open.count && open.key[child+1]<open.key[child] {child+=1}
        if open.key[index]<=open.key[child] {break}
        open_swap(open,index,child)
        index=child
    }
}

Edge :: struct {
    to:u64,
    cost:f32,
    data:u32, // for the space: what the step is, handed back when the search accepts it
}
// Where a neighbors callback writes the edges of a node. Edges past its
// capacity are counted in `dropped` and ignored.
Edge_List :: struct {
    items:[]Edge,
    count,dropped:int,
}
edge_add :: proc "contextless" (list:^Edge_List,to:u64,cost:f32,data:u32=0) {
    if list.count<len(list.items) {list.items[list.count]={to,cost,data};list.count+=1} else {list.dropped+=1}
}

Search_Status :: enum u8 {
    Found,
    No_Path,     // the goal cannot be reached
    Open_Full,   // the open set, or the slots of a keyed search, ran out before the goal was reached
    Output_Full, // the path does not fit the output
    Invalid,     // a node is out of range, or the search is smaller than the space it is asked about
    Running,     // search_step used its budget: call it again
}

Search_Stats :: struct {
    searches:u64,
    expanded:int,  // nodes expanded by the last search
    peak_open:int, // largest open set of the last search
    open_full:u64, // searches that ran out of open set or slots
}

// The memory of searches: reuse it for every search of any space that fits.
// Not safe to share between threads; one search runs in it at a time.
Search :: struct {
    g:[]f32,
    parent:[]u32, // slot
    stamp:[]u32,  // == generation when the slot was reached by the current search
    closed:[]u32,
    keys:[]u64,   // keyed: the key of each slot
    table:[]u32,  // keyed: open addressing from a key to its slot+1, valid where table_stamp is the generation
    table_stamp:[]u32,
    used:int,     // keyed: slots given in the current search
    open:Open_Set,
    edges:[]Edge,
    channel:[]u64, // scratch with room for any path, for the callers that convert one
    generation:u32,
    start,goal:u64,
    goal_cost:f32,
    goal_slot:u32,
    status:Search_Status,
    found:bool, // the last search reached `goal`
    stats:Search_Stats,
    allocator:runtime.Allocator,
}
Search_Desc :: struct {
    nodes:int,                   // dense: keys below it; keyed: the nodes one search may reach
    keyed:bool,
    open:int,                    // open set capacity; nodes when 0
    max_edges:int,               // edges one node may have; 16 when 0
    allocator:runtime.Allocator, // context.allocator when unset
}

search_init :: proc(s:^Search,desc:Search_Desc) -> bool {
    allocator:=desc.allocator if desc.allocator.procedure!=nil else context.allocator
    s^={allocator=allocator}
    if desc.nodes<=0 || desc.nodes>int(max(u32)/4) || desc.max_edges>max(int)/size_of(Edge) {return false}
    e1,e2,e3,e4,e5,e6,e7,e8,e9:runtime.Allocator_Error
    s.g,e1=make([]f32,desc.nodes,allocator)
    s.parent,e2=make([]u32,desc.nodes,allocator)
    s.stamp,e3=make([]u32,desc.nodes,allocator)
    s.closed,e4=make([]u32,desc.nodes,allocator)
    s.edges,e5=make([]Edge,desc.max_edges if desc.max_edges>0 else 16,allocator)
    s.channel,e6=make([]u64,desc.nodes,allocator)
    if desc.keyed {
        size:=2
        for size<desc.nodes*2 {size*=2}
        s.keys,e7=make([]u64,desc.nodes,allocator)
        s.table,e8=make([]u32,size,allocator)
        s.table_stamp,e9=make([]u32,size,allocator)
    }
    if e1!=nil || e2!=nil || e3!=nil || e4!=nil || e5!=nil || e6!=nil || e7!=nil || e8!=nil || e9!=nil || !open_init(&s.open,desc.nodes,desc.open if desc.open>0 else desc.nodes,allocator) {
        search_destroy(s);return false
    }
    return true
}
search_destroy :: proc(s:^Search) {
    if s.allocator.procedure==nil {s^={};return}
    delete(s.g,s.allocator);delete(s.parent,s.allocator);delete(s.stamp,s.allocator);delete(s.closed,s.allocator);delete(s.edges,s.allocator);delete(s.channel,s.allocator)
    delete(s.keys,s.allocator);delete(s.table,s.allocator);delete(s.table_stamp,s.allocator)
    open_destroy(&s.open)
    s^={}
}
search_nodes :: #force_inline proc "contextless" (s:^Search) -> int {return len(s.g)}
search_keyed :: #force_inline proc "contextless" (s:^Search) -> bool {return len(s.table)>0}

// The cost of the path found by the last successful search.
search_cost :: #force_inline proc "contextless" (s:^Search) -> f32 {return s.goal_cost}

@(private)
search_hash :: #force_inline proc "contextless" (key:u64) -> u64 {
    h:=key*0x9e3779b97f4a7c15
    return h~(h>>29)
}
// The slot of a key the current search has reached, or false.
search_find :: proc "contextless" (s:^Search,key:u64) -> (slot:u32,ok:bool) {
    // No search has run: every stamp is still the first generation.
    if s.generation==0 {return}
    if !search_keyed(s) {
        if key>=u64(len(s.g)) || s.stamp[key]!=s.generation {return}
        return u32(key),true
    }
    mask:=u64(len(s.table)-1)
    for i:=search_hash(key)&mask;;i=(i+1)&mask {
        if s.table_stamp[i]!=s.generation {return}
        found:=s.table[i]-1
        if s.keys[found]==key {return found,true}
    }
}
// The slot of a key, given one when it has none. False when the key is out of
// range or a keyed search has no slot left.
@(private)
search_slot :: proc "contextless" (s:^Search,key:u64) -> (slot:u32,fresh,ok:bool) {
    if !search_keyed(s) {
        if key>=u64(len(s.g)) {return}
        return u32(key),s.stamp[key]!=s.generation,true
    }
    mask:=u64(len(s.table)-1)
    for i:=search_hash(key)&mask;;i=(i+1)&mask {
        if s.table_stamp[i]!=s.generation {
            if s.used>=len(s.g) {return}
            slot=u32(s.used)
            s.used+=1
            s.table_stamp[i]=s.generation;s.table[i]=slot+1
            s.keys[slot]=key
            return slot,true,true
        }
        found:=s.table[i]-1
        if s.keys[found]==key {return found,false,true}
    }
}
search_key :: #force_inline proc "contextless" (s:^Search,slot:u32) -> u64 {return s.keys[slot] if search_keyed(s) else u64(slot)}

// The parent of a node reached by the current or last search, or false at the start.
search_parent :: proc "contextless" (s:^Search,key:u64) -> (parent:u64,ok:bool) {
    slot,found:=search_find(s,key)
    if !found || s.parent[slot]==slot {return}
    return search_key(s,s.parent[slot]),true
}

// Finds the cheapest path from `start` to `goal` over the space `space`, whose
// edges `neighbors` writes and whose estimate of the remaining cost,
// `heuristic`, must never exceed the true cost to stay optimal (a constant
// zero makes it Dijkstra). The path is left in the search: read it with
// search_path.
search_run :: proc(s:^Search,start,goal:u64,space:$S,$neighbors:proc(S,u64,^Edge_List),$heuristic:proc(S,u64,u64) -> f32) -> Search_Status {
    if search_begin(s,start,goal,space,heuristic)!=.Running {return s.status}
    return search_step(s,space,neighbors,heuristic,search_accept_nothing,max(int))
}
search_accept_nothing :: proc(space:$S,slot:u32,edge:Edge) {}

// Starts a search that search_step advances. Running, or the status it ended with.
search_begin :: proc(s:^Search,start,goal:u64,space:$S,$heuristic:proc(S,u64,u64) -> f32) -> Search_Status {
    s.found=false
    s.status=.Invalid
    if len(s.g)==0 {return .Invalid}
    if !search_keyed(s) && (start>=u64(len(s.g)) || goal>=u64(len(s.g))) {return .Invalid}
    s.stats.searches+=1
    s.stats.expanded=0
    open_clear(&s.open)
    s.open.peak=0
    search_next_generation(s)
    s.used=0
    s.start,s.goal=start,goal
    slot,_,_:=search_slot(s,start)
    s.g[slot]=0;s.parent[slot]=slot;s.stamp[slot]=s.generation
    s.status=.Running
    if !open_push(&s.open,slot,heuristic(space,start,goal)) {search_end(s,.Open_Full)}
    return s.status
}
// Expands up to `budget` nodes of the search begun by search_begin. `accept`
// hears every step that becomes the best way to a node, with the slot of the
// node and the edge, right before `heuristic` is asked about that node; a
// no-op is search_accept_nothing. Running while the budget ran out first.
search_step :: proc(s:^Search,space:$S,$neighbors:proc(S,u64,^Edge_List),$heuristic:proc(S,u64,u64) -> f32,$accept:proc(S,u32,Edge),budget:int) -> Search_Status {
    if s.status!=.Running {return s.status}
    generation:=s.generation
    left:=budget
    list:Edge_List
    for left>0 {
        slot,_,ok:=open_pop(&s.open)
        if !ok {search_end(s,.No_Path);return s.status}
        key:=search_key(s,slot)
        if key==s.goal {s.goal_slot=slot;search_end(s,.Found);return s.status}
        s.closed[slot]=generation
        s.stats.expanded+=1
        left-=1
        list={items=s.edges}
        neighbors(space,key,&list)
        for edge in list.items[:list.count] {
            next,fresh,valid:=search_slot(s,edge.to)
            if !valid {
                if search_keyed(s) {search_end(s,.Open_Full);return s.status}
                continue
            }
            if !fresh && s.closed[next]==generation {continue}
            cost:=s.g[slot]+edge.cost
            if !fresh && s.stamp[next]==generation && cost>=s.g[next] {continue}
            s.g[next]=cost;s.parent[next]=slot;s.stamp[next]=generation
            accept(space,next,edge)
            if !open_push(&s.open,next,cost+heuristic(space,edge.to,s.goal)) {search_end(s,.Open_Full);return s.status}
        }
    }
    return s.status
}
@(private)
search_end :: proc "contextless" (s:^Search,status:Search_Status) {
    s.status=status
    s.stats.peak_open=s.open.peak
    if status==.Open_Full {s.stats.open_full+=1}
    s.found=status==.Found
    if s.found {s.goal_cost=s.g[s.goal_slot]}
}
@(private)
search_next_generation :: proc "contextless" (s:^Search) {
    s.generation+=1
    if s.generation==0 {
        for &stamp in s.stamp {stamp=0}
        for &closed in s.closed {closed=0}
        for &stamp in s.table_stamp {stamp=0}
        s.generation=1
    }
}

// Writes the keys of the path of the last successful search, in order from the
// start, and returns its length. Output_Full, with nothing written, when it
// does not fit; Invalid when the last search did not reach its goal.
search_path :: proc "contextless" (s:^Search,out:[]u64) -> (count:int,status:Search_Status) {
    if !s.found {return 0,.Invalid}
    length:=1
    for slot:=s.goal_slot;s.parent[slot]!=slot;slot=s.parent[slot] {length+=1}
    if length>len(out) {return 0,.Output_Full}
    slot:=s.goal_slot
    for i:=length-1;i>=0;i-=1 {out[i]=search_key(s,slot);slot=s.parent[slot]}
    return length,.Found
}

// Writes the keys of the path from the start to a node the current or last
// search reached (the nearest to an unreached goal, for a partial path).
search_path_to :: proc "contextless" (s:^Search,key:u64,out:[]u64) -> (count:int,status:Search_Status) {
    slot,found:=search_find(s,key)
    if !found {return 0,.Invalid}
    length:=1
    for at:=slot;s.parent[at]!=at;at=s.parent[at] {length+=1}
    if length>len(out) {return 0,.Output_Full}
    at:=slot
    for i:=length-1;i>=0;i-=1 {out[i]=search_key(s,at);at=s.parent[at]}
    return length,.Found
}
// The slots the current or last search reached, to visit with search_key: all
// of a keyed search below this count; a dense one, those whose stamp is the generation.
search_reached :: #force_inline proc "contextless" (s:^Search,slot:u32) -> bool {
    if search_keyed(s) {return int(slot)<s.used}
    return int(slot)<len(s.stamp) && s.stamp[slot]==s.generation
}
