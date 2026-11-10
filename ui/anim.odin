package ui

import "base:runtime"
import "core:math"
import std_anim "mirai:std/anim"
import mm "mirai:std/math"

// Animation of game interfaces. An animation is data: tracks of keyframes
// over the offset, scale, rotation, opacity and color of an element, played
// alone, one after another (sequence) or together (parallel). The state of
// what is playing belongs to the caller. An animated element moves on screen
// without changing the layout around it.

Anim_Property :: enum u8 {
    Offset,   // x, y in layout units
    Scale,    // x, y around the center of the element
    Rotation, // x: radians, clockwise on screen
    Opacity,  // x: 0 to 1
    Color,    // r, g, b, a that multiply the colors of the element
    Width,    // x: layout units in place of its width; the layout around it follows
    Height,
    Value,    // x: what a Progress, a Slider or a Number shows in place of its value
    Frame,    // x: the frame of the sheet of sprites of its image
    Reveal,   // x: 0 to 1, the part of the characters of its text shown
}
Anim_Properties :: bit_set[Anim_Property;u16]
@(private)
Anim_Track :: struct {property:Anim_Property,first,count:u32}
@(private)
Anim_Node :: struct {kind:Anim_Kind,loop:std_anim.Loop,first,count:u32,duration:f32}

// An animation of a library; 0 is none.
Anim :: distinct u16

Anim_Library :: struct {
    keys:[]std_anim.Keyframe,key_count:int,
    tracks:[]Anim_Track,track_count:int,
    nodes:[]Anim_Node,node_count:int,
    children:[]Anim,child_count:int,
    allocator:runtime.Allocator,
}
Anim_Library_Desc :: struct {
    allocator:runtime.Allocator, // context.allocator when unset
    max_keys,max_tracks,max_anims,max_children:int, // 1024, 256, 128 and 256 when 0
}

anim_library_init :: proc(lib:^Anim_Library,desc:Anim_Library_Desc={}) -> bool {
    a:=desc.allocator if desc.allocator.procedure!=nil else context.allocator
    lib^={allocator=a}
    e1,e2,e3,e4:runtime.Allocator_Error
    lib.keys,e1=make([]std_anim.Keyframe,desc.max_keys if desc.max_keys>0 else 1024,a)
    lib.tracks,e2=make([]Anim_Track,desc.max_tracks if desc.max_tracks>0 else 256,a)
    lib.nodes,e3=make([]Anim_Node,desc.max_anims if desc.max_anims>0 else 128,a)
    lib.children,e4=make([]Anim,desc.max_children if desc.max_children>0 else 256,a)
    if e1!=nil || e2!=nil || e3!=nil || e4!=nil {anim_library_destroy(lib);return false}
    return true
}
anim_library_destroy :: proc(lib:^Anim_Library) {
    delete(lib.keys,lib.allocator);delete(lib.tracks,lib.allocator);delete(lib.nodes,lib.allocator);delete(lib.children,lib.allocator)
    lib^={}
}

// The keys of a property: those of std/anim, in seconds from the start of the track.
Track :: struct {property:Anim_Property,keys:[]std_anim.Keyframe}

