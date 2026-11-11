package editor

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:reflect"
import "core:strings"
import "core:time"
import "mirai:cook/build"
import "mirai:core"
import "mirai:editor/api"
import "mirai:editor/history"
import input "mirai:engine/input"
import erender "mirai:engine/render"
import "mirai:host"
import "mirai:platform"
import "mirai:project"
import gpu "mirai:render"
import "mirai:rhi"
import "mirai:std/base"
import "mirai:std/serial"
import "mirai:ui"

// The methods of the agent API that are not edits of the scene: execution,
// inspection and input of the editor, history, camera, capture, Play and
// Build. The scene has its own file (api_scene.odin).

API_STEP_LIMIT :: 3600
API_NO_GAME :: "No game is playing; play.start first"
API_PLAYING :: "A game is playing; play.stop first"

// What a method that needs a game answers without one, and one that needs
// Edit while a game plays: one code and one text each, with the method that
// changes it.
api_no_game :: proc(call:^api.Call,more:="") {
    api.call_not_now(call,more!=""?fmt.tprintf("%s; %s",API_NO_GAME,more):API_NO_GAME,"play.start")
}
api_playing :: proc(call:^api.Call,more:="") {
    api.call_not_now(call,more!=""?fmt.tprintf("%s; %s",API_PLAYING,more):API_PLAYING,"play.stop")
}
API_FILMSTRIP_CELLS :: 64
API_DT_MAX :: f32(0.25)
API_INPUT_EVENTS :: 256
API_TIMINGS :: 48

Api_Timing :: struct {
    name:[32]u8 `mirai:"text"`,
    ms:f32,
}

API_COUNTERS :: gpu.EXTENSION_COUNTER_CAPACITY

// What the passes of a plugin count on the GPU under a name; its plugin says
// what each value is.
Api_Counter :: struct {
    name:[gpu.EXTENSION_COUNTER_NAME_BYTES]u8 `mirai:"text"`,
    values:[4]u32,
}

// Time of the main thread in the parts of the last frame, in ms.
Api_Cpu :: struct {
    platform_ms:f32 `mirai:"label=Events of the window and pacing"`,
    watch_ms:f32 `mirai:"label=Resize and the watches of assets and shaders"`,
    game_ms:f32 `mirai:"label=The game loop of a Play"`,
    editor_ms:f32 `mirai:"label=The loop of the editor over the World shown"`,
    editor_begin_ms:f32 `mirai:"label=editor_begin: input; the pointer and shortcuts"`,
    editor_tools_ms:f32 `mirai:"label=editor_tools: camera; gizmo and selection"`,
    editor_ui_ms:f32 `mirai:"label=editor_panels: bar and panels"`,
    editor_end_ms:f32 `mirai:"label=editor_end: layout and draw lists of the UI"`,
    render_prepare_ms:f32 `mirai:"label=Geometry commit; capacities and targets"`,
    render_begin_ms:f32 `mirai:"label=The wait for a frame slot of the GPU"`,
    render_record_ms:f32 `mirai:"label=Uploads and the commands of every pass"`,
    render_end_ms:f32 `mirai:"label=Submit and present"`,
    render_ms:f32 `mirai:"label=The whole of the renderer frame"`,
    app_ms:f32 `mirai:"label=The whole frame of the application"`,
}

Api_Status :: struct {
    frame:u64,
    mode:Mode,
    entities:int,
    selected:int,
    dirty,headless,manual,gpu_enabled,has_project:bool,
    document:[API_PATH_BYTES]u8 `mirai:"text"`,
    fps,gpu_ms:f32,
    ev100:f32 `mirai:"label=The exposure of the viewport before its compensation: what the meter took or the manual value"`,
    cpu:Api_Cpu `mirai:"label=Time of the main thread in the parts of the last frame in ms"`,
    render_width,render_height:int,
    instances,visible_instances,lights:int,
    tlas_instances:int `mirai:"label=Entries of the structure rays walk"`,
    visible_triangles:int `mirai:"label=Of the instances that passed culling two frames ago"`,
    visible_kinds:Api_Visible_Kinds `mirai:"label=What passed culling two frames ago, by kind of instance"`,
    probes_traced:int `mirai:"label=Two frames ago"`,
    gpu_timings:[API_TIMINGS]Api_Timing `mirai:"trim,label=By pass in the order of the frame"`,
    counters:[API_COUNTERS]Api_Counter `mirai:"trim,label=What the passes of extensions counted two frames ago by name"`,
    functions:[API_FUNCTIONS]Api_Timing `mirai:"trim,label=The costliest functions of the loops per frame since the last status; settle included"`,
    backend:[16]u8 `mirai:"text"`,
    device:[128]u8 `mirai:"text"`,
    undo,redo:int,
    ui_dropped:u64,
    validation_errors:int,
    renderer_problem:[512]u8 `mirai:"text,label=What the renderer could not do in the last frame and why; empty when nothing failed"`,
    asset_errors:int,
    assets:Api_Assets, // loaded now, and how many what no world names unloaded so far
    textures:Api_Textures,
    geometry:Api_Geometry,
    ticks_dropped:u64,
    extras_dropped:u64 `mirai:"label=What libraries asked to draw in a frame that did not fit and was not drawn (panels, lines, UI layers and textures, views, probes), since the editor started; it should stay 0"`,
    build:Build_Phase,
    build_errors:int,
    build_message:[256]u8 `mirai:"text"`,
    collab:[32]u8 `mirai:"text"`,
    api_calls,api_errors:u64,
    gpu_memory:Api_Gpu_Memory `mirai:"label=What the editor holds of the memory of the GPU and what the system lets it hold before it pages some out; zeros when the driver does not say"`,
}

Api_Gpu_Memory :: struct {used_mb,budget_mb:f32}

Api_Assets :: struct {meshes,textures,materials,scenes,unloads:int}

Api_Visible :: struct {instances,clusters,triangles:int}
Api_Visible_Kinds :: struct {
    levels:Api_Visible `mirai:"label=Instances of the scene whose mesh has levels of detail"`,
    single:Api_Visible `mirai:"label=Instances of the scene whose mesh has one level: terrain pieces and other meshes made at run time"`,
    batches:Api_Visible `mirai:"label=Instances of batches"`,
    late:Api_Visible `mirai:"label=Of all of them, what phase 1 of the occlusion drew: the pyramid of the frame showed it after the one of the frame before hid it"`,
    dropped:[len(gpu.Cull_List)]int `mirai:"label=Chunks, visible clusters, occlusion candidates and clusters of Surface programs past the capacities of the lists of the cull, which grow for the frames after"`,
}

Api_Textures :: struct {
    bytes:u64 `mirai:"label=GPU memory of the textures of the renderer"`,
    view_bytes:u64 `mirai:"label=GPU memory of the targets of the views drawn into textures, which the pool of the textures gives up"`,
    pending:int `mirai:"label=Textures whose levels are not yet those the frames sample"`,
    reduced:int `mirai:"label=Textures held coarser than the frames sample to fit the pool"`,
    streamed:int `mirai:"label=Ranges of levels given to textures since the assets loaded"`,
}

Api_Geometry :: struct {
    bytes:u64 `mirai:"label=GPU memory of the pools of the geometry of the renderer"`,
    free_bytes:u64 `mirai:"label=Of those pools: the free ranges between their meshes, that a mesh of their size or less takes"`,
    free_largest:u64 `mirai:"label=The bytes of the largest of those ranges"`,
    ray_bytes:u64 `mirai:"label=GPU memory of the structures rays are traced through"`,
    page_slots:int `mirai:"label=Slots of the vertex pool for the pages of streamed meshes out of their root; 0: none"`,
    page_bytes:u64 `mirai:"label=GPU memory of those slots: geometry_memory of Graphics_Settings"`,
    pages_resident:int `mirai:"label=Slots that hold a page"`,
    pages_requested:int `mirai:"label=Pages the views and the ray cuts asked for in the last frame, once each"`,
    pages_loaded:int `mirai:"label=Pages loaded in the last frame"`,
    pages_evicted:int `mirai:"label=Pages that left their slot to others in the last frame"`,
    pages_dropped:int `mirai:"label=Requests of the last frame past the capacity of their list, or whose page found no slot"`,
}

Api_Step_Params :: struct {
    frames:int `mirai:"optional,min=1,max=3600"`,
    dt:f32 `mirai:"optional,min=0.0001,max=0.25,unit=s"`,
}
Api_Step_Result :: struct {frame:u64,dt:f32}

Api_Shutdown_Params :: struct {
    discard:bool `mirai:"optional,label=Quit with unsaved changes"`,
}
Api_Shutdown_Result :: struct {quitting:bool}

Api_Gpu_Lose_Result :: struct {
    asked:bool `mirai:"label=The next submission to the GPU reports the device lost"`,
}

Api_History_Result :: struct {
    undo:int `mirai:"label=The steps the caller can still undo"`,
    redo:int `mirai:"label=The steps the caller can still redo"`,
    kept:int `mirai:"label=The fields the move left as other authors wrote them"`,
}

Api_Select_Params :: struct {
    entities:[64][API_ENTITY_TEXT]u8 `mirai:"optional,text,label=Entities to select by name or path Parent/Child or id or handle (the last one active); none clears the selection"`,
    add:bool `mirai:"optional,label=Add to the selection instead of replacing it"`,
}
Api_Select_Result :: struct {
    selected:int,
    active:base.Entity_Id,
}

Api_Camera_Result :: struct {
    position,target:[3]f32,
    yaw,pitch,distance:f32,
    fov_y:f32,
    exposure:Viewport_Exposure,
    ev100:f32,
}

// Frames an image without the UI is drawn so that what builds up over time settles.
API_CAPTURE_SETTLE :: 8

Api_Play_Result :: struct {
    playing,paused:bool,
    detached:bool `mirai:"label=The run is of a turn: the editor does not show it"`,
    simulating:bool,
    tick:u64,
    seconds:f64,
    entities:int,
    ticks_dropped:u64,
    game_camera:bool,
    input_released:bool,
}


Api_Play_Start_Params :: struct {
    players:int `mirai:"optional,min=0,max=4,label=Local players sharing the screen; 0: the last chosen (a turn: the scene)"`,
    online:int `mirai:"optional,min=-1,max=3,label=Players on the network besides them; the run serves the game. A turn gets a run per online player (player 1 and on) that is a client of its run. -1 outside a turn: those the Play menu of the editor has, asking the person at the editor first about unsaved assets the players would not have"`,
    ping_ms:int `mirai:"optional,min=-1,max=1000,label=Round trip the online players simulate; -1: that of the Play menu"`,
    saved_only:bool `mirai:"optional,label=Outside a turn a game on the network plays with what the files hold although assets have unsaved changes"`,
    simulate:bool `mirai:"optional,label=Simulate the scene instead: the editor camera and no player input; outside a turn and without players or online"`,
    from:Api_Play_From `mirai:"optional,label=Where player 1 gets its first body outside a turn: Scene (the default) at a Spawn_Point or without one at the editor camera; Camera and Point there before any Spawn_Point, standing on what is under it"`,
    point:[3]f32 `mirai:"optional,label=With from Point: where in the world, as scene.raycast gives it"`,
}

Api_Play_From :: enum u8 {Scene,Camera,Point}

Api_Pause_Params :: struct {
    paused:bool `mirai:"optional,label=false resumes"`,
    here:bool `mirai:"optional,label=resumes from the tick play.seek went to and drops the ticks after it"`,
}

