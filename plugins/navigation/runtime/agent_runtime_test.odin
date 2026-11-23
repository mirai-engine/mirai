package navigation

import "base:intrinsics"
import "core:math/linalg"
import "core:testing"
import "mirai:core"
import "mirai:std/jobs"
import mm "mirai:std/math"
import phys "plugins:physics/runtime"

@(test)
an_authored_link_reserves_both_directions_and_ghosts_its_crossing :: proc(t:^testing.T) {
    f:Nav_Test
    if !nav_test_init(t,&f) {return}
    defer nav_test_destroy(&f)
    nav_test_box(&f,{0,-0.5,0},{8,0.5,3})
    wall:=nav_test_box(&f,{0,1,0},{0.2,1,3})
    door:=core.create(&f.entities)
    core.add(&f.transforms,door,core.Transform{{-1,0,0},1,{1,1,1}})
    core.add(&f.links,door,Nav_Link{
        enabled=true,capacity=1,passthrough=true,
        end={2,0,0},kind=LINK_DOOR,two_way=true,area=AREA_WALKABLE,
    })
    nav_test_settled(t,&f)

    walkers:=[2]core.Entity{
        agents_test_walker(&f,{-1.2,0,0}),agents_test_walker(&f,{1.2,0,0}),
    }
    nav_test_settle(&f)
    for e,i in walkers {
        core.edit(&f.agents,e).abilities=Nav_Abilities(1<<u32(ABILITY_DOOR))
        nav_move_to(&f.nav_requests,e,{4 if i==0 else -4,0,0})
    }
    active:=core.NONE
    for _ in 0..<120 {
        agents_test_step(&f)
        for event in f.nav_events.queue.items {
            if event.kind!=.Crossing {continue}
            testing.expect(t,active==core.NONE && event.link_entity==door && event.manual)
            active=event.entity
        }
        if active!=core.NONE {break}
    }
    if active==core.NONE {testing.fail_now(t,"neither agent started the crossing")}
    waiting:=walkers[1] if active==walkers[0] else walkers[0]
    for _ in 0..<15 {agents_test_step(&f)}
    p,_:=core.get(&f.paths,active)
    other,_:=core.get(&f.paths,waiting)
    move,_:=core.get(&f.moves,active)
    testing.expect(t,p.state==.Crossing && p.link_entity==door && .Ghosted in move.value.flags)
    testing.expect(t,other.state==.Moving && other.link_entity==core.NONE)
    // Through the wall it collides with nothing, but a bullet still hits it.
    crosser,_:=core.get(&f.worlds,active)
    shot,hit:=phys.raycast(core.ref(&f.state),crosser.position+{0,5,0},{0,-1,0},10,ignore=wall)
    testing.expectf(t,hit && shot.entity==active,"a ray down at the crossing agent hits %v",shot.entity)

    core.add(&f.disabled,active,core.Disabled{})
    started:=false
    began:Nav_Event
    for _ in 0..<60 {
        agents_test_step(&f)
        for event in f.nav_events.queue.items {
            if event.entity==waiting && event.kind==.Crossing && event.link_entity==door {started,began=true,event}
        }
        if started {break}
    }
    if !started {testing.fail_now(t,"the next agent did not get the released link")}
    core.remove(&f.disabled,active)
    nav_stop(&f.nav_requests,active)
    agents_test_step(&f)
    resumed,resumed_ok:=core.get(&f.moves,active)
    testing.expect(t,resumed_ok && .Ghosted not_in resumed.value.flags)
    testing.expect(t,f.problems.count==0)
    core.destroy(&f.entities,active)

    // The ends of the link it crosses are what its clip warps onto, facing across it.
    crossing,_:=core.get(&f.paths,waiting)
    from,to,facing,crosses:=nav_crossing_target(&f.run,crossing,waiting)
    testing.expectf(t,crosses && from==began.from && to==began.to && from!=to,"link from %v to %v, the event %v",from,to,began)
    ahead:=mm.quat_forward(facing)
    testing.expectf(t,linalg.dot(ahead.xz,linalg.normalize((to-from).xz))>0.999,"it faces %v across the link",ahead)
    // The clip takes it to the end, a little aside: a skip lets it go on from there, not put at the end.
    aside:=to+{0,0,0.15}
    for k in 1..=12 {
        position:=from+(aside-from)*f32(k)/12
        core.add(&f.replicas,waiting,core.Pose_Target{
            follow=true,position=position,rotation=1,scale={1,1,1},
        })
        agents_test_step(&f)
    }
    core.remove(&f.replicas,waiting)
    nav_crossing_skip(&f.nav_requests,waiting)
    agents_test_step(&f)
    crossed:=false
    for event in f.nav_events.queue.items {
        crossed|=event.entity==waiting && event.kind==.Crossed && event.link_entity==door
    }
    p,_=core.get(&f.paths,waiting)
    move,_=core.get(&f.moves,waiting)
    pose,_:=core.get(&f.transforms,waiting)
    testing.expect(t,crossed && p.link_entity==core.NONE && .Ghosted not_in move.value.flags)
    testing.expectf(t,linalg.length(pose.position.xz-aside.xz)<0.07,"it goes on from %v, at %v",aside,pose.position)
    _,_,_,after:=nav_crossing_target(&f.run,p,waiting)
    testing.expect(t,!after,"no target once across")
    testing.expect(t,core.entity_map_get(&f.run.reservations,door)==nil)
}

