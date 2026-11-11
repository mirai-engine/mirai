package ui_inspector_editor

import "core:fmt"
import "core:strings"
import "mirai:asset"
import "mirai:cook/author"
import "mirai:editor"
import "mirai:host"
import "mirai:std/base"
import "mirai:std/serial"
import "mirai:ui"

// The column of nodes: Add, and the nodes in pre-order, indented
// by depth, which the pointer drags into another place. A widget of another
// .ui shows the name of its file. Copy, paste, duplicate and delete come from
// the Edit menu and its shortcuts, or from the menu of a node.

KIND_LABELS :: [ui.Node_Kind]string{.Box="Box",.Text="Text",.Image="Image",.Progress="Progress",.Button="Button",.Checkbox="Checkbox",.Spacer="Spacer",.Component="Component",
    .Scroll="Scroll",.Switcher="Switcher",.List="List",.Prompt="Prompt",.Slider="Slider",.Field="Field",.Selector="Selector",.Dropdown="Dropdown",.Radio="Radio",
    .Tooltip="Tooltip",.Rich_Text="Rich text",.View="View",.Action_Bar="Action bar",.Number="Number",.Tabs="Tabs",.Popup="Popup",.Modal="Modal",
    .Context_Menu="Context menu",.Radial="Radial",.Particles="Particles",.Draw="Draw"}

// The kinds Add offers, in the order of its list.
ADDED_KINDS :: [?]ui.Node_Kind{.Box,.Text,.Rich_Text,.Image,.Button,.Progress,.Checkbox,.Slider,.Field,.Selector,.Dropdown,.Radio,
    .Number,.Prompt,.Action_Bar,.Scroll,.List,.Switcher,.Tabs,.Popup,.Modal,.Context_Menu,.Radial,.Tooltip,.View,.Particles,.Draw,.Spacer}

// How a node looks in the hierarchy and in Add: by its kind, a box by its
// direction, and a widget of another .ui as any widget of the user.
node_icon :: proc(n:^ui.Tree_Node) -> ui.Icon {
    switch n.kind {
    case .Box:
        switch n.layout.direction {
        case .Row:    return .Split
        case .Column: return .Rows
        case .Grid:   return .Grid
        case .Wrap:   return .Rows
        case .Stack:  return .Layers
        }
    case .Text,.Rich_Text: return .Text
    case .Image:           return .Texture
    case .Progress:        return .Gauge
    case .Button:          return .Button
    case .Checkbox:        return .Checkbox_Checked
    case .Spacer:          return .Spacer
    case .Component:       return .Prefab
    case .Scroll:          return .Scroll
    case .Switcher:        return .Layers
    case .List:            return .List
    case .Prompt,.Action_Bar: return .Lightning
    case .Slider:          return .Slider
    case .Field:           return .Field
    case .Selector:        return .Refresh
    case .Dropdown:        return .Dropdown
    case .Radio:           return .Radio
    case .Tooltip:         return .Focus
    case .View:            return .Eye
    case .Number:          return .Axis
    case .Tabs:            return .Split
    case .Popup,.Context_Menu: return .Dropdown
    case .Modal:           return .Focus
    case .Radial:          return .Target
    case .Particles:       return .Particles
    case .Draw:            return .Edit
    }
    return .None
}

ADD_HEIGHT :: f32(360) // of the list of Add, past which it scrolls

// What a person does with the document besides its records: the nodes
// folded, chosen together and renamed in the hierarchy, its filter, the node
// of a widget looked into, the gesture on the stage, the rules of several
// states opened in Style and the sound that waits to know where it goes.
Ux :: struct {
    document:base.Asset_Id,       // what the state below is of
    folds:[dynamic]Fold,          // of every document opened in the session
    picked:[dynamic]int,          // rows of the tree chosen together: they count while they hold the node chosen
    anchor:int,                   // where Shift chooses from; -1: none
    collapse:int,                 // a press on a row of several chosen: only it stays chosen if the button comes up without dragging; -1: none
    rename:int,                   // the row whose name is typed; -1: none
    rename_request:bool,
    name:[ui.TREE_NAME_CAPACITY]u8,
    name_length:int,
    filter:[64]u8,
    filter_length:int,
    revealed:int,                 // the node chosen whose containers were opened last
    peek:Peek,
    widgets:[dynamic]Widget_Peek, // records of the widgets of the project the hierarchy looked into, at widgets_revision
    widgets_revision:u64,
    gesture:Stage_Gesture,
    combo:ui.Style_States,        // the states a new rule of several states waits for
    combo_open:[64]bool,          // by Style_States: the fold of that rule of several states is open
    combo_shown:ui.Style_States,  // of those, the one opened last: Edit shows the node in it
    sound:Sound_Choice,
    style_layout_open:bool, // the rows of the layout of a style in the Style card are open
}

