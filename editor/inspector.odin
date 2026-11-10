package editor

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:reflect"
import "core:strconv"
import "core:slice"
import "core:strings"
import "mirai:asset"
import "mirai:cook/author"
import "mirai:core"
import "mirai:editor/history"
import eaudio "mirai:engine/audio"
import evolume "mirai:engine/volume"
import erender "mirai:engine/render"
import input "mirai:engine/input"
import scene "mirai:engine/scene"
import "mirai:host"
import "mirai:std/base"
import mm "mirai:std/math"
import "mirai:std/serial"
import "mirai:ui"

// The panel at the right while something is selected: the name and the
// visibility of the active entity, its Transform and a section per
// component, with rows made from the fields of its type. Numbers are typed
// or scrubbed, colors open a picker, enums a list, references to entities
// and assets a button that is cleared, chosen, or takes a drop. A tag
// mirai:"..." on a field says hidden, readonly, color, angle (shown in
// degrees), text, unit=, min= and max=. With several entities selected the
// sections are those all of them have, and an edit goes to all of them.
// A drag or a typed value is one step.

INSPECTOR_FIELD_DEPTH :: 4   // nested structs shown
INSPECTOR_ARRAY_ROWS :: 16   // elements of an array shown
INSPECTOR_COMPONENT_BYTES :: 4096

@(storage)
Inspector :: struct {
    hierarchy_tree:bool,      // the Hierarchy card shows the line of the entity: its parents and what hangs from it
    hierarchy_scroll:[2]f32,
    defaults:[dynamic]Inspector_Default,
    defaults_key:[4]u64,
    scroll:[2]f32,
    folded:[dynamic]u64,      // sections not as they start, by the hash of their title
    name:[64]u8,
    name_length:int,
    rename:bool,
    search:[64]u8,            // what the cards are filtered by: their titles and the names of their fields
    search_length:int,
    euler_entity:core.Entity, // the angles last shown, so a typed 100 reads 100
    euler_rotation:mm.Quat,
    euler:[3]f32,
    gesture:u64,              // the field whose step is open
    gesture_frame:u64,        // the last frame its field was built
    picker:Color_Session,
    list:Choice_List,
    list_with:[dynamic]base.Asset_Id, // the prefabs the open list offers when its field names a component they must have (with=)
    geometry_choice:Geometry_Choice,
    post_process:Post_Process_Editor,
    add_filter:[64]u8,
    add_filter_length:int,
    add_scroll:f32,
    menu:Value_Menu,          // the Copy and Paste of a value, open on its right click
    held:Held_Write,          // what a popup chose for values a panel holds
    naming:u64,               // the key of the field whose value with a name is being renamed; 0: none
    naming_request:bool,
    value_name:[NAME_CAPACITY]u8,
    value_name_length:int,
}

// The color picker open for a field.
Color_Session :: struct {
    key:u64,       // of the field; 0: closed
    table:int,     // of the world info
    storage:int,   // a setting instead, the storage of the world info +1
    held:u64,      // a value a panel holds instead: the key of its values
    stepped:bool,  // those values are written as steps (Held_Values.write): the session of the picker is one
    offset:int,
    channels:int,  // 3 or 4: a fourth one is alpha and is kept
    alpha:f32,
    emission:bool, // a radiance: brighter than 1, with its intensity apart
    intensity:f64,
    state:ui.Color_Picker,
}

// The list of assets open for a field, or the components to add.
Choice_List :: struct {
    key:u64,
    table:int,
    storage:int,       // a setting instead, the storage of the world info +1
    held:u64,          // a value a panel holds instead: the key of its values
    offset:int,
    kinds:Asset_Kinds,
    geometry:bool,
    field:ui.Id,
    path:int,          // a text of this many bytes takes the path of the asset under the assets folder instead of its id
    with:bool,         // it offers only Inspector.list_with
    scroll:f32,
}

Geometry_Choice :: struct {
    field:ui.Id,
    shape:erender.Shape,
    mesh:base.Asset_Id,
}

// A component of the selection, or a setting of the project, as its rows read and write it.
Inspect :: struct {
    s:^Session,
    w:core.World_Ref,
    t:^core.Table_Info,
    index:int,             // of the table in the world info; for a setting, SETTING_INDEX and the storage
    table:^core.Raw_Table,
    entities:[]core.Entity, // the selected that have it, the active last
    storage:int,           // a setting: the storage of the world info +1
    held:u64,              // values a panel holds, written in place: the key of them
    write:Held_Writer,     // writes them instead, as steps (Held_Values.write)
    user:rawptr,           // of write
    changed:bool,          // a row wrote the values a panel holds
    panel:^Project_Panel,  // a row of a panel of the project: held takes what its popups chose, it writes the document and Restore keeps what it changes
    name:string,           // of the type
    type:typeid,
    value:[^]u8,           // of the active entity, the setting or the panel
    defaults:[^]u8,
    size:int,
    width:f32,             // of the section
    // The settings dialog shows a section of a setting per card, and of it
    // what its search finds: only the fields under the title section (empty:
    // those before the first title), and of them those whose name has needle;
    // advanced: those tagged advanced, which it draws apart under a fold.
    sections:bool,
    section:string,
    needle:string,
    advanced:bool,
    ruled:bool,            // a rule between the rows
}

SETTING_INDEX :: 1<<16
@(private) HELD_INDEX :: 1<<18

// Writes bytes at an offset of what the rows show: the component of the
// selected, a setting or the values of a panel.
inspect_write :: proc(c:^Inspect,offset:int,bytes:[]u8) {
    if c.held!=0 && c.panel==nil {
        if offset<0 || offset+len(bytes)>c.size {return}
        if c.write!=nil {c.write(c.s,c.user,offset,bytes)} else {mem.copy(&c.value[offset],raw_data(bytes),len(bytes))}
        c.changed=true
        return
    }
    if c.panel!=nil {panel_keep_row(c,offset,len(bytes))}
    if c.storage>0 {
        setting_write(c.s,c.storage-1,offset,bytes)
        return
    }
    field_write(c.s,c.t,c.entities,offset,bytes)
}

// Whether what the rows write is a step of the document, which a gesture keeps open.
@(private)
inspect_stepped :: proc(c:^Inspect) -> bool {return c.held==0 || c.panel!=nil || c.write!=nil}

@(private)
inspect_entity_set :: proc(c:^Inspect,offset:int,e:core.Entity) {
    value:=e
    inspect_write(c,offset,mem.ptr_to_bytes(&value))
}

inspector_section_open :: proc(ins:^Inspector,key:u64,folded:=false) -> bool {
    for changed in ins.folded {
        if changed==key {return folded}
    }
    return !folded
}

inspector_section_toggle :: proc(ins:^Inspector,key:u64) {
    for folded,i in ins.folded {
        if folded==key {
            unordered_remove(&ins.folded,i)
            return
        }
    }
    append(&ins.folded,key)
}

CARD_HEADER :: f32(26)    // height of the line with the title of a section
SECTION_INDENT :: f32(10) // of the rows of a section from the edge of its title
BAND_INSET :: f32(16)     // from the edge of the panel to the title of a band and to the end of its rows
ENUM_SEGMENTS :: 4        // the most names of an enum shown as segments
INSPECTOR_HEAD :: f32(40) // the line of the entity, over the scroll
INSPECTOR_VARIANT :: f32(18) // the line under it that names the base of a variant
HIERARCHY_TILE :: f32(25)

// A section of the inspector: a block a step lighter than the panel, with
// its title and, while it is open, the rows under it (card_body).
@(private,deferred_in=card_end)
card :: proc(s:^Session) -> bool {
    card_begin(s)
    return true
}
card_begin :: proc(s:^Session) {
    th:=&s.gui.ctx.theme
    ui.box_begin(s.gui.ctx,{width=ui.GROW,height=ui.FIT,direction=.Column,fill=th.card,radius=th.radius_popup})
}
card_end :: proc(s:^Session) {ui.box_end(s.gui.ctx,{})}

// The rows of an open section, under its title. The right padding holds the
// arrows that revert a field.
@(private,deferred_in=card_body_end)
card_body :: proc(s:^Session) -> bool {
    card_body_begin(s)
    return true
}
card_body_begin :: proc(s:^Session) {
    ctx:=s.gui.ctx
    ui.box_begin(ctx,{width=ui.GROW,height=ui.FIT,direction=.Column,padding={SECTION_INDENT,2,3,6},gap=3})
}
card_body_end :: proc(s:^Session) {ui.box_end(s.gui.ctx,{})}

// The band at the top of a card: a click on it folds what follows, and the
// triangle at its right end says whether it is open. on: a checkbox before
// the title, the component turned on; menu: the band took a right click.
@(private)
// A button at the right of the title of a card; pressed takes its index.
Section_Button :: struct {
    icon:ui.Icon,
    on,disabled:bool,
}

section :: proc(s:^Session,title:string,folded:=false,icon:ui.Icon=.None,description:string="",menu:^bool=nil,on:^bool=nil,buttons:[]Section_Button=nil,pressed:^int=nil) -> (open:bool) {
    ins:=s.inspector
    ctx:=s.gui.ctx
    th:=&ctx.theme
    key:=base.name_hash(title)
    // What the search shows stays open.
    searching:=inspector_needle(ins)!=""
    open=inspector_section_open(ins,key,folded) || searching
    id:=ui.id(ctx,"section",int(key&0x7fffffff))
    it:=section_band(s,id,title,open,icon,on,buttons,pressed)
    inspector_description(s,id,description,it.hot)
    if menu!=nil {menu^=it.right}
    if it.clicked && !searching {
        inspector_section_toggle(ins,key)
        open=!open
    }
    return
}

SEARCH_BAR :: f32(40) // the search of Details, under the line of the entity

@(private)
inspector_needle :: proc(ins:^Inspector) -> string {return string(ins.search[:ins.search_length])}

// Whether a field of a struct, outside those it holds, has needle in its name.
@(private)
fields_match :: proc(info:^runtime.Type_Info,needle:string) -> bool {
    v,is_struct:=runtime.type_info_base(info).variant.(runtime.Type_Info_Struct)
    if !is_struct {return false}
    for i in 0..<int(v.field_count) {
        tag:=reflect.Struct_Tag(v.tags[i])
        if _,hidden:=core.field_option(tag,"hidden");hidden {continue}
        if _,transient:=core.field_option(tag,"transient");transient {continue}
        if v.usings[i] {
            if fields_match(v.types[i],needle) {return true}
            continue
        }
        label:=readable(v.names[i])
        if custom,found:=core.field_option(tag,"label");found && custom!="" {label=custom}
        if base.contains_fold(label,needle) {return true}
    }
    return false
}

// The shadow a bar casts on the list that scrolls under it, while it does:
// at the bottom of the box being built.
scroll_shadow :: proc(s:^Session,shown:bool) {
    if !shown {return}
    if ui.box(s.gui.ctx,{width=ui.GROW,height=ui.fixed(8),float={to=.Parent,anchor=.Bottom_Left,pivot=.Top_Left},fill={0,0,0,70},fill2={0,0,0,0}}) {}
}

// The band of a section whose open state its caller keeps.
section_band :: proc(s:^Session,id:ui.Id,title:string,open:bool,icon:ui.Icon=.None,on:^bool=nil,buttons:[]Section_Button=nil,pressed:^int=nil,banded:=false) -> ui.Interaction {
    ctx:=s.gui.ctx
    th:=&ctx.theme
    it:=ui.interact(ctx,id,{.Focusable})
    if pressed!=nil {pressed^=-1}
    // In a block the title sits on it; a section on the panel heads it with a band.
    if banded {band_begin(ctx,id,it.hot)} else {ui.box_begin(ctx,{id=id,width=ui.GROW,height=ui.fixed(CARD_HEADER),padding={9,0,7,0},gap=7,align_y=.Center,fill=ui.color_alpha({255,255,255,255},it.hot?10:0),radius=4})}
    {
        if on!=nil {ui.checkbox(ctx,ui.id_derive(ctx,id,"on"),on)}
        if icon!=.None {ui.icon(ctx,icon,th.text_muted,14)}
        ui.label(ctx,title,th.font,th.text,0,font=ui.FONT_SEMIBOLD)
        for button,i in buttons {
            if ui.button(ctx,ui.id_derive(ctx,id,"button",i),{icon=button.icon,icon_color=th.text_muted,icon_size=13,style=.Ghost,width=22,height=22,active=button.on,disabled=button.disabled}).clicked && pressed!=nil {pressed^=i}
        }
        ui.icon(ctx,open?.Chevron_Down:.Chevron_Right,th.text_muted,13)
    }
    if banded {band_end(ctx)} else {ui.box_end(ctx,{})}
    if pressed!=nil && pressed^>=0 {it.clicked=false}
    return it
}

// A band that heads a section on a panel, from one edge to the other between
// two rules; id takes the pointer. What it holds goes before band_end.
band_begin :: proc(ctx:^ui.Context,id:ui.Id,hot:=false) {
    th:=&ctx.theme
    ui.box_begin(ctx,{width=ui.GROW,height=ui.fixed(CARD_HEADER),direction=.Column})
    if ui.box(ctx,{width=ui.GROW,height=ui.fixed(1),fill=th.border}) {}
    ui.box_begin(ctx,{id=id,width=ui.GROW,height=ui.GROW,padding={BAND_INSET,0,BAND_INSET,0},gap=7,align_y=.Center,fill=th.field_hover if hot else th.band})
}
band_end :: proc(ctx:^ui.Context) {
    ui.box_end(ctx,{})
    if ui.box(ctx,{width=ui.GROW,height=ui.fixed(1),fill=ctx.theme.border}) {}
    ui.box_end(ctx,{})
}

@(private)
inspector_description :: proc(s:^Session,id:ui.Id,text:string,hot:bool) {
    if hot && text!="" {ui.tooltip(s.gui.ctx,text)}
}

// The description of the field of a row, while the pointer is on its name,
// at the start of the row, and no popup is open. row: the id of its box,
// which keeps its rectangle (track).
row_description :: proc(s:^Session,row:ui.Id,text:string) {
    if text=="" {return}
    ctx:=s.gui.ctx
    area,shown:=ui.widget_rect(ctx,row)
    on:=shown && ctx.popup.count==0 && ui.rect_contains(area,ctx.pointer) && ctx.pointer.x<area.x+ctx.theme.label_width
    inspector_description(s,row,text,on)
}

// A field that stopped being built while its gesture was open ends it: at the end of every frame.
inspector_sweep :: proc(s:^Session) {
    ins:=s.inspector
    if ins.gesture!=0 && ins.gesture_frame!=s.frame {gesture_end(s,ins.gesture)}
}

// Opens the step of a field when its gesture begins and ends it when it ends:
// in the history of the asset document in front, or else in that of the scene.
@(private)
gesture_begin :: proc(s:^Session,key:u64,label:string) -> bool {
    ins:=s.inspector
    if ins.gesture!=0 && ins.gesture!=key {
        material_pending_write(s,ins.gesture)
        gesture_history_end(s)
    }
    if h:=asset_history_front(s);h!=nil {
        asset_history_begin(h,label)
    } else if _,ready:=edit_open(s,label);!ready {return false}
    ins.gesture,ins.gesture_frame=key,s.frame
    return true
}
gesture_end :: proc(s:^Session,key:u64) {
    ins:=s.inspector
    if ins.gesture!=key {return}
    ins.gesture=0
    material_pending_write(s,key)
    gesture_history_end(s)
}
@(private)
gesture_history_end :: proc(s:^Session) {
    if h:=asset_history_front(s);h!=nil {asset_history_end(h)} else {history.edits_end(s.edits)}
}
gesture_follow :: proc(s:^Session,key:u64,r:ui.Number_Result,label:string) {
    if r.began {gesture_begin(s,key,label)}
    if s.inspector.gesture==key {s.inspector.gesture_frame=s.frame}
}

