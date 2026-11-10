package author

import "core:fmt"
import "core:slice"
import "mirai:host"
import "mirai:std/base"
import "mirai:std/serial"
import "mirai:ui"

// Operations on the records that the hierarchy, the stage and the cards of
// Properties ask for besides those of records.odin: several nodes at once,
// the columns of a Grid and the animations of the file.

// ---------------------------------------------------------------- several nodes

// The rows chosen that are not inside another row chosen, in order and once.
selection_roots :: proc(nodes:[]ui.Tree_Node,rows:[]int,allocator:=context.temp_allocator) -> []int {
    sorted:=make([dynamic]int,0,len(rows),allocator)
    for row in rows {
        if row>=0 && row<len(nodes) && !slice.contains(sorted[:],row) {append(&sorted,row)}
    }
    slice.sort(sorted[:])
    roots:=make([dynamic]int,0,len(sorted),allocator)
    for row in sorted {
        inside:=false
        for parent:=int(nodes[row].parent);parent>=0;parent=int(nodes[parent].parent) {
            if slice.contains(sorted[:],parent) {inside=true;break}
        }
        if !inside {append(&roots,row)}
    }
    delete(sorted)
    return roots[:]
}

// Removes the nodes of rows and what they hold.
records_delete_rows :: proc(r:^Records,rows:[]int) {
    roots:=selection_roots(r.nodes[:],rows)
    #reverse for row in roots {records_delete(r,row)}
}

// Copies each node of rows with what it holds right after it; returns the
// copies, in the order of their originals.
records_duplicate_rows :: proc(r:^Records,rows:[]int,allocator:=context.temp_allocator) -> []int {
    list:=&r.nodes
    if list==nil {return nil}
    roots:=selection_roots(list[:],rows)
    copies:=make([]int,len(roots),allocator)
    sizes:=make([]int,len(roots),context.temp_allocator)
    for row,i in roots {sizes[i]=records_subtree(list[:],row)+1}
    // From the last: a copy does not move the rows before it.
    for i:=len(roots)-1;i>=0;i-=1 {
        copies[i]=records_duplicate(r,roots[i])
        if copies[i]<0 {return copies[i:i]}
    }
    // Each copy moved by the copies made before it.
    for i in 0..<len(copies) {
        for j in 0..<i {copies[i]+=sizes[j]}
    }
    return copies
}

// Copies the nodes of rows of the tree and what they hold into clip, in
// allocator, one block after another: the first node of each is a root.
records_copy_rows :: proc(r:^Records,rows:[]int,clip:^Clip_Nodes,allocator:=context.allocator) {
    roots:=selection_roots(r.nodes[:],rows)
    if len(roots)==0 {return}
    records_copy(r,roots[0],clip,allocator)
    for row in roots[1:] {
        block:Records
        if !records_extract(r,row,&block,context.temp_allocator) {continue}
        m:=merge_begin(&clip.records,&block)
        merge_put(&m,block.nodes[:],block.overrides[:],len(clip.records.nodes),-1)
    }
}

// The blocks of a clip: the first row of each and how many rows it has.
clip_blocks :: proc(clip:^Clip_Nodes,allocator:=context.temp_allocator) -> [][2]int {
    blocks:=make([dynamic][2]int,allocator)
    for n,i in clip.records.nodes {
        if n.parent<0 || i==0 {append(&blocks,[2]int{i,1})} else if len(blocks)>0 {blocks[len(blocks)-1][1]+=1}
    }
    return blocks[:]
}

