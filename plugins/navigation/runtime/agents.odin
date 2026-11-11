package navigation

import "core:math"
import "core:math/linalg"
import "mirai:core"
import input "mirai:engine/input"
import scene "mirai:engine/scene"
import volume "mirai:engine/volume"
import "mirai:std/ai"
import "mirai:std/base"
import mm "mirai:std/math"
import "mirai:std/spatial"
import locomotion "plugins:locomotion/runtime"
import phys "plugins:physics/runtime"

// Agents: characters that walk where they are asked. Each tick an agent
// moves the start of its corridor to where it stands, heads for the next
// corner, steps aside from the agents around it and writes the Move_Input
// of its body, which its locomotion turns into steps. At the start of a link
// it crosses it: Jump and Drop by a ballistic launch that lands on its end,
// Climb and Ladder along it; Door and the kinds of a game, and every kind an
// agent leaves to the game, wait for nav_crossing_done. Paths are searched
// in slices, within Navigation_Settings.path_iterations for all agents a tick;
// several that follow one target share one search toward it (Follow_Tree).
// An agent with a Fly takes a class of the air: it flies, heading for the
// farthest portal of its corridor in sight, and steps aside in three axes.
// One with a Swim takes a class of the water while it swims, and moves
// through it the same way. With a Walk too, one that flies or swims walks on
// the surface while the physics has it walk, and its class changes with the
// mode: its path is one search over the mesh and the volume of the other
// space (ai.Nav_Medium_Query), through the shores of the water (LINK_SWIM) or
// the take-offs of the air (LINK_FLY); it follows it up to where it crosses,
// crosses, and plans the rest from the other side. A way that enters a
// section away (Nav_Sections) ends, on the mesh or in the volume, at the
// portal it enters by, where the agent goes far.

// The engine crosses links in it: navigation writes the Character_Move.
@(name_requires="Nav_Agent")
MODE_NAV_LINK :: locomotion.Locomotion_Mode(8)

NAV_AGENT_HORIZON :: f32(1.5)  // s ahead that agents avoid each other
NAV_AGENT_WALL_HORIZON :: f32(0.5) // s ahead that an agent that steps aside keeps from the edges of its mesh
NAV_AGENT_CELL :: f32(2)       // m across a cell of the neighbor grid
NAV_AGENT_REACH :: 32          // cells, at most, from an agent to the neighbors it gathers
NAV_REPLAN_FOLLOW :: f32(0.5)  // s between plans while following a target that moves
NAV_FOLLOW_TREES :: 4          // targets whose followers share a search at once
NAV_FOLLOW_IDLE :: f32(2)      // s without a follower asking before the search toward a target is let go
NAV_OFF_LEVEL :: f32(0.5)      // m beyond its climb that an agent may be above or below its corridor
NAV_CROSS_SLACK :: f32(1.0)    // s a crossing may outlast its arc before it counts as failed
NAV_FLY_AHEAD :: 6             // portals of its corridor a flying agent looks for ahead
NAV_SHORE_MARGIN :: f32(16)    // m around its way where an agent that swims looks for shores
NAV_SHORE_SPACING :: f32(2)    // m between the links of a shore

@(component,description="A Character that walks, flies with a Fly or swims with a Swim where navigation is asked to take it, with its class chosen from the size of its capsule.")
Nav_Agent :: struct {
    drop:f32 `mirai:"min=0,unit=m"`, // it may fall this far; 0: as its class
    abilities:Nav_Abilities,
    avoid:Nav_Areas,                 // areas it never walks
    reach:f32 `mirai:"min=0,unit=m"`, // how near the end counts as there
    avoidance:bool,                  // steps aside from the other agents
    manual:Nav_Link_Kinds,           // kinds of links the game crosses for it
    seated:bool,                     // walks where it is asked also while a seat drives it: click to move
}
NAV_AGENT_DEFAULT :: Nav_Agent{reach=0.3,avoidance=true}

Nav_State :: enum u8 {
    Idle,
    Waiting,  // for its path
    Moving,
    Crossing, // a link
    Arrived,  // at its end, or as near as it can (Nav_Path.partial)
    Failed,   // no way: see the problems of the entity
}

// What an agent is doing. Navigation adds it to every Nav_Agent and is its
// only writer; the game reads it.
@(component,description="Where the agent goes and how: its state, its corridor of polygons and the link it crosses.")
Nav_Path :: struct {
    state:Nav_State `mirai:"readonly"`,
    goal:[3]f32 `mirai:"readonly,unit=m"`,
    target:core.Entity `mirai:"readonly"`,   // followed; none: the goal
    distance:f32 `mirai:"readonly,unit=m"`,  // kept from the target
    look:[3]f32 `mirai:"readonly,unit=m"`,   // where it faces while it moves, when looking
    looking:bool `mirai:"readonly"`,
    partial:bool `mirai:"readonly,transient"`, // the path ends as near the goal as the mesh goes
    class:i8 `mirai:"readonly,transient"`,
    kind:Nav_Link_Kind `mirai:"readonly,transient"`, // of the link it crosses
    manual:bool `mirai:"readonly,transient"`,       // the game crosses it
    corridor:ai.Nav_Corridor `mirai:"transient,hidden"`,
    link:ai.Nav_Ref `mirai:"transient,hidden"`,
    from,to:[3]f32 `mirai:"transient,hidden"`, // of the link it crosses
    time:f32 `mirai:"transient,hidden,unit=s"`,  // in the crossing; since the last plan while following
    velocity:[3]f32 `mirai:"transient,hidden,unit=m/s"`, // wanted, before avoiding the others
    replans:u32 `mirai:"readonly,transient"`,
    halted:bool `mirai:"transient,hidden"`, // its Move_Input was stopped when it stopped moving
    partner:i8 `mirai:"readonly,transient"`, // the class of the other space it crosses into; -1: none
    medium:bool `mirai:"transient,hidden"`,  // its corridor ends where it crosses into the other space, from `from` to `to`
    through:bool `mirai:"transient,hidden"`, // its corridor ends at the portal into a section away: there it goes far
    queued:bool `mirai:"transient,hidden"`, // among those that wait for a search
}
NAV_PATH_DEFAULT :: Nav_Path{class=-1,partner=-1}

Nav_Request_Kind :: enum u8 {Move_To,Follow,Stop,Look_At,Look_Along,Crossing_Done}

Nav_Request :: struct {
    kind:Nav_Request_Kind,
    entity:core.Entity,
    target:core.Entity,
    point:[3]f32,
    distance:f32,
}

@(storage,queue)
Nav_Requests :: struct {
    using queue:core.Queue(Nav_Request),
}

// Walks the agent to a point.
nav_move_to :: proc(r:^Nav_Requests,e:core.Entity,point:[3]f32) {core.push(&r.queue,Nav_Request{kind=.Move_To,entity=e,point=point})}
// Walks the agent after an entity, keeping that far from it.
nav_follow :: proc(r:^Nav_Requests,e,target:core.Entity,distance:f32=1) {core.push(&r.queue,Nav_Request{kind=.Follow,entity=e,target=target,distance=distance})}
nav_stop :: proc(r:^Nav_Requests,e:core.Entity) {core.push(&r.queue,Nav_Request{kind=.Stop,entity=e})}
// Faces a point while it walks (a shooter that strafes); nav_look_along faces the way again.
nav_look_at :: proc(r:^Nav_Requests,e:core.Entity,point:[3]f32) {core.push(&r.queue,Nav_Request{kind=.Look_At,entity=e,point=point})}
nav_look_along :: proc(r:^Nav_Requests,e:core.Entity) {core.push(&r.queue,Nav_Request{kind=.Look_Along,entity=e})}
// The game crossed the link the agent waits at: it goes on from its end.
nav_crossing_done :: proc(r:^Nav_Requests,e:core.Entity) {core.push(&r.queue,Nav_Request{kind=.Crossing_Done,entity=e})}

Nav_Event_Kind :: enum u8 {
    Arrived,
    Failed,
    Crossing, // starts a link; the game crosses it when Nav_Event.manual
    Crossed,
}

Nav_Event :: struct {
    kind:Nav_Event_Kind,
    entity:core.Entity,
    link:Nav_Link_Kind,
    manual:bool,
    from,to:[3]f32,
}

