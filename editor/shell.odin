package editor

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:path/filepath"
import "core:strings"
import "mirai:asset"
import "mirai:core"
import "mirai:editor/git"
import "mirai:editor/history"
import "mirai:host"
import "mirai:platform"
import gpu "mirai:render"
import "mirai:std/base"
import mm "mirai:std/math"
import "mirai:ui"


@(private) SHELL_SCOPE :: ui.Id(0x4d495241)
@(private) BAR_BUTTON_HEIGHT :: f32(30)
@(private) DOCUMENT_TOOLBAR_HEIGHT :: f32(44) // nominal: bars_snap puts its edges on whole pixels
@(private) BAR_MARK_HEIGHT :: f32(34) // of the menu with the mark
@(private) TOOLBAR_BUTTON :: f32(28) // side of a button of the toolbar
@(private) RAIL_WIDTH :: f32(44)
@(private) RAIL_BUTTON :: f32(32)
@(private) LEFT_UNDER :: f32(16) // of the left panel, what the scene runs under: its rounded corners show the scene
@(private) LEFT_RADIUS :: f32(12)
@(private) DETAILS_MARGIN :: f32(8)
@(private) PANEL_HEADER :: f32(24) // the row of a tab of the left panel that has controls
@(private) WINDOW_CONTROL_WIDTH :: f32(28)
@(private) PANEL_PADDING :: f32(8)
@(private) SPLITTER_WIDTH :: f32(6)
@(private) NAMED_CAPACITY :: 96

Panel_Width :: struct {fraction,min,max:f32}
LEFT_WIDTH :: Panel_Width{0,320,320}
RIGHT_WIDTH :: Panel_Width{0,312,312}
BOTTOM_HEIGHT :: f32(220)
BOTTOM_MIN :: f32(120)

Library_Tab :: enum u8 {Editor,Content,Ai,Hierarchy,Git,World}
Library_Tabs :: bit_set[Library_Tab]

// The tabs of the left panel each type of document has: what can be shown
// beside it. An asset document has Hierarchy too when its plugin builds one.
DOCUMENT_LIBRARY_TABS :: [Document_Type]Library_Tabs{
    .Scene={.Editor,.Content,.Hierarchy,.World,.Ai,.Git},
    .Prefab={.Editor,.Content,.Hierarchy,.Ai,.Git},
    .Asset={.Content,.Ai,.Git},
}
Bottom_Tab :: enum u8 {Console,Build}
Modal :: enum u8 {None,Confirm,Save_Changes,Recovery,Shortcuts,Settings,Delete_Asset,Git_Discard}

// Whether the world of a document uses unsaved assets, as last asked
// (document_uses_unsaved): key is the revision of the registry and the state
// of its history then.
Unsaved_Use :: struct {
    world:rawptr,
    key:[2]u64,
    uses:bool,
}

// The dot of unsaved changes.
UNSAVED_COLOR :: ui.Color{201,181,239,255}
Splitter :: enum u8 {None,Bottom,Right}

// How the right panel sits: over the scene, or docked to the edge of the window
// for its whole height, with the scene beside it, smaller.
Panel_Mode :: enum u8 {Floating,Docked}
// The mode of the right panel for a type of document: that of every document, or its own.
Panel_Choice :: enum u8 {Global,Floating,Docked}
Document_Type :: enum u8 {Scene,Prefab,Asset}

// A bottom height of 0 uses the default, and so does a docked width of 0.
Layout :: struct {
    left_open,right_open,bottom_open:bool,
    library_tab,previous_library_tab:Library_Tab,
    create_folded:[CARD_GROUP_CAPACITY]bool,
    run_kind:Run_Kind,  // what the Play button starts
    bottom_tab:Bottom_Tab,
    bottom_height:f32,
    git_history:f32, // the height of the history of the Git tab; 0: GIT_HISTORY_DEFAULT
    right_mode:Panel_Mode,
    right_modes:[Document_Type]Panel_Choice,
    right_width:f32, // docked, as its edge was dragged
}

LAYOUT_DEFAULT :: Layout{left_open=true,right_open=true,library_tab=.Content,previous_library_tab=.Content}
DOCK_MIN :: f32(220) // the narrowest a docked panel is dragged

Run_Kind :: enum u8 {Play,Simulate,Play_From_Camera}

// The entry each one runs.
@(rodata)
RUN_COMMANDS := [Run_Kind]string{.Play="play",.Simulate="simulate",.Play_From_Camera="play_from_camera"}

// Rectangles of the last frame, in window points; no size: not shown.
Shell_Rects :: struct {bar,left,right,bottom:ui.Rect}

Drag_Kind :: enum u8 {None,Preset,Asset,Entity}

// Something carried from a panel: to the scene, to a row of the outliner, to a field.
Drag :: struct {
    kind:Drag_Kind,
    card:int,          // Preset: its place in cards()
    icon:ui.Icon,
    color:ui.Color,
    asset_id:base.Asset_Id,
    asset_kind:asset.Fourcc,
    part:[64]u8,       // Asset: the clip of a library it carries; empty: the whole asset
    entity:core.Entity,
    press:[2]f32,
    moved:bool,    // it travelled: a drag, not a click
    released:bool, // the button came up this frame: whatever is under the pointer takes it
    label:[64]u8,
    label_length:int,
}

Placement :: struct {active:bool,using subject:Drag}

@(private)
Named :: struct {id:ui.Id,kind:platform.Window_Region_Kind,clip:ui.Id}


// The UI of the editor. A plugin builds into ctx from the ui phase, between
// editor_panels and editor_end.
@(storage,free="gui_destroy")
Editor_Ui :: struct {
    ctx:^ui.Context,
    draws:[dynamic]gpu.Ui_Draw,
    panels:[dynamic]gpu.World_Panel,
    begun:bool,     // the frame of ctx is open
    dropped:u64,    // UI commands that did not fit
    layout:Layout,
    rects:Shell_Rects,
    modal:Modal,
    modal_scroll:f32,
    toolbar_height:f32, // of the toolbar under the document bar, its bottom on a whole pixel (bars_snap)
    pending:Pending,
    save_then:bool, // a Save As asked by the question about unsaved changes goes on with what waits
    confirm_assets:[dynamic]string, // the unsaved assets the question lists, by their path in the registry
    delete_asset:base.Asset_Id,     // what Modal.Delete_Asset asks about
    discard_path:[git.PATH_BYTES]u8, // what Modal.Git_Discard asks about; empty: every change
    unsaved_uses:[dynamic]Unsaved_Use,
    drag:Drag,
    placement:Placement,
    preview:Placement_Preview,
    splitter:Splitter,
    splitter_start:f32,
    splitter_press:[2]f32,
    cursor:platform.Cursor,
    cursor_set:platform.Cursor,
    named:[NAMED_CAPACITY]Named,
    named_count:int,
    variant:Variant_Prompt,
    title:[256]u8,
    title_length:int,
    create_scroll:[2]f32,
    drawings:[DRAWING_CAPACITY]Drawing, // of the frame being built
    drawing_count:int,
    tool_top,tool_width:f32,          // where the panel of a tool goes, in place of Details
    tool_dock:f32,                    // its height when the right panel is docked; 0: floating
    documents_scroll:f32,
    documents_width:f32,
    documents_reveal:bool,
    presence_menu:Presence_Menu, // the figure whose menu is open (presence_menu.odin)
    viewport_menu:Viewport_Menu, // of the right click on the scene (play_here.odin)
}

// The names draw_user draws: an icon from ui.Icon.User on, or a canvas.
User_Icon :: enum u8 {
    Minimize,Maximize,Close,Pause,Gear,Search,Folder,Up,List,Save,Undo,Redo,Share,Camera,Graphics,Component,Simulate,
    Scene,Copy,Trash,Hammer,Terminal,Tree,Command,Unlink,Variant,
    Agent_Star,Agent_Bolt,Agent_Ghost,Agent_Shield,Agent_Leaf,Agent_Butterfly,Agent_Claude,Agent_Codex,
    Agent_Star_Done,Agent_Bolt_Done,Agent_Ghost_Done,Agent_Shield_Done,Agent_Leaf_Done,Agent_Butterfly_Done,Agent_Claude_Done,Agent_Codex_Done,
    Agent_Star_Ask,Agent_Bolt_Ask,Agent_Ghost_Ask,Agent_Shield_Ask,Agent_Leaf_Ask,Agent_Butterfly_Ask,Agent_Claude_Ask,Agent_Codex_Ask,
    Retry,Connection,Waiting,
    Star,Star_Filled,Collapse,Users,
    Expand, // two chevrons apart: open everything, as Collapse closes it
    Panel_Close,Panel_Open, // a panel on the left with an arrow that folds it, or that brings it back
    Branch,        // three commits of git and the branch between them
    Back,          // a chevron to the left: the previous one
    Down,          // an arrow down, as Up
    Arrow_Left,Arrow_Right,Arrow_Up_Left,Arrow_Up_Right,Arrow_Down_Right,Arrow_Down_Left, // the sides and corners of a box
    Shield,        // what an agent asks leave for
    Drawing,       // data: the ^Drawing of a plugin
    Mirai,         // the mark, its arms in the color given and its star white
    To_Start,Step_Back,Step_Forward,To_End,Loop,Range,Fit_Width,Marker, // of the time strip (timeline.odin)
    Wordmark,      // the name MIRAI in the text of the theme, at the left of its area
    Terrain,       // two peaks: a terrain and its tool
    Plugin,        // three blocks and a fourth set apart: a plugin without an icon of its own
    Mirai_Shape,   // the mark in one color, the one given
    Puzzle,        // a piece with knobs on top and at its right and notches at the other two sides
    Corners_Out,   // four corners pointing out: take the whole window
    Corners_In,    // and in: back to the panel
    Dashed_Box,    // the outline of its area as dashes; data: its color
    Annotate,      // a map pin
    Pin,Pin_Filled, // a thumbtack: what keeps a chip of the composer, and the same when it keeps one
}

DRAWING_CAPACITY :: 8 // areas plugins draw in one frame

// What a plugin draws in an area of its panel, called while the frame is painted.
Drawing_Proc :: proc(ctx:^ui.Context,rect:ui.Rect,user:rawptr)
Drawing :: struct {
    draw:Drawing_Proc,
    user:rawptr, // must live until the frame is painted: a field of the plugin's storage
}

@(private)
gui_init :: proc(g:^Editor_Ui,app:^host.App) -> bool {
    ctx,error:=new(ui.Context,app.allocator)
    if error!=nil {return false}
    desc:=host.app_ui_context_desc(app)
    desc.draw_user=draw_user
    if !ui.context_init(ctx,desc) {
        free(ctx,app.allocator)
        return false
    }
    g.ctx=ctx
    g.preview.parts=make([dynamic]Placement_Part,app.allocator)
    resize(&g.draws,host.UI_COMMAND_CAPACITY)
    resize(&g.panels,16)
    g.layout=LAYOUT_DEFAULT
    if app.platform!=nil && platform.window_native(app.platform)!=nil {
        _=platform.window_set_icon(app.platform,mark_icon_pixels(context.temp_allocator),MARK_ICON_SIZE,MARK_ICON_SIZE)
    }
    return true
}

// The panels hold views of the frame, which only the arrays own.
gui_destroy :: proc(g:^Editor_Ui) {
    if g.ctx!=nil {
        allocator:=g.ctx.allocator
        ui.context_destroy(g.ctx)
        free(g.ctx,allocator)
        g.ctx=nil
    }
    delete(g.draws);delete(g.panels)
    delete(g.preview.parts)
    g.preview={}
    g.draws,g.panels={},{}
    confirm_assets_set(g,nil)
    core.value_free(g,type_info_of(Editor_Ui))
}

// The id of a widget of the shell, whatever scope is open.
shell_id :: proc(g:^Editor_Ui,name:string,index:int=0) -> ui.Id {return ui.id_derive(g.ctx,SHELL_SCOPE,name,index)}

// An area of a plugin's panel that draw paints with the ui.draw_ procedures,
// in the rectangle the layout gives it and under the clip of its container.
// The pointer on it is its interaction. Past DRAWING_CAPACITY in a frame the
// area stays empty.
drawing :: proc(g:^Editor_Ui,id:ui.Id,width,height:ui.Size,draw:Drawing_Proc,user:rawptr,flags:ui.Widget_Flags={}) -> ui.Interaction {
    data:[]u8
    if g.drawing_count<len(g.drawings) {
        g.drawings[g.drawing_count]={draw,user}
        data=([^]u8)(&g.drawings[g.drawing_count])[:size_of(Drawing)]
        g.drawing_count+=1
    } else {
        g.dropped+=1
    }
    return ui.canvas(g.ctx,id,width,height,{name=u64(User_Icon.Drawing),data=data},flags)
}

