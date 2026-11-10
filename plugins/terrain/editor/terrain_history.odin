package terrain_editor

import "base:runtime"
import "mirai:editor"
import "mirai:host"
import terrain "plugins:terrain/runtime"
import "mirai:std/base"

// The history of the sources the tool edits (editor/revision_history.odin).
// A step between two revisions keeps what the source held at the one the
// head is not at, only where the two differ: the pages of the grids of a
// Heightfield, the blocks of a Volume and its info, or the
// whole source when its kind or size changed. A stroke costs
// what it changed, not the size of its terrain.

Revisions :: editor.Revision_History(Step,terrain.Source,terrain.File_Stamp)
Applied :: editor.Revision_Head(terrain.Source,terrain.File_Stamp)

REVISIONS :: editor.Revision_Source(Step,terrain.Source,terrain.File_Stamp){
    name="terrain",stamp=terrain.terrain_stamp,write=head_write,read=head_read,
    apply=step_apply,step_destroy=step_destroy,source_destroy=terrain.source_destroy,rebase=steps_rebase,
}

// A head keeps the blocks of its pages: what a stroke did not change is not
// compressed again.
@(private)
head_write :: proc(s:^editor.Session,a:^host.Assets,id:base.Asset_Id,head:^terrain.Source) -> bool {return terrain_write(s,a,id,head,keep=true)}

@(private)
head_read :: proc(fresh:^terrain.Source,a:^host.Assets,id:base.Asset_Id,head:^terrain.Source) -> bool {
    return terrain.terrain_read(fresh,a,id,head.allocator,editable=false)
}

Page_Swap :: struct($T:typeid) {index:int,page:terrain.Page(T)}
// The pages of a grid a step changed, or the whole grid when it came, went
// or changed size.
Grid_Swap :: struct($T:typeid) {whole:bool,grid:terrain.Grid(T),pages:[dynamic]Page_Swap(T)}

Step :: struct {
    allocator:runtime.Allocator, // of what it keeps: the one of its head
    source:base.Asset_Id,
    from,to:u32,
    whole:bool,           // other is the whole source
    other:terrain.Source,
    info:terrain.Source_Info,
    heights:Grid_Swap(f32),
    holes:Grid_Swap(u8),
    weights:Grid_Swap(terrain.Weights),
    distances:Grid_Swap(f32),
}

@(private)
grid_swap_destroy :: proc(g:^Grid_Swap($T),allocator:runtime.Allocator) {
    terrain.grid_destroy(&g.grid,allocator)
    for entry in g.pages {terrain.page_free(entry.page)}
    delete(g.pages)
    g^={}
}

step_destroy :: proc(step:^Step) {
    allocator:=step.allocator
    terrain.source_destroy(&step.other)
    grid_swap_destroy(&step.heights,allocator)
    grid_swap_destroy(&step.holes,allocator)
    grid_swap_destroy(&step.weights,allocator)
    grid_swap_destroy(&step.distances,allocator)
    step^={}
}

// Whether two sources keep the same grids: a step between them keeps their
// parts, otherwise the whole source.
@(private)
step_shaped :: proc "contextless" (a,b:^terrain.Source) -> bool {
    return a.kind==b.kind && a.samples==b.samples && a.cell==b.cell && a.chunk_cells==b.chunk_cells
}

// A region of samples over x and z as one of a grid: every sample along y.
@(private)
region :: proc "contextless" (low,high:[2]int) -> (from,to:[3]int) {return {low.x,0,low.y},{high.x,max(int),high.y}}

// The index of a page of a grid from its coordinates among the pages.
@(private)
page_index :: proc "contextless" (g:^terrain.Grid($T),p:[3]int) -> int {return p.x+g.counts.x*(p.y+g.counts.y*p.z)}

