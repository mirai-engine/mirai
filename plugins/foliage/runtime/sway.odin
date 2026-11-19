package foliage

import "core:hash"
import "core:math/linalg"
import "core:mem"
import "mirai:core"
import render "mirai:engine/render"
import "mirai:host"
import mm "mirai:std/math"

// A mesh entity placed by hand that sways in the wind as foliage does: its
// Mesh_Renderer is drawn as a batch of one instance at its place, with the
// hook, the wind, the swaying shadow and the rays at rest of a foliage type of
// the same wind, while the entity is Drawn_Elsewhere. The entity stays what
// it was: its transform, collider and picking are its own, and an outline it
// is given is drawn around its mesh at rest.
@(component,description="Sways the mesh of this entity in the wind as foliage sways: what stands over its origin bends toward the wind by the red of its vertex colors. The entity keeps its transform, collider and selection.")
Foliage_Sway :: struct {
    wind:f32 `mirai:"min=0"`, // how much the wind moves it, as the wind of a foliage type
}

FOLIAGE_SWAY_DEFAULT :: Foliage_Sway{wind=1}

// What a swaying entity was drawn with: it is drawn again when any of it changes.
Sway_Key :: struct {
    transform:mm.Transform,
    renderer:render.Mesh_Renderer,
    mesh:render.Mesh_Handle, // of the renderer, which a reload of its asset changes
    sway:Foliage_Sway,
    values:u64, // hash of its Material_Values; 0 without them
    layers:u32,
    zone:i32,
    hidden:bool,
}

// The batch of a swaying entity; handle 0 while it is not drawn (hidden, or
// its mesh not loaded). drawn: it is Drawn_Elsewhere.
Resident_Sway :: struct {
    handle:render.Batch_Handle,
    key:Sway_Key,
    drawn:bool,
}

Sway_Seen :: struct {sways,meshes,values,worlds,hidden,parents,layers:core.Seen}

// The mesh entities that sway are drawn by their batches of one, made again
// where what they show, their place or their wind changes; their outline,
// while they have one, is that of their mesh at rest.
@(step="late",loops="game editor",stage="end",after="foliage_render")
foliage_sway_render :: proc(
    resident:^Foliage_Resident,sways:^core.Table(Foliage_Sway,.Read),meshes:^core.Table(render.Mesh_Renderer,.Read),values:^core.Table(render.Material_Values,.Read),
    worlds:^core.Table(core.World_Transform,.Read),hidden:^core.Table(render.Hidden,.Read),parents:^core.Table(core.Parent,.Read),layers:^core.Table(render.Layers,.Read),
    elsewhere:^core.Table(render.Drawn_Elsewhere,.Read),highlights:^core.Table(render.Highlight,.Read),outlines:^core.Table(render.Outline,.Read),
    commands:core.Commands,id:core.World_Id,app:^host.App,problems:^core.Problems,
) {
    if resident==nil || app.renderer==nil || app.assets==nil {return}
    if core.count(sways)==0 && len(resident.sways.entities)==0 {return}
    context.allocator=app.allocator
    resident.app,resident.world=app,id
    a:=app.assets
    s:=&resident.sway_seen
    cw:=core.changes(worlds,&s.worlds)
    full:=cw.all || resident.sway_epoch!=render.batches_epoch(app.renderer) || resident.sway_structure!=a.structure || resident.sway_zones!=resident.zones_revision
    full|=core.touched(sways,&s.sways) | core.touched(meshes,&s.meshes) | core.touched(values,&s.values)
    full|=core.touched(hidden,&s.hidden) | core.touched(parents,&s.parents) | core.touched(layers,&s.layers)
    if resident.sway_epoch!=render.batches_epoch(app.renderer) {
        // The renderer forgot every batch: each is made anew.
        for &held in resident.sways.values {held.handle,held.key=0,{}}
        resident.sway_epoch=render.batches_epoch(app.renderer)
    }
    resident.sway_structure,resident.sway_zones=a.structure,resident.zones_revision
    t:=Sway_Tables{sways,meshes,values,worlds,hidden,parents,layers,elsewhere}
    if full {
        for i:=len(resident.sways.entities)-1;i>=0;i-=1 {
            if e:=resident.sways.entities[i];!core.has(sways,e) {sway_drop(resident,t,commands,e)}
        }
        for row in 0..<core.count(sways) {sway_update(resident,t,commands,core.entity_at(sways,row),id,problems)}
    } else if cw.written || len(cw.gone)>0 {
        for row in core.each_changed(worlds,&cw) {
            if e:=core.entity_at(worlds,row);core.has(sways,e) {sway_update(resident,t,commands,e,id,problems)}
        }
        for e in cw.gone {if core.entity_map_get(&resident.sways,e)!=nil {sway_update(resident,t,commands,e,id,problems)}}
    }
    sway_outlines(resident,t,highlights,outlines,app)
}