@(private)
inspector_build :: proc(s:^Session,w:core.World_Ref,width,max_height:f32) {
    ins:=s.inspector
    g:=s.gui
    ctx:=g.ctx
    preview:=s.edits.preview
    if preview {ui.disabled_begin(ctx)}
    defer if preview {ui.disabled_end(ctx)}
    th:=&ctx.theme
    if git_review_shown(s) {
        git_review_build(s,w,width,max_height)
        return
    }
    active:=history.selection_active(s.selection)
    if !entity_alive(w,active) {
        if task,id,shown:=ai_review_shown(s);shown {
            if ui.box(ctx,{width=ui.GROW,height=ui.FIT,direction=.Column,padding=ui.padding_all(PANEL_PADDING)}) {ai_review_deleted_details(s,w,task,id,width-2*PANEL_PADDING,max_height-2*PANEL_PADDING)}
        }
        return
    }
    single:=len(s.selection.entities)==1
    // An entity a turn changed shows as keeping it leaves it, under the strip of its review.
    review:=single?ai_review_details_task(s,w,active):nil
    strip:=f32(0)
    if review!=nil {
        ai_review_strip(s,w,review,active)
        strip=ai_review_strip_height(th)
    }
    // One line for every entity, over the scroll: a prefab only adds buttons to it.
    if ui.box(ctx,{width=ui.GROW,height=ui.fixed(INSPECTOR_HEAD),padding={11,0,7,0},gap=4,align_y=.Center}) {
        if !single {
            ui.label(ctx,fmt.tprintf("%d selected",len(s.selection.entities)),ctx.theme.font_heading,th.text,0,font=ui.FONT_SEMIBOLD)
            if s.mode==.Edit {action_button(s,.Group,{icon=action_icon(.Group),tip=fmt.tprintf("Group selection (%s)",shortcut_text(ACTION_SHORTCUTS[.Group])),icon_size=14,icon_color=th.text_muted,style=.Ghost,width=25,height=ctx.theme.control},2)}
            if s.mode==.Edit && s.app.assets!=nil {action_button(s,.Prefab_Create,{icon=.Prefab,tip="Create prefab",icon_size=14,icon_color=th.text_muted,style=.Ghost,width=25,height=ctx.theme.control},1)}
        }
        if single && identity_row(s,w,active) {return}
    }
    variant:=single && s.mode==.Edit?inspector_variant_name(s,w,active):""
    if variant!="" {
        if ui.box(ctx,{width=ui.GROW,height=ui.fixed(INSPECTOR_VARIANT),padding={11,0,7,0},align_y=.Center}) {
            ui.label(ctx,fmt.tprintf("Variant of %s",variant),th.font_small,PREFAB_TEXT,0)
        }
    }
    origin:=f32(0)
    if single && s.mode==.Edit {
        id_text:[16]u8
        if id:=api_entity_id(w,active);id!=0 {origin=ai_provenance_row(s,.Entity,base.entity_id_format(id,id_text[:]))}
    }
    if ui.box(ctx,{width=ui.GROW,height=ui.fixed(SEARCH_BAR),padding={8,0,8,6},align_y=.Center}) {
        if search_field(s,ui.id(ctx,"inspector_search"),ins.search[:],&ins.search_length,"Search details") {ins.scroll=0}
        scroll_shadow(s,ins.scroll.y>0)
    }
    // An entity of a section is edited in its own scene: here its values only show.
    sectioned:=!preview && section_locked(s,w,active)
    if sectioned {ui.disabled_begin(ctx)}
    defer if sectioned {ui.disabled_end(ctx)}
    if ui.scroll_area(ctx,ui.id(ctx,"inspector_scroll"),&ins.scroll,{height=ui.FIT,max_height=max(max_height-strip-INSPECTOR_HEAD-(variant!=""?INSPECTOR_VARIANT:0)-origin-SEARCH_BAR,40),padding={8,7,8,8},gap=7,fade=th.panel}) {
        needle:=inspector_needle(ins)
        if single && review==nil {ai_review_entity_bar(s,w,active,width-16)}
        inner:=width-16
        if needle=="" || base.contains_fold("Transform Position Rotation Scale",needle) {
            card(s)
            _,transform:=core.world_table(w,core.Transform)
            description:=transform.description if transform!=nil else ""
            menu:=false
            if section(s,"Transform",icon=.Move,description=description,menu=&menu) {
                if card_body(s) {transform_rows(s,w)}
            }
            if menu {value_menu_open(s,{kind=.Transform},"Transform")}
        }
        if single && (needle=="" || base.contains_fold("Hierarchy Parent Children",needle)) {hierarchy_section(s,w,active,inner)}
        for pass in 0..<2 {
            for &t,index in w.info.tables {
                if t.place!=.World || !inspector_visible(s,&t) || inspector_primary(&t)!=(pass==0) {continue}
                table:=core.world_table_at(w,&t)
                if core.raw_find(table,t.info,active)==nil {continue}
                entities:=make([dynamic]core.Entity,context.temp_allocator)
                all:=true
                for e in s.selection.entities {
                    if !entity_alive(w,e) {continue}
                    if core.raw_find(table,t.info,e)==nil {all=false;continue}
                    if e!=active {append(&entities,e)}
                }
                if !all {continue}
                append(&entities,active)
                c:=Inspect{s=s,w=w,t=&t,index=index,table=table,entities=entities[:],name=t.name,type=t.type,value=cast([^]u8)core.raw_find(table,t.info,active),size=t.info.size}
                // A card whose title the search finds shows whole; another, the fields it finds.
                if needle!="" && !base.contains_fold(readable(t.name),needle) {
                    if !fields_match(t.info,needle) {continue}
                    c.needle=needle
                }
                component_section(&c,inner)
            }
        }
        if needle!="" {return}
        add:=ui.id(ctx,"add_component")
        added:ui.Interaction
        if ui.box(ctx,{width=ui.GROW,height=ui.fixed(25),stroke=ui.color_alpha({255,255,255,255},51),radius=4}) {
            added=ui.button(ctx,add,{label="Add component",icon=.Plus,icon_size=12,icon_color=th.text_label,style=.Ghost,width=-1,height=ctx.theme.control,size=th.font_small,center=true,active=ins.list.key==ADD_COMPONENT_KEY})
        }
        if added.right {value_menu_open(s,{kind=.Components},"Components")}
        if added.clicked && ins.list.key!=ADD_COMPONENT_KEY {
            anchor,_:=ui.widget_rect(ctx,add)
            list_open(s,{key=ADD_COMPONENT_KEY},anchor)
        }
        ui.spacer(ctx,-1,2)
    }
}

// The popups of the inspector, built outside its scroll area: a popup built
// inside a container that clips is clipped by it.
@(private)
inspector_popups :: proc(s:^Session,w:core.World_Ref) {
    picker_build(s,w)
    list_build(s,w)
    material_popups(s,w)
    value_menu_build(s,w)
    inspector_popups_extension(s,w)
    post_process_picker_build(s)
}

// The components that are sections: what a scene saves, besides the identity
// and the place of an entity, and what the section of another shows.
inspector_listed :: proc(s:^Session,t:^core.Table_Info) -> bool {
    return !inspector_within(s,t) && author.component_listed(t)
}

@(private)
inspector_visible :: proc(s:^Session,t:^core.Table_Info) -> bool {
    return t.type!=erender.Tint && inspector_listed(s,t)
}

// The sections shown first: what an entity is.
@(private)
inspector_primary :: proc(t:^core.Table_Info) -> bool {
    switch t.type {
    case erender.Mesh_Renderer,erender.Sun,erender.Point_Light,erender.Spot_Light,erender.Rect_Light: return true
    }
    return t.name=="Spawn_Point"
}

@(private)
identity_row :: proc(s:^Session,w:core.World_Ref,e:core.Entity) -> (changed:bool) {
    ins:=s.inspector
    ctx:=s.gui.ctx
    th:=&ctx.theme
    link,linked:=prefab_link_of(w,e)
    {
        enabled:=!entity_has(w,e,core.Disabled)
        if ui.checkbox(ctx,ui.id(ctx,"enabled"),&enabled) {entity_enabled_set(s,e,enabled)}
        ui.spacer(ctx,4,1)
        {
            // The icon of the entity in the color of what holds it: a prefab instance, a section.
            icon,color:=entity_icon(s,w,e)
            holder:=container_kind(w,e)
            if holder==.None {holder=container_kind(w,container_of(w,e))}
            if holder!=.None {color,_=container_color(s,holder)}
            // Inside a prefab instance or a section, it selects the root of what holds it;
            // on the root of an instance, a double click opens its prefab.
            if up:=container_of(w,e);up!=core.NONE {
                if ui.button(ctx,ui.id(ctx,"holder_root"),{icon=icon,icon_color=color,icon_size=15,style=.Ghost,width=22,height=ctx.theme.control}).clicked {history.selection_set(s.selection,{up})}
            } else if linked && link.root && s.mode==.Edit {
                if ui.button(ctx,ui.id(ctx,"prefab_open"),{icon=icon,icon_color=color,icon_size=15,style=.Ghost,width=22,height=ctx.theme.control}).double {
                    if _,path,found:=prefab_file(s,link.asset);found {
                        file_open_path(s,path)
                        changed=true
                    }
                }
            } else {ui.icon(ctx,icon,color,15)}
        }
        field:=ui.id(ctx,"name")
        if ins.rename {ui.edit_request(ctx,field);ins.rename=false}
        if ctx.edit.id!=field {ins.name_length=copy(ins.name[:len(ins.name)-1],entity_name(w,e))}
        named:=ui.text_field(ctx,field,ins.name[:len(ins.name)-1],&ins.name_length,{height=ctx.theme.control,size=ctx.theme.font_heading,inline=true,font=ui.FONT_SEMIBOLD,color=linked && link.root?PREFAB_TEXT:entity_has(w,e,scene.Scene_Reference)?SECTION_TEXT:th.text})
        if named.changed && !entity_rename(s,e,string(ins.name[:ins.name_length])) {notify(s,"An entity needs a name")}
        if s.mode==.Edit && s.app.assets!=nil && !linked && len(s.selection.entities)==1 {
            changed|=action_button(s,.Prefab_Create,{icon=.Prefab,tip="Create prefab",icon_size=14,icon_color=th.text_muted,style=.Ghost,width=25,height=ctx.theme.control},1)
        }
        if s.mode==.Edit && entity_has(w,e,scene.Scene_Reference) {
            editing:=section_editing(s)==e
            if ui.button(ctx,ui.id(ctx,"section_edit"),{icon=.Edit,tip=editing?"Stop editing the section":"Edit the section here, in its world",icon_size=15,icon_color=editing?SECTION_COLOR:th.text_muted,style=.Ghost,active=editing,width=22,height=ctx.theme.control}).clicked {section_edit_set(s,editing?core.NONE:e)}
            previewed:=section_previewed(w,e)
            if ui.button(ctx,ui.id(ctx,"section_preview"),{icon=.Sun,tip=previewed?"Back to the environment of the scene":"Preview the environment of this section",icon_size=15,icon_color=previewed?SECTION_COLOR:th.text_muted,style=.Ghost,active=previewed,width=22,height=ctx.theme.control}).clicked {section_preview_toggle(s,w,e)}
        }
        if linked && s.mode==.Edit {
            if link.root {
                variant:=ui.id(ctx,"variant_save")
                // A variant of an instance that changes nothing would be its prefab again.
                unchanged:=prefab_action_disabled(s,.Prefab_Apply)
                if ui.button(ctx,variant,{icon=ui.icon_user(u8(User_Icon.Variant)),tip="Save variant",icon_size=15,style=.Ghost,width=22,height=ctx.theme.control,disabled=unchanged,active=ui.popup_is_open(ctx,variant_prompt_popup(s.gui)) && s.gui.variant.instance==e}).clicked {
                    variant_prompt_open(s,variant,link.asset,e)
                }
                changed|=action_button(s,.Prefab_Apply,{icon=.Save_Prefab,tip="Apply changes",icon_size=15,style=.Ghost,width=22,height=ctx.theme.control},1)
                if prefab_variant_of(s,w,link)!={} {changed|=action_button(s,.Prefab_Apply_Base,{icon=ui.icon_user(u8(User_Icon.Up)),tip="Apply to base",icon_size=15,style=.Ghost,width=22,height=ctx.theme.control},1)}
                changed|=action_button(s,.Prefab_Unlink,{icon=ui.icon_user(u8(User_Icon.Unlink)),tip="Unlink",icon_size=15,style=.Ghost,width=22,height=ctx.theme.control},1)
                changed|=action_button(s,.Prefab_Revert,{icon=.Revert,tip="Revert all",icon_size=15,style=.Ghost,width=22,height=ctx.theme.control},1)
            } else {
                changed|=action_button(s,.Prefab_Revert,{icon=.Revert,tip="Revert entity changes",icon_size=15,style=.Ghost,width=22,height=ctx.theme.control},1)
            }
            if ui.box(ctx,{width=ui.fixed(1),height=ui.fixed(16),fill=th.border}) {}
        }
        hidden:=entity_has(w,e,erender.Hidden)
        if ui.button(ctx,ui.id(ctx,"visible"),{icon=hidden?.Eye_Off:.Eye,icon_size=14,icon_color=hidden?th.accent:th.text_muted,style=.Ghost,width=25,height=ctx.theme.control}).clicked {entity_hidden_set(s,e,!hidden)}
    }
    return
}

// The name of the base when the entity is the root of a variant; "" otherwise.
@(private)
inspector_variant_name :: proc(s:^Session,w:core.World_Ref,e:core.Entity) -> string {
    link,linked:=prefab_link_of(w,e)
    if !linked {return ""}
    variant_base:=prefab_variant_of(s,w,link)
    if variant_base=={} {return ""}
    file,_,found:=prefab_file(s,variant_base)
    return found?asset_name(file.path):"a missing prefab"
}

@(private)
hierarchy_square :: proc(s:^Session,w:core.World_Ref,e:core.Entity,index:int,editable:bool) -> (clicked,unlink:bool) {
    ctx:=s.gui.ctx
    th:=&ctx.theme
    id:=ui.id(ctx,"hierarchy_square",index)
    cross:=ui.id(ctx,"hierarchy_unlink",index)
    it:=ui.interact(ctx,id,{.Focusable})
    hot:=it.hot || ctx.hot==cross
    if ui.box(ctx,{id=id,width=ui.fixed(HIERARCHY_TILE),height=ui.fixed(HIERARCHY_TILE),fill=th.well,stroke=hot?th.accent:th.well_stroke,radius=4,align_x=.Center,align_y=.Center}) {
        if preview:=preview_entity(s,w,e);preview.kind!=.Solid {
            if ui.box(ctx,{width=ui.fixed(HIERARCHY_TILE-4),height=ui.fixed(HIERARCHY_TILE-4),image=preview}) {}
        } else {
            icon,color:=entity_icon(s,w,e)
            ui.icon(ctx,icon,color,15)
        }
        if hot {
            if ui.box(ctx,{float={to=.Parent,anchor=.Top_Right,pivot=.Top_Right}}) {
                unlink=ui.button(ctx,cross,{icon=.Cross,icon_color=ctx.hot==cross?th.danger_soft:th.text,style=.Ghost,width=14,height=14,icon_size=12,disabled=!editable}).clicked
            }
        }
    }
    return it.clicked,editable && (unlink || it.right)
}

