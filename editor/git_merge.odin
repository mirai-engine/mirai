package editor

import "core:fmt"
import "core:mem"
import vmem "core:mem/virtual"
import "core:strings"
import "mirai:asset"
import "mirai:cook/build"
import "mirai:core"
import "mirai:editor/git"
import scene "mirai:engine/scene"
import "mirai:project"
import gpu "mirai:render"
import "mirai:std/base"
import "mirai:std/serial"
import "mirai:ui"

// A pull that left files in conflict. The editor reads the three versions of
// each one from git (base, ours, theirs), merges assets again in memory with
// asset.scene_merge and lists what is left: values both sides changed, rows
// one side removed, tables matched whole, and files that do not merge
// (code, textures). Every conflict takes theirs, what came in, until it is
// changed; the scene shows the choice as it would be committed. Finish writes
// every file as chosen, adds them and commits the merge.

GIT_VALUE_BYTES :: 256

Git_Conflict :: struct {
    kind:asset.Merge_Kind,
    path:[git.PATH_BYTES]u8,   // as document_locate reads it
    table:[64]u8,              // the component, or the table
    field:[160]u8,             // what follows the row in path: ".value.position"
    ours,theirs:[GIT_VALUE_BYTES]u8, // the values as JSON; "" when the side has no row
    ours_has,theirs_has:bool,
    take_ours:bool,            // the merge keeps what ours had
}

// A file merged whole: the version it takes.
Git_Whole :: enum u8 {Theirs,Ours,Folder} // Folder: as it is in the work tree, what the AI wrote

Git_Merge_File :: struct {
    path:[git.PATH_BYTES]u8, // from the root of the repository
    stages:[3][]u8,          // base, ours and theirs from git; nil: that side does not have it
    merged:[]u8,             // the merge of assets with every conflict as ours; nil: the file merges whole
    whole:Git_Whole,
    text:bool,               // no NUL in ours: the AI can merge it
}

// What the arrows go through: the conflicts of one entity of a file, or a
// file merged whole.
Git_Merge_Item :: struct {
    file:int,
    key:base.Entity_Id, // 0: the file, or what has no entity
    name:[64]u8,
    first,count:int,
    accepted:bool,
}

Git_Merge :: struct {
    loaded:bool,
    arena:vmem.Arena,
    files:[dynamic]Git_Merge_File,
    items:[dynamic]Git_Merge_Item,
    conflicts:[dynamic]Git_Conflict,
    current:int,  // the item Details shows
    shown:bool,   // Details shows the review instead of the selection
}

// The files the merge waits for, read again from git.
@(private)
git_merge_load_start :: proc(s:^Session) {
    g:=s.git
    git_merge_clear(g)
    for &change in g.changes {
        if change.status!='U' {continue}
        file:Git_Merge_File
        file.path=change.path
        append(&g.merge.files,file)
    }
    if len(g.merge.files)==0 {return}
    for &file in g.merge.files {append(&g.load_paths,strings.clone(base.text_get(file.path[:]),git_merge_arena(g)))}
    git.start(g,s.app.platform,git_roots(s),.Load)
}

git_merge_clear :: proc(g:^Git) {
    m:=&g.merge
    clear(&m.files);clear(&m.items);clear(&m.conflicts)
    // Their paths lived in the arena.
    clear(&g.load_paths);clear(&g.finish_paths)
    vmem.arena_destroy(&m.arena)
    m.arena={}
    m.loaded,m.current,m.shown=false,0,false
}

@(private)
git_merge_arena :: proc(g:^Git) -> mem.Allocator {
    if g.merge.arena.curr_block==nil {_=vmem.arena_init_growing(&g.merge.arena)}
    return vmem.arena_allocator(&g.merge.arena)
}

