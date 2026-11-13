package physics

import "core:hash/xxhash"
import "core:math"
import "core:math/linalg"
import "core:mem"
import "core:slice"
import "mirai:asset"
import "mirai:core"
import "mirai:host"
import "mirai:std/base"
import render "mirai:engine/render"
import sim "plugins:physics/runtime/sim"
import scene "mirai:engine/scene"
import volume "mirai:engine/volume"
import "mirai:std/jobs"
import mm "mirai:std/math"

// Keeps the simulation of a world equal to its Rigid_Body, Collider,
// Character and Joint rows, steps it and brings the poses back. The rows are
// the authority for what exists; the simulation is the authority for the pose
// of every entity that has a body or a character, which is why those
// components lock the Transform: the game moves them by requests.
//
// In the editor loop nothing is stepped: bodies follow the world transform of
// their entity and the Transform is never written.

POSE_EPSILON :: 1e-5 // m, and the same in the w of the rotation between two poses

// Bodies, compound shapes and characters a tick makes or lets go: what a
// section brings or takes in one settle spreads over the next ticks.
BODIES_PER_TICK :: 1024

@(private)
Parallel :: struct {jobs:^jobs.Job_System}

@(private)
jobs_parallel_for :: proc(link:^Parallel,count,grain:int,data:rawptr,body:proc(data:rawptr,first,last,worker:int)) {
    jobs.parallel_for(link.jobs,jobs.OWNER,count,max(grain,1),body,data)
}

@(private)
jobs_workers :: proc(job_system:^jobs.Job_System) -> int {return max(jobs.worker_count(job_system),1)}

@(private)
Sync :: struct {
    state:^Physics_State,
    app:^host.App,
    meshes:^Collider_Meshes,
    playing:bool,
    dt:f32,
    rigids:^core.Table(Rigid_Body,.Read),
    colliders:^core.Table(Collider,.Read),
    characters:^core.Table(Character,.Read),
    volumes:^core.Table(volume.Volume,.Read),
    splines:^core.Table(volume.Spline,.Read), // whose points close the loop of an Outline
    statics:^core.Table(render.Mesh_Renderer,.Read),
    parents:^core.Table(core.Parent,.Read),
    hierarchy:core.Ref(core.Hierarchy), // without it every sync is whole
    names:^core.Table(core.Name,.Read),
    collision:^Collision_Settings,
    collision_changed:bool, // the settings differ from those the filters were made with
    transforms:^core.Table(core.Transform),
    motions:^core.Table(core.Motion),
    targets:^core.Table(core.Pose_Target,.Read),
    grouped:bool, // Motion.island has the groups of this step
    character_states:^core.Table(Character_State),
    jumps:^core.Jumps, // nil for whoever steps the simulation by hand
    problems:^core.Problems,
    changes:[5]core.Changes, // of Rigid_Body, Collider, Character, Volume and Spline since Physics_State.rows_seen
    written:core.Changes,    // of Transform since the last tick: what another function wrote
    budget:int,   // what the tick may still make or let go
    waiting:bool, // something waits for the next tick
    resimulating:bool, // the tick ran before: what a job prepares is waited for here (Collider_Meshes)
    unmade:bool,  // a body or character could not be made
}

// Makes the simulation of the world when it has none, before what asks of
// its bodies in the tick looks for them, and gives the queries of the world.
@(step="fixed",loops="game editor",stage="simulate")
physics_prepare :: proc(state:^Physics_State,settings:core.Ref(Physics_Settings),queries:^core.World_Queries,job_system:^jobs.Job_System,problems:^core.Problems) {
    _=state_make(state,settings.ptr,job_system,problems)
    if queries.open==nil {queries.open=query_open}
}

@(step="fixed",loops="game editor",stage="simulate",after="places_drop")
physics_step :: proc(
    state:^Physics_State,settings:core.Ref(Physics_Settings),requests:^Body_Requests,events:^Physics_Events,meshes:^Collider_Meshes,
    app:^host.App,time:core.Time,
    rigids:^core.Table(Rigid_Body,.Read),colliders:^core.Table(Collider,.Read),characters:^core.Table(Character,.Read),moves:^core.Table(Character_Move,.Read),
    joints:^core.Table(Joint),statics:^core.Table(render.Mesh_Renderer,.Read),parents:^core.Table(core.Parent,.Read),names:^core.Table(core.Name,.Read),
    transforms:^core.Table(core.Transform),motions:^core.Table(core.Motion),targets:^core.Table(core.Pose_Target,.Read),
    character_states:^core.Table(Character_State),joint_states:^core.Table(Joint_State),fluids:^core.Table(Fluid,.Read),
    joint_requests:^Joint_Requests,
    collision:core.Ref(Collision_Settings),sync_check:core.Ref(core.Sync_Check),simulation_hash:^core.Simulation_Hash,
    jumps:^core.Jumps,problems:^core.Problems,
    gravities:^core.Table(volume.Gravity,.Read),volumes:^core.Table(volume.Volume,.Read),worlds:^core.Table(core.World_Transform,.Read),
    fluid_waves:^core.Table(Fluid_Waves,.Read),winds:^core.Table(volume.Wind,.Read),
    hierarchy:core.Ref(core.Hierarchy),splines:^core.Table(volume.Spline,.Read),ground:core.Ref(core.Ground_Queries),world:core.World_Ref,
    sections:^core.Table(scene.Scene_Reference,.Read),
) {
    if !state_make(state,settings.ptr,&app.jobs,problems) {
        core.queue_clear(&requests.queue)
        return
    }
    w:=&state.world
    defer sim.static_bounds_update(w)
    lying:=splines!=nil && core.count(splines)>0
    fluids_sync(state,fluids,volumes,transforms,parents,problems,fluid_waves,winds,worlds,splines,lying?core.ground_query(world,ground):{},lying && ground.ptr!=nil?ground.changed.items[:]:nil,sections)
    if !events_reserve(events,w.desc.event_capacity) {
        memory_problem(problems,core.NONE,"the events of the physics, so nothing is simulated in this tick")
        core.queue_clear(&requests.queue)
        return
    }
    state.pass+=1
    s:=Sync{
        state=state,app=app,meshes=meshes,playing=time.playing && time.dt>0,dt=time.dt,resimulating=time.resimulating,
        rigids=rigids,colliders=colliders,characters=characters,volumes=volumes,splines=splines,statics=statics,parents=parents,hierarchy=hierarchy,names=names,
        transforms=transforms,motions=motions,targets=targets,character_states=character_states,jumps=jumps,problems=problems,
        budget=BODIES_PER_TICK,
    }
    // Bodies that wait for the next tick keep a load from being resident.
    defer host.load_report(app,.Physics,s.waiting)
    s.collision=settings_or_default(collision.ptr)
    if state.collision!=s.collision^ {
        state.collision,s.collision_changed=s.collision^,true
        state.synced=0
    }
    if s.collision_changed || !state.pushes_set {
        rules:[COLLISION_PUSH_CAPACITY]sim.Push_Rule
        count:=collision_push_rules(s.collision,&rules)
        sim.world_set_push_rules(w,rules[:count])
        collision_surfaces_apply(w,s.collision,problems)
        state.pushes_set=true
        for push,i in s.collision.pushes {
            if push.force==0 || push.force>0 && push.force<=max(f32) && int(push.a)<COLLISION_CATEGORY_CAPACITY && int(push.b)<COLLISION_CATEGORY_CAPACITY {continue}
            core.report(problems,core.NONE,"physics.collision_push","push %d of Collision_Settings (categories '%s' and '%s', %v N) is not applied: both categories need to fit Collision_Layers, and the force finite; fix it, or clear its force",i,collision_name(app.info,Collision_Category,i64(push.a)),collision_name(app.info,Collision_Category,i64(push.b)),push.force)
        }
        at,undeclared:=0,0
        first_field:string
        first_index:int
        first_value:i64
        for field,index,value in collision_settings_undeclared(s.collision,app.info,&at) {
            if undeclared==0 {first_field,first_index,first_value=field,index,value}
            undeclared+=1
        }
        if undeclared>0 {
            core.report(problems,core.NONE,"physics.collision_settings","Collision_Settings.%s[%d] configures the value %d, which no code declares (%d entries configure undeclared values); declare it as a constant of Collision_Category or Collision_Preset (CATEGORY_NAME :: physics.Collision_Category(%d)), or remove the entry",first_field,first_index,first_value,undeclared,first_value)
        }
    }
    seen,transforms_seen:=state.rows_seen,state.transforms_seen
    s.changes={core.changes(rigids,&seen[0]),core.changes(colliders,&seen[1]),core.changes(characters,&seen[2]),volumes!=nil?core.changes(volumes,&seen[3]):{},splines!=nil?core.changes(splines,&seen[4]):{}}
    s.written=core.changes(s.transforms,&transforms_seen)
    // Nothing the bodies are made from was written: they are as they were.
    structure:=sync_structure(&s)
    synced:=sync_seen(&s,structure)==state.synced
    ran:=!synced
    // Only Transform values were written: what hangs from the rows sealed since is all that moved.
    if !synced {synced=sealed_sync(&s,structure)}
    if !synced {
        syncing:=host.load_phase_begin(app,.Physics,host.LOAD_NO_ZONE)
        defer host.load_phase_end(app,syncing,BODIES_PER_TICK-s.budget)
        collider_meshes_prune(meshes,app.assets)
        state.touched_all=true
        #reverse for &link,at in state.links.values {
            e:=state.links.entities[at]
            if link.kind==.Proxy || core.has(rigids,e) || core.has(colliders,e) || core.has(characters,e) || zone_collider(&s,e).kind!=.External {continue}
            if link.kind!=.None {
                if s.budget==0 {
                    s.waiting=true
                    continue
                }
                s.budget-=1
            }
            link_release(&s,&link)
            links_remove_at(state,at)
        }
        // Without room for their links the bodies wait for the next tick.
        if synced=links_reserve(&s);synced {
            // What does not move first: a body waits for the ground it would fall through.
            for row in 0..<core.count(colliders) {
                if e:=core.entity_at(colliders,row);!core.has(rigids,e) && !core.has(characters,e) {entity_sync(&s,e)}
            }
            for row in 0..<core.count(rigids) {
                if core.at(rigids,row).type==.Static {entity_sync(&s,core.entity_at(rigids,row))}
            }
            if volumes!=nil {
                for row in 0..<core.count(volumes) {
                    if e:=core.entity_at(volumes,row);zone_collider(&s,e).kind!=.External {entity_sync(&s,e)}
                }
            }
            for row in 0..<core.count(rigids) {entity_sync(&s,core.entity_at(rigids,row))}
            for row in 0..<core.count(colliders) {entity_sync(&s,core.entity_at(colliders,row))}
            for row in 0..<core.count(characters) {entity_sync(&s,core.entity_at(characters,row))}
            synced=!s.waiting
            // Without them sealed_sync and poses_write have no room and every tick looks at all the bodies.
            if reserve(&state.sealed,core.count(rigids)+core.count(colliders)+core.count(characters)+(volumes!=nil?core.count(volumes):0))!=nil || reserve(&state.touched,2*len(state.links.values))!=nil {
                memory_problem(problems,core.NONE,"the bodies whose Transform changes, so every tick looks at all of them")
            }
        } else {memory_problem(problems,core.NONE,"the links from entities to the simulation, so no body changes in this tick")}
    }
    if !synced {state.sealed_key=0}
    // What the tick writes itself, the poses of its bodies, is not a change to them.
    defer if synced {
        structure=sync_structure(&s)
        state.synced=sync_seen(&s,structure)
        if ran {state.sealed_key,state.unmade=sealed_key(&s,structure),s.unmade}
        state.rows_seen=seen
        _=core.changes(s.transforms,&state.transforms_seen)
    }

    asked:=core.take(&requests.queue)
    requests_apply(&s,asked)
    if s.playing {joints_sync(&s,joints,joint_states)}
    joint_requests_apply(&s,joints,joint_states,joint_requests)
    if !sim.world_rebuild_static(w) {memory_problem(problems,core.NONE,"the rebuild of the tree of the static shapes")}
    if s.playing {
        for row in 0..<core.count(characters) {
            e:=core.entity_at(characters,row)
            l:=link_find(state,e)
            if l==nil || l.kind!=.Character {continue}
            // One a following target leads does not walk: it is put at the pose.
            if h:=held_of(state,e);h!=nil && .Target in h.by {
                sim.character_set_move(w,l.character,{})
                continue
            }
            move,has:=core.get(moves,e)
            if has {sim.character_set_move(w,l.character,move.value)}
            character_height_set(&s,l,e,core.at(characters,row),move.height)
        }
    }

    events_forward(&s,events,&state.forwarded)
    if !s.playing {return}

    // A held body heads for its pose in every step; what nothing steers any more leaves the list.
    #reverse for h,at in state.held {
        l:=link_find(state,h.entity)
        if l==nil || h.by=={} && h.placed==0 {
            unordered_remove(&state.held,at)
            continue
        }
        if (l.kind==.Body || l.kind==.Proxy) && (.Target in h.by || .Manipulation in h.by && h.follow) && sim.body_valid(w,l.body) {
            pose:=hold_pose(h)
            sim.body_set_kinematic_target(w,l.body,pose.p,pose.q,s.dt)
        }
    }
    parallel:=Parallel{&app.jobs}
    w.desc.parallel_user=&parallel
    if gravities!=nil {gravity_apply(state,gravities,{volumes,worlds,parents,sections,splines},problems)}
    sim.world_step(w,time.dt)
    w.desc.parallel_user=nil
    strains_apply(w,asked)
    step_followed(state)
    // A manipulation that asked to let go does once its body reaches the pose.
    for &h in state.held {
        if !h.release || h.by!={.Manipulation} {continue}
        l:=link_find(state,h.entity)
        if l==nil || !sim.body_valid(w,l.body) || pose_differs(sim.body_transform(w,l.body),h.pose[.Manipulation]) {continue}
        pose_write(&s,l,h.entity,sim.body_transform(w,l.body))
        hold_end(state,&h,l,.Manipulation,rigids)
        link_touch(state,l)
    }

    // What another owner places has to reach what touches it: its groups are kept while some entity has a target.
    s.grouped=core.count(targets)>0
    if s.grouped {sim.bodies_group(w)}
    poses_write(&s)
    sleepers:=sim.world_events(w).sleep
    for event in sleepers {
        e:=core.Entity(event.user_data)
        l:=link_find(state,e)
        if l==nil || l.kind!=.Body || !sim.body_valid(w,l.body) {continue}
        pose_write(&s,l,e,sim.body_transform(w,l.body))
    }
    state.forwarded={}
    events_forward(&s,events,&state.forwarded)
    joints_events(&s,events,joint_states)
    if sync_check.ptr!=nil && sync_check.on {simulation_hash.value=sim.world_hash(w)}
}

