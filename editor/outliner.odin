package editor

import "core:fmt"
import "core:math"
import "core:slice"
import "core:strings"
import "mirai:core"
import "mirai:editor/history"
import erender "mirai:engine/render"
import "mirai:std/base"
import "mirai:ui"

// The Scene tab: the entities of the World shown as the tree their Parent
// makes, children in their order. A click selects (Shift adds, Ctrl
// toggles), a double click or F2 renames, dragging a row onto another moves
// it there keeping where it is in the world, and onto the space below the
// rows makes it a root. Only the rows in sight are built; the tree is made
// again when the entities or their parents change.

OUTLINER_ROW :: f32(24)
OUTLINER_INDENT :: f32(14)

@(private)
Outliner_Node :: struct {
    entity:core.Entity,
    parent:i32,      // node; -1 for a root
    order:i32,
    first,count:i32, // its children: children[first:][:count]
}

@(private)
Outliner_Row :: struct {node:i32,depth:i32}

@(storage)
Outliner :: struct {
    nodes:[dynamic]Outliner_Node,
    children:[dynamic]i32,   // nodes grouped by parent
    rows:[dynamic]Outliner_Row,
    node_of:[dynamic]i32,    // by entity index: node+1
    expanded:[dynamic]core.Entity,
    world:rawptr,            // the world the tree was made from; nil: to make again
    shapes:[3]core.Shape,    // of the transforms, the names and the ids then
    parents:core.Seen,
    tree_serial:u64,         // grows each time the tree is made again
    rows_key:[3]u64,
    expanded_serial:u64,
    scroll:f32,
    filter:[64]u8,
    filter_length:int,
    rename:core.Entity,      // the entity whose name is being typed; NONE: none
    rename_request:bool,
    name:[64]u8,
    name_length:int,
    reveal:core.Entity,      // brought into sight by the next build
    menu:core.Entity,        // the entity of the open context menu
    scope:core.Entity,       // the root of the prefab instance or section shown alone as a tree; NONE: the whole scene
}

outliner_reset :: proc(o:^Outliner) {
    clear(&o.expanded)
    o.expanded_serial+=1
    o.world=nil
    o.rename,o.menu,o.reveal,o.scope=core.NONE,core.NONE,core.NONE,core.NONE
    o.scroll=0
}

// Starts typing the name of an entity in its row.
outliner_rename :: proc(o:^Outliner,e:core.Entity) {
    if e==core.NONE {return}
    o.rename,o.rename_request=e,true
    o.reveal=e
}

// Opens the ancestors of an entity and brings its row into sight.
outliner_reveal :: proc(o:^Outliner,w:core.World_Ref,e:core.Entity) {
    at:=entity_parent(w,e)
    for _ in 0..<256 {
        if at==core.NONE {break}
        if !outliner_expanded(o,at) {
            append(&o.expanded,at)
            o.expanded_serial+=1
        }
        at=entity_parent(w,at)
    }
    o.reveal=e
}

@(private)
outliner_expanded :: proc(o:^Outliner,e:core.Entity) -> bool {
    for x in o.expanded {
        if x==e {return true}
    }
    return false
}

@(private)
outliner_toggle :: proc(o:^Outliner,e:core.Entity) {
    for x,i in o.expanded {
        if x==e {
            unordered_remove(&o.expanded,i)
            o.expanded_serial+=1
            return
        }
    }
    append(&o.expanded,e)
    o.expanded_serial+=1
}

