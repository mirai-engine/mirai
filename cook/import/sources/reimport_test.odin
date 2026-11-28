package sources

import "core:c"
import "core:encoding/base64"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:testing"
import "core:time"
import stbi "vendor:stb/image"
import "mirai:asset"
import "mirai:core"
import "mirai:cook/cache"
import importer "mirai:cook/import"
import "mirai:cook/prefab"
import "mirai:cook/import/gltf"
import "mirai:cook/textures"
import "mirai:project"
import "mirai:std/base"
import "mirai:store"

// A box with two materials, the first with the image wood.png next to it.
box_source :: proc(folder,file:string,first,second:string,roughness:="0.5") -> string {
    vertices:=[15]f32{0,0,0,1,0,0,0,1,0,0,0,1,0,0,1}
    encoded,_:=base64.encode(slice.to_bytes(vertices[:]),allocator=context.temp_allocator)
    _=os.write_entire_file(fmt.tprintf("%s/wood.png",folder),png_bytes(4,4,{150,90,40}))
    text:=strings.concatenate({`{"asset":{"version":"2.0"},"scene":0,"scenes":[{"nodes":[0]}],"nodes":[{"name":"Box","mesh":0}],
        "meshes":[{"name":"Box","primitives":[{"attributes":{"POSITION":0,"TEXCOORD_0":1},"material":0},{"attributes":{"POSITION":0,"TEXCOORD_0":1},"material":1}]}],
        "materials":[{"name":"`,first,`","pbrMetallicRoughness":{"baseColorTexture":{"index":0},"roughnessFactor":`,roughness,`}},{"name":"`,second,`"}],
        "textures":[{"source":0}],"images":[{"name":"wood","uri":"wood.png"}],
        "buffers":[{"byteLength":60,"uri":"data:application/octet-stream;base64,`,encoded,`"}],"bufferViews":[{"buffer":0,"byteLength":36},{"buffer":0,"byteOffset":36,"byteLength":24}],
        "accessors":[{"bufferView":0,"componentType":5126,"count":3,"type":"VEC3","min":[0,0,0],"max":[1,1,0]},{"bufferView":1,"componentType":5126,"count":3,"type":"VEC2"}]}`},context.temp_allocator)
    return write_text(folder,file,text)
}

@(private="file")
box_import :: proc(t:^testing.T,source,root:string) -> (report:importer.Import_Report,ok:bool) {
    error:importer.Error
    report,error=import_test(t,source,{world=prefab.import_world(t),root=root,textures=.Uncompressed})
    ok=testing.expectf(t,error.code==.None,"%s: %s",source,error.message)
    return
}

@(private="file")
header_of :: proc(path:string) -> asset.Header {
    data,_:=os.read_entire_file(path,context.temp_allocator)
    header,_:=asset.header_read(data)
    return header
}

// What the slots of the mesh of a report name.
@(private="file")
slot_materials :: proc(t:^testing.T,report:^importer.Import_Report,types:^asset.Types) -> (materials:[2]base.Asset_Id) {
    mesh,found:=written_of(report,asset.KIND_MESH,"Box")
    if !testing.expect(t,found) {return}
    a,loaded:=read_asset(t,mesh,types)
    if !loaded {return}
    defer asset.asset_close(&a)
    view,error:=asset.mesh_view(&a,types)
    if !testing.expect_value(t,error,asset.Error.None) || !testing.expect_value(t,len(view.slots),2) {return}
    return {view.slots[0].material,view.slots[1].material}
}

// What an import builds that nobody edits is an object of the store; what the
// editor edits is also a file of the project, in the folder of the import,
// found by its id wherever it was moved; the package lists them all.
@(test)
the_parts_of_an_import_name_its_prefab_and_keep_their_ids_where_they_were_moved :: proc(t:^testing.T) {
    root,assets:=test_project(t,"reimport-moved")
    if root=="" {return}
    os.make_directory_all(fmt.tprintf("%s/models",assets))
    source:=box_source(fmt.tprintf("%s/models",assets),"box.gltf","Wood","Paint")
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    first,ok:=box_import(t,source,root);if !ok {return};defer importer.report_destroy(&first)
    prefab,has_prefab:=written_of(&first,asset.KIND_SCENE,"box")
    wood,has_wood:=written_of(&first,asset.KIND_MATERIAL,"Wood")
    if !testing.expect(t,has_prefab && has_wood && prefab.id!={} && prefab.id==first.prefab) {return}
    // The mesh is a part; Wood, whose island reaches across its texture, and Paint, without one, are not.
    for written in first.assets {
        header:=header_of(written.path)
        testing.expect_value(t,header.id,written.id)
        testing.expectf(t,header.owner==(written.kind==asset.KIND_MESH?prefab.id:base.Asset_Id{}),"%s: owner %v",written.path,header.owner)
    }
    testing.expect(t,strings.has_prefix(wood.detail,"of its own: an island"),wood.detail)
    for written in first.assets {
        cached:=asset.import_cached(written.kind)
        testing.expectf(t,strings.contains(written.path,cached?"/store-objects/":"/assets/models/box/"),"%s: of the %s",written.path,cached?"store":"assets")
    }
    s:=test_store(t,fmt.tprintf("%s/store",root))
    p,read_error:=asset.package_get(s,first.manifest,context.temp_allocator)
    testing.expect(t,read_error==.None && len(p.assets)==len(first.assets),"the package lists what the source gives")
    for a in p.assets {
        written,listed:=written_of(&first,a.kind,a.kind==asset.KIND_SCENE?"box":a.name)
        testing.expectf(t,listed && written.id==a.id && a.part==(a.kind==asset.KIND_MESH),"%s is listed with its id: %v",a.name,a)
    }
    a,loaded:=read_asset(t,prefab,&types)
    if loaded {
        info,error:=asset.import_info(&a,&types)
        testing.expect(t,error==.None && info!=nil && string_of(info.source[:])=="box.gltf" && .Cooked in a.blob.header.flags,"the prefab records its import")
        asset.asset_close(&a)
    }

    // The material moved to another folder is written there with its id.
    os.make_directory_all(fmt.tprintf("%s/materials",assets))
    moved:=fmt.tprintf("%s/materials/Wood.mat",assets)
    testing.expect(t,os.rename(wood.path,moved)==nil)
    again,again_ok:=box_import(t,source,root);if !again_ok {return};defer importer.report_destroy(&again)
    testing.expect_value(t,len(again.assets),len(first.assets))
    for written in first.assets {
        same,found:=written_of(&again,written.kind,written.name)
        testing.expectf(t,found && same.id==written.id,"%s keeps its id",written.name)
    }
    wood_again,_:=written_of(&again,asset.KIND_MATERIAL,"Wood")
    testing.expect(t,strings.has_suffix(wood_again.path,"assets/materials/Wood.mat") && header_of(moved).id==wood.id)
    testing.expect(t,!os.exists(wood.path),"no second file with the id of the material")
    testing.expect_value(t,slot_materials(t,&again,&types)[0],wood.id)
    testing.expect_value(t,len(again.warnings),0)
}

