package save

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import "mirai:asset"
import "mirai:core"
import "mirai:engine/scene"
import "mirai:host"
import "mirai:std/base"
import "mirai:std/jobs"
import "mirai:std/serial"
import stbi "vendor:stb/image"

@(private="file")
Save_Test_World :: struct {
    entities:core.Entities,
    ids:core.Table(core.Id),
    names:core.Table(core.Name),
    transforms:core.Table(core.Transform),
    parents:core.Table(core.Parent),
    remotes:core.Table(core.Remote),
    targets:core.Table(core.Pose_Target),
    hierarchy:core.Hierarchy,
    root:scene.Scene_Root,
}

// The layout of the World and an application that makes it.
@(private="file")
Save_Test :: struct {
    tables:[6]core.Table_Info,
    storages:[2]core.Storage_Info,
    info:core.World_Info,
    app:host.App,
    w:^Save_Test_World,
}

@(private="file")
save_test_settle :: proc(world,shared,editor:rawptr) {
    w:=cast(^Save_Test_World)world
    core.table_settle(&w.ids,&w.entities);core.table_settle(&w.names,&w.entities)
    core.table_settle(&w.transforms,&w.entities);core.table_settle(&w.parents,&w.entities)
    core.table_settle(&w.remotes,&w.entities);core.table_settle(&w.targets,&w.entities)
    core.hierarchy_settle(&w.hierarchy,core.read(&w.parents),&w.entities)
    core.entities_settle(&w.entities)
}

@(private="file")
save_test_clear :: proc(world:rawptr) -> bool {
    w:=cast(^Save_Test_World)world
    if !core.entities_clear(&w.entities) {return false}
    core.table_clear(&w.ids);core.table_clear(&w.names);core.table_clear(&w.transforms);core.table_clear(&w.parents)
    core.table_clear(&w.remotes);core.table_clear(&w.targets)
    core.hierarchy_clear(&w.hierarchy)
    return true
}

@(private="file")
save_test_world_init :: proc(data:rawptr,allocator:runtime.Allocator) -> bool {
    w:=cast(^Save_Test_World)data
    w^={}
    core.entities_init(&w.entities,allocator)
    core.table_init(&w.ids,"Id",allocator);core.table_init(&w.names,"Name",allocator)
    core.table_init(&w.transforms,"Transform",allocator);core.table_init(&w.parents,"Parent",allocator)
    core.table_init(&w.remotes,"Remote",allocator);core.table_init(&w.targets,"Pose_Target",allocator)
    return len(w.entities.generation)>0
}

@(private="file")
save_test_world_destroy :: proc(data:rawptr) {
    w:=cast(^Save_Test_World)data
    core.table_destroy(&w.ids);core.table_destroy(&w.names);core.table_destroy(&w.transforms);core.table_destroy(&w.parents)
    core.table_destroy(&w.remotes);core.table_destroy(&w.targets)
    core.value_free(&w.hierarchy,type_info_of(core.Hierarchy))
    core.entities_destroy(&w.entities)
}

@(private="file")
save_test_copy :: proc(dst,src:rawptr) -> bool {
    d,s:=cast(^Save_Test_World)dst,cast(^Save_Test_World)src
    return core.entities_copy(&d.entities,&s.entities) && core.table_copy(&d.ids,&s.ids) && core.table_copy(&d.names,&s.names) &&
        core.table_copy(&d.transforms,&s.transforms) && core.table_copy(&d.parents,&s.parents) &&
        core.table_copy(&d.remotes,&s.remotes) && core.table_copy(&d.targets,&s.targets) &&
        core.value_copy(&d.hierarchy,&s.hierarchy,type_info_of(core.Hierarchy)) && core.value_copy(&d.root,&s.root,type_info_of(scene.Scene_Root))
}

@(private="file")
save_test_swap :: proc(a,b:rawptr) {
    a,b:=cast(^Save_Test_World)a,cast(^Save_Test_World)b
    a.entities,b.entities=b.entities,a.entities
    core.table_swap(&a.ids,&b.ids);core.table_swap(&a.names,&b.names)
    core.table_swap(&a.transforms,&b.transforms);core.table_swap(&a.parents,&b.parents)
    core.table_swap(&a.remotes,&b.remotes);core.table_swap(&a.targets,&b.targets)
    a.hierarchy,b.hierarchy=b.hierarchy,a.hierarchy
    a.root,b.root=b.root,a.root
}