// The tree of the entities with a Transform or a Name.
@(private)
outliner_sync :: proc(o:^Outliner,w:core.World_Ref) {
    transforms:=core.world_table_of(w,core.Transform)
    names:=core.world_table_of(w,core.Name)
    parents:=core.world_table_of(w,core.Parent)
    ids:=core.world_table_of(w,core.Id)
    moved:=core.reshaped(transforms,&o.shapes[0]) | core.reshaped(names,&o.shapes[1]) | core.reshaped(ids,&o.shapes[2]) | core.touched(parents,&o.parents)
    if !moved && w.data==o.world {return}
    o.world=w.data
    o.tree_serial+=1
    es:=core.world_entities(w)
    clear(&o.nodes)
    resize(&o.node_of,core.entities_capacity(es))
    slice.fill(o.node_of[:],0)
    add :: proc(o:^Outliner,es:^core.Entities,e:core.Entity) {
        i:=core.entity_index(e)
        if !core.alive(es,e) || i>=len(o.node_of) || o.node_of[i]!=0 {return}
        append(&o.nodes,Outliner_Node{entity=e,parent=-1})
        o.node_of[i]=i32(len(o.nodes))
    }
    if transforms!=nil {for e in transforms.entities {if entity_author(w,e)==e {add(o,es,e)}}}
    if names!=nil {for e in names.entities {if entity_author(w,e)==e {add(o,es,e)}}}
    for &node in o.nodes {
        if parents==nil {break}
        if parent,ok:=core.get(parents,node.entity);ok && parent.entity!=core.NONE {
            i:=core.entity_index(parent.entity)
            if i<len(o.node_of) && o.node_of[i]!=0 && o.nodes[o.node_of[i]-1].entity==parent.entity {node.parent=o.node_of[i]-1}
            node.order=parent.order
        }
    }
    clear(&o.children)
    for _,i in o.nodes {append(&o.children,i32(i))}
    context.user_ptr=o
    slice.sort_by(o.children[:],proc(a,b:i32) -> bool {
        o:=cast(^Outliner)context.user_ptr
        na,nb:=&o.nodes[a],&o.nodes[b]
        if na.parent!=nb.parent {return na.parent<nb.parent}
        if na.order!=nb.order {return na.order<nb.order}
        return core.entity_index(na.entity)<core.entity_index(nb.entity)
    })
    for &node in o.nodes {node.first,node.count=0,0}
    for at:=0;at<len(o.children); {
        parent:=o.nodes[o.children[at]].parent
        end:=at
        for end<len(o.children) && o.nodes[o.children[end]].parent==parent {end+=1}
        if parent>=0 {o.nodes[parent].first,o.nodes[parent].count=i32(at),i32(end-at)}
        at=end
    }
    o.rows_key={}
}

OUTLINER_SCOPE :: f32(28) // the bar of the document shown alone

// The bar over the outliner while it shows one prefab instance or section
// alone: back to the scene, the document and where it is.
@(private)
outliner_scope_bar :: proc(s:^Session,o:^Outliner,w:core.World_Ref) {
    ctx:=s.gui.ctx
    if ui.box(ctx,{width=ui.GROW,height=ui.fixed(OUTLINER_SCOPE),gap=6,align_y=.Center}) {
        if ui.button(ctx,ui.id(ctx,"outliner_scope_back"),{icon=ui.icon_user(u8(User_Icon.Back)),icon_color=ui.tone(ctx,"text_muted"),icon_size=13,variant="ghost",width=22,height=22}).clicked {o.scope=core.NONE}
        kind:=container_kind(w,o.scope)
        icon,text:=container_color(s,kind)
        if ui.box(ctx,{width=ui.FIT,height=ui.fixed(20),padding={8,0,8,0},gap=5,align_y=.Center,fill=ui.color_alpha(icon,36),stroke=icon,radius=10}) {
            ui.icon(ctx,kind==.Section?ui.icon_user(u8(User_Icon.Scene)):.Prefab,icon,12)
            ui.label(ctx,container_document(s,w,o.scope),ui.metric(ctx,"font_label"),text,0,font=ui.FONT_SEMIBOLD)
        }
        path:=make([dynamic]string,context.temp_allocator)
        for at:=container_of(w,o.scope);at!=core.NONE;at=container_of(w,at) {append(&path,entity_label(w,at))}
        append(&path,document_label(s))
        ui.label(ctx,fmt.tprintf("in %s",strings.join(path[:]," › ",context.temp_allocator)),ui.metric(ctx,"font_label"),ui.tone(ctx,"text_faint"))
    }
}

