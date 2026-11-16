package geom

import "base:runtime"
import "core:math"
import "core:slice"

// Groups of clusters for the levels of a cluster DAG: a port of the cluster
// partitioner of meshoptimizer 1.3 (meshopt_partitionClusters in
// src/partition.cpp, MIT, Arseny Kapoulkine) with two changes: sibling
// clusters weigh less than neighbors, and stray pieces join the nearest in
// Morton order.
//
// Every cluster starts as a group. The group with the fewest vertices
// merges with the neighbor of best score, the weight of what joins them
// over the root of the vertices of each (their expected boundaries), times
// a bonus for spheres that overlap; groups that reach the target size stop
// growing, and a last pass merges small groups by place alone (Kurita,
// An efficient agglomerative clustering algorithm using a heap, 1991).
//
// The weight between two clusters is PARTITION_WEIGHT_SHARED for each vertex
// they share, PARTITION_WEIGHT_SIBLINGS instead when both come from one
// group of the level before (siblings), plus PARTITION_WEIGHT_ADJACENT.
// Siblings weigh less so that groups do not repeat those of the level
// before: their borders, locked when the group is simplified, change from
// level to level instead of staying locked all the way up. And clusters of
// small pieces that touch nothing (leaves, rocks) get links of
// PARTITION_WEIGHT_NEAR to up to PARTITION_NEAR_LINKS of the nearest clusters
// of other pieces, found along the Morton order of their centers, so they
// join their neighbors in the merge instead of only in the last pass.

PARTITION_WEIGHT_SHARED   :: 16
PARTITION_WEIGHT_SIBLINGS :: 12
PARTITION_WEIGHT_ADJACENT :: 4
PARTITION_WEIGHT_NEAR     :: 1
PARTITION_NEAR_LINKS      :: 5
@(private="file") PARTITION_NEAR_STEPS :: 16  // along the Morton order, in each direction
@(private="file") PARTITION_NEAR_PIECE :: 128 // a piece with as many clusters in a row of the order gets no links
@(private="file") MERGE_DEPTH_CUTOFF :: 40

Partition_Error :: enum u8 {None,Invalid_Clusters,Out_Of_Memory}

@(private="file")
Cluster_Adjacency :: struct {
    offsets:[]u32,
    clusters:[]u32,
    shared:[]u32, // vertices shared
    weight:[]u32,
}

@(private="file")
Cluster_Group :: struct {
    group:i32,
    next:i32,
    size:u32,     // clusters; 0 unless the group is a root
    vertices:u32,
    center:Vec3,
    radius:f32,
}

@(private="file")
Group_Order :: struct {id:u32,order:i32}

@(private="file")
order_push :: proc "contextless" (heap:[]Group_Order,size:int,item:Group_Order) #no_bounds_check {
    heap[size]=item
    i:=size
    for i>0 && heap[i].order<heap[(i-1)/2].order {
        p:=(i-1)/2
        heap[i],heap[p]=heap[p],heap[i]
        i=p
    }
}

@(private="file")
order_pop :: proc "contextless" (heap:[]Group_Order,size:int) -> Group_Order #no_bounds_check {
    top:=heap[0]
    size:=size-1
    heap[0]=heap[size]
    i:=0
    for i*2+1<size {
        j:=i*2+1
        j+=int(j+1<size && heap[j+1].order<heap[j].order)
        if heap[j].order>=heap[i].order {break}
        heap[i],heap[j]=heap[j],heap[i]
        i=j
    }
    return top
}

@(private="file")
bounds_merge :: proc "contextless" (target:^Cluster_Group,source:Cluster_Group) {
    r1,r2:=target.radius,source.radius
    dx,dy,dz:=source.center.x-target.center.x,source.center.y-target.center.y,source.center.z-target.center.z
    d:=math.sqrt(dx*dx+dy*dy+dz*dz)
    if d+r1<r2 {
        target.center=source.center
        target.radius=source.radius
        return
    }
    if d+r2>r1 {
        k:=d>0?(d+r2-r1)/(2*d):0
        target.center.x+=dx*k
        target.center.y+=dy*k
        target.center.z+=dz*k
        target.radius=(d+r2+r1)/2
    }
}

