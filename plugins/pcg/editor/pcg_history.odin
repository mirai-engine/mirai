package pcg_editor

import "base:runtime"
import "core:mem"
import "mirai:editor"
import "mirai:host"
import "mirai:std/base"
import pcg "plugins:pcg/runtime"

// The history of the .pcg sources the editor edits (editor/revision_history.odin):
// a step between two revisions keeps what the source held at the one the
// head is not at, where the two differ: its info, its layers when one of
// them changed, and whole painted cells. A stroke of the brush costs the
// cells it painted, not the source.

Revisions :: editor.Revision_History(Step,pcg.Pcg_Source,pcg.Pcg_File_Stamp)
Applied :: editor.Revision_Head(pcg.Pcg_Source,pcg.Pcg_File_Stamp)

REVISIONS :: editor.Revision_Source(Step,pcg.Pcg_Source,pcg.Pcg_File_Stamp){
    name="pcg",stamp=pcg.data_stamp,write=pcg_write,read=head_read,
    apply=step_apply,step_destroy=step_destroy,source_destroy=pcg.source_destroy,rebase=steps_rebase,
}

@(private)
head_read :: proc(fresh:^pcg.Pcg_Source,a:^host.Assets,id:base.Asset_Id,head:^pcg.Pcg_Source) -> bool {
    return pcg.data_read(fresh,a,id,a.allocator).kind==.None
}

// A painted cell of the other revision; present false: it has no such cell.
Cell_Swap :: struct {coord:[2]i32,present:bool,cell:pcg.Pcg_Cell}

Step :: struct {
    source:base.Asset_Id,
    from,to:u32,
    info:pcg.Pcg_Info,
    layers_kept:bool,             // layers holds those of the other revision
    layers:[dynamic]pcg.Pcg_Layer, // their texts from the allocator of the source
    cells:[dynamic]Cell_Swap,      // in the order of their coordinates
    allocator:runtime.Allocator,   // of the head, which the layers trade with
}

@(private)
cell_free :: proc(c:^pcg.Pcg_Cell) {delete(c.density);delete(c.ecotopes);delete(c.points);c^={}}

@(private)
layers_free :: proc(layers:^[dynamic]pcg.Pcg_Layer,allocator:=context.allocator) {
    for &l in layers {
        delete(l.field_expr,allocator);delete(l.grammar_expr,allocator);delete(l.grammar_symbols,allocator)
    }
    delete(layers^)
    layers^=nil
}

step_destroy :: proc(step:^Step) {
    for &entry in step.cells {if entry.present {cell_free(&entry.cell)}}
    delete(step.cells)
    layers_free(&step.layers,step.allocator)
    step^={}
}

@(private)
cell_clone :: proc(c:^pcg.Pcg_Cell) -> (copied:pcg.Pcg_Cell,ok:bool) {
    copied.coord=c.coord
    error:mem.Allocator_Error
    if copied.density,error=make([dynamic]u8,len(c.density));error!=nil {return {},false}
    if copied.ecotopes,error=make([dynamic]u8,len(c.ecotopes));error!=nil {delete(copied.density);return {},false}
    if copied.points,error=make([dynamic]pcg.Pcg_Point,len(c.points));error!=nil {delete(copied.density);delete(copied.ecotopes);return {},false}
    copy(copied.density[:],c.density[:])
    copy(copied.ecotopes[:],c.ecotopes[:])
    copy(copied.points[:],c.points[:])
    return copied,true
}

@(private)
cell_same :: proc(a,b:^pcg.Pcg_Cell) -> bool {
    return mem.compare(a.density[:],b.density[:])==0 && mem.compare(a.ecotopes[:],b.ecotopes[:])==0 &&
        mem.compare(mem.slice_to_bytes(a.points[:]),mem.slice_to_bytes(b.points[:]))==0
}

layer_same :: proc(a,b:^pcg.Pcg_Layer) -> bool {
    return a.params==b.params && a.field_expr==b.field_expr && a.grammar_expr==b.grammar_expr &&
        len(a.grammar_symbols)==len(b.grammar_symbols) && mem.compare(mem.slice_to_bytes(a.grammar_symbols),mem.slice_to_bytes(b.grammar_symbols))==0
}

@(private)
layers_same :: proc(a,b:[]pcg.Pcg_Layer) -> bool {
    if len(a)!=len(b) {return false}
    for &l,i in a {if !layer_same(&l,&b[i]) {return false}}
    return true
}

// A copy of layers, their texts and symbols from the allocator. False without memory.
@(private)
layers_clone :: proc(src:[]pcg.Pcg_Layer,allocator:=context.allocator) -> (copied:[dynamic]pcg.Pcg_Layer,ok:bool) {
    error:mem.Allocator_Error
    if copied,error=make([dynamic]pcg.Pcg_Layer,0,len(src),allocator);error!=nil {return}
    for &l in src {
        held:pcg.Pcg_Layer
        held.params=l.params
        e0,e1,e2:mem.Allocator_Error
        if len(l.field_expr)>0 {
            bytes:[]u8
            if bytes,e0=make([]u8,len(l.field_expr),allocator);e0==nil {copy(bytes,l.field_expr);held.field_expr=string(bytes)}
        }
        if len(l.grammar_expr)>0 {
            bytes:[]u8
            if bytes,e1=make([]u8,len(l.grammar_expr),allocator);e1==nil {copy(bytes,l.grammar_expr);held.grammar_expr=string(bytes)}
        }
        if len(l.grammar_symbols)>0 {
            if held.grammar_symbols,e2=make([]pcg.Grammar_Symbol_Def,len(l.grammar_symbols),allocator);e2==nil {copy(held.grammar_symbols,l.grammar_symbols)}
        }
        append(&copied,held)
        if e0!=nil || e1!=nil || e2!=nil {layers_free(&copied,allocator);return nil,false}
    }
    return copied,true
}

