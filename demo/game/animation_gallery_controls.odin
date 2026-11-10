package game

import "core:fmt"
import "core:math"
import "mirai:core"
import gui "mirai:engine/gui"
import "mirai:std/base"
import anim "plugins:animation/runtime"
import phys "plugins:physics/runtime"

Gallery_Command_Kind :: enum u8 {Automatic,Playing,Restart,Seek,Rate,Weight,Parameter,Speed,Clip,Layer,Action,Modifier,Match_Play,Value,Warp}
Gallery_Command :: struct {
    kind:Gallery_Command_Kind,
    entity:core.Entity,
    value:f32,
    slot:u16,
    name:[64]u8,
    modifier:anim.Modifier_Kind,
    enabled:bool,
}

// What the panels of the stations ask in a tick, for the fixed steps that do it.
@(storage)
Gallery_UI :: struct {commands:[64]Gallery_Command,count:u8}

gallery_request :: proc(panel:^Gallery_UI,kind:Gallery_Command_Kind,entity:core.Entity=core.NONE,value:f32=0,slot:u16=0,name:string="",modifier:anim.Modifier_Kind=.IK,enabled:bool=true) -> bool {
    if panel==nil || int(panel.count)>=len(panel.commands) || math.is_nan(value) || math.is_inf(value) || len(name)>=64 {return false}
    command:=Gallery_Command{kind=kind,entity=entity,value=value,slot=slot,modifier=modifier,enabled=enabled}
    base.text_set(command.name[:],name)
    panel.commands[panel.count]=command;panel.count+=1
    return true
}

// A station is manual from the first change a panel asks of it until it asks for the automatic
// demo again.
gallery_manual :: proc(manual:bool,entity:core.Entity,commands:[]Gallery_Command) -> bool {
    result:=manual
    for command in commands {
        if command.entity!=entity {continue}
        #partial switch command.kind {
        case .Modifier:
        case .Automatic: result=!command.enabled
        case: result=true
        }
    }
    return result
}

gallery_playback_commands :: proc(commands:[]Gallery_Command,animations:^core.Table(anim.Animation),requests:^anim.Animation_Requests,actions:^anim.Action_Requests,modifiers:^anim.Modifier_Requests) {
    for &command in commands {
        #partial switch command.kind {
        case .Modifier:
            anim.modifier_control(modifiers,{rig=command.entity,kind=command.modifier,slot=command.slot,weight=command.value,enabled=command.enabled,fade=.2})
            continue
        case .Action: anim.action_fire(actions,command.entity,base.text_get(command.name[:]));continue
        case .Match_Play: anim.match_play(requests,command.entity,base.text_get(command.name[:]),u16(phys.MODE_WALKING));continue
        case .Speed,.Value,.Warp: continue
        }
        animation:=core.get(animations,command.entity);if animation==nil {continue}
        #partial switch command.kind {
        case .Automatic: if command.enabled {animation.playing=true}
        case .Playing: anim.animation_command(requests,command.entity,.Resume if command.enabled else .Pause)
        case .Restart: anim.animation_command(requests,command.entity,.Play)
        case .Seek: anim.animation_seek(requests,command.entity,command.value)
        case .Rate: animation.speed=command.value
        case .Weight: anim.animation_weight(animation,0,command.value)
        case .Parameter: anim.animation_parameter(animation,GALLERY_WAVE,command.value)
        case .Clip: anim.animation_play(animation,base.text_get(command.name[:]),speed=animation.speed)
        case .Layer: anim.animation_weight(animation,1,command.value)
        }
    }
}

GALLERY_PANEL_ROWS :: 4
GALLERY_PANEL_BUTTONS :: 4

Gallery_Panel_Row :: struct {label:[24]u8 `mirai:"text"`,readout:[16]u8 `mirai:"text"`,value:f32}
Gallery_Panel_Button :: struct {label:[20]u8 `mirai:"text"`}

// The 3D panel of a station. It shows what its station does now and, while E frames it, its
// sliders and buttons ask the station for changes. The rows and buttons are those of the kind of
// its station (gallery_controls).
@(component,description="An adjustable panel of an animation gallery station: E at the station frames it and frees the pointer for its sliders and buttons.")
Gallery_Panel :: struct {
    station,camera:core.Entity,
    title:[64]u8 `mirai:"text"`,
    hint:[48]u8 `mirai:"text,hidden,readonly,transient"`,
    rows:[GALLERY_PANEL_ROWS]Gallery_Panel_Row `mirai:"hidden,readonly,transient"`,
    buttons:[GALLERY_PANEL_BUTTONS]Gallery_Panel_Button `mirai:"hidden,readonly,transient"`,
    row_count,button_count:i32 `mirai:"hidden,readonly,transient"`,
}

// A slider of a panel: the command it asks with the value between min and max.
Gallery_Control :: struct {label:string,command:Gallery_Command_Kind,min,max:f32,slot:u16,modifier:anim.Modifier_Kind}
Gallery_Button :: struct {label:string,command:Gallery_Command_Kind,name:string,slot:u16}

