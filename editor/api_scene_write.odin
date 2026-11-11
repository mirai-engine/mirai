package editor

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:strings"
import "mirai:asset"
import "mirai:cook/author"
import "mirai:core"
import "mirai:editor/api"
import "mirai:editor/history"
import erender "mirai:engine/render"
import scene "mirai:engine/scene"
import "mirai:host"
import "mirai:std/base"
import mm "mirai:std/math"
import "mirai:std/serial"

// scene.write and scene.inspect with root: the document of a scene
// (cook/author/scene_document.odin) on the world the editor edits, or on the
// game of the caller that plays. The document is read, matched and applied by
// cook/author, as mirai scene write does to a file; here are the rows it
// changes. Of the document each goes through the edits of the editor, so a
// write is one step of undo, and entities without an Id and what a section
// holds are not part of it. Of a game they change as the game changes itself
// between two ticks: no history, no lock, a place is a teleport and a prefab
// is spawned; a write that fails puts the game back as it was.

// The world a write or an inspect is aimed at.
Api_World :: enum u8 {Scene,Game}

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
    world:Api_World `mirai:"optional,label=Game: the game of the caller that plays (that of its turn, or the Play of the user outside a turn) in place of the document, as the game changes itself between two ticks: no step of undo, a position is a teleport, a prefab is spawned, Entity fields hold handles and an id may be a handle. A game takes no replace and no kind"`,
    player:int `mirai:"optional,min=0,max=3,label=world Game: the run of that player of a game a turn plays on the network"`,
    select:bool `mirai:"optional,label=true: the entities it made are what the editor has selected after it"`,
    root:string `mirai:"entity,optional,label=by its name, a path Parent/Child or its id, the entity the document declares with what hangs from it: entities holds that one entity. Left out: entities are those at the top of the scene"`,
    replace:bool `mirai:"optional,label=true: the document declares all there is under root, or in the scene without root, and what it leaves out goes: entities, components and fields. Left out: what it leaves out stays as it is, and it names only what it changes or adds"`,
    kind:Document_Kind `mirai:"optional,label=what the document is from now on, which Save writes: a scene, shown in its own light, or a prefab, with exactly one root, shown in the studio light and placed as instances. Left out: it stays what it is"`,
    entities:[]Api_Scene_Write_Entity `mirai:"label=the entities, nesting what hangs from each by children; matched by id, else by name among siblings, else (with replace) by place, and the others are made"`,
}
Api_Scene_Write_Entity :: struct {
    id:string `mirai:"optional,label=matches the entity with this id, which goes under the entity the document nests it in; one at the top of the document stays under the parent it has, unless replace"`,
    name:string `mirai:"optional,label=without id, matches the entity of this name among those of its parent; none: it is made"`,
    preset:string `mirai:"optional,label=a preset or the card of a plugin (cube, sphere, plane, point_light, sun, camera, spawn...): it gives a new entity its components, whose fields components changes, and the rotation and scale it has when those are left out"`,
    prefab:serial.Json `mirai:"optional,label=on a new entity, the path or the id of a prefab: it is placed as a linked instance, and what the entity and those under it leave out stays as the prefab gives it, also in a later write that names it the same way; on an entity that is there, {asset, root} as scene.inspect gives it declares all it has; a write changes no link of an entity that is there"`,
    group:[]string `mirai:"optional,label=on a new entity at the top of the document, the entities it takes under it, by name, path or id: it is made at their center, where they hang from when they share a parent, and they stay where they are in the world"`,
    copy:string `mirai:"optional,label=on a new entity, the entity it is a copy of, by its name, a path Parent/Child or its id: copied with what hangs from it and new ids, beside that entity unless the document nests it under another; what the entity and those under it say changes the copy"`,
    delete:bool `mirai:"optional,label=true takes the entity away with what hangs from it; it declares nothing else. A member of an instance of a prefab is turned off instead"`,
    position:[3]f32 `mirai:"optional,label=local to the parent; [0,0,0] when left out"`,
    rotation_deg:[3]f32 `mirai:"optional,label=[0,0,0] or that of its preset when left out"`,
    scale:[3]f32 `mirai:"optional,label=[1,1,1] or that of its preset when left out"`,
    visible:bool `mirai:"optional,label=true when left out"`,
    enabled:bool `mirai:"optional,label=true when left out; false turns the entity and everything under it off: their components keep their values and no system sees them"`,
    components:serial.Json `mirai:"optional,label=by name the fields to change of each component, which it gets when it has none; null takes a component away. With replace: the components it has besides those of its preset, each with the fields that differ from the value it starts with, and those it leaves out go"`,
    off:[]string `mirai:"optional,label=the components it declares that are turned off by themselves, keeping their values; those it declares and does not list are on. Left out, nothing turns, unless replace"`,
    children:[]serial.Json `mirai:"optional,label=the entities that hang from it, in order, each with these keys"`,
}

