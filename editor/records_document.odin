package editor

import "core:fmt"
import "core:mem"
import "core:strings"
import "mirai:asset"
import "mirai:core"
import "mirai:editor/records"
import "mirai:host"
import "mirai:std/base"
import "mirai:std/serial"
import "mirai:ui"

// The document of a table of game data (.records): a grid with a row per
// record and a column per column of its type, and at its right a panel that
// edits what was clicked: the fields of a row, a column (its header: name,
// kind, options, default, description), or the table (the corner). Rows and
// columns change a copy of the table, which is written as a step of the
// history of the document once nothing holds it (a drag, a field being
// typed, an open list); a table the API or an undo changed is read again.
// A table that holds rows of a type another declares shows that one's
// columns, which change there.

RECORDS_INDEX_WIDTH :: 44  // points of the column of the numbers of the rows
RECORDS_NAME_WIDTH :: 150  // of the column of the names
RECORDS_ADD_WIDTH :: 36    // of the + after the last column
RECORDS_DETAILS_WIDTH :: 320
RECORDS_PAD :: 10          // inside a cell, at each side
@(private) RECORDS_NAME_CELL :: -2 // the cell of the name of the selected row
@(private) KEY_RECORDS_ROW :: u64(0x7265636f72647372)
@(private) KEY_RECORDS_DEFAULT :: u64(0x7265636f72646466)

@(private)
RECORDS_KIND_LABELS :: [asset.Records_Kind]string{.Int="Integer",.Float="Number",.Bool="Checkbox",.Enum="Choice",.Asset="Asset",.Text="Localized text",.String="Text",.Record="Row of a table",.Type="Type of the code"}

@(storage)
Records_Documents :: struct {provider:Asset_Document_Provider}
RECORDS_DOCUMENTS_DEFAULT :: Records_Documents{provider={kinds={0=asset.KIND_RECORDS},count=1,flat={0}}}

@(storage,free="records_document_free")
Records_Document :: struct {
    id:base.Asset_Id,
    edit:records.Edit,
    read:bool,
    stamp:u64,        // the content hash of the file the copy was read from or written to
    changed:bool,     // the copy changed since: it is written once nothing holds it
    selected:int,     // row; -1: none
    column:int,       // whose header was clicked: the panel edits it; -1: none
    cell:int,         // the column of the selected row a click opened in the grid; -1: none
    reveal:bool,      // scroll to the selected row
    scroll:[2]f32,
    details_scroll:[2]f32,
    problem:[256]u8,  // why the table cannot be shown
}

records_document_free :: proc(r:^Records_Document) {
    if r.read {records.destroy(&r.edit)}
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
        if row:=records.row_find(&r.edit,part);row>=0 {r.selected,r.column,r.cell,r.reveal=row,-1,-1,true}
        d.part={}
    }
    id:=ui.id(ctx,"records_document")
    if ui.panel(ctx,id,asset_workspace(g)) {
        ui.id_push(ctx,id)
        defer ui.id_pop(ctx)
        if ui.box(ctx,{width=ui.GROW,height=ui.GROW}) {
            if asset_column_begin(ctx,ui.GROW,records_title(r),records_note(r)) {
                records_grid(s,r,app)
                asset_column_end(ctx)
            }
            asset_column_divider(ctx)
            title,note:=records_details_title(r)
            if asset_column_begin(ctx,ui.fixed(RECORDS_DETAILS_WIDTH),title,note) {
                records_details(s,r)
                asset_column_end(ctx)
            }
        }
    }
    if r.read && r.changed && ctx.active==0 && ctx.edit.id==0 && ctx.popup.count==0 {records_document_write(s,r)}
}

@(private="file")
records_title :: proc(r:^Records_Document) -> string {
    if !r.read {return "Records"}
    return records.type_name(&r.edit)
}

@(private="file")
records_note :: proc(r:^Records_Document) -> string {
    if !r.read {return ""}
    rows,columns:=records.row_count(&r.edit),len(r.edit.columns)
    return fmt.tprintf("%d %s · %d %s",rows,rows==1?"row":"rows",columns,columns==1?"column":"columns")
}

