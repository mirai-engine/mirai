package cinematics

import "core:testing"
import "mirai:asset"
import "mirai:core"
import cam "mirai:engine/camera"
import input "mirai:engine/input"
import render "mirai:engine/render"
import "mirai:host"
import lib "mirai:std/anim"
import "mirai:std/base"
import anim "plugins:animation/runtime"

@(private="file")
Cinematic_World :: struct {
    using world:core.Test_World,
    transforms:core.Table(core.Transform),
    parents:core.Table(core.Parent),
    names:core.Table(core.Name),
    cameras:core.Table(render.Camera),
    meshes:core.Table(render.Mesh_Renderer),
    targets:core.Table(anim.Animation_Target),
    animations:core.Table(anim.Animation),
    progress:core.Table(anim.Animation_Progress),
    attachments:core.Table(anim.Bone_Attachment),
    sources:core.Table(anim.Pose_Source),
    cinematics:core.Table(Cinematic),
    activations:core.Table(cam.Camera_Activation),
    follows:core.Table(cam.Camera_Follow),
    drivables:core.Table(input.Drivable),
    seats:core.Table(input.Seat),
    remotes:core.Table(core.Remote),
    hierarchy:core.Hierarchy,
    playback:anim.Playback,
    fields:anim.Field_Playback,
    requests:anim.Animation_Requests,
    events:anim.Animation_Events,
    constraints:anim.Animation_Constraints,
    modifier_runtime:anim.Modifier_Runtime,
    modifier_requests:anim.Modifier_Requests,
    grounding:anim.Grounding_Runtime,
    actions:anim.Action_Runtime,
    motion_requests:anim.Motion_Requests,
    shown:cam.Cameras,
    seat_state:input.Seats,
    camera_requests:cam.Camera_Requests,
    seat_requests:input.Seat_Requests,
}

@(private="file")
cinematic_types :: proc(types:^[dynamic]core.Test_Type) {
    cam.test_types(types)
    anim.test_types(types)
}

// The clip "intro" and what it moves: it dollies the camera "wide" from 0 to 8 on x in a second and
// narrows the lens of "close"; its markers cut to wide at 0, wave the actor "hero" from .25 to .5,
// blend into close from .5 over half a second and cut to "gone" at .75.
@(private="file")
Cinematic_Fixture :: struct {
    using w:Cinematic_World,
    problems:core.Problems,
    assets:host.Assets,
    app:host.App,
    characters:anim.Character_Assets,
    skeletons:anim.Skeleton_Assets,
    content_sources:anim.Source_Assets,
    timeline,seat,wide,close,hero,gone:core.Entity,
}

