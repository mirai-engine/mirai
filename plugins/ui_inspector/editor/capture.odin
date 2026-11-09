package ui_inspector_editor

import "core:fmt"
import "mirai:core"
import "mirai:editor"
import "mirai:editor/api"
import "mirai:engine/gui"
import "mirai:host"
import gpu "mirai:render"
import "mirai:std/base"
import "mirai:std/serial"
import "mirai:ui"

// ui.capture: an interface alone, laid out at the size the game designs for
// as the stage builds it (samples of the game, prompts and language), in a
// context of its own drawn into a UI texture in a frame without the scene:
// what the camera of the viewport sees goes under it as an image, drawn only
// when the background is the scene.

Ui_Capture_Background :: enum u8 {Scene,Checker,Color}
Ui_Capture_Params :: struct {
    asset:base.Asset_Id,
    path:[editor.API_PATH_BYTES]u8 `mirai:"text,optional,label=PNG to write: absolute (C:/shots/a.png or /c/shots/a.png as Git Bash writes it) or relative to the folder of the project; its folder is made. Omitted: .mirai/captures/ui.png of the project"`,
    size:[2]f32 `mirai:"optional,min=0,max=8192,label=Layout units the game lays it out in; zeros: the reference of Project Settings > UI, or 1920 by 1080 without one. The image has that many pixels times the density of the editor"`,
    background:Ui_Capture_Background `mirai:"optional,label=Scene: what the camera of the viewport sees, as the game shows it over its world; Checker; or Color"`,
    color:ui.Color `mirai:"optional,label=Of background Color, in display values"`,
    node:[ui.TREE_NAME_CAPACITY]u8 `mirai:"text,optional,label=A node shown in states whatever the pointer does"`,
    states:ui.Style_States `mirai:"optional,label=Those node shows"`,
    variant:[ui.TREE_NAME_CAPACITY]u8 `mirai:"text,optional,label=The variant its nodes take when they choose none, as a screen chooses it"`,
    language:[24]u8 `mirai:"text,optional,label=Of its localized texts, as gui.Language names it; empty: the one they are written in"`,
    family:ui.Prompt_Family `mirai:"optional,label=The device its prompts show"`,
    seconds:f32 `mirai:"optional,min=0,max=10,unit=s,label=What its nodes play as they appear runs this long before the capture"`,
}

UI_CAPTURE_SIZE :: [2]f32{1920,1080} // without a reference of the project
@(private) UI_CAPTURE_DT :: f32(1)/60
@(private) UI_CAPTURE_CHECKER :: [2]ui.Color{{58,62,72,255},{44,47,56,255}}

@(private)
capture_api_register :: proc(s:^editor.Session) {
    defaults:=Ui_Capture_Params{seconds=1}
    editor.api_method_register(s,{name="ui.capture",summary="Draws a .ui alone at the size the game lays it out at, with samples of the data of the game, over the scene the viewport sees or a background, and writes it as a PNG, which MCP also returns as an image. Requires GPU.",params=Ui_Capture_Params,params_info=type_info_of(Ui_Capture_Params),result=editor.Api_Capture_Result,result_info=type_info_of(editor.Api_Capture_Result),writes_result=true,defaults=&defaults,flags={.Read_Only},run=api_ui_capture})
}

