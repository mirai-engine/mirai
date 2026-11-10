package editor

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:reflect"
import "core:strings"
import "mirai:asset"
import "mirai:core"
import "mirai:editor/records"
import "mirai:host"
import "mirai:std/base"
import "mirai:ui"

// The document of a table of game data (.records): a grid with a row per
// record and a column per field, and the fields of the selected row whole at
// its right. The grid and the rows change a copy of the table, which is
// written as a step of the history of the document once nothing holds it (a
// drag, a field being typed, an open list); a table the API or an undo
// changed is read again.

RECORDS_NAME_WIDTH :: 180  // points of the column of the names
RECORDS_CELL_WIDTH :: 132  // of a column of a field
RECORDS_TEXT_WIDTH :: 200  // of a column of a text
RECORDS_DETAILS_WIDTH :: 360
RECORDS_COLUMN_DEPTH :: 3  // structs inside structs the grid opens into columns
RECORDS_ARRAY_COLUMNS :: 4 // elements of an array the grid shows as columns; longer ones only at the right
@(private) KEY_RECORDS_ROW :: u64(0x7265636f72647372)

@(storage)
Records_Documents :: struct {provider:Asset_Document_Provider}
RECORDS_DOCUMENTS_DEFAULT :: Records_Documents{provider={kinds={0=asset.KIND_RECORDS},count=1,flat={0},creates={0},create=records_document_create}}

// An empty table of the type Create was asked for (Content.create_record),
// or of the first type the code declares; nil when it declares none.
records_document_create :: proc(s:^Session,kind:asset.Fourcc,id:base.Asset_Id) -> []u8 {
    if s.app.info==nil || len(s.app.info.records)==0 || s.app.info.schema==nil {return nil}
    index:=clamp(s.content.create_record if s.content!=nil else 0,0,len(s.app.info.records)-1)
    ws:=s.app.info.schema
    desc:=asset.Records_Desc{id=id,type=records.type_name(s.app.info,index),schema=&ws.schema,value_type=ws.records[index].type}
    bytes,error:=asset.records_bytes(&s.app.assets.types,desc,context.temp_allocator)
    return bytes if error==.None else nil
}

@(storage,free="records_document_free")
Records_Document :: struct {
    id:base.Asset_Id,
    edit:records.Edit,
    read:bool,
    stamp:u64,        // the content hash of the file the copy was read from or written to
    changed:bool,     // the copy changed since: it is written once nothing holds it
    selected:int,     // row; -1: none
    reveal:bool,      // scroll to the selected row
    scroll:[2]f32,
    header_scroll:[2]f32, // follows scroll across: the names of the columns stay on top
    details_scroll:[2]f32,
    problem:[256]u8,  // why the table cannot be shown, or why the last change was refused
    defaults:[]u8,    // of a row of its type
    columns:[dynamic]Records_Column,
}

// A column of the grid: a field of the rows at some depth.
Records_Column :: struct {
    label:string,
    offset:int,
    info:^runtime.Type_Info,
    tag:reflect.Struct_Tag,
    name:string,        // of the field, for the kind of asset it takes
    description:string, // of its field on the type
    width:f32,
}

records_document_free :: proc(r:^Records_Document) {
    if r.read {records.destroy(&r.edit)}
    delete(r.defaults)
    for c in r.columns {delete(c.label)}
    delete(r.columns)
    r^={}
}