@(private)
hierarchy_section :: proc(s:^Session,w:core.World_Ref,e:core.Entity,width:f32) {
    ctx:=s.gui.ctx
    th:=&ctx.theme
    card(s)
    ins:=s.inspector
    buttons:=[1]Section_Button{{icon=ui.icon_user(u8(User_Icon.List)),on=ins.hierarchy_tree}}
    pressed:int
    open:=section(s,"Hierarchy",icon=ui.icon_user(u8(User_Icon.Tree)),buttons=buttons[:],pressed=&pressed)
    if pressed==0 {
        ins.hierarchy_tree=!ins.hierarchy_tree
        if !open {inspector_section_toggle(ins,base.name_hash("Hierarchy"))}
    }
    if !open {return}
    card_body(s)
    if ins.hierarchy_tree {
        hierarchy_tree(s,w,e)
        return
    }
    editable:=!prefab_member_locked(s,w,e)
    plus:=ui.Button{icon=.Plus,icon_size=12,icon_color=th.text_label,style=.Well,width=HIERARCHY_TILE,height=HIERARCHY_TILE,disabled=!editable}
    row:=ui.Box{width=ui.GROW,height=ui.fixed(HIERARCHY_TILE),gap=5,align_y=.Center}
    selected,release:=core.NONE,core.NONE
    if ui.box(ctx,row) {
        ui.label(ctx,"Parent",th.font_small,th.text_label,th.label_width)
        if parent:=entity_parent(w,e);parent!=core.NONE {
            clicked,unlink:=hierarchy_square(s,w,parent,0,editable)
            if clicked {selected=parent}
            if unlink {release=e}
        } else if ui.button(ctx,ui.id(ctx,"parent_pick"),plus).clicked {
            s.gui.placement={}
            s.viewport.pick={active=true,kind=.Parent,owner=e}
        }
    }
    children:=hierarchy_children(w,e)
    count:=min(len(children),32)
    columns:=max(int((width-12-th.label_width)/(HIERARCHY_TILE+5)),1)
    plus.disabled=false
    for start:=0;start<count+1;start+=columns {
        if ui.box(ctx,row) {
            if start==0 {ui.label(ctx,"Children",th.font_small,th.text_label,th.label_width)} else {ui.spacer(ctx,th.label_width,1)}
            for cell in start..<min(start+columns,count+1) {
                if cell==count {
                    if ui.button(ctx,ui.id(ctx,"child_pick"),plus).clicked {
                        s.gui.placement={}
                        s.viewport.pick={active=true,kind=.Children,owner=e}
                    }
                    continue
                }
                child:=children[cell]
                clicked,unlink:=hierarchy_square(s,w,child,cell+1,!prefab_member_locked(s,w,child))
                if clicked {selected=child}
                if unlink {release=child}
            }
        }
    }
    if len(children)>count {ui.label(ctx,fmt.tprintf("and %d more",len(children)-count),th.font_label,th.text_faint)}
    if release!=core.NONE {
        if !entity_reparent(s,release,core.NONE) {notify(s,"The entity could not leave its parent")}
    } else if selected!=core.NONE {history.selection_set(s.selection,{selected})}
}

HIERARCHY_TREE_HEIGHT :: f32(132)

// The line of e: its parents from the farthest, e, and what hangs from it,
// with scroll: its rows select. What is not its parent or under it is not there.
@(private)
hierarchy_tree :: proc(s:^Session,w:core.World_Ref,e:core.Entity) {
    ctx:=s.gui.ctx
    th:=&ctx.theme
    ins:=s.inspector
    Tree_Row :: struct {entity:core.Entity,depth:int}
    rows:=make([dynamic]Tree_Row,context.temp_allocator)
    walk :: proc(rows:^[dynamic]Tree_Row,w:core.World_Ref,e:core.Entity,depth:int) {
        if len(rows)>=1024 {return}
        append(rows,Tree_Row{e,depth})
        for child in hierarchy_children(w,e) {walk(rows,w,child,depth+1)}
    }
    parents:=make([dynamic]core.Entity,context.temp_allocator)
    for at:=entity_parent(w,e);at!=core.NONE && len(parents)<64;at=entity_parent(w,at) {append(&parents,at)}
    #reverse for parent,depth in parents {append(&rows,Tree_Row{parent,len(parents)-1-depth})}
    walk(&rows,w,e,len(parents))
    picked:=core.NONE
    if ui.scroll_area(ctx,ui.id(ctx,"hierarchy_tree"),&ins.hierarchy_scroll,{height=ui.FIT,max_height=HIERARCHY_TREE_HEIGHT}) {
        for row,i in rows {
            icon,color:=entity_icon(s,w,row.entity)
            kind:=container_kind(w,row.entity)
            text:ui.Color
            if kind!=.None {color,text=container_color(s,kind)}
            if ui.row(ctx,ui.id(ctx,"hierarchy_tree_row",i+1),{label=entity_label(w,row.entity),icon=icon,icon_color=color,icon_size=13,text_color=text,font=kind!=.None?ui.FONT_SEMIBOLD:0,selected=row.entity==e,height=22,depth=row.depth}).clicked {picked=row.entity}
        }
    }
    if picked!=core.NONE {history.selection_set(s.selection,{picked})}
}

@(private)
hierarchy_children :: proc(w:core.World_Ref,e:core.Entity) -> []core.Entity {
    children:=entity_children(w,e)
    count:=0
    for child in children {
        if entity_author(w,child)!=child {continue}
        children[count]=child;count+=1
    }
    return children[:count]
}

@(private)
Transform_Field :: enum u8 {Position,Rotation,Scale}

@(private)
transform_rows :: proc(s:^Session,w:core.World_Ref) {
    ins:=s.inspector
    ctx:=s.gui.ctx
    active:=history.selection_active(s.selection)
    local:=entity_local(w,active)
    // The angles shown follow those typed or shown before for the same rotation.
    angles:=mm.quat_to_euler(local.rotation)
    if ins.euler_entity==active {
        if ins.euler_rotation==local.rotation {angles=ins.euler} else {angles=mm.euler_closest(angles,ins.euler)}
    }
    ins.euler_entity,ins.euler_rotation,ins.euler=active,local.rotation,angles
    shown:=[Transform_Field][3]f32{.Position=local.position,.Rotation=angles*mm.DEG_PER_RAD,.Scale=local.scale}
    mixed:[Transform_Field][3]bool
    for e in s.selection.entities {
        if e==active || !entity_alive(w,e) {continue}
        other:=entity_local(w,e)
        other_angles:=mm.euler_closest(mm.quat_to_euler(other.rotation),angles)*mm.DEG_PER_RAD
        values:=[Transform_Field][3]f32{.Position=other.position,.Rotation=other_angles,.Scale=other.scale}
        for field in Transform_Field {
            for axis in 0..<3 {
                if abs(values[field][axis]-shown[field][axis])>1e-4 {mixed[field][axis]=true}
            }
        }
    }
    labels:=[Transform_Field]string{.Position="Position",.Rotation="Rotation",.Scale="Scale"}
    decimals:=[Transform_Field]int{.Position=3,.Rotation=1,.Scale=3}
    speeds:=[Transform_Field]f64{.Position=0.02,.Rotation=0.5,.Scale=0.01}
    c:=inspect_component(s,w,core.Transform,s.selection.entities[:])
    offsets:=[Transform_Field]int{.Position=int(offset_of(core.Transform,position)),.Rotation=int(offset_of(core.Transform,rotation)),.Scale=int(offset_of(core.Transform,scale))}
    for field in Transform_Field {
        row:=ui.id(ctx,"transform_row",int(field)+1)
        // The row takes the right click that its fields leave.
        if ui.box(ctx,{id=row,width=ui.GROW,height=ui.FIT}) {
            value_menu_row(s,row,{kind=.Transform_Field,transform=field},labels[field])
            if ui.property(ctx,labels[field]) {
                values:=[3]f64{f64(shown[field].x),f64(shown[field].y),f64(shown[field].z)}
                id:=ui.id(ctx,"transform",int(field)+1)
                r,axis:=ui.vector_field(ctx,id,values[:],{number={decimals=decimals[field],speed=speeds[field],unit=field==.Rotation?"°":""},mixed_axes={mixed[field][0],mixed[field][1],mixed[field][2],false}})
                field_reset_button(&c,offsets[field],field==.Rotation?16:12)
                if axis<0 {continue}
                key:=u64(id)<<8|u64(axis)
                gesture_follow(s,key,r,labels[field])
                if r.changed {
                    value:=f32(values[axis])
                    for e in s.selection.entities {
                        if !entity_alive(w,e) {continue}
                        t:=entity_local(w,e)
                        switch field {
                        case .Position: t.position[axis]=value
                        case .Scale:    t.scale[axis]=scale_limit(value)
                        case .Rotation:
                            own:=mm.euler_closest(mm.quat_to_euler(t.rotation),angles)
                            own[axis]=value*mm.RAD_PER_DEG
                            if e==active {ins.euler=own}
                            t.rotation=mm.quat_from_euler(own)
                            if e==active {ins.euler_rotation=t.rotation}
                        }
                        transform_set(s,e,t)
                    }
                }
                if r.ended {gesture_end(s,key)}
            }
        }
    }
}

@(private)
component_icon :: proc(s:^Session,t:^core.Table_Info) -> ui.Icon {
    if card,found:=card_of_table(s,t);found {return card.icon}
    switch t.type {
    case erender.Mesh_Renderer: return .Mesh
    case erender.Point_Light: return .Light
    case erender.Spot_Light: return .Spot
    case erender.Sun: return .Sun
    case erender.Rect_Light: return .Grid
    case erender.Camera: return ui.icon_user(u8(User_Icon.Camera))
    case eaudio.Audio_Source: return .Sound
    case eaudio.Audio_Reverb: return .Collider
    case evolume.Volume: return .Collider
    case eaudio.Audio_Occlusion: return .Layers
    }
    switch t.name {
    case "Rigid_Body","Collider": return .Cube
    case "Spawn_Point": return .Spawn
    case "Animation","Pose_Source": return .Rotate
    case "Keyframe_Path": return .Play
    case "Painted": return .Edit
    case "Terrain": return ui.icon_user(u8(User_Icon.Terrain))
    }
    return ui.icon_user(u8(User_Icon.Component))
}

@(private)
component_section :: proc(c:^Inspect,width:f32) {
    c.width=width-12
    s:=c.s
    ctx:=s.gui.ctx
    card(s)
    // Without entities its value is that of an entity an agent deleted: read only.
    live:=len(c.entities)>0
    // What the engine and the plugins give an entity folds, so that what the game gives it stands out.
    folded:=!c.t.game && c.t.library!="core" && !inspector_primary(c.t)
    if live {
        if _,pending:=ai_review_component(s,s.ai,c.w,c.t,c.entities[len(c.entities)-1]);pending {folded=false}
    }
    menu:=false
    turned_off:=false
    if live {_,turned_off,_=core.raw_state(c.table,c.entities[len(c.entities)-1])}
    on:=!turned_off
    open:=section(s,readable(c.t.name),folded,component_icon(s,c.t),c.t.description,live?&menu:nil,live && !c.table.base?&on:nil)
    if on==turned_off {
        for e in c.entities {component_turn(s,e,c.t,!on)}
    }
    if menu && c.storage==0 {value_menu_open(s,{kind=.Component,table=c.index},readable(c.t.name))}
    if !open || c.size==0 {return}
    card_body(s)
    ui.id_push(ctx,ui.id(ctx,c.t.name))
    defer ui.id_pop(ctx)
    if live && inspector_extension(c) {return}
    if c.size>INSPECTOR_COMPONENT_BYTES {return}
    switch c.t.type {
    case erender.Mesh_Renderer: geometry_row(c);skeleton_row(c);material_rows(c)
    case erender.Camera:
        if live && len(c.entities)==1 {camera_preview_button(c,c.entities[0])}
        fields_rows(c,c.t.info,0,0,"")
    case: fields_rows(c,c.t.info,0,0,"")
    }
}

@(private)
geometry_row :: proc(c:^Inspect) {
    s:=c.s
    mesh:=(cast(^erender.Mesh_Renderer)c.value)^
    mixed:=false
    for e in c.entities {
        other,_:=entity_get(c.w,e,erender.Mesh_Renderer)
        if other.mesh!=mesh.mesh || mesh.mesh=={} && other.shape!=mesh.shape {mixed=true;break}
    }
    if ui.box(s.gui.ctx,{width=ui.GROW,height=ui.FIT,gap=4,align_y=.Center}) {
        ui.label(s.gui.ctx,"Mesh",s.gui.ctx.theme.font_small,s.gui.ctx.theme.text_label,s.gui.ctx.theme.label_width)
        if geometry_choice(s,ui.id(s.gui.ctx,"geometry"),&mesh,mixed) {geometry_set(s,c.t,c.entities,mesh.shape,mesh.mesh)}
        field_reset_button(c,0,int(offset_of(erender.Mesh_Renderer,materials)))
    }
}

// The geometry a mesh renderer shows, chosen as Details chooses it: the
// thumbnail of what it is, the list of shapes and meshes and the button that
// finds the mesh in the content browser. It goes in a row after its label.
geometry_choice :: proc(s:^Session,id:ui.Id,mesh:^erender.Mesh_Renderer,mixed:=false) -> (changed:bool) {
    ctx:=s.gui.ctx
    // The thumbnail of a shape of the engine is its preview, or its icon until it has one.
    quad:ui.Quad
    icon:ui.Icon=.Mesh
    if !mixed {
        icons:=SHAPE_ICONS
        quad=preview_geometry(s,mesh.shape,mesh.mesh,MATERIAL_ROW)
        icon=.None if mesh.mesh!={} else icons[mesh.shape]
    }
    asset_field_thumbnail(s,ui.id_derive(ctx,id,"thumb"),asset.KIND_MESH,mesh.mesh if !mixed else {},MATERIAL_ROW,quad,icon if quad.kind==.Solid else .None)
    changed=geometry_field(s,id,mesh,mixed)
    asset_field_find(s,ui.id_derive(ctx,id,"find"),mesh.mesh if !mixed else {})
    return
}

// The skeleton the skin of the mesh is bound to: it comes with the mesh asset.
@(private)
skeleton_row :: proc(c:^Inspect) {
    s:=c.s
    mesh:=(cast(^erender.Mesh_Renderer)c.value)^
    if mesh.mesh=={} || s.app==nil || s.app.assets==nil {return}
    loaded:=host.assets_mesh(s.app.assets,mesh.mesh)
    if loaded==nil || loaded.failed || loaded.skeleton=={} {return}
    ctx:=s.gui.ctx
    shown:=asset_name(asset_path(s,loaded.skeleton))
    if shown=="" {shown="Missing"}
    icon,color:=asset_icon(s,asset.KIND_SKELETON)
    row_begin(ctx,"Skeleton")
    ui.disabled_begin(ctx)
    ui.button(ctx,ui.id(ctx,"skeleton"),{label=shown,icon=icon,icon_color=color,style=.Field,width=-1,size=ctx.theme.font_small})
    ui.disabled_end(ctx)
    row_end(ctx)
}

// The Mesh_Renderer geometry selector, also used by tools that own their value.
geometry_field :: proc(s:^Session,id:ui.Id,mesh:^erender.Mesh_Renderer,mixed:=false) -> (changed:bool) {
    ctx:=s.gui.ctx
    choice:=&s.inspector.geometry_choice
    if choice.field==id {
        mesh.shape,mesh.mesh=choice.shape,choice.mesh
        choice^={}
        changed=true
    }
    label:=fmt.tprint(mesh.shape)
    if mesh.mesh!={} {label=asset_name(asset_path(s,mesh.mesh))}
    if mixed {label="Multiple"}
    key:=u64(id)|u64(1)<<63
    open:=s.inspector.list.key==key
    th:=&ctx.theme
    arrow:=ui.id_derive(ctx,id,"arrow")
    hot:=ctx.hot==id || ctx.hot==arrow
    appearance:=ui.Node_Style{radius=th.radius_control,text={size=th.font_small,color=th.text}}
    if ui.box(ctx,{width=ui.GROW,height=ui.fixed(MATERIAL_ROW),gap=0,fill=th.well,stroke=open?th.accent:(hot?th.well_stroke_hover:th.well_stroke),radius=th.radius_control}) {
        // The thumbnail beside it shows the geometry (geometry_row).
        clicked:=ui.button(ctx,id,{label=label,width=-1,height=MATERIAL_ROW,size=th.font_small,padding=7,active=open,look=&appearance}).clicked
        clicked|=ui.button(ctx,arrow,{icon=.Chevron_Down,icon_size=13,icon_color=th.text_muted,width=18,height=MATERIAL_ROW,active=open,look=&appearance}).clicked
        if clicked && !open {
            anchor,_:=ui.widget_rect(ctx,id)
            anchor.w+=18
            list_open(s,{key=key,table=-1,kinds={0=asset.KIND_MESH},geometry=true,field=id},anchor)
        }
        if rect,found:=ui.widget_rect(ctx,id);found && s.gui.drag.kind==.Asset && s.gui.drag.asset_kind==asset.KIND_MESH && drag_dropped(s.gui,rect) {
            mesh.shape,mesh.mesh=.None,s.gui.drag.asset_id
            changed=true
        }

    }
    return
}