// A node of a document closed in the hierarchy, or a widget instance opened.
@(private)
Fold :: struct {
    document:base.Asset_Id,
    name:[ui.TREE_NAME_CAPACITY]u8,
    open:bool, // an instance whose nodes show; otherwise a container whose nodes do not
}

// A node inside a widget instance, chosen to look at its values.
@(private)
Peek :: struct {
    instance:int, // row of the tree; -1: none
    widget:base.Asset_Id,
    row:int,      // of the nodes of the widget
}

@(private)
Widget_Peek :: struct {
    id:base.Asset_Id,
    records:author.Records,
    ok:bool,
}

ux_free :: proc(x:^Ux) {
    delete(x.folds);delete(x.picked)
    for &w in x.widgets {if w.ok {author.records_destroy(&w.records)}}
    delete(x.widgets)
    x^={}
}

// The state follows the document in front: another one starts with nothing chosen.
@(private)
ux_sync :: proc(u:^Ui_Inspector) {
    x:=&u.ux
    if x.folds.allocator.procedure==nil {
        x.folds=make([dynamic]Fold,u.allocator)
        x.picked=make([dynamic]int,u.allocator)
        x.widgets=make([dynamic]Widget_Peek,u.allocator)
        x.anchor,x.collapse,x.rename,x.revealed,x.peek.instance=-1,-1,-1,-1,-1
    }
    if x.document==u.id {return}
    x.document=u.id
    clear(&x.picked)
    x.anchor,x.collapse,x.rename,x.revealed,x.peek.instance=-1,-1,-1,-1,-1
    x.gesture={}
    x.sound={}
}

// The rows of the tree chosen: those chosen together while they hold the
// node chosen, else that node alone.
chosen_rows :: proc(u:^Ui_Inspector) -> []int {
    rows:=make([dynamic]int,context.temp_allocator)
    if u.selected<0 || u.selected>=len(scope_nodes(u)) {return rows[:]}
    {
        held:=false
        for row in u.ux.picked {if row==u.selected {held=true;break}}
        if held {
            for row in u.ux.picked {if row>=0 && row<len(u.records.nodes) {append(&rows,row)}}
            return rows[:]
        }
    }
    append(&rows,u.selected)
    return rows[:]
}

// Chooses rows together, the last of them the node chosen.
@(private)
choose_rows :: proc(u:^Ui_Inspector,rows:[]int) {
    clear(&u.ux.picked)
    append(&u.ux.picked,..rows)
    u.selected=rows[len(rows)-1] if len(rows)>0 else -1
}

// The key a node folds by: its name, or its row when it has none.
@(private)
fold_name :: proc(n:^ui.Tree_Node,row:int,buffer:[]u8) -> string {
    name:=serial.text_field(n.name[:])
    if name!="" {return name}
    return fmt.bprintf(buffer,"#%d",row)
}

@(private)
fold_find :: proc(u:^Ui_Inspector,n:^ui.Tree_Node,row:int) -> int {
    buffer:[24]u8
    name:=fold_name(n,row,buffer[:])
    for &f,i in u.ux.folds {
        if f.document==u.id && serial.text_field(f.name[:])==name {return i}
    }
    return -1
}

// Whether the nodes inside a node show: a container until it is closed, a
// widget instance once it is opened.
@(private)
node_open :: proc(u:^Ui_Inspector,n:^ui.Tree_Node,row:int) -> bool {
    at:=fold_find(u,n,row)
    if n.kind==.Component {return at>=0 && u.ux.folds[at].open}
    return at<0
}

@(private)
node_open_set :: proc(u:^Ui_Inspector,n:^ui.Tree_Node,row:int,open:bool) {
    at:=fold_find(u,n,row)
    // Kept: an instance opened, a container closed.
    keep:=open if n.kind==.Component else !open
    if !keep {
        if at>=0 {unordered_remove(&u.ux.folds,at)}
        return
    }
    if at>=0 {return}
    f:=Fold{document=u.id,open=open}
    buffer:[24]u8
    ui.tree_text_set(f.name[:],fold_name(n,row,buffer[:]))
    append(&u.ux.folds,f)
}

// The records of a widget of the project, read once for each revision of the assets.
@(private)
widget_records :: proc(u:^Ui_Inspector,a:^host.Assets,id:base.Asset_Id) -> ^author.Records {
    x:=&u.ux
    if x.widgets_revision!=a.revision {
        for &w in x.widgets {if w.ok {author.records_destroy(&w.records)}}
        clear(&x.widgets)
        x.widgets_revision=a.revision
    }
    for &w in x.widgets {if w.id==id {return &w.records if w.ok else nil}}
    w:=Widget_Peek{id=id}
    w.ok=author.records_read(author.assets_of(a),id,&w.records,u.allocator)
    append(&x.widgets,w)
    last:=&x.widgets[len(x.widgets)-1]
    return &last.records if last.ok else nil
}

