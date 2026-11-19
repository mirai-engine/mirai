package geom

import "base:runtime"
import "core:math"
import "core:slice"

// Aggregate detail in the DAG of clusters: islands (leaves, cards, clumps of
// grass) that the coarser levels prune instead of simplifying (Cook,
// Halstead, Planck and Ryu, Stochastic simplification of aggregate detail,
// Pixar 2007). Simplifying each leaf by quadrics shrinks it to nothing and
// leaves a bare tree with metres of error.
//
// An island draws one of its outlines (rungs), the finest first, and is never
// split between clusters. Its islands of one class (an octave of radius of
// one submesh) are reduced together: first each steps to a coarser outline,
// then the class is halved, keeping the first of its islands in their fixed
// order (a prefix spread over the mesh) and growing them about their centers
// so they draw the area of level 0 that all of them stood for. The error of
// an island is that of its outline times its growth and, once pruned, at
// least the farther of the largest radius of its class grown and of how far
// the area of a dropped island moved, through the survivors that took it,
// over ISLAND_PIXELS of the threshold of the cut: what is drawn stays within
// a few pixels of where level 0 drew it. A class is pruned as far as that
// error lets the cut take it, down to one island, but never so far that its
// survivors grow past the cloud of their class (the sphere around its
// islands at level 0): an island larger than the plant it is part of no
// longer stands for scattered leaves, draws the plant larger than it is,
// and the box of the mesh, which culling, the sway of the wind and the far
// form of foliage take, would grow with it. Where its leaves overlap little
// a class prunes on to one island; where they overlap much, to the few that
// fill its cloud. It never drops its last: the rest of a mesh does not stand
// for the area of its islands.
//
// The clusters of islands make their own levels in the DAG, beside those of
// the rest of the mesh, which share no place with them. Clusters of whole
// islands and groups of clusters are cut by halving the box of their centers;
// a group is reduced as far as the error of its clusters allows, then by the
// least more that brings it to CLUSTER_SIMPLIFY_RATIO of its triangles and
// adds to the error of its clusters, and it keeps the rules of the DAG: its error is the largest of its clusters'
// and its own, in a sphere around theirs, and a group that cannot lose more
// than 1-CLUSTER_SIMPLIFY_STUCK of its triangles is a root. A group of one
// cluster is reduced too, so a plant far away keeps shedding its leaves. So only the near
// clusters of a plant draw its finest outlines, and a level changes one
// group at a time.
//
// And it changes without a pop (Cook et al. 2007, section 3.5): every vertex
// of an island in a cluster carries where its island goes as the cut moves
// from the error of the cluster to that of its group (Cluster_Made.scale,
// rank). A survivor grows to the area it draws in the next level, linearly;
// those its group drops shrink to nothing one after another in the order
// they were dropped in, the last first, each over a band of the way
// (asset.ISLAND_FADE_BAND), so the area of the group goes over evenly.
// A step of outline is under the threshold already and has no band.

ISLAND_PIXELS :: f32(8) // of the threshold of the cut, how far a grown island may span, and the area of a dropped one move, where its level draws it

// An island: its outlines are Cluster_Source.island_rungs[first_rung:][:rung_count].
Cluster_Island :: struct {
    first_rung,rung_count:u32,
    submesh:u32,
    class:u32,   // islands of one class are pruned together
    center:Vec3, // what it grows around
    radius:f32,  // around center, of its first outline
    order:u64,   // where it comes in the order a class is pruned in: the first are kept
}

// An outline of an island: Cluster_Source.island_indices[first_index:][:index_count].
Cluster_Island_Rung :: struct {
    first_index,index_count:u32,
    error:f32, // how far it draws from what the island stands for, in the units of the positions
}

// What an island draws at a level.
Cluster_Island_State :: struct {
    island:u32,
    rung:u32,    // of its outlines
    grow:f32,    // about its center
    area:f32,    // of its first outline, that it stands for: its own, and once pruned a share of those dropped
    error:f32,
    pruned:bool, // its class was halved: it stays at its last outline
    cover:[4]f32, // once pruned, the sphere around the centers of the islands of level 0 it stands for
}