@(private="file")
records_details_title :: proc(r:^Records_Document) -> (title,note:string) {
    if !r.read {return "Table",""}
    e:=&r.edit
    switch {
    case r.column>=0 && r.column<len(e.columns):
        labels:=RECORDS_KIND_LABELS
        return records.column_name(&e.columns[r.column]),labels[e.columns[r.column].kind]
    case r.selected>=0 && r.selected<records.row_count(e):
        return records.row_name(e,r.selected),"Row"
    }
    return records.type_name(e),"Table"
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
    same:=r.read && r.id==id
    selected,column:=same ? r.selected : -1,same ? r.column : -1
    if r.read {records.destroy(&r.edit)}
    r.read,r.changed,r.id,r.stamp,r.cell=false,false,id,file.content_hash,-1
    r.problem={}
    if problem:=records_edit_load(s,id,&r.edit);problem!="" {
        base.text_set(r.problem[:],problem)
        return
    }
    r.read=true
    r.selected=min(selected,records.row_count(&r.edit)-1)
    r.column=min(column,len(r.edit.columns)-1)
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

// What the header of a column says of its kind, after its name.
@(private="file")
records_hint :: proc(c:^asset.Records_Column) -> string {
    hint:string
    switch c.kind {
    case .Int:    hint="int"
    case .Float:  hint="float"
    case .Bool:   hint="bool"
    case .Text:   hint="text key"
    case .String: hint="text"
    case .Asset:  hint=serial.text_field(c.asset_kind[:]) if c.asset_kind[0]!=0 else "asset"
    case .Enum,.Record,.Type: hint=serial.text_field(c.type[:])
    }
    if unit:=serial.text_field(c.unit[:]);unit!="" && (c.kind==.Int || c.kind==.Float) {hint=fmt.tprintf("%s %s",hint,unit)}
    if c.count>0 {hint=fmt.tprintf("%s[%d]",hint,c.count)}
    return hint
}

// The width of a column of the grid: what its kind shows, and room for its header.
@(private="file")
records_width :: proc(ctx:^ui.Context,c:^asset.Records_Column) -> f32 {
    width:f32
    switch c.kind {
    case .Bool:              width=72
    case .Int,.Float:        width=96
    case .Enum:              width=120
    case .Asset,.Record:     width=140
    case .Text,.Type:        width=150
    case .String:            width=clamp(f32(c.length)*5,120,220)
    }
    header:=ui.text_width(&ctx.font,records.column_name(c),ui.metric(ctx,"font_small"))+ui.text_width(&ctx.font,records_hint(c),ui.metric(ctx,"font_caption"))+2*RECORDS_PAD+10
    return min(max(width,header),320)
}

// ---------------------------------------------------------------- grid

@(private="file")
records_grid :: proc(s:^Session,r:^Records_Document,app:^host.App) {
    ctx:=s.gui.ctx
    if !r.read {
        if ui.box(ctx,{width=ui.GROW,height=ui.GROW,padding={14,12,14,12}}) {ui.text(ctx,base.text_get(r.problem[:]),ui.prose(ctx,ui.metric(ctx,"font_small"),ui.tone(ctx,"text_muted")))}
        return
    }
    e:=&r.edit
    control:=ui.metric(ctx,"control")
    if ui.box(ctx,{width=ui.GROW,height=ui.fixed(control+14),padding={12,7,12,7},gap=6,align_y=.Center}) {
        if ui.button(ctx,ui.id(ctx,"add"),{label="Add row",icon=.Plus,variant="field",height=control,size=ui.metric(ctx,"font_small")}).clicked {records_grid_add(s,r)}
        if r.selected>=0 && r.column<0 {
            if ui.button(ctx,ui.id(ctx,"duplicate"),{label="Duplicate",icon=.Copy,variant="field",height=control,size=ui.metric(ctx,"font_small")}).clicked {records_grid_duplicate(s,r)}
            if ui.button(ctx,ui.id(ctx,"remove"),{label="Delete",icon=.Cross,variant="field",height=control,size=ui.metric(ctx,"font_small")}).clicked {
                records.row_remove(e,r.selected)
                r.selected=min(r.selected,records.row_count(e)-1)
                r.cell=-1
                r.changed=true
            }
        }
    }
    if ui.box(ctx,{width=ui.GROW,height=ui.fixed(1),fill=ui.tone(ctx,"divider")}) {}
    widths:=make([]f32,len(e.columns),context.temp_allocator)
    width:=f32(RECORDS_INDEX_WIDTH+RECORDS_NAME_WIDTH)
    for &c,at in e.columns {
        widths[at]=records_width(ctx,&c)
        width+=widths[at]
    }
    if e.info.declares {width+=RECORDS_ADD_WIDTH}
    header_height:=ui.metric(ctx,"row")+10
    row_height:=ui.metric(ctx,"row")+6
    area_id:=ui.id(ctx,"rows")
    area,_:=ui.widget_rect(ctx,area_id)
    // The names of the columns stay on top while the rows scroll under them,
    // and move across with them, within the width of the rows.
    r.scroll[0]=clamp(r.scroll[0],0,max(width-area.w,0))
    if ui.box(ctx,{id=ui.id(ctx,"header"),width=ui.GROW,height=ui.fixed(header_height),clip_x=true,scroll={r.scroll[0],0}}) {
        if ui.box(ctx,{width=ui.fixed(width),height=ui.fixed(header_height),align_y=.Center,fill=ui.tone(ctx,"card")}) {
            ui.spacer(ctx,RECORDS_INDEX_WIDTH,header_height)
            // The corner shows the settings of the table, which show when nothing else is chosen.
            corner:=ui.id(ctx,"corner")
            if ui.box(ctx,{id=corner,width=ui.fixed(RECORDS_NAME_WIDTH),height=ui.GROW,padding={RECORDS_PAD,0,RECORDS_PAD,0},align_y=.Center,track=true,fill=records_header_fill(ctx,corner,false)}) {
                ui.text(ctx,"Name",{size=ui.metric(ctx,"font_small"),color=ui.tone(ctx,"text_label"),font=ui.FONT_MEDIUM,align_y=.Center},ui.GROW)
            }
            if records_pressed(ctx,corner) {r.selected,r.column,r.cell=-1,-1,-1}
            for &c,at in e.columns {records_header_cell(s,r,&c,at,widths[at])}
            if e.info.declares {
                if ui.box(ctx,{width=ui.fixed(RECORDS_ADD_WIDTH),height=ui.GROW,align_x=.Center,align_y=.Center}) {
                    if ui.button(ctx,ui.id(ctx,"column_add"),{icon=.Plus,icon_color=ui.tone(ctx,"text_muted"),icon_size=14,variant="ghost",width=24,height=24,center=true}).clicked {records_column_add(s,r)}
                }
            }
        }
    }
    if ui.box(ctx,{width=ui.GROW,height=ui.fixed(1),fill=ui.tone(ctx,"border")}) {}
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
        for row in first..<last {records_grid_row(s,r,app,row,widths,width,row_height)}
        ui.spacer(ctx,width,f32(count-last)*row_height)
    }
}

