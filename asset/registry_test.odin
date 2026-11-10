package asset

import "core:fmt"
import "core:os"
import "core:testing"
import "core:time"
import "mirai:std/base"
import "mirai:std/serial"

@(private="file")
write_material :: proc(t:^testing.T,types:^Types,path:string,id:base.Asset_Id,texture:base.Asset_Id) {
    info:=MATERIAL_DEFAULTS
    info.maps.base_color.texture=texture
    testing.expect_value(t,material_save(path,types,{id=id,info=info}),Error.None)
}

@(private="file")
write_texture :: proc(t:^testing.T,types:^Types,path:string,id:base.Asset_Id) {
    pixels:[16]u8
    testing.expect_value(t,texture_save(path,types,{id=id,width=2,height=2,format=.RGBA8,mips={pixels[:]}}),Error.None)
}

@(test)
registry_scans_headers_and_answers_by_id_path_and_dependency :: proc(t:^testing.T) {
    types:Types;types_init(&types);defer types_destroy(&types)
    root:=base.test_folder(t,"registry")
    os.make_directory_all(fmt.tprintf("%s/textures",root))
    os.make_directory_all(fmt.tprintf("%s/materials/deep",root))
    os.make_directory_all(fmt.tprintf("%s/.mirai",root))
    os.make_directory_all(fmt.tprintf("%s/empty",root))
    wood,brick,missing:=base.Asset_Id{1,1},base.Asset_Id{2,2},base.Asset_Id{9,9}
    write_texture(t,&types,fmt.tprintf("%s/textures/wood.tex",root),wood)
    write_texture(t,&types,fmt.tprintf("%s/textures/brick.tex",root),brick)
    write_material(t,&types,fmt.tprintf("%s/materials/wood.mat",root),{3,3},wood)
    write_material(t,&types,fmt.tprintf("%s/materials/deep/wall.mat",root),{4,4},brick)
    write_material(t,&types,fmt.tprintf("%s/materials/lost.mat",root),{5,5},missing)
    write_material(t,&types,fmt.tprintf("%s/materials/copy.mat",root),{3,3},wood)
    write_material(t,&types,fmt.tprintf("%s/.mirai/hidden.mat",root),{6,6},wood)
    write_material(t,&types,fmt.tprintf("%s/materials/staging.mat.123.tmp",root),{7,7},wood)
    scene:Scene;scene_init(&scene,&types,{8,8})
    scene_entity_add(&scene,1,0,"wall")
    mesh:=Test_Mesh{material={4,4}}
    scene_set(&scene,1,"Mesh",&mesh)
    testing.expect_value(t,scene_save(&scene,fmt.tprintf("%s/level.scene",root)),Error.None)
    scene_destroy(&scene)
    testing.expect_value(t,serial.file_write_atomic(fmt.tprintf("%s/notes.txt",root),transmute([]u8)string("not an asset")),serial.File_Error.None)
    whole,_:=serial.file_read(fmt.tprintf("%s/textures/wood.tex",root))
    defer delete(whole)
    testing.expect_value(t,serial.file_write_atomic(fmt.tprintf("%s/textures/cut.tex",root),whole[:len(whole)-5]),serial.File_Error.None)
    testing.expect_value(t,serial.file_write_atomic(fmt.tprintf("%s/textures/tiny.tex",root),whole[:10]),serial.File_Error.None)

    cache:=fmt.tprintf("%s/.mirai/registry.cache",root)
    r:Registry;registry_init(&r,root,cache);defer registry_destroy(&r)
    testing.expect_value(t,registry_scan(&r),Error.None)
    testing.expect_value(t,r.revision,u64(1))
    testing.expect_value(t,r.stats,Registry_Stats{files=10,assets=7,opened=10,reused=0})
    paths:=[10]string{"level.scene","materials/copy.mat","materials/deep/wall.mat","materials/lost.mat","materials/wood.mat","notes.txt","textures/brick.tex","textures/cut.tex","textures/tiny.tex","textures/wood.tex"}
    for path,at in paths {testing.expect_value(t,r.files[at].path,path)}
    testing.expect(t,r.files[5].state==.Other && r.files[7].state==.Broken && r.files[8].state==.Broken)
    // Every folder, also one without files; not those a scan leaves out.
    folders:=[4]string{"empty/","materials/","materials/deep/","textures/"}
    testing.expect_value(t,len(r.folders),len(folders))
    for folder,at in folders[:min(len(folders),len(r.folders))] {testing.expect_value(t,r.folders[at],folder)}

    wall,found:=registry_find(&r,{4,4})
    testing.expect(t,found && wall.path=="materials/deep/wall.mat" && wall.kind==KIND_MATERIAL && wall.kind_version==MATERIAL_VERSION && wall.state==.Asset)
    dependencies:=registry_dependencies(&r,wall)
    testing.expect(t,len(dependencies)==1 && dependencies[0]==brick)
    level,level_found:=registry_find_path(&r,"level.scene")
    testing.expect(t,level_found && level.id==base.Asset_Id{8,8} && level.kind==KIND_SCENE && level.size>0)
    _,no_id:=registry_find(&r,{6,6})
    _,no_path:=registry_find_path(&r,"textures/none.tex")
    testing.expect(t,!no_id && !no_path)

    dependents:=registry_dependents(&r,wood)
    testing.expect(t,len(dependents)==2 && r.files[dependents[0]].path=="materials/copy.mat" && r.files[dependents[1]].path=="materials/wood.mat")
    testing.expect(t,len(registry_dependents(&r,brick))==1 && len(registry_dependents(&r,{4,4}))==1 && len(registry_dependents(&r,{77,77}))==0)
    users:[dynamic]u32;defer delete(users)
    registry_closure(&r,{8,8},&users)
    testing.expect(t,len(users)==2 && r.files[users[0]].path=="materials/deep/wall.mat" && r.files[users[1]].path=="textures/brick.tex")
    registry_closure(&r,{77,77},&users)
    testing.expect_value(t,len(users),0)
    lost:[dynamic]Registry_Missing;defer delete(lost)
    registry_missing(&r,&lost)
    testing.expect(t,len(lost)==1 && r.files[lost[0].file].path=="materials/lost.mat" && lost[0].id==missing)
    testing.expect(t,len(r.duplicates)==1 && r.duplicates[0].id==base.Asset_Id{3,3} && r.files[r.duplicates[0].first].path=="materials/copy.mat" && r.files[r.duplicates[0].second].path=="materials/wood.mat")

    // Nothing changed: nothing is opened.
    testing.expect_value(t,registry_scan(&r),Error.None)
    testing.expect_value(t,r.revision,u64(2))
    testing.expect_value(t,r.stats,Registry_Stats{files=10,assets=7,opened=0,reused=10})
    same,_:=registry_find(&r,{4,4})
    testing.expect(t,len(registry_dependencies(&r,same))==1 && registry_dependencies(&r,same)[0]==brick)

    // A file that changed, one that left and one that came.
    hidden:[2]Material_Name
    text_set(hidden[0].name[:],"pbr")
    text_set(hidden[1].name[:],"foam")
    info:=MATERIAL_DEFAULTS
    info.maps.base_color.texture,info.maps.normal.texture=wood,brick
    testing.expect_value(t,material_save(fmt.tprintf("%s/materials/lost.mat",root),&types,{id={5,5},info=info,hidden=hidden[:]}),Error.None)
    os.remove(fmt.tprintf("%s/materials/copy.mat",root))
    write_texture(t,&types,fmt.tprintf("%s/textures/new.tex",root),{10,10})
    testing.expect_value(t,registry_scan(&r),Error.None)
    testing.expect_value(t,r.revision,u64(3))
    testing.expect_value(t,r.stats,Registry_Stats{files=10,assets=7,opened=2,reused=8})
    changed,_:=registry_find(&r,{5,5})
    testing.expect_value(t,len(registry_dependencies(&r,changed)),2)
    registry_missing(&r,&lost)
    testing.expect(t,len(lost)==0 && len(r.duplicates)==0)

    // Another run of the program starts from the cache.
    again:Registry;registry_init(&again,root,cache);defer registry_destroy(&again)
    testing.expect_value(t,registry_scan(&again),Error.None)
    testing.expect_value(t,again.stats,Registry_Stats{files=10,assets=7,opened=0,reused=10})
    cached,cached_found:=registry_find(&again,{5,5})
    testing.expect(t,cached_found && cached.path=="materials/lost.mat" && len(registry_dependencies(&again,cached))==2 && registry_dependencies(&again,cached)[1]==brick)
    testing.expect(t,again.files[6].state==.Broken && again.files[8].state==.Broken)

    // A cache that cannot be trusted is not used.
    bytes,_:=serial.file_read(cache)
    defer delete(bytes)
    for cut in ([]int{0,7,len(bytes)/2,len(bytes)-1}) {
        testing.expect_value(t,serial.file_write_atomic(cache,bytes[:cut]),serial.File_Error.None)
        fresh:Registry;registry_init(&fresh,root,cache)
        testing.expect_value(t,registry_scan(&fresh),Error.None)
        testing.expect_value(t,fresh.stats,Registry_Stats{files=10,assets=7,opened=10,reused=0})
        registry_destroy(&fresh)
    }
    bytes[len(bytes)/2]~=0xff
    serial.file_write_atomic(cache,bytes)
    garbled:Registry;registry_init(&garbled,root,cache);defer registry_destroy(&garbled)
    testing.expect_value(t,registry_scan(&garbled),Error.None)
    testing.expect_value(t,garbled.stats.files,10)

    nowhere:Registry;registry_init(&nowhere,fmt.tprintf("%s/no-such-folder",root));defer registry_destroy(&nowhere)
    testing.expect_value(t,registry_scan(&nowhere),Error.Not_Found)
    testing.expect_value(t,nowhere.revision,u64(1))
    free_all(context.temp_allocator)
}

