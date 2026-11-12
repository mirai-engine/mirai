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
import importer "mirai:cook/import"
import "mirai:cook/prefab"
import "mirai:cook/import/gltf"
import "mirai:project"
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
    report,error=import_source(source,{world=prefab.import_world(t),root=root,textures=.Uncompressed})
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
// folder, named by its id; what the editor edits is of its assets, in the
// folder of the import beside the source, found by its id wherever it was
// moved.
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
        testing.expectf(t,strings.contains(written.path,cached?"/.mirai/imported/":"/assets/models/box/"),"%s: of the %s",written.path,cached?"imported folder":"assets")
    }
    sidecar,found,_:=importer.sidecar_load(source,context.temp_allocator)
    testing.expect(t,found && sidecar.folder=="box" && len(sidecar.outputs)==len(first.assets),"the sidecar next to the source lists what it gives and where")
    for output in sidecar.outputs {
        written,listed:=written_of(&first,output.kind,output.kind==asset.KIND_SCENE?"box":output.name)
        testing.expectf(t,listed && written.id==output.id && output.part==(output.kind==asset.KIND_MESH),"%s is listed with its id: %v",output.name,output)
    }
    a,loaded:=read_asset(t,prefab,&types)
    if loaded {
        info,error:=asset.import_info(&a,&types)
        testing.expect(t,error==.None && info!=nil && string_of(info.source[:])=="assets/models/box.gltf" && .Cooked in a.blob.header.flags,"the prefab records its import")
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

// The ids of an import are those its sidecar lists: a source moved, renamed
// or changed keeps them as long as its sidecar goes with it, and a copy of
// the source alone is another import.
@(test)
a_source_keeps_the_ids_of_its_import_with_its_sidecar_and_a_copy_without_it_is_another_import :: proc(t:^testing.T) {
    root,assets:=test_project(t,"reimport-renamed")
    if root=="" {return}
    os.make_directory_all(fmt.tprintf("%s/props",assets))
    source:=box_source(assets,"box.gltf","Wood","Paint")
    first,ok:=box_import(t,source,root);if !ok {return};defer importer.report_destroy(&first)

    // Moved, renamed and changed, with its sidecar.
    crate:=box_source(fmt.tprintf("%s/props",assets),"crate.gltf","Wood","Paint","0.8")
    testing.expect(t,os.rename(fmt.tprintf("%s.import",source),fmt.tprintf("%s.import",crate))==nil && os.remove(source)==nil)
    moved,moved_ok:=box_import(t,crate,root);if !moved_ok {return};defer importer.report_destroy(&moved)
    testing.expect_value(t,moved.prefab,first.prefab)
    for written in first.assets {
        same,found:=written_of(&moved,written.kind,written.kind==asset.KIND_SCENE?"crate":written.name)
        // A file of the imported folder is named by what it is built from, which changed.
        testing.expectf(t,found && same.id==written.id && (same.path==written.path || asset.import_cached(written.kind)),"%s keeps its id and its file",written.name)
    }
    testing.expect_value(t,len(moved.warnings),0)
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    scene,_:=written_of(&moved,asset.KIND_SCENE,"crate")
    if a,loaded:=read_asset(t,scene,&types);loaded {
        info,_:=asset.import_info(&a,&types)
        testing.expect(t,info!=nil && string_of(info.source[:])=="assets/props/crate.gltf","the import names the source where it is now")
        asset.asset_close(&a)
    }

    // The same bytes without the sidecar: an import of its own, which takes nothing of the other.
    copy:=box_source(assets,"copy.gltf","Wood","Paint","0.8")
    second,second_error:=import_source(copy,{world=prefab.import_world(t),root=root,textures=.Uncompressed})
    if !testing.expectf(t,second_error.code==.None,"%s",second_error.message) {return};defer importer.report_destroy(&second)
    testing.expect(t,second.prefab!={} && second.prefab!=first.prefab,"the copy writes a prefab of its own")
    for written in second.assets {
        for other in first.assets {testing.expectf(t,other.id!=written.id,"%s has an id of its own",written.path)}
    }
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

    // Whether a mesh is a part is decided once and kept in the sidecar: taken out there, it stays out.
    mesh,_:=written_of(&renamed,asset.KIND_MESH,"Box")
    testing.expect(t,header_of(mesh.path).owner==first.prefab)
    file:=fmt.tprintf("%s.import",source)
    listed,_:=os.read_entire_file(file,context.temp_allocator)
    taken_out,replaced:=strings.replace(string(listed),", \"part\": true","",1,context.temp_allocator)
    testing.expect(t,replaced && os.write_entire_file(file,taken_out)==nil)
    after,after_ok:=box_import(t,source,root);if !after_ok {return};defer importer.report_destroy(&after)
    box,has_box:=written_of(&after,asset.KIND_MESH,"Box")
    testing.expect(t,has_box && box.id==mesh.id)
    header:=header_of(box.path)
    testing.expect(t,header.owner=={} && .Cooked in header.flags,"the part taken out keeps its id and its import, and stays out of its owner")

    // Forced, every material and texture is a part.
    forced,forced_ok:=import_source(source,{world=prefab.import_world(t),root=root,textures=.Uncompressed,parts=.All,ignore_stored=true})
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
    report,error:=import_source(source,{world=prefab.import_world(t),root=root,textures=.Uncompressed})
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
// file or a sidecar of the other, and each keeps its atlas as a part.
@(test)
two_models_with_the_same_image_get_a_texture_each_and_neither_touches_the_other :: proc(t:^testing.T) {
    root,assets:=test_project(t,"parts-two-models")
    if root=="" {return}
    atlas_images(fmt.tprintf("%s/first",assets))
    atlas_images(fmt.tprintf("%s/second",assets))
    cache:=fmt.tprintf("%s/cache/textures",root)
    first_source:=atlas_source(fmt.tprintf("%s/first",assets),"crate.gltf",{"atlas","waves","across","shared"})
    first,error:=import_source(first_source,{world=prefab.import_world(t),root=root,texture_cache=cache})
    if !testing.expectf(t,error.code==.None,"%s",error.message) {return};defer importer.report_destroy(&first)
    atlas,_:=written_of(&first,asset.KIND_MATERIAL,"Atlas")
    texture,_:=written_of(&first,asset.KIND_TEXTURE,"atlas")
    testing.expect(t,header_of(atlas.path).owner==first.prefab && header_of(texture.path).owner==first.prefab)
    Kept :: struct {path:string,bytes:[]u8}
    kept:=make([dynamic]Kept,context.temp_allocator)
    sidecar:=fmt.tprintf("%s.import",first_source)
    sidecar_bytes,_:=os.read_entire_file(sidecar,context.temp_allocator)
    append(&kept,Kept{sidecar,sidecar_bytes})
    for written in first.assets {
        bytes,_:=os.read_entire_file(written.path,context.temp_allocator)
        append(&kept,Kept{written.path,bytes})
    }
    cached,_:=os.read_all_directory_by_path(cache,context.temp_allocator)

    second_source:=atlas_source(fmt.tprintf("%s/second",assets),"barrel.gltf",{"atlas","waves","across","shared"})
    second,second_error:=import_source(second_source,{world=prefab.import_world(t),root=root,texture_cache=cache})
    if !testing.expectf(t,second_error.code==.None,"%s",second_error.message) {return};defer importer.report_destroy(&second)
    second_atlas,wrote_material:=written_of(&second,asset.KIND_MATERIAL,"Atlas")
    second_texture,wrote_texture:=written_of(&second,asset.KIND_TEXTURE,"atlas")
    testing.expect(t,wrote_material && wrote_texture && second_atlas.id!=atlas.id && second_texture.id!=texture.id,"each model names a texture and a material of its own")
    testing.expect(t,header_of(second_atlas.path).owner==second.prefab && header_of(second_texture.path).owner==second.prefab,"and each keeps them as its parts")
    for file in kept {
        bytes,_:=os.read_entire_file(file.path,context.temp_allocator)
        testing.expectf(t,slice.equal(bytes,file.bytes),"%s is as the first import left it",file.path)
    }
    again,_:=os.read_all_directory_by_path(cache,context.temp_allocator)
    testing.expectf(t,len(again)==len(cached),"the images are encoded once: %d entries of the cache, then %d",len(cached),len(again))
}

// A checkout has the sources and their sidecars, and not what they build that
// nobody edits: sync builds that again, the same assets, whatever the order
// its sources come in, and builds nothing when nothing changed.
@(test)
a_checkout_without_its_imported_folder_gets_the_same_assets_from_its_sources :: proc(t:^testing.T) {
    root,assets:=test_project(t,"sync")
    if root=="" {return}
    atlas_images(fmt.tprintf("%s/set/crate",assets))
    atlas_images(fmt.tprintf("%s/set/barrel",assets))
    crate:=atlas_source(fmt.tprintf("%s/set/crate",assets),"crate.gltf",{"atlas","waves","across","shared"})
    barrel:=atlas_source(fmt.tprintf("%s/set/barrel",assets),"barrel.gltf",{"atlas","waves","across","shared"})
    _=os.write_entire_file(fmt.tprintf("%s/sign.png",assets),png_bytes(8,8,{200,40,40}))
    sources:=[3]string{crate,barrel,fmt.tprintf("%s/sign.png",assets)}
    Built :: struct {path:string,id:base.Asset_Id,bytes:[]u8}
    built:=make([dynamic]Built,context.temp_allocator)
    caches:=Sync_Options{texture_cache=fmt.tprintf("%s/cache/textures",root),mesh_cache=fmt.tprintf("%s/cache/meshes",root),library=test_library}
    context.user_ptr=prefab.import_world(t)
    for source in sources {
        report,error:=import_source(source,{world=prefab.import_world(t),root=root,textures=.Uncompressed,texture_cache=caches.texture_cache,mesh_cache=caches.mesh_cache})
        if !testing.expectf(t,error.code==.None,"%s: %s",source,error.message) {return}
        for written in report.assets {append(&built,Built{path=strings.clone(written.path,context.temp_allocator),id=written.id})}
        importer.report_destroy(&report)
    }
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

    // A source settled on disk is hashed once: the next build takes its hash from the cache of
    // the root without reading it, so a hash the cache says gives another key.
    sign:=fmt.tprintf("%s/sign.png",assets)
    an_hour_ago:=time.time_add(time.now(),-time.Hour)
    testing.expect(t,os.change_times(sign,an_hour_ago,an_hour_ago)==nil)
    testing.expect_value(t,sync(root,caches,context.temp_allocator).imported,0)
    memo:=project.cache_path(root,importer.SOURCE_HASHES,allocator=context.temp_allocator)
    hashes:=importer.source_hashes_load(memo,context.temp_allocator)
    remembered:=""
    for file in hashes.files {
        if strings.has_suffix(file,"/sign.png") {remembered=file}
    }
    if !testing.expectf(t,remembered!="","%v",hashes.files) {return}
    known:=hashes.files[remembered]
    hashes.files[remembered]={known.size,known.modified,known.hash+1}
    hashes.changed=true
    importer.source_hashes_save(&hashes,memo)
    testing.expect_value(t,sync(root,caches,context.temp_allocator).imported,1)
    // Without the cache the bytes decide again.
    testing.expect(t,os.remove(memo)==nil)
    testing.expect_value(t,sync(root,caches,context.temp_allocator).imported,1)

    // The registry lists what the imported folder holds by where its source is now.
    Listed :: struct {id:base.Asset_Id,path:string}
    listing :: proc(t:^testing.T,root:string) -> (listed:[dynamic]Listed,missing:int) {
        r:asset.Registry
        asset.registry_init(&r,fmt.tprintf("%s/assets",root),imported=fmt.tprintf("%s/.mirai/imported",root))
        defer asset.registry_destroy(&r)
        testing.expect_value(t,asset.registry_scan(&r),asset.Error.None)
        listed=make([dynamic]Listed,context.temp_allocator)
        for file in r.files {
            if file.imported!=0 {append(&listed,Listed{file.id,strings.clone(file.path,context.temp_allocator)})}
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
    body,has_body:=path_of(before[:],"set/crate/crate/Body.mesh")
    keg,has_keg:=path_of(before[:],"set/barrel/barrel/Body.mesh")
    atlas,has_atlas:=path_of(before[:],"set/crate/crate/atlas.tex")
    _,has_sign:=path_of(before[:],"sign.tex")
    testing.expectf(t,has_body && has_keg && has_atlas && has_sign && missing==0 && len(before)==cached,"what an import gives with its documents, the texture of an image beside it: %v",before[:])

    // A source that changed is imported again, and it alone; a file it reads counts as the source.
    _=os.write_entire_file(fmt.tprintf("%s/sign.png",assets),png_bytes(8,8,{40,40,200}))
    changed:=sync(root,caches,context.temp_allocator)
    testing.expectf(t,changed.imported==1 && len(changed.failures)==0,"%v",changed)
    _=os.write_entire_file(fmt.tprintf("%s/set/crate/across.png",assets),png_pixels(64,64,gradient_green))
    read:=sync(root,caches,context.temp_allocator)
    testing.expectf(t,read.imported==1 && len(read.failures)==0,"an image a model reads changed: %v",read)

    // A folder with two sources moves, one of them is renamed and another source is deleted: at
    // once, without an import, every asset is listed where its source is, with the id it had,
    // what names them still finds them and nothing of the deleted source is listed.
    testing.expect(t,os.rename(fmt.tprintf("%s/set",assets),fmt.tprintf("%s/props",assets))==nil)
    for end in ([2]string{"",".import"}) {testing.expect(t,os.rename(fmt.tprintf("%s/props/barrel/barrel.gltf%s",assets,end),fmt.tprintf("%s/props/barrel/keg.gltf%s",assets,end))==nil)}
    testing.expect(t,os.remove(fmt.tprintf("%s/sign.png",assets))==nil)
    after,after_missing:=listing(t,root)
    moved_body,_:=path_of(after[:],"props/crate/crate/Body.mesh")
    moved_keg,_:=path_of(after[:],"props/barrel/barrel/Body.mesh")
    moved_atlas,_:=path_of(after[:],"props/crate/crate/atlas.tex")
    testing.expectf(t,moved_body==body && moved_keg==keg && moved_atlas==atlas && body!={} && keg!={} && after_missing==0 && len(after)==len(before)-1,"%v",after[:])
    for entry in after {testing.expectf(t,strings.has_prefix(entry.path,"props/"),"%s is listed where its source is",entry.path)}
    // Nothing changed in what they are built from: the next build imports nothing, and removes what the deleted source gave.
    again_synced:=sync(root,caches,context.temp_allocator)
    testing.expectf(t,again_synced.sources==2 && again_synced.imported==0 && again_synced.removed==1 && len(again_synced.failures)==0,"%v",again_synced)
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

// Every import goes to the cache, whatever reads it: a format a plugin adds
// too, which sync reads again from the plugins of the project, and a source
// outside the assets is refused, saying where it goes.
@(test)
the_sources_of_a_plugin_format_build_in_the_cache_and_a_source_outside_the_assets_is_refused :: proc(t:^testing.T) {
    root:=base.test_folder(t,"sync-plugin")
    if root=="" {return}
    outside:=fmt.tprintf("%s/downloads",root)
    project:=fmt.tprintf("%s/game",root)
    os.make_directory_all(outside)
    os.make_directory_all(fmt.tprintf("%s/assets",project))
    box:=box_source(outside,"box.gltf","Wood","Paint")
    _,refused:=import_source(box,{world=prefab.import_world(t),root=project,textures=.Uncompressed})
    testing.expect(t,refused.code==.Not_Found && strings.contains(refused.message,"assets") && !os.exists(fmt.tprintf("%s.import",box)),refused.message)

    formats:=make([dynamic]importer.Format,context.temp_allocator)
    append(&formats,..FORMATS[:])
    append(&formats,probe_format())
    crate:=box_source(fmt.tprintf("%s/assets",project),"crate.probe","Wood","Paint")
    text,_:=os.read_entire_file(crate,context.temp_allocator)
    _=os.write_entire_file(crate,transmute([]u8)strings.concatenate({PROBE_MAGIC,string(text)},context.temp_allocator))
    first,error:=import_source(crate,{world=prefab.import_world(t),root=project,textures=.Uncompressed},formats[:])
    if !testing.expectf(t,error.code==.None,"%s",error.message) {return};defer importer.report_destroy(&first)
    mesh,has_mesh:=written_of(&first,asset.KIND_MESH,"Box")
    testing.expect(t,has_mesh && strings.contains(mesh.path,"/.mirai/imported/"),"what a plugin format gives that nobody edits is of the cache")
    // A clone: sync builds it again with the formats of the plugins, and says so without them.
    caches:=Sync_Options{texture_cache=fmt.tprintf("%s/cache/textures",root),mesh_cache=fmt.tprintf("%s/cache/meshes",root)}
    testing.expect(t,base.remove_all(fmt.tprintf("%s/.mirai",project))==nil)
    lacking:=sync(project,caches,context.temp_allocator)
    testing.expectf(t,len(lacking.failures)==1 && strings.contains(lacking.failures[0],"no format"),"%v",lacking)
    context.user_ptr=prefab.import_world(t)
    caches.library=proc(root:string,allocator:mem.Allocator) -> Library_Imports {
        listed:=make([]importer.Format,1,allocator)
        listed[0]=probe_format()
        return {formats=listed,world=(^core.World_Info)(context.user_ptr)}
    }
    synced:=sync(project,caches,context.temp_allocator)
    testing.expectf(t,synced.sources==1 && synced.imported==1 && len(synced.failures)==0,"%v",synced)
    testing.expect(t,os.exists(mesh.path),"the mesh is built again where it was")
}

// A source a plugin imports whole: "LEVEL <file>", a level of the glTF at
// that file beside it, which it reads and writes as a model of its import,
// and with kit a document of the kind KIT of that version. code: the
// identity of the code of its plugin.
@(private="file") Level_Importer :: struct {runs:int,code:u64,kit:u16}
@(private="file") KIT :: asset.Fourcc(u32('K')|u32('I')<<8|u32('T')<<16|u32('S')<<24)
@(private="file")
level_claims :: proc(path:string,head:[]u8) -> bool {return strings.has_prefix(string(head),"LEVEL ")}
@(private="file")
level_run :: proc(state:rawptr,source:string,options:importer.Import_Options,allocator:mem.Allocator) -> (report:importer.Import_Report,scene:string,error:importer.Error) {
    (^Level_Importer)(state).runs+=1
    bytes,_:=os.read_entire_file(source,context.temp_allocator)
    model_path:=fmt.tprintf("%s/%s",filepath.dir(source),string(bytes[len("LEVEL "):]))
    o:importer.Outputs
    if error=importer.outputs_begin(&o,source,"",u64(len(bytes)),base.hash64(bytes),importer.import_version(0),options,allocator);error.code!=.None {return}
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
        importer.output_written(&o,id,KIT,"hall",path,false)
    }
    return importer.outputs_end(&o,error.code!=.None),"",error
}

// Sync runs the importer of a plugin that claims a whole source when what it
// is built from changes: its bytes or those of a file it reads, the code of
// the plugin, or the version of a kind of document it wrote, of the engine or
// of a plugin; it leaves a current one alone.
@(test)
sync_imports_again_a_whole_source_when_what_it_is_built_from_changes :: proc(t:^testing.T) {
    root,assets:=test_project(t,"sync-whole")
    if root=="" {return}
    write_text(root,project.PROJECT_FILE,`{"name": "Hall", "version": "0.1.0"}`)
    os.make_directory_all(fmt.tprintf("%s/plugins/kit",root))
    kit_manifest :: proc(root:string,version:int) {write_text(fmt.tprintf("%s/plugins/kit",root),project.PLUGIN_FILE,strings.concatenate({`{"name": "kit", "version": "1.0.0", "asset_kinds": [{"extension": ".kit", "kind": "KITS", "version": `,fmt.tprint(version),`}]}`},context.temp_allocator))}
    kit_manifest(root,2)
    props:=fmt.tprintf("%s/props",assets)
    os.make_directory_all(props)
    box_source(props,"crate.gltf","Wood","Paint")
    level:=write_text(assets,"hall.level","LEVEL props/crate.gltf")
    state:=Level_Importer{kit=2}
    wholes:=[1]Whole_Source{{claims=level_claims,run=level_run,state=&state}}
    caches:=Sync_Options{texture_cache=fmt.tprintf("%s/cache/textures",root),mesh_cache=fmt.tprintf("%s/cache/meshes",root)}
    first,error:=import_source(level,{root=root,textures=.Uncompressed,texture_cache=caches.texture_cache,mesh_cache=caches.mesh_cache},wholes=wholes[:])
    if !testing.expectf(t,error.code==.None,"%s",error.message) {return}
    defer importer.report_destroy(&first)
    mesh,has_mesh:=written_of(&first,asset.KIND_MESH,"Box")
    testing.expect(t,has_mesh && strings.contains(mesh.path,"/.mirai/imported/"),"the mesh of the level is of the cache")
    sidecar,_,_:=importer.sidecar_load(level,context.temp_allocator)
    testing.expectf(t,slice.contains(sidecar.inputs[:],"props/crate.gltf") && slice.contains(sidecar.inputs[:],"props/wood.png"),"the files it reads are its inputs: %v",sidecar.inputs)

    lacking:=sync(root,caches,context.temp_allocator)
    testing.expectf(t,len(lacking.failures)==1 && strings.contains(lacking.failures[0],"no format or importer"),"%v",lacking)
    context.user_ptr=&state
    caches.library=proc(root:string,allocator:mem.Allocator) -> Library_Imports {
        wholes:=make([]Whole_Source,1,allocator)
        wholes[0]={claims=level_claims,run=level_run,state=context.user_ptr,code=(^Level_Importer)(context.user_ptr).code}
        return {wholes=wholes}
    }
    current:=sync(root,caches,context.temp_allocator)
    testing.expectf(t,current.sources==1 && current.imported==0 && len(current.failures)==0 && state.runs==1,"a current source is left alone: %v",current)
    Change :: enum {Input,Code,Engine_Kind,Plugin_Kind,Clone}
    material,has_material:=written_of(&first,asset.KIND_MATERIAL,"Wood")
    kit,has_kit:=written_of(&first,KIT,"hall")
    if !testing.expect(t,has_material && has_kit,"the level wrote documents") {return}
    for change in Change {
        switch change {
        case .Input: _=os.write_entire_file(fmt.tprintf("%s/wood.png",props),png_bytes(4,4,{20,90,200}))
        case .Code: state.code=7
        case .Engine_Kind:
            data,_:=os.read_entire_file(material.path,context.temp_allocator)
            old:=asset.MATERIAL_VERSION-1
            data[10],data[11]=u8(old),u8(old>>8)
            testing.expect(t,os.write_entire_file(material.path,data)==nil)
        case .Plugin_Kind:
            kit_manifest(root,3)
            state.kit=3
        case .Clone: testing.expect(t,base.remove_all(fmt.tprintf("%s/.mirai",root))==nil)
        }
        runs:=state.runs
        changed:=sync(root,caches,context.temp_allocator)
        testing.expectf(t,changed.imported==1 && len(changed.failures)==0 && state.runs==runs+1,"%v: %v",change,changed)
        testing.expectf(t,sync(root,caches,context.temp_allocator).imported==0,"%v: then nothing",change)
    }
    testing.expect(t,header_of(material.path).kind_version==asset.MATERIAL_VERSION && header_of(material.path).id==material.id,"the material is of this version again, with its id")
    testing.expect(t,header_of(kit.path).kind_version==3 && header_of(kit.path).id==kit.id,"the document of the plugin is of its version again, with its id")
    again,_,_:=importer.sidecar_load(level,context.temp_allocator)
    testing.expect(t,len(again.outputs)==len(sidecar.outputs) && again.outputs[0].id==sidecar.outputs[0].id,"the level keeps its assets")
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
    _,assets:=test_project(t,"image-use")
    if assets=="" {return}
    run :: proc(args:..string) -> (code:int,err:string) {
        output,errors:=strings.builder_make(context.temp_allocator),strings.builder_make(context.temp_allocator)
        code=command(args,strings.to_writer(&output),strings.to_writer(&errors))
        return code,strings.to_string(errors)
    }
    stored :: proc(source:string) -> importer.Image_Use {
        settings,_,_:=importer.settings_load(source)
        return settings.image
    }
    masks:=fmt.tprintf("%s/T_Katana_SpecularMasks.png",assets)
    diffuse:=fmt.tprintf("%s/T_Katana_Diffuse.png",assets)
    for path in ([?]string{masks,diffuse}) {_=os.write_entire_file(path,png_bytes(4,4,{10,200,30}))}

    code,err:=run(masks,"--uncompressed")
    testing.expectf(t,code==0,"%s",err)
    testing.expect_value(t,stored(masks),importer.Image_Use.Data)
    code,err=run(diffuse,"--uncompressed")
    testing.expectf(t,code==0,"%s",err)
    testing.expect_value(t,stored(diffuse),importer.Image_Use.Color)

    // Given once, the use stays: the name no longer decides.
    code,err=run(masks,"--uncompressed","--srgb")
    testing.expectf(t,code==0,"%s",err)
    code,err=run(masks,"--uncompressed")
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
    root,folder:=test_project(t,"old-skeleton")
    if folder=="" {return}
    source:=copy_in(root,FIXTURES,"skeletal-analytic.glb")
    first,error:=import_source(source,{world=prefab.import_world(t),textures=.Uncompressed})
    if !testing.expectf(t,error.code==.None,"%s",error.message) {return}
    defer importer.report_destroy(&first)
    skeleton:importer.Written
    for written in first.assets {if written.kind==asset.KIND_SKELETON {skeleton=written}}
    if !testing.expect(t,skeleton.path!="","the source has a skeleton") {return}
    data,_:=os.read_entire_file(skeleton.path,context.temp_allocator)
    old:=asset.SKELETON_VERSION-1
    data[10],data[11]=u8(old),u8(old>>8)
    testing.expect(t,os.write_entire_file(skeleton.path,data)==nil)
    again,failed:=import_source(source,{world=prefab.import_world(t),textures=.Uncompressed})
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
