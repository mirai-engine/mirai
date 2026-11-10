package mirai_physics

import "core:mem"
import "core:hash/xxhash"
import "mirai:std/base"
import "mirai:std/spatial"

// An array of the state: all its slots, the size of one, the slots in use and the pool it is of.
@(private) State_Array :: struct {bytes:[]byte,size:int,high:i32,pool:Pool}

// The arrays of the state, which world_state_copy copies and world_hash hashes up to their counts.
@(private)
state_arrays :: proc(w:^World) -> [12]State_Array {
    return {
        {mem.slice_to_bytes(w.bodies),size_of(Body),w.body_high,.Bodies},
        {mem.slice_to_bytes(w.shapes),size_of(Shape),w.shape_high,.Shapes},
        {mem.slice_to_bytes(w.contacts),size_of(Contact),w.contact_high,.Contacts},
        {mem.slice_to_bytes(w.joints),size_of(Joint),w.joint_high,.Joints},
        {mem.slice_to_bytes(w.blocks),size_of(Manifold_Block),w.block_high,.Blocks},
        {mem.slice_to_bytes(w.characters),size_of(Character),w.character_high,.Characters},
        {mem.slice_to_bytes(w.joint_axes),size_of(Joint_Axes),w.joint_high,.Joints},
        {mem.slice_to_bytes(w.islands),size_of(Island),w.island_high,.Islands},
        {mem.slice_to_bytes(w.fluids),size_of(Fluid),w.fluid_high,.Fluids},
        {mem.slice_to_bytes(w.breakables),size_of(Breakable),w.breakable_high,.Breakables},
        {mem.slice_to_bytes(w.pieces),size_of(Piece),w.piece_high,.Pieces},
        {mem.slice_to_bytes(w.bonds),size_of(Bond),w.bond_high,.Bonds},
    }
}

// Makes dst what src is: stepped alike, both repeat the same steps bit for bit. dst is a kept world
// (world_kept_init) or holds the geometry src names. Between two worlds of one timeline, a world kept for
// another that only takes its copies and gives them back, only the chunks written since they were last
// alike are copied; otherwise all of them. Fails, leaving dst unchanged, for a world never made, when the
// pools of dst do not hold what src uses, or when dst lacks the geometry a shape to copy names or has
// rebuilt its hull since. Returns the bytes of the pools and trees written.
world_state_copy :: proc(dst,src:^World) -> (written:int,ok:bool) {
    if dst==src {return 0,true}
    if dst.allocator.procedure==nil || src.allocator.procedure==nil {return}
    if src.breaking.made && !dst.kept && !breakables_make(dst) {return}
    if !world_state_fits(dst,src) {return}
    if src.fluid_count>0 && !dst.kept && !fluid_scratch_make(dst) {return}
    whole:=dst.lineage!=src.lineage
    into,from:=dst.stamps[.Shapes],src.stamps[.Shapes]
    shape_chunks:=base.chunks_of(int(max(src.shape_high,dst.shape_high)))
    for k in 0..<shape_chunks {
        if !whole && into[k]==base.chunk_stamp_at(from,k) {continue}
        for &shape in src.shapes[min(k*base.CHUNK,int(src.shape_high)):min((k+1)*base.CHUNK,int(src.shape_high))] {
            if shape.generation&1==0 {continue}
            // A kept world needs no geometry, only the revision of the hulls its shapes were made with.
            if dst.kept {
                if shape.type==.Hull {dst.hulls[shape.resource].revision=src.hulls[shape.resource].revision}
                continue
            }
            if !shape_geometry_known(dst,&shape) {return}
            if shape.type==.Hull && src.hulls[shape.resource].revision!=dst.hulls[shape.resource].revision {return}
        }
    }
    // What the geometry of dst is used by follows the shapes the copy replaces.
    for k in 0..<shape_chunks {
        if !whole && into[k]==base.chunk_stamp_at(from,k) {continue}
        for &shape in dst.shapes[min(k*base.CHUNK,int(dst.shape_high)):min((k+1)*base.CHUNK,int(dst.shape_high))] {
            if shape.generation&1!=0 {shape_refs_add(dst,&shape,-1)}
        }
        for &shape in src.shapes[min(k*base.CHUNK,int(src.shape_high)):min((k+1)*base.CHUNK,int(src.shape_high))] {
            if shape.generation&1!=0 {shape_refs_add(dst,&shape,1)}
        }
    }
    for &tree,i in dst.trees {
        nodes,_:=spatial.dynamic_tree_copy(&tree,&src.trees[i],whole)
        written+=nodes
    }
    copies:[Pool][3]base.Chunk_Copy
    counts,slots:[Pool]int
    to:=state_arrays(dst)
    for a,i in state_arrays(src) {
        copies[a.pool][counts[a.pool]]={to[i].bytes,a.bytes,a.size}
        counts[a.pool]+=1
        slots[a.pool]=max(slots[a.pool],int(a.high),int(to[i].high))
    }
    // The hull and the origin of a piece slot go with it, but a world put back keeps its own: they are
    // geometry, newer than those of its copy, that the pieces it repeats build over again.
    pieces:=dst.kept || whole
    if pieces {
        copies[.Pieces][1]={mem.slice_to_bytes(dst.piece_hulls),mem.slice_to_bytes(src.piece_hulls),size_of(Hull_Handle)}
        copies[.Pieces][2]={mem.slice_to_bytes(dst.piece_origins),mem.slice_to_bytes(src.piece_origins),size_of(Piece_Origin)}
        counts[.Pieces]=3
        slots[.Pieces]=max(slots[.Pieces],int(src.piece_hull_high),int(dst.piece_hull_high))
        if dst.breaking.made {dst.piece_hull_high=src.piece_hull_high}
    }
    for pool in Pool {written+=base.chunks_copy(copies[pool][:counts[pool]],dst.stamps[pool],src.stamps[pool],slots[pool],whole)}
    dst.state=src.state
    revision:=max(dst.revision,src.revision)+1
    dst.revision,src.revision=revision,revision
    // Its next copy takes them.
    if !pieces {
        for k in 0..<base.chunks_of(int(dst.piece_hull_high)) {stamp(dst,.Pieces,i32(k*base.CHUNK))}
    }
    if dst.kept {
        dst.lineage=src.lineage
    } else if whole {
        dst.lineage=lineage_new(dst)
        dst.source=src.kept?src.lineage:0
    }
    dst.events.counts={}
    if written>0 {static_log_restart(dst)}
    dst.step.woken_count,dst.step.awake_count,dst.step.active_count,dst.step.character_count=0,0,0,0
    return written,true
}