@(storage)
Nav_Events :: struct {
    using queue:core.Events(Nav_Event),
}

// How many agents cross a link: navigation_agents counts them and
// navigation_crossing looks at the paths only while there are some.
@(storage)
Nav_Crossings :: struct {
    count:u32,
}

// What the application keeps to move the agents of a world: the search under
// way and the order of those that wait, and the scratch of the neighbors.
@(storage,host,by_world,free="agents_free")
Navigation_Agents :: struct {
    query:ai.Nav_Query,
    volume_query:ai.Nav_Volume_Query,
    medium_query:ai.Nav_Medium_Query,
    space_links:[dynamic]ai.Nav_Space_Link,
    searching:core.Entity, // the agent whose path a query searches
    searching_air:bool,    // in the volume query
    searching_medium:bool, // in the query over a mesh and a volume, for its agent of searching_class
    searching_class:i8,
    searching_tree:u8,     // index+1 of the search toward a target it reads its path from; 0: its own
    trees:[NAV_FOLLOW_TREES]Follow_Tree,
    uid:u64,               // of the Navigation the search is in
    made:u32,              // and which of its meshes
    coarse:ai.Search,      // over the portals of a coarse graph
    route:[NAV_FAR_POINTS]mm.Vec3,
    far_sections:u64,      // the sections the far simulation last looked at
    waiting:[dynamic]core.Entity, // from head on, in order of arrival
    head:int,
    shapes:[2]core.Shape,  // of the agents and the paths when the agents last got their Nav_Path
    refs:[dynamic]ai.Nav_Ref,
    grid:spatial.Grid,     // the agents and obstacles of the tick (near) by where they stand on the ground
    neighbors:[dynamic]ai.Avoid_Agent(2),
    neighbors_air:[dynamic]ai.Avoid_Agent(3),
    near:[dynamic]Near,
}

// The search toward a target that its followers share: those of one class
// that walk and cross the same. The first follower searches its own way and
// only leaves its mark; a second one begins the search, from where the target
// is on the mesh, and from then each follower expands it as far as its own
// polygon and reads its path. It begins again when the target moved on, at
// most every NAV_REPLAN_FOLLOW, or the mesh changed.
@(private)
Follow_Tree :: struct {
    query:ai.Nav_Query,
    target:core.Entity, // none: free
    class:i8,
    first:core.Entity,  // the only one that asked so far
    built:bool,
    filter:ai.Nav_Filter,
    goal:mm.Vec3,       // where the target was when the search began
    end:mm.Vec3,        // on the mesh
    end_ref:ai.Nav_Ref,
    revision:u64,       // of the mesh then
    age,idle:f32,       // s since the search began, and since a follower last asked
}

@(private)
Near :: struct {
    entity:core.Entity,
    position,velocity:mm.Vec3,
    radius,height:f32,
    avoids,flies:bool,
    excluded:Nav_Areas, // the areas an agent that walks keeps out of
}

agents_free :: proc(a:^Navigation_Agents) {
    ai.nav_query_destroy(&a.query)
    ai.nav_volume_query_destroy(&a.volume_query)
    ai.nav_medium_query_destroy(&a.medium_query)
    for &tree in a.trees {ai.nav_query_destroy(&tree.query)}
    ai.search_destroy(&a.coarse)
    delete(a.space_links)
    delete(a.waiting);delete(a.refs);spatial.grid_destroy(&a.grid);delete(a.neighbors);delete(a.neighbors_air);delete(a.near)
    a^={}
}

// The class of a character in a space: the smallest by radius, then height,
// whose size holds its capsule; on the surface, one which does not step
// higher or walk steeper than it. -1: none.
class_of :: proc "contextless" (n:^Navigation,character:phys.Character,collider:phys.Collider,scale:[3]f32,space:Nav_Space) -> (class:int,radius,height:f32) {
    radius=collider.size.x*max(abs(scale.x),abs(scale.z))
    height=2*(collider.size.x+collider.size.y)*abs(scale.y)
    class=-1
    for i in 0..<n.count {
        c:=n.classes[i].class
        if c.space!=space || c.radius+1e-4<radius || c.height+1e-4<height {continue}
        if space==.Surface && (c.climb>character.step_height+1e-4 || c.max_slope>character.max_slope+1e-4) {continue}
        if class<0 || c.radius<n.classes[class].class.radius || c.radius==n.classes[class].class.radius && c.height<n.classes[class].class.height {class=i}
    }
    return
}

// What an agent can cross: its jump from its Walk (how high, and how far in
// the time in the air at its speed), its drop and abilities from Nav_Agent.
agent_can :: proc "contextless" (n:^Navigation,class:int,agent:Nav_Agent,walk:Walk_Like,gravity:f32) -> ai.Nav_Need {
    c:=n.classes[class].class
    can:=ai.Nav_Need{down=agent.drop if agent.drop>0 else c.drop,abilities=u32(agent.abilities)}
    if walk.jump_height>0 && gravity>0 {
        can.up=walk.jump_height
        can.across=walk.max_speed*2*math.sqrt(2*walk.jump_height/gravity)
    }
    return can
}
Walk_Like :: struct {jump_height,max_speed:f32}

// The areas an agent never walks: its own, and the deep ground under the water when it cannot swim.
agent_avoids :: proc "contextless" (agent:Nav_Agent,swims:bool) -> Nav_Areas {
    return agent.avoid if swims else agent.avoid|Nav_Areas(1<<u64(AREA_WATER))
}

// What an agent of a class walks and crosses, as navigation moves it; swims: it has a Swim.
agent_filter :: proc "contextless" (n:^Navigation,class:int,agent:Nav_Agent,walk:Walk_Like,swims:bool,gravity:f32) -> ai.Nav_Filter {
    return filter_make(&n.settings,agent_avoids(agent,swims),agent_can(n,class,agent,walk,gravity))
}

