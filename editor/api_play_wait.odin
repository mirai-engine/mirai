package editor

import "core:encoding/json"
import "core:fmt"
import "core:strconv"
import "core:strings"
import "mirai:core"
import "mirai:editor/api"
import "mirai:std/base"
import "mirai:std/serial"

// Conditions on the game that plays: a value of a component of an entity or
// of a storage compared with a number or a text, or whether an entity or a
// component is there. play.check reads them now; play.step with until runs
// ticks until they hold. Values are read as play.inspect writes them.

API_PLAY_CONDITIONS :: 16

Api_Compare :: enum u8 {Exists,Gone,Equal,Not_Equal,Below,At_Most,Above,At_Least}

Api_Play_Condition :: struct {
    entity:[API_ENTITY_TEXT]u8 `mirai:"optional,text,label=The entity by its name or a path Parent/Child or its id or its handle"`,
    component:[64]u8 `mirai:"optional,text,label=A component of the entity; empty: the entity itself or its world_position"`,
    storage:[64]u8 `mirai:"optional,text,label=A storage of the world in place of an entity"`,
    view:bool `mirai:"optional,label=What the player sees as play.view writes it in place of a storage or an entity: the entity named is its point (points.0)"`,
    field:[128]u8 `mirai:"optional,text,label=The value inside by names of fields and indices of elements joined by dots (velocity.1 or points.0.normalized.0); empty: all of it"`,
    compare:Api_Compare `mirai:"optional,label=Exists (the default) and Gone say whether the entity or the component or the field is there; the others compare the value"`,
    number:f64 `mirai:"optional,label=What a number is compared with; a bool is 1 or 0"`,
    text:[128]u8 `mirai:"optional,text,label=What a text or the name of a value of an enum is compared with (Equal and Not_Equal) in place of number"`,
}

Api_Play_Check_Params :: struct {
    conditions:[API_PLAY_CONDITIONS]Api_Play_Condition `mirai:"label=What must hold"`,
    player:int `mirai:"optional,min=0,max=3,label=The run of that player of a game a turn plays on the network"`,
}

Api_Play_Check_Result :: struct {
    passed:bool `mirai:"label=Every condition holds"`,
    tick:u64 `mirai:"label=The tick of the game they were read at"`,
    results:[1]Api_Play_Check_Entry `mirai:"list,label=One per condition in their order"`,
}
Api_Play_Check_Entry :: struct {
    passed:bool,
    value:u8 `mirai:"any,label=What it read as play.inspect writes it; null when the entity or the component or the storage is not there"`,
}

Api_Play_Get_Params :: struct {
    entity:[API_ENTITY_TEXT]u8 `mirai:"text,label=The entity by its name or a path Parent/Child or its id or its handle"`,
    field:[128]u8 `mirai:"text,label=A component and the path inside it (Transform.position or Motion.linear[1]) or a path of the document of the entity as play.inspect writes it (world_position)"`,
    player:int `mirai:"optional,min=0,max=3,label=The run of that player of a game a turn plays on the network"`,
}

Api_Play_Get_Result :: struct {
    entity:[16]u8 `mirai:"text,label=The handle of the entity"`,
    tick:u64 `mirai:"label=The tick of the game it was read at"`,
    value:u8 `mirai:"any,label=The value as play.inspect writes it"`,
}

@(private)
api_play_wait_register :: proc(s:^Session,st:^Api_State) {
    api_register(s,st,{name="play.get",summary="One value of one entity of the game of the caller now, without its whole document: a field of a component or a place of the world.",params=Api_Play_Get_Params,result=Api_Play_Get_Result,writes_result=true,flags={.Read_Only},run=api_play_get})
    api_register(s,st,{name="play.check",summary="Says whether conditions on the game of the caller hold now (values of components or storages compared, entities there or gone) with what each one read: the assertions of a test.",params=Api_Play_Check_Params,result=Api_Play_Check_Result,writes_result=true,flags={.Core,.Read_Only},run=api_play_check})
}

// What a condition read of a world: whether it holds, and the value as JSON.
@(private)
Api_Condition_Read :: struct {
    passed:bool,
    value:string,
}

