package navigation

import "core:math/linalg"
import "mirai:core"
import scene "mirai:engine/scene"
import "mirai:std/ai"
import mm "mirai:std/math"
import locomotion "plugins:locomotion/runtime"
import phys "plugins:physics/runtime"

// What moves by itself where the players are not. An agent with somewhere to
// go (Waiting, Moving or Crossing) is scene.Roaming, so dropping its section
// hangs it from the root instead of leaving it dormant. Where only sections
// that are away are (Nav_Sections), or at the portal its way enters one by,
// it goes far: off (core.Disabled: no body, mesh nor animation), with a route
// through the coarse graph of its class (over the surface, or through the air
// or the water by its middle) that it goes at its speed every NAV_FAR_PERIOD,
// on the fixed tick, on the server. Once where it is is not away, it is put
// on the mesh there and goes on: it plans its way again, or it has arrived.
// What has nowhere to go is not Roaming, and a section that drops it leaves
// it dormant.

NAV_FAR_PERIOD :: f32(0.5) // s between steps of what is far
NAV_FAR_POINTS :: 32
NAV_FAR_SPEED :: f32(3)    // m/s of an agent without the speed of its mode
NAV_COARSE_NODES :: 4096   // portals of every section of a class, and two
NAV_COARSE_EDGES :: 256    // ways out of a portal a search over the coarse graph takes

@(component,description="An agent that goes on far from the players, off: the route it walks through the sections that are not loaded, and how fast. Navigation adds it and takes it away.")
Nav_Far :: struct {
    route:[NAV_FAR_POINTS][3]f32 `mirai:"hidden,unit=m"`,
    count:i32 `mirai:"hidden"`, // 0: the route is made again at the next step
    next:i32 `mirai:"hidden"`,
    speed:f32 `mirai:"readonly,unit=m/s"`,
    complete:bool `mirai:"readonly"`, // the route ends at the goal
    arrived:bool `mirai:"readonly"`,
    spare:f32 `mirai:"hidden,unit=s"`, // of the last step, after it got to the end of its route: the next route starts there
}

// Whether what is far takes its step in this tick: once every NAV_FAR_PERIOD
// of fixed ticks.
nav_far_step :: proc "contextless" (time:core.Time) -> bool {
    return time.dt>0 && time.tick%far_ticks(time)==0
}

// Whether the brains of the agents far decide in this tick: the one after
// their step, so they read where it took them. What they ask goes at the
// next step, which walks also the time the last one had left once the agent
// got to the end of its route (Nav_Far.spare): a decision costs no time of
// what is far.
nav_far_decide :: proc "contextless" (time:core.Time) -> bool {
    ticks:=far_ticks(time)
    return time.dt>0 && time.tick%ticks==1%ticks
}

@(private)
far_ticks :: #force_inline proc "contextless" (time:core.Time) -> u64 {return max(core.ticks_of(time,NAV_FAR_PERIOD),1)}

// The search over the coarse graph, made the first time.
@(private)
agents_coarse_ready :: proc(a:^Navigation_Agents) -> bool {
    if len(a.coarse.g)>0 {return true}
    return ai.search_init(&a.coarse,{nodes=NAV_COARSE_NODES,max_edges=NAV_COARSE_EDGES})
}

// How near the end of its corridor an agent counts as there.
@(private)
agent_reach :: proc "contextless" (agent:Nav_Agent,p:^Nav_Path) -> f32 {
    reach:=max(agent.reach,0.05)
    if p.target!=core.NONE {reach=max(reach,p.distance)}
    return reach
}

// Where an agent heads first when its way to the goal enters a section away:
// the point its route through the coarse graph of its class enters by. False
// when the way stays where the mesh or the volume is. One that flies or swims
// goes by its middle (far_lift).
@(private)
agent_via :: proc(n:^Navigation,a:^Navigation_Agents,s:^Nav_Sections,class:int,from,goal:mm.Vec3) -> (via:mm.Vec3,ok:bool) {
    if s.away_count==0 {return}
    c:=&n.classes[class]
    if len(c.coarse.portals)==0 || !agents_coarse_ready(a) {return}
    if !sections_away(s,goal) {
        // Between two places here, the way may still cross one away: only if the coarse graph says so.
        if sections_region(s,from)==sections_region(s,goal) {return}
    }
    count,status:=ai.nav_coarse_route(&c.coarse,&a.coarse,from,sections_region(s,from),goal,sections_region(s,goal),a.route[:])
    if status!=.Found && status!=.Output_Full {return}
    previous:=from
    for point in a.route[:count] {
        if sections_away(s,(previous+point)*0.5) {return previous,true}
        previous=point
    }
    return
}

