package editor

import "core:testing"
import "mirai:core"
import "mirai:editor/history"
import erender "mirai:engine/render"
import "mirai:host"
import "mirai:ui"

@(test)
geometry_selector_works_without_selection_and_preserves_materials :: proc(t:^testing.T) {
    ctx:ui.Context
    testing.expect(t,ui.context_init(&ctx,{}))
    defer ui.context_destroy(&ctx)
    g:=Editor_Ui{ctx=&ctx}
    app:host.App
    ins:Inspector
    selection:history.Selection
    session:=Session{app=&app,gui=&g,inspector=&ins,selection=&selection}
    field:=ui.Id(123)
    mesh:=erender.Mesh_Renderer{shape=.Cube,materials={0=1,1=2}}
    materials:=mesh.materials
    other:=erender.Mesh_Renderer{shape=.Cylinder}
    list_open(&session,{key=123,table=-1,geometry=true,field=field},{20,20,260,40})
    for _ in 0..<3 {
        ui.frame_begin(&ctx,{size={800,600},pointer_absent=true})
        list_build(&session,core.World_Ref{})
        ui.frame_end(&ctx)
    }
    row,found:=ui.widget_rect(&ctx,ui.id_derive(&ctx,list_popup(&g),"row",int(erender.Shape.Sphere)))
    testing.expect(t,found)
    if !found {return}
    for phase in 0..<3 {
        input:=ui.Input{size={800,600},pointer=ui.rect_center(row)}
        if phase==1 {input.down,input.pressed={.Left},{.Left}}
        if phase==2 {input.released={.Left}}
        ui.frame_begin(&ctx,input)
        list_build(&session,core.World_Ref{})
        ui.frame_end(&ctx)
    }
    testing.expect_value(t,ins.geometry_choice.field,field)
    ui.frame_begin(&ctx,{size={800,600},pointer_absent=true})
    testing.expect(t,!geometry_field(&session,456,&other))
    testing.expect(t,geometry_field(&session,field,&mesh))
    ui.frame_end(&ctx)
    testing.expect_value(t,mesh.shape,erender.Shape.Sphere)
    testing.expect_value(t,mesh.materials,materials)
    testing.expect_value(t,other.shape,erender.Shape.Cylinder)
    testing.expect_value(t,ins.geometry_choice.field,ui.Id(0))
    testing.expect_value(t,len(selection.entities),0)
}
