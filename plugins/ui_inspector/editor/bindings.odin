package ui_inspector_editor

import "base:runtime"
import "core:fmt"
import "core:slice"
import "core:strings"
import "mirai:asset"
import "mirai:cook/author"
import "mirai:core"
import "mirai:editor"
import "mirai:editor/api"
import "mirai:host"
import "mirai:std/base"
import "mirai:std/serial"
import "mirai:editor/kit"
import "mirai:ui"

// The bindings of the nodes: a path of the data of the game (ui.tree_bind)
// for what a node shows or does, chosen with the icon next to the property it
// takes the place of. The lists walk the types of the world of the editor;
// whether the game has a path is what ui.tree_instance_init says: the
// resolver the game runs. After every build the .ui of the project are
// checked against the types of the game, and ui.check says what failed.


PICK_DEPTH :: 3     // structs a list of paths goes into to find what a binding takes
PICK_RESULTS :: 60  // paths a search or a source in use lists

// A path as a person reads it: its parts with arrows between them.
path_shown :: proc(path:string) -> string {
    if path=="" {return ""}
    shown,_:=strings.replace_all(path,"."," > ",context.temp_allocator)
    return shown
}

// A .ui as the check of the project read it last: the stamp of its file and
// the widgets it names, checked_uses[first:][:count].
Ui_Checked :: struct {
    id:base.Asset_Id,
    stamp:[2]i64,
    first,count:int,
}

// The .ui of the project checked again when the game is another build, or
// when they change: only those whose file changed and those that use them.
// What fails is said once.
@(step="ui",after="editor_panels")
ui_bindings_check :: proc(s:^editor.Session,u:^Ui_Inspector,app:^host.App) {
    a:=app.assets
    if a==nil || app.info==nil || s.gui==nil || !s.gui.begun || editor.playing(s) {return}
    if u.checked_info==app.info && u.checked_revision==a.revision {return}
    first:=u.checked_info==nil
    all:=u.checked_info!=app.info
    u.checked_info,u.checked_revision=app.info,a.revision
    if u.problems.allocator.procedure==nil {
        u.problems=make([dynamic]author.Bind_Problem,app.allocator)
        u.checked=make([dynamic]Ui_Checked,app.allocator)
        u.checked_uses=make([dynamic]base.Asset_Id,app.allocator)
    }
    before:=bind_files(u.problems[:])
    if !bind_check_changed(u,app.allocator,a,app.info,all) {return}
    if files:=bind_files(u.problems[:]);files>0 && (files!=before || first) {
        names:=make([dynamic]string,context.temp_allocator)
        for &problem in u.problems {
            if name:=editor.asset_name_of(a,problem.asset,"missing");!author.slice_has(names[:],name) {append(&names,name)}
        }
        editor.notify(s,fmt.tprintf("%d interfaces bind paths the game does not have or do not load: %s",files,strings.join(names[:],", ",context.temp_allocator)))
    }
}

// How many .ui the problems are of.
@(private)
bind_files :: proc(problems:[]author.Bind_Problem) -> (files:int) {
    for &problem,i in problems {
        earlier:=false
        for &other in problems[:i] {earlier|=other.asset==problem.asset}
        files+=int(!earlier)
    }
    return
}

