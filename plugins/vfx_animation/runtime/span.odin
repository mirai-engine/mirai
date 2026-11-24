package vfx_animation

import "mirai:core"
import "mirai:std/base"
import anim "plugins:animation/runtime"
import vfx "plugins:vfx/runtime"

// Automatic bridge between animation and vfx: drives Particle_Emitter start and
// stop from named animation spans (Animation_Events .Span_Begin/.Span_End) or
// paired point markers (start marker in span, stop marker in end_marker).
//
// Runs in fixed/react right after animation_advance and before particles_tick
// (fixed/end), so emitters start and stop on the same tick their span fires,
// beginning a fresh ribbon segment on each swing. Interruptions, clip/action
// ends and source destruction automatically stop any emitter this bridge turned
// on so trails never stick on.

SPAN_NAME_BYTES :: 64
SPAN_ANCESTOR_LIMIT :: 64

@(component,description="Starts and stops this entity's Particle_Emitter on named animation spans (.Span_Begin/.Span_End) or paired point markers (start in span, stop in end_marker).")
Particle_Animation_Span :: struct {
    source:core.Entity `mirai:"local"`,          // animated entity whose events drive this emitter; NONE uses self or nearest ancestor with anim.Animation
    span:[SPAN_NAME_BYTES]u8 `mirai:"text"`,       // span name (.Span_Begin/.Span_End), or start marker name when end_marker is set
    end_marker:[SPAN_NAME_BYTES]u8 `mirai:"text"`, // optional: when non-empty, .Marker matching span starts and .Marker matching end_marker stops
    action:[SPAN_NAME_BYTES]u8 `mirai:"text"`,     // optional: restrict to one action name; empty matches any action or clip
    restart_on_begin:bool,                         // restart emitter generation on begin instead of resuming
}

Span_Active :: struct {
    source:core.Entity,
    action:u64, // action hash that opened the active span (0 for unnamed clip)
    depth:u16,  // overlapping active duration spans currently holding emission on
    active:bool,
}

// Derived state of active span-driven emitters; copied on Play and rollback.
@(storage)
Particle_Span_State :: struct {
    entries:core.Entity_Map(Span_Active),
    seen_spans:core.Seen,
    seen_emitters:core.Seen,
}

// Applies animation span and paired marker events to Particle_Requests in the
// same fixed tick that animation_advance emitted them.
@(step="fixed",loops="game",stage="react",after="animation_advance")
vfx_animation_spans :: proc(
    spans:^core.Table(Particle_Animation_Span,.Read),
    emitters:^core.Table(vfx.Particle_Emitter,.Read),
    animations:^core.Table(anim.Animation,.Read),
    parents:^core.Table(core.Parent,.Read),
    entities:core.Ref(core.Entities),
    events:core.Ref(anim.Animation_Events),
    state:^Particle_Span_State,
    requests:^vfx.Particle_Requests,
    time:core.Time,
) {
    if !time.playing || state==nil || requests==nil {return}
    if core.count(spans)==0 && len(state.entries.values)==0 {return}

    // Stop any active emitter that lost its Particle_Animation_Span while still
    // keeping its Particle_Emitter, then prune removed spans and emitters.
    c_spans:=core.changes(spans,&state.seen_spans)
    c_emitters:=core.changes(emitters,&state.seen_emitters)
    for e in c_spans.gone {
        if entry:=core.entity_map_get(&state.entries,e);entry!=nil && entry.active && core.has(emitters,e) {
            vfx.stop(requests,e)
            entry.active=false
        }
    }
    core.entity_map_prune(&state.entries,spans,c_spans)
    core.entity_map_prune(&state.entries,emitters,c_emitters)

    items:[]anim.Animation_Event
    if events.ptr!=nil {items=events.items[:]}

    joined:=core.join(spans,emitters)
    for e,cfg,_ in core.each_joined(&joined) {
        cfg:=cfg
        source:=span_resolve_source(e,cfg.source,animations,parents,entities.ptr)
        entry:=core.entity_map_get(&state.entries,e)
        if entry!=nil && entry.active {
            source_dead:=entry.source==core.NONE || !core.alive(entities.ptr,entry.source) || !core.has(animations,entry.source)
            if source_dead || source!=entry.source {
                vfx.stop(requests,e)
                entry^={}
            }
        }
        if source==core.NONE || cfg.span[0]==0 || len(items)==0 {continue}

        span_hash:=base.name_hash(base.text_get(cfg.span[:]))
        end_text:=base.text_get(cfg.end_marker[:])
        paired:=len(end_text)>0
        end_hash:=base.name_hash(end_text) if paired else 0
        action_text:=base.text_get(cfg.action[:])
        action_hash:=base.name_hash(action_text) if len(action_text)>0 else 0

        for ev in items {
            if ev.entity!=source {continue}
            if action_hash!=0 && ev.action!=action_hash {continue}

            is_begin:=(!paired && ev.kind==.Span_Begin && ev.name==span_hash) ||
                (paired && ev.kind==.Marker && ev.name==span_hash)
            is_end:=(!paired && ev.kind==.Span_End && ev.name==span_hash) ||
                (paired && ev.kind==.Marker && ev.name==end_hash)

            switch {
            case is_begin:
                if entry==nil {
                    entry,_=core.entity_map_put(&state.entries,e,Span_Active{})
                    if entry==nil {continue}
                }
                if !entry.active {
                    if cfg.restart_on_begin {vfx.restart(requests,e)}
                    vfx.start(requests,e)
                    entry.active=true
                    entry.depth=1
                } else if !paired {
                    if entry.depth<max(u16) {entry.depth+=1}
                } else if cfg.restart_on_begin {
                    vfx.restart(requests,e)
                }
                entry.source=source
                entry.action=ev.action
            case is_end:
                if entry!=nil && entry.active {
                    if !paired && entry.depth>1 {
                        entry.depth-=1
                    } else {
                        vfx.stop(requests,e)
                        entry^={}
                    }
                }
            case ev.kind==.Interrupted || ev.kind==.Ended:
                if entry!=nil && entry.active && (entry.action==0 || ev.action==0 || entry.action==ev.action) {
                    vfx.stop(requests,e)
                    entry^={}
                }
            }
        }
    }
}

// Finds the animated entity driving e: explicit source if alive with Animation,
// otherwise self or the nearest core.Parent ancestor with Animation.
@(private)
span_resolve_source :: proc(
    e,explicit:core.Entity,
    animations:^core.Table(anim.Animation,.Read),
    parents:^core.Table(core.Parent,.Read),
    es:^core.Entities,
) -> core.Entity {
    if explicit!=core.NONE {
        if es!=nil && !core.alive(es,explicit) {return core.NONE}
        return explicit if core.has(animations,explicit) else core.NONE
    }
    at:=e
    for _ in 0..<SPAN_ANCESTOR_LIMIT {
        if at==core.NONE {return core.NONE}
        if core.has(animations,at) && (es==nil || core.alive(es,at)) {return at}
        if parents==nil {return core.NONE}
        parent,has:=core.get(parents,at)
        if !has || parent.entity==at {return core.NONE}
        at=parent.entity
    }
    return core.NONE
}
