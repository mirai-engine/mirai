package physics_editor

import "mirai:editor"
import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:reflect"
import "core:strings"
import "mirai:core"
import "mirai:editor/api"
import phys "plugins:physics/runtime"
import "mirai:std/base"
import "mirai:std/serial"

@(private)
Api_Collision_Request :: struct {
    entity:editor.Api_Entity_Text,
    component:[64]u8,
    prefix:[128]u8,
    preset:string,
    sensor,sensors:bool,
    belongs,collides,hits:[phys.COLLISION_CATEGORY_CAPACITY]string,
    belongs_count,collides_count,hits_count:int,
    has_prefix,has_sensor,has_belongs,has_collides,has_hits,has_sensors:bool,
}

@(private) Api_Collision_Kind :: enum u8 {Collider,Query}

// Where the collision of a component is: the preset, sensor, belongs, collides and group of a collider,
// or a Query_Filter.
@(private)
Api_Collision_Target :: struct {
    table:^core.Table_Info,
    entity:core.Entity,
    kind:Api_Collision_Kind,
    preset,sensor,belongs,collides,group:int, // offsets of a collider; group -1 when it has none
    query:int,                                // offset of a Query_Filter
    prefix:string,
}

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

Physics_Collision_Get_Result :: struct {
    id:base.Entity_Id,
    playing:bool,
    component,prefix:string,
    preset:string `mirai:"optional,label=Of a Collider"`,
    sensor:bool `mirai:"optional,label=Of a Collider, as belongs and collides: from its preset, or its own when custom"`,
    belongs,collides:[]string `mirai:"optional,label=At most 32."`,
    pushes:serial.Json `mirai:"optional,label=Of a Collider: the categories its dynamic body yields to, with the force"`,
    group:base.Entity_Id `mirai:"optional,label=Of a Collider"`,
    hits:[]string `mirai:"optional,label=At most 32. Of a Query_Filter: the categories it hits"`,
    sensors:bool `mirai:"optional,label=Of a Query_Filter: whether it reports sensors"`,
}

Physics_Collision_Get_Params :: struct {
    entity:editor.Api_Entity_Text `mirai:"text,entity"`,
    component:[64]u8 `mirai:"text,optional,label=The component that holds the collision; omitted: the only one of the entity"`,
    prefix:[128]u8 `mirai:"text,optional,label=Dotted path of the field of the component that holds a nested collision"`,
}

Physics_Collision_Set_Params :: struct {
    target:Physics_Collision_Get_Params `mirai:"inline"`,
    preset:string `mirai:"optional,label=Of a Collider; 'custom' keeps what it is as its own"`,
    sensor:bool `mirai:"optional,label=Of a Collider, as belongs and collides: of its own, which make it custom from what it is"`,
    belongs,collides:[]string `mirai:"optional,label=At most 32."`,
    hits:[]string `mirai:"optional,label=At most 32. Of a Query_Filter: the categories it hits; '*' is all"`,
    sensors:bool `mirai:"optional,label=Of a Query_Filter: whether it reports sensors"`,
}

@(private)
api_collision_register :: proc(s:^editor.Session) {
    editor.api_method_register(s,{name="physics.collision.inspect",summary="The collision categories and presets the code declares, the pushes between categories and the entries of Collision_Settings no code declares. Read the names here before editing collision.",result=type_info_of(Physics_Collision_Inspect_Result),flags={.Read_Only},run=api_collision_settings_list})
    editor.api_method_register(s,{params=type_info_of(Physics_Collision_Get_Params),result=type_info_of(Physics_Collision_Get_Result),name="physics.collision.get",summary="Reads by name the collision of a component of the shown world: what a Collider is and collides with, or what a Query_Filter hits. Without component, that of the only collision component of the entity.",flags={.Read_Only},run=api_collision_get})
    editor.api_method_register(s,{params=type_info_of(Physics_Collision_Set_Params),result=type_info_of(editor.Api_Edit_Result),name="physics.collision.set",summary="Edits by name the collision of a Collider or a Query_Filter of a component, or of the only collision component of the entity without one; other fields are kept. One step of undo.",run=api_collision_set})
}

