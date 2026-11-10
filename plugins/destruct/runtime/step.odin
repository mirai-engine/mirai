package destruct

import "core:math/linalg"
import "core:strings"
import "mirai:core"
import render "mirai:engine/render"
import physics "plugins:physics/runtime"
import "mirai:host"
import "mirai:std/jobs"
import sim "plugins:physics/runtime/sim"
import fr "plugins:destruct/runtime/fracture"
import "mirai:std/base"

// Keeps the destructibles of the simulation equal to the Destructible rows,
// applies the damage the game asks for, and keeps what draws them equal to
// what the simulation says became of their pieces. The simulation is the one
// of physics: a destructible is made in its world, so its pieces
// collide with everything else, and its bodies name the entity of the
// destructible. What decides the groups is the state of the simulation, never
// the event that changed it: the revision of the destructible says when to
// look again, so a world that went back in time is mirrored like any other.
// The server of a network session is the one that damages; net.odin replicates it.

@(private)
Ctx :: struct {
    state:^physics.Physics_State,
    w:^sim.World,
    f:^fr.Fracture,
    cache:^Destruct_Cache,
    events:^Destruct_Events,
    assets:^host.Assets,
    job_system:^jobs.Job_System,
    time:core.Time,
    es:^core.Entities,
    commands:core.Commands,
    authority:core.Network_Role, // in a network session the server damages, and a client only applies what it is told
    destructibles:core.Read(Destructible),
    colliders:core.Read(physics.Collider),
    collision:^physics.Collision_Settings,
    meshes:^core.Table(render.Mesh_Renderer),
    tints:^core.Table(render.Tint),
    parents:core.Read(core.Parent),
    locals:core.Read(core.Transform),
    states:^core.Table(Destructible_State),
    groups:^core.Table(Destructible_Group),
    elsewhere:^core.Table(render.Drawn_Elsewhere),
    transforms:^core.Table(core.Transform),
    ids:^core.Table(core.Id),
    problems:^core.Problems,
}

// Destruct makes its destructibles and the proxies of their pieces in the
// simulation of physics (Physics_State is shared), gives the entities of the
// pieces their mesh and tint, and makes them with commands. The step of the
// simulation that just ran damages them first.
@(step="fixed",stage="react")
destruct_step :: proc(
    state:^physics.Physics_State,fractures:^Fracture_State,settings:core.Ref(Destruct_Settings),cache:^Destruct_Cache,requests:^Destruct_Requests,events:^Destruct_Events,
    authority:core.Ref(core.Network),assets:^host.Assets,job_system:^jobs.Job_System,time:core.Time,commands:core.Commands,
    destructibles:core.Read(Destructible),meshes:^core.Table(render.Mesh_Renderer),tints:^core.Table(render.Tint),parents:core.Read(core.Parent),
    states:^core.Table(Destructible_State),groups:^core.Table(Destructible_Group),
    elsewhere:^core.Table(render.Drawn_Elsewhere),transforms:^core.Table(core.Transform),ids:^core.Table(core.Id),
    colliders:core.Read(physics.Collider),collision:core.Ref(physics.Collision_Settings),problems:^core.Problems,
) {
    core.queue_clear(&events.fractured)
    core.queue_clear(&events.applied)
    core.queue_clear(&events.replayed)
    core.queue_clear(&events.grouped)
    if cache==nil || !state.ready || !time.playing || time.dt<=0 {return}
    if !fracture_state_make(fractures,settings.ptr,&state.world,problems) {return}
    if !cache_make(cache,&fractures.fracture) {
        core.report(problems,core.NONE,"destruct.memory","out of memory for the %d pieces of Destruct_Settings and the %d bodies of Physics_Settings; nothing breaks until there is: lower them, or free memory",fractures.fracture.desc.pieces,fractures.fracture.desc.bodies)
        return
    }
    fr.fracture_update(&fractures.fracture,&state.world)
    pending:=core.take(&requests.queue)
    waiting:=core.take(&requests.waiting)
    replays:=core.take(&requests.replays)
    states_asked:=core.take(&requests.states)
    if physics.simulation_replaced(state,&cache.epoch) {cache_reset(assets,job_system,cache)}
    cache.pass+=1
    c:=Ctx{
        state=state,w=&state.world,f=&fractures.fracture,cache=cache,events=events,assets=assets,job_system=job_system,time=time,es=commands.entities,commands=commands,
        authority=authority.role,
        destructibles=destructibles,colliders=colliders,collision=collision.ptr,meshes=meshes,tints=tints,parents=parents,locals=core.read(transforms),
        states=states,groups=groups,elsewhere=elsewhere,transforms=transforms,ids=ids,problems=problems,
    }
    gone,at:=core.changes(destructibles,&cache.seen),0
    entry:Entry
    for e in core.entity_map_left(&cache.entries,destructibles,gone,&at,&entry) {
        entity_end(&c,e,&entry)
        entry_release(assets,job_system,cache,&entry)
    }
    for row in 0..<core.count(destructibles) {reconcile(&c,core.entity_at(destructibles,row),core.at(destructibles,row))}
    events_apply(&c,waiting,pending,&requests.waiting)
    for row in 0..<core.count(c.states) {shortfall_report(&c,c.states.entities[row],c.states.values[row].handle)}
    replays_apply(&c,states_asked,replays)
    for row in 0..<core.count(destructibles) {follow(&c,core.entity_at(destructibles,row))}
    groups_prune(&c)
}

