package prefab

import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "mirai:asset"
import importer "mirai:cook/import"
import "mirai:core"
import render "mirai:engine/render"
import "mirai:std/base"
import mm "mirai:std/math"

// Prefabs built from what an importer read, written as the document a world
// captures, with the components of the engine by the name of their type.

Error :: enum u8 {
    None,
    Empty,   // the model has no nodes: there is nothing to instantiate
    Write,   // the document could not be built
    Save,
}

Model_Report :: struct {
    entities:int,
    cut_names:int, // names longer than a core.Name holds
}

// The prefab of a model as the asset id at path: the root of its import,
// which the parts the import wrote name as their owner. source is where it
// came from (Import_Report.prefab_info).
model_prefab :: proc(model:^importer.Imported_Model,assets:^importer.Import_Report,types:^asset.Types,id:base.Asset_Id,name,path:string,source:^asset.Import_Info=nil,allocator:=context.allocator) -> (report:Model_Report,error:Error) {
    count:=len(model.nodes)
    if count==0 {return {},.Empty}
    scene:asset.Scene
    if asset.scene_init(&scene,types,id,allocator)!=.None {return {},.Write}
    defer asset.scene_destroy(&scene)
    roots:=0
    for node in model.nodes {
        if node.parent<0 {roots+=1}
    }
    top:=base.Entity_Id(0)
    wrap:=roots!=1 || assets.animation_id!={} || len(model.skeletons)>0
    if wrap {
        top=base.Entity_Id(count+1)
        if !entity_add(&scene,top,0,name,core.TRANSFORM_IDENTITY,&report) {return report,.Write}
    }
    rig_ids:=make([]base.Entity_Id,len(model.skeletons),context.temp_allocator)
    for skeleton,i in model.skeletons {
        if i>=len(assets.skeleton_ids) {return report,.Write}
        rig_ids[i]=top
        if len(model.skeletons)>1 {
            rig_ids[i]=base.Entity_Id(count+2+i)
            if !entity_add(&scene,rig_ids[i],top,skeleton.name,core.TRANSFORM_IDENTITY,&report) {return report,.Write}
        }
    }
    // A rig shows the first skinned mesh of its skeleton and poses it; the
    // other skinned meshes of that skeleton follow it with Pose_Source.
    shown_by_rig:=make([]bool,count,context.temp_allocator)
    rig_shows:=make([]bool,len(rig_ids),context.temp_allocator)
    for node,i in model.nodes {
        if node.mesh<0 || node.mesh>=len(assets.mesh_ids) || len(model.meshes[node.mesh].skin)==0 {continue}
        s:=model.meshes[node.mesh].skeleton
        if s<0 || s>=len(rig_ids) || rig_shows[s] {continue}
        rig_shows[s],shown_by_rig[i]=true,true
        shown:=render.Mesh_Renderer{mesh=assets.mesh_ids[node.mesh]}
        if asset.scene_set(&scene,rig_ids[s],"Mesh_Renderer",&shown)!=.None {return report,.Write}
        if !model_morphs(&scene,rig_ids[s],node,model.meshes[node.mesh],true) {return report,.Write}
        if !node.visible {
            hidden:=render.Hidden{}
            if asset.scene_set(&scene,rig_ids[s],"Hidden",&hidden)!=.None {return report,.Write}
        }
    }
    bone_rig:=make([]int,count,context.temp_allocator)
    keep:=make([]bool,count,context.temp_allocator)
    for node,i in model.nodes {
        bone_rig[i]=-1
        for skeleton,s in model.skeletons {
            for bone in skeleton.bones {if bone.target==node.target {bone_rig[i]=s;break}}
            if bone_rig[i]>=0 {break}
        }
        _,light:=node.light.?
        keep[i]=(bone_rig[i]<0 || node.mesh>=0 || light) && !shown_by_rig[i]
    }
    for node,i in model.nodes {
        if !keep[i] {continue}
        own:=base.Entity_Id(i+1)
        parent:=top
        transform:=node.transform
        ancestor:=node.parent
        for ancestor>=0 && ancestor<i {
            if keep[ancestor] {parent=base.Entity_Id(ancestor+1);break}
            transform=mm.transform_compose(model.nodes[ancestor].transform,transform)
            ancestor=model.nodes[ancestor].parent
        }
        if light,has:=node.light.?;has && light.kind==.Rect {transform.scale.x*=light.size.x;transform.scale.y*=light.size.y}
        if !entity_add(&scene,own,parent,node.name,core.Transform(transform),&report) {return report,.Write}
        if node.path!="" && bone_rig[i]<0 {
            target:Animation_Target
            base.text_set(target.path[:],node.path)
            if asset.scene_set(&scene,own,"Animation_Target",&target)!=.None {return report,.Write}
        }
        skinned:=node.mesh>=0 && len(model.meshes[node.mesh].skin)>0
        if node.mesh>=0 && node.mesh<len(assets.mesh_ids) {
            shown:=render.Mesh_Renderer{mesh=assets.mesh_ids[node.mesh]}
            if asset.scene_set(&scene,own,"Mesh_Renderer",&shown)!=.None {return report,.Write}
            if !model_morphs(&scene,own,node,model.meshes[node.mesh],bone_rig[i]>=0) {return report,.Write}
            if skinned {
                mesh:=model.meshes[node.mesh]
                if mesh.skeleton<0 || mesh.skeleton>=len(rig_ids) {return report,.Write}
                skin:=Pose_Source{rig=base.Entity(rig_ids[mesh.skeleton])}
                if asset.scene_set(&scene,own,"Pose_Source",&skin)!=.None {return report,.Write}
            }
        }
        if !skinned {
            attached:=i if bone_rig[i]>=0 else node.parent
            offset:=mm.TRANSFORM_IDENTITY if attached==i else node.transform
            for attached>=0 && bone_rig[attached]<0 {
                offset=mm.transform_compose(model.nodes[attached].transform,offset)
                attached=model.nodes[attached].parent
            }
            if attached>=0 {
                socket:=Bone_Attachment{rig=base.Entity(rig_ids[bone_rig[attached]]),offset=offset,enabled=true}
                base.text_set(socket.socket[:],fmt.tprintf("bone.%016x",base.name_hash(model.nodes[attached].path)))
                if asset.scene_set(&scene,own,"Bone_Attachment",&socket)!=.None {return report,.Write}
            }
        }
        if !node.visible {
            hidden:=render.Hidden{}
            if asset.scene_set(&scene,own,"Hidden",&hidden)!=.None {return report,.Write}
        }
        if light,has:=node.light.?;has && !model_light(&scene,own,light,node.name,assets) {return report,.Write}
    }
    // One root, the model's own or the entity that wraps several: the scene is a prefab.
    root,rooted:=asset.prefab_root(&scene)
    if !rooted {return report,.Write}
    scene.doc.flags+={.Prefab}
    if assets.animation_id!={} {
        animation:=Animation{asset=assets.animation_id,speed=1,weight=1,loop=true,playing=true,fade=0.2}
        if asset.scene_set(&scene,root,"Animation",&animation)!=.None {return report,.Write}
        if len(rig_ids)>1 {for rig in rig_ids {if asset.scene_set(&scene,rig,"Animation",&animation)!=.None {return report,.Write}}}
    }
    scene.info.id_counter=max(scene.info.id_counter,u64(count+len(rig_ids)+1))
    if asset.import_put(&scene.doc,types,source)!=.None {return report,.Write}
    os.make_directory_all(filepath.dir(path))
    if asset.scene_save(&scene,path)!=.None {return report,.Save}
    report.entities=asset.scene_entity_count(&scene)
    return report,.None
}

