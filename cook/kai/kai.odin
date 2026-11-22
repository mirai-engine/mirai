// What Kai knows of Mirai projects: the structural merge of assets, row by
// id and field by field (asset.scene_merge), and which paths of a project a
// workspace tracks (project.own_path).
package kai_assets

import "core:slice"
import "mirai:asset"
import "mirai:project"
import "mirai:std/base"
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
