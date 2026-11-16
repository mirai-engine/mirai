package anim

import "core:math/linalg"
import "core:testing"
import "mirai:core"
import "mirai:host"
import lib "mirai:std/anim"
import "mirai:std/base"
import mm "mirai:std/math"

@(private="file")
REFERENCE_TRACKS :: 6

// The keys of one track of the fixture, each its own.
@(private="file")
reference_keys :: proc(keys:^[2]lib.Keyframe,property:lib.Property,seed:f32) {
    for &key,k in keys {
        value:=seed+f32(k)*.8
        key.time=f32(k)*2
        key.value=lib.quat_vec4(mm.quat_axis_angle(linalg.normalize(mm.Vec3{1,value,.4}),value)) if property==.Rotation else mm.Vec4{value,1-value*.5,value*.25,0}
    }
}

// What the clips of a slot give one binding, each track found by the name of its target and
// evaluated on its own: the oracle the blend by track is held to.
@(private="file")
Named_Channel :: struct {sum:mm.Vec4,weight:f32}
@(private="file")
named_blend :: proc(library:^lib.Library,target:u64,players:[]lib.Player) -> (channels:[3]Named_Channel) {
    for player in players {
        if !lib.clip_valid(library,player.clip) || player.weight<=0 {continue}
        for track in lib.clip_tracks(library,player.clip) {
            if track.target!=target || track.slot!=0 || track.property>.Scale {continue}
            value:=lib.clip_evaluate(library,track,lib.player_time(library,player))
            channel:=&channels[int(track.property)]
            if track.property==.Rotation && channel.weight>0 && linalg.dot(value,channel.sum)<0 {value=-value}
            channel.sum+=value*player.weight;channel.weight+=player.weight
        }
    }
    return
}
// What additive clips put over one binding, from the pose of from at reference (0: their own).
@(private="file")
named_added :: proc(library:^lib.Library,target:u64,players:[]lib.Player,reference:f32,from:lib.Clip) -> (position:mm.Vec3,rotation:mm.Quat,scale:mm.Vec3,has:[3]bool) {
    rotation=1
    for player in players {
        if !lib.clip_valid(library,player.clip) || player.weight<=0 {continue}
        for track in lib.clip_tracks(library,player.clip) {
            if track.target!=target || track.slot!=0 || track.property>.Scale {continue}
            source:=track
            if from!=0 {for other in lib.clip_tracks(library,from) {if other.target==target && other.property==track.property && other.slot==0 {source=other;break}}}
            now,rest:=lib.clip_evaluate(library,track,lib.player_time(library,player)),lib.clip_evaluate(library,source,reference)
            #partial switch track.property {
            case .Position: position+=(now.xyz-rest.xyz)*player.weight
            case .Rotation: rotation*=mm.quat_slerp(1,mm.quat_inverse(lib.vec4_quat(rest))*lib.vec4_quat(now),player.weight)
            case .Scale: scale+=(now.xyz-rest.xyz)*player.weight
            }
            has[int(track.property)]=true
        }
    }
    return
}

