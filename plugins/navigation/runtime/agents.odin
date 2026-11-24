package navigation

import "core:math"
import "core:math/linalg"
import "mirai:core"
import input "mirai:engine/input"
import "mirai:std/jobs"
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
// corner, steps aside from the agents around it and writes the Move_Input of
// its body, a velocity (world_velocity), which its locomotion turns into steps. At the start of a link
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
// An agent without a Character (a walker of a crowd) has no body: it walks
// the surface as wide and tall as its class, and navigation moves it itself
// (agents_walk), writing its Transform and its core.Motion.

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
NAV_CORRIDOR_AHEAD :: 8        // steps of its corridor that must stay valid, and before the end of a cut one, that an agent plans again
NAV_BLOCKED :: f32(2)          // s walking in place before an agent plans again; twice that, it fails
NAV_CROSS_SLACK :: f32(1.0)    // s a crossing may outlast its arc before it counts as failed
NAV_CROSS_REACHED :: f32(0.25) // m from the end of a link within which the game took the agent across
NAV_FLY_AHEAD :: 6             // portals of its corridor a flying agent looks for ahead
NAV_SHORE_MARGIN :: f32(16)    // m around its way where an agent that swims looks for shores
NAV_SHORE_SPACING :: f32(2)    // m between the links of a shore
NAV_CLASS_MISSING :: i8(-2)    // Nav_Route.named of an agent whose class name no class has
NAV_EDGE_STEPS :: 256          // points of its straight way an agent looks at for the edge of what is built toward its goal

@(component,description="Walks where navigation is asked to take it: a Character, which flies with a Fly or swims with a Swim, by its locomotion with a class that fits its capsule and collision; without one, moved by navigation along the surface, as wide and tall as its class.")
Nav_Agent :: struct {
    drop:f32 `mirai:"min=0,unit=m"`, // it may fall this far; 0: as its class
    abilities:Nav_Abilities,
    avoid:Nav_Areas,                 // areas it never walks
    reach:f32 `mirai:"min=0,unit=m"`, // how near the end counts as there
    avoidance:bool,                  // steps aside from the other agents
    manual:Nav_Link_Kinds,           // kinds of links the game crosses for it
    seated:bool,                     // navigation may drive it while a seat controls it
    class:[32]u8 `mirai:"text"`,     // optional class name
}
NAV_AGENT_DEFAULT :: Nav_Agent{reach=0.3,avoidance=true}

Nav_State :: enum u8 {
    Idle,
    Waiting,  // for its path, walking on along the one it had
    Moving,
    Crossing, // a link
    Arrived,
    Arrived_Partial,
    Failed,   // no way, or blocked: see the problems of the entity
}

// What an agent is doing. Navigation adds it to every Nav_Agent and is its
// only writer; the game reads it.
@(component,derived,description="Where the agent goes and the link it crosses.")
Nav_Path :: struct {
    target:core.Entity `mirai:"readonly"`,
    link_entity:core.Entity `mirai:"readonly,transient"`,
    goal:[3]f32 `mirai:"readonly,unit=m"`,
    velocity:[3]f32 `mirai:"readonly,transient,unit=m/s"`,
    look:[3]f32 `mirai:"readonly,unit=m"`,
    distance:f32 `mirai:"readonly,unit=m"`, // kept from the target
    state:Nav_State `mirai:"readonly"`,
    class:i8 `mirai:"readonly,transient"`,
    kind:Nav_Link_Kind `mirai:"readonly,transient"`,
    looking,partial,manual:bool `mirai:"readonly,transient"`,
}
NAV_PATH_DEFAULT :: Nav_Path{class=-1}

Nav_Route :: struct {
    corridor:ai.Nav_Corridor,
    boundary:ai.Nav_Boundary,
    reserved:core.Entity,
    from,to:mm.Vec3,
    time:f32, // in the crossing, or since the last plan while following
    replans:u32,
    steering:bool,
    partner:i8, // class of the other space; -1: none
    named:i8,   // the class Nav_Agent.class names: -1 none, NAV_CLASS_MISSING when no class has that name
    named_known:bool, // named is looked up: false after Nav_Agent or the classes changed
    medium,through,queued:bool,
    passthrough,placed:bool,
    seat:enum u8 {None,Player,Shared},
    release:enum u8 {None,Collision,Falling},
    anchor:mm.Vec3,
    launch:mm.Vec3, // where it began its crossing
    walked:mm.Vec3, // where navigation last saw or put one without a body
    stuck:f32,
    bodyless:bool,  // it has no Character: navigation moves it (agents_walk)
    edge:bool,      // its search ends where what is built ends toward a goal whose tiles still build (edge_toward)
}

agent_route :: proc "contextless" (a:^Navigation_Agents,e:core.Entity) -> ^Nav_Route {
    return core.entity_map_get(&a.routes,e) if a!=nil else nil
}

Nav_Request_Kind :: enum u8 {Move_To,Follow,Stop,Look_At,Look_Along,Crossing_Done,Crossing_Skip}

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
// Stops the agent where it is, and its look: what it faces next is not navigation's.
nav_stop :: proc(r:^Nav_Requests,e:core.Entity) {core.push(&r.queue,Nav_Request{kind=.Stop,entity=e})}
// Faces a point, walking (a shooter that strafes) or standing; nav_look_along faces the way again.
nav_look_at :: proc(r:^Nav_Requests,e:core.Entity,point:[3]f32) {core.push(&r.queue,Nav_Request{kind=.Look_At,entity=e,point=point})}
nav_look_along :: proc(r:^Nav_Requests,e:core.Entity) {core.push(&r.queue,Nav_Request{kind=.Look_Along,entity=e})}
// The game crossed the link the agent waits at: it goes on from its end.
nav_crossing_done :: proc(r:^Nav_Requests,e:core.Entity) {core.push(&r.queue,Nav_Request{kind=.Crossing_Done,entity=e})}
// The game is done with the link the agent waits at without taking it across:
// navigation puts it at the end, facing as it was, unless it stands within
// NAV_CROSS_REACHED of it (a clip warped onto nav_crossing_target took it
// there), and it goes on from there.
nav_crossing_skip :: proc(r:^Nav_Requests,e:core.Entity) {core.push(&r.queue,Nav_Request{kind=.Crossing_Skip,entity=e})}

// The link an agent crosses while its Nav_Path is Crossing, in the world: its
// ends, as the Crossing Nav_Event gave them, and facing from one to the other
// across +Y. A clip that climbs or vaults it warps onto `to` with `facing`
// (anim.motion_target of its window).
nav_crossing_target :: proc "contextless" (a:^Navigation_Agents,p:Nav_Path,e:core.Entity) -> (from,to:[3]f32,facing:mm.Quat,ok:bool) {
    r:=agent_route(a,e)
    if r==nil || p.state!=.Crossing {return}
    along:=r.to-r.from
    yaw:f32
    if linalg.length(along.xz)>1e-4 {yaw=mm.yaw_of_direction(along)}
    return r.from,r.to,mm.quat_axis_angle({0,1,0},yaw),true
}

Nav_Event_Kind :: enum u8 {
    Arrived,
    Arrived_Partial,
    Failed,
    Crossing, // starts a link; the game crosses it when Nav_Event.manual
    Crossed,
}

Nav_Event :: struct {
    kind:Nav_Event_Kind,
    entity,link_entity:core.Entity,
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
    revision:u64,          // of the meshes the agents last looked at: partial paths plan again when it grows
    coarse:ai.Search,      // over the portals of a coarse graph
    route:[NAV_FAR_POINTS]mm.Vec3,
    far_sections:u64,      // the sections the far simulation last looked at
    routes:core.Entity_Map(Nav_Route),
    reservations:core.Entity_Map(u32), // active crossings per authored link
    waiting:[]core.Entity, // ring in order of arrival
    head,waiting_count:int,
    places_read:int,
    shapes:[4]core.Shape,  // agents, paths, authored links and characters
    agents_seen:core.Seen, // of the Nav_Agents the routes last looked up their named class in
    refs:[dynamic]ai.Nav_Ref,
    grid:spatial.Grid,     // the agents and obstacles of the tick (near) by where they stand on the ground
    avoid_scratch:[]Avoid_Scratch,
    near:[dynamic]Near,
    widest_ground:f32,     // m, the widest radius of the agents of the tick that crowd others (held_ahead)
    widest_still:f32,      // m, and of what never steps aside: the other characters and the obstacles
}

// The search toward a target that its followers share: those of one class
// that walk and cross the same. The first follower searches its own way and
// only leaves its mark; a second one begins the search, from where the target
// is on the mesh, and from then each follower expands it as far as its own
// polygon and reads its path. It begins again when the target moved on, at
// most every NAV_REPLAN_FOLLOW, or a way read from it crossed a polygon that
// expired: a tile built elsewhere does not touch it.
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
    age,idle:f32,       // s since the search began, and since a follower last asked
}

@(private)
Near :: struct {
    entity:core.Entity,
    position,velocity,wanted:mm.Vec3,
    radius,height:f32,
    avoids,flies,crowd:bool,
    path_row,route_slot:int, // index plus one
    excluded:Nav_Areas, // the areas an agent that walks keeps out of
}

agents_free :: proc(a:^Navigation_Agents) {
    ai.nav_query_destroy(&a.query)
    ai.nav_volume_query_destroy(&a.volume_query)
    ai.nav_medium_query_destroy(&a.medium_query)
    for &tree in a.trees {ai.nav_query_destroy(&tree.query)}
    ai.search_destroy(&a.coarse)
    delete(a.space_links)
    core.entity_map_destroy(&a.routes)
    core.entity_map_destroy(&a.reservations)
    delete(a.waiting)
    delete(a.refs)
    spatial.grid_destroy(&a.grid)
    for &scratch in a.avoid_scratch {
        delete(scratch.ground)
        delete(scratch.air)
    }
    delete(a.avoid_scratch)
    delete(a.near)
    a^={}
}

// The class of a character in a space: the smallest by radius, then height,
// whose size holds its capsule; on the surface, one which does not step
// higher or walk steeper than it. -1: none.
class_of :: proc "contextless" (
    n:^Navigation,character:phys.Character,collider:phys.Collider,scale:[3]f32,
    space:Nav_Space,selected:int=-1,
) -> (class:int,radius,height:f32) {
    radius=collider.size.x*max(abs(scale.x),abs(scale.z))
    height=2*(collider.size.x+collider.size.y)*abs(scale.y)
    class=class_fit(n,radius,height,collider.preset,character.step_height,character.max_slope,space,selected)
    return
}