// Reads a condition on w. problem says what is wrong with the condition
// itself: what it names that the game does not have; an entity or a
// component that is not there is a reading, not a problem.
@(private)
api_condition_read :: proc(s:^Session,w:core.World_Ref,c:^Api_Play_Condition,allocator:=context.temp_allocator) -> (read:Api_Condition_Read,problem:string) {
    st:=api_state(s)
    entity,component,storage:=base.text_get(c.entity[:]),base.text_get(c.component[:]),base.text_get(c.storage[:])
    field,text:=base.text_get(c.field[:]),base.text_get(c.text[:])
    named:=int(entity!="")
    if c.view && (storage!="" || component!="") {return {},"view reads what the player sees: leave storage and component out; an entity named is its point"}
    if !c.view && (named>0) == (storage!="") {return {},"name what it reads: an entity, a storage or the view"}
    if storage!="" && component!="" {return {},"a storage has no components: leave component out, or name an entity"}
    if text!="" && c.compare!=.Equal && c.compare!=.Not_Equal && c.compare!=.Exists && c.compare!=.Gone {return {},"a text is compared with Equal or Not_Equal; give number for the others"}
    out:serial.Writer
    serial.writer_init(&out,0,allocator)
    found:=false
    switch {
    case storage!="":
        at:=-1
        for &info,i in s.info.storages {if st.storage_types[i]!=serial.TYPE_NONE && info.name==storage {at=i;break}}
        if at<0 {return {},fmt.tprintf("storage %q is not a storage of the game; play.inspect with storages lists them",storage)}
        info:=&s.info.storages[at]
        scratch:=make([]u8,max(info.info.size,1),allocator)
        api_value_out(w,info.info,rawptr(uintptr(w.data)+info.offset),scratch,handles=true)
        serial.text_write(&out,&st.schema,st.storage_types[at],scratch[:info.info.size],.Line)
        found=true
    case:
        e:=core.NONE
        if entity!="" {
            several:string
            e,several=api_entity_find(w,entity,allocator)
            if several!="" {return {},several}
        }
        if c.view {
            // An entity that is not there is a reading of null, as without view.
            if named>0 && e==core.NONE {break}
            targets:=[1]Play_View_Target{{entity=e,named=true}}
            text,problem:=play_view_json(w,targets[:named],allocator)
            if problem!="" {return {},problem}
            serial.text_write_raw(&out,text)
            found=true
        } else if component!="" {
            t,problem:=api_component_named(shown_world(s),component)
            if t==nil || t.place!=.World || st.types[api_table_index(s,t)]==serial.TYPE_NONE {return {},fmt.tprintf("component: %s; component.list lists them",problem!=""?problem:component)}
            value:=e!=core.NONE?core.raw_find(core.world_table_at(w,t),t.info,e):nil
            if value!=nil {
                scratch:=make([]u8,max(t.info.size,1),allocator)
                api_value_out(w,t.info,value,scratch,handles=true)
                serial.text_write(&out,&st.schema,st.types[api_table_index(s,t)],scratch[:t.info.size],.Line,omit_fields={})
                found=true
            }
        } else if e!=core.NONE {
            position:=entity_world(w,e).position
            serial.text_write_raw(&out,`{"entity":"`);serial.text_write_hex(&out,u64(e))
            serial.text_write_raw(&out,`","world_position":`);api.write_list(&out,position[:])
            serial.write_u8(&out,'}')
            found=true
        }
    }
    if !found {return {passed=c.compare==.Gone,value="null"},""}
    whole,parse_error:=json.parse(serial.writer_bytes(&out),allocator=allocator)
    if parse_error!=nil {return {},"the value could not be read back as JSON"}
    leaf,missing:=api_json_select(whole,field,allocator)
    if missing!="" {return {},fmt.tprintf("field %q: %s",field,missing)}
    read.value=api_json_text(leaf,allocator)
    switch c.compare {
    case .Exists: read.passed=true
    case .Gone:   read.passed=false
    case .Equal,.Not_Equal,.Below,.At_Most,.Above,.At_Least:
        equal:bool
        order:f64
        #partial switch v in leaf {
        case json.Integer: order=f64(v)-c.number
        case json.Float:   order=f64(v)-c.number
        case json.Boolean: order=(v?1:0)-c.number
        case json.String:
            if text=="" && c.compare!=.Equal && c.compare!=.Not_Equal {return {},fmt.tprintf("%s is a text: compare it with Equal or Not_Equal and text",read.value)}
            equal=string(v)==text
        case:
            return {},fmt.tprintf("%s is not a number, a bool or a text: name a field inside it",read.value)
        }
        if _,is_text:=leaf.(json.String);!is_text {
            if text!="" {return {},fmt.tprintf("%s is not a text: compare it with number",read.value)}
            equal=order==0
        }
        #partial switch c.compare {
        case .Equal:     read.passed=equal
        case .Not_Equal: read.passed=!equal
        case .Below:     read.passed=order<0
        case .At_Most:   read.passed=order<=0
        case .Above:     read.passed=order>0
        case .At_Least:  read.passed=order>=0
        }
    }
    return
}

