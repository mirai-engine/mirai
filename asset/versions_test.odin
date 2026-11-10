package asset

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "mirai:std/base"

// The kind_version of a file, changed in place: the header is outside its content hash.
@(private="file")
version_set :: proc(path:string,version:u16) -> bool {
    data,error:=os.read_entire_file(path,context.temp_allocator)
    if error!=nil || len(data)<HEADER_SIZE {return false}
    data[10],data[11]=u8(version),u8(version>>8)
    return os.write_entire_file(path,data)==nil
}

// root/assets/models/box.obj/Box.mesh, of the version before this build's,
// imported from root/source/models/box.obj.
@(private="file")
stale_mesh :: proc(t:^testing.T,types:^Types,root:string) -> (path:string,ok:bool) {
    os.make_directory_all(fmt.tprintf("%s/source/models",root))
    os.make_directory_all(fmt.tprintf("%s/assets/models/box.obj",root))
    _=os.write_entire_file(fmt.tprintf("%s/source/models/box.obj",root),"v 0 0 0\n")
    vertices,indices:=test_grid(1);defer delete(vertices);defer delete(indices)
    source:Import_Info
    text_set(source.source[:],"source/models/box.obj")
    text_set(source.name[:],"Box")
    text_set(source.importer[:],"mirai-import")
    path=fmt.tprintf("%s/assets/models/box.obj/Box.mesh",root)
    if !testing.expect_value(t,mesh_save(path,types,{id={1,2},geometry=test_geometry(vertices,indices),source=&source}),Error.None) {return}
    return path,testing.expect(t,version_set(path,MESH_VERSION-1))
}

@(test)
an_asset_of_another_version_says_which_it_is_and_how_to_import_it_again :: proc(t:^testing.T) {
    types:Types;types_init(&types);defer types_destroy(&types)
    root:=base.test_folder(t,"versions")
    path,ok:=stale_mesh(t,&types,root)
    if !ok {return}

    a:Asset
    if !testing.expect_value(t,asset_load(&a,path),Error.None) {return}
    defer asset_close(&a)
    _,view_error:=mesh_view(&a,&types)
    testing.expect_value(t,view_error,Error.Version)
    message:=version_message(&a,&types,path,allocator=context.temp_allocator)
    wanted:=fmt.tprintf("mirai import %s/source/models/box.obj --out %s/assets/models/box.obj --root %s",root,root,root)
    testing.expect(t,strings.has_prefix(message,path) && strings.contains(message,fmt.tprintf("a mesh of version %d",MESH_VERSION-1)) && strings.contains(message,wanted),message)

    // An asset nobody imported is named, with nothing to import; an older one says to make it
    // again, and a newer one, to open it with a newer engine.
    material:=fmt.tprintf("%s/assets/Paint.mat",root)
    if !testing.expect_value(t,material_save(material,&types,{id={3,4},info=MATERIAL_DEFAULTS}),Error.None) {return}
    if !testing.expect(t,version_set(material,MATERIAL_VERSION+1)) {return}
    b:Asset
    if !testing.expect_value(t,asset_load(&b,material),Error.None) {return}
    defer asset_close(&b)
    _,material_error:=material_view(&b,&types)
    testing.expect_value(t,material_error,Error.Version)
    told:=version_message(&b,&types,material,allocator=context.temp_allocator)
    testing.expect(t,strings.contains(told,"a material of version") && strings.contains(told,"newer engine") && !strings.contains(told,"mirai import"),told)
    b.blob.header.kind_version=0
    told=version_message(&b,&types,material,allocator=context.temp_allocator)
    testing.expect(t,strings.contains(told,"a material of version 0, older than") && strings.contains(told,"it was not imported: make it again"),told)

    // A kind reads the version it writes and no other, the engine's and a plugin's alike.
    testing.expect_value(t,kind_check(&a,KIND_MESH,MESH_VERSION-1),Error.None)
    testing.expect_value(t,kind_check(&a,KIND_MESH,MESH_VERSION),Error.Version)
    testing.expect_value(t,kind_check(&a,KIND_MESH,MESH_VERSION-2),Error.Version)
    testing.expect_value(t,kind_check(&a,KIND_MATERIAL,MESH_VERSION-1),Error.Invalid)
    for info in KINDS {
        testing.expectf(t,info.version>0,"%s has the version it reads",info.name)
    }
    b.blob.header.kind=Fourcc(u32('G')|u32('R')<<8|u32('W')<<16|u32('N')<<24)
    told=version_message(&b,&types,"grown.grw",2,context.temp_allocator)
    testing.expect(t,strings.contains(told,"of version 0, older than this build reads (version 2)") && strings.contains(told,"make it again"),told)
    b.blob.header.kind_version=3
    told=version_message(&b,&types,"grown.grw",2,context.temp_allocator)
    testing.expect(t,strings.contains(told,"newer than this build") && strings.contains(told,"newer engine"),told)
}

