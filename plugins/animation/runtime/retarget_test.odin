package anim

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:strings"
import "core:testing"
import "core:math/linalg"
import "mirai:std/jobs"
import "mirai:asset"
import "mirai:core"
import scene "mirai:engine/scene"
import "mirai:host"
import lib "mirai:std/anim"
import "mirai:std/base"
import mm "mirai:std/math"

@(private="file")
RETARGET_DT :: f32(1.0/60)

// Skeletons of the fixture: a source of other names and proportions than the target, a variant of
// the source with a weapon bone, a copy of the source under another id, and one no file holds.
@(private="file") RETARGET_SOURCE :: base.Asset_Id{0x5e7,1}
@(private="file") RETARGET_TARGET :: base.Asset_Id{0x5e7,2}
@(private="file") RETARGET_VARIANT :: base.Asset_Id{0x5e7,3}
@(private="file") RETARGET_COPY :: base.Asset_Id{0x5e7,4}
@(private="file") RETARGET_MISSING :: base.Asset_Id{0x5e7,5}
// Clips: moves.anim holds kick, made on the source, and bow, made on the target; kick.anim holds
// kick alone; orphan.anim a kick made on the skeleton no file holds.
@(private="file") RETARGET_MOVES :: base.Asset_Id{0x5e7,20}
@(private="file") RETARGET_KICK :: base.Asset_Id{0x5e7,21}
@(private="file") RETARGET_ORPHAN :: base.Asset_Id{0x5e7,22}
// The bone of the left knee of the target in a rig, after the entity that wraps it.
@(private="file") RETARGET_CALF :: 8

@(private="file")
Retarget_Assets :: struct {
    directory:string,
    assets:host.Assets,
    app:host.App,
    meshes:[4]base.Asset_Id, // of the source, the target, the variant and the copy
}

// The cooked retarget of moves.anim onto the target, as the cook of a game writes it.
@(private="file") RETARGET_COOKED :: "moves.retarget.anim"

@(private="file")
Retarget_Test :: struct {
    using w:Rig_World,
    cache:Skeleton_Assets,
    characters:Character_Assets,
    sources:Source_Assets,
    simulation:scene.Simulation_Sources,
    fields:Field_Playback,
    problems:core.Problems,
    tracking:mem.Tracking_Allocator, // of sources
    markers:int,                     // crossed with the .anim of the clip as theirs
}

@(private="file")
Retarget_Bone :: struct {name:string,parent:i32,at:mm.Vec3,part:Maybe(lib.Body_Part)}

// Bones parents first, named as their paths, with the parts of the body they carry.
@(private="file")
retarget_skeleton_save :: proc(t:^testing.T,a:^Retarget_Assets,types:^asset.Types,id:base.Asset_Id,file:string,rows:[]Retarget_Bone) -> bool {
    bones:=make([]asset.Skeleton_Bone,len(rows),context.temp_allocator)
    marked:=make([dynamic]asset.Skeleton_Body_Part,context.temp_allocator)
    for row,i in rows {
        bones[i]={parent=row.parent,translation=row.at,rotation=1,scale={1,1,1},target=base.name_hash(row.name)}
        base.text_set(bones[i].name[:],row.name);base.text_set(bones[i].path[:],row.name)
        if part,marks:=row.part.?;marks {
            append(&marked,asset.Skeleton_Body_Part{part=part,confidence=1})
            base.text_set(marked[len(marked)-1].bone[:],row.name)
        }
    }
    body:=asset.Skeleton_Body{up={0,1,0},confidence=1}
    desc:=asset.Skeleton_Desc{id=id,bones=bones,body=&body,body_parts=marked[:]}
    return testing.expect_value(t,asset.skeleton_save(fmt.tprintf("%s/%s.skeleton",a.directory,file),types,desc),asset.Error.None)
}

// The source names its bones as an import from another tool, the target as Mirai, at other lengths
// and with a longer spine: they pair only by the parts of the body both mark. The variant adds a
// weapon bone to the source.
@(private="file")
RETARGET_SOURCE_BONES :: [10]Retarget_Bone{
    {"Hips",-1,{0,1,0},.Pelvis},{"Spine",0,{0,.2,0},nil},{"Neck",1,{0,.3,0},.Neck},
    {"LeftUpLeg",0,{.1,-.05,0},.Hip_L},{"LeftLeg",3,{0,-.45,0},.Knee_L},{"LeftFoot",4,{0,-.45,0},.Foot_L},
    {"RightUpLeg",0,{-.1,-.05,0},.Hip_R},{"RightLeg",6,{0,-.45,0},.Knee_R},{"RightFoot",7,{0,-.45,0},.Foot_R},
    {"Weapon",0,{.3,0,0},nil},
}
@(private="file")
RETARGET_TARGET_BONES :: [12]Retarget_Bone{
    {"root",-1,{},nil},{"pelvis",0,{0,.8,0},.Pelvis},{"spine_01",1,{0,.15,0},nil},{"spine_02",2,{0,.15,0},nil},
    {"spine_03",3,{0,.15,0},nil},{"neck",4,{0,.15,0},.Neck},
    {"thigh_l",1,{.08,-.04,0},.Hip_L},{"calf_l",6,{0,-.36,0},.Knee_L},{"foot_l",7,{0,-.36,0},.Foot_L},
    {"thigh_r",1,{-.08,-.04,0},.Hip_R},{"calf_r",9,{0,-.36,0},.Knee_R},{"foot_r",10,{0,-.36,0},.Foot_R},
}