// The vertical of every character, for what reads it outside physics: the
// camera that follows it, the game.
@(step="fixed",loops="game",stage="simulate",after="physics_step")
physics_verticals :: proc(state:core.Ref(Physics_State),characters:^core.Table(Character,.Read),verticals:^core.Table(core.Vertical)) {
    if state.ptr==nil || !state.ready {return}
    for row in 0..<core.count(characters) {
        e:=core.entity_at(characters,row)
        l:=link_find(state.ptr,e)
        if l==nil || l.kind!=.Character || !sim.character_valid(&state.world,l.character) {continue}
        found:=sim.character_state(&state.world,l.character)
        next:=core.Vertical{found.up_frame,found.ground_turn}
        if at:=core.row_of(verticals,e);at<0 {
            core.add(verticals,e,next)
        } else {core.edit_at(verticals,at)^=next}
    }
    for row:=core.count(verticals)-1;row>=0;row-=1 {
        if e:=core.entity_at(verticals,row);!core.has(characters,e) {core.remove(verticals,e)}
    }
}

// The versions of the tables and assets the bodies are made from.
@(private)
sync_seen :: proc(s:^Sync,structure:u64) -> u64 {return structure+core.version(s.transforms)}

// Those versions but the values of Transform.
@(private)
sync_structure :: proc(s:^Sync) -> u64 {
    seen:=core.version(s.rigids)+core.layout(s.rigids)+core.version(s.colliders)+core.layout(s.colliders)+core.version(s.characters)+core.layout(s.characters)
    seen+=core.version(s.statics)+core.layout(s.statics)+core.version(s.parents)+core.layout(s.parents)+core.layout(s.transforms)
    if s.volumes!=nil {seen+=core.version(s.volumes)+core.layout(s.volumes)}
    if s.splines!=nil {seen+=core.version(s.splines)+core.layout(s.splines)}
    return seen+u64(s.state.epoch)+(s.app.assets!=nil?s.app.assets.structure:0)
}

// What else a whole sync reads of every body: whether it steps, the rows it
// gives them, the bodies of the simulation and the revision of the assets.
@(private)
sealed_key :: proc(s:^Sync,structure:u64) -> u64 {
    key:=structure
    revision:=s.app.assets!=nil?s.app.assets.revision:0
    for value in ([5]u64{u64(s.playing),core.layout(s.motions),core.layout(s.character_states),u64(s.state.world.body_count),revision}) {
        key=base.hash_mix(key,value)
    }
    return key
}

// Syncs only the bodies whose world pose another function changed: those of
// the Transform rows sealed since the last tick, and what hangs from them, in
// the order a whole sync reaches them. A whole sync leaves every other body as
// it is, so both give the same simulation. False when the sync has to be
// whole: something besides the Transform values changed, the hierarchy has a
// cycle, a body waits to be made, or the rows were not seen.
@(private)
sealed_sync :: proc(s:^Sync,structure:u64) -> bool {
    state:=s.state
    h:=s.hierarchy
    if h.ptr==nil || len(h.cut)>0 || state.unmade || s.collision_changed || sealed_key(s,structure)!=state.sealed_key {return false}
    seen:=state.transforms_seen
    c:=core.changes(s.transforms,&seen)
    if c.all {return false}
    clear(&state.sealed)
    for row in core.each_changed(s.transforms,&c) {
        root:=core.entity_at(s.transforms,row)
        if sealed_above(s.transforms,h,root,c) {continue}
        for at:=root;at!=core.NONE;at=core.subtree_next(h,root,at) {
            order,body:=sync_order(s,at)
            if !body {continue}
            if len(state.sealed)==cap(state.sealed) {return false}
            l:=link_find(state,at)
            if l==nil || l.kind==.Body && !sim.body_valid(&state.world,l.body) || l.kind==.Character && !sim.character_valid(&state.world,l.character) {return false}
            append(&state.sealed,Sealed_Body{order,at})
        }
    }
    slice.sort_by(state.sealed[:],proc(a,b:Sealed_Body) -> bool {return a.order<b.order})
    for body in state.sealed {entity_sync(s,body.entity)}
    return !s.waiting
}

// Whether something e hangs from has its Transform sealed since: its walk takes e.
@(private)
sealed_above :: proc(locals:^core.Table(core.Transform,$A),h:core.Ref(core.Hierarchy),e:core.Entity,c:core.Changes) -> bool {
    for at:=core.parent_of(h,e);at!=core.NONE;at=core.parent_of(h,at) {
        if row:=core.row_of(locals,at);row>=0 && core.changed(locals,c,row) {return true}
    }
    return false
}