@(private)
geometry_set :: proc(s:^Session,t:^core.Table_Info,entities:[]core.Entity,shape:erender.Shape,mesh:base.Asset_Id) {
    opened,edit_ready:=edit_open(s,"Geometry")
    if !edit_ready {return}
    defer edit_close(s,opened)
    shape,mesh:=shape,mesh
    field_write(s,t,entities,int(offset_of(erender.Mesh_Renderer,mesh)),mem.ptr_to_bytes(&mesh))
    field_write(s,t,entities,int(offset_of(erender.Mesh_Renderer,shape)),mem.ptr_to_bytes(&shape))
}

// The rows of the fields of a struct at an offset of the component.
fields_rows :: proc(c:^Inspect,info:^runtime.Type_Info,origin:uintptr,depth:int,prefix:string) {
    v,is_struct:=runtime.type_info_base(info).variant.(runtime.Type_Info_Struct)
    if !is_struct {return}
    current:=""
    first:=true
    skip:=-1
    folded:=false // in a section that is closed
    banded:=false // the fold_band of the section of the fields is open
    defer if banded {fold_band_end(c.s)}
    for i in 0..<int(v.field_count) {
        if i==skip {continue}
        tag:=reflect.Struct_Tag(v.tags[i])
        if title,found:=core.field_option(tag,"section");found && title!="" && depth==0 {current=title}
        if _,hidden:=core.field_option(tag,"hidden");hidden {continue}
        if _,transient:=core.field_option(tag,"transient");transient {continue}
        if c.sections && depth==0 && current!=c.section {continue}
        if c.type==erender.Mesh_Renderer && v.names[i]=="materials" {continue}
        offset:=origin+v.offsets[i]
        if v.usings[i] {
            fields_rows(c,v.types[i],offset,depth,prefix)
            continue
        }
        if c.sections && depth==0 && core_has(tag,"advanced")!=c.advanced {continue}
        label:=readable(v.names[i])
        if custom,found:=core.field_option(tag,"label");found && custom!="" {
            label=custom
        } else if prefix!="" && info.id==mm.Transform {
            if v.names[i]=="position" {label="Pos"}
            if v.names[i]=="rotation" {label="Rot"}
        }
        if prefix!="" {label=fmt.tprintf("%s %s",prefix,strings.to_lower(label,context.temp_allocator))}
        if depth==0 && c.needle!="" && !base.contains_fold(label,c.needle) {continue}
        if title,found:=core.field_option(tag,"section");found && title!="" && depth==0 && !c.sections {
            if banded {fold_band_end(c.s);banded=false}
            folded=false
            // Searching, the rows that have it show without their part.
            if c.needle=="" {
                key:=base.hash_combine(base.hash_combine(u64(c.index),base.hash64(transmute([]u8)title)),0x73656374696f6e)
                folded=!fold_section(c.s,ui.id(c.s.gui.ctx,"section",int(key&0x7fffffff)),key,title,strings.equal_fold(title,ADVANCED_SECTION))
                if !folded {fold_band_begin(c.s);banded=true}
            }
        }
        if folded {continue}
        description:=""
        if prefix=="" && c.t!=nil && info==c.t.info && c.storage==0 {description=core.field_description(c.t,v.names[i])}
        if c.ruled && depth==0 {
            if !first {
                if ui.box(c.s.gui.ctx,{width=ui.GROW,height=ui.fixed(1),fill=c.s.gui.ctx.theme.row_rule}) {}
            }
            first=false
        }
        // Two masks of the same names in a row are one table, a column each.
        if i+1<int(v.field_count) && v.types[i+1].id==v.types[i].id && core.name_bits_of(c.w.info,v.types[i].id)!=nil && !v.usings[i+1] {
            skip=i+1
            if !inspector_extension(c,v.types[i],offset,label) {names_matrix_row(c,v.types[i],[2]string{label,readable(v.names[i+1])},[2]uintptr{offset,origin+v.offsets[i+1]})}
            continue
        }
        field_row(c,v.types[i],tag,v.names[i],label,offset,depth,description)
    }
}

// Two masks of the same names as one table, with one arrow that reverts both.
@(private)
names_matrix_row :: proc(c:^Inspect,info:^runtime.Type_Info,titles:[2]string,offsets:[2]uintptr) {
    ctx:=c.s.gui.ctx
    titles:=titles
    size:=info.size
    bits:[2][16]u8
    if size>len(bits[0]) {return}
    for &b,i in bits {mem.copy(&b,&c.value[offsets[i]],size)}
    masks:=[2][]u8{bits[0][:size],bits[1][:size]}
    if ui.box(ctx,{width=ui.GROW,height=ui.FIT,gap=4}) {
        changed:=names_matrix(ctx,c.w.info,core.name_bits_of(c.w.info,info.id),ui.id(ctx,"matrix",int(offsets[0])+1),titles[:],masks[:])
        for i in 0..<2 {
            if changed[i] {inspect_write(c,int(offsets[i]),masks[i])}
        }
        if offsets[1]==offsets[0]+uintptr(size) {field_reset_button(c,int(offsets[0]),2*size)} else {ui.spacer(ctx,REVERT_SIDE,1)}
    }
}

// Masks of the same names side by side, as Belongs and Collides: a line per
// name, with the box of each mask in its column. masks change in place;
// changed says which did.
names_matrix :: proc(ctx:^ui.Context,info:^core.World_Info,of:typeid,id:ui.Id,titles:[]string,masks:[][]u8,disabled:=false) -> (changed:[2]bool) {
    th:=&ctx.theme
    ui.id_push(ctx,id)
    defer ui.id_pop(ctx)
    if disabled {ui.disabled_begin(ctx)}
    defer if disabled {ui.disabled_end(ctx)}
    columns:=min(len(titles),len(masks),2)
    if ui.box(ctx,{width=ui.GROW,height=ui.FIT,direction=.Column}) {
        if ui.box(ctx,{width=ui.GROW,height=ui.fixed(22),align_y=.Center}) {
            ui.spacer(ctx,th.label_width+7,1)
            for column in 0..<columns {
                if column>0 {ui.spacer(ctx,1,1)}
                if ui.box(ctx,{width=ui.GROW,height=ui.GROW,align_x=.Center,align_y=.Center}) {ui.label(ctx,strings.to_upper(titles[column],context.temp_allocator),ctx.theme.font_caption,ctx.theme.text_caption,font=ui.FONT_SEMIBOLD)}
            }
        }
        if ui.box(ctx,{width=ui.GROW,height=ui.fixed(1),fill=ctx.theme.rule}) {}
        first:=true
        for entry,i in core.names_of(info,of) {
            if entry.value<0 || entry.value>=i64(len(masks[0])*8) {continue}
            if !first {
                if ui.box(ctx,{width=ui.GROW,height=ui.fixed(1),fill=ctx.theme.row_rule}) {}
            }
            first=false
            byte,bit:=entry.value/8,u8(1)<<u8(entry.value%8)
            if ui.box(ctx,{width=ui.GROW,height=ui.fixed(25),align_y=.Center}) {
                ui.label(ctx,readable(entry.name),th.font_small,th.text_label,th.label_width+7)
                for column in 0..<columns {
                    if column>0 {
                        if ui.box(ctx,{width=ui.fixed(1),height=ui.GROW,fill=ctx.theme.row_rule}) {}
                    }
                    if ui.box(ctx,{width=ui.GROW,height=ui.GROW,align_x=.Center,align_y=.Center}) {
                        on:=masks[column][byte]&bit!=0
                        if ui.checkbox(ctx,ui.id(ctx,"bit",column*64+i+1),&on) {
                            masks[column][byte]~=bit
                            changed[column]=true
                        }
                    }
                }
            }
        }
        if ui.box(ctx,{width=ui.GROW,height=ui.fixed(1),fill=ctx.theme.rule}) {}
    }
    return
}

// A section of a setting, as one of a component: its title in a band that
// folds it, when what is above it does not say it, and its rows under it. The
// right padding holds the arrows that revert a field. False: it is closed.
@(private,deferred_in=section_card_end)
section_card :: proc(s:^Session,id:ui.Id,title:string) -> (open:bool) {
    ctx:=s.gui.ctx
    ui.box_begin(ctx,{id=id,width=ui.GROW,height=ui.FIT,direction=.Column,track=true})
    open=true
    if title!="" {
        key:=base.hash_combine(u64(id),0x63617264)
        open=inspector_section_open(s.inspector,key)
        if section_band(s,ui.id_derive(ctx,id,"fold"),title,open,banded=true).clicked {
            inspector_section_toggle(s.inspector,key)
            open=!open
        }
    }
    // Its rows, set in under the band; empty and without room while it is folded.
    ui.box_begin(ctx,{width=ui.GROW,height=ui.FIT,direction=.Column,padding={BAND_INSET+SECTION_INDENT,7,BAND_INSET,8} if open else {},gap=3})
    return
}
@(private)
section_card_end :: proc(s:^Session,id:ui.Id,title:string) {ui.box_end(s.gui.ctx,{});ui.box_end(s.gui.ctx,{})}

// A section with this title starts folded: what few need to change.
ADVANCED_SECTION :: "Advanced"

// The title of a part of a card, which folds what follows it: every part of a
// card is one (the fields from one with `section=Title` in its tag on, a
// state of a style, Advanced), as a fold_label in a row of its own; what it
// opens goes in a fold_band.
section_fold :: proc(s:^Session,id:ui.Id,title:string,open:bool) -> (clicked:bool) {
    ctx:=s.gui.ctx
    ui.box_begin(ctx,{width=ui.GROW,height=ui.fixed(ctx.theme.row),align_y=.Center})
    clicked=fold_label(s,id,title,open)
    ui.box_end(ctx,{})
    return
}

// A section_fold whose state the inspector keeps by key, folded at first
// when folded says, and open while searching. Returns whether it is open.
fold_section :: proc(s:^Session,id:ui.Id,key:u64,title:string,folded:=false,searching:=false) -> bool {
    if searching {
        section_fold(s,id,title,true)
        return true
    }
    open:=inspector_section_open(s.inspector,key,folded)
    if section_fold(s,id,title,open) {
        inspector_section_toggle(s.inspector,key)
        open=!open
    }
    return open
}

@(private)
field_row :: proc(c:^Inspect,info:^runtime.Type_Info,tag:reflect.Struct_Tag,name,label:string,offset:uintptr,depth:int,description:="") {
    s:=c.s
    ctx:=s.gui.ctx
    th:=&ctx.theme
    if int(offset)+info.size>c.size {return}
    _,readonly:=core.field_option(tag,"readonly")
    unit,has_unit:=core.field_option(tag,"unit")
    shown:=has_unit && unit!=""?fmt.tprintf("%s (%s)",label,unit):label
    key:=base.hash_combine(u64(c.index)<<32|u64(offset),0x6669656c64~c.held)|1
    p:=rawptr(&c.value[offset])
    if inspector_extension(c,info,offset,shown) {return}
    leaf:=true
    #partial switch v in runtime.type_info_base(info).variant {
    case runtime.Type_Info_Struct: leaf=info.id==base.Asset_Id
    case runtime.Type_Info_Array:
        _,text:=core.field_option(tag,"text")
        _,number:=runtime.type_info_base(v.elem).variant.(runtime.Type_Info_Float)
        _,integer:=runtime.type_info_base(v.elem).variant.(runtime.Type_Info_Integer)
        record,is_record:=runtime.type_info_base(v.elem).variant.(runtime.Type_Info_Struct)
        leaf=text || (number || integer) && v.count>=2 && v.count<=4 || is_record && numbers_only(record)
    }
    if leaf && !readonly {
        fill:ui.Color
        if task,ok:=inspect_agent(c,int(offset),info.size);ok {fill=ui.color_alpha(ai_agent_color(task),28)}
        row:=ui.id(ctx,"field_row",int(offset)+1)
        // The arrow stays by the first line of a field its label opens.
        ui.box_begin(ctx,{id=row,width=ui.GROW,height=ui.FIT,gap=4,align_y=.Start,fill=fill,track=description!=""})
        if c.storage==0 && c.t!=nil && c.panel==nil {value_menu_row(s,row,{kind=.Field,table=c.index,offset=int(offset),info=info},label)}
        row_description(s,row,description)
        ui.box_begin(ctx,{width=ui.GROW,height=ui.FIT,direction=.Column})
    }
    defer if leaf && !readonly {
        ui.box_end(ctx,{})
        if ui.box(ctx,{width=ui.FIT,height=ui.fixed(ctx.theme.row),align_y=.Center}) {field_reset_button(c,int(offset),info.size)}
        ui.box_end(ctx,{})
    }
    if readonly {ui.disabled_begin(ctx)}
    defer if readonly {ui.disabled_end(ctx)}
    if record:=core.record_of_ref(c.w.info,info.id);record>=0 {
        record_row(c,shown,record,int(offset))
        return
    }
    switch info.id {
    case core.Entity:
        entity_row(c,shown,int(offset),key)
        return
    case base.Asset_Id:
        with,_:=core.field_option(tag,"with")
        asset_row(c,shown,field_asset_kinds(s,tag,name),int(offset),key,with)
        return
    }
    if core.named_type_of(c.w.info,info.id)!=nil {
        named_row(c,info,shown,offset,key)
        return
    }
    if of:=core.name_bits_of(c.w.info,info.id);of!=nil {
        named_bits_row(c,info,of,shown,offset)
        return
    }
    #partial switch v in runtime.type_info_base(info).variant {
    case runtime.Type_Info_Boolean:
        row_begin(ctx,shown)
        value:=(cast(^bool)p)^
        if ui.toggle_switch(ctx,ui.id(ctx,"bool",int(offset)+1),&value) {
            stored:=value
            inspect_write(c,int(offset),mem.ptr_to_bytes(&stored))
        }
        row_end(ctx)
    case runtime.Type_Info_Integer,runtime.Type_Info_Float:
        if inspector_number_extension(c,info,shown,offset,key) {return}
        if integer,is_integer:=v.(runtime.Type_Info_Integer);is_integer && !integer.signed && info.size==8 && core_has(tag,"hex") {
            hex_row(c,shown,offset)
            return
        }
        // The unit goes inside the box, after the value.
        row_begin(ctx,label)
        number_cell(c,info,tag,ui.id(ctx,"number",int(offset)+1),key,label,offset,"",{})
        row_end(ctx)
    case runtime.Type_Info_Enum:
        row_begin(ctx,shown)
        current:=i64(number_read(p,v.base))
        selected:=-1
        for value,at in v.values {
            if i64(value)==current {selected=at;break}
        }
        // A few short names are a segmented control; more, a list. icons: the
        // name of a ui.Icon for each value, which its segment shows instead.
        icons:[ENUM_SEGMENTS]ui.Icon
        iconed:=false
        if names,found:=core.field_option(tag,"icons");found && len(v.names)<=ENUM_SEGMENTS {
            iconed=true
            words:=strings.fields(names,context.temp_allocator)
            for at in 0..<len(v.names) {
                icon,known:=reflect.enum_from_name(ui.Icon,words[at] if at<len(words) else "")
                icons[at]=icon if known else .None
                iconed&=known
            }
        }
        need:=f32(0)
        for name in v.names {need+=ui.text_width(&ctx.font,readable(name),th.font_small)+16}
        if iconed {
            if ui.segments(ctx,ui.GROW,th.row) {
                for name,at in v.names {
                    if ui.button(ctx,ui.id(ctx,"enum_choice",int(offset)*8+at+1),{icon=icons[at],icon_size=16,tip=readable(name),style=.Tab,active=at==selected,width=-1,height=th.row-4,center=true,padding=2}).clicked && at!=selected {
                        buffer:[8]u8
                        number_write(raw_data(buffer[:]),v.base,f64(v.values[at]))
                        inspect_write(c,int(offset),buffer[:info.size])
                    }
                }
            }
        } else if len(v.names)<=ENUM_SEGMENTS && need<=c.width-th.label_width-REVERT_SIDE-16 {
            if ui.segments(ctx,ui.GROW,th.row) {
                for name,at in v.names {
                    if ui.button(ctx,ui.id(ctx,"enum_choice",int(offset)*8+at+1),{label=readable(name),style=.Tab,active=at==selected,width=-1,height=th.row-4,size=th.font_small,center=true,padding=2}).clicked && at!=selected {
                        buffer:[8]u8
                        number_write(raw_data(buffer[:]),v.base,f64(v.values[at]))
                        inspect_write(c,int(offset),buffer[:info.size])
                    }
                }
            }
        } else if ui.dropdown(ctx,ui.id(ctx,"enum",int(offset)+1),{list=v.names},&selected,{width=-1,height=th.row,searchable=true}) {
            buffer:[8]u8
            number_write(raw_data(buffer[:]),v.base,f64(v.values[selected]))
            inspect_write(c,int(offset),buffer[:info.size])
        }
        row_end(ctx)
    case runtime.Type_Info_Bit_Set:
        buffer:[16]u8
        if info.size>len(buffer) {readonly_row(ctx,shown,"bit set");return}
        mem.copy(&buffer,p,info.size)
        if bit_set_field(ctx,ui.id(ctx,"bits",int(offset)+1),shown,buffer[:info.size],v) {
            inspect_write(c,int(offset),buffer[:info.size])
        }
    case runtime.Type_Info_Quaternion:
        q:=(cast(^mm.Quat)p)^
        degrees:=mm.quat_to_euler(q)*mm.DEG_PER_RAD
        values:=[3]f64{f64(degrees.x),f64(degrees.y),f64(degrees.z)}
        row_begin(ctx,shown)
        id:=ui.id(ctx,"rotation",int(offset)+1)
        r,axis:=ui.vector_field(ctx,id,values[:],{number={decimals=1,speed=0.5,unit="°"}})
        if axis>=0 {
            if inspect_stepped(c) {gesture_follow(c.s,key+u64(axis),r,readable(c.name))}
            if r.changed {
                rotation:=mm.quat_from_euler({f32(values[0]),f32(values[1]),f32(values[2])}*mm.RAD_PER_DEG)
                inspect_write(c,int(offset),mem.ptr_to_bytes(&rotation))
            }
            if r.ended && inspect_stepped(c) {gesture_end(s,key+u64(axis))}
        }
        row_end(ctx)
    case runtime.Type_Info_Array:
        if inspector_array_extension(c,info,name,shown,offset) {return}
        elem:=runtime.type_info_base(v.elem)
        _,text:=core.field_option(tag,"text")
        if text && v.elem.size==1 {
            switch {
            case core_has(tag,"data"):                 data_row(c,shown,offset,v.count)
            case core_has(tag,"kind"):                 asset_path_row(c,shown,field_asset_kinds(c.s,tag,name),int(offset),v.count,key)
            case:                                      text_row(c,shown,offset,v.count,key)
            }
            return
        }
        _,is_number:=elem.variant.(runtime.Type_Info_Float)
        _,is_integer:=elem.variant.(runtime.Type_Info_Integer)
        if (is_number || is_integer) && v.count>=2 && v.count<=4 {
            if _,color:=core.field_option(tag,"color");color && is_number && v.elem.size==4 && v.count>=3 {
                color_row(c,shown,name,offset,v.count,key)
                return
            }
            vector_row(c,info,v,tag,shown,offset,key)
            return
        }
        if fields,is_record:=elem.variant.(runtime.Type_Info_Struct);is_record && numbers_only(fields) {
            record_rows(c,v,fields,shown,offset,key)
            return
        }
        shown_count:=min(v.count,INSPECTOR_ARRAY_ROWS)
        if texts,is_texts:=elem.variant.(runtime.Type_Info_Array);v.elem.id==base.Asset_Id || text && is_texts && texts.elem_size==1 || core_has(tag,"trim") {
            // References, texts and what the file trims: those set and one more.
            last:=-1
            for at in 0..<v.count {
                if !mem.check_zero(c.value[offset+uintptr(at*v.elem_size):][:v.elem_size]) {last=at}
            }
            shown_count=min(last+2,v.count)
        }
        if _,is_record:=elem.variant.(runtime.Type_Info_Struct);is_record && v.elem.id!=base.Asset_Id && depth<INSPECTOR_FIELD_DEPTH {
            records_rows(c,v,label,offset,shown_count,depth)
            return
        }
        for at in 0..<shown_count {
            element:=fmt.tprintf("%s %d",label,at+1)
            field_row(c,v.elem,tag,name,element,offset+uintptr(at*v.elem_size),depth)
        }
    case runtime.Type_Info_Struct:
        if count:=keys_count(v);count>0 {
            keys_rows(c,info,v,count,shown,offset,key)
            return
        }
        if depth>=INSPECTOR_FIELD_DEPTH {
            readonly_row(ctx,shown,"...")
            return
        }
        // Under a section of its own name its fields need not repeat it.
        section,_:=core.field_option(tag,"section")
        fields_rows(c,info,offset,depth+1,"" if strings.equal_fold(section,label) else label)
    case:
        readonly_row(ctx,shown,serial.type_label(info))
    }
}

