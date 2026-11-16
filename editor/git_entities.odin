package editor

import "core:slice"
import "core:strings"
import "mirai:asset"
import "mirai:core"
import "mirai:editor/git"
import scene "mirai:engine/scene"
import "mirai:project"
import "mirai:std/base"
import "mirai:std/serial"

// The entities of a pending scene against what the index of git holds of it,
// by their ids: added, changed and removed, as a tree with those they hang
// from. Reverting one puts it back as the index holds it, with what hangs
// from it, as one step of whoever asks. The scene in front is compared as the
// World has it; another, as its file does.

GIT_ENTITY_COMPONENTS :: 96
GIT_ENTITY_DEPTH :: 64 // levels of the tree shown

Git_Entity_Change :: enum u8 {Same,Added,Changed,Removed}

Git_Entity :: struct {
    id,parent:base.Entity_Id,
    name:asset.Entity_Name,
    change:Git_Entity_Change,
    depth:int,
    order:u32,
    components:[GIT_ENTITY_COMPONENTS]u8, // of one that changed: what of it differs, by the names of its components
}

Git_Entities :: struct {
    path:[git.PATH_BYTES]u8, // the scene whose tree shows, from the root of the repository; empty: none
    reading:bool,            // git reads what the index holds of it
    read:bool,               // kept holds it
    kept:^asset.Scene,       // what the index holds; an empty scene for a file it lacks
    state:u64,               // of the history of the document when the rows were made
    stamp:[2]i64,            // of a file that is not the document in front when the rows were made
    rows:[dynamic]Git_Entity, // the entities that differ and those they hang from, in the order of the tree
}

@(private)
git_entities_free :: proc(n:^Git_Entities) {
    if n.kept!=nil {
        asset.scene_destroy(n.kept)
        free(n.kept)
    }
    delete(n.rows)
    n^={}
}

// The file of the scene whose tree shows, absolute.
@(private)
git_entities_file :: proc(s:^Session) -> string {
    g:=s.git
    return project.path(base.text_get(g.root[:]),base.text_get(g.entities.path[:]),allocator=context.temp_allocator)
}

// Shows the tree of a pending scene, by its path from the root of the
// repository; "" hides it. Says why it could not start.
git_entities_show :: proc(s:^Session,path:string) -> string {
    g:=s.git
    git_entities_free(&g.entities)
    if path=="" {return ""}
    if git.working(g) {return "Wait for git to finish"}
    if !g.repository {return "The project is not in a repository"}
    base.text_set(g.entities.path[:],path)
    g.entities.reading=true
    git.start_base(g,git_roots(s),path)
    return ""
}

// What the index holds of the scene arrived: the tree is made.
@(private)
git_entities_read :: proc(s:^Session) {
    g:=s.git
    n:=&g.entities
    if !n.reading {return}
    n.reading=false
    a:=s.app.assets
    if a==nil {return}
    kept:=new(asset.Scene)
    read:=asset.scene_read(kept,&a.types,g.out[:])==.None if g.base_found else asset.scene_init(kept,&a.types,{})==.None
    if !read {
        free(kept)
        git_entities_free(n)
        notify(s,"What git keeps of the scene could not be read")
        return
    }
    n.kept,n.read=kept,true
    git_entities_compute(s)
}

// The scene the tree compares with what is kept: the World when it is the
// document in front, else its file. The caller destroys it.
@(private)
git_entities_current :: proc(s:^Session,current:^asset.Scene) -> (front,ok:bool) {
    file:=git_entities_file(s)
    if project.path_same(file,document_file(s.document)) && s.edits.world==s.edit_world {
        return true,document_capture(s,current,s.document.id)==.None
    }
    return false,asset.scene_load(current,&s.app.assets.types,file)==.None
}

// Makes the tree again when what it compares changed: a step of the document, or the file.
git_entities_update :: proc(s:^Session) {
    n:=&s.git.entities
    if !n.read {return}
    file:=git_entities_file(s)
    if project.path_same(file,document_file(s.document)) {
        if n.state!=history_state(s) {git_entities_compute(s)}
    } else if stamp,_:=file_stamp(s,file);stamp!=n.stamp {
        git_entities_compute(s)
    }
}

@(private="file")
history_state :: proc(s:^Session) -> u64 {return s.edits.serial}

