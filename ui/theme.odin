package ui

// Colors are display (sRGB) values.

Theme :: struct {
    backdrop:Color,
    bar_top,bar_bottom:Color,
    panel,popup,raised:Color,
    field,field_hover,field_active:Color,
    well,well_stroke,well_stroke_hover:Color, // what a value is typed or chosen in: darker than its panel, outlined
    border,divider:Color,
    rule:Color,        // edge of a component and the line of a subsection
    row_rule:Color,    // between the rows of a card and the lines of a table
    card:Color,        // a card inside a panel: a section of settings, a part of a document
    band:Color,        // the title of a section, a band over what it holds, which sits on the panel
    chip,chip_on:Color, // a small tag over a panel, and one that is on
    toggle_on,toggle_on_stroke:Color, // a button of style Toggle while it is on
    success:Color,     // what is connected or working
    text,text_muted,text_faint:Color,
    text_caption:Color, // the titles of sections, in capitals
    text_label:Color,  // names of the property rows
    text_body:Color,   // text read at length, as the answers of an agent
    accent,accent_hover,accent_soft:Color,
    text_select,on_accent:Color,
    danger,danger_soft:Color,
    shadow:Color,
    focus:Color,       // ring around the widget keyboard or gamepad navigation is on; alpha 0: none
    axis:[4]Color,     // strips of the fields of a vector: X, Y, Z, W
    channel:[4]Color,  // strips of the fields of a color: R, G, B, A

    radius_panel,radius_popup,radius_control:f32,

    // Em sizes of the roles of text, in layout units: CSS pixels.
    font,font_small,font_label,font_title:f32,
    font_heading:f32,  // the name of what a panel shows
    font_caption:f32,  // the titles of sections, in capitals
    font_axis:f32,     // letter of a field with a label inside, in FONT_MEDIUM

    bar_height:f32,
    margin:f32,        // between a floating panel and the edge of the surface
    row:f32,           // height of a control; property rows add the gap between them
    control:f32,       // height of a button of a bar, a menu row and a search
    label_width:f32,   // column of the labels of property rows
    wheel_step:f32,    // layout units a wheel notch scrolls

    // A press activates buttons, as in the editor; otherwise the release over them does.
    activate_on_press:bool,
}

// Graphite and violet: neutral greys a step lighter at each layer (bar, panel,
// field, raised) so a panel stands out from what is behind it and a field from
// its panel, and a saturated violet, for what matters most, that keeps white
// text above 4.5:1.
THEME_EDITOR :: Theme{
    backdrop     = {6,6,9,170},
    bar_top      = {11,11,14,255},
    bar_bottom   = {11,11,14,255},
    panel        = {27,27,32,255},
    popup        = {38,38,44,255},
    raised       = {52,52,61,255},
    field        = {44,44,52,255},
    field_hover  = {52,52,61,255},
    field_active = {58,52,96,255},
    well         = {18,18,21,255},
    well_stroke  = {60,60,70,255},
    well_stroke_hover = {92,92,106,255},
    border       = {58,58,68,255},
    divider      = {46,46,54,255},
    rule         = {255,255,255,30},
    row_rule     = {255,255,255,16},
    card         = {39,39,47,255},
    band         = {42,42,51,255},
    chip         = {255,255,255,9},
    chip_on      = {255,255,255,22},
    toggle_on    = {36,30,68,255},
    toggle_on_stroke = {112,80,240,255},
    success      = {107,210,138,255},
    text_caption = {184,184,194,255},
    text         = {242,242,245,255},
    text_muted   = {184,184,194,255},
    text_faint   = {142,142,153,255},
    text_label   = {184,184,194,255},
    text_body    = {212,212,219,255},
    accent       = {112,80,240,255},
    accent_hover = {129,105,245,255},
    accent_soft  = {46,37,96,255},
    text_select  = {92,70,200,255},
    on_accent    = {255,255,255,255},
    danger       = {255,112,112,255},
    danger_soft  = {255,150,150,255},
    shadow       = {},
    focus        = {},
    axis         = {{239,90,90,255},{76,199,119,255},{75,142,240,255},{179,179,189,255}},
    channel      = {{230,90,90,255},{90,200,110,255},{90,140,240,255},{150,150,160,255}},

    radius_panel   = 8,
    radius_popup   = 6,
    radius_control = 5,

    font       = 13,
    font_small = 12,
    font_label = 12,
    font_title = 17,
    font_heading = 15,
    font_caption = 11,
    font_axis  = 10.5,

    bar_height  = 40,
    margin      = 16,
    row         = 26,
    control     = 30,
    label_width = 88,
    wheel_step  = 36,

    activate_on_press = true,
}

// Layers of floating surfaces: the highest one under the pointer takes it.
LAYER_PANEL   :: i16(1)
LAYER_BAR     :: i16(2)
LAYER_TOAST   :: i16(3)
LAYER_POPUP   :: i16(10)
LAYER_TOOLTIP :: i16(11)
LAYER_MODAL   :: i16(20)

AXIS_NAMES :: [4]string{"X","Y","Z","W"}
CHANNEL_NAMES :: [4]string{"R","G","B","A"}
