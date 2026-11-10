package mirai_physics

import "core:mem"
import "mirai:std/base"
import "mirai:std/spatial"

// Counters and list heads of the pools. Copied by snapshots with the arrays they describe.
World_State :: struct {
    tick:u64,
    time:f64, // seconds stepped: the time of the waves
    gravity:Vec3,
    body_high,body_free,body_count:i32,
    shape_high,shape_free,shape_count:i32,
    contact_high,contact_free,contact_count:i32,
    joint_high,joint_free,joint_count:i32,
    block_high,block_free:i32,
    character_high,character_free,character_count:i32,
    island_high,island_free,island_count:i32,
    fluid_high,fluid_free,fluid_count:i32,
    breakable_high,breakable_free,breakable_count:i32,
    piece_high,piece_free,piece_count:i32,
    bond_high,bond_free,bond_count:i32,
    push_rule_count:i32,
    hit_shapes:i32,    // live shapes that raise hits
    grounds_stale:b32, // a body or shape changed since the characters last found their ground
    twin_count:i32,
    push_rules:[PUSH_RULE_CAPACITY]Push_Rule,
    cut_count:i32,
    twins:[TWIN_CAPACITY]Twin,
    cuts:[CUT_CAPACITY]Cut,
    awake_head,moved_head:i32, // the lists of the awake bodies and of the moved shapes
}
#assert(size_of(World_State)==2680)

@(private) Hull_Slot :: struct {hull:Hull,generation:u32,refs:i32,revision:u32} // revision: rebuilds under its handle
@(private) Mesh_Slot :: struct {mesh:Mesh,generation:u32,refs:i32}
@(private) Heightfield_Slot :: struct {field:Heightfield,generation:u32,refs:i32}

@(private) STATIC_TREE :: 0
@(private) DYNAMIC_TREE :: 1

World :: struct {
    desc:World_Desc,
    allocator:mem.Allocator,
    // State copied by snapshots.
    using state:World_State,
    bodies:[]Body,
    shapes:[]Shape,
    contacts:[]Contact,
    joints:[]Joint,
    joint_axes:[]Joint_Axes,
    islands:[]Island,
    blocks:[]Manifold_Block,
    characters:[]Character,
    fluids:[]Fluid,
    breakables:[]Breakable, // nil, with their pieces and bonds, until the first one is made
    pieces:[]Piece,
    bonds:[]Bond,
    trees:[2]spatial.Dynamic_Tree,
    // Geometry shared by shapes; immutable and outside snapshots.
    hulls:[]Hull_Slot,
    meshes:[]Mesh_Slot,
    heightfields:[]Heightfield_Slot,
    piece_hulls:[]Hull_Handle,    // hull each piece slot owns; it outlives its piece until the slot is used again
    piece_origins:[]Piece_Origin, // where the piece of each slot came from; rewritten with its hull
    piece_hull_high:i32,          // one past the last piece slot that was given a hull
    // Scratch of the step, rebuilt from the state.
    manifolds:[]Manifold,
    extra_manifolds:[][EXTRA_MANIFOLDS]Manifold,
    step:Step,
    breaking:Break_Scratch,
    events:Event_Buffers,
    static_log:Static_Log,
    stats:Stats,
    profile:Profile,
    kept:bool, // made by world_kept_init: its pools are smaller than desc says
}

@(private)
Event_Buffers :: struct {
    contact_begin:[]Contact_Begin_Event,
    contact_end:[]Contact_End_Event,
    overlap_begin,overlap_end:[]Overlap_Event,
    joint_break:[]Joint_Break_Event,
    sleep,wake:[]Body_Event,
    hit:[]Contact_Hit_Event,
    breaks:[]Break_Event,
    counts:[9]int,
}