@(private="file")
// cooked: with the retarget of moves.anim onto the target a cook writes; shipped: moves.anim as a
// cook writes it, its clips compressed into streams.
retarget_assets :: proc(t:^testing.T,a:^Retarget_Assets,name:string,cooked:=false,shipped:=false) -> bool {
    a.directory=base.test_folder(t,name)
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    source,target:=RETARGET_SOURCE_BONES,RETARGET_TARGET_BONES
    if !retarget_skeleton_save(t,a,&types,RETARGET_SOURCE,"source",source[:9]) {return false}
    if !retarget_skeleton_save(t,a,&types,RETARGET_COPY,"copy",source[:9]) {return false}
    if !retarget_skeleton_save(t,a,&types,RETARGET_VARIANT,"variant",source[:]) {return false}
    if !retarget_skeleton_save(t,a,&types,RETARGET_TARGET,"target",target[:]) {return false}
    vertices:=[3]asset.Vertex{{position={-1,0,0},color=0xffffffff},{position={1,0,0},color=0xffffffff},{position={0,1,0},color=0xffffffff}}
    influences:[3]asset.Skin_Vertex
    for &influence in influences {influence.weights[0]=255}
    joints:=[1]asset.Rig_Joint{{node=0,inverse_bind=1}}
    for skeleton,i in ([4]base.Asset_Id{RETARGET_SOURCE,RETARGET_TARGET,RETARGET_VARIANT,RETARGET_COPY}) {
        a.meshes[i]={0x5e7,u64(10+i)}
        if !testing.expect_value(t,rig_mesh_save(fmt.tprintf("%s/rig%d.mesh",a.directory,i),&types,{id=a.meshes[i],skeleton=skeleton,joints=joints[:]},vertices[:],{0,1,2},influences[:]),asset.Error.None) {return false}
    }
    // The left knee of the source bends forward and back over a second while its hips go ahead; a
    // face curve rises and a marker sits at a quarter.
    bend:=[3]lib.Keyframe{{time=0,value=lib.quat_vec4(1)},{time=.5,value=lib.quat_vec4(mm.quat_axis_angle({1,0,0},.8))},{time=1,value=lib.quat_vec4(1)}}
    ahead:=[2]lib.Keyframe{{time=0,value={0,1,0,0}},{time=1,value={0,1,-1,0}}}
    smile:=[2]lib.Keyframe{{time=0,value={0,0,0,0}},{time=1,value={1,0,0,0}}}
    tracks:=[3]asset.Animation_Track_Desc{{target="LeftLeg",property=.Rotation,keys=bend[:]},{target="Hips",property=.Position,keys=ahead[:]},{target="Smile",property=.Float,keys=smile[:]}}
    markers:=[1]asset.Animation_Marker_Desc{{time=.25,name="hit"}}
    kick:=asset.Animation_Clip_Desc{name="kick",tracks=tracks[:],markers=markers[:],skeleton=RETARGET_SOURCE}
    base.text_set(kick.root.bone[:],"Hips");kick.root.translation=true
    turn:=[2]lib.Keyframe{{time=0,value=lib.quat_vec4(1)},{time=1,value=lib.quat_vec4(mm.quat_axis_angle({1,0,0},.4))}}
    bowed:=[1]asset.Animation_Track_Desc{{target="spine_02",property=.Rotation,keys=turn[:]}}
    bow:=asset.Animation_Clip_Desc{name="bow",tracks=bowed[:],skeleton=RETARGET_TARGET}
    orphan:=kick;orphan.skeleton=RETARGET_MISSING
    File :: struct {id:base.Asset_Id,name:string,clips:[]asset.Animation_Clip_Desc}
    moves,alone,lost:=[2]asset.Animation_Clip_Desc{kick,bow},[1]asset.Animation_Clip_Desc{kick},[1]asset.Animation_Clip_Desc{orphan}
    for file in ([3]File{{RETARGET_MOVES,"moves",moves[:]},{RETARGET_KICK,"kick",alone[:]},{RETARGET_ORPHAN,"orphan",lost[:]}}) {
        if !testing.expect_value(t,asset.animation_save(fmt.tprintf("%s/%s.anim",a.directory,file.name),&types,{id=file.id,clips=file.clips}),asset.Error.None) {return false}
    }
    if !testing.expect(t,host.assets_init(&a.assets,{root=a.directory})) {return false}
    if cooked {
        file:asset.Asset
        if !testing.expect_value(t,asset.asset_load(&file,fmt.tprintf("%s/moves.anim",a.directory),context.temp_allocator),asset.Error.None) {return false}
        defer asset.asset_close(&file)
        view,error:=asset.animation_view(&file,&types)
        if !testing.expect_value(t,error,asset.Error.None) {return false}
        doc:asset.Document
        made:=asset.animation_retarget_cooked(&doc,&types,asset.animation_retarget_id(RETARGET_MOVES,RETARGET_TARGET),{},view,asset.skeleton_open_registry,&a.assets.registry,RETARGET_TARGET)
        if !testing.expect(t,made.failure==.None && !made.direct) {return false}
        defer asset.document_destroy(&doc)
        if !testing.expect_value(t,asset.document_save(&doc,fmt.tprintf("%s/%s",a.directory,RETARGET_COOKED)),asset.Error.None) {return false}
        if !testing.expect(t,host.assets_scan(&a.assets)) {return false}
    }
    if shipped {
        path:=fmt.tprintf("%s/moves.anim",a.directory)
        file:asset.Asset
        if !testing.expect_value(t,asset.asset_load(&file,path,context.temp_allocator),asset.Error.None) {return false}
        view,error:=asset.animation_view(&file,&types)
        if !testing.expect_value(t,error,asset.Error.None) {return false}
        desc:=asset.animation_library_desc(view);desc.allocator=context.temp_allocator
        library:lib.Library
        if !testing.expect(t,lib.library_init(&library,desc) && asset.animation_clips_add(view,&library)!=0) {return false}
        defer lib.library_destroy(&library)
        _,compressed:=asset.animation_compress(view,&library,&types,asset.skeleton_open_registry,&a.assets.registry)
        if !testing.expect_value(t,compressed,lib.Compress_Error.None) {return false}
        doc:asset.Document
        if !testing.expect_value(t,asset.animation_cooked_document(&doc,&types,RETARGET_MOVES,{},view,&library,context.temp_allocator),asset.Error.None) {return false}
        defer asset.document_destroy(&doc)
        asset.asset_close(&file)
        if !testing.expect_value(t,asset.document_save(&doc,path),asset.Error.None) {return false}
        if !testing.expect(t,host.assets_refresh(&a.assets,{"moves.anim"})) {return false}
    }
    a.app=host.App{assets=&a.assets,allocator=context.allocator}
    // Retargets are made in jobs, as in the editor and the player.
    if !testing.expect(t,jobs.system_init(&a.app.jobs,{threads=2})) {return false}
    for id in ([3]base.Asset_Id{RETARGET_MOVES,RETARGET_KICK,RETARGET_ORPHAN}) {
        if !testing.expect(t,host.content_animation_wait(&a.app,id)!=nil) {return false}
    }
    return true
}

