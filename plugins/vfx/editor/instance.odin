package vfx_editor

import "base:runtime"
import "core:fmt"
import "core:mem"
import "mirai:core"
import "mirai:editor"
import erender "mirai:engine/render"
import "mirai:std/base"
import "mirai:ui"
import vfx "plugins:vfx/runtime"
import "plugins:vfx/runtime/effect"

// The effect of a Particle_Emitter in Details, as the material of a mesh: a
// box with its preview and its name, which opens the list it is chosen from,
// and an arrow that unfolds the values of this entity's instance of it. Those
// live in the entity, as its Particle_Override; the assets the effect names
// (its material, its mesh, its sub particle) belong to the effect, and
// choosing one writes its file for every entity that shows it. Apply writes
// the values of the entity into the effect; revert gives them back. The
// fields the file of the effect hides are not shown.

SECTION_PARTICLE :: "particle values"
KEY_INSTANCE :: u64(0x696e7374616e6365) // of the values of the instance among the values the rows of Details hold

// What an entity shows of its effect.
@(private)
Effect :: struct {
    entity:core.Entity,
    particle:base.Asset_Id,
    shown:effect.Particle_Info, // of the effect, with the values of the entity over it
    hidden:[]effect.Particle_Field,
    override:vfx.Particle_Override,
}

@(private)
effect_read :: proc(s:^editor.Session,w:core.World_Ref,e:core.Entity) -> (f:Effect,ok:bool) {
    emitter:=editor.entity_get(w,e,vfx.Particle_Emitter) or_return
    f.entity,f.particle=e,emitter.particle
    f.override,_=editor.entity_get(w,e,vfx.Particle_Override)
    f.shown=vfx.particle_resolve(s.app.assets,emitter.particle,&f.override)
    if a:=s.app.assets;a!=nil && emitter.particle!={} {
        if view,found:=vfx.effect_view(a,emitter.particle);found {f.hidden=view.hidden}
    }
    return f,true
}

// The values of an instance are shown inside the section of its Particle_Emitter.
@(private)
emitter_within :: proc(type:typeid) -> bool {return type==vfx.Particle_Override}

// The effect of a live emitter has a box of its own after the fields (emitter_section).
@(private)
emitter_field :: proc(c:editor.Inspector_Context,info:^runtime.Type_Info,offset:uintptr,label:string) -> bool {
    return c.table!=nil && c.table.type==vfx.Particle_Emitter && len(c.entities)>0 && offset==offset_of(vfx.Particle_Emitter,particle) && info.id==base.Asset_Id
}

// The sections of the vfx plugin in Details.
@(private)
vfx_sections :: proc(c:editor.Inspector_Context) -> bool {return bindings_section(c) || emitter_section(c)}

// The rows of Particle_Bindings: the surface it starts particles on and, for
// each resource of the program of the effect that reads an entity, the entity
// it reads under the name the program gives it, in the source of that name,
// else in the one of its index (vfx.emitter_resources); a grid, also the name
// of the grid it reads.
@(private)
bindings_section :: proc(c:editor.Inspector_Context) -> bool {
    if c.table==nil || c.table.type!=vfx.Particle_Bindings || len(c.entities)==0 {return false}
    s:=c.session
    active:=c.entities[len(c.entities)-1]
    editor.inspector_entity_row(c,"Surface",int(offset_of(vfx.Particle_Bindings,surface)))
    f,read:=effect_read(s,c.world,active)
    if !read || s.app.assets==nil {return true}
    found:=erender.program_find(s.app.assets,base.text_get(f.shown.program[:]),.Vfx)
    if found==nil {return true}
    bindings,_:=editor.entity_get(c.world,active,vfx.Particle_Bindings)
    for resource,at in found.resources[:min(len(found.resources),vfx.RESOURCES)] {
        if resource.kind!=.Surface && resource.kind!=.Bones && resource.kind!=.Grid && resource.kind!=.Emitter {continue}
        slot:=at
        for &source,i in bindings.sources {
            if base.text_get(source.resource[:])==resource.name {slot=i;break}
        }
        if slot==at && base.text_get(bindings.sources[at].resource[:])!="" {continue}
        source:=int(offset_of(vfx.Particle_Bindings,sources))+slot*size_of(vfx.Particle_Source)
        editor.inspector_entity_row(c,editor.readable(resource.name),source+int(offset_of(vfx.Particle_Source,entity)))
        if resource.kind==.Grid {editor.inspector_text_row(c,fmt.tprintf("%s grid",editor.readable(resource.name)),source+int(offset_of(vfx.Particle_Source,grid)),vfx.GRID_NAME_BYTES)}
    }
    return true
}

