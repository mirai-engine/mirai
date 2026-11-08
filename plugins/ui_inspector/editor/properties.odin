package ui_inspector_editor

import "core:fmt"
import "mirai:core"
import "mirai:editor"
import inp "mirai:engine/input"
import "mirai:host"
import gpu "mirai:render"
import "mirai:std/base"
import "mirai:std/serial"
import "mirai:ui"

// The properties of the node chosen, in cards of the sections a node of its
// kind uses, with the rows of Details: each arrow gives a field back the value
// a new node of its kind has (of a style, the value of the style it
// overrides), and the name of a field describes it. What few
// interfaces need waits in Advanced, closed. The search leaves the rows whose
// name lacks it, and the cards with none left; a card whose title it finds
// shows whole. A node inside a widget instance shows its values, which only
// its widget changes. The animations, styles and fonts of the file close the
// column, with or without a node chosen.
//
// A node has a style with a name, which nodes of its family share, or None:
// a look of its own. A named style is not changed from a node: the first
// change makes the node an override of it, marked *, which Apply to style
// writes into that style and Revert drops; + turns it into a style of its
// own. A look of its own that other nodes have too (or the first row, which
// new nodes take) is copied for the node at its first change.

@(private) Texture_Pick :: struct {texture:base.Asset_Id}
@(private) Sound_Pick :: struct {sound:base.Asset_Id}
@(private) Font_Pick :: struct {font:base.Asset_Id}
@(private) Particle_Pick :: struct {particle:base.Asset_Id}

// One value as the rows of Details show it, by the type and tag of its field.
@(private) Name_Value :: struct {value:[ui.TREE_NAME_CAPACITY]u8 `mirai:"text"`}
@(private) Path_Value :: struct {value:[ui.TREE_PATH_CAPACITY]u8 `mirai:"text"`}
@(private) Text_Value :: struct {value:[TEXT_EDIT]u8 `mirai:"text"`}
@(private) Corners_Value :: struct {value:[4]f32 `mirai:"min=0,axes=TL TR BR BL"`}
@(private) Flag_Value :: struct {value:bool}
@(private) Positive_Value :: struct {value:f32 `mirai:"min=0"`}
@(private) Seconds_Value :: struct {value:f32 `mirai:"min=0,unit=s"`}
@(private) Unit_Value :: struct {value:f32 `mirai:"min=0,max=1"`}
@(private) Count_Value :: struct {value:u16}
@(private) Span_Value :: struct {value:u8 `mirai:"min=0,max=12"`}
@(private) Order_Value :: struct {value:i16}
@(private) Enum_Value :: struct($E:typeid) {value:E}
// What a node is when it is not visible: it keeps its room, or it takes none.
@(private) Visibility :: enum u8 {Visible,Hidden,Collapsed}
@(private) Hidden_As :: enum u8 {Hidden,Collapsed}
@(private) Align_X_Value :: struct {value:ui.Align `mirai:"icons=Align_Left Align_Center_X Align_Right"`}
@(private) Align_Y_Value :: struct {value:ui.Align `mirai:"icons=Align_Top Align_Center_Y Align_Bottom"`}
@(private) Color_Value :: struct {value:[4]f32 `mirai:"color"`}
@(private) Pair_Value :: struct {value:[2]f32}
@(private) Limits_Value :: struct {value:[2]f32 `mirai:"min=0,axes=Min Max"`}
@(private) Frames_Value :: struct {value:[2]u16 `mirai:"axes=Columns Rows"`}
@(private) Sides_Value :: struct {value:[4]f32 `mirai:"min=0,axes=LTRB"`}
@(private) Part_Value :: struct {value:[4]f32 `mirai:"min=0,max=1,axes=XYWH"`}
@(private) Border_Uv_Value :: struct {value:[4]f32 `mirai:"min=0,max=0.5,axes=LTRB"`}
@(private) Range_Value :: struct {value:[3]f32 `mirai:"axes=Min Max Step"`}
@(private) Program_Value :: struct {value:[4]f32 `mirai:"axes=ABCD"`}

// What the rows are built with: the session, for the rows of Details, the
// search, by which a card waits for the first row it shows, and the style
// the node edits.
@(private)
Pane :: struct {
    s:^editor.Session,
    u:^Ui_Inspector,
    needle:string,
    width:f32,      // of the rows
    pending:string, // the title of the card that waits for a row; empty: none
    which:Section,
    icon:ui.Icon,
    card,body:bool, // the card is open, and its rows under its band
    whole:bool,     // the search found its title: every row shows
    found:bool,     // a card opened
    style:Style_Edit,
    bind_open:bool, // a row of bindable is open
    flush:bool,     // the next row ends at the edge: its controls leave no room for an arrow
    look:Look,      // what the rows of Style and Text edit
    readonly:bool,  // the rows of the cards show values nothing here changes: a node of a widget
    band:string,    // the state whose band waits for the first row the search shows; empty: none
    banded:bool,    // a band is open
}

// The style the rows of Style, Text and States change: a copy, while the
// node does not override a style it has to leave as it is, or the style.
@(private)
Style_Edit :: struct {
    row:int,
    draft:bool,
    own:bool,                                // the draft is a look of the node's own, not an override
    values:ui.Node_Style,                    // the copy
    defaults:ui.Node_Style,                  // what the arrows give back: the style it overrides, or itself
    variants:[dynamic]ui.Tree_Style_Variant, // those of the copy, in the temporary allocator
    label:string,                            // the step a change becomes; empty: no change
}

@(private)
properties :: proc(s:^editor.Session,u:^Ui_Inspector,a:^host.Assets,width:f32) {
    ctx:=s.gui.ctx
    th:=&ctx.theme
    ux_sync(u)
    // As Details: the rows of a card, short of its padding and that of the scroll.
    p:=Pane{s=s,u=u,needle=string(u.search[:u.search_length]),width=width-28}
    // A node inside a widget: its records are the widget's, and nothing of them changes here.
    x:=&u.ux
    if x.peek.instance>=0 && x.peek.instance==u.selected && u.scope<0 {
        if w:=widget_records(u,a,x.peek.widget);w!=nil && x.peek.row<len(w.nodes) {
            records:=u.records
            selected,pending,change,label:=u.selected,u.pending,u.change,u.label
            u.records=w^
            u.selected=x.peek.row
            p.readonly=true
            properties_node(&p,a)
            u.records=records
            u.selected,u.pending,u.change,u.label=selected,pending,change,label
            if !p.found {ui.label(ctx,"No property has that name",th.font_small,th.text_muted)}
            return
        }
        x.peek.instance=-1
    }
    // What the document binds that the game does not have, or why it does not load, until it is fixed.
    for &problem,i in u.problem[:u.problem_count] {
        if ui.box(ctx,{width=ui.GROW,height=ui.FIT,padding={8,6,8,6},gap=6,align_y=.Center,fill=ui.color_alpha(th.danger,36),stroke=ui.color_alpha(th.danger,120),radius=4}) {
            ui.paragraph(ctx,bind_problem_text(a,&problem),th.font_small,th.text)
            if problem.row>=0 && problem.row!=u.selected && u.scope<0 {
                if ui.button(ctx,ui.id(ctx,"problem_node",i+1),{label="Show",style=.Ghost,height=th.row,size=th.font_small}).clicked {choose_rows(u,{problem.row})}
            }
        }
    }
    if selected_node(u)==nil {
        ui.label(ctx,"Choose a node",th.font_small,th.text_muted)
    } else {properties_node(&p,a)}
    n:=selected_node(u)
    if section(&p,.Animations,"Animations of the file",.Play,whole=true) {section_animations(&p,n)}
    section_end(&p)
    if section(&p,.Styles,"Styles of the file",.Palette,whole=true) {section_styles(&p,n)}
    section_end(&p)
    section_fonts(&p,a)
    if !p.found {ui.label(ctx,"No property has that name",th.font_small,th.text_muted)}
}

