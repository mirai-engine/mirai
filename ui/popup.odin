package ui

import "core:fmt"
import "core:strings"

// Floating surfaces: panels, popups that hang from what opened them (menus,
// dropdowns), tooltips and modal dialogs. Which popups are open is state of
// the context; everything else comes from the caller.

POPUP_DEPTH :: 4

@(private)
Popup_Entry :: struct {
    id:Id,
    anchor:Rect,  // what it hangs from
    layer:i16,
    cursor:int,   // row the keyboard is on; -1: none
    keys:bool,    // Up, Down and Enter in its search move over its rows and take one (row)
    rows_last:int,// rows it had last frame
    take:bool,    // Enter took the row of the cursor this frame
    moved:bool,   // the keys moved the cursor: its row comes into sight
    scroll:f32,
    opened:u64,   // frame it was opened
    built:u64,    // last frame it was built
    menu:bool,    // one of the menus of a bar: its neighbours open by hovering
    side:bool,    // a submenu: beside the item that opened it instead of under it
    filter:[64]u8,
    filter_length:int,
    filter_focused:bool,
    filter_changed:bool, // the search of the popup changed this frame
    icons,icons_next:bool, // an item of it has an icon, last frame and this one: its items keep the column of icons
}
@(private)
Popup_State :: struct {
    stack:[POPUP_DEPTH]Popup_Entry,
    count:int,
    depth:int,    // popups being built around the current element
    rows:[POPUP_DEPTH]int, // items each popup being built has so far
    building:[POPUP_DEPTH]int, // the entry of the stack of each popup being built
    closed:u64,   // the frame a press closed popups: that press opens none
}

@(private)
popup_find :: proc(ctx:^Context,id:Id) -> ^Popup_Entry {
    for &entry in ctx.popup.stack[:ctx.popup.count] {if entry.id==id {return &entry}}
    return nil
}

// Opens the popup id hanging from anchor. Popups opened from inside another
// stack on it; any other one that was open closes.
popup_open :: proc(ctx:^Context,id:Id,anchor:Rect) {
    p:=&ctx.popup
    p.count=min(p.depth,p.count)
    if p.count>=POPUP_DEPTH {return}
    base:=LAYER_POPUP if ctx.layer<LAYER_MODAL else ctx.layer+2
    p.stack[p.count]={id=id,anchor=anchor,layer=base+i16(p.count)*2,cursor=-1,opened=ctx.stats.frame}
    p.count+=1
}
popup_is_open :: proc(ctx:^Context,id:Id) -> bool {return popup_find(ctx,id)!=nil}
// Closes the popup id and those opened from it; every popup when id is 0.
popup_close :: proc(ctx:^Context,id:Id=0) {
    p:=&ctx.popup
    if id==0 {p.count=0;return}
    for entry,i in p.stack[:p.count] {if entry.id==id {p.count=i;return}}
}

// Before the frame is built: a press outside the open popups closes them and
// does nothing else, and Escape closes the last one. A press on a menu keeps
// its submenus open.
@(private)
popup_route :: proc(ctx:^Context) {
    p:=&ctx.popup
    if p.count==0 {return}
    in_:=&ctx.input
    if in_.pressed&{.Left,.Right}!={} {
        keep:=0
        for entry,i in p.stack[:p.count] {if ctx.hot!=0 && ctx.hot_layer>=entry.layer {keep=i+1}}
        // A press on a menu leaves its submenus to its items: the one that opened it chooses or closes it.
        for keep>0 && keep<p.count && p.stack[keep].side {keep+=1}
        if keep<p.count {
            p.count=keep
            p.closed=ctx.stats.frame
            ctx.press_used=true;ctx.right_press_used=true
        }
    }
    if p.count>0 && ctx.edit.id==0 && !ctx.escape_used && (.Escape in in_.keys_pressed || .Cancel in in_.pad) {
        p.count-=1;ctx.escape_used=true
    }
}

@(private)
popup_frame_end :: proc(ctx:^Context) {
    p:=&ctx.popup
    // A popup nobody built this frame is gone, and so are the ones on it.
    for entry,i in p.stack[:p.count] {
        if entry.built!=ctx.stats.frame && entry.opened!=ctx.stats.frame {p.count=i;break}
    }
}