// The rows of Particle_Emitter: its own fields, its effect and, for one
// entity, the values of its instance that the effect does not hide.
@(private)
emitter_section :: proc(c:editor.Inspector_Context) -> bool {
    if c.table==nil || c.table.type!=vfx.Particle_Emitter || len(c.entities)==0 {return false}
    s:=c.session
    ctx:=s.gui.ctx
    ins:=s.inspector
    single:=len(c.entities)==1
    active:=c.entities[len(c.entities)-1]
    f,_:=effect_read(s,c.world,active)
    key:=base.name_hash(SECTION_PARTICLE)
    unfolded:=!editor.inspector_section_open(ins,key)
    offset:=int(offset_of(vfx.Particle_Emitter,particle))
    emitter,_:=editor.entity_get(c.world,active,vfx.Particle_Emitter)
    particle,same:=emitter.particle,true
    for e in c.entities {
        if other,ok:=editor.entity_get(c.world,e,vfx.Particle_Emitter);ok && other.particle!=particle {same=false}
    }
    editor.inspector_fields(c,c.table.info)
    if ui.box(ctx,{width=ui.GROW,height=ui.fixed(editor.MATERIAL_ROW),gap=4,align_y=.Center}) {
        ui.label(ctx,"Particle",ui.metric(ctx,"font_small"),ui.tone(ctx,"text_label"),ui.metric(ctx,"label_width"))
        local:=single && f.override.count>0
        open:=editor.asset_list_shown(s,c.table,offset)
        revert:bool
        label,quad:="Multiple",ui.Quad{}
        if same {label,quad=editor.asset_label_of(s,particle,"Default"),editor.asset_quad(s,effect.PARTICLE_KIND,particle,editor.MATERIAL_ROW)}
        clicked,anchor,dropped:=editor.asset_box(s,"particle",1,label,quad,open,local?&revert:nil,effect.PARTICLE_KIND,particle if same else {})
        if clicked {editor.asset_list_open(s,c.table,offset,effect.PARTICLE_KIND,"Default",anchor)}
        if dropped!={} {editor.field_write(s,c.table,c.entities,offset,mem.ptr_to_bytes(&dropped))}
        if revert {particle_revert(s,active)}
        if local && f.particle!={} && ui.button(ctx,ui.id(ctx,"apply"),{icon=.Save_Prefab,variant="ghost",width=22,height=editor.MATERIAL_ROW}).clicked {particle_apply(s,active)}
        inspected:=editor.inspect_component(s,c.world,vfx.Particle_Emitter,c.entities)
        inspected.width=c.width
        editor.field_reset_button(&inspected,offset,size_of(base.Asset_Id))
        if single && ui.button(ctx,ui.id(ctx,"parameters"),{icon=unfolded?.Chevron_Down:.Chevron_Right,variant="ghost",width=ui.metric(ctx,"row"),height=editor.MATERIAL_ROW}).clicked {editor.inspector_section_toggle(ins,key)}
    }
    if !single || !unfolded {return true}
    inherited:vfx.Particle_Override
    reference:=editor.inspect_component(s,c.world,vfx.Particle_Override,{active})
    if reference.t!=nil {inherited=(cast(^vfx.Particle_Override)raw_data(editor.inspect_default(s,c.world,reference.t,active)))^}
    defaults:=vfx.particle_resolve(s.app.assets,f.particle,&inherited)
    held:=editor.Held_Values{key=KEY_INSTANCE,info=type_info_of(effect.Particle_Info),value=&f.shown,defaults=&defaults,write=instance_write,user=&f,name="Particle"}
    v:=runtime.type_info_base(type_info_of(effect.Particle_Info)).variant.(runtime.Type_Info_Struct)
    for i in 0..<int(v.field_count) {
        if effect.particle_hidden(f.hidden,v.names[i]) {continue}
        editor.held_field_row(s,held,v.names[i])
    }
    return true
}

