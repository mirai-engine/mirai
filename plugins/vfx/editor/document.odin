package vfx_editor

import "base:runtime"
import "core:hash"
import "core:mem"
import "core:slice"
import "mirai:asset"
import "mirai:core"
import "mirai:editor"
import erender "mirai:engine/render"
import "mirai:host"
import gpu "mirai:render"
import "mirai:std/base"
import "mirai:ui"
import vfx "plugins:vfx/runtime"
import "plugins:vfx/runtime/effect"

// The document of a particle effect: its particles at the time of its
// playback, as the game shows them (preview.odin), and every value of its
// file. The rows are those of Details, in groups, with arrows that give a
// value back as it was when the document read it, and an eye per field that
// hides it from the instances. The parameters of its Vfx program are those
// the renderer declares. What the rows change is written into the .particle,
// in memory and unsaved, once the UI lets go of it (a drag, a typed value, a
// popup): a step of the history of the document each time.

PARTICLE_FIELDS :: 64 // of Particle_Info that its hidden fields can name
PARTICLE_SIDE :: 512  // pixels of a side of its image
EYE_WIDTH :: 20       // the column of the eyes, with its gap
EFFECT_WIDTH :: f32(320)
DOCUMENT_SCOPE :: ui.Id(0x70617274)
KEY_EFFECT :: u64(0x7061727469636c65) // of its values among those the rows of Details hold

// What the panel holds of an effect, as its file has it: the hidden fields
// by their index in Particle_Info.
Effect_Values :: struct {
    info:effect.Particle_Info,
    parameters:[effect.PARTICLE_MAX_PARAMETERS]effect.Particle_Parameter,
    parameter_count:int,
    hidden:bit_set[0..<PARTICLE_FIELDS;u64],
    resources:[vfx.RESOURCES]effect.Particle_Resource, // kept as the file has them
    resource_count:int,
}

Particle_Group :: enum u8 {Spawn,Shape,Motion,Look,Collision,Program}
PARTICLE_GROUP_TITLES :: [Particle_Group]string{.Spawn="SPAWN",.Shape="SHAPE",.Motion="MOTION",.Look="LOOK",.Collision="COLLISION AND EVENTS",.Program="PROGRAM"}

// A field of Particle_Info in the group the panel shows it in, in order.
Particle_Row :: struct {group:Particle_Group,field:string}
PARTICLE_ROWS :: [?]Particle_Row{
    {.Spawn,"duration"},{.Spawn,"prewarm"},{.Spawn,"max_particles"},{.Spawn,"rate"},{.Spawn,"rate_over_cycle"},{.Spawn,"rate_over_distance"},{.Spawn,"bursts"},
    {.Shape,"shape"},{.Shape,"shape_size"},{.Shape,"surface_mesh"},{.Shape,"shape_angle"},{.Shape,"shell"},
    {.Motion,"lifetime"},{.Motion,"speed"},{.Motion,"velocity"},{.Motion,"inherit_velocity"},{.Motion,"local_space"},{.Motion,"gravity"},
    {.Motion,"acceleration"},{.Motion,"drag"},{.Motion,"noise"},{.Motion,"noise_frequency"},{.Motion,"noise_speed"},{.Motion,"attractor"},{.Motion,"attractor_strength"},
    {.Look,"size"},{.Look,"rotation"},{.Look,"spin"},{.Look,"colors"},{.Look,"intensity"},{.Look,"emission_mode"},{.Look,"size_over_life"},{.Look,"color_over_life"},
    {.Look,"render"},{.Look,"blend"},{.Look,"lit"},{.Look,"lights"},{.Look,"light_shadows"},{.Look,"light_intensity"},{.Look,"light_range"},{.Look,"light_radius"},{.Look,"sort"},{.Look,"material"},{.Look,"mesh"},{.Look,"facing"},{.Look,"spin_axis"},{.Look,"mesh_rotation"},{.Look,"mesh_scale"},{.Look,"stretch"},{.Look,"soft"},{.Look,"flipbook"},{.Look,"flipbook_speed"},
    {.Collision,"collision"},{.Collision,"bounce"},{.Collision,"friction"},{.Collision,"collision_life"},{.Collision,"trigger"},{.Collision,"sub_particle"},{.Collision,"sub_count"},{.Collision,"report"},
    {.Program,"program"},
}