// Adds tracks that play together. Keys go in time order; a track holds its
// first value before its first key and its last one after the last. Returns
// 0 when the library is full.
anim_clip :: proc(lib:^Anim_Library,tracks:[]Track,loop:std_anim.Loop=.Once) -> Anim {
    keys:=0
    for track in tracks {keys+=len(track.keys)}
    if lib.node_count>=len(lib.nodes) || lib.track_count+len(tracks)>len(lib.tracks) || lib.key_count+keys>len(lib.keys) {return 0}
    node:=Anim_Node{kind=.Clip,loop=loop,first=u32(lib.track_count),count=u32(len(tracks))}
    for track in tracks {
        lib.tracks[lib.track_count]={property=track.property,first=u32(lib.key_count),count=u32(len(track.keys))}
        lib.track_count+=1
        copy(lib.keys[lib.key_count:],track.keys)
        lib.key_count+=len(track.keys)
        if len(track.keys)>0 {node.duration=max(node.duration,track.keys[len(track.keys)-1].time)}
    }
    lib.nodes[lib.node_count]=node;lib.node_count+=1
    return Anim(lib.node_count)
}
// A tween: one property from a value to another.
anim_tween :: proc(lib:^Anim_Library,property:Anim_Property,from,to:[4]f32,duration:f32,easing:mm.Ease=.Cubic_Out,delay:f32=0) -> Anim {
    keys:=[3]std_anim.Keyframe{{time=0,value=from},{time=delay,value=from},{time=delay+duration,value=to,ease=easing}}
    return anim_clip(lib,{{property,keys[:] if delay>0 else keys[1:]}})
}
@(private)
anim_group :: proc(lib:^Anim_Library,kind:Anim_Kind,parts:[]Anim,loop:std_anim.Loop) -> Anim {
    if lib.node_count>=len(lib.nodes) || lib.child_count+len(parts)>len(lib.children) {return 0}
    node:=Anim_Node{kind=kind,loop=loop,first=u32(lib.child_count),count=u32(len(parts))}
    for part in parts {
        if part==0 || int(part)>lib.node_count {return 0}
        duration:=lib.nodes[part-1].duration
        if kind==.Sequence {node.duration+=duration} else {node.duration=max(node.duration,duration)}
    }
    copy(lib.children[lib.child_count:],parts)
    lib.child_count+=len(parts)
    lib.nodes[lib.node_count]=node;lib.node_count+=1
    return Anim(lib.node_count)
}
// Animations played one after another. A looping step counts once.
anim_sequence :: proc(lib:^Anim_Library,steps:[]Anim,loop:std_anim.Loop=.Once) -> Anim {return anim_group(lib,.Sequence,steps,loop)}
// Animations played together.
anim_parallel :: proc(lib:^Anim_Library,parts:[]Anim,loop:std_anim.Loop=.Once) -> Anim {return anim_group(lib,.Parallel,parts,loop)}

anim_duration :: proc(lib:^Anim_Library,anim:Anim) -> f32 {
    if anim==0 || int(anim)>lib.node_count {return 0}
    return lib.nodes[anim-1].duration
}

// What an animation does to an element at one instant.
Anim_Value :: struct {
    offset:[2]f32,
    scale:[2]f32,
    rotation:f32,
    opacity:f32,
    color:[4]f32,
    width,height,value,frame,reveal:f32,
    set:Anim_Properties, // of Width, Height, Value, Frame and Reveal: those an animation gave
}
ANIM_IDENTITY :: Anim_Value{scale={1,1},opacity=1,color={1,1,1,1}}

// The value of a track at time, as std_anim.track_evaluate gives it. from: where
// the first segment starts instead of its first key, the value the property
// had when the animation began; before a first key later than 0 it goes from
// there to that key.
@(private)
anim_track_value :: proc(lib:^Anim_Library,track:Anim_Track,time:f32,from:Maybe([4]f32)=nil) -> [4]f32 {
    keys:=lib.keys[track.first:][:track.count]
    start,blend:=from.?
    if !blend {return std_anim.track_evaluate(keys,.Vector,time)}
    lead:[2]std_anim.Keyframe
    if keys[0].time>0 {
        if time>=keys[0].time {return std_anim.track_evaluate(keys,.Vector,time)}
        lead={{value=start},keys[0]}
    } else {
        if len(keys)==1 {return keys[0].value}
        if time>=keys[1].time {return std_anim.track_evaluate(keys,.Vector,time)}
        lead={keys[0],keys[1]}
        lead[0].value=start
    }
    return std_anim.track_evaluate(lead[:],.Vector,max(time,0))
}

// What value holds of a property, and whether it holds it: Width, Height,
// Value, Frame and Reveal only once an animation gave them.
@(private)
anim_value_get :: proc "contextless" (v:^Anim_Value,property:Anim_Property) -> (out:[4]f32,held:bool) {
    switch property {
    case .Offset:return {v.offset.x,v.offset.y,0,0},true
    case .Scale:return {v.scale.x,v.scale.y,0,0},true
    case .Rotation:return {v.rotation,0,0,0},true
    case .Opacity:return {v.opacity,0,0,0},true
    case .Color:return v.color,true
    case .Width:out.x=v.width
    case .Height:out.x=v.height
    case .Value:out.x=v.value
    case .Frame:out.x=v.frame
    case .Reveal:out.x=v.reveal
    }
    return out,property in v.set
}