@(private="file")
retarget_assets_destroy :: proc(a:^Retarget_Assets) {host.app_content_destroy(&a.app);jobs.system_destroy(&a.app.jobs);host.assets_destroy(&a.assets)}

@(private="file")
retarget_init :: proc(t:^testing.T,f:^Retarget_Test) -> bool {
    mem.tracking_allocator_init(&f.tracking,context.allocator)
    f.sources.allocator=mem.tracking_allocator(&f.tracking)
    return test_world_init(t,&f.w)
}

@(private="file")
retarget_destroy :: proc(f:^Retarget_Test) {
    test_world_destroy(&f.w)
    skeleton_assets_free(&f.cache);character_assets_free(&f.characters);source_assets_free(&f.sources)
    field_playback_free(&f.fields)
    mem.tracking_allocator_destroy(&f.tracking)
}

@(private="file")
retarget_rig :: proc(f:^Retarget_Test,a:^Retarget_Assets,mesh:base.Asset_Id,clips:base.Asset_Id,x:f32) -> core.Entity {
    rig:=core.create(&f.entities)
    place:=core.TRANSFORM_IDENTITY;place.position={x,0,0}
    core.add(&f.transforms,rig,place)
    core.add(&f.meshes,rig,{mesh=mesh})
    animation:=ANIMATION_DEFAULT;animation.asset=clips;animation.root_motion=.Extract;animation.fade=0
    base.text_set(animation.clip[:],"kick")
    core.add(&f.animations,rig,animation)
    test_world_settle(&f.w)
    return rig
}

