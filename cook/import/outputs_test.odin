package importer

import "core:fmt"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import "mirai:asset"
import "mirai:cook/textures"
import "mirai:std/base"
import mm "mirai:std/math"
import "mirai:store"

// The package an import wrote, from the store.
@(private="file")
test_package :: proc(t:^testing.T,s:^store.Store,report:Import_Report) -> (p:asset.Package,b:asset.Build,ok:bool) {
    error:asset.Error
    if p,error=asset.package_get(s,report.manifest,context.temp_allocator);!testing.expect_value(t,error,asset.Error.None) {return}
    if b,error=asset.build_get(s,report.build,context.temp_allocator);!testing.expect_value(t,error,asset.Error.None) {return}
    return p,b,true
}

// What a plugin that imports a source whole writes with Outputs: the root and
// the parts are the assets the package of the source lists by kind and name,
// a document also in the folder its kind goes to, a part asked for twice is
// one, a part renamed in the source is another, and a run that fails records
// nothing.
@(test)
the_outputs_of_a_source_are_the_assets_its_package_lists :: proc(t:^testing.T) {
    root,assets,s:=test_assets(t,"outputs")
    if root=="" {return}
    source:=fmt.tprintf("%s/level.map",assets)
    bytes:="a level"
    PROGRAM :: "//! mirai surface stone\nnamespace stone {}\n"
    testing.expect(t,os.write_entire_file(source,bytes)==nil)
    Pass :: struct {scene,floor:base.Asset_Id,materials:[2]base.Asset_Id,floor_blob:store.Hash,report:Import_Report,warnings:int}
    pass :: proc(t:^testing.T,s:^store.Store,root,source,bytes:string,names:[]string,failed:=false) -> (p:Pass,ok:bool) {
        o:Outputs
        error:=outputs_begin(&o,source,"level",u64(len(bytes)),base.hash64(transmute([]u8)bytes),import_version(0),{store=s,root=root,documents=fmt.tprintf("%s/assets",root)},allocator=context.temp_allocator)
        if !testing.expectf(t,error.code==.None,"%s",error.message) {return}
        testing.expect_value(t,output_catalog_path(&o,"levels/../escape").code,Error_Code.Malformed)
        testing.expect_value(t,output_catalog_path(&o,"Caves/Levels").code,Error_Code.None)
        program,program_error:=output_program(&o,PROGRAM)
        repeated,repeat_error:=output_program(&o,PROGRAM)
        testing.expect(t,program_error.code==.None && repeat_error.code==.None && program==repeated)
        root_error:Error
        p.scene,_,root_error=output_root(&o,asset.KIND_SCENE,"level",".scene")
        testing.expect_value(t,root_error.code,Error_Code.None)
        floor_path:string
        p.floor,floor_path=output_part(&o,asset.KIND_TEXTURE,"Floor",0,".tex")
        ids,paths:=output_parts(&o,asset.KIND_MATERIAL,names,0,".mat",fmt.tprintf("%s/assets/level/materials",root))
        for id,at in ids {
            if at<len(p.materials) {p.materials[at]=id}
        }
        floor,again_path:=output_part(&o,asset.KIND_TEXTURE,"Floor",0,".tex")
        twice,_:=output_parts(&o,asset.KIND_MATERIAL,names,0,".mat",fmt.tprintf("%s/assets/level/materials",root))
        for id,at in ids {testing.expect(t,twice[at]==id,"a document asked for again is the same")}
        testing.expect(t,floor==p.floor && again_path==floor_path,"a part of the cache asked for again is the same")
        info:=output_info(&o,"Floor",0)
        testing.expect(t,base.text_get(info.source[:])=="level.map" && info.source_hash==base.hash64(transmute([]u8)bytes),"an output names the source by its place in the package")
        types:asset.Types;asset.types_init(&types,context.temp_allocator)
        pixels:=[16]u8{1,2,3,255,4,5,6,255,7,8,9,255,10,11,12,255}
        testing.expect_value(t,asset.texture_save(floor_path,&types,{id=p.floor,width=2,height=2,format=.RGBA8,mips={pixels[:]},source=&info}),asset.Error.None)
        testing.expect_value(t,output_written(&o,p.floor,"Floor").code,Error_Code.None)
        for id,at in ids {
            testing.expect_value(t,asset.material_save(paths[at],&types,{id=id,info=asset.MATERIAL_DEFAULTS,source=&info}),asset.Error.None)
            testing.expect_value(t,output_written(&o,id,names[at]).code,Error_Code.None)
        }
        report,end_error:=outputs_end(&o,failed,context.temp_allocator)
        testing.expectf(t,end_error.code==.None,"%s",end_error.message)
        p.warnings=len(report.warnings)
        testing.expect(t,failed || len(report.assets)==1+len(names) && report.manifest!={} && report.build!={},"the report lists what was recorded, and the package")
        for w in report.assets {
            if w.kind==asset.KIND_MATERIAL {testing.expectf(t,strings.contains(w.path,"/assets/level/materials/"),"%s goes to the folder asked for",w.path)}
            if w.id==p.floor {p.floor_blob=w.object}
        }
        p.report=report
        return p,true
    }
    first,ok:=pass(t,s,root,source,bytes,{"Stone","Wood"})
    if !ok {return}
    testing.expect(t,first.scene!={} && first.floor!={} && first.materials[0]!={} && first.materials[0]!=first.materials[1])
    manifest,build,read:=test_package(t,s,first.report)
    if !read {return}
    testing.expect(t,manifest.catalog_path=="Caves/Levels" && manifest.documents=="level")
    if testing.expect_value(t,len(build.programs),1) {
        program:=asset.generated_program_id(build.programs[0],context.temp_allocator)
        address,decoded:=asset.generated_program_address(program)
        testing.expect(t,decoded && address==build.programs[0] && len(program)<asset.MATERIAL_NAME_BYTES)
        text,read_error:=asset.record_get(s,address)
        testing.expect(t,read_error==.None && text==PROGRAM)
    }
    testing.expect(t,len(manifest.assets)==4 && len(build.outputs)==3,"the scene planned is listed; what was written is built")
    for o in build.outputs {
        listed:=false
        for a in manifest.assets {listed||=a.id==o.id && a.kind==o.kind}
        testing.expect(t,listed && asset.object_whole(s,o.object),"each output of the build is an asset of its package, in the store")
    }
    testing.expect(t,os.exists(fmt.tprintf("%s/level/materials/Stone.mat",assets)),"a document is written in the folder of the documents")

    // Again: the same assets. A run that fails records nothing.
    again,again_ok:=pass(t,s,root,source,bytes,{"Wood","Stone"})
    testing.expect(t,again_ok && again.scene==first.scene && again.floor==first.floor && again.floor_blob==first.floor_blob && again.materials=={first.materials[1],first.materials[0]} && again.warnings==0,"each output is found by its kind and name")
    id_text:[base.ASSET_ID_TEXT]u8
    named,_:=store.ref_get(s,asset.REF_PACKAGES,base.asset_id_format(manifest.id,id_text[:]))
    _,_=pass(t,s,root,source,bytes,{"Clay"},failed=true)
    after,_:=store.ref_get(s,asset.REF_PACKAGES,base.asset_id_format(manifest.id,id_text[:]))
    testing.expect(t,named==again.report.manifest && after==named,"a failed import leaves the package as it was")

    // A part renamed in the source is a new one, and the one that is gone leaves the package.
    renamed,renamed_ok:=pass(t,s,root,source,bytes,{"Wood","Granite"})
    testing.expect(t,renamed_ok && renamed.materials[0]==first.materials[1] && renamed.materials[1]!=first.materials[0],"Granite is not what Stone was")
    gone,gone_ok:=pass(t,s,root,source,bytes,{"Granite"})
    left,_,_:=test_package(t,s,gone.report)
    testing.expect(t,gone_ok && len(left.assets)==3,"Wood is no longer listed")
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
// reads are what it is made from, given before the cache is planned.
@(test)
the_models_of_an_import_share_their_parts_by_name :: proc(t:^testing.T) {
    root,assets,s:=test_assets(t,"outputs-models")
    if root=="" {return}
    source:=fmt.tprintf("%s/level.map",assets)
    bytes:="a level of two props"
    testing.expect(t,os.write_entire_file(source,bytes)==nil)
    package_file:=fmt.tprintf("%s/props.pkg",assets)
    testing.expect(t,os.write_entire_file(package_file,"the props")==nil)
    Pass :: struct {level:base.Asset_Id,crate,barrel,report:Import_Report,textures,materials,meshes:int,wood,stone:string}
    pass :: proc(t:^testing.T,s:^store.Store,root,source,bytes,package_file:string,root_first:bool) -> (p:Pass,ok:bool) {
        o:Outputs
        error:=outputs_begin(&o,source,"level",u64(len(bytes)),base.hash64(transmute([]u8)bytes),import_version(0),{store=s,root=root,documents=fmt.tprintf("%s/assets",root),textures=.Uncompressed},allocator=context.temp_allocator)
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
        report,end_error:=outputs_end(&o,false,context.temp_allocator)
        testing.expectf(t,end_error.code==.None,"%s",end_error.message)
        for written in report.assets {
            switch written.kind {
            case asset.KIND_TEXTURE: p.textures+=1
            case asset.KIND_MATERIAL: p.materials+=1
            case asset.KIND_MESH: p.meshes+=1
            }
            if written.name=="Materials/M_Wood" {p.wood=strings.clone(written.path,context.temp_allocator)}
            if written.name=="../Materials/./M_Stone" {p.stone=strings.clone(written.path,context.temp_allocator)}
        }
        p.report=report
        return p,true
    }
    first,ok:=pass(t,s,root,source,bytes,package_file,false)
    if !ok {return}
    crate,barrel:=first.crate,first.barrel
    testing.expect(t,crate.material_ids[0]==barrel.material_ids[0] && crate.image_ids[0]==barrel.image_ids[0],"the material and the texture of both models are one asset")
    testing.expect(t,crate.mesh_ids[0]!=barrel.mesh_ids[0] && crate.prefab!=barrel.prefab && crate.prefab!={} && barrel.material_ids[1]!={})
    testing.expectf(t,first.textures==1 && first.materials==2 && first.meshes==2,"what is shared is written once: %v",first)
    testing.expectf(t,strings.has_suffix(first.wood,"/assets/level/Materials/M_Wood.mat"),"%s",first.wood)
    testing.expectf(t,strings.has_suffix(first.stone,"/assets/level/Materials/M_Stone.mat"),"%s goes nowhere else",first.stone)

    // The package lists the parts by the names the models give them, the prefab of each among them.
    manifest,build,read:=test_package(t,s,first.report)
    if !read {return}
    named:=make(map[string]base.Asset_Id,context.temp_allocator)
    for a in manifest.assets {named[a.name]=a.id}
    testing.expectf(t,named["Meshes/SM_Crate"]==crate.mesh_ids[0] && named["Textures/T_Wood"]==crate.image_ids[0] && named["Crate"]==crate.prefab,"%v",named)
    built:=0
    for o in build.outputs {built+=int(o.id==crate.mesh_ids[0] || o.id==crate.image_ids[0])}
    testing.expect(t,built==2,"the build has the mesh and the texture")

    // Again, with the root asked for first among the scenes its package lists: the same assets.
    again,again_ok:=pass(t,s,root,source,bytes,package_file,true)
    testing.expect(t,again_ok && again.level==first.level && again.crate.mesh_ids[0]==crate.mesh_ids[0] && again.barrel.material_ids[1]==barrel.material_ids[1] && again.crate.image_ids[0]==crate.image_ids[0] && again.crate.prefab==crate.prefab,"each part keeps its asset")

    // An input that changed changes what the import is made from.
    testing.expect(t,len(manifest.inputs)==1 && manifest.inputs[0]=="props.pkg","the input is listed")
    settings,_:=settings_parse(manifest.settings)
    before:=identity_of(manifest.id,path_key(source),manifest.inputs[:],settings,0)
    testing.expect(t,before==manifest.identity,"the identity is that of the source, its input and its settings")
    testing.expect(t,os.write_entire_file(package_file,"other props")==nil)
    testing.expect(t,identity_of(manifest.id,path_key(source),manifest.inputs[:],settings,0)!=before,"the input counts in the identity")
}

// An image only its format decodes is keyed by its data: a texture the
// texture cache keeps for that data is written without making its texels.
@(test)
an_image_only_its_format_decodes_is_taken_from_the_cache_without_decoding :: proc(t:^testing.T) {
    root,assets,s:=test_assets(t,"outputs-made")
    if root=="" {return}
    // A store of its own holds no texture of the data.
    empty:=test_store(t,fmt.tprintf("%s/empty",root))
    if empty==nil {return}
    texels_of :: proc(data:[]u8,allocator:mem.Allocator) -> (made:textures.Source,ok:bool) {
        texels:=make([]u8,4*4*4,allocator)
        for &texel,at in texels {texel=u8(at*7)+data[0]}
        return {texels=texels,width=4,height=4,format=.RGBA8},true
    }
    refused :: proc(data:[]u8,allocator:mem.Allocator) -> (made:textures.Source,ok:bool) {return}
    written :: proc(t:^testing.T,s:^store.Store,root,assets,name:string,make:Image_Make) -> (texels:string,report:Import_Report) {
        source:=fmt.tprintf("%s/%s.map",assets,name)
        testing.expect(t,os.write_entire_file(source,name)==nil)
        o:Outputs
        error:=outputs_begin(&o,source,name,u64(len(name)),base.hash64(transmute([]u8)name),import_version(0),{store=s,root=root,textures=.Uncompressed},allocator=context.temp_allocator)
        if !testing.expectf(t,error.code==.None,"%s",error.message) {return}
        model:=model_of("Crate","SM_Crate","T_Wood","M_Wood")
        model.images[0]={name="T_Wood",data=transmute([]u8)string("packed"),make=make,srgb=true}
        _,error=output_model(&o,&model,context.temp_allocator)
        testing.expectf(t,error.code==.None,"%s",error.message)
        report,_=outputs_end(&o,false,context.temp_allocator)
        for w in report.assets {
            if w.kind!=asset.KIND_TEXTURE {continue}
            types:asset.Types;asset.types_init(&types,context.temp_allocator)
            a:asset.Asset
            if written_open(s,w,&a,context.temp_allocator)!=.None {return}
            view,view_error:=asset.texture_view(&a,&types)
            if view_error==.None {texels=strings.clone(string(asset.texture_mip(view,0)),context.temp_allocator)}
        }
        return
    }
    first,report:=written(t,s,root,assets,"first",texels_of)
    testing.expect(t,len(first)==4*4*4,"its format makes the texels")
    second,_:=written(t,s,root,assets,"second",refused)
    testing.expect(t,second==first,"the cache gives the texture of the same data")
    third,_:=written(t,empty,root,assets,"third",refused)
    testing.expect(t,third=="","without the cache the texels are made, and here they cannot be")

    // Imported again unchanged, its outputs are current: a model read ahead for it cooks nothing.
    current :: proc(s:^store.Store,root,assets:string) -> bool {
        o:Outputs
        source:=fmt.tprintf("%s/first.map",assets)
        if outputs_begin(&o,source,"first",5,base.hash64(transmute([]u8)string("first")),import_version(0),{store=s,root=root,textures=.Uncompressed}).code!=.None {return false}
        defer outputs_end(&o,true)
        return outputs_current(&o)
    }
    testing.expect(t,current(s,root,assets),"nothing changed")
    _,build,read:=test_package(t,s,report)
    if !read {return}
    // A build whose mesh is an object the store does not hold is no current one.
    for &o in build.outputs {
        if o.kind==asset.KIND_MESH {o.object=store.address_of_bytes(transmute([]u8)string("gone"))}
    }
    stale,_:=asset.build_put(s,&build)
    digits:[64]u8
    testing.expect_value(t,store.ref_set(s,asset.REF_IMPORTS,store.hex(report.key,&digits),stale),store.Error.None)
    testing.expect(t,!current(s,root,assets),"an object is gone")
}

// A source a model was read from, in a folder of its own that no project
// holds, its bytes those of name.
@(private="file")
model_source :: proc(t:^testing.T,folder,name:string,version:u32) -> (model:Imported_Model) {
    model=model_of("Crate","SM_Crate","T_Wood","M_Wood")
    model.source=path_key(fmt.tprintf("%s/%s.model",folder,name))
    testing.expect(t,os.write_entire_file(model.source,name)==nil)
    model.source_size,model.source_hash=u64(len(name)),base.hash64(transmute([]u8)name)
    model.format,model.folder,model.version="test",name,version
    return
}

// The blobs of a build by asset, sorted by id.
@(private="file")
build_blobs :: proc(t:^testing.T,s:^store.Store,report:Import_Report) -> []asset.Build_Output {
    _,b,_:=test_package(t,s,report)
    slice.sort_by(b.outputs[:],proc(a,b:asset.Build_Output) -> bool {return a.id[0]<b.id[0] || a.id[0]==b.id[0] && a.id[1]<b.id[1]})
    return b.outputs[:]
}

// A source outside any project imports into the store alone: no file is
// written beside it. Imported again it is the same package with the same
// assets, and the store holds the same blobs: a blob is never rewritten.
@(test)
importing_again_keeps_the_ids_and_the_blobs_of_every_asset :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"outputs-again")
    if folder=="" {return}
    s:=test_store(t,fmt.tprintf("%s/store",folder))
    if s==nil {return}
    outside:=fmt.tprintf("%s/downloads",folder)
    os.make_directory_all(outside)
    import_once :: proc(t:^testing.T,s:^store.Store,outside:string) -> (report:Import_Report,ok:bool) {
        model:=model_source(t,outside,"crate",import_version(0))
        error:Error
        report,error=import_write(&model,{store=s,textures=.Uncompressed},context.temp_allocator)
        return report,testing.expectf(t,error.code==.None,"%s",error.message)
    }
    first,ok:=import_once(t,s,outside)
    if !ok {return}
    entries,_:=os.read_all_directory_by_path(outside,context.temp_allocator)
    testing.expect_value(t,len(entries),1)
    again,again_ok:=import_once(t,s,outside)
    if !again_ok {return}
    testing.expect(t,again.package_id==first.package_id && again.manifest==first.manifest && again.build==first.build,"the same package, manifest and build")
    testing.expect(t,again.mesh_ids[0]==first.mesh_ids[0] && again.material_ids[0]==first.material_ids[0] && again.image_ids[0]==first.image_ids[0] && again.prefab==first.prefab,"the same ids")
    kept:=0
    for w in again.assets {kept+=int(w.kept)}
    testing.expect(t,kept==2,"the mesh and the texture are taken from the build, not built")
    p,_,_:=test_package(t,s,first)
    testing.expect(t,p.origin.path==path_key(fmt.tprintf("%s/crate.model",outside)) && p.origin.importer=="test","its origin is where the source was")
    for &a in p.assets {
        if a.kind==asset.KIND_MESH {testing.expect(t,a.owner==first.prefab && a.part && slice.contains(a.dependencies[:],first.material_ids[0]),"a mesh is a part of the prefab and depends on its material")}
    }
}