// The fill of a header: selected, under the pointer, or none.
@(private="file")
records_header_fill :: proc(ctx:^ui.Context,id:ui.Id,selected:bool) -> ui.Color {
    if selected {return ui.tone(ctx,"accent_soft")}
    if area,shown:=ui.widget_rect(ctx,id);shown && ctx.popup.count==0 && ui.rect_contains(area,ctx.pointer) {return ui.tone(ctx,"field_hover")}
    return {}
}

// Whether the left button went down on a box this frame, with no popup open.
@(private="file")
records_pressed :: proc(ctx:^ui.Context,id:ui.Id) -> bool {
    area,shown:=ui.widget_rect(ctx,id)
    return shown && .Left in ctx.input.pressed && ctx.popup.count==0 && ui.rect_contains(area,ctx.pointer)
}

@(private="file")
records_header_cell :: proc(s:^Session,r:^Records_Document,c:^asset.Records_Column,at:int,width:f32) {
    ctx:=s.gui.ctx
    id:=ui.id(ctx,"header",at+1)
    selected:=r.column==at
    if ui.box(ctx,{id=id,width=ui.fixed(width),height=ui.GROW,direction=.Column,track=true,fill=records_header_fill(ctx,id,selected)}) {
        if ui.box(ctx,{width=ui.GROW,height=ui.GROW,padding={RECORDS_PAD,0,RECORDS_PAD,0},gap=6,align_y=.Center,clip_x=true}) {
            ui.text(ctx,records.column_name(c),{size=ui.metric(ctx,"font_small"),color=ui.tone(ctx,"text") if selected else ui.tone(ctx,"text_label"),font=ui.FONT_MEDIUM,align_y=.Center,ellipsis=true},ui.GROW)
            ui.text(ctx,records_hint(c),{size=ui.metric(ctx,"font_caption"),color=ui.tone(ctx,"text_faint"),align_y=.Center})
        }
        if ui.box(ctx,{width=ui.GROW,height=ui.fixed(2),fill=ui.tone(ctx,"accent") if selected else {}}) {}
    }
    if description:=serial.text_field(c.description[:]);description!="" {
        area,shown:=ui.widget_rect(ctx,id)
        inspector_description(s,id,description,shown && ctx.popup.count==0 && ui.rect_contains(area,ctx.pointer))
    }
    if records_pressed(ctx,id) {r.column,r.selected,r.cell=at,-1,-1}
}