// The layout of the panel of the active tool of a plugin, or of the shown
// panel of the project: the place of Details, which they take while shown.
tool_panel :: proc(g:^Editor_Ui,id:ui.Id) -> ui.Panel_Float {
    ctx:=g.ctx
    if rect,found:=ui.widget_rect(ctx,id);found {g.rects.right=rect}
    if g.tool_dock>0 {return {width=ui.fixed(g.tool_width),height=ui.fixed(g.tool_dock),padding=ui.padding_all(PANEL_PADDING),gap=8,anchor=.Top_Right,pivot=.Top_Right,offset={0,g.tool_top},docked=true}}
    radius:=ctx.theme.radius_panel
    return {width=ui.fixed(g.tool_width),height=ui.FIT,padding=ui.padding_all(PANEL_PADDING),gap=8,anchor=.Top_Right,pivot=.Top_Right,offset={-DETAILS_MARGIN,g.tool_top},docked=true,corners={radius,radius,radius,radius}}
}

// The width of what the panel of tool_panel holds, inside its padding.
tool_panel_inner :: proc(g:^Editor_Ui) -> f32 {return g.tool_width-2*PANEL_PADDING}

// True while a tool of a plugin or a panel of the project takes the place of
// Details.
tool_panel_shown :: proc(s:^Session) -> bool {
    if playing(s) || scene_covered(s) || tool_on(s,AI_ANNOTATE_TOOL) {return false}
    return s.viewport.plugin_tool!=0 || panel_shown(s.panels)!=nil
}

@(private)
named_add :: proc(g:^Editor_Ui,id:ui.Id,kind:=platform.Window_Region_Kind.Client,clip:ui.Id=0) {
    if g.named_count>=len(g.named) {return}
    g.named[g.named_count]={id,kind,clip}
    g.named_count+=1
}