// Checks the .ui whose file changed since the last check (all: every one),
// and those that use them through their widgets. False when none did.
@(private)
bind_check_changed :: proc(u:^Ui_Inspector,allocator:runtime.Allocator,a:^host.Assets,info:^core.World_Info,all:bool) -> bool {
    dirty:=make([dynamic]base.Asset_Id,context.temp_allocator)
    checked :: proc(u:^Ui_Inspector,id:base.Asset_Id) -> int {
        for &c,i in u.checked {if c.id==id {return i}}
        return -1
    }
    for &file in a.registry.files {
        if file.kind!=asset.KIND_UI || file.id=={} {continue}
        at:=checked(u,file.id)
        if all || at<0 || u.checked[at].stamp!=([2]i64{file.size,file.time}) {append(&dirty,file.id)}
    }
    for &c in u.checked {
        if file,found:=asset.registry_find(&a.registry,c.id);!found || file.kind!=asset.KIND_UI {append(&dirty,c.id)}
    }
    // Those that use a changed one, through as many widgets as they go.
    for grew:=len(dirty)>0;grew; {
        grew=false
        for &c in u.checked {
            if slice.contains(dirty[:],c.id) {continue}
            for use in u.checked_uses[c.first:][:c.count] {
                if slice.contains(dirty[:],use) {append(&dirty,c.id);grew=true;break}
            }
        }
    }
    if len(dirty)==0 {return false}
    for i:=len(u.problems)-1;i>=0;i-=1 {
        if slice.contains(dirty[:],u.problems[i].asset) {ordered_remove(&u.problems,i)}
    }
    kept:=make([dynamic]Ui_Checked,context.temp_allocator)
    uses:=make([dynamic]base.Asset_Id,context.temp_allocator)
    for c in u.checked {
        if slice.contains(dirty[:],c.id) {continue}
        moved:=c
        moved.first=len(uses)
        append(&uses,..u.checked_uses[c.first:][:c.count])
        append(&kept,moved)
    }
    clear(&u.checked);clear(&u.checked_uses)
    append(&u.checked,..kept[:])
    append(&u.checked_uses,..uses[:])
    for id in dirty {
        file,found:=asset.registry_find(&a.registry,id)
        if !found || file.kind!=asset.KIND_UI {continue}
        entry:=Ui_Checked{id=id,stamp={file.size,file.time},first=len(u.checked_uses)}
        records:author.Records
        if author.records_read(author.assets_of(a),id,&records,context.temp_allocator) {
            for &template in records.components {
                if template.widget!={} {append(&u.checked_uses,template.widget)}
            }
        }
        entry.count=len(u.checked_uses)-entry.first
        append(&u.checked,entry)
        author.bind_check_file(&u.problems,&u.bind_types,allocator,author.assets_of(a),info,id)
    }
    return true
}
// Whether the game lacks what a binding of the node chosen names.
@(private)
bind_failing :: proc(u:^Ui_Inspector,binding:ui.Binding) -> bool {
    for &problem in u.problem[:u.problem_count] {
        if problem.fault==.Path && problem.row==u.selected && problem.binding==binding {return true}
    }
    return false
}
// Where the paths of a widget that start with @ start: the data an
// interface of the project gives one of its instances. Sources: none does.
widget_scope :: proc(u:^Ui_Inspector,a:^host.Assets,info:^core.World_Info) -> author.Path_Scope {
    if u.widget_scope_id==u.id && u.widget_scope_revision==a.revision && u.widget_scope_info==info {return u.widget_scope}
    u.widget_scope_id,u.widget_scope_revision,u.widget_scope_info=u.id,a.revision,info
    u.widget_scope=author.widget_scope_of(author.assets_of(a),info,u.id)
    return u.widget_scope
}
// ---------------------------------------------------------------- the rows

