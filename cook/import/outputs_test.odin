package importer

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "mirai:asset"
import "mirai:std/base"
import mm "mirai:std/math"

// What a plugin that imports a source whole writes with Outputs: the root and
// the parts are the assets the sidecar of the source lists by kind and name,
// each in the folder its kind goes to, a part asked for twice is one, a part
// renamed in the source is another, and a run that fails leaves the sidecar as
// it was.
@(test)
the_outputs_of_a_source_are_the_assets_its_sidecar_lists :: proc(t:^testing.T) {
    root,assets:=test_assets(t,"outputs")
    if root=="" {return}
    source:=fmt.tprintf("%s/level.map",assets)
    bytes:="a level"
    testing.expect(t,os.write_entire_file(source,bytes)==nil)
    Pass :: struct {scene,floor:base.Asset_Id,materials:[2]base.Asset_Id,scene_path,floor_path:string,warnings:int}
    pass :: proc(t:^testing.T,root,source,bytes:string,names:[]string,failed:=false) -> (p:Pass,ok:bool) {
        o:Outputs
        error:=outputs_begin(&o,source,"level",u64(len(bytes)),base.hash64(transmute([]u8)bytes),import_version(0),{root=root})
        if !testing.expectf(t,error.code==.None,"%s",error.message) {return}
        root_error:Error
        p.scene,p.scene_path,root_error=output_root(&o,asset.KIND_SCENE,"level",".scene")
        testing.expect_value(t,root_error.code,Error_Code.None)
        p.floor,p.floor_path=output_part(&o,asset.KIND_MESH,"Floor",0,".mesh")
        ids,paths:=output_parts(&o,asset.KIND_MATERIAL,names,0,".mat",fmt.tprintf("%s/assets/level/materials",root))
        for id,at in ids {
            if at<len(p.materials) {p.materials[at]=id}
            testing.expectf(t,strings.contains(paths[at],"/assets/level/materials/"),"%s goes to the folder asked for",paths[at])
        }
        floor,floor_path:=output_part(&o,asset.KIND_MESH,"Floor",0,".mesh")
        twice,twice_paths:=output_parts(&o,asset.KIND_MATERIAL,names,0,".mat",fmt.tprintf("%s/assets/level/materials",root))
        for id,at in ids {testing.expect(t,twice[at]==id && twice_paths[at]==paths[at],"a document asked for again is the same")}
        testing.expect(t,floor==p.floor && floor_path==p.floor_path,"a part of the cache asked for again is the same")
        info:=output_info(&o,"Floor",0)
        testing.expect(t,base.text_get(info.source[:])=="assets/level.map" && info.source_hash==base.hash64(transmute([]u8)bytes),"an output names the source by its place in the root")
        output_written(&o,p.scene,asset.KIND_SCENE,"level",p.scene_path,false)
        report:=outputs_end(&o,failed)
        p.warnings=len(report.warnings)
        testing.expect(t,failed || len(report.assets)==1 && report.saved!="","the report lists what was recorded, and the sidecar")
        report_destroy(&report)
        return p,true
    }
    first,ok:=pass(t,root,source,bytes,{"Stone","Wood"})
    if !ok {return}
    testing.expect(t,first.scene!={} && first.floor!={} && first.materials[0]!={} && first.materials[0]!=first.materials[1])
    testing.expect(t,strings.contains(first.scene_path,"/assets/level/level.scene"),first.scene_path)
    testing.expect(t,strings.contains(first.floor_path,"/.mirai/imported/") && strings.has_suffix(first.floor_path,".mesh"),first.floor_path)
    file:=fmt.tprintf("%s.import",source)
    sidecar,found,_:=sidecar_load(source,context.temp_allocator)
    testing.expect(t,found && len(sidecar.outputs)==4)

    // Again: the same assets. A run that fails writes no sidecar.
    again,again_ok:=pass(t,root,source,bytes,{"Wood","Stone"})
    testing.expect(t,again_ok && again.scene==first.scene && again.floor==first.floor && again.floor_path==first.floor_path && again.materials=={first.materials[1],first.materials[0]} && again.warnings==0,"each output is found by its kind and name")
    kept,_:=os.read_entire_file(file,context.temp_allocator)
    _,_=pass(t,root,source,bytes,{"Clay"},failed=true)
    after,_:=os.read_entire_file(file,context.temp_allocator)
    testing.expect(t,len(kept)>0 && string(after)==string(kept),"a failed import leaves the sidecar as it was")

    // A part renamed in the source is a new one, and the one that is gone leaves the sidecar.
    renamed,renamed_ok:=pass(t,root,source,bytes,{"Wood","Granite"})
    testing.expect(t,renamed_ok && renamed.materials[0]==first.materials[1] && renamed.materials[1]!=first.materials[0],"Granite is not what Stone was")
    _,gone_ok:=pass(t,root,source,bytes,{"Granite"})
    sidecar,found,_=sidecar_load(source,context.temp_allocator)
    testing.expect(t,gone_ok && found && len(sidecar.outputs)==3,"Wood is no longer listed")
}