@(private)
api_collision_request :: proc(call:^api.Call,target:Physics_Collision_Get_Params,set:^Physics_Collision_Set_Params) -> (request:Api_Collision_Request,ok:bool) {
    request={entity=target.entity,component=target.component,prefix=target.prefix,has_prefix=api.call_given(call,"prefix")}
    if api.call_given(call,"component") && target.component[0]==0 {
        api.call_fail(call,api.INVALID_PARAMS,"component must name a component, or be left out for the only collision component of the entity")
        return
    }
    if set==nil {return request,true}
    names :: proc(call:^api.Call,key:string,given:[]string,into:[]string) -> (count:int,ok:bool) {
        if len(given)>len(into) {api.call_failf(call,api.INVALID_PARAMS,"%s accepts at most %d collision category names",key,len(into));return}
        for name,i in given {
            if len(name)==0 || len(name)>31 {api.call_failf(call,api.INVALID_PARAMS,"%s[%d] must be a collision category name of 1 to 31 bytes",key,i);return}
            into[i]=name
        }
        return len(given),true
    }
    if len(set.preset)>31 {api.call_fail(call,api.INVALID_PARAMS,"preset must be a name of 1 to 31 bytes");return}
    request.preset=set.preset
    request.sensor,request.has_sensor=set.sensor,api.call_given(call,"sensor")
    request.sensors,request.has_sensors=set.sensors,api.call_given(call,"sensors")
    request.has_belongs,request.has_collides,request.has_hits=api.call_given(call,"belongs"),api.call_given(call,"collides"),api.call_given(call,"hits")
    request.belongs_count=names(call,"belongs",set.belongs,request.belongs[:]) or_return
    request.collides_count=names(call,"collides",set.collides,request.collides[:]) or_return
    request.hits_count=names(call,"hits",set.hits,request.hits[:]) or_return
    own:=request.has_sensor || request.has_belongs || request.has_collides
    collider:=request.preset!="" || own
    query:=request.has_hits || request.has_sensors
    switch {
    case collider && query: api.call_fail(call,api.INVALID_PARAMS,"give a collider preset, sensor, belongs or collides, or a query hits or sensors, not both");return
    case !collider && !query: api.call_fail(call,api.INVALID_PARAMS,"give preset, or sensor, belongs or collides, for a Collider; hits or sensors for a Query_Filter");return
    case request.preset!="" && own: api.call_fail(call,api.INVALID_PARAMS,"preset replaces sensor, belongs and collides: give one or the others");return
    }
    return request,true
}

@(private)
api_collision_member :: proc(info:^runtime.Type_Info,name:string,origin:int,set:bool) -> (type:^runtime.Type_Info,offset:int,ok:bool) {
    record,is_struct:=runtime.type_info_base(info).variant.(runtime.Type_Info_Struct)
    if !is_struct {return}
    for field in 0..<int(record.field_count) {
        if record.names[field]!=name {continue}
        tag:=reflect.Struct_Tag(record.tags[field])
        if tagged,_:=serial.field_tag(string(tag));.Hidden in tagged.flags {return}
        if tagged,_:=serial.field_tag(string(tag));.Transient in tagged.flags {return}
        if tagged,_:=serial.field_tag(string(tag));set && .Read_Only in tagged.flags {return}
        return record.types[field],origin+int(record.offsets[field]),true
    }
    return
}

