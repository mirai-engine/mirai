package editor

import "core:fmt"
import "core:mem"
import "base:runtime"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:os"
import "mirai:asset"
import "mirai:cook/share"
import "mirai:host"
import "mirai:project"
import "mirai:std/base"
import "mirai:store"
import "mirai:ui"

// The libraries in the content browser: beside the project's own content, a
// root for this machine's library and, in a session, one for the library of
// each other editor, named as the session names it. A root holds packages with
// assets still to add; a peer's package this machine has is listed once,
// under this machine. Two packages of one name in a root are told apart by
// where their source was. Adding one is the browser's gesture for bringing
// content in: carried onto a folder of the project, or Add to project of its
// menu (library.odin and collab_library.odin do the adding).

// A root of libraries: this machine's (peer -1) or that of the editor at peer in the session.
Content_Library_Root :: struct {
    peer:int,
    name:string,
}

// A package as a root of the browser shows it.
Content_Package :: struct {
    root:int,       // of Content_Libraries.roots
    id:base.Asset_Id,
    name:string,
    folder,path:string,  // catalog folder and path in the browser
    label:string,   // its name, with where its source was when another of the root has that name
    kind:asset.Fourcc, // of its first asset
    assets:[]Library_Asset,
    bytes:i64,      // of its build; -1: unknown
    here:bool,      // this machine has its build: nothing has to be fetched
    built:bool,     // a build of it this engine reads is here or at its peer
    shown:store.Hash,     // the object of its root in that build, which its card shows; zero: none
    shown_id:base.Asset_Id, // this machine's: the asset of that object, which the library mount lists
    objects:[]store.Hash, // of every asset of that build, sorted: with shown, the key of its thumbnail
}

// A thumbnail of a card in the atlas (slot), or one the store did not have when it was looked for (slot -1).
@(private)
Content_Thumb :: struct {key:u64,slot:i32,frame:u64}
CONTENT_THUMBS :: 64
CONTENT_THUMB_RECHECK :: 30 // frames before a store that lacked a thumbnail is looked at again

// A thumbnail a visible card of a peer's root lacks, which the session asks that peer for.
Content_Thumb_Want :: struct {key:u64,peer:int}

// What a peer's library gave, as the listing takes it.
Content_Peer_Listing :: struct {
    peer:int,
    name:string,
    list:[]share.Peer_Package,
}

@(private)
Content_Libraries :: struct {
    arena:^mem.Dynamic_Arena, // what roots and packages hold, apart from the storage of the browser
    ready:bool,
    roots:[dynamic]Content_Library_Root,
    packages:[dynamic]Content_Package,
    key:[4]u64,
    mounted:bool,     // LIBRARY_MOUNT lists the packages of mounted_key
    mounted_key:u64,
}