// True once per frame when Escape (or Cancel on a gamepad) was pressed and no
// text field or popup used it: the moment to close a dialog or to deselect.
escape :: proc(ctx:^Context) -> bool {
    if ctx.escape_used || ctx.edit.id!=0 {return false}
    if .Escape in ctx.input.keys_pressed || .Cancel in ctx.input.pad {ctx.escape_used=true;return true}
    return false
}

// Size of the surface being built.
surface_size :: proc(ctx:^Context) -> [2]f32 {
    if ctx.surface!=0 {return ctx.panels[ctx.surface-1].size}
    return ctx.size
}

// Which side of its anchor a popup opens on. Auto: under it when it fits.
Popup_Side :: enum u8 {Auto,Below,Above}

// Where a popup of w by h goes so it stays inside the surface: on the side of
// its anchor it asks for, or the other one when it does not fit there. Inside
// a panel (within) it lines up with the panel instead of with the anchor.
popup_origin :: proc(ctx:^Context,anchor:Rect,w,h:f32,align_right:bool,side:Popup_Side=.Auto,within:Rect={}) -> [2]f32 {
    th:=&ctx.theme
    size:=surface_size(ctx)
    top:=th.bar_height+2 if ctx.surface==0 else 0
    left,right:=anchor.x,anchor.x+anchor.w
    if within.w>0 {left,right=within.x,within.x+within.w}
    x:=right-w if align_right else left
    below,above:=anchor.y+anchor.h+4,anchor.y-h-4
    y:=below
    switch side {
    case .Auto,.Below: if below+h>size.y-th.margin && above>=top {y=above}
    case .Above:       y=above if above>=top || below+h>size.y-th.margin else below
    }
    return {clamp(x,th.margin,max(size.x-w-th.margin,th.margin)),clamp(y,top,max(size.y-h-th.margin,top))}
}

// Where a submenu of w by h goes: right of the item it hangs from, with its
// first item level with it, or left of the menu when it does not fit there.
@(private)
popup_side_origin :: proc(ctx:^Context,anchor:Rect,w,h,padding:f32) -> [2]f32 {
    th:=&ctx.theme
    size:=surface_size(ctx)
    top:=th.bar_height+2 if ctx.surface==0 else 0
    x:=anchor.x+anchor.w+padding
    if x+w>size.x-th.margin {x=anchor.x-w-padding}
    y:=anchor.y-padding
    return {clamp(x,th.margin,max(size.x-w-th.margin,th.margin)),clamp(y,top,max(size.y-h-th.margin,top))}
}

Popup :: struct {
    width:f32,        // 0: as wide as its content, at least min_width
    min_width:f32,
    height:f32,       // when known beforehand; otherwise the one it had last frame
    align_right:bool, // its right edge under the right edge of the anchor
    padding:f32,      // 4 when 0
    flush:bool,       // no padding: what it holds reaches its edges, as the bands of its sections
    gap:f32,
    side:Popup_Side,
    within:Rect,      // the panel it lines up with; nothing: its anchor
    search:string,    // the placeholder of a search over its rows, which takes the keys when it opens; empty: none
    own_keys:bool,    // its builder moves over its rows with the keys itself (a dropdown)
    style:^Node_Style, // a game's: the box takes its fill, stroke, corners and shadow instead of those of the theme
}

// What is built from here to popup_leave belongs to the open popup entry:
// the popups it opens stack on it, its items count in it, and nothing it was
// opened from clips it.
@(private)
popup_enter :: proc(ctx:^Context,entry:^Popup_Entry) {
    p:=&ctx.popup
    entry.built=ctx.stats.frame
    p.rows[p.depth]=0
    for &other,index in p.stack[:p.count] {if &other==entry {p.building[p.depth]=index}}
    entry.icons,entry.icons_next=entry.icons_next,false
    ctx.clip_stack[ctx.clip_depth]=0
    ctx.clip_depth+=1
    p.depth+=1
}
@(private)
popup_leave :: proc(ctx:^Context,entry:^Popup_Entry) {
    ctx.popup.depth-=1
    if entry!=nil {entry.rows_last=ctx.popup.rows[ctx.popup.depth]}
    ctx.clip_depth-=1
}

