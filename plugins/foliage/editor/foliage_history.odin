package foliage_editor

import "core:mem"
import "mirai:editor"
import "mirai:host"
import foliage "plugins:foliage/runtime"
import "mirai:std/base"

// The history of the foliage the tool edits (editor/revision_history.odin):
// a step between two revisions keeps what the source held at the one the
// head is not at, where the two differ: whole cells, the types and the info.
// A stroke costs the cells it changed, not the instances of its foliage.

Revisions :: editor.Revision_History(Step,foliage.Source,foliage.File_Stamp)
Applied :: editor.Revision_Head(foliage.Source,foliage.File_Stamp)

REVISIONS :: editor.Revision_Source(Step,foliage.Source,foliage.File_Stamp){
    name="foliage",stamp=foliage.foliage_stamp,write=foliage_write,read=head_read,
    apply=step_apply,step_destroy=step_destroy,source_destroy=foliage.source_destroy,rebase=steps_rebase,
}

@(private)
head_read :: proc(fresh:^foliage.Source,a:^host.Assets,id:base.Asset_Id,head:^foliage.Source) -> bool {
    return foliage.foliage_read(fresh,a,id,a.allocator)
}

// A cell of the other revision; present false: it has no such cell.
Cell_Swap :: struct {coord:[2]i32,present:bool,cell:foliage.Cell}

Step :: struct {
    source:base.Asset_Id,
    from,to:u32,
    info:foliage.Foliage_Info,
    types_kept:bool, // types holds those of the other revision
    types:[dynamic]foliage.Foliage_Type,
    cells:[dynamic]Cell_Swap, // in the order of their coordinates
}

@(private)
cell_free :: proc(c:^foliage.Cell) {delete(c.manual);delete(c.overrides);delete(c.density);c^={}}

step_destroy :: proc(step:^Step) {
    for &entry in step.cells {if entry.present {cell_free(&entry.cell)}}
    delete(step.cells)
    delete(step.types)
    step^={}
}

@(private)
cell_clone :: proc(c:^foliage.Cell) -> (copied:foliage.Cell,ok:bool) {
    copied={coord=c.coord,generate=c.generate,version=c.version}
    error:mem.Allocator_Error
    if copied.manual,error=make([dynamic]foliage.Foliage_Instance,len(c.manual));error!=nil {return {},false}
    if copied.overrides,error=make([dynamic]foliage.Foliage_Override,len(c.overrides));error!=nil {delete(copied.manual);return {},false}
    if copied.density,error=make([dynamic]u8,len(c.density));error!=nil {delete(copied.manual);delete(copied.overrides);return {},false}
    copy(copied.density[:],c.density[:])
    copy(copied.manual[:],c.manual[:])
    copy(copied.overrides[:],c.overrides[:])
    return copied,true
}

@(private)
cell_same :: proc(a,b:^foliage.Cell) -> bool {
    if a.generate!=b.generate || len(a.manual)!=len(b.manual) || len(a.overrides)!=len(b.overrides) || mem.compare(a.density[:],b.density[:])!=0 {return false}
    return mem.compare(mem.slice_to_bytes(a.manual[:]),mem.slice_to_bytes(b.manual[:]))==0 && mem.compare(mem.slice_to_bytes(a.overrides[:]),mem.slice_to_bytes(b.overrides[:]))==0
}

@(private)
types_same :: proc(a,b:[]foliage.Foliage_Type) -> bool {
    return len(a)==len(b) && mem.compare(mem.slice_to_bytes(a),mem.slice_to_bytes(b))==0
}

// The index of the first cell at or after a coordinate.
@(private)
cell_lower :: proc(cells:[]foliage.Cell,coord:[2]i32) -> int {
    low,high:=0,len(cells)
    for low<high {
        mid:=(low+high)/2
        if cell_before(cells[mid].coord,coord) {low=mid+1} else {high=mid}
    }
    return low
}