// The cards of the node chosen.
@(private)
properties_node :: proc(p:^Pane,a:^host.Assets) {
    n:=selected_node(p.u)
    if n==nil {return}
    if section(p,.Node,"Node",node_icon(n)) {section_node(p,a,n)}
    section_end(p)
    if n.kind==.Component {
        if section(p,.Component,"Widget",.Prefab,whole=true) {section_component(p,a,n)}
        section_end(p)
    }
    if section(p,.Layout,"Layout",.Grid) {section_layout(p,n)}
    section_end(p)
    // Only what holds nodes floats, and only what takes the focus, or holds what does, navigates.
    if ui.node_kind_holds(n.kind) || n.kind==.Component {
        if section(p,.Floating,"Floating",.Layers) {section_floating(p,n)}
        section_end(p)
    }
    if focusable(n.kind) || ui.node_kind_holds(n.kind) {
        if section(p,.Focus,"Focus",.Focus) {section_focus(p,n)}
        section_end(p)
    }
    if n.kind!=.Component && n.kind!=.Spacer {
        style_edit_begin(p,n)
        if section(p,.Style,"Style",.Palette) {section_style(p,a,n)}
        section_end(p)
        if section(p,.Events,"Events",.Lightning) {section_events(p,n)}
        section_end(p)
        style_edit_end(p,n)
    }
    // An Image shows it; a Box, a Button and a Progress draw it behind, as a brush.
    if n.kind==.Image || n.kind==.Box || n.kind==.Button || n.kind==.Progress {
        if section(p,.Image,"Image" if n.kind==.Image else "Background image",.Texture,whole=true) {section_image(p,n)}
        section_end(p)
    }
}

// The line of the node chosen over the scroll: the icon of its kind and its
// name, as Details shows an entity; a node of a widget, and the widget.
@(private)
properties_head :: proc(s:^editor.Session,u:^Ui_Inspector) {
    ctx:=s.gui.ctx
    th:=&ctx.theme
    n:=selected_node(u)
    x:=&u.ux
    if ui.box(ctx,{width=ui.GROW,height=ui.fixed(editor.INSPECTOR_HEAD),padding={11,0,7,0},gap=6,align_y=.Center}) {
        if n==nil {
            ui.label(ctx,"Properties",th.font_heading,th.text,0,font=ui.FONT_SEMIBOLD)
            return
        }
        if x.peek.instance==u.selected && x.peek.instance>=0 {
            if w:=widget_records(u,s.app.assets,x.peek.widget);w!=nil && x.peek.row<len(w.nodes) {
                peeked:=&w.nodes[x.peek.row]
                ui.icon(ctx,node_icon(peeked),th.text_muted,15)
                labels:=KIND_LABELS
                name:=serial.text_field(peeked.name[:])
                ui.label(ctx,name if name!="" else labels[peeked.kind],th.font_heading,th.text,0,font=ui.FONT_SEMIBOLD)
                ui.spacer(ctx)
                ui.label(ctx,editor.asset_name_of(s.app.assets,x.peek.widget,"missing"),th.font_small,th.text_faint,0)
                return
            }
        }
        ui.icon(ctx,node_icon(n),th.text_muted,15)
        length:=len(serial.text_field(n.name[:]))
        from:=n.name
        if ui.text_field(ctx,ui.id(ctx,"node_name"),n.name[:len(n.name)-1],&length,{height=th.control,size=th.font_heading,inline=true,font=ui.FONT_SEMIBOLD}).changed {
            for &b in n.name[length:] {b=0}
            node_renamed(u,serial.text_field(from[:]))
        }
    }
}

// A card of a section. While the search has text it waits for the first row
// that shows (shown); whole: a section whose rows are not all rows of their
// own, which the search shows only when it finds its title.
@(private)
section :: proc(p:^Pane,which:Section,title:string,icon:ui.Icon=.None,whole:=false) -> bool {
    ctx:=p.s.gui.ctx
    ui.id_push(ctx,ui.id(ctx,"section",int(which)+1))
    p.which,p.icon,p.pending,p.whole=which,icon,"",false
    if p.needle!="" {
        if editor.contains_fold(title,p.needle) {
            p.whole=true
            return card_open(p,title)
        }
        if whole {return false}
        p.pending=title
        return true
    }
    return card_open(p,title)
}

@(private)
section_end :: proc(p:^Pane) {
    band_close(p)
    if p.body {
        if p.readonly {ui.disabled_end(p.s.gui.ctx)}
        editor.card_body_end(p.s)
    }
    if p.card {editor.card_end(p.s)}
    p.card,p.body,p.pending=false,false,""
    ui.id_pop(p.s.gui.ctx)
}

@(private)
card_open :: proc(p:^Pane,title:string) -> bool {
    u:=p.u
    editor.card_begin(p.s)
    p.card,p.found=true,true
    // The search keeps open what it shows.
    open:=u.open[p.which] || p.needle!=""
    if editor.section_band(p.s,ui.id(p.s.gui.ctx,"band"),title,open,p.icon).clicked && p.needle=="" {
        u.open[p.which]=!u.open[p.which]
        open=!open
    }
    if open {
        editor.card_body_begin(p.s)
        if p.readonly {ui.disabled_begin(p.s.gui.ctx)}
        p.body=true
    }
    return open
}

// Whether the row of label shows: the search finds it, or the title of its
// card. The card that waited for it opens.
@(private)
shown :: proc(p:^Pane,label:string) -> bool {
    if p.needle=="" || p.whole {return true}
    if !editor.contains_fold(label,p.needle) {return false}
    if p.pending!="" {
        title:=p.pending
        p.pending=""
        card_open(p,title)
    }
    if p.band!="" {
        title:=p.band
        p.band=""
        band_open(p,title)
    }
    return true
}

// The band of the rows of a part of a card (editor.fold_band), with its name
// while searching.
@(private)
band_open :: proc(p:^Pane,title:string) {
    ctx:=p.s.gui.ctx
    editor.fold_band_begin(p.s)
    p.banded=true
    if p.needle!="" {ui.label(ctx,title,ctx.theme.font_small,ctx.theme.text_muted)}
}
@(private)
band_close :: proc(p:^Pane) {
    p.band=""
    if p.banded {editor.fold_band_end(p.s);p.banded=false}
}

// A part of a card, which folds what follows it as every part does
// (editor.section_fold): its rows go on a band until the next part or the end
// of the card. Searching, it is open and its band waits for a row it shows.
// False: it is closed, build nothing.
@(private)
subsection :: proc(p:^Pane,id:ui.Id,title:string,open:^bool) -> bool {
    band_close(p)
    if p.needle!="" {
        p.band=title
        return true
    }
    if editor.section_fold(p.s,id,title,open^) {open^=!open^}
    if open^ {band_open(p,title)}
    return open^
}

@(private)
focusable :: proc(kind:ui.Node_Kind) -> bool {
    #partial switch kind {
    case .Button,.Checkbox,.Slider,.Field,.Selector,.Dropdown,.Radio,.Number: return true
    }
    return false
}

@(private)
shows_text :: proc(kind:ui.Node_Kind) -> bool {
    #partial switch kind {
    case .Text,.Button,.Rich_Text,.Field,.Selector,.Dropdown,.Prompt,.Action_Bar,.Checkbox,.Radio,.Slider,.Number,.Tabs: return true
    }
    return false
}

// What a row changed becomes a step called label.
@(private)
edit :: proc(u:^Ui_Inspector,label:string,changes:bool) {
    if changes {changed(u,label)}
}

// ---------------------------------------------------------------- node