// The stage a step of the load read (git.Repository.load_paths), kept for the merge.
@(private)
git_merge_load_done :: proc(g:^Git,step:int,code:int) {
    if step>=3*len(g.merge.files) {return}
    if code!=0 {return}
    data:=make([]u8,len(g.out),git_merge_arena(g))
    copy(data,g.out[:])
    g.merge.files[step/3].stages[step%3]=data
}

// What is left to choose in each file, once its three versions are read.
@(private)
git_merge_compute :: proc(s:^Session) {
    g:=s.git
    m:=&g.merge
    a:=s.app.assets
    m.loaded=true
    plugins:=git_plugin_kinds(git_roots(s))
    for &file,f in m.files {
        name:=base.text_get(file.path[:])
        file.text=file.stages[1]!=nil
        for b in file.stages[1] {
            if b==0 {file.text=false;break}
        }
        if a==nil || file.stages[1]==nil || file.stages[2]==nil || !git_merges_entities(plugins,name) {
            git_merge_item_add(m,f,0,name,0,0)
            continue
        }
        ours,theirs:asset.Document
        if asset.document_read(&ours,file.stages[1])!=.None {git_merge_item_add(m,f,0,name,0,0);continue}
        defer asset.document_destroy(&ours)
        if asset.document_read(&theirs,file.stages[2])!=.None {git_merge_item_add(m,f,0,name,0,0);continue}
        defer asset.document_destroy(&theirs)
        origin:asset.Document
        has_origin:=file.stages[0]!=nil && asset.document_read(&origin,file.stages[0])==.None
        defer if has_origin {asset.document_destroy(&origin)}
        merged:asset.Document
        if asset.document_read(&merged,file.stages[1])!=.None {git_merge_item_add(m,f,0,name,0,0);continue}
        defer asset.document_destroy(&merged)
        result:asset.Merge
        defer asset.merge_destroy(&result)
        if asset.scene_merge(&result,&a.types,&merged,has_origin?&origin:nil,&theirs)!=.None {git_merge_item_add(m,f,0,name,0,0);continue}
        bytes,error:=asset.document_bytes(&merged,git_merge_arena(g))
        if error!=.None {git_merge_item_add(m,f,0,name,0,0);continue}
        file.merged=bytes
        // One item per entity, in the order the merge listed them.
        for conflict in result.conflicts {
            key:=base.Entity_Id(conflict.key)
            at:=-1
            for item,i in m.items {
                if item.file==f && item.key==key {at=i;break}
            }
            entry:=Git_Conflict{kind=conflict.kind,ours_has=conflict.ours,theirs_has=conflict.theirs}
            base.text_set(entry.path[:],conflict.path)
            base.text_set(entry.table[:],conflict.table)
            if close:=strings.index_byte(conflict.path,']');close>=0 {base.text_set(entry.field[:],conflict.path[close+1:])}
            else if dot:=strings.index_byte(conflict.path,'.');dot>=0 {base.text_set(entry.field[:],conflict.path[dot:])}
            if conflict.kind==.Value {
                base.text_set(entry.ours[:],git_value_text(&ours,conflict.path))
                base.text_set(entry.theirs[:],git_value_text(&theirs,conflict.path))
            }
            if at<0 {
                label:=key==0?name:git_entity_name(&ours,&theirs,key)
                git_merge_item_add(m,f,key,label,len(m.conflicts),0)
                at=len(m.items)-1
            }
            // Conflicts of an item stay together: what comes later of an earlier item goes after it.
            inject_at(&m.conflicts,m.items[at].first+m.items[at].count,entry)
            m.items[at].count+=1
            for &later in m.items[at+1:] {later.first+=1}
        }
        if len(result.conflicts)==0 {git_merge_item_add(m,f,0,name,0,0)}
    }
    // Details goes to the first item, in the scene it is of.
    m.current=0
    if len(m.items)>0 {git_merge_focus(s)}
    git_merge_preview(s)
}