// Whether a .ui has the one root a use of it needs: a file lent for its styles
// may have none.
@(private)
widget_one_root :: proc(u:^Ui_Inspector,a:^host.Assets,id:base.Asset_Id) -> bool {
    r:=widget_records(u,a,id)
    if r==nil {return false}
    roots:=0
    for &n in r.nodes {roots+=int(n.parent<0)}
    return roots==1
}

// The widget a node of the tree is an instance of; none for another node.
@(private)
node_widget :: proc(r:^author.Records,n:^ui.Tree_Node) -> base.Asset_Id {
    if n.kind!=.Component || n.component==0 || int(n.component)>len(r.components) {return {}}
    return r.components[n.component-1].widget
}

// Whether a widget of the project holds the document, itself or inside the
// widgets it holds: Add does not offer it, as it would hold itself.
@(private)
widget_holds_document :: proc(u:^Ui_Inspector,a:^host.Assets,widget:base.Asset_Id) -> bool {
    Reach :: struct {u:^Ui_Inspector,a:^host.Assets}
    reach:=Reach{u,a}
    return author.widget_reaches(widget,u.id,proc(user:rawptr,id:base.Asset_Id) -> (used:[]ui.Tree_Component,read:bool) {
        reach:=(^Reach)(user)
        r:=widget_records(reach.u,reach.a,id)
        if r==nil {return}
        return r.components[:],true
    },&reach)
}

// What Add puts inside the node chosen when it holds nodes, beside it
// otherwise: a node of a kind, or a widget of another .ui of the project
// that does not hold this one.
@(private)
add_popup :: proc(s:^editor.Session,u:^Ui_Inspector,a:^host.Assets,popup:ui.Id,parent:int) {
    ctx:=s.gui.ctx
    r:=&u.records
    // Under the button, its rows in an area that scrolls.
    if ui.popup(ctx,popup,{min_width=220,search="Search",side=.Below}) {
        needle,searched:=ui.popup_search(ctx,popup)
        if searched {u.add_scroll=0}
        if ui.scroll_area(ctx,ui.id(ctx,"add_rows"),&u.add_scroll,{width=ui.GROW,height=ui.FIT,max_height=ADD_HEIGHT,direction=.Column}) {
            kinds:=ADDED_KINDS
            labels:=KIND_LABELS
            for kind in kinds {
                if !base.contains_fold(labels[kind],needle) {continue}
                shown:=ui.Tree_Node{kind=kind,layout={direction=.Column}}
                if ui.menu_item(ctx,ui.id(ctx,"kind",int(kind)+1),labels[kind],{icon=node_icon(&shown)}) {
                    if row:=author.records_insert(r,parent,kind);row>=0 {
                        choose_rows(u,{row})
                        changed(u,"Add node")
                    } else {editor.notify(s,"That node holds no other node: choose a container")}
                }
            }
            caption:=false
            for &file,i in a.registry.files {
                if file.kind!=asset.KIND_UI || file.id=={} || file.id==u.id {continue}
                dot:=strings.last_index_byte(file.path,'.')
                path:=file.path[:dot] if dot>0 else file.path
                if !base.contains_fold(path,needle) || widget_holds_document(u,a,file.id) {continue}
                if !caption {
                    ui.menu_separator(ctx)
                    if ui.box(ctx,{width=ui.GROW,height=ui.fixed(20),padding={8,0,8,0},align_y=.Center}) {ui.label(ctx,"WIDGETS",ui.metric(ctx,"font_caption"),ui.tone(ctx,"text_caption"),font=ui.FONT_SEMIBOLD)}
                    caption=true
                }
                if ui.menu_item(ctx,ui.id(ctx,"widget",i+1),path,{icon=.Prefab}) {
                    name:=path[strings.last_index_byte(path,'/')+1:]
                    if row:=author.records_widget(r,parent,file.id,name,name);row>=0 {
                        choose_rows(u,{row})
                        changed(u,"Add widget")
                    } else {editor.notify(s,"That node holds no other node: choose a container")}
                }
            }
        }
    }
}

// The nodes, in the room the Hierarchy of the left panel leaves to the document.
@(private)
hierarchy_build :: proc(s:^editor.Session,u:^Ui_Inspector,a:^host.Assets) {
    g:=s.gui
    ctx:=g.ctx
    room,found:=editor.hierarchy_room(g)
    if !found || room.w<=0 || room.h<=0 || !u.read {return}
    column:=ui.Box{width=ui.fixed(room.w),height=ui.fixed(room.h),direction=.Column,float={to=.Surface,offset={room.x,room.y},layer=ui.LAYER_BAR}}
    ui.box_begin(ctx,column)
    defer ui.box_end(ctx,column)
    ui.id_push(ctx,ui.id_derive(ctx,SCOPE,"hierarchy"))
    defer ui.id_pop(ctx)
    nodes_column(s,u,a)
}