// What the rows of a write are changed with.
@(private)
Api_Write :: struct {
    s:^Session,
    call:^api.Call,
    w:core.World_Ref,
    run:^Run,     // of the game it writes; nil: the document
    scratch:[]u8, // two values of the largest component
}

@(private)
api_scene_write_register :: proc(s:^Session,st:^Api_State) {
    api_register(s,st,{name="scene.write",flags={.Core,.Destructive},params=type_info_of(Api_Scene_Write_Params),summary="The one way to change the entities of the scene: a document of nested entities, as scene.inspect with root gives it, that names what changes. Entities are matched by id or name, the others made (with preset, with prefab as a linked instance, with copy from another entity), and delete takes one away; what the document leaves out stays, or with replace goes. One step of undo; the result names what it made.",result=type_info_of(Api_Write_Result),can=api_scene_write_can,run=api_scene_write})
}

// The entities of the part of a world a document declares: root and what
// hangs from it, in pre-order; of the document, without entities that have no
// Id or are of a section, nor what hangs from them.
@(private)
api_part :: proc(a:^Api_Write,root:core.Entity,allocator:runtime.Allocator) -> []core.Entity {
    h:=entity_hierarchy(a.w)
    out:=make([dynamic]core.Entity,allocator)
    at:=root
    for at!=core.NONE {
        kept:=at==root || api_part_kept(a,at)
        if kept {append(&out,at)}
        at=core.subtree_next(h,root,at,kept)
    }
    return out[:]
}

@(private)
api_part_kept :: proc(a:^Api_Write,e:core.Entity) -> bool {
    return a.run!=nil || api_entity_id(a.w,e)!=0 && !section_locked(a.s,a.w,e)
}

// The world a call aims at: the document, or with world Game the game of the
// caller, which own says the call changes. False after failing the call.
@(private)
api_write_world :: proc(s:^Session,call:^api.Call,a:^Api_Write,world:Api_World,player:int,own:bool) -> bool {
    a^={s=s,call=call,w=edited_world(s)}
    if world==.Scene {return true}
    if own {a.run,_=api_play_own_run(s,call,player)} else if a.run,_=api_play_run(s,call,player);a.run==nil {api_no_game(call)}
    a.w=run_ref(s,a.run)
    return a.run!=nil
}

// A document that names no entity and no other kind than the one the scene is changes nothing.
@(private)
api_scene_write_can :: proc(s:^Session,params:rawptr) -> string {
    p:=(^Api_Scene_Write_Params)(params)
    if p==nil || len(p.entities)>0 || p.replace || p.root!="" || p.world==.Scene && document_is_prefab(s)!=(p.kind==.Prefab) {return ""}
    return "The document names nothing to change: no entity, and no other kind than the one the scene is"
}

@(private)
api_scene_write :: proc(s:^Session,call:^api.Call) {
    p:=api.call_params(call,Api_Scene_Write_Params)
    a:Api_Write
    if !api_write_world(s,call,&a,p.world,p.player,true) {return}
    // The game as it was, put back when the write fails.
    kept:rawptr
    defer if kept!=nil {host.app_world_free(s.app,kept)}
    if a.run!=nil {
        if api.call_given(call,"replace") || api.call_given(call,"kind") {
            api.call_fail(call,api.INVALID_PARAMS,"replace and kind are of the document: a game that plays takes what the document names, and scene.write without world changes the scene it started from")
            return
        }
        if kept=host.app_world_create(s.app);kept==nil || !core.world_copy(s.info,kept,a.run.world) {
            api.call_fail(call,api.INTERNAL_ERROR,"there is no memory to keep the game as it was while it is written")
            return
        }
    } else if !api_edit_begin(s,call,"Write entities") {return}
    target,ready:=api_write_target(&a)
    reading:=author.Reading{allocator=call.allocator,raw=call.raw,assets={s,asset_text_resolve}}
    applied:author.Scene_Applied
    if ready {
        if applied,ready=author.scene_apply(&target,&reading,call.raw,also={"world","player","select"});!ready && !call.failed {
            api.call_fail(call,api.SERVER_ERROR if reading.internal else api.INVALID_PARAMS,reading.problem)
        }
    }
    core.world_settle(a.w)
    if ready && p.select && len(applied.created)>0 && (a.run==nil || a.w.data==shown_world(s).data) {
        history.selection_set(document_selection(s) if a.run==nil else s.selection,transmute([]core.Entity)applied.created[:])
    }
    if a.run!=nil {
        if !ready {core.world_swap(s.info,a.run.world,kept);return}
        run_tell_call(s,a.run,"scene.write",call.raw)
    } else if !api_edit_end(s,call,ready) {return}
    created:=make([]Api_Write_Made,len(applied.created),call.allocator)
    for node,i in applied.created {created[i]={api_write_id(&a,core.Entity(node)),entity_name(a.w,core.Entity(node))}}
    api.call_result(call,Api_Write_Result)^={applied.id,applied.made,applied.removed,applied.disabled,created}
}