@(step="fixed",stage="apply",server)
navigation_agents :: proc(
    n:core.Ref(Navigation),a:^Navigation_Agents,agents:^core.Table(Nav_Agent,.Read),paths:^core.Table(Nav_Path),
    requests:^Nav_Requests,events:^Nav_Events,inputs:^core.Table(input.Move_Input),seats:^core.Table(input.Seat,.Read),
    characters:^core.Table(phys.Character,.Read),loco_states:^core.Table(locomotion.Locomotion_State,.Read),colliders:^core.Table(phys.Collider,.Read),walks:^core.Table(locomotion.Walk,.Read),flights:^core.Table(locomotion.Fly,.Read),swims:^core.Table(locomotion.Swim,.Read),
    grounds:^core.Table(phys.Character_State,.Read),motions:^core.Table(core.Motion,.Read),worlds:^core.Table(core.World_Transform,.Read),
    obstacles:^core.Table(Nav_Obstacle,.Read),volumes:^core.Table(volume.Volume,.Read),loco:^locomotion.Locomotion_Requests,physics:core.Ref(phys.Physics_State),builds:core.Ref(Navigation_Builds),fars:^core.Table(Nav_Far),
    roamings:^core.Table(scene.Roaming),disabled:^core.Table(core.Disabled),placer:core.Placer,bodies:^phys.Body_Requests,crossings:^Nav_Crossings,time:core.Time,problems:^core.Problems,
) {
    if core.reshaped(agents,&a.shapes[0]) | core.reshaped(paths,&a.shapes[1]) {
        for row in 0..<core.count(agents) {
            e:=core.entity_at(agents,row)
            if !core.has(paths,e) {core.add(paths,e,NAV_PATH_DEFAULT)}
        }
    }
    for asked in core.take(&requests.queue) {
        p:=core.staged(paths,asked.entity)
        if p==nil && far_request(paths,fars,asked,worlds) {continue}
        if p==nil {
            core.report(problems,asked.entity,"navigation.request","Navigation was asked to move an entity without a Nav_Agent: give it one (and a Character)")
            continue
        }
        switch asked.kind {
        case .Move_To:
            agent_stop_crossing(p,asked.entity,loco)
            p.goal,p.target,p.state=asked.point,core.NONE,.Waiting
        case .Follow:
            agent_stop_crossing(p,asked.entity,loco)
            p.target,p.distance,p.state=asked.target,max(asked.distance,0),.Waiting
            if pose,ok:=core.get(worlds,asked.target);ok {p.goal=pose.position}
        case .Stop:
            agent_stop_crossing(p,asked.entity,loco)
            p.state=.Idle
            p.velocity={}
            if mi:=core.edit(inputs,asked.entity);mi!=nil {mi.move,mi.velocity={},false}
        case .Look_At:
            p.look,p.looking=asked.point,true
        case .Look_Along:
            p.looking=false
        case .Crossing_Done:
            if p.state==.Crossing && p.manual {agent_crossed(n.ptr,p,asked.entity,events,loco)}
        }
    }
    if !n.ready || n.count==0 || !time.playing || time.dt<=0 {return}
    // Without an agent, near or far, nothing searches, steps aside or steers: no memory for it and no look at the characters.
    if len(paths.entities)==0 {return}
    budget:=int(n.settings.path_iterations) if n.settings.path_iterations>0 else 2048
    if a.uid!=n.uid || a.made!=n.made {
        // Another copy of the world, or its meshes made anew: the search under way was in the others.
        a.uid,a.made=n.uid,n.made
        a.searching,a.searching_tree=core.NONE,0
        for &tree in a.trees {tree.target,tree.built=core.NONE,false}
        clear(&a.waiting)
        a.head=0
        for row in 0..<core.count(paths) {
            if paths.values[row].queued {core.edit_at(paths,row).queued=false}
        }
    }
    if len(a.query.points)==0 && !ai.nav_query_init(&a.query,8192) {
        core.report(problems,core.NONE,"navigation.memory","No memory to search paths")
        return
    }
    if len(a.volume_query.points)==0 && !ai.nav_volume_query_init(&a.volume_query,1<<15) {
        core.report(problems,core.NONE,"navigation.memory","No memory to search paths through volumes")
        return
    }
    if !agents_coarse_ready(a) {
        core.report(problems,core.NONE,"navigation.memory","No memory to search ways through the coarse graph")
        return
    }
    if len(a.refs)==0 && resize(&a.refs,4096)!=nil || len(a.space_links)==0 && resize(&a.space_links,ai.NAV_QUERY_SPACE_LINKS)!=nil {
        core.report(problems,core.NONE,"navigation.memory","No memory to search paths")
        return
    }
    clear(&a.near)
    walking:=core.join(paths,agents)
    for e,_,agent in core.each_joined(&walking) {
        p:=core.edit_at(paths,walking.row)
        character,has_character:=core.get(characters,e)
        collider,has_collider:=core.get(colliders,e)
        pose,placed:=core.get(worlds,e)
        if !has_character || !has_collider || collider.kind!=.Capsule || !placed {
            core.report(problems,e,"navigation.agent_character","A Nav_Agent needs a Character with a capsule Collider: give it one")
            continue
        }
        fly,can_fly:=core.get(flights,e)
        swim,can_swim:=core.get(swims,e)
        walker:=core.has(walks,e)
        // One that only flies or swims is always in the air or the water; one that also walks, while the physics has it fly or swim.
        moving,_:=core.get(loco_states,e)
        flies:=can_fly && (!walker || moving.mode==locomotion.MODE_FLYING)
        swims:=!flies && can_swim && (!walker || moving.mode==locomotion.MODE_SWIMMING)
        space:=Nav_Space.Air if flies else (.Water if swims else .Surface)
        class,radius,height:=class_of(n.ptr,character,collider,pose.scale,space)
        // The other space it may cross into: the surface for one that walks, or the water or the air from it.
        partner:=-1
        switch {
        case flies || swims: if walker {partner,_,_=class_of(n.ptr,character,collider,pose.scale,.Surface)}
        case can_swim: partner,_,_=class_of(n.ptr,character,collider,pose.scale,.Water)
        case can_fly: partner,_,_=class_of(n.ptr,character,collider,pose.scale,.Air)
        }
        p.partner=i8(partner)
        if class<0 {
            if flies || swims {
                core.report(problems,e,"navigation.agent_class","No class of the %s in Navigation_Settings holds this agent, which %s: add one with space %v, a radius of at least %.2f m and a height of at least %.2f m","air" if flies else "water","flies" if flies else "swims",space,radius,height)
            } else {
                core.report(problems,e,"navigation.agent_class","No class of Navigation_Settings holds this agent: add one with a radius of at least %.2f m and a height of at least %.2f m that climbs no higher than its step_height and walks no steeper than its max_slope",radius,height)
            }
            if p.state!=.Idle && p.state!=.Failed {agent_fail(p,e,events)}
            continue
        }
        if int(p.class)!=class {
            p.class=i8(class)
            switch {
            case p.state==.Moving: p.state=.Waiting
            // In the other space: it plans on from there; a take-off, once where it leads.
            case p.state==.Crossing && p.medium && !(p.kind==LINK_FLY && flies):
                core.push(&events.queue,Nav_Event{kind=.Crossed,entity=e,link=p.kind,from=p.from,to=p.to})
                p.medium,p.state=false,.Waiting
            }
        }
        motion,_:=core.get(motions,e)
        // A flier plans and steps aside by the center of its capsule; its feet are the origin of its entity.
        center:=pose.position+{0,height*0.5,0}
        append(&a.near,Near{entity=e,position=center,velocity=motion.linear,radius=radius,height=height,avoids=agent.avoidance,flies=flies || swims,excluded=agent_avoids(agent,can_swim)})
        if p.target!=core.NONE && p.state==.Failed {
            // A follower tries again: its target may come where it can go.
            p.time+=time.dt
            if p.time>=NAV_REPLAN_FOLLOW*4 {p.time,p.state=0,.Waiting}
        }
        if p.target!=core.NONE && (p.state==.Moving || p.state==.Arrived) {
            p.time+=time.dt
            if to,ok:=core.get(worlds,p.target);ok {
                if p.time>=NAV_REPLAN_FOLLOW && linalg.length(to.position-p.goal)>max(p.distance*0.5,0.5) {p.goal=to.position;p.state=.Waiting}
            } else {p.state=.Idle}
        }
        switch p.state {
        case .Idle,.Arrived,.Failed:
            p.velocity={}
        case .Waiting:
            p.velocity={}
            if a.searching!=e && !p.queued {append(&a.waiting,e);p.queued=true}
        case .Moving:
            if flies {
                agent_fly(p,e,agent,center,&n.classes[class].volume,fly.speed,fly.acceleration,true,moving.mode,events,loco)
            } else if swims {
                agent_fly(p,e,agent,center,&n.classes[class].volume,swim.speed,swim.acceleration,false,moving.mode,events,loco)
            } else {
                walk_row,_:=core.get(walks,e)
                walk:=Walk_Like{walk_row.jump_height,walk_row.max_speed}
                // Each agent jumps under the gravity of its place: a planet, a room without it.
                filter:=agent_filter(n.ptr,class,agent,walk,can_swim,linalg.length(phys.gravity_of_entity(physics,e)))
                agent_follow(n.ptr,p,e,agent,pose.position,&n.classes[class].mesh,&filter,walk,events,loco)
            }
        case .Crossing:
            p.velocity={}
            if p.medium {
                p.time+=time.dt
                speed:=swim.speed if swims else (fly.speed if flies else 0)
                if !flies && !swims {walk_row,_:=core.get(walks,e);speed=walk_row.max_speed}
                here:=center if flies || swims else pose.position
                // Up in the air where the take-off leads, clear of the ground, it plans the rest.
                if p.kind==LINK_FLY && flies && linalg.length(p.to-here)<=max(agent_reach(agent,p),0.5) {
                    core.push(&events.queue,Nav_Event{kind=.Crossed,entity=e,link=p.kind,from=p.from,to=p.to})
                    p.medium,p.state,p.velocity=false,.Waiting,{}
                } else {
                    agent_medium_crossing(p,here,speed if speed>0 else 3,!flies && !swims)
                }
            } else if !p.manual {
                p.time+=time.dt
                ground,_:=core.get(grounds,e)
                agent_crossing(n.ptr,p,e,pose.position,ground,linalg.length(phys.gravity_of_entity(physics,e)),events,loco)
            }
        }
    }
    // What agents step aside from without stepping aside themselves: the other characters and the obstacles.
    for row in 0..<core.count(characters) {
        e:=core.entity_at(characters,row)
        if core.has(agents,e) {continue}
        pose,placed:=core.get(worlds,e)
        collider,has:=core.get(colliders,e)
        if !placed || !has {continue}
        motion,_:=core.get(motions,e)
        height:=2*(collider.size.x+collider.size.y)*abs(pose.scale.y)
        append(&a.near,Near{entity=e,position=pose.position+{0,height*0.5,0},velocity=motion.linear,radius=collider.size.x*max(abs(pose.scale.x),abs(pose.scale.z)),height=height})
    }
    placed:=core.join(obstacles,worlds)
    for e,_,pose in core.each_joined(&placed) {
        box,_:=volume_prism(volumes,e,pose.transform,0) or_continue
        half:=(box.max-box.min)*0.5
        motion,_:=core.get(motions,e)
        append(&a.near,Near{entity=e,position=pose.position,velocity=motion.linear,radius=linalg.length(mm.Vec2{half.x,half.z}),height=half.y*2})
    }
    sections:=&builds.ptr.sections if builds.ptr!=nil else nil
    agents_search(n.ptr,a,builds.ptr,paths,agents,characters,grounds,colliders,walks,swims,worlds,physics,sections,budget,time.dt,events,problems)
    agents_avoid(n.ptr,a,paths,time.dt,problems)
    crossings.count=agents_steer(n.ptr,agents,paths,inputs,seats,grounds,worlds)
    agents_far(n,builds,a,agents,paths,fars,roamings,disabled,walks,flights,swims,colliders,worlds,placer,bodies,events,time)
}

