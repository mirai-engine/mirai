package cinematics

import "core:testing"
import "mirai:asset"
import "mirai:core"
import camera "mirai:engine/camera"
import input "mirai:engine/input"
import render "mirai:engine/render"
import "mirai:host"
import lib "mirai:std/anim"
import "mirai:std/base"
import mm "mirai:std/math"
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
    modifiers:core.Table(anim.Pose_Modifiers),
    attachments:core.Table(anim.Bone_Attachment),
    sources:core.Table(anim.Pose_Source),
    cinematics:core.Table(Cinematic),
    shots:core.Table(Cinematic_Shot),
    viewers:core.Table(Cinematic_Viewer),
    views:core.Table(Cinematic_View),
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
    action_requests:anim.Action_Requests,
    motion_requests:anim.Motion_Requests,
    shown:camera.Cameras,
    seat_state:input.Seats,
    camera_requests:camera.Camera_Requests,
    seat_requests:input.Seat_Requests,
}

@(private="file")
cinematic_types :: proc(types:^[dynamic]core.Test_Type) {
    camera.test_types(types)
    anim.test_types(types)
}

@(private="file")
Cinematic_Shared :: struct {
    poses:anim.Pose_Assets,
    skeletons:anim.Skeleton_Assets,
    blends:anim.Blend_Assets,
    graphs:anim.Graph_Assets,
    actions:anim.Actions_Assets,
    sources:anim.Source_Assets,
}

// A tick of the game for a timeline: its commands, its clip, the fields and the transforms the
// clip writes, and then what the viewers see of it.
@(private="file")
cinematic_tick :: proc(w:^Cinematic_World,s:^Cinematic_Shared,app:^host.App,problems:^core.Problems,tick:u64,dt:f32) {
    time:=core.Time{dt=dt,tick=tick,playing=true}
    anim.animation_sample(core.read(&w.animations),&w.progress,core.read(&w.modifiers),core.read(&w.attachments),&w.transforms,core.read(&w.parents),core.ref(&w.hierarchy),core.read(&w.names),core.read(&w.targets),core.read(&w.meshes),core.read(&w.sources),&w.requests,&w.events,&w.modifier_requests,&w.modifier_runtime,&w.playback,&s.poses,&s.skeletons,app,time,{},problems,&s.blends,&s.graphs,&w.actions,&w.action_requests,&s.actions,nil,&w.motion_requests,nil,&s.sources,{},core.CLOCK_DEFAULT,anim.ANIMATION_BUDGET_CONFIG_DEFAULT)
    core.test_world_settle(w)
    anim.animation_fields(core.test_world_ref(w),core.ref(&w.playback),&w.fields,core.ref(&s.sources),app,problems)
    anim.animation_advance(core.read(&w.modifiers),&w.transforms,core.read(&w.parents),{},&w.modifier_requests,&w.modifier_runtime,&w.playback,&w.constraints,&w.grounding,{},{},time,&w.requests,core.ref(&s.skeletons),problems,nil,nil,{},{},core.CLOCK_DEFAULT,nil)
    cinematic_advance(core.ref(&w.entities),&w.cinematics,core.read(&w.shots),core.read(&w.viewers),&w.views,core.read(&w.cameras),core.read(&w.drivables),&w.transforms,core.read(&w.parents),core.read(&w.animations),core.ref(&w.playback),core.ref(&w.shown),core.ref(&w.seat_state),&w.camera_requests,&w.seat_requests,core.read(&w.seats),time,core.read(&w.remotes),problems)
    core.test_world_settle(w)
}

