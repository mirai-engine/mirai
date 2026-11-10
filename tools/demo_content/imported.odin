package main

import "core:fmt"
import "mirai:asset"
import importer "mirai:cook/import"
import "mirai:cook/import/sources"
import "mirai:project"
import "mirai:std/base"

// The ids of what the imports of the demo wrote. An import gives a part a
// random id the first time and keeps it every time after, in the sidecar of
// its source: the demo reads them from there.

// Imports a source this tool writes (relative to demo/), as a build does.
@(private)
source_import :: proc(o:^Out,source:string) {
    report,error:=sources.import_source(path(o,source),{root=fmt.tprintf("%s/demo",o.root),texture_cache=project.content_cache_path(fmt.tprintf("%s/demo",o.root),project.TEXTURE_CACHE,allocator=context.temp_allocator)})
    if error.code!=.None {
        fmt.eprintfln("demo_content: %s",error.message)
        o.content.failed=true
        return
    }
    for warning in report.warnings {fmt.printfln("%s: %s",source,warning)}
    fmt.printfln("imported %s",source)
    importer.report_destroy(&report)
}

// The asset of kind that the import of source (relative to demo/) wrote for
// what the source names name.
@(private)
imported_id :: proc(o:^Out,source:string,kind:asset.Fourcc,name:string) -> base.Asset_Id {
    if id,found:=importer.output_id(path(o,source),kind,name);found {return id}
    known,_:=asset.kind_info(kind)
    fmt.eprintfln("demo_content: the import of %s wrote no %s named %s",source,known.name,name)
    o.content.failed=true
    return {}
}