// The pose the clips of a state give, each value found by the name of its target: the clip of the
// component and those it fades from, then each slot of the stack over its branch.
@(private="file")
reference_pose :: proc(state:^Playing,library:^lib.Library,animation:Animation,out:[]mm.Transform) {
    in_branch :: proc(state:^Playing,bone,over:int) -> bool {
        for at:=bone;at>=0;at=int(state.parents[at]) {if at==over {return true}}
        return false
    }
    copy(out,state.rest[:])
    players:[LAYER_PLAYERS]lib.Player
    players[0]=state.fader.current;players[0].weight=lib.fader_current_weight(state.fader);count:=1
    for outgoing in state.fader.outgoing[:state.fader.outgoing_count] {players[count]=outgoing.player;players[count].weight=lib.fade_out_weight(outgoing);count+=1}
    weight:=mm.saturate(animation.weight)
    for binding,b in state.bindings {
        rest:=binding.rest
        channels:=named_blend(library,binding.target,players[:count])
        if c:=channels[0];c.weight>0 {out[b].position=rest.position+(c.sum.xyz/c.weight-rest.position)*(mm.saturate(c.weight)*weight)}
        if c:=channels[1];c.weight>0 {out[b].rotation=mm.quat_slerp(rest.rotation,linalg.normalize0(lib.vec4_quat(c.sum)),mm.saturate(c.weight)*weight)}
        if c:=channels[2];c.weight>0 {out[b].scale=rest.scale+(c.sum.xyz/c.weight-rest.scale)*(mm.saturate(c.weight)*weight)}
    }
    for &layer,i in state.layers[:state.stack] {
        if layer.clip==0 || layer.weight<=0 {continue}
        asked:=state.asked[i]
        over:=bone_named(state,asked.over[0].bone) if asked.over!={} else -1
        count=layer_players(&layer,&players)
        from:=lib.clip_find(library,asked.reference_clip) if asked.reference_clip!=0 else 0
        for binding,b in state.bindings {
            if over>=0 && !in_branch(state,b,over) {continue}
            share:=layer.weight*weight
            if asked.mode==.Additive {
                position,rotation,scale,has:=named_added(library,binding.target,players[:count],asked.reference,from)
                if has[0] {out[b].position+=position*share}
                if has[1] {out[b].rotation*=mm.quat_slerp(1,linalg.normalize0(rotation),share)}
                if has[2] {out[b].scale+=scale*share}
            } else {
                channels:=named_blend(library,binding.target,players[:count])
                if c:=channels[0];c.weight>0 {out[b].position+=(c.sum.xyz/c.weight-out[b].position)*(mm.saturate(c.weight)*share)}
                if c:=channels[1];c.weight>0 {out[b].rotation=mm.quat_slerp(out[b].rotation,linalg.normalize0(lib.vec4_quat(c.sum)),mm.saturate(c.weight)*share)}
                if c:=channels[2];c.weight>0 {out[b].scale+=(c.sum.xyz/c.weight-out[b].scale)*(mm.saturate(c.weight)*share)}
            }
        }
    }
}

