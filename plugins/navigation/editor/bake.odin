package navigation_editor

import "core:fmt"
import "core:strings"
import "mirai:asset"
import "mirai:core"
import "mirai:editor"
import "mirai:editor/api"
import scene "mirai:engine/scene"
import "mirai:std/base"
import mm "mirai:std/math"
import nav "plugins:navigation/runtime"

// Keeps the .navmesh of each Navigation_Bake of the edited world as its
// meshes: that of the scene, and that of each of its sections loaded in it.
// Once they have settled after a change, each is written again, in memory
// until it is saved.

// A .navmesh in the browser and in the field of a Navigation_Bake.
@(storage)
Nav_Kinds :: struct {provider:editor.Asset_Kind_Provider}
NAV_KINDS_DEFAULT :: Nav_Kinds{provider={kinds={0={kind=nav.BAKE_KIND,label="Navmesh",color={60,180,140,255},icon=.Plane,extension=nav.BAKE_EXTENSION,scene_data=true}},count=1}}

@(storage)
Nav_Bake_Kept :: struct {
    world:rawptr,
    revision:u64,
    bakes:u64, // the version and layout of the Navigation_Bake rows written
}

// Whether no tile waits for a build or for its links; those that wait for
// their collision to load keep what they have, and that is what is baked.
@(private)
settled :: proc(n:^nav.Navigation) -> bool {
    for i in 0..<n.count {
        it:=base.hash_map_iterator(&n.classes[i].marks)
        for _,mark in base.hash_map_iterate(&it) {
            if mark.dirty && !mark.unloaded || mark.building || mark.links {return false}
        }
    }
    return true
}

// The box of the section of a reference in the edited world; empty without one.
@(private)
section_box :: proc(w:core.World_Ref,reference:core.Entity) -> mm.Aabb {
    value,found:=editor.entity_get(w,reference,scene.Scene_Reference)
    pose,placed:=editor.entity_get(w,reference,core.World_Transform)
    if !found || !placed {return mm.AABB_EMPTY}
    return scene.section_bounds(value,pose.transform)
}

// What the .navmesh of the Navigation_Bake of e holds: the tiles over the box
// of its section; of the scene, those outside every section, with the coarse
// graph. The reference of its section, none for the scene.
@(private)
bake_filter :: proc(w:core.World_Ref,e:core.Entity) -> (filter:nav.Bake_Filter,section:core.Entity) {
    section=editor.section_of(w,e)
    if section!=core.NONE {return {within=true,inside=section_box(w,section)},section}
    outside:=make([dynamic]mm.Aabb,context.temp_allocator)
    if references:=core.world_table_of(w,scene.Scene_Reference);references!=nil {
        for row in 0..<core.raw_count(core.raw(references)) {
            if box:=section_box(w,references.entities[row]);!mm.aabb_is_empty(box) {append(&outside,box)}
        }
    }
    return {outside=outside[:],coarse=true},core.NONE
}

// Where the .navmesh of an asset is, in the registry (the file of its asset,
// or beside the scene of the section, or of the edited scene) and on disk.
@(private)
bake_path :: proc(s:^editor.Session,id:base.Asset_Id,section:core.Entity) -> (path,file:string) {
    if s.app==nil || s.app.assets==nil {return}
    registry:=&s.app.assets.registry
    if found,ok:=asset.registry_find(registry,id);ok {
        path=found.path
    } else {
        beside:string
        if section!=core.NONE {
            reference,_:=editor.entity_get(editor.edited_world(s),section,scene.Scene_Reference)
            if found,ok:=asset.registry_find(registry,reference.scene);ok {beside=found.path}
        } else if s.document!=nil {
            beside=editor.document_path(s.document)
        }
        if beside=="" {return}
        dot:=strings.last_index_byte(beside,'.')
        stem:=beside[:dot] if dot>strings.last_index_byte(beside,'/') else beside
        path=fmt.tprintf("%s%s",stem,nav.BAKE_EXTENSION)
    }
    return path,asset.registry_file_path(registry,path,context.temp_allocator)
}

