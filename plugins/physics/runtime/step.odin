package physics

import "core:math/linalg"
import "core:slice"
import "mirai:core"
import "mirai:host"
import render "mirai:engine/render"
import sim "plugins:physics/runtime/sim"
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
    rigids:core.Read(Rigid_Body),
    colliders:core.Read(Collider),
    characters:core.Read(Character),
    statics:core.Read(render.Mesh_Renderer),
    parents:core.Read(core.Parent),
    hierarchy:core.Ref(core.Hierarchy), // without it every sync is whole
    names:core.Read(core.Name),
    collision:^Collision_Settings,
    collision_changed:bool, // the settings differ from those the filters were made with
    locals:core.Read(core.Transform),
    transforms:^core.Table(core.Transform),
    motions:^core.Table(core.Motion),
    targets:core.Read(core.Pose_Target),
    grouped:bool, // Motion.island has the groups of this step
    character_states:^core.Table(Character_State),
    jumps:^core.Jumps, // nil for whoever steps the simulation by hand
    problems:^core.Problems,
    budget:int,   // what the tick may still make or let go
    waiting:bool, // something waits for the next tick
    unmade:bool,  // a body or character could not be made
}

// Makes the simulation of the world when it has none, before what asks of
// its bodies in the tick looks for them, and gives the queries of the world.
@(step="fixed",loops="game editor",stage="simulate")
physics_prepare :: proc(state:^Physics_State,settings:core.Ref(Physics_Settings),queries:^core.World_Queries,job_system:^jobs.Job_System,problems:^core.Problems) {
    _=state_make(state,settings.ptr,job_system,problems)
    if queries.open==nil {queries.open=query_open}
}

