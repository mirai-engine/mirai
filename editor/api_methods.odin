package editor

import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:reflect"
import "core:strings"
import "core:time"
import "mirai:cook/build"
import img "mirai:cook/image"
import "mirai:core"
import "mirai:editor/api"
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
    pending:int `mirai:"label=Textures whose levels are not yet those their distance asks for"`,
    reduced:int `mirai:"label=Textures held coarser than their distance asks for to fit the pool"`,
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

Api_Action_Params :: struct {
    name:[64]u8 `mirai:"text,label=An action as editor.inspect lists it"`,
}
Api_Action_Result :: struct {ran:bool}

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
    ran:int `mirai:"label=play.step: the ticks it ran"`,
    met:bool `mirai:"label=play.step with until: whether they held when it stopped"`,
    scripted:int `mirai:"label=Ticks left of the input play.input scheduled: the next ticks without input of their own play them"`,
}


Api_Play_Start_Params :: struct {
    players:int `mirai:"optional,min=0,max=4,label=Local players sharing the screen; 0: the last chosen (a turn: the scene)"`,
    online:int `mirai:"optional,min=0,max=3,label=Players on the network besides them; the run serves the game. A turn gets a run per online player (player 1 and on) that is a client of its run"`,
    ping_ms:int `mirai:"optional,min=0,max=1000,label=Round trip the online players simulate"`,
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
    ticks:int `mirai:"optional,min=1,max=3600,label=Fixed ticks it runs"`,
    seconds:f32 `mirai:"optional,label=Game time it runs in place of ticks: the nearest whole ticks and at least 1"`,
    keys:core.Keys `mirai:"optional,label=Keys held in every tick; they go to the local seat with the focus"`,
    mouse_buttons:core.Mouse_Buttons `mirai:"optional,label=Buttons held in every tick"`,
    tap_keys:core.Keys `mirai:"optional,label=Keys pressed and released inside the first tick: a press shorter than a tick that is never down"`,
    tap_buttons:core.Mouse_Buttons `mirai:"optional,label=Buttons pressed and released inside the first tick"`,
    mouse_position:[2]f32 `mirai:"optional,label=Where the pointer is from the first tick on in points of the window from its top left (the image of capture over the density): the UI of the game takes it and its clicks; it stays for the next steps"`,
    mouse_delta:[2]f32 `mirai:"optional,label=Relative motion of the mouse in points spread evenly over the ticks"`,
    wheel:[2]f32 `mirai:"optional,label=Added to the first tick"`,
    text:[ui.INPUT_TEXT_CAPACITY]u8 `mirai:"optional,text,label=Printable ASCII typed in the first tick: the field of the UI of the game with the focus takes it"`,
    gamepads:[core.GAMEPAD_CAPACITY]Api_Play_Gamepad `mirai:"optional,label=The gamepads connected in every tick; gamepad i is that of the local seat of slot i when the game has several"`,
    focus:int `mirai:"optional,min=-1,max=3,label=The local seat (by slot) that gets the keys and the mouse from this step on; -1 keeps it"`,
    until:[8]Api_Play_Condition `mirai:"optional,label=It stops after the first tick at which all hold as play.check reads them; ticks (or those of segments) is the most it runs and none run when they hold already"`,
    player:int `mirai:"optional,min=0,max=3,label=The run that gets the input in a game a turn plays on the network; every run of it advances"`,
    segments:[API_STEP_SEGMENTS]Api_Play_Segment `mirai:"optional,label=Input that changes along the step: each segment holds its input for its ticks and the next one follows; in place of ticks and the input fields"`,
    trace:Api_Play_Trace `mirai:"optional,label=Values of a few entities or of a storage read before the first tick and every some ticks and after the last: the trace of the result"`,
    observe:bool `mirai:"optional,label=The answer is what play.observe says after the ticks in place of the state of the game"`,
    targets:[API_OBSERVE_TARGETS][64]u8 `mirai:"optional,text,label=With observe: the targets of play.observe"`,
}

Api_Build_Params :: struct {
    target:[8]u8 `mirai:"optional,text,label=editor (the default): the library of the editor, loaded into it; game: the shipped game with its cooked assets; shaders: the shaders of the project published again, answering once the viewport draws with them"`,
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
    restarting:bool `mirai:"label=The new library needs an engine built after this editor started: the editor starts again now on the new one"`,
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
    selection:[1]base.Entity_Id `mirai:"list"`,
    active:u8 `mirai:"any,label=The id of the active entity of the selection; null without a selection"`,
    tool:[8]u8 `mirai:"text,label=move rotate or scale"`,
    plugin_tool:[32]u8 `mirai:"text,optional,label=The plugin tool that is on (such as terrain or foliage) by the name it turns on with"`,
    plugin_tool_aside:bool `mirai:"optional,label=It lent the scene to the gizmo (W or E or R) and stays on"`,
    space:[8]u8 `mirai:"text,label=world or local: the axes of the gizmo"`,
    snap,indicators:bool,
    mode:[24]u8 `mirai:"text,label=edit play paused simulate simulation_paused or watch"`,
    document:Api_Editor_Document,
    camera:Api_Editor_Camera `mirai:"label=The camera of the viewport"`,
    interactions:Api_Editor_Interactions,
    window:Api_Editor_Window,
    layout:Api_Editor_Layout `mirai:"label=Rectangles as x y width height in points from the top left of the window"`,
    actions:[1]Api_Editor_Action `mirai:"list,label=Every action; editor.action runs them by name"`,
}
Api_Editor_Document :: struct {
    path:[API_PATH_BYTES]u8 `mirai:"text"`,
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
    captured_by:[8]u8 `mirai:"text,label=What holds the pointer in the viewport: look pan select or gizmo; empty when nothing does"`,
    modal:[16]u8 `mirai:"text,label=The dialog that blocks the editor: confirm save_changes recovery shortcuts settings delete_asset or git_discard; empty when none does"`,
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
    widgets:u8 `mirai:"any,label=The rectangle of each widget drawn by key: action.<name> for an action; menu.<name> for a menu; stats; share"`,
}
Api_Editor_Action :: struct {
    name:[32]u8 `mirai:"text"`,
    disabled,checked:bool,
}