@(private)
agent_stop_crossing :: proc(p:^Nav_Path,e:core.Entity,loco:^locomotion.Locomotion_Requests) {
    if p.state==.Crossing && !p.manual {locomotion.set_mode(loco,e,locomotion.MODE_FALLING)}
    p.partial,p.manual=false,false
}

// Heads for the next corner, starting a link when it is at its start.
@(private)
agent_follow :: proc(n:^Navigation,p:^Nav_Path,e:core.Entity,agent:Nav_Agent,position:mm.Vec3,mesh:^ai.Nav_Mesh,filter:^ai.Nav_Filter,walk:Walk_Like,events:^Nav_Events,loco:^locomotion.Locomotion_Requests) {
    // One that left the level of its corridor (pushed off a ledge, fallen) plans from where it is.
    if !ai.nav_corridor_valid(&p.corridor,mesh,filter,8) || !ai.nav_corridor_move(&p.corridor,mesh,filter,position) || abs(position.y-p.corridor.position.y)>n.classes[p.class].class.climb+NAV_OFF_LEVEL {
        p.state=.Waiting
        p.replans+=1
        return
    }
    corners:[4]ai.Nav_Corner
    count:=ai.nav_corridor_corners(&p.corridor,mesh,corners[:],0.05)
    if count==0 {p.state=.Waiting;p.replans+=1;return}
    next:=corners[0]
    flat:=mm.Vec3{next.position.x-position.x,0,next.position.z-position.z}
    distance:=linalg.length(flat)
    reach:=agent_reach(agent,p)
    if .End in next.flags && distance<=reach {
        p.velocity={}
        // At the portal into a section away: it goes far from here (agents_far).
        if p.through {return}
        if p.medium {agent_medium_begin(p,e,false,events,loco);return}
        p.state=.Arrived
        core.push(&events.queue,Nav_Event{kind=.Arrived,entity=e})
        return
    }
    if .Link in next.flags && distance<=max(reach,0.25) {
        link:=ai.nav_link_of(mesh,next.ref)
        if link==nil {p.state=.Waiting;p.replans+=1;return}
        from,to,_,_:=ai.nav_link_ends(link,next.ref)
        kind:=Nav_Link_Kind(link.desc.kind)
        p.state,p.link,p.from,p.to,p.kind,p.time,p.velocity=.Crossing,next.ref,from,to,kind,0,{}
        p.manual=u32(agent.manual)&(1<<u32(kind))!=0 || kind!=LINK_JUMP && kind!=LINK_DROP && kind!=LINK_CLIMB && kind!=LINK_LADDER
        if !p.manual {locomotion.set_mode(loco,e,MODE_NAV_LINK)}
        core.push(&events.queue,Nav_Event{kind=.Crossing,entity=e,link=kind,manual=p.manual,from=from,to=to})
        return
    }
    speed:=walk.max_speed if walk.max_speed>0 else 3
    if .End in next.flags && distance<1 {speed*=max(distance,0.2)}
    p.velocity=flat/max(distance,1e-4)*speed
}

// Heads for the farthest portal of its corridor in sight, flying, or
// swimming, whose mode the physics decides by the depth of the water.
@(private)
agent_fly :: proc(p:^Nav_Path,e:core.Entity,agent:Nav_Agent,position:mm.Vec3,volume:^ai.Nav_Volume,speed,acceleration:f32,flies:bool,mode:locomotion.Locomotion_Mode,events:^Nav_Events,loco:^locomotion.Locomotion_Requests) {
    if flies && mode!=locomotion.MODE_FLYING {locomotion.set_mode(loco,e,locomotion.MODE_FLYING)}
    next,end,ok:=ai.nav_volume_corridor_steer(&p.corridor,volume,position,NAV_FLY_AHEAD)
    if !ok {p.state=.Waiting;p.replans+=1;return}
    to:=next-position
    distance:=linalg.length(to)
    reach:=agent_reach(agent,p)
    if end && distance<=reach {
        p.velocity={}
        // At the portal into a section away: it goes far from here (agents_far).
        if p.through {return}
        if p.medium {agent_medium_begin(p,e,true,events,loco);return}
        p.state=.Arrived
        core.push(&events.queue,Nav_Event{kind=.Arrived,entity=e})
        return
    }
    top:=speed if speed>0 else 3
    // Toward the end, no faster than it can brake: in the air nothing else stops it.
    if end && acceleration>0 {top=min(top,max(math.sqrt(2*acceleration*0.5*distance),0.2))}
    p.velocity=to/max(distance,1e-4)*top
}

// At the end of its corridor, where it crosses into the other space: a
// take-off asks the physics to fly, a landing to fall; into or out of the
// water, it goes on and the physics swims or walks by the depth.
@(private)
agent_medium_begin :: proc(p:^Nav_Path,e:core.Entity,in_volume:bool,events:^Nav_Events,loco:^locomotion.Locomotion_Requests) {
    p.state,p.time,p.manual=.Crossing,0,false
    if p.kind==LINK_FLY {locomotion.set_mode(loco,e,locomotion.MODE_FALLING if in_volume else locomotion.MODE_FLYING)}
    core.push(&events.queue,Nav_Event{kind=.Crossing,entity=e,link=p.kind,from=p.from,to=p.to})
}

// Heads for the other end of a crossing into the other space, until its
// class changes with the mode the physics gives it; past the time it takes,
// it plans again from where it is. One that walks heads for it over the ground.
@(private)
agent_medium_crossing :: proc(p:^Nav_Path,position:mm.Vec3,speed:f32,walks:bool) {
    to:=p.to-position
    if walks {to.y=0}
    distance:=linalg.length(to)
    if p.time>linalg.length(p.to-p.from)/max(speed*0.25,0.25)+NAV_CROSS_SLACK*2 {
        p.medium,p.state=false,.Waiting
        p.replans+=1
        return
    }
    if distance>0.05 {p.velocity=to/distance*speed}
}

// Ends a crossing of the engine once the body lands at the end of the link,
// or gives it up when it lasts beyond its arc.
@(private)
agent_crossing :: proc(n:^Navigation,p:^Nav_Path,e:core.Entity,position:mm.Vec3,ground:phys.Character_State,gravity:f32,events:^Nav_Events,loco:^locomotion.Locomotion_Requests) {
    near:=linalg.length(mm.Vec3{p.to.x-position.x,0,p.to.z-position.z})
    switch p.kind {
    case LINK_JUMP,LINK_DROP:
        landed:=ground.standing && p.time>0.15 && abs(position.y-p.to.y)<0.75
        if landed && near<1.5 {agent_crossed(n,p,e,events,loco);return}
        _,_,total:=jump_launch(p.from,p.to,p.kind,gravity)
        if p.time>total+NAV_CROSS_SLACK {agent_crossed(n,p,e,events,loco,near<1.5 && abs(position.y-p.to.y)<0.75)}
    case:
        if linalg.length(p.to-position)<0.2 {agent_crossed(n,p,e,events,loco);return}
        if p.time>linalg.length(p.to-p.from)/0.5+NAV_CROSS_SLACK {agent_crossed(n,p,e,events,loco,false)}
    }
}