// A property a path of the game can take: unbound, the row of its own value,
// which the caller builds when this returns true; bound, the path in place of
// it. The icon after it chooses the path.
@(private,deferred_in_out=bindable_end)
bindable :: proc(p:^Pane,label:string,field:[]u8,kind:author.Bind_Kind,about:="") -> (free:bool) {
    path:=serial.text_field(field)
    p.bind_open=false
    if !shown_either(p,label,path) {return false}
    p.bind_open=true
    ctx:=p.s.gui.ctx
    ui.id_push(ctx,ui.id(ctx,"bind",int(ui.id(ctx,label)&0x7fffffff)))
    ui.box_begin(ctx,{width=ui.GROW,height=ui.FIT,gap=2,align_y=.Center})
    if path=="" {
        ui.box_begin(ctx,{width=ui.GROW,height=ui.FIT,direction=.Column})
        return true
    }
    row:=ui.id(ctx,"bound")
    ui.box_begin(ctx,{id=row,width=ui.GROW,height=ui.fixed(ui.metric(ctx,"row")),gap=4,align_y=.Center,track=about!=""})
    kit.column_label(ctx,label)
    editor.row_description(p.s,row,about)
    failing:=bind_failing(p.u,bind_binding(p,field))
    chip:=ui.id(ctx,"path")
    if ui.button(ctx,chip,{label=path_shown(path),icon=.Link,icon_size=12,icon_color=ui.tone(ctx,"danger") if failing else ui.tone(ctx,"accent"),variant="field",width=-1,height=ui.metric(ctx,"row"),size=ui.metric(ctx,"font_small"),padding=6}).clicked {
        bind_pick_open(p,ctx,chip,kind)
    }
    if ui.button(ctx,ui.id(ctx,"unbind"),{icon=.Cross,icon_size=10,icon_color=ui.tone(ctx,"text_muted"),tip="Unbind",variant="ghost",width=editor.REVERT_SIDE,height=editor.REVERT_SIDE}).clicked {
        if n:=selected_node(p.u);n!=nil {author.node_unbind(n,field)} else {for &b in field {b=0}}
        changed(p.u,"Unbind")
    }
    ui.box_end(ctx,{})
    return false
}
@(private)
bindable_end :: proc(p:^Pane,label:string,field:[]u8,kind:author.Bind_Kind,about:string,free:bool) {
    if !p.bind_open {return}
    p.bind_open=false
    ctx:=p.s.gui.ctx
    if free {ui.box_end(ctx,{})}
    bound:=serial.text_field(field)!=""
    button:=ui.id(ctx,"pick")
    if ui.button(ctx,button,{icon=.Link,icon_size=13,icon_color=ui.tone(ctx,"accent") if bound else ui.tone(ctx,"text_muted"),tip="Bind to a field of the game",variant="ghost",width=ui.metric(ctx,"row"),height=ui.metric(ctx,"row"),active=ui.popup_is_open(ctx,bind_popup(ctx))}).clicked {
        bind_pick_open(p,ctx,button,kind)
    }
    bind_pick(p,field,kind)
    ui.box_end(ctx,{})
    ui.id_pop(ctx)
}


// A binding the node has no value of its own for: its row says so until it is bound.
@(private)
bind_only :: proc(p:^Pane,label:string,field:[]u8,kind:author.Bind_Kind,about:="") -> (changes:bool) {
    if bindable(p,label,field,kind,about) {
        if row(p,label,about) {ui.label(p.s.gui.ctx,"Not bound",ui.metric(p.s.gui.ctx,"font_small"),ui.tone(p.s.gui.ctx,"text_faint"))}
    }
    return
}

// Which binding of the node chosen a field is.
@(private)
bind_binding :: proc(p:^Pane,field:[]u8) -> ui.Binding {
    n:=selected_node(p.u)
    if n==nil {return .Text}
    fields:=[ui.Binding][]u8{.Text=n.bind_text[:],.Value=n.bind_value[:],.Visible=n.bind_visible[:],.Selected=n.bind_selected[:],.Disabled=n.bind_disabled[:],
        .Items=n.bind_items[:],.Image=n.bind_image[:],.Tint=n.bind_tint[:],.Variant=n.bind_variant[:]}
    for f,binding in fields {if raw_data(f)==raw_data(field) {return binding}}
    return .Text
}

@(private)
bind_popup :: proc(ctx:^ui.Context) -> ui.Id {return ui.id(ctx,"bind_list")}

@(private)
bind_pick_open :: proc(p:^Pane,ctx:^ui.Context,anchor:ui.Id,kind:author.Bind_Kind) {
    rect,_:=ui.widget_rect(ctx,anchor)
    p.u.pick_length,p.u.pick_scroll=0,0
    ui.popup_open(ctx,bind_popup(ctx),rect)
}