@(private)
api_ui_capture :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Ui_Capture_Params)
    app:=s.app
    a:=app.assets
    if app.renderer==nil || a==nil {api.call_fail(call,api.SERVER_ERROR,"ui.capture requires a GPU; start without --no-gpu");return}
    u:=core.world_storage_of(core.world_ref(s.editor_world,s.info,.Editor),Ui_Inspector)
    if u==nil {api.call_fail(call,api.SERVER_ERROR,"the ui_inspector plugin has no state in this editor");return}
    settings:=cast(^gui.UI_Settings)editor.setting_value(s,gui.UI_Settings)
    stage:=Stage{family=p.family}
    if name:=serial.text_field(p.language[:]);name!="" {
        for language in gui.Language {if fmt.tprintf("%v",language)==name {stage.language,stage.chosen=language,true}}
        if !stage.chosen {api.call_failf(call,api.INVALID_PARAMS,"language '%s' is none of the gui.Language names (English, Spanish, ...)",name);return}
    }
    file,writable:=editor.api_capture_file(s,call,serial.text_field(p.path[:]),"ui.png",app.allocator)
    if !writable {return}
    defer delete(file,app.allocator)
    api_flush(s)
    records:Records
    if !records_read(a,p.asset,&records,context.temp_allocator) {api.call_failf(call,api.INVALID_PARAMS,"asset %s is not a .ui that loads; pass the id of a .ui of the project (asset.list kind ui)",fmt.tprintf("%016x%016x",p.asset[0],p.asset[1]));return}
    data:=records_data(&records)
    imports,imported:=host.ui_tree_imports(a,data)
    if !imported {api.call_failf(call,api.INVALID_PARAMS,"the interface does not load: %s",widget_why(a,data));return}
    preview:Preview
    defer preview_free(&preview)
    if !preview_load(&preview,app,data,imports,app.allocator) {api.call_failf(call,api.INVALID_PARAMS,"the interface does not load: %s",load_why(a,data,imports));return}
    shown:i32
    if name:=serial.text_field(p.node[:]);name!="" {
        for &n,row in records.nodes {
            if serial.text_field(n.name[:])==name {shown=i32(preview_node_of(&preview,row))+1;break}
        }
        if shown<=0 {api.call_failf(call,api.INVALID_PARAMS,"node: the .ui has no node named '%s'; ui.inspect lists them",name);return}
    }
    size:=p.size
    if size.x<=0 || size.y<=0 {size=settings.reference if settings!=nil && settings.reference.x>0 && settings.reference.y>0 else UI_CAPTURE_SIZE}
    density:=app.density if app.density>0 else 1
    pixels:=[2]i32{i32(size.x*density+0.5),i32(size.y*density+0.5)}
    ctx:=host.app_ui_context_create(app)
    if ctx==nil {api.call_fail(call,api.SERVER_ERROR,"no UI context could be made: out of memory");return}
    defer host.app_ui_context_destroy(app,ctx)
    r:=app.renderer
    fill:=ui.Color{}
    image:ui.Quad
    scene_texture:gpu.Texture_Handle
    defer if scene_texture!=0 {gpu.texture_remove(r,scene_texture)}
    switch p.background {
    case .Checker: fill=UI_CAPTURE_CHECKER[1]
    case .Color:   fill=p.color
    case .Scene:
        // What the camera of the viewport sees, alone, under the interface as an image.
        scene,width,height,drawn:=host.app_capture_world(app,editor.shown_world(s).data,editor.API_CAPTURE_SETTLE,pixels,s.editor_world,app.allocator)
        if !drawn {api.call_failf(call,api.SERVER_ERROR,"the scene could not be drawn: %s",r.error);return}
        added:bool
        scene_texture,added=gpu.texture_add(r,{pixels=scene,width=width,height=height,srgb=true,name="ui capture scene"})
        delete(scene,app.allocator)
        if !added {api.call_failf(call,api.SERVER_ERROR,"the scene could not be shown under the interface: %s",r.error);return}
        image=ui.quad_whole(.Image,gpu.ui_image(r,scene_texture)&~gpu.UI_MATERIAL_IMAGE_BIT)
    }
    variant:=ui.style_variant(serial.text_field(p.variant[:]))
    // The first frame asks the font for its glyphs; the last one draws them.
    frames:=max(int(p.seconds/UI_CAPTURE_DT+0.5),2)
    frame:ui.Frame
    for _ in 0..<frames {
        ui.frame_begin(ctx,{size=size,scale=1,dt=UI_CAPTURE_DT,pointer_absent=true})
        ctx.game=preview_game(u,app,settings,&stage)
        surface:=ui.id(ctx,"surface")
        if ui.box(ctx,{id=surface,width=ui.fixed(size.x),height=ui.fixed(size.y),fill=fill,image=image}) {
            if p.background==.Checker {
                checker:=UI_CAPTURE_CHECKER
                ui.checker(ctx,ui.fixed(size.x),ui.fixed(size.y),checker[0],checker[1],12)
            }
            game:=ui.id(ctx,"game")
            if ui.box(ctx,{id=game,width=ui.fixed(size.x),height=ui.fixed(size.y),float={to=.Parent,anchor=.Top_Left,pivot=.Top_Left}}) {
                ui.tree_build(ctx,&preview.tree,&preview.instance,{passive=true,variant=variant,shown=shown,shown_states=p.states,area=game,area_rect={0,0,size.x,size.y}})
            }
        }
        frame=ui.frame_end(ctx)
        host.app_ui_font_sync(app,ctx)
    }
    draws:=make([]gpu.Ui_Draw,host.UI_COMMAND_CAPACITY,context.temp_allocator)
    layer,_,_,_:=host.ui_frame_convert(frame,draws,nil)
    texture,made:=gpu.ui_texture_add(r,u32(pixels.x),u32(pixels.y),"ui capture")
    if !made {api.call_failf(call,api.SERVER_ERROR,"the renderer took no texture of %dx%d: %s",pixels.x,pixels.y,r.error);return}
    defer gpu.ui_texture_remove(r,texture)
    captured,width,height,drawn:=host.app_ui_texture_capture(app,{texture=texture,layer=layer,size=size,clear={0,0,0,1}},app.allocator)
    if !drawn {api.call_failf(call,api.SERVER_ERROR,"the interface could not be drawn: %s",r.error);return}
    editor.api_capture_answer(s,call,file,captured,width,height)
}
