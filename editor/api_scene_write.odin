package editor

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:slice"
import "core:strings"
import "mirai:asset"
import "mirai:cook/author"
import "mirai:core"
import "mirai:editor/api"
import erender "mirai:engine/render"
import "mirai:std/base"
import mm "mirai:std/math"
import "mirai:std/serial"

// A subtree of the scene as a document: what scene.inspect gives with root and
// scene.write takes back. Entities nest by children and give what differs from
// a new entity: their transform local to the parent, being hidden or off, and
// by name the components they have with the fields that differ from the value
// a component starts with; a preset or the card of a plugin, as scene.add
// takes it, stands for the components it gives. scene.write makes root and what hangs from it say
// what the document declares, in one step: entities matched by Id, else by
// name among their siblings, else by place, keep what ties them to the scene
// (their Id, the overrides of an instance); the others are made, and those it
// does not declare go. A member of an instance of a prefab keeps the place its
// prefab gives it: left out, it is turned off. A new entity with prefab is
// placed as a linked instance of that prefab, as prefab.instantiate places
// one, and what it and the entities under it leave out stays as the prefab
// gives it; so does an instance that is there and names its prefab the same
// way, by path or id alone. What prefab says is read and checked by
// cook/author, as the write with no editor does. Entities without an Id and
// what a section holds are not part of the document.

Api_Write_Result :: struct {
    id:base.Entity_Id `mirai:"label=The root: the one given or the one the document made"`,
    made:int `mirai:"label=Entities the document made"`,
    removed:int `mirai:"label=Entities it took away with what hung from them"`,
    disabled:int `mirai:"label=Members of an instance of a prefab it left out and turned off"`,
    created:[]Api_Write_Made `mirai:"label=The entities of the document it made in its order; of a prefab it placed the root of the instance, whose members hang from it"`,
}
Api_Write_Made :: struct {
    id:base.Entity_Id,
    name:[64]u8 `mirai:"text"`,
}

// An entity of a document, read in pre-order.
@(private)
Api_Write_Entity :: struct {
    path:string,       // where it is in the document, for errors
    parent:int,        // the entity of the document it hangs from; -1 at the top
    end:int,           // past the last entity of the document that hangs from it
    id:base.Entity_Id, // 0: none given
    name:string,       // "": none given
    position,rotation_deg,scale:[3]f32,
    has_position,has_rotation,has_scale:bool,
    hidden,disabled:bool,
    has_visible,has_enabled:bool,
    preset:string,     // "": none given
    card:int,          // its place in cards(); -1 without a preset
    components,off,prefab:string, // as given; "": left out
    given:author.Scene_Prefab,    // what prefab says
    e:core.Entity,     // the entity it is matched to or made as
    made:bool,
    sparse:bool,       // of an instance the document names by its prefab alone: what it leaves out is what its prefab gives
}

// A component a card gives, with its value as the API shows it.
@(private)
Api_Card_Part :: struct {
    t:^core.Table_Info,
    value:[]u8,
}

@(private)
API_WRITE_KEYS :: "id, name, preset, position, rotation_deg, scale, visible, enabled, components, off, prefab and children"

Api_Scene_Write_Params_Entities :: struct {
    id:string `mirai:"optional,label=matches the entity with this id under root, which may move to another parent"`,
    preset:string `mirai:"optional,label=a preset or the card of a plugin, as scene.add takes it (cube, point_light, sun, spawn...): it gives the entity its components, whose fields components changes, and the rotation and scale it has when those are left out"`,
    name:string `mirai:"optional,label=without id, matches the entity of this name among those of its parent"`,
    position:[3]f32 `mirai:"optional,label=local to the parent; [0,0,0] when left out"`,
    rotation_deg:[3]f32 `mirai:"optional,label=[0,0,0] or that of its preset when left out"`,
    scale:[3]f32 `mirai:"optional,label=[1,1,1] or that of its preset when left out"`,
    visible,enabled:bool `mirai:"optional,label=true when left out"`,
    components:serial.Json `mirai:"optional,label=by name the components it has besides those of its preset, each with the fields that differ from the value it starts with; those it leaves out go"`,
    off:[]string `mirai:"optional,label=components it declares that are turned off by themselves"`,
    prefab:serial.Json `mirai:"optional,label=A string or a object. on a new entity, the path or the id of a .scene: it is placed as a linked instance, and what the entity and those under it leave out stays as the prefab gives it, also in a later write that names it the same way; on an entity that is there, {asset, root} as scene.inspect gives it declares all it has; a write changes no link of an entity that is there"`,
    children:[]serial.Json `mirai:"optional,label=the entities that hang from it, in order, each with these keys"`,
}
Api_Scene_Write_Params :: struct {
    root:string `mirai:"entity,optional,label=by its name, a path Parent/Child or its id, the entity the document declares with what hangs from it; left out: the document makes a new root"`,
    entities:[]Api_Scene_Write_Params_Entities `mirai:"label=the entity root is, or the new one, nesting what hangs from it by children; matched by id, else by name among siblings, else by place, the others are made and what it leaves out goes (a member of an instance of a prefab is turned off)"`,
}