// A vertex of a DAG past the positions it was built from: a copy of one of
// them, moved, and where it goes as its cluster gives way to its group. It
// keeps its place about center where scale is 1.
Cluster_Made :: struct {
    vertex:u32,
    position:Vec3,
    center:Vec3, // of its island
    scale:f32,   // how much its island grows by in the next level; 0: it is dropped
    rank:f32,    // of a dropped island, where it is among those of its class its group drops, 0 to 1: the last go first
}

// The area each outline of islands draws, in allocator.
islands_areas :: proc(positions:[]Vec3,rungs:[]Cluster_Island_Rung,indices:[]u32,allocator:=context.allocator) -> (areas:[]f32,ok:bool) {
    error:runtime.Allocator_Error
    if areas,error=make([]f32,len(rungs),allocator);error!=nil {return}
    for rung,at in rungs {
        sum:f32
        for t:=u32(0);t+2<rung.index_count;t+=3 {
            p0,p1,p2:=positions[indices[rung.first_index+t]],positions[indices[rung.first_index+t+1]],positions[indices[rung.first_index+t+2]]
            a,b:=p1-p0,p2-p0
            c:=Vec3{a.y*b.z-a.z*b.y,a.z*b.x-a.x*b.z,a.x*b.y-a.y*b.x}
            sum+=0.5*math.sqrt(c.x*c.x+c.y*c.y+c.z*c.z)
        }
        areas[at]=sum
    }
    return areas,true
}

// Of each island, the radius of the cloud of its class: the sphere around
// the islands of the class; in allocator.
islands_clouds :: proc(islands:[]Cluster_Island,allocator:=context.allocator) -> (clouds:[]f32,ok:bool) {
    Pair :: struct {class,at:u32}
    pairs,no_pairs:=make([]Pair,len(islands),context.temp_allocator)
    centers,no_centers:=make([]Vec3,len(islands),context.temp_allocator)
    radii,no_radii:=make([]f32,len(islands),context.temp_allocator)
    if no_pairs!=nil || no_centers!=nil || no_radii!=nil {return}
    error:runtime.Allocator_Error
    if clouds,error=make([]f32,len(islands),allocator);error!=nil {return}
    for island,at in islands {pairs[at]={island.class,u32(at)}}
    slice.sort_by(pairs,proc(a,b:Pair) -> bool {return a.class<b.class || a.class==b.class && a.at<b.at})
    for first:=0;first<len(pairs); {
        end:=first
        for end<len(pairs) && pairs[end].class==pairs[first].class {
            centers[end-first],radii[end-first]=islands[pairs[end].at].center,islands[pairs[end].at].radius
            end+=1
        }
        _,cloud:=spheres_bound(centers[:end-first],radii[:end-first])
        for p in pairs[first:end] {clouds[p.at]=cloud}
        first=end
    }
    return clouds,true
}

// The rung an island draws at state s of its class: s or its last.
@(private="file")
island_rung :: #force_inline proc "contextless" (island:Cluster_Island,rung:u32) -> u32 {
    return island.first_rung+min(rung,island.rung_count-1)
}

// The next step of a class whose islands are states, which come in their
// order: the rung all of them step to, or how many it keeps halved and how
// much they grow; ok false where it cannot take one.
@(private="file")
Island_Step :: struct {
    rung:u32,
    keep:int, // 0: a step of outline
    grow:f32,
    error:f32,
}

