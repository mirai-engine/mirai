package editor

import "core:fmt"
import "core:math/linalg"
import "core:path/filepath"
import "core:slice"
import "mirai:asset"
import "mirai:core"
import "mirai:editor/api"
import "mirai:std/serial"
import "mirai:host"
import erender "mirai:engine/render"
import scene "mirai:engine/scene"
import "mirai:std/base"
import mm "mirai:std/math"
import "mirai:ui"

// A scene placed in another is a reference to it (scene.Scene_Reference):
// its entities hang from the entity of the reference, are edited in their
// own scene and are not saved in this one. A prefab places copies; a scene
// does not place scenes inside prefabs.
//
// What the view of the editor turns on and off of a section is not an edit:
// it goes in scene.Section_Views of the edited World, which
// scene.scene_sections reads over what the reference asks, and what the
// sections load, drop or turn there goes to the image of the journal without
// a step.

SECTIONS_EDITED :: 64 // sections a document keeps for Save once they were edited in their world
SECTION_TRAVEL_DISTANCE :: f32(200) // m: past it the camera goes into a big section instead of framing it whole

// The sections of a document in the editor; each tab keeps its own, and
// what its view shows of them is in the scene.Section_Views of its World.
Document_Sections :: struct {
    edit:core.Entity, // the reference whose section is edited in its world: the rest reads only, and Save writes its scene too
    edited:[SECTIONS_EDITED]base.Entity_Id, // the references edited in their world since the document opened: Save writes the scenes that changed
    edited_count:int,
}

// What a section shows in the view: Loading while it is asked loaded and
// not yet there.
Section_Shown :: enum u8 {Unloaded,Loading,Loaded,Active}

// Places a reference to the scene id at point and loads what it holds under it.
section_place :: proc(s:^Session,id:base.Asset_Id,point:[3]f32,name:string) -> core.Entity {
    if document_is_prefab(s) {
        notify(s,"A prefab cannot hold a scene: place the scene in a scene, or the prefab in this one")
        return core.NONE
    }
    a:=s.app.assets
    if a==nil || s.document==nil {return core.NONE}
    if id==s.document.id {
        notify(s,"A scene cannot hold itself")
        return core.NONE
    }
    file:=host_scene(s,id)
    if file==nil {
        notify(s,"The scene could not be read")
        return core.NONE
    }
    opened,edit_ready:=edit_open(s,fmt.tprintf("Add %s",name))
    if !edit_ready {return core.NONE}
    defer edit_close(s,opened)
    w:=edited_world(s)
    e:=entity_create(s,{name=name,transform={position=point,rotation=1,scale={1,1,1}}})
    if e==core.NONE {return core.NONE}
    if t:=core.world_table_of(w,scene.Scene_Reference);t!=nil {core.add(t,e,scene.Scene_Reference{scene=id,loaded=id})}
    if error:=section_instantiate(s,w,e,file,{});error!=.None {notify(s,fmt.tprintf("The scene could not be placed: %s",scene.error_text(error)))}
    return e
}

// Instantiates file under the reference e: its Ids combined with that of e,
// its unbounded volumes ruling in the box of e.
@(private)
section_instantiate :: proc(s:^Session,w:core.World_Ref,e:core.Entity,file:^asset.Asset,extents:[3]f32) -> scene.Error {
    path:=[1]base.Asset_Id{s.document.id}
    _,error:=scene.instantiate(w,file,&s.app.assets.types,{parent=e,documents=scene.assets_documents(s.app.assets),salt=api_entity_id(w,e),path=path[:],scope=e,scope_extents=extents})
    return error
}

// What hangs from each reference of the edited world follows the scene it
// names, in the step of the change: a loaded reference whose scene changed
// (the inspector, the API) drops its section and loads the new one, and one
// the step made (a paste, a duplicate, a component added) loads its own in
// place of what was copied with it. Any other is scene.scene_sections' to
// load and drop, outside the undo.
sections_sync :: proc(s:^Session) {
    if s.mode!=.Edit || s.app==nil || s.app.assets==nil || s.document==nil {return}
    w:=edited_world(s)
    references:=core.world_table_of(w,scene.Scene_Reference)
    if references==nil {return}
    hierarchy:=core.world_storage_of(w,core.Hierarchy)
    if hierarchy==nil {return}
    image:=sections_image(s,w)
    for row in 0..<core.count(references) {
        reference:=core.at(core.read(references),row)
        e:=core.entity_at(references,row)
        changed:=reference.rule==.With_Document && reference.state!=.Unloaded && reference.loaded!={} && reference.loaded!=reference.scene
        made:=reference.loaded=={} && section_made(image,e) && section_wanted(s,w,e)!=.Unloaded
        if !changed && !made {continue}
        for child:=core.first_child(core.ref(hierarchy),e);child!=core.NONE; {
            next:=core.next_sibling(core.ref(hierarchy),child)
            core.world_destroy_tree(w,child)
            child=next
        }
        loaded:=core.at(references,row)
        loaded.loaded,loaded.held=reference.scene,false
        file:=host_scene(s,reference.scene)
        if file==nil || reference.scene==s.document.id {continue}
        if error:=section_instantiate(s,w,e,file,reference.extents);error!=.None {
            notify(s,fmt.tprintf("The scene of %s could not be loaded: %s",entity_name(w,e),scene.error_text(error)))
        }
    }
}

