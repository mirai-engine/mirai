package mirai_physics

import "core:mem"
import "core:hash/xxhash"
import "mirai:std/spatial"

@(private) SNAPSHOT_MAGIC :: u32(0x5048594d)
@(private) SNAPSHOT_VERSION :: u32(14)
@(private) SNAPSHOT_BLOCKS :: 12

@(private)
Snapshot_Header :: struct {
    magic,version:u32,
    size:u64,
    payload:u64, // hash of the header, with this field zero, and the bytes after it
    element_sizes:[SNAPSHOT_BLOCKS]u32,
    state:World_State,
}

@(private) SNAPSHOT_ELEMENT_SIZES :: [SNAPSHOT_BLOCKS]u32{
    size_of(Body),size_of(Shape),size_of(Contact),size_of(Joint),size_of(Manifold_Block),size_of(Character),
    size_of(Joint_Axes),size_of(Island),size_of(Fluid),size_of(Breakable),size_of(Piece),size_of(Bond),
}

// The arrays a snapshot holds, each up to the count that `s` gives it.
@(private)
snapshot_blocks :: proc(w:^World,s:^World_State) -> [SNAPSHOT_BLOCKS][]byte {
    return {
        mem.slice_to_bytes(w.bodies[:s.body_high]),mem.slice_to_bytes(w.shapes[:s.shape_high]),
        mem.slice_to_bytes(w.contacts[:s.contact_high]),mem.slice_to_bytes(w.joints[:s.joint_high]),
        mem.slice_to_bytes(w.blocks[:s.block_high]),mem.slice_to_bytes(w.characters[:s.character_high]),
        mem.slice_to_bytes(w.joint_axes[:s.joint_high]),mem.slice_to_bytes(w.islands[:s.island_high]),
        mem.slice_to_bytes(w.fluids[:s.fluid_high]),mem.slice_to_bytes(w.breakables[:s.breakable_high]),
        mem.slice_to_bytes(w.pieces[:s.piece_high]),mem.slice_to_bytes(w.bonds[:s.bond_high]),
    }
}

@(private)
snapshot_counts_fit :: proc(w:^World,s:^World_State) -> bool {
    fits :: proc(count:i32,capacity:int) -> bool {return count>=0 && int(count)<=capacity}
    return fits(s.body_high,len(w.bodies)) && fits(s.shape_high,len(w.shapes)) && fits(s.contact_high,len(w.contacts)) &&
        fits(s.joint_high,len(w.joints)) && fits(s.joint_high,len(w.joint_axes)) && fits(s.block_high,len(w.blocks)) && fits(s.character_high,len(w.characters)) &&
        fits(s.island_high,len(w.islands)) && fits(s.fluid_high,len(w.fluids)) &&
        fits(s.breakable_high,len(w.breakables)) && fits(s.piece_high,len(w.pieces)) && fits(s.bond_high,len(w.bonds))
}

// Bytes that world_snapshot writes for the current state.
world_snapshot_size :: proc(w:^World) -> int {
    size:=size_of(Snapshot_Header)
    for block in snapshot_blocks(w,&w.state) {size+=len(block)}
    for &tree in w.trees {size+=spatial.dynamic_tree_snapshot_size(&tree)}
    return size+len(w.hulls)*size_of(u32)
}

// Bytes that a snapshot of this world can ever need: the size of a buffer that always fits.
world_snapshot_capacity :: proc(w:^World) -> int {
    size:=size_of(Snapshot_Header)
    size+=len(w.bodies)*size_of(Body)+len(w.shapes)*size_of(Shape)+len(w.contacts)*size_of(Contact)
    size+=len(w.joints)*size_of(Joint)+len(w.blocks)*size_of(Manifold_Block)+len(w.characters)*size_of(Character)
    size+=len(w.joint_axes)*size_of(Joint_Axes)+len(w.islands)*size_of(Island)+len(w.fluids)*size_of(Fluid)
    // The pools of the breakables may not be made yet.
    size+=w.desc.breakable_capacity*size_of(Breakable)+w.desc.piece_capacity*size_of(Piece)+w.desc.bond_capacity*size_of(Bond)
    for &tree in w.trees {size+=size_of(spatial.Tree_Node)*len(tree.nodes)+64}
    return size+len(w.hulls)*size_of(u32)
}