@(test)
registry_from_its_cache_refreshes_a_new_a_changed_and_a_removed_file_without_a_scan :: proc(t:^testing.T) {
    types:Types;types_init(&types);defer types_destroy(&types)
    root:=base.test_folder(t,"registry-refresh")
    os.make_directory_all(fmt.tprintf("%s/textures",root))
    wood,brick,stone:=base.Asset_Id{1,1},base.Asset_Id{2,2},base.Asset_Id{3,3}
    write_texture(t,&types,fmt.tprintf("%s/textures/wood.tex",root),wood)
    write_texture(t,&types,fmt.tprintf("%s/textures/brick.tex",root),brick)
    write_material(t,&types,fmt.tprintf("%s/wall.mat",root),{10,10},brick)
    write_material(t,&types,fmt.tprintf("%s/floor.mat",root),{11,11},wood)
    cache:=fmt.tprintf("%s/.mirai/cache/registry",root)
    first:Registry;registry_init(&first,root,cache)
    testing.expect_value(t,registry_scan(&first),Error.None)
    testing.expect(t,os.is_file(cache))
    registry_destroy(&first)

    // Another run opens nothing that its cache knows.
    r:Registry;registry_init(&r,root,cache);defer registry_destroy(&r)
    testing.expect_value(t,registry_scan(&r),Error.None)
    testing.expect_value(t,r.stats,Registry_Stats{files=4,assets=4,opened=0,reused=4})
    before,_:=registry_find_path(&r,"wall.mat")
    wall_hash:=before.content_hash
    testing.expect(t,wall_hash!=0)
    testing.expect_value(t,len(registry_dependents(&r,brick)),1)

    // A new file, a changed one and a removed one, refreshed by path: only the two that are there are opened.
    write_texture(t,&types,fmt.tprintf("%s/textures/stone.tex",root),stone)
    time.sleep(10*time.Millisecond)
    write_material(t,&types,fmt.tprintf("%s/wall.mat",root),{10,10},stone)
    os.remove(fmt.tprintf("%s/floor.mat",root))
    revision:=r.revision
    paths:=[]string{"textures/stone.tex","wall.mat","floor.mat","textures/wood.tex",".mirai/cache/registry"}
    testing.expect_value(t,registry_refresh(&r,paths),Error.None)
    testing.expect_value(t,r.revision,revision+1)
    testing.expect_value(t,r.stats,Registry_Stats{files=4,assets=4,opened=2,reused=1})
    testing.expect_value(t,len(r.files),4)
    for path,at in ([]string{"textures/brick.tex","textures/stone.tex","textures/wood.tex","wall.mat"}) {testing.expect_value(t,r.files[at].path,path)}
    wall,found:=registry_find(&r,{10,10})
    testing.expect(t,found && wall.path=="wall.mat" && wall.content_hash!=wall_hash)
    testing.expect(t,len(registry_dependencies(&r,wall))==1 && registry_dependencies(&r,wall)[0]==stone)
    _,floor:=registry_find(&r,{11,11})
    _,floor_path:=registry_find_path(&r,"floor.mat")
    testing.expect(t,!floor && !floor_path)
    stone_file,stone_found:=registry_find(&r,stone)
    testing.expect(t,stone_found && stone_file.path=="textures/stone.tex")
    testing.expect(t,len(registry_dependents(&r,brick))==0 && len(registry_dependents(&r,wood))==0)
    users:=registry_dependents(&r,stone)
    testing.expect(t,len(users)==1 && r.files[users[0]].path=="wall.mat")
    // The removed one is noted; the changed one keeps its id and is not.
    testing.expect(t,len(r.removed)==1 && r.removed[0]==base.Asset_Id{11,11})
    clear(&r.removed)

    // Nothing that changed: the registry is as it was.
    revision=r.revision
    testing.expect_value(t,registry_refresh(&r,paths),Error.None)
    testing.expect_value(t,r.revision,revision)
    testing.expect_value(t,r.stats.opened,0)

    // The cache says what the refresh saw: another run opens nothing.
    again:Registry;registry_init(&again,root,cache);defer registry_destroy(&again)
    testing.expect_value(t,registry_scan(&again),Error.None)
    testing.expect_value(t,again.stats,Registry_Stats{files=4,assets=4,opened=0,reused=4})
    cached,_:=registry_find(&again,{10,10})
    testing.expect(t,cached.content_hash==wall.content_hash && len(registry_dependents(&again,stone))==1)
    testing.expect_value(t,len(again.removed),0)

    // A file removed while no program ran is noted by the next run, from the cache.
    registry_destroy(&again)
    os.remove(fmt.tprintf("%s/textures/brick.tex",root))
    registry_init(&again,root,cache)
    testing.expect_value(t,registry_scan(&again),Error.None)
    testing.expect(t,len(again.removed)==1 && again.removed[0]==brick)

    // So is one that only memory removes; without a cache nothing is noted.
    testing.expect_value(t,registry_memory_remove(&again,"textures/wood.tex"),Error.None)
    testing.expect(t,len(again.removed)==2 && again.removed[1]==wood)
    plain:Registry;registry_init(&plain,root);defer registry_destroy(&plain)
    testing.expect_value(t,registry_scan(&plain),Error.None)
    testing.expect_value(t,registry_memory_remove(&plain,"textures/wood.tex"),Error.None)
    testing.expect_value(t,len(plain.removed),0)
    free_all(context.temp_allocator)
}

