package sources

import "core:c"
import "core:encoding/base64"
import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:testing"
import stbi "vendor:stb/image"
import "mirai:asset"
import importer "mirai:cook/import"
import "mirai:cook/import/gltf"
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
box_import :: proc(t:^testing.T,source,root:string) -> (report:importer.Import_Report,ok:bool) {
    error:importer.Error
    report,error=import_source(source,fmt.tprintf("%s/assets/models/box",root),{root=root,textures=.Uncompressed})
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

// What an import of a project builds that nobody edits is of its imported
// folder, at the path its sidecar lists; what the editor edits is of its
// assets, found by its id wherever it was moved.
@(test)
the_parts_of_an_import_name_its_prefab_and_keep_their_ids_where_they_were_moved :: proc(t:^testing.T) {
    root:=base.test_folder(t,"reimport-moved")
    if root=="" {return}
    os.make_directory_all(fmt.tprintf("%s/source",root))
    source:=box_source(fmt.tprintf("%s/source",root),"box.gltf","Wood","Paint")
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
        cached:=importer.kind_cached(written.kind)
        testing.expectf(t,strings.contains(written.path,cached?"/.mirai/imported/":"/assets/models/box/"),"%s: of the %s",written.path,cached?"imported folder":"assets")
    }
    sidecar,found,_:=importer.sidecar_load(fmt.tprintf("%s.import",source),context.temp_allocator)
    testing.expect(t,found && len(sidecar.outputs)==len(first.assets),"the sidecar next to the source lists what it gives")
    for output in sidecar.outputs {
        written,listed:=written_of(&first,output.kind,output.kind==asset.KIND_SCENE?"box":output.name)
        testing.expectf(t,listed && written.id==output.id && output.part==(output.kind==asset.KIND_MESH),"%s is listed with its id: %v",output.name,output)
    }
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

// The ids of an import are those its sidecar lists: a source moved, renamed
// or changed keeps them as long as its sidecar goes with it, and a copy of
// the source alone is another import.
@(test)
a_source_keeps_the_ids_of_its_import_with_its_sidecar_and_a_copy_without_it_is_another_import :: proc(t:^testing.T) {
    root:=base.test_folder(t,"reimport-renamed")
    if root=="" {return}
    os.make_directory_all(fmt.tprintf("%s/source/props",root))
    source:=box_source(fmt.tprintf("%s/source",root),"box.gltf","Wood","Paint")
    first,ok:=box_import(t,source,root);if !ok {return};defer importer.report_destroy(&first)

    // Moved, renamed and changed, with its sidecar.
    crate:=box_source(fmt.tprintf("%s/source/props",root),"crate.gltf","Wood","Paint","0.8")
    testing.expect(t,os.rename(fmt.tprintf("%s.import",source),fmt.tprintf("%s.import",crate))==nil && os.remove(source)==nil)
    moved,moved_ok:=box_import(t,crate,root);if !moved_ok {return};defer importer.report_destroy(&moved)
    testing.expect_value(t,moved.prefab,first.prefab)
    for written in first.assets {
        same,found:=written_of(&moved,written.kind,written.kind==asset.KIND_SCENE?"crate":written.name)
        testing.expectf(t,found && same.id==written.id && same.path==written.path,"%s keeps its id and its file",written.name)
    }
    testing.expect_value(t,len(moved.warnings),0)
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    prefab,_:=written_of(&moved,asset.KIND_SCENE,"crate")
    if a,loaded:=read_asset(t,prefab,&types);loaded {
        info,_:=asset.import_info(&a,&types)
        testing.expect(t,info!=nil && string_of(info.source[:])=="source/props/crate.gltf","the import names the source where it is now")
        asset.asset_close(&a)
    }

    // The same bytes without the sidecar: an import of its own, which takes nothing of the other.
    copy:=box_source(fmt.tprintf("%s/source",root),"copy.gltf","Wood","Paint","0.8")
    second,second_error:=import_source(copy,fmt.tprintf("%s/assets/models/copy",root),{root=root,textures=.Uncompressed})
    if !testing.expectf(t,second_error.code==.None,"%s",second_error.message) {return};defer importer.report_destroy(&second)
    testing.expect(t,second.prefab!={} && second.prefab!=first.prefab,"the copy writes a prefab of its own")
    for written in second.assets {
        if written.kind==asset.KIND_MESH || written.kind==asset.KIND_SCENE {
            for other in first.assets {testing.expectf(t,other.id!=written.id,"%s has an id of its own",written.path)}
        }
    }
}

@(test)
a_material_renamed_in_the_source_keeps_its_id_and_a_part_taken_out_is_left_alone :: proc(t:^testing.T) {
    root:=base.test_folder(t,"reimport-parts")
    if root=="" {return}
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

    // Whether a mesh is a part is decided once and kept in the sidecar: taken out there, it stays out.
    mesh,_:=written_of(&first,asset.KIND_MESH,"Box")
    testing.expect(t,header_of(mesh.path).owner==first.prefab)
    file:=fmt.tprintf("%s.import",source)
    listed,_:=os.read_entire_file(file,context.temp_allocator)
    taken_out,replaced:=strings.replace(string(listed),", \"part\": true","",1,context.temp_allocator)
    testing.expect(t,replaced && os.write_entire_file(file,taken_out)==nil)
    after,after_ok:=box_import(t,source,root);if !after_ok {return};defer importer.report_destroy(&after)
    box,has_box:=written_of(&after,asset.KIND_MESH,"Box")
    testing.expect(t,has_box && box.id==mesh.id && box.path==mesh.path)
    header:=header_of(mesh.path)
    testing.expect(t,header.owner=={} && .Cooked in header.flags,"the part taken out keeps its id and its import, and stays out of its owner")
    testing.expect_value(t,slot_materials(t,&after,&types),[2]base.Asset_Id{wood.id,paint.id})

    // Forced, every material and texture is a part.
    forced,forced_ok:=import_source(source,fmt.tprintf("%s/assets/models/box",root),{root=root,textures=.Uncompressed,parts=.All,ignore_stored=true})
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
    root:=base.test_folder(t,"parts-rule")
    if root=="" {return}
    folder:=fmt.tprintf("%s/source",root)
    atlas_images(folder)
    source:=atlas_source(folder,"props.gltf",{"atlas","waves","across","shared"})
    report,error:=import_source(source,fmt.tprintf("%s/assets/models/props",root),{root=root,textures=.Uncompressed})
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

@(test)
a_second_model_with_the_same_textures_takes_its_material_and_both_lose_it_as_a_part :: proc(t:^testing.T) {
    root:=base.test_folder(t,"parts-shared")
    if root=="" {return}
    atlas_images(fmt.tprintf("%s/source/first",root))
    atlas_images(fmt.tprintf("%s/source/second",root))
    first_source:=atlas_source(fmt.tprintf("%s/source/first",root),"crate.gltf",{"atlas","waves","across","shared"})
    first,error:=import_source(first_source,fmt.tprintf("%s/assets/crate",root),{root=root,textures=.Uncompressed})
    if !testing.expectf(t,error.code==.None,"%s",error.message) {return};defer importer.report_destroy(&first)
    atlas,_:=written_of(&first,asset.KIND_MATERIAL,"Atlas")
    texture,_:=written_of(&first,asset.KIND_TEXTURE,"atlas")
    testing.expect(t,header_of(atlas.path).owner==first.prefab && header_of(texture.path).owner==first.prefab)

    second_source:=atlas_source(fmt.tprintf("%s/source/second",root),"barrel.gltf",{"atlas","waves","across","shared"})
    second,second_error:=import_source(second_source,fmt.tprintf("%s/assets/barrel",root),{root=root,textures=.Uncompressed})
    if !testing.expectf(t,second_error.code==.None,"%s",second_error.message) {return};defer importer.report_destroy(&second)
    testing.expect_value(t,second.material_ids[0],atlas.id)
    testing.expect_value(t,second.image_ids[0],texture.id)
    _,wrote_material:=written_of(&second,asset.KIND_MATERIAL,"Atlas")
    _,wrote_texture:=written_of(&second,asset.KIND_TEXTURE,"atlas")
    testing.expect(t,!wrote_material && !wrote_texture,"what the project has is not written twice")
    testing.expect(t,header_of(atlas.path).owner=={} && header_of(texture.path).owner=={},"used by two models, they are parts of neither")
    mesh,_:=written_of(&first,asset.KIND_MESH,"Body")
    testing.expect_value(t,header_of(mesh.path).owner,first.prefab)
    // The sidecars keep it: the first import again leaves them out, and the second names them again.
    again,again_error:=import_source(first_source,"",{root=root})
    if !testing.expectf(t,again_error.code==.None,"%s",again_error.message) {return};defer importer.report_destroy(&again)
    testing.expect(t,header_of(atlas.path).owner=={} && header_of(texture.path).owner=={},"the first import keeps them out")
    named,named_error:=import_source(second_source,"",{root=root})
    if !testing.expectf(t,named_error.code==.None,"%s",named_error.message) {return};defer importer.report_destroy(&named)
    testing.expect(t,named.material_ids[0]==atlas.id && named.image_ids[0]==texture.id,"the second import names what it shares")
}

// The editor writes a texture Fast until the cook encodes it again: the
// next import of the editor with that image takes it as one written Final.
@(test)
a_second_model_imported_by_the_editor_takes_the_texture_the_first_wrote_fast :: proc(t:^testing.T) {
    root:=base.test_folder(t,"parts-shared-fast")
    if root=="" {return}
    os.make_directory_all(fmt.tprintf("%s/source/chair",root))
    os.make_directory_all(fmt.tprintf("%s/source/table",root))
    chair_source:=box_source(fmt.tprintf("%s/source/chair",root),"chair.gltf","Wood","Paint")
    table_source:=box_source(fmt.tprintf("%s/source/table",root),"table.gltf","Wood","Paint")
    chair,error:=import_source(chair_source,fmt.tprintf("%s/assets/chair",root),{root=root,fast_textures=true})
    if !testing.expectf(t,error.code==.None,"%s",error.message) {return};defer importer.report_destroy(&chair)
    texture,found:=written_of(&chair,asset.KIND_TEXTURE,"wood")
    if !testing.expect(t,found) {return}
    table,table_error:=import_source(table_source,fmt.tprintf("%s/assets/table",root),{root=root,fast_textures=true})
    if !testing.expectf(t,table_error.code==.None,"%s",table_error.message) {return};defer importer.report_destroy(&table)
    testing.expect_value(t,table.image_ids[0],texture.id)
    _,wrote:=written_of(&table,asset.KIND_TEXTURE,"wood")
    testing.expect(t,!wrote,"the image is not written twice")
}

@(test)
a_second_model_with_the_same_textures_and_other_values_writes_a_material_of_its_own :: proc(t:^testing.T) {
    root:=base.test_folder(t,"parts-shared-values")
    if root=="" {return}
    os.make_directory_all(fmt.tprintf("%s/source/chair",root))
    os.make_directory_all(fmt.tprintf("%s/source/table",root))
    chair_source:=box_source(fmt.tprintf("%s/source/chair",root),"chair.gltf","Wood","Paint",roughness="0.5")
    table_source:=box_source(fmt.tprintf("%s/source/table",root),"table.gltf","Wood","Paint",roughness="0.9")
    chair,error:=import_source(chair_source,fmt.tprintf("%s/assets/chair",root),{root=root,textures=.Uncompressed})
    if !testing.expectf(t,error.code==.None,"%s",error.message) {return};defer importer.report_destroy(&chair)
    table,table_error:=import_source(table_source,fmt.tprintf("%s/assets/table",root),{root=root,textures=.Uncompressed})
    if !testing.expectf(t,table_error.code==.None,"%s",table_error.message) {return};defer importer.report_destroy(&table)
    testing.expect_value(t,table.image_ids[0],chair.image_ids[0])
    testing.expect(t,table.material_ids[0]!=chair.material_ids[0],"a material the source gives other values is no material of another import")
    _,wrote:=written_of(&table,asset.KIND_MATERIAL,"Wood")
    testing.expect(t,wrote)
}

@(test)
an_image_imported_on_its_own_takes_no_texture_of_a_model_whose_source_moved :: proc(t:^testing.T) {
    root:=base.test_folder(t,"reimport-image-model")
    if root=="" {return}
    os.make_directory_all(fmt.tprintf("%s/source",root))
    source:=box_source(fmt.tprintf("%s/source",root),"box.gltf","Wood","Paint")
    first,ok:=box_import(t,source,root);if !ok {return};defer importer.report_destroy(&first)
    texture,found:=written_of(&first,asset.KIND_TEXTURE,"wood")
    if !testing.expect(t,found) {return}
    testing.expect_value(t,os.rename(source,fmt.tprintf("%s/source/moved.gltf.old",root)),nil)
    image,error:=import_source(fmt.tprintf("%s/source/wood.png",root),fmt.tprintf("%s/assets/textures",root),{root=root})
    if !testing.expectf(t,error.code==.None,"%s",error.message) {return};defer importer.report_destroy(&image)
    if !testing.expect_value(t,len(image.assets),1) {return}
    testing.expect(t,image.assets[0].id!=texture.id && image.assets[0].path!=texture.path,"the texture of the model stays its own")
    testing.expect_value(t,header_of(texture.path).id,texture.id)
}

// A checkout has the sources and their sidecars, and not what they build that
// nobody edits: sync builds that again, the same assets, whatever the order
// its sources come in, and builds nothing when nothing changed.
@(test)
a_checkout_without_its_imported_folder_gets_the_same_assets_from_its_sources :: proc(t:^testing.T) {
    root:=base.test_folder(t,"sync")
    if root=="" {return}
    // The second model in the order of a walk comes first by name, and shares the texture and the material of the other.
    atlas_images(fmt.tprintf("%s/source/set/crate",root))
    atlas_images(fmt.tprintf("%s/source/set/barrel",root))
    crate:=atlas_source(fmt.tprintf("%s/source/set/crate",root),"crate.gltf",{"atlas","waves","across","shared"})
    barrel:=atlas_source(fmt.tprintf("%s/source/set/barrel",root),"barrel.gltf",{"atlas","waves","across","shared"})
    _=os.write_entire_file(fmt.tprintf("%s/source/sign.png",root),png_bytes(8,8,{200,40,40}))
    sources:=[3]string{crate,barrel,fmt.tprintf("%s/source/sign.png",root)}
    Built :: struct {path:string,id:base.Asset_Id,bytes:[]u8}
    built:=make([dynamic]Built,context.temp_allocator)
    caches:=Sync_Options{texture_cache=fmt.tprintf("%s/cache/textures",root),mesh_cache=fmt.tprintf("%s/cache/meshes",root)}
    for source in sources {
        report,error:=import_source(source,"",{root=root,textures=.Uncompressed,texture_cache=caches.texture_cache,mesh_cache=caches.mesh_cache})
        if !testing.expectf(t,error.code==.None,"%s: %s",source,error.message) {return}
        for written in report.assets {append(&built,Built{path=strings.clone(written.path,context.temp_allocator),id=written.id})}
        importer.report_destroy(&report)
    }
    // The second model took parts out of the first, whose sidecar says so now: its import once more settles it.
    settled:=sync(root,caches,context.temp_allocator)
    testing.expectf(t,settled.sources==3 && len(settled.failures)==0,"%v",settled)
    for &file in built {file.bytes,_=os.read_entire_file(file.path,context.temp_allocator)}
    sidecars:[3]string
    for source,at in sources {
        text,_:=os.read_entire_file(fmt.tprintf("%s.import",source),context.temp_allocator)
        sidecars[at]=string(text)
    }
    imported:=fmt.tprintf("%s/.mirai/imported",root)
    cached:=0
    for file in built {cached+=int(strings.has_prefix(file.path,imported))}
    testing.expect(t,cached>0 && cached<len(built),"an import of a project writes to its imported folder and to its assets")

    // Up to date: nothing is imported.
    current:=sync(root,caches,context.temp_allocator)
    testing.expectf(t,current.sources==3 && current.imported==0 && current.removed==0 && len(current.failures)==0,"%v",current)

    // What a clone has: no imported folder.
    testing.expect(t,base.remove_all(fmt.tprintf("%s/.mirai",root))==nil)
    cloned:=sync(root,caches,context.temp_allocator)
    testing.expectf(t,cloned.sources==3 && cloned.imported==3 && len(cloned.failures)==0 && len(cloned.warnings)==0,"%v",cloned)
    for file in built {
        bytes,read_error:=os.read_entire_file(file.path,context.temp_allocator)
        testing.expectf(t,read_error==nil && header_of(file.path).id==file.id && slice.equal(bytes,file.bytes),"%s is the asset it was, byte for byte",file.path)
    }
    for source,at in sources {
        text,_:=os.read_entire_file(fmt.tprintf("%s.import",source),context.temp_allocator)
        testing.expectf(t,string(text)==sidecars[at],"the sidecar of %s is as it was",source)
    }
    again:=sync(root,caches,context.temp_allocator)
    testing.expectf(t,again.imported==0 && len(again.failures)==0,"%v",again)

    // The registry lists what the imported folder holds by where its source is now.
    Listed :: struct {id:base.Asset_Id,path:string}
    listing :: proc(t:^testing.T,root:string) -> (listed:[dynamic]Listed,missing:int) {
        r:asset.Registry
        asset.registry_init(&r,fmt.tprintf("%s/assets",root),imported=fmt.tprintf("%s/.mirai/imported",root))
        defer asset.registry_destroy(&r)
        testing.expect_value(t,asset.registry_scan(&r),asset.Error.None)
        listed=make([dynamic]Listed,context.temp_allocator)
        for file in r.files {
            if file.imported {append(&listed,Listed{file.id,strings.clone(file.path,context.temp_allocator)})}
        }
        lost:=make([dynamic]asset.Registry_Missing,context.temp_allocator)
        asset.registry_missing(&r,&lost)
        return listed,len(lost)
    }
    path_of :: proc(listed:[]Listed,path:string) -> (id:base.Asset_Id,found:bool) {
        for entry in listed {
            if entry.path==path {return entry.id,true}
        }
        return
    }
    before,missing:=listing(t,root)
    body,has_body:=path_of(before[:],"set/crate/crate.gltf/Body.mesh")
    keg,has_keg:=path_of(before[:],"set/barrel/barrel.gltf/Body.mesh")
    _,has_sign:=path_of(before[:],"sign.tex")
    testing.expectf(t,has_body && has_keg && has_sign && missing==0 && len(before)==cached,"a part in the folder of its source file, a root beside its source: %v",before[:])

    // A source that changed is imported again, and it alone.
    _=os.write_entire_file(fmt.tprintf("%s/source/sign.png",root),png_bytes(8,8,{40,40,200}))
    changed:=sync(root,caches,context.temp_allocator)
    testing.expectf(t,changed.imported==1 && len(changed.failures)==0,"%v",changed)

    // A folder with two sources moves, one of them is renamed and another source is deleted: until
    // they are imported again nothing stale is listed, and then every asset is listed where its
    // source is, with the id it had; what names them still finds them.
    testing.expect(t,os.rename(fmt.tprintf("%s/source/set",root),fmt.tprintf("%s/source/props",root))==nil)
    for end in ([2]string{"",".import"}) {testing.expect(t,os.rename(fmt.tprintf("%s/source/props/barrel/barrel.gltf%s",root,end),fmt.tprintf("%s/source/props/barrel/keg.gltf%s",root,end))==nil)}
    testing.expect(t,os.remove(fmt.tprintf("%s/source/sign.png",root))==nil)
    moved,_:=listing(t,root)
    testing.expectf(t,len(moved)==0,"an asset whose source is not where it says is not listed: %v",moved[:])
    again_synced:=sync(root,caches,context.temp_allocator)
    testing.expectf(t,again_synced.sources==2 && again_synced.imported==2 && again_synced.removed==1 && len(again_synced.failures)==0,"%v",again_synced)
    after,after_missing:=listing(t,root)
    moved_body,_:=path_of(after[:],"props/crate/crate.gltf/Body.mesh")
    moved_keg,_:=path_of(after[:],"props/barrel/keg.gltf/Body.mesh")
    testing.expectf(t,moved_body==body && moved_keg==keg && body!={} && keg!={} && after_missing==0 && len(after)==len(before)-1,"%v",after[:])
    for entry in after {
        testing.expectf(t,strings.has_prefix(entry.path,"props/"),"%s is listed where its source is",entry.path)
    }
}

// What cannot be imported again from the checkout alone has no cache: the
// assets of a source outside the project, and those of a format that is not
// the engine's, are all files of the assets folder, with their ids in a
// sidecar of the project all the same.
@(test)
an_import_that_a_checkout_cannot_repeat_keeps_every_asset_in_the_assets :: proc(t:^testing.T) {
    root:=base.test_folder(t,"sync-documents")
    if root=="" {return}
    outside:=fmt.tprintf("%s/downloads",root)
    project:=fmt.tprintf("%s/game",root)
    os.make_directory_all(outside)
    os.make_directory_all(fmt.tprintf("%s/source",project))
    probe_sniff :: proc(head:[]u8) -> importer.Sniff {return .Extension}
    probe:=gltf.FORMAT
    probe.name,probe.extensions,probe.sniff="Probe",{0=".probe"},probe_sniff
    of_plugin:=[1]importer.Format{probe}
    Case :: struct {source,folder,sidecar:string,formats:[]importer.Format}
    box:=box_source(outside,"box.gltf","Wood","Paint")
    cases:=[2]Case{
        {box,"models/box",fmt.tprintf("%s/source/box.gltf.import",project),nil},
        {box_source(fmt.tprintf("%s/source",project),"crate.probe","Wood","Paint"),"models/crate",fmt.tprintf("%s/source/crate.probe.import",project),of_plugin[:]},
    }
    for c in cases {
        formats:=c.formats
        folder:=fmt.tprintf("%s/assets/%s",project,c.folder)
        first,error:=import_source(c.source,folder,{root=project,textures=.Uncompressed,fast_textures=true},formats)
        if !testing.expectf(t,error.code==.None,"%s: %s",c.source,error.message) {continue}
        defer importer.report_destroy(&first)
        types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
        for written in first.assets {
            testing.expectf(t,strings.has_prefix(written.path,folder),"%s is a file of the assets",written.path)
            if written.kind!=asset.KIND_TEXTURE {continue}
            if a,loaded:=read_asset(t,written,&types);loaded {
                view,_:=asset.texture_view(&a,&types)
                testing.expectf(t,.Fast not_in view.info.flags,"%s is built Final: nothing builds it again later",written.path)
                asset.asset_close(&a)
            }
        }
        sidecar,found,_:=importer.sidecar_load(c.sidecar,context.temp_allocator)
        own:=0
        for output in sidecar.outputs {own+=int(!output.shared)}
        testing.expectf(t,found && own==len(first.assets),"%s lists its assets",c.sidecar)
        again,again_error:=import_source(c.source,folder,{root=project,textures=.Uncompressed},formats)
        if !testing.expectf(t,again_error.code==.None,"%s",again_error.message) {continue}
        defer importer.report_destroy(&again)
        for written in first.assets {
            same,kept:=written_of(&again,written.kind,written.name)
            testing.expectf(t,kept && same.id==written.id && same.path==written.path,"%s keeps its id and its file",written.path)
        }
    }
    testing.expect(t,!os.exists(fmt.tprintf("%s.import",box)),"nothing is written next to a source outside the project")
    // No source of the project has outputs of the cache: sync has nothing to build, and does not try the format it lacks.
    report:=sync(project,{texture_cache=fmt.tprintf("%s/cache/textures",root),mesh_cache=fmt.tprintf("%s/cache/meshes",root)},context.temp_allocator)
    testing.expectf(t,report.sources==0 && report.imported==0 && len(report.failures)==0,"%v",report)
}

// An image with no settings holds what its name says, from mirai import as
// from the editor: a packed mask is linear data, a photo a color. A use
// given once stays in its settings.
@(test)
an_image_on_its_own_holds_what_its_name_says_until_its_settings_say_otherwise :: proc(t:^testing.T) {
    root:=base.test_folder(t,"image-use")
    if root=="" {return}
    out:=fmt.tprintf("%s/textures",root)
    run :: proc(args:..string) -> (code:int,err:string) {
        output,errors:=strings.builder_make(context.temp_allocator),strings.builder_make(context.temp_allocator)
        code=command(args,strings.to_writer(&output),strings.to_writer(&errors))
        return code,strings.to_string(errors)
    }
    stored :: proc(source:string) -> importer.Image_Use {
        settings,_,_:=importer.settings_load(source,"",fmt.tprintf("%s/textures",filepath.dir(source)))
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
    folder:=base.test_folder(t,"old-skeleton")
    if folder=="" {return}
    first,error:=import_source(FIXTURES+"skeletal-analytic.glb",folder,{textures=.Uncompressed})
    if !testing.expectf(t,error.code==.None,"%s",error.message) {return}
    defer importer.report_destroy(&first)
    skeleton:importer.Written
    for written in first.assets {if written.kind==asset.KIND_SKELETON {skeleton=written}}
    if !testing.expect(t,skeleton.path!="","the source has a skeleton") {return}
    data,_:=os.read_entire_file(skeleton.path,context.temp_allocator)
    old:=asset.SKELETON_VERSION-1
    data[10],data[11]=u8(old),u8(old>>8)
    testing.expect(t,os.write_entire_file(skeleton.path,data)==nil)
    again,failed:=import_source(FIXTURES+"skeletal-analytic.glb",folder,{textures=.Uncompressed})
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