@(private)
draw_user :: proc(user:rawptr,ctx:^ui.Context,node:ui.Draw_Node) {
    if node.name>=u64(len(User_Icon)) {return}
    rect,kind,color:=node.rect,u32(node.name),node.fill
    c:=ui.rect_center(rect)
    s:=min(rect.w,rect.h)/16
    switch User_Icon(kind) {
    case .Agent_Star,.Agent_Bolt,.Agent_Ghost,.Agent_Shield,.Agent_Leaf,.Agent_Butterfly,.Agent_Claude,.Agent_Codex,
         .Agent_Star_Done,.Agent_Bolt_Done,.Agent_Ghost_Done,.Agent_Shield_Done,.Agent_Leaf_Done,.Agent_Butterfly_Done,.Agent_Claude_Done,.Agent_Codex_Done,
         .Agent_Star_Ask,.Agent_Bolt_Ask,.Agent_Ghost_Ask,.Agent_Shield_Ask,.Agent_Leaf_Ask,.Agent_Butterfly_Ask,.Agent_Claude_Ask,.Agent_Codex_Ask:
        ai_agent_avatar_draw(ctx,rect,u8(kind-u32(User_Icon.Agent_Star)),color)
    case .Drawing:
        if d,ok:=ui.draw_value(node,Drawing);ok && d.draw!=nil {d.draw(ctx,rect,d.user)}
    case .To_Start,.Step_Back,.Step_Forward,.To_End,.Loop,.Range,.Fit_Width,.Marker:
        timeline_icon_draw(ctx,User_Icon(kind),c,s,color)
    case .Mirai:
        mark_shape_draw(ctx,c,s,color,MARK_STAR)
    case .Wordmark:
        wordmark_draw(ctx,rect,ctx.theme.text)
    case .Mirai_Shape:
        mark_shape_draw(ctx,c,s,color,color)
    case .Retry:
        points:[17][2]f32
        for &point,i in points {
            angle:=f32(i)*math.PI/10
            point=c+[2]f32{math.cos(angle),math.sin(angle)}*5*s
        }
        ui.draw_polyline(ctx,points[:],1.3*s,color)
        ui.draw_polyline(ctx,([][2]f32{c+{2*s,-5*s},c+{6*s,-5*s},c+{6*s,-9*s}}),1.3*s,color)
    case .Corners_Out,.Corners_In:
        out:=User_Icon(kind)==.Corners_Out
        far,near:=f32(5.5),f32(2)
        for corner in ([4][2]f32{{-1,-1},{1,-1},{1,1},{-1,1}}) {
            tip:=out?far:near
            away:=out?near:far
            bend:=[3][2]f32{c+{corner.x*away,corner.y*tip}*s,c+{corner.x*tip,corner.y*tip}*s,c+{corner.x*tip,corner.y*away}*s}
            ui.draw_polyline(ctx,bend[:],1.4*s,color)
        }
    case .Dashed_Box:
        ai_dashed_box_draw(ctx,rect,color)
    case .Close:
        ui.draw_line(ctx,c+{-3.5,-3.5},c+{3.5,3.5},1.2,color)
        ui.draw_line(ctx,c+{3.5,-3.5},c+{-3.5,3.5},1.2,color)
    case .Minimize:
        ui.draw_line(ctx,c+{-4,0},c+{4,0},1.2,color)
    case .Maximize:
        ui.draw_rect_lines(ctx,{c.x-4,c.y-4,8,8},1.2,color)
    case .Pause:
        ui.draw_rounded(ctx,{c.x-4.5*s,c.y-5.5*s,3*s,11*s},0.8*s,color)
        ui.draw_rounded(ctx,{c.x+1.5*s,c.y-5.5*s,3*s,11*s},0.8*s,color)
    case .Simulate:
        a,b:=c+{-2.5*s,2.5*s},c+{2.5*s,-2.5*s}
        for p in ([2][2]f32{a,b}) {ui.draw_rounded_stroke(ctx,{p.x-3.5*s,p.y-3.5*s,7*s,7*s},3.5*s,1.4*s,color)}
        ui.draw_line(ctx,a,b,1.4*s,color)
    case .Search:
        ui.draw_ring(ctx,c+{-1.5*s,-1.5*s},4.5*s,1.4,color)
        ui.draw_line(ctx,c+{2*s,2*s},c+{6*s,6*s},1.4,color)
    case .Camera:
        ui.draw_rect_lines(ctx,{c.x-6*s,c.y-4*s,8*s,8*s},1.3,color)
        p:=[4][2]f32{c+{2*s,-2*s},c+{6*s,-4*s},c+{6*s,4*s},c+{2*s,2*s}}
        ui.draw_polyline(ctx,p[:],1.3,color,true)
    case .Graphics:
        for x,index in ([3]f32{-5,0,5}) {
            y:=index==1?f32(3):f32(-2)
            ui.draw_line(ctx,c+{x*s,-6*s},c+{x*s,(y-1.5)*s},1.3,color)
            ui.draw_line(ctx,c+{x*s,(y+1.5)*s},c+{x*s,6*s},1.3,color)
            ui.draw_rect_lines(ctx,{c.x+(x-1.5)*s,c.y+(y-1.5)*s,3*s,3*s},1.1,color)
        }
    case .Puzzle:
        // On a 24 unit grid, as wide as the other tabs and centered nearer its body, where its weight is:
        // x, y and radius of each arc with its angles from and to, clockwise. Straight sides join them.
        arcs:=[16][5]f32{{7,6,1,90,0},{10,5,2,180,360},{13,6,1,180,90},{16,8,1,270,360},{18,11,1,180,90},{19,14,2,-90,90},{18,17,1,270,180},{16,20,1,0,90},{13,20,1,90,180},{10,19,2,0,-180},{7,20,1,0,90},{4,20,1,90,180},{4,17,1,180,270},{5,14,2,90,-90},{4,11,1,90,180},{4,8,1,180,270}}
        points:[84][2]f32
        n:=0
        for arc in arcs {
            steps:=arc[2]>1?8:3
            for i in 0..=steps {
                a:=(arc[3]+(arc[4]-arc[3])*f32(i)/f32(steps))*math.PI/180
                points[n]=c+([2]f32{arc[0]-11.25+arc[2]*math.cos(a),arc[1]-12.75+arc[2]*math.sin(a)})*0.78*s;n+=1
            }
        }
        ui.draw_outline(ctx,points[:],1.3*s,color)
    case .Component:
        ui.draw_polyline(ctx,([][2]f32{c+{-3*s,-4*s},c+{-7*s,0},c+{-3*s,4*s}}),1.3,color)
        ui.draw_polyline(ctx,([][2]f32{c+{3*s,-4*s},c+{7*s,0},c+{3*s,4*s}}),1.3,color)
        ui.draw_line(ctx,c+{1.5*s,-6*s},c+{-1.5*s,6*s},1.3,color)
    case .Gear:
        ui.draw_ring(ctx,c,4.5*s,1.4,color)
        ui.draw_ring(ctx,c,1.5*s,1.2,color)
        for i in 0..<8 {
            a:=f32(i)*math.PI/4
            d:=[2]f32{math.cos(a),math.sin(a)}
            ui.draw_line(ctx,c+d*4.5*s,c+d*6.5*s,2,color)
        }
    case .Connection:
        ui.draw_rounded_stroke(ctx,{c.x-7*s,c.y-s,8*s,5*s},2*s,1.3,color)
        ui.draw_rounded_stroke(ctx,{c.x-s,c.y-4*s,8*s,5*s},2*s,1.3,color)
        ui.draw_line(ctx,c+{-2*s,2*s},c+{2*s,-2*s},1.3,color)
    case .Shield:
        points:=[10][2]f32{c+{0,-6.2*s},c+{5*s,-4.2*s},c+{5*s,-.2*s},c+{4*s,2.8*s},c+{2*s,4.8*s},c+{0,6.2*s},c+{-2*s,4.8*s},c+{-4*s,2.8*s},c+{-5*s,-.2*s},c+{-5*s,-4.2*s}}
        ui.draw_polyline(ctx,points[:],1.3,color,true)
    case .Waiting:
        for y in ([2]f32{-6,6}) {ui.draw_line(ctx,c+{-5*s,y*s},c+{5*s,y*s},1.3,color)}
        ui.draw_polyline(ctx,([][2]f32{c+{-4*s,-6*s},c+{-4*s,-3*s},c+{4*s,3*s},c+{4*s,6*s}}),1.3,color)
        ui.draw_polyline(ctx,([][2]f32{c+{4*s,-6*s},c+{4*s,-3*s},c+{-4*s,3*s},c+{-4*s,6*s}}),1.3,color)
    case .Star,.Star_Filled:
        // Five points, and the five between them at 0.45 of their reach.
        points:[10][2]f32
        for &point,i in points {
            angle:=f32(i)*math.PI/5-math.PI/2
            reach:=6.5*s if i%2==0 else 2.9*s
            point=c+[2]f32{math.cos(angle),math.sin(angle)+0.08}*reach
        }
        if User_Icon(kind)==.Star_Filled {
            for i in 0..<10 {ui.draw_triangle(ctx,c+{0,0.5*s},points[i],points[(i+1)%10],color)}
        } else {ui.draw_polyline(ctx,points[:],1.2*s,color,true)}
    case .Collapse:
        ui.draw_polyline(ctx,([][2]f32{c+{-4*s,-7*s},c+{0,-3*s},c+{4*s,-7*s}}),1.3*s,color)
        ui.draw_polyline(ctx,([][2]f32{c+{-4*s,7*s},c+{0,3*s},c+{4*s,7*s}}),1.3*s,color)
        ui.draw_line(ctx,c+{-6*s,0},c+{6*s,0},1.3*s,color)
    case .Expand:
        ui.draw_polyline(ctx,([][2]f32{c+{-4*s,-3*s},c+{0,-7*s},c+{4*s,-3*s}}),1.3*s,color)
        ui.draw_polyline(ctx,([][2]f32{c+{-4*s,3*s},c+{0,7*s},c+{4*s,3*s}}),1.3*s,color)
        ui.draw_line(ctx,c+{-6*s,0},c+{6*s,0},1.3*s,color)
    case .Panel_Close,.Panel_Open:
        ui.draw_rounded_stroke(ctx,{c.x-7*s,c.y-7*s,14*s,14*s},3*s,1.4*s,color)
        ui.draw_line(ctx,c+{-2.5*s,-7*s},c+{-2.5*s,7*s},1.4*s,color)
        tip:=f32(0.5 if User_Icon(kind)==.Panel_Close else 3.5)
        back:=f32(3.5 if User_Icon(kind)==.Panel_Close else 0.5)
        ui.draw_polyline(ctx,([][2]f32{c+{back*s,-2.5*s},c+{tip*s,0},c+{back*s,2.5*s}}),1.4*s,color)
    case .Folder:
        ui.draw_triangle(ctx,c+{-6.5*s,-4.5*s},c+{-2*s,-4.5*s},c+{-0.5*s,-3*s},color)
        ui.draw_triangle(ctx,c+{-6.5*s,-4.5*s},c+{-0.5*s,-3*s},c+{-6.5*s,-3*s},color)
        ui.draw_rect(ctx,{c.x-6.5*s,c.y-3*s,13*s,8*s},color)
    case .Up:
        ui.draw_line(ctx,c+{0,6*s},c+{0,-6*s},1.5,color)
        ui.draw_line(ctx,c+{-4.5*s,-1.5*s},c+{0,-6*s},1.5,color)
        ui.draw_line(ctx,c+{4.5*s,-1.5*s},c+{0,-6*s},1.5,color)
    case .List:
        for y in ([3]f32{-5,0,5}) {
            ui.draw_circle(ctx,c+{-6*s,y*s},s,color)
            ui.draw_line(ctx,c+{-2*s,y*s},c+{7*s,y*s},1.4,color)
        }
    case .Save:
        p:=[5][2]f32{c+{-6*s,-6*s},c+{3*s,-6*s},c+{6*s,-3*s},c+{6*s,6*s},c+{-6*s,6*s}}
        ui.draw_polyline(ctx,p[:],1.3,color,true)
        ui.draw_rect_lines(ctx,{c.x-3*s,c.y-6*s,5*s,4*s},1.2,color)
        ui.draw_rect_lines(ctx,{c.x-3*s,c.y+s,6*s,5*s},1.2,color)
    case .Undo,.Redo:
        sign:=User_Icon(kind)==.Redo?f32(-1):f32(1)
        p:=[4][2]f32{c+{-6*s*sign,-2*s},c+{2*s*sign,-2*s},c+{5*s*sign,s},c+{5*s*sign,5*s}}
        ui.draw_polyline(ctx,p[:],1.5,color)
        ui.draw_line(ctx,p[0],c+{-2*s*sign,-6*s},1.5,color)
        ui.draw_line(ctx,p[0],c+{-2*s*sign,2*s},1.5,color)
    // Icons drawn on a 24 unit grid, at two thirds.
    case .Scene:
        for y in ([2]f32{-2,2}) {ui.draw_line(ctx,c+{-5.33*s,y*s},c+{5.33*s,y*s},1.3*s,color)}
        ui.draw_line(ctx,c+{-1.33*s,-6*s},c+{-2.67*s,6*s},1.3*s,color)
        ui.draw_line(ctx,c+{2.67*s,-6*s},c+{1.33*s,6*s},1.3*s,color)
    case .Copy:
        ui.draw_rounded_stroke(ctx,{c.x-2*s,c.y-2*s,8.67*s,8.67*s},1.33*s,1.3*s,color)
        back:=[8][2]f32{{-4.67,2},{-5.33,2},{-6.67,0.67},{-6.67,-5.33},{-5.33,-6.67},{0.67,-6.67},{2,-5.33},{2,-4.67}}
        for &p in back {p=c+p*s}
        ui.draw_polyline(ctx,back[:],1.3*s,color)
    case .Trash:
        ui.draw_line(ctx,c+{-6*s,-4*s},c+{6*s,-4*s},1.3*s,color)
        can:=[6][2]f32{{4.67,-4},{4,5.33},{2.67,6.67},{-2.67,6.67},{-4,5.33},{-4.67,-4}}
        lid:=[6][2]f32{{-2,-4},{-2,-5.33},{-1.33,-6},{1.33,-6},{2,-5.33},{2,-4}}
        for &p in can {p=c+p*s}
        for &p in lid {p=c+p*s}
        ui.draw_polyline(ctx,can[:],1.3*s,color)
        ui.draw_polyline(ctx,lid[:],1.3*s,color)
        for x in ([2]f32{-1.33,1.33}) {ui.draw_line(ctx,c+{x*s,-0.67*s},c+{x*s,3.33*s},1.3*s,color)}
    case .Hammer:
        d,p:=[2]f32{0.7071,-0.7071},[2]f32{0.7071,0.7071}
        ui.draw_line(ctx,c+{-5.5*s,5.5*s},c+{1*s,-1*s},1.6*s,color)
        head:=c+{2.5*s,-2.5*s}
        ui.draw_quad_colors(ctx,{head+(-p*4.5-d*1.8)*s,head+(p*4.5-d*1.8)*s,head+(p*4.5+d*1.8)*s,head+(-p*4.5+d*1.8)*s},{color,color,color,color})
    case .Plugin:
        for corner in ([4][2]f32{{-6,1.5},{-0.5,1.5},{-6,-4},{1.5,-6}}) {ui.draw_rounded_stroke(ctx,{c.x+corner.x*s,c.y+corner.y*s,4.5*s,4.5*s},1*s,1.2*s,color)}
    case .Terrain:
        peaks:=[5][2]f32{{-6.67,6},{-2.67,-6},{0,-0.67},{3.33,-4},{6.67,6}}
        for &p in peaks {p=c+p*s}
        ui.draw_polyline(ctx,peaks[:],1.3*s,color,true)
    case .Terminal:
        prompt:=[3][2]f32{c+{-5.33*s,3.33*s},c+{-1.33*s,-0.67*s},c+{-5.33*s,-4.67*s}}
        ui.draw_polyline(ctx,prompt[:],1.3*s,color)
        ui.draw_line(ctx,c+{0,4.67*s},c+{5.33*s,4.67*s},1.3*s,color)
    case .Tree:
        for box in ([3][2]f32{{-2,-6.67},{-6.67,2.67},{2.67,2.67}}) {ui.draw_rounded_stroke(ctx,{c.x+box.x*s,c.y+box.y*s,4*s,4*s},0.67*s,1.3*s,color)}
        branch:=[6][2]f32{{-4.67,2.67},{-4.67,0.67},{-4,0},{4,0},{4.67,0.67},{4.67,2.67}}
        for &p in branch {p=c+p*s}
        ui.draw_polyline(ctx,branch[:],1.3*s,color)
        ui.draw_line(ctx,c,c+{0,-2.67*s},1.3*s,color)
    case .Down:
        ui.draw_line(ctx,c+{0,-6*s},c+{0,6*s},1.5,color)
        ui.draw_line(ctx,c+{-4.5*s,1.5*s},c+{0,6*s},1.5,color)
        ui.draw_line(ctx,c+{4.5*s,1.5*s},c+{0,6*s},1.5,color)
    case .Arrow_Left,.Arrow_Right,.Arrow_Up_Left,.Arrow_Up_Right,.Arrow_Down_Right,.Arrow_Down_Left:
        // Toward its side or corner, with a head of two strokes at 45 degrees.
        DIRECTIONS :: [6][2]f32{{-1,0},{1,0},{-0.7071,-0.7071},{0.7071,-0.7071},{0.7071,0.7071},{-0.7071,0.7071}}
        directions:=DIRECTIONS
        d:=directions[int(User_Icon(kind))-int(User_Icon.Arrow_Left)]
        tip:=c+d*6*s
        ui.draw_line(ctx,c-d*6*s,tip,1.5,color)
        for side in ([2]f32{1,-1}) {
            back:=[2]f32{-d.x*0.7071-side*d.y*0.7071,-d.y*0.7071+side*d.x*0.7071}
            ui.draw_line(ctx,tip,tip+back*4.5*s,1.5,color)
        }
    case .Annotate:
        head:=c+[2]f32{0,-1.5}*s
        outline:[11][2]f32
        for &point,i in outline {
            angle:=f32(i)*math.PI*4/3/10-math.PI*7/6
            point=head+[2]f32{math.cos(angle),math.sin(angle)}*4.2*s
        }
        ui.draw_polyline(ctx,outline[:],1.3*s,color)
        tip:=c+[2]f32{0,6.5}*s
        ui.draw_line(ctx,outline[0],tip,1.3*s,color)
        ui.draw_line(ctx,outline[10],tip,1.3*s,color)
        ui.draw_circle(ctx,head,1.3*s,color)
    case .Pin,.Pin_Filled:
        if User_Icon(kind)==.Pin_Filled {ui.draw_line(ctx,c+[2]f32{0,-4}*s,c+[2]f32{0,0.5}*s,4.2*s,color)}
        ui.draw_line(ctx,c+[2]f32{-3.5,-5.5}*s,c+[2]f32{3.5,-5.5}*s,1.4*s,color)
        body:=[6][2]f32{{-2,-5.5},{-2,-1},{-4.5,1.5},{4.5,1.5},{2,-1},{2,-5.5}}
        for &point in body {point=c+point*s}
        ui.draw_polyline(ctx,body[:],1.3*s,color)
        ui.draw_line(ctx,c+[2]f32{0,1.5}*s,c+[2]f32{0,7}*s,1.3*s,color)
    case .Back:
        chevron:=[3][2]f32{{2.5,-5},{-2.5,0},{2.5,5}}
        for &p in chevron {p=c+p*s}
        ui.draw_polyline(ctx,chevron[:],1.5*s,color)
    case .Branch:
        for ring in ([3][2]f32{{-4,-4.67},{-4,4.67},{4,-2.67}}) {ui.draw_ring(ctx,c+ring*s,1.6*s,1.2*s,color)}
        ui.draw_line(ctx,c+{-4*s,-3*s},c+{-4*s,3*s},1.2*s,color)
        curve:=[4][2]f32{{4,-1},{3.6,0.8},{1.2,1.8},{-3,3.4}}
        for &p in curve {p=c+p*s}
        ui.draw_polyline(ctx,curve[:],1.2*s,color)
    case .Unlink:
        halves:=[2][6][2]f32{{{-2.5,-0.5},{-4.5,1.5},{-4.6,3.4},{-3.2,4.8},{-1.2,4.8},{0.8,2.8}},{{2.5,0.5},{4.5,-1.5},{4.6,-3.4},{3.2,-4.8},{1.2,-4.8},{-0.8,-2.8}}}
        for &half in halves {
            for &p in half {p=c+p*s}
            ui.draw_polyline(ctx,half[:],1.5*s,color)
        }
        for spark in ([4][2][2]f32{{{-3,-5},{-5,-7}},{{3,5},{5,7}},{{-5,-2},{-7,-2}},{{7,2},{5,2}}}) {ui.draw_line(ctx,c+spark[0]*s,c+spark[1]*s,1.5*s,color)}
    case .Variant:
        // A prefab cube with a plus: a new prefab made from it.
        top,right,bottom_right,bottom:=c+[2]f32{-1.5,-7}*s,c+[2]f32{3.5,-4.5}*s,c+[2]f32{3.5,1}*s,c+[2]f32{-1.5,3.5}*s
        bottom_left,left,middle:=c+[2]f32{-6.5,1}*s,c+[2]f32{-6.5,-4.5}*s,c+[2]f32{-1.5,-2}*s
        cube:=[6][2]f32{top,right,bottom_right,bottom,bottom_left,left}
        ui.draw_polyline(ctx,cube[:],1.3*s,color,true)
        ui.draw_line(ctx,left,middle,1.3*s,color);ui.draw_line(ctx,right,middle,1.3*s,color);ui.draw_line(ctx,middle,bottom,1.3*s,color)
        ui.draw_line(ctx,c+[2]f32{2.5,5}*s,c+[2]f32{7.5,5}*s,1.5*s,color)
        ui.draw_line(ctx,c+[2]f32{5,2.5}*s,c+[2]f32{5,7.5}*s,1.5*s,color)
    case .Command:
        for x in ([2]f32{-2,2}) {ui.draw_line(ctx,c+{x*s,-4*s},c+{x*s,4*s},1.3*s,color)}
        for y in ([2]f32{-2,2}) {ui.draw_line(ctx,c+{-4*s,y*s},c+{4*s,y*s},1.3*s,color)}
        for corner in ([4][2]f32{{-4,-4},{4,-4},{4,4},{-4,4}}) {ui.draw_ring(ctx,c+corner*s,2*s,1.3*s,color)}
    // Two people, the second behind the first.
    case .Users:
        ui.draw_ring(ctx,c+{-2*s,-3*s},2.6*s,1.3,color)
        front:=[5][2]f32{c+{-7*s,6*s},c+{-6.3*s,3*s},c+{-2*s,1.4*s},c+{2.3*s,3*s},c+{3*s,6*s}}
        ui.draw_polyline(ctx,front[:],1.3,color)
        ui.draw_ring(ctx,c+{4.6*s,-2.4*s},2.1*s,1.2,color)
        back:=[3][2]f32{c+{4.6*s,1.6*s},c+{6.8*s,2.6*s},c+{7.4*s,5.4*s}}
        ui.draw_polyline(ctx,back[:],1.2,color)
    case .Share:
        a,b,d:=c+{-5*s,0},c+{5*s,-5*s},c+{5*s,5*s}
        ui.draw_line(ctx,a,b,1.4,color);ui.draw_line(ctx,a,d,1.4,color)
        for p in ([3][2]f32{a,b,d}) {ui.draw_ring(ctx,p,2*s,1.3,color)}
    }
}

