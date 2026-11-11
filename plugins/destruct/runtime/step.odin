package destruct

import "core:math/linalg"
import "core:strings"
import "mirai:core"
import render "mirai:engine/render"
import physics "plugins:physics/runtime"
import "mirai:host"
import "mirai:std/jobs"
import "mirai:std/base"
import mm "mirai:std/math"

// A destructible is a breakable body of the simulation of physics, so its
// pieces collide with everything else and break in the step that hits them,
// and its bodies name the entity of the destructible. This library makes the
// breakable again when what it is made from changes, applies the damage the
// game asks for, and keeps what draws it equal to what the simulation says
// became of its pieces: the revision of the breakable says when to look again,
// so a world that went back in time is drawn like any other. Physics writes
// the Transform of the destructible and of its groups, proxies of its bodies.
// The server of a network session is the one that damages.

@(private)
Ctx :: struct {
    state:^physics.Physics_State,
    view:core.Ref(physics.Physics_State),
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
    rigids:core.Read(physics.Rigid_Body),
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
// simulation that just ran damaged them already.
@(step="fixed",stage="react")
destruct_step :: proc(
    state:^physics.Physics_State,cache:^Destruct_Cache,requests:^Destruct_Requests,events:^Destruct_Events,
    authority:core.Ref(core.Network),assets:^host.Assets,job_system:^jobs.Job_System,time:core.Time,commands:core.Commands,
    destructibles:core.Read(Destructible),meshes:^core.Table(render.Mesh_Renderer),tints:^core.Table(render.Tint),parents:core.Read(core.Parent),
    states:^core.Table(Destructible_State),groups:^core.Table(Destructible_Group),
    elsewhere:^core.Table(render.Drawn_Elsewhere),transforms:^core.Table(core.Transform),ids:^core.Table(core.Id),
    colliders:core.Read(physics.Collider),rigids:core.Read(physics.Rigid_Body),collision:core.Ref(physics.Collision_Settings),problems:^core.Problems,
) {
    if cache==nil || !state.ready || !time.playing || time.dt<=0 {return}
    room:=physics.breakable_room(core.ref(state))
    if !cache_make(cache,room) {
        core.report(problems,core.NONE,"destruct.memory","out of memory for the %d pieces and the %d bodies of Physics_Settings; no Destructible is made or mirrored until there is: lower them, or free memory",room.pieces,room.bodies)
        return
    }
    pending:=core.take(&requests.queue)
    waiting:=core.take(&requests.waiting)
    replays:=core.take(&requests.replays)
    states_asked:=core.take(&requests.states)
    // A simulation that replaced the one the cache was made for holds the destructibles as they were there.
    replaced:=physics.simulation_replaced(state,&cache.epoch)
    if replaced {cache_reset(assets,job_system,cache)}
    cache.pass+=1
    c:=Ctx{
        state=state,view=core.ref(state),cache=cache,events=events,assets=assets,job_system=job_system,time=time,es=commands.entities,commands=commands,
        authority=authority.role,
        destructibles=destructibles,colliders=colliders,rigids=rigids,collision=collision.ptr,meshes=meshes,tints=tints,parents=parents,locals=core.read(transforms),
        states=states,groups=groups,elsewhere=elsewhere,transforms=transforms,ids=ids,problems=problems,
    }
    if left:=core.changes(groups,&cache.seen[.Groups]);!left.all && len(left.gone)>0 {
        for e in left.gone {physics.proxy_remove(state,e)}
        meshes_sweep(&c)
    }
    gone,at:=core.changes(destructibles,&cache.seen[.Destructible]),0
    entry:Entry
    for e in core.entity_map_left(&cache.entries,destructibles,gone,&at,&entry) {
        entity_end(&c,e)
        entry_release(job_system,&entry)
    }
    // A change of what it is made of makes it again; one of its Collider or Mesh_Renderer, when it changed what its pieces are.
    for row in core.each_changed(destructibles,&gone) {reconcile(&c,core.entity_at(destructibles,row),!replaced)}
    rigid:=core.changes(rigids,&cache.seen[.Rigid_Body])
    for row in core.each_changed(rigids,&rigid) {reconcile(&c,core.entity_at(rigids,row),!replaced)}
    collider:=core.changes(colliders,&cache.seen[.Collider])
    for row in core.each_changed(colliders,&collider) {reconcile(&c,core.entity_at(colliders,row),false)}
    mesh:=core.changes(meshes,&cache.seen[.Mesh_Renderer])
    for row in core.each_changed(meshes,&mesh) {reconcile(&c,core.entity_at(meshes,row),false)}
    if cache.role!=c.authority {
        cache.role=c.authority
        for row in 0..<core.count(states) {
            if states.values[row].passive!=(c.authority==.Client) {reconcile(&c,states.entities[row],true)}
        }
    }
    // Those whose pieces are being cut, and those a replayed state ended.
    for row in 0..<core.count(states) {
        st:=states.values[row]
        if st.waiting || !st.failed && !physics.breakable_valid(c.view,st.handle) {reconcile(&c,states.entities[row],false)}
    }
    events_apply(&c,waiting,pending,&requests.waiting)
    replays_apply(&c,states_asked,replays)
    for row in 0..<core.count(states) {
        e:=states.entities[row]
        st:=states.values[row]
        shortfall_report(&c,e,st.handle)
        entry:=entry_find(cache,e)
        if entry==nil || entry.prepared==nil || prepared_pending(entry.prepared) || entry.prepared.error!=.None || !physics.breakable_valid(c.view,st.handle) {continue}
        if revision:=physics.breakable_revision(c.view,st.handle);revision!=st.revision || !entry.mirrored {mirror(&c,e,core.edit_at(states,row),entry,revision)}
    }
}

// Ends what exists for a destructible: its simulation destructible, its entities and the marks on its own.
@(private)
entity_end :: proc(c:^Ctx,e:core.Entity) {
    physics.proxy_remove(c.state,e)
    if handle:=physics.breakable_of(c.view,e);handle!=0 {physics.breakable_destroy(c.state,handle)}
    if core.has(c.states,e) {core.remove(c.states,e)}
    groups_end(c,e)
    if core.has(c.elsewhere,e) {core.remove(c.elsewhere,e)}
}

// Ends the entities of the groups of a destructible and their meshes.
@(private)
groups_end :: proc(c:^Ctx,owner:core.Entity) {
    for row in 0..<core.count(c.groups) {
        if group:=c.groups.values[row];group.owner==owner && core.alive(c.es,c.groups.entities[row]) {group_drop(c,c.groups.entities[row],group.mesh)}
    }
}

@(private)
group_drop :: proc(c:^Ctx,e:core.Entity,mesh:base.Asset_Id) {
    physics.proxy_remove(c.state,e)
    core.destroy(c.es,e)
    mesh_release(c.assets,c.cache,mesh)
}

// The meshes of groups whose entity went without this library ending it.
@(private)
meshes_sweep :: proc(c:^Ctx) {
    #reverse for mesh in c.cache.meshes {
        used:=false
        for group in c.groups.values[:core.count(c.groups)] {used||=group.mesh==mesh}
        if !used {mesh_release(c.assets,c.cache,mesh)}
    }
}