@(private="file")
records_grid_row :: proc(s:^Session,r:^Records_Document,app:^host.App,row:int,widths:[]f32,width,height:f32) {
    ctx:=s.gui.ctx
    e:=&r.edit
    ui.id_push(ctx,ui.Id(e.ids[row]))
    defer ui.id_pop(ctx)
    line:=ui.id(ctx,"row")
    selected:=r.selected==row && r.column<0
    fill:ui.Color
    if area,shown:=ui.widget_rect(ctx,line);shown && ctx.popup.count==0 && ui.rect_contains(area,ctx.pointer) {fill=ui.tone(ctx,"field_hover")}
    if selected {fill=ui.tone(ctx,"accent_soft")}
    font:=ui.metric(ctx,"font_small")
    if ui.box(ctx,{id=line,width=ui.fixed(width),height=ui.fixed(height),align_y=.Center,fill=fill,track=true}) {
        if ui.box(ctx,{width=ui.fixed(RECORDS_INDEX_WIDTH),height=ui.GROW,padding={0,0,RECORDS_PAD,0},align_x=.End,align_y=.Center}) {
            ui.text(ctx,fmt.tprint(row+1),{size=ui.metric(ctx,"font_caption"),color=ui.tone(ctx,"accent") if selected else ui.tone(ctx,"text_faint"),align_y=.Center})
        }
        name:=ui.id(ctx,"name_cell")
        if ui.box(ctx,{id=name,width=ui.fixed(RECORDS_NAME_WIDTH),height=ui.GROW,padding={RECORDS_PAD-4,2,6,2},align_y=.Center,track=true,clip_x=true}) {
            if selected && r.cell==RECORDS_NAME_CELL {
                records_name_field(s,r,row,ui.id(ctx,"name"),ui.metric(ctx,"row"))
            } else {
                ui.box_begin(ctx,{width=ui.GROW,height=ui.GROW,padding={4,0,0,0},align_y=.Center})
                ui.text(ctx,records.row_name(e,row),{size=font,color=ui.tone(ctx,"text"),font=ui.FONT_MEDIUM,align_y=.Center,ellipsis=true},ui.GROW)
                ui.box_end(ctx,{})
            }
        }
        if records_pressed(ctx,name) {r.selected,r.column,r.cell=row,-1,RECORDS_NAME_CELL}
        // A column the + of the header added this frame shows from the next one, with its width.
        for &c,at in e.columns[:min(len(e.columns),len(widths))] {
            cell:=ui.id(ctx,"cell_box",at+1)
            band:=r.column==at ? ui.tone(ctx,"accent_soft") : ui.Color{}
            if ui.box(ctx,{id=cell,width=ui.fixed(widths[at]),height=ui.GROW,padding={4,2,4,2},align_y=.Center,track=true,clip_x=true,fill=band,stroke=ui.tone(ctx,"accent") if selected && r.cell==at else {},stroke_width=1,radius=ui.metric(ctx,"radius_control")}) {
                if records_cell(s,r,app,row,&c,at,widths[at]-8,selected && r.cell==at) {r.selected,r.changed=row,true}
            }
            if records_pressed(ctx,cell) {r.selected,r.column,r.cell=row,-1,at}
        }
    }
    if records_pressed(ctx,line) && r.selected!=row {r.selected,r.column,r.cell=row,-1,-1}
    if ui.box(ctx,{width=ui.fixed(width),height=ui.fixed(1),fill=ui.tone(ctx,"row_rule")}) {}
}

@(private="file")
records_name_field :: proc(s:^Session,r:^Records_Document,row:int,id:ui.Id,height:f32) {
    ctx:=s.gui.ctx
    buffer:[asset.RECORDS_NAME]u8
    length:=copy(buffer[:asset.RECORDS_NAME-1],records.row_name(&r.edit,row))
    result:=ui.text_field(ctx,id,buffer[:asset.RECORDS_NAME-1],&length,{height=height,size=ui.metric(ctx,"font_small")})
    if !result.changed {return}
    if problem:=records.row_rename(&r.edit,row,string(buffer[:length]));problem!="" {notify(s,problem)} else {r.changed=true}
}

// A cell of a row: its value as text, or, open, the control that edits it;
// a checkbox is always one. True when it changed the value.
@(private="file")
records_cell :: proc(s:^Session,r:^Records_Document,app:^host.App,row:int,c:^asset.Records_Column,at:int,width:f32,open:bool) -> (changed:bool) {
    ctx:=s.gui.ctx
    e:=&r.edit
    field,_:=records.column_field(e,at)
    type:=e.schema.types[field.type]
    value:=records.row_bytes(e,row)[field.offset:][:type.size]
    p:=raw_data(value)
    id:=ui.id(ctx,"cell",at+1)
    height:=ui.metric(ctx,"row")
    if c.count==0 && c.kind==.Bool {
        if ui.box(ctx,{width=ui.GROW,height=ui.GROW,padding={RECORDS_PAD-4,0,0,0},align_y=.Center}) {changed=ui.checkbox(ctx,id,cast(^bool)p)}
        return
    }
    if open && c.count==0 {
        #partial switch c.kind {
        case .Asset:
            return held_asset_button(s,id,KEY_RECORDS_ROW~(u64(row)<<20|u64(at)),field_asset_kinds(s,field),cast(^base.Asset_Id)p,width)
        case .Record:
            if record:=records_built(s,serial.text_field(c.type[:]));record>=0 {
                return record_choice(s,id,record,cast(^core.Record_Id)&value[size_of(base.Asset_Id)],cast(^base.Asset_Id)p,ui.fixed(width))
            }
        case .Enum:
            choices:=e.schema.choices[type.first:][:type.count]
            options:=make([]string,len(choices),context.temp_allocator)
            for choice,i in choices {options[i]=readable(choice.name)}
            selected:=choice_at(p,len(value),choices)
            if ui.dropdown(ctx,id,{list=options},&selected,{width=-1,height=height}) && selected>=0 {
                chosen:=choices[selected].value
                copy(value,mem.ptr_to_bytes(&chosen)[:len(value)])
                return true
            }
            return false
        case .Int,.Float:
            desc,scale:=field_number(field,type)
            desc.height=height
            number:=number_read(p,type)*scale
            result:=ui.number_field(ctx,id,&number,desc)
            if result.changed {number_write(p,type,number/scale)}
            return result.changed
        case .String,.Text:
            text:=value[:len(value)-1]
            length:=base.text_len(text)
            result:=ui.text_field(ctx,id,text,&length,{height=height,size=ui.metric(ctx,"font_small")})
            if result.changed || result.committed {
                mem.zero_slice(text[length:])
                return true
            }
            return false
        }
    }
    shown,faint:=records_cell_text(s,e,c,field,value)
    if ui.box(ctx,{width=ui.GROW,height=ui.GROW,padding={RECORDS_PAD-4,0,4,0},align_y=.Center}) {
        align:=ui.Align.End if c.count==0 && (c.kind==.Int || c.kind==.Float) else .Start
        ui.text(ctx,shown,{size=ui.metric(ctx,"font_small"),color=ui.tone(ctx,"text_faint") if faint else ui.tone(ctx,"text"),align_x=align,align_y=.Center,ellipsis=true},ui.GROW)
    }
    return false
}