// The image the journal keeps of the references of w; nil without one.
@(private)
sections_image :: proc(s:^Session,w:core.World_Ref) -> ^Journal_Table {
    edits:=s.edits
    if edits==nil || edits.world!=w.data {return nil}
    for t,i in w.info.tables {
        if t.place==w.place && t.type==scene.Scene_Reference && i<len(edits.image) {return &edits.image[i]}
    }
    return nil
}

// Whether the reference e is new since the last step: the image has no row of it.
@(private)
section_made :: proc(image:^Journal_Table,e:core.Entity) -> bool {return image!=nil && journal_row(image,e)<0}

// Loads the section of e again from its scene, outside the undo: what saving
// that scene from another reference leaves. A section loaded and off turns
// off again with the next frame.
@(private)
section_reload :: proc(s:^Session,w:core.World_Ref,e:core.Entity) {
    references:=core.world_table_of(w,scene.Scene_Reference)
    reference:=core.get(references,e)
    if reference==nil || reference.loaded=={} {return}
    file:=host_scene(s,reference.scene)
    gone:=section_entities(w,e)
    h:=entity_hierarchy(w)
    for child:=core.first_child(h,e);child!=core.NONE; {
        next:=core.next_sibling(h,child)
        core.world_destroy_tree(w,child)
        child=next
    }
    core.world_settle(w)
    if file!=nil {
        if error:=section_instantiate(s,w,e,file,reference.extents);error!=.None {
            notify(s,fmt.tprintf("The scene of %s could not be loaded again: %s",entity_name(w,e),scene.error_text(error)))
        }
    }
    core.world_settle(w)
    reference=core.get(references,e)
    if reference!=nil {
        reference.loaded,reference.held={},false
        if file!=nil {reference.loaded=reference.scene}
    }
    journal_take_entities(s.edits,w,gone)
    journal_take_entities(s.edits,w,section_entities(w,e))
}

// Every entity under e, e left out.
@(private)
section_entities :: proc(w:core.World_Ref,e:core.Entity,allocator:=context.temp_allocator) -> []core.Entity {
    found:=make([dynamic]core.Entity,allocator)
    h:=entity_hierarchy(w)
    if h.ptr==nil {return nil}
    stack:=make([dynamic]core.Entity,context.temp_allocator)
    for child:=core.first_child(h,e);child!=core.NONE;child=core.next_sibling(h,child) {append(&stack,child)}
    for len(stack)>0 {
        at:=pop(&stack)
        append(&found,at)
        for child:=core.first_child(h,at);child!=core.NONE;child=core.next_sibling(h,child) {append(&stack,child)}
    }
    return found[:]
}

// The image of the journal takes the rows and the life of some entities as
// the World has them, without a step: what the sections did is no edit.
@(private)
journal_take_entities :: proc(edits:^Edits,w:core.World_Ref,entities:[]core.Entity) {
    if edits==nil || edits.world!=w.data {return}
    authors,_:=history_authors(edits,w)
    for e in entities {
        if history_is_author(authors,e) {
            for i in 0..<len(edits.image) {journal_take(edits,w,i,e)}
        }
        journal_take_entity(edits,w,e)
    }
}

// Whether the editor draws the sky and the sun of the section of reference
// instead of those on (render.Environment_Preview): only in its view, not an
// edit, and Play starts without it.
section_previewed :: proc(w:core.World_Ref,reference:core.Entity) -> bool {
    p:=core.world_storage_of(w,erender.Environment_Preview)
    return p!=nil && reference!=core.NONE && p.section==reference
}

// Turns the preview of the environment of a section on or off.
section_preview_toggle :: proc(s:^Session,w:core.World_Ref,reference:core.Entity) {
    p:=core.world_storage_of(w,erender.Environment_Preview)
    if p==nil {return}
    if section_previewed(w,reference) {
        p^={}
        return
    }
    p^={}
    find :: proc(w:core.World_Ref,t:^core.Raw_Table,reference:core.Entity) -> core.Entity {
        if t==nil {return core.NONE}
        for e in t.entities[:t.values.len] {if entity_within(w,e,reference) {return e}}
        return core.NONE
    }
    if skies:=core.world_table_of(w,erender.Sky);skies!=nil {p.sky=find(w,core.raw(skies),reference)}
    if suns:=core.world_table_of(w,erender.Sun);suns!=nil {p.sun=find(w,core.raw(suns),reference)}
    p.section=reference
    if p.sky==core.NONE && p.sun==core.NONE {notify(s,"The section has no sky nor sun of its own: the preview shows only its look")}
}

// The entity of the reference whose section e is in; none outside of every section.
section_of :: proc(w:core.World_Ref,e:core.Entity) -> core.Entity {
    references:=core.world_table_of(w,scene.Scene_Reference)
    parents:=core.world_table_of(w,core.Parent)
    if references==nil || core.count(references)==0 || parents==nil {return core.NONE}
    at:=e
    for depth:=0;depth<1024;depth+=1 {
        parent,placed:=core.get(core.read(parents),at)
        if !placed {return core.NONE}
        at=parent.entity
        if core.has(references,at) {return at}
    }
    return core.NONE
}

// The reference whose section holds e, or whose proxy e is part of; none for
// what the document holds.
@(private)
section_holder :: proc(w:core.World_Ref,e:core.Entity) -> core.Entity {
    proxies:=core.world_table_of(w,scene.Section_Proxy)
    references:=core.world_table_of(w,scene.Scene_Reference)
    parents:=core.world_table_of(w,core.Parent)
    if references==nil || parents==nil {return core.NONE}
    at:=e
    for depth:=0;at!=core.NONE && depth<1024;depth+=1 {
        if proxies!=nil {
            if row:=core.raw_row(core.raw(proxies),at);row>=0 {return proxies.values[row].reference}
        }
        if at!=e && core.raw_row(core.raw(references),at)>=0 {return at}
        parent,placed:=core.get(core.read(parents),at)
        if !placed {return core.NONE}
        at=parent.entity
    }
    return core.NONE
}