Api_Play_Step_Params :: struct {
    using input:Api_Play_Segment `mirai:"inline"`,
    focus:int `mirai:"optional,min=-1,max=3,label=The local seat (by slot) that gets the keys and the mouse from this step on; -1 keeps it"`,
    until:[8]Api_Play_Condition `mirai:"optional,label=It stops after the first tick at which all hold as play.check reads them; for (or those of segments) is the most it runs and none run when they hold already"`,
    player:int `mirai:"optional,min=0,max=3,label=The run that gets the input in a game a turn plays on the network; every run of it advances"`,
    segments:[API_STEP_SEGMENTS]Api_Play_Segment `mirai:"optional,label=Input that changes along the step: each segment holds its input for its ticks and the next one follows; in place of ticks and the input fields"`,
    trace:Api_Play_Trace `mirai:"optional,label=Values of a few entities or of a storage read before the first tick and every some ticks and after the last: the trace of the result"`,
    drive:Api_Play_Drive `mirai:"optional,label=Instead of keys steers the focused player by the move action of the game to a target re-aimed every tick along the navigation meshes when the project has them; jumps at gaps and when blocked and holds the jump as long as it still rises; stops within its distance or standing on a raised target or at for (30 s if not given) or when until holds or when it gets no closer; answers drive with where it ended and why"`,
    drive_ticks:int `mirai:"transient"`, // of a drive given no for
    look_at:Api_Play_Look_At `mirai:"optional,label=Turns what the player sees through toward an entity or a point in every tick of the step; instead of mouse_delta; play.view says where it looks with follow.yaw_deg and follow.pitch_deg"`,
}

Api_Build_Params :: struct {
    target:[8]u8 `mirai:"optional,text,label=editor (the default): the library of the editor, loaded into it; game: the shipped game with its cooked assets; shaders: the shaders of the project published again, answering once the viewport draws with them; built: what a build outside the editor left (mirai build editor): its libraries and its shaders, loaded without building"`,
    out:[512]u8 `mirai:"optional,text,label=For the game: the folder it is built into; empty: .mirai/game of the project"`,
    seconds:int `mirai:"optional,min=1,max=3600,unit=s,label=How long it waits for the end of the build; past that it answers building and the build goes on"`,
}

Api_Play_Gamepad :: struct {
    slot:int `mirai:"min=0,max=3,label=Which gamepad: the local seat of this slot gets it"`,
    buttons:platform.Gamepad_Buttons `mirai:"optional,label=Held in every tick"`,
    tapped:platform.Gamepad_Buttons `mirai:"optional,label=Pressed and released inside the first tick"`,
    left_stick:[2]f32 `mirai:"optional,min=-1,max=1,label=x and y from -1 to 1 with y positive downward"`,
    right_stick:[2]f32 `mirai:"optional,min=-1,max=1,label=x and y from -1 to 1 with y positive downward"`,
    left_trigger:f32 `mirai:"optional,min=0,max=1"`,
    right_trigger:f32 `mirai:"optional,min=0,max=1"`,
}

API_BUILD_DIAGNOSTICS :: 32

Api_Build_Diagnostic :: struct {
    severity:build.Severity,
    file:[API_PATH_BYTES]u8 `mirai:"text,label=Absolute"`,
    line,column:int,
    message:[1024]u8 `mirai:"text"`,
}

Api_Build_Result :: struct {
    building:bool `mirai:"label=It still runs: the wait of build.start ran out or build.status asked while it runs"`,
    restarting:bool `mirai:"label=What was built is not taken in place (a declaration of the engine changed or the worlds do not fit their room): the editor starts again now on it with its documents"`,
    publishing:bool `mirai:"label=Target shaders: the stages the frames do not run are still being compiled"`,
    target:[8]u8 `mirai:"text,label=editor or game: of the build that runs or ran last"`,
    game:[512]u8 `mirai:"text,label=The executable of the game the last build of the game left; player.start with shipped runs it"`,
    phase:Build_Phase,
    errors:int,
    seconds:f64,
    message:[256]u8 `mirai:"text,label=The first error of the build or what failed"`,
    diagnostics:[API_BUILD_DIAGNOSTICS]Api_Build_Diagnostic `mirai:"trim,label=What the compiler said with its file and line; errors first"`,
}

Api_Editor_Inspect :: struct {
    frame:u64,
    selection:[]base.Entity_Id,
    active:base.Entity_Id `mirai:"optional,label=The id of the active entity of the selection; omitted without a selection"`,
    tool:string `mirai:"label=move rotate or scale"`,
    plugin_tool:string `mirai:"optional,label=The plugin tool that is on (such as terrain or foliage) by the name it turns on with"`,
    plugin_tool_aside:bool `mirai:"optional,label=It lent the scene to the gizmo (W or E or R) and stays on"`,
    space:string `mirai:"label=world or local: the axes of the gizmo"`,
    snap,indicators:bool,
    mode:string `mirai:"label=edit play paused simulate simulation_paused or watch"`,
    document:Api_Editor_Document,
    camera:Api_Editor_Camera `mirai:"label=The camera of the viewport"`,
    interactions:Api_Editor_Interactions,
    window:Api_Editor_Window,
    layout:Api_Editor_Layout `mirai:"label=Rectangles as x y width height in points from the top left of the window"`,
    commands:[]Api_Editor_Command `mirai:"label=Every entry of the menus and shortcuts and buttons of the editor and of its plugins: a person runs the method it names"`,
}
Api_Editor_Document :: struct {
    path:string,
    dirty:bool,
    entities:int,
    undo,redo:int,
}
Api_Editor_Camera :: struct {
    position,target:[3]f32,
    yaw:f32 `mirai:"label=Radians"`,
    pitch:f32 `mirai:"label=Radians"`,
    distance:f32,
    fov:f32 `mirai:"label=Vertical degrees"`,
}
Api_Editor_Interactions :: struct {
    captured_by:string `mirai:"label=What holds the pointer in the viewport: look pan select or gizmo; empty when nothing does"`,
    modal:string `mirai:"label=The dialog that blocks the editor: confirm save_changes recovery shortcuts settings delete_asset or git_discard; empty when none does"`,
    recovery_offered:bool `mirai:"label=Whether changes an editor left when it ended wait for editor.recover: they stay set aside until then"`,
    popups:int `mirai:"label=Popups open"`,
    editing_text:bool `mirai:"label=Whether a text field takes the keys"`,
    dialog_pending:bool `mirai:"label=Whether a file dialog of the system waits for an answer"`,
    hovered:bool `mirai:"label=Whether the pointer is over the viewport"`,
}
Api_Editor_Window :: struct {
    present:bool `mirai:"label=Whether the editor has a window; false when headless"`,
    size:[2]f32 `mirai:"label=Points"`,
    minimized,maximized,fullscreen:bool,
}
Api_Editor_Layout :: struct {
    bar,left,right,bottom:[4]f32,
    widgets:serial.Json `mirai:"label=An object whose keys the commands name: The rectangle of each widget drawn by key: command.<name> for the button of an entry; menu.<name> for a menu; stats; share"`,
}
Api_Editor_Command :: struct {
    name:string `mirai:"label=Of the entry: layout.widgets names its button command.<name>"`,
    method:string `mirai:"label=The method it calls"`,
    params:string `mirai:"optional,label=The params it calls it with as JSON; $roots and $selection and $active and $copied and $all stand for entities of the selection of the person; $toggle for the opposite of checked; $ask for a file the person picks: a call names them itself"`,
    label:string,
    shortcut:string `mirai:"optional"`,
    disabled:bool `mirai:"label=The person cannot run it now"`,
    checked:bool,
}

Api_Editor_Input_Params_Events_Mouse_Buttons :: enum u8 {left,right,middle}
Api_Editor_Input_Params_Events :: struct {
    keys:[]string `mirai:"optional,label=keys held in the frame; they replace the previous set"`,
    repeat_keys:[]string `mirai:"optional,label=keys that repeat in the frame"`,
    mouse_buttons:[]Api_Editor_Input_Params_Events_Mouse_Buttons `mirai:"optional,label=buttons held in the frame; they replace the previous set"`,
    mouse_position:[]f32 `mirai:"optional,label=x and y in points; excludes mouse_delta"`,
    mouse_delta:[2]f32 `mirai:"optional,label=points; excludes mouse_position"`,
    wheel:[2]f32 `mirai:"optional,label=x and y; a usual wheel turns y"`,
    text:string `mirai:"optional,label=printable ASCII typed in the frame, up to 32 characters"`,
    clicks:int `mirai:"optional,min=1,max=3"`,
    dt:f64 `mirai:"optional,max=0.25,label=Above 0. seconds"`,
}
Api_Editor_Input_Params :: struct {
    events:[]Api_Editor_Input_Params_Events `mirai:"optional"`,
    dt:f64 `mirai:"optional,max=0.25,label=Above 0. seconds"`,
}

Api_Camera_Set_Params_Exposure :: enum u8 {scene,camera,manual}
Api_Camera_Set_Params :: struct {
    position,target:[3]f32 `mirai:"optional"`,
    yaw,pitch:f32 `mirai:"optional,unit=rad"`,
    distance:f32 `mirai:"optional,label=Above 0"`,
    fov:f32 `mirai:"optional,min=1,max=170,unit=deg,label=Vertical"`,
    entity:Api_Entity_Text `mirai:"text,entity,optional,label=an entity with a perspective Camera by its name, a path Parent/Child, its id or its handle: the camera takes its eye, where it looks and its fov, without changing the scene; excludes position, target, yaw and pitch"`,
    exposure:Api_Camera_Set_Params_Exposure `mirai:"optional,label=how the view exposes: as the Sky that is on, as the Camera of entity, or at ev100"`,
    ev100:f32 `mirai:"optional,min=-10,max=24,label=exposure value at ISO 100 of manual; alone, it chooses manual"`,
    frame:[API_SPATIAL_LIMIT]Api_Entity_Text `mirai:"text,entity,optional,label=entities by name, path or id the camera frames with what hangs from them, looking the way it looks now; excludes position, target and entity"`,
    from:[3]f32 `mirai:"optional,label=with frame: the direction from what is framed to the camera"`,
}

Api_Probe_Diagnostic :: struct {
    severity:string `mirai:"label=Error or Warning"`,
    file:string,
    line,column:int,
    message:string,
}
Api_Build_Check_Result :: struct {
    ok:bool,
    failure:string,
    seconds:f64,
    errors:int,
    diagnostics:[]Api_Probe_Diagnostic,
    text:string `mirai:"label=what the compiler or the tests printed, when they failed"`,
}

Api_Build_Test_Result_Failed :: struct {
    package_:string `mirai:"name=package"`,
    name:string,
    messages:[]string `mirai:"label=what it logged at error level and above, with where"`,
}
Api_Build_Test_Result :: struct {
    probe:Api_Build_Check_Result `mirai:"inline"`,
    compiled:bool `mirai:"label=false: the package did not build; diagnostics say why"`,
    total,passed:int,
    failed:[]Api_Build_Test_Result_Failed,
}