// What a cell shows of a value; faint: the value says nothing (zero, none).
@(private="file")
records_cell_text :: proc(s:^Session,e:^records.Edit,c:^asset.Records_Column,field:serial.Field,value:[]u8) -> (text:string,faint:bool) {
    if c.count>0 || c.kind==.Type {
        if mem.check_zero(value) {return "Empty",true}
        return records_summary(&e.schema,field.type,value,0),false
    }
    type:=e.schema.types[field.type]
    p:=raw_data(value)
    unit:=serial.text_field(c.unit[:])
    #partial switch c.kind {
    case .Int,.Float:
        number:=ui.number_format(make([]u8,48,context.temp_allocator),number_read(p,type))
        return unit!="" ? fmt.tprintf("%s %s",number,unit) : number,false
    case .Enum:
        choices:=e.schema.choices[type.first:][:type.count]
        if at:=choice_at(p,len(value),choices);at>=0 {return readable(choices[at].name),false}
        return "?",true
    case .Asset:
        id:=(cast(^base.Asset_Id)p)^
        if id=={} {return "None",true}
        if path:=asset_path(s,id);path!="" {return asset_name(path),false}
        return "Missing",true
    case .Text,.String:
        text:=serial.text_field(value)
        return text,false
    case .Record:
        ref:=(cast(^core.Record(int))p)^
        if ref=={} {return "None",true}
        if record:=records_built(s,serial.text_field(c.type[:]));record>=0 {
            if set:=host.app_record_set(s.app,record);set!=nil {
                if at:=core.record_index(set,ref.table,ref.row,set.size);at>=0 {return base.text_get(set.rows[at].name[:]),false}
            }
            return "Missing",true
        }
        return fmt.tprintf("Row %d",u64(ref.row)),false
    }
    return "",true
}

// A short line of what a value holds: its fields or elements that are set.
@(private="file")
records_summary :: proc(schema:^serial.Schema,type:serial.Type_Index,value:[]u8,depth:int) -> string {
    t:=schema.types[type]
    p:=raw_data(value)
    if t.named!=.None {return fmt.tprint(i64(number_read(p,t)))}
    #partial switch t.kind {
    case .Bool:  return "yes" if (cast(^bool)p)^ else "no"
    case .Int,.Uint,.Float: return ui.number_format(make([]u8,48,context.temp_allocator),number_read(p,t))
    case .Enum:
        choices:=schema.choices[t.first:][:t.count]
        if at:=choice_at(p,len(value),choices);at>=0 {return readable(choices[at].name)}
    case .Array:
        elem:=schema.types[t.elem]
        if serial.type_is_bytes(schema,type) {return serial.text_field(value)}
        set:=0
        for i in 0..<int(t.count) {
            if !mem.check_zero(value[i*int(elem.size):][:elem.size]) {set+=1}
        }
        return fmt.tprintf("%d of %d",set,t.count)
    case .Struct:
        if depth>0 {return "{...}"}
        parts:=make([dynamic]string,context.temp_allocator)
        for f in serial.schema_fields(schema,type) {
            size:=int(schema.types[f.type].size)
            part:=value[f.offset:][:size]
            if mem.check_zero(part) {continue}
            append(&parts,fmt.tprintf("%s %s",f.name,records_summary(schema,f.type,part,depth+1)))
            if len(parts)==3 {break}
        }
        return strings.join(parts[:],", ",context.temp_allocator)
    }
    return "set"
}

@(private="file")
records_grid_add :: proc(s:^Session,r:^Records_Document) {
    e:=&r.edit
    base_name:=strings.to_lower(records.type_name(e),context.temp_allocator)
    name:=base_name
    for n:=2;records.row_find(e,name)>=0;n+=1 {name=fmt.tprintf("%s_%d",base_name,n)}
    row,problem:=records.row_add(e,&s.id_state,name,nil,r.selected)
    if problem!="" {notify(s,problem);return}
    r.selected,r.column,r.cell,r.reveal,r.changed=row,-1,RECORDS_NAME_CELL,true,true
}