@(private)
git_merge_item_add :: proc(m:^Git_Merge,file:int,key:base.Entity_Id,name:string,first,count:int) {
    item:=Git_Merge_Item{file=file,key=key,first=first,count=count}
    base.text_set(item.name[:],name)
    append(&m.items,item)
}

// Whether a file is of a kind of asset that merges row by row and field by
// field: asset.Kind_Info.merged, or what the manifest of its plugin declares
// (plugins: git_plugin_kinds).
git_merges_entities :: proc(plugins:[]build.Git_Kind,path:string) -> bool {
    if kind,found:=asset.kind_of_extension(path);found {
        info,_:=asset.kind_info(kind)
        return info.merged
    }
    for declared in plugins {
        if declared.merged && strings.has_suffix(path,declared.extension) {return true}
    }
    return false
}

@(private)
git_value_text :: proc(doc:^asset.Document,path:string) -> string {
    location,error:=asset.document_locate(doc,path)
    if error!=.None || location.column<0 {return ""}
    w:serial.Writer
    serial.writer_init(&w,allocator=context.temp_allocator)
    serial.text_write(&w,&doc.schema,location.type,location.bytes,.Line,0,location.is_text)
    return string(serial.writer_bytes(&w))
}

@(private)
git_entity_name :: proc(ours,theirs:^asset.Document,key:base.Entity_Id) -> string {
    path:=fmt.tprintf("entities[@0x%016x].name",u64(key))
    for doc in ([]^asset.Document{ours,theirs}) {
        if value,_,error:=asset.document_get(doc,path);error==.None {
            if name,ok:=value.(string);ok && name!="" {return name}
        }
    }
    return fmt.tprintf("0x%016x",u64(key))
}

// The file as the choices made leave it. nil for a file merged whole as it
// is in the folder.
git_merge_resolved :: proc(s:^Session,f:int,allocator:=context.temp_allocator) -> []u8 {
    g:=s.git
    file:=&g.merge.files[f]
    if file.merged==nil {
        switch file.whole {
        case .Theirs: return file.stages[2]
        case .Ours: return file.stages[1]
        case .Folder: return nil
        }
    }
    a:=s.app.assets
    doc:asset.Document
    if asset.document_read(&doc,file.merged,allocator)!=.None {return file.merged}
    scene:asset.Scene
    is_scene:=doc.kind==asset.KIND_SCENE || doc.kind==asset.KIND_PREFAB
    if is_scene {
        if asset.scene_from_document(&scene,&a.types,&doc)!=.None {return file.merged}
    }
    defer if is_scene {asset.scene_destroy(&scene)} else {asset.document_destroy(&doc)}
    target:=is_scene?&scene.doc:&doc
    theirs:asset.Scene
    theirs_read:=false
    defer if theirs_read {asset.scene_destroy(&theirs)}
    for &conflict in g.merge.conflicts {
        if git_conflict_file(g,&conflict)!=f || conflict.take_ours {continue}
        path:=base.text_get(conflict.path[:])
        switch conflict.kind {
        case .Value:
            location,error:=asset.document_locate(target,path)
            if error!=.None || location.column<0 {continue}
            reader:serial.Text_Reader
            serial.text_reader_init(&reader,base.text_get(conflict.theirs[:]))
            if serial.text_read(&reader,&target.schema,location.type,location.bytes,location.is_text) {serial.text_end(&reader)}
        case .Removed:
            if !is_scene {continue}
            key:=git_conflict_key(g,&conflict)
            table:=base.text_get(conflict.table[:])
            if conflict.ours_has && !conflict.theirs_has {
                // Theirs removed it.
                if table==asset.TABLE_ENTITIES {asset.scene_entities_remove(&scene,{key},descendants=false)}
                else if at,found:=asset.scene_component(&scene,table);found {asset.scene_component_remove(&scene,at,key)}
            } else if !conflict.ours_has && conflict.theirs_has {
                // Ours removed it: theirs brings it back, with its components.
                if !theirs_read {theirs_read=asset.scene_read(&theirs,&a.types,file.stages[2],allocator)==.None}
                if !theirs_read {continue}
                git_scene_restore(&scene,&theirs,key,table)
            }
        case .Table:
            if theirs_doc,ok:=git_document(file.stages[2],allocator);ok {asset.document_table_take(target,&theirs_doc,base.text_get(conflict.table[:]))}
        }
    }
    data:[]u8
    error:asset.Error
    if is_scene {data,error=asset.scene_bytes(&scene,allocator)} else {data,error=asset.document_bytes(&doc,allocator)}
    if error!=.None {return file.merged}
    return data
}