// The rows shown: the open branches of the tree, or what the filter finds.
@(private)
outliner_rows :: proc(o:^Outliner,w:core.World_Ref) {
    filter:=string(o.filter[:o.filter_length])
    key:=[3]u64{o.tree_serial~u64(o.scope)<<32,o.expanded_serial,base.hash64(transmute([]u8)filter)}
    if filter!="" {key[1]=0}
    if key==o.rows_key {return}
    o.rows_key=key
    clear(&o.rows)
    if filter!="" {
        for at in o.children {
            if base.contains_fold(entity_label(w,o.nodes[at].entity),filter) {append(&o.rows,Outliner_Row{at,0})}
        }
        return
    }
    walk :: proc(o:^Outliner,at:i32,depth:i32) {
        append(&o.rows,Outliner_Row{at,depth})
        node:=&o.nodes[at]
        if node.count==0 || !outliner_expanded(o,node.entity) {return}
        for child in o.children[node.first:][:node.count] {walk(o,child,depth+1)}
    }
    if o.scope!=core.NONE {
        if i:=int(core.entity_index(o.scope));i<len(o.node_of) && o.node_of[i]>0 && o.nodes[o.node_of[i]-1].entity==o.scope {
            walk(o,o.node_of[i]-1,0)
            return
        }
        o.scope=core.NONE
    }
    for at in o.children {
        if o.nodes[at].parent>=0 {break}
        walk(o,at,0)
    }
}

