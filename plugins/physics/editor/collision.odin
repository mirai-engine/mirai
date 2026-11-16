package physics_editor

import "mirai:editor"
import "core:fmt"
import "core:mem"
import "mirai:core"
import "mirai:std/base"
import "mirai:std/serial"
import phys "plugins:physics/runtime"
import "mirai:editor/kit"
import "mirai:ui"

// Categories, presets and masks of categories are ids with names that the
// inspector shows by itself. Physics draws what depends on another value: the
// preset of a collider, whose sensor, belongs and collides show the preset's
// in gray until it is Custom, and Collision_Settings by the categories and
// presets the code declares, which it declares with names_create.

@(private)
collision_settings_of :: proc(w:core.World_Ref) -> ^phys.Collision_Settings {
    if w.info==nil || w.data==nil {return nil}
    return core.world_storage_of(w,phys.Collision_Settings)
}

// The categories the code declares that fit Collision_Layers.
@(private)
collision_categories :: proc(info:^core.World_Info,allocator:=context.temp_allocator) -> []core.Name_Info {
    list:=make([dynamic]core.Name_Info,allocator)
    for entry in core.names_of(info,phys.Collision_Category) {
        if entry.value<0 || entry.value>=phys.COLLISION_CATEGORY_CAPACITY {continue}
        append(&list,entry)
    }
    return list[:]
}

// ---------------------------------------------------------------- the collider

// The preset of a collider, chosen by name; typing a new one declares it. Choosing Custom keeps what the
// collider was as its own. Its sensor, belongs and collides show those of its preset, in gray.
@(private)
collision_collider_field :: proc(c:editor.Inspector_Context,type:typeid,offset:uintptr,label:string) -> bool {
    if c.table==nil || c.table.type!=phys.Collider || len(c.entities)==0 {return false}
    table:=core.world_table_at(c.world,c.table)
    first:=cast(^phys.Collider)core.raw_find(table,c.table.info,c.entities[0])
    if first==nil {return false}
    settings:=collision_settings_of(c.world)
    switch offset {
    case offset_of(phys.Collider,preset):
        collision_preset_choice(c,table,label,first.preset,settings)
        return true
    case offset_of(phys.Collider,sensor),offset_of(phys.Collider,belongs),offset_of(phys.Collider,collides):
        if first.preset==phys.PRESET_CUSTOM {return false}
        // What the preset gives, editable: the first change makes the collider Custom with it.
        of:=phys.collision_preset_setting(settings,first.preset)
        ctx:=c.session.gui.ctx
        switch offset {
        case offset_of(phys.Collider,sensor):
            editor.row_begin(ctx,label)
            sensor:=of.sensor
            if kit.toggle_switch(ctx,ui.id(ctx,"collider_preset_sensor"),&sensor) {
                of.sensor=sensor
                collision_preset_customize(c.session,c.table,table,c.entities,of,{.Sensor},settings)
            }
            ui.spacer(ctx)
            editor.row_end(ctx)
        case offset_of(phys.Collider,belongs):
            masks:=[2][]u8{mem.ptr_to_bytes(&of.belongs),mem.ptr_to_bytes(&of.collides)}
            titles:=[2]string{"Belongs","Collides"}
            if ui.box(ctx,{width=ui.GROW,height=ui.FIT,gap=4}) {
                changed:=editor.names_matrix(ctx,c.world.info,phys.Collision_Category,ui.id(ctx,"collider_preset_layers"),titles[:],masks[:])
                ui.spacer(ctx,editor.REVERT_SIDE,1)
                parts:Collision_Parts
                if changed[0] {parts+={.Belongs}}
                if changed[1] {parts+={.Collides}}
                if parts!={} {collision_preset_customize(c.session,c.table,table,c.entities,of,parts,settings)}
            }
        }
        return true
    }
    return false
}

@(private)
collision_preset_choice :: proc(c:editor.Inspector_Context,table:^core.Raw_Table,label:string,current:phys.Collision_Preset,settings:^phys.Collision_Settings) {
    s:=c.session
    ctx:=s.gui.ctx
    presets:=core.names_of(c.world.info,phys.Collision_Preset)
    options:=make([]string,len(presets),context.temp_allocator)
    selected:=-1
    for entry,i in presets {
        options[i]=editor.readable(entry.name)
        if entry.value==i64(current) {selected=i}
    }
    created:string
    chosen:=phys.Collision_Preset(0)
    changed:=false
    editor.row_begin(ctx,label)
    if ui.dropdown(ctx,ui.id(ctx,"collider_preset",1),{list=options},&selected,{width=-1,height=ui.metric(ctx,"row"),searchable=true,empty=phys.collision_name(c.world.info,phys.Collision_Preset,i64(current))},&created) {
        chosen,changed=phys.Collision_Preset(presets[selected].value),true
    }
    editor.row_end(ctx)
    if created!="" {
        made,error:=editor.names_create(s,c.world.info,phys.Collision_Preset,created)
        if error!=.None {editor.notify(s,editor.names_error_text(error,"Collision_Preset",created))}
        else {chosen,changed=phys.Collision_Preset(made),true}
    }
    if changed {collision_preset_apply(s,c.table,table,c.entities,chosen,settings)}
}

