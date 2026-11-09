package sources

import "core:c"
import "core:encoding/base64"
import "core:fmt"
import "core:math"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import stbi "vendor:stb/image"
import "mirai:asset"
import importer "mirai:cook/import"
import "mirai:std/base"

// A box with two materials, the first with the image wood.png next to it.
@(private="file")
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
box_import :: proc(t:^testing.T,source,root:string,into:base.Asset_Id={}) -> (report:importer.Import_Report,ok:bool) {
    error:importer.Error
    report,error=import_source(source,fmt.tprintf("%s/assets/models/box",root),{root=root,textures=.Uncompressed,no_save=true,into=into})
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

@(test)
the_parts_of_an_import_name_its_prefab_and_keep_their_ids_where_they_were_moved :: proc(t:^testing.T) {
    root:=temp_folder("reimport-moved");defer os.remove_all(root)
    os.make_directory_all(fmt.tprintf("%s/source",root))
    source:=box_source(fmt.tprintf("%s/source",root),"box.gltf","Wood","Paint")
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    first,ok:=box_import(t,source,root);if !ok {return};defer importer.report_destroy(&first)
    prefab,has_prefab:=written_of(&first,asset.KIND_PREFAB,"box")
    wood,has_wood:=written_of(&first,asset.KIND_MATERIAL,"Wood")
    if !testing.expect(t,has_prefab && has_wood && prefab.id!={} && prefab.id==first.prefab) {return}
    // The mesh is a part; Wood, whose island reaches across its texture, and Paint, without one, are not.
    for written in first.assets {
        header:=header_of(written.path)
        testing.expect_value(t,header.id,written.id)
        testing.expectf(t,header.owner==(written.kind==asset.KIND_MESH?prefab.id:base.Asset_Id{}),"%s: owner %v",written.path,header.owner)
    }
    testing.expect(t,strings.has_prefix(wood.detail,"of its own: an island"),wood.detail)
    a,loaded:=read_asset(t,prefab,&types)
    if loaded {
        info,error:=asset.import_info(&a,&types)
        testing.expect(t,error==.None && info!=nil && string_of(info.source[:])=="source/box.gltf" && .Cooked in a.blob.header.flags,"the prefab records its import")
        asset.asset_close(&a)
    }

    // The material moved to another folder is written there with its id.
    os.make_directory_all(fmt.tprintf("%s/assets/materials",root))
    moved:=fmt.tprintf("%s/assets/materials/Wood.mat",root)
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

@(test)
a_source_moved_or_renamed_keeps_the_ids_of_its_import :: proc(t:^testing.T) {
    root:=temp_folder("reimport-renamed");defer os.remove_all(root)
    os.make_directory_all(fmt.tprintf("%s/source/props",root))
    source:=box_source(fmt.tprintf("%s/source",root),"box.gltf","Wood","Paint")
    first,ok:=box_import(t,source,root);if !ok {return};defer importer.report_destroy(&first)

    // Moved and renamed with the same bytes: found by them.
    crate:=fmt.tprintf("%s/source/props/crate.gltf",root)
    _=os.write_entire_file(fmt.tprintf("%s/source/props/wood.png",root),png_bytes(4,4,{150,90,40}))
    testing.expect(t,os.rename(source,crate)==nil)
    moved,moved_ok:=box_import(t,crate,root);if !moved_ok {return};defer importer.report_destroy(&moved)
    testing.expect_value(t,moved.prefab,first.prefab)
    for written in first.assets {
        same,found:=written_of(&moved,written.kind,written.kind==asset.KIND_PREFAB?"crate":written.name)
        testing.expectf(t,found && same.id==written.id && same.path==written.path,"%s keeps its id and its file",written.name)
    }
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    prefab,_:=written_of(&moved,asset.KIND_PREFAB,"crate")
    if a,loaded:=read_asset(t,prefab,&types);loaded {
        info,_:=asset.import_info(&a,&types)
        testing.expect(t,info!=nil && string_of(info.source[:])=="source/props/crate.gltf","the import names the source where it is now")
        asset.asset_close(&a)
    }

    // Renamed and changed: into names the import.
    barrel:=box_source(fmt.tprintf("%s/source/props",root),"barrel.gltf","Wood","Paint","0.8")
    os.remove(crate)
    renamed,renamed_ok:=box_import(t,barrel,root,into=first.prefab);if !renamed_ok {return};defer importer.report_destroy(&renamed)
    testing.expect_value(t,renamed.prefab,first.prefab)
    for written in first.assets {
        if written.kind==asset.KIND_PREFAB {continue}
        same,found:=written_of(&renamed,written.kind,written.name)
        testing.expectf(t,found && same.id==written.id,"%s keeps its id",written.name)
    }
    _,wrong:=import_source(barrel,fmt.tprintf("%s/assets/models/box",root),{root=root,textures=.Uncompressed,no_save=true,into=renamed.material_ids[0]})
    testing.expect(t,wrong.code==.Not_Found && strings.contains(wrong.message,"into names the prefab"),wrong.message)
}

@(test)
a_copy_of_a_source_that_is_still_there_is_an_import_of_its_own_and_says_so :: proc(t:^testing.T) {
    root:=temp_folder("reimport-copy");defer os.remove_all(root)
    os.make_directory_all(fmt.tprintf("%s/source/copy",root))
    source:=box_source(fmt.tprintf("%s/source",root),"box.gltf","Wood","Paint")
    first,ok:=box_import(t,source,root);if !ok {return};defer importer.report_destroy(&first)
    copy:=box_source(fmt.tprintf("%s/source/copy",root),"box.gltf","Wood","Paint")
    second,second_ok:=box_import(t,copy,root);if !second_ok {return};defer importer.report_destroy(&second)
    testing.expect(t,second.prefab!=first.prefab,"the copy writes a prefab of its own")
    warned:=false
    for warning in second.warnings {warned||=strings.contains(warning,"has the bytes of source/box.gltf")}
    testing.expectf(t,warned,"the import says which source it is a copy of: %v",second.warnings)
}

@(test)
a_material_renamed_in_the_source_keeps_its_id_and_a_part_taken_out_is_left_alone :: proc(t:^testing.T) {
    root:=temp_folder("reimport-parts");defer os.remove_all(root)
    os.make_directory_all(fmt.tprintf("%s/source",root))
    source:=box_source(fmt.tprintf("%s/source",root),"box.gltf","Wood","Paint")
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    first,ok:=box_import(t,source,root);if !ok {return};defer importer.report_destroy(&first)
    wood,_:=written_of(&first,asset.KIND_MATERIAL,"Wood")
    paint,_:=written_of(&first,asset.KIND_MATERIAL,"Paint")

    // Renamed in the source, the material is the same asset by its place.
    box_source(fmt.tprintf("%s/source",root),"box.gltf","Oak","Paint")
    renamed,renamed_ok:=box_import(t,source,root);if !renamed_ok {return};defer importer.report_destroy(&renamed)
    oak,has_oak:=written_of(&renamed,asset.KIND_MATERIAL,"Oak")
    testing.expect(t,has_oak && oak.id==wood.id && oak.path==wood.path)
    testing.expect_value(t,slot_materials(t,&renamed,&types),[2]base.Asset_Id{wood.id,paint.id})

    // Taken out of the prefab, the mesh stays out: the import keeps the decision.
    mesh,_:=written_of(&first,asset.KIND_MESH,"Box")
    testing.expect(t,header_of(mesh.path).owner==first.prefab)
    testing.expect_value(t,asset.file_owner_set(mesh.path,{}),asset.Error.None)
    after,after_ok:=box_import(t,source,root);if !after_ok {return};defer importer.report_destroy(&after)
    box,has_box:=written_of(&after,asset.KIND_MESH,"Box")
    testing.expect(t,has_box && box.id==mesh.id && box.path==mesh.path)
    header:=header_of(mesh.path)
    testing.expect(t,header.owner=={} && .Cooked in header.flags,"the part taken out keeps its id and its import, and stays out of its owner")
    testing.expect_value(t,slot_materials(t,&after,&types),[2]base.Asset_Id{wood.id,paint.id})

    // Forced, every material and texture is a part.
    forced,forced_ok:=import_source(source,fmt.tprintf("%s/assets/models/box",root),{root=root,textures=.Uncompressed,no_save=true,parts=.All})
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
    root:=temp_folder("parts-rule");defer os.remove_all(root)
    folder:=fmt.tprintf("%s/source",root)
    atlas_images(folder)
    source:=atlas_source(folder,"props.gltf",{"atlas","waves","across","shared"})
    report,error:=import_source(source,fmt.tprintf("%s/assets/models/props",root),{root=root,textures=.Uncompressed,no_save=true})
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
        if written.kind==asset.KIND_PREFAB {continue}
        part:=written.kind==asset.KIND_MESH || written.name=="Atlas" || written.name=="atlas"
        owner:=header_of(written.path).owner
        testing.expectf(t,owner==(part?report.prefab:base.Asset_Id{}),"%s: owner %v",written.path,owner)
        if written.kind==asset.KIND_MATERIAL {testing.expectf(t,strings.has_prefix(written.detail,reason(written.name)),"%s: %s",written.name,written.detail)}
    }
}

@(test)
a_second_model_with_the_same_textures_takes_its_material_and_both_lose_it_as_a_part :: proc(t:^testing.T) {
    root:=temp_folder("parts-shared");defer os.remove_all(root)
    atlas_images(fmt.tprintf("%s/source/first",root))
    atlas_images(fmt.tprintf("%s/source/second",root))
    first_source:=atlas_source(fmt.tprintf("%s/source/first",root),"crate.gltf",{"atlas","waves","across","shared"})
    first,error:=import_source(first_source,fmt.tprintf("%s/assets/crate",root),{root=root,textures=.Uncompressed,no_save=true})
    if !testing.expectf(t,error.code==.None,"%s",error.message) {return};defer importer.report_destroy(&first)
    atlas,_:=written_of(&first,asset.KIND_MATERIAL,"Atlas")
    texture,_:=written_of(&first,asset.KIND_TEXTURE,"atlas")
    testing.expect(t,header_of(atlas.path).owner==first.prefab && header_of(texture.path).owner==first.prefab)

    second_source:=atlas_source(fmt.tprintf("%s/source/second",root),"barrel.gltf",{"atlas","waves","across","shared"})
    second,second_error:=import_source(second_source,fmt.tprintf("%s/assets/barrel",root),{root=root,textures=.Uncompressed,no_save=true})
    if !testing.expectf(t,second_error.code==.None,"%s",second_error.message) {return};defer importer.report_destroy(&second)
    testing.expect_value(t,second.material_ids[0],atlas.id)
    testing.expect_value(t,second.image_ids[0],texture.id)
    _,wrote_material:=written_of(&second,asset.KIND_MATERIAL,"Atlas")
    _,wrote_texture:=written_of(&second,asset.KIND_TEXTURE,"atlas")
    testing.expect(t,!wrote_material && !wrote_texture,"what the project has is not written twice")
    testing.expect(t,header_of(atlas.path).owner=={} && header_of(texture.path).owner=={},"used by two models, they are parts of neither")
    mesh,_:=written_of(&first,asset.KIND_MESH,"Body")
    testing.expect_value(t,header_of(mesh.path).owner,first.prefab)
}

// The editor writes a texture Fast until the cook encodes it again: the
// next import of the editor with that image takes it as one written Final.
@(test)
a_second_model_imported_by_the_editor_takes_the_texture_the_first_wrote_fast :: proc(t:^testing.T) {
    root:=temp_folder("parts-shared-fast");defer os.remove_all(root)
    os.make_directory_all(fmt.tprintf("%s/source/chair",root))
    os.make_directory_all(fmt.tprintf("%s/source/table",root))
    chair_source:=box_source(fmt.tprintf("%s/source/chair",root),"chair.gltf","Wood","Paint")
    table_source:=box_source(fmt.tprintf("%s/source/table",root),"table.gltf","Wood","Paint")
    chair,error:=import_source(chair_source,fmt.tprintf("%s/assets/chair",root),{root=root,fast_textures=true,no_save=true})
    if !testing.expectf(t,error.code==.None,"%s",error.message) {return};defer importer.report_destroy(&chair)
    texture,found:=written_of(&chair,asset.KIND_TEXTURE,"wood")
    if !testing.expect(t,found) {return}
    table,table_error:=import_source(table_source,fmt.tprintf("%s/assets/table",root),{root=root,fast_textures=true,no_save=true})
    if !testing.expectf(t,table_error.code==.None,"%s",table_error.message) {return};defer importer.report_destroy(&table)
    testing.expect_value(t,table.image_ids[0],texture.id)
    _,wrote:=written_of(&table,asset.KIND_TEXTURE,"wood")
    testing.expect(t,!wrote,"the image is not written twice")
}

@(test)
a_second_model_with_the_same_textures_and_other_values_writes_a_material_of_its_own :: proc(t:^testing.T) {
    root:=temp_folder("parts-shared-values");defer os.remove_all(root)
    os.make_directory_all(fmt.tprintf("%s/source/chair",root))
    os.make_directory_all(fmt.tprintf("%s/source/table",root))
    chair_source:=box_source(fmt.tprintf("%s/source/chair",root),"chair.gltf","Wood","Paint",roughness="0.5")
    table_source:=box_source(fmt.tprintf("%s/source/table",root),"table.gltf","Wood","Paint",roughness="0.9")
    chair,error:=import_source(chair_source,fmt.tprintf("%s/assets/chair",root),{root=root,textures=.Uncompressed,no_save=true})
    if !testing.expectf(t,error.code==.None,"%s",error.message) {return};defer importer.report_destroy(&chair)
    table,table_error:=import_source(table_source,fmt.tprintf("%s/assets/table",root),{root=root,textures=.Uncompressed,no_save=true})
    if !testing.expectf(t,table_error.code==.None,"%s",table_error.message) {return};defer importer.report_destroy(&table)
    testing.expect_value(t,table.image_ids[0],chair.image_ids[0])
    testing.expect(t,table.material_ids[0]!=chair.material_ids[0],"a material the source gives other values is no material of another import")
    _,wrote:=written_of(&table,asset.KIND_MATERIAL,"Wood")
    testing.expect(t,wrote)
}

@(test)
an_image_imported_on_its_own_takes_no_texture_of_a_model_whose_source_moved :: proc(t:^testing.T) {
    root:=temp_folder("reimport-image-model");defer os.remove_all(root)
    os.make_directory_all(fmt.tprintf("%s/source",root))
    source:=box_source(fmt.tprintf("%s/source",root),"box.gltf","Wood","Paint")
    first,ok:=box_import(t,source,root);if !ok {return};defer importer.report_destroy(&first)
    texture,found:=written_of(&first,asset.KIND_TEXTURE,"wood")
    if !testing.expect(t,found) {return}
    testing.expect_value(t,os.rename(source,fmt.tprintf("%s/source/moved.gltf.old",root)),nil)
    image,error:=import_source(fmt.tprintf("%s/source/wood.png",root),fmt.tprintf("%s/assets/textures",root),{root=root,no_save=true})
    if !testing.expectf(t,error.code==.None,"%s",error.message) {return};defer importer.report_destroy(&image)
    if !testing.expect_value(t,len(image.assets),1) {return}
    testing.expect(t,image.assets[0].id!=texture.id && image.assets[0].path!=texture.path,"the texture of the model stays its own")
    testing.expect_value(t,header_of(texture.path).id,texture.id)
}

// mirai import does not write an earlier output outside --out unless asked:
// with --root reaching the live import, a scratch --out fails and leaves it
// alone; --copy makes a separate import there, --in-place updates the live one.
@(test)
mirai_import_writes_nothing_outside_out_unless_asked :: proc(t:^testing.T) {
    root:=temp_folder("reimport-outside");defer os.remove_all(root)
    os.make_directory_all(fmt.tprintf("%s/source",root))
    source:=box_source(fmt.tprintf("%s/source",root),"box.gltf","Wood","Paint")
    first,ok:=box_import(t,source,root);if !ok {return};defer importer.report_destroy(&first)
    prefab,_:=written_of(&first,asset.KIND_PREFAB,"box")
    live,_:=os.read_entire_file(prefab.path,context.temp_allocator)
    live_mesh,_:=written_of(&first,asset.KIND_MESH,"Box")
    mesh_bytes,_:=os.read_entire_file(live_mesh.path,context.temp_allocator)
    run :: proc(args:..string) -> (code:int,out,err:string) {
        output,errors:=strings.builder_make(context.temp_allocator),strings.builder_make(context.temp_allocator)
        code=command(args,strings.to_writer(&output),strings.to_writer(&errors))
        return code,strings.to_string(output),strings.to_string(errors)
    }
    scratch:=fmt.tprintf("%s/assets/scratch",root)
    unchanged :: proc(path:string,bytes:[]u8) -> bool {
        now,_:=os.read_entire_file(path,context.temp_allocator)
        return slice.equal(now,bytes)
    }

    code,_,err:=run(source,"--out",scratch,"--root",root,"--uncompressed","--no-save","--rebuild")
    testing.expect_value(t,code,1)
    testing.expect(t,strings.contains(err,"box.prefab") && strings.contains(err,"--in-place") && strings.contains(err,"--copy"),err)
    testing.expect(t,unchanged(prefab.path,live) && unchanged(live_mesh.path,mesh_bytes),"the live import is left as it was")
    entries,_:=os.read_all_directory_by_path(scratch,context.temp_allocator)
    testing.expect_value(t,len(entries),0)

    code,_,err=run(source,"--out",scratch,"--root",root,"--uncompressed","--no-save","--copy")
    testing.expect_value(t,code,0)
    testing.expect(t,unchanged(prefab.path,live) && unchanged(live_mesh.path,mesh_bytes),"a copy leaves the live import alone")
    copied:=header_of(fmt.tprintf("%s/box.prefab",scratch))
    testing.expect(t,copied.id!={} && copied.id!=prefab.id,"the copy has an id of its own")

    code,_,err=run(source,"--in-place","--copy","--out",scratch)
    testing.expect_value(t,code,2)

    // With the copy there, each import of the source updates the one in its folder.
    box:=fmt.tprintf("%s/assets/models/box",root)
    copy_bytes,_:=os.read_entire_file(fmt.tprintf("%s/box.prefab",scratch),context.temp_allocator)
    out:string
    code,out,err=run(source,"--out",box,"--root",root,"--uncompressed","--no-save","--rebuild")
    testing.expectf(t,code==0,"%s",err)
    testing.expect(t,!strings.contains(out,"warning:"),out)
    testing.expect(t,unchanged(fmt.tprintf("%s/box.prefab",scratch),copy_bytes),"the copy is left alone")
    for written in first.assets {
        testing.expectf(t,strings.contains(out,written.path),"%s is written again where it is: %s",written.path,out)
    }

    // A part moved outside --out is refused too, and --in-place writes it where it is.
    wood,_:=written_of(&first,asset.KIND_MATERIAL,"Wood")
    os.make_directory_all(fmt.tprintf("%s/assets/materials",root))
    moved:=fmt.tprintf("%s/assets/materials/Wood.mat",root)
    testing.expect(t,os.rename(wood.path,moved)==nil)
    code,_,err=run(source,"--out",box,"--root",root,"--uncompressed","--no-save")
    testing.expect_value(t,code,1)
    testing.expect(t,strings.contains(err,"Wood.mat"),err)
    code,_,err=run(source,"--out",box,"--root",root,"--uncompressed","--no-save","--in-place")
    testing.expect_value(t,code,0)
    testing.expect_value(t,header_of(moved).id,wood.id)
    testing.expect(t,!os.exists(wood.path),"the material stays where it was moved")
}

// An image with no settings holds what its name says, from mirai import as
// from the editor: a packed mask is linear data, a photo a color. A use
// given once stays in its settings.
@(test)
an_image_on_its_own_holds_what_its_name_says_until_its_settings_say_otherwise :: proc(t:^testing.T) {
    root:=temp_folder("image-use");defer os.remove_all(root)
    out:=fmt.tprintf("%s/textures",root)
    run :: proc(args:..string) -> (code:int,err:string) {
        output,errors:=strings.builder_make(context.temp_allocator),strings.builder_make(context.temp_allocator)
        code=command(args,strings.to_writer(&output),strings.to_writer(&errors))
        return code,strings.to_string(errors)
    }
    stored :: proc(source:string) -> importer.Image_Use {
        settings,_,_:=importer.settings_load(source)
        return settings.image
    }
    masks:=fmt.tprintf("%s/T_Katana_SpecularMasks.png",root)
    diffuse:=fmt.tprintf("%s/T_Katana_Diffuse.png",root)
    for path in ([?]string{masks,diffuse}) {_=os.write_entire_file(path,png_bytes(4,4,{10,200,30}))}

    code,err:=run(masks,"--out",out,"--uncompressed")
    testing.expectf(t,code==0,"%s",err)
    testing.expect_value(t,stored(masks),importer.Image_Use.Data)
    code,err=run(diffuse,"--out",out,"--uncompressed")
    testing.expectf(t,code==0,"%s",err)
    testing.expect_value(t,stored(diffuse),importer.Image_Use.Color)

    // Given once, the use stays: the name no longer decides.
    code,err=run(masks,"--out",out,"--uncompressed","--srgb")
    testing.expectf(t,code==0,"%s",err)
    code,err=run(masks,"--out",out,"--uncompressed")
    testing.expectf(t,code==0,"%s",err)
    testing.expect_value(t,stored(masks),importer.Image_Use.Color)

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
    folder:=temp_folder("old-skeleton")
    defer os.remove_all(folder)
    first,error:=import_source(FIXTURES+"skeletal-analytic.glb",folder,{textures=.Uncompressed,no_save=true})
    if !testing.expectf(t,error.code==.None,"%s",error.message) {return}
    defer importer.report_destroy(&first)
    skeleton:importer.Written
    for written in first.assets {if written.kind==asset.KIND_SKELETON {skeleton=written}}
    if !testing.expect(t,skeleton.path!="","the source has a skeleton") {return}
    data,_:=os.read_entire_file(skeleton.path,context.temp_allocator)
    old:=asset.SKELETON_VERSION-1
    data[10],data[11]=u8(old),u8(old>>8)
    testing.expect(t,os.write_entire_file(skeleton.path,data)==nil)
    again,failed:=import_source(FIXTURES+"skeletal-analytic.glb",folder,{textures=.Uncompressed,no_save=true})
    if !testing.expectf(t,failed.code==.None,"%s",failed.message) {return}
    defer importer.report_destroy(&again)
    told:=false
    for warning in again.warnings {told||=strings.contains(warning,"were not kept")}
    testing.expectf(t,told,"the import says what it dropped: %v",again.warnings)
    testing.expect_value(t,header_of(skeleton.path).id,skeleton.id)
    testing.expect_value(t,header_of(skeleton.path).kind_version,u16(asset.SKELETON_VERSION))
}