// Where the loops of a whole sync reach an entity first; false for one without a body.
@(private)
sync_order :: proc(s:^Sync,e:core.Entity) -> (order:u64,body:bool) {
    rigid,collider,character:=core.row_of(s.rigids,e),core.row_of(s.colliders,e),core.row_of(s.characters,e)
    switch {
    case collider>=0 && rigid<0 && character<0:             return u64(collider),true
    case rigid>=0 && core.at(s.rigids,rigid).type==.Static: return 1<<32|u64(rigid),true
    case rigid>=0:                                          return 2<<32|u64(rigid),true
    case collider>=0:                                       return 3<<32|u64(collider),true
    case character>=0:                                      return 4<<32|u64(character),true
    case zone_collider(s,e).kind!=.External:                return 5<<32|u64(core.row_of(s.volumes,e)),true
    }
    return
}

// The sensor the Volume of an entity without a Collider, Rigid_Body or Character makes: a box, a sphere or
// the convex pieces of an outline (zone_pieces) that block nothing and report the bodies that go in and out
// of it (Physics_Events.overlap_begin and overlap_end), by the overlaps of the solver as every other shape.
// External without one: a plane or the whole world has no end the simulation can hold.
@(private)
zone_collider :: proc(s:^Sync,e:core.Entity) -> (collider:Collider) {
    collider.kind=.External
    if s.volumes==nil || core.has(s.colliders,e) || core.has(s.rigids,e) || core.has(s.characters,e) {return}
    v,found:=core.get(s.volumes,e)
    if !found || !volume.valid(v,mm.TRANSFORM_IDENTITY,volume.spline_outline(s.splines,e)) {return}
    #partial switch v.shape {
    case .Box:     collider=collider_box(v.extents)
    case .Sphere:  collider=collider_sphere(v.extents.x)
    case .Outline: collider=collider_box(v.extents);collider.kind=.Hull
    case:          return
    }
    collider.preset,collider.density=PRESET_TRIGGER,0
    return
}

@(private)
link_find :: proc(state:^Physics_State,e:core.Entity) -> ^Link {
    return state==nil?nil:core.entity_map_get(&state.links,e)
}

// Has the next step bring back the rows of a link the sync, a request or a pose target addressed: its body
// may have changed without a step moving it, as one left at rest. poses_write looks only at these and at the
// bodies the step moved; without room, at every link.
@(private)
link_touch :: proc(state:^Physics_State,l:^Link) {
    if state.touched_all {return}
    if len(state.touched)==cap(state.touched) {
        state.touched_all=true
        return
    }
    append(&state.touched,u32(link_index(state,l)))
}

@(private)
link_index :: proc "contextless" (state:^Physics_State,l:^Link) -> int {return int(mem.ptr_sub(l,&state.links.values[0]))}

// The link of an entity; the one of another generation of its index is
// released first. nil without memory.
@(private)
link_at :: proc(s:^Sync,e:core.Entity) -> ^Link {
    links:=&s.state.links
    if l:=core.entity_map_get(links,e);l!=nil {return l}
    if held:=core.entity_map_held(links,e);held!=core.NONE {link_release(s,core.entity_map_get(links,held))}
    return links_put(s.state,e,Link{})
}

// Gives an entity a link, or replaces the one of its index, stamping what it writes. nil without memory.
@(private)
links_put :: proc(state:^Physics_State,e:core.Entity,link:Link) -> ^Link {
    if !links_room(state,len(state.links.values)+1,core.entity_index(e)+1) {return nil}
    l,ok:=core.entity_map_put(&state.links,e,link)
    if !ok {return nil}
    slot_stamp(state,state.link_stamps[:],link_index(state,l))
    return l
}

// Takes out the link at an index of the values: the last one takes its place. Stamps what it moves.
@(private)
links_remove_at :: proc(state:^Physics_State,at:int) {
    slot_stamp(state,state.link_stamps[:],at)
    slot_stamp(state,state.link_stamps[:],len(state.links.values)-1)
    core.entity_map_remove_at(&state.links,at)
}

// Room for count links and for the entities of index below indices, with a stamp for each chunk of them.
@(private)
links_room :: proc(state:^Physics_State,count,indices:int) -> bool {
    return core.entity_map_reserve(&state.links,count,indices) && resize(&state.link_stamps,max(len(state.link_stamps),base.chunks_of(cap(state.links.values))))==nil
}

// Room for a link for every row the tick can reach, so that no pointer to one
// is lost while it runs. False without memory.
@(private)
links_reserve :: proc(s:^Sync) -> bool {
    most:=0
    for row in 0..<core.count(s.rigids) {most=max(most,core.entity_index(core.entity_at(s.rigids,row)))}
    for row in 0..<core.count(s.colliders) {most=max(most,core.entity_index(core.entity_at(s.colliders,row)))}
    for row in 0..<core.count(s.characters) {most=max(most,core.entity_index(core.entity_at(s.characters,row)))}
    rows:=core.count(s.rigids)+core.count(s.colliders)+core.count(s.characters)
    state:=s.state
    return links_room(state,len(state.links.values)+rows,most+1) && resize(&state.visited,cap(state.links.values))==nil
}

// Whether the row of e in a table is among the changes.
@(private)
row_changed :: proc "contextless" (r:^core.Table($T,$A),c:core.Changes,e:core.Entity) -> bool {
    row:=core.row_of(r,e)
    return row>=0 && core.changed(r,c,row)
}

@(private)
world_pose :: proc(s:^Sync,e:core.Entity) -> mm.Transform {
    world,_:=core.world_of(s.transforms,s.parents,e)
    return world
}

// The Transform values that put an entity at a world pose under its parent: what a library that moves an entity writes.
local_of :: proc(locals:^core.Table(core.Transform,$A),parents:^core.Table(core.Parent,$B),e:core.Entity,pose:sim.Transform) -> (position:[3]f32,rotation:mm.Quat,ok:bool) {
    parent,_:=core.get(parents,e)
    local:=core.local_under(locals,parents,parent.entity,{pose.p,pose.q,{1,1,1}}) or_return
    return local.position,local.rotation,true
}

@(private)
pose_differs :: proc "contextless" (current:sim.Transform,target:sim.Transform) -> bool {
    offset:=current.p-target.p
    a,b:=current.q,target.q
    alignment:=abs(a.w*b.w+a.x*b.x+a.y*b.y+a.z*b.z)
    return linalg.dot(offset,offset)>POSE_EPSILON*POSE_EPSILON || alignment<1-POSE_EPSILON
}

// Writes a world pose into the Transform of the entity.
@(private)
pose_write :: proc(s:^Sync,l:^Link,e:core.Entity,pose:sim.Transform) {
    row:=core.row_of(s.transforms,e)
    if row<0 {return}
    position,rotation,ok:=local_of(s.transforms,s.parents,e,pose)
    if !ok {return}
    local:=s.transforms.values[row]
    if local.position==position && local.rotation==rotation {return}
    written:=core.edit_at(s.transforms,row)
    written.position,written.rotation=position,rotation
}

// Whether another function moved e by its Transform since the last tick: it holds other than what the
// simulation, at pose, writes. A write that leaves it where the simulation has it (moved: false) is no
// teleport: it hangs from another parent, as a section that something left gives it to the next.
@(private)
foreign_write :: proc(s:^Sync,e:core.Entity,component:string,pose:sim.Transform,moved:bool) -> bool {
    if !moved || !row_changed(s.transforms,s.written,e) {return false}
    if local,has:=core.get(s.transforms,e);has {
        if position,rotation,ok:=local_of(s.transforms,s.parents,e,pose);ok && local.position==position && local.rotation==rotation {return false}
    }
    core.fail(
        "Entity %q has a %s, which owns its Transform, but another function wrote its position or rotation: use core.place(placer,entity,position,rotation) (physics.move_kinematic for a kinematic body)",
        core.name_get(s.names,e),component,
    )
    return true
}

@(private)
entity_sync :: proc(s:^Sync,e:core.Entity) {
    state:=s.state
    l:=link_at(s,e)
    // A proxy's body is another library's: a breakable replaces the Collider and Rigid_Body of its entity.
    if l==nil || l.kind==.Proxy {return}
    at:=link_index(state,l)
    if at>=len(state.visited) && resize(&state.visited,len(state.links.values))!=nil || state.visited[at]==state.pass {return}
    charged:=l.kind==.None
    if charged {
        if s.budget==0 {
            s.waiting=true
            return
        }
        s.budget-=1
    }
    // What it did not make, as a body that waits for its geometry, takes nothing of the budget.
    defer if charged && l.kind==.None {s.budget+=1}
    state.visited[at]=state.pass
    link_touch(state,l)
    was:=l^
    defer if l^!=was {slot_stamp(state,state.link_stamps[:],at)}
    if world:=world_pose(s,e);!sim.finite(world.position,world.scale) || !sim.finite(world.rotation) {
        core.report(s.problems,e,"physics.transform","its world Transform is not finite (position %v, rotation %v, scale %v), so the simulation keeps its body as it was: write finite values to its Transform and to those of its parents",world.position,world.rotation,world.scale)
        return
    }
    rigid,has_rigid:=core.get(s.rigids,e)
    collider,has_collider:=core.get(s.colliders,e)
    config,has_character:=core.get(s.characters,e)
    collider_changed:=row_changed(s.colliders,s.changes[1],e)
    if zone:=zone_collider(s,e);zone.kind!=.External {collider,has_collider,collider_changed=zone,true,row_changed(s.volumes,s.changes[3],e) || s.splines!=nil && row_changed(s.splines,s.changes[4],e)}
    if has_collider && collider.kind==.External {has_collider=false}
    owner:=core.NONE
    if !has_rigid && !has_character && has_collider {owner=compound_owner(s,e)}
    if has_collider && !has_character && collider.kind==.Auto {
        moving:=has_rigid && rigid.type!=.Static
        if held,on:=core.get(s.rigids,owner);owner!=core.NONE && on {moving=held.type!=.Static}
        kind,waiting:=auto_kind(s,e,moving)
        if waiting {
            s.waiting=true
            return
        }
        collider.kind=kind
    }
    switch {
    case has_character:
        if l.kind!=.Character && l.kind!=.None {link_release(s,l)}
        character_sync(s,e,l,config,collider,has_collider,collider_changed || row_changed(s.characters,s.changes[2],e))
    case owner!=core.NONE:
        compound_sync(s,e,l,collider,owner,collider_changed)
    case has_rigid || has_collider:
        if l.kind==.Compound || l.kind==.Character {link_release(s,l)}
        body_sync(s,e,l,rigid,has_rigid,row_changed(s.rigids,s.changes[0],e),collider,has_collider,collider_changed)
    }
}