@(private)
api_scene_write_register :: proc(s:^Session,st:^Api_State) {
    api_register(s,st,{name="scene.write",flags={.Core,.Destructive},params=Api_Scene_Write_Params,summary="Makes an entity and what hangs from it say what a document of nested entities declares, as scene.inspect with root gives it: matched by id, name or place, the others made (one with prefab as a linked instance of it) and what it leaves out taken away, in one step; the result names what it made.",result=Api_Write_Result,writes_result=true,run=api_scene_write})
}

// Prefixes the error of the call with where it happened in the document; false.
@(private)
api_write_failed :: proc(call:^api.Call,path:string) -> bool {
    call.error.message=api.format_text(call.allocator,"%s: %s",path,call.error.message)
    return false
}

// Reads an array of entities of the document, each before what hangs from it.
@(private)
api_write_read :: proc(a:^Rpc_Args,parent:int,path:string,out:^[dynamic]Api_Write_Entity) -> bool {
    if a.failed {return false}
    if !serial.text_accept(&a.r,'[') {return rpc_fail_type(a,"%s must be an array of entities",path)}
    if serial.text_accept(&a.r,']') {return true}
    for at:=0;;at+=1 {
        d:=Api_Write_Entity{path=fmt.aprintf("%s[%d]",path,at,allocator=a.call.allocator),parent=parent,card=-1}
        if _,error:=append(out,d);error!=nil {return rpc_fail(a,"the document has more entities than the server holds")}
        api_write_entity_read(a,len(out)-1,out) or_return
        if serial.text_accept(&a.r,',') {continue}
        if serial.text_accept(&a.r,']') {return true}
        return rpc_fail_type(a,"%s must be an array of entities",path)
    }
}

@(private)
api_write_entity_read :: proc(a:^Rpc_Args,index:int,out:^[dynamic]Api_Write_Entity) -> bool {
    path:=out[index].path
    rpc_object_begin(a,path) or_return
    object:Rpc_Object
    for key in rpc_next(a,&object) {
        d:=&out[index]
        ok:=true
        switch key {
        case "id":           d.id,ok=rpc_id(a,key)
        case "position":     ok=rpc_vector(a,key,d.position[:]);d.has_position=ok
        case "rotation_deg": ok=rpc_vector(a,key,d.rotation_deg[:]);d.has_rotation=ok
        case "scale":        ok=rpc_vector(a,key,d.scale[:]);d.has_scale=ok
        case "components":   d.components,ok=rpc_raw(a)
        case "off":          d.off,ok=rpc_raw(a)
        case "prefab":       d.prefab,ok=rpc_raw(a)
        case "preset":
            text:[32]u8
            preset:string
            if preset,ok=rpc_text(a,key,text[:]);ok {d.preset=strings.clone(preset,a.call.allocator)}
        case "name":
            text:[64]u8
            name:string
            if name,ok=rpc_text(a,key,text[:63]);ok {
                d.name=strings.clone(strings.trim_space(name),a.call.allocator)
                if d.name=="" {ok=rpc_fail(a,"name is empty; leave it out to match by place")}
            }
        case "visible","enabled":
            value:bool
            if value,ok=rpc_bool(a,key);ok {
                if key=="visible" {d.hidden,d.has_visible=!value,true} else {d.disabled,d.has_enabled=!value,true}
            }
        case "children":
            api_write_read(a,index,fmt.tprintf("%s.children",path),out) or_return
            out[index].end=len(out)
        case:
            return rpc_fail(a,"%s has no '%s'; an entity has %s",path,key,API_WRITE_KEYS)
        }
        if !ok {return api_write_failed(a.call,path)}
    }
    if a.failed {return api_write_failed(a.call,path)}
    if out[index].end==0 {out[index].end=len(out)}
    return true
}

// The entities of the part of the scene a document declares: root and what
// hangs from it, in pre-order, without entities that have no Id or are of a
// section, nor what hangs from them.
@(private)
api_part :: proc(s:^Session,w:core.World_Ref,root:core.Entity,allocator:runtime.Allocator) -> []core.Entity {
    h:=entity_hierarchy(w)
    out:=make([dynamic]core.Entity,allocator)
    at:=root
    for at!=core.NONE {
        kept:=at==root || api_part_kept(s,w,at)
        if kept {append(&out,at)}
        at=core.subtree_next(h,root,at,kept)
    }
    return out[:]
}