@(private="file")
fixture_init :: proc(t:^testing.T,f:^Cinematic_Fixture) -> bool {
    f.app={assets=&f.assets,allocator=context.allocator}
    id:=base.Asset_Id{0xc1,0xc2}
    {
        dolly:=[]lib.Keyframe{{time=0,value={0,0,0,0}},{time=1,value={8,0,0,0}}}
        zoom:=[]lib.Keyframe{{time=0,value={1,0,0,0}},{time=1,value={.5,0,0,0}}}
        tracks:=[]lib.Track_Desc{
            {target=base.name_hash("wide"),property=.Position,keys=dolly},
            {target=base.name_hash("close/@field/Camera.fov"),property=.Float,keys=zoom},
        }
        rows:[2]asset.Animation_Track
        base.text_set(rows[0].target[:],"wide");rows[0].property=.Position
        base.text_set(rows[1].target[:],"close/@field/Camera.fov");rows[1].property=.Float
        named:=[]asset.Animation_Marker_Desc{{0,"Shot",0,"wide"},{.25,"Wave",.25,"hero"},{.5,"Shot",.5,"close"},{.75,"Shot",0,"gone"}}
        marks:=make([]lib.Marker,len(named),context.temp_allocator)
        source:=host.Content_Animation{id=id,generation=1,clip_count=1}
        source.markers=make([]host.Content_Marker,len(named),f.app.allocator)
        for marker,i in named {
            marks[i]={time=marker.time,id=u32(i),duration=marker.duration}
            source.markers[i]={name=base.name_hash(marker.name),target=base.name_hash(marker.target)}
            base.text_set(source.markers[i].text[:],marker.name)
        }
        if !testing.expect(t,lib.library_init(&source.lib,{max_clips=2,max_tracks=2,max_keys=4,max_markers=len(named),allocator=f.app.allocator})) {return false}
        clip,_:=lib.clip_add(&source.lib,{name=base.name_hash("intro"),tracks=tracks,markers=marks})
        host.content_animation_loops(&source.lib,1)
        source.names=make([][asset.ANIMATION_NAME_CAPACITY]u8,1,f.app.allocator)
        source.roots=make([]asset.Animation_Root,1,f.app.allocator)
        source.fields,_=host.content_animation_fields({tracks=rows[:]},f.app.allocator)
        content:=host.app_content(&f.app)
        append(&content.animations,source);content.index[id]={kind=.Animation,index=0}
        if !testing.expect(t,clip==1 && len(source.fields)==1) {return false}
    }
    if !core.test_world_init(t,&f.w,cinematic_types) {return false}
    es:=&f.entities
    actor :: proc(f:^Cinematic_Fixture,name:string,position:[3]f32,lens:bool) -> core.Entity {
        e:=core.create(&f.entities)
        transform:=core.TRANSFORM_IDENTITY;transform.position=position
        core.add(&f.transforms,e,transform)
        if lens {
            value:=render.CAMERA_DEFAULT;value.fov,value.near=1,.1
            core.add(&f.cameras,e,value)
        }
        target:anim.Animation_Target;base.text_set(target.path[:],name);target.animation=f.timeline
        core.add(&f.targets,e,target)
        return e
    }
    f.timeline,f.seat=core.create(es),core.create(es)
    core.add(&f.transforms,f.timeline,core.TRANSFORM_IDENTITY)
    f.wide,f.close,f.gone=actor(f,"wide",{0,0,0},true),actor(f,"close",{0,5,0},true),actor(f,"gone",{0,9,0},true)
    f.hero=actor(f,"hero",{1,0,1},false)
    animation:=anim.ANIMATION_DEFAULT;animation.asset,animation.loop,animation.fade=id,false,0
    core.add(&f.animations,f.timeline,animation)
    core.add(&f.cinematics,f.timeline,Cinematic{seat=f.seat,block_mask=3})
    core.test_world_settle(&f.w)
    core.hierarchy_settle(&f.hierarchy,core.read(&f.parents),&f.entities)
    return true
}

@(private="file")
fixture_destroy :: proc(f:^Cinematic_Fixture) {
    core.test_world_destroy(&f.w)
    anim.character_assets_free(&f.characters);anim.skeleton_assets_free(&f.skeletons);anim.source_assets_free(&f.content_sources)
    host.app_content_destroy(&f.app)
}

// A tick of the game for a timeline, in the order of its stages: the camera overrides asked in the
// tick before, the commands and the clip, the fields and the transforms the clip writes, and then
// what the timeline asks of it. acting runs before the timeline: what the actions play then.
@(private="file")
fixture_tick :: proc(f:^Cinematic_Fixture,tick:u64,dt:f32,playing:=true,acting:proc(f:^Cinematic_Fixture)=nil) {
    time:=core.Time{dt=dt,tick=tick,playing=playing}
    cam.camera_select(core.ref(&f.entities),core.read(&f.cameras),&f.shown,&f.camera_requests,core.read(&f.activations),core.read(&f.follows),core.read(&f.drivables),core.read(&f.seats),core.ref(&f.seat_state),&f.problems)
    anim.animation_sample(core.read(&f.animations),&f.progress,core.read(&f.attachments),&f.transforms,core.read(&f.parents),core.ref(&f.hierarchy),core.read(&f.names),core.read(&f.targets),core.read(&f.meshes),core.read(&f.sources),&f.requests,&f.events,&f.modifier_requests,&f.modifier_runtime,&f.playback,&f.characters,&f.skeletons,&f.app,time,{},&f.problems,&f.actions,nil,&f.motion_requests,&f.content_sources,{},core.CLOCK_DEFAULT,anim.ANIMATION_BUDGET_CONFIG_DEFAULT)
    core.test_world_settle(&f.w)
    anim.animation_fields(core.test_world_ref(&f.w),core.ref(&f.playback),&f.fields,core.ref(&f.content_sources),&f.app,&f.problems)
    anim.animation_advance(&f.transforms,core.read(&f.parents),{},&f.modifier_requests,&f.modifier_runtime,&f.playback,&f.constraints,&f.grounding,{},{},time,&f.requests,core.ref(&f.skeletons),&f.problems,nil,&f.characters,{},{},core.CLOCK_DEFAULT,nil)
    if acting!=nil {acting(f)}
    cinematic_advance(core.ref(&f.entities),&f.cinematics,core.read(&f.cameras),core.read(&f.animations),core.ref(&f.playback),core.ref(&f.content_sources),&f.app,core.ref(&f.actions),&f.requests,core.ref(&f.shown),core.ref(&f.seat_state),&f.camera_requests,&f.seat_requests,core.read(&f.seats),time,core.read(&f.remotes),&f.problems)
    core.test_world_settle(&f.w)
}

