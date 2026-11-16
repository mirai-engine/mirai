package mirai_input

// The devices a window system reports, as plain data: the platform layer
// writes them and a game reads them through the sdk, both with these types.

// US keyboard. Append new keys at the end: the values are bit indices of Keys.
Key :: enum u8 {
    A,B,C,D,E,F,G,H,I,J,K,L,M,N,O,P,Q,R,S,T,U,V,W,X,Y,Z,
    Zero,One,Two,Three,Four,Five,Six,Seven,Eight,Nine,
    F1,F2,F3,F4,F5,F6,F7,F8,F9,F10,F11,F12,
    Escape,Enter,Tab,Space,Backspace,Delete,Insert,
    Home,End,Page_Up,Page_Down,Left,Right,Up,Down,
    Left_Shift,Right_Shift,Left_Control,Right_Control,Left_Alt,Right_Alt,Left_Super,Right_Super,
    Minus,Equals,Left_Bracket,Right_Bracket,Semicolon,Apostrophe,Comma,Period,Slash,Backslash,Grave,
}
#assert(len(Key)<=128)
Keys :: bit_set[Key;u128]

Mouse_Button :: enum u8 {Left,Right,Middle,X1,X2}
Mouse_Buttons :: bit_set[Mouse_Button;u8]

GAMEPAD_CAPACITY :: 4
Gamepad_Button :: enum u8 {
    South,East,West,North,Back,Guide,Start,Left_Stick,Right_Stick,Left_Shoulder,Right_Shoulder,
    Dpad_Up,Dpad_Down,Dpad_Left,Dpad_Right,
}
Gamepad_Buttons :: bit_set[Gamepad_Button;u32]
// Sticks from -1 to 1 with Y positive downward; triggers from 0 to 1. No dead zone is applied.
Gamepad_Axis :: enum u8 {Left_X,Left_Y,Right_X,Right_Y,Left_Trigger,Right_Trigger}
// How a gamepad labels its buttons; one the window system does not name looks like Xbox.
Gamepad_Family :: enum u8 {Xbox,PlayStation,Nintendo}
Gamepad :: struct {
    connected:bool,
    down,pressed,released:Gamepad_Buttons,
    axes:[Gamepad_Axis]f32,
    family:Gamepad_Family,
}

// The device used last: the keyboard and the mouse, or the gamepad of a slot.
Device :: struct {gamepad:bool,slot:u8}
