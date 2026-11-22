// What Kai knows of Mirai projects: the structural merge of assets, row by
// id and field by field (asset.scene_merge), and which paths of a project a
// workspace tracks (project.own_path).
package kai_assets

import "core:slice"
import "mirai:asset"
import "mirai:cook/cache"
import "mirai:project"
import "mirai:std/base"
import "mirai:store"
import vcs "mirai:kai"

DRIVER_ASSET :: 3
DRIVER_ASSET_VERSION :: 1

// What the asset driver reads documents with. It must outlive the drivers
// made from it.
Asset_Driver :: struct {
    types:^asset.Types,
}

// The driver that merges the assets of Mirai: a document merges row by id and
// field by field, a scene keeps its hierarchy valid, and what both sides
// changed apart is a conflict whose partial result keeps ours there. A file
// that is not an asset is left to the next driver.
driver :: proc(d:^Asset_Driver) -> vcs.Driver {
    return {id=DRIVER_ASSET,version=DRIVER_ASSET_VERSION,data=d,merge=asset_merge,anchor=asset_anchor}
}

// A driver whose Resolved and Conflicted results are kept in the cache
// MERGE_CACHE (cook/cache) of the machine's store by its id, its version and
// the addresses of the three terms: a driver is pure, so the same terms merge
// once. Results are not asked of peers: a miss waits for the mesh longer than
// a merge takes. It must outlive the drivers made from it.
Cached_Driver :: struct {
    driver:vcs.Driver,
    store:^store.Store, // nil: nothing is kept
    types:^asset.Types,
}

MERGE_CACHE :: "kai-merges"
@(private) MERGE_KIND :: asset.Fourcc(0x47524d4b) // KMRG: a result, as a row, and the merged bytes

cached :: proc(c:^Cached_Driver) -> vcs.Driver {
    d:=c.driver
    d.data,d.merge=c,cached_merge
    if c.driver.anchor!=nil {d.anchor=cached_anchor}
    return d
}

@(private)
cached_merge :: proc(data:rawptr,input:^vcs.Driver_Input,out:^[dynamic]u8) -> vcs.Driver_Result {
    c:=(^Cached_Driver)(data)
    inner:=c.driver
    if c.store==nil || c.types==nil || input.terms[1]=={} || input.terms[2]=={} {return inner.merge(inner.data,input,out)}
    key:=base.hash_combine(base.hash64(slice.to_bytes(input.terms[:])),u64(u8(input.has_base)))|1
    version:=u64(inner.id)<<32|u64(inner.version)
    file:asset.Asset
    if cache.load({store=c.store},MERGE_CACHE,key,version,&file,context.temp_allocator) {
        defer asset.asset_close(&file)
        result,re:=asset.asset_row(&file,c.types,"result",vcs.Driver_Result,whole=true)
        bytes,be:=asset.asset_rows(&file,c.types,"bytes","",u8,whole=true)
        if file.blob.header.kind==MERGE_KIND && re==.None && be==.None && (result^==.Resolved || result^==.Conflicted) {
            clear(out)
            if _,f:=append(out,..bytes);f==nil {return result^}
        }
    }
    result:=inner.merge(inner.data,input,out)
    if result!=.Resolved && result!=.Conflicted {return result}
    doc:asset.Document
    asset.document_init(&doc,MERGE_KIND,cache.id(key,version),context.temp_allocator)
    defer asset.document_destroy(&doc)
    if _,e:=asset.document_put_row(&doc,c.types,"result",&result);e!=.None {return result}
    if _,e:=asset.document_put(&doc,c.types,"bytes",out[:],{.Bulk});e!=.None {return result}
    if bytes,e:=asset.document_bytes(&doc,context.temp_allocator);e==.None {_=cache.put({store=c.store},MERGE_CACHE,key,version,bytes)}
    return result
}

@(private)
cached_anchor :: proc(data:rawptr,from,to:[]u8,anchor:^vcs.Anchor) -> (moved,known:bool) {
    c:=(^Cached_Driver)(data)
    return c.driver.anchor(c.driver.data,from,to,anchor)
}

// Tracks what a project owns: not its generated folder nor version control
// folders.
filter :: proc() -> vcs.Filter {
    return {procedure=proc(_:rawptr,path:string) -> bool {return project.own_path(path)}}
}

// The options of a workspace over a project: its filter and the asset driver.
workspace_options :: proc(drivers:[]vcs.Driver) -> vcs.Workspace_Options {
    return {filter=filter(),drivers=drivers}
}

@(private)
asset_merge :: proc(data:rawptr,input:^vcs.Driver_Input,out:^[dynamic]u8) -> vcs.Driver_Result {
    d:=(^Asset_Driver)(data)
    ours,origin,theirs:asset.Document
    if asset.document_read(&ours,input.ours)!=.None {return .Unsupported}
    defer asset.document_destroy(&ours)
    if asset.document_read(&theirs,input.theirs)!=.None {return .Unsupported}
    defer asset.document_destroy(&theirs)
    base_doc:^asset.Document
    if input.has_base {
        if asset.document_read(&origin,input.base)!=.None {return .Unsupported}
        base_doc=&origin
    }
    defer if base_doc!=nil {asset.document_destroy(&origin)}
    if ours.kind!=theirs.kind || (base_doc!=nil && origin.kind!=ours.kind) {return .Unsupported}
    m:asset.Merge
    defer asset.merge_destroy(&m)
    if asset.scene_merge(&m,d.types,&ours,base_doc,&theirs)!=.None {return .Error}
    bytes,e:=asset.document_bytes(&ours,context.temp_allocator)
    if e!=.None {return .Error}
    // Rows of a kind may name rows of another table by position, which a merge
    // of rows does not follow: a scene that does not read is no result.
    if ours.kind==asset.KIND_SCENE {
        check:asset.Scene
        if asset.scene_read(&check,d.types,bytes)!=.None {return .Error}
        asset.scene_destroy(&check)
    }
    if _,f:=append(out,..bytes);f!=nil {return .Error}
    return len(m.conflicts)==0 ? .Resolved : .Conflicted
}

// A structural anchor stays while its entity is in the scene; lines do not
// apply to an asset.
@(private)
asset_anchor :: proc(data:rawptr,from,to:[]u8,anchor:^vcs.Anchor) -> (moved,known:bool) {
    d:=(^Asset_Driver)(data)
    scene:asset.Scene
    if asset.scene_read(&scene,d.types,to)!=.None {return false,false}
    defer asset.scene_destroy(&scene)
    switch anchor.kind {
    case .File: return true,true
    case .Lines: return false,true
    case .Structural:
        _,found:=asset.scene_entity_find(&scene,base.Entity_Id(anchor.key))
        return found,true
    }
    return false,true
}