@(private)
api_methods_register :: proc(s:^Session,st:^Api_State) {
    step_default:=Api_Step_Params{frames=1,dt=HEADLESS_DT}
    play_step_default:=Api_Play_Step_Params{focus=-1,trace={every=1},drive={within=API_DRIVE_WITHIN}}
    build_default:=Api_Build_Params{seconds=API_BUILD_SECONDS}
    pause_default:=Api_Pause_Params{paused=true}
    api_register(s,st,{name="engine.status",summary="The state of the editor and of its renderer, and what the last frame cost by part of the main thread and by pass of the GPU.",result=type_info_of(Api_Status),flags={.Read_Only,.As_User},run=api_status})
    api_register(s,st,{name="engine.step",summary="Advances whole frames of editor, game and render with a fixed dt. Manual execution only (headless).",params=type_info_of(Api_Step_Params),result=type_info_of(Api_Step_Result),defaults=&step_default,flags={.As_User},run=api_step})
    api_register(s,st,{name="engine.shutdown",summary="Stops Play and quits the editor after answering. Fails with unsaved changes of scenes or assets unless discard.",params=type_info_of(Api_Shutdown_Params),result=type_info_of(Api_Shutdown_Result),flags={.Destructive,.As_User},run=api_shutdown})
    api_register(s,st,{name="engine.gpu_lose",summary="Makes the next submission to the GPU report the device lost, as a reset of the GPU does, to test what follows: the editor starts again with its documents, and ends if it was started again for a loss less than a minute before.",result=type_info_of(Api_Gpu_Lose_Result),flags={.Destructive,.As_User},run=api_gpu_lose})
    api_register(s,st,{name="editor.inspect",summary="What the editor shows and the entries of its menus, shortcuts and buttons: the method each one calls, with what params, and whether it is off or checked for the person now.",result=type_info_of(Api_Editor_Inspect),flags={.Read_Only},run=api_editor_inspect})
    api_register(s,st,{name="editor.recover",summary="Recovers what an editor that ended left unsaved, or discards it; until then it stays set aside, whatever is edited or saved meanwhile, and a tab with changes stays as it is. With nothing offered it answers resolved false.",params=type_info_of(Api_Recovery_Params),result=type_info_of(Api_Recovery_Result),flags={.Idempotent},run=api_recover})
    api_register(s,st,{name="editor.section_edit",summary="Edits the section of a Scene_Reference in its world: its entities are edited here, scene.save writes its scene too, and everything else reads only. id 0 stops. Returns the reference edited.",params=type_info_of(Api_Section_Edit_Params),result=type_info_of(Api_Section_Edit_Result),run=api_section_edit})
    api_register(s,st,{name="editor.section_preview",summary="Draws the sky and the sun of the section of a Scene_Reference instead of those on, in the view of the editor only: not an edit, not saved, and Play starts without it. id 0 goes back. Returns the sky and the sun drawn.",params=type_info_of(Api_Section_Preview_Params),result=type_info_of(Api_Section_Preview_Result),run=api_section_preview})
    api_register(s,st,{name="editor.sections",summary="The sections of the scene as the World panel maps them: each Scene_Reference with its rule, the state it asks, what the view of the editor asks of it (view; Auto for nothing) and what it shows, its box, and what it costs (entities, meshes and textures of its scene, GPU bytes they hold now and bytes of their files); with the sources the sections stream around and the camera of the editor.",flags={.Read_Only},result=type_info_of(Api_Sections_Result),run=api_sections})
    api_register(s,st,{name="editor.section_view",summary="Turns a section on (Active), loaded and off (Loaded) or off (Unloaded) in the view of the editor alone, or gives it back to what its reference asks (Auto): not an edit, not in the undo and not saved; Play starts with what the references ask. It loads over the next frames: shown in editor.sections says when it is there. Returns the section.",params=type_info_of(Api_Section_View_Params),flags={.Idempotent,.View},result=type_info_of(Api_Section),run=api_section_view})
    api_register(s,st,{name="editor.section_travel",summary="Brings the camera of the editor to a section, framing its box (into it when the box is big), and turns it on in the view when what asks for it does not. Returns the section.",params=type_info_of(Api_Section_Id_Params),result=type_info_of(Api_Section),flags={.View},run=api_section_travel})
    api_register(s,st,{name="editor.select",summary="Sets the selection of the editor: the entities the panels and the tools act on.",params=type_info_of(Api_Select_Params),result=type_info_of(Api_Select_Result),flags={.Idempotent,.View},run=api_editor_select})
    api_register(s,st,{name="editor.input",params=type_info_of(Api_Editor_Input_Params),summary="Runs a frame per event of synthetic input through the path of real input. Manual execution only (headless).",result=type_info_of(Api_Editor_Inspect),flags={.As_User},run=api_editor_input})
    api_register(s,st,{name="camera.set",params=type_info_of(Api_Camera_Set_Params),summary="Moves the camera of the editor, or looks through a Camera of the scene without changing it, and chooses how the view is exposed.",result=type_info_of(Api_Camera_Result),flags={.Idempotent,.View},run=api_camera_set})
    api_register(s,st,{name="history.undo",flags={.Core},summary="Undoes the last edit of the caller (its turn, or the API outside a turn), even after edits of others, keeping every field they changed since.",params=type_info_of(Api_History_Params),result=type_info_of(Api_History_Result),run=api_undo})
    api_register(s,st,{name="history.redo",summary="Redoes the edit the last undo of the caller took back, keeping every field others changed since; a new edit of the caller drops what it can redo.",params=type_info_of(Api_History_Params),result=type_info_of(Api_History_Result),run=api_redo})
    api_register(s,st,{name="play.start",flags={.Core,.Draws},summary="Plays a copy of the scene: a game the caller already plays goes on and answers its state while the document is as it was when it started, and starts again when it changed. Outside a turn, in the editor; in a turn, a run of its own the editor does not show and only play.step advances. Up to three turns play besides the user. When an Odin source changed since the last build, it builds first and answers when the game plays, or fails with what the compiler said.",params=type_info_of(Api_Play_Start_Params),result=type_info_of(Api_Play_Result),run=api_play_start})
    api_register(s,st,{name="play.stop",flags={.Core,.Idempotent},summary="Ends the game of the caller (its turn, or the user outside a turn, with its game on the network) and discards what it changed.",result=type_info_of(Api_Play_Result),run=api_play_stop})
    api_register(s,st,{name="play.pause",summary="Pauses the game, or resumes it with paused false: from the newest tick it played, or with here from the tick play.seek went to.",params=type_info_of(Api_Pause_Params),result=type_info_of(Api_Play_Result),defaults=&pause_default,run=api_play_pause})
    api_register(s,st,{name="play.step",flags={.Core},summary="Pauses the game and runs exactly the fixed ticks asked for with the input given (keys, mouse, pointer and text for its UI, gamepads of the local seats), or until conditions hold; keys held by consecutive calls stay down and a call that omits one releases it; segments change the input along the ticks, press clicks a button of its UI by name, drive steers the focused player to a target and a trace reads values along them.",params=type_info_of(Api_Play_Step_Params),result=type_info_of(Api_Play_Step_Result),defaults=&play_step_default,run=api_play_step})
    api_register(s,st,{name="play.status",summary="State of the game.",result=type_info_of(Api_Play_Result),flags={.Read_Only},run=api_play_status})
    api_register(s,st,{name="build.start",flags={.Core},summary="Builds the editor of the project, whose new code loads into the running editor when it succeeds, the game to ship, which leaves the editor as it is, or its shaders; answers when it ends, with each error and its file and line.",params=type_info_of(Api_Build_Params),result=type_info_of(Api_Build_Result),defaults=&build_default,run=api_build_start})
    api_register(s,st,{name="build.status",summary="State of the build and what the compiler said, with file and line.",result=type_info_of(Api_Build_Result),flags={.Core,.Read_Only},run=api_build_status})
    check_defaults:=Api_Build_Check_Params{seconds=300}
    api_register(s,st,{name="build.check",summary="Checks the types of the code of the project, its game, editor and plugins, without building or loading anything; answers when it ends, with each error and its file and line.",params=type_info_of(Api_Build_Check_Params),defaults=&check_defaults,result=type_info_of(Api_Build_Check_Result),flags={.Core,.Read_Only},run=api_build_check})
    test_defaults:=Api_Build_Test_Params{seconds=600}
    api_register(s,st,{name="build.test",summary="Builds and runs the @(test) procedures of a package of the project against the engine it uses, without loading anything; answers when they end, with each failed test and what it logged.",params=type_info_of(Api_Build_Test_Params),defaults=&test_defaults,result=type_info_of(Api_Build_Test_Result),flags={.Read_Only},run=api_build_test})
    api_play_record_register(s,st)
    api_play_history_register(s,st)
    api_register(s,st,{name="batch",flags={.Core},params=type_info_of(api.Batch_Params),summary=api.BATCH_SUMMARY,result=type_info_of(api.Batch_Result),run=proc(s:^Session,call:^api.Call) {api.batch(call)}})
    api_scene_register(s,st)
    api_names_register(s,st)
    api_simulation_register(s,st)
    api_assets_register(s,st)
    unsaved_api_register(s,st)
    prefab_api_register(s,st)
    documents_api_register(s,st)
    collab_api_register(s,st)
    watch_api_register(s,st)
    tools_api_register(s,st)
    git_api_register(s,st)
    view_modes_api_register(s,st)
    panels_api_register(s,st)
    profile_api_register(s,st)
    api_play_edit_register(s,st)
    api_play_wait_register(s,st)
    api_play_scenario_register(s,st)
    spatial_api_register(s,st)
    play_observe_api_register(s,st)
    play_view_api_register(s,st)
    save_api_register(s,st)
    api_diagnostics_register(s,st)
}

// ---------------------------------------------------------------- frames

// Advances frames from inside a method. A manual editor gives each the same dt.
@(private)
api_frames :: proc(s:^Session,count:int,dt:f32) -> int {
    st:=api_state(s)
    p:=s.app.platform
    saved:=p.fixed_dt
    if st.manual && dt>0 {p.fixed_dt=dt}
    // A method a frame of another one runs (a gesture inside editor.input) leaves it stepping.
    stepping:=st.stepping
    st.stepping=true
    done:=0
    for _ in 0..<count {
        done+=1
        start:=time.tick_now()
        running:=advance(s)
        profile_sample(s,start)
        if !running {break}
    }
    st.stepping=stepping
    p.fixed_dt=saved
    return done
}

@(private)
api_manual_required :: proc(s:^Session,call:^api.Call) -> bool {
    if st:=api_state(s);st!=nil && st.manual {return true}
    api.call_fail(call,api.SERVER_ERROR,"This editor draws by itself: engine.step and editor.input run only in a manual one, which mirai session start opens. Here play.step drives a game and the methods editor.inspect lists in commands do what the menus do")
    return false
}

API_FUNCTIONS :: 16

// The functions that cost the most per frame since the last read, and the count starts again.
@(private)
functions_fill :: proc(s:^Session,st:^Api_State,r:^Api_Status) {
    app:=s.app
    frames:=app.stats.frames-st.step_frames
    if frames>0 && s.info!=nil {
        top:[API_FUNCTIONS]struct{index:int,ns:u64}
        for &slot in top {slot.index=-1}
        for ns,i in app.step_ns {
            if ns==0 || i>=len(s.info.steps) {continue}
            at:=API_FUNCTIONS
            for at>0 && (top[at-1].index<0 || top[at-1].ns<ns) {at-=1}
            if at>=API_FUNCTIONS {continue}
            copy(top[at+1:],top[at:API_FUNCTIONS-1])
            top[at]={i,ns}
        }
        for slot,i in top {
            if slot.index<0 {break}
            base.text_set(r.functions[i].name[:],s.info.steps[slot.index].name)
            r.functions[i].ms=f32(f64(slot.ns)/f64(frames)/1e6)
        }
    }
    for &ns in app.step_ns {ns=0}
    st.step_frames=app.stats.frames
}

