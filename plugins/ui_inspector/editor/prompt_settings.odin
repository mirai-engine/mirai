package ui_inspector_editor

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:reflect"
import "mirai:asset"
import "mirai:core"
import "mirai:editor"
import "mirai:engine/gui"
import inp "mirai:engine/input"
import "mirai:host"
import "mirai:project"
import "mirai:std/base"
import "mirai:ui"

// The images of the prompts in Project Settings > UI: a row for each input
// the actions of the game bind, by family of devices, with the image the
// pack gives it. A texture chosen in a row wins over the pack: it is an entry
// of UI_Settings.prompt_images.

@(storage)
Ui_Settings_Inspector :: struct {provider:editor.Inspector_Provider}

ui_settings_inspector_default :: proc() -> Ui_Settings_Inspector {return {provider={array=prompt_images_field}}}

// An input a prompt shows, of a family.
@(private)
Prompt_Row :: struct {
    family:ui.Prompt_Family,
    input:ui.Prompt_Input,
    key:string,
}

@(private)
prompt_images_field :: proc(c:^editor.Inspect,info:^runtime.Type_Info,name,label:string,offset:uintptr) -> bool {
    if c.type!=gui.UI_Settings || name!="prompt_images" || offset!=offset_of(gui.UI_Settings,prompt_images) {return false}
    s:=c.s
    settings:=cast(^gui.UI_Settings)c.value
    rows:=prompt_rows(s.app,settings)
    pack:=host.content_prompts(s.app,settings.prompts)
    // An entry a list named as it opened and that took no image is free again.
    if s.inspector.list.key==0 {
        for image,i in settings.prompt_images {
            if image.texture!={} || image=={} {continue}
            free:gui.UI_Prompt_Image
            editor.inspect_write(c,int(offset)+i*size_of(gui.UI_Prompt_Image),mem.ptr_to_bytes(&free))
        }
    }
    titles:=[ui.Prompt_Family]string{.Keyboard="Keyboard and mouse",.Xbox="Xbox",.PlayStation="PlayStation",.Nintendo="Nintendo"}
    family:=ui.Prompt_Family(255)
    open,banded:=true,false
    defer if banded {editor.fold_band_end(s)}
    for row,at in rows {
        if row.family!=family {
            family=row.family
            if banded {editor.fold_band_end(s);banded=false}
            open=editor.fold_section(s,ui.id(s.gui.ctx,"family",int(family)+1),base.hash_combine(0x70726f6d707473,u64(family)),titles[family])
            if open {editor.fold_band_begin(s);banded=true}
        }
        if !open {continue}
        slot:=gui.prompt_image_find(settings,row.family,row.input,row.key)
        taken:=slot>=0
        if !taken {
            for image,i in settings.prompt_images {if image.texture=={} {slot=i;break}}
        }
        if slot<0 {
            ui.label(s.gui.ctx,fmt.tprintf("%s: the %d images are taken",prompt_row_label(row),gui.UI_PROMPT_IMAGES),ui.metric(s.gui.ctx,"font_small"),ui.tone(s.gui.ctx,"text_muted"))
            continue
        }
        start:=int(offset)+slot*size_of(gui.UI_Prompt_Image)
        texture:=start+int(offset_of(gui.UI_Prompt_Image,texture))
        shown,_:=host.prompts_find(pack,s.app.assets,row.family,row.input,row.key)
        key:=u64(c.index)<<40|u64(at)<<8|0x55|1<<63
        // Rows without an image share the free slot: each has ids of its own.
        ui.id_push(s.gui.ctx,ui.id(s.gui.ctx,"prompt",at+1))
        opened:=editor.asset_pick_row(c,prompt_row_label(row),asset.KIND_TEXTURE,texture,key,shown.quad)
        ui.id_pop(s.gui.ctx)
        // The entry a free slot becomes is written as its list opens.
        if opened && !taken {
            entry:=gui.UI_Prompt_Image{family=row.family,input=row.input,texture=settings.prompt_images[slot].texture}
            base.text_set(entry.key[:],row.key)
            editor.inspect_write(c,start,mem.ptr_to_bytes(&entry)[:offset_of(gui.UI_Prompt_Image,texture)])
        }
    }
    return true
}

@(private)
prompt_row_label :: proc(row:Prompt_Row) -> string {
    if row.input==.Key {return row.key}
    return editor.readable(reflect.enum_string(row.input))
}

// The inputs the actions of the game bind in input.mirai, each family in
// turn, and those the settings give an image without a binding.
@(private)
prompt_rows :: proc(app:^host.App,settings:^gui.UI_Settings) -> []Prompt_Row {
    rows:=make([dynamic]Prompt_Row,context.temp_allocator)
    add :: proc(rows:^[dynamic]Prompt_Row,row:Prompt_Row) {
        for r in rows {if r.family==row.family && r.input==row.input && r.key==row.key {return}}
        append(rows,row)
    }
    m:=new(inp.Input_Map,context.temp_allocator)
    if app.info!=nil {
        file,text:string
        if app.root!="" {
            path:=project.path(app.root,project.INPUT_FILE,allocator=context.temp_allocator)
            if data,error:=os.read_entire_file(path,context.temp_allocator);error==nil {file,text=path,string(data)}
        }
        problems:=new(core.Problems,context.temp_allocator)
        inp.input_map_make(m,app.info,file,text,problems)
    }
    for family in ([]ui.Prompt_Family{.Keyboard,.Xbox,.PlayStation}) {
        if app.info!=nil {
            for entry in core.names_of(app.info,inp.Action) {
                if entry.value<0 || entry.value>=inp.ACTION_CAPACITY {continue}
                out:[8]ui.Prompt
                for p in out[:gui.prompts_of(m,inp.Action(entry.value),family,-1,out[:])] {add(&rows,{p.family,p.input,p.text})}
            }
        }
        for &image in settings.prompt_images {
            if image.texture!={} && image.family==family {add(&rows,{image.family,image.input,base.text_get(image.key[:])})}
        }
    }
    return rows[:]
}