// Opens the popup id when it is open: what is built until popup_end is inside.
popup_begin :: proc(ctx:^Context,id:Id,desc:Popup={}) -> bool {
    entry:=popup_find(ctx,id)
    if entry==nil || ctx.popup.depth>=POPUP_DEPTH {return false}
    th:=&ctx.theme
    previous,_:=widget_rect(ctx,id)
    w:=desc.width if desc.width>0 else max(previous.w,desc.min_width)
    h:=desc.height if desc.height>0 else previous.h
    padding:=desc.padding if desc.padding>0 || desc.flush else 4
    origin:=popup_origin(ctx,entry.anchor,w,h,desc.align_right,desc.side,desc.within)
    if entry.side {origin=popup_side_origin(ctx,entry.anchor,w,h,padding)}
    popup_enter(ctx,entry)
    // Until its height is known it would land under its anchor and jump over
    // it a frame later: its first frame only lays it out, unseen.
    unknown:=h<=0
    b:=Box{id=id,width=fixed(desc.width) if desc.width>0 else fit(desc.min_width),height=FIT,direction=.Column,padding=padding_all(padding),gap=desc.gap,
        float={to=.Surface,offset=origin,layer=entry.layer},fill=th.popup,stroke=th.border,radius=th.radius_popup,shadow=true,block=true,layer={enabled=unknown,opacity=0}}
    if s:=desc.style;s!=nil {
        b.fill,b.stroke,b.stroke_width,b.radius,b.corners=s.fill,s.stroke,s.stroke_width,0,s.radius
        b.shadow,b.shadow_color,b.shadow_blur,b.shadow_offset=s.shadow,s.shadow_color,s.shadow_blur,s.shadow_offset
    }
    box_begin(ctx,b)
    entry.filter_changed=false
    if desc.search!="" {
        search:=id_derive(ctx,id,"search")
        if !entry.filter_focused {edit_request(ctx,search);entry.filter_focused=true}
        // Typing in the search, the keys go over the rows: Enter takes the one
        // of the cursor, the first one until they move. Read before the
        // search, which ends its edit with Enter.
        entry.keys,entry.take=!desc.own_keys,false
        if entry.keys {
            if entry.cursor<0 {entry.cursor=0}
            in_:=&ctx.input
            if ctx.edit.id==search && entry.rows_last>0 {
                step:=0
                if .Down in in_.keys_repeated {step=1}
                if .Up in in_.keys_repeated {step=-1}
                if step!=0 {entry.cursor,entry.moved=clamp(entry.cursor+step,0,entry.rows_last-1),true}
                entry.take=.Enter in in_.keys_pressed
            }
        }
        if text_field(ctx,search,entry.filter[:],&entry.filter_length,{placeholder=desc.search,live=true,height=th.row}).changed {
            entry.scroll,entry.cursor,entry.filter_changed=0,0 if entry.keys else -1,true
        }
        spacer(ctx,-1,POPUP_SEARCH_GAP)
    }
    return true
}

POPUP_SEARCH_GAP :: f32(4) // between the search of a popup and its rows

// What the search of the open popup id holds, and whether it changed this frame.
popup_search :: proc(ctx:^Context,id:Id) -> (text:string,changed:bool) {
    entry:=popup_find(ctx,id)
    if entry==nil {return}
    return string(entry.filter[:entry.filter_length]),entry.filter_changed
}

// Lets go of the keys the search of the popup id has, before it closes.
@(private)
popup_search_release :: proc(ctx:^Context,id:Id) {
    if ctx.edit.id==id_derive(ctx,id,"search") {ctx.edit={}}
}

popup_end :: proc(ctx:^Context,id:Id) {
    popup_leave(ctx,popup_find(ctx,id))
    box_end(ctx,{id=id,float={to=.Surface}})
}
// Builds the popup id while it is open: `if popup(ctx,id,{...}) {rows}`.
@(deferred_in_out=popup_scope_end)
popup :: proc(ctx:^Context,id:Id,desc:Popup={}) -> bool {return popup_begin(ctx,id,desc)}
@(private)
popup_scope_end :: proc(ctx:^Context,id:Id,desc:Popup,open:bool) {
    if open {popup_end(ctx,id)}
}

// ---------------------------------------------------------------- menus

