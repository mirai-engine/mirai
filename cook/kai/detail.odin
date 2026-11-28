package kai_assets

import "base:runtime"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"
import "mirai:asset"
import lines_diff "mirai:std/diff"
import "mirai:std/serial"
import "mirai:store"
import vcs "mirai:kai"

// What a change did to one file, as the editor and kai.log show it: a text file as its lines with their numbers, the runs it did not
// touch folded; an asset as the rows and fields the structural driver tells
// apart; a binary or oversized file as its sizes. Bounded: past DETAIL_ROWS
// rows the rest is only counted, and a line keeps DETAIL_LINE bytes.

DETAIL_ROWS :: 1000    // rows a detail keeps
DETAIL_BYTES :: 1<<22  // bytes of a side past which a file is oversized
DETAIL_LINE :: 512     // bytes of a row's text
DETAIL_CONTEXT :: 3    // lines kept around what changed

Detail_Kind :: enum u8 {Text,Asset,Binary,Oversized}

Detail_Row_Kind :: enum u8 {
    Fold,    // kept lines folded: skipped says how many
    Kept,
    Added,
    Removed,
    Changed, // a field of an asset
}

// The mark of each kind of row, as kai.log and the detail show it.
DETAIL_MARKS :: [Detail_Row_Kind]string{.Fold="",.Kept=" ",.Added="+",.Removed="-",.Changed="~"}

Detail_Row :: struct {
    kind:Detail_Row_Kind,
    old,new:i32, // of a text: its line on each side, from 1; 0 where it is not
    skipped:i32, // of a fold: the lines it stands for
    text:string, // the line, or the path in the asset and its values
    key:u64,     // of an asset: the entity or row it is on; 0 none
    name:string, // the entity of key
}

File_Detail :: struct {
    path:string,
    mark:u8,                 // A added, D removed, M changed, C in conflict
    kind:Detail_Kind,
    before,after:u64,        // bytes of each side
    added,removed,changed:int, // lines; of an asset, its rows and fields
    rows:[]Detail_Row,
    cut:int,                 // rows past DETAIL_ROWS, not kept
    missing:[2]store.Hash,   // when it returns Missing: the side before and after whose bytes a peer has
}

// What the change at revision did to the file at path, in allocator:
// Invalid_Argument when the change did not change it; Missing, with
// out.missing, while the bytes of a side are not in the store.
file_detail :: proc(w:^vcs.Workspace,revision:vcs.Revision,path:string,out:^File_Detail,allocator:=context.temp_allocator) -> vcs.Error {
    diffs:=make([dynamic]vcs.Diff,context.temp_allocator)
    diff(w,revision,&diffs) or_return
    found:=-1
    for d,k in diffs {
        if d.path==path {found=k;break}
    }
    if found<0 {return .Invalid_Argument}
    d:=diffs[found]
    out^={path=strings.clone(path,allocator),before=d.before.size,after=d.after.size,mark=vcs.diff_mark(d)}
    if d.before.size>DETAIL_BYTES || d.after.size>DETAIL_BYTES {
        out.kind=.Oversized
        return .None
    }
    sides:[2][]u8
    missing:=false
    for f,k in ([2]vcs.File{d.before,d.after}) {
        if f.address=={} {continue}
        e:vcs.Error
        if sides[k],e=vcs.file_bytes(w.repo.s,f.address,context.temp_allocator);e==.Missing {
            out.missing[k],missing=f.address,true
        } else if e!=.None {
            return e
        }
    }
    if missing {return .Missing}
    if detail_asset(sides,out,allocator) {return .None}
    for side in sides {
        if !utf8.valid_string(string(side)) || strings.index_byte(string(side),0)>=0 {
            out.kind=.Binary
            return .None
        }
    }
    old,new:=string(sides[0]),string(sides[1])
    lines:=make([dynamic]lines_diff.Line,context.temp_allocator)
    stats,e:=lines_diff.lines(old,new,&lines,context.temp_allocator)
    if e!=.None {return e==.Too_Large?.Too_Large:.Out_Of_Memory}
    rows:=make([dynamic]lines_diff.Row,context.temp_allocator)
    if lines_diff.rows(lines[:],DETAIL_CONTEXT,&rows)!=.None {return .Out_Of_Memory}
    out.added,out.removed=stats.added,stats.removed
    kept:=min(len(rows),DETAIL_ROWS)
    out.rows=make([]Detail_Row,kept,allocator)
    out.cut=len(rows)-kept
    for row,i in rows[:kept] {
        if row.line<0 {
            out.rows[i]={skipped=row.skipped}
            continue
        }
        l:=lines[row.line]
        kinds:=[lines_diff.Op]Detail_Row_Kind{.Same=.Kept,.Add=.Added,.Remove=.Removed}
        text:=l.op==.Remove?old:new
        out.rows[i]={kind=kinds[l.op],old=l.old,new=l.new,text=detail_line(text[l.start:l.end],allocator)}
    }
    return .None
}

// The asset both present sides are: its rows and fields, as asset.document_diff
// says them. false when a side is not an asset.
@(private)
detail_asset :: proc(sides:[2][]u8,out:^File_Detail,allocator:runtime.Allocator) -> bool {
    docs:[2]asset.Document
    present:[2]bool
    for side,k in sides {
        if side==nil {continue}
        if asset.document_read(&docs[k],side,context.temp_allocator)!=.None {return false}
        present[k]=true
    }
    if !present[0] && !present[1] {return false}
    // A side that is not there is an asset of the same kind with no tables.
    for k in 0..<2 {
        if present[k] {continue}
        other:=&docs[1-k]
        docs[k]={kind=other.kind,kind_version=other.kind_version,id=other.id,owner=other.owner,flags=other.flags,allocator=context.temp_allocator}
    }
    if present[0] && present[1] && docs[0].kind!=docs[1].kind {return false}
    w:serial.Writer
    serial.writer_init(&w,allocator=context.temp_allocator)
    if _,e:=asset.document_diff(&docs[0],&docs[1],&w);e!=.None {return false}
    out.kind=.Asset
    text:=string(serial.writer_bytes(&w))
    count:=strings.count(text,"\n")
    kept:=min(count,DETAIL_ROWS)
    out.rows=make([]Detail_Row,kept,allocator)
    out.cut=count-kept
    named:=&docs[present[1]?1:0]
    i:=0
    for line in strings.split_lines_iterator(&text) {
        if len(line)<3 {continue}
        kind:Detail_Row_Kind
        switch line[0] {
        case '+':
            kind=.Added
            out.added+=1
        case '-':
            kind=.Removed
            out.removed+=1
        case:
            kind=.Changed
            out.changed+=1
        }
        if i>=kept {continue}
        row:=Detail_Row{kind=kind,text=detail_line(line[2:],allocator)}
        if at:=strings.index(line,"[@0x");at>=0 && at+20<=len(line) {
            if key,ok:=strconv.parse_u64_of_base(line[at+4:at+20],16);ok {
                row.key=key
                row.name=entity_name(named,&docs[present[0]?0:1],key,allocator)
            }
        }
        out.rows[i]=row
        i+=1
    }
    out.rows=out.rows[:i]
    return true
}

// A line cut to DETAIL_LINE bytes between characters, in allocator.
@(private)
detail_line :: proc(text:string,allocator:runtime.Allocator) -> string {
    cut:=min(len(text),DETAIL_LINE)
    for cut>0 && cut<len(text) && text[cut]&0xC0==0x80 {cut-=1}
    return strings.clone(text[:cut],allocator)
}
