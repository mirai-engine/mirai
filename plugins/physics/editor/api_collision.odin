package physics_editor

import "mirai:editor"
import "base:runtime"
import "core:mem"
import "core:reflect"
import "core:strings"
import "mirai:core"
import "mirai:editor/api"
import phys "plugins:physics/runtime"
import "mirai:std/base"
import "mirai:std/serial"

@(private) API_COLLISION_LIST :: `"type":"array","maxItems":32,"items":{"type":"string","minLength":1,"maxLength":31}`
@(private) API_COLLISION_NAMES :: `{`+API_COLLISION_LIST+`}`
@(private) API_COLLISION_TARGET :: `"entity":{`+api.ENTITY_SCHEMA+`},"component":{"type":"string","minLength":1,"maxLength":63,"description":"The component that holds the collision; omitted: the only one of the entity"},"prefix":{"type":"string","maxLength":127,"description":"Dotted path of the field of the component that holds a nested collision"}`
@(private) API_COLLISION_GET_SCHEMA :: `{"type":"object","properties":{`+API_COLLISION_TARGET+`},"required":["entity"],"additionalProperties":false}`
@(private) API_COLLISION_SET_SCHEMA :: `{"type":"object","properties":{`+API_COLLISION_TARGET+`,"preset":{"type":"string","minLength":1,"maxLength":31,"description":"Of a Collider; 'custom' keeps what it is as its own"},"sensor":{"type":"boolean","description":"Of a Collider, as belongs and collides: of its own, which make it custom from what it is"},"belongs":`+API_COLLISION_NAMES+`,"collides":`+API_COLLISION_NAMES+`,"hits":{`+API_COLLISION_LIST+`,"description":"Of a Query_Filter: the categories it hits; '*' is all"},"sensors":{"type":"boolean","description":"Of a Query_Filter: whether it reports sensors"}},"required":["entity"],"additionalProperties":false}`
@(private) API_COLLISION_SETTINGS_SCHEMA :: `{"type":"object","properties":{"categories":{"type":"array","items":{"type":"string"},"description":"Declared in code; names.create declares one"},"presets":{"type":"array","items":{"type":"object","properties":{"name":{"type":"string"},"sensor":{"type":"boolean"},"belongs":`+API_COLLISION_NAMES+`,"collides":`+API_COLLISION_NAMES+`},"required":["name","sensor","belongs","collides"]},"description":"What colliders can use, declared in code; Collision_Settings, written with settings.set, says by name what each is"},"pushes":{"type":"array","items":{"type":"object","properties":{"a":{"type":"string"},"b":{"type":"string"},"force":{"type":"number","exclusiveMinimum":0,"x-unit":"N","description":"The most they push with"}},"required":["a","b","force"]},"description":"Pairs of categories whose dynamic bodies yield to each other"},"undeclared":{"type":"array","items":{"type":"object","properties":{"field":{"enum":["presets","pushes"]},"index":{"type":"integer","minimum":0},"value":{"type":"integer","minimum":0}},"required":["field","index","value"]},"description":"Entries of Collision_Settings for values no code declares"}},"required":["categories","presets","pushes","undeclared"],"additionalProperties":false}`
@(private) API_COLLISION_PUSHES :: `{"type":"object","additionalProperties":{"type":"number","exclusiveMinimum":0,"x-unit":"N"},"description":"Of a Collider: the categories its dynamic body yields to, with the force"}`
@(private) API_COLLISION_RESULT_SCHEMA :: `{"type":"object","properties":{"id":{"type":"string"},"playing":{"type":"boolean"},"component":{"type":"string"},"prefix":{"type":"string"},"preset":{"type":"string","description":"Of a Collider"},"sensor":{"type":"boolean","description":"Of a Collider, as belongs and collides: from its preset, or its own when custom"},"belongs":`+API_COLLISION_NAMES+`,"collides":`+API_COLLISION_NAMES+`,"pushes":`+API_COLLISION_PUSHES+`,"group":{"type":["string","null"],"description":"Of a Collider"},"hits":{`+API_COLLISION_LIST+`,"description":"Of a Query_Filter: the categories it hits"},"sensors":{"type":"boolean","description":"Of a Query_Filter: whether it reports sensors"}},"required":["id","playing","component","prefix"],"additionalProperties":false}`

