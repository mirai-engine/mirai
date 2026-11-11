package spatial

import "base:intrinsics"
import "core:math/bits"
import "core:mem"
import math "mirai:std/math"

// Deepest leaf a build can produce, and so the most subtrees an iterator ever leaves pending.
BVH_STACK_CAPACITY :: 64
@(private) BVH_BINS :: 16
@(private) BVH_TRAVERSAL_COST :: 1.0 // cost of testing a pair of nodes, in primitive tests
@(private) BVH_MIN_EXTENT :: 1e-30
@(private) BVH_NO_NODE :: i32(-1)

// count==0: interior, children are nodes[first] and nodes[first+1]. count>0: leaf over order[first:][:count].
Bvh_Node :: struct {min:[3]f32, first:u32, max:[3]f32, count:u32}
#assert(size_of(Bvh_Node)==32)

// max_leaf_size 0 means 4. max_depth: the deepest a leaf may be, as a stack that walks the tree
// bounds it; 0 means BVH_STACK_CAPACITY, more than that fails. Only a leaf at max_depth holds more
// than max_leaf_size primitives.
Bvh_Desc :: struct {max_leaf_size,max_depth:int, allocator:mem.Allocator}
// Immutable after the build. nodes[0] is the root and no input gives no nodes. Children are laid out
// depth first in pairs that start at an even index, so with nodes aligned to 64 bytes each pair is
// one cache line; nodes[1] is the unused slot that keeps that parity. order holds the primitive
// indices in leaf order.
Bvh :: struct {nodes:[]Bvh_Node, order:[]u32, allocator:mem.Allocator}

@(private) Bvh_Builder :: struct {nodes:[]Bvh_Node, node_count:int, boxes:[]Aabb, order:[]u32, max_leaf_size,depth_limit:int}

// A transaction: nodes and order come from desc.allocator, the scratch from context.temp_allocator.
// Fails, leaving the Bvh empty, on a box that is not finite or has min above max.
bvh_build :: proc(bvh:^Bvh, aabbs:[]Aabb, desc:Bvh_Desc) -> bool {
    bvh^={}
    boxes,error:=make([]Aabb,len(aabbs),context.temp_allocator)
    if error!=nil||len(boxes)!=len(aabbs) {return false}
    copy(boxes,aabbs)
    return bvh_build_boxes(bvh,boxes,desc)
}
// Primitive i is the triangle indices[3i..3i+2]. Fails, leaving the Bvh empty, on an index out of
// range or a vertex of a triangle that is not finite.
bvh_build_triangles :: proc(bvh:^Bvh, vertices:[][3]f32, indices:[]u32, desc:Bvh_Desc) -> bool {
    bvh^={}
    if len(indices)%3!=0 {return false}
    boxes,error:=make([]Aabb,len(indices)/3,context.temp_allocator)
    if error!=nil||len(boxes)!=len(indices)/3 {return false}
    for &box,i in boxes {
        a,b,c:=indices[3*i],indices[3*i+1],indices[3*i+2]
        if int(max(a,b,c))>=len(vertices) {return false}
        va,vb,vc:=vertices[a],vertices[b],vertices[c]
        // x-x is zero only for a finite x
        if va-va+(vb-vb)+(vc-vc)!={} {return false}
        box={vmin(va,vmin(vb,vc)),vmax(va,vmax(vb,vc))}
    }
    return bvh_build_boxes(bvh,boxes,desc)
}
bvh_destroy :: proc(bvh:^Bvh) {
    delete(bvh.nodes,bvh.allocator)
    delete(bvh.order,bvh.allocator)
    bvh^={}
}
bvh_bounds :: proc(bvh:^Bvh) -> Aabb {
    return len(bvh.nodes)>0?Aabb{bvh.nodes[0].min,bvh.nodes[0].max}:{}
}

// Reorders `boxes` together with the primitive order.
@(private) bvh_build_boxes :: proc(bvh:^Bvh, boxes:[]Aabb, desc:Bvh_Desc) -> bool {
    count:=len(boxes)
    if desc.max_depth<0||desc.max_depth>BVH_STACK_CAPACITY {return false}
    if count==0 {return true}
    if count>int(max(i32)) {return false}
    for box in boxes {
        if !aabb_valid(box) {return false}
    }
    allocator:=desc.allocator.procedure!=nil?desc.allocator:context.allocator
    scratch,scratch_error:=make([]Bvh_Node,2*count,context.temp_allocator)
    if scratch_error!=nil||len(scratch)!=2*count {return false}
    order,order_error:=make([]u32,count,allocator)
    if order_error!=nil||len(order)!=count {return false}
    for &primitive,i in order {primitive=u32(i)}
    builder:=Bvh_Builder{scratch,1,boxes,order,desc.max_leaf_size>0?desc.max_leaf_size:4,desc.max_depth>0?desc.max_depth:BVH_STACK_CAPACITY}
    bvh_node_build(&builder,0,0,count,0)
    nodes,nodes_error:=mem.make_aligned([]Bvh_Node,builder.node_count,64,allocator)
    if nodes_error!=nil||len(nodes)!=builder.node_count {delete(order,allocator);return false}
    copy(nodes,scratch[:builder.node_count])
    bvh^={nodes,order,allocator}
    return true
}

