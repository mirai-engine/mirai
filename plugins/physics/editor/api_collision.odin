package physics_editor

import "mirai:editor"
import "mirai:core"
import "mirai:editor/api"
import phys "plugins:physics/runtime"

Physics_Collision_Inspect_Result_Presets :: struct {
    name:string,
    sensor:bool,
    belongs,collides:[]string `mirai:"label=At most 32."`,
}
Physics_Collision_Inspect_Result_Pushes :: struct {
    a,b:string,
    force:f64 `mirai:"label=Above 0. The most they push with"`,
}
Physics_Collision_Inspect_Result_Undeclared :: struct {
    field:string `mirai:"label=presets or pushes"`,
    index,value:int `mirai:"min=0"`,
}
Physics_Collision_Inspect_Result :: struct {
    categories:[]string `mirai:"label=Declared in code; names.create declares one"`,
    presets:[]Physics_Collision_Inspect_Result_Presets `mirai:"label=What colliders can use, declared in code; Collision_Settings, written with settings.set, says by name what each is"`,
    pushes:[]Physics_Collision_Inspect_Result_Pushes `mirai:"label=Pairs of categories whose dynamic bodies yield to each other"`,
    undeclared:[]Physics_Collision_Inspect_Result_Undeclared `mirai:"label=Entries of Collision_Settings for values no code declares"`,
}

@(private)
api_collision_register :: proc(s:^editor.Session) {
    editor.api_method_register(s,{name="physics.collision.inspect",summary="The collision categories and presets the code declares, the pushes between categories and the entries of Collision_Settings no code declares. Read the names here before editing collision: scene.write gives a Collider its preset by name, or with preset Custom its sensor and the lists of names belongs and collides, and a Query_Filter the list hits.",result=type_info_of(Physics_Collision_Inspect_Result),flags={.Read_Only},run=api_collision_settings_list})
}

@(private)
api_collision_settings :: proc(call:^api.Call,w:core.World_Ref) -> (settings:^phys.Collision_Settings,ok:bool) {
    settings=core.world_storage_of(w,phys.Collision_Settings)
    if !phys.collision_settings_valid(settings) {
        api.call_failf(call,api.SERVER_ERROR,"Collision_Settings is invalid: %s",COLLISION_SETTINGS_RULE)
        return
    }
    return settings,true
}

@(private)
api_collision_name :: proc(info:^core.World_Info,type:typeid,value:i64) -> string {
    return phys.collision_name(info,type,value)
}

@(private)
api_collision_names :: proc(call:^api.Call,info:^core.World_Info,value:phys.Collision_Layers) -> []string {
    names:=make([dynamic]string,call.allocator)
    if value==phys.COLLISION_LAYERS_ALL {
        append(&names,"*")
        return names[:]
    }
    for index in 0..<phys.COLLISION_CATEGORY_CAPACITY {
        if value&(phys.Collision_Layers(1)<<uint(index))!=0 {append(&names,api_collision_name(info,phys.Collision_Category,i64(index)))}
    }
    return names[:]
}

@(private)
api_collision_settings_list :: proc(s:^editor.Session,call:^api.Call) {
    w:=editor.shown_world(s)
    settings,valid:=api_collision_settings(call,w)
    if !valid {return}
    info:=w.info
    r:=api.call_result(call,Physics_Collision_Inspect_Result)
    categories:=collision_categories(info)
    r.categories=make([]string,len(categories),call.allocator)
    for entry,i in categories {r.categories[i]=entry.name}
    presets:=make([dynamic]Physics_Collision_Inspect_Result_Presets,call.allocator)
    for entry in core.names_of(info,phys.Collision_Preset) {
        if phys.Collision_Preset(entry.value)==phys.PRESET_CUSTOM {continue}
        preset:=phys.collision_preset_setting(settings,phys.Collision_Preset(entry.value))
        append(&presets,Physics_Collision_Inspect_Result_Presets{entry.name,preset.sensor,api_collision_names(call,info,preset.belongs),api_collision_names(call,info,preset.collides)})
    }
    pushes:=make([dynamic]Physics_Collision_Inspect_Result_Pushes,call.allocator)
    for push in settings.pushes {
        if push.force!=0 {append(&pushes,Physics_Collision_Inspect_Result_Pushes{api_collision_name(info,phys.Collision_Category,i64(push.a)),api_collision_name(info,phys.Collision_Category,i64(push.b)),f64(push.force)})}
    }
    undeclared:=make([dynamic]Physics_Collision_Inspect_Result_Undeclared,call.allocator)
    at:=0
    for field,index,value in phys.collision_settings_undeclared(settings,info,&at) {
        append(&undeclared,Physics_Collision_Inspect_Result_Undeclared{field,int(index),int(value)})
    }
    r.presets,r.pushes,r.undeclared=presets[:],pushes[:],undeclared[:]
}