@(private)
host_scene :: proc(s:^Session,id:base.Asset_Id) -> ^asset.Asset {
    if s.app.assets==nil {return nil}
    file:=host.assets_scene(s.app.assets,id)
    if file==nil || file.blob.header.kind!=asset.KIND_SCENE {return nil}
    return file
}

// What contains an entity in the hierarchy: the instance of a prefab or the
// section of a scene its root stands for. The outliner and Details draw the
// root in its color and a line along what it holds.
Container_Kind :: enum u8 {None,Prefab,Section}

SECTION_COLOR :: ui.Color{232,197,71,255} // a section: its icon and the line along it; in the content browser a scene stays orange
SECTION_TEXT :: ui.Color{240,211,107,255}
PREFAB_TEXT :: ui.Color{143,176,255,255}

// What e is the root of.
container_kind :: proc(links:map[base.Entity_Id]Prefab_Link,w:core.World_Ref,e:core.Entity) -> Container_Kind {
    if entity_has(w,e,scene.Scene_Reference) {return .Section}
    if link,linked:=links[api_entity_id(w,e)];linked && link.root {return .Prefab}
    return .None
}

container_color :: proc(s:^Session,kind:Container_Kind) -> (icon,text:ui.Color) {
    switch kind {
    case .Prefab:  return asset_kind_color(s,asset.KIND_PREFAB),PREFAB_TEXT
    case .Section: return SECTION_COLOR,SECTION_TEXT
    case .None:
    }
    return {},{}
}

// The root of what contains e, outside e itself: from a root, that of what contains it.
container_of :: proc(links:map[base.Entity_Id]Prefab_Link,w:core.World_Ref,e:core.Entity) -> core.Entity {
    at:=entity_parent(w,e)
    for depth:=0;at!=core.NONE && depth<1024;depth+=1 {
        if container_kind(links,w,at)!=.None {return at}
        at=entity_parent(w,at)
    }
    return core.NONE
}

// The document of a root: the scene a section names, the prefab of an instance.
container_document :: proc(s:^Session,links:map[base.Entity_Id]Prefab_Link,w:core.World_Ref,e:core.Entity) -> string {
    id:base.Asset_Id
    if reference,ok:=entity_get(w,e,scene.Scene_Reference);ok {id=reference.scene}
    else if link,linked:=links[api_entity_id(w,e)];linked {id=link.asset}
    if id=={} || s.app.assets==nil {return ""}
    if file,found:=asset.registry_find(&s.app.assets.registry,id);found {return filepath.base(file.path)}
    return "Missing"
}

// Whether e is top or under it.
entity_within :: proc(w:core.World_Ref,e,top:core.Entity) -> bool {
    at:=e
    for depth:=0;at!=core.NONE && depth<1024;depth+=1 {
        if at==top {return true}
        at=entity_parent(w,at)
    }
    return false
}

// The file of the document in front, for where a section is: "Untitled" before it is saved.
document_label :: proc(s:^Session) -> string {
    if s.document==nil || s.document.path_length==0 {return "Untitled"}
    return filepath.base(document_path(s.document))
}

// The entities without a parent, in the order of the world.
entity_roots :: proc(w:core.World_Ref) -> []core.Entity {
    roots:=make([dynamic]core.Entity,context.temp_allocator)
    names:=core.world_table_of(w,core.Name)
    if names==nil {return nil}
    for row in 0..<core.count(names) {
        e:=core.entity_at(names,row)
        if entity_parent(w,e)==core.NONE && entity_author(w,e)==e {append(&roots,e)}
    }
    return roots[:]
}

Api_Section_Preview_Params :: struct {
    entity:base.Entity_Id `mirai:"optional,label=The entity of a Scene_Reference whose sky, sun and look the editor draws; omitted goes back to those on"`,
}

api_section_preview :: proc(s:^Session,call:^api.Call) {
    params:=api.call_params(call,Api_Section_Preview_Params)
    w:=edited_world(s)
    p:=core.world_storage_of(w,erender.Environment_Preview)
    if s.mode!=.Edit || p==nil {
        api.call_fail(call,api.INVALID_PARAMS,"The preview of a section is of Edit: stop Play or Simulate first")
        return
    }
    if params.entity==0 {
        p^={}
    } else {
        e,ok:=api_section_reference(call,w,params.entity)
        if !ok {return}
        if !section_previewed(w,e) {section_preview_toggle(s,w,e)}
    }
    w_out:=call.out
    serial.text_write_raw(w_out,`{"sky":`)
    serial.text_write_string(w_out,fmt.tprintf("0x%016x",u64(api_entity_id(w,p.sky))))
    serial.text_write_raw(w_out,`,"sun":`)
    serial.text_write_string(w_out,fmt.tprintf("0x%016x",u64(api_entity_id(w,p.sun))))
    serial.write_u8(w_out,'}')
}

// The entity of the Scene_Reference id names; none, with the call failed, for another.
@(private)
api_section_reference :: proc(call:^api.Call,w:core.World_Ref,id:base.Entity_Id) -> (e:core.Entity,ok:bool) {
    e=api_entity(w,id)
    if e==core.NONE || !entity_has(w,e,scene.Scene_Reference) {
        api.call_failf(call,api.INVALID_PARAMS,"0x%016x is not the entity of a Scene_Reference: editor.sections lists them",u64(id))
        return core.NONE,false
    }
    return e,true
}

