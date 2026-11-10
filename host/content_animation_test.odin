package host

import cmath "core:math"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"
import "mirai:asset"
import "mirai:core"
import "mirai:platform"
import anim "mirai:std/anim"
import "mirai:std/base"
import "mirai:std/jobs"
import mm "mirai:std/math"

@(private="file")
ANIMATION_ID :: base.Asset_Id{0xa1,1}
@(private="file")
SKELETON_ID :: base.Asset_Id{0x5e,1}

@(private="file")
Animation_Fixture :: struct {
    root,cache:string,
    tracking:mem.Tracking_Allocator,
    assets:Assets,
    app:App,
    types:asset.Types,
}

// A folder with an .anim whose clips play on a .skeleton, and an application without renderer
// that keeps its compressions in a cache folder; with `threads`, it compresses in jobs.
@(private="file")
animation_fixture :: proc(t:^testing.T,f:^Animation_Fixture,name:string,threads:=0) -> bool {
    directory,_:=os.temp_directory(context.temp_allocator)
    f.root=fmt.aprintf("%s/mirai-host-%d-%s",directory,os.get_pid(),name)
    f.cache=fmt.aprintf("%s/cache",f.root)
    os.remove_all(f.root)
    os.make_directory_all(fmt.tprintf("%s/assets",f.root))
    asset.types_init(&f.types)
    animation_fixture_write(t,f,1) or_return
    animation_fixture_skeleton(t,f,.3) or_return
    mem.tracking_allocator_init(&f.tracking,context.allocator)
    allocator:=mem.tracking_allocator(&f.tracking)
    testing.expect(t,assets_init(&f.assets,{root=fmt.tprintf("%s/assets",f.root),capacity=8,allocator=allocator})) or_return
    assets_scan(&f.assets)
    f.app=App{assets=&f.assets,allocator=allocator,animation_cache=f.cache}
    if threads>0 {testing.expect(t,jobs.system_init(&f.app.jobs,{threads=threads,allocator=allocator})) or_return}
    return true
}

@(private="file")
animation_fixture_destroy :: proc(f:^Animation_Fixture) {
    app_content_destroy(&f.app)
    if jobs.worker_count(&f.app.jobs)>0 {jobs.system_destroy(&f.app.jobs)}
    assets_destroy(&f.assets)
    asset.types_destroy(&f.types)
    mem.tracking_allocator_destroy(&f.tracking)
    os.remove_all(f.root)
    delete(f.root);delete(f.cache)
}

// Two clips of a hip that turns and a leg that swings, at `speed`.
@(private="file")
animation_fixture_write :: proc(t:^testing.T,f:^Animation_Fixture,speed:f32) -> bool {
    COUNT :: 61
    hips,leg:[COUNT]anim.Keyframe
    for k in 0..<COUNT {
        phase:=f32(k)/30
        hips[k]={time=phase,value=anim.quat_vec4(mm.quat_axis_angle({1,0,0},cmath.sin(phase*6*speed)*.5))}
        leg[k]={time=phase,value={0,-.4,cmath.sin(phase*4*speed)*.05,0}}
    }
    tracks:=[2]asset.Animation_Track_Desc{{target="hips",property=.Rotation,keys=hips[:]},{target="hips/leg",property=.Position,keys=leg[:]}}
    clips:=[2]asset.Animation_Clip_Desc{{name="walk",tracks=tracks[:],skeleton=SKELETON_ID},{name="run",tracks=tracks[:1],skeleton=SKELETON_ID}}
    path:=fmt.tprintf("%s/assets/walk.anim",f.root)
    return testing.expect_value(t,asset.animation_save(path,&f.types,{id=ANIMATION_ID,clips=clips[:]}),asset.Error.None)
}

