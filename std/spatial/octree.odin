package spatial

import "core:mem"
import math "mirai:std/math"

// A loose octree of boxes over a fixed cube of space: the smallest cube around Octree_Desc.bounds.
// An item goes down by the octant its middle is in while its half size is at most half the half
// size of the cell, so the level of an item follows its size and never the planes it lies
// across: everything a node holds is inside its cell grown to twice its size, which is what a
// query tests. A box whose middle is outside the cube stays in the root. A leaf with leaf_items
// items is divided into its eight octants while there is depth and nodes left; a subtree whose
// items drop to half of leaf_items becomes a leaf again. Nodes and items are allocated by
// octree_init.
//
// Octants are numbered by the side of the center on each axis: bit 0 for +x, bit 1 for +y,
// bit 2 for +z.

OCTREE_NULL :: i32(-1)
OCTREE_MAX_DEPTH :: 16
// Eight children are pushed for one node taken, at most once per level.
@(private) OCTREE_STACK_CAPACITY :: 7*OCTREE_MAX_DEPTH+8
// What the cell a query tests is grown by beyond twice its size: the rounding of the centers of
// sixteen levels.
@(private) OCTREE_PAD :: 1.0/256
@(private) OCTREE_NOISE :: 1.0/(1<<20)

Octree_Stats :: struct {
    insert_failures:u64, // no item slot, or a box that is not valid
    split_failures:u64,  // a leaf that stayed whole because no nodes were left
}

Octree_Desc :: struct {
    bounds:Aabb,
    max_depth:int,     // levels below the root. 0: 8
    leaf_items:int,    // items a leaf holds before it is divided. 0: 8
    item_capacity:int,
    node_capacity:int, // 0: one per item, and the eight of the root
    allocator:mem.Allocator,
}

// children is the first of eight consecutive nodes, OCTREE_NULL in a leaf. count is of the items
// the node holds itself and total of those of its subtree.
Octree_Node :: struct {children,parent,first_item,count,total:i32}
// node is OCTREE_NULL in a free slot, whose next is the free list.
Octree_Item :: struct {aabb:Aabb, user:u64, node,next,previous:i32}

// nodes[:node_high] and items[:item_high] with the counters are the entire state.
Octree :: struct {
    nodes:[]Octree_Node, items:[]Octree_Item,
    center:[3]f32, half:f32, // of the cube of the root
    max_depth,leaf_items:i32,
    free_item,item_high,item_count,free_block,node_high:i32,
    allocator:mem.Allocator, stats:Octree_Stats,
}

octree_init :: proc(o:^Octree, desc:Octree_Desc) -> bool {
    o^={}
    if !aabb_valid(desc.bounds)||desc.item_capacity<=0||desc.item_capacity>int(max(i32))/16||desc.max_depth<0||desc.max_depth>OCTREE_MAX_DEPTH||desc.leaf_items<0 {return false}
    blocks:=desc.node_capacity>0?(desc.node_capacity-1)/8:(desc.item_capacity+15)/8
    if blocks<0||blocks>int(max(i32))/16 {return false}
    allocator:=desc.allocator.procedure!=nil?desc.allocator:context.allocator
    nodes,nodes_error:=make([]Octree_Node,1+blocks*8,allocator)
    items,items_error:=make([]Octree_Item,desc.item_capacity,allocator)
    if nodes_error!=nil||items_error!=nil {
        delete(nodes,allocator);delete(items,allocator)
        return false
    }
    extents:=aabb_extents(desc.bounds)
    o^={
        nodes=nodes,items=items,center=aabb_center(desc.bounds),half=fmax(extents.x,fmax(extents.y,extents.z)),
        max_depth=i32(desc.max_depth>0?desc.max_depth:8),leaf_items=i32(desc.leaf_items>0?desc.leaf_items:8),allocator=allocator,
    }
    octree_clear(o)
    return true
}
octree_destroy :: proc(o:^Octree) {
    delete(o.nodes,o.allocator);delete(o.items,o.allocator)
    o^={}
}
// Drops every item and node but the root; the capacities and the counters of stats stay.
octree_clear :: proc(o:^Octree) {
    if len(o.nodes)==0 {return}
    o.nodes[0]={OCTREE_NULL,OCTREE_NULL,OCTREE_NULL,0,0}
    o.free_item,o.free_block=OCTREE_NULL,OCTREE_NULL
    o.item_high,o.item_count,o.node_high=0,0,1
}

