package cinematics

import "core:math"
import "mirai:core"
import camera "mirai:engine/camera"
import input "mirai:engine/input"
import render "mirai:engine/render"
import mm "mirai:std/math"
import anim "plugins:animation/runtime"

// Cinematics: what the players see of a timeline. The timeline is the clip of
// the Animation of an entity: its tracks move the cameras and the actors (an
// anim.Animation_Target names the ones that are not below it) and write their
// fields, anim.animation_command plays, pauses, stops and seeks it as any
// other clip (anim.animation_playing says whether it plays), and its markers
// arrive in anim.Animation_Events. What this
// library adds hangs from that entity:
//
//   Cinematic         on the timeline: where its clip is, for its shots and for the network
//   Cinematic_Shot    which camera the viewers see from a time of the clip on
//   Cinematic_Viewer  on a camera: the camera a seat sees the shots through
//
// The viewer owns the Transform of its camera; its camera is the only one this
// library moves. While the clip plays or is paused, the viewer asks
// engine/camera to show its camera, with the lens of the shot, and engine/input
// to block the actions of its seat.

Cinematic_Status :: enum u8 {
    Stopped,   // at its start, not playing
    Playing,
    Paused,    // not playing, past its start
    Completed, // a clip that does not loop reached its end
}

// In a network session its state travels from the server, which is the one
// whose game plays, pauses or seeks the clip: a client seeks its own clip to
// where the anchor says, so every end shows the same time of the same tick and
// nothing is sent while it plays.
@(component,replicated,description="Makes the clip of the Animation of this entity a cinematic: its shots choose the camera the viewers see, and a network session keeps it at the same time on every end.")
Cinematic :: struct {
    status:Cinematic_Status `mirai:"readonly"`,
    time:f32 `mirai:"readonly,unit=s,local"`,
    duration:f32 `mirai:"readonly,unit=s,local"`,
    anchor_tick:u64 `mirai:"readonly,hidden"`, // tick at which the clip was at anchor_time
    anchor_time:f32 `mirai:"readonly,hidden"`,
    anchor_rate:f32 `mirai:"readonly,hidden"`, // clip seconds per second from the anchor on; 0 while it does not play
}

@(component,description="From a time of the clip of its timeline on, the viewers see through this camera, blended in from the shot before.")
Cinematic_Shot :: struct {
    timeline:core.Entity,
    camera:core.Entity,
    time:f32 `mirai:"min=0,unit=s"`,
    blend:f32 `mirai:"min=0,unit=s"`,
    ease:mm.Ease,
}

// The entity that has it is the output camera: it needs a render.Camera and a Transform.
@(component,locks="core.Transform")
Cinematic_Viewer :: struct {
    timeline:core.Entity,
    seat:core.Entity, // none: the local player
    block_mask:input.Action_Mask, // actions of the seat blocked while it plays; 0 lets the input through
}

// What a viewer shows while its timeline plays: the seat it took the
// view of and the cameras it goes between. It stays with the viewer, so a
// saved game goes on showing it. Only cinematic_advance writes it.
@(component,description="What this cinematic viewer is showing: the seat it took the view of and its shot.")
Cinematic_View :: struct {
    timeline:core.Entity `mirai:"readonly"`,
    seat:core.Entity `mirai:"readonly"`,
    entry_camera:core.Entity `mirai:"readonly"`, // the one the seat saw through before
    shot_camera:core.Entity `mirai:"readonly"`,
    shot_time:f32 `mirai:"readonly,unit=s"`,
    mask:input.Action_Mask `mirai:"readonly,hidden"`,
    fov:f32 `mirai:"readonly,angle"`, // what the viewer shows this tick
    near:f32 `mirai:"readonly,unit=m"`,
    written:core.Transform `mirai:"readonly,hidden"`,
    wrote:bool `mirai:"readonly,hidden"`,
}