@(private)
api_part_kept :: proc(s:^Session,w:core.World_Ref,e:core.Entity) -> bool {
    return api_entity_id(w,e)!=0 && !section_locked(s,w,e)
}

// Whether the entity can change now: false, failing the call, when a section keeps it.
@(private)
api_write_editable :: proc(s:^Session,call:^api.Call,w:core.World_Ref,e:core.Entity,path:string) -> bool {
    if text:=section_lock_text(s,w,e,true);text!="" {
        api.call_failf(call,api.SERVER_ERROR,"%s: %s",path,text)
        return false
    }
    return true
}

@(private)
api_scene_write :: proc(s:^Session,call:^api.Call) {
    a:Rpc_Args
    rpc_init(&a,call,call.raw)
    root:base.Entity_Id
    decls:=make([dynamic]Api_Write_Entity,call.allocator)
    object:Rpc_Object
    if !rpc_object_begin(&a,"params") {return}
    for key in rpc_next(&a,&object) {
        switch key {
        case "root":
            if e,read:=rpc_entity(&a,edited_world(s),key);read {root=api_entity_id(edited_world(s),e)}
        case "entities": api_write_read(&a,-1,"entities",&decls)
        case:            rpc_fail_type(&a,"unknown field %q; scene.write takes root and entities",key)
        }
    }
    if a.failed {return}
    if len(decls)==0 || decls[0].end!=len(decls) {
        api.call_fail(call,api.INVALID_PARAMS,"entities declares one entity: root when it is given, or a new root, with what hangs from it as its children")
        return
    }
    given:=make(map[base.Entity_Id]int,len(decls),call.allocator)
    for &d,i in decls {
        if d.id==0 {continue}
        if _,twice:=given[d.id];twice {
            api.call_failf(call,api.INVALID_PARAMS,"%s.id: 0x%016x is declared twice",d.path,u64(d.id))
            return
        }
        given[d.id]=i
    }
    if !api_edit_begin(s,call,"Write entities") {return}
    w:=edited_world(s)
    result,applied:=api_write_apply(s,call,w,root,decls[:])
    if !api_edit_end(s,call,applied) {return}
    out:=call.out
    serial.text_write_raw(out,`{"id":`);api.write_id(out,result.id)
    api.write_int(out,"made",i64(result.made))
    api.write_int(out,"removed",i64(result.removed))
    api.write_int(out,"disabled",i64(result.disabled))
    api.write_key(out,"created");serial.write_u8(out,'[')
    first:=true
    for d in decls {
        if !d.made {continue}
        if !first {serial.write_u8(out,',')}
        first=false
        serial.text_write_raw(out,`{"id":`);api.write_id(out,api_entity_id(w,d.e))
        api.write_text(out,"name",entity_name(w,d.e))
        serial.write_u8(out,'}')
    }
    serial.text_write_raw(out,"]}")
}