@(private="file")
records_grid_duplicate :: proc(s:^Session,r:^Records_Document) {
    e:=&r.edit
    original:=records.row_name(e,r.selected)
    name:=fmt.tprintf("%s_copy",original)
    for n:=2;records.row_find(e,name)>=0;n+=1 {name=fmt.tprintf("%s_copy_%d",original,n)}
    row,problem:=records.row_duplicate(e,&s.id_state,r.selected,name)
    if problem!="" {notify(s,problem);return}
    r.selected,r.cell,r.reveal,r.changed=row,-1,true,true
}

// A new column at the end of the type, selected for the panel to edit it.
@(private="file")
records_column_add :: proc(s:^Session,r:^Records_Document) {
    e:=&r.edit
    c:=records.column_new(e,.Int)
    if problem:=records.column_add(e,s.app.info,c);problem!="" {notify(s,problem);return}
    r.column,r.selected,r.cell,r.changed=len(e.columns)-1,-1,-1,true
    r.scroll[0]=1e9
}

// ---------------------------------------------------------------- the panel

@(private="file")
records_details :: proc(s:^Session,r:^Records_Document) {
    ctx:=s.gui.ctx
    if !r.read {return}
    e:=&r.edit
    if ui.scroll_area(ctx,ui.id(ctx,"details"),&r.details_scroll,{width=ui.GROW,height=ui.GROW,direction=.Column,gap=4,padding={12,10,12,12}}) {
        switch {
        case r.column>=0 && r.column<len(e.columns):        records_column_panel(s,r,r.column)
        case r.selected>=0 && r.selected<records.row_count(e): records_row_panel(s,r,r.selected)
        case:                                               records_table_panel(s,r)
        }
    }
}

// The name and every field of a row, with the rows of Details.
@(private="file")
records_row_panel :: proc(s:^Session,r:^Records_Document,row:int) {
    ctx:=s.gui.ctx
    e:=&r.edit
    row_begin(ctx,"Name")
    records_name_field(s,r,row,ui.id(ctx,"row_name"),ui.metric(ctx,"row"))
    row_end(ctx)
    records_rule(ctx)
    h:=Held_Values{key=KEY_RECORDS_ROW~e.ids[row],value=raw_data(records.row_bytes(e,row)),defaults=raw_data(e.defaults),width=RECORDS_DETAILS_WIDTH-24}
    for &c,at in e.columns {
        field,_:=records.column_field(e,at)
        if held_schema_row(s,h,&e.schema,e.type,field,readable(field.name),serial.text_field(c.description[:])) {r.changed=true}
    }
}

@(private="file")
records_rule :: proc(ctx:^ui.Context) {
    if ui.box(ctx,{width=ui.GROW,height=ui.fixed(9),align_y=.Center}) {
        if ui.box(ctx,{width=ui.GROW,height=ui.fixed(1),fill=ui.tone(ctx,"divider")}) {}
    }
}

// A line of text of the panel, written when it is applied (Enter, Tab or a
// click elsewhere); changed: it was, and text is what it says.
@(private="file")
records_text_row :: proc(ctx:^ui.Context,id:ui.Id,label,value:string,capacity:int) -> (text:string,changed:bool) {
    row_begin(ctx,label)
    buffer:=make([]u8,capacity,context.temp_allocator)
    length:=copy(buffer[:capacity-1],value)
    result:=ui.text_field(ctx,id,buffer[:capacity-1],&length,{height=ui.metric(ctx,"row"),size=ui.metric(ctx,"font_small")})
    row_end(ctx)
    if result.changed {return strings.trim_space(string(buffer[:length])),true}
    return value,false
}

@(private="file")
records_number_row :: proc(ctx:^ui.Context,id:ui.Id,label:string,value:^f64,desc:ui.Number_Field) -> bool {
    row_begin(ctx,label)
    field:=desc
    field.height=ui.metric(ctx,"row")
    result:=ui.number_field(ctx,id,value,field)
    row_end(ctx)
    return result.changed
}

// A bound of a number column: whether it has one, and its value.
@(private="file")
records_bound_row :: proc(ctx:^ui.Context,id:ui.Id,label:string,has:^bool,value:^f64) -> (changed:bool) {
    row_begin(ctx,label)
    changed=ui.checkbox(ctx,ui.id_derive(ctx,id,"has"),has)
    if !has^ {ui.disabled_begin(ctx)}
    changed|=ui.number_field(ctx,id,value,{height=ui.metric(ctx,"row"),speed=0.05}).changed
    if !has^ {ui.disabled_end(ctx)}
    row_end(ctx)
    return
}

