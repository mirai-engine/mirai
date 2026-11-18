package main

import "core:fmt"
import "mirai:asset"
import importer "mirai:cook/import"
import "mirai:std/base"
import "mirai:store"

// The ids of what the imports of the demo wrote. An import gives a part a
// random id the first time and keeps it every time after, in the manifest of
// the package of its source in the store of the machine: the demo reads them
// from there.

// The asset of kind that the import of source (relative to demo/) wrote for
// what the source names name.
@(private)
imported_id :: proc(o:^Out,source:string,kind:asset.Fourcc,name:string) -> base.Asset_Id {
    if s,error:=store.open(store.default_root(context.temp_allocator),context.temp_allocator);error==.None {
        if id,found:=importer.output_id(&s,path(o,source),kind,name);found {return id}
    }
    known,_:=asset.kind_info(kind)
    fmt.eprintfln("demo_content: the import of %s wrote no %s named %s",source,known.name,name)
    o.content.failed=true
    return {}
}