// Makes the part of root say what the document declares, inside the open
// transaction. False after failing the call, with where in the document.
@(private)
api_write_apply :: proc(s:^Session,call:^api.Call,w:core.World_Ref,root_id:base.Entity_Id,decls:[]Api_Write_Entity) -> (result:Api_Write_Result,ok:bool) {
    member :: proc(w:core.World_Ref,e:core.Entity) -> bool {
        link,linked:=prefab_link_of(w,e)
        return linked && !link.root
    }
    // The root of the instance that placed an entity; NONE for none.
    placer :: proc(w:core.World_Ref,e:core.Entity) -> core.Entity {
        link,_:=prefab_link_of(w,e)
        return link.instance
    }
    // The part, each entity true once a document entity takes it.
    part:[]core.Entity
    taken:=make(map[core.Entity]bool,call.allocator)
    root:=core.NONE
    if root_id!=0 {
        root=api_entity(w,root_id)
        if root==core.NONE {api.call_failf(call,api.INVALID_PARAMS,"root 0x%016x is not an entity of the scene",u64(root_id));return}
        if text:=section_lock_text(s,w,root,true);text!="" {api.call_failf(call,api.SERVER_ERROR,"root: %s",text);return}
        if decls[0].id!=0 && decls[0].id!=root_id {
            api.call_failf(call,api.INVALID_PARAMS,"entities[0].id: the entity the document declares is root, 0x%016x",u64(root_id))
            return
        }
        part=api_part(s,w,root,call.allocator)
        for e in part {taken[e]=false}
        decls[0].e=root
        taken[root]=true
    }
    for &d,i in decls {
        if d.id==0 || i==0 && root!=core.NONE {continue}
        e:=api_entity(w,d.id)
        if e==core.NONE {api.call_failf(call,api.INVALID_PARAMS,"%s.id: 0x%016x is no entity of the scene; leave id out to make one",d.path,u64(d.id));return}
        if e==root {api.call_failf(call,api.INVALID_PARAMS,"%s.id: root is the entity at the top of the document",d.path);return}
        if _,inside:=taken[e];!inside {
            if root==core.NONE {api.call_failf(call,api.INVALID_PARAMS,"%s.id: without root the document makes a new root and moves nothing into it; give root to write an entity that is there",d.path);return}
            api.call_failf(call,api.INVALID_PARAMS,"%s.id: 0x%016x does not hang from root; a write declares root and what hangs from it",d.path,u64(d.id))
            return
        }
        d.e=e
        taken[e]=true
    }
    for &p,i in decls {
        if p.e!=core.NONE {api_write_match(w,decls,i,&taken,call.allocator)}
    }
    reading:=author.Reading{allocator=call.allocator,raw=call.raw,assets={s,asset_text_resolve}}
    // The instances the document names by their prefab alone: what it leaves out of them stays.
    sparse:=make(map[core.Entity]bool,call.allocator)
    for &d in decls {
        if d.prefab!="" {
            read:bool
            if d.given,read=author.scene_prefab_read(&reading,d.prefab,d.path);!read {api_write_unread(call,&reading);return}
        }
        if d.e==core.NONE {continue}
        if d.prefab!="" {api_write_linked(call,w,&reading,&sparse,&d) or_return}
        if d.parent>=0 && member(w,d.e) && entity_parent(w,d.e)!=decls[d.parent].e {
            api.call_failf(call,api.INVALID_PARAMS,"%s: %s is a member of an instance of a prefab and keeps the place its prefab gives it; declare it under %s, or leave it out to turn it off",d.path,entity_label(w,d.e),entity_label(w,entity_parent(w,d.e)))
            return
        }
    }
    // The components of each card the document names, made once.
    parts:=make(map[int][]Api_Card_Part,call.allocator)
    for &d in decls {
        if d.preset=="" {continue}
        found:bool
        if d.card,found=card_named(s,d.preset);!found {
            api.call_failf(call,api.INVALID_PARAMS,"%s.preset: %s",d.path,cards_problem(s,d.preset))
            return
        }
        if d.card not_in parts {parts[d.card]=api_card_parts(s,w,d.card,call.allocator)}
    }
    // What the document adds, and what it moves.
    for &d,i in decls {
        parent:=d.parent>=0?decls[d.parent].e:core.NONE
        if d.e!=core.NONE && (d.parent<0 || entity_parent(w,d.e)==parent) {continue}
        if _,reason:=section_target_texts(s,w,parent!=core.NONE?parent:section_editing(s));reason!="" {
            api.call_failf(call,api.SERVER_ERROR,"%s: %s",d.path,reason)
            return
        }
        if d.e==core.NONE && d.prefab!="" {
            result.made+=api_write_place(s,call,w,&reading,decls,i,parent,part,&taken,&sparse) or_return
            // What it declares under the instance is of its members, by their names.
            for c in i..<d.end {
                if decls[c].e==core.NONE {continue}
                if c>i && decls[c].prefab!="" {api_write_linked(call,w,&reading,&sparse,&decls[c]) or_return}
                api_write_match(w,decls,c,&taken,call.allocator)
            }
        } else if d.e==core.NONE {
            local:=core.Transform{d.position,mm.quat_from_euler(d.rotation_deg*mm.RAD_PER_DEG),d.scale}
            d.e=entity_create(s,{card=d.card,parent=parent,name=d.name,named=d.name!="",transform=local})
            if d.e==core.NONE {api.call_failf(call,api.SERVER_ERROR,"%s: the entity cannot be made there: its parent has no size in some axis",d.path);return}
            d.made=true
            result.made+=1
        } else {
            api_write_editable(s,call,w,d.e,d.path) or_return
            if !entity_reparent(s,d.e,parent) {api.call_failf(call,api.SERVER_ERROR,"%s: it cannot go under %s, which has no size in some axis",d.path,entity_label(w,parent));return}
        }
        core.world_settle(w)
    }
    result.id=api_entity_id(w,decls[0].e)
    for &d in decls {
        d.sparse||=sparse[placer(w,d.e)]
        api_write_values(s,call,w,&d,parts[d.card] if d.card>=0 else nil) or_return
    }
    // Siblings in the order of the document; a member keeps the place of its prefab.
    for &p,i in decls {
        last:=min(i32)
        for c:=i+1;c<p.end;c=decls[c].end {
            e:=decls[c].e
            parent,_:=entity_get(w,e,core.Parent)
            if member(w,e) {last=max(last,parent.order);continue}
            if parent.order<=last {
                api_write_editable(s,call,w,e,decls[c].path) or_return
                entity_order_set(s,e,last+1)
                parent.order=last+1
            }
            last=parent.order
        }
    }
    // What the part held and the document leaves out: it goes with what hangs
    // from it, and a member of an instance is turned off, unless the document
    // names the instance by its prefab alone: what it leaves out of it stays.
    gone:=make([dynamic]core.Entity,call.allocator)
    for e in part {
        if taken[e] {continue}
        parent:=entity_parent(w,e)
        parent_taken,parent_inside:=taken[parent]
        if member(w,e) {
            if sparse[placer(w,e)] || !parent_taken || entity_has(w,e,core.Disabled) {continue}
            api_write_editable(s,call,w,e,"root") or_return
            entity_enabled_set(s,e,false)
            result.disabled+=1
        } else if parent_taken || !parent_inside || member(w,parent) && !sparse[placer(w,parent)] {
            api_write_editable(s,call,w,e,"root") or_return
            append(&gone,e)
        }
    }
    if len(gone)>0 {
        entities_delete(s,gone[:])
        core.world_settle(w)
    }
    for e in part {result.removed+=int(!entity_alive(w,e))}
    core.world_settle(w)
    return result,true
}

