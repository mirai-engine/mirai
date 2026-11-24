package save

import "base:intrinsics"
import "base:runtime"
import "core:c"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"
import "core:slice"
import "core:time"
import "mirai:asset"
import "mirai:core"
import "mirai:engine/scene"
import "mirai:host"
import "mirai:std/base"
import "mirai:std/jobs"
import "mirai:std/serial"
import stbi "vendor:stb/image"

@(private)
@(component)
Capture_Value :: struct {value:u32}

Capture_Op :: enum u8 {Add,Edit,Remove}

@(storage,save_prepare="capture_value_prepare")
Capture_Source :: struct {entity:core.Entity,value:u32,reject:bool,op:Capture_Op}

capture_value_prepare :: proc(source:^Capture_Source,world:core.World_Ref) -> bool {
    if source.reject {return false}
    if source.entity==core.NONE {return true}
    table:=core.world_table_of(world,Capture_Value)
    if table==nil {return false}
    switch source.op {
    case .Add: return core.add(table,source.entity,{source.value})
    case .Edit:
        row:=core.row_of(table,source.entity)
        if row<0 {return false}
        core.edit_at(table,row).value=source.value
    case .Remove: core.remove(table,source.entity)
    }
    return true
}

// Counts the copies of the World it is in.
@(storage,copy="copy_counter_copy")
Copy_Counter :: struct {copies:^int}

copy_counter_copy :: proc(dst,src:^Copy_Counter) -> bool {
    if src.copies!=nil {src.copies^+=1}
    dst^=src^
    return true
}

@(private)
@(test_world)
Save_Test_World :: struct {
    using world:Test_World,
    ids:core.Table(core.Id),
    names:core.Table(core.Name),
    transforms:core.Table(core.Transform),
    parents:core.Table(core.Parent),
    disabled:core.Table(core.Disabled),
    remotes:core.Table(core.Remote),
    targets:core.Table(core.Pose_Target),
    references:core.Table(scene.Scene_Reference),
    hierarchy:core.Hierarchy,
    root:scene.Scene_Root,
    time:core.Time,
    capture_source:Capture_Source,
    capture_values:core.Table(Capture_Value),
    copy_counter:Copy_Counter,
}

// The layout of the World and an application that makes it.
@(private="file")
Save_Test :: struct {
    info:core.World_Info,
    app:host.App,
    w:^Save_Test_World,
}

@(private="file")
save_test_init :: proc(t:^testing.T,f:^Save_Test) -> bool {
    described:bool
    f.info,described=test_info(t,Save_Test_World)
    if !described {return false}
    f.app={info=&f.info,allocator=context.allocator}
    f.w=cast(^Save_Test_World)host.app_world_create(&f.app)
    if !testing.expect(t,f.w!=nil) {
        test_info_destroy(&f.info)
        return false
    }
    return true
}

@(private="file")
save_test_destroy :: proc(f:^Save_Test) {
    host.app_world_free(&f.app,f.w)
    delete(f.app.worlds)
    test_info_destroy(&f.info)
}

