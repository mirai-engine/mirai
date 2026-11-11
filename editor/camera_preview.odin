package editor

import "core:fmt"
import "core:mem"
import "mirai:core"
import "mirai:editor/history"
import ecamera "mirai:engine/camera"
import input "mirai:engine/input"
import erender "mirai:engine/render"
import "mirai:std/base"
import "mirai:ui"

// Previewing the cameras of the scene. It plays as Simulate, without the
// input of the players, and the view is drawn from a camera of the document
// that a bar picks, which comes in with the blend of its activation (or of
// the one it leaves): a camera that follows, one an action brings, one of a
// cinematic. Details edits the copy that plays. Keep writes into the document
// what its cameras became, as one step; Discard leaves them as they were.
Camera_Preview_Run :: struct {
    camera:core.Entity,         // the camera shown; none: not previewing
    blend:ecamera.Camera_Blend, // how the view came to it
    asked:core.Entity,          // the camera the focused seat was last asked to see through
}

CAMERA_PREVIEW_CAPACITY :: 12 // cameras the bar offers

camera_previewing :: proc "contextless" (s:^Session) -> bool {return s.camera_run.camera!=core.NONE && s.mode!=.Edit}

// The camera the selection previews: the selected entity, when it has a Camera.
camera_preview_target :: proc(s:^Session,w:core.World_Ref) -> core.Entity {
    if len(s.selection.entities)!=1 || !entity_has(w,s.selection.entities[0],erender.Camera) {return core.NONE}
    return s.selection.entities[0]
}

camera_preview_start :: proc(s:^Session,camera:core.Entity) -> bool {
    if s.mode!=.Edit || !entity_has(edited_world(s),camera,erender.Camera) || !play_start(s,true) {return false}
    tools_release(s)
    s.camera_run={camera=camera}
    history.selection_set(s.selection,{camera})
    return true
}

// Each frame: the focused seat of the copy sees through the camera shown, an
// override of its own.
camera_preview_frame :: proc(s:^Session) {
    if s.camera_run.camera==core.NONE {return}
    if s.mode==.Edit {
        s.camera_run={}
        return
    }
    if s.camera_run.asked==s.camera_run.camera {return}
    w:=shown_world(s)
    seats,state,requests:=core.world_table_of(w,input.Seat),core.world_storage_of(w,input.Seats),core.world_storage_of(w,ecamera.Camera_Requests)
    if seats==nil || state==nil || requests==nil {return}
    seat:=input.focused(state,core.read(seats))
    if seat==core.NONE {return}
    ecamera.camera_override(requests,seat,seat,s.camera_run.camera,blend=s.camera_run.blend)
    s.camera_run.asked=s.camera_run.camera
}

// Shows a camera: with the blend of its activation coming into it, or with
// that of the one it leaves going back.
@(private)
camera_preview_show :: proc(s:^Session,w:core.World_Ref,camera:core.Entity) {
    if camera==s.camera_run.camera {return}
    blend:=ecamera.CAMERA_BLEND
    if activation,ok:=entity_get(w,camera,ecamera.Camera_Activation);ok {
        blend=activation.blend
    } else if activation,ok=entity_get(w,s.camera_run.camera,ecamera.Camera_Activation);ok {blend=activation.blend}
    s.camera_run.camera,s.camera_run.blend=camera,blend
    history.selection_set(s.selection,{camera})
}

// The cameras of the document, whose changes Keep writes.
@(private)
camera_preview_cameras :: proc(s:^Session,w:core.World_Ref) -> (cameras:[CAMERA_PREVIEW_CAPACITY]core.Entity,count:int) {
    table:=core.world_table_of(w,erender.Camera)
    if table==nil {return}
    for row in 0..<core.count(table) {
        e:=core.entity_at(table,row)
        if id:=api_entity_id(w,e);id==0 || api_entity(edited_world(s),id)==core.NONE {continue}
        if count==len(cameras) {break}
        cameras[count]=e
        count+=1
    }
    return
}