@(private)
section_node :: proc(p:^Pane,a:^host.Assets,n:^ui.Tree_Node) {
    u:=p.u
    d:=node_default(n.kind)
    // The text, and the bubble that shows it in each language of the game.
    text_row :: proc(p:^Pane,n:^ui.Tree_Node,label,about:string) {
        ctx:=p.s.gui.ctx
        if !shown(p,label) {return}
        if ui.box(ctx,{width=ui.GROW,height=ui.FIT,gap=2,align_y=.Center}) {
            if ui.box(ctx,{width=ui.GROW,height=ui.FIT,direction=.Column}) {edit(p.u,"Text",string_row(p,label,&n.text,node_default_text(n.kind),about))}
            texts_button(p,n,false)
        }
    }
    #partial switch n.kind {
    case .Text,.Button,.Rich_Text:
        about:="Its text, in the language the interfaces are written in; a name in braces, {coins}, shows the field of the game its row below binds. The bubble gives it in the other languages; the link binds it all to a field"
        bound:=false
        {
            if bindable(p,"Text",n.bind_text[:],.Shown,about) {text_row(p,n,"Text",about)} else if p.bind_open {texts_button(p,n,true);bound=true}
        }
        if !bound {text_field_rows(p,n)}
    case .Selector,.Dropdown:
        about:="The options, separated by |; the bubble gives them in the other languages. The link takes them from an array of texts or of enums of the game instead"
        if bindable(p,"Options",n.bind_items[:],.Options,about) {text_row(p,n,"Options",about)}
    case .Tabs:
        about:="What each tab shows, separated by |; the bubble gives them in the other languages. The link takes them from an array of texts or of enums of the game instead. A tab without one shows the text of its node, or its name"
        if bindable(p,"Labels",n.bind_items[:],.Options,about) {text_row(p,n,"Labels",about)}
    case .Field:
        bind_only(p,"Text",n.bind_text[:],.Shown,"What it holds: it writes there what is typed")
        text_row(p,n,"Placeholder","What it shows while its value is empty")
    }
    #partial switch n.kind {
    case .Button,.Prompt:
        edit(u,"Action",action_row(p,"Action",n.action[:]))
        if n.kind==.Button {edit(u,"Hold",value_row(p,"Hold",Seconds_Value,&n.hold,d.hold,"How long the action is held before it clicks; 0 clicks at once"))}
    case .Progress:
        bind_only(p,"Value",n.bind_value[:],.Number,"A number from 0 to 1: how full it is")
    case .Checkbox,.Slider,.Selector,.Dropdown,.Number:
        bind_only(p,"Value",n.bind_value[:],.Number,"What it shows, and where it writes what the player chooses")
    case .Radio:
        bind_only(p,"Value",n.bind_value[:],.Number,"It is selected while this value is what it writes, and choosing it writes it there")
        edit(u,"Writes",value_row(p,"Writes",Count_Value,&n.choice,d.choice,"What choosing it writes in its value"))
    case .Switcher:
        if bindable(p,"Child",n.bind_value[:],.Number,"The node it builds: 0 is the first it holds; bound to an enum or a text, the node of that name") {edit(u,"Child",value_row(p,"Child",Count_Value,&n.index,d.index,"The node it builds: 0 is the first it holds"))}
    case .Tabs:
        if bindable(p,"Tab",n.bind_value[:],.Number,"The tab it shows, and where it writes the one the player chooses: 0 is the first node it holds") {edit(u,"Tab",value_row(p,"Tab",Count_Value,&n.index,d.index,"The tab it shows first: 0 is the first node it holds"))}
    case .Popup:
        bind_only(p,"Open",n.bind_value[:],.Number,"A bool of the game: it is open while it is true; unbound, a click on its parent opens it")
    case .List:
        bind_only(p,"Items",n.bind_items[:],.Items,"An array of structs or of entities: it builds the node it holds once for each, and that node's paths start at its element")
        if bindable(p,"Elements",n.bind_value[:],.Number,"How many of the items it builds") {edit(u,"Elements",value_row(p,"Elements",Count_Value,&n.count,d.count,"How many times it builds the node it holds"))}
    case .View:
        bind_only(p,"Camera",n.bind_value[:],.Entity,"The entity whose camera it shows")
    case .Field:
        edit(u,"Field",value_row(p,"Limit",Count_Value,&n.limit,d.limit,"The bytes it takes; 0: as many as its value holds"))
        edit(u,"Field",flag_row(p,"Multiline",&n.flags,.Multiline,d.flags,"Its text keeps line breaks, which Enter types, and wraps"))
        edit(u,"Field",flag_row(p,"Password",&n.flags,.Password,d.flags,"It shows a mark for each character typed"))
    case .Tooltip:
        edit(u,"Tooltip",value_row(p,"Delay",Seconds_Value,&n.delay,d.delay,"How long the pointer or the focus stays on the node that holds it before it shows; 0: the usual wait"))
    case .Particles:
        if shown(p,"Effect") {
            values:=Particle_Pick{n.particle}
            none:=Particle_Pick{d.particle}
            if editor.held_field_row(p.s,{key=base.hash_combine(u64(0x7061727469636c65),u64(u.selected))|1,info=type_info_of(Particle_Pick),value=&values,defaults=&none,width=p.width},"particle","Effect","The .particle of the project it plays in its rectangle") {
                n.particle=values.particle
                changed(u,"Effect")
            }
        }
    }
    if n.kind==.Slider || n.kind==.Number {edit(u,"Range",value_row(p,"Range",Range_Value,&n.range,d.range,"The least and the most value, and the step it moves by; 0 does not step"))}
    if n.kind!=.Component {
        about:="Visible: it is built. Hidden: it keeps its room but draws nothing and takes no input. Collapsed: it takes no room. Bound, a bool of the game shows it while true"
        bound:=false
        {
            if bindable(p,"Visibility",n.bind_visible[:],.Number,about) {
                mode:=Visibility.Collapsed if .Collapsed in n.flags else .Hidden if .Invisible in n.flags else .Visible
                if value_row(p,"Visibility",Enum_Value(Visibility),&mode,.Visible,about) {
                    n.flags-={.Collapsed,.Invisible}
                    switch mode {
                    case .Visible:
                    case .Hidden:    n.flags+={.Invisible}
                    case .Collapsed: n.flags+={.Collapsed}
                    }
                    changed(u,"Visibility")
                }
            } else if p.bind_open {bound=true}
        }
        // Bound, what false does.
        if bound {
            mode:=Hidden_As.Hidden if .Invisible in n.flags else .Collapsed
            if value_row(p,"When false",Enum_Value(Hidden_As),&mode,.Collapsed,"What the node is while the bool of the game is false: it keeps its room, or it takes none") {
                n.flags-={.Collapsed,.Invisible}
                n.flags+={.Invisible} if mode==.Hidden else {}
                changed(u,"Visibility")
            }
        }
    }
    if focusable(n.kind) || ui.node_kind_holds(n.kind) {
        about:="It takes no input and draws as its Disabled variant; what it holds too"
        if bindable(p,"Disabled",n.bind_disabled[:],.Number,about) {edit(u,"Disabled",value_row(p,"Disabled",Flag_Value,&n.disabled,d.disabled,about))}
    }
    if n.kind!=.Component && n.kind!=.Spacer {drag_rows(p,n,d)}
    if ui.node_kind_holds(n.kind) {edit(u,"Clip",value_row(p,"Clip",Flag_Value,&n.clip,d.clip,"What it holds is cut at its edges instead of drawing past them"))}
    if advanced(p) {
        if bindable(p,"Selected",n.bind_selected[:],.Number,"It is in the Selected state, which the look of its style can wait for") {
            edit(u,"Selected",value_row(p,"Selected",Flag_Value,&n.selected,d.selected,"It starts in the Selected state, which the look of its style can wait for"))
        }
        if ui.node_kind_holds(n.kind) {edit(u,"Block",value_row(p,"Blocks pointer",Flag_Value,&n.block,d.block,"The pointer over it does not reach what is behind it, in the game or in the world"))}
    }
}

// Whether the pointer drags the node and what it carries, and whether it
// takes what is dropped on it and what of it.
@(private)
drag_rows :: proc(p:^Pane,n:^ui.Tree_Node,d:ui.Tree_Node) {
    u:=p.u
    edit(u,"Draggable",flag_row(p,"Draggable",&n.flags,.Draggable,d.flags,"The pointer drags it: the game hears where it is dropped"))
    if .Draggable in n.flags {
        edit(u,"Drag",value_row(p,"Carries",Name_Value,&n.tag,d.tag,"What it carries, by name: a drop that takes only some names takes it when this is one of them"))
        edit(u,"Drag",ghost_row(p,n))
    }
    edit(u,"Drop",flag_row(p,"Takes drops",&n.flags,.Drop,d.flags,"What is dragged can be dropped on it"))
    if .Drop in n.flags {edit(u,"Drop",value_row(p,"Takes",Name_Value,&n.accepts,d.accepts,"What it takes, by the name dragged nodes carry; empty: anything"))}
}