// Taking a row again, as after a rollback that brings it back, leaves the simulation as it is: each setter acts
// only where the simulation differs.
@(private)
body_sync :: proc(s:^Sync,e:core.Entity,l:^Link,rigid:Rigid_Body,has_rigid,rigid_changed:bool,collider:Collider,has_collider,collider_changed:bool) {
    state:=s.state
    w:=&state.world
    world:=world_pose(s,e)
    pose:=sim.Transform{world.position,world.rotation}
    scale:=world.scale
    // Its shape waits for its geometry: the body stays as it is until then.
    if has_collider && collider_geometry_waits(s,e,collider,scale) {
        s.waiting=true
        return
    }
    type:=has_rigid?rigid.type:Body_Type.Static
    created,mass_changed:=false,false
    if l.kind!=.Body || !sim.body_valid(w,l.body) {
        link_release(s,l)
        desc:=sim.BODY_DESC_DEFAULT
        desc.type,desc.position,desc.rotation,desc.user_data=type,pose.p,pose.q,u64(e)
        if has_rigid {
            desc.linear_damping,desc.angular_damping=rigid.linear_damping,rigid.angular_damping
            desc.gravity_scale,desc.locks,desc.bullet=rigid.gravity_scale,body_locks(rigid.locks),rigid.bullet
        }
        l.body=sim.body_create(w,desc)
        if l.body=={} {
            s.unmade=true
            core.report(s.problems,e,"physics.bodies","this entity has no body in the simulation: the %d bodies of Physics_Settings.bodies are in use; raise bodies, or remove bodies",w.desc.body_capacity)
            return
        }
        l.kind=.Body
        state.stats.bodies_created+=1
        created,mass_changed=true,true
        if linear,angular:=made_velocity(s,e);type!=.Static && (linear!={} || angular!={}) {
            sim.body_set_velocity(w,l.body,linear,angular)
        }
        target_made(s,l,e)
    } else {
        // A body held as kinematic keeps that type until the last one that holds it so lets go.
        if h:=held_of(state,e);sim.body_type(w,l.body)!=type && (h==nil || !held_kinematic(h^)) {
            sim.body_set_type(w,l.body,type)
            mass_changed=true
        }
        if has_rigid && rigid_changed {
            sim.body_set_damping(w,l.body,rigid.linear_damping,rigid.angular_damping)
            sim.body_set_bullet(w,l.body,rigid.bullet)
            if sim.body_gravity_scale(w,l.body)!=rigid.gravity_scale {sim.body_set_gravity_scale(w,l.body,rigid.gravity_scale)}
            if locks:=body_locks(rigid.locks);sim.body_locks(w,l.body)!=locks {sim.body_set_locks(w,l.body,locks)}
            mass_changed=true
        }
    }

    if !has_collider {
        if l.shape!={} {
            sim.shape_destroy(w,l.shape)
            l.shape={}
            state.stats.shapes_destroyed+=1+pieces_shapes_destroy(s,l)
            mass_changed=true
        }
        geometry_release(s,l)
        l.made=0
    } else {
        shown:=shown_of(s,e,collider)
        filter:=collision_of(s,e,collider,collider_changed)
        key:=shape_key(collider,scale,mm.TRANSFORM_IDENTITY,shown)
        changed:=created || l.made!=key
        if changed && !created && shown.generated && sim.shape_valid(w,l.shape) && (!collider_changed || shape_material_same(w,l.shape,collider)) && collider_geometry_unchanged(s,l,e,collider,scale) {
            l.made=key
            changed=false
        }
        if changed || link_shapes_lost(s,l) {
            if l.shape!={} {
                sim.shape_destroy(w,l.shape)
                state.stats.shapes_destroyed+=1+pieces_shapes_destroy(s,l)
            }
            geometry_release(s,l)
            if _,sheared:=compound_relative(s,e,core.NONE);sheared {shape_problem(s,e,collider,.Sheared)}
            if failure:=collider_shapes_make(s,l,e,l.body,collider,scale,filter);failure!=.None {shape_problem(s,e,collider,failure)}
            l.made=key
            mass_changed=true
        } else {shapes_restyle(s,l,collider,filter,collider_changed)}
    }
    if mass_changed {body_mass_update(w,l.body,rigid,has_rigid)}

    switch {
    case created:
    case s.playing && (has_rigid || sim.body_type(w,l.body)!=.Static):
        if at:=sim.body_transform(w,l.body);foreign_write(s,e,has_rigid?"Rigid_Body":"physics manipulation",at,pose_differs(at,pose)) {
            sim.body_set_transform(w,l.body,pose.p,pose.q)
            state.stats.teleports+=1
        }
    case pose_differs(sim.body_transform(w,l.body),pose):
        sim.body_set_transform(w,l.body,pose.p,pose.q)
        state.stats.teleports+=1
    }
    if s.playing && has_rigid && type!=.Static && !core.has(s.motions,e) {core.add(s.motions,e,core.Motion{})}
}

// Whether a shape keeps the friction, restitution and density of a collider, as the simulation clamps them:
// with the same geometry where the collider puts it, a Collider taken again (a copy, a rollback) is the shape it has.
@(private)
shape_material_same :: proc(w:^sim.World,shape:sim.Shape_Handle,collider:Collider) -> bool {
    friction,restitution:=sim.shape_material(w,shape)
    return friction==max(collider.friction,0) && restitution==clamp(collider.restitution,0,1) && sim.shape_density(w,shape)==max(collider.density,0)
}

// What the shapes of a collider are made from, all but their filter and surface: where the entity is in the
// frame of its body, its scale and what it shows.
@(private)
shape_key :: proc(collider:Collider,scale:[3]f32,relative:mm.Transform,shown:Shown) -> u64 {
    Key :: struct {kind:Collider_Kind,size:[3]f32,convex_radius:f32,center:[3]f32,friction,restitution,density:f32,scale:[3]f32,relative:mm.Transform,shown:Shown}
    key:Key
    key.kind,key.size,key.convex_radius,key.center=collider.kind,collider.size,collider.convex_radius,collider.center
    key.friction,key.restitution,key.density,key.scale,key.relative,key.shown=collider.friction,collider.restitution,collider.density,scale,relative,shown
    return xxhash.XXH3_64_with_seed(mem.ptr_to_bytes(&key),0)
}

@(private)
compound_owner :: proc(s:^Sync,e:core.Entity) -> core.Entity {
    parent,_:=core.get(s.parents,e)
    return core.ancestor_with(s.parents,s.rigids,parent.entity)
}

// Where e is in the frame of the body of owner, which has no scale: its
// Transform and those between the two, under the world scale of owner. It
// does not depend on where the body is, so it only changes with them. With
// owner NONE, where e is in the world. sheared: a Transform of the chain turns
// under a scale that is not the same along the turned axes, a shear that a
// shape cannot take.
@(private)
compound_relative :: proc(s:^Sync,e,owner:core.Entity) -> (relative:mm.Transform,sheared:bool) {
    chain:[64]core.Entity
    depth:=0
    for at:=e;at!=owner && at!=core.NONE && depth<len(chain); {
        chain[depth]=at
        depth+=1
        parent,ok:=core.get(s.parents,at)
        at=ok?parent.entity:core.NONE
    }
    relative=mm.TRANSFORM_IDENTITY
    if above,ok:=core.world_of(s.transforms,s.parents,owner);ok {relative.scale=above.scale}
    #reverse for at in chain[:depth] {
        local,ok:=core.get(s.transforms,at)
        if !ok {continue}
        sheared||=!scale_turns(local.rotation,relative.scale)
        relative=mm.transform_compose(relative,core.to_math(local))
    }
    return
}

// Whether a scale under a rotation is still a scale along the turned axes: R^T S R is diagonal (Jolt's
// ScaleHelpers::CanScaleBeRotated), up to SHEAR_TOLERANCE of the largest scale, so that the noise of a
// rotation the simulation wrote is no shear.
@(private) SHEAR_TOLERANCE :: 1e-4 // of the size: a shear below it moves no point of a shape 0.1 mm per meter
@(private)
scale_turns :: proc "contextless" (rotation:mm.Quat,scale:[3]f32) -> bool {
    r:=linalg.matrix3_from_quaternion(rotation)
    tolerance:=SHEAR_TOLERANCE*max(abs(scale.x),abs(scale.y),abs(scale.z))
    for i in 0..<3 {
        for j in i+1..<3 {
            if !(abs(r[0,i]*scale.x*r[0,j]+r[1,i]*scale.y*r[1,j]+r[2,i]*scale.z*r[2,j])<=tolerance) {return false}
        }
    }
    return true
}

