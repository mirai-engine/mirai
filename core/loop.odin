package core

import "core:math"
import "core:math/linalg"
import si "mirai:std/input"
import mm "mirai:std/math"

Phase :: enum u8 {Input,Fixed,Frame,Late,Ui,Render,Release} // Release runs once, when a World is freed
Phases :: bit_set[Phase;u8]
Loop :: enum u8 {Game,Editor}
Loops :: bit_set[Loop;u8]

PHASE_NAMES :: [Phase]string{.Input="input",.Fixed="fixed",.Frame="frame",.Late="late",.Ui="ui",.Render="render",.Release="release"}
LOOP_NAMES :: [Loop]string{.Game="game",.Editor="editor"}

// How often the simulation advances, whatever the frame rate: the physics, the
// fixed functions of the game and the network. A World takes the one of the
// application when it is made.
@(storage,host,setting)
Simulation_Settings :: struct {
    tick_rate:i32 `mirai:"min=10,max=480,unit=Hz"`, // fixed ticks per second
}

SIMULATION_SETTINGS_DEFAULT :: Simulation_Settings{tick_rate=60}

// The clock of the simulation of a world, copied with it. tick counts the
// fixed ticks simulated before the one that runs; seconds is the simulated
// time when it began. In the editor loop dt is 0 and playing is false. While
// resimulating, the fixed loop runs again ticks that already ran, to correct
// a prediction of the network: what is not simulation (a sound, a message, a
// request outside the world) does not happen again. Of the run: loading a
// scene keeps counting, and loading a save sets it.
@(storage,keep)
Time :: struct {
    tick:u64,
    seconds:f64,
    dt:f32,
    playing:bool,
    resimulating:bool,
}

// The clock after the fixed tick that ran: one tick and dt further.
time_advance :: proc "contextless" (t:^Time) {
    t.tick+=1
    t.seconds+=f64(t.dt)
}

// The frame that runs a world, not its simulation: never copied with it, so
// a Play and a rollback leave it as the frame has it. accumulator is the time
// of the frames the ticks have not simulated yet; alpha is how far the frame
// is between the last two ticks (1 in the editor loop). dilation makes the
// ticks run faster or slower than the frames: the function that keeps the
// clock of the world on another one (the network client, on its server's)
// writes it, and host reads it. A tick may run up to half a tick before or
// after its time so the frames keep a steady count of ticks: the accumulator
// then goes that far below zero or above one tick, and the shown time
// (accumulator - lag) stays between the last two ticks.
@(storage,copy=false)
Frame_Time :: struct {
    accumulator:f64, // s
    lag:f64,         // s the shown time trails the accumulator
    dt:f32,          // s, of the frame
    alpha:f32,
    phase:Phase,     // the phase that runs
    dilation:f32,    // added to the speed of the ticks: 0 at the pace of the frames, -1 stops them
    seen:i32,                  // frames counted in ran, at most TICK_HISTORY
    ran:[TICK_HISTORY]i32,     // ticks of the last i+1 frames
    typical:[TICK_HISTORY]i32, // ran[i] is usually this or one more
}

// Frames over which the count of ticks is kept steady: 144 Hz frames over 60 Hz ticks repeat
// every 12 frames.
TICK_HISTORY :: 12
FRAME_TIME_DEFAULT :: Frame_Time{alpha=1}

// How the simulation of a world runs as its game asked: paused, or at a scale
// of the time (slow motion). host multiplies the time of the frame by it; with
// no ticks the phases of the frame still run, so a pause menu works.
// clock_requests writes it; on a client of a network session, as the network
// asks with the clock of the server.
@(storage,keep)
Clock :: struct {
    paused:bool,
    scale:f32, // ticks per tick at the pace of the frames
}

CLOCK_DEFAULT :: Clock{scale=1}
CLOCK_SCALE_MAX :: f32(8)