@(step="ui",after="editor_panels")
records_document_ui :: proc(s:^Session,r:^Records_Document,app:^host.App) {
    g:=s.gui
    if !g.begun || playing(s) {return}
    d:=asset_document_active(s)
    if d==nil || d.kind!=asset.KIND_RECORDS {return}
    ctx:=g.ctx
    records_document_sync(s,r,d.id)
    if part:=base.text_get(d.part[:]);part!="" && r.read {
        if row:=records.row_find(&r.edit,part);row>=0 {r.selected,r.reveal=row,true}
        d.part={}
    }
    id:=ui.id(ctx,"records_document")
    if ui.panel(ctx,id,asset_workspace(g)) {
        ui.id_push(ctx,id)
        defer ui.id_pop(ctx)
        if ui.box(ctx,{width=ui.GROW,height=ui.GROW}) {
            if asset_column_begin(ctx,ui.GROW,records_title(s,r),records_note(r)) {
                records_grid(s,r,app)
                asset_column_end(ctx)
            }
            asset_column_divider(ctx)
            if asset_column_begin(ctx,ui.fixed(RECORDS_DETAILS_WIDTH),r.read && r.selected>=0 ? records.row_name(&r.edit,r.selected) : "Row") {
                records_details(s,r,app)
                asset_column_end(ctx)
            }
        }
    }
    if r.read && r.changed && ctx.active==0 && ctx.edit.id==0 && ctx.popup.count==0 {records_document_write(s,r)}
}

@(private="file")
records_title :: proc(s:^Session,r:^Records_Document) -> string {
    if !r.read {return "Records"}
    return s.app.info.records[r.edit.record].name
}

@(private="file")
records_note :: proc(r:^Records_Document) -> string {
    if !r.read {return ""}
    count:=records.row_count(&r.edit)
    return fmt.tprintf("%d %s",count,count==1?"row":"rows")
}

// The copy of the table of the document, read again when the document is
// another or its file changed outside the grid.
@(private="file")
records_document_sync :: proc(s:^Session,r:^Records_Document,id:base.Asset_Id) {
    a:=s.app.assets
    if a==nil {return}
    file,found:=asset.registry_find(&a.registry,id)
    if !found {return}
    if r.id==id && (r.changed || file.content_hash==r.stamp) {return}
    selected:=r.read && r.id==id ? r.selected : -1
    if r.read {records.destroy(&r.edit)}
    r.read,r.changed,r.id,r.stamp=false,false,id,file.content_hash
    r.problem={}
    if problem:=records_edit_load(s,id,&r.edit);problem!="" {
        base.text_set(r.problem[:],problem)
        return
    }
    r.read=true
    r.selected=min(selected,records.row_count(&r.edit)-1)
    records_columns_make(s,r)
}

@(private="file")
records_document_write :: proc(s:^Session,r:^Records_Document) {
    r.changed=false
    if problem:=records_edit_publish(s,&r.edit,"Records");problem!="" {
        notify(s,problem)
        r.stamp=0 // read the file again: the copy keeps what was refused
        return
    }
    if file,found:=asset.registry_find(&s.app.assets.registry,r.id);found {r.stamp=file.content_hash}
}

// The columns of the type of the table: its fields, opened into theirs.
@(private="file")
records_columns_make :: proc(s:^Session,r:^Records_Document) {
    for c in r.columns {delete(c.label)}
    clear(&r.columns)
    info:=&s.app.info.records[r.edit.record]
    delete(r.defaults)
    r.defaults=make([]u8,info.info.size)
    if info.default!=nil {info.default(raw_data(r.defaults))}
    fields,is_struct:=runtime.type_info_base(info.info).variant.(runtime.Type_Info_Struct)
    if !is_struct {return}
    for i in 0..<int(fields.field_count) {
        description:=""
        for f in info.fields {
            if f.name==fields.names[i] {description=f.text}
        }
        records_columns_add(s,r,fields.types[i],reflect.Struct_Tag(fields.tags[i]),fields.names[i],readable(fields.names[i]),int(fields.offsets[i]),description,0)
    }
}