// ---------------------------------------------------------------- drag

drag_begin :: proc(g:^Editor_Ui,d:Drag,label:string) {
    g.drag=d
    g.drag.press=g.ctx.pointer
    g.drag.moved,g.drag.released=false,false
    g.drag.label_length=copy(g.drag.label[:],label)
}

// True when a drag ends over a rectangle of the last frame.
drag_dropped :: proc(g:^Editor_Ui,rect:ui.Rect) -> bool {
    d:=&g.drag
    return d.kind!=.None && d.moved && d.released && ui.rect_contains(rect,g.ctx.pointer)
}

// True while a drag passes over a rectangle of the last frame.
drag_over :: proc(g:^Editor_Ui,rect:ui.Rect) -> bool {
    d:=&g.drag
    return d.kind!=.None && d.moved && !d.released && ui.rect_contains(rect,g.ctx.pointer)
}

@(private)
drag_update :: proc(g:^Editor_Ui,frame:^platform.Input_Frame) {
    d:=&g.drag
    if d.kind==.None {return}
    if !d.moved && linalg.distance(frame.mouse_position,d.press)>DRAG_THRESHOLD {d.moved=true}
    if .Left in frame.mouse_released || .Left not_in frame.mouse_down {d.released=true}
}

// What is carried, next to the pointer.
@(private)
drag_chip :: proc(s:^Session,g:^Editor_Ui) {
    d:=&g.drag
    if d.kind==.None || !d.moved || d.released {return}
    ctx:=g.ctx
    th:=&ctx.theme
    p:=ctx.pointer
    if ui.box(ctx,{width=ui.FIT,height=ui.fixed(24),padding={8,0,10,0},gap=6,align_y=.Center,float={to=.Surface,offset={p.x+14,p.y+12},layer=ui.LAYER_TOOLTIP},fill=th.popup,stroke=th.border,radius=th.radius_control,shadow=true}) {
        icon,color:=drag_icon(s,d)
        ui.icon(ctx,icon,color,14)
        ui.label(ctx,string(d.label[:d.label_length]),th.font_small,th.text)
    }
}

@(private)
drag_icon :: proc(s:^Session,d:^Drag) -> (ui.Icon,ui.Color) {
    switch d.kind {
    case .None:   return .None,{}
    case .Preset: return d.icon,d.color
    case .Entity: return .Group,GROUP_COLOR
    case .Asset:  return asset_icon(s,d.asset_kind)
    }
    return .None,{}
}

// ---------------------------------------------------------------- the frame

@(private)
shell_build :: proc(s:^Session,w:core.World_Ref) {
    g:=s.gui
    ctx:=g.ctx
    th:=&ctx.theme
    g.cursor=.Default
    g.drawing_count=0
    if s.projects!=nil && s.projects.launcher {
        projects_build(s)
        return
    }
    // Behind a document in front, where the scene would be, its canvas.
    if scene_covered(s) {
        if ui.box(ctx,{width=ui.fixed(ctx.size.x),height=ui.fixed(ctx.size.y),fill=th.well,float={to=.Surface}}) {}
    }
    player_processes_view_build(s)
    bar_build(s,w)
    l:=&g.layout
    play:=play_shown(s)
    document:=asset_document_active(s)
    if play {
        if ai_chat_open(s.ai)!=s.play_chat_open {play_chat_set(s,ai_chat_open(s.ai))}
    } else {
        if ai_chat_open(s.ai) && l.library_tab!=.Ai {library_select(s,.Ai)}
        if !ai_chat_open(s.ai) && l.library_tab==.Ai {library_select(s,l.previous_library_tab)}
        if !material_document_shown(s) && ai_material_open(s.ai) {ai_material_set(s.ai,{})}
    }
    bars:=th.bar_height+toolbar_height(g)
    top:=bars+DETAILS_MARGIN
    bottom_limit:=ctx.size.y-th.margin
    // A docked panel takes its edge of the window for the whole height under
    // the bars, and the scene what is left between them.
    _,right_dock:=dock_widths(s)
    left_width:=width_of(LEFT_WIDTH,ctx.size.x)
    right_width:=right_dock>0?right_dock:width_of(RIGHT_WIDTH,ctx.size.x)
    bottom_height:=clamp(l.bottom_height>0?l.bottom_height:BOTTOM_HEIGHT,BOTTOM_MIN,max(ctx.size.y*0.6,BOTTOM_MIN))
    g.rects.left,g.rects.right,g.rects.bottom={},{},{}
    // The clients of a game on the network take the viewport, as a Play does.
    panels:=!play && !player_processes_view(s)
    // A paused game shows what is selected of it.
    details:=panels || s.mode==.Paused && !s.play_stepped && !player_processes_view(s)

    shown_tab:=library_tab_shown(s)
    // The chat takes the whole area below the bars, and nothing else is drawn on it.
    expanded:=ai_chat_expanded(s.ai) && shown_tab==.Ai && panels && l.left_open
    if expanded {
        left_width=ctx.size.x-RAIL_WIDTH
        details=false
    }
    if (panels || play && !player_processes_view(s)) && !s.viewport.pick.active {
        rail_build(s,shown_tab,bars)
        g.rects.left={0,bars,RAIL_WIDTH,ctx.size.y-bars}
    }
    if (panels && l.left_open || play && s.play_chat_open) && !s.viewport.pick.active {
        height:=max(ctx.size.y-bars,80)
        id:=shell_id(g,"left")
        style:=ui.Panel_Float{width=ui.fixed(left_width),height=ui.fixed(height),padding=ui.padding_all(PANEL_PADDING),gap=8,anchor=.Top_Left,pivot=.Top_Left,offset={RAIL_WIDTH,bars},docked=true,corners={0,LEFT_RADIUS,LEFT_RADIUS,0}}
        if expanded {style.padding,style.gap,style.corners={},0,{}}
        if ui.panel(ctx,id,style) {
            // Only the tabs with controls of their own take a row for them.
            header:=shown_tab==.Ai && !expanded || shown_tab==.Editor
            if header {
                if ui.box(ctx,{width=ui.GROW,height=ui.fixed(PANEL_HEADER),gap=shown_tab==.Ai?2:3,align_x=.End,align_y=.Center}) {
                    if shown_tab==.Ai {
                        ai_chat_bar_buttons(s)
                        ai_chat_settings_button(s)
                    } else {content_settings_button(s,shell_id(g,"library_settings"),22)}
                }
            }
            room:=height-2*PANEL_PADDING
            if header {room-=PANEL_HEADER+8}
            ui.id_push(ctx,id)
            switch shown_tab {
            case .Editor: create_build(s,w,room,left_width-2*PANEL_PADDING)
            case .Hierarchy:
                // The entities of the scene, or the hierarchy the plugin of the document in front builds in this room.
                if document==nil {outliner_build(s,w,left_width-2*PANEL_PADDING,room)}
                else if ui.box(ctx,{id=shell_id(g,"hierarchy_room"),width=ui.GROW,height=ui.fixed(room),track=true}) {}
            case .Content: content_build(s,w,room,left_width-2*PANEL_PADDING)
            case .World: world_map_build(s,w,left_width-2*PANEL_PADDING,room)
            case .Git: git_panel_build(s,left_width-2*PANEL_PADDING,room)
            case .Ai:
                if expanded {ai_chat_expanded_build(s,left_width,height)}
                else {ai_chat_content_build(s,left_width-2*PANEL_PADDING,room)}
            }
            ui.id_pop(ctx)
            if shown_tab==.Ai {
                ai_chat_history_build(s,left_width-2*PANEL_PADDING)
                ai_chat_settings_build(s)
            }
            if !play {content_settings_build(s,shown_tab==.Content)}
        }
        if rect,found:=ui.widget_rect(ctx,id);found {g.rects.left=rect}
    }
    if panels && l.bottom_open && !expanded {
        x0:=RAIL_WIDTH+(l.left_open?left_width:0)+th.margin
        x1:=ctx.size.x-(right_dock>0?right_dock:0)-th.margin
        y:=bottom_limit-bottom_height
        id:=shell_id(g,"bottom")
        if ui.panel(ctx,id,{width=ui.fixed(max(x1-x0,120)),height=ui.fixed(bottom_height),padding={PANEL_PADDING,8,PANEL_PADDING,PANEL_PADDING},gap=8,anchor=.Top_Left,pivot=.Top_Left,offset={x0,y}}) {
            if ui.box(ctx,{width=ui.GROW,height=ui.fixed(28),gap=8,align_y=.Center}) {
                tab:=int(l.bottom_tab)
                ui.tabs(ctx,shell_id(g,"bottom_tabs"),{"Console","Build"},&tab,ui.fixed(200),28)
                l.bottom_tab=Bottom_Tab(tab)
                ui.spacer(ctx)
                ui.id_push(ctx,id)
                switch l.bottom_tab {
                case .Console: console_tools(s)
                case .Build:   build_tools(s)
                }
                ui.id_pop(ctx)
                if ui.button(ctx,shell_id(g,"bottom_close"),{icon=.Cross,style=.Ghost,width=24,height=24}).clicked {l.bottom_open=false}
            }
            room:=bottom_height-PANEL_PADDING-8-28-8
            ui.id_push(ctx,id)
            switch l.bottom_tab {
            case .Console: console_build(s,room)
            case .Build:   build_panel_build(s,room)
            }
            ui.id_pop(ctx)
        }
        g.rects.bottom={x0,y,x1-x0,bottom_height}
        if height,changed:=splitter(s,.Bottom,{x0,y-SPLITTER_WIDTH/2,x1-x0,SPLITTER_WIDTH},bottom_height,-1);changed {l.bottom_height=clamp(height,BOTTOM_MIN,ctx.size.y*0.6)}
    }

    _,_,deletion:=ai_review_shown(s)
    // Docked, the panel of a tool takes the place of Details for the whole height too.
    g.tool_top,g.tool_width,g.tool_dock=top,right_width,0
    if right_dock>0 {g.tool_top,g.tool_dock=bars,ctx.size.y-bars}
    // Docked, Details stays with nothing selected: the scene does not change size with the selection.
    content:=len(s.selection.entities)>0 || deletion || git_review_shown(s)
    if details && document==nil && l.right_open && ctx.size.x>=760 && (content || right_dock>0) && !s.viewport.pick.active && !tool_panel_shown(s) {
        max_height:=bottom_limit-top
        if l.bottom_open {max_height-=bottom_height+th.margin}
        if right_dock>0 {max_height=ctx.size.y-bars}
        max_height=max(max_height,120)
        id:=shell_id(g,"right")
        radius:=th.radius_panel
        style:=ui.Panel_Float{width=ui.fixed(right_width),height=ui.FIT,anchor=.Top_Right,pivot=.Top_Right,offset={-DETAILS_MARGIN,top},docked=true,corners={radius,radius,radius,radius}}
        if right_dock>0 {style.height,style.offset,style.corners=ui.fixed(max_height),{0,bars},{}}
        if ui.panel(ctx,id,style) {
            ui.id_push(ctx,id)
            // What is watched is read, not edited.
            read_only:=watching(s)
            if read_only {ui.disabled_begin(ctx)}
            if content {inspector_build(s,w,right_width,max_height)}
            if read_only {ui.disabled_end(ctx)}
            ui.id_pop(ctx)
        }
        if rect,found:=ui.widget_rect(ctx,id);found {g.rects.right=rect} else {g.rects.right={ctx.size.x-DETAILS_MARGIN-right_width,top,right_width,120}}
    }
    if right_dock>0 && !expanded {dock_edge(s,right_width,bars,ctx.size.y-bars)}
    if panels && !expanded && material_document_shown(s) {material_document_build(s)}
    if !expanded {
        camera_preview_bar(s)
        play_history_bar(s)
    }
    inspector_popups(s,w)
    tools_popups(s,w)
    if s.projects!=nil && s.projects.shown {projects_popup_build(s)}
    modal_build(s)
    toast_build(s)
    window_outline(s)
}