// The identity of a package is what its source is: the settings change it, a
// version of the engine does not, and changes the key of its build instead.
@(test)
a_changed_setting_changes_the_identity_and_a_changed_engine_does_not :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"outputs-identity")
    if folder=="" {return}
    s:=test_store(t,fmt.tprintf("%s/store",folder))
    if s==nil {return}
    written :: proc(t:^testing.T,s:^store.Store,folder:string,version:u32,options:Import_Options) -> (p:asset.Package,b:asset.Build) {
        model:=model_source(t,folder,"crate",version)
        options:=options
        options.store,options.textures,options.ignore_stored=s,.Uncompressed,true
        report,error:=import_write(&model,options,context.temp_allocator)
        if !testing.expectf(t,error.code==.None,"%s",error.message) {return}
        p,b,_=test_package(t,s,report)
        return
    }
    first,first_build:=written(t,s,folder,import_version(0),{})
    upgraded,upgraded_build:=written(t,s,folder,import_version(9),{})
    testing.expect(t,first.identity!={} && upgraded.identity==first.identity && upgraded_build.key!=first_build.key,"another version of the reader keeps the identity and changes the key")
    lods,_:=written(t,s,folder,import_version(0),{lods=.None})
    testing.expect(t,lods.identity!=first.identity && lods.id==first.id,"a setting changes the identity of the same package")
    testing.expect(t,strings.contains(lods.settings,"lods"),"the package keeps the settings that differ from the defaults")
}