@(private="file")
records_column_panel :: proc(s:^Session,r:^Records_Document,at:int) {
    ctx:=s.gui.ctx
    e:=&r.edit
    c:=e.columns[at]
    declares:=e.info.declares
    if !declares {
        records_declaring_link(s,r)
        ui.disabled_begin(ctx)
    }
    defer if !declares {ui.disabled_end(ctx)}
    changed:=false
    if text,typed:=records_text_row(ctx,ui.id(ctx,"column_name"),"Name",records.column_name(&c),asset.RECORDS_NAME);typed && text!=records.column_name(&c) {
        c.name={}
        base.text_set(c.name[:],text)
        changed=true
    }
    row_begin(ctx,"Kind")
    labels:=RECORDS_KIND_LABELS
    kinds:=make([]string,len(asset.Records_Kind),context.temp_allocator)
    for kind in asset.Records_Kind {kinds[int(kind)]=labels[kind]}
    kind:=int(c.kind)
    if ui.dropdown(ctx,ui.id(ctx,"column_kind"),{list=kinds},&kind,{width=-1,height=ui.metric(ctx,"row")}) && kind>=0 && asset.Records_Kind(kind)!=c.kind {
        records.kind_set(e,&c,asset.Records_Kind(kind))
        // A column of a type of the code starts with the first its package declares.
        if c.kind==.Type && s.app.info!=nil {
            for &code in s.app.info.record_codes {
                if code.folder==e.folder {base.text_set(c.type[:],code.name);break}
            }
        }
        changed=true
    }
    row_end(ctx)
    #partial switch c.kind {
    case .Int,.Float:
        changed|=records_bound_row(ctx,ui.id(ctx,"column_min"),"Min",&c.has_min,&c.min)
        changed|=records_bound_row(ctx,ui.id(ctx,"column_max"),"Max",&c.has_max,&c.max)
        if text,typed:=records_text_row(ctx,ui.id(ctx,"column_unit"),"Unit",serial.text_field(c.unit[:]),asset.RECORDS_UNIT);typed {
            c.unit={}
            base.text_set(c.unit[:],text)
            changed=true
        }
    case .Enum:
        if text,typed:=records_text_row(ctx,ui.id(ctx,"column_enum"),"Enum",serial.text_field(c.type[:]),asset.RECORDS_TYPE);typed {
            c.type={}
            base.text_set(c.type[:],text)
            changed=true
        }
        if text,typed:=records_text_row(ctx,ui.id(ctx,"column_values"),"Values",serial.text_field(c.values[:]),asset.RECORDS_VALUES);typed {
            c.values={}
            base.text_set(c.values[:],text)
            changed=true
        }
    case .Asset:
        if text,typed:=records_text_row(ctx,ui.id(ctx,"column_assets"),"Kinds",serial.text_field(c.asset_kind[:]),asset.RECORDS_UNIT);typed {
            c.asset_kind={}
            base.text_set(c.asset_kind[:],text)
            changed=true
        }
    case .String:
        length:=f64(c.length)
        if records_number_row(ctx,ui.id(ctx,"column_length"),"Bytes",&length,{integer=true,has_min=true,min=2,has_max=true,max=asset.RECORDS_LENGTH,speed=0.2}) {
            c.length=u16(clamp(length,2,asset.RECORDS_LENGTH))
            changed=true
        }
    case .Record:
        names:=records_type_names(s)
        selected:=-1
        for name,i in names {
            if name==serial.text_field(c.type[:]) {selected=i}
        }
        row_begin(ctx,"Table of")
        if ui.dropdown(ctx,ui.id(ctx,"column_record"),{list=names},&selected,{width=-1,height=ui.metric(ctx,"row"),searchable=true,empty=serial.text_field(c.type[:])}) && selected>=0 {
            c.type={}
            base.text_set(c.type[:],names[selected])
            changed=true
        }
        row_end(ctx)
    case .Type:
        names:=make([dynamic]string,context.temp_allocator)
        selected:=-1
        if s.app.info!=nil {
            for &code in s.app.info.record_codes {
                if code.folder!=e.folder {continue}
                if code.name==serial.text_field(c.type[:]) {selected=len(names)}
                append(&names,code.name)
            }
        }
        row_begin(ctx,"Type")
        if ui.dropdown(ctx,ui.id(ctx,"column_code"),{list=names[:]},&selected,{width=-1,height=ui.metric(ctx,"row"),searchable=true,empty=serial.text_field(c.type[:])}) && selected>=0 {
            c.type={}
            base.text_set(c.type[:],names[selected])
            changed=true
        }
        row_end(ctx)
    }
    count:=f64(c.count)
    if records_number_row(ctx,ui.id(ctx,"column_count"),"Array length",&count,{integer=true,has_min=true,min=0,has_max=true,max=asset.RECORDS_COUNT,speed=0.05}) {
        c.count=u16(clamp(count,0,asset.RECORDS_COUNT))
        changed=true
    }
    if text,typed:=records_text_row(ctx,ui.id(ctx,"column_description"),"Description",serial.text_field(c.description[:]),asset.RECORDS_DESCRIPTION);typed {
        c.description={}
        base.text_set(c.description[:],text)
        changed=true
    }
    if changed {
        if problem:=records.column_change(e,s.app.info,at,c);problem!="" {notify(s,problem)} else {r.changed,r.cell=true,-1}
        return
    }
    records_rule(ctx)
    // What a new row starts with in this column.
    if field,found:=records.column_field(e,at);found {
        zeros:=make([]u8,records.row_size(e),context.temp_allocator)
        h:=Held_Values{key=KEY_RECORDS_DEFAULT~u64(at+1),value=raw_data(e.defaults),defaults=raw_data(zeros),width=RECORDS_DETAILS_WIDTH-24}
        if held_schema_row(s,h,&e.schema,e.type,field,"Default") {r.changed=true}
    }
    if !declares {return}
    records_rule(ctx)
    if ui.box(ctx,{width=ui.GROW,height=ui.fixed(ui.metric(ctx,"control")),gap=6,align_y=.Center}) {
        control:=ui.metric(ctx,"control")
        if ui.button(ctx,ui.id(ctx,"column_left"),{label="Move left",variant="field",height=control,size=ui.metric(ctx,"font_small"),disabled=at==0}).clicked {records_column_move(s,r,at,at-1)}
        if ui.button(ctx,ui.id(ctx,"column_right"),{label="Move right",variant="field",height=control,size=ui.metric(ctx,"font_small"),disabled=at==len(e.columns)-1}).clicked {records_column_move(s,r,at,at+1)}
        ui.spacer(ctx)
        if ui.button(ctx,ui.id(ctx,"column_remove"),{label="Delete column",icon=.Cross,variant="field",height=control,size=ui.metric(ctx,"font_small")}).clicked {
            if problem:=records.column_remove(e,s.app.info,at);problem!="" {notify(s,problem)} else {
                r.column,r.cell,r.changed=min(at,len(e.columns)-1),-1,true
            }
        }
    }
}