// A node dragged in the hierarchy, from where the button went down.
@(private)
Node_Drag :: struct {
    row:int,       // -1: none
    from:[2]f32,
    moving:bool,   // it went farther than NODE_DRAG
}
@(private) NODE_DRAG :: f32(4)
@(private) NODE_INDENT :: f32(12)

// Where a dragged node goes: inside parent (-1: the root), before the row
// before (-1: last); inside: the container lit; line: where a line shows it.
@(private)
Node_Drop :: struct {parent,before,inside:int,line:f32,ok:bool}

// A row the hierarchy shows: a node of the tree, or a node of the widget an
// instance shown open is of, which is only looked at.
@(private)
Shown_Row :: struct {
    row:int,       // of the tree; of the widget's nodes when instance>=0
    instance:int,  // -1: a node of the tree
    depth:int,
    arrow:bool,    // it has nodes inside to show or hide
    open:bool,
}

// The rows shown: those inside a closed node go, and with a filter, the
// nodes whose name or kind has it and the containers above them.
@(private)
shown_rows :: proc(u:^Ui_Inspector,a:^host.Assets,filter:string) -> []Shown_Row {
    r:=&u.records
    list:=r.nodes[:]
    rows:=make([dynamic]Shown_Row,0,len(list),context.temp_allocator)
    labels:=KIND_LABELS
    if filter!="" {
        keep:=make([]bool,len(list),context.temp_allocator)
        for &n,i in list {
            if !base.contains_fold(serial.text_field(n.name[:]),filter) && !base.contains_fold(labels[n.kind],filter) {continue}
            for at:=i;at>=0;at=int(list[at].parent) {keep[at]=true}
        }
        for &n,i in list {
            if keep[i] {append(&rows,Shown_Row{row=i,instance=-1,depth=author.records_depth(list,i)})}
        }
        return rows[:]
    }
    for i:=0;i<len(list); {
        n:=&list[i]
        inside:=author.records_subtree(list,i)
        widget:=node_widget(r,n)
        open:=node_open(u,n,i)
        row:=Shown_Row{row=i,instance=-1,depth=author.records_depth(list,i),arrow=inside>0 || widget!={},open=open}
        append(&rows,row)
        if widget!={} && open {
            if w:=widget_records(u,a,widget);w!=nil {
                for _,k in w.nodes {append(&rows,Shown_Row{row=k,instance=i,depth=row.depth+1+author.records_depth(w.nodes[:],k)})}
            }
        }
        i+=1 if open || inside==0 else inside+1
    }
    return rows[:]
}