@(private="file")
Animation_Target :: struct {path:[asset.NODE_PATH_CAPACITY]u8 `mirai:"text"`}

@(private="file")
Pose_Source :: struct {rig:base.Entity}

@(private)
Morph_Weight_Mode :: enum u8 {Default,Override,Additive}
@(private)
Morph_Weights :: struct {
    source:base.Entity,
    path:[asset.NODE_PATH_CAPACITY]u8 `mirai:"text,hidden"`,
    names:[asset.MORPH_WEIGHTS]u64 `mirai:"hidden"`,
    values:[asset.MORPH_WEIGHTS]f32 `mirai:"hidden"`,
    modes:[asset.MORPH_WEIGHTS]Morph_Weight_Mode `mirai:"hidden"`,
}

// The light of a node as the light of its entity: they shine toward -Z of
// their node, in the units of Imported_Light.
@(private="file")
model_light :: proc(scene:^asset.Scene,entity:base.Entity_Id,light:importer.Imported_Light,name:string,assets:^importer.Import_Report) -> bool {
    switch light.kind {
    case .Directional:
        sun:=render.Sun{color=light.color,illuminance=light.intensity,disc=true}
        return asset.scene_set(scene,entity,"Sun",&sun)==.None
    case .Point:
        point:=render.Point_Light{color=light.color,intensity=light.intensity,range=light_range(light),radius=light.radius.? or_else render.POINT_LIGHT_DEFAULT.radius}
        return asset.scene_set(scene,entity,"Point_Light",&point)==.None
    case .Spot:
        angle:=clamp(light.outer_cone,render.SPOT_MIN,render.SPOT_MAX)
        if angle!=light.outer_cone {
            append(&assets.warnings,fmt.aprintf("the spot of %s has an outer cone of %.1f°, out of 1° to 89°: it was given %.1f°",name,light.outer_cone*mm.DEG_PER_RAD,angle*mm.DEG_PER_RAD,allocator=assets.allocator))
        }
        spot:=render.Spot_Light{color=light.color,intensity=light.intensity,range=light_range(light),radius=light.radius.? or_else render.SPOT_LIGHT_DEFAULT.radius,angle=angle}
        return asset.scene_set(scene,entity,"Spot_Light",&spot)==.None
    case .Rect:
        rect:=render.Rect_Light{color=light.color,luminance=light.intensity,range=light_range(light)}
        return asset.scene_set(scene,entity,"Rect_Light",&rect)==.None
    }
    return true
}