// The simulation destructible of one entity made match what it is made of:
// made, made again when that changed (always with remake), its pieces given
// another collision, or left as it is.
@(private)
reconcile :: proc(c:^Ctx,e:core.Entity,remake:bool) {
    cache:=c.cache
    d,configured:=core.get(c.destructibles,e)
    if !configured {return}
    entry:=entry_take(cache,e)
    if entry==nil {
        core.report(c.problems,e,"destruct.memory","out of memory for the Destructible of this entity; it waits for the next tick: free memory")
        return
    }
    if entry.pass==cache.pass {return}
    entry.pass=cache.pass
    held,has:=core.get(c.states,e)
    st:=held
    static,has_mesh:=core.get(c.meshes,e)
    world,placed:=core.world_of(c.locals,c.parents,e)
    scale:=linalg.abs(world.scale)
    collider,has_collider:=core.get(c.colliders,e)
    if !has_collider {collider=physics.COLLIDER_DEFAULT}
    rigid,has_rigid:=core.get(c.rigids,e)
    if !has_rigid {rigid=physics.RIGID_BODY_DYNAMIC}
    filter:=physics.collision_filter(c.collision,collider)
    _,interior,generated:=slots_of(c.assets,d,static.mesh)
    key:=Prepared_Key{pieces=d.pieces,seed=d.seed,pattern=d.pattern,mesh=static.mesh,fracture=d.fracture,shape=static.shape,scale=scale,interior=interior}
    same:=!remake && (entry.prepared==nil || entry.prepared.key==key)
    if density,friction,restitution,made_filter,valid:=physics.breakable_surface(c.view,st.handle);valid {
        if same && density==collider.density && friction==collider.friction && restitution==collider.restitution {
            if made_filter!=filter {physics.breakable_set_filter(c.state,st.handle,filter)}
            if entry.prepared==nil || st.waiting {cache_recover(c,e,d,static,scale,entry)}
            return
        }
    }
    if !(st.waiting && same) {
        if physics.breakable_valid(c.view,st.handle) {physics.breakable_destroy(c.state,st.handle)}
        groups_end(c,e)
        visuals_release(entry)
        entry.mirrored=false
        if core.has(c.elsewhere,e) {core.remove(c.elsewhere,e)}
        st=Destructible_State{}
    }
    st.passive=c.authority==.Client
    st.failed,st.waiting=true,false
    defer if st!=held || !has {core.add(c.states,e,st)}
    if !has_mesh || !placed || scale.x==0 || scale.y==0 || scale.z==0 {
        why:=!has_mesh?"it has no Mesh_Renderer":!placed?"it has no Transform":"its scale has a zero axis"
        core.report(c.problems,e,"destruct.mesh","its Destructible has nothing to fracture: %s; give it a Mesh_Renderer with a closed mesh and a scale without zero axes",why)
        return
    }
    if d.fracture=={} && (d.pieces==0 || u64(d.pieces)>u64(len(cache.infos))) {
        core.report(c.problems,e,"destruct.pieces","its Destructible asks for %d pieces, and the simulation holds %d (Physics_Settings.pieces); ask for 1 to %d, or raise pieces",d.pieces,len(cache.infos),len(cache.infos))
        return
    }
    // One store per value until odin-lang/Odin#7937 (see ODIN_WORKAROUNDS).
    entry.slots=interior+1
    entry.generated=generated
    entry.materials=static.materials
    if interior<render.MATERIAL_SLOTS && d.interior=={} {entry.materials[interior]=static.materials[0]}
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
    lo,hi:=p.desc.lo,p.desc.hi
    desc:=physics.BREAKABLE_DESC_DEFAULT
    desc.fracture=&p.fracture
    desc.position,desc.rotation=world.position,world.rotation
    desc.density,desc.friction,desc.restitution,desc.strength=collider.density,collider.friction,collider.restitution,d.strength
    desc.gravity_scale,desc.kinematic=rigid.gravity_scale,rigid.type!=.Dynamic
    desc.filter=filter
    desc.hull_vertices=int(d.hull_vertices)
    desc.piece_anchors,desc.piece_clusters,desc.clusters,desc.bond_strength=p.anchors[:],p.piece_clusters[:],p.clusters[:],p.connection_strength[:]
    desc.cluster_points=p.cluster_points[:]
    desc.damage_threshold,desc.damage_radius,desc.propagation,desc.debris_volume=d.damage_threshold,d.damage_radius,d.propagation,d.debris_volume
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
    base_box:=[1]mm.Aabb{{lo-margin,{hi.x+margin.x,lo.y+margin.y,hi.z+margin.z}}}
    if d.anchored {desc.anchors=base_box[:]}
    handle,error:=physics.breakable_create(c.state,desc)
    if error!=.None {
        destructible_problem(c,e,error)
        return
    }
    st.failed,st.handle=false,handle
    if core.has(c.transforms,e) {physics.proxy_set(c.state,e,physics.breakable_body(c.view,handle))}
    count:=min(physics.breakable_pieces(c.view,handle,cache.infos),len(cache.infos))
    visuals_source(c.problems,e,entry,cache.infos[:count])
}