// Writes into value what anim does at time; properties it has no track for
// keep what value holds. from: what value held when anim began, where its
// first segments start instead of their first keys (anim_play after another
// animation); nil: they start at their keys.
anim_sample :: proc(lib:^Anim_Library,anim:Anim,time:f32,value:^Anim_Value,from:^Anim_Value=nil) {
    if anim==0 || int(anim)>lib.node_count {return}
    node:=lib.nodes[anim-1]
    from:=from
    // Only the first pass of a loop starts from there.
    if node.loop!=.Once && time>=node.duration {from=nil}
    t,_:=std_anim.loop_time(node.loop,node.duration,max(time,0))
    switch node.kind {
    case .Clip:
        for track in lib.tracks[node.first:][:node.count] {
            if track.count==0 {continue}
            start:Maybe([4]f32)
            if from!=nil {if held,ok:=anim_value_get(from,track.property);ok {start=held}}
            v:=anim_track_value(lib,track,t,start)
            switch track.property {
            case .Offset:value.offset={v.x,v.y}
            case .Scale:value.scale={v.x,v.y}
            case .Rotation:value.rotation=v.x
            case .Opacity:value.opacity=v.x
            case .Color:value.color=v
            case .Width:value.width=v.x
            case .Height:value.height=v.x
            case .Value:value.value=v.x
            case .Frame:value.frame=v.x
            case .Reveal:value.reveal=v.x
            }
            value.set+={track.property}
        }
    case .Parallel:
        for child in lib.children[node.first:][:node.count] {anim_sample(lib,child,t,value,from)}
    case .Sequence:
        // Steps that ended leave their last value for the ones that follow.
        start:f32
        for child,i in lib.children[node.first:][:node.count] {
            if t<start {break}
            duration:=lib.nodes[child-1].duration
            anim_sample(lib,child,min(t-start,duration),value,from if i==0 else nil)
            start+=duration
        }
    }
}

// What is playing on one element. Zero value: nothing.
Anim_Player :: struct {
    anim:Anim,
    time:f32,
    playing:bool,
    value:Anim_Value, // valid after the first anim_update
    from:Anim_Value,  // value when anim began after another one: where it starts
    blend:bool,       // it began after another one
}
// Plays anim from its start. After another animation it starts from the
// value that one left, not from its first keys: it does not jump.
anim_play :: proc "contextless" (player:^Anim_Player,anim:Anim) {
    player.blend,player.from=player.anim!=0,player.value
    player.anim=anim;player.time=0;player.playing=anim!=0
}
// Advances the player and samples it. Returns true while it plays: an
// animation that does not loop stops at its end and keeps its last value.
anim_update :: proc(lib:^Anim_Library,player:^Anim_Player,dt:f32) -> bool {
    if player.value.scale=={} && player.value.opacity==0 && player.value.color=={} {player.value=ANIM_IDENTITY}
    if player.anim==0 || int(player.anim)>lib.node_count {player.playing=false;return false}
    node:=lib.nodes[player.anim-1]
    if player.playing {
        player.time+=dt
        if node.loop==.Once && player.time>=node.duration {player.time=node.duration;player.playing=false}
    }
    anim_sample(lib,player.anim,player.time,&player.value,&player.from if player.blend else nil)
    return player.playing
}

// Animations an element plays when something happens to it; 0 leaves it as
// it is. What it looks like while hovered, pressed, focused or selected is
// of its style, with its transition.
Anim_Set :: struct {shown,hidden,clicked:Anim}
Anim_Flags :: struct {shown,clicked:bool}
Anim_State :: struct {
    using player:Anim_Player,
    flags:Anim_Flags, // as of the last anim_react
    started:bool,
}

// Plays what the set says for the changes between the flags of the previous
// call and these, and advances it: being shown before being clicked. Returns
// true while the element has to be built: it is shown, or still playing how
// it hides.
anim_react :: proc(lib:^Anim_Library,state:^Anim_State,set:Anim_Set,flags:Anim_Flags,dt:f32) -> bool {
    before:=state.flags
    if !state.started {before={};state.started=true;state.value=ANIM_IDENTITY}
    if !flags.shown && before.shown {
        if set.hidden!=0 {anim_play(state,set.hidden)} else {state.playing=false}
    } else {
        if flags.shown && !before.shown && set.shown!=0 {anim_play(state,set.shown)}
        else if flags.clicked && !before.clicked && set.clicked!=0 {anim_play(state,set.clicked)}
    }
    state.flags=flags
    playing:=anim_update(lib,state,dt)
    return flags.shown || (playing && state.anim==set.hidden && set.hidden!=0)
}