// ---------------------------------------------------------------- editing in its world

// The reference whose section is edited in its world; none outside of Edit.
section_editing :: proc(s:^Session) -> core.Entity {
    if s.mode!=.Edit || s.document==nil || s.document.sections.edit==core.NONE {return core.NONE}
    w:=edited_world(s)
    d:=&s.document.sections
    if !entity_alive(w,d.edit) || !entity_has(w,d.edit,scene.Scene_Reference) {
        d.edit=core.NONE
        return core.NONE
    }
    return d.edit
}

// Whether e reads only: an entity of a section, unless its section is the
// one edited in its world; while one is, everything outside it.
section_locked :: proc(s:^Session,w:core.World_Ref,e:core.Entity) -> bool {
    if s.mode!=.Edit {return false}
    if edited:=section_editing(s);edited!=core.NONE {return section_of(w,e)!=edited}
    return section_of(w,e)!=core.NONE
}

// Whether what goes under parent would be of a section that is not the one
// edited in its world, or, while one is, outside it.
section_target_locked :: proc(s:^Session,w:core.World_Ref,parent:core.Entity) -> bool {
    if s.mode!=.Edit {return false}
    target:=parent
    if parent!=core.NONE && !entity_has(w,parent,scene.Scene_Reference) {target=section_of(w,parent)}
    if edited:=section_editing(s);edited!=core.NONE {return target!=edited}
    return target!=core.NONE
}

// Why e reads only, for whoever tried to edit it: the user (api false) or a
// call of the API. "" when it does not.
section_lock_text :: proc(s:^Session,w:core.World_Ref,e:core.Entity,for_api:bool) -> string {
    if !section_locked(s,w,e) {return ""}
    name:=entity_label(w,e)
    edited:=section_editing(s)
    holder:=section_of(w,e)
    if edited!=core.NONE && holder!=edited {
        if for_api {return fmt.tprintf("%s is outside the section %s, which is edited in its world: editor.section_edit with id 0 stops editing it",name,entity_label(w,edited))}
        return fmt.tprintf("%s is outside the section %s, which is edited in its world: stop editing it to edit the rest",name,entity_label(w,edited))
    }
    scene_name:=section_scene_name(s,w,holder)
    if for_api {return fmt.tprintf("%s is of the section %s, whose scene %s keeps it: edit it there, or here after editor.section_edit with id 0x%016x",name,entity_label(w,holder),scene_name,u64(api_entity_id(w,holder)))}
    return fmt.tprintf("%s is of the section %s: edit it in %s, or here with Edit the section on %s",name,entity_label(w,holder),scene_name,entity_label(w,holder))
}

// The file of the scene of a reference.
@(private)
section_scene_name :: proc(s:^Session,w:core.World_Ref,reference:core.Entity) -> string {
    r,_:=entity_get(w,reference,scene.Scene_Reference)
    if s.app!=nil && s.app.assets!=nil {
        if file,found:=asset.registry_find(&s.app.assets.registry,r.scene);found {return filepath.base(file.path)}
    }
    return "its scene"
}

// True, with a notice and the reason a call of the API that tried fails
// with, when one of the entities reads only because of the sections.
section_refused :: proc(s:^Session,entities:..core.Entity) -> bool {
    if s.mode!=.Edit {return false}
    w:=edited_world(s)
    for e in entities {
        if !section_locked(s,w,e) {continue}
        edit_refusal(s,section_lock_text(s,w,e,false),section_lock_text(s,w,e,true))
        return true
    }
    return false
}

// Why nothing goes under parent, for the user and for a call of the API; ""
// when it can.
section_target_texts :: proc(s:^Session,w:core.World_Ref,parent:core.Entity) -> (text,reason:string) {
    if !section_target_locked(s,w,parent) {return}
    if edited:=section_editing(s);edited!=core.NONE {
        return fmt.tprintf("While %s is edited in its world, what is added or moved goes inside it",entity_label(w,edited)),
            fmt.tprintf("parent: while the section %s is edited in its world what is added or moved goes inside it; give a parent of that section, or stop editing it with editor.section_edit id 0",entity_label(w,edited))
    }
    holder:=entity_has(w,parent,scene.Scene_Reference)?parent:section_of(w,parent)
    scene_name:=section_scene_name(s,w,holder)
    return fmt.tprintf("What goes under %s is of the section %s: edit it in %s, or here with Edit the section",entity_label(w,parent),entity_label(w,holder),scene_name),
        fmt.tprintf("parent: what goes under %s is of the section %s, which its scene %s keeps: edit it there, or here after editor.section_edit with id 0x%016x",entity_label(w,parent),entity_label(w,holder),scene_name,u64(api_entity_id(w,holder)))
}

// section_refused for what would go under parent.
section_target_refused :: proc(s:^Session,parent:core.Entity) -> bool {
    if s.mode!=.Edit {return false}
    text,reason:=section_target_texts(s,edited_world(s),parent)
    if text=="" {return false}
    edit_refusal(s,text,reason)
    return true
}

// The entities that are under none of the others: those a deletion of them all asks for itself.
section_alone :: proc(s:^Session,entities:[]core.Entity) -> []core.Entity {
    w:=edited_world(s)
    given:=make(map[core.Entity]bool,len(entities),context.temp_allocator)
    for e in entities {given[e]=true}
    alone:=make([dynamic]core.Entity,0,len(entities),context.temp_allocator)
    for e in entities {
        under:=false
        for at,depth:=entity_parent(w,e),0;at!=core.NONE && depth<1024;at,depth=entity_parent(w,at),depth+1 {
            if given[at] {under=true;break}
        }
        if !under {append(&alone,e)}
    }
    return alone[:]
}

