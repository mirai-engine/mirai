package anim

import "base:runtime"
import "core:fmt"
import "core:math/linalg"
import "core:slice"
import "core:testing"
import "mirai:asset"
import "mirai:core"
import scene "mirai:engine/scene"
import "mirai:host"
import "mirai:std/ai"
import lib "mirai:std/anim"
import "mirai:std/base"
import mm "mirai:std/math"

@(private="file")
LOD_DT :: f32(1.0/60)

// A Rig_World stepped through the fixed steps of the animation, with the simulation sources it is
// posed by and the assets the application holds for it.
@(private="file")
Lod_Test :: struct {
    using w:Rig_World,
    cache:Skeleton_Assets,
    characters:Character_Assets,
    sources:Source_Assets,
    simulation:scene.Simulation_Sources,
    fields:Field_Playback,
    problems:core.Problems,
    config:Animation_Budget_Config,
}

@(private="file")
Lod_Assets :: struct {
    assets:host.Assets,
    app:host.App,
    mesh,other_mesh,walk:base.Asset_Id,
}

// A column of three bones (upper, lower, foot) in two skeletons of the same names, a mesh bound
// to each, and a looping walk that turns the upper bone, carries it forward as root motion and
// crosses two markers a second.
@(private="file")
lod_assets :: proc(t:^testing.T,a:^Lod_Assets,name:string) -> bool {
    directory:=base.test_folder(t,name)
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    bones:=[3]asset.Skeleton_Bone{{parent=-1,translation={0,2,0},rotation=1,scale={1,1,1}},{parent=0,translation={0,-1,0},rotation=1,scale={1,1,1}},{parent=1,translation={0,-1,0},rotation=1,scale={1,1,1}}}
    paths:=[3]string{"upper","upper/lower","upper/lower/foot"}
    names:=[3]string{"upper","lower","foot"}
    for &bone,i in bones {base.text_set(bone.path[:],paths[i]);base.text_set(bone.name[:],names[i]);bone.target=base.name_hash(paths[i])}
    skeletons:=[2]base.Asset_Id{{0x10d,1},{0x10d,2}}
    a.mesh,a.other_mesh,a.walk={0x10d,3},{0x10d,4},{0x10d,5}
    vertices:=[3]asset.Vertex{{position={-1,0,0},color=0xffffffff},{position={1,0,0},color=0xffffffff},{position={0,1,0},color=0xffffffff}}
    influences:[3]asset.Skin_Vertex
    for &influence in influences {influence.weights[0]=255}
    joints:=[1]asset.Rig_Joint{{node=0,inverse_bind=1}}
    turn:=[3]lib.Keyframe{{time=0,value=lib.quat_vec4(1)},{time=.5,value=lib.quat_vec4(mm.quat_axis_angle({1,0,0},.8))},{time=1,value=lib.quat_vec4(1)}}
    ahead:=[2]lib.Keyframe{{time=0,value={0,2,0,0}},{time=1,value={0,2,-1.5,0}}}
    markers:=[2]asset.Animation_Marker_Desc{{time=.25,name="step"},{time=.75,name="step"}}
    tracks:=[2]asset.Animation_Track_Desc{{target="upper",property=.Rotation,keys=turn[:]},{target="upper",property=.Position,keys=ahead[:]}}
    clip:=asset.Animation_Clip_Desc{name="walk",tracks=tracks[:],markers=markers[:]}
    base.text_set(clip.root.bone[:],"upper");clip.root.translation=true
    for skeleton,i in skeletons {
        if !testing.expect_value(t,asset.skeleton_save(fmt.tprintf("%s/rig%d.skeleton",directory,i),&types,{id=skeleton,bones=bones[:]}),asset.Error.None) {return false}
        mesh:=a.mesh if i==0 else a.other_mesh
        if !testing.expect_value(t,rig_mesh_save(fmt.tprintf("%s/rig%d.mesh",directory,i),&types,{id=mesh,skeleton=skeleton,joints=joints[:]},vertices[:],{0,1,2},influences[:]),asset.Error.None) {return false}
    }
    if !testing.expect_value(t,asset.animation_save(fmt.tprintf("%s/walk.anim",directory),&types,{id=a.walk,clips={clip}}),asset.Error.None) {return false}
    if !testing.expect(t,host.assets_init(&a.assets,{root=directory})) {return false}
    a.app=host.App{assets=&a.assets,allocator=context.allocator}
    return testing.expect(t,host.content_animation_wait(&a.app,a.walk)!=nil)
}