// Copies the simulation state into `buffer` by blocks. The geometry registered with hull_create and
// similar is not part of it: only the revision of each hull, which a restore must find again. Returns the
// bytes written, or false if the buffer is too small.
world_snapshot :: proc(w:^World,buffer:[]byte) -> (written:int,ok:bool) {
    size:=world_snapshot_size(w)
    if len(buffer)<size {return 0,false}
    cursor:=size_of(Snapshot_Header)
    for block in snapshot_blocks(w,&w.state) {
        mem.copy_non_overlapping(raw_data(buffer[cursor:]),raw_data(block),len(block))
        cursor+=len(block)
    }
    for &tree in w.trees {
        count:=spatial.dynamic_tree_snapshot(&tree,buffer[cursor:]) or_return
        cursor+=count
    }
    for &slot in w.hulls {
        mem.copy_non_overlapping(raw_data(buffer[cursor:]),&slot.revision,size_of(u32))
        cursor+=size_of(u32)
    }
    header:=Snapshot_Header{
        magic=SNAPSHOT_MAGIC,version=SNAPSHOT_VERSION,size=u64(size),element_sizes=SNAPSHOT_ELEMENT_SIZES,state=w.state,
    }
    header.payload=snapshot_payload_hash(header,buffer[size_of(Snapshot_Header):size])
    mem.copy_non_overlapping(raw_data(buffer),&header,size_of(Snapshot_Header))
    return cursor,true
}

// Returns the world to a state written by world_snapshot on a world of the same capacities. Stepping
// from it repeats the original steps exactly. Events and the manifolds of the last step are cleared.
// Fails, leaving the world unchanged, for a buffer that is not a whole snapshot of a world like this one:
// cut short or changed (its bytes hash to another value), of other capacities or layout, naming hulls,
// meshes or heightfields this world does not have, or naming a hull that this world has since rebuilt.
world_restore :: proc(w:^World,buffer:[]byte) -> bool {
    if len(buffer)<size_of(Snapshot_Header) {return false}
    header:Snapshot_Header
    mem.copy_non_overlapping(&header,raw_data(buffer),size_of(Snapshot_Header))
    if header.magic!=SNAPSHOT_MAGIC || header.version!=SNAPSHOT_VERSION || header.size<size_of(Snapshot_Header) || u64(len(buffer))<header.size {return false}
    if snapshot_payload_hash(header,buffer[size_of(Snapshot_Header):header.size])!=header.payload {return false}
    if header.element_sizes!=SNAPSHOT_ELEMENT_SIZES {return false}
    if header.state.breakable_high>0 && !breakables_make(w) {return false}
    if !snapshot_counts_fit(w,&header.state) {return false}
    restored:=snapshot_blocks(w,&header.state)
    cursor:=size_of(Snapshot_Header)
    for block in restored {cursor+=len(block)}
    if cursor>int(header.size) {return false}
    trees:=cursor
    for &tree in w.trees {
        count:=spatial.dynamic_tree_snapshot_check(&tree,buffer[cursor:header.size]) or_return
        cursor+=count
    }
    revisions:=cursor
    cursor+=len(w.hulls)*size_of(u32)
    if cursor!=int(header.size) || !snapshot_geometry_known(w,buffer,revisions,&header.state) {return false}
    if header.state.fluid_count>0 && !fluid_scratch_make(w) {return false}
    cursor=trees
    for &tree in w.trees {
        count,_:=spatial.dynamic_tree_restore(&tree,buffer[cursor:])
        cursor+=count
    }
    // Slots used after the snapshot was taken go back to never used: generations restart as in the original run.
    current:=snapshot_blocks(w,&w.state)
    cursor=size_of(Snapshot_Header)
    for block,i in restored {
        if len(current[i])>len(block) {mem.zero_slice(current[i][len(block):])}
        if len(block)>0 {mem.copy_non_overlapping(raw_data(block),raw_data(buffer[cursor:]),len(block))}
        cursor+=len(block)
    }
    w.state=header.state
    world_restored(w)
    return true
}