// What names an entity in a document: its id, or in a game its handle when it has none.
@(private="file")
api_write_id :: proc(a:^Api_Write,e:core.Entity) -> base.Entity_Id {
    id:=api_entity_id(a.w,e)
    return base.Entity_Id(e) if id==0 && a.run!=nil else id
}

// Why nothing is added or moved under parent, the top for 0, now; "" when it can be.
@(private="file")
api_write_refused :: proc(a:^Api_Write,parent:author.Node) -> string {
    _,reason:=section_target_texts(a.s,a.w,core.Entity(parent) if parent!=0 else section_editing(a.s))
    return reason
}

// A component of the entity takes the value of the document over the one it
// starts with (from: what its card gives), or with merge the one it has.
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
    message,read:=component_value_read(w,t,current,&st.schema,st.types[api_table_index(s,t)],&r,bytes,path,reading.allocator,read_only_kept=true,from=nil if merge && current!=nil else start,handles=a.run!=nil)
    if !read {author.reading_fail(reading,message);return}
    if current!=nil && mem.compare(bytes,([^]u8)(current)[:size])==0 {return false,true}
    if a.run!=nil {core.raw_add(core.world_table_at(w,t),t.info,e,raw_data(bytes))} else {component_add(s,e,t,raw_data(bytes))}
    core.world_settle(w)
    return true,true
}