@(private)
agent_crossed :: proc(n:^Navigation,p:^Nav_Path,e:core.Entity,events:^Nav_Events,loco:^locomotion.Locomotion_Requests,reached:=true) {
    if !p.manual {locomotion.set_mode(loco,e,locomotion.MODE_FALLING)}
    p.manual=false
    if reached {
        if p.class>=0 && int(p.class)<n.count {
            if _,_,_,ok:=ai.nav_corridor_cross(&p.corridor,&n.classes[p.class].mesh);ok {
                p.state=.Moving
                core.push(&events.queue,Nav_Event{kind=.Crossed,entity=e,link=p.kind,from=p.from,to=p.to})
                return
            }
        }
    }
    p.state=.Waiting
    p.replans+=1
}

// The launch of a jump or a drop from a point to the end of its link: the
// velocity at the start and the time to land, on the arc of nav_jump_point.
jump_launch :: proc "contextless" (from,to:mm.Vec3,kind:Nav_Link_Kind,gravity:f32) -> (velocity:mm.Vec3,rise,total:f32) {
    g:=max(gravity,0.1)
    top:=max(from.y,to.y)+(ai.NAV_JUMP_CLEARANCE if kind==LINK_JUMP else 0)
    up:=math.sqrt(max(2*g*(top-from.y),0))
    rise=up/g
    fall:=math.sqrt(max(2*(top-to.y)/g,0))
    total=max(rise+fall,1e-3)
    velocity={(to.x-from.x)/total,up,(to.z-from.z)/total}
    return
}

// Searches the paths of the agents that wait, in order, within the budget.
@(private)
agents_search :: proc(n:^Navigation,a:^Navigation_Agents,b:^Navigation_Builds,paths:^core.Table(Nav_Path),agents:^core.Table(Nav_Agent,$A),characters:^core.Table(phys.Character,$B),grounds:^core.Table(phys.Character_State,$C),colliders:^core.Table(phys.Collider,$D),walks:^core.Table(locomotion.Walk,$E),swims:^core.Table(locomotion.Swim,$F),worlds:^core.Table(core.World_Transform,$G),physics:core.Ref(phys.Physics_State),sections:^Nav_Sections,budget:int,dt:f32,events:^Nav_Events,problems:^core.Problems) {
    for &tree,i in a.trees {
        if tree.target==core.NONE {continue}
        tree.age+=dt
        tree.idle+=dt
        if tree.idle>NAV_FOLLOW_IDLE && int(a.searching_tree)!=i+1 {tree.target,tree.built=core.NONE,false}
    }
    left:=budget
    deferred:=0
    for left>0 {
        if a.searching==core.NONE {
            if deferred>=len(a.waiting)-a.head {return}
            e:=a.waiting[a.head]
            a.head+=1
            if a.head==len(a.waiting) {
                clear(&a.waiting)
                a.head=0
            } else if a.head>=64 && a.head*2>=len(a.waiting) {
                copy(a.waiting[:],a.waiting[a.head:])
                base.truncate(&a.waiting,len(a.waiting)-a.head)
                a.head=0
            }
            p:=core.edit(paths,e)
            if p!=nil {p.queued=false}
            agent,ok:=core.get(agents,e)
            pose,placed:=core.get(worlds,e)
            if p==nil || !ok || !placed || p.state!=.Waiting || p.class<0 || int(p.class)>=n.count {continue}
            class:=n.classes[p.class].class
            p.medium=false
            if p.partner>=0 && int(p.partner)<n.count && agent_medium_begin_search(n,a,b,p,e,agent,pose,characters,colliders,walks,swims,physics,sections) {continue}
            if class_in_volume(n,int(p.class)) {
                volume:=&n.classes[p.class].volume
                extents:=mm.Vec3{class.radius*2+0.5,class.height,class.radius*2+0.5}
                collider,_:=core.get(colliders,e)
                center:=pose.position+{0,(collider.size.x+collider.size.y)*abs(pose.scale.y),0}
                // Toward a section away, only as far as the portal its way enters by.
                goal:=p.goal
                p.through=false
                if sections!=nil {
                    if via,ok:=agent_via(n,a,sections,int(p.class),center,p.goal);ok {goal,p.through=via,true}
                }
                from,start,found:=ai.nav_volume_find_nearest(volume,center,extents)
                to,end,found_goal:=ai.nav_volume_find_nearest(volume,goal,extents*4)
                if (!found || !found_goal) && n.classes[p.class].pending>0 {
                    append(&a.waiting,e)
                    p.queued=true
                    deferred+=1
                    continue
                }
                if !found || !found_goal {
                    p.state=.Failed
                    if !found {
                        core.report(problems,e,"navigation.off_mesh","The agent is not in the free space of the volume of its class %q: move it into a Nav_Bounds of the air, clear of the collision",base.text_get(class.name[:]))
                    } else {
                        core.report(problems,e,"navigation.goal_off_mesh","The goal %v is not near the free space of the volume of class %q: ask for a point inside a Nav_Bounds of the air, clear of the collision",p.goal,base.text_get(class.name[:]))
                    }
                    core.push(&events.queue,Nav_Event{kind=.Failed,entity=e})
                    continue
                }
                p.corridor={count=1,position=start,target=start}
                p.corridor.path[0]=from
                // In sight: straight there, with no search.
                if clear,_:=ai.nav_volume_raycast(volume,start,end);clear {
                    p.corridor.target=end
                    p.partial,p.state,p.time=false,.Moving,0
                    continue
                }
                ai.nav_volume_path_begin(&a.volume_query,volume,from,to,start,end)
                a.searching,a.searching_air,a.searching_medium=e,true,false
                continue
            }
            mesh:=&n.classes[p.class].mesh
            walk_row,_:=core.get(walks,e)
            filter:=agent_filter(n,int(p.class),agent,{walk_row.jump_height,walk_row.max_speed},core.has(swims,e),linalg.length(phys.gravity_of_entity(physics,e)))
            extents:=mm.Vec3{class.radius*2+0.5,class.height,class.radius*2+0.5}
            // Toward a section away, only as far as the portal its way enters by.
            goal:=p.goal
            p.through=false
            if sections!=nil {
                if via,ok:=agent_via(n,a,sections,int(p.class),pose.position,p.goal);ok {goal,p.through=via,true}
            }
            from,start,found:=ai.nav_find_nearest(mesh,pose.position,extents,&filter)
            to,end,found_goal:=ai.nav_find_nearest(mesh,goal,extents*4,&filter)
            ground,_:=core.get(grounds,e)
            // One in the air (falling, or asked elsewhere in the middle of a jump) looks for the mesh again once it stands.
            if (!found || !found_goal) && (n.classes[p.class].pending>0 || !found && !ground.standing) {
                // The surface there may be building: ask again once it is.
                append(&a.waiting,e)
                p.queued=true
                deferred+=1
                continue
            }
            if !found {
                p.state=.Failed
                core.report(problems,e,"navigation.off_mesh","The agent is not on the mesh of its class %q: move it onto walkable ground inside the navigation bounds",base.text_get(class.name[:]))
                core.push(&events.queue,Nav_Event{kind=.Failed,entity=e})
                continue
            }
            if !found_goal {
                p.state=.Failed
                core.report(problems,e,"navigation.goal_off_mesh","The goal %v is not near the mesh of class %q: ask for a point on walkable ground",p.goal,base.text_get(class.name[:]))
                core.push(&events.queue,Nav_Event{kind=.Failed,entity=e})
                continue
            }
            ai.nav_corridor_reset(&p.corridor,from,start)
            if p.target!=core.NONE && !p.through {
                if tree:=follow_tree(a,p,e,mesh,&filter,to,end);tree>=0 {
                    // Toward the target as the shared search saw it.
                    p.goal=a.trees[tree].goal
                    a.searching,a.searching_air,a.searching_medium,a.searching_tree=e,false,false,u8(tree+1)
                    continue
                }
            }
            ai.nav_path_begin(&a.query,mesh,from,to,start,end,&filter)
            a.searching,a.searching_air,a.searching_medium=e,false,false
        }
        e:=a.searching
        p:=core.edit(paths,e)
        if a.searching_tree!=0 {
            tree:=&a.trees[a.searching_tree-1]
            if p==nil || p.state!=.Waiting || !tree.built || p.class!=tree.class || p.target!=tree.target || int(p.class)>=n.count {
                a.searching,a.searching_tree=core.NONE,0
                continue
            }
            mesh:=&n.classes[p.class].mesh
            from:=ai.nav_corridor_first(&p.corridor)
            status:=ai.Search_Status.Invalid
            if ai.nav_ref_valid(mesh,from) {
                before:=tree.query.search.stats.expanded
                status=ai.nav_toward_reach(&tree.query,from,left)
                left-=max(tree.query.search.stats.expanded-before,1)
                if status==.Running {return}
            }
            a.searching,a.searching_tree=core.NONE,0
            count,found:=0,false
            if status==.Found {count,found=ai.nav_toward_path(&tree.query,from,a.refs[:])}
            if !found {
                // Cut off from the target, or beyond what the shared search holds: its own says how near it gets.
                if ai.nav_path_begin(&a.query,mesh,from,tree.end_ref,p.corridor.position,tree.end,&tree.filter)==.Invalid {agent_fail(p,e,events);continue}
                a.searching,a.searching_air,a.searching_medium=e,false,false
                continue
            }
            if !ai.nav_corridor_set(&p.corridor,mesh,&tree.filter,tree.end,a.refs[:count]) {agent_fail(p,e,events);continue}
            p.partial,p.state,p.time=false,.Moving,0
            continue
        }
        if a.searching_medium {
            if p==nil || p.state!=.Waiting || p.class!=a.searching_class || p.partner<0 || int(p.partner)>=n.count {a.searching=core.NONE;continue}
            search:=&a.medium_query.search
            before:=search.stats.expanded
            status:=ai.nav_medium_path_step(&a.medium_query,left)
            left-=max(search.stats.expanded-before,1)
            if status==.Running {return}
            a.searching=core.NONE
            agent_medium_path(n,a,p,e,events)
            continue
        }
        if p==nil || p.state!=.Waiting || p.class<0 || int(p.class)>=n.count || class_in_volume(n,int(p.class))!=a.searching_air {a.searching=core.NONE;continue}
        if a.searching_air {
            search:=&a.volume_query.search
            before:=search.stats.expanded
            status:=ai.nav_volume_path_step(&a.volume_query,left)
            left-=max(search.stats.expanded-before,1)
            if status==.Running {return}
            a.searching=core.NONE
            volume:=&n.classes[p.class].volume
            count,final,partial:=ai.nav_volume_path_finish(&a.volume_query,a.refs[:])
            if count==0 || final==.Invalid {
                p.state=.Failed
                core.push(&events.queue,Nav_Event{kind=.Failed,entity=e})
                continue
            }
            target:=a.volume_query.end
            if partial {
                box,_:=ai.nav_volume_ref_box(volume,a.refs[count-1])
                target=linalg.clamp(target,box.min,box.max)
            }
            if !ai.nav_volume_corridor_set(&p.corridor,volume,target,a.refs[:count]) {agent_fail(p,e,events);continue}
            p.partial=partial || final!=.Found
            p.state=.Moving
            p.time=0
            continue
        }
        before:=a.query.search.stats.expanded
        status:=ai.nav_path_step(&a.query,left)
        left-=max(a.query.search.stats.expanded-before,1)
        if status==.Running {return}
        a.searching=core.NONE
        mesh:=&n.classes[p.class].mesh
        count,final,partial:=ai.nav_path_finish(&a.query,a.refs[:])
        if count==0 || final==.Invalid {
            p.state=.Failed
            core.push(&events.queue,Nav_Event{kind=.Failed,entity=e})
            continue
        }
        target:=a.query.end
        if partial {target,_=ai.nav_closest_point_on_poly(mesh,a.refs[count-1],a.query.end)}
        if !ai.nav_corridor_set(&p.corridor,mesh,&a.query.filter,target,a.refs[:count]) {agent_fail(p,e,events);continue}
        p.partial=partial || final!=.Found
        p.state=.Moving
        p.time=0
    }
}