// next took the place of previous, as a world put back from a copy kept for previous takes it when they
// trade places: if next holds what that copy held and has not stepped since, it goes on with the
// timeline of previous, so the copies kept for it still take only what changed, and previous leaves it.
world_succeed :: proc(next,previous:^World) {
    if next.source==0 || next.source!=previous.lineage {return}
    revision:=max(next.revision,previous.revision)+1
    next.revision,previous.revision=revision,revision
    for &tree,i in next.trees {
        other:=&previous.trees[i]
        tree.revision=max(tree.revision,other.revision)+1
        other.revision=tree.revision
    }
    next.lineage,next.source=previous.lineage,0
    previous.lineage=lineage_new(previous)
}

// Whether the pools of dst hold the state of src.
world_state_fits :: proc(dst,src:^World) -> bool {
    to:=state_arrays(dst)
    for a,i in state_arrays(src) {
        if int(a.high)>len(to[i].bytes)/a.size {return false}
    }
    if int(src.piece_hull_high)>len(dst.piece_hulls) {return false}
    for &tree,i in src.trees {
        if int(tree.node_high)>len(dst.trees[i].nodes) {return false}
    }
    return true
}

// Makes w a world only kept, to copy src into it with world_state_copy and
// back out of it later: its pools hold what src uses, with room to grow, and
// its desc is that of src, which a world copied back from it is made with.
// It has no events nor log of static changes, and is never stepped.
world_kept_init :: proc(w,src:^World,allocator:mem.Allocator) -> bool {
    room :: proc(used:i32,capacity:int) -> int {return clamp(int(used)+int(used)/2+16,1,max(capacity,1))}
    d:=src.desc
    d.allocator=allocator
    nodes:=max(src.trees[STATIC_TREE].node_high,src.trees[DYNAMIC_TREE].node_high)
    d.body_capacity=room(max(src.body_high,src.island_high),d.body_capacity)
    d.shape_capacity=room(max(src.shape_high,(nodes+1)/2),d.shape_capacity)
    d.contact_capacity=room(max(src.contact_high,4*src.block_high),d.contact_capacity)
    d.joint_capacity=room(src.joint_high,d.joint_capacity)
    d.character_capacity=room(src.character_high,d.character_capacity)
    d.fluid_capacity=room(src.fluid_high,d.fluid_capacity)
    d.breakable_capacity=room(src.breakable_high,d.breakable_capacity)
    d.piece_capacity=room(max(src.piece_high,src.piece_hull_high),d.piece_capacity)
    d.bond_capacity=room(src.bond_high,d.bond_capacity)
    d.event_capacity,d.static_change_capacity=0,0
    if !world_init(w,d) {return false}
    w.kept=true
    if src.breaking.made && !breakables_make(w) {
        world_destroy(w)
        return false
    }
    w.desc=src.desc
    w.desc.allocator=allocator
    w.kept=true
    return true
}

// A shape that is not live, or whose geometry is registered in w.
@(private)
shape_geometry_known :: proc "contextless" (w:^World,shape:^Shape) -> bool {
    if shape.generation&1==0 {return true}
    #partial switch shape.type {
    case .Hull: return int(shape.resource)<len(w.hulls) && w.hulls[shape.resource].generation&1!=0
    case .Mesh: return int(shape.resource)<len(w.meshes) && w.meshes[shape.resource].generation&1!=0
    case .Heightfield: return int(shape.resource)<len(w.heightfields) && w.heightfields[shape.resource].generation&1!=0
    }
    return true
}

// Hash of the state. Two worlds that were built and stepped alike have equal hashes.
world_hash :: proc(w:^World) -> u64 {
    state:=w.state
    hash:=xxhash.XXH3_64_with_seed(mem.ptr_to_bytes(&state),0)
    for a in state_arrays(w) {
        if a.high==0 {continue}
        hash=xxhash.XXH3_64_with_seed(a.bytes[:int(a.high)*a.size],hash)
    }
    for &tree in w.trees {
        head:=[4]i32{tree.root,tree.free_list,tree.node_high,tree.proxy_count}
        hash=xxhash.XXH3_64_with_seed(mem.slice_to_bytes(head[:]),hash)
        if tree.node_high>0 {hash=xxhash.XXH3_64_with_seed(mem.slice_to_bytes(tree.nodes[:tree.node_high]),hash)}
    }
    return hash
}