// The collision fields of a struct: those of a collider, or the struct is a Query_Filter.
@(private)
api_collision_fields :: proc(info:^runtime.Type_Info,origin:int,set:bool,target:^Api_Collision_Target) -> bool {
    if info.id==phys.Query_Filter {
        target.kind,target.query=.Query,origin
        return true
    }
    pt,po,has_preset:=api_collision_member(info,"preset",origin,set)
    st,so,has_sensor:=api_collision_member(info,"sensor",origin,set)
    bt,bo,has_belongs:=api_collision_member(info,"belongs",origin,set)
    ct,co,has_collides:=api_collision_member(info,"collides",origin,set)
    if !has_preset || !has_sensor || !has_belongs || !has_collides {return false}
    if pt.id!=phys.Collision_Preset || st.id!=bool || bt.id!=phys.Collision_Layers || ct.id!=phys.Collision_Layers {return false}
    target.kind,target.preset,target.sensor,target.belongs,target.collides,target.group=.Collider,po,so,bo,co,-1
    if gt,go,has_group:=api_collision_member(info,"group",origin,false);has_group && gt.id==core.Entity {target.group=go}
    return true
}

// Whether a component holds a collision: at its root or in its filter field.
@(private)
api_collision_holds :: proc(info:^runtime.Type_Info,set:bool) -> bool {
    probe:Api_Collision_Target
    if api_collision_fields(info,0,set,&probe) {return true}
    type,origin,found:=api_collision_member(info,"filter",0,set)
    return found && api_collision_fields(type,origin,set,&probe)
}

// Names in the request the only collision component of its entity; several, or none, fail listing them.
@(private)
api_collision_component :: proc(s:^editor.Session,call:^api.Call,w:core.World_Ref,request:^Api_Collision_Request,set:bool) -> bool {
    entity:=editor.api_call_entity(call,w,request.entity[:]) or_return
    found:=make([dynamic]string,0,4,call.allocator)
    for &table in w.info.tables {
        if table.place!=.World || !editor.inspector_listed(s,&table) || core.raw_find(core.world_table_at(w,&table),table.info,entity)==nil {continue}
        if api_collision_holds(table.info,set) {append(&found,table.name)}
    }
    switch len(found) {
    case 0:
        api.call_failf(call,api.INVALID_PARAMS,"entity %q has no collision component: give it a Collider with scene.write",base.text_get(request.entity[:]))
        return false
    case 1:
        base.text_set(request.component[:],found[0])
        return true
    }
    api.call_failf(call,api.INVALID_PARAMS,"entity %q has %d collision components (%s): pass component with one of them",base.text_get(request.entity[:]),len(found),strings.join(found[:],", ",call.allocator))
    return false
}

