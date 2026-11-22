package kai

import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"
import "mirai:std/blake3"
import "mirai:store"

// What a web view shows of a file it does not read: the summary of an asset,
// its thumbnail and the detail of what a change did to it. Each is derived
// data a peer that reads the file makes and publishes as a DDC record of the
// org (cook/kai), keyed by what it is made from: the content address of the
// file, or the two of a change, and PREVIEW_VERSION. A node holds and serves
// one without reading the asset; it takes only what preview_check accepts,
// whoever signed it. A file of a scope gets none: its derived data names the
// scope as tainted and is never shown.
//
// A summary is UTF-8 text: PREVIEW_SUMMARY_HEAD, the kind, then a line
// "label<TAB>value" per fact. A detail is PREVIEW_DETAIL_HEAD, a line
// "added<TAB>removed<TAB>changed<TAB>cut", then "mark<TAB>name<TAB>text" per
// row, mark one of + - ~. Every line ends with a line feed and no other byte
// below 0x20 but the tab. A thumbnail is a PNG.

PREVIEW_VERSION :: 1 // raised when what cook/kai makes of the same file changes
LABEL_PREVIEW :: "kai-1/preview"
PREVIEW_SUMMARY_HEAD :: "kai-summary 1"
PREVIEW_DETAIL_HEAD :: "kai-detail 1"

Preview_Kind :: enum u8 {Summary=1,Thumbnail=2,Detail=3}

PREVIEW_SUMMARY_MAX :: 8<<10 // bytes
PREVIEW_THUMBNAIL_MAX :: 384<<10
PREVIEW_DETAIL_MAX :: 128<<10
PREVIEW_KIND_MAX :: 32
PREVIEW_FACTS_MAX :: 16
PREVIEW_LABEL_MAX :: 48
PREVIEW_VALUE_MAX :: 256
PREVIEW_ROWS_MAX :: 200
PREVIEW_NAME_MAX :: 64
PREVIEW_TEXT_MAX :: 512
PREVIEW_SIDE_MAX :: 512 // pixels of a thumbnail's side

Preview_Fact :: struct {label,value:string}

Preview_Row :: struct {
    mark:u8,     // '+' added, '-' removed, '~' changed
    name:string, // the entity or row it is on; "" none
    text:string,
}

Preview_Detail :: struct {
    added,removed,changed:int,
    cut:int, // rows past those kept
    rows:[]Preview_Row,
}

// The key of the preview of kind made from the file at to (a summary, a
// thumbnail) or from the change of from into to (a detail; zero for a side
// that is not there).
preview_key :: proc(kind:Preview_Kind,from,to:store.Hash) -> store.Hash {
    h:blake3.Hasher
    blake3.init(&h)
    blake3.update(&h,transmute([]u8)string(LABEL_PREVIEW))
    head:=[3]u8{u8(kind),u8(PREVIEW_VERSION),u8(PREVIEW_VERSION>>8)}
    blake3.update(&h,head[:])
    a,b:=from,to
    blake3.update(&h,a[:])
    blake3.update(&h,b[:])
    return store.Hash(blake3.final(&h))
}

// text as a field of a preview: control bytes as spaces, cut to max bytes
// between characters, in builder.
@(private)
preview_text :: proc(b:^strings.Builder,text:string,max:int) {
    cut:=min(len(text),max)
    for cut>0 && cut<len(text) && !utf8.rune_start(text[cut]) {cut-=1}
    for r in text[:cut] {
        if r==utf8.RUNE_ERROR {
            strings.write_byte(b,'?')
        } else if r<0x20 || r==0x7f {
            strings.write_byte(b,' ')
        } else {
            strings.write_rune(b,r)
        }
    }
}