@(private="file")
records_columns_add :: proc(s:^Session,r:^Records_Document,info:^runtime.Type_Info,tag:reflect.Struct_Tag,name,label:string,offset:int,description:string,depth:int) {
    column :: proc(r:^Records_Document,info:^runtime.Type_Info,tag:reflect.Struct_Tag,name,label:string,offset:int,description:string,width:f32) {
        append(&r.columns,Records_Column{label=strings.clone(label),offset=offset,info=info,tag=tag,name=name,description=description,width=width})
    }
    if info.id==core.Text {
        column(r,info,tag,name,label,offset,description,RECORDS_TEXT_WIDTH)
        return
    }
    if info.id==base.Asset_Id || core.record_of_ref(s.app.info,info.id)>=0 || core.named_type_of(s.app.info,info.id)!=nil {
        column(r,info,tag,name,label,offset,description,RECORDS_CELL_WIDTH)
        return
    }
    #partial switch v in runtime.type_info_base(info).variant {
    case runtime.Type_Info_Boolean,runtime.Type_Info_Integer,runtime.Type_Info_Float,runtime.Type_Info_Enum:
        column(r,info,tag,name,label,offset,description,RECORDS_CELL_WIDTH)
    case runtime.Type_Info_Array:
        if .Text in field_tagged(string(tag)).flags && v.elem.size==1 {
            column(r,info,tag,name,label,offset,description,RECORDS_TEXT_WIDTH)
            return
        }
        if v.count>RECORDS_ARRAY_COLUMNS || depth>=RECORDS_COLUMN_DEPTH {return}
        for at in 0..<v.count {records_columns_add(s,r,v.elem,tag,name,fmt.tprintf("%s %d",label,at+1),offset+at*v.elem_size,description,depth+1)}
    case runtime.Type_Info_Struct:
        if depth>=RECORDS_COLUMN_DEPTH {return}
        for i in 0..<int(v.field_count) {
            records_columns_add(s,r,v.types[i],reflect.Struct_Tag(v.tags[i]),v.names[i],fmt.tprintf("%s %s",label,readable(v.names[i])),offset+int(v.offsets[i]),description,depth+1)
        }
    }
}

// ---------------------------------------------------------------- grid

@(private="file")
records_grid :: proc(s:^Session,r:^Records_Document,app:^host.App) {
    ctx:=s.gui.ctx
    th:=&ctx.theme
    if !r.read {
        if ui.box(ctx,{width=ui.GROW,height=ui.GROW,padding={12,12,12,12}}) {ui.label(ctx,base.text_get(r.problem[:]),th.font_small,th.text_muted)}
        return
    }
    e:=&r.edit
    if description:=s.app.info.records[e.record].description;description!="" {
        if ui.box(ctx,{width=ui.GROW,height=ui.FIT,padding={12,6,12,6}}) {ui.paragraph(ctx,description,th.font_small,th.text_muted)}
    }
    if ui.box(ctx,{width=ui.GROW,height=ui.fixed(th.control+12),padding={12,6,12,6},gap=6,align_y=.Center}) {
        if ui.button(ctx,ui.id(ctx,"add"),{label="Add row",icon=.Plus,style=.Field,height=th.control}).clicked {records_grid_add(s,r)}
        if r.selected>=0 {
            if ui.button(ctx,ui.id(ctx,"duplicate"),{label="Duplicate",style=.Field,height=th.control}).clicked {records_grid_duplicate(s,r)}
            if ui.button(ctx,ui.id(ctx,"remove"),{label="Delete",style=.Field,height=th.control}).clicked {
                records.row_remove(e,r.selected)
                r.selected=min(r.selected,records.row_count(e)-1)
                r.changed=true
            }
        }
    }
    width:=f32(RECORDS_NAME_WIDTH)
    for c in r.columns {width+=c.width}
    row_height:=th.row+4
    // The names of the columns stay on top while the rows scroll under them.
    r.header_scroll={r.scroll[0],0}
    if ui.scroll_area(ctx,ui.id(ctx,"header"),&r.header_scroll,{width=ui.GROW,height=ui.fixed(row_height),axes=.Horizontal}) {
        if ui.box(ctx,{width=ui.fixed(width),height=ui.fixed(row_height),align_y=.Center,fill=th.card}) {
            if ui.box(ctx,{width=ui.fixed(RECORDS_NAME_WIDTH),height=ui.GROW,padding={12,0,6,0},align_y=.Center}) {ui.label(ctx,"Name",th.font_small,th.text_muted)}
            for c,at in r.columns {
                header:=ui.id(ctx,"header",at+1)
                if ui.box(ctx,{id=header,width=ui.fixed(c.width),height=ui.GROW,padding={6,0,6,0},align_y=.Center,clip_x=true,track=c.description!=""}) {ui.label(ctx,c.label,th.font_small,th.text_muted)}
                if c.description!="" {
                    area,shown:=ui.widget_rect(ctx,header)
                    inspector_description(s,header,c.description,shown && ctx.popup.count==0 && ui.rect_contains(area,ctx.pointer))
                }
            }
        }
    }
    if ui.box(ctx,{width=ui.GROW,height=ui.fixed(1),fill=th.border}) {}
    area_id:=ui.id(ctx,"rows")
    area,_:=ui.widget_rect(ctx,area_id)
    count:=records.row_count(e)
    if r.reveal && r.selected>=0 {
        top:=f32(r.selected)*row_height
        if top<r.scroll[1] {r.scroll[1]=top}
        if area.h>row_height && top+row_height>r.scroll[1]+area.h {r.scroll[1]=top+row_height-area.h}
        r.reveal=false
    }
    first:=clamp(int(r.scroll[1]/row_height),0,count)
    last:=clamp(first+int(max(area.h,600)/row_height)+2,0,count)
    if ui.scroll_area(ctx,area_id,&r.scroll,{width=ui.GROW,height=ui.GROW,direction=.Column,axes=.Both}) {
        ui.spacer(ctx,width,f32(first)*row_height)
        for row in first..<last {records_grid_row(s,r,app,row,width,row_height)}
        ui.spacer(ctx,width,f32(count-last)*row_height)
    }
}