@(private="file")
save_test_init :: proc(t:^testing.T,f:^Save_Test) -> bool {
    f.tables={
        {name="Id",type=core.Id,info=type_info_of(core.Id),offset=offset_of(Save_Test_World,ids)},
        {name="Name",type=core.Name,info=type_info_of(core.Name),offset=offset_of(Save_Test_World,names)},
        {name="Transform",type=core.Transform,info=type_info_of(core.Transform),offset=offset_of(Save_Test_World,transforms)},
        {name="Parent",type=core.Parent,info=type_info_of(core.Parent),offset=offset_of(Save_Test_World,parents)},
        {name="Remote",type=core.Remote,info=type_info_of(core.Remote),offset=offset_of(Save_Test_World,remotes)},
        {name="Pose_Target",type=core.Pose_Target,info=type_info_of(core.Pose_Target),offset=offset_of(Save_Test_World,targets)},
    }
    f.storages={
        {type=core.Hierarchy,info=type_info_of(core.Hierarchy),offset=offset_of(Save_Test_World,hierarchy)},
        {type=scene.Scene_Root,info=type_info_of(scene.Scene_Root),offset=offset_of(Save_Test_World,root),keep=true},
    }
    f.info={entities=offset_of(Save_Test_World,entities),tables=f.tables[:],storages=f.storages[:],clear=save_test_clear,copy=save_test_copy,swap=save_test_swap}
    f.info.sizes[.World],f.info.aligns[.World]=size_of(Save_Test_World),align_of(Save_Test_World)
    f.info.init[.World],f.info.destroy[.World]=save_test_world_init,save_test_world_destroy
    f.app={info=&f.info,allocator=context.allocator}
    f.w=cast(^Save_Test_World)host.app_world_create(&f.app)
    return testing.expect(t,f.w!=nil)
}

@(private="file")
save_test_destroy :: proc(f:^Save_Test) {
    host.app_world_free(&f.app,f.w)
    delete(f.app.worlds)
}

// An entity without an Id, as a transient copy, travels with one it is lent
// and comes back without it; one of the scene keeps its own.
@(test)
a_transient_entity_comes_back_from_a_save_without_the_id_it_was_lent :: proc(t:^testing.T) {
    f:Save_Test
    if !save_test_init(t,&f) {return}
    defer save_test_destroy(&f)
    w:=f.w
    authored,copy:=core.create(&w.entities),core.create(&w.entities)
    core.add(&w.ids,authored,core.Id{5})
    core.add(&w.transforms,authored,core.TRANSFORM_IDENTITY)
    core.add(&w.transforms,copy,core.Transform{position={1,2,3},rotation=1,scale={1,1,1}})
    core.add(&w.parents,copy,core.Parent{entity=authored})
    save_test_settle(w,nil,nil)
    ref:=host.app_world_ref(&f.app,w)
    out:serial.Writer
    serial.writer_init(&out,0,context.allocator)
    defer serial.writer_destroy(&out)
    if !testing.expect_value(t,capture(ref,f.app.assets,f.app.allocator,&out),Error.None) {return}
    header:=(cast(^Header)raw_data(serial.writer_bytes(&out)))^
    testing.expect_value(t,header.lent,1)
    testing.expect_value(t,len(w.ids.values),1)

    if !testing.expect_value(t,restore(ref,&f.app,serial.writer_bytes(&out)),Error.None) {return}
    testing.expect_value(t,core.count(&w.transforms),2)
    testing.expect_value(t,core.count(&w.ids),1)
    testing.expect_value(t,w.ids.values[0].value,5)
    for row in 0..<core.count(&w.transforms) {
        e:=core.entity_at(&w.transforms,row)
        if core.has(&w.ids,e) {continue}
        placed,_:=core.get(core.read(&w.transforms),e)
        parent,found:=core.get(core.read(&w.parents),e)
        testing.expect(t,placed.position==[3]f32{1,2,3} && found && core.has(&w.ids,parent.entity))
    }
}

// The Ids lent are those the slot lists, wherever the sequence they come
// from meets the Ids of the scene.
@(test)
an_id_of_the_scene_that_the_lending_sequence_would_give_stays_its_own :: proc(t:^testing.T) {
    f:Save_Test
    if !save_test_init(t,&f) {return}
    defer save_test_destroy(&f)
    w:=f.w
    state:=u64(0)
    taken:=base.entity_id_next(&state)
    authored,copy:=core.create(&w.entities),core.create(&w.entities)
    core.add(&w.ids,authored,core.Id{taken})
    core.add(&w.transforms,authored,core.TRANSFORM_IDENTITY)
    core.add(&w.transforms,copy,core.TRANSFORM_IDENTITY)
    save_test_settle(w,nil,nil)
    ref:=host.app_world_ref(&f.app,w)
    out:serial.Writer
    serial.writer_init(&out,0,context.allocator)
    defer serial.writer_destroy(&out)
    if !testing.expect_value(t,capture(ref,f.app.assets,f.app.allocator,&out),Error.None) {return}
    testing.expect_value(t,core.entity_of(&w.entities,taken),authored)

    if !testing.expect_value(t,restore(ref,&f.app,serial.writer_bytes(&out)),Error.None) {return}
    testing.expect_value(t,core.count(&w.transforms),2)
    testing.expect_value(t,core.count(&w.ids),1)
    found:=core.entity_of(&w.entities,taken)
    testing.expect(t,found!=core.NONE && core.has(&w.transforms,found))
    // A slot whose list of lent Ids runs past its bytes is refused.
    bytes:=serial.writer_bytes(&out)
    (cast(^Header)raw_data(bytes)).lent=1<<20
    testing.expect_value(t,restore(ref,&f.app,bytes),Error.Corrupt)
}

