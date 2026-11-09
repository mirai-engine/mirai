package main

import "core:fmt"
import "core:os"
import "core:strings"
import "mirai:asset"
import "mirai:std/base"

// The ids of what the imports of the demo wrote. An import gives a part a
// random id the first time and keeps it every time after, in the file of the
// part: the demo reads them from there.

// The asset of kind that the import of source (relative to demo/) wrote for
// what the source names name, wherever it is under assets/.
@(private)
imported_id :: proc(o:^Out,source:string,kind:asset.Fourcc,name:string) -> base.Asset_Id {
    walker:=os.walker_create(path(o,"assets"))
    defer os.walker_destroy(&walker)
    for entry in os.walker_walk(&walker) {
        if entry.type!=.Regular || strings.has_prefix(entry.name,".") {continue}
        header,info,imported,error:=asset.import_peek(entry.fullpath,&o.content.types)
        if error==.None && imported && header.kind==kind && base.text_get(info.name[:])==name && base.text_get(info.source[:])==source {return header.id}
    }
    known,_:=asset.kind_info(kind)
    fmt.eprintfln("demo_content: the import of %s wrote no %s named %s",source,known.name,name)
    o.content.failed=true
    return {}
}

// The asset in a file of demo/.
@(private)
asset_at :: proc(o:^Out,file:string) -> (header:asset.Header,info:asset.Import_Info) {
    error:asset.Error
    header,info,_,error=asset.import_peek(path(o,file),&o.content.types)
    if error!=.None {
        fmt.eprintfln("demo_content: %s: %v",file,error)
        o.content.failed=true
    }
    return
}