// Puts a copy of what clip holds inside the row chosen when it holds nodes,
// after it otherwise, or last at the root (-1), the blocks one after another,
// with copies of the rows of its file they use (records_paste). Returns the
// first row of each copy; none when there is nothing to paste or no room.
records_paste_rows :: proc(r:^Records,row:int,clip:^Clip_Nodes,allocator:=context.temp_allocator) -> []int {
    from:=&clip.records
    blocks:=clip_blocks(clip)
    pasted:=make([dynamic]int,0,len(blocks),allocator)
    if len(blocks)==0 {return pasted[:]}
    parent,at:=-1,len(r.nodes)
    if row>=0 && row<len(r.nodes) {
        if records_takes(r.nodes[:],row) && ui.node_kind_holds(r.nodes[row].kind) {
            parent,at=row,row+records_subtree(r.nodes[:],row)+1
        } else {
            parent,at=int(r.nodes[row].parent),row+records_subtree(r.nodes[:],row)+1
            if !records_takes(r.nodes[:],parent) {return pasted[:]}
        }
    }
    m:=merge_begin(r,from)
    for block in blocks {
        first,count:=block[0],block[1]
        nodes:=make([]ui.Tree_Node,count,context.temp_allocator)
        for n,i in from.nodes[first:first+count] {
            nodes[i]=n
            nodes[i].parent=-1 if i==0 else n.parent-i32(first)
        }
        overrides:=make([dynamic]ui.Tree_Override,context.temp_allocator)
        for o in from.overrides {
            if int(o.instance)<first || int(o.instance)>=first+count {continue}
            moved:=o
            moved.instance-=u32(first)
            append(&overrides,moved)
        }
        if merge_put(&m,nodes,overrides[:],at,parent)<0 {break}
        for i in at..<at+count {records_name_free(r,i)}
        append(&pasted,at)
        at+=count
    }
    return pasted[:]
}

// Moves the nodes of rows of the tree and what they hold inside parent (-1:
// a root), one after another before the row before (-1: last). Returns
// where each went, in order; nil when one cannot go there: into itself or
// into what takes no other node.
records_place_rows :: proc(r:^Records,rows:[]int,parent,before:int,allocator:=context.temp_allocator) -> []int {
    list:=r.nodes[:]
    roots:=selection_roots(list,rows)
    if len(roots)==0 || parent>=len(list) || before>=len(list) {return nil}
    inside :: proc(at,row,count:int) -> bool {return at>=row && at<row+count}
    moved_in:=0
    for row in roots {
        count:=records_subtree(list,row)+1
        if parent>=0 && inside(parent,row,count) || before>=0 && inside(before,row,count) {return nil}
        if int(list[row].parent)==parent {moved_in+=1}
    }
    if parent>=0 && !ui.node_kind_holds(list[parent].kind) {return nil}
    // A List holds one node.
    if parent>=0 && list[parent].kind==.List {
        held:=0
        for &n in list {held+=int(int(n.parent)==parent)}
        if held-moved_in+len(roots)>1 {return nil}
    }
    blocks:=make([]Block,len(roots),context.temp_allocator)
    for row,i in roots {blocks[i]=records_block(r,row)}
    // From the last: the rows before a removed block stay where they are.
    // Moving keeps what names the nodes.
    parent,before:=parent,before
    for i:=len(roots)-1;i>=0;i-=1 {
        row:=roots[i]
        count:=len(blocks[i].nodes)
        records_remove(r,row)
        if parent>row {parent-=count}
        if before>row {before-=count}
    }
    at:=before
    if at<0 {at=len(r.nodes) if parent<0 else parent+records_subtree(r.nodes[:],parent)+1}
    placed:=make([]int,len(roots),allocator)
    for &block,i in blocks {
        if !records_block_put(r,block,at,parent) {return nil}
        placed[i]=at
        at+=len(block.nodes)
    }
    return placed
}

// ---------------------------------------------------------------- grid columns

// How many nodes of the file and the overrides of its
// instances name a row of grid_tracks.
records_grid_tracks_users :: proc(r:^Records,row:int) -> (users:int) {
    for &n in r.nodes {users+=int(int(n.layout.tracks)==row+1)}
    for &o in r.overrides {users+=int(.Layout in o.fields && int(o.values.layout.tracks)==row+1)}
    return
}

