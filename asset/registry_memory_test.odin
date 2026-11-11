package asset

import "core:fmt"
import "core:os"
import "core:testing"
import "mirai:std/base"
import "mirai:std/serial"

@(private="file")
material_bytes_of :: proc(t:^testing.T,types:^Types,id,texture:base.Asset_Id,roughness:f32) -> []u8 {
    info:=MATERIAL_DEFAULTS
    info.roughness=roughness
    info.maps.base_color.texture=texture
    doc:Document
    testing.expect_value(t,material_document(&doc,types,{id=id,info=info}),Error.None)
    defer document_destroy(&doc)
    data,error:=document_bytes(&doc,context.temp_allocator)
    testing.expect_value(t,error,Error.None)
    return data
}

@(test)
registry_answers_with_files_held_in_memory_until_they_are_written_or_dropped :: proc(t:^testing.T) {
    types:Types;types_init(&types);defer types_destroy(&types)
    root:=base.test_folder(t,"registry-memory")
    os.make_directory_all(fmt.tprintf("%s/materials",root))
    stone,clay,brick:=base.Asset_Id{1,1},base.Asset_Id{2,2},base.Asset_Id{3,3}
    on_disk:=material_bytes_of(t,&types,stone,{},0.5)
    testing.expect_value(t,serial.file_write_atomic(fmt.tprintf("%s/materials/stone.mat",root),on_disk),serial.File_Error.None)
    r:Registry
    registry_init(&r,root)
    defer registry_destroy(&r)
    testing.expect_value(t,registry_scan(&r),Error.None)
    disk,_:=registry_find(&r,stone)
    disk_time:=disk.time

    changed:=material_bytes_of(t,&types,stone,clay,0.25)
    testing.expect_value(t,registry_memory_set(&r,"materials/stone.mat",changed),Error.None)
    held,found:=registry_find(&r,stone)
    testing.expect(t,found && held.size==i64(len(changed)) && held.time!=disk_time,"the record is what memory holds")
    testing.expect(t,len(registry_dependencies(&r,held))==1 && registry_dependencies(&r,held)[0]==clay)
    read,error:=registry_read(&r,"materials/stone.mat",context.temp_allocator)
    testing.expect(t,error==.None && string(read)==string(changed),"a read gives what memory holds")
    stored,_:=os.read_entire_file(fmt.tprintf("%s/materials/stone.mat",root),context.temp_allocator)
    testing.expect(t,string(stored)==string(on_disk),"and the disk keeps what it had")

    created:=material_bytes_of(t,&types,brick,{},0.75)
    testing.expect_value(t,registry_memory_set(&r,"materials/brick.mat",created),Error.None)
    testing.expect_value(t,registry_scan(&r),Error.None)
    _,found=registry_find(&r,brick)
    testing.expect(t,found,"a scan keeps a file that only memory holds")
    held,_=registry_find(&r,stone)
    testing.expect_value(t,held.size,i64(len(changed)))
    testing.expect(t,!os.exists(fmt.tprintf("%s/materials/brick.mat",root)))

    testing.expect_value(t,registry_memory_remove(&r,"materials/stone.mat"),Error.None)
    _,found=registry_find(&r,stone)
    testing.expect(t,!found,"a removed file is not there")
    _,error=registry_read(&r,"materials/stone.mat",context.temp_allocator)
    testing.expect_value(t,error,Error.Not_Found)
    {dropped,_:=registry_memory_drop(&r,"materials/stone.mat");testing.expect(t,dropped)}
    held,found=registry_find(&r,stone)
    testing.expect(t,found && held.size==i64(len(on_disk)) && len(registry_dependencies(&r,held))==0,"dropped, the disk answers again")

    testing.expect_value(t,registry_memory_write(&r,"materials/brick.mat"),Error.None)
    stored,_=os.read_entire_file(fmt.tprintf("%s/materials/brick.mat",root),context.temp_allocator)
    testing.expect(t,string(stored)==string(created) && len(r.memory)==0,"written, the file holds it and memory forgets it")
    _,found=registry_find(&r,brick)
    testing.expect(t,found)
}