@(private)
destructible_problem :: proc(c:^Ctx,e:core.Entity,error:physics.Breakable_Error) {
    why,fix:string
    switch error {
    case .None:
    case .Invalid_Desc: why,fix="a value of the Destructible or of its Collider is not valid","give it a positive strength, damage radius and density, a propagation from 0 to 1, and finite values"
    case .Invalid_Mesh: why,fix="the pieces of its mesh are not valid","use a closed mesh, or another .fracture asset"
    case .No_Pieces:    why,fix="its mesh gave no pieces","give it a closed mesh with volume"
    case .Capacity:     why,fix="the simulation has no room for it","raise the breakables, pieces, bonds, hulls, shapes or bodies of Physics_Settings"
    case .Out_Of_Memory: why,fix="there is no memory to cut its mesh","free memory or lower Destructible.pieces"
    }
    core.report(c.problems,e,"destruct.create","the simulation refused its Destructible: %s; %s",why,fix)
}

@(private,rodata)
CAPACITY_SETTINGS:=[physics.Break_Capacity]string{.Pieces="Physics_Settings.pieces",.Hulls="Physics_Settings.hulls",.Bonds="Physics_Settings.bonds",.Shapes="Physics_Settings.shapes",.Bodies="Physics_Settings.bodies"}

// What the simulation could not give a destructible in this tick, as its problems.
@(private)
shortfall_report :: proc(c:^Ctx,e:core.Entity,handle:physics.Breakable_Handle) {
    events,refused:=physics.breakable_shortfall(c.view,handle)
    if events>0 {
        core.report(c.problems,e,"destruct.events","%d fracture events of its Destructible did not fit in one tick, which lists %d of them (Physics_Settings.events): they were applied, and not told to the game or sent to the clients; raise events",events,physics.breakable_room(c.view).events)
    }
    if refused=={} {return}
    names:[160]u8
    b:=strings.builder_from_bytes(names[:])
    for capacity in refused {
        if strings.builder_len(b)>0 {strings.write_string(&b,", ")}
        strings.write_string(&b,CAPACITY_SETTINGS[capacity])
    }
    core.report(c.problems,e,"destruct.capacity","the simulation had no room for a fracture or a cut of its Destructible, which left those pieces as they were: raise %s; a destructible keeps every piece it cut, removed or let expire until it is destroyed, and a cut takes two pieces and two hulls",strings.to_string(b))
}