@(test)
a_collider_gate_carves_its_cached_tiles_as_it_moves :: proc(t:^testing.T) {
    f:Nav_Test
    if !nav_test_init(t,&f) {return}
    defer nav_test_destroy(&f)
    nav_test_box(&f,{0,-0.5,0},{8,0.5,2})
    nav_test_settled(t,&f)

    gate:=nav_test_box(&f,{0,0.75,0},{0.3,1,2})
    core.add(&f.rigids,gate,phys.RIGID_BODY_KINEMATIC)
    core.add(&f.obstacles,gate,Nav_Obstacle{settle=0})
    f.time={playing=true,dt=1.0/60}
    for build in f.builds.builds {
        build.busy,build.due=true,max(u64)
    }
    carved:=f.nav.stats.carved
    nav_test_step(&f)
    testing.expect(t,f.nav.stats.carved>carved && !core.has(&f.volumes,gate))
    _,status:=nav_test_path(t,&f,{-4,0,0},{4,0,0},{})
    testing.expect_value(t,status,.No_Path)

    core.edit(&f.transforms,gate).position.y+=5
    nav_test_step(&f)
    _,status=nav_test_path(t,&f,{-4,0,0},{4,0,0},{})
    testing.expect_value(t,status,.Found)
}

@(test)
a_follower_resumes_after_its_target_backpedals_within_swing_range :: proc(t:^testing.T) {
    f:Nav_Test
    if !nav_test_init(t,&f) {return}
    defer nav_test_destroy(&f)
    nav_test_box(&f,{0,-0.5,0},{8,0.5,3})
    nav_test_settled(t,&f)
    e:=agents_test_walker(&f,{-3,0,0})
    target:=agents_test_walker(&f,{1,0,0})
    nav_test_settle(&f)
    core.remove(&f.agents,target)
    nav_follow(&f.nav_requests,e,target,1)
    arrived,_,_,_:=agents_test_travel(&f,e,4)
    testing.expect(t,arrived)

    phys.set_velocity(&f.requests,target,{})
    core.place({&f.transforms,core.read(&f.parents),&f.places,&f.jumps},target,{1.3,0,0})
    moved:=false
    for _ in 0..<90 {
        agents_test_step(&f)
        p,_:=core.get(&f.paths,e)
        moved|=p.velocity.x>0.1
    }
    follower,_:=core.get(&f.worlds,e)
    goal,_:=core.get(&f.worlds,target)
    p,_:=core.get(&f.paths,e)
    testing.expectf(t,moved && linalg.length(goal.position.xz-follower.position.xz)<=1.02,
                    "follower %v at %v, target at %v, moved %v",
                    p.state,follower.position,goal.position,moved)
}

@(test)
placing_and_removing_an_agent_clear_its_route_and_drive :: proc(t:^testing.T) {
    f:Nav_Test
    if !nav_test_init(t,&f) {return}
    defer nav_test_destroy(&f)
    nav_test_box(&f,{0,-0.5,0},{10,0.5,4})
    nav_test_settled(t,&f)
    e:=agents_test_walker(&f,{-5,0,0})
    nav_move_to(&f.nav_requests,e,{5,0,0})
    for _ in 0..<10 {agents_test_step(&f)}
    route:=agent_route(&f.run,e)
    steered,_:=core.get(&f.inputs,e)
    testing.expect(t,route!=nil && route.corridor.count>0 && steered.world_velocity)

    for late in ([2]bool{false,true}) {
        request:=core.Place_Request{
            entity=e,position={2,0,-2 if late else 2},rotation=1,at_rest=true,
        }
        if late {agents_test_step(&f,request)} else {
            core.place({&f.transforms,core.read(&f.parents),&f.places,&f.jumps},
                       e,request.position,at_rest=true)
            agents_test_step(&f)
        }
        p,_:=core.get(&f.paths,e)
        testing.expect(t,route.corridor.count==0 && p.state==.Waiting && !core.has(&f.inputs,e))
        for _ in 0..<4 {agents_test_step(&f)}
        testing.expect(t,route.corridor.count>0 && route.corridor.position.x>1)
    }

    core.remove(&f.agents,e)
    agents_test_step(&f)
    testing.expect(t,agent_route(&f.run,e)==nil && !core.has(&f.inputs,e) && !core.has(&f.paths,e))
}

