package portals

import "core:math"
import "core:math/linalg"
import "core:testing"
import "mirai:core"
import phys "plugins:physics/runtime"
import mm "mirai:std/math"

@(private="file")
near :: proc(a,b:[3]f32) -> bool {return linalg.length(a-b)<1e-3}

@(test)
what_walks_into_a_portal_walks_out_of_its_exit :: proc(t:^testing.T) {
    // A door that faces +X and one, far away, that faces +Z.
    entrance:=mm.Transform{{-12,2.3,0},mm.quat_axis_angle({0,1,0},math.PI/2),{3.3,4.6,1}}
    exit:=mm.Transform{{200,2.3,-12},1,{3.3,4.6,1}}
    through:=through_of(entrance,exit)
    testing.expect(t,through.scale==[3]f32{1,1,1})
    // A metre in front of one is a metre behind the other, and its left stays its left.
    testing.expect(t,near(mm.transform_point(through,{-11,2.3,0}),{200,2.3,-13}))
    testing.expect(t,near(mm.transform_point(through,{-12,1,1}),{201,1,-12}))
    // Who walks in walks out, and up stays up.
    testing.expect(t,near(mm.quat_rotate(through.rotation,[3]f32{-1,0,0}),{0,0,1}))
    testing.expect(t,near(mm.quat_rotate(through.rotation,[3]f32{0,1,0}),{0,1,0}))
    // The way back undoes it.
    back:=through_of(exit,entrance)
    testing.expect(t,near(mm.transform_point(back,mm.transform_point(through,{-9,0.5,1.2})),{-9,0.5,1.2}))
}

@(test)
a_crossing_is_a_way_into_the_opening_from_its_front :: proc(t:^testing.T) {
    portal:=mm.Transform{{0,2,0},1,{2,4,1}}
    share,crossed:=crosses(portal,false,{0.5,2,0.3},{0.5,2,-0.1})
    testing.expect(t,crossed && abs(share-0.75)<1e-4)
    // From behind, beside the opening, and short of the plane, nothing crosses.
    _,crossed=crosses(portal,false,{0.5,2,-0.3},{0.5,2,0.1})
    testing.expect(t,!crossed)
    _,crossed=crosses(portal,false,{1.2,2,0.3},{1.2,2,-0.1})
    testing.expect(t,!crossed)
    _,crossed=crosses(portal,false,{0,2,0.3},{0,2,0})
    testing.expect(t,!crossed,"a point that stops on the plane has not gone in")
    // Leaving the plane inwards has.
    _,crossed=crosses(portal,false,{0,2,0},{0,2,-0.01})
    testing.expect(t,crossed)
    // The corner of the square is outside the ellipse inside it.
    _,crossed=crosses(portal,false,{0.9,3.8,0.1},{0.9,3.8,-0.1})
    testing.expect(t,crossed)
    _,crossed=crosses(portal,true,{0.9,3.8,0.1},{0.9,3.8,-0.1})
    testing.expect(t,!crossed)
    // A portal turned and without size.
    turned:=mm.Transform{{5,0,5},mm.quat_axis_angle({0,1,0},math.PI),{2,2,1}}
    _,crossed=crosses(turned,false,{5,0,4.5},{5,0,5.5})
    testing.expect(t,crossed)
    _,crossed=crosses({{0,0,0},1,{0,2,1}},false,{0,0,1},{0,0,-1})
    testing.expect(t,!crossed)
}