// An entity without an Id, as a transient copy, travels with one it is lent
// and comes back without it; one of the scene keeps its own.
@(test)
a_transient_entity_comes_back_from_a_save_without_the_id_it_was_lent :: proc(t:^testing.T) {
    f:Save_Test
    if !save_test_init(t,&f) {return}
    defer save_test_destroy(&f)
    for &storage in f.info.storages {
        if storage.type==Capture_Source {storage.procs.save_prepare=nil}
    }
    w:=f.w
    authored,copy:=core.create(&w.entities),core.create(&w.entities)
    core.add(&w.ids,authored,core.Id{5})
    core.add(&w.transforms,authored,core.TRANSFORM_IDENTITY)
    core.add(&w.transforms,copy,core.Transform{position={1,2,3},rotation=1,scale={1,1,1}})
    core.add(&w.parents,copy,core.Parent{entity=authored})
    core.settle(&f.info,w,nil)
    ref:=host.app_world_ref(&f.app,w)
    out:serial.Writer
    serial.writer_init(&out,0,context.allocator)
    defer serial.writer_destroy(&out)
    version,layout,gone:=w.ids.version,w.ids.layout,core.log_end(w.ids.gone)
    revisions,_:=slice.clone(core.world_revisions(ref),context.temp_allocator)
    if !testing.expect_value(t,capture(ref,f.app.assets,f.app.allocator,&out),Error.None) {return}
    testing.expect(t,w.ids.version==version && w.ids.layout==layout && core.log_end(w.ids.gone)==gone)
    testing.expect(t,slice.equal(core.world_revisions(ref),revisions))
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
        placed,_:=core.get(&w.transforms,e)
        parent,found:=core.get(&w.parents,e)
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
    core.settle(&f.info,w,nil)
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
    core.settle(&f.info,w,nil)
    ref:=host.app_world_ref(&f.app,w)
    out:serial.Writer
    serial.writer_init(&out,0,context.allocator)
    defer serial.writer_destroy(&out)
    if !testing.expect_value(t,capture(ref,f.app.assets,f.app.allocator,&out),Error.None) {return}
    // The transforms of the broken copy are a stream that does not decode.
    broken:=make([]u8,len(serial.writer_bytes(&out)))
    defer delete(broken)
    copy(broken,serial.writer_bytes(&out))
    header:=(cast(^Header)raw_data(broken))^
    body:=broken[mem.align_forward_int(size_of(Header),serial.WRITER_ALIGNMENT):][:header.bytes]
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    file:asset.Asset
    if !testing.expect_value(t,asset.asset_open(&file,body),asset.Error.None) {return}
    view,_:=asset.scene_view(&file,&types)
    chunk:=-1
    for &component in view.components {
        if component.name=="Transform" {chunk=component.table.columns[1].chunk}
    }
    entry:asset.Chunk_Entry
    if chunk>=0 {entry=asset.blob_chunk(&file.blob,chunk)}
    asset.asset_close(&file)
    // Stored as they are, the bytes are made a stream that does not decode: the directory says so.
    if !testing.expect(t,chunk>=0 && entry.compression==.None && entry.size>=64) {return}
    mem.set(&body[entry.offset],0xff,int(entry.size))
    entry.compression=.Stream
    intrinsics.unaligned_store((^asset.Chunk_Entry)(&body[asset.HEADER_SIZE+chunk*asset.CHUNK_ENTRY_SIZE]),entry)

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
    placed,found:=core.get(&w.transforms,again)
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
    core.settle(&f.info,w,nil)
    ref:=host.app_world_ref(&f.app,w)
    out:serial.Writer
    serial.writer_init(&out,0,context.allocator)
    defer serial.writer_destroy(&out)
    remotes,targets:=[2]u64{w.remotes.version,w.remotes.layout},[2]u64{w.targets.version,w.targets.layout}
    if !testing.expect_value(t,capture(ref,f.app.assets,f.app.allocator,&out),Error.None) {return}
    target,kept:=core.get(&w.targets,lent)
    testing.expect(t,core.has(&w.remotes,lent) && kept && target.placed==2,"the session keeps what it has")
    testing.expect_value(t,[2]u64{w.remotes.version,w.remotes.layout},remotes)
    testing.expect_value(t,[2]u64{w.targets.version,w.targets.layout},targets)

    if !testing.expect_value(t,restore(ref,&f.app,serial.writer_bytes(&out)),Error.None) {return}
    again:=core.entity_of(&w.entities,5)
    placed,found:=core.get(&w.transforms,again)
    testing.expect(t,found && placed.position==[3]f32{4,0,0})
    testing.expect_value(t,core.count(&w.remotes),0)
    testing.expect_value(t,core.count(&w.targets),0)
    testing.expect_value(t,w.root.scene,level)
    testing.expect_value(t,w.root.changes,u32(4))
}

