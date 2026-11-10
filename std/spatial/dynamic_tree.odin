package spatial

import "core:mem"
import "mirai:std/base"
import math "mirai:std/math"

NULL_NODE :: i32(-1)
// Subtrees an iterator can leave pending, one per level of the path it is on. A tree is not
// height-bounded (nested boxes chain), so below this depth the iterator stops pushing and walks
// through the parent links instead: no height overflows the stack or loses a leaf.
TREE_STACK_CAPACITY :: 64

// Leaf: child1==NULL_NODE and height 0. Free: height -1 and parent links the free list.
Tree_Node :: struct {aabb:Aabb, user:u64, parent:i32, child1,child2:i32, height:i32}
#assert(size_of(Tree_Node)==48&&offset_of(Tree_Node,user)==24&&offset_of(Tree_Node,parent)==32&&offset_of(Tree_Node,height)==44)

Tree_Stats :: struct {insert_failures:u64}
Dynamic_Tree_Desc :: struct {proxy_capacity:int, margin:f32, allocator:mem.Allocator}
// nodes[:node_high] with root, free_list, node_high and proxy_count is the entire state.
// node_high counts the node slots ever used. stamps: of the nodes by chunk (base.chunk_stamp), with the
// revision that dynamic_tree_copy moves.
Dynamic_Tree :: struct {nodes:[]Tree_Node, root,free_list,node_high,proxy_count:i32, margin:f32, allocator:mem.Allocator, stats:Tree_Stats, stamps:[]u64, revision:u64}

dynamic_tree_init :: proc(tree:^Dynamic_Tree, desc:Dynamic_Tree_Desc) -> bool {
    tree^={}
    if desc.proxy_capacity<=0||desc.proxy_capacity>int(max(i32))/2 {return false}
    allocator:=desc.allocator.procedure!=nil?desc.allocator:context.allocator
    count:=2*desc.proxy_capacity-1
    nodes,error:=mem.make_aligned([]Tree_Node,count,64,allocator)
    if error!=nil||len(nodes)!=count {return false}
    stamps,stamps_error:=make([]u64,base.chunks_of(count),allocator)
    if stamps_error!=nil {
        delete(nodes,allocator)
        return false
    }
    tree^={nodes=nodes,root=NULL_NODE,free_list=NULL_NODE,margin=max(desc.margin,0),allocator=allocator,stamps=stamps,revision=1}
    return true
}
dynamic_tree_destroy :: proc(tree:^Dynamic_Tree) {
    delete(tree.nodes,tree.allocator)
    delete(tree.stamps,tree.allocator)
    tree^={}
}
dynamic_tree_clear :: proc(tree:^Dynamic_Tree) {
    tree.root=NULL_NODE;tree.free_list=NULL_NODE;tree.node_high=0;tree.proxy_count=0
}

@(private) node_alloc :: proc(tree:^Dynamic_Tree) -> i32 {
    index:=tree.free_list
    if index!=NULL_NODE {tree.free_list=tree.nodes[index].parent} else {index=tree.node_high;tree.node_high+=1}
    return index
}
@(private) node_written :: #force_inline proc "contextless" (tree:^Dynamic_Tree, index:i32) {base.chunk_stamp(tree.stamps,int(index),tree.revision)}
@(private) node_free :: proc(tree:^Dynamic_Tree, index:i32) {
    node_written(tree,index)
    tree.nodes[index].height=-1
    tree.nodes[index].parent=tree.free_list
    tree.free_list=index
}
@(private) node_children :: #force_inline proc "contextless" (node:^Tree_Node) -> ^[2]i32 {return (^[2]i32)(&node.child1)}
@(private) node_child_replace :: proc "contextless" (node:^Tree_Node, from,to:i32) {
    if node.child1==from {node.child1=to} else {node.child2=to}
}