// The title of a menu of a bar. While it returns true its popup is open:
// build the items. Next to an open menu, pointing at a title opens its own.
// look: an icon before the title and its inset.
@(deferred_in_out=menu_scope_end)
menu :: proc(ctx:^Context,id:Id,title:string,height:f32=26,look:Button={}) -> bool {
    p:=&ctx.popup
    list:=id_derive(ctx,id,"menu")
    open:=popup_is_open(ctx,list)
    title_button:=look
    title_button.label,title_button.style,title_button.active,title_button.height=title,.Ghost,open,height
    it:=button(ctx,id,title_button)
    anchor,_:=widget_rect(ctx,id)
    anchor={anchor.x,ctx.theme.bar_height-4 if ctx.surface==0 && anchor.y<ctx.theme.bar_height else anchor.y+anchor.h-4,anchor.w,0}
    if it.clicked && !open {
        popup_open(ctx,list,anchor)
        p.stack[p.count-1].menu=true
    } else if !open && p.count==1 && p.stack[0].menu && it.hot && p.depth==0 {
        p.stack[0]={id=list,anchor=anchor,layer=p.stack[0].layer,cursor=-1,opened=ctx.stats.frame,menu=true}
    }
    return popup_begin(ctx,list,{min_width=MENU_WIDTH})
}
@(private)
menu_scope_end :: proc(ctx:^Context,id:Id,title:string,height:f32,look:Button,open:bool) {
    if open {popup_end(ctx,id_derive(ctx,id,"menu"))}
}
menu_is_open :: proc(ctx:^Context,id:Id) -> bool {return popup_is_open(ctx,id_derive(ctx,id,"menu"))}

// How a menu button looks and how its menu opens.
Menu_Button :: struct {
    width:f32,       // 0 fits its text
    height:f32,      // row when 0
    size:f32,        // text size; font_small when 0
    disabled:bool,
    popup:Popup,
}

// A button that shows a choice and opens the menu of the others: `if
// menu_button(ctx,id,"Low",{popup={side=.Above}}) {items}`. Every picker of
// one value is one of these with menu items, the chosen one checked.
@(deferred_in_out=menu_button_scope_end)
menu_button :: proc(ctx:^Context,id:Id,text:string,b:Menu_Button={}) -> bool {
    th:=&ctx.theme
    list:=id_derive(ctx,id,"menu")
    open:=popup_is_open(ctx,list)
    if button(ctx,id,{label=text,icon=.Chevron_Down,icon_after=true,icon_size=11,icon_color=th.text_muted,style=.Ghost,width=b.width,height=b.height if b.height>0 else th.row,size=b.size if b.size>0 else th.font_small,active=open,disabled=b.disabled,padding=6}).clicked && !open {
        anchor,_:=widget_rect(ctx,id)
        popup_open(ctx,list,anchor)
    }
    desc:=b.popup
    if desc.min_width==0 && desc.width==0 {desc.min_width=MENU_CHOICE_WIDTH}
    return popup_begin(ctx,list,desc)
}
@(private)
menu_button_scope_end :: proc(ctx:^Context,id:Id,text:string,b:Menu_Button,open:bool) {
    if open {
        list:=id_derive(ctx,id,"menu")
        if !popup_is_open(ctx,list) {popup_search_release(ctx,list)}
        popup_end(ctx,list)
    }
}

MENU_CHOICE_WIDTH :: f32(140) // the least width of the menu of a menu button
MENU_WIDTH :: f32(230) // of a menu of a bar
MENU_ICON :: f32(16)   // the column of icons every item keeps

// What an item of a menu shows besides its text.
Menu_Item :: struct {
    icon:Icon,        // in the column of icons
    icon_color:Color, // text_muted when transparent
    shortcut:string,
    checked:bool,     // a check at its right end
    disabled:bool,    // shown faded; it does nothing
    chosen:^bool,     // of a submenu that is also a choice: a click sets it and closes the menu
    danger:bool,      // it destroys something: its text in the color of danger
}

// An item of a menu. Returns true when it was chosen, which closes the menu.
menu_item :: proc(ctx:^Context,id:Id,text:string,item:Menu_Item={}) -> bool {
    if menu_row(ctx,id,text,item,false,false).clicked {
        popup_close(ctx)
        return true
    }
    return false
}

// An item that opens a menu beside it while the pointer is on it or after a
// click: `if submenu(ctx,id,"GI",{icon=.Layers}) {items}`. Pointing at another
// item of the same menu closes it. With item.chosen a click chooses the item
// instead, as menu_item does.
@(deferred_in_out=submenu_scope_end)
submenu :: proc(ctx:^Context,id:Id,text:string,item:Menu_Item={}) -> bool {
    list:=id_derive(ctx,id,"submenu")
    open:=popup_is_open(ctx,list)
    it:=menu_row(ctx,id,text,item,open,true)
    if item.chosen!=nil && it.clicked {
        item.chosen^=true
        popup_close(ctx)
    } else if !open && (it.hot && ctx.pointer_moved || it.clicked) {
        anchor,found:=widget_rect(ctx,id)
        if found {
            popup_open(ctx,list,anchor)
            if entry:=popup_find(ctx,list);entry!=nil {entry.side=true}
        }
    } else if open && it.clicked {
        popup_close(ctx,list)
    }
    return popup_begin(ctx,list,{min_width=MENU_WIDTH-30})
}
@(private)
submenu_scope_end :: proc(ctx:^Context,id:Id,text:string,item:Menu_Item,open:bool) {
    if open {popup_end(ctx,id_derive(ctx,id,"submenu"))}
}

