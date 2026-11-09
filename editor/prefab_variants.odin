package editor

import "core:fmt"
import "core:strings"
import "mirai:core"
import "mirai:std/base"
import "mirai:ui"

// The name of a new variant of a prefab, asked in a popup under the button
// that makes it: Save variant of an instance in Details, with what the
// instance changes, or the new variant of the prefab of the document. It is
// written beside its base between frames, as the other prefab actions.
Variant_Prompt :: struct {
    instance:core.Entity, // the root of the instance it saves; NONE: an empty variant of base
    base:base.Asset_Id,   // the prefab it is a variant of
    name:[128]u8,
    length:int,
    focus:bool,           // the name takes the keyboard on the next frame
    path:[1024]u8,        // what Variant_Create writes, inside the assets
    path_length:int,
}

PREFAB_VARIANT_ROWS :: 64 // of the menu of the family of a prefab

@(private)
variant_prompt_popup :: proc(g:^Editor_Ui) -> ui.Id {return shell_id(g,"variant_prompt")}

// Asks the name of a variant of base under the widget anchor; instance, when
// given, is saved as it with its changes.
@(private)
variant_prompt_open :: proc(s:^Session,anchor:ui.Id,base_id:base.Asset_Id,instance:=core.NONE) {
    g:=s.gui
    p:=&g.variant
    p^={instance=instance,base=base_id,focus=true}
    path:=prefab_variant_path(s,base_id)
    p.length=copy(p.name[:len(p.name)-1],path[strings.last_index_byte(path,'/')+1:])
    rect,_:=ui.widget_rect(g.ctx,anchor)
    ui.popup_open(g.ctx,variant_prompt_popup(g),rect)
}

@(private)
variant_prompt_build :: proc(s:^Session) {
    g:=s.gui
    ctx:=g.ctx
    th:=&ctx.theme
    p:=&g.variant
    popup:=variant_prompt_popup(g)
    if !ui.popup_is_open(ctx,popup) {return}
    create:=false
    if ui.popup(ctx,popup,{width=280,padding=12}) {
        if ui.box(ctx,{width=ui.GROW,height=ui.fixed(th.control),gap=6,align_y=.Center}) {
            field:=ui.id_derive(ctx,popup,"name")
            if p.focus {ui.edit_request(ctx,field);p.focus=false}
            r:=ui.text_field(ctx,field,p.name[:len(p.name)-1],&p.length,{height=th.control,size=th.font_small})
            if r.cancelled {ui.popup_close(ctx,popup)}
            create=r.committed && .Enter in ctx.input.keys_pressed
            empty:=strings.trim_space(string(p.name[:p.length]))==""
            create|=ui.button(ctx,ui.id_derive(ctx,popup,"create"),{label=p.instance!=core.NONE?"Save variant":"Create variant",style=.Field,height=th.control,size=th.font_small,disabled=empty}).clicked
        }
    }
    if !create {return}
    name:=strings.trim_suffix(strings.trim_space(string(p.name[:p.length])),PREFAB_EXTENSION)
    if name=="" {return}
    if strings.contains_any(name,"/\\:*?\"<>|") {
        notify(s,"Give the variant a name without / \\ : * ? \" < > or |")
        return
    }
    folder:=""
    if file,_,found:=prefab_file(s,p.base);found {folder=file.path[:max(strings.last_index_byte(file.path,'/'),0)]}
    path:=folder==""?name:fmt.tprintf("%s/%s",folder,name)
    p.path_length=copy(p.path[:],path)
    ui.popup_close(ctx,popup)
    s.requests+={.Variant_Create}
}

// The variants of the prefab of the document in its toolbar: a menu with its
// family, the first base and the variants under it, that opens the one
// chosen, and the button that makes a new variant of it.
@(private)
prefab_variants_build :: proc(s:^Session) {
    g:=s.gui
    ctx:=g.ctx
    th:=&ctx.theme
    a:=s.app.assets
    current:=s.document.id
    if a==nil || s.content==nil {return}
    content_registry_read(s.content,&a.registry,content_plugin_kinds(s),&a.types)
    chain:=prefab_variant_chain(s,current)
    top:=len(chain)>0?chain[len(chain)-1]:current
    label:="Prefab"
    if file,_,found:=prefab_file(s,current);found {label=asset_name(file.path)}
    if ui.menu_button(ctx,shell_id(g,"prefab_variants"),label,{height=TOOLBAR_BUTTON,size=th.font_small,popup={min_width=200}}) {
        // Depth first, each variant under its base, one step further right.
        Entry :: struct {id:base.Asset_Id,depth:int}
        stack:=make([dynamic]Entry,context.temp_allocator)
        append(&stack,Entry{top,0})
        for row:=0;len(stack)>0 && row<PREFAB_VARIANT_ROWS;row+=1 {
            entry:=pop(&stack)
            file,path,found:=prefab_file(s,entry.id)
            if !found {continue}
            name:=fmt.tprintf("%s%s",strings.repeat("   ",entry.depth,context.temp_allocator),asset_name(file.path))
            if ui.menu_item(ctx,shell_id(g,"prefab_variant",row+1),name,{icon=.Prefab,checked=entry.id==current}) && entry.id!=current {file_open_path(s,path)}
            owned:=content_owned(s.content.variants[:],entry.id)
            #reverse for part in owned {append(&stack,Entry{a.registry.files[part.file].id,entry.depth+1})}
        }
    }
    create:=shell_id(g,"prefab_variant_new")
    if ui.button(ctx,create,{icon=ui.icon_user(u8(User_Icon.Variant)),tip="Create variant",style=.Ghost,width=TOOLBAR_BUTTON,height=TOOLBAR_BUTTON,active=ui.popup_is_open(ctx,variant_prompt_popup(g)) && g.variant.instance==core.NONE,disabled=s.mode!=.Edit}).clicked {
        variant_prompt_open(s,create,current)
    }
}

// Writes the variant the prompt named: the instance as it is, which becomes
// one of it, or an empty variant of the base, which opens.
@(private)
variant_prompt_run :: proc(s:^Session) {
    p:=&s.gui.variant
    path:=string(p.path[:p.path_length])
    error:Prefab_Error
    id:base.Asset_Id
    if p.instance!=core.NONE {
        if !entity_alive(edited_world(s),p.instance) {return}
        id,error=prefab_create_entities(s,{p.instance},path)
    } else {
        id,error=prefab_variant_create(s,p.base,path)
    }
    if error!=.None {
        notify(s,prefab_error_text(error))
        return
    }
    notify(s,fmt.tprintf("Prefab variant %s created",path))
    if p.instance==core.NONE {
        if _,file,found:=prefab_file(s,id);found {file_open_path(s,file)}
    }
}