// A cinematic is a clip with shots: the clip moves the cameras and writes their lens as it does
// any entity and field, and the viewer shows the camera of the shot in force as the clip left it
// in the tick, while the clip plays.
@(test)
a_viewer_shows_the_shots_of_a_clip_while_it_plays :: proc(t:^testing.T) {
    DT :: f32(.25)
    problems:core.Problems
    assets:host.Assets;app:=host.App{assets=&assets,allocator=context.allocator};defer host.app_content_destroy(&app)
    s:Cinematic_Shared
    defer {anim.pose_assets_free(&s.poses);anim.skeleton_assets_free(&s.skeletons);anim.blend_assets_free(&s.blends);anim.graph_assets_free(&s.graphs);anim.actions_assets_free(&s.actions);anim.source_assets_free(&s.sources)}
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
        source:=host.Content_Animation{id=id,generation=1,clip_count=1}
        if !testing.expect(t,lib.library_init(&source.lib,{max_clips=2,max_tracks=2,max_keys=4,allocator=app.allocator})) {return}
        clip,_:=lib.clip_add(&source.lib,{name=base.name_hash("intro"),tracks=tracks})
        host.content_animation_loops(&source.lib,1)
        source.names=make([][asset.ANIMATION_NAME_CAPACITY]u8,1,app.allocator)
        source.roots=make([]asset.Animation_Root,1,app.allocator)
        source.fields,_=host.content_animation_fields({tracks=rows[:]},app.allocator)
        content:=host.app_content(&app)
        append(&content.animations,source);content.index[id]={kind=.Animation,index=0}
        if !testing.expect(t,clip==1 && len(source.fields)==1) {return}
    }
    w:Cinematic_World
    if !core.test_world_init(t,&w,cinematic_types) {return}
    defer core.test_world_destroy(&w)
    es:=&w.entities
    actor :: proc(w:^Cinematic_World,timeline:core.Entity,name:string,position:[3]f32) -> core.Entity {
        e:=core.create(&w.entities)
        transform:=core.TRANSFORM_IDENTITY;transform.position=position
        core.add(&w.transforms,e,transform)
        lens:=render.CAMERA_DEFAULT;lens.fov,lens.near=1,.1
        core.add(&w.cameras,e,lens)
        if name!="" {
            target:anim.Animation_Target;base.text_set(target.path[:],name);target.animation=timeline
            core.add(&w.targets,e,target)
        }
        return e
    }
    timeline,seat:=core.create(es),core.create(es)
    core.add(&w.transforms,timeline,core.TRANSFORM_IDENTITY)
    wide,close,output:=actor(&w,timeline,"wide",{0,0,0}),actor(&w,timeline,"close",{0,5,0}),actor(&w,core.NONE,"",{9,9,9})
    animation:=anim.ANIMATION_DEFAULT;animation.asset,animation.loop,animation.fade=id,false,0
    core.add(&w.animations,timeline,animation)
    core.add(&w.cinematics,timeline,Cinematic{})
    core.add(&w.shots,wide,Cinematic_Shot{timeline=timeline,camera=wide})
    core.add(&w.shots,close,Cinematic_Shot{timeline=timeline,camera=close,time=.5,blend=.5})
    core.add(&w.viewers,output,Cinematic_Viewer{timeline=timeline,seat=seat})
    core.test_world_settle(&w)
    core.hierarchy_settle(&w.hierarchy,core.read(&w.parents),&w.entities)
    shown :: proc(w:^Cinematic_World,e:core.Entity) -> [3]f32 {value,_:=core.get(core.read(&w.transforms),e);return value.position}
    asked :: proc(w:^Cinematic_World,owner:core.Entity) -> (fov:f32,found:bool) {
        #reverse for request in w.camera_requests.items {if request.add && request.override.owner==owner {return request.override.fov,true}}
        return
    }

    // The clip plays by itself, as the Animation of the timeline says: the first shot shows the
    // camera where the clip put it in this tick.
    cinematic_tick(&w,&s,&app,&problems,1,DT)
    c,_:=core.get(core.read(&w.cinematics),timeline)
    testing.expect(t,c.status==.Playing && c.time==.25 && c.duration==1)
    testing.expect_value(t,shown(&w,wide),[3]f32{2,0,0})
    testing.expect_value(t,shown(&w,output),[3]f32{2,0,0})
    fov,found:=asked(&w,output)
    testing.expect(t,found && fov==1)
    view,viewing:=core.get(core.read(&w.views),output)
    testing.expect(t,viewing && view.shot_camera==wide && view.seat==seat)

    // The second shot blends in from the first; its lens is the one the clip writes on its camera.
    cinematic_tick(&w,&s,&app,&problems,2,DT)
    testing.expect_value(t,shown(&w,output),[3]f32{4,0,0})
    cinematic_tick(&w,&s,&app,&problems,3,DT)
    lens,_:=core.get(core.read(&w.cameras),close)
    testing.expect_value(t,lens.fov,f32(.625))
    testing.expect_value(t,shown(&w,output),[3]f32{3,2.5,0})
    fov,_=asked(&w,output)
    testing.expect_value(t,fov,f32(.8125))

    // Paused, the viewer keeps showing it; at its end the viewer gives the seat its view back.
    anim.animation_command(&w.requests,timeline,.Pause)
    cinematic_tick(&w,&s,&app,&problems,4,DT)
    c,_=core.get(core.read(&w.cinematics),timeline)
    testing.expect(t,c.status==.Paused && core.has(&w.views,output))
    anim.animation_command(&w.requests,timeline,.Resume)
    clear(&w.camera_requests.items)
    cinematic_tick(&w,&s,&app,&problems,5,DT)
    c,_=core.get(core.read(&w.cinematics),timeline)
    testing.expect(t,c.status==.Completed && c.time==1 && !core.has(&w.views,output))
    testing.expect(t,len(w.camera_requests.items)==1 && !w.camera_requests.items[0].add && w.camera_requests.items[0].override.owner==output)
    testing.expect(t,problems.count==0)

    // On an end that does not decide the timeline, the clip is asked to go where the anchor says.
    core.add(&w.remotes,timeline,core.Remote{});core.test_world_settle(&w)
    remote:=core.get(&w.cinematics,timeline)
    remote.status,remote.anchor_tick,remote.anchor_time,remote.anchor_rate=.Playing,10,.25,1
    clear(&w.requests.timeline.items)
    cinematic_follow(core.read(&w.cinematics),core.read(&w.animations),core.ref(&w.playback),&w.requests,{dt=DT,tick=11,playing=true},core.read(&w.remotes))
    commands:=w.requests.timeline.items[:]
    testing.expect(t,len(commands)==1 && commands[0]==anim.Animation_Command{timeline,.25,.Seek},"a clip that plays is sought a tick before the half second the anchor gives the end of the tick")
    clear(&w.requests.timeline.items)
    remote.status,remote.anchor_time,remote.anchor_rate=.Paused,.75,0
    cinematic_follow(core.read(&w.cinematics),core.read(&w.animations),core.ref(&w.playback),&w.requests,{dt=DT,tick=40,playing=true},core.read(&w.remotes))
    commands=w.requests.timeline.items[:]
    testing.expect(t,len(commands)==2 && commands[0].command==.Pause && commands[1]==anim.Animation_Command{timeline,.75,.Seek},"paused by the server, it pauses where the anchor is")
    clear(&w.requests.timeline.items)
    core.remove(&w.remotes,timeline);core.test_world_settle(&w)

    // A Cinematic whose entity has no Animation says so.
    bare:=core.create(es)
    core.add(&w.cinematics,bare,Cinematic{});core.test_world_settle(&w)
    cinematic_tick(&w,&s,&app,&problems,7,DT)
    testing.expect(t,core.problem_find(&problems,bare,"cinematics.animation")!=nil)
}

