package cinematics

import "mirai:core"
import camera "mirai:engine/camera"
import input "mirai:engine/input"
import render "mirai:engine/render"
import lib "mirai:std/anim"
import mm "mirai:std/math"

// Cinematics: timelines in fixed ticks that move entities and cameras. A
// timeline is an entity with a Cinematic; what hangs from it is described by
// components that name it:
//
//   Cinematic_Track   how a property of an entity varies along the timeline
//   Cinematic_Shot    which camera the viewers see from a tick on
//   Cinematic_Marker  an event at a tick
//   Cinematic_Viewer  on a camera: the camera a seat sees the shots through
//
// A track whose target is a shot camera of its timeline does not move it: it
// changes what the viewer samples from it. Any other target is moved while the
// timeline plays, in world space, by core.place. The viewer owns the
// Transform of its camera; its camera is the only one that moves. While it
// plays, the viewer asks engine/camera to show its camera, with the lens of
// the shot, and engine/input to block the actions of its seat.

CINEMATIC_KEYS :: 16
MAX_DURATION :: 0x7fffffff

Cinematic_Status :: enum u8 {Stopped,Playing,Paused,Completed}

// In a network session its state travels from the server, which is the one that
// plays, pauses or seeks it: a client follows the anchor, so the position of
// every end is the same function of the tick and nothing is sent while it plays.
@(component,replicated)
Cinematic :: struct {
    duration_ticks:u32 `mirai:"min=1,unit=ticks"`,
    auto_play:bool,
    looping:bool,
    status:Cinematic_Status `mirai:"readonly"`,
    position:u32 `mirai:"readonly,unit=ticks,local"`,
    started:bool `mirai:"readonly,hidden"`, // auto_play was honored
    anchor_tick:u64 `mirai:"readonly,hidden"`,     // tick at which the position was anchor_position
    anchor_position:u32 `mirai:"readonly,hidden"`,
}

Cinematic_Property :: enum u8 {Position,Rotation,Scale,Fov,Near}

// Keyframe.time is a position in fixed ticks, not seconds.
@(component)
Cinematic_Track :: struct {
    timeline:core.Entity,
    target:core.Entity,
    property:Cinematic_Property,
    key_count:u32 `mirai:"min=0,max=16"`,
    keys:[CINEMATIC_KEYS]lib.Keyframe,
}

@(component)
Cinematic_Shot :: struct {
    timeline:core.Entity,
    camera:core.Entity,
    tick:u32 `mirai:"unit=ticks"`,
    blend_ticks:u32 `mirai:"unit=ticks"`,
    ease:mm.Ease,
}

@(component)
Cinematic_Marker :: struct {
    timeline:core.Entity,
    tick:u32 `mirai:"unit=ticks"`,
    id:u64,
    values:[4]f32,
}

// The entity that has it is the output camera: it needs a render.Camera and a Transform.
@(component,locks="core.Transform")
Cinematic_Viewer :: struct {
    timeline:core.Entity,
    seat:core.Entity, // none: the local player
    block_mask:input.Action_Mask, // actions of the seat blocked while it plays; 0 lets the input through
}

Cinematic_Command_Kind :: enum u8 {Play,Pause,Resume,Stop,Seek}

Cinematic_Command :: struct {
    timeline:core.Entity,
    kind:Cinematic_Command_Kind,
    position:u32,
}

@(storage,queue)
Cinematic_Requests :: struct {
    using queue:core.Queue(Cinematic_Command),
}

// Reached by a timeline: read these in a fixed step. Cleared and filled by cinematic_advance in every tick.
Cinematic_Event :: struct {
    timeline:core.Entity,
    tick:u32,
    id:u64,
    values:[4]f32,
}

@(storage,events)
Cinematic_Events :: struct {
    using queue:core.Queue(Cinematic_Event),
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
    shot_tick:u32 `mirai:"readonly,unit=ticks"`,
    mask:input.Action_Mask `mirai:"readonly,hidden"`,
    fov:f32 `mirai:"readonly,angle"`, // what the viewer shows this tick
    near:f32 `mirai:"readonly,unit=m"`,
    written:core.Transform `mirai:"readonly,hidden"`,
    wrote:bool `mirai:"readonly,hidden"`,
}