// A slot that fails halfway, after its entities were made, leaves the world
// as it was; one that loads replaces it.
@(test)
a_slot_that_fails_halfway_leaves_the_world_as_it_was :: proc(t:^testing.T) {
    f:Save_Test
    if !save_test_init(t,&f) {return}
    defer save_test_destroy(&f)
    w:=f.w
    for i in 1..=64 {
        e:=core.create(&w.entities)
        core.add(&w.ids,e,core.Id{base.Entity_Id(i)})
        core.add(&w.transforms,e,core.Transform{position={1,2,3},rotation=1,scale={1,1,1}})
    }
    save_test_settle(w,nil,nil)
    ref:=host.app_world_ref(&f.app,w)
    out:serial.Writer
    serial.writer_init(&out,0,context.allocator)
    defer serial.writer_destroy(&out)
    if !testing.expect_value(t,capture(ref,f.app.assets,f.app.allocator,&out),Error.None) {return}
    // The transforms of the broken copy do not decompress.
    broken:=make([]u8,len(serial.writer_bytes(&out)))
    defer delete(broken)
    copy(broken,serial.writer_bytes(&out))
    header:=(cast(^Header)raw_data(broken))^
    body:=broken[mem.align_forward_int(size_of(Header),serial.WRITER_ALIGNMENT):][:header.bytes]
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    file:asset.Asset
    if !testing.expect_value(t,asset.asset_open(&file,body),asset.Error.None) {return}
    view,_:=asset.scene_view(&file,&types)
    entry:asset.Chunk_Entry
    for &component in view.components {
        if component.name=="Transform" {entry=asset.blob_chunk(&file.blob,component.table.columns[1].chunk)}
    }
    asset.asset_close(&file)
    if !testing.expect_value(t,entry.compression,asset.Compression.LZ) {return}
    mem.set(&body[entry.offset],0xff,int(entry.size))

    first:=core.entity_of(&w.entities,1)
    testing.expect_value(t,restore(ref,&f.app,broken),Error.Failed)
    testing.expect_value(t,w.entities.alive,64)
    testing.expect_value(t,core.entity_of(&w.entities,1),first)
    testing.expect_value(t,core.count(&w.transforms),64)
    testing.expect_value(t,host.app_world_count(&f.app),1)

    testing.expect_value(t,restore(ref,&f.app,serial.writer_bytes(&out)),Error.None)
    testing.expect_value(t,w.entities.alive,64)
    testing.expect(t,!core.alive(&w.entities,first))
    again:=core.entity_of(&w.entities,1)
    placed,found:=core.get(core.read(&w.transforms),again)
    testing.expect(t,found && placed.position==[3]f32{1,2,3})
}

// A server saves what a client simulates with the last state it has, without
// what the session keeps on it, whose tables the capture does not touch; the
// slot is the scene the world was once loaded.
@(test)
a_server_saves_what_a_client_simulates_without_the_marks_of_the_session :: proc(t:^testing.T) {
    f:Save_Test
    if !save_test_init(t,&f) {return}
    defer save_test_destroy(&f)
    w:=f.w
    level:=base.Asset_Id{7,9}
    w.root={scene=level,changes=3}
    lent:=core.create(&w.entities)
    core.add(&w.ids,lent,core.Id{5})
    core.add(&w.transforms,lent,core.Transform{position={4,0,0},rotation=1,scale={1,1,1}})
    core.add(&w.remotes,lent,core.Remote{})
    core.add(&w.targets,lent,core.Pose_Target{position={5,0,0},rotation=1,scale={1,1,1},placed=2})
    save_test_settle(w,nil,nil)
    ref:=host.app_world_ref(&f.app,w)
    out:serial.Writer
    serial.writer_init(&out,0,context.allocator)
    defer serial.writer_destroy(&out)
    remotes,targets:=[2]u64{w.remotes.version,w.remotes.layout},[2]u64{w.targets.version,w.targets.layout}
    if !testing.expect_value(t,capture(ref,f.app.assets,f.app.allocator,&out),Error.None) {return}
    target,kept:=core.get(core.read(&w.targets),lent)
    testing.expect(t,core.has(&w.remotes,lent) && kept && target.placed==2,"the session keeps what it has")
    testing.expect_value(t,[2]u64{w.remotes.version,w.remotes.layout},remotes)
    testing.expect_value(t,[2]u64{w.targets.version,w.targets.layout},targets)

    if !testing.expect_value(t,restore(ref,&f.app,serial.writer_bytes(&out)),Error.None) {return}
    again:=core.entity_of(&w.entities,5)
    placed,found:=core.get(core.read(&w.transforms),again)
    testing.expect(t,found && placed.position==[3]f32{4,0,0})
    testing.expect_value(t,core.count(&w.remotes),0)
    testing.expect_value(t,core.count(&w.targets),0)
    testing.expect_value(t,w.root.scene,level)
    testing.expect_value(t,w.root.changes,u32(4))
}

// A world of the application with its folder of slots, served frame by frame.
@(private="file")
Serve :: struct {
    state:Save_State,
    work:Save_Work,
    thumbnails:Save_Thumbnails,
    game:Save_Game,
    settings:Save_Settings,
    requests:Save_Requests,
    results:Save_Results,
    profile:Profile_State,
    network:core.Network,
    frame:core.Frame_Time,
    clock:core.Clock,
    references:core.Table(scene.Scene_Reference),
    problems:^core.Problems,
    folder:string,
}

