package asset

import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:fmt"
import "mirai:std/base"
import "mirai:std/serial"

SLOT_EMPTY_NAME :: "default"

// The names of a short list of assets a method addresses without an index,
// such as the material layers of a terrain: each the path of its asset, or
// SLOT_EMPTY_NAME without one, and "#2" on for the second that has the same.
slot_names :: proc(r:^Registry,ids:[]base.Asset_Id,allocator:=context.temp_allocator) -> []string {
    names:=make([]string,len(ids),allocator)
    for id,i in ids {
        name:=SLOT_EMPTY_NAME
        if id!={} {
            if file,found:=registry_find(r,id);found {name=file.path} else {
                buffer:[base.ASSET_ID_TEXT]u8
                name=strings.clone(base.asset_id_format(id,buffer[:]),allocator)
            }
        }
        repeated:=1
        for other in ids[:i] {if other==id {repeated+=1}}
        names[i]=repeated>1?fmt.aprintf("%s#%d",name,repeated,allocator=allocator):name
    }
    return names
}

// Whether a name given stands for the name of a slot: all of it, without its
// extension, or its stem.
@(private="file")
slot_name_taken :: proc(given,name:string) -> bool {
    stem:=filepath.stem(filepath.base(name))
    return given==name || given==name[:len(name)-len(filepath.ext(name))] || given==stem
}

// The slot a name stands for: by slot_names, without the path of its folder or
// its extension, or by the id of its asset. problem says what is wrong with
// the name for whoever wrote it, with what names exist; `what` calls the
// slots, in plural.
slot_named :: proc(names:[]string,ids:[]base.Asset_Id,given,what:string,allocator:=context.temp_allocator) -> (index:int,problem:string) {
    if id,is_id:=serial.text_parse_asset_id(given);is_id {
        for each,i in ids {if each==id {return i,""}}
    }
    wanted,order:=given,0
    if hash:=strings.last_index_byte(given,'#');hash>=0 {
        if value,parsed:=strconv.parse_int(given[hash+1:]);parsed && value>0 {wanted,order=given[:hash],value}
    }
    index=-1
    matches:=make([dynamic]int,allocator)
    for name,i in names {
        whole:=name
        if hash:=strings.last_index_byte(name,'#');hash>=0 {whole=name[:hash]}
        if slot_name_taken(wanted,whole) {append(&matches,i)}
    }
    switch {
    case order>0 && order<=len(matches): return matches[order-1],""
    case order==0 && len(matches)==1:    return matches[0],""
    case len(matches)>1 && order==0:
        taken:=make([]string,len(matches),allocator)
        for at,i in matches {taken[i]=names[at]}
        return -1,fmt.aprintf("%q names %d %s: %s; give one of those, or change them so that they differ",given,len(matches),what,strings.join(taken,", ",allocator),allocator=allocator)
    }
    return -1,fmt.aprintf("%q is not one of the %s: %s",given,what,strings.join(names,", ",allocator),allocator=allocator)
}
