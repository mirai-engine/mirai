package physics

import "base:runtime"
import "core:mem"
import "core:testing"
import "mirai:core"
import "mirai:host"
import sim "plugins:physics/runtime/sim"

Physics_Copy_Failure :: struct {owner:runtime.Allocator,remaining:int,requests:u64}
@(private)
physics_copy_allocator :: proc(data:rawptr,mode:runtime.Allocator_Mode,size,alignment:int,old_memory:rawptr,old_size:int,loc:=#caller_location) -> ([]byte,runtime.Allocator_Error) {
    state:=(^Physics_Copy_Failure)(data)
    if mode==.Alloc || mode==.Alloc_Non_Zeroed || mode==.Resize || mode==.Resize_Non_Zeroed {
        state.requests+=1
        if state.remaining==0 {return nil,.Out_Of_Memory};state.remaining-=1
    }
    return state.owner.procedure(state.owner.data,mode,size,alignment,old_memory,old_size,loc)
}

@(private)
physics_copy_fixture :: proc(state:^Physics_State,offset:f32=0) -> bool {
    desc:=sim.world_desc_default()
    desc.body_capacity,desc.shape_capacity,desc.contact_capacity,desc.joint_capacity=2,4,4,0
    desc.hull_capacity,desc.mesh_capacity,desc.heightfield_capacity,desc.character_capacity=1,1,1,0
    desc.event_capacity=0
    if !sim.world_init(&state.world,desc) {return false};state.ready=true
    vertices:=[4][3]f32{{0,0,0},{1,0,0},{0,1,0},{0,0,1}}
    for &vertex in vertices {vertex.x+=offset}
    counts:=[4]u8{3,3,3,3};faces:=[12]u8{0,2,1,0,1,3,0,3,2,1,2,3}
    hull,hull_ok:=sim.hull_create(&state.world,{vertices[:],counts[:],faces[:]});if !hull_ok {return false}
    mesh,mesh_ok:=sim.mesh_create(&state.world,{vertices=vertices[:3],indices={0,2,1},disabled_edges={1}});if !mesh_ok {return false}
    heights:=[4]f32{offset,offset,offset,offset}
    field,field_ok:=sim.heightfield_create(&state.world,{heights=heights[:],columns=2,rows=2,cell={1,1,1},disabled_borders={0,1,0,1}});if !field_ok {return false}
    body:=sim.body_create(&state.world,sim.BODY_DESC_DEFAULT)
    shape:=sim.SHAPE_DESC_DEFAULT;shape.geometry=hull;sim.shape_create(&state.world,body,shape)
    shape.geometry=mesh;sim.shape_create(&state.world,body,shape)
    shape.geometry=field;sim.shape_create(&state.world,body,shape)
    _,linked:=core.entity_map_put(&state.links,core.entity_make(1,1),Link{body=body,kind=.Body})
    return linked
}

@(test)
physics_copies_report_every_allocation_failure_keep_the_source_intact_and_retry_destructible_destinations :: proc(t:^testing.T) {
    source:Physics_State;if !testing.expect(t,physics_copy_fixture(&source)) {return};defer state_destroy(&source)
    hash:=sim.world_hash(&source.world)
    original:=context;defer context=original
    failure:=Physics_Copy_Failure{owner=context.allocator}
    allocator:=runtime.Allocator{physics_copy_allocator,&failure}
    failures:=0;completed:=false
    for budget in 0..<256 {
        destination:Physics_State
        failure.remaining=budget;context.allocator=allocator
        copied:=state_copy(&destination,&source)
        if copied {
            testing.expect_value(t,sim.world_hash(&destination.world),hash)
            completed=true;state_destroy(&destination);break
        }
        failures+=1
        testing.expect_value(t,sim.world_hash(&source.world),hash)
        failure.remaining=1000
        testing.expect(t,state_copy(&destination,&source))
        testing.expect_value(t,sim.world_hash(&destination.world),hash)
        state_destroy(&destination)
    }
    testing.expect(t,completed && failures>8)
    for budget in 0..<16 {
        destination:Physics_State
        failure.remaining=1000;context.allocator=allocator
        if !testing.expect(t,physics_copy_fixture(&destination,2)) {state_destroy(&destination);return}
        failure.remaining=budget
        copied:=state_copy(&destination,&source)
        testing.expect_value(t,sim.world_hash(&source.world),hash)
        if !copied {failure.remaining=1000;testing.expect(t,state_copy(&destination,&source))}
        testing.expect_value(t,sim.world_hash(&destination.world),hash)
        state_destroy(&destination)
    }
}

@(test)
warm_physics_copies_and_swaps_allocate_nothing_keep_custom_modes_and_invalidate_both_host_identities :: proc(t:^testing.T) {
    source,destination:Physics_State
    if !testing.expect(t,physics_copy_fixture(&source)) {return};defer state_destroy(&source);defer state_destroy(&destination)
    original:=context;defer context=original
    failure:=Physics_Copy_Failure{owner=context.allocator,remaining=1000}
    allocator:=runtime.Allocator{physics_copy_allocator,&failure};context.allocator=allocator
    if !testing.expect(t,state_copy(&destination,&source)) {return}
    failure.remaining=0;before:=failure.requests
    context.temp_allocator=runtime.nil_allocator()
    for _ in 0..<16 {testing.expect(t,state_copy(&destination,&source))}
    testing.expect_value(t,failure.requests,before)
    testing.expect(t,raw_data(destination.world.meshes[0].mesh.vertices)!=raw_data(source.world.meshes[0].mesh.vertices))
    source.epoch=1000
    hash:=sim.world_hash(&source.world)
    state_swap(&source,&destination)
    testing.expect(t,source.epoch==1001 && destination.epoch==1001 && sim.world_hash(&source.world)==hash)
    testing.expect_value(t,failure.requests,before)
    source.epoch=max(u32);state_swap(&source,&destination)
    testing.expect(t,source.epoch==1 && destination.epoch==1)
    state_swap(&source,&source);testing.expect_value(t,source.epoch,u32(1))
}