@(private="file")
animation_fixture_skeleton :: proc(t:^testing.T,f:^Animation_Fixture,length:f32) -> bool {
    bones:=[2]asset.Skeleton_Bone{{parent=-1,rotation=1,scale={1,1,1}},{parent=0,translation={0,-length,0},rotation=1,scale={1,1,1}}}
    paths:=[2]string{"hips","hips/leg"}
    for &bone,i in bones {base.text_set(bone.path[:],paths[i]);base.text_set(bone.name[:],paths[i]);bone.target=base.name_hash(paths[i])}
    path:=fmt.tprintf("%s/assets/rig.skeleton",f.root)
    return testing.expect_value(t,asset.skeleton_save(path,&f.types,{id=SKELETON_ID,bones=bones[:]}),asset.Error.None)
}

// The files of the cache folder.
@(private="file")
animation_cache_files :: proc(f:^Animation_Fixture) -> []string {
    entries,_:=os.read_all_directory_by_path(f.cache,context.temp_allocator)
    names:=make([dynamic]string,context.temp_allocator)
    for entry in entries {append(&names,strings.clone(entry.name,context.temp_allocator))}
    return names[:]
}

// What every track of every clip gives at a few times.
@(private="file")
animation_samples :: proc(content:^Content_Animation) -> []mm.Vec4 {
    values:=make([dynamic]mm.Vec4,context.temp_allocator)
    for clip in 1..=content.clip_count {
        for track in anim.clip_tracks(&content.lib,anim.Clip(clip)) {
            for step in 0..=40 {append(&values,anim.clip_evaluate(&content.lib,track,f32(step)/20))}
        }
    }
    return values[:]
}

// A compression is kept in the cache: another load takes it without compressing and plays the
// same samples, until the .anim or its skeleton change; a damaged one is compressed and written again.
@(test)
a_compressed_animation_is_kept_in_the_cache_by_what_it_is_made_from :: proc(t:^testing.T) {
    f:Animation_Fixture
    if !animation_fixture(t,&f,"animation-cache") {return}
    defer animation_fixture_destroy(&f)
    app:=&f.app
    content:=content_animation(app,ANIMATION_ID)
    if !testing.expect(t,content!=nil && app.content.stats.compressed==1) {return}
    compressed:=animation_samples(content)
    files:=animation_cache_files(&f)
    if !testing.expect_value(t,len(files),1) {return}
    testing.expect(t,len(compressed)>0)

    app_content_destroy(app)
    content=content_animation(app,ANIMATION_ID)
    if !testing.expect(t,content!=nil && app.content.stats.compressed==0 && app.content.stats.loads==1,"the cache gives it") {return}
    testing.expect(t,content.lib.prepared && content.clip_count==2 && len(content.names)==2)
    cached:=animation_samples(content)
    if testing.expect_value(t,len(cached),len(compressed)) {
        for value,i in cached {if !testing.expect_value(t,value,compressed[i]) {break}}
    }

    // The .anim changes: the load compresses it again, and the old compression goes.
    testing.expect(t,animation_fixture_write(t,&f,2) && assets_refresh(&f.assets,{"walk.anim"}))
    testing.expect_value(t,content_refresh(app),1)
    testing.expect_value(t,app.content.stats.compressed,1)
    after:=animation_cache_files(&f)
    testing.expect(t,len(after)==1 && after[0]!=files[0],"one compression per asset")

    // So does the skeleton it is measured on.
    testing.expect(t,animation_fixture_skeleton(t,&f,.5) && assets_refresh(&f.assets,{"rig.skeleton"}))
    app_content_destroy(app)
    testing.expect(t,content_animation(app,ANIMATION_ID)!=nil && app.content.stats.compressed==1)
    files=animation_cache_files(&f)
    if !testing.expect_value(t,len(files),1) {return}

    // A damaged compression is not trusted: the load compresses and writes it whole.
    path:=fmt.tprintf("%s/%s",f.cache,files[0])
    data,_:=os.read_entire_file(path,context.temp_allocator)
    data[len(data)/2]~=0xff
    testing.expect(t,os.write_entire_file(path,data)==nil)
    app_content_destroy(app)
    testing.expect(t,content_animation(app,ANIMATION_ID)!=nil && app.content.stats.compressed==1,"a damaged one is compressed")
    app_content_destroy(app)
    testing.expect(t,content_animation(app,ANIMATION_ID)!=nil && app.content.stats.compressed==0,"and written whole")

    // Neither is one another build left under the same name whose clips are not those of the
    // .anim: it reads whole, and the load compresses the .anim and writes the cache again.
    files=animation_cache_files(&f)
    if !testing.expect_value(t,len(files),1) {return}
    path=fmt.tprintf("%s/%s",f.cache,files[0])
    stale:asset.Document
    if !testing.expect_value(t,asset.document_load(&stale,path),asset.Error.None) {return}
    table,found:=asset.document_table(&stale,"clips")
    if testing.expect(t,found && stale.tables[table].columns[0].size==size_of(asset.Animation_Clip)) {
        clips:=mem.slice_data_cast([]asset.Animation_Clip,stale.tables[table].columns[0].data)
        base.text_set(clips[0].name[:],"sprint")
        testing.expect_value(t,asset.document_save(&stale,path),asset.Error.None)
    }
    asset.document_destroy(&stale)
    app_content_destroy(app)
    content=content_animation(app,ANIMATION_ID)
    testing.expect(t,content!=nil && app.content.stats.compressed==1 && base.text_get(content.names[0][:])=="walk","a compression of other clips is compressed again")
    app_content_destroy(app)
    testing.expect(t,content_animation(app,ANIMATION_ID)!=nil && app.content.stats.compressed==0,"and the cache holds the .anim again")
}