Clock_Request_Kind :: enum u8 {
    Pause,
    Resume,
    Scale,
    Follow, // the clock of the server, paused and scale: what the network of a client gives its world
}

Clock_Request :: struct {
    kind:Clock_Request_Kind,
    scale:f32,
    paused:bool, // Follow
}

@(storage,queue,keep)
Clock_Requests :: struct {queue:Queue(Clock_Request)}

pause :: proc(r:^Clock_Requests) {push(&r.queue,Clock_Request{kind=.Pause})}
resume :: proc(r:^Clock_Requests) {push(&r.queue,Clock_Request{kind=.Resume})}
// scale in (0, CLOCK_SCALE_MAX]; 1 is the pace of the frames.
time_scale :: proc(r:^Clock_Requests,scale:f32) {push(&r.queue,Clock_Request{kind=.Scale,scale=scale})}
// The clock as the server of a network session has it: the network of a
// client follows it with this, the only request a client takes.
clock_follow :: proc(r:^Clock_Requests,paused:bool,scale:f32) {push(&r.queue,Clock_Request{kind=.Follow,scale=scale,paused=paused})}

// Takes what the game asked of its clock. In a network session the server
// keeps the clock of every end: a client follows it (clock_follow), and
// another request on a client is a problem.
@(step="input",stage="begin",loops="game")
clock_requests :: proc(requests:^Clock_Requests,clock:^Clock,network:Ref(Network),problems:^Problems) {
    if len(requests.queue.items)==0 {return}
    for r in take(&requests.queue) {
        if network.role==.Client && r.kind!=.Follow {
            report(problems,NONE,"core.clock_network","a client asked to %v its clock: in a network session the server pauses and scales the time of every end; ask on the server",r.kind)
            continue
        }
        if (r.kind==.Scale || r.kind==.Follow) && (!(r.scale>0) || r.scale>CLOCK_SCALE_MAX) {
            report(problems,NONE,"core.clock_scale","time scale %v is out of range: give one above 0 and up to %v, or pause the clock",r.scale,CLOCK_SCALE_MAX)
            continue
        }
        switch r.kind {
        case .Pause:  clock.paused=true
        case .Resume: clock.paused=false
        case .Scale:  clock.scale=r.scale
        case .Follow: clock.paused,clock.scale=r.paused,r.scale
        }
    }
}

// An entity that keeps a pace of its own while the Clock of its world runs
// slower or faster (bullet time). The libraries that move it by the time make
// up for the scale of the clock: the locomotion of its Character, its turn and
// its animation. The rest of the world, and what it throws, keeps the clock.
@(component,replicated,description="This entity keeps its own pace while the clock of the world runs slower or faster: its locomotion and its animation run rate times as fast as the frames, whatever the time scale.")
Own_Pace :: struct {
    rate:f32 `mirai:"min=0,max=8"`, // its seconds per second of the frames; 1: as if the clock did not scale
}

OWN_PACE_DEFAULT :: Own_Pace{rate=1}

// Seconds of the time of e per second of the simulation of its world: 1
// without an Own_Pace or with a rate out of (0, CLOCK_SCALE_MAX], and with no
// table (a caller that leaves it out).
pace_of :: proc "contextless" (clock:Clock,paces:^Table(Own_Pace,$A),e:Entity) -> f32 {
    if paces==nil {return 1}
    own,ok:=get(paces,e)
    if !ok || !(own.rate>0) || own.rate>CLOCK_SCALE_MAX || !(clock.scale>0) {return 1}
    return own.rate/clock.scale
}

@(step="fixed",stage="begin",loops="game")
own_paces_check :: proc(paces:^Table(Own_Pace,.Read),problems:^Problems) {
    for row in 0..<count(paces) {
        if rate:=at(paces,row).rate;!(rate>0) || rate>CLOCK_SCALE_MAX {
            report(problems,entity_at(paces,row),"core.own_pace","its Own_Pace has rate %v, so it keeps the clock of the world: give it one above 0 and up to %v",rate,CLOCK_SCALE_MAX)
        }
    }
}

