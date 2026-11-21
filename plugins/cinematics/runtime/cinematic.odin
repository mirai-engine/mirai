package cinematics

import "core:math"
import "mirai:core"
import cam "mirai:engine/camera"
import input "mirai:engine/input"
import render "mirai:engine/render"
import "mirai:host"
import "mirai:std/base"
import anim "plugins:animation/runtime"

// Cinematics: what the players see of a timeline. The timeline is the clip of the Animation of an
// entity with a Cinematic: its tracks move the cameras and the actors (an anim.Animation_Target
// names the ones that are not below it) and write their fields, anim.animation_command plays,
// pauses, stops and seeks it as any other clip, and its markers arrive in anim.Animation_Events.
// The markers of the clip that name an entity stage it:
//
//   on a camera   a shot: from its time on the seat sees through that camera, which
//                 engine/camera blends in over its duration (0: a cut)
//   on an actor   the action of its name, driven by the clip (anim.play_at) from its time to
//                 the end of its span, or of the clip for a moment
//
// While the clip plays or is paused with a shot in force, the timeline is the owner of a camera
// override of its seat and of an input block of block_mask; they go when it stops or ends. In the
// editor the actors take the pose of the head of the clip.

Cinematic_Status :: enum u8 {
    Stopped,   // at its start, not playing
    Playing,
    Paused,    // not playing, past its start
    Completed, // a clip that does not loop reached its end
}

@(component,description="Makes the clip of the Animation of this entity a cinematic: its markers on cameras are the shots a seat sees and those on actors play their actions.")
Cinematic :: struct {
    seat:core.Entity,              // whose view the shots take; none: the focused local player
    block_mask:input.Action_Mask,  // actions blocked while a shot shows; 0 lets input through
}