// Whether something of the selection reads only because of the sections: the gizmo is off.
selection_section_locked :: proc(s:^Session,w:core.World_Ref) -> bool {
    if s.mode!=.Edit || s.selection==nil {return false}
    for e in s.selection.entities {
        if section_locked(s,w,e) {return true}
    }
    return false
}

// Edits the section of reference in its world, or stops with none. What the
// one left keeps unsaved, Save still writes.
section_edit_set :: proc(s:^Session,reference:core.Entity) {
    if reference!=core.NONE && document_is_prefab(s) {return}
    w:=edited_world(s)
    d:=&s.document.sections
    if left:=section_editing(s);left!=core.NONE && left!=reference && section_unsaved(s,w,left) {
        notify(s,fmt.tprintf("%s keeps its unsaved changes: Save writes them to %s",entity_label(w,left),section_scene_name(s,w,left)))
    }
    views:=core.world_storage_of(w,scene.Section_Views)
    if d.edit!=core.NONE && d.edit!=reference && views!=nil {scene.section_view(views,d.edit,{},false)}
    if reference!=core.NONE {
        id:=api_entity_id(w,reference)
        if id==0 {return}
        if !slice.contains(d.edited[:d.edited_count],id) {
            if d.edited_count==len(d.edited) {
                notify(s,fmt.tprintf("%d sections were edited in their world since the scene opened: save and open it again to edit another",SECTIONS_EDITED))
                return
            }
            d.edited[d.edited_count]=id
            d.edited_count+=1
        }
        // It stays on while it is edited.
        if views!=nil {scene.section_view(views,reference,.Active)}
    }
    d.edit=reference
}

Section_Write :: enum u8 {Unchanged,Written,Failed}

// The section of reference as its own scene would hold it, and whether that
// differs from its file. False, with the reason, while it cannot be told:
// the section is not loaded and on.
@(private)
section_capture :: proc(s:^Session,w:core.World_Ref,reference:core.Entity,captured:^asset.Scene) -> (path:string,changed:bool,why:string) {
    a:=s.app.assets
    r,ok:=entity_get(w,reference,scene.Scene_Reference)
    if a==nil || !ok {return "",false,"it is not a section"}
    file,found:=asset.registry_find(&a.registry,r.scene)
    if !found {return "",false,"its scene is missing"}
    switch {
    case r.loaded=={}:
        // Unloaded, what changed in it waits dormant under its reference.
        if len(entity_children(w,reference))>0 {return "",false,"its changes wait while it is off: turn it on to save them"}
        return "",false,""
    case r.loaded!=r.scene: return "",false,"it is loading"
    case r.held:                         return "",false,"it is loaded and off: turn it on to save it"
    }
    path=scene_file(s,file.path)
    previous:asset.Scene
    had:=asset.scene_load(&previous,&a.types,path)==.None
    defer if had {asset.scene_destroy(&previous)}
    if _,error:=scene.capture(w,captured,&a.types,{section=reference,previous=had?&previous:nil,kind=asset.KIND_SCENE,id=r.scene});error!=.None {
        return "",false,fmt.tprintf("it could not be captured: %s",scene.error_text(error))
    }
    if _,error:=asset.scene_bytes(captured,context.temp_allocator);error!=.None {
        asset.scene_destroy(captured)
        return "",false,"it could not be encoded"
    }
    return path,!had || captured.stamp!=previous.stamp,""
}

// Whether the section of reference holds what its scene does not: changed
// while it is loaded and on, or waiting dormant while it is off.
section_unsaved :: proc(s:^Session,w:core.World_Ref,reference:core.Entity) -> bool {
    r,ok:=entity_get(w,reference,scene.Scene_Reference)
    switch {
    case !ok: return false
    case r.loaded=={}: return len(entity_children(w,reference))>0
    case r.loaded!=r.scene || r.held: return false
    }
    captured:asset.Scene
    path,changed,_:=section_capture(s,w,reference,&captured)
    if path!="" {asset.scene_destroy(&captured)}
    return changed
}

// Writes the section of reference into its own scene when it differs from
// its file, and loads it again under the other references to that scene.
section_save :: proc(s:^Session,reference:core.Entity) -> (result:Section_Write,why:string) {
    a:=s.app.assets
    w:=edited_world(s)
    captured:asset.Scene
    path,changed,reason:=section_capture(s,w,reference,&captured)
    if reason!="" {return .Failed,reason}
    if path=="" {return .Unchanged,""}
    defer asset.scene_destroy(&captured)
    if !changed {return .Unchanged,""}
    if asset.scene_save(&captured,path)!=.None {return .Failed,"its file could not be written"}
    host.assets_scan(a)
    assets_wrote(s,path)
    // The other references to it show what was saved.
    r,_:=entity_get(w,reference,scene.Scene_Reference)
    references:=core.world_table_of(w,scene.Scene_Reference)
    others:=make([dynamic]core.Entity,context.temp_allocator)
    for row in 0..<core.count(references) {
        e:=core.entity_at(references,row)
        if e!=reference && core.at(core.read(references),row).scene==r.scene {append(&others,e)}
    }
    d:=&s.document.sections
    for e in others {
        if slice.contains(d.edited[:d.edited_count],api_entity_id(w,e)) && section_unsaved(s,w,e) {
            notify(s,fmt.tprintf("%s shows the scene %s saved from %s: what changed in it is gone",entity_label(w,e),section_scene_name(s,w,e),entity_label(w,reference)))
        }
        section_reload(s,w,e)
    }
    return .Written,""
}