// A texture parameter as a row of Details shows it.
Particle_Texture :: struct {texture:base.Asset_Id}

Effect_Document :: struct {
    image:editor.Asset_Image,
    playback:editor.Asset_Playback, // inside a cycle of the effect
    id:base.Asset_Id,     // the .particle of the document in front
    read:bool,            // file holds what the file of id holds
    revision:u64,         // of the assets when it was read
    file:Effect_Values,
    held:Effect_Values,   // file with the edits of the rows, until they are written
    base:Effect_Values,   // what the file held when the document read it: the arrows of the rows give it back
    open:[Particle_Group]bool,
    scroll:[2]f32,
    preview:Effect_Preview,
    due:u64,              // the signature of what the image is to show; drawn between frames
}

// The cycle of an effect, and how long it shows: its cycle and the longest
// life of its particles.
particle_span :: proc(info:^effect.Particle_Info) -> (cycle,shown:f32) {
    cycle=max(info.duration,0.001)
    return cycle,cycle+max(info.lifetime[0],info.lifetime[1])
}

// The index of a field of Particle_Info; -1 for a name it does not have.
particle_field_index :: proc(name:string) -> int {
    fields:=runtime.type_info_base(type_info_of(effect.Particle_Info)).variant.(runtime.Type_Info_Struct)
    for i in 0..<min(int(fields.field_count),PARTICLE_FIELDS) {
        if fields.names[i]==name {return i}
    }
    return -1
}

// What the file of an effect holds; false when it cannot be read.
effect_values_read :: proc(a:^host.Assets,id:base.Asset_Id) -> (values:Effect_Values,ok:bool) {
    if a==nil || id=={} {return}
    view:=vfx.effect_view(a,id) or_return
    return effect_values_of(view),true
}

effect_values_of :: proc(view:effect.Particle_View) -> (values:Effect_Values) {
    if view.info!=nil {values.info=view.info^}
    values.parameter_count=min(len(view.parameters),len(values.parameters))
    copy(values.parameters[:],view.parameters[:values.parameter_count])
    for &field in view.hidden {
        if index:=particle_field_index(base.text_get(field.name[:]));index>=0 {values.hidden+={index}}
    }
    values.resource_count=copy(values.resources[:],view.resources)
    return
}

// The file that holds the values, in temporary memory.
effect_file :: proc(values:^Effect_Values) -> (file:Particle_File) {
    file.info=values.info
    file.parameters=make([dynamic]effect.Particle_Parameter,0,values.parameter_count,context.temp_allocator)
    append(&file.parameters,..values.parameters[:values.parameter_count])
    file.hidden=make([dynamic]effect.Particle_Field,context.temp_allocator)
    file.resources=make([dynamic]effect.Particle_Resource,0,values.resource_count,context.temp_allocator)
    append(&file.resources,..values.resources[:values.resource_count])
    fields:=runtime.type_info_base(type_info_of(effect.Particle_Info)).variant.(runtime.Type_Info_Struct)
    for i in 0..<min(int(fields.field_count),PARTICLE_FIELDS) {
        if i not_in values.hidden {continue}
        entry:effect.Particle_Field
        base.text_set(entry.name[:],fields.names[i])
        append(&file.hidden,entry)
    }
    return
}

@(private)
parameter_same :: proc(a,b:^effect.Particle_Parameter) -> bool {
    return a.name==b.name && a.kind==b.kind && a.components==b.components && a.value==b.value && a.texture==b.texture
}

@(private)
parameters_same :: proc(a,b:^Effect_Values) -> bool {
    if a.parameter_count!=b.parameter_count {return false}
    for i in 0..<a.parameter_count {
        if !parameter_same(&a.parameters[i],&b.parameters[i]) {return false}
    }
    return true
}

@(private)
Span_Visitor :: #type proc(offset:uintptr,size:int,user:rawptr)