// The node built under the pointer while the node is dragged: a copy of it,
// or another node of its scope, by name.
@(private)
ghost_row :: proc(p:^Pane,n:^ui.Tree_Node) -> (changed:bool) {
    ctx:=p.s.gui.ctx
    names:=make([dynamic]string,context.temp_allocator)
    append(&names,"A copy of it")
    current:=serial.text_field(n.ghost[:])
    chosen:=0
    for &other in scope_nodes(p.u) {
        name:=serial.text_field(other.name[:])
        if name=="" || &other==n {continue}
        if name==current {chosen=len(names)}
        append(&names,name)
    }
    if current!="" && chosen==0 {chosen=len(names);append(&names,current)}
    if row(p,"Under pointer","What shows under the pointer while it is dragged: a copy of it, or another node of the interface, by its name") {
        if ui.dropdown(ctx,ui.id(ctx,"ghost"),names[:],&chosen,{width=-1}) {
            ui.tree_text_set(n.ghost[:],names[chosen] if chosen>0 else "")
            changed=true
        }
    }
    return
}

// A path of the data of the game, typed: what an override of an instance gives a node of its widget.
@(private)
binding_row :: proc(p:^Pane,label:string,field:^[ui.TREE_PATH_CAPACITY]u8,about:string) -> bool {
    return value_row(p,label,Path_Value,field,[ui.TREE_PATH_CAPACITY]u8{},fmt.tprintf("A path of the data of the game. %s",about))
}

@(private)
section_layout :: proc(p:^Pane,n:^ui.Tree_Node) {
    u:=p.u
    l:=&n.layout
    d:=node_default(n.kind).layout
    list:=scope_nodes(u)
    edit(u,"Layout",size_row(p,"Width",&l.width,d.width))
    if l.width.kind==.Fit || l.width.kind==.Grow {edit(u,"Layout",limits_row(p,"Width limits",&l.width,d.width))}
    edit(u,"Layout",size_row(p,"Height",&l.height,d.height))
    if l.height.kind==.Fit || l.height.kind==.Grow {edit(u,"Layout",limits_row(p,"Height limits",&l.height,d.height))}
    edit(u,"Layout",value_row(p,"Aspect",Positive_Value,&l.aspect,d.aspect,"The width over the height it keeps: the side that fits gives the other; 0: none"))
    // How it places itself in what holds it.
    if parent:=int(n.parent);parent>=0 && parent<len(list) {
        about:="Where it goes across the direction of what holds it, in its cell of a grid or in a stack: as what holds it says, or on its own"
        edit(u,"Layout",value_row(p,"Align self X",Enum_Value(ui.Self_Align),&l.self_x,d.self_x,about))
        edit(u,"Layout",value_row(p,"Align self Y",Enum_Value(ui.Self_Align),&l.self_y,d.self_y,about))
        if list[parent].layout.direction==.Grid {edit(u,"Layout",value_row(p,"Span",Span_Value,&l.span,d.span,"The columns of the grid it takes; 0 is 1"))}
    }
    if ui.node_kind_holds(n.kind) || n.kind==.Action_Bar {
        edit(u,"Layout",value_row(p,"Direction",Enum_Value(ui.Direction),&l.direction,d.direction,"How it lays out what it holds: in a row, in a column, in a grid of Columns cells, in rows that wrap where the next does not fit, or one over another"))
        if l.direction==.Grid {grid_rows(p,n)}
        edit(u,"Layout",value_row(p,"Align X",Align_X_Value,&l.align_x,d.align_x,"Where what it holds goes across it when it does not fill it; to fill it, a node grows"))
        edit(u,"Layout",value_row(p,"Align Y",Align_Y_Value,&l.align_y,d.align_y,"Where what it holds goes down it when it does not fill it; to fill it, a node grows"))
        edit(u,"Layout",value_row(p,"Gap",Positive_Value,&l.gap,d.gap,"The room between the nodes it holds"))
        edit(u,"Layout",value_row(p,"Padding",Sides_Value,&l.padding,d.padding,"The room between its edges and what it holds"))
    }
}

// The columns of a Grid: how many, and the width of each when they are not all the same.
@(private)
grid_rows :: proc(p:^Pane,n:^ui.Tree_Node) {
    u:=p.u
    r:=&u.records
    l:=&n.layout
    d:=node_default(n.kind).layout
    if value_row(p,"Columns",Count_Value,&l.columns,d.columns,"The cells of each row of the grid") {
        if l.tracks!=0 {
            if at:=records_grid_tracks(r,n);at>=0 {records_grid_tracks_count(r,at,int(l.columns))}
        }
        changed(u,"Layout")
    }
    at:=int(l.tracks)-1
    if at<0 || at>=len(r.grid_tracks) {
        if shown(p,"Column widths") && add_button(p,"tracks_add","Column widths") {
            if records_grid_tracks(r,n)>=0 {changed(u,"Columns")}
        }
        return
    }
    tracks:=r.grid_tracks[at]
    for i in 0..<int(tracks.count) {
        ui.id_push(p.s.gui.ctx,ui.id(p.s.gui.ctx,"track",i+1))
        if size_row(p,fmt.tprintf("Column %d",i+1),&tracks.columns[i],ui.GROW,"The width of the column: Fixed points, Percent of the grid, Fit to its widest cell, or Grow by its weight with the others that grow") {
            if own:=records_grid_tracks(r,n);own>=0 {
                r.grid_tracks[own].columns[i]=tracks.columns[i]
                changed(u,"Columns")
            }
        }
        ui.id_pop(p.s.gui.ctx)
    }
    if shown(p,"Same widths") && add_button(p,"tracks_drop","Same widths") {
        records_grid_tracks_drop(r,n)
        changed(u,"Columns")
    }
}

@(private)
section_floating :: proc(p:^Pane,n:^ui.Tree_Node) {
    u:=p.u
    d:=node_default(n.kind).float
    edit(u,"Float",value_row(p,"Float",Enum_Value(ui.Float_To),&n.float.to,d.to,"Out of the layout of its parent, over it: hung from the screen, its safe area, its parent or the root of a panel in the world. On the stage, the screen and its safe area are the stage"))
    if n.float.to==.None {return}
    edit(u,"Float",value_row(p,"Anchor",Enum_Value(ui.Anchor),&n.float.anchor,d.anchor,"The point of what it hangs from"))
    edit(u,"Float",value_row(p,"Pivot",Enum_Value(ui.Anchor),&n.float.pivot,d.pivot,"Its own point that goes on the anchor"))
    edit(u,"Float",value_row(p,"Offset",Pair_Value,&n.float.offset,d.offset,"How far it moves from the anchor; on the stage, dragging the node moves it"))
    if value_row(p,"Layer",Order_Value,&n.float.layer,d.layer,"What floats in a higher layer covers what floats in a lower one") {
        n.float.layer=clamp(n.float.layer,-100,100)
        changed(u,"Float")
    }
}

@(private)
section_focus :: proc(p:^Pane,n:^ui.Tree_Node) {
    u:=p.u
    d:=node_default(n.kind).flags
    if focusable(n.kind) {edit(u,"Navigation",flag_row(p,"Focused first",&n.flags,.Focus_First,d,"It has the focus when the interface shows"))}
    edit(u,"Navigation",flag_row(p,"Skipped",&n.flags,.Skip,d,"Navigation goes past it, and past what it holds"))
    if ui.node_kind_holds(n.kind) {
        edit(u,"Navigation",flag_row(p,"Wraps sideways",&n.flags,.Wrap_X,d,"Past its last node to the right, the focus goes to its first"))
        edit(u,"Navigation",flag_row(p,"Wraps up and down",&n.flags,.Wrap_Y,d,"Past its last node down, the focus goes to its first"))
    }
    if focusable(n.kind) && advanced(p) {
        nd:=node_default(n.kind)
        sides:=[4]string{"Up","Right","Down","Left"}
        for side,i in sides {edit(u,"Navigation",value_row(p,fmt.tprintf("Focus %s",side),Name_Value,&n.nav[i],nd.nav[i],"The node, by its name, the focus goes to that way; empty: the closest one"))}
        edit(u,"Navigation",value_row(p,"Tab order",Order_Value,&n.order,nd.order,"Where Tab takes the focus: lower first; 0 follows the tree"))
    }
}

// ---------------------------------------------------------------- style