@(private)
Api_Collision_Request :: struct {
    id:base.Entity_Id,
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

@(private)
api_collision_register :: proc(s:^editor.Session) {
    editor.api_method_register(s,{name="physics.collision.inspect",summary="The collision categories and presets the code declares, the pushes between categories and the entries of Collision_Settings no code declares. Read the names here before editing collision.",result_schema=API_COLLISION_SETTINGS_SCHEMA,flags={.Read_Only},run=api_collision_settings_list})
    editor.api_method_register(s,{name="physics.collision.get",summary="Reads by name the collision of a component of the shown world: what a Collider is and collides with, or what a Query_Filter hits. Without component, that of the only collision component of the entity.",params_schema=API_COLLISION_GET_SCHEMA,result_schema=API_COLLISION_RESULT_SCHEMA,flags={.Read_Only},run=api_collision_get})
    editor.api_method_register(s,{name="physics.collision.set",summary="Edits by name the collision of a Collider or a Query_Filter of a component, or of the only collision component of the entity without one; other fields are kept. One step of undo.",params_schema=API_COLLISION_SET_SCHEMA,result=editor.Api_Edit_Result,run=api_collision_set})
}

@(private)
api_collision_names_read :: proc(a:^editor.Rpc_Args,key:string,names:[]string) -> (count:int,ok:bool) {
    if !serial.text_accept(&a.r,'[') {return 0,editor.rpc_fail_type(a,"%s must be an array of collision category names",key)}
    for !serial.text_accept(&a.r,']') {
        if count>=len(names) {return 0,editor.rpc_fail(a,"%s accepts at most %d collision category names",key,len(names))}
        if count>0 && !serial.text_accept(&a.r,',') {return 0,editor.rpc_fail_type(a,"%s must be an array of collision category names",key)}
        name,read:=serial.text_string(&a.r)
        if !read || len(name)==0 || len(name)>31 {return 0,editor.rpc_fail(a,"%s[%d] must be a collision category name of 1 to 31 bytes",key,count)}
        names[count]=name
        count+=1
    }
    return count,true
}

@(private)
api_collision_request_read :: proc(call:^api.Call,set:bool) -> (request:Api_Collision_Request,ok:bool) {
    a:editor.Rpc_Args;editor.rpc_init(&a,call,call.raw)
    object:editor.Rpc_Object
    if !editor.rpc_object_begin(&a,"params") {return}
    seen:u16
    for key in editor.rpc_next(&a,&object) {
        at:=0
        switch key {
        case "entity":at=0
        case "component":at=1
        case "prefix":at=2
        case "preset":at=3
        case "sensor":at=4
        case "belongs":at=5
        case "collides":at=6
        case "hits":at=7
        case "sensors":at=8
        case:editor.rpc_fail_type(&a,"unknown parameter %q",key);return
        }
        bit:=u16(1)<<uint(at)
        if seen&bit!=0 {editor.rpc_fail_type(&a,"%s was supplied more than once",key);return}
        seen|=bit
        if !set && at>=3 {editor.rpc_fail_type(&a,"unknown parameter %q",key);return}
        switch key {
        case "entity":
            request.id=editor.rpc_id(&a,key) or_return
        case "component":_ = editor.rpc_text(&a,key,request.component[:63]) or_return
        case "prefix":
            _ = editor.rpc_text(&a,key,request.prefix[:127]) or_return
            request.has_prefix=true
        case "preset":
            value,read:=serial.text_string(&a.r)
            if !read || len(value)==0 || len(value)>31 {editor.rpc_fail(&a,"preset must be a name of 1 to 31 bytes");return}
            request.preset=value
        case "sensor":request.sensor,request.has_sensor=editor.rpc_bool(&a,key) or_return,true
        case "sensors":request.sensors,request.has_sensors=editor.rpc_bool(&a,key) or_return,true
        case "belongs":request.belongs_count,request.has_belongs=api_collision_names_read(&a,key,request.belongs[:]) or_return,true
        case "collides":request.collides_count,request.has_collides=api_collision_names_read(&a,key,request.collides[:]) or_return,true
        case "hits":request.hits_count,request.has_hits=api_collision_names_read(&a,key,request.hits[:]) or_return,true
        }
    }
    if a.failed {return}
    if seen&1==0 || request.id==0 {editor.rpc_fail(&a,"id is required");return}
    if seen&2!=0 && base.text_get(request.component[:])=="" {editor.rpc_fail(&a,"component must name a component, or be left out for the only collision component of the entity");return}
    if set {
        own:=request.has_sensor || request.has_belongs || request.has_collides
        collider:=request.preset!="" || own
        query:=request.has_hits || request.has_sensors
        switch {
        case collider && query: editor.rpc_fail(&a,"give a collider preset, sensor, belongs or collides, or a query hits or sensors, not both");return
        case !collider && !query: editor.rpc_fail(&a,"give preset, or sensor, belongs or collides, for a Collider; hits or sensors for a Query_Filter");return
        case request.preset!="" && own: editor.rpc_fail(&a,"preset replaces sensor, belongs and collides: give one or the others");return
        }
    }
    serial.text_space(&a.r)
    if a.r.offset!=len(call.raw) {editor.rpc_fail(&a,"unexpected text after params");return}
    return request,true
}

@(private)
api_collision_member :: proc(info:^runtime.Type_Info,name:string,origin:int,set:bool) -> (type:^runtime.Type_Info,offset:int,ok:bool) {
    record,is_struct:=runtime.type_info_base(info).variant.(runtime.Type_Info_Struct)
    if !is_struct {return}
    for field in 0..<int(record.field_count) {
        if record.names[field]!=name {continue}
        tag:=reflect.Struct_Tag(record.tags[field])
        if _,hidden:=core.field_option(tag,"hidden");hidden {return}
        if _,transient:=core.field_option(tag,"transient");transient {return}
        if _,readonly:=core.field_option(tag,"readonly");set && readonly {return}
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
    entity:=editor.api_entity(w,request.id)
    if entity==core.NONE {api.call_failf(call,api.INVALID_PARAMS,"id 0x%016x is not an entity of the shown world",u64(request.id));return false}
    found:=make([dynamic]string,0,4,call.allocator)
    for &table in w.info.tables {
        if table.place!=.World || !editor.inspector_listed(s,&table) || core.raw_find(core.world_table_at(w,&table),table.info,entity)==nil {continue}
        if api_collision_holds(table.info,set) {append(&found,table.name)}
    }
    switch len(found) {
    case 0:
        api.call_failf(call,api.INVALID_PARAMS,"entity 0x%016x has no collision component: give it a Collider with scene.set",u64(request.id))
        return false
    case 1:
        base.text_set(request.component[:],found[0])
        return true
    }
    api.call_failf(call,api.INVALID_PARAMS,"entity 0x%016x has %d collision components (%s): pass component with one of them",u64(request.id),len(found),strings.join(found[:],", ",call.allocator))
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
    entity:=editor.api_entity(w,request.id)
    if entity==core.NONE {api.call_failf(call,api.INVALID_PARAMS,"id 0x%016x is not an entity of the shown world",u64(request.id));return}
    if core.raw_find(core.world_table_at(w,table),table.info,entity)==nil {
        api.call_failf(call,api.INVALID_PARAMS,"entity 0x%016x has no %s component",u64(request.id),name);return
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
api_collision_names_write :: proc(out:^serial.Writer,info:^core.World_Info,value:phys.Collision_Layers) {
    if value==phys.COLLISION_LAYERS_ALL {serial.text_write_raw(out,`["*"]`);return}
    serial.write_u8(out,'[')
    first:=true
    for index in 0..<phys.COLLISION_CATEGORY_CAPACITY {
        if value&(phys.Collision_Layers(1)<<uint(index))==0 {continue}
        if !first {serial.write_u8(out,',')};first=false
        serial.text_write_string(out,api_collision_name(info,phys.Collision_Category,i64(index)))
    }
    serial.write_u8(out,']')
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
    out:=call.out
    serial.text_write_raw(out,`{"categories":[`)
    for entry,i in collision_categories(info) {
        if i>0 {serial.write_u8(out,',')}
        serial.text_write_string(out,entry.name)
    }
    serial.text_write_raw(out,"]")
    api.write_key(out,"presets");serial.write_u8(out,'[')
    first:=true
    for entry in core.names_of(info,phys.Collision_Preset) {
        if phys.Collision_Preset(entry.value)==phys.PRESET_CUSTOM {continue}
        if !first {serial.write_u8(out,',')};first=false
        preset:=phys.collision_preset_setting(settings,phys.Collision_Preset(entry.value))
        serial.write_u8(out,'{');api.write_text(out,"name",entry.name,true);api.write_bool(out,"sensor",preset.sensor)
        api.write_key(out,"belongs");api_collision_names_write(out,info,preset.belongs)
        api.write_key(out,"collides");api_collision_names_write(out,info,preset.collides)
        serial.write_u8(out,'}')
    }
    serial.text_write_raw(out,"]")
    api.write_key(out,"pushes");serial.write_u8(out,'[')
    first=true
    for push in settings.pushes {
        if push.force==0 {continue}
        if !first {serial.write_u8(out,',')};first=false
        serial.write_u8(out,'{');api.write_text(out,"a",api_collision_name(info,phys.Collision_Category,i64(push.a)),true);api.write_text(out,"b",api_collision_name(info,phys.Collision_Category,i64(push.b)))
        api.write_key(out,"force");api.write_number(out,push.force)
        serial.write_u8(out,'}')
    }
    serial.text_write_raw(out,"]")
    api.write_key(out,"undeclared");serial.write_u8(out,'[')
    first=true
    at:=0
    for field,index,value in phys.collision_settings_undeclared(settings,info,&at) {
        if !first {serial.write_u8(out,',')};first=false
        serial.write_u8(out,'{');api.write_text(out,"field",field,true)
        api.write_key(out,"index");serial.text_write_int(out,i64(index))
        api.write_key(out,"value");serial.text_write_int(out,value)
        serial.write_u8(out,'}')
    }
    serial.text_write_raw(out,"]}")
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
    request,read:=api_collision_request_read(call,false)
    if !read {return}
    w:=editor.shown_world(s)
    settings,valid:=api_collision_settings(call,w)
    if !valid {return}
    target,found:=api_collision_target(s,call,w,&request,false)
    if !found {return}
    info:=w.info
    value:=uintptr(core.raw_find(core.world_table_at(w,target.table),target.table.info,target.entity))
    out:=call.out
    serial.text_write_raw(out,`{"id":`);api.write_id(out,request.id)
    api.write_key(out,"playing");api.write_flag(out,editor.playing(s))
    api.write_key(out,"component");serial.text_write_string(out,base.text_get(request.component[:]))
    api.write_key(out,"prefix");serial.text_write_string(out,target.prefix)
    switch target.kind {
    case .Collider:
        collider:=api_collision_collider(target,value)
        of:=phys.collision_of_collider(settings,collider)
        api.write_text(out,"preset",api_collision_name(info,phys.Collision_Preset,i64(collider.preset)))
        api.write_bool(out,"sensor",of.sensor)
        api.write_key(out,"belongs");api_collision_names_write(out,info,of.belongs)
        api.write_key(out,"collides");api_collision_names_write(out,info,of.collides)
        api.write_key(out,"pushes");serial.write_u8(out,'{')
        first:=true
        for entry in collision_categories(info) {
            force:f32
            for index in 0..<phys.COLLISION_CATEGORY_CAPACITY {
                if of.belongs&(phys.Collision_Layers(1)<<uint(index))==0 {continue}
                force=max(force,phys.collision_push(settings,phys.Collision_Category(index),phys.Collision_Category(entry.value)))
            }
            if force==0 {continue}
            api.write_key(out,entry.name,first);api.write_number(out,force)
            first=false
        }
        serial.write_u8(out,'}')
        if target.group>=0 {
            group:=(cast(^core.Entity)(value+uintptr(target.group)))^
            api.write_key(out,"group")
            if id:=editor.api_entity_id(w,group);group!=core.NONE && id!=0 {api.write_id(out,id)} else {serial.text_write_raw(out,"null")}
        }
    case .Query:
        filter:=(cast(^phys.Query_Filter)(value+uintptr(target.query)))^
        hits,sensors:=phys.query_layers(filter)
        api.write_key(out,"hits");api_collision_names_write(out,info,hits)
        api.write_bool(out,"sensors",sensors)
    }
    serial.write_u8(out,'}')
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
    request,read:=api_collision_request_read(call,true)
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
    api.call_result(call,editor.Api_Edit_Result).id=request.id
}