Key :: si.Key
Keys :: si.Keys
Mouse_Button :: si.Mouse_Button
Mouse_Buttons :: si.Mouse_Buttons
Gamepad :: si.Gamepad
Gamepad_Button :: si.Gamepad_Button
Gamepad_Axis :: si.Gamepad_Axis
Gamepad_Family :: si.Gamepad_Family
Device :: si.Device
GAMEPAD_CAPACITY :: si.GAMEPAD_CAPACITY

// The input of the next fixed tick. pressed and released last one tick;
// mouse_delta and wheel accumulate since the tick before.
@(storage,keep)
Input :: struct {
    keys_down,keys_pressed,keys_released:Keys,
    mouse_down,mouse_pressed,mouse_released:Mouse_Buttons,
    mouse_position,mouse_delta:[2]f32, // window points, origin at the top left
    wheel:[2]f32,
    pressure:f32, // of the pen tip while it touches, 0 to 1; 1 with the mouse or without a pen
    eraser:bool,  // the eraser end of the pen touches
    gamepads:[GAMEPAD_CAPACITY]Gamepad,
    window_size:[2]f32,
    device:Device, // used last
}

// Presentation input for this frame, independent of the fixed tick
// accumulator. Of the frame, like Frame_Time: never copied with the world.
@(storage,copy=false)
Frame_Input :: struct {using input:Input}

key_down :: #force_inline proc "contextless" (input:Input,key:Key) -> bool {return key in input.keys_down}
key_pressed :: #force_inline proc "contextless" (input:Input,key:Key) -> bool {return key in input.keys_pressed}
key_released :: #force_inline proc "contextless" (input:Input,key:Key) -> bool {return key in input.keys_released}
mouse_down :: #force_inline proc "contextless" (input:Input,button:Mouse_Button) -> bool {return button in input.mouse_down}
mouse_pressed :: #force_inline proc "contextless" (input:Input,button:Mouse_Button) -> bool {return button in input.mouse_pressed}
mouse_released :: #force_inline proc "contextless" (input:Input,button:Mouse_Button) -> bool {return button in input.mouse_released}

// -1, 0 or 1 from two keys.
axis :: proc "contextless" (input:Input,negative,positive:Key) -> f32 {
    return (positive in input.keys_down?1:0)-(negative in input.keys_down?1:0)
}

input_join :: proc "contextless" (target:^Input,added:Input) {
    target.keys_down+=added.keys_down
    target.keys_pressed+=added.keys_pressed
    target.keys_released+=added.keys_released
    target.mouse_down+=added.mouse_down
    target.mouse_pressed+=added.mouse_pressed
    target.mouse_released+=added.mouse_released
    target.mouse_delta+=added.mouse_delta
    target.wheel+=added.wheel
}

// Where the frame is seen from: in the game, the active camera; in the
// editor, the camera of the viewport. Functions that depend on the point of
// view read it and work the same in both loops.
@(storage,shared,keep)
View :: struct {
    position:[3]f32,
    rotation:mm.Quat,
    fov:f32,       // vertical, radians
    near,far:f32,
    size:[2]f32,   // pixels of what it draws into
    camera:Entity, // the entity of the camera; NONE for the editor viewport
    cut:bool,      // the view jumped: history of the frame is discarded
    projection:View_Projection,
    height:f32,        // Orthographic: metres it covers from bottom to top
    shift:[2]f32,      // where the center of the projection is, in halves of the view: an off-center frustum
    custom:mm.Mat4,    // Custom: view space (x right, y up, looking down -z) to clip space, depth 1 at the nearest and 0 at the farthest
    clip_plane:[4]f32, // world plane (normal, distance) nothing is drawn behind; zero: none
    layers:u32,        // the layers of meshes it draws; 0: every one
    carried:mm.Mat4,   // the rigid transform that carried the camera since the last frame with what it sees: the image keeps its history. Zero: none
    exposure:View_Exposure,
    own:u8,            // 1 + the local slot whose body (render.View_Bodies) is the own body of this view; 0: none
    fade:f32,          // how much of its own body it leaves out: 1 all of it, below that a share of its pixels
    own_hidden:u32,    // the layers of its own body it does not draw
    slot:u8,           // 1 + the local view it is, which takes the effects of where it is (camera_local_views); 0: the view of the frame
    focus:f32,         // metres ahead of the eye, along where it looks, to what it looks at (the pivot of an orbit camera): the light the renderer gathers around the view centres there. 0: on the eye
}