// The ids of an import are those of its package: a source moved, renamed or
// changed keeps them with the manifest its project pins, and a copy of the
// source is another package.
@(test)
a_source_keeps_the_ids_of_its_package_and_a_copy_is_another_package :: proc(t:^testing.T) {
    root,assets:=test_project(t,"reimport-renamed")
    if root=="" {return}
    os.make_directory_all(fmt.tprintf("%s/props",assets))
    source:=box_source(assets,"box.gltf","Wood","Paint")
    first,ok:=box_import(t,source,root);if !ok {return};defer importer.report_destroy(&first)

    // Moved, renamed and changed, imported with the manifest the project pins.
    crate:=box_source(fmt.tprintf("%s/props",assets),"crate.gltf","Wood","Paint","0.8")
    testing.expect(t,os.remove(source)==nil)
    moved,moved_error:=import_test(t,crate,{world=prefab.import_world(t),root=root,textures=.Uncompressed,manifest=first.manifest})
    if !testing.expectf(t,moved_error.code==.None,"%s",moved_error.message) {return};defer importer.report_destroy(&moved)
    testing.expect(t,moved.prefab==first.prefab && moved.package_id==first.package_id)
    for written in first.assets {
        same,found:=written_of(&moved,written.kind,written.kind==asset.KIND_SCENE?"crate":written.name)
        // A document is followed in its file; a blob is another one, made from what changed.
        testing.expectf(t,found && same.id==written.id && (same.path==written.path || asset.import_cached(written.kind)),"%s keeps its id and its file",written.name)
    }
    testing.expect_value(t,len(moved.warnings),0)
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    scene,_:=written_of(&moved,asset.KIND_SCENE,"crate")
    if a,loaded:=read_asset(t,scene,&types);loaded {
        info,_:=asset.import_info(&a,&types)
        testing.expect(t,info!=nil && string_of(info.source[:])=="crate.gltf","the import names the source by its name in its package")
        asset.asset_close(&a)
    }

    // The same bytes elsewhere: a package of its own, which takes nothing of the other.
    copy:=box_source(assets,"copy.gltf","Wood","Paint","0.8")
    second,second_error:=import_test(t,copy,{world=prefab.import_world(t),root=root,textures=.Uncompressed})
    if !testing.expectf(t,second_error.code==.None,"%s",second_error.message) {return};defer importer.report_destroy(&second)
    testing.expect(t,second.prefab!={} && second.prefab!=first.prefab && second.package_id!=first.package_id,"the copy writes a prefab of its own")
    for written in second.assets {
        for other in first.assets {testing.expectf(t,other.id!=written.id,"%s has an id of its own",written.path)}
    }
}

// A document an import writes over in a project that changed since it wrote
// it (the prefab of a model with an entity added) stops an import into the
// project that was not told what to do with it, which names it and writes
// nothing; a refresh leaves it as it is, builds the rest and warns;
// discard_changes writes over it. The pin records what each such file held
// as written; a change of its owner alone is none, and a material, which
// follows its source, records nothing.
@(test)
an_import_does_not_write_over_a_document_changed_since_it_wrote_it :: proc(t:^testing.T) {
    root,assets:=test_project(t,"reimport-changed")
    if root=="" {return}
    source:=box_source(assets,"box.gltf","Wood","Paint")
    s:=test_store(t,fmt.tprintf("%s/store",root))
    if s==nil {return}
    context.user_ptr=prefab.import_world(t)
    options:=Library_Options{store=s,root=root,plugins=test_library,fast_textures=true}
    settings:=importer.Import_Settings{textures=.Uncompressed}
    into :: proc(t:^testing.T,root,source:string,options:Library_Options,settings:^importer.Import_Settings) -> (report:importer.Import_Report,error:importer.Error) {
        added:Library_Report
        report,added,error=project_ingest(root,source,"",options,settings,context.temp_allocator)
        testing.expectf(t,len(added.failures)==0,"%v",added.failures)
        return
    }
    first,first_error:=into(t,root,source,options,&settings)
    if !testing.expectf(t,first_error.code==.None,"%s",first_error.message) {return}
    scene,_:=written_of(&first,asset.KIND_SCENE,"box")
    wood,_:=written_of(&first,asset.KIND_MATERIAL,"Wood")
    list,_,_:=asset.packages_load(root,context.temp_allocator)
    if !testing.expect_value(t,len(list.packages),1) {return}
    recorded:=list.packages[0].written[:]
    testing.expectf(t,importer.written_of(recorded,scene.id)==importer.written_hash(scene.path) && importer.written_of(recorded,wood.id)==0,"the pin records what the prefab holds, and nothing of a material: %v",recorded)
    data,_:=os.read_entire_file(scene.path,context.temp_allocator)
    testing.expect_value(t,asset.header_owner_set(data,wood.id),asset.Error.None)
    _=os.write_entire_file(scene.path,data)
    _,again_error:=into(t,root,source,options,nil)
    if !testing.expectf(t,again_error.code==.None,"a change of owner alone is none: %s",again_error.message) {return}

    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    edited:asset.Scene
    if !testing.expect_value(t,asset.scene_load(&edited,&types,scene.path,context.temp_allocator),asset.Error.None) {return}
    _,_=asset.scene_entity_add(&edited,asset.scene_new_id(&edited),{},"Added")
    testing.expect_value(t,asset.scene_save(&edited,scene.path),asset.Error.None)
    asset.scene_destroy(&edited)
    changed,_:=os.read_entire_file(scene.path,context.temp_allocator)
    pins,_:=os.read_entire_file(fmt.tprintf("%s/%s",root,asset.PACKAGES_FILE),context.temp_allocator)
    held :: proc(t:^testing.T,path:string,bytes:[]u8,why:string) {
        now,_:=os.read_entire_file(path,context.temp_allocator)
        testing.expectf(t,string(now)==string(bytes),"%s: %s",path,why)
    }

    _,error:=into(t,root,source,options,&settings)
    testing.expectf(t,error.code==.Changed && contains(error.message,"assets/box/box.scene") && contains(error.message,"discard_changes"),"the import names what changed and how to go on: %v %s",error.code,error.message)
    held(t,scene.path,changed,"the import wrote nothing")
    held(t,fmt.tprintf("%s/%s",root,asset.PACKAGES_FILE),pins,"nor its pin")

    // The source changes: the refresh ingests it again and leaves the prefab.
    box_source(assets,"box.gltf","Wood","Paint","0.8")
    refreshed:=project_refresh(root,options,context.temp_allocator)
    testing.expectf(t,refreshed.ingested==1 && len(refreshed.failures)==0 && len(refreshed.warnings)==1 && contains(refreshed.warnings[0],"assets/box/box.scene"),"the refresh builds the rest and says what it left: %v",refreshed)
    held(t,scene.path,changed,"the refresh leaves it as it is")
    _,still:=into(t,root,source,options,nil)
    testing.expectf(t,still.code==.Changed,"what the pin records is still what was written: %v",still.code)

    options.changed=.Discard
    _,discard_error:=into(t,root,source,options,nil)
    if !testing.expectf(t,discard_error.code==.None,"%s",discard_error.message) {return}
    testing.expect(t,!scene_named(t,&types,scene.path,"Added"),"discard_changes writes over it")
    options.changed=.Refuse
    _,last_error:=into(t,root,source,options,nil)
    testing.expectf(t,last_error.code==.None,"then importing again asks nothing: %s",last_error.message)
}