// Every selected collider takes the preset, in one step; one that turns Custom keeps what its preset was.
@(private)
collision_preset_apply :: proc(s:^editor.Session,t:^core.Table_Info,table:^core.Raw_Table,entities:[]core.Entity,chosen:phys.Collision_Preset,settings:^phys.Collision_Settings) {
    opened,ready:=editor.edit_open(s,"Collision")
    if !ready {return}
    defer editor.edit_close(s,opened)
    for e in entities {
        value:=cast(^phys.Collider)core.raw_find(table,t.info,e)
        if value==nil {continue}
        next:=value^
        if chosen==phys.PRESET_CUSTOM && next.preset!=phys.PRESET_CUSTOM {
            of:=phys.collision_of_collider(settings,next)
            next.sensor,next.belongs,next.collides=of.sensor,of.belongs,of.collides
        }
        next.preset=chosen
        if next!=value^ {editor.field_write(s,t,{e},0,mem.ptr_to_bytes(&next))}
    }
}

Collision_Part :: enum {Sensor,Belongs,Collides}
Collision_Parts :: bit_set[Collision_Part]

// A change to what a preset gives: every selected collider turns Custom, keeps
// what its own preset gave and takes the parts changed, in one step.
@(private)
collision_preset_customize :: proc(s:^editor.Session,t:^core.Table_Info,table:^core.Raw_Table,entities:[]core.Entity,edited:phys.Collision_Preset_Setting,parts:Collision_Parts,settings:^phys.Collision_Settings) {
    opened,ready:=editor.edit_open(s,"Collision")
    if !ready {return}
    defer editor.edit_close(s,opened)
    for e in entities {
        value:=cast(^phys.Collider)core.raw_find(table,t.info,e)
        if value==nil {continue}
        next:=value^
        if next.preset!=phys.PRESET_CUSTOM {
            of:=phys.collision_of_collider(settings,next)
            next.sensor,next.belongs,next.collides=of.sensor,of.belongs,of.collides
        }
        if .Sensor in parts {next.sensor=edited.sensor}
        if .Belongs in parts {next.belongs=edited.belongs}
        if .Collides in parts {next.collides=edited.collides}
        next.preset=phys.PRESET_CUSTOM
        if next!=value^ {editor.field_write(s,t,{e},0,mem.ptr_to_bytes(&next))}
    }
}

// ---------------------------------------------------------------- the settings

COLLISION_SETTINGS_RULE :: "each preset has one entry and Custom has none; a push joins two categories of Collision_Layers once with a finite force"

// A setting changes only into valid settings.
@(private)
collision_value_write :: proc(c:^editor.Inspect,offset:int,bytes:[]u8) -> bool {
    if c.type==phys.Collision_Settings && c.storage>0 {
        if offset<0 || offset+len(bytes)>size_of(phys.Collision_Settings) {return false}
        next:=(cast(^phys.Collision_Settings)c.value)^
        mem.copy(rawptr(uintptr(&next)+uintptr(offset)),raw_data(bytes),len(bytes))
        if !phys.collision_settings_valid(&next) {
            editor.notify(c.s,COLLISION_SETTINGS_RULE)
            return false
        }
    }
    editor.inspect_write(c,offset,bytes)
    return true
}

// Writes the presets of next when they differ from those of the settings.
@(private)
collision_presets_write :: proc(c:^editor.Inspect,next:^phys.Collision_Settings) {
    if !phys.collision_settings_valid(next) {
        editor.notify(c.s,COLLISION_SETTINGS_RULE)
        return
    }
    current:=cast(^phys.Collision_Settings)c.value
    if current.presets!=next.presets {editor.inspect_write(c,int(offset_of(phys.Collision_Settings,presets)),mem.ptr_to_bytes(&next.presets))}
}