// The values of Particle_Info, and its program, as spans of its bytes.
@(private)
info_spans :: proc(visit:Span_Visitor,user:rawptr) {
    Spans :: struct {visit:Span_Visitor,user:rawptr}
    spans:=Spans{visit,user}
    each :: proc(value:effect.Particle_Value,user:rawptr) -> bool {
        s:=cast(^Spans)user
        s.visit(value.offset,value.size,s.user)
        return true
    }
    effect.particle_values_visit(each,&spans)
    // The program is text, which is no value of an instance.
    visit(offset_of(effect.Particle_Info,program),size_of(effect.Particle_Info{}.program),user)
}

@(private)
span_of :: proc(info:^effect.Particle_Info,offset:uintptr,size:int) -> []u8 {
    return mem.byte_slice(rawptr(uintptr(info)+offset),size)
}

// Whether the panel holds values the file does not have.
effect_edited :: proc(held,file:^Effect_Values) -> bool {
    if held.hidden!=file.hidden || !parameters_same(held,file) {return true}
    Compare :: struct {held,file:^effect.Particle_Info,differ:bool}
    compare:=Compare{&held.info,&file.info,false}
    visit :: proc(offset:uintptr,size:int,user:rawptr) {
        c:=cast(^Compare)user
        if mem.compare(span_of(c.held,offset,size),span_of(c.file,offset,size))!=0 {c.differ=true}
    }
    info_spans(visit,&compare)
    return compare.differ
}

// What a file read again brings: each value the panel did not change takes
// the one of the file now. The parameters and the hidden fields go whole.
effect_merge :: proc(held,before,now:^Effect_Values) {
    Merge :: struct {held,before,now:^effect.Particle_Info}
    merge:=Merge{&held.info,&before.info,&now.info}
    visit :: proc(offset:uintptr,size:int,user:rawptr) {
        m:=cast(^Merge)user
        kept:=span_of(m.held,offset,size)
        if mem.compare(kept,span_of(m.before,offset,size))==0 {copy(kept,span_of(m.now,offset,size))}
    }
    info_spans(visit,&merge)
    if parameters_same(held,before) {held.parameters,held.parameter_count=now.parameters,now.parameter_count}
    if held.hidden==before.hidden {held.hidden=now.hidden}
}

// The value stored for a parameter of the program; nil without one.
effect_parameter :: proc(values:^Effect_Values,name:string) -> ^effect.Particle_Parameter {
    return effect.particle_parameter_find(values.parameters[:values.parameter_count],name)
}

// Stores a value for a parameter the program declares; false without room.
effect_parameter_put :: proc(values:^Effect_Values,declared:^gpu.Program_Parameter,value:[4]f64,texture:base.Asset_Id) -> bool {
    stored:=effect_parameter(values,declared.name)
    if stored==nil {
        if values.parameter_count>=len(values.parameters) {return false}
        stored=&values.parameters[values.parameter_count]
        values.parameter_count+=1
    }
    stored^={kind=asset.Parameter_Kind(declared.kind),components=declared.components}
    base.text_set(stored.name[:],declared.name)
    if declared.kind==.Texture {
        stored.texture=texture
    } else {
        for axis in 0..<clamp(int(declared.components),1,4) {stored.value[axis]=value[axis]}
    }
    return true
}

effect_parameter_remove :: proc(values:^Effect_Values,name:string) {
    for i in 0..<values.parameter_count {
        if base.text_get(values.parameters[i].name[:])!=name {continue}
        copy(values.parameters[i:values.parameter_count-1],values.parameters[i+1:values.parameter_count])
        values.parameter_count-=1
        values.parameters[values.parameter_count]={}
        return
    }
}

// Gives a parameter back what the file stores for it, or nothing.
effect_parameter_revert :: proc(held,file:^Effect_Values,name:string) {
    stored:=effect_parameter(file,name)
    if stored==nil {
        effect_parameter_remove(held,name)
        return
    }
    if kept:=effect_parameter(held,name);kept!=nil {
        kept^=stored^
    } else if held.parameter_count<len(held.parameters) {
        held.parameters[held.parameter_count]=stored^
        held.parameter_count+=1
    }
}

effect_hidden_toggle :: proc(values:^Effect_Values,field:string) {
    index:=particle_field_index(field)
    if index<0 {return}
    if index in values.hidden {values.hidden-={index}} else {values.hidden+={index}}
}

// ---------------------------------------------------------------- the subject