// The list of the paths a binding can take, from where the node's paths
// start: a click on a source, a struct or an entity goes into it, one on a
// field the binding takes binds it.
@(private)
bind_pick :: proc(p:^Pane,field:[]u8,kind:author.Bind_Kind) {
    s,u:=p.s,p.u
    ctx:=s.gui.ctx
    popup:=bind_popup(ctx)
    if !ui.popup_is_open(ctx,popup) {return}
    info:=s.app.info
    a:=s.app.assets
    nodes:=scope_nodes(u)
    root,rooted:=author.node_scope(info,nodes,u.selected)
    data:=widget_scope(u,a,info) if a!=nil else author.Path_Scope{}
    if ui.popup(ctx,popup,{min_width=280,search="Search",side=.Below}) {
        needle,searched:=ui.popup_search(ctx,popup)
        if searched {u.pick_scroll=0}
        prefix:=string(u.pick_prefix[:u.pick_length])
        if !rooted {
            ui.label(ctx,"Bind the List around it to an array first",ui.metric(ctx,"font_small"),ui.tone(ctx,"text_muted"))
            return
        }
        scope:=root
        if prefix!="" {
            next,_,ok:=author.path_walk(info,root,prefix,data)
            if !ok {u.pick_length=0;prefix=""} else {scope=next}
        }
        pick :: proc(p:^Pane,field:[]u8,path:string) {
            ui.tree_text_set(field,path)
            changed(p.u,"Bind")
            ui.popup_close(p.s.gui.ctx)
        }
        if prefix!="" {
            back:=prefix[:max(strings.last_index_byte(prefix,'.'),0)]
            if prefix=="@" || !strings.contains(prefix,".") && !strings.has_prefix(prefix,"@") {back=""}
            if strings.has_prefix(prefix,"@") && !strings.contains(prefix,".") && prefix!="@" {back="@"}
            if ui.row(ctx,ui.id(ctx,"back"),{label=path_shown(prefix),icon=.Chevron_Up,icon_size=11,accent=true,height=ui.metric(ctx,"row")}).clicked {
                u.pick_length=copy(u.pick_prefix[:],back)
            }
            if kind==.Data && scope.kind!=.Sources {
                if ui.row(ctx,ui.id(ctx,"use"),{label=fmt.tprintf("Use %s",path_shown(prefix)),icon=.Check,icon_size=11,accent=true,height=ui.metric(ctx,"row")}).clicked {pick(p,field,prefix)}
            }
            ui.menu_separator(ctx)
        } else if data.kind!=.Sources {
            if ui.row(ctx,ui.id(ctx,"widget_data"),{label="Data of this widget",icon=.Prefab,icon_size=12,accent=true,height=ui.metric(ctx,"row")}).clicked {
                u.pick_length=copy(u.pick_prefix[:],"@")
            }
        }
        if ui.scroll_area(ctx,ui.id(ctx,"bind_rows"),&u.pick_scroll,{width=ui.GROW,height=ui.FIT,max_height=ADD_HEIGHT,direction=.Column}) {
            any:=false
            entries:=author.path_entries(info,scope,kind)
            leaves :: proc(p:^Pane,field:[]u8,paths:[]string,from:int) -> (picked,any:bool) {
                ctx:=p.s.gui.ctx
                for path,i in paths {
                    any=true
                    if ui.row(ctx,ui.id(ctx,"leaf",from+i+1),{label=path_shown(path),icon=.Link,icon_size=12,icon_color=ui.tone(ctx,"accent"),accent=true,height=ui.metric(ctx,"row")}).clicked {
                        ui.tree_text_set(field,path)
                        changed(p.u,"Bind")
                        ui.popup_close(ctx)
                        picked=true
                    }
                }
                return
            }
            if needle!="" {
                // A search finds the paths under this place by any of their names.
                found:=make([dynamic]string,context.temp_allocator)
                path_leaves(info,scope,kind,prefix,needle,&found,PICK_DEPTH)
                _,any=leaves(p,field,found[:],0)
            } else if scope.kind==.Sources && prefix=="" {
                // What the interface already reads comes first, field by field.
                used:=records_sources(&u.records,info)
                found:=make([dynamic]string,context.temp_allocator)
                for &e in entries {
                    if !author.slice_has(used,e.name) {continue}
                    path_leaves(info,e.next,kind,e.name,"",&found,PICK_DEPTH-1)
                }
                if len(found)>0 {
                    ui.menu_header(ctx,"In this interface")
                    _,any=leaves(p,field,found[:],0)
                }
            }
            // The places to go into that have something it takes: the game's, then the engine's.
            for game in ([2]bool{true,false}) {
                header:=false
                for &e,i in entries {
                    if e.game!=game && scope.kind!=.Struct {continue}
                    if scope.kind==.Struct && !game {break}
                    if needle!="" && !(e.navigable && base.contains_fold(e.name,needle)) {continue}
                    if !entry_offers(info,&e,kind,PICK_DEPTH) {continue}
                    if !header && scope.kind!=.Struct {
                        if any {ui.menu_separator(ctx)}
                        ui.menu_header(ctx,"Game" if game else "Engine")
                        header=true
                    }
                    any=true
                    icon:=ui.Icon.None
                    switch {
                    case e.storage:                icon=.Layers
                    case scope.kind!=.Struct:      icon=.Cube
                    case e.next.kind==.Entity && e.navigable: icon=.Link
                    case e.navigable:              icon=.Chevron_Right
                    }
                    if ui.row(ctx,ui.id(ctx,"entry",i+1),{label=e.name,detail="storage" if e.storage else "",icon=icon,icon_size=12,icon_color=ui.tone(ctx,"accent") if e.fits else ui.tone(ctx,"text_muted"),accent=true,height=ui.metric(ctx,"row")}).clicked {
                        if e.fits && !(e.navigable && kind==.Data) {pick(p,field,author.path_join(prefix,e.name))} else if e.navigable {
                            u.pick_length=copy(u.pick_prefix[:],author.path_join(prefix,e.name))
                            u.pick_scroll=0
                        }
                    }
                }
            }
            if !any {ui.label(ctx,"Nothing here this binding takes",ui.metric(ctx,"font_small"),ui.tone(ctx,"text_muted"))}
        }
    }
}
// Whether something under e is a path a binding of kind takes: e itself, or
// a field of the struct it leads to, depth structs down. An entity leads to
// every component, so it offers.
@(private)
entry_offers :: proc(info:^core.World_Info,e:^author.Path_Entry,kind:author.Bind_Kind,depth:int) -> bool {
    if e.fits {return true}
    if !e.navigable {return false}
    if e.next.kind==.Entity {return true}
    if depth<=0 {return false}
    for &f in author.path_entries(info,e.next,kind) {
        if entry_offers(info,&f,kind,depth-1) {return true}
    }
    return false
}