// The roots and their packages from this machine's library, the packages the
// project pins and the libraries of the peers, in allocator. machine: this
// machine has a library (a store); without one it has no root.
content_library_listing :: proc(local:[]Library_Package,peers:[]Content_Peer_Listing,machine:=true,allocator:=context.allocator) -> (roots:[dynamic]Content_Library_Root,packages:[dynamic]Content_Package) {
    roots=make([dynamic]Content_Library_Root,allocator)
    packages=make([dynamic]Content_Package,allocator)
    here:=make(map[base.Asset_Id]bool,context.temp_allocator)
    for &p in local {
        here[p.id]=true
    }
    Origin :: struct {at:int,origin:string}
    origins:=make([dynamic]Origin,context.temp_allocator)
    if machine {append(&roots,Content_Library_Root{peer=-1,name="This machine"})}
    for &p in local {
        if !machine {continue}
        entry:=Content_Package{root=0,id=p.id,name=strings.clone(p.name,allocator),
            folder=strings.clone(content_package_parent(p.catalog_path),allocator),
            here=len(p.assets)>0,built=true}
        entry.assets=make([]Library_Asset,len(p.assets),allocator)
        remaining:=false
        for a,at in p.assets {
            entry.assets[at]=a
            entry.assets[at].name=strings.clone(a.name,allocator)
            if entry.kind==0 {entry.kind=a.kind}
            entry.bytes+=a.bytes
            entry.here&&=a.built
            remaining||=!a.pinned
        }
        if p.pinned && !remaining {continue}
        entry.built=entry.here
        entry.shown,entry.shown_id,entry.objects=p.root,p.shown,slice.clone(p.objects,allocator)
        append(&origins,Origin{len(packages),p.origin})
        append(&packages,entry)
    }
    for &listing in peers {
        root:=len(roots)
        append(&roots,Content_Library_Root{peer=listing.peer,name=strings.clone(listing.name,allocator)})
        for &p in listing.list {
            if here[p.id] {continue}
            entry:=Content_Package{root=root,id=p.id,name=strings.clone(p.name,allocator),
                folder=strings.clone(content_package_parent(p.catalog_path),allocator),
                bytes=p.bytes,here=p.here,built=p.built}
            entry.assets=make([]Library_Asset,len(p.assets),allocator)
            for a,at in p.assets {entry.assets[at]={id=a.id,name=strings.clone(a.name,allocator),kind=a.kind}}
            if len(p.kinds)>0 {entry.kind=p.kinds[0]}
            entry.shown,entry.objects=p.root,slice.clone(p.objects,allocator)
            append(&origins,Origin{len(packages),p.origin})
            append(&packages,entry)
        }
    }
    // A name two packages of a root share takes where each one's source was: its folder, or all of it when that is shared too.
    for &o in origins {packages[o.at].label=packages[o.at].name}
    for i in 0..<len(origins) {
        a:=&packages[origins[i].at]
        shared,folder_shared:=false,false
        for j in 0..<len(origins) {
            b:=&packages[origins[j].at]
            if i==j || a.root!=b.root || a.folder!=b.folder || a.name!=b.name {continue}
            shared=true
            folder_shared||=origin_folder(origins[i].origin)==origin_folder(origins[j].origin)
        }
        if !shared {continue}
        where_from:=origin_folder(origins[i].origin)
        if folder_shared || where_from=="" {where_from=origins[i].origin}
        if where_from!="" {a.label=fmt.aprintf("%s (%s)",a.name,where_from,allocator=allocator)}
    }
    for &p in packages {
        name:=asset.safe_name(p.label)
        p.path=strings.clone(name,allocator) if p.folder=="" else
            strings.concatenate({p.folder,"/",name},allocator)
    }
    // In each root by label, as the browser lists files by name.
    slice.sort_by(packages[:],proc(a,b:Content_Package) -> bool {return a.root<b.root || a.root==b.root && a.label<b.label})
    return
}

@(private)
content_package_parent :: proc(folder:string) -> string {
    return content_folder_of(folder[:API_PATH_BYTES]) if len(folder)>API_PATH_BYTES else folder
}

// The name of the folder a source was in; "" when it has none.
@(private)
origin_folder :: proc(origin:string) -> string {
    path,_:=strings.replace_all(origin,"\\","/",context.temp_allocator)
    path=strings.trim_right(path,"/")
    slash:=strings.last_index_byte(path,'/')
    if slash<=0 {return ""}
    folder:=path[:slash]
    if at:=strings.last_index_byte(folder,'/');at>=0 {folder=folder[at+1:]}
    return folder
}

// Reads the libraries again when what they come from changed: the registry
// (what the project pins), the libraries of the peers or a package taken.
@(private)
content_libraries_update :: proc(s:^Session,c:^Content) {
    l:=&c.libraries
    st:=collab_state(s)
    peers_key:u64
    if st!=nil && st.node!=nil && st.phase==.Joined {
        collab_libraries_read(st)
        collab_libraries_promote(st)
        peers_key=u64(uintptr(st.libraries))
        for peer in st.peers {peers_key=base.hash_combine(peers_key,u64(peer.used))}
    }
    registry:u64
    if a:=s.app.assets;a!=nil {registry=a.registry.revision}
    key:=[4]u64{registry,peers_key,c.library_revision,u64(len(s.store.root))}
    if l.ready && key==l.key {return}
    l.key,l.ready=key,true
    if l.arena==nil {
        l.arena=new(mem.Dynamic_Arena,runtime.heap_allocator())
        mem.dynamic_arena_init(l.arena,runtime.heap_allocator(),runtime.heap_allocator())
    }
    l.roots,l.packages=nil,nil
    mem.dynamic_arena_free_all(l.arena)
    allocator:=base.dynamic_arena_allocator(l.arena)
    local:[]Library_Package
    if s.store.root!="" {local,_=library_list(s,s.project_root,context.temp_allocator)}
    listings:=make([dynamic]Content_Peer_Listing,context.temp_allocator)
    if st!=nil && st.libraries!=nil && st.phase==.Joined {
        for &library in st.libraries.libraries[:st.libraries.count] {
            if !st.peers[library.peer].used || library.error!="" {continue}
            name:=collab_peer_name(s,library.peer)
            append(&listings,Content_Peer_Listing{peer=library.peer,name=name!="" ? name : "Editor",list=library.list})
        }
    }
    roots,packages:=content_library_listing(local,listings[:],s.store.root!="",allocator)
    l.roots,l.packages=roots,packages
    content_library_restore(c)
    library_mount_update(s,local)
    c.revision+=1
}