@(private="file")
island_step :: proc "contextless" (states:[]Cluster_Island_State,islands:[]Cluster_Island,rungs:[]Cluster_Island_Rung,areas,clouds:[]f32,covers:[][4]f32) -> (step:Island_Step,ok:bool) #no_bounds_check {
    if len(states)==0 {return}
    count,rung:u32
    pruned:=false
    for s in states {
        count=max(count,islands[s.island].rung_count)
        rung=max(rung,s.rung)
        pruned||=s.pruned
    }
    if !pruned && rung+1<count {
        step.rung=rung+1
        for s in states {step.error=max(step.error,s.error,rungs[island_rung(islands[s.island],step.rung)].error*s.grow)}
        return step,step.error-step.error==0
    }
    if len(states)<2 {return}
    step.keep=(len(states)+1)/2
    total,kept,largest,reach:f32
    for s,at in states {
        island:=islands[s.island]
        total+=s.area
        largest=max(largest,island.radius)
        if at<step.keep {kept+=areas[island_rung(island,island.rung_count-1)]}
    }
    island_covers(states,islands,step.keep,covers)
    for s,at in states[:step.keep] {
        d:=covers[at].xyz-islands[s.island].center
        reach=max(reach,math.sqrt(d.x*d.x+d.y*d.y+d.z*d.z)+covers[at].w)
    }
    if !(kept>0) {return}
    step.grow=max(math.sqrt(total/kept),1)
    if !(largest*step.grow<=clouds[states[0].island]) {return}
    step.error=max(largest*step.grow,reach)/ISLAND_PIXELS
    for s,at in states {
        step.error=max(step.error,s.error)
        if at<step.keep {step.error=max(step.error,rungs[island_rung(islands[s.island],islands[s.island].rung_count-1)].error*step.grow)}
    }
    return step,step.error-step.error==0
}

// The covers of the first keep of states once a halving drops the others,
// in covers: each dropped island goes to the survivor nearest to it.
@(private="file")
island_covers :: proc "contextless" (states:[]Cluster_Island_State,islands:[]Cluster_Island,keep:int,covers:[][4]f32) #no_bounds_check {
    cover :: proc "contextless" (s:Cluster_Island_State,islands:[]Cluster_Island) -> [4]f32 {
        if s.pruned {return s.cover}
        c:=islands[s.island].center
        return {c.x,c.y,c.z,0}
    }
    for s,at in states[:keep] {covers[at]=cover(s,islands)}
    for s in states[keep:] {
        center:=islands[s.island].center
        nearest:=0
        least:=max(f32)
        for k,at in states[:keep] {
            d:=islands[k.island].center-center
            if l:=d.x*d.x+d.y*d.y+d.z*d.z;l<least {least,nearest=l,at}
        }
        // The sphere around both.
        a,b:=covers[nearest],cover(s,islands)
        d:=b.xyz-a.xyz
        l:=math.sqrt(d.x*d.x+d.y*d.y+d.z*d.z)
        if l+b.w<=a.w {continue}
        if l+a.w<=b.w {covers[nearest]=b;continue}
        r:=(l+a.w+b.w)*0.5
        c:=a.xyz+d*((r-a.w)/l)
        covers[nearest]={c.x,c.y,c.z,r}
    }
}

// Takes a step: the islands a halving drops are left after those it keeps,
// with area -1, the nearest survivor of each taking where its area lies.
@(private="file")
island_apply :: proc "contextless" (states:[]Cluster_Island_State,islands:[]Cluster_Island,rungs:[]Cluster_Island_Rung,areas:[]f32,covers:[][4]f32,step:Island_Step) #no_bounds_check {
    if step.keep==0 {
        for &s in states {
            s.rung=step.rung
            s.error=max(s.error,rungs[island_rung(islands[s.island],s.rung)].error*s.grow)
        }
        return
    }
    island_covers(states,islands,step.keep,covers)
    for &s,at in states {
        if at>=step.keep {s.area=-1;continue}
        island:=islands[s.island]
        s.rung=island.rung_count-1
        s.grow=step.grow
        s.area=step.grow*step.grow*areas[island_rung(island,s.rung)]
        s.error=step.error
        s.pruned=true
        s.cover=covers[at]
    }
}