@(private)
Cine :: struct {
    cinematics:^core.Table(Cinematic),
    shots:core.Read(Cinematic_Shot),
    cameras:core.Read(render.Camera),
    transforms:^core.Table(core.Transform),
    parents:core.Read(core.Parent),
    views:^core.Table(Cinematic_View),
    shown:core.Ref(camera.Cameras),
    seat_state:core.Ref(input.Seats),
    camera_requests:^camera.Camera_Requests,
    seat_requests:^input.Seat_Requests,
    seats:core.Read(input.Seat),
    problems:^core.Problems,
}

// What the clip of a timeline does, from its Animation and where animation_sample left it.
cinematic_status :: proc "contextless" (playing,ended:bool,time:f32) -> Cinematic_Status {
    switch {
    case ended: return .Completed
    case playing: return .Playing
    case time>0: return .Paused
    }
    return .Stopped
}

// Where a clip is at a tick by its anchor: the time it had then plus what it played since, folded
// into a clip that loops and held at the end of one that does not.
cinematic_anchored :: proc "contextless" (c:Cinematic,tick:u64,dt,duration:f32,loop:bool) -> f32 {
    elapsed:=f32(tick-c.anchor_tick) if tick>c.anchor_tick else 0
    at:=c.anchor_time+elapsed*dt*c.anchor_rate
    if !(abs(at)<=max(f32)) {return 0}
    if duration<=0 {return max(at,0)}
    if loop {
        at-=math.floor(at/duration)*duration
        return at if at>=0 && at<duration else 0
    }
    return clamp(at,0,duration)
}

// How far apart two times of a clip are: around its end and its start for one that loops.
@(private)
clip_apart :: proc "contextless" (a,b,duration:f32,loop:bool) -> f32 {
    apart:=abs(a-b)
    return min(apart,abs(duration-apart)) if loop && duration>0 else apart
}

// On an end that does not decide a timeline, its clip goes where the anchor says it is at the end
// of this tick: asked before animation_sample, which seeks and then advances a clip that plays.
@(step="fixed")
cinematic_follow :: proc(cinematics:core.Read(Cinematic),animations:core.Read(anim.Animation),playback:core.Ref(anim.Playback),requests:^anim.Animation_Requests,time:core.Time,remotes:core.Read(core.Remote)) {
    if !time.playing {return}
    for row in 0..<core.count(cinematics) {
        e:=core.entity_at(cinematics,row)
        if core.owned(remotes,e) {continue}
        c:=core.at(cinematics,row)
        animation,animated:=core.get(animations,e)
        at,duration,_,clipped:=anim.animation_progress(playback.ptr,e)
        if !animated || !clipped {continue}
        playing:=c.status==.Playing
        if anim.animation_playing(playback.ptr,e)!=playing {anim.animation_command(requests,e,.Resume if playing else .Pause,speed=animation.speed)}
        want:=cinematic_anchored(c,time.tick,time.dt,duration,animation.loop)
        step:=time.dt*animation.speed if playing else 0
        ahead:=Cinematic{anchor_time=at,anchor_rate=1}
        if clip_apart(want,cinematic_anchored(ahead,1,step,duration,animation.loop),duration,animation.loop)>time.dt*max(abs(c.anchor_rate),1)*.5 {
            anim.animation_seek(requests,e,max(want-step,0))
        }
    }
}