@(private)
outliner_build :: proc(s:^Session,w:core.World_Ref,width,height:f32) {
    o:=s.outliner
    g:=s.gui
    ctx:=g.ctx
    v:=s.viewport
    outliner_sync(o,w)
    if search_field(s,ui.id(ctx,"outliner_filter"),o.filter[:],&o.filter_length,"Search entities") {o.scroll=0}
    if o.scope!=core.NONE && !entity_alive(w,o.scope) {o.scope=core.NONE}
    if o.scope!=core.NONE {outliner_scope_bar(s,o,w)}
    outliner_rows(o,w)
    if ui.box(ctx,{width=ui.GROW,height=ui.fixed(16),align_y=.Center}) {
        ui.label(ctx,fmt.tprintf("%d entities",len(o.nodes)),ui.metric(ctx,"font_label"),ui.tone(ctx,"text_faint"))
        ui.spacer(ctx)
        if n:=len(s.selection.entities);n>0 {ui.label(ctx,fmt.tprintf("%d selected",n),ui.metric(ctx,"font_label"),ui.tone(ctx,"accent"))}
    }
    room:=max(height-28-16-2*10-(o.scope!=core.NONE?OUTLINER_SCOPE+4:0),OUTLINER_ROW*2)
    if o.reveal!=core.NONE {
        for row,i in o.rows {
            if o.nodes[row.node].entity==o.reveal {ui.scroll_reveal(&o.scroll,f32(i)*OUTLINER_ROW,f32(i+1)*OUTLINER_ROW,room);break}
        }
        o.reveal=core.NONE
    }
    list:=ui.id(ctx,"outliner_list")
    list_rect,_:=ui.widget_rect(ctx,list)
    first,last:=ui.list_begin(ctx,list,&o.scroll,len(o.rows),OUTLINER_ROW,room)
    target:=core.NONE
    on_row:=false
    // The column of the arrows is there only when a row has one to open.
    arrows:=false
    if o.filter_length==0 {
        for row in o.rows {if o.nodes[row.node].count>0 {arrows=true;break}}
    }
    for index in first..<last {
        row:=o.rows[index]
        node:=&o.nodes[row.node]
        e:=node.entity
        if !entity_alive(w,e) {continue}
        id:=ui.id(ctx,"outliner_row",index+1)
        line:=ui.id(ctx,"outliner_line",index+1)
        line_rect,_:=ui.widget_rect(ctx,line)
        if g.drag.kind!=.None && g.drag.moved && ui.rect_contains(line_rect,ctx.pointer) {target,on_row=e,true}
        if ui.box(ctx,{id=line,width=ui.GROW,height=ui.fixed(OUTLINER_ROW),align_y=.Center,track=true}) {
            // A line along what a prefab instance or a section holds, under the arrow of its root.
            if row.depth>0 {
                ancestors:[64]core.Entity
                n:=min(int(row.depth),len(ancestors))
                at:=entity_parent(w,e)
                for k:=n-1;k>=0 && at!=core.NONE;k-=1 {
                    ancestors[k]=at
                    at=entity_parent(w,at)
                }
                for k in 0..<n {
                    kind:=container_kind(w,ancestors[k])
                    if kind==.None {
                        ui.spacer(ctx,OUTLINER_INDENT,1)
                        continue
                    }
                    guide,_:=container_color(s,kind)
                    if ui.box(ctx,{width=ui.fixed(OUTLINER_INDENT),height=ui.fixed(OUTLINER_ROW)}) {
                        ui.spacer(ctx,7,1)
                        if ui.box(ctx,{width=ui.fixed(1),height=ui.GROW,fill=ui.color_alpha(guide,128)}) {}
                    }
                }
                if int(row.depth)>n {ui.spacer(ctx,f32(int(row.depth)-n)*OUTLINER_INDENT,1)}
            }
            if node.count>0 && o.filter_length==0 {
                open:=outliner_expanded(o,e)
                if ui.button(ctx,ui.id(ctx,"outliner_open",index+1),{icon=open?.Chevron_Down:.Chevron_Right,icon_color=ui.tone(ctx,"text_muted"),icon_size=10,variant="ghost",width=16,height=OUTLINER_ROW}).clicked {outliner_toggle(o,e)}
            } else if arrows {
                ui.spacer(ctx,16,1)
            }
            icon,color:=entity_icon(s,w,e)
            kind:=container_kind(w,e)
            text_color:ui.Color
            if kind!=.None {color,text_color=container_color(s,kind)}
            hidden:=entity_hidden(w,e) || core.entity_off(core.world_entities(w),e)
            if hidden {color=ui.color_alpha(color,110)}
            // While a section is edited in its world, the rest reads only and fades.
            if section_editing(s)!=core.NONE && section_locked(s,w,e) {
                color=ui.color_alpha(color,110)
                text_color=ui.color_alpha(text_color!={}?text_color:ui.tone(ctx,"text"),120)
            }
            if o.rename==e {
                field:=ui.id(ctx,"outliner_name")
                if o.rename_request {
                    o.name_length=copy(o.name[:],entity_name(w,e))
                    ui.edit_request(ctx,field)
                    o.rename_request=false
                }
                r:=ui.text_field(ctx,field,o.name[:],&o.name_length,{height=OUTLINER_ROW-2})
                if r.changed {
                    tool_preview_cancel(s)
                    if !entity_rename(s,e,string(o.name[:o.name_length])) {notify(s,"An entity needs a name")}
                }
                if r.committed || r.cancelled || (!r.editing && !r.began && ctx.edit.id!=field) {o.rename=core.NONE}
            } else {
                selected:=history.selection_has(s.selection,e)
                over:=g.drag.kind==.Entity && drag_over(g,line_rect) && g.drag.entity!=e
                label:=entity_label(w,e)
                it:=ui.row(ctx,id,{label=label,icon=icon,icon_color=color,icon_size=14,text_color=text_color,font=kind!=.None?ui.FONT_SEMIBOLD:0,selected=selected || over,height=OUTLINER_ROW})
                if it.pressed {
                    tool_preview_cancel(s)
                    if entity_alive(w,e) {
                        target:=selection_click_target(s,w,e,it.double)
                        _,linked:=prefab_link_of(w,e)
                        switch {
                        case v.pick.active:                inspector_pick_finish(s,w,e)
                        case it.double && !linked:         outliner_rename(o,e)
                        case .Primary in ctx.input.modifiers: history.selection_toggle(s.selection,target)
                        case .Shift in ctx.input.modifiers:   history.selection_add(s.selection,target)
                        case !history.selection_has(s.selection,target): history.selection_set(s.selection,{target})
                        case:                              history.selection_set(s.selection,{target},true)
                        }
                        if !v.pick.active {drag_begin(g,{kind=.Entity,entity=target},entity_label(w,target))}
                    }
                }
                if it.right {
                    tool_preview_cancel(s)
                    if entity_alive(w,e) {
                        o.menu=e
                        if !selected {history.selection_set(s.selection,{e})}
                        ui.popup_open(ctx,outliner_menu_id(g),{ctx.pointer.x,ctx.pointer.y,0,0})
                    }
                }
            }
            // On the row that is selected or under the pointer: the root of what holds it, and its document alone as a tree.
            if history.selection_has(s.selection,e) || ui.rect_contains(line_rect,ctx.pointer) {
                up:=container_of(w,e)
                tree:=kind!=.None?e:up
                if up!=core.NONE && ui.button(ctx,ui.id(ctx,"outliner_root",index+1),{icon=ui.icon_user(u8(User_Icon.Up)),icon_color=ui.tone(ctx,"text_muted"),icon_size=13,variant="ghost",width=20,height=OUTLINER_ROW}).clicked {
                    history.selection_set(s.selection,{up})
                    if o.scope!=core.NONE && !entity_within(w,up,o.scope) {o.scope=core.NONE}
                    outliner_reveal(o,w,up)
                }
                if tree!=core.NONE && tree!=o.scope && ui.button(ctx,ui.id(ctx,"outliner_tree",index+1),{icon=ui.icon_user(u8(User_Icon.Tree)),icon_color=ui.tone(ctx,"text_muted"),icon_size=13,variant="ghost",width=20,height=OUTLINER_ROW}).clicked {
                    o.scope,o.scroll=tree,0
                    if !outliner_expanded(o,tree) {append(&o.expanded,tree);o.expanded_serial+=1}
                    outliner_reveal(o,w,e)
                }
            }
            eye:=ui.id(ctx,"outliner_eye",index+1)
            own_hidden:=entity_has(w,e,erender.Hidden)
            if ui.button(ctx,eye,{icon=own_hidden?.Eye_Off:.Eye,icon_color=own_hidden?ui.tone(ctx,"text_muted"):ui.tone(ctx,"text_faint"),icon_size=14,variant="ghost",width=22,height=OUTLINER_ROW}).clicked {
                tool_preview_cancel(s)
                entity_hidden_set(s,e,!own_hidden)
            }
        }
    }
    ui.list_end(ctx,list,len(o.rows),last,OUTLINER_ROW)
    // A drop on a row moves under it; below the rows, to the root.
    d:=&g.drag
    if d.kind==.Entity && d.moved && d.released && ui.rect_contains(list_rect,ctx.pointer) {
        outliner_drop(s,w,on_row?target:core.NONE)
    }
    outliner_menu(s,w)
}