@(private="file")
lod_assets_destroy :: proc(a:^Lod_Assets) {host.app_content_destroy(&a.app);host.assets_destroy(&a.assets)}

@(private="file")
lod_init :: proc(t:^testing.T,f:^Lod_Test) -> bool {
    f.config=ANIMATION_BUDGET_CONFIG_DEFAULT
    return test_world_init(t,&f.w)
}

@(private="file")
lod_destroy :: proc(f:^Lod_Test) {
    test_world_destroy(&f.w)
    skeleton_assets_free(&f.cache);character_assets_free(&f.characters);source_assets_free(&f.sources)
    field_playback_free(&f.fields)
}

// A rig that walks at x on the ground, showing mesh; spring: with a spring down its column.
@(private="file")
lod_rig :: proc(f:^Lod_Test,a:^Lod_Assets,x:f32,spring:=false,mesh:base.Asset_Id={},animated:=true) -> core.Entity {
    rig:=core.create(&f.entities)
    place:=core.TRANSFORM_IDENTITY;place.position={x,0,0}
    core.add(&f.transforms,rig,place)
    core.add(&f.meshes,rig,{mesh=mesh if mesh!={} else a.mesh})
    animation:=ANIMATION_DEFAULT;animation.asset=a.walk;animation.root_motion=.Extract;animation.fade=0
    if animated {core.add(&f.animations,rig,animation)}
    if spring {
        chain:=SPRING_CONSTRAINT_DEFAULT
        chain.root,chain.end=bone_ref("upper"),bone_ref("foot")
        chain.settings.force={12,0,0}
        base.text_set(chain.name[:],"tail")
        // The profile keeps the rows: they outlive this call.
        springs:=make([]Spring_Constraint,1,context.temp_allocator);springs[0]=chain
        test_modifier_profile(&f.modifiers,&f.characters,rig,{springs=springs})
    }
    test_world_settle(&f.w)
    return rig
}

// One fixed tick of the animation, as the loop runs it: the rigs, the sample and the finish.
@(private="file")
lod_step :: proc(f:^Lod_Test,app:^host.App,tick:u64,resimulating:=false) {
    time:=core.Time{tick=tick,dt=LOD_DT,playing=true,resimulating=resimulating}
    test_world_settle(&f.w)
    rigs_update(&f.playback,core.read(&f.meshes),core.read(&f.skins),app.assets,core.read(&f.attachments))
    if core.count(&f.attachments)>0 {
        modifier_attachments_prepare(&f.modifiers,&f.attachments,&f.cache,&f.playback,app.assets,app.allocator,&f.problems,core.read(&f.meshes))
    }
    f.playback.prepared=true
    clear(&f.events.items)
    animation_sample(core.read(&f.animations),core.read(&f.progress),&f.played,&f.transforms,core.read(&f.parents),{},core.read(&f.labels),core.read(&f.targets),core.read(&f.remotes),&f.requests,&f.events,&f.modifiers,&f.playback,&f.characters,&f.cache,app,time,{},&f.problems,&f.actions,&f.motion,&f.sources,{},core.CLOCK_DEFAULT,f.config,core.ref(&f.simulation),core.ref(&f.fields))
    animation_advance(&f.transforms,core.read(&f.parents),core.read(&f.worlds),&f.requests,&f.modifiers,&f.playback,{},{},time,{},&f.problems,&f.motion,&f.characters,{},{},core.CLOCK_DEFAULT,nil)
}

// Fails the test with each problem the world reported.
@(private="file")
lod_problems :: proc(t:^testing.T,f:^Lod_Test,loc:=#caller_location) {
    for &problem in core.problems_list(&f.problems) {
        testing.expectf(t,false,"%s: %s",base.text_get(problem.code[:]),base.text_get(problem.text[:]),loc=loc)
    }
}

@(private="file")
lod_source :: proc(f:^Lod_Test,at:mm.Vec3) {f.simulation.items[0]={position=at,ahead=at};f.simulation.count=1}