// Reads every condition; problem names the first that is wrong.
@(private)
api_conditions_read :: proc(s:^Session,w:core.World_Ref,conditions:[]Api_Play_Condition,reads:[]Api_Condition_Read,what:string) -> (all:bool,problem:string) {
    all=true
    for &c,i in conditions {
        read,wrong:=api_condition_read(s,w,&c)
        if wrong!="" {return false,fmt.tprintf("%s[%d]: %s",what,i,wrong)}
        if i<len(reads) {reads[i]=read}
        all&&=read.passed
    }
    return
}

@(private)
api_play_check :: proc(s:^Session,call:^api.Call) {
    params:=api.call_params(call,Api_Play_Check_Params)
    r,_:=api_play_run(s,call,params.player)
    if r==nil {api.call_fail(call,api.SERVER_ERROR,API_NO_GAME);return}
    values:[1]string
    api.object_values(call.allocator,call.raw,{"conditions"},values[:])
    count:=api.json_count(values[0])
    if count==0 {api.call_fail(call,api.INVALID_PARAMS,"conditions is empty: give what must hold");return}
    w:=run_ref(s,r)
    reads:=make([]Api_Condition_Read,count,context.temp_allocator)
    passed,problem:=api_conditions_read(s,w,params.conditions[:count],reads,"conditions")
    if problem!="" {api.call_fail(call,api.INVALID_PARAMS,problem);return}
    out:=call.out
    serial.text_write_raw(out,`{"passed":`);api.write_flag(out,passed)
    tick:u64
    if t:=core.world_storage_of(w,core.Time);t!=nil {tick=t.tick}
    api.write_key(out,"tick");serial.text_write_uint(out,tick)
    api.write_key(out,"results");serial.write_u8(out,'[')
    for read,i in reads {
        if i>0 {serial.write_u8(out,',')}
        serial.text_write_raw(out,`{"passed":`);api.write_flag(out,read.passed)
        api.write_key(out,"value");serial.text_write_raw(out,read.value)
        serial.write_u8(out,'}')
    }
    serial.text_write_raw(out,"]}")
}

// A value of a live entity as JSON text: field is a component and the path
// inside it, read as play.check reads it, or a path of the document of the
// entity as play.inspect writes it. Transient values count: it is one value.
api_entity_field :: proc(s:^Session,w:core.World_Ref,e:core.Entity,field:string,allocator:=context.temp_allocator) -> (value,problem:string) {
    st:=api_state(s)
    head,rest:=field,""
    if end:=strings.index_any(field,".[");end>=0 {head,rest=field[:end],strings.trim_prefix(field[end:],".")}
    if t:=component_table(s,head);t!=nil && t.name==head && t.place==.World && st.types[api_table_index(s,t)]!=serial.TYPE_NONE {
        c:Api_Play_Condition
        api_handle_put(c.entity[:],e)
        base.text_set(c.component[:],head)
        base.text_set(c.field[:],rest)
        read,wrong:=api_condition_read(s,w,&c,allocator)
        if wrong!="" {return "",wrong}
        if read.value=="null" {return "",fmt.tprintf("the entity has no %s: play.inspect lists its components",head)}
        return read.value,""
    }
    out:serial.Writer
    serial.writer_init(&out,0,allocator)
    api_entity_write(s,w,&out,e,true,make([]u8,max(st.largest,1),allocator),true,true)
    whole,parse_error:=json.parse(serial.writer_bytes(&out),allocator=allocator)
    if parse_error!=nil {return "","the value could not be read back as JSON"}
    leaf,missing:=api_json_select(whole,field,allocator)
    if missing!="" {return "",fmt.tprintf("field %q: %s, or a component of the game as Transform.position",field,missing)}
    return api_json_text(leaf,allocator),""
}