@(test)
the_hole_of_an_opening_goes_through_its_wall_and_its_frame_lines_it :: proc(t:^testing.T) {
    // An opening of 1.2 by 2.2 m that faces +X, 2 cm in front of a wall 30 cm thick.
    portal:=mm.Transform{{3,1.1,0},mm.quat_axis_angle({0,1,0},math.PI/2),{1.2,2.2,1}}
    hole:=hole_box(portal,0.32)
    inside :: proc(box:phys.Cut_Box,p:[3]f32) -> bool {
        local:=mm.quat_rotate(conj(box.rotation),p-box.center)
        return abs(local.x)<=box.half.x && abs(local.y)<=box.half.y && abs(local.z)<=box.half.z
    }
    // From the face of the wall to its back, across the opening and its frame; not the wall beyond.
    testing.expect(t,inside(hole,{2.98,1.1,0}) && inside(hole,{2.7,1.1,0}) && inside(hole,{2.9,0,0.6+RIM_WIDTH*0.5}))
    testing.expect(t,!inside(hole,{2.9,1.1,0.6+RIM_WIDTH+0.05}) && !inside(hole,{2.6,1.1,0}) && !inside(hole,{3.05,1.1,0}))
    // The frame fills what the hole takes of the wall beside the opening, and nothing of the opening.
    for box in rim_boxes(portal.scale.xy,0.02,0.32) {
        testing.expect(t,abs(box.center.z+0.17)<1e-5 && abs(box.half.z-0.15)<1e-5)
        low,high:=box.center-box.half,box.center+box.half
        clear:=high.x<=-0.6+1e-5 || low.x>=0.6-1e-5 || high.y<=-1.1+1e-5 || low.y>=1.1-1e-5
        testing.expectf(t,clear,"a box of the frame reaches into the opening: %v",box)
        testing.expect(t,low.x>=-0.6-RIM_WIDTH-1e-5 && high.x<=0.6+RIM_WIDTH+1e-5 && low.y>=-1.1-RIM_WIDTH-1e-5 && high.y<=1.1+RIM_WIDTH+1e-5)
    }
    // A sphere reaches into the opening when it crosses its plane within the square.
    _,reaches:=reaches_into(portal,{3.2,1.1,0.5},0.3)
    testing.expect(t,reaches)
    _,reaches=reaches_into(portal,{3.4,1.1,0},0.3)
    testing.expect(t,!reaches,"in front of it")
    _,reaches=reaches_into(portal,{3.1,1.1,1.5},0.3)
    testing.expect(t,!reaches,"beside it")
}

@(test)
a_character_that_falls_into_the_floor_comes_out_of_a_wall_upright_and_in_front_of_it :: proc(t:^testing.T) {
    // A portal on the floor whose top faces the way the player looked, and one in a wall that faces +X.
    floor:=mm.Transform{{0,0.02,0},mm.quat_axis_angle({1,0,0},-math.PI/2),{1.2,2.2,1}}
    wall:=mm.Transform{{10.02,1.1,0},mm.quat_axis_angle({0,1,0},math.PI/2),{1.2,2.2,1}}
    through:=through_of(floor,wall)
    capsule:=[3]f32{0.3,0.6,0}
    collider:=phys.collider_character(0.3,1.8)
    testing.expect(t,near(collider.size,capsule))
    // The eyes reach the floor looking down.
    placed:=mm.Transform{{0,-1.6,0},1,{1,1,1}}
    feet,yaw:=character_through(through,wall,placed,{0,1.6,0},{0,-1,0},collider)
    // It looks out of the wall, stands no lower than the opening and wholly in front of it.
    testing.expectf(t,abs(yaw+math.PI/2)<1e-3,"yaw %v",yaw)
    testing.expectf(t,feet.y>=-0.01,"feet %v",feet)
    testing.expectf(t,feet.x>=10.02+0.3,"feet %v",feet)
    // A wall to wall portal keeps the eyes where the portal takes them.
    other:=mm.Transform{{-5,1.1,3},1,{1.2,2.2,1}}
    feet,yaw=character_through(through_of(wall,other),other,mm.Transform{{10.05,0,0.2},mm.quat_axis_angle({0,1,0},-math.PI/2),{1,1,1}},{0,1.6,0},{-1,0,0},collider)
    testing.expect(t,near(feet+[3]f32{0,1.6,0},mm.transform_point(through_of(wall,other),{10.05,1.6,0.2})))
}