// The title of a group of items, over a rule unless it opens the menu.
menu_header :: proc(ctx:^Context,text:string) {
    th:=&ctx.theme
    p:=&ctx.popup
    first:=p.depth==0 || p.rows[p.depth-1]==0
    if box(ctx,{width=GROW,height=FIT,direction=.Column}) {
        if !first {
            if box(ctx,{width=GROW,height=fixed(1),fill=th.border}) {}
        }
        if box(ctx,{width=GROW,height=FIT,padding={6,6,6,2}}) {
            label(ctx,text,MENU_HEADER_FONT,th.text_faint,0)
        }
    }
    menu_row_count(ctx)
}

menu_separator :: proc(ctx:^Context) {
    if box(ctx,{width=GROW,height=fixed(9),padding={6,0,6,0},align_y=.Center}) {divider(ctx)}
}

@(private)
MENU_HEADER_FONT :: f32(10)

// The item of a menu as the editor draws it: an icon column, the text, the
// shortcut and, at the right end, the check or the arrow of a submenu.
@(private)
menu_row :: proc(ctx:^Context,id:Id,text:string,item:Menu_Item,open,arrow:bool) -> (it:Interaction) {
    th:=&ctx.theme
    disabled:=item.disabled || ctx.disabled_depth>0
    it=interact(ctx,id,{.Focusable} if !disabled else {.Passive})
    if disabled {it={}} else {popup_row_keys(ctx,id,&it)}
    // Pointing at an item closes the submenu another item of this menu opened.
    if it.hot && !arrow {menu_submenus_close(ctx)}
    text_color,muted:=th.danger_soft if item.danger else th.text,th.text_muted
    icon_color:=item.icon_color if item.icon_color[3]>0 else th.text_muted
    check:=th.accent_hover
    if disabled {
        text_color,muted,icon_color,check=color_faded(text_color),color_faded(muted),color_faded(icon_color),color_faded(check)
    }
    fill:=color_hover(th) if it.hot || open else Color{}
    // The items of a menu of the prototype are text of 11.
    size:=th.font
    shortcut:=f32(0)
    if item.shortcut!="" {shortcut=text_width(&ctx.font,item.shortcut,MENU_HEADER_FONT)+1}
    // The column of icons is there when an item of the menu has one: the text of all of them lines up.
    column:=item.icon!=.None
    if p:=&ctx.popup;p.depth>0 {
        entry:=&p.stack[p.building[p.depth-1]]
        column||=entry.icons
        if item.icon!=.None {entry.icons_next=true}
    }
    if box(ctx,{id=id,width=grow((MENU_ICON+7 if column else 0)+text_width(&ctx.font,text,size)+shortcut+57),height=fixed(th.control),padding={6,0,6,0},gap=7,align_y=.Center,fill=fill,radius=th.radius_control}) {
        if column {element_leaf(ctx,{layout={width=fixed(MENU_ICON),height=fixed(MENU_ICON)},custom=paint_add(ctx,{kind=.Icon,icon=item.icon,icon_color=icon_color,icon_size=MENU_ICON}) if item.icon!=.None else nil})}
        label(ctx,text,size,text_color,0)
        if item.shortcut!="" {label(ctx,item.shortcut,MENU_HEADER_FONT,muted,shortcut)}
        if item.checked {icon(ctx,.Check,check,13)}
        if arrow {icon(ctx,.Chevron_Right,muted,12)}
    }
    menu_row_count(ctx)
    return
}

// A row of the open popup that its builder draws as a box with id, as an
// item of a menu: the keys of its search move over it and Enter takes it.
popup_row :: proc(ctx:^Context,id:Id) -> (it:Interaction) {
    it=interact(ctx,id,{.Focusable})
    popup_row_keys(ctx,id,&it)
    menu_row_count(ctx)
    return
}