// Ends what exists for a destructible: its simulation destructible, its entities and the marks on its own.
@(private)
entity_end :: proc(c:^Ctx,e:core.Entity,entry:^Entry) {
    physics.proxy_remove(c.state,e)
    if st:=core.get(c.states,e);st!=nil {
        if fr.destructible_valid(c.f,st.handle) {
            fr.destructible_destroy(c.f,c.w,st.handle)
            c.cache.stats.destroyed+=1
        }
        core.remove(c.states,e)
    } else if handle:=fr.destructible_find(c.f,u64(e));handle!=0 {
        fr.destructible_destroy(c.f,c.w,handle)
        c.cache.stats.destroyed+=1
    }
    groups_end(c,entry)
    if core.has(c.elsewhere,e) {core.remove(c.elsewhere,e)}
}

@(private)
groups_end :: proc(c:^Ctx,entry:^Entry) {
    for &group in entry.groups {
        physics.proxy_remove(c.state,group.entity)
        if core.alive(c.es,group.entity) {core.destroy(c.es,group.entity)}
    }
    groups_release(c.assets,c.cache,entry)
}

// The simulation destructible of one entity made match its row: made, made
// again when what it is made from changed, or left as it is.
@(private)
reconcile :: proc(c:^Ctx,e:core.Entity,d:Destructible) {
    cache:=c.cache
    w:=c.w
    f:=c.f
    held:Destructible_State
    has:bool
    held,has=core.get(core.read(c.states),e)
    st:=held
    static,has_mesh:=core.get(core.read(c.meshes),e)
    world,placed:=core.world_of(c.locals,c.parents,e)
    scale:=linalg.abs(world.scale)
    entry:=entry_take(cache,e)
    if entry==nil {
        core.report(c.problems,e,"destruct.memory","out of memory for the Destructible of this entity; it waits for the next tick: free memory")
        return
    }
    valid:=fr.destructible_valid(f,st.handle)
    collider,has_collider:=core.get(c.colliders,e)
    if !has_collider || collider.kind!=.External {collider={}}
    surface:=[3]f32{collider.density,collider.friction,collider.restitution}
    filter:=physics.collision_filter(c.collision,collider)
    same:=st.configured && st.applied==d && st.applied_surface==surface && st.applied_mesh==static.mesh && st.applied_shape==static.shape && st.applied_scale==scale && st.passive==(c.authority==.Client)
    if same && (valid || st.failed) {
        if valid && st.applied_filter!=filter {
            fr.destructible_set_filter(f,w,st.handle,filter)
            st.applied_filter=filter
            core.add(c.states,e,st)
        }
        if valid {
            if local,has_local:=core.get(c.locals,e);has_local {physics.proxy_set(c.state,e,st.body,local.position,local.rotation)}
            if len(entry.visuals)==0 {cache_recover(c,e,d,static,scale,entry)}
        }
        return
    }
    if !(st.waiting && same) {
        if valid {
            fr.destructible_destroy(f,w,st.handle)
            cache.stats.destroyed+=1
        }
        groups_end(c,entry)
        visuals_release(entry)
        if core.has(c.elsewhere,e) {core.remove(c.elsewhere,e)}
        st=Destructible_State{}
    }
    st.configured,st.applied,st.applied_mesh,st.applied_shape,st.applied_scale=true,d,static.mesh,static.shape,scale
    st.applied_surface,st.applied_filter=surface,filter
    st.passive=c.authority==.Client
    st.failed,st.waiting=true,false
    defer {
        if st!=held || !has {core.add(c.states,e,st)}
        entry.pass=cache.pass
    }
    if !has_mesh || !placed || scale.x==0 || scale.y==0 || scale.z==0 {
        why:=!has_mesh?"it has no Mesh_Renderer":!placed?"it has no Transform":"its scale has a zero axis"
        core.report(c.problems,e,"destruct.mesh","its Destructible has nothing to fracture: %s; give it a Mesh_Renderer with a closed mesh and a scale without zero axes",why)
        return
    }
    if collider.kind!=.External {
        core.report(c.problems,e,"destruct.collider","its Destructible needs a Collider of kind External, whose surface and collision its pieces take; give it collider_fracture()")
        return
    }
    if d.fracture=={} && (d.pieces==0 || u64(d.pieces)>u64(len(cache.infos))) {
        core.report(c.problems,e,"destruct.pieces","its Destructible asks for %d pieces, and the world holds %d (Destruct_Settings.pieces); ask for 1 to %d, or raise pieces",d.pieces,len(cache.infos),len(cache.infos))
        return
    }
    _,interior,generated:=slots_of(c.assets,d,static.mesh)
    // One store per value until odin-lang/Odin#7937 (see ODIN_WORKAROUNDS).
    entry.slots=interior+1
    entry.generated=generated
    entry.materials=static.materials
    if interior<render.MATERIAL_SLOTS && d.interior=={} {entry.materials[interior]=static.materials[0]}
    key:=Prepared_Key{pieces=d.pieces,seed=d.seed,pattern=d.pattern,mesh=static.mesh,fracture=d.fracture,shape=static.shape,scale=scale,interior=interior}
    if entry.prepared==nil || entry.prepared.key!=key {
        if !prepare_start(c.assets,c.job_system,entry,d,static,scale,interior) {
            name:[base.ASSET_ID_TEXT]u8
            core.report(c.problems,e,"destruct.geometry","mesh %s of its Destructible has no geometry to fracture: the mesh is missing or has no triangles, or memory ran out; give Mesh_Renderer.mesh a closed mesh of the assets",host.assets_name(c.assets,static.mesh,&name))
            return
        }
    }
    p:=entry.prepared
    if prepared_pending(p) {
        st.failed,st.waiting=false,true
        return
    }
    if p.error==.Out_Of_Memory {
        name:[base.ASSET_ID_TEXT]u8
        core.report(c.problems,e,"destruct.memory","no memory to fracture mesh %s of its Destructible: it stays whole; free memory or lower Destructible.pieces",host.assets_name(c.assets,static.mesh,&name))
        return
    }
    if p.error!=.None {
        name:[base.ASSET_ID_TEXT]u8
        core.report(c.problems,e,"destruct.fracture","mesh %s of its Destructible cannot be fractured (%v): a mesh breaks only when it is closed; close it in the modelling tool, or give Destructible.fracture a .fracture asset",host.assets_name(c.assets,static.mesh,&name),p.error)
        return
    }
    cache.stats.prepared+=1
    lo,hi:=p.desc.lo,p.desc.hi
    desc:=fr.DESTRUCTIBLE_DESC_DEFAULT
    desc.fracture=&p.fracture
    desc.position,desc.rotation=world.position,world.rotation
    desc.density,desc.friction,desc.restitution,desc.gravity_scale,desc.strength=collider.density,collider.friction,collider.restitution,d.gravity_scale,d.strength
    desc.filter=filter
    desc.kinematic=d.kinematic || d.follow_parent
    desc.hull_vertices=int(d.hull_vertices)
    desc.piece_anchors,desc.piece_clusters,desc.clusters,desc.connection_strength=p.anchors[:],p.piece_clusters[:],p.clusters[:],p.connection_strength[:]
    desc.cluster_points=p.cluster_points[:]
    desc.damage_threshold,desc.damage_radius,desc.debris_volume=d.damage_threshold,d.damage_radius,d.debris_volume
    desc.impact_damage=d.impact_damage && c.authority!=.Client
    if d.debris_lifetime<0 || d.removal_lifetime<0 ||
       d.debris_lifetime-d.debris_lifetime!=0 || d.removal_lifetime-d.removal_lifetime!=0 ||
       f64(d.debris_lifetime)/f64(c.time.dt)>f64(max(u32))-.5 || f64(d.removal_lifetime)/f64(c.time.dt)>f64(max(u32))-.5 {
        core.report(c.problems,e,"destruct.lifetime","Destructible.debris_lifetime (%v s) or removal_lifetime (%v s) is negative, not finite or longer than the ticks can count; give 0 or more seconds",d.debris_lifetime,d.removal_lifetime)
        return
    }
    desc.debris_ticks=u32(core.ticks_of(c.time,d.debris_lifetime))
    desc.removal_ticks=u32(core.ticks_of(c.time,d.removal_lifetime))
    desc.remove_on_sleep=d.remove_on_sleep
    desc.passive_removal=c.authority==.Client
    desc.user_data=u64(e)
    margin:=0.02*(hi-lo)+0.01
    base_box:=[1]sim.Aabb{{lo-margin,{hi.x+margin.x,lo.y+margin.y,hi.z+margin.z}}}
    if d.anchored {desc.anchors=base_box[:]}
    handle,error:=fr.destructible_create(f,w,desc)
    if error!=.None {
        destructible_problem(c,e,error)
        return
    }
    st.failed,st.handle,st.body=false,handle,fr.destructible_body(f,handle)
    cache.stats.created+=1
    if local:=core.get(c.transforms,e);local!=nil {
        st.written_position,st.written_rotation,st.initial=local.position,local.rotation,local^
        physics.proxy_set(c.state,e,st.body,local.position,local.rotation)
    }
    count:=min(fr.destructible_pieces(f,w,handle,cache.infos),len(cache.infos))
    visuals_source(c.problems,e,entry,cache.infos[:count])

}