// Writes the scene of every section edited in its world that changed: the
// one edited first, so that it wins over another reference to the same
// scene. False, with a notice, when one could not be written: the document
// stays unsaved.
sections_save :: proc(s:^Session) -> bool {
    w:=edited_world(s)
    d:=&s.document.sections
    order:=make([dynamic]core.Entity,context.temp_allocator)
    if edited:=section_editing(s);edited!=core.NONE {append(&order,edited)}
    for id in d.edited[:d.edited_count] {
        e:=api_entity(w,id)
        if e!=core.NONE && !slice.contains(order[:],e) && entity_has(w,e,scene.Scene_Reference) {append(&order,e)}
    }
    written:=make([dynamic]base.Asset_Id,context.temp_allocator)
    ok:=true
    for e in order {
        r,_:=entity_get(w,e,scene.Scene_Reference)
        if slice.contains(written[:],r.scene) {continue}
        result,why:=section_save(s,e)
        switch result {
        case .Unchanged:
        case .Written: append(&written,r.scene)
        case .Failed:
            ok=false
            notify(s,fmt.tprintf("The section %s was not saved: %s",entity_label(w,e),why))
        }
    }
    return ok
}

Api_Section_Edit_Params :: struct {
    entity:base.Entity_Id `mirai:"optional,label=The entity of a Scene_Reference whose section is edited in its world: Save writes its scene too, and the rest reads only; omitted stops"`,
}

api_section_edit :: proc(s:^Session,call:^api.Call) {
    params:=api.call_params(call,Api_Section_Edit_Params)
    w:=edited_world(s)
    if s.mode!=.Edit || document_is_prefab(s) {
        api.call_fail(call,api.INVALID_PARAMS,"A section is edited in its world in Edit, in a scene: stop Play or Simulate, or open the scene")
        return
    }
    e:=core.NONE
    if params.entity!=0 {
        ok:bool
        if e,ok=api_section_reference(call,w,params.entity);!ok {return}
    }
    left:=section_editing(s)
    kept:=left!=core.NONE && left!=e && section_unsaved(s,w,left)
    section_edit_set(s,e)
    if section_editing(s)!=e {
        api.call_failf(call,api.SERVER_ERROR,"%d sections were edited in their world since the scene opened: scene.save, then scene.open it again to edit another",SECTIONS_EDITED)
        return
    }
    out:=call.out
    serial.text_write_raw(out,`{"editing":`)
    api_write_id(out,api_entity_id(w,e))
    serial.text_write_raw(out,`,"unsaved":`)
    api_write_id(out,kept?api_entity_id(w,left):0)
    serial.write_u8(out,'}')
}

// ---------------------------------------------------------------- the view

// The state the view asks of the section of reference, and whether it
// overrides what the reference asks. The section edited in its world stays
// on; one a gesture made waits for its step, which is no view of the user.
section_view :: proc(s:^Session,w:core.World_Ref,reference:core.Entity) -> (state:scene.Section_State,overridden:bool) {
    if reference==section_editing(s) && reference!=core.NONE {return .Active,true}
    views:=core.world_storage_of(w,scene.Section_Views)
    if views==nil || section_made(sections_image(s,w),reference) {return}
    for v in views.items {
        if v.entity==reference {return v.state,true}
    }
    return
}

// Turns the section of reference on, off, or loaded and off in the view of
// the editor; auto gives it back to what its reference asks. "" once done,
// otherwise why not.
section_view_set :: proc(s:^Session,w:core.World_Ref,reference:core.Entity,state:scene.Section_State,auto:=false) -> string {
    if s.mode!=.Edit {return "Sections turn on and off in the view in Edit: stop Play or Simulate first"}
    if !entity_has(w,reference,scene.Scene_Reference) {return "It is not the entity of a Scene_Reference"}
    if !auto && reference==section_editing(s) {return "The section edited in its world stays on: stop editing it first"}
    views:=core.world_storage_of(w,scene.Section_Views)
    if views==nil {return "The World has no Section_Views: generate the World of the project again"}
    scene.section_view(views,reference,state,!auto)
    return ""
}

// What the section of reference is asked to be now: by the view, by the
// streaming of this end for a Spatial one, or by its reference.
section_wanted :: proc(s:^Session,w:core.World_Ref,reference:core.Entity) -> scene.Section_State {
    if state,overridden:=section_view(s,w,reference);overridden {return state}
    r,_:=entity_get(w,reference,scene.Scene_Reference)
    return r.rule==.Spatial?r.streamed:r.state
}

section_shown :: proc(s:^Session,w:core.World_Ref,reference:core.Entity) -> Section_Shown {
    r,_:=entity_get(w,reference,scene.Scene_Reference)
    switch {
    case r.loaded=={}: return section_wanted(s,w,reference)==.Unloaded?.Unloaded:.Loading
    case r.loaded!=r.scene: return .Loading
    case r.held: return .Loaded
    }
    return .Active
}

Section_Mark :: struct {entity:core.Entity,loaded,far:base.Asset_Id,held:bool}