// With a search, the keys move over the rows of a popup as over a list.
@(private)
popup_row_keys :: proc(ctx:^Context,id:Id,it:^Interaction) {
    p:=&ctx.popup
    if p.depth==0 {return}
    entry:=&p.stack[p.building[p.depth-1]]
    if !entry.keys {return}
    index:=p.rows[p.depth-1]
    if it.hot && ctx.pointer_moved {entry.cursor=index}
    if index==entry.cursor {
        it.hot=true
        if entry.take {it.clicked,entry.take=true,false}
        if entry.moved {ctx.reveal_next,entry.moved=id,false}
    }
}

@(private)
menu_row_count :: proc(ctx:^Context) {
    p:=&ctx.popup
    if p.depth>0 {p.rows[p.depth-1]+=1}
}

// Closes the submenus the menu being built opened.
@(private)
menu_submenus_close :: proc(ctx:^Context) {
    p:=&ctx.popup
    if p.depth>0 && p.count>p.depth {p.count=p.depth}
}

// ---------------------------------------------------------------- dropdown

Dropdown :: struct {
    width:f32,     // of the button: 0 fits, negative grows
    height:f32,
    size:f32,      // text size; font_small when 0
    rows:int,      // rows shown before the list scrolls; 10 when 0
    row_height:f32,
    empty:string,  // shown when selected^ is not one of the options
    disabled:bool,
    searchable:bool,
}

// A button that shows the chosen option and opens the list of all of them.
// Returns true when the choice changed. With created, a searchable list
// offers to create what was searched when no option is it, and created takes
// it (in the temp allocator) when that row is clicked.
dropdown :: proc(ctx:^Context,id:Id,options:[]string,selected:^int,d:Dropdown={},created:^string=nil) -> (changed:bool) {
    th:=&ctx.theme
    open:=popup_is_open(ctx,id_derive(ctx,id,"list"))
    chosen:=options[selected^] if selected^>=0 && selected^<len(options) else d.empty
    it:=button(ctx,id,{label=chosen,style=.Well,width=d.width,height=d.height,size=d.size if d.size>0 else th.font_small,active=open,disabled=d.disabled,icon=.Chevron_Down,icon_size=13,icon_after=true,icon_color=th.text_muted,padding=7})
    list:=id_derive(ctx,id,"list")
    if it.clicked && !open {
        anchor,_:=widget_rect(ctx,id)
        popup_open(ctx,list,anchor)
        popup_find(ctx,list).cursor=selected^
    }
    entry:=popup_find(ctx,list)
    if entry==nil {return}
    row_height:=d.row_height if d.row_height>0 else th.row
    size:=surface_size(ctx)
    search_height:=th.row+POPUP_SEARCH_GAP if d.searchable else f32(0)
    capacity:=clamp(int((size.y-th.bar_height-2*th.margin-8-search_height)/row_height),1,d.rows if d.rows>0 else 10)
    matches:=0
    filter:=string(entry.filter[:entry.filter_length])
    for option in options {if dropdown_matches(option,filter) {matches+=1}}
    // A list that can create what it does not find keeps no empty row for it.
    least:=created!=nil && d.searchable && filter!=""?0:1
    height:=f32(clamp(matches,least,capacity))*row_height
    choice:=-1
    // The keyboard moves the row and Enter takes it.
    in_:=&ctx.input
    search:=id_derive(ctx,list,"search")
    if (ctx.edit.id==0 || d.searchable && ctx.edit.id==search) && entry.opened!=ctx.stats.frame {
        direction:=0
        if .Down in in_.keys_repeated || .Down in in_.pad {direction=1}
        if .Up in in_.keys_repeated || .Up in in_.pad {direction=-1}
        if direction!=0 {
            cursor:=entry.cursor+direction
            if entry.cursor<0 && direction<0 {cursor=len(options)-1}
            for cursor>=0 && cursor<len(options) {
                if dropdown_matches(options[cursor],filter) {entry.cursor=cursor;break}
                cursor+=direction
            }
            visible:=0
            for option,index in options {
                if !dropdown_matches(option,filter) {continue}
                if index==entry.cursor {scroll_reveal(&entry.scroll,f32(visible)*row_height,f32(visible+1)*row_height,height);break}
                visible+=1
            }
        }
        if .Enter in in_.keys_pressed || .Accept in in_.pad {
            if entry.cursor<0 {
                for option,index in options {if dropdown_matches(option,filter) {entry.cursor=index;break}}
            }
            if entry.cursor>=0 && entry.cursor<len(options) && dropdown_matches(options[entry.cursor],filter) {choice=entry.cursor}
        }
    }
    creating:=created!=nil && d.searchable && entry.filter_length>0 ? row_height : 0
    if popup(ctx,list,{width=max(entry.anchor.w,180),height=height+search_height+creating+8,search="Search" if d.searchable else "",own_keys=true}) {
        id_push(ctx,list)
        if d.searchable {
            filter,_=popup_search(ctx,list)
            matches=0
            for option in options {if dropdown_matches(option,filter) {matches+=1}}
            least=created!=nil && filter!=""?0:1
            height=f32(clamp(matches,least,capacity))*row_height
        }
        first,last:=list_begin(ctx,ui_id(ctx,"rows"),&entry.scroll,matches,row_height,height,row_height*1.5)
        visible:=0
        for option,index in options {
            if !dropdown_matches(option,filter) {continue}
            at:=visible
            visible+=1
            if at<first || at>=last {continue}
            row_id:=ui_id(ctx,"row",index+1)
            // A row takes the keyboard row when the pointer moves onto it.
            if ctx.hot==row_id && ctx.pointer_moved {entry.cursor=index}
            current:=index==selected^
            if row(ctx,row_id,{label=option,selected=entry.cursor==index,checked=current,check_room=!current,quiet=true,height=row_height}).clicked {choice=index}
        }
        if matches==0 && created==nil {label(ctx,"No results",th.font_small,th.text_faint)}
        list_end(ctx,ui_id(ctx,"rows"),matches,last,row_height)
        if created!=nil && d.searchable && filter!="" {
            exact:=false
            for option in options {exact ||= strings.equal_fold(option,filter)}
            if !exact && row(ctx,ui_id(ctx,"create"),{label=fmt.tprintf("Create \"%s\"",filter),quiet=true,height=row_height}).clicked {
                created^=strings.clone(filter,context.temp_allocator)
                if ctx.edit.id==search {ctx.edit={}}
                popup_close(ctx,list)
            }
        }
        id_pop(ctx)
    }
    if choice>=0 {
        if ctx.edit.id==search {ctx.edit={}}
        popup_close(ctx,list)
        if choice!=selected^ {selected^=choice;changed=true}
    }
    return
}