// Where a light stops: its range, or without one, where what it gives a
// surface that faces it falls to LIGHT_REACH lux; a rectangle gives as many
// candelas as nits times its area. The lights of a scene need one.
@(private="file")
light_range :: proc(light:importer.Imported_Light) -> f32 {
    if light.range>0 {return light.range}
    candelas:=light.intensity
    if light.kind==.Rect {candelas*=light.size.x*light.size.y}
    return math.sqrt(max(candelas,0)/LIGHT_REACH)
}

@(private="file")
LIGHT_REACH :: 0.5 // lux

// The weights of a node that morphs where they differ from its mesh's, and
// the path of its morph curves on an entity without an Animation_Target.
@(private="file")
model_morphs :: proc(scene:^asset.Scene,entity:base.Entity_Id,node:importer.Imported_Node,mesh:importer.Imported_Mesh,named:bool) -> bool {
    if len(mesh.morphs)==0 {return true}
    value:Morph_Weights
    count:=0
    for weight,i in node.morph_weights {
        if i>=len(mesh.morphs) || weight==mesh.morphs[i].weight {continue}
        if count>=len(value.names) {return false}
        value.names[count],value.values[count],value.modes[count]=base.name_hash(base.text_get(mesh.morphs[i].name[:])),weight,.Default
        count+=1
    }
    named:=named && node.path!=""
    if named {base.text_set(value.path[:],node.path)}
    if count==0 && !named {return true}
    return asset.scene_set(scene,entity,"Morph_Weights",&value)==.None
}
@(private="file")
Bone_Attachment :: struct {rig:base.Entity,socket:[64]u8 `mirai:"text"`,offset:mm.Transform,enabled:bool}

@(private="file")
Animation :: struct {
    asset:base.Asset_Id,
    clip:[64]u8 `mirai:"text"`,
    speed:f32,
    loop,playing:bool,
    weight,fade:f32,
}

@(private)
entity_add :: proc(scene:^asset.Scene,id,parent:base.Entity_Id,name:string,transform:core.Transform,report:^Model_Report) -> bool {
    label:core.Name
    if !base.text_set(label.text[:],name) {report.cut_names+=1}
    if _,error:=asset.scene_entity_add(scene,id,parent,base.text_get(label.text[:]));error!=.None {return false}
    transform:=transform
    return asset.scene_set(scene,id,"Transform",&transform)==.None
}

// Imports a model of one of formats into folder: its assets and, when it has
// nodes, the prefab of its hierarchy, which the report lists last. keep, when
// given, receives the model that was read; its caller destroys it.
model_import :: proc(path,folder:string,formats:[]importer.Format,options:importer.Import_Options,allocator:=context.allocator,keep:^importer.Imported_Model=nil) -> (report:importer.Import_Report,error:importer.Error) {
    model:importer.Imported_Model
    if model,error=importer.import_model(path,formats,options,allocator);error.code!=.None {return}
    defer if keep!=nil {keep^=model} else {importer.model_destroy(&model)}
    return model_write(&model,path,folder,options,allocator)
}

// Writes a model read from path as model_import does: its assets and the
// prefab of its hierarchy; only its clips with Import_Settings.skeleton.
model_write :: proc(model:^importer.Imported_Model,path,folder:string,options:importer.Import_Options,allocator:=context.allocator) -> (report:importer.Import_Report,error:importer.Error) {
    if report,error=importer.import_write(model,folder,options,allocator);error.code!=.None {return}
    if len(model.nodes)==0 || report.settings.skeleton!={} {return report,{}}
    name:=filepath.stem(path)
    source:=importer.source_path(options,path)
    id,target:=report.prefab,report.prefab_path
    types:asset.Types
    asset.types_init(&types)
    defer asset.types_destroy(&types)
    prefab_zone:=importer.zone_begin(options,"prefab.save")
    built,prefab_error:=model_prefab(model,&report,&types,id,name,target,&report.prefab_info,allocator)
    base.profile_end(prefab_zone)
    if prefab_error!=.None {
        importer.report_destroy(&report)
        return {},importer.error_make(.Write,"the prefab %s could not be written: %v",target,prefab_error)
    }
    size:int
    if info,stat_error:=os.stat(target,context.temp_allocator);stat_error==nil {size=int(info.size)}
    append(&report.assets,importer.Written{
        id=id,kind=asset.KIND_SCENE,name=strings.clone(name,allocator),path=strings.clone(target,allocator),source=strings.clone(source,allocator),bytes=size,
        detail=fmt.aprintf("%d %s",built.entities,built.entities==1?"entity":"entities",allocator=allocator),
    })
    return report,{}
}
