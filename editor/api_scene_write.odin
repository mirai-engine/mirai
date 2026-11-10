package editor

import "base:runtime"
import "core:mem"
import "core:strings"
import "mirai:asset"
import "mirai:cook/author"
import "mirai:core"
import "mirai:editor/api"
import "mirai:editor/history"
import erender "mirai:engine/render"
import "mirai:std/base"
import "mirai:std/serial"

// scene.write and scene.inspect with root: the document of a scene
// (cook/author/scene_document.odin) on the world the editor edits. The
// document is read, matched and applied by cook/author, as mirai scene write
// does to a file; here are the rows it changes, each through the edits of the
// editor, so a write is one step of undo. Entities without an Id and what a
// section holds are not part of a document.

Api_Write_Result :: struct {
    id:base.Entity_Id `mirai:"label=The first entity the document declares: root or the one it made"`,
    made:int `mirai:"label=Entities the document made"`,
    removed:int `mirai:"label=Entities it took away with what hung from them"`,
    disabled:int `mirai:"label=Members of an instance of a prefab it turned off instead of taking them away"`,
    created:[]Api_Write_Made `mirai:"label=The entities of the document it made in its order; of a prefab it placed the root of the instance, whose members hang from it"`,
}
Api_Write_Made :: struct {
    id:base.Entity_Id,
    name:string,
}

// The params of scene.write: a document of scene_document.odin, which
// cook/author reads from the text.
Api_Scene_Write_Params :: struct {
    root:string `mirai:"entity,optional,label=by its name, a path Parent/Child or its id, the entity the document declares with what hangs from it: entities holds that one entity. Left out: entities are those at the top of the scene"`,
    merge:bool `mirai:"optional,label=true: what the document leaves out stays as it is (entities, components, fields, places): it names only what it changes or adds. Left out: the document declares all there is under root, or in the scene without root, and what it leaves out goes"`,
    entities:[]Api_Scene_Write_Entity `mirai:"label=the entities, nesting what hangs from each by children; matched by id, else by name among siblings, else (not in a merge) by place, and the others are made"`,
}
Api_Scene_Write_Entity :: struct {
    id:string `mirai:"optional,label=matches the entity with this id, which goes under the entity the document nests it in; in a merge, one at the top of the document stays under the parent it has"`,
    name:string `mirai:"optional,label=without id, matches the entity of this name among those of its parent; none: it is made"`,
    preset:string `mirai:"optional,label=a preset or the card of a plugin (cube, sphere, plane, point_light, sun, camera, spawn...): it gives a new entity its components, whose fields components changes, and the rotation and scale it has when those are left out"`,
    prefab:serial.Json `mirai:"optional,label=on a new entity, the path or the id of a .scene with one root: it is placed as a linked instance, and what the entity and those under it leave out stays as the prefab gives it, also in a later write that names it the same way; on an entity that is there, {asset, root} as scene.inspect gives it declares all it has; a write changes no link of an entity that is there"`,
    copy:string `mirai:"optional,label=on a new entity, the entity it is a copy of, by its name, a path Parent/Child or its id: copied with what hangs from it and new ids, beside that entity unless the document nests it under another; what the entity and those under it say changes the copy"`,
    delete:bool `mirai:"optional,label=true takes the entity away with what hangs from it; it declares nothing else. A member of an instance of a prefab is turned off instead"`,
    position:[3]f32 `mirai:"optional,label=local to the parent; [0,0,0] when left out"`,
    rotation_deg:[3]f32 `mirai:"optional,label=[0,0,0] or that of its preset when left out"`,
    scale:[3]f32 `mirai:"optional,label=[1,1,1] or that of its preset when left out"`,
    visible:bool `mirai:"optional,label=true when left out"`,
    enabled:bool `mirai:"optional,label=true when left out; false turns the entity and everything under it off: their components keep their values and no system sees them"`,
    components:serial.Json `mirai:"optional,label=by name the components it has besides those of its preset, each with the fields that differ from the value it starts with; those it leaves out go. In a merge: the fields to change of each, and null takes a component away"`,
    off:[]string `mirai:"optional,label=the components it declares that are turned off by themselves, keeping their values; those it declares and does not list are on. In a merge without off nothing turns"`,
    children:[]serial.Json `mirai:"optional,label=the entities that hang from it, in order, each with these keys"`,
}