@(private)
api_methods_register :: proc(s:^Session,st:^Api_State) {
    step_default:=Api_Step_Params{frames=1,dt=HEADLESS_DT}
    play_step_default:=Api_Play_Step_Params{ticks=1,focus=-1,trace={every=1}}
    build_default:=Api_Build_Params{seconds=API_BUILD_SECONDS}
    pause_default:=Api_Pause_Params{paused=true}
    api_register(s,st,{name="engine.status",summary="The state of the editor and of its renderer, and what the last frame cost by part of the main thread and by pass of the GPU.",result=Api_Status,flags={.Read_Only},run=api_status})
    api_register(s,st,{name="engine.step",summary="Advances whole frames of editor, game and render with a fixed dt. Manual execution only (headless).",params=Api_Step_Params,result=Api_Step_Result,defaults=&step_default,run=api_step})
    api_register(s,st,{name="engine.shutdown",summary="Stops Play and quits the editor after answering. Fails with unsaved changes of scenes or assets unless discard.",params=Api_Shutdown_Params,result=Api_Shutdown_Result,flags={.Destructive},run=api_shutdown})
    api_register(s,st,{name="engine.gpu_lose",summary="Makes the next submission to the GPU report the device lost, as a reset of the GPU does, to test what follows: the editor starts again with its documents, and ends if it was started again for a loss less than a minute before.",result=Api_Gpu_Lose_Result,flags={.Destructive},run=api_gpu_lose})
    api_register(s,st,{name="editor.inspect",summary="What the editor shows and the actions it can run, to drive it as a person would with editor.input and editor.action.",result=Api_Editor_Inspect,writes_result=true,flags={.Read_Only},run=api_editor_inspect})
    api_register(s,st,{name="editor.action",summary="Runs an action of the editor by name, as its menu entry or its shortcut does.",params=Api_Action_Params,result=Api_Action_Result,run=api_editor_action})
    api_register(s,st,{name="editor.recover",summary="Recovers the pending scene after an interrupted session, or discards its recovery copy.",params=Api_Recovery_Params,result=Api_File_Result,run=api_recover})
    api_register(s,st,{name="editor.section_edit",summary="Edits the section of a Scene_Reference in its world: its entities are edited here, scene.save writes its scene too, and everything else reads only. id 0 stops. Returns the reference edited.",params=Api_Section_Edit_Params,run=api_section_edit})
    api_register(s,st,{name="editor.section_preview",summary="Draws the sky and the sun of the section of a Scene_Reference instead of those on, in the view of the editor only: not an edit, not saved, and Play starts without it. id 0 goes back. Returns the sky and the sun drawn.",params=Api_Section_Preview_Params,run=api_section_preview})
    api_register(s,st,{name="editor.sections",summary="The sections of the scene as the World panel maps them: each Scene_Reference with its rule, the state it asks, what the view of the editor asks of it (view; Auto for nothing) and what it shows, its box, and what it costs (entities, meshes and textures of its scene, GPU bytes they hold now and bytes of their files); with the sources the sections stream around and the camera of the editor.",flags={.Read_Only},run=api_sections})
    api_register(s,st,{name="editor.section_view",summary="Turns a section on (Active), loaded and off (Loaded) or off (Unloaded) in the view of the editor alone, or gives it back to what its reference asks (Auto): not an edit, not in the undo and not saved; Play starts with what the references ask. It loads over the next frames: shown in editor.sections says when it is there. Returns the section.",params=Api_Section_View_Params,flags={.Idempotent},run=api_section_view})
    api_register(s,st,{name="editor.section_travel",summary="Brings the camera of the editor to a section, framing its box (into it when the box is big), and turns it on in the view when what asks for it does not. Returns the section.",params=Api_Section_Id_Params,run=api_section_travel})
    api_register(s,st,{name="editor.select",summary="Sets the selection of the editor: the entities the panels and the tools act on.",params=Api_Select_Params,result=Api_Select_Result,flags={.Idempotent},run=api_editor_select})
    api_register(s,st,{name="editor.input",params_schema=API_INPUT_SCHEMA,summary="Runs a frame per event of synthetic input through the path of real input. Manual execution only (headless).",result=Api_Editor_Inspect,writes_result=true,run=api_editor_input})
    api_register(s,st,{name="camera.set",params_schema=API_CAMERA_SCHEMA,summary="Moves the camera of the editor, or looks through a Camera of the scene without changing it, and chooses how the view is exposed.",result=Api_Camera_Result,flags={.Idempotent},run=api_camera_set})
    api_register(s,st,{name="history.undo",flags={.Core},summary="Undoes the last edit of the caller (its turn, or the API outside a turn), even after edits of others, keeping every field they changed since.",result=Api_History_Result,run=api_undo})
    api_register(s,st,{name="history.redo",summary="Redoes the edit the last undo of the caller took back, keeping every field others changed since; a new edit of the caller drops what it can redo.",result=Api_History_Result,run=api_redo})
    api_register(s,st,{name="play.start",flags={.Core},summary="Plays a copy of the scene: outside a turn, in the editor; in a turn, a run of its own the editor does not show and only play.step advances. Up to three turns play besides the user. When an Odin source changed since the last build, it builds first and answers when the game plays, or fails with what the compiler said.",params=Api_Play_Start_Params,result=Api_Play_Result,run=api_play_start})
    api_register(s,st,{name="play.stop",flags={.Core,.Idempotent},summary="Ends the game of the caller (its turn, or the user outside a turn, with its game on the network) and discards what it changed.",result=Api_Play_Result,run=api_play_stop})
    api_register(s,st,{name="play.pause",summary="Pauses the game, or resumes it with paused false: from the newest tick it played, or with here from the tick play.seek went to.",params=Api_Pause_Params,result=Api_Play_Result,defaults=&pause_default,run=api_play_pause})
    api_register(s,st,{name="play.step",flags={.Core},summary="Pauses the game and runs exactly the fixed ticks asked for with the input given (keys, mouse, pointer and text for its UI, gamepads of the local seats), or until conditions hold; segments change the input along the ticks and a trace reads values along them.",params=Api_Play_Step_Params,result=Api_Play_Step_Result,writes_result=true,defaults=&play_step_default,run=api_play_step})
    api_register(s,st,{name="play.status",summary="State of the game.",result=Api_Play_Result,flags={.Read_Only},run=api_play_status})
    api_register(s,st,{name="build.start",flags={.Core},summary="Builds the editor of the project, whose new code loads into the running editor when it succeeds, the game to ship, which leaves the editor as it is, or its shaders; answers when it ends, with each error and its file and line.",params=Api_Build_Params,result=Api_Build_Result,defaults=&build_default,run=api_build_start})
    api_register(s,st,{name="build.status",summary="State of the build and what the compiler said, with file and line.",result=Api_Build_Result,flags={.Core,.Read_Only},run=api_build_status})
    check_defaults:=Api_Build_Check_Params{seconds=300}
    api_register(s,st,{name="build.check",summary="Checks the types of the code of the project, its game, editor and plugins, without building or loading anything; answers when it ends, with each error and its file and line.",params=Api_Build_Check_Params,defaults=&check_defaults,result_schema=API_CHECK_RESULT,flags={.Core,.Read_Only},run=api_build_check})
    test_defaults:=Api_Build_Test_Params{seconds=600}
    api_register(s,st,{name="build.test",summary="Builds and runs the @(test) procedures of a package of the project against the engine it uses, without loading anything; answers when they end, with each failed test and what it logged.",params=Api_Build_Test_Params,defaults=&test_defaults,result_schema=API_TEST_RESULT,flags={.Read_Only},run=api_build_test})
    api_play_record_register(s,st)
    api_play_history_register(s,st)
    play_agent_api_register(s,st)
    qa_api_register(s,st)
    play_explore_api_register(s,st)
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
    st.stepping=true
    done:=0
    for _ in 0..<count {
        done+=1
        start:=time.tick_now()
        running:=advance(s)
        profile_sample(s,start)
        if !running {break}
    }
    st.stepping=false
    p.fixed_dt=saved
    return done
}