@(private)
effect_subject_set :: proc(p:^Effect_Document,id:base.Asset_Id) {
    p.id,p.read=id,false
    p.file={}
    p.held={}
    p.base={}
    p.scroll=0
}

// Reads the file of the subject again when the assets change.
@(private)
effect_sync :: proc(a:^host.Assets,p:^Effect_Document) {
    if p.id=={} || a==nil {return}
    if record,found:=asset.registry_find(&a.registry,p.id);!found || record.kind!=effect.KIND {
        effect_subject_set(p,{})
        return
    }
    if p.read && p.revision==a.revision {return}
    now,ok:=effect_values_read(a,p.id)
    p.revision=a.revision
    if !ok {return}
    if p.read {effect_merge(&p.held,&p.file,&now)} else {
        p.held=now
        p.base=now
    }
    // One store per value until odin-lang/Odin#7937 (see ODIN_WORKAROUNDS).
    p.file=now
    p.read=true
}

// Writes the values of the document into the file of the effect. A program
// the shaders have refuses what it does not take, as particle.set does: the
// values go back to the file.
@(private)
effect_commit :: proc(s:^editor.Session,assets:^host.Assets,p:^Effect_Document) -> bool {
    file:=effect_file(&p.held)
    if name:=base.text_get(file.info.program[:]);name!="" && erender.program_find(assets,name,.Vfx)!=nil {
        program:vfx.Program
        if problem:=vfx.particle_program_check(assets,&file.info,file.parameters[:],nil,&program);problem!="" {
            editor.notify(s,problem)
            p.held=p.file
            return false
        }
    }
    if !particle_write(s,p.id,&file) {
        p.held=p.file
        return false
    }
    p.file=p.held
    return true
}

// ---------------------------------------------------------------- the document

@(private)
effect_document :: proc(s:^editor.Session,p:^Effect_Document,assets:^host.Assets,frame:core.Frame_Time,chosen:base.Asset_Id) {
    a:=assets
    g:=s.gui
    ctx:=g.ctx
    if p.id!=chosen {
        effect_subject_set(p,chosen)
        p.playback.time,p.playback.strip=0,{}
    }
    effect_sync(a,p)
    // A cycle until its last particle dies, and again with Loop: what an emitter previews in the editor.
    _,shown:=particle_span(&p.held.info)
    editor.asset_playback_advance(&p.playback,shown,frame.dt)
    id:=ui.id_derive(ctx,DOCUMENT_SCOPE,"particle")
    if ui.panel(ctx,id,editor.asset_workspace(g)) {
        ui.id_push(ctx,id)
        defer ui.id_pop(ctx)
        if ui.box(ctx,{width=ui.GROW,height=ui.GROW}) {
            if editor.asset_column_begin(ctx,ui.GROW,"Preview") {
                editor.asset_image_show(s,&p.image)
                editor.asset_playback_strip(s,&p.playback,shown,nil,p.id)
                editor.asset_column_end(ctx)
            }
            editor.asset_column_divider(ctx)
            if editor.asset_column_begin(ctx,ui.fixed(EFFECT_WIDTH),"Effect") {
                if p.read {
                    if ui.scroll_area(ctx,ui.id(ctx,"rows"),&p.scroll,{width=ui.GROW,height=ui.GROW,direction=.Column,gap=3,padding={8,8,10,8}}) {effect_rows(s,p,assets)}
                }
                editor.asset_column_end(ctx)
            }
        }
    }
    // What the rows changed goes to the file once nothing holds it.
    if p.read && ctx.active==0 && ctx.edit.id==0 && ctx.popup.count==0 && effect_edited(&p.held,&p.file) {effect_commit(s,assets,p)}
    effect_document_image(s,assets,p)
}