// The pages of a grid of the head that differ from those of edited within a
// region of values (all: everywhere), into g, and edited's in the head.
@(private)
grid_step :: proc(g:^Grid_Swap($T),head,edited:^terrain.Grid(T),low,high:[3]int,all:bool,allocator:runtime.Allocator) -> bool {
    if head.size!=edited.size || len(head.pages)!=len(edited.pages) {
        copied:terrain.Grid(T)
        if !terrain.grid_clone(&copied,edited,allocator) {return false}
        g.whole,g.grid=true,head^
        head^=copied
        return true
    }
    from,to:=[3]int{},head.counts-1
    if !all {
        ok:bool
        if from,to,ok=terrain.grid_page_range(head,low,high);!ok {return true}
    }
    // The pages first: what fails leaves the head as it was.
    first:=len(g.pages)
    for pz in from.z..=to.z {for py in from.y..=to.y {for px in from.x..=to.x {
        i:=page_index(head,{px,py,pz})
        if terrain.grid_page_same(head,edited,i) {continue}
        if append(&g.pages,Page_Swap(T){i,terrain.page_share(edited.pages[i])})!=1 {
            terrain.page_free(edited.pages[i])
            for entry in g.pages[first:] {terrain.page_free(entry.page)}
            resize(&g.pages,first)
            return false
        }
    }}}
    for &entry in g.pages[first:] {head.pages[entry.index],entry.page=entry.page,head.pages[entry.index]}
    return true
}

// The step from the head to edited over a region of samples over x and z
// (all: everywhere): the head takes what edited holds there and the step what
// the head held. False, the head as it was, without memory.
step_make :: proc(step:^Step,head,edited:^terrain.Source,low,high:[2]int,all:bool) -> bool {
    allocator:=head.allocator
    step.allocator=allocator
    if !step_shaped(head,edited) {
        copied:terrain.Source
        if !terrain.source_clone(&copied,edited,allocator,editable=false) {return false}
        step.whole,step.other=true,head^
        head^=copied
        return true
    }
    from,to:=region(low,high)
    if !grid_step(&step.heights,&head.heights,&edited.heights,from,to,all,allocator) {step_revert(step,head);return false}
    if !grid_step(&step.holes,&head.holes,&edited.holes,from-{1,0,1},to,all,allocator) {step_revert(step,head);return false}
    if !grid_step(&step.weights,&head.weights,&edited.weights,from,to,all,allocator) {step_revert(step,head);return false}
    if !grid_step(&step.distances,&head.distances,&edited.distances,from,to,all,allocator) {step_revert(step,head);return false}
    step.info,head.info=head.info,edited.info
    return true
}

// Puts back in the head what a step being made took, and lets it go.
@(private)
step_revert :: proc(step:^Step,head:^terrain.Source) {
    step_apply(step,head)
    step_destroy(step)
}

@(private)
grid_apply :: proc(g:^Grid_Swap($T),head:^terrain.Grid(T)) {
    if g.whole {head^,g.grid=g.grid,head^;return}
    for &entry in g.pages {head.pages[entry.index],entry.page=entry.page,head.pages[entry.index]}
}

// Trades a step with the head: the head goes to the other revision of the
// step, and the step keeps the one the head was at.
step_apply :: proc(step:^Step,head:^terrain.Source) {
    if step.whole {head^,step.other=step.other,head^;return}
    grid_apply(&step.heights,&head.heights)
    grid_apply(&step.holes,&head.holes)
    grid_apply(&step.weights,&head.weights)
    grid_apply(&step.distances,&head.distances)
    step.info,head.info=head.info,step.info
}

@(private)
grid_follow :: proc(g:^Grid_Swap($T),edit,head:^terrain.Grid(T),allocator:runtime.Allocator) -> bool {
    if g.whole || len(edit.pages)!=len(head.pages) {return terrain.grid_clone(edit,head,allocator)}
    for entry in g.pages {
        terrain.page_free(edit.pages[entry.index])
        edit.pages[entry.index]=terrain.page_share(head.pages[entry.index])
    }
    return true
}

// Copies into the source the tool edits what a step changed in the head it
// was applied to: both read the same afterwards. False without memory.
step_follow :: proc(step:^Step,edit,head:^terrain.Source) -> bool {
    if step.whole || !step_shaped(edit,head) {return terrain.source_clone(edit,head,edit.allocator)}
    allocator:=edit.allocator
    if !grid_follow(&step.heights,&edit.heights,&head.heights,allocator) || !grid_follow(&step.holes,&edit.holes,&head.holes,allocator) || !grid_follow(&step.weights,&edit.weights,&head.weights,allocator) || !grid_follow(&step.distances,&edit.distances,&head.distances,allocator) {return false}
    edit.info=head.info
    return true
}