// What was dragged goes under target: the selection when the dragged row is in it.
@(private)
outliner_drop :: proc(s:^Session,w:core.World_Ref,target:core.Entity) {
    tool_preview_cancel(s)
    d:=&s.gui.drag
    moved:=[]core.Entity{d.entity}
    if history.selection_has(s.selection,d.entity) {moved=history.selection_roots(s.selection,w)}
    opened,edit_ready:=edit_open(s,"Parent")
    if !edit_ready {return}
    defer edit_close(s,opened)
    refused:=false
    for e in moved {
        if e==target {continue}
        if !entity_reparent(s,e,target) {refused=true}
    }
    if refused {notify(s,"An entity cannot go under itself or under a parent without size")}
    if target!=core.NONE && !outliner_expanded(s.outliner,target) {
        append(&s.outliner.expanded,target)
        s.outliner.expanded_serial+=1
    }
}

@(private)
outliner_menu_id :: proc(g:^Editor_Ui) -> ui.Id {return shell_id(g,"outliner_menu")}

@(private)
outliner_menu :: proc(s:^Session,w:core.World_Ref) {
    o:=s.outliner
    g:=s.gui
    ctx:=g.ctx
    popup:=outliner_menu_id(g)
    e:=o.menu
    if ui.popup_is_open(ctx,popup) && !entity_alive(w,e) {
        ui.popup_close(ctx,popup)
        return
    }
    if ui.popup(ctx,popup,{min_width=200}) {
        playing:=s.mode==.Play
        if ui.menu_item(ctx,ui.id(ctx,"menu_child"),"Add child",{disabled=playing}) {
            tool_preview_cancel(s)
            if !entity_alive(w,e) {return}
            child:=entity_create(s,{name="Group",parent=e})
            history.selection_set(s.selection,{child})
            outliner_reveal(o,w,child)
        }
        if ui.menu_item(ctx,ui.id(ctx,"menu_rename"),"Rename",{shortcut="F2"}) {outliner_rename(o,e)}
        if ui.menu_item(ctx,ui.id(ctx,"menu_duplicate"),"Duplicate",{shortcut=command_shortcut_text(s,"duplicate")}) {command_run(s,"duplicate")}
        if ui.menu_item(ctx,ui.id(ctx,"menu_root"),"Move to root",{disabled=entity_parent(w,e)==core.NONE}) {
            tool_preview_cancel(s)
            if !entity_reparent(s,e,core.NONE) {notify(s,"The entity could not leave its parent")}
        }
        if ui.menu_item(ctx,ui.id(ctx,"menu_focus"),"Focus",{shortcut="F"}) {command_run(s,"focus")}
        ui.menu_separator(ctx)
        for entry,at in ([5]string{"prefab_create","prefab_apply","prefab_apply_base","prefab_revert","prefab_unlink"}) {
            state:=command_state(s,entry)
            if ui.menu_item(ctx,ui.id(ctx,"menu_prefab",at+1),command_label(s,entry),{disabled=state.disabled}) {command_run(s,entry)}
        }
        ui.menu_separator(ctx)
        if ui.menu_item(ctx,ui.id(ctx,"menu_delete"),"Delete",{shortcut="Del"}) {command_run(s,s.mode!=.Edit?"delete_in_game":"delete")}
    }
}