// The paths under scope a binding of kind takes, depth structs down (not
// through entities), each after prefix; with a needle, those that have it.
@(private)
path_leaves :: proc(info:^core.World_Info,scope:author.Path_Scope,kind:author.Bind_Kind,prefix,needle:string,list:^[dynamic]string,depth:int) {
    for &e in author.path_entries(info,scope,kind) {
        if len(list)>=PICK_RESULTS {return}
        if scope.kind==.Entity && e.storage {continue}
        path:=author.path_join(prefix,e.name)
        if e.fits && base.contains_fold(path,needle) {append(list,path)}
        if e.navigable && depth>0 && (e.next.kind==.Struct || scope.kind==.Sources) {
            path_leaves(info,e.next,kind,path,needle,list,depth-1)
        }
    }
}

// A row under the text for each name in its braces, with the path of the
// game it shows.
@(private)
text_field_rows :: proc(p:^Pane,n:^ui.Tree_Node) {
    ctx:=p.s.gui.ctx
    for name in author.text_field_names(author.records_text(&p.u.records,n.text)) {
        label:=strings.concatenate({"{",name,"}"},context.temp_allocator)
        // The name takes a field the first time; nothing changes until a path is chosen.
        at:=author.text_field_of(&p.u.records,n,name,true)
        if at<0 {
            if row(p,label) {ui.label(ctx,fmt.tprintf("At most %d names",ui.TREE_TEXT_FIELDS),ui.metric(ctx,"font_small"),ui.tone(ctx,"danger"))}
            continue
        }
        bind_only(p,label,n.fields[at].path[:],.Shown,"The field of the game this name of the text shows; every language of its key names it as the text does")
    }
}

// The sources the paths of the records start at.
@(private)
records_sources :: proc(r:^author.Records,info:^core.World_Info) -> []string {
    list:=make([dynamic]string,context.temp_allocator)
    add :: proc(list:^[dynamic]string,info:^core.World_Info,path:string) {
        if path=="" || strings.has_prefix(path,"@") {return}
        name:=path
        if dot:=strings.index_byte(path,'.');dot>=0 {name=path[:dot]}
        if author.slice_has(list[:],name) {return}
        for &e in author.path_entries(info,{kind=.Sources},.Data) {
            if e.name==name {append(list,name);return}
        }
    }
    each :: proc(list:^[dynamic]string,info:^core.World_Info,n:^ui.Tree_Node) {
        for field in author.node_paths(n) {add(list,info,serial.text_field(field))}
    }
    for &n in r.nodes {each(&list,info,&n)}
    for &o in r.overrides {each(&list,info,&o.values)}
    return list[:]
}