// A category chosen by name among those the code declares; typing a new one declares it.
@(private)
collision_category_choice :: proc(c:^editor.Inspect,label,id:string,at:int,current:phys.Collision_Category) -> (value:phys.Collision_Category,changed:bool) {
    ctx:=c.s.gui.ctx
    categories:=collision_categories(c.w.info)
    options:=make([]string,len(categories),context.temp_allocator)
    selected:=-1
    for entry,i in categories {
        options[i]=editor.readable(entry.name)
        if entry.value==i64(current) {selected=i}
    }
    created:string
    editor.row_begin(ctx,label)
    if ui.dropdown(ctx,ui.id(ctx,id,at+1),{list=options},&selected,{width=-1,height=ui.metric(ctx,"row"),searchable=true,empty=phys.collision_name(c.w.info,phys.Collision_Category,i64(current))},&created) {
        value,changed=phys.Collision_Category(categories[selected].value),true
    }
    editor.row_end(ctx)
    if created!="" {
        made,error:=editor.names_create(c.s,c.w.info,phys.Collision_Category,created)
        if error!=.None {editor.notify(c.s,editor.names_error_text(error,"Collision_Category",created))}
        else {value,changed=phys.Collision_Category(made),true}
    }
    return
}

// A list to declare a new value of a type with names, showing those it has.
@(private)
collision_declare_row :: proc(c:^editor.Inspect,label,id:string,type:typeid,type_name:string) {
    ctx:=c.s.gui.ctx
    names:=core.names_of(c.w.info,type)
    options:=make([]string,len(names),context.temp_allocator)
    for entry,i in names {options[i]=editor.readable(entry.name)}
    selected:=-1
    created:string
    editor.row_begin(ctx,label)
    ui.dropdown(ctx,ui.id(ctx,id,1),{list=options},&selected,{width=-1,height=ui.metric(ctx,"row"),searchable=true,empty="Type a name to declare"},&created)
    editor.row_end(ctx)
    if created=="" {return}
    if _,error:=editor.names_create(c.s,c.w.info,type,created);error!=.None {editor.notify(c.s,editor.names_error_text(error,type_name,created))}
}

// An entry of the settings for a value the code does not declare, and a button that removes it.
@(private)
collision_undeclared_row :: proc(c:^editor.Inspect,id:string,at:int,text:string) -> (removed:bool) {
    ctx:=c.s.gui.ctx
    if ui.box(ctx,{width=ui.GROW,height=ui.fixed(ui.metric(ctx,"row")),gap=4,align_y=.Center}) {
        ui.label(ctx,text,ui.metric(ctx,"font_small"),ui.tone(ctx,"text_muted"),0)
        ui.spacer(ctx,-1,1)
        removed=ui.button(ctx,ui.id(ctx,id,at+1),{label="Remove",variant="ghost",height=ui.metric(ctx,"row"),size=ui.metric(ctx,"font_small")}).clicked
    }
    return
}

// A part of the settings that folds, as every part of a card does; true:
// open, with its band begun, which editor.fold_band_end ends.
@(private)
collision_section :: proc(c:^editor.Inspect,text:string) -> bool {
    key:=base.name_hash(text)
    if !editor.fold_section(c.s,ui.id(c.s.gui.ctx,"collision_section",int(key&0x7fffffff)),key~0x636f6c6c6973696f,text) {return false}
    editor.fold_band_begin(c.s)
    return true
}

@(private)
// What a preset belongs to and collides with, as the table of a collider.
collision_layers_matrix :: proc(c:^editor.Inspect,at:int,belongs,collides:phys.Collision_Layers) -> (next_belongs,next_collides:phys.Collision_Layers,changed:bool) {
    ctx:=c.s.gui.ctx
    next_belongs,next_collides=belongs,collides
    masks:=[2][]u8{mem.ptr_to_bytes(&next_belongs),mem.ptr_to_bytes(&next_collides)}
    titles:=[2]string{"Belongs","Collides"}
    which:=editor.names_matrix(ctx,c.w.info,phys.Collision_Category,ui.id(ctx,"preset_layers",at+1),titles[:],masks[:])
    return next_belongs,next_collides,which[0] || which[1]
}