// A build of Fast textures is named apart from the Final builds, where only a
// refresh that takes Fast looks, while the machine chooses it for the package.
@(test)
a_fast_build_is_named_apart_from_the_final_builds :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"outputs-fast")
    if folder=="" {return}
    s:=test_store(t,fmt.tprintf("%s/store",folder))
    if s==nil {return}
    model:=model_source(t,folder,"crate",import_version(0))
    report,error:=import_write(&model,{store=s,fast_textures=true},context.temp_allocator)
    if !testing.expectf(t,error.code==.None,"%s",error.message) {return}
    testing.expect(t,!report.final,"its texture is Fast")
    digits:[64]u8
    _,shared:=store.ref_get(s,asset.REF_IMPORTS,store.hex(report.key,&digits))
    fast,local:=store.ref_get(s,asset.REF_IMPORTS_FAST,store.hex(report.key,&digits))
    testing.expect(t,shared==.Missing && local==.None && fast==report.build,"published under the namespace of Fast builds alone")
    p,_,_:=test_package(t,s,report)
    chosen,_:=store.ref_get(s,asset.REF_BUILDS,store.hex(asset.build_select(report.manifest,&p),&digits))
    testing.expect(t,chosen==report.build,"the build this machine chose")
    list:=asset.Packages{packages=make([dynamic]asset.Project_Package,context.temp_allocator)}
    append(&list.packages,asset.Project_Package{id=p.id,manifest=report.manifest})
    resolved,resolve_error:=asset.packages_resolve(s,"",&list,context.temp_allocator)
    testing.expect(t,resolve_error==.None && len(resolved.problems)==0 && len(resolved.listed)==2,"a project lists the mesh and the texture of the package")
    for l in resolved.listed {testing.expectf(t,l.state==.Built && asset.object_whole(s,l.object) && l.header.id==l.id,"%s is built",l.path)}
}

