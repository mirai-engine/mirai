package previews_editor

import "base:intrinsics"
import "core:slice"
import "mirai:asset"
import "mirai:editor"
import erender "mirai:engine/render"
import "mirai:host"
import "mirai:std/base"
import "mirai:std/serial"

// What the thumbnail of an asset that moves a model shows, found through the
// registry. An animation shows what plays it: the first entity of a prefab or a
// scene that depends on it whose components name it, as the skinned mesh of
// that entity or under it whose skeleton its tracks move, else as the
// entities under it. When nothing plays it, it shows the skinned mesh whose
// skeleton has the most bones its tracks move, the first by path of those
// with as many.
Thumbnail_Model :: struct {
    mesh:base.Asset_Id,     // a skinned mesh, drawn through its skeleton
    document:base.Asset_Id, // else a prefab or a scene, whose entities are drawn
    root:base.Entity_Id,    // the entity of document whose subtree is drawn; 0: all of it
}

// A skinned mesh of the registry and the bones of its skeleton in Thumbnail_Models.bones.
Thumbnail_Skin :: struct {
    mesh,skeleton:base.Asset_Id,
    first,count:u32,
}

// The model given to an animation and what it was found from.
Thumbnail_Match :: struct {
    animation:base.Asset_Id,
    inputs:u64,  // the stamps of the files it was read from and the skins it was compared with
    checked:u64, // the revision of the registry they were compared at
    model:Thumbnail_Model,
}

Thumbnail_Models :: struct {
    revision:u64, // of the registry the skins were listed at
    skins_key:u64,
    skins:[dynamic]Thumbnail_Skin,
    bones:[dynamic]u64,   // targets of the bones of the skeletons of skins
    matches:[dynamic]Thumbnail_Match,
    targets:[dynamic]u64, // the targets the tracks of an animation move, sorted
}

@(private)
thumbnail_models_destroy :: proc(m:^Thumbnail_Models) {
    delete(m.skins);delete(m.bones);delete(m.matches);delete(m.targets)
    m^={}
}

// What changes when the content of a file of the registry does; 0 for an id it does not have.
@(private)
registry_stamp :: proc(r:^asset.Registry,id:base.Asset_Id) -> u64 {
    file,found:=asset.registry_find(r,id)
    if !found || id=={} {return 0}
    return file.content_hash|1
}

// The skinned meshes of the registry, by path, with the bones of their skeletons.
@(private)
skinned_meshes :: proc(m:^Thumbnail_Models,a:^host.Assets) -> []Thumbnail_Skin {
    if a==nil {return nil}
    thumbnail_skins_refresh(m,a)
    return m.skins[:]
}

// Lists the skinned meshes of the registry and the bones of their skeletons
// again when the registry changed what they are.
@(private)
thumbnail_skins_refresh :: proc(m:^Thumbnail_Models,a:^host.Assets) {
    r:=&a.registry
    if m.revision==r.revision && m.skins_key!=0 {return}
    m.revision=r.revision
    key:=u64(0x736b696e73)
    for &file in r.files {
        if file.state!=.Asset || file.kind!=asset.KIND_MESH {continue}
        skeleton:=asset.registry_skeleton(r,&file)
        if skeleton=={} {continue}
        key=base.hash_combine(base.hash_combine(base.hash_combine(key,file.id[0]~file.id[1]),skeleton[0]~skeleton[1]),registry_stamp(r,skeleton))
    }
    if key==m.skins_key {return}
    m.skins_key=key
    clear(&m.skins)
    clear(&m.bones)
    for &file in r.files {
        if file.state!=.Asset || file.kind!=asset.KIND_MESH {continue}
        skeleton:=asset.registry_skeleton(r,&file)
        if skeleton=={} {continue}
        skin:=Thumbnail_Skin{mesh=file.id,skeleton=skeleton,first=u32(len(m.bones))}
        read:=false
        for other in m.skins {
            if other.skeleton!=skeleton {continue}
            skin.first,skin.count,read=other.first,other.count,true
            break
        }
        if !read {
            data:asset.Asset
            if host.assets_file(a,skeleton,asset.KIND_SKELETON,&data)!=.None {continue}
            if view,error:=asset.skeleton_view(&data,&a.types);error==.None {
                for bone in view.bones {append(&m.bones,bone.target)}
            }
            asset.asset_close(&data)
            skin.count=u32(len(m.bones))-skin.first
        }
        if skin.count>0 {append(&m.skins,skin)}
    }
}

// How many bones of a skeleton the targets of an animation move.
@(private)
bones_moved :: proc(bones:[]u64,targets:[]u64) -> (moved:int) {
    for bone in bones {
        if _,found:=slice.binary_search(targets,bone);found {moved+=1}
    }
    return
}