gallery_controls :: proc(kind:Gallery_Kind) -> (rows:[GALLERY_PANEL_ROWS]Gallery_Control,row_count:int,buttons:[GALLERY_PANEL_BUTTONS]Gallery_Button,button_count:int) {
    automatic:=Gallery_Button{label="Automatic",command=.Automatic}
    #partial switch kind {
    case .Direct:
        rows[0],rows[1]={label="Play rate",command=.Rate,min=-2,max=2},{label="Time",command=.Seek,max=1}
        buttons[0],buttons[1],buttons[2],buttons[3]={label="walk",command=.Clip,name="walk"},{label="wave",command=.Clip,name="wave"},{label="jog",command=.Clip,name="jog"},automatic
        return rows,2,buttons,4
    case .Matching:
        rows[0]={label="Speed",command=.Speed,max=GALLERY_MATCH_SPEED}
        buttons[0],buttons[1]={label="Inertial wave",command=.Match_Play,name="wave"},automatic
        return rows,1,buttons,2
    case .Layered: rows[0]={label="Greeting",command=.Layer,max=1}
    case .Sync: rows[0]={label="Jog blend",command=.Layer,max=1}
    case .Additive: rows[0]={label="Wave",command=.Parameter,max=1}
    case .Graph:
        rows[0]={label="Greeting layer",command=.Parameter,max=1}
        buttons[0],buttons[1]={label="Greet",command=.Action,name="Greet"},automatic
        return rows,1,buttons,2
    case .Actions:
        buttons[0],buttons[1],buttons[2]={label="Greet",command=.Action,name="Greet"},{label="Step",command=.Action,name="Step"},automatic
        return rows,0,buttons,3
    case .Warp:
        rows[0]={label="Goal / stride",command=.Value,min=.7,max=1.3}
        buttons[0],buttons[1]={label="Stride",command=.Warp},automatic
        return rows,1,buttons,2
    case .IK:
        rows[0],rows[1]={label="Target height",command=.Value,min=.9,max=1.8},{label="Target reach",command=.Value,min=.1,max=.8,slot=1}
        rows[2],rows[3]={label="Hand IK",command=.Modifier,max=1,modifier=.IK},{label="Look at",command=.Modifier,max=1,modifier=.Look}
        buttons[0]=automatic
        return rows,4,buttons,1
    case .Sequence:
        rows[0]={label="Play rate",command=.Rate,min=-2,max=2}
        buttons[0],buttons[1]={label="Play / pause",command=.Playing},{label="Restart",command=.Restart}
        return rows,1,buttons,2
    case: return
    }
    buttons[0]=automatic
    return rows,1,buttons,1
}

// What a slider or a button of a panel asked becomes a command of its station; Play / pause asks
// for the other of what its clip does.
@(step="fixed",before="gallery_animate")
gallery_panel_input :: proc(panels:core.Read(Gallery_Panel),gallery:core.Read(Animation_Gallery),ui_events:core.Ref(gui.UI_Events),playback:core.Ref(anim.Playback),panel:^Gallery_UI) {
    for event in ui_events.items {
        value,found:=core.get(panels,event.entity)
        if !found || event.item<0 {continue}
        item,exists:=core.get(gallery,value.station)
        if !exists {continue}
        rows,row_count,buttons,button_count:=gallery_controls(item.kind)
        if event.kind==.Changed && event.name==base.name_hash("value") && int(event.item)<row_count {
            row:=rows[event.item]
            high:=row.max
            if row.command==.Seek {_,duration,_,valid:=anim.animation_progress(playback.ptr,value.station);if !valid {continue};high=duration}
            amount:=row.min+f32(clamp(event.value,0,1))*(high-row.min)
            gallery_request(panel,row.command,value.station,value=amount,slot=row.slot,modifier=row.modifier,enabled=amount>0 || row.command!=.Modifier)
        } else if event.kind==.Clicked && event.name==base.name_hash("button") && int(event.item)<button_count {
            button:=buttons[event.item]
            gallery_request(panel,button.command,value.station,name=button.name,enabled=button.command!=.Playing || !anim.animation_playing(playback.ptr,value.station))
        }
    }
}

// Fills each panel with the rows and buttons of its station and what the station does now.
@(step="fixed",stage="react",after="gallery_observe")
gallery_panels :: proc(panels:^core.Table(Gallery_Panel),gallery:core.Read(Animation_Gallery),animations:core.Read(anim.Animation),playback:core.Ref(anim.Playback),modifiers:core.Ref(anim.Modifier_Runtime)) {
    for row in 0..<core.count(panels) {
        current:=core.at(core.read(panels),row)
        item,exists:=core.get(gallery,current.station)
        if !exists {continue}
        animation,_:=core.get(animations,current.station)
        rows,row_count,buttons,button_count:=gallery_controls(item.kind)
        next:=current
        next.row_count,next.button_count=i32(row_count),i32(button_count)
        for control,i in rows[:row_count] {
            value,high:f32=0,control.max
            #partial switch control.command {
            case .Rate: value=animation.speed
            case .Seek: clock,duration,_,valid:=anim.animation_progress(playback.ptr,current.station);if valid {value,high=clock,duration}
            case .Speed: value=item.speed
            case .Layer: value=animation.layers[0].weight
            case .Parameter: value,_=anim.animation_parameter_value(animation,GALLERY_WAVE)
            case .Value: value=item.values[control.slot]
            case .Modifier:
                value=1
                for state in modifiers.controls {if state.rig==current.station && state.kind==control.modifier {value=state.target if state.enabled else 0}}
            }
            line:=&next.rows[i]
            base.text_set(line.label[:],control.label)
            line.readout={};fmt.bprintf(line.readout[:len(line.readout)-1],"%.2f",value)
            line.value=clamp((value-control.min)/(high-control.min),0,1) if high>control.min else 0
        }
        for button,i in buttons[:button_count] {base.text_set(next.buttons[i].label[:],button.label)}
        hint:="manual    E: back" if item.manual else "automatic    E: back"
        if item.kind==.Sequence {hint="playing    E: back" if anim.animation_playing(playback.ptr,current.station) else "paused    E: back"}
        base.text_set(next.hint[:],hint)
        if next!=current {core.at(panels,row)^=next}
    }
}