// Two machines that import one source as the same package write the same
// blobs: what an import writes depends on no machine.
@(test)
two_stores_that_import_one_source_hold_the_same_blobs :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"outputs-stores")
    if folder=="" {return}
    here:=test_store(t,fmt.tprintf("%s/here",folder))
    there:=test_store(t,fmt.tprintf("%s/there",folder))
    if here==nil || there==nil {return}
    model:=model_source(t,folder,"crate",import_version(0))
    first,error:=import_write(&model,{store=here,textures=.Uncompressed},context.temp_allocator)
    if !testing.expectf(t,error.code==.None,"%s",error.message) {return}
    // The other machine has the manifest, as a peer gives it, and the source.
    p,_,_:=test_package(t,here,first)
    manifest,put_error:=asset.package_put(there,&p)
    testing.expect(t,put_error==.None && manifest==first.manifest,"the manifest is the same blob")
    model=model_source(t,folder,"crate",import_version(0))
    second:Import_Report
    second,error=import_write(&model,{store=there,manifest=manifest,textures=.Uncompressed},context.temp_allocator)
    if !testing.expectf(t,error.code==.None,"%s",error.message) {return}
    testing.expect(t,second.manifest==first.manifest && second.build==first.build,"the same manifest and build")
    a,b:=build_blobs(t,here,first),build_blobs(t,there,second)
    testing.expect(t,len(a)==len(b) && len(a)>0)
    for o,at in a {
        if at<len(b) {testing.expectf(t,o==b[at],"%v is the same blob on both",o.id)}
    }
}