// The bytes of a summary of kind with facts, in allocator; Too_Large past
// PREVIEW_FACTS_MAX facts. Texts are cut to their bounds.
preview_summary_encode :: proc(kind:string,facts:[]Preview_Fact,allocator:=context.allocator) -> (bytes:[]u8,error:Error) {
    if len(facts)>PREVIEW_FACTS_MAX {return nil,.Too_Large}
    if kind=="" {return nil,.Invalid_Argument}
    b:=strings.builder_make(allocator)
    strings.write_string(&b,PREVIEW_SUMMARY_HEAD)
    strings.write_byte(&b,'\n')
    preview_text(&b,kind,PREVIEW_KIND_MAX)
    strings.write_byte(&b,'\n')
    for f in facts {
        if f.label=="" {
            strings.builder_destroy(&b)
            return nil,.Invalid_Argument
        }
        preview_text(&b,f.label,PREVIEW_LABEL_MAX)
        strings.write_byte(&b,'\t')
        preview_text(&b,f.value,PREVIEW_VALUE_MAX)
        strings.write_byte(&b,'\n')
    }
    if len(b.buf)>PREVIEW_SUMMARY_MAX {
        strings.builder_destroy(&b)
        return nil,.Too_Large
    }
    return b.buf[:],.None
}

// The kind and facts of the summary in bytes, which they point into: Corrupt
// for anything preview_summary_encode does not make.
preview_summary_decode :: proc(bytes:[]u8,facts:^[dynamic]Preview_Fact) -> (kind:string,error:Error) {
    clear(facts)
    text:=preview_lines(bytes,.Summary) or_return
    head,_:=strings.split_lines_iterator(&text)
    if head!=PREVIEW_SUMMARY_HEAD {return "",.Corrupt}
    kind,_=strings.split_lines_iterator(&text)
    if kind=="" || len(kind)>PREVIEW_KIND_MAX || strings.index_byte(kind,'\t')>=0 {return "",.Corrupt}
    for line in strings.split_lines_iterator(&text) {
        tab:=strings.index_byte(line,'\t')
        if tab<=0 || tab>PREVIEW_LABEL_MAX || len(line)-tab-1>PREVIEW_VALUE_MAX || strings.index_byte(line[tab+1:],'\t')>=0 || len(facts)>=PREVIEW_FACTS_MAX {return "",.Corrupt}
        if _,e:=append(facts,Preview_Fact{line[:tab],line[tab+1:]});e!=nil {return "",.Out_Of_Memory}
    }
    return kind,.None
}

// The bytes of a detail, in allocator: its first PREVIEW_ROWS_MAX rows, the
// rest counted in cut. Texts are cut to their bounds.
preview_detail_encode :: proc(d:^Preview_Detail,allocator:=context.allocator) -> (bytes:[]u8,error:Error) {
    if d.added<0 || d.removed<0 || d.changed<0 || d.cut<0 {return nil,.Invalid_Argument}
    kept:=min(len(d.rows),PREVIEW_ROWS_MAX)
    b:=strings.builder_make(allocator)
    strings.write_string(&b,PREVIEW_DETAIL_HEAD)
    strings.write_byte(&b,'\n')
    for n,i in ([4]int{d.added,d.removed,d.changed,d.cut+len(d.rows)-kept}) {
        if i>0 {strings.write_byte(&b,'\t')}
        strings.write_int(&b,min(n,PREVIEW_COUNT_MAX))
    }
    strings.write_byte(&b,'\n')
    for r in d.rows[:kept] {
        if r.mark!='+' && r.mark!='-' && r.mark!='~' {
            strings.builder_destroy(&b)
            return nil,.Invalid_Argument
        }
        strings.write_byte(&b,r.mark)
        strings.write_byte(&b,'\t')
        preview_text(&b,r.name,PREVIEW_NAME_MAX)
        strings.write_byte(&b,'\t')
        preview_text(&b,r.text,PREVIEW_TEXT_MAX)
        strings.write_byte(&b,'\n')
    }
    if len(b.buf)>PREVIEW_DETAIL_MAX {
        strings.builder_destroy(&b)
        return nil,.Too_Large
    }
    return b.buf[:],.None
}

@(private)
PREVIEW_COUNT_MAX :: 999_999_999