@(private)
api_status :: proc(s:^Session,call:^api.Call) {
    r:=api.call_result(call,Api_Status)
    st:=api_state(s)
    app:=s.app
    status_value:=status(s)
    r.frame,r.mode=s.frame,s.mode
    r.entities,r.selected=status_value.entities,status_value.selected
    r.dirty,r.headless,r.manual,r.gpu_enabled,r.has_project=status_value.dirty,s.headless,st.manual,app.renderer!=nil,s.has_project
    base.text_set(r.document[:],status_value.document)
    r.fps=s.app.stats.fps
    r.undo,r.redo=status_value.undo,status_value.redo
    r.ticks_dropped,r.extras_dropped=app.stats.ticks_dropped,app.extras.dropped
    a:=api_of(s)
    functions_fill(s,st,r)
    r.cpu={
        platform_ms=app.stats.platform_ms,watch_ms=app.stats.watch_ms,game_ms=app.stats.game_ms,editor_ms=app.stats.editor_ms,
        editor_begin_ms=a.begin_ms,editor_tools_ms=a.tools_ms,editor_ui_ms=a.panels_ms,editor_end_ms=a.end_ms,
        render_ms=app.stats.render_ms,app_ms=app.stats.frame_ms,
    }
    if renderer:=app.renderer;renderer!=nil {
        stats:=gpu.renderer_stats(renderer)
        r.render_width,r.render_height=int(stats.render_width),int(stats.render_height)
        r.instances,r.visible_instances,r.lights=int(stats.instances),int(stats.visible_instances),int(stats.lights)
        r.tlas_instances=int(stats.tlas_instances)
        for counter,i in stats.counters[:min(len(stats.counters),API_COUNTERS)] {r.counters[i]={counter.name,counter.values}}
        r.visible_triangles=int(stats.visible_triangles)
        for kind,k in ([3]^Api_Visible{&r.visible_kinds.levels,&r.visible_kinds.single,&r.visible_kinds.batches}) {
            from:=stats.visible_kinds[gpu.Visible_Kind_Id(k)]
            kind^={int(from.instances),int(from.clusters),int(from.triangles)}
        }
        late:=stats.visible_late
        r.visible_kinds.late={int(late.instances),int(late.clusters),int(late.triangles)}
        for dropped,k in stats.cull_dropped {r.visible_kinds.dropped[k]=int(dropped)}
        r.gpu_ms,r.ev100=stats.gpu_ms,stats.ev100
        r.probes_traced=int(stats.probes_traced)
        r.textures.bytes,r.textures.view_bytes=stats.texture_bytes,stats.view_target_bytes
        r.textures.pending,r.textures.reduced=int(stats.textures_pending),int(stats.textures_reduced)
        r.geometry={
            bytes=stats.geometry_bytes,free_bytes=stats.geometry_free,free_largest=stats.geometry_free_largest,ray_bytes=stats.ray_bytes,page_slots=int(stats.page_slots),page_bytes=stats.page_region_bytes,
            pages_resident=int(stats.pages_resident),pages_requested=int(stats.pages_requested),pages_loaded=int(stats.pages_loaded),
            pages_evicted=int(stats.pages_evicted),pages_dropped=int(stats.page_requests_dropped),
        }
        r.cpu.render_prepare_ms,r.cpu.render_begin_ms=stats.cpu_prepare_ms,stats.cpu_begin_ms
        r.cpu.render_record_ms,r.cpu.render_end_ms=stats.cpu_record_ms,stats.cpu_end_ms
        for timing,i in stats.timings[:min(len(stats.timings),API_TIMINGS)] {
            base.text_set(r.gpu_timings[i].name[:],timing.name)
            r.gpu_timings[i].ms=timing.ms
        }
        backend,_:=reflect.enum_name_from_value(stats.backend)
        base.text_set(r.backend[:],backend)
        base.text_set(r.device[:],stats.device_name)
        if app.device!=nil {
            r.validation_errors=rhi.device_validation_errors(app.device)
            used,budget:=rhi.device_memory(app.device)
            r.gpu_memory={f32(f64(used)/(1<<20)),f32(f64(budget)/(1<<20))}
        }
        base.text_set(r.renderer_problem[:],stats.problem)
    }
    if a:=app.assets;a!=nil {
        r.asset_errors=len(host.assets_errors(a))+len(a.registry.reassigned)+len(a.registry.duplicates)
        r.assets={a.stats.meshes,a.stats.textures,a.stats.materials,a.stats.scenes,a.stats.unloads}
        r.textures.streamed=a.stats.streamed
    }
    r.ui_dropped=s.gui.dropped
    r.build,r.build_errors=s.build.phase,len(s.build.diagnostics)
    if len(s.build.diagnostics)>0 {base.text_set(r.build_message[:],s.build.diagnostics[0].message)}
    base.text_set(r.collab[:],collab_summary(s))
    r.api_calls,r.api_errors=st.server.stats.calls,st.server.stats.errors
}

@(private)
api_step :: proc(s:^Session,call:^api.Call) {
    params:=api.call_params(call,Api_Step_Params)
    if !api_manual_required(s,call) {return}
    api_frames(s,params.frames,params.dt)
    api.call_result(call,Api_Step_Result)^={s.frame,params.dt}
}

@(private)
api_shutdown :: proc(s:^Session,call:^api.Call) {
    if api_turn_refused(s,call,"quit the editor") {return}
    params:=api.call_params(call,Api_Shutdown_Params)
    if documents_dirty(s) && !params.discard {
        api.call_fail(call,api.SERVER_ERROR,"The scene has unsaved changes; save it first or pass discard")
        return
    }
    if unsaved:=assets_unsaved(s);len(unsaved)>0 && !params.discard {
        names:=make([dynamic]string,context.temp_allocator)
        for held in unsaved[:min(len(unsaved),API_UNSAVED_NAMED)] {append(&names,unsaved_name(s,held.path))}
        more:=len(unsaved)>API_UNSAVED_NAMED?fmt.tprintf(" and %d more",len(unsaved)-API_UNSAVED_NAMED):""
        api.call_failf(call,api.SERVER_ERROR,"Unsaved changes in %s%s; asset.save writes them, or pass discard",strings.join(names[:],", ",context.temp_allocator),more)
        return
    }
    if platform.dialog_pending(s.app.platform) {
        api.call_fail(call,api.SERVER_ERROR,"A file dialog is open; answer it first")
        return
    }
    runs_stop(s)
    s.quit=true
    api.call_result(call,Api_Shutdown_Result).quitting=true
}

@(private)
api_gpu_lose :: proc(s:^Session,call:^api.Call) {
    if api_turn_refused(s,call,"stop the GPU") {return}
    if s.app.device==nil {
        api.call_fail(call,api.SERVER_ERROR,"The editor has no GPU device: it was started with --no-gpu")
        return
    }
    rhi.device_lose(s.app.device)
    api.call_result(call,Api_Gpu_Lose_Result).asked=true
}

// ---------------------------------------------------------------- history

// A manual editor runs a frame after undo and redo: what the steps of the
// plugins derive from the history (the file of a terrain takes the revision
// of its owners) is there before the answer, as with a window.
@(private)
api_history_result :: proc(s:^Session,call:^api.Call,kept:=0) {
    if st:=api_state(s);st!=nil && st.manual {api_frames(s,1,0)}
    api.call_result(call,Api_History_Result)^={history.edits_undo_count(s.edits),history.edits_redo_count(s.edits),kept}
}

Api_History_Params :: struct {
    asset:[API_PATH_BYTES]u8 `mirai:"text,optional,label=An asset with a document open in the editor (editor.documents lists them): its history, which is that of the document and not of a caller, in place of that of the scene"`,
}

// The history of the document of the asset a call names; nil for the scene, and after failing the call.
@(private)
api_document_history :: proc(s:^Session,call:^api.Call) -> ^Asset_History {
    name:=base.text_get(api.call_params(call,Api_History_Params).asset[:])
    if name=="" {return nil}
    if _,shown:=api_document_named(s,name);shown>=0 {return &s.asset_documents[shown].history}
    api.call_failf(call,api.INVALID_PARAMS,"asset: %q has no document open: editor.documents lists them; without asset the history is that of the scene",name)
    return nil
}

@(private)
api_undo :: proc(s:^Session,call:^api.Call) {
    preview:=s.edits.preview
    h:=api_document_history(s,call)
    if call.failed {return}
    if h!=nil {
        tools_release(s)
        if asset_history_undo(h) {notify(s,fmt.tprintf("Undo %s",history.cstring_text(h.steps[h.cursor].label[:])))}
        api.call_result(call,Api_History_Result)^={h.cursor,len(h.steps)-h.cursor,0}
        return
    }
    if !api_guard(s,call) {return}
    if preview {api_history_result(s,call);return}
    move:=history_undo(s)
    if text:=history_text(move,"Undo");text!="" {notify(s,text)}
    if !move.done {
        api.call_fail(call,api.SERVER_ERROR,move.error if move.error!="" else "Nothing to undo: the caller has no edit of its own left (an agent's turn undoes its own edits, the API outside a turn its own)")
        return
    }
    api_history_result(s,call,move.kept)
}

@(private)
api_redo :: proc(s:^Session,call:^api.Call) {
    h:=api_document_history(s,call)
    if call.failed {return}
    if h!=nil {
        tools_release(s)
        if asset_history_redo(h) {notify(s,fmt.tprintf("Redo %s",history.cstring_text(h.steps[h.cursor-1].label[:])))}
        api.call_result(call,Api_History_Result)^={h.cursor,len(h.steps)-h.cursor,0}
        return
    }
    if !api_guard(s,call) {return}
    move:=history_redo(s)
    if text:=history_text(move,"Redo");text!="" {notify(s,text)}
    if !move.done {
        api.call_fail(call,api.SERVER_ERROR,move.error if move.error!="" else "Nothing to redo: the caller undid nothing since its last edit")
        return
    }
    api_history_result(s,call,move.kept)
}

// ---------------------------------------------------------------- selection and actions

@(private)
api_editor_select :: proc(s:^Session,call:^api.Call) {
    params:=api.call_params(call,Api_Select_Params)
    w:=shown_world(s)
    if s.edits.preview {tools_release(s)}
    picked,known:=api_call_entities(call,w,params.entities[:],"entities",call.allocator)
    if !known {return}
    tools_release(s)
    if len(picked)==0 && !params.add {history.selection_clear(s.selection)} else {history.selection_set(s.selection,picked,params.add)}
    api.call_result(call,Api_Select_Result)^={len(s.selection.entities),api_entity_id(w,history.selection_active(s.selection))}
}

// ---------------------------------------------------------------- editor.inspect