// One frame of the application with one fixed tick of the animation, as the loop runs them: the
// frame first takes the loads whose jobs ended. Counts the markers whose .anim is that of the clip.
@(private="file")
retarget_step :: proc(f:^Retarget_Test,app:^host.App,tick:u64) {
    host.app_content_adopt(app)
    time:=core.Time{tick=tick,dt=RETARGET_DT,playing=true}
    test_world_settle(&f.w)
    rigs_update(&f.playback,core.read(&f.meshes),core.read(&f.skins),app.assets,core.read(&f.attachments))
    f.playback.prepared=true
    clear(&f.events.items)
    animation_sample(core.read(&f.animations),core.read(&f.progress),&f.played,&f.transforms,core.read(&f.parents),{},core.read(&f.labels),core.read(&f.targets),core.read(&f.remotes),&f.requests,&f.events,&f.modifiers,&f.playback,&f.characters,&f.cache,app,time,{},&f.problems,&f.actions,&f.motion,&f.sources,{},core.CLOCK_DEFAULT,ANIMATION_BUDGET_CONFIG_DEFAULT,core.ref(&f.simulation),core.ref(&f.fields))
    animation_advance(&f.transforms,core.read(&f.parents),core.read(&f.worlds),&f.requests,&f.modifiers,&f.playback,{},{},time,{},&f.problems,&f.motion,&f.characters,{},{},core.CLOCK_DEFAULT,nil)
    for event in f.events.items {if event.kind==.Marker && event.name==base.name_hash("hit") && (event.animation==RETARGET_MOVES || event.animation==RETARGET_KICK) {f.markers+=1}}
}

@(private="file")
retarget_problems :: proc(t:^testing.T,f:^Retarget_Test,loc:=#caller_location) {
    for &problem in core.problems_list(&f.problems) {
        testing.expectf(t,false,"%s: %s",base.text_get(problem.code[:]),base.text_get(problem.text[:]),loc=loc)
    }
}

// The entry of the content for the retarget of a library onto a skeleton, whatever its state.
@(private="file")
retarget_entry :: proc(app:^host.App,library,skeleton:base.Asset_Id) -> ^host.Content_Animation {
    if app.content==nil {return nil}
    ref,known:=app.content.index[asset.animation_retarget_id(library,skeleton)]
    return &app.content.animations[ref.index] if known else nil
}

// How many retargets the content holds.
@(private="file")
retarget_count :: proc(app:^host.App) -> (count:int) {
    if app.content==nil {return}
    for &entry in app.content.animations {if entry.id!={} && entry.retarget.skeleton!={} {count+=1}}
    return
}

// Waits for the job that makes a retarget, which the next frame takes.
@(private="file")
retarget_job_wait :: proc(app:^host.App,library,skeleton:base.Asset_Id) {
    if entry:=retarget_entry(app,library,skeleton);entry!=nil && entry.load!=nil {jobs.wait(&app.jobs,jobs.OWNER,&entry.load.counter)}
}

// How far a bone of a rig turned from its rest, in radians.
@(private="file")
retarget_bend :: proc(f:^Retarget_Test,rig:core.Entity,bone:int) -> f32 {
    state:=constraint_playing(core.ref(&f.playback),rig)
    if state==nil || bone>=len(playing_pose(state,.Local)) {return -1}
    return mm.quat_angle(playing_topology(state).rest[bone].rotation,playing_pose(state,.Local)[bone].rotation)
}

@(private="file")
retarget_curve :: proc(state:^Playing,name:string) -> f32 {
    for curve in state.curves {if curve.target==base.name_hash(name) {return curve.value.x}}
    return -1
}