// Whether the row of label shows: the search finds its name or the path it
// binds. The card that waited for it opens.
@(private)
shown_either :: proc(p:^Pane,label,path:string) -> bool {
    if p.needle=="" || p.whole {return true}
    if path!="" && base.contains_fold(path,p.needle) {return shown(p,p.needle)}
    return shown(p,label)
}
// ---------------------------------------------------------------- the API

// Agents bind as a person does: ui.paths lists what a binding of a node takes
// from a prefix, ui.write sets it by the keys bind_*, data and fields of a
// node, ui.check says what the project's interfaces bind that the game does
// not have, and ui.path.rename follows a field the code renamed in every .ui.
@(storage)
Ui_Bind_Api :: struct {provider:editor.Api_Provider}
ui_bind_api_default :: proc() -> Ui_Bind_Api {return {provider={register=bind_api_register}}}

Ui_Paths_Params :: struct {
    asset:base.Asset_Id,
    node:[ui.TREE_NAME_CAPACITY]u8 `mirai:"text,label=Its name; the paths of a node inside a List start at its element"`,
    binding:[16]u8 `mirai:"text,label=Text; Value; Visible; Selected; Disabled; Items; Image; Tint; Variant; or Data: what a widget instance gives its @ paths"`,
    prefix:[ui.TREE_PATH_CAPACITY]u8 `mirai:"text,label=The path walked so far. Empty: the sources (the components of the entity the interface is for and the storages); past a struct its fields; past a field of type Entity the components of that entity"`,
}
Ui_Rename_Params :: struct {
    from:[ui.TREE_PATH_CAPACITY]u8 `mirai:"text,label=Each path that is it or starts with it and a dot starts with to instead"`,
    to:[ui.TREE_PATH_CAPACITY]u8 `mirai:"text"`,
}
Ui_Empty_Params :: struct {}

Ui_Paths_Result :: struct {
    scope:author.Path_Scope_Kind `mirai:"label=What the entries are: the sources; the fields of a struct; or the components of an entity"`,
    entries:[]Ui_Path_Entry,
}
Ui_Path_Entry :: struct {
    name:string `mirai:"label=@ is the data an instance of the widget gives it"`,
    path:string `mirai:"label=What prefix takes, and a bind_ key of ui.write"`,
    type:string `mirai:"optional,label=Its type in the game; @ has none"`,
    fits:bool `mirai:"label=Whether the binding takes it"`,
    navigable:bool `mirai:"label=Whether it is a prefix that goes on"`,
    storage:bool `mirai:"optional,label=A storage; absent: a component or a field"`,
}
Ui_Check_Result :: struct {
    problems:[]Ui_Check_Problem `mirai:"label=Each binding the game lacks once and each .ui that does not load; at most 16 by .ui"`,
}
Ui_Check_Problem :: struct {
    asset:string `mirai:"label=The name of the file of the .ui"`,
    node:string `mirai:"label=The node that fails: its name, or instance/node inside a widget; empty when it does not load"`,
    binding:string `mirai:"label=The binding that fails; Text (in braces) for a name in braces of the text; empty when it does not load"`,
    path:string `mirai:"label=What the binding names that the game does not have or cannot show there; empty for a name in braces or when it does not load"`,
    loads:bool `mirai:"label=False: it does not load because a widget it uses is missing or an override names a node its widget no longer has"`,
    message:string `mirai:"label=What fails for a person"`,
}
Ui_Rename_Result :: struct {
    files:[]string `mirai:"label=The paths of the .ui it changed; each waits for Save"`,
}