@(private)
api_editor_inspect_value :: proc(s:^Session,allocator:=context.temp_allocator) -> (r:Api_Editor_Inspect) {
    v:=s.viewport
    g:=s.gui
    world:=shown_world(s)
    r.frame=s.frame
    r.selection=make([]base.Entity_Id,len(s.selection.entities),allocator)
    for e,i in s.selection.entities {r.selection[i]=api_entity_id(world,e)}
    r.active=api_entity_id(world,history.selection_active(s.selection))
    tool,_:=reflect.enum_name_from_value(v.tool)
    r.tool=api_lower(tool)
    // A plugin tool that holds the scene is the tool; one that lent it to the gizmo is the plugin.
    if v.plugin_tool!=0 {r.plugin_tool,r.plugin_tool_aside=strings.clone(base.text_get(v.plugin_tool_name[:]),allocator),v.plugin_aside}
    r.space="world" if v.space==.World else "local"
    r.snap,r.indicators=snapping(v,.Move),v.show_indicators
    mode,_:=reflect.enum_name_from_value(s.mode)
    r.mode=api_lower(mode)
    r.document={document_path(s.document),document_dirty(s),core.world_entities(world).alive,history.edits_undo_count(s.edits),history.edits_redo_count(s.edits)}
    r.camera={orbit_position(v.orbit),v.orbit.target,v.orbit.yaw,v.orbit.pitch,v.orbit.distance,v.orbit.fov}
    capture,_:=reflect.enum_name_from_value(v.capture)
    modal,_:=reflect.enum_name_from_value(g.modal)
    r.interactions={"" if v.capture==.None else api_lower(capture),"" if g.modal==.None else api_lower(modal),s.recovery.pending,g.ctx.popup.count,g.ctx.edit.id!=0,platform.dialog_pending(s.app.platform),v.hovered}
    window:=platform.input_frame(s.app.platform).window
    r.window={!s.headless,{f32(window.size.x),f32(window.size.y)},window.minimized,window.maximized,window.fullscreen}
    rect :: proc(rect:ui.Rect) -> [4]f32 {return {rect.x,rect.y,rect.w,rect.h}}
    r.layout={bar=rect(g.rects.bar),left=rect(g.rects.left),right=rect(g.rects.right),bottom=rect(g.rects.bottom)}
    widgets:serial.Writer
    serial.writer_init(&widgets,0,allocator)
    serial.write_u8(&widgets,'{')
    widget :: proc(w:^serial.Writer,s:^Session,key:string,id:ui.Id) {
        found,drawn:=ui.widget_rect(s.gui.ctx,id)
        if !drawn {return}
        if w.count>1 {serial.write_u8(w,',')}
        serial.text_write_string(w,key);serial.text_write_raw(w,": ")
        api.write_list(w,{found.x,found.y,found.w,found.h})
    }
    for &b in command_bindings(s) {widget(&widgets,s,fmt.tprintf("command.%s",b.name),command_widget(g,b.name))}
    widget(&widgets,s,"menu.file",shell_id(g,"menu",1))
    widget(&widgets,s,"menu.view",shell_id(g,"menu",4))
    widget(&widgets,s,"stats",shell_id(g,"stats"))
    widget(&widgets,s,"share",shell_id(g,"share"))
    serial.write_u8(&widgets,'}')
    r.layout.widgets=serial.Json(string(serial.writer_bytes(&widgets)))
    r.commands=api_commands(s,allocator)
    return
}

@(private)
api_editor_inspect :: proc(s:^Session,call:^api.Call) {
    api.call_result(call,Api_Editor_Inspect)^=api_editor_inspect_value(s,call.allocator)
}

// ---------------------------------------------------------------- editor.input

@(private)
Api_Input_Step :: struct {
    keys,repeat:platform.Keys,
    buttons:platform.Mouse_Buttons,
    position,delta,wheel:[2]f32,
    has_position:bool,
    clicks:u8,
    text:[32]u8,
    text_length:int,
    dt:f32,
}

@(private)
api_key_from_name :: proc(name:string) -> (key:platform.Key,ok:bool) {
    index,_:=base.name_find(name,reflect.enum_field_names(platform.Key))
    if index<0 {return}
    return platform.Key(index),true
}

// Keys by their platform.Key names.
@(private)
api_keys :: proc(call:^api.Call,names:[]string,what:string) -> (keys:platform.Keys,ok:bool) {
    for name in names {
        key,known:=api_key_from_name(name)
        if !known {api.call_failf(call,api.INVALID_PARAMS,"%s: %s; keys go by their platform.Key name, such as A, F5, Enter, Space, Left_Shift, Left_Control or Left_Super (Command on a Mac)",what,base.name_problem(name,"a key",reflect.enum_field_names(platform.Key)));return}
        keys+={key}
    }
    return keys,true
}

@(private)
api_dt_valid :: proc "contextless" (dt:f32) -> bool {return rpc_finite(dt) && dt>0 && dt<=API_DT_MAX}

@(private)
api_input_step :: proc(call:^api.Call,event:Api_Editor_Input_Params_Events,at:int) -> (step:Api_Input_Step,ok:bool) {
    step.keys=api_keys(call,event.keys,fmt.tprintf("events[%d].keys",at)) or_return
    step.repeat=api_keys(call,event.repeat_keys,fmt.tprintf("events[%d].repeat_keys",at)) or_return
    buttons:=[Api_Editor_Input_Params_Events_Mouse_Buttons]platform.Mouse_Button{.left=.Left,.right=.Right,.middle=.Middle}
    for button in event.mouse_buttons {step.buttons+={buttons[button]}}
    switch len(event.mouse_position) {
    case 0:
    case 2: step.position,step.has_position={event.mouse_position[0],event.mouse_position[1]},true
    case: api.call_failf(call,api.INVALID_PARAMS,"events[%d].mouse_position must be x and y",at);return
    }
    step.delta,step.wheel,step.clicks,step.dt=event.mouse_delta,event.wheel,u8(event.clicks),f32(event.dt)
    if step.has_position && step.delta!={} {api.call_failf(call,api.INVALID_PARAMS,"events[%d]: mouse_position and mouse_delta exclude each other",at);return}
    if step.repeat-step.keys!={} {api.call_failf(call,api.INVALID_PARAMS,"events[%d]: repeat_keys must be held in keys",at);return}
    if event.dt!=0 && !api_dt_valid(step.dt) {api.call_failf(call,api.INVALID_PARAMS,"events[%d].dt must be greater than 0 and at most 0.25 seconds",at);return}
    if len(event.text)>len(step.text) {api.call_failf(call,api.INVALID_PARAMS,"events[%d].text has more than %d characters",at,len(step.text));return}
    for character in transmute([]u8)event.text {
        if character<32 || character>126 {api.call_failf(call,api.INVALID_PARAMS,"events[%d].text must be printable ASCII",at);return}
    }
    step.text_length=copy(step.text[:],event.text)
    return step,true
}

@(private)
api_editor_input :: proc(s:^Session,call:^api.Call) {
    if !api_manual_required(s,call) {return}
    params:=api.call_params(call,Api_Editor_Input_Params)
    if len(params.events)==0 || len(params.events)>API_INPUT_EVENTS {
        api.call_failf(call,api.INVALID_PARAMS,"events must have 1 to %d entries",API_INPUT_EVENTS)
        return
    }
    dt:=HEADLESS_DT
    if api.call_given(call,"dt") {
        if !api_dt_valid(f32(params.dt)) {api.call_fail(call,api.INVALID_PARAMS,"dt must be greater than 0 and at most 0.25 seconds");return}
        dt=f32(params.dt)
    }
    steps:=make([]Api_Input_Step,len(params.events),call.allocator)
    for event,i in params.events {
        step,ok:=api_input_step(call,event,i)
        if !ok {return}
        steps[i]=step
    }
    p:=s.app.platform
    for &step in steps {
        frame:=platform.input_frame(p)
        held_keys,held_buttons:=frame.keys_down,frame.mouse_down
        position:=frame.mouse_inside?frame.mouse_position:[2]f32{}
        if step.has_position {
            position=step.position
            platform.input_inject(p,platform.Mouse_Motion_Event{position=position})
        } else if step.delta!={} {
            position+=step.delta
            platform.input_inject(p,platform.Mouse_Motion_Event{position=position,delta=step.delta})
        }
        for key in platform.Key {
            switch {
            case key in step.keys && key not_in held_keys: platform.input_inject(p,platform.Key_Event{key=key,down=true})
            case key in step.repeat:                       platform.input_inject(p,platform.Key_Event{key=key,down=true,repeat=true})
            case key not_in step.keys && key in held_keys: platform.input_inject(p,platform.Key_Event{key=key,down=false})
            }
        }
        for button in platform.Mouse_Button {
            down:=button in step.buttons
            if down==(button in held_buttons) {continue}
            platform.input_inject(p,platform.Mouse_Button_Event{button=button,down=down,clicks=max(step.clicks,1),position=position})
        }
        if step.wheel!={} {platform.input_inject(p,platform.Mouse_Wheel_Event{delta=step.wheel})}
        if step.text_length>0 {platform.input_inject_text(p,string(step.text[:step.text_length]))}
        if api_frames(s,1,step.dt>0?step.dt:dt)==0 || s.quit {break}
    }
    api.call_result(call,Api_Editor_Inspect)^=api_editor_inspect_value(s,call.allocator)
}

// ---------------------------------------------------------------- camera and capture

@(private)
api_camera_set :: proc(s:^Session,call:^api.Call) {
    p:=api.call_params(call,Api_Camera_Set_Params)
    v:=s.viewport
    orbit:=v.orbit
    position,target,from:=p.position,p.target,p.from
    has_position,has_target,has_from:=api.call_given(call,"position"),api.call_given(call,"target"),api.call_given(call,"from")
    has_angles:=api.call_given(call,"yaw") || api.call_given(call,"pitch")
    if api.call_given(call,"yaw") {orbit.yaw=p.yaw}
    if api.call_given(call,"pitch") {orbit.pitch=p.pitch}
    if api.call_given(call,"distance") {
        if p.distance<=0 {api.call_fail(call,api.INVALID_PARAMS,"distance must be greater than 0");return}
        orbit.distance=p.distance
    }
    fov,has_fov:=p.fov,api.call_given(call,"fov")
    entity,has_entity:=base.text_get(p.entity[:]),api.call_given(call,"entity")
    exposure:core.View_Exposure
    source,has_source:=v.exposure_source,api.call_given(call,"exposure")
    if has_source {
        switch p.exposure {
        case .scene:  source=.Scene
        case .camera: source=.Camera
        case .manual: source=.Manual
        }
    }
    ev100:=v.ev100
    if api.call_given(call,"ev100") {
        ev100=p.ev100
        if !has_source {source=.Manual}
    }
    frame_texts:=p.frame
    framed,_:=api.params_array_count(call,"frame")
    if has_entity {
        if has_position || has_target || has_angles {
            api.call_fail(call,api.INVALID_PARAMS,"entity places the camera: leave out position, target, yaw and pitch")
            return
        }
        w:=shown_world(s)
        e,problem:=api_entity_select(w,entity,allocator=call.allocator)
        if problem!="" {
            api.call_fail(call,api.INVALID_PARAMS,problem)
            return
        }
        camera,found:=entity_get(w,e,erender.Camera)
        if !found {
            api.call_failf(call,api.INVALID_PARAMS,"entity %q has no Camera; scene.inspect with component Camera lists those that do",entity)
            return
        }
        if camera.projection!=.Perspective {
            api.call_failf(call,api.INVALID_PARAMS,"entity %q has an orthographic Camera; the camera of the editor is perspective",entity)
            return
        }
        orbit_sanitize(&orbit)
        seen,ok:=orbit_of_camera(entity_world(w,e),camera,orbit.distance)
        if !ok {
            api.call_failf(call,api.SERVER_ERROR,"entity %q has no usable orientation",entity)
            return
        }
        orbit=seen
        exposure={}
        if metered,has:=entity_get(w,e,erender.Exposure);has {exposure=erender.exposure_of(metered)}
        if !has_source {source=exposure.own?.Camera:.Scene}
    } else if source==.Camera && has_source {
        api.call_fail(call,api.INVALID_PARAMS,"exposure camera takes the exposure of the camera given in entity")
        return
    } else {
        exposure=v.exposure
        if !has_source && source==.Camera && (has_position || has_target || has_angles) {source=.Scene}
    }
    if framed>0 {
        if has_position || has_target || has_entity {
            api.call_fail(call,api.INVALID_PARAMS,"frame places the camera: leave out position, target and entity")
            return
        }
        if has_from && from=={} {api.call_fail(call,api.INVALID_PARAMS,"from is the direction from what is framed to the camera: it cannot be zero");return}
        w:=shown_world(s)
        entities,known:=api_call_entities(call,w,frame_texts[:framed],"frame",call.allocator)
        if !known {return}
        box:=api_entities_box(s,w,entities)
        if has_from {
            center:=(box.min+box.max)*0.5
            if placed,placeable:=orbit_from_points(center+from,center,orbit.fov);placeable {orbit=placed}
        }
        free:=free_region(s.gui,v.window)
        free.x-=v.origin.x
        free.y-=v.origin.y
        orbit_frame(&orbit,box.min,box.max,v.size,free)
    }
    if has_target {orbit.target=target}
    if has_position {
        placed,ok:=orbit_from_points(position,orbit.target,orbit.fov)
        if !ok {
            api.call_fail(call,api.INVALID_PARAMS,"position and target must be different points")
            return
        }
        orbit=placed
    }
    if has_fov {orbit.fov=fov}
    orbit_sanitize(&orbit)
    v.orbit=orbit
    v.exposure,v.exposure_source,v.ev100=exposure,source,ev100
    viewport_camera(v)
    s.view_cut=true
    api.call_result(call,Api_Camera_Result)^={orbit_position(orbit),orbit.target,orbit.yaw,orbit.pitch,orbit.distance,orbit.fov,source,ev100}
}