@(private="file")
serve_init :: proc(t:^testing.T,f:^Save_Test,s:^Serve) -> bool {
    dir,error:=os.make_directory_temp("","mirai-save-*",context.allocator)
    if !testing.expect(t,error==nil) {return false}
    s.folder=dir
    folder_set(&s.state,f.app.allocator,dir)
    s.settings=SAVE_SETTINGS_DEFAULT
    s.profile.read=true
    s.frame.dt=1.0/60
    s.clock=core.CLOCK_DEFAULT
    core.table_init(&s.references,"Scene_Reference")
    s.problems=new(core.Problems)
    return true
}

@(private="file")
serve_destroy :: proc(f:^Save_Test,s:^Serve) {
    saves_release(host.app_world_ref(&f.app,f.w),&s.work,&s.thumbnails,&f.app,&s.state,{},s.problems)
    work_free(&s.work)
    os.remove_all(s.folder)
    delete(s.folder)
    delete(s.state.folder,f.app.allocator)
    delete(s.requests.queue.items)
    delete(s.results.queue.items)
    core.table_destroy(&s.references)
    free(s.problems)
}

// One frame: the requests of the tick before and the autosaves that are due.
@(private="file")
serve :: proc(f:^Save_Test,s:^Serve) {
    saves_serve(
        host.app_world_ref(&f.app,f.w),&f.app,&s.requests,&s.results,&s.state,&s.work,&s.thumbnails,&s.game,core.ref(&s.settings),&s.profile,{},
        core.ref(&s.network),core.ref(&s.frame),core.ref(&s.clock),core.read(&s.references),s.problems,
    )
}

@(private="file")
autosaves_of :: proc(s:^Serve) -> (count:int) {
    for r in s.results.queue.items {if r.op==.Save && r.kind==.Autosave && r.error==.None {count+=1}}
    return
}

@(private="file")
placed_at :: proc(w:^Save_Test_World,id:base.Entity_Id) -> [3]f32 {
    placed,_:=core.get(core.read(&w.transforms),core.entity_of(&w.entities,id))
    return placed.position
}

@(private="file")
place :: proc(w:^Save_Test_World,id:base.Entity_Id,position:[3]f32) {
    core.at(&w.transforms,core.table_row(&w.transforms,core.entity_of(&w.entities,id))).position=position
}

@(private="file")
save_test_entity :: proc(w:^Save_Test_World,id:base.Entity_Id,position:[3]f32) {
    e:=core.create(&w.entities)
    core.add(&w.ids,e,core.Id{id})
    core.add(&w.transforms,e,core.Transform{position=position,rotation=1,scale={1,1,1}})
    save_test_settle(w,nil,nil)
}

// A slot says what it is from its header: its label, kind, scene, time played
// and a thumbnail, the view halved as a PNG; the world after the thumbnail
// loads as it was, and the game with it.
@(test)
a_slot_lists_what_it_is_and_its_thumbnail_without_loading_the_world :: proc(t:^testing.T) {
    f:Save_Test
    if !save_test_init(t,&f) {return}
    defer save_test_destroy(&f)
    s:Serve
    if !serve_init(t,&f,&s) {return}
    defer serve_destroy(&f,&s)
    w:=f.w
    w.root={scene={7,9},changes=1}
    save_test_entity(w,5,{1,2,3})
    ref:=host.app_world_ref(&f.app,w)
    out:serial.Writer
    serial.writer_init(&out,0,context.allocator)
    defer serial.writer_destroy(&out)
    if !testing.expect_value(t,capture(ref,f.app.assets,f.app.allocator,&out,.Checkpoint,"Gate",125.5),Error.None) {return}
    // Columns black and white: each four pixels halve to the gray of their light.
    width,height:=int(THUMBNAIL_SIZE.x)*2,int(THUMBNAIL_SIZE.y)*2
    pixels:=make([]u8,width*height*4)
    defer delete(pixels)
    for y in 0..<height {
        for x in 0..<width {
            v:=x%2==0?u8(0):u8(255)
            at:=(y*width+x)*4
            pixels[at],pixels[at+1],pixels[at+2],pixels[at+3]=v,v,v,255
        }
    }
    path,_:=slot_path(&s.state,&f.app,"gate")
    if !testing.expect_value(t,slot_file_write(path,serial.writer_bytes(&out),pixels),Error.None) {return}

    list:[4]Slot
    if !testing.expect_value(t,slots(&s.state,&f.app,list[:]),1) {return}
    slot:=list[0]
    testing.expect_value(t,slot_name(&slot),"gate")
    testing.expect_value(t,base.text_get(slot.label[:]),"Gate")
    testing.expect_value(t,slot.kind,Slot_Kind.Checkpoint)
    testing.expect_value(t,slot.scene,base.Asset_Id{7,9})
    testing.expect_value(t,slot.played,125.5)
    testing.expect_value(t,slot.entities,1)
    testing.expect(t,abs(slot.written-time.to_unix_seconds(time.now()))<60,"written now")
    testing.expect(t,slot.thumbnail>0)

    png,error:=slot_thumbnail(&s.state,&f.app,"gate")
    defer delete(png)
    if !testing.expect_value(t,error,Error.None) {return}
    x,y,channels:c.int
    decoded:=stbi.load_from_memory(raw_data(png),c.int(len(png)),&x,&y,&channels,3)
    if !testing.expect(t,decoded!=nil) {return}
    defer stbi.image_free(decoded)
    testing.expect(t,x==c.int(THUMBNAIL_SIZE.x) && y==c.int(THUMBNAIL_SIZE.y))
    testing.expect_value(t,decoded[0],180)

    place(w,5,{9,9,9})
    data,read_error:=serial.file_read(path,context.allocator)
    defer delete(data)
    if !testing.expect(t,read_error==.None) {return}
    if !testing.expect_value(t,restore(ref,&f.app,data,&s.game),Error.None) {return}
    testing.expect_value(t,placed_at(w,5),[3]f32{1,2,3})
    testing.expect_value(t,base.text_get(s.game.label[:]),"Gate")
    testing.expect_value(t,s.game.played,125.5)

    // What is not valid does not reach the disk: its result and a problem say so.
    request_save(&s.requests,"gate",strings.repeat("x",LABEL_CAPACITY,context.temp_allocator))
    request_save(&s.requests,"bad/slot")
    serve(&f,&s)
    testing.expect_value(t,s.results.queue.items[0].error,Error.Invalid_Label)
    testing.expect_value(t,s.results.queue.items[1].error,Error.Invalid_Slot)
    testing.expect(t,core.problem_find(s.problems,core.NONE,"save.request")!=nil)
}