@(private)
bind_api_register :: proc(s:^editor.Session) {
    editor.api_method_register(s,{params=type_info_of(Ui_Paths_Params),result=type_info_of(Ui_Paths_Result),name="ui.paths",summary="Lists what a binding of a node of a .ui can take, one level of the data of the game at a time.",flags={.Read_Only},run=api_paths})
    editor.api_method_register(s,{params=type_info_of(Ui_Empty_Params),result=type_info_of(Ui_Check_Result),name="ui.check",summary="Checks every .ui of the project against the types of the game of this build: the paths they bind that the game lacks, the names of styles, tokens, components and parameters that resolve to nothing, and each .ui that does not load with why.",flags={.Read_Only},run=api_check})
    editor.api_method_register(s,{params=type_info_of(Ui_Rename_Params),result=type_info_of(Ui_Rename_Result),name="ui.path.rename",summary="Follows a field or a source the code renamed in the paths of every .ui: bindings, widget data and the fields of texts. One step of history per file.",run=api_rename})
}

@(private)
api_binding :: proc(text:string) -> (binding:ui.Binding,data,ok:bool) {
    if text=="Data" {return .Text,true,true}
    for b in ui.Binding {if fmt.tprintf("%v",b)==text {return b,false,true}}
    return
}

// The records of a .ui and the row of a node of its tree, by its name.
@(private)
api_node :: proc(s:^editor.Session,call:^api.Call,id:base.Asset_Id,name:string,records:^author.Records) -> (row:int,ok:bool) {
    a:=s.app.assets
    api_flush(s)
    if a==nil || !author.records_read(author.assets_of(a),id,records,context.temp_allocator) {
        api.call_failf(call,api.INVALID_PARAMS,"asset %v is not a .ui that loads; pass the id of a .ui of the project",id)
        return
    }
    for &n,i in records.nodes {if serial.text_field(n.name[:])==name {return i,true}}
    api.call_failf(call,api.INVALID_PARAMS,"the .ui has no node named '%s'; give the name a node of its tree has",name)
    return
}

@(private)
api_paths :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Ui_Paths_Params)
    binding,data,known:=api_binding(serial.text_field(p.binding[:]))
    if !known {api.call_fail(call,api.INVALID_PARAMS,"binding is one of Text, Value, Visible, Selected, Disabled, Items, Image, Tint, Variant or Data");return}
    records:author.Records
    row,ok:=api_node(s,call,p.asset,serial.text_field(p.node[:]),&records)
    if !ok {return}
    info:=s.app.info
    kind:=author.Bind_Kind.Data if data else author.bind_kind(binding,records.nodes[row].kind)
    widget:=author.widget_scope_of(author.assets_of(s.app.assets),info,p.asset)
    root,rooted:=author.node_scope(info,records.nodes[:],row,widget)
    if !rooted {api.call_fail(call,api.INVALID_PARAMS,"the node is inside a List that binds no array: bind its Items first");return}
    prefix:=serial.text_field(p.prefix[:])
    scope:=root
    if prefix!="" {
        next,_,walked:=author.path_walk(info,root,prefix,widget)
        if !walked || next.kind==.Sources && prefix!="" {api.call_failf(call,api.INVALID_PARAMS,"prefix '%s' is not a source, a struct or an entity of the game; walk it one name at a time from the entries ui.paths gives",prefix);return}
        scope=next
    }
    entries:=make([dynamic]Ui_Path_Entry,call.allocator)
    // What an instance of this widget gives it, which its @ paths read.
    if prefix=="" && widget.kind!=.Sources {append(&entries,Ui_Path_Entry{name="@",path="@",fits=author.type_fits(widget.info,kind),navigable=true})}
    for &e in author.path_entries(info,scope,kind) {
        if !e.navigable && !e.fits {continue}
        append(&entries,Ui_Path_Entry{name=e.name,path=author.path_join(prefix,e.name),type=fmt.tprintf("%v",e.info.id),fits=e.fits,navigable=e.navigable,storage=e.storage})
    }
    api.call_result(call,Ui_Paths_Result)^={scope.kind,entries[:]}
}