@(private="file")
records_grid_row :: proc(s:^Session,r:^Records_Document,app:^host.App,row:int,width,height:f32) {
    ctx:=s.gui.ctx
    th:=&ctx.theme
    e:=&r.edit
    ui.id_push(ctx,ui.Id(e.ids[row]))
    defer ui.id_pop(ctx)
    line:=ui.id(ctx,"row")
    fill:=r.selected==row ? th.accent_soft : ui.Color{}
    if ui.box(ctx,{id=line,width=ui.fixed(width),height=ui.fixed(height),align_y=.Center,fill=fill,track=true}) {
        if ui.box(ctx,{width=ui.fixed(RECORDS_NAME_WIDTH),height=ui.GROW,padding={8,2,6,2},align_y=.Center}) {records_name_cell(s,r,row)}
        for &c,at in r.columns {
            if ui.box(ctx,{width=ui.fixed(c.width),height=ui.GROW,padding={2,2,4,2},align_y=.Center}) {
                if records_cell(s,r,app,row,&c,at) {r.selected,r.changed=row,true}
            }
        }
    }
    if area,shown:=ui.widget_rect(ctx,line);shown && .Left in ctx.input.pressed && ui.rect_contains(area,ctx.pointer) && ctx.popup.count==0 {r.selected=row}
    if ui.box(ctx,{width=ui.fixed(width),height=ui.fixed(1),fill=th.row_rule}) {}
}

@(private="file")
records_name_cell :: proc(s:^Session,r:^Records_Document,row:int) {
    ctx:=s.gui.ctx
    th:=&ctx.theme
    buffer:[asset.RECORDS_NAME]u8
    length:=copy(buffer[:asset.RECORDS_NAME-1],records.row_name(&r.edit,row))
    result:=ui.text_field(ctx,ui.id(ctx,"name"),buffer[:asset.RECORDS_NAME-1],&length,{height=th.row,size=th.font_small})
    if !result.changed {return}
    if problem:=records.row_rename(&r.edit,row,string(buffer[:length]));problem!="" {notify(s,problem)} else {r.changed=true}
}

