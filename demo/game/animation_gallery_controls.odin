package game

import "core:fmt"
import "core:math"
import "mirai:core"
import gui "mirai:engine/gui"
import "mirai:std/base"
import anim "plugins:animation/runtime"

Gallery_Command_Kind :: enum u8 {Automatic,Playing,Restart,Seek,Rate,Speed,Clip,Action,Modifier,Value,Warp}
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

gallery_playback_commands :: proc(commands:[]Gallery_Command,requests:^anim.Animation_Requests,playback:core.Ref(anim.Playback)) {
    for &command in commands {
        e:=command.entity
        #partial switch command.kind {
        case .Modifier: anim.modifier(requests,{rig=e,kind=command.modifier,weight=command.value,enabled=command.enabled,fade=.2},base.text_get(command.name[:]))
        case .Action: anim.play(requests,e,base.text_get(command.name[:]))
        case .Automatic: if command.enabled {anim.animation_command(requests,e,.Resume)}
        case .Playing: anim.animation_command(requests,e,.Resume if command.enabled else .Pause)
        case .Restart: anim.animation_command(requests,e,.Play)
        case .Seek: anim.animation_command(requests,e,.Seek,command.value)
        case .Rate:
            command_kind:=anim.Timeline_Command.Resume if anim.animation_playing(playback,e) else .Pause
            anim.animation_command(requests,e,command_kind,speed=command.value)
        case .Clip: anim.play_clip(requests,e,base.text_get(command.name[:]))
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
Gallery_Panel_Setup :: struct {
    station,camera:core.Entity,
    title:[64]u8 `mirai:"text"`,
}

@(component,derived)
Gallery_Panel :: struct {
    title:[64]u8 `mirai:"text"`,
    hint:[48]u8 `mirai:"text,hidden,readonly"`,
    rows:[GALLERY_PANEL_ROWS]Gallery_Panel_Row `mirai:"hidden,readonly"`,
    buttons:[GALLERY_PANEL_BUTTONS]Gallery_Panel_Button `mirai:"hidden,readonly"`,
    row_count,button_count:i32 `mirai:"hidden,readonly"`,
}

// A slider of a panel: the command it asks with the value between min and max.
Gallery_Control :: struct {label:string,command:Gallery_Command_Kind,min,max:f32,slot:u16,modifier:anim.Modifier_Kind,name:string}
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
        buttons[0],buttons[1]={label="Inertial wave",command=.Action,name="Wave"},automatic
        return rows,1,buttons,2
    case .Layered: rows[0]={label="Greeting",command=.Value,max=1}
    case .Sync: rows[0]={label="Jog blend",command=.Value,max=1}
    case .Additive: rows[0]={label="Wave",command=.Value,max=1}
    case .Actions:
        buttons[0],buttons[1],buttons[2]={label="Greet",command=.Action,name="Greet"},{label="Step",command=.Action,name="Step"},automatic
        return rows,0,buttons,3
    case .Warp:
        rows[0]={label="Goal / stride",command=.Value,min=.7,max=1.3}
        buttons[0],buttons[1]={label="Stride",command=.Warp},automatic
        return rows,1,buttons,2
    case .IK:
        rows[0],rows[1]={label="Target height",command=.Value,min=.9,max=1.8},{label="Target reach",command=.Value,min=.1,max=.8,slot=1}
        rows[2],rows[3]={label="Hand IK",command=.Modifier,max=1,modifier=.IK,name="RightHand"},{label="Look at",command=.Modifier,max=1,modifier=.Look,name="Head"}
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
@(step="fixed")
gallery_panel_input :: proc(panels:^core.Table(Gallery_Panel_Setup,.Read),gallery:^core.Table(Animation_Gallery,.Read),ui_events:core.Ref(gui.UI_Events),playback:core.Ref(anim.Playback),panel:^Gallery_UI) {
    for event in ui_events.items {
        value,found:=core.get(panels,event.entity)
        if !found || event.item<0 {continue}
        item,exists:=core.get(gallery,value.station)
        if !exists {continue}
        rows,row_count,buttons,button_count:=gallery_controls(item.kind)
        if event.kind==.Changed && event.name==base.name_hash("value") && int(event.item)<row_count {
            row:=rows[event.item]
            high:=row.max
            if row.command==.Seek {_,duration,_,valid:=anim.animation_progress(playback,value.station);if !valid {continue};high=duration}
            amount:=row.min+f32(clamp(event.value,0,1))*(high-row.min)
            gallery_request(panel,row.command,value.station,value=amount,slot=row.slot,name=row.name,modifier=row.modifier,enabled=amount>0 || row.command!=.Modifier)
        } else if event.kind==.Clicked && event.name==base.name_hash("button") && int(event.item)<button_count {
            button:=buttons[event.item]
            gallery_request(panel,button.command,value.station,name=button.name,enabled=button.command!=.Playing || !anim.animation_playing(playback,value.station))
        }
    }
}

// Fills each panel with the rows and buttons of its station and what the station does now.
@(step="fixed",stage="react")
gallery_panels :: proc(panels:^core.Table(Gallery_Panel_Setup,.Read),outputs:^core.Table(Gallery_Panel),gallery:^core.Table(Animation_Gallery,.Read),states:^core.Table(Animation_Gallery_State,.Read),playback:core.Ref(anim.Playback),modifiers:core.Ref(anim.Modifier_Runtime),problems:^core.Problems) {
    for row in 0..<core.count(panels) {
        current:=core.at(panels,row)
        item,exists:=core.get(gallery,current.station)
        if !exists {continue}
        progress,_:=anim.animation_progress_now(playback,current.station)
        rows,row_count,buttons,button_count:=gallery_controls(item.kind)
        state,ready:=core.view(states,current.station)
        empty:Animation_Gallery_State
        if !ready {state=core.ref(&empty)}
        next:Gallery_Panel
        next.title=current.title
        next.row_count,next.button_count=i32(row_count),i32(button_count)
        for control,i in rows[:row_count] {
            value,high:f32=0,control.max
            #partial switch control.command {
            case .Rate: value=progress.speed
            case .Seek: clock,duration,_,valid:=anim.animation_progress(playback,current.station);if valid {value,high=clock,duration}
            case .Speed: value=state.speed
            case .Value: value=state.values[control.slot]
            case .Modifier:
                value=1
                if _,_,_,target,_,enabled,found:=anim.modifier_influence(modifiers,current.station,control.modifier,base.name_hash(control.name));found {value=target if enabled else 0}
            }
            line:=&next.rows[i]
            base.text_set(line.label[:],control.label)
            line.readout={};fmt.bprintf(line.readout[:len(line.readout)-1],"%.2f",value)
            line.value=clamp((value-control.min)/(high-control.min),0,1) if high>control.min else 0
        }
        for button,i in buttons[:button_count] {base.text_set(next.buttons[i].label[:],button.label)}
        hint:="manual    E: back" if state.manual else "automatic    E: back"
        if item.kind==.Sequence {hint="playing    E: back" if progress.playing else "paused    E: back"}
        base.text_set(next.hint[:],hint)
        e:=core.entity_at(panels,row)
        if old,shown:=core.get(outputs,e);shown {
            if old!=next {core.edit(outputs,e)^=next}
        } else if !core.add(outputs,e,next) {
            core.report(problems,e,"demo.gallery","out of memory for what the panel of a gallery station shows")
        }
    }
}