// A cache that another build wrote, of another layout or container version, says what that build
// saw in the files: here a file it could not read, which this build reads. It is not trusted:
// the scan opens every file, finds the asset and writes the cache again.
@(test)
a_registry_cache_of_another_build_is_read_again_from_the_files :: proc(t:^testing.T) {
    types:Types;types_init(&types);defer types_destroy(&types)
    root:=base.test_folder(t,"registry-other-build")
    os.make_directory_all(root)
    write_material(t,&types,fmt.tprintf("%s/wall.mat",root),{10,10},{})
    info,error:=os.stat(fmt.tprintf("%s/wall.mat",root),context.temp_allocator)
    if !testing.expect(t,error==nil) {return}
    cache:=fmt.tprintf("%s/.mirai/cache/registry",root)
    os.make_directory_all(fmt.tprintf("%s/.mirai/cache",root))
    // The layout of the cache before the container version was part of it, then the current one
    // written by a build of another container version.
    for layout in ([2][2]u32{{3,0},{REGISTRY_CACHE_VERSION,VERSION+1}}) {
        w:serial.Writer;serial.writer_init(&w,allocator=context.temp_allocator)
        serial.write_u32(&w,REGISTRY_CACHE_MAGIC)
        serial.write_u32(&w,layout[0])
        if layout[1]!=0 {serial.write_u32(&w,layout[1])}
        serial.write_varint(&w,1)
        serial.write_string(&w,"wall.mat")
        serial.write_svarint(&w,info.size)
        serial.write_svarint(&w,time.time_to_unix_nano(info.modification_time))
        serial.write_u8(&w,u8(Registry_State.Broken))
        if !testing.expect_value(t,serial.file_write_atomic(cache,serial.writer_bytes(&w)),serial.File_Error.None) {return}
        r:Registry;registry_init(&r,root,cache)
        testing.expect_value(t,registry_scan(&r),Error.None)
        testing.expect_value(t,r.stats,Registry_Stats{files=1,assets=1,opened=1,reused=0})
        wall,found:=registry_find(&r,{10,10})
        testing.expect(t,found && wall.state==.Asset && wall.path=="wall.mat")
        registry_destroy(&r)
        again:Registry;registry_init(&again,root,cache)
        testing.expect_value(t,registry_scan(&again),Error.None)
        testing.expect_value(t,again.stats,Registry_Stats{files=1,assets=1,opened=0,reused=1})
        registry_destroy(&again)
    }
    free_all(context.temp_allocator)
}