@(private)
style_edit_begin :: proc(p:^Pane,n:^ui.Tree_Node) {
    r:=&p.u.records
    row:=int(n.style)
    p.style={row=row}
    if row>=len(r.styles) {return}
    base:=records_style_base(r,row)
    p.style.defaults=r.styles[base if base>=0 else row]
    named:=records_style_named(r,row)
    if base<0 && (named || row==0 || records_style_users(r,row)>1) {
        p.style.draft,p.style.own=true,!named
        p.style.values=r.styles[row]
        p.style.variants=make([dynamic]ui.Tree_Style_Variant,context.temp_allocator)
        append(&p.style.variants,..records_style_variants(r,row))
    }
}

// The copy a row changed becomes the override of the node.
@(private)
style_edit_end :: proc(p:^Pane,n:^ui.Tree_Node) {
    if p.style.label=="" || p.readonly {return}
    if p.style.draft {
        row:=records_style_add(&p.u.records,p.style.values,p.style.variants[:],{} if p.style.own else {base=u16(p.style.row+1)})
        if row<0 {return}
        n.style=u16(row)
    }
    changed(p.u,p.style.label)
}

@(private)
style_values :: proc(p:^Pane) -> ^ui.Node_Style {
    return &p.style.values if p.style.draft else &p.u.records.styles[p.style.row]
}

@(private)
style_variants :: proc(p:^Pane) -> ^[dynamic]ui.Tree_Style_Variant {
    return &p.style.variants if p.style.draft else &p.u.records.variants
}

@(private)
style_changed :: proc(p:^Pane,label:string,changes:bool) {
    if changes {p.style.label=label}
}

// The style of the node, among the named ones of its family, or None; and,
// while the node changes a style it shares, what to do with the changes.
@(private)
style_head :: proc(p:^Pane,n:^ui.Tree_Node) {
    s:=p.s
    u:=p.u
    ctx:=s.gui.ctx
    th:=&ctx.theme
    r:=&u.records
    base:=records_style_base(r,int(n.style))
    current:=base if base>=0 else int(n.style)
    named:=records_style_named(r,current)
    family:=style_family(n.kind)
    names:=make([dynamic]string,context.temp_allocator)
    rows:=make([dynamic]int,context.temp_allocator)
    append(&names,"None");append(&rows,-1)
    selected:=0
    for i in 0..<len(r.styles) {
        if !records_style_named(r,i) || records_style_base(r,i)>=0 || r.style_infos[i].family!=family {continue}
        if i==current {selected=len(names)}
        append(&names,records_style_name(r,i));append(&rows,i)
    }
    // A style of another family the node already has stays in its list.
    if named && selected==0 {
        selected=len(names)
        append(&names,records_style_name(r,current));append(&rows,current)
    }
    if selected>0 && base>=0 {names[selected]=fmt.tprintf("%s *",names[selected])}
    icon :: proc(ctx:^ui.Context,name:string,icon:ui.Icon,tip:string,disabled:=false) -> bool {
        return ui.button(ctx,ui.id(ctx,name),{icon=icon,icon_size=14,icon_color=ctx.theme.text_muted,tip=tip,style=.Ghost,width=ctx.theme.row,height=ctx.theme.row,disabled=disabled}).clicked
    }
    p.flush=true
    if row(p,"Style","The look it shares with the nodes of that style; None: a look of its own. A * after its name: this node changes the style, which only it shows until Apply to style writes the changes there") {
        if u.style_rename && u.style_renamed==current && named {
            field:=ui.id(ctx,"style_name")
            if ctx.edit.id!=field {ui.edit_request(ctx,field)}
            result:=ui.text_field(ctx,field,u.style_name[:len(u.style_name)-1],&u.style_name_length,{width=ui.GROW})
            if result.committed && u.style_name_length>0 {
                ui.tree_text_set(r.style_infos[current].name[:],string(u.style_name[:u.style_name_length]))
                changed(u,"Rename style")
            }
            if result.committed || result.cancelled {u.style_rename=false}
        } else if ui.dropdown(ctx,ui.id(ctx,"style"),names[:],&selected,{width=-1}) {
            old:=int(n.style)
            to:=rows[selected]
            // None keeps the look the node has, as its own.
            if to<0 {to=records_style_add(r,r.styles[old],records_style_variants(r,old),{})}
            if to>=0 {
                n.style=u16(to)
                if !records_style_named(r,old) {n.style=u16(records_style_remove(r,old,to))}
                changed(u,"Style")
            }
        }
        if icon(ctx,"style_new",.Plus,"New style with this look") {
            at:=int(n.style)
            if base>=0 {
                r.style_infos[at].base=0
            } else if named || at==0 || records_style_users(r,at)>1 {
                at=records_style_add(r,r.styles[at],records_style_variants(r,at),{})
            }
            if at>=0 {
                ui.tree_text_set(r.style_infos[at].name[:],records_style_name_unique(r))
                r.style_infos[at].family=family
                n.style=u16(at)
                style_rename_begin(u,at)
                changed(u,"New style")
            }
        }
        if icon(ctx,"style_rename",.Edit,"Rename the style",!named) {style_rename_begin(u,current)}
    }
    if current>0 && current<len(r.style_infos) && !p.readonly {
        taken:=n.kind in r.style_infos[current].defaults
        if value_row(p,"Default",Flag_Value,&taken,false,fmt.tprintf("New %v nodes of this file take this style",n.kind)) {
            if taken {records_kind_style_set(r,current,{n.kind})} else {r.style_infos[current].defaults-={n.kind}}
            changed(u,"Default style")
        }
    }
    // The changes of this node to the style it shares: into the style, or away.
    if base>=0 && !p.readonly {
        p.flush=true
        if row(p,"Changes",fmt.tprintf("What this node changes of %s, marked *: Apply to style writes it into the style, for every node that has it; Revert leaves the style as it is and the node with it",records_style_name(r,base))) {
            if ui.button(ctx,ui.id(ctx,"style_apply"),{label="Apply to style",style=.Field,width=-1,height=th.row,size=th.font_small}).clicked {
                n.style=u16(records_style_save(r,int(n.style)))
                changed(u,"Apply to style")
            }
            if ui.button(ctx,ui.id(ctx,"style_revert"),{label="Revert",icon=.Revert,icon_size=12,icon_color=th.text_muted,style=.Field,width=-1,height=th.row,size=th.font_small}).clicked {
                old:=int(n.style)
                n.style=u16(base)
                n.style=u16(records_style_remove(r,old,base))
                changed(u,"Revert style")
            }
        }
    }
    // What the rows after it edit follows the style the node has now.
    if u.pending && !p.readonly {style_edit_begin(p,n)}
}

@(private)
style_rename_begin :: proc(u:^Ui_Inspector,row:int) {
    u.style_rename,u.style_renamed=true,row
    u.style_name_length=copy(u.style_name[:len(u.style_name)-1],records_style_name(&u.records,row))
}

// The style of the node: its look, box and text, in the variant it shows,
// and below it what each state changes, folded, and the rules of several
// states together.
@(private)
section_style :: proc(p:^Pane,a:^host.Assets,n:^ui.Tree_Node) {
    s:=p.s
    u:=p.u
    ctx:=s.gui.ctx
    th:=&ctx.theme
    r:=&u.records
    style_head(p,n)
    if p.style.row>=len(r.styles) {return}
    if users:=records_style_users(r,int(n.style));users>1 && p.needle=="" && records_style_named(r,int(n.style)) {ui.label(ctx,fmt.tprintf("Shared by %d nodes",users),th.font_small,th.text_muted)}
    // What lays the text out is the style's in every variant and state: first.
    fixed_rows(p,n)
    look_head(p,n)
    look_begin(p,n,{})
    style_rows(p,a,n)
    look_end(p)
    // Each state is a row that opens what it changes, indented on a band.
    names:=NODE_STATE_NAMES
    for state in Node_State {
        if state==.Normal {continue}
        ui.id_push(ctx,ui.id(ctx,"state",int(state)))
        open:=u.state_open[state] || p.needle!=""
        if p.needle=="" && editor.section_fold(s,ui.id(ctx,"fold"),names[state],open) {
            u.state_open[state]=!open
            open=!open
            u.ux.combo_shown={}
            if open {u.state_shown=state} else if u.state_shown==state {
                u.state_shown=.Normal
                for other in Node_State {if other!=.Normal && u.state_open[other] {u.state_shown=other}}
            }
        }
        if open {
            // Searching, the band waits for the first row it shows.
            if p.needle=="" {band_open(p,names[state])} else {p.band=names[state]}
            look_begin(p,n,state_rule_states(state))
            style_rows(p,a,n)
            look_end(p)
            band_close(p)
        }
        ui.id_pop(ctx)
    }
    combo_rows(p,a,n)
    // What only a box has: none for what draws only text.
    #partial switch n.kind {
    case .Text,.Rich_Text,.Prompt,.Action_Bar:
    case: if advanced(p) {style_advanced(p,a,n)}
    }
}