// What the steps around scene.scene_sections, and the plugins that show the
// far forms of sections after it, keep between them in a frame of the
// edited World.
@(storage)
Sections_Watch :: struct {
    marks:[dynamic]Section_Mark,  // what each reference had loaded, and how, before
    seen:[dynamic]core.Seen,      // by table of the world info, before
    verdicts:[dynamic]u8,         // by entity index while what the sections changed is taken in: 1 of a section, 2 not
    taken:[dynamic]core.Entity,
    made:[dynamic]core.Entity,    // references a gesture made, which the view keeps unloaded until their step loads them (sections_sync)
    references:core.Seen,         // of the Scene_Reference table of world, for the references that went
    proxies:u64,                  // the version of the table of scene.Section_Proxy before
    proxied:[dynamic]core.Entity, // the far forms there were before: one that goes is theirs too
    world:rawptr,
}

// Marks what each reference holds before scene.scene_sections, and keeps in
// the view the references a gesture made unloaded until their step.
@(step="frame",before="scene_sections")
sections_watch :: proc(s:^Session,watch:^Sections_Watch,world:core.World_Ref) {
    clear(&watch.marks)
    if s.mode!=.Edit || world.data!=s.edit_world || s.edits==nil || s.document==nil {return}
    references:=core.world_table_of(world,scene.Scene_Reference)
    views:=core.world_storage_of(world,scene.Section_Views)
    if references==nil || views==nil {return}
    sections_orphans_drop(s,watch,world,references,views)
    image:=sections_image(s,world)
    #reverse for e,i in watch.made {
        if section_made(image,e) && entity_has(world,e,scene.Scene_Reference) {continue}
        scene.section_view(views,e,{},false)
        unordered_remove(&watch.made,i)
    }
    if core.count(references)==0 {return}
    clear(&watch.proxied)
    if proxies:=core.world_table_of(world,scene.Section_Proxy);proxies!=nil {
        watch.proxies=core.version(core.read(proxies))
        for row in 0..<core.count(core.read(proxies)) {append(&watch.proxied,core.entity_at(core.read(proxies),row))}
    }
    for row in 0..<core.count(references) {
        e:=core.entity_at(references,row)
        r:=core.at(core.read(references),row)
        append(&watch.marks,Section_Mark{e,r.loaded,r.far,r.held})
        if section_made(image,e) && !slice.contains(watch.made[:],e) {
            append(&watch.made,e)
            scene.section_view(views,e,.Unloaded)
        }
    }
    if len(watch.seen)!=len(world.info.tables) {resize(&watch.seen,len(world.info.tables))}
    for &t,i in world.info.tables {
        if i<len(s.edits.saved) && s.edits.saved[i] {_=core.raw_changes(core.world_table_at(world,&t),&watch.seen[i])}
    }
}

// What hung from a reference that is gone goes too, outside the undo: an undo
// that took the reference back leaves what its section loaded, which no step
// holds. The view forgets it.
@(private)
sections_orphans_drop :: proc(s:^Session,watch:^Sections_Watch,world:core.World_Ref,references:^core.Table(scene.Scene_Reference),views:^scene.Section_Views) {
    c:=core.raw_changes(core.raw(references),&watch.references)
    if watch.world!=world.data {
        watch.world=world.data
        clear(&watch.made)
        return
    }
    if c.all || len(c.gone)==0 {return}
    gone:=make([dynamic]core.Entity,context.temp_allocator)
    for e in c.gone {
        if entity_has(world,e,scene.Scene_Reference) {continue}
        scene.section_view(views,e,{},false)
        if !entity_alive(world,e) {append(&gone,e)}
    }
    parents:=core.world_table_of(world,core.Parent)
    if len(gone)==0 || parents==nil {return}
    orphans:=make([dynamic]core.Entity,context.temp_allocator)
    for e,row in parents.entities {
        if slice.contains(gone[:],parents.values[row].entity) && entity_alive(world,e) {append(&orphans,e)}
    }
    if len(orphans)==0 {return}
    dropped:=make([dynamic]core.Entity,context.temp_allocator)
    for e in orphans {
        append(&dropped,e)
        append(&dropped,..section_entities(world,e))
    }
    for e in orphans {core.world_destroy_tree(world,e)}
    core.world_settle(world)
    journal_take_entities(s.edits,world,dropped[:])
}

// When a section loaded, dropped or turned, or the far form of one showed or
// went, takes what that changed into the image of the journal: no edit. It
// runs at the end of the frame, past the plugins that show far forms after
// scene.scene_sections; the tools of the user edit at its beginning.
@(step="frame",stage="end")
sections_watched :: proc(s:^Session,watch:^Sections_Watch,world:core.World_Ref) {
    if s.mode!=.Edit || world.data!=s.edit_world || s.edits==nil || len(watch.marks)==0 {return}
    references:=core.world_table_of(world,scene.Scene_Reference)
    if references==nil {return}
    if proxies:=core.world_table_of(world,scene.Section_Proxy);proxies!=nil && core.version(core.read(proxies))!=watch.proxies {
        sections_take_in(s,watch,world)
        return
    }
    for m in watch.marks {
        r,found:=core.get(core.read(references),m.entity)
        if !found || r.loaded!=m.loaded || r.held!=m.held || r.far!=m.far {
            sections_take_in(s,watch,world)
            return
        }
    }
}

// What the loads and drops of sections of this frame gave the Entity fields
// of the document (Unresolved_References.resolved: an entity resolved, or
// none released) goes to the image of the journal: no step of the user holds
// it.
@(step="frame",after="scene_references")
sections_resolved :: proc(s:^Session,world:core.World_Ref) {
    edits:=s.edits
    if edits==nil || edits.world!=world.data {return}
    u:=core.world_storage_of(world,scene.Unresolved_References)
    if u==nil || u.written==edits.resolved {return}
    edits.resolved=u.written
    for &t,i in world.info.tables {
        if t.place!=world.place {continue}
        hash:=base.name_hash(t.name)
        for item in u.resolved {
            if item.table==hash {journal_take_field(edits,world,i,item.entity,int(item.offset),size_of(core.Entity))}
        }
    }
}