// The row of grid_tracks a Grid node changes: its own, made the first time
// with one Grow column for each of its columns, or a copy of the one it
// shares. -1 when there is no room.
records_grid_tracks :: proc(r:^Records,node:^ui.Tree_Node) -> int {
    at:=int(node.layout.tracks)-1
    if at>=0 && at<len(r.grid_tracks) && records_grid_tracks_users(r,at)<=1 {return at}
    if len(r.grid_tracks)>=int(max(u16)) {return -1}
    tracks:ui.Grid_Tracks
    if at>=0 && at<len(r.grid_tracks) {
        tracks=r.grid_tracks[at]
    } else {
        tracks.count=u8(clamp(int(node.layout.columns),1,ui.GRID_TRACKS))
        for &column in tracks.columns[:tracks.count] {column=ui.GROW}
    }
    append(&r.grid_tracks,tracks)
    node.layout.tracks=u16(len(r.grid_tracks))
    return len(r.grid_tracks)-1
}

// Sets how many columns a row of grid_tracks has: those added grow.
records_grid_tracks_count :: proc(r:^Records,row,count:int) {
    if row<0 || row>=len(r.grid_tracks) {return}
    t:=&r.grid_tracks[row]
    count:=clamp(count,1,ui.GRID_TRACKS)
    for i in int(t.count)..<count {t.columns[i]=ui.GROW}
    for i in count..<ui.GRID_TRACKS {t.columns[i]={}}
    t.count=u8(count)
}

// The node goes back to columns of the same width; the row it named goes
// when nothing else names it, and the rows after it move up.
records_grid_tracks_drop :: proc(r:^Records,node:^ui.Tree_Node) {
    at:=int(node.layout.tracks)-1
    node.layout.tracks=0
    if at<0 || at>=len(r.grid_tracks) || records_grid_tracks_users(r,at)>0 {return}
    ordered_remove(&r.grid_tracks,at)
    shift :: proc(tracks:^u16,at:int) {if int(tracks^)>at+1 {tracks^-=1}}
    for &n in r.nodes {shift(&n.layout.tracks,at)}
    for &o in r.overrides {shift(&o.values.layout.tracks,at)}
}

// ---------------------------------------------------------------- animations

// Adds part, an earlier animation, at the end of the parts of a group,
// wherever its parts are in the table. False when anim is no group.
records_part_add :: proc(r:^Records,anim:int,part:ui.Anim) -> bool {
    if anim<0 || anim>=len(r.anims) || r.anims[anim].kind==.Clip {return false}
    a:=&r.anims[anim]
    at:=int(a.first+a.count)
    if a.count==0 {at=len(r.parts);a.first=u32(at)}
    inject_at(&r.parts,at,part)
    for &other,i in r.anims {
        if i!=anim && other.kind!=.Clip && int(other.first)>=at {other.first+=1}
    }
    a.count+=1
    return true
}

// Removes the part-th part of a group.
records_part_remove :: proc(r:^Records,anim,part:int) {
    if anim<0 || anim>=len(r.anims) || r.anims[anim].kind==.Clip {return}
    a:=&r.anims[anim]
    if part<0 || part>=int(a.count) {return}
    at:=int(a.first)+part
    ordered_remove(&r.parts,at)
    for &other,i in r.anims {
        if i!=anim && other.kind!=.Clip && int(other.first)>at {other.first-=1}
    }
    a.count-=1
}

// Removes an animation of the file with its tracks and keys, or its parts:
// the groups that played it and the sets that named it lose it, and the
// animations after it move up a row.
records_anim_remove :: proc(r:^Records,anim:int) {
    if anim<0 || anim>=len(r.anims) {return}
    a:=r.anims[anim]
    if a.kind==.Clip {
        records_anim_contents_drop(r,anim)
    } else {
        for part:=int(a.count)-1;part>=0;part-=1 {records_part_remove(r,anim,part)}
    }
    // Groups that play it lose it.
    played:=ui.Anim(anim+1)
    for &other,i in r.anims {
        if i==anim || other.kind==.Clip {continue}
        for part:=int(other.count)-1;part>=0;part-=1 {
            if r.parts[int(other.first)+part]==played {records_part_remove(r,i,part)}
        }
    }
    ordered_remove(&r.anims,anim)
    for &part in r.parts {if part>played {part-=1}}
    fix :: proc(value:^ui.Anim,played:ui.Anim) {
        if value^==played {value^=0} else if value^>played {value^-=1}
    }
    for &set in r.anim_sets {
        fix(&set.shown,played);fix(&set.hidden,played);fix(&set.clicked,played)
    }
}

