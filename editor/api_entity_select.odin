package editor

import "core:fmt"
import "core:strings"
import "mirai:core"
import "mirai:editor/api"
import "mirai:std/base"
import "mirai:std/serial"

// How the params of a method name an entity, in one place for scene.*,
// editor.select, camera.set and play.*: by its name, by a path of names
// (Parent/Child, as long as it needs to be to say which), by its id or by its
// handle. A name that several entities have is an error, never the first of
// them.

API_ENTITY_TEXT :: 256          // bytes of the text that names an entity
API_ENTITY_SEVERAL_SHOWN :: 8   // how many of the entities a name fits an error lists

// Whether the text has the form of an id or a handle: 16 hexadecimal digits,
// or any number of them after 0x, so that a name like "1" stays a name.
@(private="file")
api_entity_hex :: proc(text:string) -> (value:u64,is_hex:bool) {
    prefixed:=len(text)>2 && text[0]=='0' && (text[1]=='x' || text[1]=='X')
    if !prefixed && len(text)!=16 {return}
    return serial.text_parse_hex(text)
}

// Whether the end of the chain of names of an entity is the path.
@(private="file")
api_entity_path_is :: proc(w:core.World_Ref,e:core.Entity,path:string) -> bool {
    rest,at:=path,e
    for {
        slash:=strings.last_index_byte(rest,'/')
        if at==core.NONE || entity_name(w,at)!=rest[slash+1:] {return false}
        if slash<0 {return true}
        rest,at=rest[:slash],entity_parent(w,at)
    }
}

// The whole path of names of an entity from its root.
api_entity_path :: proc(w:core.World_Ref,e:core.Entity,allocator:=context.temp_allocator) -> string {
    names:=make([dynamic]string,context.temp_allocator)
    for at:=e;at!=core.NONE;at=entity_parent(w,at) {append(&names,entity_name(w,at))}
    b:=strings.builder_make(allocator)
    for i:=len(names)-1;i>=0;i-=1 {
        if i<len(names)-1 {strings.write_byte(&b,'/')}
        strings.write_string(&b,names[i])
    }
    return strings.to_string(b)
}

// The entity a text names; NONE when none does, and then several says why
// when the text fits more than one, for whoever reads it as a miss.
api_entity_find :: proc(w:core.World_Ref,text:string,game:=false,allocator:=context.temp_allocator) -> (e:core.Entity,several:string) {
    if value,is_hex:=api_entity_hex(text);is_hex {
        if found:=api_entity(w,base.Entity_Id(value));found!=core.NONE {return found,""}
        if core.alive(core.world_entities(w),core.Entity(value)) {return core.Entity(value),""}
    }
    matches:=make([dynamic]core.Entity,context.temp_allocator)
    if names:=core.world_table_of(w,core.Name);names!=nil {
        for candidate in names.entities {
            if api_entity_path_is(w,candidate,text) {append(&matches,candidate)}
        }
    }
    if len(matches)==1 {return matches[0],""}
    if len(matches)==0 {return core.NONE,""}
    b:=strings.builder_make(allocator)
    fmt.sbprintf(&b,"%q names %d entities: ",text,len(matches))
    for match,i in matches[:min(len(matches),API_ENTITY_SEVERAL_SHOWN)] {
        if i>0 {strings.write_string(&b,", ")}
        strings.write_string(&b,api_entity_path(w,match,allocator))
        if id:=api_entity_id(w,match);id!=0 {fmt.sbprintf(&b," (id %016x)",u64(id))} else {fmt.sbprintf(&b," (handle %016x)",u64(match))}
    }
    if len(matches)>API_ENTITY_SEVERAL_SHOWN {fmt.sbprintf(&b," and %d more",len(matches)-API_ENTITY_SEVERAL_SHOWN)}
    fmt.sbprintf(&b,"; give a path of its parents as Parent/%s, or one id or handle",text)
    return core.NONE,strings.to_string(b)
}

// The entity a text names; problem says what is wrong for whoever gave it,
// after what, the name of the param.
api_entity_select :: proc(w:core.World_Ref,text:string,what:="entity",game:=false,allocator:=context.temp_allocator) -> (e:core.Entity,problem:string) {
    lister:=game?"play.inspect":"scene.inspect"
    if text=="" {return core.NONE,fmt.aprintf("%s is required: the name of an entity, a path Parent/Child, an id or a handle; %s lists them",what,lister,allocator=allocator)}
    several:string
    if e,several=api_entity_find(w,text,game,allocator);e!=core.NONE {return e,""}
    if several!="" {return core.NONE,fmt.aprintf("%s: %s",what,several,allocator=allocator)}
    of:=game?"the game":"the scene"
    return core.NONE,fmt.aprintf("%s: %q names no entity of %s; %s lists their names and ids",what,text,of,lister,allocator=allocator)
}

// api_entity_select of a text of the params; false after failing the call.
api_call_entity :: proc(call:^api.Call,w:core.World_Ref,field:[]u8,what:="entity",game:=false) -> (e:core.Entity,ok:bool) {
    problem:string
    if e,problem=api_entity_select(w,base.text_get(field),what,game,call.allocator);problem!="" {
        api.call_fail(call,api.INVALID_PARAMS,problem)
        return core.NONE,false
    }
    return e,true
}

// The entity at the reader of params read by hand; null is none.
rpc_entity :: proc(a:^Rpc_Args,w:core.World_Ref,what:string,game:=false) -> (e:core.Entity,ok:bool) {
    if a.failed {return}
    if serial.text_keyword(&a.r,"null") {return core.NONE,true}
    text,read:=serial.text_string(&a.r)
    if !read {return core.NONE,rpc_fail(a,"%s must be the name of an entity, a path Parent/Child, an id or a handle",what)}
    problem:string
    if e,problem=api_entity_select(w,text,what,game,a.call.allocator);problem!="" {return core.NONE,rpc_fail(a,"%s",problem)}
    return e,true
}

// The entities of a list of texts of the params: each one named, and none
// twice; false after failing the call.
api_call_entities :: proc(call:^api.Call,w:core.World_Ref,texts:[][API_ENTITY_TEXT]u8,what:string,allocator:=context.temp_allocator) -> (entities:[]core.Entity,ok:bool) {
    out:=make([dynamic]core.Entity,0,len(texts),allocator)
    for &text,i in texts {
        given:=base.text_get(text[:])
        if given=="" {continue}
        e,known:=api_call_entity(call,w,text[:],fmt.tprintf("%s[%d]",what,i))
        if !known {return}
        for other in out {
            if other==e {
                api.call_failf(call,api.INVALID_PARAMS,"%s[%d]: %q is listed twice; list each entity once",what,i,given)
                return
            }
        }
        append(&out,e)
    }
    return out[:],true
}