// The route of a far agent from where it is to its goal: through the coarse
// graph of its class, over the surface or through the air or the water, or
// straight when the graph does not join them.
@(private)
far_route :: proc(n:^Navigation,a:^Navigation_Agents,s:^Nav_Sections,far:^Nav_Far,class:int,from,goal:mm.Vec3) {
    far.next,far.complete,far.arrived=0,true,false
    if class>=0 && class<n.count && agents_coarse_ready(a) {
        c:=&n.classes[class]
        count,status:=ai.nav_coarse_route(&c.coarse,&a.coarse,from,sections_region(s,from),goal,sections_region(s,goal),far.route[:])
        if (status==.Found || status==.Output_Full) && count>0 {
            far.count,far.complete=i32(count),status==.Found
            return
        }
    }
    far.route[0]=goal
    far.count=1
}

// Walks a far agent along its route for dt seconds; where it gets to. What
// is left of dt at the end of the route is its spare.
@(private)
far_walk :: proc "contextless" (far:^Nav_Far,position:mm.Vec3,dt:f32) -> mm.Vec3 {
    at:=position
    left:=far.speed*dt
    for left>0 && far.next<far.count {
        to:=far.route[far.next]
        d:=to-at
        length:=linalg.length(d)
        if length<=left {
            at=to
            left-=length
            far.next+=1
            continue
        }
        at+=d/length*left
        left=0
    }
    if far.next>=far.count {
        if far.complete {far.arrived=true} else {far.count=0}
        if far.speed>0 {far.spare=left/far.speed}
    }
    return at
}

// How high the middle of an agent of a class of a volume is over its feet,
// which its route and its goal are of; 0 on the surface. Its Collider may be
// off, with the agent far.
@(private)
far_lift :: proc "contextless" (n:^Navigation,colliders:^core.Table(phys.Collider,$A),e:core.Entity,class:i8,scale:[3]f32) -> mm.Vec3 {
    if class<0 || int(class)>=n.count || !class_in_volume(n,int(class)) || colliders==nil {return {}}
    collider:=cast(^phys.Collider)core.raw_find(core.raw(colliders),type_info_of(phys.Collider),e)
    if collider==nil {return {}}
    return {0,(collider.size.x+collider.size.y)*abs(scale.y),0}
}

// A request to an agent that is far changes where it goes; false when it is not far.
@(private)
far_request :: proc(paths:^core.Table(Nav_Path),fars:^core.Table(Nav_Far),asked:Nav_Request,worlds:^core.Table(core.World_Transform,$A)) -> bool {
    far:=cast(^Nav_Far)core.raw_edit(core.raw(fars),type_info_of(Nav_Far),asked.entity)
    p:=cast(^Nav_Path)core.raw_edit(core.raw(paths),type_info_of(Nav_Path),asked.entity)
    if far==nil || p==nil {return false}
    #partial switch asked.kind {
    case .Move_To:
        p.goal,p.target,p.state=asked.point,core.NONE,.Moving
        far.count,far.arrived=0,false
    case .Follow:
        p.target,p.distance,p.state=asked.target,max(asked.distance,0),.Moving
        if pose,ok:=core.get(worlds,asked.target);ok {p.goal=pose.position}
        far.count,far.arrived=0,false
    case .Stop:
        p.state=.Idle
        far.count,far.next,far.complete,far.arrived,far.spare=1,1,true,true,0
    case .Look_At:
        p.look,p.looking=asked.point,true
    case .Look_Along:
        p.looking=false
    }
    return true
}