// A cinematic is a clip whose markers stage it: one on a camera is a shot, which the timeline asks
// of engine/camera as the camera_override of its seat with the blend of the marker, while the clip
// plays or is paused; one on an actor plays the action of its name there and a span stops it at
// its end. A marker on an entity that is gone is a problem, never a crash.
@(test)
the_markers_of_a_clip_cut_between_cameras_and_play_actions_while_it_plays :: proc(t:^testing.T) {
    DT :: f32(.25)
    f:=new(Cinematic_Fixture);defer free(f)
    if !fixture_init(t,f) {return}
    defer fixture_destroy(f)
    core.destroy(&f.entities,f.gone);core.test_world_settle(&f.w)
    asked :: proc(f:^Cinematic_Fixture,camera:core.Entity,seconds:f32) -> cam.Camera_Request {
        r:cam.Camera_Requests
        cam.camera_override(&r,f.timeline,f.seat,camera,blend={seconds,cam.CAMERA_BLEND.ease})
        defer delete(r.items)
        return r.items[0]
    }
    plays :: proc(f:^Cinematic_Fixture) -> (asked:[dynamic]anim.Play_Request) {
        for request in f.requests.plays.items {append(&asked,request)}
        clear(&f.requests.plays.items)
        return
    }

    // The clip plays by itself: the first shot cuts to wide, the input of the seat is blocked, and
    // the actor starts to wave.
    fixture_tick(f,1,DT)
    c,_:=core.get(core.read(&f.cinematics),f.timeline)
    testing.expect(t,c.status==.Playing && c.time==.25 && c.duration==1)
    testing.expect(t,len(f.camera_requests.items)==1 && f.camera_requests.items[0]==asked(f,f.wide,0))
    testing.expect(t,len(f.seat_requests.items)==1 && f.seat_requests.items[0].kind==.Block_Add && f.seat_requests.items[0].mask==3)
    clear(&f.seat_requests.items)
    waves:=plays(f);defer delete(waves)
    testing.expect(t,len(waves)==1 && !waves[0].stop && waves[0].entity==f.hero && base.text_get(waves[0].action[:])=="Wave")

    // At the end of its span the wave is stopped, while it plays; the shot of close is asked with the
    // blend of its marker, as camera_override asks it.
    fixture_tick(f,2,DT,acting=proc(f:^Cinematic_Fixture) {
        profile:anim.Action_Profile
        profile.actions=make([]anim.Action_Definition,1,context.temp_allocator);base.text_set(profile.actions[0].name[:],"Wave")
        append(&f.actions.plans,anim.Action_Plan{profile=profile})
        state:=anim.Action_State{entity=f.hero};state.slots[0]={active=true}
        append(&f.actions.states,state)
        resize(&f.actions.rows,core.entity_index(f.hero)+1);f.actions.rows[core.entity_index(f.hero)]=i32(len(f.actions.states))
    })
    clear(&f.actions.plans);clear(&f.actions.states);clear(&f.actions.rows)
    stops:=plays(f);defer delete(stops)
    testing.expect(t,len(stops)==1 && stops[0].stop && stops[0].entity==f.hero)
    testing.expect(t,len(f.camera_requests.items)==1 && f.camera_requests.items[0]==asked(f,f.close,.5))
    fixture_tick(f,3,DT)
    testing.expect_value(t,cam.camera_selected(&f.shown,core.read(&f.drivables),core.read(&f.cameras),f.seat),f.close)
    testing.expect(t,len(f.camera_requests.items)==0,"the shot in force is asked once")
    lens,_:=core.get(core.read(&f.cameras),f.close)
    testing.expect_value(t,lens.fov,f32(.625))
    testing.expect(t,core.problem_find(&f.problems,f.timeline,"cinematics.marker_target")!=nil,"the shot on the camera that is gone is reported and left out")

    // Paused, the shot stays; at the end of the clip the seat gets its view and its input back.
    anim.animation_command(&f.requests,f.timeline,.Pause)
    fixture_tick(f,4,DT)
    c,_=core.get(core.read(&f.cinematics),f.timeline)
    testing.expect(t,c.status==.Paused && len(f.camera_requests.items)==0)
    anim.animation_command(&f.requests,f.timeline,.Resume)
    clear(&f.seat_requests.items)
    fixture_tick(f,5,DT)
    c,_=core.get(core.read(&f.cinematics),f.timeline)
    testing.expect(t,c.status==.Completed && c.time==1)
    testing.expect(t,len(f.camera_requests.items)==1 && !f.camera_requests.items[0].add && f.camera_requests.items[0].override.owner==f.timeline)
    testing.expect(t,len(f.seat_requests.items)==0,"no block is asked once it ends")

    // On an end that does not decide the timeline, the clip is asked to go where the anchor says.
    core.add(&f.remotes,f.timeline,core.Remote{});core.test_world_settle(&f.w)
    remote:=core.edit(&f.cinematics,f.timeline)
    remote.status,remote.anchor_tick,remote.anchor_time,remote.anchor_rate=.Playing,10,.25,1
    clear(&f.requests.timeline.items)
    cinematic_follow(core.read(&f.cinematics),core.read(&f.animations),core.ref(&f.playback),&f.requests,{dt=DT,tick=11,playing=true},core.read(&f.remotes))
    commands:=f.requests.timeline.items[:]
    testing.expect(t,len(commands)==1 && commands[0]==anim.Animation_Command{f.timeline,.25,.Seek},"a clip that plays is sought a tick before the half second the anchor gives the end of the tick")
    clear(&f.requests.timeline.items)
    remote.status,remote.anchor_time,remote.anchor_rate=.Paused,.75,0
    cinematic_follow(core.read(&f.cinematics),core.read(&f.animations),core.ref(&f.playback),&f.requests,{dt=DT,tick=40,playing=true},core.read(&f.remotes))
    commands=f.requests.timeline.items[:]
    testing.expect(t,len(commands)==2 && commands[0].command==.Pause && commands[1]==anim.Animation_Command{f.timeline,.75,.Seek},"paused by the server, it pauses where the anchor is")
    clear(&f.requests.timeline.items)
    core.remove(&f.remotes,f.timeline);core.test_world_settle(&f.w)

    // A Cinematic whose entity has no Animation says so.
    bare:=core.create(&f.entities)
    core.add(&f.cinematics,bare,Cinematic{});core.test_world_settle(&f.w)
    fixture_tick(f,7,DT)
    testing.expect(t,core.problem_find(&f.problems,bare,"cinematics.animation")!=nil)
}