// The class of an agent without a Character: the walking class it names, else
// the smallest walking class of the default collision. It is as wide and tall
// as its class, and climbs and walks what its class does. -1: none.
class_bodyless :: proc "contextless" (n:^Navigation,selected:int=-1) -> (class:int,radius,height:f32) {
    class=class_fit(n,0,0,phys.PRESET_DEFAULT,math.INF_F32,math.INF_F32,.Surface,selected)
    if class>=0 {radius,height=n.classes[class].class.radius,n.classes[class].class.height}
    return
}

// The smallest class of a space, by radius then height, that holds a radius
// and a height; on the surface, one which climbs no higher than climb and walks
// no steeper than slope. -1: none.
@(private)
class_fit :: proc "contextless" (
    n:^Navigation,radius,height:f32,collision:phys.Collision_Preset,climb,slope:f32,
    space:Nav_Space,selected:int,
) -> (class:int) {
    preset:=collision
    specific:=false
    for i in 0..<n.count {
        c:=n.classes[i].class
        specific|=c.space==space && c.collision==preset
    }
    if !specific {preset=phys.PRESET_DEFAULT}
    explicit:=selected>=0 && selected<n.count && n.classes[selected].class.space==space
    class=-1
    for i in 0..<n.count {
        c:=n.classes[i].class
        if c.space!=space || c.radius+1e-4<radius || c.height+1e-4<height {continue}
        if space==.Surface && (c.climb>climb+1e-4 || c.max_slope>slope+1e-4) {continue}
        if explicit {
            if i==selected {class=i;return}
            continue
        }
        if c.collision!=preset {continue}
        if class<0 || c.radius<n.classes[class].class.radius ||
                      c.radius==n.classes[class].class.radius &&
                      c.height<n.classes[class].class.height {class=i}
    }
    return
}

// What an agent can cross: its jump from its Walk (how high, jump_height,
// the apex of every jump of the walk, and how far in the time in the air of
// an arc to that apex at its speed, under the gravity it falls by), its drop
// and abilities from Nav_Agent.
agent_can :: proc "contextless" (n:^Navigation,class:int,agent:Nav_Agent,walk:locomotion.Walk,gravity:f32) -> ai.Nav_Need {
    c:=n.classes[class].class
    can:=ai.Nav_Need{down=agent.drop if agent.drop>0 else c.drop,abilities=u32(agent.abilities)}
    if walk.jump_height>0 && gravity>0 {
        can.up=walk.jump_height
        can.across=walk.max_speed*2*math.sqrt(2*walk.jump_height/gravity)
    }
    return can
}

// The gravity an agent falls by: that of its place times the gravity_scale of
// its Character, and as it is without one.
agent_gravity :: proc(physics:core.Ref(phys.Physics_State),e:core.Entity,characters:^core.Table(phys.Character,$A)) -> f32 {
    scale:=f32(1)
    if character,ok:=core.get(characters,e);ok {scale=character.gravity_scale}
    return linalg.length(phys.gravity_of_entity(physics,e))*scale
}

// The areas an agent never walks: its own, and the deep ground under the water when it cannot swim.
agent_avoids :: proc "contextless" (agent:Nav_Agent,swims:bool) -> Nav_Areas {
    return agent.avoid if swims else agent.avoid|Nav_Areas(1<<u64(AREA_WATER))
}

// What an agent of a class walks and crosses, as navigation moves it; swims: it has a Swim.
agent_filter :: proc "contextless" (n:^Navigation,class:int,agent:Nav_Agent,walk:locomotion.Walk,swims:bool,gravity:f32) -> ai.Nav_Filter {
    return filter_make(&n.settings,agent_avoids(agent,swims),agent_can(n,class,agent,walk,gravity))
}