@(test)
a_slot_capture_prepares_its_saved_components_and_can_be_refused :: proc(t:^testing.T) {
    f:Save_Test
    if !save_test_init(t,&f) {return}
    defer save_test_destroy(&f)
    w:=f.w
    e:=core.create(&w.entities)
    core.add(&w.ids,e,{1})
    core.add(&w.transforms,e,core.TRANSFORM_IDENTITY)
    w.capture_source={entity=e,value=21,reject=true}
    ref:=host.app_world_ref(&f.app,w)
    out:serial.Writer
    serial.writer_init(&out)
    defer serial.writer_destroy(&out)
    testing.expect_value(t,capture(ref,nil,context.allocator,&out),Error.Failed)
    testing.expect(t,out.count==0 && !core.has(&w.capture_values,e))
    w.capture_source.reject=false
    if !testing.expect_value(t,capture(ref,nil,context.allocator,&out),Error.None) {return}
    testing.expect(t,!core.has(&w.capture_values,e) && len(w.ids.pending)==1,"only the snapshot is materialized and settled")
    testing.expect_value(t,restore(ref,&f.app,serial.writer_bytes(&out)),Error.None)
    saved,found:=core.get(&w.capture_values,core.entity_of(&w.entities,1))
    testing.expect(t,found && saved.value==21 && w.capture_source=={})
}

// A save hook writes the components of its library in a snapshot that copies them and the
// entities, and shares the rest of the World: nothing of the World is copied, written or left
// pending, whatever the hook adds, edits or removes. A World that waits for a settle is copied
// whole, to settle the copy.
@(test)
a_save_hook_writes_a_snapshot_of_its_components_without_copying_the_world :: proc(t:^testing.T) {
    Case :: struct {op:Capture_Op,live:Maybe(u32),pending:bool,saved:Maybe(u32),copies:int}
    cases:=[]Case{
        {op=.Add,saved=21},
        {op=.Edit,live=5,saved=21},
        {op=.Remove,live=5},
        {op=.Add,pending=true,saved=21,copies=1},
    }
    for c,i in cases {
        f:Save_Test
        if !save_test_init(t,&f) {return}
        defer save_test_destroy(&f)
        w:=f.w
        copies:=0
        w.copy_counter.copies=&copies
        e:=core.create(&w.entities)
        core.add(&w.ids,e,{1})
        core.add(&w.transforms,e,core.TRANSFORM_IDENTITY)
        if live,ok:=c.live.?;ok {core.add(&w.capture_values,e,{live})}
        // A row off and room for edits: the table holds memory besides its rows.
        off:=core.create(&w.entities)
        core.add(&w.capture_values,off,{3})
        core.disable(&w.capture_values,off)
        core.settle(&f.info,w,nil)
        testing.expect(t,core.table_edit_reserve(&w.capture_values,4))
        aux,edits:=w.capture_values.aux,w.capture_values.edits
        if c.pending {core.add(&w.ids,core.create(&w.entities),{2})}
        w.capture_source={entity=e,value=21,op=c.op}
        ref:=host.app_world_ref(&f.app,w)
        values,transforms:=w.capture_values.version,w.transforms.version
        out:serial.Writer
        serial.writer_init(&out)
        defer serial.writer_destroy(&out)
        if !testing.expectf(t,capture(ref,nil,context.allocator,&out)==.None,"case %d: captured",i) {continue}
        testing.expectf(t,copies==c.copies,"case %d: %d copies of the World, not %d",i,copies,c.copies)
        live,found:=core.get(&w.capture_values,e)
        testing.expectf(t,found==(c.live!=nil) && (!found || live.value==c.live.?),"case %d: the World keeps its value",i)
        testing.expectf(t,w.capture_values.version==values && len(w.capture_values.pending)==0 && w.transforms.version==transforms,"case %d: the World is not written",i)
        testing.expectf(t,w.capture_values.aux==aux && w.capture_values.edits==edits && aux!=nil && edits!=nil && core.count(&w.capture_values)==(c.live!=nil?1:0),"case %d: the table keeps what it holds besides its rows",i)
        testing.expectf(t,len(w.ids.pending)==(c.pending?1:0),"case %d: what the World has pending stays its own",i)
        if !testing.expectf(t,restore(ref,&f.app,serial.writer_bytes(&out))==.None,"case %d: restored",i) {continue}
        saved,kept:=core.get(&w.capture_values,core.entity_of(&w.entities,1))
        testing.expectf(t,kept==(c.saved!=nil) && (!kept || saved.value==c.saved.?),"case %d: the slot holds what the hook wrote",i)
    }
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
    problems:^core.Problems,
    folder:string,
}