// The thumbnail of a slot is a texture of the assets the game shows by its
// id: the same while the slot is not written again, a new one in place of
// the old once it is, none for a slot without one, and gone with a delete
// or the world. A PNG that does not decode is Corrupt.
@(test)
a_thumbnail_becomes_a_texture_the_game_shows_until_the_slot_changes :: proc(t:^testing.T) {
    f:Save_Test
    if !save_test_init(t,&f) {return}
    defer save_test_destroy(&f)
    s:Serve
    if !serve_init(t,&f,&s) {return}
    defer serve_destroy(&f,&s)
    assets:host.Assets
    if !testing.expect(t,host.assets_init(&assets,{root=s.folder,capacity=8})) {return}
    defer host.assets_destroy(&assets)
    _,unavailable:=thumbnail_texture(&s.thumbnails,&s.state,&f.app,"gate")
    testing.expect_value(t,unavailable,Error.Unavailable)
    f.app.assets=&assets
    defer f.app.assets=nil
    save_test_entity(f.w,5,{1,2,3})
    ref:=host.app_world_ref(&f.app,f.w)
    width,height:=int(THUMBNAIL_SIZE.x)*2,int(THUMBNAIL_SIZE.y)*2
    pixels:=make([]u8,width*height*4)
    defer delete(pixels)
    for &value in pixels {value=200}
    write :: proc(t:^testing.T,f:^Save_Test,s:^Serve,ref:core.World_Ref,slot:string,pixels:[]u8) {
        out:serial.Writer
        serial.writer_init(&out,0,context.allocator)
        defer serial.writer_destroy(&out)
        testing.expect_value(t,capture(ref,f.app.assets,f.app.allocator,&out),Error.None)
        path,_:=slot_path(&s.state,&f.app,slot)
        testing.expect_value(t,slot_file_write(path,serial.writer_bytes(&out),pixels),Error.None)
    }
    write(t,&f,&s,ref,"gate",pixels)
    texture,error:=thumbnail_texture(&s.thumbnails,&s.state,&f.app,"gate")
    if !testing.expect_value(t,error,Error.None) {return}
    shown:=host.assets_texture(&assets,texture)
    testing.expect(t,shown!=nil && !shown.failed && shown.generated && shown.width==THUMBNAIL_SIZE.x && shown.height==THUMBNAIL_SIZE.y)
    again,_:=thumbnail_texture(&s.thumbnails,&s.state,&f.app,"gate")
    testing.expect_value(t,again,texture)

    write(t,&f,&s,ref,"gate",pixels)
    fresh,_:=thumbnail_texture(&s.thumbnails,&s.state,&f.app,"gate")
    testing.expect(t,fresh!={} && fresh!=texture,"written again, a new texture")
    testing.expect(t,!host.assets_loaded(&assets,texture),"the old one went")

    write(t,&f,&s,ref,"plain",nil)
    none,none_error:=thumbnail_texture(&s.thumbnails,&s.state,&f.app,"plain")
    testing.expect(t,none=={} && none_error==.None,"no thumbnail, no texture")

    // A PNG whose bytes were damaged does not decode.
    path,_:=slot_path(&s.state,&f.app,"gate")
    data,read_error:=serial.file_read(path,context.allocator)
    defer delete(data)
    if !testing.expect(t,read_error==.None) {return}
    at:=mem.align_forward_int(size_of(Header),serial.WRITER_ALIGNMENT)
    mem.set(&data[at],0,16)
    broken_path,_:=slot_path(&s.state,&f.app,"broken")
    testing.expect(t,os.write_entire_file(broken_path,data)==nil)
    _,corrupt:=thumbnail_texture(&s.thumbnails,&s.state,&f.app,"broken")
    testing.expect_value(t,corrupt,Error.Corrupt)

    request_delete(&s.requests,"gate")
    serve(&f,&s)
    testing.expect(t,!host.assets_loaded(&assets,fresh),"a deleted slot lets go of its texture")
    write(t,&f,&s,ref,"gate",pixels)
    last,_:=thumbnail_texture(&s.thumbnails,&s.state,&f.app,"gate")
    saves_release(host.app_world_ref(&f.app,f.w),&s.work,&s.thumbnails,&f.app,&s.state,{},s.problems)
    testing.expect(t,last!={} && !host.assets_loaded(&assets,last),"the world that goes lets go of them")
    testing.expect_value(t,assets.stats.generated,0)
}