@(private) octree_child_center :: #force_inline proc "contextless" (center:[3]f32, half:f32, octant:int) -> [3]f32 {
    quarter:=half*0.5
    return {center.x+(octant&1!=0?quarter:-quarter),center.y+(octant&2!=0?quarter:-quarter),center.z+(octant&4!=0?quarter:-quarter)}
}
// The octant the middle of a box is in.
@(private) octree_octant :: #force_inline proc "contextless" (center:[3]f32, aabb:Aabb) -> (octant:int) {
    for i in 0..<3 {
        if aabb.min[i]*0.5+aabb.max[i]*0.5>center[i] {octant|=1<<uint(i)}
    }
    return
}
// Whether a box is small enough for the octants of a cell of this half size.
@(private) octree_descends :: #force_inline proc "contextless" (half:f32, aabb:Aabb) -> bool {
    quarter:=half*0.5
    return aabb.max.x*0.5-aabb.min.x*0.5<=quarter&&aabb.max.y*0.5-aabb.min.y*0.5<=quarter&&aabb.max.z*0.5-aabb.min.z*0.5<=quarter
}
// Whether the middle of a box is in the cube of the root: only then does it leave the root.
@(private) octree_inside :: proc "contextless" (o:^Octree, aabb:Aabb) -> bool {
    for i in 0..<3 {
        middle:=aabb.min[i]*0.5+aabb.max[i]*0.5
        if !(middle>=o.center[i]-o.half&&middle<=o.center[i]+o.half) {return false}
    }
    return true
}
// What everything under a node is inside of.
@(private) octree_loose :: #force_inline proc "contextless" (center:[3]f32, half:f32) -> Aabb {
    reach:=half*(2+OCTREE_PAD)
    pad:=[3]f32{reach+abs(center.x)*OCTREE_NOISE,reach+abs(center.y)*OCTREE_NOISE,reach+abs(center.z)*OCTREE_NOISE}
    return {center-pad,center+pad}
}

@(private) octree_attach :: proc(o:^Octree, item,node:i32) {
    entry,n:=&o.items[item],&o.nodes[node]
    entry.node,entry.previous,entry.next=node,OCTREE_NULL,n.first_item
    if n.first_item!=OCTREE_NULL {o.items[n.first_item].previous=item}
    n.first_item=item
    n.count+=1
}
@(private) octree_detach :: proc(o:^Octree, item:i32) {
    entry:=&o.items[item]
    n:=&o.nodes[entry.node]
    if entry.previous!=OCTREE_NULL {o.items[entry.previous].next=entry.next} else {n.first_item=entry.next}
    if entry.next!=OCTREE_NULL {o.items[entry.next].previous=entry.previous}
    n.count-=1
}

// Whether a box held by a node of this half size belongs in one of its octants.
@(private) octree_goes_down :: #force_inline proc "contextless" (o:^Octree, node:i32, half:f32, aabb:Aabb) -> bool {
    return octree_descends(half,aabb)&&(node!=0||octree_inside(o,aabb))
}

// Divides a leaf and hands its items to the octants they belong in. False, with the leaf as it
// was, when none of its items would go down, or no nodes are left.
@(private) octree_split :: proc(o:^Octree, node:i32, center:[3]f32, half:f32) -> bool {
    moves:=false
    for item:=o.nodes[node].first_item;item!=OCTREE_NULL&&!moves;item=o.items[item].next {
        moves=octree_goes_down(o,node,half,o.items[item].aabb)
    }
    if !moves {return false}
    block:=o.free_block
    if block!=OCTREE_NULL {
        o.free_block=o.nodes[block].parent
    } else if int(o.node_high)+8<=len(o.nodes) {
        block=o.node_high
        o.node_high+=8
    } else {
        o.stats.split_failures+=1
        return false
    }
    for child in block..<block+8 {o.nodes[child]={OCTREE_NULL,node,OCTREE_NULL,0,0}}
    o.nodes[node].children=block
    next:i32
    for item:=o.nodes[node].first_item;item!=OCTREE_NULL;item=next {
        next=o.items[item].next
        if !octree_goes_down(o,node,half,o.items[item].aabb) {continue}
        child:=block+i32(octree_octant(center,o.items[item].aabb))
        octree_detach(o,item)
        octree_attach(o,item,child)
        o.nodes[child].total+=1
    }
    return true
}

// Walks an item down from the root to its node, counting it in every subtree it enters.
@(private) octree_place :: proc(o:^Octree, item:i32) {
    aabb:=o.items[item].aabb
    node:=i32(0)
    center,half:=o.center,o.half
    for depth:=i32(0);;depth+=1 {
        n:=&o.nodes[node]
        n.total+=1
        if depth>=o.max_depth||!octree_goes_down(o,node,half,aabb) {break}
        if n.children==OCTREE_NULL&&(n.count<o.leaf_items||!octree_split(o,node,center,half)) {break}
        octant:=octree_octant(center,aabb)
        node=o.nodes[node].children+i32(octant)
        center,half=octree_child_center(center,half,octant),half*0.5
    }
    octree_attach(o,item,node)
}