// Runs after animation_advance, whose Playback it reads: the viewers see the cameras where the clip
// put them in this tick.
@(step="fixed",stage="react")
cinematic_advance :: proc(
    entities:core.Ref(core.Entities),cinematics:^core.Table(Cinematic),shots:core.Read(Cinematic_Shot),viewers:core.Read(Cinematic_Viewer),
    views:^core.Table(Cinematic_View),cameras:core.Read(render.Camera),drivables:core.Read(input.Drivable),transforms:^core.Table(core.Transform),
    parents:core.Read(core.Parent),animations:core.Read(anim.Animation),playback:core.Ref(anim.Playback),
    shown:core.Ref(camera.Cameras),seat_state:core.Ref(input.Seats),camera_requests:^camera.Camera_Requests,seat_requests:^input.Seat_Requests,
    seats:core.Read(input.Seat),time:core.Time,remotes:core.Read(core.Remote),problems:^core.Problems,
) {
    if !time.playing {return}
    p:=Cine{cinematics,shots,cameras,transforms,parents,views,shown,seat_state,camera_requests,seat_requests,seats,problems}
    es:=entities.ptr
    // A viewer that lost its Cinematic_Viewer lets go of what it asked of
    // control; for an entity that is gone, the upkeep of control does it.
    for row in 0..<core.count(views) {
        if e:=core.entity_at(views,row);!core.has(viewers,e) {view_release(&p,e)}
    }
    for row in 0..<core.count(cinematics) {
        e:=cinematics.entities[row]
        was:=core.at(cinematics,row)
        animation,animated:=core.get(animations,e)
        if !animated {
            core.report(problems,e,"cinematics.animation","this Cinematic plays nothing: its entity has no Animation; add one whose asset is the .anim of its clip, with playing set for a timeline that starts by itself")
            continue
        }
        at,duration,ended,clipped:=anim.animation_progress(playback.ptr,e)
        if !clipped {continue}
        next:=was
        next.time,next.duration=at,duration
        if core.owned(remotes,e) {
            next.status=cinematic_status(anim.animation_playing(playback.ptr,e),ended,at)
            rate:=animation.speed if next.status==.Playing else 0
            if next.status!=was.status || rate!=was.anchor_rate || time.tick<was.anchor_tick || clip_apart(cinematic_anchored(was,time.tick,time.dt,duration,animation.loop),at,duration,animation.loop)>time.dt*max(abs(rate),1)*.5 {
                next.anchor_tick,next.anchor_time,next.anchor_rate=time.tick,at,rate
            }
        }
        if next!=was {core.edit_at(cinematics,row)^=next}
    }
    for row in 0..<core.count(viewers) {
        viewer_update(&p,es,core.entity_at(viewers,row),core.at(viewers,row),drivables)
    }
}

Camera_Sample :: struct {
    pose:mm.Transform,
    fov,near:f32,
}

// The shot in force at a time and the one before it.
cinematic_shots_at :: proc(shots:core.Read(Cinematic_Shot),timeline:core.Entity,time:f32) -> (current,previous:Cinematic_Shot,found:bool) {
    for row in 0..<core.count(shots) {
        shot:=core.at(shots,row)
        if shot.timeline!=timeline || !(shot.time<=time) {continue}
        if !found || shot.time>current.time {current,found=shot,true}
    }
    if !found {return}
    previous_found:=false
    for row in 0..<core.count(shots) {
        shot:=core.at(shots,row)
        if shot.timeline!=timeline || !(shot.time<current.time) {continue}
        if !previous_found || shot.time>previous.time {previous,previous_found=shot,true}
    }
    return
}

// The view of a shot that is still blending in at a time, mixed from the
// view it comes from; any other time keeps the view of the shot.
cinematic_shot_blend :: proc(shot:Cinematic_Shot,from,to:Camera_Sample,time:f32) -> Camera_Sample {
    since:=time-shot.time
    if !(shot.blend>0) || !(since>=0) || since>=shot.blend {return to}
    weight:=mm.ease_apply(shot.ease,since/shot.blend)
    out:=to
    out.pose.position=from.pose.position+(to.pose.position-from.pose.position)*weight
    out.pose.rotation=mm.quat_slerp(from.pose.rotation,to.pose.rotation,weight)
    out.fov=from.fov+(to.fov-from.fov)*weight
    out.near=from.near+(to.near-from.near)*weight
    return out
}

// A camera as a shot shows it: where its transforms put it in the world now, with the lens it has
// now. The clip moves it and writes its lens as it does any entity.
cinematic_camera_sample :: proc(cameras:core.Read(render.Camera),transforms:core.Read(core.Transform),parents:core.Read(core.Parent),e:core.Entity) -> (sample:Camera_Sample,ok:bool) {
    lens:=core.get(cameras,e) or_return
    sample.pose=core.world_of(transforms,parents,e) or_return
    sample.fov,sample.near=lens.fov,lens.near
    return sample,true
}