// The editor scrubs a timeline by seeking its clip: whatever the order of the heads, a head shows the
// same cameras where the clip puts them and the same shot, which blends in from the one before it.
@(test)
a_head_of_a_scrubbed_clip_shows_one_shot :: proc(t:^testing.T) {
    f:=new(Cinematic_Fixture);defer free(f)
    if !fixture_init(t,f) {return}
    defer fixture_destroy(f)
    Seen :: struct {shot,previous:Shot,wide:[3]f32,fov:f32}
    look :: proc(f:^Cinematic_Fixture,head:f32) -> (seen:Seen) {
        anim.animation_seek(&f.requests,f.timeline,head)
        fixture_tick(f,1,0,playing=false)
        seen.shot,seen.previous=cinematic_shot(&f.playback,&f.content_sources,&f.app,&f.entities,core.read(&f.cameras),f.timeline,head)
        place,_:=core.get(core.read(&f.transforms),f.wide);seen.wide=place.position
        lens,_:=core.get(core.read(&f.cameras),f.close);seen.fov=lens.fov
        return
    }
    nan:=f32(0h7fc00000)
    late,early:=look(f,.6),look(f,.25)
    testing.expect_value(t,look(f,.6),late)
    testing.expect_value(t,look(f,.25),early)
    testing.expect(t,late.shot.camera==f.close && late.shot.time==.5 && late.shot.blend.seconds==.5 && late.previous.camera==f.wide)
    testing.expect(t,early.shot.camera==f.wide && early.previous.camera==core.NONE && early.wide==[3]f32{2,0,0})
    testing.expect_value(t,look(f,.9).shot.camera,f.gone)
    shot,previous:=cinematic_shot(&f.playback,&f.content_sources,&f.app,&f.entities,core.read(&f.cameras),f.timeline,nan)
    testing.expect(t,shot.camera==core.NONE && previous.camera==core.NONE,"no time of the clip has no shot")
    core.destroy(&f.entities,f.gone);core.test_world_settle(&f.w)
    testing.expect_value(t,look(f,.9).shot.camera,f.close)
}