@(private)
destructible_problem :: proc(c:^Ctx,e:core.Entity,error:fr.Destructible_Error) {
    why,fix:string
    switch error {
    case .None:
    case .Invalid_Desc: why,fix="a value of the Destructible or of its Collider is not valid","give it a positive strength, damage radius and density, and finite values"
    case .Invalid_Mesh: why,fix="the pieces of its mesh are not valid","use a closed mesh, or another .fracture asset"
    case .No_Pieces:    why,fix="its mesh gave no pieces","give it a closed mesh with volume"
    case .Capacity:     why,fix="the fracture or the simulation has no room for it","raise the destructibles, pieces or connections of Destruct_Settings, or the hulls, shapes or bodies of Physics_Settings"
    case .Out_Of_Memory: why,fix="there is no memory to cut its mesh","free memory or lower Destructible.pieces"
    }
    core.report(c.problems,e,"destruct.create","the simulation refused its Destructible: %s; %s",why,fix)
}

@(private,rodata)
CAPACITY_SETTINGS:=[fr.Capacity]string{.Pieces="Destruct_Settings.pieces",.Hulls="Physics_Settings.hulls",.Connections="Destruct_Settings.connections",.Shapes="Physics_Settings.shapes",.Bodies="Physics_Settings.bodies"}