// The fields of the effect in their groups, each with its eye, and the
// parameters of its program after the program.
@(private)
effect_rows :: proc(s:^editor.Session,p:^Effect_Document,assets:^host.Assets) {
    ctx:=s.gui.ctx
    th:=&ctx.theme
    titles:=PARTICLE_GROUP_TITLES
    rows:=PARTICLE_ROWS
    values:=editor.Held_Values{key=KEY_EFFECT,info=type_info_of(effect.Particle_Info),value=&p.held.info,defaults=&p.base.info}
    group,open:=Particle_Group(len(Particle_Group)),false
    for row in rows {
        if row.group!=group {
            group=row.group
            open=ui.collapsible(ctx,ui.id(ctx,"group",int(group)+1),titles[group],&p.open[group]).open
        }
        if !open {continue}
        index:=particle_field_index(row.field)
        hidden:=index>=0 && index in p.held.hidden
        if ui.box(ctx,{width=ui.GROW,height=ui.FIT,gap=2,align_y=.Start}) {
            if ui.button(ctx,ui.id(ctx,"hidden",index+1),{icon=hidden?.Eye_Off:.Eye,icon_size=13,icon_color=hidden?th.text_faint:th.text_muted,style=.Ghost,width=EYE_WIDTH-2,height=th.row}).clicked {
                effect_hidden_toggle(&p.held,row.field)
            }
            if ui.box(ctx,{width=ui.GROW,height=ui.FIT,direction=.Column,gap=3}) {editor.held_field_row(s,values,row.field)}
        }
        if row.field=="program" {parameter_rows(s,p,assets)}
    }
}

// The parameters the Vfx program of the effect declares, with what the
// effect stores or their defaults, and those it stores that the program
// does not declare, which the x takes away.
@(private)
parameter_rows :: proc(s:^editor.Session,p:^Effect_Document,assets:^host.Assets) {
    ctx:=s.gui.ctx
    th:=&ctx.theme
    program:^gpu.Program
    if name:=base.text_get(p.held.info.program[:]);name!="" {program=erender.program_find(assets,name,.Vfx)}
    if program!=nil {
        for &declared,index in program.parameters {
            ui.id_push(ctx,ui.id(ctx,"parameter",index+1))
            parameter_row(s,p,&declared)
            ui.id_pop(ctx)
        }
    }
    removed:=-1
    for i in 0..<p.held.parameter_count {
        name:=base.text_get(p.held.parameters[i].name[:])
        if program!=nil && erender.program_parameter(program,name)!=nil {continue}
        if ui.box(ctx,{width=ui.GROW,height=ui.fixed(th.row),gap=4,align_y=.Center}) {
            ui.spacer(ctx,EYE_WIDTH-4,1)
            ui.label(ctx,editor.readable(name),th.font_small,th.text_faint,0)
            ui.spacer(ctx)
            if ui.button(ctx,ui.id(ctx,"stale",i+1),{icon=.Cross,style=.Ghost,width=th.row,height=th.row}).clicked {removed=i}
        }
    }
    if removed>=0 {effect_parameter_remove(&p.held,base.text_get(p.held.parameters[removed].name[:]))}
}