// The node to pair a new leaf with: a greedy descent by surface area. Pairing with a node costs the
// area of the union plus what its ancestors grow; a child is entered only while the least it could
// cost still beats the best pairing found.
@(private) sibling_find :: proc(nodes:[]Tree_Node, root:i32, box:Aabb) -> i32 #no_bounds_check {
    box_area:=aabb_area(box)
    index:=root
    area:=aabb_area(nodes[root].aabb)
    direct:=aabb_area(math.aabb_merge(nodes[root].aabb,box))
    inherited:=f32(0)
    best,best_cost:=root,direct
    for nodes[index].child1!=NULL_NODE {
        if cost:=direct+inherited;cost<best_cost {best=index;best_cost=cost}
        inherited+=direct-area
        children:=node_children(&nodes[index])^
        child_area,child_direct,lower:[2]f32
        internal:[2]bool
        for child,i in children {
            child_box:=nodes[child].aabb
            child_direct[i]=aabb_area(math.aabb_merge(child_box,box))
            if nodes[child].child1==NULL_NODE {
                lower[i]=max(f32)
                if cost:=child_direct[i]+inherited;cost<best_cost {best=child;best_cost=cost}
            } else {
                internal[i]=true
                child_area[i]=aabb_area(child_box)
                lower[i]=inherited+child_direct[i]+fmin(box_area-child_area[i],0)
            }
        }
        if !internal[0]&&!internal[1] {break}
        if best_cost<=lower[0]&&best_cost<=lower[1] {break}
        if lower[0]==lower[1]&&internal[0]&&internal[1] {
            // Both children hold the box at the same cost: prefer the nearer one.
            center:=aabb_center(box)
            for child,i in children {
                d:=aabb_center(nodes[child].aabb)-center
                lower[i]=d.x*d.x+d.y*d.y+d.z*d.z
            }
        }
        next:=internal[0]&&(lower[0]<lower[1]||!internal[1])?0:1
        index=children[next];area=child_area[next];direct=child_direct[next]
    }
    return best
}

// Swaps a child of the node with a grandchild from its other side when that shrinks the internal
// child that receives it. The node keeps its box: it bounds the same leaves.
@(private) node_rotate :: proc(tree:^Dynamic_Tree, index:i32) -> (rotated:bool) #no_bounds_check {
    nodes:=tree.nodes
    node:=&nodes[index]
    if node.height<2 {return false}
    children:=node_children(node)
    best_gain:=f32(0)
    best_side,best_up:=-1,0
    for side in 0..<2 {
        pivot:=&nodes[children[1-side]]
        if pivot.child1==NULL_NODE {continue}
        down:=&nodes[children[side]]
        pivot_area:=aabb_area(pivot.aabb)
        grandchildren:=node_children(pivot)
        for up in 0..<2 {
            gain:=pivot_area-aabb_area(math.aabb_merge(down.aabb,nodes[grandchildren[1-up]].aabb))
            if gain>best_gain {best_gain=gain;best_side=side;best_up=up}
        }
    }
    if best_side<0 {return false}
    pivot_index:=children[1-best_side]
    pivot:=&nodes[pivot_index]
    grandchildren:=node_children(pivot)
    down,up,stay:=children[best_side],grandchildren[best_up],grandchildren[1-best_up]
    for written in ([4]i32{index,pivot_index,down,up}) {node_written(tree,written)}
    children[best_side]=up;nodes[up].parent=index
    grandchildren[best_up]=down;nodes[down].parent=pivot_index
    pivot.aabb=math.aabb_merge(nodes[down].aabb,nodes[stay].aabb)
    pivot.height=1+max(nodes[down].height,nodes[stay].height)
    node.height=1+max(pivot.height,nodes[up].height)
    return true
}

// A node left unchanged by a refit has unchanged ancestors: two in a row end the walk.
@(private) REFIT_STABLE :: 2
@(private) ancestors_refit :: proc(tree:^Dynamic_Tree, first:i32) #no_bounds_check {
    nodes:=tree.nodes
    stable:=0
    for index:=first;index!=NULL_NODE;index=nodes[index].parent {
        node:=&nodes[index]
        a,b:=&nodes[node.child1],&nodes[node.child2]
        box,height:=math.aabb_merge(a.aabb,b.aabb),1+max(a.height,b.height)
        changed:=box!=node.aabb||height!=node.height
        if changed {
            node_written(tree,index)
            node.aabb=box;node.height=height
        }
        if node_rotate(tree,index)||changed {stable=0;continue}
        stable+=1
        if stable==REFIT_STABLE {return}
    }
}