@(step="frame")
navigation_bake_keep :: proc(s:^editor.Session,kept:^Nav_Bake_Kept) {
    if editor.playing(s) || editor.document_is_prefab(s) || s.app==nil || s.app.assets==nil {return}
    w:=editor.edited_world(s)
    if w.data==nil {return}
    n:=core.world_storage_of(w,nav.Navigation)
    bakes:=core.world_table_of(w,nav.Navigation_Bake)
    if n==nil || bakes==nil || core.count(bakes)==0 || !n.ready {return}
    seen:=core.version(bakes)+core.layout(bakes)
    if kept.world==w.data && kept.revision==n.revision && kept.bakes==seen {return}
    if !settled(n) {return}
    written:=true
    for row in 0..<core.count(bakes) {
        e:=core.entity_at(bakes,row)
        bake:=core.at(bakes,row)
        if bake.asset=={} {continue}
        filter,section:=bake_filter(w,e)
        _,file:=bake_path(s,bake.asset,section)
        if file=="" {continue}
        bytes,error:=nav.bake_bytes(n,bake.asset,&s.app.assets.types,filter,context.temp_allocator)
        if error!=.None || !editor.file_set(s,file,bytes) {written=false}
    }
    if written {kept^={w.data,n.revision,seen}}
}

// The scene, or the section edited in its world, saves its meshes: the first
// time it gets a .navmesh beside it and an entity whose Navigation_Bake names
// it, in one undo step; the file stays in memory until the scene is saved,
// and follows the meshes from then on.
@(private)
bake_call :: proc(s:^editor.Session,call:^api.Call) {
    if editor.document_is_prefab(s) {api.call_fail(call,api.INVALID_PARAMS,"nav.bake works on a scene: open one");return}
    w:=editor.edited_world(s)
    n:=core.world_storage_of(w,nav.Navigation)
    bakes,bakes_info:=core.world_table(w,nav.Navigation_Bake)
    if n==nil || bakes==nil {api.call_fail(call,api.INVALID_PARAMS,"The scene has no navigation: activate the plugin navigation in project.mirai");return}
    table:=cast(^core.Table(nav.Navigation_Bake))bakes
    if !n.ready {api.call_fail(call,api.INVALID_PARAMS,"The navigation meshes are not made yet: the physics of the scene must be ready");return}
    if s.document==nil || editor.document_path(s.document)=="" {api.call_fail(call,api.INVALID_PARAMS,"Save the scene first: its .navmesh goes beside it");return}
    section:=editor.section_editing(s)
    owner:=core.NONE
    for row in 0..<core.count(table) {
        e:=core.entity_at(table,row)
        if editor.section_of(w,e)==section {owner=e;break}
    }
    id:base.Asset_Id
    if value,found:=core.get(table,owner);found {id=value.asset}
    if id=={} {
        if section!=core.NONE {
            reference,_:=editor.entity_get(w,section,scene.Scene_Reference)
            id=base.asset_id_named(fmt.tprintf("navmesh %x %x",reference.scene[0],reference.scene[1]))
        } else {
            id=base.asset_id_named(fmt.tprintf("navmesh %x %x",s.document.id[0],s.document.id[1]))
        }
    }
    path,file:=bake_path(s,id,section)
    if file=="" {api.call_fail(call,api.SERVER_ERROR,"There is no asset registry to write the .navmesh to, or the scene of the section is not in it");return}
    filter,_:=bake_filter(w,owner)
    if section!=core.NONE {filter={within=true,inside=section_box(w,section)}}
    bytes,error:=nav.bake_bytes(n,id,&s.app.assets.types,filter,context.temp_allocator)
    if error!=.None {api.call_failf(call,api.SERVER_ERROR,"The meshes cannot be written: %v",error);return}
    if !editor.api_edit_begin(s,call,"Bake navigation") {return}
    if owner!=core.NONE {
        core.edit(table,owner).asset=id
    } else if e:=editor.entity_create(s,{preset=.Empty,name="Navigation",parent=section});e!=core.NONE {
        value:=nav.Navigation_Bake{asset=id}
        editor.component_add(s,e,bakes_info,&value)
    }
    written:=editor.file_write(s,file,bytes,"Bake navigation")
    editor.api_edit_end(s,call,written)
    tiles:=0
    for i in 0..<n.count {for &tile in n.classes[i].mesh.tiles {if tile.used && (!filter.within || mm.aabb_overlaps(filter.inside,tile.data.bounds)) {tiles+=1}}}
    api.call_result(call,Nav_Bake_Result)^={id,path,tiles,settled(n)}
}