@(step="fixed",loops="game editor",stage="simulate",after="physics_places places_drop")
physics_step :: proc(
    state:^Physics_State,settings:core.Ref(Physics_Settings),requests:^Body_Requests,events:^Physics_Events,meshes:^Collider_Meshes,
    app:^host.App,time:core.Time,
    rigids:core.Read(Rigid_Body),colliders:core.Read(Collider),characters:core.Read(Character),moves:core.Read(Character_Move),
    joints:^core.Table(Joint),statics:core.Read(render.Mesh_Renderer),parents:core.Read(core.Parent),names:core.Read(core.Name),
    transforms:^core.Table(core.Transform),motions:^core.Table(core.Motion),targets:core.Read(core.Pose_Target),
    character_states:^core.Table(Character_State),joint_states:^core.Table(Joint_State),volumes:core.Read(Fluid_Volume),
    joint_requests:^Joint_Requests,
    collision:core.Ref(Collision_Settings),sync_check:core.Ref(core.Sync_Check),simulation_hash:^core.Simulation_Hash,
    jumps:^core.Jumps,problems:^core.Problems,
    gravities:core.Read(volume.Gravity),gravity_volumes:core.Read(volume.Volume),worlds:core.Read(core.World_Transform),
    fluid_waves:core.Read(Fluid_Waves),winds:core.Read(volume.Wind),
    hierarchy:core.Ref(core.Hierarchy),
) {
    events_clear(events)
    if !state_make(state,settings.ptr,&app.jobs,problems) {
        core.queue_clear(&requests.queue)
        return
    }
    w:=&state.world
    fluids_sync(state,volumes,core.read(transforms),parents,problems,fluid_waves,winds,gravity_volumes,worlds)
    if !events_reserve(events,w.desc.event_capacity) {
        memory_problem(problems,core.NONE,"the events of the physics, so nothing is simulated in this tick")
        core.queue_clear(&requests.queue)
        return
    }
    state.pass+=1
    s:=Sync{
        state=state,app=app,meshes=meshes,playing=time.playing && time.dt>0,dt=time.dt,
        rigids=rigids,colliders=colliders,characters=characters,statics=statics,parents=parents,hierarchy=hierarchy,names=names,
        locals=core.read(transforms),transforms=transforms,motions=motions,targets=targets,character_states=character_states,jumps=jumps,problems=problems,
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
        #reverse for &link,at in state.links.values {
            e:=state.links.entities[at]
            if link.kind==.Proxy || core.has(rigids,e) || core.has(colliders,e) || core.has(characters,e) {continue}
            if link.kind!=.None {
                if s.budget==0 {
                    s.waiting=true
                    continue
                }
                s.budget-=1
            }
            link_release(&s,&link)
            core.entity_map_remove_at(&state.links,at)
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
            for row in 0..<core.count(rigids) {entity_sync(&s,core.entity_at(rigids,row))}
            for row in 0..<core.count(colliders) {entity_sync(&s,core.entity_at(colliders,row))}
            for row in 0..<core.count(characters) {entity_sync(&s,core.entity_at(characters,row))}
            synced=!s.waiting
            // Without it sealed_sync has no room and every tick looks at all the bodies.
            if reserve(&state.sealed,core.count(rigids)+core.count(colliders)+core.count(characters))!=nil {
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
        _=core.changes(s.locals,&state.transforms_seen)
    }

    requests_apply(&s,core.take(&requests.queue))
    if s.playing {joints_sync(&s,core.read(joints),joint_states)}
    joint_requests_apply(&s,joints,joint_states,joint_requests)
    if s.playing {
        for row in 0..<core.count(characters) {
            e:=core.entity_at(characters,row)
            l:=link_find(state,e)
            if l==nil || l.kind!=.Character {continue}
            // One a following target leads does not walk: it is put at the pose.
            if l.followed {
                sim.character_set_move(w,l.character,{})
                continue
            }
            move,has:=core.get(moves,e)
            if has {sim.character_set_move(w,l.character,move.value)}
            character_height_set(w,l,e,move.height)
        }
    }

    events_forward(&s,events,&state.forwarded)
    if !s.playing {return}

    // A held body heads for its pose in every step.
    for &l in state.links.values {
        if (l.kind==.Body || l.kind==.Proxy) && l.hold.by!={} && sim.body_valid(w,l.body) {
            pose:=hold_pose(l.hold)
            sim.body_set_kinematic_target(w,l.body,pose.p,pose.q,s.dt)
        }
    }
    parallel:=Parallel{&app.jobs}
    w.desc.parallel_user=&parallel
    if gravities.table!=nil {gravity_apply(state,gravities,gravity_volumes,worlds,problems)}
    sim.world_step(w,time.dt)
    w.desc.parallel_user=nil
    step_followed(state,characters)

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
physics_verticals :: proc(state:core.Ref(Physics_State),characters:core.Read(Character),verticals:^core.Table(core.Vertical)) {
    if state.ptr==nil || !state.ready {return}
    for row in 0..<core.count(characters) {
        e:=core.entity_at(characters,row)
        l:=link_find(state.ptr,e)
        if l==nil || l.kind!=.Character || !sim.character_valid(&state.world,l.character) {continue}
        next:=core.Vertical{sim.character_state(&state.world,l.character).up_frame}
        if at:=core.row_of(verticals,e);at<0 {
            core.add(verticals,e,next)
        } else if verticals.values[at]!=next {core.at(verticals,at)^=next}
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
    seen:=core.version(s.rigids)+core.layout(s.rigids)+core.version(s.colliders)+core.layout(s.colliders)+core.layout(s.characters)+characters_seen(s.characters)
    seen+=core.version(s.statics)+core.layout(s.statics)+core.version(s.parents)+core.layout(s.parents)+core.layout(s.transforms)
    return seen+u64(s.state.epoch)+(s.app.assets!=nil?s.app.assets.structure:0)
}

// What else a whole sync reads of every body: whether it steps, the rows it
// gives them, the bodies of the simulation and the revision of the assets.
@(private)
sealed_key :: proc(s:^Sync,structure:u64) -> u64 {
    key:=structure
    revision:=s.app.assets!=nil?s.app.assets.revision:0
    for value in ([5]u64{u64(s.playing),core.layout(s.motions),core.layout(s.character_states),u64(s.state.world.body_count),revision}) {
        key=(key~value)*0x100000001b3
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
    c:=core.changes(s.locals,&seen)
    if c.all {return false}
    clear(&state.sealed)
    for row in 0..<core.count(s.locals) {
        if core.stamp(s.locals,row)<=c.since {continue}
        root:=core.entity_at(s.locals,row)
        if sealed_above(s.locals,h,root,c.since) {continue}
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
sealed_above :: proc(locals:core.Read(core.Transform),h:core.Ref(core.Hierarchy),e:core.Entity,since:u64) -> bool {
    for at:=core.parent_of(h,e);at!=core.NONE;at=core.parent_of(h,at) {
        if row:=core.row_of(locals,at);row>=0 && core.stamp(locals,row)>since {return true}
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
    }
    return
}

// The fields of the characters the simulation reads, which change seldom; the
// locomotion writes the rest of their rows every tick.
@(private)
characters_seen :: proc(characters:core.Read(Character)) -> (seen:u64) {
    for c in characters.table.values[:core.count(characters)] {
        for field in ([9]f32{c.mass,c.max_slope,c.step_height,c.traction_force,c.adhesion_force,c.gravity_scale,c.push_force,c.density,c.up_speed}) {
            seen=(seen~u64(transmute(u32)field))*0x100000001b3
        }
        seen=(seen~u64(transmute(u8)c.locks))*0x100000001b3
    }
    return
}

@(private)
link_find :: proc(state:^Physics_State,e:core.Entity) -> ^Link {
    return state==nil?nil:core.entity_map_get(&state.links,e)
}

// The link of an entity; the one of another generation of its index is
// released first. nil without memory.
@(private)
link_at :: proc(s:^Sync,e:core.Entity) -> ^Link {
    links:=&s.state.links
    if l:=core.entity_map_get(links,e);l!=nil {return l}
    if held:=core.entity_map_held(links,e);held!=core.NONE {link_release(s,core.entity_map_get(links,held))}
    l,_:=core.entity_map_put(links,e,Link{})
    return l
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
    return core.entity_map_reserve(&s.state.links,len(s.state.links.values)+rows,most+1)
}

@(private)
world_pose :: proc(s:^Sync,e:core.Entity) -> mm.Transform {
    world,_:=core.world_of(s.locals,s.parents,e)
    return world
}

// The Transform values that put an entity at a world pose under its parent: what a library that moves an entity writes.
local_of :: proc(locals:core.Read(core.Transform),parents:core.Read(core.Parent),e:core.Entity,pose:sim.Transform) -> (position:[3]f32,rotation:mm.Quat,ok:bool) {
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

// Writes a world pose into the Transform of the entity and remembers it, so that a write of anybody else shows.
@(private)
pose_write :: proc(s:^Sync,l:^Link,e:core.Entity,pose:sim.Transform) {
    row:=core.row_of(s.transforms,e)
    if row<0 {return}
    position,rotation,ok:=local_of(s.locals,s.parents,e,pose)
    if !ok {return}
    l.written_position,l.written_rotation=position,rotation
    local:=s.transforms.values[row]
    if local.position==position && local.rotation==rotation {return}
    written:=core.at(s.transforms,row)
    written.position,written.rotation=position,rotation
}

// Whether another function wrote the Transform of e. A write that leaves it
// where the simulation has it (moved: false) is no teleport: it hangs from
// another parent, as a section that something left gives it to the next.
@(private)
foreign_write :: proc(s:^Sync,l:^Link,e:core.Entity,component:string,moved:bool) -> bool {
    row:=core.row_of(s.transforms,e)
    if row<0 {return false}
    local:=s.transforms.values[row]
    if local.position==l.written_position && local.rotation==l.written_rotation {return false}
    if !moved {
        l.written_position,l.written_rotation=local.position,local.rotation
        return false
    }
    core.fail(
        "Entity %q has a %s, which owns its Transform, but another function wrote its position or rotation: use core.place(placer,entity,position,rotation) (physics.move_kinematic for a kinematic body)",
        core.name_get(s.names,e),component,
    )
    return true
}

@(private)
entity_sync :: proc(s:^Sync,e:core.Entity) {
    l:=link_at(s,e)
    if l==nil || l.pass==s.state.pass {return}
    if l.kind==.None && !l.refused {
        if s.budget==0 {
            s.waiting=true
            return
        }
        s.budget-=1
    }
    l.pass=s.state.pass
    rigid,has_rigid:=core.get(s.rigids,e)
    collider,has_collider:=core.get(s.colliders,e)
    config,has_character:=core.get(s.characters,e)
    if has_collider && collider.kind==.External {has_collider=false}
    owner:=core.NONE
    if !has_rigid && !has_character && has_collider {owner=compound_owner(s,e)}
    switch {
    case has_character:
        if l.kind!=.Character && l.kind!=.None {link_release(s,l)}
        character_sync(s,e,l,config,collider,has_collider)
    case owner!=core.NONE:
        compound_sync(s,e,l,collider,owner)
    case has_rigid || has_collider:
        if l.kind==.Compound || l.kind==.Character {link_release(s,l)}
        body_sync(s,e,l,rigid,has_rigid,collider,has_collider)
    }
}

@(private)
body_sync :: proc(s:^Sync,e:core.Entity,l:^Link,rigid:Rigid_Body,has_rigid:bool,collider:Collider,has_collider:bool) {
    state:=s.state
    w:=&state.world
    world:=world_pose(s,e)
    pose:=sim.Transform{world.position,world.rotation}
    scale:=linalg.abs(world.scale)
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
        l.kind,l.rigid,l.has_rigid=.Body,rigid,has_rigid
        state.stats.bodies_created+=1
        created,mass_changed=true,true
        if linear,angular:=made_velocity(s,e);type!=.Static && (linear!={} || angular!={}) {
            sim.body_set_velocity(w,l.body,linear,angular)
        }
        target_made(state,l,s.targets,e)
    } else if l.rigid!=rigid || l.has_rigid!=has_rigid {
        effective:=l.hold.by!={}?Body_Type.Kinematic:type
        if sim.body_type(w,l.body)!=effective {sim.body_set_type(w,l.body,effective)}
        if has_rigid {
            sim.body_set_damping(w,l.body,rigid.linear_damping,rigid.angular_damping)
            sim.body_set_gravity_scale(w,l.body,rigid.gravity_scale)
            sim.body_set_locks(w,l.body,body_locks(rigid.locks))
            sim.body_set_bullet(w,l.body,rigid.bullet)
        }
        l.rigid,l.has_rigid=rigid,has_rigid
        mass_changed=true
    }

    if !has_collider {
        if l.shape!={} {
            sim.shape_destroy(w,l.shape)
            l.shape={}
            state.stats.shapes_destroyed+=1+pieces_shapes_destroy(s,l)
            mass_changed=true
        }
        geometry_release(s,l)
        l.has_collider,l.collider,l.refused=false,{},false
    } else {
        shown:=shown_of(s,e,collider,l.shown)
        filter:=collision_of(s,e,l,collider)
        same:=l.has_collider && collider_shape_same(l.collider,collider)
        changed:=!same || l.scale!=scale || l.shown!=shown
        if changed && same && l.scale==scale && l.shown.generated && shown.generated && sim.shape_valid(w,l.shape) && collider_geometry_unchanged(s,l,e) {
            l.shown=shown
            changed=false
        }
        if changed || link_shapes_lost(s,l) {
            if l.shape!={} {
                sim.shape_destroy(w,l.shape)
                state.stats.shapes_destroyed+=1+pieces_shapes_destroy(s,l)
            }
            geometry_release(s,l)
            if failure:=collider_shapes_make(s,l,e,l.body,collider,scale,filter);failure!=.None {shape_problem(s,e,collider,failure)}
            l.has_collider,l.scale,l.shown=true,scale,shown
            mass_changed=true
        } else {shapes_restyle(s,l,collider,filter)}
        l.collider,l.filter=collider,filter
    }
    if mass_changed {body_mass_update(w,l.body,rigid,has_rigid)}

    local,has_local:=core.get(s.locals,e)
    if created {
        if has_local {l.written_position,l.written_rotation=local.position,local.rotation}
    } else if s.playing && (has_rigid || l.hold.by!={}) {
        if foreign_write(s,l,e,has_rigid?"Rigid_Body":"physics manipulation",pose_differs(sim.body_transform(w,l.body),pose)) {
            sim.body_set_transform(w,l.body,pose.p,pose.q)
            l.written_position,l.written_rotation=local.position,local.rotation
            state.stats.teleports+=1
        }
    } else if pose_differs(sim.body_transform(w,l.body),pose) {
        sim.body_set_transform(w,l.body,pose.p,pose.q)
        state.stats.teleports+=1
    }
    if !s.playing && has_local {l.written_position,l.written_rotation=local.position,local.rotation}
    l.placed=pose
    if s.playing && has_rigid && type!=.Static && !core.has(s.motions,e) {core.add(s.motions,e,core.Motion{})}
}

@(private)
compound_owner :: proc(s:^Sync,e:core.Entity) -> core.Entity {
    parent,_:=core.get(s.parents,e)
    return core.ancestor_with(s.parents,s.rigids,parent.entity)
}

// Where e is in the frame of the body of owner, which has no scale: its
// Transform and those between the two, under the world scale of owner. It
// does not depend on where the body is, so it only changes with them.
@(private)
compound_relative :: proc(s:^Sync,e,owner:core.Entity) -> mm.Transform {
    chain:[64]core.Entity
    depth:=0
    for at:=e;at!=owner && at!=core.NONE && depth<len(chain); {
        chain[depth]=at
        depth+=1
        parent,ok:=core.get(s.parents,at)
        at=ok?parent.entity:core.NONE
    }
    relative:=mm.TRANSFORM_IDENTITY
    if above,ok:=core.world_of(s.locals,s.parents,owner);ok {relative.scale=above.scale}
    #reverse for at in chain[:depth] {
        if local,ok:=core.get(s.locals,at);ok {relative=mm.transform_compose(relative,core.to_math(local))}
    }
    return relative
}

@(private)
compound_sync :: proc(s:^Sync,e:core.Entity,l:^Link,collider:Collider,owner:core.Entity) {
    state:=s.state
    w:=&state.world
    if l.kind==.Body || l.kind==.Character || l.kind==.Compound && l.owner!=owner {link_release(s,l)}
    holder:=link_at(s,owner)
    if holder!=nil && holder.pass!=state.pass {entity_sync(s,owner)}
    if holder==nil || holder.kind!=.Body || !sim.body_valid(w,holder.body) {
        link_release(s,l)
        s.unmade=true
        return
    }
    relative:=compound_relative(s,e,owner)
    scale:=linalg.abs(relative.scale)
    shown:=shown_of(s,e,collider,l.shown)
    filter:=collision_of(s,e,l,collider)
    same:=l.kind==.Compound && l.has_collider && collider_shape_same(l.collider,collider)
    changed:=!same || l.scale!=scale || l.relative!=relative || l.shown!=shown || l.body!=holder.body
    if changed && same && l.scale==scale && l.relative==relative && l.body==holder.body && l.shown.generated && shown.generated && sim.shape_valid(w,l.shape) && collider_geometry_unchanged(s,l,e,relative) {
        l.shown=shown
        changed=false
    }
    if !changed && !link_shapes_lost(s,l) {
        shapes_restyle(s,l,collider,filter)
        l.collider,l.filter=collider,filter
        return
    }
    if sim.shape_valid(w,l.shape) {
        sim.shape_destroy(w,l.shape)
        state.stats.shapes_destroyed+=1
    }
    state.stats.shapes_destroyed+=pieces_shapes_destroy(s,l)
    geometry_release(s,l)
    if failure:=collider_shapes_make(s,l,e,holder.body,collider,scale,filter,&relative);failure!=.None {shape_problem(s,e,collider,failure)}
    l.kind,l.owner,l.body=.Compound,owner,holder.body
    l.has_collider,l.collider,l.filter,l.scale,l.relative,l.shown=true,collider,filter,scale,relative,shown
    body_mass_update(w,holder.body,holder.rigid,holder.has_rigid)
}

@(private)
shown_of :: proc(s:^Sync,e:core.Entity,collider:Collider,previous:Shown) -> (shown:Shown) {
    if collider.kind!=.Hull && collider.kind!=.Mesh && collider.kind!=.Heightfield {return}
    if static,has:=core.get(s.statics,e);has {shown.mesh,shown.shape=static.mesh,static.shape}
    shown.generated=host.assets_mesh_generated(s.app.assets,shown.mesh) || previous.generated && previous.mesh==shown.mesh
    if s.app.assets!=nil && !shown.generated {shown.revision=s.app.assets.revision}
    return
}

// The mass of a dynamic body from the shapes it has now: by their density, or scaled to the mass its Rigid_Body gives.
@(private)
body_mass_update :: proc(w:^sim.World,body:sim.Body_Handle,rigid:Rigid_Body,has_rigid:bool) {
    if !has_rigid || rigid.type!=.Dynamic {return}
    sim.body_reset_mass_properties(w,body)
    if rigid.mass<=0 {return}
    if mass,center,inertia:=sim.body_mass_properties(w,body);mass>0 {
        factor:=rigid.mass/mass
        for row in 0..<3 {
            for column in 0..<3 {inertia[row,column]*=factor}
        }
        sim.body_set_mass_properties(w,body,rigid.mass,center,inertia)
    }
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
        if destroyed>0 {
            if holder:=link_find(state,l.owner);holder!=nil && holder.kind==.Body {body_mass_update(w,holder.body,holder.rigid,holder.has_rigid)}
        }
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
    l^={pass=l.pass}
}

HEIGHT_EPSILON :: f32(1e-4) // m of capsule height that are no change

// Makes the capsule of a character as tall as its move asks (0: that of its Collider, which it is
// never taller than) before it steps: shorter at once, taller when nothing over it is in the way.
@(private)
character_height_set :: proc(w:^sim.World,l:^Link,e:core.Entity,asked:f32) {
    full:=character_desc(l.config,l.collider,l.scale,l.filter,e).height
    want:=asked
    if !(want>0) || want>full {want=full}
    l.height_asked=want
    if abs(sim.character_desc(w,l.character).height-want)>HEIGHT_EPSILON {_=sim.character_set_height(w,l.character,want)}
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

// The part of a character that is kept as it was made.
@(private)
character_shape_same :: proc "contextless" (l:^Link,c:Character,capsule:Collider,scale:[3]f32) -> bool {
    return l.config.mass==c.mass && l.config.step_height==c.step_height && collider_shape_same(l.collider,capsule) && l.scale==scale
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

// The frame of the vertical of the character of e: the identity without one.
up_frame_of :: proc(physics:core.Ref(Physics_State),e:core.Entity) -> mm.Quat {
    if physics.ptr==nil || !physics.ready {return mm.QUAT_IDENTITY}
    l:=link_find(physics.ptr,e)
    if l==nil || l.kind!=.Character || !sim.character_valid(&physics.world,l.character) {return mm.QUAT_IDENTITY}
    return sim.character_state(&physics.world,l.character).up_frame
}

@(private)
character_sync :: proc(s:^Sync,e:core.Entity,l:^Link,config:Character,capsule:Collider,has_capsule:bool) {
    state:=s.state
    w:=&state.world
    if !has_capsule || capsule.kind!=.Capsule {
        if !l.refused || !character_body_same(l.config,config) || l.collider!=capsule {
            core.report(s.problems,e,"physics.character_capsule","its Character is not made: it moves as the Collider of kind Capsule of the entity, and it has %s; give it physics.collider_character() or a capsule of its own",has_capsule?"another kind":"none")
        }
        l.refused,l.config,l.collider=true,config,capsule
        return
    }
    world:=world_pose(s,e)
    scale:=linalg.abs(world.scale)
    filter:=collision_of(s,e,l,capsule)
    desc:=character_desc(config,capsule,scale,filter,e)
    local,has_local:=core.get(s.locals,e)
    if l.kind==.Character && sim.character_valid(w,l.character) && character_shape_same(l,config,capsule,scale) {
        if !character_body_same(l.config,config) || l.collider.drag!=capsule.drag {sim.character_set_desc(w,l.character,desc)}
        if l.config.locks!=config.locks {sim.character_set_locks(w,l.character,body_locks(config.locks))}
        if l.filter!=filter {sim.character_set_filter(w,l.character,filter)}
        if !collider_surface_same(l.collider,capsule) {surface_set(w,sim.character_shape(w,l.character),capsule)}
        l.config,l.collider,l.filter=config,capsule,filter
        if s.playing {
            character_rows(s,e)
            offset:=sim.character_position(w,l.character)-world.position
            moved:=linalg.dot(offset,offset)>POSE_EPSILON*POSE_EPSILON
            // A write that turns it where it is cannot be taken: its turn is that of its move and its vertical.
            if !moved && has_local && (local.position!=l.written_position || local.rotation!=l.written_rotation) {
                held:=sim.body_rotation(w,sim.character_body(w,l.character))
                if pose_differs({world.position,held},{world.position,world.rotation}) {
                    core.report(s.problems,e,"physics.character_turn","Character %q was turned by another function while it plays, and a Character turns with its move and its vertical: turn it with the look of its Move_Input, or put it turned with core.place(placer,entity,position,rotation)",core.name_get(s.names,e))
                }
            }
            if foreign_write(s,l,e,"Character",moved) {
                sim.character_set_position(w,l.character,world.position)
                l.written_position,l.written_rotation=local.position,local.rotation
                state.stats.teleports+=1
            }
            return
        }
        offset:=sim.character_position(w,l.character)-world.position
        if linalg.dot(offset,offset)>POSE_EPSILON*POSE_EPSILON {
            sim.character_set_position(w,l.character,world.position)
            state.stats.teleports+=1
        }
        if l.placed.q!=world.rotation {
            sim.character_set_rotation(w,l.character,world.rotation)
            l.placed.q=world.rotation
        }
        if has_local {l.written_position,l.written_rotation=local.position,local.rotation}
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
    l.kind,l.config,l.collider,l.filter,l.scale=.Character,config,capsule,filter,scale
    l.placed={position,world.rotation}
    target_made(state,l,s.targets,e)
    if has_local {l.written_position,l.written_rotation=local.position,local.rotation}
    if s.playing {character_rows(s,e)}
}

// The velocities a body is made with: those of its pose target, or those a saved
// game left in its Motion.
@(private)
made_velocity :: proc(s:^Sync,e:core.Entity) -> (linear,angular:[3]f32) {
    if target,on:=core.get(s.targets,e);on {return target.linear,target.angular}
    if held:=core.get(s.motions,e);held!=nil {return held.linear,held.angular}
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

// Whether two colliders make the same shape; what differs in their collision is a new filter of that shape.
@(private)
collider_shape_same :: proc "contextless" (a,b:Collider) -> bool {
    return a.kind==b.kind && a.size==b.size && a.convex_radius==b.convex_radius && a.center==b.center && a.friction==b.friction && a.restitution==b.restitution && a.density==b.density
}

// The filter of a collider under the settings of the world. A preset the code does not declare is
// reported once, when the collider or the settings change; it is the Default category colliding with
// every category.
@(private)
collision_of :: proc(s:^Sync,e:core.Entity,l:^Link,collider:Collider) -> sim.Filter {
    filter:=collision_filter(s.collision,collider)
    if l.collider==collider && !s.collision_changed {return filter}
    info:=s.app!=nil?s.app.info:nil
    if collider.preset!=PRESET_CUSTOM && !collision_declared(info,Collision_Preset,i64(collider.preset)) {
        core.report(s.problems,e,"physics.collision","its Collider uses collision preset %d, which no code declares; choose a declared preset, or declare it (PRESET_NAME :: physics.Collision_Preset(%d))",collider.preset,collider.preset)
    }
    return filter
}

@(private)
collider_desc :: proc "contextless" (collider:Collider,scale:[3]f32,filter:sim.Filter,e:core.Entity) -> sim.Shape_Desc {
    desc:=sim.SHAPE_DESC_DEFAULT
    switch collider.kind {
    case .Hull,.Mesh,.Heightfield,.External:
    case .Box:     desc.geometry=sim.Box{collider.size*scale}
    case .Sphere:  desc.geometry=sim.Sphere{collider.size.x*max(scale.x,scale.y,scale.z)}
    case .Capsule: desc.geometry=sim.Capsule{collider.size.x*max(scale.x,scale.z),collider.size.y*scale.y}
    case .Cylinder: desc.geometry=sim.Cylinder{collider.size.x*max(scale.x,scale.z),collider.size.y*scale.y}
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
// alike but for their hull. Those of a compound go where relative puts the entity. Nothing stays made when
// one fails.
@(private)
collider_shapes_make :: proc(s:^Sync,l:^Link,e:core.Entity,body:sim.Body_Handle,collider:Collider,scale:[3]f32,filter:sim.Filter,relative:^mm.Transform=nil) -> Shape_Failure {
    state:=s.state
    w:=&state.world
    desc:=collider_desc(collider,scale,filter,e)
    failure:=collider_round_fits(collider,scale)?Shape_Failure.None:.Convex_Radius
    pieces:bool
    if failure==.None && collider.kind==.Hull {
        pieces,failure=collider_pieces_make(s,l,e,scale,desc.convex_radius)
        if pieces {desc.geometry=l.hull}
    }
    if failure==.None && !pieces && (collider.kind==.Hull || collider.kind==.Mesh || collider.kind==.Heightfield) {
        origin:[3]f32
        desc.geometry,origin,failure=collider_geometry(s,l,collider.kind,e,scale,desc.convex_radius)
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

// Gives the shapes of a link the filter and the surface of its collider.
@(private)
shapes_restyle :: proc(s:^Sync,l:^Link,collider:Collider,filter:sim.Filter) {
    w:=&s.state.world
    restyle :: proc(w:^sim.World,l:^Link,shape:sim.Shape_Handle,collider:Collider,filter:sim.Filter) {
        if l.filter!=filter {sim.shape_set_filter(w,shape,filter)}
        if !collider_surface_same(l.collider,collider) {surface_set(w,shape,collider)}
    }
    restyle(w,l,l.shape,collider,filter)
    for piece in pieces_of(s.state,l) {restyle(w,l,piece.shape,collider,filter)}
}

// Whether two colliders give their contacts the same rules; a change is applied to the shape as it is.
@(private)
collider_surface_same :: proc "contextless" (a,b:Collider) -> bool {
    return a.surface_speed==b.surface_speed && a.one_way==b.one_way && a.dominance==b.dominance && a.drag==b.drag
}

@(private)
surface_set :: proc(w:^sim.World,shape:sim.Shape_Handle,collider:Collider) {
    sim.shape_set_surface(w,shape,collider.surface_speed,collider.one_way,collider.dominance)
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

@(private)
requests_apply :: proc(s:^Sync,requests:[]Body_Request) {
    state:=s.state
    w:=&state.world
    for request in requests {
        if request.kind==.Box_Force || request.kind==.Sphere_Force || request.kind==.Box_Radial_Force || request.kind==.Plane_Force {
            ok:bool
            range,noise:=request.falloff_range,request.noise
            #partial switch request.kind {
            case .Box_Force: _,ok=sim.world_apply_box_force(w,request.position,request.half_extents,request.rotation,request.linear,request.falloff,request.filter,range,noise)
            case .Sphere_Force: _,ok=sim.world_apply_sphere_force(w,request.position,request.radius,request.linear,request.falloff,request.filter,range,noise)
            case .Box_Radial_Force: _,ok=sim.world_apply_box_radial_force(w,request.position,request.half_extents,request.rotation,request.strength,request.falloff,request.filter,range,noise)
            case .Plane_Force: _,ok=sim.world_apply_plane_force(w,request.position,request.half_extents,request.rotation,request.linear,request.falloff,request.filter,range,noise)
            }
            if !ok {area_problem(s,request)}
            continue
        }
        if request.kind==.Radial_Force || request.kind==.Radial_Impulse {
            _,ok:=sim.world_apply_radial(w,request.position,request.radius,request.strength,request.falloff,request.kind==.Radial_Impulse,request.override,request.filter,request.falloff_range,request.noise)
            if !ok {area_problem(s,request)}
            continue
        }
        e:=request.entity
        valid:=true
        for value in request.linear {valid=valid && value>=-max(f32) && value<=max(f32)}
        for value in request.angular {valid=valid && value>=-max(f32) && value<=max(f32)}
        if request.at_point {for value in request.point {valid=valid && value>=-max(f32) && value<=max(f32)}}
        if !valid {
            request_problem(s,e,request.kind,"physics.request_value","its linear, angular or point values are not finite","send finite values")
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
            case .Impulse:          sim.character_launch(w,l.character,request.linear/max(l.config.mass,1e-3))
            case .Force:            sim.body_apply_force(w,sim.character_body(w,l.character),request.linear)
            case .Radial_Force,.Radial_Impulse,.Box_Force,.Sphere_Force,.Box_Radial_Force,.Plane_Force:
            case .Kinematic,.Manipulate,.Release_Manipulation: request_problem(s,e,request.kind,"physics.request_character","a Character moves by its Character_Move","teleport it, give it a velocity or an impulse, or write its Character_Move")
            }
            continue
        }
        if !sim.body_valid(w,l.body) {
            request_problem(s,e,request.kind,"physics.request_body","its body was not made","read the problems of the entity about its body and fix them")
            continue
        }
        switch request.kind {
        case .Teleport:
            was:=sim.body_transform(w,l.body)
            jumped(s,e,was.p,rotation*conj(was.q),request.position)
            sim.body_set_transform(w,l.body,request.position,rotation)
            pose_write(s,l,e,{request.position,rotation})
            l.placed={request.position,rotation}
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
        case .Radial_Force,.Radial_Impulse,.Box_Force,.Sphere_Force,.Box_Radial_Force,.Plane_Force:
        case .Kinematic:
            if s.playing {
                sim.body_set_kinematic_target(w,l.body,request.position,rotation,s.dt)
            } else {
                sim.body_set_transform(w,l.body,request.position,rotation)
                pose_write(s,l,e,{request.position,rotation})
            }
        case .Manipulate:
            valid:=true
            for value in request.position {valid=valid && value<=max(f32) && value>=-max(f32)}
            for value in ([4]f32{rotation.x,rotation.y,rotation.z,rotation.w}) {valid=valid && value<=max(f32) && value>=-max(f32)}
            if !valid {
                request_problem(s,e,request.kind,"physics.request_value","its position or rotation is not finite","send finite values")
                continue
            }
            qscale:=max(abs(rotation.x),abs(rotation.y),abs(rotation.z),abs(rotation.w))
            rotation=linalg.normalize(quaternion(x=rotation.x/qscale,y=rotation.y/qscale,z=rotation.z/qscale,w=rotation.w/qscale))
            // Another link of the same body hands over its manipulation, and the type the body had.
            for &other in state.links.values {
                if &other==l || other.body!=l.body || .Manipulation not_in other.hold.by {continue}
                if l.hold.by=={} {l.hold.type_before=other.hold.type_before;l.hold.by+={.Manipulation}}
                other.hold.by-={.Manipulation}
                other.hold.release=false
            }
            hold_begin(w,l,.Manipulation,{request.position,rotation})
            l.hold.release,l.hold.keep_velocity=false,false
            // A body its pose target holds heads for the manipulation once the target lets it go.
            if .Target in l.hold.by {continue}
            if s.playing {
                sim.body_set_kinematic_target(w,l.body,request.position,rotation,s.dt)
            } else {
                sim.body_set_transform(w,l.body,request.position,rotation)
                sim.body_set_velocity(w,l.body,{},{})
                pose_write(s,l,e,sim.body_transform(w,l.body))
            }
        case .Release_Manipulation:
            if .Manipulation in l.hold.by {
                l.hold.release,l.hold.keep_velocity=true,request.override
                if !s.playing || .Target in l.hold.by || !pose_differs(sim.body_transform(w,l.body),l.hold.pose[.Manipulation]) {hold_end(w,l,.Manipulation,l.hold.keep_velocity)}
            }
        }
    }
}

// A force or impulse over a volume that the simulation refused.
@(private)
area_problem :: proc(s:^Sync,request:Body_Request) {
    core.report(s.problems,core.NONE,"physics.request_area","a %v request of Body_Requests did nothing: its radius or extents are not positive, its values are not finite, its falloff is not a Radial_Falloff, or its noise scale is negative; send a positive size, finite values and a falloff and noise of physics",request.kind)
}

// Brings the pose of what the step moved back into Transform, and the state of bodies and characters.
@(private)
poses_write :: proc(s:^Sync) {
    state:=s.state
    w:=&state.world
    for &l,at in state.links.values {
        e:=state.links.entities[at]
        switch l.kind {
        case .None,.Compound:
        case .Body,.Proxy:
            if l.kind==.Body && (!l.has_rigid || l.rigid.type==.Static) && l.hold.by=={} || !sim.body_valid(w,l.body) {continue}
            awake:=sim.body_is_awake(w,l.body)
            if awake {pose_write(s,&l,e,sim.body_transform(w,l.body))}
            if l.hold.release && l.hold.by=={.Manipulation} && !pose_differs(sim.body_transform(w,l.body),l.hold.pose[.Manipulation]) {
                hold_end(w,&l,.Manipulation,l.hold.keep_velocity)
                awake=sim.body_is_awake(w,l.body)
            }
            motion_write(s,e,l.body,awake,l.kind==.Proxy)
        case .Character:
            if !sim.character_valid(w,l.character) {continue}
            if row:=core.row_of(s.character_states,e);row>=0 {
                next:=character_state_of(sim.character_state(w,l.character))
                next.height=sim.character_desc(w,l.character).height
                next.velocity=sim.character_velocity(w,l.character)
                next.cramped=next.height<l.height_asked-HEIGHT_EPSILON
                if s.character_states.values[row]!=next {core.at(s.character_states,row)^=next}
            }
            body:=sim.character_body(w,l.character)
            motion_write(s,e,body,sim.body_is_awake(w,body),false)
            pose_write(s,&l,e,sim.body_transform(w,body))
        }
    }
}

// The core.Motion of what a body moves; a proxy gets its row here, the others when they are made.
@(private)
motion_write :: proc(s:^Sync,e:core.Entity,body:sim.Body_Handle,awake,add:bool) {
    w:=&s.state.world
    _,center,_:=sim.body_mass_properties(w,body)
    next:=core.Motion{
        linear=sim.body_linear_velocity(w,body),angular=sim.body_angular_velocity(w,body),
        center=center,island=s.grouped?sim.body_group(w,body):0,awake=awake,
    }
    if row:=core.row_of(s.motions,e);row>=0 {
        if s.motions.values[row]!=next {core.at(s.motions,row)^=next}
    } else if add {
        core.add(s.motions,e,next)
    }
}

// The rows of what the step leaves of a character.
@(private)
character_rows :: proc(s:^Sync,e:core.Entity) {
    if !core.has(s.character_states,e) {core.add(s.character_states,e,Character_State{})}
    if !core.has(s.motions,e) {core.add(s.motions,e,core.Motion{})}
}

// A source holds the body as kinematic toward pose; the first one makes it kinematic.
@(private)
hold_begin :: proc(w:^sim.World,l:^Link,source:Hold_Source,pose:sim.Transform) {
    if l.hold.by=={} {
        l.hold.type_before=sim.body_type(w,l.body)
        sim.body_set_type(w,l.body,.Kinematic)
    }
    l.hold.by+={source}
    l.hold.pose[source]=pose
}

// A source lets go. When none holds the body any more it has its own type
// again: moving as it was with keep_velocity, else at rest.
@(private)
hold_end :: proc(w:^sim.World,l:^Link,source:Hold_Source,keep_velocity:bool) {
    if source not_in l.hold.by {return}
    l.hold.by-={source}
    if source==.Manipulation {l.hold.release,l.hold.keep_velocity=false,false}
    if l.hold.by!={} || !sim.body_valid(w,l.body) {return}
    if !keep_velocity {sim.body_set_velocity(w,l.body,{},{})}
    sim.body_set_type(w,l.body,l.kind==.Proxy?l.hold.type_before:(l.has_rigid?l.rigid.type:Body_Type.Static))
    if l.kind!=.Proxy {body_mass_update(w,l.body,l.rigid,l.has_rigid)}
}

// Where a held body heads: its pose target first.
@(private)
hold_pose :: proc "contextless" (h:Hold) -> sim.Transform {return .Target in h.by?h.pose[.Target]:h.pose[.Manipulation]}

// Sends the events of the simulation not sent yet. The step clears them, so
// what woke or slept between two steps is sent before the next one.
@(private)
events_forward :: proc(s:^Sync,events:^Physics_Events,sent:^[6]int) {
    w:=&s.state.world
    named :: proc(w:^sim.World,body:sim.Body_Handle) -> core.Entity {return core.Entity(sim.body_user_data(w,body))}
    of :: proc(w:^sim.World,shape:sim.Shape_Handle) -> core.Entity {return core.Entity(sim.shape_user_data(w,shape))}
    list:=sim.world_events(w)
    lengths:=[6]int{len(list.contact_begin),len(list.contact_end),len(list.overlap_begin),len(list.overlap_end),len(list.sleep),len(list.wake)}
    for &count,i in sent {count=min(count,lengths[i])}
    for event in list.contact_begin[sent[0]:] {
        core.push(&events.contact_begin,Contact_Begin{
            a=named(w,event.body_a),b=named(w,event.body_b),collider_a=of(w,event.shape_a),collider_b=of(w,event.shape_b),
            point=event.point,normal=event.normal,impulse=event.impulse,
        })
    }
    for event in list.contact_end[sent[1]:] {core.push(&events.contact_end,Contact_End{named(w,event.body_a),named(w,event.body_b),of(w,event.shape_a),of(w,event.shape_b)})}
    for event in list.overlap_begin[sent[2]:] {core.push(&events.overlap_begin,Overlap_Event{named(w,event.body),named(w,event.other_body),of(w,event.shape),of(w,event.other),event.crossed})}
    for event in list.overlap_end[sent[3]:] {core.push(&events.overlap_end,Overlap_Event{named(w,event.body),named(w,event.other_body),of(w,event.shape),of(w,event.other),event.crossed})}
    for event in list.sleep[sent[4]:] {core.push(&events.sleep,Body_Event{core.Entity(event.user_data)})}
    for event in list.wake[sent[5]:] {core.push(&events.wake,Body_Event{core.Entity(event.user_data)})}
    sent^=lengths
}