@(private)
api_manual_required :: proc(s:^Session,call:^api.Call) -> bool {
    if st:=api_state(s);st!=nil && st.manual {return true}
    api.call_fail(call,api.SERVER_ERROR,"This editor draws by itself: engine.step and editor.input run only in a manual one, which mirai session start opens. Here play.step drives a game and editor.action runs an action")
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
            api_text_put(r.functions[i].name[:],s.info.steps[slot.index].name)
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
    api_text_put(r.document[:],status_value.document)
    r.fps=s.app.stats.fps
    r.undo,r.redo=status_value.undo,status_value.redo
    r.ticks_dropped,r.extras_dropped=app.stats.ticks_dropped,app.stats.extras_dropped
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
        r.textures.bytes,r.textures.pending,r.textures.reduced=stats.texture_bytes,int(stats.textures_pending),int(stats.textures_reduced)
        r.geometry={
            bytes=stats.geometry_bytes,free_bytes=stats.geometry_free,free_largest=stats.geometry_free_largest,ray_bytes=stats.ray_bytes,page_slots=int(stats.page_slots),page_bytes=stats.page_region_bytes,
            pages_resident=int(stats.pages_resident),pages_requested=int(stats.pages_requested),pages_loaded=int(stats.pages_loaded),
            pages_evicted=int(stats.pages_evicted),pages_dropped=int(stats.page_requests_dropped),
        }
        r.cpu.render_prepare_ms,r.cpu.render_begin_ms=stats.cpu_prepare_ms,stats.cpu_begin_ms
        r.cpu.render_record_ms,r.cpu.render_end_ms=stats.cpu_record_ms,stats.cpu_end_ms
        for timing,i in stats.timings[:min(len(stats.timings),API_TIMINGS)] {
            api_text_put(r.gpu_timings[i].name[:],timing.name)
            r.gpu_timings[i].ms=timing.ms
        }
        backend,_:=reflect.enum_name_from_value(stats.backend)
        api_text_put(r.backend[:],backend)
        api_text_put(r.device[:],stats.device_name)
        if app.device!=nil {
            r.validation_errors=rhi.device_validation_errors(app.device)
            used,budget:=rhi.device_memory(app.device)
            r.gpu_memory={f32(f64(used)/(1<<20)),f32(f64(budget)/(1<<20))}
        }
        api_text_put(r.renderer_problem[:],stats.problem)
    }
    if a:=app.assets;a!=nil {
        r.asset_errors=len(host.assets_errors(a))+len(a.registry.reassigned)+len(a.registry.duplicates)
        r.assets={a.stats.meshes,a.stats.textures,a.stats.materials,a.stats.scenes,a.stats.unloads}
        r.textures.streamed=a.stats.streamed
    }
    r.ui_dropped=s.gui.dropped
    r.build,r.build_errors=s.build.phase,len(s.build.diagnostics)
    if len(s.build.diagnostics)>0 {api_text_put(r.build_message[:],s.build.diagnostics[0].message)}
    api_text_put(r.collab[:],collab_summary(s))
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
    prefabs_sync(s,prefabs_of(s))
    api.call_result(call,Api_History_Result)^={edits_undo_count(s.edits),edits_redo_count(s.edits),kept}
}

@(private)
api_undo :: proc(s:^Session,call:^api.Call) {
    preview:=s.edits.preview
    if !api_guard(s,call) {return}
    if preview {api_history_result(s,call);return}
    move:=history_undo(s)
    if !move.done {
        api.call_fail(call,api.SERVER_ERROR,move.error if move.error!="" else "Nothing to undo: the caller has no edit of its own left (an agent's turn undoes its own edits, the API outside a turn its own)")
        return
    }
    api_history_result(s,call,move.kept)
}

@(private)
api_redo :: proc(s:^Session,call:^api.Call) {
    if !api_guard(s,call) {return}
    move:=history_redo(s)
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
    if len(picked)==0 && !params.add {selection_clear(s.selection)} else {selection_set(s.selection,picked,params.add)}
    api.call_result(call,Api_Select_Result)^={len(s.selection.entities),api_entity_id(w,selection_active(s.selection))}
}

@(private)
api_action_find :: proc(name:string) -> (action:Action,found:bool) {
    for candidate,index in reflect.enum_field_names(Action) {
        if strings.equal_fold(candidate,name) {return Action(index),true}
    }
    return
}

@(private)
api_editor_action :: proc(s:^Session,call:^api.Call) {
    name:=base.text_get(api.call_params(call,Api_Action_Params).name[:])
    action,found:=api_action_find(name)
    if !found {
        api.call_failf(call,api.INVALID_PARAMS,"%q is not an action; editor.inspect lists them",name)
        return
    }
    #partial switch action {
    case .Open,.Save_As,.Quit,.Shortcuts,.Import:
        api.call_failf(call,api.INVALID_PARAMS,"%s opens a dialog: use scene.open, scene.save or engine.shutdown",name)
        return
    }
    prefabs_sync(s,prefabs_of(s))
    prefab_observe(s)
    if !action_run(s,action) {
        api.call_failf(call,api.SERVER_ERROR,"%s is disabled now",name)
        return
    }
    // What the action asked for happens between frames; a manual editor
    // runs one after undo and redo, as history.undo does.
    if s.requests!={} || action==.Undo || action==.Redo {
        st:=api_state(s)
        if st.manual {api_frames(s,1,0)} else if s.requests!={} {requests_run(s)}
    }
    api.call_result(call,Api_Action_Result).ran=true
}

// ---------------------------------------------------------------- editor.inspect

@(private)
api_rect :: proc(w:^serial.Writer,rect:ui.Rect) {api.write_list(w,{rect.x,rect.y,rect.w,rect.h})}