// Far from the centre of the world, the gates a view gets relative to the
// origin the renderer draws from find the opening and carry what crosses it
// as the world does; a light behind a gate moves with the origin, the sun
// does not.
@(test)
gates_go_to_the_shaders_relative_to_the_origin :: proc(t:^testing.T) {
    state:Portals_Gpu
    entrance:=mm.Transform{{-18000.5,2.3,9000.25},mm.quat_axis_angle({0,1,0},math.PI/2),{3.3,4.6,1}}
    exit:=mm.Transform{{-17800,2.3,9100},1,{1,1,1}}
    state.gates[0]={entrance=entrance,exit=exit}
    state.count=1
    state.constants.lights[0]={position_range={-17790,3,9105,10}}
    state.constants.lights[1]={position_range={0,1,0,0}}
    state.constants.light_count=2
    origin:=[3]f32{-17408,0,9216}
    c:=constants_relative(&state,origin)
    apply :: proc(m:[3][4]f32,p:[3]f32) -> (q:[3]f32) {
        for row,i in m {q[i]=row.x*p.x+row.y*p.y+row.z*p.z+row.w}
        return
    }
    // A metre in front of the middle of the opening, and where it comes out.
    front:=entrance.position+mm.quat_rotate(entrance.rotation,[3]f32{0,0,1})
    testing.expect(t,near(apply(c.gates[0].to_local,front-origin),{0,0,1}))
    testing.expect(t,near(apply(c.gates[0].through,front-origin),mm.transform_point(through_of(entrance,exit),front)-origin))
    testing.expect(t,near(c.lights[0].position_range.xyz,[3]f32{-17790,3,9105}-origin))
    testing.expect_value(t,c.lights[1].position_range,[4]f32{0,1,0,0})
}

// A world of the physics without gravity, where the tests below do what
// portals_collision and portals_travel do for a traveler every tick.
@(private="file")
Lab_World :: struct {
    using world:core.Test_World,
    using physics:phys.Test_Physics,
    twins:core.Table(phys.Body_Twin),
    cuts:core.Table(phys.Collider_Cuts),
    places:core.Places,
    jumps:core.Jumps,
}

@(private="file")
Lab :: struct {
    using w:Lab_World,
    using host:phys.Test_Physics_Host,
}

@(private="file")
lab_init :: proc(t:^testing.T,lab:^Lab) -> bool {
    if !core.test_world_init(t,&lab.w,phys.test_types) {return false}
    lab.settings={bodies=64,shapes=64,contacts=512,joints=4,characters=4,hulls=4,meshes=4,heightfields=4,fluids=4,events=64}
    lab.whole=true
    return true
}

@(private="file")
lab_destroy :: proc(lab:^Lab) {
    phys.test_host_destroy(&lab.host)
    core.test_world_destroy(&lab.w)
}

@(private="file")
lab_box :: proc(lab:^Lab,type:phys.Body_Type,position,half:[3]f32,rotation:mm.Quat=1,velocity:[3]f32={}) -> core.Entity {
    e:=core.create(&lab.entities)
    core.add(&lab.transforms,e,core.Transform{position=position,rotation=rotation,scale={1,1,1}})
    core.add(&lab.rigids,e,phys.Rigid_Body{type=type,gravity_scale=1})
    collider:=phys.collider_box(half)
    collider.friction=0
    core.add(&lab.colliders,e,collider)
    if velocity!={} {phys.set_velocity(&lab.requests,e,velocity)}
    return e
}

// Makes the bodies of the rows and applies the requests, without a step.
@(private="file")
lab_settle :: proc(lab:^Lab) {
    core.test_world_settle(&lab.w)
    phys.test_step(&lab.physics,&lab.host,0)
    core.test_world_settle(&lab.w)
}

@(private="file")
lab_body :: proc(lab:^Lab,e:core.Entity) -> phys.Body_Info {
    info,_:=phys.body_info(core.ref(&lab.state),phys.body_of(core.ref(&lab.state),e))
    return info
}