// What the style has the same in every variant and state: how the text lays
// out, which way a bar fills and how long its colors take to change.
@(private)
fixed_rows :: proc(p:^Pane,n:^ui.Tree_Node) {
    st:=style_values(p)
    d:=p.style.defaults
    if shows_text(n.kind) {
        t:=&st.text
        style_changed(p,"Text",value_row(p,"Align X",Align_X_Value,&t.align_x,d.text.align_x,"Where its lines go across the node"))
        style_changed(p,"Text",value_row(p,"Align Y",Align_Y_Value,&t.align_y,d.text.align_y,"Where its lines go down the node"))
        style_changed(p,"Text",value_row(p,"Wrap",Enum_Value(ui.Text_Wrap),&t.wrap,d.text.wrap,"Words that do not fit go to the next line"))
        style_changed(p,"Text",value_row(p,"Ellipsis",Flag_Value,&t.ellipsis,d.text.ellipsis,"Text that does not fit ends in ..."))
        style_changed(p,"Text",value_row(p,"Line height",Positive_Value,&t.line_height,d.text.line_height,"In sizes of the text; 0: the one of the font"))
    }
    if n.kind==.Progress {style_changed(p,"Style",value_row(p,"Fills",Enum_Value(ui.Progress_Fill),&st.fill_mode,d.fill_mode,"Which way the bar grows: from a side, from the center or around"))}
    style_changed(p,"Style",value_row(p,"Transition",Seconds_Value,&st.transition,d.transition,"How long its colors take to go from the look of one state to that of the next; 0: at once"))
}

// The rows of the look the pane edits: the box, for what draws one, the
// parts of a control, and the text, for what shows one. A rule of a variant
// or a state has only what it can change, and takes the colors of the theme.
@(private)
style_rows :: proc(p:^Pane,a:^host.Assets,n:^ui.Tree_Node) {
    v,d:=look_values(p)
    rule:=p.look.rule
    #partial switch n.kind {
    case .Text,.Rich_Text,.Prompt,.Action_Bar:
    case:
        fill_about:="Its background; the bar of a Progress, the tint of an Image"
        #partial switch n.kind {
        case .Box,.Image,.Progress:
            if !rule {
                if bindable(p,"Fill",n.bind_tint[:],.Color,"Its background; the bar of a Progress, the tint of an Image. Bound, a color of the game takes its place on this node") {look_color(p,"Fill",.Fill,&v.fill,d.fill,fill_about)}
            } else {look_color(p,"Fill",.Fill,&v.fill,d.fill,fill_about)}
        case:
            look_color(p,"Fill",.Fill,&v.fill,d.fill,fill_about)
        }
        look_color(p,"Gradient to",.Fill2,&v.fill2,d.fill2,"The fill goes down into this color; transparent: no gradient")
        look_color(p,"Stroke",.Stroke,&v.stroke,d.stroke,"The line around its edge")
        look_changed(p,"Style",.Stroke_Width,value_row(p,"Stroke width",Positive_Value,&v.stroke_width,d.stroke_width))
        look_changed(p,"Style",.Radius,value_row(p,"Corners",Corners_Value,&v.radius,d.radius,"The radius of each corner"))
        #partial switch n.kind {
        case .Progress,.Slider:
            look_color(p,"Track",.Track,&v.track,d.track,"What the bar fills")
        }
        if n.kind==.Slider {look_color(p,"Knob",.Knob,&v.knob,d.knob,"What the pointer drags along the track")}
        #partial switch n.kind {
        case .Checkbox,.Radio,.Selector,.Dropdown,.Number,.Button:
            look_color(p,"Mark",.Mark,&v.mark,d.mark,"What it marks with: the filled part of a slider, the tick of a checkbox, the dot of a radio, the arrows of a selector or a number, the accent of a dropdown, the bar of a button held")
        }
        look_changed(p,"Shadow",.Shadow,value_row(p,"Shadow",Flag_Value,&v.shadow,d.shadow,"A blurred copy of its shape under it"))
        if v.shadow {
            look_changed(p,"Shadow",.Shadow,color_row(p,"Shadow color",&v.shadow_color,d.shadow_color))
            look_changed(p,"Shadow",.Shadow,value_row(p,"Shadow blur",Positive_Value,&v.shadow_blur,d.shadow_blur))
            look_changed(p,"Shadow",.Shadow,value_row(p,"Shadow offset",Pair_Value,&v.shadow_offset,d.shadow_offset))
        }
    }
    if shows_text(n.kind) {text_rows(p)}
}

@(private)
text_rows :: proc(p:^Pane) {
    ctx:=p.s.gui.ctx
    r:=&p.u.records
    v,dv:=look_values(p)
    t:=&v.text
    d:=dv.text
    fonts:=make([dynamic]string,context.temp_allocator)
    values:=make([dynamic]u8,context.temp_allocator)
    append(&fonts,"Regular","Medium","Semibold")
    append(&values,ui.FONT_REGULAR,ui.FONT_MEDIUM,ui.FONT_SEMIBOLD)
    for i in 0..<len(r.fonts) {append(&fonts,fmt.tprintf("Font %d",i));append(&values,u8(ui.FONT_TREE+i))}
    chosen:=0
    for value,i in values {if value==t.font {chosen=i}}
    if row(p,"Font","A font of the editor, or one of the fonts of the file") {
        if ui.dropdown(ctx,ui.id(ctx,"font"),fonts[:],&chosen,{width=-1}) {t.font=values[chosen];look_changed(p,"Text",.Text_Font,true)}
    }
    look_changed(p,"Text",.Text_Size,value_row(p,"Size",Positive_Value,&t.size,d.size))
    look_color(p,"Color",.Text_Color,&t.color,d.color,group="Text")
    look_changed(p,"Text",.Text_Outline,value_row(p,"Outline",Positive_Value,&t.outline,d.outline,"The width of a line around each letter"))
    if t.outline>0 {look_changed(p,"Text",.Text_Outline,color_row(p,"Outline color",&t.outline_color,d.outline_color))}
    look_changed(p,"Text",.Text_Shadow,value_row(p,"Text shadow",Pair_Value,&t.shadow,d.shadow,"How far a copy of the text is drawn under it; 0, 0: none"))
    if t.shadow!={} {look_changed(p,"Text",.Text_Shadow,color_row(p,"Text shadow color",&t.shadow_color,d.shadow_color))}
}

// What few interfaces change of the look: the program that colors the fill
// and a layer of its own.
@(private)
style_advanced :: proc(p:^Pane,a:^host.Assets,n:^ui.Tree_Node) {
    s,u:=p.s,p.u
    ctx:=s.gui.ctx
    st:=style_values(p)
    d_style:=p.style.defaults
    programs:=make([dynamic]string,context.temp_allocator)
    append(&programs,"None")
    chosen:=0
    current:=serial.text_field(st.program[:])
    if a.renderer!=nil {
        for &program in gpu.renderer_programs(a.renderer) {
            if program.domain!=.Ui {continue}
            if program.name==current {chosen=len(programs)}
            append(&programs,program.name)
        }
    }
    if row(p,"Program","A ui program of the shaders of the project that colors the fill instead, as the shader says") {
        if ui.dropdown(ctx,ui.id(ctx,"program"),programs[:],&chosen,{width=-1}) {
            name:=programs[chosen] if chosen>0 else ""
            ui.tree_text_set(st.program[:],name)
            st.program_values={}
            if program:=gpu.program_find(a.renderer,name,.Ui) if a.renderer!=nil && name!="" else nil;program!=nil {
                defaults:=gpu.program_defaults(program)
                st.program_values=transmute([4]f32)defaults[0]
            }
            style_changed(p,"Program",true)
        }
    }
    if current!="" {style_changed(p,"Program",value_row(p,"Values",Program_Value,&st.program_values,d_style.program_values,"The first parameters of the program"))}
    if ui.node_kind_holds(n.kind) {layer_rows(p,u,&n.layer,node_default(n.kind).layer)}
}