@(private)
api_inspect_write :: proc(s:^Session,w:^serial.Writer) {
    v:=s.viewport
    g:=s.gui
    world:=shown_world(s)
    serial.text_write_raw(w,`{"frame":`);serial.text_write_uint(w,s.frame)
    api.write_key(w,"selection");serial.write_u8(w,'[')
    for e,i in s.selection.entities {
        if i>0 {serial.write_u8(w,',')}
        api_write_id(w,api_entity_id(world,e))
    }
    serial.write_u8(w,']')
    api.write_key(w,"active")
    if active:=api_entity_id(world,selection_active(s.selection));active!=0 {api_write_id(w,active)} else {serial.text_write_raw(w,"null")}
    tool,_:=reflect.enum_name_from_value(v.tool)
    // A plugin tool that holds the scene is the tool; one that lent it to the gizmo is the plugin.
    api.write_key(w,"tool");serial.text_write_string(w,api_lower(tool))
    if v.plugin_tool!=0 {api.write_key(w,"plugin_tool");serial.text_write_string(w,base.text_get(v.plugin_tool_name[:]));api.write_bool(w,"plugin_tool_aside",v.plugin_aside)}
    api.write_key(w,"space");serial.text_write_string(w,v.space==.World?"world":"local")
    api.write_key(w,"snap");api.write_flag(w,snapping(v,.Move))
    api.write_key(w,"indicators");api.write_flag(w,v.show_indicators)
    mode,_:=reflect.enum_name_from_value(s.mode)
    api.write_key(w,"mode");serial.text_write_string(w,api_lower(mode))
    api.write_key(w,"document");serial.text_write_raw(w,`{"path":`);serial.text_write_string(w,document_path(s.document))
    api.write_key(w,"dirty");api.write_flag(w,document_dirty(s))
    api.write_key(w,"entities");serial.text_write_int(w,i64(core.world_entities(world).alive))
    api.write_key(w,"undo");serial.text_write_int(w,i64(edits_undo_count(s.edits)))
    api.write_key(w,"redo");serial.text_write_int(w,i64(edits_redo_count(s.edits)))
    serial.write_u8(w,'}')
    position:=orbit_position(v.orbit)
    api.write_key(w,"camera");serial.text_write_raw(w,`{"position":`);api.write_list(w,position[:])
    api.write_key(w,"target");api.write_list(w,v.orbit.target[:])
    api.write_key(w,"yaw");api.write_number(w,v.orbit.yaw)
    api.write_key(w,"pitch");api.write_number(w,v.orbit.pitch)
    api.write_key(w,"distance");api.write_number(w,v.orbit.distance)
    api.write_key(w,"fov");api.write_number(w,v.orbit.fov)
    serial.write_u8(w,'}')
    capture,_:=reflect.enum_name_from_value(v.capture)
    api.write_key(w,"interactions");serial.text_write_raw(w,`{"captured_by":`)
    serial.text_write_string(w,v.capture==.None?"":api_lower(capture))
    modal,_:=reflect.enum_name_from_value(g.modal)
    api.write_key(w,"modal");serial.text_write_string(w,g.modal==.None?"":api_lower(modal))
    api.write_key(w,"popups");serial.text_write_int(w,i64(g.ctx.popup.count))
    api.write_key(w,"editing_text");api.write_flag(w,g.ctx.edit.id!=0)
    api.write_key(w,"dialog_pending");api.write_flag(w,platform.dialog_pending(s.app.platform))
    api.write_key(w,"hovered");api.write_flag(w,v.hovered)
    serial.write_u8(w,'}')
    window:=platform.input_frame(s.app.platform).window
    api.write_key(w,"window");serial.text_write_raw(w,`{"present":`);api.write_flag(w,!s.headless)
    api.write_key(w,"size");api.write_list(w,{f32(window.size.x),f32(window.size.y)})
    api.write_key(w,"minimized");api.write_flag(w,window.minimized)
    api.write_key(w,"maximized");api.write_flag(w,window.maximized)
    api.write_key(w,"fullscreen");api.write_flag(w,window.fullscreen)
    serial.write_u8(w,'}')
    api.write_key(w,"layout");serial.text_write_raw(w,`{"bar":`);api_rect(w,g.rects.bar)
    api.write_key(w,"left");api_rect(w,g.rects.left)
    api.write_key(w,"right");api_rect(w,g.rects.right)
    api.write_key(w,"bottom");api_rect(w,g.rects.bottom)
    api.write_key(w,"widgets");serial.write_u8(w,'{')
    first:=true
    widget :: proc(w:^serial.Writer,s:^Session,first:^bool,key:string,id:ui.Id) {
        rect,found:=ui.widget_rect(s.gui.ctx,id)
        if !found {return}
        api.write_key(w,key,first^)
        first^=false
        api_rect(w,rect)
    }
    for action in Action {
        name,_:=reflect.enum_name_from_value(action)
        widget(w,s,&first,fmt.tprintf("action.%s",api_lower(name)),shell_id(g,"action",int(action)+1))
    }
    widget(w,s,&first,"menu.file",shell_id(g,"menu",1))
    widget(w,s,&first,"menu.view",shell_id(g,"menu",4))
    widget(w,s,&first,"stats",shell_id(g,"stats"))
    widget(w,s,&first,"share",shell_id(g,"share"))
    serial.text_write_raw(w,"}}")
    api.write_key(w,"actions");serial.write_u8(w,'[')
    for action in Action {
        name,_:=reflect.enum_name_from_value(action)
        if int(action)>0 {serial.write_u8(w,',')}
        state:=action_state(s,action)
        serial.text_write_raw(w,`{"name":`);serial.text_write_string(w,api_lower(name))
        api.write_key(w,"disabled");api.write_flag(w,state.disabled)
        api.write_key(w,"checked");api.write_flag(w,state.checked)
        serial.write_u8(w,'}')
    }
    serial.write_u8(w,']')
    serial.write_u8(w,'}')
}

@(private)
api_editor_inspect :: proc(s:^Session,call:^api.Call) {
    api_inspect_write(s,call.out)
}

// ---------------------------------------------------------------- editor.input