// The header of one slot reads by its name; a file of a slot that does not
// load is listed only when all are asked for, with why.
@(test)
a_slot_that_does_not_load_says_why_and_lists_only_when_asked :: proc(t:^testing.T) {
    f:Save_Test
    if !save_test_init(t,&f) {return}
    defer save_test_destroy(&f)
    s:Serve
    if !serve_init(t,&f,&s) {return}
    defer serve_destroy(&f,&s)
    save_test_entity(f.w,5,{1,2,3})
    if !testing.expect_value(t,write(host.app_world_ref(&f.app,f.w),&f.app,&s.state,"gate",.Checkpoint,"Gate",12),Error.None) {return}
    path,_:=slot_path(&s.state,&f.app,"gate")
    data,read_error:=serial.file_read(path,context.allocator)
    defer delete(data)
    if !testing.expect(t,read_error==.None) {return}
    old:=with_version(data,VERSION-1)
    defer delete(old)
    old_path,_:=slot_path(&s.state,&f.app,"old")
    broken_path,_:=slot_path(&s.state,&f.app,"broken")
    testing.expect(t,os.write_entire_file(old_path,old)==nil && os.write_entire_file(broken_path,transmute([]u8)string("not a save"))==nil)

    info:=slot_info(&s.state,&f.app,"gate")
    testing.expect_value(t,info.error,Error.None)
    testing.expect(t,info.kind==.Checkpoint && info.played==12 && info.entities==1 && info.version==VERSION)
    testing.expect_value(t,base.text_get(info.label[:]),"Gate")
    testing.expect_value(t,info.size,i64(len(data)))
    info=slot_info(&s.state,&f.app,"old")
    testing.expect(t,info.error==.Version && info.version==VERSION-1 && info.size==i64(len(data)) && info.played==0)
    testing.expect_value(t,slot_info(&s.state,&f.app,"broken").error,Error.Corrupt)
    testing.expect_value(t,slot_info(&s.state,&f.app,"missing").error,Error.Not_Found)
    testing.expect_value(t,slot_info(&s.state,&f.app,"COM1").error,Error.Invalid_Slot)
    _,error:=slot_thumbnail(&s.state,&f.app,"old")
    testing.expect_value(t,error,Error.Version)

    list:[4]Slot
    if testing.expect_value(t,slots(&s.state,&f.app,list[:]),1) {testing.expect_value(t,slot_name(&list[0]),"gate")}
    if !testing.expect_value(t,slots(&s.state,&f.app,list[:],all=true),3) {return}
    testing.expect(t,slot_name(&list[0])=="broken" && list[0].error==.Corrupt)
    testing.expect(t,slot_name(&list[1])=="gate" && list[1].error==.None)
    testing.expect(t,slot_name(&list[2])=="old" && list[2].error==.Version)
}

// The bytes of a slot as another version of the engine would have written them.
@(private="file")
with_version :: proc(data:[]u8,version:u32) -> []u8 {
    out:=make([]u8,len(data))
    copy(out,data)
    (cast(^Header)raw_data(out)).version=version
    return out
}

// Autosaves go round their slots, replacing the oldest; a checkpoint takes
// the label of the game and loads back the world and the game it was of.
@(test)
autosaves_go_round_their_slots_and_a_checkpoint_loads_back :: proc(t:^testing.T) {
    f:Save_Test
    if !save_test_init(t,&f) {return}
    defer save_test_destroy(&f)
    s:Serve
    if !serve_init(t,&f,&s) {return}
    defer serve_destroy(&f,&s)
    w:=f.w
    save_test_entity(w,5,{1,2,3})
    s.settings.autosave_slots=2
    for expected,i in ([]string{"autosave 1","autosave 2","autosave 1"}) {
        request_autosave(&s.requests,fmt.tprintf("Save %d",i))
        serve(&f,&s)
        if !testing.expect_value(t,len(s.results.queue.items),1) {return}
        r:=s.results.queue.items[0]
        testing.expect(t,r.kind==.Autosave && r.error==.None,"autosaved")
        testing.expect_value(t,base.text_get(r.slot[:]),expected)
    }
    list:[4]Slot
    testing.expect_value(t,slots(&s.state,&f.app,list[:]),2)
    testing.expect_value(t,base.text_get(list[0].label[:]),"Save 2")

    request_label(&s.requests,"Act 1")
    request_checkpoint(&s.requests)
    serve(&f,&s)
    played:=s.game.played
    place(w,5,{9,9,9})
    serve(&f,&s)
    request_load_checkpoint(&s.requests)
    serve(&f,&s)
    if !testing.expect_value(t,len(s.results.queue.items),1) {return}
    testing.expect_value(t,s.results.queue.items[0].error,Error.None)
    testing.expect_value(t,placed_at(w,5),[3]f32{1,2,3})
    testing.expect_value(t,base.text_get(s.game.label[:]),"Act 1")
    testing.expect_value(t,s.game.played,played)
}