// The tabs of the left panel, at its side, whether it is open or not: a click
// on the one shown folds it and on another shows that one. In the pause of a
// game, the chat alone.
@(private)
rail_build :: proc(s:^Session,shown_tab:Library_Tab,bars:f32) {
    g:=s.gui
    ctx:=g.ctx
    th:=&ctx.theme
    l:=&g.layout
    play:=play_shown(s)
    tabs:=library_tabs(s)
    icons:=[Library_Tab]ui.Icon{.Editor=ui.icon_user(u8(User_Icon.Puzzle)),.Content=ui.icon_user(u8(User_Icon.Folder)),.Hierarchy=ui.icon_user(u8(User_Icon.List)),.World=.Layers,.Ai=.Sparkle,.Git=ui.icon_user(u8(User_Icon.Branch))}
    tips:=[Library_Tab]string{.Editor="Editor",.Content="Content Browser",.Hierarchy="Hierarchy",.World="World",.Ai="AI",.Git="Source control"}
    if ui.box(ctx,{id=shell_id(g,"rail"),width=ui.fixed(RAIL_WIDTH),height=ui.fixed(max(ctx.size.y-bars,1)),padding={0,8,0,8},gap=4,direction=.Column,align_x=.Center,float={to=.Surface,offset={0,bars},layer=ui.LAYER_BAR},fill=th.bar_top,block=true}) {
        for tab in ([]Library_Tab{.Editor,.Content,.Hierarchy,.World,.Ai,.Git}) {
            if tab not_in tabs {continue}
            shown:=play?tab==.Ai && s.play_chat_open:l.left_open && shown_tab==tab
            color:=shown?th.text:th.text_muted
            // A merge that waits for its conflicts marks the tab while it lasts.
            if tab==.Git && s.git!=nil && s.git.merging {color=th.danger}
            if !ui.button(ctx,shell_id(g,"library_tab",int(tab)+1),{icon=icons[tab],tip=tips[tab],style=.Toggle,active=shown,icon_color=color,width=RAIL_BUTTON,height=RAIL_BUTTON,icon_size=17,disabled=play && (tab!=.Ai || s.mode==.Play)}).clicked {continue}
            switch {
            case play:  play_chat_set(s,!s.play_chat_open)
            case shown: l.left_open=false
            case:       library_select(s,tab)
            }
        }
    }
}

library_select :: proc(s:^Session,tab:Library_Tab) {
    l:=&s.gui.layout
    if l.library_tab!=.Ai {l.previous_library_tab=l.library_tab}
    l.library_tab=tab
    l.left_open=true
    ai_chat_show(s.ai,tab==.Ai)
    if tab==.Ai {ai_chat_focus(s.ai,true)}
    // The search of the browser takes the keyboard, as the message of AI does,
    // unless an asset it reveals takes it.
    if tab==.Content && s.content!=nil {s.content.focus_search=s.content.reveal=={}}
}

// What follows the frame of the UI: the rectangles the window moves by, its title, the cursor.
@(private)
shell_after :: proc(s:^Session) {
    g:=s.gui
    ctx:=g.ctx
    p:=s.app.platform
    g.rects.bar={0,0,ctx.size.x,ctx.theme.bar_height+toolbar_height(g)}
    if g.cursor==.Default {
        switch ctx.cursor {
        case .Default:
        case .Text: g.cursor=.Text
        case .Resize_Horizontal: g.cursor=.Resize_Horizontal
        }
    }
    if g.cursor!=g.cursor_set {
        platform.window_set_cursor(p,g.cursor)
        g.cursor_set=g.cursor
    }
    title:=fmt.tprintf("%s%s - Mirai",document_title(s.document),document_dirty(s)?" *":"")
    if s.projects!=nil && s.projects.launcher {title="Mirai"} else if d:=asset_document_active(s);d!=nil {title=fmt.tprintf("%s%s - Mirai",asset_document_title(s,d),asset_document_dirty(s,d)?" *":"")}
    if title!=string(g.title[:g.title_length]) {
        g.title_length=copy(g.title[:],title)
        platform.window_set_title(p,title)
    }
    if s.headless {return}
    regions:[NAMED_CAPACITY+1]platform.Window_Region
    count:=shell_regions(s,regions[:])
    window:=platform.input_frame(p).window
    platform.window_set_regions(p,regions[:count],!window.maximized && !window.fullscreen)
}

@(private)
shell_regions :: proc(s:^Session,regions:[]platform.Window_Region) -> int {
    g:=s.gui
    count:=0
    bar:=g.rects.bar
    for entry in g.named[:g.named_count] {
        rect,found:=ui.widget_rect(g.ctx,entry.id)
        if !found || rect.y>=g.ctx.theme.bar_height {continue}
        if entry.clip!=0 {
            clip,clipped:=ui.widget_rect(g.ctx,entry.clip)
            if !clipped {continue}
            rect=ui.rect_intersect(rect,clip)
            if rect.w<=0 || rect.h<=0 {continue}
        }
        regions[count]={{rect.x,rect.y,rect.w,rect.h},entry.kind}
        count+=1
    }
    regions[count]={{bar.x,bar.y,bar.w,g.ctx.theme.bar_height},.Drag}
    count+=1
    return count
}

@(private)
width_of :: proc "contextless" (width:Panel_Width,window:f32) -> f32 {
    return clamp(window*width.fraction,width.min,width.max)
}

// The tabs of the left panel the document in front has.
library_tabs :: proc(s:^Session) -> Library_Tabs {
    type:=document_type(s)
    table:=DOCUMENT_LIBRARY_TABS
    tabs:=table[type]
    if d:=asset_document_active(s);type==.Asset && d!=nil && asset_document_hierarchy(s,d.kind) {tabs+={.Hierarchy}}
    return tabs
}

// The tab the left panel shows: the one chosen, or the first the document in
// front has when it does not have that one. The choice is kept for the others.
library_tab_shown :: proc(s:^Session) -> Library_Tab {
    tabs:=library_tabs(s)
    if s.gui.layout.library_tab in tabs {return s.gui.layout.library_tab}
    for tab in ([]Library_Tab{.Content,.Ai,.Git,.Editor,.Hierarchy,.World}) {if tab in tabs {return tab}}
    return .Content
}

// The type of the document in front, for the mode of the right panel.
document_type :: proc(s:^Session) -> Document_Type {
    switch {
    case asset_document_active(s)!=nil: return .Asset
    case document_is_prefab(s):         return .Prefab
    }
    return .Scene
}

// Whether the right panel docks for a type of document: its own choice, or the global mode.
panel_mode :: proc "contextless" (l:^Layout,type:Document_Type) -> Panel_Mode {
    switch l.right_modes[type] {
    case .Floating: return .Floating
    case .Docked:   return .Docked
    case .Global:
    }
    return l.right_mode
}

// Where the part of the view the left panel does not cover starts, in points on
// whole pixels: a little under the panel, so its rounded corners show the scene.
dock_scene_left :: proc(s:^Session) -> f32 {
    left,_:=dock_widths(s)
    g:=s.gui
    if left<=0 || !g.layout.left_open || play_shown(s) {return left}
    density:=s.app!=nil && s.app.density>0?s.app.density:1
    return math.round((RAIL_WIDTH+width_of(LEFT_WIDTH,g.ctx.size.x)-LEFT_UNDER)*density)/density
}

// What the rail and a docked right panel take of the window, in points on
// whole pixels: the view is the rest, whether the left panel covers part of it
// or not, so folding the panel moves nothing of its image. An asset document
// draws its own right side. In a Play only the rail stays, and while picking
// nothing does.
dock_widths :: proc(s:^Session) -> (left,right:f32) {
    g:=s.gui
    if g==nil || g.ctx==nil || player_processes_view(s) || s.viewport!=nil && s.viewport.pick.active {return}
    l:=&g.layout
    window:=g.ctx.size.x
    density:=s.app!=nil && s.app.density>0?s.app.density:1
    left=math.round(RAIL_WIDTH*density)/density
    if play_shown(s) {return}
    switch type:=document_type(s);type {
    case .Asset:
    case .Scene,.Prefab:
        if l.right_open && window>=760 && panel_mode(l,type)==.Docked {right=dock_right_width(s)}
    }
    return
}

// The width of a docked right panel, in points on whole pixels.
dock_right_width :: proc(s:^Session) -> f32 {
    g:=s.gui
    window:=g.ctx.size.x
    density:=s.app!=nil && s.app.density>0?s.app.density:1
    value:=clamp(g.layout.right_width>0?g.layout.right_width:width_of(RIGHT_WIDTH,window),DOCK_MIN,max(window*0.4,DOCK_MIN))
    return math.round(value*density)/density
}

// The inner edge of a docked right panel: a rule, which a drag moves to widen or narrow it.
dock_edge :: proc(s:^Session,width,top,height:f32) {
    g:=s.gui;ctx:=g.ctx
    x:=ctx.size.x-width
    height:=max(height,1)
    if ui.box(ctx,{width=ui.fixed(1),height=ui.fixed(height),fill=ctx.theme.divider,float={to=.Surface,offset={x,top},layer=ui.LAYER_PANEL}}) {}
    if value,changed:=splitter(s,.Right,{x-SPLITTER_WIDTH/2,top,SPLITTER_WIDTH,height},width,-1);changed {
        g.layout.right_width=clamp(value,DOCK_MIN,max(ctx.size.x*0.4,DOCK_MIN))
    }
}

// The edge of a panel that resizes it. sign: whether the size grows with the pointer (1) or against it (-1).
@(private)
splitter :: proc(s:^Session,which:Splitter,rect:ui.Rect,size,sign:f32) -> (value:f32,changed:bool) {
    g:=s.gui
    ctx:=g.ctx
    th:=&ctx.theme
    id:=shell_id(g,"splitter",int(which))
    it:ui.Interaction
    horizontal:=which==.Bottom
    if ui.box(ctx,{width=ui.fixed(rect.w),height=ui.fixed(rect.h),float={to=.Surface,offset={rect.x,rect.y},layer=ui.LAYER_PANEL+1}}) {
        it=ui.interact(ctx,id)
        lit:=it.active || it.hot
        if ui.box(ctx,{id=id,width=ui.GROW,height=ui.GROW,fill=lit?ui.color_alpha(th.accent,110):{}}) {}
    }
    if it.hot || it.active {g.cursor=horizontal?.Resize_Vertical:.Resize_Horizontal}
    if it.pressed {
        g.splitter,g.splitter_start,g.splitter_press=which,size,ctx.pointer
    }
    if g.splitter!=which {return size,false}
    if !it.active {
        g.splitter=.None
        return size,false
    }
    delta:=horizontal?ctx.pointer.y-g.splitter_press.y:ctx.pointer.x-g.splitter_press.x
    return g.splitter_start+delta*sign,true
}

// ---------------------------------------------------------------- bar

@(private)
divider_vertical :: proc(ctx:^ui.Context) {
    if ui.box(ctx,{width=ui.FIT,height=ui.FIT,padding={4,0,4,0}}) {
        if ui.box(ctx,{width=ui.fixed(1),height=ui.fixed(20),fill=ctx.theme.border}) {}
    }
}

// The button of an entry: off and checked as the entry is, and it runs it.
// index tells apart two buttons of one entry.
command_button :: proc(s:^Session,name:string,b:ui.Button,index:int=0) -> bool {
    g:=s.gui
    state:=command_state(s,name)
    id:=command_widget(g,name,index)
    named_add(g,id)
    button:=b
    button.disabled=button.disabled || state.disabled
    if button.tip=="" && button.label=="" {button.tip=command_label(s,name)}
    if button.label!="" && state.label!="" {button.label=state.label}
    if button.style==.Tab || button.style==.Ghost {button.active=button.active || state.checked}
    if ui.button(g.ctx,id,button).clicked {return command_run(s,name)}
    return false
}

// The entry of a menu for an entry of the commands: it runs it. label: in place of its own.
command_menu_item :: proc(s:^Session,id:ui.Id,name:string,label:="") -> bool {
    b:=command_binding(s,name)
    if b==nil {return false}
    state:=binding_state(s,b)
    text:=label!=""?label:binding_label(b,state)
    if ui.menu_item(s.gui.ctx,id,text,{icon=b.icon,shortcut=shortcut_text(b.shortcut),checked=state.checked,disabled=state.disabled}) {return command_run(s,name)}
    return false
}