@(private)
compound_sync :: proc(s:^Sync,e:core.Entity,l:^Link,collider:Collider,owner:core.Entity,collider_changed:bool) {
    state:=s.state
    w:=&state.world
    if l.kind==.Body || l.kind==.Character || l.kind==.Compound && l.owner!=owner {link_release(s,l)}
    holder:=link_at(s,owner)
    if holder!=nil {entity_sync(s,owner)}
    if holder==nil || holder.kind!=.Body || !sim.body_valid(w,holder.body) {
        link_release(s,l)
        s.unmade=true
        return
    }
    relative,sheared:=compound_relative(s,e,owner)
    scale:=relative.scale
    if collider_geometry_waits(s,e,collider,scale) {
        s.waiting=true
        return
    }
    shown:=shown_of(s,e,collider)
    filter:=collision_of(s,e,collider,collider_changed)
    key:=shape_key(collider,scale,relative,shown)
    changed:=l.kind!=.Compound || l.made!=key || l.body!=holder.body
    if changed && l.kind==.Compound && l.body==holder.body && shown.generated && sim.shape_valid(w,l.shape) && (!collider_changed || shape_material_same(w,l.shape,collider)) && collider_geometry_unchanged(s,l,e,collider,scale,relative) {
        l.made=key
        changed=false
    }
    if !changed && !link_shapes_lost(s,l) {
        shapes_restyle(s,l,collider,filter,collider_changed)
        return
    }
    if sim.shape_valid(w,l.shape) {
        sim.shape_destroy(w,l.shape)
        state.stats.shapes_destroyed+=1
    }
    state.stats.shapes_destroyed+=pieces_shapes_destroy(s,l)
    geometry_release(s,l)
    if sheared {shape_problem(s,e,collider,.Sheared)}
    if failure:=collider_shapes_make(s,l,e,holder.body,collider,scale,filter,&relative);failure!=.None {shape_problem(s,e,collider,failure)}
    l.kind,l.owner,l.body,l.made=.Compound,owner,holder.body,key
}

// What a Hull, Mesh or Heightfield collider shows. A mesh without a file is an immutable generated id, also
// once its asset is freed: other asset changes do not make its shapes again.
@(private)
shown_of :: proc(s:^Sync,e:core.Entity,collider:Collider) -> (shown:Shown) {
    if collider.kind!=.Hull && collider.kind!=.Mesh && collider.kind!=.Heightfield && collider.kind!=.Auto {return}
    if static,has:=core.get(s.statics,e);has {shown.mesh,shown.shape=static.mesh,static.shape}
    if s.app.assets==nil {return}
    record,file:=asset.registry_find(&s.app.assets.registry,shown.mesh)
    shown.generated=host.assets_mesh_generated(s.app.assets,shown.mesh) || shown.mesh!={} && !file
    if file && !shown.generated {shown.size,shown.time=record.size,record.time}
    return
}

// A dynamic body weighs what its Rigid_Body says, or what its shapes do; they place its center and inertia,
// and the simulation keeps both as they change.
@(private)
body_mass_update :: proc(w:^sim.World,body:sim.Body_Handle,rigid:Rigid_Body,has_rigid:bool) {
    if has_rigid && rigid.type==.Dynamic {sim.body_set_mass(w,body,rigid.mass)}
}

// Ends what the link holds: the body, or the shape of a compound, and the geometry made for it.
@(private)
link_release :: proc(s:^Sync,l:^Link) {
    state:=s.state
    w:=&state.world
    switch l.kind {
    case .None,.Proxy:
    case .Compound:
        destroyed:=pieces_shapes_destroy(s,l)
        if sim.shape_valid(w,l.shape) {
            sim.shape_destroy(w,l.shape)
            destroyed+=1
        }
        state.stats.shapes_destroyed+=destroyed
        geometry_release(s,l)
    case .Body:
        // A body the simulation ended by itself (debris, the bodies of a destructible) took its shapes with it, not their geometry.
        if sim.body_valid(w,l.body) {
            sim.body_destroy(w,l.body)
            state.stats.bodies_destroyed+=1
            if l.shape!={} {state.stats.shapes_destroyed+=1+u64(l.pieces.count)}
        }
        geometry_release(s,l)
    case .Character:
        if sim.character_valid(w,l.character) {
            sim.character_destroy(w,l.character)
            state.stats.characters_destroyed+=1
        }
    }
    l^={}
}

HEIGHT_EPSILON :: f32(1e-4) // m of capsule height that are no change

// Makes the capsule of a character as tall as its move asks (0: that of its Collider, which it is
// never taller than) before it steps: shorter at once, taller when nothing over it is in the way.
// Kept shorter than asked by what is over it, it is cramped.
@(private)
character_height_set :: proc(s:^Sync,l:^Link,e:core.Entity,config:Character,asked:f32) {
    w:=&s.state.world
    capsule,_:=core.get(s.colliders,e)
    world,_:=core.world_of(s.transforms,s.parents,e)
    full:=character_desc(config,capsule,linalg.abs(world.scale),{},e).height
    want:=asked
    if !(want>0) || want>full {want=full}
    if abs(sim.character_desc(w,l.character).height-want)>HEIGHT_EPSILON {_=sim.character_set_height(w,l.character,want)}
    cramped:=sim.character_desc(w,l.character).height<want-HEIGHT_EPSILON
    if state:=core.edit(s.character_states,e);state!=nil {state.cramped=cramped}
}

// The capsule stands on the feet: its center and surface are those of the controller.
@(private)
character_desc :: proc "contextless" (c:Character,capsule:Collider,scale:[3]f32,filter:sim.Filter,e:core.Entity) -> sim.Character_Desc {
    desc:=sim.CHARACTER_DESC_DEFAULT
    radius:=capsule.size.x*max(scale.x,scale.z)
    half:=capsule.size.y*scale.y
    desc.radius,desc.height,desc.mass=radius,2*(radius+half),c.mass
    if desc.mass<=0 {desc.mass=capsule.density*(2*linalg.PI*radius*radius*half+4.0/3*linalg.PI*radius*radius*radius)}
    desc.max_slope,desc.step_height=c.max_slope,c.step_height
    desc.traction_force,desc.adhesion_force,desc.gravity_scale=c.traction_force,c.adhesion_force,c.gravity_scale
    desc.push_force,desc.density,desc.drag,desc.up_speed=c.push_force,c.density,capsule.drag,c.up_speed
    desc.filter=filter
    desc.user_data=u64(e)
    return desc
}

// What a character is made from; the rest of its Character and its Collider changes it as it is.
@(private)
character_key :: proc(c:Character,capsule:Collider,scale:[3]f32) -> u64 {
    return base.hash_mix(shape_key(capsule,scale,mm.TRANSFORM_IDENTITY,{}),u64(transmute(u32)c.mass)|u64(transmute(u32)c.step_height)<<32)
}

@(private)
yaw_of :: proc "contextless" (rotation:mm.Quat) -> f32 {
    forward:=mm.quat_forward(rotation)
    return mm.yaw_of_direction(forward)
}

// The look yaw of a character's body rotation (its -Z faces the look) in the frame of the vertical it has, or
// in the one it takes from its rotation when it is made from the identity.
look_yaw_of :: proc "contextless" (frame,rotation:mm.Quat) -> f32 {
    return sim.up_frame_yaw(sim.up_frame_turn(frame,mm.quat_rotate(rotation,{0,1,0})),rotation)
}

@(private)
character_sync :: proc(s:^Sync,e:core.Entity,l:^Link,config:Character,capsule:Collider,has_capsule,changed:bool) {
    state:=s.state
    w:=&state.world
    if !has_capsule || capsule.kind!=.Capsule {
        link_release(s,l)
        if changed {
            core.report(s.problems,e,"physics.character_capsule","its Character is not made: it moves as the Collider of kind Capsule of the entity, and it has %s; give it physics.collider_character() or a capsule of its own",has_capsule?"another kind":"none")
        }
        return
    }
    world:=world_pose(s,e)
    scale:=linalg.abs(world.scale)
    filter:=collision_of(s,e,capsule,changed)
    desc:=character_desc(config,capsule,scale,filter,e)
    key:=character_key(config,capsule,scale)
    if l.kind==.Character && sim.character_valid(w,l.character) && l.made==key {
        current:=sim.character_desc(w,l.character)
        next:=desc
        next.radius,next.height,next.mass,next.step_height,next.filter=current.radius,current.height,current.mass,current.step_height,current.filter
        if next.drag==0 {next.drag=sim.CD_HUMAN}
        if next!=current {sim.character_set_desc(w,l.character,desc)}
        body:=sim.character_body(w,l.character)
        // Its move turns it: the angular locks are always on.
        if locks:=body_locks(config.locks);sim.body_locks(w,body)!=locks+{.Lock_Angular_X,.Lock_Angular_Y,.Lock_Angular_Z} {sim.character_set_locks(w,l.character,locks)}
        if current.filter!=filter {sim.character_set_filter(w,l.character,filter)}
        if changed {surface_set(w,sim.character_shape(w,l.character),capsule)}
        held:=sim.body_rotation(w,body)
        offset:=sim.character_position(w,l.character)-world.position
        moved:=linalg.dot(offset,offset)>POSE_EPSILON*POSE_EPSILON
        if s.playing {
            character_rows(s,e)
            // A write that turns it where it is cannot be taken: its turn is that of its move and its vertical.
            if !moved && row_changed(s.transforms,s.written,e) && pose_differs({world.position,held},{world.position,world.rotation}) {
                core.report(s.problems,e,"physics.character_turn","Character %q was turned by another function while it plays, and a Character turns with its move and its vertical: turn it with the look of its Move_Input, or put it turned with core.place(placer,entity,position,rotation)",core.name_get(s.names,e))
            }
            if foreign_write(s,e,"Character",sim.body_transform(w,body),moved) {
                sim.character_set_position(w,l.character,world.position)
                state.stats.teleports+=1
            }
            return
        }
        if moved {
            sim.character_set_position(w,l.character,world.position)
            state.stats.teleports+=1
        }
        if pose_differs({world.position,held},{world.position,world.rotation}) {sim.character_set_rotation(w,l.character,world.rotation)}
        return
    }
    position,rotation,frame:=world.position,world.rotation,mm.QUAT_IDENTITY
    if l.kind==.Character && sim.character_valid(w,l.character) {
        position=sim.character_position(w,l.character)
        rotation=sim.body_rotation(w,sim.character_body(w,l.character))
        frame=sim.character_state(w,l.character).up_frame
    }
    link_release(s,l)
    l.character=sim.character_create(w,desc,position,rotation,frame)
    if l.character=={} {
        s.unmade=true
        core.report(s.problems,e,"physics.characters","its Character is not made: the %d characters of Physics_Settings.characters are in use, or its capsule, mass, max_slope, push_force or up_speed is not valid; raise characters, or fix the Character and its Collider",w.desc.character_capacity)
        return
    }
    state.stats.characters_created+=1
    if config.locks!={} {sim.character_set_locks(w,l.character,body_locks(config.locks))}
    if !collider_surface_same({},capsule) {surface_set(w,sim.character_shape(w,l.character),capsule)}
    if linear,_:=made_velocity(s,e);linear!={} {
        sim.body_set_linear_velocity(w,sim.character_body(w,l.character),linear)
    }
    l.kind,l.made=.Character,key
    target_made(s,l,e)
    if s.playing {character_rows(s,e)}
}