@(test)
registry_loads_a_packed_index_without_looking_at_the_folder :: proc(t:^testing.T) {
    types:Types;types_init(&types);defer types_destroy(&types)
    root:=base.test_folder(t,"registry-index")
    os.make_directory_all(fmt.tprintf("%s/textures",root))
    wood:=base.Asset_Id{1,1}
    write_texture(t,&types,fmt.tprintf("%s/textures/wood.tex",root),wood)
    write_material(t,&types,fmt.tprintf("%s/wood.mat",root),{3,3},wood)
    index:=fmt.tprintf("%s/%s",root,REGISTRY_INDEX)
    scanned:Registry
    registry_init(&scanned,root)
    defer registry_destroy(&scanned)
    testing.expect_value(t,registry_scan(&scanned),Error.None)
    testing.expect(t,registry_save(&scanned,index))
    testing.expect_value(t,registry_scan(&scanned),Error.None)
    testing.expect_value(t,scanned.stats.files,2)

    // A file that appears afterwards is not in the index, and the index does not look for it.
    write_texture(t,&types,fmt.tprintf("%s/textures/late.tex",root),{2,2})
    loaded:Registry
    registry_init(&loaded,root)
    defer registry_destroy(&loaded)
    testing.expect_value(t,registry_load(&loaded,index),Error.None)
    testing.expect_value(t,loaded.revision,u64(1))
    testing.expect_value(t,len(loaded.files),2)
    testing.expect(t,loaded.stats.opened==0 && loaded.stats.assets==2)
    for &file,at in loaded.files {
        other:=scanned.files[at]
        testing.expect(t,file.path==other.path && file.size==other.size && file.time==other.time && file.id==other.id && file.kind==other.kind && file.state==other.state)
    }
    material,found:=registry_find(&loaded,{3,3})
    testing.expect(t,found && material.path=="wood.mat" && len(registry_dependencies(&loaded,material))==1 && registry_dependencies(&loaded,material)[0]==wood)
    _,late:=registry_find(&loaded,{2,2})
    testing.expect(t,!late)
    by_path,has_path:=registry_find_path(&loaded,"textures/wood.tex")
    testing.expect(t,has_path && by_path.id==wood)

    // Without an index, or with one that is not an index, the registry is empty and says which.
    testing.expect_value(t,registry_load(&loaded,fmt.tprintf("%s/absent",root)),Error.Not_Found)
    testing.expect_value(t,loaded.revision,u64(2))
    testing.expect_value(t,len(loaded.files),0)
    whole,_:=serial.file_read(index)
    defer delete(whole)
    for cut in ([]int{0,7,len(whole)-1}) {
        testing.expect_value(t,serial.file_write_atomic(index,whole[:cut]),serial.File_Error.None)
        revision:=loaded.revision
        testing.expect_value(t,registry_load(&loaded,index),Error.Corrupt)
        testing.expect_value(t,loaded.revision,revision+1)
        _,any:=registry_find(&loaded,wood)
        testing.expect(t,!any && len(loaded.files)==0)
    }
    testing.expect_value(t,serial.file_write_atomic(index,whole),serial.File_Error.None)
    testing.expect_value(t,registry_load(&loaded,index),Error.None)
    testing.expect_value(t,len(loaded.files),2)
}

