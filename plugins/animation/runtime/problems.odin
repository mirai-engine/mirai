package anim

import "mirai:asset"
import "mirai:core"
import "mirai:host"
import "mirai:std/base"

// Why a cache of contents has none for id: what reading it gave, or no
// memory to keep it.
content_error :: proc(contents:[]$T,id:base.Asset_Id) -> asset.Error {
    for &content in contents {if content.id==id {return content.error}}
    return .Out_Of_Memory
}

// Reports that the asset id, which field of entity e names, cannot be used.
asset_problem :: proc(problems:^core.Problems,e:core.Entity,assets:^host.Assets,code,field:string,id:base.Asset_Id,error:asset.Error) {
    name:[base.ASSET_ID_TEXT]u8
    path:=host.assets_name(assets,id,&name)
    switch error {
    case .None:
    case .Not_Found:
        core.report(problems,e,code,"%s names %s, which is not in the assets; import or create it, or name one that is",field,path)
    case .Invalid:
        core.report(problems,e,code,"%s names %s, which is not of the kind it takes or holds nothing to use; name an asset of that kind",field,path)
    case .Version:
        core.report(problems,e,code,"%s names %s, of a version this build does not read; make it again with what made it (its import or the editor method), or open it with a newer engine if it is newer",field,path)
    case .Out_Of_Memory:
        core.report(problems,e,code,"%s names %s, which did not fit in memory; it is read again when the assets change: free memory",field,path)
    case .Truncated,.Not_An_Asset,.Corrupt,.Hash,.Too_Large,.Schema,.IO,.Codec_Missing,.Blocks_Old:
        core.report(problems,e,code,"%s names %s, which cannot be read (%v); import it again or write it again from the editor",field,path,error)
    }
}

// Reports a pose of a rig that does not compose.
pose_problem :: proc(problems:^core.Problems,e:core.Entity) {
    core.report(problems,e,"animation.pose_invalid","the pose of this rig does not compose: a bone has a value that is not finite or a scale of zero; check the clips, requests and parents that move it (animation.analyze)")
}

// Reports that memory ran out for what an entity (NONE: the world) animates:
// it keeps its last pose and tries again in the next tick.
memory_problem :: proc(problems:^core.Problems,e:core.Entity,what:string) {
    if e==core.NONE {
        core.report(problems,e,"animation.memory","out of memory for %s; it is tried again in the next tick: free memory, or animate fewer entities",what)
    } else {
        core.report(problems,e,"animation.memory","out of memory for %s; this entity keeps its last pose and tries again in the next tick: free memory, or animate fewer entities",what)
    }
}