// What the rows of a write are changed with.
@(private)
Api_Write :: struct {
    s:^Session,
    call:^api.Call,
    w:core.World_Ref,
    scratch:[]u8, // two values of the largest component
}

@(private)
api_scene_write_register :: proc(s:^Session,st:^Api_State) {
    api_register(s,st,{name="scene.write",flags={.Core,.Destructive},params=Api_Scene_Write_Params,summary="The one way to change the entities of the scene: makes it say what a document of nested entities declares, as scene.inspect with root gives it. Entities are matched by id or name, the others made (with preset, with prefab as a linked instance, with copy from another entity). What the document leaves out goes, or with merge stays: then it names only what changes, and delete takes an entity away. One step of undo; the result names what it made.",result=Api_Write_Result,run=api_scene_write})
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

@(private)
api_scene_write :: proc(s:^Session,call:^api.Call) {
    // The step of a gesture of the person is named as its entry.
    label:="Write entities"
    if api_person(s) {
        switch {
        case strings.contains(call.raw,CONTEXT_COPIED): label="Paste"
        case strings.contains(call.raw,`"copy"`):       label="Duplicate"
        case strings.contains(call.raw,`"delete"`):     label="Delete"
        }
    }
    if !api_edit_begin(s,call,label) {return}
    w:=edited_world(s)
    a:Api_Write
    target,ready:=api_write_target(s,call,&a)
    reading:=author.Reading{allocator=call.allocator,raw=call.raw,assets={s,asset_text_resolve}}
    applied:author.Scene_Applied
    if ready {
        if applied,ready=author.scene_apply(&target,&reading,call.raw);!ready && !call.failed {
            api.call_fail(call,api.SERVER_ERROR if reading.internal else api.INVALID_PARAMS,reading.problem)
        }
    }
    core.world_settle(w)
    // A person goes on with what the step made: it is what it leaves selected.
    if ready && api_person(s) && len(applied.created)>0 {history.selection_set(document_selection(s),transmute([]core.Entity)applied.created[:])}
    if !api_edit_end(s,call,ready) {return}
    created:=make([]Api_Write_Made,len(applied.created),call.allocator)
    for node,i in applied.created {created[i]={api_entity_id(w,core.Entity(node)),entity_name(w,core.Entity(node))}}
    api.call_result(call,Api_Write_Result)^={applied.id,applied.made,applied.removed,applied.disabled,created}
}

// Why nothing is added or moved under parent, the top for 0, now; "" when it can be.
@(private="file")
api_write_refused :: proc(a:^Api_Write,parent:author.Node) -> string {
    _,reason:=section_target_texts(a.s,a.w,core.Entity(parent) if parent!=0 else section_editing(a.s))
    return reason
}

// A component of the entity takes the value of the document over the one it
// starts with (from: what its card gives), or with merge over the one it has.
@(private="file")
api_write_component :: proc(a:^Api_Write,reading:^author.Reading,e:core.Entity,t:^core.Table_Info,text,path:string,from:[]u8,merge:bool) -> (changed,ok:bool) {
    s,w:=a.s,a.w
    st:=api_state(s)
    size:=t.info.size
    start,bytes:=a.scratch[:size],a.scratch[len(a.scratch)/2:][:size]
    component_start(t,start)
    copy(start,from)
    current:=core.raw_find(core.world_table_at(w,t),t.info,e)
    r:serial.Text_Reader
    author.reading_reader(reading,&r,text)
    message,read:=component_value_read(w,t,current,&st.schema,st.types[api_table_index(s,t)],&r,bytes,path,reading.allocator,read_only_kept=true,from=nil if merge && current!=nil else start)
    if !read {author.reading_fail(reading,message);return}
    if current!=nil && mem.compare(bytes,([^]u8)(current)[:size])==0 {return false,true}
    component_add(s,e,t,raw_data(bytes))
    core.world_settle(w)
    return true,true
}

// The components a card gives, as the API shows them: made on an entity of
// its own that goes at once, inside the open edit.
@(private="file")
api_card_parts :: proc(s:^Session,w:core.World_Ref,card:int,allocator:runtime.Allocator) -> []author.Part {
    e:=core.create(core.world_entities(w))
    if made:=cards(s)[card].make;made!=nil {made(s,w,e)} else {preset_components(w,e,Preset(card))}
    core.world_settle(w)
    parts:=make([dynamic]author.Part,allocator)
    for part in author.entity_parts(w,e,allocator) {
        if api_component_listed(s,part.t) {append(&parts,part)}
    }
    core.world_destroy_tree(w,e)
    core.world_settle(w)
    return parts[:]
}

// The world the editor edits as what a document is read from and written to.
// False after failing the call.
@(private)
api_write_target :: proc(s:^Session,call:^api.Call,a:^Api_Write) -> (target:author.Scene_Target,ok:bool) {
    st:=api_state(s)
    scratch,memory:=make([]u8,2*max(st.largest,1),call.allocator)
    if memory!=nil {api.call_fail(call,api.INTERNAL_ERROR,"the request needs more scratch memory than the server has");return}
    a^={s,call,edited_world(s),scratch}
    tables:=make([dynamic]^core.Table_Info,call.allocator)
    for &t in s.info.tables {
        if api_component_listed(s,&t) {append(&tables,&t)}
    }
    return {
        user=a,tables=tables[:],lists="component.list lists them",
        assets=author.assets_of(s.app.assets),into=s.document.id,
        find=proc(user:rawptr,id:base.Entity_Id) -> (author.Node,string) {
            a:=(^Api_Write)(user)
            e:=api_entity(a.w,id)
            return author.Node(e),section_lock_text(a.s,a.w,e,true) if e!=core.NONE else ""
        },
        named=proc(user:rawptr,text,what:string,allocator:runtime.Allocator) -> ([]author.Node,string) {
            a:=(^Api_Write)(user)
            found,known:=api_call_targets(a.call,a.w,transmute([]u8)text,what)
            if !known {return nil,a.call.error.message}
            for e in found {
                if locked:=section_lock_text(a.s,a.w,e,true);locked!="" {return nil,strings.concatenate({what,": ",locked},allocator)}
            }
            return transmute([]author.Node)found,""
        },
        children=proc(user:rawptr,parent:author.Node,allocator:runtime.Allocator) -> []author.Node {
            a:=(^Api_Write)(user)
            found:=make([dynamic]author.Node,allocator)
            if parent!=0 {
                for e in entity_children(a.w,core.Entity(parent),allocator) {
                    if api_part_kept(a.s,a.w,e) {append(&found,author.Node(e))}
                }
            } else if transforms:=core.world_table_of(a.w,core.Transform);transforms!=nil {
                for e in transforms.entities {
                    if entity_parent(a.w,e)==core.NONE && api_part_kept(a.s,a.w,e) {append(&found,author.Node(e))}
                }
            }
            return found[:]
        },
        entity=proc(user:rawptr,node:author.Node) -> author.Node_Info {
            a:=(^Api_Write)(user)
            w,e:=a.w,core.Entity(node)
            parent,_:=entity_get(w,e,core.Parent)
            link,_:=prefab_link_of(w,e)
            return {
                id=api_entity_id(w,e),name=entity_name(w,e),parent=author.Node(entity_parent(w,e)),order=int(parent.order),local=core.from_math(entity_local(w,e)),
                hidden=entity_has(w,e,erender.Hidden),disabled=entity_has(w,e,core.Disabled),prefab=link.asset,instance=author.Node(link.instance),
            }
        },
        has=proc(user:rawptr,node:author.Node,t:^core.Table_Info) -> (has,off:bool) {
            a:=(^Api_Write)(user)
            _,off,has=core.raw_state(core.world_table_at(a.w,t),core.Entity(node))
            return
        },
        text=proc(user:rawptr,out:^serial.Writer,node:author.Node,t:^core.Table_Info) {
            a:=(^Api_Write)(user)
            st:=api_state(a.s)
            size:=t.info.size
            value,start:=a.scratch[:size],a.scratch[len(a.scratch)/2:][:size]
            api_value_out(a.w,t.info,core.raw_find(core.world_table_at(a.w,t),t.info,core.Entity(node)),value)
            component_start(t,start)
            serial.text_write_changed(out,&st.schema,st.types[api_table_index(a.s,t)],value,start,omit_fields={.Transient,.Hidden})
        },
        preset=proc(user:rawptr,name:string,allocator:runtime.Allocator) -> (preset:author.Scene_Preset,problem:string) {
            a:=(^Api_Write)(user)
            card,found:=card_named(a.s,name)
            if !found {return {},cards_problem(a.s,name)}
            preset={name=name,rotation=1,scale={1,1,1},parts=api_card_parts(a.s,a.w,card,allocator)}
            if card<len(Preset) {preset.rotation=preset_rotation(Preset(card))}
            if c:=cards(a.s)[card];c.scale!={} {preset.scale=c.scale}
            return
        },
        create=proc(user:rawptr,parent:author.Node,name:string,preset:author.Scene_Preset,id:base.Entity_Id) -> (author.Node,string) {
            a:=(^Api_Write)(user)
            if reason:=api_write_refused(a,parent);reason!="" {return 0,reason}
            card:=-1
            if preset.name!="" {card,_=card_named(a.s,preset.name)}
            e:=entity_create(a.s,{card=card,parent=core.Entity(parent),name=name,named=name!=""})
            core.world_settle(a.w)
            return author.Node(e),"the entity cannot be made there: its parent has no size in some axis" if e==core.NONE else ""
        },
        place=proc(user:rawptr,prefab:^asset.Scene,id:base.Asset_Id,parent:author.Node) -> (author.Node,int,string) {
            a:=(^Api_Write)(user)
            if reason:=api_write_refused(a,parent);reason!="" {return 0,0,reason}
            // What the document leaves out of the place of the root is what its prefab gives it.
            source,_:=asset.prefab_root(prefab)
            local,placed:=asset.scene_get(prefab,source,"Transform",core.Transform)
            if !placed {local=core.TRANSFORM_IDENTITY}
            instantiated,error:=prefab_instantiate(a.s,id,{parent=core.Entity(parent),position=local.position,rotation={local.rotation.x,local.rotation.y,local.rotation.z,local.rotation.w}},true)
            root:=api_entity(a.w,instantiated)
            if error==.None && root==core.NONE {error=.Rejected}
            if error!=.None {return 0,0,prefab_error_text(error)}
            return author.Node(root),len(prefab_members(a.w,root)),""
        },
        copy=proc(user:rawptr,sources:[]author.Node,allocator:runtime.Allocator) -> ([]author.Node,int,string) {
            a:=(^Api_Write)(user)
            before:=core.world_entities(a.w).alive
            copies:=entities_duplicate(a.s,transmute([]core.Entity)sources,"Duplicate",allocator)
            core.world_settle(a.w)
            return transmute([]author.Node)copies,core.world_entities(a.w).alive-before,"nothing was copied" if len(copies)==0 else ""
        },
        reparent=proc(user:rawptr,node,parent:author.Node) -> string {
            a:=(^Api_Write)(user)
            if reason:=api_write_refused(a,parent);reason!="" {return reason}
            if !entity_reparent(a.s,core.Entity(node),core.Entity(parent)) {return "it cannot go there: its new parent hangs from it, or has no size in some axis"}
            core.world_settle(a.w)
            return ""
        },
        rename=proc(user:rawptr,node:author.Node,name:string) -> string {
            a:=(^Api_Write)(user)
            return "" if entity_rename(a.s,core.Entity(node),name) else "the entity cannot be renamed"
        },
        move=proc(user:rawptr,node:author.Node,local:core.Transform) -> string {
            a:=(^Api_Write)(user)
            return "" if transform_set(a.s,core.Entity(node),core.to_math(local)) else "the entity has no Transform"
        },
        mark=proc(user:rawptr,node:author.Node,hidden,on:bool) -> string {
            a:=(^Api_Write)(user)
            if hidden {
                if core.world_table_of(a.w,erender.Hidden)==nil {return "the world has no Hidden"}
                entity_hidden_set(a.s,core.Entity(node),on)
            } else {
                entity_enabled_set(a.s,core.Entity(node),!on)
            }
            core.world_settle(a.w)
            return ""
        },
        order=proc(user:rawptr,node:author.Node,order:int) {
            entity_order_set((^Api_Write)(user).s,core.Entity(node),i32(order))
        },
        write=proc(user:rawptr,reading:^author.Reading,node:author.Node,t:^core.Table_Info,text,path:string,from:[]u8,merge:bool) -> (changed,ok:bool) {
            return api_write_component((^Api_Write)(user),reading,core.Entity(node),t,text,path,from,merge)
        },
        drop=proc(user:rawptr,node:author.Node,t:^core.Table_Info) {
            a:=(^Api_Write)(user)
            component_remove(a.s,core.Entity(node),t)
            core.world_settle(a.w)
        },
        turn=proc(user:rawptr,node:author.Node,t:^core.Table_Info,off:bool) {
            a:=(^Api_Write)(user)
            component_turn(a.s,core.Entity(node),t,off)
            core.world_settle(a.w)
        },
        remove=proc(user:rawptr,nodes:[]author.Node) -> (int,string) {
            a:=(^Api_Write)(user)
            before:=core.world_entities(a.w).alive
            entities_delete(a.s,transmute([]core.Entity)nodes)
            core.world_settle(a.w)
            return before-core.world_entities(a.w).alive,""
        },
    },true
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
    if text:=section_lock_text(s,w,root,true);text!="" {api.call_failf(call,api.SERVER_ERROR,"root: %s",text);return}
    part:=api_part(s,w,root,call.allocator)
    if len(part)>params.limit {
        api.call_failf(call,api.INVALID_PARAMS,"the subtree of root has %d entities, more than limit %d; raise limit up to 4096, or give a root lower in the tree",len(part),params.limit)
        return
    }
    a:Api_Write
    target,ready:=api_write_target(s,call,&a)
    if !ready {return}
    out:=call.out
    serial.text_write_raw(out,`{"path":`);serial.text_write_string(out,document_path(s.document))
    api.write_key(out,"dirty");api.write_flag(out,document_dirty(s))
    api.write_key(out,"playing");api.write_flag(out,s.mode!=.Edit)
    api.write_key(out,"total");serial.text_write_int(out,i64(core.world_entities(w).alive))
    api.write_key(out,"offset");serial.write_u8(out,'0')
    api.write_key(out,"entities");serial.write_u8(out,'[')
    author.scene_entity_write(&target,out,author.Node(root),values.only if values.listed else target.tables)
    serial.write_u8(out,']')
    api.write_key(out,"shown");serial.text_write_int(out,i64(len(part)))
    api.write_key(out,"matched");serial.text_write_int(out,i64(len(part)))
    api.write_key(out,"omitted");serial.write_u8(out,'0')
    serial.write_u8(out,'}')
}

// The shape of the params of scene.write.