// What the simulation could not give a destructible in this tick, as its problems.
@(private)
shortfall_report :: proc(c:^Ctx,e:core.Entity,handle:fr.Destructible_Handle) {
    events,refused:=fr.destructible_shortfall(c.f,handle)
    if events>0 {
        core.report(c.problems,e,"destruct.events","%d fracture events of its Destructible did not fit in one tick, which lists %d of them (Destruct_Settings.events): their damage was not done, or not sent to the clients; raise events",events,c.f.desc.events)
    }
    if refused=={} {return}
    names:[160]u8
    b:=strings.builder_from_bytes(names[:])
    for capacity in refused {
        if strings.builder_len(b)>0 {strings.write_string(&b,", ")}
        strings.write_string(&b,CAPACITY_SETTINGS[capacity])
    }
    core.report(c.problems,e,"destruct.capacity","the fracture or the simulation had no room for a fracture or a cut of its Destructible, which left those pieces as they were: raise %s; a destructible keeps every piece it cut, removed or let expire until it is destroyed, and a cut takes two pieces and two hulls",strings.to_string(b))
}

@(private)
cache_recover :: proc(c:^Ctx,e:core.Entity,d:Destructible,static:render.Mesh_Renderer,scale:[3]f32,entry:^Entry) {
    st:=core.get(c.states,e)
    if st==nil {return}
    if entry.prepared==nil {
        _,interior,generated:=slots_of(c.assets,d,static.mesh)
        // One store per value until odin-lang/Odin#7937 (see ODIN_WORKAROUNDS).
        entry.slots=interior+1
        entry.generated=generated
        entry.materials=static.materials
        if !prepare_start(c.assets,c.job_system,entry,d,static,scale,interior) {st.failed=true;return}
    }
    st.waiting=prepared_pending(entry.prepared)
    if st.waiting || entry.prepared.error!=.None {return}
    count:=min(fr.destructible_pieces(c.f,c.w,st.handle,c.cache.infos),len(c.cache.infos))
    visuals_source(c.problems,e,entry,c.cache.infos[:count])
    for row in 0..<core.count(c.groups) {
        group:=c.groups.values[row]
        if group.owner!=e {continue}
        entity:=c.groups.entities[row]
        append(&entry.groups,Group_Record{group=group.group,entity=entity,body=physics.body_of(core.ref(c.state),entity)})
    }
    st.revision=max(u32)
}