// A core.Record: a row of the tables of its type, by name.
@(private)
record_row :: proc(c:^Inspect,label:string,record,offset:int) {
    ctx:=c.s.gui.ctx
    buffer:[size_of(base.Asset_Id)+size_of(core.Record_Id)]u8
    if offset+len(buffer)>c.size {return}
    mem.copy(&buffer[0],&c.value[offset],len(buffer))
    row_begin(ctx,label)
    if record_choice(c.s,ui.id(ctx,"record",offset+1),record,cast(^core.Record_Id)&buffer[size_of(base.Asset_Id)],cast(^base.Asset_Id)&buffer[0],ui.GROW) {inspect_write(c,offset,buffer[:])}
    row_end(ctx)
}

// A value of a type @(names): its name in a list of them. Typing a name that
// is not there creates it, and the pencil renames one the project declared.
@(private)
named_row :: proc(c:^Inspect,info:^runtime.Type_Info,label:string,offset:uintptr,key:u64) {
    s:=c.s
    ctx:=s.gui.ctx
    th:=&ctx.theme
    ins:=s.inspector
    type:=core.named_type_of(c.w.info,info.id)
    current:=i64(number_read(&c.value[offset],info))
    // The values whose component the active entity lacks are not offered; the current one always is.
    active:=len(c.entities)>0?c.entities[len(c.entities)-1]:core.NONE
    offered:=make([dynamic]core.Name_Info,context.temp_allocator)
    for entry in core.names_of(c.w.info,info.id) {
        if entry.requires!=nil && active!=core.NONE && entry.value!=current {
            if table,_:=core.world_table(c.w,entry.requires);table==nil || core.raw_row(table,active)<0 {continue}
        }
        append(&offered,entry)
    }
    names:=offered[:]
    options:=make([]string,len(names),context.temp_allocator)
    selected:=-1
    for entry,i in names {
        options[i]=readable(entry.name)
        if entry.value==current {selected=i}
    }
    write :: proc(c:^Inspect,info:^runtime.Type_Info,offset:uintptr,value:i64) {
        buffer:[8]u8
        number_write(raw_data(buffer[:]),info,f64(value))
        inspect_write(c,int(offset),buffer[:info.size])
    }
    row_begin(ctx,label)
    if ins.naming==key && selected>=0 {
        field:=ui.id(ctx,"value_name",int(offset)+1)
        if ins.naming_request {
            ins.value_name_length=copy(ins.value_name[:],names[selected].name)
            ui.edit_request(ctx,field)
            ins.naming_request=false
        }
        r:=ui.text_field(ctx,field,ins.value_name[:],&ins.value_name_length,{height=th.row})
        if r.committed {
            if error:=names_rename(s,c.w.info,info.id,names[selected].name,string(ins.value_name[:ins.value_name_length]));error!=.None {
                notify(s,names_error_text(error,type.name,string(ins.value_name[:ins.value_name_length])))
            }
        }
        if r.committed || r.cancelled || (!r.editing && !r.began && ctx.edit.id!=field) {ins.naming=0}
    } else {
        created:string
        if ui.dropdown(ctx,ui.id(ctx,"named",int(offset)+1),{list=options},&selected,{width=-1,height=th.row,searchable=true,empty=fmt.tprintf("%d",current)},&created) {
            write(c,info,offset,names[selected].value)
        }
        if created!="" {
            if value,error:=names_create(s,c.w.info,info.id,created);error==.None {
                write(c,info,offset,value)
            } else {notify(s,names_error_text(error,type.name,created))}
        }
        // An input action is renamed in code; names.rename then follows it.
        if selected>=0 && names[selected].project && info.id!=input.Action &&ui.button(ctx,ui.id(ctx,"rename_value",int(offset)+1),{icon=.Edit,style=.Ghost,width=th.row,height=th.row}).clicked {
            ins.naming,ins.naming_request=key,true
        }
    }
    row_end(ctx)
}

// A mask whose bits are the values of a type @(names): a box for each of them.
@(private)
named_bits_row :: proc(c:^Inspect,info:^runtime.Type_Info,of:typeid,label:string,offset:uintptr) {
    ctx:=c.s.gui.ctx
    th:=&ctx.theme
    bits:[16]u8
    if info.size>len(bits) {readonly_row(ctx,label,"mask");return}
    mem.copy(&bits,&c.value[offset],info.size)
    ui.label(ctx,label,th.font_small,th.text_muted,0)
    changed:=false
    for entry,i in core.names_of(c.w.info,of) {
        if entry.value<0 || entry.value>=i64(info.size*8) {continue}
        byte,mask:=entry.value/8,u8(1)<<u8(entry.value%8)
        on:=bits[byte]&mask!=0
        ui.box_begin(ctx,{width=ui.GROW,height=ui.fixed(th.row),gap=4,align_y=.Center})
        ui.label(ctx,readable(entry.name),th.font_small,th.text,0)
        if ui.checkbox(ctx,ui.id(ctx,"named_bit",int(offset)*64+i+1),&on) {
            bits[byte]~=mask
            changed=true
        }
        ui.box_end(ctx,{})
    }
    if changed {inspect_write(c,int(offset),bits[:info.size])}
}

@(private)
bit_set_axis_group :: proc(names:[]string,first:int) -> (group:string,count:int) {
    if first+2>=len(names) {return}
    name:=names[first]
    if len(name)<3 || !strings.has_suffix(name,"_X") {return}
    group=name[:len(name)-2]
    y,z:=names[first+1],names[first+2]
    if strings.has_suffix(y,"_Y") && y[:len(y)-2]==group && strings.has_suffix(z,"_Z") && z[:len(z)-2]==group {return group,3}
    return "",0
}

@(private)
bit_set_field :: proc(ctx:^ui.Context,id:ui.Id,label:string,bits:[]u8,type:runtime.Type_Info_Bit_Set) -> (changed:bool) {
    elements,is_enum:=runtime.type_info_base(type.elem).variant.(runtime.Type_Info_Enum)
    if !is_enum {readonly_row(ctx,label,"bit set");return}
    th:=&ctx.theme
    axes:=ui.AXIS_NAMES
    ui.label(ctx,label,th.font_small,th.text_muted,0)
    for first:=0;first<len(elements.names); {
        group,count:=bit_set_axis_group(elements.names,first)
        if count==0 {count=1}
        ui.box_begin(ctx,{width=ui.GROW,height=ui.fixed(th.row),gap=4,align_y=.Center})
        if group!="" {ui.label(ctx,readable(group),th.font_small,th.text_label,th.label_width)}
        for at in first..<first+count {
            bit:=int(i64(elements.values[at])-type.lower)
            if bit<0 || bit>=len(bits)*8 {continue}
            byte,mask:=bit/8,u8(1)<<u8(bit%8)
            on:=bits[byte]&mask!=0
            clicked:=false
            if group!="" {
                axis:=at-first
                clicked=ui.toggle(ctx,ui.id_derive(ctx,id,"member",at+1),axes[axis],&on)
            } else {
                ui.label(ctx,readable(elements.names[at]),th.font_small,th.text,0)
                clicked=ui.checkbox(ctx,ui.id_derive(ctx,id,"member",at+1),&on)
            }
            if clicked {
                bits[byte]~=mask
                changed=true
            }
        }
        ui.box_end(ctx,{})
        first+=count
    }
    return
}

// The elements of an array of records, each folded under a button with its
// name: opened, its fields follow in a band under it.
@(private)
records_rows :: proc(c:^Inspect,v:runtime.Type_Info_Array,label:string,offset:uintptr,count,depth:int) {
    s:=c.s
    ctx:=s.gui.ctx
    th:=&ctx.theme
    one:=label
    switch {
    case strings.has_suffix(label,"sses"),strings.has_suffix(label,"shes"),strings.has_suffix(label,"ches"),strings.has_suffix(label,"xes"),strings.has_suffix(label,"uses"):
        one=label[:len(label)-2]
    case strings.has_suffix(label,"s") && !strings.has_suffix(label,"ss"):
        one=label[:len(label)-1]
    }
    for at in 0..<count {
        at_offset:=offset+uintptr(at*v.elem_size)
        key:=base.hash_combine(u64(c.index)<<32|u64(at_offset),0x7265636f7264)
        open:=inspector_section_open(s.inspector,key,true)
        if ui.box(ctx,{width=ui.GROW,height=ui.fixed(th.row),gap=4,align_y=.Center}) {
            if fold_button(s,ui.id(ctx,"record_fold",int(at_offset)+1),fmt.tprintf("%s %d",one,at+1),open) {
                inspector_section_toggle(s.inspector,key)
                open=!open
            }
            field_reset_button(c,int(at_offset),v.elem_size)
        }
        if !open {continue}
        // Under its button, short of the column of the arrows that revert.
        if ui.box(ctx,{width=ui.GROW,height=ui.FIT,gap=4}) {
            if fold_band(s) {fields_rows(c,v.elem,at_offset,depth+1,"")}
            ui.spacer(ctx,REVERT_SIDE,1)
        }
    }
}

// A button that folds what follows it: its name, and a triangle at its right end.
@(private)
fold_button :: proc(s:^Session,id:ui.Id,label:string,open:bool) -> (clicked:bool) {
    ctx:=s.gui.ctx
    th:=&ctx.theme
    white:=ui.Color{255,255,255,255}
    it:=ui.interact(ctx,id,{.Focusable})
    if ui.box(ctx,{id=id,width=ui.GROW,height=ui.fixed(20),padding={7,0,5,0},gap=4,align_y=.Center,fill=ui.color_alpha(white,open || it.hot?28:15),stroke=ui.color_alpha(white,open?46:26),radius=4}) {
        ui.label(ctx,label,th.font_small,th.text,0,font=open?ui.FONT_SEMIBOLD:ui.FONT_REGULAR)
        ui.icon(ctx,open?.Chevron_Down:.Chevron_Right,th.text_muted,11)
    }
    return it.clicked
}

// The label of a row that folds what follows it, in the column of labels
// where the labels of the rows around it start, with the arrow after it.
fold_label :: proc(s:^Session,id:ui.Id,label:string,open:bool) -> (clicked:bool) {
    ctx:=s.gui.ctx
    th:=&ctx.theme
    it:=ui.interact(ctx,id,{.Focusable})
    if ui.box(ctx,{id=id,width=ui.fixed(th.label_width),height=ui.fixed(20),gap=3,align_y=.Center}) {
        font:u8=open?ui.FONT_SEMIBOLD:ui.FONT_REGULAR
        // A long label fades out before the arrow.
        room:=min(ui.text_width(&ctx.font,label,th.font_small,int(font))+1,th.label_width-14)
        ui.label(ctx,label,th.font_small,open || it.hot?th.text:th.text_label,room,font=font,fade=true)
        ui.icon(ctx,open?.Chevron_Down:.Chevron_Right,th.text_muted,11)
    }
    return it.clicked
}

// The band under a fold_button, a fold_label or a section_fold that holds
// what it opened.
@(deferred_in=fold_band_end)
fold_band :: proc(s:^Session) -> bool {
    fold_band_begin(s)
    return true
}
// What a section unfolds, on the background of its card: no box of its own,
// set in from the row that opened it with a rule down its left.
fold_band_begin :: proc(s:^Session) {
    ctx:=s.gui.ctx
    ui.box_begin(ctx,{width=ui.GROW,height=ui.FIT,padding={4,3,0,4},gap=9})
    if ui.box(ctx,{width=ui.fixed(1),height=ui.GROW,fill=ctx.theme.rule}) {}
    ui.box_begin(ctx,{width=ui.GROW,height=ui.FIT,direction=.Column,gap=3})
}
fold_band_end :: proc(s:^Session) {ui.box_end(s.gui.ctx,{});ui.box_end(s.gui.ctx,{})}