cinematic_play :: proc(r:^Cinematic_Requests,timeline:core.Entity) {
    core.push(&r.queue,Cinematic_Command{timeline=timeline,kind=.Play})
}
cinematic_pause :: proc(r:^Cinematic_Requests,timeline:core.Entity) {
    core.push(&r.queue,Cinematic_Command{timeline=timeline,kind=.Pause})
}
cinematic_resume :: proc(r:^Cinematic_Requests,timeline:core.Entity) {
    core.push(&r.queue,Cinematic_Command{timeline=timeline,kind=.Resume})
}
cinematic_stop :: proc(r:^Cinematic_Requests,timeline:core.Entity) {
    core.push(&r.queue,Cinematic_Command{timeline=timeline,kind=.Stop})
}
// Moves the playback to a tick without firing the markers it skips.
cinematic_seek :: proc(r:^Cinematic_Requests,timeline:core.Entity,position:u32) {
    core.push(&r.queue,Cinematic_Command{timeline=timeline,kind=.Seek,position=position})
}

@(private)
duration_valid :: proc "contextless" (c:^Cinematic) -> bool {return c.duration_ticks>0 && c.duration_ticks<=MAX_DURATION}

@(private)
Cine :: struct {
    cinematics:^core.Table(Cinematic),
    tracks:core.Read(Cinematic_Track),
    shots:core.Read(Cinematic_Shot),
    markers:core.Read(Cinematic_Marker),
    cameras:core.Read(render.Camera),
    worlds:core.Read(core.World_Transform),
    placer:core.Placer,
    events:^Cinematic_Events,
    views:^core.Table(Cinematic_View),
    shown:core.Ref(camera.Cameras),
    seat_state:core.Ref(input.Seats),
    camera_requests:^camera.Camera_Requests,
    seat_requests:^input.Seat_Requests,
    seats:core.Read(input.Seat),
    tick:u64,
    remotes:core.Read(core.Remote),
    problems:^core.Problems,
}

@(step="fixed")
cinematic_advance :: proc(
    entities:core.Ref(core.Entities),cinematics:^core.Table(Cinematic),tracks:core.Read(Cinematic_Track),shots:core.Read(Cinematic_Shot),
    markers:core.Read(Cinematic_Marker),viewers:core.Read(Cinematic_Viewer),views:^core.Table(Cinematic_View),cameras:core.Read(render.Camera),
    drivables:core.Read(input.Drivable),worlds:core.Read(core.World_Transform),placer:core.Placer,commands:^Cinematic_Requests,events:^Cinematic_Events,
    shown:core.Ref(camera.Cameras),seat_state:core.Ref(input.Seats),camera_requests:^camera.Camera_Requests,seat_requests:^input.Seat_Requests,
    seats:core.Read(input.Seat),time:core.Time,remotes:core.Read(core.Remote),problems:^core.Problems,
) {
    clear(&events.items)
    if !time.playing {return}
    p:=Cine{cinematics,tracks,shots,markers,cameras,worlds,placer,events,views,shown,seat_state,camera_requests,seat_requests,seats,time.tick,remotes,problems}
    es:=entities.ptr
    // A viewer that lost its Cinematic_Viewer lets go of what it asked of
    // control; for an entity that is gone, the upkeep of control does it.
    for row in 0..<core.count(views) {
        if e:=core.entity_at(views,row);!core.has(viewers,e) {view_release(&p,e)}
    }
    for command in core.take(&commands.queue) {command_apply(&p,command)}
    for row in 0..<core.count(cinematics) {
        e:=cinematics.entities[row]
        c:=core.edit_at(cinematics,row)
        if !duration_valid(c) {
            if c.status==.Playing || c.auto_play && !c.started {duration_report(problems,e,c)}
            continue
        }
        mine:=core.owned(remotes,e)
        if mine && !c.started {
            c.started=true
            if c.auto_play && c.status==.Stopped {timeline_start(&p,e,c)}
        }
        if mine && p.tick<c.anchor_tick {c.anchor_tick,c.anchor_position=p.tick,c.position}
        playing:=c.status==.Playing
        if playing {timeline_step(&p,e,c)}
        if playing || c.status==.Paused {tracks_apply(&p,e,c)}
    }
    for row in 0..<core.count(viewers) {
        viewer_update(&p,es,core.entity_at(viewers,row),core.at(viewers,row),drivables)
    }
}

