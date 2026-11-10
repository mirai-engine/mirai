package editor

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "mirai:asset"
import "mirai:core"
import "mirai:editor/api"
import scene "mirai:engine/scene"
import "mirai:host"
import "mirai:std/base"
import "mirai:std/serial"

// A prefab is a template placed as copies; a scene is a place referenced as
// a section or loaded as the world. When the use changes (a building that is
// now streamed in), the same document changes kind and keeps its id: what
// named it with the other kind reports the field that names it.

Api_Asset_Convert_Params :: struct {
    asset:[API_PATH_BYTES]u8 `mirai:"text,label=The scene or prefab: its path under the asset folder or its id"`,
}

// Turns a scene into a prefab or a prefab into a scene, at once and not as
// an edit, as a delete does. Returns its new path, or what stops it.
asset_convert :: proc(s:^Session,id:base.Asset_Id) -> (path:string,message:string) {
    r:=files_registry(s)
    if r==nil {return "","The editor has no asset folder it can change"}
    file,found:=asset.registry_find(r,id)
    if !found {return "","No asset has that id"}
    if file.kind!=asset.KIND_SCENE && file.kind!=asset.KIND_PREFAB {return "","Only a scene or a prefab changes kind"}
    if busy:=import_busy(s);busy!="" {return "",busy}
    if scene_tab(s,id)>=0 {return "","It is open in a tab: close the tab first"}
    if file.kind==asset.KIND_SCENE {
        if title,reference:=scene_referenced(s,id);title!="" {return "",fmt.tprintf("%s holds it as the section %s: remove that Scene_Reference first",title,reference)}
    }
    from:=scene_file(s,file.path)
    doc:asset.Scene
    if asset.scene_load(&doc,&s.app.assets.types,from)!=.None {return "","It could not be read"}
    defer asset.scene_destroy(&doc)
    to:=asset.KIND_SCENE
    if file.kind==asset.KIND_SCENE {
        to=asset.KIND_PREFAB
        roots:=0
        for parent in asset.scene_parents(&doc) {if parent==0 {roots+=1}}
        if roots!=1 {return "",fmt.tprintf("A prefab has one root and this scene has %d: put its entities under one first",roots)}
        if _,referenced:=asset.scene_component(&doc,"Scene_Reference");referenced {return "","A prefab cannot hold scenes: remove its Scene_Reference first"}
        for parent,row in asset.scene_parents(&doc) {if parent==0 {doc.info.root=asset.scene_ids(&doc)[row]}}
    } else {
        doc.info.root=0
    }
    doc.doc.kind=to
    extension:=to==asset.KIND_SCENE?".scene":".prefab"
    target:=strings.concatenate({strings.trim_suffix(from,filepath.ext(from)),extension},context.temp_allocator)
    if os.exists(target) {return "",fmt.tprintf("%s exists: rename one of them first",filepath.base(target))}
    if asset.scene_save(&doc,target)!=.None {return "","It could not be written"}
    if os.remove(from)!=nil {
        os.remove(target)
        return "","The old file could not be removed"
    }
    host.assets_scan(s.app.assets)
    return scene_path(s,target),""
}

// The first open document that references the scene id as a section, and the
// name of that reference; "" when none does.
@(private)
scene_referenced :: proc(s:^Session,id:base.Asset_Id) -> (title,reference:string) {
    documents_ensure(s)
    for &tab,index in s.documents {
        world:=index==s.active_document?s.edit_world:tab.world
        if world==nil {continue}
        w:=core.world_ref(world,s.info)
        references:=core.world_table_of(w,scene.Scene_Reference)
        if references==nil {continue}
        for e,row in references.entities {
            if references.values[row].scene!=id {continue}
            return document_title(index==s.active_document?s.document:&tab.document),entity_label(w,e)
        }
    }
    return
}

Api_Asset_Convert_Result :: struct {
    path:string `mirai:"label=Where the asset is now, under the assets folder"`,
}

api_asset_convert :: proc(s:^Session,call:^api.Call) {
    r,id,named:=api_asset_named(s,call,base.text_get(api.call_params(call,Api_Asset_Convert_Params).asset[:]))
    if !named {return}
    path,message:=asset_convert(s,id)
    if message!="" {
        api.call_fail(call,api.INVALID_PARAMS,message)
        return
    }
    w:=call.out
    serial.text_write_raw(w,`{"path":`)
    serial.text_write_string(w,path)
    serial.write_u8(w,'}')
}
