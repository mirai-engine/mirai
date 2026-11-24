package asset

import "core:fmt"
import "core:strings"
import "mirai:std/base"
import "mirai:std/serial"

// The asset a text names among those of a registry: its id, or its path under
// the assets folder, with or without its extension. kinds: the extensions it
// may have, separated by spaces; "": any. problem says what is wrong with the
// name, with the paths nearest to it; "": found.
registry_resolve :: proc(r:^Registry,name,kinds:string) -> (id:base.Asset_Id,problem:string) {
    if parsed,is_id:=serial.text_parse_asset_id(name);is_id {return parsed,""}
    if file,found:=registry_find_path(r,name);found && file.state==.Asset && path_of_kinds(file.path,kinds) {return file.id,""}
    matches:=make([dynamic]^Registry_File,context.temp_allocator)
    for &file in r.files {
        if file.state==.Asset && path_stem(file.path)==name && path_of_kinds(file.path,kinds) {append(&matches,&file)}
    }
    if len(matches)==1 {return matches[0].id,""}
    b:=strings.builder_make(context.temp_allocator)
    if len(matches)>1 {
        for each,i in matches {fmt.sbprintf(&b,"%s%s",i>0?", ":"",each.path)}
        return {},fmt.tprintf("%q names several assets: %s; give the path with its extension",name,strings.to_string(b))
    }
    kind:=kinds!=""?fmt.tprintf("%s ",kinds):""
    if nearest:=registry_nearest(r,name,kinds);nearest!="" {
        return {},fmt.tprintf("%q is no %sasset; the nearest paths are %s",name,kind,nearest)
    }
    return {},fmt.tprintf("%q is no %sasset and none is near that name: asset.list lists them and asset.import brings one",name,kind)
}

// Whether a path is of one of the extensions, separated by spaces; "": any.
@(private="file")
path_of_kinds :: proc(path,kinds:string) -> bool {
    if kinds=="" {return true}
    rest:=kinds
    for kind in strings.fields_iterator(&rest) {
        if strings.has_suffix(path,kind) {return true}
    }
    return false
}

// A path without the extension of its file.
@(private="file")
path_stem :: proc(path:string) -> string {
    dot:=strings.last_index_byte(path,'.')
    slash:=strings.last_index_byte(path,'/')
    return dot>slash?path[:dot]:path
}

// The paths nearest to a name among the assets of the kinds, as a list.
@(private="file")
registry_nearest :: proc(r:^Registry,name,kinds:string) -> string {
    last:=path_stem(name)
    matcher:base.Name_Nearest
    if !base.name_nearest_init(&matcher,last[strings.last_index_byte(last,'/')+1:],base.NAME_NEAREST,context.temp_allocator) {return ""}
    for &file,i in r.files {
        if file.state!=.Asset || !registry_listed(&file) || !path_of_kinds(file.path,kinds) {continue}
        base.name_nearest_add(&matcher,i,path_stem(file.path))
    }
    nearest:[base.NAME_NEAREST]int
    count:=base.name_nearest_finish(&matcher,nearest[:])
    b:=strings.builder_make(context.temp_allocator)
    for at,i in nearest[:count] {fmt.sbprintf(&b,"%s%s",i>0?", ":"",r.files[at].path)}
    return strings.to_string(b)
}