@(private)
api_play_get :: proc(s:^Session,call:^api.Call) {
    p:=api.call_params(call,Api_Play_Get_Params)
    r,_:=api_play_run(s,call,p.player)
    if r==nil {api.call_fail(call,api.SERVER_ERROR,API_NO_GAME);return}
    w:=run_ref(s,r)
    e,known:=api_call_entity(call,w,p.entity[:],game=true)
    if !known {return}
    value,wrong:=api_entity_field(s,w,e,base.text_get(p.field[:]),call.allocator)
    if wrong!="" {api.call_fail(call,api.INVALID_PARAMS,wrong);return}
    out:=call.out
    handle:[16]u8
    api_handle_put(handle[:],e)
    serial.text_write_raw(out,`{"entity":`);serial.text_write_string(out,string(handle[:]))
    api.write_key(out,"tick")
    tick:u64
    if t:=core.world_storage_of(w,core.Time);t!=nil {tick=t.tick}
    serial.text_write_uint(out,tick)
    api.write_key(out,"value");serial.text_write_raw(out,value)
    serial.write_u8(out,'}')
}

// The value at a path inside a JSON value: names of fields joined by dots and
// [i] for element i of a list, from its end when negative (velocity[1], also
// velocity.1); "" is the whole value. missing says which part is not there
// and what is.
@(private)
api_json_select :: proc(value:json.Value,path:string,allocator:=context.temp_allocator) -> (leaf:json.Value,missing:string) {
    leaf=value
    rest:=path
    for rest!="" {
        part:string
        if rest[0]=='[' {
            end:=strings.index_byte(rest,']')
            if end<0 {return nil,fmt.tprintf("%q has no ] that closes it",rest)}
            part,rest=rest[1:end],rest[end+1:]
            if strings.has_prefix(rest,".") {rest=rest[1:]}
        } else {
            end:=strings.index_any(rest,".[")
            switch {
            case end<0:          part,rest=rest,""
            case rest[end]=='.': part,rest=rest[:end],rest[end+1:]
            case:                part,rest=rest[:end],rest[end:]
            }
        }
        if part=="" {return nil,fmt.tprintf("%q has an empty name: join names with one dot",path)}
        #partial switch v in leaf {
        case json.Object:
            inner,has:=v[part]
            if !has {
                keys:=make([dynamic]string,allocator)
                for key in v {append(&keys,key)}
                return nil,fmt.tprintf("%q is not there; it has %s",part,strings.join(keys[:],", ",allocator))
            }
            leaf=inner
        case json.Array:
            index,number:=strconv.parse_int(part)
            if number && index<0 {index+=len(v)}
            if !number || index<0 || index>=len(v) {return nil,fmt.tprintf("%q is not an element of a list of %d",part,len(v))}
            leaf=v[index]
        case:
            return nil,fmt.tprintf("%q goes inside a value that has nothing inside",part)
        }
    }
    return
}

// A JSON value as text; a number as short as it reads back the same.
@(private)
api_json_text :: proc(value:json.Value,allocator:=context.temp_allocator) -> string {
    if v,is_float:=value.(json.Float);is_float {
        buffer:=make([]u8,32,allocator)
        text:=strconv.write_float(buffer,f64(v),'g',-1,64)
        return text[1:] if strings.has_prefix(text,"+") else text
    }
    bytes,_:=json.marshal(value,allocator=allocator)
    return string(bytes)
}