// A quad of one material, which a model of the test draws.
@(private="file")
quad_mesh :: proc(name:string,material:int) -> Imported_Mesh {
    vertices:=make([]asset.Vertex,4,context.temp_allocator)
    for corner,at in ([4][2]f32{{0,0},{1,0},{1,1},{0,1}}) {vertices[at]=test_vertex({corner.x,corner.y,0},{0,0,1},corner*0.5)}
    indices:=make([]u32,6,context.temp_allocator)
    copy(indices,[]u32{0,1,2,0,2,3})
    submeshes:=make([]Submesh,1,context.temp_allocator)
    submeshes[0]={index_count=6,bounds_max={1,1,0}}
    slots:=make([]Imported_Slot,1,context.temp_allocator)
    slots[0]={id=1,label="surface",material=material}
    return {name=name,vertices=vertices,indices=indices,submeshes=submeshes,slots=slots,skeleton=-1,bounds_max={1,1,0}}
}

// A model as a plugin builds one from what it read: a node with a mesh of the
// material that shows the image, and the materials named after them.
@(private="file")
model_of :: proc(name,mesh,image:string,materials:..string) -> Imported_Model {
    texels:=make([]u8,4*4*4,context.temp_allocator)
    for &texel,at in texels {texel=u8(at*7)}
    images:=make([]Imported_Image,1,context.temp_allocator)
    images[0]={name=image,made={texels=texels,width=4,height=4,format=.RGBA8},srgb=true}
    listed:=make([]Imported_Material,len(materials),context.temp_allocator)
    for material,at in materials {
        listed[at]={name=material,info=asset.MATERIAL_DEFAULTS}
        for &row in listed[at].images {row=-1}
    }
    listed[0].images[.Base_Color]=0
    meshes:=make([]Imported_Mesh,1,context.temp_allocator)
    meshes[0]=quad_mesh(mesh,0)
    nodes:=make([]Imported_Node,1,context.temp_allocator)
    nodes[0]={name=name,path=name,parent=-1,transform=mm.TRANSFORM_IDENTITY,mesh=0,visible=true}
    return {name=name,meshes=meshes,materials=listed,images=images,nodes=nodes}
}