// The velocities a body is made with: those of its pose target, or those a saved
// game left in its Motion.
@(private)
made_velocity :: proc(s:^Sync,e:core.Entity) -> (linear,angular:[3]f32) {
    if target,on:=core.get(s.targets,e);on {return target.linear,target.angular}
    if held,ok:=core.get(s.motions,e);ok {return held.linear,held.angular}
    return
}

@(private)
body_locks :: proc "contextless" (locks:Body_Locks) -> (flags:sim.Body_Flags) {
    if .Linear_X in locks {flags+={.Lock_Linear_X}}
    if .Linear_Y in locks {flags+={.Lock_Linear_Y}}
    if .Linear_Z in locks {flags+={.Lock_Linear_Z}}
    if .Angular_X in locks {flags+={.Lock_Angular_X}}
    if .Angular_Y in locks {flags+={.Lock_Angular_Y}}
    if .Angular_Z in locks {flags+={.Lock_Angular_Z}}
    return
}

// The filter of a collider under the settings of the world. A preset the code does not declare is
// reported once, when the collider or the settings change; it is the Default category colliding with
// every category.
@(private)
collision_of :: proc(s:^Sync,e:core.Entity,collider:Collider,changed:bool) -> sim.Filter {
    filter:=collision_filter(s.collision,collider)
    if !changed && !s.collision_changed {return filter}
    info:=s.app!=nil?s.app.info:nil
    if collider.preset!=PRESET_CUSTOM && !collision_declared(info,Collision_Preset,i64(collider.preset)) {
        core.report(s.problems,e,"physics.collision","its Collider uses collision preset %d, which no code declares; choose a declared preset, or declare it (PRESET_NAME :: physics.Collision_Preset(%d))",collider.preset,collider.preset)
    }
    return filter
}

// A negative axis of the scale mirrors the collider: its center goes to the other side, and a symmetric
// primitive keeps its size.
@(private)
collider_desc :: proc "contextless" (collider:Collider,scale:[3]f32,filter:sim.Filter,e:core.Entity) -> sim.Shape_Desc {
    desc:=sim.SHAPE_DESC_DEFAULT
    size:=linalg.abs(scale)
    switch collider.kind {
    case .Hull,.Mesh,.Heightfield,.External,.Auto:
    case .Box:     desc.geometry=sim.Box{collider.size*size}
    case .Sphere:  desc.geometry=sim.Sphere{collider.size.x*max(size.x,size.y,size.z)}
    case .Capsule: desc.geometry=sim.Capsule{collider.size.x*max(size.x,size.z),collider.size.y*size.y}
    case .Cylinder: desc.geometry=sim.Cylinder{collider.size.x*max(size.x,size.z),collider.size.y*size.y}
    }
    desc.convex_radius=collider_round(collider,scale)
    desc.transform.p=collider.center*scale
    desc.friction,desc.restitution,desc.density=collider.friction,collider.restitution,collider.density
    desc.filter,desc.user_data=filter,u64(e)
    desc.surface_speed,desc.one_way,desc.dominance=collider.surface_speed,collider.one_way,collider.dominance
    desc.drag=collider.drag
    return desc
}

// Makes the shapes of a collider on body: one, or one per convex piece of a Hull whose mesh has several, all
// alike but for their hull. An Auto collider is as auto_kind resolved it: still Auto, the pieces of a
// decomposition of its mesh, or one hull when it has fewer than two. Those of a compound go where relative
// puts the entity. Nothing stays made when one fails.
@(private)
collider_shapes_make :: proc(s:^Sync,l:^Link,e:core.Entity,body:sim.Body_Handle,collider:Collider,scale:[3]f32,filter:sim.Filter,relative:^mm.Transform=nil) -> Shape_Failure {
    state:=s.state
    w:=&state.world
    desc:=collider_desc(collider,scale,filter,e)
    failure:=collider_round_fits(collider,scale)?Shape_Failure.None:.Convex_Radius
    pieces:bool
    if failure==.None && (collider.kind==.Hull || collider.kind==.Auto) {
        pieces,failure=collider_pieces_make(s,l,e,scale,desc.convex_radius,collider.kind==.Auto)
        if pieces {desc.geometry=l.hull}
    }
    if failure==.None && !pieces && (collider.kind==.Hull || collider.kind==.Mesh || collider.kind==.Heightfield || collider.kind==.Auto) {
        origin:[3]f32
        desc.geometry,origin,failure=collider_geometry(s,l,collider.kind==.Auto?.Hull:collider.kind,e,scale,desc.convex_radius)
        desc.transform.p+=origin
    }
    if relative!=nil {desc.transform={relative.position+mm.quat_rotate(relative.rotation,desc.transform.p),relative.rotation}}
    l.shape=failure==.None?sim.shape_create(w,body,desc):{}
    if failure==.None && l.shape=={} {failure=.Shapes}
    for &piece in pieces_of(state,l) {
        if failure!=.None {break}
        desc.geometry=piece.hull
        piece.shape=sim.shape_create(w,body,desc)
        if piece.shape=={} {failure=.Shapes}
    }
    if failure!=.None {
        if l.shape!={} {sim.shape_destroy(w,l.shape)}
        l.shape={}
        pieces_shapes_destroy(s,l)
        geometry_release(s,l)
        return failure
    }
    state.stats.shapes_created+=1+u64(l.pieces.count)
    return .None
}

// Destroys the shapes of the pieces after the first of a link: how many there were.
@(private)
pieces_shapes_destroy :: proc(s:^Sync,l:^Link) -> (count:u64) {
    w:=&s.state.world
    for &piece in pieces_of(s.state,l) {
        if sim.shape_valid(w,piece.shape) {
            sim.shape_destroy(w,piece.shape)
            count+=1
        }
        piece.shape={}
    }
    return
}

// A shape of the link is gone from the simulation without the link letting it go.
@(private)
link_shapes_lost :: proc(s:^Sync,l:^Link) -> bool {
    w:=&s.state.world
    if l.shape!={} && !sim.shape_valid(w,l.shape) {return true}
    for piece in pieces_of(s.state,l) {
        if !sim.shape_valid(w,piece.shape) {return true}
    }
    return false
}

// Gives the shapes of a link the filter of its collider, and its surface when it changed.
@(private)
shapes_restyle :: proc(s:^Sync,l:^Link,collider:Collider,filter:sim.Filter,changed:bool) {
    w:=&s.state.world
    restyle :: proc(w:^sim.World,shape:sim.Shape_Handle,collider:Collider,filter:sim.Filter,changed:bool) {
        if sim.shape_filter(w,shape)!=filter {sim.shape_set_filter(w,shape,filter)}
        if changed {surface_set(w,shape,collider)}
    }
    restyle(w,l.shape,collider,filter,changed)
    for piece in pieces_of(s.state,l) {restyle(w,piece.shape,collider,filter,changed)}
}

// Whether two colliders give their contacts the same rules; a change is applied to the shape as it is.
@(private)
collider_surface_same :: proc "contextless" (a,b:Collider) -> bool {
    return a.surface_speed==b.surface_speed && a.one_way==b.one_way && a.dominance==b.dominance && a.drag==b.drag
}

// Wakes the body only when the surface differs.
@(private)
surface_set :: proc(w:^sim.World,shape:sim.Shape_Handle,collider:Collider) {
    if speed,one_way,dominance:=sim.shape_surface(w,shape);speed!=collider.surface_speed || one_way!=collider.one_way || dominance!=collider.dominance {
        sim.shape_set_surface(w,shape,collider.surface_speed,collider.one_way,collider.dominance)
    }
    sim.shape_set_drag(w,shape,collider.drag)
}

// What the game asked for since the last tick.
// A teleport is a jump: who draws the entity between two ticks takes it as
// coming from where it is put, turned as it was turned, and not from where
// it was.
@(private)
jumped :: proc(s:^Sync,e:core.Entity,from:[3]f32,turn:mm.Quat,to:[3]f32) {
    if s.jumps!=nil {core.jump(s.jumps,e,{to-mm.quat_rotate(turn,from),turn,{1,1,1}})}
}

