package navigation

import "core:math/linalg"
import "core:testing"
import "mirai:core"
import "mirai:std/ai"
import "mirai:std/base"
import mm "mirai:std/math"
import locomotion "plugins:locomotion/runtime"
import phys "plugins:physics/runtime"

// An agent without a Character: a walker of a crowd that navigation moves itself.
@(private)
bodyless_walker :: proc(f:^Nav_Test,feet:[3]f32) -> core.Entity {
    e:=core.create(&f.entities)
    core.add(&f.transforms,e,core.Transform{feet,1,{1,1,1}})
    core.add(&f.walks,e,locomotion.WALK_DEFAULT)
    core.add(&f.agents,e,NAV_AGENT_DEFAULT)
    return e
}

// A character that navigation does not move: a player standing in the way.
@(private)
bodyless_player :: proc(f:^Nav_Test,feet:[3]f32) -> core.Entity {
    e:=core.create(&f.entities)
    core.add(&f.transforms,e,core.Transform{feet,1,{1,1,1}})
    core.add(&f.colliders,e,phys.collider_character())
    core.add(&f.characters,e,phys.character_default())
    core.add(&f.moves,e,phys.Character_Move{})
    core.add(&f.bodies,e,core.Motion{})
    return e
}

// The height of the detail of the mesh under a point, and how far across from
// the mesh the point is.
@(private="file")
bodyless_surface :: proc(f:^Nav_Test,at:mm.Vec3) -> (height,off:f32,found:bool) {
    mesh:=&f.nav.classes[0].mesh
    filter:=filter_make(&f.nav_settings,{},{})
    ref,nearest,ok:=ai.nav_find_nearest(mesh,at,{0.5,1,0.5},&filter)
    if !ok {return}
    height,found=ai.nav_poly_height(mesh,ref,nearest)
    return height,linalg.length(nearest.xz-at.xz),found
}

// Up stairs, across a landing and down a ramp: an agent without a Character
// walks there on the mesh, at the height of its detail, writing its Transform
// and a core.Motion that is how it moved, and faces the way it goes.
@(test)
a_bodyless_agent_walks_stairs_and_a_ramp_on_the_detail_of_the_mesh :: proc(t:^testing.T) {
    f:Nav_Test
    if !nav_test_init(t,&f) {return}
    defer nav_test_destroy(&f)
    nav_test_box(&f,{0,-0.5,0},{12,0.5,4})
    for k in 0..<8 {
        rise:=0.1*f32(k+1)
        nav_test_box(&f,{-4+0.5*f32(k)+0.25,rise,0},{0.25,rise,3})
    }
    nav_test_box(&f,{2,0.8,0},{2,0.8,3})
    slope:=f32(-0.2606) // rad about +Z: down 1.6 m over 6 m toward +X
    ramp:=core.create(&f.entities)
    core.add(&f.transforms,ramp,core.Transform{{6.936,0.5585,0},mm.quat_axis_angle({0,0,1},slope),{1,1,1}})
    core.add(&f.colliders,ramp,phys.collider_box({3.2,0.25,3}))
    nav_test_settled(t,&f)

    e:=bodyless_walker(&f,{-10,0,0})
    nav_test_settle(&f)
    nav_move_to(&f.nav_requests,e,{11,0,0})
    previous:=mm.Vec3{-10,0,0}
    top,climbed,descended,arrived:=f32(0),false,false,false
    for tick in 0..<60*20 {
        agents_test_step(&f)
        transform,_:=core.get(&f.transforms,e)
        at:=transform.position
        motion,moves:=core.get(&f.bodies,e)
        // From its first step on, it is on the mesh.
        if motion.linear!={} {
            height,off,found:=bodyless_surface(&f,at)
            testing.expectf(t,found && off<1e-3 && abs(at.y-height)<0.02,"tick %d at %v: surface %v, %v m across",tick,at,height,off)
            testing.expectf(t,moves && linalg.length(motion.linear-(at-previous)*60)<1e-2,"tick %d: motion %v, moved %v",tick,motion.linear,(at-previous)*60)
        }
        climbed|=motion.linear.y>0.1
        descended|=motion.linear.y< -0.1
        top=max(top,at.y)
        previous=at
        p,_:=core.get(&f.paths,e)
        if p.state==.Arrived {arrived=true;break}
        if !testing.expectf(t,p.state!=.Failed,"it fails at %v",at) {break}
    }
    transform,_:=core.get(&f.transforms,e)
    testing.expectf(t,arrived && linalg.length(transform.position.xz-mm.Vec2{11,0})<0.5,"it arrives %v at %v",arrived,transform.position)
    testing.expectf(t,climbed && descended && top>1.5,"it went up %v to %v m and down %v",climbed,top,descended)
    testing.expect(t,linalg.dot(mm.quat_forward(transform.rotation),mm.Vec3{1,0,0})>0.9,"it faces the way it walked")
    testing.expect(t,!core.has(&f.inputs,e) && !core.has(&f.loco_states,e),"nothing asks a locomotion it has not")
    bodyless_no_problems(t,&f)
}