// The game autosaves by itself after its interval of play, when a scene
// replaces another and when a Manual section turns on, but not for the scene
// and the first level it starts with, nor while it is off or a client.
@(test)
autosaves_follow_play_scenes_and_levels_but_not_the_start :: proc(t:^testing.T) {
    f:Save_Test
    if !save_test_init(t,&f) {return}
    defer save_test_destroy(&f)
    s:Serve
    if !serve_init(t,&f,&s) {return}
    defer serve_destroy(&f,&s)
    w:=f.w
    s.settings={autosave_interval=10,autosave_scene=true,autosave_section=true,autosave_slots=3}
    w.root={scene={1,1},changes=1}
    serve(&f,&s)
    testing.expect_value(t,autosaves_of(&s),0)

    level:=core.create(&w.entities)
    core.add(&s.references,level,scene.Scene_Reference{rule=.Manual,state=.Active,loaded={1,2}})
    core.table_settle(&s.references,&w.entities)
    serve(&f,&s)
    testing.expect_value(t,autosaves_of(&s),0)

    core.at(&s.references,0).held=true
    next:=core.create(&w.entities)
    core.add(&s.references,next,scene.Scene_Reference{rule=.Manual,state=.Active,loaded={1,3}})
    core.table_settle(&s.references,&w.entities)
    serve(&f,&s)
    testing.expect_value(t,autosaves_of(&s),1)
    serve(&f,&s)
    testing.expect_value(t,autosaves_of(&s),0)

    w.root={scene={2,1},changes=2}
    serve(&f,&s)
    testing.expect_value(t,autosaves_of(&s),1)

    s.frame.dt=10
    serve(&f,&s)
    testing.expect_value(t,autosaves_of(&s),1)

    request_end_game(&s.requests)
    serve(&f,&s)
    played:=s.game.played
    w.root={scene={3,1},changes=3}
    serve(&f,&s)
    testing.expect_value(t,autosaves_of(&s),0)
    testing.expect_value(t,s.game.played,played)

    request_new_game(&s.requests)
    s.network.role=.Client
    w.root={scene={4,1},changes=4}
    serve(&f,&s)
    testing.expect_value(t,autosaves_of(&s),0)
    request_autosave(&s.requests)
    serve(&f,&s)
    if !testing.expect_value(t,len(s.results.queue.items),1) {return}
    testing.expect_value(t,s.results.queue.items[0].error,Error.Unavailable)
}

// With threads a job writes the slot, and its result comes in the frame it is written.
@(test)
a_job_writes_the_slot_and_its_result_comes_once_it_is_written :: proc(t:^testing.T) {
    f:Save_Test
    if !save_test_init(t,&f) {return}
    defer save_test_destroy(&f)
    if !testing.expect(t,jobs.system_init(&f.app.jobs,{threads=1})) {return}
    defer jobs.system_destroy(&f.app.jobs)
    s:Serve
    if !serve_init(t,&f,&s) {return}
    defer serve_destroy(&f,&s)
    save_test_entity(f.w,5,{1,2,3})
    request_save(&s.requests,"job")
    path,_:=slot_path(&s.state,&f.app,"job")
    for _ in 0..<5000 {
        serve(&f,&s)
        if len(s.results.queue.items)>0 {break}
        time.sleep(time.Millisecond)
    }
    if !testing.expect_value(t,len(s.results.queue.items),1) {return}
    testing.expect_value(t,s.results.queue.items[0].error,Error.None)
    _,_,error:=slot_header(path)
    testing.expect_value(t,error,Error.None)
    testing.expect_value(t,len(s.work.writes),0)
}