@(private)
instance_write :: proc(s:^editor.Session,user:rawptr,offset:int,bytes:[]u8) {
    particle_value_write(s,(cast(^Effect)user).entity,offset,bytes)
}

// Writes bytes at an offset of the values an entity shows of its effect. The
// values they change become values of the entity; the assets they change,
// of the effect for every entity that shows it.
particle_value_write :: proc(s:^editor.Session,e:core.Entity,offset:int,bytes:[]u8) -> bool {
    w:=editor.shown_world(s)
    f:=effect_read(s,w,e) or_return
    next:=f.shown
    mem.copy(rawptr(uintptr(&next)+uintptr(offset)),raw_data(bytes),len(bytes))
    override:=f.override
    file:=particle_file(s,f.particle)
    values,assets:=false,false
    // The program, as the assets the effect names, is of the effect.
    if next.program!=f.shown.program {file.info.program,assets=next.program,true}
    for value in effect.particle_fields() {
        start:=int(value.offset)
        if start+value.size<=offset || start>=offset+len(bytes) {continue}
        now:=mem.byte_slice(rawptr(uintptr(&next)+value.offset),value.size)
        if mem.compare(now,mem.byte_slice(rawptr(uintptr(&f.shown)+value.offset),value.size))==0 {continue}
        if value.kind==.Asset {
            mem.copy(rawptr(uintptr(&file.info)+value.offset),raw_data(now),value.size)
            assets=true
            continue
        }
        if error:=vfx.value_put(&override,base.name_hash(value.path),now);error!=.None {
            editor.notify(s,vfx.error_message(error))
            return false
        }
        values=true
    }
    opened,edit_ready:=editor.edit_open(s,"Particle")
    if !edit_ready {return false}
    defer editor.edit_close(s,opened)
    if values {
        table:=core.world_table_of(w,vfx.Particle_Override)
        if table==nil {return false}
        core.add(table,e,override)
    }
    if assets {return particle_change(s,e,&file)}
    return values
}

// Gives back to the effect every value the entity had for it.
@(private)
particle_revert :: proc(s:^editor.Session,e:core.Entity) -> bool {
    w:=editor.shown_world(s)
    values:=core.world_table_of(w,vfx.Particle_Override)
    if values==nil || !core.has(values,e) {return false}
    opened,edit_ready:=editor.edit_open(s,"Revert particle")
    if !edit_ready {return false}
    defer editor.edit_close(s,opened)
    core.remove(values,e)
    return true
}

// Writes the values and program parameters the entity shows into its
// effect, for every entity that shows it.
@(private)
particle_apply :: proc(s:^editor.Session,e:core.Entity) -> bool {
    w:=editor.shown_world(s)
    f:=effect_read(s,w,e) or_return
    file:=particle_file(s,f.particle)
    file.info=f.shown
    instance_parameters(s,&file.info,&f.override,&file.parameters)
    opened,edit_ready:=editor.edit_open(s,"Apply to particle")
    if !edit_ready {return false}
    defer editor.edit_close(s,opened)
    particle_change(s,e,&file) or_return
    particle_revert(s,e)
    return true
}
