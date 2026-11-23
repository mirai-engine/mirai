package anim

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:testing"
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
retarget_assets :: proc(t:^testing.T,a:^Retarget_Assets,name:string) -> bool {
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
    a.app=host.App{assets=&a.assets,allocator=context.allocator}
    for id in ([3]base.Asset_Id{RETARGET_MOVES,RETARGET_KICK,RETARGET_ORPHAN}) {
        if !testing.expect(t,host.content_animation_wait(&a.app,id)!=nil) {return false}
    }
    return true
}

@(private="file")
retarget_assets_destroy :: proc(a:^Retarget_Assets) {host.app_content_destroy(&a.app);host.assets_destroy(&a.assets)}

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

// One fixed tick of the animation, as the loop runs it, counting the markers whose .anim is that
// of the clip.
@(private="file")
retarget_step :: proc(f:^Retarget_Test,app:^host.App,tick:u64) {
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

@(private="file")
retarget_entry :: proc(f:^Retarget_Test,library,skeleton:base.Asset_Id) -> ^Source_Retarget {
    for &entry in f.sources.retargets {if entry.library==library && entry.skeleton==skeleton {return &entry}}
    return nil
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
// the library, made once and played by name (the knee of the source bends the knee of the
// target), keeping its curves, markers and the clip made on the target; stable ticks allocate
// nothing, a new generation of the library replaces it in place, and freeing the cache leaves
// nothing behind.
@(test)
rigs_of_a_skeleton_share_one_retarget_of_a_library_made_on_another :: proc(t:^testing.T) {
    a:Retarget_Assets;if !retarget_assets(t,&a,"retarget-shared") {return};defer retarget_assets_destroy(&a)
    f:Retarget_Test;if !retarget_init(t,&f) {return};defer retarget_destroy(&f)
    first,second:=retarget_rig(&f,&a,a.meshes[1],RETARGET_MOVES,0),retarget_rig(&f,&a,a.meshes[1],RETARGET_MOVES,2)
    for tick in 0..<u64(30) {retarget_step(&f,&a.app,tick)}
    retarget_problems(t,&f)
    entry:=retarget_entry(&f,RETARGET_MOVES,RETARGET_TARGET)
    if !testing.expect(t,entry!=nil && !entry.direct && entry.failure==.None && len(f.sources.retargets)==1) {return}
    library:=&entry.content
    one,other:=constraint_playing(core.ref(&f.playback),first),constraint_playing(core.ref(&f.playback),second)
    if !testing.expect(t,one!=nil && other!=nil) {return}
    testing.expect(t,library.generation&RETARGET_GENERATION!=0 && one.generation==library.generation && other.generation==library.generation)
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
    kept,base_tracks:=lib.clip_tracks(&library.lib,2),lib.clip_tracks(&moves.lib,2)
    testing.expect(t,len(kept)==len(base_tracks) && len(kept)>0 && kept[0]==base_tracks[0],"the clip made on the target keeps its tracks")
    // Stable ticks allocate nothing, in the cache or anywhere.
    allocations:=f.tracking.total_allocation_count
    saved:=context;context.allocator=runtime.nil_allocator();context.temp_allocator=runtime.nil_allocator();a.app.allocator=runtime.nil_allocator()
    for tick in 30..<u64(90) {retarget_step(&f,&a.app,tick)}
    context=saved;a.app.allocator=context.allocator
    testing.expectf(t,f.tracking.total_allocation_count==allocations && f.problems.count==0,"%d allocations and %d problems in stable ticks",f.tracking.total_allocation_count-allocations,f.problems.count)
    retarget_problems(t,&f)
    // A new generation of the library: the entry is made again in place, and the rigs follow it.
    made:=library.generation
    moves.generation+=1<<20
    for tick in 90..<u64(92) {retarget_step(&f,&a.app,tick)}
    entry=retarget_entry(&f,RETARGET_MOVES,RETARGET_TARGET)
    testing.expect(t,len(f.sources.retargets)==1 && entry.generation==moves.generation && entry.content.generation!=made)
    testing.expect(t,one.generation==entry.content.generation && other.generation==entry.content.generation)
    source_assets_free(&f.sources)
    testing.expectf(t,len(f.tracking.allocation_map)==0 && len(f.tracking.bad_free_array)==0,"%d allocations left",len(f.tracking.allocation_map))
}

// A clip made on another skeleton whose bones it moves have the names, parents and rests of those
// of the rig binds by name as it is: a variant of its skeleton with a weapon bone and a copy of it
// under another id play the library itself; the target retargets it; the source keeps no entry.
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
    for c,i in cases {rigs[i]=retarget_rig(&f,&a,a.meshes[c.mesh],RETARGET_KICK,f32(i))}
    for tick in 0..<u64(30) {retarget_step(&f,&a.app,tick)}
    retarget_problems(t,&f)
    kick:=host.content_animation(&a.app,RETARGET_KICK)
    for c,i in cases {
        entry:=retarget_entry(&f,RETARGET_KICK,c.skeleton)
        state:=constraint_playing(core.ref(&f.playback),rigs[i])
        if !testing.expectf(t,(entry!=nil)==c.entry && state!=nil,"%s: entry %v",c.name,entry!=nil) {continue}
        if entry!=nil {
            testing.expectf(t,entry.direct==c.direct,"%s: direct %v",c.name,entry.direct)
            if c.direct {testing.expectf(t,entry.content.clip_count==0 && entry.content.lib.tracks==nil,"%s: a library was made",c.name)}
        }
        testing.expectf(t,(state.generation==kick.generation)==c.direct,"%s: plays generation %x",c.name,state.generation)
        bend:=retarget_bend(&f,rigs[i],c.knee)
        testing.expectf(t,abs(bend-.8)<.02,"%s: the knee bends %v",c.name,bend)
    }
}

// Clips made on a skeleton that cannot be read hold the rest pose of the rig, which reports it,
// and play once that skeleton arrives: the entry is made again, never kept broken.
@(test)
clips_of_a_skeleton_that_cannot_be_read_hold_the_rest_pose_until_it_arrives :: proc(t:^testing.T) {
    a:Retarget_Assets;if !retarget_assets(t,&a,"retarget-missing") {return};defer retarget_assets_destroy(&a)
    f:Retarget_Test;if !retarget_init(t,&f) {return};defer retarget_destroy(&f)
    rig:=retarget_rig(&f,&a,a.meshes[1],RETARGET_ORPHAN,0)
    for tick in 0..<u64(30) {retarget_step(&f,&a.app,tick)}
    entry:=retarget_entry(&f,RETARGET_ORPHAN,RETARGET_TARGET)
    if !testing.expect(t,entry!=nil && entry.failure==.Unread && entry.failed==RETARGET_MISSING) {return}
    testing.expect(t,core.problem_find(&f.problems,rig,"animation.retarget_skeleton")!=nil && f.problems.count==1)
    testing.expectf(t,retarget_bend(&f,rig,RETARGET_CALF)<1e-4,"the knee holds its rest: %v",retarget_bend(&f,rig,RETARGET_CALF))
    state:=constraint_playing(core.ref(&f.playback),rig)
    testing.expect(t,state!=nil && abs(retarget_curve(state,"Smile")-.5)<.05,"its curves still play")
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    source:=RETARGET_SOURCE_BONES
    if !retarget_skeleton_save(t,&a,&types,RETARGET_MISSING,"arrived",source[:9]) {return}
    testing.expect(t,host.assets_scan(&a.assets))
    core.problems_clear(&f.problems)
    for tick in 30..<u64(31) {retarget_step(&f,&a.app,tick)}
    for tick in 31..<u64(90) {retarget_step(&f,&a.app,tick)}
    entry=retarget_entry(&f,RETARGET_ORPHAN,RETARGET_TARGET)
    testing.expect(t,entry!=nil && entry.failure==.None && !entry.direct && f.problems.count==0)
    testing.expectf(t,abs(retarget_bend(&f,rig,RETARGET_CALF)-.8)<.02,"the knee bends once its skeleton arrives: %v",retarget_bend(&f,rig,RETARGET_CALF))
}

// A rollback snapshot keeps the generation its rigs played, never a place in the cache: restored
// after the retarget it names was made again, its rigs find nothing of the old one and bind the
// new one in their next tick.
@(test)
a_restored_snapshot_binds_the_retarget_made_since_without_dangling :: proc(t:^testing.T) {
    a:Retarget_Assets;if !retarget_assets(t,&a,"retarget-snapshot") {return};defer retarget_assets_destroy(&a)
    f:Retarget_Test;if !retarget_init(t,&f) {return};defer retarget_destroy(&f)
    rig:=retarget_rig(&f,&a,a.meshes[1],RETARGET_MOVES,0)
    for tick in 0..<u64(10) {retarget_step(&f,&a.app,tick)}
    snapshot:Playback;defer playback_free(&snapshot)
    if !testing.expect(t,playback_copy(&snapshot,&f.playback)) {return}
    moves:=host.content_animation(&a.app,RETARGET_MOVES)
    moves.generation+=1<<20
    for tick in 10..<u64(12) {retarget_step(&f,&a.app,tick)}
    entry:=retarget_entry(&f,RETARGET_MOVES,RETARGET_TARGET)
    if !testing.expect(t,playback_copy(&f.playback,&snapshot)) {return}
    state:=constraint_playing(core.ref(&f.playback),rig)
    if !testing.expect(t,state!=nil && state.generation!=entry.content.generation) {return}
    testing.expect(t,animation_playing_content(core.ref(&f.sources),&a.app,state)==nil,"the old retarget is not found")
    for tick in 10..<u64(30) {retarget_step(&f,&a.app,tick)}
    retarget_problems(t,&f)
    testing.expect(t,state.generation==entry.content.generation && len(f.sources.retargets)==1)
    testing.expectf(t,abs(retarget_bend(&f,rig,RETARGET_CALF)-.8)<.02,"the knee bends %v",retarget_bend(&f,rig,RETARGET_CALF))
}
