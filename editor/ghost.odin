package editor

import "mirai:asset"
import "mirai:core"
import erender "mirai:engine/render"
import scene "mirai:engine/scene"
import "mirai:host"
import gpu "mirai:render"
import mm "mirai:std/math"
import "mirai:ui"

GHOST_COLOR :: [4]f32{1,0.71,0.28,0.95}
GHOST_MARKER :: f32(0.35)

// What is hidden or turned off shows as a flat coat of this level, which
// lights nothing and casts no shadow; selected, as the outline of its level.
GHOST_LEVEL :: AI_CONTEXT_LEVEL+1
GHOST_FILL :: [4]f32{0.62,0.72,0.9,1} // display color
GHOST_OPACITY :: f32(0.6)
GHOST_OWNER :: u64(0x67686f7374)

// Hidden and turned off entities show and are picked as ghosts while the scene is edited.
ghosts_shown :: proc "contextless" (s:^Session) -> bool {return s.mode==.Edit || s.mode==.Simulate || s.mode==.Simulation_Paused}

Placement_Part :: struct {
    mesh:erender.Mesh_Renderer,
    tint:erender.Material_Values, // what its entity shows of its materials
    transform:mm.Transform,
}

Placement_Preview :: struct {
    key:[5]u64,
    parts:[dynamic]Placement_Part,
    low,high:[3]f32,
    measured:bool,
}

@(private)
placement_subject :: proc(d:Drag) -> bool {
    return d.kind==.Preset || d.kind==.Asset && (d.asset_kind==asset.KIND_MESH || d.asset_kind==asset.KIND_PREFAB || d.asset_kind==asset.KIND_SCENE || placement_sound(d))
}

// A .sound or a .sound_set placed in the scene makes an entity of the Sound preset that plays it.
@(private)
placement_sound :: proc(d:Drag) -> bool {
    return d.kind==.Asset && (d.asset_kind==asset.KIND_SOUND || d.asset_kind==asset.KIND_SOUND_SET)
}

@(private)
placement_same :: proc(a,b:Drag) -> bool {return a.kind==b.kind && a.card==b.card && a.asset_id==b.asset_id && a.asset_kind==b.asset_kind}

@(private)
placement_measure :: proc(s:^Session,p:^Placement_Preview,part:Placement_Part) {
    append(&p.parts,part)
    low,high,known:=picker_bounds(s.picker,s.app.assets,part.mesh)
    if !known {return}
    box:=mm.aabb_transform({low,high},mm.transform_matrix(part.transform))
    if !p.measured {p.low,p.high,p.measured=box.min,box.max,true} else {
        for axis in 0..<3 {p.low[axis]=min(p.low[axis],box.min[axis]);p.high[axis]=max(p.high[axis],box.max[axis])}
    }
}

@(private)
placement_prepare :: proc(s:^Session,d:Drag) -> ^Placement_Preview {
    p:=&s.gui.preview
    a:=s.app.assets
    if a==nil {return p}
    key:=[5]u64{u64(d.kind),u64(d.card)|u64(s.library_generation)<<32,d.asset_id[0],d.asset_id[1],a.revision+1}
    if p.key==key {return p}
    p.key=key
    clear(&p.parts)
    p.low,p.high,p.measured={},{},false
    part:=Placement_Part{tint=erender.MATERIAL_VALUES_DEFAULT,transform=mm.TRANSFORM_IDENTITY}
    if d.kind==.Preset {
        card:=cards(s)[d.card]
        part.mesh.shape=card.body
        if card.scale!={} {part.transform.scale=card.scale}
        if part.mesh.shape!=.None {placement_measure(s,p,part)}
    } else if d.asset_kind==asset.KIND_MESH {
        part.mesh.mesh=d.asset_id
        placement_measure(s,p,part)
    } else if d.asset_kind==asset.KIND_PREFAB || d.asset_kind==asset.KIND_SCENE {
        file:=host.assets_scene(a,d.asset_id)
        if file==nil {return p}
        data:=host.app_world_create(s.app)
        if data==nil {return p}
        defer host.app_world_free(s.app,data)
        w:=host.app_world_ref(s.app,data)
        report,error:=scene.instantiate(w,file,&a.types,{transient=true,documents=scene.assets_documents(a)})
        if error!=.None {return p}
        core.world_settle(w)
        if transforms:=core.world_table_of(w,core.Transform);transforms!=nil {
            if root:=core.get(transforms,report.root);root!=nil {root.position,root.rotation={},1}
        }
        if meshes:=core.world_table_of(w,erender.Mesh_Renderer);meshes!=nil {
            for mesh,i in meshes.values[:core.count(meshes)] {
                e:=meshes.entities[i]
                if entity_hidden(w,e) || entity_has(w,e,erender.Drawn_Elsewhere) {continue}
                part=Placement_Part{mesh=mesh,tint=erender.MATERIAL_VALUES_DEFAULT,transform=entity_world(w,e)}
                if tint,ok:=entity_get(w,e,erender.Material_Values);ok {part.tint=tint}
                placement_measure(s,p,part)
            }
        }
    }
    return p
}