world_init :: proc(w:^World,desc:World_Desc) -> bool {
    w^={}
    d:=desc
    if d.allocator.procedure==nil {d.allocator=context.allocator}
    if d.body_capacity<=0 || d.shape_capacity<=0 || d.contact_capacity<=0 || d.joint_capacity<0 {return false}
    if d.body_capacity>=1<<30 || d.shape_capacity>=1<<30 || d.contact_capacity>=1<<30 {return false}
    d.substeps=clamp(d.substeps,1,64)
    d.worker_count=clamp(d.worker_count,1,MAX_WORKERS)
    if d.parallel_for==nil {d.worker_count=1}
    if d.contact_hertz<=0 {d.contact_hertz=30}
    if d.contact_damping_ratio<=0 {d.contact_damping_ratio=10}
    if d.contact_speed<=0 {d.contact_speed=3}
    if d.joint_hertz<=0 {d.joint_hertz=60}
    if d.joint_damping_ratio<=0 {d.joint_damping_ratio=2}
    if d.restitution_threshold<=0 {d.restitution_threshold=1}
    if d.max_linear_speed<=0 {d.max_linear_speed=400}
    d.event_capacity=max(d.event_capacity,0)
    d.character_capacity=max(d.character_capacity,0)
    d.fluid_capacity=max(d.fluid_capacity,0)
    d.static_change_capacity=max(d.static_change_capacity,0)
    d.breakable_capacity,d.piece_capacity,d.bond_capacity=max(d.breakable_capacity,0),max(d.piece_capacity,0),max(d.bond_capacity,0)
    if !(d.hit_speed>=0) {d.hit_speed=0.5}
    w.desc=d
    w.allocator=d.allocator
    w.gravity=d.gravity
    w.body_free,w.shape_free,w.contact_free,w.joint_free,w.block_free,w.character_free=-1,-1,-1,-1,-1,-1
    w.island_free,w.fluid_free,w.awake_head,w.moved_head=-1,-1,-1,-1
    w.breakable_free,w.piece_free,w.bond_free=-1,-1,-1
    a:=d.allocator
    ok:=true
    alloc :: proc($T:typeid,count:int,a:mem.Allocator,ok:^bool) -> []T {
        if count<=0 {return nil}
        slice,error:=make([]T,count,a)
        if error!=nil {ok^=false}
        return slice
    }
    w.bodies=alloc(Body,d.body_capacity,a,&ok)
    w.shapes=alloc(Shape,d.shape_capacity,a,&ok)
    w.contacts=alloc(Contact,d.contact_capacity,a,&ok)
    w.joints=alloc(Joint,d.joint_capacity,a,&ok)
    w.joint_axes=alloc(Joint_Axes,d.joint_capacity,a,&ok)
    w.islands=alloc(Island,d.body_capacity,a,&ok)
    w.blocks=alloc(Manifold_Block,d.contact_capacity/4,a,&ok)
    w.characters=alloc(Character,d.character_capacity,a,&ok)
    w.fluids=alloc(Fluid,d.fluid_capacity,a,&ok)
    w.events.hit=alloc(Contact_Hit_Event,d.event_capacity,a,&ok)
    w.hulls=alloc(Hull_Slot,d.hull_capacity,a,&ok)
    w.meshes=alloc(Mesh_Slot,d.mesh_capacity,a,&ok)
    w.heightfields=alloc(Heightfield_Slot,d.heightfield_capacity,a,&ok)
    w.manifolds=alloc(Manifold,d.contact_capacity,a,&ok)
    w.extra_manifolds=alloc([EXTRA_MANIFOLDS]Manifold,d.contact_capacity/4,a,&ok)
    w.events.contact_begin=alloc(Contact_Begin_Event,d.event_capacity,a,&ok)
    w.events.contact_end=alloc(Contact_End_Event,d.event_capacity,a,&ok)
    w.events.overlap_begin=alloc(Overlap_Event,d.event_capacity,a,&ok)
    w.events.overlap_end=alloc(Overlap_Event,d.event_capacity,a,&ok)
    w.events.joint_break=alloc(Joint_Break_Event,d.event_capacity,a,&ok)
    w.events.sleep=alloc(Body_Event,d.event_capacity,a,&ok)
    w.events.wake=alloc(Body_Event,d.event_capacity,a,&ok)
    w.static_log.boxes=alloc(Aabb,d.static_change_capacity,a,&ok)
    for &tree in w.trees {
        ok&&=spatial.dynamic_tree_init(&tree,{proxy_capacity=d.shape_capacity,margin=AABB_MARGIN,allocator=a})
    }
    ok&&=step_init(&w.step,d,a)
    if !ok {world_destroy(w);return false}
    return true
}

