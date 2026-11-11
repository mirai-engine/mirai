package editor

import "base:runtime"
import "mirai:core"
import input "mirai:engine/input"
import "mirai:std/base"

Inspector_Context :: struct {
    session:^Session,
    world:core.World_Ref,
    table:^core.Table_Info,
    entities:[]core.Entity,
    width:f32,
}

// A sole-field Editor storage supplies the current callbacks after code reload.
// Each one says whether it drew what it was handed; the editor draws the rest.
Inspector_Provider :: struct {
    component:proc(c:Inspector_Context) -> bool,
    field:proc(c:Inspector_Context,type:typeid,offset:uintptr,label:string) -> bool,
    number:proc(c:^Inspect,type:typeid,label:string,offset:uintptr,key:u64) -> bool, // a number of a component or a setting, in its row
    array:proc(c:^Inspect,type:typeid,name,label:string,offset:uintptr) -> bool,     // an array of a component or a setting, with its rows
    popup:proc(s:^Session,w:core.World_Ref),          // what the inspector opens over itself, outside its scroll area
    valid:proc(info:^runtime.Type_Info,value:rawptr) -> (problem:string), // a setting the API is given; empty: it takes it
    // A component that the section of another shows (the values of an
    // instance of an effect): no section of its own, no component of the API.
    within:proc(type:typeid) -> bool,
}

// What a plugin adds with a component the editor adds: the Collider a
// Character takes its capsule from.
Component_Provider :: struct {
    added:proc(s:^Session,e:core.Entity,t:^core.Table_Info),
}

@(private)
inspector_number_extension :: proc(c:^Inspect,type:typeid,label:string,offset:uintptr,key:u64) -> bool {
    for &p in providers(c.s).inspectors[:providers(c.s).inspector_count] {
        if p.number!=nil && p.number(c,type,label,offset,key) {return true}
    }
    return false
}

@(private)
inspector_array_extension :: proc(c:^Inspect,type:typeid,name,label:string,offset:uintptr) -> bool {
    for &p in providers(c.s).inspectors[:providers(c.s).inspector_count] {
        if p.array!=nil && p.array(c,type,name,label,offset) {return true}
    }
    return false
}

@(private)
inspector_popups_extension :: proc(s:^Session,w:core.World_Ref) {
    for &p in providers(s).inspectors[:providers(s).inspector_count] {
        if p.popup!=nil {p.popup(s,w)}
    }
}

// Whether the section of another component, of a plugin, shows this one.
@(private)
inspector_within :: proc(s:^Session,t:^core.Table_Info) -> bool {
    for &p in providers(s).inspectors[:providers(s).inspector_count] {
        if p.within!=nil && p.within(t.type) {return true}
    }
    return false
}

// Why a plugin refuses a value of a setting; empty when none does.
@(private)
setting_problem :: proc(s:^Session,info:^runtime.Type_Info,value:rawptr) -> string {
    if info.id==input.Input_Settings {
        if problem:=input.input_settings_problem(s.info,(^input.Input_Settings)(value));problem!="" {return problem}
    }
    for &p in providers(s).inspectors[:providers(s).inspector_count] {
        if p.valid==nil {continue}
        if problem:=p.valid(info,value);problem!="" {return problem}
    }
    return ""
}

// What the plugins add with a component the editor added.
@(private)
component_companions :: proc(s:^Session,e:core.Entity,t:^core.Table_Info) {
    for &p in providers(s).components[:providers(s).component_count] {
        if p.added!=nil {p.added(s,e,t)}
    }
}

@(private)
inspector_extension :: proc(c:^Inspect,type:typeid,offset:uintptr=0,label:string="") -> bool {
    // A field of a setting or of the values of a panel has no table to hand a provider.
    if type!=nil && c.t==nil {return false}
    descriptor:=Inspector_Context{c.s,c.w,c.t,c.entities,c.width}
    p:=providers(c.s)
    for provider in p.inspectors[:p.inspector_count] {
        if type==nil {
            if provider.component!=nil && provider.component(descriptor) {return true}
        } else if provider.field!=nil && provider.field(descriptor,type,offset,label) {return true}
    }
    return false
}

// The rows of the fields of the component, of a provider that draws them under its own.
inspector_fields :: proc(c:Inspector_Context) {
    if c.session==nil || c.table==nil || len(c.entities)==0 {return}
    inspected:=inspect_component(c.session,c.world,c.table.type,c.entities)
    inspected.width=c.width
    if inspected.schema!=nil {fields_rows(&inspected,inspected.of,0,0,"")}
}

// The row of a reference to an entity at an offset of the component, under a label of the provider's.
inspector_entity_row :: proc(c:Inspector_Context,label:string,offset:int) {
    if c.session==nil || c.table==nil || len(c.entities)==0 {return}
    inspected:=inspect_component(c.session,c.world,c.table.type,c.entities)
    inspected.width=c.width
    if inspected.value==nil || offset+size_of(core.Entity)>inspected.size {return}
    entity_row(&inspected,label,offset,base.hash_combine(u64(inspected.index)<<32|u64(offset),0x656e74697479)|1)
}

// The row of a text of count bytes at an offset of the component, under a label of the provider's.
inspector_text_row :: proc(c:Inspector_Context,label:string,offset,count:int) {
    if c.session==nil || c.table==nil || len(c.entities)==0 {return}
    inspected:=inspect_component(c.session,c.world,c.table.type,c.entities)
    inspected.width=c.width
    if inspected.value==nil || offset+count>inspected.size {return}
    text_row(&inspected,label,uintptr(offset),count,base.hash_combine(u64(inspected.index)<<32|u64(offset),0x74657874)|1)
}