// A volume where it is, for the simulation to ask how much of it a point is in.
@(private)
Area_Place :: struct {
    area:volume.Volume,
    pose:mm.Transform,
    blend:f32,
    outline:[]mm.Path_Point,
}

// Applies a request of an area, which names no entity; false for any other request.
@(private)
area_apply :: proc(s:^Sync,request:Body_Request) -> bool {
    if request.kind==.Area_Strain {return true}
    if request.kind!=.Area_Force && request.kind!=.Area_Impulse {return false}
    place:=Area_Place{request.area,{request.position,request.rotation==0?mm.QUAT_IDENTITY:request.rotation,request.scale=={}?[3]f32{1,1,1}:request.scale},request.blend,volume.spline_outline(s.splines,request.entity)}
    weight :: proc "contextless" (user:rawptr,point:[3]f32) -> f32 {
        p:=(^Area_Place)(user)
        return volume.weight(p.area,p.pose,point,p.blend,p.outline)
    }
    ok:=volume.valid(place.area,place.pose,place.outline) && request.blend>=0 && request.blend<=max(f32) && request.strength>=-max(f32) && request.strength<=max(f32)
    for value in request.linear {ok=ok && value>=-max(f32) && value<=max(f32)}
    if ok {
        radial:=request.linear=={}
        force:=radial?[3]f32{request.strength,0,0}:linalg.normalize0(request.linear)*request.strength
        // Away from a plane is along its normal.
        if radial && place.area.shape==.Plane {radial,force=false,mm.quat_rotate(place.pose.rotation,[3]f32{0,1,0})*request.strength}
        area:=sim.Area{bounds=volume.bounds(place.area,place.pose,place.outline),center=place.pose.position,rotation=place.pose.rotation,weight=weight,user=&place}
        _,ok=sim.world_apply_area(&s.state.world,area,force,radial,request.kind==.Area_Impulse,request.override,request.falloff,request.filter,request.falloff_range,request.noise)
    }
    if !ok {area_problem(s,request)}
    return true
}

@(private)
requests_apply :: proc(s:^Sync,requests:[]Body_Request) {
    state:=s.state
    w:=&state.world
    for request in requests {
        if area_apply(s,request) {continue}
        e:=request.entity
        if !sim.finite(request.linear,request.angular,request.point,request.position) || !sim.finite(request.rotation) {
            request_problem(s,e,request.kind,"physics.request_value","its position, rotation, linear, angular or point values are not finite","send finite values")
            continue
        }
        l:=link_find(state,e)
        if l==nil || l.kind==.None || l.kind==.Compound {
            why:=l!=nil && l.kind==.Compound?"its Collider is part of the body of an ancestor":"it has no body in the simulation"
            request_problem(s,e,request.kind,"physics.request_body",why,"send it to an entity with a Rigid_Body, a Collider of its own or a Character")
            continue
        }
        rotation:=request.rotation==0?mm.QUAT_IDENTITY:request.rotation
        if l.kind==.Character {
            switch request.kind {
            case .Teleport:
                body:=sim.character_body(w,l.character)
                from,was:=sim.character_position(w,l.character),sim.body_rotation(w,body)
                sim.character_set_position(w,l.character,request.position)
                sim.character_set_rotation(w,l.character,rotation)
                turned:=sim.body_rotation(w,body)
                jumped(s,e,from,turned*conj(was),request.position)
                pose_write(s,l,e,{request.position,turned})
                state.stats.teleports+=1
            case .Velocity:         sim.character_launch(w,l.character,request.linear,true)
            case .Impulse:          sim.character_launch(w,l.character,request.linear/sim.character_desc(w,l.character).mass)
            case .Force:            sim.body_apply_force(w,sim.character_body(w,l.character),request.linear)
            case .Area_Force,.Area_Impulse,.Area_Strain:
            case .Kinematic,.Manipulate,.Release_Manipulation: request_problem(s,e,request.kind,"physics.request_character","a Character moves by its Character_Move","teleport it, give it a velocity or an impulse, or write its Character_Move")
            }
            continue
        }
        if !sim.body_valid(w,l.body) {
            request_problem(s,e,request.kind,"physics.request_body","its body was not made","read the problems of the entity about its body and fix them")
            continue
        }
        link_touch(state,l)
        switch request.kind {
        case .Teleport:
            was:=sim.body_transform(w,l.body)
            jumped(s,e,was.p,rotation*conj(was.q),request.position)
            sim.body_set_transform(w,l.body,request.position,rotation)
            pose_write(s,l,e,{request.position,rotation})
            state.stats.teleports+=1
        case .Velocity:
            sim.body_set_velocity(w,l.body,request.linear,request.angular)
        case .Impulse:
            if request.linear!={} {
                if request.at_point {sim.body_apply_impulse_at(w,l.body,request.linear,request.point)} else {sim.body_apply_impulse(w,l.body,request.linear)}
            }
            if request.angular!={} {sim.body_apply_angular_impulse(w,l.body,request.angular)}
        case .Force:
            if request.at_point {sim.body_apply_force_at(w,l.body,request.linear,request.point)} else {sim.body_apply_force(w,l.body,request.linear)}
            if request.angular!={} {sim.body_apply_torque(w,l.body,request.angular)}
        case .Area_Force,.Area_Impulse,.Area_Strain:
        case .Kinematic:
            if s.playing {
                sim.body_set_kinematic_target(w,l.body,request.position,rotation,s.dt)
            } else {
                sim.body_set_transform(w,l.body,request.position,rotation)
                pose_write(s,l,e,{request.position,rotation})
            }
        case .Manipulate:
            qscale:=max(abs(rotation.x),abs(rotation.y),abs(rotation.z),abs(rotation.w))
            rotation=linalg.normalize(quaternion(x=rotation.x/qscale,y=rotation.y/qscale,z=rotation.z/qscale,w=rotation.w/qscale))
            h:=held_take(state,e)
            if h==nil {memory_problem(s.problems,e,"what physics holds, so the manipulation does not take the body");continue}
            // Another link of the same body hands over its manipulation, the type the body had and its spring.
            for &other in state.held {
                if &other==h || .Manipulation not_in other.by {continue}
                if by:=link_find(state,other.entity);by==nil || by.body!=l.body {continue}
                if h.by=={} {
                    h.type_before,h.follow,h.pull=other.type_before,other.follow,other.pull
                    h.by+={.Manipulation}
                } else if sim.joint_valid(w,other.pull) {sim.joint_destroy(w,other.pull)}
                other.by-={.Manipulation}
                other.release,other.pull=false,{}
            }
            was:=held_kinematic(h^)
            h.follow=request.override || (was?h.type_before:sim.body_type(w,l.body))!=.Dynamic
            h.by+={.Manipulation}
            h.pose[.Manipulation]={request.position,rotation}
            h.release=false
            if !hold_type(state,h,l,was,s.rigids) {
                core.report(s.problems,e,"physics.joints","a manipulation does not pull it: the %d joints of Physics_Settings.joints are in use; raise joints, or remove joints",w.desc.joint_capacity)
                hold_end(state,h,l,.Manipulation,s.rigids)
                continue
            }
            // A body its pose target holds heads for the manipulation once the target lets it go.
            if .Target in h.by {continue}
            if !s.playing {
                sim.body_set_transform(w,l.body,request.position,rotation)
                sim.body_set_velocity(w,l.body,{},{})
                pose_write(s,l,e,sim.body_transform(w,l.body))
            } else if h.follow {
                sim.body_set_kinematic_target(w,l.body,request.position,rotation,s.dt)
            }
        case .Release_Manipulation:
            if h:=held_of(state,e);h!=nil && .Manipulation in h.by {
                h.release=true
                if !s.playing || !h.follow || .Target in h.by || !pose_differs(sim.body_transform(w,l.body),h.pose[.Manipulation]) {hold_end(state,h,l,.Manipulation,s.rigids)}
            }
        }
    }
}

// A force or impulse over a volume that the simulation refused.
@(private)
area_problem :: proc(s:^Sync,request:Body_Request) {
    core.report(s.problems,core.NONE,"physics.request_area","a %v request of Body_Requests did nothing: its volume has no size or a pose that is not finite, its blend, its strength or its direction is not finite, a velocity change is not an impulse, its falloff is not a Radial_Falloff, or its noise scale is negative; send apply_area a volume of volume.box, volume.sphere, volume.plane or volume.outline (with outline_of the entity of its Spline) with a positive size, finite values and a falloff and noise of physics",request.kind)
}

// Brings back into the rows what the step left: the pose, the Motion and the state of the bodies it moved or
// woke, of the links something else addressed since the last time (link_touch), of the proxies and of the
// characters, in the order of the links. Every other body is asleep or static, as its rows already say.
@(private)
poses_write :: proc(s:^Sync) {
    state:=s.state
    w:=&state.world
    integrated,woken:=sim.world_stepped(w)
    for slots in ([2][]i32{integrated,woken}) {
        for slot in slots {
            body,user:=sim.body_at(w,slot)
            if l:=link_find(state,core.Entity(user));l!=nil && l.kind==.Body && l.body==body {link_touch(state,l)}
        }
    }
    #reverse for e,at in state.proxies {
        if l:=link_find(state,e);l!=nil && l.kind==.Proxy {link_touch(state,l)} else {unordered_remove(&state.proxies,at)}
    }
    for row in 0..<core.count(s.characters) {
        if l:=link_find(state,core.entity_at(s.characters,row));l!=nil {link_touch(state,l)}
    }
    if state.touched_all {
        clear(&state.touched)
        state.touched_all=false
        for &l,at in state.links.values {
            if link_write(s,&l,state.links.entities[at]) {link_touch(state,&l)}
        }
        return
    }
    slice.sort(state.touched[:])
    // A link to write again takes the place of one already written: what is left is the list of the next step.
    again,last:=0,max(u32)
    for at in state.touched {
        if at==last || int(at)>=len(state.links.values) {continue}
        last=at
        if link_write(s,&state.links.values[at],state.links.entities[at]) {
            state.touched[again]=at
            again+=1
        }
    }
    base.truncate(&state.touched,again)
}