// Fails the call with what a reading of the document failed with; false.
@(private)
api_write_unread :: proc(call:^api.Call,reading:^author.Reading) -> bool {
    api.call_fail(call,api.SERVER_ERROR if reading.internal else api.INVALID_PARAMS,reading.problem)
    return false
}

// The entities the document declares under the entity at p that no id
// matched take those that hang from it: by name, then by place.
@(private)
api_write_match :: proc(w:core.World_Ref,decls:[]Api_Write_Entity,p:int,taken:^map[core.Entity]bool,allocator:runtime.Allocator) {
    children:=entity_children(w,decls[p].e,allocator)
    for by_name in ([]bool{true,false}) {
        for c:=p+1;c<decls[p].end;c=decls[c].end {
            d:=&decls[c]
            if d.e!=core.NONE || d.id!=0 || (d.name!="")!=by_name {continue}
            for x in children {
                if used,inside:=taken[x];!inside || used {continue}
                if by_name && entity_name(w,x)!=d.name {continue}
                d.e=x
                taken[x]=true
                break
            }
        }
    }
}

// The prefab a matched entity gives is what links it; by its path or id
// alone, the instance is declared as its prefab gives it.
@(private)
api_write_linked :: proc(call:^api.Call,w:core.World_Ref,reading:^author.Reading,sparse:^map[core.Entity]bool,d:^Api_Write_Entity) -> bool {
    link,linked:=prefab_link_of(w,d.e)
    if !author.scene_prefab_same(reading,d.given,d.path,link.asset,link.root,linked) {return api_write_unread(call,reading)}
    if d.given.alone {
        d.sparse=true
        sparse[link.instance]=true
    }
    return true
}

// Places the prefab the new entity at index names under parent, inside the
// open edit, with prefab_instantiate. The members of the instance are left
// to be matched; made counts them.
@(private)
api_write_place :: proc(s:^Session,call:^api.Call,w:core.World_Ref,reading:^author.Reading,decls:[]Api_Write_Entity,index:int,parent:core.Entity,part:[]core.Entity,taken:^map[core.Entity]bool,sparse:^map[core.Entity]bool) -> (made:int,ok:bool) {
    d:=&decls[index]
    prefab:asset.Scene
    if !author.scene_prefab_open(reading,author.assets_of(s.app.assets),d.given,d.path,s.document.id,&prefab) {return 0,api_write_unread(call,reading)}
    // What the document leaves out of the place of the root is what its prefab gives it.
    source,_:=asset.prefab_root(&prefab)
    local,placed:=asset.scene_get(&prefab,source,"Transform",core.Transform)
    if !placed {local=core.TRANSFORM_IDENTITY}
    instantiated,error:=prefab_instantiate(s,d.given.asset,{parent=parent,position=local.position,rotation={local.rotation.x,local.rotation.y,local.rotation.z,local.rotation.w}},true)
    root:=api_entity(w,instantiated)
    if error==.None && root==core.NONE {error=.Rejected}
    if error!=.None {
        api.call_failf(call,api.SERVER_ERROR,"%s.prefab: %s",d.path,prefab_error_text(error))
        return 0,false
    }
    d.e,d.made,d.sparse=root,true,true
    sparse[root]=true
    for member in prefab_members(w,root) {
        taken[member.entity]=member.entity==root
        made+=1
    }
    return made,true
}