@(private)
git_document :: proc(data:[]u8,allocator:=context.temp_allocator) -> (doc:asset.Document,ok:bool) {
    if data==nil {return}
    return doc,asset.document_read(&doc,data,allocator)==.None
}

// An entity, or one component of it, as theirs has it.
@(private)
git_scene_restore :: proc(scene,theirs:^asset.Scene,key:base.Entity_Id,table:string) {
    row,found:=asset.scene_entity_find(theirs,key)
    if !found {return}
    if table==asset.TABLE_ENTITIES {
        if _,has:=asset.scene_entity_find(scene,key);!has {
            record:=asset.scene_entity(theirs,row)
            parent:=record.parent
            if _,known:=asset.scene_entity_find(scene,parent);!known {parent=0}
            if _,error:=asset.scene_entity_add(scene,key,parent,record.name);error!=.None {return}
        }
    }
    for &source,at in theirs.doc.tables {
        component:=at>0 && len(source.columns)==2 && source.columns[0].name==asset.COLUMN_ENTITY && source.columns[0].ref==0 && source.columns[1].name==asset.COLUMN_VALUE
        if !component || table!=asset.TABLE_ENTITIES && source.name!=table {continue}
        image,has:=asset.scene_component_get(theirs,at,key)
        if !has {continue}
        target,_:=asset.scene_component(scene,source.name)
        if target<0 {
            added,error:=asset.scene_component_add(scene,source.name,&theirs.doc.schema,source.columns[1].type)
            if error!=.None {continue}
            target=added
        }
        asset.scene_component_set(scene,target,key,image)
    }
}

@(private)
git_conflict_file :: proc(g:^Git,conflict:^Git_Conflict) -> int {
    index:=int((uintptr(conflict)-uintptr(raw_data(g.merge.conflicts)))/size_of(Git_Conflict))
    for item in g.merge.items {
        if index>=item.first && index<item.first+item.count {return item.file}
    }
    return -1
}

@(private)
git_conflict_key :: proc(g:^Git,conflict:^Git_Conflict) -> base.Entity_Id {
    index:=int((uintptr(conflict)-uintptr(raw_data(g.merge.conflicts)))/size_of(Git_Conflict))
    for item in g.merge.items {
        if index>=item.first && index<item.first+item.count {return item.key}
    }
    return 0
}

// The scene shown takes the choices of the file it is, without writing it.
git_merge_preview :: proc(s:^Session) {
    g:=s.git
    if !g.merge.loaded || s.app.assets==nil {return}
    open:=document_file(s.document)
    for &file,f in g.merge.files {
        if file.merged==nil {continue}
        if !project.path_same(git_file_absolute(g,&file),open) {continue}
        data:=git_merge_resolved(s,f)
        if data!=nil {git_scene_show(s,data)}
    }
}

// The absolute path of a file of the merge, as the document names its file.
@(private)
git_file_absolute :: proc(g:^Git,file:^Git_Merge_File) -> string {
    return project.path(base.text_get(g.root[:]),base.text_get(file.path[:]),allocator=context.temp_allocator)
}