// The world a write aims at as what a document is read from and written to.
// False after failing the call.
@(private)
api_write_target :: proc(a:^Api_Write) -> (target:author.Scene_Target,ok:bool) {
    s,call:=a.s,a.call
    st:=api_state(s)
    memory:runtime.Allocator_Error
    if a.scratch,memory=make([]u8,2*max(st.largest,1),call.allocator);memory!=nil {api.call_fail(call,api.INTERNAL_ERROR,"the request needs more scratch memory than the server has");return}
    tables:=make([dynamic]^core.Table_Info,call.allocator)
    for &t in s.info.tables {
        if api_component_listed(s,&t,a.run!=nil) {append(&tables,&t)}
    }
    return {
        user=a,tables=tables[:],lists="component.list lists them",
        assets=author.assets_of(s.app.assets),into=s.document.id if a.run==nil else {},
        find=proc(user:rawptr,id:base.Entity_Id) -> (author.Node,string) {
            a:=(^Api_Write)(user)
            e:=api_entity(a.w,id)
            if a.run!=nil {return author.Node(e if e!=core.NONE || !core.alive(core.world_entities(a.w),core.Entity(id)) else core.Entity(id)),""}
            return author.Node(e),section_lock_text(a.s,a.w,e,true) if e!=core.NONE else ""
        },
        named=proc(user:rawptr,text,what:string,allocator:runtime.Allocator) -> (author.Node,string) {
            a:=(^Api_Write)(user)
            e,problem:=api_entity_select(a.w,text,what,a.run!=nil,allocator)
            if problem=="" && a.run==nil {
                if locked:=section_lock_text(a.s,a.w,e,true);locked!="" {problem=strings.concatenate({what,": ",locked},allocator)}
            }
            return author.Node(e),problem
        },
        children=proc(user:rawptr,parent:author.Node,allocator:runtime.Allocator) -> []author.Node {
            a:=(^Api_Write)(user)
            found:=make([dynamic]author.Node,allocator)
            if parent!=0 {
                for e in entity_children(a.w,core.Entity(parent),allocator) {
                    if api_part_kept(a,e) {append(&found,author.Node(e))}
                }
            } else if transforms:=core.world_table_of(a.w,core.Transform);transforms!=nil {
                for e in transforms.entities {
                    if entity_parent(a.w,e)==core.NONE && api_part_kept(a,e) {append(&found,author.Node(e))}
                }
            }
            return found[:]
        },
        entity=proc(user:rawptr,node:author.Node) -> author.Node_Info {
            a:=(^Api_Write)(user)
            w,e:=a.w,core.Entity(node)
            parent,_:=entity_get(w,e,core.Parent)
            info:=author.Node_Info{
                id=api_write_id(a,e),name=entity_name(w,e),parent=author.Node(entity_parent(w,e)),order=int(parent.order),local=core.from_math(entity_local(w,e)),
                hidden=entity_has(w,e,erender.Hidden),disabled=entity_has(w,e,core.Disabled),
            }
            // What links an entity to its prefab locks nothing of a game that plays.
            if link,linked:=prefab_link_of(w,e);linked && a.run==nil {info.prefab,info.instance=link.asset,author.Node(link.instance)}
            return info
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
            api_value_out(a.w,t.info,core.raw_find(core.world_table_at(a.w,t),t.info,core.Entity(node)),value,a.run!=nil)
            component_start(t,start)
            serial.text_write_changed(out,&st.schema,st.types[api_table_index(a.s,t)],value,start,omit_fields={.Transient,.Hidden})
        },
        // A recipe is placed on an entity of its own that goes at once, inside the open edit.
        preset=proc(user:rawptr,name:string,allocator:runtime.Allocator) -> (preset:author.Scene_Preset,problem:string) {
            a:=(^Api_Write)(user)
            recipe,found:=recipe_of(a.s,name)
            if !found {return {},recipes_problem(a.s,name)}
            all:[]author.Part
            if all,problem=author.recipe_parts(a.w,&a.s.app.assets.types,recipe,allocator);problem!="" {return}
            parts:=make([dynamic]author.Part,allocator)
            for part in all {
                if api_component_listed(a.s,part.t) {append(&parts,part)}
            }
            return {recipe=recipe,parts=parts[:]},""
        },
        create=proc(user:rawptr,parent:author.Node,name:string,preset:author.Scene_Preset,id:base.Entity_Id) -> (author.Node,string) {
            a:=(^Api_Write)(user)
            desc:=Create_Desc{recipe=preset.name,parent=core.Entity(parent),name=name,named=name!=""}
            e:core.Entity
            if a.run!=nil {e=entity_make(a.s,a.w,desc)} else {
                if reason:=api_write_refused(a,parent);reason!="" {return 0,reason}
                e=entity_create(a.s,desc)
            }
            core.world_settle(a.w)
            return author.Node(e),"the entity cannot be made there: its parent has no size in some axis" if e==core.NONE else ""
        },
        place=proc(user:rawptr,prefab:^asset.Scene,id:base.Asset_Id,parent:author.Node) -> (author.Node,int,string) {
            a:=(^Api_Write)(user)
            s,w:=a.s,a.w
            // What the document leaves out of the place of the root is what its prefab gives it.
            source,_:=asset.prefab_root(prefab)
            local,placed:=asset.scene_get(prefab,source,"Transform",core.Transform)
            if !placed {local=core.TRANSFORM_IDENTITY}
            before:=core.world_entities(w).alive
            if a.run!=nil {
                // As the game spawns one, with what waits for its prefab read now.
                report,error:=scene.spawn_prefab(core.commands_of(w),s.app.assets,{prefab=id,parent=core.Entity(parent),transform=local})
                if error!=.None {return 0,0,scene.error_text(error)}
                core.world_settle(w)
                scene.spawns_fill(w,s.app,core.world_storage_of(core.world_ref(s.app.shared,s.app.info,.Shared),scene.Prefab_Warms),core.world_storage_of(w,core.Problems),all=true)
                core.world_settle(w)
                return author.Node(report.root),core.world_entities(w).alive-before,""
            }
            if reason:=api_write_refused(a,parent);reason!="" {return 0,0,reason}
            instantiated,error:=prefab_instantiate(s,id,{parent=core.Entity(parent),position=local.position,rotation={local.rotation.x,local.rotation.y,local.rotation.z,local.rotation.w}},true)
            root:=api_entity(w,instantiated)
            if error==.None && root==core.NONE {error=.Rejected}
            if error!=.None {return 0,0,prefab_error_text(error)}
            return author.Node(root),len(prefab_members(w,root)),""
        },
        copy=proc(user:rawptr,sources:[]author.Node,allocator:runtime.Allocator) -> ([]author.Node,int,string) {
            a:=(^Api_Write)(user)
            before:=core.world_entities(a.w).alive
            entities:=transmute([]core.Entity)sources
            copies:=entities_copy(a.s,a.w,entities,allocator) if a.run!=nil else entities_duplicate(a.s,entities,"Duplicate",allocator)
            core.world_settle(a.w)
            return transmute([]author.Node)copies,core.world_entities(a.w).alive-before,"nothing was copied" if len(copies)!=len(sources) else ""
        },
        group=proc(user:rawptr,members:[]author.Node) -> (author.Node,string) {
            a:=(^Api_Write)(user)
            entities:=transmute([]core.Entity)members
            if a.run!=nil || len(entities)==0 {return 0,"name the entities of the scene the group holds: a game that plays groups nothing"}
            for e in entities {
                if prefab_member_locked(a.s,a.w,e) {return 0,"a member of an instance of a prefab keeps the place its prefab gives it; group the instance, or unlink it"}
            }
            made:=entities_group(a.s,a.w,entities)
            core.world_settle(a.w)
            return author.Node(made),"the group could not be made" if made==core.NONE else ""
        },
        reparent=proc(user:rawptr,node,parent:author.Node) -> string {
            a:=(^Api_Write)(user)
            e,under:=core.Entity(node),core.Entity(parent)
            if a.run==nil {
                if reason:=api_write_refused(a,parent);reason!="" {return reason}
            }
            if !(entity_reparent(a.s,e,under) if a.run==nil else !entity_under(a.w,under,e) && entity_hang(a.w,e,under)) {return "it cannot go there: its new parent hangs from it, or has no size in some axis"}
            core.world_settle(a.w)
            return ""
        },
        rename=proc(user:rawptr,node:author.Node,name:string) -> string {
            a:=(^Api_Write)(user)
            if a.run!=nil {
                core.add(core.world_table_of(a.w,core.Name),core.Entity(node),core.name_make(name))
                return ""
            }
            return "" if entity_rename(a.s,core.Entity(node),name) else "the entity cannot be renamed"
        },
        move=proc(user:rawptr,node:author.Node,local:core.Transform) -> string {
            a:=(^Api_Write)(user)
            w,e:=a.w,core.Entity(node)
            if a.run==nil {return "" if transform_set(a.s,e,core.to_math(local)) else "the entity has no Transform"}
            // A teleport: a free Transform holds it now, and one a library owns (a body) jumps there in the next tick.
            transforms:=core.world_table_of(w,core.Transform)
            placer:=core.Placer{transforms,core.read(core.world_table_of(w,core.Parent)),core.world_storage_of(w,core.Places),core.world_storage_of(w,core.Jumps)}
            world:=core.to_math(local)
            if parent:=entity_parent(w,e);parent!=core.NONE {world=mm.transform_compose(entity_world(w,parent),world)}
            if transforms==nil || placer.places==nil || placer.jumps==nil || !core.place(placer,e,world.position,world.rotation) {return "it cannot be teleported: it has no Transform, or a parent of it cannot hold that place"}
            if row:=core.free(transforms,e);row!=nil {row.scale=local.scale}
            core.world_settle(w)
            return ""
        },
        mark=proc(user:rawptr,node:author.Node,hidden,on:bool) -> string {
            a:=(^Api_Write)(user)
            w,e:=a.w,core.Entity(node)
            hides,disabled:=core.world_table_of(w,erender.Hidden),core.world_table_of(w,core.Disabled)
            switch {
            case hidden && hides==nil: return "the world has no Hidden"
            case a.run==nil && hidden: entity_hidden_set(a.s,e,on)
            case a.run==nil:           entity_enabled_set(a.s,e,!on)
            case hidden && on:         core.add(hides,e,erender.Hidden{})
            case hidden:               core.remove(hides,e)
            case on:                   core.add(disabled,e,core.Disabled{})
            case:                      core.remove(disabled,e)
            }
            core.world_settle(w)
            return ""
        },
        order=proc(user:rawptr,node:author.Node,order:int) {
            a:=(^Api_Write)(user)
            if a.run==nil {entity_order_set(a.s,core.Entity(node),i32(order));return}
            if row:=core.edit(core.world_table_of(a.w,core.Parent),core.Entity(node));row!=nil {row.order=i32(order)}
        },
        write=proc(user:rawptr,reading:^author.Reading,node:author.Node,t:^core.Table_Info,text,path:string,from:[]u8,merge:bool) -> (changed,ok:bool) {
            return api_write_component((^Api_Write)(user),reading,core.Entity(node),t,text,path,from,merge)
        },
        drop=proc(user:rawptr,node:author.Node,t:^core.Table_Info) {
            a:=(^Api_Write)(user)
            if a.run!=nil {core.raw_remove(core.world_table_at(a.w,t),core.Entity(node))} else {component_remove(a.s,core.Entity(node),t)}
            core.world_settle(a.w)
        },
        turn=proc(user:rawptr,node:author.Node,t:^core.Table_Info,off:bool) {
            a:=(^Api_Write)(user)
            table,e:=core.world_table_at(a.w,t),core.Entity(node)
            switch {
            case a.run==nil: component_turn(a.s,e,t,off)
            case off:        core.raw_disable(table,e)
            case:            core.raw_enable(table,e)
            }
            core.world_settle(a.w)
        },
        remove=proc(user:rawptr,nodes:[]author.Node) -> (int,string) {
            a:=(^Api_Write)(user)
            before:=core.world_entities(a.w).alive
            if a.run==nil {entities_delete(a.s,transmute([]core.Entity)nodes)} else {
                for node in nodes {
                    if core.alive(core.world_entities(a.w),core.Entity(node)) {core.destroy(core.world_entities(a.w),core.Entity(node))}
                }
            }
            core.world_settle(a.w)
            return before-core.world_entities(a.w).alive,""
        },
        // The kind of the document, which Save writes.
        kind=proc(user:rawptr,prefab:bool) -> (bool,string) {
            a:=(^Api_Write)(user)
            d:=a.s.document
            if d.prefab==prefab {return false,""}
            if prefab {
                roots:=0
                for e in core.world_table_of(a.w,core.Id).entities {roots+=int(entity_parent(a.w,e)==core.NONE)}
                if roots!=1 {return false,fmt.tprintf("a prefab has exactly one root, and this scene has %d: put its entities under one (group), then make it a prefab",roots)}
            }
            d.prefab,d.unsaved=prefab,true
            a.s.view_cut=true
            return true,""
        },
    },true
}

