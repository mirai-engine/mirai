package importer

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "mirai:asset"
import anim "mirai:std/anim"
import "mirai:std/base"
import "mirai:std/serial"
import "mirai:store"

// The documents of a package (materials, skeletons, clips, scenes) are edited
// in each project that uses it. Its build keeps them as the source gives them,
// their baseline; a project gets a file of each, written from the baseline the
// first time and followed on every later import: the file keeps what was
// changed in it after the last import. A material keeps the fields changed
// over what its source gave, its overlays and hidden names; a skeleton keeps
// the body parts set by hand and the sockets added to it on bones it still
// has; a clip keeps the root set by hand while its bone is still in its
// skeleton. Any document keeps the owner its file has, so one taken out of the
// package stays out.

// The baseline of a skeleton the clips followed with it play on.
Followed_Skeleton :: struct {
    id:base.Asset_Id,
    path:string,
}

// A document documents_follow wrote.
Followed :: struct {
    id:base.Asset_Id,
    kind:asset.Fourcc,
    path:string,
    warning:string, // what of the file could not be kept; "" when all
}

// Writes into folder the documents of the build b of the package p, or
// follows those whose ids registry has where it has them. A new file is
// named as the package names its document, under folder. What it wrote, in
// allocator. B4: the per-project step of an ingest calls it.
documents_follow :: proc(s:^store.Store,p:^asset.Package,b:^asset.Build,folder:string,registry:^asset.Registry,allocator:=context.allocator) -> (written:[dynamic]Followed,error:Error) {
    written=make([dynamic]Followed,allocator)
    types:asset.Types
    asset.types_init(&types,context.temp_allocator)
    defer asset.types_destroy(&types)
    skeletons:=make([dynamic]Followed_Skeleton,context.temp_allocator)
    for o in b.outputs {
        if o.kind!=asset.KIND_SKELETON {continue}
        if blob,path_error:=store.blob_path(s,o.blob,context.temp_allocator);path_error==.None {append(&skeletons,Followed_Skeleton{o.id,blob})}
    }
    taken:=make(map[string]bool,context.temp_allocator)
    for o in b.outputs {
        if asset.import_cached(o.kind) {continue}
        blob,path_error:=store.blob_path(s,o.blob,context.temp_allocator)
        if path_error!=.None {return written,error_make(.Not_Found,"the store at %s has no blob of the document %v of the package %v: fetch it from a peer that has it",s.root,o.id,p.id,allocator=context.temp_allocator)}
        target:string
        if registry!=nil {
            if file,found:=asset.registry_find(registry,o.id);found && file.kind==o.kind {target=asset.registry_file_path(registry,file.path,context.temp_allocator)}
        }
        if target=="" {
            name:="unnamed"
            for &a in p.assets {
                if a.id==o.id {name=asset.safe_path(a.name)}
            }
            info,_:=asset.kind_info(o.kind)
            for at:=1;;at+=1 {
                candidate:=fmt.tprintf("%s/%s%s",folder,name,info.extension) if at==1 else fmt.tprintf("%s/%s (%d)%s",folder,name,at,info.extension)
                key:=strings.to_lower(candidate,context.temp_allocator)
                if taken[key] || os.exists(candidate) {continue}
                taken[key]=true
                target=candidate
                break
            }
            if under:=filepath.dir(target);!os.is_dir(under) {_=os.make_directory_all(under)}
        }
        warning,follow_error:=document_follow(&types,o.kind,blob,target,skeletons[:],registry)
        if follow_error!=.None {return written,error_make(.Write,"%s could not be written: %v",target,follow_error,allocator=context.temp_allocator)}
        append(&written,Followed{id=o.id,kind=o.kind,path=strings.clone(target,allocator),warning=strings.clone(warning,allocator)})
    }
    return written,{}
}