// The detail in bytes, whose rows point into them and go to rows: Corrupt for
// anything preview_detail_encode does not make.
preview_detail_decode :: proc(bytes:[]u8,rows:^[dynamic]Preview_Row) -> (d:Preview_Detail,error:Error) {
    clear(rows)
    text:=preview_lines(bytes,.Detail) or_return
    head,_:=strings.split_lines_iterator(&text)
    if head!=PREVIEW_DETAIL_HEAD {return {},.Corrupt}
    counts,_:=strings.split_lines_iterator(&text)
    n:[4]int
    for &x,i in n {
        tab:=strings.index_byte(counts,'\t')
        field:=tab<0?counts:counts[:tab]
        if (tab<0)!=(i==3) || len(field)==0 || len(field)>9 {return {},.Corrupt}
        for c in transmute([]u8)field {
            if c<'0' || c>'9' {return {},.Corrupt}
        }
        x,_=strconv.parse_int(field,10)
        counts=tab<0?"":counts[tab+1:]
    }
    d.added,d.removed,d.changed,d.cut=n[0],n[1],n[2],n[3]
    for line in strings.split_lines_iterator(&text) {
        if len(line)<3 || (line[0]!='+' && line[0]!='-' && line[0]!='~') || line[1]!='\t' || len(rows)>=PREVIEW_ROWS_MAX {return {},.Corrupt}
        rest:=line[2:]
        tab:=strings.index_byte(rest,'\t')
        if tab<0 || tab>PREVIEW_NAME_MAX || len(rest)-tab-1>PREVIEW_TEXT_MAX || strings.index_byte(rest[tab+1:],'\t')>=0 {return {},.Corrupt}
        if _,e:=append(rows,Preview_Row{line[0],rest[:tab],rest[tab+1:]});e!=nil {return {},.Out_Of_Memory}
    }
    d.rows=rows[:]
    return d,.None
}

// The text of a summary or a detail, when its bytes are lines of UTF-8
// without control bytes but the tab, within the bound of kind.
@(private)
preview_lines :: proc(bytes:[]u8,kind:Preview_Kind) -> (text:string,error:Error) {
    if len(bytes)==0 || len(bytes)>preview_max(kind) || bytes[len(bytes)-1]!='\n' || !utf8.valid_string(string(bytes)) {return "",.Corrupt}
    for c in bytes {
        if (c<0x20 && c!='\t' && c!='\n') || c==0x7f {return "",.Corrupt}
    }
    return string(bytes),.None
}

// The bytes a preview of kind takes at most.
preview_max :: proc "contextless" (kind:Preview_Kind) -> int {
    switch kind {
    case .Summary: return PREVIEW_SUMMARY_MAX
    case .Thumbnail: return PREVIEW_THUMBNAIL_MAX
    case .Detail: return PREVIEW_DETAIL_MAX
    }
    return 0
}

PNG_SIGNATURE :: [8]u8{0x89,'P','N','G','\r','\n',0x1a,'\n'}
@(private) PNG_END :: [12]u8{0,0,0,0,'I','E','N','D',0xae,0x42,0x60,0x82}

// Whether bytes are a preview of kind as a node serves it: a summary or a
// detail its decoder reads, or a PNG whose header names a side of at most
// PREVIEW_SIDE_MAX pixels and which ends where its IEND chunk does.
preview_check :: proc(kind:Preview_Kind,bytes:[]u8) -> Error {
    if len(bytes)>preview_max(kind) {return .Too_Large}
    switch kind {
    case .Summary:
        facts:=make([dynamic]Preview_Fact,context.temp_allocator)
        _,e:=preview_summary_decode(bytes,&facts)
        return e
    case .Detail:
        rows:=make([dynamic]Preview_Row,context.temp_allocator)
        _,e:=preview_detail_decode(bytes,&rows)
        return e
    case .Thumbnail:
        signature,end:=PNG_SIGNATURE,PNG_END
        if len(bytes)<8+25+12 || string(bytes[:8])!=string(signature[:]) || string(bytes[len(bytes)-12:])!=string(end[:]) {return .Corrupt}
        ihdr:=bytes[8:]
        if ihdr[0]!=0 || ihdr[1]!=0 || ihdr[2]!=0 || ihdr[3]!=13 || string(ihdr[4:8])!="IHDR" {return .Corrupt}
        be :: proc(b:[]u8) -> u32 {return u32(b[0])<<24|u32(b[1])<<16|u32(b[2])<<8|u32(b[3])}
        width,height:=be(ihdr[8:12]),be(ihdr[12:16])
        if width==0 || height==0 || width>PREVIEW_SIDE_MAX || height>PREVIEW_SIDE_MAX {return .Corrupt}
        return .None
    }
    return .Invalid_Argument
}

