package main

import "core:fmt"
import "core:os"
import "mirai:asset"
import "mirai:std/base"

// The ids of what the imports of the demo wrote. An import gives a part a
// random id the first time and keeps it every time after, in the manifest of
// the package of its source, which the demo pins with the text of each
// manifest in its packages folder: the demo reads them from there.

// The asset of kind that the import of source (relative to demo/) wrote for
// what the source names name.
@(private)
imported_id :: proc(o:^Out,source:string,kind:asset.Fourcc,name:string) -> base.Asset_Id {
    root:=fmt.tprintf("%s/demo",o.root)
    list,_,_:=asset.packages_load(root,context.temp_allocator)
    for &entry in list.packages {
        text,read_error:=os.read_entire_file(asset.package_file(root,entry.id),context.temp_allocator)
        if read_error!=nil {continue}
        p,parse_error:=asset.package_parse(string(text),context.temp_allocator)
        if parse_error!=.None || p.origin.path!=source {continue}
        for &a in p.assets {
            if a.kind==kind && a.name==name {return a.id}
        }
    }
    known,_:=asset.kind_info(kind)
    fmt.eprintfln("demo_content: the package the demo pins for %s has no %s named %s",source,known.name,name)
    o.content.failed=true
    return {}
}
