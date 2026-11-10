package terrain_editor

import "core:testing"
import "mirai:core"
import "mirai:editor"
import erender "mirai:engine/render"
import "mirai:host"
import gpu "mirai:render"
import "mirai:std/base"

@(private="file")
Terrain_View_Test_World :: struct {entities:core.Entities}

// The modes are declared in every frame and shown by their pass; the pipeline
// is asked for only while one of the modes of the pass is shown, and without
// one the mode shown says why and leaves the lit image. An overlay asks for
// no pipeline. A Play asks for nothing.
@(test)
terrain_view_modes_ask_for_their_pipeline_only_while_one_is_shown :: proc(t:^testing.T) {
    world:Terrain_View_Test_World
    info:=core.World_Info{entities=offset_of(Terrain_View_Test_World,entities)}
    modes:editor.View_Modes
    defer editor.view_modes_free(&modes)
    viewport:editor.Viewport
    document:editor.Document
    app:host.App
    s:=editor.Session{info=&info,edit_world=&world,app=&app,viewport=&viewport,document=&document,view_modes=&modes}
    view:Terrain_View

    terrain_view_modes(&s,&view,app.renderer)
    testing.expect_value(t,modes.count,len(Terrain_View_Mode)+len(Terrain_Overlay)-1)
    testing.expect_value(t,view.pipeline,erender.Pipeline(0))
    // Declared while Lit was shown: each can be chosen, and its pass draws it.
    base.text_set(viewport.view_mode[:],"SLOPE")
    editor.view_mode_render(&s,&viewport,&modes,&app)
    testing.expect(t,app.inspection.record==terrain_view_record && app.inspection.user==&view)

    // Shown without a renderer, there is no pipeline: the mode says so and the view stays lit.
    app.inspection={}
    editor.view_modes_begin(&modes)
    terrain_view_modes(&s,&view,app.renderer)
    testing.expect_value(t,view.mode,Terrain_View_Mode.Slope)
    editor.view_mode_render(&s,&viewport,&modes,&app)
    testing.expect_value(t,app.inspection,gpu.View_Inspection{})
    testing.expect_value(t,editor.view_mode_current(&viewport),"SLOPE")

    base.text_set(viewport.view_mode[:],"contours_height")
    s.mode=.Play
    editor.view_modes_begin(&modes)
    terrain_view_modes(&s,&view,app.renderer)
    testing.expect_value(t,view.mode,Terrain_View_Mode.Slope)
    s.mode=.Edit
    editor.view_modes_begin(&modes)
    terrain_view_modes(&s,&view,app.renderer)
    testing.expect_value(t,view.mode,Terrain_View_Mode.Contours_Height)
    base.text_set(viewport.view_mode[:],"layer_weights")
    editor.view_modes_begin(&modes)
    terrain_view_modes(&s,&view,app.renderer)
    testing.expect(t,view.overlay==.Layers && view.pipeline==0)
}
