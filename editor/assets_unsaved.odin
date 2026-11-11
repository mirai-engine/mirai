package editor

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "mirai:asset"
import "mirai:core"
import "mirai:editor/history"
import "mirai:host"
import "mirai:project"
import "mirai:std/base"
import "mirai:std/serial"

// The asset files that edits changed and did not write (edits_files.odin):
// they live in the memory of the registry of the assets until they are saved,
// which writes them, or discarded, which takes back what the disk holds; undo
// back to what the disk holds also takes one off the list. This is what the
// content browser, the tabs, the dialogs, the API and the asset documents
// show and save. The sources of programs are among them, by their absolute
// path: the generation of the shaders reads them (programs_overlay), so
// saving one changes nothing that was published and discarding one publishes
// the programs again.

// The asset files unsaved now, by their path in the registry.
assets_unsaved :: proc(s:^Session) -> []asset.Registry_Memory {
    if s.app==nil || s.app.assets==nil {return nil}
    return host.assets_unsaved(s.app.assets)
}

// Whether an asset of the project has changes that are not saved.
asset_unsaved :: proc(s:^Session,id:base.Asset_Id) -> bool {
    unsaved:=assets_unsaved(s)
    if len(unsaved)==0 || id=={} {return false}
    file,found:=asset.registry_find(&s.app.assets.registry,id)
    if !found {return false}
    for held in unsaved {
        if held.path==file.path {return true}
    }
    return false
}

// The paths of the asset files unsaved now, as copies.
assets_unsaved_paths :: proc(s:^Session,allocator:=context.temp_allocator) -> []string {
    unsaved:=assets_unsaved(s)
    paths:=make([]string,len(unsaved),allocator)
    for held,i in unsaved {paths[i]=strings.clone(held.path,allocator)}
    return paths
}

// How the user and the API name an unsaved file: its path in the registry, or
// for the source of a program its path under the project, or under engine/
// for one of the engine.
unsaved_name :: proc(s:^Session,path:string) -> string {
    if !asset.registry_outside(path) {return path}
    if relative:=history.file_relative(s.project_root,path);relative!=path {return relative}
    if s.engine_root!="" && strings.has_prefix(path,s.engine_root) && len(path)>len(s.engine_root) && path[len(s.engine_root)]=='/' {
        return strings.concatenate({"engine",path[len(s.engine_root):]},context.temp_allocator)
    }
    return path
}

// What depends on an unsaved file takes what it holds now: an asset where it
// is loaded, a program in the next publication of the programs.
@(private)
unsaved_changed :: proc(s:^Session,path:string) {
    if !asset.registry_outside(path) {
        host.app_asset_changed(s.app,path)
    } else if strings.has_suffix(path,".slang") && s.build!=nil {
        programs_publish_request(s)
    }
}

// Writes unsaved asset files, by their path in the registry; one with
// nothing unsaved is skipped. Returns how many it wrote, and false when one
// could not be written: it stays unsaved.
assets_save :: proc(s:^Session,paths:[]string) -> (saved:int,ok:bool) {
    failures:string
    saved,failures=assets_write(s,paths)
    return saved,failures==""
}

// assets_save that says which files could not be written and why, as text in
// the temporary allocator; "" when all were.
assets_write :: proc(s:^Session,paths:[]string) -> (saved:int,failures:string) {
    if busy:=import_busy(s);busy!="" && len(paths)>0 {
        notify(s,busy)
        return 0,busy
    }
    if s.app==nil || s.app.assets==nil {return}
    r:=&s.app.assets.registry
    failed:=make([dynamic]string,context.temp_allocator)
    for path in paths {
        if _,found:=asset.registry_memory_find(r,path);!found {continue}
        // Writing frees the entry the path may belong to.
        relative:=strings.clone(path,context.temp_allocator)
        if error:=asset.registry_memory_write(r,relative);error!=.None {
            append(&failed,fmt.tprintf("%s: %v",unsaved_name(s,relative),error))
            continue
        }
        // A program published as it was held: its file now holds the same.
        if !asset.registry_outside(relative) {host.app_asset_changed(s.app,relative)}
        saved+=1
    }
    return saved,strings.join(failed[:],"; ",context.temp_allocator)
}