@(test)
registry_holds_a_file_outside_its_folders_by_its_absolute_path :: proc(t:^testing.T) {
    root:=base.test_folder(t,"registry-memory-outside")
    os.make_directory_all(fmt.tprintf("%s/assets",root))
    os.make_directory_all(fmt.tprintf("%s/shaders",root))
    source:=fmt.tprintf("%s/shaders/rock.slang",root)
    testing.expect(t,os.write_entire_file(source,"saved")==nil)
    r:Registry
    registry_init(&r,fmt.tprintf("%s/assets",root))
    defer registry_destroy(&r)
    testing.expect_value(t,registry_scan(&r),Error.None)
    testing.expect(t,registry_outside(source) && !registry_outside("materials/stone.mat"))

    testing.expect_value(t,registry_memory_set(&r,source,transmute([]u8)string("unsaved")),Error.None)
    _,listed:=registry_find_path(&r,source)
    testing.expect(t,!listed && len(r.files)==0,"it is no file of the registry")
    read,error:=registry_read(&r,source,context.temp_allocator)
    testing.expect(t,error==.None && string(read)=="unsaved")
    testing.expect_value(t,registry_scan(&r),Error.None)
    _,kept:=registry_memory_find(&r,source)
    testing.expect(t,kept && len(r.files)==0,"a scan keeps it in memory and out of the files")

    {dropped,_:=registry_memory_drop(&r,source);testing.expect(t,dropped)}
    testing.expect(t,len(r.files)==0 && len(r.memory)==0,"dropped, memory holds nothing of it")

    testing.expect_value(t,registry_memory_set(&r,source,transmute([]u8)string("written")),Error.None)
    testing.expect_value(t,registry_memory_write(&r,source),Error.None)
    stored,_:=os.read_entire_file(source,context.temp_allocator)
    testing.expect(t,string(stored)=="written" && len(r.memory)==0 && len(r.files)==0)
}

// What places a prefab depends on it, also while the placer is a file only
// memory holds: who follows a prefab that changed is found without reading
// every file of the assets.
@(test)
registry_tells_which_files_place_a_prefab_while_memory_holds_them :: proc(t:^testing.T) {
    types:Types;types_init(&types);defer types_destroy(&types)
    root:=base.test_folder(t,"registry-placers")
    os.make_directory_all(root)
    r:Registry
    registry_init(&r,root)
    defer registry_destroy(&r)
    testing.expect_value(t,registry_scan(&r),Error.None)
    lamp,yard_id:=base.Asset_Id{7,7},base.Asset_Id{8,8}
    yard:Scene
    testing.expect_value(t,scene_init(&yard,&types,KIND_PREFAB,yard_id),Error.None)
    defer scene_destroy(&yard)
    scene_entity_add(&yard,1,0,"Yard")
    scene_entity_add(&yard,2,1,"Lamp")
    testing.expect_value(t,scene_instance_set(&yard,2,{prefab=lamp}),Error.None)
    testing.expect_value(t,scene_member_set(&yard,2,2,1),Error.None)
    data,encoded:=scene_bytes(&yard,context.temp_allocator)
    testing.expect_value(t,encoded,Error.None)
    testing.expect_value(t,len(registry_dependents(&r,lamp)),0)
    testing.expect_value(t,registry_memory_set(&r,"yard.prefab",data),Error.None)
    placers:=registry_dependents(&r,lamp)
    testing.expect(t,len(placers)==1 && r.files[placers[0]].id==yard_id && r.files[placers[0]].kind==KIND_PREFAB)
    testing.expect_value(t,registry_memory_remove(&r,"yard.prefab"),Error.None)
    testing.expect_value(t,len(registry_dependents(&r,lamp)),0)
}