@(private="file")
lod_markers :: proc(f:^Lod_Test,rig:core.Entity) -> (count:int) {
    for event in f.events.items {if event.entity==rig && event.kind==.Marker {count+=1}}
    return
}

// How far the foot of a rig is from where its clips put it: what its modifiers moved it.
@(private="file")
lod_foot_offset :: proc(state:^Playing) -> f32 {
    shown,sampled:[4]mm.Transform
    copy(shown[:],playing_pose(state,.Local));copy(sampled[:],playing_pose(state,.Sampled))
    shown[0],sampled[0]=mm.TRANSFORM_IDENTITY,mm.TRANSFORM_IDENTITY
    if !lib.pose_world(playing_topology(state).parents[:],shown[:],shown[:]) || !lib.pose_world(playing_topology(state).parents[:],sampled[:],sampled[:]) {return max(f32)}
    return linalg.length(shown[3].position-sampled[3].position)
}

// Near the sources a rig is posed with its modifiers in every tick; past cosmetic_distance its
// springs stop while it is still posed; past twice cadence_near it is posed only on the ticks of
// its cadence (ai.cadence_period), and its clock, markers and root motion still run every tick,
// as those of the same rig in a world without sources; a stable tick takes no memory.
@(test)
rigs_are_posed_by_their_distance_to_the_simulation_sources :: proc(t:^testing.T) {
    a:Lod_Assets;if !lod_assets(t,&a,"lod-distance") {return};defer lod_assets_destroy(&a)
    Case :: struct {x:f32,period:u32,plain:bool}
    cases:=[3]Case{{x=5,period=1},{x=30,period=1,plain=true},{x=100,period=5,plain=true}}
    lodded,full:Lod_Test
    if !lod_init(t,&lodded) || !lod_init(t,&full) {return}
    defer {lod_destroy(&lodded);lod_destroy(&full)}
    rigs:[3]core.Entity
    for c,i in cases {rigs[i]=lod_rig(&lodded,&a,c.x,spring=true);lod_rig(&full,&a,c.x,spring=true)}
    lod_source(&lodded,{})
    TICKS :: 40
    posed,markers:[3]int
    last:[3][4]mm.Transform
    for tick in 0..<u64(TICKS) {
        // The last ticks are stable: they take no memory.
        saved:=context
        if tick>=TICKS-8 {context.allocator=runtime.nil_allocator();context.temp_allocator=runtime.nil_allocator()}
        lod_step(&lodded,&a.app,tick);lod_step(&full,&a.app,tick)
        context=saved
        for c,i in cases {
            state,reference:=constraint_playing(core.ref(&lodded.playback),rigs[i]),constraint_playing(core.ref(&full.playback),rigs[i])
            if !testing.expect(t,state!=nil && reference!=nil && len(playing_pose(state,.Sampled))==4) {return}
            testing.expectf(t,state.lod.period==c.period && state.lod.plain==c.plain,"rig at %.0f m, tick %d: %v",c.x,tick,state.lod)
            testing.expectf(t,state.time==reference.time && state.motion==reference.motion && state.motion.translation!={},"rig at %.0f m, tick %d: its clock and root motion run every tick",c.x,tick)
            testing.expectf(t,lod_markers(&lodded,rigs[i])==lod_markers(&full,rigs[i]),"rig at %.0f m, tick %d: its markers are crossed every tick",c.x,tick)
            markers[i]+=lod_markers(&lodded,rigs[i])
            due:=tick==0 || ai.cadence_due(tick,u64(core.entity_index(rigs[i])),u64(c.period))
            if due {
                posed[i]+=1
                testing.expectf(t,slice.equal(playing_pose(state,.Sampled)[1:],playing_pose(reference,.Sampled)[1:]),"rig at %.0f m, tick %d: posed as in full",c.x,tick)
            } else {
                testing.expectf(t,state.lod.skip && slice.equal(playing_pose(state,.Sampled)[1:],last[i][1:]),"rig at %.0f m, tick %d: keeps its last pose",c.x,tick)
            }
            copy(last[i][:],playing_pose(state,.Sampled))
            offset:=lod_foot_offset(state)
            if c.plain {testing.expectf(t,offset<1e-5,"rig at %.0f m, tick %d: its spring is off (%f)",c.x,tick,offset)} else if tick>4 {testing.expectf(t,offset>1e-3,"rig at %.0f m, tick %d: its spring swings (%f)",c.x,tick,offset)}
        }
    }
    testing.expectf(t,posed[0]==TICKS && posed[1]==TICKS && posed[2]<TICKS/3,"poses by rig: %v",posed)
    testing.expectf(t,markers[0]>0 && markers[0]==markers[2],"markers by rig: %v",markers)
    lod_problems(t,&lodded)
}