// What a destructible does in a tick after the step: its body gives its Transform, and its groups follow what became of its pieces.
@(private)
follow :: proc(c:^Ctx,e:core.Entity) {
    cache:=c.cache
    w:=c.w
    f:=c.f
    st,has:=core.get(core.read(c.states),e)
    entry:=entry_find(cache,e)
    if !has || entry==nil || entry.pass==cache.pass || entry.prepared==nil || prepared_pending(entry.prepared) || entry.prepared.error!=.None || !fr.destructible_valid(f,st.handle) {return}
    written_position,written_rotation:=st.written_position,st.written_rotation
    local,has_local:=core.get(c.locals,e)
    if position,rotation,ok:=physics.proxy_pose(c.state,e);ok {written_position,written_rotation=position,rotation}
    if has_local && (local.position!=written_position || local.rotation!=written_rotation) {
        core.fail("Entity %v has a Destructible, which owns its Transform, but another function wrote its position or rotation: place a destructible in the scene; it cannot be moved while playing",e)
        written_position,written_rotation=local.position,local.rotation
    }
    if has_local && sim.body_valid(w,st.body) {
        if position,rotation,ok:=physics.local_of(c.locals,c.parents,e,sim.body_transform(w,st.body));ok {
            if local.position!=position || local.rotation!=rotation {if output:=core.get(c.transforms,e);output!=nil {output.position,output.rotation=position,rotation}}
            written_position,written_rotation=position,rotation
            physics.proxy_written(c.state,e,position,rotation)
        }
    }
    if written_position!=st.written_position || written_rotation!=st.written_rotation {
        if output:=core.get(c.states,e);output!=nil {output.written_position,output.written_rotation=written_position,written_rotation}
    }
    if revision:=fr.destructible_revision(f,st.handle);revision!=st.revision {mirror(c,e,core.get(c.states,e),entry,revision)}
    for &group in entry.groups {
        if !sim.body_valid(w,group.body) {continue}
        row,has_row:=core.get(core.read(c.groups),group.entity)
        moved,has_moved:=core.get(c.locals,group.entity)
        if !has_row || !has_moved {continue}
        written_position,written_rotation:=row.written_position,row.written_rotation
        if position,rotation,ok:=physics.proxy_pose(c.state,group.entity);ok {written_position,written_rotation=position,rotation}
        if moved.position!=written_position || moved.rotation!=written_rotation {
            core.fail("Entity %v is a body of a broken destructible, which owns its Transform: do not write it",group.entity)
        }
        if position,rotation,ok:=physics.local_of(c.locals,c.parents,group.entity,sim.body_transform(w,group.body));ok {
            if moved.position!=position || moved.rotation!=rotation {if output:=core.get(c.transforms,group.entity);output!=nil {output.position,output.rotation=position,rotation}}
            if row.written_position!=position || row.written_rotation!=rotation {if output:=core.get(c.groups,group.entity);output!=nil {output.written_position,output.written_rotation=position,rotation}}
            physics.proxy_written(c.state,group.entity,position,rotation)
        }
    }
}