// A cell of a row: true when it changed the value.
@(private="file")
records_cell :: proc(s:^Session,r:^Records_Document,app:^host.App,row:int,c:^Records_Column,at:int) -> (changed:bool) {
    ctx:=s.gui.ctx
    th:=&ctx.theme
    e:=&r.edit
    value:=records.row_bytes(e,row)[c.offset:][:c.info.size]
    p:=raw_data(value)
    id:=ui.id(ctx,"cell",at+1)
    switch {
    case c.info.id==core.Text:
        return records_text_cell(s,r,row,c,id)
    case c.info.id==base.Asset_Id:
        key:=KEY_RECORDS_ROW~(u64(row)<<20|u64(at))
        return held_asset_button(s,id,key,field_asset_kinds(s,c.tag,c.name),cast(^base.Asset_Id)p,c.width-6)
    }
    if record:=core.record_of_ref(s.app.info,c.info.id);record>=0 {
        return record_choice(s,id,record,cast(^core.Record_Id)&value[size_of(base.Asset_Id)],cast(^base.Asset_Id)p,ui.fixed(c.width-6))
    }
    if names:=core.names_of(s.app.info,c.info.id);len(names)>0 {
        options:=make([]string,len(names),context.temp_allocator)
        current:=i64(number_read(p,c.info))
        selected:=-1
        for n,i in names {
            options[i]=n.name
            if n.value==current {selected=i}
        }
        if ui.dropdown(ctx,id,{list=options},&selected,{width=-1,height=th.row,searchable=true}) && selected>=0 {
            number_write(p,c.info,f64(names[selected].value))
            return true
        }
        return false
    }
    #partial switch v in runtime.type_info_base(c.info).variant {
    case runtime.Type_Info_Boolean:
        return ui.checkbox(ctx,id,cast(^bool)p)
    case runtime.Type_Info_Integer,runtime.Type_Info_Float:
        desc,scale:=field_number(c.info,c.tag)
        desc.height=th.row
        number:=number_read(p,c.info)*scale
        result:=ui.number_field(ctx,id,&number,desc)
        if result.changed {number_write(p,c.info,number/scale)}
        return result.changed
    case runtime.Type_Info_Enum:
        current:=i64(number_read(p,v.base))
        selected:=-1
        options:=make([]string,len(v.names),context.temp_allocator)
        for name,i in v.names {
            options[i]=readable(name)
            if i64(v.values[i])==current {selected=i}
        }
        if ui.dropdown(ctx,id,{list=options},&selected,{width=-1,height=th.row}) && selected>=0 {
            number_write(p,v.base,f64(v.values[selected]))
            return true
        }
    case runtime.Type_Info_Array:
        length:=base.text_len(value)
        result:=ui.text_field(ctx,id,value[:len(value)-1],&length,{height=th.row,size=th.font_small})
        if result.changed || result.committed {
            mem.zero_slice(value[length:])
            return true
        }
    }
    return false
}

// The text of a core.Text in the language the game is written in.
@(private="file")
records_text_cell :: proc(s:^Session,r:^Records_Document,row:int,c:^Records_Column,id:ui.Id) -> (changed:bool) {
    ctx:=s.gui.ctx
    th:=&ctx.theme
    e:=&r.edit
    text:=(cast(^core.Text)&records.row_bytes(e,row)[c.offset]).id
    shown,_:=records.text_get(e,text,"")
    buffer:[1024]u8
    length:=copy(buffer[:],shown)
    if !ui.text_field(ctx,id,buffer[:],&length,{height=th.row,size=th.font_small}).changed {return false}
    records.text_set(e,&s.id_state,row,c.offset,"",strings.clone(string(buffer[:length]),context.temp_allocator))
    return true
}

@(private="file")
records_grid_add :: proc(s:^Session,r:^Records_Document) {
    e:=&r.edit
    base_name:=strings.to_lower(s.app.info.records[e.record].name,context.temp_allocator)
    name:=base_name
    for n:=2;records.row_find(e,name)>=0;n+=1 {name=fmt.tprintf("%s_%d",base_name,n)}
    row,problem:=records.row_add(e,&s.id_state,name,nil,r.selected,s.app.info.records[e.record].default)
    if problem!="" {notify(s,problem);return}
    r.selected,r.reveal,r.changed=row,true,true
}

@(private="file")
records_grid_duplicate :: proc(s:^Session,r:^Records_Document) {
    e:=&r.edit
    original:=records.row_name(e,r.selected)
    name:=fmt.tprintf("%s_copy",original)
    for n:=2;records.row_find(e,name)>=0;n+=1 {name=fmt.tprintf("%s_copy_%d",original,n)}
    row,problem:=records.row_duplicate(e,&s.id_state,r.selected,name)
    if problem!="" {notify(s,problem);return}
    r.selected,r.reveal,r.changed=row,true,true
}