// A row with its label in the column of labels.
row_begin :: proc(ctx:^ui.Context,label:string) {
    th:=&ctx.theme
    ui.box_begin(ctx,{width=ui.GROW,height=ui.fixed(th.row),gap=4,align_y=.Center})
    ui.column_label(ctx,label)
}
row_end :: proc(ctx:^ui.Context) {ui.box_end(ctx,{})}

@(private)
readonly_row :: proc(ctx:^ui.Context,label,value:string) {
    th:=&ctx.theme
    row_begin(ctx,label)
    ui.label(ctx,value,th.font_small,th.text_faint,0)
    row_end(ctx)
}

number_read :: proc(p:rawptr,info:^runtime.Type_Info) -> f64 {
    #partial switch v in runtime.type_info_base(info).variant {
    case runtime.Type_Info_Float:
        switch info.size {
        case 2: return f64((cast(^f16)p)^)
        case 4: return f64((cast(^f32)p)^)
        case 8: return (cast(^f64)p)^
        }
    case runtime.Type_Info_Integer:
        if v.signed {
            switch info.size {
            case 1: return f64((cast(^i8)p)^)
            case 2: return f64((cast(^i16)p)^)
            case 4: return f64((cast(^i32)p)^)
            case 8: return f64((cast(^i64)p)^)
            }
        } else {
            switch info.size {
            case 1: return f64((cast(^u8)p)^)
            case 2: return f64((cast(^u16)p)^)
            case 4: return f64((cast(^u32)p)^)
            case 8: return f64((cast(^u64)p)^)
            }
        }
    case runtime.Type_Info_Boolean:
        return (cast(^bool)p)^?1:0
    }
    return 0
}

number_write :: proc(p:rawptr,info:^runtime.Type_Info,value:f64) {
    #partial switch v in runtime.type_info_base(info).variant {
    case runtime.Type_Info_Float:
        switch info.size {
        case 2: (cast(^f16)p)^=f16(value)
        case 4: (cast(^f32)p)^=f32(value)
        case 8: (cast(^f64)p)^=value
        }
    case runtime.Type_Info_Integer:
        rounded:=math.round(value)
        if v.signed {
            switch info.size {
            case 1: (cast(^i8)p)^=i8(clamp(rounded,-128,127))
            case 2: (cast(^i16)p)^=i16(clamp(rounded,-32768,32767))
            case 4: (cast(^i32)p)^=i32(clamp(rounded,-2147483648,2147483647))
            case 8: (cast(^i64)p)^=i64(rounded)
            }
        } else {
            switch info.size {
            case 1: (cast(^u8)p)^=u8(clamp(rounded,0,255))
            case 2: (cast(^u16)p)^=u16(clamp(rounded,0,65535))
            case 4: (cast(^u32)p)^=u32(clamp(rounded,0,4294967295))
            case 8: (cast(^u64)p)^=u64(max(rounded,0))
            }
        }
    }
}

// What the tag of a field says of its number field, and the units it is shown in.
field_number :: proc(info:^runtime.Type_Info,tag:reflect.Struct_Tag) -> (desc:ui.Number_Field,scale:f64) {
    scale=1
    _,is_float:=runtime.type_info_base(info).variant.(runtime.Type_Info_Float)
    desc.integer=!is_float
    if text,ok:=core.field_option(tag,"min");ok {desc.min,desc.has_min=strconv.parse_f64(text)}
    if text,ok:=core.field_option(tag,"max");ok {desc.max,desc.has_max=strconv.parse_f64(text)}
    if !is_float {
        if v,ok:=runtime.type_info_base(info).variant.(runtime.Type_Info_Integer);ok && !v.signed && !desc.has_min {desc.min,desc.has_min=0,true}
    }
    if unit,found:=core.field_option(tag,"unit");found {desc.unit=unit}
    switch {
    case core_has(tag,"angle"):
        scale=f64(mm.DEG_PER_RAD)
        desc.unit="°"
        desc.decimals,desc.speed=1,0.2
        desc.min*=scale
        desc.max*=scale
    case desc.integer:                   desc.speed=0.05
    case desc.has_min && desc.has_max:   desc.speed=max((desc.max-desc.min)/200,1e-4)
    case:                                desc.speed=0.02
    }
    return
}

@(private)
core_has :: proc(tag:reflect.Struct_Tag,option:string) -> bool {
    _,ok:=core.field_option(tag,option)
    return ok
}

// One number of a component as a field.
@(private)
number_cell :: proc(c:^Inspect,info:^runtime.Type_Info,tag:reflect.Struct_Tag,id:ui.Id,key:u64,label:string,offset:uintptr,axis_label:string,strip:ui.Color,icon:=ui.Icon.None) {
    desc,scale:=field_number(info,tag)
    desc.strip,desc.icon=strip,icon
    // A cell of a vector is narrow: its name says the unit, and only degrees go inside.
    if axis_label!="" && desc.unit!="°" {desc.unit=""}
    // An axis without a color of its own says its name inside.
    if axis_label!="" && strip[3]==0 {desc.label=axis_label}
    value:=number_read(&c.value[offset],info)*scale
    r:ui.Number_Result
    if axis_label=="" {r=ui.slider_field(c.s.gui.ctx,id,&value,desc)} else {r=ui.number_field(c.s.gui.ctx,id,&value,desc)}
    // The values a panel holds are no step of the document.
    stepped:=inspect_stepped(c)
    if stepped {gesture_follow(c.s,key,r,readable(c.name))}
    if r.changed {
        buffer:[8]u8
        number_write(raw_data(buffer[:]),info,value/scale)
        inspect_write(c,int(offset),buffer[:info.size])
    }
    if r.ended && stepped {gesture_end(c.s,key)}
}

// The sides of a box (`axes=LTRB`) and its corners (`axes=TL TR BR BL`): an
// arrow toward each and its name when the row opens.
@(private) BOX_SIDE_ICONS :: [4]User_Icon{.Arrow_Left,.Up,.Arrow_Right,.Down}
@(private) BOX_SIDE_NAMES :: [4]string{"Left","Top","Right","Bottom"}
@(private) BOX_CORNER_ICONS :: [4]User_Icon{.Arrow_Up_Left,.Arrow_Up_Right,.Arrow_Down_Right,.Arrow_Down_Left}
@(private) BOX_CORNER_NAMES :: [4]string{"Top left","Top right","Bottom right","Bottom left"}

@(private)
vector_row :: proc(c:^Inspect,info:^runtime.Type_Info,v:runtime.Type_Info_Array,tag:reflect.Struct_Tag,label:string,offset:uintptr,key:u64) {
    ctx:=c.s.gui.ctx
    th:=&ctx.theme
    // axes: the name of each, a letter (`axes=LTRB`) or words (`axes=Min Max Step`); X, Y, Z and W otherwise.
    names:=ui.AXIS_NAMES
    axes,lettered:=core.field_option(tag,"axes")
    words:=strings.fields(axes,context.temp_allocator) if strings.contains(axes," ") else nil
    if v.count==4 && (axes=="LTRB" || axes=="TL TR BR BL") {
        box_row(c,v,tag,label,offset,key,axes=="LTRB")
        return
    }
    row_begin(ctx,label)
    for at in 0..<v.count {
        letter:=names[at]
        if at<len(words) {letter=words[at]} else if lettered && words==nil && at<len(axes) {letter=axes[at:at+1]}
        number_cell(c,v.elem,tag,ui.id(ctx,"axis",int(offset)*8+at+1),key+u64(at)*2,label,offset+uintptr(at*v.elem_size),letter,lettered?{}:th.axis[at])
    }
    row_end(ctx)
}

// The four values of the sides or the corners of a box, each with its arrow;
// the label opens a row for each, with its name, as a color opens its channels.
@(private)
box_row :: proc(c:^Inspect,v:runtime.Type_Info_Array,tag:reflect.Struct_Tag,label:string,offset:uintptr,key:u64,sides:bool) {
    s:=c.s
    ctx:=s.gui.ctx
    th:=&ctx.theme
    icons:=BOX_SIDE_ICONS if sides else BOX_CORNER_ICONS
    names:=BOX_SIDE_NAMES if sides else BOX_CORNER_NAMES
    fold:=base.hash_combine(key,0x626f7873696465)
    open:=inspector_section_open(s.inspector,fold,true)
    ui.box_begin(ctx,{width=ui.GROW,height=ui.fixed(th.row),gap=4,align_y=.Center})
    if fold_label(s,ui.id(ctx,"box_sides",int(offset)+1),label,open) {
        inspector_section_toggle(s.inspector,fold)
        open=!open
    }
    for at in 0..<4 {
        number_cell(c,v.elem,tag,ui.id(ctx,"axis",int(offset)*8+at+1),key+u64(at)*2,label,offset+uintptr(at*v.elem_size),"·",{},ui.icon_user(u8(icons[at])))
    }
    ui.box_end(ctx,{})
    if !open {return}
    if fold_band(s) {
        for at in 0..<4 {
            row_begin(ctx,names[at])
            number_cell(c,v.elem,tag,ui.id(ctx,"side",int(offset)*8+at+1),key+u64(at)*2,label,offset+uintptr(at*v.elem_size),"",{},ui.icon_user(u8(icons[at])))
            row_end(ctx)
        }
    }
}

// An array of records of a few numbers as a table, a column per field: the
// records set, each with its remove, and an empty one to fill.
@(private)
record_rows :: proc(c:^Inspect,v:runtime.Type_Info_Array,fields:runtime.Type_Info_Struct,label:string,offset:uintptr,key:u64) {
    ctx:=c.s.gui.ctx
    th:=&ctx.theme
    array:=c.value[offset:][:v.count*v.elem_size]
    used:=0
    for at in 0..<v.count {
        if !mem.check_zero(array[at*v.elem_size:][:v.elem_size]) {used=at+1}
    }
    row_begin(ctx,label)
    for i in 0..<int(fields.field_count) {ui.label(ctx,readable(fields.names[i]),th.font_small,th.text_faint,0)}
    ui.spacer(ctx,th.row)
    row_end(ctx)
    for at in 0..<min(used+1,v.count) {
        at_offset:=offset+uintptr(at*v.elem_size)
        row_begin(ctx,"")
        for i in 0..<int(fields.field_count) {
            cell:=at*int(fields.field_count)+i
            number_cell(c,fields.types[i],reflect.Struct_Tag(fields.tags[i]),ui.id(ctx,"record",int(offset)*64+cell+1),key+u64(cell)*2,label,at_offset+fields.offsets[i],"",{})
        }
        if at>=used {
            ui.spacer(ctx,th.row)
        } else if ui.button(ctx,ui.id(ctx,"record_remove",int(offset)*64+at+1),{icon=.Cross,style=.Ghost,width=th.row,height=th.row}).clicked {
            next:=make([]u8,len(array),context.temp_allocator)
            copy(next,array[:at*v.elem_size])
            copy(next[at*v.elem_size:],array[(at+1)*v.elem_size:])
            inspect_write(c,int(offset),next)
        }
        row_end(ctx)
    }
}

// The keys of a struct of two to four arrays of one length above four, of
// numbers or of colors, as a curve keeps them; 0 for another struct.
@(private)
keys_count :: proc(fields:runtime.Type_Info_Struct) -> (count:int) {
    if fields.field_count<2 || fields.field_count>4 {return 0}
    for i in 0..<int(fields.field_count) {
        array,is_array:=runtime.type_info_base(fields.types[i]).variant.(runtime.Type_Info_Array)
        if !is_array || array.count<=4 || array.count>INSPECTOR_ARRAY_ROWS || i>0 && array.count!=count {return 0}
        count=array.count
        #partial switch element in runtime.type_info_base(array.elem).variant {
        case runtime.Type_Info_Float,runtime.Type_Info_Integer:
        case runtime.Type_Info_Array:
            _,float:=runtime.type_info_base(element.elem).variant.(runtime.Type_Info_Float)
            if !float || element.elem.size!=4 || element.count<3 || element.count>4 || !core_has(reflect.Struct_Tag(fields.tags[i]),"color") {return 0}
        case: return 0
        }
    }
    return
}

// The keys of a curve as a table: its name and one arrow for all of it, a
// title per array, and a row per key with a cell per array.
@(private)
keys_rows :: proc(c:^Inspect,info:^runtime.Type_Info,fields:runtime.Type_Info_Struct,count:int,label:string,offset:uintptr,key:u64) {
    ctx:=c.s.gui.ctx
    th:=&ctx.theme
    columns:=int(fields.field_count)
    if ui.box(ctx,{width=ui.GROW,height=ui.fixed(th.row),gap=4,align_y=.Center}) {
        ui.label(ctx,label,th.font_small,th.text_muted,0)
        ui.spacer(ctx)
        field_reset_button(c,int(offset),info.size)
    }
    row_begin(ctx,"")
    for i in 0..<columns {
        if ui.box(ctx,{width=ui.GROW,height=ui.fixed(th.row),align_y=.Center}) {ui.label(ctx,readable(fields.names[i]),th.font_small,th.text_faint,0)}
    }
    ui.spacer(ctx,REVERT_SIDE,1)
    row_end(ctx)
    for at in 0..<count {
        row_begin(ctx,"")
        for i in 0..<columns {
            array:=runtime.type_info_base(fields.types[i]).variant.(runtime.Type_Info_Array)
            at_offset:=offset+fields.offsets[i]+uintptr(at*array.elem_size)
            cell:=at*columns+i
            if ui.box(ctx,{width=ui.GROW,height=ui.fixed(th.row),gap=4,align_y=.Center}) {
                if color,is_color:=runtime.type_info_base(array.elem).variant.(runtime.Type_Info_Array);is_color {
                    color_cell(c,label,fields.names[i],at_offset,color.count,key+u64(cell)*2)
                } else {
                    number_cell(c,array.elem,reflect.Struct_Tag(fields.tags[i]),ui.id(ctx,"key",int(offset)*64+cell+1),key+u64(cell)*2,label,at_offset,"",{})
                }
            }
        }
        ui.spacer(ctx,REVERT_SIDE,1)
        row_end(ctx)
    }
}

@(private)
numbers_only :: proc(fields:runtime.Type_Info_Struct) -> bool {
    if fields.field_count>4 {return false}
    for i in 0..<int(fields.field_count) {
        #partial switch _ in runtime.type_info_base(fields.types[i]).variant {
        case runtime.Type_Info_Integer,runtime.Type_Info_Float:
        case: return false
        }
    }
    return true
}

// A component or a storage of the game, by its name (`data` in the tag of a
// text): one of a list of those the world declares, or none. A name the
// world no longer has stays, marked, until another is chosen.
@(private)
data_row :: proc(c:^Inspect,label:string,offset:uintptr,count:int) {
    ctx:=c.s.gui.ctx
    current:=base.text_get(c.value[offset:][:count])
    names:=make([dynamic]string,context.temp_allocator)
    append(&names,"None")
    selected:=0
    if c.w.info!=nil {
        for &t in c.w.info.tables {
            if t.name==current {selected=len(names)}
            append(&names,t.name)
        }
        for &storage in c.w.info.storages {
            if storage.name==current {selected=len(names)}
            append(&names,storage.name)
        }
    }
    missing:=current!="" && selected==0
    if missing {
        selected=len(names)
        append(&names,fmt.tprintf("%s (missing)",current))
    }
    row_begin(ctx,label)
    if ui.dropdown(ctx,ui.id(ctx,"data",int(offset)+1),{list=names[:]},&selected,{width=-1,height=ctx.theme.row,searchable=true}) && !(missing && selected==len(names)-1) {
        buffer:=make([]u8,count,context.temp_allocator)
        if selected>0 {copy(buffer[:max(count-1,0)],names[selected])}
        inspect_write(c,int(offset),buffer)
    }
    row_end(ctx)
}

@(private)
text_row :: proc(c:^Inspect,label:string,offset:uintptr,count:int,key:u64) {
    ctx:=c.s.gui.ctx
    buffer:=make([]u8,count,context.temp_allocator)
    copy(buffer,c.value[offset:][:count])
    length:=len(base.text_get(buffer))
    row_begin(ctx,label)
    if ui.text_field(ctx,ui.id(ctx,"text",int(offset)+1),buffer[:max(count-1,0)],&length).changed {
        for &b in buffer[length:] {b=0}
        inspect_write(c,int(offset),buffer)
    }
    row_end(ctx)
}