// Writes pixels of the allocator of the application as the PNG at file, of
// api_output_file, and answers the call with it as capture does: its path and
// size and, when shown, the image over MCP.
api_capture_answer :: proc(s:^Session,call:^api.Call,file:string,pixels:[]u8,width,height:int,shown:=true,seen:=Api_Capture_Seen{}) {
    if problem:=api_png_write(s,file,pixels,width,height);problem!="" {api.call_fail(call,api.SERVER_ERROR,problem);return}
    api_capture_reply(call,file,width,height,shown,seen)
}

// The file a capture writes: path as api_output_file takes it, or name under
// .mirai/captures of the project without one.
api_capture_file :: proc(s:^Session,call:^api.Call,path,name:string,allocator:=context.allocator) -> (file:string,ok:bool) {
    if path!="" {return api_output_file(s,call,path,allocator)}
    if s.project_root=="" {api.call_fail(call,api.INVALID_PARAMS,"path is required without a project");return "",false}
    return api_output_file(s,call,fmt.tprintf(".mirai/captures/%s",name),allocator)
}

// The file that path names, absolute with forward slashes. path is written
// as Windows or Git Bash (/c/...) writes it, or relative to root, the folder
// of the project, or to the working folder without one. problem says what
// is wrong with path.
api_file_path :: proc(root,path:string,allocator:=context.allocator) -> (file,problem:string) {
    inside:=root!=""?fmt.tprintf("the folder of the project, %s",root):"the working folder"
    if path=="" {return "",fmt.tprintf("path is required: a file absolute or relative to %s",inside)}
    native,ok:=project.path_native(path)
    if !ok {return "",fmt.tprintf("%s: %s, or relative to %s",path,document_error_text(.Bad_Path),inside)}
    if root!="" && !filepath.is_abs(native) {native=project.path(root,native,allocator=context.temp_allocator)}
    return project.path_absolute(native,allocator),""
}

// The file a method is about to write, from path (api_file_path), in
// allocator: its folder is made, and the call fails saying why when the file
// cannot be written, before the work that would be lost.
api_output_file :: proc(s:^Session,call:^api.Call,path:string,allocator:=context.allocator) -> (file:string,ok:bool) {
    problem:string
    file,problem=api_file_path(s.project_root,path,context.temp_allocator)
    if problem!="" {api.call_fail(call,api.INVALID_PARAMS,problem);return "",false}
    if problem,code:=api_output_prepare(file);problem!="" {api.call_fail(call,code,problem);return "",false}
    return strings.clone(file,allocator),true
}

// Makes the folder of file, absolute, and opens it to write without
// changing it; problem says why it cannot be written, with the code of the error.
api_output_prepare :: proc(file:string) -> (problem:string,code:int) {
    if os.is_dir(file) {return fmt.tprintf("%s is a folder: name the file inside it",file),api.INVALID_PARAMS}
    if folder:=os.dir(file);!os.is_dir(folder) {
        if error:=os.make_directory_all(folder);error!=nil && !os.is_dir(folder) {
            return fmt.tprintf("The folder %s could not be made: %s",folder,os.error_string(error)),api.SERVER_ERROR
        }
    }
    existed:=os.exists(file)
    probe,error:=os.open(file,{.Write,.Create})
    if error!=nil {return fmt.tprintf("%s could not be written: %s",file,os.error_string(error)),api.SERVER_ERROR}
    os.close(probe)
    if !existed {os.remove(file)}
    return "",0
}

// The size of the scene the viewport draws, under the bars: an image of the
// world alone takes its proportion, so that it frames what the window shows.
@(private)
api_capture_viewport :: proc "contextless" (app:^host.App) -> [2]i32 {
    if app.scene.z>0 && app.scene.w>0 {return {app.scene.z,app.scene.w}}
    return app.drawable
}

// The size of an image without the UI: the one asked for, a side of 0 keeping
// the aspect of the window, or the window when both are 0.
api_capture_size :: proc "contextless" (window:[2]i32,width,height:int) -> [2]i32 {
    size:=[2]i32{i32(width),i32(height)}
    switch {
    case width==0 && height==0: return window
    case width==0:              size.x=max(i32(f32(height)*f32(window.x)/f32(max(window.y,1))+0.5),1)
    case height==0:             size.y=max(i32(f32(width)*f32(window.y)/f32(max(window.x,1))+0.5),1)
    }
    return size
}

// The image capture writes after its frames: the window as the last
// one drew it, or the world shown alone at size, through the camera of the
// viewport. The pixels are of the allocator of the application. wait: as
// app_capture_world, for the world alone.
@(private)
api_capture_image :: proc(s:^Session,ui:bool,size:[2]i32,generated:=false,wait:=time.Duration(0)) -> (pixels:[]u8,width,height:int,ok:bool) {
    if ui {return host.app_capture_pixels(s.app,s.app.allocator,generated)}
    return host.app_capture_world(s.app,shown_world(s).data,API_CAPTURE_SETTLE,size,s.editor_world,s.app.allocator,wait)
}

// ---------------------------------------------------------------- play

// The run a call acts on: that of its turn, or that of the user outside a
// turn. A turn that began inside the Play of the user and has no run of its
// own reads that one; own says whether the call may change it.
api_play_run :: proc(s:^Session,call:^api.Call,player:=0) -> (r:^Run,own:bool) {
    owner:=ai_task_of_call(s,call)
    if owner==0 {return run_player(s,0,player),true}
    task:=ai_task_find(s.ai,owner)
    if task==nil {return nil,false}
    if player>0 {
        r=run_player(s,owner,player)
        return r,r!=nil
    }
    r=ai_task_run(s,task)
    return r,r!=nil && r.owner==owner
}

api_play_refused :: proc(call:^api.Call) {
    api.call_fail(call,api.SERVER_ERROR,"The user is playing this game; a turn changes only a run of its own, which play.start opens")
}

@(private)
api_play_result :: proc(s:^Session,call:^api.Call,r:^Run) {api_play_result_fill(s,api.call_result(call,Api_Play_Result),r)}

@(private)
api_play_result_fill :: proc(s:^Session,result:^Api_Play_Result,r:^Run) {
    result.ticks_dropped=s.app.stats.ticks_dropped
    if r==nil {return}
    result.playing=true
    result.detached=r.owner!=0
    if r.owner==0 {
        result.paused=play_paused(s)
        result.simulating=simulating(s)
        result.input_released=s.play_input_released || simulating(s)
    }
    ref:=core.world_ref(r.world,s.info)
    if t:=core.world_storage_of(ref,core.Time);t!=nil {
        result.tick,result.seconds=t.tick,t.seconds
    }
    result.entities=core.world_entities(ref).alive
    if view:=core.world_storage_of(ref,core.View);view!=nil {result.game_camera=view.camera!=core.NONE}
}

@(private)
api_play_start :: proc(s:^Session,call:^api.Call) {
    owner:=ai_task_of_call(s,call)
    running:=run_find(s,owner)
    if running!=nil && running.document==history.edits_scene_state(s.edits) {
        api_play_result(s,call,running)
        return
    }
    params:=api.call_params(call,Api_Play_Start_Params)
    if params.from!=.Scene && (owner!=0 || params.simulate) {
        api.call_fail(call,api.INVALID_PARAMS,"from places player 1 of the Play of the editor: leave it out in a turn or with simulate")
        return
    }
    // Simulate takes over the view of the user; a turn runs its own copy
    // and steps it without input instead.
    if params.simulate && owner!=0 {api.call_fail(call,api.SERVER_ERROR,"A turn simulates on its own copy: play.start, then play.step without keys");return}
    if params.simulate && (params.players>0 || params.online>0) {api.call_fail(call,api.INVALID_PARAMS,"A simulation has no players: leave out players and online");return}
    if plugin:=providers(s);params.online>0 && (!plugin.plays || plugin.play.start==nil || plugin.play.turn==nil) {
        api.call_fail(call,api.INVALID_PARAMS,"Online players need a plugin that plays games on the network: add multiplayer to the plugins of project.mirai")
        return
    }
    if params.players+params.online>PLAYER_PROCESSES {
        api.call_fail(call,api.INVALID_PARAMS,"players and online are 4 at most")
        return
    }
    if running!=nil {
        if owner==0 {
            play_stop(s,true)
            play_plugin_stop(s)
        } else {run_stop(s,owner)}
    }
    if params.simulate {
        if !simulation_start(s) {
            if simulating(s) {play_stop(s,true)}
            api.call_fail(call,api.SERVER_ERROR,"The simulation could not start")
            return
        }
        api_play_result(s,call,run_find(s,0))
        return
    }
    switch params.from {
    case .Scene:  s.play_asked={}
    case .Camera: s.play_asked=camera_origin(s);s.play_asked.asked=true
    case .Point:  s.play_asked=point_origin(s,params.point)
    }
    online,ping:=params.online,params.ping_ms
    if owner!=0 && (online<0 || ping<0) {
        api.call_fail(call,api.INVALID_PARAMS,"online and ping_ms -1 are the Play menu of the person at the editor: a turn gives its own")
        return
    }
    if play_build_first(s,{owner=owner,players=params.players,online=online,ping_ms=ping,saved_only=params.saved_only}) {
        api_play_after_build(s,call,owner)
        return
    }
    if error:=play_begin(s,owner,params.players,online,ping,params.saved_only);error!="" {
        s.play_asked={}
        api.call_fail(call,api.SERVER_ERROR,error)
        return
    }
    api_play_result(s,call,run_find(s,owner))
}