// The part of navigation_agents for what is far, after the agents moved.
@(private)
agents_far :: proc(
    n:core.Ref(Navigation),builds:core.Ref(Navigation_Builds),a:^Navigation_Agents,agents:^core.Table(Nav_Agent,$A),paths:^core.Table(Nav_Path),
    fars:^core.Table(Nav_Far),roamings:^core.Table(scene.Roaming),disabled:^core.Table(core.Disabled),
    walks:^core.Table(locomotion.Walk,$B),flights:^core.Table(locomotion.Fly,$C),swims:^core.Table(locomotion.Swim,$D),colliders:^core.Table(phys.Collider,$E),worlds:^core.Table(core.World_Transform,$F),
    placer:core.Placer,bodies:^phys.Body_Requests,events:^Nav_Events,time:core.Time,
) {
    if n.ptr==nil || builds.ptr==nil || !n.ready || !time.playing || time.dt<=0 {return}
    s:=&builds.ptr.sections
    // Roaming follows whether an agent has somewhere to go; one that has, where only away sections are, goes far.
    for row in 0..<core.count(paths) {
        e:=core.entity_at(paths,row)
        p:=core.at(paths,row)
        moving:=p.state==.Waiting || p.state==.Moving || p.state==.Crossing
        if moving!=core.has(roamings,e) {
            if moving {core.add(roamings,e,scene.Roaming{})} else {core.remove(roamings,e)}
        }
        if !moving || p.state==.Crossing || s.away_count==0 {continue}
        pose,placed:=core.get(worlds,e)
        agent,is_agent:=core.get(agents,e)
        if !placed || !is_agent {continue}
        lift:=far_lift(n.ptr,colliders,e,p.class,pose.scale)
        center:=pose.position+lift
        to:=p.corridor.target-center
        reach:=max(agent_reach(agent,&p),0.5)
        // At the portal its corridor ends at: on the plane over the surface, in three axes in the air and the water.
        near:=linalg.length(to)<=reach if lift!={} else linalg.length(mm.Vec2{to.x,to.z})<=reach
        at_portal:=p.through && p.state==.Moving && near
        if !at_portal && !sections_away(s,center) {continue}
        far:Nav_Far
        far.speed=NAV_FAR_SPEED
        space:=n.classes[p.class].class.space if p.class>=0 && int(p.class)<n.count else Nav_Space.Surface
        switch space {
        case .Surface: if walk,ok:=core.get(walks,e);ok && walk.max_speed>0 {far.speed=walk.max_speed}
        case .Air:     if fly,ok:=core.get(flights,e);ok && fly.speed>0 {far.speed=fly.speed}
        case .Water:   if swim,ok:=core.get(swims,e);ok && swim.speed>0 {far.speed=swim.speed}
        }
        if !agents_coarse_ready(a) {continue}
        far_route(n.ptr,a,s,&far,int(p.class),center,p.goal)
        core.add(fars,e,far)
        core.add(disabled,e,core.Disabled{})
        written:=core.edit(paths,e)
        written.through,written.velocity=false,{}
    }
    // What is far steps every NAV_FAR_PERIOD, and looks at once when a section comes or goes.
    ticks:=far_ticks(time)
    step:=nav_far_step(time)
    changed:=s.hash!=a.far_sections
    a.far_sections=s.hash
    if !step && !changed {return}
    for row:=0;row<len(fars.entities);row+=1 {
        e:=fars.entities[row]
        far:=cast(^Nav_Far)core.raw_edit(core.raw(fars),type_info_of(Nav_Far),e)
        p:=cast(^Nav_Path)core.raw_edit(core.raw(paths),type_info_of(Nav_Path),e)
        pose,placed:=core.get(worlds,e)
        if far==nil || p==nil || !placed {continue}
        // The route of one that flies or swims is of its middle.
        lift:=far_lift(n.ptr,colliders,e,p.class,pose.scale)
        position:=pose.position+lift
        // Turned on by something else: it is where the players are.
        if row<fars.on {
            far_wake(n.ptr,p,far,e,position,lift,pose.rotation,placer,bodies,fars,disabled,events)
            continue
        }
        if step && p.state!=.Idle && !far.arrived {
            if p.target!=core.NONE {
                // A target that moved away from where the route goes takes it again.
                if to,ok:=core.get(worlds,p.target);ok {
                    end:=far.route[max(far.count-1,0)]
                    if far.count==0 || linalg.length(to.position-end)>max(p.distance,2) {p.goal,far.count=to.position,0}
                } else {p.target=core.NONE}
            }
            if far.count==0 {far_route(n.ptr,a,s,far,int(p.class),position,p.goal)}
            spent:=f32(ticks)*time.dt+far.spare
            far.spare=0
            position=far_walk(far,position,spent)
            if far.arrived {p.state=.Arrived}
            core.place(placer,e,position-lift,pose.rotation,false)
        } else if step {
            // Nothing asked after it got there: the time it had left is gone.
            far.spare=0
        }
        // Out where it is not away, and not heading back into a section away.
        if sections_away(s,position) {continue}
        if !far.arrived && far.next<far.count && sections_away(s,(position+far.route[far.next])*0.5) {continue}
        far_wake(n.ptr,p,far,e,position,lift,pose.rotation,placer,bodies,fars,disabled,events)
    }
}

// A far agent where the players are again: on the mesh there, or in the free
// space of its volume, on, and still: its body comes back without the
// velocity it had when it went far. It waits while the mesh or the volume
// there is still building. position is of its middle, lift over its feet.
@(private)
far_wake :: proc(n:^Navigation,p:^Nav_Path,far:^Nav_Far,e:core.Entity,position,lift:mm.Vec3,rotation:mm.Quat,placer:core.Placer,bodies:^phys.Body_Requests,fars:^core.Table(Nav_Far),disabled:^core.Table(core.Disabled),events:^Nav_Events) {
    at:=position
    if p.class>=0 && int(p.class)<n.count {
        c:=&n.classes[p.class]
        extents:=mm.Vec3{c.class.radius*2+0.5,c.class.height,c.class.radius*2+0.5}
        found:bool
        nearest:mm.Vec3
        if class_in_volume(n,int(p.class)) {
            _,nearest,found=ai.nav_volume_find_nearest(&c.volume,position,extents*4)
        } else {
            filter:=filter_make(&n.settings,{},{})
            _,nearest,found=ai.nav_find_nearest(&c.mesh,position,extents*4,&filter)
        }
        if found {at=nearest} else if c.pending>0 {return}
    }
    core.place(placer,e,at-lift,rotation,true)
    phys.set_velocity(bodies,e,{})
    core.remove(fars,e)
    core.remove(disabled,e)
    p.corridor,p.velocity,p.through,p.partial,p.manual={},{},false,false,false
    switch {
    case p.state==.Idle:
    case far.arrived:
        p.state=.Arrived
        core.push(&events.queue,Nav_Event{kind=.Arrived,entity=e})
    case:
        p.state=.Waiting
        p.replans+=1
    }
}