@(private)
hex_row :: proc(c:^Inspect,label:string,offset:uintptr) {
    value:=(cast(^u64)&c.value[offset])^
    buffer:[18]u8
    buffer[0],buffer[1]='0','x'
    digits:="0123456789abcdef"
    for i in 0..<16 {buffer[i+2]=digits[(value>>u32((15-i)*4))&15]}
    length:=len(buffer)
    ctx:=c.s.gui.ctx
    row_begin(ctx,label)
    if ui.text_field(ctx,ui.id(ctx,"hex",int(offset)+1),buffer[:],&length).changed {
        parsed,ok:=serial.text_parse_hex(string(buffer[:length]))
        if ok {inspect_write(c,int(offset),mem.ptr_to_bytes(&parsed))}
    }
    row_end(ctx)
}

// A color as its swatch: a click opens the picker. Linear values, shown as they are displayed.
@(private)
// Its label opens the channels, each a number of its own.
color_row :: proc(c:^Inspect,label,name:string,offset:uintptr,channels:int,key:u64) {
    s:=c.s
    ctx:=s.gui.ctx
    th:=&ctx.theme
    fold:=base.hash_combine(key,0x6368616e6e656c73)
    open:=inspector_section_open(s.inspector,fold,true)
    ui.box_begin(ctx,{width=ui.GROW,height=ui.fixed(th.row),gap=4,align_y=.Center})
    if fold_label(s,ui.id(ctx,"channels",int(offset)+1),label,open) {
        inspector_section_toggle(s.inspector,fold)
        open=!open
    }
    color_cell(c,label,name,offset,channels,key)
    ui.box_end(ctx,{})
    if !open {return}
    // Light can be brighter than 1: its color is not bounded.
    tag:=reflect.Struct_Tag(`mirai:"min=0"` if strings.contains(name,"emission") else `mirai:"min=0,max=1"`)
    names:=[4]string{"R","G","B","A"}
    if fold_band(s) {
        for at in 0..<channels {
            row_begin(ctx,names[at])
            number_cell(c,type_info_of(f32),tag if at<3 else reflect.Struct_Tag(`mirai:"min=0,max=1"`),ui.id(ctx,"channel",int(offset)*4+at+1),key+u64(at+1)*2,label,offset+uintptr(at*4),"",th.channel[at])
            row_end(ctx)
        }
    }
}

// The swatch of a color and, with four channels, its alpha.
@(private)
color_cell :: proc(c:^Inspect,label,name:string,offset:uintptr,channels:int,key:u64) {
    s:=c.s
    ctx:=s.gui.ctx
    th:=&ctx.theme
    linear:=(cast(^[3]f32)&c.value[offset])^
    emission:=strings.contains(name,"emission")
    id:=ui.id(ctx,"swatch",int(offset)+1)
    if ui.color_swatch(ctx,id,swatch_color(linear),s.inspector.picker.key==key).clicked && s.inspector.picker.key!=key {
        rect,_:=ui.widget_rect(ctx,id)
        alpha:=channels>3?(cast(^[4]f32)&c.value[offset])^.w:1
        picker_open(s,{key=key,table=c.index,storage=c.storage,held=c.held,stepped=c.write!=nil,offset=int(offset),channels=channels,alpha=alpha,emission=emission},linear,rect)
    }
    if channels>3 {
        alpha_info:=type_info_of(f32)
        number_cell(c,alpha_info,`mirai:"min=0,max=1"`,ui.id(ctx,"alpha",int(offset)+1),key+1,label,offset+12,"A",th.channel[3])
    }
}

// The swatch of a linear color: brighter than 1, normalized to its brightest channel.
@(private)
swatch_color :: proc(linear:[3]f32) -> [3]f32 {
    shown:=linear
    if peak:=max(shown.x,shown.y,shown.z);peak>1 {shown/=peak}
    return ui.display_color({clamp(shown.x,0,1),clamp(shown.y,0,1),clamp(shown.z,0,1)})
}

@(private)
picker_popup :: proc(g:^Editor_Ui) -> ui.Id {return shell_id(g,"color_picker")}

@(private)
picker_open :: proc(s:^Session,p:Color_Session,linear:[3]f32,anchor:ui.Rect) {
    ins:=s.inspector
    shown:=linear
    ins.picker=p
    ins.picker.intensity=1
    if peak:=max(shown.x,shown.y,shown.z);p.emission && peak>1 {
        ins.picker.intensity=f64(peak)
        shown/=peak
    }
    ui.color_picker_set(&ins.picker.state,ui.display_color({clamp(shown.x,0,1),clamp(shown.y,0,1),clamp(shown.z,0,1)}))
    ui.popup_open(s.gui.ctx,picker_popup(s.gui),anchor)
}

// Everything one session of the picker changes is one step.
@(private)
picker_build :: proc(s:^Session,w:core.World_Ref) {
    ins:=s.inspector
    p:=&ins.picker
    if p.key==0 {return}
    g:=s.gui
    ctx:=g.ctx
    th:=&ctx.theme
    popup:=picker_popup(g)
    if !ui.popup_is_open(ctx,popup) {
        gesture_end(s,p.key)
        p^={}
        return
    }
    if ins.gesture==p.key {ins.gesture_frame=s.frame}
    changed:=false
    if ui.popup(ctx,popup,{width=240,padding=12}) {
        changed=ui.color_picker(ctx,ui.id_derive(ctx,popup,"picker"),&p.state).changed
        if p.emission {
            if ui.box(ctx,{width=ui.GROW,height=ui.fixed(th.row),gap=4,align_y=.Center}) {
                ui.label(ctx,"Intensity",th.font_small,th.text_label,th.label_width)
                changed|=ui.number_field(ctx,ui.id_derive(ctx,popup,"intensity"),&p.intensity,{decimals=2,speed=0.02,has_min=true,has_max=true,max=1e5}).changed
            }
        }
    }
    if !changed {return}
    linear:=ui.linear_color(ui.color_picker_rgb(&p.state))*f32(p.intensity)
    value:=[4]f32{linear.x,linear.y,linear.z,p.alpha}
    bytes:=mem.ptr_to_bytes(&value)[:p.channels>3?16:12]
    if p.held!=0 {
        if p.stepped && ins.gesture!=p.key && !gesture_begin(s,p.key,"Color") {return}
        held_put(ins,p.held,p.offset,bytes)
        return
    }
    if ins.gesture!=p.key && !gesture_begin(s,p.key,"Color") {return}
    if p.storage>0 {
        setting_write(s,p.storage-1,p.offset,bytes)
        return
    }
    if p.table<0 || p.table>=len(w.info.tables) {return}
    t:=&w.info.tables[p.table]
    table:=core.world_table_at(w,t)
    targets:=make([dynamic]core.Entity,context.temp_allocator)
    for e in s.selection.entities {
        if core.raw_find(table,t.info,e)!=nil {append(&targets,e)}
    }
    field_write(s,t,targets[:],p.offset,bytes)
}

// A reference to an entity: its name selects it, the x clears it, the + waits
// for a click on the scene or on the outliner, and a row dropped on it sets it.
@(private)
entity_row :: proc(c:^Inspect,label:string,offset:int,key:u64) {
    s:=c.s
    g:=s.gui
    ctx:=g.ctx
    th:=&ctx.theme
    w:=c.w
    referred:=(cast(^core.Entity)&c.value[offset])^
    row_begin(ctx,label)
    waiting:=s.viewport.pick.active && s.viewport.pick.table==c.index && s.viewport.pick.offset==offset
    if entity_alive(w,referred) {
        icon,color:=entity_icon(s,w,referred)
        id:=ui.id(ctx,"entity",offset+1)
        it:=ui.button(ctx,id,{label=entity_label(w,referred),icon=icon,icon_color=color,style=.Field,width=-1,size=th.font_small})
        if rect,found:=ui.widget_rect(ctx,id);found && g.drag.kind==.Entity && drag_dropped(g,rect) {inspect_entity_set(c,offset,g.drag.entity)}
        if ui.button(ctx,ui.id(ctx,"entity_clear",offset+1),{icon=.Cross,style=.Ghost,width=th.row,height=th.row}).clicked || it.right {
            inspect_entity_set(c,offset,core.NONE)
        } else if it.clicked {
            history.selection_set(s.selection,{referred})
            outliner_reveal(s.outliner,w,referred)
        }
    } else {
        id:=ui.id(ctx,"entity_pick",offset+1)
        // An entity of a section that is not loaded: what the field names stays until it loads.
        pending:=base.Entity_Id(0)
        if len(c.entities)>0 {pending=scene.unresolved_target(core.world_storage_of(w,scene.Unresolved_References),c.entities[len(c.entities)-1],base.name_hash(c.t.name),u32(offset))}
        if pending!=0 {
            if ui.button(ctx,id,{label=fmt.tprintf("In a section not loaded (%016x)",u64(pending)),icon=.Link,icon_color=SECTION_COLOR,style=.Field,width=-1,size=th.font_small,active=waiting}).clicked {
                g.placement={}
                s.viewport.pick=waiting?{}:{active=true,table=c.index,offset=offset}
            }
        } else if ui.button(ctx,id,{icon=.Plus,style=.Field,width=-1,height=th.row,active=waiting}).clicked {
            g.placement={}
            s.viewport.pick=waiting?{}:{active=true,table=c.index,offset=offset}
        }
        if rect,found:=ui.widget_rect(ctx,id);found && g.drag.kind==.Entity && drag_dropped(g,rect) {inspect_entity_set(c,offset,g.drag.entity)}
    }
    row_end(ctx)
}

@(private)
entity_field_set :: proc(s:^Session,t:^core.Table_Info,entities:[]core.Entity,offset:int,e:core.Entity) {
    value:=e
    field_write(s,t,entities,offset,mem.ptr_to_bytes(&value))
    // What the field waited for in a section is replaced.
    unresolved:=core.world_storage_of(edited_world(s),scene.Unresolved_References)
    for e in entities {scene.unresolved_forget(unresolved,e,base.name_hash(t.name),u32(offset))}
}

// The entity chosen for the reference that waits for one.
inspector_pick_finish :: proc(s:^Session,w:core.World_Ref,e:core.Entity) {
    v:=s.viewport
    if v.pick.active && v.pick.kind!=.Field {
        target:=v.pick.owner
        child,parent:=target,e
        if v.pick.kind==.Children {child,parent=e,target}
        if !entity_reparent(s,child,parent) {notify(s,"The entity could not be reparented")}
        v.pick={}
        return
    }
    if !v.pick.active || v.pick.table<0 || v.pick.table>=len(w.info.tables) {
        v.pick={}
        return
    }
    t:=&w.info.tables[v.pick.table]
    table:=core.world_table_at(w,t)
    targets:=make([dynamic]core.Entity,context.temp_allocator)
    for selected in s.selection.entities {
        if core.raw_find(table,t.info,selected)!=nil {append(&targets,selected)}
    }
    entity_field_set(s,t,targets[:],v.pick.offset,e)
    v.pick={}
}

// The thumbnail of a field that references an asset, as in Unreal: its
// preview with the border and the line of the color of its kind, also while
// it is empty. A double click opens the asset in its editor, a prefab in its
// tab. quad, icon: what it shows instead, as a shape of the engine.
@(private)
asset_field_thumbnail :: proc(s:^Session,id:ui.Id,kind:asset.Fourcc,value:base.Asset_Id,side:f32,quad:ui.Quad={},icon:ui.Icon=.None) {
    ctx:=s.gui.ctx
    th:=&ctx.theme
    it:=ui.interact(ctx,id,{.Focusable})
    file:^asset.Registry_File
    if value!={} && s.app.assets!=nil {file,_=asset.registry_find(&s.app.assets.registry,value)}
    if ui.box(ctx,{id=id,width=ui.fixed(side),height=ui.fixed(side)}) {
        if file!=nil && quad.kind==.Solid && icon==.None {asset_thumbnail(s,file,side,hot=it.hot)} else {
            color:=asset_kind_color(s,kind)
            asset_frame(s,side,color,ui.color_alpha(color,140 if it.hot else 77),1,quad,icon,th.text_muted,kind)
        }
    }
    if it.double && file!=nil && s.mode!=.Play {
        switch {
        case asset_document_opens(s,file.kind):
            content_used(s,file.id)
            asset_document_open(s,file.id)
        case asset.registry_prefab(file) && s.mode==.Edit:
            content_used(s,file.id)
            file_open_path(s,file.path)
        }
    }
}

// The magnifier that shows the asset of a field in the content browser.
@(private)
asset_field_find :: proc(s:^Session,id:ui.Id,value:base.Asset_Id) {
    ctx:=s.gui.ctx
    found:=false
    if value!={} && s.app.assets!=nil {_,found=asset.registry_find(&s.app.assets.registry,value)}
    if ui.button(ctx,id,{icon=ui.icon_user(u8(User_Icon.Search)),icon_color=ctx.theme.text_muted,tip="Find in Content Browser",style=.Ghost,width=22,height=22,disabled=!found}).clicked && found {content_reveal(s,value)}
}

// Plays the sound of a field to be heard, or stops it. That of an
// Audio_Source plays as the source is set, and follows it while it plays.
@(private)
asset_field_hear :: proc(c:^Inspect,id:ui.Id,value:base.Asset_Id) {
    s:=c.s
    ctx:=s.gui.ctx
    source:=eaudio.Audio_Source{sound=value,bus=eaudio.BUS_MASTER,volume=1,pitch=1}
    if c.type==eaudio.Audio_Source && c.size==size_of(eaudio.Audio_Source) {
        source=(cast(^eaudio.Audio_Source)c.value)^
        source.sound=value
    }
    heard:=sound_heard(s,value)
    if heard {sound_hear_tune(s,source)}
    if !ui.button(ctx,id,{icon=heard?.Stop:.Play,icon_color=ctx.theme.text_muted,tip=heard?"Stop sound":"Play sound",style=.Ghost,width=22,height=22,disabled=value=={} || s.app.mixer==nil}).clicked {return}
    if heard {
        sound_hear_stop(s)
    } else if !sound_hear_source(s,source) {
        notify(s,"It did not play: the sound does not load, or a set has no sound that does")
    }
}

// While an asset is dragged over a field: tinted with the color of its kind
// when it takes it, faded when it is of another kind. Over the rectangle of
// the last frame, as drag_over.
@(private)
asset_field_drop_look :: proc(s:^Session,id:ui.Id,kinds:Asset_Kinds) -> (fill,stroke:ui.Color,faded:bool) {
    g:=s.gui
    rect,found:=ui.widget_rect(g.ctx,id)
    if !found || g.drag.kind!=.Asset || !drag_over(g,rect) {return}
    if !asset_kind_takes(kinds,g.drag.asset_kind) {return {},{},true}
    color:=asset_kind_color(s,kinds[0])
    return ui.color_alpha(color,40),color,false
}

// A dropped asset: the one of its kind, or a notice that says what the field takes.
@(private)
asset_field_dropped :: proc(s:^Session,id:ui.Id,kinds:Asset_Kinds,label:string) -> (dropped:base.Asset_Id,ok:bool) {
    g:=s.gui
    rect,found:=ui.widget_rect(g.ctx,id)
    if !found || g.drag.kind!=.Asset || !drag_dropped(g,rect) {return}
    if !asset_kind_takes(kinds,g.drag.asset_kind) {
        taken:=strings.builder_make(context.temp_allocator)
        for kind,i in kinds {
            if kind==0 {break}
            if i>0 {strings.write_string(&taken," or ")}
            strings.write_string(&taken,strings.to_lower(asset_kind_label(s,kind),context.temp_allocator))
        }
        notify(s,fmt.tprintf("%s takes a %s",label,strings.to_string(taken)))
        return
    }
    content_used(s,g.drag.asset_id)
    return g.drag.asset_id,true
}