// A slot that waits for its thumbnail is written without it once it waited
// too long, and at once before a load of it.
@(test)
a_slot_waiting_for_its_thumbnail_is_written_before_a_load_or_after_a_while :: proc(t:^testing.T) {
    f:Save_Test
    if !save_test_init(t,&f) {return}
    defer save_test_destroy(&f)
    s:Serve
    if !serve_init(t,&f,&s) {return}
    defer serve_destroy(&f,&s)
    w:=f.w
    save_test_entity(w,5,{1,2,3})
    ref:=host.app_world_ref(&f.app,w)
    path,_:=slot_path(&s.state,&f.app,"wait")
    result:=Result{op=.Save}
    base.text_set(result.slot[:],"wait")

    out:serial.Writer
    serial.writer_init(&out,0,context.allocator)
    if !testing.expect_value(t,capture(ref,f.app.assets,f.app.allocator,&out),Error.None) {return}
    s.work.frame=1
    if !testing.expect_value(t,write_queue(&s.work,f.app.renderer,f.app.allocator,result,path,serial.writer_take(&out)),Error.None) {return}
    s.work.writes[0].phase=.Thumbnail
    s.work.drawn=1
    for _ in 0..<THUMBNAIL_WAIT {
        serve(&f,&s)
        testing.expect_value(t,len(s.results.queue.items),0)
    }
    testing.expect(t,!os.exists(path))
    serve(&f,&s)
    if !testing.expect_value(t,len(s.results.queue.items),1) {return}
    header,_,error:=slot_header(path)
    testing.expect(t,error==.None && header.thumbnail==0)

    place(w,5,{4,5,6})
    serial.writer_init(&out,0,context.allocator)
    if !testing.expect_value(t,capture(ref,f.app.assets,f.app.allocator,&out),Error.None) {return}
    if !testing.expect_value(t,write_queue(&s.work,f.app.renderer,f.app.allocator,result,path,serial.writer_take(&out)),Error.None) {return}
    s.work.writes[0].phase=.Thumbnail
    place(w,5,{9,9,9})
    request_load(&s.requests,"wait")
    serve(&f,&s)
    if !testing.expect_value(t,len(s.results.queue.items),2) {return}
    testing.expect(t,s.results.queue.items[0].op==.Save && s.results.queue.items[1].op==.Load && s.results.queue.items[1].error==.None)
    testing.expect_value(t,placed_at(w,5),[3]f32{4,5,6})
}

// An allocator that serves `remaining` requests of its owner and refuses the rest.
@(private="file")
Memory_Limit :: struct {owner:runtime.Allocator,remaining:int}

@(private="file")
memory_limit_proc :: proc(data:rawptr,mode:runtime.Allocator_Mode,size,alignment:int,old_memory:rawptr,old_size:int,loc:=#caller_location) -> ([]byte,runtime.Allocator_Error) {
    limit:=(^Memory_Limit)(data)
    if mode==.Alloc || mode==.Alloc_Non_Zeroed || mode==.Resize || mode==.Resize_Non_Zeroed {
        if limit.remaining<=0 {return nil,.Out_Of_Memory}
        limit.remaining-=1
    }
    return limit.owner.procedure(limit.owner.data,mode,size,alignment,old_memory,old_size,loc)
}

// What the library asks memory for to write a slot, with the memory ending
// at each request in turn: the slot is refused, nothing of it stays, and with
// memory enough it goes through.
@(test)
a_slot_without_memory_is_refused_and_leaves_nothing :: proc(t:^testing.T) {
    f:Save_Test
    if !save_test_init(t,&f) {return}
    defer save_test_destroy(&f)
    s:Serve
    if !serve_init(t,&f,&s) {return}
    defer serve_destroy(&f,&s)
    owner:=f.app.allocator
    limit:=Memory_Limit{owner=owner}
    Step :: enum {Queue,Thumbnail,File}
    for step in Step {
        done,refused:=false,false
        for served in 0..<16 {
            limit.remaining=served
            switch step {
            case .Queue:
                data,_:=make([]u8,64,owner)
                f.app.allocator={memory_limit_proc,&limit}
                error:=write_queue(&s.work,f.app.renderer,f.app.allocator,Result{op=.Save},"slot",data)
                f.app.allocator=owner
                done=error==.None
                if done {
                    work_free(&s.work)
                } else {
                    testing.expect_value(t,error,Error.Failed)
                    testing.expect_value(t,len(s.work.writes),0)
                }
            case .Thumbnail:
                pixels:=make([]u8,int(THUMBNAIL_SIZE.x)*int(THUMBNAIL_SIZE.y)*16,context.temp_allocator)
                limit.owner=context.temp_allocator
                png,made:=thumbnail_png(pixels,{memory_limit_proc,&limit})
                done=made
                testing.expectf(t,made==(len(png)>0),"%d requests served: a thumbnail only when it was made",served)
            case .File:
                pixels:=make([]u8,int(THUMBNAIL_SIZE.x)*int(THUMBNAIL_SIZE.y)*16,context.temp_allocator)
                captured:=make([]u8,mem.align_forward_int(size_of(Header),serial.WRITER_ALIGNMENT)+64,context.temp_allocator)
                path:=fmt.tprintf("%s/limit.save",s.folder)
                limit.owner=context.temp_allocator
                context.temp_allocator={memory_limit_proc,&limit}
                error:=slot_file_write(path,captured,pixels)
                done=error==.None
                if !done {
                    testing.expect_value(t,error,Error.Write_Failed)
                    testing.expect(t,!os.exists(path),"no file of a slot that was not written")
                }
            }
            if done {break}
            refused=true
        }
        testing.expectf(t,done && refused,"%v: refused without memory, and with it it goes through",step)
    }
}