@(private)
collision_settings_presets :: proc(c:^editor.Inspect,settings:^phys.Collision_Settings) {
    ctx:=c.s.gui.ctx
    if collision_section(c,"Categories") {
        for entry in collision_categories(c.w.info) {
            if ui.box(ctx,{width=ui.GROW,height=ui.fixed(ui.metric(ctx,"row")),align_y=.Center}) {ui.label(ctx,editor.readable(entry.name),ui.metric(ctx,"font_small"),ui.tone(ctx,"text_label"),0)}
        }
        collision_declare_row(c,"New category","declare_category",phys.Collision_Category,"Collision_Category")
        editor.fold_band_end(c.s)
    }
    if !collision_section(c,"Presets") {return}
    defer editor.fold_band_end(c.s)
    for entry,at in core.names_of(c.w.info,phys.Collision_Preset) {
        preset:=phys.Collision_Preset(entry.value)
        if preset==phys.PRESET_CUSTOM {continue}
        setting:=phys.collision_preset_setting(settings,preset)
        if ui.box(ctx,{width=ui.GROW,height=ui.fixed(ui.metric(ctx,"row")),align_y=.Center}) {ui.label(ctx,editor.readable(entry.name),ui.metric(ctx,"font_small"),ui.tone(ctx,"text"),0,font=ui.FONT_SEMIBOLD)}
        next:=setting
        editor.row_begin(ctx,"Sensor")
        if kit.toggle_switch(ctx,ui.id(ctx,"preset_sensor",at+1),&next.sensor) {}
        editor.row_end(ctx)
        if belongs,collides,changed:=collision_layers_matrix(c,at,setting.belongs,setting.collides);changed {next.belongs,next.collides=belongs,collides}
        if next==setting {continue}
        copied:=settings^
        if phys.collision_preset_setting_set(&copied,next)==.None {collision_presets_write(c,&copied)}
        else {editor.notify(c.s,"Collision_Settings has no free entry for another preset")}
    }
    for entry,at in settings.presets {
        if entry=={} || phys.collision_declared(c.w.info,phys.Collision_Preset,i64(entry.preset)) {continue}
        if collision_undeclared_row(c,"remove_preset",at,fmt.tprintf("Preset %d is not declared in code",entry.preset)) {
            copied:=settings^
            copied.presets[at]={}
            collision_presets_write(c,&copied)
        }
    }
    collision_declare_row(c,"New preset","declare_preset",phys.Collision_Preset,"Collision_Preset")
}

// The force of a push of Collision_Settings, which changes only into valid settings.
@(private)
collision_push_force_field :: proc(c:^editor.Inspect,offset:uintptr,key:u64) {
    ctx:=c.s.gui.ctx
    force:serial.Field
    for field in editor.type_fields(c.w.info,type_info_of(phys.Collision_Push)) {if field.name=="force" {force=field}}
    number:=serial.Type{kind=.Float,size=size_of(f32)}
    desc,scale:=editor.field_number(force,number)
    value:=editor.number_read(&c.value[offset],number)*scale
    editor.row_begin(ctx,"Force")
    r:=kit.slider_field(ctx,ui.id(ctx,"push_force",int(offset)+1),&value,desc)
    stepped:=c.held==0 || c.panel!=nil
    if stepped {editor.gesture_follow(c.s,key,r,editor.readable(c.name))}
    if r.changed {
        buffer:[8]u8
        editor.number_write(raw_data(buffer[:]),number,value/scale)
        collision_value_write(c,int(offset),buffer[:number.size])
    }
    if r.ended && stepped {editor.gesture_end(c.s,key)}
    editor.row_end(ctx)
}

@(private)
collision_settings_pushes :: proc(c:^editor.Inspect,settings:^phys.Collision_Settings,offset:uintptr) {
    ctx:=c.s.gui.ctx
    if !collision_section(c,"Pushes") {return}
    defer editor.fold_band_end(c.s)
    last:=-1
    for push,slot in settings.pushes {if push!={} {last=slot}}
    for slot in 0..<min(last+2,phys.COLLISION_PUSH_CAPACITY) {
        at:=uintptr(int(offset)+slot*size_of(phys.Collision_Push))
        push:=settings.pushes[slot]
        ui.id_push(ctx,ui.id(ctx,"push",slot+1))
        if value,changed:=collision_category_choice(c,fmt.tprintf("Push %d",slot+1),"push_a",slot,push.a);changed {
            collision_value_write(c,int(at+offset_of(phys.Collision_Push,a)),mem.ptr_to_bytes(&value))
        }
        if value,changed:=collision_category_choice(c,"With","push_b",slot,push.b);changed {
            collision_value_write(c,int(at+offset_of(phys.Collision_Push,b)),mem.ptr_to_bytes(&value))
        }
        collision_push_force_field(c,at+offset_of(phys.Collision_Push,force),u64(c.index)<<40|u64(at)<<8|0x7|1<<63)
        ui.id_pop(ctx)
    }
}

// The categories and presets the code declares, each preset with what Collision_Settings says of it, the
// entries for values it does not declare, and the pushes set with one more to fill.
@(private)
collision_settings_field :: proc(c:^editor.Inspect,type:typeid,name,label:string,offset:uintptr) -> bool {
    if c.type!=phys.Collision_Settings {return false}
    settings:=cast(^phys.Collision_Settings)c.value
    switch {
    case name=="presets" && offset==offset_of(phys.Collision_Settings,presets):
        collision_settings_presets(c,settings)
    case name=="pushes" && offset==offset_of(phys.Collision_Settings,pushes):
        collision_settings_pushes(c,settings,offset)
    case: return false
    }
    return true
}