// Replaces the edited World with a scene in memory, keeping the file of the
// document, which is unsaved after; the item shown stays selected.
@(private)
git_scene_show :: proc(s:^Session,data:[]u8) {
    a:=s.app.assets
    source:asset.Asset
    if asset.asset_open(&source,data)!=.None {return}
    defer asset.asset_close(&source)
    loaded:=new(asset.Scene)
    if asset.scene_read(loaded,&a.types,data)!=.None {free(loaded);return}
    w:=edited_world(s)
    runs_stop(s)
    tools_release(s)
    if _,error:=scene.replace(w,s.app,&source,&a.types);error!=.None {
        asset.scene_destroy(loaded);free(loaded)
        return
    }
    core.world_settle(w)
    document_previous_free(s.document)
    s.document.previous=loaded
    edits_reset(s.edits,w)
    s.document.saved=edits_scene_state(s.edits)
    s.document.unsaved=true
    s.view_cut=true
    g:=s.git
    if g.merge.current>=0 && g.merge.current<len(g.merge.items) {git_select(s,g.merge.items[g.merge.current].key)}
}

@(private)
git_select :: proc(s:^Session,key:base.Entity_Id) {
    if key==0 {return}
    w:=edited_world(s)
    if e:=core.entity_of(core.world_entities(w),key);e!=core.NONE {selection_set(s.selection,{e})}
}

// Writes every file as chosen, then adds and commits them.
git_merge_finish :: proc(s:^Session) -> string {
    g:=s.git
    if git.working(g) {return "Wait for git to finish"}
    if !g.merging || !g.merge.loaded {return "No merge to finish"}
    for item in g.merge.items {
        if !item.accepted {return "Accept or reject every conflict first"}
    }
    clear(&g.finish_paths)
    for &file,f in g.merge.files {
        data:=git_merge_resolved(s,f)
        if data!=nil && serial.file_write_atomic(git_file_absolute(g,&file),data)!=.None {return fmt.tprintf("%s could not be written",base.text_get(file.path[:]))}
        append(&g.finish_paths,strings.clone(base.text_get(file.path[:]),git_merge_arena(g)))
    }
    git.start(s.git,s.app.platform,git_roots(s),.Finish)
    return ""
}

// After the merge was committed: the open scene is read again from its file.
@(private)
git_merge_finished :: proc(s:^Session) {
    g:=s.git
    open:=document_file(s.document)
    reopen:=false
    for &file in g.merge.files {
        if project.path_same(git_file_absolute(g,&file),open) {reopen=true}
    }
    git_merge_clear(g)
    if reopen {scene_open(s,open)}
}

// Accepts an item as chosen, or rejects it: ours for all its conflicts.
git_merge_settle :: proc(s:^Session,index:int,keep_ours:bool) {
    g:=s.git
    if index<0 || index>=len(g.merge.items) {return}
    item:=&g.merge.items[index]
    if keep_ours {
        for &conflict in g.merge.conflicts[item.first:][:item.count] {conflict.take_ours=true}
        g.merge.files[item.file].whole=.Ours
    }
    item.accepted=true
    if keep_ours {git_merge_preview(s)}
    // The next one waiting.
    for _,step in g.merge.items {
        next:=(index+1+step)%len(g.merge.items)
        if !g.merge.items[next].accepted {g.merge.current=next;git_merge_focus(s);return}
    }
}

git_merge_settle_all :: proc(s:^Session,keep_ours:bool) {
    g:=s.git
    for &item in g.merge.items {
        if keep_ours {
            for &conflict in g.merge.conflicts[item.first:][:item.count] {conflict.take_ours=true}
            g.merge.files[item.file].whole=.Ours
        }
        item.accepted=true
    }
    if keep_ours {git_merge_preview(s)}
}

// Chooses one side for one conflict; an accepted item waits again.
git_conflict_choose :: proc(s:^Session,index:int,keep_ours:bool) {
    g:=s.git
    if index<0 || index>=len(g.merge.conflicts) {return}
    conflict:=&g.merge.conflicts[index]
    if conflict.take_ours==keep_ours {return}
    conflict.take_ours=keep_ours
    for &item in g.merge.items {
        if index>=item.first && index<item.first+item.count {item.accepted=false}
    }
    git_merge_preview(s)
}