// The group of the row of a root, apart from those of folders and virtual ones.
@(private)
content_library_group :: proc "contextless" (root:int) -> u64 {return base.hash_combine(0x6c6962,u64(root+2))}

@(private)
content_package_text_matches :: proc(name,filter:string) -> bool {
    folded:=strings.to_lower(name,context.temp_allocator)
    for token in strings.fields(filter,context.temp_allocator) {
        if !strings.contains(folded,strings.to_lower(token,context.temp_allocator)) {return false}
    }
    return true
}

// Whether a package or one of its assets matches the current search and kind.
@(private)
content_package_asset_matches :: proc(c:^Content,entry:Library_Asset,filter:string) -> bool {
    category,_:=content_category(entry.kind)
    return (c.category==.None || c.category==category) && content_package_text_matches(entry.name,filter)
}

@(private)
content_package_title_matches :: proc(p:^Content_Package,filter:string) -> bool {
    if filter=="" {return true}
    return content_package_text_matches(fmt.tprintf("%s/%s",p.folder,p.label),filter)
}

@(private)
content_package_matches :: proc(c:^Content,p:^Content_Package,filter:string) -> bool {
    if c.unused || c.selection_only {return false}
    title:=content_package_title_matches(p,filter)
    if title {
        category,_:=content_category(p.kind)
        if c.category==.None || c.category==category {return true}
    }
    for entry in p.assets {
        if content_package_asset_matches(c,entry,"" if title else filter) {return true}
    }
    return false
}

@(private)
content_package_asset_cards :: proc(c:^Content,pack:int,filter:string) {
    p:=&c.libraries.packages[pack]
    asset_filter:="" if content_package_title_matches(p,filter) else filter
    for &entry,at in p.assets {
        if !content_package_asset_matches(c,entry,asset_filter) {continue}
        append(&c.cards,Content_Card{file=-1,pack=i32(pack+1),pack_asset=i32(at+1),name=entry.name})
    }
}

// Paths of a library's packages under the same folder tree used for project files.
@(private)
content_package_entries :: proc(c:^Content,root:int,filter:string) -> []Content_Entry {
    entries:=make([dynamic]Content_Entry,context.temp_allocator)
    for &p,k in c.libraries.packages {
        if p.root!=root || !content_package_matches(c,&p,filter) {continue}
        append(&entries,Content_Entry{p.path,i32(k)})
    }
    slice.sort_by(entries[:],proc(a,b:Content_Entry) -> bool {return a.path<b.path || a.path==b.path && a.index<b.index})
    return entries[:]
}

@(private)
content_package_card :: proc(c:^Content,pack:i32) {
    append(&c.cards,Content_Card{file=-1,pack=pack+1,name=c.libraries.packages[pack].label})
}

@(private)
content_package_cards_add :: proc(c:^Content,root:int,filter:string,folder:string,chosen:=base.Asset_Id{}) {
    if chosen!={} {
        for &p,k in c.libraries.packages {
            if p.root!=root || p.id!=chosen || !content_package_matches(c,&p,filter) {continue}
            content_package_asset_cards(c,k,filter)
            break
        }
        return
    }
    if root<0 {return}
    library:=i32(c.libraries.roots[root].peer+1)
    prefix:=fmt.tprintf("%s/",folder) if folder!="" else ""
    entries:=content_under(content_package_entries(c,root,filter),prefix)
    for child in content_children(entries,prefix) {
        append(&c.cards,Content_Card{file=-1,name=child.name,folder=child.path,virtual=.Library,library=library})
    }
    for pack in content_direct_files(entries,prefix) {content_package_card(c,pack)}
}

@(private)
content_library_folder_group :: proc(root:int,folder:string) -> u64 {
    group:=content_library_group(root)
    return group if folder=="" else base.hash_combine(group,base.hash64(transmute([]u8)folder))
}