@(private)
bar_build :: proc(s:^Session,w:core.World_Ref) {
    g:=s.gui
    ctx:=g.ctx
    th:=&ctx.theme
    v:=s.viewport
    if ui.menu_bar(ctx,shell_id(g,"bar")) {
        if !s.headless && platform.WINDOW_CONTROLS==.Left_Traffic_Lights {ui.spacer(ctx,78,0)}
        if ui.box(ctx,{width=ui.FIT,height=ui.GROW,gap=2,align_y=.Center}) {
            if s.mode==.Play && !s.play_input_released {
                ui.icon(ctx,ui.icon_user(u8(User_Icon.Mirai)),MARK_ARM,30)
                ui.spacer(ctx,6,0)
                // Inset as the text of a menu is, so the tabs keep their distance.
                if ui.box(ctx,{width=ui.FIT,height=ui.GROW,padding={10,0,10,0},align_y=.Center}) {ui.label(ctx,"Playing",th.font,th.accent)}
            } else {menus_build(s,w)}
        }
        documents_build(s)
        if !s.headless && platform.WINDOW_CONTROLS==.Right {window_controls(s)}
    }
    if ui.box(ctx,{id=shell_id(g,"document_toolbar"),width=ui.fixed(ctx.size.x),height=ui.fixed(toolbar_height(g)),padding={10,0,10,0},gap=4,align_y=.Center,float={to=.Surface,offset={0,th.bar_height},layer=ui.LAYER_BAR},fill=th.panel,block=true}) {
        document:=asset_document_active(s)
        if document!=nil {
            // An asset document: its save, undo and redo, and what it plays after them.
            if ui.box(ctx,{width=ui.FIT,height=ui.GROW,gap=4,align_y=.Center}) {
                command_button(s,"save",{icon=ui.icon_user(u8(User_Icon.Save)),style=.Ghost,width=TOOLBAR_BUTTON,height=TOOLBAR_BUTTON})
                command_button(s,"undo",{icon=ui.icon_user(u8(User_Icon.Undo)),style=.Ghost,width=TOOLBAR_BUTTON,height=TOOLBAR_BUTTON})
                command_button(s,"redo",{icon=ui.icon_user(u8(User_Icon.Redo)),style=.Ghost,width=TOOLBAR_BUTTON,height=TOOLBAR_BUTTON})
            }
            if ui.box(ctx,{id=shell_id(g,"asset_toolbar"),width=ui.GROW,height=ui.GROW,gap=8,padding={10,0,0,0},align_y=.Center,track=true}) {
                if material_document_shown(s) {ui.label(ctx,material_document_kind(s),th.font,th.text_muted)}
            }
        } else if ui.box(ctx,{width=ui.FIT,height=ui.GROW,gap=4,align_y=.Center}) {
            command_button(s,"save",{icon=ui.icon_user(u8(User_Icon.Save)),style=.Ghost,width=TOOLBAR_BUTTON,height=TOOLBAR_BUTTON,disabled=!document_dirty(s)})
            command_button(s,"undo",{icon=ui.icon_user(u8(User_Icon.Undo)),style=.Ghost,width=TOOLBAR_BUTTON,height=TOOLBAR_BUTTON})
            command_button(s,"redo",{icon=ui.icon_user(u8(User_Icon.Redo)),style=.Ghost,width=TOOLBAR_BUTTON,height=TOOLBAR_BUTTON})
        }
        // The tools go at the left, after the document: Move, Rotate and Scale,
        // the snaps and the axes, the camera, and the tools of the plugins.
        if s.mode!=.Play && s.mode!=.Watch && !scene_covered(s) {
            divider_vertical(ctx)
            if ui.box(ctx,{width=ui.FIT,height=ui.GROW,gap=4,align_y=.Center}) {
                tools:=[3]string{"tool_move","tool_rotate","tool_scale"}
                icons:=[3]ui.Icon{.Move,.Rotate,.Scale}
                // Up to 1050 points they are narrower.
                for tool,i in tools {
                    command_button(s,tool,{icon=icons[i],style=.Tab,width=25 if ctx.size.x<=1050 else TOOLBAR_BUTTON,height=TOOLBAR_BUTTON,icon_size=16})
                }
                divider_vertical(ctx)
                snap_menu_build(s)
                command_button(s,"space",{icon=v.space==.Local?.Relative:.Absolute,style=.Ghost,icon_color=th.text_muted,width=TOOLBAR_BUTTON,height=TOOLBAR_BUTTON,active=v.space==.Local})
                camera_speed_build(s)
                divider_vertical(ctx)
                // A prefab document: its variants and its light, just before the tools.
                if document_is_prefab(s) {
                    prefab_variants_build(s)
                    if ui.button(ctx,shell_id(g,"prefab_sun"),{icon=.Sun,tip="Preview sunlight",style=.Tab,active=v.preview_sun,width=TOOLBAR_BUTTON,height=TOOLBAR_BUTTON}).clicked {v.preview_sun=!v.preview_sun}
                    divider_vertical(ctx)
                }
                tools_menu_build(s)
            }
        }
        // One distance between every control of the right end.
        if ui.box(ctx,{width=ui.GROW,height=ui.GROW,gap=8,align_x=.End,align_y=.Center}) {
            switch s.mode {
            case .Edit: if name:=presence_followed_name(s);name!="" && ctx.size.x>=900 {ui.label(ctx,ai_chat_menu_label(ctx,fmt.tprintf("Following %s",name),220,th.font),th.font,th.accent)}
            case .Play:
            case .Simulate: if ctx.size.x>=900 {ui.label(ctx,"Simulating",th.font,th.accent)}
            case .Paused,.Simulation_Paused: if ctx.size.x>=900 {ui.label(ctx,"Paused",th.font,th.accent)}
            case .Watch: if ctx.size.x>=900 {ui.label(ctx,ai_chat_menu_label(ctx,fmt.tprintf("Watching %s",watch_name(s)),220,th.font),th.font,th.accent)}
            }
            if (ctx.size.x>=900 || s.mode==.Watch) && !scene_covered(s) {watch_bar_build(s)}
            // The finder looks for entities of the scene, which an asset document hides.
            if s.mode!=.Play && !scene_covered(s) {
                command_button(s,"find",{icon=ui.icon_user(u8(User_Icon.Search)),style=.Ghost,width=TOOLBAR_BUTTON,height=TOOLBAR_BUTTON,icon_size=14})
            }
            if document==nil || !asset_document_flat(s,document.kind) {
                if document==nil && s.mode!=.Play {view_mode_build(s)}
                // The rate of the frame goes with Graphics, where it is turned on.
                if graphics:=graphics_settings(s);graphics!=nil && graphics.show_fps {
                    if ui.box(ctx,{id=shell_id(g,"fps"),width=ui.fixed(54),height=ui.fixed(th.control),align_x=.End,align_y=.Center,track=true}) {ui.label(ctx,fmt.tprintf("%.0f fps",s.app.stats.fps),th.font_small,th.text_muted)}
                }
                graphics:=shell_id(g,"graphics")
                if ui.button(ctx,graphics,{icon=ui.icon_user(u8(User_Icon.Graphics)),tip="Graphics",style=.Ghost,width=TOOLBAR_BUTTON,height=TOOLBAR_BUTTON,active=ui.popup_is_open(ctx,graphics_popup(g))}).clicked {command_run(s,"graphics")}
            }
            if s.mode!=.Play && ctx.size.x>=900 {share_button(s,BAR_BUTTON_HEIGHT)}
            if document==nil {play_controls(s)}
        }
    }
    g.rects.bar={0,0,ctx.size.x,th.bar_height+toolbar_height(g)}
    stats_build(s,w)
    share_build(s)
    presence_menu_build(s)
    viewport_menu_build(s)
    variant_prompt_build(s)
}

// One menu for the tools of the plugins and the panels of the project: the
// one chosen takes the place of Details. Icon, name and arrow, the name as
// wide as "Tools" so the button never grows and a longer one is cut; below
// 900 points, the icon and the arrow.
TOOLS_MENU_POPUP_WIDTH :: 240
TOOLS_LABEL_WIDTH :: 28 // the least width of "Tools"
TOOLS_MENU_PARTS :: 58  // the width of the button besides its name: paddings, icon, gaps and arrow
@(private)
tools_menu_build :: proc(s:^Session) {
    g:=s.gui
    ctx:=g.ctx
    th:=&ctx.theme
    panels:=s.panels
    shown:=panel_shown(panels)
    count:=panels!=nil?len(panels.list):0
    label,icon:="Tools",ui.icon_user(u8(User_Icon.Hammer))
    // The tools work on the scene of the document: a game shows none.
    tools:=!playing(s)
    for &b in command_bindings(s) {
        if b.menu!=.Tools || !tools {continue}
        count+=1
        if binding_state(s,&b).checked {label,icon=b.label,b.icon}
    }
    if count==0 {return}
    if shown!=nil {label,icon=base.text_get(shown.title[:]),.Layers}
    id,popup:=shell_id(g,"tools"),shell_id(g,"tools_popup")
    wide:=ctx.size.x>=900
    active:=shown!=nil || s.viewport.plugin_tool!=0
    it:=ui.interact(ctx,id,{.Focusable})
    color:=th.on_accent if active else th.text
    fill:=th.accent if active else (th.field_hover if it.hot else ui.Color{})
    stroke:=th.accent if active else ui.Color{}
    if ui.box(ctx,{id=id,width=ui.FIT,height=ui.fixed(TOOLBAR_BUTTON),padding={10,0,8,0},gap=6,align_y=.Center,fill=fill,stroke=stroke,radius=th.radius_control}) {
        ui.icon(ctx,icon,color,16)
        if wide {
            room:=max(ui.text_width(&ctx.font,"Tools",th.font),TOOLS_LABEL_WIDTH)
            // A fifth wider than its parts, all of it for the name.
            room+=(room+TOOLS_MENU_PARTS)*0.2
            ui.label(ctx,ai_chat_menu_label(ctx,label,room,th.font),th.font,color,room)
        }
        ui.icon(ctx,.Chevron_Down,color,12)
    }
    if it.hot && (!wide || label!="Tools") {ui.tooltip(ctx,label)}
    if it.clicked {
        anchor,_:=ui.widget_rect(ctx,id)
        ui.popup_open(ctx,popup,{anchor.x,anchor.y+anchor.h,anchor.w,0})
    }
    if ui.popup(ctx,popup,{min_width=TOOLS_MENU_POPUP_WIDTH}) {
        ui.id_push(ctx,popup)
        defer ui.id_pop(ctx)
        // Select leaves the tool or the panel shown: the gizmo and Details again.
        if ui.menu_item(ctx,ui.id(ctx,"select"),"Select",{icon=.Move,checked=!active}) {
            if s.viewport.plugin_tool!=0 {tool_leave(s)}
            panel_show(s,panels,-1,false)
        }
        header:=false
        for &b in command_bindings(s) {
            if b.menu!=.Tools || !tools {continue}
            if !header {ui.menu_header(ctx,"Plugin tools");header=true}
            command_menu_item(s,command_widget(g,b.name),b.name)
        }
        if panels!=nil && len(panels.list)>0 {
            ui.menu_header(ctx,"Panels")
            for &p,i in panels.list {
                if ui.menu_item(ctx,ui.id(ctx,"panel",i+1),base.text_get(p.title[:]),{icon=.Layers,checked=p.open}) {panel_show(s,panels,i,!p.open)}
            }
        }
    }
}

// A group of a menu: its title and a segmented control of choices. Returns
// the choice clicked; -1: none.
menu_choices :: proc(s:^Session,id:ui.Id,title:string,labels:[]string,current:int,disabled:=false) -> (chosen:int) {
    ctx:=s.gui.ctx
    th:=&ctx.theme
    chosen=-1
    ui.menu_header(ctx,title)
    ui.id_push(ctx,id)
    defer ui.id_pop(ctx)
    if ui.box(ctx,{width=ui.GROW,height=ui.FIT,padding={6,0,6,4}}) {
        if ui.segments(ctx,ui.GROW,26) {
            for label,i in labels {
                if ui.button(ctx,ui.id(ctx,"choice",i+1),{label=label,style=.Tab,active=i==current,width=-1,height=22,size=th.font_small,center=true,padding=2,disabled=disabled}).clicked {chosen=i}
            }
        }
    }
    return
}

@(private)
toolbar_height :: proc(g:^Editor_Ui) -> f32 {return g.toolbar_height if g.toolbar_height>0 else DOCUMENT_TOOLBAR_HEIGHT}

// Puts the bottom of the document bar and of the toolbar on whole pixels at
// the density of the window: two edges inside a pixel would let what is
// behind them through.
@(private)
bars_snap :: proc(g:^Editor_Ui,density:f32) {
    d:=density if density>0 else 1
    snap :: proc(points,d:f32) -> f32 {return max(math.round(points*d),1)/d}
    g.ctx.theme.bar_height=snap(ui.THEME_EDITOR.bar_height,d)
    g.toolbar_height=snap(ui.THEME_EDITOR.bar_height+DOCUMENT_TOOLBAR_HEIGHT,d)-g.ctx.theme.bar_height
}