// A far rig that gameplay reads (animation_read, a Bone_Attachment, a pose asked of a bone) is
// posed with all its modifiers in every tick.
@(test)
a_rig_gameplay_reads_runs_in_full_at_any_distance :: proc(t:^testing.T) {
    a:Lod_Assets;if !lod_assets(t,&a,"lod-read") {return};defer lod_assets_destroy(&a)
    Read :: enum {Request,Attachment,Pose}
    for read in Read {
        f:Lod_Test
        if !lod_init(t,&f) {return}
        defer lod_destroy(&f)
        rig:=lod_rig(&f,&a,100,spring=true)
        lod_source(&f,{})
        if read==.Attachment {
            hitbox:=core.create(&f.entities)
            core.add(&f.transforms,hitbox,core.TRANSFORM_IDENTITY)
            attachment:=BONE_ATTACHMENT_DEFAULT;attachment.rig,attachment.bone=rig,bone_ref("foot")
            core.add(&f.attachments,hitbox,attachment)
        }
        for tick in 0..<u64(20) {
            switch read {
            case .Request: animation_read(&f.requests,rig)
            case .Attachment:
            case .Pose: animation_pose(&f.requests,rig,bone_ref("lower"),mm.TRANSFORM_IDENTITY,0)
            }
            lod_step(&f,&a.app,tick)
            state:=constraint_playing(core.ref(&f.playback),rig)
            if !testing.expect(t,state!=nil) {return}
            testing.expectf(t,state.lod==Rig_Lod{} && state.finished==f.playback.frame,"%v, tick %d: %v",read,tick,state.lod)
            if tick>4 {testing.expectf(t,lod_foot_offset(state)>1e-3,"%v, tick %d: its spring swings",read,tick)}
        }
        lod_problems(t,&f)
    }
}

// A rig that takes the pose of a far one (Pose_Source, finished or sampled) is posed on the
// ticks of that one, whatever its own distance: it never misses its pose.
@(test)
a_follower_is_posed_on_the_ticks_of_its_leader :: proc(t:^testing.T) {
    a:Lod_Assets;if !lod_assets(t,&a,"lod-follow") {return};defer lod_assets_destroy(&a)
    for stage in Pose_Stage {
        f:Lod_Test
        if !lod_init(t,&f) {return}
        defer lod_destroy(&f)
        leader:=lod_rig(&f,&a,100)
        // A finished pose of the same skeleton is shared without a rig: this one is of another.
        follower:=lod_rig(&f,&a,5,mesh=a.other_mesh if stage==.Finished else a.mesh,animated=false)
        core.add(&f.skins,follower,{rig=leader,stage=stage})
        lod_source(&f,{})
        posed:=0
        for tick in 0..<u64(30) {
            lod_step(&f,&a.app,tick)
            body,head:=constraint_playing(core.ref(&f.playback),leader),constraint_playing(core.ref(&f.playback),follower)
            if !testing.expect(t,body!=nil && head!=nil && head.leader==leader) {return}
            testing.expectf(t,head.lod==body.lod && head.finished==body.finished,"%v, tick %d: %v and %v",stage,tick,head.lod,body.lod)
            if !body.lod.skip {posed+=1}
        }
        testing.expectf(t,posed>0 && posed<30,"%v: the leader skips some ticks (%d posed)",stage,posed)
        testing.expectf(t,core.problem_find(&f.problems,follower,"animation.follow_rig")==nil && f.problems.count==0,"%v: %d problems",stage,f.problems.count)
    }
}