// A reference to an asset: its thumbnail, a button with its name that opens
// the list of the assets of its kinds (None first) and the magnifier that
// shows it in the content browser. An asset of its kinds dropped on it is
// assigned; one of another kind is refused.
@(private)
asset_row :: proc(c:^Inspect,label:string,kinds:Asset_Kinds,offset:int,key:u64,with:="") {
    s:=c.s
    ctx:=s.gui.ctx
    th:=&ctx.theme
    id_value:=(cast(^base.Asset_Id)&c.value[offset])^
    shown:="None"
    if id_value!={} {
        shown=asset_name(asset_path(s,id_value))
        if shown=="" {shown="Missing"}
    }
    row:=ui.id(ctx,"asset_row",offset+1)
    fill,stroke,faded:=asset_field_drop_look(s,row,kinds)
    if ui.box(ctx,{id=row,width=ui.GROW,height=ui.fixed(MATERIAL_ROW+2),gap=4,align_y=.Center,fill=fill,stroke=stroke,stroke_width=1,radius=4,track=true,layer={enabled=faded,opacity=0.45}}) {
        ui.column_label(ctx,label)
        asset_field_thumbnail(s,ui.id(ctx,"asset_thumb",offset+1),kinds[0],id_value,MATERIAL_ROW)
        id:=ui.id(ctx,"asset",offset+1)
        open:=s.inspector.list.key==key
        if ui.button(ctx,id,{label=shown,icon=.Chevron_Down,icon_after=true,icon_color=th.text_muted,icon_size=13,style=.Well,width=-1,height=MATERIAL_ROW,size=th.font_small,padding=7,active=open}).clicked && !open {
            anchor,_:=ui.widget_rect(ctx,id)
            list_open(s,{key=key,table=c.index,storage=c.storage,held=c.held,offset=offset,kinds=kinds,with=with!=""},anchor)
            if with!="" {prefabs_with(s,with,&s.inspector.list_with)}
        }
        if kinds[0]==asset.KIND_SOUND {asset_field_hear(c,ui.id(ctx,"asset_hear",offset+1),id_value)}
        asset_field_find(s,ui.id(ctx,"asset_find",offset+1),id_value)
    }
    if dropped,ok:=asset_field_dropped(s,row,kinds,label);ok {inspect_write(c,offset,mem.ptr_to_bytes(&dropped))}
}

// The row of an asset of a kind at offset of what the rows show, as
// asset_row draws one, for a plugin that lays out its own rows: quad is what
// it shows while it has none. opened: its list opened this frame, so that
// the caller writes what goes with the asset before the list writes it.
asset_pick_row :: proc(c:^Inspect,label:string,kind:asset.Fourcc,offset:int,key:u64,quad:ui.Quad={}) -> (opened:bool) {
    s:=c.s
    ctx:=s.gui.ctx
    th:=&ctx.theme
    id_value:=(cast(^base.Asset_Id)&c.value[offset])^
    shown:="Pack"
    if id_value!={} {
        shown=asset_name(asset_path(s,id_value))
        if shown=="" {shown="Missing"}
    }
    row:=ui.id(ctx,"asset_row",offset+1)
    fill,stroke,faded:=asset_field_drop_look(s,row,{0=kind})
    if ui.box(ctx,{id=row,width=ui.GROW,height=ui.fixed(MATERIAL_ROW+2),gap=4,align_y=.Center,fill=fill,stroke=stroke,stroke_width=1,radius=4,track=true,layer={enabled=faded,opacity=0.45}}) {
        ui.column_label(ctx,label)
        asset_field_thumbnail(s,ui.id(ctx,"asset_thumb",offset+1),kind,id_value,MATERIAL_ROW,quad if id_value=={} else {})
        id:=ui.id(ctx,"asset",offset+1)
        open:=s.inspector.list.key==key
        if ui.button(ctx,id,{label=shown,icon=.Chevron_Down,icon_after=true,icon_color=th.text_muted,icon_size=13,style=.Well,width=-1,height=MATERIAL_ROW,size=th.font_small,padding=7,active=open}).clicked && !open {
            anchor,_:=ui.widget_rect(ctx,id)
            list_open(s,{key=key,table=c.index,storage=c.storage,held=c.held,offset=offset,kinds={0=kind}},anchor)
            opened=true
        }
    }
    if dropped,ok:=asset_field_dropped(s,row,{0=kind},label);ok {
        opened=true
        inspect_write(c,offset,mem.ptr_to_bytes(&dropped))
    }
    return
}

// A text that names an asset of its kinds by its path under the assets folder,
// as asset_row shows a reference: the list offers the assets of the project.
@(private)
asset_path_row :: proc(c:^Inspect,label:string,kinds:Asset_Kinds,offset,count:int,key:u64) {
    s:=c.s
    ctx:=s.gui.ctx
    th:=&ctx.theme
    path:=base.text_get(c.value[offset:][:count])
    value:base.Asset_Id
    shown:="None"
    if path!="" {
        shown=asset_name(path)
        if s.app.assets!=nil {
            if file,found:=asset.registry_find_path(&s.app.assets.registry,path);found {value=file.id} else {shown="Missing"}
        }
    }
    ui.box_begin(ctx,{width=ui.GROW,height=ui.fixed(MATERIAL_ROW+2),gap=4,align_y=.Center})
    ui.column_label(ctx,label)
    asset_field_thumbnail(s,ui.id(ctx,"asset_thumb",offset+1),kinds[0],value,MATERIAL_ROW)
    id:=ui.id(ctx,"asset",offset+1)
    open:=s.inspector.list.key==key
    if ui.button(ctx,id,{label=shown,icon=.Chevron_Down,icon_after=true,icon_color=th.text_muted,icon_size=13,style=.Well,width=-1,height=MATERIAL_ROW,size=th.font_small,padding=7,active=open}).clicked && !open {
        anchor,_:=ui.widget_rect(ctx,id)
        list_open(s,{key=key,table=c.index,storage=c.storage,held=c.held,offset=offset,kinds=kinds,path=count},anchor)
    }
    asset_field_find(s,ui.id(ctx,"asset_find",offset+1),value)
    ui.box_end(ctx,{})
}

// The prefabs of the registry that have a component named name, as read
// once when a list opens: a body for a seat is a prefab with a Drivable.
@(private)
prefabs_with :: proc(s:^Session,name:string,into:^[dynamic]base.Asset_Id) {
    clear(into)
    if s.app.assets==nil {return}
    reader:Prefab_Reader
    prefab_reader_begin(s,&reader)
    defer prefab_reader_end(&reader)
    for &file in s.app.assets.registry.files {
        if !asset.registry_prefab(&file) {continue}
        if scene,error:=asset.resolver_take(&reader.resolver,file.id);error==.None && scene!=nil {
            if _,found:=asset.scene_component(scene,name);found {append(into,file.id)}
        }
    }
}

// Whether a path of the registry is a file of the assets folder, not of a mount.
@(private)
asset_under_root :: proc(r:^asset.Registry,path:string) -> bool {
    for mount in r.mounts {
        if len(path)>len(mount.prefix) && path[len(mount.prefix)]=='/' && strings.has_prefix(path,mount.prefix) {return false}
    }
    return true
}

FIELD_KINDS :: 4 // of asset one Asset_Id field takes

// The kinds of asset a field takes, the first for its look while empty; none: every kind.
Asset_Kinds :: [FIELD_KINDS]asset.Fourcc

// Whether a field takes an asset shown as a kind (shown_kind): any when it
// names none, a .sound_set where a .sound goes, since it plays as one, and a
// prefab where a scene goes, since it is one; a field of prefabs takes only
// the scenes with one root.
asset_kind_takes :: proc "contextless" (field:Asset_Kinds,kind:asset.Fourcc) -> bool {
    if field[0]==0 {return true}
    for each in field {
        if each!=0 && (kind==each || each==asset.KIND_SOUND && kind==asset.KIND_SOUND_SET || each==asset.KIND_SCENE && kind==SHOWN_PREFAB) {return true}
    }
    return false
}

// The kinds of asset a field takes: the extensions its tag names, apart by
// spaces (`kind=.anim .match`), each of the engine or one a plugin declares
// (Asset_Kind_Provider), and the word prefab for the scenes with one root
// (`kind=prefab`); without one known, what its name suggests.
field_asset_kinds :: proc(s:^Session,tag:reflect.Struct_Tag,name:string) -> (kinds:Asset_Kinds) {
    if extensions,found:=core.field_option(tag,"kind");found {
        count:=0
        for extension in strings.fields_iterator(&extensions) {
            kind,known:=asset.kind_of_extension(extension)
            if extension=="prefab" {kind,known=SHOWN_PREFAB,true}
            if !known {
                if declared:=asset_plugin_kind_of_extension(s,extension);declared!=nil {kind,known=declared.kind,true}
            }
            if known && count<len(kinds) {kinds[count]=kind;count+=1}
        }
        if count>0 {return}
    }
    kinds[0]=asset_kind_of_field(s,name)
    return
}

// The kind of asset a field names, by its name: a word of a kind of a
// plugin (Asset_Kind.field) first.
asset_kind_of_field :: proc(s:^Session,name:string) -> asset.Fourcc {
    lower:=strings.to_lower(name,context.temp_allocator)
    if kind,found:=asset_kind_of_word(s,lower);found {return kind}
    switch {
    case strings.contains(lower,"font"):     return asset.KIND_FONT
    case strings.contains(lower,"prompt"):   return asset.KIND_PROMPTS
    case strings.contains(lower,"strings"),strings.contains(lower,"texts"),strings.contains(lower,"locali"): return asset.KIND_STRINGS
    case strings.contains(lower,"mesh"):     return asset.KIND_MESH
    case strings.contains(lower,"material"): return asset.KIND_MATERIAL
    case strings.contains(lower,"texture"),strings.contains(lower,"image"): return asset.KIND_TEXTURE
    case strings.contains(lower,"prefab"):   return SHOWN_PREFAB
    case strings.contains(lower,"scene"):    return asset.KIND_SCENE
    case strings.contains(lower,"sound"),strings.contains(lower,"audio"),strings.contains(lower,"clip"): return asset.KIND_SOUND
    case strings.contains(lower,"anim"):     return asset.KIND_ANIMATION
    case strings.contains(lower,"widget"),strings.contains(lower,"interface"): return asset.KIND_UI
    }
    return 0
}

@(private) ADD_COMPONENT_KEY :: u64(0x6164645f636f6d70)
@(private) ASSET_LIST_ROW :: f32(32) // a row of the list of assets of a field, with the preview of each

@(private)
list_popup :: proc(g:^Editor_Ui) -> ui.Id {return shell_id(g,"choice_list")}

@(private)
list_open :: proc(s:^Session,list:Choice_List,anchor:ui.Rect) {
    s.inspector.geometry_choice={}
    s.inspector.list=list
    ui.popup_open(s.gui.ctx,list_popup(s.gui),anchor)
}

// The list of assets for a field, or of the components to add.
@(private)
list_build :: proc(s:^Session,w:core.World_Ref) {
    ins:=s.inspector
    l:=&ins.list
    if l.key==0 {return}
    g:=s.gui
    ctx:=g.ctx
    th:=&ctx.theme
    popup:=list_popup(g)
    if !ui.popup_is_open(ctx,popup) {
        l^={}
        return
    }
    choices:=make([dynamic]string,context.temp_allocator)
    tables:=make([dynamic]int,context.temp_allocator)
    ids:=make([dynamic]base.Asset_Id,context.temp_allocator)
    shapes:=make([dynamic]erender.Shape,context.temp_allocator)
    icons:=SHAPE_ICONS
    filter,_:=ui.popup_search(ctx,popup)
    if l.key==ADD_COMPONENT_KEY {
        active:=history.selection_active(s.selection)
        for &t,index in w.info.tables {
            if t.place!=.World || !inspector_visible(s,&t) {continue}
            if core.raw_find(core.world_table_at(w,&t),t.info,active)!=nil {continue}
            label:=readable(t.name)
            if !base.contains_fold(label,filter) {continue}
            append(&choices,label)
            append(&tables,index)
        }
    } else {
        if l.geometry {
            for shape in erender.Shape {
                if shape==.None {continue}
                label:=fmt.tprint(shape)
                if !base.contains_fold(label,filter) {continue}
                append(&choices,label);append(&ids,base.Asset_Id{});append(&shapes,shape)
            }
        } else {
            append(&choices,"None")
            append(&ids,base.Asset_Id{})
            append(&shapes,erender.Shape.None)
        }
        if a:=s.app.assets;a!=nil {
            // The parts of imports, which the browser hides, after the rest.
            parts:=make([dynamic]^asset.Registry_File,context.temp_allocator)
            for &file in a.registry.files {
                if file.state!=.Asset || !asset_kind_takes(l.kinds,shown_kind(&file)) || !asset.registry_listed(&file) || !base.contains_fold(file.path,filter) {continue}
                if l.path>0 && (len(file.path)>=l.path || !asset_under_root(&a.registry,file.path)) {continue}
                if l.with && !slice.contains(ins.list_with[:],file.id) {continue}
                if content_part(&a.registry,&file) {
                    append(&parts,&file)
                    continue
                }
                append(&choices,asset_name(file.path))
                append(&ids,file.id)
                append(&shapes,erender.Shape.None)
            }
            for file in parts {
                append(&choices,asset_name(file.path))
                append(&ids,file.id)
                append(&shapes,erender.Shape.None)
            }
        }
    }
    row_height:=th.row if l.key==ADD_COMPONENT_KEY else ASSET_LIST_ROW
    shown:=f32(clamp(len(choices),1,10))*row_height
    chosen:=-1
    if ui.popup(ctx,popup,{width=260,search="Search"}) {
        ui.id_push(ctx,popup)
        if _,changed:=ui.popup_search(ctx,popup);changed {l.scroll=0}
        rows:=ui.id(ctx,"rows")
        first,last:=ui.list_begin(ctx,rows,&l.scroll,len(choices),row_height,shown)
        for index in first..<last {
            r:=ui.Row{label=choices[index],height=row_height}
            if l.key!=ADD_COMPONENT_KEY {
                kind:=asset.Fourcc(0)
                file:^asset.Registry_File
                if ids[index]!={} {
                    found:bool
                    file,found=asset.registry_find(&s.app.assets.registry,ids[index])
                    if found {kind=shown_kind(file);r.detail=file.path} else {file=nil}
                }
                r.icon,r.icon_color=asset_icon(s,kind)
                if file!=nil {
                    if _,_,quad:=content_preview(s,file,row_height);quad.kind!=.Solid {r.icon,r.quad=.None,quad}
                }
                if l.geometry && shapes[index]!=.None {r.icon,r.icon_color=icons[shapes[index]],MESH_COLOR}
            }
            if ui.row(ctx,ui.id(ctx,"row",index+1),r).clicked {chosen=index}
        }
        ui.list_end(ctx,rows,len(choices),last,row_height)
        ui.id_pop(ctx)
    }
    if chosen<0 {return}
    ui.popup_close(ctx,popup)
    if l.key!=ADD_COMPONENT_KEY {content_used(s,ids[chosen])}
    if l.key==ADD_COMPONENT_KEY {
        t:=&w.info.tables[tables[chosen]]
        for e in s.selection.entities {
            if entity_alive(w,e) && core.raw_find(core.world_table_at(w,t),t.info,e)==nil {component_add(s,e,t)}
        }
    } else if l.field!=0 {
        ins.geometry_choice={l.field,shapes[chosen],ids[chosen]}
    } else {
        value:=ids[chosen]
        bytes:=mem.ptr_to_bytes(&value)
        if l.path>0 {
            bytes=make([]u8,l.path,context.temp_allocator)
            if file,found:=asset.registry_find(&s.app.assets.registry,value);found {copy(bytes[:l.path-1],file.path)}
        }
        switch {
        case l.held!=0:  held_put(ins,l.held,l.offset,bytes)
        case l.storage>0: setting_write(s,l.storage-1,l.offset,bytes)
        case l.table>=0 && l.table<len(w.info.tables):
            t:=&w.info.tables[l.table]
            targets:=make([dynamic]core.Entity,context.temp_allocator)
            for e in s.selection.entities {
                if core.raw_find(core.world_table_at(w,t),t.info,e)!=nil {append(&targets,e)}
            }
            field_write(s,t,targets[:],l.offset,bytes)
        }
    }
    l^={}
}

// The details of the selection as the panel on the right shows them, inside
// the panel of a plugin tool that takes its place.
details_build :: proc(s:^Session,w:core.World_Ref,width,max_height:f32) {
    read_only:=watching(s)
    if read_only {ui.disabled_begin(s.gui.ctx)}
    inspector_build(s,w,width,max_height)
    if read_only {ui.disabled_end(s.gui.ctx)}
}