// The snaps of the three tools behind the magnet: a click on it turns them
// off and back on, its arrow opens them, each with its toggle and its
// increment, whose arrow offers the usual ones.
SNAP_POPUP_WIDTH :: 236
@(private)
snap_menu_build :: proc(s:^Session) {
    g:=s.gui
    ctx:=g.ctx
    th:=&ctx.theme
    v:=s.viewport
    id,open,popup:=shell_id(g,"snap"),shell_id(g,"snap_open"),shell_id(g,"snap_popup")
    chosen:=v.snap || v.snap_rotate || v.snap_scale
    on:=chosen && !v.snap_off
    color:=th.on_accent if on else th.text_label
    // One button of the bar, lit while it snaps: the magnet and its arrow.
    if ui.box(ctx,{width=ui.FIT,height=ui.fixed(TOOLBAR_BUTTON),align_y=.Center,fill=th.accent_soft if on else {},stroke=th.accent if on else {},radius=th.radius_control}) {
        magnet:=ui.interact(ctx,id,{.Focusable})
        if ui.box(ctx,{id=id,width=ui.fixed(TOOLBAR_BUTTON-2),height=ui.GROW,align_x=.Center,align_y=.Center,fill=th.field_hover if magnet.hot else {},radius=th.radius_control}) {ui.icon(ctx,.Magnet,color,16)}
        if magnet.hot {ui.tooltip(ctx,"Snap")}
        if magnet.clicked {
            v.snap_off=on
            if !on && !chosen {v.snap=true}
        }
        arrow:=ui.interact(ctx,open,{.Focusable})
        if ui.box(ctx,{id=open,width=ui.fixed(14),height=ui.GROW,align_x=.Center,align_y=.Center,fill=th.field_hover if arrow.hot || ui.popup_is_open(ctx,popup) else {},radius=th.radius_control}) {ui.icon(ctx,.Chevron_Down,color,10)}
        if arrow.clicked {
            from,_:=ui.widget_rect(ctx,id)
            to,_:=ui.widget_rect(ctx,open)
            ui.popup_open(ctx,popup,{from.x,to.y+to.h,to.x+to.w-from.x,0})
        }
    }
    if ui.popup(ctx,popup,{width=SNAP_POPUP_WIDTH,padding=12,gap=6}) {
        icons:=[Tool]ui.Icon{.Move=.Grid,.Rotate=.Rotate,.Scale=.Scale}
        names:=[Tool]string{.Move="Position",.Rotate="Rotation",.Scale="Scale"}
        for tool in Tool {
            enabled:^bool
            value:^f32
            choices:[]f32
            field:=ui.Number_Field{height=22,min=0.001,has_min=true}
            switch tool {
            case .Move: enabled,value,field.unit,field.speed=&v.snap,&v.grid,"m",0.01;choices={0.1,0.25,0.5,1,5,10,25}
            case .Rotate: enabled,value,field.unit,field.speed,field.max,field.has_max=&v.snap_rotate,&v.rotate_increment,"°",0.5,360,true;choices={1,5,10,15,30,45,90}
            case .Scale: enabled,value,field.unit,field.speed=&v.snap_scale,&v.scale_increment,"×",0.005;choices={0.05,0.1,0.25,0.5,1}
            }
            // As narrow as the typed field of a slider: the increment and its unit.
            field.width=ui.fixed(46+ui.text_width(&ctx.font,field.unit,ui.FIELD_UNIT)+4)
            if ui.box(ctx,{width=ui.GROW,height=ui.fixed(th.row),gap=6,align_y=.Center}) {
                if ui.button(ctx,shell_id(g,"snap_toggle",int(tool)+1),{icon=icons[tool],style=.Tab,active=enabled^,width=24,height=22,icon_size=14}).clicked {enabled^=!enabled^}
                ui.label(ctx,names[tool],th.font,th.text,0)
                value_id,presets_open,presets:=shell_id(g,"snap_value",int(tool)+1),shell_id(g,"snap_presets_open",int(tool)+1),shell_id(g,"snap_presets",int(tool)+1)
                if ui.box(ctx,{width=ui.FIT,height=ui.FIT,gap=2,align_y=.Center}) {
                    typed:=f64(value^)
                    if ui.number_field(ctx,value_id,&typed,field).changed {value^=f32(typed)}
                    if ui.button(ctx,presets_open,{icon=.Chevron_Down,icon_size=10,icon_color=th.text_muted,style=.Field,width=18,height=22,active=ui.popup_is_open(ctx,presets)}).clicked {
                        from,_:=ui.widget_rect(ctx,value_id)
                        to,_:=ui.widget_rect(ctx,presets_open)
                        ui.popup_open(ctx,presets,{from.x,to.y+to.h,to.x+to.w-from.x,0})
                    }
                }
                if ui.popup(ctx,presets,{min_width=72,gap=1}) {
                    for choice,index in choices {
                        label:=fmt.tprintf("%s %s",ui.number_text(ctx,f64(choice)),field.unit)
                        if ui.button(ctx,shell_id(g,"snap_choice",int(tool)*16+index+1),{label=label,style=.Ghost,active=value^==choice,width=-1,height=22,size=th.font_small}).clicked {
                            value^=choice
                            ui.popup_close(ctx,presets)
                        }
                    }
                }
            }
        }
    }
}

@(private)
camera_speed_build :: proc(s:^Session) {
    g:=s.gui
    ctx:=g.ctx
    id:=shell_id(g,"camera_speed")
    popup:=shell_id(g,"camera_speed_popup")
    speed:=f64(s.viewport.fly_speed>0?s.viewport.fly_speed:VIEW_FLY_SPEED)
    if ui.button(ctx,id,{label=ui.number_text(ctx,speed,1),icon=ui.icon_user(u8(User_Icon.Camera)),style=.Ghost,height=TOOLBAR_BUTTON,size=ctx.theme.font,tip="Camera speed"}).clicked {
        anchor,_:=ui.widget_rect(ctx,id)
        ui.popup_open(ctx,popup,anchor)
    }
    if ui.popup(ctx,popup,{width=200,padding=12,gap=5}) {
        if ui.property(ctx,"Speed") {
            if ui.number_field(ctx,shell_id(g,"camera_speed_value"),&speed,{min=f64(VIEW_FLY_SPEED)*0.2,max=f64(VIEW_FLY_SPEED)*2.5,has_min=true,has_max=true,decimals=1,speed=0.1}).changed {s.viewport.fly_speed=f32(speed)}
        }
    }
}

@(private)
play_controls :: proc(s:^Session) {
    g:=s.gui
    ctx:=g.ctx
    th:=&ctx.theme
    stop:=ui.Button{icon=.Stop,style=.Tab,icon_color=th.accent,width=BAR_BUTTON_HEIGHT,height=BAR_BUTTON_HEIGHT}
    if s.mode==.Watch {
        if ui.segments(ctx,ui.FIT,30) {command_button(s,"stop",stop)}
        return
    }
    // Who has the keyboard and the mouse says how to get them back.
    eject :: proc(s:^Session) {
        if player_processes_captured(s) || s.mode==.Play && !s.play_input_released {
            command_button(s,"release_input",{label="Eject (F1)",style=.Field,height=BAR_BUTTON_HEIGHT,size=s.gui.ctx.theme.font_small})
        }
    }
    providers_:=providers(s)
    plugin:=&providers_.play
    plugin_label :: proc(s:^Session,plugin:^Play_Provider) -> string {return plugin.label!=nil?plugin.label(s):""}
    if s.mode==.Edit && play_plugin_active(s) {
        if label:=plugin_label(s,plugin);ctx.size.x>=900 && label!="" {ui.label(ctx,label,th.font,th.accent)}
        eject(s)
        if ui.segments(ctx,ui.FIT,30) {command_button(s,"stop",stop)}
        return
    }
    if s.mode==.Edit {
        kind:=&g.layout.run_kind
        players:=s.play_players
        run:=RUN_COMMANDS[kind^]
        // The mode keeps its icon whoever plays it: online players are said in the menu.
        icon:=command_icon(s,run)
        if ui.box(ctx,{width=ui.FIT,height=ui.fixed(th.control),gap=0,align_y=.Center,fill=th.accent,radius=th.radius_control}) {
            command_button(s,run,{icon=icon,style=.Accent,width=28,height=ctx.theme.control,icon_size=14})
            id:=shell_id(g,"run_menu")
            if ui.button(ctx,id,{icon=.Chevron_Down,style=.Accent,width=18,height=ctx.theme.control,icon_size=10,tip="Execution mode"}).clicked {
                anchor,_:=ui.widget_rect(ctx,id)
                ui.popup_open(ctx,shell_id(g,"run_popup"),anchor)
            }
        }
        if ui.popup(ctx,shell_id(g,"run_popup"),{align_right=true}) {
            // Choosing a mode also runs it.
            for k in Run_Kind {
                run:=RUN_COMMANDS[k]
                if ui.menu_item(ctx,shell_id(g,"run_kind",int(k)+1),command_label(s,run),{icon=command_icon(s,run),shortcut=k==.Play?"F5":"",checked=kind^==k}) {
                    kind^=k
                    command_run(s,run)
                }
            }
            if players!=nil {
                // The players of Play split the screen; a plugin that plays
                // them on the network shows them, and how they share, itself.
                if providers_.plays && plugin.menu!=nil {plugin.menu(s)} else {
                    labels:=[PLAYER_PROCESSES]string{"1","2","3","4"}
                    if chosen:=menu_choices(s,shell_id(g,"run_players"),"Players",labels[:],players.players-1);chosen>=0 {players.players=chosen+1}
                }
            }
        }
        return
    }
    if simulating(s) && !camera_previewing(s) {command_button(s,"apply_simulation",{label="Apply transforms",style=.Field,height=BAR_BUTTON_HEIGHT})}
    if camera_previewing(s) {
        command_button(s,"camera_discard",{label="Discard",style=.Field,height=BAR_BUTTON_HEIGHT})
        command_button(s,"camera_keep",{label="Keep",style=.Accent,height=BAR_BUTTON_HEIGHT})
    }
    if label:=plugin_label(s,plugin);play_plugin_active(s) && ctx.size.x>=900 && label!="" {ui.label(ctx,label,th.font,th.accent)}
    eject(s)
    if ui.segments(ctx,ui.FIT,30) {
        // One button: Pause while it plays, Resume while it is paused.
        pause:=play_paused(s)?"resume":"pause"
        command_button(s,pause,{icon=command_icon(s,pause),style=.Tab,icon_color=th.text,width=BAR_BUTTON_HEIGHT,height=BAR_BUTTON_HEIGHT})
        command_button(s,"stop",stop)
    }
}

@(private)
bottom_toggle_open :: proc(g:^Editor_Ui,tab:Bottom_Tab) {g.layout.bottom_open,g.layout.bottom_tab=true,tab}

@(private)
window_controls :: proc(s:^Session) {
    g:=s.gui
    ctx:=g.ctx
    p:=s.app.platform
    th:=&ctx.theme
    window:=platform.input_frame(p).window
    // Flush with the top right corner of the window, past the 10 points of
    // padding of the bar, so a pointer thrown at the corner lands on Close.
    ui.spacer(ctx,3*WINDOW_CONTROL_WIDTH-10,0)
    if ui.box(ctx,{width=ui.FIT,height=ui.fixed(th.bar_height),float={to=.Parent,anchor=.Top_Right,pivot=.Top_Right}}) {
        for control in ([3]User_Icon{.Minimize,.Maximize,.Close}) {
            id:=shell_id(g,"window_control",int(control)+1)
            named_add(g,id,.Control)
            if !ui.button(ctx,id,{icon=ui.icon_user(u8(control)),icon_color=th.text_muted,style=.Ghost,width=WINDOW_CONTROL_WIDTH,height=th.bar_height,center=true}).clicked {continue}
            #partial switch control {
            case .Minimize: platform.window_minimize(p)
            case .Maximize: platform.window_set_maximized(p,!window.maximized)
            case .Close:    quit_request(s)
            }
        }
    }
}

@(private)
menus_build :: proc(s:^Session,w:core.World_Ref) {
    menu_entries(s,"Mirai",1,.File,{icon=ui.icon_user(u8(User_Icon.Mirai)),icon_color=MARK_ARM,icon_size=30,padding=4})
    menu_entries(s,"View",4,.View)
}

// A menu of the bar: the entries given to it, of the editor and of the
// plugins, by group. View shows Stats, a popup of its own and not a command,
// after the panels of the plugins.
@(private)
menu_entries :: proc(s:^Session,title:string,index:int,menu:Menu,look:ui.Button={}) {
    g:=s.gui
    ctx:=g.ctx
    id:=shell_id(g,"menu",index)
    named_add(g,id)
    if ui.menu(ctx,id,title,look.icon!=.None?BAR_MARK_HEIGHT:26,look) {
        shown:=false
        for group in 0..<u8(MENU_GROUPS) {
            parted:=false
            part :: proc(ctx:^ui.Context,shown,parted:^bool) {
                if shown^ && !parted^ {ui.menu_separator(ctx)}
                shown^,parted^=true,true
            }
            for &b,at in command_bindings(s) {
                if b.menu!=menu || b.group!=group {continue}
                part(ctx,&shown,&parted)
                command_menu_item(s,shell_id(g,"menu_item",index*1000+at+1),b.name)
            }
            if menu==.View && group==MENU_GROUP_PLUGINS {
                part(ctx,&shown,&parted)
                if ui.menu_item(ctx,shell_id(g,"stats"),"Stats",{icon=.Gauge}) {
                    anchor,_:=ui.widget_rect(ctx,id)
                    ui.popup_open(ctx,stats_popup(g),anchor)
                }
            }
        }
    }
}