// Takes an item out of its node and makes a leaf of the highest subtree left with few items.
@(private) octree_lift :: proc(o:^Octree, item:i32) {
    node:=o.items[item].node
    octree_detach(o,item)
    sparse:=OCTREE_NULL
    for at:=node;at!=OCTREE_NULL;at=o.nodes[at].parent {
        o.nodes[at].total-=1
        if o.nodes[at].children!=OCTREE_NULL&&o.nodes[at].total<=o.leaf_items/2 {sparse=at}
    }
    if sparse==OCTREE_NULL {return}
    stack:[8*OCTREE_MAX_DEPTH]i32
    count:=1
    stack[0]=o.nodes[sparse].children
    o.nodes[sparse].children=OCTREE_NULL
    for count>0 {
        count-=1
        block:=stack[count]
        for child in block..<block+8 {
            n:=&o.nodes[child]
            next:i32
            for moved:=n.first_item;moved!=OCTREE_NULL;moved=next {
                next=o.items[moved].next
                octree_attach(o,moved,sparse)
            }
            if n.children!=OCTREE_NULL {
                stack[count]=n.children
                count+=1
            }
        }
        o.nodes[block].parent=o.free_block
        o.free_block=block
    }
}

@(private) octree_live :: #force_inline proc "contextless" (o:^Octree, item:i32) -> bool {
    return item>=0&&item<o.item_high&&o.items[item].node!=OCTREE_NULL
}

octree_insert :: proc(o:^Octree, aabb:Aabb, user:u64) -> (item:i32, ok:bool) {
    if len(o.items)==0||int(o.item_count)>=len(o.items)||!aabb_valid(aabb) {
        o.stats.insert_failures+=1
        return OCTREE_NULL,false
    }
    item=o.free_item
    if item!=OCTREE_NULL {o.free_item=o.items[item].next} else {item=o.item_high;o.item_high+=1}
    o.items[item]={aabb=aabb,user=user}
    o.item_count+=1
    octree_place(o,item)
    return item,true
}
octree_remove :: proc(o:^Octree, item:i32) {
    if !octree_live(o,item) {return}
    octree_lift(o,item)
    o.items[item]={node=OCTREE_NULL,next=o.free_item}
    o.free_item=item
    o.item_count-=1
}
// Gives an item another box. False, with the item where it was, for a box that is not valid.
octree_move :: proc(o:^Octree, item:i32, aabb:Aabb) -> bool {
    if !octree_live(o,item)||!aabb_valid(aabb) {return false}
    octree_lift(o,item)
    o.items[item].aabb=aabb
    octree_place(o,item)
    return true
}
// An item that is not live reads as zero and takes no user.
octree_aabb :: proc(o:^Octree, item:i32) -> Aabb {return octree_live(o,item)?o.items[item].aabb:{}}
octree_user :: proc(o:^Octree, item:i32) -> u64 {return octree_live(o,item)?o.items[item].user:0}
octree_set_user :: proc(o:^Octree, item:i32, user:u64) {
    if octree_live(o,item) {o.items[item].user=user}
}
// Nodes in use, with the root.
octree_node_count :: proc(o:^Octree) -> int {
    if len(o.nodes)==0 {return 0}
    free:=0
    for block:=o.free_block;block!=OCTREE_NULL;block=o.nodes[block].parent {free+=8}
    return int(o.node_high)-free
}

// Every item is on the way down from the root that its box takes, as deep as the nodes there
// go, and inside the grown cell of its node; the counts of every node are those of its list and
// of its subtree.
octree_validate :: proc(o:^Octree) -> bool {
    if len(o.nodes)==0 {return o.item_count==0}
    Visit :: struct {node:i32, center:[3]f32, half:f32, depth:i32}
    stack:[OCTREE_STACK_CAPACITY]Visit
    stack[0]={0,o.center,o.half,0}
    count,items:=1,0
    for count>0 {
        count-=1
        v:=stack[count]
        n:=o.nodes[v.node]
        held:=i32(0)
        previous:=OCTREE_NULL
        for item:=n.first_item;item!=OCTREE_NULL;item=o.items[item].next {
            entry:=o.items[item]
            if entry.node!=v.node||entry.previous!=previous {return false}
            if v.node!=0&&!math.aabb_contains(octree_loose(v.center,v.half),entry.aabb) {return false}
            if n.children!=OCTREE_NULL&&octree_goes_down(o,v.node,v.half,entry.aabb) {return false}
            // The way down of the box ends here.
            at,center,half:=i32(0),o.center,o.half
            for at!=v.node {
                if o.nodes[at].children==OCTREE_NULL||!octree_goes_down(o,at,half,entry.aabb) {return false}
                octant:=octree_octant(center,entry.aabb)
                at=o.nodes[at].children+i32(octant)
                center,half=octree_child_center(center,half,octant),half*0.5
            }
            previous=item
            held+=1
            if held>o.item_count {return false}
        }
        if held!=n.count {return false}
        items+=int(held)
        below:=n.count
        if n.children!=OCTREE_NULL {
            if v.depth>=o.max_depth {return false}
            for octant in 0..<8 {
                child:=n.children+i32(octant)
                if o.nodes[child].parent!=v.node {return false}
                below+=o.nodes[child].total
                stack[count]={child,octree_child_center(v.center,v.half,octant),v.half*0.5,v.depth+1}
                count+=1
            }
        }
        if below!=n.total {return false}
    }
    return items==int(o.item_count)
}