// Whether the scene at path has an entity named name.
@(private="file")
scene_named :: proc(t:^testing.T,types:^asset.Types,path,name:string) -> bool {
    loaded:asset.Scene
    if !testing.expect_value(t,asset.scene_load(&loaded,types,path,context.temp_allocator),asset.Error.None) {return false}
    defer asset.scene_destroy(&loaded)
    for &held in asset.scene_names(&loaded) {
        if base.text_get(held[:])==name {return true}
    }
    return false
}

// A part is found by its kind and name alone: one renamed in the source is
// a new asset, and the one that left stays as it is, with a warning.
@(test)
a_material_renamed_in_the_source_is_a_new_one_and_a_part_taken_out_is_left_alone :: proc(t:^testing.T) {
    root,assets:=test_project(t,"reimport-parts")
    if root=="" {return}
    source:=box_source(assets,"box.gltf","Wood","Paint")
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    first,ok:=box_import(t,source,root);if !ok {return};defer importer.report_destroy(&first)
    wood,_:=written_of(&first,asset.KIND_MATERIAL,"Wood")
    paint,_:=written_of(&first,asset.KIND_MATERIAL,"Paint")

    // Renamed in the source, the material is another asset: what named Wood does not get Oak.
    box_source(assets,"box.gltf","Oak","Paint")
    renamed,renamed_ok:=box_import(t,source,root);if !renamed_ok {return};defer importer.report_destroy(&renamed)
    oak,has_oak:=written_of(&renamed,asset.KIND_MATERIAL,"Oak")
    testing.expect(t,has_oak && oak.id!=wood.id && oak.path!=wood.path && header_of(wood.path).id==wood.id)
    testing.expect_value(t,slot_materials(t,&renamed,&types),[2]base.Asset_Id{oak.id,paint.id})
    left:=false
    for warning in renamed.warnings {left||=strings.contains(warning,"Wood.mat is no longer in the source")}
    testing.expectf(t,left,"the import says Wood left: %v",renamed.warnings)

    // Whether a mesh is a part is decided once and kept in the package: taken out there, it stays out.
    mesh,_:=written_of(&renamed,asset.KIND_MESH,"Box")
    testing.expect(t,header_of(mesh.path).owner==first.prefab)
    s:=test_store(t,fmt.tprintf("%s/store",root))
    p,_:=asset.package_get(s,renamed.manifest,context.temp_allocator)
    taken_out:=false
    for &a in p.assets {
        if a.kind==asset.KIND_MESH && a.part {a.part,taken_out=false,true}
    }
    manifest,put_error:=asset.package_put(s,&p)
    testing.expect(t,taken_out && put_error==.None)
    after,after_error:=import_test(t,source,{world=prefab.import_world(t),root=root,textures=.Uncompressed,manifest=manifest})
    if !testing.expectf(t,after_error.code==.None,"%s",after_error.message) {return};defer importer.report_destroy(&after)
    box,has_box:=written_of(&after,asset.KIND_MESH,"Box")
    testing.expect(t,has_box && box.id==mesh.id)
    header:=header_of(box.path)
    testing.expect(t,header.owner=={} && .Cooked in header.flags,"the part taken out keeps its id and its import, and stays out of its owner")

    // Forced, every material and texture is a part.
    forced,forced_ok:=import_test(t,source,{world=prefab.import_world(t),root=root,textures=.Uncompressed,parts=.All,ignore_stored=true})
    if !testing.expectf(t,forced_ok.code==.None,"%s",forced_ok.message) {return};defer importer.report_destroy(&forced)
    for written in forced.assets {
        if written.kind==asset.KIND_MATERIAL || written.kind==asset.KIND_TEXTURE {testing.expectf(t,header_of(written.path).owner==first.prefab,"%s is forced into the prefab",written.name)}
    }
}

// A PNG whose pixels a procedure gives.
@(private="file")
png_pixels :: proc(width,height:int,pixel:proc(x,y,width,height:int) -> [3]u8) -> []u8 {
    pixels:=make([]u8,width*height*4,context.temp_allocator)
    for y in 0..<height {
        for x in 0..<width {
            at:=(y*width+x)*4
            rgb:=pixel(x,y,width,height)
            pixels[at],pixels[at+1],pixels[at+2],pixels[at+3]=rgb[0],rgb[1],rgb[2],255
        }
    }
    sink:=Png_Sink{allocator=context.temp_allocator}
    stbi.write_png_to_func(png_sink,&sink,c.int(width),c.int(height),4,raw_data(pixels),c.int(width*4))
    return sink.bytes[:]
}

// What does not repeat: a gradient, with a tint that tells images apart.
@(private="file") gradient_red :: proc(x,y,w,h:int) -> [3]u8 {return {u8(x*255/(w-1)),u8(y*255/(h-1)),40}}
@(private="file") gradient_blue :: proc(x,y,w,h:int) -> [3]u8 {return {u8(x*255/(w-1)),u8(y*255/(h-1)),200}}
@(private="file") gradient_green :: proc(x,y,w,h:int) -> [3]u8 {return {u8(x*255/(w-1)),120,u8(y*255/(h-1))}}
// What repeats: whole periods across both sides.
@(private="file") waves :: proc(x,y,w,h:int) -> [3]u8 {
    v:=128+60*math.cos(2*math.PI*3*f32(x)/f32(w))+60*math.cos(2*math.PI*2*f32(y)/f32(h))
    return {u8(v),u8(255-v),128}
}