// A parameter as its kind and components take it, inside its range, with the
// arrow that gives it back what the file stores.
@(private)
parameter_row :: proc(s:^editor.Session,p:^Effect_Document,declared:^gpu.Program_Parameter) {
    ctx:=s.gui.ctx
    th:=&ctx.theme
    label:=editor.readable(declared.name)
    stored,reference:=effect_parameter(&p.held,declared.name),effect_parameter(&p.base,declared.name)
    value:=declared.defaults
    texture:base.Asset_Id
    if stored!=nil {value,texture=stored.value,stored.texture}
    if declared.kind==.Texture {
        now:=Particle_Texture{texture}
        before:Particle_Texture
        if reference!=nil {before.texture=reference.texture}
        held:=editor.Held_Values{key=KEY_EFFECT~base.name_hash(declared.name)|1,info=type_info_of(Particle_Texture),value=&now,defaults=&before}
        if ui.box(ctx,{width=ui.GROW,height=ui.FIT,gap=2,align_y=.Start}) {
            ui.spacer(ctx,EYE_WIDTH-2,1)
            if ui.box(ctx,{width=ui.GROW,height=ui.FIT,direction=.Column}) {
                if editor.held_field_row(s,held,"texture",label) {
                    if now.texture=={} && reference==nil {effect_parameter_remove(&p.held,declared.name)} else {effect_parameter_put(&p.held,declared,{},now.texture)}
                }
            }
        }
        return
    }
    count:=clamp(int(declared.components),1,4)
    fits:=ui.text_width(&ctx.font,label,th.font_small)<=th.label_width
    if count>1 && !fits {
        if ui.box(ctx,{width=ui.GROW,height=ui.fixed(th.row),gap=4,align_y=.Center}) {
            ui.spacer(ctx,EYE_WIDTH-4,1)
            ui.label(ctx,label,th.font_small,th.text_muted)
        }
    }
    changed,reverted:=false,false
    if ui.box(ctx,{width=ui.GROW,height=ui.fixed(th.row),gap=4,align_y=.Center}) {
        ui.spacer(ctx,EYE_WIDTH-4,1)
        if count==1 || fits {ui.label(ctx,label,th.font_small,th.text_label,fits?th.label_width:0)}
        switch {
        case declared.kind==.Bool:
            for axis in 0..<count {
                on:=value[axis]!=0
                if ui.toggle(ctx,ui.id(ctx,"toggle",axis+1),on?"On":"Off",&on,width=-1) {
                    value[axis]=on?1:0
                    changed=true
                }
            }
        case declared.color && count>=3:
            linear:=[3]f32{f32(value[0]),f32(value[1]),f32(value[2])}
            shown:=ui.display_color({clamp(linear.r,0,1),clamp(linear.g,0,1),clamp(linear.b,0,1)})
            if result,_:=ui.color_field(ctx,ui.id(ctx,"color"),&shown);result.changed {
                linear=ui.linear_color(shown)
                value[0],value[1],value[2]=f64(linear.r),f64(linear.g),f64(linear.b)
                changed=true
            }
        case:
            field:=ui.Number_Field{integer=declared.kind!=.Float,speed=declared.kind!=.Float?0.05:0.02}
            if declared.kind==.Uint {field.has_min=true}
            if declared.min<declared.max {
                field.has_min,field.has_max,field.min,field.max=true,true,declared.min,declared.max
                if !field.integer {field.speed=max((declared.max-declared.min)/200,1e-4)}
            }
            if count==1 {
                changed=ui.slider_field(ctx,ui.id(ctx,"number"),&value[0],field).changed
            } else {
                result,_:=ui.vector_field(ctx,ui.id(ctx,"numbers"),value[:count],{number=field})
                changed=result.changed
            }
        }
        // As the file has it: its value, or the default without one.
        before:=reference!=nil?reference.value:declared.defaults
        differs:=(stored==nil)!=(reference==nil) || !slice.equal(value[:count],before[:count])
        if differs {
            reverted=ui.button(ctx,ui.id(ctx,"revert"),{icon=.Revert,style=.Ghost,width=22,height=22}).clicked
        } else {
            ui.spacer(ctx,22,1)
        }
    }
    if reverted {
        effect_parameter_revert(&p.held,&p.base,declared.name)
    } else if changed {
        effect_parameter_put(&p.held,declared,value,{})
    }
}

// What the image is to show: the values, the assets they name and the time.
// It is drawn between frames (effect_document_between).
@(private)
effect_document_image :: proc(s:^editor.Session,assets:^host.Assets,p:^Effect_Document) {
    a:=assets
    if !p.read || a==nil || a.renderer==nil {
        p.image.ready,p.due=false,0
        return
    }
    values:=[5]u64{p.id[0],p.id[1],u64(a.revision),hash.fnv64a(mem.ptr_to_bytes(&p.held.info)),u64(transmute(u32)p.playback.time)}
    p.due=base.hash_combine(hash.fnv64a(mem.slice_to_bytes(values[:])),hash.fnv64a(mem.slice_to_bytes(p.held.parameters[:p.held.parameter_count])))|1
}

// The preview of the document in front goes to what its image is to show.
@(private)
effect_document_between :: proc(s:^editor.Session,d:^editor.Asset_Document) {
    v:=vfx_editor_of(s)
    if v==nil || editor.playing(s) {return}
    p:=&v.document
    if p.due==0 || p.due==p.image.signature || p.id!=d.id {return}
    image:=&p.image
    image.signature=p.due
    override,given:=preview_values(&p.held,&p.file)
    image.ready=preview_draw(s,&p.preview,p.id,&p.held.info,&override,&given,p.playback.time,PARTICLE_SIDE)
    image.renderer,image.texture=s.app.renderer,p.preview.texture
    image.side,image.size,image.stretch=0,{},false
}