// Sorts states by class, then order, ties by island. False without memory.
@(private="file")
islands_sort :: proc(states:[]Cluster_Island_State,islands:[]Cluster_Island) -> bool {
    Pair :: struct {class:u32,order:u64,island:u32,at:int}
    pairs,no_pairs:=make([]Pair,len(states),context.temp_allocator)
    sorted,no_sorted:=make([]Cluster_Island_State,len(states),context.temp_allocator)
    if no_pairs!=nil || no_sorted!=nil {return false}
    for s,at in states {pairs[at]={islands[s.island].class,islands[s.island].order,s.island,at}}
    slice.sort_by(pairs,proc(a,b:Pair) -> bool {
        if a.class!=b.class {return a.class<b.class}
        if a.order!=b.order {return a.order<b.order}
        return a.island<b.island
    })
    for p,at in pairs {sorted[at]=states[p.at]}
    copy(states,sorted)
    return true
}

// Reduces islands, each at its state, as a group of the DAG or a whole level
// does: every class goes as far as `allowed` lets it, then `allowed` rises
// to the least that moves one more class while they draw more than `target`
// triangles. The states that remain come first, by class and order; returns
// how many, the `allowed` it ended at, the largest error among them and the
// triangles they draw; those it drops follow, each class in its order. ok
// false without memory, the states as they were.
islands_reduce :: proc(states:[]Cluster_Island_State,islands:[]Cluster_Island,rungs:[]Cluster_Island_Rung,areas,clouds:[]f32,allowed:f32,target:int) -> (kept:int,reached:f32,error:f32,triangles:int,ok:bool) #no_bounds_check {
    sorted,no_sorted:=make([]Cluster_Island_State,len(states),context.temp_allocator)
    ordered,no_ordered:=make([]Cluster_Island_State,len(states),context.temp_allocator)
    covers,no_covers:=make([][4]f32,len(states),context.temp_allocator)
    if no_sorted!=nil || no_ordered!=nil || no_covers!=nil || !islands_sort(states,islands) {return}
    copy(sorted,states)
    // The classes as runs of states: [first,first+alive) live, the rest dropped.
    Run :: struct {first,alive:int}
    runs:=make([dynamic]Run,context.temp_allocator)
    for at:=0;at<len(states); {
        end:=at+1
        for end<len(states) && islands[states[end].island].class==islands[states[at].island].class {end+=1}
        if _,failed:=append(&runs,Run{at,end-at});failed!=nil {copy(states,sorted);return}
        at=end
    }
    reached=allowed
    for {
        triangles=0
        for &run in runs {
            for {
                live:=states[run.first:][:run.alive]
                step,ok:=island_step(live,islands,rungs,areas,clouds,covers)
                if !ok || step.error>reached {break}
                island_apply(live,islands,rungs,areas,covers,step)
                if step.keep>0 {run.alive=step.keep}
            }
            for s in states[run.first:][:run.alive] {triangles+=int(rungs[island_rung(islands[s.island],s.rung)].index_count/3)}
        }
        if triangles<=target {break}
        next:=max(f32)
        for run in runs {
            if step,ok:=island_step(states[run.first:][:run.alive],islands,rungs,areas,clouds,covers);ok {next=min(next,step.error)}
        }
        if next==max(f32) {break}
        reached=max(reached,next)
    }
    // The survivors first, then those dropped, each in the order of its class.
    at:=0
    for run in runs {
        for s in states[run.first:][:run.alive] {
            ordered[at]=s
            error=max(error,s.error)
            at+=1
        }
    }
    kept=at
    for run in runs {
        end:=run.first+1
        for end<len(states) && islands[states[end].island].class==islands[states[run.first].island].class {end+=1}
        for s in states[run.first+run.alive:end] {ordered[at]=s;at+=1}
    }
    copy(states,ordered)
    ok=true
    return
}

