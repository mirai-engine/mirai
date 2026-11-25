package kai

import "base:runtime"
import "mirai:store"

// The graph of changes as dense arrays, derived from the changes and extended
// as new ones become visible: a change is indexed after its parents, so an
// index is a topological order. The generation of a change is one more than
// its parents' highest; a walk toward the roots stops below the generation it
// looks for.

Graph_Index :: struct {
    revisions:[dynamic]Revision,
    parent_ranges:[dynamic][2]u32, // first and count into parents
    parents:[dynamic]u32,
    generation:[dynamic]u32,
    change_id:[dynamic]Change_Id,
    trees:[dynamic]store.Hash,
    lookup:map[Revision]u32,
}

graph_init :: proc(g:^Graph_Index,allocator:=context.allocator) {
    g.revisions=make([dynamic]Revision,allocator)
    g.parent_ranges=make([dynamic][2]u32,allocator)
    g.parents=make([dynamic]u32,allocator)
    g.generation=make([dynamic]u32,allocator)
    g.change_id=make([dynamic]Change_Id,allocator)
    g.trees=make([dynamic]store.Hash,allocator)
    g.lookup=make(map[Revision]u32,allocator)
}

graph_destroy :: proc(g:^Graph_Index) {
    delete(g.revisions)
    delete(g.parent_ranges)
    delete(g.parents)
    delete(g.generation)
    delete(g.change_id)
    delete(g.trees)
    delete(g.lookup)
    g^={}
}

// Indexes the changes heads reach that it does not hold yet.
graph_extend :: proc(g:^Graph_Index,s:^store.Store,heads:[]Revision) -> Error {
    Pending :: struct {revision:Revision,expanded:bool}
    stack:=make([dynamic]Pending,context.temp_allocator)
    for h in heads {
        if h in g.lookup {continue}
        if _,e:=append(&stack,Pending{h,false});e!=nil {return .Out_Of_Memory}
    }
    for len(stack)>0 {
        top:=stack[len(stack)-1]
        if top.revision in g.lookup {
            pop(&stack)
            continue
        }
        c:=change_get(s,top.revision,context.temp_allocator) or_return
        if !top.expanded {
            stack[len(stack)-1].expanded=true
            missing:=false
            for p in c.parents {
                if p in g.lookup {continue}
                if _,e:=append(&stack,Pending{p,false});e!=nil {return .Out_Of_Memory}
                missing=true
            }
            if missing {continue}
        }
        pop(&stack)
        generation:u32=1
        first:=u32(len(g.parents))
        for p in c.parents {
            index,found:=g.lookup[p]
            if !found {return .Corrupt} // a cycle: a parent not indexed after its own walk
            generation=max(generation,g.generation[index]+1)
            if _,e:=append(&g.parents,index);e!=nil {return .Out_Of_Memory}
        }
        index:=u32(len(g.revisions))
        _,e1:=append(&g.revisions,top.revision)
        _,e2:=append(&g.parent_ranges,[2]u32{first,u32(len(c.parents))})
        _,e3:=append(&g.generation,generation)
        _,e4:=append(&g.change_id,c.id)
        _,e5:=append(&g.trees,c.tree)
        if e1!=nil || e2!=nil || e3!=nil || e4!=nil || e5!=nil {return .Out_Of_Memory}
        if _,e:=map_insert(&g.lookup,top.revision,index);e!=nil {return .Out_Of_Memory}
    }
    return .None
}

graph_parents :: proc(g:^Graph_Index,index:u32) -> []u32 {
    r:=g.parent_ranges[index]
    return g.parents[r[0]:][:r[1]]
}

