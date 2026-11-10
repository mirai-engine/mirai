package animation_editor

import "core:fmt"
import "core:math"
import "core:reflect"
import aa "mirai:asset"
import "mirai:core"
import "mirai:editor"
import "mirai:host"
import lib "mirai:std/anim"
import "mirai:std/base"
import mm "mirai:std/math"
import "mirai:std/serial"
import "mirai:ui"
import anim "plugins:animation/runtime"

// The Tracks tool: the tracks of the clip an entity's Animation plays, by target and field, over
// a ruler with the head, for any clip (a door, a light, a camera move, a cinematic). The scene
// shows the clip at the head because the tool seeks it there, as the preview of an Animation: the
// document does not change. Every edit is a call of animation.key.set, animation.track.set or
// animation.key.capture, one step of undo each; the tool keeps only its view. The gizmo letting go
// of an entity the clip moves keys it at the head. Another tool shows it on an entity of its own
// in place of its panel (tracks_open), as Cinematics does.

TRACKS_TOOL :: "tracks"
TRACKS_SCOPE :: ui.Id(0x74726b73)
TRACKS_SECONDS :: 2 // the least the ruler shows; past a longer clip it shows a quarter more, to key after its end
TRACKS_LANES :: 6   // tracks the strip shows at once
TRACKS_FIELDS :: 64 // values of the selected entity the list of a new track offers

@(storage,free="tracks_free")
Tracks :: struct {
    entity:core.Entity, // whose Animation plays the clip shown
    selected:core.Entity, // the first of the selection when the tool last followed it
    head:f32,           // seconds
    playing,loop:bool,
    speed:f32,
    shown:f32,          // the head the clip was sought at; <0: it has to be sought
    on:bool,            // it showed in the last frame
    opened:bool,        // another tool shows it in this frame
    moving:bool,        // the gizmo was moving the selection in the last frame
    track:int,          // of the clip, chosen; -1: none
    key:f32,            // the time of the key chosen on it; <0: none
    first:int,          // the first track the strip shows
    field:int,          // of the values of the selected entity, the one a new track keys
    menu:Tracks_Menu,
    strip:editor.Timeline,
    scroll:[2]f32,
    file:aa.Asset,      // the .anim shown, as the registry had it at hash
    hash:u64,
}
TRACKS_DEFAULT :: Tracks{speed=1,shown=-1,track=-1,key=-1,field=-1}
Tracks_Menu :: struct {track:int,time:f32,on_key:bool}

@(storage)
Tracks_Api :: struct {provider:editor.Api_Provider}
TRACKS_API_DEFAULT :: Tracks_Api{provider={register=tracks_register}}

tracks_free :: proc(t:^Tracks) {aa.asset_close(&t.file);t^={}}

@(private)
tracks_tool_state :: proc(s:^editor.Session) -> ^Tracks {
    return core.world_storage_of(core.world_ref(s.editor_world,s.info,.Editor),Tracks)
}

// Shows the tool on the clip of the Animation of an entity for this frame, in place of the panel
// of the tool named, which lends the scene to the gizmo: the frame step of that tool calls it
// while it is on, and its panel draws tracks_rows.
tracks_open :: proc(s:^editor.Session,entity:core.Entity,tool:string) {
    t:=tracks_tool_state(s)
    if t==nil {return}
    tracks_choose(t,entity)
    t.opened=true
    editor.tool_lend(s,tool)
    if !t.on {s.viewport.plugin_aside=true}
}

// Where the head of the tool is on the clip of an entity; shown false when it does not show it.
tracks_head :: proc(s:^editor.Session,entity:core.Entity) -> (seconds:f32,playing,shown:bool) {
    t:=tracks_tool_state(s)
    if t==nil || !t.on || t.entity!=entity {return}
    return t.head,t.playing,true
}