// Makes the groups what the pieces of a destructible are now: one entity per body, with one mesh of the pieces on it.
@(private)
mirror :: proc(c:^Ctx,e:core.Entity,st:^Destructible_State,entry:^Entry,revision:u32) {
    cache:=c.cache
    w:=c.w
    f:=c.f
    count:=min(fr.destructible_pieces(f,w,st.handle,cache.infos),len(cache.infos))
    pieces:=cache.infos[:count]
    // Every half gets its geometry, in the world or not: a later cut starts from it.
    for piece in pieces {
        if piece.parent>=0 && !visual_cut(cache,entry,piece) {
            core.report(c.problems,e,"destruct.cut","a piece of its Destructible has no geometry: cutting the mesh of the piece it came from left nothing, or memory ran out; it collides, and is not drawn")
        }
    }
    cache.mark+=1
    clear(&cache.groups)
    detached:u32
    for piece in pieces {
        if piece.body=={} {
            detached+=u32(.Debris in piece.flags)
            continue
        }
        slot:=base.handle_index(base.Handle(piece.body))
        if cache.marks[slot]!=cache.mark {
            cache.marks[slot],cache.group_of[slot]=cache.mark,i32(len(cache.groups))
            append(&cache.groups,Scratch_Group{group=piece.group,body=piece.body})
        }
        group:=&cache.groups[cache.group_of[slot]]
        group.count+=1
        group.debris||=.Debris in piece.flags
        detached+=u32(piece.group!=0)
    }
    first:=0
    for &group in cache.groups {
        group.first=first
        first+=group.count
        group.count=0
    }
    for piece in pieces {
        if piece.body=={} {continue}
        group:=&cache.groups[cache.group_of[base.handle_index(base.Handle(piece.body))]]
        cache.flat[group.first+group.count]=piece.id
        group.count+=1
    }

    // The entities of bodies that are gone.
    #reverse for &record,at in entry.groups {
        wanted:=false
        for group in cache.groups {wanted||=group.group==record.group}
        if wanted && revision!=0 {continue}
        physics.proxy_remove(c.state,record.entity)
        if core.alive(c.es,record.entity) {core.destroy(c.es,record.entity)}
        if record.mesh!={} && c.assets!=nil && host.assets_mesh_release(c.assets,record.mesh) {cache.stats.meshes-=1}
        delete(record.members)
        ordered_remove(&entry.groups,at)
    }
    if revision!=0 {
        for group in cache.groups {group_sync(c,e,entry,group)}
        if !core.has(c.elsewhere,e) {core.add(c.elsewhere,e,render.Drawn_Elsewhere{})}
    } else if core.has(c.elsewhere,e) {
        core.remove(c.elsewhere,e)
    }
    if detached>st.detached && entry.event_tick==c.time.tick {
        core.push(&c.events.fractured,Fracture{entity=e,kind=entry.event.kind,point=entry.event.point,impulse=entry.event.vector,pieces=detached-st.detached})
    }
    st.revision,st.broken,st.detached=revision,revision!=0,detached
}