// Whether a is b or one of its ancestors; both must be indexed.
graph_is_ancestor :: proc(g:^Graph_Index,a,b:Revision) -> bool {
    ia,fa:=g.lookup[a]
    ib,fb:=g.lookup[b]
    if !fa || !fb {return false}
    if ia==ib {return true}
    floor:=g.generation[ia]
    seen,e:=make([]bool,len(g.revisions),context.temp_allocator)
    if e!=nil {return false}
    stack:=make([dynamic]u32,context.temp_allocator)
    if _,e:=append(&stack,ib);e!=nil {return false}
    for len(stack)>0 {
        n:=pop(&stack)
        for p in graph_parents(g,n) {
            if p==ia {return true}
            if g.generation[p]<=floor || seen[p] {continue}
            seen[p]=true
            if _,e:=append(&stack,p);e!=nil {return false}
        }
    }
    return false
}

// The best common ancestors of a and b: those no other common ancestor
// descends from, found walking down by generation from both.
graph_merge_bases :: proc(g:^Graph_Index,a,b:Revision,out:^[dynamic]Revision) -> Error {
    clear(out)
    ia,fa:=g.lookup[a]
    ib,fb:=g.lookup[b]
    if !fa || !fb {return .Missing}
    if ia==ib {
        if _,e:=append(out,a);e!=nil {return .Out_Of_Memory}
        return .None
    }
    LEFT :: u8(1)
    RIGHT :: u8(2)
    STALE :: u8(4)
    flags,made:=make([]u8,len(g.revisions),context.temp_allocator)
    if made!=nil {return .Out_Of_Memory}
    heap:=make([dynamic]u32,context.temp_allocator)
    less :: proc(g:^Graph_Index,x,y:u32) -> bool {return g.generation[x]>g.generation[y] || (g.generation[x]==g.generation[y] && x>y)}
    push :: proc(g:^Graph_Index,heap:^[dynamic]u32,n:u32) -> runtime.Allocator_Error {
        append(heap,n) or_return
        k:=len(heap)-1
        for k>0 {
            parent:=(k-1)/2
            if !less(g,heap[k],heap[parent]) {break}
            heap[k],heap[parent]=heap[parent],heap[k]
            k=parent
        }
        return nil
    }
    take :: proc(g:^Graph_Index,heap:^[dynamic]u32) -> u32 {
        top:=heap[0]
        heap[0]=heap[len(heap)-1]
        pop(heap)
        k:=0
        for {
            l,r,best:=2*k+1,2*k+2,k
            if l<len(heap) && less(g,heap[l],heap[best]) {best=l}
            if r<len(heap) && less(g,heap[r],heap[best]) {best=r}
            if best==k {break}
            heap[k],heap[best]=heap[best],heap[k]
            k=best
        }
        return top
    }
    flags[ia]=LEFT
    flags[ib]=RIGHT
    if push(g,&heap,ia)!=nil || push(g,&heap,ib)!=nil {return .Out_Of_Memory}
    found:=make([dynamic]u32,context.temp_allocator)
    for len(heap)>0 {
        // Stop once every node left is stale.
        live:=false
        for n in heap {if flags[n]&STALE==0 {live=true;break}}
        if !live {break}
        n:=take(g,&heap)
        f:=flags[n]
        if f&(LEFT|RIGHT)==LEFT|RIGHT && f&STALE==0 {
            if !slice_has(found[:],n) {
                if _,e:=append(&found,n);e!=nil {return .Out_Of_Memory}
            }
            f|=STALE
        }
        for p in graph_parents(g,n) {
            old:=flags[p]
            if old|f==old {continue}
            flags[p]=old|f
            if push(g,&heap,p)!=nil {return .Out_Of_Memory}
        }
    }
    // A base another base descends from is not a best one.
    for n in found {
        redundant:=false
        for m in found {
            if m!=n && graph_is_ancestor(g,g.revisions[n],g.revisions[m]) {redundant=true;break}
        }
        if redundant {continue}
        if _,e:=append(out,g.revisions[n]);e!=nil {return .Out_Of_Memory}
    }
    return .None
}

@(private)
slice_has :: proc "contextless" (list:[]u32,value:u32) -> bool {
    for v in list {if v==value {return true}}
    return false
}