// Writes the document whose baseline is the file at baseline to target, or
// follows the file target has. skeletons: the baselines the clips of an
// animation may play on, else registry has them. The warning, in the temp
// allocator, says what of the file could not be kept.
document_follow :: proc(types:^asset.Types,kind:asset.Fourcc,baseline,target:string,skeletons:[]Followed_Skeleton,registry:^asset.Registry) -> (warning:string,error:asset.Error) {
    given:asset.Asset
    asset.asset_load(&given,baseline,context.temp_allocator) or_return
    defer asset.asset_close(&given)
    previous:asset.Asset
    existed:=os.exists(target) && asset.asset_load(&previous,target,context.temp_allocator)==.None
    defer if existed {asset.asset_close(&previous)}
    owner:=previous.blob.header.owner if existed else given.blob.header.owner
    id:=given.blob.header.id
    switch kind {
    case asset.KIND_MATERIAL:
        view:=asset.material_view(&given,types) or_return
        desc:=asset.Material_Desc{id=id,owner=owner,info=view.info^,imported=view.imported,parameters=view.parameters,imported_parameters=view.imported_parameters,source=view.source}
        if existed && previous.blob.header.id==id {
            if kept,kept_error:=asset.material_view(&previous,types);kept_error==.None {
                desc.info=asset.material_follow(types,kept,view.imported^ if view.imported!=nil else view.info^)
                desc.parameters=asset.material_parameters_follow(kept,view.imported_parameters,context.temp_allocator)
                desc.overlays,desc.hidden=kept.overlays,kept.hidden
            }
        }
        return "",asset.material_save(target,types,desc)
    case asset.KIND_SKELETON:
        view:=asset.skeleton_view(&given,types) or_return
        kept:^asset.Skeleton_View
        kept_view:asset.Skeleton_View
        if existed {
            view_error:asset.Error
            kept_view,view_error=asset.skeleton_view(&previous,types)
            if view_error==.None {kept=&kept_view}
            if view_error==.Version {warning=fmt.tprintf("%s is of a version this build does not read: the body parts, axes and sockets set by hand on it were not kept; set them again",target)}
        }
        body:asset.Skeleton_Body
        body_parts:[len(anim.Body_Part)]asset.Skeleton_Body_Part
        count,_:=skeleton_body(kept,view.bones,&body,&body_parts)
        sockets:=make([dynamic]asset.Skeleton_Socket,context.temp_allocator)
        append(&sockets,..view.sockets)
        skeleton_sockets_kept(kept,view.bones,&sockets)
        return warning,asset.skeleton_save(target,types,{id=id,owner=owner,bones=view.bones,sockets=sockets[:],body=&body if count>0 else nil,body_parts=body_parts[:count],source=view.source})
    case asset.KIND_ANIMATION:
        view:=asset.animation_view(&given,types) or_return
        clips,editable:=asset.animation_descs(view,context.temp_allocator)
        if !editable {break}
        if existed {
            kept,view_error:=asset.animation_view(&previous,types)
            if view_error==.Version {warning=fmt.tprintf("%s is of a version this build does not read: the root bones set by hand on its clips were not kept; set them again",target)}
            for &clip in clips {
                for &old in kept.clips {
                    if base.text_get(old.name[:])!=clip.name || !old.root.translation && !old.root.rotation {continue}
                    bones,found:=skeleton_bones(types,clip.skeleton,skeletons,registry)
                    if !found || asset.skeleton_bone_index(bones,old.root.bone)>=0 {clip.root=old.root}
                    break
                }
            }
        }
        return warning,asset.animation_save(target,types,{id=id,owner=owner,clips=clips,source=view.source})
    }
    // Any other document is the baseline, with the owner of its file.
    data,read_error:=serial.file_read(baseline,context.temp_allocator)
    if read_error!=.None {return "",.IO}
    if owner!=given.blob.header.owner {asset.header_owner_set(data,owner) or_return}
    if serial.file_write_atomic(target,data)!=.None {return "",.IO}
    return "",.None
}

// The bones of the skeleton id: a baseline of skeletons, else the file
// registry has. In the temp allocator.
@(private="file")
skeleton_bones :: proc(types:^asset.Types,id:base.Asset_Id,skeletons:[]Followed_Skeleton,registry:^asset.Registry) -> (bones:[]asset.Skeleton_Bone,found:bool) {
    path:string
    for s in skeletons {
        if s.id==id {path=s.path}
    }
    if path=="" && registry!=nil {
        if file,known:=asset.registry_find(registry,id);known {path=asset.registry_file_path(registry,file.path,context.temp_allocator)}
    }
    if path=="" {return}
    a:asset.Asset
    if asset.asset_load(&a,path,context.temp_allocator)!=.None {return}
    view,error:=asset.skeleton_view(&a,types)
    if error!=.None {return}
    return view.bones,true
}

// The sockets of the file an import replaces that it does not make again (one a person or an agent
// added, such as where a weapon hangs), on a bone it still has. Those it makes (named by the
// source, bone.*, grips) are made again from the source.
@(private)
skeleton_sockets_kept :: proc(previous:^asset.Skeleton_View,bones:[]asset.Skeleton_Bone,sockets:^[dynamic]asset.Skeleton_Socket) {
    if previous==nil {return}
    made:=len(sockets)
    for &socket in previous.sockets {
        name:=base.text_get(socket.name[:])
        if strings.has_prefix(name,"bone.") {continue}
        again:=false
        for &other in sockets[:made] {if other.name==socket.name {again=true;break}}
        if again {continue}
        for &bone in bones {if bone.path==socket.bone {append(sockets,socket);break}}
    }
}

// The body of an imported skeleton: found on its bones, keeping the parts a
// person set in the file it replaces when their bones are still there.
// Returns how many parts it wrote, 0 for a skeleton without a body, and the map they come from.
@(private)
skeleton_body :: proc(previous_file:^asset.Skeleton_View,bones:[]asset.Skeleton_Bone,body:^asset.Skeleton_Body,parts:^[len(anim.Body_Part)]asset.Skeleton_Body_Part) -> (count:int,map_:anim.Body_Map) {
    previous:=anim.body_map_empty()
    if previous_file!=nil {
        previous=asset.skeleton_body_map(bones,previous_file.body,previous_file.body_parts)
        for part in anim.Body_Part {if part not_in previous.manual {previous.bones[part],previous.confidence[part]=-1,0}}
    }
    found:bool
    map_,found=asset.skeleton_body_detect(bones,previous)
    if !found {return 0,map_}
    count,_=asset.skeleton_body_rows(bones,map_,body,parts)
    return count,map_
}
