package editor

import "base:runtime"
import "core:mem"
import "mirai:asset"
import "mirai:std/base"
import "mirai:std/serial"
import "mirai:ui"

// Values a panel holds and edits with the rows of Details: a value of a
// struct type in the storage of the panel, which the rows write in place,
// with no step of the document, and the values each arrow gives its field
// back. A list or a color picker a row opens writes what it chose the next
// time a row of those values is built. info: of the type of the values, as
// type_info_of gives it where the type is declared: a plugin's types are not
// known to the editor. With write, the rows write through it instead, as
// steps of the document named name, and a drag or a session of the picker is
// one step: values a plugin shows of what it keeps elsewhere (those of an
// effect an entity shows).
Held_Values :: struct {
    key:u64, // of these values among those panels hold; not 0
    info:^runtime.Type_Info, // type_info_of their type where it is declared: a library of a plugin has its own table of types
    value:rawptr,
    defaults:rawptr,
    width:f32, // of the rows: an enum of a few short names fits as segments; 0: a list
    write:Held_Writer,
    user:rawptr, // of write, while the rows are built
    name:string, // of the steps of write
}

// Writes bytes at an offset of held values, in the step that is open or in one of its own.
Held_Writer :: #type proc(s:^Session,user:rawptr,offset:int,bytes:[]u8)

// A value a popup chose for values a panel holds.
Held_Write :: struct {
    key:u64, // of the values; 0: none
    offset:int,
    size:int,
    bytes:[16]u8,
}

@(private)
held_put :: proc(ins:^Inspector,key:u64,offset:int,bytes:[]u8) {
    if len(bytes)>len(ins.held.bytes) {return}
    ins.held={key=key,offset=offset,size=len(bytes)}
    copy(ins.held.bytes[:],bytes)
}

// Writes into the values what a popup chose for them.
@(private)
held_take :: proc(c:^Inspect) {
    w:=&c.s.inspector.held
    if w.key==0 || w.key!=c.held {return}
    inspect_write(c,w.offset,w.bytes[:w.size])
    w^={}
}

// The rows of one field of the values, with their arrows; true when they
// changed it or a popup did.
held_field_row :: proc(s:^Session,h:Held_Values,name:string,label:string="",description:string="") -> (changed:bool) {
    info:=h.info
    if info==nil || h.key==0 || h.value==nil || h.defaults==nil {return false}
    c:=Inspect{s=s,w=shown_world(s),index=HELD_INDEX,held=h.key,write=h.write,user=h.user,name=h.name,type=info.id,value=cast([^]u8)h.value,defaults=cast([^]u8)h.defaults,size=info.size,width=h.width}
    if !inspect_schema(&c,info) {return false}
    held_take(&c)
    for field in serial.schema_fields(c.schema,c.of) {
        if field.name!=name {continue}
        field_row(&c,field,label!=""?label:readable(name),uintptr(field.offset),0,description)
        break
    }
    return c.changed
}

// The rows of one field of values a schema describes instead of a type of
// the code: those of a table of game data, whose layout its columns make.
// h.info is not read.
held_schema_row :: proc(s:^Session,h:Held_Values,schema:^serial.Schema,of:serial.Type_Index,field:serial.Field,label:string,description:string="") -> (changed:bool) {
    if h.key==0 || h.value==nil || h.defaults==nil || !serial.type_valid(schema,of) {return false}
    c:=Inspect{s=s,w=shown_world(s),index=HELD_INDEX,held=h.key,write=h.write,user=h.user,name=h.name,schema=schema,of=of,value=cast([^]u8)h.value,defaults=cast([^]u8)h.defaults,size=int(schema.types[of].size),width=h.width}
    held_take(&c)
    field_row(&c,field,label,uintptr(field.offset),0,description)
    return c.changed
}

// An asset a panel holds, as a button for a toolbar: its thumbnail and name,
// and the list of the assets of its kinds when it is clicked. key: of the value
// among those panels hold, not 0. True when the list or a drop changed it.
held_asset_button :: proc(s:^Session,id:ui.Id,key:u64,kinds:Asset_Kinds,value:^base.Asset_Id,width:f32) -> (changed:bool) {
    ctx:=s.gui.ctx
    if w:=&s.inspector.held;w.key==key && w.size==size_of(base.Asset_Id) {
        mem.copy(value,&w.bytes[0],size_of(base.Asset_Id))
        w^={}
        changed=true
    }
    shown:="None"
    if value^!={} {
        shown=asset_name(asset_path(s,value^))
        if shown=="" {shown="Missing"}
    }
    side:=ui.metric(ctx,"control")-4
    if ui.box(ctx,{id=id,width=ui.fixed(width),height=ui.fixed(ui.metric(ctx,"control")),gap=4,align_y=.Center,track=true}) {
        asset_field_thumbnail(s,ui.id_derive(ctx,id,"thumbnail"),kinds[0],value^,side)
        button:=ui.id_derive(ctx,id,"list")
        open:=s.inspector.list.key==key
        if ui.button(ctx,button,{label=shown,icon=.Chevron_Down,icon_after=true,icon_color=ui.tone(ctx,"text_muted"),icon_size=13,variant="field",width=-1,height=ui.metric(ctx,"control"),size=ui.metric(ctx,"font_small"),padding=7,active=open}).clicked && !open {
            anchor,_:=ui.widget_rect(ctx,button)
            list_open(s,{key=key,held=key,kinds=kinds},anchor)
        }
    }
    if dropped,ok:=asset_field_dropped(s,id,kinds,"");ok {value^,changed=dropped,true}
    return
}

// A field that filters a list as it is typed: a search icon before it and,
// while it has text, a cross that empties it.
search_field :: proc(s:^Session,id:ui.Id,buffer:[]u8,length:^int,placeholder:string) -> (changed:bool) {
    ctx:=s.gui.ctx
    if ui.box(ctx,{width=ui.GROW,height=ui.fixed(28),padding={7,0,2,0},gap=5,align_y=.Center,fill=ui.tone(ctx,"field"),stroke=ui.tone(ctx,"accent") if ctx.edit.id==id else ui.tone(ctx,"border"),stroke_width=1,radius=4}) {
        ui.icon(ctx,ui.icon_user(u8(User_Icon.Search)),ui.tone(ctx,"text_muted"),13)
        result:=ui.text_field(ctx,id,buffer,length,{height=24,live=true,keep_caret=true,placeholder=placeholder,bare=true})
        changed=result.changed
        if result.cancelled && length^>0 {length^=0;changed=true}
        if length^>0 && ui.button(ctx,ui.id_derive(ctx,id,"clear"),{icon=.Cross,icon_color=ui.tone(ctx,"text_muted"),variant="ghost",width=22,height=22}).clicked {length^=0;changed=true}
    }
    return
}