// -- Iterators --------------------------------------------------------------
//
// Iterators only read the octree and own their stack: any number of them can run from different
// threads.

@(private) Octree_Visit :: struct {node:i32, center:[3]f32, half:f32, fraction:f32}

Octree_Query :: struct {tree:^Octree, aabb:Aabb, item,count:i32, stack:[OCTREE_STACK_CAPACITY]Octree_Visit}

octree_query :: proc(o:^Octree, aabb:Aabb) -> Octree_Query {
    q:Octree_Query=---
    q.tree,q.aabb,q.item,q.count=o,aabb,OCTREE_NULL,0
    if o.item_count>0&&aabb_valid(aabb) {
        q.stack[0]={0,o.center,o.half,0}
        q.count=1
    }
    return q
}
// One item whose box overlaps the query per call: those of a node before those of its octants,
// octants from the last to the first.
octree_query_next :: proc(q:^Octree_Query) -> (item:i32, user:u64, ok:bool) {
    o:=q.tree
    for {
        for q.item!=OCTREE_NULL {
            index:=q.item
            entry:=&o.items[index]
            q.item=entry.next
            if math.aabb_overlaps(entry.aabb,q.aabb) {return index,entry.user,true}
        }
        if q.count==0 {return OCTREE_NULL,0,false}
        q.count-=1
        v:=q.stack[q.count]
        n:=&o.nodes[v.node]
        q.item=n.first_item
        if n.children==OCTREE_NULL {continue}
        for octant in 0..<8 {
            child:=n.children+i32(octant)
            if o.nodes[child].total==0 {continue}
            center,half:=octree_child_center(v.center,v.half,octant),v.half*0.5
            if !math.aabb_overlaps(octree_loose(center,half),q.aabb) {continue}
            q.stack[q.count]={child,center,half,0}
            q.count+=1
        }
    }
}

// The caller may lower max_fraction between calls to clip what is left of the traversal.
Octree_Ray :: struct {tree:^Octree, origin,translation:[3]f32, max_fraction:f32, item,count:i32, stack:[OCTREE_STACK_CAPACITY]Octree_Visit}

// The items whose box the segment origin + t*translation, t in [0,max_fraction], touches.
octree_ray :: proc(o:^Octree, origin,translation:[3]f32, max_fraction:f32) -> Octree_Ray {
    r:Octree_Ray=---
    r.tree,r.origin,r.translation,r.max_fraction,r.item,r.count=o,origin,translation,max_fraction,OCTREE_NULL,0
    if o.item_count>0 {
        r.stack[0]={0,o.center,o.half,0}
        r.count=1
    }
    return r
}
// One item the segment touches per call: those of a node before those of its octants, and the
// octants the segment enters first before the others.
octree_ray_next :: proc(r:^Octree_Ray) -> (item:i32, user:u64, ok:bool) {
    o:=r.tree
    for {
        for r.item!=OCTREE_NULL {
            index:=r.item
            entry:=&o.items[index]
            r.item=entry.next
            if _,hit:=aabb_ray(entry.aabb,r.origin,r.translation,r.max_fraction);hit {return index,entry.user,true}
        }
        v:Octree_Visit
        for {
            if r.count==0 {return OCTREE_NULL,0,false}
            r.count-=1
            v=r.stack[r.count]
            if v.fraction<=r.max_fraction {break}
        }
        n:=&o.nodes[v.node]
        r.item=n.first_item
        if n.children==OCTREE_NULL {continue}
        first:=r.count
        for octant in 0..<8 {
            child:=n.children+i32(octant)
            if o.nodes[child].total==0 {continue}
            center,half:=octree_child_center(v.center,v.half,octant),v.half*0.5
            fraction,hit:=aabb_ray(octree_loose(center,half),r.origin,r.translation,r.max_fraction)
            if !hit {continue}
            // Kept with the farthest at the bottom: the nearest is taken next.
            at:=r.count
            for at>first&&r.stack[at-1].fraction<fraction {
                r.stack[at]=r.stack[at-1]
                at-=1
            }
            r.stack[at]={child,center,half,fraction}
            r.count+=1
        }
    }
}