// A model of two meshes. Body has one triangle per material, Other one with
// Shared, which Body also uses. Each material takes its image and the UVs of
// its triangle: a corner of the texture, or across it for Spanning.
@(private="file")
atlas_source :: proc(folder,file:string,images:[]string) -> string {
    corner:=[6]f32{0.1,0.1,0.4,0.1,0.1,0.4}
    across:=[6]f32{0,0,1,0,0,1}
    positions:=[9]f32{0,0,0,1,0,0,0,1,0}
    data:=make([dynamic]u8,context.temp_allocator)
    append(&data,..slice.to_bytes(positions[:]))
    append(&data,..slice.to_bytes(corner[:]))
    append(&data,..slice.to_bytes(across[:]))
    encoded,_:=base64.encode(data[:],allocator=context.temp_allocator)
    primitive :: proc(uv,material:int) -> string {return fmt.tprintf(`{{"attributes":{{"POSITION":0,"TEXCOORD_0":%d}},"material":%d}}`,uv,material)}
    image_list:=make([dynamic]string,context.temp_allocator)
    for image in images {append(&image_list,fmt.tprintf(`{{"name":"%s","uri":"%s.png"}}`,image,image))}
    text:=strings.concatenate({`{"asset":{"version":"2.0"},"scene":0,"scenes":[{"nodes":[0,1]}],"nodes":[{"name":"Body","mesh":0},{"name":"Other","mesh":1}],
        "meshes":[{"name":"Body","primitives":[`,primitive(1,0),",",primitive(1,1),",",primitive(2,2),",",primitive(1,3),",",primitive(1,4),`]},{"name":"Other","primitives":[`,primitive(1,4),`]}],
        "materials":[{"name":"Atlas","pbrMetallicRoughness":{"baseColorTexture":{"index":0}}},{"name":"Tiled","pbrMetallicRoughness":{"baseColorTexture":{"index":1}}},
            {"name":"Spanning","pbrMetallicRoughness":{"baseColorTexture":{"index":2}}},{"name":"Flat"},{"name":"Shared","pbrMetallicRoughness":{"baseColorTexture":{"index":3}}}],
        "textures":[{"source":0},{"source":1},{"source":2},{"source":3}],"images":[`,strings.join(image_list[:],",",context.temp_allocator),`],
        "buffers":[{"byteLength":84,"uri":"data:application/octet-stream;base64,`,encoded,`"}],
        "bufferViews":[{"buffer":0,"byteLength":36},{"buffer":0,"byteOffset":36,"byteLength":24},{"buffer":0,"byteOffset":60,"byteLength":24}],
        "accessors":[{"bufferView":0,"componentType":5126,"count":3,"type":"VEC3","min":[0,0,0],"max":[1,1,0]},{"bufferView":1,"componentType":5126,"count":3,"type":"VEC2"},{"bufferView":2,"componentType":5126,"count":3,"type":"VEC2"}]}`},context.temp_allocator)
    return write_text(folder,file,text)
}

@(private="file")
atlas_images :: proc(folder:string) {
    os.make_directory_all(folder)
    _=os.write_entire_file(fmt.tprintf("%s/atlas.png",folder),png_pixels(64,64,gradient_red))
    _=os.write_entire_file(fmt.tprintf("%s/waves.png",folder),png_pixels(64,64,waves))
    _=os.write_entire_file(fmt.tprintf("%s/across.png",folder),png_pixels(64,64,gradient_blue))
    _=os.write_entire_file(fmt.tprintf("%s/shared.png",folder),png_pixels(64,64,gradient_green))
}

@(test)
a_material_is_a_part_only_when_its_texture_is_an_atlas_of_one_model :: proc(t:^testing.T) {
    root,assets:=test_project(t,"parts-rule")
    if root=="" {return}
    atlas_images(assets)
    source:=atlas_source(assets,"props.gltf",{"atlas","waves","across","shared"})
    report,error:=import_test(t,source,{world=prefab.import_world(t),root=root,textures=.Uncompressed})
    if !testing.expectf(t,error.code==.None,"%s",error.message) {return};defer importer.report_destroy(&report)
    reason :: proc(material:string) -> string {
        switch material {
        case "Atlas":    return "part of props: UVs inside 0..1"
        case "Tiled":    return "of its own: its image tiles"
        case "Spanning": return "of its own: an island"
        case "Flat":     return "of its own: it has no textures"
        case "Shared":   return "of its own: 2 meshes"
        }
        return "?"
    }
    for written in report.assets {
        if written.kind==asset.KIND_SCENE {continue}
        part:=written.kind==asset.KIND_MESH || written.name=="Atlas" || written.name=="atlas"
        owner:=header_of(written.path).owner
        testing.expectf(t,owner==(part?report.prefab:base.Asset_Id{}),"%s: owner %v",written.path,owner)
        if written.kind==asset.KIND_MATERIAL {testing.expectf(t,strings.has_prefix(written.detail,reason(written.name)),"%s: %s",written.name,written.detail)}
    }
}