// Two rigs of the target play clips made on a source of other names: they share one retarget of
// the library onto it, played by name (the knee of the source bends the knee of the target),
// keeping its curves, markers and the clip made on the target; stable ticks allocate nothing, the
// retarget is made again when its .anim changes, and the rigs follow it.
@(test)
rigs_of_a_skeleton_share_one_retarget_of_a_library_made_on_another :: proc(t:^testing.T) {
    a:Retarget_Assets;if !retarget_assets(t,&a,"retarget-shared") {return};defer retarget_assets_destroy(&a)
    f:Retarget_Test;if !retarget_init(t,&f) {return};defer retarget_destroy(&f)
    first,second:=retarget_rig(&f,&a,a.meshes[1],RETARGET_MOVES,0),retarget_rig(&f,&a,a.meshes[1],RETARGET_MOVES,2)
    if _,fault:=host.content_animation_retarget_wait(&a.app,RETARGET_MOVES,RETARGET_TARGET);!testing.expect(t,fault.failure==.None) {return}
    for tick in 0..<u64(30) {retarget_step(&f,&a.app,tick)}
    retarget_problems(t,&f)
    library:=retarget_entry(&a.app,RETARGET_MOVES,RETARGET_TARGET)
    if !testing.expect(t,library!=nil && !library.retarget.direct && !library.failed && retarget_count(&a.app)==1) {return}
    testing.expect(t,library.id==RETARGET_MOVES && library.retarget.bytes>0 && a.app.content.retarget_bytes==library.retarget.bytes)
    one,other:=constraint_playing(core.ref(&f.playback),first),constraint_playing(core.ref(&f.playback),second)
    if !testing.expect(t,one!=nil && other!=nil) {return}
    testing.expect(t,one.generation==library.generation && other.generation==library.generation)
    testing.expect(t,one.tracks!=0 && one.tracks==other.tracks,"both rigs bind the same tracks")
    testing.expect(t,animation_playing_content(core.ref(&f.sources),&a.app,one)==library)
    for rig in ([2]core.Entity{first,second}) {
        bend:=retarget_bend(&f,rig,RETARGET_CALF)
        testing.expectf(t,abs(bend-.8)<.02,"the knee of the target bends %v at half a second",bend)
    }
    testing.expectf(t,abs(retarget_curve(one,"Smile")-.5)<.05,"the face curve is %v",retarget_curve(one,"Smile"))
    testing.expectf(t,f.markers==2,"%d markers crossed with the .anim of their clip",f.markers)
    testing.expect(t,base.text_get(library.roots[0].bone[:])=="pelvis" && library.roots[0].translation)
    testing.expect(t,library.skeletons[0]==RETARGET_TARGET && library.skeletons[1]==RETARGET_TARGET)
    moves:=host.content_animation(&a.app,RETARGET_MOVES)
    kept,own:=lib.clip_tracks(&library.lib,2),lib.clip_tracks(&moves.lib,2)
    testing.expect(t,len(kept)==len(own) && len(kept)>0 && kept[0].target==own[0].target,"the clip made on the target keeps its tracks")
    // Stable ticks allocate nothing, in the cache or anywhere.
    allocations:=f.tracking.total_allocation_count
    saved:=context;context.allocator=runtime.nil_allocator();context.temp_allocator=runtime.nil_allocator();a.app.allocator=runtime.nil_allocator()
    for tick in 30..<u64(90) {retarget_step(&f,&a.app,tick)}
    context=saved;a.app.allocator=context.allocator
    testing.expectf(t,f.tracking.total_allocation_count==allocations && f.problems.count==0,"%d allocations and %d problems in stable ticks",f.tracking.total_allocation_count-allocations,f.problems.count)
    retarget_problems(t,&f)
    // A skeleton its clips were made on changes: the retarget is made again in a job, and the
    // rigs follow it.
    made:=library.generation
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    bones:=RETARGET_SOURCE_BONES
    bones[4].at.y=-.5
    if !retarget_skeleton_save(t,&a,&types,RETARGET_SOURCE,"source",bones[:9]) {return}
    testing.expect(t,host.assets_refresh(&a.assets,{"source.skeleton"}))
    host.content_refresh(&a.app)
    retarget_job_wait(&a.app,RETARGET_MOVES,RETARGET_TARGET)
    for tick in 90..<u64(92) {retarget_step(&f,&a.app,tick)}
    library=retarget_entry(&a.app,RETARGET_MOVES,RETARGET_TARGET)
    testing.expect(t,retarget_count(&a.app)==1 && library.generation!=made && !library.failed)
    testing.expect(t,one.generation==library.generation && other.generation==library.generation)
    retarget_problems(t,&f)
    source_assets_free(&f.sources)
    testing.expectf(t,len(f.tracking.allocation_map)==0 && len(f.tracking.bad_free_array)==0,"%d allocations left",len(f.tracking.allocation_map))
}

// The first tick a rig plays a library made on another skeleton does not retarget it: it asks for
// it, and holds its rest pose while a job makes it; a later frame takes it and the rig plays it.
@(test)
the_first_play_of_a_library_on_another_skeleton_waits_in_the_rest_pose_for_a_job :: proc(t:^testing.T) {
    a:Retarget_Assets;if !retarget_assets(t,&a,"retarget-job") {return};defer retarget_assets_destroy(&a)
    f:Retarget_Test;if !retarget_init(t,&f) {return};defer retarget_destroy(&f)
    rig:=retarget_rig(&f,&a,a.meshes[1],RETARGET_MOVES,0)
    retarget_step(&f,&a.app,0)
    entry:=retarget_entry(&a.app,RETARGET_MOVES,RETARGET_TARGET)
    if !testing.expect(t,entry!=nil && entry.load!=nil && entry.generation==0,"the tick asked for it and a job makes it") {return}
    testing.expect(t,a.app.content.stats.retargets==0 && retarget_bend(&f,rig,RETARGET_CALF)<1e-4,"nothing was retargeted in the tick: the rig holds its rest")
    retarget_job_wait(&a.app,RETARGET_MOVES,RETARGET_TARGET)
    testing.expect(t,entry.generation==0,"what the job made waits for the next frame")
    for tick in 1..<u64(31) {retarget_step(&f,&a.app,tick)}
    retarget_problems(t,&f)
    testing.expect(t,a.app.content.stats.retargets==1 && !entry.failed && entry.load==nil)
    testing.expectf(t,retarget_bend(&f,rig,RETARGET_CALF)>.1,"the rig plays the retarget: the knee bends %v",retarget_bend(&f,rig,RETARGET_CALF))
}