// What the step left of one link. True when its rows change again without the step moving its body: one that
// fell asleep keeps for this tick the group it moved in.
@(private)
link_write :: proc(s:^Sync,l:^Link,e:core.Entity) -> (again:bool) {
    w:=&s.state.world
    switch l.kind {
    case .None,.Compound:
    case .Body,.Proxy:
        // A held body is kinematic: one static is as its rows say.
        if !sim.body_valid(w,l.body) || l.kind==.Body && sim.body_type(w,l.body)==.Static {return}
        awake:=sim.body_is_awake(w,l.body)
        if awake {pose_write(s,l,e,sim.body_transform(w,l.body))}
        return motion_write(s,e,l.body,awake,l.kind==.Proxy)!=0 && !awake
    case .Character:
        if !sim.character_valid(w,l.character) {return}
        if row:=core.row_of(s.character_states,e);row>=0 {
            found:=sim.character_state(w,l.character)
            next:=Character_State{
                standing=.Standing in found.ground,walkable=.Walkable in found.ground,ground_distance=found.ground_distance,
                ground_normal=found.ground_normal,ground_velocity=found.ground_velocity,ground_turn=found.ground_turn,wall_normal=found.wall_normal,
                fluid=found.fluid,submersion=found.submersion,head_depth=found.head_depth,depth=found.depth,fluid_velocity=found.fluid_velocity,
                height=sim.character_desc(w,l.character).height,velocity=sim.character_velocity(w,l.character),
            }
            next.cramped=s.character_states.values[row].cramped
            core.edit_at(s.character_states,row)^=next
        }
        body:=sim.character_body(w,l.character)
        motion_write(s,e,body,sim.body_is_awake(w,body),false)
        pose_write(s,l,e,sim.body_transform(w,body))
    }
    return
}

// The core.Motion of what a body moves; a proxy gets its row here, the others when they are made.
// Returns the group it wrote.
@(private)
motion_write :: proc(s:^Sync,e:core.Entity,body:sim.Body_Handle,awake,add:bool) -> u32 {
    w:=&s.state.world
    _,center,_:=sim.body_mass_properties(w,body)
    next:=core.Motion{
        linear=sim.body_linear_velocity(w,body),angular=sim.body_angular_velocity(w,body),
        center=center,island=s.grouped?sim.body_group(w,body):0,awake=awake,
    }
    if row:=core.row_of(s.motions,e);row>=0 {
        core.edit_at(s.motions,row)^=next
    } else if add {
        core.add(s.motions,e,next)
    }
    return next.island
}

// The rows of what the step leaves of a character.
@(private)
character_rows :: proc(s:^Sync,e:core.Entity) {
    if !core.has(s.character_states,e) {core.add(s.character_states,e,Character_State{})}
    if !core.has(s.motions,e) {core.add(s.motions,e,core.Motion{})}
}

// What steers an entity; nil when nothing does.
@(private)
held_of :: proc "contextless" (state:^Physics_State,e:core.Entity) -> ^Held {
    for &h in state.held {
        if h.entity==e {return &h}
    }
    return nil
}

// What steers an entity, listed now if nothing did. nil without memory.
@(private)
held_take :: proc(state:^Physics_State,e:core.Entity) -> ^Held {
    if h:=held_of(state,e);h!=nil {return h}
    if _,err:=append(&state.held,Held{entity=e});err!=nil {return nil}
    return &state.held[len(state.held)-1]
}

// Whether what holds the body makes it kinematic: a following pose target or manipulation, or a section.
@(private)
held_kinematic :: proc "contextless" (h:Held) -> bool {return .Target in h.by || .Section in h.by || .Manipulation in h.by && h.follow}

// A source lets go.
@(private)
hold_end :: proc(state:^Physics_State,h:^Held,l:^Link,source:Hold_Source,rigids:^core.Table(Rigid_Body,.Read)) {
    if source not_in h.by {return}
    was:=held_kinematic(h^)
    h.by-={source}
    if source==.Manipulation {h.release=false}
    hold_type(state,h,l,was,rigids)
}

// Gives the body the type its holds ask (was: whether they held it as kinematic before) and the spring of a
// manipulation that pulls. Held as kinematic, it keeps the type it had; let go, it has its own again: moving
// as it was when it is dynamic, else at rest. false when no joint is left for the spring.
@(private)
hold_type :: proc(state:^Physics_State,h:^Held,l:^Link,was:bool,rigids:^core.Table(Rigid_Body,.Read)) -> bool {
    w:=&state.world
    if l.kind==.Character {
        sim.character_set_held(w,l.character,.Section in h.by)
        return true
    }
    if !sim.body_valid(w,l.body) {return true}
    now:=held_kinematic(h^)
    if now && !was {
        h.type_before=sim.body_type(w,l.body)
        sim.body_set_type(w,l.body,.Kinematic)
    } else if was && !now {
        rigid,has_rigid:=core.get(rigids,h.entity)
        type:=l.kind==.Proxy?h.type_before:(has_rigid?rigid.type:Body_Type.Static)
        if type!=.Dynamic {sim.body_set_velocity(w,l.body,{},{})}
        sim.body_set_type(w,l.body,type)
        if l.kind!=.Proxy {body_mass_update(w,l.body,rigid,has_rigid)}
    }
    if !now && .Manipulation in h.by {return pull_set(state,h,l)}
    if sim.joint_valid(w,h.pull) {sim.joint_destroy(w,h.pull)}
    h.pull={}
    return true
}

// Box2D's mouse drag: a soft drive of PULL_HERTZ, critically damped, whose force is bounded by the weight
// of the body, and whose torque by that force at the radius of gyration.
@(private) PULL_HERTZ :: 7.5
PULL_WEIGHTS :: 10 // times its weight a manipulation pulls a dynamic body with at the most
@(private) PULL_GRAVITY :: 9.81 // m/s2 of that weight, whatever the gravity where the body is

// Makes or tunes the spring that pulls a dynamic body toward its manipulation, from the world body.
@(private)
pull_set :: proc(state:^Physics_State,h:^Held,l:^Link) -> bool {
    w:=&state.world
    mass,_,inertia:=sim.body_mass_properties(w,l.body)
    force:=PULL_WEIGHTS*PULL_GRAVITY*mass
    gyration:=mass>0?math.sqrt((inertia[0,0]+inertia[1,1]+inertia[2,2])/(3*mass)):0
    desc:=sim.Joint_Desc{body_a=joint_world_body(state),body_b=l.body}
    pose:=h.pose[.Manipulation]
    if sim.joint_drive_pose(&desc,pose.p,pose.q,PULL_HERTZ,1,force,force*gyration)!=.None {return false}
    if sim.joint_valid(w,h.pull) {
        if _,b:=sim.joint_bodies(w,h.pull);b==l.body {return sim.joint_set_axes(w,h.pull,desc.linear,desc.angular)==.None}
        sim.joint_destroy(w,h.pull)
    }
    h.pull=sim.joint_create(w,desc)
    return h.pull!={}
}

// Where a held body heads: its pose target first.
@(private)
hold_pose :: proc "contextless" (h:Held) -> sim.Transform {return .Target in h.by?h.pose[.Target]:h.pose[.Manipulation]}

// Sends the events of the simulation not sent yet. The step clears them, so
// what woke or slept between two steps is sent before the next one.
@(private)
events_forward :: proc(s:^Sync,events:^Physics_Events,sent:^[6]int) {
    w:=&s.state.world
    list:=sim.world_events(w)
    lengths:=[6]int{len(list.contact_begin),len(list.contact_end),len(list.overlap_begin),len(list.overlap_end),len(list.sleep),len(list.wake)}
    for &count,i in sent {count=min(count,lengths[i])}
    for event in list.contact_begin[sent[0]:] {
        core.push(&events.contact_begin,Contact_Begin{
            a=core.Entity(event.users.body_a),b=core.Entity(event.users.body_b),collider_a=core.Entity(event.users.shape_a),collider_b=core.Entity(event.users.shape_b),
            point=event.point,normal=event.normal,impulse=event.impulse,material=base.Asset_Id(event.surface),
        })
    }
    for event in list.contact_end[sent[1]:] {core.push(&events.contact_end,Contact_End{core.Entity(event.users.body_a),core.Entity(event.users.body_b),core.Entity(event.users.shape_a),core.Entity(event.users.shape_b)})}
    for event in list.overlap_begin[sent[2]:] {core.push(&events.overlap_begin,Overlap_Event{core.Entity(event.users.body_a),core.Entity(event.users.body_b),core.Entity(event.users.shape_a),core.Entity(event.users.shape_b),event.crossed})}
    for event in list.overlap_end[sent[3]:] {core.push(&events.overlap_end,Overlap_Event{core.Entity(event.users.body_a),core.Entity(event.users.body_b),core.Entity(event.users.shape_a),core.Entity(event.users.shape_b),event.crossed})}
    for event in list.sleep[sent[4]:] {core.push(&events.sleep,Body_Event{core.Entity(event.user_data)})}
    for event in list.wake[sent[5]:] {core.push(&events.wake,Body_Event{core.Entity(event.user_data)})}
    sent^=lengths
}