@(private)
nodes_column :: proc(s:^editor.Session,u:^Ui_Inspector,a:^host.Assets) {
    ctx:=s.gui.ctx
    r:=&u.records
    x:=&u.ux
    ux_sync(u)
    list:=r.nodes[:]
    selected:=u.selected if u.selected>=0 && u.selected<len(list) else -1
    // A node chosen elsewhere (on the stage, by an undo) shows: what holds it opens.
    if selected!=x.revealed {
        x.revealed=selected
        if selected>=0 {
            for parent:=int(list[selected].parent);parent>=0;parent=int(list[parent].parent) {node_open_set(u,&list[parent],parent,true)}
        }
    }
    if x.peek.instance>=0 && x.peek.instance!=selected {x.peek.instance=-1}
    // Inside what is chosen when it holds nodes, beside it otherwise, or at the root.
    parent:=-1
    if selected>=0 {parent=selected if ui.node_kind_holds(list[selected].kind) else int(list[selected].parent)}
    add:=ui.id(ctx,"add")
    if ui.box(ctx,{width=ui.GROW,height=ui.FIT,padding={0,0,0,4},gap=4,align_y=.Center}) {
        popup:=ui.id_derive(ctx,add,"list")
        if ui.button(ctx,add,{label="Add",icon=.Plus,icon_size=12,variant="field",height=ui.metric(ctx,"control"),size=ui.metric(ctx,"font_small"),padding=8,active=ui.popup_is_open(ctx,popup)}).clicked {
            anchor,_:=ui.widget_rect(ctx,add)
            ui.popup_open(ctx,popup,anchor)
        }
        add_popup(s,u,a,popup,parent)
        if editor.search_field(s,ui.id(ctx,"filter"),x.filter[:],&x.filter_length,"Filter") {u.nodes_scroll=0}
    }
    list=r.nodes[:]
    filter:=string(x.filter[:x.filter_length])
    rows:=shown_rows(u,a,filter)
    chosen:=chosen_rows(u)
    rows_id:=ui.id(ctx,"rows")
    labels:=KIND_LABELS
    drop:Node_Drop
    if u.drag.row>=len(list) {u.drag={row=-1}}
    if u.drag.row>=0 && !u.drag.moving {
        moved:=ctx.pointer-u.drag.from
        if abs(moved.x)+abs(moved.y)>NODE_DRAG {u.drag.moving=true;x.collapse=-1}
    }
    arrows:=false
    for row in rows {if row.arrow {arrows=true;break}}
    toggled:=-1
    if ui.scroll_area(ctx,rows_id,&u.nodes_scroll,{width=ui.GROW,height=ui.GROW,direction=.Column}) {
        for shown,index in rows {
            if shown.instance>=0 {
                widget_row(s,u,a,shown,index,arrows)
                continue
            }
            i:=shown.row
            n:=&list[i]
            name:=serial.text_field(n.name[:])
            kind:=labels[n.kind]
            if n.kind==.Component && n.component>0 && int(n.component)<=len(r.components) {
                template:=&r.components[n.component-1]
                kind=serial.text_field(template.name[:])
                if template.widget!={} {kind=editor.asset_name_of(a,template.widget,"missing")}
            }
            row_id:=ui.id(ctx,"node",i+1)
            if ui.box(ctx,{width=ui.GROW,height=ui.fixed(NODE_ROW),align_y=.Center}) {
                if shown.depth>0 {ui.spacer(ctx,f32(shown.depth)*NODE_INDENT,1)}
                if shown.arrow && filter=="" {
                    if ui.button(ctx,ui.id(ctx,"fold",i+1),{icon=.Chevron_Down if shown.open else .Chevron_Right,icon_color=ui.tone(ctx,"text_muted"),icon_size=10,variant="ghost",width=16,height=NODE_ROW}).clicked {toggled=i}
                } else if arrows && filter=="" {ui.spacer(ctx,16,1)}
                if x.rename==i {
                    rename_field(s,u,i)
                } else {
                    picked:=false
                    for row in chosen {if row==i {picked=true;break}}
                    it:=ui.row(ctx,row_id,{label=name if name!="" else kind,detail=kind if name!="" else "",icon=node_icon(n),icon_size=14,selected=picked && x.peek.instance<0,height=NODE_ROW})
                    if it.pressed {row_press(ctx,u,rows,i,it.double)}
                    if it.right {
                        if !picked {choose_rows(u,{i})}
                        u.selected=i
                        x.peek.instance=-1
                        ui.popup_open(ctx,ui.id_derive(ctx,SCOPE,"node_menu"),{ctx.pointer.x,ctx.pointer.y,0,0})
                    }
                }
            }
            // A node that takes paths of the game shows a link before its kind.
            if author.node_bound(n) {
                if r,found:=ui.widget_rect(ctx,row_id);found {
                    if area,shown:=ui.widget_rect(ctx,rows_id);shown && r.y>=area.y && r.y+r.h<=area.y+area.h {
                        detail:=kind if name!="" else ""
                        room:=ui.text_width(&ctx.font,detail,ui.metric(ctx,"font_small"))+10 if detail!="" else 6
                        if ui.box(ctx,{width=ui.fixed(14),height=ui.fixed(14),align_x=.Center,align_y=.Center,float={to=.Surface,offset={r.x+r.w-room-16,r.y+(r.h-14)*0.5},layer=ui.LAYER_BAR+1}}) {
                            ui.icon(ctx,.Link,ui.tone(ctx,"accent"),12)
                        }
                    }
                }
            }
            if u.drag.moving {
                if rect,found:=ui.widget_rect(ctx,row_id);found && ctx.pointer.y>=rect.y && ctx.pointer.y<rect.y+rect.h {drop=node_drop(list,i,rect,ctx.pointer.y)}
            }
        }
    }
    if toggled>=0 {node_open_set(u,&list[toggled],toggled,!node_open(u,&list[toggled],toggled))}
    if !u.drag.moving {
        if .Left not_in ctx.input.down {
            // A press on one of several chosen that did not drag chooses it alone.
            if x.collapse>=0 && x.collapse<len(list) {choose_rows(u,{x.collapse})}
            x.collapse=-1
            u.drag={row=-1}
        }
        return
    }
    // Where it goes: a line between rows, or the container it goes into lit.
    if drop.ok {
        if area,found:=ui.widget_rect(ctx,rows_id);found {
            if drop.inside>=0 {
                if rect,shown:=ui.widget_rect(ctx,ui.id(ctx,"node",drop.inside+1));shown {
                    if ui.box(ctx,{width=ui.fixed(rect.w),height=ui.fixed(rect.h),float={to=.Surface,offset={rect.x,rect.y},layer=ui.LAYER_BAR+1},stroke=ui.tone(ctx,"accent"),stroke_width=1,radius=3}) {}
                }
            } else if ui.box(ctx,{width=ui.fixed(area.w-8),height=ui.fixed(2),float={to=.Surface,offset={area.x+4,drop.line-1},layer=ui.LAYER_BAR+1},fill=ui.tone(ctx,"accent")}) {}
        }
    }
    if .Left in ctx.input.down {return}
    from:=u.drag.row
    u.drag={row=-1}
    if !drop.ok {return}
    // What is chosen together goes together when the row dragged is one of them.
    moved:=chosen_rows(u)
    together:=len(moved)>1
    if together {
        held:=false
        for row in moved {if row==from {held=true;break}}
        together=held
    }
    if together {
        if placed:=author.records_place_rows(r,moved,drop.parent,drop.before);placed!=nil {
            choose_rows(u,placed)
            changed(u,"Move nodes")
        } else {editor.notify(s,"They cannot go there: a node does not go inside itself, and only containers hold nodes")}
        return
    }
    if row:=author.records_place(r,from,drop.parent,drop.before);row>=0 {
        choose_rows(u,{row})
        changed(u,"Move node")
    } else {editor.notify(s,"It cannot go there: a node does not go inside itself, and only containers hold nodes")}
}