// Copies the head into the source the tool edits within a region of samples
// over x and z: what a stroke changed there goes back.
source_take_back :: proc(edit,head:^terrain.Source,low,high:[2]int) -> bool {
    if !step_shaped(edit,head) {return terrain.source_clone(edit,head,edit.allocator)}
    back :: proc(edit,head:^terrain.Grid($T),low,high:[3]int,allocator:runtime.Allocator) -> bool {
        if edit.size!=head.size || len(edit.pages)!=len(head.pages) {return terrain.grid_clone(edit,head,allocator)}
        from,to,ok:=terrain.grid_page_range(head,low,high)
        if !ok {return true}
        for pz in from.z..=to.z {for py in from.y..=to.y {for px in from.x..=to.x {
            i:=page_index(head,{px,py,pz})
            if terrain.grid_page_same(edit,head,i) {continue}
            terrain.page_free(edit.pages[i])
            edit.pages[i]=terrain.page_share(head.pages[i])
        }}}
        return true
    }
    allocator:=edit.allocator
    from,to:=region(low,high)
    if !back(&edit.heights,&head.heights,from,to,allocator) || !back(&edit.holes,&head.holes,from-{1,0,1},to,allocator) || !back(&edit.weights,&head.weights,from,to,allocator) || !back(&edit.distances,&head.distances,from,to,allocator) {return false}
    edit.info=head.info
    return true
}

// The file of a source changed outside the tool while its owners stayed at
// the revision of its head. The step that leads to it keeps the revision
// before for what fresh changed; those that go past it keep theirs, so redo
// does not bring back what the file let go of.
@(private)
steps_rebase :: proc(steps:^[dynamic]Step,id:base.Asset_Id,revision:u32,head,fresh:^terrain.Source) {
    allocator:=head.allocator
    for i:=len(steps)-1;i>=0;i-=1 {
        step:=&steps[i]
        if step.source!=id {continue}
        if step.from>=revision && !step_shaped(head,fresh) {step_destroy(step);ordered_remove(steps,i);continue}
        if step.to!=revision || step.whole {continue}
        if !step_shaped(head,fresh) {
            // What the revision before held, whole: the head with the step put back.
            before:terrain.Source
            if !terrain.source_clone(&before,head,allocator,editable=false) {step_destroy(step);ordered_remove(steps,i);continue}
            step_apply(step,&before)
            from:=step.from
            step_destroy(step)
            // One store per value until odin-lang/Odin#7937 (see ODIN_WORKAROUNDS).
            step.other=before
            step.allocator,step.source,step.from,step.to,step.whole=allocator,id,from,revision,true
            continue
        }
        if !rebase_grid(&step.heights,&head.heights,&fresh.heights,allocator) || !rebase_grid(&step.holes,&head.holes,&fresh.holes,allocator) || !rebase_grid(&step.weights,&head.weights,&fresh.weights,allocator) || !rebase_grid(&step.distances,&head.distances,&fresh.distances,allocator) {
            step_destroy(step);ordered_remove(steps,i);continue
        }
    }
}

// The pages fresh changed from the head that the step does not keep: what
// the revision before held there is what the head held.
@(private)
rebase_grid :: proc(g:^Grid_Swap($T),head,fresh:^terrain.Grid(T),allocator:runtime.Allocator) -> bool {
    if g.whole {return true}
    if head.size!=fresh.size || len(head.pages)!=len(fresh.pages) {
        // The grid came or went: the step keeps the whole grid of the revision before.
        before:terrain.Grid(T)
        if !terrain.grid_clone(&before,head,allocator) {return false}
        grid_apply(g,&before)
        for entry in g.pages {terrain.page_free(entry.page)}
        delete(g.pages)
        g^={whole=true,grid=before}
        return true
    }
    for i in 0..<len(head.pages) {
        if terrain.grid_page_same(head,fresh,i) {continue}
        kept:=false
        for entry in g.pages {if entry.index==i {kept=true;break}}
        if kept {continue}
        if append(&g.pages,Page_Swap(T){i,terrain.page_share(head.pages[i])})!=1 {terrain.page_free(head.pages[i]);return false}
    }
    return true
}