// The share of the merged sphere the radius of target is: near 1 for groups
// that overlap.
@(private="file")
bounds_score :: proc "contextless" (target,source:Cluster_Group) -> f32 {
    r1,r2:=target.radius,source.radius
    dx,dy,dz:=source.center.x-target.center.x,source.center.y-target.center.y,source.center.z-target.center.z
    d:=math.sqrt(dx*dx+dy*dy+dz*dz)
    mr:=d+r1<r2?r2:(d+r2<r1?r1:(d+r2+r1)/2)
    return mr>0?r1/mr:0
}

@(private="file")
group_to_merge :: proc "contextless" (groups:[]Cluster_Group,id:i32,adjacency:^Cluster_Adjacency,max_partition_size:u32,weight_acc,shared_acc:[]u32) -> (best_group:i32,best_shared:u32) #no_bounds_check {
    group_rsqrt:=1/math.sqrt(f32(i32(groups[id].vertices)))
    best_group=-1
    best_score:f32
    // What each adjacent group shares with this one, over their clusters; weight_acc and shared_acc are zero on entry.
    for ci:=id;ci>=0;ci=groups[ci].next {
        for adj in adjacency.offsets[ci]..<adjacency.offsets[ci+1] {
            other:=groups[adjacency.clusters[adj]].group
            if other>=0 {
                weight_acc[other]+=adjacency.weight[adj]
                shared_acc[other]+=adjacency.shared[adj]
            }
        }
    }
    // Each scored once, and its sums cleared before any early way out.
    for ci:=id;ci>=0;ci=groups[ci].next {
        for adj in adjacency.offsets[ci]..<adjacency.offsets[ci+1] {
            other:=groups[adjacency.clusters[adj]].group
            if other<0 || weight_acc[other]==0 {continue}
            weight,shared:=weight_acc[other],shared_acc[other]
            weight_acc[other]=0
            shared_acc[other]=0
            if groups[id].size+groups[other].size>max_partition_size {continue}
            other_rsqrt:=1/math.sqrt(f32(i32(groups[other].vertices)))
            // Normalized by the expected boundary of each group, which keeps it symmetric.
            score:=f32(i32(weight))*(group_rsqrt+other_rsqrt)
            score*=1+0.4*bounds_score(groups[id],groups[other])
            if score>best_score {
                best_group=other
                best_score=score
                best_shared=shared
            }
        }
    }
    return
}

@(private="file")
merge_leaf :: proc "contextless" (groups:[]Cluster_Group,order:[]u32,target_partition_size,max_partition_size:u32) #no_bounds_check {
    for id in order {
        if groups[id].size==0 || groups[id].size>=target_partition_size {continue}
        best_score:=f32(-1)
        best_group:=i32(-1)
        for other in order {
            if id==other || groups[other].size==0 {continue}
            if groups[id].size+groups[other].size>max_partition_size {continue}
            score:=bounds_score(groups[id],groups[other])
            if score>best_score {
                best_score=score
                best_group=i32(other)
            }
        }
        // id joins best_group, which may take more groups and reach the target.
        if best_group!=-1 {
            tail:=best_group
            for groups[tail].next>=0 {tail=groups[tail].next}
            groups[tail].next=i32(id)
            groups[best_group].size+=groups[id].size
            groups[id].size=0
            bounds_merge(&groups[best_group],groups[id])
            groups[id].radius=0
        }
    }
}

@(private="file")
merge_partition :: proc "contextless" (order:[]u32,groups:[]Cluster_Group,axis:int,pivot:f32) -> int #no_bounds_check {
    m:=0
    for i in 0..<len(order) {
        v:=groups[order[i]].center[axis]
        order[m],order[i]=order[i],order[m]
        m+=int(v<pivot)
    }
    return m
}