@(private) leaf_insert :: proc(tree:^Dynamic_Tree, leaf:i32, start:i32) {
    nodes:=tree.nodes
    node_written(tree,leaf)
    nodes[leaf].parent=NULL_NODE
    if tree.root==NULL_NODE {tree.root=leaf;return}
    sibling:=sibling_find(nodes,start,nodes[leaf].aabb)
    old_parent:=nodes[sibling].parent
    parent:=node_alloc(tree)
    node_written(tree,parent)
    node_written(tree,sibling)
    nodes[parent]={aabb=math.aabb_merge(nodes[leaf].aabb,nodes[sibling].aabb),parent=old_parent,child1=sibling,child2=leaf,height=nodes[sibling].height+1}
    if old_parent==NULL_NODE {tree.root=parent} else {node_written(tree,old_parent);node_child_replace(&nodes[old_parent],sibling,parent)}
    nodes[sibling].parent=parent;nodes[leaf].parent=parent
    ancestors_refit(tree,parent)
}
@(private) leaf_remove :: proc(tree:^Dynamic_Tree, leaf:i32) -> (grandparent:i32) {
    nodes:=tree.nodes
    if leaf==tree.root {tree.root=NULL_NODE;return NULL_NODE}
    parent:=nodes[leaf].parent
    grandparent=nodes[parent].parent
    sibling:=nodes[parent].child1==leaf?nodes[parent].child2:nodes[parent].child1
    node_written(tree,sibling)
    nodes[sibling].parent=grandparent
    if grandparent==NULL_NODE {tree.root=sibling} else {node_written(tree,grandparent);node_child_replace(&nodes[grandparent],parent,sibling)}
    node_free(tree,parent)
    ancestors_refit(tree,grandparent)
    return
}

// Stores the box exactly as given. A full tree returns ok=false and counts the failure.
dynamic_tree_insert :: proc(tree:^Dynamic_Tree, aabb:Aabb, user:u64) -> (proxy:i32, ok:bool) {
    if 2*int(tree.proxy_count)>=len(tree.nodes) {tree.stats.insert_failures+=1;return NULL_NODE,false}
    proxy=node_alloc(tree)
    node_written(tree,proxy)
    tree.nodes[proxy]={aabb=aabb,user=user,parent=NULL_NODE,child1=NULL_NODE,child2=NULL_NODE}
    leaf_insert(tree,proxy,tree.root)
    tree.proxy_count+=1
    return proxy,true
}
// A proxy that is not a leaf of the tree (removed, out of range, an internal node) is ignored by
// every procedure that takes one: reads give zero and changes do nothing.
dynamic_tree_remove :: proc(tree:^Dynamic_Tree, proxy:i32) {
    if !proxy_valid(tree,proxy) {return}
    leaf_remove(tree,proxy)
    node_free(tree,proxy)
    tree.proxy_count-=1
}
// Reinserts the leaf with exactly this box.
dynamic_tree_move :: proc(tree:^Dynamic_Tree, proxy:i32, aabb:Aabb) {
    if proxy_valid(tree,proxy) {leaf_move(tree,proxy,aabb)}
}
@(private) leaf_move :: proc(tree:^Dynamic_Tree, proxy:i32, aabb:Aabb) {
    start:=leaf_remove(tree,proxy)
    node_written(tree,proxy)
    tree.nodes[proxy].aabb=aabb
    // The search for the new sibling starts at the lowest ancestor that still contains the box.
    for start!=NULL_NODE&&!math.aabb_contains(tree.nodes[start].aabb,aabb) {start=tree.nodes[start].parent}
    if start==NULL_NODE {start=tree.root}
    leaf_insert(tree,proxy,start)
}
// Fat box policy: nothing changes while the stored box contains `tight`; otherwise the proxy takes
// `tight` grown by the margin of the tree and extended along the displacement.
dynamic_tree_update :: proc(tree:^Dynamic_Tree, proxy:i32, tight:Aabb, displacement:[3]f32={}) -> (moved:bool) {
    if !proxy_valid(tree,proxy)||math.aabb_contains(tree.nodes[proxy].aabb,tight) {return false}
    leaf_move(tree,proxy,aabb_translate_extend(math.aabb_expand(tight,tree.margin),displacement))
    return true
}
@(private) proxy_valid :: #force_inline proc "contextless" (tree:^Dynamic_Tree, proxy:i32) -> bool {
    return proxy>=0&&proxy<tree.node_high&&tree.nodes[proxy].height==0&&tree.nodes[proxy].child1==NULL_NODE
}
dynamic_tree_aabb :: proc(tree:^Dynamic_Tree, proxy:i32) -> Aabb {return proxy_valid(tree,proxy)?tree.nodes[proxy].aabb:{}}
dynamic_tree_user :: proc(tree:^Dynamic_Tree, proxy:i32) -> u64 {return proxy_valid(tree,proxy)?tree.nodes[proxy].user:0}
dynamic_tree_set_user :: proc(tree:^Dynamic_Tree, proxy:i32, user:u64) {
    if proxy_valid(tree,proxy) && tree.nodes[proxy].user!=user {
        node_written(tree,proxy)
        tree.nodes[proxy].user=user
    }
}