// The frame of an opening in a wall and the hole of the wall, as portals_collision makes them.
@(private="file")
lab_frame :: proc(lab:^Lab,wall:core.Entity,portal:mm.Transform,face,depth:f32) {
    for box in rim_boxes(portal.scale.xy,face,depth) {
        lab_box(lab,.Static,portal.position+mm.quat_rotate(portal.rotation,box.center),box.half,portal.rotation)
    }
    cuts,_:=core.get(&lab.cuts,wall)
    cuts.boxes[cuts.count]=hole_box(portal,depth)
    cuts.count+=1
    core.add(&lab.cuts,wall,cuts)
}

// The twin and the cuts of the traveler for this tick; whether it has a twin.
@(private="file")
lab_tick :: proc(lab:^Lab,traveler:core.Entity,openings:[]Opening) -> bool {
    bounds,_:=phys.body_bounds(core.ref(&lab.state),traveler)
    twin,cut,near:=traveler_twin(openings,0.5*(bounds.min+bounds.max),0.5*linalg.length(bounds.max-bounds.min))
    if near {
        core.add(&lab.twins,traveler,twin)
        mine:=phys.Collider_Cuts{count=1}
        mine.boxes[0]=cut
        core.add(&lab.cuts,traveler,mine)
    } else {
        if core.has(&lab.twins,traveler) {core.remove(&lab.twins,traveler)}
        if core.has(&lab.cuts,traveler) {core.remove(&lab.cuts,traveler)}
    }
    core.test_world_settle(&lab.w)
    phys.physics_twins(&lab.state,core.read(&lab.twins),core.read(&lab.cuts),&lab.problems)
    return near
}

@(private="file")
lab_step :: proc(lab:^Lab) {
    phys.test_step(&lab.physics,&lab.host,1.0/60)
    core.test_world_settle(&lab.w)
}

// A body whose center went into an opening comes out of its exit, with its velocity turned.
@(private="file")
lab_travel :: proc(lab:^Lab,traveler:core.Entity,openings:[]Opening,before:[3]f32) {
    body:=lab_body(lab,traveler)
    pose:=body.pose
    for opening in openings {
        if _,crossed:=crosses(opening.entrance,false,before,pose.position);!crossed {continue}
        through:=through_of(opening.entrance,opening.exit)
        core.place({&lab.transforms,core.read(&lab.parents),&lab.places,&lab.jumps},traveler,mm.transform_point(through,pose.position),through.rotation*pose.rotation)
        phys.physics_places(&lab.places,&lab.requests,core.ref(&lab.state),core.read(&lab.rigids),core.read(&lab.characters))
        phys.set_velocity(&lab.requests,traveler,mm.quat_rotate(through.rotation,body.linear))
        lab_settle(lab)
        return
    }
}

@(private="file")
lab_run :: proc(lab:^Lab,traveler:core.Entity,openings:[]Opening,ticks:int) -> (twinned:int) {
    before:=lab_body(lab,traveler).pose.position
    for _ in 0..<ticks {
        if lab_tick(lab,traveler,openings) {twinned+=1}
        lab_step(lab)
        lab_travel(lab,traveler,openings,before)
        before=lab_body(lab,traveler).pose.position
    }
    return
}

// Two openings that stand free and lead to each other: one at the origin that faces +Z, and one far
// away that faces +X. What goes 30 cm into the first comes 30 cm out of the second.
@(private="file")
lab_openings :: proc() -> [2]Opening {
    a:=mm.Transform{{0,0,0},1,{1.2,1.2,1}}
    b:=mm.Transform{{20,0,0},mm.quat_axis_angle({0,1,0},math.PI/2),{1.2,1.2,1}}
    return {{entrance=a,exit=b},{entrance=b,exit=a}}
}

