package portals_editor

import "mirai:editor"
import erender "mirai:engine/render"

// The mode of inspection "nested" of the viewport: what each nested view of
// the frame drew (portals_nested.comp), over the lit image of the view.

@(storage)
Portals_View_Mode :: struct {pipeline:erender.Pipeline} // of this frame

@(step="frame")
portals_view_mode :: proc(s:^editor.Session,mode:^Portals_View_Mode,renderer:^erender.Renderer) {
    mode.pipeline=erender.stage_pipeline(renderer,{stage=.Inspect,shader="portals_nested",name="nested views"})
    reason:=""
    if mode.pipeline==0 {reason="The shaders in use have no portals_nested.comp: generate those of the project"}
    editor.view_mode_declare(s,{name="nested",label="Nested views",group="Advanced",icon=.Split,reason=reason,record=portals_nested_record,user=mode})
}

@(private)
portals_nested_record :: proc(pass:^erender.Pass,user:rawptr) {
    mode:=cast(^Portals_View_Mode)user
    if mode.pipeline==0 {return}
    erender.pass_pipeline(pass,mode.pipeline)
    if !erender.pass_image_bind(pass,0) {return}
    erender.pass_dispatch(pass,(pass.width+7)/8,(pass.height+7)/8)
}
