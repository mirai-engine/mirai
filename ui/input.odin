package ui

// What the host hands a context every frame. The platform layer fills it from
// its events; nothing here knows about windows or devices.

Mouse_Button :: enum u8 {Left,Right,Middle,Back}
Mouse_Buttons :: bit_set[Mouse_Button;u8]

// The keys the library itself gives a meaning to. Shortcuts of the host are
// its own business.
Key :: enum u8 {Left,Right,Up,Down,Home,End,Page_Up,Page_Down,Backspace,Delete,Enter,Escape,Tab,Space,A,C,V,X}
Keys :: bit_set[Key;u32]

Modifier :: enum u8 {
    Shift,
    Primary, // Ctrl, or Cmd on macOS
    Alt,
}
Modifiers :: bit_set[Modifier;u8]

// Gamepad navigation, already mapped by the host from its buttons and sticks.
Pad :: enum u8 {Up,Down,Left,Right,Accept,Cancel,Next,Previous}
Pads :: bit_set[Pad;u8]

INPUT_TEXT_CAPACITY :: 32

// A ray that points at world panels: the mouse through the camera, a
// controller, the center of the screen. A panel that the scene in front of
// it hides, as scene says, is not reached; without scene nothing is known to
// be in the way.
World_Ray :: struct {origin,direction:[3]f32,valid:bool,scene:Ray_Scene}
// Whether the scene hides point, a place the ray meets: what is in front of
// it along the view, by more than share of its depth plus metres. user: what
// the host gives hides, which lives while the frame is built.
Ray_Scene :: struct {
    hides:proc(user:rawptr,point:[3]f32,share,metres:f32) -> bool,
    user:rawptr,
}

// The camera world panels are placed for. rotation: camera to world, looking
// down -Z with +Y up.
World_View :: struct {
    position:[3]f32,
    rotation:quaternion128,
    fov_y:f32,           // radians
    viewport_height:f32, // window points
}

Input :: struct {
    size:[2]f32,     // the surface, in window points
    scale:f32,       // layout units to window points; 0 means 1
    safe:[4]f32,     // insets of the safe area in window points: left, top, right, bottom
    dt:f32,          // seconds since the previous frame
    pointer:[2]f32,  // window points
    pointer_absent:bool, // no pointer hovers the surface (gamepad only, cursor captured)
    down,pressed,released:Mouse_Buttons,
    clicks:u8,       // consecutive clicks counted for the left press of this frame: 2 on a double click
    wheel:[2]f32,    // notches; positive y scrolls towards the top
    keys_down:Keys,
    keys_pressed:Keys,  // went down this frame
    keys_repeated:Keys, // went down this frame or auto-repeated
    modifiers:Modifiers,
    pad:Pads,           // pressed this frame or auto-repeated
    // Analog sticks, as held now: -1 to 1 on each axis past the dead zone, y
    // down. scroll (the right stick) moves the content of the scroll area the
    // keys reach SCROLL_STICK units a second all the way over; aim (the left
    // stick) chooses in a Radial.
    scroll,aim:[2]f32,
    text:[INPUT_TEXT_CAPACITY]u8, // printable ASCII typed this frame
    text_count:int,
    ray:World_Ray,
    view:World_View,
}

// Forgets what happened during the previous frame and keeps what is held.
input_next_frame :: proc "contextless" (input:^Input) {
    input.pressed={};input.released={};input.clicks=0;input.wheel={}
    input.keys_pressed={};input.keys_repeated={};input.pad={};input.text_count=0
}
input_button :: proc "contextless" (input:^Input,button:Mouse_Button,down:bool,clicks:u8=1) {
    if down {
        input.down+={button};input.pressed+={button}
        if button==.Left {input.clicks=max(clicks,1)}
    } else {
        input.down-={button};input.released+={button}
    }
}
input_key :: proc "contextless" (input:^Input,key:Key,down:bool,repeat:bool=false) {
    if down {
        input.keys_down+={key};input.keys_repeated+={key}
        if !repeat {input.keys_pressed+={key}}
    } else {input.keys_down-={key}}
}
// Only printable ASCII is text: the rest of a US keyboard arrives as keys.
input_text :: proc "contextless" (input:^Input,character:rune) {
    if character<32 || character>126 || input.text_count>=INPUT_TEXT_CAPACITY {return}
    input.text[input.text_count]=u8(character);input.text_count+=1
}
