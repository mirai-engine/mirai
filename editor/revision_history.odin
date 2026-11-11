package editor

import "core:log"
import "mirai:core"
import "mirai:editor/history"
import "mirai:host"
import "mirai:std/base"

// The history of sources a tool edits in files of their own, outside the
// scene (a terrain, a foliage). The entities that show a source keep the
// revision its file holds, which the edits of the scene move; for each
// source it edited the tool keeps its head: what the file holds at that
// revision. A step between two revisions keeps what the source held at the
// one the head is not at, only where the two differ. Undo and redo trade a
// step with the head, so a change is kept once whichever way it goes. What a
// step keeps and how it trades it with a head is of the tool
// (Revision_Source); Step has the fields source, from and to.

REVISION_STEPS_CAPACITY :: 2*history.EDITS_STEP_CAPACITY

// The revision the file of a source holds, its stamp once the tool wrote it,
// and once the tool edits it, its head.
Revision_Head :: struct($Source,$Stamp:typeid) {
    source:base.Asset_Id,
    revision:u32,
    stamp:Stamp,
    held:bool, // head is the source at revision
    head:Source,
}

Revision_History :: struct($Step,$Source,$Stamp:typeid) {
    steps:[dynamic]Step,
    applied:[dynamic]Revision_Head(Source,Stamp),
    initial:u64,  // of the edits when the history last took it
    registry:u64, // the revision of the registry of the assets when the stamps were last compared
    moves:u64,    // undos and redos of the edits then
}

// What a tool does with its sources and its steps.
Revision_Source :: struct($Step,$Source,$Stamp:typeid) {
    name:string, // of the sources, in what the log says
    stamp:proc(a:^host.Assets,id:base.Asset_Id) -> Stamp,
    write:proc(s:^Session,a:^host.Assets,id:base.Asset_Id,head:^Source) -> bool,
    read:proc(fresh:^Source,a:^host.Assets,id:base.Asset_Id,head:^Source) -> bool, // the file into fresh, as head keeps it
    apply:proc(step:^Step,head:^Source),       // trades a step with the head
    step_destroy:proc(step:^Step),
    source_destroy:proc(source:^Source),
    // The file changed outside the tool while its owners stayed at revision:
    // the step that leads to it keeps, for what fresh changed, what head held.
    rebase:proc(steps:^[dynamic]Step,id:base.Asset_Id,revision:u32,head,fresh:^Source),
}

revision_history_destroy :: proc(h:^Revision_History($Step,$Source,$Stamp),src:Revision_Source(Step,Source,Stamp)) {
    for &step in h.steps {src.step_destroy(&step)}
    for &entry in h.applied {src.source_destroy(&entry.head)}
    delete(h.steps)
    delete(h.applied)
    h^={}
}

revision_applied :: proc(h:^Revision_History($Step,$Source,$Stamp),id:base.Asset_Id) -> ^Revision_Head(Source,Stamp) {
    for &entry in h.applied {if entry.source==id {return &entry}}
    return nil
}

// The head of a source at a revision; nil before the tool edits it.
revision_head :: proc(h:^Revision_History($Step,$Source,$Stamp),id:base.Asset_Id,revision:u32) -> ^Source {
    if entry:=revision_applied(h,id);entry!=nil && entry.held && entry.revision==revision {return &entry.head}
    return nil
}

revision_find :: proc(h:^Revision_History($Step,$Source,$Stamp),id:base.Asset_Id,from,to:u32) -> int {
    for &step,i in h.steps {if step.source==id && step.from==from && step.to==to {return i}}
    return -1
}

// Keeps a step of a source, after the ones before it: those from its revision
// on were a history undone, which it replaces. The oldest step goes past
// REVISION_STEPS_CAPACITY. False without memory: the step is let go.
revision_push :: proc(h:^Revision_History($Step,$Source,$Stamp),step:^Step,destroy:proc(step:^Step)) -> bool {
    for i:=len(h.steps)-1;i>=0;i-=1 {
        if h.steps[i].source==step.source && h.steps[i].from>=step.from {destroy(&h.steps[i]);ordered_remove(&h.steps,i)}
    }
    if len(h.steps)>=REVISION_STEPS_CAPACITY {destroy(&h.steps[0]);ordered_remove(&h.steps,0)}
    if append(&h.steps,step^)!=1 {destroy(step);return false}
    step^={}
    return true
}