@(private)
git_entities_compute :: proc(s:^Session) {
    n:=&s.git.entities
    clear(&n.rows)
    n.state=history_state(s)
    n.stamp,_=file_stamp(s,git_entities_file(s))
    current:asset.Scene
    if _,ok:=git_entities_current(s,&current);!ok {return}
    defer asset.scene_destroy(&current)
    kept:=n.kept

    Found :: struct {change:Git_Entity_Change,components:[GIT_ENTITY_COMPONENTS]u8}
    found:=make(map[base.Entity_Id]Found,context.temp_allocator)
    differs :: proc(found:^map[base.Entity_Id]Found,id:base.Entity_Id,what:string) {
        entry:=found[id]
        if entry.change==.Same {entry.change=.Changed}
        listed:=base.text_get(entry.components[:])
        if entry.change==.Changed && what!="" && !strings.contains(listed,what) {
            base.text_set(entry.components[:],listed==""?what:strings.concatenate({listed,", ",what},context.temp_allocator))
        }
        found[id]=entry
    }
    out:serial.Writer
    serial.writer_init(&out,0,context.temp_allocator)
    asset.document_diff(&kept.doc,&current.doc,&out)
    text:=string(serial.writer_bytes(&out))
    for line in strings.split_lines_iterator(&text) {
        if len(line)<3 {continue}
        mark,rest:=line[0],line[2:]
        at:=strings.index(rest,"[@0x")
        if at<0 {
            // A component only one of them has: every entity that holds it differs.
            if mark=='~' || strings.index_any(rest,"[.: ")>=0 {continue}
            side:=mark=='-'?kept:&current
            if table,has:=asset.scene_component(side,rest);has && table>0 {
                for id in asset.scene_ids(side) {
                    if _,holds:=asset.scene_component_get(side,table,id);holds {differs(&found,id,rest)}
                }
            }
            continue
        }
        table:=rest[:at]
        if len(rest)<at+4+base.ENTITY_ID_TEXT {continue}
        value,parsed:=serial.text_parse_hex(rest[at+4:][:base.ENTITY_ID_TEXT])
        if !parsed {continue}
        id:=base.Entity_Id(value)
        if table!=asset.TABLE_ENTITIES {
            differs(&found,id,table)
            continue
        }
        switch mark {
        case '+': found[id]={change=.Added}
        case '-': found[id]={change=.Removed}
        case:
            field:=rest[at+4+base.ENTITY_ID_TEXT:]
            if close:=strings.index_byte(field,'.');close>=0 {field=field[close+1:]}
            if colon:=strings.index_byte(field,':');colon>=0 {field=field[:colon]}
            // Its place among its siblings moves when one of them comes or goes: alone, it is no change of the entity.
            if field!="order" {differs(&found,id,field)}
        }
    }
    if len(found)==0 {return}

    // Each with those it hangs from, where the scene has it now or, once removed, where it was kept.
    record :: proc(current,kept:^asset.Scene,id:base.Entity_Id) -> (entity:asset.Entity_Record,ok:bool) {
        if row,has:=asset.scene_entity_find(current,id);has {return asset.scene_entity(current,row),true}
        if row,has:=asset.scene_entity_find(kept,id);has {return asset.scene_entity(kept,row),true}
        return {},false
    }
    nodes:=make([dynamic]Git_Entity,context.temp_allocator)
    listed:=make(map[base.Entity_Id]bool,context.temp_allocator)
    for id,entry in found {
        for at:=id;at!=0 && !listed[at]; {
            entity,ok:=record(&current,kept,at)
            if !ok {break}
            node:=Git_Entity{id=at,parent=entity.parent,order=entity.order}
            base.text_set(node.name[:],entity.name)
            if known,has:=found[at];has {node.change,node.components=known.change,known.components}
            append(&nodes,node)
            listed[at]=true
            at=entity.parent
        }
    }
    for &node in nodes {
        if !listed[node.parent] {node.parent=0}
    }
    slice.sort_by(nodes[:],proc(a,b:Git_Entity) -> bool {
        if a.parent!=b.parent {return a.parent<b.parent}
        if a.order!=b.order {return a.order<b.order}
        return a.id<b.id
    })
    // Depth first: the children of a node are a run of the sorted nodes.
    first :: proc(nodes:[]Git_Entity,parent:base.Entity_Id) -> int {
        low,high:=0,len(nodes)
        for low<high {
            middle:=(low+high)/2
            if nodes[middle].parent<parent {low=middle+1} else {high=middle}
        }
        return low
    }
    write :: proc(n:^Git_Entities,nodes:[]Git_Entity,parent:base.Entity_Id,depth:int) {
        for at:=first(nodes,parent);at<len(nodes) && nodes[at].parent==parent;at+=1 {
            node:=nodes[at]
            node.depth=depth
            append(&n.rows,node)
            if depth<GIT_ENTITY_DEPTH {write(n,nodes,node.id,depth+1)}
        }
    }
    write(n,nodes[:],0,0)
}

