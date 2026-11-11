package physics

import "core:testing"
import "mirai:core"
import volume "mirai:engine/volume"
import "mirai:std/geom"
import "mirai:std/jobs"
import sim "plugins:physics/runtime/sim"

// A wall of 4 x 2 x 0.4 m at the origin of a simulation alone, anchored by its base and cut in 16 pieces.
@(private="file")
test_wall :: proc(state:^Physics_State,position:[3]f32={0,1,0},user:u64=0) -> (Breakable_Handle,Breakable_Error) {
    mesh:geom.Mesh_Buffer
    geom.mesh_buffer_init(&mesh)
    defer geom.mesh_buffer_destroy(&mesh)
    geom.cube_build(&mesh,{4,2,0.4})
    sites:[16][3]f32
    geom.sites_generate(sites[:],{pattern=.Uniform,seed=7,lo={-2,-1,-0.2},hi={2,1,0.2}})
    anchors:=[1]sim.Aabb{{{-2.1,-1.1,-0.3},{2.1,-0.95,0.3}}}
    desc:=BREAKABLE_DESC_DEFAULT
    desc.mesh,desc.sites,desc.anchors,desc.position=geom.mesh_buffer_view(&mesh),sites[:],anchors[:],position
    desc.damage_radius,desc.user_data=1,user
    return breakable_create(state,desc)
}

@(private="file") WALL_SETTINGS :: Physics_Settings{bodies=64,shapes=128,contacts=1024,joints=1,hulls=96,events=64,breakables=2,pieces=64,bonds=256}

@(test)
a_copy_and_a_kept_copy_carry_what_broke_and_step_as_their_source :: proc(t:^testing.T) {
    source,copied,kept,back:Physics_State
    defer state_destroy(&source);defer state_destroy(&copied);defer state_destroy(&kept);defer state_destroy(&back)
    if !testing.expect(t,test_state_make(&source,WALL_SETTINGS)) {return}
    job_system:jobs.Job_System
    wall,error:=test_wall(&source)
    if !testing.expect_value(t,error,Breakable_Error.None) {return}
    test_ball(&source,{0,1.2,3},{0,0,-30})
    for _ in 0..<30 {
        testing.expect(t,simulate(&source,nil,&job_system,1.0/60))
        if breakable_revision(core.ref(&source),wall)!=0 {break}
    }
    if !testing.expect(t,breakable_revision(core.ref(&source),wall)!=0,"the ball broke the wall") {return}
    // Neither destination had a simulation, nor pools for what breaks: the copy makes them.
    if !testing.expect(t,state_copy(&copied,&source) && state_copy_kept(&kept,&source) && state_copy(&back,&kept)) {return}
    testing.expect(t,kept.world.kept && len(kept.world.pieces)<len(source.world.pieces))
    ends:=[3]^Physics_State{&source,&copied,&back}
    hash,check:=state_hash(core.ref(&source)),breakable_check(core.ref(&source),wall)
    pieces:[2][64]Piece_Info
    count:=breakable_pieces(core.ref(&source),wall,pieces[0][:])
    for end in ends[1:] {
        testing.expect_value(t,state_hash(core.ref(end)),hash)
        testing.expect_value(t,breakable_check(core.ref(end),wall),check)
        testing.expect_value(t,breakable_pieces(core.ref(end),wall,pieces[1][:]),count)
        testing.expect(t,pieces[0]==pieces[1],"the pieces of the copy are those of its source")
    }
    // The same cut and the same steps on the three: the halves take the hulls the slots of their pieces own.
    for step in 0..<40 {
        for end in ends {
            if step==5 {
                testing.expect(t,test_slice(end,wall,{0.5,1,0},{1,0.2,0}))
            }
            testing.expect(t,simulate(end,nil,&job_system,1.0/60))
        }
        hash=state_hash(core.ref(&source))
        if !testing.expectf(t,state_hash(core.ref(&copied))==hash && state_hash(core.ref(&back))==hash,"a copy diverged from its source at step %v",step) {return}
    }
    // A source whose breakables outgrow the kept pools makes them again.
    second,second_error:=test_wall(&source,{0,1,6})
    testing.expect_value(t,second_error,Breakable_Error.None)
    testing.expect(t,state_copy_kept(&kept,&source) && state_copy(&back,&kept))
    testing.expect_value(t,state_hash(core.ref(&back)),state_hash(core.ref(&source)))
    testing.expect(t,breakable_valid(core.ref(&back),second))
}