// With job threads the first load compresses in a job: the .anim is pending until it ends, and a
// reload keeps the library it had meanwhile. Once loaded, asking for it allocates nothing.
@(test)
an_animation_compresses_in_a_job_and_keeps_what_it_had_until_it_ends :: proc(t:^testing.T) {
    f:Animation_Fixture
    if !animation_fixture(t,&f,"animation-jobs",threads=2) {return}
    defer animation_fixture_destroy(&f)
    app:=&f.app
    if !testing.expect(t,content_animation(app,ANIMATION_ID)==nil && content_animation_pending(app,ANIMATION_ID),"it is pending, not failed") {return}
    content:=content_animation_wait(app,ANIMATION_ID)
    if !testing.expect(t,content!=nil && !content_animation_pending(app,ANIMATION_ID) && app.content.stats.compressed==1) {return}
    testing.expect_value(t,len(animation_cache_files(&f)),1)
    generation:=content.generation
    before:=animation_samples(content)

    testing.expect(t,animation_fixture_write(t,&f,2) && assets_refresh(&f.assets,{"walk.anim"}))
    content_refresh(app)
    entry:=&app.content.animations[app.content.index[ANIMATION_ID].index]
    if !testing.expect(t,entry.load!=nil) {return}
    testing.expect(t,content_animation(app,ANIMATION_ID)==content && !content_animation_pending(app,ANIMATION_ID),"the old library plays meanwhile")
    jobs.wait(&app.jobs,jobs.OWNER,&entry.load.counter)
    app_content_adopt(app)
    reloaded:=content_animation(app,ANIMATION_ID)
    testing.expect(t,reloaded==content && reloaded.generation!=generation && app.content.stats.reloads==1)
    after:=animation_samples(reloaded)
    testing.expect(t,len(after)==len(before) && after[3]!=before[3],"the new keys play")

    allocations:=f.tracking.total_allocation_count
    for _ in 0..<8 {testing.expect(t,content_animation(app,ANIMATION_ID)==reloaded)}
    testing.expect_value(t,f.tracking.total_allocation_count,allocations)
}