@(private)
Api_Input_Step :: struct {
    keys,repeat:platform.Keys,
    buttons:platform.Mouse_Buttons,
    position,delta,wheel:[2]f32,
    has_position,has_delta:bool,
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

@(private)
api_keys :: proc(a:^Rpc_Args,what:string) -> (keys:platform.Keys,ok:bool) {
    if !serial.text_accept(&a.r,'[') {return {},rpc_fail(a,"%s must be an array of key names",what)}
    if serial.text_accept(&a.r,']') {return {},true}
    for {
        name,read:=serial.text_string(&a.r)
        if !read {return {},rpc_fail(a,"%s must be an array of key names",what)}
        key,known:=api_key_from_name(name)
        if !known {return {},rpc_fail(a,"%s: %s; keys go by their platform.Key name, such as A, F5, Enter, Space, Left_Shift, Left_Control or Left_Super (Command on a Mac)",what,base.name_problem(name,"a key",reflect.enum_field_names(platform.Key)))}
        keys+={key}
        if serial.text_accept(&a.r,',') {continue}
        if !serial.text_accept(&a.r,']') {return {},rpc_fail(a,"%s must be an array of key names",what)}
        return keys,true
    }
}

@(private)
api_buttons :: proc(a:^Rpc_Args,what:string) -> (buttons:platform.Mouse_Buttons,ok:bool) {
    if !serial.text_accept(&a.r,'[') {return {},rpc_fail(a,"%s must be an array of left, right or middle",what)}
    if serial.text_accept(&a.r,']') {return {},true}
    for {
        name,read:=serial.text_string(&a.r)
        if !read {return {},rpc_fail(a,"%s must be an array of left, right or middle",what)}
        switch {
        case strings.equal_fold(name,"left"):   buttons+={.Left}
        case strings.equal_fold(name,"right"):  buttons+={.Right}
        case strings.equal_fold(name,"middle"): buttons+={.Middle}
        case: return {},rpc_fail(a,"%s: unknown button %q",what,name)
        }
        if serial.text_accept(&a.r,',') {continue}
        if !serial.text_accept(&a.r,']') {return {},rpc_fail(a,"%s must be an array of left, right or middle",what)}
        return buttons,true
    }
}

@(private)
api_dt_valid :: proc "contextless" (dt:f32) -> bool {return rpc_finite(dt) && dt>0 && dt<=API_DT_MAX}

@(private)
api_input_step :: proc(a:^Rpc_Args,step:^Api_Input_Step) -> bool {
    object:Rpc_Object
    rpc_object_begin(a,"an event") or_return
    for key in rpc_next(a,&object) {
        switch key {
        case "keys":           step.keys=api_keys(a,key) or_return
        case "repeat_keys":    step.repeat=api_keys(a,key) or_return
        case "mouse_buttons":  step.buttons=api_buttons(a,key) or_return
        case "mouse_position":
            rpc_vector(a,key,step.position[:]) or_return
            step.has_position=true
        case "mouse_delta":
            rpc_vector(a,key,step.delta[:]) or_return
            step.has_delta=true
        case "wheel":
            if serial.text_peek(&a.r)=='[' {rpc_vector(a,key,step.wheel[:]) or_return} else {step.wheel.y=rpc_number(a,key) or_return}
        case "clicks":
            clicks:=rpc_unsigned(a,key) or_return
            if clicks<1 || clicks>3 {return rpc_fail(a,"clicks must be 1 to 3")}
            step.clicks=u8(clicks)
        case "text":
            text:=rpc_text(a,key,step.text[:]) or_return
            step.text_length=len(text)
            for character in transmute([]u8)text {
                if character<32 || character>126 {return rpc_fail(a,"text must be printable ASCII")}
            }
        case "dt":
            step.dt=rpc_number(a,key) or_return
            if !api_dt_valid(step.dt) {return rpc_fail(a,"dt must be greater than 0 and at most 0.25 seconds")}
        case:
            return rpc_fail_unknown(a,key,"keys","repeat_keys","mouse_buttons","mouse_position","mouse_delta","wheel","clicks","text","dt")
        }
    }
    if a.failed {return false}
    if step.has_position && step.has_delta {return rpc_fail(a,"mouse_position and mouse_delta exclude each other")}
    if step.repeat-step.keys!={} {return rpc_fail(a,"repeat_keys must be held in keys")}
    return true
}

@(private)
api_editor_input :: proc(s:^Session,call:^api.Call) {
    if !api_manual_required(s,call) {return}
    steps,memory:=make([]Api_Input_Step,API_INPUT_EVENTS,call.allocator)
    if memory!=nil {
        api.call_fail(call,api.INTERNAL_ERROR,"the request needs more scratch memory than the server has")
        return
    }
    count:=0
    dt:=HEADLESS_DT
    a:Rpc_Args
    rpc_init(&a,call,call.raw)
    object:Rpc_Object
    if !rpc_object_begin(&a,"params") {return}
    for key in rpc_next(&a,&object) {
        switch key {
        case "dt":
            value,ok:=rpc_number(&a,key)
            if ok && !api_dt_valid(value) {rpc_fail(&a,"dt must be greater than 0 and at most 0.25 seconds")}
            dt=value
        case "events":
            if !serial.text_accept(&a.r,'[') {rpc_fail(&a,"events must be an array");break}
            if serial.text_accept(&a.r,']') {break}
            for !a.failed {
                if count>=API_INPUT_EVENTS {rpc_fail(&a,"events has more than %d entries",API_INPUT_EVENTS);break}
                if !api_input_step(&a,&steps[count]) {break}
                count+=1
                if serial.text_accept(&a.r,',') {continue}
                if !serial.text_accept(&a.r,']') {rpc_fail(&a,"events must be an array")}
                break
            }
        case:
            rpc_fail_unknown(&a,key,"events","dt")
        }
    }
    if a.failed {return}
    if count==0 {
        api.call_fail(call,api.INVALID_PARAMS,"events must have 1 to 256 entries")
        return
    }
    p:=s.app.platform
    for &step in steps[:count] {
        frame:=platform.input_frame(p)
        held_keys,held_buttons:=frame.keys_down,frame.mouse_down
        position:=frame.mouse_inside?frame.mouse_position:[2]f32{}
        if step.has_position {
            position=step.position
            platform.input_inject(p,platform.Mouse_Motion_Event{position=position})
        } else if step.has_delta {
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
    api_inspect_write(s,call.out)
}

// ---------------------------------------------------------------- camera and capture

@(private)
api_camera_set :: proc(s:^Session,call:^api.Call) {
    v:=s.viewport
    orbit:=v.orbit
    position,target:[3]f32
    fov:f32
    entity:string
    entity_text:[API_ENTITY_TEXT]u8
    exposure:core.View_Exposure
    source:=v.exposure_source
    ev100:=v.ev100
    has_position,has_target,has_angles,has_fov,has_entity,has_source,has_from:=false,false,false,false,false,false,false
    from:[3]f32
    frame_texts:[API_SPATIAL_LIMIT][API_ENTITY_TEXT]u8
    framed:=0
    a:Rpc_Args
    rpc_init(&a,call,call.raw)
    object:Rpc_Object
    if !rpc_object_begin(&a,"params") {return}
    for key in rpc_next(&a,&object) {
        ok:=true
        switch key {
        case "position": has_position=rpc_vector(&a,key,position[:])
        case "target":   has_target=rpc_vector(&a,key,target[:])
        case "yaw":      orbit.yaw,ok=rpc_number(&a,key);has_angles=true
        case "pitch":    orbit.pitch,ok=rpc_number(&a,key);has_angles=true
        case "distance":
            orbit.distance,ok=rpc_number(&a,key)
            if ok && orbit.distance<=0 {rpc_fail(&a,"distance must be greater than 0")}
        case "fov":
            fov,ok=rpc_number(&a,key)
            if ok && (fov<VIEW_FOV_MIN || fov>VIEW_FOV_MAX) {rpc_fail(&a,"fov must be %v to %v degrees",VIEW_FOV_MIN,VIEW_FOV_MAX)}
            has_fov=true
        case "entity":
            entity,ok=rpc_text(&a,key,entity_text[:])
            has_entity=true
        case "exposure":
            buffer:[8]u8
            text:string
            text,ok=rpc_text(&a,key,buffer[:])
            switch text {
            case "scene":  source=.Scene
            case "camera": source=.Camera
            case "manual": source=.Manual
            case: if ok {rpc_fail(&a,"exposure must be scene, camera or manual")}
            }
            has_source=true
        case "ev100":
            ev100,ok=rpc_number(&a,key)
            if ok && (ev100<-10 || ev100>24) {rpc_fail(&a,"ev100 must be -10 to 24")}
            if !has_source {source=.Manual}
        case "from":
            has_from=rpc_vector(&a,key,from[:])
        case "frame":
            if !serial.text_accept(&a.r,'[') {rpc_fail(&a,"frame must be an array of entities");break}
            for i:=0;!serial.text_accept(&a.r,']') && !a.failed;i+=1 {
                if i>0 && !serial.text_accept(&a.r,',') {rpc_fail(&a,"frame must be an array of entities");break}
                if framed>=API_SPATIAL_LIMIT {rpc_fail(&a,"frame takes at most %d entities",API_SPATIAL_LIMIT);break}
                rpc_text(&a,"an entity of frame",frame_texts[framed][:len(frame_texts[0])-1])
                framed+=1
            }
        case:
            rpc_fail_unknown(&a,key,"position","target","yaw","pitch","distance","fov","entity","exposure","ev100","frame","from")
        }
    }
    if a.failed {return}
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
api_capture_answer :: proc(s:^Session,call:^api.Call,file:string,pixels:[]u8,width,height:int,shown:=true) {
    if !api_png_write(s,file,pixels,width,height) {
        api.call_failf(call,api.SERVER_ERROR,"%s could not be written although it could be opened: the disk may be full",file)
        return
    }
    api_capture_reply(call,file,width,height,shown)
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
@(private)
api_output_path :: proc(root,path:string,allocator:=context.allocator) -> (file,problem:string) {
    inside:=root!=""?fmt.tprintf("the folder of the project, %s",root):"the working folder"
    if path=="" {return "",fmt.tprintf("path is required: a file absolute or relative to %s",inside)}
    native,ok:=project.path_native(path)
    if !ok {return "",fmt.tprintf("%s: %s, or relative to %s",path,document_error_text(.Bad_Path),inside)}
    if root!="" && !filepath.is_abs(native) {native=project.path(root,native,allocator=context.temp_allocator)}
    return project.path_absolute(native,allocator),""
}

// The file a method is about to write, from path (api_output_path), in
// allocator: its folder is made, and the call fails saying why when the file
// cannot be written, before the work that would be lost.
api_output_file :: proc(s:^Session,call:^api.Call,path:string,allocator:=context.allocator) -> (file:string,ok:bool) {
    problem:string
    file,problem=api_output_path(s.project_root,path,context.temp_allocator)
    if problem!="" {api.call_fail(call,api.INVALID_PARAMS,problem);return "",false}
    if problem,code:=api_output_prepare(file);problem!="" {api.call_fail(call,code,problem);return "",false}
    return strings.clone(file,allocator),true
}

// Makes the folder of file, absolute, and opens it to write without
// changing it; problem says why it cannot be written, with the code of the error.
@(private)
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
// viewport. The pixels are of the allocator of the application.
@(private)
api_capture_image :: proc(s:^Session,ui:bool,size:[2]i32,generated:=false) -> (pixels:[]u8,width,height:int,ok:bool) {
    if ui {return host.app_capture_pixels(s.app,s.app.allocator,generated)}
    return host.app_capture_world(s.app,shown_world(s).data,API_CAPTURE_SETTLE,size,s.editor_world,s.app.allocator)
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
    result.scripted=run_script_ticks(run_script(s,r))
}

@(private)
api_play_start :: proc(s:^Session,call:^api.Call) {
    owner:=ai_task_of_call(s,call)
    if owner==0 && run_find(s,0)!=nil {
        api.call_fail(call,api.SERVER_ERROR,"A game is already playing: play.status says how it goes and play.stop ends it")
        return
    }
    params:=api.call_params(call,Api_Play_Start_Params)
    if params.from!=.Scene && (owner!=0 || params.simulate) {
        api.call_fail(call,api.INVALID_PARAMS,"from places player 1 of the Play of the editor: leave it out in a turn or with simulate")
        return
    }
    if params.simulate {
        // Simulate takes over the view of the user; a turn runs its own copy
        // and steps it without input instead.
        if owner!=0 {api.call_fail(call,api.SERVER_ERROR,"A turn simulates on its own copy: play.start, then play.step without keys");return}
        if params.players>0 || params.online>0 {api.call_fail(call,api.INVALID_PARAMS,"A simulation has no players: leave out players and online");return}
        if !simulation_start(s) {
            if simulating(s) {play_stop(s,true)}
            api.call_fail(call,api.SERVER_ERROR,"The simulation could not start")
            return
        }
        api_play_result(s,call,run_find(s,0))
        return
    }
    if plugin:=providers(s);params.online>0 && (!plugin.plays || plugin.play.start==nil || plugin.play.turn==nil) {
        api.call_fail(call,api.INVALID_PARAMS,"Online players need a plugin that plays games on the network: add multiplayer to the plugins of project.mirai")
        return
    }
    if params.players+params.online>PLAYER_PROCESSES {
        api.call_fail(call,api.INVALID_PARAMS,"players and online are 4 at most")
        return
    }
    switch params.from {
    case .Scene:  s.play_asked={}
    case .Camera: s.play_asked=camera_origin(s);s.play_asked.asked=true
    case .Point:  s.play_asked=point_origin(s,params.point)
    }
    if play_build_first(s,{owner=owner,players=params.players,online=params.online,ping_ms=params.ping_ms,saved_only=params.saved_only}) {
        api_play_after_build(s,call,owner)
        return
    }
    if error:=play_begin(s,owner,params.players,params.online,params.ping_ms,params.saved_only);error!="" {
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
    if !api_wait(s,API_BUILD_SECONDS,nil,build_play_waits) {
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
    if r!=nil {
        if r.owner==0 {play_stop(s,true)} else {run_stop(s,r.owner)}
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
    case r==nil: api.call_fail(call,api.SERVER_ERROR,"No game is playing; play.start first")
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
    if r==nil {
        api.call_fail(call,api.SERVER_ERROR,"No game is playing; play.start first")
        return
    }
    if !own {api_play_refused(call);return}
    owner:=r.owner
    timeline,ok:=api_step_timeline(call,params,s.app.tick_dt)
    if !ok {return}
    if owner==0 && simulating(s) && (api_timeline_input(timeline) || params.focus>=0) {
        api.call_fail(call,api.INVALID_PARAMS,"A simulation takes no player input")
        return
    }
    target:=run_player(s,owner,params.player)
    if target==nil {
        api.call_fail(call,api.INVALID_PARAMS,"That player has no run: play.start with online opens them")
        return
    }
    if api_timeline_input(timeline) {
        if problem:=run_script_blocks(s,target);problem!="" {api.call_fail(call,api.INVALID_PARAMS,problem);return}
    }
    values:[2]string
    api.object_values(call.allocator,call.raw,{"until","trace"},values[:])
    until:=params.until[:api_list_count(values[0])]
    if _,problem:=api_conditions_read(s,run_ref(s,target),until,nil,"until");problem!="" {api.call_fail(call,api.INVALID_PARAMS,problem);return}
    observe_raw:[1]string
    api.object_values(call.allocator,call.raw,{"targets"},observe_raw[:])
    targets:=observe_targets_read(call,params.targets[:],observe_raw[0],call.allocator)
    if len(targets)>0 && !params.observe {api.call_fail(call,api.INVALID_PARAMS,"targets are of observe: give observe true, or leave them out");return}
    run:=Api_Step_Run{owner=owner,player=params.player,timeline=timeline,until=until}
    trace:Api_Trace
    traced:=values[1]!=""
    if traced {
        if problem:=api_trace_read(s,call,run_ref(s,target),&params.trace,values[1],api_timeline_ticks(timeline),&trace);problem!="" {
            api.call_fail(call,api.INVALID_PARAMS,problem)
            return
        }
        run.sampler={every=params.trace.every,take=api_trace_take,data=&trace}
    }
    if params.focus>=0 && !api_seat_focus(s,call,target,params.focus) {return}
    ran,met,problem:=api_step_run(s,&run,api_step_frame)
    if problem!="" {api.call_fail(call,api.INVALID_PARAMS,problem);return}
    if params.observe {
        api_play_step_observe_write(s,call,run_find(s,owner),ran,len(until)>0 && met,targets,traced?&trace:nil)
        return
    }
    api_play_step_write(s,call,run_find(s,owner),ran,len(until)>0 && met,traced?&trace:nil)
}

// The elements of a JSON array as text; 0 for anything else.
@(private)
api_list_count :: proc(text:string) -> int {
    if text=="" {return 0}
    r:serial.Text_Reader
    serial.text_reader_init(&r,text,context.temp_allocator)
    if !serial.text_accept(&r,'[') || serial.text_accept(&r,']') {return 0}
    count:=0
    for serial.text_skip(&r) {
        count+=1
        if !serial.text_accept(&r,',') {break}
    }
    return count
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
    qa_log_focus(s,r,slot)
    return true
}

// One tick of play.step: every run of the game advances; the one of the
// player gets the input of step, or without one the next tick of its script.
// at: the tick of its segment; the first takes its pointer, wheel, taps and
// text, and the motion of the mouse is spread over all of them.
@(private)
api_step_tick :: proc(s:^Session,owner,player:int,step:^Api_Step_Input,at:int) {
    for &other in s.runs {
        if other.world==nil || other.owner!=owner {continue}
        other.step=true
        if other.player!=player {continue}
        step,at:=step,at
        scripted:Api_Step_Input
        if step==nil {
            scripted,at=run_script_take(run_script(s,&other))
            step=&scripted
        }
        qa_log_tick(s,&other,step,at)
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
    frame:platform.Input_Frame
    frame.keys_down,frame.keys_pressed,frame.keys_released=given.keys_down,given.keys_pressed,given.keys_released
    frame.keys_repeated=given.keys_pressed
    frame.mouse_down,frame.mouse_pressed,frame.mouse_released=given.mouse_down,given.mouse_pressed,given.mouse_released
    if .Left in given.mouse_pressed {frame.mouse_clicks[.Left]=1}
    frame.mouse_position,frame.mouse_inside,frame.wheel=given.mouse_position,true,given.wheel
    frame.gamepads=given.gamepads
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
    api_text_put(result.target[:],s.build.target==.Game?"game":"editor")
    api_text_put(result.game[:],s.build.game)
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
            api_text_put(row.file[:],d.file)
            api_text_put(row.message[:],d.message)
        }
    }
    has_error:=false
    for d in s.build.diagnostics {has_error||=d.severity==.Error}
    if has_error || s.build.phase==.Failed {api_text_put(result.message[:],api_build_first_error(s))}
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
    case:
        api.call_failf(call,api.INVALID_PARAMS,"target %q is editor, game or shaders",text)
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
    if s.build.phase==.Running {
        api.call_fail(call,api.SERVER_ERROR,"Another build is running: build.status says when it ends")
        return
    }
    if !s.has_project || s.engine_root=="" {
        api.call_fail(call,api.SERVER_ERROR,"Build needs a project and the root of the engine: start the editor with --engine or MIRAI_ROOT")
        return
    }
    if player_building(s) {
        api.call_fail(call,api.SERVER_ERROR,"The player of the project is being built: wait for it")
        return
    }
    if !build_start(s,target,out) {
        tool_call_fail(s,call,"The build could not start")
        return
    }
    build_running :: proc(s:^Session,user:rawptr) -> bool {return s.build.phase==.Running || s.build.reload}
    api_wait(s,f64(params.seconds),nil,build_running)
    api_build_result(s,call)
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
    api_text_put(result.target[:],"shaders")
}

Api_Build_Check_Params :: struct {
    seconds:int `mirai:"optional,min=1,max=3600,label=How long it may take before it is stopped"`,
}

Api_Build_Test_Params :: struct {
    package_folder:[256]u8 `mirai:"text,optional,label=Folder of the package under the project (game/enemies); game when empty"`,
    tests:[1024]u8 `mirai:"text,optional,label=Names of the tests to run, separated by commas; all of them when empty"`,
    seconds:int `mirai:"optional,min=1,max=3600,label=How long the build and the tests may take before they are stopped"`,
}

@(private) API_PROBE_DIAGNOSTICS :: `"diagnostics":{"type":"array","items":{"type":"object","properties":{"severity":{"enum":["Error","Warning"]},"file":{"type":"string"},"line":{"type":"integer"},"column":{"type":"integer"},"message":{"type":"string"}},"required":["severity","file","line","column","message"]}}`
@(private) API_CHECK_RESULT :: `{"type":"object","properties":{"ok":{"type":"boolean"},"failure":{"type":"string"},"seconds":{"type":"number"},"errors":{"type":"integer"},` + API_PROBE_DIAGNOSTICS + `,"text":{"type":"string"}},"required":["ok","failure","seconds","errors","diagnostics","text"],"additionalProperties":false}`
@(private) API_TEST_RESULT :: `{"type":"object","properties":{"ok":{"type":"boolean"},"failure":{"type":"string"},"seconds":{"type":"number"},"compiled":{"type":"boolean","description":"false: the package did not build; diagnostics say why"},"total":{"type":"integer"},"passed":{"type":"integer"},` +
    `"failed":{"type":"array","items":{"type":"object","properties":{"package":{"type":"string"},"name":{"type":"string"},"messages":{"type":"array","items":{"type":"string"},"description":"what it logged at error level and above, with where"}},"required":["package","name","messages"]}},` +
    `"errors":{"type":"integer"},` + API_PROBE_DIAGNOSTICS + `,"text":{"type":"string","description":"what the compiler or the tests printed, when they failed"}},"required":["ok","failure","seconds","compiled","total","passed","failed","errors","diagnostics","text"],"additionalProperties":false}`

@(private)
api_build_check :: proc(s:^Session,call:^api.Call) {
    params:=api.call_params(call,Api_Build_Check_Params)
    job,error:=code_probe(s,.Check,"",nil,f64(params.seconds))
    if error!="" {api.call_fail(call,api.SERVER_ERROR,error);return}
    defer build.job_destroy(job)
    out:=call.out
    serial.write_u8(out,'{')
    api_probe_write(out,&job.result)
    serial.write_u8(out,'}')
}

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
    job,error:=code_probe(s,.Test,path,names[:],f64(params.seconds))
    if error!="" {api.call_fail(call,api.SERVER_ERROR,error);return}
    defer build.job_destroy(job)
    out:=call.out
    report:=&job.result.tests
    serial.write_u8(out,'{')
    api_probe_write(out,&job.result)
    api.write_bool(out,"compiled",report.compiled)
    api.write_int(out,"total",i64(report.total))
    api.write_int(out,"passed",i64(report.passed))
    api.write_key(out,"failed");serial.write_u8(out,'[')
    for failure,i in report.failed {
        if i>0 {serial.write_u8(out,',')}
        serial.write_u8(out,'{')
        api.write_text(out,"package",failure.package_name,true)
        api.write_text(out,"name",failure.name)
        api.write_key(out,"messages");serial.write_u8(out,'[')
        for message,j in failure.messages {
            if j>0 {serial.write_u8(out,',')}
            serial.text_write_string(out,message)
        }
        serial.write_u8(out,']')
        serial.write_u8(out,'}')
    }
    serial.write_u8(out,']')
    serial.write_u8(out,'}')
}

// What a check or a run of the tests ended with, without the braces.
@(private)
api_probe_write :: proc(out:^serial.Writer,result:^build.Result) {
    texts:=FAILURE_TEXTS
    api.write_bool(out,"ok",result.status==.Built,true)
    api.write_text(out,"failure",texts[result.failure])
    api.write_key(out,"seconds");api.write_number(out,f32(result.seconds))
    errors:=0
    for d in result.diagnostics {if d.severity==.Error {errors+=1}}
    api.write_int(out,"errors",i64(errors))
    api.write_key(out,"diagnostics");serial.write_u8(out,'[')
    for d,i in result.diagnostics[:min(len(result.diagnostics),API_DIAGNOSTICS_LIMIT)] {
        if i>0 {serial.write_u8(out,',')}
        serial.write_u8(out,'{')
        api.write_text(out,"severity",fmt.tprint(d.severity),true)
        api.write_text(out,"file",d.file)
        api.write_int(out,"line",i64(d.line))
        api.write_int(out,"column",i64(d.column))
        api.write_text(out,"message",d.message)
        serial.write_u8(out,'}')
    }
    serial.write_u8(out,']')
    text:=result.status==.Built?"":result.text
    api.write_text(out,"text",api_text_whole(text[:min(len(text),API_DIAGNOSTICS_BUILD_TEXT)]))
}

// The shapes of the params of the methods that read them by hand.
@(private) API_INPUT_SCHEMA :: `{"type":"object","additionalProperties":false,"properties":{"events":{"type":"array","items":{"type":"object","additionalProperties":false,"properties":{"keys":{"type":"array","items":{"type":"string"},"description":"keys held in the frame; they replace the previous set"},"repeat_keys":{"type":"array","items":{"type":"string"},"description":"keys that repeat in the frame"},"mouse_buttons":{"type":"array","items":{"type":"string","enum":["left","right","middle"]},"description":"buttons held in the frame; they replace the previous set"},"mouse_position":{"type":"array","items":{"type":"number"},"minItems":2,"maxItems":2,"description":"points; excludes mouse_delta"},"mouse_delta":{"type":"array","items":{"type":"number"},"minItems":2,"maxItems":2,"description":"points; excludes mouse_position"},"wheel":{"oneOf":[{"type":"number"},{"type":"array","items":{"type":"number"},"minItems":2,"maxItems":2}]},"text":{"type":"string","description":"printable ASCII typed in the frame"},"clicks":{"type":"integer","minimum":1,"maximum":3},"dt":{"type":"number","exclusiveMinimum":0,"maximum":0.25,"description":"seconds"}}}},"dt":{"type":"number","exclusiveMinimum":0,"maximum":0.25,"description":"seconds"}}}`
@(private) API_CAMERA_SCHEMA :: `{"type":"object","additionalProperties":false,"properties":{"position":{"type":"array","items":{"type":"number"},"minItems":3,"maxItems":3},"target":{"type":"array","items":{"type":"number"},"minItems":3,"maxItems":3},"yaw":{"type":"number","description":"radians"},"pitch":{"type":"number","description":"radians"},"distance":{"type":"number","exclusiveMinimum":0},"fov":{"type":"number","minimum":1,"maximum":170,"description":"degrees, vertical"},"entity":{"type":"string","description":"an entity with a perspective Camera by its name, a path Parent/Child, its id or its handle: the camera takes its eye, where it looks and its fov, without changing the scene; excludes position, target, yaw and pitch"},"exposure":{"enum":["scene","camera","manual"],"description":"how the view exposes: as the Sky that is on, as the Camera of entity, or at ev100"},"ev100":{"type":"number","minimum":-10,"maximum":24,"description":"exposure value at ISO 100 of manual; alone, it chooses manual"},"frame":{"type":"array","maxItems":64,"items":{"type":"string"},"description":"entities by name, path or id the camera frames with what hangs from them, looking the way it looks now; excludes position, target and entity"},"from":{"type":"array","items":{"type":"number"},"minItems":3,"maxItems":3,"description":"with frame: the direction from what is framed to the camera"}}}`

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