@(private)
duration_report :: proc(problems:^core.Problems,e:core.Entity,c:^Cinematic) {
    core.report(problems,e,"cinematics.duration","this timeline cannot play: Cinematic.duration_ticks is %d; give it 1 to %d fixed ticks",c.duration_ticks,MAX_DURATION)
}

@(private)
command_apply :: proc(p:^Cine,command:Cinematic_Command) {
    c:=core.edit(p.cinematics,command.timeline)
    if c==nil {
        core.report(p.problems,command.timeline,"cinematics.missing","a %v of this entity was asked for, and it has no Cinematic; send cinematic commands to the entity of a timeline",command.kind)
        return
    }
    if !core.owned(p.remotes,command.timeline) {
        core.report(p.problems,command.timeline,"cinematics.client","a %v of this timeline was refused: in a network game the server plays, pauses and seeks timelines, and clients follow; send it on the server",command.kind)
        return
    }
    if !duration_valid(c) {
        duration_report(p.problems,command.timeline,c)
        return
    }
    switch command.kind {
    case .Play: timeline_start(p,command.timeline,c)
    case .Pause: if c.status==.Playing {c.status=.Paused}
    case .Resume: if c.status==.Paused {c.status,c.anchor_tick,c.anchor_position=.Playing,p.tick,c.position}
    case .Stop: c.status,c.position=.Stopped,0
    case .Seek:
        c.position=c.looping?command.position%c.duration_ticks:min(command.position,c.duration_ticks)
        if c.status==.Completed && c.position<c.duration_ticks {c.status=.Paused}
        c.anchor_tick,c.anchor_position=p.tick,c.position
    }
}

@(private)
timeline_start :: proc(p:^Cine,e:core.Entity,c:^Cinematic) {
    c.status,c.position,c.started=.Playing,0,true
    c.anchor_tick,c.anchor_position=p.tick,0
    markers_fire(p,e,0,0,true)
}

// One tick forward. A marker fires when the position reaches its tick; a loop
// fires the markers of its end and then those of its start. The position of a
// tick is a function of the anchor: one that is not where a step from the
// previous one leads, as a client sees when the server anchors the timeline
// anew, is taken without firing the markers it skips.
@(private)
timeline_step :: proc(p:^Cine,e:core.Entity,c:^Cinematic) {
    previous:=c.position
    next:=previous+1
    elapsed:=p.tick>c.anchor_tick?p.tick-c.anchor_tick:0
    expected:=u64(c.anchor_position)+elapsed+1
    duration:=u64(c.duration_ticks)
    if c.looping {
        if u32(expected%duration)!=next%c.duration_ticks {
            c.position=u32(expected%duration)
            return
        }
        if next>=c.duration_ticks {
            markers_fire(p,e,previous,c.duration_ticks,false)
            c.position=0
            markers_fire(p,e,0,0,true)
        } else {
            markers_fire(p,e,previous,next,false)
            c.position=next
        }
        return
    }
    next=min(next,c.duration_ticks)
    if u32(min(expected,duration))!=next {
        next=u32(min(expected,duration))
    } else {
        markers_fire(p,e,previous,next,false)
    }
    c.position=next
    if next>=c.duration_ticks {c.status=.Completed}
}

// The markers of a timeline in (low,high], or [low,high] with include_low.
@(private)
markers_fire :: proc(p:^Cine,timeline:core.Entity,low,high:u32,include_low:bool) {
    for row in 0..<core.count(p.markers) {
        marker:=core.at(p.markers,row)
        if marker.timeline!=timeline || marker.tick>high || marker.tick<low || marker.tick==low && !include_low {continue}
        core.push(&p.events.queue,Cinematic_Event{timeline,marker.tick,marker.id,marker.values})
    }
}

// Whether a camera is the camera of a shot of the timeline: tracks that target it change what the viewers sample, not the camera.
cinematic_shot_camera :: proc(shots:core.Read(Cinematic_Shot),timeline,camera:core.Entity) -> bool {
    for row in 0..<core.count(shots) {
        shot:=core.at(shots,row)
        if shot.timeline==timeline && shot.camera==camera {return true}
    }
    return false
}

