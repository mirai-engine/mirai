package ui

import "mirai:std/base"

// What the game gives the interfaces it builds and the ui package does not
// own: its input, its texts, its textures, its cameras and its sounds. Any
// procedure may be nil; what needs it then shows what it shows without one.
Game_Source :: struct {
    user:rawptr,
    family:Prompt_Family, // of the device the player used last
    // The prompts of an action, by the name_hash of its name, as the family shows them.
    prompts:proc(user:rawptr,action:u64,family:Prompt_Family,out:[]Prompt) -> int,
    // Whether an action is held, and whether it was pressed since the last frame.
    action:proc(user:rawptr,action:u64) -> (down,pressed:bool),
    // What the localized nodes read their keys in: the texts of the game
    // and the code of the language they show in ("es", "pt-BR"), as
    // base.text finds it; empty, the one each key was written in.
    texts:^base.Texts,
    language:string,
    // What an Image shows for a texture asset.
    texture:proc(user:rawptr,id:base.Asset_Id) -> Quad,
    // What a camera sees, at a size in layout units.
    view:proc(user:rawptr,camera:base.Entity,size:[2]f32) -> Quad,
    // A particle effect playing in a rectangle of a size in layout units:
    // id is the element that shows it, which keeps it alive while it is built.
    particles:proc(user:rawptr,id:Id,effect:base.Asset_Id,size:[2]f32) -> Quad,
    // Plays a sound a style names.
    sound:proc(user:rawptr,id:base.Asset_Id),
}

// What Context.draw_user is handed to draw a canvas, an icon or a Draw node: where
// the layout put it and, of a Draw node, the colors and the text of its style
// and the bytes of the value it binds, as the interface copied them last. What it draws outside
// the container that clips the node is cut. A screen that did not change is
// shown again from what it drew: the procedure runs when the node is built,
// so it draws from node alone, and what it reads of the game is what the
// node binds.
Draw_Node :: struct {
    name:u64,          // what draws it: of a Draw node, name_hash of its draw
    rect:Rect,         // in layout units
    fill,stroke,track,knob,mark:Color,
    text:Text_Style,
    radius:[4]f32,
    stroke_width:f32,
    data:[]u8,         // of the field the node binds as its value; nil: it binds none
    item:i32,          // the element of the List the node is in; -1: in none
}

// The value a Draw node binds, as the type the game declares it with; false
// when the node binds none, or a field of another size.
draw_value :: proc "contextless" (node:Draw_Node,$T:typeid) -> (value:^T,ok:bool) {
    if len(node.data)!=size_of(T) || uintptr(raw_data(node.data))%align_of(T)!=0 {return nil,false}
    return (^T)(raw_data(node.data)),true
}