// Package folders under an importer's path, and the assets of those that are open.
@(private)
content_package_tree_add :: proc(c:^Content,library:i32,root:int,entries:[]Content_Entry,filter,prefix:string,depth:int,parent:i32) {
    for child in content_children(entries,prefix) {
        group:=content_library_folder_group(root,child.path)
        header:=i32(len(c.lines))
        append(&c.lines,Content_Line{kind=.Header,group=group,name=child.name,path=child.path,
            virtual=.Library,library=library,parent=parent,depth=u8(min(depth,255))})
        if !content_folded(c,group) {
            content_package_tree_add(c,library,root,child.entries,filter,fmt.tprintf("%s/",child.path),depth+1,header)
        }
    }
    group:=content_library_group(root)
    for pack in content_direct_files(entries,prefix) {
        first:=len(c.cards)
        content_package_card(c,pack)
        content_tree_rows_add(c,first,depth,group,parent)
        if slice.contains(c.unfolded[:],c.libraries.packages[pack].id) {
            first=len(c.cards)
            content_package_asset_cards(c,int(pack),filter)
            content_tree_rows_add(c,first,depth+1,group,parent)
        }
    }
}

// The root a virtual Library folder shows: Content_At.library is its peer, +1.
@(private)
content_library_root_of :: proc(c:^Content,library:i32) -> int {
    for root,at in c.libraries.roots {
        if i32(root.peer+1)==library {return at}
    }
    return -1
}

// A package taken from a peer moves into This machine; keep its folder open.
@(private)
content_library_restore :: proc(c:^Content) {
    if c.at.virtual!=.Library {return}
    root:=content_library_root_of(c,c.at.library)
    if c.at.package_id!={} {
        chosen:=-1
        for &p,k in c.libraries.packages {
            if p.id!=c.at.package_id {continue}
            chosen=k
            if p.root==root {break}
        }
        if chosen>=0 {
            p:=&c.libraries.packages[chosen]
            c.at.library=i32(c.libraries.roots[p.root].peer+1)
            c.at.length=copy(c.at.folder[:],p.folder)
            return
        }
        c.at.package_id={}
    }
    if root<0 {c.at={};return}
    folder:=string(c.at.folder[:c.at.length])
    for folder!="" {
        for p in c.libraries.packages {
            if p.root==root && (p.folder==folder || asset_path_inside(p.folder,folder)) {return}
        }
        folder=content_folder_of(folder)
        c.at.length=len(folder)
    }
}

@(private)
content_library_crumbs :: proc(s:^Session,act:^Content_Actions,name,folder:string) {
    c:=s.content
    ctx:=s.gui.ctx
    library:=ui.id(ctx,"content_crumb_library")
    it:=content_crumb(ctx,library,name,false,true,false)
    content_folder_take(s,act,library,it,.Library,"",library=c.at.library)
    start:=0
    for i in 0..=len(folder) {
        if folder=="" || i<len(folder) && folder[i]!='/' {continue}
        id:=ui.id(ctx,"content_crumb_library_folder",i+1)
        last:=i==len(folder) && c.at.package_id=={}
        it:=content_crumb(ctx,id,folder[start:i],last,true,false)
        if !last {content_folder_take(s,act,id,it,.Library,folder[:i],library=c.at.library)}
        start=i+1
    }
    if c.at.package_id=={} {return}
    root:=content_library_root_of(c,c.at.library)
    for &p in c.libraries.packages {
        if p.id!=c.at.package_id || p.root!=root {continue}
        content_crumb(ctx,ui.id(ctx,"content_crumb_package"),p.label,true,true,false)
        break
    }
}

// The state of fetching a package of a peer, as its card says it.
@(private)
content_package_state :: proc(s:^Session,p:^Content_Package) -> (text:string,failed:bool,why:string) {
    st:=collab_state(s)
    if st!=nil && st.take!=nil && st.take.id==p.id {
        t:=st.take
        if !sync.atomic_load(&t.done) || t.thread!=nil {
            received:=share.node_totals(st.node).received-t.received
            if p.bytes>0 {return fmt.tprintf("Fetching %d%%",min(int(received*100/u64(p.bytes)),99)),false,""}
            return "Fetching",false,""
        }
        if t.error!="" {return "Not added",true,t.error}
    }
    // A package of a peer's root is not in this machine's library yet: adding takes it, even when its build is here.
    peer:=content_package_peer(s,p)
    switch {
    case peer<0:     return p.bytes>0 ? share.bytes_text(p.bytes) : "",false,""
    case p.bytes>=0: return fmt.tprintf("%s to fetch",share.bytes_text(p.bytes)),false,""
    }
    return "To fetch",false,""
}