assets_save_all :: proc(s:^Session) -> (saved:int,ok:bool) {return assets_save(s,assets_unsaved_paths(s))}

// Puts back what the disk holds of unsaved asset files: one that only memory
// held is gone. Returns how many it put back.
assets_discard :: proc(s:^Session,paths:[]string) -> (discarded:int) {
    if s.app==nil || s.app.assets==nil {return}
    r:=&s.app.assets.registry
    for path in paths {
        relative:=strings.clone(path,context.temp_allocator)
        if dropped,_:=asset.registry_memory_drop(r,relative);!dropped {continue}
        unsaved_changed(s,relative)
        discarded+=1
    }
    return
}

// The unsaved asset files a world uses: those of the assets it names and of
// what they need, at any depth, and the sources of the programs of its
// materials. Their paths go to out, as copies in the temporary allocator.
world_unsaved_assets :: proc(s:^Session,w:core.World_Ref,out:^[dynamic]string) {
    clear(out)
    unsaved:=assets_unsaved(s)
    if len(unsaved)==0 || w.data==nil {return}
    r:=&s.app.assets.registry
    ids:=make([dynamic]base.Asset_Id,context.temp_allocator)
    host.world_asset_ids(w,&ids)
    used:=make(map[u32]bool,context.temp_allocator)
    pending:=make([dynamic]u32,context.temp_allocator)
    reach :: proc(r:^asset.Registry,id:base.Asset_Id,used:^map[u32]bool,pending:^[dynamic]u32) {
        at,known:=r.by_id[id]
        if !known || used[at] {return}
        used[at]=true
        append(pending,at)
    }
    for id in ids {reach(r,id,&used,&pending)}
    for len(pending)>0 {
        current:=pop(&pending)
        for dependency in asset.registry_dependencies(r,&r.files[current]) {reach(r,dependency,&used,&pending)}
    }
    // The unsaved sources by the name of the program they declare.
    programs:=make([dynamic][2]string,context.temp_allocator)
    for held in unsaved {
        if at,known:=r.by_path[held.path];known && used[at] {append(out,strings.clone(held.path,context.temp_allocator))}
        if asset.registry_outside(held.path) && !held.removed {
            if name:=program_declared(string(held.data));name!="" {append(&programs,[2]string{name,held.path})}
        }
    }
    for at in used {
        if len(programs)==0 {break}
        file:=&r.files[at]
        if file.kind!=asset.KIND_MATERIAL {continue}
        info,read:=material_file(s,file.id)
        if !read {continue}
        name:=base.text_get(info.program[:])
        for program,i in programs {
            if program[0]!=name {continue}
            append(out,strings.clone(program[1],context.temp_allocator))
            unordered_remove(&programs,i)
            break
        }
    }
}

// The unsaved asset files a world owns (host.world_asset_ids with owned):
// they are saved with its scene. Their paths go to out, as copies in the
// temporary allocator.
world_owned_unsaved :: proc(s:^Session,w:core.World_Ref,out:^[dynamic]string) {
    clear(out)
    unsaved:=assets_unsaved(s)
    if len(unsaved)==0 || w.data==nil {return}
    r:=&s.app.assets.registry
    ids:=make([dynamic]base.Asset_Id,context.temp_allocator)
    host.world_owned_asset_ids(w,&ids)
    for id in ids {
        file,found:=asset.registry_find(r,id)
        if !found {continue}
        for held in unsaved {
            if held.path==file.path {append(out,strings.clone(held.path,context.temp_allocator));break}
        }
    }
}