// ---------------------------------------------------------------- scopes

// A subtree drawn through a transform of its own.
@(private)
Scope :: struct {
    id:Id,          // element whose center is the pivot
    parent:u16,
    surface:u16,
    value:Anim_Value,
    m:Affine,       // layout units to layout units
    tint:[4]f32,
    still:bool,     // the pointer finds it where the layout put it: what a style moves
}

@(private)
affine_mul :: proc "contextless" (a,b:Affine) -> Affine {
    return {
        a[0,0]*b[0,0]+a[0,1]*b[1,0], a[0,0]*b[0,1]+a[0,1]*b[1,1], a[0,0]*b[0,2]+a[0,1]*b[1,2]+a[0,2],
        a[1,0]*b[0,0]+a[1,1]*b[1,0], a[1,0]*b[0,1]+a[1,1]*b[1,1], a[1,0]*b[0,2]+a[1,1]*b[1,2]+a[1,2],
    }
}
@(private)
affine_inverse :: proc "contextless" (m:Affine) -> Affine {
    det:=m[0,0]*m[1,1]-m[0,1]*m[1,0]
    if abs(det)<1e-12 {return AFFINE_IDENTITY}
    i:=1/det
    a,b,c,d:=m[1,1]*i,-m[0,1]*i,-m[1,0]*i,m[0,0]*i
    return {a,b,-(a*m[0,2]+b*m[1,2]), c,d,-(c*m[0,2]+d*m[1,2])}
}

// What is built until animated_end is drawn moved, scaled, rotated and tinted
// by value around the center of the element id. The pointer follows, unless
// still: what lifts a button under the pointer does not leave it.
animated_begin :: proc(ctx:^Context,id:Id,value:Anim_Value,still:=false) -> bool {
    if ctx.scope_count>=len(ctx.scopes) {ctx.stats.dropped_scopes+=1;return false}
    // The pivot is looked up after the layout.
    widget_add(ctx,id,{.Passive})
    index:=u16(ctx.scope_count)
    ctx.scopes[index]={id=id,parent=ctx.scope,surface=ctx.surface,value=value,m=AFFINE_IDENTITY,tint={1,1,1,1},still=still}
    ctx.scope_count+=1
    ctx.scope=index
    return true
}
animated_end :: proc(ctx:^Context) {
    if ctx.scope!=0 {ctx.scope=ctx.scopes[ctx.scope].parent}
}
@(deferred_in_out=animated_scope_end)
animated :: proc(ctx:^Context,id:Id,value:Anim_Value) -> bool {
    animated_begin(ctx,id,value)
    return true
}
@(private)
animated_scope_end :: proc(ctx:^Context,id:Id,value:Anim_Value,opened:bool) {
    if ctx.scope!=0 && ctx.scopes[ctx.scope].id==id {animated_end(ctx)}
}

// Runs after layout: the pivots are known.
@(private)
scopes_resolve :: proc(ctx:^Context) {
    ctx.previous_scopes[0]=AFFINE_IDENTITY
    for i in 1..<ctx.scope_count {
        s:=&ctx.scopes[i]
        parent:=&ctx.scopes[s.parent]
        pivot:[2]f32
        if w,found:=element_rect(ctx,s.id);found {pivot=rect_center(w)}
        v:=s.value
        cos,sin:=math.cos(v.rotation),math.sin(v.rotation)
        // p -> pivot + offset + R * S * (p - pivot)
        a,b,c,d:=cos*v.scale.x,-sin*v.scale.y,sin*v.scale.x,cos*v.scale.y
        local:=Affine{a,b,pivot.x+v.offset.x-(a*pivot.x+b*pivot.y), c,d,pivot.y+v.offset.y-(c*pivot.x+d*pivot.y)}
        s.m=affine_mul(parent.m,local)
        s.tint=parent.tint*v.color*[4]f32{1,1,1,v.opacity}
        ctx.previous_scopes[i]=ctx.previous_scopes[s.parent] if s.still else affine_inverse(s.m)
    }
    ctx.previous_scope_count=ctx.scope_count
}

// The rectangle an element of this frame got; valid between the layout and
// the next frame_begin.
@(private)
element_rect :: proc(ctx:^Context,id:Id) -> (Rect,bool) {
    for &w in ctx.widgets[:ctx.widget_count] {if w.id==id {return w.rect,true}}
    return {},false
}