@(private)
content_package_peer :: proc(s:^Session,p:^Content_Package) -> int {
    roots:=s.content.libraries.roots
    return p.root<len(roots) ? roots[p.root].peer : -1
}

// A package as a row of Folders, a row of the list or a cell of a grid: the
// icon of its kind, its label and what has to be fetched or is being fetched.
@(private)
content_package_item :: proc(s:^Session,card:Content_Card,group:u64,cell:f32,depth:=-1) -> (it:ui.Interaction,id:ui.Id) {
    c:=s.content
    ctx:=s.gui.ctx
    p:=&c.libraries.packages[card.pack-1]
    kind,item,added:=p.kind,base.Asset_Id{},false
    if card.pack_asset>0 {
        entry:=p.assets[card.pack_asset-1]
        kind,item,added=entry.kind,entry.id,entry.pinned
    }
    key:=base.hash_combine(group,base.hash_combine(p.id[0],p.id[1]))
    if item!={} {key=base.hash_combine(key,base.hash_combine(item[0],item[1]))}
    id=ui.id(ctx,"content_package",int(key))
    it=ui.interact(ctx,id,{.Focusable})
    selected:=item=={} && c.package_selected==p.id && c.package_root==p.root
    icon,color:=asset_icon(s,kind)
    if item=={} {icon=content_folder_icon(.None)}
    state,why:string
    failed:bool
    if item=={} {state,failed,why=content_package_state(s,p)}
    quad:=content_package_thumbnail(s,p,20 if depth>=0 || c.view.mode==.List else cell) if item=={} else ui.Quad{}
    ink:=ui.tone(ctx,"danger_soft") if failed else ui.tone(ctx,"text_muted")
    if depth>=0 || c.view.mode==.List {
        box:=asset_row_box(ctx,id,CONTENT_INSET+f32(max(depth,0))*CONTENT_TREE_INDENT,selected,it.hot,content_keyboard(ctx,it))
        if depth>=0 {box.width,box.gap=ui.fixed(cell),CONTENT_TREE_GAP}
        if ui.box(ctx,box) {
            if depth>=0 {
                if item=={} {
                    arrow:=.Chevron_Down if slice.contains(c.unfolded[:],p.id) else ui.Icon.Chevron_Right
                    ui.icon(ctx,arrow,ui.tone(ctx,"text_muted"),CONTENT_TREE_ARROW)
                } else {ui.spacer(ctx,CONTENT_TREE_ARROW,1)}
            }
            if ui.box(ctx,{width=ui.fixed(20),height=ui.fixed(20),align_x=.Center,align_y=.Center,radius=2,clip_x=true,clip_y=true}) {
                if quad.kind!=.Solid {ui.image(ctx,{quad=quad,width=ui.GROW,height=ui.GROW})} else {ui.icon(ctx,icon,color,14)}
            }
            ui.label(ctx,card.name,ui.metric(ctx,"font"),ui.tone(ctx,"text"),0,font=ui.FONT_MEDIUM if selected else 0)
            ui.spacer(ctx,-1,1)
            if item=={} && state!="" {ui.label(ctx,state,ui.metric(ctx,"font_small"),ink)}
            content_package_button(s,p,key,item,added)
            ui.spacer(ctx,4,1)
        }
    } else {
        names:=u8(2)
        if ui.box(ctx,asset_card_box(ctx,id,c.view,cell,selected,content_keyboard(ctx,it),names)) {
            stroke,stroke_width:=asset_frame_edge(ctx,it.hot,selected)
            asset_frame(s,cell,CONTENT_FRAME,stroke,stroke_width,quad,icon,color,kind)
            if content_shows_names(c.view) {content_name(ctx,card.name,selected,cell,names)}
            if ui.box(ctx,{width=ui.FIT,height=ui.FIT,radius=2,fill=ui.tone(ctx,"panel"),float={to=.Parent,anchor=.Top_Right,pivot=.Top_Right,offset={-3,3}}}) {
                content_package_button(s,p,key,item,added)
            }
        }
    }
    if it.hot {
        tip:=fmt.tprintf("%s, %s",card.name,state) if item=={} && state!="" else card.name
        if why!="" {tip=fmt.tprintf("%s: %s",tip,why)}
        ui.tooltip(ctx,tip)
    }
    return
}