@(test)
physics_world_creation_reports_allocation_failure_and_retries_including_reach_buffers :: proc(t:^testing.T) {
    original:=context;defer context=original
    failure:=Physics_Copy_Failure{owner=context.allocator};context.allocator={physics_copy_allocator,&failure}
    context.temp_allocator=runtime.nil_allocator()
    settings:=Physics_Settings{bodies=2,shapes=4,contacts=4,joints=1,characters=1,hulls=1,meshes=1,heightfields=1}
    app:host.App
    failures:=0;completed:=false
    for budget in 0..<256 {
        state:Physics_State
        problems:core.Problems
        failure.remaining=budget
        if state_make(&state,&settings,&app,&problems) {completed=true;state_destroy(&state);break}
        failures+=1
        testing.expect(t,!state.ready && problems.count==1 && problems.entries[0].entity==core.NONE)
        failure.remaining=1000
        testing.expect(t,state_make(&state,&settings,&app,&problems))
        state_destroy(&state)
    }
    testing.expect(t,completed && failures>3)
}

@(private)
physics_kept_drop :: proc(w:^sim.World,count:int) {
    for i in 0..<count {
        body:=sim.BODY_DESC_DEFAULT;body.position={f32(i%8)*1.5,2+f32(i/8)*1.5,0}
        handle:=sim.body_create(w,body)
        shape:=sim.SHAPE_DESC_DEFAULT;shape.geometry=sim.Sphere{0.5}
        sim.shape_create(w,handle,shape)
    }
}

@(test)
what_a_copy_marks_on_its_source_stays_in_the_allocator_of_the_source :: proc(t:^testing.T) {
    tracker:mem.Tracking_Allocator
    mem.tracking_allocator_init(&tracker,context.allocator);defer mem.tracking_allocator_destroy(&tracker)
    source,kept:Physics_State
    if !testing.expect(t,sim.world_init(&source.world,sim.world_desc_default())) {return}
    source.ready=true
    defer state_destroy(&source);defer state_destroy(&kept)
    {
        context.allocator=mem.tracking_allocator(&tracker)
        if !testing.expect(t,state_copy_kept(&kept,&source)) {return}
    }
    testing.expect(t,len(source.geometry)>0)
    testing.expect(t,source.geometry.allocator.data!=rawptr(&tracker),"the source would be freed by an allocator that its copy took with it")
}

@(test)
a_kept_copy_takes_what_the_simulation_uses_and_copies_back_to_the_same_steps :: proc(t:^testing.T) {
    whole_tracker,kept_tracker:mem.Tracking_Allocator
    mem.tracking_allocator_init(&whole_tracker,context.allocator);defer mem.tracking_allocator_destroy(&whole_tracker)
    mem.tracking_allocator_init(&kept_tracker,context.allocator);defer mem.tracking_allocator_destroy(&kept_tracker)
    source,kept,back:Physics_State
    if !testing.expect(t,sim.world_init(&source.world,sim.world_desc_default())) {return}
    source.ready=true
    defer state_destroy(&source);defer state_destroy(&kept);defer state_destroy(&back)
    ground:=sim.body_create(&source.world,{type=.Static,rotation=sim.QUAT_IDENTITY})
    floor:=sim.SHAPE_DESC_DEFAULT;floor.geometry=sim.Box{{20,0.5,20}}
    sim.shape_create(&source.world,ground,floor)
    physics_kept_drop(&source.world,6)
    for _ in 0..<30 {sim.world_step(&source.world,1.0/60)}
    {
        context.allocator=mem.tracking_allocator(&whole_tracker)
        whole:Physics_State
        testing.expect(t,state_copy(&whole,&source))
        state_destroy(&whole)
    }
    {
        context.allocator=mem.tracking_allocator(&kept_tracker)
        if !testing.expect(t,state_copy_kept(&kept,&source)) {return}
    }
    testing.expectf(t,kept_tracker.current_memory_allocated*20<whole_tracker.peak_memory_allocated,"kept %d bytes, a whole copy %d",kept_tracker.current_memory_allocated,whole_tracker.peak_memory_allocated)
    testing.expect(t,kept.world.kept && kept.world.desc.body_capacity==source.world.desc.body_capacity)
    // Copied back, it steps as the source does.
    if !testing.expect(t,state_copy(&back,&kept)) {return}
    testing.expect(t,!back.world.kept && len(back.world.bodies)==source.world.desc.body_capacity)
    for _ in 0..<30 {
        sim.world_step(&source.world,1.0/60)
        sim.world_step(&back.world,1.0/60)
    }
    testing.expect_value(t,sim.world_hash(&back.world),sim.world_hash(&source.world))
    // A source that outgrows the kept pools makes them again, larger.
    physics_kept_drop(&source.world,80)
    for _ in 0..<5 {sim.world_step(&source.world,1.0/60)}
    {
        context.allocator=mem.tracking_allocator(&kept_tracker)
        testing.expect(t,state_copy_kept(&kept,&source))
    }
    testing.expect(t,state_copy(&back,&kept))
    testing.expect_value(t,sim.world_hash(&back.world),sim.world_hash(&source.world))
    // A kept world is never stepped.
    before:=sim.world_hash(&kept.world)
    sim.world_step(&kept.world,1.0/60)
    testing.expect_value(t,sim.world_hash(&kept.world),before)
}