// The item shown: its entity selected and in sight in the scene it is of.
@(private)
git_merge_focus :: proc(s:^Session) {
    g:=s.git
    if g.merge.current<0 || g.merge.current>=len(g.merge.items) {return}
    item:=&g.merge.items[g.merge.current]
    g.merge.shown=true
    file:=&g.merge.files[item.file]
    if file.merged!=nil && !project.path_same(git_file_absolute(g,file),document_file(s.document)) {
        if scene_open(s,git_file_absolute(g,file))==.None {git_merge_preview(s)}
    }
    git_select(s,item.key)
}

// The internal AI merges a file of text that both sides changed, or every
// conflict, through the methods git.* of the API.
git_merge_ai :: proc(s:^Session,index:int) {
    g:=s.git
    prompt:=strings.builder_make(context.temp_allocator)
    if index>=0 && index<len(g.merge.items) {
        item:=&g.merge.items[index]
        path:=base.text_get(g.merge.files[item.file].path[:])
        fmt.sbprintf(&prompt,"Resolve the merge conflict of %s: it has the conflict markers of git. Keep the changes of both sides so that the code still compiles, remove the markers, save the file and call git.choose with file %s and choice folder.",path,path)
    } else {
        strings.write_string(&prompt,"Resolve the merge conflicts of the project. Call git.conflicts to see them, choose ours or theirs for each value with git.choose, merge the files of code that both sides changed keeping both changes (save them and choose folder for them), and accept every item with git.accept. Do not call git.finish.")
    }
    if !ai_chat_ask(s,s.ai,strings.to_string(prompt)) {notify(s,"Connect an AI agent first")}
}

// While the merge waits, its entities are outlined red until accepted.
git_highlights :: proc(s:^Session,w:core.World_Ref,levels:[]u8) {
    g:=s.git
    if g==nil || !g.merging || !g.merge.loaded {return}
    open:=document_file(s.document)
    style_set:=false
    es:=core.world_entities(w)
    for item in g.merge.items {
        if item.accepted || item.key==0 {continue}
        if !project.path_same(git_file_absolute(g,&g.merge.files[item.file]),open) {continue}
        if !style_set {git_highlight_style(s);style_set=true}
        e:=core.entity_of(es,item.key)
        if at:=core.entity_index(e);e!=core.NONE && at<len(levels) {levels[at]=GIT_CONFLICT_LEVEL}
    }
}

// The outline of what a merge waits for, after the levels of the agents and the ghosts.
GIT_CONFLICT_LEVEL :: GHOST_LEVEL+1
GIT_CONFLICT_COLOR :: [4]f32{0.9,0.39,0.37,1}

@(private)
git_highlight_style :: proc(s:^Session) {
    r:=s.app.renderer
    if r==nil {return}
    style:=r.highlight
    style.colors[GIT_CONFLICT_LEVEL-1],style.fill[GIT_CONFLICT_LEVEL-1]=GIT_CONFLICT_COLOR,0
    if style!=r.highlight {gpu.renderer_set_highlight_style(r,style)}
}

// ---------------------------------------------------------------- the Git tab