@(private)
Sway_Tables :: struct {
    sways:^core.Table(Foliage_Sway,.Read),
    meshes:^core.Table(render.Mesh_Renderer,.Read),
    values:^core.Table(render.Material_Values,.Read),
    worlds:^core.Table(core.World_Transform,.Read),
    hidden:^core.Table(render.Hidden,.Read),
    parents:^core.Table(core.Parent,.Read),
    layers:^core.Table(render.Layers,.Read),
    elsewhere:^core.Table(render.Drawn_Elsewhere,.Read),
}

// The batch of a swaying entity as its rows are now: made, set again or
// removed. A world copied with its entities (Play) keeps their
// Drawn_Elsewhere, which this one takes as its own.
@(private)
sway_update :: proc(resident:^Foliage_Resident,t:Sway_Tables,commands:core.Commands,e:core.Entity,id:core.World_Id,problems:^core.Problems) {
    sway,swaying:=core.get(t.sways,e)
    static,has_mesh:=core.get(t.meshes,e)
    world,placed:=core.get(t.worlds,e)
    if !swaying || !has_mesh || !placed {
        sway_drop(resident,t,commands,e)
        return
    }
    held:=core.entity_map_get(&resident.sways,e)
    if held==nil {
        put,kept:=core.entity_map_put(&resident.sways,e,Resident_Sway{})
        if !kept {
            memory_problem(problems,e,"this Foliage_Sway, which does not sway")
            return
        }
        held=put
    }
    key:=Sway_Key{transform=world.transform,renderer=static,sway=sway,hidden=render.is_hidden(t.hidden,t.parents,e)}
    shown:=render.MATERIAL_VALUES_DEFAULT
    if own,has_values:=core.get(t.values,e);has_values {
        shown=own
        key.values=hash.fnv64a(mem.ptr_to_bytes(&shown))|1
    }
    key.layers=1
    if in_layers,has_layers:=core.get(t.layers,e);has_layers {key.layers=in_layers.mask}
    key.zone=wind_zone_at(resident,world.transform.position)
    key.mesh,_=render.mesh_handle(resident.app.assets,static)
    if !held.drawn {
        if !core.has(t.elsewhere,e) {core.commands_add(commands,e,render.Drawn_Elsewhere{})}
        held.drawn=true
    }
    if held.handle!=0 && held.key==key {return}
    app:=resident.app
    desc,known:=render.batch_desc(app.assets,static,shown)
    if key.hidden || !known {
        if held.handle!=0 {render.batch_remove(app.renderer,held.handle)}
        held.handle=0
        // A mesh still loading is drawn once the assets change.
        held.key=key if key.hidden else {}
        return
    }
    kind:=FOLIAGE_TYPE_DEFAULT
    kind.wind,kind.casts_shadow=sway.wind,static.shadows
    amount:=sway_amount(kind)
    desc.flags={.Ray_Visible}
    if static.shadows {desc.flags+={.Casts_Shadow}}
    desc.layers=key.layers
    desc.object_id=u64(e)
    desc.vertex={amount,1,0,0}
    if low,high,bounded:=render.mesh_bounds(app.renderer,desc.mesh);bounded {
        // How high its farthest point stands over its origin in the world,
        // and how far it lies from it: the hook bends what stands over it.
        top,size:=f32(0),f32(0)
        for corner in 0..<8 {
            p:=[3]f32{corner&1!=0?high.x:low.x,corner&2!=0?high.y:low.y,corner&4!=0?high.z:low.z}
            q:=mm.quat_rotate(world.transform.rotation,p*world.transform.scale)
            top,size=max(top,q.y),max(size,linalg.length(q))
        }
        scale:=max(abs(world.transform.scale.x),abs(world.transform.scale.y),abs(world.transform.scale.z),1e-6)
        desc.reach=hook_reach(amount,top)
        desc.sway=shadow_sway(kind,top/scale,size)
        if desc.sway>0 {desc.wind=wind_zone_take(resident,key.zone,world.transform.position)}
    }
    instance:=[1]render.Batch_Instance{render.batch_instance(world.transform.position,world.transform.rotation,world.transform.scale)}
    next,error:=render.batch_set(app.renderer,id,held.handle,desc,instance[:])
    if error!="" {
        if held.handle!=0 {render.batch_remove(app.renderer,held.handle)}
        held.handle,held.key=0,{}
        core.report(problems,e,"foliage.sway","the mesh of this Foliage_Sway is not drawn: %s",error)
        return
    }
    held.handle,held.key=next,key
}