// A layer of its own of what holds nodes.
@(private)
layer_rows :: proc(p:^Pane,u:^Ui_Inspector,layer:^ui.Layer_Style,d:ui.Layer_Style) {
    edit(u,"Layer",value_row(p,"Own layer",Flag_Value,&layer.enabled,d.enabled,"It and what it holds are drawn apart and then blended: for an opacity of the whole, rounded corners that cut or a blur of what is behind"))
    if layer.enabled {
        edit(u,"Layer",value_row(p,"Opacity",Unit_Value,&layer.opacity,1,"Of the whole layer"))
        edit(u,"Layer",value_row(p,"Corner",Positive_Value,&layer.radius,d.radius,"The radius of the corners that cut the layer"))
        edit(u,"Layer",value_row(p,"Backdrop blur",Positive_Value,&layer.backdrop_blur,d.backdrop_blur,"How much what is behind the layer is blurred"))
    }
}

// A button that adds a row of a list, at its end.
@(private)
add_button :: proc(p:^Pane,name,label:string,disabled:=false) -> bool {
    ctx:=p.s.gui.ctx
    th:=&ctx.theme
    return ui.button(ctx,ui.id(ctx,name),{label=label,icon=.Plus,icon_size=11,icon_color=th.text_label,style=.Ghost,height=th.row,size=th.font_small,disabled=disabled}).clicked
}

// ---------------------------------------------------------------- styles of the file

// The styles with a name of the file, with how many nodes have each; one no
// node has can go.
@(private)
section_styles :: proc(p:^Pane,n:^ui.Tree_Node) {
    u:=p.u
    ctx:=p.s.gui.ctx
    th:=&ctx.theme
    r:=&u.records
    removed:=-1
    for i in 0..<len(r.styles) {
        if !records_style_named(r,i) || records_style_base(r,i)>=0 {continue}
        name:=records_style_name(r,i)
        if !shown(p,name) {continue}
        users:=records_style_users(r,i)
        // An override of it is a node that has it too.
        for j in 0..<len(r.styles) {users+=int(records_style_base(r,j)==i)}
        ui.id_push(ctx,ui.id(ctx,"style",i+1))
        p.flush=true
        if row(p,name) {
            ui.label(ctx,fmt.tprintf("%d nodes",users) if users!=1 else "1 node",th.font_small,th.text_muted)
            ui.spacer(ctx)
            if ui.button(ctx,ui.id(ctx,"remove"),{icon=ui.icon_user(u8(editor.User_Icon.Trash)),icon_size=13,icon_color=th.text_muted,tip="Delete",style=.Ghost,width=th.row,height=th.row,disabled=users>0 || i==0 || p.readonly}).clicked {removed=i}
        }
        ui.id_pop(ctx)
    }
    if removed>=0 {
        keep:=int(n.style) if n!=nil else 0
        kept:=records_style_remove(r,removed,keep)
        if n!=nil {n.style=u16(kept)}
        changed(u,"Delete style")
    }
}

// ---------------------------------------------------------------- image

@(private)
section_image :: proc(p:^Pane,n:^ui.Tree_Node) {
    s:=p.s
    u:=p.u
    ctx:=s.gui.ctx
    th:=&ctx.theme
    r:=&u.records
    about:="The texture it shows; bound, an asset id of the game"
    if n.image==0 || int(n.image)>len(r.images) {
        if n.kind==.Image {bind_only(p,"Texture",n.bind_image[:],.Asset,about)}
        if add_button(p,"image_add","Add image") {
            if records_image(r,n)>=0 {changed(u,"Image")}
        }
        return
    }
    image:=&r.images[n.image-1]
    texture :: proc(s:^editor.Session,u:^Ui_Inspector,n:^ui.Tree_Node,image:^ui.Tree_Image,about:string) {
        values:=Texture_Pick{image.texture}
        none:Texture_Pick
        if editor.held_field_row(s,{key=base.hash_combine(u64(0x696d616765),u64(n.image))|1,info=type_info_of(Texture_Pick),value=&values,defaults=&none},"texture","Texture",about) {
            image.texture=values.texture
            changed(u,"Image")
        }
    }
    if n.kind==.Image {
        if bindable(p,"Texture",n.bind_image[:],.Asset,about) {texture(s,u,n,image,about)}
    } else {texture(s,u,n,image,about)}
    edit(u,"Image",value_row(p,"Fit",Enum_Value(ui.Image_Fit),&image.fit,ui.Image_Fit.Stretch,"How it takes the rectangle of the node: filling it, as large as fits keeping its proportions, filling it keeping them and cut, or at its own size in the middle"))
    part:=[4]f32{image.uv.x,image.uv.y,image.uv.w,image.uv.h}
    if value_row(p,"Part",Part_Value,&part,[4]f32{},"The part of the texture it shows, from 0 to 1; all 0: the whole") {
        image.uv={part[0],part[1],part[2],part[3]}
        changed(u,"Image")
    }
    edit(u,"Image",value_row(p,"Frames",Frames_Value,&image.frames,[2]u16{},"A sheet of sprites: its columns and rows, whose frames an animation of Frame plays; 0: one"))
    edit(u,"Image",value_row(p,"Borders",Sides_Value,&image.border,[4]f32{},"Nine slice: how wide its edges are drawn, which do not stretch with it"))
    edit(u,"Image",value_row(p,"Border UV",Border_Uv_Value,&image.border_uv,[4]f32{},"Nine slice: how much of the texture each edge is, from 0 to 0.5"))
    edit(u,"Image",value_row(p,"Name",Name_Value,&image.name,[ui.TREE_NAME_CAPACITY]u8{},"What a rich text shows it by: <img=name>"))
    if ui.button(ctx,ui.id(ctx,"image_remove"),{label="No image",icon=.Cross,icon_size=11,icon_color=th.text_label,style=.Ghost,height=th.row,size=th.font_small}).clicked {
        n.image=0
        changed(u,"Image")
    }
}

// ---------------------------------------------------------------- fonts

@(private)
section_fonts :: proc(p:^Pane,a:^host.Assets) {
    s:=p.s
    u:=p.u
    ctx:=s.gui.ctx
    th:=&ctx.theme
    r:=&u.records
    defer section_end(p)
    if !section(p,.Fonts,"Fonts of the file",.Text,whole=true) {return}
    removed:=-1
    for &font,i in r.fonts {
        ui.id_push(ctx,ui.id(ctx,"font",i+1))
        values:=Font_Pick{font.font}
        none:Font_Pick
        if ui.box(ctx,{width=ui.GROW,height=ui.FIT,gap=4,align_y=.Start}) {
            if ui.box(ctx,{width=ui.GROW,height=ui.FIT,direction=.Column}) {
                if editor.held_field_row(s,{key=base.hash_combine(u64(0x666f6e74),u64(i))|1,info=type_info_of(Font_Pick),value=&values,defaults=&none},"font",fmt.tprintf("Font %d",i)) && values.font!={} {
                    font.font=values.font
                    changed(u,"Font")
                }
            }
            if ui.button(ctx,ui.id(ctx,"remove"),{icon=.Cross,tip="Remove font",style=.Ghost,width=th.row,height=th.row}).clicked {removed=i}
        }
        ui.id_pop(ctx)
    }
    if removed>=0 {
        ordered_remove(&r.fonts,removed)
        // Styles that took a font after it now take the one before.
        fix :: proc(font:^u8,removed:int) {
            if int(font^)<ui.FONT_TREE {return}
            row:=int(font^)-ui.FONT_TREE
            if row==removed {font^=ui.FONT_REGULAR} else if row>removed {font^-=1}
        }
        for &st in r.styles {fix(&st.text.font,removed)}
        for &v in r.variants {fix(&v.patch.values.text.font,removed)}
        changed(u,"Remove font")
    }
    // A font row needs its file: it is added once one is chosen.
    values:Font_Pick
    none:Font_Pick
    if editor.held_field_row(s,{key=u64(0x666f6e745f616464),info=type_info_of(Font_Pick),value=&values,defaults=&none},"font","Add a font","A .font of the project the styles of the file can take") && values.font!={} {
        append(&r.fonts,ui.Tree_Font{font=values.font})
        changed(u,"Add font")
    }
}