// ---------------------------------------------------------------- widgets

// The components a .ui names; false when its file does not read.
Widget_Uses :: proc(user:rawptr,id:base.Asset_Id) -> (used:[]ui.Tree_Component,read:bool)

// A walk of the .ui that others use, depth first: what it found when it ended.
Widget_Walk :: struct {
    uses:Widget_Uses,
    user:rawptr,
    target:base.Asset_Id, // none: it only looks for what fails
    chain:[dynamic]base.Asset_Id, // the files open, from the first; when it reached target, the way there
    seen:[dynamic]base.Asset_Id,
    reached:bool,
    broken:ui.Tree_Component, // the first component that does not read or that closes a cycle
    cycle:bool,
}

// Walks what used names, from the file from (none: from records of no file).
widget_walk :: proc(used:[]ui.Tree_Component,from,target:base.Asset_Id,uses:Widget_Uses,user:rawptr) -> (w:Widget_Walk) {
    w.uses,w.user,w.target=uses,user,target
    w.chain,w.seen=make([dynamic]base.Asset_Id,context.temp_allocator),make([dynamic]base.Asset_Id,context.temp_allocator)
    if from!={} {
        append(&w.chain,from)
        append(&w.seen,from)
    }
    widget_walk_down(&w,used)
    return
}

// True when it reached target, with the chain left as it was.
widget_walk_down :: proc(w:^Widget_Walk,used:[]ui.Tree_Component) -> bool {
    broke :: proc(w:^Widget_Walk,component:ui.Tree_Component,cycle:bool) {
        if w.broken.widget=={} {w.broken,w.cycle=component,cycle}
    }
    for component in used {
        id:=component.widget
        if id=={} {continue}
        if id==w.target {w.reached=true;return true}
        if slice.contains(w.chain[:],id) {broke(w,component,true);continue}
        if slice.contains(w.seen[:],id) {continue}
        append(&w.seen,id)
        held,read:=w.uses(w.user,id)
        if !read {broke(w,component,false);continue}
        append(&w.chain,id)
        if widget_walk_down(w,held) {return true}
        pop(&w.chain)
    }
    return false
}

// The components of a .ui, read from its file. user: the ^Assets.
widget_uses_of_file :: proc(user:rawptr,id:base.Asset_Id) -> (used:[]ui.Tree_Component,read:bool) {
    records:Records
    if !records_read((^Assets)(user)^,id,&records,context.temp_allocator) {return}
    return records.components[:],true
}

// Whether the widget from reaches target through the widgets it holds, the
// widgets those hold and so on: putting from inside target would make a
// widget that holds itself.
widget_reaches :: proc(from,target:base.Asset_Id,uses:Widget_Uses,user:rawptr) -> bool {
    if from==target {return true}
    used,read:=uses(user,from)
    return read && widget_walk(used,from,target,uses,user).reached
}

// Takes away the tracks and keys of an animation, or its parts: the row stays
// for the events that play it, with nothing in it.
records_anim_contents_drop :: proc(r:^Records,anim:int) {
    if anim<0 || anim>=len(r.anims) {return}
    a:=r.anims[anim]
    if a.kind==.Clip {
        for t:=int(a.first+a.count)-1;t>=int(a.first);t-=1 {
            track:=r.tracks[t]
            records_keys_remove(r,int(track.first_key),int(track.key_count))
        }
        remove_range(&r.tracks,int(a.first),int(a.first+a.count))
        for &other,i in r.anims {
            if i!=anim && other.kind==.Clip && other.first>=a.first+a.count {other.first-=a.count}
        }
    } else {
        for part:=int(a.count)-1;part>=0;part-=1 {records_part_remove(r,anim,part)}
    }
    r.anims[anim].first,r.anims[anim].count=0,0
}