// A press on a row: Ctrl adds it or takes it from what is chosen, Shift
// chooses the rows shown from the last one chosen to it, a double click
// renames it. It starts a drag either way.
@(private)
row_press :: proc(ctx:^ui.Context,u:^Ui_Inspector,rows:[]Shown_Row,i:int,double:bool) {
    x:=&u.ux
    x.peek.instance=-1
    u.editing.open=false
    modifiers:=ctx.input.modifiers
    chosen:=chosen_rows(u)
    switch {
    case double:
        choose_rows(u,{i})
        rename_begin(u,i)
    case .Primary in modifiers:
        kept:=make([dynamic]int,context.temp_allocator)
        held:=false
        for row in chosen {
            if row==i {held=true;continue}
            append(&kept,row)
        }
        if !held {append(&kept,i)}
        choose_rows(u,kept[:])
        x.anchor=i
    case .Shift in modifiers && x.anchor>=0:
        from,to:=-1,-1
        for shown,at in rows {
            if shown.instance>=0 {continue}
            if shown.row==x.anchor {from=at}
            if shown.row==i {to=at}
        }
        if from<0 || to<0 {choose_rows(u,{i});break}
        if from>to {from,to=to,from}
        span:=make([dynamic]int,context.temp_allocator)
        for shown in rows[from:to+1] {if shown.instance<0 && shown.row!=i {append(&span,shown.row)}}
        append(&span,i)
        choose_rows(u,span[:])
    case:
        held:=false
        for row in chosen {if row==i {held=true;break}}
        if held && len(chosen)>1 {
            u.selected=i
            x.collapse=i
        } else {choose_rows(u,{i})}
        x.anchor=i
    }
    if !double {u.drag={row=i,from=ctx.pointer}}
}

// The name of a row typed where the hierarchy shows it.
@(private)
rename_begin :: proc(u:^Ui_Inspector,row:int) {
    if row<0 || row>=len(u.records.nodes) {return}
    u.ux.rename,u.ux.rename_request=row,true
}

@(private)
rename_field :: proc(s:^editor.Session,u:^Ui_Inspector,row:int) {
    ctx:=s.gui.ctx
    x:=&u.ux
    n:=&u.records.nodes[row]
    field:=ui.id(ctx,"rename")
    if x.rename_request {
        x.name_length=copy(x.name[:len(x.name)-1],serial.text_field(n.name[:]))
        ui.edit_request(ctx,field)
        x.rename_request=false
    }
    result:=ui.text_field(ctx,field,x.name[:len(x.name)-1],&x.name_length,{height=NODE_ROW-2})
    if result.committed {
        name:=string(x.name[:x.name_length])
        taken:=false
        for &other,i in u.records.nodes {if i!=row && serial.text_field(other.name[:])==name {taken=true;break}}
        switch {
        case name=="" || name==serial.text_field(n.name[:]):
        case taken: editor.notify(s,fmt.tprintf("Another node is called %s: names find nodes, so each is its own",name))
        case:
            // A node closed keeps closed under its new name.
            closed:=fold_find(u,n,row)
            ui.tree_text_set(n.name[:],name)
            if closed>=0 {ui.tree_text_set(x.folds[closed].name[:],name)}
            changed(u,"Rename node")
        }
    }
    if result.committed || result.cancelled || (!result.editing && !result.began && ctx.edit.id!=field) {x.rename=-1}
}