// A folder of assets opened by scanning its files, by scanning them from the
// cache of another run, and by reading its packed index, and one of its files
// refreshed. Run with --release -define:ASSET_INDEX_BENCH=true;
// ASSET_INDEX_FOLDER names a folder to measure besides the generated one.
@(private="file") INDEX_BENCH :: #config(ASSET_INDEX_BENCH,false)
@(private="file") INDEX_FOLDER :: #config(ASSET_INDEX_FOLDER,"")

@(test)
bench_registry_scan_against_its_packed_index :: proc(t:^testing.T) {
    if !INDEX_BENCH {return}
    measure :: proc(t:^testing.T,name,root:string) {
        index:=fmt.tprintf("%s/%s",root,REGISTRY_INDEX)
        cache:=fmt.tprintf("%s/cache",base.test_folder(t,"registry-bench-cache"))
        os.remove(index)
        scan_best,cached_best,load_best,refresh_best:=time.Duration(max(i64)),time.Duration(max(i64)),time.Duration(max(i64)),time.Duration(max(i64))
        files:=0
        for _ in 0..<5 {
            r:Registry
            registry_init(&r,root)
            start:=time.tick_now()
            testing.expect_value(t,registry_scan(&r),Error.None)
            scan_best=min(scan_best,time.tick_since(start))
            files=len(r.files)
            testing.expect(t,registry_save(&r,index))
            testing.expect(t,registry_save(&r,cache))
            registry_destroy(&r)
        }
        for _ in 0..<5 {
            r:Registry
            registry_init(&r,root,cache)
            start:=time.tick_now()
            testing.expect_value(t,registry_scan(&r),Error.None)
            cached_best=min(cached_best,time.tick_since(start))
            testing.expect_value(t,r.stats.opened,0)
            if len(r.files)>0 {
                path:=r.files[len(r.files)/2].path
                r.files[len(r.files)/2].time-=1 // as if the file changed: it is opened again
                start=time.tick_now()
                testing.expect_value(t,registry_refresh(&r,{path}),Error.None)
                refresh_best=min(refresh_best,time.tick_since(start))
            }
            registry_destroy(&r)
        }
        for _ in 0..<5 {
            r:Registry
            registry_init(&r,root)
            start:=time.tick_now()
            testing.expect_value(t,registry_load(&r,index),Error.None)
            load_best=min(load_best,time.tick_since(start))
            testing.expect_value(t,len(r.files),files)
            registry_destroy(&r)
        }
        info,_:=os.stat(index,context.temp_allocator)
        os.remove(index)
        fmt.printfln("%s: %d files, scan %.2f ms, scan from its cache %.2f ms, packed index (%d bytes) %.3f ms, refresh of a changed file %.3f ms",name,files,time.duration_milliseconds(scan_best),time.duration_milliseconds(cached_best),info.size,time.duration_milliseconds(load_best),time.duration_milliseconds(refresh_best))
    }
    types:Types;types_init(&types);defer types_destroy(&types)
    root:=base.test_folder(t,"registry-bench")
    for folder in 0..<20 {
        os.make_directory_all(fmt.tprintf("%s/set%d",root,folder))
        for at in 0..<100 {
            id:=base.Asset_Id{u64(folder)+1,u64(at)+1}
            write_texture(t,&types,fmt.tprintf("%s/set%d/t%d.tex",root,folder,at),id)
            write_material(t,&types,fmt.tprintf("%s/set%d/m%d.mat",root,folder,at),{u64(folder)+100,u64(at)+1},id)
        }
    }
    measure(t,"generated",root)
    if INDEX_FOLDER!="" {measure(t,INDEX_FOLDER,INDEX_FOLDER)}
}