// ---------------------------------------------------------------- the row

// Every field of the selected row, with the rows of Details.
@(private="file")
records_details :: proc(s:^Session,r:^Records_Document,app:^host.App) {
    ctx:=s.gui.ctx
    if !r.read || r.selected<0 || r.selected>=records.row_count(&r.edit) {return}
    e:=&r.edit
    info:=e.info
    fields,is_struct:=runtime.type_info_base(info).variant.(runtime.Type_Info_Struct)
    if !is_struct {return}
    row:=records.row_bytes(e,r.selected)
    record:=&s.app.info.records[e.record]
    h:=Held_Values{key=KEY_RECORDS_ROW~e.ids[r.selected],info=info,value=raw_data(row),defaults=raw_data(r.defaults),width=RECORDS_DETAILS_WIDTH-16}
    if ui.scroll_area(ctx,ui.id(ctx,"details"),&r.details_scroll,{width=ui.GROW,height=ui.GROW,direction=.Column,gap=3,padding={8,8,10,8}}) {
        for i in 0..<int(fields.field_count) {
            name:=fields.names[i]
            description:=""
            for f in record.fields {
                if f.name==name {description=f.text}
            }
            if fields.types[i].id==core.Text {
                records_text_row(s,r,int(fields.offsets[i]),readable(name),i)
                continue
            }
            if held_field_row(s,h,name,description=description) {r.changed=true}
        }
    }
}

// A text of the row as a field of its own, in the language the game is written in.
@(private="file")
records_text_row :: proc(s:^Session,r:^Records_Document,offset:int,label:string,at:int) {
    ctx:=s.gui.ctx
    row_begin(ctx,label)
    column:=Records_Column{offset=offset,info=type_info_of(core.Text)}
    if records_text_cell(s,r,r.selected,&column,ui.id(ctx,"text",at+1)) {r.changed=true}
    row_end(ctx)
}

// ---------------------------------------------------------------- references

// A row of the tables of a record type, for a core.Record field: a list of
// their names (with the table when there are several), and a button that
// opens the table at the row. A row no table has shows Missing. True when
// the list changed it.
record_choice :: proc(s:^Session,id:ui.Id,record:int,row:^core.Record_Id,table:^base.Asset_Id,width:ui.Size) -> (changed:bool) {
    ctx:=s.gui.ctx
    th:=&ctx.theme
    set:=host.app_record_set(s.app,record)
    tables:=0
    if set!=nil {tables=len(set.tables)}
    count:=set!=nil ? len(set.rows) : 0
    options:=make([]string,count+1,context.temp_allocator)
    options[0]="None"
    selected:=0 if table^=={} else -1
    for i in 0..<count {
        entry:=&set.rows[i]
        name:=base.text_get(entry.name[:])
        if tables>1 {
            for &t in set.tables {
                if t.id==entry.table {name=fmt.tprintf("%s / %s",asset_name(base.text_get(t.name[:])),name)}
            }
        }
        options[i+1]=name
        if entry.table==table^ && entry.row==row^ {selected=i+1}
    }
    if ui.box(ctx,{width=width,height=ui.fixed(th.row),gap=2,align_y=.Center}) {
        if ui.dropdown(ctx,id,{list=options},&selected,{width=-1,height=th.row,searchable=true,empty="Missing"}) && selected>=0 {
            if selected==0 {
                table^,row^={},0
            } else {
                table^,row^=set.rows[selected-1].table,set.rows[selected-1].row
            }
            changed=true
        }
        if table^!={} && ui.button(ctx,ui.id_derive(ctx,id,"open"),{icon=.Chevron_Right,style=.Ghost,width=th.row,height=th.row}).clicked {
            name:=""
            if set!=nil {
                if at:=core.record_index(set,table^,row^,set.size);at>=0 {name=base.text_get(set.rows[at].name[:])}
            }
            asset_document_open(s,table^,name)
        }
    }
    return
}
