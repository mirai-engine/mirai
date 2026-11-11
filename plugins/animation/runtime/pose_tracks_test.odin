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

// The pose the clips of a state give, with a Pose that finds each value by the name of its target:
// the clip of the component and those it fades from, then each layer over its branch.
@(private="file")
reference_pose :: proc(pose:^lib.Pose,state:^Playing,library:^lib.Library,animation:Animation,out:[]mm.Transform) {
    in_branch :: proc(state:^Playing,bone,over:int) -> bool {
        for at:=bone;at>=0;at=int(state.parents[at]) {if at==over {return true}}
        return false
    }
    copy(out,state.rest[:])
    lib.pose_clear(pose)
    lib.fader_blend(pose,library,state.fader)
    weight:=mm.saturate(animation.weight)
    for binding,b in state.bindings {
        rest:=binding.rest
        if value,w,ok:=lib.pose_position(pose,binding.target);ok {out[b].position=rest.position+(value-rest.position)*(mm.saturate(w)*weight)}
        if value,w,ok:=lib.pose_rotation(pose,binding.target);ok {out[b].rotation=mm.quat_slerp(rest.rotation,value,mm.saturate(w)*weight)}
        if value,w,ok:=lib.pose_scale(pose,binding.target);ok {out[b].scale=rest.scale+(value-rest.scale)*(mm.saturate(w)*weight)}
    }
    for &layer,i in state.layers {
        if layer.clip==0 || layer.weight<=0 {continue}
        asked:=animation.layers[i]
        over:=bone_named(state,asked.over) if asked.over!=0 else -1
        lib.pose_clear(pose)
        if asked.mode==.Additive {
            from:=lib.clip_find(library,asked.reference_clip) if asked.reference_clip!=0 else 0
            player:=layer.fader.current;player.weight=lib.fader_current_weight(layer.fader)
            lib.pose_blend_additive(pose,library,player,asked.reference,1,from)
            for outgoing in layer.fader.outgoing[:layer.fader.outgoing_count] {
                player=outgoing.player;player.weight=lib.fade_out_weight(outgoing)
                lib.pose_blend_additive(pose,library,player,asked.reference,1,from)
            }
        } else {lib.fader_blend(pose,library,layer.fader)}
        for binding,b in state.bindings {
            if over>=0 && !in_branch(state,b,over) {continue}
            share:=layer.weight*weight
            position,position_weight,moves:=lib.pose_position(pose,binding.target)
            rotation,rotation_weight,turns:=lib.pose_rotation(pose,binding.target)
            scale,scale_weight,grows:=lib.pose_scale(pose,binding.target)
            if asked.mode==.Additive {
                if moves {out[b].position+=position*share}
                if turns {out[b].rotation*=mm.quat_slerp(1,rotation,share)}
                if grows {out[b].scale+=scale*share}
            } else {
                if moves {out[b].position+=(position-out[b].position)*(mm.saturate(position_weight)*share)}
                if turns {out[b].rotation=mm.quat_slerp(out[b].rotation,rotation,mm.saturate(rotation_weight)*share)}
                if grows {out[b].scale+=(scale-out[b].scale)*(mm.saturate(scale_weight)*share)}
            }
        }
    }
}

// Clips that list their tracks in other orders, lack some of what the rig has and move what it
// does not have, under a cross-fade of the component, a masked layer and additive layers over
// their own pose and over a reference clip. The last two bindings share a target.
@(test)
poses_by_track_match_the_pose_found_by_name :: proc(t:^testing.T) {
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
    pose:lib.Pose
    testing.expect(t,lib.pose_init(&pose,64));defer lib.pose_destroy(&pose)
    events:Animation_Events;defer delete(events.items)

    animation:=ANIMATION_DEFAULT;animation.weight=.8;animation.fade=.4
    testing.expect(t,animation_play(&animation,"walk"))
    expected:[len(targets)]mm.Transform
    faults:Pose_Faults
    layered:=false
    for step in 0..<12 {
        switch step {
        case 2: testing.expect(t,animation_play(&animation,"run"))
        case 3: testing.expect(t,animation_play(&animation,"wave",layer=1,over="spine",weight=.6,fade=.2))
        case 4: testing.expect(t,animation_play(&animation,"lean",layer=2,weight=.7,fade=.15,mode=.Additive,reference=.5,reference_clip="walk"))
        case 5: testing.expect(t,animation_play(&animation,"run",layer=3,over="hip",weight=.5,fade=0,mode=.Additive,reference=.25))
        case 7: testing.expect(t,animation_play(&animation,"walk") && animation_play(&animation,"lean",layer=1,over="spine",weight=.9,fade=.3))
        case 9: testing.expect(t,animation_stop(&animation,2,.2))
        }
        copy(state.local[:],state.rest[:])
        advance(&playback,&state,&content,animation,&events,.1,nil)
        layers_advance(&playback,&state,&content,animation,&events,.1,nil)
        result:=pose_sample(&playback,&state,&content.lib,animation,{})
        faults.memory||=result.memory;faults.layer_bone|=result.layer_bone;faults.layer_reference|=result.layer_reference
        reference_pose(&pose,&state,&content.lib,animation,expected[:])
        for value,b in expected {
            got:=state.local[b]
            testing.expectf(t,linalg.length(got.position-value.position)<1e-5 && linalg.length(got.scale-value.scale)<1e-5 && mm.quat_angle(got.rotation,value.rotation)<1e-4,"step %d, bone %d: %v, by name %v",step,b,got,value)
        }
        layered||=state.fader.outgoing_count>0 && state.layers[0].weight>0 && state.layers[1].weight>0 && state.layers[2].weight>0
    }
    testing.expect_value(t,faults,Pose_Faults{})
    testing.expect(t,layered,"the component cross-fades under its three layers")
    testing.expect(t,state.local[4].position!=state.rest[4].position && state.local[5].position!=state.rest[5].position,"bindings of one target are both moved")
    testing.expect_value(t,pose.failed,0)
}