@(test)
registry_gives_a_copy_made_outside_an_editor_an_id_of_its_own_in_memory :: proc(t:^testing.T) {
    types:Types;types_init(&types);defer types_destroy(&types)
    root:=base.test_folder(t,"registry-copies")
    os.make_directory_all(fmt.tprintf("%s/materials",root))
    original,prefab:=base.Asset_Id{3,3},base.Asset_Id{7,7}
    source:Import_Info
    text_set(source.source[:],"models/box.gltf")
    text_set(source.name[:],"Wood")
    info:=MATERIAL_DEFAULTS
    testing.expect_value(t,material_save(fmt.tprintf("%s/materials/wood.mat",root),&types,{id=original,owner=prefab,info=info,source=&source}),Error.None)
    bytes,_:=serial.file_read(fmt.tprintf("%s/materials/wood.mat",root))
    defer delete(bytes)
    time.sleep(20*time.Millisecond)
    testing.expect_value(t,serial.file_write_atomic(fmt.tprintf("%s/materials/wood copy.mat",root),bytes),serial.File_Error.None)

    // A tool that only reads the folder sees the two files with one id.
    seen:Registry;registry_init(&seen,root);defer registry_destroy(&seen)
    testing.expect_value(t,registry_scan(&seen),Error.None)
    testing.expect(t,len(seen.duplicates)==1 && len(seen.reassigned)==0 && len(seen.memory)==0)
    parts:[dynamic]u32;defer delete(parts)
    registry_parts(&seen,prefab,&parts)
    testing.expect_value(t,len(parts),2)

    cache:=fmt.tprintf("%s/.cache",root)
    r:Registry;registry_init(&r,root,cache);defer registry_destroy(&r)
    r.resolve_duplicates=true
    testing.expect_value(t,registry_scan(&r),Error.None)
    testing.expect_value(t,len(r.duplicates),0)
    if !testing.expect_value(t,len(r.reassigned),1) {return}
    moved:=r.reassigned[0]
    testing.expect(t,moved.path=="materials/wood copy.mat" && moved.original=="materials/wood.mat" && moved.from==original && moved.to!=original && moved.to!={})
    kept,found_kept:=registry_find(&r,original)
    copy,found_copy:=registry_find(&r,moved.to)
    testing.expect(t,found_kept && kept.path=="materials/wood.mat" && kept.owner==prefab)
    testing.expect(t,found_copy && copy.path=="materials/wood copy.mat" && copy.owner=={} && .Cooked not_in copy.flags)
    registry_parts(&r,prefab,&parts)
    testing.expect(t,len(parts)==1 && r.files[parts[0]].path=="materials/wood.mat","the copy is no part of the prefab")
    held,_:=registry_read(&r,"materials/wood copy.mat")
    a:Asset
    testing.expect_value(t,asset_open(&a,held),Error.None)
    imported,_:=import_info(&a,&types)
    testing.expect(t,a.blob.header.id==moved.to && imported==nil,"the copy is no output of an import")
    asset_close(&a);delete(held)
    disk,_:=serial.file_read(fmt.tprintf("%s/materials/wood copy.mat",root))
    header,_:=header_read(disk)
    testing.expect(t,header.id==original,"nothing is written before it is saved")
    delete(disk)

    // Until it is written the copy keeps that id, here and in the next run.
    testing.expect_value(t,registry_scan(&r),Error.None)
    testing.expect(t,len(r.reassigned)==1 && r.reassigned[0].to==moved.to)
    next:Registry;registry_init(&next,root,cache);defer registry_destroy(&next)
    next.resolve_duplicates=true
    testing.expect_value(t,registry_scan(&next),Error.None)
    testing.expect(t,len(next.reassigned)==1 && next.reassigned[0].to==moved.to)
    from_cache,cached:=registry_find(&next,original)
    testing.expect(t,cached && from_cache.owner==prefab,"the cache keeps the owner")

    testing.expect_value(t,registry_memory_write(&r,"materials/wood copy.mat"),Error.None)
    testing.expect_value(t,registry_scan(&r),Error.None)
    testing.expect(t,len(r.reassigned)==0 && len(r.duplicates)==0 && len(r.memory)==0)
    written,found_written:=registry_find(&r,moved.to)
    testing.expect(t,found_written && written.path=="materials/wood copy.mat")
}