// ---------------------------------------------------------------- what a widget takes

// The node of the file called name; nil: none.
records_node_named :: proc(r:^Records,name:string) -> ^ui.Tree_Node {
    if name=="" {return nil}
    for &n in r.nodes {if serial.text_field(n.name[:])==name {return &n}}
    return nil
}

// Why a parameter cannot have the name its row has; empty: it can.
records_param_valid_name :: proc(r:^Records,row:int) -> string {
    p:=&r.params[row]
    name:=serial.text_field(p.name[:])
    if name=="" || name=="children" {return "A parameter needs a name of its own"}
    reserved:=DOCUMENT_NODE_KEYS
    _,is_node:=doc_instance_field(name)
    if slice.contains(reserved[:],name) || is_node {return "A node has a key of that name"}
    for &other,i in r.params {if i!=row && other.name==p.name {return "The widget has a parameter of that name"}}
    return ""
}

// A new parameter, called param and a number no other has, going to the text of its root.
records_param_add :: proc(r:^Records) -> int {
    append(&r.params,ui.Tree_Param{})
    at:=len(r.params)-1
    for n in 1..=at+1 {
        ui.tree_text_set(r.params[at].name[:],fmt.tprintf("param%d",n))
        if records_param_valid_name(r,at)=="" {break}
    }
    return at
}

// Where a parameter goes: a field of a node (node empty: the root), or param
// of the use at node.
records_param_target :: proc(r:^Records,row:int,node:string,field:ui.Tree_Param_Field,param:string) {
    p:=&r.params[row]
    ui.tree_text_set(p.node[:],node)
    p.field=field
    ui.tree_text_set(p.param[:],param)
}

// Whether a node of the file holds what a use holds, the Slot, the last of
// its file: one node at most. Why it cannot be; empty: done.
records_slot_set :: proc(r:^Records,row:int,on:bool) -> string {
    if row<0 || row>=len(r.nodes) {return "Choose a node"}
    n:=&r.nodes[row]
    if !on {n.flags-={.Slot};return ""}
    if !ui.node_kind_holds(n.kind) {return "Only what holds nodes takes the Slot"}
    if row+records_subtree(r.nodes[:],row)!=len(r.nodes)-1 {return "The Slot is the last node of the widget: move it after the others first"}
    for &other in r.nodes {other.flags-={.Slot}}
    r.nodes[row].flags+={.Slot}
    return ""
}

// What a widget made of a part of another file takes: for each named node of
// its nodes that shows a text or binds one, a parameter of that name, so a
// use names only what differs.
records_widget_params :: proc(r:^Records) {
    for &n,row in r.nodes {
        name:=serial.text_field(n.name[:])
        if row==0 || name=="" || n.kind==.Component {continue}
        fields:ui.Tree_Param_Field
        ok:=false
        switch {
        case serial.text_field(n.bind_text[:])!="":  fields,ok=.Bind_Text,true
        case serial.text_field(n.bind_value[:])!="": fields,ok=.Bind_Value,true
        case records_text(r,n.text)!="":             fields,ok=.Text,true
        }
        if !ok || len(r.params)>=WIDGET_MADE_PARAMS {continue}
        append(&r.params,ui.Tree_Param{field=fields})
        at:=len(r.params)-1
        ui.tree_text_set(r.params[at].name[:],name)
        ui.tree_text_set(r.params[at].node[:],name)
        if records_param_valid_name(r,at)!="" {
            ui.tree_text_set(r.params[at].name[:],fmt.tprintf("%s_%s",name,fields==.Text ? "text" : "value"))
            if records_param_valid_name(r,at)!="" {ordered_remove(&r.params,at)}
        }
    }
}

// Parameters Make widget declares by itself at most.
WIDGET_MADE_PARAMS :: 8