@(private)
dropdown_matches :: proc(text,part:string) -> bool {
    if len(part)>len(text) {return false}
    for i in 0..=len(text)-len(part) {
        if strings.equal_fold(text[i:][:len(part)],part) {return true}
    }
    return false
}

// The id `name` would have inside the scope of id.
id_derive :: proc(ctx:^Context,scope:Id,name:string,index:int=0) -> Id {
    id_push(ctx,scope)
    defer id_pop(ctx)
    return id(ctx,name,index)
}

// ---------------------------------------------------------------- panels and dialogs

Panel_Float :: struct {
    using layout:Layout, // direction is Column unless row is set
    row:bool,
    anchor,pivot:Anchor, // where on the surface, and which of its points goes there
    offset:[2]f32,
    layer:i16,           // LAYER_PANEL when 0
    safe:bool,           // placed inside the safe area
    popup:bool,          // the fill and the radius of a popup
    bare:bool,           // no background
    docked:bool,         // against an edge of the surface: its fill, square, without border or shadow
    corners:[4]f32,      // docked: of each corner, top left first clockwise; 0: square
    backdrop:bool,       // in layer 0, under every other panel, whatever layer says
    stroke:Color,        // the border; that of the theme when transparent
}

// A floating panel of the surface that takes the pointer.
@(deferred_in=panel_end)
panel :: proc(ctx:^Context,id:Id,p:Panel_Float) -> bool {
    th:=&ctx.theme
    layer:=p.layer if p.layer!=0 else LAYER_PANEL
    if p.backdrop {layer=0}
    b:=Box{id=id,layout=p.layout,float={to=.Safe if p.safe else .Surface,anchor=p.anchor,pivot=p.pivot,offset=p.offset,layer=layer},block=true}
    b.direction=.Row if p.row else .Column
    switch {
    case p.bare:
    case p.docked: b.fill,b.corners=th.panel,p.corners
    case:
        b.fill=th.popup if p.popup else th.panel;b.stroke=p.stroke if p.stroke[3]>0 else th.border
        b.radius=th.radius_popup if p.popup else th.radius_panel;b.shadow=true
    }
    box_begin(ctx,b)
    return true
}
@(private)
panel_end :: proc(ctx:^Context,id:Id,p:Panel_Float) {box_end(ctx,{id=id,float={to=.Surface}})}