// A camera of the document previews in play.
@(private)
camera_preview_button :: proc(c:^Inspect,camera:core.Entity) {
    s:=c.s
    if s.mode!=.Edit {return}
    ctx:=s.gui.ctx
    if ui.button(ctx,ui.id(ctx,"camera_preview"),{label="Preview",icon=.Play,variant="field",width=-1,height=ui.metric(ctx,"row"),size=ui.metric(ctx,"font_small"),center=true}).clicked {
        command_call(s,"camera.preview",fmt.tprintf(`{{"entity":"0x%016x"}}`,u64(camera)))
    }
}

// The cameras to switch between, at the bottom of the scene.
camera_preview_bar :: proc(s:^Session) {
    if !camera_previewing(s) {return}
    g:=s.gui
    ctx:=g.ctx
    w:=shown_world(s)
    cameras,count:=camera_preview_cameras(s,w)
    if ui.panel(ctx,shell_id(g,"camera_preview"),{row=true,width=ui.FIT,height=ui.FIT,padding=ui.padding_all(PANEL_PADDING),gap=4,align_y=.Center,anchor=.Bottom_Center,pivot=.Bottom_Center,offset={0,-ui.metric(ctx,"margin")}}) {
        for e,i in cameras[:count] {
            if ui.button(ctx,shell_id(g,"camera_preview_camera",i+1),{label=entity_name(w,e),variant="tab",active=e==s.camera_run.camera,height=ui.metric(ctx,"control"),size=ui.metric(ctx,"font_small"),padding=10}).clicked {camera_preview_show(s,w,e)}
        }
    }
}

// Ends previewing: Keep writes into the document the lens, the follow and the
// activation each of its cameras has in the copy, as one step.
camera_preview_end :: proc(s:^Session,keep:bool) {
    if !camera_previewing(s) {return}
    s.camera_run={}
    if !keep {
        play_stop(s,true)
        return
    }
    Kept :: struct {
        id:base.Entity_Id,
        lens:erender.Camera,
        follow:ecamera.Camera_Follow,
        activation:ecamera.Camera_Activation,
        follows,activated:bool,
    }
    w:=shown_world(s)
    edited:=edited_world(s)
    kept:=make([dynamic]Kept,context.temp_allocator)
    cameras,count:=camera_preview_cameras(s,w)
    for e in cameras[:count] {
        // One store per value until odin-lang/Odin#7937 (see ODIN_WORKAROUNDS).
        lens,_:=entity_get(w,e,erender.Camera)
        follow,follows:=entity_get(w,e,ecamera.Camera_Follow)
        activation,activated:=entity_get(w,e,ecamera.Camera_Activation)
        k:=Kept{id=api_entity_id(w,e),follows=follows,activated=activated}
        k.lens=lens
        k.follow=ecamera.camera_follow_config(follow)
        k.activation=activation
        append(&kept,k)
    }
    play_stop(s,true)
    if !history.edits_commit(s.edits,edited,s.selection) && s.edits.error!=.No_Change {return}
    opened,ready:=edit_open(s,"Preview cameras")
    if !ready {return}
    _,lens_info:=core.world_table(edited,erender.Camera)
    _,follow_info:=core.world_table(edited,ecamera.Camera_Follow)
    _,activation_info:=core.world_table(edited,ecamera.Camera_Activation)
    for &k in kept {
        e:=api_entity(edited,k.id)
        if lens,ok:=entity_get(edited,e,erender.Camera);ok && lens!=k.lens {field_write(s,lens_info,{e},0,mem.ptr_to_bytes(&k.lens))}
        if follow,ok:=entity_get(edited,e,ecamera.Camera_Follow);ok && k.follows && ecamera.camera_follow_config(follow)!=k.follow {
            field_write(s,follow_info,{e},0,mem.ptr_to_bytes(&k.follow))
        }
        if activation,ok:=entity_get(edited,e,ecamera.Camera_Activation);ok && k.activated && activation!=k.activation {
            field_write(s,activation_info,{e},0,mem.ptr_to_bytes(&k.activation))
        }
    }
    edit_close(s,opened)
    if !history.edits_commit(s.edits,edited,s.selection) && s.edits.error!=.No_Change {history.edits_cancel(s.edits,edited)}
}