@(test)
a_body_halfway_through_an_opening_meets_what_is_in_front_of_the_exit :: proc(t:^testing.T) {
    openings:=lab_openings()
    {
        lab:Lab
        if !lab_init(t,&lab) {return}
        defer lab_destroy(&lab)
        // A cube goes into the first opening, and a wall stands 15 cm in front of the second.
        cube:=lab_box(&lab,.Dynamic,{0,0,0.4},{0.25,0.25,0.25},1,{0,0,-1})
        lab_box(&lab,.Static,{20.15+0.25,0,0},{0.25,2,2})
        lab_settle(&lab)
        testing.expect(t,lab_run(&lab,cube,openings[:],60)>0)
        // The part that comes out stops at the wall: the cube stays halfway in, on this side.
        at:=lab_body(&lab,cube)
        testing.expectf(t,abs(at.pose.position.z-0.1)<0.03 && abs(at.pose.position.x)<1e-3,"the cube is at %v",at.pose.position)
        testing.expectf(t,linalg.length(at.linear)<0.05,"the cube moves at %v",at.linear)
        testing.expect_value(t,core.count(&lab.cuts),1)
        testing.expect_value(t,lab.problems.count,0)
    }
    {
        lab:Lab
        if !lab_init(t,&lab) {return}
        defer lab_destroy(&lab)
        // In front of the second opening a crate stands instead: the part that comes out pushes it,
        // and the crate pushes the cube back as much.
        cube:=lab_box(&lab,.Dynamic,{0,0,0.4},{0.25,0.25,0.25},1,{0,0,-1})
        crate:=lab_box(&lab,.Dynamic,{20.35,0,0},{0.2,0.2,0.2})
        lab_settle(&lab)
        lab_run(&lab,cube,openings[:],30)
        pushed:=lab_body(&lab,crate).pose.position
        testing.expectf(t,pushed.x>20.4,"the crate is at %v",pushed)
        testing.expectf(t,abs(pushed.y)<1e-3 && abs(pushed.z)<1e-3,"the crate is pushed out of the opening: %v",pushed)
        moving:=lab_body(&lab,cube).linear
        testing.expectf(t,linalg.length(moving)<0.9,"the cube moves at %v",moving)
    }
}

@(test)
a_wall_of_any_collider_lets_through_its_opening_and_stops_beside_it :: proc(t:^testing.T) {
    lab:Lab
    if !lab_init(t,&lab) {return}
    defer lab_destroy(&lab)
    // A wall that is a sphere 10 m across whose top faces +Z at the origin, with an opening there.
    wall:=core.create(&lab.entities)
    core.add(&lab.transforms,wall,core.Transform{position={0,0,-5},rotation=1,scale={1,1,1}})
    core.add(&lab.colliders,wall,phys.collider_sphere(5))
    portal:=mm.Transform{{0,0,0.02},1,{1.2,1.2,1}}
    lab_frame(&lab,wall,portal,0.02,WALL_DEPTH_MAX)
    lab_settle(&lab)
    phys.physics_twins(&lab.state,core.read(&lab.twins),core.read(&lab.cuts),&lab.problems)
    testing.expect_value(t,lab.problems.count,0)
    // A ray finds the wall beside the opening and not in it.
    _,hit:=phys.raycast(core.ref(&lab.state),{0,0,1},{0,0,-1},2)
    testing.expect(t,!hit,"a ray through the opening goes into the hole")
    beside,found:=phys.raycast(core.ref(&lab.state),{1.5,0,1},{0,0,-1},2)
    testing.expectf(t,found && beside.entity==wall,"a ray beside it hits the wall: %v",beside)
    // One cube goes in through the opening; another, beside it, stops on the wall.
    into:=lab_box(&lab,.Dynamic,{0,0,0.5},{0.2,0.2,0.2},1,{0,0,-2})
    onto:=lab_box(&lab,.Dynamic,{2,0,0.3},{0.2,0.2,0.2},1,{0,0,-2})
    lab_settle(&lab)
    for _ in 0..<40 {lab_step(&lab)}
    in_hole:=lab_body(&lab,into).pose.position
    testing.expectf(t,in_hole.z< -0.6 && abs(in_hole.x)<0.05,"the cube in the opening is at %v",in_hole)
    stopped:=lab_body(&lab,onto).pose.position
    from_center:=linalg.length(stopped-[3]f32{0,0,-5})
    testing.expectf(t,from_center>5.15,"the cube beside the opening is %v m from the center of the wall",from_center)
    // The frame holds what is in the hole: pushed sideways, the cube stays inside the opening.
    phys.set_velocity(&lab.requests,into,{3,0,0})
    lab_settle(&lab)
    for _ in 0..<30 {lab_step(&lab)}
    held:=lab_body(&lab,into).pose.position
    testing.expectf(t,held.x<0.6-0.2+0.03,"the cube in the hole is at %v",held)
}