// play.start once its build began: it answers when the game plays, or fails
// with what kept it from it.
@(private)
api_play_after_build :: proc(s:^Session,call:^api.Call,owner:int) {
    build_play_waits :: proc(s:^Session,user:rawptr) -> bool {return s.build.play.pending}
    if !api_wait(s,API_BUILD_SECONDS,nil,build_play_waits,"building to play") {
        // Whoever does not wait sees the build and the game that follows it.
        if api_state(s).left_going {return}
        // Cancelled, the game does not start by itself when the build ends.
        if api_stop_asked(s) {s.build.play.pending=false;s.play_asked={};return}
        api.call_failf(call,api.SERVER_ERROR,"The build still runs after %d s: the game starts when it stands and play.status says so",API_BUILD_SECONDS)
        return
    }
    switch {
    case .Restart in s.requests:
        api.call_fail(call,api.SERVER_ERROR,"The build needs an engine newer than this editor, which starts again on it now: call play.start again once it answers")
    case s.build.phase==.Failed:
        api_build_fail(s,call,"The code does not build, so the game did not start")
    case base.text_get(s.build.play_error[:])!="":
        api.call_fail(call,api.SERVER_ERROR,base.text_get(s.build.play_error[:]))
    case run_find(s,owner)==nil:
        api.call_fail(call,api.SERVER_ERROR,"The game could not start; engine.diagnostics says why")
    case:
        api_play_result(s,call,run_find(s,owner))
    }
}

// The call fails with what a build said: the first error in its message and
// every one, with file and line, in its data.
api_build_fail :: proc(s:^Session,call:^api.Call,what:string) {
    message:=api_build_first_error(s)
    data:=strings.builder_make(call.allocator)
    strings.write_string(&data,`{"diagnostics":[`)
    first:=true
    for d in s.build.diagnostics {
        if d.severity!=.Error {continue}
        if !first {strings.write_byte(&data,',')}
        first=false
        fmt.sbprintf(&data,`{{"file":%s,"line":%d,"column":%d,"message":%s}}`,serial.text_quote(d.file),d.line,d.column,serial.text_quote(d.message))
    }
    strings.write_string(&data,`]}`)
    api.call_fail(call,api.SERVER_ERROR,fmt.tprintf("%s: %s",what,message),strings.to_string(data))
}

// The first error of the last build with its place, or what failed when no
// diagnostic says it.
@(private)
api_build_first_error :: proc(s:^Session) -> string {
    for d in s.build.diagnostics {
        if d.severity==.Error {return fmt.tprintf("%s(%d:%d) %s",d.file,d.line,d.column,d.message)}
    }
    texts:=FAILURE_TEXTS
    text:=strings.trim_space(s.build.text)
    if line:=strings.index_byte(text,'\n');line>=0 {text=text[:line]}
    return text!=""?fmt.tprintf("%s: %s",texts[s.build.failure],text):texts[s.build.failure]
}

// Starts the run of an owner with its local and online players: "" or what
// kept it from starting.
play_begin :: proc(s:^Session,owner,players,online,ping_ms:int,saved_only:bool) -> string {
    plugin:=providers(s)
    if online>0 && (!plugin.plays || plugin.play.start==nil || plugin.play.turn==nil) {
        return "Online players need a plugin that plays games on the network: add multiplayer to the plugins of project.mirai"
    }
    if owner==0 {
        if players>0 && s.play_players!=nil {s.play_players.players=players}
        taken,error:=play_plugin_start(s,online,ping_ms,saved_only)
        if error!="" {return error}
        if taken {return ""}
    }
    if !play_start(s,false,owner) {return "The game could not start"}
    if owner!=0 {
        if error:=play_turn_runs(s,owner,players,online,ping_ms);error!="" {
            run_stop(s,owner)
            return error
        }
    }
    return ""
}

@(private)
api_play_stop :: proc(s:^Session,call:^api.Call) {
    r,own:=api_play_run(s,call)
    if r!=nil && !own {api_play_refused(call);return}
    // Outside a turn it ends what the editor shows: a watch, the game, and that of a plugin.
    switch {
    case r!=nil && r.owner!=0:  run_stop(s,r.owner)
    case s.mode==.Watch:        watch_stop(s)
    case r!=nil:                play_stop(s,true)
    }
    if ai_task_of_call(s,call)==0 {play_plugin_stop(s)}
    api_play_result(s,call,nil)
}

@(private)
api_play_status :: proc(s:^Session,call:^api.Call) {
    r,_:=api_play_run(s,call)
    api_play_result(s,call,r)
}

@(private)
api_play_pause :: proc(s:^Session,call:^api.Call) {
    r,own:=api_play_run(s,call)
    switch {
    case r==nil: api_no_game(call)
    case !own: api_play_refused(call)
    case r.owner!=0: api.call_fail(call,api.SERVER_ERROR,"This run advances only with play.step")
    case:
        p:=api.call_params(call,Api_Pause_Params)
        play_pause(s,p.paused,here=p.here)
        api_play_result(s,call,r)
    }
}

@(private)
api_play_step :: proc(s:^Session,call:^api.Call) {
    params:=api.call_params(call,Api_Play_Step_Params)
    r,own:=api_play_run(s,call)
    if r==nil {api_no_game(call);return}
    if !own {api_play_refused(call);return}
    owner:=r.owner
    if !api_step_drive_ticks(s,call,params) {return}
    timeline,ok:=api_step_timeline(call,params,s.app.tick_dt)
    if !ok {return}
    if params.drive_ticks>0 {timeline[0].ticks=params.drive_ticks}
    if owner==0 && simulating(s) && (api_timeline_input(timeline) || params.focus>=0) {
        api.call_fail(call,api.INVALID_PARAMS,"A simulation takes no player input")
        return
    }
    target:=run_player(s,owner,params.player)
    if target==nil {
        api.call_fail(call,api.INVALID_PARAMS,"That player has no run: play.start with online opens them")
        return
    }
    values:[4]string
    api.object_values(call.allocator,call.raw,{"until","trace","drive","look_at"},values[:])
    until:=params.until[:api.json_count(values[0])]
    if _,problem:=api_conditions_read(s,run_ref(s,target),until,nil,"until");problem!="" {api.call_fail(call,api.INVALID_PARAMS,problem);return}
    run:=Api_Step_Run{owner=owner,player=params.player,timeline=timeline,until=until}
    drive:^Api_Drive
    if values[2]!="" {
        if owner==0 && simulating(s) {api.call_fail(call,api.INVALID_PARAMS,"A simulation takes no player input");return}
        read,ok:=api_drive_read(s,call,run_ref(s,target),&params.drive,values[2])
        if !ok {return}
        drive=new_clone(read,call.allocator)
        run.drive=drive
    }
    if values[3]!="" {
        if owner==0 && simulating(s) {api.call_fail(call,api.INVALID_PARAMS,"A simulation takes no player input");return}
        read,ok:=api_look_read(s,call,run_ref(s,target),&params.look_at,values[3],timeline)
        if !ok {return}
        run.look=new_clone(read,call.allocator)
    }
    trace:Api_Trace
    traced:=values[1]!=""
    if traced {
        if problem:=api_trace_read(s,call,run_ref(s,target),&params.trace,values[1],api_timeline_ticks(timeline),&trace);problem!="" {
            api.call_fail(call,api.INVALID_PARAMS,problem)
            return
        }
        run.sampler,run.every=&trace,params.trace.every
    }
    if params.focus>=0 && !api_seat_focus(s,call,target,params.focus) {return}
    ran,met,problem:=api_step_run(s,&run,api_step_frame)
    ended:=run_find(s,owner)
    if drive!=nil {api_drive_finish(s,ended,drive,len(until)>0 && met)}
    if problem!="" {api.call_fail(call,api.INVALID_PARAMS,problem);return}
    api_play_step_write(s,call,ended,ran,len(until)>0 && met,traced?&trace:nil,drive)
}

// A drive runs as long as its step says, 30 s when it does not; it
// takes no segments and no press, which the steering would fight. false after failing the call.
@(private)
api_step_drive_ticks :: proc(s:^Session,call:^api.Call,params:^Api_Play_Step_Params) -> bool {
    values:[4]string
    api.object_values(call.allocator,call.raw,{"drive","for","segments","press"},values[:])
    if values[0]=="" {return true}
    if values[2]!="" || values[3]!="" {
        api.call_fail(call,api.INVALID_PARAMS,"drive steers along the ticks of the step: give it with for, without segments or press")
        return false
    }
    if values[1]=="" {params.drive_ticks=clamp(int(f64(API_DRIVE_DEFAULT_SECONDS)/max(f64(s.app.tick_dt),1e-6)+0.5),1,API_STEP_LIMIT)}
    return true
}

// The keys and the mouse go to the local seat of slot from the next tick on,
// as the game asks with input.focus.
@(private)
api_seat_focus :: proc(s:^Session,call:^api.Call,r:^Run,slot:int) -> bool {
    ref:=run_ref(s,r)
    seats,requests:=core.world_storage_of(ref,input.Seats),core.world_storage_of(ref,input.Seat_Requests)
    if seats==nil || requests==nil {
        api.call_fail(call,api.INVALID_PARAMS,"focus moves the keys between local seats, and this game has none: leave it out")
        return false
    }
    if slot>=seats.local_count {
        api.call_failf(call,api.INVALID_PARAMS,"focus %d is not a local seat: the game has %d, slots 0 to %d; play.start with players gives it more",slot,seats.local_count,seats.local_count-1)
        return false
    }
    input.focus(requests,slot)
    run_tell_focus(s,r,slot)
    return true
}

// One tick of play.step: every run of the game advances; the one of the
// player gets the input of step. at: the tick of its segment; the first takes its pointer, wheel, taps and
// text, and the motion of the mouse is spread over all of them.
@(private)
api_step_tick :: proc(s:^Session,owner,player:int,step:^Api_Step_Input,at:int) {
    for &other in s.runs {
        if other.world==nil || other.owner!=owner {continue}
        other.step=true
        if other.player!=player {continue}
        run_tell_input(s,&other,step,at)
        first:=at==0
        if step.placed {other.pointer,other.pointer_set=step.mouse_position,true}
        given:core.Input
        given.keys_down,given.mouse_down=step.keys,step.buttons
        given.keys_pressed=step.keys-other.held_keys
        given.keys_released=other.held_keys-step.keys
        given.mouse_pressed=step.buttons-other.held_buttons
        given.mouse_released=other.held_buttons-step.buttons
        if first {
            given.keys_pressed+=step.tap_keys;given.keys_released+=step.tap_keys
            given.mouse_pressed+=step.tap_buttons;given.mouse_released+=step.tap_buttons
        }
        given.mouse_position,given.gamepads=other.pointer,step.gamepads
        // The device used last stays until another is pressed.
        if held:=core.world_storage_of(run_ref(s,&other),core.Input);held!=nil {given.device=held.device}
        for &g,slot in given.gamepads {
            g.pressed=g.down-other.held_pads[slot]
            g.released=other.held_pads[slot]-g.down
            if first {g.pressed+=step.pad_taps[slot];g.released+=step.pad_taps[slot]}
            other.held_pads[slot]=g.down
            if g.pressed!={} {given.device={gamepad=true,slot=u8(slot)}}
        }
        if given.keys_pressed!={} || given.mouse_pressed!={} {given.device={}}
        if at<step.ticks {
            ticks:=f32(step.ticks)
            given.mouse_delta=step.mouse_delta*f32(at+1)/ticks-step.mouse_delta*f32(at)/ticks
        }
        if first {given.wheel=step.wheel}
        other.held_keys,other.held_buttons=step.keys,step.buttons
        // One store per value until odin-lang/Odin#7937 (see ODIN_WORKAROUNDS).
        other.input=given
        other.has_input=true
        other.ui=api_play_ui_input(given,first?step.text:"")
    }
}