// The rows and entities of the sections, and of their proxies, that changed
// since sections_watch go to the image of the journal; those of the
// document stay for its steps. The edits of the user are not made between
// the two steps, so what changed there of the section edited in its world is
// what loading it did.
@(private)
sections_take_in :: proc(s:^Session,watch:^Sections_Watch,w:core.World_Ref) {
    edits:=s.edits
    if edits.world!=w.data || len(watch.seen)!=len(w.info.tables) {return}
    es:=core.world_entities(w)
    resize(&watch.verdicts,len(es.generation))
    slice.zero(watch.verdicts[:])
    clear(&watch.taken)
    authors,_:=history_authors(edits,w)
    parent_table:=-1
    for t,i in w.info.tables {
        if t.place==w.place && t.type==core.Parent {parent_table=i;break}
    }
    theirs :: proc(watch:^Sections_Watch,edits:^Edits,w:core.World_Ref,e:core.Entity,parent_table:int) -> bool {
        i:=int(core.entity_index(e))
        if i>=len(watch.verdicts) {return false}
        if watch.verdicts[i]==0 {
            holder:=core.NONE
            if entity_alive(w,e) {
                holder=section_holder(w,e)
            } else if slice.contains(watch.proxied[:],e) {
                holder=e
            } else if parent_table>=0 {
                // Gone: up the parents the image had, to the first that lives.
                image:=&edits.image[parent_table]
                at:=e
                for depth:=0;depth<1024;depth+=1 {
                    row:=journal_row(image,at)
                    if row<0 {break}
                    at=(^core.Parent)(journal_value(image,size_of(core.Parent),row)).entity
                    if entity_alive(w,at) {
                        holder=entity_has(w,at,scene.Scene_Reference)?at:section_holder(w,at)
                        break
                    }
                }
            }
            watch.verdicts[i]=holder!=core.NONE?1:2
            if watch.verdicts[i]==1 {append(&watch.taken,e)}
        }
        return watch.verdicts[i]==1
    }
    for &t,i in w.info.tables {
        if i>=len(edits.saved) || !edits.saved[i] {continue}
        table:=core.world_table_at(w,&t)
        c:=core.raw_changes(table,&watch.seen[i])
        if !c.all && table.version<=c.since && len(c.gone)==0 {continue}
        for e in c.gone {
            if theirs(watch,edits,w,e,parent_table) && history_is_author(authors,e) {journal_take(edits,w,i,e)}
        }
        for e,row in table.entities {
            if !c.all && table.stamps[row]<=c.since {continue}
            if theirs(watch,edits,w,e,parent_table) && history_is_author(authors,e) {journal_take(edits,w,i,e)}
        }
    }
    for e in watch.taken {journal_take_entity(edits,w,e)}
}

// ---------------------------------------------------------------- travel

// Brings the camera of the editor to the section of reference, and turns
// the section on in the view when what asks for it does not.
section_travel :: proc(s:^Session,w:core.World_Ref,reference:core.Entity) -> string {
    if s.mode!=.Edit {return "The camera travels to a section in Edit: stop Play or Simulate first"}
    r,ok:=entity_get(w,reference,scene.Scene_Reference)
    if !ok {return "It is not the entity of a Scene_Reference"}
    if section_wanted(s,w,reference)!=.Active {
        if why:=section_view_set(s,w,reference,.Active);why!="" {return why}
    }
    v:=s.viewport
    pose:=entity_world(w,reference)
    if r.extents=={} {
        v.orbit.target=pose.position
        v.orbit.distance=ORBIT_DEFAULT.distance
    } else {
        box:=section_box(r,pose)
        low,high:=box[0],box[0]
        for corner in box[1:] {low,high=linalg.min(low,corner),linalg.max(high,corner)}
        free:=ui.Rect{0,0,v.size.x,v.size.y}
        if s.gui!=nil {
            free=free_region(s.gui,v.window)
            free.x-=v.origin.x
            free.y-=v.origin.y
        }
        orbit_frame(&v.orbit,low,high,v.size,free)
        if v.orbit.distance>SECTION_TRAVEL_DISTANCE {
            v.orbit.target=(low+high)*0.5
            v.orbit.distance=SECTION_TRAVEL_DISTANCE
        }
    }
    viewport_camera(v)
    return ""
}

// The corners of the box of a section at pose: its extents times its scale.
section_box :: proc(r:scene.Scene_Reference,pose:mm.Transform) -> (corners:[8][3]f32) {
    axes:=section_axes(pose,r.extents)
    for &corner,i in corners {
        corner=pose.position
        for axis in 0..<3 {corner+=axes[axis]*(i&(1<<uint(axis))!=0?1:-1)}
    }
    return
}

// The half axes of a box of extents at pose, in the world.
section_axes :: proc(pose:mm.Transform,extents:[3]f32) -> [3][3]f32 {
    return {
        mm.quat_rotate(pose.rotation,[3]f32{extents.x*abs(pose.scale.x),0,0}),
        mm.quat_rotate(pose.rotation,[3]f32{0,extents.y*abs(pose.scale.y),0}),
        mm.quat_rotate(pose.rotation,[3]f32{0,0,extents.z*abs(pose.scale.z)}),
    }
}