// Clips that list their tracks in other orders, lack some of what the rig has and move what it
// does not have, under a cross-fade of the component, a masked layer and additive layers over
// their own pose and over a reference clip. The last two bindings share a target.
@(test)
poses_by_track_match_the_pose_each_track_gives_by_name :: proc(t:^testing.T) {
    content:=host.Content_Animation{clip_count=4};content.id={7,9};content.generation=3
    testing.expect(t,lib.library_init(&content.lib,{max_keys=64,max_tracks=24,max_clips=8,max_markers=0}))
    defer lib.library_destroy(&content.lib)
    hip,spine,arm,leg:=base.name_hash("hip"),base.name_hash("spine"),base.name_hash("arm"),base.name_hash("leg")
    keys:[4][REFERENCE_TRACKS][2]lib.Keyframe
    walk:=[?]lib.Track_Desc{{target=hip,property=.Position},{target=hip,property=.Rotation},{target=spine,property=.Rotation},{target=leg,property=.Position},{target=leg,property=.Rotation},{target=leg,property=.Scale}}
    run:=[?]lib.Track_Desc{{target=leg,property=.Rotation},{target=hip,property=.Rotation},{target=hip,property=.Position},{target=arm,property=.Rotation}}
    wave:=[?]lib.Track_Desc{{target=arm,property=.Rotation},{target=arm,property=.Position},{target=base.name_hash("prop"),property=.Position},{target=spine,property=.Rotation},{target=spine,property=.Float}}
    lean:=[?]lib.Track_Desc{{target=spine,property=.Scale},{target=spine,property=.Rotation},{target=hip,property=.Position},{target=leg,property=.Position}}
    clips:=[?]lib.Clip_Desc{{name=base.name_hash("walk"),tracks=walk[:]},{name=base.name_hash("run"),tracks=run[:]},{name=base.name_hash("wave"),tracks=wave[:]},{name=base.name_hash("lean"),tracks=lean[:]}}
    for &clip,c in clips {
        for &track,i in clip.tracks {reference_keys(&keys[c][i],track.property,f32(c)*.6+f32(i)*.35+.2);track.keys=keys[c][i][:]}
        added,_:=lib.clip_add(&content.lib,clip);testing.expect(t,added!=0)
    }
    for i in 0..<4 {content.lib.clips[4+i]=content.lib.clips[i];content.lib.clips[4+i].loop=.Loop}
    content.lib.clip_count=8

    state:=Playing{entity=core.entity_make(1,1),clip=-1};defer playing_free(&state)
    targets:=[?]u64{0,hip,spine,arm,leg,leg}
    parents:=[?]i32{-1,0,1,2,1,1}
    for target,i in targets {
        rest:=mm.Transform{position={f32(i),.5,-1},rotation=mm.quat_axis_angle({0,1,0},.3*f32(i)),scale={1,1.5,.75}}
        append(&state.bindings,Binding{target=target,entity=core.NONE,driven=targeted(&content.lib,target),rest=rest,parent=parents[i]})
        append(&state.parents,parents[i]);append(&state.targets,target);append(&state.rest,rest)
    }
    resize(&state.local,len(targets))
    playback:Playback;defer playback_free(&playback)
    if !testing.expect(t,tracks_bind(&playback,&state,&content)) {return}
    testing.expect_value(t,len(playback.track_maps[state.tracks-1].twins),1)
    events:Animation_Events;defer delete(events.items)

    animation:=ANIMATION_DEFAULT;animation.weight=.8;animation.fade=.4
    testing.expect(t,animation_clip(&animation,"walk"))
    expected:[len(targets)]mm.Transform
    faults:Pose_Faults
    layered:=false
    for step in 0..<12 {
        switch step {
        case 2: testing.expect(t,animation_clip(&animation,"run"))
        case 3: testing.expect(t,test_layer(&state,1,"wave",over="spine",weight=.6,fade=.2))
        case 4: testing.expect(t,test_layer(&state,2,"lean",weight=.7,fade=.15,mode=.Additive,reference=.5,reference_clip="walk"))
        case 5: testing.expect(t,test_layer(&state,3,"run",over="hip",weight=.5,fade=0,mode=.Additive,reference=.25))
        case 7: testing.expect(t,animation_clip(&animation,"walk") && test_layer(&state,1,"lean",over="spine",weight=.9,fade=.3))
        case 9: testing.expect(t,test_layer_stop(&state,2,.2))
        }
        copy(state.local[:],state.rest[:])
        advance(&playback,&state,&content,animation,&events,.1,nil)
        layers_advance(&playback,&state,&content,animation,&events,.1,nil)
        result:=pose_sample(&playback,&state,&content,animation,{})
        faults.memory||=result.memory;faults.layer_reference|=result.layer_reference
        reference_pose(&state,&content.lib,animation,expected[:])
        for value,b in expected {
            got:=state.local[b]
            testing.expectf(t,linalg.length(got.position-value.position)<1e-5 && linalg.length(got.scale-value.scale)<1e-5 && mm.quat_angle(got.rotation,value.rotation)<1e-4,"step %d, bone %d: %v, by name %v",step,b,got,value)
        }
        layered||=state.fader.outgoing_count>0 && state.layers[1].weight>0 && state.layers[2].weight>0 && state.layers[3].weight>0
    }
    testing.expect_value(t,faults,Pose_Faults{})
    testing.expect(t,layered,"the component cross-fades under its three layers")
    testing.expect(t,state.local[4].position!=state.rest[4].position && state.local[5].position!=state.rest[5].position,"bindings of one target are both moved")
}
