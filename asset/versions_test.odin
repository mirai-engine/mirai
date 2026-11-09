package asset

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

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
    root,_:=strings.replace_all(test_path("versions"),"\\","/",context.temp_allocator)
    defer os.remove_all(root)
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
        testing.expectf(t,info.version>0 || info.kind==KIND_PHYSICS_CACHE,"%s has the version it reads",info.name)
    }
    b.blob.header.kind=Fourcc(u32('G')|u32('R')<<8|u32('W')<<16|u32('N')<<24)
    told=version_message(&b,&types,"grown.grw",2,context.temp_allocator)
    testing.expect(t,strings.contains(told,"of version 0, older than this build reads (version 2)") && strings.contains(told,"make it again"),told)
    b.blob.header.kind_version=3
    told=version_message(&b,&types,"grown.grw",2,context.temp_allocator)
    testing.expect(t,strings.contains(told,"newer than this build") && strings.contains(told,"newer engine"),told)
}

@(test)
an_asset_of_another_version_named_by_a_relative_path_says_how_to_import_it_again :: proc(t:^testing.T) {
    types:Types;types_init(&types);defer types_destroy(&types)
    root,_:=strings.replace_all(test_path("versions_relative"),"\\","/",context.temp_allocator)
    defer os.remove_all(root)
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