// The step from the head to edit: the head takes the cells and the types
// edit has where they differ, and the step what the head had. False, the
// head as it was, without memory.
step_make :: proc(step:^Step,head,edit:^foliage.Source) -> bool {
    // What edit has that the head takes, copied first: what fails leaves the head as it was.
    taken:=make([dynamic]Cell_Swap,context.temp_allocator)
    fail :: proc(taken:[]Cell_Swap) -> bool {
        for &entry in taken {if entry.present {cell_free(&entry.cell)}}
        return false
    }
    i,j:=0,0
    for i<len(head.cells) || j<len(edit.cells) {
        switch {
        case j>=len(edit.cells) || i<len(head.cells) && cell_before(head.cells[i].coord,edit.cells[j].coord):
            append(&taken,Cell_Swap{coord=head.cells[i].coord})
            i+=1
        case i>=len(head.cells) || cell_before(edit.cells[j].coord,head.cells[i].coord):
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
    types:[dynamic]foliage.Foliage_Type
    kept:=!types_same(head.types[:],edit.types[:])
    if kept {
        error:mem.Allocator_Error
        if types,error=make([dynamic]foliage.Foliage_Type,len(edit.types));error!=nil {return fail(taken[:])}
        copy(types[:],edit.types[:])
    }
    if reserve(&step.cells,len(taken))!=nil {delete(types);return fail(taken[:])}
    for &entry in taken {
        append(&step.cells,entry)
        swap_cell(&step.cells[len(step.cells)-1],head)
    }
    if kept {step.types_kept,step.types,head.types=true,head.types,types}
    step.info,head.info=head.info,edit.info
    return true
}

// Trades a cell of a step with the one of its coordinate in the head.
@(private)
swap_cell :: proc(entry:^Cell_Swap,head:^foliage.Source) {
    at:=cell_lower(head.cells[:],entry.coord)
    found:=at<len(head.cells) && head.cells[at].coord==entry.coord
    switch {
    case found && entry.present: entry.cell,head.cells[at]=head.cells[at],entry.cell
    case found:                  entry.cell,entry.present=head.cells[at],true;ordered_remove(&head.cells,at)
    case entry.present:          inject_at(&head.cells,at,entry.cell);entry.cell,entry.present={},false
    }
}

// Trades a step with the head: the head goes to the other revision of the
// step, and the step keeps the one the head was at.
step_apply :: proc(step:^Step,head:^foliage.Source) {
    for &entry in step.cells {swap_cell(&entry,head)}
    if step.types_kept {head.types,step.types=step.types,head.types}
    step.info,head.info=head.info,step.info
}

// The file of a source changed outside the tool while its Foliage stayed at
// the revision of its head. The step that leads to it keeps the revision
// before for what fresh changed; those that go past it keep theirs.
@(private)
steps_rebase :: proc(steps:^[dynamic]Step,id:base.Asset_Id,revision:u32,head,fresh:^foliage.Source) {
    for &step in steps {
        if step.source!=id || step.to!=revision {continue}
        i,j:=0,0
        for i<len(head.cells) || j<len(fresh.cells) {
            coord:[2]i32
            differs:=false
            held:^foliage.Cell
            switch {
            case j>=len(fresh.cells) || i<len(head.cells) && cell_before(head.cells[i].coord,fresh.cells[j].coord):
                coord,differs,held=head.cells[i].coord,true,&head.cells[i];i+=1
            case i>=len(head.cells) || cell_before(fresh.cells[j].coord,head.cells[i].coord):
                coord,differs=fresh.cells[j].coord,true;j+=1
            case:
                coord,differs,held=head.cells[i].coord,!cell_same(&head.cells[i],&fresh.cells[j]),&head.cells[i];i+=1;j+=1
            }
            if !differs {continue}
            at:=0
            for at<len(step.cells) && cell_before(step.cells[at].coord,coord) {at+=1}
            if at<len(step.cells) && step.cells[at].coord==coord {continue}
            entry:=Cell_Swap{coord=coord}
            if held!=nil {
                copied,ok:=cell_clone(held)
                if !ok {continue}
                entry.present,entry.cell=true,copied
            }
            inject_at(&step.cells,at,entry)
        }
        if !step.types_kept && !types_same(head.types[:],fresh.types[:]) {
            kept,error:=make([dynamic]foliage.Foliage_Type,len(head.types))
            if error==nil {copy(kept[:],head.types[:]);step.types_kept,step.types=true,kept}
        }
    }
}