dynamic_tree_height :: proc(tree:^Dynamic_Tree) -> int {
    return tree.proxy_count>0?int(tree.nodes[tree.root].height):0
}
// Sum of the areas of the internal nodes over the area of the root: lower is a better tree.
dynamic_tree_area_ratio :: proc(tree:^Dynamic_Tree) -> f32 {
    if tree.proxy_count<2 {return 0}
    root_area:=aabb_area(tree.nodes[tree.root].aabb)
    if root_area<=0 {return 0}
    total:=f32(0)
    for &node in tree.nodes[:tree.node_high] {
        if node.height>0 {total+=aabb_area(node.aabb)}
    }
    return total/root_area
}

// Structure, heights, enclosing boxes and the free list. Heights that fall strictly from parent to
// child rule out cycles, so the per-node checks are enough to prove one tree under the root.
dynamic_tree_validate :: proc(tree:^Dynamic_Tree) -> bool {
    nodes:=tree.nodes
    high:=tree.node_high
    if high<0||int(high)>len(nodes)||tree.proxy_count<0 {return false}
    in_range :: proc(index,high:i32) -> bool {return index>=0&&index<high}
    if tree.proxy_count==0 {
        if tree.root!=NULL_NODE {return false}
    } else if !in_range(tree.root,high)||nodes[tree.root].height<0||nodes[tree.root].parent!=NULL_NODE {
        return false
    }
    leaves,internals,free:i32
    for &node,i in nodes[:high] {
        index:=i32(i)
        if node.height<0 {
            if node.height!=-1 {return false}
            free+=1
            continue
        }
        if index!=tree.root {
            if !in_range(node.parent,high) {return false}
            parent:=&nodes[node.parent]
            if parent.height<=node.height||(parent.child1!=index&&parent.child2!=index) {return false}
        }
        if node.child1==NULL_NODE {
            if node.child2!=NULL_NODE||node.height!=0 {return false}
            leaves+=1
            continue
        }
        if !in_range(node.child1,high)||!in_range(node.child2,high)||node.child1==node.child2 {return false}
        a,b:=&nodes[node.child1],&nodes[node.child2]
        if a.parent!=index||b.parent!=index||a.height<0||b.height<0 {return false}
        if node.height!=1+max(a.height,b.height)||node.aabb!=math.aabb_merge(a.aabb,b.aabb) {return false}
        internals+=1
    }
    if leaves!=tree.proxy_count||internals!=max(tree.proxy_count-1,0) {return false}
    listed:=i32(0)
    for index:=tree.free_list;index!=NULL_NODE;index=nodes[index].parent {
        if !in_range(index,high)||nodes[index].height!=-1||listed==free {return false}
        listed+=1
    }
    return listed==free
}

// Iterators only read the tree and own their stack, so any number of them can run over one tree
// from different threads. The tree must not change while one is in use.

// What follows a finished node. With the stack in use (deep^==NULL_NODE) that is whatever is pending;
// in the stackless part it is the next unvisited sibling above the node, until the walk is back at
// the node where it began.
@(private) tree_walk_after :: #force_inline proc "contextless" (nodes:[^]Tree_Node, finished:i32, deep:^i32) -> i32 #no_bounds_check {
    if deep^==NULL_NODE {return NULL_NODE}
    index:=finished
    for index!=deep^ {
        parent:=nodes[index].parent
        if nodes[parent].child1==index {return nodes[parent].child2}
        index=parent
    }
    deep^=NULL_NODE
    return NULL_NODE
}