@(private="file")
merge_spatial :: proc "contextless" (groups:[]Cluster_Group,order:[]u32,target_partition_size,max_partition_size:u32,leaf_size,depth:int) #no_bounds_check {
    count:=len(order)
    total:u32
    for id in order {total+=groups[id].size}
    if total<=max_partition_size || count<=leaf_size {
        merge_leaf(groups,order,target_partition_size,max_partition_size)
        return
    }
    mean,vars:[3]f32
    runc,runs:=f32(1),f32(1)
    for id in order {
        point:=groups[id].center
        for k in 0..<3 {
            delta:=point[k]-mean[k]
            mean[k]+=delta*runs
            vars[k]+=delta*(point[k]-mean[k])
        }
        runc+=1
        runs=1/runc
    }
    axis:=(vars[0]>=vars[1] && vars[0]>=vars[2])?0:(vars[1]>=vars[2]?1:2)
    middle:=merge_partition(order,groups,axis,mean[axis])
    // A degenerate or too deep split halves the order instead.
    if middle<=leaf_size/2 || count-middle<=leaf_size/2 || depth>=MERGE_DEPTH_CUTOFF {middle=count/2}
    merge_spatial(groups,order[:middle],target_partition_size,max_partition_size,leaf_size,depth+1)
    merge_spatial(groups,order[middle:],target_partition_size,max_partition_size,leaf_size,depth+1)
}

@(private="file")
morton_spread :: #force_inline proc "contextless" (x:u32) -> u32 {
    x:=x&0x3ff
    x=(x|x<<16)&0x030000ff
    x=(x|x<<8)&0x0300f00f
    x=(x|x<<4)&0x030c30c3
    x=(x|x<<2)&0x09249249
    return x
}

@(private="file")
piece_root :: proc "contextless" (parents:[]u32,index:u32) -> u32 #no_bounds_check {
    index:=index
    for index!=parents[index] {
        parent:=parents[index]
        parents[index]=parents[parent]
        index=parent
    }
    return index
}