// The server sends an anchor when playback changes. Each client derives its
// playback position from that anchor and its own clip.
@(component,derived,replicated)
Cinematic_State :: struct {
    status:Cinematic_Status `mirai:"readonly"`,
    time:f32 `mirai:"readonly,unit=s,local"`,
    duration:f32 `mirai:"readonly,unit=s,local"`,
    anchor_tick:u64 `mirai:"readonly,hidden"`, // tick at which the clip was at anchor_time
    anchor_time:f32 `mirai:"readonly,hidden"`,
    anchor_rate:f32 `mirai:"readonly,hidden"`, // clip seconds per second from the anchor on; 0 while it does not play
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
cinematic_anchored :: proc "contextless" (c:Cinematic_State,tick:u64,dt,duration:f32,loop:bool) -> f32 {
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

// A shot of a timeline: its camera, the time of the clip it starts at and how engine/camera blends
// the view into it.
Shot :: struct {
    camera:core.Entity,
    time:f32,
    blend:cam.Camera_Blend,
}

// The shot in force at a time of the clip a timeline plays and the one before it: its last two
// markers on a camera at or before that time. What the seats see in play and the editor at its head.
cinematic_shot :: proc(playback:core.Ref(anim.Playback),sources:core.Ref(anim.Source_Assets),app:^host.App,entities:^core.Entities,cameras:^core.Table(render.Camera,$A),timeline:core.Entity,time:f32) -> (shot,previous:Shot) {
    markers,content:=anim.animation_markers(playback,sources,app,timeline)
    for marker in markers {
        if !(marker.time<=time) {break}
        if int(marker.id)>=len(content.markers) || content.markers[marker.id].target==0 {continue}
        on:=anim.animation_bound(playback,timeline,content.markers[marker.id].target)
        if core.alive(entities,on) && core.has(cameras,on) {previous,shot=shot,{on,marker.time,{marker.duration,cam.CAMERA_BLEND.ease}}}
    }
    return
}

// Whether an actor of a marker plays its action at a time of the clip of a timeline that shows: from
// its time to the end of its span, or to the end of the clip for a moment.
@(private)
cinematic_acting :: proc "contextless" (showing:bool,time,duration,at:f32) -> bool {
    return showing && time<=at && (duration<=0 || at<time+duration)
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
cinematic_follow :: proc(cinematics:^core.Table(Cinematic,.Read),states:^core.Table(Cinematic_State,.Read),animations:^core.Table(anim.Animation,.Read),playback:core.Ref(anim.Playback),requests:^anim.Animation_Requests,time:core.Time,remotes:^core.Table(core.Remote,.Read)) {
    if !time.playing {return}
    for row in 0..<core.count(cinematics) {
        e:=core.entity_at(cinematics,row)
        if core.owned(remotes,e) {continue}
        c:=core.get(states,e) or_continue
        animated:=core.has(animations,e)
        at,duration,_,clipped:=anim.animation_progress(playback,e)
        if !animated || !clipped {continue}
        _,loop:=anim.animation_clip_clock(playback,e)
        playing:=c.status==.Playing
        if anim.animation_playing(playback,e)!=playing {anim.animation_command(requests,e,.Resume if playing else .Pause,speed=c.anchor_rate)}
        want:=cinematic_anchored(c,time.tick,time.dt,duration,loop)
        step:=time.dt*c.anchor_rate if playing else 0
        ahead:=Cinematic_State{anchor_time=at,anchor_rate=1}
        if clip_apart(want,cinematic_anchored(ahead,1,step,duration,loop),duration,loop)>time.dt*max(abs(c.anchor_rate),1)*.5 {
            anim.animation_command(requests,e,.Seek,max(want-step,0))
        }
    }
}

@(params)
Cinematic_Actors :: struct {
    animations:^core.Table(anim.Animation,.Read),
    playback:core.Ref(anim.Playback),
    content_sources:core.Ref(anim.Source_Assets),
    actions:core.Ref(anim.Action_Runtime),
    requests:^anim.Animation_Requests,
}

@(params)
Cinematic_Seats :: struct {
    cameras:^core.Table(render.Camera,.Read),
    shown:core.Ref(cam.Cameras),
    seat_state:core.Ref(input.Seats),
    camera_requests:^cam.Camera_Requests,
    seat_requests:^input.Seat_Requests,
    seats:^core.Table(input.Seat,.Read),
}

// Runs after animation_advance, whose Playback it reads: the seats see the cameras where the clip put
// them in this tick, and the actions of the actors are where the clip is. In the editor, where the
// game does not play, only the actors follow the head of the clip.
@(step="fixed",loops="game editor",stage="react",after="animation_advance")
cinematic_advance :: proc(
    entities:core.Ref(core.Entities),cinematics:^core.Table(Cinematic,.Read),
    states:^core.Table(Cinematic_State),actors:Cinematic_Actors,audience:Cinematic_Seats,
    app:^host.App,time:core.Time,remotes:^core.Table(core.Remote,.Read),problems:^core.Problems,
) {
    for e in states.entities {
        if core.raw_row(core.raw(cinematics),e)>=0 {continue}
        core.remove(states,e)
        if cam.camera_overriding(audience.shown,e) {cam.camera_override_remove(audience.camera_requests,e)}
        if input.blocking(audience.seat_state,e) {input.input_unblock(audience.seat_requests,e)}
    }
    for row in 0..<core.count(cinematics) {
        e:=core.entity_at(cinematics,row)
        config:=core.at(cinematics,row)
        was,has_state:=core.get(states,e)
        animated:=core.has(actors.animations,e)
        if !animated {
            core.report(problems,e,"cinematics.animation","this Cinematic plays nothing: its entity has no Animation; add one whose asset is the .anim of its clip, with playing set for a timeline that starts by itself")
            continue
        }
        at,duration,ended,clipped:=anim.animation_progress(actors.playback,e)
        if !clipped {continue}
        speed,loop:=anim.animation_clip_clock(actors.playback,e)
        next:=was
        if time.playing {
            next.time,next.duration=at,duration
            if core.owned(remotes,e) {
                next.status=cinematic_status(anim.animation_playing(actors.playback,e),ended,at)
                rate:=speed if next.status==.Playing else 0
                if next.status!=was.status || rate!=was.anchor_rate || time.tick<was.anchor_tick || clip_apart(cinematic_anchored(was,time.tick,time.dt,duration,loop),at,duration,loop)>time.dt*max(abs(rate),1)*.5 {
                    next.anchor_tick,next.anchor_time,next.anchor_rate=time.tick,at,rate
                }
            }
            if !has_state {
                if !core.add(states,e,next) {
                    core.report(problems,e,"cinematics.state","out of memory for cinematic playback state; free memory")
                }
            } else if next!=was {
                core.edit(states,e)^=next
            }
        }
        showing:=!time.playing || next.status==.Playing || next.status==.Paused
        showed:=was.status==.Playing || was.status==.Paused
        // A clip that did not play on from where it was, or the head of the editor, was sought.
        step:=time.dt*speed if next.status==.Playing else 0
        sought:=!time.playing || clip_apart(at,was.time+step,duration,loop)>time.dt*max(abs(speed),1)*.5
        markers,content:=anim.animation_markers(actors.playback,actors.content_sources,app,e)
        for marker in markers {
            if int(marker.id)>=len(content.markers) || content.markers[marker.id].target==0 {continue}
            named:=content.markers[marker.id]
            on:=anim.animation_bound(actors.playback,e,named.target)
            action:=base.text_get(named.text[:])
            if !core.alive(entities.ptr,on) {
                core.report(problems,e,"cinematics.marker_target","marker '%s' of its clip is on an entity it does not animate: none below it has the name of its target, and none names it in Animation_Target.animation; name the entity as the marker does, or give it an Animation_Target with this entity and that name",action)
                continue
            }
            if core.has(audience.cameras,on) {continue}
            // Every end drives the actions of its actors by its own clip, which follows the anchor.
            acting,acted:=cinematic_acting(showing,marker.time,marker.duration,at),cinematic_acting(showed,marker.time,marker.duration,was.time)
            _,_,playing:=anim.action_playing(actors.actions,on,action)
            if acting && (playing || sought || !acted) {anim.play_at(actors.requests,on,action,at-marker.time,sought)} else if !acting && playing && (acted || sought) {anim.stop(actors.requests,on,action)}
        }
        if !time.playing {continue}
        shot,_:=cinematic_shot(actors.playback,actors.content_sources,app,entities.ptr,audience.cameras,e,at)
        seat:=config.seat if config.seat!=core.NONE else input.focused(audience.seat_state,audience.seats)
        asked:cam.Camera_Override
        for item in audience.shown.ptr.overrides {if item.active && item.owner==e {asked=item}}
        if !showing || shot.camera==core.NONE || !core.alive(entities.ptr,seat) {
            if asked.active {cam.camera_override_remove(audience.camera_requests,e)}
            if input.blocking(audience.seat_state,e) {input.input_unblock(audience.seat_requests,e)}
            continue
        }
        if !asked.active || asked.camera!=shot.camera || asked.seat!=seat {
            cam.camera_override(audience.camera_requests,e,seat,shot.camera,blend=shot.blend)
            if config.block_mask!=0 {input.input_block(audience.seat_requests,e,seat,config.block_mask)}
        } else if config.block_mask!=0 && !input.blocking(audience.seat_state,e) {input.input_block(audience.seat_requests,e,seat,config.block_mask)}
    }
}