// The geometry of the pieces of a destructible the simulation kept while this cache did not: a world
// that went back in time, or a copy. Its groups draw again once it is cut.
@(private)
cache_recover :: proc(c:^Ctx,e:core.Entity,d:Destructible,static:render.Mesh_Renderer,scale:[3]f32,entry:^Entry) {
    st:=core.edit(c.states,e)
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
    count:=min(physics.breakable_pieces(c.view,st.handle,c.cache.infos),len(c.cache.infos))
    visuals_source(c.problems,e,entry,c.cache.infos[:count])
}

// Makes the groups what the pieces of a destructible are now: one entity per body, with one mesh of the pieces on it.
@(private)
mirror :: proc(c:^Ctx,e:core.Entity,st:^Destructible_State,entry:^Entry,revision:u32) {
    cache:=c.cache
    count:=min(physics.breakable_pieces(c.view,st.handle,cache.infos),len(cache.infos))
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

    // The entities of bodies that are gone end; those of the others are kept.
    for row in 0..<core.count(c.groups) {
        group:=c.groups.values[row]
        if group.owner!=e || !core.alive(c.es,c.groups.entities[row]) {continue}
        kept:=false
        if revision!=0 {
            for &wanted in cache.groups {
                if wanted.group!=group.group {continue}
                wanted.entity,kept=c.groups.entities[row],true
                break
            }
        }
        if !kept {group_drop(c,c.groups.entities[row],group.mesh)}
    }
    if revision!=0 {
        for &group in cache.groups {group_sync(c,e,entry,&group)}
        if !core.has(c.elsewhere,e) {core.add(c.elsewhere,e,render.Drawn_Elsewhere{})}
    } else if core.has(c.elsewhere,e) {
        core.remove(c.elsewhere,e)
    }
    if detached>st.detached && entry.event_tick==c.time.tick {
        core.push(&c.events.fractured,Fracture{entity=e,kind=entry.event.kind,point=entry.event.point,impulse=entry.event.vector,pieces=detached-st.detached})
    }
    st.revision,st.broken,st.detached=revision,revision!=0,detached
    entry.mirrored=true
}