// The near links of each cluster, both ways and without repeats: those of c
// are links[link_offsets[c]:link_offsets[c+1]].
@(private="file")
near_links_build :: proc(geometric:^Cluster_Adjacency,groups:[]Cluster_Group,scratch:runtime.Allocator) -> (link_offsets,links:[]u32,ok:bool) #no_bounds_check {
    cluster_count:=len(groups)
    failed:[7]runtime.Allocator_Error
    pieces:[]u32
    if pieces,failed[0]=make([]u32,cluster_count,scratch);failed[0]!=nil {return}
    for &p,i in pieces {p=u32(i)}
    for c in 0..<cluster_count {
        for adj in geometric.offsets[c]..<geometric.offsets[c+1] {
            a,b:=piece_root(pieces,u32(c)),piece_root(pieces,geometric.clusters[adj])
            if a!=b {pieces[max(a,b)]=min(a,b)}
        }
    }
    for c in 0..<cluster_count {pieces[c]=piece_root(pieces,u32(c))}
    lo,hi:=Vec3{max(f32),max(f32),max(f32)},Vec3{-max(f32),-max(f32),-max(f32)}
    for g in groups {
        lo={min(lo.x,g.center.x),min(lo.y,g.center.y),min(lo.z,g.center.z)}
        hi={max(hi.x,g.center.x),max(hi.y,g.center.y),max(hi.z,g.center.z)}
    }
    extent:=max(hi.x-lo.x,hi.y-lo.y,hi.z-lo.z)
    scale:=extent>0?1023/extent:0
    Keyed :: struct {key,id:u32}
    sorted:[]Keyed
    run_begin,run_end:[]u32
    found:[dynamic][2]u32
    sorted,failed[1]=make([]Keyed,cluster_count,scratch)
    run_begin,failed[2]=make([]u32,cluster_count,scratch)
    run_end,failed[3]=make([]u32,cluster_count,scratch)
    // Each cluster adds its nearest ones both ways.
    found,failed[4]=make([dynamic][2]u32,0,cluster_count*PARTITION_NEAR_LINKS*2,scratch)
    link_offsets,failed[5]=make([]u32,cluster_count+1,scratch)
    for f in failed {
        if f!=nil {return nil,nil,false}
    }
    for g,i in groups {
        q:=[3]u32{u32((g.center.x-lo.x)*scale),u32((g.center.y-lo.y)*scale),u32((g.center.z-lo.z)*scale)}
        sorted[i]={morton_spread(q[0])|morton_spread(q[1])<<1|morton_spread(q[2])<<2,u32(i)}
    }
    slice.sort_by(sorted,proc(a,b:Keyed) -> bool {return a.key<b.key || a.key==b.key && a.id<b.id})
    // The run of the same piece each place of the order is in.
    first:=0
    for i in 1..=cluster_count {
        if i<cluster_count && pieces[sorted[i].id]==pieces[sorted[first].id] {continue}
        for j in first..<i {run_begin[j],run_end[j]=u32(first),u32(i)}
        first=i
    }
    for i in 0..<cluster_count {
        if run_end[i]-run_begin[i]>=PARTITION_NEAR_PIECE {continue}
        id:=sorted[i].id
        center:=groups[id].center
        closest:[PARTITION_NEAR_LINKS]u32
        closest_distance:[PARTITION_NEAR_LINKS]f32
        for k in 0..<PARTITION_NEAR_LINKS {closest[k],closest_distance[k]=NONE,max(f32)}
        for direction in 0..<2 {
            at:=i
            for _ in 0..<PARTITION_NEAR_STEPS {
                if direction==0 && at==0 || direction==1 && at==cluster_count-1 {break}
                at+=direction==1?1:-1
                other:=sorted[at].id
                if pieces[other]==pieces[id] {
                    // Past this run of the same piece.
                    at=direction==1?int(run_end[at])-1:int(run_begin[at])
                    continue
                }
                d:=groups[other].center-center
                distance:=d.x*d.x+d.y*d.y+d.z*d.z
                // Kept sorted, nearest first.
                candidate,candidate_distance:=other,distance
                for k in 0..<PARTITION_NEAR_LINKS {
                    if candidate_distance<closest_distance[k] || candidate_distance==closest_distance[k] && candidate<closest[k] {
                        closest[k],candidate=candidate,closest[k]
                        closest_distance[k],candidate_distance=candidate_distance,closest_distance[k]
                    }
                }
            }
        }
        for other in closest {
            if other==NONE {continue}
            push(&found,[2]u32{id,other});push(&found,[2]u32{other,id})
        }
    }
    slice.sort_by(found[:],proc(a,b:[2]u32) -> bool {return a[0]<b[0] || a[0]==b[0] && a[1]<b[1]})
    unique:[dynamic]u32
    if unique,failed[6]=make([dynamic]u32,0,len(found),scratch);failed[6]!=nil {return nil,nil,false}
    for pair,i in found {
        if i>0 && found[i-1]==pair {continue}
        link_offsets[pair[0]+1]+=1
        push(&unique,pair[1])
    }
    for c in 0..<cluster_count {link_offsets[c+1]+=link_offsets[c]}
    return link_offsets,unique[:],true
}