@(test)
registry_gives_every_copy_an_id_and_forgets_one_whose_file_goes :: proc(t:^testing.T) {
    types:Types;types_init(&types);defer types_destroy(&types)
    root:=base.test_folder(t,"registry-copies-gone")
    os.make_directory_all(fmt.tprintf("%s/materials",root))
    original:=base.Asset_Id{3,3}
    testing.expect_value(t,material_save(fmt.tprintf("%s/materials/wood.mat",root),&types,{id=original,info=MATERIAL_DEFAULTS}),Error.None)
    bytes,_:=serial.file_read(fmt.tprintf("%s/materials/wood.mat",root))
    defer delete(bytes)
    for name in ([2]string{"wood copy.mat","wood copy 2.mat"}) {
        time.sleep(20*time.Millisecond)
        testing.expect_value(t,serial.file_write_atomic(fmt.tprintf("%s/materials/%s",root,name),bytes),serial.File_Error.None)
    }
    r:Registry;registry_init(&r,root,fmt.tprintf("%s/.cache",root));defer registry_destroy(&r)
    r.resolve_duplicates=true
    testing.expect_value(t,registry_scan(&r),Error.None)
    if !testing.expect_value(t,len(r.reassigned),2) {return}
    testing.expect(t,r.reassigned[0].to!=r.reassigned[1].to && r.reassigned[0].original=="materials/wood.mat" && r.reassigned[1].original=="materials/wood.mat")
    kept,found:=registry_find(&r,original)
    testing.expect(t,found && kept.path=="materials/wood.mat" && len(r.duplicates)==0)

    // Removed outside the editor before it was edited, a copy leaves memory with its file.
    os.remove(fmt.tprintf("%s/materials/wood copy.mat",root))
    testing.expect_value(t,registry_refresh(&r,{"materials/wood copy.mat"}),Error.None)
    _,listed:=r.by_path["materials/wood copy.mat"]
    testing.expect(t,!listed && len(r.reassigned)==1 && len(r.memory)==1)
    os.remove(fmt.tprintf("%s/materials/wood copy 2.mat",root))
    testing.expect_value(t,registry_scan(&r),Error.None)
    testing.expect(t,len(r.files)==1 && len(r.reassigned)==0 && len(r.memory)==0)
}