// ---------------------------------------------------------------- rows

// A row of Details for one value: H holds it in its field value, whose type
// and tag choose the row. default: what its arrow gives back; about: what
// its name says under the pointer.
@(private)
value_row :: proc(p:^Pane,label:string,$H:typeid,value:^$V,default:V,about:="") -> (changed:bool) {
    if !shown(p,label) {return}
    ctx:=p.s.gui.ctx
    id:=ui.id(ctx,label)
    ui.id_push(ctx,id)
    defer ui.id_pop(ctx)
    held:=H{value=value^}
    defaults:=H{value=default}
    if editor.held_field_row(p.s,{key=u64(id)|1,info=type_info_of(H),value=&held,defaults=&defaults,width=p.width},"value",label,about) {
        value^=held.value
        changed=true
    }
    return
}

// A text of the records, as a row of Details.
@(private)
string_row :: proc(p:^Pane,label:string,s:^ui.Tree_String,default:string,about:="") -> (changed:bool) {
    r:=&p.u.records
    value,initial:[TEXT_EDIT]u8
    ui.tree_text_set(value[:],records_text(r,s^))
    ui.tree_text_set(initial[:],default)
    if !value_row(p,label,Text_Value,&value,initial,about) {return}
    records_text_set(r,s,serial.text_field(value[:]))
    return true
}

// A color of a record, which keeps it as display bytes: Details shows it
// linear, with its alpha.
@(private)
color_row :: proc(p:^Pane,label:string,c:^ui.Color,default:ui.Color,about:="") -> (changed:bool) {
    linear :: proc(c:ui.Color) -> [4]f32 {
        rgb:=ui.linear_color({f32(c.r)/255,f32(c.g)/255,f32(c.b)/255})
        return {rgb.x,rgb.y,rgb.z,f32(c.a)/255}
    }
    value:=linear(c^)
    if !value_row(p,label,Color_Value,&value,linear(default),about) {return}
    c^=ui.rgb_color(ui.display_color(value.xyz),u8(clamp(value.w,0,1)*255+0.5))
    return true
}

@(private)
flag_row :: proc(p:^Pane,label:string,flags:^ui.Node_Flags,flag:ui.Node_Flag,defaults:ui.Node_Flags,about:="") -> (changed:bool) {
    on:=flag in flags
    if value_row(p,label,Flag_Value,&on,flag in defaults,about) {
        if on {flags^+={flag}} else {flags^-={flag}}
        changed=true
    }
    return
}

// A row of its own controls, in the column of the rows of Details.
@(private,deferred_in_out=row_end)
row :: proc(p:^Pane,label:string,about:="") -> bool {
    // A row the search hides leaves the next one its arrow's room.
    if !shown(p,label) {p.flush=false;return false}
    ctx:=p.s.gui.ctx
    id:=ui.id(ctx,"row",int(ui.id(ctx,label)&0x7fffffff))
    ui.box_begin(ctx,{id=id,width=ui.GROW,height=ui.fixed(ctx.theme.row),gap=4,align_y=.Center,track=about!=""})
    ui.column_label(ctx,label)
    editor.row_description(p.s,id,about)
    return true
}
@(private)
row_end :: proc(p:^Pane,label:string,about:string,open:bool) {
    if !open {return}
    ctx:=p.s.gui.ctx
    if !p.flush {ui.spacer(ctx,editor.REVERT_SIDE,1)}
    p.flush=false
    ui.box_end(ctx,{})
}

// The arrow at the end of a row of its own that gives its value back, or its room.
@(private)
revert_arrow :: proc(ctx:^ui.Context,name:string,changed:bool) -> bool {
    if !changed {
        ui.spacer(ctx,editor.REVERT_SIDE,1)
        return false
    }
    return ui.button(ctx,ui.id(ctx,name),{icon=.Revert,icon_size=12,icon_color=ctx.theme.text_muted,style=.Ghost,width=editor.REVERT_SIDE,height=editor.REVERT_SIDE}).clicked
}

// An input action of the game, by its name (an Action constant of any of
// its packages, as input.mirai binds them): none, or one of the list. A name
// the game no longer has stays, marked, until another is chosen.
@(private)
action_row :: proc(p:^Pane,label:string,field:[]u8) -> (changed:bool) {
    ctx:=p.s.gui.ctx
    info:=p.s.app.info
    names:=make([dynamic]string,context.temp_allocator)
    append(&names,"None")
    current:=serial.text_field(field)
    selected:=0
    if info!=nil {
        for entry in core.names_of(info,inp.Action) {
            if entry.value<0 || entry.value>=inp.ACTION_CAPACITY {continue}
            if entry.name==current {selected=len(names)}
            append(&names,entry.name)
        }
    }
    missing:=current!="" && selected==0
    if missing {
        selected=len(names)
        append(&names,fmt.tprintf("%s (missing)",current))
    }
    if row(p,label,"An input action of the game, as input.mirai binds it; one marked missing the game does not declare, and does nothing") {
        if ui.dropdown(ctx,ui.id(ctx,label),names[:],&selected,{width=-1}) && !(missing && selected==len(names)-1) {
            for &b in field {b=0}
            if selected>0 {copy(field[:len(field)-1],names[selected])}
            changed=true
        }
    }
    return
}

// A size of the layout: how it is taken and its value, the weight of what
// grows; default is what its arrow gives back.
@(private)
size_row :: proc(p:^Pane,label:string,size:^ui.Size,default:ui.Size,about:="Fit: as large as what it holds; Grow: shares what its parent has left with the others that grow, by its weight; Fixed: points; Percent: of its parent, 0 to 1") -> (changed:bool) {
    ctx:=p.s.gui.ctx
    p.flush=true
    if row(p,label,about) {
        ui.id_push(ctx,ui.id(ctx,label))
        defer ui.id_pop(ctx)
        kind:=int(size.kind)
        if ui.dropdown(ctx,ui.id(ctx,"kind"),{"Fit","Grow","Fixed","Percent"},&kind,{width=84}) {
            size.kind=ui.Size_Kind(kind)
            if size.kind==.Percent && size.value>1 {size.value=1}
            changed=true
        }
        v:=f64(size.value)
        #partial switch size.kind {
        case .Fixed:   if ui.number_field(ctx,ui.id(ctx,"value"),&v,{min=0,has_min=true,speed=0.5,decimals=1}).changed {size.value=f32(v);changed=true}
        case .Percent: if ui.number_field(ctx,ui.id(ctx,"value"),&v,{min=0,max=1,has_min=true,has_max=true,speed=0.005,decimals=3}).changed {size.value=f32(v);changed=true}
        case .Grow:    if ui.number_field(ctx,ui.id(ctx,"value"),&v,{min=0,has_min=true,speed=0.05,decimals=2,unit="x"}).changed {size.value=f32(v);changed=true}
        case:          ui.spacer(ctx)
        }
        if revert_arrow(ctx,"revert",size^!=default) {size^=default;changed=true}
    }
    return
}

// The least and the most a size that fits or grows takes; 0: no limit.
@(private)
limits_row :: proc(p:^Pane,label:string,size:^ui.Size,default:ui.Size) -> (changed:bool) {
    limits:=[2]f32{size.min,size.max}
    if value_row(p,label,Limits_Value,&limits,[2]f32{default.min,default.max},"The least and the most it takes; 0: no limit") {
        size.min,size.max=limits[0],limits[1]
        changed=true
    }
    return
}

// One of names, for a value that is no enum of its own.
@(private)
list_row :: proc(p:^Pane,label:string,value:^$E,names:[]string) -> (changed:bool) {
    ctx:=p.s.gui.ctx
    if row(p,label) {
        selected:=int(value^)
        if ui.dropdown(ctx,ui.id(ctx,label),names,&selected,{width=-1}) {value^=E(selected);changed=true}
    }
    return
}