// Writes to destination (one per cluster) the group of each cluster and
// returns how many groups there are, of about target_partition_size
// clusters and at most a third more. cluster_indices holds the vertices of
// each cluster in turn, cluster_index_counts[c] of them for cluster c, as
// vertices of positions; those of one position should be one vertex there,
// since only shared vertices join clusters. generators, empty or one per
// cluster, is the group of the level before each cluster comes from (NONE
// for none): siblings weigh less. Scratch memory comes from
// context.temp_allocator.
clusters_partition :: proc(destination,cluster_indices,cluster_index_counts:[]u32,positions:[]Vec3,target_partition_size:int,generators:[]u32=nil) -> (count:int,error:Partition_Error) #no_bounds_check {
    cluster_count:=len(cluster_index_counts)
    vertex_count:=len(positions)
    if target_partition_size<=0 || len(destination)<cluster_count || len(generators)!=0 && len(generators)!=cluster_count || vertex_count>=int(NONE) || cluster_count>=int(max(i32)) {return 0,.Invalid_Clusters}
    total:=0
    for c in cluster_index_counts {
        if c==0 {return 0,.Invalid_Clusters}
        total+=int(c)
    }
    if total!=len(cluster_indices) {return 0,.Invalid_Clusters}
    for index in cluster_indices {
        if int(index)>=vertex_count || !finite3(positions[index]) {return 0,.Invalid_Clusters}
    }
    if cluster_count==0 {return 0,.None}
    target:=u32(min(target_partition_size,int(max(u32)/2)))
    max_partition_size:=target+target/3

    runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
    scratch:=context.temp_allocator
    used:=make([]u8,vertex_count,scratch)
    // The vertices of each cluster without repeats: those of c are filtered[offsets[c]:offsets[c+1]].
    filtered:=make([]u32,len(cluster_indices),scratch)
    offsets:=make([]u32,cluster_count+1,scratch)
    if used==nil && vertex_count>0 || filtered==nil && len(cluster_indices)>0 || offsets==nil {return 0,.Out_Of_Memory}
    {
        start,write:=0,u32(0)
        for c in 0..<cluster_count {
            offsets[c]=write
            for v in cluster_indices[start:][:cluster_index_counts[c]] {
                filtered[write]=v
                write+=u32(1-used[v])
                used[v]=1
            }
            for v in filtered[offsets[c]:write] {used[v]=0}
            start+=int(cluster_index_counts[c])
        }
        offsets[cluster_count]=write
    }

    // The clusters of each vertex, and from them the clusters each cluster shares vertices with.
    ref_offsets:=make([]u32,vertex_count+1,scratch)
    for c in 0..<cluster_count {
        for v in filtered[offsets[c]:offsets[c+1]] {ref_offsets[v]+=1}
    }
    total_adjacency:=0
    for c in 0..<cluster_count {
        n:=0
        for v in filtered[offsets[c]:offsets[c+1]] {n+=int(ref_offsets[v])-1}
        total_adjacency+=min(n,cluster_count-1)
    }
    total_refs:u32
    for v in 0..<vertex_count {
        n:=ref_offsets[v]
        ref_offsets[v]=total_refs
        total_refs+=n
    }
    ref_data:=make([]u32,total_refs,scratch)
    if ref_offsets==nil || total_refs>0 && ref_data==nil {return 0,.Out_Of_Memory}
    for c in 0..<cluster_count {
        for v in filtered[offsets[c]:offsets[c+1]] {
            ref_data[ref_offsets[v]]=u32(c)
            ref_offsets[v]+=1
        }
    }
    copy(ref_offsets[1:],ref_offsets[:vertex_count])
    ref_offsets[0]=0
    geometric:Cluster_Adjacency
    geometric.offsets=make([]u32,cluster_count+1,scratch)
    geometric.clusters=make([]u32,total_adjacency,scratch)
    geometric.shared=make([]u32,total_adjacency,scratch)
    slots:=make([]u32,cluster_count,scratch)
    if geometric.offsets==nil || total_adjacency>0 && (geometric.clusters==nil || geometric.shared==nil) || slots==nil {return 0,.Out_Of_Memory}
    for &s in slots {s=NONE}
    for c in 0..<cluster_count {
        adj:=geometric.clusters[geometric.offsets[c]:]
        shd:=geometric.shared[geometric.offsets[c]:]
        n:u32
        for v in filtered[offsets[c]:offsets[c+1]] {
            for other in ref_data[ref_offsets[v]:ref_offsets[v+1]] {
                if other==u32(c) {continue}
                // Slots need no clearing between clusters: adj confirms them.
                slot:=slots[other]
                if slot<n && adj[slot]==other {
                    shd[slot]+=1
                } else {
                    slots[other]=n
                    adj[n]=other
                    shd[n]=1
                    n+=1
                }
            }
        }
        geometric.offsets[c+1]=geometric.offsets[c]+n
    }

    groups:=make([]Cluster_Group,cluster_count,scratch)
    if groups==nil {return 0,.Out_Of_Memory}
    for &g,c in groups {
        g.group=i32(c)
        g.next=-1
        g.size=1
        g.vertices=offsets[c+1]-offsets[c]
        // The mean of the vertices, and the farthest of them.
        vertices:=filtered[offsets[c]:offsets[c+1]]
        center:Vec3
        for v in vertices {center+=positions[v]}
        center/=f32(len(vertices))
        radiussq:f32
        for v in vertices {
            p:=positions[v]
            d2:=(p.x-center.x)*(p.x-center.x)+(p.y-center.y)*(p.y-center.y)+(p.z-center.z)*(p.z-center.z)
            radiussq=radiussq<d2?d2:radiussq
        }
        g.center=center
        g.radius=math.sqrt(radiussq)
    }

    // The weights of what clusters share, and the near links between pieces.
    link_offsets,links,linked:=near_links_build(&geometric,groups,scratch)
    if !linked {return 0,.Out_Of_Memory}
    adjacency:Cluster_Adjacency
    adjacency.offsets=make([]u32,cluster_count+1,scratch)
    edges:=int(geometric.offsets[cluster_count])+len(links)
    adjacency.clusters=make([]u32,edges,scratch)
    adjacency.shared=make([]u32,edges,scratch)
    adjacency.weight=make([]u32,edges,scratch)
    if adjacency.offsets==nil || edges>0 && (adjacency.clusters==nil || adjacency.shared==nil || adjacency.weight==nil) {return 0,.Out_Of_Memory}
    {
        n:u32
        for c in 0..<cluster_count {
            adjacency.offsets[c]=n
            for adj in geometric.offsets[c]..<geometric.offsets[c+1] {
                other:=geometric.clusters[adj]
                shared:=geometric.shared[adj]
                siblings:=len(generators)>0 && generators[c]!=NONE && generators[c]==generators[other]
                adjacency.clusters[n]=other
                adjacency.shared[n]=shared
                adjacency.weight[n]=shared*(siblings?PARTITION_WEIGHT_SIBLINGS:PARTITION_WEIGHT_SHARED)+PARTITION_WEIGHT_ADJACENT
                n+=1
            }
            for other in links[link_offsets[c]:link_offsets[c+1]] {
                adjacency.clusters[n]=other
                adjacency.weight[n]=PARTITION_WEIGHT_NEAR
                n+=1
            }
        }
        adjacency.offsets[cluster_count]=n
    }

    order:=make([]Group_Order,cluster_count,scratch)
    weight_acc:=make([]u32,cluster_count,scratch)
    shared_acc:=make([]u32,cluster_count,scratch)
    if order==nil || weight_acc==nil || shared_acc==nil {return 0,.Out_Of_Memory}
    pending:=0
    for c in 0..<cluster_count {
        order_push(order,pending,{u32(c),i32(groups[c].vertices)})
        pending+=1
    }
    // The group of fewest vertices merges with its best neighbor, until none can.
    for pending>0 {
        top:=order_pop(order,pending)
        pending-=1
        // Merged into another earlier.
        if groups[top.id].size==0 {continue}
        // Its clusters leave it so they are not merged again; they come back if it does.
        for i:=i32(top.id);i>=0;i=groups[i].next {groups[i].group=-1}
        if groups[top.id].size>=target {continue}
        best_group,best_shared:=group_to_merge(groups,i32(top.id),&adjacency,max_partition_size,weight_acc,shared_acc)
        if best_group==-1 {continue}
        tail:=i32(top.id)
        for groups[tail].next>=0 {tail=groups[tail].next}
        groups[tail].next=best_group
        // The vertices of the merge, approximated without counting them again.
        groups[top.id].size+=groups[best_group].size
        groups[top.id].vertices+=groups[best_group].vertices
        groups[top.id].vertices=groups[top.id].vertices>best_shared?groups[top.id].vertices-best_shared:1
        groups[best_group].size=0
        groups[best_group].vertices=0
        bounds_merge(&groups[top.id],groups[best_group])
        groups[best_group].radius=0
        for i:=i32(top.id);i>=0;i=groups[i].next {groups[i].group=i32(top.id)}
        top.order=i32(groups[top.id].vertices)
        order_push(order,pending,top)
        pending+=1
    }
    // Small groups left merge by place alone.
    merge_order:=make([]u32,cluster_count,scratch)
    merge_count:=0
    for g,c in groups {
        if g.size>0 {
            merge_order[merge_count]=u32(c)
            merge_count+=1
        }
    }
    merge_spatial(groups,merge_order[:merge_count],target,max_partition_size,8,0)

    next_group:u32
    for g,c in groups {
        if g.size==0 {continue}
        for j:=i32(c);j>=0;j=groups[j].next {destination[j]=next_group}
        next_group+=1
    }
    return int(next_group),.None
}