@(private)
tracks_choose :: proc(t:^Tracks,entity:core.Entity) {
    if t.entity==entity {return}
    t.entity,t.head,t.playing,t.shown,t.track,t.key,t.first,t.strip=entity,0,false,-1,-1,-1,0,{}
}

// Frames per second of the ruler: the ticks of the fixed loop, as the settings of the project have them.
tracks_rate :: proc(s:^editor.Session) -> f32 {
    if s.app!=nil && s.app.shared!=nil {
        if settings:=core.world_storage_of(core.world_ref(s.app.shared,s.app.info,.Shared),core.Simulation_Settings);settings!=nil && settings.tick_rate>0 {return f32(settings.tick_rate)}
    }
    return f32(core.SIMULATION_SETTINGS_DEFAULT.tick_rate)
}

@(private)
tracks_seek :: proc(w:core.World_Ref,entity:core.Entity,seconds:f32) {
    if requests:=core.world_storage_of(w,anim.Animation_Requests);requests!=nil && entity!=core.NONE {anim.animation_seek(requests,entity,seconds)}
}

// The clip the tool shows, from the .anim as the registry has it now: the file opens again when
// its content changes, and the scene is shown at the head again.
@(private)
tracks_clip :: proc(s:^editor.Session,t:^Tracks,w:core.World_Ref) -> (view:aa.Animation_View,clip:int,ok:bool) {
    animation:=editor.entity_get(w,t.entity,anim.Animation) or_return
    if s.app==nil || s.app.assets==nil {return}
    a:=s.app.assets
    record:=aa.registry_find(&a.registry,animation.asset) or_return
    if record.kind!=aa.KIND_ANIMATION {return}
    if t.hash==0 || t.hash!=record.content_hash || t.file.blob.header.id!=animation.asset {
        aa.asset_close(&t.file)
        t.file,t.hash,t.shown={},0,-1
        if host.assets_file(a,animation.asset,aa.KIND_ANIMATION,&t.file)!=.None {return}
        t.hash=record.content_hash
    }
    error:aa.Error
    if view,error=aa.animation_view(&t.file,&a.types);error!=.None {return}
    name:=base.text_get(animation.clip[:])
    for &each,i in view.clips {if base.text_get(each.name[:])==name || name=="" && i==0 {return view,i,true}}
    return
}

// Seconds of a clip: its last key or marker.
tracks_duration :: proc(view:aa.Animation_View,clip:int) -> (seconds:f32) {
    c:=view.clips[clip]
    for track in view.tracks[c.first_track:][:c.track_count] {
        if track.key_count>0 {seconds=max(seconds,view.keys[track.first_key+track.key_count-1].time)}
    }
    for marker in view.markers[c.first_marker:][:c.marker_count] {seconds=max(seconds,marker.time)}
    return
}

// The entity whose clip moves e: itself with an Animation, the one its Animation_Target names, else
// the nearest above it with one.
@(private)
tracks_animated :: proc(w:core.World_Ref,e:core.Entity) -> core.Entity {
    if editor.entity_has(w,e,anim.Animation) {return e}
    if target,ok:=editor.entity_get(w,e,anim.Animation_Target);ok && target.animation!=core.NONE {return target.animation}
    for parent:=editor.entity_parent(w,e);parent!=core.NONE;parent=editor.entity_parent(w,parent) {
        if editor.entity_has(w,parent,anim.Animation) {return parent}
    }
    return core.NONE
}

// What a track moves: its target and field, or only the field of the entity that plays the clip.
@(private)
track_label :: proc(track:^aa.Animation_Track) -> string {
    node,component,field:=track_parts(base.text_get(track.target[:]))
    what:=fmt.tprintf("%v",track.property) if component=="" else fmt.tprintf("%s.%s",component,field)
    return what if node=="" else fmt.tprintf("%s %s",node,what)
}