// A player that navigation does not move stands in the way of an agent
// without a body, which steps aside from it rather than through it, and
// plans another way round when the player holds it; a crowd of a hundred of
// them, all near each other, steps aside from two players.
@(test)
bodyless_agents_step_aside_from_players_in_a_crowd_of_any_size :: proc(t:^testing.T) {
    f:Nav_Test
    if !nav_test_init(t,&f) {return}
    defer nav_test_destroy(&f)
    nav_test_box(&f,{0,-0.5,0},{20,0.5,20})
    nav_test_settled(t,&f)
    player:=bodyless_player(&f,{0,0,0.1})
    e:=bodyless_walker(&f,{-5,0,0})
    nav_test_settle(&f)
    nav_move_to(&f.nav_requests,e,{5,0,0})
    clearance:=f32(0.3+0.3)
    closest:=f32(100)
    arrived:=false
    for _ in 0..<60*10 {
        agents_test_step(&f)
        at,_:=core.get(&f.transforms,e)
        held,_:=core.get(&f.transforms,player)
        closest=min(closest,linalg.length(at.position.xz-held.position.xz))
        p,_:=core.get(&f.paths,e)
        if p.state==.Arrived {arrived=true;break}
    }
    testing.expectf(t,arrived && closest>=clearance-0.05,"it arrives %v, %v m from the player at its closest",arrived,closest)

    crowd:[100]core.Entity
    for &walker,i in crowd {
        walker=bodyless_walker(&f,{-15+f32(i%10),0,-5+f32(i/10)})
    }
    other:=bodyless_player(&f,{0,0,3})
    nav_test_settle(&f)
    // A new agent gets its Nav_Path in one tick and is near the others from the next.
    agents_test_step(&f)
    for walker,i in crowd {nav_move_to(&f.nav_requests,walker,{6+f32(i%10),0,-5+f32(i/10)})}
    agents_test_step(&f)
    testing.expect_value(t,len(f.run.near),len(crowd)+3)
    overlaps:=0
    for _ in 0..<60*15 {
        agents_test_step(&f)
        for walker in crowd {
            at,_:=core.get(&f.transforms,walker)
            for standing in ([2]core.Entity{player,other}) {
                held,_:=core.get(&f.transforms,standing)
                if linalg.length(at.position.xz-held.position.xz)<clearance-0.1 {overlaps+=1}
            }
        }
    }
    arrivals:=0
    for walker in crowd {
        p,_:=core.get(&f.paths,walker)
        if p.state==.Arrived {arrivals+=1}
    }
    testing.expectf(t,overlaps==0 && arrivals>=95,"%d ticks inside a player, %d of %d arrived",overlaps,arrivals,len(crowd))
    bodyless_no_problems(t,&f)
}

// Across a gap to a higher platform by a jump link: an agent without a body
// goes along the arc of the launch, over both ends, and lands at the end of
// the link on its mesh; one that leaves jumps to the game waits at the start
// until the game skips it across.
@(test)
a_bodyless_agent_jumps_a_link_along_its_arc :: proc(t:^testing.T) {
    f:Nav_Test
    if !nav_test_init(t,&f) {return}
    defer nav_test_destroy(&f)
    f.nav_settings.classes[0].jump_up,f.nav_settings.classes[0].jump_across,f.nav_settings.classes[0].drop=0,0,0
    nav_test_box(&f,{-4,-0.5,0},{2.5,0.5,3})
    nav_test_box(&f,{4,0,0},{2.5,0.5,3})
    jump:=core.create(&f.entities)
    core.add(&f.transforms,jump,core.Transform{{-2,0,0},1,{1,1,1}})
    core.add(&f.links,jump,Nav_Link{enabled=true,end={4,0.5,0},kind=LINK_JUMP,two_way=true,area=AREA_WALKABLE})
    nav_test_settled(t,&f)

    for manual in ([2]bool{false,true}) {
        e:=bodyless_walker(&f,{-5,0,0})
        nav_test_settle(&f)
        // It drops from the top of the arc onto the higher end.
        core.edit(&f.agents,e).drop=1
        if manual {core.edit(&f.agents,e).manual=Nav_Link_Kinds(1<<u32(LINK_JUMP))}
        nav_move_to(&f.nav_requests,e,{5,0.5,0})
        apex,rising:=f32(-1),false
        from,to:mm.Vec3
        began,landed,arrived:=false,false,false
        for _ in 0..<60*15 {
            agents_test_step(&f)
            at,_:=core.get(&f.transforms,e)
            for event in f.nav_events.queue.items {
                if event.entity!=e {continue}
                #partial switch event.kind {
                case .Crossing:
                    testing.expect(t,event.link==LINK_JUMP && event.manual==manual)
                    began,from,to=true,event.from,event.to
                    if manual {nav_crossing_skip(&f.nav_requests,e)}
                case .Crossed:
                    landed=true
                    testing.expectf(t,linalg.length(at.position-to)<0.05,"it lands at %v, the link ends at %v",at.position,to)
                }
            }
            p,_:=core.get(&f.paths,e)
            if p.state==.Crossing {
                apex=max(apex,at.position.y)
                motion,_:=core.get(&f.bodies,e)
                rising|=motion.linear.y>0.5
            }
            if p.state==.Arrived {arrived=true;break}
        }
        testing.expectf(t,began && landed && arrived,"manual %v: it begins %v, lands %v, arrives %v",manual,began,landed,arrived)
        if manual {
            testing.expectf(t,apex<=max(from.y,to.y)+1e-3,"the game took it across: apex %v",apex)
        } else {
            testing.expectf(t,rising && apex>max(from.y,to.y)+0.3,"on its arc it rises %v to %v over ends at %v and %v",rising,apex,from.y,to.y)
        }
        core.destroy(&f.entities,e)
        nav_test_settle(&f)
    }
    bodyless_no_problems(t,&f)
}

@(private="file")
bodyless_no_problems :: proc(t:^testing.T,f:^Nav_Test,loc:=#caller_location) {
    for &problem in f.problems.entries[:f.problems.count] {
        testing.expectf(t,false,"%v: %s: %s",problem.entity,base.text_get(problem.code[:]),base.text_get(problem.text[:]),loc=loc)
    }
}