// The targets the tracks of an animation move, sorted, into m.targets. False when it cannot be read.
@(private)
animation_targets :: proc(m:^Thumbnail_Models,a:^host.Assets,id:base.Asset_Id) -> bool {
    clear(&m.targets)
    data:asset.Asset
    if host.assets_file(a,id,asset.KIND_ANIMATION,&data)!=.None {return false}
    defer asset.asset_close(&data)
    view,error:=asset.animation_view(&data,&a.types)
    if error!=.None {return false}
    for &track in view.tracks {
        if target:=serial.text_field(track.target[:]);target!="" {append(&m.targets,base.name_hash(target))}
    }
    slice.sort(m.targets[:])
    return true
}

// The model of an animation (Thumbnail_Model), found again only when a file it is found from changed.
@(private)
thumbnail_animation_model :: proc(m:^Thumbnail_Models,a:^host.Assets,id:base.Asset_Id) -> Thumbnail_Model {
    if a==nil || id=={} {return {}}
    thumbnail_skins_refresh(m,a)
    r:=&a.registry
    match:^Thumbnail_Match
    for &each in m.matches {
        if each.animation==id {match=&each;break}
    }
    if match!=nil && match.checked==r.revision {return match.model}
    users:=asset.registry_dependents(r,id)
    inputs:=base.hash_combine(registry_stamp(r,id),m.skins_key)
    for at in users {
        file:=&r.files[at]
        if file.kind==asset.KIND_PREFAB || file.kind==asset.KIND_SCENE {inputs=base.hash_combine(inputs,registry_stamp(r,file.id))}
    }
    if match==nil {
        append(&m.matches,Thumbnail_Match{animation=id})
        match=&m.matches[len(m.matches)-1]
    }
    match.checked=r.revision
    if match.inputs==inputs {return match.model}
    match.inputs=inputs
    match.model={}
    if !animation_targets(m,a,id) {return {}}
    for at in users {
        file:=&r.files[at]
        if file.kind!=asset.KIND_PREFAB && file.kind!=asset.KIND_SCENE {continue}
        if model,found:=animation_player(m,a,file,id);found {
            match.model=model
            return model
        }
    }
    most:=0
    for skin in m.skins {
        if moved:=bones_moved(m.bones[skin.first:][:skin.count],m.targets[:]);moved>most {most,match.model=moved,{mesh=skin.mesh}}
    }
    return match.model
}

// What plays an animation in a prefab or a scene: its first entity whose
// components name the animation, as the skinned mesh of it or under it whose
// skeleton the animation moves, else as its subtree. found is false when no
// entity names it.
@(private)
animation_player :: proc(m:^Thumbnail_Models,a:^host.Assets,file:^asset.Registry_File,animation:base.Asset_Id) -> (model:Thumbnail_Model,found:bool) {
    data:asset.Asset
    if host.assets_file(a,file.id,file.kind,&data)!=.None {return}
    defer asset.asset_close(&data)
    view,error:=asset.scene_view(&data,&a.types)
    if error!=.None || asset.scene_view_check(view,context.temp_allocator)!=.None {return}
    player:=-1
    refs:=make([dynamic]serial.Ref,context.temp_allocator)
    for &component in view.components {
        clear(&refs)
        if component.size==0 || !serial.refs_collect(&data.schema,component.type,&refs) {continue}
        values,values_error:=asset.scene_component_values(&data,&component)
        if values_error!=.None || len(values)<len(component.entities)*component.size {continue}
        for row,i in component.entities {
            if player>=0 && int(row)>=player {break}
            for ref in refs {
                if ref.kind!=.Asset || int(ref.offset)+size_of(base.Asset_Id)>component.size {continue}
                if intrinsics.unaligned_load((^base.Asset_Id)(&values[i*component.size+int(ref.offset)]))==animation {player=int(row);break}
            }
        }
    }
    if player<0 {return}
    found=true
    model={document=file.id,root=view.ids[player]}
    renderers,has:=editor.document_column(&data,&view,&a.types,"Mesh_Renderer",erender.Mesh_Renderer)
    if renderers==nil {return}
    under:=editor.document_subtree(view,player)
    for row in 0..<len(view.ids) {
        if !under[row] || !has[row] {continue}
        for skin in m.skins {
            if skin.mesh!=renderers[row].mesh {continue}
            if bones_moved(m.bones[skin.first:][:skin.count],m.targets[:])>0 {return {mesh=skin.mesh},true}
        }
    }
    return
}