@(step="fixed",stage="apply",server)
navigation_agents :: proc(
    n:core.Ref(Navigation),a:^Navigation_Agents,agents:^core.Table(Nav_Agent,.Read),paths:^core.Table(Nav_Path),
    requests:^Nav_Requests,events:^Nav_Events,moves:^core.Table(input.Move_Input),
    links:^core.Table(Nav_Link,.Read),seats:^core.Table(input.Seat,.Read),seat_state:core.Ref(input.Seats),
    characters:^core.Table(phys.Character,.Read),loco_states:^core.Table(locomotion.Locomotion_State,.Read),colliders:^core.Table(phys.Collider,.Read),walks:^core.Table(locomotion.Walk,.Read),flights:^core.Table(locomotion.Fly,.Read),swims:^core.Table(locomotion.Swim,.Read),
    grounds:^core.Table(phys.Character_State,.Read),motions:^core.Table(core.Motion),worlds:^core.Table(core.World_Transform,.Read),
    obstacles:^core.Table(Nav_Obstacle,.Read),volumes:^core.Table(volume.Volume,.Read),splines:^core.Table(volume.Spline,.Read),loco:^locomotion.Locomotion_Requests,physics:core.Ref(phys.Physics_State),builds:core.Ref(Navigation_Builds),fars:^core.Table(Nav_Far),
    roamings:^core.Table(scene.Roaming),disabled:^core.Table(core.Disabled),placer:core.Placer,bodies:^phys.Body_Requests,crossings:^Nav_Crossings,
    sources:core.Ref(scene.Simulation_Sources),time:core.Time,job_system:^jobs.Job_System,problems:^core.Problems,
) {
    a.places_read=0
    if !agents_sync(a,agents,characters,paths,links,moves,seat_state,fars,roamings,disabled,loco,problems) {return}
    if n.ptr!=nil && (a.uid!=n.uid || a.made!=n.made) {
        a.uid,a.made=n.uid,n.made
        a.searching,a.searching_tree=core.NONE,0
        for &tree in a.trees {tree.target,tree.built=core.NONE,false}
        a.head,a.waiting_count=0,0
        for &r,i in a.routes.values {
            r.queued,r.named_known=false,false
            e:=a.routes.entities[i]
            if p:=core.staged(paths,e);p!=nil {agent_reset(a,p,&r,e,loco)}
        }
    }
    if core.table_touched(agents,&a.agents_seen) {
        for &r in a.routes.values {r.named_known=false}
    }
    for asked in core.take(&requests.queue) {
        if far_request(paths,fars,asked,worlds) {continue}
        p:=core.staged(paths,asked.entity)
        r:=agent_route(a,asked.entity)
        if p==nil || r==nil {
            core.report(problems,asked.entity,"navigation.request","Navigation was asked to move an entity without a Nav_Agent: give it one")
            continue
        }
        switch asked.kind {
        case .Move_To:
            agent_cancel_search(a,asked.entity)
            agent_stop_crossing(a,p,r,asked.entity,loco)
            p.goal,p.target,p.state,p.partial=asked.point,core.NONE,.Waiting,false
            r.stuck=0
        case .Follow:
            agent_cancel_search(a,asked.entity)
            agent_stop_crossing(a,p,r,asked.entity,loco)
            p.target,p.distance,p.state,p.partial=asked.target,max(asked.distance,0),.Waiting,false
            r.stuck=0
            if pose,ok:=core.get(worlds,asked.target);ok {p.goal=pose.position}
        case .Stop:
            agent_cancel_search(a,asked.entity)
            agent_stop_crossing(a,p,r,asked.entity,loco)
            p.state,p.looking,p.partial=.Idle,false,false
            p.velocity={}
            r.corridor.count=0
            if r.steering {input.move_release(moves,seat_state,asked.entity);r.steering=false}
        case .Look_At:
            p.look,p.looking=asked.point,true
        case .Look_Along:
            p.looking=false
        case .Crossing_Done,.Crossing_Skip:
            if n.ptr==nil || p.state!=.Crossing || !p.manual {continue}
            // One the clip of the crossing took to the end goes on from where it stands.
            if pose,placed:=core.get(worlds,asked.entity);asked.kind==.Crossing_Skip && !(placed && linalg.length(pose.position-r.to)<=NAV_CROSS_REACHED) {
                core.place(placer,asked.entity,r.to,pose.rotation if placed else 1)
                r.walked=r.to
            }
            agent_crossed(n.ptr,a,p,r,asked.entity,events,loco)
        }
    }
    for &r in a.routes.values {r.placed,r.seat=false,.None}
    for seat in seats.values[:core.count(seats)] {
        if r:=agent_route(a,seat.body);r!=nil {
            agent,_:=core.get(agents,seat.body)
            r.seat=.Shared if agent.seated else .Player
        }
    }
    agents_places(a,paths,moves,seat_state,placer.places,loco)
    if n.ptr==nil || !n.ready || n.count==0 || !time.playing || time.dt<=0 {return}
    if core.count(paths)==0 && len(fars.entities)==0 {return}
    budget:=int(n.settings.path_iterations) if n.settings.path_iterations>0 else 2048
    // Each agent, each other character and each obstacle is near some agent at most once.
    if !agents_scratch_ready(a,core.count(agents)+core.count(characters)+core.count(obstacles),job_system) {
        core.report(problems,core.NONE,"navigation.memory","No memory for navigation agent scratch")
        return
    }
    if len(a.query.points)==0 && !ai.nav_query_init(&a.query,8192) {
        core.report(problems,core.NONE,"navigation.memory","No memory to search paths")
        return
    }
    if len(a.refs)==0 && resize(&a.refs,4096)!=nil {
        core.report(problems,core.NONE,"navigation.memory","No memory to search paths")
        return
    }
    clear(&a.near)
    built:=a.revision!=n.revision
    a.revision=n.revision
    walking:=core.join(paths,agents)
    for e,_,agent in core.each_joined(&walking) {
        p:=core.edit_at(paths,walking.row)
        slot:=core.entity_map_index(&a.routes,e)
        if slot<0 {continue}
        r:=&a.routes.values[slot]
        if r.placed {continue}
        character,has_character:=core.get(characters,e)
        collider,has_collider:=core.get(colliders,e)
        pose,placed:=core.get(worlds,e)
        if !has_character && placed {
            // Nothing else moves it: it is where its Transform puts it now, placed earlier in
            // this tick too. Put elsewhere than navigation left it, it plans again from there,
            // unless the game takes it across a link.
            if now,ok:=core.world_of(placer.transforms,placer.parents,e);ok {pose.transform=now}
            if linalg.length2(pose.position-r.walked)>1e-6 {
                if p.state!=.Idle && !(p.state==.Crossing && p.manual) {agent_reset(a,p,r,e,loco)}
                r.walked=pose.position
            }
        }
        if has_character && (!has_collider || collider.kind!=.Capsule) || !placed {
            agent_stop_crossing(a,p,r,e,loco)
            if p.state!=.Idle && p.state!=.Failed {agent_fail(p,e,events)}
            if placed {
                core.report(problems,e,"navigation.agent_character","The Character of a Nav_Agent needs a capsule Collider: give it one, or remove the Character for navigation to move it")
            } else {
                core.report(problems,e,"navigation.agent_character","A Nav_Agent needs a Transform: give it one")
            }
            continue
        }
        // One without a Character walks: nothing flies or swims it.
        fly,can_fly:=core.get(flights,e)
        swim,can_swim:=core.get(swims,e)
        can_fly&&=has_character
        can_swim&&=has_character
        walker:=core.has(walks,e)
        // One that only flies or swims is always in the air or the water; one that also walks, while the physics has it fly or swim.
        moving,_:=core.get(loco_states,e)
        flies:=can_fly && (!walker || moving.mode==locomotion.MODE_FLYING)
        swims:=!flies && can_swim && (!walker || moving.mode==locomotion.MODE_SWIMMING)
        space:=Nav_Space.Air if flies else (.Water if swims else .Surface)
        if !r.named_known {
            class_name:=agent.class
            name:=base.text_get(class_name[:])
            r.named=-1 if name=="" else i8(class_find(n.ptr,name))
            if name!="" && r.named<0 {r.named=NAV_CLASS_MISSING}
            r.named_known=true
        }
        if r.named==NAV_CLASS_MISSING {
            class_name:=agent.class
            core.report(problems,e,"navigation.agent_class","Navigation class %q does not exist: choose a class from Navigation_Settings",base.text_get(class_name[:]))
            agent_stop_crossing(a,p,r,e,loco)
            if p.state!=.Idle && p.state!=.Failed {agent_fail(p,e,events)}
            continue
        }
        selected:=int(r.named)
        class,radius,height:=class_bodyless(n.ptr,selected)
        if has_character {class,radius,height=class_of(n.ptr,character,collider,pose.scale,space,selected)}
        // The other space it may cross into: the surface for one that walks, or the water or the air from it.
        partner:=-1
        switch {
        case flies || swims: if walker {partner,_,_=class_of(n.ptr,character,collider,pose.scale,.Surface,selected)}
        case can_swim: partner,_,_=class_of(n.ptr,character,collider,pose.scale,.Water,selected)
        case can_fly: partner,_,_=class_of(n.ptr,character,collider,pose.scale,.Air,selected)
        }
        r.partner=i8(partner)
        if class<0 {
            agent_stop_crossing(a,p,r,e,loco)
            if !has_character {
                core.report(problems,e,"navigation.agent_class","No class of Navigation_Settings walks the surface with the default collision: add one, or name a class of the surface in Nav_Agent.class")
            } else if flies || swims {
                core.report(problems,e,"navigation.agent_class","No class of the %s in Navigation_Settings holds this agent, which %s: add one with space %v, a radius of at least %.2f m and a height of at least %.2f m","air" if flies else "water","flies" if flies else "swims",space,radius,height)
            } else {
                core.report(problems,e,"navigation.agent_class","No class of Navigation_Settings holds this agent: add one with a radius of at least %.2f m and a height of at least %.2f m that climbs no higher than its step_height and walks no steeper than its max_slope",radius,height)
            }
            if p.state!=.Idle && p.state!=.Failed {agent_fail(p,e,events)}
            continue
        }
        if int(p.class)!=class {
            // Its corridor was over the mesh or the volume of the other class.
            p.class,r.corridor.count,r.boundary=i8(class),0,{}
            switch {
            case p.state==.Moving || p.state==.Arrived_Partial: p.state=.Waiting
            case p.state==.Crossing && !r.medium:
                agent_stop_crossing(a,p,r,e,loco)
                p.state=.Waiting
            // In the other space: it plans on from there; a take-off, once where it leads.
            case p.state==.Crossing && r.medium && !(p.kind==LINK_FLY && flies):
                core.push(&events.queue,Nav_Event{kind=.Crossed,entity=e,link=p.kind,from=r.from,to=r.to})
                r.medium,p.state=false,.Waiting
            }
        }
        motion,_:=core.get(motions,e)
        // A flier plans and steps aside by the center of its capsule; its feet are the origin of its entity.
        center:=pose.position+{0,height*0.5,0}
        append(&a.near,Near{entity=e,position=center,velocity=motion.linear,radius=radius,height=height,avoids=agent.avoidance,flies=flies || swims,excluded=agent_avoids(agent,can_swim),path_row=walking.row+1,route_slot=slot+1})
        if p.target!=core.NONE && p.state==.Failed {
            // A follower tries again: its target may come where it can go.
            r.time+=time.dt
            if r.time>=NAV_REPLAN_FOLLOW*4 {r.time,p.state,r.stuck=0,.Waiting,0}
        }
        // A tile built may take it nearer its goal.
        if p.partial && (p.state==.Moving || p.state==.Arrived_Partial) && built {agent_replan(p,r)}
        walk,_:=core.get(walks,e)
        // What it walks and crosses, for one on its way: it jumps under the gravity of its
        // place (a planet, a room without it).
        filter:ai.Nav_Filter
        if !flies && !swims && (p.state==.Waiting || p.state==.Moving || p.state==.Arrived && p.target!=core.NONE) {
            filter=agent_filter(n.ptr,class,agent,walk,can_swim,agent_gravity(physics,e,characters))
        }
        if p.target!=core.NONE && (p.state==.Moving || p.state==.Arrived || p.state==.Arrived_Partial) {
            r.time+=time.dt
            if to,ok:=core.get(worlds,p.target);ok {
                reach:=agent_reach(agent,p)
                slack:=follow_slack(reach)
                moved:=linalg.length(to.position-p.goal)>slack
                if !p.partial && to.position!=p.goal && !flies && !swims &&
                   !r.medium && !r.through &&
                   ai.nav_corridor_move_target(&r.corridor,&n.classes[class].mesh,&filter,to.position) &&
                   linalg.length(r.corridor.target.xz-to.position.xz)<=slack {
                    p.goal=to.position
                    if p.state==.Arrived &&
                       linalg.length(r.corridor.target.xz-pose.position.xz)>reach+slack {
                        p.state=.Moving
                    }
                } else if moved && r.time>=NAV_REPLAN_FOLLOW {
                    p.goal,p.state=to.position,.Waiting
                }
            } else {p.state=.Idle}
        }
        switch p.state {
        case .Idle,.Arrived,.Arrived_Partial,.Failed:
            p.velocity={}
        case .Waiting,.Moving:
            if flies || swims {
                p.velocity={}
                if p.state==.Moving {
                    agent_fly(p,r,e,agent,center,&n.classes[class].volume,swim.speed if swims else fly.speed,swim.acceleration if swims else fly.acceleration,flies,moving.mode,n.classes[class].pending>0,events,loco)
                }
            } else if r.corridor.count>0 {
                agent_follow(n.ptr,a,links,p,r,e,agent,pose.position,&n.classes[class].mesh,&filter,walk,events,loco,problems)
            } else {
                p.velocity={}
            }
            if p.state==.Waiting && a.searching!=e && !r.queued {agent_enqueue(a,r,e)}
        case .Crossing:
            p.velocity={}
            if r.medium {
                r.time+=time.dt
                speed:=swim.speed if swims else (fly.speed if flies else 0)
                if !flies && !swims {speed=walk.max_speed}
                here:=center if flies || swims else pose.position
                // Up in the air where the take-off leads, clear of the ground, it plans the rest.
                if p.kind==LINK_FLY && flies && linalg.length(r.to-here)<=max(agent_reach(agent,p),0.5) {
                    core.push(&events.queue,Nav_Event{kind=.Crossed,entity=e,link=p.kind,from=r.from,to=r.to})
                    r.medium,p.state,p.velocity=false,.Waiting,{}
                } else {
                    agent_medium_crossing(p,r,here,speed if speed>0 else 3,!flies && !swims)
                }
            } else if p.link_entity!=core.NONE && !core.has(links,p.link_entity) {
                agent_reset(a,p,r,e,loco)
            } else if !p.manual {
                r.time+=time.dt
                // One without a body is carried along the link by agents_walk.
                if has_character {
                    ground,_:=core.get(grounds,e)
                    agent_crossing(n.ptr,a,p,r,e,pose.position,ground,agent_gravity(physics,e,characters),events,loco)
                }
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
        box,_:=obstacle_prism(volumes,splines,physics,e,pose.transform) or_continue
        half:=(box.max-box.min)*0.5
        motion,_:=core.get(motions,e)
        append(&a.near,Near{entity=e,position=(box.min+box.max)*0.5,velocity=motion.linear,radius=linalg.length(mm.Vec2{half.x,half.z}),height=half.y*2})
    }
    sections:=&builds.ptr.sections if builds.ptr!=nil else nil
    agents_search(n.ptr,a,builds.ptr,paths,agents,characters,grounds,colliders,walks,swims,worlds,physics,sections,budget,time.dt,events,problems)
    agents_avoid(n.ptr,a,paths,sources.ptr,time.dt,problems,job_system)
    agents_stuck(n.ptr,a,paths,time.dt,events,problems)
    crossings.count=agents_steer(n.ptr,a,paths,moves,seat_state,grounds,worlds)
    agents_walk(n.ptr,a,paths,walks,motions,placer,physics,characters,time.dt,events)
    agents_far(n,builds,a,agents,paths,moves,seat_state,fars,roamings,disabled,walks,flights,swims,colliders,worlds,placer,bodies,events,time)
    // A far agent wakes with a fresh route before requesting its own place.
    if placer.places!=nil {a.places_read=len(placer.places.queue.items)}
}

@(private)
agents_places :: proc(
    a:^Navigation_Agents,paths:^core.Table(Nav_Path),
    moves:^core.Table(input.Move_Input),seat_state:core.Ref(input.Seats),places:^core.Places,
    loco:^locomotion.Locomotion_Requests,
) {
    if places==nil {return}
    for placed in places.queue.items[min(a.places_read,len(places.queue.items)):] {
        e:=placed.entity
        p:=core.staged(paths,e)
        r:=agent_route(a,e)
        if p==nil || r==nil {continue}
        agent_reset(a,p,r,e,loco)
        if r.steering {input.move_release(moves,seat_state,e);r.steering=false}
        r.placed=true
    }
    a.places_read=len(places.queue.items)
}

@(private)
agents_sync :: proc(
    a:^Navigation_Agents,agents:^core.Table(Nav_Agent,.Read),
    characters:^core.Table(phys.Character,.Read),paths:^core.Table(Nav_Path),
    links:^core.Table(Nav_Link,.Read),moves:^core.Table(input.Move_Input),seat_state:core.Ref(input.Seats),
    fars:^core.Table(Nav_Far),roamings:^core.Table(scene.Roaming),disabled:^core.Table(core.Disabled),
    loco:^locomotion.Locomotion_Requests,problems:^core.Problems,
) -> bool {
    if core.reshaped(agents,&a.shapes[0]) | core.reshaped(paths,&a.shapes[1]) |
       core.reshaped(characters,&a.shapes[3]) {
        #reverse for e,i in a.routes.entities {
            r:=&a.routes.values[i]
            can_drive:=core.has(characters,e)
            if can_drive {
                switch r.release {
                case .None:
                case .Collision: locomotion.set_suspended(loco,e,false)
                case .Falling: locomotion.set_mode(loco,e,locomotion.MODE_FALLING)
                }
                r.release=.None
            }
            has_agent:=core.raw_row(core.raw(agents),e)>=0
            if core.has(agents,e) || has_agent && core.raw_row(core.raw(fars),e)>=0 {continue}
            parked:=!can_drive && core.raw_row(core.raw(characters),e)>=0
            requests:=loco if can_drive else nil
            if parked && r.passthrough {r.release=.Collision}
            if p:=cast(^Nav_Path)core.raw_edit(core.raw(paths),type_info_of(Nav_Path),e);p!=nil {
                if parked && p.state==.Crossing && !p.manual && !r.medium {r.release=.Falling}
                agent_reset(a,p,r,e,requests)
            } else {agent_release_link(a,r,e,requests)}
            r.queued=false
            if r.steering {input.move_release(moves,seat_state,e);r.steering=false}
            if core.raw_row(core.raw(fars),e)>=0 {
                core.remove(fars,e)
                core.remove(disabled,e)
            }
            if core.raw_row(core.raw(roamings),e)>=0 {core.remove(roamings,e)}
            if !parked || r.release==.None {core.entity_map_remove_at(&a.routes,i)}
        }
        for e in paths.entities {
            if core.raw_find(core.raw(agents),type_info_of(Nav_Agent),e)==nil {core.remove(paths,e)}
        }
        for row in 0..<core.count(agents) {
            e:=core.entity_at(agents,row)
            if !core.has(paths,e) {
                if r:=agent_route(a,e);r!=nil {
                    agent_release_link(a,r,e,loco)
                    agent_cancel_search(a,e)
                    if r.steering {input.move_release(moves,seat_state,e)}
                    r^={partner=-1,queued=r.queued}
                }
                core.add(paths,e,NAV_PATH_DEFAULT)
            }
        }
        count:=0
        for i in 0..<a.waiting_count {
            e:=a.waiting[(a.head+i)%len(a.waiting)]
            if !core.has(agents,e) || agent_route(a,e)==nil {continue}
            a.waiting[(a.head+count)%len(a.waiting)]=e
            count+=1
        }
        a.waiting_count=count
        if capacity:=len(agents.entities);capacity>len(a.waiting) {
            waiting,err:=make([]core.Entity,max(capacity,2*len(a.waiting)))
            if err!=nil {
                a.shapes[0]={}
                core.report(problems,core.NONE,"navigation.memory","No memory for the path search queue")
                return false
            }
            for i in 0..<count {waiting[i]=a.waiting[(a.head+i)%len(a.waiting)]}
            delete(a.waiting)
            a.waiting,a.head=waiting,0
        }
        for row in 0..<core.count(agents) {
            e:=core.entity_at(agents,row)
            if agent_route(a,e)!=nil {continue}
            r,ok:=core.entity_map_put(&a.routes,e,Nav_Route{partner=-1})
            if !ok {
                a.shapes[0]={}
                core.report(problems,e,"navigation.memory","No memory for the agent's route")
                return false
            }
            r.bodyless=!core.has(characters,e)
            if p:=core.edit(paths,e);p!=nil && p.state!=.Idle {agent_reset(a,p,r,e,loco)}
        }
        for e,i in a.routes.entities {a.routes.values[i].bodyless=!core.has(characters,e)}
    }
    if core.reshaped(links,&a.shapes[2]) {
        indices:=0
        for e in links.entities {indices=max(indices,core.entity_index(e)+1)}
        if !core.entity_map_reserve(&a.reservations,len(links.entities),indices) {
            a.shapes[2]={}
            core.report(problems,core.NONE,"navigation.memory","No memory for link reservations")
            return false
        }
    }
    return true
}

@(private)
agent_stop_crossing :: proc(
    a:^Navigation_Agents,p:^Nav_Path,r:^Nav_Route,e:core.Entity,
    loco:^locomotion.Locomotion_Requests,
) {
    if loco!=nil && !r.bodyless && p.state==.Crossing && !p.manual && !r.medium {
        locomotion.set_mode(loco,e,locomotion.MODE_FALLING)
    }
    agent_release_link(a,r,e,loco)
    p.link_entity,p.manual=core.NONE,false
}

@(private)
agent_release_link :: proc(
    a:^Navigation_Agents,r:^Nav_Route,e:core.Entity,loco:^locomotion.Locomotion_Requests,
) {
    if loco!=nil && !r.bodyless && r.passthrough {locomotion.set_suspended(loco,e,false)}
    if r.reserved!=core.NONE {
        if used:=core.entity_map_get(&a.reservations,r.reserved);used!=nil {
            used^-=1
            if used^==0 {core.entity_map_remove(&a.reservations,r.reserved)}
        }
    }
    r.passthrough,r.reserved=false,core.NONE
}

@(private)
agent_enqueue :: proc "contextless" (a:^Navigation_Agents,r:^Nav_Route,e:core.Entity) {
    if a.waiting_count>=len(a.waiting) {return}
    a.waiting[(a.head+a.waiting_count)%len(a.waiting)]=e
    a.waiting_count+=1
    r.queued=true
}

@(private)
agent_cancel_search :: proc "contextless" (a:^Navigation_Agents,e:core.Entity) {
    if a.searching==e {a.searching,a.searching_tree=core.NONE,0}
}

@(private)
agent_reset :: proc(
    a:^Navigation_Agents,p:^Nav_Path,r:^Nav_Route,e:core.Entity,
    loco:^locomotion.Locomotion_Requests,
) {
    agent_stop_crossing(a,p,r,e,loco)
    agent_cancel_search(a,e)
    r.corridor.count,r.boundary,r.stuck,r.time=0,{},0,0
    r.through,r.medium=false,false
    p.velocity,p.partial={},false
    if p.state!=.Idle {agent_replan(p,r)}
}

@(private)
follow_slack :: proc "contextless" (reach:f32) -> f32 {return min(reach*0.15,0.15)}

// Plans again from where it is; while it waits it walks on along its corridor.
@(private)
agent_replan :: proc "contextless" (p:^Nav_Path,r:^Nav_Route) {
    if p.state!=.Waiting {p.state,r.replans=.Waiting,r.replans+1}
}

// Whether navigation moves the agent: on its way, across a link, or on along its corridor while it waits.
@(private)
agent_goes :: #force_inline proc "contextless" (p:Nav_Path) -> bool {
    return p.state==.Moving || p.state==.Crossing || p.state==.Waiting && p.velocity!={}
}