@(private) bvh_node_build :: proc(b:^Bvh_Builder, index,first,count,depth:int) {
    bounds,centroids:=math.AABB_EMPTY,math.AABB_EMPTY
    for box in b.boxes[first:][:count] {
        bounds=math.aabb_merge(bounds,box)
        center:=aabb_center(box)
        centroids={vmin(centroids.min,center),vmax(centroids.max,center)}
    }
    node:=&b.nodes[index]
    node.min=bounds.min;node.max=bounds.max
    left:=count>1&&depth<b.depth_limit?bvh_split(b,first,count,bounds,centroids,depth):0
    if left==0 {node.first=u32(first);node.count=u32(count);return}
    child:=max(b.node_count,2)
    b.node_count=child+2
    node.first=u32(child)
    bvh_node_build(b,child,first,left,depth+1)
    bvh_node_build(b,child+1,first+left,count-left,depth+1)
}

@(private) bvh_bin :: #force_inline proc "contextless" (box:Aabb, axis:int, origin,scale:f32, bin_count:int) -> int {
    return min(int((box.min[axis]*0.5+box.max[axis]*0.5-origin)*scale),bin_count-1)
}

// Partitions the range and returns how many primitives go to the first child, or 0 to keep it as a
// leaf. The split is the cheapest plane by surface area among the bins of the three axes; a range
// that fits a leaf is split only when that is cheaper than testing its primitives.
@(private) bvh_split :: proc(b:^Bvh_Builder, first,count:int, bounds,centroids:Aabb, depth:int) -> int {
    boxes,order:=b.boxes[first:][:count],b.order[first:][:count]
    extent:=centroids.max-centroids.min
    // A path this deep can only stay within the limit by halving the range at every level.
    if depth+bits.len(uint(count-1))<b.depth_limit {
        Bin :: struct {bounds:Aabb, count:int}
        bins:[3][BVH_BINS]Bin=---
        bin_count:=min(BVH_BINS,count)
        scale:[3]f32
        for axis in 0..<3 {
            if extent[axis]>BVH_MIN_EXTENT {scale[axis]=f32(bin_count)/extent[axis]}
            for &bin in bins[axis][:bin_count] {bin={math.AABB_EMPTY,0}}
        }
        for box in boxes {
            for axis in 0..<3 {
                bin:=&bins[axis][bvh_bin(box,axis,centroids.min[axis],scale[axis],bin_count)]
                bin.bounds=math.aabb_merge(bin.bounds,box)
                bin.count+=1
            }
        }
        // Equal costs, as among boxes without area, go to the split that divides the count best.
        best_cost:=max(f32)
        best_axis,best_bin,best_imbalance:=-1,0,0
        for axis in 0..<3 {
            if scale[axis]==0 {continue}
            // cost of the bins from i to the last one, as the second child
            right:[BVH_BINS]f32=---
            merged:=math.AABB_EMPTY
            merged_count:=0
            for i:=bin_count-1;i>0;i-=1 {
                merged=math.aabb_merge(merged,bins[axis][i].bounds)
                merged_count+=bins[axis][i].count
                right[i]=merged_count>0?aabb_area(merged)*f32(merged_count):-1
            }
            merged=math.AABB_EMPTY
            merged_count=0
            for i in 1..<bin_count {
                merged=math.aabb_merge(merged,bins[axis][i-1].bounds)
                merged_count+=bins[axis][i-1].count
                if merged_count==0||right[i]<0 {continue}
                cost,imbalance:=aabb_area(merged)*f32(merged_count)+right[i],abs(2*merged_count-count)
                if cost<best_cost||(cost==best_cost&&imbalance<best_imbalance) {
                    best_cost=cost;best_axis=axis;best_bin=i;best_imbalance=imbalance
                }
            }
        }
        if best_axis>=0 {
            area:=aabb_area(bounds)
            if count<=b.max_leaf_size&&!(BVH_TRAVERSAL_COST*area+best_cost<f32(count)*area) {return 0}
            left:=0
            for i in 0..<count {
                if bvh_bin(boxes[i],best_axis,centroids.min[best_axis],scale[best_axis],bin_count)<best_bin {
                    boxes[i],boxes[left]=boxes[left],boxes[i]
                    order[i],order[left]=order[left],order[i]
                    left+=1
                }
            }
            return left
        }
    }
    if count<=b.max_leaf_size {return 0}
    axis:=0
    if extent.y>extent[axis] {axis=1}
    if extent.z>extent[axis] {axis=2}
    bvh_select(boxes,order,count/2,axis)
    return count/2
}

