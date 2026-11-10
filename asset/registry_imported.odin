package asset

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"
import "mirai:std/base"

// What the imports of the sources of a project build that nobody edits
// (meshes, textures, sounds, fonts) is not in its assets folder: each is a
// file of the imported folder that goes with it, named by its id, and is
// never versioned. The registry lists it as any other asset, at a path it
// derives from where the source of the asset is now: the folder of the
// source under the source folder and, for what is not the root of its
// import, a folder named after the source file. Nothing stores that path: a
// source that moves takes its outputs with it once it is imported again, and
// one that is gone is not listed.

// Where the sources of the root of an imported folder are named from, in
// Import_Info.source: the source folder of a project or a plugin.
@(private="file") SOURCES :: "source/"

// The file of the imported asset id listed at path.
@(private)
registry_imported_file :: proc(r:^Registry,path:string,id:base.Asset_Id,allocator:=context.allocator) -> string {
    folder:=r.imported
    for mount in r.mounts {
        if registry_under(path,mount.prefix) {folder=mount.imported;break}
    }
    buffer:[base.ASSET_ID_TEXT]u8
    file,error:=strings.concatenate({folder,"/",base.asset_id_format(id,buffer[:]),path[strings.last_index_byte(path,'.'):]},allocator)
    if error!=nil {return ""}
    return file
}

// Appends the assets of the imported folders of the root and of the mounts.
@(private)
registry_imported_list :: proc(r:^Registry,known:map[string]u32,previous:[]Registry_File,previous_dependencies:[]base.Asset_Id) -> Error {
    types:Types
    types_init(&types,context.temp_allocator)
    defer types_destroy(&types)
    taken:=make(map[string]struct{},context.temp_allocator)
    folders:=make(map[string]struct{},context.temp_allocator)
    for file in r.files {taken[file.path]={}}
    for folder in r.folders {folders[folder]={}}
    list :: proc(r:^Registry,imported,prefix:string,types:^Types,taken,folders:^map[string]struct{},known:map[string]u32,previous:[]Registry_File,previous_dependencies:[]base.Asset_Id) -> Error {
        if imported=="" {return .None}
        entries,error:=os.read_all_directory_by_path(imported,context.temp_allocator)
        if error!=nil {return .None}
        slice.sort_by(entries,proc(a,b:os.File_Info) -> bool {return a.name<b.name})
        // The project or the plugin: the imported folder is in its generated folder.
        root:=imported[:max(strings.last_index_byte(imported[:max(strings.last_index_byte(imported,'/'),0)],'/'),0)]
        for info in entries {
            dot:=strings.last_index_byte(info.name,'.')
            if info.type!=.Regular || dot<=0 || strings.has_suffix(info.name,".tmp") {continue}
            header,source,imported_asset,peek_error:=import_peek(info.fullpath,types)
            named:=base.text_get(source.source[:])
            if peek_error!=.None || !imported_asset || !strings.has_prefix(named,SOURCES) || !os.exists(fmt.tprintf("%s/%s",root,named)) {continue}
            folder,file:=named[len(SOURCES):],named[len(SOURCES):]
            if slash:=strings.last_index_byte(folder,'/');slash>=0 {folder,file=folder[:slash+1],folder[slash+1:]} else {folder=""}
            name,_:=strings.replace_all(base.text_get(source.name[:]),"/","_",context.temp_allocator)
            // The root of an import is listed beside its source; its other outputs, in a folder of the name of the source.
            stem:=file[:max(strings.last_index_byte(file,'.'),0)]
            if !(header.owner=={} && source.index==0 && name==stem) {folder=fmt.tprintf("%s%s/",folder,file)}
            if prefix!="" {folder=fmt.tprintf("%s/%s",prefix,folder)}
            path:=fmt.tprintf("%s%s%s",folder,name,info.name[dot:])
            for n:=2;(path in taken);n+=1 {path=fmt.tprintf("%s%s (%d)%s",folder,name,n,info.name[dot:])}
            taken[path]={}
            for at:=strings.index_byte(folder,'/');at>=0; {
                if !(folder[:at+1] in folders) {
                    listed,no_folder:=strings.clone(folder[:at+1],r.allocator)
                    if no_folder!=nil {return .Out_Of_Memory}
                    append(&r.folders,listed)
                    folders[listed]={}
                }
                next:=strings.index_byte(folder[at+1:],'/')
                at=next<0?-1:at+1+next
            }
            entry:=Registry_File{size=info.size,time=time.time_to_unix_nano(info.modification_time),imported=true}
            r.stats.files+=1
            registry_walk_reuse(r,&entry,info.fullpath,path,known,previous,previous_dependencies) or_return
            if entry.state!=.Asset {continue}
            registry_file_add(r,entry,path) or_return
        }
        return .None
    }
    list(r,r.imported,"",&types,&taken,&folders,known,previous,previous_dependencies) or_return
    for mount in r.mounts {list(r,mount.imported,mount.prefix,&types,&taken,&folders,known,previous,previous_dependencies) or_return}
    return .None
}