@(private)
content_package_button :: proc(s:^Session,p:^Content_Package,key:u64,item:base.Asset_Id,added:bool) {
    ctx:=s.gui.ctx
    if added {
        ui.icon(ctx,.Check,ui.tone(ctx,"text_muted"),12)
        return
    }
    disabled:=s.mode!=.Edit || content_package_busy(s)
    tip:="Add folder to project" if item=={} else "Add asset to project"
    if ui.button(ctx,ui.id(ctx,"content_package_add",int(key)),{icon=.Plus,tip=tip,variant="ghost",width=20,height=20,icon_size=12,disabled=disabled}).clicked {
        content_package_add(s,i32(s.content.libraries.roots[p.root].peer+1),p.id,content_create_place(s.content),item)
    }
}

// What a click, a press and the right button do on a package: select it,
// carry it to a folder of the project, open its menu.
@(private)
content_package_action :: proc(s:^Session,act:^Content_Actions,card:Content_Card,it:ui.Interaction) {
    c:=s.content
    g:=s.gui
    p:=&c.libraries.packages[card.pack-1]
    library:=i32(c.libraries.roots[p.root].peer+1)
    item:=base.Asset_Id{}
    if card.pack_asset>0 {item=p.assets[card.pack_asset-1].id}
    if item=={} && it.pressed {
        d:=Drag{kind=.Package,asset_id=p.id,asset_kind=p.kind,library=library}
        d.icon,d.color=asset_icon(s,p.kind)
        drag_begin(g,d,card.name)
    }
    if item=={} && it.clicked {
        if c.view.arrangement==.Folders {
            content_unfold(c,p.id)
        } else {
            act.enter,act.reset,act.virtual,act.folder,act.library,act.package_id=true,false,.Library,p.folder,library,p.id
        }
    }
    if it.clicked || it.right {c.package_selected,c.package_root=p.id,p.root}
    if it.right {
        if card.pack_asset>0 && p.assets[card.pack_asset-1].pinned {return}
        c.package_menu,c.package_menu_library,c.package_menu_asset=p.id,library,item
        ui.popup_open(g.ctx,content_package_menu_id(g),{g.ctx.pointer.x,g.ctx.pointer.y,0,0})
    }
}

@(private)
content_package_menu_id :: proc(g:^Editor_Ui) -> ui.Id {return shell_id(g,"content_package_menu")}

// The menu of a package: Add to project, into the folder the browser makes in.
@(private)
content_package_menu :: proc(s:^Session) {
    c:=s.content
    g:=s.gui
    ctx:=g.ctx
    popup:=content_package_menu_id(g)
    if !ui.popup_is_open(ctx,popup) {return}
    if ui.popup(ctx,popup,{min_width=180}) {
        ui.id_push(ctx,popup)
        defer ui.id_pop(ctx)
        if ui.menu_item(ctx,ui.id(ctx,"add"),"Add to project",{icon=.Import,disabled=s.mode!=.Edit || content_package_busy(s)}) {
            content_package_add(s,c.package_menu_library,c.package_menu,content_create_place(c),c.package_menu_asset)
        }
    }
}

// A package being taken from a peer or an import running: nothing else is added meanwhile.
@(private)
content_package_busy :: proc(s:^Session) -> bool {
    if s.importer==nil || s.importer.running!=nil {return true}
    st:=collab_state(s)
    return st!=nil && st.take!=nil && (st.take.thread!=nil || !sync.atomic_load(&st.take.done))
}

// Adds the package id of the library (its peer +1, 0: this machine) to folder of the project.
@(private)
content_package_add :: proc(s:^Session,library:i32,id:base.Asset_Id,folder:string,item:=base.Asset_Id{}) {
    buffer,asset_buffer:[base.ASSET_ID_TEXT]u8
    text:=base.asset_id_format(id,buffer[:])
    wanted:[1]string
    ids:=wanted[:0]
    if item!={} {wanted[0]=base.asset_id_format(item,asset_buffer[:]);ids=wanted[:]}
    problem:=library==0 ? library_add(s,text,ids,folder) : collab_library_add(s,int(library-1),text,folder,ids)
    if problem!="" {notify(s,problem)}
}

