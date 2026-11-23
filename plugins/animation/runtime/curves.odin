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
        if append(&next,Curve_Output{target=track.target,property=track.property,slot=track.slot})!=1 {return false}
    }
    slice.sort_by(next[:],curve_order)
    count:=0
    for curve in next {
        if count==0 || !curve_same(next[count-1],curve) {next[count]=curve;count+=1}
    }
    base.truncate(&next,count)
    delete(state.curves);state.curves=next;next=nil;state.curves_ready=true
    return state.stack==nil || stack_scratch_prepare(state)
}

sample_curves :: proc(state:^Playing,content:^host.Content_Animation,weight:f32=1,animation:Animation=ANIMATION_DEFAULT) {
    if !curves_prepare(state,content) {return}
    for &result in state.curves {result.value,result.weight={},0}
    total:=lib.fader_current_weight(state.fader)
    curves_accumulate(state.curves[:],&content.lib,state.fader.current,total)
    for outgoing in state.fader.outgoing[:state.fader.outgoing_count] {
        share:=lib.fade_out_weight(outgoing)
        curves_accumulate(state.curves[:],&content.lib,outgoing.player,share)
        total+=share
    }
    scale:=mm.saturate(weight)/total if total>0 else 0
    for &result in state.curves {result.value*=scale;result.weight*=scale}
    sample_layer_curves(state,content,animation)
}

// The curves of the clips the slots of the stack play, over those of the base.
sample_layer_curves :: proc(state:^Playing,content:^host.Content_Animation,animation:Animation) {
    stack:=state.stack
    if stack==nil || stack.slots==0 || len(stack.scratch.curves)<3*len(state.curves) {return}
    for &layer,i in stack.layers[:stack.slots] {
        asked:=stack.asked[i]
        if layer.weight<=0 || asked.curves==.Ignore {continue}
        players:[LAYER_PLAYERS]lib.Player
        count:=layer_players(&layer,&players)
        if count==0 {continue}
        additive:=asked.mode==.Additive || asked.curves==.Additive
        from:=lib.clip_find(&content.lib,asked.reference_clip) if additive && asked.reference_clip!=0 else 0
        n:=len(state.curves)
        overlay,rest,own:=stack.scratch.curves[:n],stack.scratch.curves[n:2*n],stack.scratch.curves[2*n:3*n]
        for curve,k in state.curves {
            key:=Curve_Output{target=curve.target,property=curve.property,slot=curve.slot}
            overlay[k],rest[k],own[k]=key,key,key
        }
        sum:f32
        for player in players[:count] {
            curves_accumulate(overlay,&content.lib,player,player.weight)
            sum+=player.weight
            if additive {
                reference:=player;reference.time=asked.reference
                curves_accumulate(own,&content.lib,reference,player.weight)
            }
        }
        if from!=0 {
            reference:=lib.player_make(from);reference.time=asked.reference
            curves_accumulate(rest,&content.lib,reference,1)
        }
        if sum<=0 {continue}
        for &result,k in state.curves {
            authored:=overlay[k]
            if authored.weight<=0 {continue}
            alpha:=layer.weight*mm.saturate(animation.weight)*authored.weight/sum
            value:=authored.value/authored.weight
            if additive {
                reference:=rest[k] if rest[k].weight>0 else own[k]
                if reference.weight>0 {value-=reference.value/reference.weight}
                result.value+=value*alpha
            } else {
                result.value=mm.lerp(result.value,value,alpha)
                result.weight=mm.lerp(result.weight,1,alpha)
            }
        }
    }
}

@(private)
curves_accumulate :: proc(results:[]Curve_Output,library:^lib.Library,player:lib.Player,weight:f32) {
    if weight==0 || len(results)==0 {return}
    time:=lib.player_time(library,player)
    for track in lib.clip_tracks(library,player.clip) {
        if track.property!=.Float && track.property!=.Vector {continue}
        key:=Curve_Output{target=track.target,property=track.property,slot=track.slot}
        if row,found:=slice.binary_search_by(results,key,curve_compare);found {
            results[row].value+=lib.clip_evaluate(library,track,time)*weight
            results[row].weight+=weight
        }
    }
}

animation_curve :: proc(playback:core.Ref(Playback),entity:core.Entity,name:string,slot:u8=0,default_value:f32=0) -> f32 {
    state:=constraint_playing(playback,entity)
    if state==nil || state.seen!=playback.frame {return default_value}
    at:=[2]i32{-1,-1}
    if curve:=rig_curve(state,rig_leader(playback,state),{target=base.name_hash(name),property=.Float,slot=slot},&at);curve!=nil {return curve.value.x+default_value*(1-curve.weight)}
    return default_value
}

animation_vector :: proc(playback:core.Ref(Playback),entity:core.Entity,name:string,slot:u8=0,default_value:mm.Vec4={}) -> mm.Vec4 {
    state:=constraint_playing(playback,entity)
    if state==nil || state.seen!=playback.frame {return default_value}
    at:=[2]i32{-1,-1}
    if curve:=rig_curve(state,rig_leader(playback,state),{target=base.name_hash(name),property=.Vector,slot=slot},&at);curve!=nil {return curve.value+default_value*(1-curve.weight)}
    return default_value
}

animation_root_delta :: proc(playback:core.Ref(Playback),entity:core.Entity) -> (Root_Delta,bool) {
    state:=constraint_playing(playback,entity)
    if state==nil || state.seen!=playback.frame || !state.root_enabled {return ROOT_DELTA_DEFAULT,false}
    return state.motion,true
}

// The root motion of the tick that the actions of entity give its body: ok while one whose
// body_move is not None plays.
animation_body_motion :: proc(playback:core.Ref(Playback),entity:core.Entity) -> (Body_Motion,bool) {
    state:=constraint_playing(playback,entity)
    if state==nil || state.seen!=playback.frame || state.body_motion.move==.None {return {},false}
    return state.body_motion,true
}