@(private)
api_collision_target :: proc(s:^editor.Session,call:^api.Call,w:core.World_Ref,request:^Api_Collision_Request,set:bool) -> (target:Api_Collision_Target,ok:bool) {
    if base.text_get(request.component[:])=="" && !api_collision_component(s,call,w,request,set) {return}
    name:=base.text_get(request.component[:])
    table,problem:=editor.api_component_named(w,name)
    if table==nil {api.call_failf(call,api.INVALID_PARAMS,"component: %s",problem);return}
    if table.place!=.World || !editor.inspector_listed(s,table) {
        api.call_failf(call,api.INVALID_PARAMS,"component %q is not an editable component of the world",name);return
    }
    entity,named:=editor.api_call_entity(call,w,request.entity[:])
    if !named {return}
    if core.raw_find(core.world_table_at(w,table),table.info,entity)==nil {
        api.call_failf(call,api.INVALID_PARAMS,"entity %q has no %s component",base.text_get(request.entity[:]),name);return
    }
    target.table,target.entity=table,entity
    type,origin:=table.info,0
    prefix:=base.text_get(request.prefix[:])
    if !request.has_prefix && !api_collision_fields(type,0,set,&target) {prefix="filter"}
    if prefix!="" {
        start:=0
        for at in 0..=len(prefix) {
            if at<len(prefix) && prefix[at]!='.' {continue}
            next,offset,found:=api_collision_member(type,prefix[start:at],origin,set)
            if !found {api.call_failf(call,api.INVALID_PARAMS,"%s.%s is not a public collision field",name,prefix);return}
            type,origin=next,offset
            start=at+1
        }
    }
    if (prefix!="" || request.has_prefix) && !api_collision_fields(type,origin,set,&target) {
        api.call_failf(call,api.INVALID_PARAMS,"%s%s is neither a collider collision (preset, sensor, belongs, collides) nor a Query_Filter",name,prefix!=""?strings.concatenate({".",prefix},call.allocator):"");return
    }
    target.prefix=prefix
    return target,true
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

// The value the code declares with a name: a category of Collision_Layers or a preset.
@(private)
api_collision_value :: proc(info:^core.World_Info,type:typeid,name:string) -> (value:i64,found:bool) {
    value,found=core.name_value(info,type,name)
    if found && type==phys.Collision_Category && (value<0 || value>=phys.COLLISION_CATEGORY_CAPACITY) {found=false}
    return
}

API_COLLISION_DISCOVER :: "physics.collision.inspect lists those the code declares, names.create declares one"

// The categories of names, '*' for all of them.
@(private)
api_collision_layers :: proc(call:^api.Call,info:^core.World_Info,key:string,names:[]string) -> (layers:phys.Collision_Layers,ok:bool) {
    for name,index in names {
        if name=="*" {layers=phys.COLLISION_LAYERS_ALL;continue}
        chosen,found:=api_collision_value(info,phys.Collision_Category,name)
        if !found {api.call_failf(call,api.INVALID_PARAMS,"%s[%d]: unknown collision category %q; %s",key,index,name,API_COLLISION_DISCOVER);return}
        layers|=phys.collision_layers(phys.Collision_Category(chosen))
    }
    return layers,true
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

// The collision of the collider fields at the target.
@(private)
api_collision_collider :: proc(target:Api_Collision_Target,value:uintptr) -> (collider:phys.Collider) {
    collider.preset=(cast(^phys.Collision_Preset)(value+uintptr(target.preset)))^
    collider.sensor=(cast(^bool)(value+uintptr(target.sensor)))^
    collider.belongs=(cast(^phys.Collision_Layers)(value+uintptr(target.belongs)))^
    collider.collides=(cast(^phys.Collision_Layers)(value+uintptr(target.collides)))^
    return
}

@(private)
api_collision_get :: proc(s:^editor.Session,call:^api.Call) {
    request,read:=api_collision_request(call,api.call_params(call,Physics_Collision_Get_Params)^,nil)
    if !read {return}
    w:=editor.shown_world(s)
    settings,valid:=api_collision_settings(call,w)
    if !valid {return}
    target,found:=api_collision_target(s,call,w,&request,false)
    if !found {return}
    info:=w.info
    value:=uintptr(core.raw_find(core.world_table_at(w,target.table),target.table.info,target.entity))
    r:=api.call_result(call,Physics_Collision_Get_Result)
    r^={id=editor.api_entity_id(w,target.entity),playing=editor.playing(s),component=strings.clone(base.text_get(request.component[:]),call.allocator),prefix=strings.clone(target.prefix,call.allocator)}
    switch target.kind {
    case .Collider:
        collider:=api_collision_collider(target,value)
        of:=phys.collision_of_collider(settings,collider)
        r.preset,r.sensor=api_collision_name(info,phys.Collision_Preset,i64(collider.preset)),of.sensor
        r.belongs,r.collides=api_collision_names(call,info,of.belongs),api_collision_names(call,info,of.collides)
        pushes:=strings.builder_make(call.allocator)
        strings.write_byte(&pushes,'{')
        for entry in collision_categories(info) {
            force:f32
            for index in 0..<phys.COLLISION_CATEGORY_CAPACITY {
                if of.belongs&(phys.Collision_Layers(1)<<uint(index))==0 {continue}
                force=max(force,phys.collision_push(settings,phys.Collision_Category(index),phys.Collision_Category(entry.value)))
            }
            if force!=0 {fmt.sbprintf(&pushes,"%s%q:%v",strings.builder_len(pushes)>1?",":"",entry.name,force)}
        }
        strings.write_byte(&pushes,'}')
        r.pushes=serial.Json(strings.to_string(pushes))
        if target.group>=0 {r.group=editor.api_entity_id(w,(cast(^core.Entity)(value+uintptr(target.group)))^)}
    case .Query:
        filter:=(cast(^phys.Query_Filter)(value+uintptr(target.query)))^
        hits,sensors:=phys.query_layers(filter)
        r.hits,r.sensors=api_collision_names(call,info,hits),sensors
    }
}

// What the request makes of the value at the target, with precise errors for names the code does not declare.
@(private)
api_collision_apply :: proc(call:^api.Call,info:^core.World_Info,settings:^phys.Collision_Settings,request:^Api_Collision_Request,target:Api_Collision_Target,value:uintptr) -> bool {
    switch target.kind {
    case .Collider:
        if request.has_hits || request.has_sensors {api.call_fail(call,api.INVALID_PARAMS,"this collision is a Collider's: give preset, or sensor, belongs or collides");return false}
        preset:=cast(^phys.Collision_Preset)(value+uintptr(target.preset))
        sensor:=cast(^bool)(value+uintptr(target.sensor))
        belongs:=cast(^phys.Collision_Layers)(value+uintptr(target.belongs))
        collides:=cast(^phys.Collision_Layers)(value+uintptr(target.collides))
        of:=phys.collision_of_collider(settings,api_collision_collider(target,value))
        if request.preset!="" {
            chosen,found:=api_collision_value(info,phys.Collision_Preset,request.preset)
            if !found {api.call_failf(call,api.INVALID_PARAMS,"unknown collision preset %q; %s",request.preset,API_COLLISION_DISCOVER);return false}
            preset^=phys.Collision_Preset(chosen)
            // Custom keeps what it was as its own.
            if preset^==phys.PRESET_CUSTOM {sensor^,belongs^,collides^=of.sensor,of.belongs,of.collides}
            return true
        }
        preset^,sensor^,belongs^,collides^=phys.PRESET_CUSTOM,of.sensor,of.belongs,of.collides
        if request.has_sensor {sensor^=request.sensor}
        if request.has_belongs {belongs^=api_collision_layers(call,info,"belongs",request.belongs[:request.belongs_count]) or_return}
        if request.has_collides {collides^=api_collision_layers(call,info,"collides",request.collides[:request.collides_count]) or_return}
    case .Query:
        if request.preset!="" || request.has_sensor || request.has_belongs || request.has_collides {api.call_fail(call,api.INVALID_PARAMS,"this collision is a Query_Filter: give hits or sensors");return false}
        filter:=cast(^phys.Query_Filter)(value+uintptr(target.query))
        hits,sensors:=phys.query_layers(filter^)
        if request.has_hits {hits=api_collision_layers(call,info,"hits",request.hits[:request.hits_count]) or_return}
        if request.has_sensors {sensors=request.sensors}
        next:=phys.query_hits(hits,sensors)
        filter.filter,filter.objects,filter.overlaps=next.filter,0,next.overlaps
    }
    return true
}

@(private)
api_collision_set :: proc(s:^editor.Session,call:^api.Call) {
    params:=api.call_params(call,Physics_Collision_Set_Params)
    request,read:=api_collision_request(call,params.target,params)
    if !read {return}
    w:=editor.edited_world(s)
    settings,valid:=api_collision_settings(call,w)
    if !valid {return}
    target,found:=api_collision_target(s,call,w,&request,true)
    if !found {return}
    size:=target.table.info.size
    scratch:=make([]u8,size,call.allocator)
    mem.copy(raw_data(scratch),core.raw_find(core.world_table_at(w,target.table),target.table.info,target.entity),size)
    if !api_collision_apply(call,w.info,settings,&request,target,uintptr(raw_data(scratch))) {return}
    if !editor.api_edit_begin(s,call,"Collision") {return}
    target,found=api_collision_target(s,call,editor.edited_world(s),&request,true)
    if !found {editor.api_edit_end(s,call,false);return}
    changed:=editor.field_write(s,target.table,{target.entity},0,scratch)
    if !editor.api_edit_end(s,call,changed) {return}
    api.call_result(call,editor.Api_Edit_Result).id=editor.api_entity_id(editor.edited_world(s),target.entity)
}