@(private="file")
serve_init :: proc(t:^testing.T,f:^Save_Test,s:^Serve) -> bool {
    s.folder=base.test_folder(t,"save")
    if s.folder=="" {return false}
    folder_set(&s.state,f.app.allocator,s.folder)
    s.settings=SAVE_SETTINGS_DEFAULT
    s.profile.read=true
    s.frame.dt=1.0/60
    s.clock=core.CLOCK_DEFAULT
    s.problems=new(core.Problems)
    return true
}

@(private="file")
serve_destroy :: proc(f:^Save_Test,s:^Serve) {
    saves_release(core.world_read(host.app_world_ref(&f.app,f.w)),&s.work,&s.thumbnails,&f.app,&s.state,s.problems)
    work_free(&s.work)
    delete(s.state.folder,f.app.allocator)
    delete(s.requests.queue.items)
    delete(s.results.queue.items)
    free(s.problems)
}

// One frame: the requests of the tick before and the autosaves that are due.
@(private="file")
serve :: proc(f:^Save_Test,s:^Serve) {
    clear(&s.results.queue.items) // the log of a frame, as its readers are handed it
    saves_serve(
        core.world_read(host.app_world_ref(&f.app,f.w)),&f.app,&s.requests,&s.results,&s.state,&s.work,&s.thumbnails,&s.game,
        {core.ref(&s.settings),&s.profile,core.ref(&s.network),core.ref(&s.frame),core.ref(&s.clock),core.read(&f.w.references)},
        s.problems,
    )
}

@(private="file")
autosaves_of :: proc(s:^Serve) -> (count:int) {
    for r in s.results.queue.items {if r.op==.Save && r.kind==.Autosave && r.error==.None {count+=1}}
    return
}

@(private="file")
placed_at :: proc(w:^Save_Test_World,id:base.Entity_Id) -> [3]f32 {
    placed,_:=core.get(&w.transforms,core.entity_of(&w.entities,id))
    return placed.position
}

@(private="file")
place :: proc(w:^Save_Test_World,id:base.Entity_Id,position:[3]f32) {
    core.edit_at(&w.transforms,core.row_of(&w.transforms,core.entity_of(&w.entities,id))).position=position
}