// The entity of the document takes what it declares: name, transform, being
// hidden or off, its components and those it turns off. parts are the
// components of its card: they are declared too, and the fields the document
// does not name take the values the card gives.
@(private)
api_write_values :: proc(s:^Session,call:^api.Call,w:core.World_Ref,d:^Api_Write_Entity,parts:[]Api_Card_Part) -> bool {
    e:=d.e
    if d.name!="" && d.name!=entity_name(w,e) {
        api_write_editable(s,call,w,e,d.path) or_return
        if !entity_rename(s,e,d.name) {api.call_failf(call,api.SERVER_ERROR,"%s.name: the entity cannot be renamed",d.path);return false}
    }
    local:=entity_local(w,e)
    rotation,scale:=api_card_place(s,d.card)
    if d.has_rotation {rotation=mm.quat_from_euler(d.rotation_deg*mm.RAD_PER_DEG)}
    target:=local
    target.position,target.scale=d.position,d.has_scale?d.scale:scale
    // The rotation scene.inspect gave keeps its quaternion: degrees do not say it to the last bit.
    angles:=d.has_rotation?d.rotation_deg:mm.quat_to_euler(rotation)*mm.DEG_PER_RAD
    if mm.quat_to_euler(local.rotation)*mm.DEG_PER_RAD!=angles {target.rotation=rotation}
    if d.sparse {
        if !d.has_position {target.position=local.position}
        if !d.has_rotation {target.rotation=local.rotation}
        if !d.has_scale {target.scale=local.scale}
    }
    if target!=local {
        api_write_editable(s,call,w,e,d.path) or_return
        if !transform_set(s,e,target) {api.call_failf(call,api.SERVER_ERROR,"%s: the entity has no Transform",d.path);return false}
    }
    if entity_has(w,e,erender.Hidden)!=d.hidden && (d.has_visible || !d.sparse) {
        if core.world_table_of(w,erender.Hidden)==nil {api.call_failf(call,api.SERVER_ERROR,"%s.visible: the world has no Hidden",d.path);return false}
        api_write_editable(s,call,w,e,d.path) or_return
        entity_hidden_set(s,e,d.hidden)
    }
    if entity_has(w,e,core.Disabled)!=d.disabled && (d.has_enabled || !d.sparse) {
        api_write_editable(s,call,w,e,d.path) or_return
        entity_enabled_set(s,e,!d.disabled)
    }
    core.world_settle(w)
    declared:=make([dynamic]^core.Table_Info,call.allocator)
    if d.components!="" {
        a:Rpc_Args
        rpc_init(&a,call,d.components)
        object:Rpc_Object
        if !rpc_object_begin(&a,"components") {return api_write_failed(call,d.path)}
        key:[64]u8
        for name in rpc_next(&a,&object) {
            given:=string(key[:copy(key[:],name)])
            path:=fmt.aprintf("%s.components.%s",d.path,given,allocator=call.allocator)
            t,problem:=api_component_named(shown_world(s),given)
            if t==nil || t.place!=.World {return rpc_fail(&a,"%s: %s; component.list lists them",path,problem)}
            if author.component_links(t.name) {return rpc_fail(&a,author.COMPONENT_LINKS_TEXT,path,given)}
            if !api_component_listed(s,t) {return rpc_fail(&a,"%s: %s is not written as a component: Transform, Name, Parent, Hidden and Disabled have their own keys (position, name, children, visible, enabled)",path,given)}
            if serial.text_keyword(&a.r,"null") {return rpc_fail(&a,"%s: the document declares the components the entity has; leave %s out to take it away",path,given)}
            if !api_write_component(s,&a,w,e,t,parts,path) {return false}
            append(&declared,t)
        }
        if a.failed {return false}
    }
    for part in parts {
        if slice.contains(declared[:],part.t) {continue}
        a:Rpc_Args
        rpc_init(&a,call,"{}")
        if !api_write_component(s,&a,w,e,part.t,parts,fmt.aprintf("%s.preset",d.path,allocator=call.allocator)) {return false}
        append(&declared,part.t)
    }
    // What the document leaves out goes, with what the editor added beside a component it declares;
    // of an instance it names by its prefab alone, it stays.
    for &t in s.info.tables {
        if d.sparse || !api_component_listed(s,&t) || slice.contains(declared[:],&t) || core.raw_find(core.world_table_at(w,&t),t.info,e)==nil {continue}
        api_write_editable(s,call,w,e,d.path) or_return
        component_remove(s,e,&t)
    }
    core.world_settle(w)
    off:=make([dynamic]^core.Table_Info,call.allocator)
    if d.off!="" {
        a:Rpc_Args
        rpc_init(&a,call,d.off)
        if !serial.text_accept(&a.r,'[') {api.call_failf(call,api.INVALID_PARAMS,"%s.off must be an array of names of components it declares",d.path);return false}
        for !serial.text_accept(&a.r,']') {
            if len(off)>0 && !serial.text_accept(&a.r,',') {api.call_failf(call,api.INVALID_PARAMS,"%s.off must be an array of names of components it declares",d.path);return false}
            text:[64]u8
            name,read:=rpc_text(&a,"off",text[:])
            if !read {return api_write_failed(call,d.path)}
            found:=component_table(s,name)
            if found==nil || !slice.contains(declared[:],found) {api.call_failf(call,api.INVALID_PARAMS,"%s.off: %s is not among the components it declares",d.path,name);return false}
            append(&off,found)
        }
    }
    for t in declared {
        _,turned_off,found:=core.raw_state(core.world_table_at(w,t),e)
        if !found || turned_off==slice.contains(off[:],t) {continue}
        api_write_editable(s,call,w,e,d.path) or_return
        component_turn(s,e,t,!turned_off)
    }
    core.world_settle(w)
    return true
}