// A shipped game, whose .anim keep only their streams, meets a library and a skeleton its cook did
// not retarget: the rig waits in its rest pose while the same job makes the retarget from the
// streams, then plays it.
@(test)
a_shipped_game_retargets_a_pair_it_has_no_cooked_retarget_for_in_a_job :: proc(t:^testing.T) {
    a:Retarget_Assets;if !retarget_assets(t,&a,"retarget-shipped",shipped=true) {return};defer retarget_assets_destroy(&a)
    f:Retarget_Test;if !retarget_init(t,&f) {return};defer retarget_destroy(&f)
    moves:=host.content_animation(&a.app,RETARGET_MOVES)
    if !testing.expect(t,moves!=nil && moves.lib.stream_bytes>0,"moves.anim is cooked") {return}
    rig:=retarget_rig(&f,&a,a.meshes[1],RETARGET_MOVES,0)
    retarget_step(&f,&a.app,0)
    entry:=retarget_entry(&a.app,RETARGET_MOVES,RETARGET_TARGET)
    if !testing.expect(t,entry!=nil && entry.load!=nil && entry.generation==0,"the tick asked for it and a job makes it") {return}
    testing.expect(t,a.app.content.stats.retargets==0 && retarget_bend(&f,rig,RETARGET_CALF)<1e-4,"nothing was retargeted in the tick: the rig holds its rest")
    retarget_job_wait(&a.app,RETARGET_MOVES,RETARGET_TARGET)
    for tick in 1..<u64(31) {retarget_step(&f,&a.app,tick)}
    retarget_problems(t,&f)
    testing.expect(t,a.app.content.stats.retargets==1 && !entry.failed && !entry.retarget.direct)
    testing.expectf(t,abs(retarget_bend(&f,rig,RETARGET_CALF)-.8)<.03,"the knee bends %v at half a second",retarget_bend(&f,rig,RETARGET_CALF))
    state:=constraint_playing(core.ref(&f.playback),rig)
    testing.expectf(t,state!=nil && abs(retarget_curve(state,"Smile")-.5)<.05,"its curves play")
}

// A clip made on another skeleton whose bones it moves have the names, parents and rests of those
// of the rig binds by name as it is: a variant of its skeleton with a weapon bone and a copy of it
// under another id play the library itself; the target retargets it; the source asks for nothing.
@(test)
clips_of_a_skeleton_whose_moved_bones_match_bind_by_name_without_a_retarget :: proc(t:^testing.T) {
    a:Retarget_Assets;if !retarget_assets(t,&a,"retarget-direct") {return};defer retarget_assets_destroy(&a)
    f:Retarget_Test;if !retarget_init(t,&f) {return};defer retarget_destroy(&f)
    Case :: struct {name:string,mesh:int,skeleton:base.Asset_Id,entry,direct:bool,knee:int}
    cases:=[4]Case{
        {"the source",0,RETARGET_SOURCE,false,true,5},
        {"a variant with a weapon bone",2,RETARGET_VARIANT,true,true,5},
        {"a copy under another id",3,RETARGET_COPY,true,true,5},
        {"the target",1,RETARGET_TARGET,true,false,RETARGET_CALF},
    }
    rigs:[4]core.Entity
    for c,i in cases {
        rigs[i]=retarget_rig(&f,&a,a.meshes[c.mesh],RETARGET_KICK,f32(i))
        if c.entry {_,_=host.content_animation_retarget_wait(&a.app,RETARGET_KICK,c.skeleton)}
    }
    for tick in 0..<u64(30) {retarget_step(&f,&a.app,tick)}
    retarget_problems(t,&f)
    kick:=host.content_animation(&a.app,RETARGET_KICK)
    for c,i in cases {
        entry:=retarget_entry(&a.app,RETARGET_KICK,c.skeleton)
        state:=constraint_playing(core.ref(&f.playback),rigs[i])
        if !testing.expectf(t,(entry!=nil)==c.entry && state!=nil,"%s: entry %v",c.name,entry!=nil) {continue}
        if entry!=nil {
            testing.expectf(t,entry.retarget.direct==c.direct,"%s: direct %v",c.name,entry.retarget.direct)
            if c.direct {testing.expectf(t,entry.clip_count==0 && entry.lib.tracks==nil && entry.retarget.bytes==0,"%s: a library was made",c.name)}
        }
        testing.expectf(t,(state.generation==kick.generation)==c.direct,"%s: plays generation %x",c.name,state.generation)
        bend:=retarget_bend(&f,rigs[i],c.knee)
        testing.expectf(t,abs(bend-.8)<.02,"%s: the knee bends %v",c.name,bend)
    }
}

