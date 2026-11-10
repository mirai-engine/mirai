package anim

import "core:slice"
import "mirai:core"
import "mirai:std/base"
import "mirai:host"
import lib "mirai:std/anim"
import mm "mirai:std/math"

Curve_Output :: struct {target:u64,property:lib.Property,slot:u8,value:mm.Vec4,weight:f32}

curves_prepare :: proc(state:^Playing,content:^host.Content_Animation) -> bool {
    if state.curves_ready {return true}
    next:[dynamic]Curve_Output
    defer delete(next)
    for track in content.lib.tracks[:content.lib.track_count] {
        if track.property!=.Float && track.property!=.Vector {continue}
        found:=false
        for curve in next {if curve.target==track.target && curve.property==track.property && curve.slot==track.slot {found=true;break}}
        if !found && append(&next,Curve_Output{target=track.target,property=track.property,slot=track.slot})!=1 {return false}
    }
    // In curve_order, so the final curves of a rig are laid out by halves and lookups search by halves.
    slice.sort_by(next[:],curve_order)
    delete(state.curves);state.curves=next;next=nil;state.curves_ready=true
    return true
}

sample_curves :: proc(state:^Playing,content:^host.Content_Animation,weight:f32=1,animation:Animation=ANIMATION_DEFAULT) {
    if !curves_prepare(state,content) {return}
    for &result in state.curves {
        result.value,result.weight={},0
        current:=lib.fader_current_weight(state.fader)
        curve_accumulate(&result,&content.lib,state.fader.current,current)
        total:=current
        for outgoing in state.fader.outgoing[:state.fader.outgoing_count] {
            share:=lib.fade_out_weight(outgoing)
            curve_accumulate(&result,&content.lib,outgoing.player,share);total+=share
        }
        if total>0 {result.value/=total;result.weight/=total}
        result.value*=mm.saturate(weight);result.weight*=mm.saturate(weight)
    }
    sample_layer_curves(state,content,animation)
}

// The curves of the clips the slots of the stack play, over those of the base.
sample_layer_curves :: proc(state:^Playing,content:^host.Content_Animation,animation:Animation) {
    if state.stack==0 {return}
    for &layer,i in state.layers[:state.stack] {
        asked:=state.asked[i]
        if asked.injected || layer.weight<=0 || asked.curves==.Ignore {continue}
        players:[LAYER_PLAYERS]lib.Player
        count:=layer_players(&layer,&players)
        if count==0 {continue}
        additive:=asked.mode==.Additive || asked.curves==.Additive
        from:=lib.clip_find(&content.lib,asked.reference_clip) if additive && asked.reference_clip!=0 else 0
        for &result in state.curves {
            overlay:=Curve_Output{target=result.target,property=result.property,slot=result.slot}
            sum:f32
            for player in players[:count] {curve_accumulate(&overlay,&content.lib,player,player.weight);sum+=player.weight}
            if overlay.weight<=0 || sum<=0 {continue}
            alpha:=layer.weight*mm.saturate(animation.weight)*overlay.weight/sum
            if additive {
                // From the reference clip when it has the curve, as the bones; else from its own.
                rest:=Curve_Output{target=result.target,property=result.property,slot=result.slot}
                if from!=0 {
                    reference:=lib.player_make(from);reference.time=asked.reference
                    curve_accumulate(&rest,&content.lib,reference,1)
                }
                if rest.weight<=0 {
                    for player in players[:count] {reference:=player;reference.time=asked.reference;curve_accumulate(&rest,&content.lib,reference,player.weight)}
                }
                if rest.weight>0 {rest.value/=rest.weight}
                result.value+=(overlay.value/overlay.weight-rest.value)*alpha
            } else {
                result.value=mm.lerp(result.value,overlay.value/overlay.weight,alpha)
                result.weight=mm.lerp(result.weight,1,alpha)
            }
        }
    }
}

@(private)
curve_accumulate :: proc(result:^Curve_Output,library:^lib.Library,player:lib.Player,weight:f32) {
    for track in lib.clip_tracks(library,player.clip) {
        if track.property!=result.property || track.target!=result.target || track.slot!=result.slot {continue}
        result.value+=lib.clip_evaluate(library,track,lib.player_time(library,player))*weight
        result.weight+=weight;return
    }
}

animation_curve :: proc(playback:^Playback,entity:core.Entity,name:string,slot:u8=0,default_value:f32=0) -> f32 {
    if playback==nil {return default_value}
    state:=constraint_playing(playback,entity)
    if state==nil || state.seen!=playback.frame {return default_value}
    target:=base.name_hash(name)
    for curve in playing_curves(state) {if curve.target==target && curve.property==.Float && curve.slot==slot {return curve.value.x+default_value*(1-curve.weight)}}
    return default_value
}

animation_vector :: proc(playback:^Playback,entity:core.Entity,name:string,slot:u8=0,default_value:mm.Vec4={}) -> mm.Vec4 {
    if playback==nil {return default_value}
    state:=constraint_playing(playback,entity)
    if state==nil || state.seen!=playback.frame {return default_value}
    target:=base.name_hash(name)
    for curve in playing_curves(state) {if curve.target==target && curve.property==.Vector && curve.slot==slot {return curve.value+default_value*(1-curve.weight)}}
    return default_value
}

animation_root_delta :: proc(playback:^Playback,entity:core.Entity) -> (Root_Delta,bool) {
    if playback==nil {return ROOT_DELTA_DEFAULT,false}
    state:=constraint_playing(playback,entity)
    if state==nil || state.seen!=playback.frame || !state.root_enabled {return ROOT_DELTA_DEFAULT,false}
    return state.motion,true
}

// The root motion of the tick that the actions of entity give its body: ok while one whose
// body_move is not None plays.
animation_body_motion :: proc(playback:^Playback,entity:core.Entity) -> (Body_Motion,bool) {
    if playback==nil {return {},false}
    state:=constraint_playing(playback,entity)
    if state==nil || state.seen!=playback.frame || state.body_motion.move==.None {return {},false}
    return state.body_motion,true
}