// Halves items along the longest side of the box of their centers until a
// part fits limit (in each of the two sizes of an item), each cut where the
// part before holds as many whole parts as it can: order is rewritten so
// each part is a run, and the end of each run appended to ends.
@(private)
spatial_runs :: proc(centers:[]Vec3,sizes:[][2]u32,limit:[2]u32,order:[]u32,ends:^[dynamic]u32) -> bool {
    Part :: struct {first,count:int}
    stack:=make([dynamic]Part,context.temp_allocator)
    Keyed :: struct {key:f32,item:u32}
    keyed:=make([dynamic]Keyed,context.temp_allocator)
    if _,error:=append(&stack,Part{0,len(order)});error!=nil {return false}
    for len(stack)>0 {
        part:=pop(&stack)
        items:=order[part.first:][:part.count]
        total:[2]u32
        low,high:=Vec3{max(f32),max(f32),max(f32)},Vec3{-max(f32),-max(f32),-max(f32)}
        for item in items {
            total+=sizes[item]
            c:=centers[item]
            low,high={min(low.x,c.x),min(low.y,c.y),min(low.z,c.z)},{max(high.x,c.x),max(high.y,c.y),max(high.z,c.z)}
        }
        parts:=max((total[0]+limit[0]-1)/limit[0],(total[1]+limit[1]-1)/limit[1])
        if parts<=1 || len(items)==1 {
            if _,error:=append(ends,u32(part.first+part.count));error!=nil {return false}
            continue
        }
        side:=high-low
        axis:=0
        if side.y>side[axis] {axis=1}
        if side.z>side[axis] {axis=2}
        clear(&keyed)
        for item in items {
            if _,error:=append(&keyed,Keyed{centers[item][axis],item});error!=nil {return false}
        }
        slice.sort_by(keyed[:],proc(a,b:Keyed) -> bool {return a.key<b.key || a.key==b.key && a.item<b.item})
        for k,at in keyed {items[at]=k.item}
        // The part before takes ceil(parts/2) parts' worth, and one item at least.
        room:=limit*((parts+1)/2)
        split:=1
        sum:=sizes[items[0]]
        for split<len(items)-1 {
            next:=sum+sizes[items[split]]
            if next[0]>room[0] || next[1]>room[1] {break}
            sum=next
            split+=1
        }
        // Later parts go first on the stack: the runs come in order.
        if _,error:=append(&stack,Part{part.first+split,part.count-split},Part{part.first,split});error!=nil {return false}
    }
    return true
}

// A cluster of islands being built: its states are those of
// Island_Builder.states[first:][:count].
@(private="file")
Island_Pending :: struct {
    first,count:u32,
    own:Cluster_Lod,
    generator:u32,
    submesh:u32,
}

@(private="file")
Island_Builder :: struct {
    b:^Dag_Builder,
    source:Cluster_Source,
    areas:[]f32,
    clouds:[]f32, // islands_clouds
    vertices:[]u32, // of each rung, distinct
    positions:[dynamic]Vec3, // those of the source, then those made
    stamp:[]u32,             // of each position of the source: the made one it is in the cluster being output
    // Of each island, where it goes in the group being output: its scale and rank (Cluster_Made).
    scale,rank:[]f32,
}

// Splits states (all of one submesh) in clusters of whole islands appended
// to out, their states to states.
@(private="file")
islands_clusterize :: proc(ib:^Island_Builder,given:[]Cluster_Island_State,submesh:u32,own:Cluster_Lod,generator:u32,out:^[dynamic]Island_Pending,states:^[dynamic]Cluster_Island_State) -> Cluster_Error {
    if len(given)==0 {return .None}
    centers,no_centers:=make([]Vec3,len(given),context.temp_allocator)
    sizes,no_sizes:=make([][2]u32,len(given),context.temp_allocator)
    order,no_order:=make([]u32,len(given),context.temp_allocator)
    if no_centers!=nil || no_sizes!=nil || no_order!=nil {return .Out_Of_Memory}
    for s,at in given {
        island:=ib.source.islands[s.island]
        r:=island_rung(island,s.rung)
        centers[at]=island.center
        sizes[at]={ib.source.island_rungs[r].index_count/3,ib.vertices[r]}
        order[at]=u32(at)
    }
    ends:=make([dynamic]u32,context.temp_allocator)
    if !spatial_runs(centers,sizes,{CLUSTER_MAX_TRIANGLES,CLUSTER_MAX_VERTICES},order,&ends) {return .Out_Of_Memory}
    first:u32
    for end in ends {
        cluster:=Island_Pending{first=u32(len(states)),count=end-first,own=own,generator=generator,submesh=submesh}
        for at in order[first:end] {
            if _,error:=append(states,given[at]);error!=nil {return .Out_Of_Memory}
        }
        if _,error:=append(out,cluster);error!=nil {return .Out_Of_Memory}
        first=end
    }
    return .None
}