// The search toward its target that a follower reads its path from, begun, or
// begun again when the target moved on or the mesh changed; -1 for the first
// follower of a target, which leaves its mark and searches its own way, and
// when no search is free.
@(private)
follow_tree :: proc(a:^Navigation_Agents,p:^Nav_Path,e:core.Entity,mesh:^ai.Nav_Mesh,filter:^ai.Nav_Filter,to:ai.Nav_Ref,end:mm.Vec3) -> int {
    free:=-1
    for &tree,i in a.trees {
        if tree.target!=p.target || tree.class!=p.class || tree.filter!=filter^ {
            // The first free one; else one nobody shares yet, or the one unused longest for a whole plan.
            unused:=tree.target==core.NONE
            if free>=0 && a.trees[free].target==core.NONE {continue}
            if unused || !tree.built && (free<0 || a.trees[free].built || tree.idle>a.trees[free].idle) || tree.built && tree.idle>=NAV_REPLAN_FOLLOW && (free<0 || a.trees[free].built && tree.idle>a.trees[free].idle) {free=i}
            continue
        }
        tree.idle=0
        if !tree.built && tree.first==e {return -1}
        moved:=tree.age>=NAV_REPLAN_FOLLOW && linalg.length(p.goal-tree.goal)>max(p.distance*0.5,0.5)
        if !tree.built || moved || tree.revision!=mesh.revision || !ai.nav_ref_valid(mesh,tree.end_ref) {
            if len(tree.query.points)==0 && !ai.nav_query_init(&tree.query,len(a.query.points)) {return -1}
            if !ai.nav_toward_begin(&tree.query,mesh,to,end,filter) {tree.built=false;return -1}
            tree.built,tree.goal,tree.end,tree.end_ref,tree.revision,tree.age=true,p.goal,end,to,mesh.revision,0
        }
        return i
    }
    if free>=0 {
        tree:=&a.trees[free]
        tree.target,tree.class,tree.first,tree.built,tree.filter,tree.idle=p.target,p.class,e,false,filter^,0
    }
    return -1
}

// The space links between the mesh of a class and the volume of another
// around a way from `from` to `to`: the shores of the water near it, or every
// take-off of the air (the Nav_Link rows of LINK_FLY).
@(private)
agent_space_links :: proc(n:^Navigation,a:^Navigation_Agents,b:^Navigation_Builds,mesh_class,volume_class:int,from,to:mm.Vec3) -> []ai.Nav_Space_Link {
    count:=0
    c:=n.classes[volume_class].class
    switch c.space {
    case .Water:
        box:=mm.aabb_add_point(mm.aabb_add_point(mm.AABB_EMPTY,from),to)
        box={box.min-NAV_SHORE_MARGIN,box.max+NAV_SHORE_MARGIN}
        count=ai.nav_shore_links(&n.classes[mesh_class].mesh,box,u8(AREA_WATER),c.radius*2,c.height*0.5+0.1,NAV_SHORE_SPACING,u8(LINK_SWIM),a.space_links[:])
    case .Air:
        if b==nil {break}
        for seen in b.links.values {
            if seen.link.kind!=LINK_FLY {continue}
            if count==len(a.space_links) {break}
            a.space_links[count]={surface=seen.start,space=seen.end,two_way=seen.link.two_way,cost=seen.link.cost,kind=u8(LINK_FLY)}
            count+=1
        }
    case .Surface:
    }
    return a.space_links[:count]
}