// Clips made on a skeleton that cannot be read are not played as they are: the rig holds its rest
// pose and reports the library, the skeleton and the fix, until that skeleton arrives and the
// retarget is made.
@(test)
clips_of_a_skeleton_that_cannot_be_read_hold_the_rest_pose_until_it_arrives :: proc(t:^testing.T) {
    a:Retarget_Assets;if !retarget_assets(t,&a,"retarget-missing") {return};defer retarget_assets_destroy(&a)
    f:Retarget_Test;if !retarget_init(t,&f) {return};defer retarget_destroy(&f)
    rig:=retarget_rig(&f,&a,a.meshes[1],RETARGET_ORPHAN,0)
    _,fault:=host.content_animation_retarget_wait(&a.app,RETARGET_ORPHAN,RETARGET_TARGET)
    if !testing.expect(t,fault.failure==.Unread && fault.skeleton==RETARGET_MISSING) {return}
    for tick in 0..<u64(30) {retarget_step(&f,&a.app,tick)}
    problem:=core.problem_find(&f.problems,rig,"animation.retarget_skeleton")
    testing.expect(t,problem!=nil && f.problems.count==1)
    if problem!=nil {
        text:=base.text_get(problem.text[:])
        testing.expectf(t,strings.contains(text,"orphan.anim") && strings.contains(text,"target.skeleton") && strings.contains(text,"import that .skeleton again"),"the problem names the library, the skeleton and the fix: %s",text)
    }
    testing.expectf(t,retarget_bend(&f,rig,RETARGET_CALF)<1e-4,"the knee holds its rest: %v",retarget_bend(&f,rig,RETARGET_CALF))
    state:=constraint_playing(core.ref(&f.playback),rig)
    testing.expect(t,state!=nil && retarget_curve(state,"Smile")<0,"nothing of the clips plays")
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    source:=RETARGET_SOURCE_BONES
    if !retarget_skeleton_save(t,&a,&types,RETARGET_MISSING,"arrived",source[:9]) {return}
    testing.expect(t,host.assets_scan(&a.assets))
    host.content_refresh(&a.app)
    retarget_job_wait(&a.app,RETARGET_ORPHAN,RETARGET_TARGET)
    core.problems_clear(&f.problems)
    // Half a second of the clip, which starts once the retarget is made.
    for tick in 30..<u64(60) {retarget_step(&f,&a.app,tick)}
    entry:=retarget_entry(&a.app,RETARGET_ORPHAN,RETARGET_TARGET)
    testing.expect(t,entry!=nil && !entry.failed && !entry.retarget.direct && f.problems.count==0)
    testing.expectf(t,retarget_bend(&f,rig,RETARGET_CALF)>.1,"the knee bends once its skeleton arrives: %v",retarget_bend(&f,rig,RETARGET_CALF))
}

// Retargets stay within the budget of the application: one that does not fit while the others
// play leaves its rig in the rest pose with a problem, never playing the clips as they are; once
// the rig of another is gone and it idled, it is evicted and the waiting one is made.
@(test)
the_retarget_budget_evicts_only_what_no_rig_plays_and_never_plays_clips_unretargeted :: proc(t:^testing.T) {
    a:Retarget_Assets;if !retarget_assets(t,&a,"retarget-budget") {return};defer retarget_assets_destroy(&a)
    f:Retarget_Test;if !retarget_init(t,&f) {return};defer retarget_destroy(&f)
    first:=retarget_rig(&f,&a,a.meshes[1],RETARGET_MOVES,0)
    if _,fault:=host.content_animation_retarget_wait(&a.app,RETARGET_MOVES,RETARGET_TARGET);!testing.expect(t,fault.failure==.None) {return}
    moves:=retarget_entry(&a.app,RETARGET_MOVES,RETARGET_TARGET)
    // Room for that one alone.
    a.app.retarget_budget=moves.retarget.bytes
    second:=retarget_rig(&f,&a,a.meshes[1],RETARGET_KICK,2)
    tick:=u64(0)
    for ;tick<10;tick+=1 {retarget_step(&f,&a.app,tick);retarget_job_wait(&a.app,RETARGET_KICK,RETARGET_TARGET)}
    kick:=retarget_entry(&a.app,RETARGET_KICK,RETARGET_TARGET)
    if !testing.expect(t,kick!=nil && kick.failed && kick.retarget.failure==.Budget,"the second does not fit") {return}
    testing.expect(t,core.problem_find(&f.problems,second,"animation.retarget_budget")!=nil)
    testing.expectf(t,retarget_bend(&f,second,RETARGET_CALF)<1e-4,"its rig holds its rest: %v",retarget_bend(&f,second,RETARGET_CALF))
    testing.expect(t,a.app.content.retarget_bytes<=a.app.retarget_budget && a.app.content.stats.evicted==0,"the one played stays")
    // The rig of the first goes: once it idled, the second evicts it.
    core.destroy(&f.entities,first)
    bent:f32
    for ;tick<u64(host.CONTENT_RETARGET_IDLE)+40;tick+=1 {
        retarget_step(&f,&a.app,tick);retarget_job_wait(&a.app,RETARGET_KICK,RETARGET_TARGET)
        bent=max(bent,retarget_bend(&f,second,RETARGET_CALF))
    }
    core.problems_clear(&f.problems)
    retarget_step(&f,&a.app,tick)
    retarget_problems(t,&f)
    kick=retarget_entry(&a.app,RETARGET_KICK,RETARGET_TARGET)
    testing.expect(t,kick!=nil && !kick.failed && retarget_entry(&a.app,RETARGET_MOVES,RETARGET_TARGET)==nil && a.app.content.stats.evicted==1)
    testing.expect(t,a.app.content.retarget_bytes<=a.app.retarget_budget)
    testing.expectf(t,abs(bent-.8)<.02,"the second plays its retarget: the knee bends up to %v",bent)
}