@(private="file")
Content_Frame_World :: struct {
    using world:core.Test_World,
    time:core.Time,
    frame_time:core.Frame_Time,
    ready:bool, // the fixed tick found the .anim
}

@(private="file")
content_frame_fixed :: proc(world,shared,editor,app:rawptr) {
    (cast(^Content_Frame_World)world).ready=content_animation(cast(^App)app,ANIMATION_ID)!=nil
}

// A load a job ended is taken only at the start of a frame, never by a lookup in the middle of
// one. A frame played again finds pending what it found pending when it played, also after a
// reload, which says that it replaced what those frames read.
@(test)
a_frame_played_again_finds_the_content_it_found_when_it_played :: proc(t:^testing.T) {
    f:Animation_Fixture
    if !animation_fixture(t,&f,"animation-frames",threads=2) {return}
    defer animation_fixture_destroy(&f)
    p,error:=platform.create({headless=true,fixed_dt=1.0/60,pacing=platform.Frame_Pacing{}})
    if !testing.expect_value(t,error,platform.Error.None) {return}
    defer platform.destroy(p)
    w:Content_Frame_World
    if !core.test_world_init(t,&w) {return}
    defer core.test_world_destroy(&w)
    info:=core.test_world_info(&w)
    info.loops[.Game][.Fixed]=content_frame_fixed
    app:=&f.app
    app.info,app.platform,app.tick_dt,app.max_ticks=info,p,1.0/60,4
    defer {delete(app.worlds);assets_marks_free(&app.asset_marks)}
    tick:=f64(app.tick_dt)
    found:=w
    records:[3]Frame_Record

    app_frame_begin(app)
    app_game_frame(app,&w,dt=tick,record=&records[0])
    pending:=content_animation_pending(app,ANIMATION_ID)
    testing.expect(t,!w.ready && pending,"the first tick starts the load")
    entry:=&app.content.animations[app.content.index[ANIMATION_ID].index]
    if !testing.expect(t,entry.load!=nil) {return}
    jobs.wait(&app.jobs,jobs.OWNER,&entry.load.counter)
    pending=content_animation_pending(app,ANIMATION_ID)
    testing.expect(t,content_animation(app,ANIMATION_ID)==nil && pending,"a lookup leaves the job")
    app_game_frame(app,&w,dt=tick,record=&records[1])
    testing.expect(t,!w.ready,"so does a frame that did not begin")
    app_frame_begin(app)
    app_game_frame(app,&w,dt=tick,record=&records[2])
    testing.expect(t,w.ready,"the start of the next frame takes it")

    w=found
    for &record,i in records {
        app_game_frame(app,&w,replay=&record)
        testing.expect_value(t,w.ready,i==2)
    }
    // A tick a network correction runs again finds what it found the first time too.
    for &record,i in records {
        w.ready=i!=2
        app_tick_replay(app,&w,record.content)
        testing.expect_value(t,w.ready,i==2)
    }
    pending=content_animation_pending(app,ANIMATION_ID)
    testing.expect(t,content_animation(app,ANIMATION_ID)!=nil && !pending,"outside a replay it is")

    testing.expect(t,!content_reloaded_after(app,records[2].content))
    testing.expect(t,animation_fixture_write(t,&f,2) && assets_refresh(&f.assets,{"walk.anim"}))
    content_refresh(app)
    if !testing.expect(t,entry.load!=nil) {return}
    jobs.wait(&app.jobs,jobs.OWNER,&entry.load.counter)
    reloaded:=content_reloaded_after(app,records[2].content)
    testing.expect(t,!reloaded,"a reload waits for the start of a frame too")
    app_frame_begin(app)
    reloaded=content_reloaded_after(app,records[2].content)
    testing.expect(t,reloaded,"what the frames read was replaced")
    w=found
    for &record,i in records {
        app_game_frame(app,&w,replay=&record)
        testing.expect_value(t,w.ready,i==2)
    }
}