// Takes the head of a source from its revision to another by its steps, into
// path the steps it applied in order. False, the head as it was, when a step
// is missing.
revision_walk :: proc(h:^Revision_History($Step,$Source,$Stamp),id:base.Asset_Id,head:^Source,from,target:u32,path:^[dynamic]int,apply:proc(step:^Step,head:^Source)) -> bool {
    clear(path)
    at:=from
    for at!=target {
        found:=-1
        for &step,i in h.steps {
            if step.source!=id {continue}
            if target<at && step.to==at {found=i;at=step.from;break}
            if target>at && step.from==at {found=i;at=step.to;break}
        }
        if found<0 || len(path)>len(h.steps) {clear(path);return false}
        append(path,found)
    }
    for i in path {apply(&h.steps[i],head)}
    return true
}

// The file of a source changed outside the tool (the history of the editor, git)
// while its owners stayed at the revision of its head: that revision holds
// fresh from here on, and the head takes it.
revision_rebase :: proc(h:^Revision_History($Step,$Source,$Stamp),src:Revision_Source(Step,Source,Stamp),id:base.Asset_Id,revision:u32,head,fresh:^Source) {
    src.rebase(&h.steps,id,revision,head,fresh)
    src.source_destroy(head)
    head^=fresh^
    fresh^={}
}

// Undo and redo move the revisions the owners of the sources are at
// (markers, with the fields source and revision): their heads walk the steps
// there and are written to their files; follow, if given, gets each that
// moved, with the steps it applied. What changes a file outside the tool is
// what the revision its owners are at holds.
revision_sync :: proc(s:^Session,h:^Revision_History($Step,$Source,$Stamp),markers:^core.Table($Marker,$A),a:^host.Assets,src:Revision_Source(Step,Source,Stamp),user:rawptr=nil,follow:proc(user:rawptr,held:^Revision_Head(Source,Stamp),path:[]int)=nil) {
    if core.count(markers)>0 && s.edits!=nil && h.initial!=s.edits.initial {
        _=history.edits_sync_initial(s.edits,edited_world(s))
        h.initial=s.edits.initial
    }
    changed:=h.registry!=a.registry.revision
    h.registry=a.registry.revision
    moves:=s.edits!=nil?s.edits.stats.undos+s.edits.stats.redos:0
    moved:=moves!=h.moves
    h.moves=moves
    path:=make([dynamic]int,context.temp_allocator)
    for row in 0..<core.count(markers) {
        marker:=core.at(markers,row)
        if marker.source=={} {continue}
        held:=revision_applied(h,marker.source)
        if held==nil {append(&h.applied,Revision_Head(Source,Stamp){source=marker.source,revision=marker.revision,stamp=src.stamp(a,marker.source)});continue}
        head:=held.held?&held.head:nil
        if held.revision==marker.revision {
            if !changed {continue}
            stamp:=src.stamp(a,marker.source)
            if stamp==held.stamp {continue}
            // Undo and redo put back what a step held of the file (the one of
            // its creation): the head is what the revision the owners are at
            // holds. Otherwise it changed outside the tool, and the revision
            // holds what the file has.
            if moved && head!=nil && src.write(s,a,marker.source,head) {
                held.stamp=src.stamp(a,marker.source)
                continue
            }
            held.stamp=stamp
            if head!=nil {
                fresh:Source
                if src.read(&fresh,a,marker.source,head) {revision_rebase(h,src,marker.source,held.revision,head,&fresh)} else {src.source_destroy(&fresh)}
            }
            continue
        }
        if head==nil {held.revision,held.stamp=marker.revision,src.stamp(a,marker.source);continue}
        if !revision_walk(h,marker.source,head,held.revision,marker.revision,&path,src.apply) {log.errorf("the %s revision %d could not be restored",src.name,marker.revision);continue}
        if !src.write(s,a,marker.source,head) {
            log.errorf("the %s revision %d could not be restored",src.name,marker.revision)
            #reverse for i in path {src.apply(&h.steps[i],head)}
            continue
        }
        held.revision,held.stamp=marker.revision,src.stamp(a,marker.source)
        if follow!=nil {follow(user,held,path[:])}
    }
}