// Two models that embed the same image each get a texture and a material of
// their own, encoded once in the content cache: neither import changes a
// file or the package of the other, and each keeps its atlas as a part.
@(test)
two_models_with_the_same_image_get_a_texture_each_and_neither_touches_the_other :: proc(t:^testing.T) {
    root,assets:=test_project(t,"parts-two-models")
    if root=="" {return}
    atlas_images(fmt.tprintf("%s/first",assets))
    atlas_images(fmt.tprintf("%s/second",assets))
    cache:=test_store(t,fmt.tprintf("%s/store",root))
    if cache==nil {return}
    first_source:=atlas_source(fmt.tprintf("%s/first",assets),"crate.gltf",{"atlas","waves","across","shared"})
    first,error:=import_test(t,first_source,{world=prefab.import_world(t),root=root,store=cache})
    first_package,_:=asset.package_get(cache,first.manifest,context.temp_allocator)
    if !testing.expectf(t,error.code==.None,"%s",error.message) {return};defer importer.report_destroy(&first)
    atlas,_:=written_of(&first,asset.KIND_MATERIAL,"Atlas")
    texture,_:=written_of(&first,asset.KIND_TEXTURE,"atlas")
    testing.expect(t,header_of(atlas.path).owner==first.prefab && header_of(texture.path).owner==first.prefab)
    Kept :: struct {path:string,bytes:[]u8}
    kept:=make([dynamic]Kept,context.temp_allocator)
    for written in first.assets {
        bytes,_:=os.read_entire_file(written.path,context.temp_allocator)
        append(&kept,Kept{written.path,bytes})
    }
    cached:=cached_refs(cache,textures.CACHE)

    second_source:=atlas_source(fmt.tprintf("%s/second",assets),"barrel.gltf",{"atlas","waves","across","shared"})
    second,second_error:=import_test(t,second_source,{world=prefab.import_world(t),root=root,store=cache})
    if !testing.expectf(t,second_error.code==.None,"%s",second_error.message) {return};defer importer.report_destroy(&second)
    second_atlas,wrote_material:=written_of(&second,asset.KIND_MATERIAL,"Atlas")
    second_texture,wrote_texture:=written_of(&second,asset.KIND_TEXTURE,"atlas")
    testing.expect(t,wrote_material && wrote_texture && second_atlas.id!=atlas.id && second_texture.id!=texture.id,"each model names a texture and a material of its own")
    testing.expect(t,header_of(second_atlas.path).owner==second.prefab && header_of(second_texture.path).owner==second.prefab,"and each keeps them as its parts")
    for file in kept {
        bytes,_:=os.read_entire_file(file.path,context.temp_allocator)
        testing.expectf(t,slice.equal(bytes,file.bytes),"%s is as the first import left it",file.path)
    }
    again_package,_:=asset.package_get(cache,first.manifest,context.temp_allocator)
    testing.expect(t,len(again_package.assets)==len(first_package.assets),"the package of the first is as it was")
    again:=cached_refs(cache,textures.CACHE)
    testing.expectf(t,len(again)==len(cached),"the images are encoded once: %d entries of the cache, then %d",len(cached),len(again))
}

// A format of models a plugin adds, which no format of the engine reads: glTF after a magic of its own.
@(private="file") PROBE_MAGIC :: "PROBE:"
@(private="file")
probe_sniff :: proc(head:[]u8) -> importer.Sniff {return .Content if strings.has_prefix(string(head),PROBE_MAGIC) else .No}
@(private="file")
probe_read :: proc(r:^importer.Reader,bytes:[]u8) -> bool {return gltf.FORMAT.read(r,bytes[len(PROBE_MAGIC):])}
@(private="file")
probe_format :: proc() -> importer.Format {
    probe:=gltf.FORMAT
    probe.name,probe.extensions,probe.sniff,probe.read="Probe",{0=".probe"},probe_sniff,probe_read
    return probe
}

// A format a plugin adds reads a source as the formats of the engine do: a
// refresh that must ingest it again reads it with the plugins of the project,
// and says so without them.
@(test)
a_refresh_reads_a_source_again_with_the_formats_of_the_plugins :: proc(t:^testing.T) {
    root:=base.test_folder(t,"refresh-plugin")
    if root=="" {return}
    game:=fmt.tprintf("%s/game",root)
    os.make_directory_all(fmt.tprintf("%s/assets",game))
    crate:=box_source(fmt.tprintf("%s/assets",game),"crate.probe","Wood","Paint")
    text,_:=os.read_entire_file(crate,context.temp_allocator)
    _=os.write_entire_file(crate,transmute([]u8)strings.concatenate({PROBE_MAGIC,string(text)},context.temp_allocator))
    s:=test_store(t,fmt.tprintf("%s/store",root))
    if s==nil {return}
    context.user_ptr=prefab.import_world(t)
    probing :: proc(root:string,s:^store.Store,allocator:mem.Allocator) -> Library_Imports {
        listed:=make([]importer.Format,1,allocator)
        listed[0]=probe_format()
        return {formats=listed,world=(^core.World_Info)(context.user_ptr)}
    }
    options:=Library_Options{store=s,root=game,plugins=probing}
    first,error:=ingest(crate,options,allocator=context.temp_allocator)
    if !testing.expectf(t,error.code==.None,"%s",error.message) {return}
    added:=project_add(game,first.manifest,"",nil,options,context.temp_allocator)
    testing.expectf(t,len(added.failures)==0 && len(added.missing)==0,"%v",added)
    mesh,has_mesh:=written_of(&first,asset.KIND_MESH,"Box")
    testing.expect(t,has_mesh && mesh.path=="" && asset.object_whole(s,mesh.object),"what a plugin format gives that nobody edits is an object of the store")

    // An engine of other versions: without the plugins nothing reads it, with them it is ingested again.
    forget :: proc(s:^store.Store) {
        for namespace in ([2]string{asset.REF_IMPORTS,asset.REF_BUILDS}) {
            refs,_:=store.ref_list(s,namespace,context.temp_allocator)
            for ref in refs {store.ref_remove(s,namespace,ref.name)}
        }
    }
    forget(s)
    lacking:=options
    lacking.plugins=nil
    without:=project_refresh(game,lacking,context.temp_allocator)
    testing.expectf(t,len(without.failures)==1 && strings.contains(without.failures[0],"not a source Mirai imports"),"%v",without)
    with:=project_refresh(game,options,context.temp_allocator)
    testing.expectf(t,with.ingested==1 && len(with.failures)==0 && len(with.missing)==0,"%v",with)
    testing.expect(t,asset.object_whole(s,mesh.object),"the mesh is the object it was")
}