// The step from the head to edit: the head takes the cells and the layers
// edit has where they differ, and the step what the head had. False, the
// head as it was, without memory.
step_make :: proc(step:^Step,head,edit:^pcg.Pcg_Source) -> bool {
    // What edit has that the head takes, copied first: what fails leaves the head as it was.
    taken:=make([dynamic]Cell_Swap,context.temp_allocator)
    fail :: proc(taken:[]Cell_Swap) -> bool {
        for &entry in taken {if entry.present {cell_free(&entry.cell)}}
        return false
    }
    i,j:=0,0
    for i<len(head.cells) || j<len(edit.cells) {
        switch {
        case j>=len(edit.cells) || i<len(head.cells) && coord_before(head.cells[i].coord,edit.cells[j].coord):
            append(&taken,Cell_Swap{coord=head.cells[i].coord})
            i+=1
        case i>=len(head.cells) || coord_before(edit.cells[j].coord,head.cells[i].coord):
            copied,ok:=cell_clone(&edit.cells[j])
            if !ok {return fail(taken[:])}
            append(&taken,Cell_Swap{coord=copied.coord,present=true,cell=copied})
            j+=1
        case:
            if !cell_same(&head.cells[i],&edit.cells[j]) {
                copied,ok:=cell_clone(&edit.cells[j])
                if !ok {return fail(taken[:])}
                append(&taken,Cell_Swap{coord=copied.coord,present=true,cell=copied})
            }
            i+=1;j+=1
        }
    }
    step.allocator=head.allocator
    layers:[dynamic]pcg.Pcg_Layer
    kept:=!layers_same(head.layers[:],edit.layers[:])
    if kept {
        ok:bool
        if layers,ok=layers_clone(edit.layers[:],head.allocator);!ok {return fail(taken[:])}
    }
    if reserve(&step.cells,len(taken))!=nil {layers_free(&layers,head.allocator);return fail(taken[:])}
    for &entry in taken {
        append(&step.cells,entry)
        swap_cell(&step.cells[len(step.cells)-1],head)
    }
    if kept {
        pcg.source_compiled_free(head)
        step.layers_kept=true
        step.layers=head.layers
        head.layers=layers
    }
    step.info,head.info=head.info,edit.info
    return true
}

@(private)
coord_before :: proc "contextless" (a,b:[2]i32) -> bool {return a.y<b.y || a.y==b.y && a.x<b.x}

// Trades a cell of a step with the one of its coordinate in the head.
@(private)
swap_cell :: proc(entry:^Cell_Swap,head:^pcg.Pcg_Source) {
    at:=pcg.coord_lower(head.cells[:],entry.coord)
    found:=at<len(head.cells) && head.cells[at].coord==entry.coord
    switch {
    case found && entry.present:
        previous:=entry.cell
        entry.cell=head.cells[at]
        head.cells[at]=previous
    case found:
        entry.cell=head.cells[at]
        entry.present=true
        ordered_remove(&head.cells,at)
    case entry.present:
        inject_at(&head.cells,at,entry.cell)
        entry.cell={}
        entry.present=false
    }
}

// Trades a step with the head: the head goes to the other revision of the
// step, and the step keeps the one the head was at. The programs of the head
// are made again when it is written.
step_apply :: proc(step:^Step,head:^pcg.Pcg_Source) {
    for &entry in step.cells {swap_cell(&entry,head)}
    if step.layers_kept {
        pcg.source_compiled_free(head)
        held:=head.layers
        head.layers=step.layers
        step.layers=held
    }
    step.info,head.info=head.info,step.info
}

// The file of a source changed outside the editor while its graphs stayed at
// the revision of its head. The step that leads to it keeps the revision
// before for what fresh changed; those that go past it keep theirs.
@(private)
steps_rebase :: proc(steps:^[dynamic]Step,id:base.Asset_Id,revision:u32,head,fresh:^pcg.Pcg_Source) {
    for &step in steps {
        if step.source!=id || step.to!=revision {continue}
        i,j:=0,0
        for i<len(head.cells) || j<len(fresh.cells) {
            coord:[2]i32
            differs:=false
            held:^pcg.Pcg_Cell
            switch {
            case j>=len(fresh.cells) || i<len(head.cells) && coord_before(head.cells[i].coord,fresh.cells[j].coord):
                coord,differs,held=head.cells[i].coord,true,&head.cells[i];i+=1
            case i>=len(head.cells) || coord_before(fresh.cells[j].coord,head.cells[i].coord):
                coord,differs=fresh.cells[j].coord,true;j+=1
            case:
                coord,differs,held=head.cells[i].coord,!cell_same(&head.cells[i],&fresh.cells[j]),&head.cells[i];i+=1;j+=1
            }
            if !differs {continue}
            at:=0
            for at<len(step.cells) && coord_before(step.cells[at].coord,coord) {at+=1}
            if at<len(step.cells) && step.cells[at].coord==coord {continue}
            entry:=Cell_Swap{coord=coord}
            if held!=nil {
                copied,ok:=cell_clone(held)
                if !ok {continue}
                entry.present,entry.cell=true,copied
            }
            inject_at(&step.cells,at,entry)
        }
        if !step.layers_kept && !layers_same(head.layers[:],fresh.layers[:]) {
            if kept,ok:=layers_clone(head.layers[:],head.allocator);ok {
                step.layers_kept,step.allocator=true,head.allocator
                step.layers=kept
            }
        }
    }
}