// The state a timeline sends over the network is an anchor: every end finds the same time of
// the clip for the same tick, and a clip that is elsewhere is sought there.
@(test)
an_anchor_gives_the_time_of_a_clip_at_a_tick :: proc(t:^testing.T) {
    DT :: f32(1.0/60)
    nan:=f32(0h7fc00000)
    Case :: struct {name:string,c:Cinematic,tick:u64,duration:f32,loop:bool,want:f32}
    cases:=[]Case{
        {"at its anchor",{anchor_tick=100,anchor_time=1,anchor_rate=1},100,4,false,1},
        {"a second later",{anchor_tick=100,anchor_time=1,anchor_rate=1},160,4,false,2},
        {"before its anchor it is the anchor",{anchor_tick=100,anchor_time=1,anchor_rate=1},40,4,false,1},
        {"paused it stays",{anchor_tick=100,anchor_time=1},400,4,false,1},
        {"at half speed",{anchor_tick=0,anchor_time=0,anchor_rate=.5},120,4,false,1},
        {"backwards",{anchor_tick=0,anchor_time=3,anchor_rate=-1},60,4,false,2},
        {"it holds its end",{anchor_tick=0,anchor_time=3,anchor_rate=1},600,4,false,4},
        {"it holds its start",{anchor_tick=0,anchor_time=1,anchor_rate=-1},600,4,false,0},
        {"a loop folds",{anchor_tick=0,anchor_time=3,anchor_rate=1},120,4,true,1},
        {"a clip of no length",{anchor_tick=0,anchor_time=3,anchor_rate=1},60,0,true,4},
        {"a time that is no number",{anchor_tick=0,anchor_time=nan,anchor_rate=1},60,4,true,0},
        {"a rate that is no number",{anchor_tick=0,anchor_time=1,anchor_rate=nan},60,4,false,0},
    }
    for c in cases {
        got:=cinematic_anchored(c.c,c.tick,DT,c.duration,c.loop)
        testing.expectf(t,abs(got-c.want)<1e-4,"%s: %v, not %v",c.name,got,c.want)
    }
    testing.expect_value(t,cinematic_status(true,true,4),Cinematic_Status.Completed)
    testing.expect_value(t,cinematic_status(true,false,0),Cinematic_Status.Playing)
    testing.expect_value(t,cinematic_status(false,false,2),Cinematic_Status.Paused)
    testing.expect_value(t,cinematic_status(false,false,0),Cinematic_Status.Stopped)
}