// The params that name a track of the clip shown, for animation.key.set and animation.track.set.
@(private)
tracks_params :: proc(asset:base.Asset_Id,clip:string,target:string,property:lib.Property,slot:u8) -> string {
    text:[base.ASSET_ID_TEXT]u8
    return fmt.tprintf(`"asset":"%s","clip":%q,"target":%q,"property":"%v","slot":%d`,base.asset_id_format(asset,text[:]),clip,target,property,slot)
}

@(private)
tracks_value_text :: proc(v:[4]f32) -> string {return fmt.tprintf("[%v,%v,%v,%v]",v[0],v[1],v[2],v[3])}

@(step="ui",after="editor_panels")
tracks_frame :: proc(s:^editor.Session,t:^Tracks,frame:core.Frame_Time) {
    opened:=t.opened
    t.opened=false
    own:=editor.tool_on(s,TRACKS_TOOL)
    w:=editor.edited_world(s)
    if editor.playing(s) || !own && !opened {
        // The scene goes back to the start of the clip, as when the preview of an Animation ends.
        if t.on && !editor.playing(s) {tracks_seek(w,t.entity,0)}
        t.on,t.playing,t.shown,t.moving,t.selected=false,false,-1,false,core.NONE
        return
    }
    if own {
        editor.tool_lend(s,TRACKS_TOOL)
        if !t.on {s.viewport.plugin_aside=true}
        // A new selection chooses the clip that moves it.
        first:=s.selection.entities[0] if len(s.selection.entities)>0 else core.NONE
        if first!=t.selected {
            t.selected=first
            if animated:=tracks_animated(w,first);animated!=core.NONE {tracks_choose(t,animated)}
        }
    }
    t.on=true
    view,clip,ok:=tracks_clip(s,t,w)
    duration:=tracks_duration(view,clip) if ok else 0
    span:=max(duration*1.25,TRACKS_SECONDS)
    if t.playing && duration>0 {
        t.head+=frame.dt*max(t.speed,0)
        if t.head>=duration {
            if t.loop {t.head=math.mod(t.head,duration)} else {t.head,t.playing=duration,false}
        }
    }
    t.head=clamp(t.head,0,span)
    if t.shown!=t.head {tracks_seek(w,t.entity,t.head)}
    t.shown=t.head
    moving:=s.viewport.gizmo.drag.active
    if t.moving && !moving && ok {tracks_key_moved(s,t,w,view,clip)}
    t.moving=moving

    g:=s.gui
    if !g.begun || s.viewport.pick.active {return}
    ctx:=g.ctx;th:=&ctx.theme
    if own {
        id:=ui.id_derive(ctx,TRACKS_SCOPE,"panel")
        if ui.panel(ctx,id,editor.tool_panel(g,id)) {
            ui.id_push(ctx,id);defer ui.id_pop(ctx)
            tracks_rows(s)
        }
    }
    if !ok {return}
    left,right:=th.margin,ctx.size.x-th.margin
    if r:=g.rects.left;r.w>0 {left=r.x+r.w+th.margin}
    if r:=g.rects.right;r.w>0 {right=r.x-th.margin}
    bottom:=th.margin
    if r:=g.rects.bottom;r.h>0 {bottom+=ctx.size.y-r.y}
    strip:=ui.id_derive(ctx,TRACKS_SCOPE,"strip")
    if ui.panel(ctx,strip,{width=ui.fixed(max(right-left,320)),height=ui.FIT,padding={0,4,0,4},anchor=.Bottom_Left,pivot=.Bottom_Left,offset={left,-bottom}}) {
        ui.id_push(ctx,strip);defer ui.id_pop(ctx)
        tracks_strip(s,t,w,view,clip,duration,span)
    }
}