// A component of the entity takes the value at the reader over the one it
// starts with: what its card gives, or what a new one has.
@(private)
api_write_component :: proc(s:^Session,a:^Rpc_Args,w:core.World_Ref,e:core.Entity,t:^core.Table_Info,parts:[]Api_Card_Part,path:string) -> bool {
    st:=api_state(s)
    size:=t.info.size
    start,memory:=make([]u8,max(size,1),a.call.allocator)
    bytes,more:=make([]u8,max(size,1),a.call.allocator)
    if memory!=nil || more!=nil {api.call_fail(a.call,api.INTERNAL_ERROR,"the request needs more scratch memory than the server has");return false}
    component_start(t,start[:size])
    for part in parts {
        if part.t==t {copy(start,part.value)}
    }
    current:=core.raw_find(core.world_table_at(w,t),t.info,e)
    if message,read:=component_value_read(w,t,current,&st.schema,st.types[api_table_index(s,t)],&a.r,bytes[:size],path,a.call.allocator,read_only_kept=true,from=start[:size]);!read {
        return rpc_fail(a,"%s",message)
    }
    if current!=nil && mem.compare(bytes[:size],([^]u8)(current)[:size])==0 {return true}
    api_write_editable(s,a.call,w,e,path) or_return
    component_add(s,e,t,raw_data(bytes))
    core.world_settle(w)
    return true
}

// The components a card gives, as the API shows them: made on an entity of
// its own that goes at once, inside the open edit.
@(private)
api_card_parts :: proc(s:^Session,w:core.World_Ref,card:int,allocator:runtime.Allocator) -> []Api_Card_Part {
    e:=core.create(core.world_entities(w))
    if made:=cards(s)[card].make;made!=nil {made(s,w,e)} else {preset_components(w,e,Preset(card))}
    core.world_settle(w)
    parts:=make([dynamic]Api_Card_Part,allocator)
    for part in author.entity_parts(w,e,allocator) {
        if api_component_listed(s,part.t) {append(&parts,Api_Card_Part{part.t,part.value})}
    }
    core.world_destroy_tree(w,e)
    core.world_settle(w)
    return parts[:]
}

// What a card gives the entity it makes besides components, and what an
// entity without one has: the rotation of a preset, the scale of a card.
@(private)
api_card_place :: proc(s:^Session,card:int) -> (rotation:mm.Quat,scale:[3]f32) {
    rotation,scale=1,{1,1,1}
    if card<0 {return}
    if card<len(Preset) {rotation=preset_rotation(Preset(card))}
    if c:=cards(s)[card];c.scale!={} {scale=c.scale}
    return
}

// ---------------------------------------------------------------- scene.inspect with root