Preview_State :: enum u8 {
    None,     // no record of the key is here, or none a viewer may see
    Fetching, // a record is here and its output is not whole yet
    Found,
}

// The preview of kind under key that a record of org in the store names, in
// allocator: the first record whose output is whole here, names no tainted
// scope and holds what preview_check accepts. Fetching, with the objects that
// would make one whole appended to lacking, while none is but one could be.
preview_get :: proc(s:^store.Store,org:Log_Id,kind:Preview_Kind,key:store.Hash,lacking:^[dynamic]store.Hash,allocator:=context.allocator) -> (bytes:[]u8,state:Preview_State) {
    records:=make([dynamic]DDC_Record,context.temp_allocator)
    if ddc_lookup(s,org,key,&records)!=.None {return nil,.None}
    missing:=make([dynamic]store.Hash,context.temp_allocator)
    for d in records {
        if len(d.tainted_scopes)>0 {continue}
        clear(&missing)
        objects,e:=ddc_output_lacking(s,d.output_root,&missing)
        if e!=.None {continue}
        if len(missing)>0 {
            append(lacking,..missing[:])
            state=.Fetching
            continue
        }
        if len(objects)!=1 {continue}
        o,oe:=store.object_open(s,objects[0])
        if oe!=.None {continue}
        size:=store.object_size(&o)
        if size==0 || size>u64(preview_max(kind)) {
            store.object_close(&o)
            continue
        }
        made,me:=make([]u8,int(size),allocator)
        if me!=nil {
            store.object_close(&o)
            return nil,state
        }
        re:=store.object_read(&o,0,made)
        store.object_close(&o)
        if re!=.None || preview_check(kind,made)!=.None {
            delete(made,allocator)
            continue
        }
        return made,.Found
    }
    return nil,state
}

// Publishes a preview this device made from files it read, signed, as the
// derived data of the org under key, and tells the mesh. What preview_check
// refuses is not published.
machine_publish_preview :: proc(m:^Machine,org:Log_Id,kind:Preview_Kind,key:store.Hash,bytes:[]u8) -> Error {
    if e:=preview_check(kind,bytes);e!=.None {return machine_fail(m,e,"the preview is not one a node serves: see kai/preview.odin")}
    address,pe:=store.put(&m.store,bytes)
    if pe!=.None {return machine_fail(m,store_error(pe),"the preview does not go into the store")}
    _,e:=machine_publish_ddc(m,org,key,{address},nil)
    return e
}

// Whether this device's store already holds a record of its own under key
// for org: what it published before is not published again.
preview_published :: proc(m:^Machine,org:Log_Id,key:store.Hash) -> bool {
    records:=make([dynamic]DDC_Record,context.temp_allocator)
    if ddc_lookup(&m.store,org,key,&records)!=.None {return false}
    for d in records {
        if d.producer==m.identity.key {return true}
    }
    return false
}

// A size in bytes as a person reads it, in the temporary allocator.
bytes_text :: proc(bytes:i64) -> string {
    value:=f64(bytes)
    switch {
    case value>=1<<30: return fmt.tprintf("%.2f GiB",value/(1<<30))
    case value>=1<<20: return fmt.tprintf("%.1f MiB",value/(1<<20))
    case value>=1<<10: return fmt.tprintf("%.1f KiB",value/(1<<10))
    }
    return fmt.tprintf("%d bytes",bytes)
}