// Between two of its poses a rig shows the last one, carried with its entity: Previous is Local
// after every tick, so what is drawn between the ticks does not go back and forth.
@(test)
a_rig_between_its_poses_holds_its_pose_and_moves_with_its_entity :: proc(t:^testing.T) {
    a:Lod_Assets;if !lod_assets(t,&a,"lod-hold") {return};defer lod_assets_destroy(&a)
    f:Lod_Test
    if !lod_init(t,&f) {return}
    defer lod_destroy(&f)
    rig:=lod_rig(&f,&a,100)
    lod_source(&f,{})
    skipped:=0
    held:[4]mm.Transform
    for tick in 0..<u64(30) {
        core.edit(&f.transforms,rig).position.x=100+f32(tick)*.05
        lod_step(&f,&a.app,tick)
        state:=constraint_playing(core.ref(&f.playback),rig)
        if !testing.expect(t,state!=nil) {return}
        testing.expectf(t,slice.equal(playing_pose(state,.Previous),playing_pose(state,.Local)),"tick %d: Previous is Local",tick)
        testing.expectf(t,playing_pose(state,.Local)[0].position.x==100+f32(tick)*.05,"tick %d: the pose is carried with its entity",tick)
        if state.lod.skip {
            skipped+=1
            testing.expectf(t,slice.equal(playing_pose(state,.Local)[1:],held[1:]),"tick %d: its bones hold",tick)
        }
        copy(held[:],playing_pose(state,.Local))
    }
    testing.expect(t,skipped>0)
}

// A rig whose springs swung near the sources, then went off far from them or were left for
// ticks it was not posed, starts them over from its pose when it is posed with them again: no
// swing carried over from a pose it did not show, while it walked on.
@(test)
a_rig_that_comes_back_near_starts_its_springs_over :: proc(t:^testing.T) {
    a:Lod_Assets;if !lod_assets(t,&a,"lod-return") {return};defer lod_assets_destroy(&a)
    // Off past cosmetic_distance, posed in every tick or on the ticks of its cadence; on, but
    // posed on the ticks of a slow cadence. away: how far the source goes.
    Case :: struct {cosmetic,slowest,away:f32}
    cases:=[3]Case{{25,.25,30},{25,.25,1000},{0,1,1000}}
    for c in cases {
        f,near:Lod_Test
        if !lod_init(t,&f) || !lod_init(t,&near) {return}
        defer {lod_destroy(&f);lod_destroy(&near)}
        f.config.cosmetic_distance,f.config.cadence_slowest=c.cosmetic,c.slowest
        near.config=f.config
        rig:=lod_rig(&f,&a,0,spring=true);lod_rig(&near,&a,0,spring=true)
        worst,steady:f32
        for tick in 0..<u64(80) {
            // It walks sideways, which swings its spring; from tick 20 to 50 the source is away.
            x:=f32(tick)*.04
            core.edit(&f.transforms,rig).position.x=x;core.edit(&near.transforms,rig).position.x=x
            lod_source(&f,{x+c.away if tick>=20 && tick<50 else x,0,0});lod_source(&near,{x,0,0})
            lod_step(&f,&a.app,tick);lod_step(&near,&a.app,tick)
            state,reference:=constraint_playing(core.ref(&f.playback),rig),constraint_playing(core.ref(&near.playback),rig)
            if !testing.expect(t,state!=nil && reference!=nil) {return}
            offset:=lod_foot_offset(state)
            testing.expectf(t,offset<max(f32),"%v, tick %d: a finite pose",c,tick)
            if tick>=20 && tick<50 {testing.expectf(t,(state.lod.period>1)==(c.away>40) && state.lod.plain==(c.cosmetic>0),"%v, tick %d: away: %v",c,tick,state.lod)}
            if tick>=50 {
                testing.expectf(t,state.lod==Rig_Lod{period=1},"%v, tick %d: near again: %v",c,tick,state.lod)
                worst=max(worst,offset)
            }
            steady=max(steady,lod_foot_offset(reference))
        }
        testing.expectf(t,steady>1e-3 && worst<=steady+1e-3,"%v: back near, its spring moves its foot up to %f m, and %f m always near",c,worst,steady)
        lod_problems(t,&f)
    }
}