@(private) node_overlaps :: #force_inline proc "contextless" (node:^Tree_Node, lo,hi:F4) -> bool {
    return boxes_overlap(lanes_load(&node.aabb.min),lanes_load(&node.aabb.max),lo,hi)
}
@(private) node_segment :: #force_inline proc "contextless" (node:^Tree_Node, s:^Segment, max_fraction:f32, $SWEEP:bool) -> (fraction:f32, hit:bool) {
    return segment_box(s,lanes_load(&node.aabb.min),lanes_load(&node.aabb.max),max_fraction,SWEEP)
}

// In both kinds of iterator `node` is a node the volume touches and that is still to be entered, or
// NULL_NODE to take the next pending one. While `deep` is set the walk is stackless under that node
// and `node` is a candidate still to be tested.
Tree_Query :: struct {nodes:[^]Tree_Node, lo,hi:F4, node,deep,count:i32, stack:[TREE_STACK_CAPACITY]i32}

dynamic_tree_query :: proc(tree:^Dynamic_Tree, aabb:Aabb) -> Tree_Query {
    q:Tree_Query=---
    q.nodes=raw_data(tree.nodes);q.lo=lanes(aabb.min);q.hi=lanes(aabb.max)
    q.node=NULL_NODE;q.deep=NULL_NODE;q.count=0
    if tree.proxy_count>0&&node_overlaps(&tree.nodes[tree.root],q.lo,q.hi) {q.node=tree.root}
    return q
}
// The leaves whose box overlaps the query, depth first with child1 before child2.
tree_query_next :: proc(q:^Tree_Query) -> (proxy:i32, user:u64, ok:bool) #no_bounds_check {
    nodes:=q.nodes
    index:=q.node
    for {
        if index==NULL_NODE {
            if q.count==0 {q.node=NULL_NODE;return NULL_NODE,0,false}
            q.count-=1;index=q.stack[q.count]
        } else if q.deep!=NULL_NODE&&!node_overlaps(&nodes[index],q.lo,q.hi) {
            index=tree_walk_after(nodes,index,&q.deep)
            continue
        }
        node:=&nodes[index]
        if node.child1==NULL_NODE {
            q.node=tree_walk_after(nodes,index,&q.deep)
            return index,node.user,true
        }
        if q.deep!=NULL_NODE||q.count==TREE_STACK_CAPACITY {
            if q.deep==NULL_NODE {q.deep=index}
            index=node.child1
            continue
        }
        // Both children are read before either is entered, so their cache misses overlap.
        overlaps_a,overlaps_b:=node_overlaps(&nodes[node.child1],q.lo,q.hi),node_overlaps(&nodes[node.child2],q.lo,q.hi)
        switch {
        case overlaps_a:
            if overlaps_b {q.stack[q.count]=node.child2;q.count+=1}
            index=node.child1
        case overlaps_b: index=node.child2
        case: index=NULL_NODE
        }
    }
}

@(private) Cast_Entry :: struct {node:i32, fraction:f32}

// The caller may lower max_fraction between calls to clip what is left of the traversal.
Tree_Ray :: struct {nodes:[^]Tree_Node, using segment:Segment, max_fraction:f32, node,deep,count:i32, stack:[TREE_STACK_CAPACITY]Cast_Entry}
Tree_Sweep :: distinct Tree_Ray