// The triangles of a cluster of islands, as made vertices, appended to indices.
@(private="file")
islands_triangles :: proc(ib:^Island_Builder,states:[]Cluster_Island_State,indices:^[dynamic]u32) -> Cluster_Error {
    dag:=ib.b.dag
    for s in states {
        island:=ib.source.islands[s.island]
        rung:=ib.source.island_rungs[island_rung(island,s.rung)]
        corners:=ib.source.island_indices[rung.first_index:][:rung.index_count]
        for index in corners {
            if ib.stamp[index]==NONE {
                p:=island.center+(ib.source.positions[index]-island.center)*s.grow
                ib.stamp[index]=u32(len(ib.positions))
                _,no_position:=append(&ib.positions,p)
                _,no_made:=append(&dag.made,Cluster_Made{index,p,island.center,ib.scale[s.island],ib.rank[s.island]})
                if no_position!=nil || no_made!=nil {return .Out_Of_Memory}
            }
            if _,error:=append(indices,ib.stamp[index]);error!=nil {return .Out_Of_Memory}
        }
        for index in corners {ib.stamp[index]=NONE}
    }
    return .None
}

// Appends the clusters of a group of islands to the DAG; returns its index.
@(private="file")
islands_output :: proc(ib:^Island_Builder,clusters:[]Island_Pending,states:[]Cluster_Island_State,parent:Cluster_Lod,level:int) -> (group:u32,error:Cluster_Error) {
    pending:=make([dynamic]Pending,0,len(clusters),context.temp_allocator)
    indices:=make([dynamic]u32,context.temp_allocator)
    for c in clusters {
        first:=u32(len(indices))
        islands_triangles(ib,states[c.first:][:c.count],&indices) or_return
        if _,failed:=append(&pending,Pending{first,u32(len(indices))-first,c.own,c.generator,c.submesh});failed!=nil {return 0,.Out_Of_Memory}
    }
    written:bool
    group,written=group_output(ib.b,pending[:],indices[:],ib.positions[:],parent,level)
    return group,.None if written else .Out_Of_Memory
}