git_merge_build :: proc(s:^Session,width,room:f32) {
    g:=s.git;ctx:=s.gui.ctx;th:=&ctx.theme
    busy:=git.working(g)
    m:=&g.merge
    left:=0
    for item in m.items {if !item.accepted {left+=1}}
    if ui.box(ctx,{width=ui.GROW,height=ui.FIT,direction=.Column,gap=8,padding=ui.padding_all(10),fill=th.chip,radius=th.radius_control}) {
        if ui.box(ctx,{width=ui.GROW,height=ui.FIT,gap=8,align_y=.Center}) {
            ui.icon(ctx,ui.icon_user(u8(User_Icon.Branch)),th.danger,14)
            if ui.box(ctx,{width=ui.GROW,height=ui.FIT,direction=.Column,gap=2}) {
                ui.label(ctx,"Merge conflicts",th.font,th.text,font=ui.FONT_SEMIBOLD)
                into:[128]u8
                ui.label(ctx,fmt.bprintf(into[:],"origin into %s",base.text_get(g.branch[:])),th.font_small,th.text_faint)
            }
            count:[32]u8
            ui.label(ctx,!m.loaded?"Reading...":left==0?"Resolved":fmt.bprintf(count[:],"%d left",left),th.font_small,th.text_muted)
        }
        total:=max(len(m.items),1)
        done:=f32(len(m.items)-left)/f32(total)
        if ui.box(ctx,{width=ui.GROW,height=ui.fixed(3),fill=th.chip_on,radius=1.5}) {
            if ui.box(ctx,{width=ui.fixed(max(done*(width-20),0)),height=ui.GROW,fill=th.accent,radius=1.5}) {}
        }
        if ui.button(ctx,ui.id(ctx,"git_ai_all"),{label="Resolve all with AI",icon=.Sparkle,style=.Field,width=-1,center=true,disabled=busy || !m.loaded}).clicked {git_merge_ai(s,-1)}
    }
    previous:=-1
    for &item,i in m.items {
        if item.file!=previous {
            previous=item.file
            ui.label(ctx,base.text_get(m.files[item.file].path[:]),th.font_caption,th.text_caption)
        }
        ui.id_push(ctx,ui.id(ctx,"item",i))
        shown:=m.shown && m.current==i
        if ui.box(ctx,{width=ui.GROW,height=ui.fixed(th.row+4),gap=6,align_y=.Center,padding={10,0,4,0},fill=shown?th.chip_on:th.chip,radius=th.radius_control}) {
            if ui.button(ctx,ui.id(ctx,"pick"),{label=base.text_get(item.name[:]),icon=item.key!=0?.Cube:ui.icon_user(u8(User_Icon.Component)),icon_color=th.text_muted,style=.Ghost,width=-1,size=th.font_small,padding=-1}).clicked {
                m.current=i
                git_merge_focus(s)
            }
            file:=&m.files[item.file]
            if !item.accepted && file.merged==nil && file.text {
                if ui.button(ctx,ui.id(ctx,"ai"),{label="AI",icon=.Sparkle,style=.Field,height=th.control-6,size=th.font_small,disabled=busy}).clicked {git_merge_ai(s,i)}
            }
            if item.accepted {ui.icon(ctx,.Check,th.accent_hover,13)} else {ui.box(ctx,{width=ui.fixed(6),height=ui.fixed(6),fill=th.danger,radius=3})}
        }
        ui.id_pop(ctx)
    }
    if ui.box(ctx,{width=ui.GROW,height=ui.FIT,gap=6}) {
        if ui.button(ctx,ui.id(ctx,"git_abort"),{label="Abort",style=.Field,width=-1,center=true,disabled=busy}).clicked {
            if message:=git.abort(s.git,s.app.platform,git_roots(s));message!="" {notify(s,message)}
        }
        if ui.button(ctx,ui.id(ctx,"git_reject_all"),{label="Reject all",style=.Field,width=-1,center=true,disabled=busy || !m.loaded}).clicked {git_merge_settle_all(s,true)}
        if left==0 {
            if ui.button(ctx,ui.id(ctx,"git_finish"),{label="Finish merge",style=.Accent,width=-1,center=true,disabled=busy || !m.loaded}).clicked {
                if message:=git_merge_finish(s);message!="" {notify(s,message)}
            }
        } else if ui.button(ctx,ui.id(ctx,"git_accept_all"),{label="Accept all",style=.Accent,width=-1,center=true,disabled=busy || !m.loaded}).clicked {git_merge_settle_all(s,false)}
    }
}