// A section of Create: the cards it lists, by their place in cards().
@(private)
Create_Group :: struct {
    title:string,
    cards:[CARD_CAPACITY]int,
    count:int,
}

// The sections of Create in the order their first cards come in; a card
// with no group goes in Logic.
@(private)
create_groups :: proc(s:^Session,groups:^[CARD_GROUP_CAPACITY]Create_Group) -> (count:int) {
    for card,at in cards(s) {
        title:=card.group if card.group!="" else "Logic"
        found:=-1
        for group,index in groups[:count] {if group.title==title {found=index}}
        if found<0 {
            if count>=len(groups) {continue}
            groups[count].title=title
            found=count
            count+=1
        }
        g:=&groups[found]
        g.cards[g.count]=at
        g.count+=1
    }
    return
}

// The Create tab: the cards as the content browser shows assets, under the
// headers of their groups and at the zoom and in the mode of its cells;
// dragged onto the scene or clicked to place one where the camera looks.
@(private)
create_build :: proc(s:^Session,w:core.World_Ref,height:f32,width:f32=CONTENT_WIDTH) {
    g:=s.gui
    ctx:=g.ctx
    all:=cards(s)
    groups:[CARD_GROUP_CAPACITY]Create_Group
    group_count:=create_groups(s,&groups)
    scroll:=ui.id(ctx,"create_scroll")
    // Ctrl+wheel over Create changes the cells of the browser with them.
    if notches:=ui.zoom(ctx,scroll);notches!=0 && s.content!=nil {content_zoom(&s.content.view,notches)}
    view:=asset_cards_view(s)
    columns,cell:=content_cells(view,width)
    list:=view.mode==.List
    named:=content_shows_names(view)
    ui.scroll_begin(ctx,scroll,&g.create_scroll,{height=ui.FIT,max_height=height})
    defer ui.scroll_end(ctx,scroll,&g.create_scroll)
    for &group,index in groups[:group_count] {
        open:=!g.layout.create_folded[index]
        if create_header(s,ui.id(ctx,"create_group",index+1),group.title,open,width).clicked {open=!open}
        g.layout.create_folded[index]=!open
        if !open {continue}
        listed,count:=group.cards,group.count
        for start:=0;start<count;start+=columns {
            bottom:=CONTENT_GRID_BOTTOM if start+columns>=count else (CONTENT_NAMED_ROW_GAP if named else CONTENT_GAP)
            if list {bottom=0}
            if ui.box(ctx,{width=ui.fixed(width),height=ui.FIT,padding={0,0,0,bottom},gap=CONTENT_GAP}) {
                for which in listed[start:min(start+columns,count)] {
                    card:=all[which]
                    carried:=g.drag.kind==.Preset && g.drag.card==which || g.placement.active && g.placement.kind==.Preset && g.placement.card==which
                    it:=create_card(s,ui.id(ctx,"card",which+1),card,carried,view,cell)
                    if it.pressed && s.mode!=.Play {
                        drag_begin(g,{kind=.Preset,card=which,icon=card.icon,color=card.color},card.label)
                    }
                }
            }
        }
    }
}