// ---------------------------------------------------------------- scene.inspect with root

// The subtree of root as the document scene.write takes, among what
// scene.inspect gives of a world.
@(private)
api_inspect_tree :: proc(a:^Api_Write,params:^Api_Inspect_Params) {
    s,call,w:=a.s,a.call,a.w
    if base.text_get(params.entity[:])!="" || base.text_get(params.name[:])!="" || base.text_get(params.component[:])!="" || params.offset!=0 || params.include_runtime || params.storages || base.text_get(params.storage[:])!="" {
        api.call_fail(call,api.INVALID_PARAMS,"root gives the whole subtree as the document scene.write takes: leave out entity, name, component, offset, include_runtime and storages; components [] gives it without components")
        return
    }
    root,known:=api_call_entity(call,w,params.root[:],"root",a.run!=nil)
    if !known {return}
    values,read:=api_inspect_values(s,call,w,false)
    if !read {return}
    if text:=section_lock_text(s,w,root,true);text!="" && a.run==nil {api.call_failf(call,api.SERVER_ERROR,"root: %s",text);return}
    part:=api_part(a,root,call.allocator)
    if len(part)>params.limit {
        api.call_failf(call,api.INVALID_PARAMS,"the subtree of root has %d entities, more than limit %d; raise limit up to 4096, or give a root lower in the tree",len(part),params.limit)
        return
    }
    target,ready:=api_write_target(a)
    if !ready {return}
    tree:serial.Writer
    serial.writer_init(&tree,0,call.allocator)
    serial.write_u8(&tree,'[')
    author.scene_entity_write(&target,&tree,author.Node(root),values.only if values.listed else target.tables)
    serial.write_u8(&tree,']')
    r:=api.call_result(call,Api_Inspect_Result)
    base.text_set(r.path[:],document_path(s.document))
    r.dirty,r.playing,r.total=document_dirty(s),s.mode!=.Edit,core.world_entities(w).alive
    r.shown,r.matched,r.tree=len(part),len(part),serial.Json(string(serial.writer_bytes(&tree)))
}