// Heads for the next corner, starting a link when it is at its start. While
// its path is searched (Waiting) it walks on along the corridor it has, up to
// its end or its next link.
@(private)
agent_follow :: proc(n:^Navigation,a:^Navigation_Agents,links:^core.Table(Nav_Link,.Read),p:^Nav_Path,r:^Nav_Route,e:core.Entity,agent:Nav_Agent,position:mm.Vec3,mesh:^ai.Nav_Mesh,filter:^ai.Nav_Filter,walk:locomotion.Walk,events:^Nav_Events,loco:^locomotion.Locomotion_Requests,problems:^core.Problems) {
    p.velocity={}
    class:=n.classes[p.class].class
    // One that left the level of its corridor (pushed off a ledge, fallen) plans from where it is.
    if !ai.nav_corridor_move(&r.corridor,mesh,filter,position) || abs(position.y-r.corridor.position.y)>class.climb+NAV_OFF_LEVEL {
        agent_replan(p,r)
        return
    }
    // A step ahead changed (a tile built again), or the end of a cut corridor is near.
    if !ai.nav_corridor_valid(&r.corridor,mesh,filter,NAV_CORRIDOR_AHEAD) || r.corridor.cut && r.corridor.count<NAV_CORRIDOR_AHEAD {agent_replan(p,r)}
    speed:=walk.max_speed if walk.max_speed>0 else 3
    corners:[4]ai.Nav_Corner
    count:=ai.nav_corridor_corners(&r.corridor,mesh,corners[:],0.05)
    if count==0 {agent_replan(p,r);return}
    next:=corners[0]
    flat:=mm.Vec3{next.position.x-position.x,0,next.position.z-position.z}
    distance:=linalg.length(flat)
    reach:=agent_reach(agent,p)
    if .End in next.flags && distance<=reach {
        // At the portal into a section away: it goes far from here (agents_far).
        if p.state==.Waiting || r.through {return}
        if r.medium {agent_medium_begin(p,r,e,false,events,loco);return}
        // The end of a partial path while tiles still build is not as near as it gets: it waits there.
        if p.partial && n.classes[p.class].pending>0 {return}
        agent_arrived(p,e,events)
        return
    }
    if .Link in next.flags && distance<=max(reach,0.25) {
        if p.state==.Waiting {return}
        if agent_begin_link(a,links,p,r,e,agent,mesh,next,events,loco,problems) {r.launch=position}
        return
    }
    // Straight at the next corner: a turn taken wide (Detour's anticipated turns)
    // leads a body nothing clamps to its mesh into the outer wall. Slower within
    // twice its radius of the end.
    if last:=corners[count-1];.End in last.flags && !r.corridor.cut {
        remaining:=linalg.length(last.position.xz-position.xz)-reach
        speed*=clamp(remaining/max(2*class.radius,1e-3),0.2,1)
    }
    p.velocity=flat/max(distance,1e-4)*speed
}