// A node inside a widget instance: its values show in Properties, and only there.
@(private)
widget_row :: proc(s:^editor.Session,u:^Ui_Inspector,a:^host.Assets,shown:Shown_Row,index:int,arrows:bool) {
    ctx:=s.gui.ctx
    x:=&u.ux
    widget:=node_widget(&u.records,&u.records.nodes[shown.instance])
    w:=widget_records(u,a,widget)
    if w==nil || shown.row>=len(w.nodes) {return}
    n:=&w.nodes[shown.row]
    labels:=KIND_LABELS
    name:=serial.text_field(n.name[:])
    if ui.box(ctx,{width=ui.GROW,height=ui.fixed(NODE_ROW),align_y=.Center}) {
        ui.spacer(ctx,f32(shown.depth)*NODE_INDENT+(16 if arrows else 0),1)
        on:=x.peek.instance==shown.instance && x.peek.widget==widget && x.peek.row==shown.row && u.selected==shown.instance
        it:=ui.row(ctx,ui.id(ctx,"peek",index+1),{label=name if name!="" else labels[n.kind],icon=node_icon(n),icon_size=14,icon_color=ui.tone(ctx,"text_faint"),selected=on,height=NODE_ROW})
        if it.pressed {
            choose_rows(u,{shown.instance})
            x.peek={instance=shown.instance,widget=widget,row=shown.row}
            x.revealed=shown.instance
            u.editing.open=false
        }
    }
}

// Where a node dropped over row i goes: the top half of the row puts it
// before the row, the bottom half after it, and the middle of a container
// inside it, last.
@(private)
node_drop :: proc(list:[]ui.Tree_Node,i:int,rect:ui.Rect,y:f32) -> Node_Drop {
    at:=(y-rect.y)/max(rect.h,1)
    if ui.node_kind_holds(list[i].kind) && at>0.25 && at<0.75 {
        return {parent=i,before=-1,inside=i,ok=true}
    }
    if at<0.5 {return {parent=int(list[i].parent),before=i,inside=-1,line=rect.y,ok=true}}
    next:=i+author.records_subtree(list,i)+1
    before:=next if next<len(list) && list[next].parent==list[i].parent else -1
    return {parent=int(list[i].parent),before=before,inside=-1,line=rect.y+rect.h,ok=true}
}

// The menu of a node of the hierarchy, and the entries of the editor the
// document takes in place of the scene (Copy, Paste, Duplicate, Rename,
// Delete), by their names: on every node chosen.
@(private)
nodes_actions :: proc(s:^editor.Session,u:^Ui_Inspector,a:^host.Assets,d:^editor.Asset_Document) {
    ctx:=s.gui.ctx
    r:=&u.records
    ux_sync(u)
    popup:=ui.id_derive(ctx,SCOPE,"node_menu")
    request:=""
    if d.request_serial!=u.request_seen {
        u.request_seen=d.request_serial
        request=d.request
    }
    if ui.popup(ctx,popup,{min_width=180}) {
        none:=u.selected<0 || u.selected>=len(r.nodes)
        entries:=[5]string{"copy","paste","duplicate","rename","delete"}
        labels:=[5]string{"Copy","Paste","Duplicate","Rename","Delete"}
        for entry,i in entries {
            off:=none if entry!="paste" else len(u.clip.records.nodes)==0
            if ui.menu_item(ctx,ui.id(ctx,"menu_entry",i+1),labels[i],{shortcut=editor.command_shortcut_text(s,entry),disabled=off}) {request=entry}
        }
        ui.menu_separator(ctx)
        box:=!none && r.nodes[u.selected].kind==.Box && len(chosen_rows(u))==1
        if ui.menu_item(ctx,ui.id(ctx,"menu_widget"),"Make widget",{disabled=!box}) {make_widget(s,u,a,d)}
    }
    if request=="" {return}
    row:=u.selected if u.selected>=0 && u.selected<len(r.nodes) else -1
    rows:=chosen_rows(u)
    switch request {
    case "copy":
        if row>=0 {
            author.records_copy_rows(r,rows,&u.clip,u.allocator)
            u.clip.source=u.id
        }
    case "paste":
        clip:=&u.clip.records
        for &template in clip.components {
            if template.widget==u.id {
                editor.notify(s,"An interface does not hold an instance of itself")
                return
            }
        }
        if pasted:=author.records_paste_rows(r,row,&u.clip);len(pasted)>0 {
            choose_rows(u,pasted)
            changed(u,"Paste node" if len(pasted)==1 else "Paste nodes")
        } else if len(clip.nodes)>0 {editor.notify(s,"That node holds no other node: choose a container")}
    case "duplicate":
        if row>=0 {
            if copies:=author.records_duplicate_rows(r,rows);len(copies)>0 {
                choose_rows(u,copies)
                changed(u,"Duplicate node" if len(copies)==1 else "Duplicate nodes")
            }
        }
    case "rename":
        if row>=0 {
            rename_begin(u,row)
            if !(s.gui.layout.left_open && s.gui.layout.library_tab==.Hierarchy) {editor.notify(s,"Hierarchy shows the name to type: open it in the left panel")}
        }
    case "delete":
        if row>=0 {
            first:=author.selection_roots(r.nodes[:],rows)[0]
            author.records_delete_rows(r,rows)
            choose_rows(u,{min(first,len(r.nodes)-1)} if len(r.nodes)>0 else {})
            changed(u,"Delete node" if len(rows)==1 else "Delete nodes")
        }
    }
}