// The value of a track at a position in ticks; false while its keys are not in order or their count is out of range.
cinematic_track_value :: proc "contextless" (track:^Cinematic_Track,position:f32) -> (value:mm.Vec4,ok:bool) {
    if track.key_count==0 || track.key_count>CINEMATIC_KEYS {return}
    keys:=track.keys[:int(track.key_count)]
    for key,i in keys {
        if key.time<0 || i>0 && key.time<keys[i-1].time {return}
    }
    property:lib.Property
    switch track.property {
    case .Position: property=.Position
    case .Rotation: property=.Rotation
    case .Scale: property=.Scale
    case .Fov,.Near: property=.Float
    }
    return lib.track_evaluate(keys,property,position),true
}

// Moves the entities the tracks of the timeline target, except the cameras the shots sample.
@(private)
tracks_apply :: proc(p:^Cine,timeline:core.Entity,c:^Cinematic) {
    for row in 0..<core.count(p.tracks) {
        track:=core.at(p.tracks,row)
        if track.timeline!=timeline || track.target==core.NONE || cinematic_shot_camera(p.shots,timeline,track.target) {continue}
        value,ok:=cinematic_track_value(&track,f32(c.position))
        if !ok {continue}
        target:=track.target
        placed,has_world:=core.get(p.worlds,target)
        if !has_world {continue}
        placed_ok:=true
        switch track.property {
        case .Position: placed_ok=core.place(p.placer,target,{value.x,value.y,value.z},placed.rotation,teleport=false)
        case .Rotation: placed_ok=core.place(p.placer,target,placed.position,lib.vec4_quat(value),teleport=false)
        case .Scale:
            local:=core.free(p.placer.transforms,target)
            placed_ok=local!=nil
            if placed_ok {local.scale={value.x,value.y,value.z}}
        case .Fov,.Near:
        }
        if !placed_ok {
            if track.property==.Scale {
                core.report(p.problems,target,"cinematics.place","a Scale track of timeline 0x%016x cannot scale this entity: it has no Transform, or another component owns it (a body of the physics, an animation); target an entity it can write",u64(timeline))
            } else {
                core.report(p.problems,target,"cinematics.place","a %v track of timeline 0x%016x cannot place this entity: it has no Transform, or a parent of it has a scale of zero; give it a Transform and its parents a scale",track.property,u64(timeline))
            }
        }
    }
}

Camera_Sample :: struct {
    pose:mm.Transform,
    fov,near:f32,
}

// A camera as the shots of a timeline see it at a position: its pose and
// lens with the tracks that target it applied.
cinematic_camera_sample :: proc(tracks:core.Read(Cinematic_Track),timeline,camera:core.Entity,pose:mm.Transform,lens:render.Camera,position:f32) -> Camera_Sample {
    sample:=Camera_Sample{pose,lens.fov,lens.near}
    for row in 0..<core.count(tracks) {
        track:=core.at(tracks,row)
        if track.timeline!=timeline || track.target!=camera {continue}
        value,valid:=cinematic_track_value(&track,position)
        if !valid {continue}
        switch track.property {
        case .Position: sample.pose.position={value.x,value.y,value.z}
        case .Rotation: sample.pose.rotation=lib.vec4_quat(value)
        case .Scale: sample.pose.scale={value.x,value.y,value.z}
        case .Fov: sample.fov=max(value.x,0.001)
        case .Near: sample.near=max(value.x,0.0001)
        }
    }
    return sample
}

// The shot in force at a position and the one before it.
cinematic_shots_at :: proc(shots:core.Read(Cinematic_Shot),timeline:core.Entity,position:f32) -> (current,previous:Cinematic_Shot,found:bool) {
    for row in 0..<core.count(shots) {
        shot:=core.at(shots,row)
        if shot.timeline!=timeline || f32(shot.tick)>position {continue}
        if !found || shot.tick>current.tick {current,found=shot,true}
    }
    if !found {return}
    previous_found:=false
    for row in 0..<core.count(shots) {
        shot:=core.at(shots,row)
        if shot.timeline!=timeline || shot.tick>=current.tick {continue}
        if !previous_found || shot.tick>previous.tick {previous,previous_found=shot,true}
    }
    return
}