@(private)
agent_begin_link :: proc(
    a:^Navigation_Agents,links:^core.Table(Nav_Link,.Read),p:^Nav_Path,r:^Nav_Route,
    e:core.Entity,agent:Nav_Agent,mesh:^ai.Nav_Mesh,next:ai.Nav_Corner,
    events:^Nav_Events,loco:^locomotion.Locomotion_Requests,problems:^core.Problems,
) -> bool {
    link:=ai.nav_link_of(mesh,next.ref)
    if link==nil || !link.enabled {agent_replan(p,r);return false}
    owner:=core.NONE
    if next.link_owner&LINK_OWNER_GENERATED==0 {owner=core.Entity(next.link_owner)}
    if owner!=core.NONE {
        authored,exists:=core.get(links,owner)
        if !exists || !authored.enabled {agent_replan(p,r);return false}
        used:=core.entity_map_get(&a.reservations,owner)
        if used==nil {
            used,_=core.entity_map_put(&a.reservations,owner,0)
            if used==nil {
                core.report(problems,e,"navigation.memory","No memory to reserve the link")
                return false
            }
        }
        if authored.capacity>0 && used^>=u32(authored.capacity) {return false}
        used^+=1
        r.passthrough,r.reserved=authored.passthrough,owner
    }
    from,to,_,_:=ai.nav_link_ends(link,next.ref)
    kind:=Nav_Link_Kind(link.desc.kind)
    p.state,p.kind,p.link_entity=.Crossing,kind,owner
    r.from,r.to,r.time=from,to,0
    p.manual=r.passthrough || u32(agent.manual)&(1<<u32(kind))!=0 ||
             kind!=LINK_JUMP && kind!=LINK_DROP && kind!=LINK_CLIMB && kind!=LINK_LADDER
    if !r.bodyless {
        if r.passthrough {locomotion.set_suspended(loco,e,true)}
        if !p.manual {locomotion.set_mode(loco,e,MODE_NAV_LINK)}
    }
    core.push(&events.queue,Nav_Event{
        kind=.Crossing,entity=e,link_entity=owner,link=kind,manual=p.manual,from=from,to=to,
    })
    return true
}

@(private)
agent_arrived :: proc(p:^Nav_Path,e:core.Entity,events:^Nav_Events) {
    p.state=.Arrived_Partial if p.partial else .Arrived
    core.push(&events.queue,Nav_Event{kind=.Arrived_Partial if p.partial else .Arrived,entity=e})
}

// Heads for the farthest portal of its corridor in sight, flying, or
// swimming, whose mode the physics decides by the depth of the water.
// building: its class has zones to build, so a partial end is no arrival.
@(private)
agent_fly :: proc(p:^Nav_Path,r:^Nav_Route,e:core.Entity,agent:Nav_Agent,position:mm.Vec3,volume:^ai.Nav_Volume,speed,acceleration:f32,flies:bool,mode:locomotion.Locomotion_Mode,building:bool,events:^Nav_Events,loco:^locomotion.Locomotion_Requests) {
    if flies && mode!=locomotion.MODE_FLYING {locomotion.set_mode(loco,e,locomotion.MODE_FLYING)}
    next,end,ok:=ai.nav_volume_corridor_steer(&r.corridor,volume,position,NAV_FLY_AHEAD)
    if !ok {agent_replan(p,r);return}
    to:=next-position
    distance:=linalg.length(to)
    reach:=agent_reach(agent,p)
    // The end of a cut corridor is not where it goes: it plans on from there without braking.
    if end && r.corridor.cut {
        if distance<=reach {agent_replan(p,r)}
    } else if end && distance<=reach {
        p.velocity={}
        // At the portal into a section away: it goes far from here (agents_far).
        if r.through {return}
        if r.medium {agent_medium_begin(p,r,e,true,events,loco);return}
        if p.partial && building {return}
        agent_arrived(p,e,events)
        return
    }
    top:=speed if speed>0 else 3
    // Toward the end, no faster than it can brake: in the air nothing else stops it.
    if end && !r.corridor.cut && acceleration>0 {top=min(top,max(math.sqrt(2*acceleration*0.5*distance),0.2))}
    p.velocity=to/max(distance,1e-4)*top
}

// At the end of its corridor, where it crosses into the other space: a
// take-off asks the physics to fly, a landing to fall; into or out of the
// water, it goes on and the physics swims or walks by the depth.
@(private)
agent_medium_begin :: proc(p:^Nav_Path,r:^Nav_Route,e:core.Entity,in_volume:bool,events:^Nav_Events,loco:^locomotion.Locomotion_Requests) {
    p.state,r.time,p.manual=.Crossing,0,false
    if p.kind==LINK_FLY {locomotion.set_mode(loco,e,locomotion.MODE_FALLING if in_volume else locomotion.MODE_FLYING)}
    core.push(&events.queue,Nav_Event{kind=.Crossing,entity=e,link=p.kind,from=r.from,to=r.to})
}

// Heads for the other end of a crossing into the other space, until its
// class changes with the mode the physics gives it; past the time it takes,
// it plans again from where it is. One that walks heads for it over the ground.
@(private)
agent_medium_crossing :: proc(p:^Nav_Path,r:^Nav_Route,position:mm.Vec3,speed:f32,walks:bool) {
    to:=r.to-position
    if walks {to.y=0}
    distance:=linalg.length(to)
    if r.time>linalg.length(r.to-r.from)/max(speed*0.25,0.25)+NAV_CROSS_SLACK*2 {
        r.medium=false
        agent_replan(p,r)
        return
    }
    if distance>0.05 {p.velocity=to/distance*speed}
}

// Ends a crossing of the engine once the body lands at the end of the link,
// or gives it up when it lasts beyond its arc.
@(private)
agent_crossing :: proc(n:^Navigation,a:^Navigation_Agents,p:^Nav_Path,r:^Nav_Route,e:core.Entity,position:mm.Vec3,ground:phys.Character_State,gravity:f32,events:^Nav_Events,loco:^locomotion.Locomotion_Requests) {
    near:=linalg.length(mm.Vec3{r.to.x-position.x,0,r.to.z-position.z})
    switch p.kind {
    case LINK_JUMP,LINK_DROP:
        landed:=ground.standing && r.time>0.15 && abs(position.y-r.to.y)<0.75
        if landed && near<1.5 {agent_crossed(n,a,p,r,e,events,loco);return}
        _,_,total:=jump_launch(r.from,r.to,p.kind,gravity)
        if r.time>total+NAV_CROSS_SLACK {agent_crossed(n,a,p,r,e,events,loco,near<1.5 && abs(position.y-r.to.y)<0.75)}
    case:
        if linalg.length(r.to-position)<0.2 {agent_crossed(n,a,p,r,e,events,loco);return}
        if r.time>linalg.length(r.to-r.from)/0.5+NAV_CROSS_SLACK {agent_crossed(n,a,p,r,e,events,loco,false)}
    }
}