// The thumbnail of the card of a package at points: in the atlas, else from
// the store of this machine, read a few a frame; a card of a peer's root that
// the store lacks asks the session for it (Content.thumb_wants), which asks
// that peer. Nothing is drawn for a card, and nothing of the package fetched.
@(private)
content_package_thumbnail :: proc(s:^Session,p:^Content_Package,points:f32) -> ui.Quad {
    c:=s.content
    if p.shown=={} || s.store.root=="" {return {}}
    // One of this machine: the preview its asset has, which the browser draws
    // and keeps as it does for the project's (the library mount lists it).
    if content_package_peer(s,p)<0 {
        if a:=s.app.assets;a!=nil {
            if file,found:=asset.registry_find(&a.registry,p.shown_id);found {
                _,_,quad:=content_preview(s,file,points)
                return quad
            }
        }
    }
    level:=Thumbnail_Level.Large if points*max(s.app.density,1)>THUMBNAIL_SIZE else .Small
    key:=thumbnail_package_key(level,thumbnail_programs(s),p.shown,p.objects)
    held:^Content_Thumb
    oldest:=0
    for &t,at in c.thumbs {
        if t.key==key {held=&t;break}
        if t.frame<c.thumbs[oldest].frame {oldest=at}
    }
    if held!=nil && held.slot>=0 {
        held.frame=s.frame
        if quad:=thumbnail_image_quad(s,int(held.slot),key);quad.kind!=.Solid {return quad}
        held.slot=-1
    }
    if held!=nil && held.slot<0 && s.frame<held.frame+CONTENT_THUMB_RECHECK {return {}}
    if held==nil {
        held=&c.thumbs[oldest]
        held^={key=key,slot=-1}
    }
    held.frame=s.frame
    if th:=s.thumbnails;th!=nil {
        if th.loaded!=s.frame {th.loaded,th.loads=s.frame,0}
        if th.loads>=THUMBNAIL_LOADS {
            held.frame=0 // its turn comes in another frame
            return {}
        }
        th.loads+=1
        sides:=THUMBNAIL_SIDES
        if thumbnail_store_load(&s.store,sides[level],key,&th.file,&th.image) {
            held.slot=i32(thumbnail_image_put(s,key,level,th.image[:]))
            return thumbnail_image_quad(s,int(held.slot),key)
        }
    }
    if peer:=content_package_peer(s,p);peer>=0 && len(c.thumb_wants)<CONTENT_THUMBS {append(&c.thumb_wants,Content_Thumb_Want{key,peer})}
    return {}
}

LIBRARY_MOUNT :: ".library" // the outputs of this machine's packages the project does not pin, listed by id alone

// Lists under LIBRARY_MOUNT the outputs of the packages of this machine's
// library the project does not pin, so a card of This machine draws its
// preview as the project's content does, without the package entering the
// project: a path under a folder that starts with a dot is none the browser,
// the lists or a path of the project reaches. Only when they change.
@(private)
library_mount_update :: proc(s:^Session,local:[]Library_Package) {
    a:=s.app.assets
    if a==nil || s.store.root=="" || s.project_root=="" {return}
    list:asset.Packages
    list.packages=make([dynamic]asset.Project_Package,context.temp_allocator)
    key:u64
    for &p in local {
        if p.pinned {continue}
        buffer:[base.ASSET_ID_TEXT]u8
        append(&list.packages,asset.Project_Package{id=p.id,manifest=p.manifest,folder=strings.clone(base.asset_id_format(p.id,buffer[:]),context.temp_allocator)})
        m:=p.manifest
        key=base.hash_combine(key,base.hash64(m[:]))
    }
    l:=&s.content.libraries
    if l.mounted && key==l.mounted_key {return}
    r:=&a.registry
    mounted:=false
    for mount in r.mounts {mounted||=mount.prefix==LIBRARY_MOUNT}
    if !mounted {
        folder:=project.path(project.folder_path(s.project_root,.Generated,context.temp_allocator),"library",allocator=context.temp_allocator)
        if os.make_directory_all(folder)!=nil && !os.is_dir(folder) {return}
        if !asset.registry_mount(r,folder,LIBRARY_MOUNT) {return}
    }
    resolved,error:=asset.packages_resolve(&s.store,"",&list,context.temp_allocator)
    if error!=.None || !asset.registry_listed_set(r,LIBRARY_MOUNT,resolved.listed[:]) {return}
    l.mounted,l.mounted_key=true,key
    host.assets_scan(a)
}