@(test)
the_shot_in_force_blends_in_from_the_one_before_it :: proc(t:^testing.T) {
    w:Cinematic_World
    if !core.test_world_init(t,&w,cinematic_types) {return}
    defer core.test_world_destroy(&w)
    es,shots:=&w.entities,&w.shots
    timeline,first,second:=core.create(es),core.create(es),core.create(es)
    core.add(shots,core.create(es),Cinematic_Shot{timeline=timeline,camera=second,time=3,blend=1})
    core.add(shots,core.create(es),Cinematic_Shot{timeline=timeline,camera=first})
    core.add(shots,core.create(es),Cinematic_Shot{timeline=core.create(es),camera=first,time=2})
    core.test_world_settle(&w)
    nan:=f32(0h7fc00000)
    for time in ([]f32{-1,nan}) {
        _,_,found:=cinematic_shots_at(core.read(shots),timeline,time)
        testing.expect(t,!found)
    }
    current,previous,_:=cinematic_shots_at(core.read(shots),timeline,2.95)
    testing.expect_value(t,current.camera,first)
    testing.expect_value(t,previous.camera,core.NONE)
    current,previous,_=cinematic_shots_at(core.read(shots),timeline,3.5)
    testing.expect_value(t,current.camera,second)
    testing.expect_value(t,previous.camera,first)
    from:=Camera_Sample{pose=mm.TRANSFORM_IDENTITY,fov=1,near=0.1}
    to:=from;to.pose.position={10,0,0};to.fov=2
    halfway:=cinematic_shot_blend(current,from,to,3.5)
    testing.expect_value(t,halfway.pose.position.x,f32(5))
    testing.expect_value(t,halfway.fov,f32(1.5))
    for time in ([]f32{4,2.9,nan}) {testing.expect_value(t,cinematic_shot_blend(current,from,to,time),to)}
    current.blend=nan
    testing.expect_value(t,cinematic_shot_blend(current,from,to,3.5),to)
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