// The gizmo let go of entities the clip moves: each is keyed at the head, in the step of the move.
@(private)
tracks_key_moved :: proc(s:^editor.Session,t:^Tracks,w:core.World_Ref,view:aa.Animation_View,clip:int) {
    c:=view.clips[clip]
    for item in s.viewport.gizmo.items {
        if !editor.entity_alive(w,item.entity) || editor.entity_local(w,item.entity)==item.local {continue}
        name,reached:=track_name(w,t.entity,item.entity)
        if !reached {continue}
        for &track in view.tracks[c.first_track:][:c.track_count] {
            node,component,_:=track_parts(base.text_get(track.target[:]))
            if node!=name || component!="" {continue}
            editor.command_join(s,"animation.key.capture",fmt.tprintf(`{{"animation":"%016x","entity":"%016x","time":%v}}`,u64(editor.api_entity_id(w,t.entity)),u64(editor.api_entity_id(w,item.entity)),t.head))
            break
        }
    }
}

// The ruler of the clip with a lane of keys for each track in view: a press chooses a key, a drag
// moves it, the button of a lane adds one at the head with the value the track has there, and the
// right button adds or deletes one.
@(private)
tracks_strip :: proc(s:^editor.Session,t:^Tracks,w:core.World_Ref,view:aa.Animation_View,clip:int,duration,span:f32) {
    ctx:=s.gui.ctx;th:=&ctx.theme
    rate:=tracks_rate(s)
    animation,_:=editor.entity_get(w,t.entity,anim.Animation)
    c:=view.clips[clip]
    name:=base.text_get(c.name[:])
    tracks:=view.tracks[c.first_track:][:c.track_count]
    count:=len(tracks)
    if t.track>=count {t.track,t.key=-1,-1}
    if t.track>=0 {
        if t.track<t.first {t.first=t.track} else if t.track>=t.first+TRACKS_LANES {t.first=t.track-TRACKS_LANES+1}
    }
    t.first=clamp(t.first,0,max(count-TRACKS_LANES,0))
    shown:=tracks[t.first:][:min(TRACKS_LANES,count-t.first)]
    lanes:=make([]editor.Timeline_Lane,len(shown),context.temp_allocator)
    t.strip.mark={}
    for &track,i in shown {
        keys:=view.keys[track.first_key:][:track.key_count]
        marks:=make([]editor.Timeline_Mark,len(keys),context.temp_allocator)
        for key,j in keys {
            marks[j].frame=key.time*rate
            if t.first+i==t.track && t.key>=0 && abs(key.time-t.key)<=AUTHORING_TIME_EPSILON {t.strip.mark={i,j+1}}
        }
        lanes[i]={name=track_label(&track),marks=marks,add=true}
    }
    if ui.box(ctx,{width=ui.GROW,height=ui.fixed(th.row),padding={12,0,12,0},gap=8,align_y=.Center}) {
        ui.label(ctx,editor.entity_label(w,t.entity),th.font_small,th.text,font=ui.FONT_SEMIBOLD)
        ui.label(ctx,name,th.font_small,th.text_muted)
    }
    clock:=editor.Timeline_Clock{frame=t.head*rate,frames=span*rate,rate=rate,playing=t.playing,loop=t.loop,speed=t.speed,ask=editor.timeline_can_ask(s)}
    r:=editor.timeline_strip(s,&t.strip,clock,lanes,ui.id(ctx,"timeline"))
    if (r.ask || r.copy) && t.strip.range {
        lo,hi:=editor.timeline_range(&t.strip,clock.frames)
        range:=editor.Ai_Range{kind=.Clip,from=u64(lo),to=u64(hi)}
        if s.document!=nil {base.text_set(range.path[:],editor.document_path(s.document))}
        base.text_set(range.name[:],editor.entity_label(w,t.entity))
        editor.timeline_range_use(s,r,range)
    }
    if r.seek {t.head,t.playing=r.frame/rate,false}
    if r.loop {t.loop=!t.loop}
    if r.speed>0 {t.speed=r.speed}
    if r.play {
        t.playing=!t.playing
        if t.playing && t.head>=duration {t.head=0}
    }
    if picked:=t.strip.mark;picked[1]>0 && picked[0]<len(shown) {
        track:=shown[picked[0]]
        t.track,t.key=t.first+picked[0],view.keys[track.first_key+u32(picked[1]-1)].time
    } else {t.key=-1}
    switch {
    case r.moved && r.lane<len(shown):
        track:=shown[r.lane]
        from,to:=view.keys[track.first_key+u32(r.index)].time,max(r.to,0)/rate
        params:=tracks_params(animation.asset,name,base.text_get(track.target[:]),track.property,track.slot)
        editor.command_call(s,"animation.key.set",fmt.tprintf(`{{%s,"time":%v,"to":%v}}`,params,from,to))
        t.track,t.key=t.first+r.lane,to
    case r.add && r.lane<len(shown):
        tracks_key_add(s,animation.asset,name,view,&shown[r.lane],t.head)
    case r.menu && r.lane<len(shown):
        track:=shown[r.lane]
        t.menu={t.first+r.lane,view.keys[track.first_key+u32(r.index)].time if r.index>=0 else max(r.to,0)/rate,r.index>=0}
        ui.popup_open(ctx,ui.id(ctx,"menu"),r.anchor)
    }
    if ui.popup(ctx,ui.id(ctx,"menu"),{min_width=ui.MENU_CHOICE_WIDTH}) {
        if t.menu.track<count {
            track:=&tracks[t.menu.track]
            if !t.menu.on_key {
                if ui.menu_item(ctx,ui.id(ctx,"menu_add"),"Add key",{icon=.Plus}) {tracks_key_add(s,animation.asset,name,view,track,t.menu.time)}
            } else if ui.menu_item(ctx,ui.id(ctx,"menu_delete"),"Delete key",{icon=.Cross,danger=true}) {
                params:=tracks_params(animation.asset,name,base.text_get(track.target[:]),track.property,track.slot)
                editor.command_call(s,"animation.key.set",fmt.tprintf(`{{%s,"time":%v,"remove":true}}`,params,t.menu.time))
            }
        }
    }
}