// An entity that no longer sways: its batch goes, and its own mesh draws it again.
@(private)
sway_drop :: proc(resident:^Foliage_Resident,t:Sway_Tables,commands:core.Commands,e:core.Entity) {
    held:=core.entity_map_get(&resident.sways,e)
    if held==nil {return}
    if held.handle!=0 && resident.app!=nil {render.batch_remove(resident.app.renderer,held.handle)}
    if held.drawn && core.has(t.elsewhere,e) {core.commands_remove(commands,e,render.Drawn_Elsewhere)}
    core.entity_map_remove(&resident.sways,e)
}

// The outline of each swaying entity that has one, around its mesh at rest,
// for this frame.
@(private)
sway_outlines :: proc(resident:^Foliage_Resident,t:Sway_Tables,highlights:^core.Table(render.Highlight,.Read),outlines:^core.Table(render.Outline,.Read),app:^host.App) {
    outline :: proc(resident:^Foliage_Resident,t:Sway_Tables,e:core.Entity,level:u8,app:^host.App) {
        held:=core.entity_map_get(&resident.sways,e)
        if held==nil || held.handle==0 || level==0 {return}
        static,_:=core.get(t.meshes,e)
        world,_:=core.get(t.worlds,e)
        instance,ok:=render.mesh_instance(app.assets,static,mm.transform_matrix(world.transform))
        if !ok {return}
        instance.object_id,instance.copy_owner=u64(e),SWAY_OUTLINE_OWNER
        instance.highlight,instance.outline_only,instance.layers=level,true,held.key.layers
        render.instance_add(&app.extras,instance)
    }
    for row in 0..<core.count(highlights) {outline(resident,t,core.entity_at(highlights,row),render.instance_outline(highlights,outlines,core.entity_at(highlights,row)),app)}
    for row in 0..<core.count(outlines) {
        if e:=core.entity_at(outlines,row);!core.has(highlights,e) {outline(resident,t,e,render.instance_outline(highlights,outlines,e),app)}
    }
}

SWAY_OUTLINE_OWNER :: u64(0x5357415900000001) // the copy an outline of a swaying entity is drawn as

// Whether a swaying entity sways in a zone of wind.
@(private)
sway_zone_used :: proc(resident:^Foliage_Resident,zone:i32) -> bool {
    for held in resident.sways.values {if held.handle!=0 && held.key.zone==zone {return true}}
    return false
}

sways_free :: proc(resident:^Foliage_Resident) {
    if resident.app!=nil {for held in resident.sways.values {if held.handle!=0 {render.batch_remove(resident.app.renderer,held.handle)}}}
    core.entity_map_destroy(&resident.sways)
}