// The subtree of root as the document scene.write takes, among what
// scene.inspect gives of the whole scene.
@(private)
api_inspect_tree :: proc(s:^Session,call:^api.Call,w:core.World_Ref,params:^Api_Inspect_Params) {
    if base.text_get(params.entity[:])!="" || base.text_get(params.name[:])!="" || base.text_get(params.component[:])!="" || params.offset!=0 || params.include_runtime || params.storages || base.text_get(params.storage[:])!="" {
        api.call_fail(call,api.INVALID_PARAMS,"root gives the whole subtree as the document scene.write takes: leave out entity, name, component, offset, include_runtime and storages; components [] gives it without components")
        return
    }
    root,known:=api_call_entity(call,w,params.root[:],"root")
    if !known {return}
    values,read:=api_inspect_values(s,call,w,false)
    if !read {return}
    if !values.listed {values.every=true}
    if text:=section_lock_text(s,w,root,true);text!="" {api.call_failf(call,api.SERVER_ERROR,"root: %s",text);return}
    part:=api_part(s,w,root,call.allocator)
    if len(part)>params.limit {
        api.call_failf(call,api.INVALID_PARAMS,"the subtree of root has %d entities, more than limit %d; raise limit up to 4096, or give a root lower in the tree",len(part),params.limit)
        return
    }
    st:=api_state(s)
    scratch,memory:=make([]u8,2*max(st.largest,1),call.allocator)
    if memory!=nil {api.call_fail(call,api.INTERNAL_ERROR,"the request needs more scratch memory than the server has");return}
    out:=call.out
    serial.text_write_raw(out,`{"path":`);serial.text_write_string(out,document_path(s.document))
    api.write_key(out,"dirty");api.write_flag(out,document_dirty(s))
    api.write_key(out,"playing");api.write_flag(out,s.mode!=.Edit)
    api.write_key(out,"total");serial.text_write_int(out,i64(core.world_entities(w).alive))
    api.write_key(out,"offset");serial.write_u8(out,'0')
    api.write_key(out,"entities");serial.write_u8(out,'[')
    api_tree_entity_write(s,w,out,root,scratch,values)
    serial.write_u8(out,']')
    api.write_key(out,"shown");serial.text_write_int(out,i64(len(part)))
    api.write_key(out,"matched");serial.text_write_int(out,i64(len(part)))
    api.write_key(out,"omitted");serial.write_u8(out,'0')
    serial.write_u8(out,'}')
}

@(private)
api_tree_entity_write :: proc(s:^Session,w:core.World_Ref,out:^serial.Writer,e:core.Entity,scratch:[]u8,values:Api_Inspect_Values) {
    st:=api_state(s)
    id:=api_entity_id(w,e)
    serial.text_write_raw(out,`{"id":`);api.write_id(out,id)
    api.write_key(out,"name");serial.text_write_string(out,entity_name(w,e))
    local:=entity_local(w,e)
    angles:=mm.quat_to_euler(local.rotation)*mm.DEG_PER_RAD
    if local.position!={} {api.write_key(out,"position");api.write_list(out,local.position[:])}
    if angles!={} {api.write_key(out,"rotation_deg");api.write_list(out,angles[:])}
    if local.scale!={1,1,1} {api.write_key(out,"scale");api.write_list(out,local.scale[:])}
    if entity_has(w,e,erender.Hidden) {api.write_key(out,"visible");api.write_flag(out,false)}
    if entity_has(w,e,core.Disabled) {api.write_key(out,"enabled");api.write_flag(out,false)}
    if link,linked:=prefab_link_of(w,e);linked {
        api.write_key(out,"prefab");serial.text_write_raw(out,`{"asset":`);api_asset_write(out,link.asset)
        api.write_key(out,"root");api.write_flag(out,link.root)
        serial.write_u8(out,'}')
    }
    value,start:=scratch[:len(scratch)/2],scratch[len(scratch)/2:]
    first,off_first:=true,true
    for &t,i in s.info.tables {
        if !api_inspect_wants(values,&t) || !api_component_listed(s,&t) {continue}
        table:=core.world_table_at(w,&t)
        current:=core.raw_find(table,t.info,e)
        if current==nil {continue}
        size:=t.info.size
        api_value_out(w,t.info,current,value)
        component_start(&t,start[:size])
        if first {api.write_key(out,"components");serial.write_u8(out,'{')}
        api.write_key(out,t.name,first)
        first=false
        serial.text_write_changed(out,&st.schema,st.types[i],value[:size],start[:size],omit_fields={.Transient,.Hidden})
    }
    if !first {serial.write_u8(out,'}')}
    for &t in s.info.tables {
        if !api_inspect_wants(values,&t) || !api_component_listed(s,&t) {continue}
        if _,turned_off,_:=core.raw_state(core.world_table_at(w,&t),e);!turned_off {continue}
        if off_first {api.write_key(out,"off");serial.write_u8(out,'[')} else {serial.write_u8(out,',')}
        off_first=false
        serial.text_write_string(out,t.name)
    }
    if !off_first {serial.write_u8(out,']')}
    children:=false
    for child in entity_children(w,e) {
        if !api_part_kept(s,w,child) {continue}
        if !children {api.write_key(out,"children");serial.write_u8(out,'[')} else {serial.write_u8(out,',')}
        children=true
        api_tree_entity_write(s,w,out,child,scratch,values)
    }
    if children {serial.write_u8(out,']')}
    serial.write_u8(out,'}')
}