@(private="file")
save_test_entity :: proc(f:^Save_Test,id:base.Entity_Id,position:[3]f32) {
    w:=f.w
    e:=core.create(&w.entities)
    core.add(&w.ids,e,core.Id{id})
    core.add(&w.transforms,e,core.Transform{position=position,rotation=1,scale={1,1,1}})
    core.settle(&f.info,w,nil)
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
    save_test_entity(&f,5,{1,2,3})
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
    save_test_entity(&f,5,{1,2,3})
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
    saves_release(core.world_read(host.app_world_ref(&f.app,f.w)),&s.work,&s.thumbnails,&f.app,&s.state,s.problems)
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
    save_test_entity(&f,5,{1,2,3})
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
    save_test_entity(&f,5,{1,2,3})
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

    // A deadline is a tick of the clock the save keeps: what waited two seconds waits them again.
    w.time={tick=600,seconds=10,dt=1.0/60,playing=true}
    until:=core.deadline(w.time,2)
    request_label(&s.requests,"Act 1")
    request_checkpoint(&s.requests)
    serve(&f,&s)
    played:=s.game.played
    place(w,5,{9,9,9})
    w.time.tick,w.time.seconds=900,15
    testing.expect(t,core.due(w.time,until))
    serve(&f,&s)
    request_load_checkpoint(&s.requests)
    serve(&f,&s)
    if !testing.expect_value(t,len(s.results.queue.items),1) {return}
    testing.expect_value(t,s.results.queue.items[0].error,Error.None)
    testing.expect_value(t,placed_at(w,5),[3]f32{1,2,3})
    testing.expect_value(t,w.time.tick,u64(600))
    testing.expect(t,!core.due(w.time,until) && until-w.time.tick==core.ticks_of(w.time,2))
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
    core.add(&w.references,level,scene.Scene_Reference{rule=.Manual,state=.Active,loaded={1,2}})
    core.settle(&f.info,w,nil)
    serve(&f,&s)
    testing.expect_value(t,autosaves_of(&s),0)

    core.edit_at(&w.references,0).held=true
    next:=core.create(&w.entities)
    core.add(&w.references,next,scene.Scene_Reference{rule=.Manual,state=.Active,loaded={1,3}})
    core.settle(&f.info,w,nil)
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
    save_test_entity(&f,5,{1,2,3})
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
    save_test_entity(&f,5,{1,2,3})
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

// Serves frames until the slots captured are written, keeping the results of each.
@(private="file")
serve_written :: proc(f:^Save_Test,s:^Serve,results:^[dynamic]Result) {
    for _ in 0..<5000 {
        serve(f,s)
        append(results,..s.results.queue.items[:])
        if len(s.work.writes)==0 {return}
        time.sleep(time.Millisecond)
    }
}

// However a slot is written, its scene is compressed by the write, not by the frame that captured
// it, and loads back as it was: a save, an autosave and a checkpoint that a job writes, two saves
// of a slot back to back, a save that a load of it writes before its job ran, one that a world
// that goes writes, and a write at once.
@(test)
a_slot_is_compressed_where_it_is_written_and_loads_back :: proc(t:^testing.T) {
    Flow :: enum {Save,Autosave,Checkpoint,Back_To_Back,Loaded_At_Once,Released,At_Once}
    for flow in Flow {
        f:Save_Test
        if !save_test_init(t,&f) {return}
        defer save_test_destroy(&f)
        if !testing.expect(t,jobs.system_init(&f.app.jobs,{threads=1})) {return}
        defer jobs.system_destroy(&f.app.jobs)
        s:Serve
        if !serve_init(t,&f,&s) {return}
        defer serve_destroy(&f,&s)
        w:=f.w
        for id in 1..=64 {save_test_entity(&f,base.Entity_Id(id),{1,2,3})}
        ref:=host.app_world_ref(&f.app,w)
        slot,placed:="slot",[3]f32{1,2,3}
        results:=make([dynamic]Result,context.temp_allocator)
        switch flow {
        case .Save:
            request_save(&s.requests,slot)
            serve_written(&f,&s,&results)
        case .Autosave:
            slot=autosave_name(1)
            request_autosave(&s.requests)
            serve_written(&f,&s,&results)
        case .Checkpoint:
            slot=CHECKPOINT
            request_checkpoint(&s.requests)
            serve_written(&f,&s,&results)
        case .Back_To_Back:
            request_save(&s.requests,slot)
            serve(&f,&s)
            append(&results,..s.results.queue.items[:])
            placed={4,5,6}
            place(w,1,placed)
            request_save(&s.requests,slot)
            serve_written(&f,&s,&results)
        case .Loaded_At_Once:
            request_save(&s.requests,slot)
            request_load(&s.requests,slot)
            serve(&f,&s)
            append(&results,..s.results.queue.items[:])
        case .Released:
            out:serial.Writer
            serial.writer_init(&out,0,f.app.allocator)
            if !testing.expect_value(t,capture(ref,f.app.assets,f.app.allocator,&out),Error.None) {continue}
            path,_:=slot_path(&s.state,&f.app,slot)
            if !testing.expect_value(t,write_queue(&s.work,f.app.renderer,f.app.allocator,{op=.Save},path,serial.writer_take(&out)),Error.None) {continue}
            s.work.writes[0].phase=.Thumbnail
            saves_release(core.world_read(ref),&s.work,&s.thumbnails,&f.app,&s.state,s.problems)
            testing.expect_value(t,len(s.work.writes),0)
        case .At_Once:
            testing.expect_value(t,write(ref,&f.app,&s.state,slot),Error.None)
        }
        for &r in results {testing.expectf(t,r.error==.None,"%v: %v of %s: %v",flow,r.op,base.text_get(r.slot[:]),r.error)}
        path,_:=slot_path(&s.state,&f.app,slot)
        header,_,error:=slot_header(path)
        if !testing.expectf(t,error==.None,"%v: written",flow) {continue}
        testing.expectf(t,header.stored>0 && header.stored<header.bytes,"%v: compressed, %d bytes of %d",flow,header.stored,header.bytes)
        place(w,1,{9,9,9})
        testing.expectf(t,read(ref,&f.app,&s.state,slot)==.None && placed_at(w,1)==placed,"%v: loads back",flow)
    }
}

// A slot that cannot be written says why in its result, and one whose scene was damaged does not
// load and leaves the world as it was.
@(test)
a_slot_that_is_not_written_or_is_damaged_says_why :: proc(t:^testing.T) {
    Case :: enum {Unwritable,Damaged,Truncated}
    for c in Case {
        f:Save_Test
        if !save_test_init(t,&f) {return}
        defer save_test_destroy(&f)
        if !testing.expect(t,jobs.system_init(&f.app.jobs,{threads=1})) {return}
        defer jobs.system_destroy(&f.app.jobs)
        s:Serve
        if !serve_init(t,&f,&s) {return}
        defer serve_destroy(&f,&s)
        w:=f.w
        for id in 1..=16 {save_test_entity(&f,base.Entity_Id(id),{1,2,3})}
        results:=make([dynamic]Result,context.temp_allocator)
        if c==.Unwritable {
            blocker:=fmt.tprintf("%s/blocker",s.folder)
            testing.expect(t,os.write_entire_file(blocker,[]u8{1})==nil)
            folder_set(&s.state,f.app.allocator,fmt.tprintf("%s/saves",blocker))
        }
        request_save(&s.requests,"slot")
        serve_written(&f,&s,&results)
        if !testing.expectf(t,len(results)==1,"%v: one result",c) {continue}
        if c==.Unwritable {
            testing.expectf(t,results[0].error==.Write_Failed,"%v: %v",c,results[0].error)
            continue
        }
        path,_:=slot_path(&s.state,&f.app,"slot")
        data,read_error:=os.read_entire_file(path,context.temp_allocator)
        if !testing.expect(t,read_error==nil) {continue}
        header:=(cast(^Header)raw_data(data))^
        at:=mem.align_forward_int(size_of(Header),serial.WRITER_ALIGNMENT)
        switch c {
        case .Unwritable:
        case .Damaged:
            for &b in data[at+int(header.stored)/2:][:min(32,int(header.stored)/2)] {b~=0xa5}
        case .Truncated:
            (cast(^Header)raw_data(data)).stored=header.stored/2
        }
        testing.expect(t,os.write_entire_file(path,data)==nil)
        place(w,1,{9,9,9})
        error:=read(host.app_world_ref(&f.app,w),&f.app,&s.state,"slot")
        testing.expectf(t,error==.Corrupt,"%v: %v",c,error)
        testing.expectf(t,placed_at(w,1)==[3]f32{9,9,9} && core.count(&w.ids)==16,"%v: the world stays",c)
    }
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
    save_test_entity(&f,5,{1,2,3})
    out:serial.Writer
    serial.writer_init(&out,0,context.allocator)
    defer serial.writer_destroy(&out)
    if !testing.expect_value(t,capture(host.app_world_ref(&f.app,f.w),nil,context.allocator,&out),Error.None) {return}
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
                path:=fmt.tprintf("%s/limit.save",s.folder)
                limit.owner=context.temp_allocator
                context.temp_allocator={memory_limit_proc,&limit}
                error:=slot_file_write(path,serial.writer_bytes(&out),pixels)
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