// The name of a group of Create, with the arrow that folds what it holds and
// a line under it while it is open.
@(private)
create_header :: proc(s:^Session,id:ui.Id,name:string,open:bool,width:f32) -> ui.Interaction {
    ctx:=s.gui.ctx
    it:=ui.interact(ctx,id,{.Focusable})
    height:=CONTENT_HEADER+2
    if ui.box(ctx,{width=ui.fixed(width),height=ui.fixed(height),direction=.Column}) {
        if ui.box(ctx,{id=id,width=ui.GROW,height=ui.fixed(height-1 if open else height),padding={CONTENT_INSET,0,8,0},gap=7,align_y=.Center,fill=ui.tone(ctx,"field") if it.hot else ui.tone(ctx,"panel"),radius=3}) {
            ui.icon(ctx,.Chevron_Down if open else .Chevron_Right,ui.tone(ctx,"text_faint"),10)
            ui.icon(ctx,ui.icon_user(u8(User_Icon.Folder)),ui.tone(ctx,"text_faint"),14)
            ui.label(ctx,name,ui.metric(ctx,"font"),ui.tone(ctx,"text") if open else ui.tone(ctx,"text_muted"),0,font=ui.FONT_MEDIUM)
        }
        if open {
            if ui.box(ctx,{width=ui.GROW,height=ui.fixed(1),fill=ui.tone(ctx,"divider")}) {}
        }
    }
    return it
}

// A card as the browser shows an asset: a row of its list, or its icon on a
// thumbnail with the line of the color of its group and its name under it.
@(private)
create_card :: proc(s:^Session,id:ui.Id,card:Card,carried:bool,view:Content_View,cell:f32) -> (it:ui.Interaction) {
    ctx:=s.gui.ctx
    it=ui.interact(ctx,id,{.Focusable})
    keyboard:=content_keyboard(ctx,it)
    if view.mode==.List {
        if ui.box(ctx,asset_row_box(ctx,id,CONTENT_INSET,carried,it.hot,keyboard)) {
            asset_frame(s,20,card.color,CONTENT_FRAME_EDGE,1,{},card.icon,card.color,0)
            ui.label(ctx,card.label,ui.metric(ctx,"font"),ui.tone(ctx,"text"),0,font=ui.FONT_MEDIUM if carried else 0)
        }
        return
    }
    if ui.box(ctx,asset_card_box(ctx,id,view,cell,carried,keyboard)) {
        edge,stroke:=asset_frame_edge(ctx,it.hot,carried)
        asset_frame(s,cell,card.color,edge,stroke,{},card.icon,card.color,0)
        names:=content_shows_names(view)
        if names {content_name(ctx,card.label,carried,cell)}
        if it.hot && (!names || content_name_cut(ctx,card.label,cell)) {ui.tooltip(ctx,card.label)}
    }
    return
}