// Reorders the range so that the k primitives with the lowest centers along the axis come first.
@(private) bvh_select :: proc(boxes:[]Aabb, order:[]u32, k,axis:int) {
    key :: #force_inline proc "contextless" (box:Aabb, axis:int) -> f32 {return box.min[axis]+box.max[axis]}
    lo,hi:=0,len(boxes)
    for hi-lo>1 {
        a,b,c:=key(boxes[lo],axis),key(boxes[lo+(hi-lo)/2],axis),key(boxes[hi-1],axis)
        pivot:=max(min(a,b),min(max(a,b),c))
        less,i,greater:=lo,lo,hi
        for i<greater {
            switch value:=key(boxes[i],axis);{
            case value<pivot:
                boxes[i],boxes[less]=boxes[less],boxes[i]
                order[i],order[less]=order[less],order[i]
                less+=1;i+=1
            case value>pivot:
                greater-=1
                boxes[i],boxes[greater]=boxes[greater],boxes[i]
                order[i],order[greater]=order[greater],order[i]
            case:
                i+=1
            }
        }
        if k<less {hi=less} else if k>=greater {lo=greater} else {return}
    }
}

// Structure of an array that did not come from bvh_build: children after their parent and in range,
// boxes that enclose their children, leaves that cover order once and in sequence, primitive indices
// in range and no path deeper than the iterator stack.
bvh_validate :: proc(bvh:^Bvh) -> bool {
    nodes,order:=bvh.nodes,bvh.order
    if len(nodes)==0 {return len(order)==0}
    Entry :: struct {node:u32, depth:int}
    stack:[BVH_STACK_CAPACITY+1]Entry
    stack[0]={0,0}
    stack_count:=1
    covered:=0
    for stack_count>0 {
        stack_count-=1
        entry:=stack[stack_count]
        node:=nodes[entry.node]
        if node.count>0 {
            if int(node.first)!=covered||covered+int(node.count)>len(order) {return false}
            covered+=int(node.count)
            continue
        }
        if entry.depth==BVH_STACK_CAPACITY||node.first<=entry.node||node.first<2||int(node.first)+1>=len(nodes) {return false}
        for child in ([2]u32{node.first+1,node.first}) {
            if !math.aabb_contains({node.min,node.max},{nodes[child].min,nodes[child].max}) {return false}
            stack[stack_count]={child,entry.depth+1}
            stack_count+=1
        }
    }
    if covered!=len(order) {return false}
    for primitive in order {
        if int(primitive)>=len(order) {return false}
    }
    return true
}

// Iterators only read the Bvh and own their stack: any number of them can run from different threads.

@(private) bvh_node_overlaps :: #force_inline proc "contextless" (node:^Bvh_Node, lo,hi:F4) -> bool {
    return boxes_overlap(lanes_load(&node.min),lanes_load(&node.max),lo,hi)
}
@(private) bvh_node_segment :: #force_inline proc "contextless" (node:^Bvh_Node, s:^Segment, max_fraction:f32, $SWEEP:bool) -> (fraction:f32, hit:bool) {
    return segment_box(s,lanes_load(&node.min),lanes_load(&node.max),max_fraction,SWEEP)
}

// In both kinds of iterator `node` is a node the volume touches and that is still to be entered, or
// BVH_NO_NODE to take the next pending one.
Bvh_Query :: struct {nodes:[^]Bvh_Node, order:[^]u32, lo,hi:F4, node,count:i32, stack:[BVH_STACK_CAPACITY]i32}