// A source a plugin imports whole: "LEVEL <file>", a level of the glTF at
// that file beside it, which it reads and writes as a model of its import,
// and with kit a document of the kind KIT of that version. code: the
// identity of the code of its plugin; version: that of its format.
@(private) Level_Importer :: struct {runs:int,code:u64,kit:u16,version:u16}
@(private) LEVEL_IMPORTER :: "Levels"
@(private="file") KIT :: asset.Fourcc(u32('K')|u32('I')<<8|u32('T')<<16|u32('S')<<24)
@(private)
level_claims :: proc(path:string,head:[]u8) -> bool {return strings.has_prefix(string(head),"LEVEL ")}
@(private)
level_run :: proc(state:rawptr,source:string,options:importer.Import_Options,allocator:mem.Allocator) -> (report:importer.Import_Report,scene:string,error:importer.Error) {
    (^Level_Importer)(state).runs+=1
    bytes,_:=os.read_entire_file(source,context.temp_allocator)
    model_path:=fmt.tprintf("%s/%s",filepath.dir(source),string(bytes[len("LEVEL "):]))
    o:importer.Outputs
    if error=importer.outputs_begin(&o,source,filepath.stem(source),u64(len(bytes)),base.hash64(bytes),importer.import_version((^Level_Importer)(state).version),options,LEVEL_IMPORTER,allocator);error.code!=.None {return}
    model:importer.Imported_Model
    if error=importer.output_input(&o,model_path);error.code==.None {model,error=importer.import_model(model_path,FORMATS[:],options)}
    defer importer.model_destroy(&model)
    if error.code==.None {_,error=importer.output_model(&o,&model,context.temp_allocator)}
    if version:=(^Level_Importer)(state).kit;version!=0 && error.code==.None {
        id,path:=importer.output_part(&o,KIT,"hall",0,".kit")
        kit:asset.Document
        asset.document_init(&kit,KIT,id,context.temp_allocator)
        kit.kind_version=version
        if asset.document_save(&kit,path)!=.None {error=importer.error_make(.Write,"%s could not be written",path)}
        if error.code==.None {error=importer.output_written(&o,id,"hall")}
    }
    if error.code!=.None {
        _,_=importer.outputs_end(&o,true)
        return {},"",error
    }
    report,error=importer.outputs_end(&o,false,allocator)
    return report,"",error
}

// A refresh ingests again a whole source a plugin claims when what it is
// built from changes: its bytes or those of a file it reads, or the code of
// the plugin; it leaves a current one alone, the ids stay, and a document it
// wrote into the project that was changed since stays as it is.
@(test)
a_refresh_ingests_again_a_whole_source_when_what_it_is_built_from_changes :: proc(t:^testing.T) {
    root,assets:=test_project(t,"refresh-whole")
    if root=="" {return}
    props:=fmt.tprintf("%s/props",assets)
    os.make_directory_all(props)
    box_source(props,"crate.gltf","Wood","Paint")
    level:=write_text(assets,"hall.level","LEVEL props/crate.gltf")
    state:=Level_Importer{kit=2}
    s:=test_store(t,fmt.tprintf("%s/store",root))
    if s==nil {return}
    context.user_ptr=&state
    leveling :: proc(root:string,s:^store.Store,allocator:mem.Allocator) -> Library_Imports {
        wholes:=make([]Whole_Source,1,allocator)
        level:=(^Level_Importer)(context.user_ptr)
        wholes[0]={name=LEVEL_IMPORTER,version=level.version,claims=level_claims,run=level_run,state=level,code=level.code}
        return {wholes=wholes}
    }
    options:=Library_Options{store=s,root=root,plugins=leveling,fast_textures=true}
    first,error:=ingest(level,options,allocator=context.temp_allocator)
    if !testing.expectf(t,error.code==.None,"%s",error.message) {return}
    mesh,has_mesh:=written_of(&first,asset.KIND_MESH,"Box")
    testing.expect(t,has_mesh && mesh.path=="" && asset.object_whole(s,mesh.object),"the mesh of the level is an object of the store")
    p,_:=asset.package_get(s,first.manifest,context.temp_allocator)
    testing.expectf(t,slice.contains(p.inputs[:],"props/crate.gltf") && slice.contains(p.inputs[:],"props/wood.png"),"the files it reads are its inputs: %v",p.inputs)
    added:=project_add(root,first.manifest,"",nil,options,context.temp_allocator)
    testing.expectf(t,len(added.failures)==0 && len(added.missing)==0,"%v",added)
    _,has_kit:=written_of(&first,KIT,"hall")
    testing.expect(t,has_kit,"the level wrote a document")

    runs:=state.runs
    current:=project_refresh(root,options,context.temp_allocator)
    testing.expectf(t,current.ingested==0 && len(current.failures)==0 && len(current.missing)==0 && state.runs==runs,"a current source is left alone: %v",current)
    Change :: enum {Input,Code,Edited}
    kit_id,_:=written_of(&first,KIT,"hall")
    r:asset.Registry
    asset.registry_init(&r,assets,"",context.temp_allocator)
    testing.expect_value(t,asset.registry_scan(&r),asset.Error.None)
    kit_file,kit_found:=asset.registry_find(&r,kit_id.id)
    if !testing.expect(t,kit_found,"the project has its file of the document") {return}
    kit:=asset.registry_file_path(&r,kit_file.path,context.temp_allocator)
    for change in Change {
        switch change {
        case .Input: _=os.write_entire_file(fmt.tprintf("%s/wood.png",props),png_bytes(4,4,{20,90,200}))
        case .Code: state.code=7
        case .Edited:
            doc:asset.Document
            testing.expect_value(t,asset.document_load(&doc,kit,context.temp_allocator),asset.Error.None)
            _,_=asset.document_table_add(&doc,"notes")
            testing.expect_value(t,asset.document_save(&doc,kit),asset.Error.None)
            state.code=9
        }
        edited,_:=os.read_entire_file(kit,context.temp_allocator)
        runs=state.runs
        changed:=project_refresh(root,options,context.temp_allocator)
        testing.expectf(t,changed.ingested==1 && len(changed.failures)==0 && state.runs==runs+1,"%v: %v",change,changed)
        if change==.Edited {
            now,_:=os.read_entire_file(kit,context.temp_allocator)
            testing.expectf(t,string(now)==string(edited) && len(changed.warnings)==1 && contains(changed.warnings[0],"assets/hall"),"what was changed of it stays, and the refresh says so: %v",changed.warnings)
        }
        testing.expectf(t,project_refresh(root,options,context.temp_allocator).ingested==0,"%v: then nothing",change)
    }
    list,_,_:=asset.packages_load(root,context.temp_allocator)
    again,_:=asset.package_get(s,list.packages[0].manifest,context.temp_allocator)
    testing.expect(t,list.packages[0].manifest!=first.manifest && len(again.assets)==len(p.assets) && again.assets[0].id==p.assets[0].id,"the level keeps its assets, pinned anew")
}