// A retarget the cook wrote plays as the one a job makes: the same poses tick by tick, with no
// retarget made at run time.
@(test)
a_cooked_retarget_plays_as_the_one_a_job_makes :: proc(t:^testing.T) {
    made,cooked:Retarget_Assets
    if !retarget_assets(t,&made,"retarget-made") {return};defer retarget_assets_destroy(&made)
    if !retarget_assets(t,&cooked,"retarget-cooked",cooked=true) {return};defer retarget_assets_destroy(&cooked)
    f,g:Retarget_Test
    if !retarget_init(t,&f) || !retarget_init(t,&g) {return}
    defer {retarget_destroy(&f);retarget_destroy(&g)}
    one,other:=retarget_rig(&f,&made,made.meshes[1],RETARGET_MOVES,0),retarget_rig(&g,&cooked,cooked.meshes[1],RETARGET_MOVES,0)
    // The cooked one is read as the first tick asks for it and plays in that tick.
    retarget_step(&g,&cooked.app,0)
    read:=retarget_entry(&cooked.app,RETARGET_MOVES,RETARGET_TARGET)
    testing.expect(t,read!=nil && read.load==nil && read.generation!=0 && cooked.app.content.stats.retargets==0,"the cooked one is read, not made")
    testing.expect(t,constraint_playing(core.ref(&g.playback),other).generation==read.generation,"it plays in the first tick")
    _,_=host.content_animation_retarget_wait(&made.app,RETARGET_MOVES,RETARGET_TARGET)
    retarget_step(&f,&made.app,0)
    testing.expect(t,made.app.content.stats.retargets==1)
    worst:f32
    for tick in 1..<u64(70) {
        retarget_step(&f,&made.app,tick);retarget_step(&g,&cooked.app,tick)
        a,b:=constraint_playing(core.ref(&f.playback),one),constraint_playing(core.ref(&g.playback),other)
        if !testing.expect(t,a!=nil && b!=nil) {return}
        for value,i in playing_pose(a,.Local) {
            other:=playing_pose(b,.Local)[i]
            worst=max(worst,linalg.length(value.position-other.position),1-abs(linalg.dot(value.rotation,other.rotation)))
        }
    }
    retarget_problems(t,&f);retarget_problems(t,&g)
    testing.expectf(t,worst<=1e-6,"the poses differ by %v",worst)
    testing.expectf(t,retarget_bend(&f,one,RETARGET_CALF)>.1,"they play the retarget: %v",retarget_bend(&f,one,RETARGET_CALF))
}

// A copy of the animation state of a world (a snapshot a rollback restores, a world copy) keeps the
// generation its rigs played, never a place in a cache: restored, it plays the same poses again.
@(test)
a_restored_copy_of_a_world_plays_the_same_retargeted_poses :: proc(t:^testing.T) {
    a:Retarget_Assets;if !retarget_assets(t,&a,"retarget-snapshot") {return};defer retarget_assets_destroy(&a)
    f:Retarget_Test;if !retarget_init(t,&f) {return};defer retarget_destroy(&f)
    rig:=retarget_rig(&f,&a,a.meshes[1],RETARGET_MOVES,0)
    _,_=host.content_animation_retarget_wait(&a.app,RETARGET_MOVES,RETARGET_TARGET)
    for tick in 0..<u64(10) {retarget_step(&f,&a.app,tick)}
    snapshot:Playback;defer playback_free(&snapshot)
    if !testing.expect(t,playback_copy(&snapshot,&f.playback)) {return}
    poses:[20]f32
    for tick in 10..<u64(30) {retarget_step(&f,&a.app,tick);poses[tick-10]=retarget_bend(&f,rig,RETARGET_CALF)}
    if !testing.expect(t,playback_copy(&f.playback,&snapshot)) {return}
    for tick in 10..<u64(30) {
        retarget_step(&f,&a.app,tick)
        testing.expectf(t,retarget_bend(&f,rig,RETARGET_CALF)==poses[tick-10],"tick %d: %v, before %v",tick,retarget_bend(&f,rig,RETARGET_CALF),poses[tick-10])
    }
    retarget_problems(t,&f)
    testing.expect(t,poses[19]>.1)
}