// Starts the search of an agent that may cross into the other space, over
// its mesh and the volume of the other, when there are space links between
// them and its start and goal are found; false leaves it to the search of
// its own space, which says what is missing. A way toward a section away
// stays in its own space.
@(private)
agent_medium_begin_search :: proc(n:^Navigation,a:^Navigation_Agents,b:^Navigation_Builds,p:^Nav_Path,e:core.Entity,agent:Nav_Agent,pose:core.World_Transform,characters:^core.Table(phys.Character,$A),colliders:^core.Table(phys.Collider,$B),walks:^core.Table(locomotion.Walk,$C),swims:^core.Table(locomotion.Swim,$D),physics:core.Ref(phys.Physics_State),sections:^Nav_Sections) -> bool {
    if sections!=nil && sections.away_count>0 && sections_away(sections,p.goal) {return false}
    in_volume:=class_in_volume(n,int(p.class))
    if in_volume==class_in_volume(n,int(p.partner)) {return false}
    mesh_class,volume_class:=int(p.partner) if in_volume else int(p.class),int(p.class) if in_volume else int(p.partner)
    mesh:=&n.classes[mesh_class].mesh
    volume:=&n.classes[volume_class].volume
    walk_row,_:=core.get(walks,e)
    filter:=agent_filter(n,mesh_class,agent,{walk_row.jump_height,walk_row.max_speed},core.has(swims,e),linalg.length(phys.gravity_of_entity(physics,e)))
    // Under the water it swims, through the volume: the ground there is not walked.
    if n.classes[volume_class].class.space==.Water {filter.excluded|=u64(1)<<u64(AREA_WATER)}
    own:=n.classes[p.class].class
    extents:=mm.Vec3{own.radius*2+0.5,own.height,own.radius*2+0.5}
    collider,_:=core.get(colliders,e)
    lift:=mm.Vec3{0,(collider.size.x+collider.size.y)*abs(pose.scale.y),0}
    find :: proc(mesh:^ai.Nav_Mesh,volume:^ai.Nav_Volume,filter:^ai.Nav_Filter,in_volume:bool,point,extents:mm.Vec3) -> (ref:ai.Nav_Ref,at:mm.Vec3,ok:bool) {
        if in_volume {return ai.nav_volume_find_nearest(volume,point,extents)}
        return ai.nav_find_nearest(mesh,point,extents,filter)
    }
    position:=pose.position+lift if in_volume else pose.position
    from,start,found:=find(mesh,volume,&filter,in_volume,position,extents)
    if !found {return false}
    // A goal on the ground is on the mesh (it lands, it walks out of the water); else in the free space, else farther.
    walker:=n.classes[mesh_class].class
    to,end,found_goal:=find(mesh,volume,&filter,false,p.goal,{walker.radius*2+0.5,walker.height,walker.radius*2+0.5})
    if !found_goal {to,end,found_goal=find(mesh,volume,&filter,true,p.goal,extents)}
    if !found_goal {to,end,found_goal=find(mesh,volume,&filter,in_volume,p.goal,extents*4)}
    if !found_goal {return false}
    links:=agent_space_links(n,a,b,mesh_class,volume_class,start,end)
    if len(links)==0 {return false}
    if len(a.medium_query.points)==0 && !ai.nav_medium_query_init(&a.medium_query,1<<15) {return false}
    reach:=mm.Vec3{1,2,1}*max(n.classes[volume_class].class.radius*2+0.5,1)
    if ai.nav_medium_path_begin(&a.medium_query,mesh,volume,&filter,links,reach,from,to,start,end)==.Invalid {return false}
    if in_volume {
        p.corridor={count=1,position=start,target=start}
        p.corridor.path[0]=from
    } else {
        ai.nav_corridor_reset(&p.corridor,from,start)
    }
    p.through=false
    a.searching,a.searching_air,a.searching_medium,a.searching_class=e,in_volume,true,p.class
    return true
}

// Takes the path a search over the mesh and the volume found: its corridor
// is the part in the space the agent is in, up to where it crosses into the
// other, if the corridor holds it.
@(private)
agent_fail :: proc(p:^Nav_Path,e:core.Entity,events:^Nav_Events) {
    p.state=.Failed
    core.push(&events.queue,Nav_Event{kind=.Failed,entity=e})
}

@(private)
agent_medium_path :: proc(n:^Navigation,a:^Navigation_Agents,p:^Nav_Path,e:core.Entity,events:^Nav_Events) {
    q:=&a.medium_query
    count,final,partial:=ai.nav_medium_path_finish(q,a.refs[:])
    if count==0 || final==.Invalid {
        p.state=.Failed
        core.push(&events.queue,Nav_Event{kind=.Failed,entity=e})
        return
    }
    part,from,to,kind,crosses:=ai.nav_medium_first_part(q,a.refs[:count])
    crosses&&=part<=ai.NAV_CORRIDOR_CAPACITY
    in_volume:=class_in_volume(n,int(p.class))
    target:=from if crosses else q.end
    set:bool
    if in_volume {
        volume:=&n.classes[p.class].volume
        if !crosses && (partial || part<count) {
            box,_:=ai.nav_volume_ref_box(volume,a.refs[part-1])
            target=linalg.clamp(target,box.min,box.max)
        }
        set=ai.nav_volume_corridor_set(&p.corridor,volume,target,a.refs[:part])
    } else {
        mesh:=&n.classes[p.class].mesh
        if !crosses && (partial || part<count) {target,_=ai.nav_closest_point_on_poly(mesh,a.refs[part-1],q.end)}
        set=ai.nav_corridor_set(&p.corridor,mesh,&q.filter,target,a.refs[:part])
    }
    if !set {agent_fail(p,e,events);return}
    p.medium=crosses
    if crosses {p.from,p.to,p.kind=from,to,Nav_Link_Kind(kind)}
    p.partial=!crosses && (partial || final!=.Found || part<count)
    p.state=.Moving
    p.time=0
}

// Steps every avoiding agent aside from the others, each from its wanted
// velocity, with ORCA: on the plane, among those at its height and within the
// edges of its mesh near it, for an agent that walks; in three axes, every
// neighbor a sphere, for one that flies. Its neighbors are those it may meet
// within the horizon (agent_neighbors).
@(private)
agents_avoid :: proc(n:^Navigation,a:^Navigation_Agents,paths:^core.Table(Nav_Path),dt:f32,problems:^core.Problems) {
    count:=len(a.near)
    if count<2 {return}
    if count>len(a.grid.items) {
        capacity:=64
        for capacity<count {capacity*=2}
        spatial.grid_destroy(&a.grid)
        if !spatial.grid_init(&a.grid,{cell_size=NAV_AGENT_CELL,buckets=capacity*2,item_capacity=capacity}) {
            core.report(problems,core.NONE,"navigation.memory","No memory for %d agents and obstacles to step aside from each other: they do not in this tick; free memory, or give fewer agents avoidance",count)
            return
        }
    }
    spatial.grid_clear(&a.grid)
    // The fastest and the widest: farther than those close within the horizon, nobody shapes a velocity.
    fastest,widest:f32
    for near,i in a.near {
        spatial.grid_insert(&a.grid,ground_box(near.position,0),u64(i))
        if near.avoids {fastest=max(fastest,linalg.length(near.velocity))}
        widest=max(widest,near_sphere(near))
    }
    for near,i in a.near {
        if !near.avoids {continue}
        p:=core.edit(paths,near.entity)
        if p==nil || p.state!=.Moving {continue}
        speed:=linalg.length(p.velocity)
        // Farther than both can close within the horizon, a neighbor shapes no velocity it may choose.
        top:=max(speed,linalg.length(near.velocity))
        agent_neighbors(a,i,top,NAV_AGENT_HORIZON*(top+fastest)+near_sphere(near)+widest)
        if near.flies {
            if len(a.neighbors_air)==0 {continue}
            self:=ai.Avoid_Agent(3){position=near.position,velocity=near.velocity,radius=near_sphere(near)}
            p.velocity=ai.avoid_velocity(self,p.velocity,max(speed,0.01),a.neighbors_air[:],NAV_AGENT_HORIZON,dt)
            continue
        }
        if len(a.neighbors)==0 {continue}
        self:=ai.Avoid_Agent(2){position={near.position.x,near.position.z},velocity={near.velocity.x,near.velocity.z},radius=near.radius}
        // The edges of its mesh it could reach are walls of the same program: a velocity that
        // steps aside does not leave the mesh, off a ledge or into a wall where others crowd.
        walls:[ai.AVOID_MAX_WALLS]ai.Avoid_Wall
        wall_count:=0
        if p.class>=0 && int(p.class)<n.count {
            filter:=ai.Nav_Filter{excluded=u64(near.excluded)}
            on:=p.corridor.position
            wall_count=ai.nav_walls_near(&n.classes[p.class].mesh,ai.nav_corridor_first(&p.corridor),on,max(speed,0.01)*NAV_AGENT_WALL_HORIZON+ai.AVOID_WALL_TOUCH,&filter,walls[:])
            // Seen from where it is on the mesh: its body may stand a little off it.
            off:=[2]f32{near.position.x-on.x,near.position.z-on.z}
            for &wall in walls[:wall_count] {wall.a+=off;wall.b+=off}
        }
        chosen:=ai.avoid_velocity(self,{p.velocity.x,p.velocity.z},max(speed,0.01),a.neighbors[:],NAV_AGENT_HORIZON,dt,walls[:wall_count],NAV_AGENT_WALL_HORIZON)
        p.velocity={chosen.x,0,chosen.y}
    }
}