// Writes records as a step of the history of the document of their .ui. A
// tree the game would not load is not written: message says why.
@(private)
records_write :: proc(s:^editor.Session,id:base.Asset_Id,records:^author.Records,label:string) -> (message:string,ok:bool) {
    a:=s.app.assets
    api_flush(s)
    params:=author.widget_params(author.assets_of(a),id)
    bytes,imports,why,loads:=author.records_bytes(author.assets_of(a),id,records)
    if !loads {return why,false}
    return records_file_write(s,id,records,bytes,imports,params,label)
}
// Writes what records_bytes gave as a step of the history of the document of
// the .ui; params: those its widget had before, which its uses follow.
@(private)
records_file_write :: proc(s:^editor.Session,id:base.Asset_Id,records:^author.Records,bytes:[]u8,imports:[]ui.Tree_Data,params:[]ui.Tree_Param,label:string) -> (message:string,ok:bool) {
    a:=s.app.assets
    record,found:=asset.registry_find(&a.registry,id)
    if !found {return "the .ui is not in the assets",false}
    path:=asset.registry_file_path(&a.registry,record.path,context.temp_allocator)
    data:=author.records_data(records)
    written,opened:=false,false
    for &d in s.asset_documents {
        if d.id!=id || d.kind!=asset.KIND_UI {continue}
        written,opened=editor.asset_document_write(s,&d,path,bytes,label),true
        break
    }
    if !opened {written=editor.file_write(s,path,bytes,label)}
    if !written {return "the file could not be written",false}
    widget_params_follow(s,a,id,author.params_changes(params,author.data_params(data,imports)))
    return "",true
}

@(private)
api_check :: proc(s:^editor.Session,call:^api.Call) {
    a:=s.app.assets
    if a==nil || s.app.info==nil {api.call_fail(call,api.SERVER_ERROR,"the editor has no world or assets to check against");return}
    types:author.Bind_Types
    defer author.bind_types_free(&types)
    problems:=make([dynamic]author.Bind_Problem,context.temp_allocator)
    author.bind_check_all(&problems,&types,context.allocator,author.assets_of(a),s.app.info)
    result:=api.call_result(call,Ui_Check_Result)
    result.problems=make([]Ui_Check_Problem,len(problems),call.allocator)
    for &row,i in result.problems {
        problem:=&problems[i]
        row={node=strings.clone(serial.text_field(problem.name[:]),call.allocator),loads=problem.fault!=.Widget && problem.fault!=.Load,asset=author.file_name_of(author.assets_of(a),problem.asset,"missing"),message=author.bind_problem_text(author.assets_of(a),problem)}
        #partial switch problem.fault {
        case .Template: row.binding="Text (in braces)"
        case .Path: row.binding,row.path=fmt.tprintf("%v",problem.binding),strings.clone(serial.text_field(problem.path[:]),call.allocator)
        }
    }
}

@(private)
api_rename :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Ui_Rename_Params)
    api_flush(s)
    from,to:=serial.text_field(p.from[:]),serial.text_field(p.to[:])
    if from=="" || to=="" {api.call_fail(call,api.INVALID_PARAMS,"from and to are paths: Old_Name.field and New_Name.field");return}
    a:=s.app.assets
    if a==nil {api.call_fail(call,api.SERVER_ERROR,"the editor has no assets");return}
    files:=make([dynamic]string,call.allocator)
    for &file in a.registry.files {
        if file.kind!=asset.KIND_UI || file.id=={} {continue}
        records:author.Records
        if !author.records_read(author.assets_of(a),file.id,&records,context.temp_allocator) {continue}
        count:=0
        rename :: proc(field:[]u8,from,to:string) -> int {
            path:=serial.text_field(field)
            if path!=from && !strings.has_prefix(path,fmt.tprintf("%s.",from)) {return 0}
            renamed:=fmt.tprintf("%s%s",to,path[len(from):])
            if len(renamed)>=len(field) {return 0}
            ui.tree_text_set(field,renamed)
            return 1
        }
        each :: proc(n:^ui.Tree_Node,from,to:string) -> int {
            count:=0
            for f in author.node_paths(n) {count+=rename(f,from,to)}
            return count
        }
        for &n in records.nodes {count+=each(&n,from,to)}
        for &o in records.overrides {count+=each(&o.values,from,to)}
        if count==0 {continue}
        if _,written:=records_write(s,file.id,&records,"Rename path");!written {continue}
        append(&files,strings.clone(file.path,call.allocator))
    }
    api.call_result(call,Ui_Rename_Result).files=files[:]
}