// Adds a key at a time with the value the track has there.
@(private)
tracks_key_add :: proc(s:^editor.Session,asset:base.Asset_Id,clip:string,view:aa.Animation_View,track:^aa.Animation_Track,time:f32) {
    value:=lib.track_evaluate(view.keys[track.first_key:][:track.key_count],track.property,time)
    params:=tracks_params(asset,clip,base.text_get(track.target[:]),track.property,track.slot)
    editor.command_call(s,"animation.key.set",fmt.tprintf(`{{%s,"time":%v,"key":{{"value":%s}}}}`,params,time,tracks_value_text(value)))
}

// The rows of the panel of the tool: its clip, the tracks by target and field, how the key chosen
// arrives, and a new track for a value of the selected entity. Another tool that shows it draws
// them in its own panel.
tracks_rows :: proc(s:^editor.Session) {
    t:=tracks_tool_state(s)
    if t==nil {return}
    ctx:=s.gui.ctx;th:=&ctx.theme
    w:=editor.edited_world(s)
    ui.section(ctx,"Tracks")
    view,clip,ok:=tracks_clip(s,t,w)
    if !ok {return}
    animation,_:=editor.entity_get(w,t.entity,anim.Animation)
    c:=view.clips[clip]
    name:=base.text_get(c.name[:])
    tracks:=view.tracks[c.first_track:][:c.track_count]
    if ui.scroll_area(ctx,ui.id(ctx,"tracks"),&t.scroll,{width=ui.GROW,height=ui.FIT,direction=.Column,max_height=8*th.row}) {
        for &track,i in tracks {
            if ui.row(ctx,ui.id(ctx,"track",i+1),{label=track_label(&track),detail=fmt.tprintf("%d",track.key_count),selected=t.track==i}).clicked {
                if t.track!=i {t.track,t.key=i,-1}
            }
        }
    }
    if t.track>=0 && t.track<len(tracks) {
        track:=&tracks[t.track]
        keys:=view.keys[track.first_key:][:track.key_count]
        params:=tracks_params(animation.asset,name,base.text_get(track.target[:]),track.property,track.slot)
        if ui.box(ctx,{width=ui.GROW,height=ui.FIT,gap=4}) {
            if ui.button(ctx,ui.id(ctx,"key_add"),{label="Add key",icon=.Plus,style=.Field,width=-1,center=true}).clicked {tracks_key_add(s,animation.asset,name,view,track,t.head)}
            if ui.button(ctx,ui.id(ctx,"track_remove"),{label="Remove track",icon=.Cross,style=.Field,width=-1,center=true}).clicked {
                editor.command_call(s,"animation.track.set",fmt.tprintf(`{{%s,"remove":true}}`,params))
                t.track,t.key=-1,-1
            }
        }
        at,exists:=-1,false
        if t.key>=0 {at,exists=authoring_key_at(keys,t.key)}
        if exists {
            key:=keys[at]
            ui.section(ctx,"Key")
            interpolation,ease:=int(key.interpolation),int(key.ease)
            if ui.property(ctx,"Interpolation") {
                if ui.dropdown(ctx,ui.id(ctx,"interpolation"),{list=reflect.enum_field_names(lib.Interpolation)},&interpolation,{width=-1}) {
                    editor.command_call(s,"animation.key.set",fmt.tprintf(`{{%s,"time":%v,"key":{{"interpolation":"%v"}}}}`,params,key.time,lib.Interpolation(interpolation)))
                }
            }
            if ui.property(ctx,"Ease") {
                if ui.dropdown(ctx,ui.id(ctx,"ease"),{list=reflect.enum_field_names(mm.Ease)},&ease,{width=-1,searchable=true}) {
                    editor.command_call(s,"animation.key.set",fmt.tprintf(`{{%s,"time":%v,"key":{{"ease":"%v"}}}}`,params,key.time,mm.Ease(ease)))
                }
            }
            if ui.button(ctx,ui.id(ctx,"key_delete"),{label="Delete key",icon=.Cross,style=.Field,width=-1,center=true}).clicked {
                editor.command_call(s,"animation.key.set",fmt.tprintf(`{{%s,"time":%v,"remove":true}}`,params,key.time))
            }
        }
    }
    // A new track keys a value of the first selected entity the clip moves.
    e:=core.NONE
    for selected in s.selection.entities {if _,reached:=track_name(w,t.entity,selected);reached {e=selected;break}}
    fields:=track_fields(w,t.entity,e) if e!=core.NONE else nil
    labels:=make([]string,len(fields),context.temp_allocator)
    for field,i in fields {labels[i]=field.label}
    if t.field>=len(fields) {t.field=-1}
    taken:=false
    if t.field>=0 {
        for &track in tracks {if base.text_get(track.target[:])==fields[t.field].target && track.property==fields[t.field].property {taken=true}}
    }
    ui.section(ctx,"New track")
    if ui.property(ctx,"Value") {
        ui.dropdown(ctx,ui.id(ctx,"field"),{list=labels},&t.field,{width=-1,empty="None",disabled=len(fields)==0,searchable=true})
    }
    if ui.button(ctx,ui.id(ctx,"track_add"),{label="Add track",icon=.Plus,style=.Field,width=-1,center=true,disabled=t.field<0 || taken}).clicked {
        field:=fields[t.field]
        _,component,path:=track_parts(field.target)
        schema:serial.Schema
        serial.schema_init(&schema,context.temp_allocator)
        if value,read:=track_value(w,&schema,e,field.property,component,path);read {
            params:=tracks_params(animation.asset,name,field.target,field.property,0)
            editor.command_call(s,"animation.track.set",fmt.tprintf(`{{%s,"keys":[{{"time":%v,"value":%s}}]}}`,params,t.head,tracks_value_text(value)))
        }
    }
}