// A world copied back to an earlier tick and run again poses its rigs, near, far and following,
// as it did: their level of detail is decided from the simulation alone.
@(test)
a_rig_resimulated_after_a_rollback_takes_the_same_poses :: proc(t:^testing.T) {
    a:Lod_Assets;if !lod_assets(t,&a,"lod-rollback") {return};defer lod_assets_destroy(&a)
    f,snapshot:Lod_Test
    if !lod_init(t,&f) || !lod_init(t,&snapshot) {return}
    defer {lod_destroy(&f);lod_destroy(&snapshot)}
    rigs:=[3]core.Entity{lod_rig(&f,&a,5,spring=true),lod_rig(&f,&a,60,spring=true),lod_rig(&f,&a,100)}
    lod_source(&f,{})
    for tick in 0..<u64(7) {lod_step(&f,&a.app,tick)}
    if !testing.expect(t,test_world_copy(&snapshot.w,&f.w)) {return}
    TICKS :: 12
    Tick :: struct {local,sampled,previous:[3][4]mm.Transform,lod:[3]Rig_Lod,time:[3]f32,motion:[3]Root_Delta}
    run :: proc(t:^testing.T,f:^Lod_Test,a:^Lod_Assets,rigs:[3]core.Entity,resimulating:bool) -> (out:[TICKS]Tick) {
        for &tick,i in out {
            lod_step(f,&a.app,7+u64(i),resimulating)
            for rig,k in rigs {
                state:=constraint_playing(core.ref(&f.playback),rig)
                if !testing.expect(t,state!=nil) {return}
                copy(tick.local[k][:],playing_pose(state,.Local));copy(tick.sampled[k][:],playing_pose(state,.Sampled));copy(tick.previous[k][:],playing_pose(state,.Previous))
                tick.lod[k],tick.time[k],tick.motion[k]=state.lod,state.time,state.motion
            }
        }
        return
    }
    played:=run(t,&f,&a,rigs,false)
    if !testing.expect(t,test_world_copy(&f.w,&snapshot.w)) {return}
    replayed:=run(t,&f,&a,rigs,true)
    for tick,i in played {testing.expectf(t,tick==replayed[i],"tick %d replays as it played",i)}
    skipped:=false
    for tick in played {skipped ||= tick.lod[2].skip}
    testing.expect(t,skipped,"the replay covers ticks a rig skips")
}

// Where nobody watches (a dedicated server runs no phase Ui or Render) a rig is not posed, unless
// gameplay reads it; its clock, markers and root motion run as where it is drawn.
@(test)
a_dedicated_server_poses_only_what_gameplay_reads :: proc(t:^testing.T) {
    a:Lod_Assets;if !lod_assets(t,&a,"lod-server") {return};defer lod_assets_destroy(&a)
    a.app.played[0]={phases=core.Phases{.Input,.Fixed,.Frame,.Late,.Release}}
    f,drawn:Lod_Test
    if !lod_init(t,&f) || !lod_init(t,&drawn) {return}
    defer {lod_destroy(&f);lod_destroy(&drawn)}
    shown,read:=lod_rig(&f,&a,5,spring=true),lod_rig(&f,&a,5,spring=true)
    lod_rig(&drawn,&a,5,spring=true);lod_rig(&drawn,&a,5,spring=true)
    markers:=0
    for tick in 0..<u64(30) {
        animation_read(&f.requests,read);animation_read(&drawn.requests,read)
        a.app.played_count=1;lod_step(&f,&a.app,tick)
        a.app.played_count=0;lod_step(&drawn,&a.app,tick)
        for rig in ([2]core.Entity{shown,read}) {
            state,reference:=constraint_playing(core.ref(&f.playback),rig),constraint_playing(core.ref(&drawn.playback),rig)
            if !testing.expect(t,state!=nil && reference!=nil) {return}
            testing.expectf(t,state.time==reference.time && state.motion==reference.motion && lod_markers(&f,rig)==lod_markers(&drawn,rig),"tick %d: its clock, markers and root motion run",tick)
            if rig==read {
                testing.expectf(t,state.lod==Rig_Lod{} && slice.equal(playing_pose(state,.Local),playing_pose(reference,.Local)),"tick %d: what gameplay reads is posed in full",tick)
            } else {
                testing.expectf(t,state.lod.skip && state.lod.plain && !state.pose_ready && state.finished==0,"tick %d: what is only drawn is not posed: %v",tick,state.lod)
            }
        }
        markers+=lod_markers(&f,shown)
    }
    testing.expect(t,markers>0)
    lod_problems(t,&f)
}