// The entity and the mesh of one body of a broken destructible.
@(private)
group_sync :: proc(c:^Ctx,owner:core.Entity,entry:^Entry,group:Scratch_Group) {
    cache:=c.cache
    w:=c.w
    members:=cache.flat[group.first:][:group.count]
    at:=-1
    for record,i in entry.groups {
        if record.group==group.group {at=i}
    }
    created:=at<0 || !core.alive(c.es,entry.groups[at].entity)
    if at<0 {
        append(&entry.groups,Group_Record{group=group.group})
        at=len(entry.groups)-1
    }
    record:=&entry.groups[at]
    changed:=created || len(record.members)!=len(members)
    if !changed {
        for member,i in record.members {changed||=member!=members[i]}
    }
    record.body=group.body
    if created {record.entity=core.create(c.es)}
    sim.body_set_user_data(w,group.body,u64(group.group==0?owner:record.entity))
    if changed {
        if record.mesh!={} && c.assets!=nil && host.assets_mesh_release(c.assets,record.mesh) {cache.stats.meshes-=1}
        made:bool
        record.mesh,made=group_mesh_make(c.assets,cache,entry,members)
        if !made && c.assets!=nil {
            core.report(c.problems,owner,"destruct.group_mesh","the mesh of a broken part of its Destructible was not made: its pieces have no geometry, or the generated meshes are full; that part collides and is not drawn: free memory, or use fewer pieces")
        }
        clear(&record.members)
        append(&record.members,..members)
        if record.mesh!={} {core.add(c.meshes,record.entity,render.Mesh_Renderer{mesh=record.mesh,materials=entry.materials})}
    }
    if !created {
        if moved:=core.get(c.transforms,record.entity);moved!=nil {physics.proxy_set(c.state,record.entity,group.body,moved.position,moved.rotation)}
        return
    }
    pose:=core.TRANSFORM_IDENTITY
    row:=Destructible_Group{owner=owner,group=group.group,debris=group.debris}
    if group.group==0 {
        // The pieces are at their size already: the entity undoes the scale of the one it hangs from.
        if above,ok:=core.world_of(c.locals,c.parents,owner);ok {
            for axis in 0..<3 {
                if above.scale[axis]!=0 {pose.scale[axis]=1/abs(above.scale[axis])}
            }
        }
        core.commands_add(c.commands,record.entity,core.Parent{entity=owner})
    } else {
        body:=sim.body_transform(w,group.body)
        pose.position,pose.rotation=body.p,body.q
    }
    row.written_position,row.written_rotation=pose.position,pose.rotation
    core.add(c.transforms,record.entity,pose)
    core.add(c.groups,record.entity,row)
    physics.proxy_set(c.state,record.entity,group.body,pose.position,pose.rotation)
    if group.group!=0 {group_identify(c,owner,record.entity,group)}
    if tint,has:=core.get(core.read(c.tints),owner);has {core.add(c.tints,record.entity,tint)}
}