@(private="file")
records_column_move :: proc(s:^Session,r:^Records_Document,from,to:int) {
    if problem:=records.column_move(&r.edit,s.app.info,from,to);problem!="" {notify(s,problem);return}
    r.column,r.cell,r.changed=to,-1,true
}

// The table itself: the name of its type, its description and what it holds.
@(private="file")
records_table_panel :: proc(s:^Session,r:^Records_Document) {
    ctx:=s.gui.ctx
    e:=&r.edit
    if !e.info.declares {
        records_declaring_link(s,r)
        readonly_row(ctx,"Rows of",records.type_name(e))
        readonly_row(ctx,"Rows",fmt.tprint(records.row_count(e)))
        return
    }
    if text,typed:=records_text_row(ctx,ui.id(ctx,"table_type"),"Type",records.type_name(e),asset.RECORDS_TYPE);typed && text!=records.type_name(e) {
        if problem:=records.type_rename(e,text);problem!="" {notify(s,problem)} else {r.changed=true}
    }
    if text,typed:=records_text_row(ctx,ui.id(ctx,"table_description"),"Description",records.description(e),asset.RECORDS_DESCRIPTION);typed {
        records.description_set(e,text)
        r.changed=true
    }
    records_rule(ctx)
    readonly_row(ctx,"Rows",fmt.tprint(records.row_count(e)))
    readonly_row(ctx,"Columns",fmt.tprint(len(e.columns)))
}

// The button that opens the table that declares the type of the rows, where its columns change.
@(private="file")
records_declaring_link :: proc(s:^Session,r:^Records_Document) {
    ctx:=s.gui.ctx
    path:=asset_path(s,r.edit.declaring)
    if path=="" {return}
    if ui.button(ctx,ui.id(ctx,"declaring"),{label=fmt.tprintf("Edit columns in %s",asset_name(path)),icon=.Chevron_Right,icon_after=true,variant="field",width=-1,height=ui.metric(ctx,"control"),size=ui.metric(ctx,"font_small")}).clicked {
        asset_document_open(s,r.edit.declaring,"")
    }
    records_rule(ctx)
}

// ---------------------------------------------------------------- references

// A row of the tables of a record type, for a core.Record field: a list of
// their names (with the table when there are several), and a button that
// opens the table at the row. A row no table has shows Missing. True when
// the list changed it.
record_choice :: proc(s:^Session,id:ui.Id,record:int,row:^core.Record_Id,table:^base.Asset_Id,width:ui.Size) -> (changed:bool) {
    ctx:=s.gui.ctx
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
    if ui.box(ctx,{width=width,height=ui.fixed(ui.metric(ctx,"row")),gap=2,align_y=.Center}) {
        if ui.dropdown(ctx,id,{list=options},&selected,{width=-1,height=ui.metric(ctx,"row"),searchable=true,empty="Missing"}) && selected>=0 {
            if selected==0 {
                table^,row^={},0
            } else {
                table^,row^=set.rows[selected-1].table,set.rows[selected-1].row
            }
            changed=true
        }
        if table^!={} && ui.button(ctx,ui.id_derive(ctx,id,"open"),{icon=.Chevron_Right,variant="ghost",width=ui.metric(ctx,"row"),height=ui.metric(ctx,"row")}).clicked {
            name:=""
            if set!=nil {
                if at:=core.record_index(set,table^,row^,set.size);at>=0 {name=base.text_get(set.rows[at].name[:])}
            }
            asset_document_open(s,table^,name)
        }
    }
    return
}