@(private)
placement_point :: proc(s:^Session,d:Drag,hit:Pick) -> [3]f32 {
    point:=place_point(s.viewport,hit)
    p:=placement_prepare(s,d)
    if p.measured {
        normal:=hit.entity!=core.NONE && !hit.indicator?hit.normal:[3]f32{0,1,0}
        support:=f32(0)
        for corner in 0..<8 {
            v:=[3]f32{corner&1!=0?p.high.x:p.low.x,corner&2!=0?p.high.y:p.low.y,corner&4!=0?p.high.z:p.low.z}
            support=max(support,-(v.x*normal.x+v.y*normal.y+v.z*normal.z))
        }
        point+=normal*support
    } else if d.kind==.Preset {
        point.y+=cards(s)[d.card].lift
    } else if placement_sound(d) {
        point.y+=cards(s)[int(Preset.Sound)].lift
    }
    return point
}

// The lines of the frame that follow the grid: the ghost of a placement and the entity a list points at.
@(private)
tools_lines :: proc(s:^Session,w:core.World_Ref) {
    if s.mode==.Play {return}
    ghost_draw(s,w)
    hidden_ghosts_draw(s,w)
    finder_outline(s,w)
}

// The ghosts of the meshes that are hidden or turned off, made again only
// when the scene, the selection or the assets change.
@(private)
hidden_ghosts_draw :: proc(s:^Session,w:core.World_Ref) {
    v:=s.viewport
    a:=s.app.assets
    if a==nil || !ghosts_shown(s) {return}
    hidden:=core.world_table_of(w,erender.Hidden)
    disabled:=core.world_table_of(w,core.Disabled)
    if (hidden==nil || core.count(hidden)==0) && (disabled==nil || core.count(disabled)==0) {return}
    if r:=s.app.renderer;r!=nil {
        style:=r.highlight
        style.colors[GHOST_LEVEL-1],style.fill[GHOST_LEVEL-1],style.behind[GHOST_LEVEL-1]=GHOST_FILL,GHOST_OPACITY,0
        if style!=r.highlight {gpu.renderer_set_highlight_style(r,style)}
    }
    worlds:=core.world_table_of(w,core.World_Transform)
    meshes:=core.world_table_of(w,erender.Mesh_Renderer)
    parents:=core.world_table_of(w,core.Parent)
    key:=[8]u64{
        u64(uintptr(w.data)),worlds!=nil?worlds.layout+worlds.version:0,meshes!=nil?meshes.layout+meshes.version:0,
        hidden!=nil?hidden.layout+hidden.version:0,parents!=nil?parents.layout+parents.version:0,
        core.world_entities(w).activity,v.levels_serial,a.revision+a.structure,
    }
    if key!=v.ghosts_key {
        v.ghosts_key=key
        clear(&v.ghosts)
        items:=scene_items(s,w,true)
        for item in scene_item_next(&items) {
            if !item.hidden || !item.body {continue}
            instance,ok:=erender.mesh_instance(a,item.mesh,mm.transform_matrix(item.world))
            if !ok {
                // A mesh still loading is asked for again the next frame.
                v.ghosts_key={}
                continue
            }
            instance.object_id,instance.copy_owner=u64(item.entity),GHOST_OWNER
            level:=entity_level(v,item.entity)
            instance.highlight,instance.outline_only=level!=0?level:GHOST_LEVEL,true
            append(&v.ghosts,instance)
        }
        host.assets_commit(a)
    }
    for instance in v.ghosts {host.extras_instance_add(&s.app.extras,instance)}
}

// The box an entity occupies in the world, drawn over the scene.
@(private)
outline_entity :: proc(s:^Session,w:core.World_Ref,e:core.Entity,color:[4]f32) {
    if !entity_alive(w,e) {return}
    world:=entity_world(w,e)
    low,high:=[3]f32{-GHOST_MARKER*0.5,-GHOST_MARKER*0.5,-GHOST_MARKER*0.5},[3]f32{GHOST_MARKER*0.5,GHOST_MARKER*0.5,GHOST_MARKER*0.5}
    if mesh,ok:=entity_get(w,e,erender.Mesh_Renderer);ok && (mesh.mesh!={} || mesh.shape!=.None) {
        if mesh_low,mesh_high,known:=picker_bounds(s.picker,s.app.assets,mesh);known {low,high=mesh_low,mesh_high}
    }
    gpu.debug_box_transformed(&s.viewport.lines,mm.transform_matrix(world),low,high,color)
}

@(private)
ghost_draw :: proc(s:^Session,w:core.World_Ref) {
    g:=s.gui
    drag:=g.drag
    if drag.kind==.None && g.placement.active {drag=g.placement.subject;drag.moved,drag.released=true,false}
    d:=&drag
    v:=s.viewport
    if !placement_subject(d^) || !d.moved || d.released {return}
    if g.ctx.over || g.ctx.popup.count>0 || g.modal!=.None || v.pick.active || s.edits.open || !ui.rect_contains(viewport_rect(v),v.pointer) {return}
    hit:=pick_point(s,w,v.pointer)
    point:=placement_point(s,d^,hit)
    p:=&g.preview
    for part,i in p.parts {
        transform:=part.transform
        transform.position+=point
        if instance,ok:=erender.mesh_instance(s.app.assets,part.mesh,mm.transform_matrix(transform),part.tint);ok {
            instance.copy_owner,instance.copy_variant=0x706c6163656d656e,u64(i+1)
            host.extras_instance_add(&s.app.extras,instance)
        }
    }
    if len(p.parts)==0 {gpu.debug_circle(&v.lines,point,{0,1,0},GHOST_MARKER,GHOST_COLOR,32)}
    host.assets_commit(s.app.assets)
}
