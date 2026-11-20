package asset

import "core:time"
import "mirai:store"

// Sweeps the machine's store: the one procedure a long-running owner of it
// (a share, an editor) calls now and then. What stays is what live names
// (what the owner holds open), what every fresh lease names, every ref of
// every namespace, and the outputs and thumbnails of the builds those refs
// name. A project reaches its pins through these refs while it is refreshed
// (REF_BUILDS, REF_PACKAGES), and its root carries the text of each manifest
// it pins (PACKAGE_FILES), so a manifest swept is taken from there again.
store_sweep :: proc(s:^store.Store,live:[]store.Hash,now:Maybe(time.Time)=nil) -> (result:store.Sweep_Result,error:store.Error) {
    held:=make([dynamic]store.Hash,0,len(live)+256,context.temp_allocator)
    append(&held,..live)
    namespaces:=store.ref_namespaces(s,context.temp_allocator) or_return
    for namespace in namespaces {
        refs:=store.ref_list(s,namespace,context.temp_allocator) or_return
        builds:=namespace==REF_IMPORTS || namespace==REF_IMPORTS_FAST || namespace==REF_BUILDS
        for ref in refs {
            append(&held,ref.hash)
            if !builds {continue}
            // A build that does not read keeps only itself.
            b,build_error:=build_get(s,ref.hash,context.temp_allocator)
            if build_error!=.None {continue}
            objects:=Build_Objects{build=&b,with_thumbnails=true}
            for address in build_object_next(&objects) {append(&held,address)}
        }
    }
    return store.sweep(s,held[:],now)
}