@(test)
an_agent_queued_behind_a_crossing_keeps_its_path :: proc(t:^testing.T) {
    f:Nav_Test
    if !nav_test_init(t,&f) {return}
    defer nav_test_destroy(&f)
    f.nav.count=1
    f.nav.classes[0].class.radius=0.3
    e,leader:=core.create(&f.entities),core.create(&f.entities)
    core.add(&f.paths,e,Nav_Path{state=.Moving,velocity={2,0,0}})
    core.add(&f.paths,leader,Nav_Path{state=.Crossing,velocity={0.05,0,0}})
    core.entity_map_put(&f.run.routes,e,Nav_Route{})
    nav_test_settle(&f)
    append(&f.run.near,Near{
        entity=e,radius=0.3,height=1.8,path_row=1,route_slot=1,
    })
    append(&f.run.near,Near{
        entity=leader,position={0.6,0,0},velocity={0.05,0,0},radius=0.3,height=1.8,path_row=2,
    })
    agents_avoid(&f.nav,&f.run,&f.paths,nil,1.0/60,&f.problems)
    for _ in 0..<60*7 {agents_stuck(&f.nav,&f.run,&f.paths,1.0/60,&f.nav_events,&f.problems)}
    p,_:=core.get(&f.paths,e)
    testing.expect(t,p.state==.Moving && core.problem_find(&f.problems,e,"navigation.blocked")==nil)
}

// A wide agent ahead counts as a crowd however far its center stands beyond the narrow one's reach.
@(test)
a_wide_agent_ahead_is_a_crowd :: proc(t:^testing.T) {
    f:Nav_Test
    if !nav_test_init(t,&f) {return}
    defer nav_test_destroy(&f)
    e,wide:=core.create(&f.entities),core.create(&f.entities)
    core.add(&f.paths,e,Nav_Path{state=.Moving,velocity={2,0,0}})
    core.add(&f.paths,wide,Nav_Path{state=.Moving,velocity={0.05,0,0}})
    nav_test_settle(&f)
    append(&f.run.near,Near{entity=e,position={1,0.9,1},radius=0.3,height=1.8,path_row=1})
    append(&f.run.near,Near{
        entity=wide,position={3.7,0.9,1},velocity={0.05,0,0},radius=2,height=1.8,path_row=2,
    })
    agents_avoid(&f.nav,&f.run,&f.paths,nil,1.0/60,&f.problems)
    testing.expect_value(t,f.run.widest_ground,f32(2))
    testing.expect(t,held_ahead(&f.run,&f.run.near[0],core.NONE,false))
}

@(test)
parallel_avoidance_matches_the_owner_and_excludes_the_target :: proc(t:^testing.T) {
    f:Nav_Test
    if !nav_test_init(t,&f,2) {return}
    defer nav_test_destroy(&f)
    wanted:=mm.Vec3{4,0,0}
    first,second:core.Entity
    for i in 0..<48 {
        e:=core.create(&f.entities)
        if i==0 {first=e}
        if i==1 {second=e}
        core.add(&f.paths,e,Nav_Path{state=.Moving,class=-1,velocity=wanted})
    }
    nav_test_settle(&f)
    expected:[48]mm.Vec3
    for parallel in ([2]bool{false,true}) {
        clear(&f.run.near)
        for e,i in f.paths.entities {
            p:=core.edit_at(&f.paths,i)
            p.velocity=wanted
            if e==first {p.target=second}
            position:=mm.Vec3{f32(i-2),0,30} if i>=2 else {2*f32(i),0,0}
            append(&f.run.near,Near{
                entity=e,position=position,radius=0.4,height=1.8,avoids=true,path_row=i+1,
            })
        }
        agents_avoid(&f.nav,&f.run,&f.paths,nil,1.0/60,&f.problems,
                     &f.app.jobs if parallel else nil)
        for p,i in f.paths.values {
            if parallel {testing.expect_value(t,p.velocity,expected[i])}
            else {expected[i]=p.velocity}
        }
    }
    testing.expect_value(t,expected[0],wanted)
    testing.expect(t,expected[2]!=wanted)
}

@(test)
gameplay_keeps_a_due_tile_job_while_its_counter_is_pending :: proc(t:^testing.T) {
    n:Navigation
    b:Navigation_Builds
    build:Build
    append(&b.builds,&build)
    defer delete(b.builds)
    build.busy=true
    build.due=b.ticks
    intrinsics.atomic_store(&build.counter.pending,1)
    problems:core.Problems
    published,_:=builds_publish(&n,&b,&problems)
    testing.expect(t,published==0 && build.busy)

    intrinsics.atomic_store(&build.counter.pending,0)
    published,_=builds_publish(&n,&b,&problems)
    testing.expect(t,published==1 && !build.busy)
}