// What the UI of the game takes of the input of a tick, as the UI of a
// window takes it (host.ui_input_from_platform), and text typed.
@(private)
api_play_ui_input :: proc(given:core.Input,text:string) -> ui.Input {
    frame:=host.input_frame_of(given)
    for c,i in text {frame.text[i]=c}
    frame.text_count=len(text)
    return host.ui_input_from_platform(&frame)
}

// Asks one tick of every run of the game of an owner for the next frame; the
// run of player gets the input, whose edges are against what it held before.
@(private)
runs_tick_ask :: proc(s:^Session,owner,player:int,keys:core.Keys,buttons:core.Mouse_Buttons,mouse_delta,wheel:[2]f32) {
    step:=Api_Step_Input{ticks=1,keys=keys,buttons=buttons,mouse_delta=mouse_delta,wheel=wheel}
    api_step_tick(s,owner,player,&step,0)
}

// Whether the game loop of a run goes on every frame of the editor: the Play
// of the user while it is not paused, also while the editor watches another.
@(private)
run_goes_on :: proc(s:^Session,r:^Run) -> bool {
    if r.owner!=0 {return false}
    mode:=s.mode==.Watch?s.watch.from:s.mode
    return mode==.Play || mode==.Simulate
}

// ---------------------------------------------------------------- build

@(private)
api_build_result :: proc(s:^Session,call:^api.Call) {
    result:=api.call_result(call,Api_Build_Result)
    result.building=s.build.phase==.Running || s.build.reload
    result.restarting=.Restart in s.requests
    base.text_set(result.target[:],s.build.target==.Game?"game":"editor")
    base.text_set(result.game[:],s.build.game)
    result.phase=s.build.phase
    result.errors=len(s.build.diagnostics)
    result.seconds=s.build.seconds
    count:=0
    for severity in ([2]build.Severity{.Error,.Warning}) {
        for d in s.build.diagnostics {
            if d.severity!=severity || count==len(result.diagnostics) {continue}
            row:=&result.diagnostics[count]
            count+=1
            row.severity,row.line,row.column=d.severity,d.line,d.column
            base.text_set(row.file[:],d.file)
            base.text_set(row.message[:],d.message)
        }
    }
    has_error:=false
    for d in s.build.diagnostics {has_error||=d.severity==.Error}
    if has_error || s.build.phase==.Failed {base.text_set(result.message[:],api_build_first_error(s))}
}

@(private)
api_build_start :: proc(s:^Session,call:^api.Call) {
    params:=api.call_params(call,Api_Build_Params)
    target:build.Target
    switch text:=base.text_get(params.target[:]);text {
    case "","editor": target=.Editor
    case "game":      target=.Game
    case "shaders":
        api_build_shaders(s,call,params.seconds)
        return
    case "built":
        if s.build.phase==.Running {break}
        s.build.started_sources=code_fingerprint(s.project_root)
        s.build.reload=library_stale(s)
        // The shaders it published load as those the editor publishes, and it answers once the viewport draws with them.
        shaders:u64
        if s.app.renderer!=nil && host.app_shaders_behind(s.app) {shaders=host.app_shaders_reload(s.app)}
        api_wait(s,f64(params.seconds),&shaders,built_loading,"loading")
        api_build_result(s,call)
        return
    case:
        api.call_failf(call,api.INVALID_PARAMS,"target %q is editor, game, shaders or built",text)
        return
    }
    out:=base.text_get(params.out[:])
    if out!="" && target!=.Game {
        api.call_fail(call,api.INVALID_PARAMS,"out is the folder of the game: pass it with target game")
        return
    }
    if out!="" && !filepath.is_abs(out) {out=project.path(s.project_root,out,allocator=context.temp_allocator)}
    if out!="" && project.path_same(project.path_absolute(out,context.temp_allocator),s.project_root) {
        api.call_fail(call,api.INVALID_PARAMS,"out cannot be the folder of the project: name another one, or leave it empty for .mirai/game")
        return
    }
    if build_busy(s.build) {
        api.call_fail(call,api.SERVER_ERROR,"Another build, check or run of the tests is running: build.status says when a build ends")
        return
    }
    if !s.has_project || s.engine_root=="" {
        api.call_fail(call,api.SERVER_ERROR,"Build needs a project and the root of the engine: start the editor with --engine or MIRAI_ROOT")
        return
    }
    if !build_start(s,target,out) {
        tool_call_fail(s,call,"The build could not start")
        return
    }
    api_wait(s,f64(params.seconds),nil,build_running,"building")
    api_build_result(s,call)
}

@(private="file")
build_running :: proc(s:^Session,user:rawptr) -> bool {return s.build.phase==.Running || s.build.reload}

@(private="file")
built_loading :: proc(s:^Session,user:rawptr) -> bool {
    if build_running(s,nil) {return true}
    if s.app.renderer==nil {return false}
    host.app_shaders_poll(s.app)
    return host.app_shaders_loading(s.app,(^u64)(user)^) || gpu.renderer_pipelines_pending(s.app.renderer)
}

@(private)
api_build_status :: proc(s:^Session,call:^api.Call) {api_build_result(s,call)}

// build.start with target shaders: published again from their files and what
// the editor holds unsaved, answering once the viewport has them.
@(private)
api_build_shaders :: proc(s:^Session,call:^api.Call,seconds:int) {
    started:=time.tick_now()
    programs_publish_request(s)
    if ok,message:=programs_wait(s,f64(seconds),true);!ok {
        api.call_fail(call,api.SERVER_ERROR,message)
        return
    }
    api_build_result(s,call)
    result:=api.call_result(call,Api_Build_Result)
    result.seconds=time.duration_seconds(time.tick_since(started))
    result.publishing=programs_publishing(s)
    base.text_set(result.target[:],"shaders")
}

Api_Build_Check_Params :: struct {
    seconds:int `mirai:"optional,min=1,max=3600,label=How long it may take before it is stopped"`,
}

Api_Build_Test_Params :: struct {
    package_folder:[256]u8 `mirai:"text,optional,label=Folder of the package under the project (game/enemies); game when empty"`,
    tests:[1024]u8 `mirai:"text,optional,label=Names of the tests to run, separated by commas; all of them when empty"`,
    seconds:int `mirai:"optional,min=1,max=3600,label=How long the build and the tests may take before they are stopped"`,
}

@(private)
api_build_check :: proc(s:^Session,call:^api.Call) {
    params:=api.call_params(call,Api_Build_Check_Params)
    if error:=build_run_start(s,.Check,.Editor,"","",nil,f64(params.seconds));error!="" {api.call_fail(call,api.SERVER_ERROR,error);return}
    if !api_run_wait(s,call,f64(params.seconds),"checking") {return}
    api.call_result(call,Api_Build_Check_Result)^=api_probe_of(api_run_result(s.build),call.allocator)
}

// Builds and runs the tests and answers when they end.
@(private)
api_build_test :: proc(s:^Session,call:^api.Call) {
    params:=api.call_params(call,Api_Build_Test_Params)
    folder:=base.text_get(params.package_folder[:])
    if folder=="" {folder="game"}
    path:=project.path_absolute(project.path(s.project_root,folder,allocator=context.temp_allocator),context.temp_allocator)
    inside:=strings.has_prefix(path,s.project_root) && (len(path)==len(s.project_root) || path[len(s.project_root)]=='/')
    if !inside || !os.is_dir(path) {
        api.call_failf(call,api.INVALID_PARAMS,"%s is not a folder of the project: name the folder of a package under %s, as game",folder,s.project_root)
        return
    }
    names:=make([dynamic]string,context.temp_allocator)
    rest:=base.text_get(params.tests[:])
    for name in strings.split_iterator(&rest,",") {
        if trimmed:=strings.trim_space(name);trimmed!="" {append(&names,trimmed)}
    }
    if error:=build_run_start(s,.Test,.Editor,"",path,names[:],f64(params.seconds));error!="" {api.call_fail(call,api.SERVER_ERROR,error);return}
    if !api_run_wait(s,call,f64(params.seconds),"testing") {return}
    result:=api_run_result(s.build)
    report:=&result.tests
    r:=api.call_result(call,Api_Build_Test_Result)
    r^={probe=api_probe_of(result,call.allocator),compiled=report.compiled,total=report.total,passed=report.passed,failed=make([]Api_Build_Test_Result_Failed,len(report.failed),call.allocator)}
    for failure,i in report.failed {r.failed[i]={failure.package_name,failure.name,failure.messages[:]}}
}

// Waits for the check or the run of the tests just started, which answers
// within its seconds. False, with the call failed, when it did not end.
@(private="file")
api_run_wait :: proc(s:^Session,call:^api.Call,seconds:f64,doing:string) -> bool {
    busy :: proc(s:^Session,user:rawptr) -> bool {return build_busy(s.build)}
    api_wait(s,seconds+5,nil,busy,doing)
    build_poll(s)
    if build_busy(s.build) {
        api.call_failf(call,api.SERVER_ERROR,"It did not end in its %.0f seconds",seconds)
        return false
    }
    return true
}

// What the last check or run of the tests ended with; one that says so when its project could not be opened.
@(private="file")
api_run_result :: proc(b:^Build_State) -> ^build.Result {
    if job:=build_run_job(b);job!=nil {return &job.result}
    result:=new(build.Result,context.temp_allocator)
    result.status,result.text=.Failed,"The project could not be opened"
    return result
}

// What a check or a run of the tests ended with, without the braces.
@(private)
api_probe_of :: proc(result:^build.Result,allocator:runtime.Allocator) -> (r:Api_Build_Check_Result) {
    texts:=FAILURE_TEXTS
    shown:=result.diagnostics[:min(len(result.diagnostics),API_DIAGNOSTICS_LIMIT)]
    text:=result.status==.Built?"":result.text
    r={ok=result.status==.Built,failure=texts[result.failure],seconds=result.seconds,diagnostics=make([]Api_Probe_Diagnostic,len(shown),allocator),text=api_text_whole(text[:min(len(text),API_DIAGNOSTICS_BUILD_TEXT)])}
    for d in result.diagnostics {if d.severity==.Error {r.errors+=1}}
    for d,i in shown {r.diagnostics[i]={fmt.tprint(d.severity),d.file,d.line,d.column,d.message}}
    return
}

// The runs of a turn: its own, with players local ones, and those a plugin
// adds for online players (multiplayer: a run per online player that joins
// the game its run serves).
@(private)
play_turn_runs :: proc(s:^Session,owner,players,online,ping:int) -> string {
    r:=run_find(s,owner)
    if r==nil {return "The game could not start"}
    run_configure(s,r,players)
    if online==0 {return ""}
    p:=providers(s)
    return p.play.turn(s,owner,players,online,ping)
}
