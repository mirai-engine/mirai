package mirai_ui_format

// What the structure of a .ui is judged by: the kinds of its nodes and which
// of them hold others, the fields a use of a widget overrides, the kinds of
// its animations and the limits of the tree its records are built into. The
// ui package builds the tree and the asset package checks its file, both by
// these: neither imports the other.

Node_Kind :: enum u8 {
    Box,      // a container
    Text,
    Image,
    Progress, // shows its bound value, 0 to 1
    Button,   // reports Clicked; one that binds a value writes choice there when clicked
    Checkbox, // edits its bound bool and reports Changed
    Spacer,
    Component, // authoring only: expanded into a Box subtree at load
    Scroll,   // a container whose content moves with the wheel when it does not fit
    Switcher, // a container that builds one of the nodes it holds: bound to an enum or a text, the one of that name; bound to a number, the one at that position; else index
    List,     // a container that builds the one node it holds once per element of the array bind_items names
    Prompt,   // the prompts of its action, as the device the player holds shows them
    Slider,   // edits its bound number between range[0] and range[1], in steps of range[2]
    Field,    // edits its bound text, as an ASCII keyboard types it, with its own text as the placeholder; Enter reports Submitted
    Selector, // steps through its options (bind_items, or its text separated by '|'): its bound value is the index, or, for options written Label=Value, the value of the one chosen (a number, the name of a member of an enum, or a text for a text field)
    Dropdown, // picks one of its options, as a Selector has them, from a list that opens under it
    Radio,    // selected while its bound value equals choice; choosing it writes choice there
    Tooltip,  // a container built next to the node that holds it while that one is hovered or focused
    Rich_Text, // text with markup: <b>, <i>, <u>, <s>, <color=#rrggbb>, <size=n>, <link=name>, <img=name>, <prompt=action>
    View,     // what the camera its bound entity is sees
    Action_Bar, // the prompts and texts of the buttons of its tree that an action clicks
    Number,   // edits its bound number in a field with arrows, between range[0] and range[1], in steps of range[2]
    Tabs,     // a container with a strip of tabs, one per node it holds, and the page of the one chosen
    Popup,    // a container that floats from its parent while its bound value, or its parent clicked, opens it
    Modal,    // a container centered over a backdrop that takes all input while it is shown
    Context_Menu, // a container that opens at the pointer when its parent is clicked with the right button
    Radial,   // a container that places what it holds on a circle, chosen by direction
    Particles, // a .particle of the project, playing in its rectangle
    Draw,     // a rectangle the procedure of the game its draw names draws, with the colors of its style and the bytes of the value it binds
}
Node_Kinds :: bit_set[Node_Kind;u32]

// The kinds that hold other nodes.
node_kind_holds :: #force_inline proc "contextless" (kind:Node_Kind) -> bool {
    switch kind {
    case .Box,.Scroll,.Switcher,.List,.Tooltip,.Tabs,.Popup,.Modal,.Context_Menu,.Radial: return true
    case .Text,.Image,.Progress,.Button,.Checkbox,.Spacer,.Component,.Prompt,.Slider,.Field,.Selector,.Dropdown,.Radio,.Rich_Text,.View,.Action_Bar,.Number,.Particles,.Draw:
    }
    return false
}

// What a use of a widget, or an override of one of its nodes, sets.
Node_Field :: enum u8 {
    Text, Style, Layout, Float, Image, Animations, Bindings, Visibility, Variant, Layer, Clip, Block,
    Values, // index, count, choice, range, limit, delay, particle and draw
    Action, // action and hold
    Focus,  // nav, order and flags
    Drag,   // tag, accepts and ghost
}
Node_Fields :: bit_set[Node_Field; u32]
NODE_FIELDS_UNKNOWN :: ~u32(1<<len(Node_Field)-1) // bits of Node_Fields that name no field

Anim_Kind :: enum u8 {
    Clip,     // tracks that play together
    Sequence, // animations one after another
    Parallel, // animations together
}

TREE_DEPTH :: 32       // nodes one inside another
TREE_CLIP_TRACKS :: 16 // tracks of one clip

FONT_CAPACITY :: 16 // fonts of a context
// A style whose text has a font of FONT_TREE or more takes the font of row
// font-FONT_TREE of the fonts of its file; a lower one, that font of the context.
FONT_TREE :: 16

// Whether the font a style names exists, in a file with that many rows of fonts.
style_font_exists :: proc "contextless" (font:u8,rows:int) -> bool {
    if font<FONT_TREE {return font<FONT_CAPACITY}
    return int(font)-FONT_TREE<rows
}
