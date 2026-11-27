// What Kai knows of Mirai projects: the structural merge of assets, row by
// id and field by field (asset.scene_merge), and which paths of a project a
// workspace tracks (tracked_path).
package kai_assets

import "core:slice"
import "core:strings"
import "mirai:asset"
import "mirai:project"
import "mirai:std/base"
import vcs "mirai:kai"

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
    return {data=d,merge=asset_merge}
}

// What a workspace over a project tracks: its own files (project.own_path),
// not the checkouts of the plugins from git its manifest names (`sources`),
// which git versions and each machine makes (install.sync), as its
// .gitignore leaves them out of a repository of git.
Tracked :: struct {
    sources:[project.MAX_SOURCES]project.Name,
}

// Reads the plugins from git the manifest of the project at root names; none
// when it has no manifest yet.
tracked_read :: proc(t:^Tracked,root:string) {
    t^={}
    m,error:=project.manifest_read(project.path(root,project.PROJECT_FILE,allocator=context.temp_allocator))
    if error.code!=.None {return}
    for &source,i in m.sources {t.sources[i]=source.name}
}

// Whether relative, with forward slashes, is a path a workspace over the
// project tracks.
tracked_path :: proc(t:^Tracked,relative:string) -> bool {
    if !project.own_path(relative) {return false}
    names:=project.FOLDER_NAMES
    plugins:=names[.Plugins]
    if len(relative)<=len(plugins) || relative[len(plugins)]!='/' || !project.path_same(relative[:len(plugins)],plugins) {return true}
    plugin:=relative[len(plugins)+1:]
    if slash:=strings.index_byte(plugin,'/');slash>=0 {plugin=plugin[:slash]}
    for &name in t.sources {
        source:=base.text_get(name[:])
        if source!="" && project.path_same(plugin,source) {return false}
    }
    return true
}

// The filter of tracked_path over t, which must outlive the workspace.
filter :: proc(t:^Tracked) -> vcs.Filter {
    return {procedure=proc(data:rawptr,path:string) -> bool {return tracked_path((^Tracked)(data),path)},data=t}
}

// The options of a workspace over a project: its filter and the asset driver.
workspace_options :: proc(t:^Tracked,drivers:[]vcs.Driver) -> vcs.Workspace_Options {
    return {filter=filter(t),drivers=drivers}
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
    if merge_refused(d.types,bytes,input.ours) {
        if _,f:=append(out,..input.ours);f!=nil {return .Error}
        return .Conflicted
    }
    if _,f:=append(out,..bytes);f!=nil {return .Error}
    return len(m.conflicts)==0 ? .Resolved : .Conflicted
}

// Rows of one table may name rows of another by what they hold, which a merge
// of rows does not follow: a merged asset that breaks the rules of its kind
// where ours kept them is no result, and the file conflicts whole, as ours.
@(private)
merge_refused :: proc(types:^asset.Types,merged,ours:[]u8) -> bool {
    return !kind_valid(types,merged) && kind_valid(types,ours)
}

// Whether bytes are an asset its kind allows (asset.verify) and, of a scene,
// one that reads.
@(private)
kind_valid :: proc(types:^asset.Types,bytes:[]u8) -> bool {
    a:asset.Asset
    if asset.asset_open(&a,bytes)!=.None {return false}
    defer asset.asset_close(&a)
    if asset.verify(&a,types,"")!="" {return false}
    if a.blob.header.kind!=asset.KIND_SCENE {return true}
    scene:asset.Scene
    if asset.scene_read(&scene,types,bytes)!=.None {return false}
    asset.scene_destroy(&scene)
    return true
}