// What a restart or a recovery keeps of the unsaved assets: a copy of each
// under a folder of the project, at its path in the registry (a source of a
// program, under .sources/ at its name), and a manifest with the paths of the
// copies and of the removed files.
Unsaved_Manifest :: struct {
    assets,removed:[dynamic]string,
}

UNSAVED_MANIFEST :: "unsaved.json"

// Where folder keeps the copy of an unsaved file.
@(private)
unsaved_copy :: proc(s:^Session,folder,path:string) -> string {
    if asset.registry_outside(path) {return project.path(folder,".sources",unsaved_name(s,path),allocator=context.temp_allocator)}
    return project.path(folder,path,allocator=context.temp_allocator)
}

// Keeps the unsaved assets in folder, which it replaces; with none it only
// removes the folder. False when something could not be written.
assets_unsaved_store :: proc(s:^Session,folder:string) -> bool {
    base.remove_all(folder)
    unsaved:=assets_unsaved(s)
    if len(unsaved)==0 {return true}
    manifest:=Unsaved_Manifest{make([dynamic]string,context.temp_allocator),make([dynamic]string,context.temp_allocator)}
    for held in unsaved {
        if held.removed {
            append(&manifest.removed,held.path)
            continue
        }
        file:=unsaved_copy(s,folder,held.path)
        if dir:=filepath.dir(file);!os.is_dir(dir) && os.make_directory_all(dir)!=nil {return false}
        if serial.file_write_atomic(file,held.data)!=.None {return false}
        append(&manifest.assets,held.path)
    }
    data,encoded:=serial.text_encode(manifest,.Line,context.temp_allocator)
    return encoded && serial.file_write_atomic(project.path(folder,UNSAVED_MANIFEST,allocator=context.temp_allocator),data)==.None
}

// Whether folder keeps unsaved assets (assets_unsaved_store).
assets_unsaved_kept :: proc(folder:string) -> bool {
    return os.exists(project.path(folder,UNSAVED_MANIFEST,allocator=context.temp_allocator))
}

// A file folder keeps that this editor holds unsaved as well; "" when none is.
assets_unsaved_conflict :: proc(s:^Session,folder:string) -> string {
    if s.app==nil || s.app.assets==nil {return ""}
    data,read:=os.read_entire_file(project.path(folder,UNSAVED_MANIFEST,allocator=context.temp_allocator),context.temp_allocator)
    if read!=nil {return ""}
    manifest:Unsaved_Manifest
    if serial.text_decode(string(data),&manifest,context.temp_allocator)!="" {return ""}
    r:=&s.app.assets.registry
    for path in manifest.assets {
        if _,held:=asset.registry_memory_find(r,path);held {return path}
    }
    for path in manifest.removed {
        if _,held:=asset.registry_memory_find(r,path);held {return path}
    }
    return ""
}

// Puts back in memory the unsaved assets folder keeps and removes it.
// Returns how many it put back; false when the manifest could not be read.
assets_unsaved_restore :: proc(s:^Session,folder:string) -> (restored:int,ok:bool) {
    if s.app==nil || s.app.assets==nil {return}
    data,read:=os.read_entire_file(project.path(folder,UNSAVED_MANIFEST,allocator=context.temp_allocator),context.temp_allocator)
    if read!=nil {return}
    manifest:Unsaved_Manifest
    if serial.text_decode(string(data),&manifest,context.temp_allocator)!="" {return}
    r:=&s.app.assets.registry
    for path in manifest.assets {
        bytes,error:=os.read_entire_file(unsaved_copy(s,folder,path),context.temp_allocator)
        if error!=nil || asset.registry_memory_set(r,path,bytes)!=.None {continue}
        unsaved_changed(s,path)
        restored+=1
    }
    for path in manifest.removed {
        if asset.registry_memory_remove(r,path)!=.None {continue}
        unsaved_changed(s,path)
        restored+=1
    }
    base.remove_all(folder)
    return restored,true
}