world_destroy :: proc(w:^World) {
    a:=w.allocator
    if a.procedure==nil {return}
    for &slot in w.hulls {
        if slot.generation&1!=0 {hull_free(&slot.hull,a)}
    }
    for &slot in w.meshes {
        if slot.generation&1!=0 {mesh_free(&slot.mesh,a)}
    }
    for &slot in w.heightfields {
        if slot.generation&1!=0 {heightfield_free(&slot.field,a)}
    }
    delete(w.bodies,a);delete(w.shapes,a);delete(w.contacts,a);delete(w.joints,a);delete(w.blocks,a)
    delete(w.joint_axes,a);delete(w.islands,a)
    delete(w.hulls,a);delete(w.meshes,a);delete(w.heightfields,a);delete(w.characters,a);delete(w.fluids,a)
    delete(w.events.hit,a)
    delete(w.manifolds,a);delete(w.extra_manifolds,a)
    delete(w.events.contact_begin,a);delete(w.events.contact_end,a)
    delete(w.events.overlap_begin,a);delete(w.events.overlap_end,a)
    delete(w.events.joint_break,a);delete(w.events.sleep,a);delete(w.events.wake,a)
    delete(w.static_log.boxes,a)
    breakables_free(w)
    for &tree in w.trees {spatial.dynamic_tree_destroy(&tree)}
    step_destroy(&w.step,a)
    w^={}
}

world_gravity :: proc(w:^World) -> Vec3 {return w.gravity}
world_set_gravity :: proc(w:^World,gravity:Vec3) {w.gravity=gravity}

// Replaces the push rules of the world. False, changing nothing, for more than PUSH_RULE_CAPACITY rules,
// a rule without layers on a side or a force that is not positive and finite.
world_set_push_rules :: proc(w:^World,rules:[]Push_Rule) -> bool {
    if len(rules)>PUSH_RULE_CAPACITY {return false}
    for rule in rules {
        if rule.a==0 || rule.b==0 || !(rule.force>0 && rule.force<=max(f32)) {return false}
    }
    w.push_rules={}
    copy(w.push_rules[:],rules)
    w.push_rule_count=i32(len(rules))
    return true
}
world_push_rules :: proc(w:^World) -> []Push_Rule {return w.push_rules[:w.push_rule_count]}

// The force a contact between two dynamic shapes of these layers pushes with at most: the smallest of the
// rules that pair them, zero when none does.
@(private)
push_force_of :: proc "contextless" (w:^World,a,b:Collision_Layers) -> (force:f32) #no_bounds_check {
    for rule in w.push_rules[:w.push_rule_count] {
        if a&rule.a!=0 && b&rule.b!=0 || a&rule.b!=0 && b&rule.a!=0 {force=force>0?min(force,rule.force):rule.force}
    }
    return
}
world_tick :: proc(w:^World) -> u64 {return w.tick}
world_profile :: proc(w:^World) -> Profile {return w.profile}

world_stats :: proc(w:^World) -> Stats {
    s:=w.stats
    s.bodies,s.shapes,s.contacts,s.joints=int(w.body_count),int(w.shape_count),int(w.contact_count),int(w.joint_count)
    s.characters,s.fluids=int(w.character_count),int(w.fluid_count)
    s.breakables,s.pieces=int(w.breakable_count),int(w.piece_count)
    return s
}