@(private)
agent_crossed :: proc(n:^Navigation,a:^Navigation_Agents,p:^Nav_Path,r:^Nav_Route,e:core.Entity,events:^Nav_Events,loco:^locomotion.Locomotion_Requests,reached:=true) {
    owner:=p.link_entity
    agent_stop_crossing(a,p,r,e,loco)
    if reached {
        if p.class>=0 && int(p.class)<n.count {
            if _,_,_,ok:=ai.nav_corridor_cross(&r.corridor,&n.classes[p.class].mesh);ok {
                p.state=.Moving
                core.push(&events.queue,Nav_Event{kind=.Crossed,entity=e,link_entity=owner,link=p.kind,from=r.from,to=r.to})
                return
            }
        }
    }
    agent_replan(p,r)
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
            if deferred>=a.waiting_count {return}
            e:=a.waiting[a.head]
            a.head=(a.head+1)%len(a.waiting)
            a.waiting_count-=1
            p:=core.edit(paths,e)
            r:=agent_route(a,e)
            if r!=nil {r.queued=false}
            agent,ok:=core.get(agents,e)
            pose,placed:=core.get(worlds,e)
            if p==nil || r==nil || r.placed || !ok || !placed || p.state!=.Waiting || p.class<0 || int(p.class)>=n.count {continue}
            class:=n.classes[p.class].class
            r.medium,r.edge=false,false
            if r.partner>=0 && int(r.partner)<n.count && agent_medium_begin_search(n,a,b,p,r,e,agent,pose,characters,colliders,walks,swims,physics,sections) {continue}
            if class_in_volume(n,int(p.class)) {
                volume:=&n.classes[p.class].volume
                extents:=mm.Vec3{class.radius*2+0.5,class.height,class.radius*2+0.5}
                collider,_:=core.get(colliders,e)
                center:=pose.position+{0,(collider.size.x+collider.size.y)*abs(pose.scale.y),0}
                // Toward a section away, only as far as the portal its way enters by.
                goal:=p.goal
                r.through=false
                if sections!=nil {
                    if via,ok:=agent_via(n,a,sections,int(p.class),center,p.goal);ok {goal,r.through=via,true}
                }
                from,start,found:=ai.nav_volume_find_nearest(volume,center,extents)
                to,end,found_goal:=ai.nav_volume_find_nearest(volume,goal,extents*4)
                // Its goal in zones still building: toward the edge of what is built meanwhile.
                if found && !found_goal && n.classes[p.class].pending>0 {
                    to,end,found_goal=edge_toward(&n.classes[p.class],true,start,goal,extents*4,nil)
                    r.edge=found_goal
                }
                if (!found || !found_goal) && n.classes[p.class].pending>0 {
                    agent_enqueue(a,r,e)
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
                r.corridor={count=1,position=start,target=start}
                r.corridor.path[0]=from
                // In sight: straight there, with no search.
                if clear,_:=ai.nav_volume_raycast(volume,start,end);clear {
                    r.corridor.target=end
                    p.partial,p.state,r.time=r.edge,.Moving,0
                    continue
                }
                if len(a.volume_query.points)==0 && !ai.nav_volume_query_init(&a.volume_query,1<<15) {
                    core.report(problems,e,"navigation.memory","No memory to search paths through volumes")
                    agent_fail(p,e,events)
                    continue
                }
                ai.nav_volume_path_begin(&a.volume_query,volume,from,to,start,end)
                a.searching,a.searching_air,a.searching_medium=e,true,false
                continue
            }
            mesh:=&n.classes[p.class].mesh
            walk,_:=core.get(walks,e)
            filter:=agent_filter(n,int(p.class),agent,walk,core.has(swims,e),agent_gravity(physics,e,characters))
            extents:=mm.Vec3{class.radius*2+0.5,class.height,class.radius*2+0.5}
            // Toward a section away, only as far as the portal its way enters by.
            goal:=p.goal
            r.through=false
            if sections!=nil {
                if via,ok:=agent_via(n,a,sections,int(p.class),pose.position,p.goal);ok {goal,r.through=via,true}
            }
            // From where it stands on its corridor, which it walks on along while the search runs; else from the mesh nearest to it.
            from,start:=ai.nav_corridor_first(&r.corridor),r.corridor.position
            found:=!ai.nav_ref_is_link(from) && ai.nav_corridor_valid(&r.corridor,mesh,&filter,1) && linalg.length2(mm.Vec2{pose.position.x-start.x,pose.position.z-start.z})<=class.radius*class.radius && abs(pose.position.y-start.y)<=class.climb+NAV_OFF_LEVEL
            if !found {
                from,start,found=ai.nav_find_nearest(mesh,pose.position,extents,&filter)
                if found {ai.nav_corridor_reset(&r.corridor,from,start)}
            }
            to,end,found_goal:=ai.nav_find_nearest(mesh,goal,extents*4,&filter)
            // Its goal on tiles still building: toward the edge of what is built meanwhile.
            if found && !found_goal && n.classes[p.class].pending>0 {
                to,end,found_goal=edge_toward(&n.classes[p.class],false,start,goal,extents*4,&filter)
                r.edge=found_goal
            }
            ground,_:=core.get(grounds,e)
            // One in the air (falling, or asked elsewhere in the middle of a jump) looks for the mesh again once it stands.
            if (!found || !found_goal) && (n.classes[p.class].pending>0 || !found && !ground.standing && !r.bodyless) {
                // The surface there may be building: ask again once it is.
                agent_enqueue(a,r,e)
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
            if p.target!=core.NONE && !r.through && !r.edge {
                if tree:=follow_tree(a,p,r,e,agent,mesh,&filter,to,end);tree>=0 {
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
        r:=agent_route(a,e)
        if r==nil {a.searching,a.searching_tree=core.NONE,0;continue}
        if a.searching_tree!=0 {
            tree:=&a.trees[a.searching_tree-1]
            if p==nil || p.state!=.Waiting || !tree.built || p.class!=tree.class || p.target!=tree.target || int(p.class)>=n.count {
                a.searching,a.searching_tree=core.NONE,0
                continue
            }
            mesh:=&n.classes[p.class].mesh
            from:=ai.nav_corridor_first(&r.corridor)
            status:=ai.Search_Status.Invalid
            if ai.nav_ref_valid(mesh,from) {
                before:=tree.query.search.stats.expanded
                status=ai.nav_toward_reach(&tree.query,from,left)
                left-=max(tree.query.search.stats.expanded-before,1)
                if status==.Running {return}
            }
            a.searching,a.searching_tree=core.NONE,0
            count,found:=0,false
            if status==.Found {
                count,found=ai.nav_toward_path(&tree.query,from,a.refs[:])
                // A polygon of the way expired (a tile built again on it): the next follower begins it again.
                if !found {tree.built=false}
            }
            if !found {
                // Cut off from the target, or beyond what the shared search holds: its own says how near it gets.
                if ai.nav_path_begin(&a.query,mesh,from,tree.end_ref,r.corridor.position,tree.end,&tree.filter)==.Invalid {agent_fail(p,e,events);continue}
                a.searching,a.searching_air,a.searching_medium=e,false,false
                continue
            }
            if !ai.nav_corridor_set(&r.corridor,mesh,&tree.filter,tree.end,a.refs[:count]) {agent_fail(p,e,events);continue}
            p.partial,p.state,r.time=false,.Moving,0
            continue
        }
        if a.searching_medium {
            if p==nil || p.state!=.Waiting || p.class!=a.searching_class || r.partner<0 || int(r.partner)>=n.count {a.searching=core.NONE;continue}
            search:=&a.medium_query.search
            before:=search.stats.expanded
            status:=ai.nav_medium_path_step(&a.medium_query,left)
            left-=max(search.stats.expanded-before,1)
            if status==.Running {return}
            a.searching=core.NONE
            agent_medium_path(n,a,p,r,e,events)
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
            if !ai.nav_volume_corridor_set(&r.corridor,volume,target,a.refs[:count]) {agent_fail(p,e,events);continue}
            p.partial=partial || final!=.Found || r.edge
            p.state=.Moving
            r.time=0
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
        // From where the search began: the next move of the corridor takes it to where the agent walked since.
        r.corridor.position=a.query.start
        if !ai.nav_corridor_set(&r.corridor,mesh,&a.query.filter,target,a.refs[:count]) {agent_fail(p,e,events);continue}
        p.partial=partial || final!=.Found || r.edge
        p.state=.Moving
        r.time=0
    }
}

// The point of the mesh, or of the volume, nearest the goal on the straight
// way from start: where what is built ends toward a goal whose tiles or
// zones still build. The agent walks there, waits without arriving, and plans
// again as they come (a partial path).
@(private)
edge_toward :: proc "contextless" (c:^Class_Mesh,volume:bool,start,goal,extents:mm.Vec3,filter:^ai.Nav_Filter) -> (ref:ai.Nav_Ref,point:mm.Vec3,found:bool) {
    width:=c.volume.zone_size if volume else c.mesh.tile_width
    step:=max(min(width*0.5,extents.x),0.05)
    span:=linalg.length(goal-start)/step
    if !(span<NAV_EDGE_STEPS) {span=NAV_EDGE_STEPS}
    steps:=int(span)+1
    for i:=steps-1;i>=0;i-=1 {
        at:=linalg.lerp(start,goal,f32(i)/f32(steps))
        if volume {ref,point,found=ai.nav_volume_find_nearest(&c.volume,at,extents)} else {ref,point,found=ai.nav_find_nearest(&c.mesh,at,extents,filter)}
        if found {return}
    }
    return
}

// The search toward its target that a follower reads its path from, begun, or
// begun again when the target moved on or a way read from it expired; -1 for the first
// follower of a target, which leaves its mark and searches its own way, and
// when no search is free.
@(private)
follow_tree :: proc(a:^Navigation_Agents,p:^Nav_Path,r:^Nav_Route,e:core.Entity,agent:Nav_Agent,mesh:^ai.Nav_Mesh,filter:^ai.Nav_Filter,to:ai.Nav_Ref,end:mm.Vec3) -> int {
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
        moved:=tree.age>=NAV_REPLAN_FOLLOW && linalg.length(p.goal-tree.goal)>follow_slack(agent_reach(agent,p))
        if !tree.built || moved || !ai.nav_ref_valid(mesh,tree.end_ref) {
            if len(tree.query.points)==0 && !ai.nav_query_init(&tree.query,len(a.query.points)) {return -1}
            if !ai.nav_toward_begin(&tree.query,mesh,to,end,filter) {tree.built=false;return -1}
            tree.built,tree.goal,tree.end,tree.end_ref,tree.age=true,p.goal,end,to,0
        }
        return i
    }
    if free>=0 {
        tree:=&a.trees[free]
        tree.filter=filter^
        tree.target,tree.class,tree.first,tree.built,tree.idle=p.target,p.class,e,false,0
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
            if !seen.link.enabled || seen.link.kind!=LINK_FLY {continue}
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
agent_medium_begin_search :: proc(n:^Navigation,a:^Navigation_Agents,b:^Navigation_Builds,p:^Nav_Path,r:^Nav_Route,e:core.Entity,agent:Nav_Agent,pose:core.World_Transform,characters:^core.Table(phys.Character,$A),colliders:^core.Table(phys.Collider,$B),walks:^core.Table(locomotion.Walk,$C),swims:^core.Table(locomotion.Swim,$D),physics:core.Ref(phys.Physics_State),sections:^Nav_Sections) -> bool {
    if sections!=nil && len(sections.away)>0 && sections_away(sections,p.goal) {return false}
    in_volume:=class_in_volume(n,int(p.class))
    if in_volume==class_in_volume(n,int(r.partner)) {return false}
    mesh_class,volume_class:=int(r.partner) if in_volume else int(p.class),int(p.class) if in_volume else int(r.partner)
    mesh:=&n.classes[mesh_class].mesh
    volume:=&n.classes[volume_class].volume
    walk,_:=core.get(walks,e)
    filter:=agent_filter(n,mesh_class,agent,walk,core.has(swims,e),agent_gravity(physics,e,characters))
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
    if len(a.space_links)==0 && resize(&a.space_links,ai.NAV_QUERY_SPACE_LINKS)!=nil {return false}
    links:=agent_space_links(n,a,b,mesh_class,volume_class,start,end)
    if len(links)==0 {return false}
    if len(a.medium_query.points)==0 && !ai.nav_medium_query_init(&a.medium_query,1<<15) {return false}
    reach:=mm.Vec3{1,2,1}*max(n.classes[volume_class].class.radius*2+0.5,1)
    if ai.nav_medium_path_begin(&a.medium_query,mesh,volume,&filter,links,reach,from,to,start,end)==.Invalid {return false}
    if in_volume {
        r.corridor={count=1,position=start,target=start}
        r.corridor.path[0]=from
    } else {
        ai.nav_corridor_reset(&r.corridor,from,start)
    }
    r.through=false
    a.searching,a.searching_air,a.searching_medium,a.searching_class=e,in_volume,true,p.class
    return true
}

// Takes the path a search over the mesh and the volume found: its corridor
// is the part in the space the agent is in, up to where it crosses into the
// other, if the corridor holds it.
@(private)
agent_fail :: proc(p:^Nav_Path,e:core.Entity,events:^Nav_Events) {
    p.state,p.velocity=.Failed,{}
    core.push(&events.queue,Nav_Event{kind=.Failed,entity=e})
}

@(private)
agent_medium_path :: proc(n:^Navigation,a:^Navigation_Agents,p:^Nav_Path,r:^Nav_Route,e:core.Entity,events:^Nav_Events) {
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
    r.corridor.position=q.start
    set:bool
    if in_volume {
        volume:=&n.classes[p.class].volume
        if !crosses && (partial || part<count) {
            box,_:=ai.nav_volume_ref_box(volume,a.refs[part-1])
            target=linalg.clamp(target,box.min,box.max)
        }
        set=ai.nav_volume_corridor_set(&r.corridor,volume,target,a.refs[:part])
    } else {
        mesh:=&n.classes[p.class].mesh
        if !crosses && (partial || part<count) {target,_=ai.nav_closest_point_on_poly(mesh,a.refs[part-1],q.end)}
        set=ai.nav_corridor_set(&r.corridor,mesh,&q.filter,target,a.refs[:part])
    }
    if !set {agent_fail(p,e,events);return}
    r.medium=crosses
    if crosses {r.from,r.to,p.kind=from,to,Nav_Link_Kind(kind)}
    p.partial=!crosses && (partial || final!=.Found)
    p.state=.Moving
    r.time=0
}

@(private)
Avoid_Scratch :: struct {
    ground:[dynamic]ai.Avoid_Agent(2),
    air:[dynamic]ai.Avoid_Agent(3),
}

@(private)
agents_scratch_ready :: proc(a:^Navigation_Agents,count:int,system:^jobs.Job_System) -> bool {
    if count<=0 {return true}
    workers:=max(jobs.worker_count(system),1) if system!=nil else 1
    if count<=len(a.grid.items) && workers<=len(a.avoid_scratch) &&
       count<=cap(a.avoid_scratch[workers-1].ground) &&
       count<=cap(a.avoid_scratch[workers-1].air) {return true}
    capacity:=64
    for capacity<count {capacity*=2}
    if cap(a.near)<capacity && reserve(&a.near,capacity)!=nil {return false}
    if len(a.avoid_scratch)<workers {
        scratch,err:=make([]Avoid_Scratch,workers)
        if err!=nil {return false}
        copy(scratch,a.avoid_scratch)
        delete(a.avoid_scratch)
        a.avoid_scratch=scratch
    }
    for &scratch in a.avoid_scratch[:workers] {
        if cap(scratch.ground)<capacity && reserve(&scratch.ground,capacity)!=nil ||
           cap(scratch.air)<capacity && reserve(&scratch.air,capacity)!=nil {return false}
    }
    if len(a.grid.items)<capacity {
        grid:spatial.Grid
        if !spatial.grid_init(&grid,{cell_size=NAV_AGENT_CELL,buckets=capacity*2,item_capacity=capacity}) {
            spatial.grid_destroy(&grid)
            return false
        }
        spatial.grid_destroy(&a.grid)
        a.grid=grid
    }
    return true
}

@(private)
Avoid_Tick :: struct {
    n:^Navigation,
    a:^Navigation_Agents,
    paths:[]Nav_Path,
    fastest,widest,dt:f32,
}

@(private)
agents_avoid :: proc(
    n:^Navigation,a:^Navigation_Agents,paths:^core.Table(Nav_Path),
    sources:^scene.Simulation_Sources,dt:f32,problems:^core.Problems,system:^jobs.Job_System=nil,
) {
    count:=len(a.near)
    if count==0 {return}
    if !agents_scratch_ready(a,count,system) {
        core.report(problems,core.NONE,"navigation.memory","No memory for crowd avoidance")
        return
    }
    spatial.grid_clear(&a.grid)
    reach:=n.settings.avoidance_reach if n!=nil else 0
    tick:=Avoid_Tick{n=n,a=a,paths=paths.values[:],dt=dt}
    a.widest_ground,a.widest_still=0,0
    for &near,i in a.near {
        spatial.grid_insert(&a.grid,ground_box(near.position,0),u64(i))
        if near.path_row==0 && near.avoids {
            row:=core.raw_row(core.raw(paths),near.entity)
            if row>=0 && row<core.count(paths) {near.path_row=row+1}
        }
        if near.path_row!=0 {
            p:=core.edit_at(paths,near.path_row-1)
            near.wanted=p.velocity
            near.crowd=agent_goes(p^)
            near.avoids&=near.crowd && p.state!=.Crossing &&
                !(reach>0 && scene.sources_distance(sources,near.position,near.position)>reach)
        }
        tick.fastest=max(tick.fastest,linalg.length(near.velocity))
        tick.widest=max(tick.widest,near_sphere(near))
        if near.crowd {a.widest_ground=max(a.widest_ground,near.radius)}
        if near.route_slot==0 {a.widest_still=max(a.widest_still,near.radius)}
    }
    if count<2 {return}
    if system!=nil && jobs.worker_count(system)>0 {
        jobs.parallel_for(system,jobs.OWNER,count,16,avoid_range,&tick)
    } else {
        avoid_range(&tick,0,count,0)
    }
}

@(private)
avoid_range :: proc(tick:^Avoid_Tick,first,last,worker:int) {
    n,a:=tick.n,tick.a
    scratch:=&a.avoid_scratch[worker]
    for i in first..<last {
        near:=&a.near[i]
        if !near.avoids || near.path_row==0 {continue}
        p:=&tick.paths[near.path_row-1]
        speed:=linalg.length(near.wanted)
        top:=max(speed,linalg.length(near.velocity))
        agent_neighbors(a,scratch,i,p.target,top,
                        NAV_AGENT_HORIZON*(top+tick.fastest)+near_sphere(near^)+tick.widest)
        if near.flies {
            if len(scratch.air)==0 {continue}
            self:=ai.Avoid_Agent(3){
                position=near.position,velocity=near.velocity,radius=near_sphere(near^),
            }
            p.velocity=ai.avoid_velocity(self,near.wanted,max(speed,0.01),scratch.air[:],
                                         NAV_AGENT_HORIZON,tick.dt)
            continue
        }
        if len(scratch.ground)==0 {continue}
        self:=ai.Avoid_Agent(2){
            position=near.position.xz,velocity=near.velocity.xz,radius=near.radius,
        }
        walls:[ai.AVOID_MAX_WALLS]ai.Avoid_Wall
        wall_count:=0
        if near.route_slot!=0 && n!=nil && p.class>=0 && int(p.class)<n.count {
            r:=&a.routes.values[near.route_slot-1]
            filter:=ai.Nav_Filter{excluded=u64(near.excluded)}
            on:=r.corridor.position
            near_walls,_:=ai.nav_boundary_update(
                &r.boundary,&n.classes[p.class].mesh,ai.nav_corridor_first(&r.corridor),on,
                max(speed,0.01)*NAV_AGENT_WALL_HORIZON+ai.AVOID_WALL_TOUCH,&filter,
            )
            wall_count=copy(walls[:],near_walls)
            off:=near.position.xz-on.xz
            for &wall in walls[:wall_count] {wall.a+=off;wall.b+=off}
        }
        chosen:=ai.avoid_velocity(self,near.wanted.xz,max(speed,0.01),scratch.ground[:],
                                  NAV_AGENT_HORIZON,tick.dt,walls[:wall_count],NAV_AGENT_WALL_HORIZON)
        p.velocity={chosen.x,0,chosen.y}
    }
}

@(private)
agent_neighbors :: proc(
    a:^Navigation_Agents,scratch:^Avoid_Scratch,i:int,target:core.Entity,top,wanted:f32,
) {
    near:=&a.near[i]
    far:=clamp(wanted,NAV_AGENT_CELL,NAV_AGENT_REACH*NAV_AGENT_CELL)
    for held:=NAV_AGENT_CELL;;held=min(held*2,far) {
        clear(&scratch.ground)
        clear(&scratch.air)
        within:=0
        query:=spatial.grid_query(&a.grid,ground_box(near.position,held))
        for {
            _,index,ok:=spatial.grid_query_next(&query)
            if !ok {break}
            other:=&a.near[index]
            if int(index)==i || target!=core.NONE && other.entity==target || other.entity==near.entity {continue}
            to:=other.position-near.position
            reach:=NAV_AGENT_HORIZON*(top+linalg.length(other.velocity))
            if near.flies {
                reach+=near_sphere(near^)+near_sphere(other^)
            } else {
                if abs(to.y)>max(near.height,other.height) {continue}
                to.y=0
                reach+=near.radius+other.radius
            }
            distance2:=linalg.length2(to)
            if distance2>reach*reach {continue}
            if distance2<=held*held {within+=1}
            if near.flies {
                append(&scratch.air,ai.Avoid_Agent(3){
                    position=other.position,velocity=other.velocity,
                    radius=near_sphere(other^),ignores=!other.avoids,
                })
            } else {
                append(&scratch.ground,ai.Avoid_Agent(2){
                    position=other.position.xz,velocity=other.velocity.xz,
                    radius=other.radius,ignores=!other.avoids,
                })
            }
        }
        if held>=far || within>=ai.AVOID_MAX_NEIGHBORS {return}
    }
}

@(private)
agents_stuck :: proc(
    n:^Navigation,a:^Navigation_Agents,paths:^core.Table(Nav_Path),
    dt:f32,events:^Nav_Events,problems:^core.Problems,
) {
    for &near in a.near {
        if !near.crowd || near.flies || near.path_row==0 || near.route_slot==0 {continue}
        p:=&paths.values[near.path_row-1]
        r:=&a.routes.values[near.route_slot-1]
        if p.state==.Crossing || r.seat==.Player {continue}
        position:=near.position
        radius:=n.classes[p.class].class.radius
        // Stuck is going nowhere while what it steps aside from lets it go, or while what never
        // steps aside holds it (a player in the way): it plans again from where it is. It fails
        // only when nothing it steps aside from holds it.
        if linalg.length2(position.xz-r.anchor.xz)>radius*radius {
            r.anchor,r.stuck=position,0
        } else if going:=linalg.length2(p.velocity.xz)>0.2*0.2;going || held_ahead(a,&near,p.target,true) {
            r.stuck+=dt
            if r.stuck<NAV_BLOCKED {continue}
            if held_ahead(a,&near,p.target,false) || !going && r.stuck>=NAV_BLOCKED*2 {
                r.stuck=0
            } else if r.stuck>=NAV_BLOCKED*2 {
                core.report(problems,near.entity,"navigation.blocked","The agent cannot move along its path: mark the obstruction as a Nav_Obstacle or clear the way")
                agent_fail(p,near.entity,events)
                agent_cancel_search(a,near.entity)
            } else if r.stuck-dt<NAV_BLOCKED {
                agent_replan(p,r)
            }
        }
    }
}

// Whether something holds an agent that wants to go from just ahead of it: of
// the crowd, which goes on (still false), or what never steps aside, a
// character navigation does not move or an obstacle (still true).
@(private)
held_ahead :: proc(a:^Navigation_Agents,near:^Near,target:core.Entity,still:bool) -> bool {
    speed:=linalg.length(near.wanted.xz)
    if speed<=0.2 {return false}
    direction:=near.wanted.xz/speed
    widest:=a.widest_still if still else a.widest_ground
    query:=spatial.grid_query(&a.grid,ground_box(near.position,near.radius+widest+0.5))
    for {
        _,index,ok:=spatial.grid_query_next(&query)
        if !ok {return false}
        other:=&a.near[index]
        if other.entity==near.entity || other.entity==target {continue}
        if still ? other.route_slot!=0 : !other.crowd {continue}
        if abs(other.position.y-near.position.y)>0.5*(near.height+other.height) {continue}
        delta:=other.position.xz-near.position.xz
        along:=linalg.dot(delta,direction)
        reach:=near.radius+other.radius
        if along>0 && along<=reach+0.5 && linalg.length2(delta-along*direction)<reach*reach {
            return true
        }
    }
}

@(private)
near_sphere :: #force_inline proc "contextless" (near:Near) -> f32 {return max(near.radius,near.height*0.5)}

// The box of the neighbor grid around a point on the ground: all its cells are of one height.
@(private)
ground_box :: #force_inline proc "contextless" (at:mm.Vec3,reach:f32) -> mm.Aabb {
    return {{at.x-reach,NAV_AGENT_CELL*0.5,at.z-reach},{at.x+reach,NAV_AGENT_CELL*0.5,at.z+reach}}
}

@(private)
agents_steer :: proc(
    n:^Navigation,a:^Navigation_Agents,paths:^core.Table(Nav_Path),
    moves:^core.Table(input.Move_Input),seat_state:core.Ref(input.Seats),grounds:^core.Table(phys.Character_State,.Read),
    worlds:^core.Table(core.World_Transform,.Read),
) -> (crossing:u32) {
    for row in 0..<core.count(paths) {
        e:=core.entity_at(paths,row)
        r:=agent_route(a,e)
        if r==nil {continue}
        p:=core.at(paths,row)
        if p.state==.Crossing {crossing+=1}
        // One without a body has no locomotion to ask: agents_walk moves it.
        if r.bodyless {
            if r.steering {input.move_release(moves,seat_state,e);r.steering=false}
            continue
        }
        goes:=agent_goes(p)
        if r.seat==.Player && p.velocity!={} {core.edit_at(paths,row).velocity={}}
        if r.placed || r.seat==.Player || !goes && (r.seat==.Shared || !p.looking) {
            if r.steering {input.move_release(moves,seat_state,e);r.steering=false}
            continue
        }
        pose,_:=core.get(worlds,e)
        // The buttons stay those of its seat, or of the game: navigation asks where it goes and looks.
        previous,has:=core.get(moves,e)
        next:=input.Move_Input{look_yaw=mm.yaw_of_direction(mm.quat_forward(pose.rotation)),buttons=previous.buttons,world_velocity=true}
        if r.steering && has {
            ground,_:=core.get(grounds,e)
            next.look_yaw=mm.angle_wrap(previous.look_yaw+ground.ground_turn)
        }
        flat:=mm.Vec3{p.velocity.x,0,p.velocity.z}
        speed:=linalg.length(flat)
        if p.looking {
            to:=p.look-pose.position
            to.y=0
            if linalg.length(to)>1e-3 {next.look_yaw=mm.yaw_of_direction(to)}
        } else if speed>0.05 {next.look_yaw=mm.yaw_of_direction(flat)}
        if goes {
            if p.class>=0 && int(p.class)<n.count && class_in_volume(n,int(p.class)) {
                next.move=p.velocity
            } else if speed>1e-4 && !(p.state==.Crossing && !r.medium) {
                next.move=flat
            }
        }
        // A seated agent (Nav_Agent.seated) is steered over what its seat asked this tick.
        if row:=core.staged(moves,e);row!=nil {row^=next} else {core.add(moves,e,next)}
        r.steering=true
    }
    return
}

// Moves the agents without a Character, which nothing else moves: toward the
// velocity they chose, at the acceleration and braking of their Walk (at once
// without them), along the surface of the mesh of their class at the height of
// its detail, never through its walls; across a jump or a drop on its arc,
// along a climb or a ladder in a line. They turn toward where they go or look
// at the turn_speed of their Walk. Writes their Transform and the core.Motion
// that took them there.
@(private)
agents_walk :: proc(
    n:^Navigation,a:^Navigation_Agents,paths:^core.Table(Nav_Path),
    walks:^core.Table(locomotion.Walk,.Read),motions:^core.Table(core.Motion),placer:core.Placer,physics:core.Ref(phys.Physics_State),
    characters:^core.Table(phys.Character,.Read),dt:f32,events:^Nav_Events,
) {
    if n==nil || !(dt>0) {return}
    for near in a.near {
        if near.route_slot==0 || near.path_row==0 {continue}
        r:=&a.routes.values[near.route_slot-1]
        if !r.bodyless || r.placed {continue}
        e:=near.entity
        p:=core.edit_at(paths,near.path_row-1)
        // What owns its Transform (a pose target) moves it instead.
        pose,placed:=core.world_of(placer.transforms,placer.parents,e)
        if core.owner(placer.transforms,e)!=0 || !placed || p.class<0 || int(p.class)>=n.count {continue}
        mesh:=&n.classes[p.class].mesh
        motion,moving:=core.get(motions,e)
        walk,_:=core.get(walks,e)
        from:=pose.position
        to:=from
        switch {
        case p.state==.Crossing && !p.manual && !r.medium:
            speed:=max(walk.max_speed*0.5,0.5)
            done:bool
            to,done=agent_carried(p^,r^,speed,agent_gravity(physics,e,characters))
            if done {
                agent_crossed(n,a,p,r,e,events,nil)
                // On the polygon it lands on, at the height of its surface.
                if y,ok:=ai.nav_poly_height(mesh,ai.nav_corridor_first(&r.corridor),to);ok {to.y=y}
            }
        case p.state!=.Crossing && r.corridor.count>0:
            heading:=mm.Vec3{motion.linear.x,0,motion.linear.z}
            wanted:=mm.Vec3{p.velocity.x,0,p.velocity.z}
            rate:=walk.braking if linalg.length2(wanted)<linalg.length2(heading) else walk.acceleration
            change:=wanted-heading
            if length:=linalg.length(change);rate>0 && length>rate*dt {heading+=change*(rate*dt/length)} else {heading=wanted}
            filter:=ai.Nav_Filter{excluded=u64(near.excluded)}
            if heading!={} && ai.nav_corridor_move(&r.corridor,mesh,&filter,from+heading*dt) {to=r.corridor.position}
        }
        yaw:=mm.yaw_of_direction(mm.quat_forward(pose.rotation))
        facing:=yaw
        went:=mm.Vec3{to.x-from.x,0,to.z-from.z}
        if p.looking {
            look:=mm.Vec3{p.look.x-from.x,0,p.look.z-from.z}
            if linalg.length2(look)>1e-6 {facing=mm.yaw_of_direction(look)}
        } else if linalg.length(went)>0.05*dt {facing=mm.yaw_of_direction(went)}
        turn:=mm.angle_wrap(facing-yaw)
        if walk.turn_speed>0 {turn=clamp(turn,-walk.turn_speed*dt,walk.turn_speed*dt)}
        next:=motion
        next.linear,next.angular=(to-from)/dt,{0,turn/dt,0}
        next.awake=next.linear!={} || turn!=0
        if !moving {
            core.add(motions,e,next)
        } else if next!=motion {
            core.edit(motions,e)^=next
        }
        r.walked=to
        if to==from && turn==0 {continue}
        if row:=core.free(placer.transforms,e);row!=nil {
            core.world_set(row,placer.transforms,placer.parents,e,to,mm.quat_axis_angle({0,1,0},yaw+turn))
        }
    }
}

// Where an agent without a body is on the crossing of a link of the engine,
// r.time into it: on the arc of a jump or a drop from where it began, or along
// a climb or a ladder at speed. done: it is at its end.
@(private)
agent_carried :: proc "contextless" (p:Nav_Path,r:Nav_Route,speed,gravity:f32) -> (at:mm.Vec3,done:bool) {
    switch p.kind {
    case LINK_JUMP,LINK_DROP:
        velocity,_,total:=jump_launch(r.launch,r.to,p.kind,gravity)
        if r.time>=total {return r.to,true}
        t:=r.time
        return r.launch+velocity*t-{0,0.5*max(gravity,0.1)*t*t,0},false
    case:
        length:=linalg.length(r.to-r.launch)
        along:=r.time*speed
        if along>=length {return r.to,true}
        return r.launch+(r.to-r.launch)*(along/length),false
    }
}

// Drives the characters that cross a link of the engine: the launch of a
// jump or a drop on its first tick and the air drive along it after, or the
// way along a ladder or a climb without gravity.
@(step="fixed",stage="simulate",before="locomotion_prepare",server)
navigation_crossing :: proc(
    a:^Navigation_Agents,paths:^core.Table(Nav_Path),
    inputs:^core.Table(input.Move_Input),seat_state:core.Ref(input.Seats),places:core.Ref(core.Places),
    loco:^locomotion.Locomotion_Requests,moves:^core.Table(phys.Character_Move),
    characters:^core.Table(phys.Character,.Read),
    walks:^core.Table(locomotion.Walk,.Read),motions:^core.Table(core.Motion,.Read),worlds:^core.Table(core.World_Transform,.Read),
    physics:core.Ref(phys.Physics_State),crossings:core.Ref(Nav_Crossings),time:core.Time,
) {
    agents_places(a,paths,inputs,seat_state,places.ptr,loco)
    if !time.playing || time.dt<=0 || crossings.ptr==nil || crossings.count==0 {return}
    for row in 0..<core.count(paths) {
        p:=paths.values[row]
        if p.state!=.Crossing || p.manual {continue}
        e:=core.entity_at(paths,row)
        r:=agent_route(a,e)
        if r==nil || r.medium {continue}
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
            velocity,_,_:=jump_launch(pose.position if r.time==0 else r.from,r.to,p.kind,agent_gravity(physics,e,characters))
            flat:=mm.Vec3{velocity.x,0,velocity.z}
            if r.time==0 {
                next.value.launch=velocity-motion.linear
                next.value.flags={.Airborne}
            }
            next.value.air={velocity=flat,force=traction}
            if linalg.length(flat)>0.05 {next.value.yaw=mm.yaw_of_direction(flat)}
        case:
            speed:=max(walk.max_speed*0.5,0.5)
            d:=r.to-pose.position
            length:=linalg.length(d)
            next.value.air={velocity=d/max(length,1e-4)*min(speed,length/max(time.dt,1e-4)),force=traction}
            next.value.flags={.Airborne,.Drive_Vertical,.No_Gravity}
        }
        if move^!=next {move^=next}
    }
}