// Makes dst, a world of the same capacities that holds the geometry src
// names, what world_restore makes of a snapshot of src, without the bytes in
// between. Fails, leaving dst unchanged, as world_restore does.
world_state_copy :: proc(dst,src:^World) -> bool {
    if dst==src {return true}
    if src.breaking.made && !dst.kept && !breakables_make(dst) {return false}
    if !world_state_fits(dst,src) {return false}
    if src.fluid_count>0 && !dst.kept && !fluid_scratch_make(dst) {return false}
    for &shape in src.shapes[:src.shape_high] {
        if !shape_geometry_known(dst,&shape) {return false}
        if shape.generation&1!=0 && shape.type==.Hull && src.hulls[shape.resource].revision!=dst.hulls[shape.resource].revision {return false}
    }
    for &tree,i in src.trees {
        to:=&dst.trees[i]
        copy(to.nodes[:tree.node_high],tree.nodes[:tree.node_high])
        to.root,to.free_list,to.node_high,to.proxy_count=tree.root,tree.free_list,tree.node_high,tree.proxy_count
    }
    current:=snapshot_blocks(dst,&dst.state)
    restored:=snapshot_blocks(dst,&src.state)
    for block,i in snapshot_blocks(src,&src.state) {
        if len(current[i])>len(block) {mem.zero_slice(current[i][len(block):])}
        copy(restored[i],block)
    }
    if dst.breaking.made {breakables_geometry_copy(dst,src)}
    dst.state=src.state
    world_restored(dst)
    return true
}

// Whether the pools of dst hold the state of src.
world_state_fits :: proc(dst,src:^World) -> bool {
    if !snapshot_counts_fit(dst,&src.state) || int(src.piece_hull_high)>len(dst.piece_hulls) {return false}
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

// What a world whose state was put back recounts: the shapes of its geometry, and nothing of the last step.
@(private)
world_restored :: proc(w:^World) {
    for &slot in w.hulls {slot.refs=0}
    for &slot in w.meshes {slot.refs=0}
    for &slot in w.heightfields {slot.refs=0}
    for &shape in w.shapes[:w.shape_high] {
        if shape.generation&1!=0 {shape_refs_add(w,&shape,1)}
    }
    w.events.counts={}
    static_log_restart(w)
    w.step.woken_count=0
    w.step.awake_count=0
    w.step.active_count=0
    w.step.character_count=0
}

@(private)
snapshot_payload_hash :: proc(header:Snapshot_Header,body:[]byte) -> u64 {
    h:=header
    h.payload=0
    return xxhash.XXH3_64_with_seed(body,xxhash.XXH3_64_default(mem.ptr_to_bytes(&h)))
}

// Every live shape of the snapshot names geometry registered in this world, its hull as it was then.
@(private)
snapshot_geometry_known :: proc(w:^World,buffer:[]byte,revisions:int,s:^World_State) -> bool #no_bounds_check {
    blocks:=snapshot_blocks(w,s)
    offsets:[SNAPSHOT_BLOCKS]int
    cursor:=size_of(Snapshot_Header)
    for block,i in blocks {
        offsets[i]=cursor
        cursor+=len(block)
    }
    for i in 0..<int(s.shape_high) {
        shape:Shape
        mem.copy_non_overlapping(&shape,raw_data(buffer[offsets[1]+i*size_of(Shape):]),size_of(Shape))
        if !shape_geometry_known(w,&shape) {return false}
        if shape.generation&1==0 || shape.type!=.Hull {continue}
        revision:u32
        mem.copy_non_overlapping(&revision,raw_data(buffer[revisions+int(shape.resource)*size_of(u32):]),size_of(u32))
        if revision!=w.hulls[shape.resource].revision {return false}
    }
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

// Hash of everything a snapshot holds. Two worlds that were built and stepped alike have equal hashes.
world_hash :: proc(w:^World) -> u64 {
    state:=w.state
    hash:=xxhash.XXH3_64_with_seed(mem.ptr_to_bytes(&state),0)
    for block in snapshot_blocks(w,&w.state) {
        if len(block)==0 {continue}
        hash=xxhash.XXH3_64_with_seed(block,hash)
    }
    for &tree in w.trees {
        head:=[4]i32{tree.root,tree.free_list,tree.node_high,tree.proxy_count}
        hash=xxhash.XXH3_64_with_seed(mem.slice_to_bytes(head[:]),hash)
        if tree.node_high>0 {hash=xxhash.XXH3_64_with_seed(mem.slice_to_bytes(tree.nodes[:tree.node_high]),hash)}
    }
    return hash
}