// The levels of the islands of source in the DAG of b (see above).
@(private)
islands_dag :: proc(b:^Dag_Builder,source:Cluster_Source) -> Cluster_Error {
    if len(source.islands)==0 {return .None}
    ib:=Island_Builder{b=b,source=source}
    scratch:=context.temp_allocator
    measured:bool
    if ib.areas,measured=islands_areas(source.positions,source.island_rungs,source.island_indices,scratch);!measured {return .Out_Of_Memory}
    if ib.clouds,measured=islands_clouds(source.islands,scratch);!measured {return .Out_Of_Memory}
    no_vertices,no_stamp,no_scale,no_rank:runtime.Allocator_Error
    ib.vertices,no_vertices=make([]u32,len(source.island_rungs),scratch)
    ib.stamp,no_stamp=make([]u32,len(source.positions),scratch)
    ib.scale,no_scale=make([]f32,len(source.islands),scratch)
    ib.rank,no_rank=make([]f32,len(source.islands),scratch)
    if no_vertices!=nil || no_stamp!=nil || no_scale!=nil || no_rank!=nil {return .Out_Of_Memory}
    for &k in ib.scale {k=1}
    ib.positions=make([dynamic]Vec3,scratch)
    if _,error:=append(&ib.positions,..source.positions);error!=nil {return .Out_Of_Memory}
    for &s in ib.stamp {s=NONE}
    for rung,at in source.island_rungs {
        for index in source.island_indices[rung.first_index:][:rung.index_count] {
            if ib.stamp[index]==NONE {ib.vertices[at]+=1;ib.stamp[index]=0}
        }
        for index in source.island_indices[rung.first_index:][:rung.index_count] {ib.stamp[index]=NONE}
        if rung.index_count/3>CLUSTER_MAX_TRIANGLES || ib.vertices[at]>CLUSTER_MAX_VERTICES {return .Invalid_Mesh}
    }
    // Level 0: the islands of each submesh at their first outline, measured exactly.
    clusters:=make([dynamic]Island_Pending,scratch)
    states:=make([dynamic]Cluster_Island_State,scratch)
    next_clusters:=make([dynamic]Island_Pending,scratch)
    next_states:=make([dynamic]Cluster_Island_State,scratch)
    given:=make([dynamic]Cluster_Island_State,scratch)
    submeshes:=make([dynamic]u32,scratch)
    for island in source.islands {
        if slice.contains(submeshes[:],island.submesh) {continue}
        if _,error:=append(&submeshes,island.submesh);error!=nil {return .Out_Of_Memory}
    }
    slice.sort(submeshes[:])
    for submesh in submeshes {
        clear(&given)
        for island,at in source.islands {
            if island.submesh!=submesh {continue}
            first:=island.first_rung
            if _,error:=append(&given,Cluster_Island_State{island=u32(at),grow=1,area=ib.areas[first],error=source.island_rungs[first].error});error!=nil {return .Out_Of_Memory}
        }
        islands_clusterize(&ib,given[:],submesh,{},NONE,&clusters,&states) or_return
    }
    corners:=make([dynamic]u32,scratch)
    for &c in clusters {
        clear(&corners)
        for s in states[c.first:][:c.count] {
            rung:=source.island_rungs[island_rung(source.islands[s.island],s.rung)]
            if _,error:=append(&corners,..source.island_indices[rung.first_index:][:rung.index_count]);error!=nil {return .Out_Of_Memory}
        }
        bounds:=cluster_bounds(corners[:],source.positions)
        c.own={bounds.center,bounds.radius,0}
    }
    work:runtime.Arena
    defer runtime.arena_destroy(&work)
    depth:=0
    // A group of one cluster too: a far plant still sheds its leaves, down to a root that cannot.
    for len(clusters)>0 {
        level_temp:=runtime.arena_temp_begin(&work)
        defer runtime.arena_temp_end(level_temp)
        context.temp_allocator=runtime.arena_allocator(&work)
        // The groups: runs of order.
        order,no_order:=make([]u32,len(clusters),context.temp_allocator)
        ends:=make([dynamic]u32,context.temp_allocator)
        if no_order!=nil {return .Out_Of_Memory}
        for &o,at in order {o=u32(at)}
        if len(clusters)>CLUSTER_GROUP_SIZE {
            centers,no_centers:=make([]Vec3,len(clusters),context.temp_allocator)
            sizes,no_sizes:=make([][2]u32,len(clusters),context.temp_allocator)
            if no_centers!=nil || no_sizes!=nil {return .Out_Of_Memory}
            for c,at in clusters {centers[at],sizes[at]=c.own.center,{1,0}}
            if !spatial_runs(centers,sizes,{CLUSTER_GROUP_SIZE,1},order,&ends) {return .Out_Of_Memory}
        } else {
            if _,error:=append(&ends,u32(len(clusters)));error!=nil {return .Out_Of_Memory}
        }
        clear(&next_clusters);clear(&next_states)
        first:u32
        for end in ends {
            group_temp:=runtime.arena_temp_begin(&work)
            defer runtime.arena_temp_end(group_temp)
            group,no_group:=make([]Island_Pending,end-first,context.temp_allocator)
            lods,no_lods:=make([]Cluster_Lod,end-first,context.temp_allocator)
            members:=make([dynamic]Cluster_Island_State,context.temp_allocator)
            group_states:=make([dynamic]Cluster_Island_State,context.temp_allocator)
            if no_group!=nil || no_lods!=nil {return .Out_Of_Memory}
            triangles:=0
            for at,k in order[first:end] {
                c:=clusters[at]
                // The clusters of the group with their states apart, as they are output.
                group[k]=c
                group[k].first=u32(len(group_states))
                lods[k]=c.own
                for s in states[c.first:][:c.count] {
                    _,no_state:=append(&group_states,s)
                    _,no_member:=append(&members,s)
                    if no_state!=nil || no_member!=nil {return .Out_Of_Memory}
                    triangles+=int(source.island_rungs[island_rung(source.islands[s.island],s.rung)].index_count/3)
                }
            }
            first=end
            bounds,bounded:=lod_merge(lods,context.temp_allocator)
            if !bounded {return .Out_Of_Memory}
            kept,_,error,left,reduced:=islands_reduce(members[:],source.islands,source.island_rungs,ib.areas,ib.clouds,bounds.error,int(f32(triangles)*CLUSTER_SIMPLIFY_RATIO))
            if !reduced {return .Out_Of_Memory}
            // A group that adds no error to that of its clusters is a level the cut never
            // draws, which those clusters would grow towards: it takes one more step.
            if !(error>bounds.error) && kept>0 {
                more,_,more_error,more_left,again:=islands_reduce(members[:kept],source.islands,source.island_rungs,ib.areas,ib.clouds,bounds.error,left-1)
                if !again {return .Out_Of_Memory}
                if more_error>bounds.error {
                    kept,error,left=more,more_error,more_left
                    // Those dropped, each class in its order again.
                    if !islands_sort(members[kept:],source.islands) {return .Out_Of_Memory}
                }
            }
            stuck:=f32(left)>f32(triangles)*CLUSTER_SIMPLIFY_STUCK
            if !stuck {
                // Where each island goes: a survivor to the area it draws in the next level,
                // its outline and growth there; those dropped, by their rank among the
                // dropped of their class.
                drawn :: proc(ib:^Island_Builder,s:Cluster_Island_State) -> f32 {
                    return s.grow*s.grow*ib.areas[island_rung(ib.source.islands[s.island],s.rung)]
                }
                for s in group_states {ib.scale[s.island]=drawn(&ib,s)}
                for s in members[:kept] {
                    before:=ib.scale[s.island]
                    ib.scale[s.island]=math.sqrt(drawn(&ib,s)/before) if before>0 else 1
                }
                dropped:=members[kept:]
                for at:=0;at<len(dropped); {
                    end:=at+1
                    class:=source.islands[dropped[at].island].class
                    for end<len(dropped) && source.islands[dropped[end].island].class==class {end+=1}
                    for s,k in dropped[at:end] {
                        ib.scale[s.island]=0
                        ib.rank[s.island]=(f32(k)+0.5)/f32(end-at)
                    }
                    at=end
                }
            }
            defer for s in group_states {ib.scale[s.island],ib.rank[s.island]=1,0}
            if stuck {
                // Stuck: the group is a root.
                bounds.error=max(f32)
                islands_output(&ib,group,group_states[:],bounds,depth) or_return
                continue
            }
            bounds.error=max(bounds.error,error)
            id:=islands_output(&ib,group,group_states[:],bounds,depth) or_return
            // What remains, by submesh, split in clusters of the next level.
            survivors:=members[:kept]
            for submesh in submeshes {
                clear(&given)
                for s in survivors {
                    if source.islands[s.island].submesh!=submesh {continue}
                    if _,failed:=append(&given,s);failed!=nil {return .Out_Of_Memory}
                }
                islands_clusterize(&ib,given[:],submesh,bounds,id,&next_clusters,&next_states) or_return
            }
        }
        clusters,next_clusters=next_clusters,clusters
        states,next_states=next_states,states
        depth+=1
    }
    return .None
}