@(test)
the_twin_of_a_body_goes_once_it_is_through :: proc(t:^testing.T) {
    lab:Lab
    if !lab_init(t,&lab) {return}
    defer lab_destroy(&lab)
    openings:=lab_openings()
    cube:=lab_box(&lab,.Dynamic,{0.3,0,1},{0.25,0.25,0.25},1,{0,0,-3})
    lab_settle(&lab)
    testing.expect(t,lab_run(&lab,cube,openings[:],60)>0)
    // Out of the exit and on its way, with no twin, cut or copy left: nothing is where a copy would be.
    out:=lab_body(&lab,cube).pose.position
    testing.expectf(t,out.x>21 && abs(out.z-0.3)<1e-3,"the cube is at %v",out)
    testing.expect_value(t,core.count(&lab.twins),0)
    testing.expect_value(t,core.count(&lab.cuts),0)
    found:[4]core.Entity
    copied,_:=phys.overlap_sphere(core.ref(&lab.state),mm.transform_point(through_of(openings[1].entrance,openings[1].exit),out),0.5,found[:])
    testing.expect_value(t,copied,0)
    testing.expect_value(t,lab.problems.count,0)
}

@(test)
a_body_halfway_through_an_opening_steps_again_the_same_from_a_snapshot :: proc(t:^testing.T) {
    lab:Lab
    if !lab_init(t,&lab) {return}
    defer lab_destroy(&lab)
    openings:=lab_openings()
    // The cube pushes a crate against a wall in front of the exit, and goes through.
    cube:=lab_box(&lab,.Dynamic,{0,0,0.4},{0.25,0.25,0.25},1,{0,0,-1.5})
    lab_box(&lab,.Static,{20.6+0.25,0,0},{0.25,2,2})
    lab_box(&lab,.Dynamic,{20.3,0.1,0.1},{0.15,0.15,0.15})
    lab_settle(&lab)
    run :: proc(lab:^Lab,cube:core.Entity,openings:[]Opening,hashes:[]u64) {
        before:=lab_body(lab,cube).pose.position
        for &hash in hashes {
            lab_tick(lab,cube,openings)
            lab_step(lab)
            lab_travel(lab,cube,openings,before)
            before=lab_body(lab,cube).pose.position
            hash=phys.state_hash(core.ref(&lab.state))
        }
    }
    first:[8]u64
    run(&lab,cube,openings[:],first[:])
    testing.expect(t,core.has(&lab.twins,cube),"the snapshot is taken halfway in")
    snapshot:Lab_World
    if !core.test_world_init(t,&snapshot,phys.test_types) {return}
    defer core.test_world_destroy(&snapshot)
    testing.expect(t,core.test_world_copy(&snapshot,&lab.w))
    once,again:[40]u64
    run(&lab,cube,openings[:],once[:])
    testing.expect(t,core.test_world_copy(&lab.w,&snapshot))
    run(&lab,cube,openings[:],again[:])
    testing.expect(t,once==again)
}