// Puts some entities of the scene in front back as the index holds them,
// and with subtree what hangs from them in either: those it has otherwise
// take what was kept, those it lacks come back and those the index lacks go.
// One step. Returns how many differed, or why nothing changed.
git_entities_revert :: proc(s:^Session,ids:[]base.Entity_Id,subtree:bool) -> (reverted:int,message:string) {
    n:=&s.git.entities
    a:=s.app.assets
    if !n.read || a==nil {return 0,"The changes of the scene were not read: git.changes reads them"}
    if s.mode!=.Edit {return 0,"A game plays: stop it first"}
    current:asset.Scene
    front,captured:=git_entities_current(s,&current)
    if !front {
        if captured {asset.scene_destroy(&current)}
        return 0,"The scene is not the document in front: open it first"
    }
    if !captured {return 0,"The scene could not be copied out of the World"}
    defer asset.scene_destroy(&current)
    kept:=n.kept

    wanted:=make(map[base.Entity_Id]bool,context.temp_allocator)
    for id in ids {wanted[id]=true}
    for grew:=subtree;grew; {
        grew=false
        for side in ([2]^asset.Scene{kept,&current}) {
            parents:=asset.scene_parents(side)
            for id,row in asset.scene_ids(side) {
                if !wanted[id] && wanted[parents[row]] {wanted[id],grew=true,true}
            }
        }
    }
    for &row in n.rows {
        if row.change!=.Same && wanted[row.id] {reverted+=1}
    }
    if reverted==0 {return 0,"Those entities are as git keeps them"}

    // What is kept of them, as a scene of its own: their roots hang from nothing in it.
    part:asset.Scene
    if asset.scene_init(&part,&a.types,kept.doc.id,context.temp_allocator)!=.None {return 0,"There is not enough memory"}
    defer asset.scene_destroy(&part)
    kept_ids,kept_parents:=asset.scene_ids(kept),asset.scene_parents(kept)
    for added:=true;added; {
        added=false
        for id,row in kept_ids {
            if !wanted[id] {continue}
            if _,has:=asset.scene_entity_find(&part,id);has {continue}
            parent:=kept_parents[row] if wanted[kept_parents[row]] else 0
            if _,placed:=asset.scene_entity_find(&part,parent);parent!=0 && !placed {continue}
            entity:=asset.scene_entity(kept,row)
            if _,error:=asset.scene_entity_add(&part,id,parent,entity.name,int(entity.order));error!=.None {return 0,"There is not enough memory"}
            added=true
        }
    }
    for &source,at in kept.doc.tables {
        component:=at>0 && len(source.columns)==2 && source.columns[0].name==asset.COLUMN_ENTITY && source.columns[0].ref==0 && source.columns[1].name==asset.COLUMN_VALUE
        if !component {continue}
        target:=-1
        for id in asset.scene_ids(&part) {
            image,has:=asset.scene_component_get(kept,at,id)
            if !has {continue}
            if target<0 {
                added,error:=asset.scene_component_add(&part,source.name,&kept.doc.schema,source.columns[1].type)
                if error!=.None {return 0,"There is not enough memory"}
                target=added
            }
            if asset.scene_component_set(&part,target,id,image)!=.None {return 0,"There is not enough memory"}
        }
    }
    for off in kept.off {
        if _,has:=asset.scene_entity_find(&part,off.entity);has {asset.scene_component_turn(&part,off.entity,off.component,true)}
    }
    data,encoded:=asset.scene_bytes(&part,context.temp_allocator)
    if encoded!=.None {return 0,"There is not enough memory"}
    file:asset.Asset
    if asset.asset_open(&file,data)!=.None {return 0,"What git keeps of those entities could not be read"}
    defer asset.asset_close(&file)

    // Those the scene has now are the ones the update may take away.
    scope:=make([dynamic]base.Entity_Id,context.temp_allocator)
    for id in asset.scene_ids(&current) {
        if wanted[id] {append(&scope,id)}
    }
    opened,ready:=edit_open(s,"Revert")
    if !ready {return 0,"Finish or cancel the edit in progress first"}
    defer edit_close(s,opened)
    w:=edited_world(s)
    if _,failed:=scene.update(w,&file,&a.types,{scope=scope[:]});failed!=.None {
        return 0,"Something that stays hangs from an entity that would go: revert the one it hangs from, with what hangs from it"
    }
    core.world_settle(w)
    // The roots of what came back hang where they were kept, when that is still there.
    es:=core.world_entities(w)
    parents:=core.world_table_of(w,core.Parent)
    for id,row in asset.scene_ids(&part) {
        if asset.scene_parents(&part)[row]!=0 || parents==nil {continue}
        e:=core.entity_of(es,id)
        at,_:=asset.scene_entity_find(kept,id)
        entity:=asset.scene_entity(kept,at)
        under:=core.entity_of(es,entity.parent) if entity.parent!=0 else core.NONE
        if e==core.NONE || entity.parent!=0 && under==core.NONE || entity_parent(w,e)==under {continue}
        if under==core.NONE {
            core.remove(parents,e)
        } else if held:=core.edit(parents,e);held!=nil {
            held.entity,held.order=under,i32(entity.order)
        } else {
            core.add(parents,e,core.Parent{under,i32(entity.order)})
        }
    }
    core.world_settle(w)
    return reverted,""
}