@(private)
stats_popup :: proc(g:^Editor_Ui) -> ui.Id {return shell_id(g,"stats_popup")}

// What the renderer and the editor are doing: the popup of the Stats button.
@(private)
stats_build :: proc(s:^Session,w:core.World_Ref) {
    g:=s.gui
    ctx:=g.ctx
    th:=&ctx.theme
    popup:=stats_popup(g)
    if !ui.popup_is_open(ctx,popup) {return}
    row :: proc(ctx:^ui.Context,name,value:string) {
        th:=&ctx.theme
        if ui.box(ctx,{width=ui.GROW,height=ui.fixed(th.row),gap=8,align_y=.Center}) {
            ui.label(ctx,name,th.font_small,th.text_muted)
            ui.spacer(ctx)
            ui.label(ctx,value,th.font_small,th.text)
        }
    }
    if ui.popup(ctx,popup,{width=260,align_right=true,padding=12,gap=2}) {
        ui.label(ctx,"Stats",th.font_title,th.text,font=ui.FONT_SEMIBOLD)
        app:=s.app
        row(ctx,"Frames per second",fmt.tprintf("%.0f",s.app.stats.fps))
        row(ctx,"Frame",fmt.tprintf("%.2f ms",app.stats.frame_ms))
        row(ctx,"Game",fmt.tprintf("%.2f ms",app.stats.game_ms))
        row(ctx,"Editor",fmt.tprintf("%.2f ms",app.stats.editor_ms))
        row(ctx,"Entities",fmt.tprintf("%d",core.world_entities(w).alive))
        row(ctx,"Undo steps",fmt.tprintf("%d",history.edits_undo_count(s.edits)))
        if r:=app.renderer;r!=nil {
            stats:=gpu.renderer_stats(r)
            row(ctx,"Render",fmt.tprintf("%.2f ms",app.stats.render_ms))
            row(ctx,"GPU",fmt.tprintf("%.2f ms",stats.gpu_ms))
            row(ctx,"Resolution",fmt.tprintf("%d x %d",stats.render_width,stats.render_height))
            row(ctx,"Instances",fmt.tprintf("%d of %d",stats.visible_instances,stats.instances))
            row(ctx,"Device",stats.device_name)
        } else {
            row(ctx,"Renderer","None")
        }
    }
}

// ---------------------------------------------------------------- dialogs and notices

@(private)
modal_build :: proc(s:^Session) {
    g:=s.gui
    ctx:=g.ctx
    th:=&ctx.theme
    switch g.modal {
    case .None:
    case .Recovery:
        if ui.modal(ctx,shell_id(g,"recovery"),{width=440}) {
            ui.label(ctx,"Recover unsaved changes?",th.font_title,th.text,font=ui.FONT_SEMIBOLD)
            if s.recovery.tabs {
                ui.label(ctx,"Every tab of the editor that ended",th.font_small,th.text_muted)
            } else {
                for &found in s.recovery.found {
                    path:=base.text_get(found.scene?found.info.source[:]:found.source[:])
                    ui.label(ctx,path!=""?filepath.base(path):"Untitled",th.font_small,th.text_muted)
                }
            }
            if len(s.recovery.assets)>0 {ui.label(ctx,"Assets with unsaved changes",th.font_small,th.text_muted)}
            if ui.box(ctx,{width=ui.GROW,height=ui.fixed(28),gap=8,align_x=.End,align_y=.Center}) {
                if ui.button(ctx,shell_id(g,"recovery_later"),{label="Later",style=.Field,width=92,height=28,center=true}).clicked {g.modal=.None}
                if ui.button(ctx,shell_id(g,"recover"),{label="Recover",style=.Accent,width=92,height=28,center=true}).clicked {s.requests+={.Recover}}
                if ui.button(ctx,shell_id(g,"discard_recovery"),{label="Discard",style=.Field,width=92,height=28,center=true}).clicked {s.requests+={.Discard_Recovery}}
            }
        }
    case .Confirm:
        if ui.modal(ctx,shell_id(g,"confirm"),{width=380}) {
            // Agents still working are asked about too, with nothing unsaved.
            scene:=document_dirty(s) && !pending_plugin(g.pending) && g.pending!=.Asset_Close
            unsaved:=scene || len(g.confirm_assets)>0
            working,waiting:=ai_working_count(s),ai_review_waiting_count(s)
            agents:=working==1?"An agent is working":fmt.tprintf("%d agents are working",working)
            others:=scene_switch_others(s,g.pending)
            ui.label(ctx,unsaved?"Unsaved changes":others!=""?"Change the scene?":agents,th.font_title,th.text,font=ui.FONT_SEMIBOLD)
            if others!="" {ui.text(ctx,others,ui.prose(ctx,th.font_small,th.text_muted))}
            if pending_plugin(g.pending) {
                ui.label(ctx,"The players read the saved files",th.font_small,th.text_muted)
            } else if unsaved {
                ui.label(ctx,len(g.confirm_assets)>0?"Save the changes before going on?":document_title(s.document),th.font_small,th.text_muted)
            }
            if unsaved {unsaved_list(s,scene)} else {ui.label(ctx,document_title(s.document),th.font_small,th.text_muted)}
            if (unsaved || others!="") && working>0 {ui.label(ctx,fmt.tprintf("%s: %s",agents,working==1?"it stops":"they stop"),th.font_small,th.text_muted)}
            if waiting>0 {ui.label(ctx,fmt.tprintf("%d agent %s waiting for review",waiting,waiting==1?"change":"changes"),th.font_small,th.text_muted)}
            if ui.box(ctx,{width=ui.GROW,height=ui.fixed(28),gap=8,align_x=.End,align_y=.Center}) {
                choices:=[3]Choice{.Save,.Discard,.Cancel}
                labels:=[3]string{"Save","Discard","Cancel"}
                widths:=[3]f32{92,92,92}
                shown:=choices[:]
                verb:="Play"
                if p:=providers(s);g.pending==.Play_Plugin && p.plays && p.play.verb!=nil {verb=p.play.verb(s)}
                if g.pending==.Play_Plugin {labels[0],labels[1],widths[1]=fmt.tprintf("Save and %s",strings.to_lower(verb,context.temp_allocator)),fmt.tprintf("%s without",verb),110}
                if !unsaved {
                    // Nothing to save: going on is all that is asked.
                    pending_labels:=[Pending]string{.None="Continue",.New="New",.Close="Close",.Quit="Quit",.Play_Plugin="Play",.Asset_Close="Close",.Open_Scene="Open"}
                    labels[1]=pending_labels[g.pending]
                    if g.pending==.Play_Plugin {labels[1]=verb}
                    shown=choices[1:]
                }
                for choice in shown {
                    if ui.button(ctx,shell_id(g,"confirm_choice",int(choice)+1),{label=labels[int(choice)],style=choice==.Save || !unsaved && choice==.Discard?.Accent:.Field,width=widths[int(choice)],height=28,center=true}).clicked {confirm_resolve(s,choice)}
                }
            }
        }
    case .Save_Changes:
        if ui.modal(ctx,shell_id(g,"save_changes"),{width=380}) {
            ui.label(ctx,"Save changes",th.font_title,th.text,font=ui.FONT_SEMIBOLD)
            ui.label(ctx,"The scene uses assets with unsaved changes.",th.font_small,th.text_muted)
            unsaved_list(s,true)
            if ui.box(ctx,{width=ui.GROW,height=ui.fixed(28),gap=8,align_x=.End,align_y=.Center}) {
                if ui.button(ctx,shell_id(g,"save_changes_cancel"),{label="Cancel",style=.Field,width=92,height=28,center=true}).clicked {modal_close(g)}
                if ui.button(ctx,shell_id(g,"save_changes_scene"),{label="Scene only",style=.Field,width=92,height=28,center=true}).clicked {save_changes_resolve(s,false)}
                if ui.button(ctx,shell_id(g,"save_changes_all"),{label="Save all",style=.Accent,width=92,height=28,center=true}).clicked {save_changes_resolve(s,true)}
            }
        }
    case .Shortcuts:
        closed:=false
        defer if closed {g.modal=.None}
        if ui.modal(ctx,shell_id(g,"shortcuts"),{width=440,scroll=&g.modal_scroll,close=&closed}) {
            ui.label(ctx,"Keyboard shortcuts",th.font_title,th.text,font=ui.FONT_SEMIBOLD)
            row :: proc(ctx:^ui.Context,name,keys:string) {
                th:=&ctx.theme
                if ui.box(ctx,{width=ui.GROW,height=ui.fixed(th.row),align_y=.Center}) {
                    ui.label(ctx,name,th.font_small,th.text)
                    ui.spacer(ctx)
                    ui.label(ctx,keys,th.font_small,th.text_muted)
                }
            }
            // An entry by its key: two entries of one key are what it does by turns (Pause and Resume).
            for &b,at in command_bindings(s) {
                if !b.shortcut.set {continue}
                repeated:=false
                for &other in command_bindings(s)[:at] {repeated||=other.shortcut==b.shortcut}
                if !repeated {row(ctx,b.label,shortcut_text(b.shortcut))}
            }
        }
    case .Settings: settings_modal(s)
    case .Delete_Asset: asset_delete_modal(s)
    case .Git_Discard:  git_discard_modal(s)
    }
}

// What a question about unsaved changes saves or discards: the scene when
// scene is set, and its assets, a row each with the kind of the file.
@(private)
unsaved_list :: proc(s:^Session,scene:bool) {
    g:=s.gui
    ctx:=g.ctx
    if ui.box(ctx,{width=ui.GROW,height=ui.FIT,direction=.Column,gap=2,padding={0,6,0,6}}) {
        if scene {modal_row(ctx,document_is_prefab(s)?.Prefab:.Scene,document_title(s.document),document_is_prefab(s)?"Prefab":"Scene")}
        registry:=&s.app.assets.registry
        for path in g.confirm_assets {
            if asset.registry_outside(path) {
                modal_row(ctx,.Material,asset_name(path),"Program")
            } else if file,found:=asset.registry_find_path(registry,path);found && file.state==.Asset {
                modal_asset_row(s,ctx,file)
            } else {
                modal_row(ctx,.None,asset_name(path),"File")
            }
        }
    }
}

// A file a question names: its icon, its name and its kind.
@(private)
modal_row :: proc(ctx:^ui.Context,icon:ui.Icon,name,kind:string) {
    th:=&ctx.theme
    if ui.box(ctx,{width=ui.GROW,height=ui.fixed(th.control),gap=8,padding={8,0,8,0},align_y=.Center,fill=th.field,radius=4}) {
        ui.icon(ctx,icon,th.text_muted,14)
        ui.label(ctx,name,th.font_small,th.text,0)
        ui.spacer(ctx)
        ui.label(ctx,kind,th.font_small,th.text_muted)
    }
}

@(private)
modal_asset_row :: proc(s:^Session,ctx:^ui.Context,file:^asset.Registry_File) {
    icon,_:=asset_file_icon(s,file)
    kind:="File"
    if info,known:=asset.kind_info(file.kind);known {kind=strings.to_upper_camel_case(info.name,context.temp_allocator)}
    modal_row(ctx,icon,asset_name(file.path),kind)
}

// A line around the window that sets it apart from what is behind it, as
// the panels have theirs; not while it fills the screen.
WINDOW_RULE :: ui.Color{86,89,99,255}

@(private)
window_outline :: proc(s:^Session) {
    if s.headless || s.app==nil {return}
    window:=platform.input_frame(s.app.platform).window
    if window.maximized || window.fullscreen {return}
    ctx:=s.gui.ctx
    if ui.box(ctx,{width=ui.fixed(ctx.size.x),height=ui.fixed(ctx.size.y),stroke=WINDOW_RULE,stroke_width=1,float={to=.Surface,layer=ui.LAYER_MODAL+1}}) {}
}

@(private)
toast_build :: proc(s:^Session) {
    if s.toast_seconds<=0 || s.toast_length==0 {return}
    g:=s.gui
    ctx:=g.ctx
    th:=&ctx.theme
    offset:=-2*th.margin
    if g.layout.bottom_open {offset-=g.rects.bottom.h+th.margin}
    if ui.panel(ctx,shell_id(g,"toast"),{width=ui.FIT,height=ui.FIT,padding={12,8,12,8},anchor=.Bottom_Center,pivot=.Bottom_Center,offset={0,offset},layer=ui.LAYER_TOAST,popup=true}) {
        ui.label(ctx,string(s.toast[:s.toast_length]),th.font,th.text)
    }
}