// The neighbors of near[i] in a.neighbors (it walks) or a.neighbors_air (it
// flies): those it may meet within the horizon at speed top, from boxes of the
// grid that grow up to wanted until they hold as many neighbors nearer than the
// box as ORCA counts.
@(private)
agent_neighbors :: proc(a:^Navigation_Agents,i:int,top,wanted:f32) {
    near:=a.near[i]
    far:=clamp(wanted,NAV_AGENT_CELL,NAV_AGENT_REACH*NAV_AGENT_CELL)
    for held:=NAV_AGENT_CELL;;held=min(held*2,far) {
        clear(&a.neighbors)
        clear(&a.neighbors_air)
        within:=0
        query:=spatial.grid_query(&a.grid,ground_box(near.position,held))
        for {
            _,index,ok:=spatial.grid_query_next(&query)
            if !ok {break}
            if int(index)==i {continue}
            other:=a.near[index]
            velocity:=other.avoids?other.velocity:{}
            to:=other.position-near.position
            reach:=NAV_AGENT_HORIZON*(top+linalg.length(velocity))
            if near.flies {
                reach+=near_sphere(near)+near_sphere(other)
            } else {
                if abs(to.y)>max(near.height,other.height) {continue}
                to.y=0
                reach+=near.radius+other.radius
            }
            distance2:=linalg.length2(to)
            if distance2>reach*reach {continue}
            if distance2<=held*held {within+=1}
            if near.flies {
                append(&a.neighbors_air,ai.Avoid_Agent(3){position=other.position,velocity=velocity,radius=near_sphere(other)})
            } else {
                append(&a.neighbors,ai.Avoid_Agent(2){position=other.position.xz,velocity=velocity.xz,radius=other.radius})
            }
        }
        if held>=far || within>=ai.AVOID_MAX_NEIGHBORS {return}
    }
}

@(private)
near_sphere :: #force_inline proc "contextless" (near:Near) -> f32 {return max(near.radius,near.height*0.5)}

// The box of the neighbor grid around a point on the ground: all its cells are of one height.
@(private)
ground_box :: #force_inline proc "contextless" (at:mm.Vec3,reach:f32) -> mm.Aabb {
    return {{at.x-reach,NAV_AGENT_CELL*0.5,at.z-reach},{at.x+reach,NAV_AGENT_CELL*0.5,at.z+reach}}
}

// Writes the Move_Input of every agent no seat drives, and of a seated one
// while it goes: its velocity, which its mover takes up to its top speed (the
// velocity that steps aside is the one it moves at), looking where it goes or
// at what it looks at; its body turns there at its own rate. One that flies or
// swims looks level and climbs or dives. The seat of a seated one
// wrote its Move_Input earlier in the tick, with its buttons and the turn of
// the ground. How many agents cross a link.
@(private)
agents_steer :: proc(n:^Navigation,agents:^core.Table(Nav_Agent,.Read),paths:^core.Table(Nav_Path),inputs:^core.Table(input.Move_Input),seats:^core.Table(input.Seat,.Read),grounds:^core.Table(phys.Character_State,.Read),worlds:^core.Table(core.World_Transform,.Read)) -> (crossing:u32) {
    for row in 0..<core.count(paths) {
        e:=core.entity_at(paths,row)
        p:=core.edit_at(paths,row)
        if p.state==.Crossing {crossing+=1}
        driven:=false
        if input.seat_of(seats,e)!=core.NONE {
            agent,_:=core.get(agents,e)
            if !agent.seated {continue}
            driven=true
        }
        mi:=core.edit(inputs,e)
        if mi==nil {continue}
        if p.state!=.Moving && p.state!=.Crossing {
            // Once, when it stops: whatever writes it next is not navigation.
            if !p.halted {
                if !driven {mi.move,mi.velocity={},false}
                p.halted=true
            }
            continue
        }
        p.halted=false
        ground,_:=core.get(grounds,e)
        pose,_:=core.get(worlds,e)
        if !driven {mi.look_yaw=mm.angle_wrap(mi.look_yaw+ground.ground_turn)}
        flat:=mm.Vec3{p.velocity.x,0,p.velocity.z}
        speed:=linalg.length(flat)
        if p.looking {
            to:=p.look-pose.position
            to.y=0
            if linalg.length(to)>1e-3 {mi.look_yaw=mm.yaw_of_direction(to)}
        } else if speed>0.05 {mi.look_yaw=mm.yaw_of_direction(flat)}
        mi.velocity=true
        if p.class>=0 && int(p.class)<n.count && class_in_volume(n,int(p.class)) {
            mi.look_pitch=0
            mi.move=p.velocity
            continue
        }
        mi.move=flat
        if speed<=1e-4 || p.state==.Crossing && !p.medium {mi.move={}}
    }
    return
}

// Drives the characters that cross a link of the engine: the launch of a
// jump or a drop on its first tick and the air drive along it after, or the
// way along a ladder or a climb without gravity.
@(step="fixed",stage="simulate",before="locomotion_step",server)
navigation_crossing :: proc(
    paths:^core.Table(Nav_Path,.Read),moves:^core.Table(phys.Character_Move),characters:^core.Table(phys.Character,.Read),
    walks:^core.Table(locomotion.Walk,.Read),motions:^core.Table(core.Motion,.Read),worlds:^core.Table(core.World_Transform,.Read),
    physics:core.Ref(phys.Physics_State),crossings:core.Ref(Nav_Crossings),time:core.Time,
) {
    if !time.playing || time.dt<=0 || crossings.ptr==nil || crossings.count==0 {return}
    for row in 0..<core.count(paths) {
        p:=paths.values[row]
        if p.state!=.Crossing || p.manual || p.medium {continue}
        e:=core.entity_at(paths,row)
        move:=core.edit(moves,e)
        character,ok:=core.get(characters,e)
        if move==nil || !ok {continue}
        pose,_:=core.get(worlds,e)
        motion,_:=core.get(motions,e)
        walk,_:=core.get(walks,e)
        next:phys.Character_Move
        next.value.yaw=move.value.yaw
        traction:=character.traction_force
        switch p.kind {
        case LINK_JUMP,LINK_DROP:
            velocity,_,_:=jump_launch(pose.position if p.time==0 else p.from,p.to,p.kind,linalg.length(phys.gravity_of_entity(physics,e))*character.gravity_scale)
            flat:=mm.Vec3{velocity.x,0,velocity.z}
            if p.time==0 {
                next.value.launch=velocity-motion.linear
                next.value.flags={.Airborne}
            }
            next.value.air={velocity=flat,force=traction}
            if linalg.length(flat)>0.05 {next.value.yaw=mm.yaw_of_direction(flat)}
        case:
            speed:=max(walk.max_speed*0.5,0.5)
            d:=p.to-pose.position
            length:=linalg.length(d)
            next.value.air={velocity=d/max(length,1e-4)*min(speed,length/max(time.dt,1e-4)),force=traction}
            next.value.flags={.Airborne,.Drive_Vertical,.No_Gravity}
        }
        if move^!=next {move^=next}
    }
}