@(test)
a_strain_asked_of_a_volume_in_a_tick_breaks_what_its_filter_meets_after_the_step :: proc(t:^testing.T) {
    state:Physics_State
    defer state_destroy(&state)
    if !testing.expect(t,test_state_make(&state,WALL_SETTINGS)) {return}
    job_system:jobs.Job_System
    requests:Body_Requests
    defer delete(requests.queue.items)
    wall,error:=test_wall(&state,user=9)
    if !testing.expect_value(t,error,Breakable_Error.None) {return}
    view:=core.ref(&state)
    unseen:=QUERY_FILTER_DEFAULT
    unseen.objects=8
    nan:=transmute(f32)u32(0x7fc00000)
    // What strains nothing: a filter that does not see the wall, values that are not numbers, a volume
    // that is neither a box nor a sphere, one that does not reach the wall.
    strain_area(&requests,volume.sphere(5),{position={0,1,0}},1e6,filter=unseen)
    strain_area(&requests,volume.sphere(5),{position={nan,1,0}},1e6)
    strain_area(&requests,volume.sphere(5),{position={0,1,0}},nan)
    strain_area(&requests,volume.plane(),{position={0,9,0}},1e6)
    strain_area(&requests,volume.world(),{},1e6)
    strain_area(&requests,volume.box({1,1,1}),{position={0,9,0}},1e6)
    testing.expect(t,simulate(&state,&requests,&job_system,1.0/60))
    testing.expect_value(t,len(breakable_events(view)),0)
    // A weakening strains and breaks nothing; the blend of the volume is that of the event.
    strain_area(&requests,volume.sphere(5),{position={0,1,0}},1e6,weakening=true,blend=2)
    testing.expect(t,simulate(&state,&requests,&job_system,1.0/60))
    events:=breakable_events(view)
    testing.expect(t,len(events)==1 && events[0].kind==.Weaken && events[0].radius==5 && events[0].blend==2 && breakable_revision(view,wall)==0)
    // A box is scaled and turned by its pose.
    strain_area(&requests,volume.box({1,1,1}),{position={0,1,0},rotation=1,scale={5,-5,5}},1e6)
    testing.expect(t,simulate(&state,&requests,&job_system,1.0/60))
    events=breakable_events(view)
    testing.expect(t,len(events)==1 && events[0].breakable==wall && events[0].kind==.Damage && events[0].half_extents=={5,5,5} && breakable_revision(view,wall)!=0)
    // The bodies that came off name the entity of the breakable until their owner names them.
    pieces:[64]Piece_Info
    count:=min(breakable_pieces(view,wall,pieces[:]),len(pieces))
    root:=breakable_body(view,wall)
    loose:Body_Handle
    for piece in pieces[:count] {
        if piece.body!={} && piece.body!=root {loose=piece.body}
    }
    if !testing.expect(t,loose!={},"a piece came off") {return}
    testing.expect_value(t,entity_of(view,loose),core.Entity(9))
    testing.expect(t,breakable_body_name(&state,loose,core.Entity(12)))
    testing.expect_value(t,entity_of(view,loose),core.Entity(12))
    testing.expect_value(t,len(requests.queue.items),0)
}

@(test)
the_breakables_of_a_simulation_that_is_not_ready_or_of_stale_handles_are_refused :: proc(t:^testing.T) {
    ready,missing:Physics_State
    defer state_destroy(&ready)
    if !testing.expect(t,test_state_make(&ready,WALL_SETTINGS)) {return}
    wall,_:=test_wall(&ready)
    ball:=test_ball(&ready,{0,9,0},{})
    stale:=Breakable_Handle(u64(wall)+2)
    Case :: struct {state:^Physics_State,handle:Breakable_Handle}
    out:[4]Piece_Info
    bytes:[64]u8
    for c in ([]Case{{&missing,wall},{nil,wall},{&ready,{}},{&ready,stale},{&ready,Breakable_Handle(max(u64))}}) {
        view:=core.ref(c.state)
        testing.expect(t,!breakable_valid(view,c.handle) && breakable_body(view,c.handle)=={} && breakable_pieces(view,c.handle,out[:])==0)
        testing.expect(t,breakable_clusters(view,c.handle,nil)==0)
        testing.expect(t,breakable_revision(view,c.handle)==0 && breakable_check(view,c.handle)==0 && breakable_state_size(view,c.handle)==0)
        testing.expect(t,breakable_state_write(view,c.handle,bytes[:])==0 && !breakable_state_apply(c.state,c.handle,bytes[:]))
        for kind in Break_Kind {
            applied,changed,strained:=break_apply(c.state,{breakable=c.handle,piece=-1,region={point={0,1,0},radius=4},vector={0,1,0},strain=1e6,kind=kind})
            testing.expect(t,!changed && !strained && applied.breakable==c.handle)
        }
        changed,strained:=test_strain(c.state,c.handle,{0,1,0},4,1e6)
        testing.expect(t,!changed && !strained && !test_slice(c.state,c.handle,{0,1,0},{0,1,0}))
        events,refused:=breakable_shortfall(view,c.handle)
        _,expires:=breakable_body_remaining_ticks(view,c.handle,breakable_body(core.ref(&ready),wall))
        testing.expect(t,events==0 && refused=={} && !expires)
        breakable_destroy(c.state,c.handle)
        breakable_set_filter(c.state,c.handle,{})
    }
    testing.expect(t,breakable_room(core.ref(&missing))=={} && breakable_events(core.ref(&missing))==nil && breakable_of(core.ref(&missing),core.Entity(1))=={})
    made,error:=test_wall(&missing)
    testing.expect(t,made=={} && error==.Invalid_Desc)
    // A body that is of no breakable is not named through them.
    testing.expect(t,!breakable_body_name(&ready,ball,core.Entity(3)) && !breakable_body_name(&missing,ball,core.Entity(3)) && !breakable_body_name(&ready,{},core.Entity(3)))
    _,posed:=body_pose(core.ref(&missing),ball)
    testing.expect(t,!posed && breakable_valid(core.ref(&ready),wall) && breakable_revision(core.ref(&ready),wall)==0)
}
