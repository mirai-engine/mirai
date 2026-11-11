package author

import "base:runtime"
import "core:mem"
import "core:reflect"
import "core:strings"
import "mirai:core"
import "mirai:std/base"
import mm "mirai:std/math"

// The recipes the plugins of a project add to the presets: the cards of their
// editor packages, which the editor reads from the library of the project
// (editor.plugin_recipes). make gives an entity of a world the components of
// the recipe at index.
Plugin_Recipes :: struct {
    labels:[]string,
    scales:[][3]f32, // of the entity each makes; zero: one
    make:proc(user:rawptr,index:int,w:core.World_Ref,e:core.Entity),
    user:rawptr,
}

// How a command finds the recipes of the plugins of a library.
Plugin_Recipes_Proc :: proc(info:^core.World_Info,allocator:runtime.Allocator) -> Plugin_Recipes

// The recipe a name means, as base.name_find takes it: a preset by its
// place, or past them a card of a plugin by its label, in the order of labels.
recipe_named :: proc(name:string,labels:[]string) -> (index:int,found:bool) {
    if preset,_:=base.name_find(name,reflect.enum_field_names(Preset));preset>=0 {return preset,true}
    at,_:=base.name_find(name,labels)
    return len(Preset)+at,at>=0
}

// What is wrong with a name recipe_named does not take, with the nearest ones.
recipe_problem :: proc(name:string,labels:[]string) -> string {
    names:=make([dynamic]string,context.temp_allocator)
    for each in reflect.enum_field_names(Preset) {append(&names,strings.to_lower(each,context.temp_allocator))}
    append(&names,..labels)
    return base.name_problem(name,"a preset or the card of a plugin",names[:])
}

// The offsets of the Entity fields of a type.
entity_offsets :: proc(type:^runtime.Type_Info,allocator:=context.temp_allocator) -> []uintptr {
    out:=make([dynamic]uintptr,allocator)
    walk :: proc(info:^runtime.Type_Info,at:uintptr,out:^[dynamic]uintptr) {
        if info.id==core.Entity {append(out,at);return}
        #partial switch v in runtime.type_info_base(info).variant {
        case runtime.Type_Info_Struct:
            for i in 0..<int(v.field_count) {walk(v.types[i],at+v.offsets[i],out)}
        case runtime.Type_Info_Array:
            for i in 0..<v.count {walk(v.elem,at+uintptr(i*v.elem_size),out)}
        }
    }
    walk(type,0,&out)
    return out[:]
}

// A component of an entity a recipe made, as a document shows its value: its
// Entity fields name none.
Part :: struct {
    t:^core.Table_Info,
    value:[]u8,
}

// The components an entity has that a document writes by name, in the order
// of the tables of its world.
entity_parts :: proc(w:core.World_Ref,e:core.Entity,allocator:runtime.Allocator) -> []Part {
    parts:=make([dynamic]Part,allocator)
    for &t in w.info.tables {
        if t.place!=.World || !component_listed(&t) {continue}
        value:=core.raw_find(core.world_table_at(w,&t),t.info,e)
        if value==nil {continue}
        bytes:=make([]u8,max(t.info.size,1),allocator)
        if t.info.size>0 {mem.copy(raw_data(bytes),value,t.info.size)}
        for offset in entity_offsets(t.info) {(cast(^u64)&bytes[offset])^=0}
        append(&parts,Part{&t,bytes[:t.info.size]})
    }
    return parts[:]
}

// A world of a game that holds nothing, to run a recipe on with no editor.
Scratch_World :: struct {
    w:core.World_Ref,
    allocator:runtime.Allocator,
}

scratch_world_make :: proc(info:^core.World_Info,allocator:=context.allocator) -> (scratch:Scratch_World,ok:bool) {
    if info==nil || info.sizes[.World]<=0 {return}
    data,error:=mem.alloc(info.sizes[.World],max(info.aligns[.World],1),allocator)
    if error!=nil {return}
    if !core.world_init(info,.World,data,allocator) {
        core.world_destroy(info,.World,data)
        mem.free(data,allocator)
        return
    }
    return {core.world_ref(data,info),allocator},true
}

scratch_world_free :: proc(scratch:^Scratch_World) {
    if scratch.w.data==nil {return}
    core.world_destroy(scratch.w.info,.World,scratch.w.data)
    mem.free(scratch.w.data,scratch.allocator)
    scratch^={}
}

// The components a recipe gives the entity it makes: a preset by its place,
// or past them one of the plugins. The entity is made in the scratch world and
// goes at once.
recipe_parts :: proc(scratch:^Scratch_World,index:int,plugins:Plugin_Recipes,allocator:runtime.Allocator) -> []Part {
    w:=scratch.w
    e:=core.create(core.world_entities(w))
    if t:=core.world_table_of(w,core.Transform);t!=nil {core.add(t,e,core.TRANSFORM_IDENTITY)}
    core.world_settle(w)
    if index<len(Preset) {
        preset_components(w,e,Preset(index))
    } else if at:=index-len(Preset);at<len(plugins.labels) && plugins.make!=nil {
        plugins.make(plugins.user,at,w,e)
    }
    core.world_settle(w)
    parts:=entity_parts(w,e,allocator)
    core.destroy(core.world_entities(w),e)
    core.world_settle(w)
    return parts
}

// What a recipe gives the entity it makes besides components: the rotation
// of a preset, the scale of a card.
recipe_place :: proc(index:int,plugins:Plugin_Recipes) -> (rotation:mm.Quat,scale:[3]f32) {
    rotation,scale=1,{1,1,1}
    if index<0 {return}
    if index<len(Preset) {rotation=preset_rotation(Preset(index))}
    else if at:=index-len(Preset);at<len(plugins.scales) && plugins.scales[at]!={} {scale=plugins.scales[at]}
    return
}