// A node renamed in Properties keeps a name no other node has,
// and what named it follows: here at once and, for the tree, in the .ui that
// instance this one when it is written.
node_renamed :: proc(u:^Ui_Inspector,from:string) {
    name:=author.records_rename(&u.records,u.selected,from)
    if from!="" && name!=from && u.rename_count<len(u.renames) {
        rename:=&u.renames[u.rename_count]
        ui.tree_text_set(rename.from[:],from)
        ui.tree_text_set(rename.to[:],name)
        u.rename_count+=1
    }
    changed(u,"Name")
}

// A Box of the tree and what it holds become a .ui of their own beside the
// file, with only the rows they use, and an instance of it takes their
// place: one step of the history of the document.
@(private)
make_widget :: proc(s:^editor.Session,u:^Ui_Inspector,a:^host.Assets,d:^editor.Asset_Document) {
    r:=&u.records
    row:=u.selected
    widget:author.Records
    record,found:=asset.registry_find(&a.registry,u.id)
    if !found || !author.records_widget_data(r,row,&widget,context.temp_allocator) {
        editor.notify(s,"Only a Box becomes a widget")
        return
    }
    name:=widget_file_name(serial.text_field(r.nodes[row].name[:]))
    folder:=record.path[:strings.last_index_byte(record.path,'/')+1]
    path:=fmt.tprintf("%s%s.ui",folder,name)
    for n:=2;;n+=1 {
        if _,taken:=asset.registry_find_path(&a.registry,path);!taken {break}
        path=fmt.tprintf("%s%s%d.ui",folder,name,n)
    }
    id:=editor.asset_id_new(s)
    data:=author.records_data(&widget)
    imports,imported:=host.ui_tree_imports(a,data)
    bytes:[]u8
    error:=asset.Error.Invalid
    if imported {bytes,error=host.ui_tree_bytes(&a.types,id,data,imports,context.temp_allocator)}
    if error!=.None {
        editor.notify(s,"The widget could not be written")
        return
    }
    inspector_flush(s,u)
    if !editor.asset_history_begin(&d.history,"Make widget") {return}
    written:=editor.asset_document_write(s,d,asset.registry_file_path(&a.registry,path,context.temp_allocator),bytes,"Make widget")
    if written {
        root:=r.nodes[row]
        parent:=int(root.parent)
        author.records_remove(r,row)
        // The instance keeps the name of the box, which the focus of other nodes may name.
        box:=serial.text_field(root.name[:])
        at:=author.records_widget(r,parent,id,box if box!="" else name,name)
        // In the place of the box, laid out as it was.
        if at>=0 && at!=row && row<len(r.nodes) && int(r.nodes[row].parent)==parent {at=author.records_place(r,at,parent,row)}
        if at>=0 {
            r.nodes[at].layout=root.layout
            r.nodes[at].float=root.float
            r.nodes[at].component_fields={.Layout,.Float}
            u.selected=at
        }
        changed(u,"Make widget")
        written=inspector_write(s,u,a,d)
    }
    if !written {
        editor.asset_history_cancel(&d.history)
        editor.notify(s,"The widget could not be written")
        return
    }
    editor.asset_history_end(&d.history)
    u.cursor=d.history.cursor
    editor.notify(s,fmt.tprintf("%s is a widget of its own",path))
}

// The name of a file made of the name of a node: letters, digits, _ and -.
@(private)
widget_file_name :: proc(name:string) -> string {
    b:=make([]u8,len(name),context.temp_allocator)
    for c,i in transmute([]u8)name {
        letter:=c>='a' && c<='z' || c>='A' && c<='Z' || c>='0' && c<='9' || c=='-'
        b[i]=c if letter else '_'
    }
    file:=strings.trim(string(b),"_")
    return file if file!="" else "widget"
}