// A row of a kind holds every field of its version: a file that does not
// store one is refused, and told with the field and how to make it again.
@(test)
a_row_that_lacks_a_field_of_its_kind_is_refused :: proc(t:^testing.T) {
    Old_Material :: struct {base_color:[3]f64,roughness:f32}
    Old_Texture :: struct {width,height,mip_count:u32,format:Texture_Format,flags:Texture_Flags,alpha_coverage:f32}
    Old_Sound_Set :: struct {volume_min,volume_max:f32}
    types:Types;types_init(&types);defer types_destroy(&types)
    Case :: struct {kind:Fourcc,version:u16,table,lacking:string}
    for c in ([3]Case{{KIND_MATERIAL,MATERIAL_VERSION,"material","opacity"},{KIND_TEXTURE,TEXTURE_VERSION,"texture","layers"},{KIND_SOUND_SET,SOUND_SET_VERSION,"sound_set","sounds"}}) {
        doc:Document;document_init(&doc,c.kind,{4,4});defer document_destroy(&doc)
        doc.kind_version=c.version
        put:Error
        switch c.kind {
        case KIND_MATERIAL: _,put=document_put_row(&doc,&types,c.table,&Old_Material{base_color={0.5,0.25,1},roughness=0.2})
        case KIND_TEXTURE: _,put=document_put_row(&doc,&types,c.table,&Old_Texture{width=2,height=1,mip_count=1})
        case KIND_SOUND_SET: _,put=document_put_row(&doc,&types,c.table,&Old_Sound_Set{1,1})
        }
        bytes,written:=document_bytes(&doc,context.temp_allocator)
        a:Asset
        if !testing.expect(t,put==.None && written==.None && asset_open(&a,bytes,context.temp_allocator)==.None,c.table) {continue}
        defer asset_close(&a)
        read:Error
        switch c.kind {
        case KIND_MATERIAL: _,read=material_view(&a,&types)
        case KIND_TEXTURE: _,read=texture_open(&a,&types)
        case KIND_SOUND_SET: _,read=sound_set_view(&a,&types)
        }
        testing.expect_value(t,read,Error.Version)
        told:=version_message(&a,&types,"old.asset",allocator=context.temp_allocator)
        testing.expect(t,strings.contains(told,c.table) && strings.contains(told,c.lacking) && strings.contains(told,"make it again"),told)
    }
}

@(test)
an_asset_of_another_version_named_by_a_relative_path_says_how_to_import_it_again :: proc(t:^testing.T) {
    types:Types;types_init(&types);defer types_destroy(&types)
    root:=base.test_folder(t,"versions_relative")
    path,ok:=stale_mesh(t,&types,root)
    if !ok {return}
    a:Asset
    if !testing.expect_value(t,asset_load(&a,path),Error.None) {return}
    defer asset_close(&a)

    // The folders above a relative path are the ones of its own, then "." once.
    working,_:=os.get_working_directory(context.temp_allocator)
    if relative,error:=filepath.rel(working,root,context.temp_allocator);error==.None {
        relative,_=strings.replace_all(relative,"\\","/",context.temp_allocator)
        named:=fmt.tprintf("%s/assets/models/box.obj/Box.mesh",relative)
        found:=version_message(&a,&types,named,allocator=context.temp_allocator)
        wanted:=fmt.tprintf("mirai import %s/source/models/box.obj --out %s/assets/models/box.obj --root %s",relative,relative,relative)
        testing.expect(t,strings.contains(found,wanted),found)
        os.remove(fmt.tprintf("%s/source/models/box.obj",root))
        lost:=version_message(&a,&types,named,allocator=context.temp_allocator)
        testing.expect(t,strings.has_suffix(lost,fmt.tprintf("import its source source/models/box.obj again with mirai import into %s/assets/models/box.obj",relative)),lost)
    }
    bare:=version_message(&a,&types,"Box.mesh",allocator=context.temp_allocator)
    testing.expect(t,strings.has_suffix(bare,"again with mirai import into ."),bare)
}