@(private)
view_release :: proc(p:^Cine,viewer:core.Entity) {
    camera.camera_override_remove(p.camera_requests,viewer)
    input.input_unblock(p.seat_requests,viewer)
    core.remove(p.views,viewer)
}

// The camera, with the lens of the shot, and the blocks of a viewer: when it
// starts, when the lens changes, and again after a saved game brought its
// view back without them.
@(private)
view_ask :: proc(p:^Cine,e,seat:core.Entity,viewer:Cinematic_Viewer,fov,near:f32) {
    camera.camera_override(p.camera_requests,e,seat,e,fov,near)
    if viewer.block_mask!=0 {input.input_block(p.seat_requests,e,seat,viewer.block_mask)}
}

@(private)
viewer_update :: proc(p:^Cine,es:^core.Entities,e:core.Entity,viewer:Cinematic_Viewer,drivables:core.Read(input.Drivable)) {
    c,has_timeline:=core.get(p.cinematics,viewer.timeline)
    ready:=has_timeline && (c.status==.Playing || c.status==.Paused)
    seat:=viewer.seat!=core.NONE?viewer.seat:input.focused(p.seat_state.ptr,p.seats)
    row:=core.edit(p.transforms,e)
    current,previous,shot_found:=cinematic_shots_at(p.shots,viewer.timeline,c.time)
    active:=ready && shot_found && row!=nil && core.alive(es,seat) && core.has(p.cameras,e)

    binding:=core.edit(p.views,e)
    if binding!=nil && (!active || binding.timeline!=viewer.timeline || binding.seat!=seat || binding.mask!=viewer.block_mask) {
        view_release(p,e)
        binding=nil
    }
    if !active {return}
    locals:=core.read(p.transforms)
    sample,valid:=cinematic_camera_sample(p.cameras,locals,p.parents,current.camera)
    if !valid {
        if binding!=nil {view_release(p,e)}
        return
    }
    entry:=binding!=nil?binding.entry_camera:camera.camera_selected(p.shown.ptr,drivables,p.cameras,seat)
    from_camera:=previous.camera!=core.NONE?previous.camera:entry
    if from_camera!=core.NONE && from_camera!=e {
        if from,found:=cinematic_camera_sample(p.cameras,locals,p.parents,from_camera);found {sample=cinematic_shot_blend(current,from,sample,c.time)}
    }
    sample.fov,sample.near=max(sample.fov,0.001),max(sample.near,0.0001)
    if binding!=nil && binding.wrote && row^!=binding.written {
        core.fail("Cinematic_Viewer owns the Transform of entity %v and another library wrote it: only the viewer moves its camera",e)
    }
    if !core.world_set(row,locals,p.parents,e,sample.pose.position,sample.pose.rotation) {
        core.report(p.problems,e,"cinematics.place","this Cinematic_Viewer cannot place its camera where the shot is: a parent of it has a scale of zero; give its parents a scale, or take the camera out of them")
        if binding!=nil {view_release(p,e)}
        return
    }
    if binding!=nil {
        if !camera.camera_overriding(p.shown.ptr,e) || !input.blocking(p.seat_state.ptr,e) && viewer.block_mask!=0 || binding.fov!=sample.fov || binding.near!=sample.near {
            view_ask(p,e,seat,viewer,sample.fov,sample.near)
        }
        binding.shot_camera,binding.shot_time=current.camera,current.time
        binding.fov,binding.near,binding.written,binding.wrote=sample.fov,sample.near,row^,true
        return
    }
    view_ask(p,e,seat,viewer,sample.fov,sample.near)
    core.add(p.views,e,Cinematic_View{
        timeline=viewer.timeline,seat=seat,entry_camera=entry,shot_camera=current.camera,shot_time=current.time,
        mask=viewer.block_mask,fov=sample.fov,near=sample.near,written=row^,wrote=true,
    })
}