@(private) tree_cast_init :: #force_inline proc(r:^Tree_Ray, tree:^Dynamic_Tree, segment:Segment, max_fraction:f32, $SWEEP:bool) {
    r.nodes=raw_data(tree.nodes);r.segment=segment;r.max_fraction=max_fraction
    r.node=NULL_NODE;r.deep=NULL_NODE;r.count=0
    if tree.proxy_count>0 {
        if _,hit:=node_segment(&tree.nodes[tree.root],&r.segment,max_fraction,SWEEP);hit {r.node=tree.root}
    }
}
@(private) tree_cast_next :: #force_inline proc(r:^Tree_Ray, $SWEEP:bool) -> (proxy:i32, user:u64, ok:bool) #no_bounds_check {
    nodes:=r.nodes
    index:=r.node
    for {
        if index==NULL_NODE {
            for {
                if r.count==0 {r.node=NULL_NODE;return NULL_NODE,0,false}
                r.count-=1
                if entry:=r.stack[r.count];entry.fraction<=r.max_fraction {index=entry.node;break}
            }
        } else if r.deep!=NULL_NODE {
            if _,hit:=node_segment(&nodes[index],&r.segment,r.max_fraction,SWEEP);!hit {
                index=tree_walk_after(nodes,index,&r.deep)
                continue
            }
        }
        node:=&nodes[index]
        if node.child1==NULL_NODE {
            r.node=tree_walk_after(nodes,index,&r.deep)
            return index,node.user,true
        }
        if r.deep!=NULL_NODE||r.count==TREE_STACK_CAPACITY {
            if r.deep==NULL_NODE {r.deep=index}
            index=node.child1
            continue
        }
        fraction_a,hit_a:=node_segment(&nodes[node.child1],&r.segment,r.max_fraction,SWEEP)
        fraction_b,hit_b:=node_segment(&nodes[node.child2],&r.segment,r.max_fraction,SWEEP)
        switch {
        case hit_a&&hit_b:
            if fraction_b<fraction_a {
                r.stack[r.count]={node.child1,fraction_a};index=node.child2
            } else {
                r.stack[r.count]={node.child2,fraction_b};index=node.child1
            }
            r.count+=1
        case hit_a: index=node.child1
        case hit_b: index=node.child2
        case: index=NULL_NODE
        }
    }
}

dynamic_tree_ray :: proc(tree:^Dynamic_Tree, origin,translation:[3]f32, max_fraction:f32) -> Tree_Ray {
    r:Tree_Ray=---
    tree_cast_init(&r,tree,segment_make(origin,translation,{}),max_fraction,false)
    return r
}
// The leaves whose box the segment origin + t*translation, t in [0,max_fraction], touches. Of two
// children it enters the one the segment reaches first, child1 on a tie; in the stackless part of a
// deep tree, child1 first.
tree_ray_next :: proc(r:^Tree_Ray) -> (proxy:i32, user:u64, ok:bool) {return tree_cast_next(r,false)}

// A box that moves by translation; same order and clipping as a ray.
dynamic_tree_sweep :: proc(tree:^Dynamic_Tree, aabb:Aabb, translation:[3]f32, max_fraction:f32) -> Tree_Sweep {
    s:Tree_Sweep=---
    tree_cast_init((^Tree_Ray)(&s),tree,segment_make(aabb_center(aabb),translation,aabb_extents(aabb)),max_fraction,true)
    return s
}
tree_sweep_next :: proc(s:^Tree_Sweep) -> (proxy:i32, user:u64, ok:bool) {return tree_cast_next((^Tree_Ray)(s),true)}

// Makes dst the tree src is, copying the chunks of nodes whose stamps differ, or all of them with whole:
// a dst that only ever took copies of src, or src of it, keeps equal stamps where its nodes are equal. Both
// stamp what they write next with a revision neither used. Returns the bytes of nodes written; false,
// leaving dst as it was, when the nodes of src do not fit in it.
dynamic_tree_copy :: proc(dst,src:^Dynamic_Tree, whole:bool) -> (written:int, ok:bool) {
    if dst==src {return 0,true}
    if src.node_high<0||int(src.node_high)>len(dst.nodes) {return 0,false}
    nodes:=[1]base.Chunk_Copy{{mem.slice_to_bytes(dst.nodes),mem.slice_to_bytes(src.nodes),size_of(Tree_Node)}}
    written=base.chunks_copy(nodes[:],dst.stamps,src.stamps,int(max(src.node_high,dst.node_high)),whole)
    dst.root,dst.free_list,dst.node_high,dst.proxy_count=src.root,src.free_list,src.node_high,src.proxy_count
    revision:=max(dst.revision,src.revision)+1
    dst.revision,src.revision=revision,revision
    return written,true
}