bvh_query :: proc(bvh:^Bvh, aabb:Aabb) -> Bvh_Query {
    q:Bvh_Query=---
    q.nodes=raw_data(bvh.nodes);q.order=raw_data(bvh.order);q.lo=lanes(aabb.min);q.hi=lanes(aabb.max)
    q.node=BVH_NO_NODE;q.count=0
    if len(bvh.nodes)>0&&bvh_node_overlaps(&bvh.nodes[0],q.lo,q.hi) {q.node=0}
    return q
}
// One leaf whose box overlaps the query per call, depth first with the first child before the second.
bvh_query_next :: proc(q:^Bvh_Query) -> (primitives:[]u32, ok:bool) #no_bounds_check {
    index:=q.node
    for {
        if index<0 {
            if q.count==0 {q.node=BVH_NO_NODE;return nil,false}
            q.count-=1;index=q.stack[q.count]
        }
        node:=&q.nodes[index]
        if node.count>0 {q.node=BVH_NO_NODE;return q.order[node.first:][:node.count],true}
        first:=i32(node.first)
        overlaps_a,overlaps_b:=bvh_node_overlaps(&q.nodes[first],q.lo,q.hi),bvh_node_overlaps(&q.nodes[first+1],q.lo,q.hi)
        switch {
        case overlaps_a:
            if overlaps_b&&q.count<BVH_STACK_CAPACITY {q.stack[q.count]=first+1;q.count+=1}
            index=first
        case overlaps_b: index=first+1
        case: index=BVH_NO_NODE
        }
    }
}

// The caller may lower max_fraction between calls to clip what is left of the traversal.
Bvh_Ray :: struct {nodes:[^]Bvh_Node, order:[^]u32, using segment:Segment, max_fraction:f32, node,count:i32, stack:[BVH_STACK_CAPACITY]Cast_Entry}
Bvh_Sweep :: distinct Bvh_Ray

@(private) bvh_cast_init :: #force_inline proc(r:^Bvh_Ray, bvh:^Bvh, segment:Segment, max_fraction:f32, $SWEEP:bool) {
    r.nodes=raw_data(bvh.nodes);r.order=raw_data(bvh.order);r.segment=segment;r.max_fraction=max_fraction
    r.node=BVH_NO_NODE;r.count=0
    if len(bvh.nodes)>0 {
        if _,hit:=bvh_node_segment(&bvh.nodes[0],&r.segment,max_fraction,SWEEP);hit {r.node=0}
    }
}
@(private) bvh_cast_next :: #force_inline proc(r:^Bvh_Ray, $SWEEP:bool) -> (primitives:[]u32, ok:bool) #no_bounds_check {
    index:=r.node
    for {
        if index<0 {
            for {
                if r.count==0 {r.node=BVH_NO_NODE;return nil,false}
                r.count-=1
                if entry:=r.stack[r.count];entry.fraction<=r.max_fraction {index=entry.node;break}
            }
        }
        node:=&r.nodes[index]
        if node.count>0 {r.node=BVH_NO_NODE;return r.order[node.first:][:node.count],true}
        first:=i32(node.first)
        fraction_a,hit_a:=bvh_node_segment(&r.nodes[first],&r.segment,r.max_fraction,SWEEP)
        fraction_b,hit_b:=bvh_node_segment(&r.nodes[first+1],&r.segment,r.max_fraction,SWEEP)
        switch {
        case hit_a&&hit_b:
            near,far,far_fraction:=first,first+1,fraction_b
            if fraction_b<fraction_a {near,far,far_fraction=first+1,first,fraction_a}
            if r.count<BVH_STACK_CAPACITY {r.stack[r.count]={far,far_fraction};r.count+=1}
            index=near
        case hit_a: index=first
        case hit_b: index=first+1
        case: index=BVH_NO_NODE
        }
    }
}

bvh_ray :: proc(bvh:^Bvh, origin,translation:[3]f32, max_fraction:f32) -> Bvh_Ray {
    r:Bvh_Ray=---
    bvh_cast_init(&r,bvh,segment_make(origin,translation,{}),max_fraction,false)
    return r
}
// One leaf whose box the segment origin + t*translation, t in [0,max_fraction], touches per call.
// Of two children it enters the one the segment reaches first, the first child on a tie.
bvh_ray_next :: proc(r:^Bvh_Ray) -> (primitives:[]u32, ok:bool) {return bvh_cast_next(r,false)}

// A box that moves by translation; same order and clipping as a ray.
bvh_sweep :: proc(bvh:^Bvh, aabb:Aabb, translation:[3]f32, max_fraction:f32) -> Bvh_Sweep {
    s:Bvh_Sweep=---
    bvh_cast_init((^Bvh_Ray)(&s),bvh,segment_make(aabb_center(aabb),translation,aabb_extents(aabb)),max_fraction,true)
    return s
}
bvh_sweep_next :: proc(s:^Bvh_Sweep) -> (primitives:[]u32, ok:bool) {return bvh_cast_next((^Bvh_Ray)(s),true)}