world_events :: proc(w:^World) -> Events {
    e:=&w.events
    return {
        e.contact_begin[:e.counts[0]],e.contact_end[:e.counts[1]],e.overlap_begin[:e.counts[2]],e.overlap_end[:e.counts[3]],
        e.joint_break[:e.counts[4]],e.sleep[:e.counts[5]],e.wake[:e.counts[6]],e.hit[:e.counts[7]],
        e.breaks[:e.counts[8]],
    }
}

// The slots of the bodies the last step integrated and of those it woke: every body whose pose, velocity or
// sleep it changed, some of them twice. The slices belong to the world and last until the next step or restore.
world_stepped :: proc(w:^World) -> (integrated,woken:[]i32) {
    st:=&w.step
    return st.awake[:st.awake_count],st.woken[:st.woken_count]
}

// The body in a slot world_stepped gave, and its user data; zero for a slot that is free.
body_at :: proc(w:^World,index:i32) -> (handle:Body_Handle,user_data:u64) {
    if index<0 || index>=w.body_high || w.bodies[index].generation&1==0 {return}
    return body_handle(w,index),w.bodies[index].user_data
}

@(private)
event_push :: proc(w:^World,buffer:[]$T,kind:int,event:T) {
    count:=w.events.counts[kind]
    if count>=len(buffer) {w.stats.event_capacity_exhausted+=1;return}
    buffer[count]=event
    w.events.counts[kind]=count+1
}

@(private) body_handle :: #force_inline proc "contextless" (w:^World,index:i32) -> Body_Handle {
    return Body_Handle(base.handle_make(u32(index),w.bodies[index].generation))
}
@(private) shape_handle :: #force_inline proc "contextless" (w:^World,index:i32) -> Shape_Handle {
    return Shape_Handle(base.handle_make(u32(index),w.shapes[index].generation))
}
@(private) joint_handle :: #force_inline proc "contextless" (w:^World,index:i32) -> Joint_Handle {
    return Joint_Handle(base.handle_make(u32(index),w.joints[index].generation))
}

// Slot of a live handle, or nil.
@(private)
body_get :: #force_inline proc "contextless" (w:^World,h:Body_Handle) -> (^Body,i32) {
    index:=base.handle_index(base.Handle(h))
    generation:=base.handle_generation(base.Handle(h))
    if index>=u32(w.body_high) || generation&1==0 || w.bodies[index].generation!=generation {return nil,-1}
    return &w.bodies[index],i32(index)
}
@(private)
shape_get :: #force_inline proc "contextless" (w:^World,h:Shape_Handle) -> (^Shape,i32) {
    index:=base.handle_index(base.Handle(h))
    generation:=base.handle_generation(base.Handle(h))
    if index>=u32(w.shape_high) || generation&1==0 || w.shapes[index].generation!=generation {return nil,-1}
    return &w.shapes[index],i32(index)
}
@(private)
joint_get :: #force_inline proc "contextless" (w:^World,h:Joint_Handle) -> (^Joint,i32) {
    index:=base.handle_index(base.Handle(h))
    generation:=base.handle_generation(base.Handle(h))
    if index>=u32(w.joint_high) || generation&1==0 || w.joints[index].generation!=generation {return nil,-1}
    return &w.joints[index],i32(index)
}

body_valid :: proc(w:^World,h:Body_Handle) -> bool {
    body,_:=body_get(w,h)
    return body!=nil
}
shape_valid :: proc(w:^World,h:Shape_Handle) -> bool {
    shape,_:=shape_get(w,h)
    return shape!=nil
}
joint_valid :: proc(w:^World,h:Joint_Handle) -> bool {
    joint,_:=joint_get(w,h)
    return joint!=nil
}

// Runs a stage over [0,count) through the job interface of the world, or inline when it is small.
@(private)
world_parallel :: proc(w:^World,count,grain:int,data:rawptr,body:proc(data:rawptr,first,last,worker:int)) {
    if count<=0 {return}
    if w.desc.parallel_for==nil || w.desc.worker_count<=1 || count<=grain {
        body(data,0,count,0)
        return
    }
    context.user_ptr=w.desc.parallel_user
    w.desc.parallel_for(count,grain,data,body)
}