// The models a plugin reads in a source it imports whole are parts of that
// import: one part of the kind and name another model gave is that asset,
// written once, and every part keeps its asset when the source is imported
// again. A name with '/' goes to that folder, made safe; the files the import
// reads are what its cache is built from, given before the cache is.
@(test)
the_models_of_an_import_share_their_parts_by_name :: proc(t:^testing.T) {
    root,assets:=test_assets(t,"outputs-models")
    if root=="" {return}
    source:=fmt.tprintf("%s/level.map",assets)
    bytes:="a level of two props"
    testing.expect(t,os.write_entire_file(source,bytes)==nil)
    package_file:=fmt.tprintf("%s/props.pkg",assets)
    testing.expect(t,os.write_entire_file(package_file,"the props")==nil)
    Pass :: struct {level:base.Asset_Id,crate,barrel:Import_Report,textures,materials,meshes:int,wood,stone:string}
    pass :: proc(t:^testing.T,root,source,bytes,package_file:string,root_first:bool) -> (p:Pass,ok:bool) {
        o:Outputs
        error:=outputs_begin(&o,source,"level",u64(len(bytes)),base.hash64(transmute([]u8)bytes),import_version(0),{root=root,textures=.Uncompressed})
        if !testing.expectf(t,error.code==.None,"%s",error.message) {return}
        testing.expect_value(t,output_input(&o,package_file).code,Error_Code.None)
        if root_first {p.level,_,_=output_root(&o,asset.KIND_SCENE,"level",".scene")}
        crate:=model_of("Crate","Meshes/SM_Crate","Textures/T_Wood","Materials/M_Wood")
        barrel:=model_of("Barrel","Meshes/SM_Barrel","Textures/T_Wood","Materials/M_Wood","../Materials/./M_Stone")
        p.crate,error=output_model(&o,&crate,context.temp_allocator)
        testing.expectf(t,error.code==.None,"%s",error.message)
        p.barrel,error=output_model(&o,&barrel,context.temp_allocator)
        testing.expectf(t,error.code==.None,"%s",error.message)
        late:=output_input(&o,fmt.tprintf("%s.more",package_file))
        testing.expect(t,late.code!=.None && output_input(&o,package_file).code==.None,"a new input once the cache is planned is refused, a known one is not")
        if !root_first {p.level,_,_=output_root(&o,asset.KIND_SCENE,"level",".scene")}
        report:=outputs_end(&o,false)
        defer report_destroy(&report)
        for written in report.assets {
            switch written.kind {
            case asset.KIND_TEXTURE: p.textures+=1
            case asset.KIND_MATERIAL: p.materials+=1
            case asset.KIND_MESH: p.meshes+=1
            }
            if written.name=="Materials/M_Wood" {p.wood=strings.clone(written.path,context.temp_allocator)}
            if written.name=="../Materials/./M_Stone" {p.stone=strings.clone(written.path,context.temp_allocator)}
        }
        return p,true
    }
    first,ok:=pass(t,root,source,bytes,package_file,false)
    if !ok {return}
    crate,barrel:=first.crate,first.barrel
    testing.expect(t,crate.material_ids[0]==barrel.material_ids[0] && crate.image_ids[0]==barrel.image_ids[0],"the material and the texture of both models are one asset")
    testing.expect(t,crate.mesh_ids[0]!=barrel.mesh_ids[0] && crate.prefab!=barrel.prefab && crate.prefab!={} && barrel.material_ids[1]!={})
    testing.expectf(t,first.textures==1 && first.materials==2 && first.meshes==2,"what is shared is written once: %v",first)
    testing.expectf(t,strings.has_suffix(crate.prefab_path,"/assets/level/Crate.scene"),"%s",crate.prefab_path)
    testing.expectf(t,strings.has_suffix(first.wood,"/assets/level/Materials/M_Wood.mat"),"%s",first.wood)
    testing.expectf(t,strings.has_suffix(first.stone,"/assets/level/Materials/M_Stone.mat"),"%s goes nowhere else",first.stone)

    // The registry lists the cache where the names say.
    r:asset.Registry
    asset.registry_init(&r,assets,allocator=context.temp_allocator,imported=fmt.tprintf("%s/.mirai/imported",root))
    testing.expect_value(t,asset.registry_scan(&r),asset.Error.None)
    listed:=make(map[string]base.Asset_Id,context.temp_allocator)
    for file in r.files {listed[file.path]=file.id}
    testing.expectf(t,listed["level/Meshes/SM_Crate.mesh"]==crate.mesh_ids[0] && listed["level/Textures/T_Wood.tex"]==crate.image_ids[0],"%v",listed)

    // Again, with the root asked for first among the scenes its sidecar lists: the same assets.
    again,again_ok:=pass(t,root,source,bytes,package_file,true)
    testing.expect(t,again_ok && again.level==first.level && again.crate.mesh_ids[0]==crate.mesh_ids[0] && again.barrel.material_ids[1]==barrel.material_ids[1] && again.crate.image_ids[0]==crate.image_ids[0] && again.crate.prefab==crate.prefab,"each part keeps its asset")

    // An input that changed changes what the cache is built from.
    sidecar,_,_:=sidecar_load(source,context.temp_allocator)
    before:=import_key(source,sidecar,import_version(0),false)
    testing.expect(t,os.write_entire_file(package_file,"other props")==nil)
    testing.expect(t,len(sidecar.inputs)==1 && sidecar.inputs[0]=="props.pkg" && import_key(source,sidecar,import_version(0),false)!=before,"the input is listed and counts in the key")
}