View_Projection :: enum u8 {Perspective,Orthographic,Custom}

// How a view exposes its image. Zero: Auto at once, over the renderer's range.
View_Exposure :: struct {
    mode:View_Exposure_Mode,
    ev100:f32,        // Manual: the exposure value at ISO 100
    compensation:f32, // EV added to what the camera gives: +1 doubles the light of the image
    range:[2]f32,     // Auto: the lowest and highest EV100 it takes; zero: the renderer's
    adaptation:f32,   // Auto, Time: seconds to come 95 % of the way to less light, half of that to more light; Speed: seconds for each EV of less light, a third of that for each EV of more; 0: at once
    adaptation_mode:View_Exposure_Adaptation,
    own:bool,         // the camera has an Exposure, which replaces that of the scene
    tint:[3]f32,      // multiplies the image before the display; zero: none
}

View_Exposure_Mode :: enum u8 {Auto,Manual}
View_Exposure_Adaptation :: enum u8 {Time,Speed}

VIEW_DEFAULT :: View{position={0,2,6},rotation=1,fov=60*mm.RAD_PER_DEG,near=0.1,far=0}

view_forward :: proc "contextless" (v:View) -> [3]f32 {return mm.quat_forward(v.rotation)}

// The ray from the eye through a point of the window, in pixels from the top left.
view_ray :: proc "contextless" (v:View,pixel:[2]f32) -> (origin,direction:[3]f32) {
    size:=[2]f32{max(v.size.x,1),max(v.size.y,1)}
    ndc:=[2]f32{2*pixel.x/size.x-1,1-2*pixel.y/size.y}
    half:=math.tan(v.fov*0.5)
    local:=[3]f32{ndc.x*half*size.x/size.y,ndc.y*half,-1}
    return v.position,linalg.normalize(mm.quat_rotate(v.rotation,local))
}

// Where a world point shows in the view, in pixels of its size from the top
// left, and how far ahead of the eye it is along where it looks. front is
// false for a point behind the eye, whose pixel means nothing.
view_project :: proc "contextless" (v:View,point:[3]f32) -> (pixel:[2]f32,depth:f32,front:bool) {
    size:=[2]f32{max(v.size.x,1),max(v.size.y,1)}
    local:=mm.quat_rotate(mm.quat_inverse(v.rotation),point-v.position)
    depth=-local.z
    ndc:[2]f32
    switch v.projection {
    case .Custom:
        clip:=v.custom*[4]f32{local.x,local.y,local.z,1}
        if !(clip.w>0) {return {},depth,false}
        ndc=clip.xy/clip.w
    case .Orthographic:
        if !(v.height>0) {return {},depth,false}
        ndc=[2]f32{2*local.x/(v.height*size.x/size.y),2*local.y/v.height}+v.shift
    case .Perspective:
        if !(depth>0) {return {},depth,false}
        half:=math.tan((v.fov>0?v.fov:VIEW_DEFAULT.fov)*0.5)
        ndc=[2]f32{local.x/(depth*half*size.x/size.y),local.y/(depth*half)}+v.shift
    }
    return {(ndc.x*0.5+0.5)*size.x,(0.5-ndc.y*0.5)*size.y},depth,depth>0
}