// Each of two sources a plugin imports whole from one folder, from outside the
// project or from its assets, writes its documents in the folder of its own
// name under the one it is added to.
@(test)
the_documents_of_a_whole_source_go_to_its_own_folder :: proc(t:^testing.T) {
    root,assets:=test_project(t,"whole-documents")
    if root=="" {return}
    Fixture :: struct {level:Level_Importer,loads,releases:int}
    state:=Fixture{level={kit=2}}
    context.user_ptr=&state
    leveling :: proc(root:string,s:^store.Store,allocator:mem.Allocator) -> Library_Imports {
        fixture:=(^Fixture)(context.user_ptr)
        fixture.loads+=1
        wholes:=make([]Whole_Source,1,allocator)
        level:=&fixture.level
        wholes[0]={name=LEVEL_IMPORTER,version=level.version,claims=level_claims,run=level_run,state=level,code=level.code}
        return {wholes=wholes,state=fixture,release=proc(raw:rawptr) {(^Fixture)(raw).releases+=1}}
    }
    kept:=fmt.tprintf("%s/store",root)
    errors:=strings.builder_make(context.temp_allocator)
    Case :: struct {sources,name,folder:string,explicit_folder:bool}
    for c in ([]Case{
        {fmt.tprintf("%s/outside",root),"yard","levels",true},
        {fmt.tprintf("%s/maps",assets),"hall","maps",false},
        {fmt.tprintf("%s/maps",assets),"roof","",true},
    }) {
        os.make_directory_all(c.sources)
        box_source(c.sources,"crate.gltf","Wood","Paint")
        source:=write_text(c.sources,fmt.tprintf("%s.level",c.name),"LEVEL crate.gltf")
        args:=make([dynamic]string,context.temp_allocator)
        append(&args,source,"--store",kept,"--project",root)
        if c.explicit_folder {append(&args,"--folder",c.folder)}
        state.loads,state.releases=0,0
        code:=command(args[:],{},strings.to_writer(&errors),leveling)
        if !testing.expectf(t,code==0,"%s: %s",source,strings.to_string(errors)) {return}
        testing.expect_value(t,state.loads,1)
        testing.expect_value(t,state.releases,1)
        r:asset.Registry
        asset.registry_init(&r,assets,"",context.temp_allocator)
        testing.expect_value(t,asset.registry_scan(&r),asset.Error.None)
        prefix:=fmt.tprintf("%s/",project.path(c.folder,c.name,allocator=context.temp_allocator))
        documents:=0
        for &file in r.files {documents+=int(strings.has_prefix(file.path,prefix))}
        testing.expectf(t,documents>=2,"%s wrote its kit and materials under %s",source,prefix)
    }
    state.loads,state.releases=0,0
    args:=[]string{"--store",kept,"--refresh",root,"--refresh",fmt.tprintf("%s/.",root)}
    code:=command(args,{},strings.to_writer(&errors),leveling)
    testing.expectf(t,code==0,"%s",strings.to_string(errors))
    testing.expect_value(t,state.loads,1)
    testing.expect_value(t,state.releases,1)
}

// A store with no build of a source a plugin imports whole takes it by key
// from another store, lists and loads it, and imports nothing. Another version
// or code of the importer, also with the unchanged source here, or no importer
// at all, takes the build the other store chose for the manifest, keeps it as
// that choice and not under its own key, and finds it here on the next refresh
// without asking. With no store to ask it says why the importer was not read.
@(test)
a_whole_source_build_is_found_by_key_without_its_source :: proc(t:^testing.T) {
    root,assets:=test_project(t,"whole-by-key")
    if root=="" {return}
    props:=fmt.tprintf("%s/props",assets)
    os.make_directory_all(props)
    box_source(props,"crate.gltf","Wood","Paint")
    level:=write_text(assets,"hall.level","LEVEL props/crate.gltf")
    state:=Level_Importer{version=1}
    context.user_ptr=&state
    leveling :: proc(root:string,s:^store.Store,allocator:mem.Allocator) -> Library_Imports {
        wholes:=make([]Whole_Source,1,allocator)
        level:=(^Level_Importer)(context.user_ptr)
        wholes[0]={name=LEVEL_IMPORTER,version=level.version,claims=level_claims,run=level_run,state=level,code=level.code}
        return {wholes=wholes}
    }
    s:=test_store(t,fmt.tprintf("%s-host",root))
    if s==nil {return}
    first,error:=ingest(level,{store=s,root=root,plugins=leveling},allocator=context.temp_allocator)
    if !testing.expectf(t,error.code==.None,"%s",error.message) {return}
    added:=project_add(root,first.manifest,"",nil,{store=s,root=root,plugins=leveling},context.temp_allocator)
    if !testing.expectf(t,len(added.failures)==0 && len(added.missing)==0,"%v",added) {return}
    peer,sourced:=fmt.tprintf("%s-peer",root),fmt.tprintf("%s-sourced",root)
    folder_copy(root,peer)
    folder_copy(root,sourced)
    testing.expect(t,os.remove(fmt.tprintf("%s/assets/hall.level",peer))==nil)
    runs:=state.runs
    UNBUILT :: "the editor could not be built"
    unbuilt :: proc(root:string,s:^store.Store,allocator:mem.Allocator) -> Library_Imports {return {problem=UNBUILT}}
    Case :: struct {version:u16,code:u64,importer,source,asked,found:bool}
    for c,k in ([]Case{
        {1,0,true,false,true,true},
        {2,0,true,false,true,true},
        {1,5,true,false,true,true},
        {2,0,true,true,true,true},
        {1,0,false,false,true,true},
        {1,0,false,false,false,false},
    }) {
        state.version,state.code=c.version,c.code
        here:=test_store(t,fmt.tprintf("%s-store-%d",root,k))
        if here==nil {return}
        project:=sourced if c.source else peer
        options:=Library_Options{store=here,root=project,plugins=leveling if c.importer else unbuilt}
        if c.asked {options.source=cache.store_source(s)}
        refreshed:=project_refresh(project,options,context.temp_allocator)
        testing.expectf(t,state.runs==runs && refreshed.ingested==0,"%v: nothing is imported",c)
        if !c.found {
            testing.expectf(t,refreshed.fetched==0 && len(refreshed.missing)==1,"%v: no build is found: %v",c,refreshed)
            if !c.importer && len(refreshed.missing)==1 {testing.expectf(t,strings.contains(refreshed.missing[0],UNBUILT),"it says why: %s",refreshed.missing[0])}
            continue
        }
        testing.expectf(t,refreshed.fetched==1 && len(refreshed.missing)==0 && len(refreshed.failures)==0,"%v: %v",c,refreshed)
        imports,_:=store.ref_list(here,asset.REF_IMPORTS,context.temp_allocator)
        fast,_:=store.ref_list(here,asset.REF_IMPORTS_FAST,context.temp_allocator)
        by_key:=c.importer && c.version==1 && c.code==0
        testing.expectf(t,len(imports)+len(fast)==(1 if by_key else 0),"%v: a build of another key is kept only as the choice: %v %v",c,imports,fast)
        options.source={}
        again:=project_refresh(project,options,context.temp_allocator)
        testing.expectf(t,state.runs==runs && again.ingested==0 && again.fetched==0 && len(again.missing)==0 && len(again.failures)==0,"%v: found here without asking: %v",c,again)
        listed,list_error:=asset.root_packages_in(here,project,context.temp_allocator)
        testing.expectf(t,list_error==.None && len(listed.problems)==0 && len(listed.listed)>0,"%v",listed)
        for l in listed.listed {
            a:asset.Asset
            if testing.expectf(t,asset.asset_open_object(&a,here,l.object,context.temp_allocator)==.None,"%s loads",l.path) {asset.asset_close(&a)}
        }
    }
}