// The view of a shot that is still blending in at a position, mixed from the
// view it comes from; any other position keeps the view of the shot.
cinematic_shot_blend :: proc(shot:Cinematic_Shot,from,to:Camera_Sample,position:f32) -> Camera_Sample {
    since:=position-f32(shot.tick)
    if shot.blend_ticks==0 || since<0 || since>=f32(shot.blend_ticks) {return to}
    weight:=mm.ease_apply(shot.ease,since/f32(shot.blend_ticks))
    out:=to
    out.pose.position=from.pose.position+(to.pose.position-from.pose.position)*weight
    out.pose.rotation=mm.quat_slerp(from.pose.rotation,to.pose.rotation,weight)
    out.fov=from.fov+(to.fov-from.fov)*weight
    out.near=from.near+(to.near-from.near)*weight
    return out
}

@(private)
camera_sample :: proc(p:^Cine,timeline,camera:core.Entity,position:u32) -> (sample:Camera_Sample,ok:bool) {
    lens,has_camera:=core.get(p.cameras,camera)
    placed,has_world:=core.get(p.worlds,camera)
    if !has_camera || !has_world {return}
    return cinematic_camera_sample(p.tracks,timeline,camera,placed.transform,lens,f32(position)),true
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
    position:u32
    ready:=has_timeline && duration_valid(&c) && (c.status==.Playing || c.status==.Paused)
    if ready {position=c.position}
    seat:=viewer.seat!=core.NONE?viewer.seat:input.focused(p.seat_state.ptr,p.seats)
    row:=core.edit(p.placer.transforms,e)
    current,previous,shot_found:=cinematic_shots_at(p.shots,viewer.timeline,f32(position))
    active:=ready && shot_found && row!=nil && core.alive(es,seat) && core.has(p.cameras,e)

    binding:=core.edit(p.views,e)
    if binding!=nil && (!active || binding.timeline!=viewer.timeline || binding.seat!=seat || binding.mask!=viewer.block_mask) {
        view_release(p,e)
        binding=nil
    }
    if !active {return}
    sample,valid:=camera_sample(p,viewer.timeline,current.camera,position)
    if !valid {
        if binding!=nil {view_release(p,e)}
        return
    }
    entry:=binding!=nil?binding.entry_camera:camera.camera_selected(p.shown.ptr,drivables,p.cameras,seat)
    from_camera:=previous.camera!=core.NONE?previous.camera:entry
    if from_camera!=core.NONE && from_camera!=e {
        if from,found:=camera_sample(p,viewer.timeline,from_camera,position);found {sample=cinematic_shot_blend(current,from,sample,f32(position))}
    }
    if binding!=nil && binding.wrote && row^!=binding.written {
        core.fail("Cinematic_Viewer owns the Transform of entity %v and another library wrote it: only the viewer moves its camera",e)
    }
    if !core.world_set(row,core.read(p.placer.transforms),p.placer.parents,e,sample.pose.position,sample.pose.rotation) {
        core.report(p.problems,e,"cinematics.place","this Cinematic_Viewer cannot place its camera where the shot is: a parent of it has a scale of zero; give its parents a scale, or take the camera out of them")
        if binding!=nil {view_release(p,e)}
        return
    }
    if binding!=nil {
        if !camera.camera_overriding(p.shown.ptr,e) || !input.blocking(p.seat_state.ptr,e) && viewer.block_mask!=0 || binding.fov!=sample.fov || binding.near!=sample.near {
            view_ask(p,e,seat,viewer,sample.fov,sample.near)
        }
        binding.shot_camera,binding.shot_tick=current.camera,current.tick
        binding.fov,binding.near,binding.written,binding.wrote=sample.fov,sample.near,row^,true
        return
    }
    view_ask(p,e,seat,viewer,sample.fov,sample.near)
    core.add(p.views,e,Cinematic_View{
        timeline=viewer.timeline,seat=seat,entry_camera=entry,shot_camera=current.camera,shot_tick=current.tick,
        mask=viewer.block_mask,fov=sample.fov,near=sample.near,written=row^,wrote=true,
    })
}