// A folder mounted while running is seen at once, over a scan and over a
// packed index, and never takes an id the registry already has: the copy of a
// shipped id is left out. Refreshing finds what is written in it, and
// unmounting takes it out whole.
@(test)
registry_mounts_a_guest_folder_that_never_takes_an_id_the_registry_has :: proc(t:^testing.T) {
    types:Types;types_init(&types);defer types_destroy(&types)
    root,guest:=base.test_folder(t,"registry-guest"),base.test_folder(t,"registry-guest-user")
    os.make_directory_all(fmt.tprintf("%s/textures",root))
    os.make_directory_all(fmt.tprintf("%s/levels",guest))
    wood,own,late:=base.Asset_Id{1,1},base.Asset_Id{2,2},base.Asset_Id{3,3}
    write_texture(t,&types,fmt.tprintf("%s/textures/wood.tex",root),wood)
    write_texture(t,&types,fmt.tprintf("%s/levels/own.tex",guest),own)
    write_texture(t,&types,fmt.tprintf("%s/levels/fake.tex",guest),wood)
    index:=fmt.tprintf("%s/%s",root,REGISTRY_INDEX)
    packed:Registry;registry_init(&packed,root);defer registry_destroy(&packed)
    testing.expect_value(t,registry_scan(&packed),Error.None)
    testing.expect(t,registry_save(&packed,index))

    Mode :: enum {Scanned,Indexed}
    for mode in Mode {
        r:Registry;registry_init(&r,root);defer registry_destroy(&r)
        testing.expect_value(t,registry_scan(&r) if mode==.Scanned else registry_load(&r,index),Error.None)
        for prefix in ([]string{"",".user","..","/user","user/","a//b","a/../b","a\\b","a:b","textures"}) {
            _,error:=registry_mount_guest(&r,guest,prefix)
            testing.expectf(t,error==.Invalid,"%v: prefix %q gives %v",mode,prefix,error)
        }
        _,missing:=registry_mount_guest(&r,fmt.tprintf("%s/absent",guest),"user")
        testing.expect_value(t,missing,Error.Not_Found)
        revision:=r.revision
        refused,error:=registry_mount_guest(&r,guest,"user")
        testing.expect(t,error==.None && refused==1 && r.revision>revision)
        file,found:=registry_find(&r,own)
        testing.expect(t,found && file.path=="user/levels/own.tex")
        testing.expect_value(t,registry_file_path(&r,file.path,context.temp_allocator),fmt.tprintf("%s/levels/own.tex",guest))
        shipped,_:=registry_find(&r,wood)
        testing.expect_value(t,shipped.path,"textures/wood.tex")
        _,copy:=registry_find_path(&r,"user/levels/fake.tex")
        testing.expect(t,!copy && len(r.refused)==1 && r.refused[0]=="user/levels/fake.tex")
        empty:=fmt.tprintf("%s/empty",guest)
        os.make_directory_all(empty)
        for taken in ([]string{"user","user/more"}) {
            _,again:=registry_mount_guest(&r,empty,taken)
            testing.expect_value(t,again,Error.Invalid)
        }
        _,spare:=registry_mount_guest(&r,empty,"spare")
        _,twice:=registry_mount_guest(&r,empty,"spare")
        testing.expect(t,spare==.None && twice==.Invalid && registry_unmount(&r,"spare")==.None)

        write_texture(t,&types,fmt.tprintf("%s/levels/late.tex",guest),late)
        testing.expect_value(t,registry_refresh(&r,{"user/levels/late.tex","user/levels/fake.tex"}),Error.None)
        _,seen:=registry_find(&r,late)
        testing.expect(t,seen && len(r.refused)==1)
        if mode==.Scanned {
            testing.expect_value(t,registry_scan(&r),Error.None)
            _,kept:=registry_find(&r,own)
            testing.expect(t,kept && len(r.refused)==1)
        }

        revision=r.revision
        testing.expect_value(t,registry_unmount(&r,"user"),Error.None)
        _,gone:=registry_find(&r,own)
        _,gone_late:=registry_find(&r,late)
        _,still:=registry_find(&r,wood)
        testing.expect(t,!gone && !gone_late && still && len(r.refused)==0 && len(r.mounts)==0 && r.revision>revision)
        testing.expect_value(t,registry_unmount(&r,"user"),Error.Not_Found)
        os.remove(fmt.tprintf("%s/levels/late.tex",guest))
    }
}