// The code of a plugin is its Odin sources and those of the plugins it holds,
// not its tests nor what git keeps.
@(test)
the_code_of_a_plugin_changes_with_its_sources_alone :: proc(t:^testing.T) {
    plugin:=base.test_folder(t,"plugin-code")
    if plugin=="" {return}
    for folder in ([?]string{"editor","plugins/bridge/editor",".git"}) {os.make_directory_all(fmt.tprintf("%s/%s",plugin,folder))}
    write_text(plugin,"editor/level.odin","package level")
    write_text(plugin,"plugins/bridge/editor/bridge.odin","package bridge")
    Edit :: struct {file:string,changes:bool}
    for edit in ([?]Edit{{"editor/level.odin",true},{"plugins/bridge/editor/bridge.odin",true},{"editor/level_test.odin",false},{".git/HEAD",false},{"editor/notes.md",false}}) {
        before:=code_identity(plugin)
        write_text(plugin,edit.file,fmt.tprintf("// %s",edit.file))
        testing.expectf(t,(code_identity(plugin)!=before)==edit.changes,"%s",edit.file)
    }
}

// An image with no settings holds what its name says, from mirai import as
// from the editor: a packed mask is linear data, a photo a color. A use
// given once stays in its settings.
@(test)
an_image_on_its_own_holds_what_its_name_says_until_its_settings_say_otherwise :: proc(t:^testing.T) {
    root,assets:=test_project(t,"image-use")
    if assets=="" {return}
    kept:=fmt.tprintf("%s/store",root)
    run :: proc(args:..string) -> (code:int,err:string) {
        output,errors:=strings.builder_make(context.temp_allocator),strings.builder_make(context.temp_allocator)
        code=command(args,strings.to_writer(&output),strings.to_writer(&errors))
        return code,strings.to_string(errors)
    }
    stored :: proc(t:^testing.T,kept,source:string) -> importer.Image_Use {
        settings,_,_:=importer.settings_load({store=test_store(t,kept)},source)
        return settings.image
    }
    masks:=fmt.tprintf("%s/T_Katana_SpecularMasks.png",assets)
    diffuse:=fmt.tprintf("%s/T_Katana_Diffuse.png",assets)
    for path in ([?]string{masks,diffuse}) {_=os.write_entire_file(path,png_bytes(4,4,{10,200,30}))}

    code,err:=run(masks,"--uncompressed","--store",kept)
    testing.expectf(t,code==0,"%s",err)
    testing.expect_value(t,stored(t,kept,masks),importer.Image_Use.Data)
    code,err=run(diffuse,"--uncompressed","--store",kept)
    testing.expectf(t,code==0,"%s",err)
    testing.expect_value(t,stored(t,kept,diffuse),importer.Image_Use.Color)

    // Given once, the use stays: the name no longer decides.
    code,err=run(masks,"--uncompressed","--srgb","--store",kept)
    testing.expectf(t,code==0,"%s",err)
    code,err=run(masks,"--uncompressed","--store",kept)
    testing.expectf(t,code==0,"%s",err)
    testing.expect_value(t,stored(t,kept,masks),importer.Image_Use.Color)

    Named :: struct {name:string,use:importer.Image_Use}
    for named in ([?]Named{{"data",.Data},{"Color",.Color},{"normal",.Normal},{"NORMAL_GREEN_DOWN",.Normal_Green_Down}}) {
        got,known:=image_use_from_name(named.name)
        testing.expectf(t,known && got==named.use,"%s: %v",named.name,got)
    }
    _,known:=image_use_from_name("metallic")
    testing.expect(t,!known)
}

// A skeleton too old to read gives up what a person set on it, and the import says so, keeping its id.
@(test)
importing_over_a_skeleton_of_an_older_version_says_what_it_did_not_keep :: proc(t:^testing.T) {
    root,folder:=test_project(t,"old-skeleton")
    if folder=="" {return}
    source:=copy_in(root,FIXTURES,"skeletal-analytic.glb")
    first,error:=import_test(t,source,{world=prefab.import_world(t),textures=.Uncompressed})
    if !testing.expectf(t,error.code==.None,"%s",error.message) {return}
    defer importer.report_destroy(&first)
    skeleton:importer.Written
    for written in first.assets {if written.kind==asset.KIND_SKELETON {skeleton=written}}
    if !testing.expect(t,skeleton.path!="","the source has a skeleton") {return}
    data,_:=os.read_entire_file(skeleton.path,context.temp_allocator)
    old:=asset.SKELETON_VERSION-1
    data[10],data[11]=u8(old),u8(old>>8)
    testing.expect(t,os.write_entire_file(skeleton.path,data)==nil)
    again,failed:=import_test(t,source,{world=prefab.import_world(t),textures=.Uncompressed})
    if !testing.expectf(t,failed.code==.None,"%s",failed.message) {return}
    defer importer.report_destroy(&again)
    told:=false
    for warning in again.warnings {told||=strings.contains(warning,"were not kept")}
    testing.expectf(t,told,"the import says what it dropped: %v",again.warnings)
    testing.expect_value(t,header_of(skeleton.path).id,skeleton.id)
    testing.expect_value(t,header_of(skeleton.path).kind_version,u16(asset.SKELETON_VERSION))
}

@(test)
an_image_is_a_normal_map_only_when_n_is_a_word_of_its_name :: proc(t:^testing.T) {
    Named :: struct {name:string,use:importer.Image_Use}
    for named in ([?]Named{{"wall_n.png",.Normal},{"wall_n_2.png",.Normal},{"wall_normal.png",.Normal},{"wall_nm.png",.Normal},{"wall_nor_gl.png",.Normal},{"wall_norm.png",.Normal},{"hud_nmbr2.png",.Color},{"icon_new.png",.Color},{"north_wall.png",.Color},{"n_wall.png",.Color}}) {
        testing.expectf(t,image_use(named.name)==named.use,"%s: %v",named.name,image_use(named.name))
    }
}