// Destroys the entities of a group that no destructible of this world accounts for: what a world that went back in time left.
@(private)
groups_prune :: proc(c:^Ctx) {
    for row in 0..<core.count(c.groups) {
        group:=c.groups.values[row]
        e:=c.groups.entities[row]
        entry:=entry_find(c.cache,group.owner)
        known:=false
        if entry!=nil {
            for record in entry.groups {known||=record.entity==e}
        }
        if !known {physics.proxy_remove(c.state,e);core.destroy(c.es,e)}
    }
}

// What damaged the destructibles in this tick: the contacts of the step and what the game asked for.
@(private)
events_apply :: proc(c:^Ctx,waiting,requests:[]Destruct_Request,retry:^core.Queue(Destruct_Request)) {
    cache:=c.cache
    w:=c.w
    f:=c.f
    for event in fr.fracture_events(f) {
        for row in 0..<core.count(c.states) {
            if c.states.values[row].handle!=event.destructible {continue}
            e:=c.states.entities[row]
            if entry:=entry_find(cache,e);entry!=nil {event_applied(c,e,entry,event,true)}
            break
        }
    }
    for batch in ([2][]Destruct_Request{waiting,requests}) {for request in batch {
        target:=request.entity
        body:sim.Body_Handle
        cosmetic:=false
        if group,has:=core.get(core.read(c.groups),target);has {
            cosmetic=group.debris
            if c.authority==.Client && (request.kind!=.Remove || !cosmetic) {continue}
            body=physics.body_of(core.ref(c.state),target);target=group.owner
            if body==0 {
                if core.has(c.destructibles,target) {core.push(retry,request)}
                continue
            }
        } else if c.authority==.Client || request.kind==.Remove {continue}
        st,has:=core.get(core.read(c.states),target)
        entry:=entry_find(cache,target)
        if !has || entry==nil || !fr.destructible_valid(f,st.handle) {
            if core.has(c.destructibles,target) && (!has || st.waiting || !st.failed) {core.push(retry,request)}
            continue
        }
        // One event per body of the destructible, so each can travel in the frame of its body.
        count:=min(fr.destructible_pieces(f,w,st.handle,cache.infos),len(cache.infos))
        cache.mark+=1
        bodies:=0
        for piece in cache.infos[:count] {
            if piece.body=={} || .Debris in piece.flags && request.kind!=.Remove {continue}
            if piece.body==request.ignore_body {continue}
            if body!={} && piece.body!=body {continue}
            slot:=base.handle_index(base.Handle(piece.body))
            if cache.marks[slot]==cache.mark {continue}
            cache.marks[slot]=cache.mark
            cache.firsts[bodies]=piece.id
            bodies+=1
        }
        for piece in cache.firsts[:bodies] {
            event:fr.Fracture_Event
            if request.kind==.Remove {
                removed:bool
                if event,removed=fr.destructible_remove_body(f,w,st.handle,piece);!removed {continue}
            } else if request.kind==.Slice {
                cut:bool
                if event,cut=fr.destructible_slice_body(f,w,st.handle,piece,request.region.point,request.vector);!cut {continue}
            } else {
                strained:bool
                if event,_,strained=fr.destructible_field_body(f,w,st.handle,piece,request.region,request.strain,request.vector,request.kind==.Weaken);!strained {continue}
            }
            if !cosmetic {event_applied(c,target,entry,event,true)}
        }
    }}
}

// Keeps the strongest event of the tick: what Fracture tells. One this end
// caused (noted) is recorded in Applied.
@(private)
event_applied :: proc(c:^Ctx,e:core.Entity,entry:^Entry,event:fr.Fracture_Event,noted:bool) {
    if noted {event_note(c,e,event)}
    if entry.event_tick!=c.time.tick || linalg.length2(event.vector)>linalg.length2(entry.event.vector) || event.kind==.Slice {
        entry.event,entry.event_tick=event,c.time.tick
    }
    c.cache.stats.events+=1
}