// The entity and the mesh of one body of a broken destructible.
@(private)
group_sync :: proc(c:^Ctx,owner:core.Entity,entry:^Entry,group:^Scratch_Group) {
    cache:=c.cache
    members:=cache.flat[group.first:][:group.count]
    hash:=u64(len(members))
    for member in members {hash=base.hash_combine(hash,u64(member))}
    created:=group.entity==core.NONE || !core.alive(c.es,group.entity)
    row:Destructible_Group
    if created {
        group.entity=core.create(c.es)
        row={owner=owner,group=group.group,debris=group.debris}
    } else {
        row,_=core.get(c.groups,group.entity)
    }
    physics.breakable_body_name(c.state,group.body,group.group==0?owner:group.entity)
    if created || !entry.mirrored || row.members!=hash {
        mesh_release(c.assets,cache,row.mesh)
        made:bool
        row.mesh,made=group_mesh_make(c.assets,cache,entry,members)
        if !made && c.assets!=nil {
            core.report(c.problems,owner,"destruct.group_mesh","the mesh of a broken part of its Destructible was not made: its pieces have no geometry, or the generated meshes are full; that part collides and is not drawn: free memory, or use fewer pieces")
        }
        row.members=hash
        if row.mesh!={} {
            core.add(c.meshes,group.entity,render.Mesh_Renderer{mesh=row.mesh,materials=entry.materials})
        } else if core.has(c.meshes,group.entity) {
            core.remove(c.meshes,group.entity)
        }
        if !created {core.add(c.groups,group.entity,row)}
    }
    if !created {
        if core.has(c.transforms,group.entity) {physics.proxy_set(c.state,group.entity,group.body)}
        return
    }
    pose:=core.TRANSFORM_IDENTITY
    if group.group==0 {
        // The pieces are at their size already: the entity undoes the scale of the one it hangs from.
        if above,ok:=core.world_of(c.locals,c.parents,owner);ok {
            for axis in 0..<3 {
                if above.scale[axis]!=0 {pose.scale[axis]=1/abs(above.scale[axis])}
            }
        }
        core.commands_add(c.commands,group.entity,core.Parent{entity=owner})
    } else {
        body,_:=physics.body_pose(c.view,group.body)
        pose.position,pose.rotation=body.p,body.q
    }
    core.add(c.transforms,group.entity,pose)
    core.add(c.groups,group.entity,row)
    physics.proxy_set(c.state,group.entity,group.body)
    if group.group!=0 {group_identify(c,owner,group.entity,group^)}
    if tint,has:=core.get(c.tints,owner);has {core.add(c.tints,group.entity,tint)}
}

// What damaged the destructibles in this tick: the contacts of the step and what the game asked for.
@(private)
events_apply :: proc(c:^Ctx,waiting,requests:[]Destruct_Request,retry:^core.Queue(Destruct_Request)) {
    cache:=c.cache
    for event in physics.breakable_events(c.view) {
        for row in 0..<core.count(c.states) {
            if c.states.values[row].handle!=event.breakable {continue}
            e:=c.states.entities[row]
            if entry:=entry_find(cache,e);entry!=nil {event_applied(c,e,entry,event,true)}
            break
        }
    }
    for batch in ([2][]Destruct_Request{waiting,requests}) {for request in batch {
        target:=request.entity
        body:physics.Body_Handle
        cosmetic:=false
        if group,has:=core.get(c.groups,target);has {
            cosmetic=group.debris
            if c.authority==.Client && (request.kind!=.Remove || !cosmetic) {continue}
            body=physics.body_of(core.ref(c.state),target);target=group.owner
            if body==0 {
                if core.has(c.destructibles,target) {core.push(retry,request)}
                continue
            }
        } else if c.authority==.Client || request.kind==.Remove {continue}
        st,has:=core.get(c.states,target)
        entry:=entry_find(cache,target)
        if !has || entry==nil || !physics.breakable_valid(c.view,st.handle) {
            if core.has(c.destructibles,target) && (!has || st.waiting || !st.failed) {core.push(retry,request)}
            continue
        }
        // One event per body of the destructible, so each can travel in the frame of its body.
        count:=min(physics.breakable_pieces(c.view,st.handle,cache.infos),len(cache.infos))
        cache.mark+=1
        bodies:=0
        for piece in cache.infos[:count] {
            if piece.body=={} || .Debris in piece.flags && request.kind!=.Remove {continue}
            if body!={} && piece.body!=body {continue}
            slot:=base.handle_index(base.Handle(piece.body))
            if cache.marks[slot]==cache.mark {continue}
            cache.marks[slot]=cache.mark
            cache.firsts[bodies]=piece.id
            bodies+=1
        }
        asked:=request.event
        asked.breakable=st.handle
        for piece in cache.firsts[:bodies] {
            asked.piece=piece
            event,changed,strained:=physics.break_apply(c.state,asked)
            if (changed || strained) && !cosmetic {event_applied(c,target,entry,event,true)}
        }
    }}
}

// Keeps the strongest event of the tick: what Fracture tells. One this end
// caused (noted) is recorded in Applied.
@(private)
event_applied :: proc(c:^Ctx,e:core.Entity,entry:^Entry,event:physics.Break_Event,noted:bool) {
    if noted {event_note(c,e,event)}
    if entry.event_tick!=c.time.tick || linalg.length2(event.vector)>linalg.length2(entry.event.vector) || event.kind==.Slice {
        entry.event,entry.event_tick=event,c.time.tick
    }
}