Modal :: struct {
    width:f32,     // 400 when 0; never wider than the surface
    scroll:^f32,   // for dialogs taller than the surface
    padding:f32,   // 18 when 0; negative: none
    gap:f32,       // 12 when 0
    close:^bool,   // a dialog that can be dismissed: a cross in its corner and a press outside it set this
    own_cross:bool, // the content draws the dialog's cross in its header: no cross in the corner
    fill:Color,     // popup when transparent
}

// A dialog over a backdrop that takes every press: `if modal(ctx,id,{...}) {content}`.
@(deferred_in=modal_end)
modal :: proc(ctx:^Context,id:Id,m:Modal={}) -> bool {
    th:=&ctx.theme
    size:=surface_size(ctx)
    backdrop:=id_derive(ctx,id,"backdrop")
    content:=id_derive(ctx,id,"content")
    box_begin(ctx,{id=backdrop,width=fixed(size.x),height=fixed(size.y),float={to=.Surface,layer=LAYER_MODAL},fill=th.backdrop,block=true})
    box_end(ctx,{id=backdrop,float={to=.Surface}})
    w:=min(size.x-2*th.margin,m.width if m.width>0 else 400)
    offset:=f32(0)
    if m.scroll!=nil {
        view,found:=widget_rect(ctx,id)
        inner,_:=widget_rect(ctx,content)
        if ctx.wheel_target==id && ctx.input.wheel.y!=0 {m.scroll^-=ctx.input.wheel.y*th.wheel_step}
        if found {m.scroll^=clamp(m.scroll^,0,max(inner.h-view.h,0))}
        offset=m.scroll^
    }
    box_begin(ctx,{id=id,width=fixed(w),height=fit(0,size.y-2*th.margin),direction=.Column,clip_y=true,scroll={0,offset},
        float={to=.Surface,anchor=.Center,pivot=.Center,layer=LAYER_MODAL+1},fill=m.fill if m.fill[3]>0 else th.popup,stroke=th.border,radius=th.radius_panel,shadow=true,block=true})
    widget_add(ctx,id,{.Passive,.Scroll})
    if m.close!=nil {
        // A press outside the dialog closes it, unless a popup of the dialog takes it.
        if rect,found:=widget_rect(ctx,id);found && .Left in ctx.input.pressed && !ctx.press_used && ctx.popup.count==0 && !rect_contains(rect,ctx.pointer) {
            m.close^=true
            ctx.press_used=true
        }
        if !m.own_cross {
            corner:=id_derive(ctx,id,"corner")
            box_begin(ctx,{id=corner,width=FIT,height=FIT,float={to=.Parent,anchor=.Top_Right,pivot=.Top_Right,offset={-4,4},layer=LAYER_MODAL+2}})
            if button(ctx,id_derive(ctx,id,"close"),{icon=.Cross,icon_size=12,style=.Ghost,width=18,height=18,padding=-1,center=true}).clicked {m.close^=true}
            box_end(ctx,{id=corner,float={to=.Parent}})
        }
    }
    box_begin(ctx,{id=content,width=fixed(w),height=FIT,direction=.Column,padding=padding_all(m.padding if m.padding>0 else (0 if m.padding<0 else 18)),gap=m.gap if m.gap>0 else 12,track=true})
    ctx.modal_open=true;ctx.modal_layer=LAYER_MODAL
    return true
}
@(private)
modal_end :: proc(ctx:^Context,id:Id,m:Modal) {
    box_end(ctx,{id=id_derive(ctx,id,"content")})
    box_end(ctx,{id=id,clip_y=true,float={to=.Surface}})
}

// The bar across the top of the surface: put menus and tools inside.
@(deferred_in=menu_bar_end)
menu_bar :: proc(ctx:^Context,id:Id) -> bool {
    th:=&ctx.theme
    box_begin(ctx,{id=id,width=fixed(surface_size(ctx).x),height=fixed(th.bar_height),padding={10,0,10,0},gap=2,align_y=.Center,
        float={to=.Surface,layer=LAYER_BAR},fill=th.bar_top,fill2=th.bar_bottom,stroke=th.border,block=true})
    return true
}
@(private)
menu_bar_end :: proc(ctx:^Context,id:Id) {box_end(ctx,{id=id,float={to=.Surface}})}