// A document of a plugin's kind that a refresh writes as a new file takes the
// extension the plugin declares for its kind, else that of a file of its kind
// the registry has.
@(test)
a_document_of_a_plugin_kind_takes_its_extension :: proc(t:^testing.T) {
    _,folder,s:=test_assets(t,"plugin-document")
    if folder=="" {return}
    KIND :: asset.Fourcc(u32('K')|u32('I')<<8|u32('T')<<16|u32('T')<<24)
    doc:asset.Document
    asset.document_init(&doc,KIND,{70,1},context.temp_allocator)
    bytes,_:=asset.document_bytes(&doc,context.temp_allocator)
    asset.document_destroy(&doc)
    object,put_error:=asset.object_put(s,bytes)
    if !testing.expect_value(t,put_error,asset.Error.None) {return}
    p:=asset.Package{id={71,1},name="hall"}
    p.assets=make([dynamic]asset.Package_Asset,context.temp_allocator)
    append(&p.assets,asset.Package_Asset{kind=KIND,name="hall",id={70,1}})
    b:=asset.Build{package_id=p.id}
    b.outputs=make([dynamic]asset.Build_Output,context.temp_allocator)
    append(&b.outputs,asset.Build_Output{id={70,1},kind=KIND,object=object})
    kinds:=[]Kind_Extension{{KIND,".kit"}}
    written,error:=documents_follow(s,&p,&b,fmt.tprintf("%s/declared",folder),nil,nil,.Keep,kinds,context.temp_allocator)
    testing.expectf(t,error.code==.None && len(written)==1 && strings.has_suffix(written[0].path,"/declared/hall.kit") && os.exists(written[0].path),"%s %v",error.message,written[:])
    // Without what the plugin declares, a file of its kind the registry has gives it.
    r:asset.Registry
    asset.registry_init(&r,folder,"",context.temp_allocator)
    defer asset.registry_destroy(&r)
    testing.expect_value(t,asset.registry_scan(&r),asset.Error.None)
    written,error=documents_follow(s,&p,&b,fmt.tprintf("%s/found",folder),&r,nil,.Discard,nil,context.temp_allocator)
    testing.expectf(t,error.code==.None && len(written)==1 && strings.has_suffix(written[0].path,".kit"),"%s %v",error.message,written[:])
}
